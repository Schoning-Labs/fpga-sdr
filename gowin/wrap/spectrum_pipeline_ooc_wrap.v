// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// spectrum_pipeline_ooc_wrap: a measurement wrapper that puts spectrum_pipeline alone into a chip, to find out how much
// logic it needs and how fast it can run. It is not part of the radio.
//
// WHY A WRAPPER IS NEEDED
// Gowin's place-and-route has no out-of-context mode. spectrum_pipeline has the full-band ports and, on top of them, the
// zoom back end (the zoom_in_*, zreg_*, zline_* and zwf_* ports), which takes the total to 316 ports (208 input bits and
// 120 output bits, without clk and rst). That is more than the 292 ordinary user I/O ports the tool accepts on the
// GW5AST-138 (312 pins in the package, docs/BOARD.md), and a direct run stops with an error that the number of ports
// exceeds the resource limit.
//
// HOW IT WORKS
// Every port of spectrum_pipeline except clk and rst sits on one of two shift chains clocked by clk, so place-and-route
// sees only six top-level pins (clk, rst, si, in_shift, so, out_shift) and every path it times runs from register to
// register. This is the same technique as gowin/wrap/rx_backend_ooc_wrap.v and the DDR3 arbiter wrappers.
//   input chain   (in_chain, 208 bits) holds the value of every input port: shifted in from `si` while in_shift is
//                 high, held while it is low, and then driving the inputs of the block.
//   output chain  (out_chain, 120 bits) takes a snapshot of all outputs every clock while out_shift is low, and shifts
//                 it out on `so`, most significant bit first, while out_shift is high.
// The chains cost 208 + 120 flip-flops and a small multiplexer per output bit, with no DSP or block RAM, so the figures
// of the wrapper alone can be subtracted from the figures of the whole run. The rtl file is included below so that the
// wrapper can be run as one source (see gowin/res.sh).
`timescale 1ns / 1ps

`include "rtl/spectrum/spectrum_pipeline.v"

module spectrum_pipeline_ooc_wrap (
    input  wire clk,  // clock for the wrapper and the block, any frequency (the run sets it)
    input  wire rst,  // reset, high = reset; clears both chains and resets the block
    input  wire si,        // serial data into the input chain
    input  wire in_shift,  // 1 = shift si in; 0 = hold (drives the DUT's inputs)
    output wire so,        // serial data out of the output chain
    input  wire out_shift  // 1 = shift captured outputs out; 0 = capture the DUT's outputs
);
    // IN_BITS: the block's input bits, OUT_BITS: its output bits (the sums of the port widths of spectrum_pipeline)
    localparam IN_BITS  = 208;
    localparam OUT_BITS = 120;

    // Input chain: shifts `si` in while in_shift is high, holds otherwise; bit 0 is the first bit of the layout below.
    reg [IN_BITS-1:0] in_chain;
    always @(posedge clk or posedge rst)
        if (rst) in_chain <= {IN_BITS{1'b0}};
        else if (in_shift) in_chain <= {in_chain[IN_BITS-2:0], si};

    // The input chain cut into the block's input ports, in port order. The full-band side: the 12-bit signed ADC
    // sample and its valid, the register bus (write and read strobes, 16-bit address, 32-bit write data) and the read
    // address of the spectrum line buffer (11 bits).
    wire signed [11:0] adc_data       = in_chain[11:0];
    wire               adc_valid      = in_chain[12];
    wire               reg_wr         = in_chain[13];
    wire               reg_rd         = in_chain[14];
    wire [15:0]        reg_addr       = in_chain[30:15];
    wire [31:0]        reg_wdata      = in_chain[62:31];
    wire [10:0]        line_rd_addr   = in_chain[73:63];
    // The zoom side: the zoom bin stream (valid, first-bin flag, 12-bit bin number, usable flag, and the 29-bit signed
    // real and imaginary parts), then the zoom's own register bus and the read address of its line buffer.
    wire               zoom_in_valid  = in_chain[74];
    wire               zoom_in_first  = in_chain[75];
    wire [11:0]        zoom_in_bin    = in_chain[87:76];
    wire               zoom_in_usable = in_chain[88];
    wire signed [28:0] zoom_in_re     = in_chain[117:89];
    wire signed [28:0] zoom_in_im     = in_chain[146:118];
    wire               zreg_wr        = in_chain[147];
    wire               zreg_rd        = in_chain[148];
    wire [15:0]        zreg_addr      = in_chain[164:149];
    wire [31:0]        zreg_wdata     = in_chain[196:165];
    wire [10:0]        zline_rd_addr  = in_chain[207:197];

    // The block's outputs: for the full-band side the register read data, the line-done interrupt, the line buffer's
    // data and the waterfall byte stream (valid, start and end of line, 8-bit data); then the same for the zoom side.
    wire [31:0] reg_rdata;
    wire        irq_line_done;
    wire [15:0] line_rd_data;
    wire        wf_valid, wf_sol, wf_eol;
    wire [7:0]  wf_data;
    wire [31:0] zreg_rdata;
    wire        zirq_line_done;
    wire [15:0] zline_rd_data;
    wire        zwf_valid, zwf_sol, zwf_eol;
    wire [7:0]  zwf_data;

    // All outputs in one vector, the zoom side first (the most significant bits), then the full-band side.
    wire [OUT_BITS-1:0] dut_out = {
        zwf_data, zwf_eol, zwf_sol, zwf_valid, zline_rd_data, zirq_line_done, zreg_rdata,
        wf_data, wf_eol, wf_sol, wf_valid, line_rd_data, irq_line_done, reg_rdata
    };

    // Output chain: captures dut_out every clock while out_shift is low, shifts it out toward `so` while it is high.
    reg [OUT_BITS-1:0] out_chain;
    always @(posedge clk or posedge rst)
        if (rst) out_chain <= {OUT_BITS{1'b0}};
        else if (out_shift) out_chain <= {out_chain[OUT_BITS-2:0], 1'b0};
        else out_chain <= dut_out;
    assign so = out_chain[OUT_BITS-1];

    // The block under measurement.
    spectrum_pipeline u_dut (
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

endmodule
