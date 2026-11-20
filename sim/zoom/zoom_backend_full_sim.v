// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// End-to-end test of the zoom spectrum with its waterfall back end, run to completion through the real DDC
// and FFT chain (rtl/zoom/zoom_spectrum.v) and the averaging, dB and waterfall back end of the zoom in
// rtl/spectrum/spectrum_pipeline.v: a tone 1 kHz off the zoom center at the 48 kHz span must show up in the
// right screen column of the line that the pipeline writes (docs/PLAN.md, and docs/F3_ZOOM.md for the same test
// of the zoom spectrum alone). docs/learn/GLOSSARY.md has the terms: the DDC (digital down-converter)
// mixes the ADC samples down so that the zoom center is at 0 Hz and decimates them (keeps only a
// fraction of the samples), the FFT turns each block of 4,096 samples into 4,096 bins, and the back end turns the
// bins into power, groups them into the 1,920 screen columns, averages K frames and converts to dB.
//
// The stimulus is that of sim/zoom/zoom_bin48_sim.v (whose header explains why one frame at the 48 kHz span
// takes 20 to 30 minutes under iverilog: 4,096 x 1,280 = 5,242,880 ADC clocks), with Gaussian noise of 4 steps
// (sigma) added to the tone and K = 2 frames averaged, so this run takes at least twice as long, about an hour.
// The zoom center is 7.1 MHz, the tone 1,800 in amplitude and 1 kHz above it, and the ADC gets one sample per
// clock. The file is deliberately not named tb_*.v, so tools/check.sh does not run it; its fast equivalent,
// which injects synthetic bins into the back end and covers the same logic without the DDC's decimation, is
// sim/zoom/tb_zoom_backend_quick.v.
//
// What counts as a pass: after the first complete line the bench reads back all 1,920 columns of the line buffer
// (16-bit values in 1/64 dB), no column may hold an unknown (x) value, and the column with the highest
// level must be the column of the tone's bin (bin round(1,000 / 14.65) = 68 at the 60 kHz full rate of this
// span, mapped to a column with the same bin-to-column arithmetic as the pipeline). The bench prints the
// peak column and its level and ends with PASS or FAIL. The level and the spread of the noise floor are
// checked against theory only in tb_zoom_backend_quick.v.
//
// Run from the repository root, or with tools/zoom_backend_full_sim.sh:
//   iverilog -g2012 -o tb.vvp sim/zoom/zoom_backend_full_sim.v && vvp tb.vvp

