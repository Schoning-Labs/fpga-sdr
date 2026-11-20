// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// usbh_phy: the line interface of the USB host for full speed (12 Mbit/s) and low speed (1.5 Mbit/s), docs/USB_HOST.md section 2.
// It turns the two wires D+ and D- of one host port into received bytes and sent bytes, and nothing more; the packets, the
// timing of the frame and the transactions are in usbh_port.v, which sits above it. Two copies of this module live in usbh_top.v,
// one per port, and the pads are in the top level of the chip.
//
// Wire level, short version (the long one, with the pull-up, J and K, NRZI, bit stuffing, SYNC and EOP, is at the top of
// rtl/usb/usb_fs_phy.v and applies unchanged here). A host sees which speed a device has by which wire the device pulls
// up: a full-speed device pulls D+ high through 1.5 kohm when idle, a low-speed device (mice, keyboards) pulls D- high. In both
// cases the idle state is called J, so J is D+ high at full speed and D- high at low speed, and K is the opposite, which means
// the meaning of the two wires swaps at low speed (USB 2.0 table 7-2). A low-speed bit lasts 666.7 ns, which is 32 clocks of
// the 48 MHz clock, while a full-speed bit lasts 83.3 ns, which is 4 clocks. Everything else is the same: NRZI coding,
// a stuffed 0 after six 1s, the SYNC pattern KJKJKJKK at the start and an EOP (SE0 for two bit times, then J for one) at the end.
//
// Made from rtl/usb/usb_fs_phy.v (the device's line interface): the receive clock recovery
// (a phase counter that restarts on every line edge, the line sampled in the middle of the bit), SYNC
// detection, NRZI, bit stuffing and EOP are that file's, with two changes: the bit time is 4 clocks of the
// 48 MHz clock or 32 (`ls`), and the lines are read and driven as J and K, not as D+ and D-: at full speed J
// is D+ high, at low speed J is D- high (USB 2.0 table 7-2).
//
// New for a host:
//   eop_req    send a bare end-of-packet (two bit times of SE0, one of J): the low-speed keep-alive (USB 2.0
//              11.8.4.1) and, with eop_slow, the low-speed EOP that ends resume signalling at either speed
//              (7.1.7.7). Hold it until tx_busy is seen. A low-speed device sees a bus with no activity as a bus gone quiet and
//              would suspend, and since low speed has no SOF packets (they are full speed only), this bare EOP once per frame is what
//              keeps it awake.
//   force_se0  drive both lines low (bus reset, 7.1.7.5); force_k drive K (resume). Both only while nothing
//              is being sent.
//   line_dp, line_dn   the two lines after the synchronizer, for the connect detection.
//
// Byte handshake as usb_fs_phy.v: tx_valid with the first byte; tx_ready pulses each time a byte is taken;
// drop tx_valid after the last. One bit time of idle and one of J precede the SYNC, so two packets of the host
// in a row, or an answer to a device's packet, keep the 2-bit inter-packet gap (7.1.18). The caller has 8 bit times (32 clocks at
// full speed, 256 at low speed) to present the next byte after tx_ready.
//
// Latency: a received byte appears at rx_data at its 8th sample, in the middle of the 8th bit, and rx_eop comes in the middle of
// the J bit after the SE0 pair; a transmission starts 1 bit time (4 or 32 clocks) after tx_valid, and drives J for another bit before the SYNC.
//
// Gowin specifics: ordinary logic; the attributes of the module keep the fan-out limit high and keep the two-stage synchronizers as plain
// registers. The pads are bidirectional LVCMOS33 pins with a medium pull-down (see docs/USB_HOST.md section 3), set in the top level and the constraint file. The 48 MHz
// clock is on a global clock line. Terms are in docs/learn/GLOSSARY.md.

