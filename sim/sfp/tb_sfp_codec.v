// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Testbench for the SFP lane's coding and word alignment (docs/SFP_LINKS.md sections 2.2 and 9). A sender codes
// bytes in 8b10b (docs/learn/GLOSSARY.md), a lane model (sim/sfp/sfp_lane_model.v) cuts the resulting bit stream
// into words at an arbitrary bit position, as a real transceiver does, and the receiver (rtl/sfp/sfp_rx_sym.v)
// has to find the word boundary from the comma symbol, lock, and decode every symbol again. It is done for
// the 10-bit lane of the HL2 link (coder rtl/n1/enc_8b10b.v, one symbol per word) at the bit positions
// 0, 3, 6 and 9, and for the 20-bit lane of the board link (coder rtl/sfp/sfp_enc20.v, two symbols per word)
// at all 20 bit positions.
//
// Stimulus: idle pairs of a comma and a data symbol, so the receiver can lock, then twice every data byte
// from 0 to 255 followed by the control symbols that the links use (start and end of frame, carrier extend,
// K28.0, K28.3, the comma and an idle half). What comes out of the receiver must be what went in, in order,
// with no error flag once the receiver is locked. The 20-bit coder's output is also checked for running
// disparity by counting the ones of every symbol: symbols that are not balanced must alternate between more
// ones and fewer ones. Last, a burst of bad words (a dead line) drops the lock, and the aligner has to find
// the position again, with exactly one loss counted.
//
// Pass: no mismatch, enough symbols checked at every bit position (520 for the 10-bit lane, 1,000 for the
// 20-bit lane) and the relock worked; the bench prints "PASS: tb_sfp_codec", otherwise FAIL lines and
// "FAILED: n errors".
//
// How to run: from the repository root, `bash sim/sfp/run.sh codec`.

