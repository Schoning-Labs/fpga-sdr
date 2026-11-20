// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// 8b/10b coder for two symbols per clock, for the board link's 20-bit lane words
// (docs/SFP_LINKS.md 2.2).
//
// What 8b/10b is, for a beginner: a serial line cannot carry plain bytes, because a long run of
// equal bits would give the receiver no signal edges to recover the clock from, and because the AC
// coupled transceiver needs about as many ones as zeros over time. The 8b/10b code replaces every
// byte by a 10-bit symbol that is chosen so that runs are at most five bits long and the number of
// ones and zeros stays balanced. Most symbols exist in two forms, one with more ones and one with
// more zeros, and the coder picks the one that brings the running disparity (the count of ones minus
// zeros sent so far, always -1 or +1 between symbols) back towards zero. Besides the 256 data bytes
// there are control symbols (K codes), which are used for the comma that marks symbol boundaries, for
// the start and end of frames, and for filler between frames.
//
// How it works: the code table is in rtl/n1/tab_8b10b.vh. A symbol either keeps or flips the running
// disparity whatever the disparity is (its code is either balanced or it is not), so the flip flags
// of both symbols are worked out in the first clock (bit 0 of a table entry is the running disparity after
// the symbol, so looked up with a negative start disparity it says whether the symbol flips it), and in the next clock the second symbol's disparity is one XOR of the first and the flag, and
// not a second table look-up behind the first.
//
// Output in line order: bit 0 goes on the line first (symbol 0 is d[7:0], with its bit `a`, the first
// bit of a 10-bit symbol on the line, in bit 0 of the output).
// Latency 2 clocks.

`timescale 1ns / 1ps

module sfp_enc20 (
    input  wire        clk,        // lane word clock, 125 MHz
    input  wire        rst,        // synchronous reset, running disparity to -1
    input  wire [15:0] d,       // symbol 0 in 7:0
    input  wire [1:0]  k,       // 1: the symbol in the same position is a control (K) symbol, not data
    output reg  [19:0] q = 20'd0   // two 10-bit symbols in line order, symbol 0 in bits 9:0
);

`include "tab_8b10b.vh"

    // Stage 1 registers: the input again, and the flip flags of both symbols.
    reg [15:0] d1 = 16'd0;
    reg [1:0]  k1 = 2'd0, f1 = 2'd0;
    reg        rd = 1'b0;           // running disparity before symbol 0 (0: negative, 1: positive)

    // Stage 1: table look-ups with a negative start disparity, only to read the flip flag (bit 0 of the
    // entry, which is 1 when the disparity after the symbol is positive).
    wire [10:0] e0n = k[0] ? enc8b10b_k(d[7:0], 1'b0)  : enc8b10b_d(d[7:0], 1'b0);
    wire [10:0] e1n = k[1] ? enc8b10b_k(d[15:8], 1'b0) : enc8b10b_d(d[15:8], 1'b0);
    // Stage 2: the disparity before symbol 1 is that before symbol 0, flipped if symbol 0 flips it,
    // and the real table look-ups with the right disparities.
    wire        rd1 = rd ^ f1[0];
    wire [10:0] c0 = k1[0] ? enc8b10b_k(d1[7:0], rd)   : enc8b10b_d(d1[7:0], rd);
    wire [10:0] c1 = k1[1] ? enc8b10b_k(d1[15:8], rd1) : enc8b10b_d(d1[15:8], rd1);

    always @(posedge clk) begin
        d1 <= d; k1 <= k;
        f1 <= {e1n[0], e0n[0]};
        if (rst) rd <= 1'b0;
        else     rd <= rd ^ f1[0] ^ f1[1];
        // The table has bit `a` (first on the line) at bit 9, and the lane sends bit 0 first, so
        // each symbol is written into the output with its bits in reverse order.
        q <= {c1[1], c1[2], c1[3], c1[4], c1[5], c1[6], c1[7], c1[8], c1[9], c1[10],
              c0[1], c0[2], c0[3], c0[4], c0[5], c0[6], c0[7], c0[8], c0[9], c0[10]};
    end

endmodule