`timescale 1ns / 1ps

// One instance per host port.
module usbh_phy (
    input  wire       clk,        // 48 MHz USB clock
    input  wire       rst,  // synchronous reset, 1 = idle
    input  wire       ls,         // 1 = low speed (32 clocks per bit, J is D- high), 0 = full speed (4 clocks per bit, J is D+ high)
    input  wire       dp_i,  // D+ as read from the pad
    input  wire       dn_i,  // D- as read from the pad
    output reg        dp_o = 1'b0,  // level to drive onto D+
    output reg        dn_o = 1'b0,  // level to drive onto D-
    output reg        oe = 1'b0,  // 1 = the PHY drives the pads
    input  wire       force_se0,  // 1 = drive SE0 (both lines low): bus reset; only honored while nothing is being sent
    input  wire       force_k,  // 1 = drive K: resume signaling; only honored while nothing is being sent
    input  wire       eop_req,  // 1 = send a bare EOP (SE0 for two bit times, then J for one); hold it until tx_busy shows
    input  wire       eop_slow,  // with eop_req: 1 = use low-speed bit times even on a full-speed port (the EOP that ends resume)
    output wire       line_dp,  // D+ after the synchronizer
    output wire       line_dn,  // D- after the synchronizer
    // receive
    output reg        rx_active = 1'b0,  // 1 from the end of SYNC until the EOP of the packet being received
    output reg        rx_valid = 1'b0,  // one-clock pulse: rx_data is a received byte
    output reg  [7:0] rx_data = 8'd0,  // the received byte, first bit on the wire in bit 0
    output reg        rx_eop = 1'b0,  // one-clock pulse at the end of a packet
    output reg        rx_err = 1'b0,  // with rx_eop: 1 = bit-stuffing error
    // transmit
    input  wire       tx_valid,  // 1 = the caller has a byte to send; hold it up through the packet and drop it after the last byte
    input  wire [7:0] tx_data,  // the byte to send, first bit on the wire in bit 0
    output reg        tx_ready = 1'b0,  // one-clock pulse: tx_data was taken, present the next byte within 8 bit times
    output wire       tx_busy  // 1 from the start of a transmission until the lines are released
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;

    // ---------------------------------------------------------------- receive
    // Two-flip-flop synchronizers bring the pads into the 48 MHz domain (the device's bits are unrelated to our clock).
    reg [1:0] dp_s = 2'b00, dn_s = 2'b00;
    always @(posedge clk) begin
        dp_s <= {dp_s[0], dp_i};
        dn_s <= {dn_s[0], dn_i};
    end
    // The synchronized lines, also given out for the connect detection.
    wire dp = dp_s[1];
    wire dn = dn_s[1];
    assign line_dp = dp;
    assign line_dn = dn;
    // dp_q, dn_q: the lines one clock ago, to spot an edge. phase: counts the clocks of a bit, from 0 to 3 at full speed and 0 to 31
    // at low speed, and restarts at every edge, so it shows the position inside the sender's bit.
    reg  dp_q = 1'b0, dn_q = 1'b0;
    reg  [4:0] phase = 5'd0;
    wire se0 = !dp && !dn;
    // Clock recovery: an edge sets phase to 0 on the next clock; otherwise it counts, and wraps after one bit time. The line is
    // sampled at phase 1 (full speed) or phase 15 (low speed): with an edge at clock c that is clock c + 2 or c + 16, the middle of
    // the 4 or 32 clock bit.
    always @(posedge clk) begin
        dp_q <= dp;
        dn_q <= dn;
        if (dp != dp_q || dn != dn_q)           phase <= 5'd0;
        else if (phase == (ls ? 5'd31 : 5'd3))  phase <= 5'd0;
        else                                    phase <= phase + 5'd1;
    end
    // sample: 1 clock per bit, at the middle of the bit. lvl: the sampled level as J (1) or K (0), where J is D+ high at full speed and
    // D- high at low speed (valid only when the line is not SE0).
    wire sample = (phase == (ls ? 5'd15 : 5'd1));
    wire lvl = ls ? dn : dp;          // 1 = J, 0 = K (valid when not SE0)

    // Receiver states: wait for a SYNC, count the SYNC's 0s, receive data bits, wait for the SE0 after a stuffing error, wait for
    // the J that ends the EOP. They work as in usb_fs_phy.v, once per sample.
    localparam R_IDLE = 3'd0, R_SYNC = 3'd1, R_DATA = 3'd2, R_WAIT_SE0 = 3'd3, R_EOP = 3'd4;
    // rstate: receiver state. last_lvl: level of the previous bit for NRZI (no change = 1, change = 0). zeros: edges counted in the SYNC.
    // ones: 1s in a row for unstuffing. bitcnt: bits of the current byte. shreg: the byte being assembled. err_flag: a stuffing error was seen.
    reg [2:0] rstate = R_IDLE;
    reg       last_lvl = 1'b1;
    reg [2:0] zeros = 3'd0;
    reg [2:0] ones = 3'd0;
    reg [2:0] bitcnt = 3'd0;
    reg [7:0] shreg = 8'd0;
    reg       err_flag = 1'b0;
    wire      bit_nrzi = (lvl == last_lvl);

    // Receive state machine, advanced once per bit; held idle while the PHY is driving (oe), so the host does not hear itself.
    always @(posedge clk) begin
        rx_valid <= 1'b0;
        rx_eop   <= 1'b0;
        if (rst || oe) begin
            rstate    <= R_IDLE;
            rx_active <= 1'b0;
            last_lvl  <= 1'b1;
            err_flag  <= 1'b0;
        end else if (sample) begin
            case (rstate)
                R_IDLE: begin
                    last_lvl <= 1'b1;
                    if (!se0 && !lvl) begin      // first K of SYNC (decoded 0)
                        rstate   <= R_SYNC;
                        zeros    <= 3'd1;
                        last_lvl <= 1'b0;
                    end
                end
                R_SYNC: begin
                    if (se0) begin
                        rstate <= R_IDLE;
                    end else begin
                        last_lvl <= lvl;
                        if (!bit_nrzi) begin
                            if (zeros != 3'd7) zeros <= zeros + 3'd1;
                        end else if (zeros >= 3'd3) begin
                            rstate    <= R_DATA;      // KK: end of SYNC
                            rx_active <= 1'b1;
                            ones      <= 3'd1;
                            bitcnt    <= 3'd0;
                            err_flag  <= 1'b0;
                        end else begin
                            rstate <= R_IDLE;         // not a SYNC
                        end
                    end
                end
                R_DATA: begin
                    if (se0) begin
                        rstate <= R_EOP;
                    end else begin
                        last_lvl <= lvl;
                        if (ones == 3'd6) begin
                            ones <= 3'd0;             // stuffed bit, dropped
                            if (bit_nrzi) begin       // seven 1s: stuff error
                                err_flag <= 1'b1;
                                rstate   <= R_WAIT_SE0;
                            end
                        end else begin
                            ones   <= bit_nrzi ? ones + 3'd1 : 3'd0;
                            shreg  <= {bit_nrzi, shreg[7:1]};
                            bitcnt <= bitcnt + 3'd1;
                            if (bitcnt == 3'd7) begin
                                rx_data  <= {bit_nrzi, shreg[7:1]};
                                rx_valid <= 1'b1;
                            end
                        end
                    end
                end
                R_WAIT_SE0: if (se0) rstate <= R_EOP;
                R_EOP: begin
                    if (!se0) begin                   // J (or K) after SE0: end of packet
                        rx_eop    <= 1'b1;
                        rx_err    <= err_flag;
                        rx_active <= 1'b0;
                        rstate    <= R_IDLE;
                        last_lvl  <= 1'b1;
                    end
                end
                default: rstate <= R_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------- transmit
    // Transmit states: idle, one bit time of waiting, one bit of J, the data bits (SYNC first), one more bit for a stuffed bit after the last
    // byte, then the EOP (two bits of SE0, one bit of J).
    localparam T_IDLE = 3'd0, T_WAIT = 3'd1, T_J = 3'd2, T_BITS = 3'd3, T_END = 3'd4, T_EOP = 3'd5;
    // tstate: transmit state. tdiv: counts the clocks of a bit (restarts at every tick). slow and jpol are latched while idle for the whole transmission:
    // slow = low-speed bit times, jpol = low-speed polarity (J is D- high).
    reg [2:0] tstate = T_IDLE;
    reg [4:0] tdiv = 5'd0;
    reg       slow = 1'b0;           // this transmission has low-speed bit times (32 clocks per bit)
    reg       jpol = 1'b0;           // this transmission has low-speed polarity (J is D- high)
    // tick: the last clock of a bit; a new bit starts at the next clock.
    wire      tick = (tdiv == (slow ? 5'd31 : 5'd3));
    // tsh: the byte being sent, shifted right so that the next bit is tsh[0]. tbit: bits sent of it. tones: 1s in a row, for stuffing.
    // tlvl: the level on the line as J (1) or K (0). eopcnt: counts the bits of the EOP.
    reg [7:0] tsh = 8'd0;
    reg [2:0] tbit = 3'd0;
    reg [2:0] tones = 3'd0;
    reg       tlvl = 1'b1;           // 1 = J
    reg [1:0] eopcnt = 2'd0;
    // busy from the first request until the lines are released
    assign tx_busy = (tstate != T_IDLE);

    // Transmit state machine; every change of state or level happens at a tick, so edges are one bit time apart.
    always @(posedge clk) begin
        tx_ready <= 1'b0;
        if (rst) begin
            tstate <= T_IDLE;
            oe     <= 1'b0;
            dp_o   <= 1'b0;
            dn_o   <= 1'b0;
            tdiv   <= 5'd0;
        end else begin
            tdiv <= tick ? 5'd0 : tdiv + 5'd1;
            case (tstate)
                T_IDLE: begin
                    slow <= ls;
                    jpol <= ls;
                    tdiv <= 5'd0;
                    // Reset and resume are forced levels; force_se0 wins over force_k, and both over a bare EOP and a packet. K is D+ low at full speed and D+ high at low speed.
                    if (force_se0) begin
                        oe <= 1'b1; dp_o <= 1'b0; dn_o <= 1'b0;
                    end else if (force_k) begin
                        oe <= 1'b1; dp_o <= ls; dn_o <= !ls;
                    // A bare EOP goes straight to SE0, since nothing is being sent; eop_slow makes it low-speed length even on a full-speed port.
                    end else if (eop_req) begin
                        oe     <= 1'b1;                 // straight to SE0: nothing was being sent
                        dp_o   <= 1'b0;
                        dn_o   <= 1'b0;
                        slow   <= ls || eop_slow;
                        eopcnt <= 2'd0;
                        tstate <= T_EOP;
                    // A packet: wait one bit time first
                    end else begin
                        oe <= 1'b0;
                        if (tx_valid) tstate <= T_WAIT;
                    end
                end
                T_WAIT: if (tick) begin              // one idle bit time before driving
                    tstate <= T_J;
                    oe     <= 1'b1;
                    dp_o   <= !jpol;
                    dn_o   <= jpol;
                    tlvl   <= 1'b1;
                end
                T_J: if (tick) begin                 // one bit of J, then the SYNC
                    tstate <= T_BITS;
                    tones  <= 3'd0;
                    tlvl   <= 1'b0;                   // first SYNC bit (0): K
                    dp_o   <= jpol;
                    dn_o   <= !jpol;
                    tsh    <= 8'h40;                  // remaining SYNC bits, LSB first
                    tbit   <= 3'd1;
                end
                // Data bits, SYNC first: a 0 is a change of level, a 1 keeps it, and a stuffed 0 follows six 1s. The XOR with jpol swaps D+ and D- at low speed.
                T_BITS: if (tick) begin
                    if (tones == 3'd6) begin
                        tones <= 3'd0;               // stuffed 0
                        tlvl  <= !tlvl;
                        dp_o  <= !tlvl ^ jpol;
                        dn_o  <= tlvl ^ jpol;
                    end else begin
                        tones <= tsh[0] ? tones + 3'd1 : 3'd0;
                        if (!tsh[0]) begin
                            tlvl <= !tlvl;
                            dp_o <= !tlvl ^ jpol;
                            dn_o <= tlvl ^ jpol;
                        end
                        tsh  <= {1'b0, tsh[7:1]};
                        tbit <= tbit + 3'd1;
                            // the last bit of the byte is on the line: load the next byte, or end the packet if the caller has none
                        if (tbit == 3'd7) begin
                            if (tx_valid) begin
                                tsh      <= tx_data;
                                tx_ready <= 1'b1;
                            end else begin
                                tstate <= T_END;
                            end
                        end
                    end
                end
                // after the last byte one more bit time, then the EOP
                T_END: if (tick) begin
                    if (tones == 3'd6) begin         // stuffed bit due after the last byte
                        tones <= 3'd0;
                        tlvl  <= !tlvl;
                        dp_o  <= !tlvl ^ jpol;
                        dn_o  <= tlvl ^ jpol;
                    end else begin
                        tstate <= T_EOP;
                        eopcnt <= 2'd0;
                        dp_o   <= 1'b0;
                        dn_o   <= 1'b0;
                    end
                end
                // EOP: two bits of SE0, one bit of J, then the pads are released
                T_EOP: if (tick) begin
                    eopcnt <= eopcnt + 2'd1;
                    if (eopcnt == 2'd1) begin        // 2 bits of SE0 done: 1 bit of J
                        dp_o <= !jpol;
                        dn_o <= jpol;
                    end else if (eopcnt == 2'd2) begin
                        oe     <= 1'b0;
                        tstate <= T_IDLE;
                    end
                end
                default: tstate <= T_IDLE;
            endcase
        end
    end

endmodule
