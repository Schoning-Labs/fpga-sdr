// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// spectrum_ratio_db: the log-domain average of the spectrum (docs/F2_SPECTRUM.md). It computes
// db64 = 10 x log10(num_in / den_in) in 1/64 dB units from two log2_core.v instances (one for the
// K-frame sum, one for K x bins) and a subtraction. The spectrum display shows an average of K
// FFT frames in dB, and the average is a sum divided by K x bins; working in the log domain
// replaces that wide division and a following logarithm by log2(num) - log2(den), which is exact
// arithmetic, so the only error is the two independent table lookups (each under 0.001 dB once scaled
// to dB, under 0.002 dB combined, well inside the 1/64 dB = 0.0156 dB step of the output). It also
// avoids rounding the quotient to an integer before taking its logarithm, which a plain integer
// divide would do and which would turn very small quotients into 0. The terms are explained in
// docs/learn/GLOSSARY.md.
//
// num_in = 0 (no signal accumulated; den_in is never 0, because callers always pass K x bins with K
// clamped to at least 1 and bins at least 1) gives the sentinel minimum -32768 (1/64 dB units).
// The output is clamped to the 16-bit range.
//
// Pipeline: log2_core's own 4 stages (both instances run in lock-step since their latency does not
// depend on the width), 1 stage to register the subtraction, 1 stage to register the product with the
// dB constant, and 1 final stage for the rounding, clamp and sentinel: 7 cycles from valid_in to
// valid_out (RATIO_LATENCY in spectrum_walk_core.v), gap-free (a new (num_in, den_in) pair every
// cycle is accepted with no back-pressure).

`timescale 1ns / 1ps

`include "rtl/spectrum/log2_core.v"

module spectrum_ratio_db #(
    parameter integer NUM_IW    = 48,     // numerator width, unsigned (K-frame accumulator)
    parameter integer DEN_IW    = 23,     // denominator width, unsigned (K x bins)
    parameter integer FRAC_BITS = 9,
    parameter integer LUT_W     = 12,
    parameter         TW_DIR    = "rtl/spectrum/tw/",
    localparam integer PBN      = (NUM_IW <= 1) ? 1 : $clog2(NUM_IW),
    localparam integer PBD      = (DEN_IW <= 1) ? 1 : $clog2(DEN_IW),
    localparam integer PBM      = (PBN > PBD) ? PBN : PBD,
    localparam integer DIFFW    = PBM + 2 + LUT_W   // signed, 2 guard bits (sign + headroom)
) (
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  valid_in,      // a pair is on num_in/den_in
    input  wire [NUM_IW-1:0]     num_in,        // numerator, unsigned (the K-frame sum of powers)
    input  wire [DEN_IW-1:0]     den_in,        // denominator, unsigned (K x bins in the column)
    output reg                   valid_out,     // 7 clocks after valid_in
    output reg  signed [15:0]    db64_out       // 10 log10(num/den) in 1/64 dB, clamped
);

    wire                 num_v, den_v;
    wire                 num_zero, den_zero;
    wire [PBN+LUT_W-1:0] num_log2;
    wire [PBD+LUT_W-1:0] den_log2;

    log2_core #(.IW(NUM_IW), .FRAC_BITS(FRAC_BITS), .LUT_W(LUT_W), .TW_DIR(TW_DIR)) u_num (
        .clk(clk), .rst(rst), .valid_in(valid_in), .value_in(num_in),
        .valid_out(num_v), .zero_out(num_zero), .log2_out(num_log2)
    );
    log2_core #(.IW(DEN_IW), .FRAC_BITS(FRAC_BITS), .LUT_W(LUT_W), .TW_DIR(TW_DIR)) u_den (
        .clk(clk), .rst(rst), .valid_in(valid_in), .value_in(den_in),
        .valid_out(den_v), .zero_out(den_zero), .log2_out(den_log2)
    );
    // num_v and den_v are identical (both cores see the same valid_in/clk/rst and have the same
    // register count regardless of IW), so only num_v is used.

    // ---- stage: subtract in the log domain, register ----
    wire signed [DIFFW-1:0] num_ext = {{(DIFFW-(PBN+LUT_W)){1'b0}}, num_log2};
    wire signed [DIFFW-1:0] den_ext = {{(DIFFW-(PBD+LUT_W)){1'b0}}, den_log2};
    wire signed [DIFFW-1:0] diff_c  = num_ext - den_ext;

    reg signed [DIFFW-1:0] diff_r;
    reg                    numzero_r, va_r;
    always @(posedge clk) begin
        diff_r    <= diff_c;
        numzero_r <= num_zero;
        va_r      <= rst ? 1'b0 : num_v;
    end

    // ---- stage: multiply by the dB constant, round (half away from zero), clamp, sentinel ----
    // COEF/2^COEF_SH = 10/log2(10) * 64 / 2^LUT_W, i.e. db64 = round(diff * COEF / 2^COEF_SH)
    // (10 log10(x) = 10/log2(10) x log2(x) = 3.0103 x log2(x), 64 steps per dB, and the log2 values
    // carry LUT_W fraction bits).
    localparam integer COEF_SH = 24;
    localparam [23:0]  COEF    = 24'd789132;
    localparam integer PW      = DIFFW + 25;

    // The product is registered before it is rounded and clamped, because the multiplier's
    // output through the rounding add and two compares in one clock would be too slow. That makes
    // 7 clocks from valid_in to valid_out, RATIO_LATENCY in spectrum_walk_core.v.
    wire signed [PW-1:0] prod_m = diff_r * $signed({1'b0, COEF});
    reg  signed [PW-1:0] prod_c;
    reg                  numzero_p, va_p;
    always @(posedge clk) begin
        prod_c    <= prod_m;
        numzero_p <= numzero_r;
        va_p      <= rst ? 1'b0 : va_r;
    end
    localparam signed [PW-1:0] HALF = 1 <<< (COEF_SH - 1);
    wire signed [PW-1:0] rnd_c  = prod_c[PW-1] ? ((prod_c - HALF) >>> COEF_SH)
                                                : ((prod_c + HALF) >>> COEF_SH);

    localparam integer DBW = PW - COEF_SH;
    localparam signed [15:0] MIN_DB = -16'sd32768;
    localparam signed [15:0] MAX_DB =  16'sd32767;
    wire signed [DBW-1:0] db_full = rnd_c[DBW-1:0];

    always @(posedge clk) begin
        valid_out <= rst ? 1'b0 : va_p;
        if (numzero_p)
            db64_out <= MIN_DB;
        else if (db_full > MAX_DB)
            db64_out <= MAX_DB;
        else if (db_full < MIN_DB)
            db64_out <= MIN_DB;
        else
            db64_out <= db_full[15:0];
    end

endmodule
