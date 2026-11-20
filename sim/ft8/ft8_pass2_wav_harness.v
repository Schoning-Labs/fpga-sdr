// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Bench for the second FT8 decode pass on the whole FT8 front end, rtl/ft8/ft8_frontend.v, the
// block that the chip instantiates (docs/FT8_PASS2.md). FT8 decoders usually run twice: the first
// pass finds the strong signals, the CPU subtracts them from the audio, and the second pass looks
// for weaker signals that were hidden underneath. The hardware part of that second pass is a
// replay of the residual audio (the slot's audio with the first pass's decodes removed) through
// the same transform that serves the live receivers, followed by the Costas sync search over the
// resulting spectrogram, and this bench runs exactly that.
//
// Stimulus: the residual audio of one recording (45,000 lane words, 4 samples of 16 bits each,
// written by `ft8-frontend pass2-vectors`) is copied into the DDR3 model where the CPU would put
// it. The bench then drives the register page the way the firmware does: the band of receiver RX
// (bins IA .. IB), its power shift (16) with capture off, the base address of the residual (the
// replay's spectrogram goes to base + 0x1_0000 and the search's records to base + 0x4_0000), the
// p2_done interrupt enable, and finally p2_cmd. The interrupt ends the run.
//
// The DDR3 behind it is the same unkind stand-in as in sim/ft8/tb_ft8_sync.v: a 150 MHz engine
// clock, a lane that delivers a data beat on two of every three clocks (100 MHz of throughput),
// random stalls, a video read client on the top read tier and IQ writes on the top write tier.
//
// Pass criterion: this bench does not compare the words itself. It checks that the interrupt
// arrives with irq_status equal to p2_done only and with the frame counter at 372, and then
// writes the replay's spectrogram (372 frames x 512 lane words) to SPEC_OUT and the search's
// records (4 lane words per bin) to OUT_FILE. It prints "DONE" on success and "FAIL" if the
// interrupt does not come within 60 million clocks. `ft8-frontend pass2-check` then compares
// both files bit for bit with the Rust model and runs the two-pass decode on the RTL's records.
// The bench prints the length of the replay and of the search in clocks and in milliseconds.
//
// It is not a tb_*.v file because it needs vectors made from the recordings in captures/, and
// one run takes about 20 million clocks. tools/check_ft8_pass2.sh builds the vectors, compiles
// this file with iverilog -g2012 and runs it with vvp, passing the defines RES_FILE, OUT_FILE,
// SPEC_OUT, BAND_IA and BAND_IB.

