// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Testbench for the USB sound card of the radio, rtl/usb/usb_audio.v (docs/USB_AUDIO.md): a USB 1.1 full speed device
// (12 Mbit/s) of the USB Audio Class 1.0 with 48 kHz 16 bit stereo in both directions, built in plain Verilog. The
// bench began as the USB device bench of an earlier design by the same author, and its
// behavioral USB host (line driver and receiver, CRCs, transactions, control transfers) is carried over unchanged, while the
// device under test and the tests are those of docs/USB_AUDIO.md.
//
// A little USB background for a beginner (the terms are in docs/learn/GLOSSARY.md). A USB bus has one host (the PC) that
// starts every transfer. Data goes over two wires, D+ and D-, as packets: a SYNC pattern, a packet ID (PID), the payload
// and a CRC, then an end of packet (EOP) in which both wires are held low for two bit times. The bits are NRZI coded (a 0 flips the
// line level, a 1 keeps it) and after six 1s in a row a 0 is stuffed, so that the receiver always sees edges to
// recover the clock from. Every millisecond the host sends a start of frame packet (SOF), and an audio device
// exchanges one packet per frame in each direction: isochronous packets, which carry no handshake and are never repeated, so
// a lost one is lost. The PC does not know the radio's sample rate exactly, so the device reports it back on a feedback
// endpoint (as the number of samples per frame in a 10.14 fixed point format) and the PC adjusts how many samples
// it sends in each frame.
//
// How the bench works: the host drives and reads the D+ and D- lines bit by bit (NRZI, bit stuffing, SYNC, EOP, CRC5 and
// CRC16 all written independently here), with a bit time 1000 ppm off the device's 48 MHz clock, so that the device's
// clock recovery is exercised. The firmware side is played through the register bus with the timing of
// rtl/top/regbus_leg.v (a strobe for one clock, the answer four clocks later).
//
// To save simulation time the frame clock and the sample clock both run 2x fast (a frame every 500 us and the radio's sample
// tick at 96 kHz), so a frame still carries 48 samples, and clk_dsp is 30 MHz. The device logic has no absolute time in it.
// The radio's sample clock is 5,000 ppm fast against the host's frames (48.24 samples per frame), far more than any
// crystal would be, so that the feedback loop has work to do.
//
// The tests, in order:
//  1. Enumeration: bus reset; GET_DESCRIPTOR(device) at address 0; SET_ADDRESS 5; the old address stops
//     answering; device, configuration (three packets) and string descriptors compared byte for byte with
//     the ROM file; STALL for a device qualifier, an absent string and a vendor request;
//     SET/GET_CONFIGURATION, GET_STATUS, GET_INTERFACE.
//  2. Class requests and switching: sampling frequency of both endpoints = 48000; the three audio
//     endpoints are silent in alternate setting 0; SET_INTERFACE on both; status register.
//  3. Streaming, 160 frames, both directions at once. The host sends as many samples per frame as the
//     feedback endpoint asks (read every 8 frames). Checked: every sample the PC sends arrives in the CPU
//     FIFO once and in order; every sample of the radio arrives at the PC once and in order, 47 to 49 per
//     frame; the feedback settles at the radio's rate and the buffer near its target; no fault counted;
//     the digital output stream is the radio's stream unchanged; peak meters; the high-water interrupt.
//  4. Loop-back: the PC records its own playback, sample for sample.
//  5. Monitor: the digital output stream is the radio's sample plus the PC's.
//  6. Faults, each counted and none stopping the device: a playback packet with a bad CRC; the PC stops
//     sending (one under-run, zeros, restart); the PC sends twice too much (over-run); the PC stops
//     fetching the recording (capture over-run, then caught up with 49 sample packets); the firmware stops
//     reading (CPU FIFO over-run). After the under-run everything sent has been read: samples in = out.
//  7. Interfaces off: endpoints silent. Bus reset: address 0, unconfigured.
// Every device response must start within 7.5 bit times of the host's EOP (USB 2.0 section 7.1.18.1).
//
// Pass: every check above holds, the bus is never driven by both sides at once, and the longest device response is within the
// limit. Each failed check prints "FAIL at <time> ns: <what>" (the first 40), and the run ends with "PASS", or
// "FAIL: n failures". A watchdog ends the run with "FAIL: watchdog" after 400 ms of simulated time.
//
// Run, from the repo root (the include paths and the descriptor ROM file are relative to it):
//   iverilog -g2012 -o build/tb_usb_audio.vvp sim/usb/tb_usb_audio.v && vvp build/tb_usb_audio.vvp
// -DMIDI_ONLY reads the descriptors of the MIDI-only ROM variant instead.

