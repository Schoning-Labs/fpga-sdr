// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// rx_backend_ooc_wrap: a measurement wrapper that puts rx_backend alone into a chip, to find out how much logic it needs and how
// fast it can run. It is not part of the radio.
//
// WHY A WRAPPER IS NEEDED
// Gowin's place-and-route has no out-of-context mode (the closest project option, `set_option -disable_io_insertion`,
// still assigns one package pin per port). rx_backend alone has 152 input bits and 231 output bits (without clk and
// rst), which is 385 top-level pins with clk and rst, and the chip has only 312 user I/O pins (docs/BOARD.md, of which
// the tool accepts 292 as ordinary ports), so a direct run could not be placed. Pins pulled apart over the whole die would
// also make the routing to the pads the critical path, which says nothing about the block.
//
// HOW IT WORKS
// Every port of rx_backend except clk and rst sits on one of two shift chains clocked by clk, so place-and-route sees only
// six top-level pins (clk, rst, si, in_shift, so, out_shift) and every path it times runs from register to register.
//   input chain   (in_chain, 152 bits) holds the value of every input port. With in_shift high one bit of `si` is
//                 shifted in per clock, and with in_shift low the chain holds its value and drives the inputs of the
//                 block. To apply a test vector, shift in 152 bits and then stop.
//   output chain  (out_chain, 231 bits) takes a snapshot of all the output ports every clock while out_shift is low,
//                 and shifts that snapshot out on `so`, most significant bit first, while out_shift is high.
// The only cost is 152 + 231 flip-flops and a small multiplexer in front of each output flip-flop, with no DSP or
// block RAM, so the figures of the wrapper alone can be subtracted from the figures of the whole run. The method is
// described in the header of gowin/gen_wrap.py, which writes this kind of wrapper automatically; this one was written by
// hand. Run it with gowin/res.sh (see its header).
`timescale 1ns / 1ps

module rx_backend_ooc_wrap (
    input  wire clk,  // clock for the wrapper and the block, any frequency (the run sets it)
    input  wire rst,  // reset, high = reset; clears both chains and resets the block
    input  wire si,        // serial data into the input chain
    input  wire in_shift,  // 1 = shift si in; 0 = hold (drives the DUT's inputs)
    output wire so,        // serial data out of the output chain
    input  wire out_shift  // 1 = shift captured outputs out; 0 = capture the DUT's outputs
);
    // IN_BITS: the block's input bits, OUT_BITS: its output bits (the sums of the port widths of rx_backend)
    localparam IN_BITS  = 152;
    localparam OUT_BITS = 231;

    // Input chain: shifts `si` in while in_shift is high, holds otherwise; bit 0 is the first bit of the layout below.
    reg [IN_BITS-1:0] in_chain;
    always @(posedge clk or posedge rst)
        if (rst) in_chain <= {IN_BITS{1'b0}};
        else if (in_shift) in_chain <= {in_chain[IN_BITS-2:0], si};

    // The input chain cut into the block's input ports, in port order: the sample stream from the receiver bank (valid,
    // receiver index, 24-bit I and Q), the HL2 frame index, the register bus (write and read strobes, 16-bit address,
    // 32-bit write data) and the two answers of the DDR3 write arbiter (grant and done).
    wire in_valid = in_chain[0];
    wire [2:0] in_index = in_chain[3:1];
    wire [23:0] in_i = in_chain[27:4];
    wire [23:0] in_q = in_chain[51:28];
    wire [47:0] hl2_index = in_chain[99:52];
    wire reg_wr = in_chain[100];
    wire reg_rd = in_chain[101];
    wire [15:0] reg_addr = in_chain[117:102];
    wire [31:0] reg_wdata = in_chain[149:118];
    wire ring_gnt = in_chain[150];
    wire ring_done = in_chain[151];

    // The block's outputs.
    wire [31:0] reg_rdata;
    wire out_valid;
    wire [2:0] out_rx;
    wire [15:0] out_s0;
    wire [15:0] out_s1;
    wire out_iq;
    wire [47:0] out_stamp;
    wire ring_req;
    wire [31:0] ring_addr;
    wire [7:0] ring_burstlen;
    wire [63:0] ring_wdata;
    wire [7:0] ring_wmask;
    wire irq;

    // All outputs in one vector, the first named in the most significant bits.
    wire [OUT_BITS-1:0] dut_out = {irq, ring_wmask, ring_wdata, ring_burstlen, ring_addr, ring_req, out_stamp, out_iq, out_s1, out_s0, out_rx, out_valid, reg_rdata};

    // Output chain: captures dut_out every clock while out_shift is low, shifts it out toward `so` while it is high.
    reg [OUT_BITS-1:0] out_chain;
    always @(posedge clk or posedge rst)
        if (rst) out_chain <= {OUT_BITS{1'b0}};
        else if (out_shift) out_chain <= {out_chain[OUT_BITS-2:0], 1'b0};
        else out_chain <= dut_out;
    assign so = out_chain[OUT_BITS-1];

    // The block under measurement.
    rx_backend u_dut (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .in_index(in_index),
        .in_i(in_i),
        .in_q(in_q),
        .hl2_index(hl2_index),
        .reg_wr(reg_wr),
        .reg_rd(reg_rd),
        .reg_addr(reg_addr),
        .reg_wdata(reg_wdata),
        .ring_gnt(ring_gnt),
        .ring_done(ring_done),
        .reg_rdata(reg_rdata),
        .out_valid(out_valid),
        .out_rx(out_rx),
        .out_s0(out_s0),
        .out_s1(out_s1),
        .out_iq(out_iq),
        .out_stamp(out_stamp),
        .ring_req(ring_req),
        .ring_addr(ring_addr),
        .ring_burstlen(ring_burstlen),
        .ring_wdata(ring_wdata),
        .ring_wmask(ring_wmask),
        .irq(irq)
    );
endmodule
