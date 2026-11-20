// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Full alias rejection test of the receiver bank rtl/rx/rx_bank.v (about 1 to 2 minutes of
// simulation, the measured results are in docs/RX_DSP.md section 6.2). A receiver reduces the
// 76.8 MHz ADC stream to a few hundred kilosamples per second by decimating in a CIC filter
// (docs/learn/GLOSSARY.md), and decimation folds every frequency that lies a whole multiple
// of the output rate away from the tuned frequency back onto it. Those alias frequencies are
// where the filter has to be at its best, so this test puts one full-scale interferer exactly
// on each receiver's worst alias frequency and measures how much of it reaches the output.
//
// Stimulus: tools/gen_signals/out/alias_test.hex, made by tools/gen_signals/gen_alias_test_signals.py
// from the worst-case frequencies that tools/analyze_alias.py computes, and the constants of
// the generated sim/alias_config.vh (ALIAS_N_SAMPLES, and for each receiver the first sample,
// the length and the rate selection of its segment). All 8 receivers are tuned to a phase
// increment of 0 (baseband) and only one at a time is enabled, during its own isolated time segment
// of the file, which holds exactly one full-scale interferer at that receiver's alias frequency.
// Whatever lands near DC in that receiver's output during its segment is the measured alias.
//
// Output: out/alias_capture.csv (every output sample, as the port delivers it) and
// out/alias_hires.csv (each receiver's FIR accumulator, 44 bits, before the rounding to the
// 24 bit output port). The residuals can be far below one count of the rounded output, and the
// accumulator is what makes rejection figures beyond 100 dB measurable. There is no pass or fail
// in this file. sim/check_alias.py reads the two CSV files and reports the rejection per receiver
// in dB against a target of 90 dB.
//
// The file is not named tb_*.v and is kept out of tools/check.sh, because it needs the generated
// stimulus and the Python checker, and it takes too long for the quick checks. check.sh runs
// sim/rx/tb_alias.v instead, a fast and self-contained single case. This one is started by
// sim/run_sim.sh, which prepares the inputs, compiles it with iverilog, runs it and runs the
// checker. The paths below are relative to the sim/ directory, where that script runs it.

`timescale 1ns/1ps

module tb_alias;

// Generated constants: ALIAS_N_SAMPLES, and ALIAS_RXn_START, _LEN and _RATE_SEL for each receiver.
`include "alias_config.vh"

// The ADC sample rate and the clock period it gives (13.02 ns). adc_valid is high on every
// clock here, so the bench runs at the ADC rate.
localparam real FS_ADC = 76.8e6;
localparam real CLK_PERIOD_NS = 1.0e9 / FS_ADC;

// The clock runs at the ADC rate.
reg clock = 1'b0;
always #(CLK_PERIOD_NS/2.0) clock = ~clock;

// Bank inputs: ADC data, valid and the register write port, with address {receiver[2:0], register}.
reg rst = 1'b1;
reg [11:0] adc_data = 12'sd0;
reg        adc_valid = 1'b0;

reg        reg_wr = 1'b0;
reg [3:0]  reg_addr = 4'd0;
reg [31:0] reg_wdata = 32'd0;

// Bank output: one tagged sample per out_valid.
wire        out_valid;
wire [2:0]  out_index;
wire signed [23:0] out_i, out_q;

// Eight receivers, 12 bit ADC samples, FIR coefficients from rtl/rx/fir_coeffs.hex.
rx_bank #(
  .N(8), .ADC_WIDTH(12), .FIR_COEFF_FILE("../rtl/rx/fir_coeffs.hex")
) dut (
  .clock(clock), .rst(rst),
  .adc_data(adc_data), .adc_valid(adc_valid),
  .reg_wr(reg_wr), .reg_addr(reg_addr), .reg_wdata(reg_wdata),
  .out_valid(out_valid), .out_index(out_index), .out_i(out_i), .out_q(out_q)
);

// The ADC stimulus, 144,000 samples (ALIAS_N_SAMPLES) of 12 bits.
reg signed [11:0] adc_mem [0:ALIAS_N_SAMPLES-1];
initial $readmemh("../tools/gen_signals/out/alias_test.hex", adc_mem);

// ---------------------------------------------------------------------
// High precision capture: the alias residuals this test looks for can be far below one count of
// the normal 24 bit rounded output, so that a reading of 0.00 there only means "below one count".
// Each receiver's fir_decim MAC accumulator (44 bits, before rounding) is probed directly, and
// sim/check_alias.py can then resolve rejection figures deeper than the output port allows.
// ---------------------------------------------------------------------
integer hifile;
genvar gk;
generate
  for (gk = 0; gk < 8; gk = gk + 1) begin : hires
    // The FIR is instantiated in rx_bank.v itself (the `firs` generate block) and not inside
    // rx_channel.v, because the FIR's delay line and the variable CIC are bank level resources
    // shared between receivers, so rx_channel.v stops at the fixed CIC (see its header).
    wire signed [43:0] hi_i = dut.firs[gk].u_fir.hi_i;
    wire signed [43:0] hi_q = dut.firs[gk].u_fir.hi_q;
    wire                hi_strobe = dut.firs[gk].u_fir.out_strobe;

    always @(posedge clock)
      if (hi_strobe)
        $fwrite(hifile, "%0d,%0d,%0d\n", gk, hi_i, hi_q);
  end
endgenerate

// File handle of the output samples, index into the stimulus and number of output samples so far.
integer outfile;
integer sample_i;
integer recnum;

// One register write: address, data and write strobe held for one clock.
task write_reg(input [3:0] addr, input [31:0] data);
  begin
    @(posedge clock);
    reg_wr    <= 1'b1;
    reg_addr  <= addr;
    reg_wdata <= data;
    @(posedge clock);
    reg_wr <= 1'b0;
  end
