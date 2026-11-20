// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Testbench for the SFP network socket, rtl/sfp/sfp_top.v (register page 0x0A): the PCS (the coding and
// auto-negotiation layer of Gigabit Ethernet over a fiber or module link, see docs/learn/GLOSSARY.md), the
// MAC that frames bytes into Ethernet frames, and the packet memory the CPU reads and writes through the
// register bus. The design is tested against a link partner that was written from the standards (IEEE 802.3
// clauses 36 and 37 and the SGMII specification) and not from our own PCS, so that a misreading of the standard
// in the design cannot be mirrored in the test (docs/SFP_LINKS.md section 9). The partner shares only the
// 8b10b table with the design. It checks, on everything the design sends, the running disparity of every symbol
// by counting bits, the place of every comma, the ordered sets, and the frame's FCS (frame check sequence,
// the CRC at the end of an Ethernet frame) with a bit-serial CRC of its own. The design's receive direction
// goes through the lane model of sim/sfp/sfp_lane_model.v, which cuts the bit stream at an arbitrary position,
// and the partner's clock is 100 ppm off the design's, so the receiver has to cope with a frequency offset.
//
// Variants selected on the command line:
//   -DSGMII: the partner is the PHY side of a copper module (SGMII); without it the partner speaks
//   1000BASE-X with auto-negotiation.
//   -DGAPS: the transceiver's receive buffer as the design sees it when its read clock is a little faster than the
//   words arrive (about 2.5 %), so some receive clocks carry no word (rx_vld low), and the MAC has to take the
//   frame bytes with gaps in between.
//
// Script: negotiation until the link is up, a good frame from the partner (read back through the packet memory),
// a frame with one flipped bit (dropped and counted), a good one after it, frames from the design of 60 and
// 61 bytes (both end positions of the last word, checked byte by byte and by FCS), a renegotiation after the
// partner restarts, and a dead line, where the link and the aligner must drop.
//
// Pass: no check fails; the bench prints "PASS (n symbols of the design checked)", otherwise FAIL lines and
// "FAILED: n errors".
//
// How to run: from the repository root, `bash sim/sfp/run.sh net` runs the 1000BASE-X and SGMII variants, and
// `bash sim/sfp/run.sh gaps` the same two with -DGAPS.

`timescale 1ns / 1ps

module tb_sfp_net;
// The 8b10b table and the encode and decode functions, which are the only thing the partner takes from the design.
`include "tab_8b10b.vh"

`ifdef SGMII
    localparam SG = 1;
`else
    localparam SG = 0;
`endif

    // clk is the register clock of the design (120 MHz), txc the lane clock of its transmitter (125 MHz), and
    // pclk the lane clock of the partner (125 MHz, 100 ppm slow).
    reg clk = 0, txc = 0, pclk = 0, rst = 1;
    always #4.1667 clk = ~clk;        // 120 MHz
    always #4.0    txc = ~txc;        // our lane clock
    always #4.0004 pclk = ~pclk;      // the partner's, 100 ppm slow

    integer errors = 0;

    // Register bus of the design, its lane words, and the error and cut controls of the lane model.
    // ---------------------------------------------------------------- DUT
    reg         bus_wr = 0, bus_rd = 0;
    reg  [15:0] bus_addr = 0;
    reg  [31:0] bus_wdata = 0;
    wire [31:0] bus_rdata;
    wire [9:0]  d_tx, d_rx;
    wire        d_rxc, irq_rx, irq_link;
    reg  [9:0]  rx_err = 0;
    reg         rx_cut = 0;
    wire [9:0]  p_tx;                 // partner's words, line order

`ifdef GAPS
    // Words of the lane model are queued in its clock and taken one per reader clock while the queue is not empty.
    reg g_rxc = 0;
    always #3.9 g_rxc = ~g_rxc;
    reg [9:0] gq [0:255];
    integer gw = 0, gr = 0;
    reg [9:0] g_rx = 10'd0;
    reg       g_vld = 1'b0;
    always @(posedge d_rxc) begin gq[gw % 256] = d_rx; gw = gw + 1; end
    always @(posedge g_rxc) begin
        if (gr < gw - 2) begin g_rx <= gq[gr % 256]; g_vld <= 1'b1; gr = gr + 1; end
        else g_vld <= 1'b0;
    end