`timescale 1ns / 1ps
`include "rtl/ft8/ft8_frontend.v"
`include "rtl/ddr3/ddr3_write_arbiter.v"
`include "rtl/ddr3/ddr3_read_arbiter.v"
`include "sim/ddr3/ddr3_lane_behav_model.v"
`include "sim/ddr3/write_traffic_client.v"
`include "sim/ddr3/video_scanout_model.v"

module ft8_pass2_wav_harness;
    // Receiver 5 is the one used, with a band of bins IA .. IB (bin k is k x 12,000 / 3,840 =
    // 3.125 Hz x k, so 32 .. 960 is 100 Hz to 3,000 Hz). RES_WORDS is 180,000 samples / 4.
    // RES_BASE, SPEC_BASE and REC_BASE are word addresses in the DDR3 model.
    localparam integer RX        = 5;
    localparam integer IA        = `BAND_IA, IB = `BAND_IB;
    localparam integer NBINS     = IB - IA + 1;
    localparam integer RES_WORDS = 45000;
    localparam integer RES_BASE  = 32'h0000_0000;
    localparam integer SPEC_BASE = 32'h0001_0000;
    localparam integer REC_BASE  = 32'h0004_0000;

    // 150 MHz: 6.666 ns period, 3.333 ns per half period.
    reg clk = 0;
    always #3.333 clk = ~clk;
    reg rst = 1;

    // The residual audio, 4 samples per 64-bit word.
    reg [63:0] res [0:RES_WORDS-1];
    initial $readmemh(`RES_FILE, res);

    // Register bus of the front end, driven by the tasks wr and rd below.
    reg         bus_wr = 1'b0, bus_rd = 1'b0;
    reg  [15:0] bus_addr = 16'd0;
    reg  [31:0] bus_wdata = 32'd0;
    wire [31:0] bus_rdata;
    wire        irq;

    // DDR3 client ports of the front end, wired to the arbiters below.
    wire        f_wr_req, f_wr_gnt, f_wr_done;
    wire [31:0] f_wr_addr;
    wire [7:0]  f_wr_burstlen, f_wr_wmask;
    wire [63:0] f_wr_wdata;
    wire        f_rd_req, f_rd_gnt, f_rd_rvalid, f_rd_done;
    wire [31:0] f_rd_addr;
    wire [7:0]  f_rd_burstlen;
    wire [63:0] f_rd_rdata;

    // The front end: no live audio here (audio_valid tied low), only the register bus and DDR3.
    ft8_frontend dut (
        .clk(clk), .rst(rst),
        .audio_valid(1'b0), .audio_rx(3'd0), .audio_sample(16'd0), .audio_iq(1'b0),
        .bus_wr(bus_wr), .bus_rd(bus_rd), .bus_addr(bus_addr), .bus_wdata(bus_wdata),
        .bus_rdata(bus_rdata),
        .wr_req(f_wr_req), .wr_addr(f_wr_addr), .wr_burstlen(f_wr_burstlen), .wr_wdata(f_wr_wdata),
        .wr_wmask(f_wr_wmask), .wr_gnt(f_wr_gnt), .wr_done(f_wr_done),
        .rd_req(f_rd_req), .rd_addr(f_rd_addr), .rd_burstlen(f_rd_burstlen), .rd_gnt(f_rd_gnt),
        .rd_rvalid(f_rd_rvalid), .rd_rdata(f_rd_rdata), .rd_done(f_rd_done),
        .irq(irq)
    );

    // Stand-in for the video scan-out on the top read tier.
    wire        v_req, v_gnt, v_rvalid, v_done;
    wire [31:0] v_addr;
    wire [7:0]  v_burstlen;
    wire signed [31:0] v_min_fill;
    wire [31:0] v_underruns;
    video_scanout_model #(.BASE_ADDR(32'h0006_0000), .RING_WORDS(1 << 14), .BURSTLEN(180),
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
    write_traffic_client #(.BASE_ADDR(32'h0005_0000), .RING_WORDS(4096), .BURSTLEN(4),
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
        .ft8_req(f_wr_req), .ft8_addr(f_wr_addr), .ft8_burstlen(f_wr_burstlen), .ft8_wdata(f_wr_wdata), .ft8_wmask(f_wr_wmask), .ft8_gnt(f_wr_gnt), .ft8_done(f_wr_done),
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
        .rest_req(f_rd_req), .rest_addr(f_rd_addr), .rest_burstlen(f_rd_burstlen),
        .rest_gnt(f_rd_gnt), .rest_rvalid(f_rd_rvalid), .rest_rdata(f_rd_rdata), .rest_done(f_rd_done),
        .addr_lane5(addr_lane5), .rd_en_lane5(rd_en_lane5), .rd_go_lane5(rd_go_lane5),
        .burstcount_lane5(burstcount_lane5), .rd_valid_lane5(rd_valid_lane5),
        .rd_data_lane5(rd_data_lane5), .rd_rdy_lane5(rd_rdy_lane5), .owner());

    // Behavioral DDR3 lane: 9 clocks of read latency, random stalls (3 percent chance per idle
    // clock, up to 32 clocks) and BEAT_SKIP = 3, a data beat dropped on every third clock.
    ddr3_lane_behav_model #(.MEM_WORDS(1 << 19), .RD_LATENCY(9), .STALL_NUM(30), .STALL_DEN(1000),
                             .STALL_MAX_CYCLES(32), .SEED(32'hF8_2A55), .BEAT_SKIP(3)) u_lane (
        .clk(clk), .rst(rst),
        .addr_lane4(addr_lane4), .wr_mask_lane4(wr_mask_lane4), .wr_data_lane4(wr_data_lane4),
        .wr_en_lane4(wr_en_lane4), .wr_go_lane4(wr_go_lane4), .burstcount_lane4(burstcount_lane4),
        .wr_wait_lane4(wr_wait_lane4), .wr_done_lane4(wr_done_lane4),
        .addr_lane5(addr_lane5), .rd_en_lane5(rd_en_lane5), .rd_go_lane5(rd_go_lane5),
        .burstcount_lane5(burstcount_lane5), .rd_valid_lane5(rd_valid_lane5),
        .rd_data_lane5(rd_data_lane5), .rd_rdy_lane5(rd_rdy_lane5), .phys_busy());

    // Register accesses as rtl/top/sdr_core.v makes them: a one clock strobe with address
    // and data, followed by four idle clocks (the front end acts two clocks after a write, and
    // read data is valid four clocks after the strobe).
    task wr(input [31:0] a, input [31:0] d);
        begin
            @(posedge clk); bus_addr <= a[15:0]; bus_wdata <= d; bus_wr <= 1'b1;
            @(posedge clk); bus_wr <= 1'b0;
            repeat (4) @(posedge clk);
        end
    endtask
    task rd(input [31:0] a, output [31:0] d);
        begin
            @(posedge clk); bus_addr <= a[15:0]; bus_rd <= 1'b1;
            @(posedge clk); bus_rd <= 1'b0;
            repeat (4) @(posedge clk);
            #1 d = bus_rdata;
        end
    endtask

    // t counts clocks of the whole run, t_replay is the clock where the replay finished.
    integer i, t, fd;
    integer t_replay = 0;
    always @(posedge clk) if (dut.rp_done_w) t_replay = t;

    reg [31:0] v, st;
    // Fill the DDR3 model with the residual, release reset and program the front end.
    initial begin
        for (i = 0; i < RES_WORDS; i = i + 1) u_lane.mem[RES_BASE + i] = res[i];
        repeat (8) @(posedge clk);
        rst <= 1'b0;
        repeat (20) @(posedge clk);
        // Band of receiver RX, then its power shift of 16, the residual's base address, the
        // interrupt enable for p2_done and the second pass command for receiver RX.
        wr(`FT8_BAND_ADDR(RX), (IB << `FT8_BAND_IB_LSB) | IA);
        wr(`FT8_CTRL_ADDR(RX), 32'd16 << `FT8_CTRL_PWR_SHIFT_LSB);    // capture off, shift 16
        wr(`FT8_P2_BASE_ADDR, RES_BASE);          // spectrogram at + 0x1_0000, records at + 0x4_0000
        wr(`FT8_IRQ_ENABLE_ADDR, 32'd1 << `FT8_IRQ_ENABLE_P2_DONE_LSB);
        wr(`FT8_P2_CMD_ADDR, RX);
        // Wait for the interrupt, which means the replay and the search are both finished.
        t = 0;
        while (!irq && t < 60_000_000) begin
            @(posedge clk);
            t = t + 1;
        end
        // Read back the interrupt status and the replay's frame counter, which must be 372 (a
        // full slot at one frame per 480 samples).
        rd(`FT8_IRQ_STATUS_ADDR, st);
        rd(`FT8_P2_FRAME_ADDR, v);
        if (!irq || st != (32'd1 << `FT8_IRQ_STATUS_P2_DONE_LSB) || v != 32'd372) begin
            $display("FAIL: no p2_done (irq %b, irq_status %08x, p2_frame %0d)", irq, st, v);
        end else begin
            // Write out the search records and the replay's spectrogram for the model comparison.
            rd(`FT8_SYNC_CLOCKS_ADDR, v);
            fd = $fopen(`OUT_FILE, "w");
            for (i = 0; i < 4 * NBINS; i = i + 1) $fdisplay(fd, "%016x", u_lane.mem[REC_BASE + i]);
            $fclose(fd);
            fd = $fopen(`SPEC_OUT, "w");
            for (i = 0; i < 372 * 512; i = i + 1) $fdisplay(fd, "%016x", u_lane.mem[SPEC_BASE + i]);
            $fclose(fd);
            $display("second pass on the chip: replay of 372 frames %0d clocks = %0.2f ms, search of %0d bins %0d clocks = %0.2f ms, p2_cmd to p2_done %0d clocks = %0.2f ms at 150 MHz; video %0d underruns, lowest FIFO fill %0d words",
                     t_replay, t_replay / 150000.0, NBINS, v, v / 150000.0, t, t / 150000.0, v_underruns, v_min_fill);
            $display("DONE");
        end
        $finish;
    end
endmodule
