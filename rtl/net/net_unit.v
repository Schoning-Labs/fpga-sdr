// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// The network unit on the board's RJ45 socket (RTL8211F PHY, RGMII at 100 Mbit/s; docs/HL2_SFP.md section 9):
// the Ethernet MAC of rtl/net/eth_top.v behind one register page of the AE350's bus, plus the chip's
// identification number. It carries the home network side of the radio (control, GUI, TCI and the loader),
// since the Hermes-Lite 2 link uses the SFP lane. The page and its layout are shared with an earlier
// design by the same author, so that one loader finds the unit at the same address in both (docs/NET_ID.md):
//   0x00 id 0x4554_0001  0x04 control  0x08 status  0x0C flags  0x10 interrupt enable  0x14/0x18 MAC  0x1C MDIO
//   0x20 transmit length  0x24 transmit data  0x28 transmit pointer  0x2C receive length  0x30 receive data
//   0x34 receive done  0x38 receive count  0x3C dropped  0x40 transmit count
//   0x80-0x90 the 129 raw bits of the chip's OTP read (word 4 = bit 128)  0x94 status (bit 0 read done, 15:8 ID width = 64)
//   0x98 chip ID low word (raw[63:32])  0x9C chip ID high word (raw[95:64])   (rtl/net/chip_dna.v; Gowin
//   SUG283-3.6.1E section 8.9)
// The page number is defined in one place: hw/regmap/net.toml (`NET_BASE), which rtl/top/sdr_core.v uses
// for the bus bridge's channel 3 and the firmware uses too (fw/tr-fabric/src/eth.rs). A different layout means
// a new eth_top.v and net.toml, and nothing else here.
//
// Clock: clk_eth, 100 MHz from the Ethernet PLL (rtl/hl2link/eth_clk_pll.v), so eth_top runs with DIV = 4
// (25 MHz = clk / 4 for TXC and the PHY's reference, RXC sampled as data). The register bus arrives through
// rtl/top/regbus_cdc_dst.v in clk_eth, which is a toggle handshake of the kind cdc_word.v explains: a strobe
// with address and data, and the read word is taken RD_LAT clocks later. eth_top gives its read word only in
// the clock after the read strobe, so it is held here until the bus asks for it.

`timescale 1ns / 1ps

module net_unit (
    input  wire        clk,                  // clk_eth, 100 MHz
    input  wire        rst,                  // synchronous reset, active high
    input  wire        bus_wr,               // register write strobe
    input  wire        bus_rd,               // register read strobe
    input  wire [15:0] bus_addr,             // byte address within the page
    input  wire [31:0] bus_wdata,            // write data
    output reg  [31:0] bus_rdata = 32'd0,    // read data, held after a read
    output wire        irq,                  // level, clk
    // RJ45 PHY pins
    output wire        rgmii_txc,            // transmit clock to the PHY
    output wire [3:0]  rgmii_txd,            // transmit nibble
    output wire        rgmii_tx_ctl,         // transmit enable
    input  wire        rgmii_rxc,            // receive clock from the PHY
    input  wire [3:0]  rgmii_rxd,            // receive nibble
    input  wire        rgmii_rx_ctl,         // receive data valid
    output wire        phy_clk,              // 25 MHz reference clock for the PHY
    output wire        phy_rst_n,            // PHY reset, active low
    output wire        mdc,                  // management clock
    input  wire        mdio_i,               // management data in
    output wire        mdio_o,               // management data out
    output wire        mdio_oe               // 1: drive mdio_o
);
    wire        in_page = (bus_addr[15:8] == 8'h00);   // the page is 256 bytes
    wire [31:0] rd;
    reg         rd_q = 1'b0;

    // ---------------------------------------------------------------- chip ID (the same words as in the earlier design)
    // Every Gowin chip carries a factory identification number (a 64-bit "DNA") in its OTP (one time
    // programmable) memory, which chip_dna.v reads once after the reset (about 150 us). The number lets several
    // boards on one network tell themselves apart. The words are read-only, at word offsets 0x20 to 0x27 (those
    // are free in eth_top, whose last register is 0x10). Like eth_top's read word, this one is valid in the
    // clock after the read strobe and 0 otherwise.
    wire [128:0] dna_raw;
    wire         dna_done;
    chip_dna u_dna (.clk(clk), .rst(rst), .raw(dna_raw), .done(dna_done));
    reg  [31:0]  d_rd = 32'd0;
    // The two read words are ORed together, since each is 0 unless its own register is addressed.
    wire [31:0] rd_all = rd | d_rd;
    always @(posedge clk) begin
        rd_q <= bus_rd;
        if (rd_q) bus_rdata <= rd_all;
    end
    always @(posedge clk) begin
        d_rd <= 32'd0;
        if (bus_rd && in_page) case (bus_addr[7:2])
            6'h20: d_rd <= dna_raw[31:0];
            6'h21: d_rd <= dna_raw[63:32];
            6'h22: d_rd <= dna_raw[95:64];
            6'h23: d_rd <= dna_raw[127:96];
            6'h24: d_rd <= {31'd0, dna_raw[128]};
            6'h25: d_rd <= {16'd0, 8'd64, 7'd0, dna_done};
            6'h26: d_rd <= dna_raw[63:32];
            6'h27: d_rd <= dna_raw[95:64];
            default: ;
        endcase
    end
    eth_top #(.DIV(4)) u_eth (
        .clk(clk), .rst(rst), .we(bus_wr && in_page), .re(bus_rd && in_page), .a(bus_addr[7:2]), .wd(bus_wdata),
        .rd(rd), .irq(irq),
        .rgmii_txc(rgmii_txc), .rgmii_txd(rgmii_txd), .rgmii_tx_ctl(rgmii_tx_ctl),
        .rgmii_rxc(rgmii_rxc), .rgmii_rxd(rgmii_rxd), .rgmii_rx_ctl(rgmii_rx_ctl),
        .phy_clk(phy_clk), .phy_rst_n(phy_rst_n), .mdc(mdc), .mdio_i(mdio_i), .mdio_o(mdio_o), .mdio_oe(mdio_oe),
        .ph_o()
    );
endmodule
