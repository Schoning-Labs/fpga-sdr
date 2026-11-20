// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// System level check that the video reader is never starved of DDR3 bandwidth, using both arbiters
// together: rtl/ddr3/ddr3_write_arbiter.v and rtl/ddr3/ddr3_read_arbiter.v. The display is the one client
// that cannot wait, a missed line shows up as a glitch on the monitor, while every other client has a buffer
// that hides a delay, so this is the number that decides whether the shared DDR3 is fast enough.
//
// The other arbiter tests (tb_ddr3_write_arbiter.v, tb_ddr3_write_arbiter_priority.v and
// tb_ddr3_read_arbiter.v) check data integrity and priority order with artificial saturating traffic. This
// one instead runs every client at once at the realistic, bandwidth derived rate of docs/ARCHITECTURE.md 3.9
// (the arithmetic is in docs/F4_DDR.md section 3), one write arbiter and one read arbiter sharing the one
// sim/ddr3/ddr3_lane_behav_model.v, the way the two lanes share the one DDR3 die:
//   write lane: IQ writer (24.6 MB/s), waterfall writer (0.2 MB/s, full band and zoom combined into one
//               client), raw capture (153.6 MB/s, the documented worst case with capture on)
//   read lane:  video (sim/ddr3/video_scanout_model.v, the framebuffer and the waterfall combined, 1080p60,
//               the heavier of the two refresh rates), audio ring reader, TX ring reader, and a small
//               background reader called "the rest"
//
// The random stalls of the lane model (STALL_NUM out of STALL_DEN idle clocks start a run of up to
// STALL_MAX_CYCLES clocks) stand for how long the CPU can keep both fabric lanes off the DDR3 controller
// while it serves its own traffic. That figure can only be measured on the real board, so the defaults here
// are an assumption (docs/F4_DDR.md section 4) and can be overridden when compiling, see the run line below,
// which is how the margin sweep in that document was done.
//
// Printed at the end, and turned into the "measured margins" in docs/F4_DDR.md section 4:
//   - the share of clocks that were stalled, as a check on the stall model
//   - the lowest video FIFO fill reached (in words, and as a percentage of the 1,440 word FIFO), which is
//     the margin the hardware has to match
//   - the number of video underruns, which has to be zero to pass
//   - for every client the measured throughput against the intended bandwidth, and the worst wait for a grant
//
// Passing: "PASS" is the last line, which needs zero video underruns and a FIFO fill that never went below
// zero. A failing run prints "FAIL: ..." lines and "FAIL: <n> error(s)", or "FAIL: timeout" after 200 ms of
// simulated time. Run it from the repository root, the include paths are relative to it:
//   iverilog -g2012 -o sim/out/tb_ddr3_video_no_starve.vvp sim/ddr3/tb_ddr3_video_no_starve.v && vvp -n sim/out/tb_ddr3_video_no_starve.vvp
// and add for example -Ptb_ddr3_video_no_starve.STALL_MAX_CYCLES=64 to the iverilog command to try longer
// stalls. tools/check.sh runs the defaults together with all other testbenches. Terms such as burst, lane
// and arbiter are explained in docs/learn/GLOSSARY.md.

