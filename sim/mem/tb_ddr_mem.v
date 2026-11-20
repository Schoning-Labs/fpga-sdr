// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Testbench for the memory bridge rtl/mem/ddr_mem.v, which connects the board's whole DDR3 (through Gowin's DDR3
// Memory Interface IP) to three clients: the CPU's data memory bus (AHB-Lite, 64 data lines), the read lane
// of the logic (video, audio, transmit ring) and the write lane of the logic (receiver rings, waterfall). The
// bench comes from an earlier design by the same author and was changed for fpga-sdr
// (docs/MEM_1GB.md section 5): our clocks, the write lane driven the way rtl/ddr3/ddr3_write_arbiter.v drives
// it, and tests 4 (the rates against our budget), 6 and 7.
//
// The DUT runs against a byte-wise reference memory (refm) in the bench, with the behavioral DDR3 IP
// (sim/mem/ddr3_ip_model.v, whose ready signals drop at random) behind it and four unrelated clocks, so that
// every clock crossing in the bridge is exercised. Every read is compared with the reference, and every write
// updates it. The seven tests:
//   1  the processor's bus: 4,000 random reads and writes of 1, 2, 4 and 8 bytes, single and as runs of
//      four beats with the next address given during the data phase (as a cache line fill does)
//   2  the read lane after the bus has rested: every line the processor wrote is in the memory
//      (bursts of 1 to 255 words from any word address)
//   3  the write lane (single words, bursts, masked words) and the read lane on it
//   4  all three at once: the processor in one region, the read lane with back-to-back bursts of 180 words
//      (the video reader's load, docs/F4_DDR.md), the write lane with back-to-back bursts of 4 words (the
//      receiver rings' load); the rates are printed and checked against docs/ARCHITECTURE.md 3.9
//   5  the top address: the line number that reaches the IP for byte address 0x3FFF_FFE0
//   6  the processor reads a word, the logic writes it, the processor reads it again and sees the new value
//   7  times: a cache line read by the processor (four beats, line not held), a word of the write lane
//
// Pass: no mismatch, no protocol fault counted by the IP model, the read and write lane rates above their
// budgets, and the top line reached the IP; the bench prints one line per test and then
// "PASS: ddr_mem (IP writes n, reads n)", otherwise FAIL lines.
//
// How to run: from the repository root,
//   iverilog -g2012 -o build/tb_ddr_mem.vvp sim/mem/tb_ddr_mem.v && vvp -n build/tb_ddr_mem.vvp
// Options: -DDDR_512MB (16 data line form), -DHCLK_HALF=<ns> (half period of the bus clock) and
// -DRD_KEEP=<n> (see below).
`timescale 1ns / 1ps
`include "rtl/mem/ddr_mem.v"
`include "rtl/ddr3/ddr3_wr_relay.v"
`include "rtl/ddr3/ddr3_rd_relay.v"
`include "sim/mem/ddr3_ip_model.v"

module tb_ddr_mem;
    // Four unrelated clocks: mem_clk is the DDR3 memory clock, clk_in the board reference of the IP's PLL, hclk
    // the CPU's data memory clock and lclk the logic's clock. The half periods are 1.25 ns (400 MHz), 10 ns
    // (50 MHz), 10.07 ns (49.65 MHz) and 3.337 ns (149.8 MHz); the last two are chosen so that they do not
    // line up with the others.
    reg mem_clk = 0, clk_in = 0, hclk = 0, lclk = 0;
    always #1.25  mem_clk = ~mem_clk;       // 400 MHz
    always #10    clk_in = ~clk_in;         // 50 MHz
`ifndef HCLK_HALF
`define HCLK_HALF 10.07
`endif
    always #(`HCLK_HALF) hclk = ~hclk;      // the AE350's data memory clock (50 MHz), not related
    always #3.337 lclk = ~lclk;             // the logic's clock (clk_dsp, 150 MHz), not related
    reg rstn = 0, hrstn = 0, lrst = 1;

    reg  [31:0] haddr = 0;
    reg  [2:0]  hsize = 0;
    reg  [1:0]  htrans = 0;
    reg         hwrite = 0;
    reg  [63:0] hwdata = 0;
    wire        hready, hresp, init;
    wire [63:0] hrdata;
    reg  [31:0] a4 = 0, a5 = 0;
    reg  [7:0]  m4 = 0;
    reg  [63:0] d4 = 0;
    reg         en4 = 0, en5 = 0;
    reg  [7:0]  b4 = 0, b5 = 0;
    wire        wait4, done4, valid5, rdy5, lrdy5;
    wire [31:0] la5; wire [7:0] lb5; wire len5;
    wire [31:0] ra4; wire [7:0] rm4, rb4; wire [63:0] rd4; wire ren4, rwait4, rdone4;
    wire [63:0] q5;
    wire [31:0] dq;
    wire [3:0]  dqs, dqsn;

    // -DDDR_512MB runs the bench on the form of the IP with 16 data lines (lines of 16 bytes); LB is the
    // number of bytes in a line. The chip itself uses the 32 line form.
