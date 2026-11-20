// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Testbench for the output rings of the receiver back end, rtl/rx_backend/bk_ring.v, which rx_backend.v
// contains. Each receiver's output samples (16-bit audio, or I and Q pairs) are written into a ring of
// slots in DDR3 memory, one slot for every block of 128 samples, so that the CPU can pick up finished
// blocks later without any work per sample. A slot holds 2 header words and then the payload in 64-bit
// lane words (4 audio samples or 2 IQ pairs per word), which makes 34 words for audio and 66 for IQ.
// Header word 0 carries the HL2 stamp of the block's first sample, the receiver number and an IQ flag,
// header word 1 the block sequence number and the S-meter at the end of the block. The DDR3 side is the
// behavioural write lane sim/ddr3/ddr3_lane_behav_model.v, which stalls at random (6 % of the idle
// clocks start a stall of up to 12 clocks), so the writer has to cope with a lane that is not always ready.
//
// Part 1 tests bk_ring alone. Three receivers' output streams (audio, IQ, audio) are fed at a high rate
// into rings of 4 slots, 7 blocks each, so that the rings wrap around. Afterwards every header and
// payload word of the 4 slots still in each ring must be what the stream says, ring_wptr must count
// the completed blocks, and block_done must pulse once per block (which it may only do after the
// block's header has landed, since the firmware reads a slot as soon as it sees the pointer move).
// Disabling a ring must reset its pointer.
//
// Part 2 tests the whole rx_backend with one IQ receiver (an identity filter, 48 ksps in, 24 ksps out)
// whose ring is enabled and subscribed to the interrupt. After 3 blocks the ring_wptr register must
// read 3, the interrupt must be up, irq_status must show the receiver's bit and clear when a 1 is
// written to it, and the 2 slots of the ring must hold the last two blocks of the output stream with
// the right stamps and sequence numbers.
//
// Pass: no check fails and no FIFO overflow flag is set; the bench prints "part 1: ..." and "part 2: ..."
// lines and then PASS, or FAIL lines with the expected and actual words followed by "FAIL: n errors".
//
// How to run: from the repository root, `iverilog -g2012 -o tb.vvp sim/rx_backend/tb_rx_backend_ring.v`
// and `vvp tb.vvp` (tools/check.sh runs it with the other benches).

`timescale 1ns / 1ps
`include "rtl/rx_backend/bk_mul.v"
`include "rtl/rx_backend/bk_ram.v"
`include "rtl/rx_backend/bk_rom.v"
`include "rtl/rx_backend/bk_fifo.v"
`include "rtl/rx_backend/bk_front.v"
`include "rtl/rx_backend/bk_decim.v"
`include "rtl/rx_backend/bk_chfilt.v"
`include "rtl/rx_backend/bk_cordic.v"
`include "rtl/rx_backend/bk_post.v"
`include "rtl/rx_backend/bk_ring.v"
`include "rtl/rx_backend/rx_backend.v"
`include "sim/ddr3/ddr3_lane_behav_model.v"

// Number of receivers built: -DTB_NRX=<n> (default 8); the three receivers of part 1 move below
// receiver 4 when n <= 4.
`ifndef TB_NRX
`define TB_NRX 8
`endif

