// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ft8_slot_capture: writes each decoder receiver's 12 ksps audio into that receiver's own ring buffer in DDR3.
//
// What it does and why
//   FT8 works in 15-second slots (see ft8_frontend.v), and everything after the audio is derived from a whole slot
//   of it: the spectrogram, the sync search, the down-conversion of each candidate.  So the audio of the running slot
//   has to be kept somewhere, and 15 s of 16-bit samples at 12 ksps is 360 KB per receiver, far too much for block RAM
//   once there are eight receivers.  It goes to DDR3 instead.  The ring holds RING_SAMPLES samples per receiver
//   (a power of two, by default 2^19 = 524,288 samples = 43.7 s at 12 ksps, 1 MB), so more than two slots fit, and
//   a wrap-around is a plain mask of the pointer.  The pointer `wr_ptr` counts samples without bound.
//
// Where it sits in the radio
//   Fed by: the receiver back end's audio stream (ft8_frontend.v passes it on through ft8_spectrogram.v).
//   Feeds:  the DDR3 write lane (through ft8_ddr3_mux.v), and the write pointers to ft8_spectrogram.v and the firmware.
//   The ring is read back by ft8_slot_reader.v (for the spectrogram) and by the candidate engine (ft8_cand.v).
//
// Memory layout
//   Four samples per 64-bit lane word: sample p of the ring sits in lane word p / 4, in bits 16 (p mod 4) + 15 down to
//   16 (p mod 4).  Each sample is still written on its own, as a single beat with the byte mask selecting its 16-bit
//   lane, so it is in DDR3 as soon as it arrives.  Packing four to a word is what lets the candidate engine, which
//   replays the whole slot 240 times per slot, read 4 samples per DDR3 beat (docs/F7_CAND.md).
//
// Input and flow
//   The shared audio stream has one sample per `in_valid`, tagged with its receiver (`in_rx`).  A small FIFO (depth 8)
//   takes samples that arrive close together from different receivers, and the write side empties it one DDR3 write
//   (burst length 1) at a time.  At 8 receivers x 12 ksps the average rate is one sample per 1,250 clocks of 120 MHz,
//   and a write needs five clocks plus the arbiter's wait, so there is a lot of room.  If the FIFO ever is full, the
//   sample is dropped and the sticky flag `overflow` is set.
//
// Write port convention (rtl/ddr3/ddr3_write_arbiter.v, docs/F4_DDR.md): hold `req`, present `addr` and `burstlen`,
//   drive `wdata` and `wmask` combinationally, one clock per beat on `gnt`, and `done` when the burst is complete.

