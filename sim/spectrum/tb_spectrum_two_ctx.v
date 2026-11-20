// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Testbench for the shared column-walk engine inside rtl/spectrum/spectrum_pipeline.v. That module hosts
// two spectrum backends, the full-band one (context A) and the zoom one (context B), and one walk engine
// (log, dB and color arithmetic) serves whichever context finishes a frame next. This bench runs both
// contexts at once, with the full-band ADC stream on every clock and zoom bin frames arriving in between,
// so that one context's walk is often granted straight after the other's. The engine's current context
// switches while the previous walk's last columns are still in its pipeline, so the write-back and the
// line output have to follow the context that owns each column and not the engine's present one, and this
// bench exists to catch a fault in exactly that.
//
// Pass: each context's line output delivers columns 0 to 1,919 in order, once each, for every line, no
// order error is counted for either context, at least one line is finished by each, and back-to-back
// grants happened in both directions (B right after A, and A right after B), so the case was really
// exercised. The bench prints a summary line and then PASS or FAIL. The values of the lines are not
// checked here; tb_spectrum_pipeline.v and sim/zoom/tb_zoom_backend_quick.v do that.
//
// How to run: from the repository root, `iverilog -g2012 -o tb.vvp sim/spectrum/tb_spectrum_two_ctx.v`
// and `vvp tb.vvp`.

