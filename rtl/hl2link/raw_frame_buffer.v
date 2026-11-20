// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Raw-frame sample staging: unpacks the sample bytes of a raw frame into 12-bit samples, keeps
// them in a ring while the frame's CRC is still being checked, and, for a frame that turns out to
// be good, drains them across the clock boundary to clk_dsp (docs/ARCHITECTURE.md 3.1 steps 3
// and 4, up to but not including the gap filler, which is gap_filler.v).
//
// Where it sits: eth_frame_rx.v (clk_rx) gives it the sample bytes of every raw frame as they
// arrive (`raw_sof`, `sample_valid`, `sample_data`), and four clocks after the last content byte
// the verdict (`commit` if the CRC was good). The output is two FIFO read ports in clk_dsp, which
// gap_filler.v pops.
//
// How the samples are packed: the Hermes-Lite 2 sends two 12-bit samples in every three bytes
// (docs/rawfront/PROTOCOL.md 5.2): `a[11:4]`, then `{a[3:0], b[11:8]}`, then `b[7:0]`, with `a`
// the earlier sample. The unpacker below writes one finished sample per clock into the ring at the
// current write pointer: sample `a` is complete as soon as the second byte of its group arrives
// (the first byte plus the high nibble of the second), and sample `b` as soon as the third byte
// arrives. So the two samples of a group are written in two different clocks and never both in the
// same one, which is what a single block RAM write port wants.
//
// The ring: one ring of 8,192 samples with one write port (the unpacker) and one registered read
// port (the drain sequencer below), which is the standard two-port block RAM (BSRAM) shape of the
// Gowin chip. A frame drains into the sample FIFO at 125 M samples/s (one clk_rx clock per
// sample), while the next frame's bytes arrive at 83 M samples/s (three bytes in three clocks
// give two samples), so 8,192 / 5,968 = 1.37 frames of ring space is always enough margin between
// the write side and the read side: the write side never has to wait for the read side, and never
// overtakes it either. The write pointer advances continuously across frames and is never reset.
//
// What commit means: a frame's samples are written into the ring as they arrive, before anyone
// knows whether the frame is good. They are only drained, so only reach clk_dsp, if eth_frame_rx.v
// pulses `commit` for that frame (CRC good, classified raw, length right). An uncommitted frame's
// samples just sit in the ring until the write pointer wraps back over them, which is how a bad or
// lost frame turns into nothing here, and so into a gap, which gap_filler.v then sees and fills
// with zeros.
//
// Two asynchronous FIFOs (cdc_sample_fifo.v, which explains how a FIFO crosses clocks) take the
// data to clk_dsp:
//   - the sample stream itself, one word per sample, tagged with `sof` on a committed frame's
//     first sample;
//   - a much shallower "frame index" stream, one word per committed frame, carrying only its
//     48-bit first-sample index. gap_filler.v pops one word from this FIFO exactly when it pops
//     an `sof`-tagged sample from the other one, so the two stay matched however far either
//     FIFO backs up. A single mailbox register (cdc_word.v) would not survive a backlog of more
//     than one frame, which is why this is a real FIFO.
//
// Loss counters (docs/HL2_SFP.md section 6; they stop at 0xFFFF): `cnt_drain_drops` counts
// committed frames that were not drained because the previous frame was still draining,
// `cnt_overruns` counts samples overwritten before they were drained, and `cnt_idx_drops` counts
// frame indices lost because the index FIFO was full. In normal operation all three stay at zero.