`ifdef DDR_512MB
    localparam integer HALF = 1, LB = 16;
`else
    localparam integer HALF = 0, LB = 32;
`endif
`ifndef RD_KEEP
`define RD_KEEP 1
`endif
    // -DRD_KEEP=255 restores the earlier behavior, in which the line read for the processor is kept, and test 6
    // must then fail.
    ddr_mem #(.HALF(HALF), .RD_KEEP(`RD_KEEP)) dut (
        .ddr3_clk_in(clk_in), .ddr3_mem_clk(mem_clk), .ddr3_lock(1'b1), .ddr3_stop(), .rstn(rstn), .init(init),
        .DDR3_BANK(), .DDR3_CS_N(), .DDR3_RAS_N(), .DDR3_CAS_N(), .DDR3_WE_N(), .DDR3_CK(), .DDR3_CK_N(),
        .DDR3_CKE(), .DDR3_RESET_N(), .DDR3_ODT(), .DDR3_ADDR(), .DDR3_DM(), .DDR3_DQ(dq), .DDR3_DQS(dqs),
        .DDR3_DQS_N(dqsn),
        .hclk(hclk), .hrstn(hrstn), .haddr(haddr), .hsize(hsize), .htrans(htrans), .hwrite(hwrite),
        .hwdata(hwdata), .hready(hready), .hresp(hresp), .hrdata(hrdata),
        .lane_clk(lclk), .lane_rst(lrst),
        // As the write arbiter drives it: the request stays up until wr_done and is masked in that clock,
        // through the register stage rtl/ddr3/ddr3_wr_relay.v, as in sdr_core.v.
        .addr_lane4(ra4), .wr_mask_lane4(rm4), .wr_data_lane4(rd4), .wr_en_lane4(ren4),
        .burstcount_lane4(rb4), .wr_wait_lane4(rwait4), .wr_done_lane4(rdone4),
        .addr_lane5(la5), .rd_en_lane5(len5), .burstcount_lane5(lb5), .rd_valid_lane5(valid5),
        .rd_data_lane5(q5), .rd_rdy_lane5(lrdy5));

    // As in sdr_core.v the read lane sits behind rtl/ddr3/ddr3_rd_relay.v, and the driver sees the
    // relay's a_rdy as the lane's rd_rdy.
    ddr3_rd_relay u_rrelay (
        .clk(lclk), .rst(lrst),
        .a_addr(a5), .a_burst(b5), .a_en(en5), .a_rdy(rdy5),
        .l_addr(la5), .l_burst(lb5), .l_en(len5), .l_go(), .l_rdy(lrdy5));

    ddr3_wr_relay u_relay (
        .clk(lclk), .rst(lrst),
        .a_addr(a4), .a_mask(m4), .a_data(d4), .a_en(en4 && !done4), .a_go(1'b0), .a_burst(b4),
        .a_wait(wait4), .a_done(done4),
        .l_addr(ra4), .l_mask(rm4), .l_data(rd4), .l_en(ren4), .l_go(), .l_burst(rb4),
        .l_wait(rwait4), .l_done(rdone4));

    // The reference memory: the 131,072 bytes (4,096 lines of 32) of the model, kept byte by byte.
    localparam integer NB = 131072;         // bytes of the model's memory (4,096 lines)
    reg [7:0] refm [0:NB-1];
    integer errors = 0, i, k, n, t0, t1, rd_bytes, wr_bytes;
    real rd_rate, wr_rate;
    reg [31:0] seed = 32'hC0FFEE01;
    // A linear congruential generator (multiplier 1664525, increment 1013904223) gives the random values of the
    // test.
    function [31:0] rnd; input dummy; begin seed = seed * 32'd1664525 + 32'd1013904223; rnd = seed; end endfunction

    // ---------------------------------------------------------------- the processor's bus
    // ahb_run drives up to 4 AHB-Lite transfers back to back from the queue q_w (write), q_a (address), q_s
    // (size: 0 to 3 for 1, 2, 4 and 8 bytes), q_d (write data) and gives the read data in q_r. The address of
    // the next transfer is put on the bus during the data phase of the one before, as the processor does.
    reg [31:0] haddr_last = 0;
    reg        q_w  [0:3];
    reg [31:0] q_a  [0:3];
    reg [2:0]  q_s  [0:3];
    reg [63:0] q_d  [0:3];
    reg [63:0] q_r  [0:3];
    task ahb_run; input integer cnt; integer j; begin
        htrans <= 2'b10; haddr <= q_a[0]; hsize <= q_s[0]; hwrite <= q_w[0];
        @(posedge hclk); while (!hready) @(posedge hclk);
        for (j = 0; j < cnt; j = j + 1) begin
            hwdata <= q_d[j];
            if (j + 1 < cnt) begin htrans <= 2'b11; haddr <= q_a[j+1]; hsize <= q_s[j+1]; hwrite <= q_w[j+1]; end
            else begin htrans <= 2'b00; haddr <= 32'hFFFF_FFFF; hwrite <= 1'b0; end
            @(posedge hclk); while (!hready) @(posedge hclk);
            q_r[j] = hrdata;
            if (hresp) begin errors = errors + 1; $display("FAIL: hresp"); end
        end
    end endtask
    // Reference update (write) or check (read) of one beat, byte by byte on the 8-byte aligned lanes.
    task ref_beat; input integer j; integer bb, nbytes; reg [31:0] base; begin
        nbytes = 1 << q_s[j]; base = q_a[j] & ~(nbytes - 1);
        for (bb = 0; bb < nbytes; bb = bb + 1)
            if (q_w[j]) refm[(base + bb) % NB] = q_d[j][8*((base + bb) & 7) +: 8];
            else if (q_r[j][8*((base + bb) & 7) +: 8] !== refm[(base + bb) % NB]) begin
                errors = errors + 1;
                if (errors < 20) $display("FAIL: bus read %h byte %0d: got %h, want %h", q_a[j], bb,
                                          q_r[j][8*((base + bb) & 7) +: 8], refm[(base + bb) % NB]);
            end
    end endtask
    // ops random bus operations in the region from lo over span bytes: one in 16 is a run of four 64-bit beats
    // over one line (as a cache line fill), the others are single transfers, mostly near the previous address
    // (so that the bridge's line reuse is exercised) and sometimes anywhere, with an occasional idle pause.
    task bus_random; input integer ops; input [31:0] lo; input [31:0] span; integer o, j; reg [31:0] r, a; begin
        for (o = 0; o < ops; o = o + 1) begin
            r = rnd(0);
            if (r[3:0] == 4'd0) begin               // a run of four 64-bit beats over one line
                a = lo + ((rnd(0) % span) & ~32'd31);
                for (j = 0; j < 4; j = j + 1) begin
                    q_w[j] = r[4]; q_a[j] = a + 8 * ((j + r[6:5]) & 3); q_s[j] = 3'd3; q_d[j] = {rnd(0), rnd(0)};
                end
                ahb_run(4);
                for (j = 0; j < 4; j = j + 1) ref_beat(j);
            end else begin
                // near the last addresses most of the time, anywhere sometimes
                if (r[7:5] == 3'd0) a = lo + (rnd(0) % span);
                else a = lo + ((haddr_last + (rnd(0) % 96) - 32) % span);
                q_s[0] = r[9:8]; q_a[0] = a & ~((1 << q_s[0]) - 1); q_w[0] = r[10];
                q_d[0] = {rnd(0), rnd(0)};
                haddr_last = q_a[0] - lo;
                ahb_run(1);
                ref_beat(0);
                if (r[13:11] == 3'd0) repeat (r[19:14]) @(posedge hclk);
            end
        end
    end endtask

    // ---------------------------------------------------------------- the lanes
    // Read cnt words from word address `word` on the read lane (address and length held until rd_rdy), and
    // check each beat of the burst against the reference.
    task lane_read; input [31:0] word; input integer cnt; integer got, bb; begin
        a5 <= word; b5 <= cnt; en5 <= 1'b1;
        @(posedge lclk); while (!rdy5) @(posedge lclk);
        en5 <= 1'b0;
        got = 0;
        while (got < cnt) begin
            @(posedge lclk);
            if (valid5) begin
                for (bb = 0; bb < 8; bb = bb + 1)
                    if (q5[8*bb +: 8] !== refm[((word + got) * 8 + bb) % NB]) begin
                        errors = errors + 1;
                        if (errors < 20) $display("FAIL: lane read word %h byte %0d: got %h, want %h",
                                                  word + got, bb, q5[8*bb +: 8], refm[((word + got) * 8 + bb) % NB]);
                    end
                got = got + 1;
            end
        end
    end endtask
    integer extra_valid = 0;
    // As rtl/ddr3/ddr3_write_arbiter.v drives the lane: address and length held for the burst, wr_en up from the
    // first clock (no wr_go) until wr_done, the data of the next beat after each beat taken. A length of 0
    // counts as 1, and the mask has one bit per byte (1 = byte written).
    task lane_write; input [31:0] word; input integer cnt; input [7:0] mask; integer j, bb, tmo; reg [63:0] d; begin
        a4 <= word; b4 <= cnt; m4 <= mask;
        for (j = 0; j < ((cnt == 0) ? 1 : cnt); j = j + 1) begin
            d = {rnd(0), rnd(0)};
            d4 <= d; en4 <= 1'b1;
            @(posedge lclk); while (wait4) @(posedge lclk);
            for (bb = 0; bb < 8; bb = bb + 1) if (mask[bb]) refm[((word + j) * 8 + bb) % NB] = d[8*bb +: 8];
        end
        d4 <= 64'hBAD0_BAD0_BAD0_BAD0;          // never to be taken: the burst is over
        tmo = 0;
        while (!done4 && tmo < 2000) begin @(posedge lclk); tmo = tmo + 1; end
        if (!done4) begin errors = errors + 1; $display("FAIL: no wr_done"); end
        en4 <= 1'b0; a4 <= 32'h0BAD_0BAD;
        @(posedge lclk);
    end endtask

    // Test 5 watches the IP's command bus for a write to line 0x1FFFFFF, the last line of the 1 GB.
    reg [24:0] top_line = 0;
    reg        top_seen = 0;
    always @(posedge dut.clk_m) if (dut.cmd_en && dut.cmd == 3'b000 && dut.addr[27:3] == 25'h1FF_FFFF) top_seen <= 1'b1;

    reg stop_bus = 0, bus_done = 0;
    initial begin
        // The model's start content: line i holds eight words of 0xDEAD0000 + i.
        for (i = 0; i < NB; i = i + 1) begin
            k = 32'hDEAD_0000 + ((i / LB) & 16'hFFFF);
            refm[i] = k[8*(i % 4) +: 8];
        end
        // Reset: release the IP's reset, wait for its calibration to complete, then release the bus and lane
        // resets.
        #200 rstn = 1;
        wait (init);
        repeat (20) @(posedge hclk);
        hrstn = 1; lrst = 0;
        repeat (20) @(posedge hclk);

        // 1: random bus accesses over the first 64 KB
        bus_random(4000, 32'd0, 32'd65536);
        $display("1: bus, %0d errors so far; IP writes %0d, reads %0d", errors, dut.u_ddr3.n_wr, dut.u_ddr3.n_rd);
        // 2: the bus rests (more than 256 clocks), then everything it wrote is in the memory
        repeat (400) @(posedge hclk);
        for (i = 0; i < 65536; i = i + 1)
            if (dut.u_ddr3.mem[i / LB][8*(i % LB) +: 8] !== refm[i]) begin
                errors = errors + 1; if (errors < 20) $display("FAIL: memory byte %h after the rest", i);
            end
        for (n = 0; n < 60; n = n + 1) lane_read(rnd(0) % 8000, 1 + (rnd(0) % 70));
        lane_read(32'd3, 255);
        lane_read(32'd8190, 1);
        $display("2: read lane after the rest, %0d errors so far", errors);
        // 3: the write lane, in a region the processor's line is not in
        for (n = 0; n < 40; n = n + 1) lane_write(32'd9000 + (rnd(0) % 3000), 1, 8'hFF);
        lane_write(32'd9101, 3, 8'hFF);
        lane_write(32'd9200, 1, 8'b1100_0011);
        lane_write(32'd9203, 2, 8'b0010_1101);
        lane_write(32'd9302, 9, 8'hFF);
        lane_write(32'd9311, 4, 8'hFF);         // back to back with the burst before
        lane_write(32'd9400, 0, 8'hFF);         // length 0 counts as 1
        for (n = 0; n < 30; n = n + 1) lane_read(32'd9000 + (rnd(0) % 3000), 1 + (rnd(0) % 40));
        lane_read(32'd9098, 12); lane_read(32'd9198, 10); lane_read(32'd9298, 20); lane_read(32'd9398, 6);
        // and the processor reads what the lane wrote
        q_w[0] = 0; q_a[0] = 9101 * 8; q_s[0] = 3; ahb_run(1); ref_beat(0);
        q_w[0] = 0; q_a[0] = 9200 * 8 + 4; q_s[0] = 2; ahb_run(1); ref_beat(0);
        $display("3: write lane, %0d errors so far", errors);
        // 4: all three at once
        rd_bytes = 0; wr_bytes = 0;
        fork
            begin t0 = $time; bus_random(3000, 32'd0, 32'd32768); bus_done = 1; t1 = $time; end
            begin
                while (!bus_done) begin
                    lane_read(32'd12000 + 180 * (rd_bytes / 1440 % 8), 180);
                    if (!bus_done) rd_bytes = rd_bytes + 1440;
                end
            end
            begin
                while (!bus_done) begin
                    lane_write(32'd14000 + 4 * (wr_bytes / 32 % 400), 4, 8'hFF);
                    if (!bus_done) wr_bytes = wr_bytes + 32;
                end
            end
        join
        rd_rate = rd_bytes * 1000.0 / (t1 - t0); wr_rate = wr_bytes * 1000.0 / (t1 - t0);
        $display("4: all at once, %0d errors so far; read lane %0.0f MB/s (budget 374), write lane %0.1f MB/s (budget 26.4 without raw capture), bus: 3,000 accesses in %0d us",
                 errors, rd_rate, wr_rate, (t1 - t0) / 1000);
        // The read lane must reach the video budget of 374 MB/s and the write lane 26.4 MB/s (without the raw
        // capture) of docs/ARCHITECTURE.md 3.9, while the bus is busy.
        if (rd_rate < 374.0) begin errors = errors + 1; $display("FAIL: the read lane is below the video budget"); end
        if (wr_rate < 26.4)  begin errors = errors + 1; $display("FAIL: the write lane is below its budget"); end
        for (n = 0; n < 20; n = n + 1) lane_read(32'd14000 + (rnd(0) % 1500), 1 + (rnd(0) % 90));
        // 5: the top of the 1 GB (with the 16-line form the last line is at 0x1FFF_FFF0), written by the
        // processor, followed by an access to another address
        q_w[0] = 1; q_a[0] = HALF ? 32'h1FFF_FFF0 : 32'h3FFF_FFE0; q_s[0] = 3; q_d[0] = 64'h0123_4567_89AB_CDEF; ahb_run(1);
        q_w[0] = 0; q_a[0] = 32'h0000_0100; q_s[0] = 3; ahb_run(1);
        repeat (40) @(posedge hclk);
        // 6: the logic writes a word the processor has just read (the earlier bridge gave the old value)
        for (n = 0; n < 12; n = n + 1) begin
            q_w[0] = 0; q_a[0] = (15000 + n) * 8; q_s[0] = 3; ahb_run(1); ref_beat(0);
            lane_write(32'd15000 + n, 1, 8'hFF);
            if (n[0]) repeat (n) @(posedge hclk);
            q_w[0] = 0; q_a[0] = (15000 + n) * 8; q_s[0] = 3; ahb_run(1); ref_beat(0);
        end
        // ... and a line the processor has written in part: both parts are there afterwards
        q_w[0] = 1; q_a[0] = 15100 * 8; q_s[0] = 3; q_d[0] = 64'h1111_2222_3333_4444; ahb_run(1); ref_beat(0);
        lane_write(32'd15101, 1, 8'hFF);
        q_w[0] = 0; q_a[0] = 15101 * 8; q_s[0] = 3; ahb_run(1); ref_beat(0);
        q_w[0] = 0; q_a[0] = 15100 * 8; q_s[0] = 3; ahb_run(1); ref_beat(0);
        lane_read(32'd15100, 2);
        $display("6: processor read, logic write, processor read: %0d errors so far", errors);
        // 7: times, everything else at rest
        repeat (400) @(posedge hclk);
        for (k = 0; k < 4; k = k + 1) begin q_w[k] = 0; q_a[k] = 16000 * 8 + 8 * k; q_s[k] = 3'd3; end
        t0 = $time; ahb_run(4); t1 = $time;
        for (k = 0; k < 4; k = k + 1) ref_beat(k);
        $display("7: a cache line (4 beats, 32 bytes) read by the processor: %0d ns at a bus clock of %0.1f MHz", t1 - t0, 500.0 / `HCLK_HALF);
        t0 = $time; lane_write(32'd16100, 64, 8'hFF); t1 = $time;
        $display("7: write lane alone: 64 words in %0d ns = %0.0f MB/s", t1 - t0, 512000.0 / (t1 - t0));
        t0 = $time; lane_read(32'd16100, 180); t1 = $time;
        $display("7: read lane alone: 180 words in %0d ns = %0.0f MB/s", t1 - t0, 1440000.0 / (t1 - t0));
        if (!top_seen) begin errors = errors + 1; $display("FAIL: line 0x1FFFFFF did not reach the IP"); end
        if (dut.u_ddr3.errors != 0) begin errors = errors + dut.u_ddr3.errors; $display("FAIL: the IP model saw %0d faults", dut.u_ddr3.errors); end
        if (extra_valid != 0) begin errors = errors + 1; $display("FAIL: rd_valid outside a burst"); end
        if (errors == 0) $display("PASS: ddr_mem (IP writes %0d, reads %0d)", dut.u_ddr3.n_wr, dut.u_ddr3.n_rd);
        else $display("FAIL: ddr_mem, %0d errors", errors);
        $finish;
    end
    // Watchdog: 400 ms of simulated time.
    initial begin #400_000_000; $display("FAIL: ddr_mem timeout"); $finish; end
endmodule
