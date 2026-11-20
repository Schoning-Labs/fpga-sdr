// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Quick self-check of the NCO mixer rtl/rx/nco_mixer.v in both of its modes. An NCO (numerically
// controlled oscillator, see docs/learn/GLOSSARY.md) is a phase accumulator, here 32 bits wide
// with one turn equal to 2^32, whose phase t is stepped by a tuning word on every sample, and
// whose sine and cosine are read from a table and refined with a small first-order correction.
// The mixer multiplies the signal by e^(jt) with it, which moves a frequency of interest down to
// zero (receive) or up to the radio frequency (transmit). Its gain is G = 107,922 / 2,048 = 52.696,
// the gain of the CORDIC mixers it replaced, so that all levels further on stay the same.
//
// Each mode is compared with the ideal mix, computed in real arithmetic from the same input
// words and the same phase sequence:
//   MODE 0 (receive): out = G x e^(jt) for a random 12 bit input x, with random tuning words, a
//     gapped in_strobe (the receiver bank's adc_valid can pause) and a tuning word of 0, which
//     holds the phase at 0. Every output must be within 0.6 |x| / 2,048 + 0.55 LSB of the ideal
//     (the table's rounding is half a step of 107,922 scaled by |x| / 2,048, and the correction's
//     truncation and the rounding of the output to 18 bits add the rest, at most about 1.2 LSB
//     in all). The number of outputs must be the number of accepted inputs minus LAT - 1 = 6, and
//     out_strobe must drop the clock after in_strobe stops and on reset.
//   MODE 1 (transmit): out = G Re{(i + jq) e^(jt)} for 24 bit random i and q on every clock. Every
//     output must be within (|i| + |q|) x 1.6 / 2,048 + 1.5 LSB of the ideal (the sine and cosine are
//     18 bits wide here, E = 0 extra fraction bits).
// The spectral test (spurious-free range at 1,000 random tuning words, and the level error) is
// tools/rb4_nco_sfdr.py with sim/rx/nco_sfdr_sim.v. docs/RX_DSP.md section 10 has its results.
//
// Pass criterion: no mismatch, the right number of outputs, no out_strobe without in_strobe.
// The bench prints "PASS" on success and "FAIL (<n>)" otherwise, with up to 10 mismatches listed,
// and the largest errors seen.
//
// Run from the repository root, as tools/check.sh does: iverilog -g2012 -o tb.vvp
// sim/rx/tb_nco_mixer.v && vvp tb.vvp

`timescale 1ns / 1ps

`include "rtl/rx/nco_mixer.v"

