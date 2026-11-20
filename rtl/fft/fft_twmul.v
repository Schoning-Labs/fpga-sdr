// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// fft_twmul: the twiddle multiplier that sits between two stage pairs of the streaming FFT
// (docs/F1_FFT.md). A twiddle factor is a complex number of length one, W = exp(-j 2 pi e / NP),
// that an FFT multiplies into its data between stages; this module does that complex multiply
// for a stream of samples, taking the right twiddle factor for each sample position from a ROM.
// The terms are explained in docs/learn/GLOSSARY.md.
//
// Sample q of every NP-sample frame (q = k1 NP/2 + k2 NP/4 + n3, where k1 and k2 are the top two
// bits of the position and n3 the rest) is multiplied by W_NP^(n3 (k1 + 2 k2)) = exp(-j 2 pi e/NP)
// with e = n3 (k1 + 2 k2). The ROM holds only the first octant (an eighth of the circle): cos and
// sin of 2 pi r / NP for r < NP/8, as 18-bit numbers scaled by 2^17 - 1, and the other octants
// and the 45-degree point come from symmetry (swap cos and sin, negate, or the constant K45).
// ROM file: rtl/fft/tw/fft_tw18_lNN.hex, NN = log2(NP), written by tools/fft_r22sdf.py gen-tw.
// Using one eighth of the table saves 8 times the memory, which for NP = 16,384 is 2,048 words
// of 36 bits and not 16,384.
//
// The product: four real multiplies of W bits (the data) by 18 bits (the twiddle), one DSP block
// each as long as W <= 27: re = ar wr - ai wi and im = ar wi + ai wr, where the twiddle is
// wr + j wi (wi is stored negated, the sine part with its sign folded in, because the FFT
// kernel is exp(-j ...)). The product has 18 - 1 = 17 fraction bits, so it is rounded half up at
// 2^-17 and saturated to W bits; the output keeps the input width because the magnitude of a
// twiddle is at most 1. The twiddles are scaled by 2^17 - 1 and not 2^17, which is why the gain
// of a multiplier is 1 - 7.6e-6 (-0.0004 dB over the six multipliers of a 16k FFT).
//
// Latency 8 clocks (7 with M1_ONE = 1); the sample count advances on in_valid only, so bursty
// input is fine. Pipeline: the ROM address is picked between two precomputed candidates (tw_a, the
// current count's index, and tw_b, the next count's) instead of being worked out through three
// adders in front of the ROM, then the ROM read, the octant mapping in two clocks (m0, m1), the
// multiplier operands, the products, the sums, the rounding and finally the saturation, a clock
// each. Spreading it out like this lets the multiplier run at the DSP clock rate.

