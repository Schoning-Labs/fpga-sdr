// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// zoom_frontend: the zoom receiver as it sits in the chip (docs/ZOOM_IN_CHIP.md, docs/ZOOM_FIT.md). It
// puts together the register block of the zoom DDC (page 0x06, hw/regmap/zoom.toml: id, phase_inc,
// ctrl.enable, ctrl.span_shift, ctrl.narrow_shift, ctrl.narrow_gain), the DDC itself
// (rtl/zoom/zoom_ddc.v), the window (zoom_window.v) and the frame buffer (zoom_frame.v). The terms
// are explained in docs/learn/GLOSSARY.md.
//
// It has no FFT of its own. The zoom uses the whole-band FFT again: rtl/spectrum/spectrum_pipeline.v
// plays each buffered frame of 4,096 windowed samples into the last twelve stages of that FFT
// (fft_r22sdf.v, INJ_S) between two frames of the full-band stream, and hands the bins to its zoom
// context, which owns the other registers of the same page (ctrl bits 4 and 5, backend_*). Both
// modules see the same bus, each answers 0 for what is not its own, and the core ORs the two read words.
//
// A frame here is 4,096 consecutive accepted samples, and the samples that arrive while a complete
// frame waits to be played are dropped (docs/ZOOM_FIT.md section 2). The values are those of
// rtl/zoom/zoom_spectrum.v (DDC, window and a private FFT, kept for the simulations) for every frame.
//
// Register bus: registered once, decoded from the registered copy; read data two clocks after bus_rd,
// held until the next read (as spectrum_pipeline's zoom port). A span_shift of 7 is taken as 6 and a
// narrow_shift above 4 as 4.

`timescale 1ns / 1ps
`include "hw/regmap/generated/zoom_regs.vh"
`ifndef ZOOM_FRAME_V
`define ZOOM_FRAME_V
`include "rtl/zoom/zoom_frame.v"
`endif