endtask

// Enable only receiver `idx` (control word: bit 2 = enable, bits 1:0 = rate_sel) and disable all
// the others. adc_valid is dropped during the register writes so that no receiver takes in
// stale samples of the previous segment while the configuration changes. rate_sel 0 to 3
// selects the output rates 48, 96, 192 and 384 ksps.
task set_active(input [2:0] idx, input [1:0] rate_sel);
  integer j;
  begin
    adc_valid <= 1'b0;
    for (j = 0; j < 8; j = j + 1) begin
      if (j == idx)
        write_reg({j[2:0], 1'b1}, {29'd0, 1'b1, rate_sel});
      else
        write_reg({j[2:0], 1'b1}, {29'd0, 1'b0, 2'd0});
    end
  end
endtask

// Main sequence: set up the bank, then one segment per receiver, back to back.
initial begin
  recnum = 0;
  #(CLK_PERIOD_NS*4);
  @(posedge clock);
  rst <= 1'b0;
  @(posedge clock);

  // Phase increment 0 for all 8 receivers (tuned to baseband), register 0 of each receiver.
  write_reg({3'd0,1'b0}, 32'sd0); write_reg({3'd1,1'b0}, 32'sd0);
  write_reg({3'd2,1'b0}, 32'sd0); write_reg({3'd3,1'b0}, 32'sd0);
  write_reg({3'd4,1'b0}, 32'sd0); write_reg({3'd5,1'b0}, 32'sd0);
  write_reg({3'd6,1'b0}, 32'sd0); write_reg({3'd7,1'b0}, 32'sd0);

  // CSV files: the output samples (with the stimulus index at the time of capture) and the
  // high precision accumulator readings.
  outfile = $fopen("out/alias_capture.csv", "w");
  $fwrite(outfile, "recnum,rx_index,i,q,sample\n");
  hifile = $fopen("out/alias_hires.csv", "w");
  $fwrite(hifile, "rx_index,hi_i,hi_q\n");

  // Segment of receiver 0: enable it alone with its rate, then play its part of the stimulus file,
  // one sample per clock. The following segments do the same for receivers 1 to 7. Every segment
  // is long enough for 24 output samples at its rate (the lengths halve as the rate doubles).
  set_active(3'd0, ALIAS_RX0_RATE_SEL);
  for (sample_i = ALIAS_RX0_START; sample_i < ALIAS_RX0_START+ALIAS_RX0_LEN; sample_i=sample_i+1) begin
    @(posedge clock); adc_data <= adc_mem[sample_i]; adc_valid <= 1'b1;
  end

  set_active(3'd1, ALIAS_RX1_RATE_SEL);
  for (sample_i = ALIAS_RX1_START; sample_i < ALIAS_RX1_START+ALIAS_RX1_LEN; sample_i=sample_i+1) begin
    @(posedge clock); adc_data <= adc_mem[sample_i]; adc_valid <= 1'b1;
  end

  set_active(3'd2, ALIAS_RX2_RATE_SEL);
  for (sample_i = ALIAS_RX2_START; sample_i < ALIAS_RX2_START+ALIAS_RX2_LEN; sample_i=sample_i+1) begin
    @(posedge clock); adc_data <= adc_mem[sample_i]; adc_valid <= 1'b1;
  end

  set_active(3'd3, ALIAS_RX3_RATE_SEL);
  for (sample_i = ALIAS_RX3_START; sample_i < ALIAS_RX3_START+ALIAS_RX3_LEN; sample_i=sample_i+1) begin
    @(posedge clock); adc_data <= adc_mem[sample_i]; adc_valid <= 1'b1;
  end

  set_active(3'd4, ALIAS_RX4_RATE_SEL);
  for (sample_i = ALIAS_RX4_START; sample_i < ALIAS_RX4_START+ALIAS_RX4_LEN; sample_i=sample_i+1) begin
    @(posedge clock); adc_data <= adc_mem[sample_i]; adc_valid <= 1'b1;
  end

  set_active(3'd5, ALIAS_RX5_RATE_SEL);
  for (sample_i = ALIAS_RX5_START; sample_i < ALIAS_RX5_START+ALIAS_RX5_LEN; sample_i=sample_i+1) begin
    @(posedge clock); adc_data <= adc_mem[sample_i]; adc_valid <= 1'b1;
  end

  set_active(3'd6, ALIAS_RX6_RATE_SEL);
  for (sample_i = ALIAS_RX6_START; sample_i < ALIAS_RX6_START+ALIAS_RX6_LEN; sample_i=sample_i+1) begin
    @(posedge clock); adc_data <= adc_mem[sample_i]; adc_valid <= 1'b1;
  end

  set_active(3'd7, ALIAS_RX7_RATE_SEL);
  for (sample_i = ALIAS_RX7_START; sample_i < ALIAS_RX7_START+ALIAS_RX7_LEN; sample_i=sample_i+1) begin
    @(posedge clock); adc_data <= adc_mem[sample_i]; adc_valid <= 1'b1;
  end

  // Stop feeding, then let the pipeline run out.
  @(posedge clock); adc_valid <= 1'b0;
  repeat (2000) @(posedge clock);

  $fclose(outfile);
  $fclose(hifile);
  $display("TB_ALIAS: done, %0d output records captured", recnum);
  $finish;
end

// Capture of every output sample.
always @(posedge clock) begin
  if (out_valid) begin
    $fwrite(outfile, "%0d,%0d,%0d,%0d,%0d\n", recnum, out_index, $signed(out_i), $signed(out_q), sample_i);
    recnum <= recnum + 1;
  end
end

endmodule
