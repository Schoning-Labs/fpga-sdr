// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Top level of the minimal FPGA build that tests a real Hermes-Lite 2 over SFP cage 0
// (docs/HL2MIN.md): the HL2 plugged into a 1000BASE-T copper module (Marvell 88E1111, which speaks
// 1000BASE-X towards the FPGA) in cage SFP0, quad 1 lane 0 at 1.25 Gbit/s. The build has no
// processor, no DDR3, no video and no USB. It runs on the Sipeed Tang Mega 138K Pro with its dock
// (part GW5AST-LV138FPG676AC1/I0) and exists to prove the receive path of the HL2 link on the real
// radio, counting every lost packet, before the full radio is built.
//
// What is in this file: the pins, the reset key, and the transceiver (rtl/sfp/sfp_serdes.v, which
// wraps the generated `Serdes_Top` block in the default reset form). Everything else is
// rtl/hl2min/hl2min_core.v, which is also what the testbench sim/hl2min/tb_hl2min.v runs.
//
// Clocks: clk_50m (the board oscillator, pin P16), sfp_txc (lane 0's transmit word clock, 125 MHz,
// derived from the reference that the clock chip delivers), and n1_rxc (lane 0's recovered receive
// clock, 125 MHz). Lane 1 is generated with the quad (it is in serdes.toml, because both lanes of a
// quad share one configuration) and kept idle: its PCS in reset, its words 0, and its cage's
// transmitter off.
//
// HL2MIN_LANE = 1 (gowin/hl2min/build.sh with HL2MIN_LANE=1, for a module in cage SFP1): the HL2 is
// on lane 1 = cage SFP1 and lane 0 is idle. The build then generates lane 1 at 1.25 Gbit/s with
// 10-bit words like lane 0 (both lanes 1.25G Ethernet, the proven configuration of
// hw/gowin/sfp/serdes.toml). Lane 1's transmit buffer is written with its own
// tx_pcs_clkout (`ln1_txc`) and its receive buffer is read with its own rx_pcs_clkout (`bl_rxc`),
// so no lane 0 clock is in lane 1's buffers. The core then runs on ln1_txc and bl_rxc, and the
// 10-bit word is bits 9:0 of lane 1's 20-bit port. Lane 1's transmit buffer has its own clock in
// both settings (rtl/sfp/sfp_serdes.v, bl_txc = ln1_txc).
//
// Outputs: the debug UART (P15, 115,200 baud 8N1) with one line a second, and four LEDs (active low
// on the dock): 0 link up, 1 raw frames arriving, 2 any loss since start, 3 heartbeat.

