// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// usbh_port: one USB host port, which keeps the frame timing and runs the transactions (docs/USB_HOST.md section 2), on the
// 48 MHz clock. It sits between usbh_phy.v (wires, bits and bytes of this port) below, and the audio ends usbh_iso_out.v and
// usbh_iso_in.v, the register page usbh_regs.v and the receive FIFO above; usbh_top.v builds two of them. A port exists so that the
// radio can take a headset, a mouse or a keyboard directly, without a PC: the radio is then the host, which means it is the
// one that runs the bus and the device never speaks unless it is asked.
//
// The host side of USB, for a beginner (the wire level, packets and endpoints are explained in rtl/usb/usb_fs_phy.v and
// rtl/usb/usb_fs_core.v; terms are in docs/learn/GLOSSARY.md). The host has a 15 kohm pull-down on each data wire, and
// a device announces itself by pulling one wire up with 1.5 kohm: D+ for a full-speed device, D- for a low-speed one, so the host knows
// both that something is plugged in and at which speed (this port gets the speed from the firmware, which reads the lines
// through line_dp and line_dn). To start a device the host resets it by driving both wires low (SE0) for 50 ms (mode 1 below). Then it
// gives the bus a regular heartbeat: every 1 ms, a frame, it sends a start-of-frame packet (SOF) with an 11-bit frame number, and the
// device uses the SOFs to keep time and not to go to sleep. A low-speed device does not see SOF packets. For it the frame starts
// with a bare end of packet (EOP), a keep-alive, which is enough to keep it awake. Everything else happens in transactions inside the
// frames: the host sends a token (SETUP, OUT or IN) saying what and to which device address and endpoint, and then either it or the device
// sends a data packet, and the receiver of the data answers with a handshake (ACK; NAK for "not ready now"; STALL for "can never do that").
// Four kinds of transfer are used here. Control transfers (SETUP, data, status) are what the firmware does for enumeration, one at a time
// as the CPU's transaction. Interrupt transfers are how a mouse or keyboard reports: the host asks the endpoint (an IN token) every so many
// milliseconds, the device says NAK if nothing happened and sends a report if something did. Isochronous transfers carry audio, one packet
// per frame without a handshake: OUT for the speaker, IN for the microphone. A retried packet is told from a new one by the data toggle
// (DATA0 or DATA1, alternating per packet), kept here in logic for interrupt transfers and given by the firmware for control transfers.
//
// CRC5 and CRC16 are the functions of rtl/usb/usb_fs_core.v (LSB-first registers, CRC16 checked by its
// residual 16'hB001, USB 2.0 8.3.5).
//
// Frame: 48,000 clocks (1 ms at 48 MHz). At its start a SOF token (full speed) or a bare EOP (low speed keep-alive). Then, each
// when due and in this order: isochronous OUT, isochronous IN, interrupt slot 0, interrupt slot 1, the CPU's
// transaction. Nothing starts after clock 40,000 of a frame (the longest low-speed transaction is 6,100
// clocks, the longest full-speed one here 3,400), so a SOF is never late. A SOF, once due, goes first even when a transaction is still
// to be done, and it waits only for the one transaction in progress.
//
// One transaction: token; then for SETUP/OUT a data packet and the device's handshake, for IN the device's
// data packet and our ACK. Isochronous: no handshake, either toggle. What can happen, and what is done:
//   ACK / good data with the expected toggle   done (interrupt slot: its toggle flips)
//   good data with the other toggle            ACK sent, data dropped, tried again next frame
//   NAK                                        interrupt slot: nothing. CPU: again next frame, x_nak frames
//                                              at most (0 = for ever), then result 2
//   STALL                                      CPU: result 3. Slot: stopped, slot_err set
//   nothing within 24 bit times, bad CRC,      tried again in the next frame; the third failure in a row is
//   bad PID, more than 64 bytes                result 4 (nothing came) or 5 (damaged); slot: stopped, slot_err
// A transaction that does not end within 40,000 clocks is given up (a device pulled out in mid-packet leaves
// the line at SE0 and the receiver waiting for the end of the packet).
//
// The CPU's transaction is the one the firmware prepares in usbh_regs.v (kind, endpoint, toggle, length, up to 64 bytes
// in a send buffer, read here through txb_addr and txb_data), started by a toggle (go_t_a) and finished with a toggle (done_t) and a
// result code x_res: 1 done, 2 NAK limit, 3 STALL, 4 no answer, 5 damaged, 6 the port is not running. An IN transaction leaves
// its data in the receive FIFO.
//
// "Device gone": both lines low for 4,096 clocks (85 us) while the port runs and does not drive. `gone` then
// stays set and the port sends nothing until the firmware takes the mode away from "run".
//
// Settings come from registers of another clock (rtl/usbh/usbh_regs.v). Single bits and the mode pass two
// registers here; the wider ones (address, endpoint numbers, the CPU's transaction) are only read after a
// toggle or an enable that was written after them has arrived, or are harmless when read while changing.
//
// Receive FIFO records (rf_*, 9 bits): the data bytes with bit 8 low, then one word with bit 8 high and the
// source in bits 1:0 (0 the CPU's IN transaction, 1 slot 0, 2 slot 1). Committed only for a good packet, and a
// record is at most 64 bytes plus that last word, which is why a transaction only starts when the FIFO has 70 words free.
//
// Latency: the SOF goes out at clock 0 of the frame (a few clocks later at the pins), 1,000 frames a second. A transaction needs the device's answer
// within 24 bit times (96 clocks at full speed, 768 at low speed), after which it counts as no answer.
//
// Gowin specifics: ordinary logic on the 48 MHz clock, which sits on a global clock line; the attributes of the module keep the fan-out
// limit high; no RAM and no DSP block (the send buffer and the receive FIFO are outside, in usbh_regs.v and usbh_top.v).

