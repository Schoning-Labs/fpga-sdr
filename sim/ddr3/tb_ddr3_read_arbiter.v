// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Testbench for rtl/ddr3/ddr3_read_arbiter.v, the module that puts four readers (video, audio, TX ring and
// "the rest") onto the single DDR3 read lane. The order is a strict priority, video first, then audio and TX
// together, then the rest, as docs/ARCHITECTURE.md 3.9 lays it out: the picture must never starve, while an
// audio ring that has to wait a few microseconds is harmless because it is buffered.
//
// The device under test is connected to four sim/ddr3/read_traffic_client.v instances (one per reader) and
// to sim/ddr3/ddr3_lane_behav_model.v, which stands for the real lane and injects random stalls (3 percent of
// idle clocks, runs of up to 6 clocks) to make arbitration timing irregular. The write half of the lane
// model is tied off. Before the run the model's memory is loaded with an address derived pattern, the word
// at address A is `{A, ~A}`, in each client's own 4,096-word region, so every beat that arrives can be
// checked against the address it came from.
//
// Two things are checked:
//
//  1. Data correctness. Every `rvalid` beat on every client port is compared with the pattern recomputed
//     from the client's address and the beat number, so a wrong word, or a word delivered to the wrong client,
//     is reported straight away.
//  2. Priority order under contention. All four clients saturate the lane (PERIOD_CYCLES is 1, they
//     always have a burst ready) and are switched on one at a time, each for PHASE_CYCLES clocks. Phase 1 has
//     "the rest" alone and must make progress. Phase 2 adds audio and TX, which must both progress, must
//     take the lane from "the rest" (it may finish at most the one burst already running when they
//     arrived) and must share it roughly evenly with each other (neither gets more than twice the bursts of
//     the other, which shows the round robin between them). Phase 3 adds video, which must progress while
//     audio and TX each finish at most one more burst. "At most one" is the rule that a burst already granted
//     is never pre-empted, so a lower tier can lose the lane only after its current burst, here 4 beats.
//
// The measurement of how much margin the video reader has under the realistic bandwidth mix, as opposed to
// this artificial saturation, is the separate sim/ddr3/tb_ddr3_video_no_starve.v.
//
// Passing: the last line printed is "PASS" and every `FAIL:` line is absent, the testbench ends with
// "FAIL: <n> error(s)" otherwise, or "FAIL: timeout" after 200 us of simulated time. It is run like every
// other testbench in sim/, from the repository root, because the `include` paths are relative to it:
//   iverilog -g2012 -o sim/out/tb_ddr3_read_arbiter.vvp sim/ddr3/tb_ddr3_read_arbiter.v && vvp -n sim/out/tb_ddr3_read_arbiter.vvp
// or all together with tools/check.sh. Terms such as burst, lane and arbiter are explained in
// docs/learn/GLOSSARY.md.

`timescale 1ns / 1ps
`include "rtl/ddr3/ddr3_read_arbiter.v"
`include "sim/ddr3/ddr3_lane_behav_model.v"
`include "sim/ddr3/read_traffic_client.v"

