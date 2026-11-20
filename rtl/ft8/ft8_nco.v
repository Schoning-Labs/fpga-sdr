// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ft8_nco: sine and cosine look-up for the candidate engine's oscillators.
//
// Background
//   A numerically controlled oscillator (NCO, glossary "NCO", "Phase accumulator") makes a sine wave from a counter: a 32-bit
//   phase p grows by a fixed increment each sample, so the frequency is increment x sample rate / 2^32, and the sine and
//   cosine of the phase come out of a table.  This block is the table part: it takes the phase and returns (cos, sin).
//   The candidate engine uses it twice, to mix a candidate's tones down to baseband and to rotate away the frequency offset
//   that was found for it.
//
// What it computes
//   Bit-exact with the Rust model (fw/tr-modes/src/frontend/baseband.rs `nco_index` and tables.rs `Tables::nco`).  For a 32-bit
//   phase p,
//
//   i = ((p + 2^19) mod 2^32) >> 20          (12 bits, the phase rounded to 4,096 steps)
//   (c, s) = (cos, sin)(2 pi i / 4,096) x (2^17 - 1), rounded, from the quarter wave q[0 ..= 1,024]
//
//   so the phase is rounded to one of 4,096 points of the circle, and the table result is an 18-bit signed number scaled
//   by 2^17 - 1.
//
// Why it is not rtl/rx/nco_mixer.v
//   That module is the receiver's mixer, with a half-step-offset table, a first-order Taylor correction, a gain of 52.7 and the
//   sign convention e^(+jt).  The Rust model specifies a plain rounded-index table look-up, and the hardware has to equal the
//   model bit for bit.  What is reused is its ROM layout: the quarter wave packed as 512 words of 36 bits, word j = {q[j],
//   q[1,024 - j]} (rtl/ft8/rom/ft8_nco_q512.hex, written by `ft8-frontend tables`, which also checks this module's mapping
//   against the model's table for all 4,096 indices).  That is one single-port 512 x 36 block ROM (1 block RAM).  An index
//   r = i mod 1,024 above 512 reads word 1,024 - r with the halves swapped, and r = 512 (45 degrees) is a constant.
//
// Latency
//   5 clocks from `in_valid` to `out_valid`: rounded index; ROM address and quadrant; ROM read; half select; quadrant signs.  One
//   look-up per clock.
`timescale 1ns / 1ps

`ifndef FT8_NCO_ROM
`define FT8_NCO_ROM "rtl/ft8/rom/ft8_nco_q512.hex"
`endif

module ft8_nco (
    // clk: clock (clk_dsp, 120 MHz).  in_valid with phase (32-bit unsigned, one turn = 2^32) is a look-up request.
    // out_valid, cos_o and sin_o (signed 18 bit, scale 2^17 - 1) are the answer 5 clocks later.
    input  wire               clk,
    input  wire               in_valid,
    input  wire [31:0]        phase,
    output reg                out_valid,
    output reg  signed [17:0] cos_o,
    output reg  signed [17:0] sin_o
);

    // The quarter-wave ROM, read once per look-up.
    reg [35:0] rom [0:511];
    initial $readmemh(`FT8_NCO_ROM, rom);

    // The 45-degree value, which is not in the table: q[512] = round(sin(pi / 4) x 131,071), the same constant as K45 in tables.rs.

    localparam [16:0] Q45 = 17'd92681;    // q[512] = round(sin(pi / 4) x 131,071) (tables.rs K45)

    // 1: rounded index
    reg        v1;
    reg [11:0] i1;
    // 2: address, swap, 45-degree, quadrant
    reg        v2, sw2, m2;
    reg [8:0]  a2;
    reg [1:0]  qd2;
    // 3: ROM word
    reg        v3, sw3, m3;
    reg [1:0]  qd3;
    reg [35:0] w3;
    // 4: q[r], q[1,024 - r]
    reg        v4;
    reg [1:0]  qd4;
    reg [16:0] qr4, qc4;

    wire [31:0] pr = phase + 32'h0008_0000;
    wire [9:0]  r1 = i1[9:0];
    wire [9:0]  a1 = r1[9] ? (10'd0 - r1) : r1;      // 1,024 - r for r >= 512 (mod 1,024)

    always @(posedge clk) begin
        v1 <= in_valid;
        i1 <= pr[31:20];

        v2  <= v1;
        a2  <= a1[8:0];
        sw2 <= r1[9];
        m2  <= (r1 == 10'd512);
        qd2 <= i1[11:10];

        v3  <= v2;
        w3  <= rom[a2];
        sw3 <= sw2;
        m3  <= m2;
        qd3 <= qd2;

        v4  <= v3;
        qd4 <= qd3;
        if (m3) begin
            qr4 <= Q45;
            qc4 <= Q45;
        end else if (sw3) begin
            qr4 <= w3[16:0];                 // q[r]     = q[1,024 - a]
            qc4 <= w3[34:18];                // q[1,024 - r] = q[a]
        end else begin
            qr4 <= w3[34:18];
            qc4 <= w3[16:0];
        end

        out_valid <= v4;
        case (qd4)
            2'd0: begin cos_o <=  $signed({1'b0, qc4}); sin_o <=  $signed({1'b0, qr4}); end
            2'd1: begin cos_o <= -$signed({1'b0, qr4}); sin_o <=  $signed({1'b0, qc4}); end
            2'd2: begin cos_o <= -$signed({1'b0, qc4}); sin_o <= -$signed({1'b0, qr4}); end
            default: begin cos_o <= $signed({1'b0, qr4}); sin_o <= -$signed({1'b0, qc4}); end
        endcase
    end

endmodule
