// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Taken from an earlier design by the same author; modified 2026 by
// Franz Schöning for fpga-sdr: only the synthesis attribute on the module (two-stage synchronisers stay registers) (docs/USB_AUDIO.md).
//
// usb_fs_phy: the line interface of the USB device, which turns the two wires D+ and D- into bytes and bytes into
// the two wires, and does nothing more. It is the lowest layer of the USB sound card of rtl/usb/ (see usb_audio.v for
// the whole unit): the pads of the "Custom USB" socket come in at one side, and usb_fs_core.v, which understands
// packets, sits on the other. Everything here runs on the 48 MHz clock clk_usb (clk_48m in the top level).
//
// USB at the wire level, as much as this file needs. A full-speed device (the slowest speed that carries audio
// well) sends 12 Mbit/s, so one bit lasts 83.3 ns, which is exactly 4 clocks of 48 MHz, and that is why the whole USB
// side of the radio runs on 48 MHz: with 4 clocks per bit the logic can sample every bit once and still has three
// clocks to spare for deciding. The bus has two data wires, D+ and D-, and normally they carry opposite levels
// (differential signaling, which is what makes a long cable robust against noise). A device announces itself by
// pulling D+ up to 3.3 V through 1.5 kohm (on this board a switch does that, see usb_audio.v), while the host holds
// both wires low through 15 kohm resistors, so an idle bus with a device plugged in has D+ high and D- low: this state
// is called J. The opposite state, D+ low and D- high, is K, and both wires low is called SE0 ("single-ended zero"),
// which is used to mark the end of a packet and, when it lasts long enough, a bus reset. Bits are NRZI coded: a 0 is
// a change between J and K, a 1 is no change. A long run of 1s would therefore give the receiver no edge to lock
// its timing onto, and for that reason the sender inserts an extra 0 (a change) after every six 1s in a row (bit
// stuffing), which the receiver removes again; a seventh 1 in a row is a stuffing error. Every packet begins with
// the SYNC pattern, the levels KJKJKJKK (seven 0s and a 1), whose many edges let the receiver find the bit
// boundaries, and ends with an EOP, which is SE0 for two bit times followed by J for one. Bytes are sent least
// significant bit first. Terms such as PID, token or endpoint are explained in usb_fs_core.v; unknown words may
// be in docs/learn/GLOSSARY.md.
//
// Pins: dp_i and dn_i read D+ and D- through ordinary LVCMOS33 inputs, and dp_o, dn_o and oe drive them through
// LVCMOS33 outputs (the top level makes the pads bidirectional). On the Tang Mega 138K Pro dock these are pins T19
// (D+) and U19 (D-), which reach the connector through 0 ohm resistors (dock schematic, PERIPHERALS sheet,
// R17 and R19), so the pins see the bus directly with CMOS thresholds, which is what a full-speed single-ended
// receiver needs (USB 2.0 table 7-7: VIL 0.8 V, VIH 2.0 V).
//
// Receive, step by step: two-flip-flop synchronizers bring the pins into the clock domain (the bus clock of the
// host is unrelated to ours); a phase counter restarts on every line transition and the line is sampled 2 clocks
// after it, which is the middle of a 4 clock bit (bit stuffing guarantees an edge at least every 7 bits, so the
// +-0.25 % full-speed rate tolerance cannot move the sample point by more than a small fraction of a bit, and no
// PLL is needed). Then come SYNC detection, NRZI decoding, bit unstuffing (the SYNC's final 1 counts as the
// first 1 of a run: USB 2.0 section 7.1.9) and EOP detection (SE0 followed by J). rx_valid pulses for each
// received byte, and rx_eop pulses at the J that ends the EOP, with rx_err giving the packet's error state
// (bit-stuff violation).
//
// Transmit, step by step: a byte handshake. When the PHY is idle and tx_valid is high it waits one bit time,
// drives J for one bit, sends SYNC, then the bytes: it takes tx_data and pulses tx_ready for one clock each time
// it needs the next byte (the first time at the end of SYNC, then every 8 bits), so the caller has 32 clocks to
// present the next byte or drop tx_valid. After the last byte it sends a stuffed bit if one is due, then EOP (2
// bits SE0, 1 bit J) and releases the lines. The receiver is held in its idle state while the PHY drives (oe=1),
// so the device does not hear itself.
//
// Latency: rx_eop arrives about half a bit (2 clocks) after the host's EOP ends; with the caller's few clocks and
// the 1-bit wait (4 clocks) the device starts driving about 2.5 to 3 bit times after the EOP, inside the 7.5
// bit-time limit the host allows for an answer (USB 2.0 section 7.1.18.1).
//
// Bus reset: bus_reset is high while SE0 has lasted more than 2.5 us (120 clocks, USB 2.0 section 7.1.7.5).
//
// Gowin specifics: the synthesizer attributes on the module keep the fan-out limit high (the reset and the
// bit tick reach many registers) and keep the two-stage synchronizers as plain registers instead of turning them
// into a shift register primitive, which would put the two stages apart in the chip. The 48 MHz clock should be
// on one of the chip's global clock lines: on ordinary wiring the clock skew between these shift-register-like
// paths gives hold-time violations.
`timescale 1ns / 1ps

module usb_fs_phy (
    input  wire       clk,        // 48 MHz USB clock; 4 clocks per bit at 12 Mbit/s
    input  wire       rst,        // synchronous reset, 1 = idle state
    input  wire       dp_i,        // D+ as read from the pad (asynchronous, synchronized below)
    input  wire       dn_i,        // D- as read from the pad
    output reg        dp_o,        // level to drive onto D+ while oe = 1
    output reg        dn_o,        // level to drive onto D- while oe = 1 (always the opposite of dp_o except in SE0)
    output reg        oe,        // output enable: 1 = this PHY drives the lines, 0 = the pads are inputs and the host drives
    output reg        bus_reset,        // 1 while the bus has been in SE0 for more than 2.5 us (120 clocks) with nobody driving: the host's reset
    output wire       line_se0,        // 1 while both lines are low (SE0), after the synchronizers
    // receive
    output reg        rx_active,        // 1 from the end of SYNC until the EOP of the packet being received
    output reg        rx_valid,   // one-clock pulse: rx_data holds a newly received byte (every 8 data bits)
    output reg  [7:0] rx_data,        // the received byte, first bit on the wire in bit 0
    output reg        rx_eop,     // one-clock pulse at the end of a packet (the J after the SE0 pair)
    output reg        rx_err,     // meaningful with rx_eop: 1 = the packet had a bit-stuffing error
    // transmit
    input  wire       tx_valid,        // 1 = the caller has a byte to send; keep it high through the packet and drop it after the last byte
    input  wire [7:0] tx_data,        // the byte to send, bit 0 first; first read at the end of the SYNC, then again when tx_ready pulses
    output reg        tx_ready,   // one-clock pulse: tx_data was taken, present the next byte within 32 clocks
    output wire       tx_busy        // 1 from the start of a transmission until the lines are released after the EOP
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;

    // ---------------------------------------------------------------- receive
    // Two-flip-flop synchronizers: the host's bits are unrelated to our clock, so the first flip-flop of each pair
    // may go metastable (undecided) and the second one gives it a full clock to settle.
    reg [1:0] dp_s, dn_s;
    always @(posedge clk) begin
        dp_s <= {dp_s[0], dp_i};
        dn_s <= {dn_s[0], dn_i};
    end
    // The synchronized lines used from here on.
    wire dp = dp_s[1];
    wire dn = dn_s[1];
    // dp_q, dn_q: the lines one clock ago, to spot an edge. phase: 2-bit counter that counts the 4 clocks of a bit,
    // restarted by every edge, so it always shows where in the bit the line is, relative to the sender's timing.
    reg  dp_q, dn_q;
    reg  [1:0] phase;
    // SE0: both lines low.
    wire se0 = !dp && !dn;
    assign line_se0 = se0;
    // Clock recovery. An edge (either line changed) sets phase to 0 on the next clock; with the edge having
    // happened at clock c, phase is 1 at clock c + 2.
    always @(posedge clk) begin
        dp_q <= dp;
        dn_q <= dn;
        if (dp != dp_q || dn != dn_q) phase <= 2'd0;
        else phase <= phase + 2'd1;
    end
    // sample: 1 clock in every 4, at the middle of a bit, when the receiver looks at the line.
    wire sample = (phase == 2'd1);
    wire lvl = dp;          // the sampled level: 1 = J, 0 = K (meaningful only when the line is not SE0)

    // Receiver states: wait for a SYNC, count the SYNC's 0s, receive data bits, wait for the SE0 after a stuffing
    // error, wait for the J that ends the EOP.
    localparam R_IDLE = 3'd0, R_SYNC = 3'd1, R_DATA = 3'd2, R_WAIT_SE0 = 3'd3, R_EOP = 3'd4;
    // rstate: receiver state. last_lvl: the level of the previous bit, for NRZI decoding. zeros: 0s (edges) counted in the
    // SYNC. ones: 1s in a row, for unstuffing. bitcnt: bits of the byte received so far. shreg: the byte being
    // assembled, filled from the top so that the first bit ends in bit 0. err_flag: a stuffing error was seen.
    reg [2:0] rstate;
    reg       last_lvl;
    reg [2:0] zeros;
    reg [2:0] ones;
    reg [2:0] bitcnt;
    reg [7:0] shreg;
    reg       err_flag;
    // The NRZI decoding: the same level as the bit before is a 1, a change is a 0.
    wire      bit_nrzi = (lvl == last_lvl);

    // Bus reset timer: counts clocks of SE0 while the PHY is not driving; 2.5 us = 120 clocks at 48 MHz. It stops
    // at 255 so that the 8-bit counter does not wrap, and bus_reset follows it one clock later.
    reg [7:0] se0_cnt;
    always @(posedge clk) begin
        if (rst) begin
            se0_cnt <= 8'd0;
            bus_reset <= 1'b0;
        end else if (se0 && !oe) begin
            if (se0_cnt != 8'd255) se0_cnt <= se0_cnt + 8'd1;
            bus_reset <= (se0_cnt >= 8'd120);
        end else begin
            se0_cnt <= 8'd0;
            bus_reset <= 1'b0;
        end
    end

    // The receive state machine, advanced only at the sample clock (once per bit). rx_valid and rx_eop are pulses,
    // so they default to 0 each clock. While the PHY drives (oe) or is reset the receiver is kept idle.
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
                    // an idle bus is J; a K starts the SYNC
                    if (!se0 && !lvl) begin      // first K of SYNC (decoded 0)
                        rstate   <= R_SYNC;
                        zeros    <= 3'd1;
                        last_lvl <= 1'b0;
                    end
                end
                R_SYNC: begin
                    // SE0 in the middle of a SYNC is garbage, go back to idle
                    if (se0) begin
                        rstate <= R_IDLE;
                    end else begin
                        last_lvl <= lvl;
                        // a 0 (edge) is one more SYNC bit; the first 1 ends the SYNC, and it counts only if at least 3
                        // edges came before (a hub may eat the first bits of a SYNC)
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
                    // SE0 starts the EOP
                    if (se0) begin
                        rstate <= R_EOP;
                    end else begin
                        last_lvl <= lvl;
                    // six 1s in a row: the next bit is a stuffed 0 that carries no data and is dropped
                        if (ones == 3'd6) begin
                            ones <= 3'd0;             // stuffed bit, dropped
                            if (bit_nrzi) begin       // seven 1s: stuff error
                                err_flag <= 1'b1;
                                rstate   <= R_WAIT_SE0;
                            end
                        end else begin
                            // an ordinary data bit: shift it in, 8 of them make a byte
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
                // after a stuffing error nothing is delivered until the packet ends with its SE0
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
    // Transmit states: idle, one bit of waiting, one bit of J, the data bits (SYNC first), one more bit for a stuffed
    // bit after the last byte, then the two SE0 bits and one J bit of the EOP.
    localparam T_IDLE = 3'd0, T_WAIT = 3'd1, T_J = 3'd2, T_BITS = 3'd3, T_END = 3'd4, T_EOP = 3'd5;
    // tstate: state. tdiv: counts the 4 clocks of a bit; tick is the last of them, when a new bit may start.
    reg [2:0] tstate;
    reg [1:0] tdiv;
    wire      tick = (tdiv == 2'd3);
    // tsh: the byte being sent, shifted right so that the next bit is always tsh[0]. tbit: bits of it sent. tones: 1s in a
    // row, for stuffing. tlvl: the level now on the line (1 = J). eopcnt: counts the bits of the EOP.
    reg [7:0] tsh;
    reg [2:0] tbit;
    reg [2:0] tones;
    reg       tlvl;          // 1 = J
    reg [1:0] eopcnt;
    // busy from the first request until the line is released
    assign tx_busy = (tstate != T_IDLE);

    // The transmit state machine; every state change happens at a tick, so bit edges come every 4 clocks.
    always @(posedge clk) begin
        tx_ready <= 1'b0;
        if (rst) begin
            tstate <= T_IDLE;
            oe     <= 1'b0;
            dp_o   <= 1'b1;
            dn_o   <= 1'b0;
            tdiv   <= 2'd0;
        end else begin
            tdiv <= tdiv + 2'd1;
            case (tstate)
                T_IDLE: begin
                    oe <= 1'b0;
                    if (tx_valid) begin
                        tstate <= T_WAIT;
                        tdiv   <= 2'd0;
                    end
                end
                T_WAIT: if (tick) begin              // one idle bit time before driving, as the host does
                    tstate <= T_J;
                    oe     <= 1'b1;
                    dp_o   <= 1'b1;
                    dn_o   <= 1'b0;
                    tlvl   <= 1'b1;
                end
                T_J: if (tick) begin                 // one bit of J, then the SYNC
                    tstate    <= T_BITS;
                    tones     <= 3'd0;
                    // first SYNC bit (0): toggle to K now
                    tlvl <= 1'b0;
                    dp_o <= 1'b0;
                    dn_o <= 1'b1;
                    tsh  <= 8'h40;                    // the 7 SYNC bits still to come (SYNC is 8'h80, the first 0 went out above)
                    tbit <= 3'd1;
                end
                // Data bits (the SYNC's remaining bits first). A 0 is a change of level, a 1 keeps it, and after six 1s a
                // 0 is inserted.
                T_BITS: if (tick) begin
                    if (tones == 3'd6) begin
                        // stuffed 0
                        tones <= 3'd0;
                        tlvl  <= !tlvl;
                        dp_o  <= !tlvl;
                        dn_o  <= tlvl;
                    end else begin
                        tones <= tsh[0] ? tones + 3'd1 : 3'd0;
                        if (!tsh[0]) begin
                            tlvl <= !tlvl;
                            dp_o <= !tlvl;
                            dn_o <= tlvl;
                        end
                        tsh  <= {1'b0, tsh[7:1]};
                        tbit <= tbit + 3'd1;
                        if (tbit == 3'd7) begin
                            // this was the last bit of the byte: load the next one
                            // this was the last bit of the byte: load the next one
                            if (tx_valid) begin
                                tsh      <= tx_data;
                                tx_ready <= 1'b1;
                            end else begin
                                tstate <= T_END;
                            end
                        end
                    end
                end
                // after the last byte the last bit stays one bit time on the line before the EOP begins
                T_END: if (tick) begin
                    if (tones == 3'd6) begin         // stuffed bit due after the last byte
                        tones <= 3'd0;
                        tlvl  <= !tlvl;
                        dp_o  <= !tlvl;
                        dn_o  <= tlvl;
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
                        dp_o <= 1'b1;
                        dn_o <= 1'b0;
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
