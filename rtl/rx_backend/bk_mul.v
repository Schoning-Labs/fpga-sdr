// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// bk_mul: the signed multiplier that every multiplication of the receiver back end goes through
// (docs/R4_BACKEND.md). It has registered inputs and a registered product, so the result is
// there 2 clocks after the operands. Keeping every multiply in one small module means that the
// back end's DSP use can be counted by counting instances, and that the vendor primitive can be
// swapped in at one place.
//
// Every instance is at most 27 x 36 bits, which one GW5A DSP block does in a single block (its
// MULT27X36 mode, Gowin UG305 section 4.1.2); smaller operands also fit the MULTALU27X18 mode.
// The resource count in docs/R4_BACKEND.md section 7 treats this module as a black box and
// counts one DSP block per instance.
//
// Where it sits: bk_front (input scaling), bk_decim (half-band filters, 2 multipliers), bk_chfilt
// (channel filter, 4 multipliers per unit) and bk_post (demodulator and AGC, one shared
// multiplier) instantiate it.

`timescale 1ns / 1ps

module bk_mul #(
    parameter integer AW = 27,      // bits of operand a
    parameter integer BW = 36       // bits of operand b
) (
    input  wire                     clk,
    input  wire signed [AW-1:0]     a,      // first operand, two's complement
    input  wire signed [BW-1:0]     b,      // second operand, two's complement
    output reg  signed [AW+BW-1:0]  p       // exact product a x b, 2 clocks after the operands
);
    // One register for each operand and one for the product: the three stages of the DSP block.
    reg signed [AW-1:0] ar;
    reg signed [BW-1:0] br;
    always @(posedge clk) begin
        ar <= a;
        br <= b;
        p  <= ar * br;
    end
endmodule
