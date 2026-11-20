// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Word-for-word comparison of the zoom spectrum as built for the chip, rtl/zoom/zoom_spectrum.v, against the
// plain parallel version of the same chain that is kept in sim/zoom/ref/ (zoom_fir_half_parallel_ref.v,
// zoom_cic_comp_parallel_ref.v, cic_var_pow2_ref.v, zoom_ddc_ref.v and zoom_spectrum_ref.v, which carry a _ref
// suffix so that both versions can sit side by side in one simulation). The chip version shares one set of
// multipliers across the taps of its filters (two multipliers per channel in zoom_fir_half.v, one in
// zoom_cic_comp.v) and does its sums serially, the reference forms every product at once, and the two are written
// separately, so equal output words show that the serial schedules, the circular buffers and the
// reordering of the adds change nothing in the result. docs/learn/GLOSSARY.md explains the terms.
//
// Stimulus: the setup of tb_zoom_quick.v, the widest span (span_shift = 0) and a real ADC tone 45 kHz (48 bins)
// above a zoom center of 10 MHz, at amplitude 1,800. The ADC samples come at a steady 50 % duty, one idle clock after
// every sample, and not on every clock. The serial engines of the chip version need idle clocks between their
// input samples to keep up, and the real ADC delivers 76.8 Msps to a 120 MHz clock, which is at most 64 % of the
// clocks, so a stimulus on every clock is not a condition the design has to sustain. The values and their order
// do not depend on the pacing, so the comparison is fair. The bursts of the real HL2 frames, which average
// about the same duty but arrive in runs, are covered by sim/zoom/zoom_rb1_burst_sim.v.
//
// Both versions get the same input signals. Each one captures its own first complete 4,096-word FFT frame (from
// one out_first to the next, because the latencies of the two differ), and the two captured frames are then
// compared index by index: bin number, real part and imaginary part must be identical.
//
// What counts as a pass: both frames were captured, and there is no mismatch in the 4,096 words. The bench
// prints the first twenty mismatches, the total, and PASS or FAIL.
//
// Run from the repository root (2 to 3 minutes). It is not run by tools/check.sh, because that takes too long for its
// budget (the same as sim/zoom/zoom_alias_sim.v and zoom_bin48_sim.v), and it is step 3 of sim/zoom/run_sim.sh:
//   iverilog -g2012 -o build/zoom_rb1_compare.vvp sim/zoom/zoom_rb1_compare_sim.v && vvp build/zoom_rb1_compare.vvp

`timescale 1ns / 1ps

// The chip version: the receiver's mixer and CIC blocks, the zoom DDC and its filters, the window and the FFT.
`include "rtl/rx/nco_mixer.v"
`include "rtl/rx/cic_integrator.v"
`include "rtl/rx/cic_comb.v"
`include "rtl/rx/cic_fixed.v"
`include "rtl/rx/cic_var_shared.v"
`include "rtl/rx/fir_delay_ram2.v"
`include "rtl/rx/fir_decim.v"
`include "rtl/rx/rx_channel.v"
`include "rtl/zoom/cic_var_pow2.v"
`include "rtl/zoom/zoom_fir_half.v"
`include "rtl/zoom/zoom_cic_comp.v"
`include "rtl/zoom/zoom_ddc.v"
`include "rtl/zoom/zoom_window.v"
`include "rtl/fft/fft_delay.v"
`include "rtl/fft/fft_bf.v"
`include "rtl/fft/fft_mul.v"
`include "rtl/fft/fft_twmul.v"
`include "rtl/fft/fft_r22sdf.v"
`include "rtl/zoom/zoom_spectrum.v"