`timescale 1ns / 1ps

module fft_twmul #(
    parameter integer W        = 18,     // data width per component, in and out
    parameter integer LOG_NP   = 14,     // log2 of the frame size NP this multiplier works in
    parameter integer CNT_INIT = 0,      // frame position of the first valid sample after reset
    parameter         TW_DIR   = "rtl/fft/tw/",    // directory of the twiddle ROM files
    parameter integer TW_LUT_MAX = 32,   // ROMs of this many words or fewer are built in LUTs (the full-band spectrum FFT sets 128)
    // 1: the octant mapping (select and negate) in one clock instead of two, latency 7 instead of 8.
    // The second clock keeps the path short at a high clock rate; at 120 MHz one clock is enough,
    // and the second clock costs 86 flip-flops per multiplier, 50 of them a plain copy of the sample.
    parameter integer M1_ONE   = 0
) (
    input  wire          clk,
    input  wire          rst,         // synchronous reset
    input  wire          in_valid,    // one-clock pulse per input sample (any gaps)
    input  wire [W-1:0]  in_re,       // input, real part
    input  wire [W-1:0]  in_im,       // input, imaginary part
    output reg           out_valid,   // output sample valid (8 clocks after in_valid, or 7)
    output reg  [W-1:0]  out_re,      // product, rounded and saturated to W bits
    output reg  [W-1:0]  out_im
) /* synthesis syn_srlstyle = "registers" syn_maxfan = 10000 */;

    localparam integer TW  = 18;
    localparam integer NP  = 1 << LOG_NP;
    localparam integer OCT = NP / 8;                  // ROM depth
    localparam integer RB  = (LOG_NP > 3) ? LOG_NP - 3 : 1;
    localparam integer OM  = OCT - 1;
    localparam signed [TW-1:0] K45 = 18'sd92681;      // round(sqrt(0.5) * (2^17 - 1))
    localparam integer D1I = 48 + LOG_NP / 10;          // ASCII digits of LOG_NP
    localparam integer D0I = 48 + LOG_NP % 10;
    localparam [7:0]   D1  = D1I[7:0];
    localparam [7:0]   D0  = D0I[7:0];
    localparam TW_FILE = {TW_DIR, "fft_tw18_l", D1, D0, ".hex"};

    // The ROM is 36 bits wide (cos, sin), OCT words. Up to TW_LUT_MAX words (32 unless the instance
    // says otherwise) it is built in LUTs (the 32-word one takes 2 block RAMs otherwise); larger
    // ones stay block RAM.
    wire [RB-1:0] rom_a;
    wire [2*TW-1:0] rom_d;
    generate
        if (OCT <= TW_LUT_MAX) begin : g_lrom
            (* syn_romstyle = "distributed_rom" *) reg [2*TW-1:0] rom [0:OCT-1];
            initial $readmemh(TW_FILE, rom);
            assign rom_d = rom[rom_a];
        end else begin : g_brom
            reg [2*TW-1:0] rom [0:OCT-1];
            initial $readmemh(TW_FILE, rom);
            assign rom_d = rom[rom_a];
        end
    endgenerate

    // ---- twiddle index for the sample that will arrive next (ROM read is registered) ----
    // tw_idx(c) = {k45, octant, ROM address} of frame position c: the exponent e = n3 (k1 + 2 k2) is
    // worked out from the position c, its top three bits are the octant, the rest is the position in
    // the octant (reflected in odd octants), and k45 marks the 45-degree point.
    localparam integer XW = RB + 5;
    function [XW-1:0] tw_idx;
        input [LOG_NP-1:0] c;
        reg   [LOG_NP-1:0] n3, e;
        reg   [2:0]        oc;
        reg   [RB:0]       r, rr;
        begin
            n3 = {2'b00, c[LOG_NP-3:0]};
            e  = (c[LOG_NP-1] ? n3 : {LOG_NP{1'b0}}) +
                 (c[LOG_NP-2] ? {n3[LOG_NP-2:0], 1'b0} : {LOG_NP{1'b0}});
            oc = e[LOG_NP-1:LOG_NP-3];
            r  = (LOG_NP > 3) ? {1'b0, e[RB-1:0]} : {(RB+1){1'b0}};
            rr = oc[0] ? OCT[RB:0] - r : r;                    // reflected: 1 .. NP/8
            // rr == OCT only when reflected with r == 0 (r < OCT always): the 45-degree point
            tw_idx = {oc[0] && (r == {(RB+1){1'b0}}), oc, rr};
        end
    endfunction

    // tw_a = tw_idx(cnt), tw_b = tw_idx(cnt + 1), tw_c = tw_idx(cnt + 2), kept up to date as cnt
    // advances (c3 counts cnt + 3); the sample that arrives next has position cnt + in_valid
    reg  [LOG_NP-1:0] cnt  = CNT_INIT[LOG_NP-1:0];
    wire [LOG_NP-1:0] cnt_n = cnt + in_valid;
    reg  [LOG_NP-1:0] c3   = CNT_INIT[LOG_NP-1:0] + 2'd3;
    reg  [XW-1:0]     tw_a = tw_idx(CNT_INIT[LOG_NP-1:0]);
    reg  [XW-1:0]     tw_b = tw_idx(CNT_INIT[LOG_NP-1:0] + 1'b1);
    reg  [XW-1:0]     tw_c = tw_idx(CNT_INIT[LOG_NP-1:0] + 2'd2);
    wire [XW-1:0]     tw_n = in_valid ? tw_b : tw_a;
    wire [2:0]        oct_n = tw_n[RB+3:RB+1];
    wire [RB:0]       rr_n  = tw_n[RB:0];
    wire              k45_n = tw_n[XW-1];
    assign rom_a = rr_n[RB-1:0] & OM[RB-1:0];

    reg [2*TW-1:0] rom_q = {2*TW{1'b0}};
    reg [2:0]      oct_q = 3'd0;
    reg            k45_q = 1'b0;
    always @(posedge clk) begin
        rom_q <= rom_d;
        oct_q <= oct_n;
        k45_q <= k45_n;
        if (rst) begin
            tw_a <= tw_idx(CNT_INIT[LOG_NP-1:0]);
            tw_b <= tw_idx(CNT_INIT[LOG_NP-1:0] + 1'b1);
            tw_c <= tw_idx(CNT_INIT[LOG_NP-1:0] + 2'd2);
            c3   <= CNT_INIT[LOG_NP-1:0] + 2'd3;
        end else if (in_valid) begin
            tw_a <= tw_b;
            tw_b <= tw_c;
            tw_c <= tw_idx(c3);
            c3   <= c3 + 1'b1;
        end
    end

    // ---- m0 (on in_valid): the sample and its twiddle's ROM word, octant, 45-degree flag ----
    reg signed [W-1:0]  ar0, ai0;
    reg signed [TW-1:0] c0, s0;
    // The octant is decoded into the three flags of m1 (selr_c, wrn_c, win_c) one clock earlier,
    // here, and registered (the three flags in place of the 3-bit octant: no extra register).
    // In m1 the decode would be one more logic level in front of the select and the negation.
    reg                 selr_c, wrn_c, win_c;
    always @(posedge clk)
        if (in_valid) begin
            ar0  <= in_re;
            ai0  <= in_im;
            c0   <= k45_q ? K45 : rom_q[2*TW-1:TW];
            s0   <= k45_q ? K45 : rom_q[TW-1:0];
            case (oct_q)                  // the part and its sign for this octant: wr from cos (0) or sin (1), negated or not; wi likewise
                3'd0: begin selr_c <= 1'b0; wrn_c <= 1'b0; win_c <= 1'b1; end
                3'd1: begin selr_c <= 1'b1; wrn_c <= 1'b0; win_c <= 1'b1; end
                3'd2: begin selr_c <= 1'b1; wrn_c <= 1'b1; win_c <= 1'b1; end
                3'd3: begin selr_c <= 1'b0; wrn_c <= 1'b1; win_c <= 1'b1; end
                3'd4: begin selr_c <= 1'b0; wrn_c <= 1'b1; win_c <= 1'b0; end
                3'd5: begin selr_c <= 1'b1; wrn_c <= 1'b1; win_c <= 1'b0; end
                3'd6: begin selr_c <= 1'b1; wrn_c <= 1'b0; win_c <= 1'b0; end
                default: begin selr_c <= 1'b0; wrn_c <= 1'b0; win_c <= 1'b0; end
            endcase
        end

    // ---- m1: octant mapping, wr = cos-part, wi = -(sin-part) (the negation folded in). Two
    // clocks (m1a picks the part and its sign, m1b negates), because the select and the negation
    // in one clock are too slow for the fastest clock; M1_ONE = 1 does it in one ----
    wire signed [TW-1:0] wr_c = selr_c ? s0 : c0;
    wire signed [TW-1:0] wi_c = selr_c ? c0 : s0;
    reg signed [W-1:0]  ar1, ai1;
    reg signed [TW-1:0] wr1, wi1;
    generate
        if (M1_ONE != 0) begin : g_m1one
            always @(posedge clk) begin
                ar1 <= ar0;
                ai1 <= ai0;
                wr1 <= wrn_c ? -wr_c : wr_c;
                wi1 <= win_c ? -wi_c : wi_c;
            end
        end else begin : g_m1two
            reg signed [W-1:0]  ar1a, ai1a;
            reg signed [TW-1:0] wr1a, wi1a;
            reg                 wrn, win;           // negate wr1a / wi1a
            always @(posedge clk) begin
                ar1a <= ar0;
                ai1a <= ai0;
                wr1a <= wr_c;  wrn <= wrn_c;
                wi1a <= wi_c;  win <= win_c;
                ar1 <= ar1a;
                ai1 <= ai1a;
                wr1 <= wrn ? -wr1a : wr1a;
                wi1 <= win ? -wi1a : wi1a;
            end
        end
    endgenerate

    // ---- pipeline: m2 multiplier operands, m3 products, m4 sums, m5 round, m6 saturate ----
    reg [7:0] v = 8'b0;
    reg signed [W-1:0]  ar, ai;
    reg signed [TW-1:0] wr, wi;
    wire signed [W+TW-1:0] p_rr, p_ii, p_ri, p_ir;
    reg signed [W+TW:0]   s_re, s_im;

    fft_mul #(.AW(W), .BW(TW)) u_m_rr (.clk(clk), .a(ar), .b(wr), .p(p_rr));
    fft_mul #(.AW(W), .BW(TW)) u_m_ii (.clk(clk), .a(ai), .b(wi), .p(p_ii));
    fft_mul #(.AW(W), .BW(TW)) u_m_ri (.clk(clk), .a(ar), .b(wi), .p(p_ri));
    fft_mul #(.AW(W), .BW(TW)) u_m_ir (.clk(clk), .a(ai), .b(wr), .p(p_ir));

    localparam signed [W+TW:0] HALF = 1 <<< (TW - 2);
    wire signed [W+TW:0] rnd_re = (s_re + HALF) >>> (TW - 1);
    wire signed [W+TW:0] rnd_im = (s_im + HALF) >>> (TW - 1);
    localparam signed [W+TW:0] MAXV = (1 <<< (W - 1)) - 1;
    localparam signed [W+TW:0] MINV = -(1 <<< (W - 1));
    reg signed [W+TW:0] rnd_re_q, rnd_im_q;
    // saturation flags worked out in m5 from the unrounded sums, beside the rounding (compared in
    // m6, the compare would fan out to every output bit's set/reset):
    // rnd > MAXV exactly when s >= (MAXV + 1) 2^(TW-1) - HALF, rnd < MINV when
    // s < MINV 2^(TW-1) - HALF.
    localparam signed [W+TW:0] ONE  = 1;
    localparam signed [W+TW:0] S_HI = (ONE <<< (W + TW - 2)) - HALF;
    localparam signed [W+TW:0] S_LO = -(ONE <<< (W + TW - 2)) - HALF;
    reg ovp_re, ovn_re, ovp_im, ovn_im;

    always @(posedge clk) begin
        if (rst) begin
            cnt <= CNT_INIT[LOG_NP-1:0];
            v   <= 8'b0;
        end else begin
            cnt <= cnt_n;
            v   <= {v[6:0], in_valid};
        end
        ar <= ar1;
        ai <= ai1;
        wr <= wr1;
        wi <= wi1;
        s_re <= p_rr - p_ii;
        s_im <= p_ri + p_ir;
        rnd_re_q <= rnd_re;
        rnd_im_q <= rnd_im;
        ovp_re   <= s_re >= S_HI;
        ovn_re   <= s_re <  S_LO;
        ovp_im   <= s_im >= S_HI;
        ovn_im   <= s_im <  S_LO;
        out_re <= ovp_re ? MAXV[W-1:0] : ovn_re ? MINV[W-1:0] : rnd_re_q[W-1:0];
        out_im <= ovp_im ? MAXV[W-1:0] : ovn_im ? MINV[W-1:0] : rnd_im_q[W-1:0];
        out_valid <= ((M1_ONE != 0) ? v[5] : v[6]) & ~rst;
    end

endmodule
