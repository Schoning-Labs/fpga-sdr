// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Test-only MDIO slave model, standing in for the Ethernet PHY chip so that mdio_ctrl.v has something to talk to in
// simulation. It answers clause 22 reads at address `MY_ADDR` from a small register file with just enough content
// to check the controller: PHYID1 and PHYID2 at registers 2 and 3, which together give the real RTL8211F ID 0x001cc916
// (docs/H3_PHY.md section 3), plus BMCR and BMSR at registers 0 and 1 with plausible power-on
// values, to also check a read of a register that is not the ID). Not a synthesisable model of
// the RTL8211F, and not part of the fpga-sdr FPGA build. It plays the same role for the MDIO master as
// sim/h1_link_rx/hl2/*.v and sim/h2_link_tx/hl2/*.v play for the link, only that here the far end is a model and not
// the real gateware. It handles reads only, and writes are ignored.
//
// MDIO frames in short: the master sends 32 ones as a preamble, then the start bits 01, the opcode (10 for a read),
// the PHY address and the register address (5 bits each), a two bit turnaround, and 16 data bits. In a read the master
// lets go of the line after the register address and the PHY drives the turnaround and the data. The model tracks a
// frame in three stages, so that none of them has to treat the known zero first bit of the start field specially:
//   1. Preamble: the model counts consecutive ones sampled on the rising edge of MDC. The first 0 after at
//      least 31 of them is the first bit of the start field (always 0 in a valid clause 22 frame), which ends this stage,
//      and that bit is not itself captured into `addr13` below.
//   2. The next 13 bits (the second start bit, the 2 opcode bits, the 5 PHY address bits and the 5 register address bits,
//      1 + 2 + 5 + 5) shift into `addr13` most significant bit first. The edge that captures the 13th one also decodes
//      opcode, PHY address and register address, and latches whether to respond (`respond_rd`: this model's address
//      and the read opcode 10) and the value of the addressed register (`data_latch`).
//   3. If it was addressed, the model answers the following 17 clocks: it drives the turnaround's acknowledgement
//      bit low and then the 16 bits of the register, most significant bit first. It changes MDIO on the falling edge of
//      MDC, so that the value is stable well before the master's next rising-edge sample, the same convention
//      mdio_ctrl.v uses.

`timescale 1ns / 1ps

module mdio_phy_model #(
    parameter [4:0] MY_ADDR = 5'd1
) (
    input  wire mdc,
    input  wire mdio_in,     // what the master is driving (or released, pulled up externally)
    output reg  mdio_out,
    output reg  mdio_oe      // 1: this model drives `mdio_out` onto the shared line
);

    reg [15:0] regs [0:31];
    initial begin
        regs[0] = 16'h1140;   // BMCR: autonegotiation enabled (bit 12), full duplex (bit 8), speed select 1000 Mbit/s (bit 6)
        regs[1] = 16'h796d;   // BMSR: 10/100 half and full duplex capable, autonegotiation able and complete, link up
        regs[2] = 16'h001c;   // PHYID1
        regs[3] = 16'hc916;   // PHYID2 (together: 0x001cc916, the real RTL8211F ID)
    end

    // ---- stage 1: preamble ----
    reg [5:0] ones_run = 6'd0;
    reg       in_addr  = 1'b0;   // stage 2 (capturing addr13) in progress

    // ---- stage 2: ST[1],OP[1:0],PHYAD[4:0],REGAD[4:0] (13 bits) ----
    reg [12:0] addr13     = 13'd0;
    reg [3:0]  addr_cnt   = 4'd0;   // bits captured so far this stage, 0..12
    reg        respond_rd = 1'b0;   // this transaction: our address, OP=read
    reg [15:0] data_latch = 16'd0;

    // ---- stage 3: turnaround + data (17 edges: TA's 2nd bit, then 16 data bits) ----
    reg       in_resp  = 1'b0;
    reg [4:0] resp_cnt = 5'd0;   // 0 = TA's 2nd bit, 1..16 = data bits MSB..LSB

    wire [12:0] addr13_next = {addr13[11:0], mdio_in};   // this edge's bit folded in

    // Stages 1 to 3, sampled on the rising edge of MDC.
    always @(posedge mdc) begin
        if (in_resp) begin
            if (resp_cnt == 5'd16) in_resp <= 1'b0;
            else                    resp_cnt <= resp_cnt + 5'd1;
        end else if (in_addr) begin
            addr13 <= addr13_next;
            if (addr_cnt == 4'd12) begin
                // `addr13_next` already folds in this edge's bit, giving the complete 13-bit
                // field one edge sooner than waiting for `addr13` itself to show it.
                respond_rd <= (addr13_next[9:5] == MY_ADDR) && (addr13_next[11:10] == 2'b10);
                data_latch <= regs[addr13_next[4:0]];
                in_addr    <= 1'b0;
                in_resp    <= 1'b1;   // harmless if not actually addressed: mdio_oe gates on
                                      // `respond_rd` below, so an unaddressed transaction never drives
                resp_cnt   <= 5'd0;
            end else begin
                addr_cnt <= addr_cnt + 4'd1;
            end
        end else begin
            if (mdio_in) begin
                ones_run <= (&ones_run) ? ones_run : ones_run + 6'd1;
            end else begin
                if (ones_run >= 6'd31) begin
                    in_addr  <= 1'b1;
                    addr_cnt <= 4'd0;
                end
                ones_run <= 6'd0;
            end
        end
    end

    // Output side, on the falling edge of MDC: the model drives the line only while answering a read addressed to it, and
    // otherwise releases it.
    always @(negedge mdc) begin
        mdio_oe  <= 1'b0;
        mdio_out <= 1'b0;
        if (in_resp && respond_rd) begin
            mdio_oe  <= 1'b1;
            // `resp_cnt` (posedge side) already holds this bit's position by the time this
            // falling edge fires, one half cycle later: 0 selects the TA acknowledgement (always
            // 0), 1..16 select data bits 15 downto 0 in order.
            mdio_out <= (resp_cnt == 5'd0) ? 1'b0 : data_latch[16 - resp_cnt];
        end
    end

endmodule
