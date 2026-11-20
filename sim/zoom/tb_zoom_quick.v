// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Quick end-to-end test of the zoom spectrum, rtl/zoom/zoom_spectrum.v: a tone at a known offset from the
// zoom center must show up in the predicted bin of the 4,096-point FFT, after going through the real chain
// of the zoom DDC (digital down-converter), the window and the FFT. The DDC multiplies the ADC samples with
// a numerically controlled oscillator (NCO, a phase accumulator that makes a complex sine of the wanted
// frequency) so that the zoom center lands at 0 Hz, and then filters and decimates (keeps only a fraction
// of the samples) to the rate of the chosen span; the window (Blackman-Harris) shapes each block of 4,096
// samples so that the FFT shows little leakage between bins. docs/learn/GLOSSARY.md has these terms.
//
// Stimulus: the 12-bit ADC samples are made in the bench with $cos at 76.8 Msps, as the ADC delivers them.
// The zoom center is 10 MHz (an arbitrary HF frequency) and the tone sits 45 kHz above it, that is 48 bins
// of 937.5 Hz at the widest span (span_shift = 0, which makes the cic_var_pow2 stage an identity), so the
// tone falls exactly on a bin. The amplitude is 1,800 of the 2,047 full scale. The widest span is used
// here instead of the 48 kHz span that the done-test of the zoom names literally, because one FFT frame
// needs 4,096 x decimation ADC clocks whatever else changes, and the total decimation of the 48 kHz span
// is 1,280, which takes tens of minutes (sim/zoom/zoom_bin48_sim.v runs that case, and every other span,
// through sim/zoom/run_sim.sh). The mechanism that is exercised is the same: DDC, windowing and FFT indexing.
//
// The FFT runs at the full internal rate of the DDC (3.84 MHz at this span), and the 80 % of the bins that are
// alias-protected and displayed are only a part of that, so the bin spacing is worked out from the full rate,
// as zoom_spectrum.v does with its out_bin and out_usable.
//
// The coefficient files rtl/zoom/zoom_window_coeffs.hex, rtl/zoom/zoom_fir_half_coeffs.hex,
// rtl/zoom/zoom_cic_comp_coeffs.hex and rtl/fft/tw/fft_tw18_l12.hex are read from the checked-in copies, no
// input file is generated.
//
// What counts as a pass, taken on the first complete FFT frame: it has exactly 4,096 words, the bin with the
// largest magnitude is bin 48, and its power is more than four times (6 dB above) the largest power of any bin
// outside the tone's own main lobe (bins 40 to 56). The bench prints the center, the tone, the bin
// spacing and the peak, and ends with PASS or FAIL.
//
// Run from the repository root (tools/check.sh runs it as well):
//   iverilog -g2012 -o tb.vvp sim/zoom/tb_zoom_quick.v && vvp tb.vvp

