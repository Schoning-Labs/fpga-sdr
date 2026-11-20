// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Alias-rejection measurement of the whole zoom DDC, rtl/zoom/zoom_ddc.v, at every span. An alias is a signal
// from outside the displayed band that lands inside it when the sample rate is cut, because decimation folds
// everything above half the new rate back down onto the band. The filters in front of each rate change have
// to remove such signals first, and the requirement for the zoom is at least 80 dB of rejection for the
// displayed bins at every span (docs/F3_ZOOM.md section 3). The method is that of sim/rx/tb_alias.v, applied
// to the zoom DDC instead of a receiver channel. No window or FFT is in the path, because they only
// display alias content and neither add nor remove any, so the measurement is taken at the I and Q output
// of the DDC. docs/learn/GLOSSARY.md has the terms.
//
// There are eleven spans. Index 0 to 6 are the wide spans, 3.072 MHz down to 48 kHz (span_shift equal to the
// index), and 7 to 10 are the narrow spans, 24, 12, 6 and 3 kHz, which use span_shift 6 with narrow_shift 1 to 4
// and rtl/zoom/zoom_cic_narrow.v at gain 0 (docs/ZOOM_IN_CHIP.md section 12).
//
// Stimulus and measurement, in this order:
//   1. Calibration: a real 5 kHz tone of 2,040 amplitude (just under the 12-bit full scale of 2,047) with the
//      DDC tuned to exactly 5 kHz, at span_shift 0, which settles fastest. The tone is inside the Nyquist
//      band of every span, including the narrowest. The largest |I + jQ| after the start-up transient is the
//      reference. Every CIC stage in the chain takes the same slice of its output so that the DC gain is the
//      same at every decimation (as in rtl/rx/rx_channel.v, which sim/rx/tb_rx_bank.v checks with its "gain
//      matches across rates" test), so this one reference holds for every span, and the bench is also a
//      check of that property for the zoom chain.
//   2. For each span: tune to baseband (phase_inc = 0) and feed a real tone of the same amplitude at the worst
//      alias frequency that tools/analyze_zoom_alias.py worked out for the span (the worse of the two
//      decimating stages), which it writes to sim/zoom/zoom_alias_config.vh, a generated file that this
//      bench includes. Whatever lands near DC at the output is the alias, and the rejection is
//      20 x log10(reference / residual).
//
// Two figures are taken for each span: the largest output word over the measured points (the measure of spans 0
// to 6) and the line at the frequency that the interferer lands on, found by correlating the output with
// that frequency over the measured points (the measure of the narrow spans). For the narrow spans the
// largest word is 2 steps of the 16-bit output, which is 78 dB under the reference whatever the interferer
// does, because of the rounding noise of the 16-bit words between the stages
// (sim/zoom/zoom_narrow_chain_sim.v shows the same without the stages in front), and the line is not limited by that.
//
// What counts as a pass: every span must reject by at least 80 dB, otherwise the bench prints "FAIL: span n ..."
// for it, and at the end it prints the worst figure and PASS or FAIL. The predicted figure from the analysis
// script is printed for comparison and is not checked.
//
// Run, from the repository root, as step 1 of sim/zoom/run_sim.sh (which makes the configuration file first, and
// takes about five to six minutes for the seven wide spans, with the narrow spans on top of that):
//   python tools/analyze_zoom_alias.py
//   iverilog -g2012 -o sim/zoom/out/zoom_alias.vvp sim/zoom/zoom_alias_sim.v && vvp sim/zoom/out/zoom_alias.vvp
// Adding -DZOOM_ALIAS_FIRST=<n> -DZOOM_ALIAS_LAST=<n> to the iverilog line runs only the spans n to m, so
// that spans can be run as several simulations side by side (each one calibrates for itself).

