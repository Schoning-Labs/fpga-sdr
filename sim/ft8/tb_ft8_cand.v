// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Unit test of the FT8 candidate engine, rtl/ft8/ft8_cand.v (design in docs/F7_CAND.md). Once the
// sync search has found likely signals, this engine takes a candidate's frequency and timing and
// produces what the LDPC decoder needs. Pass 1 replays the whole 15 second slot of 12 ksps audio
// from a capture ring in DDR3 through a numerically controlled oscillator (a digital sine and
// cosine source, see docs/learn/GLOSSARY.md) that shifts the candidate's frequency down to zero
// and through a decimating filter, which leaves 3,200 complex baseband words per candidate. Pass
// 2 reads that baseband back, locates the symbol grid with a start sample, and runs a small DFT
// per symbol to get 632 soft-symbol words (79 symbols with 8 tones each). Two candidates are
// handled at once, one per lane.
//
// The engine is wired to the real DDR3 write and read arbiters and to the behavioral DDR3 lanes,
// so that the test also covers the traffic around it, and the results are compared with the Rust
// reference model's functions `baseband_fx` and `symbols_fx` bit for bit. The DDR3 stand-in is
// the same as in sim/ft8/tb_ft8_sync.v: a 150 MHz engine clock, a lane that delivers a data beat on
// two of every three clocks (BEAT_SKIP = 3, which is 100 MHz of throughput), random lane stalls,
// the video scan-out model on the top read tier and IQ writes on the top write tier.
//
// Stimulus: a full slot (180,000 samples) of full-scale random audio, the top 16 bits of a 32 bit
// linear congruential generator (s = 1,664,525 s + 1,013,904,223, starting at 0x0F7C_A11D, the same
// sequence `ft8-frontend f7-synth` produces for the model), written 4 samples per lane word into a
// capture ring in such a way that the slot starts 5,001 samples before the end of the ring. That
// is not a multiple of 4, so the packing has to cope with an odd start, and the replay wraps
// around the end of the ring. One pass-1 command runs both lanes (candidates at 1,234.5 Hz and
// 2,871.25 Hz) and one pass-2 command runs both lanes on their own baseband, with start samples
// 1,203 and -9, so that the second candidate begins partly before its baseband and the engine
// has to feed zeros there.
//
// Pass criterion: all 6,400 baseband words (2 x 3,200) and 1,264 soft-symbol words (2 x 632)
// are read out of the DDR3 model and compared with sim/ft8/vectors/f7_synth_pass1.hex and
// f7_synth_pass2.hex, and the video client must not underrun. The bench prints "PASS: tb_ft8_cand
// (...)" on success and "FAIL" with an error count otherwise, together with the length of each
// pass in clocks.
//
// Run from the repository root, as tools/check.sh does for every tb_*.v: iverilog -g2012 -o
// out.vvp sim/ft8/tb_ft8_cand.v, then vvp out.vvp. Add -DTB_LANES=1 to build the engine with a
// single lane.