// The reference version.
`include "sim/zoom/ref/zoom_fir_half_parallel_ref.v"
`include "sim/zoom/ref/zoom_cic_comp_parallel_ref.v"
`include "sim/zoom/ref/cic_var_pow2_ref.v"
`include "sim/zoom/ref/zoom_ddc_ref.v"
`include "sim/zoom/ref/zoom_spectrum_ref.v"

module zoom_rb1_compare_sim;
    // Same tone and span as tb_zoom_quick.v: full internal rate 76.8 MHz / 10 / 1 / 2 = 3.84 MHz, bin
    // spacing 3.84 MHz / 4,096 = 937.5 Hz, and the tone 48 bins above the center.
    localparam real PI = 3.14159265358979323846;
    localparam real FS = 76_800_000.0;
    localparam real ZOOM_CENTRE_HZ = 10_000_000.0;
    localparam real FULL_RATE_HZ = 76_800_000.0 / 10.0 / 1.0 / 2.0;
    localparam integer LOG_N  = 12;
    localparam integer N      = 1 << LOG_N;
    localparam real    BIN_HZ = FULL_RATE_HZ / N;
    localparam integer EXPECT_BIN = 48;
    localparam real OFFSET_HZ = BIN_HZ * EXPECT_BIN;
    localparam real TONE_HZ   = ZOOM_CENTRE_HZ + OFFSET_HZ;
    localparam real AMP       = 1800.0;
    localparam [2:0] SPAN_SHIFT = 3'd0;

    // Arbitrary 2 ns clock, only the number of clocks matters.
    reg clock = 1'b0;
    always #1 clock = ~clock;

    reg rst = 1'b1;
    reg [11:0] adc_data = 12'sd0;
    reg        adc_valid = 1'b0;
    reg        enable = 1'b0;
    reg signed [31:0] phase_inc;

    // Outputs of the chip version (_a) and of the reference (_b).
    wire out_valid_a, out_first_a;
    wire [LOG_N-1:0] out_bin_a;
    wire out_usable_a;
    wire signed [17+LOG_N-1:0] out_re_a, out_im_a;

    wire out_valid_b, out_first_b;
    wire [LOG_N-1:0] out_bin_b;
    wire out_usable_b;
    wire signed [17+LOG_N-1:0] out_re_b, out_im_b;

    // The chip's parameters (rtl/zoom/zoom_frontend.v) give a window output of 16 bits and so 28-bit bins, which
    // are sign-extended for the comparison with the 29-bit bins of the reference, whose window output is 17 bits.
    // the chip's parameters (rtl/zoom/zoom_frontend.v): WIN_OUT_W 16, so 28-bit bins, sign-extended as there
    wire signed [16+LOG_N-1:0] new_re, new_im;
    assign out_re_a = new_re;
    assign out_im_a = new_im;
    // Chip version, with the FFT's delay lines up to 512 words in LUT RAM as on the chip.
    zoom_spectrum #(.LOG_N(LOG_N), .WIN_OUT_W(16), .FFT_LUT_MAX_W(512)) dut_new (
        .clock(clock), .rst(rst),
        .adc_data(adc_data), .adc_valid(adc_valid),
        .phase_inc(phase_inc), .span_shift(SPAN_SHIFT), .narrow_shift(3'd0), .narrow_gain(2'd0), .enable(enable),
        .out_valid(out_valid_a), .out_first(out_first_a), .out_bin(out_bin_a),
        .out_usable(out_usable_a), .out_re(new_re), .out_im(new_im)
    );

    // Reference version.
    zoom_spectrum_ref #(.LOG_N(LOG_N)) dut_ref (
        .clock(clock), .rst(rst),
        .adc_data(adc_data), .adc_valid(adc_valid),
        .phase_inc(phase_inc), .span_shift(SPAN_SHIFT), .enable(enable),
        .out_valid(out_valid_b), .out_first(out_first_b), .out_bin(out_bin_b),
        .out_usable(out_usable_b), .out_re(out_re_b), .out_im(out_im_b)
    );

    // The first complete frame of each version, stored by position of arrival.
    reg [LOG_N-1:0] cap_bin_a [0:N-1];
    reg signed [17+LOG_N-1:0] cap_re_a [0:N-1];
    reg signed [17+LOG_N-1:0] cap_im_a [0:N-1];
    reg [LOG_N-1:0] cap_bin_b [0:N-1];
    reg signed [17+LOG_N-1:0] cap_re_b [0:N-1];
    reg signed [17+LOG_N-1:0] cap_im_b [0:N-1];

    // The frame counters and the "frame captured" flags.
    integer frame_a, words_a, frame_b, words_b;
    reg done_a, done_b;

    // Capture of the chip version: from the first out_first until 4,096 words are stored.
    always @(posedge clock) if (out_valid_a) begin
        if (out_first_a) begin
            frame_a = frame_a + 1;
            if (frame_a == 1) words_a = 0;
        end
        if (frame_a == 1 && !done_a) begin
            cap_bin_a[words_a] = out_bin_a;
            cap_re_a[words_a]  = out_re_a;
            cap_im_a[words_a]  = out_im_a;
            words_a = words_a + 1;
            if (words_a == N) done_a = 1'b1;
        end
    end

    // Capture of the reference, the same way.
    always @(posedge clock) if (out_valid_b) begin
        if (out_first_b) begin
            frame_b = frame_b + 1;
            if (frame_b == 1) words_b = 0;
        end
        if (frame_b == 1 && !done_b) begin
            cap_bin_b[words_b] = out_bin_b;
            cap_re_b[words_b]  = out_re_b;
            cap_im_b[words_b]  = out_im_b;
            words_b = words_b + 1;
            if (words_b == N) done_b = 1'b1;
        end
    end

    // Setup: the tone's phase step and the zoom center's NCO phase increment (center over sample rate times
    // 2^32, since the phase accumulator wraps once per cycle).
    integer k, idx, mismatches;
    real w;
    initial begin
        frame_a = 0; words_a = 0; done_a = 1'b0;
        frame_b = 0; words_b = 0; done_b = 1'b0;
        w = 2.0 * PI * TONE_HZ / FS;
        phase_inc = $rtoi((ZOOM_CENTRE_HZ / FS) * 4294967296.0);

        $display("zoom centre = %.0f Hz, tone = %.0f Hz (+%.0f Hz), expected bin = %0d",
                  ZOOM_CENTRE_HZ, TONE_HZ, OFFSET_HZ, EXPECT_BIN);

        // Short reset, then enable.
        repeat (5) @(posedge clock);
        rst = 1'b0;
        @(posedge clock);
        enable = 1'b1;

        // One sample per two clocks (the idle clock is the 50 % duty), until both frames are captured or
        // 180,000 samples have been given (the frame needs 2 x 4,096 x 20 = 163,840).
        for (k = 0; k < 180_000 && !(done_a && done_b); k = k + 1) begin
            @(posedge clock);
            adc_data  <= $rtoi(AMP * $cos(w * k));
            adc_valid <= 1'b1;
            @(posedge clock);
            adc_valid <= 1'b0;
        end
        adc_valid <= 1'b0;
        repeat (50) @(posedge clock);

        // Check: both frames present, then every word equal.
        $display("done_a=%0b words_a=%0d  done_b=%0b words_b=%0d", done_a, words_a, done_b, words_b);

        mismatches = 0;
        if (done_a && done_b) begin
            for (idx = 0; idx < N; idx = idx + 1) begin
                if (cap_bin_a[idx] !== cap_bin_b[idx] ||
                    cap_re_a[idx]  !== cap_re_b[idx]  ||
                    cap_im_a[idx]  !== cap_im_b[idx]) begin
                    mismatches = mismatches + 1;
                    if (mismatches <= 20)
                        $display("MISMATCH idx=%0d: new(bin=%0d re=%0d im=%0d) ref(bin=%0d re=%0d im=%0d)",
                                  idx, cap_bin_a[idx], cap_re_a[idx], cap_im_a[idx],
                                  cap_bin_b[idx], cap_re_b[idx], cap_im_b[idx]);
                end
            end
            $display("TOTAL MISMATCHES: %0d / %0d", mismatches, N);
        end else begin
            $display("FAIL: did not capture both full frames within the simulated time");
            mismatches = mismatches + 1;
        end

        if (mismatches == 0) $display("PASS");
        else $display("FAIL: %0d mismatch(es)", mismatches);
        $finish;
    end
endmodule
