// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Behavioral USB device for sim/usbh/tb_usbh.v, standing in for the real peripherals that the radio's USB host
// (rtl/usbh/, docs/USB_HOST.md) has to deal with: a full speed headset (KIND 0), a low speed boot mouse (KIND 1) or a low
// speed boot keyboard (KIND 2), each on its own clock (HALF is half its 48 MHz period in ns, so that the bench can
// make every device a little fast or slow). It models what such a device does on the wires and nothing more: it answers
// the control requests of enumeration, keeps its state (address, configuration, alternate settings), and sends or
// takes the data of its endpoints, and the bench switches faults on in it to see how the host copes. The terms
// used below (NRZI, SYNC, PID, CRC5, CRC16, endpoint, handshake, toggle) are explained in docs/learn/GLOSSARY.md, and the packet
// format in the header of sim/usb/tb_usb_audio.v.
//
// Line level: the full speed device uses rtl/usb/usb_fs_phy.v, the line interface of the radio's own USB device, which was
// tested against the independent bit level host model of sim/usb/tb_usb_audio.v, so the host under test meets a second
// implementation of NRZI, bit stuffing and timing. The low speed devices use rtl/usbh/usbh_phy.v with ls = 1 (the
// bench checks the low speed polarity and the keep-alive on the wires by itself). Tokens are checked with the
// CRC5 residual and data with the CRC16 residual, which is what a real device does.
//
// Endpoint 0 understands GET_DESCRIPTOR (device, configuration, HID report), SET_ADDRESS, SET_CONFIGURATION,
// SET_INTERFACE, SET_IDLE, SET_PROTOCOL, and the class request SET_CUR with 3 data bytes (the sampling
// frequency). Anything else is answered with a STALL. The other endpoints:
//   headset           endpoint 1 isochronous OUT (2 channels of 2 bytes, checking left = previous + 1 and right = ~left),
//                     endpoint 2 isochronous IN (1 channel of 2 bytes: a counter, one sample per 1,000 of its own clocks,
//                     which is 48 kHz from 48 MHz), endpoint 3 interrupt IN
//   mouse, keyboard   endpoint 1 interrupt IN, with reports from a queue (queue_report)
//
// Faults, set by the bench: nak_n (NAK the next n endpoint 0 transactions), stall_next (STALL the next request),
// mute (answer nothing), corrupt_n (damage the CRC of the next n data packets sent), deaf_ack_n (do not hear the
// next n ACKs, so that the packet is sent again), die_mid (stop driving in the middle of the next data packet),
// int_stall (STALL the interrupt endpoint).

