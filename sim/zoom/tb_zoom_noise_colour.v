// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Test of the colors that the zoom waterfall shows for the receiver's own noise (docs/LISTEN.md section 8).
// The DUT is rtl/spectrum/spectrum_pipeline.v, whose zoom side takes the 4,096 complex bins of a zoom FFT
// frame, turns them into power, reduces them to screen columns, converts to dB, adds the level offset and
// gain that the firmware writes to the backend_level register, and turns the result into one 8-bit palette
// index (the "color byte") per column of the waterfall line. Palette index 0 is black. If the firmware sets
// the level wrongly, a line that holds nothing but receiver noise comes out all black, and nobody can see
// whether the radio works, which is what this bench is there to catch.
//
// Same method as tb_zoom_backend_quick.v: the bench does not run the DDC and FFT, it injects synthetic bins
// on the zoom_in_* port of the pipeline, so a test takes a fraction of a second instead of hours.
//
// Stimulus: two frames, each of 4,096 bins in the bit-reversed order in which the FFT delivers them, every
// bin of the usable 80 % (bins 0 to 1,638 and 2,458 to 4,095) a Gaussian random number with the same
// standard deviation (sigma) on the real and on the imaginary part. The sigma values come from a model of
// the whole receive chain (the model is a script that is not in the repository, its figures are in
// docs/LISTEN.md section 8). It multiplies the fixed-point scale factors of the stages (mixer table
// 107,922 / 2^11, fixed CIC 10^9 / 2^32, variable CIC 1, narrow CIC 4^gain, half-band and droop filters 1,
// 4-term Blackman-Harris window, unscaled 4,096-point FFT) with the ADC noise of 1.06 LSB^2 (the S-meter's
// -105 dBFS in 2.4 kHz, measured on the board with no antenna) plus the rounding of the 16-bit words between
// the stages, at the 12 kHz span (15 ksps into the FFT):
//   narrow gain 16:  sigma  87 per component, power word mean 0.40 = -4.0 dB
//   narrow gain 64:  sigma 337 per component, power word mean 3.64 = +5.6 dB
//
// Line 1 uses the level that goes with gain 16 (offset -24.08 dB, gain_q8 0x100, that is 1.0 index step per
// dB), the setting the firmware used at first, and every color byte must be 0: this is a negative control
// that reproduces the all-black waterfall that was seen on the board, and it fails if the pipeline starts
// to show noise at that level.
// Line 2 uses gain 64 and the firmware's current first level (offset +7.50 dB, gain_q8 1,092, which is 60
// dB spread over the 256 palette indices, 256 x 256 / 60 rounded; tr_station::wflevel): at least 95 % of
// the window's columns (the middle 1,172 of the 1,920, columns 374 to 1,545) must not be 0, and the 25th
// percentile of their palette indices must lie between 16 and 64, because the firmware aims for the noise
// floor at index 32.
//
// The bench prints the counts for each line and ends with PASS, or with FAIL and the number of failed checks.
//
// Run from the repository root:
//   iverilog -g2012 -o build/tb_zoom_noise_colour.vvp sim/zoom/tb_zoom_noise_colour.v && vvp build/tb_zoom_noise_colour.vvp

`timescale 1ns / 1ps
`include "rtl/spectrum/spectrum_pipeline.v"

