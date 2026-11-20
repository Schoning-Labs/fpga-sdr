// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Behavioral model of one direction of a raw transceiver lane (docs/SFP_LINKS.md section 9), used by the SFP
// and board link benches in place of the transceiver, whose encrypted lane Gowin does not provide a
// simulation model for. A real lane carries a serial bit stream with no word boundaries, and the receiver
// cuts it into words wherever its aligner finds the pattern it looks for, so the receive logic has to cope
// with any bit position. This model reproduces that: the sender's W-bit words are laid out as one bit stream
// (bit 0 first, "low first" as in Gowin's IPUG1024 section 3.7), and the receiver cuts that stream into
// words at a bit position it does not choose (OFFSET, 0 to W-1), on a clock that is recovered from the data,
// which is the sender's clock with a delay (DELAY, in ns). The input err flips bits of the received word to
// model line errors, and cut models a dead line (no transitions), where the receiver sees zeros.
//
// Parameters: W is the word width (10 for a 1000BASE-X lane, 20 for the board link's lane), OFFSET the bit
// position at which the receiver's words start in the stream, DELAY the clock delay.

`timescale 1ns / 1ps

module sfp_lane_model #(
    parameter integer W = 10,
    parameter integer OFFSET = 3,
    parameter real    DELAY = 2.3
) (
    input  wire         tx_clk,
    input  wire [W-1:0] tx_word,
    output wire         rx_clk,
    output reg  [W-1:0] rx_word = {W{1'b0}},
    input  wire [W-1:0] err,
    input  wire         cut
);
    // prev and cur are the last two sent words; hist is the stream over those two words with the older
    // word in the low bits, so shifting it right by OFFSET and taking W bits gives the received word that
    // starts OFFSET bits into the older word and ends in the newer one.
    reg [W-1:0] prev = {W{1'b0}}, cur = {W{1'b0}};
    always @(posedge tx_clk) begin prev <= cur; cur <= tx_word; end
    wire [2*W-1:0] hist = {cur, prev};
    wire [2*W-1:0] sh = hist >> OFFSET;
    // The recovered clock is the sender's clock after DELAY ns.
    assign #(DELAY) rx_clk = tx_clk;
    // One received word per recovered clock, or zeros on a dead line, with the error bits flipped.
    always @(posedge rx_clk) rx_word <= cut ? {W{1'b0}} : (sh[W-1:0] ^ err);
endmodule
