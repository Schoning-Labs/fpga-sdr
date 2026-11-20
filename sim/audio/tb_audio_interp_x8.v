// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Testbench for rtl/audio/audio_interp_x8.v, the interpolator that turns the 48 kHz stereo audio stream into
// a 384 kHz stream for the PT8211 DAC. Interpolating by 8 means the filter first inserts 7 zeros after every
// sample, which raises the sample rate but leaves copies ("images") of the audio spectrum around 48 kHz, 96
// kHz and so on, and then removes those images with a low-pass filter (a polyphase FIR, which only computes
// the multiplications that do not hit a zero). How well the images are removed is the quality of the whole
// block, see docs/learn/GLOSSARY.md for image, polyphase and Goertzel.
//
// Stimulus: three full-scale tones of 12, 15 and 18 kHz (amplitude 0.9 of full scale), one after the other,
// 18 kHz being the upper edge of the filter's designed passband (docs/A1_AUDIO.md). The same sample goes into
// the left and right input. For each tone the nearest image sits at 48 kHz minus the tone frequency (36,
// 33 and 30 kHz), and it is the strongest one because it is the closest to the passband.
//
// Measurement: a Goertzel single-bin DFT, which is a cheap way to compute one frequency bin without a whole
// FFT, gives the level of the tone and of its image in the 384 kHz output. The analysis window is 3,072
// output samples, so the bin spacing is 384,000 / 3,072 = 125 Hz, and the three tones and their images are
// all exact multiples of 125 Hz, which means the energy falls into exactly one bin each and there is no
// spectral leakage to correct for. The ratio of image to tone is therefore a plain measured number.
//
// Pass: the image is at least 60 dB below the tone for every one of the three tones. The testbench prints one
// line per tone with the measured level, then "PASS", or "FAIL: ..." lines and "FAIL: <n> burst(s) above
// -60 dB", or "FAIL: timeout" after 50 ms of simulated time (the three bursts take 48 ms at 48 kHz). Run it
// from the repository root, the include paths and the coefficient file are relative to it:
//   iverilog -g2012 -o sim/out/tb_audio_interp_x8.vvp sim/audio/tb_audio_interp_x8.v && vvp -n sim/out/tb_audio_interp_x8.vvp
// or all testbenches together with tools/check.sh.
//
// `frame_tick` comes from the same rtl/audio/audio_nco_tick.v phase accumulator that audio_pt8211_tx.v uses,
// set to 384 kHz directly, so the interpolator sees the same frame timing as in the full audio engine.

