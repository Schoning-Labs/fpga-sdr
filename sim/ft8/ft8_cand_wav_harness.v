// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Full-recording bench for the FT8 candidate engine, rtl/ft8/ft8_cand.v. That engine takes one
// receiver's whole 15 second slot of 12 ksps audio from a ring in DDR3 and, for two candidate
// signals at a time (its two lanes), turns it into a short complex baseband (pass 1, 3,200 words
// per candidate) and then into soft symbols for the decoder (pass 2, 632 words per candidate,
// which is 79 FT8 symbols times 8 tones). Both passes write their words back to DDR3, and this
// bench checks every one of those words bit for bit against the Rust reference model
// (fw/tr-modes, the `ft8-frontend` tool), so a single wrong bit anywhere in the pipeline shows up.
//
// The bench runs about 50 million clocks and needs test vectors made from the recordings in
// captures/, so it is not a tb_*.v file that tools/check.sh could compile on its own. It is
// started by tools/check_ft8_cand.sh, which builds the vectors with `ft8-frontend f7-vectors`,
// compiles this file with iverilog and runs it with vvp. The script passes these defines:
// VEC3 and VEC1 (the vector directories of the qso3_busy and qso1 recordings), OUT_DIR (where
// the RTL's output words are written) and N_RX (how many receivers to run, default 8).
//
// The DDR3 around the engine is the same stand-in as in sim/ft8/tb_ft8_cand.v and is meant to
// be unkind: a 150 MHz engine clock, a lane that delivers a data beat on only two of every three
// clocks (which is 100 MHz of lane throughput), random stalls before new bursts, a video read
// client that takes a long burst on the top read tier, and IQ writes on the top write tier.
//
// Stimulus: two capture rings (each RING_SAMPLES = 2^18 samples) hold the two recordings.
// The qso3_busy slot starts 7,777 samples before the end of its ring, so the replay has to
// wrap around the ring, and the qso1 slot starts at ring sample 12,345. Receivers 0, 2, 4 and 6
// then decode qso3_busy and receivers 1, 3, 5 and 7 decode qso1, which is only a way of making
// the engine work through eight different slot positions. Per receiver the bench runs the 60
// candidates the reference model picks, as 30 pass-1 commands and 30 pass-2 commands (two
// candidates per command), so 480 candidates and 480 commands for eight receivers.
//
// Pass criterion: every baseband word and every soft-symbol word must equal the model's, and
// the video client must not underrun. The bench prints "PASS: ft8_cand_wav_harness (every word
// bit-exact)" on success and "FAIL:" with the mismatch count otherwise, plus up to three
// MISMATCH lines per candidate and the total simulated time. The words of receivers 0 and 1 are
// also written to OUT_DIR so that `ft8-frontend cand-check` can run the LDPC decoder on the
// RTL's own soft symbols and show that the whole chain still decodes.

`timescale 1ns / 1ps
`include "rtl/ft8/ft8_cand.v"
`include "rtl/ddr3/ddr3_write_arbiter.v"
`include "rtl/ddr3/ddr3_read_arbiter.v"
`include "sim/ddr3/ddr3_lane_behav_model.v"
`include "sim/ddr3/write_traffic_client.v"
`include "sim/ddr3/video_scanout_model.v"

`ifndef N_RX
`define N_RX 8
`endif

