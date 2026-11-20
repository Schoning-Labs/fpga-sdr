// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// zoom_only: the zoom receiver and the spectrum pipeline with both views active, wired as in rtl/top/sdr_core.v
// (docs/ZOOM_FIT.md), so that the zoom and the display path can be measured alone for size and speed. It is not part
// of the radio itself. The zoom has no FFT of its own: its 4,096-sample frames go through the last stages of the
// full-band FFT inside spectrum_pipeline (parameter ZOOM_SHARED = 1), so the full-band pipeline must be in the run.
// Measured with (from the repository root, see gowin/res.sh):
//   gowin/res.sh zoom_only --wrap --period-ns 7.92 --opt "place_option 3" --opt "route_option 1" \
//       --sdc gowin/wrap/zoom_paths.sdc \
//       rtl/rx/nco_mixer.v rtl/rx/cic_var_shared.v rtl/rx/fir_decim.v rtl/rx/fir_delay_ram2.v rtl/rx/rx_channel.v \
//       rtl/zoom/cic_var_pow2.v rtl/zoom/zoom_fir_half.v rtl/zoom/zoom_cic_comp.v rtl/zoom/zoom_ddc.v \
//       rtl/zoom/zoom_window.v rtl/zoom/zoom_frontend.v rtl/spectrum/spectrum_pipeline.v gowin/wrap/zoom_only.v
// (GOWIN_RUN=syn in front: synthesis only, then tools/gowin_mems.py on the netlist)

`timescale 1ns / 1ps

module zoom_only (
    input  wire               clk,  // clk_dsp, 120 MHz
    input  wire               rst,  // synchronous reset, high = reset
    input  wire signed [11:0] adc_data,  // the HL2 sample stream, 12-bit signed
    input  wire               adc_valid,  // one-clock pulse: adc_data holds a new sample
    input  wire               bus_wr,  // write strobe of the zoom page
    input  wire               bus_rd,  // read strobe of the zoom page
    input  wire [15:0]        bus_addr,  // register address within the page, 16 bits
    input  wire [31:0]        bus_wdata,  // register write data, 32 bits (shared with the full-band page)
    output reg  [31:0]        bus_rdata,  // read data of the zoom page: the OR of the zoom receiver's and the pipeline's zoom registers, registered
    input  wire               fb_wr,  // write strobe of the full-band spectrum page
    input  wire               fb_rd,  // read strobe of the full-band spectrum page
    input  wire [15:0]        fb_addr,  // register address within the full-band page, 16 bits
    output wire [31:0]        fb_rdata,  // read data of the full-band spectrum page
    input  wire [10:0]        line_rd_addr,  // read address into the full-band line buffer, 11 bits
    output wire [15:0]        line_rd_data,  // line data, 16 bits
    output wire               irq_line_done,  // full-band line done interrupt
    output wire               wf_valid,  // full-band waterfall byte stream: a byte is present
    output wire               wf_sol,  // start of a waterfall line
    output wire               wf_eol,  // end of a waterfall line
    output wire [7:0]         wf_data,  // the waterfall byte, 8 bits
    input  wire [10:0]        zline_rd_addr,  // read address into the zoom line buffer, 11 bits
    output wire [15:0]        zline_rd_data,  // zoom line data, 16 bits
    output wire               zirq_line_done,  // zoom line done interrupt
    output wire               zwf_valid,  // zoom waterfall byte stream: a byte is present
    output wire               zwf_sol,  // start of a zoom waterfall line
    output wire               zwf_eol,  // end of a zoom waterfall line
    output wire [7:0]         zwf_data  // the zoom waterfall byte, 8 bits
);
    // rd_fe, rd_be: read data of the zoom receiver and of the pipeline's zoom registers. f_*: the frame interface from
    // the zoom receiver to the pipeline: f_ready (a frame of 4,096 samples waits), f_go (play it), f_valid, f_last
    // (last sample of the frame) and the 16-bit signed samples f_re and f_im.
    wire [31:0] rd_fe, rd_be;
    wire        f_ready, f_go, f_valid, f_last;
    wire signed [15:0] f_re, f_im;

    // The zoom receiver: its registers on the zoom page, and the windowed frames on f_*.
    zoom_frontend u_zoom (
        .clk(clk), .rst(rst), .adc_data(adc_data), .adc_valid(adc_valid),
        .bus_wr(bus_wr), .bus_rd(bus_rd), .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(rd_fe),
        .fr_ready(f_ready), .fr_go(f_go), .fr_valid(f_valid), .fr_last(f_last), .fr_re(f_re), .fr_im(f_im)
    );

    // The spectrum pipeline with the zoom's frames fed through its own FFT (ZOOM_SHARED = 1), so the zoom bin inputs
    // are tied off.
    spectrum_pipeline #(.ZOOM_SHARED(1)) u_spectrum (
        .clk(clk), .rst(rst), .adc_data(adc_data), .adc_valid(adc_valid),
        .reg_wr(fb_wr), .reg_rd(fb_rd), .reg_addr(fb_addr), .reg_wdata(bus_wdata),
        .reg_rdata(fb_rdata), .irq_line_done(irq_line_done),
        .line_rd_addr(line_rd_addr), .line_rd_data(line_rd_data),
        .wf_valid(wf_valid), .wf_sol(wf_sol), .wf_eol(wf_eol), .wf_data(wf_data),
        .zoom_in_valid(1'b0), .zoom_in_first(1'b0), .zoom_in_bin(12'd0),
        .zoom_in_usable(1'b0), .zoom_in_re(29'sd0), .zoom_in_im(29'sd0),
        .zfr_ready(f_ready), .zfr_go(f_go), .zfr_valid(f_valid), .zfr_last(f_last), .zfr_re(f_re), .zfr_im(f_im),
        .zreg_wr(bus_wr), .zreg_rd(bus_rd), .zreg_addr(bus_addr), .zreg_wdata(bus_wdata),
        .zreg_rdata(rd_be), .zirq_line_done(zirq_line_done),
        .zline_rd_addr(zline_rd_addr), .zline_rd_data(zline_rd_data),
        .zwf_valid(zwf_valid), .zwf_sol(zwf_sol), .zwf_eol(zwf_eol), .zwf_data(zwf_data)
    );

    // Both readback words are registered, as the core's read multiplexer does.
    always @(posedge clk) bus_rdata <= rd_fe | rd_be;
endmodule
