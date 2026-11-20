// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Shared body of the done-test for rtl/spectrum/spectrum_pipeline.v, the full-band spectrum pipeline: a
// window, a 16,384-point FFT, the power of every bin, a reduction of the bins to 1,920 screen columns
// (maximum or mean), an average over K FFT frames (or peak hold), the conversion to dB, and a line buffer
// that the CPU and the waterfall read (see docs/F2_SPECTRUM.md and docs/learn/GLOSSARY.md). It is
// included by two top files that differ only in K, the number of frames averaged into one line:
//
//   sim/spectrum/tb_spectrum_pipeline.v        K = 2, run by tools/check.sh (well under a minute)
//   sim/spectrum/spectrum_noise_full_k156.v    K = 156, the specified number, run by
//                                              tools/spectrum_k156.sh (several minutes)
//
// The including file defines SPECTRUM_DT_MODULE (the module name) and SPECTRUM_DT_K before it includes this
// file, which is not named tb_*.v so that tools/check.sh does not try to run it on its own. The pass line
// is "PASS", otherwise FAIL lines say which check failed.
//
// Stimulus: one continuous stream, one sample per clock, of a -6 dBFS tone exactly on bin 1,520 (7.125 MHz
// at the 76.8 MHz sample rate, since 1,520 * 76.8e6 / 16,384 = 7.125 MHz; an exact bin means there is no
// scalloping loss to model) plus Gaussian noise with a standard deviation of 4 ADC LSB. The column mode is
// mean and peak hold is off. The first completed line (FFT output frames 0 to K-1) is read back through
// the line buffer port and checked five ways:
//
//   1. The peak is in the tone's column (456).
//   2. The tone level is within 0.5 dB of the closed form.
//   3. Every one of the 1,920 columns is a defined value (no X) and equals, within 0.03 dB, an independent
//      model of everything after the FFT. The bench taps the FFT output (out_index, out_re, out_im) and
//      itself does the rounding shift, the power, the bin to column mapping, the sum over each column's
//      bins and the K frames, and 10 * log10(sum / (K * bins)). This is the check that pins a fault in the
//      column reduction, the K-frame accumulator, the log-domain K-average or the line buffer to the exact
//      column, whatever the noise statistics do. The RTL (rtl/spectrum/spectrum_ratio_db.v) computes
//      10 * log10(sum) - 10 * log10(K * bins) directly in the log domain, with no integer quotient in
//      between, so the model divides as real numbers too; a model that rounded the quotient to an integer
//      first would disagree with the RTL by more than the tolerance in the columns with small sums, where
//      half a count is a large part of the value.
//   4. Noise floor level: the mean linear power of the noise-only columns against the closed form
//      sigma^2 * sum(w^2) * 64 / 2^16 + 2/12, where the last term is the rounding of re and im to the
//      power stage's LSB. sigma^2 is measured from the samples actually fed in (the tone's own rounding
//      included). Linear and not dB, because the mean of dB values is biased low by an amount that depends
//      on K and the mean of linear values is not, so this check means the same at any K.
//   5. Noise floor spread: the coefficient of variation (standard deviation over mean, linear) across the
//      noise-only columns, separately for 3-bin and 4-bin columns, against the exact theory for averaging
//      correlated exponential variables: CV^2 = sum over i,j of |rho(i-j)|^2 / (m^2 K), with
//      rho(d) = |sum w^2 e^(-j 2 pi d n / N)| / sum w^2. The window makes neighbouring bins correlated, so a
//      column of m bins is worth less than m independent samples. For K >= 32 the standard deviation in dB
//      is checked too, against 10 / ln(10) * CV.
//
// Register writes wait 1 ns after the clock edge, and every tap of a DUT signal samples on the falling
// edge, so that the bench never races the DUT's own clocked logic (docs/F2_SPECTRUM.md "Testbench notes").

`timescale 1ns / 1ps
`include "rtl/spectrum/spectrum_pipeline.v"

