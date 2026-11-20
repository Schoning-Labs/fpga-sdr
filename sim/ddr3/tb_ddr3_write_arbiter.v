// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Testbench for rtl/ddr3/ddr3_write_arbiter.v, the module that puts the fabric's DDR3 writers (the IQ writer,
// the waterfall writer and the raw capture writer, plus a fourth tied off here) onto the single DDR3 write
// lane. This one checks that no data is lost or corrupted on the way. The order in which the arbiter picks
// between clients is a separate question, tested with saturating traffic in
// sim/ddr3/tb_ddr3_write_arbiter_priority.v.
//
// Stimulus: three sim/ddr3/write_traffic_client.v instances run at the same time at their own realistic request
// rate (bursts of 4, 8 and 8 words every 130, 32,000 and 42 clocks, the bandwidths in docs/F4_DDR.md
// section 3), each into its own region of memory, through the arbiter into sim/ddr3/ddr3_lane_behav_model.v
// with random stalls switched on (3 percent of idle clocks, runs of up to 6 clocks). Every word a client
// writes has the value `{A, ~A}` for its address A, so what ought to be in memory can be recomputed from
// the address alone. The clients run for 60,000 clocks (600 us at 100 MHz), which gives hundreds of bursts
// from the two faster ones and a couple of bursts from the waterfall client, whose period is 32,000 clocks.
//
// Checks: every word of every burst each client reported as done is read from the lane model's memory
// with `peek` and compared with the pattern, and a handful of IQ addresses are then read back through the
// real read lane port of the same model (`rd_en_lane5`) to show that a normal read sees the same data. It
// also fails if any client never completed a burst, since a test in which nothing was written would pass
// the data check without proving anything.
//
// Passing: the last line is "PASS", otherwise "FAIL: ..." lines and "FAIL: <n> error(s)" are printed, or
// "FAIL: timeout" after 20 ms of simulated time. Run it from the repository root, the include paths are
// relative to it:
//   iverilog -g2012 -o sim/out/tb_ddr3_write_arbiter.vvp sim/ddr3/tb_ddr3_write_arbiter.v && vvp -n sim/out/tb_ddr3_write_arbiter.vvp
// or all testbenches together with tools/check.sh. Terms such as burst, lane and arbiter are explained in
// docs/learn/GLOSSARY.md.

`timescale 1ns / 1ps
`include "rtl/ddr3/ddr3_write_arbiter.v"
`include "sim/ddr3/ddr3_lane_behav_model.v"
`include "sim/ddr3/write_traffic_client.v"