module ft8_cand_wav_harness;
    // Each ring holds 2^18 samples; the lane packs 4 samples (16 bits each) into one 64-bit word,
    // so a ring is RING_SAMPLES / 4 lane words. CAP3 and CAP1 are the word addresses of the
    // two rings, one after the other. FIRST3 and FIRST1 are the ring sample numbers where the
    // 180,000 sample slot (15 s at 12 ksps) begins. BB* and SY* are the word addresses where
    // the two lanes write their baseband words and their soft symbols.
    localparam integer RING_SAMPLES = 1 << 18;
    localparam integer RING_WORDS   = RING_SAMPLES / 4;
    localparam integer CAP3 = 32'h0000_0000, CAP1 = RING_WORDS;
    localparam integer FIRST3 = RING_SAMPLES - 7777, FIRST1 = 12345;
    localparam integer BB0 = 32'h0002_0000, BB1 = 32'h0002_1000;
    localparam integer SY0 = 32'h0002_2000, SY1 = 32'h0002_2400;

    // 150 MHz: 6.666 ns period, 3.333 ns per half period.
    reg clk = 0;
    always #3.333 clk = ~clk;
    reg rst = 1;

    // Test vectors as 64-bit words: audio is 4 samples per word (45,000 words of 180,000
    // samples), cd is one 96-bit candidate record (pass 1 increment in bits 95:64, pass 2
    // increment in 63:32 and start sample in 15:0), e1 and e2 are the model's expected pass-1
    // (3,200 words) and pass-2 (632 words) output for each of the 60 candidates. The suffix 3
    // is qso3_busy and 1 is qso1.
    reg [63:0] au3 [0:44999];
    reg [63:0] au1 [0:44999];
    reg [95:0] cd3 [0:59];
    reg [95:0] cd1 [0:59];
    reg [63:0] e1_3 [0:60*3200-1];
    reg [63:0] e1_1 [0:60*3200-1];
    reg [63:0] e2_3 [0:60*632-1];
    reg [63:0] e2_1 [0:60*632-1];
    initial begin
        $readmemh({`VEC3, "/audio_lw.hex"}, au3);
        $readmemh({`VEC1, "/audio_lw.hex"}, au1);
        $readmemh({`VEC3, "/cands.hex"}, cd3);
        $readmemh({`VEC1, "/cands.hex"}, cd1);
        $readmemh({`VEC3, "/pass1.hex"}, e1_3);
        $readmemh({`VEC1, "/pass1.hex"}, e1_1);
        $readmemh({`VEC3, "/pass2.hex"}, e2_3);
        $readmemh({`VEC1, "/pass2.hex"}, e2_1);
    end

    reg         cmd_start, cmd_pass2;
    reg  [31:0] cap_base, first;
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

    ft8_cand #(.RING_SAMPLES(RING_SAMPLES)) dut (
        .clk(clk), .rst(rst),
        .cmd_start(cmd_start), .cmd_pass2(cmd_pass2), .cmd_lanes(2'b11),
        .cap_ring_base(cap_base), .slot_first_sample(first),
        .lane_inc(lane_inc), .lane_i0(lane_i0),
        .lane_bb_base({BB1[31:0], BB0[31:0]}), .lane_sym_base({SY1[31:0], SY0[31:0]}),
        .busy(busy), .irq(irq), .run_clocks(run_clocks),
        .rd_req(c_rd_req), .rd_addr(c_rd_addr), .rd_burstlen(c_rd_burstlen), .rd_gnt(c_rd_gnt),
        .rd_rvalid(c_rd_rvalid), .rd_rdata(c_rd_rdata), .rd_done(c_rd_done),
        .wr_req(c_wr_req), .wr_addr(c_wr_addr), .wr_burstlen(c_wr_burstlen), .wr_wdata(c_wr_wdata),
        .wr_wmask(c_wr_wmask), .wr_gnt(c_wr_gnt), .wr_done(c_wr_done)
    );

    // A stand-in for the video scan-out, the heaviest reader of DDR3. It makes the engine's
    // read FIFO prove that it can bridge a long video burst.
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

    // Stand-in for the IQ capture that keeps writing to DDR3 on the highest write priority.
    wire        iq_req, iq_gnt, iq_done;
    wire [31:0] iq_addr;
    wire [7:0]  iq_burstlen, iq_wmask;
    wire [63:0] iq_wdata;
    write_traffic_client #(.BASE_ADDR(32'h0003_A000), .RING_WORDS(4096), .BURSTLEN(4),
                           .PERIOD_CYCLES(195)) u_iq (
        .clk(clk), .rst(rst), .enable(1'b1),
        .req(iq_req), .addr(iq_addr), .burstlen(iq_burstlen), .wdata(iq_wdata), .wmask(iq_wmask),
        .gnt(iq_gnt), .done(iq_done), .words_done(), .bursts_done(), .max_wait_cycles());

    // The two arbiters give each client its tier (video and IQ on top, this engine on the lowest
    // write and read tier) and merge them onto one write lane and one read lane.
    wire [31:0] addr_lane4, addr_lane5;
    wire [7:0]  wr_mask_lane4, burstcount_lane4, burstcount_lane5;
    wire [63:0] wr_data_lane4, rd_data_lane5;
    wire wr_en_lane4, wr_go_lane4, wr_wait_lane4, wr_done_lane4;
    wire rd_en_lane5, rd_go_lane5, rd_valid_lane5, rd_rdy_lane5;

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

    // Behavioral DDR3 lane: 9 clocks of read latency, a 3 percent chance (30 of 1,000) per idle
    // clock of a stall of up to 32 clocks, and BEAT_SKIP = 3, which drops one data beat in
    // every three clocks.
    ddr3_lane_behav_model #(.MEM_WORDS(1 << 18), .RD_LATENCY(9), .STALL_NUM(30), .STALL_DEN(1000),
                             .STALL_MAX_CYCLES(32), .SEED(32'hF7_0480), .BEAT_SKIP(3)) u_lane (
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

    // Writes one recording's slot into a ring in the DDR3 model, starting at ring sample `f`
    // (the slot is placed sample by sample, wrapping at the end of the ring), the way the capture
    // writer would have stored it. `which` picks qso1 (1) or qso3_busy (0).
    // put a recording's slot into a ring, from ring sample `f` on
    task load_ring(input integer base, input integer f, input integer which);
        integer n, w, s;
        reg [63:0] src, word;
        begin
            for (n = 0; n < 180000; n = n + 1) begin
                src  = which ? au1[n / 4] : au3[n / 4];
                s    = (f + n) % RING_SAMPLES;
                w    = s / 4;
                word = u_lane.mem[base + w];
                word[16 * (s % 4) +: 16] = src[16 * (n % 4) +: 16];
                u_lane.mem[base + w] = word;
            end
        end
    endtask

    // Pulses cmd_start for one clock and waits for irq. A command that does not finish within
    // 2 million clocks counts as hung, and the bench stops.
    integer errors = 0, cmds = 0;
    integer fd1_3, fd2_3, fd1_1, fd2_1;
    time t_first, t_last;
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
                $display("FAIL: command %0d (pass %0d) did not finish", cmds, p2 + 1);
                errors = errors + 1;
                $finish;
            end
            cmds = cmds + 1;
        end
    endtask

    // Compares the words one lane wrote (pass 1: 3,200 words, pass 2: 632 words, from word
    // address `base`) with the model's words for candidate `c` of receiver `rx`. The first three
    // mismatches of a candidate are printed. Receivers 0 and 1 also save their words to file.
    task check_lane(input integer rx, input integer c, input p2, input integer base);
        integer k, n, mism, off;
        reg [63:0] got, want;
        begin
            n    = p2 ? 632 : 3200;
            off  = c * n;
            mism = 0;
            for (k = 0; k < n; k = k + 1) begin
                got  = u_lane.mem[base + k];
                if (rx % 2) want = p2 ? e2_1[off + k] : e1_1[off + k];
                else        want = p2 ? e2_3[off + k] : e1_3[off + k];
                if (got !== want) begin
                    mism = mism + 1;
                    if (mism <= 3)
                        $display("MISMATCH rx %0d cand %0d pass %0d word %0d: got %016x want %016x",
                                 rx, c, p2 + 1, k, got, want);
                end
                if (rx == 0) $fdisplay(p2 ? fd2_3 : fd1_3, "%016x", got);
                if (rx == 1) $fdisplay(p2 ? fd2_1 : fd1_1, "%016x", got);
            end
            errors = errors + mism;
        end
    endtask

    // Main sequence: fill both rings, release reset, then for every receiver and every pair
    // of candidates run pass 1 and check the baseband, then run pass 2 on the baseband and check
    // the soft symbols.
    integer rx, b, c0;
    reg [95:0] ca, cb;
    initial begin
        cmd_start = 0; cmd_pass2 = 0;
        load_ring(CAP3, FIRST3, 0);
        load_ring(CAP1, FIRST1, 1);
        fd1_3 = $fopen({`OUT_DIR, "/rtl_qso3_busy_pass1.hex"}, "w");
        fd2_3 = $fopen({`OUT_DIR, "/rtl_qso3_busy_pass2.hex"}, "w");
        fd1_1 = $fopen({`OUT_DIR, "/rtl_qso1_pass1.hex"}, "w");
        fd2_1 = $fopen({`OUT_DIR, "/rtl_qso1_pass2.hex"}, "w");
        repeat (4) step;
        rst = 0;
        repeat (20) step;
        t_first = $time;
        for (rx = 0; rx < `N_RX; rx = rx + 1) begin
            cap_base = (rx % 2) ? CAP1 : CAP3;
            first    = (rx % 2) ? FIRST1 : FIRST3;
            for (b = 0; b < 30; b = b + 1) begin
                // Candidates c0 and c0 + 1 go to lane 0 and lane 1. Pass 1 takes each lane's NCO
                // increment from the top 32 bits of its candidate record.
                c0 = 2 * b;
                ca = (rx % 2) ? cd1[c0] : cd3[c0];
                cb = (rx % 2) ? cd1[c0 + 1] : cd3[c0 + 1];
                lane_inc = {cb[95:64], ca[95:64]};
                lane_i0  = 0;
                run_cmd(1'b0);
                check_lane(rx, c0, 1'b0, BB0);
                check_lane(rx, c0 + 1, 1'b0, BB1);
                // Pass 2 reads the baseband back from DDR3, with its own rotation increment and
                // the start sample of the symbol grid.
                lane_inc = {cb[63:32], ca[63:32]};
                lane_i0  = {cb[15:0], ca[15:0]};
                run_cmd(1'b1);
                check_lane(rx, c0, 1'b1, SY0);
                check_lane(rx, c0 + 1, 1'b1, SY1);
            end
            $display("rx %0d done: %0d commands, %0d mismatching words so far, %0.1f ms simulated",
                     rx, cmds, errors, ($time - t_first) / 1.0e6);
        end
        t_last = $time;
        $fclose(fd1_3); $fclose(fd2_3); $fclose(fd1_1); $fclose(fd2_1);
        $display("%0d candidates (%0d receivers x 60) in %0.1f ms simulated at 150 MHz; video %0d underruns, lowest FIFO fill %0d words",
                 2 * cmds / 2, `N_RX, (t_last - t_first) / 1.0e6, v_underruns, v_min_fill);
        if (errors == 0 && v_underruns == 0) $display("PASS: ft8_cand_wav_harness (every word bit-exact)");
        else $display("FAIL: ft8_cand_wav_harness, %0d mismatching words", errors);
        $finish;
    end
endmodule