module `SPECTRUM_DT_MODULE;

    // N is the FFT size, K the number of averaged frames, NUM_BINS the 6,400 bins that are kept (0 to
    // 30 MHz) and NUM_COLS the 1,920 columns on screen (6,400 * 3 / 10, so 3 or 4 bins per column).
    // RSH is the right shift the power stage applies to re and im before squaring.
    localparam integer N   = 16384;
    localparam integer K   = `SPECTRUM_DT_K;
    localparam integer NUM_BINS = 6400;
    localparam integer NUM_COLS = 1920;
    localparam real    PI  = 3.14159265358979323846;
    localparam real    RSH_SCALE = 256.0;   // 2^RSH, RSH = 8 in rtl/spectrum/spectrum_pipeline.v
    localparam integer RSH = 8;

    // ---- stimulus parameters ----
    // Tone level, bin, and the column that bin falls in (1,520 * 3 / 10 = 456, with the 4 bins 1,520 to
    // 1,523 mapped to it); TONE_GUARD columns on each side of it are left out of the noise statistics.
    localparam real    TONE_DBFS   = -6.0;
    localparam integer TONE_BIN    = 1520;           // 1520 * 76.8e6/16384 = 7.125 MHz, exact bin
    localparam integer TONE_COL    = 456;             // floor(1520*3/10)
    localparam integer TONE_NBINS  = 4;               // bins mapped to column 456
    localparam integer TONE_GUARD  = 10;              // columns either side left out of the noise stats
    // Mean mode sums the whole column, and the main lobe of the window puts real power into the other 3
    // bins of the tone's column, so the column holds more than the tone bin alone. MAIN_LOBE_SUM_RATIO is
    // sum(|X[1520..1523]|^2) / |X[1520]|^2 for this window and an exact-bin tone.
    localparam real MAIN_LOBE_SUM_RATIO = 1.5021764691085198;

    // ---- pass limits ----
    localparam real TONE_TOL_DB  = 0.5;               // PLAN's own number
    // Check 3 tolerance. The RTL runs its log2 lookup table twice per column, once for the K-frame sum and
    // once for K times the bin count, so the two lookups' own quantization errors (each up to 0.0007 dB,
    // as reported by tools/gen_spectrum_tables.py) can add up. The worst case measured at K = 156, which is
    // the widest dynamic range this test exercises, is 0.026 dB, so 0.03 dB leaves real margin above it.
    localparam real MODEL_TOL_DB = 0.03;
    localparam real CV_TOL       = 0.15;              // check 5: relative, about 4-5 standard errors at K = 2

    reg clk = 1'b0;
    always #3.333 clk = ~clk;                          // 150 MHz, clk_dsp
    reg rst = 1'b1;

    // ADC input, register port, line buffer read port and waterfall output of the full-band side.
    reg  signed [11:0] adc_data = 12'sd0;
    reg                adc_valid = 1'b0;
    reg                reg_wr = 1'b0, reg_rd = 1'b0;
    reg  [15:0]        reg_addr = 16'h0;
    reg  [31:0]        reg_wdata = 32'h0;
    wire [31:0]        reg_rdata;
    wire               irq_line_done;
    reg  [10:0]        line_rd_addr = 11'd0;
    wire [15:0]        line_rd_data;
    wire               wf_valid, wf_sol, wf_eol;
    wire [7:0]         wf_data;

    // The DUT also hosts the zoom spectrum backend, which shares the column-walk engine with the
    // full-band side. This test only exercises the full-band side, so the zoom input stream is tied idle,
    // no zoom frame ever completes, and the walk engine serves only this bench's own requests. The zoom
    // side has its own equivalent of this file in sim/zoom/zoom_backend_done_test.vh.
    wire               zoom_in_valid = 1'b0, zoom_in_first = 1'b0, zoom_in_usable = 1'b0;
    wire [11:0]        zoom_in_bin = 12'd0;
    wire signed [28:0] zoom_in_re = 29'sd0, zoom_in_im = 29'sd0;
    wire               zreg_wr = 1'b0, zreg_rd = 1'b0;
    wire [15:0]        zreg_addr = 16'h0;
    wire [31:0]        zreg_wdata = 32'h0;
    wire [31:0]        zreg_rdata;
    wire               zirq_line_done;
    wire [10:0]        zline_rd_addr = 11'd0;
    wire [15:0]        zline_rd_data;
    wire               zwf_valid, zwf_sol, zwf_eol;
    wire [7:0]         zwf_data;

    spectrum_pipeline dut (
        .clk(clk), .rst(rst), .adc_data(adc_data), .adc_valid(adc_valid),
        .reg_wr(reg_wr), .reg_rd(reg_rd), .reg_addr(reg_addr), .reg_wdata(reg_wdata),
        .reg_rdata(reg_rdata), .irq_line_done(irq_line_done),
        .line_rd_addr(line_rd_addr), .line_rd_data(line_rd_data),
        .wf_valid(wf_valid), .wf_sol(wf_sol), .wf_eol(wf_eol), .wf_data(wf_data),
        .zoom_in_valid(zoom_in_valid), .zoom_in_first(zoom_in_first), .zoom_in_bin(zoom_in_bin),
        .zoom_in_usable(zoom_in_usable), .zoom_in_re(zoom_in_re), .zoom_in_im(zoom_in_im),
        .zreg_wr(zreg_wr), .zreg_rd(zreg_rd), .zreg_addr(zreg_addr), .zreg_wdata(zreg_wdata),
        .zreg_rdata(zreg_rdata), .zirq_line_done(zirq_line_done),
        .zline_rd_addr(zline_rd_addr), .zline_rd_data(zline_rd_data),
        .zwf_valid(zwf_valid), .zwf_sol(zwf_sol), .zwf_eol(zwf_eol), .zwf_data(zwf_data)
    );

    // Register write, one clock wide, driven 1 ns after the clock edge.
    task reg_write(input [15:0] a, input [31:0] d);
        begin
            @(posedge clk); #1; reg_addr = a; reg_wdata = d; reg_wr = 1'b1;
            @(posedge clk); #1; reg_wr = 1'b0;
        end
    endtask

    // Power to dB.
    function real db10(input real p);
        db10 = 10.0 * $log10((p > 1.0e-300) ? p : 1.0e-300);
    endfunction

    // The FFT delivers its bins in bit-reversed order, so output index idx carries bin bitrev14(idx).
    function integer bitrev14(input integer x);
        integer b;
        begin
            bitrev14 = 0;
            for (b = 0; b < 14; b = b + 1) bitrev14 = bitrev14 | (((x >> b) & 1) << (13 - b));
        end
    endfunction

    // ---- window sums and bin-to-bin correlation (ideal 4-term Blackman-Harris) ----
    // wsum is the sum of the window w, wsum2 the sum of w^2, and rho2[d] is |rho(d)|^2, the squared
    // correlation of two bins d apart (see check 5). The coefficients are those of the 4-term
    // Blackman-Harris window that rtl/spectrum/spectrum_window.v implements.
    real wsum, wsum2, rho_re, rho_im, w_n;
    real rho2 [0:3];                                   // |rho(d)|^2, d = 0..3
    integer i, d;
    initial begin
        wsum = 0.0; wsum2 = 0.0;
        for (i = 0; i < N; i = i + 1) begin
            w_n = 0.35875 - 0.48829 * $cos(2.0*PI*i/N) + 0.14128 * $cos(4.0*PI*i/N)
                  - 0.01168 * $cos(6.0*PI*i/N);
            wsum  = wsum  + w_n;
            wsum2 = wsum2 + w_n*w_n;
        end
        for (d = 0; d < 4; d = d + 1) begin
            rho_re = 0.0; rho_im = 0.0;
            for (i = 0; i < N; i = i + 1) begin
                w_n = 0.35875 - 0.48829 * $cos(2.0*PI*i/N) + 0.14128 * $cos(4.0*PI*i/N)
                      - 0.01168 * $cos(6.0*PI*i/N);
                rho_re = rho_re + w_n*w_n*$cos(2.0*PI*d*i/N);
                rho_im = rho_im + w_n*w_n*$sin(2.0*PI*d*i/N);
            end
            rho2[d] = (rho_re*rho_re + rho_im*rho_im) / (wsum2*wsum2);
        end
    end

    // ---- stimulus: tone + noise, one continuous stream ----
    // MARGIN: the FFT's output frame f comes out while input frame f + 1 goes in (docs/F1_FFT.md), so the
    // last frame of the group is only fully out once almost another whole frame (N samples) has been fed
    // after it. N plus a small allowance for the window, FFT and power latency is enough, because the walk
    // that follows is clocked and not paced by the input.
    localparam integer MARGIN  = N + 616;
    localparam integer TOTAL   = K*N + MARGIN;
    real amp, ph, tone_s, noise_sq_sum, sigma2;
    integer seed_n = 12345;
    integer samp;
    integer c;

    initial begin
        noise_sq_sum = 0.0;
        repeat (5) @(posedge clk); rst = 1'b0;
        repeat (5) @(posedge clk);
        reg_write(16'h0008, K[31:0]);                  // averaging_k
        reg_write(16'h0004, 32'h0000_0003);             // enable=1, column_mode=mean(1), peak_hold=0

        // The tone amplitude is 2047 * 10^(-6/20), which is -6 dBFS of the 12-bit range, and the phase
        // advances by 2 pi * 1520 / N per clock so that exactly 1,520 periods fit into one frame.
        amp = 2047.0 * $pow(10.0, TONE_DBFS/20.0);
        ph  = 2.0*PI*TONE_BIN/N;
        $display("%m: tone amp=%.1f (%.1f dBFS) bin=%0d col=%0d, noise sigma=4, K=%0d",
                  amp, TONE_DBFS, TONE_BIN, TONE_COL, K);
        // One sample per clock: the tone plus Gaussian noise of sigma 4, rounded and clipped to 12 bits.
        // noise_sq_sum adds up (sample - tone)^2 over the K frames that make the first line, which gives
        // the noise power that was really fed in, quantization included.
        for (i = 0; i < TOTAL; i = i + 1) begin
            @(posedge clk);
            tone_s = amp*$cos(ph*i);
            samp = $rtoi($floor(tone_s + $itor($dist_normal(seed_n, 0, 4)) + 0.5));
            if (samp > 2047)  samp = 2047;
            if (samp < -2048) samp = -2048;
            if (i < K*N) noise_sq_sum = noise_sq_sum + ($itor(samp) - tone_s)*($itor(samp) - tone_s);
            adc_data  <= samp[11:0];
            adc_valid <= 1'b1;
        end
        @(posedge clk); adc_valid <= 1'b0;
    end

    // ---- independent model of everything after the FFT (check 3) ----
    // Independent model of the power stage and column reduction: ref_sum[c] collects the power of every
    // bin that maps to column c over the K frames, ref_bins[c] counts the bins of the column.
    reg [63:0] ref_sum  [0:NUM_COLS-1];
    integer    ref_bins [0:NUM_COLS-1];
    integer    ref_frame = 0;
    integer    t_idx, t_bin, t_col;
    reg signed [63:0] t_re, t_im;
    initial begin
        for (c = 0; c < NUM_COLS; c = c + 1) begin ref_sum[c] = 64'd0; ref_bins[c] = 0; end
        for (c = 0; c < NUM_BINS; c = c + 1) ref_bins[(c*3)/10] = ref_bins[(c*3)/10] + 1;
    end
    // Tap the FFT output on the falling edge for the first K frames: bit-reverse the index to get the bin,
    // keep the 6,400 bins in use, round and shift re and im, and add the power to the bin's column.
    always @(negedge clk) begin
        if (dut.fft_valid && ref_frame < K) begin
            t_idx = dut.fft_index;
            t_bin = bitrev14(t_idx);
            if (t_bin < NUM_BINS) begin
                // round half up at 2^RSH, the power stage's documented rounding (no saturation
                // needed at these levels: |component| stays far below 2^20)
                t_re = ($signed(dut.fft_re) + (64'sd1 <<< (RSH-1))) >>> RSH;
                t_im = ($signed(dut.fft_im) + (64'sd1 <<< (RSH-1))) >>> RSH;
                t_col = (t_bin*3)/10;
                ref_sum[t_col] = ref_sum[t_col] + t_re*t_re + t_im*t_im;
            end
            if (t_idx == N-1) ref_frame = ref_frame + 1;
        end
    end

    // ---- wait for the first completed line, then read the line buffer ----
    real db_val [0:NUM_COLS-1];
    real lin, ref_db, max_model_err, tone_theory, noise_theory, peak_val;
    real sum_lin[3:4], sum_lin2[3:4], mean_lin_m[3:4], cv_m[3:4], cv_th[3:4];
    real sum_all, sum_db, sum_db2, mean_all, mean_db, sd_db, cv_pool_th, sd_db_th;
    integer n_m[3:4], n_all, m;
    reg [63:0] div_k;
    integer peak_col, n_x, n_model_bad, worst_col;
    integer errors;

    initial begin
        errors = 0;
        // Wait for the first finished line, then read all 1,920 columns back through the line buffer.
        wait (dut.line_count_reg == 32'd1);
        $display("%m: line 1 complete at t=%0t", $time);
        repeat (3) @(posedge clk);
        n_x = 0; n_model_bad = 0; max_model_err = 0.0; worst_col = -1;
        for (c = 0; c < NUM_COLS; c = c + 1) begin
            @(posedge clk); #1; line_rd_addr = c[10:0];
            @(posedge clk); #1;                          // 1-cycle registered read
            if (^line_rd_data === 1'bx) begin
                n_x = n_x + 1;
                db_val[c] = -512.0;
            end else begin
                db_val[c] = $itor($signed(line_rd_data)) / 64.0;
            end
            // Model value: the RTL computes 10 * log10(sum) - 10 * log10(K * bins) directly in the log
            // domain, so the model does the same real-valued division (see the header, check 3).
            div_k = K * ref_bins[c];
            // $itor takes a 32-bit integer in Icarus, so the 64-bit sum passed directly would silently
            // lose its upper half; the tone's own column is the one sum large enough to exceed 2^32, and it
            // would read about 14.7 dB too high. The real value is rebuilt from both halves instead.
            lin = ($itor(ref_sum[c][31:0]) + $itor(ref_sum[c][63:32]) * 4294967296.0)
                  / $itor(div_k[31:0]);
            ref_db = (ref_sum[c] == 0) ? -512.0 : db10(lin);
            if ((db_val[c] - ref_db > max_model_err) || (ref_db - db_val[c] > max_model_err)) begin
                max_model_err = (db_val[c] > ref_db) ? db_val[c] - ref_db : ref_db - db_val[c];
                worst_col = c;
            end
            if ((db_val[c] - ref_db > MODEL_TOL_DB) || (ref_db - db_val[c] > MODEL_TOL_DB)) begin
                if (n_model_bad < 5)
                    $display("  column %0d: line %.3f dB, model %.3f dB", c, db_val[c], ref_db);
                n_model_bad = n_model_bad + 1;
            end
        end

        // ---- theory ----
        // The tone column holds the mean over its 4 bins. The window scales the FFT output by 8 (64 in
        // power), and a real tone of peak amp gives a bin of amp * wsum / 2, so the bin amplitude is
        // 4 * amp * wsum after the shift by RSH; MAIN_LOBE_SUM_RATIO adds the other 3 bins' power and the
        // division by TONE_NBINS takes the mean. The noise floor is the closed form of check 4. The cv_th
        // values are check 5's formula written out for m = 3 and m = 4 bins.
        sigma2 = noise_sq_sum / (K*N);
        tone_theory  = db10((4.0*amp*wsum/RSH_SCALE)*(4.0*amp*wsum/RSH_SCALE) * MAIN_LOBE_SUM_RATIO / TONE_NBINS);
        noise_theory = sigma2*wsum2*64.0/(RSH_SCALE*RSH_SCALE) + 2.0/12.0;
        cv_th[3] = $sqrt((3.0 + 4.0*rho2[1] + 2.0*rho2[2]) / (9.0*K));
        cv_th[4] = $sqrt((4.0 + 6.0*rho2[1] + 4.0*rho2[2] + 2.0*rho2[3]) / (16.0*K));

        peak_val = -1.0e300; peak_col = -1;
        for (c = 0; c < NUM_COLS; c = c + 1)
            if (db_val[c] > peak_val) begin peak_val = db_val[c]; peak_col = c; end

        // ---- noise-only columns: skip column 0 (DC bin is real-only) and the tone's neighbourhood ----
        // Accumulate the linear power per column width (3 or 4 bins) and over all, and the dB values, for
        // the level and the two kinds of spread.
        for (m = 3; m <= 4; m = m + 1) begin sum_lin[m] = 0.0; sum_lin2[m] = 0.0; n_m[m] = 0; end
        sum_all = 0.0; n_all = 0; sum_db = 0.0; sum_db2 = 0.0;
        for (c = 1; c < NUM_COLS; c = c + 1)
            if (c < TONE_COL - TONE_GUARD || c > TONE_COL + TONE_GUARD) begin
                lin = $pow(10.0, db_val[c]/10.0);
                m = ref_bins[c];
                sum_lin[m] = sum_lin[m] + lin; sum_lin2[m] = sum_lin2[m] + lin*lin; n_m[m] = n_m[m] + 1;
                sum_all = sum_all + lin; n_all = n_all + 1;
                sum_db = sum_db + db_val[c]; sum_db2 = sum_db2 + db_val[c]*db_val[c];
            end
        mean_all = sum_all / n_all;
        for (m = 3; m <= 4; m = m + 1) begin
            mean_lin_m[m] = sum_lin[m] / n_m[m];
            cv_m[m] = $sqrt(sum_lin2[m]/n_m[m] - mean_lin_m[m]*mean_lin_m[m]) / mean_lin_m[m];
        end
        mean_db = sum_db / n_all;
        sd_db = $sqrt(sum_db2/n_all - mean_db*mean_db);
        cv_pool_th = $sqrt((n_m[3]*cv_th[3]*cv_th[3] + n_m[4]*cv_th[4]*cv_th[4]) / (n_m[3] + n_m[4]));
        sd_db_th = 10.0/$ln(10.0) * cv_pool_th;

        $display("peak column %0d (expected %0d), level %.3f dB (theory %.3f dB, diff %.3f dB)",
                  peak_col, TONE_COL, peak_val, tone_theory, peak_val - tone_theory);
        $display("model check: %0d X columns, %0d columns off by more than %.2f dB, worst %.4f dB (column %0d)",
                  n_x, n_model_bad, MODEL_TOL_DB, max_model_err, worst_col);
        $display("noise floor over %0d columns (input sigma^2 %.3f): linear mean %.3f dB (theory %.3f dB, diff %.3f dB)",
                  n_all, sigma2, db10(mean_all), db10(noise_theory), db10(mean_all) - db10(noise_theory));
        $display("noise spread: CV 3-bin %.4f (theory %.4f), 4-bin %.4f (theory %.4f); dB std dev %.3f dB (theory %.3f dB), mean of dB %.3f",
                  cv_m[3], cv_th[3], cv_m[4], cv_th[4], sd_db, sd_db_th, mean_db);

        if (peak_col != TONE_COL) begin
            $display("FAIL: peak in column %0d, expected %0d", peak_col, TONE_COL); errors = errors + 1;
        end
        if ((peak_val - tone_theory > TONE_TOL_DB) || (tone_theory - peak_val > TONE_TOL_DB)) begin
            $display("FAIL: tone level %.3f dB outside +/- %.1f dB of theory", peak_val, TONE_TOL_DB);
            errors = errors + 1;
        end
        if (n_x != 0 || n_model_bad != 0) begin
            $display("FAIL: line does not match the post-FFT model (%0d X, %0d off)", n_x, n_model_bad);
            errors = errors + 1;
        end
        // Level: 6 standard errors of the mean (from the measured spread) plus 0.05 dB for the small terms
        // that the closed form leaves out (FFT rounding, window quantization).
        if ((db10(mean_all) - db10(noise_theory) > 0.05 + 6.0*4.343*cv_pool_th/$sqrt(n_all)) ||
            (db10(noise_theory) - db10(mean_all) > 0.05 + 6.0*4.343*cv_pool_th/$sqrt(n_all))) begin
            $display("FAIL: noise floor level off theory by more than %.3f dB",
                      0.05 + 6.0*4.343*cv_pool_th/$sqrt(n_all));
            errors = errors + 1;
        end
        for (m = 3; m <= 4; m = m + 1)
            if (cv_m[m] > cv_th[m]*(1.0 + CV_TOL) || cv_m[m] < cv_th[m]*(1.0 - CV_TOL)) begin
                $display("FAIL: %0d-bin column CV %.4f outside +/- %.0f%% of theory %.4f",
                          m, cv_m[m], 100.0*CV_TOL, cv_th[m]);
                errors = errors + 1;
            end
        if (K >= 32 && (sd_db > sd_db_th*(1.0 + CV_TOL) || sd_db < sd_db_th*(1.0 - CV_TOL))) begin
            $display("FAIL: noise floor dB spread %.3f outside +/- %.0f%% of theory %.3f",
                      sd_db, 100.0*CV_TOL, sd_db_th);
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS");
        else $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    // Watchdog: K + 3 frames of clocks (6.667 ns each) with 50 % extra, plus the read-back time.
    initial begin
        #((K + 3) * N * 6.667 * 1.5 + 5_000_000);   // K + margin frames of cycles, plus the readback
        $display("FAIL: timeout");
        $finish;
    end

endmodule