module tb_nco_mixer;

  // G is the mixer's gain, NCLK the number of clocks the bench runs.
  localparam real PI = 3.14159265358979323846;
  localparam real G  = 107922.0 / 2048.0;
  localparam integer NCLK = 60000;

  // The time scale is arbitrary (2 ns per period), the mixer only counts clock edges.
  reg clock = 1'b0;
  always #1 clock = ~clock;

  // Inputs shared by the two mixers: tuning word freq, strobe st for the receive mixer and the
  // random input samples (12 bit x for receive, 24 bit ti and tq for transmit).
  reg               rst = 1'b1;
  reg               st  = 1'b0;
  reg signed [31:0] freq = 32'sd0;
  reg signed [11:0] x = 12'sd0;
  reg signed [23:0] ti = 24'sd0, tq = 24'sd0;

  // The receive mixer (MODE 0, 12 bit input, 18 bit output) and the transmit mixer (MODE 1, 24 bit
  // input, 31 bit output, an input on every clock).
  wire               os;
  wire signed [17:0] oi, oq;
  wire signed [30:0] to;

  nco_mixer #(.MODE(0), .IN_WIDTH(12), .OUT_WIDTH(18)) dut_rx (
    .clock(clock), .rst(rst), .in_strobe(st), .frequency(freq),
    .in_i(x), .in_q(12'sd0), .out_strobe(os), .out_i(oi), .out_q(oq)
  );

  nco_mixer #(.MODE(1), .IN_WIDTH(24), .OUT_WIDTH(31)) dut_tx (
    .clock(clock), .rst(rst), .in_strobe(1'b1), .frequency(freq),
    .in_i(ti), .in_q(tq), .out_strobe(), .out_i(to), .out_q()
  );

  // Expected-value queues: the ideal output of each accepted receive sample, with its error
  // bound, and of each transmit clock, in real arithmetic.
  real rx_ei [0:NCLK-1];
  real rx_eq [0:NCLK-1];
  real rx_bd [0:NCLK-1];
  real tx_e  [0:NCLK-1];
  real tx_bd [0:NCLK-1];
  integer rx_wr = 0, rx_rd = 0, tx_n = 0;

  // Phase models: the receive phase advances for every accepted sample and the transmit phase on
  // every clock, in both cases held at 0 while the tuning word is 0, as the hardware does.
  reg [31:0] ph_rx = 32'd0, ph_tx = 32'd0;
  real th, err, max_rx = 0.0, max_tx = 0.0;
  integer n, seed, fails = 0, accepted = 0, outs = 0, stuck = 0;

  // Every clock, at the falling edge: choose the tuning word, the strobe and random input words,
  // work out the ideal outputs, then at the next rising edge compare the mixers' outputs with them.
  initial begin
    seed = 20260927;
    repeat (4) @(posedge clock);
    @(negedge clock) rst = 1'b0;
    for (n = 0; n < NCLK; n = n + 1) begin
      @(negedge clock);
      // A new random tuning word every 7,000 clocks, and three fixed ones in between: zero (phase
      // held), a quarter turn per sample (0x4000_0000) and a negative one.
      if (n % 7000 == 0) freq = $random(seed);
      if (n == 21000)    freq = 32'sd0;        // phase held at 0
      if (n == 24000)    freq = 32'sh40000000; // quarter turn per sample
      if (n == 28000)    freq = -32'sd12345678;
      // in_strobe: always up to clock 20,000, then 75 % of the clocks until 40,000, then 50 %, with a
      // forced pause of 10 clocks at 50,000 (out_strobe must drop during it).
      st = (n < 20000) ? 1'b1 : (n < 40000) ? (($random(seed) & 3) != 0) : ($random(seed) & 1);
      if (n >= 50000 && n < 50010) st = 1'b0;  // a pause: out_strobe must drop
      // Random input words, and at clock 30,000 the most negative values of all three inputs.
      x  = $random(seed);
      ti = $random(seed);
      tq = $random(seed);
      if (n == 30000) begin x = -12'sd2048; ti = -24'sd8388608; tq = -24'sd8388608; end

      // Ideal receive output for this sample, if it is accepted: G x e^(jt) and its error bound.
      if (st) begin
        th = 2.0 * PI * $itor(ph_rx) / 4294967296.0;
        rx_ei[rx_wr] = G * $itor(x) * $cos(th);
        rx_eq[rx_wr] = G * $itor(x) * $sin(th);
        rx_bd[rx_wr] = 0.6 * ((x < 0 ? -$itor(x) : $itor(x)) / 2048.0) + 0.55;
        rx_wr = rx_wr + 1;
        accepted = accepted + 1;
        ph_rx = (freq == 0) ? 32'd0 : ph_rx + freq;
      end
      // Ideal transmit output: G (i cos t - q sin t), and its error bound.
      th = 2.0 * PI * $itor(ph_tx) / 4294967296.0;
      tx_e[n]  = G * ($itor(ti) * $cos(th) - $itor(tq) * $sin(th));
      tx_bd[n] = ((ti < 0 ? -$itor(ti) : $itor(ti)) + (tq < 0 ? -$itor(tq) : $itor(tq))) * 1.6 / 2048.0 + 1.5;
      ph_tx = (freq == 0) ? 32'd0 : ph_tx + freq;

      // Receive check: the outputs come out in the order of the accepted samples, 6 samples later.
      @(posedge clock); #0.1;
      if (os) begin
        err = $itor(oi) - rx_ei[rx_rd];
        if (err < 0) err = -err;
        if (err > max_rx) max_rx = err;
        if (err > rx_bd[rx_rd]) begin
          if (fails < 10) $display("RX I mismatch sample %0d: got %0d want %f", rx_rd, oi, rx_ei[rx_rd]);
          fails = fails + 1;
        end
        err = $itor(oq) - rx_eq[rx_rd];
        if (err < 0) err = -err;
        if (err > max_rx) max_rx = err;
        if (err > rx_bd[rx_rd]) begin
          if (fails < 10) $display("RX Q mismatch sample %0d: got %0d want %f", rx_rd, oq, rx_eq[rx_rd]);
          fails = fails + 1;
        end
        rx_rd = rx_rd + 1;
        outs = outs + 1;
        if (!st) stuck = stuck + 1;
      end
      // Transmit: the output after this edge is the input of 7 clocks earlier (LAT = 8).
      if (n >= 7) begin
        err = $itor(to) - tx_e[n-7];
        if (err < 0) err = -err;
        if (err / (tx_bd[n-7]) > max_tx) max_tx = err / tx_bd[n-7];
        if (err > tx_bd[n-7]) begin
          if (fails < 10) $display("TX mismatch sample %0d: got %0d want %f", n-7, to, tx_e[n-7]);
          fails = fails + 1;
        end
      end
    end

    // Reset must clear out_strobe and the valid tracking at once, and the pipeline must not
    // show a valid output again until it has refilled.
    @(negedge clock); st = 1'b1; rst = 1'b1;
    @(posedge clock); #0.1;
    if (os) begin $display("out_strobe not cleared by rst"); fails = fails + 1; end
    @(negedge clock); rst = 1'b0;
    repeat (5) begin @(posedge clock); #0.1; if (os) begin $display("out_strobe before pipeline refilled"); fails = fails + 1; end end

    // Summary and final checks: one output per accepted input but the first 6, and no out_strobe
    // without in_strobe.
    $display("tb_nco_mixer: receive %0d accepted, %0d outputs, max error %f LSB; transmit max error %f of bound",
             accepted, outs, max_rx, max_tx);
    if (outs != accepted - 6) begin
      $display("output count %0d != accepted %0d - 6", outs, accepted);
      fails = fails + 1;
    end
    if (stuck != 0) begin
      $display("out_strobe high on %0d clocks without in_strobe", stuck);
      fails = fails + 1;
    end
    if (fails == 0) $display("PASS");
    else            $display("FAIL (%0d)", fails);
    $finish;
  end

endmodule
