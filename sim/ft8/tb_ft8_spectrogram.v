// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// End to end test of the FT8 spectrogram engine, rtl/ft8/ft8_spectrogram.v, through DDR3
// (docs/F5_FT8SPEC.md). The FT8 decoder works on a spectrogram, a picture of signal power per
// frequency bin (3.125 Hz wide) and per time frame (40 ms apart), and this engine makes one such
// picture for each decoder receiver. It captures each receiver's 12 ksps audio into a ring in
// DDR3, and whenever another 480 samples (40 ms) have landed it reads the latest 1,920 sample
// window back, runs it through one shared 3,840 point transform and writes the 1,024 power words of
// the frame into that receiver's spectrogram ring (see docs/learn/GLOSSARY.md for the
// transform and for the other terms).
//
// The engine is wired to the real write arbiter (rtl/ddr3/ddr3_write_arbiter.v, "ft8" port), the
// real read arbiter (rtl/ddr3/ddr3_read_arbiter.v, "rest" tier) and the behavioral DDR3 lanes
// (sim/ddr3/ddr3_lane_behav_model.v, with random stalls), and an IQ writer on the top write tier
// adds contention. Three of the eight receivers run at once with different slot boundaries:
//
//   rx 0: the qso3_busy prefix (the first 3,840 samples of that WSJT-X recording), slot
//         boundary at capture sample 0
//   rx 2: 243 samples of junk, then the same qso3_busy prefix, slot boundary at sample 243. That is
//         not a multiple of 4, so every window starts inside a packed lane word, and it also tests
//         a boundary that is set ahead of the write pointer and is not zero
//   rx 5: the qso1 prefix, slot boundary at sample 0 (rx 3 if the bench is built with 4 receivers)
//
// The audio of the three receivers is interleaved on the shared audio input, the way the receiver
// back end delivers it. Each prefix of 3,840 samples is five frames (4 x 480 + 1,920 samples).
// After the run the three spectrogram rings are read straight out of the DDR3 model and compared
// bit for bit with the Rust reference model's words (frames 0 .. 4 of each recording, power
// shift 16, from sim/ft8/vectors).
//
// Second decode pass (docs/FT8_PASS2.md): while the three receivers run, the replay channel
// transforms a buffer of "residual" audio (here the qso1 prefix, written into DDR3 beforehand the
// way the CPU would) into a spectrogram area of its own. The engine is built with N_TIME = 5, so
// the replay ends after the five frames that the vectors cover.
//
// Pass criterion: 15 interrupts (3 receivers x 5 frames) with matching receiver and frame tags,
// no capture overflow, every frame counter at 5, all 3 x 5 x 1,024 live power words and all
// 5 x 1,024 replay words equal to the model's, exactly one rp_done pulse, rp_busy low at the
// end and one rp_frame step per replay frame. The bench prints "PASS: tb_ft8_spectrogram (...)"
// on success, "FAIL" lines otherwise, and the engine's busy clocks per frame, which is the figure
// for the load of the shared engine.
//
// Run from the repository root, as tools/check.sh does for every tb_*.v: iverilog -g2012 -o
// out.vvp sim/ft8/tb_ft8_spectrogram.v, then vvp out.vvp. Add -DTB_NRX=4 for four receivers and
// -DTB_CFG_EXT for the variant in which the ring bases are delivered one receiver at a time.