module tb_zoom_noise_colour;

    // The zoom FFT has 4,096 bins, of which the central 80 % are usable: bin 0 and 1,638 (0.4 x 4,096,
    // rounded down) on each side of it. The screen line has 1,920 columns and the waterfall window shows
    // the middle 1,172 of them, starting at column (1,920 - 1,172) / 2 = 374.
    localparam integer ZN            = 4096;
    localparam integer Z_USABLE_HALF = 1638;
    localparam integer COLS          = 1920;
    localparam integer WIN_X0        = (1920 - 1172) / 2;
    localparam integer WIN_W         = 1172;

    // Bit reversal of a 12-bit index: the FFT delivers its bins in this order, so the bench does too.
    function integer bitrev12(input integer x);
        integer b;
        begin
            bitrev12 = 0;
            for (b = 0; b < 12; b = b + 1) bitrev12 = bitrev12 | (((x >> b) & 1) << (11 - b));
        end
    endfunction

    // 150 MHz (half period 3.333 ns) where the chip runs at 120 MHz, which makes no difference because only
    // the number of clocks matters here.
    reg clk = 1'b0;
    always #3.333 clk = ~clk;
    // The full-band side of the pipeline is not used and its inputs stay quiet.
    reg rst = 1'b1;

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
    // the register bus (a write takes one clock) and the waterfall outputs.
    reg                zoom_in_valid = 1'b0, zoom_in_first = 1'b0, zoom_in_usable = 1'b0;
    reg  [11:0]        zoom_in_bin = 12'd0;
    reg  signed [28:0] zoom_in_re = 29'sd0, zoom_in_im = 29'sd0;
    reg                zreg_wr = 1'b0, zreg_rd = 1'b0;
    reg  [15:0]        zreg_addr = 16'h0;
    reg  [31:0]        zreg_wdata = 32'h0;
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

    // One write on the zoom register bus.
    task zreg_write(input [15:0] a, input [31:0] d);
        begin
            @(posedge clk); #1; zreg_addr = a; zreg_wdata = d; zreg_wr = 1'b1;
            @(posedge clk); #1; zreg_wr = 1'b0;
        end
    endtask

    // One noise-only frame: every usable bin Gaussian with `sigma` per component, one bin per clock in FFT
    // output order, with out_first on the first and the usable flag set for the central 80 %. The seed
    // is fixed so that every run is the same.
    integer seed_n = 20261022;
    task play_frame(input integer sigma);
        integer idx, bin;
        begin
            for (idx = 0; idx < ZN; idx = idx + 1) begin
                bin = bitrev12(idx);
                @(posedge clk); #1;
                zoom_in_valid  = 1'b1;
                zoom_in_first  = (idx == 0);
                zoom_in_bin    = bin[11:0];
                zoom_in_usable = (bin <= Z_USABLE_HALF) || (bin >= ZN - Z_USABLE_HALF);
                zoom_in_re     = $dist_normal(seed_n, 0, sigma);
                zoom_in_im     = $dist_normal(seed_n, 0, sigma);
            end
            @(posedge clk); #1; zoom_in_valid = 1'b0;
        end
    endtask

    // The colour bytes of the line being written (the column is the position since the start of the line).
    reg [7:0] bytes [0:COLS-1];
    integer   col = 0, lines_out = 0;
    always @(posedge clk) begin
        if (zwf_valid) begin
            if (zwf_sol) col = 0;
            if (col < COLS) bytes[col] = zwf_data;
            col = col + 1;
            if (zwf_eol) lines_out = lines_out + 1;
        end
    end

    // Statistics of a finished line: how many columns are not black (in the window and in the whole line),
    // the 25th percentile of the palette indices in the window, found through a histogram, and their mean.
    integer hist [0:255];
    integer c, k, acc, nz, nz_all, p25, errors;
    real    mean;
    task stats(input integer line_no);
        begin
            for (k = 0; k < 256; k = k + 1) hist[k] = 0;
            nz = 0; nz_all = 0; mean = 0.0;
            for (c = 0; c < COLS; c = c + 1) if (bytes[c] != 0) nz_all = nz_all + 1;
            for (c = WIN_X0; c < WIN_X0 + WIN_W; c = c + 1) begin
                hist[bytes[c]] = hist[bytes[c]] + 1;
                if (bytes[c] != 0) nz = nz + 1;
                mean = mean + bytes[c];
            end
            mean = mean / WIN_W;
            acc = 0; p25 = -1;
            for (k = 0; k < 256 && p25 < 0; k = k + 1) begin
                acc = acc + hist[k];
                if (acc * 4 >= WIN_W) p25 = k;
            end
            $display("line %0d: %0d of %0d window columns not black (%0d of %0d in the whole line), 25th percentile index %0d, mean index %.1f",
                     line_no, nz, WIN_W, nz_all, COLS, p25, mean);
        end
    endtask

    initial begin
        errors = 0;
        // Short reset, then no averaging (K = 1) and the plain column mode, which takes the largest bin of each column.
        repeat (5) @(posedge clk); rst = 1'b0;
        repeat (5) @(posedge clk);
        zreg_write(`ZOOM_BACKEND_AVERAGING_K_ADDR, 32'd1);
        zreg_write(`ZOOM_CTRL_ADDR, 32'h0000_0000);                    // max per column, the usual column scale

        // ---- line 1: the level that goes with gain 16. The offset is -1,542 / 64 dB (the register holds dB x 64
        // as a 16-bit two's complement number) and the gain 0x100 / 256 = 1.0. Check: all black.
        zreg_write(`ZOOM_BACKEND_LEVEL_ADDR, (32'h0100 << 16) | 16'hF9FA);   // -1,542 / 64 dB, gain 1.0
        play_frame(87);
        wait (lines_out == 1);
        stats(1);
        if (nz_all != 0) begin
            $display("FAIL: line 1 (old level, gain 16) has %0d columns that are not black; the board showed none", nz_all);
            errors = errors + 1;
        end

        // ---- line 2: the level that goes with gain 64, offset 480 / 64 = +7.50 dB. Checks: at least 95 % of
        // the window not black, and the 25th percentile between 16 and 64.
        zreg_write(`ZOOM_BACKEND_LEVEL_ADDR, (32'd1092 << 16) | 32'd480);    // +7.50 dB, 60 dB over the palette
        repeat (100) @(posedge clk);
        play_frame(337);
        wait (lines_out == 2);
        stats(2);
        if (nz * 100 < WIN_W * 95) begin
            $display("FAIL: line 2 (new level, gain 64): only %0d of %0d window columns are not black", nz, WIN_W);
            errors = errors + 1;
        end
        if (p25 < 16 || p25 > 64) begin
            $display("FAIL: line 2: 25th percentile index %0d, expected 16 to 64 (the firmware aims at 32)", p25);
            errors = errors + 1;
        end

        // Pass only if both lines were as expected.
        if (errors == 0) $display("PASS");
        else $display("FAIL: %0d error(s)", errors);
        $finish;
    end

    // Watchdog: 2 ms of simulated time is far more than the two frames need.
    initial begin
        #2_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
