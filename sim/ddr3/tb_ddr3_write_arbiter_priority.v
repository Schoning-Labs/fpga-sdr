// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Priority order test for rtl/ddr3/ddr3_write_arbiter.v. The arbiter serves the IQ writer first, then the
// waterfall writer, then raw capture (docs/ARCHITECTURE.md 3.9), because losing IQ samples is the damage
// that cannot be repaired later while a delayed capture burst costs nothing. When two clients want the lane
// at the same moment the higher one has to win every time. Data integrity is checked separately, under
// realistic traffic, in sim/ddr3/tb_ddr3_write_arbiter.v.
//
// Stimulus: three sim/ddr3/write_traffic_client.v instances (IQ with 4-word bursts, waterfall and capture
// with 8-word bursts) run in saturating mode (PERIOD_CYCLES is 1), which means each one always has the
// next burst ready, so who gets the lane is decided by priority alone and never by who asks more often.
// They are switched on one at a time, each phase lasting PHASE_CYCLES clocks, and the check is how many new
// bursts each client that was already running completes while the newcomer is also active:
//
//   phase 1: capture alone, to show it makes progress unopposed
//   phase 2: waterfall joins, it should get nearly all the new bursts and capture almost none
//   phase 3: IQ joins, it should get nearly all the new bursts and waterfall and capture almost none
//
// "Almost none" and not exactly none, because a burst that is already running when a higher client starts
// asking is allowed to finish (the arbiter never pre-empts a granted burst, see its header), so the loser can
// complete at most one more burst after it lost its priority. The test therefore fails when a loser gains
// more than 1 burst in a phase.
//
// The lane model has no random stalls here, since a stall delays every client alike and would only make the
// counting of the last burst fuzzy.
//
// Passing: the last line is "PASS", otherwise "FAIL: ..." lines and "FAIL: <n> error(s)" are printed, or
// "FAIL: timeout" after 200 us of simulated time. Run it from the repository root, the include paths are
// relative to it:
//   iverilog -g2012 -o sim/out/tb_ddr3_write_arbiter_priority.vvp sim/ddr3/tb_ddr3_write_arbiter_priority.v && vvp -n sim/out/tb_ddr3_write_arbiter_priority.vvp
// or all testbenches together with tools/check.sh. Terms such as burst, lane and arbiter are explained in
// docs/learn/GLOSSARY.md.

`timescale 1ns / 1ps
`include "rtl/ddr3/ddr3_write_arbiter.v"
`include "sim/ddr3/ddr3_lane_behav_model.v"
`include "sim/ddr3/write_traffic_client.v"

