// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Reset sequencer for the RTL8211F Ethernet PHY chip on the RJ45 socket. Not used in the current
// design, where the RJ45 PHY is driven by rtl/net/net_unit.v (docs/HL2_SFP.md section 9), and kept
// together with the other RGMII pieces for a board that wires the HL2 link to an RGMII PHY.
//
// What it does, for a beginner: a PHY chip has to be held in reset for a while after power-up,
// and its configuration pins (the "straps", which are the same pins as the RGMII receive data and
// control lines) are read at the moment the reset ends, so the chip needs a steady clock on its
// input before that moment. This module holds `phy_rst_n` (board net EPHY_~RST, FPGA pin E17,
// active low) low for at least `RESET_HOLD_CYCLES`, then keeps holding it until the 25 MHz
// reference clock of the PHY (from eth_clk_pll.v) has locked, releases it, and waits a further
// `POST_RESET_CYCLES` before raising `phy_ready`, which allows mdio_ctrl.v to make its first
// access to the PHY's registers.
//
// States:
//   ST_HOLD      reset low for the hold time (counted in clocks)
//   ST_WAIT_CLK  reset still low, waiting for `clk_ref_ok`, so that the strap latch at the end of
//                reset sees a settled clock
//   ST_POST      reset released (high), strap pins latch now, counting the settle time
//   ST_READY     `phy_ready` high, the PHY may be accessed over MDIO
//
// The default times follow the datasheet of the RTL8211F family: reset must be low for at least
// 10 ms, and register access must wait a further 30 ms after the release. The defaults of 12 ms
// and 35 ms add a little margin to each (docs/H3_PHY.md section 2 has the details).
//
// `CLK_HZ` is the frequency of `clk`, which drives the cycle counters below. Any convenient
// fabric clock will do, since this module is unrelated to the timing of the sample path, and
// `CLK_HZ` has to be set to match it.

`timescale 1ns / 1ps

module phy_reset_seq #(
    parameter CLK_HZ            = 150_000_000,   // frequency of clk, in Hz
    parameter RESET_HOLD_MS     = 12,    // >= 10 ms (datasheet minimum), 2 ms margin
    parameter POST_RESET_MS     = 35     // >= 30 ms (datasheet minimum), 5 ms margin
) (
    input  wire clk,          // any fabric clock, frequency CLK_HZ
    input  wire rst,          // this module's own logic reset (board power-on reset), not the PHY's
    input  wire clk_ref_ok,   // eth_clk_pll.v lock

    output reg  phy_rst_n,    // to EPHY_~{RST} (E17): active low
    output reg  phy_ready     // mdio_ctrl.v may start transactions
);

    // The two times in clock cycles, and a counter wide enough for the longer of them.
    localparam integer HOLD_CYCLES = (CLK_HZ / 1000) * RESET_HOLD_MS;
    localparam integer POST_CYCLES = (CLK_HZ / 1000) * POST_RESET_MS;
    localparam integer MAX_CYCLES  = (HOLD_CYCLES > POST_CYCLES) ? HOLD_CYCLES : POST_CYCLES;
    localparam CW = $clog2(MAX_CYCLES + 1);

    localparam ST_HOLD = 2'd0, ST_WAIT_CLK = 2'd1, ST_POST = 2'd2, ST_READY = 2'd3;
    reg [1:0]     state = ST_HOLD;
    reg [CW-1:0]  cnt   = {CW{1'b0}};

    always @(posedge clk) begin
        if (rst) begin
            state     <= ST_HOLD;
            cnt       <= {CW{1'b0}};
            phy_rst_n <= 1'b0;
            phy_ready <= 1'b0;
        end else begin
            case (state)
                ST_HOLD: begin
                    phy_rst_n <= 1'b0;
                    if (cnt == HOLD_CYCLES[CW-1:0] - 1'b1) begin
                        cnt   <= {CW{1'b0}};
                        state <= ST_WAIT_CLK;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                // Keep the PHY in reset until the 25 MHz reference it straps against is stable,
                // so the strap latch (sampled as reset releases) sees a settled clock domain.
                ST_WAIT_CLK: begin
                    phy_rst_n <= 1'b0;
                    if (clk_ref_ok) state <= ST_POST;
                end

                ST_POST: begin
                    phy_rst_n <= 1'b1;   // released; straps latch now
                    if (cnt == POST_CYCLES[CW-1:0] - 1'b1) begin
                        state <= ST_READY;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                ST_READY: begin
                    phy_rst_n <= 1'b1;
                    phy_ready <= 1'b1;
                end

                default: state <= ST_HOLD;
            endcase
        end
    end

endmodule