`timescale 1ns / 1ps

module tb_sfp_codec;
    // Half period 4 ns makes an 8 ns period, the 125 MHz of a 1000BASE-X lane (10 bits per clock, 1.25 Gbit/s).
    reg clk = 0;
    always #4 clk = ~clk;
    integer errors = 0;

    // ---- 10-bit lane: one complete chain per bit position g = 0, 3, 6, 9 ----
    // Coder, lane model with OFFSET g, aligner and decoder. lw is the coder's output in line order
    // (bit 0 on the line first), which is the reverse of the order of the coder's output port.
    genvar g;
    generate
        for (g = 0; g < 10; g = g + 3) begin : g10
            reg  [7:0] d = 8'hBC; reg k = 1; reg rst = 1;
            wire [9:0] e; wire [9:0] lw = {e[0], e[1], e[2], e[3], e[4], e[5], e[6], e[7], e[8], e[9]};
            wire [9:0] rw; wire rc, sv, sk, se, lk; wire [7:0] sd; wire [15:0] ls;
            enc_8b10b u_e (.clk(clk), .rst(rst), .din(d), .kin(k), .dout(e), .rd_out(), .valid());
            sfp_lane_model #(.W(10), .OFFSET(g)) u_l (.tx_clk(clk), .tx_word(lw), .rx_clk(rc), .rx_word(rw),
                                                    .err(10'd0), .cut(1'b0));
            sfp_rx_sym #(.N(1)) u_r (.clk(rc), .rst(1'b0), .vld(1'b1), .din(rw), .sym_vld(sv), .sym_d(sd),
                                     .sym_k(sk), .sym_err(se), .locked(lk), .cnt_loss(ls));
            // The queue q keeps every symbol sent in order; the receiver joins the stream at the first symbol that
            // is not an idle one, so the queue is read from there.
            reg [8:0] q [0:2047]; integer wp = 0, rp = 0, n = 0, i, checked = 0; reg synced = 0;
            always @(posedge clk) begin q[wp] <= {k, d}; wp <= wp + 1; end
            initial begin
                repeat (4) @(posedge clk); rst = 0;
                // 40 idle pairs of the comma (K28.5) and a data symbol (D16.2, 0x50), long enough for the
                // receiver to find the word boundary and lock.
                for (i = 0; i < 40; i = i + 1) begin
                    @(posedge clk); d <= 8'hBC; k <= 1; @(posedge clk); d <= 8'h50; k <= 0;
                end
                // Two rounds of: all 256 data bytes, then control symbols (K27.7 start of frame, K29.7 and
                // K23.7 for the end, K28.0, K28.3, the comma K28.5) and an idle half (D5.6).
                for (n = 0; n < 2; n = n + 1) begin
                    for (i = 0; i < 256; i = i + 1) begin @(posedge clk); d <= i[7:0]; k <= 0; end
                    @(posedge clk); d <= 8'hFB; k <= 1; @(posedge clk); d <= 8'hFD; k <= 1;
                    @(posedge clk); d <= 8'hF7; k <= 1; @(posedge clk); d <= 8'h1C; k <= 1;
                    @(posedge clk); d <= 8'h7C; k <= 1; @(posedge clk); d <= 8'hBC; k <= 1;
                    @(posedge clk); d <= 8'hC5; k <= 0;
                end
                repeat (30) @(posedge clk);
                // Round one and two together are 526 symbols, so at least 520 must have been checked.
                if (checked < 520) begin errors = errors + 1; $display("FAIL: 10-bit offset %0d: %0d checked", g, checked); end
            end
            // Receiver side, one word per recovered clock while locked: wait for the first symbol that is
            // not idle, find it in the queue, then every received symbol must be the queued one and carry no
            // error flag.
            always @(posedge rc) if (lk && sv) begin
                if (!synced && {sk, sd} !== 9'h1BC && {sk, sd} !== 9'h050) begin
                    while (q[rp] === 9'h1BC || q[rp] === 9'h050) rp = rp + 1;
                    synced = 1;
                end
                if (synced) begin
                    checked = checked + 1;
                    if (se || {sk, sd} !== q[rp]) begin
                        errors = errors + 1;
                        if (errors < 10) $display("FAIL: 10-bit offset %0d: got %b %h err %b, expected %h", g, sk, sd, se, q[rp]);
                    end
                    rp = rp + 1;
                end
            end
        end

        // ---- 20-bit lane: two symbols per word, one chain per bit position g = 0 to 19 ----
        for (g = 0; g < 20; g = g + 1) begin : g20
            reg  [15:0] d = 16'h50BC; reg [1:0] k = 2'b01; reg rst = 1; reg bad = 0;
            wire [19:0] lw, rw; wire rc, sv, lk; wire [1:0] sk, se; wire [15:0] sd, ls;
            sfp_enc20 u_e (.clk(clk), .rst(rst), .d(d), .k(k), .q(lw));
            sfp_lane_model #(.W(20), .OFFSET(g)) u_l (.tx_clk(clk), .tx_word(lw), .rx_clk(rc), .rx_word(rw),
                                                     .err(20'd0), .cut(bad));
            sfp_rx_sym #(.N(2)) u_r (.clk(rc), .rst(1'b0), .vld(1'b1), .din(rw), .sym_vld(sv), .sym_d(sd),
                                     .sym_k(sk), .sym_err(se), .locked(lk), .cnt_loss(ls));
            // q holds the words sent as {k, d}, rdk and rdsum track the disparity of the last unbalanced symbol.
            reg [17:0] q [0:2047]; integer wp = 0, rp = 0, n = 0, i, checked = 0, ones, b, rdsum = 0, s; reg synced = 0;
            reg rdk = 0, quiet = 0;
            always @(posedge clk) begin q[wp] <= {k, d}; wp <= wp + 1; end
            // Running disparity of what the coder sends, symbol by symbol, by counting ones: a symbol with more
            // or fewer than 5 ones changes the disparity, and two such symbols in a row must go opposite ways.
            always @(posedge clk) if (!rst) for (s = 0; s < 2; s = s + 1) begin
                ones = 0; for (b = 0; b < 10; b = b + 1) ones = ones + lw[10*s + b];
                if (ones != 5) begin
                    if (rdk && ((ones > 5) == (rdsum > 0))) begin errors = errors + 1; if (errors < 10) $display("FAIL: 20-bit coder disparity"); end
                    rdsum = (ones > 5) ? 1 : -1; rdk = 1;
                end
            end
            initial begin
                // Idle words of the comma in symbol 0 and a data byte in symbol 1, then two rounds of data in
                // both symbols (second byte is the first one xor 0xA5), words with a start of frame symbol
                // in symbol 0 followed by a data byte, and the end of frame and comma control words.
                repeat (4) @(posedge clk); rst = 0;
                for (i = 0; i < 40; i = i + 1) begin @(posedge clk); d <= 16'h50BC; k <= 2'b01; end
                for (n = 0; n < 2; n = n + 1) begin
                    for (i = 0; i < 256; i = i + 1) begin @(posedge clk); d <= {i[7:0] ^ 8'hA5, i[7:0]}; k <= 0; end
                    for (i = 0; i < 256; i = i + 1) begin @(posedge clk); d <= {i[7:0], 8'hFB}; k <= 2'b01; end
                    @(posedge clk); d <= 16'h12FD; k <= 2'b01; @(posedge clk); d <= 16'h341C; k <= 2'b01;
                    @(posedge clk); d <= 16'h567C; k <= 2'b01; @(posedge clk); d <= 16'h50BC; k <= 2'b01;
                end
                repeat (30) @(posedge clk);
                if (checked < 1000) begin errors = errors + 1; $display("FAIL: 20-bit offset %0d: %0d checked", g, checked); end
                // Bad words: the lock must drop and then come back, with exactly one loss counted (ls).
                quiet = 1; d <= 16'h50BC; k <= 2'b01;
                bad = 1; repeat (40) @(posedge clk); bad = 0;
                repeat (40) @(posedge clk);
                if (!lk || ls != 16'd1) begin errors = errors + 1; $display("FAIL: 20-bit offset %0d: no relock (%b, %0d)", g, lk, ls); end
            end
            // Receiver side, as in the 10-bit lane but for both symbols of the word at once.
            always @(posedge rc) if (lk && sv && !quiet) begin
                if (!synced && {sk, sd} !== 18'h150BC) begin
                    while (q[rp] === 18'h150BC) rp = rp + 1;
                    synced = 1;
                end
                if (synced) begin
                    checked = checked + 1;
                    if (se != 0 || {sk, sd} !== q[rp]) begin
                        errors = errors + 1;
                        if (errors < 10) $display("FAIL: 20-bit offset %0d: got %b %h err %b, expected %h", g, sk, sd, se, q[rp]);
                    end
                    rp = rp + 1;
                end
            end
        end
    endgenerate

    initial begin
        // The run takes about 9.5 us at 8 ns per clock, so 11 us is the limit.
        #11_000;
        if (errors == 0) $display("PASS: tb_sfp_codec"); else $display("FAILED: %0d errors", errors);
        $finish;
    end
endmodule