`timescale 1ns / 1ps
`include "rtl/usb/usb_fs_phy.v"
`include "rtl/usb/usb_afifo.v"
`include "rtl/usb/usb_fs_core.v"
`include "rtl/usb/usb_ep0.v"
`include "rtl/usb/usb_ep_cap.v"
`include "rtl/usb/usb_ep_play.v"
`include "rtl/usb/usb_play.v"
`include "rtl/usb/usb_regs.v"
`include "rtl/usb/usb_audio.v"
`include "rtl/rx_backend/bk_ram.v"

module tb_usb_audio;
    // ------------------------------------------------------------------ clocks, DUT
    // clk_usb is the 48 MHz USB clock (half period 10.416667 ns, four clocks per bit at 12 Mbit/s) and clk_sys stands in for clk_dsp,
    // at 30 MHz here (half period 16.666667 ns).
    // ------------------------------------------------------------------ clocks, DUT
    reg clk_usb = 0;
    always #(10.416667) clk_usb = ~clk_usb;       // 48 MHz
    reg clk_sys = 0;
    always #(16.666667) clk_sys = ~clk_sys;       // "clk_dsp", 30 MHz here
    reg rst_sys = 1;

    wire dp, dn;
    wire d_dp, d_dn, d_oe, pullup_en;
    reg  h_oe = 0, h_dp = 1, h_dn = 0;
    // The D+ and D- lines are shared by the device (when `d_oe` is set) and the host (when `h_oe` is set), with weak pull
    // resistors: D+ is pulled up through the device's 1.5 kohm resistor when `pullup_en` is set (which tells the host that a
    // full speed device is attached), and D- is pulled low by the host's 15 kohm resistor.
    assign dp = d_oe ? d_dp : 1'bz;
    assign dn = d_oe ? d_dn : 1'bz;
    assign dp = h_oe ? h_dp : 1'bz;
    assign dn = h_oe ? h_dn : 1'bz;
    assign (weak1, weak0) dp = pullup_en;         // 1.5 kohm pull-up, else host pull-down
    assign (weak1, weak0) dn = 1'b0;              // host 15 kohm pull-down

    // Register bus of the firmware side, the radio's 48 kHz stream into the device (s_*) and the stream out of it (m_*).
    reg  [15:0] bus_addr = 0;
    reg         bus_wr = 0, bus_rd = 0;
    reg  [31:0] bus_wdata = 0;
    wire [31:0] bus_rdata;
    reg         s_v = 0;
    reg  signed [15:0] s_l = 0, s_r = 0;
    wire        m_v;
    wire signed [15:0] m_l, m_r;
    wire        irq;

    usb_audio dut (
        .clk_usb(clk_usb), .clk_dsp(clk_sys), .rst_dsp(rst_sys),
        .dp_i(dp), .dn_i(dn), .dp_o(d_dp), .dn_o(d_dn), .oe(d_oe), .pullup_en(pullup_en),
        .bus_wr(bus_wr), .bus_rd(bus_rd), .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
        .irq(irq),
        .s_v(s_v), .s_l(s_l), .s_r(s_r), .m_v(m_v), .m_l(m_l), .m_r(m_r),
        .x_v(1'b0), .x_l(16'sd0), .x_r(16'sd0)
    );

    integer fails = 0;
    reg [7:0] pkt [0:1100];
    integer   pkt_len;
    reg [7:0] dbuf [0:1100];
    // Reports a failed check (the first 40 are printed) and counts it.
    task fail(input [8*80-1:0] msg);
        begin
            fails = fails + 1;
            if (fails < 40) $display("FAIL at %0t ns: %0s", $time, msg);
        end
    endtask

    // The host and the device must never drive the bus at the same time.
    always @(posedge clk_usb) if (d_oe && h_oe) begin
        fails = fails + 1;
        $display("FAIL at %0t ns: host and device drive the bus together", $time);
    end

    // The radio's 48 kHz stream, as the device sees it from the DSP side: a sample tick at 96 kHz times 1.005 (the test runs 2x fast),
    // made by a numerically controlled oscillator from the 30 MHz clock. The left channel counts from 0 to 8191 and the right
    // channel is the left with bit 12 turned over (the PC's samples have right = 8191 - left, so the two streams cannot be mistaken
    // for each other).
    // Frame period of the test: 500 us (a real frame is 1 ms, and the test runs 2x fast).
    localparam real FRAME_NS = 500000.0;
    // Phase increment of the oscillator for the 96.48 kHz tick (96 kHz * 1.005): 96,480 / 30e6 * 2^32 = 13,812,615 (rounded),
    // one tick whenever the 32 bit accumulator overflows.
    localparam [31:0] NCO_INC = 32'd13812615;      // round(96480 / 30e6 * 2^32)
    reg  [31:0] nco = 0;
    reg         nco_c = 0;
    reg  [12:0] s_cnt = 0;
    always @(posedge clk_sys) begin
        {nco_c, nco} <= {1'b0, nco} + NCO_INC;
        s_v <= nco_c;
        if (nco_c) begin
            s_l   <= {3'd0, s_cnt};
            s_r   <= {3'd0, s_cnt ^ 13'h1000};
            s_cnt <= s_cnt + 13'd1;
        end
    end

    // The stream for the digital outputs, which must be the radio's sample of the same tick (and with the monitor on, plus the PC's).
    // Without the monitor the difference between m_* and s_* must be 0; with it, the difference is the PC's sample, whose left
    // counts up by one each time and whose right is 8191 minus its left.
    // the stream for the digital outputs: the radio's sample of the same tick, plus the PC's with the monitor
    reg         mon_on = 0, mon_skip = 0;
    integer     mon_n = 0, mon_prev = -1;
    reg signed [15:0] cur_l = 0, cur_r = 0;
    integer     d_l, d_r;
    always @(posedge clk_sys) begin
        if (s_v) begin cur_l <= s_l; cur_r <= s_r; end
        if (m_v && !rst_sys && !mon_skip) begin
            d_l = m_l - cur_l;
            d_r = m_r - cur_r;
            if (!mon_on) begin
                if (d_l != 0 || d_r != 0) fail("output stream differs from the radio's stream");
            end else if (dut.u_play.p_live) begin
                if (d_r != 8191 - d_l) fail("monitor: right is not the PC's right");
                if (mon_prev >= 0 && d_l != ((mon_prev + 1) & 8191)) fail("monitor: PC samples not in order");
                mon_prev = d_l;
                mon_n = mon_n + 1;
            end
        end
    end

    // ------------------------------------------------------------------ register bus (regbus_leg timing)
    // A write is a strobe for one clock, a read a strobe and then the answer four clocks later, as rtl/top/regbus_leg.v does it.
    // ------------------------------------------------------------------ register bus (regbus_leg timing)
    task reg_wr(input [15:0] a, input [31:0] d);
        begin
            @(posedge clk_sys); #1 bus_addr = a; bus_wdata = d; bus_wr = 1;
            @(posedge clk_sys); #1 bus_wr = 0;
            repeat (3) @(posedge clk_sys);
        end
    endtask
    reg [31:0] rd_val;
    task reg_rd(input [15:0] a);
        begin
            @(posedge clk_sys); #1 bus_addr = a; bus_rd = 1;
            @(posedge clk_sys); #1 bus_rd = 0;
            repeat (4) @(posedge clk_sys);
            #1 rd_val = bus_rdata;
        end
    endtask

    // The firmware's reader of the CPU FIFO: while `rd_run` is set it reads the level (register 0x0C) and then that many samples
    // (register 0x10, left in the low half and right in the high half), checking that the right channel is 8191 minus the
    // left and that the left counts on by one. `f_chk` turns the order check off for the tests that lose samples on purpose.
    // the firmware's reader of the CPU FIFO: while rd_run, reads the level and then that many samples
    reg       rd_run = 0, rd_busy = 0, f_sync = 0, f_chk = 1;
    integer   f_got = 0, f_last = -1, f_lvl, f_l, f_r;
    always begin
        @(posedge clk_sys);
        if (rd_run) begin
            rd_busy = 1;
            reg_rd(16'h000C);
            f_lvl = rd_val;
            while (f_lvl > 0) begin
                reg_rd(16'h0010);
                f_l = rd_val[15:0];
                f_r = rd_val[31:16];
                if (f_r != 8191 - f_l) fail("CPU FIFO: right is not the PC's right");
                if (f_sync && f_chk && f_l != ((f_last + 1) & 8191)) fail("CPU FIFO: sample lost or repeated");
                f_sync = 1;
                f_last = f_l;
                f_got = f_got + 1;
                f_lvl = f_lvl - 1;
            end
            rd_busy = 0;
        end
    end
    task rd_stop;
        begin
            rd_run = 0;
            @(posedge clk_sys);
            wait (!rd_busy);
        end
    endtask

    // ------------------------------------------------------------------ CRCs (host side)
    // CRC-16 of USB data packets: polynomial 0x8005 (0xA001 reflected), initial value 0xFFFF, result inverted, sent low byte first.
    // ------------------------------------------------------------------ CRCs (host side)
    function [15:0] crc16(input integer n);   // over dbuf[0..n-1], returns the value to send
        integer i, k;
        reg [15:0] c;
        begin
            c = 16'hFFFF;
            for (i = 0; i < n; i = i + 1)
                for (k = 0; k < 8; k = k + 1)
                    c = (c[0] ^ dbuf[i][k]) ? ((c >> 1) ^ 16'hA001) : (c >> 1);
            crc16 = ~c;
        end
    endfunction
    // CRC-5 of USB token packets over the 11 bit address and endpoint field: polynomial 0x05 (0x14 reflected), initial 0x1F, inverted.
    function [4:0] crc5(input [10:0] v);
        integer k;
        reg [4:0] c;
        begin
            c = 5'h1F;
            for (k = 0; k < 11; k = k + 1) c = (c[0] ^ v[k]) ? ((c >> 1) ^ 5'h14) : (c >> 1);
            crc5 = ~c;
        end
    endfunction

    // ------------------------------------------------------------------ host line driver
    // ------------------------------------------------------------------ host line driver
    localparam real TBIT = 83.25;                 // host bit time 83.25 ns, 1000 ppm shorter than the nominal 83.333 ns (12 Mbit/s), so the host is 1000 ppm fast
    integer   h_lvl, h_ones;
    real      t_eop_end;

    // Sets the host's driver: 0 = SE0 (both wires low), 1 = J (D+ high), 2 = K (D- high).
    task drive(input integer s);  // 0 SE0, 1 J, 2 K
        begin
            h_oe = 1;
            h_dp = (s == 1);
            h_dn = (s == 2);
        end
    endtask
    // Sends one bit NRZI coded with bit stuffing: a 0 flips the line level, a 1 keeps it, and after six 1s in a row a 0 is stuffed.
    task send_bit(input integer b);
        begin
            if (b == 0) h_lvl = !h_lvl;
            drive(h_lvl ? 1 : 2);
            #(TBIT);
            h_ones = b ? h_ones + 1 : 0;
            if (h_ones == 6) begin
                h_lvl = !h_lvl;
                drive(h_lvl ? 1 : 2);
                #(TBIT);
                h_ones = 0;
            end
        end
    endtask
    // Sends the packet in pkt[0 .. pkt_len-1]: the SYNC pattern (seven 0s and a 1, which is KJKJKJKK on the line), the bytes
    // least significant bit first, then the EOP (two bit times of SE0 and one of J), and then lets go of the bus.
    task send_raw;
        integer i, k;
        begin
            h_lvl = 1;
            h_ones = 0;
            for (i = 0; i < 8; i = i + 1) send_bit(i == 7);
            for (i = 0; i < pkt_len; i = i + 1)
                for (k = 0; k < 8; k = k + 1) send_bit(pkt[i][k]);
            drive(0); #(2 * TBIT);
            drive(1); #(TBIT);
            h_oe = 0;
            t_eop_end = $realtime;
        end
    endtask

    // Packet IDs (USB 2.0 table 8-1). A PID byte holds the 4 bit PID in its low half and its complement in the high half.
    localparam [3:0] P_OUT = 4'h1, P_IN = 4'h9, P_SOF = 4'h5, P_SETUP = 4'hD,
                     P_DATA0 = 4'h3, P_DATA1 = 4'hB, P_ACK = 4'h2, P_NAK = 4'hA, P_STALL = 4'hE;

    // Token packet: PID and 11 bits of address (7) and endpoint (4), or the frame number for an SOF, then the CRC-5.
    task send_token(input [3:0] pid, input [10:0] v);
        reg [4:0] c;
        begin
            c = crc5(v);
            pkt[0] = {~pid, pid};
            pkt[1] = v[7:0];
            pkt[2] = {c, v[10:8]};
            pkt_len = 3;
            send_raw;
        end
    endtask
    // Data packet: PID, n bytes from dbuf, then the CRC-16 low byte first.
    task send_data(input [3:0] pid, input integer n);
        integer i;
        reg [15:0] c;
        begin
            c = crc16(n);
            pkt[0] = {~pid, pid};
            for (i = 0; i < n; i = i + 1) pkt[1 + i] = dbuf[i];
            pkt[1 + n] = c[7:0];
            pkt[2 + n] = c[15:8];
            pkt_len = n + 3;
            send_raw;
        end
    endtask
    // Handshake packet, just a PID.
    task send_hs(input [3:0] pid);
        begin
            pkt[0] = {~pid, pid};
            pkt_len = 1;
            send_raw;
        end
    endtask

    // ------------------------------------------------------------------ host receiver
    // Receives one packet from the device into rx[]. rx_len is the number of bytes including PID and CRC, -1 for a timeout and -2
    // for a line error. `max_resp_ns` is the longest time from the host's EOP to the start of a device response.
    // ------------------------------------------------------------------ host receiver
    reg [7:0] rx [0:1100];
    integer   rx_len;        // bytes including PID and CRC; -1 timeout, -2 line error
    integer   max_resp_ns;

    // Line state from the two wire levels: 0 SE0, 1 J, 2 K, 3 SE1 (an illegal state).
    function integer lstate(input a, input b);  // 0 SE0, 1 J, 2 K, 3 SE1
        lstate = (a === 1'b1 && b === 1'b0) ? 1 : (a === 1'b0 && b === 1'b1) ? 2 :
                 (a === 1'b0 && b === 1'b0) ? 0 : 3;
    endfunction

    // Waits up to `timeout_ns` for the device to start a packet with a K, measures the response time from the host's last EOP
    // (and checks it against 7.5 bit times when `check_resp` is set), and then samples the line eight times per bit time,
    // taking the bit at the fourth sample, in the middle of the bit. It decodes NRZI (the same level as before is a 1), requires
    // the SYNC (seven 0s and a 1), removes stuffed bits, packs the bits into bytes, and ends at the EOP (SE0).
    task recv_packet(input real timeout_ns, input integer check_resp);
        real t0, resp;
        integer cur, prev, cnt, last_lvl, lvl, bitv, zeros, in_sync, ones, nbits, done, steps;
        reg [7:0] sh;
        begin
            t0 = $realtime;
            rx_len = -1;
            while (lstate(dp, dn) != 2 && ($realtime - t0) < timeout_ns) #(TBIT / 16);
            if (lstate(dp, dn) == 2) begin
                resp = $realtime - t_eop_end;
                if (check_resp) begin
                    if (resp > 7.5 * TBIT) fail("device response later than 7.5 bit times");
                    if (resp > max_resp_ns) max_resp_ns = resp;
                end
                prev = 2; cnt = 0; last_lvl = 1; zeros = 0; in_sync = 1; ones = 0; nbits = 0;
                done = 0; steps = 0; rx_len = 0;
                while (!done) begin
                    #(TBIT / 8);
                    steps = steps + 1;
                    cur = lstate(dp, dn);
                    if (cur != prev) cnt = 0; else cnt = (cnt + 1) % 8;
                    prev = cur;
                    // Gives up after 12,000 bit times, so a stuck line cannot hang the bench.
                    if (steps > 8 * 12000) begin rx_len = -2; done = 1; end
                    if (cnt == 4) begin
                        if (cur == 0) begin
                            done = 1;
                            if (in_sync || (nbits % 8) != 0) rx_len = -2;
                        end else if (cur == 3) begin
                            done = 1; rx_len = -2;
                        end else begin
                            lvl = (cur == 1);
                            bitv = (lvl == last_lvl);
                            last_lvl = lvl;
                            if (in_sync) begin
                                if (!bitv) zeros = zeros + 1;
                                else if (zeros == 7) begin in_sync = 0; ones = 1; end
                                else begin done = 1; rx_len = -2; end
                            end else if (ones == 6) begin
                                if (bitv) begin done = 1; rx_len = -2; end
                                ones = 0;
                            end else begin
                                ones = bitv ? ones + 1 : 0;
                                sh = {bitv[0], sh[7:1]};
                                nbits = nbits + 1;
                                if (nbits % 8 == 0) begin
                                    rx[nbits / 8 - 1] = sh;
                                    rx_len = nbits / 8;
                                end
                            end
                        end
                    end
                end
                // rest of the EOP: wait for J
                t0 = $realtime;
                while (lstate(dp, dn) != 1 && ($realtime - t0) < 4 * TBIT) #(TBIT / 16);
                if (lstate(dp, dn) != 1) rx_len = -2;
                #(2 * TBIT);   // inter-packet gap before the host answers
            end
        end
    endtask

    // ------------------------------------------------------------------ transactions
    // Results of a transaction: nothing came back, ACK, NAK, STALL, DATA0, DATA1, or something wrong.
    // ------------------------------------------------------------------ transactions
    localparam integer R_TIMEOUT = 0, R_ACK = 1, R_NAK = 2, R_STALL = 3, R_DATA0 = 4, R_DATA1 = 5, R_ERR = 6;
    integer   res;
    reg [7:0] ibuf [0:1100];
    integer   ilen;

    // Receives a handshake packet and sets `res` from it.
    task get_hs;
        begin
            recv_packet(20 * TBIT, 1);
            if (rx_len == -1) res = R_TIMEOUT;
            else if (rx_len != 1) res = R_ERR;
            else if (rx[0] == {~P_ACK, P_ACK}) res = R_ACK;
            else if (rx[0] == {~P_NAK, P_NAK}) res = R_NAK;
            else if (rx[0] == {~P_STALL, P_STALL}) res = R_STALL;
            else res = R_ERR;
            if (res == R_ERR) $display("  handshake error: rx_len %0d rx[0] %h", rx_len, rx[0]);
        end
    endtask

    // A SETUP transaction: the SETUP token, then the 8 byte setup packet in dbuf as DATA0, then the device's handshake.
    task do_setup(input [6:0] a);
        begin
            send_token(P_SETUP, {4'd0, a});
            #(2 * TBIT);
            send_data(P_DATA0, 8);
            get_hs;
        end
    endtask

    // An OUT transaction: the OUT token, a data packet with `pid` and n bytes from dbuf, then the handshake.
    task do_out(input [6:0] a, input [3:0] ep, input [3:0] pid, input integer n);
        begin
            send_token(P_OUT, {ep, a});
            #(2 * TBIT);
            send_data(pid, n);
            get_hs;
        end
    endtask

    // An IN transaction: the IN token, then the device's data packet, whose CRC-16 is checked by running it over data and CRC
    // together, which must leave the fixed residue 0xB001. The data goes to ibuf and `ilen`. With `ack` set the host
    // answers with an ACK (isochronous endpoints get none).
    task do_in(input [6:0] a, input [3:0] ep, input integer ack);
        integer i, k;
        reg [15:0] c;
        begin
            send_token(P_IN, {ep, a});
            recv_packet(20 * TBIT, 1);
            ilen = 0;
            if (rx_len == -1) res = R_TIMEOUT;
            else if (rx_len < 1) res = R_ERR;
            else if (rx_len == 1) begin
                if (rx[0] == {~P_NAK, P_NAK}) res = R_NAK;
                else if (rx[0] == {~P_STALL, P_STALL}) res = R_STALL;
                else res = R_ERR;
            end else if (rx_len >= 3 && (rx[0] == {~P_DATA0, P_DATA0} || rx[0] == {~P_DATA1, P_DATA1})) begin
                c = 16'hFFFF;
                for (i = 1; i < rx_len; i = i + 1)
                    for (k = 0; k < 8; k = k + 1)
                        c = (c[0] ^ rx[i][k]) ? ((c >> 1) ^ 16'hA001) : (c >> 1);
                if (c != 16'hB001) res = R_ERR;
                else begin
                    res = (rx[0][3]) ? R_DATA1 : R_DATA0;
                    ilen = rx_len - 3;
                    for (i = 0; i < ilen; i = i + 1) ibuf[i] = rx[1 + i];
                    if (ack) send_hs(P_ACK);
                end
            end else res = R_ERR;
        end
    endtask

    // Control transfers on endpoint 0. `cres` is R_ACK for success, R_STALL or R_ERR.
    // control transfers
    reg [7:0] cbuf [0:1100];
    integer   clen, cres;   // cres: R_ACK ok, R_STALL, R_ERR

    // Fills dbuf with the 8 byte setup packet: request type, request, value, index, length (each 16 bit field low byte first).
    task setup_pkt(input [7:0] bm, input [7:0] br, input [15:0] wv, input [15:0] wi, input [15:0] wl);
        begin
            dbuf[0] = bm; dbuf[1] = br; dbuf[2] = wv[7:0]; dbuf[3] = wv[15:8];
            dbuf[4] = wi[7:0]; dbuf[5] = wi[15:8]; dbuf[6] = wl[7:0]; dbuf[7] = wl[15:8];
        end
    endtask

    // Control transfer with a data stage from the device: the setup stage, then IN transactions with alternating DATA1 and DATA0
    // (up to 20 NAKs are tolerated and retried) until a short packet (under 64 bytes) or the requested length, then the status
    // stage, a zero length OUT with DATA1. The data lands in cbuf and `clen`.
    task control_read(input [6:0] a, input [7:0] bm, input [7:0] br, input [15:0] wv, input [15:0] wi, input [15:0] wl);
        integer tog, tries, i, fin;
        begin
            setup_pkt(bm, br, wv, wi, wl);
            do_setup(a);
            clen = 0;
            cres = R_ERR;
            if (res == R_ACK) begin
                tog = 1; fin = 0; tries = 0;
                while (!fin) begin
                    do_in(a, 0, 1);
                    if (res == R_NAK && tries < 20) tries = tries + 1;
                    else if (res == R_STALL) begin cres = R_STALL; fin = 2; end
                    else if (res == (tog ? R_DATA1 : R_DATA0)) begin
                        for (i = 0; i < ilen; i = i + 1) cbuf[clen + i] = ibuf[i];
                        clen = clen + ilen;
                        tog = !tog;
                        if (ilen < 64 || clen >= wl) fin = 1;
                    end else begin
                        fin = 3;
                        $display("  control read: data stage result %0d, rx_len %0d, rx[0] %h, tog %0d", res, rx_len, rx[0], tog);
                    end
                end
                if (fin == 1) begin
                    tries = 0;
                    res = R_NAK;
                    while (res == R_NAK && tries < 20) begin
                        do_out(a, 0, P_DATA1, 0);
                        tries = tries + 1;
                    end
                    cres = (res == R_ACK) ? R_ACK : R_ERR;
                end
            end
        end
    endtask

    // Control transfer without a data stage from the device (or with n bytes to it, a SET_CUR payload): the setup stage, the OUT
    // data stage if there is one, and the status stage, an IN that must give a zero length DATA1.
    task control_write(input [6:0] a, input [7:0] bm, input [7:0] br, input [15:0] wv, input [15:0] wi, input integer n);
        integer tries;
        begin
            setup_pkt(bm, br, wv, wi, n[15:0]);
            do_setup(a);
            cres = R_ERR;
            if (res == R_ACK) begin
                res = R_ACK;
                if (n > 0) begin
                    dbuf[0] = 8'h80; dbuf[1] = 8'hBB; dbuf[2] = 8'h00;
                    do_out(a, 0, P_DATA1, n);
                end
                if (res == R_STALL) cres = R_STALL;
                else if (res == R_ACK) begin
                    tries = 0;
                    res = R_NAK;
                    while (res == R_NAK && tries < 20) begin
                        do_in(a, 0, 1);
                        tries = tries + 1;
                    end
                    if (res == R_STALL) cres = R_STALL;
                    else if (res == R_DATA1 && ilen == 0) cres = R_ACK;
                end
            end
        end
    endtask

    // A bus reset: the host holds SE0, which a real host does for 10 ms and which this device already acts on after 2.5 us.
    task bus_reset;
        begin
            drive(0);
            #5000;             // a real host holds SE0 for 10 ms; the device acts after 2.5 us
            drive(1);
            #(TBIT);
            h_oe = 0;
            #3000;
        end
    endtask

    // ------------------------------------------------------------------ reference ROM
    // The descriptor ROM file of the device, read here independently as the reference to compare the device's answers against.
    // Each slot has an entry of 4 bytes at the start, an offset and a length (16 bit, low byte first), into the ROM.
    // ------------------------------------------------------------------ reference ROM
    reg [7:0] rom [0:511];
`ifdef MIDI_ONLY
    initial $readmemh("rtl/usb/usb_desc_rom_midi.hex", rom);
