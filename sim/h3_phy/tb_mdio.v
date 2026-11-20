// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Testbench for the MDIO master rtl/hl2link/mdio_ctrl.v, which the radio uses to talk to the Ethernet PHY chip
// (an RTL8211F, strapped to PHY address 1 on this board, see docs/H3_PHY.md). MDIO is the slow two wire management
// bus of Ethernet (the clock MDC and one shared data line MDIO) through which a PHY's registers are read and written,
// one 32 bit frame per access: a preamble of ones, a start and an opcode field, the PHY address and register
// address, a two bit turnaround and 16 bits of data (IEEE 802.3 clause 22, explained in docs/learn/GLOSSARY.md).
//
// The bench drives mdio_ctrl.v against sim/h3_phy/mdio_phy_model.v, a small register model of the PHY, on one shared
// MDIO line, and reads three registers: 2 and 3 (PHYID1 and PHYID2, which together must be the real RTL8211F
// ID 0x001cc916, docs/H3_PHY.md section 3) and 0 (BMCR, the basic mode control register). The read of register 0
// has to return that register's own value and not the ID again, which shows that the controller really addresses
// different registers and does not replay the first answer it ever saw.
//
// Pass: no read came back without a PHY response, PHYID1 = 0x001c, PHYID2 = 0xc916, BMCR = 0x1140 and BMCR differs
// from PHYID1. It prints the three values, then "PASS", or "FAIL: n errors" after the individual ERROR lines.
//
// Run, from the repo root (the include paths are relative to it):
//   iverilog -g2012 -o build/tb_mdio.vvp sim/h3_phy/tb_mdio.v && vvp build/tb_mdio.vvp

`include "rtl/hl2link/mdio_ctrl.v"
`include "sim/h3_phy/mdio_phy_model.v"

`timescale 1ns / 1ps

module tb_mdio;

    localparam [4:0] PHY_ADDR = 5'd1;

    logic clk = 1'b0;
    always #4 clk = ~clk;   // 125 MHz; MDC_DIV below divides it down for MDC

    logic rst = 1'b1;

    logic        start   = 1'b0;
    logic        rd_wrn  = 1'b1;
    logic [4:0]  reg_addr = 5'd0;
    logic [15:0] wr_data  = 16'd0;
    wire  [15:0] rd_data;
    wire         busy, done, no_response;

    wire mdc, mdio_ctrl_out, mdio_ctrl_oe, mdio_line;
    wire mdio_phy_out, mdio_phy_oe;

    // The shared MDIO line: whichever side enables its driver drives it, and when neither does it floats high, as the
    // board's external pull-up makes it (R70 in the dock schematic, docs/H3_PHY.md section 1).
    assign mdio_line = mdio_ctrl_oe ? mdio_ctrl_out : (mdio_phy_oe ? mdio_phy_out : 1'b1);

    // MDC_DIV = 4 makes MDC 125 MHz / (2 * 4) = 15.6 MHz, much faster than the 1.25 MHz the real design uses and above the
    // 2.5 MHz limit of clause 22, which is fine in simulation and keeps each frame short.
    mdio_ctrl #(.MDC_DIV(4)) dut (
        .clk(clk), .rst(rst),
        .start(start), .rd_wrn(rd_wrn), .phy_addr(PHY_ADDR), .reg_addr(reg_addr), .wr_data(wr_data),
        .rd_data(rd_data), .busy(busy), .done(done), .no_response(no_response),
        .mdc(mdc), .mdio_out(mdio_ctrl_out), .mdio_oe(mdio_ctrl_oe), .mdio_in(mdio_line)
    );

    mdio_phy_model #(.MY_ADDR(PHY_ADDR)) phy_i (
        .mdc(mdc), .mdio_in(mdio_line), .mdio_out(mdio_phy_out), .mdio_oe(mdio_phy_oe)
    );

    integer errors = 0;
    `define CHECK(cond, msg) if ((cond) !== 1'b1) begin errors = errors + 1; $display("ERROR t=%0t: %s", $time, msg); end

    // One read through the controller: loads the register address, pulses `start`, waits for `done`, and returns the data
    // and the no-response flag (set when the PHY never answered the turnaround).
    task automatic mdio_read(input [4:0] addr, output [15:0] data, output bit no_resp);
        begin
            @(posedge clk);
            reg_addr <= addr;
            rd_wrn   <= 1'b1;
            start    <= 1'b1;
            @(posedge clk);
            start <= 1'b0;
            wait (done);
            data    = rd_data;
            no_resp = no_response;
            @(posedge clk);
        end
    endtask

    logic [15:0] got_id1, got_id0, got_bmcr;
    logic        nr1, nr0, nrb;

    initial begin
        // Reset is released at 23 ns, off the 8 ns clock grid.
        #23;
        rst = 1'b0;
        #40;

        // Registers 2, 3 and 0, in that order.
        mdio_read(5'd2, got_id1, nr1);
        mdio_read(5'd3, got_id0, nr0);
        mdio_read(5'd0, got_bmcr, nrb);

        `CHECK(!nr1, "no PHY response reading register 2 (PHYID1)")
        `CHECK(!nr0, "no PHY response reading register 3 (PHYID2)")
        `CHECK(!nrb, "no PHY response reading register 0 (BMCR)")
        // The ID is the 32 bit value 0x001cc916 split over the two registers.
        `CHECK(got_id1 == 16'h001c, $sformatf("PHYID1 = %h, expected 001c", got_id1))
        `CHECK(got_id0 == 16'hc916, $sformatf("PHYID2 = %h, expected c916", got_id0))
        `CHECK({got_id1, got_id0} == 32'h001cc916,
               $sformatf("combined PHY ID = %h, expected the real RTL8211F ID 001cc916", {got_id1, got_id0}))
        // BMCR is a different register with its own value, so this shows that the controller addresses register 0 and
        // does not just replay the last answer it saw.
        `CHECK(got_bmcr == 16'h1140, $sformatf("BMCR = %h, expected 1140", got_bmcr))
        `CHECK(got_bmcr != got_id1, "BMCR read back the same value as PHYID1 -- register address is not taking effect")

        $display("PHYID1=%h PHYID2=%h BMCR=%h", got_id1, got_id0, got_bmcr);

        if (errors == 0) $display("PASS");
        else $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule
