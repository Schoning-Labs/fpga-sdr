// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Test of the part of the zoom DDC that only the four narrow spans (24, 12, 6 and 3 kHz) use, on its own
// (docs/ZOOM_IN_CHIP.md section 12): the third CIC filter rtl/zoom/zoom_cic_narrow.v, then the half-band
// filter rtl/zoom/zoom_fir_half.v, then the droop compensation rtl/zoom/zoom_cic_comp.v. A CIC (cascaded
// integrator-comb) filter is a chain of running sums and differences around a decimation, which keeps only
// every R-th sample, and the droop is the fall in its pass band gain towards the band edge that the last
// filter compensates; docs/learn/GLOSSARY.md has the terms.
//
// The chain is fed with what cic_var_pow2 delivers at its largest decimation (64), which is one complex 16-bit
// sample every 640 clocks, a rate of 120 ksps (7.68 Msps / 64, with 76.8 MHz / 120 kHz = 640 clocks between
// samples). The mixer and the two CIC stages in front are left out, and that is what makes the bench fast
// (minutes, where a 3 kHz span through the whole DDC in sim/zoom/zoom_alias_sim.v takes hours): at these
// spans the wanted band is a few kHz around the center, where those two stages are flat, and their own alias bands
// lie behind their nulls (tools/analyze_zoom_alias.py).
//
// For each narrow span index 7 to 10 (24, 12, 6 and 3 kHz, which is a decimation of 2, 4, 8 and 16 in
// zoom_cic_narrow), the bench feeds complex tones and checks:
//   1. Flatness: tones at 2 %, 20 % and 39 % of the output rate (the displayed band ends at 40 %) must come
//      out within 0.03 dB of the input amplitude, after adding back the droop of the two CIC stages that are
//      not in the bench (a function in this file works that out). The droop filter's coefficient set for
//      the span takes it out as well, and it amounts to 1.5 dB at the edge of the 24 kHz span, which is 12 kHz
//      off the center of the 120 ksps stream of cic_var_pow2.
//   2. Alias rejection of 80 dB or more for a full-scale tone at
//      a) the worst frequency of the whole chain (from sim/zoom/zoom_alias_config.vh, which is the
//         half-band filter's)
//      b) the nearest alias band of zoom_cic_narrow itself (its output rate less 30 % of the final rate)
//      measured as the line at the frequency that the tone lands on (the output correlated with that frequency
//      over the 60 measured points). The largest single output word is printed as well. It is 2 steps of
//      the 16-bit word, which is 78 dB under full scale, and it is rounding noise of the three 16-bit words in the
//      chain (the middle coefficient of the droop filter is 1.5), not the tone.
//   3. Gain: with narrow_gain = 2 (a factor of 16) a tone 30 dB under full scale must come out 24.08 dB higher,
//      within 0.05 dB.
// The bench prints one line per measurement and ends with the worst flatness error and the worst rejection,
// then PASS if there were no errors, and FAIL otherwise. Giving +dbg on the vvp command line runs only the
// first span and prints some output words.
//
// Run from the repository root (sim/zoom/zoom_alias_config.vh comes from tools/analyze_zoom_alias.py):
//   iverilog -g2012 -o build/zoom_narrow_chain.vvp sim/zoom/zoom_narrow_chain_sim.v && vvp build/zoom_narrow_chain.vvp

