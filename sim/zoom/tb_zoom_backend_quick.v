// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Fast test of the zoom spectrum's back end, the part of rtl/spectrum/spectrum_pipeline.v that takes the
// 4,096 complex FFT bins of a zoom frame, turns them into power, groups them into the 1,920 screen
// columns, averages K frames in the log domain, converts to dB and writes a line buffer that the video path
// reads. The bench drives the zoom_in_* port of the pipeline directly with a synthetic bin stream, so
// the zoom DDC and the FFT (which tb_zoom_quick.v covers on its own) are left out. A real zoom FFT frame at the
// narrowest span needs 4,096 x 1,280 = 5,242,880 ADC clocks, and the test with the real DDC and FFT,
// sim/zoom/zoom_backend_full_sim.v (run by tools/zoom_backend_full_sim.sh, tens of minutes, not part of
// tools/check.sh), takes that long; injecting the bin values directly tests the same hardware (the shared
// walk engine that does the arithmetic for both spectrum streams, the log-domain K-average, the tables
// that map bins to columns, and the single buffer with the arrival FIFO in front) in milliseconds.
//
// Stimulus: K = 3 frames of 4,096 words in the bit-reversed order the FFT delivers them. Bin 68 (an
// arbitrary usable bin, the same one that sim/zoom/zoom_bin48_sim.v expects for a 1 kHz tone at the 48 kHz
// span) gets a fixed "tone" value of 200,000 on the real part in every frame, and every other usable bin gets
// an independent Gaussian value on each of its real and imaginary parts, new in every frame, with sigma =
// 2,000, so that the averaging over frames has something to average. These are bin values and not the
// output of a real window, so neighbouring bins are independent, and the noise statistics below are
// the simple case of independent bins. The register bus selects K and the column mode "mean" (the average of
// the power of the bins of a column); with -DZOOM_FT8_COLS the control word also selects the FT8 column
// scale, which spreads the bins over more columns, and every check stays the same.
//
// Checks, after the pipeline has finished the first line and its dB values have been read back:
//   1. The peak of the line is in the tone's column.
//   2. Every column is within 0.02 dB of an independent model in this bench that applies the same rounding
//      shift, power and column sum to the same injected values and takes the exact 10 x log10 of the mean, and
//      none of them contains an unknown (x) value. This also covers the tone's level, which is just one
//      more column that the model predicts.
//   3. The noise floor, the linear mean of the power over all columns other than the tone's, is within 0.3
//      dB of the theory for independent bins: each bin holds 2 x (sigma / 256)^2 plus the rounding noise.
//   4. The spread of the noise, the coefficient of variation (CV, standard deviation divided by mean) of the
//      power over the columns, is within 20 % of the theory. A column of m independent bins averaged over
//      K frames has a power with CV = 1 / sqrt(m x K), because the power of a complex Gaussian value
//      has a CV of 1 (it is exponentially distributed), and columns hold 1 or 2 bins, so the theory is
//      pooled over the columns.
// The bench prints the figures and ends with PASS, or FAIL with the number of failed checks.
//
// Run from the repository root (tools/check.sh runs it too):
//   iverilog -g2012 -o build/tb_zoom_backend_quick.vvp sim/zoom/tb_zoom_backend_quick.v && vvp build/tb_zoom_backend_quick.vvp
//   (add -DZOOM_FT8_COLS to the iverilog line for the FT8 column scale)

`timescale 1ns / 1ps
`include "rtl/spectrum/spectrum_pipeline.v"

module tb_zoom_backend_quick;

    // Zoom FFT geometry: 4,096 bins, of which the central 80 % are usable, bin 0 and 1,638 (0.4 x 4,096,
    // rounded down) on each side of it, 3,277 bins in all, over 1,920 screen columns.
    localparam integer ZLOG_N        = 12;
    localparam integer ZN            = 1 << ZLOG_N;       // 4096
    localparam integer Z_USABLE_HALF = 1638;
    localparam integer Z_NUM_COLS    = 1920;
    // The column of a bin is (position in the usable range x multiplier) >> 20. 614363 / 2^20 = 1,920 / 3,277
    // spreads the whole displayed span over the 1,920 columns. 750080 / 2^20 = 0.71533 is the scale of the
    // FT8 screen (1,172 columns = 3,000 Hz at the 6 kHz span), and bins that land beyond column 1,919 are
    // dropped by the RTL and fall outside the model's arrays. The control word 0x10 sets backend_column_mode
    // (bit 4) to the mean, and 0x810 also sets backend_ft8_columns (bit 11).