module tb_rx_backend_ring;
    localparam integer NRX = `TB_NRX;
    // Half period 3.333 ns makes a 6.666 ns period, the 150 MHz DSP clock of the chip.
    reg clk = 1'b0;
    always #3.333 clk = ~clk;
    reg rst = 1'b1;
    integer errors = 0;

    // ================================================================ part 1: bk_ring alone
    // Samples go straight into bk_ring (in_valid with receiver, two 16-bit values, IQ flag and stamp),
    // ring_base, ring_log2 and ring_en hold the settings of all receivers side by side (32 bits, 4 bits
    // and 1 bit each), and ring_wptr and block_done are its results.
    reg         in_valid = 1'b0;
    reg  [2:0]  in_rx = 3'd0;
    reg  [15:0] in_s0 = 16'd0, in_s1 = 16'd0;
    reg         in_iq = 1'b0;
    reg  [47:0] in_stamp = 48'd0;
    reg  [255:0] ring_base = 256'd0;
    reg  [31:0]  ring_log2 = 32'd0;
    reg  [7:0]   ring_en = 8'd0;
    wire [255:0] ring_wptr;
    wire [7:0]   block_done;
    wire         ovf;
    wire         req1, gnt1, done1;
    wire [31:0]  addr1;
    wire [7:0]   bl1, wm1;
    wire [63:0]  wd1;
    wire         wr_wait1, wr_done1;
    wire         wr_en1 = req1 && !wr_done1;
    assign gnt1  = wr_en1 && !wr_wait1;
    assign done1 = wr_done1;

    wire [2:0]   ring_crx;                   // receiver whose ring base bk_ring wants to read; rx_backend keeps the bases in a memory, so the bench picks the field by this index
    bk_ring #(.NRX(NRX)) u_ring (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_rx(in_rx), .in_s0(in_s0), .in_s1(in_s1), .in_iq(in_iq),
        .in_stamp(in_stamp), .smeter({8{16'hFABC}}),
        .cfg_rx(ring_crx), .ring_base(ring_base[ring_crx*32 +: 32]), .ring_log2(ring_log2), .ring_en(ring_en),
        .ring_wptr(ring_wptr), .block_done(block_done), .overflow(ovf),
        .req(req1), .addr(addr1), .burstlen(bl1), .wdata(wd1), .wmask(wm1), .gnt(gnt1), .done(done1)
    );
    // DDR3 write lane the ring writer is connected to. gnt is given while a request is up and the lane is
    // not stalling, and done comes from the lane when the write has landed in the array u_lane1.mem.
    ddr3_lane_behav_model #(.MEM_WORDS(8192), .STALL_NUM(60), .STALL_DEN(1000), .STALL_MAX_CYCLES(12),
                            .SEED(32'h0B10_C4ED)) u_lane1 (
        .clk(clk), .rst(rst),
        .addr_lane4(addr1), .wr_mask_lane4(wm1), .wr_data_lane4(wd1), .wr_en_lane4(wr_en1),
        .wr_go_lane4(1'b0), .burstcount_lane4(bl1), .wr_wait_lane4(wr_wait1), .wr_done_lane4(wr_done1),
        .addr_lane5(32'd0), .rd_en_lane5(1'b0), .rd_go_lane5(1'b0), .burstcount_lane5(8'd0),
        .rd_valid_lane5(), .rd_data_lane5(), .rd_rdy_lane5(), .phys_busy()
    );

    // What was sent to each of the three receivers (the two 16-bit values packed as {s1, s0}) and the
    // stamp of each sample, as the reference for the payload and header words.
    // sent samples: stream[rx][n] = {s1, s0}, stamps
    reg [31:0] sent  [0:2][0:1279];
    reg [47:0] sstmp [0:2][0:1279];
    integer    nsent [0:2];
    integer    ndone [0:7];
    // Counts the block_done pulses of each receiver.
    always @(posedge clk) begin : cnt_done
        integer j;
        for (j = 0; j < 8; j = j + 1)
            if (block_done[j]) ndone[j] = ndone[j] + 1;
    end

    // Part 1 receivers: audio on RXA, IQ on RXB, audio on RXC, picked below 4 when fewer receivers are built.
    localparam [2:0] RXA = 3'd1, RXB = (NRX > 4) ? 3'd4 : 3'd2, RXC = (NRX > 4) ? 3'd6 : 3'd3;   // audio, IQ, audio
    function [2:0] rx_of; input integer i; rx_of = (i == 0) ? RXA : (i == 1) ? RXB : RXC; endfunction

    // ================================================================ part 2: the whole back end
    // Input stream, register port and ring lane of the complete back end, a second lane model so the two
    // parts do not share memory.
    reg         b_valid = 1'b0;
    reg  [2:0]  b_index = 3'd0;
    reg  [23:0] b_i = 24'd0, b_q = 24'd0;
    reg  [47:0] hl2_index = 48'h00AB_0000_0000;
    reg         reg_wr = 1'b0, reg_rd = 1'b0;
    reg  [15:0] reg_addr = 16'd0;
    reg  [31:0] reg_wdata = 32'd0;
    wire [31:0] reg_rdata;
    wire        o_valid, o_iq, irq;
    wire [2:0]  o_rx;
    wire [15:0] o_s0, o_s1;
    wire [47:0] o_stamp;
    wire        req2, gnt2, done2;
    wire [31:0] addr2;
    wire [7:0]  bl2, wm2;
    wire [63:0] wd2;
    wire        wr_wait2, wr_done2;
    wire        wr_en2 = req2 && !wr_done2;
    assign gnt2  = wr_en2 && !wr_wait2;
    assign done2 = wr_done2;

    rx_backend #(.NRX(NRX)) dut (
        .clk(clk), .rst(rst),
        .in_valid(b_valid), .in_index(b_index), .in_i(b_i), .in_q(b_q), .hl2_index(hl2_index),
        .reg_wr(reg_wr), .reg_rd(reg_rd), .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_rdata(reg_rdata),
        .out_valid(o_valid), .out_rx(o_rx), .out_s0(o_s0), .out_s1(o_s1), .out_iq(o_iq), .out_stamp(o_stamp),
        .ring_req(req2), .ring_addr(addr2), .ring_burstlen(bl2), .ring_wdata(wd2), .ring_wmask(wm2),
        .ring_gnt(gnt2), .ring_done(done2), .irq(irq)
    );
    // Same lane model as above with another random seed, for part 2.
    ddr3_lane_behav_model #(.MEM_WORDS(4096), .STALL_NUM(60), .STALL_DEN(1000), .STALL_MAX_CYCLES(12),
                            .SEED(32'h0B10_C4EE)) u_lane2 (
        .clk(clk), .rst(rst),
        .addr_lane4(addr2), .wr_mask_lane4(wm2), .wr_data_lane4(wd2), .wr_en_lane4(wr_en2),
        .wr_go_lane4(1'b0), .burstcount_lane4(bl2), .wr_wait_lane4(wr_wait2), .wr_done_lane4(wr_done2),
        .addr_lane5(32'd0), .rd_en_lane5(1'b0), .rd_go_lane5(1'b0), .burstcount_lane5(8'd0),
        .rd_valid_lane5(), .rd_data_lane5(), .rd_rdy_lane5(), .phys_busy()
    );

    // Register write, one clock wide.
    task wr(input [15:0] a, input [31:0] d);
        begin
            @(posedge clk); reg_wr <= 1'b1; reg_addr <= a; reg_wdata <= d;
            @(posedge clk); reg_wr <= 1'b0;
        end
    endtask
    task rd(input [15:0] a, output [31:0] d);
        begin
            @(posedge clk); reg_rd <= 1'b1; reg_addr <= a;
            @(posedge clk); reg_rd <= 1'b0;
            @(posedge clk);
            // Five extra clocks of waiting: the DUT registers the bus once, latches the read address,
            // and its read multiplexer takes two clocks per step (first by receiver, then by field) as
            // two-clock paths (see "register bus" in rx_backend.v), so read data is valid six clocks
            // after reg_rd, not one.
            repeat (3) @(posedge clk);
            @(posedge clk);
            @(posedge clk); d = reg_rdata;
        end
    endtask

    // Output samples of receiver 2 as they leave the back end, with their stamps, as the reference for
    // the payload and header words that part 2 finds in memory.
    reg [31:0] out2 [0:1023];
    reg [47:0] ost2 [0:1023];
    integer    nout2 = 0;
    always @(posedge clk)
        if (o_valid && o_rx == 3'd2) begin
            out2[nout2] = {o_s1, o_s0};
            ost2[nout2] = o_stamp;
            nout2 = nout2 + 1;
        end

    // ================================================================ checks
    // Start address of a slot: the block number modulo the ring size (2^lg slots) times the slot length,
    // 66 words for IQ and 34 for audio, plus the ring's base address.
    function [31:0] slot_base;
        input [31:0] base;
        input integer slot;
        input integer lg;
        input integer iq;
        integer s;
        begin
            s = slot % (1 << lg);
            slot_base = base + s * (iq ? 66 : 34);
        end
    endfunction

    // expected payload word w (0-based) of block b from a stream: for audio four samples of 16 bits,
    // the first in the lowest bits; for IQ two {s1, s0} pairs, the first in the lower half
    reg [63:0] ew;
    reg [15:0] s0v, s1v;
    integer i, n, b, w, s, blocks, nb, iq;
    reg [31:0] base, v;
    reg [63:0] got;
    reg [47:0] st;
    integer feed;
    initial begin
        for (i = 0; i < 8; i = i + 1) ndone[i] = 0;
        for (i = 0; i < 3; i = i + 1) nsent[i] = 0;
        repeat (5) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);

        // ------------------------------------------------ part 1
        // Ring settings: three rings of 4 slots (log2 = 2) at different base addresses, then enable them.
        ring_base[RXA*32 +: 32] = 32'd100;   ring_log2[RXA*4 +: 4] = 4'd2;
        ring_base[RXB*32 +: 32] = 32'd1000;  ring_log2[RXB*4 +: 4] = 4'd2;
        ring_base[RXC*32 +: 32] = 32'd2000;  ring_log2[RXC*4 +: 4] = 4'd2;
        ring_en = (8'd1 << RXA) | (8'd1 << RXB) | (8'd1 << RXC);
        repeat (3) @(posedge clk);
        blocks = 7;                          // 7 blocks each: the 4-slot rings wrap
        // 7 blocks of 128 samples for each receiver, one sample per receiver in turn with 6 idle clocks
        // after each, so the three streams interleave the way the receiver outputs do.
        for (n = 0; n < blocks * 128; n = n + 1)
            for (i = 0; i < 3; i = i + 1) begin
                @(posedge clk);
                in_valid <= 1'b1;
                in_rx    <= rx_of(i);
                in_iq    <= (i == 1);
                s0v      = n * 7 + i * 1000;
                s1v      = (i == 1) ? n * 13 + 5 : 0;
                in_s0    <= s0v;
                in_s1    <= s1v;
                in_stamp <= 48'h0001_0000_0000 * i + n * 6400 + 17;
                sent[i][n]  = {s1v, s0v};
                sstmp[i][n] = 48'h0001_0000_0000 * i + n * 6400 + 17;
                @(posedge clk);
                in_valid <= 1'b0;
                repeat (6) @(posedge clk);
            end
        // Let the last blocks drain through the lane before looking at memory.
        repeat (3000) @(posedge clk);

        // Check each ring: the pointer and the block_done count first, then the last 4 blocks (which are
        // the ones still in a 4-slot ring), each with both header words and every payload word.
        for (i = 0; i < 3; i = i + 1) begin
            iq = (i == 1);
            base = ring_base[rx_of(i)*32 +: 32];
            if (ring_wptr[rx_of(i)*32 +: 32] != blocks || ndone[rx_of(i)] != blocks) begin
                $display("FAIL part 1 rx%0d: ring_wptr %0d, block_done pulses %0d, expected %0d",
                         rx_of(i), ring_wptr[rx_of(i)*32 +: 32], ndone[rx_of(i)], blocks);
                errors = errors + 1;
            end
            for (b = blocks - 4; b < blocks; b = b + 1) begin
                s = slot_base(base, b, 2, iq);
                // header word 0: stamp of the block's first sample in bits 47:0, receiver in 50:48,
                // IQ flag in bit 56
                got = u_lane1.mem[s];
                if (got !== {7'd0, iq[0], 5'd0, rx_of(i), sstmp[i][b*128]}) begin
                    $display("FAIL part 1 rx%0d block %0d: header word 0 %016x", rx_of(i), b, got);
                    errors = errors + 1;
                end
                // header word 1: block sequence number in bits 31:0 and the S-meter (16'hFABC, which
                // the bench holds on the input) in bits 47:32
                got = u_lane1.mem[s + 1];
                if (got !== {16'd0, 16'hFABC, b[31:0]}) begin
                    $display("FAIL part 1 rx%0d block %0d: header word 1 %016x", rx_of(i), b, got);
                    errors = errors + 1;
                end
                for (w = 0; w < (iq ? 64 : 32); w = w + 1) begin
                    if (iq)
                        ew = {sent[i][b*128 + 2*w + 1], sent[i][b*128 + 2*w]};
                    else
                        ew = {sent[i][b*128 + 4*w + 3][15:0], sent[i][b*128 + 4*w + 2][15:0],
                              sent[i][b*128 + 4*w + 1][15:0], sent[i][b*128 + 4*w][15:0]};
                    got = u_lane1.mem[s + 2 + w];
                    if (got !== ew) begin
                        if (errors < 10)
                            $display("FAIL part 1 rx%0d block %0d word %0d: %016x, expected %016x", rx_of(i), b, w, got, ew);
                        errors = errors + 1;
                    end
                end
            end
        end
        // Disabling a ring resets its pointer.
        ring_en = 8'd0;
        repeat (3) @(posedge clk);
        if (ring_wptr[RXA*32 +: 32] != 0) begin
            $display("FAIL part 1: ring_wptr not reset by disable");
            errors = errors + 1;
        end
        $display("part 1: 3 rings x %0d blocks written through a stalling lane, last 4 slots of each checked", blocks);

        // Part 2 settings: coefficient bank 0 of unit 0 as a one-tap identity filter, the ring of
        // receiver 2 at base 300 with 2 slots, its interrupt enabled, then the receiver itself.
        // ------------------------------------------------ part 2
        wr(`RX_BACKEND_COEF_SEL_ADDR, 32'd0);                 // unit 0, bank 0: identity
        wr(`RX_BACKEND_BANK_CFG_ADDR(0), 32'd1);
        wr(`RX_BACKEND_COEF_OFFSET, 32'h4000_0000);
        wr(`RX_BACKEND_COEF_OFFSET + 4, 32'd0);
        wr(`RX_BACKEND_RING_BASE_ADDR(2), 32'd300);
        wr(`RX_BACKEND_RING_SLOTS_ADDR(2), 32'd1);            // 2 slots
        wr(`RX_BACKEND_RING_CTRL_ADDR(2), 32'd1);
        wr(`RX_BACKEND_IRQ_ENABLE_ADDR, 32'h04);
        // IQ (mode 4), 24 ksps out, 48 ksps in, shift 0, AGC off (manual gain 0 dB), enabled
        wr(`RX_BACKEND_CTRL_ADDR(2), (32'd4 << `RX_BACKEND_CTRL_MODE_LSB) | (32'd1 << `RX_BACKEND_CTRL_OUT24_LSB) | 32'd1);
        // One bank sample for receiver 2 every 64 clocks; 768 samples give 384 outputs at 24 ksps,
        // which is 3 blocks of 128.
        feed = 0;
        while (feed < 64 * 768) begin               // 768 bank samples = 384 outputs = 3 blocks
            @(posedge clk);
            hl2_index <= hl2_index + 1;
            b_valid <= 1'b0;
            if ((feed % 64) == 63) begin
                b_valid <= 1'b1;
                b_index <= 3'd2;
                b_i <= (feed * 131) & 24'h7FFFFF;
                b_q <= -((feed * 77) & 24'h3FFFFF);
            end
            feed = feed + 1;
        end
        @(posedge clk);
        b_valid <= 1'b0;
        repeat (2000) @(posedge clk);
        // The ring pointer register reads 3 and the interrupt line is up.
        rd(`RX_BACKEND_RING_WPTR_ADDR(2), v);
        if (v != 3 || !irq) begin
            $display("FAIL part 2: ring_wptr register %0d (expected 3), irq %b", v, irq);
            errors = errors + 1;
        end
        // irq_status shows receiver 2's bit, writing a 1 to it clears the bit and the line.
        rd(`RX_BACKEND_IRQ_STATUS_ADDR, v);
        if (v != 32'h04) begin
            $display("FAIL part 2: irq_status %08x", v);
            errors = errors + 1;
        end
        wr(`RX_BACKEND_IRQ_STATUS_ADDR, 32'h04);
        @(posedge clk);
        rd(`RX_BACKEND_IRQ_STATUS_ADDR, v);
        if (v != 0 || irq) begin
            $display("FAIL part 2: irq_status %08x after clearing, irq %b", v, irq);
            errors = errors + 1;
        end
        // Blocks 1 and 2 are the two slots still in the ring (slot = block modulo 2): header word 0 must
        // carry the stamp of the block's first output sample and header word 1 the sequence number, and
        // every payload word must be the output stream of the same block.
        for (b = 1; b < 3; b = b + 1) begin
            s = 300 + (b % 2) * 66;
            got = u_lane2.mem[s];
            if (got !== {7'd0, 1'b1, 5'd0, 3'd2, ost2[b*128]}) begin
                $display("FAIL part 2 block %0d: header word 0 %016x, first stamp %012x", b, got, ost2[b*128]);
                errors = errors + 1;
            end
            if (u_lane2.mem[s + 1][31:0] !== b) begin
                $display("FAIL part 2 block %0d: sequence %0d", b, u_lane2.mem[s + 1][31:0]);
                errors = errors + 1;
            end
            for (w = 0; w < 64; w = w + 1) begin
                ew = {out2[b*128 + 2*w + 1], out2[b*128 + 2*w]};
                if (u_lane2.mem[s + 2 + w] !== ew) begin
                    if (errors < 10)
                        $display("FAIL part 2 block %0d word %0d: %016x, expected %016x", b, w, u_lane2.mem[s + 2 + w], ew);
                    errors = errors + 1;
                end
            end
        end
        // No FIFO overflow flag, neither in the status register nor from the ring writer.
        rd(`RX_BACKEND_STATUS_ADDR, v);
        if (v != 0 || ovf) begin
            $display("FAIL: overflow flags %b / %b", v[3:0], ovf);
            errors = errors + 1;
        end
        $display("part 2: rx_backend ring of one IQ receiver, 3 blocks, register pointer and interrupt checked");
        if (errors == 0) $display("PASS"); else $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