`timescale 1ns / 1ps

module raw_frame_buffer #(
    parameter MAX_N    = 5968,   // PROTOCOL.md 5.1: samples per frame is cut to 5,968
    parameter BANK_AW  = 13,     // 2**13 = 8192 > MAX_N: the whole ring
    parameter SAMP_AW  = 10,     // sample FIFO depth 2**10 = 1024 samples
    parameter IDX_AW   = 4       // frame-index FIFO depth 2**4 = 16 frames
) (
    // -------- clk_rx (eth_frame_rx.v) --------
    input  wire        clk_rx,        // Ethernet receive clock, 125 MHz
    input  wire        rst_rx,        // synchronous reset for the clk_rx domain, active high

    input  wire         raw_sof,          // pulse: a raw frame starts (its first byte, UDP payload byte 0)
    input  wire          sample_valid,    // sample_data is a sample byte this clock
    input  wire [ 7:0]   sample_data,     // one sample byte (three of them make two samples)
    input  wire          commit,          // pulse after the frame's last byte: CRC good, drain this frame
    input  wire [47:0]   commit_first_idx, // header: index of the frame's first sample
    input  wire [15:0]   commit_n,        // header: number of samples in the frame

    output reg  [31:0]  cnt_committed_samples,   // samples sent on to clk_dsp, since reset
    // loss accounting (docs/HL2_SFP.md section 6; stop at 0xFFFF)
    output reg  [15:0]  cnt_drain_drops = 16'd0,  // committed frames not drained: the previous one was still draining
    output reg  [15:0]  cnt_overruns = 16'd0,     // samples written over one not yet drained (ring overrun)
    output reg  [15:0]  cnt_idx_drops = 16'd0,    // frame indices lost because the index FIFO was full

    // -------- clk_dsp (gap_filler.v) --------
    input  wire        clk_dsp,       // 120 MHz
    input  wire        rst_dsp,       // synchronous reset for the clk_dsp domain, active high

    input  wire          samp_pop,         // read one sample word
    output wire            samp_sof,       // the sample is the first of a committed frame
    output wire [11:0]     samp_data,      // 12-bit two's complement sample
    output wire             samp_valid,   // registered fifo output valid one cycle after samp_pop

    input  wire          idx_pop,          // read one frame index word
    output wire [47:0]     idx_data,       // first-sample index of a committed frame
    output wire             idx_valid      // idx_data is valid (one clock after idx_pop, if the FIFO was not empty)
) /* synthesis syn_srlstyle = "registers" */;

    // One ring, one write port (this unpacker) and one registered read port (the drain sequencer
    // below), see the header.
    reg [11:0] mem [0:(1<<BANK_AW)-1];

    // -----------------------------------------------------------------
    // The 3-byte to two 12-bit sample unpacker, described in the header. `phase` says which of the
    // three bytes of a group comes next, `byte0` and `byte1` hold the earlier bytes of the group,
    // and `wr_en_bank` and `wr_data_bank` are the registered write into the ring.
    reg [1:0] phase = 2'd0;   // 0,1,2 within each 3-byte group
    reg [7:0] byte0, byte1;

    reg [BANK_AW-1:0] wp = {BANK_AW{1'b0}};        // continuous ring write pointer
    reg [BANK_AW-1:0] frame_start = {BANK_AW{1'b0}}; // wp as of this frame's raw_sof, for the drain
                                                       // sequencer to know where it starts
    reg          wr_en_bank;
    reg [11:0]   wr_data_bank;

    always @(posedge clk_rx) begin
        wr_en_bank <= 1'b0;
        if (raw_sof) begin
            phase       <= 2'd0;
            frame_start <= wp;
        end else if (sample_valid) begin
            case (phase)
                2'd0: begin
                    byte0 <= sample_data;
                    phase <= 2'd1;
                end
                2'd1: begin
                    byte1        <= sample_data;
                    wr_en_bank   <= 1'b1;
                    wr_data_bank <= {byte0, sample_data[7:4]};   // sample a
                    phase        <= 2'd2;
                end
                default: begin
                    wr_en_bank   <= 1'b1;
                    wr_data_bank <= {byte1[3:0], sample_data};   // sample b
                    phase        <= 2'd0;
                end
            endcase
        end
    end

    // wp advances together with each write that `wr_en_bank` marks (one sample per clock, see the
    // header). It wraps by itself, since it is BANK_AW bits wide and the ring size is an exact
    // power of two.
    always @(posedge clk_rx) begin
        if (wr_en_bank) wp <= wp + 1'b1;
    end

    always @(posedge clk_rx) begin
        if (wr_en_bank) mem[wp] <= wr_data_bank;
    end

    // -----------------------------------------------------------------
    // Commit and drain sequencer (clk_rx side): it reads the just-finished frame's samples
    // (addresses `frame_start` to `frame_start + commit_n - 1`, wrapping in the ring) one after
    // another into the sample FIFO. `commit` follows the raw_sof that started this same frame
    // with nothing else in between (frames do not overlap on the wire), so `frame_start` still
    // holds this frame's first address when `commit` arrives.
    //
    // The read is registered and unconditional (`mem_q <= mem[dp]` in every clock, with no
    // enable), which is the shape of a block RAM with a registered read, and it is deliberately
    // kept in a memory-only always block below with nothing else in it: mixing the state machine's
    // bookkeeping into the same block as the memory access stops the tools from using block RAM
    // and makes them build the 8,192 samples out of tens of thousands of flip-flops instead.
    // `dp` only changes when `can_advance` says so. `q_pend_valid` and `q_pend_first` are
    // `can_advance` and `is_first` delayed by one clock, to land on the same clock in which `mem_q`
    // (also one clock behind `dp`) becomes meaningful.
    //
    // Stalling: by the time a fetched word shows up in `mem_q`, `dp` has already moved past it, so
    // holding `dp` does not keep that word, and the next clock's `mem_q` is the following sample.
    // A fetched word that the FIFO has no room for is therefore parked in `hold_q` (one word is
    // enough, since no new fetch starts while it is occupied) and written from there once there is
    // room. Dropping it instead would lose one sample every time the sample FIFO filled.
    reg         draining = 1'b0;      // a committed frame is being drained
    reg [BANK_AW-1:0] dp;             // ring read address
    reg [BANK_AW-1:0] drain_start;    // address of the draining frame's first sample
    reg [15:0]  remaining;            // samples of the frame still to fetch
    reg [47:0]  drain_first_idx;      // index of the draining frame's first sample

    reg         q_pend_valid = 1'b0;  // mem_q holds a fetched sample this clock
    reg         q_pend_first;         // ... and it is the frame's first sample
    wire [11:0] mem_q;

    reg         hold_valid = 1'b0;   // a fetched sample waiting for room in the CDC fifo
    reg         hold_first;
    reg [11:0]  hold_q;

    reg         fifo_wr;              // write to the sample FIFO
    reg [12:0]  fifo_wdata;           // {first-sample tag, sample}
    wire        fifo_wr_full;

    reg         idx_send;             // write to the index FIFO
    wire        idx_fifo_wfull;
    reg [47:0]  idx_send_data;

    // fifo_wr_full already accounts for the write that fifo_wr is making in this clock (the
    // write-side contract of cdc_sample_fifo.v), so "not full" here means that the write issued
    // below, next clock, fits.
    wire have_word    = hold_valid || q_pend_valid;   // never both (see can_advance)
    wire do_consume   = have_word && !fifo_wr_full;
    wire can_advance  = draining && (remaining != 16'd0) && (!have_word || do_consume);
    wire        out_first = hold_valid ? hold_first : q_pend_first;
    wire [11:0] out_q     = hold_valid ? hold_q     : mem_q;
    wire is_first     = (dp == drain_start);

    always @(posedge clk_rx) begin
        fifo_wr  <= 1'b0;
        idx_send <= 1'b0;

        if (rst_rx) begin
            draining     <= 1'b0;
            q_pend_valid <= 1'b0;
            hold_valid   <= 1'b0;
            cnt_committed_samples <= 32'd0;
            cnt_drain_drops <= 16'd0; cnt_overruns <= 16'd0; cnt_idx_drops <= 16'd0;
        end else begin
            // Push the previously fetched sample (the parked one, else mem_q, one clock behind
            // dp) into the CDC FIFO, if there is one and it fits. The first sample of a frame also
            // sends the frame's index to the index FIFO.
            if (do_consume) begin
                fifo_wr    <= 1'b1;
                fifo_wdata <= {out_first, out_q};
                if (out_first) begin
                    idx_send      <= 1'b1;
                    idx_send_data <= drain_first_idx;
                end
                cnt_committed_samples <= cnt_committed_samples + 32'd1;
            end

            // A second commit that arrives before this one has finished draining is dropped (the
            // margin of the ring holds for every N the protocol allows, so it should not happen).
            // The loss counters are updated here too.
            if (commit && draining && (cnt_drain_drops != 16'hFFFF)) cnt_drain_drops <= cnt_drain_drops + 16'd1;
            if (wr_en_bank && draining && (wp == dp) && (cnt_overruns != 16'hFFFF)) cnt_overruns <= cnt_overruns + 16'd1;
            if (idx_send && idx_fifo_wfull && (cnt_idx_drops != 16'hFFFF)) cnt_idx_drops <= cnt_idx_drops + 16'd1;
            if (commit && !draining) begin
                draining        <= 1'b1;
                dp              <= frame_start;
                drain_start     <= frame_start;
                remaining       <= commit_n;
                drain_first_idx <= commit_first_idx;
            end else if (can_advance) begin
                dp        <= dp + 1'b1;
                remaining <= remaining - 16'd1;
                if (remaining == 16'd1) draining <= 1'b0;
            end

            // Park a just fetched word that the FIFO had no room for, and release it once it has
            // been written.
            if (q_pend_valid && !do_consume) begin
                hold_valid <= 1'b1;
                hold_q     <= mem_q;
                hold_first <= q_pend_first;
            end else if (hold_valid && do_consume) begin
                hold_valid <= 1'b0;
            end

            // One clock behind can_advance and is_first, landing together with mem_q.
            q_pend_valid <= can_advance;
            q_pend_first <= is_first;
        end
    end

    // The memory-only port: an unconditional read, with nothing else in this block (see the
    // comment above).
    reg [11:0] mem_q_r;
    always @(posedge clk_rx) mem_q_r <= mem[dp];
    assign mem_q = mem_q_r;

    // The sample FIFO to clk_dsp. REG_FULL is set, so that its full flag comes from a register
    // (cdc_sample_fifo.v explains why).
    wire [12:0] samp_rd_data;
    assign samp_sof  = samp_rd_data[12];
    assign samp_data = samp_rd_data[11:0];

    cdc_sample_fifo #(.W(13), .AW(SAMP_AW), .REG_FULL(1)) samp_fifo_i (
        .wr_clk (clk_rx),  .wr_rst(rst_rx),  .wr_en(fifo_wr),  .wr_data(fifo_wdata), .wr_full(fifo_wr_full),
        .rd_clk (clk_dsp), .rd_rst(rst_dsp), .rd_en(samp_pop), .rd_data(samp_rd_data),
        .rd_valid(samp_valid), .rd_empty()
    );

    // The frame-index FIFO (16 frames) is not expected to fill. A write into a full one is lost
    // and counted (cnt_idx_drops; idx_fifo_wfull is declared next to idx_send above).
    cdc_sample_fifo #(.W(48), .AW(IDX_AW)) idx_fifo_i (
        .wr_clk (clk_rx),  .wr_rst(rst_rx),  .wr_en(idx_send), .wr_data(idx_send_data), .wr_full(idx_fifo_wfull),
        .rd_clk (clk_dsp), .rd_rst(rst_dsp), .rd_en(idx_pop),  .rd_data(idx_data),
        .rd_valid(idx_valid), .rd_empty()
    );

endmodule