`ifdef ZOOM_FT8_COLS
    localparam integer Z_COL_MULT    = 750080;
    localparam [31:0]  CTRL_WORD     = 32'h0000_0810;
`else
    localparam integer Z_COL_MULT    = 614363;
    localparam [31:0]  CTRL_WORD     = 32'h0000_0010;
`endif
    localparam integer Z_COL_SHIFT   = 20;
    localparam integer Z_NUM_BINS    = 2 * Z_USABLE_HALF + 1;   // 3277
    // RSH: the RTL shifts every bin value right by 8 bits (with rounding) before it squares them, to keep the
    // power word narrow.
    localparam integer RSH           = 8;

    // K frames are averaged, the tone sits in bin 68, and the tone and the noise have the sizes below
    // (the bin values are 29-bit, so these are well inside the range).
    localparam integer K          = 3;
    localparam integer TONE_BIN   = 68;      // matches sim/zoom/zoom_bin48_sim.v's expected bin
    localparam real    TONE_RE    = 200000.0;
    localparam real    SIGMA      = 2000.0;  // injected per-component noise, pre-RSH-rounding

    // Bit reversal of a 12-bit index: the FFT delivers its bins in this order, so the bench does too.
    function integer bitrev12(input integer x);
        integer b;
        begin
            bitrev12 = 0;
            for (b = 0; b < 12; b = b + 1) bitrev12 = bitrev12 | (((x >> b) & 1) << (11 - b));
        end
    endfunction

    // Position of a bin counted from the low edge of the usable range (the bins of the upper end of the
    // FFT output, the negative frequencies, come first), 0 to 3,276.
    function integer zrel_of(input integer bin);
        begin
            if (bin <= Z_USABLE_HALF) zrel_of = bin + Z_USABLE_HALF;
            else                      zrel_of = bin - (ZN - Z_USABLE_HALF);
        end
    endfunction

    // Column of a position, with the multiplier of the RTL's table.
    function integer zcol_of_rel(input integer rel);
        reg [63:0] p;
        begin
            p = rel * Z_COL_MULT;
            zcol_of_rel = p >> Z_COL_SHIFT;
        end
    endfunction

    // 150 MHz (half period 3.333 ns) where the chip runs at 120 MHz, which makes no difference because only
    // the number of clocks matters here.
    reg clk = 1'b0;
    always #3.333 clk = ~clk;
    reg rst = 1'b1;

    // The full-band side of the pipeline is not used and its inputs stay quiet.
    reg  signed [11:0] adc_data = 12'sd0;
    wire               adc_valid = 1'b0;
    wire               reg_wr = 1'b0, reg_rd = 1'b0;
    wire [15:0]        reg_addr = 16'h0;
    wire [31:0]        reg_wdata = 32'h0;
    wire [31:0]        reg_rdata;
    wire               irq_line_done;
    wire [10:0]        line_rd_addr = 11'd0;
    wire [15:0]        line_rd_data;
    wire               wf_valid, wf_sol, wf_eol;
    wire [7:0]         wf_data;

    // The zoom side: the bin stream (29 bits, the width of the 17-bit window output plus 12 bits of FFT growth),
    // the register bus (a write takes one clock), the line buffer read port and the waterfall outputs.
    reg                zoom_in_valid = 1'b0, zoom_in_first = 1'b0, zoom_in_usable = 1'b0;
    reg  [11:0]        zoom_in_bin = 12'd0;
    reg  signed [28:0] zoom_in_re = 29'sd0, zoom_in_im = 29'sd0;
    reg                zreg_wr = 1'b0, zreg_rd = 1'b0;
    reg  [15:0]        zreg_addr = 16'h0;
    reg  [31:0]        zreg_wdata = 32'h0;
    wire [31:0]        zreg_rdata;
    wire               zirq_line_done;
    reg  [10:0]        zline_rd_addr = 11'd0;
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

    // One write on the zoom register bus.
    task zreg_write(input [15:0] a, input [31:0] d);
        begin
            @(posedge clk); #1; zreg_addr = a; zreg_wdata = d; zreg_wr = 1'b1;
            @(posedge clk); #1; zreg_wr = 1'b0;
        end
    endtask

    // Power in dB, with a floor so that the logarithm of zero is finite.
    function real db10(input real p);
        db10 = 10.0 * $log10((p > 1.0e-300) ? p : 1.0e-300);
    endfunction

    // ---- independent model: same rounding, power and column-sum as the RTL does ----
    // ref_sum is the sum of the power terms in each column over all K frames, ref_bins the number of bins in
    // each column.
    reg [63:0] ref_sum  [0:Z_NUM_COLS-1];
    integer    ref_bins [0:Z_NUM_COLS-1];
    integer    c, f, idx, bin, rel, col, seed_n;
    real       re_f, im_f;
    integer    re_i, im_i, term;

    // Initial block 1: fills ref_bins by mapping every usable bin to its column (once, since the
    // mapping does not change) and checks that the tone's column has at least one bin.
    initial begin
        seed_n = 424242;
        for (c = 0; c < Z_NUM_COLS; c = c + 1) begin ref_sum[c] = 64'd0; ref_bins[c] = 0; end
        for (bin = 0; bin <= Z_USABLE_HALF; bin = bin + 1) begin
            rel = zrel_of(bin); col = zcol_of_rel(rel); ref_bins[col] = ref_bins[col] + 1;
        end
        for (bin = ZN - Z_USABLE_HALF; bin < ZN; bin = bin + 1) begin
            rel = zrel_of(bin); col = zcol_of_rel(rel); ref_bins[col] = ref_bins[col] + 1;
        end
        if (ref_bins[zcol_of_rel(zrel_of(TONE_BIN))] < 1)
            $display("WARNING: tone column has no bins (should not happen)");
    end

    // Initial block 2: the stimulus. A short reset, then K and the column mode through the register bus.
    initial begin
        repeat (5) @(posedge clk); rst = 1'b0;
        repeat (5) @(posedge clk);
        zreg_write(`ZOOM_BACKEND_AVERAGING_K_ADDR, K[31:0]);
        zreg_write(`ZOOM_CTRL_ADDR, CTRL_WORD);   // backend_column_mode = mean (bit 4)

        // One frame per pass. A real zoom delivers a new bin only once every several tens of clocks (the
        // DDC's own decimated rate), so the walk engine, which is busy for about 1,920 clocks on each
        // walk, only ever sees a handful of this stream's bins arrive while it works, nothing like the
        // 750 or so entries of the full-band side that the arrival FIFO was sized for. Feeding the words of
        // a frame one per clock directly after the previous frame would recreate that dense arrival at a
        // rate the FIFO was never made for, so a gap of 2,200 clocks, longer than the longest walk
        // (about 1,930 clocks), lets the previous frame finish, and inside a frame the bins still come one
        // per clock.
        for (f = 0; f < K; f = f + 1) begin
            if (f > 0) repeat (2200) @(posedge clk);
            // One bin per clock in FFT output order, out_first on the first and the usable flag set for the
            // central 80 %.
            for (idx = 0; idx < ZN; idx = idx + 1) begin
                bin = bitrev12(idx);
                @(posedge clk); #1;
                zoom_in_valid  = 1'b1;
                zoom_in_first  = (idx == 0);
                zoom_in_bin    = bin[11:0];
                zoom_in_usable = (bin <= Z_USABLE_HALF) || (bin >= ZN - Z_USABLE_HALF);
                // The tone bin gets a fixed value, every other usable bin a Gaussian one (mean 0, standard
                // deviation sigma, from the fixed seed so that every run is the same).
                if (zoom_in_usable) begin
                    if (bin == TONE_BIN) begin
                        re_f = TONE_RE; im_f = 0.0;
                    end else begin
                        re_f = $itor($dist_normal(seed_n, 0, $rtoi(SIGMA)));
                        im_f = $itor($dist_normal(seed_n, 0, $rtoi(SIGMA)));
                    end
                    zoom_in_re = $rtoi(re_f);
                    zoom_in_im = $rtoi(im_f);
                    // The model rounds exactly as the RTL does: (s + 128) >>> 8, an arithmetic (sign-extending)
                    // shift, which rounds ties toward plus infinity and not symmetrically away from zero
                    // (s = -128 gives 0, not -1). A real-valued model that rounds half away from zero
                    // would differ from the RTL by one count wherever a sample lands on a tie, which shows
                    // up as columns off by a fraction of a dB when the numbers are small, so the model uses
                    // integer arithmetic throughout.
                    re_i = (zoom_in_re + 29'sd128) >>> 8;
                    im_i = (zoom_in_im + 29'sd128) >>> 8;
                    // Column of this bin.
                    rel = zrel_of(bin); col = zcol_of_rel(rel);
                    // The (never negative) term is worked out in a plain 32-bit integer first and only then
                    // added to the 64-bit unsigned ref_sum, because Icarus Verilog handles an expression that
                    // mixes a signed narrow operand with a wider unsigned one wrongly.
                    // The power of the rounded bin value, summed into its column.
                    term = re_i*re_i + im_i*im_i;
                    ref_sum[col] = ref_sum[col] + term;
                end else begin
                    zoom_in_re = 29'sd0; zoom_in_im = 29'sd0;
                end
            end
        end
        // Stimulus ends: the line is complete when the pipeline says so (see the checker below).
        @(posedge clk); #1; zoom_in_valid = 1'b0;
        $display("%m: stimulus done at t=%0t, tone bin=%0d col=%0d", $time, TONE_BIN,
                  zcol_of_rel(zrel_of(TONE_BIN)));
    end

    // ---- readback and checks ----
    // ---- readback and checks ----
    real db_val [0:Z_NUM_COLS-1];
    real lin, ref_db, max_model_err;
    real sigma2_trunc, noise_theory, sum_all, sum_sq, mean_all, cv_meas, cv_th;
    integer n_all, n_x, n_model_bad, worst_col, peak_col, errors;
    real    peak_val;
    // Tolerances: 0.02 dB against the model per column, and 20 % on the noise spread.
    localparam real MODEL_TOL_DB = 0.02;
    localparam real CV_TOL       = 0.20;

    initial begin
        errors = 0;
        // Wait for the first line, then read every column back from the line buffer (the data is 16-bit
        // signed in units of 1/64 dB, and one read takes two clocks).
        wait (dut.zline_count_reg == 32'd1);
        $display("%m: zoom line 1 complete at t=%0t", $time);
        repeat (3) @(posedge clk);
        n_x = 0; n_model_bad = 0; max_model_err = 0.0; worst_col = -1;
        for (c = 0; c < Z_NUM_COLS; c = c + 1) begin
            @(posedge clk); #1; zline_rd_addr = c[10:0];
            @(posedge clk); #1;
            if (^zline_rd_data === 1'bx) begin
                n_x = n_x + 1; db_val[c] = -512.0;
            end else begin
                db_val[c] = $itor($signed(zline_rd_data)) / 64.0;
            end
            // The model's value for this column: the exact mean power over K frames and the column's bins,
            // in dB (power 0 gives the -512 dB floor of the pipeline).
            lin = ($itor(ref_sum[c][31:0]) + $itor(ref_sum[c][63:32]) * 4294967296.0)
                  / $itor(K * ref_bins[c]);
            ref_db = (ref_sum[c] == 0) ? -512.0 : db10(lin);
            // Track the largest difference to the model, and count the columns that are off by more than the
            // tolerance (the first five are printed).
            if (((db_val[c] - ref_db > max_model_err) || (ref_db - db_val[c] > max_model_err))) begin
                max_model_err = (db_val[c] > ref_db) ? db_val[c] - ref_db : ref_db - db_val[c];
                worst_col = c;
            end
            if ((db_val[c] - ref_db > MODEL_TOL_DB) || (ref_db - db_val[c] > MODEL_TOL_DB)) begin
                if (n_model_bad < 5)
                    $display("  column %0d (%0d bins): line %.3f dB, model %.3f dB", c, ref_bins[c], db_val[c], ref_db);
                n_model_bad = n_model_bad + 1;
            end
        end

        // Check 1: the column of the highest level.
        peak_val = -1.0e300; peak_col = -1;
        for (c = 0; c < Z_NUM_COLS; c = c + 1)
            if (db_val[c] > peak_val) begin peak_val = db_val[c]; peak_col = c; end

        // Noise floor: independent bins without a window, so the mean power per bin after the rounding shift
        // is (sigma / 256)^2 x 2 (real plus imaginary part) plus 2 / 12 for the rounding noise of the two
        // components (a uniform rounding error has a variance of 1/12), which is small here.
        sigma2_trunc = (SIGMA / 256.0) * (SIGMA / 256.0);
        noise_theory = sigma2_trunc * 2.0 + 2.0 * (1.0 / 12.0);
        sum_all = 0.0; sum_sq = 0.0; n_all = 0;
        for (c = 0; c < Z_NUM_COLS; c = c + 1)
            if (c != zcol_of_rel(zrel_of(TONE_BIN))) begin
                lin = $pow(10.0, db_val[c] / 10.0);
                sum_all = sum_all + lin; sum_sq = sum_sq + lin*lin; n_all = n_all + 1;
            end
        mean_all = sum_all / n_all;
        cv_meas = $sqrt(sum_sq / n_all - mean_all*mean_all) / mean_all;
        // Spread: the CV of the power of columns of m = 1 or 2 independent bins averaged over K frames is
        // 1 / sqrt(m x K), and the figures for the columns are pooled as the square root of the mean of
        // 1 / (m x K).
        cv_th = 0.0;
        begin : pool
            real acc; integer nn;
            acc = 0.0; nn = 0;
            for (c = 0; c < Z_NUM_COLS; c = c + 1)
                if (c != zcol_of_rel(zrel_of(TONE_BIN))) begin
                    acc = acc + 1.0 / ($itor(ref_bins[c]) * K);
                    nn = nn + 1;
                end
            cv_th = $sqrt(acc / nn);
        end

        // Report and then the four checks.
        $display("peak column %0d, level %.3f dB", peak_col, peak_val);
        $display("model check: %0d X columns, %0d columns off by more than %.2f dB, worst %.4f dB (column %0d)",
                  n_x, n_model_bad, MODEL_TOL_DB, max_model_err, worst_col);
        $display("noise floor over %0d columns: linear mean %.3f dB (theory %.3f dB, diff %.3f dB)",
                  n_all, db10(mean_all), db10(noise_theory), db10(mean_all) - db10(noise_theory));
        $display("noise spread: CV %.4f (theory %.4f)", cv_meas, cv_th);

        // Check 1: the peak is in the tone's column.
        if (peak_col != zcol_of_rel(zrel_of(TONE_BIN))) begin
            $display("FAIL: peak in column %0d, expected %0d", peak_col, zcol_of_rel(zrel_of(TONE_BIN)));
            errors = errors + 1;
        end
        // Check 2: the line matches the model in every column, with no unknown values.
        if (n_x != 0 || n_model_bad != 0) begin
            $display("FAIL: line does not match the injected-bin model (%0d X, %0d off)", n_x, n_model_bad);
            errors = errors + 1;
        end
        // Check 3: the noise floor is within 0.3 dB of the theory.
        if ((db10(mean_all) - db10(noise_theory) > 0.3) || (db10(noise_theory) - db10(mean_all) > 0.3)) begin
            $display("FAIL: noise floor level off theory by more than 0.3 dB");
            errors = errors + 1;
        end
        // Check 4: the spread of the noise is within 20 % of the theory.
        if (cv_meas > cv_th * (1.0 + CV_TOL) || cv_meas < cv_th * (1.0 - CV_TOL)) begin
            $display("FAIL: noise CV %.4f outside +/- %.0f%% of theory %.4f", cv_meas, 100.0*CV_TOL, cv_th);
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS");
        else $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    // Watchdog: K frames of 4,096 clocks of 6.667 ns, with 50 % margin and 1 ms for the gaps and the walks.
    initial begin
        #(K * ZN * 6.667 * 1.5 + 1_000_000);
        $display("FAIL: timeout");
        $finish;
    end

endmodule
