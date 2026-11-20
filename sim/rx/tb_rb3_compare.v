// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Equivalence test of the current receiver bank rtl/rx/rx_bank.v against the earlier form of the
// same bank, which is kept in sim/rx/ref/ (renamed rx_bank_ref and so on, so that both can be
// compiled into one bench). The current bank shares work between its receivers where the earlier
// one had a private copy for each: two shared 5 stage variable CIC engines replace one dedicated
// variable CIC per receiver, and the FIR delay lines are circular buffers in memory instead of a
// shift register plus a snapshot copy (docs/ARCHITECTURE.md 3.14, changes C2 and C3, and
// docs/RX_DSP.md; the filter terms are explained in docs/learn/GLOSSARY.md). Those changes
// save logic and are meant to leave the output unchanged, and this bench shows that. The
// reference's mixer is the same rtl/rx/nco_mixer.v as the current bank's, so what is compared is
// exactly the part that was reorganized.
//
// Stimulus: the same pseudo-random 12 bit ADC samples, the same clock and the same
// schedule of register writes go into both banks. All 8 receivers are active together,
// two per output rate (48, 96, 192 and 384 ksps), tuned across the HF band, which is the arrangement
// of docs/RX_DSP.md section 6.1 and of the CHANNELS table in fw/tr-rxmodel/src/bin/r2_check.rs.
// There are two passes of 30,000 ADC cycles each. In the first adc_valid is high on every
// clock, the steady full rate case. In the second it is bursty with an average duty of
// about 51 %, which is the case that the sizing of the shared CIC engines assumes: the fixed CIC
// stages (decimate by 10) of all receivers deliver on the same clock, and a burst is when the
// round-robin that drains the shared engines is busiest.
//
// Pass criterion: every out_valid word of each bank is captured (receiver index, I, Q) in the
// order in which it was emitted, and the two sequences must be equal word for word, including the
// order and the number of words, which is the way fw/tr-rxmodel compares the RTL with its
// model (sim/rx/r2_replay.v). The bench prints "PASS" on success and "FAIL" otherwise, with up to 10
// mismatching words. It compares the two streams of values, and not cycle by cycle, because the
// current bank has a different internal pipeline latency (the same for all receivers, and always
// resolved well within the margin of at least 10 clocks that the sizing assumes), which
// never shows up at the bank's interface (see the headers of cic_var_shared.v and fir_decim.v).
// The comparison of the RTL with the Rust model, which mirrors the earlier per instance timing,
// still passes bit exactly and confirms that the emitted values and their order are the same.
//
// Run from the repository root, as tools/check.sh does: iverilog -g2012 -o tb.vvp
// sim/rx/tb_rb3_compare.v && vvp tb.vvp (add -DTB_NRX=4 to compare four receivers).

`timescale 1ns / 1ps

`include "rtl/rx/nco_mixer.v"
`include "rtl/rx/cic_integrator.v"
`include "rtl/rx/cic_comb.v"
`include "rtl/rx/cic_fixed.v"
`include "rtl/rx/cic_var_shared.v"
`include "rtl/rx/fir_decim.v"
`include "rtl/rx/fir_delay_ram2.v"
`include "rtl/rx/rx_channel.v"
`include "rtl/rx/rx_bank.v"

