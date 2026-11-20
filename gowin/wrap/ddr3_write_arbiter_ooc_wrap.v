// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ddr3_write_arbiter_ooc_wrap: a measurement wrapper that puts ddr3_write_arbiter alone into a chip, to find out how much logic it needs and how
// fast it can run. It is not part of the radio.
//
// WHY A WRAPPER IS NEEDED
// Gowin's place-and-route has no out-of-context mode (the closest project option, `set_option -disable_io_insertion`,
// still assigns one package pin per port). ddr3_write_arbiter alone has 341 input bits and 122 output bits (without clk and
// rst), which is 465 top-level pins with clk and rst, and the chip has only 312 user I/O pins (docs/BOARD.md, of which
// the tool accepts 292 as ordinary ports), so a direct run could not be placed. The three-client form is wrapped here: the ports of
// the three highest tiers (iq, wf, cap) are on the chains and the fourth tier's (ft8) ports are not connected, so the
// figures are those of the arbiter with its lowest tier left out. Pins pulled apart over the whole die would
// also make the routing to the pads the critical path, which says nothing about the block.
//
// HOW IT WORKS
// Every port of ddr3_write_arbiter except clk and rst sits on one of two shift chains clocked by clk, so place-and-route sees only
// six top-level pins (clk, rst, si, in_shift, so, out_shift) and every path it times runs from register to register.
//   input chain   (in_chain, 341 bits) holds the value of every input port. With in_shift high one bit of `si` is
//                 shifted in per clock, and with in_shift low the chain holds its value and drives the inputs of the
//                 block. To apply a test vector, shift in 341 bits and then stop.
//   output chain  (out_chain, 122 bits) takes a snapshot of all the output ports every clock while out_shift is low,
//                 and shifts that snapshot out on `so`, most significant bit first, while out_shift is high.
// The only cost is 341 + 122 flip-flops and a small multiplexer in front of each output flip-flop, with no DSP or
// block RAM, so the figures of the wrapper alone can be subtracted from the figures of the whole run. The method is
// described in the header of gowin/gen_wrap.py, which writes this kind of wrapper automatically; this one was written by
// hand. Run it with gowin/res.sh (see its header).
`timescale 1ns / 1ps

module ddr3_write_arbiter_ooc_wrap (
    input  wire clk,  // clock for the wrapper and the block, any frequency (the run sets it)
    input  wire rst,  // reset, high = reset; clears both chains and resets the block
    input  wire si,        // serial data into the input chain
    input  wire in_shift,  // 1 = shift si in; 0 = hold (drives the DUT's inputs)
    output wire so,        // serial data out of the output chain
    input  wire out_shift  // 1 = shift captured outputs out; 0 = capture the DUT's outputs
);
    // IN_BITS: the block's input bits, OUT_BITS: its output bits (the sums of the port widths as wired below)
    localparam IN_BITS  = 341;
    localparam OUT_BITS = 122;

    // Input chain: shifts `si` in while in_shift is high, holds otherwise; bit 0 is the first bit of the layout below.
    reg [IN_BITS-1:0] in_chain;
    always @(posedge clk or posedge rst)
        if (rst) in_chain <= {IN_BITS{1'b0}};
        else if (in_shift) in_chain <= {in_chain[IN_BITS-2:0], si};

    // The input chain cut into the block's input ports, in port order: for each client (iq, wf, cap) its request, a
    // 32-bit address, an 8-bit burst length, 64-bit data and an 8-bit byte mask, then the lane's wait and done.
    wire iq_req = in_chain[0];
    wire [31:0] iq_addr = in_chain[32:1];
    wire [7:0] iq_burstlen = in_chain[40:33];
    wire [63:0] iq_wdata = in_chain[104:41];
    wire [7:0] iq_wmask = in_chain[112:105];
    wire wf_req = in_chain[113];
    wire [31:0] wf_addr = in_chain[145:114];
    wire [7:0] wf_burstlen = in_chain[153:146];
    wire [63:0] wf_wdata = in_chain[217:154];
    wire [7:0] wf_wmask = in_chain[225:218];
    wire cap_req = in_chain[226];
    wire [31:0] cap_addr = in_chain[258:227];
    wire [7:0] cap_burstlen = in_chain[266:259];
    wire [63:0] cap_wdata = in_chain[330:267];
    wire [7:0] cap_wmask = in_chain[338:331];
    wire wr_wait_lane4 = in_chain[339];
    wire wr_done_lane4 = in_chain[340];

    // The block's outputs.
    wire iq_gnt;
    wire iq_done;
    wire wf_gnt;
    wire wf_done;
    wire cap_gnt;
    wire cap_done;
    wire [31:0] addr_lane4;
    wire [7:0] wr_mask_lane4;
    wire [63:0] wr_data_lane4;
    wire wr_en_lane4;
    wire wr_go_lane4;
    wire [7:0] burstcount_lane4;
    wire [1:0] owner;

    // All outputs in one vector, the first named in the most significant bits.
    wire [OUT_BITS-1:0] dut_out = {owner, burstcount_lane4, wr_go_lane4, wr_en_lane4, wr_data_lane4, wr_mask_lane4, addr_lane4, cap_done, cap_gnt, wf_done, wf_gnt, iq_done, iq_gnt};

    // Output chain: captures dut_out every clock while out_shift is low, shifts it out toward `so` while it is high.
    reg [OUT_BITS-1:0] out_chain;
    always @(posedge clk or posedge rst)
        if (rst) out_chain <= {OUT_BITS{1'b0}};
        else if (out_shift) out_chain <= {out_chain[OUT_BITS-2:0], 1'b0};
        else out_chain <= dut_out;
    assign so = out_chain[OUT_BITS-1];

    // The block under measurement.
    ddr3_write_arbiter u_dut (
        .clk(clk),
        .rst(rst),
        .iq_req(iq_req),
        .iq_addr(iq_addr),
        .iq_burstlen(iq_burstlen),
        .iq_wdata(iq_wdata),
        .iq_wmask(iq_wmask),
        .wf_req(wf_req),
        .wf_addr(wf_addr),
        .wf_burstlen(wf_burstlen),
        .wf_wdata(wf_wdata),
        .wf_wmask(wf_wmask),
        .cap_req(cap_req),
        .cap_addr(cap_addr),
        .cap_burstlen(cap_burstlen),
        .cap_wdata(cap_wdata),
        .cap_wmask(cap_wmask),
        .wr_wait_lane4(wr_wait_lane4),
        .wr_done_lane4(wr_done_lane4),
        .iq_gnt(iq_gnt),
        .iq_done(iq_done),
        .wf_gnt(wf_gnt),
        .wf_done(wf_done),
        .cap_gnt(cap_gnt),
        .cap_done(cap_done),
        .addr_lane4(addr_lane4),
        .wr_mask_lane4(wr_mask_lane4),
        .wr_data_lane4(wr_data_lane4),
        .wr_en_lane4(wr_en_lane4),
        .wr_go_lane4(wr_go_lane4),
        .burstcount_lane4(burstcount_lane4),
        .owner(owner)
    );
endmodule
