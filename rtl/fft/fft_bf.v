// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// fft_bf: one radix-2 butterfly stage of the streaming FFT (docs/F1_FFT.md), in the "single-path
// delay feedback" form. A butterfly combines two samples that are L samples apart in the stream,
// giving their sum and their difference. In a streaming design the sample that arrives first
// has to wait for its partner, and that wait is a delay line of L samples. This stage uses the
// delay line in a feedback loop: during the first L samples of every 2L the line is filled with
// the incoming samples while the old contents (the differences of the previous period) go out,
// and during the next L samples every input meets its partner from the line, the sum goes out
// and the difference goes into the line to be sent out during the following L samples. Only one
// stream enters and leaves (so "single path"), and the delay line is the only memory. The terms
// used here (butterfly, DIF FFT, twiddle factor) are explained in docs/learn/GLOSSARY.md.
//
//   BF2I  (TYPE 1): delay L. The butterfly as described above.
//   BF2II (TYPE 2): the same, plus the input is multiplied by -j when it falls in the 4th quarter
//                   of the 4L-sample frame. Multiplying a complex number by -j is free (swap the
//                   real and imaginary part and negate one of them, no multiplier), and it is
//                   what lets two radix-2 stages do the work of a radix-4 butterfly with the
//                   twiddle multiplier (fft_twmul.v) only after every second stage.
//
// Full precision: the output is one bit wider than the input (the sum of two numbers needs one
// more bit) and nothing is rounded here. REAL_IN = 1 (the first stage when the FFT input is real):
// the imaginary input is ignored and taken as zero, and the delay line stores only the real part,
// which halves the biggest memory of the whole FFT.
//
// The stage counts samples, not clocks: the counter cnt advances only on in_valid, so gaps in
// the stream only pause it. CNT_INIT is the position of the first enabled sample after reset
// within the 4L frame, which removes the stage's sample latency from the start of the FFT
// (see fft_r22sdf.v), so no start signal has to travel down the pipeline. The stage adds one
// register of latency (out_valid follows in_valid by one clock).
//
// Gowin specific: the delay line is built in fft_delay.v, as registers, LUT RAM or block RAM
// depending on its length.

