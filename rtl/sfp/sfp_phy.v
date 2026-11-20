// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Lane 0 of the transceiver as a GMII-style byte interface: the whole 1000BASE-X physical layer in
// logic, between the 10-bit line words of the transceiver and the bytes of an Ethernet frame
// (docs/HL2_SFP.md section 3, docs/SFP_LINKS.md section 4).
//
// What 1000BASE-X is, for a beginner: gigabit Ethernet over an SFP cage. The line runs at 1.25 Gbit/s
// and carries 8b/10b symbols (see sfp_enc20.v for what that code is), of which 1 Gbit/s is data. The
// Hermes-Lite 2 is on copper (1000BASE-T), so a copper SFP module sits in the cage and converts between
// the two, and towards the FPGA it speaks 1000BASE-X. On the line there are always symbols. Between
// frames the sender sends idle ordered sets (the comma K28.5 followed by a data symbol, which keeps
// the receiver locked), a frame is introduced by the control symbol /S/ in place of the first preamble
// byte and closed by /T/ and /R/, and when a link starts, both ends exchange 16-bit configuration words
// (auto-negotiation, IEEE 802.3 clause 37) to agree on duplex and to learn that the partner is there.
// The block that does all this is the PCS (physical coding sublayer, in sfp_pcs.v). Its byte interface
// is called GMII, the gigabit media independent interface: a byte, a data-valid flag and an error flag,
// one byte per clock at 125 MHz, which is exactly what an Ethernet MAC wants.
//
// What is inside: comma alignment and 8b/10b decoding (sfp_rx_sym.v), the PCS (sfp_pcs.v) and the
// 8b/10b coder (rtl/n1/enc_8b10b.v). The same PCS serves two users: sfp_net.v (a MAC and packet
// memory, used by its testbench) and the Hermes-Lite 2 link (rtl/hl2link, through
// rtl/top/sdr_core.v).
//
// Three clocks:
//   txc   lane 0 transmit word clock: coder, PCS transmit side and negotiation; the GMII transmit byte
//   rxc   lane 0 recovered word clock: aligner, decoder, PCS receive side; the GMII receive byte
//   clk   clk_dsp: settings in, status out (levels and counters, crossed with sfp_xstat)
//
// GMII receive (rxc): `g_rx_d`, `g_rx_dv` and `g_rx_er` are new in a clock with `g_rx_ce` 1 and held
// otherwise (the transceiver's receive buffer is read while not almost empty, so a receive clock may
// carry no word: IPUG1024-1.7.2E 3.7.2). The frame comes as the PCS gives it: /S/ as the first
// preamble byte 0x55, the rest of the preamble, the SFD, the content and the FCS, and `g_rx_dv` falls at
// /T/.
// GMII transmit (txc): one byte per clock while `g_tx_en`, preamble and SFD included (the PCS puts
// /S/ in place of the first byte), with no gaps inside a frame. The PCS starts a frame only at an even
// symbol while the link is up. A frame that begins while the PCS sends the second symbol of an idle
// loses its first preamble byte, which the standard allows (36.2.4.13). The caller keeps at least 12
// bytes between frames (sfp_net.v counts 20).

