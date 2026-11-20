// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// A status word carried from one clock domain into another one (docs/SFP_LINKS.md section 3).
//
// Why it exists: the transceiver lanes give the logic two clocks of their own, a recovered receive
// clock and a transmit clock, and the PCS reports its state (link up, negotiation done, aligner
// locked, counters) into clk_dsp, where the register bus lives. Those clocks are asynchronous to each
// other, so every status word has to cross with care, and cdc_word.v (a toggle handshake, which
// holds the word still while a single toggle bit travels over) does that.
//
// How it works: every 16 source clocks the word is sent through a cdc_word, which keeps the crossing
// load low, because status changes slowly. The destination remembers the newest word in `q_b`
// and pulses `upd_b` for one clock when it has been loaded.
//
// Why there is an age counter: a lane clock can stop altogether (no module in the cage, the transceiver
// held in reset), and then no word arrives any more. Without a safeguard `q_b` would keep showing the
// last word, which could say "link up" for a link that is gone. When no word has come for 2^AGE
// destination clocks, the output goes back to the idle value and `alive` is 0, so nothing downstream
// acts on a stale word.

`timescale 1ns / 1ps

module sfp_xstat #(
    parameter integer W = 16,                  // width of the status word
    parameter integer AGE = 8,                 // a word is stale after 2**AGE destination clocks
    parameter [W-1:0] IDLE = {W{1'b0}}         // the value shown while no word arrives
) (
    input  wire         clk_a,                 // source clock (a lane clock, which may stop)
    input  wire [W-1:0] d_a,                   // status word in the source clock
    input  wire         clk_b,                 // destination clock
    output reg  [W-1:0] q_b = IDLE,            // the status word, or IDLE when stale
    output reg          alive = 1'b0,          // a word has arrived recently
    output reg          upd_b = 1'b0      // q_b was loaded in the last clock
);
    // A 4-bit counter in the source clock gives one send every 16 clocks.
    reg [3:0] tick = 4'd0;
    always @(posedge clk_a) tick <= tick + 4'd1;

    wire [W-1:0] w;
    wire         v;
    cdc_word #(.W(W)) u_x (.clk_a(clk_a), .d_a(d_a), .send_a(tick == 4'd0), .clk_b(clk_b), .q_b(w), .valid_b(v));

    // `age` counts destination clocks since the last word. Its top bit set means "stale".
    reg [AGE:0] age = {(AGE+1){1'b1}};
    always @(posedge clk_b) begin
        upd_b <= v;
        if (v) begin
            q_b <= w; alive <= 1'b1; age <= {(AGE+1){1'b0}};
        end else if (age[AGE]) begin
            q_b <= IDLE; alive <= 1'b0;
        end else age <= age + 1'b1;
    end
endmodule
