// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// fft_mul: a signed multiplier with a registered product (result one clock after the operands),
// used by the FFT's twiddle multipliers (rtl/fft/fft_twmul.v). A twiddle multiplier turns one
// complex multiply into four of these. It is kept in its own module so that a vendor wrapper
// can replace it without touching the FFT; as written it uses generic inference, and the Gowin
// tools map it to one DSP block when the operands fit the block's 27 x 18 multiplier (AW <= 27
// and BW <= 18). In the full-band FFT there are 6 twiddle multipliers, so 24 of these.

`timescale 1ns / 1ps

module fft_mul #(
    parameter integer AW = 27,       // bits of operand a (the data)
    parameter integer BW = 18        // bits of operand b (the twiddle factor)
) (
    input  wire                     clk,
    input  wire signed [AW-1:0]     a,      // data, two's complement
    input  wire signed [BW-1:0]     b,      // twiddle factor, two's complement
    output reg  signed [AW+BW-1:0]  p       // exact product, one clock after the operands
);
    always @(posedge clk) p <= a * b;
endmodule