`timescale 1ns / 1ps
`include "rtl/ft8/ft8_spectrogram.v"
`include "rtl/ft8/ft8_ddr3_mux.v"
`include "rtl/ddr3/ddr3_write_arbiter.v"
`include "rtl/ddr3/ddr3_read_arbiter.v"
`include "sim/ddr3/ddr3_lane_behav_model.v"
`include "sim/ddr3/write_traffic_client.v"

module tb_ft8_spectrogram;
`ifndef TB_NRX
`define TB_NRX 8              // receivers: -DTB_NRX=4 builds 4 (the chip's default)
`endif
    // NUM_RX receivers are built, 8 unless TB_NRX says otherwise. RXC is the third receiver
    // that is fed (qso1 words): 5 with eight receivers, 3 with four.
    localparam integer NUM_RX  = `TB_NRX;
    localparam integer RXC     = (NUM_RX > 5) ? 5 : 3;      // the third receiver, fed the qso1 words
    localparam integer NFRAMES = 5;
    // NSAMP samples per recording prefix is 3,840 = five frames of 1,920 samples, 480 apart.
    // JUNK is the number of samples sent to rx 2 before its slot boundary.
    // CAP_BASE and SPEC_BASE are word addresses in the DDR3 model: each receiver gets a capture
    // ring of 8,192 lane words (4 samples per word) and a spectrogram ring of 4,096 lane words
    // (a frame is 512 words, two power words each). RP_CAP and RP_SPEC are the replay's residual
    // audio (3,840 / 4 = 960 words) and its spectrogram (5 x 512 words).
    localparam integer NSAMP   = 3840;     // samples per recording prefix (frames 0 .. 4)
    localparam integer JUNK    = 243;      // rx 2's pre-slot samples (not a multiple of 4: the window starts mid lane word)
    localparam integer CAP_BASE  = 32'h0000_0000;   // + rx * 8,192 lane words
    localparam integer SPEC_BASE = 32'h0001_0000;   // + rx * 4,096 lane words
    localparam integer RP_CAP    = 32'h0002_0000;   // residual audio, 960 lane words
    localparam integer RP_SPEC   = 32'h0002_8000;   // its spectrogram, 5 x 512 lane words

    // 100 MHz bench clock (10 ns period).
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;

    // a3 and a1 are the audio of qso3_busy and qso1, p3 and p1 the model's 5 x 1,024 power words.
    reg [15:0] a3 [0:NSAMP-1];
    reg [15:0] a1 [0:NSAMP-1];
    reg [31:0] p3 [0:NFRAMES*1024-1];
    reg [31:0] p1 [0:NFRAMES*1024-1];
    initial begin
        $readmemh("sim/ft8/vectors/qso3_busy_small_audio.hex", a3);
        $readmemh("sim/ft8/vectors/qso1_small_audio.hex", a1);
        $readmemh("sim/ft8/vectors/qso3_busy_small_power.hex", p3);
        $readmemh("sim/ft8/vectors/qso1_small_power.hex", p1);
    end

    // ---------------------------------------------------------------- DUT configuration
    // Configuration as one vector per port, with the receiver in each slice: enable, slot
    // boundary pointer, slot start pulse, and a power shift of 16 for every receiver.
    reg  [NUM_RX-1:0]    enable;
    reg  [NUM_RX*32-1:0] slot_boundary_ptr;
    reg  [NUM_RX-1:0]    slot_start;
    wire [NUM_RX*5-1:0]  pwr_shift = {NUM_RX{5'd16}};
    wire [NUM_RX*32-1:0] cap_ring_base, spec_ring_base;
    genvar g;
    generate
        for (g = 0; g < NUM_RX; g = g + 1) begin : g_cfg
            assign cap_ring_base[g*32 +: 32]  = CAP_BASE + g * 8192;
            assign spec_ring_base[g*32 +: 32] = SPEC_BASE + g * 4096;
        end
    endgenerate

    // The shared audio input: one 16 bit sample at a time, tagged with its receiver.
    reg         audio_valid;
    reg  [2:0]  audio_rx;
    reg  [15:0] audio_sample;

    wire [NUM_RX*32-1:0] cap_wr_ptr;
    wire [NUM_RX*9-1:0]  frame_ptr;
    wire cap_overflow, engine_busy, irq;
    reg        rp_start = 1'b0;
    wire [8:0] rp_frame;
    wire       rp_busy, rp_done;
    wire [2:0] irq_rx;
    wire [8:0] irq_frame;

    wire        f_wr_req, f_wr_gnt, f_wr_done;
    wire [31:0] f_wr_addr;
    wire [7:0]  f_wr_burstlen, f_wr_wmask;
    wire [63:0] f_wr_wdata;
    wire        f_rd_req, f_rd_gnt, f_rd_rvalid, f_rd_done;
    wire [31:0] f_rd_addr;
    wire [7:0]  f_rd_burstlen;
    wire [63:0] f_rd_rdata;

    // The engine's two write clients (slot capture and spectrogram ring writer) on the front
    // end's write share, merged by the same 4-way write mux that rtl/ft8/ft8_frontend.v uses.
    wire        cw_req, cw_gnt, cw_done, rw_req, rw_gnt, rw_done;
    wire [31:0] cw_addr, rw_addr;
    wire [7:0]  cw_burstlen, cw_wmask, rw_burstlen, rw_wmask;
    wire [63:0] cw_wdata, rw_wdata;
    wire [1:0]  nc_gnt, nc_done;
    ft8_ddr3_wmux4 u_wmux (
        .clk(clk), .rst(rst),
        .c_req({2'b00, rw_req, cw_req}), .c_addr({64'd0, rw_addr, cw_addr}),
        .c_burstlen({16'd0, rw_burstlen, cw_burstlen}), .c_wdata({128'd0, rw_wdata, cw_wdata}),
        .c_wmask({16'd0, rw_wmask, cw_wmask}),
        .c_gnt({nc_gnt, rw_gnt, cw_gnt}), .c_done({nc_done, rw_done, cw_done}),
        .req(f_wr_req), .addr(f_wr_addr), .burstlen(f_wr_burstlen), .wdata(f_wr_wdata),
        .wmask(f_wr_wmask), .gnt(f_wr_gnt), .done(f_wr_done));

    // -DTB_CFG_EXT: the ring bases are delivered one receiver at a time, at the receiver number
    // that the engine shows (CFG_EXT = 1; in the chip that is a LUT RAM read, here a select from
    // the same words).
`ifdef TB_CFG_EXT
    wire [2:0] t_cfg_rx, t_cap_cfg_rx;
    ft8_spectrogram #(.NUM_RX(NUM_RX), .N_TIME(NFRAMES), .CFG_EXT(1)) dut (
        .cfg_rx(t_cfg_rx), .cfg_bases({cap_ring_base[t_cfg_rx*32 +: 32], spec_ring_base[t_cfg_rx*32 +: 32]}),
        .cap_cfg_rx(t_cap_cfg_rx), .cap_cfg_base(cap_ring_base[t_cap_cfg_rx*32 +: 32]),
