// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// PCS (physical coding sublayer) of the SFP lane: 1000BASE-X (IEEE 802.3 clauses 36 and 37) and the MAC
// side of SGMII, at the level of symbols (docs/SFP_LINKS.md section 4). It sits between the 8b/10b
// decoder and coder on one side (bytes with a K flag, one per clock) and a MAC or a frame producer on the
// other (GMII bytes). It was written from the standard.
//
// What it does, for a beginner:
//   - Transmit: when there is no frame it sends idle ordered sets, and when the link is still starting it
//     sends configuration words. A frame is sent as /S/ (start of packet) in place of its first preamble
//     byte, the data bytes, and /T/ (end of packet), usually followed by /R/ (carrier extend) so that
//     the idle after the frame starts on an even symbol position.
//   - Receive: it recognizes the same ordered sets in the incoming symbols, and gives the frame bytes to
//     the MAC with a data-valid flag, and finds out whether the partner is sending configuration words or
//     idles.
//   - Auto-negotiation (clause 37): the two ends of a link first exchange 16-bit configuration words
//     (/C/ sets) to say what they can do, acknowledge each other's word, and then start sending idles
//     and then data. Here that means "full duplex" for 1000BASE-X (word 0x0020) and, in SGMII mode, the
//     link status that the copper module reports about its own connection (bit 15 link, bits 11:10 speed).
//
// The ordered sets used (K codes are control symbols, D codes data symbols, written K28.5 for "code 28,
// sub-code 5"):
//   /I1/ K28.5 D5.6 (sent when the running disparity before it is positive), /I2/ K28.5 D16.2
//   /C1/ K28.5 D21.5 lo hi, /C2/ K28.5 D2.2 lo hi, alternating (lo, hi: the 16-bit configuration word)
//   /S/ K27.7 in place of a preamble byte, /T/ K29.7, /R/ K23.7 (twice when the frame ended so that the
//   next idle would start on an odd symbol)
// The running disparity (see sfp_enc20.v for what that is) matters for idle: the first symbol of an
// idle set is a comma that is the same in both forms, and the second one must be the form that brings
// the disparity back, which the coder's `enc_rd` tells.
//
// Two clocks. The receive side (rxc, the recovered clock) does the ordered sets, the three match flags of
// clause 37 (three equal configuration words in a row, the same with the acknowledge bit, and three
// idles) and the frame to the MAC. The transmit side (txc) does the auto-negotiation states and the
// symbol sequencer. The receive side's word and flags cross into txc as a held word (sfp_xstat), and
// link_up crosses back through two registers.
//
// The coder (rtl/n1/enc_8b10b.v) is outside: tx_d and tx_k go to it through one register (in sfp_phy.v), and
// `enc_rd` is its running disparity before the symbol it codes now, which is the one this module
// presented one clock earlier.
//
// Byte enable: the transceiver's receive buffer is read while it is not almost empty, so some receive
// clocks carry no word (`rx_vld` low). The PCS holds its outputs in such a clock and sets `mac_rx_ce` low,
// and the MAC must not take the held byte again. `link_up` is a register, and the idle's second symbol
// reads the encoder's disparity in the clock in which it is presented (`enc_rd`).