`timescale 1ns / 1ps

module ft8_slot_capture #(
    // NUM_RX is the number of decoder receivers, ADDR_WIDTH the DDR3 word address width, RING_SAMPLES the ring length
    // in samples (a power of two).  CFG_EXT = 1: the ring base of receiver `cfg_rx` arrives on `cfg_base` (a
    // LUT RAM read in the caller, taken into a register here in state SEL) and `ring_base` is not used.
    parameter integer NUM_RX      = 8,
    parameter integer ADDR_WIDTH  = 32,
    parameter integer RING_SAMPLES = 1 << 19, // must be a power of 2
    parameter integer CFG_EXT      = 0
) (
    // Clock (clk_dsp, 120 MHz) and synchronous reset (active high).
    input  wire        clk,
    input  wire        rst,

    // Shared 12 ksps audio input: one signed 16-bit sample of receiver in_rx (0..7) per in_valid pulse.
    input  wire        in_valid,
    input  wire [2:0]  in_rx,
    input  wire [15:0] in_sample,

    // Per-receiver configuration: enable (a disabled receiver's samples are ignored) and the ring base address
    // as a lane-word address.  They are plain ports, as in audio_ring_reader.v, and the caller owns the registers.
    input  wire [NUM_RX-1:0]            enable,
    input  wire [NUM_RX*ADDR_WIDTH-1:0] ring_base,   // per-receiver base, lane-word address
    // Base address look-up for CFG_EXT = 1 (see the parameters).
    output wire [2:0]                   cfg_rx,
    input  wire [ADDR_WIDTH-1:0]        cfg_base,

    // Per-receiver write pointer (samples written so far, free-running, the ring offset of the next sample is
    // wr_ptr mod RING_SAMPLES), read by the spectrogram scheduler and the firmware.
    output wire [NUM_RX*32-1:0]         wr_ptr,
    output reg                          overflow,    // sticky: a sample was dropped (FIFO full)

    // Write-lane client port (rtl/ddr3/ddr3_write_arbiter.v), shared with ft8_ring_writer.v through ft8_ddr3_writer.v.
    output reg                     req,
    output reg  [ADDR_WIDTH-1:0]   addr,
    output wire [7:0]              burstlen,
    output reg  [63:0]             wdata,
    output reg  [7:0]              wmask,
    input  wire                    gnt,
    input  wire                    done
);

    // Every write is one beat.
    assign burstlen = 8'd1;

    // Per-receiver write pointers, free-running sample counters into a power-of-two ring.
    reg [31:0] ptr [0:NUM_RX-1];
    genvar gp;
    generate
        for (gp = 0; gp < NUM_RX; gp = gp + 1) begin : g_ptr
            assign wr_ptr[gp*32 +: 32] = ptr[gp];
        end
    endgenerate

    // ---- input FIFO of (receiver, sample) pairs, 8 deep.  wp and rp are its write and read pointers, cnt the fill.
    localparam integer FW = 3 + 16;
    reg [FW-1:0] fifo [0:7];
    reg [3:0] wp, rp, cnt;
    wire full  = (cnt == 4'd8);
    wire empty = (cnt == 4'd0);
    wire pop;

    always @(posedge clk) begin
        if (rst) begin
            wp <= 4'd0; rp <= 4'd0; cnt <= 4'd0;
            overflow <= 1'b0;
        end else begin
            if (in_valid && enable[in_rx] && full) overflow <= 1'b1;
            if (in_valid && enable[in_rx] && !full) begin
                fifo[wp[2:0]] <= {in_rx, in_sample};
                wp <= wp + 4'd1;
            end
            if (pop) begin
                rp <= rp + 4'd1;
            end
            case ({in_valid && enable[in_rx] && !full, pop})
                2'b10: cnt <= cnt + 4'd1;
                2'b01: cnt <= cnt - 4'd1;
                default: ;
            endcase
        end
    end

    // The FIFO head: receiver number and sample.
    wire [FW-1:0] head    = fifo[rp[2:0]];
    wire [2:0]    head_rx = head[FW-1 -: 3];
    wire [15:0]   head_smp = head[15:0];

    // ---- write sequencer: one outstanding write at a time ----
    // IDLE takes the FIFO head.  SEL and SEL2 register that receiver's ring base and pointer: the 8-way select is done
    // in two registered steps (4-way, then 2-way), like cfg_lo and cfg_hi in ft8_spectrogram.v, because a one-step
    // select from cur_rx did not meet timing.  ADDR adds base and offset.  WAIT holds `req` until the single beat is
    // granted and takes the sample off the FIFO on `done`.  A sample takes five clocks, which is ample for 96 k
    // samples per second at most.
    localparam [2:0] IDLE = 3'd0, SEL = 3'd1, SEL2 = 3'd2, ADDR = 3'd3, WAIT = 3'd4;
    reg [2:0] state;
    integer r;
    reg [2:0] cur_rx;
    localparam integer CW = ADDR_WIDTH + 32;
    wire [CW-1:0] cfg [0:7];        // 8 entries whatever NUM_RX is: the ones that are not built are 0
    genvar gc;
    generate
        for (gc = 0; gc < NUM_RX; gc = gc + 1) begin : g_cfg
            assign cfg[gc] = {(CFG_EXT != 0) ? {ADDR_WIDTH{1'b0}} : ring_base[gc*ADDR_WIDTH +: ADDR_WIDTH], ptr[gc]};
        end
        for (gc = NUM_RX; gc < 8; gc = gc + 1) begin : g_cfg_off
            assign cfg[gc] = {CW{1'b0}};
        end
    endgenerate
    reg [CW-1:0] cfg_lo, cfg_hi;
    reg [ADDR_WIDTH-1:0] ext_q;
    assign cfg_rx = cur_rx;
    wire [CW-1:0] cfg_sel = cur_rx[2] ? cfg_hi : cfg_lo;
    reg [NUM_RX-1:0] cur_onehot;
    reg [ADDR_WIDTH-1:0] base_s;
    reg [31:0]           off_s, ptr_s, ptr_inc;
    // The pointer update is registered: `done` arrives combinationally through both write arbiters, and decoding
    // cur_rx into 8 x 32 write enables behind it did not meet timing.  The update lands in the IDLE clock after WAIT,
    // before SEL reads the pointer again.
    reg [NUM_RX-1:0]     bump;

    // Take the sample off the FIFO in the same clock as `done`, not one later: a registered pop would leave the FIFO
    // count and read pointer stale for the IDLE clock that follows, and the old head would be sent again as a new sample.
    assign pop = (state == WAIT) && done;

    // Sequencer.  The sample is replicated into all four 16-bit lanes (wdata) and the mask (wmask) picks the lane of
    // pointer mod 4.  The address is the ring base plus the pointer mod RING_SAMPLES, divided by 4 (a lane word index).

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            req   <= 1'b0;
            for (r = 0; r < NUM_RX; r = r + 1) ptr[r] <= 32'd0;
            bump  <= {NUM_RX{1'b0}};
        end else begin
            bump <= {NUM_RX{1'b0}};
            for (r = 0; r < NUM_RX; r = r + 1)
                if (bump[r]) ptr[r] <= ptr_inc;
            case (state)
                IDLE: begin
                    if (!empty) begin
                        cur_rx <= head_rx;
                        wdata  <= {4{head_smp}};
                        state  <= SEL;
                    end
                end
                SEL: begin
                    cfg_lo     <= cfg[{1'b0, cur_rx[1:0]}];
                    cfg_hi     <= cfg[{1'b1, cur_rx[1:0]}];
                    ext_q      <= cfg_base;
                    cur_onehot <= {{(NUM_RX-1){1'b0}}, 1'b1} << cur_rx;
                    state      <= SEL2;
                end
                SEL2: begin
                    base_s <= (CFG_EXT != 0) ? ext_q : cfg_sel[CW-1 -: ADDR_WIDTH];
                    off_s  <= (cfg_sel[31:0] & (RING_SAMPLES - 1)) >> 2;
                    ptr_s  <= cfg_sel[31:0];
                    case (cfg_sel[1:0])
                        2'd0:    wmask <= 8'b0000_0011;
                        2'd1:    wmask <= 8'b0000_1100;
                        2'd2:    wmask <= 8'b0011_0000;
                        default: wmask <= 8'b1100_0000;
                    endcase
                    state  <= ADDR;
                end
                ADDR: begin
                    addr    <= base_s + off_s;
                    ptr_inc <= ptr_s + 32'd1;
                    req     <= 1'b1;
                    state <= WAIT;
                end
                WAIT: begin
                    if (gnt) begin
                        req <= 1'b0;
                    end
                    if (done) begin
                        bump  <= cur_onehot;
                        state <= IDLE;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end

endmodule
