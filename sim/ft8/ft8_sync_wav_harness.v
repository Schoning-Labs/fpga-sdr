// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Full-recording bench for the FT8 sync search engine, rtl/ft8/ft8_sync.v. The engine looks for
// the Costas sync pattern that every FT8 transmission carries (three blocks of seven tones in a
// fixed order), and it does so over the spectrogram, which is a picture of signal power per
// frequency bin (3.125 Hz wide) and per time frame (40 ms). For every carrier bin of the band it
// tries every lag from -63 to 63 frames, scores how well the pattern fits, divides the match by
// the total energy, and keeps the best lag and the scores around it. The result for each bin is
// a record of 8 words of 32 bits, which is 4 DDR3 lane words.
//
// Stimulus: the Rust reference model's spectrogram of one whole recording (372 frames x 512
// lane words, two 32-bit power words per lane word) is written into the ring of receiver 5 in
// the DDR3 model. The bench then pulses slot_start for that receiver and sets its frame counter
// to 372, the end of the slot, which makes the engine run one full search over the band IA .. IB.
// The DDR3 behind the engine is the same unkind stand-in as in sim/ft8/tb_ft8_sync.v: a 150 MHz
// engine clock, a lane that delivers a data beat on two of every three clocks (100 MHz of
// throughput), random stalls, a video read client and a background reader that share the read
// side with the engine, and IQ writes on the top write tier.
//
// Pass criterion: this bench does not compare the records itself. It checks that the interrupt
// arrives for receiver 5 with 372 rows, writes the records (4 lane words per bin) to OUT_FILE
// and prints the length of the search in clocks and milliseconds, followed by "DONE". A "FAIL"
// line is printed if the interrupt does not come within 40 million clocks. `ft8-frontend
// sync-check` then compares the records bit for bit with the model's.
//
// It is not a tb_*.v file because it needs vectors made from the recordings in captures/, and a
// search over the whole band takes several million clocks. tools/check_ft8_sync.sh builds the
// vectors, compiles this file with iverilog -g2012 and runs it with vvp, passing the defines
// SPEC_FILE, OUT_FILE, BAND_IA and BAND_IB.