module tb_ddr3_write_arbiter_priority;

    localparam integer ADDR_WIDTH = 32;
    localparam integer DATA_WIDTH = 64;
    // Length of each stimulus phase in clocks, 4,000 clocks of 10 ns are 40 us.
    localparam integer PHASE_CYCLES = 4000;

    reg clk = 0;
    reg rst = 1;
    always #5 clk = ~clk; // 100 MHz fabric R/W clock

    wire iq_req, wf_req, cap_req;
    wire [ADDR_WIDTH-1:0] iq_addr, wf_addr, cap_addr;
    wire [7:0] iq_burstlen, wf_burstlen, cap_burstlen;
    wire [DATA_WIDTH-1:0] iq_wdata, wf_wdata, cap_wdata;
    wire [7:0] iq_wmask, wf_wmask, cap_wmask;
    wire iq_gnt, wf_gnt, cap_gnt, iq_done, wf_done, cap_done;
    wire [63:0] iq_words_done, wf_words_done, cap_words_done;
    wire [31:0] iq_bursts_done, wf_bursts_done, cap_bursts_done;

    // One enable per client, they are raised one after the other by the stimulus below.
    reg iq_enable, wf_enable, cap_enable;

    // The three saturating clients, each with its own 4,096 or 8,192 word region.
    write_traffic_client #(.BASE_ADDR(32'h0000_0000), .RING_WORDS(4096), .BURSTLEN(4), .PERIOD_CYCLES(1)) u_iq (
        .clk(clk), .rst(rst), .enable(iq_enable),
        .req(iq_req), .addr(iq_addr), .burstlen(iq_burstlen), .wdata(iq_wdata), .wmask(iq_wmask),
        .gnt(iq_gnt), .done(iq_done), .words_done(iq_words_done), .bursts_done(iq_bursts_done), .max_wait_cycles());

    write_traffic_client #(.BASE_ADDR(32'h0001_0000), .RING_WORDS(4096), .BURSTLEN(8), .PERIOD_CYCLES(1)) u_wf (
        .clk(clk), .rst(rst), .enable(wf_enable),
        .req(wf_req), .addr(wf_addr), .burstlen(wf_burstlen), .wdata(wf_wdata), .wmask(wf_wmask),
        .gnt(wf_gnt), .done(wf_done), .words_done(wf_words_done), .bursts_done(wf_bursts_done), .max_wait_cycles());

    write_traffic_client #(.BASE_ADDR(32'h0002_0000), .RING_WORDS(8192), .BURSTLEN(8), .PERIOD_CYCLES(1)) u_cap (
        .clk(clk), .rst(rst), .enable(cap_enable),
        .req(cap_req), .addr(cap_addr), .burstlen(cap_burstlen), .wdata(cap_wdata), .wmask(cap_wmask),
        .gnt(cap_gnt), .done(cap_done), .words_done(cap_words_done), .bursts_done(cap_bursts_done), .max_wait_cycles());

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

    // No stalls here: this test is about the arbiter's own priority logic and not about lane availability.
    // A stall pauses the acceptance of a new burst whichever client wants it, and would only blur the
    // counting of the one burst that may still finish after a priority change.
    ddr3_lane_behav_model #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH), .MEM_WORDS(262144),
                             .STALL_NUM(0)) u_lane (
        .clk(clk), .rst(rst),
        .addr_lane4(addr_lane4), .wr_mask_lane4(wr_mask_lane4), .wr_data_lane4(wr_data_lane4),
        .wr_en_lane4(wr_en_lane4), .wr_go_lane4(wr_go_lane4), .burstcount_lane4(burstcount_lane4),
        .wr_wait_lane4(wr_wait_lane4), .wr_done_lane4(wr_done_lane4),
        .addr_lane5(32'd0), .rd_en_lane5(1'b0), .rd_go_lane5(1'b0), .burstcount_lane5(8'd0),
        .rd_valid_lane5(), .rd_data_lane5(), .rd_rdy_lane5(), .phys_busy());

    // Burst counts at the start of a phase, so the phase can report how many each client gained.
    integer errors;
    integer cap_before, wf_before, iq_before;

    initial begin
        errors = 0;
        iq_enable = 0; wf_enable = 0; cap_enable = 0;
        rst = 1;
        repeat (5) @(posedge clk);
        rst = 0;

        // phase 1: capture alone.
        // phase 1: capture alone
        cap_enable = 1;
        repeat (PHASE_CYCLES) @(posedge clk);
        if (cap_bursts_done == 0) begin
            $display("FAIL: capture made no progress even unopposed");
            errors = errors + 1;
        end
        $display("phase 1 (capture alone): cap_bursts=%0d", cap_bursts_done);

        // phase 2: waterfall joins (higher priority than capture).
        // phase 2: + waterfall (higher priority than capture)
        cap_before = cap_bursts_done;
        wf_enable = 1;
        repeat (PHASE_CYCLES) @(posedge clk);
        $display("phase 2 (+waterfall): wf_bursts=%0d, capture gained %0d bursts",
                  wf_bursts_done, cap_bursts_done - cap_before);
        if (wf_bursts_done == 0) begin
            $display("FAIL: waterfall made no progress against capture");
            errors = errors + 1;
        end
        // Capture may finish the one burst that was already running when the waterfall request first rose,
        // anything beyond that means capture kept winning an arbitration it should have lost.
        if (cap_bursts_done - cap_before > 1) begin
            $display("FAIL: capture gained %0d bursts while waterfall was contending (expected <= 1)",
                      cap_bursts_done - cap_before);
            errors = errors + 1;
        end

        // phase 3: + IQ (higher priority than both)
        wf_before  = wf_bursts_done;
        cap_before = cap_bursts_done;
        iq_enable  = 1;
        repeat (PHASE_CYCLES) @(posedge clk);
        $display("phase 3 (+IQ): iq_bursts=%0d, waterfall gained %0d bursts, capture gained %0d bursts",
                  iq_bursts_done, wf_bursts_done - wf_before, cap_bursts_done - cap_before);
        if (iq_bursts_done == 0) begin
            $display("FAIL: IQ made no progress against waterfall and capture");
            errors = errors + 1;
        end
        if (wf_bursts_done - wf_before > 1) begin
            $display("FAIL: waterfall gained %0d bursts while IQ was contending (expected <= 1)",
                      wf_bursts_done - wf_before);
            errors = errors + 1;
        end
        if (cap_bursts_done - cap_before > 1) begin
            $display("FAIL: capture gained %0d bursts while IQ was contending (expected <= 1)",
                      cap_bursts_done - cap_before);
            errors = errors + 1;
        end

        // Switch everything off and let any burst in flight end.
        iq_enable = 0; wf_enable = 0; cap_enable = 0;
        repeat (20) @(posedge clk);

        if (errors == 0) begin
            $display("PASS");
        end else begin
            $display("FAIL: %0d error(s)", errors);
        end
        $finish;
    end

    // Safety net: 200 us of simulated time, the three phases need 120 us.
    initial begin
        #200_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
