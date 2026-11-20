// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Core of the minimal Hermes-Lite 2 test build (docs/HL2MIN.md): everything of
// rtl/hl2min/hl2min_top.v except the pins and Gowin's transceiver block, so that the testbench
// sim/hl2min/tb_hl2min.v can run all of it. There is no processor. The build proves, on the real
// radio, that the HL2's raw sample stream arrives over the SFP lane without loss, and it counts
// everything that could go wrong on the way.
//
// The three clock domains and what runs in each:
//   clk_50m  hl2min_clkseq (clock chip over I2C, transceiver resets), the status of the PCS, the
//            report that goes out on the UART line, and the LEDs.
//   n1_rxc   lane 0's recovered word clock: the aligner, the decoder and the receive side of the
//            PCS (rtl/sfp/sfp_phy.v), the HL2 link's receive chain (rtl/hl2link/hl2_link_rx_top.v,
//            whose "clk_dsp" side runs on the same clock, since the gap filler takes one sample
//            per clock, 125 M/s, above the 76.8 M/s of the stream), the learner of the HL2's
//            addresses, the sample pattern check and the counters.
//   sfp_txc  lane 0's transmit word clock: the transmit side of the PCS with its negotiation, and
//            the frame sender (hl2min_sender.v).
//
// Crossings between the domains (each explained in rtl/hl2link/cdc_word.v and the synchronizer
// chains below):
//   - the counters, n1_rxc to clk_50m, as one wide word that is held still and sent every 16 clocks
//     (cdc_word);
//   - the HL2's MAC and IP addresses, n1_rxc to sfp_txc, in the same way;
//   - the once-a-second tick and the "streaming" flag, clk_50m to sfp_txc, through synchronizer
//     flip-flops;
//   - the PCS status, through sfp_phy's own sfp_xstat.
//
// What the build learns on its own: the classifier in the HL2 link needs to know the HL2's IP
// address to tell its raw frames from other traffic, and nobody has configured it, so the core
// watches for the HL2's reply to the discovery request that hl2min_sender.v sends every second, and
// takes the MAC and IP address from it.

