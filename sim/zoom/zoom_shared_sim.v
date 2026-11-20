// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Test that one FFT can serve both spectrum views (docs/ZOOM_FIT.md section 2). The DUT is
// rtl/spectrum/spectrum_pipeline.v with ZOOM_SHARED = 1, which means that the zoom has no FFT of its own: its
// frames of 4,096 windowed samples are pushed through the last twelve stages of the 16,384-point whole-band
// FFT, between two whole-band frames, and the zoom side takes its bins from there. The frames reach the
// pipeline the way rtl/zoom/zoom_frontend.v wires them, through rtl/zoom/zoom_window.v and rtl/zoom/zoom_frame.v
// (the window shapes a block of samples to keep the leakage between FFT bins low, and the frame
// buffer holds a windowed frame until the shared FFT is free for it). docs/learn/GLOSSARY.md has the terms.
//
// Two reference FFTs of their own check the shared one:
//   - zoom: every bin of every frame (index, real, imaginary, the "first" flag and the "usable" flag) must equal
//     that of a 4,096-point fft_r22sdf fed with the same windowed samples (the frames that the buffer accepted);
//   - whole band: the sequence of bins (index, real, imaginary, "first") must equal that of a 16,384-point
//     fft_r22sdf behind its own window, fed with the samples that the pipeline took (it drops those that arrive
//     while a zoom frame goes in);
//   - the zoom frames go in only at whole-band frame boundaries, both contexts produce lines, and no zoom
//     bin arrives while the zoom context is being walked (the shared engine is busy then).
//
// Stimulus: the whole-band ADC samples are random 12-bit words that are valid on 16 of every 25 clocks, in runs,
// which is the 76.8 Msps of the ADC on the 120 MHz clock. The zoom DDC is not in this test: its samples are
// random 16-bit words 16 to 31 clocks apart, with full-scale words (+32767 and -32768) among them, because the
// DDC is unchanged and has its own tests. Four zoom frames are compared, and the whole band runs for at least ten
// frames.
//
// What counts as a pass: no mismatch in either comparison, all NZF x 4,096 zoom bins seen, every zoom frame
// started at a whole-band frame boundary (bad_boundary = 0), no zoom bin during a walk (bin_in_walk = 0), at
// least NZF zoom lines and ten whole-band lines, and at least ten whole-band frames of words compared. It
// prints the counts and PASS, or FAIL with the number of errors.
//
// Run from the repository root (about 5 minutes):
//   iverilog -g2012 -o build/zoom_shared_sim.vvp sim/zoom/zoom_shared_sim.v && vvp build/zoom_shared_sim.vvp

`timescale 1ns / 1ps
`include "rtl/spectrum/spectrum_pipeline.v"
`include "rtl/zoom/zoom_window.v"
`include "rtl/zoom/zoom_frame.v"