`timescale 1ns / 1ps

module hl2min_top (
    input  wire        clk_50m,          // P16, 50 MHz board oscillator
    input  wire        key_rst_n,        // G16, user key 3: low = reset
    output wire        uart_txd,         // P15 -> BL616 / FT2232 channel B
    output wire [3:0]  led,              // J14, R26, L20, M25 (low = lit)
    output wire [1:0]  sfp_tx_disable,   // R18 (SFP0), M20 (SFP1)
    inout  wire        twi_scl,          // K25
    inout  wire        twi_sda,          // K26
    output wire [2:0]  twi_sel           // N19 (bit 2), P19 (bit 1), P26 (bit 0), as in fpga-sdr's constraint file
);
    // ---------------------------------------------------------------- reset: key, 3-flop synchronizer, 21 ms debounce
    // The key is a mechanical switch whose contacts bounce for a few milliseconds, so a change is
    // accepted only after it has lasted 2**20 clocks (21 ms at 50 MHz). The result goes through
    // a four-stage shift register, which gives `rst` four clocks of delay and starts it high, so the
    // design is in reset at power-up. `rst` is high while the key is down (key_rst_n low).
    (* preserve *) reg [2:0] key_s = 3'b111;
    reg [19:0] key_cnt = 20'd0;
    reg        key_ok = 1'b0;
    always @(posedge clk_50m) begin
        key_s <= {key_s[1:0], key_rst_n};
        if (key_s[2] == key_ok) key_cnt <= 20'd0;
        else if (&key_cnt)       key_ok  <= key_s[2];
        else                     key_cnt <= key_cnt + 1'b1;
    end
    reg [3:0] rst_s = 4'hF;
    always @(posedge clk_50m) rst_s <= {rst_s[2:0], ~key_ok};
    wire rst = rst_s[3];

    // ---------------------------------------------------------------- transceiver
    // HL2MIN_LANE chooses which lane carries the HL2. The core always talks to one lane through the
    // `c_` signals (words c_tx and c_rx, clocks c_txc and c_rxc, status c_st), and the lane that is
    // not chosen gets words of 0.
    wire        sfp_txc, n1_rxc, bl_rxc, ln1_txc, ln0_rx_vld, ln1_rx_vld, por_n;
    wire [9:0]  ln0_rx;
    wire [19:0] ln1_rx;
    wire [1:0]  ln_rst_n, ln_rx_rst, ln_tx_rst;
    wire [3:0]  ln0_stat, ln1_stat;
    wire [11:0] diag;
`ifndef HL2MIN_LANE
`define HL2MIN_LANE 0
`endif
    localparam integer LANE = `HL2MIN_LANE;
    wire [9:0]  c_tx;                    // the core's words, for the lane LANE
    wire [9:0]  l0_tx = (LANE == 1) ? 10'd0 : c_tx;
    wire [19:0] l1_tx = (LANE == 1) ? {10'd0, c_tx} : 20'd0;
    sfp_serdes u_serdes (
        .por_n(por_n), .ln_rst_n(ln_rst_n), .ln_rx_rst(ln_rx_rst), .ln_tx_rst(ln_tx_rst),
        .ln0_fix(4'd0), .ln1_fix(4'd0),
        .sfp_txc(sfp_txc), .n1_rxc(n1_rxc), .bl_txc(ln1_txc), .ln1_txc(ln1_txc), .bl_rxc(bl_rxc),
        .ln0_tx(l0_tx), .ln0_rx(ln0_rx), .ln0_rx_vld(ln0_rx_vld),
        .ln1_tx(l1_tx), .ln1_rx(ln1_rx), .ln1_rx_vld(ln1_rx_vld),
        .ln0_stat(ln0_stat), .ln1_stat(ln1_stat), .diag(diag)
    );
    // The HL2's lane to the core. The clocks are wires from the transceiver, chosen at build time,
    // with no multiplexer, since a clock must not go through logic.
    wire        c_txc, c_rxc;
    generate if (LANE == 1) begin : g_l1
        assign c_txc = ln1_txc;
        assign c_rxc = bl_rxc;
    end else begin : g_l0
        assign c_txc = sfp_txc;
        assign c_rxc = n1_rxc;
    end endgenerate
    wire [9:0]  c_rx  = (LANE == 1) ? ln1_rx[9:0] : ln0_rx;
    wire        c_vld = (LANE == 1) ? ln1_rx_vld : ln0_rx_vld;
    wire [3:0]  c_st  = (LANE == 1) ? ln1_stat : ln0_stat;

    // ---------------------------------------------------------------- the rest
    // The I2C pins are open drain: a 0 pulls the wire low, a 1 lets it float and the pull-up
    // resistor on the board takes it high. The LEDs on the dock are lit by a low level.
    wire scl_o, sda_o, s_n19, s_p19, s_p26;
    wire [3:0] led_on;
    assign twi_scl = scl_o ? 1'bz : 1'b0;
    assign twi_sda = sda_o ? 1'bz : 1'b0;
    assign twi_sel = {s_n19, s_p19, s_p26};
`ifndef HL2MIN_REG30
`define HL2MIN_REG30 32'h03C8_0003      // N = 968, test pattern, raw mode on (gowin/hl2min/build.sh sets it)
`endif
`ifndef HL2MIN_SGMII
`define HL2MIN_SGMII 0
`endif
    hl2min_core #(.REG30(`HL2MIN_REG30), .SGMII(`HL2MIN_SGMII), .LANE(LANE)) u_core (
        .clk_50m(clk_50m), .rst(rst),
        .sfp_txc(c_txc), .n1_rxc(c_rxc), .ln0_tx(c_tx), .ln0_rx(c_rx), .ln0_rx_vld(c_vld),
        .serdes_por_n(por_n), .ln_rst_n(ln_rst_n), .ln_rx_rst(ln_rx_rst), .ln_tx_rst(ln_tx_rst),
        .ln0_stat(c_st), .sfp_diag(diag), .sfp_tx_disable(sfp_tx_disable),
        .twi_scl_o(scl_o), .twi_sda_o(sda_o), .twi_scl_i(twi_scl), .twi_sda_i(twi_sda),
        .sel_n19(s_n19), .sel_p19(s_p19), .sel_p26(s_p26),
        .uart_txd(uart_txd), .led_on(led_on)
    );
    assign led = ~led_on;
endmodule