`else
    initial $readmemh("rtl/usb/usb_desc_rom.hex", rom);
`endif
    function integer rom_off(input integer slot);
        rom_off = rom[slot * 4] + 256 * rom[slot * 4 + 1];
    endfunction
    function integer rom_len(input integer slot);
        rom_len = rom[slot * 4 + 2] + 256 * rom[slot * 4 + 3];
    endfunction
    // Compares the descriptor that the last control read returned (cbuf, clen) with the ROM's slot, byte for byte.
    task check_desc(input integer slot, input integer n, input [8*40-1:0] what);
        integer i, bad;
        begin
            bad = 0;
            if (cres != R_ACK) bad = 1;
            if (clen != n) bad = 1;
            for (i = 0; i < n && i < clen; i = i + 1) if (cbuf[i] != rom[rom_off(slot) + i]) bad = 1;
            if (bad) begin
                $display("  %0s: result %0d, %0d bytes, expected %0d", what, cres, clen, n);
                fail("descriptor mismatch");
            end else $display("  %0s: %0d bytes, match", what, clen);
        end
    endtask

    // ------------------------------------------------------------------ one frame of audio traffic
    // ------------------------------------------------------------------ one frame of audio traffic
    integer   addr, sof_n, p_cnt, acc, cap_prev, cap_sync, cap_pb, cap_min, cap_max, cap_total, cap_frames;
    integer   fill_sof, fill_min, fill_max, fb_n;
    reg [23:0] fb_host;
    real      t_frame, fb_sum;

    // A DATA0 packet with a wrong CRC16 (its first CRC byte inverted).
    task send_data_bad(input integer n);        // DATA0 with a wrong CRC16
        integer i;
        reg [15:0] c;
        begin
            c = crc16(n);
            pkt[0] = {~P_DATA0, P_DATA0};
            for (i = 0; i < n; i = i + 1) pkt[1 + i] = dbuf[i];
            pkt[1 + n] = ~c[7:0];
            pkt[2 + n] = c[15:8];
            pkt_len = n + 3;
            send_raw;
        end
    endtask

    // n stereo samples to endpoint 0x01 (the playback endpoint): left = the running count, right = 8191 - left, as 16 bit words, low
    // byte first. An isochronous OUT has no handshake, so any answer from the device is a failure.
    // n stereo samples to endpoint 0x01: left = the running count, right = 8191 - left
    task out_packet(input integer n, input integer bad);
        integer i, v;
        begin
            for (i = 0; i < n; i = i + 1) begin
                v = p_cnt & 8191;
                dbuf[4*i]   = v[7:0];
                dbuf[4*i+1] = v[15:8];
                v = 8191 - v;
                dbuf[4*i+2] = v[7:0];
                dbuf[4*i+3] = v[15:8];
                p_cnt = p_cnt + 1;
            end
            send_token(P_OUT, {4'd1, addr[6:0]});
            #(2 * TBIT);
            if (bad) send_data_bad(4 * n);
            else     send_data(P_DATA0, 4 * n);
            recv_packet(12 * TBIT, 0);
            if (rx_len != -1) fail("a handshake after an isochronous OUT packet");
        end
    endtask

    // One 500 us frame as the host does it. `send`: 0 nothing, 1 as many samples as the feedback asks, 2 that and 48 more,
    // 3 with a bad CRC. `poll_cap` fetches the recording packet from endpoint 2 (1 fetches and checks, 2 fetches and does not check),
    // and `poll_fb` reads the feedback endpoint (1).
    // send: 0 nothing, 1 what the feedback asks, 2 that and 48 more, 3 with a bad CRC
    task frame(input integer send, input integer poll_cap, input integer poll_fb);
        integer i, n, lval, rval;
        begin
            // Wait for the start of the frame, then send the SOF with the frame number.
            t_frame = t_frame + FRAME_NS;
            if (t_frame < $realtime) fail("frame overrun in the test itself");
            else #(t_frame - $realtime);
            sof_n = sof_n + 1;
            send_token(P_SOF, sof_n[10:0]);
            #(3 * TBIT);
            // The playback buffer's fill at the start of a frame (256 words minus the free words), tracked for min and max.
            fill_sof = 256 - dut.pw_free;
            if (fill_sof < fill_min) fill_min = fill_sof;
            if (fill_sof > fill_max) fill_max = fill_sof;
            // Feedback: 3 bytes, samples per frame in 10.14 fixed point (divided by 16384 for the average).
            if (poll_fb) begin
                do_in(addr[6:0], 1, 0);
                if (res != R_DATA0 || ilen != 3) fail("feedback packet");
                else begin
                    fb_host = {ibuf[2], ibuf[1], ibuf[0]};
                    fb_sum = fb_sum + fb_host / 16384.0;
                    fb_n = fb_n + 1;
                end
                #(3 * TBIT);
            end
            // Playback: the number of samples comes from the accumulated feedback value (a fraction of a sample is carried to the next frame).
            if (send != 0) begin
                acc = acc + fb_host;
                n = acc >> 14;
                acc = acc & 16383;
                out_packet(n, send == 3);
                if (send == 2) out_packet(48, 0);
            end
            // Capture: the packet from endpoint 2 must be whole stereo samples, with the right channel and the running count as expected.
            if (poll_cap) begin
                do_in(addr[6:0], 2, 0);
                if (res != R_DATA0 || (ilen % 4) != 0) begin
                    $display("  frame %0d: result %0d len %0d", sof_n, res, ilen);
                    fail("capture packet");
                end
                n = ilen / 4;
                for (i = 0; i < n && poll_cap == 1; i = i + 1) begin
                    lval = ibuf[4*i] | (ibuf[4*i+1] << 8);
                    rval = ibuf[4*i+2] | (ibuf[4*i+3] << 8);
                    if (rval != (cap_pb ? 8191 - lval : (lval ^ 4096))) fail("capture: right channel");
                    if (cap_sync && lval != ((cap_prev + 1) & 8191)) begin
                        $display("  frame %0d sample %0d: %0d after %0d", sof_n, i, lval, cap_prev);
                        fail("capture: sample lost or repeated");
                    end
                    cap_sync = 1;
                    cap_prev = lval;
                end
                if (poll_cap != 1) cap_sync = 0;      // 2: fetched, not checked (a switch-over)
                if (n < cap_min) cap_min = n;
                if (n > cap_max) cap_max = n;
                cap_total = cap_total + n;
                cap_frames = cap_frames + 1;
            end
        end
    endtask
    // Resets the per frame statistics.
    task stats_clear;
        begin
            cap_min = 999; cap_max = 0; cap_total = 0; cap_frames = 0;
            fill_min = 999; fill_max = 0; fb_sum = 0; fb_n = 0;
        end
    endtask

    // ------------------------------------------------------------------ test
    // ------------------------------------------------------------------ test
    integer i, f, n, e0, e1;

    initial begin
        max_resp_ns = 0;
        sof_n = 0; p_cnt = 0; acc = 0; cap_prev = -1; cap_sync = 0; cap_pb = 0;
        fb_host = 24'd786432;                    // 48.0 until the device says otherwise
        stats_clear;
        // known-answer check of the host CRC16: GET_DESCRIPTOR setup packet -> DD 94
        setup_pkt(8'h80, 8'h06, 16'h0100, 16'h0000, 16'h0040);
        if (crc16(8) != 16'h94DD) fail("host CRC16 known answer");
        if (crc5(11'h000) != 5'h02) fail("host CRC5 known answer");

        // Reset, then the first checks of the register page: ID, ctrl and fifo_mark after reset.
        #400 rst_sys = 0;
        #3000;
        if (lstate(dp, dn) != 1) fail("no J idle after reset (pull-up off?)");
        reg_rd(16'h0000);
        if (rd_val != 32'h55530001) fail("register ID");
        reg_rd(16'h0004);
        if (rd_val != 32'h1) fail("ctrl after reset");
        reg_rd(16'h0014);
        if (rd_val != 32'd512) fail("fifo_mark after reset");

        $display("-- 1. enumeration");
        bus_reset;
        control_read(0, 8'h80, 8'h06, 16'h0100, 0, 64);
        check_desc(0, 18, "device descriptor @0");
        control_write(0, 8'h00, 8'h05, 5, 0, 0);
        if (cres != R_ACK) fail("SET_ADDRESS");
        addr = 5;
        do_in(0, 0, 0);
        if (res != R_TIMEOUT) fail("old address 0 still answers");
        control_read(addr, 8'h80, 8'h06, 16'h0100, 0, 18);
        check_desc(0, 18, "device descriptor @5");
        control_read(addr, 8'h80, 8'h06, 16'h0200, 0, 9);
        check_desc(1, 9, "configuration (9)");
        n = cbuf[2] + 256 * cbuf[3];
        if (n != rom_len(1) || n != 183) fail("wTotalLength");
        control_read(addr, 8'h80, 8'h06, 16'h0200, 0, 255);
        check_desc(1, n, "configuration (all)");
        control_read(addr, 8'h80, 8'h06, 16'h0300, 0, 255);
        check_desc(2, 4, "string 0");
        control_read(addr, 8'h80, 8'h06, 16'h0302, 16'h0409, 255);
        check_desc(4, rom_len(4), "string 2 (product)");
        control_read(addr, 8'h80, 8'h06, 16'h0304, 16'h0409, 255);
        if (cres != R_STALL) fail("absent string not STALLed");
        control_read(addr, 8'h80, 8'h06, 16'h0600, 0, 10);
        if (cres != R_STALL) fail("device qualifier not STALLed");
        // exactly 64 bytes asked of a longer descriptor: one full packet, no ZLP
        control_read(addr, 8'h80, 8'h06, 16'h0200, 0, 64);
        check_desc(1, 64, "configuration (64)");
        control_write(addr, 8'h00, 8'h09, 1, 0, 0);
        if (cres != R_ACK) fail("SET_CONFIGURATION");
        control_read(addr, 8'h80, 8'h08, 0, 0, 1);
        if (cres != R_ACK || clen != 1 || cbuf[0] != 1) fail("GET_CONFIGURATION");
        control_read(addr, 8'h80, 8'h00, 0, 0, 2);
        if (cres != R_ACK || clen != 2 || cbuf[0] != 1) fail("GET_STATUS device");
        control_read(addr, 8'h81, 8'h0A, 0, 1, 1);
        if (cres != R_ACK || clen != 1 || cbuf[0] != 0) fail("GET_INTERFACE 1");
        control_read(addr, 8'h81, 8'h0A, 0, 3, 1);
        if (cres != R_STALL) fail("GET_INTERFACE 3 not STALLed");
        control_write(addr, 8'h40, 8'h01, 0, 0, 0);
        if (cres != R_STALL) fail("vendor request not STALLed");
        control_write(addr, 8'h02, 8'h01, 0, 16'h0001, 0);
        if (cres != R_ACK) fail("CLEAR_FEATURE(ENDPOINT_HALT) not accepted");
        reg_rd(16'h0008);
        if (rd_val[3:0] != 4'b0001) fail("status after configuration");

        $display("-- 2. class requests, switching the interfaces");
        control_read(addr, 8'hA2, 8'h81, 16'h0100, 16'h0001, 3);
        if (cres != R_ACK || clen != 3 || {cbuf[2], cbuf[1], cbuf[0]} != 24'd48000) fail("GET_CUR sampling frequency, playback");
        control_read(addr, 8'hA2, 8'h81, 16'h0100, 16'h0082, 3);
        if (cres != R_ACK || clen != 3 || {cbuf[2], cbuf[1], cbuf[0]} != 24'd48000) fail("GET_CUR sampling frequency, capture");
        control_write(addr, 8'h22, 8'h01, 16'h0100, 16'h0001, 3);
        if (cres != R_ACK) fail("SET_CUR sampling frequency");
        t_frame = $realtime;
        frame(0, 0, 0);
        do_in(addr[6:0], 2, 0);
        if (res != R_TIMEOUT) fail("capture endpoint answers in alt setting 0");
        do_in(addr[6:0], 1, 0);
        if (res != R_TIMEOUT) fail("feedback endpoint answers in alt setting 0");
        control_write(addr, 8'h01, 8'h0B, 1, 1, 0);
        if (cres != R_ACK) fail("SET_INTERFACE(1,1)");
        control_write(addr, 8'h01, 8'h0B, 1, 2, 0);
        if (cres != R_ACK) fail("SET_INTERFACE(2,1)");
        control_write(addr, 8'h01, 8'h0B, 2, 2, 0);
        if (cres != R_STALL) fail("SET_INTERFACE(2,2) not STALLed");
        control_read(addr, 8'h81, 8'h0A, 0, 2, 1);
        if (cres != R_ACK || clen != 1 || cbuf[0] != 1) fail("GET_INTERFACE 2");
        reg_rd(16'h0008);
        if (rd_val[3:0] != 4'b0111) fail("status: both interfaces on");
        reg_rd(16'h0024);                        // clears the peak meters
        reg_wr(16'h0004, 32'h3);                 // connect, CPU FIFO on
        $display("  sampling frequency 48000 on both, endpoints silent in alt 0, both interfaces on");

        $display("-- 3. streaming both ways, 160 frames");
        rd_run = 1;
        t_frame = $realtime;
        for (f = 0; f < 160; f = f + 1) begin
            if (f == 96) stats_clear;
            frame(1, 1, (f % 8) == 7);
        end
        $display("  frames 96-159: capture %0d samples in %0d frames, %0d to %0d per frame", cap_total, cap_frames, cap_min, cap_max);
        $display("  feedback %0.4f samples per frame (radio makes 48.24), buffer at start of frame %0d to %0d (target 72)",
                 fb_sum / fb_n, fill_min, fill_max);
        if (cap_min < 47 || cap_max > 49) fail("capture packet sizes outside 47-49");
        if (cap_total < 64 * 48 + 8 || cap_total > 64 * 48 + 24) fail("capture average rate");
        if (fb_sum / fb_n < 48.24 - 0.08 || fb_sum / fb_n > 48.24 + 0.08) fail("feedback did not settle at the radio's rate");
        if (fill_min < 40 || fill_max > 80) fail("playback buffer far from its target");
        rd_stop;
        reg_rd(16'h0008);
        if (rd_val[3:0] != 4'b1111) fail("status: playback reader not running");
        reg_rd(16'h0018);
        if (rd_val != 0) fail("playback under-run or over-run counted in normal running");
        reg_rd(16'h001C);
        if (rd_val != 0) fail("capture or CPU FIFO over-run counted in normal running");
        reg_rd(16'h0020);
        if (rd_val != 0) fail("bad packet counted");
        reg_rd(16'h0024);
        if (rd_val != {1'b0, 15'd8191, 1'b0, 15'd8191}) fail("peak meters");
        $display("  CPU FIFO: %0d samples read, in order; %0d sent; no fault counted", f_got, p_cnt);
        if (f_got < p_cnt - 400 || f_got > p_cnt) fail("CPU FIFO sample count");
        // high-water interrupt: nobody reads for three frames
        reg_wr(16'h0014, 32'd100);
        if (irq) fail("interrupt before the mark");
        for (f = 0; f < 3; f = f + 1) frame(1, 1, 0);
        if (!irq) fail("no interrupt at the mark");
        rd_run = 1;
        frame(1, 1, 1);
        if (irq) fail("interrupt still high after reading");
        $display("  high-water interrupt: ok");

        $display("-- 4. loop-back");
        rd_stop;
        reg_wr(16'h0004, 32'hB);
        rd_run = 1;
        frame(1, 2, 0); frame(1, 2, 0); frame(1, 2, 0);
        cap_pb = 1; cap_sync = 0; stats_clear;
        for (f = 0; f < 12; f = f + 1) frame(1, 1, (f % 8) == 7);
        if (cap_total < 12 * 47) fail("loop-back: too few samples");
        if (p_cnt - cap_prev > 400 && ((p_cnt - cap_prev) & 8191) > 400) fail("loop-back: not the samples just sent");
        $display("  %0d samples came back in order; last sent %0d, last back %0d", cap_total, (p_cnt - 1) & 8191, cap_prev);
        rd_stop;
        reg_wr(16'h0004, 32'h3);
        rd_run = 1;
        frame(1, 2, 0); frame(1, 2, 0); frame(1, 2, 0);
        cap_pb = 0; cap_sync = 0;

        $display("-- 5. monitor");
        rd_stop;
        mon_skip = 1;                            // no check while the switch is being written
        reg_wr(16'h0004, 32'h7);
        rd_run = 1;
        frame(1, 1, 0);
        mon_n = 0; mon_prev = -1; mon_on = 1; mon_skip = 0;
        for (f = 0; f < 8; f = f + 1) frame(1, 1, (f % 8) == 7);
        mon_skip = 1; mon_on = 0;
        rd_stop;
        reg_wr(16'h0004, 32'h3);
        rd_run = 1;
        if (mon_n < 8 * 47) fail("monitor: too few samples checked");
        $display("  %0d output samples = radio + PC", mon_n);
        frame(1, 1, 0);
        mon_skip = 0;
        frame(1, 1, 0);

        $display("-- 6. faults");
        // (a) The PC stops sending: one under-run, then everything sent has been read.
        // (a) the PC stops sending: one under-run, then everything sent has been read
        for (f = 0; f < 5; f = f + 1) frame(0, 1, 0);
        rd_stop;
        reg_rd(16'h0018);
        if (rd_val != 32'h0000_0001) fail("exactly one under-run expected");
        reg_rd(16'h0008);
        if (rd_val[3] != 1'b0) fail("reader still running after the under-run");
        reg_rd(16'h000C);
        if (rd_val != 0) fail("CPU FIFO not empty");
        if (f_got != p_cnt || f_last != ((p_cnt - 1) & 8191)) fail("samples in differ from samples out");
        $display("  under-run: counted once; %0d samples sent, %0d read, all in order", p_cnt, f_got);
        // (b) A packet with a bad CRC is dropped whole. From here on samples are lost on purpose, so the order
        // check of the CPU FIFO is off (the check of each sample against itself stays on).
        f_chk = 0;
        rd_run = 1;
        for (f = 0; f < 3; f = f + 1) frame(1, 1, 0);
        f_sync = 0;
        frame(3, 1, 0);
        for (f = 0; f < 4; f = f + 1) frame(1, 1, (f == 0));
        rd_stop;
        reg_rd(16'h0020);
        if (rd_val != 1) fail("bad packet not counted once");
        reg_rd(16'h0008);
        if (rd_val[3] != 1'b1) fail("reader not running again");
        $display("  bad CRC: packet dropped and counted");
        // (c) The PC sends twice too much: an over-run, and the device goes on.
        // (c) the PC sends twice too much: over-run, and the device goes on
        rd_run = 1;
        reg_rd(16'h0018);
        e0 = rd_val[31:16];
        f_sync = 0;
        for (f = 0; f < 8; f = f + 1) begin f_sync = 0; frame(2, 1, 0); end
        f_sync = 0;
        for (f = 0; f < 3; f = f + 1) begin f_sync = 0; frame(0, 1, 0); end
        rd_stop;
        reg_rd(16'h0018);
        if (rd_val[31:16] == e0) fail("playback over-run not counted");
        $display("  playback over-run: %0d samples dropped and counted", rd_val[31:16] - e0);
        // (d) The PC stops fetching the recording, then catches up.
        // (d) the PC stops fetching the recording, then catches up
        rd_run = 1;
        for (f = 0; f < 5; f = f + 1) frame(1, 0, (f == 0));
        cap_sync = 0; stats_clear;
        for (f = 0; f < 60; f = f + 1) frame(1, (f < 4) ? 2 : 1, (f % 8) == 7);
        rd_stop;
        reg_rd(16'h001C);
        if (rd_val[15:0] == 0) fail("capture over-run not counted");
        if (cap_max != 49) fail("no 49-sample packets after the capture backlog");
        // 49 samples a frame against the 48.24 the radio makes here: 60 frames take 45 of the 128 samples waiting.
        // 49 a frame against the 48.24 the radio makes here: 60 frames take 45 of the 128 waiting
        if (dut.u_ep_cap.avail > 100) fail("capture backlog is not draining");
        $display("  capture over-run: %0d samples dropped and counted; backlog draining with 49-sample packets, %0d left", rd_val[15:0], dut.u_ep_cap.avail);
        // (e) The firmware stops reading: CPU FIFO over-run and interrupt, then it drains.
        // (e) the firmware stops reading: CPU FIFO over-run, interrupt, then it drains
        for (f = 0; f < 24; f = f + 1) frame(1, 1, (f % 8) == 7);
        reg_rd(16'h001C);
        if (rd_val[31:16] == 0) fail("CPU FIFO over-run not counted");
        reg_rd(16'h000C);
        if (rd_val != 1024 || !irq) fail("CPU FIFO not full");
        $display("  CPU FIFO over-run: %0d samples dropped and counted", 0 + dut.u_regs.n_fifo);
        f_sync = 0; i = f_got;
        rd_run = 1;
        frame(1, 1, 0);
        frame(1, 1, 0);
        rd_stop;
        if (f_got - i < 1024) fail("CPU FIFO did not drain");
        reg_wr(16'h0004, 32'h1);
        reg_rd(16'h000C);
        if (rd_val != 0 || irq) fail("CPU FIFO not empty when switched off");

        $display("-- 7. interfaces off, bus reset");
        control_write(addr, 8'h01, 8'h0B, 0, 1, 0);
        if (cres != R_ACK) fail("SET_INTERFACE(1,0)");
        control_write(addr, 8'h01, 8'h0B, 0, 2, 0);
        if (cres != R_ACK) fail("SET_INTERFACE(2,0)");
        t_frame = $realtime;
        frame(0, 0, 0);
        do_in(addr[6:0], 2, 0);
        if (res != R_TIMEOUT) fail("capture endpoint still answers after alt 0");
        do_in(addr[6:0], 1, 0);
        if (res != R_TIMEOUT) fail("feedback endpoint still answers after alt 0");
        reg_rd(16'h0008);
        if (rd_val[3:0] != 4'b0001 || rd_val[24:16] != 0) fail("status after both interfaces off");
        bus_reset;
        control_read(addr, 8'h80, 8'h06, 16'h0100, 0, 18);
        if (cres == R_ACK) fail("old address answers after bus reset");
        control_read(0, 8'h80, 8'h06, 16'h0100, 0, 18);
        check_desc(0, 18, "device descriptor @0 after reset");
        reg_rd(16'h0008);
        if (rd_val[0] != 1'b0) fail("still configured after bus reset");
        reg_wr(16'h0004, 32'h0);
        #3000;
        if (lstate(dp, dn) != 0) fail("pull-up still on after ctrl.connect = 0");

        $display("longest device response: %0.1f ns = %0.2f bit times (limit 7.5)", max_resp_ns, max_resp_ns / TBIT);
        if (fails == 0) $display("PASS");
        else $display("FAIL: %0d failures", fails);
        $finish;
    end

    // Watchdog.
    initial begin
        #400_000_000;
        $display("FAIL: watchdog");
        $finish;
    end
endmodule