`timescale 1ns / 1ps
`include "rtl/audio/audio_nco_tick.v"
`include "rtl/audio/audio_interp_x8.v"

module tb_audio_interp_x8;

    // 120 MHz is the DSP clock (docs/ARCHITECTURE.md section 2).
    localparam integer CLK_HZ = 120_000_000;
    localparam real    CLK_PERIOD_NS = 1.0e9 / CLK_HZ;
    localparam real    PI = 3.14159265358979323846;

    reg clk = 0;
    always #(CLK_PERIOD_NS / 2.0) clk = ~clk;

    reg rst = 1;

    // 384 kHz frame pulse, one clock long. 120 MHz / 384 kHz is 312.5, so the pulse comes every 312 or 313
    // clocks, the phase accumulator keeps the average exact.
    wire frame_tick;
    audio_nco_tick #(
        .CLK_HZ (CLK_HZ),
        .TICK_HZ(384_000)
    ) u_tick (
        .clk (clk),
        .rst (rst),
        .tick(frame_tick)
    );

    // 48 kHz input side of the interpolator (valid/ready) and its 384 kHz output.
    reg                smp_valid;
    reg  signed [15:0] smp_l, smp_r;
    wire               smp_ready;
    wire               underrun;
    wire signed [15:0] out_l, out_r;
    wire               out_valid;

    audio_interp_x8 dut (
        .clk       (clk),
        .rst       (rst),
        .frame_tick(frame_tick),
        .smp_ready (smp_ready),
        .smp_valid (smp_valid),
        .smp_l     (smp_l),
        .smp_r     (smp_r),
        .underrun  (underrun),
        .out_l     (out_l),
        .out_r     (out_r),
        .out_valid (out_valid)
    );

    // ---------------------------------------------------------------- stimulus: 3 tone bursts
    // Each tone burst is a warm-up half and an analysis half of 384 input samples. The warm-up is far longer
    // than the filter's 18 taps per phase, so the previous burst's tone is gone from the delay line before
    // the analysis half starts. Each input sample becomes 8 output samples.
    localparam integer NBURST       = 3;
    localparam integer N_WARMUP_IN  = 384;  // >> the 18-tap/8-phase transient, flushes the previous burst
    localparam integer N_ANALYZE_IN = 384;
    localparam integer N_IN_BURST   = N_WARMUP_IN + N_ANALYZE_IN;   // 768
    localparam integer N_OUT_BURST  = N_IN_BURST * 8;               // 6144
    localparam integer N_ANALYZE_OUT = N_ANALYZE_IN * 8;            // 3072, = the Goertzel window
    localparam integer N_IN_TOTAL   = N_IN_BURST * NBURST;
    localparam integer N_OUT_TOTAL  = N_OUT_BURST * NBURST;
    // 0.9 of full scale, which leaves room for the small overshoot the filter can add without clipping.
    localparam real    AMP          = 0.9 * 32767.0;

    // Tone frequencies. Over 384 input samples each one has a whole number of cycles (96, 120 and 144), so
    // the analysis window holds exactly complete cycles.
    real freq_hz [0:NBURST-1];
    initial begin
        freq_hz[0] = 12000.0;
        freq_hz[1] = 15000.0;
        freq_hz[2] = 18000.0;
    end

    // The whole input stream, three bursts in a row, as 16-bit integers rounded to nearest.
    reg signed [15:0] stim [0:N_IN_TOTAL-1];
    integer b, n, idx;
    real    phase_arg, s;
    initial begin
        idx = 0;
        for (b = 0; b < NBURST; b = b + 1) begin
            for (n = 0; n < N_IN_BURST; n = n + 1) begin
                phase_arg    = 2.0 * PI * freq_hz[b] * n / 48000.0;
                s            = AMP * $sin(phase_arg);
                stim[idx]    = $rtoi(s >= 0.0 ? s + 0.5 : s - 0.5);
                idx          = idx + 1;
            end
        end
    end

    // Feed the stream into the interpolator: `smp_valid` stays high as long as samples are left, and the
    // index moves on every time the interpolator takes one (`smp_ready` together with `smp_valid`).
    integer stim_idx;
    always @(posedge clk) begin
        if (rst) begin
            stim_idx  <= 0;
            smp_valid <= 1'b0;
            smp_l     <= 16'sd0;
            smp_r     <= 16'sd0;
        end else begin
            smp_valid <= (stim_idx < N_IN_TOTAL);
            if (stim_idx < N_IN_TOTAL) begin
                smp_l <= stim[stim_idx];
                smp_r <= stim[stim_idx];
            end
            if (smp_ready && smp_valid && stim_idx < N_IN_TOTAL)
                stim_idx <= stim_idx + 1;
        end
    end

    // ---------------------------------------------------------------- capture output
    reg signed [15:0] captured [0:N_OUT_TOTAL-1];
    integer out_count;
    // Store every output sample; the left channel stands for both, as both inputs are identical.
    always @(posedge clk) begin
        if (rst) begin
            out_count <= 0;
        end else if (out_valid && out_count < N_OUT_TOTAL) begin
            captured[out_count] <= out_l; // out_l == out_r for this mono-into-both-channels stimulus
            out_count           <= out_count + 1;
        end
    end

    // ---------------------------------------------------------------- Goertzel single-bin magnitude
    // Goertzel: for window captured[base_off ..  base_off + nwin - 1] and the integer bin k, the recurrence
    // s0 = x + 2 cos(w) s1 - s2 with w = 2 pi k / nwin runs over the window, and the last two states give the
    // real and imaginary part of that bin. Only the magnitude is used, so no scaling to dB-full-scale is needed.
    // window: captured[base_off .. base_off+N-1], target bin k (integer, exact - see header)
    task automatic goertzel_mag(
        input integer base_off,
        input integer nwin,
        input integer k,
        output real   mag
    );
        real w, coeff, s0, s1, s2, re, im;
        integer i;
        begin
            w     = 2.0 * PI * k / nwin;
            coeff = 2.0 * $cos(w);
            s1 = 0.0; s2 = 0.0;
            for (i = 0; i < nwin; i = i + 1) begin
                s0 = $itor(captured[base_off + i]) + coeff * s1 - s2;
                s2 = s1;
                s1 = s0;
            end
            re  = s1 - s2 * $cos(w);
            im  = s2 * $sin(w);
            mag = $sqrt(re * re + im * im);
        end
    endtask

    integer errors;
    real    sig_mag, img_mag, ratio_db;
    integer sig_bin, img_bin, win_off;
    real    fimg;

    initial begin
        errors = 0;
        // Hold reset for 30 clocks, then let the stimulus run until all output samples are captured.
        #(30 * CLK_PERIOD_NS);
        rst = 0;

        wait (out_count >= N_OUT_TOTAL);
        #(2 * CLK_PERIOD_NS);

        // For each burst: analyze the second half, the first half was the warm-up. The tone bin is
        // frequency / 125 Hz, the image bin is (48,000 Hz minus the frequency) / 125 Hz.
        for (b = 0; b < NBURST; b = b + 1) begin
            win_off = b * N_OUT_BURST + N_ANALYZE_OUT; // skip the warmup half of this burst
            sig_bin = $rtoi(freq_hz[b] / 125.0 + 0.5);
            fimg    = 48000.0 - freq_hz[b];
            img_bin = $rtoi(fimg / 125.0 + 0.5);

            goertzel_mag(win_off, N_ANALYZE_OUT, sig_bin, sig_mag);
            goertzel_mag(win_off, N_ANALYZE_OUT, img_bin, img_mag);

            // Image level relative to the tone in dB, a negative number when the image is smaller.
            ratio_db = 20.0 * $log10(img_mag / sig_mag);
            $display("tone %0.0f Hz: image at %0.0f Hz = %0.2f dB relative to the tone",
                      freq_hz[b], fimg, ratio_db);

            // The requirement: image at least 60 dB down.
            if (ratio_db > -60.0) begin
                $display("FAIL: tone %0.0f Hz image only %0.2f dB down (need <= -60 dB)",
                          freq_hz[b], ratio_db);
                errors = errors + 1;
            end
        end

        if (underrun !== 1'bx && underrun) begin
            // Underrun is not expected as `smp_valid` is held high for the whole stream, the test does not
            // act on it.
        end

        if (errors == 0)
            $display("PASS");
        else
            $display("FAIL: %0d burst(s) above -60 dB", errors);
        $finish;
    end

    // Safety net: 50 ms of simulated time, a little above the 48 ms the three bursts take.
    initial begin
        #(50_000_000);
        $display("FAIL: timeout, out_count=%0d (expected %0d)", out_count, N_OUT_TOTAL);
        $finish;
    end

endmodule
