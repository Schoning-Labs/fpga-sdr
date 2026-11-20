// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Long zero-loss testbench for the HL2 link on transceiver lane 0 (docs/HL2_SFP.md section 8). It runs the receive path as
// the chip has it, rtl/sfp/sfp_phy.v (aligner, 8b/10b decoder and the PCS in 1000BASE-X with negotiation) into
// rtl/hl2link/hl2_link_rx_top.v (gmii_rx_in, eth_frame_rx, raw_frame_buffer, gap_filler and cpu_rx_ring), with the gap
// filler's side on its own 120 MHz clock, against a synthetic stream that looks like a Hermes-Lite 2 (HL2). The
// terms used below (PCS, 8b/10b, ordered set, FCS, UDP) are explained in docs/learn/GLOSSARY.md, and the raw frame format in
// the header of tb_h1_link_rx.v.
//
// The stream is made like this:
//   - raw frames in the wire format of PROTOCOL.md 5.2 (version 1 header of 20 bytes, sequence number, first sample index, N,
//     test pattern samples, FCS), produced at the rate of an ADC clock of 76.8 MHz plus or minus PPM parts per million;
//   - in bursts: the sender collects BURST frames and then sends them back to back with the minimum gap (12 bytes), so the
//     receive chain sees the longest run of frames the line can carry, and a 60 byte non-raw frame follows after every 16th
//     frame, for the CPU ring;
//   - through a model of the copper SFP module (a 1000BASE-X sender after IEEE 802.3 clause 36, with /S/ on even positions,
//     /T/, /R/, idle, and the negotiation of clause 37) on the HL2's clock, PPM off ours, and through the lane model. The
//     receive buffer is read by a clock 2.5 % faster than the words come, so some clocks carry no word, as on the board.
//
// Pass: every sample out of the gap filler equals its index mod 4096 (the test pattern), there is no fill sample, real samples
// equal committed frames times N, every loss counter is 0 (sequence, FCS, code, length, drain, overrun, index, gap events,
// resyncs), and all frames that were sent arrived (by count and by last sequence number). It prints "PASS", or "FAIL: n errors"
// after the individual ERROR lines.
//   +define+N=<samples per frame> (default 968, and 5968 is the largest, a jumbo frame),
//   +define+BURST=<frames> (default 4), +define+SIM_US=<microseconds of stream> (default 2000),
//   +define+PPM_NEG for -100 ppm (default +100)
//   +define+STALE: the radio has just started while the HL2 is still streaming from an earlier session, so the classifier has
//     no HL2 address yet (0) and every raw frame goes to the CPU ring. The bench measures how long a 60 byte frame (a discovery
//     reply) between them stays readable in the ring, then stops the stream (as the firmware's broadcast stop does) and checks
//     that a reply sent after that stays in the ring and reads back intact.
// Run, from the repo root: bash sim/hl2sfp/run.sh [defines]

`timescale 1ps / 1fs

module tb_hl2_sfp;
// 8b/10b encode and decode functions (enc8b10b_d, enc8b10b_k, dec8b10b), found through the -I rtl/n1 of run.sh.
`include "tab_8b10b.vh"

`ifdef N
    localparam integer NS = `N;
`else
    localparam integer NS = 968;
`endif
`ifdef BURST
    localparam integer BURST = `BURST;
`else
    localparam integer BURST = 4;
`endif
`ifdef SIM_US
    localparam integer SIM_US = `SIM_US;
`else
    localparam integer SIM_US = 2000;
`endif
`ifdef PPM_NEG
    localparam real PPM = -100.0;
`else
    localparam real PPM = 100.0;
`endif
    localparam [31:0] HL2_IP = 32'h0a63_0002;
`ifdef STALE
    localparam [31:0] CFG_IP = 32'd0;           // the session has not learned the HL2's address yet
