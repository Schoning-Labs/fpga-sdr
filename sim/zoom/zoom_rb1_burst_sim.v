// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Word-for-word comparison of the zoom spectrum as built for the chip, rtl/zoom/zoom_spectrum.v, against the
// plain parallel reference chain in sim/zoom/ref/, with the ADC samples arriving the way the HL2 delivers them: whole
// frames of 5,968 samples on consecutive clocks (docs/ARCHITECTURE.md section 3.2), then an idle gap, at the
// widest span. This is the burst condition that the circular buffers of zoom_fir_half.v and zoom_cic_comp.v are
// sized for: the serial filters fall behind by up to about 240 samples during a frame, and catch up in
// the gap. The chip version shares its multipliers across the taps and works serially, the reference forms every
// product at once, and they are written separately, so equal words show that the backlog handling changes nothing
// in the result. docs/learn/GLOSSARY.md explains the terms.
//
// The structure is that of sim/zoom/zoom_rb1_compare_sim.v, whose header has the details, and the setup is that of
// tb_zoom_quick.v: a real ADC tone of 1,800 amplitude 45 kHz (48 bins) above a zoom center of 10 MHz, span_shift 0.
// Each version captures its own first complete 4,096-word FFT frame, and the two frames are compared index by index.
// The gap is 5,734 clocks, which makes the long-run average duty 5,968 / (5,968 + 5,734) = 51 %, the share
// that 76.8 Msps takes of a 150 MHz clock. At most 40 bursts are given, and the bench stops as soon as both
// frames are captured.
//
// What counts as a pass: both frames were captured, and all 4,096 words (bin, real and imaginary part) are
// identical. The bench prints the first twenty mismatches and the total, and ends with PASS or FAIL.
//
// Run from the repository root (about 10 minutes). It is not run by tools/check.sh, which it would
// overrun, and it is step 4 of sim/zoom/run_sim.sh:
//   iverilog -g2012 -o build/zoom_rb1_burst.vvp sim/zoom/zoom_rb1_burst_sim.v && vvp build/zoom_rb1_burst.vvp

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

module zoom_rb1_burst_sim;
    // Same tone and span as tb_zoom_quick.v: full internal rate 76.8 MHz / 10 / 1 / 2 = 3.84 MHz, bin
    // spacing 3.84 MHz / 4,096 = 937.5 Hz, and the tone 48 bins above the center.
    localparam real PI = 3.14159265358979323846;
    localparam real FS = 76_800_000.0;
    localparam real ZOOM_CENTRE_HZ = 10_000_000.0;
    localparam integer LOG_N  = 12;
    localparam integer N      = 1 << LOG_N;
    localparam real    FULL_RATE_HZ = 76_800_000.0 / 10.0 / 1.0 / 2.0;
    localparam real    BIN_HZ = FULL_RATE_HZ / N;
    localparam integer EXPECT_BIN = 48;
    localparam real OFFSET_HZ = BIN_HZ * EXPECT_BIN;
    localparam real TONE_HZ   = ZOOM_CENTRE_HZ + OFFSET_HZ;
    localparam real AMP       = 1800.0;
    localparam [2:0] SPAN_SHIFT = 3'd0;

    // One HL2 frame is 5,968 samples, and the gap after it gives the 51 % average duty.
    localparam integer FRAME_SAMPLES = 5968; // one HL2 frame, ARCHITECTURE.md 3.2
    localparam integer GAP_CLOCKS    = 5734; // 5968/(5968+5734) = 51.0% average duty

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

    // Chip version.
    zoom_spectrum #(.LOG_N(LOG_N)) dut_new (
        .clock(clock), .rst(rst),
        .adc_data(adc_data), .adc_valid(adc_valid),
        .phase_inc(phase_inc), .span_shift(SPAN_SHIFT), .narrow_shift(3'd0), .narrow_gain(2'd0), .enable(enable),
        .out_valid(out_valid_a), .out_first(out_first_a), .out_bin(out_bin_a),
        .out_usable(out_usable_a), .out_re(out_re_a), .out_im(out_im_a)
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
    integer k, idx, mismatches, burst;
    real w;
    integer sample_n;
    initial begin
        frame_a = 0; words_a = 0; done_a = 1'b0;
        frame_b = 0; words_b = 0; done_b = 1'b0;
        w = 2.0 * PI * TONE_HZ / FS;
        phase_inc = $rtoi((ZOOM_CENTRE_HZ / FS) * 4294967296.0);
        sample_n = 0;

        $display("zoom centre = %.0f Hz, tone = %.0f Hz (+%.0f Hz), expected bin = %0d, frame=%0d samples, gap=%0d clocks (%.1f%% duty)",
                  ZOOM_CENTRE_HZ, TONE_HZ, OFFSET_HZ, EXPECT_BIN, FRAME_SAMPLES, GAP_CLOCKS,
                  100.0 * FRAME_SAMPLES / (FRAME_SAMPLES + GAP_CLOCKS));

        // Short reset, then enable.
        repeat (5) @(posedge clock);
        rst = 1'b0;
        @(posedge clock);
        enable = 1'b1;

        // Bursts: a frame of consecutive samples, then the idle gap, until both frames are captured.
        burst = 0;
        while (!(done_a && done_b) && burst < 40) begin
            burst = burst + 1;
            for (k = 0; k < FRAME_SAMPLES && !(done_a && done_b); k = k + 1) begin
                @(posedge clock);
                adc_data  <= $rtoi(AMP * $cos(w * sample_n));
                adc_valid <= 1'b1;
                sample_n = sample_n + 1;
            end
            adc_valid <= 1'b0;
            for (k = 0; k < GAP_CLOCKS && !(done_a && done_b); k = k + 1) begin
                @(posedge clock);
            end
        end
        repeat (50) @(posedge clock);

        $display("done_a=%0b words_a=%0d  done_b=%0b words_b=%0d  bursts=%0d", done_a, words_a, done_b, words_b, burst);

        // Check: both frames present, then every word equal.
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
            $display("FAIL: did not capture both full frames within %0d bursts", burst);
            mismatches = mismatches + 1;
        end

        if (mismatches == 0) $display("PASS");
        else $display("FAIL: %0d mismatch(es)", mismatches);
        $finish;
    end
endmodule
