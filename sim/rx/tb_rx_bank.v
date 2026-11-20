// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Quick, self-contained smoke test of the receiver bank rtl/rx/rx_bank.v with two receivers, run
// by tools/check.sh (a few seconds). Each receiver multiplies the ADC stream by a numerically
// controlled oscillator to move its tuned frequency to zero, decimates with a CIC filter and
// then a compensating FIR (docs/learn/GLOSSARY.md), and delivers its output samples at 48, 96,
// 192 or 384 ksps. The test tone is made inside the bench with $cos, and the FIR coefficients are
// the checked-in file rtl/rx/fir_coeffs.hex that tools/gen_fir_coeffs.py writes, so no
// generated inputs or Python are needed. The full tests, with many receivers and frequencies and
// FFT based measurement, are sim/rx/rx_bank_functional_sim.v and sim/rx/rx_alias_sim.v, started
// by sim/run_sim.sh (about 4 minutes in all, the results are in docs/RX_DSP.md section 6).
//
// Stimulus: a real 1.84 MHz cosine of amplitude 1,800 (12 bit ADC codes, under full scale
// 2,047) at 76.8 MHz, one sample per clock. Receiver 0 runs at 384 ksps and receiver 1 at
// 48 ksps (the slower one dominates the run time), and both are tuned exactly onto the tone.
//
// Pass criterion, two checks that are both required:
// 1. Both receivers must settle to the same output magnitude, within 8 % of the expected one,
//    although they run at different rates. This is the property that the variable CIC's
//    bit selection keeps the DC gain the same at every decimation setting (docs/RX_DSP.md
//    section 2), and it is worth a check of its own.
// 2. Disabling and re-enabling a receiver while the stream is running must not corrupt its
//    output. It must produce outputs again and settle back to the same magnitude, and it must
//    not get stuck. A receiver that is disabled has no input strobe left to clear its output
//    strobe, so a latch that stays high after the disable has to be avoided.
// The bench prints "PASS" on success and "FAIL" lines otherwise, with the measured magnitudes.
//
// Run from the repository root, as tools/check.sh does: iverilog -g2012 -o tb.vvp
// sim/rx/tb_rx_bank.v && vvp tb.vvp

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

