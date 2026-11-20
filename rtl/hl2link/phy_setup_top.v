// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Start-up of the RTL8211F Ethernet PHY chip on the RJ45 socket. Not used in the current design:
// the HL2 link no longer runs over RGMII, the RJ45 PHY is driven by rtl/net/net_unit.v (MDIO and
// reset live in its eth_top.v), and eth_clk_pll.v's output 0 is now 100 MHz instead of the 125 MHz
// this module expects (docs/HL2_SFP.md section 9). It is kept together with the other RGMII pieces
// for a board that wires the HL2 link to an RGMII PHY (docs/H3_PHY.md).
//
// It ties together:
//   eth_clk_pll.v    the clocks for the PHY (originally 125 MHz for RGMII and 25 MHz for the PHY's
//                    reference input, from the board's 50 MHz oscillator)
//   phy_reset_seq.v  reset hold and post-reset settle time of the PHY (docs/H3_PHY.md section 2)
//   mdio_ctrl.v      the clause 22 master that reads the PHY's registers
// and, once `phy_ready`, reads the PHY ID registers 2 and 3 (PHYID1 and PHYID2) once as a bring-up
// check. The two 16-bit halves are assembled into `phy_id`, and `phy_id_valid` says whether it
// matches the ID of the RTL8211F (0x001cc916, docs/H3_PHY.md section 3). If the chip does not
// answer at all (open bus, wrong address), `phy_no_response` is set. The outputs are flat status
// signals for firmware to read.
//
// The RGMII delay is not configured here. Both delays the PHY needs (2 ns on TXC before TXD is
// latched, and 2 ns on RXC before it reaches the MAC) are enabled by the board's strap pins
// (docs/H3_PHY.md section 1), so there is nothing to write. A wrong strap would still answer
// MDIO reads, so the ID read proves only that the management bus works, and a wrong delay would
// show up as CRC errors on real traffic.

`timescale 1ns / 1ps

module phy_setup_top #(
    parameter [4:0] PHY_ADDR = 5'd1   // strapped on this board (docs/H3_PHY.md section 1)
) (
    input  wire clk_in,      // 50 MHz board oscillator
    input  wire rst,         // power-on reset, active high

    output wire clk_125,     // to an RGMII transmitter / this repo's clk_tx elsewhere in the chip
    output wire phy_clk,     // EPHY_CLK, pin E18
    output wire phy_rst_n,   // EPHY_~{RST}, pin E17

    output wire phy_mdc,     // RGMII_MDC, pin K23
    output wire phy_mdio_out,
    output wire phy_mdio_oe,
    input  wire phy_mdio_in, // RGMII_MDIO, pin K22 (tristate at the top-level pin instantiation)

    output reg  [31:0] phy_id,           // {PHYID1, PHYID2} as read from registers 2 and 3
    output reg          phy_id_valid,   // phy_id == RTL8211F_ID
    output reg          phy_id_done,    // the read completed (id_valid tells whether it matched)
    output reg          phy_no_response // the PHY never acknowledged a read
);

    localparam [31:0] RTL8211F_ID = 32'h001c_c916;   // docs/H3_PHY.md section 3

    wire pll_locked;
    eth_clk_pll pll_i (
        .clk_in(clk_in), .clk_100(clk_125), .clk_25(phy_clk), .locked(pll_locked)
    );

    wire seq_ready;
    phy_reset_seq reset_seq_i (
        .clk(clk_125), .rst(rst), .clk_ref_ok(pll_locked),
        .phy_rst_n(phy_rst_n), .phy_ready(seq_ready)
    );

    reg         mdio_start = 1'b0;
    reg  [4:0]  mdio_reg   = 5'd2;
    wire [15:0] mdio_rd_data;
    wire        mdio_busy, mdio_done, mdio_no_resp;

    mdio_ctrl mdio_i (
        .clk(clk_125), .rst(rst),
        .start(mdio_start), .rd_wrn(1'b1), .phy_addr(PHY_ADDR), .reg_addr(mdio_reg), .wr_data(16'd0),
        .rd_data(mdio_rd_data), .busy(mdio_busy), .done(mdio_done), .no_response(mdio_no_resp),
        .mdc(phy_mdc), .mdio_out(phy_mdio_out), .mdio_oe(phy_mdio_oe), .mdio_in(phy_mdio_in)
    );

    // Sequence: wait until the PHY is ready, read register 2 (upper half of the ID), read
    // register 3 (lower half), then compare with the expected ID once.
    localparam S_IDLE = 2'd0, S_REG2 = 2'd1, S_REG3 = 2'd2, S_DONE = 2'd3;
    reg [1:0] state = S_IDLE;

    always @(posedge clk_125) begin
        mdio_start <= 1'b0;
        if (rst) begin
            state           <= S_IDLE;
            phy_id          <= 32'd0;
            phy_id_valid    <= 1'b0;
            phy_id_done     <= 1'b0;
            phy_no_response <= 1'b0;
        end else begin
            case (state)
                S_IDLE: if (seq_ready && !mdio_busy) begin
                    mdio_reg   <= 5'd2;
                    mdio_start <= 1'b1;
                    state      <= S_REG2;
                end

                S_REG2: if (mdio_done) begin
                    phy_id[31:16]   <= mdio_rd_data;
                    phy_no_response <= mdio_no_resp;
                    mdio_reg        <= 5'd3;
                    mdio_start      <= 1'b1;
                    state           <= S_REG3;
                end

                S_REG3: if (mdio_done) begin
                    phy_id[15:0]    <= mdio_rd_data;
                    phy_no_response <= phy_no_response | mdio_no_resp;
                    state           <= S_DONE;
                end

                S_DONE: begin
                    // `phy_id` was fully assembled (both halves) on the change into this state,
                    // one clock ago, so it is read back here and not `mdio_rd_data` again, which
                    // mdio_ctrl.v is free to have already changed on a later transaction.
                    phy_id_done  <= 1'b1;
                    phy_id_valid <= (phy_id == RTL8211F_ID) && !phy_no_response;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
