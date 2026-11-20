// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ft8_tw3840: look-up of the twiddle factors W^e for the spectrogram combine stage (ft8_combine.v).
//
// What it computes
//   W = e^(-j 2 pi / 3,840), so W^e = cos(2 pi e / 3,840) - j sin(2 pi e / 3,840) is a point on the unit circle (glossary "Twiddle
//   factor").  The exponent is e = n1 x k, where n1 = 0 .. 14 is the index of the 256-point partial transform and k = 0 .. 1,023
//   the kept spectrogram bin (the product is at most 14,322, and W^e repeats every 3,840).  The output is the pair
//   (wr, wi) = (cos, -sin) as 18-bit signed numbers scaled by 2^17 - 1.  Bit-exact with
//   `twiddle(e, 3_840, octant_table(3_840))` in `fw/tr-modes/src/frontend/tables.rs`.
//
// How it works
//   A ROM with all 3,840 points would be wasteful, because the circle is symmetric.  The exponent is reduced modulo 3,840 and
//   split into an octant o = e / 480 (3,840 = 8 x 480, an eighth of the circle) and a remainder r = e mod 480.  A table of
//   (cos, sin) for the first octant only (r = 0 .. 479, the file rtl/ft8/rom/ft8_w3840_oct.hex, which `ft8-frontend tables` writes
//   from the same `octant_table()` that the Rust model calls) gives the point for r.  For the other octants the sine and
//   cosine are swapped and/or negated, and in odd octants the table is read backwards (index 480 - r, because the second
//   half of an octant mirrors the first around 45 degrees).  The 45-degree point itself (an odd octant with r = 0, reflected
//   index 480) takes the constant K45 = round(sqrt(0.5) x (2^17 - 1)), the same constant that rtl/fft/fft_twmul.v uses (this is
//   its octant scheme, widened from a power of two to 480).  The final sign and swap map is that of `tables::twiddle`'s match arms.
//
//   It is a pure look-up with no rounding: ft8_combine.v does the multiplication and rounds the finished sum.
//
// Latency and resources
//   LATENCY = 9 clocks, one small step per clock (input register, product, reduction modulo 3,840, octant, remainder, reflection,
//   ROM, 45-degree select, sign map), fully pipelined for one look-up per clock, with `in_valid` and `out_valid` shifted along in
//   step.  ft8_combine.v's TWL has to equal LATENCY.  One block RAM (a 512 x 36 ROM) and one small multiplier (n1 x k).

