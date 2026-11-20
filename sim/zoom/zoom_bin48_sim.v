// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// The literal done-test of the zoom spectrum, run to completion: a tone 1 kHz off the zoom center at the 48 kHz
// span must land in the right bin, through the real chain of zoom DDC, window and 4,096-point FFT in
// rtl/zoom/zoom_spectrum.v, with no shortcuts. The DDC (digital down-converter) mixes the ADC samples with a
// numerically controlled oscillator so that the zoom center sits at 0 Hz and then filters and decimates,
// which means that it keeps only a fraction of the samples, down to the rate of the span; the window shapes
// each block of 4,096 samples to keep the leakage between FFT bins low. docs/learn/GLOSSARY.md has the terms.
//
// The file is deliberately not named tb_*.v, so tools/check.sh does not pick it up, because at the 48 kHz span
// the total decimation is 1,280 (fixed CIC 10, variable CIC 64, half-band filter 2) and one 4,096-sample FFT frame
// needs 4,096 x 1,280 = 5,242,880 ADC clocks, which takes about 20 to 30 minutes under iverilog (docs/F3_ZOOM.md
// section 6.2). tools/check.sh runs sim/zoom/tb_zoom_quick.v instead, which uses the same method at the
// widest span for a quick regression, and this bench proves the case that is named literally.
//
// The FFT itself runs at the full internal rate of the DDC, which is 60 kHz at this span (docs/F3_ZOOM.md
// section 3, the displayed 48 kHz is 80 % of it), and the bin spacing is worked out from that rate:
// 76.8 MHz / 10 / 64 / 2 = 60 kHz, divided by 4,096 bins, is 14.65 Hz.
//
// Stimulus: the zoom center is 7.1 MHz (an arbitrary HF frequency) and a real ADC tone of 1,800 amplitude (the
// full scale is 2,047) is made in the bench with $cos exactly 1 kHz above it, one sample per clock at 76.8
// Msps, for one full output frame plus the second frame of input that the FFT needs to deliver the first
// (see the loop below). The coefficient files rtl/zoom/zoom_window_coeffs.hex, rtl/zoom/zoom_fir_half_coeffs.hex,
// rtl/zoom/zoom_cic_comp_coeffs.hex and rtl/fft/tw/fft_tw18_l12.hex are read from the checked-in copies.
//
// What counts as a pass, on the first complete FFT frame: it has 4,096 words, the bin with the largest
// magnitude is bin round(1,000 / 14.65) = 68, and its power is more than four times (6 dB above) the largest
// power of any bin outside the tone's own main lobe (bins 60 to 76), which is a coarse sanity check of the
// image rejection as well. The bench prints the figures and ends with PASS or FAIL.
//
// Run from the repository root, it takes 20 to 30 minutes (sim/zoom/run_sim.sh runs it as step 2):
//   iverilog -g2012 -o tb.vvp sim/zoom/zoom_bin48_sim.v && vvp tb.vvp

`timescale 1ns / 1ps

// The DDC (mixer, CIC filters, half-band and droop filters), the window and the FFT, which make up zoom_spectrum.v.
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

module zoom_bin48_sim;

    // The ADC rate (76.8 Msps) and the zoom center.
    localparam real PI = 3.14159265358979323846;
    localparam real FS = 76_800_000.0;
    localparam real ZOOM_CENTRE_HZ = 7_100_000.0;   // arbitrary HF frequency
    localparam real OFFSET_HZ      = 1_000.0;       // 1 kHz off centre, per the done-test
    // zoom_ddc.v negates phase_inc internally, so a tone above the tuned center lands in the bin above
    // center (docs/F3_ZOOM.md section 5): the tone is simply center plus offset.
    localparam real TONE_HZ        = ZOOM_CENTRE_HZ + OFFSET_HZ;
    // Amplitude 1,800 of 2,047, a little below full scale of the signed 12-bit samples.
    localparam real AMP            = 1800.0;        // comfortably under full scale (2047)

    localparam integer LOG_N  = 12;
    localparam integer N      = 1 << LOG_N;
    // span_shift 6 is the 48 kHz displayed span, with a total decimation of 20 x 64 = 1,280.
    localparam [2:0]   SPAN_SHIFT = 3'd6;            // 48 kHz displayed span (total decimation 1,280)
    // Full internal rate: 76.8 MHz / 10 (fixed CIC) / 64 (variable CIC) / 2 (half-band filter) = 60 kHz.
    localparam real    FULL_RATE_HZ = 76_800_000.0 / 10.0 / 64.0 / 2.0; // 60 kHz
    localparam real    BIN_HZ  = FULL_RATE_HZ / N;
    // The bin the tone should land in: the offset over the bin spacing, rounded (1,000 / 14.65 = 68.3).
    localparam integer EXPECT_BIN = $rtoi(OFFSET_HZ / BIN_HZ + 0.5); // round

    // Arbitrary 2 ns clock, only the number of clocks matters.
    reg clock = 1'b0;
    always #1 clock = ~clock;

    reg rst = 1'b1;
    reg [11:0] adc_data = 12'sd0;
    reg        adc_valid = 1'b0;
    reg        enable = 1'b0;
    reg signed [31:0] phase_inc;

    wire               out_valid, out_first;
    wire [LOG_N-1:0]   out_bin;
    wire signed [17+LOG_N-1:0] out_re, out_im;

    // The DUT: no narrow-span stage (narrow_shift 0), and the usable-bin flag is not used here.
    zoom_spectrum #(.LOG_N(LOG_N)) dut (
        .clock(clock), .rst(rst),
        .adc_data(adc_data), .adc_valid(adc_valid),
        .phase_inc(phase_inc), .span_shift(SPAN_SHIFT), .narrow_shift(3'd0), .narrow_gain(2'd0), .enable(enable),
        .out_valid(out_valid), .out_first(out_first), .out_bin(out_bin),
        .out_re(out_re), .out_im(out_im)
    );

    // As in tb_zoom_quick.v, the main lobe of a windowed tone is several bins wide, so it is left out
    // of the check that no other bin comes close, with a guard band of 8 bins on each side of the expected bin.
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
    // starts at its out_first and ends the moment all 4,096 of its words have been seen, because waiting for
    // the out_first of frame 1 as well would need a second frame of input for nothing, which
    // would double an ADC clock budget that is already large. The largest power overall is kept with its bin, and
    // the largest one outside the main lobe separately.
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

    // Start: the tone's phase step per sample, the zoom center's NCO phase increment (center over sample rate
    // times 2^32, because the phase accumulator wraps once per cycle), and a short reset.
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

        // Frame 0 begins after 4,096 x 1,280 = 5,242,880 ADC clocks. Its output then streams out one word
        // per input word while the input of frame 1 is fed (fft_r22sdf.v: frame f comes out while frame f+1
        // goes in), so capturing all 4,096 words of frame 0 needs a second frame of input as well, about
        // 2 x 4,096 x 1,280 = 10,485,760 ADC clocks. The loop runs for at most 10,600,000 and ends the
        // moment `done` goes high. The tone is one sample per clock, cosine rounded to an integer.
        for (k = 0; k < 10_600_000 && !done; k = k + 1) begin
            @(posedge clock);
            adc_data  <= $rtoi(AMP * $cos(w * k));
            adc_valid <= 1'b1;
        end
        adc_valid <= 1'b0;
        repeat (20) @(posedge clock);

        // Report and checks: a complete frame, the peak in the expected bin, and the peak at least 6 dB above
        // everything outside the main lobe.
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