`timescale 1ns / 1ps

// Settling time: a point of the 3 kHz span is 20,480 ADC clocks (total decimation 1,280 x 16), so the narrow
// spans settle over NARROW_POINTS = 160 output points (the first NARROW_SKIP = 100 skipped and the peak taken
// over the next 60) instead of the 800 of the wide spans. The filters behind the last CIC are 63 and 15 taps long.

`include "rtl/rx/nco_mixer.v"
`include "rtl/rx/cic_integrator.v"
`include "rtl/rx/cic_comb.v"
`include "rtl/rx/cic_fixed.v"
`include "rtl/rx/cic_var_shared.v"
`include "rtl/rx/fir_delay_ram2.v"
`include "rtl/rx/fir_decim.v"
`include "rtl/rx/rx_channel.v"
`include "rtl/zoom/cic_var_pow2.v"
`include "rtl/fft/fft_mul.v"
`include "rtl/zoom/zoom_fir_half.v"
`include "rtl/zoom/zoom_cic_comp.v"
`include "rtl/zoom/zoom_ddc.v"
`include "sim/zoom/zoom_alias_config.vh"

module zoom_alias_sim;

    // The ADC rate, and the amplitude of every tone (just under the full scale of 2,047, so that nothing clips).
    localparam real PI = 3.14159265358979323846;
    localparam real FS = 76_800_000.0;
    localparam real ADC_FULL_SCALE = 2040.0; // a hair under full scale (2047), no clipping
    localparam real F_CAL_HZ = 5_000.0;      // calibration tone: inside every span's Nyquist
    localparam integer SETTLE_POINTS = 800;   // decimated output points per wide span (the CIC order and the filters' group delay make the chain slow to settle; worst case 800 x 1,280 = 1,024,000 ADC clocks)
    localparam integer NARROW_POINTS = 160;   // the same for span index 7 to 10
    localparam integer NARROW_SKIP   = 100;
// Default span range: all of them, unless the command line gives -DZOOM_ALIAS_FIRST and -DZOOM_ALIAS_LAST.
`ifndef ZOOM_ALIAS_FIRST
`define ZOOM_ALIAS_FIRST 0
`endif
`ifndef ZOOM_ALIAS_LAST
`define ZOOM_ALIAS_LAST (ZOOM_ALIAS_N_SPANS - 1)
`endif
    localparam integer CAL_SETTLE_ADC_CLOCKS = 150_000; // generous fixed window for the single calibration pass (span_shift=0, decimation 20)

    // Arbitrary 2 ns clock, the ADC gets one sample per clock here.
    reg clock = 1'b0;
    always #1 clock = ~clock;

    reg rst = 1'b1;
    reg [11:0] adc_data = 12'sd0;
    reg        adc_valid = 1'b0;
    reg        enable = 1'b0;
    reg signed [31:0] phase_inc = 32'sd0;
    reg [2:0]  span_shift = 3'd0;
    reg [2:0]  narrow_shift = 3'd0;

    wire out_valid;
    wire signed [15:0] out_i, out_q;

    zoom_ddc dut (
        .clock(clock), .rst(rst),
        .adc_data(adc_data), .adc_valid(adc_valid),
        .phase_inc(phase_inc), .span_shift(span_shift), .narrow_shift(narrow_shift), .narrow_gain(2'd0),
        .enable(enable),
        .out_valid(out_valid), .out_i(out_i), .out_q(out_q)
    );

    // The measurement is taken on the output that every real consumer sees (out_i and out_q, the 16-bit rounded
    // words that zoom_window.v takes), and not on an internal wide accumulator. That costs a measurement floor of
    // about 1 step against a reference of 27,000 or so, roughly 85 to 90 dB, which is enough to tell "meets
    // the 80 dB target" from "does not", and a residual that rounds to exactly 0 is reported as "at or beyond
    // the floor" and is not an exact figure.
    real last_i, last_q;
    real peak_mag;
    reg  capture_peak;
    real w_land = 0.0, cr_p = 0.0, ci_p = 0.0, cr_n = 0.0, ci_n = 0.0, line_mag = 0.0;
    integer n_cap = 0;
    // At every output word: remember it, and while capture_peak is set, track the peak |I + jQ| and also
    // correlate the output with the frequency the interferer lands on, for both signs of that frequency (the
    // _p sums for +w, the _n sums for -w, over I and Q).
    always @(posedge clock) if (out_valid) begin
        last_i = $itor($signed(out_i));
        last_q = $itor($signed(out_q));
        if (capture_peak) begin
            n_cap = n_cap + 1;
            cr_p = cr_p + last_i * $cos(w_land * n_cap) + last_q * $sin(w_land * n_cap);
            ci_p = ci_p + last_q * $cos(w_land * n_cap) - last_i * $sin(w_land * n_cap);
            cr_n = cr_n + last_i * $cos(w_land * n_cap) - last_q * $sin(w_land * n_cap);
            ci_n = ci_n + last_q * $cos(w_land * n_cap) + last_i * $sin(w_land * n_cap);
            if ($sqrt(last_i*last_i + last_q*last_q) > peak_mag)
                peak_mag = $sqrt(last_i*last_i + last_q*last_q);
        end
    end

    // A real ADC tone with the DDC tuned to baseband (phase_inc = 0, as in every interferer case below) is a
    // two-sided signal: a real cosine is 0.5 x (e^(+jwn) + e^(-jwn)), and the two mirror-image complex
    // components fold onto the same offset through this real-coefficient chain, landing on top of each other
    // in the complex output with a relative phase that depends on the settle time. Any real interferer does
    // this to a real ADC, so it is measured as it is: the PEAK |I + jQ| over a settled window is tracked
    // and not a single snapshot, which is also the more meaningful figure for how far down an operator could
    // still see a ghost.

    integer k;
    // The start-up transient of zoom_fir_half.v and zoom_cic_comp.v (their delay lines filling with a partial
    // window) can spike far above the settled residual before it decays, and its duration is a fixed number
    // of DECIMATED samples, which is a different number of ADC clocks at every span: at span_shift 0 it
    // is gone within about 900 ADC clocks, and at span_shift 6 (total decimation 1,280) it peaks around ADC clock
    // 42,000 and dies away around 56,000. TRANSIENT_SKIP_SAMPLES is therefore counted in decimated samples
    // and the caller multiplies it by the span's own total decimation to get the ADC clocks to skip.
    localparam integer TRANSIENT_SKIP_SAMPLES = 150;

    // Runs `adc_clocks` clocks of a real tone at `tone_hz` with the DDC tuned to `tune_hz` (phase_inc worked out
    // from it), on span index `sshift` (0 to 6 is span_shift, 7 and above is span_shift 6 plus a narrow_shift
    // of sshift - 6), and returns the peak |I + jQ| seen after the first `skip_clocks` clocks (or after half
    // the run if that is shorter, so that short runs still capture something). The correlation sums for the
    // line figure are in line_mag.
    task run_case(
        input real tone_hz, input real tune_hz, input [3:0] sshift,
        input integer adc_clocks, input integer skip_clocks, output real mag
    );
        real w;
        integer skip;
        begin
            // Reset and set up the DDC for this case (a span change always happens in reset), then enable it.
            rst = 1'b1; enable = 1'b0; adc_valid = 1'b0;
            peak_mag = 0.0; capture_peak = 1'b0;
            n_cap = 0; cr_p = 0.0; ci_p = 0.0; cr_n = 0.0; ci_n = 0.0;
            repeat (5) @(posedge clock);
            span_shift   = (sshift > 4'd6) ? 3'd6 : sshift[2:0];
            narrow_shift = (sshift > 4'd6) ? (sshift - 4'd6) : 3'd0;
            phase_inc = $rtoi((tune_hz / FS) * 4294967296.0);
            rst = 1'b0;
            @(posedge clock);
            enable = 1'b1;
            // One ADC sample per clock, a cosine at the tone frequency; the peak capture starts after the skip.
            w = 2.0 * PI * tone_hz / FS;
            skip = (skip_clocks < adc_clocks/2) ? skip_clocks : adc_clocks/2;
            for (k = 0; k < adc_clocks; k = k + 1) begin
                @(posedge clock);
                adc_data  <= $rtoi(ADC_FULL_SCALE * $cos(w * k));
                adc_valid <= 1'b1;
                if (k == skip) capture_peak = 1'b1;
            end
            // Let the pipeline drain, then take the figures: the peak, and the larger of the two line magnitudes.
            @(posedge clock); adc_valid <= 1'b0;
            repeat (50) @(posedge clock);
            mag = peak_mag;
            line_mag = (n_cap == 0) ? 0.0 : $sqrt(cr_p * cr_p + ci_p * ci_p) / n_cap;
            if (n_cap != 0 && $sqrt(cr_n * cr_n + ci_n * ci_n) / n_cap > line_mag)
                line_mag = $sqrt(cr_n * cr_n + ci_n * ci_n) / n_cap;
        end
    endtask

    // Per-span data from the generated configuration file: the worst-case interferer frequency, the predicted
    // rejection, the total decimation of the chain and the displayed span.
    real reference_mag;
    real interferer_hz [0:ZOOM_ALIAS_N_SPANS-1];
    real predicted_db  [0:ZOOM_ALIAS_N_SPANS-1];
    integer total_decim [0:ZOOM_ALIAS_N_SPANS-1];
    real span_hz_arr    [0:ZOOM_ALIAS_N_SPANS-1];
    real measured_mag, measured_db;
    reg  floor_hit;
    integer s, errors, worst_within_tol;
    real min_measured_db;

    initial begin
        interferer_hz[0] = ZOOM_ALIAS_INTERFERER_0_HZ; predicted_db[0] = ZOOM_ALIAS_PREDICTED_0_DB;
        total_decim[0] = ZOOM_ALIAS_TOTAL_DECIM_0;      span_hz_arr[0] = ZOOM_ALIAS_SPAN_0_HZ;
        interferer_hz[1] = ZOOM_ALIAS_INTERFERER_1_HZ; predicted_db[1] = ZOOM_ALIAS_PREDICTED_1_DB;
        total_decim[1] = ZOOM_ALIAS_TOTAL_DECIM_1;      span_hz_arr[1] = ZOOM_ALIAS_SPAN_1_HZ;
        interferer_hz[2] = ZOOM_ALIAS_INTERFERER_2_HZ; predicted_db[2] = ZOOM_ALIAS_PREDICTED_2_DB;
        total_decim[2] = ZOOM_ALIAS_TOTAL_DECIM_2;      span_hz_arr[2] = ZOOM_ALIAS_SPAN_2_HZ;
        interferer_hz[3] = ZOOM_ALIAS_INTERFERER_3_HZ; predicted_db[3] = ZOOM_ALIAS_PREDICTED_3_DB;
        total_decim[3] = ZOOM_ALIAS_TOTAL_DECIM_3;      span_hz_arr[3] = ZOOM_ALIAS_SPAN_3_HZ;
        interferer_hz[4] = ZOOM_ALIAS_INTERFERER_4_HZ; predicted_db[4] = ZOOM_ALIAS_PREDICTED_4_DB;
        total_decim[4] = ZOOM_ALIAS_TOTAL_DECIM_4;      span_hz_arr[4] = ZOOM_ALIAS_SPAN_4_HZ;
        interferer_hz[5] = ZOOM_ALIAS_INTERFERER_5_HZ; predicted_db[5] = ZOOM_ALIAS_PREDICTED_5_DB;
        total_decim[5] = ZOOM_ALIAS_TOTAL_DECIM_5;      span_hz_arr[5] = ZOOM_ALIAS_SPAN_5_HZ;
        interferer_hz[6] = ZOOM_ALIAS_INTERFERER_6_HZ; predicted_db[6] = ZOOM_ALIAS_PREDICTED_6_DB;
        total_decim[6] = ZOOM_ALIAS_TOTAL_DECIM_6;      span_hz_arr[6] = ZOOM_ALIAS_SPAN_6_HZ;
        interferer_hz[7] = ZOOM_ALIAS_INTERFERER_7_HZ; predicted_db[7] = ZOOM_ALIAS_PREDICTED_7_DB;
        total_decim[7] = ZOOM_ALIAS_TOTAL_DECIM_7;      span_hz_arr[7] = ZOOM_ALIAS_SPAN_7_HZ;
        interferer_hz[8] = ZOOM_ALIAS_INTERFERER_8_HZ; predicted_db[8] = ZOOM_ALIAS_PREDICTED_8_DB;
        total_decim[8] = ZOOM_ALIAS_TOTAL_DECIM_8;      span_hz_arr[8] = ZOOM_ALIAS_SPAN_8_HZ;
        interferer_hz[9] = ZOOM_ALIAS_INTERFERER_9_HZ; predicted_db[9] = ZOOM_ALIAS_PREDICTED_9_DB;
        total_decim[9] = ZOOM_ALIAS_TOTAL_DECIM_9;      span_hz_arr[9] = ZOOM_ALIAS_SPAN_9_HZ;
        interferer_hz[10] = ZOOM_ALIAS_INTERFERER_10_HZ; predicted_db[10] = ZOOM_ALIAS_PREDICTED_10_DB;
        total_decim[10] = ZOOM_ALIAS_TOTAL_DECIM_10;     span_hz_arr[10] = ZOOM_ALIAS_SPAN_10_HZ;

        // Calibration, then one case per span.
        errors = 0;
        min_measured_db = 1.0e9;

        run_case(F_CAL_HZ, F_CAL_HZ, 4'd0, CAL_SETTLE_ADC_CLOCKS, TRANSIENT_SKIP_SAMPLES * 20, reference_mag);
        $display("calibration: on-tune %.0f Hz tone, span_shift=0 -> reference |I+jQ| = %.2f", F_CAL_HZ, reference_mag);

        $display("%6s  %12s  %14s  %12s  %12s", "span", "interferer", "measured dB", "predicted dB", "settle(ADC clk)");
        for (s = `ZOOM_ALIAS_FIRST; s <= `ZOOM_ALIAS_LAST; s = s + 1) begin
            // The window is SETTLE_POINTS (or NARROW_POINTS) decimated samples and the skip is
            // TRANSIENT_SKIP_SAMPLES (or NARROW_SKIP), both scaled by this span's own total decimation, so that
            // the skip clears the start-up transient at every span. w_land is the frequency that the interferer
            // lands on, in radians per output point: the interferer in cycles per output sample, folded to
            // within plus or minus half a cycle.
            w_land = 2.0 * PI * (interferer_hz[s] * total_decim[s] / FS - $floor(interferer_hz[s] * total_decim[s] / FS + 0.5));
            run_case(interferer_hz[s], 0.0, s[3:0],
                     ((s > 6) ? NARROW_POINTS : SETTLE_POINTS) * total_decim[s],
                     ((s > 6) ? NARROW_SKIP : TRANSIENT_SKIP_SAMPLES) * total_decim[s],
                     measured_mag);
            // A residual that rounds to exactly 0 counts as "at or beyond the measurement floor" and is
            // reported as the floor, 0.5 counts (half a step), so the number is a conservative bound and
            // not infinite.
            floor_hit = (measured_mag < 0.5);
            measured_db = 20.0 * $log10(reference_mag / (floor_hit ? 0.5 : measured_mag));
            $display("      span %0d: largest word %.2f steps (%.1f dB), line %.3f steps (%.1f dB)", s, measured_mag, measured_db,
                     line_mag, 20.0 * $log10(reference_mag / ((line_mag < 0.01) ? 0.01 : line_mag)));
            // The narrow spans are judged by the line figure and the wide ones by the largest word.
            if (s > 6) measured_db = 20.0 * $log10(reference_mag / ((line_mag < 0.01) ? 0.01 : line_mag));
            if (measured_db < min_measured_db) min_measured_db = measured_db;
            $display("%5.2fk  %9.3f k  %11.1f dB%s  %11.1f dB  %14d",
                      span_hz_arr[s]/1000.0, interferer_hz[s]/1000.0, measured_db,
                      floor_hit ? " (floor)" : "        ", predicted_db[s],
                      ((s > 6) ? NARROW_POINTS : SETTLE_POINTS) * total_decim[s]);

            // The requirement (docs/F3_ZOOM.md section 3) is at least 80 dB measured at every span. The
            // predicted figure (a single-tone analytical number, printed above) is not checked against the
            // measurement, because at the margins this design has, the measurement floor of the output is reached
            // long before the prediction would matter.
            if (measured_db < 80.0) begin
                $display("FAIL: span %0d measured rejection %.1f dB is below the 80 dB target", s, measured_db);
                errors = errors + 1;
            end
        end

        $display("worst measured rejection across all spans: %.1f dB", min_measured_db);

        if (errors == 0) $display("PASS");
        else $display("FAIL: %0d error(s)", errors);
        $finish;
    end

endmodule