`timescale 1ns / 1ps

module hl2min_core #(
    parameter integer CLK_HZ    = 50_000_000,    // clk_50m (the clock chip sequence's milliseconds)
    parameter integer SEC_CLKS  = 50_000_000,    // clk_50m clocks per UART line
    parameter integer BAUD_DIV  = 434,           // 115,200 baud
    parameter integer I2C_QDIV  = 125,           // 100 kbit/s
    parameter integer TIMER_X   = 1250000,       // PCS link timer, 10 ms of sfp_txc
    parameter integer SGMII     = 0,             // 0: 1000BASE-X with negotiation (as the 88E1111 module is run on this board)
    parameter [31:0]  REG30     = 32'h03C8_0003, // HL2 register 0x30: N = 968, test pattern, raw mode on
    parameter [47:0]  MY_MAC    = 48'h02_54_52_00_00_01,
    parameter [31:0]  MY_IP     = 32'hA9FE_4D01, // 169.254.77.1
    parameter [15:0]  MY_PORT   = 16'd51000,
    parameter integer LANE      = 0              // HL2MIN_LANE: the transceiver lane (= cage) of the HL2; the top level
                                                 // gives this core that lane's clocks, words and status
) (
    input  wire        clk_50m,                  // board oscillator, 50 MHz
    input  wire        rst,                      // clk_50m, synchronous
    // transceiver (sfp_serdes.v in the top level)
    input  wire        sfp_txc,                  // the lane's transmit word clock, 125 MHz
    input  wire        n1_rxc,                   // the lane's recovered receive word clock, 125 MHz
    output wire [9:0]  ln0_tx,                   // 10-bit line symbol to send
    input  wire [9:0]  ln0_rx,                   // 10-bit line symbol received
    input  wire        ln0_rx_vld,               // ln0_rx holds a new word in this clock
    output wire        serdes_por_n,             // quad power-on reset, active low
    output wire [1:0]  ln_rst_n,                 // lane resets, active low
    output wire [1:0]  ln_rx_rst,                // PCS receive resets, active high
    output wire [1:0]  ln_tx_rst,                // PCS transmit resets, active high
    input  wire [3:0]  ln0_stat,                 // asynchronous: PLL lock, receive clock lock, signal detect, ready
    input  wire [11:0] sfp_diag,                 // asynchronous (sfp_serdes.v diag)
    output wire [1:0]  sfp_tx_disable,           // module transmitter off, per cage (1 = off)
    // I2C
    output wire        twi_scl_o,                // SCL level to drive (0 pulls low)
    output wire        twi_sda_o,                // SDA level to drive
    input  wire        twi_scl_i,                // SCL as seen on the pin
    input  wire        twi_sda_i,                // SDA as seen on the pin
    output wire        sel_n19,                  // multiplexer select bit 0
    output wire        sel_p19,                  // bit 1
    output wire        sel_p26,                  // bit 2
    // UART, LEDs (1 = lit)
    output wire        uart_txd,                 // status line, 115,200 baud
    output wire [3:0]  led_on                    // 0 link up, 1 raw frames, 2 any loss, 3 heartbeat
);
    // =========================================================================== start-up (clk_50m)
    // The start-up sequencer: clock chip over I2C, then the lane and PCS resets in order.
    wire       pcs_enable, tx_dis0, i2c_nack;
    wire [2:0] phase;
    wire [7:0] chip_status;
    wire [15:0] attempts, rx_resets;
    wire       rx_locked;
    hl2min_clkseq #(.CLK_HZ(CLK_HZ), .QDIV(I2C_QDIV), .LANE(LANE)) u_seq (
        .clk(clk_50m), .rst(rst),
        .scl_o(twi_scl_o), .sda_o(twi_sda_o), .scl_i(twi_scl_i), .sda_i(twi_sda_i),
        .sel_n19(sel_n19), .sel_p19(sel_p19), .sel_p26(sel_p26),
        .por_n(serdes_por_n), .ln_rst_n(ln_rst_n), .ln_rx_rst(ln_rx_rst), .ln_tx_rst(ln_tx_rst),
        .ln0_pll_lock(ln0_stat[0]), .ln0_signal(ln0_stat[2]), .ln0_aligned(rx_locked),
        .pcs_enable(pcs_enable), .sfp0_tx_disable(tx_dis0),
        .phase(phase), .i2c_nack(i2c_nack), .chip_status(chip_status), .attempts(attempts), .rx_resets(rx_resets)
    );
    // The HL2's cage follows the start-up. The other cage's transmitter is always off (its disable
    // bit stays 1).
    assign sfp_tx_disable = (LANE == 1) ? {tx_dis0, 1'b1} : {1'b1, tx_dis0};

    // =========================================================================== lane 0: PCS
    // The 1000BASE-X PCS with auto-negotiation: turns the 10-bit line symbols into bytes with
    // data valid, error and byte enable (g_rx_*), and bytes from the sender into line symbols
    // (g_tx_*). The st_* flags report its state: link up, negotiation done, symbol synchronization,
    // idles seen, aligner locked.
    wire [7:0] g_rx_d, g_tx_d;
    wire       g_rx_dv, g_rx_er, g_rx_ce, g_rx_rst, g_tx_en, g_tx_rst, tx_link_up;
    wire       st_link, st_an, st_sync, st_idle, st_aligned;
    wire [15:0] st_partner, al_loss, code_err;
    sfp_phy #(.TIMER_X(TIMER_X), .TIMER_SGMII(TIMER_X / 6)) u_phy (
        .txc(sfp_txc), .tx_word(ln0_tx), .rxc(n1_rxc), .rx_vld(ln0_rx_vld), .rx_word(ln0_rx),
        .clk(clk_50m), .cfg_enable(pcs_enable), .cfg_sgmii(SGMII != 0), .cfg_an(1'b1), .cfg_restart_tog(1'b0),
        .rx_rst(g_rx_rst), .g_rx_d(g_rx_d), .g_rx_dv(g_rx_dv), .g_rx_er(g_rx_er), .g_rx_ce(g_rx_ce), .rx_locked(rx_locked),
        .tx_rst(g_tx_rst), .g_tx_d(g_tx_d), .g_tx_en(g_tx_en), .tx_link_up(tx_link_up),
        .st_link_up(st_link), .st_an_done(st_an), .st_rx_sync(st_sync), .st_rx_idle(st_idle),
        .st_aligned(st_aligned), .st_partner(st_partner), .align_losses(al_loss), .code_errors(code_err),
        .irq_link()
    );

    // =========================================================================== HL2 link receive (n1_rxc)
    // The receive chain of the real radio, unchanged, with every counter brought out. The IP
    // address it matches is `hl2_ip_r`, learned below, and 0 until then, which makes every frame
    // "other" until the HL2 has answered a discovery.
    reg  [31:0] hl2_ip_r = 32'd0;
    wire [11:0] samp;
    wire        samp_valid, samp_fill, irq_pkt;
    wire [47:0] samp_index;
    wire [7:0]  safety;
    wire [31:0] c_crc, c_raw, c_other, c_gev, c_gsmp, c_resync, c_lost, last_seq;
    wire [15:0] c_restart, c_code, c_len, c_hmiss, c_drain, c_over, c_idx, c_hovf, c_ringf, c_ringd;
    hl2_link_rx_top #(.RING_AW(12)) u_rx (
        .clk_rx(n1_rxc), .rst_rx(g_rx_rst),
        .g_rx_d(g_rx_d), .g_rx_dv(g_rx_dv), .g_rx_er(g_rx_er), .g_rx_ce(g_rx_ce),
        .clk_dsp(n1_rxc), .rst_dsp(g_rx_rst),
        .cfg_hl2_ip(hl2_ip_r),
        .samp_out(samp), .samp_out_valid(samp_valid), .samp_out_is_fill(samp_fill), .samp_index(samp_index),
        .safety_byte(safety), .irq_safety_change(),
        .raw_version(), .raw_tx_fifo_fill(), .raw_commit_pulse(),
        .irq_pkt_rx(irq_pkt), .irq_gap(),
        .cnt_crc_errors(c_crc), .cnt_raw_frames(c_raw), .cnt_other_frames(c_other),
        .cnt_ring_frames(c_ringf), .cnt_ring_dropped(c_ringd),
        .cnt_gap_events(c_gev), .cnt_gap_samples(c_gsmp), .cnt_resync_events(c_resync),
        .cnt_seq_lost(c_lost), .cnt_seq_restarts(c_restart), .cnt_code_frames(c_code), .cnt_len_errors(c_len),
        .cnt_hl2_missing(c_hmiss), .last_seq(last_seq), .cnt_drain_drops(c_drain), .cnt_overruns(c_over),
        .cnt_idx_drops(c_idx), .hl2_ovf_count(c_hovf),
        .ring_rd_addr(12'd0), .ring_rd_data(), .ring_wr_ptr()
    );

    // ---- the HL2's addresses, from its discovery reply (UDP from port 1024 or 1025, payload EF FE 02 or 03), taken
    // when the frame's FCS was good (it then lands in the CPU ring: irq_pkt within a few clocks of its end).
    // A second copy of the frame input stage (gmii_rx_in) strips the preamble, and a counter `li`
    // numbers the bytes of the frame. The fields of interest are caught as they pass: source MAC (bytes
    // 6 to 11), EtherType (12, 13), IP protocol (23), IP source address (26 to 29), UDP source port (34,
    // 35) and the first three payload bytes (42 to 44). When the frame ends, it is a candidate if it is
    // UDP from port 1024 or 1025 and the payload starts EF FE 02 or EF FE 03. It is accepted only if
    // cpu_rx_ring then reports a committed frame (`irq_pkt`) within 63 clocks, which means that its FCS
    // was good, and then its MAC and IP address are kept.
    wire [7:0] l_d;
    wire       l_act, l_ce;
    gmii_rx_in u_lin (.clk(n1_rxc), .rst(g_rx_rst), .rx_d(g_rx_d), .rx_dv(g_rx_dv), .rx_er(g_rx_er), .rx_ce(g_rx_ce),
                      .data(l_d), .active(l_act), .ce_o(l_ce), .err());
    reg  [15:0] li = 16'd0;
    reg         l_act_d = 1'b0, cand = 1'b0, known = 1'b0;
    reg  [47:0] c_mac = 48'd0, hl2_mac_r = 48'd0;
    reg  [31:0] c_ip = 32'd0;
    reg  [15:0] c_et = 16'd0, c_sport = 16'd0;
    reg  [7:0]  c_proto = 8'd0, c_p0 = 8'd0, c_p1 = 8'd0, c_p2 = 8'd0;
    reg  [5:0]  pend = 6'd0;
    reg  [31:0] c_bytes = 32'd0;
    always @(posedge n1_rxc) begin
        if (g_rx_rst) begin
            l_act_d <= 1'b0; li <= 16'd0; pend <= 6'd0; known <= 1'b0; c_bytes <= 32'd0;
        end else begin
            if (l_ce) begin
                l_act_d <= l_act;
                if (l_act) begin
                    c_bytes <= c_bytes + 32'd1;
                    li <= (l_act_d ? li : 16'd0) + 16'd1;
                    case (l_act_d ? li : 16'd0)
                        16'd6:  c_mac[47:40] <= l_d;  16'd7:  c_mac[39:32] <= l_d;  16'd8:  c_mac[31:24] <= l_d;
                        16'd9:  c_mac[23:16] <= l_d;  16'd10: c_mac[15:8]  <= l_d;  16'd11: c_mac[7:0]   <= l_d;
                        16'd12: c_et[15:8] <= l_d;    16'd13: c_et[7:0] <= l_d;     16'd23: c_proto <= l_d;
                        16'd26: c_ip[31:24] <= l_d;   16'd27: c_ip[23:16] <= l_d;   16'd28: c_ip[15:8] <= l_d;
                        16'd29: c_ip[7:0] <= l_d;     16'd34: c_sport[15:8] <= l_d; 16'd35: c_sport[7:0] <= l_d;
                        16'd42: c_p0 <= l_d;          16'd43: c_p1 <= l_d;          16'd44: c_p2 <= l_d;
                        default: ;
                    endcase
                end else if (l_act_d) begin             // the frame ended
                    cand <= (c_et == 16'h0800) && (c_proto == 8'h11) && (c_sport[15:1] == 15'd512) &&
                            (c_p0 == 8'hEF) && (c_p1 == 8'hFE) && ((c_p2 == 8'h02) || (c_p2 == 8'h03));
                    pend <= 6'd63;
                end
            end
            if (pend != 6'd0) pend <= pend - 6'd1;
            if (pend != 6'd0 && cand && irq_pkt) begin
                known <= 1'b1; hl2_mac_r <= c_mac; hl2_ip_r <= c_ip; pend <= 6'd0;
            end
        end
    end

    // ---- sample check: with the test pattern (register 0x30 bit 1) a real sample equals its index mod 4096
    // (PROTOCOL.md 5.5); samp_index is the index of the next sample after the one out now
    reg [31:0] c_pat = 32'd0;
    wire [47:0] idx_now = samp_index - 48'd1;
    always @(posedge n1_rxc)
        if (g_rx_rst) c_pat <= 32'd0;
        else if (REG30[1] && samp_valid && !samp_fill && (samp != idx_now[11:0])) c_pat <= c_pat + 32'd1;

    // ---- largest single jump of the sequence number (frames missing at once): shows whether the
    // losses are single frames or long outages.
    reg [31:0] lost_d = 32'd0, max_gap = 32'd0;
    always @(posedge n1_rxc)
        if (g_rx_rst) begin lost_d <= 32'd0; max_gap <= 32'd0; end
        else if (c_lost != lost_d) begin
            lost_d <= c_lost;
            if (c_lost - lost_d > max_gap) max_gap <= c_lost - lost_d;
        end

    // ---- counters into clk_50m
    // All counters are gathered into one wide word (`x_a`), sent as a whole through one cdc_word every
    // 16 clocks, and held in `xs` in clk_50m, so the values are consistent with each other.
    localparam integer XW = 32 * 8 + 16 * 3 + 8 + 1;   // 313
    wire [XW-1:0] x_a = {known, safety, hl2_ip_r, c_pat, c_gsmp, c_hovf, c_drain + c_over + c_idx, c_len, c_crc,
                         max_gap, c_lost, c_bytes, c_raw};
    wire [XW-1:0] x_b;
    wire          x_v;
    reg  [3:0]    x_tick = 4'd0;
    always @(posedge n1_rxc) x_tick <= x_tick + 4'd1;
    cdc_word #(.W(XW)) u_x (.clk_a(n1_rxc), .d_a(x_a), .send_a(x_tick == 4'd0), .clk_b(clk_50m), .q_b(x_b), .valid_b(x_v));
    reg [XW-1:0] xs = {XW{1'b0}};
    always @(posedge clk_50m) if (x_v) xs <= x_b;
    wire [31:0] s_raw = xs[31:0], s_bytes = xs[63:32], s_lost = xs[95:64], s_gap = xs[127:96], s_crc = xs[159:128];
    wire [15:0] s_len = xs[175:160], s_ovf = xs[191:176], s_hovf = xs[207:192];
    wire [31:0] s_fill = xs[239:208], s_pat = xs[271:240], s_ip = xs[303:272];
    wire [7:0]  s_sb = xs[311:304];
    wire        s_known = xs[312];

    // =========================================================================== second, report, LEDs (clk_50m)
    // Once per second: `tick` starts a report line, `bps` is the bytes counted in the last second,
    // and `streaming` says whether the raw frame count has moved in the last second, which tells the
    // sender whether it has to restart the HL2's stream.
    reg [$clog2(SEC_CLKS+1)-1:0] sc = 0;
    reg        tick = 1'b0, tick_tog = 1'b0, hb = 1'b0;
    reg [31:0] secs = 32'd0, bytes_d = 32'd0, raw_d = 32'd0, bps = 32'd0;
    reg        streaming = 1'b0;
    always @(posedge clk_50m) begin
        tick <= 1'b0;
        if (sc == SEC_CLKS - 1) begin
            sc <= 0; tick <= 1'b1; tick_tog <= ~tick_tog; hb <= ~hb; secs <= secs + 32'd1;
            bps <= s_bytes - bytes_d; bytes_d <= s_bytes;
            streaming <= (s_raw != raw_d); raw_d <= s_raw;
        end else sc <= sc + 1'b1;
    end

    reg  [3:0]  ln_a = 4'd0, ln_b = 4'd0;
    reg  [11:0] dg_a = 12'd0, dg_b = 12'd0;
    always @(posedge clk_50m) begin ln_a <= ln0_stat; ln_b <= ln_a; dg_a <= sfp_diag; dg_b <= dg_a; end
    wire [7:0]  pcs_bits = {i2c_nack, (LANE == 1) ? dg_b[11] : dg_b[9], 1'b0, st_aligned, st_idle, st_sync, st_an, st_link};
    // The line the report prints (docs/HL2MIN.md section 5). `pcs_bits` packs the PCS flags: link up,
    // negotiation done, synchronized, idles seen, aligned, a spare bit, a diagnostic of the lane's
    // receive buffer, and a missing I2C acknowledge.
    // chip ID (Gowin OTP DNA, raw[95:32]; rtl/net/chip_dna.v, SUG283-3.6.1E section 8.9; docs/NET_ID.md), read once after the reset
    wire [128:0] dna_raw;
    wire         dna_done;
    chip_dna u_dna (.clk(clk_50m), .rst(rst), .raw(dna_raw), .done(dna_done));
    wire [63:0]  chip_id = dna_done ? dna_raw[95:32] : 64'd0;
    wire [20*32-1:0] fields = {
        chip_id[31:0], chip_id[63:32], {16'd0, attempts}, {24'd0, chip_status}, s_ip, {24'd0, s_sb}, s_pat, s_fill, {16'd0, s_hovf}, {16'd0, s_ovf},
        {16'd0, s_len}, s_crc, s_gap, s_lost, bps, s_raw, {24'd0, pcs_bits}, {28'd0, ln_b}, {29'd0, phase}, secs};
    hl2min_report #(.NF(20), .BAUD_DIV(BAUD_DIV)) u_rep (.clk(clk_50m), .rst(rst), .tick(tick), .fields(fields), .txd(uart_txd));

    // LEDs: 0 link up, 1 raw frames arriving (stretched to 0.1 s so that it is visible), 2 any loss
    // since start, 3 heartbeat (toggles once a second)
    reg [31:0] raw_seen = 32'd0;
    reg [$clog2(SEC_CLKS / 10 + 1)-1:0] fr_led = 0;
    always @(posedge clk_50m) begin
        raw_seen <= s_raw;
        if (s_raw != raw_seen) fr_led <= SEC_CLKS / 10;
        else if (fr_led != 0) fr_led <= fr_led - 1'b1;
    end
    wire any_loss = (s_lost != 32'd0) || (s_ovf != 16'd0) || (s_fill != 32'd0) || (s_pat != 32'd0) || (s_len != 16'd0);
    assign led_on = {hb, any_loss, fr_led != 0, st_link};

    // =========================================================================== sender (sfp_txc)
    // The sender runs in the transmit clock. It gets the once-a-second tick as a toggle (so that it
    // survives the crossing) through three flip-flops and an edge detect, the streaming flag through
    // two flip-flops, and the HL2's addresses through a cdc_word every 16 clocks.
    reg [2:0]  tk_s = 3'd0;
    reg [1:0]  st_s = 2'd0;
    always @(posedge sfp_txc) begin tk_s <= {tk_s[1:0], tick_tog}; st_s <= {st_s[0], streaming}; end
    wire [80:0] a_b;
    wire        a_v;
    reg  [3:0]  a_tick = 4'd0;
    reg  [80:0] a_q = 81'd0;
    always @(posedge n1_rxc) a_tick <= a_tick + 4'd1;
    cdc_word #(.W(81)) u_a (.clk_a(n1_rxc), .d_a({known, hl2_mac_r, hl2_ip_r}), .send_a(a_tick == 4'd0),
                            .clk_b(sfp_txc), .q_b(a_b), .valid_b(a_v));
    always @(posedge sfp_txc) if (a_v) a_q <= a_b;
    hl2min_sender #(.MY_MAC(MY_MAC), .MY_IP(MY_IP), .MY_PORT(MY_PORT), .REG30(REG30)) u_tx (
        .clk(sfp_txc), .rst(g_tx_rst), .tick(tk_s[2] ^ tk_s[1]), .known(a_q[80]),
        .hl2_mac(a_q[79:32]), .hl2_ip(a_q[31:0]), .streaming(st_s[1]), .link_up(tx_link_up),
        .gmii_txd(g_tx_d), .gmii_tx_en(g_tx_en), .cnt_sent()
    );
endmodule
