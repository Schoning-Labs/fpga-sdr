// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ladder_cnt_x: an event counter in one clock domain whose value can be read safely in another, used by the bring-up ladder
// (rtl/top/ladder_top.v) to bring counts of events in each clock into the AHB clock for the register page. The counter comes
// from an earlier design by the same author, where it has the same name apart from the prefix.
//
// HOW IT WORKS
// A counter c counts pulses of `inc` in the source clock clk_s. Reading a multi-bit value in an unrelated clock is unsafe,
// because several bits change at once and a sample taken at the wrong instant can mix old and new bits into a number that was
// never the count. The fix here is a Gray code: g = c ^ (c >> 1) changes only one bit when c steps by one, so a sample taken
// during a step is either the old count or the new one, and a read taken while the counter steps is off by one at most,
// never torn. g is registered in clk_s, passed through two registers in the destination clock clk_d (the synchronizer, which
// gives a signal that arrives at a random instant time to settle), turned back into binary by a chain of XORs (b[i] is the
// XOR of all Gray bits from the top down to i), and registered once more in clk_d as q_d.
// The count wraps at 2^W. For the Gray argument to hold, `inc` must come far less often than clk_d samples (the pulses in the
// ladder are thousands of clocks apart). Latency from `inc` to the changed q_d: one clk_s clock for the counter and
// one for the Gray register, two clk_d clocks for the synchronizer and one for the output register.
// See docs/learn/GLOSSARY.md for Gray code and clock domain crossing.
`timescale 1ns / 1ps
// W = width of the counter in bits (16 in the ladder).
module ladder_cnt_x #(parameter integer W = 16) (
    input  wire         clk_s,  // source clock, the clock in which the events happen
    input  wire         inc,  // one-clock event pulse in clk_s, counted when high
    input  wire         clk_d,  // destination clock, the clock in which q_d is read
    output reg  [W-1:0] q_d  // the count in clk_d, wraps at 2^W, off by one at most while the counter steps
) /* synthesis syn_maxfan = 10000 */;
    // c = the binary count in clk_s, g = its Gray code, registered
    reg [W-1:0] c = {W{1'b0}}, g = {W{1'b0}};
    // count the pulses and register the Gray code of the count (it lags c by one clock)
    always @(posedge clk_s) begin
        if (inc) c <= c + 1'b1;
        g <= c ^ (c >> 1);
    end
    // s1 and s2 = the two synchronizer registers in the destination clock
    reg [W-1:0] s1 = {W{1'b0}}, s2 = {W{1'b0}};
    // two registers in clk_d: the second one is the value that is used
    always @(posedge clk_d) begin s1 <= g; s2 <= s1; end
    // b = the Gray code of s2 turned back into binary
    reg [W-1:0] b;
    integer i;
    // Gray to binary: the top bit is the same, and every lower bit is the bit above it XOR the Gray bit
    always @* begin
        b[W-1] = s2[W-1];
        for (i = W - 2; i >= 0; i = i - 1) b[i] = b[i+1] ^ s2[i];
    end
    // the binary count, registered in clk_d
    always @(posedge clk_d) q_d <= b;
endmodule