`timescale 1ns / 1ps
`include "rtl/ft8/ft8_cand.v"
`include "rtl/ddr3/ddr3_write_arbiter.v"
`include "rtl/ddr3/ddr3_read_arbiter.v"
`include "sim/ddr3/ddr3_lane_behav_model.v"
`include "sim/ddr3/write_traffic_client.v"
`include "sim/ddr3/video_scanout_model.v"

module tb_ft8_cand;
    // The capture ring holds 2^19 samples. The slot starts 5,001 samples before its end, so
    // the replay wraps. BB0 and BB1 are the word addresses where the two lanes write their
    // baseband, SY0 and SY1 where they write their soft symbols.
    localparam integer RING_SAMPLES = 1 << 19;
    localparam integer CAP_BASE = 32'h0000_0000;
    localparam integer FIRST    = RING_SAMPLES - 5001;
    localparam integer BB0 = 32'h0002_0000, BB1 = 32'h0002_1000;
    localparam integer SY0 = 32'h0002_2000, SY1 = 32'h0002_2400;

    // 150 MHz: 6.666 ns period, 3.333 ns per half period.
    reg clk = 0;
    always #3.333 clk = ~clk;
    reg rst = 1;

    // Candidate records (96 bits: pass 1 increment in 95:64, pass 2 increment in 63:32, start
    // sample in 15:0) and the model's expected words for both lanes, 3,200 baseband words and 632
    // soft-symbol words each.
    reg [95:0] cands [0:1];
    reg [63:0] exp1 [0:2*3200-1];
    reg [63:0] exp2 [0:2*632-1];
    initial begin
        $readmemh("sim/ft8/vectors/f7_synth_cands.hex", cands);
        $readmemh("sim/ft8/vectors/f7_synth_pass1.hex", exp1);
        $readmemh("sim/ft8/vectors/f7_synth_pass2.hex", exp2);
    end

    // ---------------------------------------------------------------- DUT
    // ---------------------------------------------------------------- DUT
    reg         cmd_start, cmd_pass2;
    reg  [63:0] lane_inc;
    reg  [31:0] lane_i0;
    wire busy, irq;
    wire [31:0] run_clocks;
    wire        c_rd_req, c_rd_gnt, c_rd_rvalid, c_rd_done;
    wire [31:0] c_rd_addr;
    wire [7:0]  c_rd_burstlen;
    wire [63:0] c_rd_rdata;
    wire        c_wr_req, c_wr_gnt, c_wr_done;
    wire [31:0] c_wr_addr;
    wire [7:0]  c_wr_burstlen, c_wr_wmask;
    wire [63:0] c_wr_wdata;

`ifndef TB_LANES
`define TB_LANES 2       // -DTB_LANES=1 builds the engine with one lane, which then runs twice per command
`endif
    ft8_cand #(.RING_SAMPLES(RING_SAMPLES), .LANES(`TB_LANES)) dut (
        .clk(clk), .rst(rst),
        .cmd_start(cmd_start), .cmd_pass2(cmd_pass2), .cmd_lanes(2'b11),
        .cap_ring_base(CAP_BASE[31:0]), .slot_first_sample(FIRST[31:0]),
        .lane_inc(lane_inc), .lane_i0(lane_i0),
        .lane_bb_base({BB1[31:0], BB0[31:0]}), .lane_sym_base({SY1[31:0], SY0[31:0]}),
        .busy(busy), .irq(irq), .run_clocks(run_clocks),
        .rd_req(c_rd_req), .rd_addr(c_rd_addr), .rd_burstlen(c_rd_burstlen), .rd_gnt(c_rd_gnt),
        .rd_rvalid(c_rd_rvalid), .rd_rdata(c_rd_rdata), .rd_done(c_rd_done),
        .wr_req(c_wr_req), .wr_addr(c_wr_addr), .wr_burstlen(c_wr_burstlen), .wr_wdata(c_wr_wdata),
        .wr_wmask(c_wr_wmask), .wr_gnt(c_wr_gnt), .wr_done(c_wr_done)
    );

    // ---------------------------------------------------------------- video, IQ, arbiters, lanes
    wire        v_req, v_gnt, v_rvalid, v_done;
    wire [31:0] v_addr;
    wire [7:0]  v_burstlen;
    wire signed [31:0] v_min_fill;
    wire [31:0] v_underruns;
    // Stand-in for the video scan-out, whose long read bursts the engine's read FIFO has to bridge.
    video_scanout_model #(.BASE_ADDR(32'h0003_C000), .RING_WORDS(1 << 14), .BURSTLEN(180),
                          .LINE_WORDS(720), .LINE_PERIOD_CYCLES(2222), .FIFO_DEPTH_LINES(2)) u_video (
        .clk(clk), .rst(rst), .enable(1'b1),
        .req(v_req), .addr(v_addr), .burstlen(v_burstlen), .gnt(v_gnt), .rvalid(v_rvalid), .done(v_done),
        .fifo_fill(), .min_fifo_fill(v_min_fill), .underrun_events(v_underruns), .words_done(),
        .max_wait_cycles());

    wire        iq_req, iq_gnt, iq_done;
    wire [31:0] iq_addr;
    wire [7:0]  iq_burstlen, iq_wmask;
    wire [63:0] iq_wdata;
    // Stand-in for the IQ capture, writing on the highest write tier.
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

    // The arbiters share one write lane and one read lane between the clients, the engine being
    // on the lowest write tier and on the "rest" read tier.
    ddr3_write_arbiter u_warb (
        .clk(clk), .rst(rst),
        .iq_req(iq_req), .iq_addr(iq_addr), .iq_burstlen(iq_burstlen), .iq_wdata(iq_wdata), .iq_wmask(iq_wmask), .iq_gnt(iq_gnt), .iq_done(iq_done),
        .wf_req(1'b0), .wf_addr(32'd0), .wf_burstlen(8'd0), .wf_wdata(64'd0), .wf_wmask(8'd0), .wf_gnt(), .wf_done(),
        .cap_req(1'b0), .cap_addr(32'd0), .cap_burstlen(8'd0), .cap_wdata(64'd0), .cap_wmask(8'd0), .cap_gnt(), .cap_done(),
        .ft8_req(c_wr_req), .ft8_addr(c_wr_addr), .ft8_burstlen(c_wr_burstlen), .ft8_wdata(c_wr_wdata), .ft8_wmask(c_wr_wmask), .ft8_gnt(c_wr_gnt), .ft8_done(c_wr_done),
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
        .rest_req(c_rd_req), .rest_addr(c_rd_addr), .rest_burstlen(c_rd_burstlen),
        .rest_gnt(c_rd_gnt), .rest_rvalid(c_rd_rvalid), .rest_rdata(c_rd_rdata), .rest_done(c_rd_done),
        .addr_lane5(addr_lane5), .rd_en_lane5(rd_en_lane5), .rd_go_lane5(rd_go_lane5),
        .burstcount_lane5(burstcount_lane5), .rd_valid_lane5(rd_valid_lane5),
        .rd_data_lane5(rd_data_lane5), .rd_rdy_lane5(rd_rdy_lane5), .owner());

    // Behavioral DDR3 lane: 9 clocks of read latency, random stalls (3 percent chance per idle
    // clock, up to 32 clocks) and BEAT_SKIP = 3, a data beat dropped on every third clock.
    ddr3_lane_behav_model #(.MEM_WORDS(1 << 18), .RD_LATENCY(9), .STALL_NUM(30), .STALL_DEN(1000),
                             .STALL_MAX_CYCLES(32), .SEED(32'hF7_C4D1), .BEAT_SKIP(3)) u_lane (
        .clk(clk), .rst(rst),
        .addr_lane4(addr_lane4), .wr_mask_lane4(wr_mask_lane4), .wr_data_lane4(wr_data_lane4),
        .wr_en_lane4(wr_en_lane4), .wr_go_lane4(wr_go_lane4), .burstcount_lane4(burstcount_lane4),
        .wr_wait_lane4(wr_wait_lane4), .wr_done_lane4(wr_done_lane4),
        .addr_lane5(addr_lane5), .rd_en_lane5(rd_en_lane5), .rd_go_lane5(rd_go_lane5),
        .burstcount_lane5(burstcount_lane5), .rd_valid_lane5(rd_valid_lane5),
        .rd_data_lane5(rd_data_lane5), .rd_rdy_lane5(rd_rdy_lane5), .phys_busy());

    // ---------------------------------------------------------------- stimulus and checks
    // One clock, then 1 ns later, so that the bench changes its inputs after the clock edge.
    task step;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    integer errors = 0;
    // Starts a command with a one clock cmd_start, waits for irq (at most 2 million clocks) and
    // prints how many clocks the engine needed.
    task run_cmd(input p2);
        integer t;
        begin
            cmd_pass2 = p2;
            cmd_start = 1'b1;
            step;
            cmd_start = 1'b0;
            t = 0;
            while (!irq && t < 2_000_000) begin
                step;
                t = t + 1;
            end
            if (!irq) begin
                $display("FAIL: pass %0d did not finish", p2 + 1);
                errors = errors + 1;
            end else begin
                $display("pass %0d: %0d clocks (%0.3f ms at 150 MHz)", p2 + 1, run_clocks, run_clocks / 150000.0);
            end
            step;
        end
    endtask

    // Compares n words that one lane wrote at word address `base` with the model's words from
    // index `off` on. The first five mismatches are printed.
    task check(input integer base, input integer n, input integer off, input p2, input integer lane);
        integer k, mism;
        reg [63:0] got, want;
        begin
            mism = 0;
            for (k = 0; k < n; k = k + 1) begin
                got  = u_lane.mem[base + k];
                want = p2 ? exp2[off + k] : exp1[off + k];
                if (got !== want) begin
                    mism = mism + 1;
                    if (mism <= 5)
                        $display("MISMATCH pass %0d lane %0d word %0d: got %016x want %016x", p2 + 1, lane, k, got, want);
                end
            end
            errors = errors + mism;
            $display("pass %0d lane %0d: %0d words, %0d mismatches", p2 + 1, lane, n, mism);
        end
    endtask

    // n and w index the audio samples and ring words, lcg is the generator state, word is the
    // lane word being assembled.
    integer n, w;
    reg [31:0] lcg;
    reg [63:0] word;
    initial begin
        cmd_start = 0; cmd_pass2 = 0;
        lane_inc  = {cands[1][95:64], cands[0][95:64]};
        lane_i0   = 0;
        // Write the slot's audio into the capture ring, 4 samples per lane word (sample p in word
        // p / 4, bits 16 (p mod 4) + 15 down to 16 (p mod 4)), from ring sample FIRST on.
        lcg = 32'h0F7C_A11D;
        for (n = 0; n < 180000; n = n + 1) begin
            lcg = lcg * 32'd1664525 + 32'd1013904223;
            w = ((FIRST + n) % RING_SAMPLES) / 4;
            word = u_lane.mem[CAP_BASE + w];
            word[16 * ((FIRST + n) % 4) +: 16] = lcg[31:16];
            u_lane.mem[CAP_BASE + w] = word;
        end
        repeat (4) step;
        // Release reset and let the engine settle.
        rst = 0;
        repeat (20) step;

        // Pass 1, both lanes: 3,200 baseband words each, from the model's words 0 and 3,200 on.
        run_cmd(1'b0);
        check(BB0, 3200, 0, 1'b0, 0);
        check(BB1, 3200, 3200, 1'b0, 1);

        // Pass 2, both lanes: the rotation increments and start samples come from the low words
        // of the candidate records, and each lane reads its own baseband back. The model's soft
        // symbols are 632 words per lane.
        lane_inc = {cands[1][63:32], cands[0][63:32]};
        lane_i0  = {cands[1][15:0], cands[0][15:0]};
        run_cmd(1'b1);
        check(SY0, 632, 0, 1'b1, 0);
        check(SY1, 632, 632, 1'b1, 1);

        // The video client must not have starved while the engine was working.
        $display("video: %0d underruns, lowest FIFO fill %0d words", v_underruns, v_min_fill);
        if (v_underruns != 0) errors = errors + 1;
        if (errors == 0) $display("PASS: tb_ft8_cand (%0d lanes built, pass 1 and pass 2 bit-exact)", `TB_LANES);
        else $display("FAIL: tb_ft8_cand, %0d errors", errors);
        $finish;
    end
endmodule
