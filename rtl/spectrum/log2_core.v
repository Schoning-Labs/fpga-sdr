// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// log2_core: a base-2 logarithm estimator for unsigned integers, fully pipelined (a new value every clock,
// no back-pressure). The spectrum needs logarithms because a spectrum display is in dB, and a dB value
// is ten times the base-10 logarithm of a power ratio; spectrum_ratio_db.v runs two of these, one for
// the sum over the K frames and one for K x bins, and subtracts the two results, which replaces a wide
// division followed by a single logarithm. The terms are explained in docs/learn/GLOSSARY.md and
// docs/F2_SPECTRUM.md has the surrounding design.
//
// Method: every positive integer can be written value = 2^msb_pos x (1 + f) with 0 <= f < 1, where
// msb_pos is the position of the leading one, so log2(value) = msb_pos + log2(1 + f). The integer
// part comes from a combinational leading-one search. The fraction log2(1 + f) comes from a lookup
// table (rtl/spectrum/tw/log2_frac.hex, written by tools/gen_spectrum_tables.py: midpoint samples
// of the curve, addressed by the first FRAC_BITS bits after the leading one; worst-case error under
// 0.001 dB once multiplied by the dB constant downstream, see that script's own printout).
// The result is an unsigned fixed-point number with PB integer bits and LUT_W fraction bits.
// value_in = 0 sets zero_out (log2(0) is undefined; the caller decides what that means: for
// spectrum_ratio_db.v a zero numerator is "no signal", which gives the sentinel dB output).
//
// 4-stage pipeline: stage 0 leading-one search + register (a stage of its own, so that the search, the
// barrel shift and the ROM address are not in one clock), stage 1 barrel shift + register, stage 2 ROM
// read + register, stage 3 combine to the Q(PB).LUT_W fixed-point log2 value + register. valid_out
// follows valid_in by exactly 4 cycles, gap-free (a new value_in every cycle is accepted with no
// back-pressure), which two instances running in lock-step in spectrum_ratio_db.v rely on.
//
// Gowin specific: the 512-entry table is a block RAM (or LUTs), read with the clock.

`timescale 1ns / 1ps

module log2_core #(
    parameter integer IW        = 48,     // value_in width, unsigned
    parameter integer FRAC_BITS = 9,      // mantissa LUT address bits (512 entries)
    parameter integer LUT_W     = 12,     // LUT entry width, unsigned Q0.12
    parameter         TW_DIR    = "rtl/spectrum/tw/",
    localparam integer PB       = (IW <= 1) ? 1 : $clog2(IW)   // bits to hold msb_pos (0..IW-1)
) (
    input  wire                  clk,
    input  wire                  rst,           // synchronous reset
    input  wire                  valid_in,      // a value is on value_in (any pattern, including every clock)
    input  wire [IW-1:0]         value_in,      // unsigned integer
    output reg                   valid_out,     // 4 clocks after valid_in
    output reg                   zero_out,      // the value was 0
    output reg  [PB+LUT_W-1:0]   log2_out       // unsigned Q(PB).LUT_W
) /* synthesis syn_srlstyle = "registers" */;

    localparam TW_FILE = {TW_DIR, "log2_frac.hex"};

    reg [LUT_W-1:0] rom [0:(1<<FRAC_BITS)-1];
    initial $readmemh(TW_FILE, rom);

    // ---- stage 0: leading-one search (combinational) ----
    integer i;
    reg [PB-1:0] msb_pos_c;
    reg          zero_c;
    always @* begin
        msb_pos_c = {PB{1'b0}};
        zero_c    = 1'b1;
        for (i = IW - 1; i >= 0; i = i - 1) begin
            if (zero_c && value_in[i]) begin
                msb_pos_c = i[PB-1:0];
                zero_c    = 1'b0;
            end
        end
    end
    wire [PB-1:0] shamt_c = (IW - 1) - msb_pos_c;   // 0 when value_in's MSB is already set

    // ---- stage 0r: register the leading-one position and the value. Gowin moves the stage-1
    // register below into the block RAM's address register, which would put the leading-one search,
    // the barrel shift and the ROM address into one clock, so the search has a clock of its own ----
    reg [IW-1:0] val0;
    reg [PB-1:0] msb_pos0, shamt0;
    reg          zero0, v0;
    always @(posedge clk) begin
        val0     <= value_in;
        msb_pos0 <= msb_pos_c;
        shamt0   <= shamt_c;
        zero0    <= zero_c;
        v0       <= rst ? 1'b0 : valid_in;
    end

    // ---- stage 1: barrel shift so the leading one sits at bit IW-1, register ----
    reg [IW-1:0] norm1;
    reg [PB-1:0] msb_pos1;
    reg          zero1, v1;
    always @(posedge clk) begin
        norm1    <= val0 << shamt0;
        msb_pos1 <= msb_pos0;
        zero1    <= zero0;
        v1       <= rst ? 1'b0 : v0;
    end

    // ---- stage 2: ROM read of the mantissa bucket, register ----
    wire [FRAC_BITS-1:0] frac_idx2 = norm1[IW-2 -: FRAC_BITS];
    reg [LUT_W-1:0] frac2;
    reg [PB-1:0]    msb_pos2;
    reg             zero2, v2;
    always @(posedge clk) begin
        frac2    <= rom[frac_idx2];
        msb_pos2 <= msb_pos1;
        zero2    <= zero1;
        v2       <= rst ? 1'b0 : v1;
    end

    // ---- stage 3: combine to log2(value) fixed point, register ----
    wire [PB+LUT_W-1:0] log2_fixed2 = {msb_pos2, {LUT_W{1'b0}}} + frac2;
    always @(posedge clk) begin
        log2_out  <= log2_fixed2;
        zero_out  <= zero2;
        valid_out <= rst ? 1'b0 : v2;
    end

endmodule
