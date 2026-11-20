// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Register page 0x0A "sfp" (hw/regmap/sfp.toml; docs/SFP_LINKS.md): the control and status of the
// transceiver, in a form that the firmware can use from the CPU. It holds the reset and status of both
// lanes, the pins of the cages, the I2C pins and multiplexer select as plain register bits (the firmware
// does the I2C protocol itself: the clock chip and the modules' memories), and lane 0's PCS settings and
// status. Everything here is in clk_dsp, and the page works with both lane clocks stopped, so the
// firmware can still read it and start the lanes when they are not running.
//
// Why I2C is done by bits: the firmware has to program the clock chip that makes the 125 MHz transceiver
// reference, and read the identification memory of an SFP module, both over I2C. Instead of an I2C
// controller in logic, the page gives the firmware the two open-drain pins (`twi` register: SCL and SDA
// out, and the pin levels back) and the three select pins of the multiplexer, and the firmware wiggles
// them (the hl2min test build does the same in logic, hl2min_clkseq.v).
//
// NET_MAC chooses what sits behind the PCS: 0 (the chip) means lane 0 carries the Hermes-Lite 2 link, so
// the PCS (sfp_phy.v) gives its bytes to the GMII ports below, which rtl/top/sdr_core.v takes to
// rtl/hl2link, and the packet memory is not built, so its registers read 0. 1 means a network socket
// with a MAC and a packet memory behind the PCS (sfp_net.v), which its testbench sim/sfp/tb_sfp_net.v uses.
//
// Offsets (the generated map is the source for firmware):
//   0x000 id            0x004 serdes_ctrl    0x008 serdes_status   0x00C cage    0x010 twi
//   0x020 net_ctrl      0x024 net_status     0x040 align_losses    0x044 code_errors (NET_MAC 0)
//   NET_MAC 1 only: 0x028 tx_len (write: send)  0x02C rx_wr_ptr  0x030 rx_rd_ptr  0x034 rx_frames  0x038 rx_dropped
//   0x03C rx_crc_errors; 0x1000-0x17FC transmit buffer (512 words, write)  0x2000-0x3FFC receive ring (2,048 words, read)
// A write lands two clocks after the strobe, and read data is valid three clocks after it.