`timescale 1ns / 1ps

// The DDC and the receiver's mixer and CIC filters, the two FIR stages, the window and the FFT, which
// make up zoom_spectrum.v.
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

module tb_zoom_quick;

    // PI and the sampling rate of the ADC (76.8 Msps).
    localparam real PI = 3.14159265358979323846;
    localparam real FS = 76_800_000.0;
    // The zoom center, 10 MHz.
    localparam real ZOOM_CENTRE_HZ = 10_000_000.0;  // arbitrary HF frequency
    // Full internal rate at span_shift = 0: 76.8 MHz / 10 (fixed CIC) / 1 (variable CIC) / 2 (half-band filter) = 3.84 MHz.
    // Full (uncropped) internal rate at span_shift=0: 76.8e6/10/1/2 = 3.84 MHz
    localparam real FULL_RATE_HZ = 76_800_000.0 / 10.0 / 1.0 / 2.0;
    localparam integer LOG_N  = 12;
    localparam integer N      = 1 << LOG_N;
    // Bin spacing 3.84 MHz / 4,096 = 937.5 Hz.
    localparam real    BIN_HZ = FULL_RATE_HZ / N;     // 937.5 Hz
    // 48 bins of offset is an exact multiple of the spacing, so the tone has no scalloping loss.
    localparam integer EXPECT_BIN = 48;               // chosen to land exactly on a bin
    localparam real OFFSET_HZ = BIN_HZ * EXPECT_BIN;  // 45,000 Hz
    // zoom_ddc.v negates phase_inc internally, so a tone above the tuned center lands in the bin above
    // center (docs/F3_ZOOM.md section 5): the tone is simply center plus offset.
    localparam real TONE_HZ   = ZOOM_CENTRE_HZ + OFFSET_HZ;
    // Amplitude 1,800 of 2,047, a little below full scale of the signed 12-bit samples.
    localparam real AMP       = 1800.0;               // comfortably under full scale (2047)
    localparam [2:0] SPAN_SHIFT = 3'd0;

    // Arbitrary 2 ns clock, only the number of clocks matters.
    reg clock = 1'b0;
    always #1 clock = ~clock;

    // Stimulus signals and the outputs of the FFT: out_re and out_im are 17 + 12 bits wide (window output
    // width plus the growth of a 4,096-point FFT).
    reg rst = 1'b1;
    reg [11:0] adc_data = 12'sd0;
    reg        adc_valid = 1'b0;
    reg        enable = 1'b0;
    reg signed [31:0] phase_inc;

    wire               out_valid, out_first;
    wire [LOG_N-1:0]   out_bin;
    wire signed [17+LOG_N-1:0] out_re, out_im;

    // Nothing is connected to out_usable here, the bench looks at all bins and decides itself.
    zoom_spectrum #(.LOG_N(LOG_N)) dut (
        .clock(clock), .rst(rst),
        .adc_data(adc_data), .adc_valid(adc_valid),
        .phase_inc(phase_inc), .span_shift(SPAN_SHIFT), .narrow_shift(3'd0), .narrow_gain(2'd0), .enable(enable),
        .out_valid(out_valid), .out_first(out_first), .out_bin(out_bin),
        .out_re(out_re), .out_im(out_im)
    );

    // A windowed tone has a main lobe that is several bins wide (that is what gives the Blackman-Harris
    // window its side lobes of about -92 dB), so its immediate neighbours always carry real energy and
    // the peak must not be compared with them. "No other bin comes close" therefore means outside the
    // main lobe, as in the SFDR figures of docs/F1_FFT.md. The expected bin is known, so the guard band is
    // a fixed range of 8 bins on each side of it, and no wrap-around has to be handled for the bins used here
    // or in sim/zoom/zoom_bin48_sim.v.
    localparam integer LOBE_GUARD = 8;
    localparam integer LOBE_LO = EXPECT_BIN - LOBE_GUARD;
    localparam integer LOBE_HI = EXPECT_BIN + LOBE_GUARD;

    integer k;
    real w;
    real mag2, best_mag2, second_mag2;
    integer best_bin, frame_count, words_this_frame;
    real final_best_mag2, final_second_mag2;
    integer final_best_bin, final_words, errors;
    reg done, capturing;

    // Frame 0 is the first frame that the FFT delivers (the convention of rtl/fft/fft_r22sdf.v). Capturing
    // starts at its out_first and ends the moment all 4,096 of its words have been seen, so the bench
    // does not wait for frame 1 and does not need a second frame of decimated input for that. Per word the
    // power is worked out in floating point, the largest one overall is kept with its bin, and the
    // largest one outside the main lobe is kept separately.
    always @(posedge clock) if (out_valid) begin
        mag2 = $itor($signed(out_re)) * $itor($signed(out_re))
             + $itor($signed(out_im)) * $itor($signed(out_im));
        if (out_first) begin
            frame_count = frame_count + 1;
            if (frame_count == 1) begin
                capturing = 1'b1;
                words_this_frame = 0;
                best_mag2 = -1.0; best_bin = -1; second_mag2 = -1.0;
            end
        end
        if (capturing && !done) begin
            if (mag2 > best_mag2) begin
                best_mag2 = mag2; best_bin = out_bin; // global argmax, any bin
            end
            if ((out_bin < LOBE_LO || out_bin > LOBE_HI) && mag2 > second_mag2) begin
                second_mag2 = mag2; // highest OUTSIDE the expected tone's own main lobe
            end
            words_this_frame = words_this_frame + 1;
            if (words_this_frame == N) begin
                final_best_bin = best_bin; final_best_mag2 = best_mag2;
                final_second_mag2 = second_mag2; final_words = words_this_frame;
                done = 1'b1;
            end
        end
    end

    // Start: tone phase step and the zoom center's phase increment, which is the center frequency over the
    // sampling rate times 2^32 (the NCO's phase accumulator wraps once per cycle), then a short reset.
    initial begin
        errors = 0;
        frame_count = 0;
        words_this_frame = 0;
        best_mag2 = -1.0; best_bin = -1; second_mag2 = -1.0;
        done = 1'b0; capturing = 1'b0;
        final_best_bin = -1; final_best_mag2 = 0.0; final_second_mag2 = 0.0; final_words = 0;
        w = 2.0 * PI * TONE_HZ / FS;
        phase_inc = $rtoi((ZOOM_CENTRE_HZ / FS) * 4294967296.0);

        $display("zoom centre = %.0f Hz, tone = %.0f Hz (+%.0f Hz), full rate = %.1f kHz, bin = %.2f Hz, expected bin = %0d",
                  ZOOM_CENTRE_HZ, TONE_HZ, OFFSET_HZ, FULL_RATE_HZ/1000.0, BIN_HZ, EXPECT_BIN);

        repeat (5) @(posedge clock);
        rst = 1'b0;
        @(posedge clock);
        enable = 1'b1;

        // Frame 0 begins after 4,096 x 20 = 81,920 ADC samples (total decimation at span_shift = 0 is 10 for the
        // fixed CIC, 1 for the variable CIC and 2 for the half-band filter). Its output streams out one word
        // per input word while the input of frame 1 is fed (fft_r22sdf.v: frame f comes out while frame
        // f+1 goes in), so capturing all 4,096 words of frame 0 needs a second frame of input as well,
        // about 2 x 4,096 x 20 = 163,840 ADC samples. The loop runs for at most 180,000 and ends the
        // moment `done` goes high.
        //
        // The ADC samples are not given on every clock. The serial engines of the half-band and droop filters
        // need idle clocks between their inputs, and 76.8 Msps into a 120 MHz clock is at most 64 % of the
        // clocks even with no gaps at all in the network stream, so one idle clock follows every sample,
        // which is a steady 50 % duty. The values and their order are unchanged (k still counts ADC
        // samples one for one), so only the pacing in time differs, and the math does not.
        // One sample every second clock: cosine at the tone frequency, rounded to an integer.
        for (k = 0; k < 180_000 && !done; k = k + 1) begin
            @(posedge clock);
            adc_data  <= $rtoi(AMP * $cos(w * k));
            adc_valid <= 1'b1;
            @(posedge clock);
            adc_valid <= 1'b0;
        end
        adc_valid <= 1'b0;
        // Report and checks: a complete frame with all 4,096 words, the peak in the expected bin, and the
        // peak at least 6 dB above everything outside the main lobe.
        repeat (20) @(posedge clock);

        $display("frames seen = %0d; first complete frame: %0d words, peak bin = %0d, peak mag^2 = %.3e, next mag^2 = %.3e",
                  frame_count, final_words, final_best_bin, final_best_mag2, final_second_mag2);

        if (!done) begin
            $display("FAIL: no complete FFT frame captured within the simulated time");
            errors = errors + 1;
        end else begin
            if (final_words != N) begin
                $display("FAIL: captured frame had %0d words, expected %0d (a decimated sample was dropped)", final_words, N);
                errors = errors + 1;
            end
            if (final_best_bin != EXPECT_BIN) begin
                $display("FAIL: peak bin %0d != expected bin %0d", final_best_bin, EXPECT_BIN);
                errors = errors + 1;
            end
            if (final_best_mag2 <= final_second_mag2 * 4.0) begin // >= 6 dB above every other bin
                $display("FAIL: peak bin not clearly dominant (peak %.3e vs next %.3e)", final_best_mag2, final_second_mag2);
                errors = errors + 1;
            end
        end

        if (errors == 0) $display("PASS");
        else $display("FAIL: %0d error(s)", errors);
        $finish;
    end

endmodule
