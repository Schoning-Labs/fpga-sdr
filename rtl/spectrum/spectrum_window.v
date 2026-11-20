// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// spectrum_window: the window of the full-band spectrum (docs/F2_SPECTRUM.md; docs/ARCHITECTURE.md
// section 3.3). It multiplies the 12-bit ADC stream by a 4-term Blackman-Harris window and gives the
// 15-bit windowed sample (the 12-bit sample times the window, with 3 fraction bits) that
// rtl/fft/fft_r22sdf.v expects on its real input (docs/F1_FFT.md "Interface for F2 and F3"). An FFT
// treats its frame as if it repeated forever, so a signal that does not fit the frame exactly
// smears into every bin and weak signals next to strong ones disappear; fading the samples
// toward zero at both ends of the frame with a window keeps that to about -92 dB (the side lobe level
// of this window), which a 12-bit ADC plus the FFT gain needs. The terms are explained in
// docs/learn/GLOSSARY.md.
//
// Frames are consecutive blocks of N = 16,384 valid input samples counted from reset, the same
// convention as the FFT itself: no start signal, and gaps in in_valid only pause the frame counter.
// The window is symmetric, w[i] = w[N-1-i], so only the first half is stored. To save block RAM
// that half is stored decimated: the ROM (rtl/spectrum/tw/window_coeffs.hex, written by
// tools/gen_spectrum_tables.py) keeps only every DECIM-th sample of the half (1,025 entries at DECIM
// = 8: i = 0, 8, ... 8192, instead of 8,192), of which the first 1,024 are in the ROM and the last, the
// center of the window, is exactly 1.0 and comes from a compare. This module interpolates linearly
// between neighbours for the points in between, which saves 7 block RAMs. The worst-case
// interpolation error against the true continuous window, measured by the script, is 4.7e-6, under
// the 18-bit coefficient's own quantization step (7.6e-6), so the -92 dB side lobes are unaffected.
//
// Coefficient format: unsigned WC-bit Q1.WFRAC (WFRAC = WC - 1 fraction bits, 0 .. 2^WFRAC = 1.0
// exactly at the window's peak). The signed IW-bit sample times the coefficient gives a product
// scaled by 2^WFRAC; the wanted output has OW - IW fraction bits (3, to match the FFT's 15-bit /
// 3-fraction-bit input), so the round-shift amount is SH = WFRAC - (OW - IW) = 14.
//
// Pipeline, 7 register stages: ROM read of the two neighbouring stored samples; the interpolation
// over four stages (subtract, multiply by the fraction, round and add back, clamp); then the multiply
// and the round/saturate in two. A stage is one short step so that the module runs at the DSP clock.