`timescale 1ns / 1ps

// The zoom pipeline's back end, and then the zoom DDC and FFT that feed it.
`include "rtl/spectrum/spectrum_pipeline.v"
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
`include "rtl/zoom/zoom_spectrum.v"

module zoom_backend_full_sim;

    localparam real PI = 3.14159265358979323846;
    localparam real FS = 76_800_000.0;
    localparam real ZOOM_CENTRE_HZ = 7_100_000.0;
    localparam real OFFSET_HZ      = 1_000.0;
    localparam real TONE_HZ        = ZOOM_CENTRE_HZ + OFFSET_HZ;   // zoom_ddc.v negates phase_inc,
                                                                     // see docs/F3_ZOOM.md section 5
    localparam real AMP            = 1800.0;
    localparam real NOISE_SIGMA    = 4.0;                           // standard deviation of the Gaussian noise on each ADC sample, in ADC steps

    localparam integer LOG_N       = 12;
    localparam integer N           = 1 << LOG_N;
    localparam [2:0]   SPAN_SHIFT  = 3'd6;                          // 48 kHz displayed span
    localparam real    FULL_RATE_HZ = 76_800_000.0 / 10.0 / 64.0 / 2.0; // 60 kHz
    localparam real    BIN_HZ      = FULL_RATE_HZ / N;
    localparam integer EXPECT_BIN  = $rtoi(OFFSET_HZ / BIN_HZ + 0.5);
    // K frames are averaged in the back end.
    localparam integer K           = 2;

    // One clock serves zoom_spectrum.v and spectrum_pipeline.v, as in sim/zoom/zoom_bin48_sim.v: both run on
    // clk_dsp in the real system, and adc_valid is high on every clock here (one ADC sample per clock), the
    // same simplification as in that file.
    reg clock = 1'b0;
    always #1 clock = ~clock;
    reg rst = 1'b1;
    reg [11:0] adc_data = 12'sd0;
    reg        adc_valid = 1'b0;
    reg        zoom_enable = 1'b0;
    reg signed [31:0] phase_inc;

    wire                z_valid, z_first, z_usable;
    wire [LOG_N-1:0]    z_bin;
    wire signed [17+LOG_N-1:0] z_re, z_im;

    zoom_spectrum #(.LOG_N(LOG_N)) u_zoom (
        .clock(clock), .rst(rst),
        .adc_data(adc_data), .adc_valid(adc_valid),
        .phase_inc(phase_inc), .span_shift(SPAN_SHIFT), .narrow_shift(3'd0), .narrow_gain(2'd0), .enable(zoom_enable),
        .out_valid(z_valid), .out_first(z_first), .out_bin(z_bin), .out_usable(z_usable),
        .out_re(z_re), .out_im(z_im)
    );

    // The full-band side of the pipeline is not used, and its inputs stay quiet.
    wire adc_valid_be = 1'b0;
    wire reg_wr = 1'b0, reg_rd = 1'b0;
    wire [15:0] reg_addr = 16'h0;
    wire [31:0] reg_wdata = 32'h0;
    wire [31:0] reg_rdata;
    wire irq_line_done;
    wire [10:0] line_rd_addr = 11'd0;
    wire [15:0] line_rd_data;
    wire wf_valid, wf_sol, wf_eol;
    wire [7:0] wf_data;

    // The zoom register bus of the pipeline and the line buffer read port.
    reg  zreg_wr = 1'b0, zreg_rd = 1'b0;
    reg  [15:0] zreg_addr = 16'h0;
    reg  [31:0] zreg_wdata = 32'h0;
    wire [31:0] zreg_rdata;
    wire zirq_line_done;
    reg  [10:0] zline_rd_addr = 11'd0;
    wire [15:0] zline_rd_data;
    wire zwf_valid, zwf_sol, zwf_eol;
    wire [7:0] zwf_data;

    spectrum_pipeline dut (
        .clk(clock), .rst(rst), .adc_data(12'sd0), .adc_valid(adc_valid_be),
        .reg_wr(reg_wr), .reg_rd(reg_rd), .reg_addr(reg_addr), .reg_wdata(reg_wdata),
        .reg_rdata(reg_rdata), .irq_line_done(irq_line_done),
        .line_rd_addr(line_rd_addr), .line_rd_data(line_rd_data),
        .wf_valid(wf_valid), .wf_sol(wf_sol), .wf_eol(wf_eol), .wf_data(wf_data),
        .zoom_in_valid(z_valid), .zoom_in_first(z_first), .zoom_in_bin(z_bin),
        .zoom_in_usable(z_usable), .zoom_in_re(z_re), .zoom_in_im(z_im),
        .zreg_wr(zreg_wr), .zreg_rd(zreg_rd), .zreg_addr(zreg_addr), .zreg_wdata(zreg_wdata),
        .zreg_rdata(zreg_rdata), .zirq_line_done(zirq_line_done),
        .zline_rd_addr(zline_rd_addr), .zline_rd_data(zline_rd_data),
        .zwf_valid(zwf_valid), .zwf_sol(zwf_sol), .zwf_eol(zwf_eol), .zwf_data(zwf_data)
    );

    // One write on the zoom register bus.
    task zreg_write(input [15:0] a, input [31:0] d);
        begin
            @(posedge clock); #1; zreg_addr = a; zreg_wdata = d; zreg_wr = 1'b1;
            @(posedge clock); #1; zreg_wr = 1'b0;
        end
    endtask

    real w;
    integer seed_n, k_idx, c, errors;
    integer expect_col;

    // The bin-to-column mapping of rtl/spectrum/spectrum_pipeline.v and tools/gen_spectrum_tables.py: the usable
    // bins are 0 to 1,638 and 2,458 to 4,095 (80 % of 4,096), counted from the low end of the range, and a
    // column is (position x 614363) >> 20, which is 1,920 / 3,277 columns per bin.
    localparam integer Z_USABLE_HALF = 1638;
    localparam integer Z_COL_MULT    = 614363;
    localparam integer Z_COL_SHIFT   = 20;
    function integer zrel_of(input integer bin);
        begin
            if (bin <= Z_USABLE_HALF) zrel_of = bin + Z_USABLE_HALF;
            else                      zrel_of = bin - (N - Z_USABLE_HALF);
        end
    endfunction
    function integer zcol_of_rel(input integer rel);
        reg [63:0] p;
        begin
            p = rel * Z_COL_MULT;
            zcol_of_rel = p >> Z_COL_SHIFT;
        end
    endfunction

    // The level of every column read back from the line buffer, in dB.
    real db_val [0:1919];
    real peak_val;
    integer peak_col, n_x;

    // Setup: the expected column, the tone's phase step per sample, and the NCO phase increment of the zoom center
    // (center over sample rate times 2^32, since the phase accumulator wraps once per cycle).
    initial begin
        errors = 0;
        seed_n = 13579;
        expect_col = zcol_of_rel(zrel_of(EXPECT_BIN));
        w  = 2.0 * PI * TONE_HZ / FS;
        phase_inc = $rtoi((ZOOM_CENTRE_HZ / FS) * 4294967296.0);

        $display("%m: zoom centre = %.0f Hz, tone = %.0f Hz (+%.0f Hz), expected bin = %0d, column = %0d, K = %0d",
                  ZOOM_CENTRE_HZ, TONE_HZ, OFFSET_HZ, EXPECT_BIN, expect_col, K);

        // Short reset, then enable the zoom DDC and set the back end: K frames of averaging and the column mode "mean".
        repeat (5) @(posedge clock);
        rst = 1'b0;
        @(posedge clock);
        zoom_enable = 1'b1;
        zreg_write(`ZOOM_BACKEND_AVERAGING_K_ADDR, K[31:0]);
        zreg_write(`ZOOM_CTRL_ADDR, 32'h0000_0010);   // backend_column_mode = mean

        // The ADC samples: K frames of the FFT's own input, and one more frame because the FFT delivers frame f
        // while frame f+1 goes in (the same margin as in sim/zoom/zoom_bin48_sim.v and
        // sim/spectrum/spectrum_done_test.vh). The sample is the tone plus Gaussian noise of 4 steps, rounded.
        for (k_idx = 0; k_idx < (K + 1) * N * 1280; k_idx = k_idx + 1) begin
            @(posedge clock);
            adc_data  <= $rtoi(AMP * $cos(w * k_idx) + $itor($dist_normal(seed_n, 0, $rtoi(NOISE_SIGMA))));
            adc_valid <= 1'b1;
        end
        adc_valid <= 1'b0;
        $display("%m: stimulus done at t=%0t", $time);

        // Wait for the first line, then read all 1,920 columns back (one read takes two clocks).
        wait (dut.zline_count_reg == 32'd1);
        $display("%m: zoom line 1 complete at t=%0t", $time);
        repeat (3) @(posedge clock);
        n_x = 0;
        for (c = 0; c < 1920; c = c + 1) begin
            @(posedge clock); #1; zline_rd_addr = c[10:0];
            @(posedge clock); #1;
            if (^zline_rd_data === 1'bx) begin
                n_x = n_x + 1; db_val[c] = -512.0;
            end else begin
                db_val[c] = $itor($signed(zline_rd_data)) / 64.0;
            end
        end
        // The column with the highest level.
        peak_val = -1.0e300; peak_col = -1;
        for (c = 0; c < 1920; c = c + 1)
            if (db_val[c] > peak_val) begin peak_val = db_val[c]; peak_col = c; end

        $display("peak column %0d (expected %0d), level %.3f dB", peak_col, expect_col, peak_val);

        // Checks: no undefined column, and the peak in the tone's column.
        if (n_x != 0) begin
            $display("FAIL: %0d columns undefined", n_x); errors = errors + 1;
        end
        if (peak_col != expect_col) begin
            $display("FAIL: peak in column %0d, expected %0d", peak_col, expect_col);
            errors = errors + 1;
        end

        if (errors == 0) $display("PASS");
        else $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    // Watchdog: a little more than the (K + 1) frames of stimulus.
    initial begin
        repeat ((K + 2) * N * 1280 + 100_000) @(posedge clock);
        $display("FAIL: timeout");
        $finish;
    end

endmodule
