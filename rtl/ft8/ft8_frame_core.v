// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ft8_frame_core: the 3,840-point transform of one spectrogram frame, built from 15 transforms of 256 points.
//
// Background
//   Each spectrogram line (ft8_spectrogram.v) is the spectrum of 1,920 audio samples (one FT8 symbol) zero-padded to
//   3,840, so that the bins are 3.125 Hz apart.  3,840 is 256 x 15, which is not a power of two, so the usual
//   radix-2 FFT cannot do it directly.  The index trick (the Cooley-Tukey factorization, glossary "FFT" in
//   docs/learn/GLOSSARY.md) splits it into small pieces: write the sample index as n = 15 n2 + n1 (n1 = 0 .. 14,
//   n2 = 0 .. 255) and the bin as k = 256 k2 + k1 (k1 = 0 .. 255).  Then
//        X[k] = sum over n1 of  W^(n1 k) x Y_n1[k1],     W = e^(-j 2 pi / 3840),
//   where Y_n1 is the ordinary 256-point FFT of the samples u[n2] = a[15 n2 + n1], that is every 15th sample starting
//   at n1.  So the frame needs 15 FFTs of 256 points (one per n1) and then, for each wanted bin, a sum of 15 products
//   with twiddle factors W^(n1 k), which is done in ft8_combine.v.  Samples at index 1,920 and above are zero (the
//   padding), so half of every 256-point input is zeros.
//
// What it does
//   The caller loads the frame's 1,920-sample window into the input buffer (`buf_wr_*`) and pulses `frame_start`.  For
//   n1 = 0 .. 14 this module then streams u[n2] = buf[15 n2 + n1] (zero for 15 n2 + n1 >= 1,920, n2 = 0 .. 255) into the
//   FFT at a fixed pace (one sample every FEED_PERIOD clocks; gaps are fine, see rtl/fft/fft_r22sdf.v), and forwards
//   the FFT's output stream, tagged with the n1 it belongs to, through a small FIFO into ft8_combine.v.  `frame_done`
//   pulses once ft8_combine.v has taken in the last (n1 = 14) result and its pipeline is empty.  ft8_power.v then
//   reads the finished sums through `rd_*`, which this module passes straight through to the combine block.
//
// Where it sits in the radio
//   Fed by: ft8_slot_reader.v.  Feeds: ft8_power.v, through ft8_combine.v.  One instance serves all receivers
//   (ft8_spectrogram.v).  The FFT is the same rtl/fft/fft_r22sdf.v as in the full-band spectrum, with LOG_N = 8 and 16-bit
//   real input (its imaginary input is tied to 0).
//
// Why 16 blocks and a flush
//   fft_r22sdf.v is a streaming FFT with exactly one output word per input word, and output word j (counted from
//   reset) holds frame position (j - 255) mod 256.  So the transform of input block b comes out while input block
//   b + 1 is being fed: a block's outputs are pushed out by the next 256 inputs, and not just by the pipeline's clock
//   latency.  A burst of 15 blocks would leave the bins 1 .. 255 of the 15th block stuck inside the FFT.  Each frame
//   therefore feeds 16 blocks: n1 = 0 .. 14 and one zero "flush" block (n1 = 15) whose only job is to push block 14
//   out.  Every frame is then a whole number of 256-sample blocks, so input and output block numbers stay aligned
//   from reset on.  The output side counts blocks modulo 16 on `out_first` and drops the flush block's outputs, which
//   are all zero (the 255 words that the FFT suppresses after reset do not belong to any block, so no warm-up is needed).
//
// Time
//   FEED_PERIOD sets the pace and is not a data dependency.  It is above ft8_combine.v's minimum spacing of 4 clocks,
//   so that the FIFO of 8 never has to push back on the feed.  A frame takes 16 x 256 x FEED_PERIOD = 32,768 clocks of
//   feed (0.27 ms at 120 MHz) plus a few clocks for the combine stage to drain.
`timescale 1ns / 1ps
// TR_FFT_INCLUDED is set by a file list that already holds the FFT sources (rtl/spectrum/spectrum_pipeline.v includes them
// too, and rtl/fft has no include guards).
`ifndef TR_FFT_INCLUDED
`include "rtl/fft/fft_delay.v"
`include "rtl/fft/fft_bf.v"
`include "rtl/fft/fft_mul.v"
`include "rtl/fft/fft_twmul.v"
`include "rtl/fft/fft_r22sdf.v"
`endif
`include "rtl/ft8/ft8_combine.v"

module ft8_frame_core #(
    // FEED_PERIOD: clocks per FFT input sample (8).  TW_DIR: folder of the FFT's twiddle tables.  W3840_ROM: the
    // first-octant table of the 3,840-point twiddle factors for ft8_combine.v.
    parameter integer FEED_PERIOD = 8,
    parameter         TW_DIR      = "rtl/fft/tw/",
    parameter         W3840_ROM   = "rtl/ft8/rom/ft8_w3840_oct.hex"
) (
    // Clock (clk_dsp, 120 MHz) and synchronous reset (active high).
    input  wire        clk,
    input  wire        rst,

    // Input window load: one sample per clock with its index 0 .. 1,919 (from the slot reader).  Samples beyond the
    // slot's audio have to be loaded as zero.
    input  wire        buf_wr_en,
    input  wire [10:0] buf_wr_addr,   // 0 .. 1,919
    input  wire [15:0] buf_wr_data,

    // frame_start: one-clock start pulse.  frame_busy is high from the start until the sums are complete, and
    // frame_done is a one-clock pulse at the end.
    input  wire        frame_start,
    output reg         frame_busy,
    output reg         frame_done,

    // Read-out of the finished sums (ft8_power.v), passed through to the combine block: one bin address per clock, two clocks
    // of latency, 44 bit signed real and imaginary parts.
    input  wire        rd_en,
    input  wire [9:0]  rd_addr,
    output wire signed [43:0] rd_re,
    output wire signed [43:0] rd_im
);

    // NSPS: samples per symbol and window (160 ms at 12 ksps).  N256: points of each partial transform.
    localparam integer NSPS = 1920;
    localparam integer N256 = 256;

    // ================================================================ input window buffer
    // 1,920 x 16 bit (a block RAM), written by the slot reader and read by the feed sequencer.
    reg [15:0] abuf [0:NSPS-1];
    always @(posedge clk) if (buf_wr_en) abuf[buf_wr_addr] <= buf_wr_data;

    // ================================================================ sample-feed sequencer
    // Sample feed sequencer: n1 and n2 are the block and the position inside it, pace counts the FEED_PERIOD clocks
    // between samples, and `running` is high while samples are fed.
    reg [3:0]  n1;             // 0 .. 14
    reg [7:0]  n2;             // 0 .. 255
    reg [7:0]  pace;
    reg        running;
    // Fan-out capped (Gowin duplicates the register): inside the FFT this net feeds the first
    // delay line's LUT-RAM read address, and its routing alone was 3.8 ns of a failing path.
    reg        fft_in_valid /* synthesis syn_maxfan = 10000 */;
    reg signed [15:0] fft_in_re;

    // samp_idx is the buffer address 15 n2 + n1.  It runs from 0 to 3,824 + 14 = 3,839 and so needs 12 bits (with 11 bits an
    // index above 2,047 would wrap into the buffer's valid range instead of failing the >= 1,920 zero-pad test, and about half
    // of every partial transform would be fed garbage instead of zeros).  It is a register that is stepped along (plus 15 per
    // sample, and n1 + 1 at a new block) and not computed as 15 n2 + n1 in front of the buffer's address port.

    reg  [11:0] samp_idx;
    // n1 == 15 is the zero flush block (module header)
    wire        samp_in_range = (n1 != 4'd15) && (samp_idx < 12'd1920);

    // frame_busy and frame_done are each driven in one place only (the FIFO and combine section below read comb_ev_ready
    // and so on but never assign them).

    // ================================================================ 256-point FFT (rtl/fft/fft_r22sdf.v, unmodified)
    wire        fft_out_valid, fft_out_first;
    wire [7:0]  fft_out_index;
    wire [7:0]  fft_out_bin;
    wire signed [23:0] fft_out_re, fft_out_im;

    // Instance attributes (GowinSynthesis applies them to everything below this instance,
    // SUG550 section 5, without touching rtl/fft): the core's delay lines are small here (the
    // largest is 128 x 34 bits), and as block RAM they would cost 16 BSRAM blocks, because the shift registers of 8 to
    // 32 words were each turned into 32-bit block RAMs that count 2 each.  So the shift registers are kept in
    // flip-flops by the instance attributes (as LUT RAM they became 17-level logic paths), and the two RAM delay lines
    // (128 and 64 words deep) are partly LUT RAM.
    // REAL_IN = 1: the input is real (the imaginary part is 0), and the core's real-input mode computes the same values as
    // its complex mode with a zero imaginary input (the imaginary half of the first delay line would always be zero), while
    // storing only the real half.  That halves the 128-deep line to 17 bits, which is what let its LUT-RAM read meet timing (at
    // 34 bits it did not).  The testbenches check this bit for bit against the complex mode.
    // SR_LUT = 1: the 4- to 32-word delay lines of stages 3 to 6 are LUT RAM (as in the full-band spectrum's FFT, where they
    // run at a sample per clock) instead of 2,600 flip-flops.  The 64-deep line is LUT RAM by rtl/fft/fft_delay.v's own
    // attribute, and the 128 x 17 line becomes one block RAM (as LUT RAM its write pointer to read register path did not meet
    // timing).  syn_maxfan limits the fan-out of the enables, which otherwise reach over 1,000 flip-flops.
    (* syn_maxfan = 10000 *)
    // The instance name u_ft8fft is what rtl/ft8/ft8_spectrogram.sdc matches: this FFT gets one
    // sample every FEED_PERIOD clocks, so its butterflies are two-clock paths (that file).
    fft_r22sdf #(.LOG_N(8), .IW(16), .REAL_IN(1), .TW_DIR(TW_DIR), .SR_LUT(1), .TW_M1_ONE(1)) u_ft8fft (
        .clk(clk), .rst(rst),
        .in_valid(fft_in_valid), .in_re(fft_in_re), .in_im(16'sd0),
        .out_valid(fft_out_valid), .out_first(fft_out_first),
        .out_index(fft_out_index), .out_bin(fft_out_bin),
        .out_re(fft_out_re), .out_im(fft_out_im)
    );

    // Which block (n1 = 0 .. 15, 15 = the flush block) the FFT's current output belongs to: `out_first` opens a new output
    // block, `out_blk` holds the block of the most recent `out_first` and starts at 15 so that the first block after reset
    // is 0.  The FFT output is registered once together with its tag before it goes into the FIFO.
    reg  [3:0] out_blk;
    wire [3:0] tag_now  = fft_out_first ? out_blk + 4'd1 : out_blk;
    always @(posedge clk) begin
        if (rst)                                 out_blk <= 4'd15;
        else if (fft_out_valid && fft_out_first) out_blk <= out_blk + 4'd1;
    end
    // out_keep: this output word belongs to a real block (not the flush block).  out_last: it is the frame's last word
    // (n1 = 14, bin 255).  out_tag, out_bin_q, out_re_q and out_im_q: the block, the bin and the 24-bit real and imaginary parts.
    reg        out_keep;
    reg        out_last;          // the frame's last event: n1 = 14, bin 255
    reg [3:0]  out_tag;
    reg [7:0]  out_bin_q;
    reg signed [23:0] out_re_q, out_im_q;
    always @(posedge clk) begin
        out_keep  <= !rst && fft_out_valid && (tag_now != 4'd15);
        out_last  <= (tag_now == 4'd14) && (fft_out_bin == 8'd255);
        out_tag   <= tag_now;
        out_bin_q <= fft_out_bin;
        out_re_q  <= fft_out_re;
        out_im_q  <= fft_out_im;
    end

    // ================================================================ output FIFO
    // Eight entries of (n1, bin, re, im), 4 + 8 + 24 + 24 bits, between the FFT and the combine stage.  Because the feed
    // is slower than the combine stage can work, it stays almost empty.
    localparam integer FW = 4 + 8 + 24 + 24;
    reg [FW-1:0] fifo [0:7];
    reg [3:0] fifo_wp, fifo_rp;
    reg [3:0] fifo_cnt;
    wire fifo_full  = (fifo_cnt == 4'd8);
    wire fifo_empty = (fifo_cnt == 4'd0);

    // The FIFO head as the event that the combine stage sees.
    wire [FW-1:0] fifo_head = fifo[fifo_rp[2:0]];
    wire comb_ev_valid = !fifo_empty;
    wire comb_ev_ready;
    wire [3:0] head_n1  = fifo_head[FW-1 -: 4];
    wire [7:0] head_bin = fifo_head[FW-5 -: 8];
    wire signed [23:0] head_re = fifo_head[47:24];
    wire signed [23:0] head_im = fifo_head[23:0];

    // FIFO write and read.
    always @(posedge clk) begin
        if (rst) begin
            fifo_wp  <= 4'd0;
            fifo_rp  <= 4'd0;
            fifo_cnt <= 4'd0;
        end else begin
            // fifo_full is not expected, given FEED_PERIOD's margin (ft8_combine.v takes one event every 4 clocks); it is
            // guarded anyway, so that a violated assumption shows up as a stuck frame and not as an overwritten entry.
            if (out_keep && !fifo_full) begin
                fifo[fifo_wp[2:0]] <= {out_tag, out_bin_q, out_re_q, out_im_q};
                fifo_wp <= fifo_wp + 4'd1;
            end
            if (comb_ev_valid && comb_ev_ready) begin
                fifo_rp <= fifo_rp + 4'd1;
            end
            case ({out_keep && !fifo_full, (comb_ev_valid && comb_ev_ready)})
                2'b10: fifo_cnt <= fifo_cnt + 4'd1;
                2'b01: fifo_cnt <= fifo_cnt - 4'd1;
                default: ;
            endcase
        end
    end

    // ================================================================ combine (shared instance)
    // The combine stage: accumulates W^(n1 k) x Y_n1[k1] into the 1,024 bins.
    wire comb_idle;
    ft8_combine #(.ROM_FILE(W3840_ROM)) u_combine (
        .clk(clk), .rst(rst),
        .ev_valid(comb_ev_valid), .ev_ready(comb_ev_ready),
        .ev_n1(head_n1), .ev_k1(head_bin), .ev_yr(head_re), .ev_yi(head_im),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_re(rd_re), .rd_im(rd_im),
        .idle(comb_idle)
    );

    // ================================================================ sequencer / frame_busy / frame_done
    // One always block drives frame_busy, running and frame_done together.  frame_start begins a frame (n1 = 0 .. 15 and
    // n2 = 0 .. 255 at one sample every FEED_PERIOD clocks into the FFT, with n1 = 15 the zero flush block).  frame_busy drops
    // and frame_done pulses once combine has accepted the very last event (n1 = 14, bin 255), the output FIFO has drained and
    // the combine pipeline is idle.
    reg saw_last_n1_event;
    reg drained;
    always @(posedge clk) drained <= !rst && !running && fifo_empty && comb_idle && !out_keep;
    // Input buffer read, then the FFT input one clock later: a plain registered block RAM read, with the zero-pad select
    // after it and not in front of it.
    wire       feed_now = running && (pace == FEED_PERIOD - 1);   // sample (n1, n2) this clock
    reg        feed_rd_q, feed_zero_q;
    reg [15:0] abuf_q;
    always @(posedge clk) begin
        abuf_q       <= abuf[samp_idx[10:0]];
        feed_rd_q    <= feed_now && !rst;
        feed_zero_q  <= !samp_in_range;
        fft_in_valid <= feed_rd_q && !rst;
        fft_in_re    <= feed_zero_q ? 16'sd0 : abuf_q;
    end

    // Sequencer: counts the feed (pace, n2, n1, and the buffer address samp_idx) and decides when the frame is done.
    always @(posedge clk) begin
        frame_done   <= 1'b0;
        if (rst) begin
            running           <= 1'b0;
            frame_busy        <= 1'b0;
            saw_last_n1_event <= 1'b0;
        end else begin
            if (frame_start && !frame_busy) begin
                frame_busy <= 1'b1;
                saw_last_n1_event <= 1'b0;
                running <= 1'b1;
                n1   <= 4'd0;
                n2   <= 8'd0;
                samp_idx <= 12'd0;
                pace <= 8'd0;
            end else if (running) begin
                if (pace == FEED_PERIOD - 1) begin
                    pace <= 8'd0;
                    if (n2 == 8'd255) begin
                        n2 <= 8'd0;
                        n1 <= n1 + 4'd1;
                        samp_idx <= {8'd0, n1} + 12'd1;
                        if (n1 == 4'd15) running <= 1'b0;   // flush block fed
                    end else begin
                        n2 <= n2 + 8'd1;
                        samp_idx <= samp_idx + 12'd15;
                    end
                end else begin
                    pace <= pace + 8'd1;
                end
            end

            // Set when the frame's last event (n1 = 14, bin 255) enters the FIFO, and not when combine takes it (that
            // compare sat behind the FIFO's LUT-RAM read and did not meet timing).  The frame_done condition below still
            // waits for the FIFO to empty and for combine to be idle.
            if (out_keep && out_last) begin
                saw_last_n1_event <= 1'b1;
            end
            // Waiting for comb_ev_ready alone is not enough: it only says that the event expander can take the next event,
            // while the four sub-events of the last event can still be draining through the twiddle lookup and the
            // multiply-accumulate for a few more clocks.  An early frame_done would let ft8_power.v start reading the sums
            // through the same shared read port that those sub-events still need, and corrupt exactly the bins whose last
            // (n1 = 14) contribution had not landed yet.  comb_idle covers the whole pipeline.  `drained` is registered,
            // and it excludes a clock with a push in progress, so a one-clock-old "empty" cannot race the push of the last event.
            if (saw_last_n1_event && drained) begin
                frame_done        <= 1'b1;
                frame_busy        <= 1'b0;
                saw_last_n1_event <= 1'b0;
            end
        end
    end

endmodule