`timescale 1ns / 1ps

module sfp_phy #(
    parameter integer TIMER_X     = 1250000,   // link timer of 1000BASE-X in txc clocks: 10 ms at 125 MHz
    parameter integer TIMER_SGMII = 200000     // link timer of SGMII: 1.6 ms
) (
    // ---- lane 0 (line order: bit 0 first on the line)
    input  wire        txc,              // transmit word clock, 125 MHz
    output reg  [9:0]  tx_word = 10'd0,  // 10-bit symbol to the lane
    input  wire        rxc,              // recovered receive word clock, 125 MHz
    input  wire        rx_vld,           // rx_word holds a new word in this clock
    input  wire [9:0]  rx_word,          // 10-bit word from the lane
    // ---- clk_dsp side
    input  wire        clk,              // clk_dsp, for settings and status
    input  wire        cfg_enable,       // 0: both lane-clock sides held in reset
    input  wire        cfg_sgmii,        // 1: SGMII (MAC side), 0: 1000BASE-X
    input  wire        cfg_an,           // 1: auto-negotiation on
    input  wire        cfg_restart_tog,  // toggles: restart negotiation
    // ---- GMII receive (rxc)
    output wire        rx_rst,           // the receive side's reset, for the consumer of the bytes
    output wire [7:0]  g_rx_d,
    output wire        g_rx_dv,
    output wire        g_rx_er,
    output wire        g_rx_ce,
    output wire        rx_locked,        // aligner locked (rxc)
    // ---- GMII transmit (txc)
    output wire        tx_rst,           // the transmit side's reset, for the producer of the bytes
    input  wire [7:0]  g_tx_d,           // transmit byte, preamble first
    input  wire        g_tx_en,          // the byte is part of a frame
    output wire        tx_link_up,       // the PCS sends data (txc)
    // ---- status (clk)
    output wire        st_link_up,       // link up
    output wire        st_an_done,       // negotiation complete
    output wire        st_rx_sync,       // receive side has symbol lock
    output wire        st_rx_idle,       // idle ordered sets are arriving
    output wire        st_aligned,       // the aligner's lock
    output wire [15:0] st_partner,       // the partner's last configuration word
    output wire [15:0] align_losses,     // times the aligner lost its lock (10 bits, in the low bits)
    output wire [15:0] code_errors,      // symbols not in the 8b/10b alphabet while locked (saturating)
    output reg         irq_link = 1'b0   // pulse (clk): link went up or down
) /* synthesis syn_srlstyle = "registers" */;

    // ---------------------------------------------------------------- resets (asserted at once, released in step)
    // A reset that is asserted at once (asynchronously) when `cfg_enable` goes low and released
    // synchronously, four clocks of that side's own clock later, so that the end of the reset never
    // arrives at a random moment relative to the clock.
    reg [3:0] trs = 4'hF, rrs = 4'hF;
    always @(posedge txc or negedge cfg_enable) if (!cfg_enable) trs <= 4'hF; else trs <= {trs[2:0], 1'b0};
    always @(posedge rxc or negedge cfg_enable) if (!cfg_enable) rrs <= 4'hF; else rrs <= {rrs[2:0], 1'b0};
    assign tx_rst = trs[3];
    assign rx_rst = rrs[3];

    // settings into txc: two-flop synchronizers (levels; a change while running restarts the negotiation
    // anyway, so a glitch of a clock does no harm). The restart request is a toggle, and an edge
    // detect (rs_s[2] ^ rs_s[1]) makes a pulse of it.
    reg [1:0] sg_s = 2'd0, an_s = 2'd0;
    reg [2:0] rs_s = 3'd0;
    always @(posedge txc) begin
        sg_s <= {sg_s[0], cfg_sgmii}; an_s <= {an_s[0], cfg_an}; rs_s <= {rs_s[1:0], cfg_restart_tog};
    end

    // ---------------------------------------------------------------- receive: aligner, decoder
    // The aligner finds the symbol boundary and the decoder turns each symbol into a byte, a flag for
    // a control symbol and a flag for an invalid code.
    wire       sy_vld, sy_k, sy_err, sy_locked;
    wire [7:0] sy_d;
    wire [15:0] sy_loss;
    sfp_rx_sym #(.N(1)) u_rxsym (
        .clk(rxc), .rst(rx_rst), .vld(rx_vld), .din(rx_word),
        .sym_vld(sy_vld), .sym_d(sy_d), .sym_k(sy_k), .sym_err(sy_err), .locked(sy_locked), .cnt_loss(sy_loss)
    );
    assign rx_locked = sy_locked;

    // Count of invalid symbols while locked (saturating), shown as code_errors.
    reg [15:0] c_code = 16'd0;
    always @(posedge rxc)
        if (rx_rst) c_code <= 16'd0;
        else if (sy_vld && sy_err && sy_locked && (c_code != 16'hFFFF)) c_code <= c_code + 16'd1;

    // ---------------------------------------------------------------- PCS and coder
    // The PCS gives a byte and a K flag to the coder, one clock apart through the register `pq`.
    wire [7:0] pcs_d;
    wire       pcs_k, enc_rd, link_up, an_done, rx_sync, rx_idle;
    wire [15:0] partner;
    wire [9:0] enc_q;
    // One register between the MAC and the PCS, because a frame length compare, the FCS, the PCS and
    // the coder table in one clock would be 19 logic levels, which does not fit in 8 ns. The PCS
    // only sees the frame one clock later.
    reg  [7:0] mtx_d = 8'd0;
    reg        mtx_en = 1'b0;
    always @(posedge txc) begin mtx_d <= g_tx_d; mtx_en <= g_tx_en; end
    sfp_pcs #(.TIMER_X(TIMER_X), .TIMER_SGMII(TIMER_SGMII)) u_pcs (
        .rxc(rxc), .rx_rst(rx_rst), .rx_vld(sy_vld), .rx_d(sy_d), .rx_k(sy_k), .rx_err(sy_err),
        .rx_locked(sy_locked), .mac_rx_data(g_rx_d), .mac_rx_dv(g_rx_dv), .mac_rx_er(g_rx_er), .mac_rx_ce(g_rx_ce),
        .txc(txc), .tx_rst(tx_rst), .cfg_sgmii(sg_s[1]), .cfg_an(an_s[1]), .cfg_restart(rs_s[2] ^ rs_s[1]),
        .mac_tx_data(mtx_d), .mac_tx_en(mtx_en), .tx_d(pcs_d), .tx_k(pcs_k), .enc_rd(enc_rd),
        .link_up(link_up), .an_done(an_done), .rx_sync(rx_sync), .rx_idle(rx_idle), .partner(partner)
    );
    assign tx_link_up = link_up;
    // A register between the PCS output and the encoder, because the combined path (PCS sequencer
    // and coder table in one clock) is too slow for 125 MHz. The PCS reads `enc_rd` (the running
    // disparity before the symbol that the encoder works on now, which is the symbol that the PCS
    // presented one clock ago) to choose between its two idle ordered sets.
    reg [7:0] pq_d = 8'd0;
    reg       pq_k = 1'b0;
    always @(posedge txc) begin pq_d <= pcs_d; pq_k <= pcs_k; end
    enc_8b10b u_enc (.clk(txc), .rst(tx_rst), .din(pq_d), .kin(pq_k), .dout(enc_q), .rd_out(enc_rd), .valid());
    // The table has bit `a` (first on the line) at bit 9, and the lane takes bit 0 first, so the 10 bits
    // go out in reverse order.
    always @(posedge txc)
        tx_word <= {enc_q[0], enc_q[1], enc_q[2], enc_q[3], enc_q[4], enc_q[5], enc_q[6], enc_q[7], enc_q[8], enc_q[9]};

    // ---------------------------------------------------------------- status into clk
    // The receive side's status (aligner lock, alignment losses, code errors) and the transmit side's
    // (link, negotiation, synchronization, idle, partner word) each cross into `clk` as one word through
    // sfp_xstat, which also shows the idle value (all 0) if a lane clock has stopped.
    wire [26:0] xr;
    sfp_xstat #(.W(27), .AGE(9)) u_xr (
        .clk_a(rxc), .d_a({sy_locked, sy_loss[9:0], c_code}), .clk_b(clk), .q_b(xr), .alive(), .upd_b()
    );
    assign code_errors  = xr[15:0];
    assign align_losses = {6'd0, xr[25:16]};
    assign st_aligned   = xr[26];

    wire [19:0] xt;
    sfp_xstat #(.W(20), .AGE(9)) u_xt (
        .clk_a(txc), .d_a({partner, rx_idle, rx_sync, an_done, link_up}),
        .clk_b(clk), .q_b(xt), .alive(), .upd_b()
    );
    assign st_link_up = xt[0];
    assign st_an_done = xt[1];
    assign st_rx_sync = xt[2];
    assign st_rx_idle = xt[3];
    assign st_partner = xt[19:4];
    // The link interrupt: a pulse in every clock in which the link status differs from the last one.
    reg link_q = 1'b0;
    always @(posedge clk) begin link_q <= xt[0]; irq_link <= (xt[0] != link_q); end

endmodule