module tb_rx_bank;

    // The sample rate of the ADC is 76.8 MHz. The tone at 1.84 MHz is well inside every rate's
    // passband, and 1,800 is comfortably under full scale.
    localparam real PI = 3.14159265358979323846;
    localparam real FS = 76_800_000.0;
    localparam real FREQ_HZ = 1_840_000.0;   // test tone, well inside every rate's passband
    localparam real AMP = 1800.0;            // ADC code peak, comfortably under full scale (2047)

    // Gain from the ADC's peak amplitude to the steady |I + jQ| of a real, on-tune cosine, measured
    // once on the whole chain (10,043 / 2,047, see the comment at G_REAL in sim/check_alias.py).
    // It is the same at every output rate, which check 1 below tests again.
    localparam real G_REAL = 4.9062;
    localparam real EXPECTED_MAG = AMP * G_REAL;
    // Allowed deviation of the magnitude from the expected one, 8 %.
    localparam real TOL_FRAC = 0.08;         // 8% magnitude tolerance

    // The time scale is arbitrary (2 ns per period), the samples are generated from their index.
    reg clock = 1'b0;
    always #1 clock = ~clock;

    reg rst = 1'b1;
    reg [11:0] adc_data = 12'sd0;
    reg        adc_valid = 1'b0;

    // Register write port: {receiver[0], register}, register 0 the phase increment and 1 the control.
    reg        reg_wr = 1'b0;
    reg [1:0]  reg_addr = 2'd0;   // N=2: {channel[0], regtype}
    reg [31:0] reg_wdata = 32'd0;

    wire        out_valid;
    wire        out_index;
    wire signed [23:0] out_i, out_q;

    // Two receivers.
    rx_bank #(
        .N(2), .ADC_WIDTH(12), .FIR_COEFF_FILE("rtl/rx/fir_coeffs.hex")
    ) dut (
        .clock(clock), .rst(rst),
        .adc_data(adc_data), .adc_valid(adc_valid),
        .reg_wr(reg_wr), .reg_addr(reg_addr), .reg_wdata(reg_wdata),
        .out_valid(out_valid), .out_index(out_index), .out_i(out_i), .out_q(out_q)
    );

    // One register write: address, data and write strobe held for one clock.
    task write_reg(input [1:0] addr, input [31:0] data);
        begin
            @(posedge clock);
            reg_wr <= 1'b1; reg_addr <= addr; reg_wdata <= data;
            @(posedge clock);
            reg_wr <= 1'b0;
        end
    endtask

    // Receiver 0 runs at 384 ksps (rate_sel = 3, settles quickly), receiver 1 at 48 ksps
    // (rate_sel = 0, settles slowly, so it sets the run time: about 20 output samples times a
    // decimation of 1,600 is 32,000 ADC clocks). Both are tuned to the tone, with the phase
    // increment frequency / 76.8 MHz x 2^32, and rx0_enable switches receiver 0 on or off.
    task configure(input rx0_enable);
        begin
            write_reg(2'b00, $rtoi((FREQ_HZ / FS) * 4294967296.0)); // rx0 phase_inc
            write_reg(2'b01, {29'd0, rx0_enable, 2'd3});            // rx0 control
            write_reg(2'b10, $rtoi((FREQ_HZ / FS) * 4294967296.0)); // rx1 phase_inc
            write_reg(2'b11, {29'd0, 1'b1, 2'd0});                  // rx1 control
        end
    endtask

    // k indexes the ADC samples, w is the tone's phase step per sample.
    integer k;
    real w;
    reg signed [23:0] last_i0, last_q0, last_i1, last_q1;
    integer rx0_count;
    reg     count_rx0;

    // Keeps the latest output of each receiver (index 0 or 1), and counts those of receiver 0
    // after count_rx0 is set.
    always @(posedge clock) if (out_valid) begin
        if (out_index == 1'b0) begin
            last_i0 <= out_i; last_q0 <= out_q;
            if (count_rx0) rx0_count <= rx0_count + 1;
        end else begin
            last_i1 <= out_i; last_q1 <= out_q;
        end
    end

    // Magnitude of an I/Q pair, and a test that it lies within TOL_FRAC of the expected value.
    function real mag_of(input real i, input real q);
        mag_of = $sqrt(i*i + q*q);
    endfunction

    function integer within_tol(input real measured);
        real lo, hi;
        begin
            lo = EXPECTED_MAG * (1.0 - TOL_FRAC);
            hi = EXPECTED_MAG * (1.0 + TOL_FRAC);
            within_tol = (measured >= lo) && (measured <= hi);
        end
    endfunction

    // Error count and the measured magnitudes of the two receivers.
    integer errors;
    real mag0, mag1;

    // Reset, configure both receivers and feed the tone.
    initial begin
        errors = 0;
        rx0_count = 0;
        count_rx0 = 1'b0;
        w = 2.0 * PI * FREQ_HZ / FS;

        repeat (5) @(posedge clock);
        rst = 1'b0;
        @(posedge clock);
        configure(1'b1); // both receivers enabled

        // Feed the tone for 40,000 clocks, which is long enough for receiver 1 (48 ksps) to settle.
        for (k = 0; k < 40000; k = k + 1) begin
            @(posedge clock);
            adc_data  <= $rtoi(AMP * $cos(w * k));
            adc_valid <= 1'b1;
        end
        repeat (500) @(posedge clock);

        // ---- check 1: the gain must match across rates ----------------------------------
        mag0 = mag_of($itor(last_i0), $itor(last_q0));
        mag1 = mag_of($itor(last_i1), $itor(last_q1));
        $display("rx0 (384 ksps) magnitude = %.1f (expected ~%.1f)", mag0, EXPECTED_MAG);
        $display("rx1 (48  ksps) magnitude = %.1f (expected ~%.1f)", mag1, EXPECTED_MAG);

        if (!within_tol(mag0)) begin
            $display("FAIL: rx0 magnitude %.1f outside +/-%.0f%% of expected %.1f",
                      mag0, TOL_FRAC*100.0, EXPECTED_MAG);
            errors = errors + 1;
        end
        if (!within_tol(mag1)) begin
            $display("FAIL: rx1 magnitude %.1f outside +/-%.0f%% of expected %.1f",
                      mag1, TOL_FRAC*100.0, EXPECTED_MAG);
            errors = errors + 1;
        end

        // ---- check 2: disable and re-enable receiver 0, which must not leave it stuck ------
        configure(1'b0); // disable rx0, rx1 stays enabled and keeps running
        for (k = 40000; k < 44000; k = k + 1) begin
            @(posedge clock);
            adc_data  <= $rtoi(AMP * $cos(w * k));
            adc_valid <= 1'b1;
        end

        // From here on count receiver 0's outputs, then re-enable it and feed the tone again.
        count_rx0 = 1'b1; // start counting rx0 output pulses from here
        configure(1'b1);  // re-enable rx0
        for (k = 44000; k < 52000; k = k + 1) begin
            @(posedge clock);
            adc_data  <= $rtoi(AMP * $cos(w * k));
            adc_valid <= 1'b1;
        end
        repeat (500) @(posedge clock);

        $display("rx0 output pulses after re-enable = %0d", rx0_count);
        if (rx0_count == 0) begin
            $display("FAIL: rx0 produced no output at all after re-enable");
            errors = errors + 1;
        end

        mag0 = mag_of($itor(last_i0), $itor(last_q0));
        $display("rx0 magnitude after disable/re-enable = %.1f (expected ~%.1f)", mag0, EXPECTED_MAG);
        if (!within_tol(mag0)) begin
            $display("FAIL: rx0 did not recover cleanly after disable/re-enable (magnitude %.1f, expected ~%.1f) -- possible stuck-strobe regression",
                      mag0, EXPECTED_MAG);
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS");
        else $display("FAIL: %0d error(s)", errors);
        $finish;
    end

endmodule