`else
    localparam [31:0] CFG_IP = HL2_IP;
`endif

    // ------------------------------------------------------------------ clocks (ps)
    // sfp_txc is the lane's 125 MHz transmit word clock (half period 4000 ps), clk_dsp the gap filler's 120 MHz (half period 4166.667 ps),
    // clk the 50 MHz status clock. pclk is the HL2's 125 MHz byte clock, run PPM parts per million fast: half period 4000 / (1 + PPM * 1e-6).
    // g_rxc is the clock that reads the lane's receive words and the DUT's receive clock, with a half period of 3900 ps and so a
    // period of 7800 ps against 8000 ps, about 2.5 % faster than the words come.
    // ------------------------------------------------------------------ clocks (ps)
    reg sfp_txc = 0;  initial begin #1300; forever #4000 sfp_txc = ~sfp_txc; end
    reg clk_dsp = 0;  initial begin #900;  forever #4166.667 clk_dsp = ~clk_dsp; end
    reg clk = 0;      initial begin #300;  forever #10000 clk = ~clk; end         // the status side (50 MHz)
    real PH;
    initial PH = 4000.0 / (1.0 + PPM * 1e-6);
    reg pclk = 0;     initial begin #2100; forever #(PH) pclk = ~pclk; end
    reg g_rxc = 0;    initial begin #700;  forever #3900 g_rxc = ~g_rxc; end

    integer errors = 0;
    `define CHECK(cond, msg) if ((cond) !== 1'b1) begin errors = errors + 1; $display("ERROR t=%0t: %s", $time, msg); end

    // ------------------------------------------------------------------ DUT
    wire [9:0] ln0_tx, d_rx, p_tx;
    wire       d_rxc;
    reg  [9:0] gq [0:255];
    integer    gw = 0, gr = 0, gaps = 0;
    reg  [9:0] g_rx = 10'd0;
    reg        g_vld = 1'b0;
    // The lane's receive words are queued (256 entries) and read by g_rxc, so that some of its clocks find the queue empty
    // and carry no word (g_vld 0), as the transceiver's receive buffer does on the board. `gaps` counts them.
    always @(posedge d_rxc) begin gq[gw % 256] = d_rx; gw = gw + 1; end
    always @(posedge g_rxc) begin
        if (gr < gw - 2) begin g_rx <= gq[gr % 256]; g_vld <= 1'b1; gr = gr + 1; end
        else begin g_vld <= 1'b0; gaps = gaps + 1; end
    end
    // The lane model carries the 10 bit words between the bench's module side (pclk) and the PCS, with the receive words cut at a
    // bit position (OFFSET 6) as a receiver sees them before its aligner.
    sfp_lane_model #(.W(10), .OFFSET(6)) u_lane (.tx_clk(pclk), .tx_word(p_tx), .rx_clk(d_rxc), .rx_word(d_rx),
                                                 .err(10'd0), .cut(1'b0));
    reg        enable = 1'b0;
    wire [7:0] g_d;
    wire       g_dv, g_er, g_ce, g_rst, st_link;
    // The PCS of the chip, with its link timers shortened (TIMER_X 3000 is 24 us of sfp_txc) and auto-negotiation on, in 1000BASE-X.
    sfp_phy #(.TIMER_X(3000), .TIMER_SGMII(800)) u_phy (
        .txc(sfp_txc), .tx_word(ln0_tx), .rxc(g_rxc), .rx_vld(g_vld), .rx_word(g_rx),
        .clk(clk), .cfg_enable(enable), .cfg_sgmii(1'b0), .cfg_an(1'b1), .cfg_restart_tog(1'b0),
        .rx_rst(g_rst), .g_rx_d(g_d), .g_rx_dv(g_dv), .g_rx_er(g_er), .g_rx_ce(g_ce), .rx_locked(),
        .tx_rst(), .g_tx_d(8'd0), .g_tx_en(1'b0), .tx_link_up(),
        .st_link_up(st_link), .st_an_done(), .st_rx_sync(), .st_rx_idle(), .st_aligned(), .st_partner(),
        .align_losses(), .code_errors(), .irq_link()
    );
    reg rst_dsp = 1'b1;
    wire [11:0] samp;
    wire        sv, sfill;
    wire [47:0] sidx;
    wire [31:0] c_crc, c_raw, c_other, c_gev, c_gsmp, c_rsy, c_lost, last_seq;
    wire [15:0] c_rst, c_code, c_len, c_hm, c_drain, c_over, c_idx, c_ringf, c_ringd;
    reg  [11:0] rd_a = 12'd0;
    wire [7:0]  rd_d;
    // The HL2 link receive path, with the CPU ring at its fixed 4 KB; its address comes from CFG_IP.
    hl2_link_rx_top #(.RING_AW(12)) dut (
        .clk_rx(g_rxc), .rst_rx(g_rst), .g_rx_d(g_d), .g_rx_dv(g_dv), .g_rx_er(g_er), .g_rx_ce(g_ce),
        .clk_dsp(clk_dsp), .rst_dsp(rst_dsp), .cfg_hl2_ip(CFG_IP),
        .samp_out(samp), .samp_out_valid(sv), .samp_out_is_fill(sfill), .samp_index(sidx),
        .safety_byte(), .irq_safety_change(), .raw_version(), .raw_tx_fifo_fill(), .raw_commit_pulse(),
        .irq_pkt_rx(), .irq_gap(),
        .cnt_crc_errors(c_crc), .cnt_raw_frames(c_raw), .cnt_other_frames(c_other),
        .cnt_ring_frames(c_ringf), .cnt_ring_dropped(c_ringd),
        .cnt_gap_events(c_gev), .cnt_gap_samples(c_gsmp), .cnt_resync_events(c_rsy),
        .cnt_seq_lost(c_lost), .cnt_seq_restarts(c_rst), .cnt_code_frames(c_code), .cnt_len_errors(c_len),
        .cnt_hl2_missing(c_hm), .last_seq(last_seq), .cnt_drain_drops(c_drain), .cnt_overruns(c_over),
        .cnt_idx_drops(c_idx), .hl2_ovf_count(),
        .ring_rd_addr(rd_a), .ring_rd_data(rd_d), .ring_wr_ptr()
    );

    // ------------------------------------------------------------------ synthetic HL2 (pclk): bytes with dv into a queue
    // Frame k has the first sample index k * N. It may go out once the ADC (76.8 MHz plus PPM) has made (k + 1) * N samples,
    // and frames go in bursts.
    // One byte of the Ethernet CRC-32 (reflected polynomial 0xEDB88320).
    function [31:0] crc_byte(input [31:0] c, input [7:0] b);
        integer i; reg [31:0] x;
        begin x = c ^ {24'd0, b}; for (i = 0; i < 8; i = i + 1) x = x[0] ? ((x >> 1) ^ 32'hEDB88320) : (x >> 1); crc_byte = x; end
    endfunction
    reg [7:0] fb [0:9100];
    integer   flen;
    // Builds raw frame k in fb[] and its length in flen: Ethernet header, IPv4 header, UDP header, the 20 byte raw header,
    // N samples of 12 bit packed two to every three bytes, and the FCS.
    task build_raw(input integer k);
        integer i, s; reg [47:0] idx; reg [11:0] a, b2; reg [15:0] ul, il; reg [31:0] c;
        begin
            // UDP length = 8 (UDP header) + 20 (raw header) + 3N/2 (samples), IP length = that + 20 (IPv4 header).
            ul = 8 + 20 + 3 * NS / 2; il = ul + 20;
            for (i = 0; i < 6; i = i + 1) fb[i] = 8'h02;                       // destination: us
            fb[6] = 8'h02; fb[7] = 8'h00; fb[8] = 8'h00; fb[9] = 8'h00; fb[10] = 8'h00; fb[11] = 8'h02;
            fb[12] = 8'h08; fb[13] = 8'h00;
            // IPv4 header: version 4 with a 20 byte header, no fragmentation, TTL 0x40, protocol 0x11 (UDP), source address the HL2's.
            fb[14] = 8'h45; fb[15] = 8'h00; fb[16] = il[15:8]; fb[17] = il[7:0]; fb[18] = 0; fb[19] = 0;
            fb[20] = 8'h40; fb[21] = 0; fb[22] = 8'h40; fb[23] = 8'h11; fb[24] = 0; fb[25] = 0;
            fb[26] = HL2_IP[31:24]; fb[27] = HL2_IP[23:16]; fb[28] = HL2_IP[15:8]; fb[29] = HL2_IP[7:0];
            fb[30] = 8'hA9; fb[31] = 8'hFE; fb[32] = 8'h4D; fb[33] = 8'h01;
            // UDP source port 1024 (0x0400) and destination port 51000 (0xC738).
            fb[34] = 8'h04; fb[35] = 8'h00; fb[36] = 8'hC7; fb[37] = 8'h38; fb[38] = ul[15:8]; fb[39] = ul[7:0];
            fb[40] = 0; fb[41] = 0;
            idx = k * NS;
            // Raw header: 0xA5 marker, version 1, flags (bit 0 = test pattern, and bit 4 = first frame of a stream, which is set on
            // frame 0 only, so 0x11 there and 0x01 after),
            // Raw header: 0xA5 marker, version 1, flags (0x11 on the first frame, which marks the start of a stream, else 0x01),
            // the safety status byte 0x01, then the sequence number (4 bytes), the first sample index (6 bytes), N (2 bytes) and
            // three more 16 bit fields that stay 0 here (the HL2's own overflow count and the like).
            fb[42] = 8'hA5; fb[43] = 8'h01; fb[44] = (k == 0) ? 8'h11 : 8'h01; fb[45] = 8'h01;
            fb[46] = k[31:24]; fb[47] = k[23:16]; fb[48] = k[15:8]; fb[49] = k[7:0];
            fb[50] = idx[47:40]; fb[51] = idx[39:32]; fb[52] = idx[31:24]; fb[53] = idx[23:16]; fb[54] = idx[15:8]; fb[55] = idx[7:0];
            fb[56] = NS / 256; fb[57] = NS % 256; fb[58] = 0; fb[59] = 0; fb[60] = 0; fb[61] = 0;
            s = 62;
            // Two samples a and b make three bytes: a[11:4], then a[3:0] with b[11:8], then b[7:0]. The test pattern is the sample index mod 4096.
            for (i = 0; i < NS; i = i + 2) begin
                a = (idx + i) & 12'hFFF; b2 = (idx + i + 1) & 12'hFFF;
                fb[s] = a[11:4]; fb[s+1] = {a[3:0], b2[11:8]}; fb[s+2] = b2[7:0]; s = s + 3;
            end
            // FCS: CRC-32 over the whole frame, sent least significant byte first.
            c = 32'hFFFFFFFF; for (i = 0; i < s; i = i + 1) c = crc_byte(c, fb[i]); c = ~c;
            fb[s] = c[7:0]; fb[s+1] = c[15:8]; fb[s+2] = c[23:16]; fb[s+3] = c[31:24];
            flen = s + 4;
        end
    endtask
    // Builds a 60 byte frame that is not raw (an ARP-like one: EtherType 0x0806), for the CPU ring.
    task build_other;
        integer i; reg [31:0] c;
        begin
            for (i = 0; i < 60; i = i + 1) fb[i] = 8'h00;
            for (i = 0; i < 6; i = i + 1) fb[i] = 8'h02;
            fb[11] = 8'h02; fb[12] = 8'h08; fb[13] = 8'h06;                  // an ARP-like frame
            c = 32'hFFFFFFFF; for (i = 0; i < 60; i = i + 1) c = crc_byte(c, fb[i]); c = ~c;
            fb[60] = c[7:0]; fb[61] = c[15:8]; fb[62] = c[23:16]; fb[63] = c[31:24];
            flen = 64;
        end
    endtask
    // Queue of bytes (with their data valid flag) from the HL2's side to the copper module's sender.
    reg [8:0] mq [0:16383];
    integer   mw = 0, mr = 0;
    // Puts one byte (or one clock of nothing, dv 0) into the queue, a byte per pclk clock.
    task put(input dv, input [7:0] b); begin @(posedge pclk); mq[mw % 16384] = {dv, b}; mw = mw + 1; end endtask
    // Sends the built frame: 7 bytes of 0x55 preamble, the start frame delimiter 0xD5, the frame, and the minimum gap of 12 byte times.
    task send_frame; integer i; begin
        for (i = 0; i < 7; i = i + 1) put(1, 8'h55);
        put(1, 8'hD5);
        for (i = 0; i < flen; i = i + 1) put(1, fb[i]);
        for (i = 0; i < 12; i = i + 1) put(0, 8'h00);                      // the minimum gap
    end endtask
    // The ADC's sample count at time t: 76.8 MHz times (1 + PPM), t in ps.
    // the ADC's sample count at time t: 76.8 MHz +PPM
    function real adc_samples(input real t_ps); adc_samples = t_ps * 76.8e-6 * (1.0 + PPM * 1e-6); endfunction
    integer sent = 0, others = 0, k, stream_on = 0;
    real    t0;
    // The sender: waits for the link, then keeps sending bursts for SIM_US microseconds.
    initial begin
        wait (stream_on == 1);
        t0 = $realtime;
        while ($realtime - t0 < SIM_US * 1.0e6) begin
            // Wait until the samples for BURST more frames exist, then send them back to back.
            // wait until BURST frames' samples exist, then send them back to back
            while (adc_samples($realtime - t0) < (sent + BURST) * NS) put(0, 8'h00);
            for (k = 0; k < BURST; k = k + 1) begin
                build_raw(sent); send_frame; sent = sent + 1;
                if (sent % 16 == 0) begin build_other; send_frame; others = others + 1; end
            end
        end
`ifdef STALE
        // The HL2 has stopped (the firmware's broadcast stop), and its discovery reply follows.
        // the HL2 has stopped (the firmware's broadcast stop); its discovery reply follows
        for (k = 0; k < 2000; k = k + 1) put(0, 8'h00);
        build_other; send_frame; others = others + 1;
`endif
        stream_on = 2;
        forever put(0, 8'h00);
    end

    // ------------------------------------------------------------------ the copper module: 1000BASE-X sender (pclk)
    // The same sender as in tb_hl2min.v, with a bigger queue: one 8b/10b symbol per clock, configuration ordered sets until the
    // negotiation is done, then idle with frames between /S/ and /T/ /R/ on even positions. ms: 0 idle at an even position,
    // 1 idle at an odd position, 2 frame data, 3 /R/ after /T/. `maxlvl` records the largest queue depth reached.
    // ------------------------------------------------------------------ the copper module: 1000BASE-X sender (pclk)
    reg        p_rd = 0, p_mode = 0, pos = 0, c2 = 0;
    reg [9:0]  p_code = 0;
    reg [2:0]  ms = 0;
    reg [1:0]  cpos = 0;
    reg [15:0] p_word = 16'h0020;
    assign p_tx = {p_code[0], p_code[1], p_code[2], p_code[3], p_code[4], p_code[5], p_code[6], p_code[7], p_code[8], p_code[9]};
    task psym(input [7:0] d, input k);
        reg [10:0] e;
        begin e = k ? enc8b10b_k(d, p_rd) : enc8b10b_d(d, p_rd); p_code <= e[10:1]; p_rd = e[0]; end
    endtask
    wire [8:0] head = mq[mr % 16384], next = mq[(mr + 1) % 16384];
    integer lvl, maxlvl = 0;
    always @(posedge pclk) begin
        #1;                                       // after the queue's writer of this edge
        lvl = mw - mr;
        if (lvl > maxlvl) maxlvl = lvl;
        if (!p_mode) begin
            case (cpos)
                2'd0: psym(8'hBC, 1);
                2'd1: psym(c2 ? 8'h42 : 8'hB5, 0);
                2'd2: psym(p_word[7:0], 0);
                default: begin psym(p_word[15:8], 0); c2 = ~c2; end
            endcase
            cpos = cpos + 2'd1;
            if (lvl > 6) mr = mr + 1;
            pos = 0; ms = 0;
        end else begin
            case (ms)
                3'd0: if (lvl > 0 && head[8]) begin psym(8'hFB, 1); mr = mr + 1; ms = 2; end
                      else begin psym(8'hBC, 1); if (lvl > 0) mr = mr + 1; if (lvl > 8 && !next[8]) mr = mr + 1; ms = 1; end
                3'd1: begin psym(!p_rd ? 8'hC5 : 8'h50, 0); if (lvl > 0 && !head[8]) mr = mr + 1; ms = 0; end
                3'd2: if (lvl > 0 && head[8]) begin psym(head[7:0], 0); mr = mr + 1; end
                      else if (lvl > 0) begin psym(8'hFD, 1); mr = mr + 1; ms = 3; end
                      else begin errors = errors + 1; $display("ERROR: module queue ran empty inside a frame"); end
                default: begin psym(8'hF7, 1); if (lvl > 0 && !head[8]) mr = mr + 1; ms = pos ? 3'd0 : 3'd3; end
            endcase
            pos = ~pos;
        end
    end

    // Our configuration words, as the module reads them from our transmitter (aligned, the bits in the decoder's order).
    // our configuration words, as the module reads them (our transmitter, aligned)
    wire [9:0] rcode = {ln0_tx[0], ln0_tx[1], ln0_tx[2], ln0_tx[3], ln0_tx[4], ln0_tx[5], ln0_tx[6], ln0_tx[7], ln0_tx[8], ln0_tx[9]};
    wire [9:0] rdec = dec8b10b(rcode);
    reg [7:0]  prev_d = 0; reg prev_k = 0; reg [1:0] rpos = 0; reg [7:0] clo = 0;
    reg [15:0] d_cfg = 0; integer d_cfg_n = 0, acks = 0;
    always @(posedge sfp_txc) begin
        if (rpos == 1) begin clo = rdec[7:0]; rpos = 2; end
        else if (rpos == 2) begin
            rpos = 0;
            if ({rdec[7:0], clo} == d_cfg) d_cfg_n = d_cfg_n + 1; else d_cfg_n = 1;
            d_cfg = {rdec[7:0], clo};
        end else if (prev_k && prev_d == 8'hBC && !rdec[8] && (rdec[7:0] == 8'hB5 || rdec[7:0] == 8'h42)) rpos = 1;
        prev_d = rdec[7:0]; prev_k = rdec[8];
    end
    // Negotiation as the module plays it: our word seen three times in a row is answered with the acknowledged word (0x4020 against
    // 0x0020), and more than 1000 acknowledged words from us end the negotiation.
    always @(posedge pclk) if (!p_mode) begin
        if (d_cfg_n >= 3 && (d_cfg & 16'hBFFF) == 16'h0020) p_word <= 16'h4020; else p_word <= 16'h0020;
        if (d_cfg_n >= 3 && d_cfg == 16'h4020 && cpos == 2'd0) acks = acks + 1;
        if (acks > 1000) p_mode <= 1'b1;
    end

    // ------------------------------------------------------------------ sample check (clk_dsp)
    // samp_index is the index of the next sample, so the sample that just came out has the index sidx - 1 and, in the test
    // pattern, the value of that index mod 4096. A fill sample must not occur.
    // ------------------------------------------------------------------ sample check (clk_dsp)
    integer samples = 0, fills = 0, pat = 0;
    wire [47:0] idx_now = sidx - 48'd1;
    always @(posedge clk_dsp) if (sv) begin
        samples = samples + 1;
        if (sfill) fills = fills + 1;
        else if (samp != idx_now[11:0]) begin pat = pat + 1; if (pat < 10) $display("ERROR: sample %h at index %0d", samp, idx_now); end
    end

`ifdef STALE
    // ------------------------------------------------------------------ lifetime of a 60-byte frame in the CPU ring (clk_rx)
    // Measured from the clock the frame's length word is queued until the first later write into one of its 31 words.
    reg  [10:0] sm_w = 11'd0;
    reg         sm_live = 1'b0;
    real        sm_t = 0.0, life = 0.0, life_min = 1.0e18, life_max = 0.0;
    integer     sm_n = 0, sm_dead = 0;
    always @(posedge g_rxc) begin
        if (sm_live && dut.ring_i.mem_we && ($realtime - sm_t > 50_000.0) && (((dut.ring_i.mem_waddr - sm_w) & 11'h7FF) <= 11'd30)) begin
            life = $realtime - sm_t;
            if (life < life_min) life_min = life;
            if (life > life_max) life_max = life;
            sm_live = 1'b0; sm_dead = sm_dead + 1;
        end
        if (dut.ring_i.len_pending && dut.ring_i.len_data == 16'd60) begin
            sm_w = dut.ring_i.len_addr; sm_t = $realtime; sm_live = 1'b1; sm_n = sm_n + 1;
        end
    end
    integer rb, rbad;
    task read_back;   // the last 60-byte frame, as the firmware reads it: length word, then the frame
        begin
            rbad = 0;
            for (rb = 0; rb < 62; rb = rb + 1) begin
                @(posedge g_rxc) rd_a <= {sm_w, 1'b0} + rb;
                @(posedge g_rxc); @(posedge g_rxc); #1;
                if (rb == 0 && rd_d !== 8'h00) rbad = rbad + 1;
                if (rb == 1 && rd_d !== 8'd60) rbad = rbad + 1;
                if (rb >= 2 && rd_d !== fb[rb - 2]) rbad = rbad + 1;
            end
        end
    endtask
`endif

    // ------------------------------------------------------------------ run
    // ------------------------------------------------------------------ run
    initial begin
        $display("tb_hl2_sfp: N %0d, bursts of %0d frames back to back, HL2 clock %0.0f ppm, receive gaps, %0d us",
                 NS, BURST, PPM, SIM_US);
        // Enable the PCS, release the DSP clock side's reset, and wait until the link is up and the module has finished negotiating.
        #100_000; enable = 1'b1; #50_000; rst_dsp = 1'b0;
        wait (st_link === 1'b1 && p_mode);
        // 20 us of idle, then the stream starts and runs for SIM_US microseconds.
        #20_000_000;
        $display("t=%0t: link up, stream starts", $time);
        stream_on = 1;
        wait (stream_on == 2);
        // Let the last frames drain: N * 30 ns (the samples of a frame arrive at about 13 ns each, so this is well over a frame time) plus 200 us.
        // Let the last frames drain: the time for N * 30 ns (a frame at the 76.8 Msps rate is about 13 ns per sample) plus 200 us.
        #((NS * 30 + 200_000) * 1000);                    // the last frames drain
        $display("frames sent %0d (+%0d others), committed %0d, last sequence %0d; samples out %0d, fill %0d, pattern errors %0d",
                 sent, others, c_raw, last_seq, samples, fills, pat);
        $display("lost %0d, restarts %0d, bad FCS %0d, code %0d, length %0d, drain %0d, overrun %0d, index %0d, gap events %0d, resyncs %0d",
                 c_lost, c_rst, c_crc, c_code, c_len, c_drain, c_over, c_idx, c_gev, c_rsy);
        $display("other frames %0d, ring %0d, receive clocks without a word %0d, module queue at most %0d bytes", c_other, c_ringf, gaps, maxlvl);
`ifdef STALE
        read_back;
        $display("STALE: raw %0d, other %0d (all %0d raw frames + %0d small), ring %0d; small frames %0d, overwritten %0d, readable %0.1f to %0.1f us; last one (after the stop) %s, read back %0d bad bytes",
                 c_raw, c_other, sent, others, c_ringf, sm_n, sm_dead, life_min / 1.0e6, life_max / 1.0e6, sm_live ? "still in the ring" : "overwritten", rbad);
        // With a stale stream every raw frame lands in the CPU ring (the classifier has no address), nothing is counted as raw,
        // and the small frames in the flooded ring live for less than 100 us each.
        `CHECK(c_raw == 0 && c_other == sent + others, "a stale stream must all go to the CPU ring (the board's signature)")
        `CHECK(c_crc == 0 && c_code == 0, "line errors")
        `CHECK(sm_n == others && sm_dead >= others - 2, "every small frame in the stream is overwritten")
        `CHECK(life_max < 100.0e6, "a small frame lives longer than 100 us in the flooded ring")
        `CHECK(sm_live && rbad == 0, "the reply after the stop must stay in the ring and read back intact")
`else
        // Every frame arrived and nothing was lost on the line or in the receive chain, no fill was needed, and the samples all
        // match the pattern.
        `CHECK(c_raw == sent && last_seq == sent - 1, "not every frame arrived")
        `CHECK(c_other == others, "not every other frame arrived")
        `CHECK(c_lost == 0 && c_crc == 0 && c_code == 0 && c_len == 0, "loss on the line")
        `CHECK(c_drain == 0 && c_over == 0 && c_idx == 0, "loss in the receive chain")
        `CHECK(c_gev == 0 && c_rsy == 0 && fills == 0 && c_gsmp == 0, "fill")
        `CHECK(pat == 0 && samples == sent * NS, "samples")
        `CHECK(c_rst == 0, "sequence restarts")
`endif
        // The receive buffer clock must really have run dry, otherwise this run did not test the byte enable.
        `CHECK(gaps > 1000, "no receive gaps")
        if (errors == 0) $display("PASS"); else $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