`timescale 1ns / 1ps

// One port; the module has no parameters.
module usbh_port (
    input  wire        clk,  // 48 MHz USB clock
    input  wire        rst,  // synchronous reset
    // pins (through the PHY): the two data wires of the socket, and the output enable
    // pins
    input  wire        dp_i,  // D+ as read from the pad
    input  wire        dn_i,  // D- as read from the pad
    output wire        dp_o,  // level to drive onto D+
    output wire        dn_o,  // level to drive onto D-
    output wire        oe,  // 1 = the port drives the pads
    // settings (other clock)
    input  wire [2:0]  mode_a,        // port mode from the firmware: 0 off, 1 reset (SE0), 2 run, 3 suspend (no SOF), 4 resume (K)
    input  wire        ls_a,  // 1 = the device is low speed
    input  wire [6:0]  addr,  // device address given by the firmware at enumeration (7 bits, 0 before)
    // the CPU's transaction
    input  wire        go_t_a,        // toggle: a flip starts the transaction below
    input  wire [1:0]  x_kind,        // 0 SETUP, 1 OUT, 2 IN
    input  wire [3:0]  x_ep,  // endpoint number
    input  wire        x_tog,  // data toggle of the data packet: 0 = DATA0, 1 = DATA1
    input  wire [6:0]  x_len,  // bytes to send in an OUT or SETUP data packet (0 to 64)
    input  wire [7:0]  x_nak,  // NAK frames to wait before giving up (0 = for ever)
    output reg  [5:0]  txb_addr = 6'd0,  // address of the next byte of the send buffer
    input  wire [7:0]  txb_data,      // the byte at txb_addr, at most two clocks later
    output reg         done_t = 1'b0, // toggle: finished, x_res holds the result
    output reg  [2:0]  x_res = 3'd0,  // 1 done, 2 NAK limit, 3 STALL, 4 no answer, 5 damaged, 6 port not running
    // interrupt slots: two repeating IN polls per port (for a mouse and a keyboard, say)
    input  wire [1:0]  slot_en_a,  // per slot, 1 = enabled
    input  wire [3:0]  slot0_ep,  // slot 0: endpoint number
    input  wire [7:0]  slot0_ivl,  // slot 0: poll interval in frames (ms)
    input  wire [3:0]  slot1_ep,  // slot 1: endpoint number
    input  wire [7:0]  slot1_ivl,  // slot 1: poll interval in frames (ms)
    output reg  [1:0]  slot_err = 2'b00,  // per slot, 1 = stopped after a STALL or three failures in a row
    // receive FIFO, write side
    output reg         rf_push = 1'b0,  // one-clock pulse: store rf_data
    output reg  [8:0]  rf_data = 9'd0,  // 9-bit word of a record: bit 8 low = data byte, high = the last word with the source in bits 1:0
    output reg         rf_commit = 1'b0,  // one-clock pulse: the record is complete and good, make it visible
    output reg         rf_abort = 1'b0,  // one-clock pulse: the record was damaged, throw it away
    input  wire [10:0] rf_free,  // free words in the receive FIFO
    // isochronous OUT (speaker)
    input  wire        so_en,         // 1 = the speaker stream is on (already on this clock)
    input  wire [3:0]  so_ep,  // speaker endpoint number
    output reg         sof = 1'b0,    // one-clock pulse at the start of every frame (the speaker FIFO packs its packet on it)
    input  wire [9:0]  so_len,  // bytes in the speaker packet
    input  wire [7:0]  so_data,  // the byte at the speaker FIFO's current position
    output reg         so_rd = 1'b0,  // one-clock pulse: byte taken, step on
    output reg         so_commit = 1'b0,  // one-clock pulse: packet sent, release it
    // isochronous IN (microphone)
    // isochronous IN (microphone)
    input  wire        si_en,  // 1 = the microphone stream is on
    input  wire [3:0]  si_ep,  // microphone endpoint number
    output reg         si_wr = 1'b0,  // one-clock pulse: si_data is a byte of the packet
    output reg  [7:0]  si_data = 8'd0,  // the received byte
    output reg         si_commit = 1'b0,  // one-clock pulse: the packet was good
    output reg         si_abort = 1'b0,  // one-clock pulse: the packet was bad
    // status
    output wire        line_dp,  // the two lines after the synchronizer, for the connect detection
    output wire        line_dn,  // (as above, D-)
    output reg         gone = 1'b0,  // 1 = both lines were low for 85 us while running: the device was pulled out
    output reg  [10:0] frame = 11'd0  // frame number of the SOF last sent, 0 to 2047
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;

    // Port modes set by the firmware. Frame constants: a frame is 48,000 clocks (FRAME_LAST = 47,999 is its last), no new transaction
    // starts after clock WINDOW = 40,000 (5/6 of the frame), and a transaction is given up after GIVE_UP = 40,000 clocks.
    localparam [2:0] MODE_OFF = 3'd0, MODE_RESET = 3'd1, MODE_RUN = 3'd2, MODE_SUSP = 3'd3, MODE_RESUME = 3'd4;
    // PIDs: tokens and data (as in usb_fs_core.v), and the three handshakes ACK, NAK and STALL.
    localparam [3:0] PID_OUT = 4'h1, PID_IN = 4'h9, PID_SOF = 4'h5, PID_SETUP = 4'hD;
    localparam [3:0] PID_DATA0 = 4'h3, PID_DATA1 = 4'hB, PID_ACK = 4'h2, PID_NAK = 4'hA, PID_STALL = 4'hE;
    localparam [15:0] FRAME_LAST = 16'd47999, WINDOW = 16'd40000, GIVE_UP = 16'd40000;

    // CRC16 of USB, one byte at a time (polynomial 16'hA001 bit-reversed, start value all ones, sent inverted).
    function [15:0] crc16_byte(input [15:0] c, input [7:0] d);
        integer i;
        reg [15:0] x;
        begin
            x = c ^ {8'h00, d};
            for (i = 0; i < 8; i = i + 1) x = x[0] ? ((x >> 1) ^ 16'hA001) : (x >> 1);
            crc16_byte = x;
        end
    endfunction
    // CRC5 of a token over its 11 bits (address and endpoint, or frame number), inverted and ready to go into bits 15:11 of the token (bit 11 first).
    function [4:0] crc5_11(input [10:0] t);
        integer i;
        reg [4:0] c;
        begin
            c = 5'h1F;
            for (i = 0; i < 11; i = i + 1) c = (c[0] ^ t[i]) ? ((c >> 1) ^ 5'h14) : (c >> 1);
            crc5_11 = ~c;
        end
    endfunction

    // ---------------------------------------------------------------- settings into this clock
    // md_s1, md_s2: the mode through two registers; mode takes the value only when both agree (all three bits settled).
    // ls_s: low speed flag through two registers. go_s: the start toggle through three. se_s1, se_s2: the slot enables.
    reg [2:0] md_s1 = 3'd0, md_s2 = 3'd0, mode = 3'd0, mode_q = 3'd0;
    reg [1:0] ls_s = 2'b00;
    reg [2:0] go_s = 3'b000;
    reg [1:0] se_s1 = 2'b00, se_s2 = 2'b00;
    always @(posedge clk) begin
        md_s1 <= mode_a;
        md_s2 <= md_s1;
        if (md_s1 == md_s2) mode <= md_s2;       // all three bits have settled
        mode_q <= mode;
        ls_s   <= {ls_s[0], ls_a};
        go_s   <= {go_s[1:0], go_t_a};
        se_s1  <= slot_en_a;
        se_s2  <= se_s1;
    end
    // ls: the synchronized speed bit. go: a one-clock pulse when the start toggle flipped. slot_en: the synchronized slot enables.
    wire ls = ls_s[1];
    wire go = go_s[2] ^ go_s[1];
    wire [1:0] slot_en = se_s2;

    // ---------------------------------------------------------------- line interface
    // The line interface of this port, with the reset and resume levels forced from the mode, and the bare EOP of the keep-alive.
    wire       rx_active, rx_valid, rx_eop, rx_err, tx_ready, tx_busy;
    wire [7:0] rx_data;
    reg        tx_valid = 1'b0;
    reg  [7:0] tx_data = 8'd0;
    reg        eop_req = 1'b0, eop_slow = 1'b0;
    usbh_phy u_phy (
        .clk(clk), .rst(rst), .ls(ls),
        .dp_i(dp_i), .dn_i(dn_i), .dp_o(dp_o), .dn_o(dn_o), .oe(oe),
        .force_se0(mode == MODE_RESET), .force_k(mode == MODE_RESUME),
        .eop_req(eop_req), .eop_slow(eop_slow),
        .line_dp(line_dp), .line_dn(line_dn),
        .rx_active(rx_active), .rx_valid(rx_valid), .rx_data(rx_data), .rx_eop(rx_eop), .rx_err(rx_err),
        .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready), .tx_busy(tx_busy)
    );

    // ---------------------------------------------------------------- device gone
    // se0_cnt: clocks of SE0 while running and not driving; 4,096 clocks (bit 12) is 85 us, after which the device is gone.
    reg [12:0] se0_cnt = 13'd0;
    // running: the port is in mode run and the device has not gone.
    wire running = (mode == MODE_RUN) && !gone;
    always @(posedge clk) begin
        if (rst || mode != MODE_RUN) begin
            gone    <= 1'b0;
            se0_cnt <= 13'd0;
        end else if (!line_dp && !line_dn && !oe) begin
            if (se0_cnt[12]) gone <= 1'b1;
            else             se0_cnt <= se0_cnt + 13'd1;
        end else begin
            se0_cnt <= 13'd0;
        end
    end

    // ---------------------------------------------------------------- frame and what is due
    // Jobs of a frame: the SOF, the speaker packet, the microphone request, the two interrupt slots, the CPU's transaction.
    // M_*: the states of the transaction engine. R_*: results of a transaction (R_AGAIN is only used inside: a repeated packet was dropped).
    localparam [2:0] J_SOF = 3'd0, J_SO = 3'd1, J_SI = 3'd2, J_I0 = 3'd3, J_I1 = 3'd4, J_X = 3'd5;
    localparam [4:0] M_IDLE = 5'd0, M_EOP = 5'd1, M_EOP2 = 5'd2, M_TOK = 5'd3, M_TOK1 = 5'd4, M_TOK2 = 5'd5,
                     M_TOK3 = 5'd6, M_TOKEND = 5'd7, M_DPID = 5'd8, M_DTX = 5'd9, M_DCRC2 = 5'd10,
                     M_DLAST = 5'd11, M_DEND = 5'd12, M_RXWAIT = 5'd13, M_RXDATA = 5'd14, M_RXHS = 5'd15,
                     M_RXSKIP = 5'd16, M_ACK = 5'd17, M_ACKEND = 5'd18, M_RESULT = 5'd19, M_SETUP = 5'd20;
    localparam [2:0] R_OK = 3'd1, R_NAK = 3'd2, R_STALL = 3'd3, R_NONE = 3'd4, R_BAD = 3'd5, R_AGAIN = 3'd7;

    // fcnt: clock within the frame, 0 to 47,999. p_*: a job is due (SOF, speaker, microphone, slot 0, slot 1, the low-speed EOP that ends resume).
    // x_pend: the CPU's transaction is waiting. x_wait: it was NAKed or damaged and waits for the next frame. x_nakcnt, x_errcnt: tries so far.
    // iv0, iv1: frames until the slot is polled again. s_tog: the data toggle of each slot, flipped on every good report.
    // s_err0, s_err1: failures in a row per slot.
    reg [15:0] fcnt = 16'd0;
    reg        p_sof = 1'b0, p_so = 1'b0, p_si = 1'b0, p_i0 = 1'b0, p_i1 = 1'b0, p_reop = 1'b0;
    reg        x_pend = 1'b0, x_wait = 1'b0;
    reg [7:0]  x_nakcnt = 8'd0;
    reg [1:0]  x_errcnt = 2'd0;
    reg [7:0]  iv0 = 8'd0, iv1 = 8'd0;
    reg [1:0]  s_tog = 2'b00;
    reg [1:0]  s_err0 = 2'd0, s_err1 = 2'd0;
    // st: state of the engine. job: which job is running. tok: the 16 bits of the token. tokpid: its PID.
    // j_in, j_iso, j_tog: the job is an IN, is isochronous, and its data toggle. remaining: bytes of our data still to send.
    // crc: running CRC16. timer: clocks of idle line while waiting for the device. wd: clocks in the present transaction (the watchdog).
    // nbytes: bytes received so far, CRC included. d1, d2: the last two received bytes, which keeps the CRC from being passed on.
    // rpid: PID of the device's answer. res: result of the transaction. babble: the device sent more than 64 bytes.
    reg [4:0]  st = M_IDLE;
    reg [2:0]  job = J_SOF;
    reg [15:0] tok = 16'd0;
    reg [3:0]  tokpid = 4'd0;
    reg        j_in = 1'b0, j_iso = 1'b0, j_tog = 1'b0;
    reg [9:0]  remaining = 10'd0;
    reg [15:0] crc = 16'd0;
    reg [9:0]  timer = 10'd0;
    reg [15:0] wd = 16'd0;
    reg [10:0] nbytes = 11'd0;
    reg [7:0]  d1 = 8'd0, d2 = 8'd0;
    reg [3:0]  rpid = 4'd0;
    reg [2:0]  res = 3'd0;
    reg        babble = 1'b0;
    // 24 bit times (768 clocks at low speed, 96 at full speed) until the end of the device's SYNC, after which no answer counts.
    // room: the receive FIFO can take a whole record (64 bytes and its last word, with some margin). window: a transaction may still start.
    wire [9:0] timeout = ls ? 10'd768 : 10'd96;       // 24 bit times to the end of the SYNC
    wire       room = (rf_free >= 11'd70);
    wire       window = (fcnt < WINDOW);
    // The endpoint number of the job, and the 11 bits of the token: the frame number for a SOF, else endpoint and address.
    wire [3:0] j_ep = (job == J_SO) ? so_ep : (job == J_SI) ? si_ep : (job == J_I0) ? slot0_ep :
                      (job == J_I1) ? slot1_ep : x_ep;
    wire [10:0] tokbits = (job == J_SOF) ? frame : {j_ep, addr};

    // The engine. The one-clock pulses default to 0 each clock.
    always @(posedge clk) begin
        sof       <= 1'b0;
        so_rd     <= 1'b0;
        so_commit <= 1'b0;
        si_wr     <= 1'b0;
        si_commit <= 1'b0;
        si_abort  <= 1'b0;
        rf_push   <= 1'b0;
        rf_commit <= 1'b0;
        rf_abort  <= 1'b0;

        // The frame counter and the flags that say what is due: at the start of each frame the SOF, the speaker, the microphone and the
        // slots whose interval has run out become due (the intervals count frames).
        if (rst || !running) begin
            fcnt  <= 16'd0;
            p_sof <= 1'b0; p_so <= 1'b0; p_si <= 1'b0; p_i0 <= 1'b0; p_i1 <= 1'b0;
            iv0   <= 8'd0; iv1 <= 8'd0;
        end else begin
            fcnt <= (fcnt == FRAME_LAST) ? 16'd0 : fcnt + 16'd1;
            if (fcnt == 16'd0) begin
                p_sof  <= 1'b1;
                sof    <= 1'b1;
                frame  <= frame + 11'd1;
                p_so   <= so_en;
                p_si   <= si_en;
                x_wait <= 1'b0;
                if (slot_en[0] && !slot_err[0]) begin
                    if (iv0 == 8'd0) begin p_i0 <= 1'b1; iv0 <= slot0_ivl - 8'd1; end
                    else iv0 <= iv0 - 8'd1;
                end
                if (slot_en[1] && !slot_err[1]) begin
                    if (iv1 == 8'd0) begin p_i1 <= 1'b1; iv1 <= slot1_ivl - 8'd1; end
                    else iv1 <= iv1 - 8'd1;
                end
            end
        end
        // A slot that is switched off forgets its toggle and its fault.
        if (rst || !slot_en[0]) begin s_tog[0] <= 1'b0; slot_err[0] <= 1'b0; s_err0 <= 2'd0; p_i0 <= 1'b0; end
        if (rst || !slot_en[1]) begin s_tog[1] <= 1'b0; slot_err[1] <= 1'b0; s_err1 <= 2'd0; p_i1 <= 1'b0; end
        // The end of resume signaling is a low-speed EOP.
        if (mode_q == MODE_RESUME && mode != MODE_RESUME) p_reop <= 1'b1;

        // The CPU's transaction: the start toggle makes it pending and clears its counters.
        if (go) begin
            x_pend   <= 1'b1;
            x_wait   <= 1'b0;
            x_nakcnt <= 8'd0;
            x_errcnt <= 2'd0;
        end

        // wd measures how long the engine has been out of idle.
        wd <= (st == M_IDLE) ? 16'd0 : wd + 16'd1;

        if (rst) begin
            st       <= M_IDLE;
            tx_valid <= 1'b0;
            eop_req  <= 1'b0;
            x_pend   <= 1'b0;
            p_reop   <= 1'b0;
            // (the watchdog ran out)
        end else if (wd == GIVE_UP) begin
            // given up: whatever was being received is dropped
            tx_valid <= 1'b0;
            eop_req  <= 1'b0;
            rf_abort <= !j_iso;
            si_abort <= j_iso && j_in;
            res      <= R_BAD;
            st       <= (job == J_SOF) ? M_IDLE : M_RESULT;
        end else begin
            case (st)
                    // Idle: decide what to do next, in this order: the EOP that ends resume; end a CPU transaction at once if the
                    // port is not running; the SOF (a SOF token at full speed, a keep-alive EOP at low speed); then, inside the window
                    // of the frame, the speaker, the microphone, the two slots (only when the receive FIFO has room), and the CPU's transaction.
                M_IDLE: begin
                    if (p_reop) begin
                        eop_req  <= 1'b1;
                        eop_slow <= 1'b1;
                        p_reop   <= 1'b0;
                        job      <= J_SOF;
                        st       <= M_EOP;
                    end else if (x_pend && !go && !running) begin
                        x_pend <= 1'b0;                 // no running port: the transaction ends at once
                        x_res  <= 3'd6;
                        done_t <= ~done_t;
                    end else if (running && p_sof) begin
                        p_sof <= 1'b0;
                        job   <= J_SOF;
                        if (ls) begin
                            eop_req  <= 1'b1;
                            eop_slow <= 1'b0;
                            st       <= M_EOP;
                        end else begin
                            st <= M_SETUP;
                        end
                    end else if (running && window) begin
                        if (p_so) begin
                            p_so <= 1'b0; job <= J_SO; st <= M_SETUP;
                        end else if (p_si) begin
                            p_si <= 1'b0; job <= J_SI; st <= M_SETUP;
                        end else if (p_i0) begin
                            p_i0 <= 1'b0;
                            if (room) begin job <= J_I0; st <= M_SETUP; end
                        end else if (p_i1) begin
                            p_i1 <= 1'b0;
                            if (room) begin job <= J_I1; st <= M_SETUP; end
                        end else if (x_pend && !go && !x_wait && (x_kind != 2'd2 || room)) begin
                            job <= J_X; st <= M_SETUP;
                        end
                    end
                end
                // ---- bare EOP (keep-alive, end of resume): wait until the PHY has started it, then until it is done
                M_EOP:  if (tx_busy) begin eop_req <= 1'b0; st <= M_EOP2; end
                M_EOP2: if (!tx_busy) st <= M_IDLE;
                // ---- token: choose PID and toggle for the job, build the token (address, endpoint, CRC5) and send PID and 2 bytes
                M_SETUP: begin
                    case (job)
                        J_SOF:   begin tokpid <= PID_SOF; j_in <= 1'b0; j_iso <= 1'b1; j_tog <= 1'b0; end
                        J_SO:    begin tokpid <= PID_OUT; j_in <= 1'b0; j_iso <= 1'b1; j_tog <= 1'b0; end
                        J_SI:    begin tokpid <= PID_IN;  j_in <= 1'b1; j_iso <= 1'b1; j_tog <= 1'b0; end
                        J_I0:    begin tokpid <= PID_IN;  j_in <= 1'b1; j_iso <= 1'b0; j_tog <= s_tog[0]; end
                        J_I1:    begin tokpid <= PID_IN;  j_in <= 1'b1; j_iso <= 1'b0; j_tog <= s_tog[1]; end
                        default: begin
                            tokpid <= (x_kind == 2'd0) ? PID_SETUP : (x_kind == 2'd1) ? PID_OUT : PID_IN;
                            j_in   <= (x_kind == 2'd2);
                            j_iso  <= 1'b0;
                            j_tog  <= x_tog;
                        end
                    endcase
                    tok       <= {crc5_11(tokbits), tokbits};
                    remaining <= (job == J_SO) ? so_len : {3'd0, x_len};
                    txb_addr  <= 6'd0;
                    st        <= M_TOK;
                end
                M_TOK: begin
                    tx_valid <= 1'b1;
                    tx_data  <= {~tokpid, tokpid};
                    st       <= M_TOK1;
                end
                M_TOK1: if (tx_ready) begin tx_data <= tok[7:0];  st <= M_TOK2; end
                M_TOK2: if (tx_ready) begin tx_data <= tok[15:8]; st <= M_TOK3; end
                M_TOK3: if (tx_ready) begin tx_valid <= 1'b0;     st <= M_TOKEND; end
                M_TOKEND: if (!tx_busy && !tx_valid) begin
                    timer <= 10'd0;
                    if (job == J_SOF)  st <= M_IDLE;
                    else if (j_in)     st <= M_RXWAIT;
                    else               st <= M_DPID;
                end
                // ---- our data packet: the PID with the toggle, the bytes of the speaker FIFO or the send buffer, then CRC16 low byte, high byte
                M_DPID: begin
                    tx_valid <= 1'b1;
                    tx_data  <= j_tog ? {~PID_DATA1, PID_DATA1} : {~PID_DATA0, PID_DATA0};
                    crc      <= 16'hFFFF;
                    st       <= M_DTX;
                end
                M_DTX: if (tx_ready) begin
                    if (remaining != 10'd0) begin
                        tx_data   <= (job == J_SO) ? so_data : txb_data;
                        crc       <= crc16_byte(crc, (job == J_SO) ? so_data : txb_data);
                        so_rd     <= (job == J_SO);
                        txb_addr  <= txb_addr + 6'd1;
                        remaining <= remaining - 10'd1;
                    end else begin
                        tx_data <= ~crc[7:0];
                        st      <= M_DCRC2;
                    end
                end
                M_DCRC2: if (tx_ready) begin tx_data <= ~crc[15:8]; st <= M_DLAST; end
                M_DLAST: if (tx_ready) begin tx_valid <= 1'b0;      st <= M_DEND; end
                M_DEND: if (!tx_busy && !tx_valid) begin
                    timer <= 10'd0;
                    if (j_iso) begin
                        so_commit <= 1'b1;
                        st        <= M_IDLE;
                    end else begin
                        st <= M_RXWAIT;
                    end
                end
                // ---- the device's answer: wait for its PID (or give up after 24 bit times), then receive data, a handshake, or skip a bad packet
                M_RXWAIT: begin
                    if (!rx_active) timer <= timer + 10'd1;
                    if (rx_valid) begin
                        rpid   <= rx_data[3:0];
                        crc    <= 16'hFFFF;
                        nbytes <= 11'd0;
                        babble <= 1'b0;
                        if (rx_data[3:0] != ~rx_data[7:4])
                            st <= M_RXSKIP;
                        else if (j_in && (rx_data[3:0] == PID_DATA0 || rx_data[3:0] == PID_DATA1))
                            st <= M_RXDATA;
                        else if (!j_iso && (rx_data[3:0] == PID_NAK || rx_data[3:0] == PID_STALL ||
                                            (!j_in && rx_data[3:0] == PID_ACK)))
                            st <= M_RXHS;
                        else
                            st <= M_RXSKIP;
                    end else if (timer == timeout) begin
                        res <= R_NONE;
                        st  <= M_RESULT;
                    end
                end
                // The data packet of an IN: two bytes are kept back so the CRC never reaches the FIFO; isochronous bytes go to the microphone,
                // others to the receive FIFO (at most 64). At the end the packet is committed if it was good, acknowledged if it was not isochronous.
                M_RXDATA: begin
                    if (rx_valid) begin
                        crc <= crc16_byte(crc, rx_data);
                        if (nbytes != 11'h7FF) nbytes <= nbytes + 11'd1;
                        d1 <= rx_data;
                        d2 <= d1;
                        if (nbytes >= 11'd2) begin
                            if (j_iso) begin
                                si_wr   <= 1'b1;
                                si_data <= d2;
                            end else if (nbytes < 11'd66) begin
                                rf_push <= 1'b1;
                                rf_data <= {1'b0, d2};
                            end else begin
                                babble <= 1'b1;
                            end
                        end
                    end else if (rx_eop) begin
                        if (rx_err || nbytes < 11'd2 || crc != 16'hB001 || babble) begin
                            rf_abort <= !j_iso;
                            si_abort <= j_iso;
                            res      <= R_BAD;
                            st       <= M_RESULT;
                        end else if (j_iso) begin
                            si_commit <= 1'b1;
                            st        <= M_IDLE;
                        end else if (rpid[3] != j_tog) begin
                            rf_abort <= 1'b1;               // a repeat: acknowledged and dropped
                            res      <= R_AGAIN;
                            st       <= M_ACK;
                        end else begin
                            rf_push   <= 1'b1;              // the record's last word, and the commit
                            rf_data   <= {1'b1, 6'd0, (job == J_I0) ? 2'd1 : (job == J_I1) ? 2'd2 : 2'd0};
                            rf_commit <= 1'b1;
                            res       <= R_OK;
                            st        <= M_ACK;
                        end
                    end
                end
                // A handshake from the device (ACK for an OUT or SETUP, NAK, STALL), which must be followed by the end of the packet.
                M_RXHS: begin
                    if (rx_valid) begin
                        st <= M_RXSKIP;
                    end else if (rx_eop) begin
                        res <= rx_err ? R_BAD : (rpid == PID_ACK) ? R_OK : (rpid == PID_NAK) ? R_NAK : R_STALL;
                        st  <= M_RESULT;
                    end
                end
                M_RXSKIP: if (rx_eop || !rx_active) begin
                    rf_abort <= !j_iso;
                    si_abort <= j_iso;
                    res      <= R_BAD;
                    st       <= M_RESULT;
                end
                // Send our ACK for a good data packet (also for a repeated one, whose data was dropped).
                M_ACK: begin
                    tx_valid <= 1'b1;
                    tx_data  <= {~PID_ACK, PID_ACK};
                    if (tx_ready) begin
                        tx_valid <= 1'b0;
                        st       <= M_ACKEND;
                    end
                end
                M_ACKEND: if (!tx_busy && !tx_valid) st <= M_RESULT;
                // ---- what the answer means for the job: an interrupt slot flips its toggle on a good report and stops on a STALL or on 3 failures
                // in a row; the CPU's transaction ends with its result, or waits for the next frame after a NAK or an error
                M_RESULT: begin
                    st <= M_IDLE;
                    case (job)
                        J_I0: begin
                            if (res == R_OK) begin s_tog[0] <= ~s_tog[0]; s_err0 <= 2'd0; end
                            else if (res == R_STALL) slot_err[0] <= slot_en[0];
                            else if (res == R_NONE || res == R_BAD) begin
                                s_err0 <= s_err0 + 2'd1;
                                if (s_err0 == 2'd2) slot_err[0] <= slot_en[0];
                            end
                        end
                        J_I1: begin
                            if (res == R_OK) begin s_tog[1] <= ~s_tog[1]; s_err1 <= 2'd0; end
                            else if (res == R_STALL) slot_err[1] <= slot_en[1];
                            else if (res == R_NONE || res == R_BAD) begin
                                s_err1 <= s_err1 + 2'd1;
                                if (s_err1 == 2'd2) slot_err[1] <= slot_en[1];
                            end
                        end
                        J_X: if (!go) begin
                            case (res)
                                R_OK, R_STALL: begin
                                    x_pend <= 1'b0; x_res <= res; done_t <= ~done_t;
                                end
                                R_NAK: begin
                                    x_nakcnt <= x_nakcnt + 8'd1;
                                    if (x_nak != 8'd0 && x_nakcnt + 8'd1 == x_nak) begin
                                        x_pend <= 1'b0; x_res <= R_NAK; done_t <= ~done_t;
                                    end else x_wait <= 1'b1;
                                end
                                R_AGAIN: x_wait <= 1'b1;
                                default: begin
                                    x_errcnt <= x_errcnt + 2'd1;
                                    if (x_errcnt == 2'd2) begin
                                        x_pend <= 1'b0; x_res <= res; done_t <= ~done_t;
                                    end else x_wait <= 1'b1;
                                end
                            endcase
                        end
                        default: ;                      // isochronous IN that brought nothing: nothing to do
                    endcase
                end
                default: st <= M_IDLE;
            endcase
        end
    end

endmodule