module tb_ddr3_write_arbiter;

    localparam integer ADDR_WIDTH = 32;
    localparam integer DATA_WIDTH = 64;

    reg clk = 0;
    reg rst = 1;
    always #5 clk = ~clk; // 100 MHz fabric R/W clock (docs/ARCHITECTURE.md section 2)

    // -------- three write clients, separate address regions, realistic request rate --------
    // Bandwidth derivation (docs/F4_DDR.md section 3), all at the 100 MHz lane clock with 8 bytes per word:
    //   IQ writer:    24.6 MB/s, 4-word (32 B) bursts -> a burst every 32 B / 24.6 MB/s  = about 130 clocks
    //   waterfall:     0.2 MB/s, 8-word (64 B) bursts -> a burst every 64 B / 0.2 MB/s   = about 32,000 clocks
    //   raw capture: 153.6 MB/s, 8-word (64 B) bursts -> a burst every 64 B / 153.6 MB/s = about 42 clocks
    wire iq_req, wf_req, cap_req;
    wire [ADDR_WIDTH-1:0] iq_addr, wf_addr, cap_addr;
    wire [7:0] iq_burstlen, wf_burstlen, cap_burstlen;
    wire [DATA_WIDTH-1:0] iq_wdata, wf_wdata, cap_wdata;
    wire [7:0] iq_wmask, wf_wmask, cap_wmask;
    wire iq_gnt, wf_gnt, cap_gnt, iq_done, wf_done, cap_done;
    wire [63:0] iq_words_done, wf_words_done, cap_words_done;
    wire [31:0] iq_bursts_done, wf_bursts_done, cap_bursts_done;
    wire [31:0] iq_max_wait, wf_max_wait, cap_max_wait;

    // Switches all three clients on and off together.
    reg clients_enable;

    write_traffic_client #(.BASE_ADDR(32'h0000_0000), .RING_WORDS(4096), .BURSTLEN(4),
                            .PERIOD_CYCLES(130)) u_iq (
        .clk(clk), .rst(rst), .enable(clients_enable),
        .req(iq_req), .addr(iq_addr), .burstlen(iq_burstlen), .wdata(iq_wdata), .wmask(iq_wmask),
        .gnt(iq_gnt), .done(iq_done), .words_done(iq_words_done), .bursts_done(iq_bursts_done),
        .max_wait_cycles(iq_max_wait));

    write_traffic_client #(.BASE_ADDR(32'h0001_0000), .RING_WORDS(4096), .BURSTLEN(8),
                            .PERIOD_CYCLES(32000)) u_wf (
        .clk(clk), .rst(rst), .enable(clients_enable),
        .req(wf_req), .addr(wf_addr), .burstlen(wf_burstlen), .wdata(wf_wdata), .wmask(wf_wmask),
        .gnt(wf_gnt), .done(wf_done), .words_done(wf_words_done), .bursts_done(wf_bursts_done),
        .max_wait_cycles(wf_max_wait));

    write_traffic_client #(.BASE_ADDR(32'h0002_0000), .RING_WORDS(8192), .BURSTLEN(8),
                            .PERIOD_CYCLES(42)) u_cap (
        .clk(clk), .rst(rst), .enable(clients_enable),
        .req(cap_req), .addr(cap_addr), .burstlen(cap_burstlen), .wdata(cap_wdata), .wmask(cap_wmask),
        .gnt(cap_gnt), .done(cap_done), .words_done(cap_words_done), .bursts_done(cap_bursts_done),
        .max_wait_cycles(cap_max_wait));

    wire [ADDR_WIDTH-1:0] addr_lane4;
    wire [7:0] wr_mask_lane4;
    wire [DATA_WIDTH-1:0] wr_data_lane4;
    wire wr_en_lane4, wr_go_lane4;
    wire [7:0] burstcount_lane4;
    wire wr_wait_lane4, wr_done_lane4;

    ddr3_write_arbiter #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)) u_arb (
        .clk(clk), .rst(rst),
        .iq_req(iq_req), .iq_addr(iq_addr), .iq_burstlen(iq_burstlen), .iq_wdata(iq_wdata), .iq_wmask(iq_wmask), .iq_gnt(iq_gnt), .iq_done(iq_done),
        .wf_req(wf_req), .wf_addr(wf_addr), .wf_burstlen(wf_burstlen), .wf_wdata(wf_wdata), .wf_wmask(wf_wmask), .wf_gnt(wf_gnt), .wf_done(wf_done),
        .cap_req(cap_req), .cap_addr(cap_addr), .cap_burstlen(cap_burstlen), .cap_wdata(cap_wdata), .cap_wmask(cap_wmask), .cap_gnt(cap_gnt), .cap_done(cap_done),
        // The FT8/FT4 front end's write client (docs/F5_FT8SPEC.md) is tied off, it is not part of this test.
        .ft8_req(1'b0), .ft8_addr(32'd0), .ft8_burstlen(8'd0), .ft8_wdata(64'd0), .ft8_wmask(8'd0), .ft8_gnt(), .ft8_done(),
        .addr_lane4(addr_lane4), .wr_mask_lane4(wr_mask_lane4), .wr_data_lane4(wr_data_lane4),
        .wr_en_lane4(wr_en_lane4), .wr_go_lane4(wr_go_lane4), .burstcount_lane4(burstcount_lane4),
        .wr_wait_lane4(wr_wait_lane4), .wr_done_lane4(wr_done_lane4), .owner());

    // A second, direct connection to the read lane of the model, driven by the testbench itself, for the
    // final read-through-the-lane check.
    reg [ADDR_WIDTH-1:0] addr_lane5_direct;
    reg rd_en_lane5_direct, rd_go_lane5_direct;
    reg [7:0] burstcount_lane5_direct;
    wire rd_valid_lane5_direct;
    wire [DATA_WIDTH-1:0] rd_data_lane5_direct;
    wire rd_rdy_lane5_direct;

    // MEM_WORDS has to cover every client's BASE_ADDR plus RING_WORDS (capture's region is the highest,
    // 0x0002_0000 + 8192 = 0x0002_2000), otherwise the lane model cuts the address to its low bits and
    // silently maps one client's region onto another's.
    ddr3_lane_behav_model #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH), .MEM_WORDS(262144),
                             .STALL_NUM(30), .STALL_DEN(1000), .STALL_MAX_CYCLES(6),
                             .SEED(32'h1234_5678)) u_lane (
        .clk(clk), .rst(rst),
        .addr_lane4(addr_lane4), .wr_mask_lane4(wr_mask_lane4), .wr_data_lane4(wr_data_lane4),
        .wr_en_lane4(wr_en_lane4), .wr_go_lane4(wr_go_lane4), .burstcount_lane4(burstcount_lane4),
        .wr_wait_lane4(wr_wait_lane4), .wr_done_lane4(wr_done_lane4),
        .addr_lane5(addr_lane5_direct), .rd_en_lane5(rd_en_lane5_direct), .rd_go_lane5(rd_go_lane5_direct),
        .burstcount_lane5(burstcount_lane5_direct), .rd_valid_lane5(rd_valid_lane5_direct),
        .rd_data_lane5(rd_data_lane5_direct), .rd_rdy_lane5(rd_rdy_lane5_direct), .phys_busy());

    // Checker variables. The task uses these module level variables so it can be called from the initial block.
    integer errors;
    integer i, k;
    reg [ADDR_WIDTH-1:0] base, a;
    reg [DATA_WIDTH-1:0] expect_word, got;

    // Walks the regions of one client: for each of the `bursts` completed bursts it computes the burst's
    // start (the ring position moves on by `burstlen` words per burst and wraps at `ring_words`) and compares
    // every word of the burst in the lane model's memory with `{address, ~address}`. A wrapped ring is
    // simply checked again, which is fine because the expected value depends only on the address.
    task check_client_region(input [ADDR_WIDTH-1:0] base_addr, input integer ring_words,
                              input integer burstlen, input integer bursts);
        begin
            for (i = 0; i < bursts; i = i + 1) begin
                base = base_addr + ((i * burstlen) % ring_words);
                for (k = 0; k < burstlen; k = k + 1) begin
                    a = base + k;
                    got = u_lane.peek(a);
                    expect_word = {a, ~a};
                    if (got !== expect_word) begin
                        $display("FAIL: addr %0h got %h expected %h", a, got, expect_word);
                        errors = errors + 1;
                    end
                end
            end
        end
    endtask

    initial begin
        errors = 0;
        clients_enable = 0;
        rst = 1;
        repeat (5) @(posedge clk);
        rst = 0;
        clients_enable = 1;

        // Run for 60,000 clocks with stalls active, hundreds of bursts from the two fast clients.
        repeat (60000) @(posedge clk);
        clients_enable = 0;
        repeat (20) @(posedge clk); // let any in-flight burst finish

        $display("iq: %0d bursts, %0d words, max wait %0d; wf: %0d bursts, %0d words, max wait %0d; cap: %0d bursts, %0d words, max wait %0d",
                  iq_bursts_done, iq_words_done, iq_max_wait,
                  wf_bursts_done, wf_words_done, wf_max_wait,
                  cap_bursts_done, cap_words_done, cap_max_wait);

        if (iq_bursts_done == 0 || wf_bursts_done == 0 || cap_bursts_done == 0) begin
            $display("FAIL: at least one client never completed a burst - test is not exercising the arbiter");
            errors = errors + 1;
        end

        // ---- every word each client wrote must be in memory with the right value ----
        check_client_region(32'h0000_0000, 4096, 4, iq_bursts_done);
        check_client_region(32'h0001_0000, 4096, 8, wf_bursts_done);
        check_client_region(32'h0002_0000, 8192, 8, cap_bursts_done);

        // ---- a handful of IQ addresses read back through the real read lane port, not just by peek:
        // request one word, wait until the lane is ready, drop the request, wait for the data beat ----
        for (i = 0; i < 8; i = i + 1) begin
            a = 32'h0000_0000 + i;
            rd_go_lane5_direct       <= 1'b1;
            addr_lane5_direct        <= a;
            burstcount_lane5_direct  <= 8'd1;
            rd_en_lane5_direct       <= 1'b1;
            @(posedge clk);
            while (!rd_rdy_lane5_direct) @(posedge clk);
            rd_en_lane5_direct <= 1'b0;
            rd_go_lane5_direct <= 1'b0;
            while (!rd_valid_lane5_direct) @(posedge clk);
            expect_word = {a, ~a};
            if (rd_data_lane5_direct !== expect_word) begin
                $display("FAIL: read-lane readback addr %0h got %h expected %h", a, rd_data_lane5_direct, expect_word);
                errors = errors + 1;
            end
            @(posedge clk);
        end

        if (errors == 0) begin
            $display("PASS");
        end else begin
            $display("FAIL: %0d error(s)", errors);
        end
        $finish;
    end

    // Safety net: 20 ms of simulated time.
    // safety timeout
    initial begin
        #20_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