module tb_ddr3_read_arbiter;

    localparam integer ADDR_WIDTH = 32;
    localparam integer DATA_WIDTH = 64;
    // Length of each stimulus phase in clocks, 4,000 clocks of 10 ns are 40 us, long enough for hundreds of
    // short bursts.
    localparam integer PHASE_CYCLES = 4000;

    // 100 MHz fabric read/write clock (docs/ARCHITECTURE.md section 2): the 5 ns half period gives 10 ns.
    reg clk = 0;
    reg rst = 1;
    always #5 clk = ~clk;

    wire video_req, audio_req, tx_req, rest_req;
    wire [ADDR_WIDTH-1:0] video_addr, audio_addr, tx_addr, rest_addr;
    wire [7:0] video_burstlen, audio_burstlen, tx_burstlen, rest_burstlen;
    wire video_gnt, audio_gnt, tx_gnt, rest_gnt;
    wire video_rvalid, audio_rvalid, tx_rvalid, rest_rvalid;
    wire [DATA_WIDTH-1:0] video_rdata, audio_rdata, tx_rdata, rest_rdata;
    wire video_done, audio_done, tx_done, rest_done;
    wire [63:0] video_words, audio_words, tx_words, rest_words;
    wire [31:0] video_bursts, audio_bursts, tx_bursts, rest_bursts;

    reg video_enable, audio_enable, tx_enable, rest_enable;

    // The four readers, all saturating. Video uses 8-word bursts and the other three 4-word bursts, and each
    // reads its own 4,096-word region (starting at 0x0, 0x1_0000, 0x2_0000 and 0x3_0000), so the pattern
    // checker can tell whose data is whose.
    read_traffic_client #(.BASE_ADDR(32'h0000_0000), .RING_WORDS(4096), .BURSTLEN(8), .PERIOD_CYCLES(1)) u_video (
        .clk(clk), .rst(rst), .enable(video_enable),
        .req(video_req), .addr(video_addr), .burstlen(video_burstlen), .gnt(video_gnt),
        .rvalid(video_rvalid), .done(video_done), .words_done(video_words), .bursts_done(video_bursts), .max_wait_cycles());

    read_traffic_client #(.BASE_ADDR(32'h0001_0000), .RING_WORDS(4096), .BURSTLEN(4), .PERIOD_CYCLES(1)) u_audio (
        .clk(clk), .rst(rst), .enable(audio_enable),
        .req(audio_req), .addr(audio_addr), .burstlen(audio_burstlen), .gnt(audio_gnt),
        .rvalid(audio_rvalid), .done(audio_done), .words_done(audio_words), .bursts_done(audio_bursts), .max_wait_cycles());

    read_traffic_client #(.BASE_ADDR(32'h0002_0000), .RING_WORDS(4096), .BURSTLEN(4), .PERIOD_CYCLES(1)) u_tx (
        .clk(clk), .rst(rst), .enable(tx_enable),
        .req(tx_req), .addr(tx_addr), .burstlen(tx_burstlen), .gnt(tx_gnt),
        .rvalid(tx_rvalid), .done(tx_done), .words_done(tx_words), .bursts_done(tx_bursts), .max_wait_cycles());

    read_traffic_client #(.BASE_ADDR(32'h0003_0000), .RING_WORDS(4096), .BURSTLEN(4), .PERIOD_CYCLES(1)) u_rest (
        .clk(clk), .rst(rst), .enable(rest_enable),
        .req(rest_req), .addr(rest_addr), .burstlen(rest_burstlen), .gnt(rest_gnt),
        .rvalid(rest_rvalid), .done(rest_done), .words_done(rest_words), .bursts_done(rest_bursts), .max_wait_cycles());

    wire [ADDR_WIDTH-1:0] addr_lane5;
    wire rd_en_lane5, rd_go_lane5;
    wire [7:0] burstcount_lane5;
    wire rd_valid_lane5, rd_rdy_lane5;
    wire [DATA_WIDTH-1:0] rd_data_lane5;

    ddr3_read_arbiter #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)) u_arb (
        .clk(clk), .rst(rst),
        .video_req(video_req), .video_addr(video_addr), .video_burstlen(video_burstlen),
        .video_gnt(video_gnt), .video_rvalid(video_rvalid), .video_rdata(video_rdata), .video_done(video_done),
        .audio_req(audio_req), .audio_addr(audio_addr), .audio_burstlen(audio_burstlen),
        .audio_gnt(audio_gnt), .audio_rvalid(audio_rvalid), .audio_rdata(audio_rdata), .audio_done(audio_done),
        .tx_req(tx_req), .tx_addr(tx_addr), .tx_burstlen(tx_burstlen),
        .tx_gnt(tx_gnt), .tx_rvalid(tx_rvalid), .tx_rdata(tx_rdata), .tx_done(tx_done),
        .rest_req(rest_req), .rest_addr(rest_addr), .rest_burstlen(rest_burstlen),
        .rest_gnt(rest_gnt), .rest_rvalid(rest_rvalid), .rest_rdata(rest_rdata), .rest_done(rest_done),
        .addr_lane5(addr_lane5), .rd_en_lane5(rd_en_lane5), .rd_go_lane5(rd_go_lane5),
        .burstcount_lane5(burstcount_lane5), .rd_valid_lane5(rd_valid_lane5),
        .rd_data_lane5(rd_data_lane5), .rd_rdy_lane5(rd_rdy_lane5), .owner());

    // Only the read half of the lane model is used (the write lane inputs are tied to zero). MEM_WORDS of
    // 262,144 covers the highest region, 0x3_0000 plus 4,096 words.
    ddr3_lane_behav_model #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH), .MEM_WORDS(262144),
                             .STALL_NUM(30), .STALL_DEN(1000), .STALL_MAX_CYCLES(6),
                             .SEED(32'hABCD_EF01)) u_lane (
        .clk(clk), .rst(rst),
        .addr_lane4(32'd0), .wr_mask_lane4(8'd0), .wr_data_lane4(64'd0), .wr_en_lane4(1'b0),
        .wr_go_lane4(1'b0), .burstcount_lane4(8'd0), .wr_wait_lane4(), .wr_done_lane4(),
        .addr_lane5(addr_lane5), .rd_en_lane5(rd_en_lane5), .rd_go_lane5(rd_go_lane5),
        .burstcount_lane5(burstcount_lane5), .rd_valid_lane5(rd_valid_lane5),
        .rd_data_lane5(rd_data_lane5), .rd_rdy_lane5(rd_rdy_lane5), .phys_busy());

    // ---------------- pre-load the pattern every client expects to read back ----------------
    integer i;
    initial begin
        for (i = 0; i < 4096; i = i + 1) begin
            u_lane.poke(32'h0000_0000 + i, {32'h0000_0000 + i, ~(32'h0000_0000 + i)});
            u_lane.poke(32'h0001_0000 + i, {32'h0001_0000 + i, ~(32'h0001_0000 + i)});
            u_lane.poke(32'h0002_0000 + i, {32'h0002_0000 + i, ~(32'h0002_0000 + i)});
            u_lane.poke(32'h0003_0000 + i, {32'h0003_0000 + i, ~(32'h0003_0000 + i)});
        end
    end

    // ---------------- data checker: for every `rvalid` the expected word is recomputed from the
    // address the client's own port is presenting and the number of the beat in its burst ----------------
    integer data_errors;
    task check_stream(input rvalid, input [ADDR_WIDTH-1:0] port_addr,
                       input [DATA_WIDTH-1:0] port_rdata, input [7:0] beat_of_burst);
        reg [ADDR_WIDTH-1:0] eff;
        reg [DATA_WIDTH-1:0] expect_word;
        begin
            if (rvalid) begin
                eff = port_addr + beat_of_burst;
                expect_word = {eff, ~eff};
                if (port_rdata !== expect_word) begin
                    $display("FAIL: read data mismatch at addr %0h: got %h expected %h", eff, port_rdata, expect_word);
                    data_errors = data_errors + 1;
                end
            end
        end
    endtask

    // One beat counter per client, so the checker knows which word of the burst each `rvalid` is (the client
    // only exposes the burst's base address). It wraps at the client's `burstlen` and does not use the
    // arbiter's `done`, because `done` is a registered pulse that comes one clock after the last
    // `rd_valid_lane5` beat it reports, and a counter reset by it would be wrong for every burst after the
    // first.
    reg [7:0] video_beat, audio_beat, tx_beat, rest_beat;
    always @(posedge clk) begin
        if (rst) begin
            video_beat <= 0; audio_beat <= 0; tx_beat <= 0; rest_beat <= 0;
        end else begin
            if (video_rvalid) video_beat <= (video_beat + 8'd1 >= video_burstlen) ? 8'd0 : video_beat + 8'd1;
            if (audio_rvalid) audio_beat <= (audio_beat + 8'd1 >= audio_burstlen) ? 8'd0 : audio_beat + 8'd1;
            if (tx_rvalid)    tx_beat    <= (tx_beat    + 8'd1 >= tx_burstlen)    ? 8'd0 : tx_beat    + 8'd1;
            if (rest_rvalid)  rest_beat  <= (rest_beat  + 8'd1 >= rest_burstlen)  ? 8'd0 : rest_beat  + 8'd1;
        end
    end

    // Check every beat on every client port on every clock.
    always @(posedge clk) begin
        check_stream(video_rvalid, video_addr, video_rdata, video_beat);
        check_stream(audio_rvalid, audio_addr, audio_rdata, audio_beat);
        check_stream(tx_rvalid,    tx_addr,    tx_rdata,    tx_beat);
        check_stream(rest_rvalid,  rest_addr,  rest_rdata,  rest_beat);
    end

    // ---------------- priority-order phases, the same structure as the write side ----------------
    // ---------------- priority-order phases (same structure as the write side) --------------
    integer errors;
    integer audio_before, tx_before, rest_before;

    initial begin
        errors = 0;
        data_errors = 0;
        video_enable = 0; audio_enable = 0; tx_enable = 0; rest_enable = 0;
        rst = 1;
        repeat (5) @(posedge clk);
        rst = 0;

        // phase 1: "the rest" alone (tier 2, the lowest). It has to make progress when nobody else wants the lane.
        // phase 1: rest alone (tier 2, lowest)
        rest_enable = 1;
        repeat (PHASE_CYCLES) @(posedge clk);
        if (rest_bursts == 0) begin
            $display("FAIL: rest-tier reader made no progress even unopposed");
            errors = errors + 1;
        end
        $display("phase 1 (rest alone): rest_bursts=%0d", rest_bursts);

        // phase 2: audio and TX join (tier 1). Both should now take the lane from "the rest" and share it
        // roughly evenly between themselves, which is the round robin in ddr3_read_arbiter.v.
        rest_before = rest_bursts;
        audio_enable = 1;
        tx_enable    = 1;
        repeat (PHASE_CYCLES) @(posedge clk);
        $display("phase 2 (+audio,+tx): audio_bursts=%0d tx_bursts=%0d, rest gained %0d bursts",
                  audio_bursts, tx_bursts, rest_bursts - rest_before);
        if (audio_bursts == 0 || tx_bursts == 0) begin
            $display("FAIL: audio or tx made no progress");
            errors = errors + 1;
        end
        if (rest_bursts - rest_before > 1) begin
            $display("FAIL: rest gained %0d bursts while tier 1 was contending (expected <= 1)",
                      rest_bursts - rest_before);
            errors = errors + 1;
        end
        // Round robin fairness: neither of the two may get more than twice the bursts of the other.
        // round-robin fairness between audio and tx: neither should get much more than half
        if (audio_bursts > 2 * tx_bursts || tx_bursts > 2 * audio_bursts) begin
            $display("FAIL: audio/tx round-robin looks unfair: audio=%0d tx=%0d", audio_bursts, tx_bursts);
            errors = errors + 1;
        end

        // phase 3: video joins (tier 0, the top). It should push audio and TX out, each one allowed at
        // most the burst that was already running.
        // phase 3: + video (tier 0, top)
        audio_before = audio_bursts;
        tx_before    = tx_bursts;
        video_enable = 1;
        repeat (PHASE_CYCLES) @(posedge clk);
        $display("phase 3 (+video): video_bursts=%0d, audio gained %0d, tx gained %0d",
                  video_bursts, audio_bursts - audio_before, tx_bursts - tx_before);
        if (video_bursts == 0) begin
            $display("FAIL: video made no progress against audio/tx");
            errors = errors + 1;
        end
        if (audio_bursts - audio_before > 1) begin
            $display("FAIL: audio gained %0d bursts while video was contending (expected <= 1)",
                      audio_bursts - audio_before);
            errors = errors + 1;
        end
        if (tx_bursts - tx_before > 1) begin
            $display("FAIL: tx gained %0d bursts while video was contending (expected <= 1)",
                      tx_bursts - tx_before);
            errors = errors + 1;
        end

        // Switch every client off and let anything in flight drain before the last check.
        video_enable = 0; audio_enable = 0; tx_enable = 0; rest_enable = 0;
        repeat (20) @(posedge clk);

        // Any mismatch the data checker found counts as an error.
        $display("data_errors=%0d", data_errors);
        if (data_errors > 0) errors = errors + data_errors;

        if (errors == 0) begin
            $display("PASS");
        end else begin
            $display("FAIL: %0d error(s)", errors);
        end
        $finish;
    end

    // Safety net: 200 us of simulated time, far more than the three phases (120 us in total) need.
    initial begin
        #200_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
