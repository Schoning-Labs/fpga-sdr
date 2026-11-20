// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ft8_ring_writer: writes the spectrogram lines to DDR3.
//
// What it does
//   ft8_power.v hands over each spectrogram frame as 1,024 power words of 32 bit, one per bin in order, and this block
//   writes them to the receiver's spectrogram ring at the lane word address
//   `ring_base + frame_index * 512 + bin / 2`: two 32-bit power words per 64-bit lane word, bin 2m in the low half and bin
//   2m + 1 in the high half.  Read as bytes (little-endian), the ring is exactly a `u32` array S[j * 1,024 + k], with frame
//   j and bin k, which is the layout of the Rust model and of the firmware.  A frame is 4 KB, the ring of 372 frames is 1.5 MB
//   per receiver (docs/ARCHITECTURE.md section 3.12, docs/F5_FT8SPEC.md).
//
// Where it sits in the radio
//   Fed by: ft8_power.v.  Feeds: the DDR3 write lane (through ft8_ddr3_mux.v).  Controlled by ft8_spectrogram.v, which
//   sets `ring_base` and `frame_index` and waits for `idle`.
//
// How it works
//   Pairs of words are packed into lane words, which go into a small FIFO (DEPTH entries, LUT RAM), and are written in
//   bursts of BURST beats (512 / BURST bursts per frame, and a burst never crosses into the next frame).  The block
//   drives `wdata` for the current beat from the FIFO head combinationally, advances on each `gnt`, and holds `req` until
//   `done` (the convention of rtl/ddr3/ddr3_write_arbiter.v).  Flow control: every lane word taken off the FIFO frees two
//   bins of space, which is reported on `credit` to ft8_power.v, and that starts with 2 x DEPTH credits, so it never has more
//   words in flight than the FIFO can take.
//
//   `idle` is high once every word that was handed in has been written (FIFO empty and no burst open).  The scheduler waits
//   for it before it raises the frame interrupt, so the interrupt means "this frame is in DDR3".  `frame_index` and
//   `ring_base` have to stay stable until then.

`timescale 1ns / 1ps

module ft8_ring_writer #(
    parameter integer ADDR_WIDTH = 32,
    parameter integer BURST      = 16,    // beats per burst; 512 must be a multiple of it
    parameter integer DEPTH      = 32     // lane-word FIFO entries, a power of two, at least BURST
) (
    // Clock (clk_dsp, 120 MHz) and synchronous reset (active high).
    input  wire        clk,
    input  wire        rst,

    // One frame's power words in bin order (ft8_power.v's stream): in_valid with the bin number and the 32-bit word.
    // ring_base is this receiver's spectrogram ring (a lane word address) and frame_index is 0 .. 371.
    input  wire        in_valid,
    input  wire [9:0]  in_bin,
    input  wire [31:0] in_word,
    input  wire [ADDR_WIDTH-1:0] ring_base,     // this receiver's spectrogram ring base
    input  wire [8:0]  frame_index,             // 0 .. 371

    // credit: 2 in the clock where a lane word leaves the FIFO (two bins of space freed), else 0.  idle: see the header.
    output wire [1:0]  credit,                  // bins of FIFO space freed this clock
    output wire        idle,

    // Write-lane client port (rtl/ddr3/ddr3_write_arbiter.v): req with address and burst length, wdata for the current
    // beat, gnt per beat, done at the end of the burst.
    output reg          req,
    output reg  [ADDR_WIDTH-1:0] addr,
    output wire [7:0]   burstlen,
    output wire [63:0]  wdata,
    output wire [7:0]   wmask,
    input  wire         gnt,
    input  wire         done
);

    // Width of the FIFO pointers.  Every write is a whole lane word (mask all ones) and a burst is BURST beats.
    localparam integer AW = $clog2(DEPTH);

    assign burstlen = BURST[7:0];
    assign wmask    = 8'hFF;

    // ---- pair packer: the even bin waits in `lo`, and the odd bin pushes {odd, even} into the FIFO ----
    reg [31:0] lo;
    wire       push = in_valid && in_bin[0];
    always @(posedge clk) if (in_valid && !in_bin[0]) lo <= in_word;

    // ---- lane-word FIFO ----
    // LUT RAM: as block RAM this 64-bit-wide FIFO would take 6 block RAMs, and that is not worth it for 32 words.
    // wp and rp are its write and read pointers (one bit wider than the index so that full and empty differ), cnt the
    // fill, and the head is shown on wdata.
    (* syn_ramstyle = "distributed_ram" *) reg [63:0] fdata [0:DEPTH-1];
    reg [AW:0] wp, rp;
    wire [AW:0] cnt   = wp - rp;
    wire        empty = (wp == rp);
    wire        pop   = gnt;

    always @(posedge clk) begin
        if (push) fdata[wp[AW-1:0]] <= {in_word, lo};
    end
    always @(posedge clk) begin
        if (rst) begin
            wp <= 0;
            rp <= 0;
        end else begin
            if (push) wp <= wp + 1'b1;
            if (pop)  rp <= rp + 1'b1;
        end
    end

    assign wdata  = fdata[rp[AW-1:0]];
    // credit: each beat granted frees one lane word, which is two bins.
    assign credit = pop ? 2'd2 : 2'd0;

    // ---- burst control ----
    // Every frame is exactly 512 lane words, which is 512 / BURST whole bursts written in order, so the first word index
    // of the next burst is a running count (plus BURST per burst, wrapping at 512 to word 0 of the next frame).  The
    // address is precomputed from registers on every clock (ring_base and frame_index hold still while a frame is
    // written), and `gap` keeps the next burst from starting in the clock after `done`, while addr_nx still holds the
    // old index.
    reg [8:0]            widx;
    reg                  gap;
    reg [ADDR_WIDTH-1:0] frame_base, addr_nx;
    always @(posedge clk) begin
        frame_base <= ring_base + {frame_index, 9'd0};
        addr_nx    <= frame_base + widx;
    end
    reg in_burst;
    always @(posedge clk) begin
        if (rst) begin
            req      <= 1'b0;
            in_burst <= 1'b0;
            widx     <= 9'd0;
            gap      <= 1'b0;
        end else if (!in_burst) begin
            gap <= 1'b0;
            if (cnt >= BURST && !gap) begin
                req      <= 1'b1;
                in_burst <= 1'b1;
                addr     <= addr_nx;
            end
        end else if (done) begin
            req      <= 1'b0;
            in_burst <= 1'b0;
            widx     <= widx + BURST[8:0];
            gap      <= 1'b1;
        end
    end

    // idle is registered, because as a combinational output it fed the scheduler's per-receiver frame counters through a
    // FIFO-count compare in one clock.  `!push` keeps it low in the clock where the last word is written.

    reg idle_r;
    always @(posedge clk) idle_r <= !rst && empty && !in_burst && !push;
    assign idle = idle_r;

endmodule