`timescale 1ns / 1ps
`include "rtl/ddr3/ddr3_write_arbiter.v"
`include "rtl/ddr3/ddr3_read_arbiter.v"
`include "sim/ddr3/ddr3_lane_behav_model.v"
`include "sim/ddr3/write_traffic_client.v"
`include "sim/ddr3/read_traffic_client.v"
`include "sim/ddr3/video_scanout_model.v"

module tb_ddr3_video_no_starve;

    localparam integer ADDR_WIDTH = 32;
    localparam integer DATA_WIDTH = 64;

    // Random stall assumption for this run (see the file header). Each can be overridden on the iverilog
    // command line, for example -Ptb_ddr3_video_no_starve.STALL_MAX_CYCLES=64 for the margin sweep.
    parameter integer STALL_NUM         = 30;   // 3.0% of idle clocks start a stall run
    parameter integer STALL_DEN         = 1000;
    parameter integer STALL_MAX_CYCLES  = 32;   // longest single stall run, clocks (320 ns)

    // Number of video lines to simulate, one line takes 1,481 clocks at 100 MHz, which is 14.8 us. The default
    // of 600 lines is about 9 ms of video and about 0.9 million clocks, enough for a quick run. A longer run
    // (-Ptb_ddr3_video_no_starve.LINES_TO_RUN=<n>, several frames) gives a better worst case, because the
    // random stalls need many events before their worst case settles.
    parameter integer LINES_TO_RUN = 600;
    // Clocks per 1080p60 line at the lane clock: 148.5 MHz pixel clock, 2,200 clocks per line, 14.815 us,
    // which is 1,481.5 clocks of 10 ns, rounded down.
    localparam integer LINE_PERIOD_CYCLES = 1481;

    reg clk = 0;
    reg rst = 1;
    always #5 clk = ~clk; // 100 MHz fabric R/W clock

    // ================= write lane =================
    wire iq_req, wf_req, cap_req;
    wire [ADDR_WIDTH-1:0] iq_addr, wf_addr, cap_addr;
    wire [7:0] iq_burstlen, wf_burstlen, cap_burstlen;
    wire [DATA_WIDTH-1:0] iq_wdata, wf_wdata, cap_wdata;
    wire [7:0] iq_wmask, wf_wmask, cap_wmask;
    wire iq_gnt, wf_gnt, cap_gnt, iq_done, wf_done, cap_done;
    wire [63:0] iq_words, wf_words, cap_words;
    wire [31:0] iq_bursts, wf_bursts, cap_bursts;
    wire [31:0] iq_max_wait, wf_max_wait, cap_max_wait;

    // Bandwidth derivation, all at the 100 MHz lane clock with 8 bytes per word (docs/F4_DDR.md section 3),
    // PERIOD_CYCLES is the clocks between the starts of two bursts:
    //   IQ:        24.6 MB/s, 4-word (32 B) bursts -> 32 B / 24.6 MB/s   = about 130 clocks per burst
    //   waterfall:  0.2 MB/s, 8-word (64 B) bursts -> 64 B / 0.2 MB/s    = about 32,000 clocks per burst
    //   capture:  153.6 MB/s, 8-word (64 B) bursts -> 64 B / 153.6 MB/s  = about 42 clocks per burst
    write_traffic_client #(.BASE_ADDR(32'h0000_0000), .RING_WORDS(1<<16), .BURSTLEN(4), .PERIOD_CYCLES(130)) u_iq (
        .clk(clk), .rst(rst), .enable(1'b1),
        .req(iq_req), .addr(iq_addr), .burstlen(iq_burstlen), .wdata(iq_wdata), .wmask(iq_wmask),
        .gnt(iq_gnt), .done(iq_done), .words_done(iq_words), .bursts_done(iq_bursts), .max_wait_cycles(iq_max_wait));

    write_traffic_client #(.BASE_ADDR(32'h0010_0000), .RING_WORDS(1<<16), .BURSTLEN(8), .PERIOD_CYCLES(32000)) u_wf (
        .clk(clk), .rst(rst), .enable(1'b1),
        .req(wf_req), .addr(wf_addr), .burstlen(wf_burstlen), .wdata(wf_wdata), .wmask(wf_wmask),
        .gnt(wf_gnt), .done(wf_done), .words_done(wf_words), .bursts_done(wf_bursts), .max_wait_cycles(wf_max_wait));

    write_traffic_client #(.BASE_ADDR(32'h0020_0000), .RING_WORDS(1<<18), .BURSTLEN(8), .PERIOD_CYCLES(42)) u_cap (
        .clk(clk), .rst(rst), .enable(1'b1),
        .req(cap_req), .addr(cap_addr), .burstlen(cap_burstlen), .wdata(cap_wdata), .wmask(cap_wmask),
        .gnt(cap_gnt), .done(cap_done), .words_done(cap_words), .bursts_done(cap_bursts), .max_wait_cycles(cap_max_wait));

    wire [ADDR_WIDTH-1:0] addr_lane4;
    wire [7:0] wr_mask_lane4;
    wire [DATA_WIDTH-1:0] wr_data_lane4;
    wire wr_en_lane4, wr_go_lane4;
    wire [7:0] burstcount_lane4;
    wire wr_wait_lane4, wr_done_lane4;

    ddr3_write_arbiter #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)) u_warb (
        .clk(clk), .rst(rst),
        .iq_req(iq_req), .iq_addr(iq_addr), .iq_burstlen(iq_burstlen), .iq_wdata(iq_wdata), .iq_wmask(iq_wmask), .iq_gnt(iq_gnt), .iq_done(iq_done),
        .wf_req(wf_req), .wf_addr(wf_addr), .wf_burstlen(wf_burstlen), .wf_wdata(wf_wdata), .wf_wmask(wf_wmask), .wf_gnt(wf_gnt), .wf_done(wf_done),
        .cap_req(cap_req), .cap_addr(cap_addr), .cap_burstlen(cap_burstlen), .cap_wdata(cap_wdata), .cap_wmask(cap_wmask), .cap_gnt(cap_gnt), .cap_done(cap_done),
        // The FT8/FT4 front end's write client (docs/F5_FT8SPEC.md) is tied off, it is not part of this traffic mix.
        .ft8_req(1'b0), .ft8_addr(32'd0), .ft8_burstlen(8'd0), .ft8_wdata(64'd0), .ft8_wmask(8'd0), .ft8_gnt(), .ft8_done(),
        .addr_lane4(addr_lane4), .wr_mask_lane4(wr_mask_lane4), .wr_data_lane4(wr_data_lane4),
        .wr_en_lane4(wr_en_lane4), .wr_go_lane4(wr_go_lane4), .burstcount_lane4(burstcount_lane4),
        .wr_wait_lane4(wr_wait_lane4), .wr_done_lane4(wr_done_lane4), .owner());

    // ================= read lane =================
    wire video_req, audio_req, tx_req, rest_req;
    wire [ADDR_WIDTH-1:0] video_addr, audio_addr, tx_addr, rest_addr;
    wire [7:0] video_burstlen, audio_burstlen, tx_burstlen, rest_burstlen;
    wire video_gnt, audio_gnt, tx_gnt, rest_gnt;
    wire video_rvalid, audio_rvalid, tx_rvalid, rest_rvalid;
    wire [DATA_WIDTH-1:0] video_rdata, audio_rdata, tx_rdata, rest_rdata;
    wire video_done, audio_done, tx_done, rest_done;
    wire [63:0] audio_words, tx_words, rest_words, video_words;
    wire [31:0] audio_bursts, tx_bursts, rest_bursts;
    wire [31:0] audio_max_wait, tx_max_wait, rest_max_wait, video_max_wait;
    wire signed [31:0] video_fifo_fill, video_min_fifo_fill;
    wire [31:0] video_underrun_events;

    // Audio and TX rings: about 0.192 MB/s each (the 0.4 MB/s of docs/ARCHITECTURE.md 3.9 split between
    // them), 1-word bursts, which is 8 B / 0.192 MB/s = about 4,167 clocks per burst. "The rest" has no
    // documented figure and is a small background reader of the same order (docs/F4_DDR.md section 2).
    read_traffic_client #(.BASE_ADDR(32'h0030_0000), .RING_WORDS(1<<12), .BURSTLEN(1), .PERIOD_CYCLES(4167)) u_audio (
        .clk(clk), .rst(rst), .enable(1'b1),
        .req(audio_req), .addr(audio_addr), .burstlen(audio_burstlen), .gnt(audio_gnt),
        .rvalid(audio_rvalid), .done(audio_done), .words_done(audio_words), .bursts_done(audio_bursts), .max_wait_cycles(audio_max_wait));

    read_traffic_client #(.BASE_ADDR(32'h0031_0000), .RING_WORDS(1<<12), .BURSTLEN(1), .PERIOD_CYCLES(4167)) u_tx (
        .clk(clk), .rst(rst), .enable(1'b1),
        .req(tx_req), .addr(tx_addr), .burstlen(tx_burstlen), .gnt(tx_gnt),
        .rvalid(tx_rvalid), .done(tx_done), .words_done(tx_words), .bursts_done(tx_bursts), .max_wait_cycles(tx_max_wait));

    read_traffic_client #(.BASE_ADDR(32'h0032_0000), .RING_WORDS(1<<12), .BURSTLEN(1), .PERIOD_CYCLES(5000)) u_rest (
        .clk(clk), .rst(rst), .enable(1'b1),
        .req(rest_req), .addr(rest_addr), .burstlen(rest_burstlen), .gnt(rest_gnt),
        .rvalid(rest_rvalid), .done(rest_done), .words_done(rest_words), .bursts_done(rest_bursts), .max_wait_cycles(rest_max_wait));

    // BURSTLEN 180 and not 8: with 8-word bursts the per-burst latency of the lane model eats almost the
    // whole lane, see the header of sim/ddr3/video_scanout_model.v. 720 words per line, 2 lines of FIFO.
    video_scanout_model #(.BASE_ADDR(32'h0000_0000), .RING_WORDS(1<<20), .BURSTLEN(180),
                           .LINE_WORDS(720), .LINE_PERIOD_CYCLES(LINE_PERIOD_CYCLES),
                           .FIFO_DEPTH_LINES(2)) u_video (
        .clk(clk), .rst(rst), .enable(1'b1),
        .req(video_req), .addr(video_addr), .burstlen(video_burstlen), .gnt(video_gnt),
        .rvalid(video_rvalid), .done(video_done),
        .fifo_fill(video_fifo_fill), .min_fifo_fill(video_min_fifo_fill),
        .underrun_events(video_underrun_events), .words_done(video_words), .max_wait_cycles(video_max_wait));

    wire [ADDR_WIDTH-1:0] addr_lane5;
    wire rd_en_lane5, rd_go_lane5;
    wire [7:0] burstcount_lane5;
    wire rd_valid_lane5, rd_rdy_lane5;
    wire [DATA_WIDTH-1:0] rd_data_lane5;

    ddr3_read_arbiter #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)) u_rarb (
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

    // ================= the shared lane, one instance for both directions =================
    wire phys_busy;
    ddr3_lane_behav_model #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH), .MEM_WORDS(1<<20),
                             .STALL_NUM(STALL_NUM), .STALL_DEN(STALL_DEN),
                             .STALL_MAX_CYCLES(STALL_MAX_CYCLES), .SEED(32'h600D_F00D)) u_lane (
        .clk(clk), .rst(rst),
        .addr_lane4(addr_lane4), .wr_mask_lane4(wr_mask_lane4), .wr_data_lane4(wr_data_lane4),
        .wr_en_lane4(wr_en_lane4), .wr_go_lane4(wr_go_lane4), .burstcount_lane4(burstcount_lane4),
        .wr_wait_lane4(wr_wait_lane4), .wr_done_lane4(wr_done_lane4),
        .addr_lane5(addr_lane5), .rd_en_lane5(rd_en_lane5), .rd_go_lane5(rd_go_lane5),
        .burstcount_lane5(burstcount_lane5), .rd_valid_lane5(rd_valid_lane5),
        .rd_data_lane5(rd_data_lane5), .rd_rdy_lane5(rd_rdy_lane5), .phys_busy(phys_busy));

    // Count the clocks on which the lane model was stalled, for the duty figure in the report.
    integer stall_cycles;
    always @(posedge clk) begin
        if (rst) stall_cycles <= 0;
        else if (phys_busy) stall_cycles <= stall_cycles + 1;
    end

    integer errors;
    real video_mbps, iq_mbps, wf_mbps, cap_mbps, audio_mbps, tx_mbps, rest_mbps;
    real elapsed_s, stall_duty_pct;

    // Run for LINES_TO_RUN video lines and then print the report and judge it.
    initial begin
        errors = 0;
        rst = 1;
        repeat (5) @(posedge clk);
        rst = 0;

        repeat (LINES_TO_RUN * LINE_PERIOD_CYCLES) @(posedge clk);

        // Throughput in MB/s: words times 8 bytes, divided by the elapsed time (10 ns per clock at 100 MHz).
        elapsed_s = (LINES_TO_RUN * LINE_PERIOD_CYCLES) * 10.0e-9; // 100 MHz = 10 ns/clock
        video_mbps = (video_words * 8.0) / elapsed_s / 1.0e6;
        iq_mbps    = (iq_words    * 8.0) / elapsed_s / 1.0e6;
        wf_mbps    = (wf_words    * 8.0) / elapsed_s / 1.0e6;
        cap_mbps   = (cap_words   * 8.0) / elapsed_s / 1.0e6;
        audio_mbps = (audio_words * 8.0) / elapsed_s / 1.0e6;
        tx_mbps    = (tx_words    * 8.0) / elapsed_s / 1.0e6;
        rest_mbps  = (rest_words  * 8.0) / elapsed_s / 1.0e6;
        stall_duty_pct = 100.0 * stall_cycles / (LINES_TO_RUN * LINE_PERIOD_CYCLES);

        // Report, see the header.
        $display("stall model: %0d/%0d chance/clock, up to %0d clocks/run -> measured %0.1f%% of clocks stalled",
                  STALL_NUM, STALL_DEN, STALL_MAX_CYCLES, stall_duty_pct);
        $display("ran %0d video lines (%0.3f s simulated)", LINES_TO_RUN, elapsed_s);
        $display("video: %0.2f MB/s (of 373.2 documented), max grant wait %0d clocks, FIFO min fill %0d / %0d words (%0.1f%%), underruns %0d",
                  video_mbps, video_max_wait, video_min_fifo_fill, 720*2, 100.0*video_min_fifo_fill/(720*2), video_underrun_events);
        $display("iq:    %0.2f MB/s (of 24.6),  max grant wait %0d clocks", iq_mbps, iq_max_wait);
        $display("wf:    %0.2f MB/s (of 0.2),   max grant wait %0d clocks", wf_mbps, wf_max_wait);
        $display("cap:   %0.2f MB/s (of 153.6), max grant wait %0d clocks", cap_mbps, cap_max_wait);
        $display("audio: %0.3f MB/s (of 0.192), max grant wait %0d clocks", audio_mbps, audio_max_wait);
        $display("tx:    %0.3f MB/s (of 0.192), max grant wait %0d clocks", tx_mbps, tx_max_wait);
        $display("rest:  %0.3f MB/s,            max grant wait %0d clocks", rest_mbps, rest_max_wait);

        // Pass criteria: no underrun, and a FIFO fill that never went negative (a check on the model's own
        // bookkeeping).
        if (video_underrun_events != 0) begin
            $display("FAIL: video underran %0d times", video_underrun_events);
            errors = errors + 1;
        end
        if (video_min_fifo_fill < 0) begin
            $display("FAIL: video FIFO fill went negative (%0d)", video_min_fifo_fill);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("PASS");
        end else begin
            $display("FAIL: %0d error(s)", errors);
        end
        $finish;
    end

    initial begin
        // Safety net, the default run needs about 9 ms of simulated time.
        #200_000_000; // 200 ms sim-time safety net
        $display("FAIL: timeout");
        $finish;
    end

endmodule