`timescale 1ns / 1ps

module usbh_tb_dev #(
    parameter integer LS = 0,
    parameter real    HALF = 10.415,
    parameter integer KIND = 0,
    parameter integer MAXP0 = 8,
    parameter integer CFG_LEN = 34
) (
    inout wire dp,
    inout wire dn
);
    // Packet IDs of the tokens the device reacts to (USB 2.0 table 8-1).
    localparam [3:0] PID_OUT = 4'h1, PID_IN = 4'h9, PID_SOF = 4'h5, PID_SETUP = 4'hD;
    localparam integer INT_EP = (KIND == 0) ? 3 : 1;

    reg clk = 1'b0;
    always #(HALF) clk = ~clk;

    reg attached = 1'b0;
    wire dp_o, dn_o, oe;
    // The device pulls up the line that tells the host its speed when it is attached: D+ for full speed, D- for low speed.
    assign (pull1, highz0) dp = (attached && LS == 0) ? 1'b1 : 1'bz;
    assign (pull1, highz0) dn = (attached && LS != 0) ? 1'b1 : 1'bz;
    assign dp = oe ? dp_o : 1'bz;
    assign dn = oe ? dn_o : 1'bz;

    reg        phy_rst = 1'b0;
    wire       rx_active, rx_valid, rx_eop, rx_err, tx_ready, tx_busy;
    wire [7:0] rx_data;
    reg        tx_valid = 1'b0;
    reg  [7:0] tx_data = 8'd0;
    // The line interface: the host's PHY in low speed mode for the low speed devices, the device PHY for the full speed one.
    generate if (LS != 0) begin : g_ls
        usbh_phy u_phy (
            .clk(clk), .rst(!attached || phy_rst), .ls(1'b1), .dp_i(dp), .dn_i(dn),
            .dp_o(dp_o), .dn_o(dn_o), .oe(oe), .force_se0(1'b0), .force_k(1'b0), .eop_req(1'b0),
            .eop_slow(1'b0), .line_dp(), .line_dn(),
            .rx_active(rx_active), .rx_valid(rx_valid), .rx_data(rx_data), .rx_eop(rx_eop), .rx_err(rx_err),
            .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready), .tx_busy(tx_busy)
        );
    end else begin : g_fs
        usb_fs_phy u_phy (
            .clk(clk), .rst(!attached || phy_rst), .dp_i(dp), .dn_i(dn),
            .dp_o(dp_o), .dn_o(dn_o), .oe(oe), .bus_reset(), .line_se0(),
            .rx_active(rx_active), .rx_valid(rx_valid), .rx_data(rx_data), .rx_eop(rx_eop), .rx_err(rx_err),
            .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready), .tx_busy(tx_busy)
        );
    end endgenerate

    // One byte of the CRC-16 of USB data packets (reflected polynomial 0xA001).
    function [15:0] crc16_byte(input [15:0] c, input [7:0] d);
        integer i;
        reg [15:0] x;
        begin
            x = c ^ {8'h00, d};
            for (i = 0; i < 8; i = i + 1) x = x[0] ? ((x >> 1) ^ 16'hA001) : (x >> 1);
            crc16_byte = x;
        end
    endfunction
    // CRC-5 of a token over its 16 bits (11 bit address and endpoint field plus the 5 CRC bits), not inverted, so that a good
    // token leaves the residual 0x06.
    function [4:0] crc5_16(input [15:0] t);
        integer i;
        reg [4:0] c;
        begin
            c = 5'h1F;
            for (i = 0; i < 16; i = i + 1) c = (c[0] ^ t[i]) ? ((c >> 1) ^ 5'h14) : (c >> 1);
            crc5_16 = c;
        end
    endfunction

    // ---------------------------------------------------------------- descriptors
    // ---------------------------------------------------------------- descriptors
    reg [7:0] dev_desc [0:17];
    reg [7:0] cfg_desc [0:511];
    reg [7:0] rep_desc [0:63];
    integer   k;
    initial begin
        dev_desc[0] = 18; dev_desc[1] = 1; dev_desc[2] = 8'h10; dev_desc[3] = 8'h01;
        dev_desc[4] = 0; dev_desc[5] = 0; dev_desc[6] = 0; dev_desc[7] = MAXP0;
        dev_desc[8] = 8'h09 + KIND; dev_desc[9] = 8'h12; dev_desc[10] = 8'h34; dev_desc[11] = 8'h56;
        dev_desc[12] = 0; dev_desc[13] = 1; dev_desc[14] = 1; dev_desc[15] = 2; dev_desc[16] = 0;
        dev_desc[17] = 1;
        // The bench does not parse these (the firmware's USB stack has its own tests with real descriptor sets). The device
        // descriptor has made up IDs that differ by KIND, and the configuration is a header with the right total length followed by a pattern.
        for (k = 0; k < 512; k = k + 1) cfg_desc[k] = (k * 7 + KIND * 31 + 3) & 8'hFF;
        cfg_desc[0] = 9; cfg_desc[1] = 2; cfg_desc[2] = CFG_LEN & 8'hFF; cfg_desc[3] = CFG_LEN >> 8;
        for (k = 0; k < 64; k = k + 1) rep_desc[k] = (k * 5 + 1) & 8'hFF;
    end

    // ---------------------------------------------------------------- state and fault switches
    // ---------------------------------------------------------------- state and fault switches
    reg [6:0]  addr = 7'd0, pend_addr = 7'd0;
    reg        pend_addr_v = 1'b0;
    reg [7:0]  configured = 8'd0;
    reg [7:0]  alt1 = 8'd0, alt2 = 8'd0;
    reg [7:0]  protocol = 8'd1, idle = 8'hFF;
    reg [23:0] freq = 24'd0;
    integer    nak_n = 0, corrupt_n = 0, deaf_ack_n = 0;
    reg        stall_next = 1'b0, mute = 1'b0, die_mid = 1'b0, int_stall = 1'b0;
    integer    n_sof = 0, n_badtok = 0, n_reset = 0, n_setup = 0, n_tokens = 0;
    reg [10:0] last_frame = 11'd0;

    reg [7:0]  setup [0:7];
    integer    stage = 0;                  // 0 idle, 1 data IN, 2 status IN, 3 data OUT
    reg [7:0]  resp [0:511];
    integer    resp_len = 0, resp_pos = 0;
    reg        in_tog = 1'b0, ep0_stall = 1'b0, int_tog = 1'b0;

    // Interrupt reports: a queue of 16 reports (up to 8 bytes each, byte 0 in the low bits) for the mouse and keyboard.
    // interrupt reports
    reg [63:0] rq [0:15];
    integer    rq_len [0:15];
    integer    rq_w = 0, rq_r = 0, n_rep_acked = 0;
    task queue_report(input integer len, input [63:0] bytes);
        begin
            rq[rq_w % 16] = bytes;
            rq_len[rq_w % 16] = len;
            rq_w = rq_w + 1;
        end
    endtask

    // Speaker (what the host sent: counts, order errors, packet sizes, the first bytes of the last packet) and the microphone's sample clock.
    // speaker and microphone
    integer    spk_n = 0, spk_err = 0, spk_pkts = 0, spk_min = 999, spk_max = 0, spk_badcrc = 0;
    reg [15:0] spk_last = 16'd0;
    reg        spk_first = 1'b1;
    integer    spk_len = 0;
    reg [7:0]  spk_b1 = 8'd0, spk_b2 = 8'd0, spk_b3 = 8'd0;
    integer    mic_div = 0, mic_due = 0, mic_sent = 0, mic_pkts = 0;
    reg [15:0] mic_seq = 16'd0;
    // The microphone makes one sample due every 1,000 clocks (48 kHz) while its interface is switched on (alternate setting 1).
    always @(posedge clk) begin
        if (alt2 == 8'd1) begin
            if (mic_div == 999) begin mic_div <= 0; mic_due = mic_due + 1; end
            else mic_div <= mic_div + 1;
        end else begin
            mic_div <= 0; mic_due = 0;
        end
    end

    // Bus reset: SE0 held for 10 us (480 clocks of 48 MHz), which is longer than an EOP or a low speed keep-alive.
    // bus reset: SE0 for more than 2.5 us
    integer se0_n = 0;
    always @(posedge clk) begin
        if (attached && dp === 1'b0 && dn === 1'b0 && !oe) begin
            se0_n = se0_n + 1;
            if (se0_n == 480) begin              // 10 us: a reset, not an EOP or a keep-alive
                addr = 0; configured = 0; alt1 = 0; alt2 = 0; stage = 0; pend_addr_v = 0; int_tog = 0;
                protocol = 1; n_reset = n_reset + 1; spk_first = 1'b1;
            end
        end else se0_n = 0;
        if (!attached) begin
            addr = 0; configured = 0; alt1 = 0; alt2 = 0; stage = 0; pend_addr_v = 0; int_tog = 0;
            rq_r = rq_w; spk_first = 1'b1;
        end
    end

    // ---------------------------------------------------------------- packets
    // ---------------------------------------------------------------- packets
    reg [7:0] rb [0:1100];
    integer   rlen;
    reg       rerr, rnone;
    task recv(input integer maxwait);       // maxwait clocks for the packet to begin; 0 = for ever
        integer w;
        reg     done;
        begin
            rlen = 0; rerr = 1'b0; rnone = 1'b0; w = 0; done = 1'b0;
            while (!done) begin
                @(negedge clk);
                if (!attached) begin rnone = 1'b1; done = 1'b1; end
                else if (rx_valid) begin rb[rlen] = rx_data; rlen = rlen + 1; end
                else if (rx_eop) begin rerr = rx_err; done = 1'b1; end
                else if (rlen == 0 && !rx_active) begin
                    w = w + 1;
                    if (maxwait != 0 && w > maxwait) begin rnone = 1'b1; done = 1'b1; end
                end
            end
        end
    endtask

    reg [7:0] tb [0:1100];
    task send(input integer n, input integer cut);   // cut > 0: stop driving after that many bytes
        integer i;
        begin
            tx_data = tb[0]; tx_valid = 1'b1; i = 0;
            while (i < n && attached) begin
                @(negedge clk);
                if (tx_ready) begin
                    i = i + 1;
                    if (cut > 0 && i == cut) begin
                        tx_valid = 1'b0;
                        phy_rst = 1'b1;              // the device dies: the line floats back to idle
                        repeat (4) @(negedge clk);
                        phy_rst = 1'b0;
                        i = n;
                    end else if (i < n) tx_data = tb[i];
                    else tx_valid = 1'b0;
                end
            end
            tx_valid = 1'b0;
            while (tx_busy && attached) @(negedge clk);
        end
    endtask
    task send_hs(input [3:0] pid);
        begin
            if (!mute) begin tb[0] = {~pid, pid}; send(1, 0); end
        end
    endtask
    // A data packet of n bytes that are in tb[1 ..]: PID (DATA1 0x4B or DATA0 0xC3 with its complement), the bytes and the CRC-16,
    // damaged on purpose while corrupt_n is set, and cut off after 2 bytes when die_mid is set.
    // a data packet of n bytes that stand in tb[1 ..]
    task send_data(input tog, input integer n);
        integer i;
        reg [15:0] c;
        begin
            if (!mute) begin
                tb[0] = tog ? 8'h4B : 8'hC3;
                c = 16'hFFFF;
                for (i = 0; i < n; i = i + 1) c = crc16_byte(c, tb[1 + i]);
                c = ~c;
                if (corrupt_n > 0) begin c = c ^ 16'h0100; corrupt_n = corrupt_n - 1; end
                tb[1 + n] = c[7:0];
                tb[2 + n] = c[15:8];
                if (die_mid) begin die_mid = 1'b0; send(n + 3, 2); end
                else send(n + 3, 0);
            end
        end
    endtask
    // Checks a received data packet: PID with its complement, a DATA PID (low bits 011), and the CRC-16 residual 0xB001 over data and CRC.
    function data_ok(input integer n);
        integer i;
        reg [15:0] c;
        begin
            c = 16'hFFFF;
            for (i = 1; i < n; i = i + 1) c = crc16_byte(c, rb[i]);
            data_ok = (n >= 3) && (c == 16'hB001) && (rb[0][3:0] == ~rb[0][7:4]) && (rb[0][2:0] == 3'b011);
        end
    endfunction
    // Waits for the host's ACK (0xD2 = PID 2 with its complement). The wait limit is 150 clocks at full speed and 1200 at low speed, which is
    // 37.5 bit times at either speed (4 and 32 clocks a bit).
    // wait for the host's ACK
    task get_ack(output ok);
        begin
            recv(LS != 0 ? 1200 : 150);
            ok = !rnone && !rerr && rlen == 1 && rb[0] == 8'hD2;
            if (ok && deaf_ack_n > 0) begin deaf_ack_n = deaf_ack_n - 1; ok = 1'b0; end
        end
    endtask

    // ---------------------------------------------------------------- endpoint 0
    // ---------------------------------------------------------------- endpoint 0
    integer wlen, total, i2;
    reg     okf;
    // A control transfer's setup stage: takes the 8 byte setup packet, acknowledges it, and decides what the data and status stages
    // will be (a descriptor to send, an address to take at the end of the status stage, a configuration, and so on).
    task do_setup;
        begin
            recv(LS != 0 ? 1200 : 150);
            if (!rnone && !rerr && rlen == 11 && data_ok(rlen) && rb[0] == 8'hC3) begin
                for (i2 = 0; i2 < 8; i2 = i2 + 1) setup[i2] = rb[1 + i2];
                n_setup = n_setup + 1;
                send_hs(4'h2);
                ep0_stall = 1'b0; stage = 0; in_tog = 1'b1; resp_pos = 0; resp_len = 0;
                wlen = {setup[7], setup[6]};
                total = -1;
                if (stall_next) begin
                    stall_next = 1'b0; ep0_stall = 1'b1;
                end else if (setup[1] == 8'd6 && (setup[0] == 8'h80 || setup[0] == 8'h81)) begin
                    if (setup[3] == 8'd1) begin
                        total = 18; for (i2 = 0; i2 < 18; i2 = i2 + 1) resp[i2] = dev_desc[i2];
                    end else if (setup[3] == 8'd2) begin
                        total = CFG_LEN; for (i2 = 0; i2 < CFG_LEN; i2 = i2 + 1) resp[i2] = cfg_desc[i2];
                    end else if (setup[3] == 8'h22 && KIND != 0) begin
                        total = 52; for (i2 = 0; i2 < 52; i2 = i2 + 1) resp[i2] = rep_desc[i2];
                    end
                    if (total < 0) ep0_stall = 1'b1;
                    else begin resp_len = (wlen < total) ? wlen : total; stage = 1; end
                end else if (setup[0] == 8'h00 && setup[1] == 8'd5) begin
                    pend_addr = setup[2][6:0]; pend_addr_v = 1'b1; stage = 2;
                end else if (setup[0] == 8'h00 && setup[1] == 8'd9) begin
                    configured = setup[2]; stage = 2;
                end else if (setup[0] == 8'h01 && setup[1] == 8'd11) begin
                    if (setup[4] == 8'd1) alt1 = setup[2]; else alt2 = setup[2];
                    stage = 2;
                end else if (setup[0] == 8'h21 && setup[1] == 8'h0A) begin
                    idle = setup[3]; stage = 2;
                end else if (setup[0] == 8'h21 && setup[1] == 8'h0B) begin
                    protocol = setup[2]; stage = 2;
                end else if (setup[0] == 8'h22 && setup[1] == 8'h01 && wlen == 3) begin
                    stage = 3;
                end else begin
                    ep0_stall = 1'b1;
                end
            end
        end
    endtask

    integer chunk;
    // IN on endpoint 0: the data stage (the descriptor in chunks of at most MAXP0 bytes with toggling DATA1 and DATA0, moving on only
    // when the host's ACK was heard) or the status stage (a zero length DATA1, after which a new address takes effect).
    task ep0_in;
        begin
            if (ep0_stall) send_hs(4'hE);
            else if (nak_n > 0) begin nak_n = nak_n - 1; send_hs(4'hA); end
            else if (stage == 1) begin
                chunk = resp_len - resp_pos;
                if (chunk > MAXP0) chunk = MAXP0;
                for (i2 = 0; i2 < chunk; i2 = i2 + 1) tb[1 + i2] = resp[resp_pos + i2];
                send_data(in_tog, chunk);
                get_ack(okf);
                if (okf) begin resp_pos = resp_pos + chunk; in_tog = ~in_tog; end
            end else if (stage == 2) begin
                send_data(1'b1, 0);
                get_ack(okf);
                if (okf) begin
                    if (pend_addr_v) begin addr = pend_addr; pend_addr_v = 1'b0; end
                    stage = 0;
                end
            end else send_hs(4'hA);
        end
    endtask
    // OUT on endpoint 0: the data stage of SET_CUR (3 bytes, the sampling frequency), or the status stage of a read.
    task ep0_out;
        begin
            recv(LS != 0 ? 1200 : 150);
            if (!rnone && !rerr && data_ok(rlen)) begin
                if (ep0_stall) send_hs(4'hE);
                else if (nak_n > 0) begin nak_n = nak_n - 1; send_hs(4'hA); end
                else begin
                    if (stage == 3 && rlen == 6) begin
                        freq = {rb[3], rb[2], rb[1]};
                        stage = 2;
                    end else if (stage == 1) stage = 0;      // the status stage of a read
                    send_hs(4'h2);
                end
            end
        end
    endtask

    // ---------------------------------------------------------------- the other endpoints
    // ---------------------------------------------------------------- the other endpoints
    integer nb, ns;
    reg [15:0] sl, sr;
    // Interrupt IN: sends the next queued report (and drops it from the queue only when the host's ACK was heard), or NAKs when there is none.
    task int_in;
        begin
            if (int_stall) send_hs(4'hE);
            else if (rq_r != rq_w) begin
                nb = rq_len[rq_r % 16];
                for (i2 = 0; i2 < nb; i2 = i2 + 1) tb[1 + i2] = rq[rq_r % 16][8 * i2 +: 8];
                send_data(int_tog, nb);
                get_ack(okf);
                if (okf) begin rq_r = rq_r + 1; int_tog = ~int_tog; n_rep_acked = n_rep_acked + 1; end
            end else send_hs(4'hA);
        end
    endtask
    // Microphone IN: sends the samples that are due (at most 50 in a packet) as a counter, one 16 bit word each. When a packet is
    // damaged on purpose its samples are said again in the next one, so the bench can tell that nothing may be lost.
    task mic_in;
        begin
            ns = mic_due;
            if (ns > 50) ns = 50;
            mic_due = mic_due - ns;
            for (i2 = 0; i2 < ns; i2 = i2 + 1) begin
                tb[1 + 2 * i2] = mic_seq[7:0];
                tb[2 + 2 * i2] = mic_seq[15:8];
                mic_seq = mic_seq + 16'd1;
            end
            if (corrupt_n > 0) mic_seq = mic_seq - ns;       // a damaged packet's samples are lost: say them again
            mic_sent = mic_sent + ((corrupt_n > 0) ? 0 : ns);
            if (corrupt_n > 0) mic_due = mic_due + ns;
            mic_pkts = mic_pkts + 1;
            send_data(1'b0, 2 * ns);
        end
    endtask
    // Speaker OUT: checks and counts what the host sends: the number of stereo samples, left counting up by one and right = ~left, and
    // keeps the byte count and first bytes of the last packet. A bad packet is counted and no handshake is given (isochronous).
    task spk_out;
        begin
            recv(150);
            if (!rnone && !rerr && data_ok(rlen)) begin
                spk_len = rlen; spk_b1 = rb[1]; spk_b2 = rb[2]; spk_b3 = rb[3];
                ns = (rlen - 3) / 4;
                spk_pkts = spk_pkts + 1;
                if (ns < spk_min) spk_min = ns;
                if (ns > spk_max) spk_max = ns;
                for (i2 = 0; i2 < ns; i2 = i2 + 1) begin
                    sl = {rb[2 + 4 * i2], rb[1 + 4 * i2]};
                    sr = {rb[4 + 4 * i2], rb[3 + 4 * i2]};
                    if (!spk_first && sl != spk_last + 16'd1) spk_err = spk_err + 1;
                    if (sr != ~sl) spk_err = spk_err + 1;
                    spk_last = sl; spk_first = 1'b0;
                    spk_n = spk_n + 1;
                end
            end else spk_badcrc = spk_badcrc + 1;
        end
    endtask

    // ---------------------------------------------------------------- main loop
    // Waits for a token, checks its PID and CRC-5 (the good residual is 0x06), and then handles it if it is an SOF (counted, with its frame
    // number) or addressed to this device (the endpoint picks the task above).
    // ---------------------------------------------------------------- main loop
    reg [15:0] tokv;
    reg [3:0]  pid, ep;
    initial forever begin
        if (!attached) begin
            tx_valid = 1'b0;
            @(posedge attached);
        end
        recv(0);
        if (!rnone && !rerr && rlen == 3 && rb[0][3:0] == ~rb[0][7:4]) begin
            pid  = rb[0][3:0];
            tokv = {rb[2], rb[1]};
            if (crc5_16(tokv) != 5'h06) n_badtok = n_badtok + 1;
            else if (pid == PID_SOF) begin
                n_sof = n_sof + 1;
                last_frame = tokv[10:0];
            end else if (tokv[6:0] == addr && (pid == PID_SETUP || pid == PID_OUT || pid == PID_IN)) begin
                ep = tokv[10:7];
                n_tokens = n_tokens + 1;
                if (pid == PID_SETUP && ep == 4'd0) do_setup;
                else if (ep == 4'd0 && pid == PID_IN) ep0_in;
                else if (ep == 4'd0 && pid == PID_OUT) ep0_out;
                else if (configured != 8'd0 && ep == INT_EP && pid == PID_IN) int_in;
                else if (KIND == 0 && alt2 == 8'd1 && ep == 4'd2 && pid == PID_IN) mic_in;
                else if (KIND == 0 && alt1 == 8'd1 && ep == 4'd1 && pid == PID_OUT) spk_out;
            end
        end
    end

endmodule