`timescale 1ns / 1ps

module sfp_pcs #(
    parameter integer TIMER_X     = 1250000,  // link timer 1000BASE-X: 10 ms of txc
    parameter integer TIMER_SGMII = 200000    // SGMII: 1.6 ms
) (
    // ---- receive clock
    input  wire        rxc,              // recovered receive word clock
    input  wire        rx_rst,           // receive side reset, active high
    input  wire        rx_vld,           // a new symbol on rx_d, rx_k, rx_err in this clock
    input  wire [7:0]  rx_d,             // decoded symbol
    input  wire        rx_k,             // the symbol is a control symbol
    input  wire        rx_err,           // the symbol is not in the 8b/10b alphabet
    input  wire        rx_locked,        // the aligner is locked
    output reg  [7:0]  mac_rx_data = 8'd0,   // frame byte to the MAC, starting with the preamble
    output reg         mac_rx_dv = 1'b0,     // data valid: high from /S/ to /T/
    output reg         mac_rx_ce = 1'b1,     // mac_rx_data / dv / er are new this clock (no symbol: held, ce 0)
    output reg         mac_rx_er = 1'b0,     // error in this byte (invalid code, or a frame cut short)
    // ---- transmit clock
    input  wire        txc,              // transmit word clock
    input  wire        tx_rst,           // transmit side reset, active high
    input  wire        cfg_sgmii,        // 1: SGMII, 0: 1000BASE-X
    input  wire        cfg_an,           // 0: no negotiation, idle at once, link up when idles are seen
    input  wire        cfg_restart,      // pulse
    input  wire [7:0]  mac_tx_data,      // frame byte from the MAC, preamble first
    input  wire        mac_tx_en,        // the byte is part of a frame
    output wire [7:0]  tx_d,             // symbol to the coder
    output wire        tx_k,             // the symbol is a control symbol
    input  wire        enc_rd,           // the coder's running disparity (1: positive) before the current symbol
    output wire        link_up,          // the link is up and frames are sent
    output wire        an_done,          // negotiation complete
    output wire        rx_sync,          // receive side locked (as seen in txc)
    output wire        rx_idle,          // three idles in a row seen
    output reg  [15:0] partner = 16'd0   // the partner's configuration word, as acknowledged
) /* synthesis syn_srlstyle = "registers" */;

    // The symbols as bytes in the {y[2:0], x[4:0]} packing of the code table: K28.5 (comma), K27.7
    // (/S/), K29.7 (/T/), K23.7 (/R/), and D5.6, D16.2 (the idle second symbols), D21.5, D2.2 (the
    // configuration set markers).
    localparam [7:0] K_COMMA = 8'hBC, K_S = 8'hFB, K_T = 8'hFD, K_R = 8'hF7;
    localparam [7:0] D_I1 = 8'hC5, D_I2 = 8'h50, D_C1 = 8'hB5, D_C2 = 8'h42;

    // =================================================================== receive side (rxc)
    // `link_r2` is link_up in the receive clock. A frame start /S/ is only taken while the link is up.
    reg        link_r1 = 1'b0, link_r2 = 1'b0;
    always @(posedge rxc) begin link_r1 <= link_up; link_r2 <= link_r1; end

    // `prev_comma` says that the previous symbol was a comma, so that the symbol now is the second
    // one of an ordered set. `in_frame` is high between /S/ and /T/. `cst` follows a configuration set:
    // after the /C/ marker the next two symbols are the low and high byte of the word.
    reg        prev_comma = 1'b0, in_frame = 1'b0;
    reg [1:0]  cst = 2'd0;               // 0: none, 1: expect lo, 2: expect hi
    reg [7:0]  cfg_lo = 8'd0;
    reg [15:0] rx_cfg = 16'd0;
    // Match counters, each saturating at 3: configuration words equal to the last (ignoring the
    // acknowledge bit, mask 0xBFFF), words equal with the acknowledge bit set, and idle sets in a row.
    reg [1:0]  n_same = 2'd0, n_ack = 2'd0, n_idle = 2'd0;
    wire [15:0] cfg_now = {rx_d, cfg_lo};
    wire        same_now = ((cfg_now ^ rx_cfg) & 16'hBFFF) == 16'd0;

    always @(posedge rxc) begin
        if (rx_rst || !rx_locked) begin
            prev_comma <= 1'b0; in_frame <= 1'b0; cst <= 2'd0;
            n_same <= 2'd0; n_ack <= 2'd0; n_idle <= 2'd0; rx_cfg <= 16'd0;
            mac_rx_dv <= 1'b0; mac_rx_er <= 1'b0; mac_rx_ce <= 1'b1;
        end else if (!rx_vld) begin
            mac_rx_ce <= 1'b0;                // no word this clock: hold the outputs, ce low
        end else begin
            mac_rx_ce <= 1'b1;
            prev_comma <= rx_k && !rx_err && (rx_d == K_COMMA);
            if (in_frame) begin
                // In a frame: /T/ ends it, a comma means it was cut short (an error), anything else is a
                // data byte (and a K symbol or an invalid code marks the byte as an error).
                if (rx_k && !rx_err && (rx_d == K_T)) begin
                    in_frame <= 1'b0; mac_rx_dv <= 1'b0;
                end else if (rx_k && !rx_err && (rx_d == K_COMMA)) begin
                    in_frame <= 1'b0; mac_rx_dv <= 1'b1; mac_rx_er <= 1'b1;   // frame cut short
                end else begin
                    mac_rx_dv <= 1'b1; mac_rx_data <= rx_d; mac_rx_er <= rx_err || rx_k;
                end
            end else begin
                // Not in a frame: look for configuration sets, idles and /S/.
                mac_rx_dv <= 1'b0; mac_rx_er <= 1'b0;
                if (rx_err) begin
                    cst <= 2'd0; n_same <= 2'd0; n_ack <= 2'd0; n_idle <= 2'd0;
                end else if (cst == 2'd1) begin
                    cfg_lo <= rx_d; cst <= 2'd2;
                end else if (cst == 2'd2) begin
                    // The configuration word is complete: compare it with the last one.
                    cst    <= 2'd0;
                    rx_cfg <= cfg_now;
                    n_idle <= 2'd0;
                    if (same_now) begin
                        if (n_same != 2'd3) n_same <= n_same + 2'd1;
                        if (cfg_now[14] && rx_cfg[14]) begin
                            if (n_ack != 2'd3) n_ack <= n_ack + 2'd1;
                        end else n_ack <= {1'b0, cfg_now[14]};
                    end else begin
                        n_same <= 2'd1; n_ack <= {1'b0, cfg_now[14]};
                    end
                end else if (prev_comma && !rx_k) begin
                    // The second symbol of an ordered set: a /C/ marker starts a configuration word,
                    // anything else counts as an idle.
                    if ((rx_d == D_C1) || (rx_d == D_C2)) cst <= 2'd1;
                    else begin
                        n_same <= 2'd0; n_ack <= 2'd0;
                        if (n_idle != 2'd3) n_idle <= n_idle + 2'd1;
                    end
                end else if (rx_k && (rx_d == K_S) && link_r2) begin
                    // /S/ stands for the first preamble byte 0x55.
                    in_frame <= 1'b1; mac_rx_dv <= 1'b1; mac_rx_data <= 8'h55;
                end
            end
        end
    end

    // The three match flags of clause 37, and the receive side's word with the lock flag, sent to the transmit clock.
    wire f_ability_r = (n_same == 2'd3);
    wire f_ack_r     = (n_ack == 2'd3);
    wire f_idle_r    = (n_idle == 2'd3);

    wire [19:0] xs;
    sfp_xstat #(.W(20), .AGE(7)) u_xs (
        .clk_a(rxc), .d_a({rx_locked, f_idle_r, f_ack_r, f_ability_r, rx_cfg}),
        .clk_b(txc), .q_b(xs), .alive(), .upd_b()
    );
    wire [15:0] p_cfg     = xs[15:0];
    wire        f_ability = xs[16], f_ack = xs[17], f_idle = xs[18], f_sync = xs[19];
    assign rx_sync = f_sync;
    assign rx_idle = f_idle;

    // =================================================================== auto-negotiation (txc)
    // States (clause 37, simplified): A_RESTART (send empty configuration words for the link timer so
    // the partner sees the restart), A_ABILITY (send our ability word until the partner's word is
    // seen three times), A_ACK (send it with the acknowledge bit 14 until the partner acknowledges),
    // A_COMPLETE (wait the link timer), A_IDLE (send idles until the partner's idles are seen), A_OK
    // (link up, data may flow). A partner word of 0 (a restart) or a loss of synchronization
    // sends it back to A_RESTART. Our word is 0x0020 (full duplex) for 1000BASE-X and 0x0001 for
    // SGMII (the MAC side), and for SGMII the link comes up only with the link bit (15) of the partner's word.
    // `xmit` is what is sent: 0 configuration, 1 idle, 2 data.
    localparam [2:0] A_RESTART = 3'd0, A_ABILITY = 3'd1, A_ACK = 3'd2, A_COMPLETE = 3'd3,
                     A_IDLE = 3'd4, A_OK = 3'd5;
    reg [2:0]  an = A_RESTART;
    reg [20:0] timer = 21'd0;
    reg        timer_done = 1'b0;
    wire [20:0] timer_top = cfg_sgmii ? TIMER_SGMII[20:0] : TIMER_X[20:0];
    reg        sg_q = 1'b0, an_q = 1'b0;
    wire [15:0] base = cfg_sgmii ? 16'h0001 : 16'h0020;
    wire        p_zero = (p_cfg & 16'hBFFF) == 16'd0;
    reg  [15:0] tx_cfg = 16'd0;
    reg  [1:0]  xmit = 2'd0;            // 0: configuration, 1: idle, 2: data

    always @(posedge txc) begin
        sg_q <= cfg_sgmii; an_q <= cfg_an;
        timer_done <= (timer >= timer_top);
        if (!timer_done) timer <= timer + 21'd1;
        if (tx_rst || !f_sync || cfg_restart || (sg_q != cfg_sgmii) || (an_q != cfg_an)) begin
            an <= A_RESTART; timer <= 21'd0; timer_done <= 1'b0; xmit <= cfg_an ? 2'd0 : 2'd1; tx_cfg <= 16'd0;
        end else if (!cfg_an) begin
            an <= A_RESTART; xmit <= f_idle ? 2'd2 : 2'd1;
        end else case (an)
            A_RESTART: begin
                xmit <= 2'd0; tx_cfg <= 16'd0;
                if (timer_done) an <= A_ABILITY;
            end
            A_ABILITY: begin
                tx_cfg <= base;
                if (f_ability && !p_zero) an <= A_ACK;
            end
            A_ACK: begin
                tx_cfg <= base | 16'h4000;
                if (f_ability && p_zero) begin an <= A_RESTART; timer <= 21'd0; timer_done <= 1'b0; end
                else if (f_ack) begin
                    an <= A_COMPLETE; partner <= p_cfg; timer <= 21'd0; timer_done <= 1'b0;
                end
            end
            A_COMPLETE: begin
                if (f_ability && p_zero) begin an <= A_RESTART; timer <= 21'd0; timer_done <= 1'b0; end
                else if (timer_done) begin an <= A_IDLE; xmit <= 2'd1; timer <= 21'd0; timer_done <= 1'b0; end
            end
            A_IDLE: begin
                if (f_ability && p_zero) begin an <= A_RESTART; timer <= 21'd0; timer_done <= 1'b0; end
                else if (timer_done && f_idle) begin an <= A_OK; xmit <= 2'd2; end
            end
            A_OK: begin
                if (f_ability) begin
                    an <= A_RESTART; timer <= 21'd0; timer_done <= 1'b0; xmit <= 2'd0; tx_cfg <= 16'd0;
                end
            end
            default: an <= A_RESTART;
        endcase
    end

    assign an_done = (an == A_OK);
    // `link_up` is a register, because the path from the negotiation state through link_up, start, and the
    // symbol choice to the encoder would be 14 logic levels, too slow for 125 MHz.
    reg link_up_r = 1'b0;
    always @(posedge txc) link_up_r <= f_sync && (cfg_an ? ((an == A_OK) && (!cfg_sgmii || partner[15])) : (xmit == 2'd2));
    assign link_up = link_up_r;

    // =================================================================== symbol sequencer (txc)
    // The sequencer makes the symbol stream, two clocks per ordered set. States: S_K (the first symbol: a
    // comma, or /S/ if a frame starts now), S_ID (second symbol of an idle), S_C1 to S_C3 (second symbol
    // and the two bytes of a configuration set), S_DATA (frame bytes, then /T/), S_R (/R/ after /T/) and
    // S_R2 (a second /R/ when the frame ended at an odd position, which keeps the next idle on an even one).
    // `odd` follows the symbol position, `c2` alternates /C1/ and /C2/. A frame starts only from S_K, i.e.
    // at an even position, while the link is up.
    localparam [2:0] S_K = 3'd0, S_ID = 3'd1, S_C1 = 3'd2, S_C2 = 3'd3, S_C3 = 3'd4, S_DATA = 3'd5,
                     S_R = 3'd6, S_R2 = 3'd7;
    reg [2:0] ts = S_K;
    reg       c2 = 1'b0, odd = 1'b0, need_r2 = 1'b0;
    wire      start = (xmit == 2'd2) && mac_tx_en && link_up;

    always @(posedge txc) begin
        if (tx_rst) begin
            ts <= S_K; c2 <= 1'b0; odd <= 1'b0;
        end else begin
            odd <= ~odd;
            case (ts)
                S_K: begin
                    odd <= 1'b1;
                    if (start) ts <= S_DATA;
                    else if (xmit == 2'd0) ts <= S_C1;
                    else ts <= S_ID;
                end
                S_ID:   ts <= S_K;
                S_C1:   ts <= S_C2;
                S_C2:   ts <= S_C3;
                S_C3:   begin ts <= S_K; c2 <= ~c2; end
                S_DATA: if (!mac_tx_en) begin ts <= S_R; need_r2 <= odd; end
                S_R:    ts <= need_r2 ? S_R2 : S_K;
                S_R2:   ts <= S_K;
                default: ts <= S_K;
            endcase
        end
    end

    // The outputs are continuous assignments and not an always @(*) block, because a simulator runs such
    // a block only on a change of its inputs, and with a quiet MAC there is none after reset.
    assign tx_k = (ts == S_K) || (ts == S_R) || (ts == S_R2) || ((ts == S_DATA) && !mac_tx_en);
    assign tx_d = (ts == S_K)    ? (start ? K_S : K_COMMA) :
                  (ts == S_ID)   ? (enc_rd ? D_I1 : D_I2) :     // the encoder is one clock behind, so its disparity now is the one before the K28.5 of S_K
                  (ts == S_C1)   ? (c2 ? D_C2 : D_C1) :
                  (ts == S_C2)   ? tx_cfg[7:0] :
                  (ts == S_C3)   ? tx_cfg[15:8] :
                  (ts == S_DATA) ? (mac_tx_en ? mac_tx_data : K_T) : K_R;

endmodule
