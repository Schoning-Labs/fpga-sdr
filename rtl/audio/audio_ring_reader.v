// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// audio_ring_reader: reads the stereo audio ring in DDR3 and turns it into a steady stream of samples.
//
// What it does
//   Firmware writes 48 kHz stereo samples (16 bit, two's complement) into a ring buffer in DDR3 and moves a write
//   pointer past them (the CPU writes through its cache, so it has to write the cache back before it moves the
//   pointer).  This module follows that pointer: as long as the ring holds unread samples and there is room in
//   a small prefetch FIFO, it asks DDR3 for the next word, one word per stereo sample, packed as
//   {left[15:0], right[15:0]} (`mem_rdata[31:16]` is the left channel, `mem_rdata[15:0]` the right).
//
// Where it sits in the radio
//   Fed by:  the DDR3 read lane (through the generic memory port below, which rtl/top/rd_word_adapter.v turns into one tier
//            of the read lane arbiter, rtl/ddr3/ddr3_read_arbiter.v) and the firmware's write pointer.
//   Feeds:   audio_interp_x8.v on a valid/ready stream (one sample per 48 kHz tick), and the HDMI and S/PDIF
//            path through a second, mirrored port (`hdmi_*`), see audio_out_src.v.
//   The same block, with its own ring, also reads the transmit baseband for tx_chain.v: left is then I and right is Q.
//
// Why a prefetch FIFO
//   A read from DDR3 goes through the lane arbiter and the memory controller and can take anything from a few
//   dozen to a few hundred clocks, depending on what the video reader is doing at that moment.  The audio
//   consumer, on the other hand, wants one sample at exact intervals (every 2,500 clocks of 120 MHz).  With
//   a few samples already waiting in the FIFO, a late DDR3 answer is invisible to the consumer, and only a ring
//   that firmware has not kept filled can run it empty.
//
// Memory port
//   Deliberately plain: one outstanding word read at a time, no assumed latency.  `mem_req` is a one-clock
//   pulse with the address in `mem_addr`, and `mem_rvalid` is a one-clock pulse when the answer is on `mem_rdata`.
//   The next request is only issued after the previous answer arrived, so the FIFO can never receive more words
//   than it has room for.  The addresses are word addresses: ring_base + (rd_ptr mod RING_SIZE_WORDS).
//
// Pointers
//   `wr_ptr` (from firmware) and `rd_ptr` (this module) are free-running word counters that are only masked to the
//   ring size when an address is formed, so wrapping around the end of the ring needs no special case.  The ring
//   counts as empty when the two are equal.
//
// Underrun
//   If the FIFO is empty when the interpolator asks for a sample, `smp_valid` is simply low on that clock.
//   audio_interp_x8.v then repeats its previous sample and pulses its own `underrun` output.  `low_water` (FIFO
//   fill at or below LOW_WATER samples) is the early warning, meant to drive a "ring is running dry" interrupt
//   through the register block.
//
// Latency and resources
//   A sample leaves the FIFO on the same clock the interpolator asks for it (the FIFO head is read directly,
//   so there is no pipeline stage), and the HDMI tap follows one clock later.  The FIFO is a small register array
//   of FIFO_DEPTH x 2 x 16 bits, no block RAM and no DSP block.

