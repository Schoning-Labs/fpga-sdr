// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Testbench for the radio's USB host, rtl/usbh/usbh_top.v (docs/USB_HOST.md): two ports that talk full speed and low speed USB to
// peripherals such as a headset, a mouse or a keyboard, with a register page through which the firmware drives everything. The
// terms used below (enumeration, endpoint, NAK, STALL, toggle, SOF, NRZI) are explained in docs/learn/GLOSSARY.md, and the packet
// format in the header of sim/usb/tb_usb_audio.v.
//
// The devices are the behavioral models of usbh_tb_dev.v: a full speed headset on port 0, and a low speed mouse and then a low
// speed keyboard on port 1 (both can sit on the same socket, one after the other, as the bench swaps them with `kbd_sel`). The bench
// plays the part of the firmware through the register page, in eight stages: registers and empty sockets, plugging in (the speed
// shows in which line goes high, and a plug that sits the other way up exchanges D+ and D-), enumeration of every device, faults
// of the control transfers, interrupt reports from the mouse while the headset streams, 100 ms of audio in both directions, unplugging
// and plugging in, and suspend and resume. Every check prints "ok" or "FAIL" with its text, a task that waits has a limit and
// "HANG" is a failure, and the run ends with "tb_usbh: PASS", or "tb_usbh: FAIL" (also after the time limit of 2 s of simulated time).
//
// Run, from the repo root (the include paths are relative to it):
//   iverilog -g2012 -o build/tb_usbh.vvp sim/usbh/tb_usbh.v && vvp build/tb_usbh.vvp
//
// Clocks: clk_dsp has a period of 8.332 ns (120 MHz) and clk_usb 20.830 ns (48 MHz), exactly 2.5 : 1 as from the one PLL. The devices
// run off their own clocks, the headset 480 ppm fast, the mouse 1.1 % fast and the keyboard 1 % slow (full speed allows 0.25 %
// and low speed 1.5 %), which makes the host's clock recovery work. The radio's stream is a counter at clk_dsp / 2,500 = 48 kHz. The
// resets are 1 ms here, not the firmware's 50 ms.

`timescale 1ns / 1ps
`include "rtl/usb/usb_fs_phy.v"
`include "rtl/usb/usb_afifo.v"
`include "rtl/usbh/usbh_phy.v"
`include "rtl/usbh/usbh_port.v"
`include "rtl/usbh/usbh_iso_out.v"
`include "rtl/usbh/usbh_iso_in.v"
`include "rtl/usbh/usbh_regs.v"
`include "rtl/usbh/usbh_top.v"
`include "sim/usbh/usbh_tb_dev.v"

