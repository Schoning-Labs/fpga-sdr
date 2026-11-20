// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Toggle handshake: carries a wide word from one clock domain into another one when the word
// changes only rarely.
//
// Why it exists: the radio has several clocks that have no fixed phase relation (the 125 MHz clock
// recovered from the SFP lane, the 125 MHz transmit clock of the lane, and the 120 MHz clk_dsp
// where the registers and receivers live). A multi-bit value cannot just be copied from one of
// them into another, because a flip-flop that samples at the very moment its input changes can
// capture a mix of old and new bits, and with a 32-bit counter that would show up as an
// occasional absurd reading. A two-flop synchronizer only protects a single bit, so for a word
// the trick is to hold the word still, send one single bit that says "the word is ready now", and
// only look at the word after that bit has arrived.
//
// Where it is used: frame header fields and statistics counters of the HL2 link, which change at
// most once per received frame (tens of microseconds apart at gigabit rate), and settings written
// by the CPU. The destination runs at 120 MHz, so there is always plenty of time for the
// handshake to settle. It is not for a word that can change every clock; use a real asynchronous
// FIFO for that (cdc_sample_fifo.v carries the sample stream itself).
//
// Protocol, step by step:
//   1. The source side puts the word on `d_a` and pulses `send_a` for one clock, once `d_a` is
//      stable.
//   2. On that pulse the word is copied into `hold_a` and the bit `toggle_a` flips. `hold_a` then
//      does not change until the next pulse.
//   3. The toggle bit travels through a chain of flip-flops in the destination clock. The word is
//      not synchronized bit by bit at all, since only the single toggle bit is.
//   4. When the destination sees the toggle change, `hold_a` has been stable for at least three
//      destination clocks already, so it is copied into `q_b` and `valid_b` pulses for one clock.
//
// The source must not pulse `send_a` again before the previous word has arrived (a few destination
// clocks, i.e. well under a microsecond), otherwise `hold_a` could change while it is being
// copied. All callers send at most once per frame, which is thousands of clocks apart.
//
// Latency: three to four destination clocks from `send_a` to `valid_b`.

`timescale 1ns / 1ps

module cdc_word #(
    parameter W = 32            // width of the word in bits
) (
    input  wire         clk_a,    // source clock
    input  wire [W-1:0] d_a,      // the word to send, must be stable when send_a pulses
    input  wire         send_a,   // one-clock pulse in clk_a: take d_a and send it
    input  wire         clk_b,    // destination clock
    output reg  [W-1:0] q_b,      // the received word, holds its value until the next one arrives
    output reg           valid_b  // one-clock pulse in clk_b: q_b has just been updated
) /* synthesis syn_srlstyle = "registers" */;

    // Source side: the word register and the toggle bit. The toggle flips once per word sent.
    reg [W-1:0] hold_a = {W{1'b0}};
    reg         toggle_a = 1'b0;

    always @(posedge clk_a) begin
        if (send_a) begin
            hold_a   <= d_a;
            toggle_a <= ~toggle_a;
        end
    end

    // Destination side: a three-flop synchronizer on the toggle (one more than the usual two,
    // because the source here is a clock that is recovered from the line and so is a little less
    // clean), then an edge detect on its last two stages, which finds the moment the toggle
    // changed, and then the capture of the word, which has long since settled. q_b and valid_b
    // update together so that a consumer can latch q_b in the same clock in which valid_b is high,
    // without a one-clock skew between them.
    (* preserve *) reg [2:0] sync_b = 3'b000;

    always @(posedge clk_b) begin
        sync_b <= {sync_b[1:0], toggle_a};
        valid_b <= 1'b0;
        if (sync_b[2] ^ sync_b[1]) begin
            q_b     <= hold_a;
            valid_b <= 1'b1;
        end
    end

endmodule