`timescale 1ns / 1ps

module spectrum_window #(
    parameter integer LOG_N  = 14,          // log2 of the frame length
    parameter integer IW     = 12,          // ADC sample width
    parameter integer OW     = 15,          // windowed sample width (the FFT's IW)
    parameter integer WC     = 18,          // window coefficient width, unsigned
    parameter integer WFRAC  = 17,          // window coefficient fraction bits (Q1.17)
    parameter         TW_DIR = "rtl/spectrum/tw/"
) (
    input  wire                 clk,
    input  wire                 rst,           // synchronous reset, restarts the frame count
    input  wire                 in_valid,      // a sample is on in_sample (gaps only pause the frame counter)
    input  wire signed [IW-1:0] in_sample,     // ADC sample, two's complement
    output reg                  out_valid,     // windowed sample valid, 7 clocks after in_valid
    output reg  signed [OW-1:0] out_sample     // windowed sample
) /* synthesis syn_srlstyle = "registers" */;

    localparam integer N       = 1 << LOG_N;
    localparam integer HALF    = N / 2;
    localparam integer SH      = WFRAC - (OW - IW);      // round-shift amount, 14 for the defaults
    localparam integer PW      = IW + WC + 1;             // product width (coeff zero-extended by 1)
    localparam TW_FILE = {TW_DIR, "window_coeffs.hex"};

    // The decimated window ROM: the DECIM_BITS low bits of idx are the interpolation fraction.
    localparam integer DECIM_BITS = 3;                     // DECIM = 8
    localparam integer ROM_N      = (HALF >> DECIM_BITS) + 1;   // 1025 entries in the file
    localparam integer ROM_AW     = $clog2(ROM_N);               // 11
    // Only entries 0 .. 1023 are stored. A 1,025-entry ROM needs the next power of two
    // (2,048 words, 4 block RAMs for the two reads); the last entry, the window's center, is
    // exactly 1.0 (Q1.17: 1 << WFRAC, the file's last line 20000) and comes from a compare.
    localparam integer ROM_S      = ROM_N - 1;                   // 1024 stored
    localparam [WC-1:0] ROM_LAST  = 1 << WFRAC;

    reg [WC-1:0] rom [0:ROM_S-1];
    initial $readmemh(TW_FILE, rom, 0, ROM_S - 1);

    // ---- frame sample counter, symmetric ROM index (combinational) ----
    reg [LOG_N-1:0] cnt = {LOG_N{1'b0}};
    wire [LOG_N-1:0] idx  = (cnt < HALF[LOG_N-1:0]) ? cnt : (N[LOG_N-1:0] - 1 - cnt);
    wire [ROM_AW-1:0] idx_hi   = idx >> DECIM_BITS;        // 0 .. 1023 (implicit truncation to ROM_AW bits)
    wire [DECIM_BITS-1:0] idx_frac = idx[DECIM_BITS-1:0];  // 0 .. 7

    // ---- stage 1: register the sample and the two neighbouring ROM entries ----
    reg                     v1 = 1'b0;
    reg signed [IW-1:0]     s1 = {IW{1'b0}};
    reg [WC-1:0]            c_lo1, c_hi1;
    reg [DECIM_BITS-1:0]    frac1;
    always @(posedge clk) begin
        if (rst) begin
            cnt <= {LOG_N{1'b0}};
        end else if (in_valid) begin
            cnt <= cnt + 1'b1;
        end
        v1    <= rst ? 1'b0 : in_valid;
        s1    <= in_sample;
        c_lo1 <= rom[idx_hi[ROM_AW-2:0]];
        // idx_hi max 1023 (ROM_S - 1): the next entry is the stored one, or the last at 1023
        c_hi1 <= (idx_hi == ROM_S - 1) ? ROM_LAST : rom[idx_hi[ROM_AW-2:0] + 1'b1];
        frac1 <= idx_frac;
    end

    // ---- stage 2: subtract (delta = c_hi - c_lo), register. This is split from the rest of the
    // interpolation (multiply by the fraction, round, add back to c_lo, clamp), which is stage 2b onward,
    // because the whole chain from the block RAM's read through the subtract, multiply, round, add and
    // clamp in one clock is far too long for the DSP clock rate; splitting it halves the depth between
    // registers at the cost of cycles of latency, which nothing downstream depends on. ----
    localparam integer DW = WC + 2;                       // delta width, signed, headroom
    wire signed [DW-1:0] delta2 = $signed({2'b00, c_hi1}) - $signed({2'b00, c_lo1});

    reg                  v2a = 1'b0;
    reg signed [IW-1:0]  s2a = {IW{1'b0}};
    reg [WC-1:0]         c_lo2a;
    reg signed [DW-1:0]  delta2a;
    reg [DECIM_BITS-1:0] frac2a;
    always @(posedge clk) begin
        v2a     <= rst ? 1'b0 : v1;
        s2a     <= s1;
        c_lo2a  <= c_lo1;
        delta2a <= delta2;
        frac2a  <= frac1;
    end

    // ---- stage 2b: multiply by the fraction, register (the multiply's output through the round,
    // the add and the clamp in one clock is too slow) ----
    localparam integer TW = DW + 4;                        // term width: delta (signed) * frac (0..7)
    reg                  v2b = 1'b0;
    reg signed [IW-1:0]  s2b = {IW{1'b0}};
    reg [WC-1:0]         c_lo2b;
    reg signed [TW-1:0]  term2b;
    always @(posedge clk) begin
        v2b    <= rst ? 1'b0 : v2a;
        s2b    <= s2a;
        c_lo2b <= c_lo2a;
        term2b <= delta2a * $signed({1'b0, frac2a});
    end

    // ---- stage 2c: round to nearest, add back, register; stage 2d: clamp, register ----
    localparam signed [TW-1:0] HALF_FRAC = 1 <<< (DECIM_BITS - 1);
    wire signed [TW-1:0] rounded2c = (term2b + HALF_FRAC) >>> DECIM_BITS;
    localparam signed [DW:0] WMAX = (1 <<< WC) - 1;
    localparam signed [DW:0] WMIN = 0;

    reg                 v2c = 1'b0;
    reg signed [IW-1:0] s2c = {IW{1'b0}};
    reg signed [DW:0]   c_interp2c;
    always @(posedge clk) begin
        v2c        <= rst ? 1'b0 : v2b;
        s2c        <= s2b;
        c_interp2c <= $signed({1'b0, c_lo2b}) + rounded2c[DW:0];
    end

    reg               v2 = 1'b0;
    reg signed [IW-1:0] s2 = {IW{1'b0}};
    reg [WC-1:0]        c2;
    always @(posedge clk) begin
        v2 <= rst ? 1'b0 : v2c;
        s2 <= s2c;
        c2 <= (c_interp2c > WMAX) ? WMAX[WC-1:0] : (c_interp2c < WMIN) ? {WC{1'b0}} : c_interp2c[WC-1:0];
    end

    // ---- stage 3a: multiply, register; stage 3b: round, saturate (split, since the multiplier's
    // output through the round and the saturate in one clock is too slow) ----
    reg                 v3 = 1'b0;
    reg signed [PW-1:0] prod3;
    always @(posedge clk) begin
        v3    <= rst ? 1'b0 : v2;
        prod3 <= s2 * $signed({1'b0, c2});
    end
    localparam signed [PW-1:0] HALF_LSB = 1 <<< (SH - 1);
    wire signed [PW-1:0] rnd = (prod3 + HALF_LSB) >>> SH;
    localparam signed [PW-1:0] MAXV = (1 <<< (OW - 1)) - 1;
    localparam signed [PW-1:0] MINV = -(1 <<< (OW - 1));

    always @(posedge clk) begin
        out_valid  <= rst ? 1'b0 : v3;
        out_sample <= (rnd > MAXV) ? MAXV[OW-1:0] : (rnd < MINV) ? MINV[OW-1:0] : rnd[OW-1:0];
    end

endmodule
