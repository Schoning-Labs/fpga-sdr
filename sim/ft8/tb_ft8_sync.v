// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Unit test of the FT8 sync search engine, rtl/ft8/ft8_sync.v (design in docs/F6_SYNC.md). Every
// FT8 transmission starts, ends and is interrupted in the middle by the same Costas pattern, three
// blocks of seven tones in a fixed order, and the engine finds signals by looking for that
// pattern in the spectrogram, a picture of signal power per frequency bin and per 40 ms frame
// (docs/learn/GLOSSARY.md). For every carrier bin and every lag from -63 to 63 frames it adds
// up the power at the pattern's tones, divides it by the power of all the tones, and keeps the
// best lag, so that the CPU later gets one short record per bin (8 words of 32 bits, which is
// 4 DDR3 lane words) to pick its decode candidates from.
//
// The engine is wired to the real DDR3 arbiters and the behavioral lanes, and the test compares
// its records with those of the Rust reference model (`sync_fx_rows`) bit for bit. The DDR3
// stand-in is meant to be unkind: a 150 MHz engine clock, a lane that delivers a data beat on two
// of every three clocks (BEAT_SKIP = 3, which is 100 MHz of throughput), random stalls (3 percent
// chance per idle clock, runs up to 32 clocks), a video scan-out model on the top read tier
// (720 lane words per 2,222 clocks, the load of a 1080p60 screen with a full-screen waterfall),
// an IQ writer on the top write tier, and a background reader that shares the "rest" read tier
// with the engine through rtl/ft8/ft8_ddr3_rdmux.v and stands in for the spectrogram's slot
// reader, which has priority over the sync search.
//
// Stimulus: rows 0 .. 371 of the model's spectrogram of the recording qso1, lane words 200 .. 221
// of each row (bins 400 .. 443, the part the search reads for the band) put straight into
// receiver 3's spectrogram ring in the DDR3 model. The band is bins 401 .. 431, 31 carriers
// around the strongest signal in the recording. Receiver 3's early trigger 1 is set to frame
// 295, so the test first raises that receiver's frame counter to 295, which starts a search
// over 295 rows, and then to 372, the end of the slot, for the full search. Finally it starts
// the residual search that the second decode pass uses (docs/FT8_PASS2.md), over the same
// spectrogram but through the alt_* base addresses, after pointing the receiver's own
// spectrogram base somewhere else.
//
// Pass criterion: three interrupts for receiver 3 with 295, 372 and 372 rows, the last one
// flagged irq_alt, the records of each search in the DDR3 model equal to
// sim/ft8/vectors/f6_qso1_sync295.hex and f6_qso1_sync372.hex (made by `ft8-frontend sync-vectors
// captures/ft8/qso1.wav <dir> 401 431 {295,372} 200 221`), the residual search's records in the
// alt records area while the receiver's own records stay untouched, the engine idle at the end
// and no underrun of the video client. The bench prints "PASS: tb_ft8_sync (...)" on success
// and "FAIL" lines otherwise, together with the length of each search in clocks.
//
// Run from the repository root, as tools/check.sh does for every tb_*.v: iverilog -g2012 -o
// out.vvp sim/ft8/tb_ft8_sync.v, then vvp out.vvp. Defines: -DTB_NRX=4 builds four receivers,
// -DTB_CFG_EXT delivers the base addresses one receiver at a time, -DTB_DIV_PAIRS=4 builds the
// score divider with four step pairs instead of the chip's one.

