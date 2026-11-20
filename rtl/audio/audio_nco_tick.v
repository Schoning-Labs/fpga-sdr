// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// audio_nco_tick: a pulse generator for any rate that is not a whole division of the clock.
//
// What it does
//   Emits a one-clock `tick` pulse at an average rate of TICK_HZ from a clock of CLK_HZ.  The audio chain needs
//   rates such as the 12.288 MHz bit clock of the DAC, and 120 MHz / 12.288 MHz = 9.765625 is not a whole number,
//   so a plain counter that divides by an integer cannot produce it.  The remedy is a phase accumulator, the
//   same idea as a numerically controlled oscillator (glossary entries "NCO", "Phase accumulator" and "Phase
//   increment" in docs/learn/GLOSSARY.md): a register adds a fixed increment on every clock, and each time the
//   addition overflows, one tick is emitted.  The method is called fractional-N division, or
// direct-digital-synthesis, the standard technique for deriving a non-integer clock ratio
//   without a PLL.
//
// Where it sits in the radio
//   One instance per rate, inside audio_pt8211_tx.v (TICK_HZ = 2 x the DAC bit clock, since every tick flips the
//   bit clock register) and inside audio_spdif_tx.v (TICK_HZ = 128 x the sample rate, the S/PDIF cell rate).
//
// How it works
//   The increment is INC = round(TICK_HZ x 2^ACC_WIDTH / CLK_HZ).  The accumulator wraps once every 2^ACC_WIDTH / INC
//   clocks, which is CLK_HZ / TICK_HZ clocks on average, so the carry out of the addition is a pulse train at TICK_HZ.
//   For the DAC bit clock of 12.288 MHz the tick rate is 24.576 MHz, INC = 0.2048 x 2^32 = 879,609,302, and
//   the carry comes out on 1 clock in 4.88.  The pulses are one clock wide and never closer than one clock apart
//   (they can be on consecutive clocks only if TICK_HZ is above half of CLK_HZ).
//
// Accuracy
//   Because the ratio is not an integer, the clocks between pulses alternate (for example 4 and 5) and any single
//   tick can be up to one clock period early or late (8.3 ns at 120 MHz) compared with the ideal time.  The long-run
//   rate is exact to within the rounding of INC, which is better than one part in 2^ACC_WIDTH of the increment, and
//   for the rates used here a few thousandths of a part per million.  docs/A1_AUDIO.md works out the frequency
//   error and the signal-to-noise cost of the jitter, which is negligible for 16-bit audio.
//
// Latency and resources
//   The carry is registered, so `tick` appears one clock after the addition that produced it.  The block is one
//   32-bit adder and 33 flip-flops, no block RAM and no DSP.

`timescale 1ns / 1ps

    // CLK_HZ is the frequency of `clk`, TICK_HZ the wanted average tick rate, ACC_WIDTH the width of the phase
    // accumulator (more bits give a finer increment and so a smaller rate error).
module audio_nco_tick #(
    parameter integer CLK_HZ    = 120_000_000,
    parameter integer TICK_HZ   = 384_000,
    parameter integer ACC_WIDTH = 32
) (
    // Clock and synchronous reset (active high).  tick is the output pulse, one clock wide.
    input  wire clk,
    input  wire rst,
    output reg  tick
);

    // The increment is computed at elaboration time with real arithmetic (it is not built as logic), because
    // TICK_HZ x 2^ACC_WIDTH would overflow a 32-bit integer, and it is rounded to the nearest whole number.
    localparam real INC_REAL = (TICK_HZ * 1.0 * (2.0 ** ACC_WIDTH)) / (CLK_HZ * 1.0);
    localparam [ACC_WIDTH-1:0] INC = $rtoi(INC_REAL + 0.5);

    // acc is the phase accumulator.  sum is one bit wider than acc, so that bit ACC_WIDTH is the carry out.
    reg  [ACC_WIDTH-1:0] acc;
    wire [ACC_WIDTH:0]   sum = {1'b0, acc} + {1'b0, INC};

    // Add INC every clock and register the carry as the tick.

    always @(posedge clk) begin
        if (rst) begin
            acc  <= {ACC_WIDTH{1'b0}};
            tick <= 1'b0;
        end else begin
            acc  <= sum[ACC_WIDTH-1:0];
            tick <= sum[ACC_WIDTH];
        end
    end

endmodule
