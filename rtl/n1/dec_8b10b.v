// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// 8b/10b decoder, the counterpart of enc_8b10b.v: one 10-bit code group in, one decoded byte out, per
// clock (see sfp_enc20.v for what 8b/10b is). It works on the received symbol after the comma
// alignment has cut the stream into symbols (the aligner and decoder that the SFP lane actually uses are
// in sfp_rx_sym.v, which calls the same table function `dec8b10b`; this module wraps it for testbenches
// and for logic that has symbols already). The table is in rtl/n1/tab_8b10b.vh. A code group that does not
// exist in the alphabet (a bit error) is reported as `invalid`, and one of the 12 control symbols as `kout`.
//
// Latency: 1 clock.

`timescale 1ns / 1ps

module dec_8b10b (
    input  wire       clk,         // lane word clock
    input  wire       rst,         // synchronous reset, active high

    input  wire [9:0] code,     // received 10-bit code group

    output reg  [7:0] dout,     // decoded byte ({y[2:0],x[4:0]} packing, same as enc_8b10b din)
    output reg        kout,     // 1: dout is one of the 12 legal K control codes
    output reg        invalid,  // 1: `code` is not a legal 8b/10b code group this cycle
    output reg        valid     // 0 for the first cycle after rst
);

`include "tab_8b10b.vh"

    wire [9:0] dec = dec8b10b(code);

    always @(posedge clk) begin
        if (rst) begin
            dout    <= 8'h00;
            kout    <= 1'b0;
            invalid <= 1'b0;
            valid   <= 1'b0;
        end else begin
            invalid <= ~dec[9];
            kout    <= dec[8];
            dout    <= dec[7:0];
            valid   <= 1'b1;
        end
    end

endmodule