`timescale 1ns / 1ps
`include "rtl/ft8/ft8_sync.v"
`include "rtl/ft8/ft8_ddr3_rdmux.v"
`include "rtl/ddr3/ddr3_write_arbiter.v"
`include "rtl/ddr3/ddr3_read_arbiter.v"
`include "sim/ddr3/ddr3_lane_behav_model.v"
`include "sim/ddr3/write_traffic_client.v"
`include "sim/ddr3/read_traffic_client.v"
`include "sim/ddr3/video_scanout_model.v"

module tb_ft8_sync;
`ifndef TB_NRX
`define TB_NRX 8              // receivers: -DTB_NRX=4 builds 4 (the chip's default)
`endif
    // Receiver RX = 3 is the one that is searched, in a band of bins IA .. IB. W0 is the first
    // and NWV the number of lane words per row that the vectors hold (bins 400 .. 443).
    // SPEC_BASE and REC_BASE are word addresses of the spectrogram ring and the records in the
    // DDR3 model, ALT_REC the records of the residual search and JUNK_SPEC the address of the
    // background reader's ring, which holds no spectrogram.
    localparam integer NUM_RX    = `TB_NRX;
    localparam integer RX        = 3;
    localparam integer IA        = 401, IB = 431;
    localparam integer W0        = 200, NWV = 22;          // lane words per row in the vectors
    localparam integer NBINS     = IB - IA + 1;
    localparam integer SPEC_BASE = 32'h0000_0000;
    localparam integer REC_BASE  = 32'h0003_0000;
    localparam integer ALT_REC   = 32'h0003_1000;          // the residual search's records
    localparam integer JUNK_SPEC = 32'h0003_8000;          // not a spectrogram (the background reader's ring)

    // 150 MHz: 6.666 ns period, 3.333 ns per half period.
    reg clk = 0;
    always #3.333 clk = ~clk;
    reg rst = 1;

    // The spectrogram's lane words, and the model's records after 295 rows and after 372 (each
    // record is 4 lane words per bin).
    reg [63:0] spec [0:372*NWV-1];
    reg [63:0] exp295 [0:4*NBINS-1];
    reg [63:0] exp372 [0:4*NBINS-1];
    initial begin
        $readmemh("sim/ft8/vectors/f6_qso1_spec_lw.hex", spec);
        $readmemh("sim/ft8/vectors/f6_qso1_sync295.hex", exp295);
        $readmemh("sim/ft8/vectors/f6_qso1_sync372.hex", exp372);
    end

    // ---------------------------------------------------------------- DUT
    reg  [NUM_RX*9-1:0] frame_ptr;
    reg  [NUM_RX-1:0]   slot_start;
    reg  [NUM_RX*32-1:0] spec_ring_base = {NUM_RX{SPEC_BASE[31:0]}};
    reg                  alt_start = 1'b0;
    wire                 irq_alt;
    wire [NUM_RX*32-1:0] rec_base       = {NUM_RX{REC_BASE[31:0]}};
    wire [NUM_RX*10-1:0] band_ia        = {NUM_RX{IA[9:0]}};
    wire [NUM_RX*10-1:0] band_ib        = {NUM_RX{IB[9:0]}};
    reg  [NUM_RX*9-1:0]  trig1;
    wire [NUM_RX*9-1:0]  trig2 = {(NUM_RX*9){1'b0}};
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

    // -DTB_CFG_EXT: the two base addresses are delivered one receiver at a time, as in
    // tb_ft8_spectrogram.v. -DTB_DIV_PAIRS=4 builds the score divider with four step pairs
    // instead of the chip's one pair.
`ifndef TB_DIV_PAIRS
`define TB_DIV_PAIRS 1
`endif
`ifdef TB_CFG_EXT
    wire [2:0] t_cfg_rx;
    ft8_sync #(.NUM_RX(NUM_RX), .DIV_PAIRS(`TB_DIV_PAIRS), .CFG_EXT(1)) dut (
        .clk(clk), .rst(rst),
        .spec_ring_base({(NUM_RX*32){1'bx}}), .rec_base({(NUM_RX*32){1'bx}}),
        .cfg_rx(t_cfg_rx), .cfg_bases({spec_ring_base[t_cfg_rx*32 +: 32], rec_base[t_cfg_rx*32 +: 32]}),
        .band_ia(band_ia), .band_ib(band_ib),
`else
    ft8_sync #(.NUM_RX(NUM_RX), .DIV_PAIRS(`TB_DIV_PAIRS)) dut (
        .clk(clk), .rst(rst),
        .spec_ring_base(spec_ring_base), .rec_base(rec_base), .band_ia(band_ia), .band_ib(band_ib),
`endif
        .trig1(trig1), .trig2(trig2), .frame_ptr(frame_ptr), .slot_start(slot_start),
        .cmd_start(1'b0), .cmd_rx(3'd0), .cmd_rows(9'd0),
        .alt_start(alt_start), .alt_rx(RX[2:0]), .alt_spec_base(SPEC_BASE[31:0]), .alt_rec_base(ALT_REC[31:0]),
        .busy(busy), .irq(irq), .irq_rx(irq_rx), .irq_rows(irq_rows), .irq_alt(irq_alt),
        .run_clocks(run_clocks),
        .rd_req(s_rd_req), .rd_addr(s_rd_addr), .rd_burstlen(s_rd_burstlen), .rd_gnt(s_rd_gnt),
        .rd_rvalid(s_rd_rvalid), .rd_rdata(s_rd_rdata), .rd_done(s_rd_done),
        .wr_req(s_wr_req), .wr_addr(s_wr_addr), .wr_burstlen(s_wr_burstlen), .wr_wdata(s_wr_wdata),
        .wr_wmask(s_wr_wmask), .wr_gnt(s_wr_gnt), .wr_done(s_wr_done)
    );

    // ---------------------------------------------------------------- rest tier: background reader and sync engine
    wire        b_req, b_gnt, b_rvalid, b_done;
    wire [31:0] b_addr;
    wire [7:0]  b_burstlen;
    read_traffic_client #(.BASE_ADDR(32'h0003_8000), .RING_WORDS(4096), .BURSTLEN(120),
                          .PERIOD_CYCLES(3000)) u_bg (
        .clk(clk), .rst(rst), .enable(1'b1),
        .req(b_req), .addr(b_addr), .burstlen(b_burstlen), .gnt(b_gnt), .rvalid(b_rvalid), .done(b_done),
        .words_done(), .bursts_done(), .max_wait_cycles());

    // Two-way read multiplexer that merges the background reader (a, the higher priority) and
    // the sync engine (b) onto the "rest" tier.
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

    // ---------------------------------------------------------------- video, IQ, arbiters, lanes
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

    // The arbiters share one write lane and one read lane between the clients. The engine is
    // on the write arbiter's "ft8" port and, through the multiplexer, on the read arbiter's
    // "rest" tier.
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

    // Behavioral DDR3 lane: 9 clocks of read latency, random stalls and BEAT_SKIP = 3, a data
    // beat dropped on every third clock.
    ddr3_lane_behav_model #(.MEM_WORDS(1 << 18), .RD_LATENCY(9), .STALL_NUM(30), .STALL_DEN(1000),
                             .STALL_MAX_CYCLES(32), .SEED(32'hF6_5A11), .BEAT_SKIP(3)) u_lane (
        .clk(clk), .rst(rst),
        .addr_lane4(addr_lane4), .wr_mask_lane4(wr_mask_lane4), .wr_data_lane4(wr_data_lane4),
        .wr_en_lane4(wr_en_lane4), .wr_go_lane4(wr_go_lane4), .burstcount_lane4(burstcount_lane4),
        .wr_wait_lane4(wr_wait_lane4), .wr_done_lane4(wr_done_lane4),
        .addr_lane5(addr_lane5), .rd_en_lane5(rd_en_lane5), .rd_go_lane5(rd_go_lane5),
        .burstcount_lane5(burstcount_lane5), .rd_valid_lane5(rd_valid_lane5),
        .rd_data_lane5(rd_data_lane5), .rd_rdy_lane5(rd_rdy_lane5), .phys_busy());

    // ---------------------------------------------------------------- monitors
    integer irqs = 0;
    reg [2:0] last_rx;
    reg [8:0] last_rows;
    reg       last_alt;
    // Records the receiver, row count and kind of every interrupt, and counts them.
    always @(posedge clk) begin
        if (!rst && irq) begin
            irqs      = irqs + 1;
            last_rx   = irq_rx;
            last_rows = irq_rows;
            last_alt  = irq_alt;
        end
    end

    // One clock, then 1 ns later, so that the bench changes its inputs after the clock edge.
    task step;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    integer errors = 0;
    // Compares the 4 lane words per bin that a search wrote at `base` with the model's records
    // for that row count. The first six mismatches are printed.
    task check_records(input integer rows, input integer base);
        integer f, mism;
        reg [63:0] got, want;
        begin
            mism = 0;
            for (f = 0; f < 4 * NBINS; f = f + 1) begin
                got  = u_lane.mem[base + f];
                want = (rows == 295) ? exp295[f] : exp372[f];
                if (got !== want) begin
                    mism = mism + 1;
                    if (mism <= 6)
                        $display("MISMATCH rows %0d bin %0d lane word %0d: got %016x want %016x",
                                 rows, IA + f / 4, f % 4, got, want);
                end
            end
            errors = errors + mism;
            $display("%0d rows: %0d bins, %0d mismatching lane words; search took %0d clocks (%0.3f ms at 150 MHz)",
                     rows, NBINS, mism, run_clocks, run_clocks / 150000.0);
        end
    endtask

    // Waits until n interrupts have been seen (at most 3 million clocks) and checks that the
    // last one was for receiver RX.
    task wait_irq(input integer n);
        integer t;
        begin
            t = 0;
            while (irqs < n && t < 3_000_000) begin
                step;
                t = t + 1;
            end
            if (irqs < n) begin
                $display("FAIL: no interrupt %0d", n);
                errors = errors + 1;
            end else if (last_rx !== RX) begin
                $display("FAIL: interrupt for rx %0d", last_rx);
                errors = errors + 1;
            end
        end
    endtask

    integer m, w;
    initial begin
        // Arm the trigger at frame 295 and put the spectrogram into DDR3, then release reset and
        // announce the start of a slot for receiver RX.
        frame_ptr  = 0;
        slot_start = 0;
        trig1      = 0;
        trig1[RX*9 +: 9] = 9'd295;
        for (m = 0; m < 372; m = m + 1)
            for (w = 0; w < NWV; w = w + 1)
                u_lane.mem[SPEC_BASE + m * 512 + W0 + w] = spec[m * NWV + w];
        repeat (4) step;
        rst = 0;
        repeat (4) step;
        slot_start[RX] = 1'b1;
        step;
        slot_start = 0;
        repeat (4) step;

        // Early trigger 1: 295 frames have been written, which starts a search over 295 rows.
        frame_ptr[RX*9 +: 9] = 9'd295;             // early trigger 1
        wait_irq(1);
        if (last_rows !== 9'd295) begin
            $display("FAIL: first search over %0d rows, expected 295", last_rows);
            errors = errors + 1;
        end
        check_records(295, REC_BASE);
        if (last_alt !== 1'b0) begin $display("FAIL: irq_alt on a receiver's own search"); errors = errors + 1; end

        // Slot end: 372 frames, the full search.
        frame_ptr[RX*9 +: 9] = 9'd372;             // slot end: the full search
        wait_irq(2);
        if (last_rows !== 9'd372) begin
            $display("FAIL: second search over %0d rows, expected 372", last_rows);
            errors = errors + 1;
        end
        check_records(372, REC_BASE);

        // The residual's search (second decode pass, docs/FT8_PASS2.md): the same spectrogram
        // through the alt_* bases. The receiver's own spectrogram base now points at something
        // else, so the records are right only if the search read alt_spec_base. They must go to
        // alt_rec_base and leave the receiver's records alone.
        spec_ring_base = {NUM_RX{JUNK_SPEC[31:0]}};
        repeat (4) step;
        alt_start = 1'b1;
        step;
        alt_start = 1'b0;
        wait_irq(3);
        if (last_rows !== 9'd372 || last_alt !== 1'b1) begin
            $display("FAIL: residual search: %0d rows, irq_alt %b", last_rows, last_alt);
            errors = errors + 1;
        end
        check_records(372, ALT_REC);
        check_records(372, REC_BASE);

        // No further interrupt may follow and the engine must be idle again.
        repeat (2000) step;
        if (irqs != 3 || busy) begin
            $display("FAIL: %0d interrupts, busy %0d after the three searches", irqs, busy);
            errors = errors + 1;
        end
        // The video client must not have starved while the engine was working.
        $display("video: %0d underruns, lowest FIFO fill %0d words", v_underruns, v_min_fill);
        if (v_underruns != 0) errors = errors + 1;
        if (errors == 0) $display("PASS: tb_ft8_sync (3 searches, one the residual's, %0d bins each, bit-exact)", NBINS);
        else $display("FAIL: tb_ft8_sync, %0d errors", errors);
        $finish;
    end
endmodule