`timescale 1ns / 1ps
`include "rtl/spectrum/spectrum_pipeline.v"
module tb_spectrum_two_ctx;
    // Half period 3.333 ns makes a 6.666 ns period, the 150 MHz DSP clock of the chip.
    reg clk = 1'b0; always #3.333 clk = ~clk;
    reg rst = 1'b1;
    // Full-band ADC input (12 bit), the register ports of the full-band side (reg_*) and of the zoom side
    // (zreg_*), their line-done interrupts and line read ports, and the waterfall byte streams.
    reg signed [11:0] adc_data = 0; reg adc_valid = 0;
    reg reg_wr = 0, reg_rd = 0; reg [15:0] reg_addr = 0; reg [31:0] reg_wdata = 0; wire [31:0] reg_rdata;
    reg zreg_wr = 0, zreg_rd = 0; reg [15:0] zreg_addr = 0; reg [31:0] zreg_wdata = 0; wire [31:0] zreg_rdata;
    wire irq, zirq; wire [15:0] lrd, zlrd;
    wire wf_valid, wf_sol, wf_eol, zwf_valid, zwf_sol, zwf_eol; wire [7:0] wf_data, zwf_data;
    // Zoom input: one complex bin per clock (29-bit re and im) with its bin number, a first-bin marker and
    // a flag that says whether the bin lies inside the usable part of the span.
    reg zoom_in_valid = 0, zoom_in_first = 0, zoom_in_usable = 0; reg [11:0] zoom_in_bin = 0;
    reg signed [28:0] zoom_in_re = 0, zoom_in_im = 0;
    // Both contexts of the DUT are connected; the line buffer read ports stay at address 0 because only the
    // order of the columns is looked at, through the internal line writer.
    spectrum_pipeline dut (
        .clk(clk), .rst(rst), .adc_data(adc_data), .adc_valid(adc_valid),
        .reg_wr(reg_wr), .reg_rd(reg_rd), .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_rdata(reg_rdata),
        .irq_line_done(irq), .line_rd_addr(11'd0), .line_rd_data(lrd),
        .wf_valid(wf_valid), .wf_sol(wf_sol), .wf_eol(wf_eol), .wf_data(wf_data),
        .zoom_in_valid(zoom_in_valid), .zoom_in_first(zoom_in_first), .zoom_in_bin(zoom_in_bin),
        .zoom_in_usable(zoom_in_usable), .zoom_in_re(zoom_in_re), .zoom_in_im(zoom_in_im),
        .zreg_wr(zreg_wr), .zreg_rd(zreg_rd), .zreg_addr(zreg_addr), .zreg_wdata(zreg_wdata), .zreg_rdata(zreg_rdata),
        .zirq_line_done(zirq), .zline_rd_addr(11'd0), .zline_rd_data(zlrd),
        .zwf_valid(zwf_valid), .zwf_sol(zwf_sol), .zwf_eol(zwf_eol), .zwf_data(zwf_data));
    // The FFT delivers its bins in bit-reversed order; this gives the bin number of the idx-th output of a
    // 4,096-point frame.
    function integer bitrev12(input integer x); integer b; begin bitrev12 = 0; for (b = 0; b < 12; b = b + 1) if (x & (1 << b)) bitrev12 = bitrev12 | (1 << (11 - b)); end endfunction
    // expa and expb are the next column each context must write, erra and errb count order errors, nla and
    // nlb count finished lines, bafter and aafter count grants that came within 2 clocks of the end of the
    // other context's walk, and since counts the clocks since the engine was last busy.
    integer seed = 7, i, f, idx, bin;
    integer expa = 0, expb = 0, erra = 0, errb = 0, nla = 0, nlb = 0, bafter = 0, aafter = 0, since = 99;
    reg last_ctx = 0;
    initial begin
    // Release reset, then set up both sides with an averaging K of 1 so that a line completes after one
    // frame: the full-band side gets averaging_k = 1 and enable with column mode mean (control word 3), the
    // zoom side gets averaging_k = 1 and its backend column mode set to mean (bit 4 of its control word).
        repeat (5) @(posedge clk); rst = 0; repeat (5) @(posedge clk);
        @(posedge clk); #1; reg_addr = 16'h0008; reg_wdata = 1; reg_wr = 1; @(posedge clk); #1; reg_wr = 0;
        @(posedge clk); #1; reg_addr = 16'h0004; reg_wdata = 3; reg_wr = 1; @(posedge clk); #1; reg_wr = 0;
        @(posedge clk); #1; zreg_addr = `ZOOM_BACKEND_AVERAGING_K_ADDR; zreg_wdata = 1; zreg_wr = 1; @(posedge clk); #1; zreg_wr = 0;
        @(posedge clk); #1; zreg_addr = `ZOOM_CTRL_ADDR; zreg_wdata = 32'h10; zreg_wr = 1; @(posedge clk); #1; zreg_wr = 0;
    end
    // Full-band stream: a new random sample (about -399 to 399, well inside the 12-bit range) on every clock.
    always @(posedge clk) begin adc_valid <= !rst; adc_data <= $random(seed) % 400; end
    initial begin
    // Let the full-band side get going, then feed 12 zoom frames of 4,096 bins each, in bit-reversed bin
    // order with the usable range of 3,277 bins marked (bins up to 1,638 and the 1,638 at the top), and
    // wait a slightly different time after each frame (3,000 + 37 f clocks) so that the zoom walk lands at
    // different points of the full-band frame cycle.
        repeat (30000) @(posedge clk);
        for (f = 0; f < 12; f = f + 1) begin
            for (idx = 0; idx < 4096; idx = idx + 1) begin
                bin = bitrev12(idx);
                @(posedge clk); #1;
                zoom_in_valid = 1; zoom_in_first = (idx == 0); zoom_in_bin = bin[11:0];
                zoom_in_usable = (bin <= 1638) || (bin >= 4096 - 1638);
                zoom_in_re = $random(seed) % 100000; zoom_in_im = $random(seed) % 100000;
            end
            @(posedge clk); #1; zoom_in_valid = 0;
            repeat (3000 + f * 37) @(posedge clk);
        end
    // Let the last walks finish, then report.
        repeat (5000) @(posedge clk);
    // Pass needs both contexts to have written lines with no order error and the back-to-back grants to
    // have happened in both directions.
        $display("tb_spectrum_two_ctx: lines A %0d B %0d, column-order errors A %0d B %0d, B granted right after A %0d times, A right after B %0d",
                 nla, nlb, erra, errb, bafter, aafter);
        if (erra == 0 && errb == 0 && nla > 0 && nlb > 0 && bafter > 0 && aafter > 0) $display("PASS"); else $display("FAIL");
        $finish;
    end
    // Monitor: each valid column write of a context must be the next one in 0 to 1,919 order (lineA_v and
    // lineB_v are the write strobes, wc_line_col the column being written); the walk engine grants are
    // classified by whether the other context's walk ended 2 clocks or fewer before.
    always @(posedge clk) begin
        if (dut.lineA_v) begin if (dut.wc_line_col != expa) erra = erra + 1; expa = (dut.wc_line_col == 1919) ? 0 : dut.wc_line_col + 1; if (dut.lineA_last) nla = nla + 1; end
        if (dut.lineB_v) begin if (dut.wc_line_col != expb) errb = errb + 1; expb = (dut.wc_line_col == 1919) ? 0 : dut.wc_line_col + 1; if (dut.lineB_last) nlb = nlb + 1; end
        since = dut.wc_busy ? 0 : since + 1;
        if (dut.u_walk.grant_b && since <= 2 && last_ctx == 0) bafter = bafter + 1;
        if (dut.u_walk.grant_a && since <= 2 && last_ctx == 1) aafter = aafter + 1;
        if (dut.u_walk.grant_a) last_ctx = 0; if (dut.u_walk.grant_b) last_ctx = 1;
    end
endmodule
