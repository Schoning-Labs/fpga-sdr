// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// regbus_leg: one page's own copy of the clk_dsp register bus.
//
// One leg sits between regbus_cdc_dst and each register block in sdr_core.v, so that no bus net is shared
// between two blocks. Without the legs a single set of bus registers in sdr_core.v fed every block of the chip,
// and in that arrangement
// synthesis shared the address decode between blocks, and one decode LUT had 133 loads all over the
// chip, which cost 3.3 ns of routing on that net alone.
//
// The leg only loads on an access to its own page, so the copies of the address and the data in two
// legs are different registers to synthesis (equal registers would be made one, CLAUDE.md), and a
// block sees no bus activity of the other pages at all.
// Timing, in clocks after the one in which regbus_cdc_dst holds d_wr or d_rd high (call that clock 0):
//   clock 1   hit, wr_p and rd_p are loaded (the page compare)
//   clock 2   addr, wdata, wr and rd are loaded: the block sees the strobe two clocks after the bus did
//   ...       the block answers on blk_rdata
//   rdata is blk_rdata one clock later, and 0 while the last access was to another page, so sdr_core.v can
//   simply OR the rdata of all legs together to get the read data of whichever page was addressed.
// d_addr and d_wdata are held by regbus_cdc_dst from clock 0 until the next access (RD_LAT clocks later at the
// earliest), which is why they may be taken one clock after the page compare. addr and wdata then stay until the
// next access to this page, so a block may use them in any clock after the strobe (a block with a registered
// address decode, see block_regs.v, does exactly that).
//
// Gowin specifics (SUG550 GowinSynthesis manual): syn_preserve keeps the hit and act registers from being merged,
// syn_maxfan raises the fan-out limit of the leg's nets, and the load enables are copied by hand, one per 8
// registers, because syn_maxfan does not copy a clock-enable net.

`timescale 1ns / 1ps

// PAGE: the page number (register address bits 23:16) this leg answers to.
module regbus_leg #(
    parameter [7:0] PAGE = 8'h00
) (
    // Clock of the register bus (clk_dsp); the leg has no reset because it holds no state that matters.
    input  wire        clk,
    // from regbus_cdc_dst: the strobes and the full 24-bit address and data of the access
    input  wire        d_wr,
    input  wire        d_rd,
    input  wire [23:0] d_addr,
    input  wire [31:0] d_wdata,
    // to the block: one-clock write and read strobes, the 16-bit offset inside the page, the write data, and the
    // block's answer coming back
    output reg         wr = 1'b0,
    output reg         rd = 1'b0,
    output reg  [15:0] addr = 16'd0,
    output reg  [31:0] wdata = 32'd0,
    input  wire [31:0] blk_rdata,
    // to the page OR in sdr_core.v: the block's read data, or 0 when the last access was to another page
    output reg  [31:0] rdata = 32'd0
) /* synthesis syn_maxfan = 10000 */;

    // match = this access is for this page
    wire match = (d_addr[23:16] == PAGE);
    // hit = copies of "an access to this page is happening", one per 8 data/address bits, so each load enable has
    // only a few loads. act = the same for the read-data gate, one per byte.
    reg [5:0] hit = 6'd0 /* synthesis syn_preserve = 1 */;
    reg [3:0] act = 4'd0 /* synthesis syn_preserve = 1 */;
    // wr_p, rd_p: the strobes one clock early, before they are passed on
    reg       wr_p = 1'b0, rd_p = 1'b0;

    always @(posedge clk) begin
        // the page compare and the strobes
        hit  <= {6{match && (d_wr || d_rd)}};
        wr_p <= match && d_wr;
        rd_p <= match && d_rd;
        wr   <= wr_p;
        rd   <= rd_p;
        // addr and wdata load only when this page is addressed, one byte at a time through its own enable
        if (hit[0]) addr[7:0]    <= d_addr[7:0];
        if (hit[1]) addr[15:8]   <= d_addr[15:8];
        if (hit[2]) wdata[7:0]   <= d_wdata[7:0];
        if (hit[3]) wdata[15:8]  <= d_wdata[15:8];
        if (hit[4]) wdata[23:16] <= d_wdata[23:16];
        if (hit[5]) wdata[31:24] <= d_wdata[31:24];
        // act remembers whether the last access was to this page; read data is passed only while it is
        if (d_wr || d_rd) act <= {4{match}};
        rdata[7:0]   <= act[0] ? blk_rdata[7:0]   : 8'd0;
        rdata[15:8]  <= act[1] ? blk_rdata[15:8]  : 8'd0;
        rdata[23:16] <= act[2] ? blk_rdata[23:16] : 8'd0;
        rdata[31:24] <= act[3] ? blk_rdata[31:24] : 8'd0;
    end

endmodule