`timescale 1ns / 1ps

module fft_bf #(
    parameter integer IW       = 16,    // input width per component
    parameter integer L        = 1024,  // delay (power of two)
    parameter integer TYPE     = 1,     // 1 = BF2I, 2 = BF2II
    parameter integer REAL_IN  = 0,     // 1: imaginary input ignored, delay line holds the real part only
    parameter integer CNT_INIT = 0,     // position of the first valid sample after reset within the 4L frame
    parameter integer SR_LUT   = 0,    // fft_delay.v: register chains as LUT RAM
    parameter integer LUT_MAX_W = 64   // fft_delay.v: stores up to this many words as LUT RAM
) (
    input  wire              clk,
    input  wire              rst,        // synchronous reset
    input  wire              in_valid,   // one-clock pulse per input sample (any gaps)
    input  wire [IW-1:0]     in_re,      // input, real part, two's complement
    input  wire [IW-1:0]     in_im,      // input, imaginary part
    output reg               out_valid,  // one clock after in_valid
    output reg  [IW:0]       out_re,     // output, one bit wider than the input
    output reg  [IW:0]       out_im
) /* synthesis syn_maxfan = 10000 */;   // out_valid enables the next stage: it has 176 loads, which as one net would be too slow (docs/ZOOM_FIT.md)

    localparam integer OW = IW + 1;
    localparam integer LB = $clog2(L);       // bit LB of the counter = butterfly phase
    localparam integer CW = LB + 2;          // counter covers 4L (BF2II needs bit LB+1)

    // cnt is the position within the 4L frame. Bit LB of it is the butterfly phase (0: filling the
    // delay line, 1: combining with the line's contents) and, for BF2II, the bit above it says
    // whether this is the quarter of the frame in which the -j rotation applies.
    reg [CW-1:0] cnt = CNT_INIT[CW-1:0];
    // phase = cnt[LB] and rot = (BF2II, phase, k1 = cnt[LB+1]) as registers of their own, set
    // from the next count when cnt advances (decoded from cnt they would fan out to every data
    // bit's muxes and be the slowest path of the FFT).
    // Each in four copies (syn_preserve), one per group of data bits it selects: as one net each
    // would fan out to about a hundred bits, and that routing alone takes 3 ns.
    localparam [3:0] PH0 = {4{CNT_INIT[LB]}};
    localparam [3:0] RT0 = {4{(TYPE == 2) && CNT_INIT[LB] && CNT_INIT[LB+1]}};
    (* syn_preserve = 1 *) reg [3:0] phase = PH0;   // wr_r, wr_i, out_re, out_im
    (* syn_preserve = 1 *) reg [3:0] rot   = RT0;   // xr, opi, sum_i, dif_i
    wire [CW-1:0] cnt_p1 = cnt + 1'b1;

    // input, sign-extended, with the -j rotation for BF2II
    wire signed [OW-1:0] xr0 = {in_re[IW-1], in_re};
    wire signed [OW-1:0] xi0 = (REAL_IN != 0) ? {OW{1'b0}} : {in_im[IW-1], in_im};
    wire signed [OW-1:0] xr = rot[0] ?  xi0 : xr0;
    // xi = rot ? -xr0 : xi0 (-j * (a + jb) = b - ja) is not formed on its own: the negation is
    // folded into the sum and difference below as an inverted operand, x + (y ^ m) + m, so the
    // path from the input through the rotation to the delay line has one adder, not two.
    // When phase = 0, rot = 0, so the value written into the line then is the unrotated input.
    wire signed [OW-1:0] opi = rot[1] ? xr0 : xi0;

    // delay line: dr/di is the word that left the line (the partner of the current input in the
    // second half of a period, last period's difference in the first half)
    wire signed [OW-1:0] dr, di;
    wire signed [OW-1:0] sum_r = dr + xr;
    wire signed [OW-1:0] sum_i = di + (opi ^ {OW{rot[2]}}) + {{(OW-1){1'b0}}, rot[2]};
    wire signed [OW-1:0] dif_r = dr - xr;
    wire signed [OW-1:0] dif_i = di + (opi ^ {OW{!rot[3]}}) + {{(OW-1){1'b0}}, !rot[3]};
    // what goes into the line: the difference while combining, the plain input while filling
    wire [OW-1:0] wr_r = phase[0] ? dif_r : xr0;
    wire [OW-1:0] wr_i = phase[1] ? dif_i : xi0;

    generate
        if (REAL_IN != 0) begin : g_real
            fft_delay #(.W(OW), .L(L), .SR_LUT(SR_LUT), .LUT_MAX_W(LUT_MAX_W)) u_dl (
                .clk(clk), .ce(in_valid), .d(wr_r), .q(dr)
            );
            assign di = {OW{1'b0}};
        end else begin : g_cplx
            wire [2*OW-1:0] q;
            fft_delay #(.W(2*OW), .L(L), .SR_LUT(SR_LUT), .LUT_MAX_W(LUT_MAX_W)) u_dl (
                .clk(clk), .ce(in_valid), .d({wr_r, wr_i}), .q(q)
            );
            assign dr = q[2*OW-1:OW];
            assign di = q[OW-1:0];
        end
    endgenerate

    // output: the sum while combining, whatever the line holds while filling (the old differences)
    always @(posedge clk) begin
        if (rst) begin
            cnt       <= CNT_INIT[CW-1:0];
            phase     <= PH0;
            rot       <= RT0;
            out_valid <= 1'b0;
        end else begin
            out_valid <= in_valid;
            if (in_valid) begin
                cnt    <= cnt_p1;
                phase  <= {4{cnt_p1[LB]}};
                rot    <= {4{(TYPE == 2) && cnt_p1[LB] && cnt_p1[LB+1]}};
                out_re <= phase[2] ? sum_r : dr;
                out_im <= phase[3] ? sum_i : di;
            end
        end
    end

endmodule