`timescale 1ns / 1ps
`include "rtl/ft8/ft8_sync.v"
`include "rtl/ft8/ft8_ddr3_rdmux.v"
`include "rtl/ddr3/ddr3_write_arbiter.v"
`include "rtl/ddr3/ddr3_read_arbiter.v"
`include "sim/ddr3/ddr3_lane_behav_model.v"
`include "sim/ddr3/write_traffic_client.v"
`include "sim/ddr3/read_traffic_client.v"
`include "sim/ddr3/video_scanout_model.v"

module ft8_sync_wav_harness;
    // Eight receivers in the engine, of which receiver 5 is searched. Bins IA .. IB (bin k is
    // k x 12,000 / 3,840 = 3.125 Hz x k) set the band. SPEC_BASE and REC_BASE are word addresses
    // of the spectrogram ring and of the records in the DDR3 model.
    localparam integer NUM_RX    = 8;
    localparam integer RX        = 5;
    localparam integer IA        = `BAND_IA, IB = `BAND_IB;
    localparam integer NBINS     = IB - IA + 1;
    localparam integer SPEC_BASE = 32'h0000_0000;
    localparam integer REC_BASE  = 32'h0003_0000;

    // 150 MHz: 6.666 ns period, 3.333 ns per half period.
    reg clk = 0;
    always #3.333 clk = ~clk;
    reg rst = 1;

    // The model's spectrogram: 372 frames of 512 lane words (1,024 power words, two per word).
    reg [63:0] spec [0:372*512-1];
    initial $readmemh(`SPEC_FILE, spec);

    // Per receiver frame counters (9 bits each) and slot start pulses, driven by the bench.
    reg  [NUM_RX*9-1:0] frame_ptr;
    reg  [NUM_RX-1:0]   slot_start;
    wire busy, irq;
    wire [2:0] irq_rx;
    wire [8:0] irq_rows;
    wire [31:0] run_clocks;

    wire        s_rd_req, s_rd_gnt, s_rd_rvalid, s_rd_done;
    wire [31:0] s_rd_addr;
    wire [7:0]  s_rd_burstlen;
    wire [63:0] s_rd_rdata;
    wire        s_wr_req, s_wr_gnt, s_wr_done;
    wire [31:0] s_wr_addr;
    wire [7:0]  s_wr_burstlen, s_wr_wmask;
    wire [63:0] s_wr_wdata;

    // The sync engine, with the early decode triggers (trig1, trig2) and the second pass inputs
    // (alt_*) switched off.
    ft8_sync #(.NUM_RX(NUM_RX)) dut (
        .clk(clk), .rst(rst),
        .spec_ring_base({NUM_RX{SPEC_BASE[31:0]}}), .rec_base({NUM_RX{REC_BASE[31:0]}}),
        .band_ia({NUM_RX{IA[9:0]}}), .band_ib({NUM_RX{IB[9:0]}}),
        .trig1({(NUM_RX*9){1'b0}}), .trig2({(NUM_RX*9){1'b0}}), .frame_ptr(frame_ptr),
        .slot_start(slot_start), .cmd_start(1'b0), .cmd_rx(3'd0), .cmd_rows(9'd0),
        .alt_start(1'b0), .alt_rx(3'd0), .alt_spec_base(32'd0), .alt_rec_base(32'd0),
        .busy(busy), .irq(irq), .irq_rx(irq_rx), .irq_rows(irq_rows), .irq_alt(),
        .run_clocks(run_clocks),
        .rd_req(s_rd_req), .rd_addr(s_rd_addr), .rd_burstlen(s_rd_burstlen), .rd_gnt(s_rd_gnt),
        .rd_rvalid(s_rd_rvalid), .rd_rdata(s_rd_rdata), .rd_done(s_rd_done),
        .wr_req(s_wr_req), .wr_addr(s_wr_addr), .wr_burstlen(s_wr_burstlen), .wr_wdata(s_wr_wdata),
        .wr_wmask(s_wr_wmask), .wr_gnt(s_wr_gnt), .wr_done(s_wr_done)
    );

    // A background reader that shares the read side with the engine, 120 word bursts every 3,000 clocks.
    wire        b_req, b_gnt, b_rvalid, b_done;
    wire [31:0] b_addr;
    wire [7:0]  b_burstlen;
    read_traffic_client #(.BASE_ADDR(32'h0003_8000), .RING_WORDS(4096), .BURSTLEN(120),
                          .PERIOD_CYCLES(3000)) u_bg (
        .clk(clk), .rst(rst), .enable(1'b1),
        .req(b_req), .addr(b_addr), .burstlen(b_burstlen), .gnt(b_gnt), .rvalid(b_rvalid), .done(b_done),
        .words_done(), .bursts_done(), .max_wait_cycles());

    // Two-way read multiplexer that merges the background reader and the engine onto the "rest" tier.
    wire        r_req, r_gnt, r_rvalid, r_done;
    wire [31:0] r_addr;
    wire [7:0]  r_burstlen;
    wire [63:0] r_rdata;
    ft8_ddr3_rdmux u_mux (
        .clk(clk), .rst(rst),
        .a_req(b_req), .a_addr(b_addr), .a_burstlen(b_burstlen), .a_gnt(b_gnt), .a_rvalid(b_rvalid),
        .a_rdata(), .a_done(b_done),
        .b_req(s_rd_req), .b_addr(s_rd_addr), .b_burstlen(s_rd_burstlen), .b_gnt(s_rd_gnt),
        .b_rvalid(s_rd_rvalid), .b_rdata(s_rd_rdata), .b_done(s_rd_done),
        .req(r_req), .addr(r_addr), .burstlen(r_burstlen), .gnt(r_gnt), .rvalid(r_rvalid),
        .rdata(r_rdata), .done(r_done));

    // Stand-in for the video scan-out on the top read tier.
    wire        v_req, v_gnt, v_rvalid, v_done;
    wire [31:0] v_addr;
    wire [7:0]  v_burstlen;
    wire signed [31:0] v_min_fill;
    wire [31:0] v_underruns;
    video_scanout_model #(.BASE_ADDR(32'h0003_C000), .RING_WORDS(1 << 14), .BURSTLEN(180),
                          .LINE_WORDS(720), .LINE_PERIOD_CYCLES(2222), .FIFO_DEPTH_LINES(2)) u_video (
        .clk(clk), .rst(rst), .enable(1'b1),
        .req(v_req), .addr(v_addr), .burstlen(v_burstlen), .gnt(v_gnt), .rvalid(v_rvalid), .done(v_done),
        .fifo_fill(), .min_fifo_fill(v_min_fill), .underrun_events(v_underruns), .words_done(),
        .max_wait_cycles());

    // Stand-in for the IQ capture on the top write tier.
    wire        iq_req, iq_gnt, iq_done;
    wire [31:0] iq_addr;
    wire [7:0]  iq_burstlen, iq_wmask;
    wire [63:0] iq_wdata;
    write_traffic_client #(.BASE_ADDR(32'h0003_A000), .RING_WORDS(4096), .BURSTLEN(4),
                           .PERIOD_CYCLES(195)) u_iq (
        .clk(clk), .rst(rst), .enable(1'b1),
        .req(iq_req), .addr(iq_addr), .burstlen(iq_burstlen), .wdata(iq_wdata), .wmask(iq_wmask),
        .gnt(iq_gnt), .done(iq_done), .words_done(), .bursts_done(), .max_wait_cycles());

    wire [31:0] addr_lane4, addr_lane5;
    wire [7:0]  wr_mask_lane4, burstcount_lane4, burstcount_lane5;
    wire [63:0] wr_data_lane4, rd_data_lane5;
    wire wr_en_lane4, wr_go_lane4, wr_wait_lane4, wr_done_lane4;
    wire rd_en_lane5, rd_go_lane5, rd_valid_lane5, rd_rdy_lane5;

    // Arbiters that share one write lane and one read lane between the clients.
    ddr3_write_arbiter u_warb (
        .clk(clk), .rst(rst),
        .iq_req(iq_req), .iq_addr(iq_addr), .iq_burstlen(iq_burstlen), .iq_wdata(iq_wdata), .iq_wmask(iq_wmask), .iq_gnt(iq_gnt), .iq_done(iq_done),
        .wf_req(1'b0), .wf_addr(32'd0), .wf_burstlen(8'd0), .wf_wdata(64'd0), .wf_wmask(8'd0), .wf_gnt(), .wf_done(),
        .cap_req(1'b0), .cap_addr(32'd0), .cap_burstlen(8'd0), .cap_wdata(64'd0), .cap_wmask(8'd0), .cap_gnt(), .cap_done(),
        .ft8_req(s_wr_req), .ft8_addr(s_wr_addr), .ft8_burstlen(s_wr_burstlen), .ft8_wdata(s_wr_wdata), .ft8_wmask(s_wr_wmask), .ft8_gnt(s_wr_gnt), .ft8_done(s_wr_done),
        .addr_lane4(addr_lane4), .wr_mask_lane4(wr_mask_lane4), .wr_data_lane4(wr_data_lane4),
        .wr_en_lane4(wr_en_lane4), .wr_go_lane4(wr_go_lane4), .burstcount_lane4(burstcount_lane4),
        .wr_wait_lane4(wr_wait_lane4), .wr_done_lane4(wr_done_lane4), .owner());

    ddr3_read_arbiter u_rarb (
        .clk(clk), .rst(rst),
        .video_req(v_req), .video_addr(v_addr), .video_burstlen(v_burstlen),
        .video_gnt(v_gnt), .video_rvalid(v_rvalid), .video_rdata(), .video_done(v_done),
        .audio_req(1'b0), .audio_addr(32'd0), .audio_burstlen(8'd0),
        .audio_gnt(), .audio_rvalid(), .audio_rdata(), .audio_done(),
        .tx_req(1'b0), .tx_addr(32'd0), .tx_burstlen(8'd0),
        .tx_gnt(), .tx_rvalid(), .tx_rdata(), .tx_done(),
        .rest_req(r_req), .rest_addr(r_addr), .rest_burstlen(r_burstlen),
        .rest_gnt(r_gnt), .rest_rvalid(r_rvalid), .rest_rdata(r_rdata), .rest_done(r_done),
        .addr_lane5(addr_lane5), .rd_en_lane5(rd_en_lane5), .rd_go_lane5(rd_go_lane5),
        .burstcount_lane5(burstcount_lane5), .rd_valid_lane5(rd_valid_lane5),
        .rd_data_lane5(rd_data_lane5), .rd_rdy_lane5(rd_rdy_lane5), .owner());

    // Behavioral DDR3 lane: 9 clocks of read latency, random stalls (3 percent chance per idle
    // clock, up to 32 clocks) and BEAT_SKIP = 3, a data beat dropped on every third clock.
    ddr3_lane_behav_model #(.MEM_WORDS(1 << 18), .RD_LATENCY(9), .STALL_NUM(30), .STALL_DEN(1000),
                             .STALL_MAX_CYCLES(32), .SEED(32'hF6_3A7E), .BEAT_SKIP(3)) u_lane (
        .clk(clk), .rst(rst),
        .addr_lane4(addr_lane4), .wr_mask_lane4(wr_mask_lane4), .wr_data_lane4(wr_data_lane4),
        .wr_en_lane4(wr_en_lane4), .wr_go_lane4(wr_go_lane4), .burstcount_lane4(burstcount_lane4),
        .wr_wait_lane4(wr_wait_lane4), .wr_done_lane4(wr_done_lane4),
        .addr_lane5(addr_lane5), .rd_en_lane5(rd_en_lane5), .rd_go_lane5(rd_go_lane5),
        .burstcount_lane5(burstcount_lane5), .rd_valid_lane5(rd_valid_lane5),
        .rd_data_lane5(rd_data_lane5), .rd_rdy_lane5(rd_rdy_lane5), .phys_busy());

    // One clock, then 1 ns later, so that the bench changes its inputs after the clock edge.
    task step;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    integer i, t, fd;
    // Put the spectrogram into DDR3, release reset, announce the start of a slot for receiver
    // RX and then claim that 372 frames have been written, which starts the full search.
    initial begin
        frame_ptr  = 0;
        slot_start = 0;
        for (i = 0; i < 372 * 512; i = i + 1) u_lane.mem[SPEC_BASE + i] = spec[i];
        repeat (4) step;
        rst = 0;
        repeat (4) step;
        slot_start[RX] = 1'b1;
        step;
        slot_start = 0;
        repeat (4) step;
        frame_ptr[RX*9 +: 9] = 9'd372;
        // Wait for the search to finish, at most 40 million clocks.
        t = 0;
        while (!irq && t < 40_000_000) begin
            step;
            t = t + 1;
        end
        // The interrupt must come from receiver RX and cover all 372 rows.
        if (!irq || irq_rx != RX || irq_rows != 9'd372) begin
            $display("FAIL: no interrupt for the full search (rx %0d rows %0d)", irq_rx, irq_rows);
        end else begin
            // Save the records for the model comparison.
            fd = $fopen(`OUT_FILE, "w");
            for (i = 0; i < 4 * NBINS; i = i + 1) $fdisplay(fd, "%016x", u_lane.mem[REC_BASE + i]);
            $fclose(fd);
            $display("search over band %0d .. %0d (%0d bins): %0d clocks = %0.2f ms at 150 MHz; video %0d underruns, lowest FIFO fill %0d words",
                     IA, IB, NBINS, run_clocks, run_clocks / 150000.0, v_underruns, v_min_fill);
            $display("DONE");
        end
        $finish;
    end
endmodule