module zoom_shared_sim;
    // Number of zoom frames that are compared.
    localparam integer NZF = 4;                      // zoom frames compared

    // 120 MHz clock (half period 4.166 ns).
    reg clk = 1'b0; always #4.166 clk = ~clk;
    reg rst = 1'b1;
    integer seed = 11;

    // ---- whole-band samples: valid on 16 of every 25 clocks, in runs (16/25 x 120 MHz = 76.8 MHz).
    reg signed [11:0] adc_data = 0;
    reg               adc_valid = 0;
    integer ph = 0;
    always @(posedge clk) begin
        ph        <= (ph == 24) ? 0 : ph + 1;
        adc_valid <= !rst && (ph < 16);
        adc_data  <= $random(seed);
    end

    // ---- zoom samples in place of the DDC: one every 16 to 31 clocks (gap counts down from 15 + a random number
    // of 0 to 15), with +32767 or -32768 now and then on I and on Q.
    reg               ddc_valid = 0;
    reg signed [15:0] ddc_i = 0, ddc_q = 0;
    integer gap = 20, r;
    always @(posedge clk) begin
        ddc_valid <= 1'b0;
        if (!rst) begin
            if (gap == 0) begin
                ddc_valid <= 1'b1;
                r = $random(seed);
                ddc_i <= (r % 13 == 0) ? 16'sh7FFF : (r % 17 == 0) ? 16'sh8000 : $random(seed);
                ddc_q <= (r % 13 == 0) ? 16'sh7FFF : (r % 19 == 0) ? 16'sh8000 : $random(seed);
                gap = 15 + ({$random(seed)} % 16);
            end else gap = gap - 1;
        end
    end

    // The zoom front end as zoom_frontend.v wires it: the window takes a sample when the frame buffer says `take`,
    // and the frame buffer asks the pipeline for the FFT (ready and go) and plays the frame into it.
    wire               take, win_valid;
    wire signed [15:0] win_re, win_im;
    zoom_window #(.N(4096), .IN_WIDTH(16), .OUT_WIDTH(16)) u_win (
        .clock(clk), .rst(rst), .in_valid(ddc_valid & take), .in_i(ddc_i), .in_q(ddc_q),
        .out_valid(win_valid), .out_re(win_re), .out_im(win_im));
    wire               fr_ready, fr_go, fr_valid, fr_last;
    wire signed [15:0] fr_re, fr_im;
    zoom_frame #(.LOG_N(12), .W(16)) u_frame (
        .clock(clk), .rst(rst), .in_strobe(ddc_valid), .take(take),
        .win_valid(win_valid), .win_re(win_re), .win_im(win_im),
        .ready(fr_ready), .go(fr_go), .out_valid(fr_valid), .out_last(fr_last), .out_re(fr_re), .out_im(fr_im));

    // Register bus of the whole band and of the zoom, which only set the averaging and enable below.
    reg         reg_wr = 0, zreg_wr = 0;
    reg  [15:0] reg_addr = 0, zreg_addr = 0;
    reg  [31:0] reg_wdata = 0, zreg_wdata = 0;
    wire [31:0] reg_rdata, zreg_rdata;
    wire        irq, zirq, wf_valid, wf_sol, wf_eol, zwf_valid, zwf_sol, zwf_eol;
    wire [15:0] lrd, zlrd;
    wire [7:0]  wf_data, zwf_data;
    // The DUT, with the shared FFT: the zoom bins come from the pipeline's own FFT, so the zoom_in_* port is
    // tied off and the frame goes in on zfr_*.
    spectrum_pipeline #(.ZOOM_SHARED(1)) dut (
        .clk(clk), .rst(rst), .adc_data(adc_data), .adc_valid(adc_valid),
        .reg_wr(reg_wr), .reg_rd(1'b0), .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_rdata(reg_rdata),
        .irq_line_done(irq), .line_rd_addr(11'd0), .line_rd_data(lrd),
        .wf_valid(wf_valid), .wf_sol(wf_sol), .wf_eol(wf_eol), .wf_data(wf_data),
        .zoom_in_valid(1'b0), .zoom_in_first(1'b0), .zoom_in_bin(12'd0),
        .zoom_in_usable(1'b0), .zoom_in_re(29'sd0), .zoom_in_im(29'sd0),
        .zfr_ready(fr_ready), .zfr_go(fr_go), .zfr_valid(fr_valid), .zfr_last(fr_last), .zfr_re(fr_re), .zfr_im(fr_im),
        .zreg_wr(zreg_wr), .zreg_rd(1'b0), .zreg_addr(zreg_addr), .zreg_wdata(zreg_wdata), .zreg_rdata(zreg_rdata),
        .zirq_line_done(zirq), .zline_rd_addr(11'd0), .zline_rd_data(zlrd),
        .zwf_valid(zwf_valid), .zwf_sol(zwf_sol), .zwf_eol(zwf_eol), .zwf_data(zwf_data));

    // ---- reference 1: the zoom's own 4,096-point FFT, on the same windowed samples (17 bits in: the
    // 16-bit window output with one head-room bit)
    wire        zr_valid, zr_first;
    wire [11:0] zr_bin, zr_index;
    wire [28:0] zr_re, zr_im;
    fft_r22sdf #(.LOG_N(12), .IW(17), .REAL_IN(0)) u_zref (
        .clk(clk), .rst(rst), .in_valid(win_valid), .in_re({win_re[15], win_re}), .in_im({win_im[15], win_im}),
        .out_valid(zr_valid), .out_first(zr_first), .out_index(zr_index), .out_bin(zr_bin),
        .out_re(zr_re), .out_im(zr_im),
        .inj_valid(1'b0), .inj_re(17'd0), .inj_im(17'd0), .out_ivalid(), .out_ifirst(), .out_iindex(), .out_ibin());

    // ---- reference 2: the whole band's own window and 16,384-point FFT, fed with the samples the pipeline took
    wire               wr_valid;
    wire signed [14:0] wr_re;
    spectrum_window #(.LOG_N(14), .IW(12), .OW(15)) u_wref (
        .clk(clk), .rst(rst), .in_valid(dut.fb_take), .in_sample(adc_data),
        .out_valid(wr_valid), .out_sample(wr_re));
    wire        fr_v, fr_f;
    wire [13:0] fr_bin, fr_idx;
    wire [28:0] fr_r, fr_i;
    fft_r22sdf #(.LOG_N(14), .IW(15), .REAL_IN(1), .SR_LUT(1), .LUT_MAX_W(256), .TW_LUT_MAX(128), .TW_M1_ONE(1)) u_fref (
        .clk(clk), .rst(rst), .in_valid(wr_valid), .in_re(wr_re), .in_im(15'd0),
        .out_valid(fr_v), .out_first(fr_f), .out_index(fr_idx), .out_bin(fr_bin), .out_re(fr_r), .out_im(fr_i),
        .inj_valid(1'b0), .inj_re(15'd0), .inj_im(15'd0), .out_ivalid(), .out_ifirst(), .out_iindex(), .out_ibin());

    // errors is shared by all the checks.
    integer errors = 0;

    // Whole band: word for word in order, with the DUT's words (qa) and the reference's words (qb) in two queues
    // that are compared as soon as both have a word. A word is {first, bin, re, im}, 1 + 14 + 29 + 29 = 73 bits.
    reg [72:0] qa [$];
    reg [72:0] qb [$];
    reg [72:0] wa_w, wb_w;
    integer fb_words = 0;
    always @(posedge clk) begin
        if (dut.fft_valid) qa.push_back({dut.fft_first, dut.fft_bin, dut.fft_re, dut.fft_im});
        if (fr_v)          qb.push_back({fr_f, fr_bin, fr_r, fr_i});
        while (qa.size() > 0 && qb.size() > 0) begin
            wa_w = qa.pop_front(); wb_w = qb.pop_front();
            fb_words = fb_words + 1;
            if (wa_w !== wb_w) begin
                errors = errors + 1;
                if (errors <= 10) $display("MISMATCH whole band word %0d: %h, reference %h", fb_words, wa_w, wb_w);
            end
        end
    end

    // Zoom: the bins of each frame stored by bin number ({re, im}, 29 + 29 bits) for the DUT (za, with the
    // usable flag in zua) and for the reference (zb), and counters for the boundary and walk checks.
    reg [57:0] za [0:NZF*4096-1];
    reg [57:0] zb [0:NZF*4096-1];
    reg        zua [0:NZF*4096-1];
    integer nza = -1, nzb = -1, cza = 0, czb = 0, i, k, zwords = 0;
    integer plays = 0, bad_boundary = 0, bin_in_walk = 0, firsts = 0;
    always @(posedge clk) begin
        if (dut.zin_valid) begin
            if (dut.zin_first) begin nza = nza + 1; firsts = firsts + 1; end
            if (nza >= 0 && nza < NZF) begin
                za[nza*4096 + dut.zin_bin]  = {dut.zin_re, dut.zin_im};
                zua[nza*4096 + dut.zin_bin] = dut.zin_usable;
                cza = cza + 1;
            end
            if (dut.walkB_busy) bin_in_walk = bin_in_walk + 1;
        end
        if (zr_valid) begin
            if (zr_first) nzb = nzb + 1;
            if (nzb >= 0 && nzb < NZF) begin zb[nzb*4096 + zr_bin] = {zr_re, zr_im}; czb = czb + 1; end
        end
        // fr_go starts a zoom frame: it must happen at a whole-band frame boundary (fb_pos = 0).
        if (fr_go) begin
            plays = plays + 1;
            if (dut.g_zsh.fb_pos != 0) bad_boundary = bad_boundary + 1;
        end
    end

    // Register writes on the whole-band bus and on the zoom bus.
    task wr(input [15:0] a, input [31:0] d); begin
        @(posedge clk); #1; reg_addr = a; reg_wdata = d; reg_wr = 1; @(posedge clk); #1; reg_wr = 0;
    end endtask
    task zwr(input [15:0] a, input [31:0] d); begin
        @(posedge clk); #1; zreg_addr = a; zreg_wdata = d; zreg_wr = 1; @(posedge clk); #1; zreg_wr = 0;
    end endtask

    initial begin
        // Reset, then no averaging (K = 1) on both sides and the whole-band path enabled.
        repeat (5) @(posedge clk); rst = 0;
        wr(`SPECTRUM_AVERAGING_K_ADDR, 32'd1);
        wr(`SPECTRUM_CTRL_ADDR, 32'd1);
        zwr(`ZOOM_BACKEND_AVERAGING_K_ADDR, 32'd1);
        // Run until the reference has begun frame NZF, which means that frames 0 to NZF - 1 are complete (the
        // reference gives frame f while frame f + 1 goes in), and then give the DUT 40,000 clocks to finish.
        wait (nzb == NZF);
        repeat (40000) @(posedge clk);
        // Check 1: every zoom bin of every frame arrived.
        if (cza != NZF * 4096 || czb != NZF * 4096) begin
            $display("ERROR: %0d zoom bins, %0d of the reference, expected %0d", cza, czb, NZF * 4096);
            errors = errors + 1;
        end
        // Check 2: every zoom bin equals the reference, and the usable flag is that of the central 80 %
        // (bins 0 to 1,638 and 2,458 to 4,095).
        for (i = 0; i < NZF * 4096; i = i + 1) begin
            zwords = zwords + 1;
            k = i % 4096;
            if (za[i] !== zb[i] || zua[i] !== ((k <= 1638) || (k >= 2458))) begin
                errors = errors + 1;
                if (errors <= 10) $display("MISMATCH zoom frame %0d bin %0d: %h, reference %h", i / 4096, k, za[i], zb[i]);
            end
        end
        // Report, and Check 3: boundaries, walk collisions and the line counts.
        $display("zoom: %0d bins of %0d frames compared; whole band: %0d bins compared (%0d frames)",
                 zwords, NZF, fb_words, fb_words / 16384);
        $display("zoom frames played: %0d, not at a whole-band frame boundary: %0d; zoom bins during a zoom walk: %0d",
                 plays, bad_boundary, bin_in_walk);
        $display("lines: whole band %0d, zoom %0d", dut.line_count_reg, dut.zline_count_reg);
        if (bad_boundary != 0 || bin_in_walk != 0 || plays < NZF) errors = errors + 1;
        if (dut.zline_count_reg < NZF || dut.line_count_reg < 10 || fb_words < 10 * 16384) errors = errors + 1;
        if (errors == 0) $display("PASS"); else $display("FAIL (%0d errors)", errors);
        $finish;
    end
endmodule