module tb_usbh;
    reg clk_dsp = 1'b0, clk_usb = 1'b0, rst = 1'b1;
    always #4.166 clk_dsp = ~clk_dsp;
    always #10.415 clk_usb = ~clk_usb;

    // ---------------------------------------------------------------- wires, pull-downs, the swap of the plug
    // dp and dn are the lines at the two sockets. The FPGA has one pin per line on the dock's odd row (a) and one on the even row (b),
    // and the board can sit either way up, which exchanges the rows. The four switches (tranif1) connect a to dn and b to dp
    // in the normal case and a to dp and b to dn with `plug_swapped`. The pins have weak pull-downs.
    // ---------------------------------------------------------------- wires, pull-downs, the swap of the plug
    wire [1:0] dp, dn;                   // the sockets
    reg        plug_swapped = 1'b0;      // the board sits the other way up: rows a and b change places
    wire [1:0] a_o, b_o, oe;
    wire [1:0] a_pin, b_pin;             // the FPGA pins: a = odd row, b = even row
    genvar g;
    generate for (g = 0; g < 2; g = g + 1) begin : w
        assign a_pin[g] = oe[g] ? a_o[g] : 1'bz;
        assign b_pin[g] = oe[g] ? b_o[g] : 1'bz;
        assign (weak0, highz1) a_pin[g] = 1'b0;       // the pins' pull-downs
        assign (weak0, highz1) b_pin[g] = 1'b0;
        tranif1 t0 (a_pin[g], dn[g], !plug_swapped);
        tranif1 t1 (b_pin[g], dp[g], !plug_swapped);
        tranif1 t2 (a_pin[g], dp[g], plug_swapped);
        tranif1 t3 (b_pin[g], dn[g], plug_swapped);
    end endgenerate

    usbh_tb_dev #(.LS(0), .HALF(10.410), .KIND(0), .MAXP0(64), .CFG_LEN(197)) headset (.dp(dp[0]), .dn(dn[0]));
    wire m_dp, m_dn, k_dp, k_dn;
    reg  kbd_sel = 1'b0;
    tranif1 tm0 (dp[1], m_dp, !kbd_sel);
    tranif1 tm1 (dn[1], m_dn, !kbd_sel);
    tranif1 tk0 (dp[1], k_dp, kbd_sel);
    tranif1 tk1 (dn[1], k_dn, kbd_sel);
    usbh_tb_dev #(.LS(1), .HALF(10.300), .KIND(1), .MAXP0(8), .CFG_LEN(34)) mouse (.dp(m_dp), .dn(m_dn));
    usbh_tb_dev #(.LS(1), .HALF(10.520), .KIND(2), .MAXP0(8), .CFG_LEN(59)) kbd (.dp(k_dp), .dn(k_dn));

    // ---------------------------------------------------------------- the unit, the radio's stream
    // The register bus of the firmware side and the radio's 48 kHz stream: s_cnt counts up with the right channel its complement.
    // ---------------------------------------------------------------- the unit, the radio's stream
    reg         b_wr = 1'b0, b_rd = 1'b0;
    reg  [15:0] b_addr = 16'd0;
    reg  [31:0] b_wdata = 32'd0;
    wire [31:0] b_rdata;
    wire        irq, m_v;
    wire signed [15:0] m_l, m_r;
    reg         s_v = 1'b0;
    reg  [15:0] s_cnt = 16'd0;
    integer     s_div = 0;
    always @(posedge clk_dsp) begin
        s_v <= 1'b0;
        if (s_div == 2499) begin s_div <= 0; s_v <= 1'b1; s_cnt <= s_cnt + 16'd1; end
        else s_div <= s_div + 1;
    end
    usbh_top dut (
        .clk_usb(clk_usb), .clk_dsp(clk_dsp), .rst_dsp(rst),
        .a_i(a_pin), .b_i(b_pin), .a_o(a_o), .b_o(b_o), .oe(oe),
        .bus_wr(b_wr), .bus_rd(b_rd), .bus_addr(b_addr), .bus_wdata(b_wdata), .bus_rdata(b_rdata), .irq(irq),
        .s_v(s_v), .s_l(s_cnt), .s_r(~s_cnt), .m_v(m_v), .m_l(m_l), .m_r(m_r)
    );

    // Microphone samples as the radio gets them: they must be a counter that goes up by one, with both channels equal (the microphone
    // is mono), and no gap.
    // microphone samples as the radio gets them: a counter, both channels equal
    integer    mic_n = 0, mic_err = 0;
    reg [15:0] mic_last = 16'd0;
    reg        mic_first = 1'b1;
    always @(posedge clk_dsp) if (m_v) begin
        if (!mic_first && m_l != mic_last + 16'd1) mic_err = mic_err + 1;
        if (m_l != m_r) mic_err = mic_err + 1;
        mic_last = m_l; mic_first = 1'b0; mic_n = mic_n + 1;
    end

    // The width of every SE0 the host drives on port 1, to check the low speed keep-alive (two low speed bit times).
    // what the host puts on port 1's wires while it drives: the width of each SE0 (keep-alive: 2 low-speed bits)
    realtime se0_t0 = 0, se0_w = 0;
    integer  n_se0_p1 = 0;
    reg      se0_q = 1'b0;
    wire     se0_p1 = oe[1] && dp[1] === 1'b0 && dn[1] === 1'b0;
    always @(posedge clk_usb) begin
        se0_q <= se0_p1;
        if (se0_p1 && !se0_q) se0_t0 = $realtime;
        if (!se0_p1 && se0_q) begin se0_w = $realtime - se0_t0; n_se0_p1 = n_se0_p1 + 1; end
    end
    // Host activity per port (number of times it turned its driver on), to see that a port has stopped.
    // host activity per port (for "the port has stopped")
    integer n_oe0 = 0, n_oe1 = 0;
    always @(posedge oe[0]) n_oe0 = n_oe0 + 1;
    always @(posedge oe[1]) n_oe1 = n_oe1 + 1;

    // ---------------------------------------------------------------- bookkeeping
    // Counts a check and prints "ok" or "FAIL" with its text.
    // ---------------------------------------------------------------- bookkeeping
    integer fails = 0, checks = 0;
    task check(input cond, input [8*64-1:0] what);
        begin
            checks = checks + 1;
            if (!cond) begin fails = fails + 1; $display("FAIL  %0s  (t = %0t)", what, $time); end
            else $display("ok    %0s", what);
        end
    endtask

    // ---------------------------------------------------------------- the firmware's side
    // A register write is a strobe for one clock followed by four idle clocks, and a read is a strobe and then six clocks until the
    // answer is taken. The register page has global registers (0x0000 ID, 0x0004 control with bit 0 = swap and bit 8 = interrupt on a
    // record, 0x0010 speaker, 0x0014 microphone, 0x0018 fault counters, 0x001C microphone sample count) and a page per port.
    // ---------------------------------------------------------------- the firmware's side
    task bus_wr(input [15:0] a, input [31:0] d);
        begin
            @(posedge clk_dsp); #1 b_addr = a; b_wdata = d; b_wr = 1'b1;
            @(posedge clk_dsp); #1 b_wr = 1'b0;
            repeat (4) @(posedge clk_dsp);
        end
    endtask
    task bus_rd(input [15:0] a, output [31:0] d);
        begin
            @(posedge clk_dsp); #1 b_addr = a; b_rd = 1'b1;
            @(posedge clk_dsp); #1 b_rd = 1'b0;
            repeat (6) @(posedge clk_dsp);
            d = b_rdata;
        end
    endtask
    // Address of a register in the page of port p (bit 8 for port 0, bit 9 for port 1): 0x00 port mode, 0x04 status, 0x08 transaction
    // command, 0x0C receive FIFO, 0x10 interrupt slot, 0x40 and 0x44 send buffer.
    function [15:0] pa(input integer p, input [7:0] lo);
        pa = {7'd0, (p == 1), (p == 0), lo};
    endfunction
    // Waits n milliseconds of simulated time.
    task wait_ms(input integer n);
        begin repeat (n) #1000000; end
    endtask

    reg [31:0] rv;
    reg [2:0]  res;
    // One transaction on port p: `kind` 0 = SETUP, 1 = OUT, 2 = IN, with the endpoint, the data toggle, the length and the NAK limit
    // (in frames) written to the transaction register. The status register is then polled every 20 us (up to 20,000 times) until it
    // is no longer busy. `res` is the result: 0 = it never finished, 1 = done (ACK or data), 2 = NAK limit reached, 3 = STALL,
    // 4 = no answer three times, 5 = damaged three times, 6 = the port is off or empty.
    // one transaction; res = result code, 0 = it never finished
    task xact(input integer p, input [1:0] kind, input [3:0] ep, input tog, input [6:0] len, input [7:0] nak);
        integer n;
        begin
            bus_wr(pa(p, 8'h08), {8'd0, nak, 2'd0, len, tog, ep, kind});
            n = 0; rv = 32'h8;
            while (rv[3] && n < 20000) begin
                #20000;
                bus_rd(pa(p, 8'h04), rv);
                n = n + 1;
            end
            res = rv[3] ? 3'd0 : rv[6:4];
            if (rv[3]) begin fails = fails + 1; $display("FAIL  HANG: a transaction did not finish"); end
        end
    endtask
    // Takes one record out of the receive FIFO of port p (words with a valid flag in bit 31; bytes of the record, then a marker word
    // that says where it came from: 0 = a control transfer, 1 = interrupt slot 0). `rlen` is its length, and -1 means nothing is there.
    // one record out of the receive FIFO; rlen = -1: nothing there
    reg [7:0] rec [0:127];
    integer   rlen, rsrc;
    task pop_rec(input integer p);
        integer n;
        reg     done;
        begin
            rlen = 0; rsrc = -1; done = 1'b0; n = 0;
            while (!done && n < 200) begin
                bus_rd(pa(p, 8'h0C), rv);
                n = n + 1;
                if (!rv[31]) begin rlen = -1; done = 1'b1; end
                else if (rv[8]) begin rsrc = rv[1:0]; done = 1'b1; end
                else begin rec[rlen] = rv[7:0]; rlen = rlen + 1; end
            end
        end
    endtask
    task put_setup(input integer p, input [63:0] s);      // s: byte 0 in bits 7:0
        begin
            bus_wr(pa(p, 8'h40), s[31:0]);
            bus_wr(pa(p, 8'h44), s[63:32]);
        end
    endtask
    // Control read: the data ends up in cbuf and clen. A setup stage, then IN transactions with alternating toggle until a short packet
    // or the requested length, then a zero length DATA1 as the status stage. cres = 1 when all three stages were done.
    // control read: the data ends up in cbuf, clen bytes; cres = 1 when all three stages were done
    reg [7:0] cbuf [0:511];
    integer   clen;
    reg [2:0] cres;
    task ctrl_in(input integer p, input [63:0] s, input integer maxp);
        integer want, i;
        reg     tog, fin;
        begin
            want = s[63:48]; clen = 0; tog = 1'b1; fin = 1'b0;
            put_setup(p, s);
            xact(p, 2'd0, 4'd0, 1'b0, 7'd8, 8'd50);
            cres = res;
            while (cres == 3'd1 && !fin) begin
                xact(p, 2'd2, 4'd0, tog, 7'd0, 8'd200);
                cres = res;
                if (res == 3'd1) begin
                    pop_rec(p);
                    if (rsrc != 0) begin cres = 3'd7; end
                    for (i = 0; i < rlen; i = i + 1) cbuf[clen + i] = rec[i];
                    clen = clen + rlen;
                    tog = ~tog;
                    if (rlen < maxp || clen >= want) fin = 1'b1;
                end
            end
            if (cres == 3'd1) begin
                xact(p, 2'd1, 4'd0, 1'b1, 7'd0, 8'd50);       // status: a zero-length DATA1
                cres = res;
            end
        end
    endtask
    // Control write without data, or with up to 4 bytes of data (a SET_CUR payload), then the status stage, an IN that must give nothing.
    // control write without data, or with up to 4 bytes of data
    task ctrl_out(input integer p, input [63:0] s, input integer dlen, input [31:0] data);
        begin
            put_setup(p, s);
            xact(p, 2'd0, 4'd0, 1'b0, 7'd8, 8'd50);
            cres = res;
            if (cres == 3'd1 && dlen > 0) begin
                bus_wr(pa(p, 8'h40), data);
                xact(p, 2'd1, 4'd0, 1'b1, dlen[6:0], 8'd50);
                cres = res;
            end
            if (cres == 3'd1) begin
                xact(p, 2'd2, 4'd0, 1'b1, 7'd0, 8'd50);       // status: a zero-length DATA1 from the device
                cres = res;
                if (res == 3'd1) begin
                    pop_rec(p);
                    if (rsrc != 0 || rlen != 0) cres = 3'd7;
                end
            end
        end
    endtask
    // Setup packet: request type, request, value, index, length, byte 0 in the low bits.
    function [63:0] setup8(input [7:0] bm, input [7:0] req, input [15:0] val, input [15:0] idx, input [15:0] len);
        setup8 = {len, idx, val, req, bm};
    endfunction

    // Resets a port and brings its device to "configured" at address `a`, checking every step (`ok`): reset and run at address 0, read
    // the first 8 bytes of the device descriptor (length 18 and the endpoint 0 size), SET_ADDRESS, then the full device descriptor, the
    // configuration descriptor with its pattern, and SET_CONFIGURATION 1.
    // reset a port and bring its device to "configured" at address `a`; ok = every step was right
    reg ok;
    integer i, j;
    task enumerate(input integer p, input low, input [6:0] a, input integer maxp, input integer cfglen);
        begin
            ok = 1'b1;
            bus_wr(pa(p, 8'h00), {21'd0, 7'd0, low, 3'd1});      // reset
            wait_ms(1);
            bus_wr(pa(p, 8'h00), {21'd0, 7'd0, low, 3'd2});      // run, address 0
            wait_ms(2);
            ctrl_in(p, setup8(8'h80, 8'd6, 16'h0100, 16'd0, 16'd8), maxp);
            if (cres != 3'd1 || clen != 8 || cbuf[0] != 8'd18 || cbuf[7] != maxp) ok = 1'b0;
            ctrl_out(p, setup8(8'h00, 8'd5, {9'd0, a}, 16'd0, 16'd0), 0, 32'd0);
            if (cres != 3'd1) ok = 1'b0;
            bus_wr(pa(p, 8'h00), {21'd0, a, low, 3'd2});
            wait_ms(2);
            ctrl_in(p, setup8(8'h80, 8'd6, 16'h0100, 16'd0, 16'd18), maxp);
            if (cres != 3'd1 || clen != 18 || cbuf[8] != 8'h09 + p[7:0] + (cfglen == 59 ? 8'd1 : 8'd0)) ok = 1'b0;
            ctrl_in(p, setup8(8'h80, 8'd6, 16'h0200, 16'd0, cfglen[15:0]), maxp);
            if (cres != 3'd1 || clen != cfglen) ok = 1'b0;
            for (i = 4; i < cfglen; i = i + 1)
                if (cbuf[i] != ((i * 7 + (cfglen == 197 ? 0 : cfglen == 34 ? 1 : 2) * 31 + 3) & 8'hFF)) ok = 1'b0;
            ctrl_out(p, setup8(8'h00, 8'd9, 16'd1, 16'd0, 16'd0), 0, 32'd0);
            if (cres != 3'd1) ok = 1'b0;
        end
    endtask

    integer n0, n1, n2, t0;
    reg [31:0] c0, c1;
    initial begin
        $display("tb_usbh: USB host, two ports");
        repeat (20) @(posedge clk_dsp);
        rst = 1'b0;
        wait_ms(1);

        // ---- 1. registers, empty sockets
        // The ID register reads 0x55480001, the speaker setting resets to 48 samples a frame (0x3000, 48 in bits 13:8), an empty port shows both lines
        // low, and a transaction on a port that is off ends with result 6.
        // ---- 1. registers, empty sockets
        bus_rd(16'h0000, rv);            check(rv == 32'h55480001, "id");
        bus_rd(16'h0010, rv);            check(rv == 32'h00003000, "spk resets to 48 samples a frame");
        bus_rd(pa(0, 8'h04), rv);        check(rv[2:0] == 3'd0, "port 0 empty: both lines low");
        bus_rd(pa(1, 8'h04), rv);        check(rv[2:0] == 3'd0, "port 1 empty: both lines low");
        xact(0, 2'd2, 4'd0, 1'b0, 7'd0, 8'd3);
        check(res == 3'd6, "a transaction on a port that is off ends with result 6");

        // ---- 2. plug in: which line goes high says the speed; the plug the other way up
        // A full speed device pulls D+ up and a low speed one pulls D- up, so the host reads the speed from the line that went high, with a line event
        // flag that the read clears. A plug that sits the other way up exchanges the lines, so the headset looks low speed until ctrl.swap is set.
        // ---- 2. plug in: which line goes high says the speed; the plug the other way up
        headset.attached = 1'b1;
        mouse.attached = 1'b1;
        wait_ms(2);
        bus_rd(pa(0, 8'h04), rv);        check(rv[1:0] == 2'b01 && rv[8], "headset: D+ high, line event");
        bus_rd(pa(1, 8'h04), rv);        check(rv[1:0] == 2'b10 && rv[8], "mouse: D- high, line event");
        bus_rd(pa(1, 8'h04), rv);        check(!rv[8], "the line event is cleared by the read");
        plug_swapped = 1'b1;
        wait_ms(2);
        bus_rd(pa(0, 8'h04), rv);        check(rv[1:0] == 2'b10, "plug the other way up: the headset looks low speed");
        bus_wr(16'h0004, 32'h0000_0001);
        wait_ms(2);
        bus_rd(pa(0, 8'h04), rv);        check(rv[1:0] == 2'b01, "ctrl.swap puts it right");

        // ---- 3. enumeration, both ports, with the swapped plug
        // ---- 3. enumeration, both ports, with the swapped plug
        enumerate(0, 1'b0, 7'd5, 64, 197);
        check(ok, "headset enumerated (full speed, 64-byte endpoint 0, 197-byte configuration)");
        check(headset.addr == 7'd5 && headset.configured == 8'd1, "headset has address 5 and is configured");
        enumerate(1, 1'b1, 7'd9, 8, 34);
        check(ok, "mouse enumerated (low speed, 8-byte endpoint 0)");
        check(mouse.addr == 7'd9 && mouse.configured == 8'd1, "mouse has address 9 and is configured");
        check(headset.n_badtok == 0 && mouse.n_badtok == 0, "every token had a good CRC5 (device's residual check)");
        // Two low speed bit times at 1.5 Mbit/s are 2 * 666.7 ns = 1333 ns.
        check(se0_w > 1300.0 && se0_w < 1370.0, "low-speed keep-alive: SE0 for two low-speed bit times");
        n0 = headset.n_sof; t0 = headset.last_frame;
        wait_ms(10);
        check(headset.n_sof - n0 >= 9 && headset.n_sof - n0 <= 11, "one SOF per ms at the headset");
        check(((headset.last_frame - t0) & 11'h7FF) == headset.n_sof - n0, "frame numbers count up");
        plug_swapped = 1'b0;
        bus_wr(16'h0004, 32'h0000_0000);

        // ---- 4. control transfer faults (mouse, low speed)
        // NAKs that end (3), NAKs for ever (given up after the NAK limit, result 2), a STALL (3), no answer (4), a damaged packet that is asked
        // for again (ok) and one damaged three times (5), a device that did not hear our ACK and repeats the packet (dropped by its toggle), and a
        // device that stops half way through a packet. After each of these the port must work again.
        // ---- 4. control transfer faults (mouse, low speed)
        mouse.nak_n = 3;
        ctrl_in(1, setup8(8'h81, 8'd6, 16'h2200, 16'd0, 16'd52), 8);
        check(cres == 3'd1 && clen == 52 && cbuf[51] == 8'd0, "3 NAKs, then the 52-byte report descriptor");
        mouse.nak_n = 1000;
        put_setup(1, setup8(8'h80, 8'd6, 16'h0100, 16'd0, 16'd18));
        xact(1, 2'd0, 4'd0, 1'b0, 7'd8, 8'd50);
        xact(1, 2'd2, 4'd0, 1'b1, 7'd0, 8'd5);
        check(res == 3'd2, "NAK for ever: given up after nak_limit frames (result 2)");
        mouse.nak_n = 0;
        mouse.stall_next = 1'b1;
        ctrl_in(1, setup8(8'h80, 8'd6, 16'h0300, 16'd0, 16'd4), 8);
        check(cres == 3'd3, "STALL is reported (result 3)");
        ctrl_in(1, setup8(8'h80, 8'd6, 16'h0100, 16'd0, 16'd18), 8);
        check(cres == 3'd1 && clen == 18, "the next request works again");
        mouse.mute = 1'b1;
        put_setup(1, setup8(8'h80, 8'd6, 16'h0100, 16'd0, 16'd18));
        xact(1, 2'd0, 4'd0, 1'b0, 7'd8, 8'd50);
        check(res == 3'd4, "no answer three times: result 4");
        mouse.mute = 1'b0;
        mouse.corrupt_n = 1;
        ctrl_in(1, setup8(8'h80, 8'd6, 16'h0100, 16'd0, 16'd18), 8);
        check(cres == 3'd1 && clen == 18 && cbuf[17] == 8'd1, "one damaged packet: asked again, data right");
        mouse.corrupt_n = 3;
        put_setup(1, setup8(8'h80, 8'd6, 16'h0100, 16'd0, 16'd18));
        xact(1, 2'd0, 4'd0, 1'b0, 7'd8, 8'd50);
        xact(1, 2'd2, 4'd0, 1'b1, 7'd0, 8'd50);
        check(res == 3'd5, "damaged three times: result 5");
        pop_rec(1);
        check(rlen == -1, "nothing of a damaged packet reached the receive FIFO");
        mouse.deaf_ack_n = 1;
        ctrl_in(1, setup8(8'h80, 8'd6, 16'h0200, 16'd0, 16'd34), 8);
        check(cres == 3'd1 && clen == 34, "device missed our ACK: its repeat is acknowledged and dropped");
        mouse.die_mid = 1'b1;
        put_setup(1, setup8(8'h80, 8'd6, 16'h0100, 16'd0, 16'd18));
        xact(1, 2'd0, 4'd0, 1'b0, 7'd8, 8'd50);
        xact(1, 2'd2, 4'd0, 1'b1, 7'd0, 8'd50);
        check(res == 3'd1 || res == 3'd5, "a packet that stops half way does not hang the port");
        if (res == 3'd1) pop_rec(1);              // the second try brought the data: take it out
        ctrl_in(1, setup8(8'h80, 8'd6, 16'h0100, 16'd0, 16'd18), 8);
        check(cres == 3'd1 && clen == 18, "and the port works afterwards");

        // ---- 5. mouse reports through interrupt slot 0, while the headset streams
        // The headset's speaker and microphone interfaces are switched on and set to 48 kHz, the speaker, microphone and mouse slots are configured
        // (the mouse is polled every 4 ms), and the mouse's queued reports must arrive once each, in order, even when the first is damaged once
        // and when the device did not hear the host's ACK.
        // ---- 5. mouse reports through interrupt slot 0, while the headset streams
        ctrl_out(0, setup8(8'h01, 8'd11, 16'd1, 16'd1, 16'd0), 0, 32'd0);        // speaker interface on
        ctrl_out(0, setup8(8'h22, 8'h01, 16'h0100, 16'h0001, 16'd3), 3, 32'h0000BB80);
        check(cres == 3'd1 && headset.freq == 24'd48000, "SET_CUR sampling frequency 48,000 (data stage OUT)");
        ctrl_out(0, setup8(8'h01, 8'd11, 16'd1, 16'd2, 16'd0), 0, 32'd0);        // microphone interface on
        check(cres == 3'd1 && headset.alt1 == 8'd1 && headset.alt2 == 8'd1, "both streaming interfaces on");
        bus_wr(16'h0010, {18'd0, 6'd48, 1'b0, 1'b0, 4'd1, 1'b0, 1'b1});          // speaker: port 0, endpoint 1
        bus_wr(16'h0014, {24'd0, 1'b0, 1'b1, 4'd2, 1'b0, 1'b1});                 // microphone: endpoint 2, mono
        bus_wr(pa(1, 8'h10), {19'd0, 8'd4, 4'd1, 1'b1});                          // mouse: endpoint 1 every 4 ms
        bus_wr(16'h0004, 32'h0000_0100);                                         // interrupt on a record
        wait_ms(12);
        check(!irq, "no report, no interrupt (the mouse answers NAK)");
        mouse.queue_report(4, 64'h0000_0000_00FE_0501);
        mouse.queue_report(4, 64'h0000_0000_0100_FB00);
        mouse.corrupt_n = 1;                      // the first report is damaged once and comes again
        wait_ms(20);
        check(irq, "interrupt line high while a record waits");
        pop_rec(1);
        check(rsrc == 1 && rlen == 4 && rec[0] == 8'h01 && rec[1] == 8'h05 && rec[2] == 8'hFE && rec[3] == 8'h00,
              "first mouse report, once, from slot 0");
        pop_rec(1);
        check(rsrc == 1 && rlen == 4 && rec[1] == 8'hFB && rec[3] == 8'h01, "second mouse report");
        pop_rec(1);
        check(rlen == -1 && mouse.n_rep_acked == 2, "no third record; the mouse saw two ACKs");
        mouse.deaf_ack_n = 1;
        mouse.queue_report(4, 64'h0000_0000_0000_0102);
        mouse.queue_report(4, 64'h0000_0000_0000_0204);
        wait_ms(24);
        pop_rec(1); n0 = rec[0];
        pop_rec(1); n1 = rec[0];
        pop_rec(1);
        check(n0 == 2 && n1 == 4 && rlen == -1, "a report the mouse sent twice arrives once (toggle)");
        bus_rd(pa(1, 8'h04), rv);
        check(rv[11:10] == 2'b00 && !rv[2], "no slot fault, device present");

        // ---- 6. audio: 100 ms of both streams
        // 100 ms at 48 samples a millisecond are 4,800 samples, with a margin of about 20 either way.
        // ---- 6. audio: 100 ms of both streams
        n0 = headset.spk_n; n1 = mic_n; n2 = headset.mic_sent;
        bus_rd(16'h001C, c0);
        wait_ms(100);
        bus_rd(16'h001C, c1);
        $display("      speaker: %0d samples in %0d packets, %0d to %0d a packet, %0d sequence errors",
                 headset.spk_n - n0, headset.spk_pkts, headset.spk_min, headset.spk_max, headset.spk_err);
        $display("      microphone: device sent %0d, radio got %0d, %0d sequence errors",
                 headset.mic_sent - n2, mic_n - n1, mic_err);
        check(headset.spk_n - n0 >= 4780 && headset.spk_n - n0 <= 4820, "speaker: 48 samples a ms reach the headset");
        check(headset.spk_err == 0 && headset.spk_badcrc == 0, "speaker: every sample once, in order, both channels");
        check(headset.spk_max == 48, "speaker: never more than max_samples in a packet");
        check(mic_n - n1 >= 4780 && mic_n - n1 <= 4830, "microphone: the device's samples reach the radio");
        check(mic_err == 0, "microphone: every sample once, in order, mono on both channels");
        // mic_count may differ from what the radio got by a few samples that are in flight.
        check(c1 - c0 + 4 >= mic_n - n1 && c1 - c0 <= mic_n - n1 + 4, "mic_count counts them");
        bus_rd(16'h0018, rv);
        check(rv[31:8] == 24'd0, "no speaker overrun, no bad microphone packet");
        headset.corrupt_n = 1;
        wait_ms(5);
        bus_rd(16'h0018, rv);
        check(rv[31:16] == 16'd1 && mic_err == 0, "a damaged microphone packet is dropped whole and counted");
        // Mono speaker with 3 byte samples: a packet is 3 bytes of overhead (PID and CRC-16) and 48 * 3 data bytes = 144 bytes, and the sample is the
        // mean of left and right with a zero low byte.
        // mono speaker, 3-byte samples: the byte count of a packet
        bus_wr(16'h0010, {18'd0, 6'd48, 1'b1, 1'b1, 4'd1, 1'b0, 1'b0});
        wait_ms(2);
        bus_wr(16'h0010, {18'd0, 6'd48, 1'b1, 1'b1, 4'd1, 1'b0, 1'b1});
        wait_ms(6);
        check(headset.spk_len == 3 + 48 * 3, "mono, 3-byte samples: 144 bytes a packet");
        check(headset.spk_b1 == 8'd0 && headset.spk_b2 == 8'hFF && headset.spk_b3 == 8'hFF,
              "mono is (left + right) / 2 with a zero low byte");
        bus_wr(16'h0010, 32'h00003000);
        wait_ms(2);
        bus_wr(16'h0010, {18'd0, 6'd48, 1'b0, 1'b0, 4'd1, 1'b0, 1'b1});
        wait_ms(4);
        headset.spk_err = 0; headset.spk_first = 1'b1;

        // ---- 7. unplug the mouse while it is polled; plug the keyboard
        // The port must notice the missing device (gone, line event), end a transaction with result 6 and send nothing more to the empty socket.
        // The keyboard on the same port is then enumerated, its boot reports arrive, and a slot whose endpoint answers STALL stops and says so.
        // ---- 7. unplug the mouse while it is polled; plug the keyboard
        n1 = n_oe1;
        mouse.attached = 1'b0;
        wait_ms(3);
        bus_rd(pa(1, 8'h04), rv);
        check(rv[2] && rv[8] && rv[1:0] == 2'b00, "mouse pulled: gone, line event, both lines low");
        n1 = n_oe1;
        xact(1, 2'd2, 4'd0, 1'b1, 7'd0, 8'd50);
        check(res == 3'd6, "a transaction to the empty socket ends with result 6");
        wait_ms(5);
        check(n_oe1 == n1, "the port sends nothing to the empty socket");
        bus_wr(pa(1, 8'h10), 32'd0);
        bus_wr(pa(1, 8'h00), 32'd0);
        kbd_sel = 1'b1;
        kbd.attached = 1'b1;
        wait_ms(2);
        bus_rd(pa(1, 8'h04), rv);
        check(rv[2:0] == 3'b010, "keyboard plugged: D- high, gone cleared");
        enumerate(1, 1'b1, 7'd3, 8, 59);
        check(ok, "keyboard enumerated on the same port");
        ctrl_out(1, setup8(8'h21, 8'h0B, 16'd0, 16'd0, 16'd0), 0, 32'd0);
        check(cres == 3'd1 && kbd.protocol == 8'd0, "SET_PROTOCOL boot");
        bus_wr(pa(1, 8'h10), {19'd0, 8'd8, 4'd1, 1'b1});
        kbd.queue_report(8, 64'h0000_0000_0004_0002);       // shift + a
        kbd.queue_report(8, 64'h0000_0000_0000_0000);       // all up
        wait_ms(30);
        pop_rec(1);
        check(rsrc == 1 && rlen == 8 && rec[0] == 8'h02 && rec[2] == 8'h04, "key down report (8 bytes)");
        pop_rec(1);
        check(rsrc == 1 && rlen == 8 && rec[0] == 8'h00 && rec[2] == 8'h00, "key up report");
        kbd.int_stall = 1'b1;
        wait_ms(20);
        bus_rd(pa(1, 8'h04), rv);
        check(rv[10], "a slot whose endpoint answers STALL stops and says so");
        n1 = kbd.n_tokens;
        wait_ms(20);
        check(kbd.n_tokens == n1, "a stopped slot is not polled");
        kbd.int_stall = 1'b0;

        // ---- 8. the headset still streams; suspend and resume it
        // Port 0's audio must not be disturbed by port 1's faults. Suspend stops the SOFs, resume puts K on the lines, and then the
        // frames run again, the headset answers, and a headset that is pulled and plugged again enumerates again.
        // ---- 8. the headset still streams; suspend and resume it
        check(headset.spk_err == 0 && mic_err == 0, "audio undisturbed by all of port 1's faults");
        n0 = headset.n_sof;
        bus_wr(pa(0, 8'h00), {21'd0, 7'd5, 1'b0, 3'd3});
        wait_ms(5);
        check(headset.n_sof - n0 <= 1, "suspend: no SOF");
        bus_wr(pa(0, 8'h00), {21'd0, 7'd5, 1'b0, 3'd4});
        wait_ms(1);
        check(dp[0] === 1'b0 && dn[0] === 1'b1, "resume: K on the lines");
        bus_wr(pa(0, 8'h00), {21'd0, 7'd5, 1'b0, 3'd2});
        wait_ms(5);
        check(headset.n_sof - n0 >= 4, "after resume the frames run again");
        ctrl_in(0, setup8(8'h80, 8'd6, 16'h0100, 16'd0, 16'd18), 64);
        check(cres == 3'd1 && clen == 18, "and the headset answers");
        headset.attached = 1'b0;
        wait_ms(3);
        bus_rd(pa(0, 8'h04), rv);
        check(rv[2], "headset pulled: gone");
        bus_wr(pa(0, 8'h00), 32'd0);
        headset.attached = 1'b1;
        wait_ms(2);
        enumerate(0, 1'b0, 7'd6, 64, 197);
        check(ok, "headset plugged again: enumerated again");

        $display("%0d checks, %0d failed", checks, fails);
        if (fails == 0) $display("tb_usbh: PASS");
        else            $display("tb_usbh: FAIL");
        $finish;
    end

    // Time limit.
    initial begin
        #2000000000;
        $display("tb_usbh: FAIL (time limit)");
        $finish;
    end
endmodule
