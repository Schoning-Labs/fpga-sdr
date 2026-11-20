// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// p1_stubs: placeholder blocks for the chip top level.
//
// A stub is a stand-in for a block that is not finished or not wanted yet: it has the same ports as the real block, so the
// rest of the design can be wired and simulated against it, and it drives every output to an idle value. Replacing a
// stub by the real block is then a module swap in sdr_core.v plus the file list of the build script
// (gowin/p1/build.sh) and of the smoke test (sim/top/tb_sdr_core.v).
// The only stub left in this file is compositor_stub, a stand-in for the video compositor (rtl/video/compositor.v): it has
// the same pixel position input from the HDMI timing, the video tier of the DDR3 read arbiter and the spectrum line buffer
// read ports, and it makes only the frame-start interrupt. The chip does not use it any more, because the real compositor is
// in place; the module stays as the smallest example of the ports a compositor has.

`timescale 1ns / 1ps

// ================================================================================ compositor
// compositor_stub: the idle stand-in of the video compositor, see the header.
module compositor_stub (
    input  wire        clk,            // clk_dsp side of the compositor  // register bus clock side of the compositor, clk_dsp (120 MHz)
    input  wire        rst,  // synchronous reset, high = reset
    input  wire        clk_pix,  // pixel clock, 74.17 MHz
    input  wire [11:0] cx,  // horizontal pixel position from the HDMI timing, in clk_pix
    input  wire [10:0] cy,  // vertical line position from the HDMI timing, in clk_pix
    // video tier of the DDR3 read arbiter: no request is ever made
    output wire        rd_req,  // request, held low
    output wire [31:0] rd_addr,  // address, held at 0
    output wire [7:0]  rd_burstlen,  // burst length, held at 0
    input  wire        rd_gnt,  // grant from the arbiter, unused
    input  wire        rd_rvalid,  // a read data word is valid, unused
    input  wire [63:0] rd_rdata,  // read data, 64 bits, unused
    input  wire        rd_done,  // read burst finished, unused
    // spectrum line buffers (full band and zoom), synchronous read, clk_dsp: addresses held at 0
    output wire [10:0] line_rd_addr,  // read address of the full-band spectrum line buffer, 11 bits
    input  wire [15:0] line_rd_data,  // data from the full-band line buffer, 16 bits, unused
    output wire [10:0] zline_rd_addr,  // read address of the zoom spectrum line buffer, 11 bits
    input  wire [15:0] zline_rd_data,  // data from the zoom line buffer, 16 bits, unused
    // frame start, one clk_dsp pulse per frame (interrupt line 8)
    output reg         frame_start
);
    // all memory requests and buffer reads idle
    assign rd_req = 1'b0; assign rd_addr = 32'd0; assign rd_burstlen = 8'd0;
    assign line_rd_addr = 11'd0; assign zline_rd_addr = 11'd0;
    // frame start: a toggle in clk_pix at the first pixel of each frame, carried into clk through a three-register synchronizer
    // (the toggle is used because a one-clock pulse in the faster or slower clock could be missed); each change of the toggle
    // seen in clk becomes one clock of frame_start
    reg tog_pix = 1'b0;
    always @(posedge clk_pix) if (cx == 12'd0 && cy == 11'd0) tog_pix <= ~tog_pix;
    // the three synchronizer registers, kept as they are by the tool
    (* preserve *) reg [2:0] s = 3'b000;
    // frame_start is high for one clk_dsp clock whenever the synchronized toggle has changed
    always @(posedge clk) begin
        s <= {s[1:0], tog_pix};
        frame_start <= s[2] ^ s[1];
    end
endmodule