`include "sim/rx/ref/cic_integrator.v"
`include "sim/rx/ref/cic_comb.v"
`include "sim/rx/ref/cic_fixed.v"
`include "sim/rx/ref/cic_var.v"
`include "sim/rx/ref/fir_decim.v"
`include "sim/rx/ref/rx_channel.v"
`include "sim/rx/ref/rx_bank.v"

module tb_rb3_compare;

`ifndef TB_NRX
`define TB_NRX 8      // receivers: -DTB_NRX=4 compares the 4-receiver bank (the chip's default)
`endif
  // N receivers in both banks (8 unless TB_NRX says otherwise), ADC sample rate for the tuning words.
  localparam N = `TB_NRX;
  localparam FS_HZ = 76_800_000.0;

  // The time scale is arbitrary (2 ns per period), the banks only count clock edges.
  reg clock = 1'b0;
  always #1 clock = ~clock;

  // Inputs shared by both banks, and the output stream of each (the current bank is "new", the
  // reference "ref").
  reg         rst = 1'b1;
  reg  [11:0] adc_data = 12'sd0;
  reg         adc_valid = 1'b0;
  reg         reg_wr = 1'b0;
  reg  [3:0]  reg_addr = 4'd0;
  reg  [31:0] reg_wdata = 32'd0;

  wire        new_valid; wire [2:0] new_index; wire signed [23:0] new_i, new_q;
  wire        ref_valid; wire [2:0] ref_index; wire signed [23:0] ref_i, ref_q;

  // The current bank and the earlier reference bank, side by side on the same inputs.
  rx_bank #(.N(N), .ADC_WIDTH(12), .FIR_COEFF_FILE("rtl/rx/fir_coeffs.hex")) dut_new (
    .clock(clock), .rst(rst),
    .adc_data(adc_data), .adc_valid(adc_valid),
    .reg_wr(reg_wr), .reg_addr(reg_addr), .reg_wdata(reg_wdata),
    .out_valid(new_valid), .out_index(new_index), .out_i(new_i), .out_q(new_q)
  );

  rx_bank_ref #(.N(N), .ADC_WIDTH(12), .FIR_COEFF_FILE("rtl/rx/fir_coeffs.hex")) dut_ref (
    .clock(clock), .rst(rst),
    .adc_data(adc_data), .adc_valid(adc_valid),
    .reg_wr(reg_wr), .reg_addr(reg_addr), .reg_wdata(reg_wdata),
    .out_valid(ref_valid), .out_index(ref_index), .out_i(ref_i), .out_q(ref_q)
  );

  // ------------------------------------------------------------------------------------------
  // Capture both streams on the falling edge, clear of the updates at the rising edge (see
  // r2_replay.v). Each word is stored with its receiver index, in the order of emission.
  // ------------------------------------------------------------------------------------------
  localparam MAXW = 20000;
  reg [2:0]  new_idx_q [0:MAXW-1]; reg signed [23:0] new_i_q [0:MAXW-1]; reg signed [23:0] new_q_q [0:MAXW-1];
  reg [2:0]  ref_idx_q [0:MAXW-1]; reg signed [23:0] ref_i_q [0:MAXW-1]; reg signed [23:0] ref_q_q [0:MAXW-1];
  integer new_count, ref_count;

  always @(negedge clock) begin
    if (new_valid) begin
      new_idx_q[new_count] <= new_index; new_i_q[new_count] <= new_i; new_q_q[new_count] <= new_q;
      new_count <= new_count + 1;
    end
    if (ref_valid) begin
      ref_idx_q[ref_count] <= ref_index; ref_i_q[ref_count] <= ref_i; ref_q_q[ref_count] <= ref_q;
      ref_count <= ref_count + 1;
    end
  end

  // ------------------------------------------------------------------------------------------
  // Deterministic 12 bit ADC stimulus from a xorshift32 generator, the same generator as in
  // fw/tr-rxmodel/src/bin/r2_check.rs, so that both comparisons are exercised in the same way. The
  // sample is the low 12 bits of the generator state.
  // ------------------------------------------------------------------------------------------
  reg [31:0] prng;
  function [31:0] xorshift32;
    input [31:0] x_in;
    reg [31:0] x;
    begin
      x = x_in;
      x = x ^ (x << 13);
      x = x ^ (x >> 17);
      x = x ^ (x << 5);
      xorshift32 = x;
    end
  endfunction

  function signed [11:0] prng_sample;
    input [31:0] x;
    begin
      prng_sample = x[11:0];
    end
  endfunction

  // One register write: address, data and write strobe held for one clock.
  task write_reg(input [3:0] addr, input [31:0] data);
    begin
      @(posedge clock);
      reg_wr <= 1'b1; reg_addr <= addr; reg_wdata <= data;
      @(posedge clock);
      reg_wr <= 1'b0;
    end
  endtask

  // The tuning word for a frequency: frequency / sample rate x 2^32.
  function [31:0] phase_inc_for(input real freq_hz);
    phase_inc_for = $rtoi((freq_hz / FS_HZ) * 4294967296.0);
  endfunction

  // Two receivers per output rate, spread across the HF band, as in docs/RX_DSP.md section 6.1 and
  // in the CHANNELS table of fw/tr-rxmodel's r2_check.rs. The rate codes 0 to 3 stand for 48, 96,
  // 192 and 384 ksps.
  real freqs [0:7];
  reg [1:0] rates [0:7];

  integer k;
  integer errors;

  // Tune and enable all receivers, then run the two passes and compare.
  initial begin
    freqs[0] = 1_840_000.0;  rates[0] = 2'd0;
    freqs[1] = 3_573_000.0;  rates[1] = 2'd0;
    freqs[2] = 7_074_000.0;  rates[2] = 2'd1;
    freqs[3] = 10_136_000.0; rates[3] = 2'd1;
    freqs[4] = 14_074_000.0; rates[4] = 2'd2;
    freqs[5] = 18_100_000.0; rates[5] = 2'd2;
    freqs[6] = 21_074_000.0; rates[6] = 2'd3;
    freqs[7] = 28_074_000.0; rates[7] = 2'd3;

    new_count = 0;
    ref_count = 0;
    prng = 32'h1234_5678;
    errors = 0;

    repeat (5) @(posedge clock);
    rst = 1'b0;
    @(posedge clock);

    // Write each receiver's tuning word (register 0) and control word (register 1: enable and rate).
    for (k = 0; k < N; k = k + 1) begin
      write_reg({k[2:0], 1'b0}, phase_inc_for(freqs[k]));
      write_reg({k[2:0], 1'b1}, {29'd0, 1'b1, rates[k]});
    end

    // ---- pass 1: adc_valid on every clock, 30,000 ADC cycles ----------------------------
    for (k = 0; k < 30000; k = k + 1) begin
      @(posedge clock);
      prng <= xorshift32(prng);
      adc_data  <= prng_sample(prng);
      adc_valid <= 1'b1;
    end

    // ---- pass 2: adc_valid bursty at about 51 % duty, 30,000 ADC cycles (65 of 128 values of
    // the random bits give a valid sample, 50.8 %) ----------------------------------------
    for (k = 0; k < 30000; k = k + 1) begin
      @(posedge clock);
      prng <= xorshift32(prng);
      adc_valid <= (prng[6:0] < 65); // 65/128 ~= 50.8%
      adc_data  <= prng_sample(prng);
    end

    // Stop feeding, let both banks run out and capture the last words.
    adc_valid <= 1'b0;
    repeat (64) @(posedge clock);
    @(negedge clock);

    // Compare the two captured sequences: first the number of words, then each word.
    $display("new: %0d words, ref: %0d words", new_count, ref_count);
    if (new_count != ref_count) begin
      $display("FAIL: word count differs: new=%0d ref=%0d", new_count, ref_count);
      errors = errors + 1;
    end else begin
      for (k = 0; k < new_count; k = k + 1) begin
        if (new_idx_q[k] !== ref_idx_q[k] || new_i_q[k] !== ref_i_q[k] || new_q_q[k] !== ref_q_q[k]) begin
          if (errors < 10)
            $display("mismatch at word %0d: new=(%0d,%0d,%0d) ref=(%0d,%0d,%0d)",
                      k, new_idx_q[k], new_i_q[k], new_q_q[k], ref_idx_q[k], ref_i_q[k], ref_q_q[k]);
          errors = errors + 1;
        end
      end
    end

    // The capture buffers must not have been filled to the end.
    if (new_count >= MAXW || ref_count >= MAXW) begin
      $display("FAIL: capture buffer too small (MAXW=%0d)", MAXW);
      errors = errors + 1;
    end

    if (errors == 0) $display("PASS");
    else $display("FAIL: %0d error(s)", errors);
    $finish;
  end

endmodule
