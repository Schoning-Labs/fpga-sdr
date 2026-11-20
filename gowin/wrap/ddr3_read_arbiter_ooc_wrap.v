// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ddr3_read_arbiter_ooc_wrap: a measurement wrapper that puts ddr3_read_arbiter alone into a chip, to find out how much logic it needs and how
// fast it can run. It is not part of the radio.
//
// WHY A WRAPPER IS NEEDED
// Gowin's place-and-route has no out-of-context mode (the closest project option, `set_option -disable_io_insertion`,
// still assigns one package pin per port). ddr3_read_arbiter alone has 230 input bits and 313 output bits (without clk and
// rst), which is 545 top-level pins with clk and rst, and the chip has only 312 user I/O pins (docs/BOARD.md, of which
// the tool accepts 292 as ordinary ports), so a direct run could not be placed. Pins pulled apart over the whole die would
// also make the routing to the pads the critical path, which says nothing about the block.
//
// HOW IT WORKS
// Every port of ddr3_read_arbiter except clk and rst sits on one of two shift chains clocked by clk, so place-and-route sees only
// six top-level pins (clk, rst, si, in_shift, so, out_shift) and every path it times runs from register to register.
//   input chain   (in_chain, 230 bits) holds the value of every input port. With in_shift high one bit of `si` is
//                 shifted in per clock, and with in_shift low the chain holds its value and drives the inputs of the
//                 block. To apply a test vector, shift in 230 bits and then stop.
//   output chain  (out_chain, 313 bits) takes a snapshot of all the output ports every clock while out_shift is low,
//                 and shifts that snapshot out on `so`, most significant bit first, while out_shift is high.
// The only cost is 230 + 313 flip-flops and a small multiplexer in front of each output flip-flop, with no DSP or
// block RAM, so the figures of the wrapper alone can be subtracted from the figures of the whole run. The method is
// described in the header of gowin/gen_wrap.py, which writes this kind of wrapper automatically; this one was written by
// hand. Run it with gowin/res.sh (see its header).
`timescale 1ns / 1ps

module ddr3_read_arbiter_ooc_wrap (
    input  wire clk,  // clock for the wrapper and the block, any frequency (the run sets it)
    input  wire rst,  // reset, high = reset; clears both chains and resets the block
    input  wire si,        // serial data into the input chain
    input  wire in_shift,  // 1 = shift si in; 0 = hold (drives the DUT's inputs)
    output wire so,        // serial data out of the output chain
    input  wire out_shift  // 1 = shift captured outputs out; 0 = capture the DUT's outputs
);
    // IN_BITS: the block's input bits, OUT_BITS: its output bits (the sums of the port widths of ddr3_read_arbiter)
    localparam IN_BITS  = 230;
    localparam OUT_BITS = 313;

    // Input chain: shifts `si` in while in_shift is high, holds otherwise; bit 0 is the first bit of the layout below.
    reg [IN_BITS-1:0] in_chain;
    always @(posedge clk or posedge rst)
        if (rst) in_chain <= {IN_BITS{1'b0}};
        else if (in_shift) in_chain <= {in_chain[IN_BITS-2:0], si};

    // The input chain cut into the block's input ports, in port order: for each of the four clients (video, audio, tx,
    // rest) its request, a 32-bit address and an 8-bit burst length, then the lane's valid, 64-bit data and ready.
    wire video_req = in_chain[0];
    wire [31:0] video_addr = in_chain[32:1];
    wire [7:0] video_burstlen = in_chain[40:33];
    wire audio_req = in_chain[41];
    wire [31:0] audio_addr = in_chain[73:42];
    wire [7:0] audio_burstlen = in_chain[81:74];
    wire tx_req = in_chain[82];
    wire [31:0] tx_addr = in_chain[114:83];
    wire [7:0] tx_burstlen = in_chain[122:115];
    wire rest_req = in_chain[123];
    wire [31:0] rest_addr = in_chain[155:124];
    wire [7:0] rest_burstlen = in_chain[163:156];
    wire rd_valid_lane5 = in_chain[164];
    wire [63:0] rd_data_lane5 = in_chain[228:165];
    wire rd_rdy_lane5 = in_chain[229];

    // The block's outputs.
    wire video_gnt;
    wire video_rvalid;
    wire [63:0] video_rdata;
    wire video_done;
    wire audio_gnt;
    wire audio_rvalid;
    wire [63:0] audio_rdata;
    wire audio_done;
    wire tx_gnt;
    wire tx_rvalid;
    wire [63:0] tx_rdata;
    wire tx_done;
    wire rest_gnt;
    wire rest_rvalid;
    wire [63:0] rest_rdata;
    wire rest_done;
    wire [31:0] addr_lane5;
    wire rd_en_lane5;
    wire rd_go_lane5;
    wire [7:0] burstcount_lane5;
    wire [2:0] owner;

    // All outputs in one vector, the first named in the most significant bits.
    wire [OUT_BITS-1:0] dut_out = {owner, burstcount_lane5, rd_go_lane5, rd_en_lane5, addr_lane5, rest_done, rest_rdata, rest_rvalid, rest_gnt, tx_done, tx_rdata, tx_rvalid, tx_gnt, audio_done, audio_rdata, audio_rvalid, audio_gnt, video_done, video_rdata, video_rvalid, video_gnt};

    // Output chain: captures dut_out every clock while out_shift is low, shifts it out toward `so` while it is high.
    reg [OUT_BITS-1:0] out_chain;
    always @(posedge clk or posedge rst)
        if (rst) out_chain <= {OUT_BITS{1'b0}};
        else if (out_shift) out_chain <= {out_chain[OUT_BITS-2:0], 1'b0};
        else out_chain <= dut_out;
    assign so = out_chain[OUT_BITS-1];

    // The block under measurement.
    ddr3_read_arbiter u_dut (
        .clk(clk),
        .rst(rst),
        .video_req(video_req),
        .video_addr(video_addr),
        .video_burstlen(video_burstlen),
        .audio_req(audio_req),
        .audio_addr(audio_addr),
        .audio_burstlen(audio_burstlen),
        .tx_req(tx_req),
        .tx_addr(tx_addr),
        .tx_burstlen(tx_burstlen),
        .rest_req(rest_req),
        .rest_addr(rest_addr),
        .rest_burstlen(rest_burstlen),
        .rd_valid_lane5(rd_valid_lane5),
        .rd_data_lane5(rd_data_lane5),
        .rd_rdy_lane5(rd_rdy_lane5),
        .video_gnt(video_gnt),
        .video_rvalid(video_rvalid),
        .video_rdata(video_rdata),
        .video_done(video_done),
        .audio_gnt(audio_gnt),
        .audio_rvalid(audio_rvalid),
        .audio_rdata(audio_rdata),
        .audio_done(audio_done),
        .tx_gnt(tx_gnt),
        .tx_rvalid(tx_rvalid),
        .tx_rdata(tx_rdata),
        .tx_done(tx_done),
        .rest_gnt(rest_gnt),
        .rest_rvalid(rest_rvalid),
        .rest_rdata(rest_rdata),
        .rest_done(rest_done),
        .addr_lane5(addr_lane5),
        .rd_en_lane5(rd_en_lane5),
        .rd_go_lane5(rd_go_lane5),
        .burstcount_lane5(burstcount_lane5),
        .owner(owner)
    );
endmodule