`timescale 1ns / 1ps

module audio_ring_reader #(
    // Sizes below are counted in stereo samples, one 32-bit DDR3 word each.  RING_SIZE_WORDS is the length of the
    // ring (512 words are 10.7 ms of audio at 48 kHz), FIFO_DEPTH is the depth of the prefetch FIFO, and
    // LOW_WATER is the fill at or below which `low_water` goes high.
    parameter integer ADDR_WIDTH      = 32,
    parameter integer RING_SIZE_WORDS = 512,   // must be a power of 2
    parameter integer FIFO_DEPTH      = 8,     // must be a power of 2
    parameter integer LOW_WATER       = 2
) (
    // Clock (clk_dsp, 120 MHz) and synchronous reset, active high.
    input  wire                    clk,
    input  wire                    rst,

    // Ring base (word address of the first sample) and the two pointers.  wr_ptr is written by firmware, rd_ptr
    // is this module's own read position.  Both are free-running sample counters, see the header.
    input  wire [ADDR_WIDTH-1:0]   ring_base,
    input  wire [ADDR_WIDTH-1:0]   wr_ptr,
    output reg  [ADDR_WIDTH-1:0]   rd_ptr,

    // Generic word read port to DDR3 (see the header): a one-clock request with its address, and a one-clock
    // answer carrying the 32-bit word.
    output reg                     mem_req,
    output reg  [ADDR_WIDTH-1:0]   mem_addr,
    input  wire                    mem_rvalid,
    input  wire [31:0]             mem_rdata,

    // 48 kHz sample stream to audio_interp_x8.v: smp_valid is high while the FIFO has a sample, smp_l and smp_r
    // show the oldest one (signed 16 bit), and the sample is taken on the clock where smp_ready is high too.
    output wire                    smp_valid,
    output wire signed [15:0]      smp_l,
    output wire signed [15:0]      smp_r,
    input  wire                    smp_ready,

    // HDMI tap: a copy of every sample taken above, delayed one clock.  hdmi_valid is a one-clock pulse, hdmi_l and
    // hdmi_r (signed 16 bit) hold the sample until the next pulse.
    output reg                     hdmi_valid,
    output reg  signed [15:0]      hdmi_l,
    output reg  signed [15:0]      hdmi_r,

    // Status: ring_empty is high while rd_ptr has caught up with wr_ptr, low_water while the FIFO holds
    // LOW_WATER samples or fewer.
    output wire                    ring_empty,
    output wire                    low_water
);

    // Width of the FIFO pointers, and the mask that wraps a pointer to the ring size.
    localparam integer FIFO_BITS = $clog2(FIFO_DEPTH);
    localparam [ADDR_WIDTH-1:0] RING_MASK = RING_SIZE_WORDS - 1;

    // ------------------------------------------------------------ prefetch FIFO
    // Prefetch FIFO, kept as two small register arrays (left and right).  fifo_head points at the oldest sample
    // (the one shown on smp_l and smp_r), fifo_tail at the next free entry, fifo_count holds the number of
    // samples stored.
    reg signed [15:0] fifo_l [0:FIFO_DEPTH-1];
    reg signed [15:0] fifo_r [0:FIFO_DEPTH-1];
    reg [FIFO_BITS:0]  fifo_count; // one extra bit so DEPTH itself is representable
    reg [FIFO_BITS-1:0] fifo_head, fifo_tail;

    wire fifo_full  = (fifo_count == FIFO_DEPTH);
    wire fifo_empty = (fifo_count == 0);

    assign smp_valid = !fifo_empty;
    assign smp_l      = fifo_l[fifo_head];
    assign smp_r      = fifo_r[fifo_head];
    assign low_water  = (fifo_count <= LOW_WATER);

    wire pop = smp_valid && smp_ready;

    // ------------------------------------------------------------ ring fetch state machine
    // Ring fetch state machine.  A request goes out when the FIFO has room, the ring has unread samples and
    // no earlier request is still waiting for its answer.
    assign ring_empty = (wr_ptr == rd_ptr);

    reg req_outstanding;
    wire can_issue = !fifo_full && !ring_empty && !req_outstanding;

    // Request side: form the address from the read pointer, pulse mem_req for one clock, and move rd_ptr on only
    // when the answer arrives (so a slow memory never makes the pointer run ahead of the data).
    always @(posedge clk) begin
        if (rst) begin
            rd_ptr          <= {ADDR_WIDTH{1'b0}};
            mem_req         <= 1'b0;
            mem_addr        <= {ADDR_WIDTH{1'b0}};
            req_outstanding <= 1'b0;
        end else begin
            mem_req <= 1'b0;
            if (can_issue) begin
                mem_addr        <= ring_base + (rd_ptr & RING_MASK);
                mem_req         <= 1'b1;
                req_outstanding <= 1'b1;
            end
            if (mem_rvalid) begin
                rd_ptr          <= rd_ptr + 1'b1;
                req_outstanding <= 1'b0;
            end
        end
    end

    // FIFO side: store an arriving word at the tail, take the oldest sample at the head when the consumer pops,
    // and keep the fill count and the HDMI copy up to date.

    always @(posedge clk) begin
        if (rst) begin
            fifo_count <= {(FIFO_BITS+1){1'b0}};
            fifo_head  <= {FIFO_BITS{1'b0}};
            fifo_tail  <= {FIFO_BITS{1'b0}};
            hdmi_valid <= 1'b0;
            hdmi_l     <= 16'sd0;
            hdmi_r     <= 16'sd0;
        end else begin
            hdmi_valid <= 1'b0;

            if (mem_rvalid) begin
                fifo_l[fifo_tail] <= mem_rdata[31:16];
                fifo_r[fifo_tail] <= mem_rdata[15:0];
                fifo_tail         <= fifo_tail + 1'b1;
            end

            if (pop) begin
                hdmi_valid <= 1'b1;
                hdmi_l     <= fifo_l[fifo_head];
                hdmi_r     <= fifo_r[fifo_head];
                fifo_head  <= fifo_head + 1'b1;
            end

            case ({mem_rvalid, pop})
                2'b10:   fifo_count <= fifo_count + 1'b1;
                2'b01:   fifo_count <= fifo_count - 1'b1;
                default: fifo_count <= fifo_count; // 00: no change, 11: one in one out
            endcase
        end
    end

endmodule