module zoom_frontend #(
    parameter TW_DIR = "rtl/fft/tw/"   // not used (the FFT is the spectrum pipeline's)
) (
    input  wire                clk,          // clk_dsp
    input  wire                rst,          // synchronous reset
    input  wire signed [11:0]  adc_data,     // the HL2 sample stream (as the receiver bank's)
    input  wire                adc_valid,    // one-clock pulse per sample
    // register page 0x06
    input  wire                bus_wr,       // write strobe
    input  wire                bus_rd,       // read strobe
    input  wire [15:0]         bus_addr,     // byte address within the page
    input  wire [31:0]         bus_wdata,    // write data
    output reg  [31:0]         bus_rdata,    // read data, two clocks after bus_rd, held
    // frames of 4,096 windowed samples to spectrum_pipeline's zfr_* (rtl/zoom/zoom_frame.v)
    output wire                fr_ready,     // a complete frame waits to be played
    input  wire                fr_go,        // one clock: start playing the frame
    output wire                fr_valid,     // a word of the frame is on fr_re/fr_im
    output wire                fr_last,      // with the last word
    output wire signed [15:0]  fr_re,        // windowed sample, real part
    output wire signed [15:0]  fr_im         // imaginary part
) /* synthesis syn_maxfan = 10000 */;

    // the bus is registered once, and everything below decodes from the registered copy
    reg         wr_r = 1'b0, rd_r = 1'b0;
    reg  [15:0] addr_r = 16'd0;
    reg  [31:0] wdata_r = 32'd0;
    always @(posedge clk) begin
        wr_r    <= bus_wr & ~rst;
        rd_r    <= bus_rd & ~rst;
        addr_r  <= bus_addr;
        wdata_r <= bus_wdata;
    end

    localparam [15:0] A_ID    = `ZOOM_ID_ADDR;
    localparam [15:0] A_PHASE = `ZOOM_PHASE_INC_ADDR;
    localparam [15:0] A_CTRL  = `ZOOM_CTRL_ADDR;

    initial bus_rdata = 32'd0;
    reg [31:0] r_phase = 32'd0;
    reg        r_en = 1'b0;
    reg [2:0]  r_span = 3'd0;
    reg [2:0]  r_narrow = 3'd0;
    reg [1:0]  r_ngain = 2'd0;
    always @(posedge clk) begin
        if (rst) begin
            r_phase <= 32'd0;
            r_en    <= 1'b0;
            r_span  <= 3'd0;
            r_narrow <= 3'd0;
            r_ngain <= 2'd0;
        end else begin
            if (wr_r && addr_r == A_PHASE) r_phase <= wdata_r;
            if (wr_r && addr_r == A_CTRL) begin
                r_en   <= wdata_r[`ZOOM_CTRL_ENABLE_LSB];
                r_span <= (wdata_r[`ZOOM_CTRL_SPAN_SHIFT_MSB:`ZOOM_CTRL_SPAN_SHIFT_LSB] == 3'd7) ? 3'd6
                        :  wdata_r[`ZOOM_CTRL_SPAN_SHIFT_MSB:`ZOOM_CTRL_SPAN_SHIFT_LSB];
                r_narrow <= (wdata_r[`ZOOM_CTRL_NARROW_SHIFT_MSB:`ZOOM_CTRL_NARROW_SHIFT_LSB] > 3'd4) ? 3'd4
                          :  wdata_r[`ZOOM_CTRL_NARROW_SHIFT_MSB:`ZOOM_CTRL_NARROW_SHIFT_LSB];
                r_ngain  <= wdata_r[`ZOOM_CTRL_NARROW_GAIN_MSB:`ZOOM_CTRL_NARROW_GAIN_LSB];
            end
        end
        if (rd_r) begin
            case (addr_r)
                A_ID:    bus_rdata <= `ZOOM_ID_RESET;
                A_PHASE: bus_rdata <= r_phase;
                A_CTRL:  bus_rdata <= {21'd0, r_ngain, r_narrow, 2'd0, r_span, r_en};
                default: bus_rdata <= 32'd0;
            endcase
        end
    end

    // the DDC (sample-rate step by step down to the span), then the window. `take` (from the frame buffer)
    // lets a sample into the window only while the buffer collects, so that the window's frame counter and
    // the buffer stay in step.
    wire               ddc_valid, take;
    wire signed [15:0] ddc_i, ddc_q;
    zoom_ddc #(.ADC_WIDTH(12)) u_ddc (
        .clock(clk), .rst(rst),
        .adc_data(adc_data), .adc_valid(adc_valid),
        .phase_inc(r_phase), .span_shift(r_span), .narrow_shift(r_narrow), .narrow_gain(r_ngain), .enable(r_en),
        .out_valid(ddc_valid), .out_i(ddc_i), .out_q(ddc_q)
    );

    // The window's output is a 16-bit sample times a factor below 1: 16 bits (docs/ZOOM_IN_CHIP.md
    // section 11). The shared FFT takes it with one bit of head-room.
    wire               win_valid;
    wire signed [15:0] win_re, win_im;
    zoom_window #(.N(4096), .IN_WIDTH(16), .OUT_WIDTH(16)) u_win (
        .clock(clk), .rst(rst),
        .in_valid(ddc_valid & take), .in_i(ddc_i), .in_q(ddc_q),
        .out_valid(win_valid), .out_re(win_re), .out_im(win_im)
    );

    zoom_frame #(.LOG_N(12), .W(16)) u_frame (
        .clock(clk), .rst(rst),
        .in_strobe(ddc_valid), .take(take),
        .win_valid(win_valid), .win_re(win_re), .win_im(win_im),
        .ready(fr_ready), .go(fr_go),
        .out_valid(fr_valid), .out_last(fr_last), .out_re(fr_re), .out_im(fr_im)
    );

endmodule