`timescale 1ns / 1ps

module sfp_top #(
    parameter integer TIMER_X     = 1250000,
    parameter integer TIMER_SGMII = 200000,
    parameter integer NET_MAC     = 1      // 0: lane 0's bytes on the GMII ports (HL2 link); 1: MAC and packet memory
) (
    input  wire        clk,              // clk_dsp
    input  wire        rst,              // synchronous reset, active high
    input  wire        bus_wr,           // register write strobe
    input  wire        bus_rd,           // register read strobe
    input  wire [15:0] bus_addr,         // byte address within the page
    input  wire [31:0] bus_wdata,        // write data
    output reg  [31:0] bus_rdata = 32'd0, // read data
    // ---- transceiver (asynchronous levels both ways)
    output wire        por_n,            // quad power-on reset, active low
    output wire [1:0]  ln_rst_n,         // lane 0, lane 1: 0 = lane held in reset
    output wire [1:0]  ln_rx_rst,        // 1 = receive side of the lane in reset
    output wire [1:0]  ln_tx_rst,
    output wire [3:0]  ln0_fix,          // 0 tx bit order reversed, 1 rx reversed, 2 tx inverted, 3 rx inverted
    output wire [3:0]  ln1_fix,
    input  wire [3:0]  ln0_stat,         // 0 PLL lock, 1 receive clock lock, 2 signal detect, 3 ready
    input  wire [3:0]  ln1_stat,
    input  wire [11:0] diag,             // 7:0 the quad's status, 11:8 the lanes' buffer flags (rtl/sfp/sfp_serdes.v)
    input  wire        ln1_aligned,      // board link's aligner (clk)
    // ---- cages and I2C
    output wire [1:0]  sfp_tx_disable,   // 1 = the module's transmitter is off, per cage
    input  wire [1:0]  sfp_los,          // loss of signal from the module, per cage (not every module drives it)
    output wire        twi_scl_o,        // 0 = pull the line low
    output wire        twi_sda_o,
    input  wire        twi_scl_i,
    input  wire        twi_sda_i,
    output wire [2:0]  twi_sel,          // I2C multiplexer select pins: bits 2, 1, 0 drive N19, P19, P26 (N19 is the multiplexer's lowest select input)
    // ---- lane 0
    input  wire        txc,              // lane 0 transmit word clock
    output wire [9:0]  tx_word,          // word to send
    input  wire        rxc,              // lane 0 recovered receive word clock
    input  wire        rx_vld,           // rx_word is new
    input  wire [9:0]  rx_word,          // word received
    output wire        irq_rx,           // pulse: a frame was added to the ring (NET_MAC 1)
    output wire        irq_link,         // pulse: link went up or down
    // ---- lane 0 as bytes (NET_MAC 0; sfp_phy.v): receive in rxc, transmit in txc
    output wire        g_rx_rst,         // receive side reset, for the consumer of the bytes
    output wire [7:0]  g_rx_d,           // received byte
    output wire        g_rx_dv,          // data valid
    output wire        g_rx_er,          // error in this byte
    output wire        g_rx_ce,          // a new byte in this clock
    output wire        g_tx_rst,         // transmit side reset
    input  wire [7:0]  g_tx_d,           // byte to send
    input  wire        g_tx_en,          // the byte is part of a frame
    output wire        g_tx_link_up      // the PCS sends data
) /* synthesis syn_srlstyle = "registers" */;

    // Register bits. serdes_ctrl: bit 0 por_n, 2:1 lane resets (active low), 4:3 PCS receive resets, 6:5
    // PCS transmit resets, 11:8 lane 0 bring-up bits, 15:12 lane 1 bring-up bits. After reset all are 0, so
    // both lanes are held in reset. `r_txdis` starts with both transmitters off, `r_twi` is {select (3
    // bits), SDA, SCL} with both I2C wires released, and `r_net` is {negotiation on, SGMII, enable}.
    reg [15:0] r_serdes = 16'd0;
    reg [1:0]  r_txdis = 2'b11;
    reg [4:0]  r_twi = 5'b00011;
    reg [2:0]  r_net = 3'b100;           // 0 enable, 1 sgmii, 2 negotiation on
    reg        r_restart = 1'b0;
    reg [10:0] r_txlen = 11'd0, r_rdptr = 11'd0;
    reg        tx_send = 1'b0;

    assign por_n     = r_serdes[0];
    assign ln_rst_n  = r_serdes[2:1];
    assign ln_rx_rst = r_serdes[4:3];
    assign ln_tx_rst = r_serdes[6:5];
    assign ln0_fix   = r_serdes[11:8];
    assign ln1_fix   = r_serdes[15:12];
    assign sfp_tx_disable = r_txdis;
    assign twi_scl_o = r_twi[0];
    assign twi_sda_o = r_twi[1];
    assign twi_sel   = r_twi[4:2];

    // The transceiver's status levels, the diagnostic word and the pins come from other clocks or from
    // outside, so each goes through two flip-flops before it is read onto the bus.
    (* preserve *) reg [3:0] s0a = 4'd0, s0b = 4'd0, s1a = 4'd0, s1b = 4'd0;
    (* preserve *) reg [3:0] pina = 4'd0, pinb = 4'd0;
    (* preserve *) reg [11:0] dga = 12'd0, dgb = 12'd0;
    always @(posedge clk) begin
        s0a <= ln0_stat; s0b <= s0a; s1a <= ln1_stat; s1b <= s1a; dga <= diag; dgb <= dga;
        pina <= {twi_sda_i, twi_scl_i, sfp_los}; pinb <= pina;
    end

    wire        tx_busy, st_link, st_an, st_sync, st_idle, st_aligned;
    wire [15:0] st_partner, rx_frames, rx_dropped, rx_crc, al_loss, code_err;
    wire [10:0] rx_wr_ptr;
    wire [31:0] rxr_q;
    // Address decoding: the registers are at 0x000 to 0x0FF, the transmit buffer at 0x1000, the receive ring at 0x2000.
    wire        sel_txb = (bus_addr[15:12] == 4'h1);
    wire        sel_rxr = (bus_addr[15:13] == 3'b001);
    wire        sel_reg = (bus_addr[15:8] == 8'h00);

    reg         wr_q = 1'b0;
    reg         txb_we = 1'b0;
    reg  [2:0]  rd_kind = 3'd0;          // 1 register, 2 ring
    reg  [31:0] reg_q = 32'd0;

    // Register file. A write is taken one clock after the strobe (`wr_q`), a read is answered in two
    // steps (the register value into `reg_q`, then onto the bus), which is why read data is valid three
    // clocks after the strobe.
    always @(posedge clk) begin
        wr_q    <= bus_wr;
        txb_we  <= bus_wr && sel_txb;
        tx_send <= 1'b0;
        if (rst) begin
            r_serdes <= 16'd0; r_txdis <= 2'b11; r_twi <= 5'b00011; r_net <= 3'b100;
        end else if (wr_q && sel_reg) begin
            case (bus_addr[7:0])
                8'h04: r_serdes <= bus_wdata[15:0];
                8'h0C: r_txdis  <= bus_wdata[1:0];
                8'h10: r_twi    <= bus_wdata[4:0];
                8'h20: begin r_net <= bus_wdata[2:0]; if (bus_wdata[3]) r_restart <= ~r_restart; end
                8'h28: begin r_txlen <= bus_wdata[10:0]; tx_send <= 1'b1; end
                8'h30: r_rdptr  <= bus_wdata[10:0];
                default: ;
            endcase
        end

        case (bus_addr[7:0])
            8'h00: reg_q <= 32'h5346_0001;
            8'h04: reg_q <= {16'd0, r_serdes};
            8'h08: reg_q <= {4'd0, dgb, 3'd0, ln1_aligned, s1b, 3'd0, st_aligned, s0b};
            8'h0C: reg_q <= {22'd0, pinb[1:0], 6'd0, r_txdis};
            8'h10: reg_q <= {22'd0, pinb[3:2], 3'd0, r_twi};
            8'h20: reg_q <= {29'd0, r_net};
            8'h24: reg_q <= {st_partner, 11'd0, tx_busy, st_idle, st_sync, st_an, st_link};
            8'h28: reg_q <= (NET_MAC != 0) ? {21'd0, r_txlen} : 32'd0;
            8'h2C: reg_q <= {21'd0, rx_wr_ptr};
            8'h30: reg_q <= (NET_MAC != 0) ? {21'd0, r_rdptr} : 32'd0;
            8'h34: reg_q <= {16'd0, rx_frames};
            8'h38: reg_q <= {16'd0, rx_dropped};
            8'h3C: reg_q <= {16'd0, rx_crc};
            8'h40: reg_q <= {16'd0, al_loss};
            8'h44: reg_q <= {16'd0, code_err};
            default: reg_q <= 32'd0;
        endcase
        rd_kind   <= {1'b0, sel_rxr, sel_reg};
        bus_rdata <= rd_kind[1] ? rxr_q : (rd_kind[0] ? reg_q : 32'd0);
    end

    // What sits behind the PCS: a MAC with packet memory (NET_MAC 1) or nothing, with the PCS's bytes brought
    // out to the GMII ports for the HL2 link (NET_MAC 0). The registers of the unused side read 0.
    generate if (NET_MAC != 0) begin : g_net
        sfp_net #(.TIMER_X(TIMER_X), .TIMER_SGMII(TIMER_SGMII)) u_net (
            .txc(txc), .tx_word(tx_word), .rxc(rxc), .rx_vld(rx_vld), .rx_word(rx_word),
            .clk(clk), .cfg_enable(r_net[0]), .cfg_sgmii(r_net[1]), .cfg_an(r_net[2]), .cfg_restart_tog(r_restart),
            .txb_we(txb_we), .txb_addr(bus_addr[10:2]), .txb_wdata(bus_wdata),
            .tx_send(tx_send), .tx_len(r_txlen), .tx_busy(tx_busy),
            .rxr_addr(bus_addr[12:2]), .rxr_rdata(rxr_q), .rx_rd_ptr(r_rdptr), .rx_wr_ptr(rx_wr_ptr),
            .rx_frames(rx_frames), .rx_dropped(rx_dropped), .rx_crc_errors(rx_crc), .align_losses(al_loss),
            .st_link_up(st_link), .st_an_done(st_an), .st_rx_sync(st_sync), .st_rx_idle(st_idle),
            .st_aligned(st_aligned), .st_partner(st_partner),
            .irq_rx(irq_rx), .irq_link(irq_link)
        );
        assign code_err = 16'd0;
        assign g_rx_rst = 1'b1; assign g_rx_d = 8'd0; assign g_rx_dv = 1'b0; assign g_rx_er = 1'b0; assign g_rx_ce = 1'b0;
        assign g_tx_rst = 1'b1; assign g_tx_link_up = 1'b0;
    end else begin : g_phy
        // the Hermes-Lite 2 link (docs/HL2_SFP.md): no MAC, no packet memory
        sfp_phy #(.TIMER_X(TIMER_X), .TIMER_SGMII(TIMER_SGMII)) u_phy (
            .txc(txc), .tx_word(tx_word), .rxc(rxc), .rx_vld(rx_vld), .rx_word(rx_word),
            .clk(clk), .cfg_enable(r_net[0]), .cfg_sgmii(r_net[1]), .cfg_an(r_net[2]), .cfg_restart_tog(r_restart),
            .rx_rst(g_rx_rst), .g_rx_d(g_rx_d), .g_rx_dv(g_rx_dv), .g_rx_er(g_rx_er), .g_rx_ce(g_rx_ce), .rx_locked(),
            .tx_rst(g_tx_rst), .g_tx_d(g_tx_d), .g_tx_en(g_tx_en), .tx_link_up(g_tx_link_up),
            .st_link_up(st_link), .st_an_done(st_an), .st_rx_sync(st_sync), .st_rx_idle(st_idle),
            .st_aligned(st_aligned), .st_partner(st_partner), .align_losses(al_loss), .code_errors(code_err),
            .irq_link(irq_link)
        );
        assign irq_rx = 1'b0; assign tx_busy = 1'b0; assign rxr_q = 32'd0; assign rx_wr_ptr = 11'd0;
        assign rx_frames = 16'd0; assign rx_dropped = 16'd0; assign rx_crc = 16'd0;
    end endgenerate

endmodule
