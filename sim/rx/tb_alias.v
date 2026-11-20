// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Quick, self-contained alias rejection test of the receiver bank rtl/rx/rx_bank.v with one
// receiver, run by tools/check.sh (a few seconds). Decimating by a CIC filter folds every
// frequency that lies a whole multiple of the filter's output rate away from the tuned frequency
// back onto it (docs/learn/GLOSSARY.md), and the filter chain has to suppress those alias
// frequencies by at least 90 dB (docs/DECISIONS.md). The full test, with all four output rates
// and both decimating stages, is sim/rx/rx_alias_sim.v started by sim/run_sim.sh (the results are
// in docs/RX_DSP.md section 6.2). This file checks only the one case that
// tools/analyze_alias.py found to have the least margin of the 8 cases (4 rates times 2 stages),
// which is the fixed CIC stage at 384 ksps, so that it fits into the quick checks.
//
// Method: the receiver is tuned to baseband (phase increment 0) and fed a full-scale cosine at
// 7,587,840 Hz, which is 92.16 kHz below 7.68 MHz, the output rate of the fixed CIC stage
// (decimation 10 from 76.8 MHz), at the edge of the passband of the 384 ksps setting. That
// is the frequency that folds into the passband with the least attenuation (the file
// tools/gen_signals/out/alias_plan.json, written by tools/analyze_alias.py, shows how it is
// derived). Whatever then lands near DC is the alias.
//
// The measurement is taken from the 44 bit accumulator of the FIR (before its rounding to the
// 24 bit output) and not from the output port. In this noiseless simulation, without
// dither, a residual below one output count reads as exactly 0, which cannot tell 90 dB from 150
// dB apart, and the wider accumulator can (sim/check_alias.py has the same reasoning).
//
// Pass criterion: the rejection, which is 20 log10 of the magnitude that a full-scale on-tune
// tone would give over the magnitude of the residual, must be at least 90 dB. The bench prints
// "PASS" on success and a "FAIL" line otherwise, with the measured rejection in dB.
//
// Run from the repository root, as tools/check.sh does: iverilog -g2012 -o tb.vvp
// sim/rx/tb_alias.v && vvp tb.vvp

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

module tb_alias;

    // 76.8 MHz is the ADC sample rate, and the interferer sits at the worst alias frequency
    // described in the header.
    localparam real PI = 3.14159265358979323846;
    localparam real FS = 76_800_000.0;
    localparam real INTERFERER_HZ = 7_587_840.0;  // cic_fixed worst case @ 384 ksps (see header)
    localparam real ADC_FULL_SCALE = 2040.0;      // a hair under full scale, no clipping

    // The gain of the whole chain, as in sim/check_alias.py (see the comment at its G_REAL for
    // the derivation): a 0 dBFS on-tune real cosine gives a steady |I + jQ| of ADC_FULL_SCALE x G_REAL.
    localparam real G_REAL = 4.9062;
    localparam real REFERENCE_MAG = ADC_FULL_SCALE * G_REAL;

    // The FIR's accumulator has 19 fraction bits (see the SHIFT and the output rounding in
    // fir_decim.v), so dividing by 2^19 puts a raw reading on the scale of out_i and out_q.
    localparam real HI_SCALE = 524288.0; // 2^19

    localparam real TARGET_REJECTION_DB = 90.0;

    // The time scale is arbitrary (2 ns per period), the samples are generated from their index.
    reg clock = 1'b0;
    always #1 clock = ~clock;

    reg rst = 1'b1;
    reg [11:0] adc_data = 12'sd0;
    reg        adc_valid = 1'b0;
    reg        reg_wr = 1'b0;
    reg [1:0]  reg_addr = 2'd0;
    reg [31:0] reg_wdata = 32'd0;
    wire       out_valid;
    wire [1:0] out_index;
    wire signed [23:0] out_i, out_q;

    // One receiver. The FIR delay line and the shared variable CIC engine are resources of the
    // bank (docs/ARCHITECTURE.md 3.14), so even a single receiver test instantiates rx_bank
    // with N = 1 and drives it through the register write port.
    rx_bank #(
        .N(1), .ADC_WIDTH(12), .FIR_COEFF_FILE("rtl/rx/fir_coeffs.hex")
    ) dut (
        .clock(clock), .rst(rst),
        .adc_data(adc_data), .adc_valid(adc_valid),
        .reg_wr(reg_wr), .reg_addr(reg_addr), .reg_wdata(reg_wdata),
        .out_valid(out_valid), .out_index(out_index), .out_i(out_i), .out_q(out_q)
    );

    task write_reg(input [1:0] addr, input [31:0] data);
        begin
            @(posedge clock);
            reg_wr <= 1'b1; reg_addr <= addr; reg_wdata <= data;
            @(posedge clock);
            reg_wr <= 1'b0;
        end
    endtask

    // High precision probe: the FIR's own accumulator before rounding. The FIR is instantiated
    // in rx_bank.v's `firs` generate block, not inside rx_channel.v (see its header).
    wire signed [43:0] hi_i = dut.firs[0].u_fir.hi_i;
    wire signed [43:0] hi_q = dut.firs[0].u_fir.hi_q;

    integer k;
    real w;
    real last_hi_i, last_hi_q, measured_mag, rejection_db;
    integer errors;

    // Tune to baseband and enable the receiver at 384 ksps, then feed the cosine.
    initial begin
        errors = 0;
        w = 2.0 * PI * INTERFERER_HZ / FS;

        repeat (5) @(posedge clock);
        rst = 1'b0;
        @(posedge clock);
        write_reg(2'b00, 32'sd0);              // phase_inc = 0 (baseband)
        write_reg(2'b01, {29'd0, 1'b1, 2'd3}); // enable=1, rate_sel=3 (384 ksps)

        // 40 output samples of settling at 384 ksps (decimation 76.8 MHz / 384 kHz = 200), which is
        // 8,000 ADC clocks. The last accumulator reading before the end is kept.
        for (k = 0; k < 8000; k = k + 1) begin
            @(posedge clock);
            adc_data  <= $rtoi(ADC_FULL_SCALE * $cos(w * k));
            adc_valid <= 1'b1;
            if (out_valid) begin
                last_hi_i = $itor(hi_i) / HI_SCALE;
                last_hi_q = $itor(hi_q) / HI_SCALE;
            end
        end
        // Stop feeding and let the last outputs come out, then convert the residual to a rejection.
        @(posedge clock); adc_valid <= 1'b0;
        repeat (200) @(posedge clock);

        measured_mag = $sqrt(last_hi_i*last_hi_i + last_hi_q*last_hi_q);
        rejection_db = 20.0 * $log10(REFERENCE_MAG / measured_mag);

        $display("interferer = %.4f MHz, 0 dBFS; measured residual mag = %.6f; rejection = %.1f dB (target %.0f dB)",
                  INTERFERER_HZ/1.0e6, measured_mag, rejection_db, TARGET_REJECTION_DB);

        if (rejection_db < TARGET_REJECTION_DB) begin
            $display("FAIL: rejection %.1f dB below %.0f dB target", rejection_db, TARGET_REJECTION_DB);
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS");
        else $display("FAIL: %0d error(s)", errors);
        $finish;
    end

endmodule