`timescale 1ns / 1ps

module ft8_tw3840 #(
    // ROM_FILE: the first-octant table, 480 words, each {cos[17:0], sin[17:0]} in 9 hex digits.
    parameter ROM_FILE = "rtl/ft8/rom/ft8_w3840_oct.hex"
) (
    // Clock (clk_dsp, 120 MHz) and synchronous reset (active high).
    input  wire        clk,
    input  wire        rst,
    // Look-up request: in_valid with n1 (0 .. 14) and k (0 .. 1,023), one per clock at most.
    input  wire        in_valid,
    input  wire [3:0]  n1,     // 0 .. 14
    input  wire [9:0]  k,      // 0 .. 1,023
    output reg         out_valid,     // high LATENCY clocks after in_valid (from a shift register of the valid flag)
    // The twiddle factor: wr = cos and wi = -sin of 2 pi n1 k / 3,840, signed 18 bit, scale 2^17 - 1.
    output reg signed [17:0] wr,
    output reg signed [17:0] wi
);

    // LATENCY: clocks from request to answer.  K45: the cosine and sine of 45 degrees, round(sqrt(0.5) x (2^17 - 1)).
    localparam integer       LATENCY = 9;
    localparam signed [17:0] K45 = 18'sd92_681; // round(sqrt(0.5) * (2^17 - 1)), same as in the FFT's rtl/fft/fft_twmul.v

    // The ROM holds {cos[17:0], sin[17:0]} for each first-octant address, in the 9-hex-digit format that `ft8-frontend tables` writes
    // (fw/tr-modes/src/bin/ft8_frontend.rs `pair()`).  It is one block ROM (Gowin pROMX9, 512 x 36, one block RAM in place and
    // route).  A LUT ROM failed timing, because its address fans out to about 1,000 LUT inputs (11.6 ns).
    reg [35:0] rom [0:479];
    initial $readmemh(ROM_FILE, rom);

    // ---- stage 0: input register, kept apart from the product's own (otherwise the tool absorbs the caller's registers into
    // the multiplier and counts the caller's logic as part of the multiplier's path); stage 1: e = n1 x k (n1 <= 14,
    // k <= 1,023, so at most 14,322, 14 bits) ----
    reg [3:0]  n1_0;
    reg [9:0]  k_0;
    reg [13:0] e1;
    always @(posedge clk) begin
        n1_0 <= n1;
        k_0  <= k;
        e1   <= n1_0 * k_0;
    end

    // ---- stage 2: reduce modulo 3,840 (e < 4 x 3,840, so a few parallel compares and one subtraction do it) ----
    reg [11:0] e2;
    always @(posedge clk) begin
        if (e1 >= 14'd11_520)      e2 <= e1 - 14'd11_520;
        else if (e1 >= 14'd7_680)  e2 <= e1 - 14'd7_680;
        else if (e1 >= 14'd3_840)  e2 <= e1 - 14'd3_840;
        else                       e2 <= e1[11:0];
    end

    // ---- stage 3: the octant o = e / 480 (seven parallel compares); stage 3b: the remainder e mod 480 ----
    reg [2:0]  oct3, o_c3;
    reg [11:0] e3;
    reg [8:0]  rem3;
    reg [2:0]  o_c;
    always @* begin
        o_c = 3'd0;
        if (e2 >= 12'd480)   o_c = 3'd1;
        if (e2 >= 12'd960)   o_c = 3'd2;
        if (e2 >= 12'd1_440) o_c = 3'd3;
        if (e2 >= 12'd1_920) o_c = 3'd4;
        if (e2 >= 12'd2_400) o_c = 3'd5;
        if (e2 >= 12'd2_880) o_c = 3'd6;
        if (e2 >= 12'd3_360) o_c = 3'd7;
    end
    always @(posedge clk) begin
        o_c3 <= o_c;
        e3   <= e2;
    end
    reg [11:0] o_base;
    always @* begin
        case (o_c3)
            3'd0: o_base = 12'd0;     3'd1: o_base = 12'd480;
            3'd2: o_base = 12'd960;   3'd3: o_base = 12'd1_440;
            3'd4: o_base = 12'd1_920; 3'd5: o_base = 12'd2_400;
            3'd6: o_base = 12'd2_880; default: o_base = 12'd3_360;
        endcase
    end
    always @(posedge clk) begin
        oct3 <= o_c3;
        rem3 <= e3 - o_base;
    end

    // ---- stage 4: reflected index (1 .. 480 for odd octants, where 480 only occurs at the 45-degree point, an odd octant
    // with r = 0, which takes the K45 constant) and the ROM address ----
    reg [8:0]  addr4;
    reg [2:0]  oct4;
    reg        k45_4;
    always @(posedge clk) begin
        oct4  <= oct3;
        k45_4 <= oct3[0] && (rem3 == 9'd0);
        addr4 <= (oct3[0] && rem3 != 9'd0) ? (9'd480 - rem3) : (oct3[0] ? 9'd0 : rem3);
    end

    // ---- stage 5: ROM read (a plain registered read, so it maps to the block ROM) ----
    reg [35:0] rom_q;
    reg [2:0]  oct5;
    reg        k45_5;
    always @(posedge clk) begin
        rom_q <= rom[addr4];
        oct5  <= oct4;
        k45_5 <= k45_4;
    end

    // ---- stage 6: the 45-degree constant, and the negations; stage 7: the octant sign and swap map (the match arms of
    // `tables::twiddle`), (wr, wi) = (a, -b).  They are split so that only one small adder sits in front of the multiplier's input
    // register in ft8_combine.v.  The negations are precomputed here, so that stage 7 is a plain 4-way select.  |cos| and |sin|
    // are at most 2^17 - 1, so the negations cannot overflow 18 bits. ----
    reg signed [17:0] c5, s5, nc5, ns5;
    reg [2:0]  oct6;
    wire signed [17:0] c_pick = k45_5 ? K45 : $signed(rom_q[35:18]);
    wire signed [17:0] s_pick = k45_5 ? K45 : $signed(rom_q[17:0]);
    always @(posedge clk) begin
        c5   <= c_pick;
        s5   <= s_pick;
        nc5  <= -c_pick;
        ns5  <= -s_pick;
        oct6 <= oct5;
    end
    always @(posedge clk) begin
        case (oct6)
            3'd0: begin wr <=  c5; wi <= ns5; end
            3'd1: begin wr <=  s5; wi <= nc5; end
            3'd2: begin wr <= ns5; wi <= nc5; end
            3'd3: begin wr <= nc5; wi <= ns5; end
            3'd4: begin wr <= nc5; wi <=  s5; end
            3'd5: begin wr <= ns5; wi <=  c5; end
            3'd6: begin wr <=  s5; wi <=  c5; end
            default: begin wr <= c5; wi <= s5; end // 3'd7
        endcase
    end

    // Valid flag, LATENCY clocks deep.

    // valid, LATENCY deep
    reg [LATENCY-1:0] vq;
    always @(posedge clk) begin
        if (rst) vq <= {LATENCY{1'b0}};
        else     vq <= {vq[LATENCY-2:0], in_valid};
    end
    always @* out_valid = vq[LATENCY-1];

endmodule