`timescale 1ns / 1ps

// The receiver's mixer, CIC and FIR blocks that the zoom filters build on, and then the three filters of the bench.
`include "rtl/rx/nco_mixer.v"
`include "rtl/rx/cic_integrator.v"
`include "rtl/rx/cic_comb.v"
`include "rtl/rx/cic_fixed.v"
`include "rtl/rx/cic_var_shared.v"
`include "rtl/rx/fir_delay_ram2.v"
`include "rtl/rx/fir_decim.v"
`include "rtl/rx/rx_channel.v"
`include "rtl/zoom/zoom_cic_narrow.v"
`include "rtl/zoom/zoom_fir_half.v"
`include "rtl/zoom/zoom_cic_comp.v"
`include "sim/zoom/zoom_alias_config.vh"

module zoom_narrow_chain_sim;
    // FIN is the rate of the stream into zoom_cic_narrow (7.68 Msps / 64). AMP is a full-scale tone at that point
    // (a full-scale 12-bit ADC tone is about 2^14 after the mixer and the fixed CIC), GAP the clocks between
    // samples, and each measurement runs POINTS output points of which the first SKIP are skipped.
    localparam real PI   = 3.14159265358979323846;
    localparam real FIN  = 120_000.0;          // sample rate into zoom_cic_narrow
    localparam real AMP  = 16_300.0;           // a full-scale ADC tone is about 2^14 here
    localparam integer GAP    = 640;           // clocks between input samples
    localparam integer POINTS = 160, SKIP = 100;

    // Arbitrary 2 ns clock, only the number of clocks matters.
    reg clock = 1'b0;
    always #1 clock = ~clock;

    reg        rst = 1'b1;
    reg [2:0]  nshift = 3'd1;
    reg [1:0]  ngain = 2'd0;
    reg        in_strobe = 1'b0;
    reg signed [15:0] in_i = 16'sd0, in_q = 16'sd0;
    wire       s3, sf, so;
    wire signed [15:0] i3, q3, fi, fq, oi, oq;

    // The three stages of the narrow chain. The droop compensation takes the coefficient set of its own span:
    // span index = 6 + narrow shift.
    zoom_cic_narrow #(.STAGES(11), .WIDTH(16), .MAX_SHIFT(4)) u_cic3 (
        .clock(clock), .rst(rst), .shift(nshift), .gain(ngain),
        .in_strobe(in_strobe), .in_i(in_i), .in_q(in_q), .out_strobe(s3), .out_i(i3), .out_q(q3));
    zoom_fir_half #(.TAPS(63), .IN_WIDTH(16), .COEFF_WIDTH(20), .OUT_WIDTH(16)) u_fir (
        .clock(clock), .rst(rst), .in_strobe(s3), .in_i(i3), .in_q(q3),
        .out_strobe(sf), .out_i(fi), .out_q(fq));
    zoom_cic_comp #(.TAPS(15), .IN_WIDTH(16), .COEFF_WIDTH(18), .OUT_WIDTH(16), .N_SPANS(11)) u_comp (
        .clock(clock), .rst(rst), .span_shift(4'd6 + {1'b0, nshift}),
        .in_strobe(sf), .in_i(fi), .in_q(fq), .out_strobe(so), .out_i(oi), .out_q(oq));

    // Output statistics: the peak |I + jQ| after the first SKIP points, and sums for the line at the frequency
    // that the tone lands on (correlations against + and - that frequency, I and Q together).
    integer n_out = 0;
    real    peak = 0.0, m;
    real    w_land = 0.0, cr_p = 0.0, ci_p = 0.0, cr_n = 0.0, ci_n = 0.0;   // against +/- the landing frequency
    always @(posedge clock) if (so && !rst) begin
        n_out = n_out + 1;
        if (n_out > SKIP) begin
            m = $sqrt($itor(oi) * $itor(oi) + $itor(oq) * $itor(oq));
            if (m > peak) peak = m;
            cr_p = cr_p + $itor(oi) * $cos(w_land * n_out) + $itor(oq) * $sin(w_land * n_out);
            ci_p = ci_p + $itor(oq) * $cos(w_land * n_out) - $itor(oi) * $sin(w_land * n_out);
            cr_n = cr_n + $itor(oi) * $cos(w_land * n_out) - $itor(oq) * $sin(w_land * n_out);
            ci_n = ci_n + $itor(oq) * $cos(w_land * n_out) + $itor(oi) * $sin(w_land * n_out);
            if ($test$plusargs("dbg") && n_out < SKIP + 12) $display("   out %0d %0d   fir %0d %0d  cic3 %0d %0d", oi, oq, fi, fq, i3, q3);
        end
    end

    // line is the amplitude of the line found at the landing frequency in the last tone run.
    integer k;
    real line;                                             // amplitude of the line at the landing frequency
    // Droop of the two CIC stages that are not in this bench, at frequency f: the fixed CIC (9 stages,
    // decimation 10, at 76.8 MHz) and cic_var_pow2 (11 stages, decimation 64, at 7.68 MHz), each stage having the
    // magnitude sin(pi f R / fs) / (R sin(pi f / fs)).
    function real droop_db(input real f);                  // of the fixed CIC (9 stages, 10) and cic_var_pow2 (11, 64)
        real h1, h2;
        begin
            h1 = (f < 1.0) ? 1.0 : $sin(PI * f * 10.0 / 76.8e6) / (10.0 * $sin(PI * f / 76.8e6));
            h2 = (f < 1.0) ? 1.0 : $sin(PI * f * 64.0 / 7.68e6) / (64.0 * $sin(PI * f / 7.68e6));
            droop_db = 20.0 * $log10($pow(h1, 9.0) * $pow(h2, 11.0));
        end
    endfunction
    // Runs one complex tone of frequency f_hz and amplitude amp through the chain at narrow shift nsh and gain g
    // and returns the peak output magnitude (and, in `line`, the amplitude at the landing frequency). The output
    // rate is FIN / (2 << nsh), and the tone is folded to the frequency it lands on at that rate.
    task run_tone(input integer nsh, input integer g, input real f_hz, input real amp, output real mag);
        real w, fo_t, fl, a_p, a_n;
        integer n_in;
        begin
            fo_t = FIN / (2 << nsh);
            fl = f_hz - $floor(f_hz / fo_t + 0.5) * fo_t;
            w_land = 2.0 * PI * fl / fo_t;
            cr_p = 0.0; ci_p = 0.0; cr_n = 0.0; ci_n = 0.0;
            rst = 1'b1; nshift = nsh; ngain = g; in_strobe = 1'b0;
            repeat (80) @(posedge clock);
            n_out = 0; peak = 0.0;
            rst = 1'b0;
            repeat (8) @(posedge clock);
            // The tone, one sample per GAP clocks, rounded to integers, I as cosine and Q as sine.
            w = 2.0 * PI * f_hz / FIN;
            n_in = POINTS * (2 << nsh);
            for (k = 0; k < n_in; k = k + 1) begin
                in_i <= $rtoi(amp * $cos(w * k) + ((amp * $cos(w * k) >= 0.0) ? 0.5 : -0.5));
                in_q <= $rtoi(amp * $sin(w * k) + ((amp * $sin(w * k) >= 0.0) ? 0.5 : -0.5));
                in_strobe <= 1'b1;
                @(posedge clock);
                in_strobe <= 1'b0;
                repeat (GAP - 1) @(posedge clock);
            end
            mag = peak;
            a_p = $sqrt(cr_p * cr_p + ci_p * ci_p) / (n_out - SKIP);
            a_n = $sqrt(cr_n * cr_n + ci_n * ci_n) / (n_out - SKIP);
            line = (a_p > a_n) ? a_p : a_n;
        end
    endtask

    // The worst alias frequency of the narrow spans, from the generated configuration file.
    real f_alias [1:4];
    real fo, mag, db, worst_flat, worst_rej;
    integer n, t, errors;
    initial begin
        f_alias[1] = ZOOM_ALIAS_INTERFERER_7_HZ;  f_alias[2] = ZOOM_ALIAS_INTERFERER_8_HZ;
        f_alias[3] = ZOOM_ALIAS_INTERFERER_9_HZ;  f_alias[4] = ZOOM_ALIAS_INTERFERER_10_HZ;
        errors = 0; worst_flat = 0.0; worst_rej = 1.0e9;
        // For every narrow span (just the first one with +dbg): flatness, alias rejection and gain.
        for (n = 1; n <= ($test$plusargs("dbg") ? 1 : 4); n = n + 1) begin
            fo = FIN / (2 << n);                                   // the rate into the FFT
            // Flatness at 2 %, 20 % and 39 % of the output rate.
            for (t = 0; t < 3; t = t + 1) begin
                run_tone(n, 0, fo * ((t == 0) ? 0.02 : (t == 1) ? 0.20 : 0.39), AMP, mag);
                db = 20.0 * $log10(mag / AMP) + droop_db(fo * ((t == 0) ? 0.02 : (t == 1) ? 0.20 : 0.39));
                if (db > worst_flat || -db > worst_flat) worst_flat = (db > 0.0) ? db : -db;
                $display("span %5.1f kHz  tone at %2d %% of the rate: %8.4f dB", 0.8 * fo / 1000.0, (t == 0) ? 2 : (t == 1) ? 20 : 39, db);
                if (db > 0.03 || db < -0.03) begin errors = errors + 1; $display("FAIL: not flat"); end
            end
            // Alias rejection: the worst frequency of the chain, and the nearest alias band of zoom_cic_narrow
            // (twice the output rate less 30 % of it, since the narrow CIC output rate is twice the final rate).
            for (t = 0; t < 2; t = t + 1) begin
                run_tone(n, 0, (t == 0) ? f_alias[n] : (2.0 * fo - 0.3 * fo), AMP, mag);
                db = 20.0 * $log10(AMP / ((line < 0.01) ? 0.01 : line));
                if (db < worst_rej) worst_rej = db;
                $display("span %5.1f kHz  full-scale tone at %9.1f Hz: line %6.3f steps, rejection %6.1f dB; largest word %4.2f steps", 0.8 * fo / 1000.0,
                         (t == 0) ? f_alias[n] : (2.0 * fo - 0.3 * fo), line, db, mag);
                if (db < 80.0) begin errors = errors + 1; $display("FAIL: under 80 dB"); end
            end
            // Gain: 30 dB under full scale (1 / 31.6228) with narrow_gain 2, expected 20 x log10(16) = 24.082 dB.
            run_tone(n, 2, fo * 0.20, AMP / 31.6228, mag);
            db = 20.0 * $log10(mag / (AMP / 31.6228)) + droop_db(fo * 0.20);
            $display("span %5.1f kHz  narrow_gain 2: %8.3f dB (24.082)", 0.8 * fo / 1000.0, db);
            if (db > 24.082 + 0.05 || db < 24.082 - 0.05) begin errors = errors + 1; $display("FAIL: gain"); end
        end
        $display("worst flatness error %.4f dB, worst rejection %.1f dB", worst_flat, worst_rej);
        if (errors == 0) $display("PASS");
        else $display("FAIL: %0d error(s)", errors);
        $finish;
    end
endmodule