`else
    ft8_spectrogram #(.NUM_RX(NUM_RX), .N_TIME(NFRAMES)) dut (
`endif
        .clk(clk), .rst(rst),
        .audio_valid(audio_valid), .audio_rx(audio_rx), .audio_sample(audio_sample),
        .enable(enable), .pwr_shift(pwr_shift),
`ifdef TB_CFG_EXT
        .cap_ring_base({(NUM_RX*32){1'bx}}), .spec_ring_base({(NUM_RX*32){1'bx}}),
`else
        .cap_ring_base(cap_ring_base), .spec_ring_base(spec_ring_base),
`endif
        .slot_boundary_ptr(slot_boundary_ptr), .slot_start(slot_start),
        .cap_wr_ptr(cap_wr_ptr), .frame_ptr(frame_ptr),
        .cap_overflow(cap_overflow), .engine_busy(engine_busy),
        .rp_start(rp_start), .rp_cap_base(RP_CAP[31:0]), .rp_spec_base(RP_SPEC[31:0]), .rp_sh(5'd16),
        .rp_frame(rp_frame), .rp_busy(rp_busy), .rp_done(rp_done),
        .capw_req(cw_req), .capw_addr(cw_addr), .capw_burstlen(cw_burstlen),
        .capw_wdata(cw_wdata), .capw_wmask(cw_wmask), .capw_gnt(cw_gnt), .capw_done(cw_done),
        .ringw_req(rw_req), .ringw_addr(rw_addr), .ringw_burstlen(rw_burstlen),
        .ringw_wdata(rw_wdata), .ringw_wmask(rw_wmask), .ringw_gnt(rw_gnt), .ringw_done(rw_done),
        .rd_req(f_rd_req), .rd_addr_o(f_rd_addr), .rd_burstlen(f_rd_burstlen),
        .rd_gnt(f_rd_gnt), .rd_rvalid(f_rd_rvalid), .rd_rdata(f_rd_rdata), .rd_rdone(f_rd_done),
        .irq(irq), .irq_rx(irq_rx), .irq_frame(irq_frame)
    );

    // ---------------------------------------------------------------- DDR3 side
    wire        iq_req, iq_gnt, iq_done;
    wire [31:0] iq_addr;
    wire [7:0]  iq_burstlen, iq_wmask;
    wire [63:0] iq_wdata;
    // IQ writer: a burst of 8 words every 40 clocks on the top write tier, heavy contention for
    // the engine's writes.
    write_traffic_client #(.BASE_ADDR(32'h0003_0000), .RING_WORDS(4096), .BURSTLEN(8),
                           .PERIOD_CYCLES(40)) u_iq (
        .clk(clk), .rst(rst), .enable(1'b1),
        .req(iq_req), .addr(iq_addr), .burstlen(iq_burstlen), .wdata(iq_wdata), .wmask(iq_wmask),
        .gnt(iq_gnt), .done(iq_done),
        .words_done(), .bursts_done(), .max_wait_cycles());

    wire [31:0] addr_lane4, addr_lane5;
    wire [7:0]  wr_mask_lane4, burstcount_lane4, burstcount_lane5;
    wire [63:0] wr_data_lane4, rd_data_lane5;
    wire wr_en_lane4, wr_go_lane4, wr_wait_lane4, wr_done_lane4;
    wire rd_en_lane5, rd_go_lane5, rd_valid_lane5, rd_rdy_lane5;

    // The arbiters share one write lane and one read lane between the clients. The engine is
    // on the write arbiter's "ft8" port and the read arbiter's "rest" tier.
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
        .video_req(1'b0), .video_addr(32'd0), .video_burstlen(8'd0),
        .video_gnt(), .video_rvalid(), .video_rdata(), .video_done(),
        .audio_req(1'b0), .audio_addr(32'd0), .audio_burstlen(8'd0),
        .audio_gnt(), .audio_rvalid(), .audio_rdata(), .audio_done(),
        .tx_req(1'b0), .tx_addr(32'd0), .tx_burstlen(8'd0),
        .tx_gnt(), .tx_rvalid(), .tx_rdata(), .tx_done(),
        .rest_req(f_rd_req), .rest_addr(f_rd_addr), .rest_burstlen(f_rd_burstlen),
        .rest_gnt(f_rd_gnt), .rest_rvalid(f_rd_rvalid), .rest_rdata(f_rd_rdata), .rest_done(f_rd_done),
        .addr_lane5(addr_lane5), .rd_en_lane5(rd_en_lane5), .rd_go_lane5(rd_go_lane5),
        .burstcount_lane5(burstcount_lane5), .rd_valid_lane5(rd_valid_lane5),
        .rd_data_lane5(rd_data_lane5), .rd_rdy_lane5(rd_rdy_lane5), .owner());

    // Behavioral DDR3 lane with random stalls (3 percent chance per idle clock, up to 32 clocks)
    // and no beat throttle.
    ddr3_lane_behav_model #(.MEM_WORDS(1 << 18), .STALL_NUM(30), .STALL_DEN(1000),
                             .STALL_MAX_CYCLES(32), .SEED(32'hF7_8F58)) u_lane (
        .clk(clk), .rst(rst),
        .addr_lane4(addr_lane4), .wr_mask_lane4(wr_mask_lane4), .wr_data_lane4(wr_data_lane4),
        .wr_en_lane4(wr_en_lane4), .wr_go_lane4(wr_go_lane4), .burstcount_lane4(burstcount_lane4),
        .wr_wait_lane4(wr_wait_lane4), .wr_done_lane4(wr_done_lane4),
        .addr_lane5(addr_lane5), .rd_en_lane5(rd_en_lane5), .rd_go_lane5(rd_go_lane5),
        .burstcount_lane5(burstcount_lane5), .rd_valid_lane5(rd_valid_lane5),
        .rd_data_lane5(rd_data_lane5), .rd_rdy_lane5(rd_rdy_lane5), .phys_busy());

    // ---------------------------------------------------------------- monitors
    integer irqs = 0, errors = 0;
    integer busy_clocks = 0;
    integer seen_frames [0:NUM_RX-1];
    integer r0;
    initial for (r0 = 0; r0 < NUM_RX; r0 = r0 + 1) seen_frames[r0] = 0;
    integer rp_dones = 0, rp_frames_seen = 0, rp_started = 0;
    reg [8:0] rp_frame_q = 9'd0;
    // Replay monitor: counts rp_done pulses and every change of rp_frame, and starts the replay
    // (below) when two live frames are done.
    always @(posedge clk) begin
        if (!rst && rp_done) rp_dones = rp_dones + 1;
        if (!rst && rp_frame !== rp_frame_q) begin
            if (rp_frame != 0) rp_frames_seen = rp_frames_seen + 1;
            rp_frame_q <= rp_frame;
        end
        // The replay starts once two live frames are done, while audio is still arriving.
        rp_start <= 1'b0;
        if (!rst && irqs >= 2 && rp_started == 0) begin
            rp_start   <= 1'b1;
            rp_started = 1;
        end
    end
    // Interrupt monitor: counts busy clocks and interrupts, and checks that the frames of each
    // receiver are announced in order, starting at 0.
    always @(posedge clk) begin
        if (!rst && engine_busy) busy_clocks = busy_clocks + 1;
        if (!rst && irq) begin
            irqs = irqs + 1;
            if (irq_frame !== seen_frames[irq_rx]) begin
                $display("FAIL: irq rx %0d frame %0d, expected frame %0d", irq_rx, irq_frame,
                         seen_frames[irq_rx]);
                errors = errors + 1;
            end
            seen_frames[irq_rx] = seen_frames[irq_rx] + 1;
        end
    end

    // ---------------------------------------------------------------- stimulus
    task step;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    // One sample to one receiver every 32 clocks. Each receiver then gets a sample every 96
    // clocks, where the chip at 150 MHz sees one every 12,500 (12 ksps), so the bench runs about
    // 130 times faster than real time, which is fast enough for frames to queue up behind each
    // other and so to test the scheduler under load.
    task put(input [2:0] rx, input [15:0] smp);
        begin
            audio_valid  = 1;
            audio_rx     = rx;
            audio_sample = smp;
            step;
            audio_valid  = 0;
            repeat (31) step;
        end
    endtask

    // Expected power word of receiver rx, frame f, bin k.
    function [31:0] want(input integer rx, input integer f, input integer k);
        want = (rx == RXC) ? p1[f * 1024 + k] : p3[f * 1024 + k];
    endfunction

    integer i, f, k, rx, checked, mism;
    reg [63:0] lw;
    reg [31:0] got;
    // i, f, k, rx are loop counters, lw is one lane word and got the power word cut out of it.
    initial begin
        audio_valid = 0; audio_rx = 0; audio_sample = 0;
        enable = 0; slot_start = 0;
        slot_boundary_ptr = 0;
        slot_boundary_ptr[2*32 +: 32] = JUNK;
        // The residual buffer as the CPU writes it: 4 samples per lane word, sample 0 in the low
        // 16 bits, from slot sample 0.
        for (i = 0; i < NSAMP / 4; i = i + 1)
            u_lane.mem[RP_CAP + i] = {a1[4*i+3], a1[4*i+2], a1[4*i+1], a1[4*i]};
        repeat (4) step;
        rst = 0;
        step;
        // Enable rx 0, rx 2 and the third receiver, and pulse slot_start for them.
        enable = 8'b0000_0101 | (8'd1 << RXC);
        slot_start = 8'b0000_0101 | (8'd1 << RXC);
        step;
        slot_start = 0;

        // rx 2's pre-slot junk first, then all three interleaved.
        for (i = 0; i < JUNK; i = i + 1) put(3'd2, 16'h7F00 ^ i[15:0]);
        for (i = 0; i < NSAMP; i = i + 1) begin
            put(3'd0, a3[i]);
            put(3'd2, a3[i]);
            put(RXC[2:0], a1[i]);
        end

        // Wait for all 3 x 5 frames and the replay, at most 3 million clocks.
        i = 0;
        while ((irqs < 3 * NFRAMES || rp_dones == 0) && i < 3_000_000) begin
            step;
            i = i + 1;
        end
        repeat (200) step;

        // Interrupt count, capture overflow and frame counters: only the three receivers in use
        // may have moved.
        if (irqs != 3 * NFRAMES) begin
            $display("FAIL: %0d interrupts, expected %0d", irqs, 3 * NFRAMES);
            errors = errors + 1;
        end
        if (cap_overflow) begin
            $display("FAIL: slot capture overflow");
            errors = errors + 1;
        end
        for (rx = 0; rx < NUM_RX; rx = rx + 1) begin
            if (frame_ptr[rx*9 +: 9] !== ((rx == 0 || rx == 2 || rx == RXC) ? NFRAMES : 0)) begin
                $display("FAIL: rx %0d frame_ptr %0d", rx, frame_ptr[rx*9 +: 9]);
                errors = errors + 1;
            end
        end

        // Spectrogram rings, straight out of the DDR3 model: the word for bin 2m is the low half
        // of lane word m, bin 2m + 1 the high half.
        checked = 0;
        for (rx = 0; rx < NUM_RX; rx = rx + 1) begin
            if (rx == 0 || rx == 2 || rx == RXC) begin
                mism = 0;
                for (f = 0; f < NFRAMES; f = f + 1) begin
                    for (k = 0; k < 1024; k = k + 1) begin
                        lw  = u_lane.mem[SPEC_BASE + rx * 4096 + f * 512 + k / 2];
                        got = (k % 2) ? lw[63:32] : lw[31:0];
                        checked = checked + 1;
                        if (got !== want(rx, f, k)) begin
                            mism = mism + 1;
                            errors = errors + 1;
                            if (mism <= 5)
                                $display("MISMATCH rx %0d frame %0d bin %0d: got %08x want %08x",
                                         rx, f, k, got, want(rx, f, k));
                        end
                    end
                end
                $display("rx %0d: %0d frames checked, %0d mismatches", rx, NFRAMES, mism);
            end
        end

        // The replay's own spectrogram area must hold the qso1 words.
        mism = 0;
        for (f = 0; f < NFRAMES; f = f + 1) begin
            for (k = 0; k < 1024; k = k + 1) begin
                lw  = u_lane.mem[RP_SPEC + f * 512 + k / 2];
                got = (k % 2) ? lw[63:32] : lw[31:0];
                checked = checked + 1;
                if (got !== p1[f * 1024 + k]) begin
                    mism = mism + 1;
                    errors = errors + 1;
                    if (mism <= 5)
                        $display("MISMATCH replay frame %0d bin %0d: got %08x want %08x", f, k, got, p1[f * 1024 + k]);
                end
            end
        end
        $display("replay: %0d frames checked, %0d mismatches", NFRAMES, mism);
        if (rp_dones != 1 || rp_frame !== NFRAMES || rp_busy !== 1'b0 || rp_frames_seen != NFRAMES) begin
            $display("FAIL: replay: %0d done pulses, rp_frame %0d, rp_busy %b, %0d frame steps", rp_dones,
                     rp_frame, rp_busy, rp_frames_seen);
            errors = errors + 1;
        end

        // The busy figure divides the engine's busy clocks by the number of frames it did,
        // which is the three receivers' 15 plus the replay's 5.
        $display("engine busy %0d clocks for %0d frames: %0d clocks per frame", busy_clocks, irqs + NFRAMES,
                 busy_clocks / (irqs + NFRAMES));
        if (errors == 0) $display("PASS: tb_ft8_spectrogram (3 receivers and a replay, %0d bins through DDR3)", checked);
        else $display("FAIL: tb_ft8_spectrogram, %0d errors", errors);
        $finish;
    end
endmodule