`else
    wire       g_rxc = d_rxc;
    wire [9:0] g_rx = d_rx;
    wire       g_vld = 1'b1;
`endif
    // The design, with its link timers shortened (3,000 and 800 clocks) so that the negotiation fits into a short
    // run, and the serdes status inputs held at "up".
    sfp_top #(.TIMER_X(3000), .TIMER_SGMII(800)) dut (
        .clk(clk), .rst(rst), .bus_wr(bus_wr), .bus_rd(bus_rd), .bus_addr(bus_addr), .bus_wdata(bus_wdata),
        .bus_rdata(bus_rdata),
        .por_n(), .ln_rst_n(), .ln_rx_rst(), .ln_tx_rst(), .ln0_fix(), .ln1_fix(),
        .ln0_stat(4'hF), .ln1_stat(4'h0), .diag(12'h000), .ln1_aligned(1'b0),
        .sfp_tx_disable(), .sfp_los(2'b00), .twi_scl_o(), .twi_sda_o(), .twi_scl_i(1'b1), .twi_sda_i(1'b1),
        .twi_sel(),
        .txc(txc), .tx_word(d_tx), .rxc(g_rxc), .rx_vld(g_vld), .rx_word(g_rx),
        .irq_rx(irq_rx), .irq_link(irq_link)
    );
    // The partner's words go through the lane model, which cuts them at bit position 7, and rx_err and rx_cut
    // flip bits and kill the line on demand.
    sfp_lane_model #(.W(10), .OFFSET(7)) u_to_dut (
        .tx_clk(pclk), .tx_word(p_tx), .rx_clk(d_rxc), .rx_word(d_rx), .err(rx_err), .cut(rx_cut));

    // Register write, followed by 4 idle clocks, and register read, with the data taken 6 clocks later.
    task wr(input [15:0] a, input [31:0] d); begin
        @(posedge clk); bus_addr <= a; bus_wdata <= d; bus_wr <= 1; @(posedge clk); bus_wr <= 0;
        repeat (4) @(posedge clk);
    end endtask
    reg [31:0] rdv;
    task rd(input [15:0] a); begin
        @(posedge clk); bus_addr <= a; bus_rd <= 1; @(posedge clk); bus_rd <= 0;
        repeat (6) @(posedge clk); rdv = bus_rdata;
    end endtask

    // ---------------------------------------------------------------- partner: transmit side (pclk)
    // psym encodes one symbol with the running disparity p_rd and puts its 10 bits on the line in line order.
    // p_idle sends an idle ordered set (K28.5 with D5.6 or D16.2, whichever leaves the disparity as it was),
    // p_cfg a configuration ordered set (K28.5, D21.5 or D2.2 in turn, then the 16-bit word low byte first).
    // ---------------------------------------------------------------- partner: transmit side (pclk)
    reg        p_rd = 0;
    reg [9:0]  p_code = 0;
    assign p_tx = {p_code[0], p_code[1], p_code[2], p_code[3], p_code[4], p_code[5], p_code[6], p_code[7],
                   p_code[8], p_code[9]};
    task psym(input [7:0] d, input k);
        reg [10:0] e;
        begin
            e = k ? enc8b10b_k(d, p_rd) : enc8b10b_d(d, p_rd);
            @(posedge pclk); p_code <= e[10:1]; p_rd = e[0];
        end
    endtask
    task p_idle; begin
        if (p_rd) begin psym(8'hBC, 1); psym(8'hC5, 0); end
        else      begin psym(8'hBC, 1); psym(8'h50, 0); end
    end endtask
    reg p_c2 = 0;
    task p_cfg(input [15:0] w); begin
        psym(8'hBC, 1); psym(p_c2 ? 8'h42 : 8'hB5, 0); psym(w[7:0], 0); psym(w[15:8], 0); p_c2 = ~p_c2;
    end endtask

    // Ethernet CRC-32 of one more byte, computed bit by bit with the reflected polynomial 0xEDB88320. The state
    // starts as all ones and is inverted at the end by the caller; it is written separately from the
    // design's own CRC on purpose.
    function [31:0] crc_byte(input [31:0] c, input [7:0] b);
        integer i; reg [31:0] x;
        begin
            x = c ^ {24'd0, b};
            for (i = 0; i < 8; i = i + 1) x = x[0] ? ((x >> 1) ^ 32'hEDB88320) : (x >> 1);
            crc_byte = x;
        end
    endfunction

    // The frame the partner sends: pf_len bytes of the pattern (7 i + 3) mod 256.
    reg [7:0] pf [0:127];             // frame the partner sends
    integer   pf_len = 0;
    // One frame in 1000BASE-X: start of packet /S/ (K27.7) which takes the place of the first preamble byte,
    // 6 more preamble bytes of 0x55, the start of frame delimiter 0xD5, the payload, the FCS (inverted CRC,
    // low byte first), then /T/ (K29.7) and /R/ (K23.7), with another /R/ when the frame from /S/ to /R/ is
    // an odd number of symbols so that the idle that follows starts on an even symbol.
    task p_frame;
        integer i; reg [31:0] c;
        begin
            c = 32'hFFFFFFFF;
            psym(8'hFB, 1);
            for (i = 0; i < 6; i = i + 1) psym(8'h55, 0);
            psym(8'hD5, 0);
            for (i = 0; i < pf_len; i = i + 1) begin psym(pf[i], 0); c = crc_byte(c, pf[i]); end
            c = ~c;
            psym(c[7:0], 0); psym(c[15:8], 0); psym(c[23:16], 0); psym(c[31:24], 0);
            psym(8'hFD, 1); psym(8'hF7, 1);
            if (((pf_len + 14) % 2) == 1) psym(8'hF7, 1);   // /S/ .. /R/ is odd long: one more /R/
        end
    endtask

    // ---------------------------------------------------------------- partner: receive side (our txc)
    // The design's transmit direction is taken aligned (the design's own aligner is tested in the other direction).
    wire [9:0] rcode = {d_tx[0], d_tx[1], d_tx[2], d_tx[3], d_tx[4], d_tx[5], d_tx[6], d_tx[7], d_tx[8], d_tx[9]};
    wire [9:0] rdec = dec8b10b(rcode);
    integer    ones, k, rdsum = 0, sym_n = 0;
    reg        rd_known = 0, even = 0, chk = 0;
    reg [7:0]  prev_d = 0; reg prev_k = 0, prev2_comma = 0;
    reg [1:0]  cpos = 0; reg [7:0] clo = 0;
    reg [15:0] d_cfg = 0; integer d_cfg_n = 0, d_idle_n = 0, d_c1 = 0, d_c2 = 0, d_i1 = 0;
    reg        in_f = 0; reg [7:0] df [0:255]; integer df_len = 0, df_done = 0; reg f_even = 0;
    // Everything the design sends is checked symbol by symbol: a valid code, the running disparity by bit
    // count (unbalanced symbols have 4 or 6 ones and must alternate), commas on even symbol positions, /S/ on
    // an even position, no control symbol inside a frame, and the configuration words and idle ordered sets
    // are decoded and counted (d_cfg and d_cfg_n hold the last word and how often it repeated, d_c1 and d_c2
    // count the C1 and C2 sets, d_i1 the idle I1 sets). The bytes of a frame go into df.
    always @(posedge txc) if (chk) begin
        sym_n = sym_n + 1;
        ones = 0; for (k = 0; k < 10; k = k + 1) ones = ones + rcode[k];
        if (!rdec[9]) begin errors = errors + 1; $display("FAIL: design sent an invalid code %b", rcode); end
        // running disparity by bit count: it must stay at -1 or +1 after every symbol
        if (ones != 5) begin
            if (rd_known && ((ones > 5) == (rdsum > 0))) begin
                errors = errors + 1; $display("FAIL: disparity error at symbol %0d", sym_n);
            end
            rdsum = (ones > 5) ? 1 : -1; rd_known = 1;
            if ((ones != 4) && (ones != 6)) begin errors = errors + 1; $display("FAIL: code weight %0d", ones); end
        end
        even = ~even;
        if (rdec[8] && rdec[7:0] == 8'hBC) begin
            if (rd_known && sym_n > 4 && even !== 1'b1 && prev2_comma) begin
                errors = errors + 1; $display("FAIL: comma on an odd symbol at %0d", sym_n);
            end
            even = 1; prev2_comma = 1;
        end
        if (in_f) begin
            if (rdec[8] && rdec[7:0] == 8'hFD) begin in_f = 0; df_done = df_done + 1; f_even = even; end
            else if (rdec[8]) begin errors = errors + 1; $display("FAIL: control symbol inside a frame"); end
            else begin df[df_len] = rdec[7:0]; df_len = df_len + 1; end
        end else if (rdec[8] && rdec[7:0] == 8'hFB) begin
            if (!even) begin errors = errors + 1; $display("FAIL: /S/ on an odd symbol"); end
            in_f = 1; df_len = 0;
        end else if (cpos == 1) begin clo = rdec[7:0]; cpos = 2; end
        else if (cpos == 2) begin
            cpos = 0;
            if ({rdec[7:0], clo} == d_cfg) d_cfg_n = d_cfg_n + 1; else d_cfg_n = 1;
            d_cfg = {rdec[7:0], clo}; d_idle_n = 0;
        end else if (prev_k && prev_d == 8'hBC && !rdec[8]) begin
            if (rdec[7:0] == 8'hB5) begin cpos = 1; d_c1 = d_c1 + 1; end
            else if (rdec[7:0] == 8'h42) begin cpos = 1; d_c2 = d_c2 + 1; end
            else if (rdec[7:0] == 8'h50) begin d_idle_n = d_idle_n + 1; d_cfg_n = 0; end
            else if (rdec[7:0] == 8'hC5) begin d_idle_n = d_idle_n + 1; d_cfg_n = 0; d_i1 = d_i1 + 1; end
            else begin errors = errors + 1; $display("FAIL: K28.5 followed by %h", rdec[7:0]); end
        end
        prev_d = rdec[7:0]; prev_k = rdec[8];
    end

    // ---------------------------------------------------------------- the partner's script
    // Frame data: partner frames use (7 i + 3) mod 256, the design's frames (13 i + 5) mod 256.
    // ---------------------------------------------------------------- the partner's script
    integer i, n, t0;
    reg [15:0] base, want;
    reg [7:0]  tf [0:127];
    reg [31:0] c, w;
    reg        p_stop = 0;
    initial begin
        $display("tb_sfp_net: %0s", SG ? "SGMII" : "1000BASE-X");
        for (i = 0; i < 128; i = i + 1) begin pf[i] = (i * 7 + 3) & 8'hFF; tf[i] = (i * 13 + 5) & 8'hFF; end
        repeat (20) @(posedge clk); rst = 0;
        // Register page: the id reads 0x5346_0001 ('S' 'F', layout version 1). Then the transceiver is released,
        // two registers are cleared, and lane 0 is switched on with negotiation (value 5; the SGMII variant
        // uses 7).
        rd(16'h0000); if (rdv !== 32'h5346_0001) begin errors = errors + 1; $display("FAIL: id %h", rdv); end
        wr(16'h0004, 32'h0000_0007);
        wr(16'h000C, 32'h0);
        wr(16'h0030, 32'h0);
        wr(16'h0020, SG ? 32'h7 : 32'h5);
        repeat (20) @(posedge txc);
        chk = 1;

        // --- negotiation, the partner's side
        // The design must send its ability word (base word 0x0020 for 1000BASE-X, full duplex; for SGMII the
        // MAC side sends 0x0001) at least three times in a row before the partner acknowledges it. The SGMII
        // partner word 0x9801 says link up, full duplex, 1000 Mbit/s, SGMII. The partner first sends empty
        // configuration words to make the design restart, answers with its own word until it sees the design's,
        // acknowledges with bit 14, and goes to idle when the design does the same.
        // --- negotiation, the partner's side
        base = SG ? 16'h9801 : 16'h0020;
        want = SG ? 16'h0001 : 16'h0020;
        for (i = 0; i < 400; i = i + 1) p_cfg(16'h0000);
        n = 0;
        while (!(d_cfg_n >= 3 && (d_cfg & 16'hBFFF) == want)) begin
            p_cfg(base); n = n + 1;
            if (n > 20000) begin errors = errors + 1; $display("FAIL: no ability from the design (%h)", d_cfg); $finish; end
        end
        n = 0;
        while (!(d_cfg_n >= 3 && d_cfg == (want | 16'h4000))) begin
            p_cfg(base | 16'h4000); n = n + 1;
            if (n > 20000) begin errors = errors + 1; $display("FAIL: no acknowledge from the design (%h)", d_cfg); $finish; end
        end
        for (i = 0; i < 1200; i = i + 1) p_cfg(base | 16'h4000);
        n = 0;
        while (d_idle_n < 3) begin
            p_idle; n = n + 1;
            if (n > 20000) begin errors = errors + 1; $display("FAIL: the design sends no idle"); $finish; end
        end
        for (i = 0; i < 3000; i = i + 1) p_idle;
        // Link status in bits 3:0 of 0x24 must read F, with the partner's word (with acknowledge) in
        // bits 31:16, the aligner must be locked, and the design must have sent at least 10 each of C1 and C2.
        rd(16'h0024);
        if (rdv[3:0] !== 4'hF) begin errors = errors + 1; $display("FAIL: status %h, link not up", rdv); end
        if (rdv[31:16] !== (base | 16'h4000)) begin errors = errors + 1; $display("FAIL: partner word %h", rdv[31:16]); end
        rd(16'h0008); if (!rdv[4]) begin errors = errors + 1; $display("FAIL: aligner not locked"); end
        if (d_c1 < 10 || d_c2 < 10) begin errors = errors + 1; $display("FAIL: /C1/ %0d /C2/ %0d", d_c1, d_c2); end
        $display("  link up; design sent %0d /C1/, %0d /C2/, %0d /I1/", d_c1, d_c2, d_i1);

        // --- a frame from the partner (61 bytes: odd, so the partial last word is used)
        pf_len = 61;
        p_frame; for (i = 0; i < 200; i = i + 1) p_idle;
        rd(16'h002C);
        if (rdv !== 32'd17) begin errors = errors + 1; $display("FAIL: rx_wr_ptr %0d, expected 17", rdv); end
        rd(16'h2000); if (rdv !== 32'd61) begin errors = errors + 1; $display("FAIL: length word %0d", rdv); end
        for (i = 0; i < 61; i = i + 1) begin
            if (i % 4 == 0) rd(16'h2004 + i);
            if (rdv[8*(i%4) +: 8] !== pf[i]) begin errors = errors + 1; $display("FAIL: rx byte %0d = %h", i, rdv[8*(i%4) +: 8]); end
        end
        wr(16'h0030, 32'd17);
        // a second one, with a flipped bit on the line: dropped, counted
        pf_len = 64;
        fork
            p_frame;
            begin repeat (40) @(posedge d_rxc); rx_err <= 10'h010; @(posedge d_rxc); rx_err <= 0; end
        join
        for (i = 0; i < 200; i = i + 1) p_idle;
        rd(16'h002C); if (rdv !== 32'd17) begin errors = errors + 1; $display("FAIL: bad frame moved rx_wr_ptr to %0d", rdv); end
        rd(16'h0038); if (rdv !== 32'd1) begin errors = errors + 1; $display("FAIL: rx_dropped %0d", rdv); end
        // and a good one after it
        p_frame; for (i = 0; i < 200; i = i + 1) p_idle;
        rd(16'h002C); if (rdv !== 32'd34) begin errors = errors + 1; $display("FAIL: rx_wr_ptr %0d, expected 34", rdv); end
        rd(16'h0034); if (rdv !== 32'd2) begin errors = errors + 1; $display("FAIL: rx_frames %0d", rdv); end

        // --- frames from the design: 60 and 61 bytes (both end positions)
        for (n = 60; n <= 61; n = n + 1) begin
            for (i = 0; i < n; i = i + 4)
                wr(16'h1000 + i, {tf[i+3], tf[i+2], tf[i+1], tf[i]});
            df_done = 0;
            fork
                wr(16'h0028, n);
                begin t0 = 0; while (df_done == 0 && t0 < 4000) begin p_idle; t0 = t0 + 1; end end
            join
            for (i = 0; i < 20; i = i + 1) p_idle;
            if (df_done != 1) begin errors = errors + 1; $display("FAIL: no frame from the design"); end
            else begin
                // preamble (6 or 5 bytes of 0x55 after /S/), SFD, content, FCS
                i = 0; while (df[i] == 8'h55 && i < 8) i = i + 1;
                if (i < 5 || i > 6 || df[i] != 8'hD5) begin errors = errors + 1; $display("FAIL: preamble (%0d bytes)", i); end
                if (df_len != i + 1 + n + 4) begin errors = errors + 1; $display("FAIL: frame length %0d", df_len); end
                c = 32'hFFFFFFFF;
                for (k = 0; k < n; k = k + 1) begin
                    if (df[i+1+k] !== tf[k]) begin errors = errors + 1; $display("FAIL: tx byte %0d", k); end
                    c = crc_byte(c, df[i+1+k]);
                end
                c = ~c; w = {df[i+n+4], df[i+n+3], df[i+n+2], df[i+n+1]};
                if (w !== c) begin errors = errors + 1; $display("FAIL: FCS %h, expected %h", w, c); end
            end
            rd(16'h0024); if (rdv[4]) begin errors = errors + 1; $display("FAIL: tx_busy stuck"); end
        end

        // --- the partner restarts (sends configuration again): the design must follow and come back
        for (i = 0; i < 400; i = i + 1) p_cfg(16'h0000);
        rd(16'h0024); if (rdv[0]) begin errors = errors + 1; $display("FAIL: link still up during restart"); end
        n = 0;
        while (!(d_cfg_n >= 3 && d_cfg == (want | 16'h4000))) begin
            p_cfg(base | 16'h4000); n = n + 1;
            if (n > 20000) begin errors = errors + 1; $display("FAIL: no second negotiation"); $finish; end
        end
        for (i = 0; i < 1200; i = i + 1) p_cfg(base | 16'h4000);
        for (i = 0; i < 4000; i = i + 1) p_idle;
        rd(16'h0024); if (!rdv[0]) begin errors = errors + 1; $display("FAIL: link not up after restart"); end

        // --- dead line: link down
        rx_cut = 1; for (i = 0; i < 3000; i = i + 1) p_idle;
        rd(16'h0024); if (rdv[0]) begin errors = errors + 1; $display("FAIL: link up on a dead line"); end
        rd(16'h0008); if (rdv[4]) begin errors = errors + 1; $display("FAIL: aligner locked on a dead line"); end

        if (errors == 0) $display("PASS (%0d symbols of the design checked)", sym_n);
        else $display("FAILED: %0d errors", errors);
        $finish;
    end

    // Watchdog: 60 ms of simulated time.
    initial begin #60_000_000; $display("FAIL: timeout"); $finish; end
endmodule
