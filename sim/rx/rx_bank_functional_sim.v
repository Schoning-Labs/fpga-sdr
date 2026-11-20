// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Full functional test of the receiver bank rtl/rx/rx_bank.v with eight receivers (about 2 minutes
// of simulation, the measured results are in docs/RX_DSP.md section 6.1). Each receiver of the
// bank multiplies the 76.8 MHz ADC stream by a numerically controlled oscillator to move its
// tuned frequency down to zero, then decimates with a CIC filter and a compensating FIR
// (docs/learn/GLOSSARY.md) to an output rate of 48, 96, 192 or 384 ksps, and the bank delivers
// all outputs on one stream tagged with the receiver number. This test checks that every receiver
// puts its wanted tone at the right baseband frequency and at the right level.
//
// Stimulus: tools/gen_signals/out/adc_test.hex, a file of 12 bit ADC samples (N_SAMPLES of them, one
// per clock, 307,200 = 4 ms at 76.8 MHz) with a test tone for each receiver, and the constants
// of the generated sim/rx_config.vh: for each receiver RXn_PHASE_INC (the tuning word, the
// frequency divided by 76.8 MHz times 2^32) and RXn_RATE_SEL (the output rate). Both files come
// from tools/gen_signals/gen_test_signals.py, and all 8 receivers are tuned and enabled
// before the first sample goes in.
//
// Output: out/rx_capture.csv with one line per output sample, "recnum,rx_index,i,q", all receivers
// interleaved in time order. There is no pass or fail in this file. sim/check_results.py does
// an FFT per receiver and reports the baseband frequency error, the amplitude error against
// the input level (within 0.5 dB, after one calibration constant common to all receivers) and
// the strongest spur, and prints "ALL CHECKS PASSED" or "FAILED".
//
// The file is not named tb_*.v and is kept out of tools/check.sh, because it needs the generated
// stimulus and the Python checker, and it takes too long for the quick checks. check.sh runs
// sim/rx/tb_rx_bank.v instead, a fast smoke test with no generated inputs. This one is started by
// sim/run_sim.sh, which generates the test file, compiles it with iverilog, runs it and runs the
// checker. The paths below are relative to the sim/ directory, where that script runs it.

`timescale 1ns/1ps

module tb_rx_bank;

// Generated constants: N_SAMPLES, and RXn_PHASE_INC and RXn_RATE_SEL for each receiver.
`include "rx_config.vh"

// The ADC sample rate and the clock period it gives (13.02 ns). adc_valid is high on every
// clock here, so the bench runs at the ADC rate.
localparam real FS_ADC = 76.8e6;
localparam real CLK_PERIOD_NS = 1.0e9 / FS_ADC;

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

// The ADC stimulus.
reg signed [11:0] adc_mem [0:N_SAMPLES-1];
initial $readmemh("../tools/gen_signals/out/adc_test.hex", adc_mem);

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

// Main sequence: reset, tune and enable the receivers, play the stimulus one sample per clock,
// drain the pipeline and close the file.
initial begin
  recnum = 0;
  #(CLK_PERIOD_NS*4);
  @(posedge clock);
  rst <= 1'b0;
  @(posedge clock);

  // Register address is {channel[2:0], regtype}, where regtype 0 is the phase increment and 1 is
  // the control word {enable, rate_sel[1:0]}.
  write_reg({3'd0,1'b0}, RX0_PHASE_INC); write_reg({3'd0,1'b1}, {29'd0,1'b1,RX0_RATE_SEL});
  write_reg({3'd1,1'b0}, RX1_PHASE_INC); write_reg({3'd1,1'b1}, {29'd0,1'b1,RX1_RATE_SEL});
  write_reg({3'd2,1'b0}, RX2_PHASE_INC); write_reg({3'd2,1'b1}, {29'd0,1'b1,RX2_RATE_SEL});
  write_reg({3'd3,1'b0}, RX3_PHASE_INC); write_reg({3'd3,1'b1}, {29'd0,1'b1,RX3_RATE_SEL});
  write_reg({3'd4,1'b0}, RX4_PHASE_INC); write_reg({3'd4,1'b1}, {29'd0,1'b1,RX4_RATE_SEL});
  write_reg({3'd5,1'b0}, RX5_PHASE_INC); write_reg({3'd5,1'b1}, {29'd0,1'b1,RX5_RATE_SEL});
  write_reg({3'd6,1'b0}, RX6_PHASE_INC); write_reg({3'd6,1'b1}, {29'd0,1'b1,RX6_RATE_SEL});
  write_reg({3'd7,1'b0}, RX7_PHASE_INC); write_reg({3'd7,1'b1}, {29'd0,1'b1,RX7_RATE_SEL});

  outfile = $fopen("out/rx_capture.csv", "w");
  $fwrite(outfile, "recnum,rx_index,i,q\n");

  // One ADC sample per clock.
  for (sample_i = 0; sample_i < N_SAMPLES; sample_i = sample_i + 1) begin
    @(posedge clock);
    adc_data  <= adc_mem[sample_i];
    adc_valid <= 1'b1;
  end
  @(posedge clock);
  adc_valid <= 1'b0;

  // Drain the pipeline for 5,000 clocks (the deepest path is cic_fixed, cic_var and fir_decim).
  repeat (5000) @(posedge clock);

  $fclose(outfile);
  $display("TB_RX_BANK: done, %0d output records captured", recnum);
  $finish;
end

// Capture of every output sample.
always @(posedge clock) begin
  if (out_valid) begin
    $fwrite(outfile, "%0d,%0d,%0d,%0d\n", recnum, out_index, $signed(out_i), $signed(out_q));
    recnum <= recnum + 1;
  end
end

endmodule
