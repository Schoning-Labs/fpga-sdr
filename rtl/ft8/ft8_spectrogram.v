// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ft8_spectrogram: records each decoder receiver's audio of the running 15-second slot and turns it into a
// spectrogram, one new line every 40 ms.
//
// Background
//   ft8_frontend.v explains FT8 (slots, 8-FSK tones 6.25 Hz apart, 160 ms symbols, the Costas sync pattern).  A
//   spectrogram is a picture of signal energy over time and frequency: a sequence of lines, each one the power in every
//   frequency bin during a short window of the audio (glossary "Spectrogram", "Bin", "FFT" in docs/learn/GLOSSARY.md).
//   The sync search later looks for the Costas pattern in it.  The window is one symbol long (1,920 samples at
//   12 ksps = 160 ms), a new window starts every 480 samples (40 ms, a quarter of a symbol) so the search can find a
//   signal to within 40 ms in time, the window is rectangular, and the window is zero-padded to 3,840 samples for the
//   transform so that the bins are 12,000 / 3,840 = 3.125 Hz apart, half of the 6.25 Hz tone spacing.  Of the
//   1,920 bins up to 6 kHz only the lowest 1,024 are kept (0 to 3,196.9 Hz), which is where FT8 signals are.  One
//   slot has 372 frames (0 .. 371, numbered j), the same numbers as WSJT-X's `sync8` uses, so the results can be
//   compared line by line.  Frame j covers slot samples 480 j .. 480 j + 1,919, so the last one ends at sample
//   179,999, wholly inside the slot (180,000 samples = 15 s).
//
// What it does
//   Per decoder receiver:
//     (a) slot capture (ft8_slot_capture.v) continuously copies the receiver's 12 ksps audio into its own ring in DDR3,
//         four samples per 64-bit word;
//     (b) a scheduler watches each ring's write pointer against a "next frame due" counter.  Once 480 more samples
//         have arrived than the last frame needed, it fetches that window back out of DDR3 (ft8_slot_reader.v), runs the
//         transform (ft8_frame_core.v, one shared copy for all receivers), converts the bins to power (ft8_power.v) and
//         streams the 1,024 power words into the receiver's spectrogram ring in DDR3 (ft8_ring_writer.v).
//   Because the transform is shared and takes far less than 40 ms per frame, the scheduler hands it to the receivers
//   round-robin, so a ready receiver never waits for more than NUM_RX - 1 other frames.  The two writers are two
//   client ports (`capw_*` and `ringw_*`), which the front end puts on the write arbiter's FT8 tier with the slot
//   capture first (rtl/ft8/ft8_ddr3_mux.v), and the slot reader is a client of the read lane's lowest tier.  Design,
//   latency, resources and test are in docs/F5_FT8SPEC.md.
//
// Configuration
//   Plain input ports, not a register block: ft8_frontend.v owns the registers and wires them here.
//   `slot_boundary_ptr[r]` is the value of receiver r's slot-capture write pointer (`cap_wr_ptr`) at the moment a new
//   15-second slot starts; the firmware reads `cap_wr_ptr` and writes it back to the boundary register when it decides
//   a slot has begun (from UTC or the operator's clock), and pulses `slot_start[r]`.  Frames of that slot then start
//   once 1,920 samples past the boundary have landed, and a frame number counter restarts at 0.
//
// Second decode pass (docs/FT8_PASS2.md)
//   The scheduler has a ninth source, the replay channel (`rp_*` ports).  It transforms a whole slot of residual
//   audio (the slot's audio with the decoded signals subtracted) from a DDR3 buffer that the CPU wrote, frame after
//   frame, into its own spectrogram area, through the same reader, frame core, power stage and ring writer.  It is
//   served only when no live receiver has a frame due.
//
// Clocks
//   Everything runs on `clk` (clk_dsp, 120 MHz).  Setting up a frame takes a handful of clocks, and a whole frame is a
//   small fraction of the 40 ms between frames of one receiver (docs/F5_FT8SPEC.md has the figure).

`timescale 1ns / 1ps
`include "rtl/ft8/ft8_frame_core.v"
`include "rtl/ft8/ft8_power.v"
`include "rtl/ft8/ft8_slot_capture.v"
`include "rtl/ft8/ft8_slot_reader.v"
`include "rtl/ft8/ft8_ring_writer.v"

module ft8_spectrogram #(
    parameter integer NUM_RX     = 8,
    parameter integer ADDR_WIDTH = 32,
    parameter integer N_TIME     = 372,
    // CFG_EXT = 1: the two ring bases of a receiver (capture base and spectrogram base) come from small LUT RAMs in
    // the caller instead of through the 8-way selects here: {capture base, spectrogram base} of the receiver `cfg_rx`
    // arrive on `cfg_bases`, and the capture base of receiver `cap_cfg_rx` on `cap_cfg_base` (for the slot capture).
    // `cap_ring_base` and `spec_ring_base` are then unused.  The timing is the same as with the selects.
    parameter integer CFG_EXT    = 0
) (
    // Clock (clk_dsp, 120 MHz) and synchronous reset (active high).
    input  wire        clk,
    input  wire        rst,

    // Shared 12 ksps audio input, the output stream convention of the receiver back end: one 16-bit signed sample
    // for receiver audio_rx on each clock where audio_valid is high.
    input  wire        audio_valid,
    input  wire [2:0]  audio_rx,
    input  wire [15:0] audio_sample,

    // Per-receiver configuration: enable (1 bit per receiver), pwr_shift (5 bits per receiver, see ft8_power.v),
    // and the ring bases (ADDR_WIDTH bits per receiver).  slot_boundary_ptr is explained in the header.
    input  wire [NUM_RX-1:0]              enable,
    input  wire [NUM_RX*5-1:0]            pwr_shift,       // 0 .. 31 per receiver, default 16
    input  wire [NUM_RX*ADDR_WIDTH-1:0]   cap_ring_base,   // slot-capture ring base, per receiver
    input  wire [NUM_RX*ADDR_WIDTH-1:0]   spec_ring_base,  // spectrogram ring base, per receiver
    input  wire [NUM_RX*32-1:0]           slot_boundary_ptr,
    // Base address look-up (CFG_EXT = 1): the receiver number the caller should look up, and the bases it answers.
    output wire [2:0]                     cfg_rx,
    input  wire [2*ADDR_WIDTH-1:0]        cfg_bases,
    output wire [2:0]                     cap_cfg_rx,
    input  wire [ADDR_WIDTH-1:0]          cap_cfg_base,
    // One-clock pulse per receiver: a new slot begins, restart at frame 0.
    input  wire [NUM_RX-1:0]              slot_start,      // pulse: new slot, restart at frame 0

    output wire [NUM_RX*32-1:0]           cap_wr_ptr,      // for firmware's slot-boundary capture
    output wire [NUM_RX*9-1:0]            frame_ptr,       // frames of this slot written so far
    output wire                           cap_overflow,    // sticky: slot capture dropped audio
    output wire                           engine_busy,     // scheduler not idle (busy-time meter)

    // Replay channel for the second decode pass (docs/FT8_PASS2.md): the spectrogram of a slot
    // of residual audio the CPU wrote to DDR3 (sample 0 of the slot = sample 0 at `rp_cap_base`,
    // 4 samples per lane word as in the capture rings), frame after frame into `rp_spec_base`.
    // A live receiver's frame always goes first. The three settings must hold from `rp_start`
    // until `rp_done` (the front end's registers do). No frame interrupt for replay frames.
    input  wire                           rp_start,        // pulse: start at frame 0
    input  wire [ADDR_WIDTH-1:0]          rp_cap_base,
    input  wire [ADDR_WIDTH-1:0]          rp_spec_base,
    input  wire [4:0]                     rp_sh,
    output reg  [8:0]                     rp_frame,        // replay frames written, 0 .. N_TIME
    output reg                            rp_busy,         // a replay is running
    output reg                            rp_done,         // pulse: frame N_TIME - 1 is in DDR3

    // two write-lane clients (rtl/ddr3/ddr3_write_arbiter.v convention), for the front end's
    // write share (rtl/ft8/ft8_ddr3_mux.v): the slot capture, which must come first (live
    // audio), and the spectrogram ring writer
    output wire          capw_req,
    output wire [ADDR_WIDTH-1:0] capw_addr,
    output wire [7:0]    capw_burstlen,
    output wire [63:0]   capw_wdata,
    output wire [7:0]    capw_wmask,
    input  wire          capw_gnt,
    input  wire          capw_done,
    output wire          ringw_req,
    output wire [ADDR_WIDTH-1:0] ringw_addr,
    output wire [7:0]    ringw_burstlen,
    output wire [63:0]   ringw_wdata,
    output wire [7:0]    ringw_wmask,
    input  wire          ringw_gnt,
    input  wire          ringw_done,

    // ft8 read-lane "rest" tier client port (rtl/ddr3/ddr3_read_arbiter.v)
    output wire          rd_req,
    output wire [ADDR_WIDTH-1:0] rd_addr_o,
    output wire [7:0]    rd_burstlen,
    input  wire          rd_gnt,
    input  wire          rd_rvalid,
    input  wire [63:0]   rd_rdata,
    input  wire          rd_rdone,

    // Interrupt: a one-clock pulse when a receiver's spectrogram frame is complete in DDR3.  `irq_rx` and
    // `irq_frame` say which receiver and which frame, valid from the pulse until the next one.  (The sync search
    // and the candidate engine have interrupts of their own, which ft8_frontend.v combines.)
    output reg           irq,
    output reg  [2:0]    irq_rx,
    output reg  [8:0]    irq_frame
);

    // ================================================================ slot capture (part a)
    // Wires between the slot capture block and the outward write port.
    wire [ADDR_WIDTH-1:0] cap_addr_w;
    wire [7:0]  cap_burstlen_w;
    wire [63:0] cap_wdata_w;
    wire [7:0]  cap_wmask_w;
    wire        cap_req_w, cap_gnt_w, cap_done_w;

    ft8_slot_capture #(.NUM_RX(NUM_RX), .ADDR_WIDTH(ADDR_WIDTH), .CFG_EXT(CFG_EXT)) u_cap (
        .clk(clk), .rst(rst),
        .in_valid(audio_valid), .in_rx(audio_rx), .in_sample(audio_sample),
        .enable(enable), .ring_base(cap_ring_base), .cfg_rx(cap_cfg_rx), .cfg_base(cap_cfg_base),
        .wr_ptr(cap_wr_ptr), .overflow(cap_overflow),
        .req(cap_req_w), .addr(cap_addr_w), .burstlen(cap_burstlen_w),
        .wdata(cap_wdata_w), .wmask(cap_wmask_w), .gnt(cap_gnt_w), .done(cap_done_w)
    );

    // ================================================================ scheduler
    // captured[r] is the number of samples written to receiver r's ring since its slot boundary (negative, meaning the
    // top bit is set, while the boundary is still in the future), need[r] is how many the next frame needs
    // (1,920 + 480 j for frame j), and ready[r] says there are enough.  The multiplication 480 j is done as
    // 512 j - 32 j (shifts and one subtraction).  All of it is pipelined with a register after each step, so `ready` lags its
    // inputs by 2 clocks (3 behind next_frame); the scheduler waits SETTLE clocks in S_IDLE after anything that
    // changes next_frame or starts a slot before it trusts `ready` again.
    reg  [31:0] captured [0:NUM_RX-1];
    reg  [31:0] need     [0:NUM_RX-1];
    reg  [17:0] nf480    [0:NUM_RX-1];   // 480 x next_frame, a clock ahead of `need`
    reg  [8:0]  next_frame [0:NUM_RX-1];
    reg  [NUM_RX-1:0] ready;
    genvar gr;
    generate
        for (gr = 0; gr < NUM_RX; gr = gr + 1) begin : g_ready
            always @(posedge clk) begin
                captured[gr] <= cap_wr_ptr[gr*32 +: 32] - slot_boundary_ptr[gr*32 +: 32];
                nf480[gr]    <= {next_frame[gr], 9'd0} - {4'd0, next_frame[gr], 5'd0};
                need[gr]     <= 32'd1920 + {14'd0, nf480[gr]};                  // 1,920 + 480 j
                ready[gr]    <= enable[gr] && (next_frame[gr] < N_TIME) && !captured[gr][31] &&
                                (captured[gr] >= need[gr]);
            end
            assign frame_ptr[gr*9 +: 9] = next_frame[gr];
        end
    endgenerate

    // scan_ptr is where the round-robin scan starts (the receiver after the one served last), cur_rx and cur_frame
    // are the receiver and frame being worked on.
    reg [2:0] scan_ptr;
    reg [2:0] cur_rx;
    reg [8:0] cur_frame;

    // Round-robin pick, registered (one more clock of lag, covered by SETTLE): rotate `ready` so that bit 0 is the
    // receiver at scan_ptr, take the lowest set bit, and rotate the index back.
    reg       pick_found;
    reg [2:0] pick_rx;
    reg [2*NUM_RX-1:0] ready2;
    reg [NUM_RX-1:0]   rot;
    reg [2:0]          first;
    reg                any;
    integer   pk;
    always @* begin
        ready2 = {ready, ready} >> scan_ptr;
        rot    = ready2[NUM_RX-1:0];
        any    = |rot;
        first  = 3'd0;
        for (pk = NUM_RX - 1; pk >= 0; pk = pk - 1)
            if (rot[pk]) first = pk;
    end
    wire [3:0] pick_sum = scan_ptr + first;
    always @(posedge clk) begin
        pick_found <= any;
        pick_rx    <= (pick_sum >= NUM_RX) ? pick_sum - NUM_RX : pick_sum;      // mod NUM_RX (mod 8 by width for 8)
    end

    // Scheduler states: idle and waiting (S_IDLE); five set-up states, of which the first three give the configuration
    // select its three clocks, the fourth loads the frame number and the first sample, and the fifth starts the slot
    // reader; then waiting for the reader (S_READ), the transform (S_XFORM), the power stage and ring writer (S_POWER),
    // and waiting for the ring writer's FIFO to drain (S_DRAIN).
    localparam S_IDLE = 4'd0, S_READ = 4'd1, S_XFORM = 4'd2, S_POWER = 4'd3, S_DRAIN = 4'd4,
               S_SETUP = 4'd5, S_SETUP2 = 4'd6, S_SETUP3 = 4'd7, S_SETUP1 = 4'd8,
               S_SETUP4 = 4'd9;
    // SETTLE: after a change the pick needs this many clocks to be right again: ready lags next_frame by 2 clocks and
    // the pick by 1 more, and next_frame itself is written one clock after the frame's completion (the registered
    // commit below).
    localparam [2:0] SETTLE = 3'd5;
    reg [3:0] st;
    reg [2:0] settle;
    assign engine_busy = (st != S_IDLE);

    // Frame data path: slot reader (DDR3 to a 2,048-sample frame buffer), frame core (transform and combine), power
    // stage and spectrogram ring writer.  rd_first_sample is the first sample number of the frame to read.
    // ================================================================ per-frame data path
    wire        frd_start;
    wire [ADDR_WIDTH-1:0] rd_ring_base_sel;
    reg  [31:0] rd_first_sample;

    wire        rdr_busy, rdr_done;
    wire        buf_wr_en;
    wire [10:0] buf_wr_addr;
    wire [15:0] buf_wr_data;

    ft8_slot_reader #(.ADDR_WIDTH(ADDR_WIDTH)) u_reader (
        .clk(clk), .rst(rst),
        .start(frd_start), .ring_base(rd_ring_base_sel), .first_sample(rd_first_sample),
        .busy(rdr_busy), .done(rdr_done),
        .buf_wr_en(buf_wr_en), .buf_wr_addr(buf_wr_addr), .buf_wr_data(buf_wr_data),
        .req(rd_req), .addr(rd_addr_o), .burstlen(rd_burstlen),
        .gnt(rd_gnt), .rvalid(rd_rvalid), .rdata(rd_rdata), .rdone(rd_rdone)
    );

    wire frame_start_w, frame_busy_w, frame_done_w;
    wire p_rd_en; wire [9:0] p_rd_addr;
    wire signed [43:0] p_rd_re, p_rd_im;

    ft8_frame_core u_core (
        .clk(clk), .rst(rst),
        .buf_wr_en(buf_wr_en), .buf_wr_addr(buf_wr_addr), .buf_wr_data(buf_wr_data),
        .frame_start(frame_start_w), .frame_busy(frame_busy_w), .frame_done(frame_done_w),
        .rd_en(p_rd_en), .rd_addr(p_rd_addr), .rd_re(p_rd_re), .rd_im(p_rd_im)
    );

    wire        pw_start, pw_busy, pw_done;
    wire        pw_out_valid;
    wire [9:0]  pw_out_bin;
    wire [31:0] pw_out_word;
    reg  [4:0]  pw_sh;

    wire [1:0] ring_credit;
    wire       ring_idle;

    ft8_power #(.CREDITS(64)) u_power (
        .clk(clk), .rst(rst),
        .start(pw_start), .sh(pw_sh), .busy(pw_busy), .done(pw_done), .credit(ring_credit),
        .rd_en(p_rd_en), .rd_addr(p_rd_addr), .rd_re(p_rd_re), .rd_im(p_rd_im),
        .out_valid(pw_out_valid), .out_bin(pw_out_bin), .out_word(pw_out_word)
    );

    wire [ADDR_WIDTH-1:0] ring_addr_w;
    wire [7:0]  ring_burstlen_w;
    wire [63:0] ring_wdata_w;
    wire [7:0]  ring_wmask_w;
    wire        ring_req_w, ring_gnt_w, ring_done_w;
    reg  [ADDR_WIDTH-1:0] ring_base_sel;
    reg  [8:0]  ring_frame_sel;

    ft8_ring_writer #(.ADDR_WIDTH(ADDR_WIDTH), .BURST(16), .DEPTH(32)) u_ring (
        .clk(clk), .rst(rst),
        .in_valid(pw_out_valid), .in_bin(pw_out_bin), .in_word(pw_out_word),
        .ring_base(ring_base_sel), .frame_index(ring_frame_sel),
        .credit(ring_credit), .idle(ring_idle),
        .req(ring_req_w), .addr(ring_addr_w), .burstlen(ring_burstlen_w),
        .wdata(ring_wdata_w), .wmask(ring_wmask_w), .gnt(ring_gnt_w), .done(ring_done_w)
    );

    assign capw_req = cap_req_w;    assign capw_addr = cap_addr_w;   assign capw_burstlen = cap_burstlen_w;
    assign capw_wdata = cap_wdata_w; assign capw_wmask = cap_wmask_w;
    assign cap_gnt_w = capw_gnt;    assign cap_done_w = capw_done;
    assign ringw_req = ring_req_w;  assign ringw_addr = ring_addr_w; assign ringw_burstlen = ring_burstlen_w;
    assign ringw_wdata = ring_wdata_w; assign ringw_wmask = ring_wmask_w;
    assign ring_gnt_w = ringw_gnt;  assign ring_done_w = ringw_done;


    // The settings of the receiver being served (rings, boundary, frame number, power shift), registered from
    // cur_rx in two steps: a 4-way select on cur_rx[1:0] for each half of the receivers, then a 2-way select on
    // cur_rx[2].  They are valid two clocks after cur_rx changes (S_SETUP and S_SETUP1 wait for it).  One 8-way select
    // in a single clock did not meet timing, mostly because of the routing of cur_rx's fan-out.
    localparam integer SW = 2 * ADDR_WIDTH + 32 + 9 + 5;   // one receiver's settings
    reg [2:0] cur_rx_sel /* synthesis syn_maxfan = 10000 */;
    wire [SW-1:0] cfg [0:7];        // 8 entries whatever NUM_RX is: the ones that are not built are 0
    genvar gs;
    generate
        for (gs = 0; gs < NUM_RX; gs = gs + 1) begin : g_cfg
            assign cfg[gs] = {(CFG_EXT != 0) ? {ADDR_WIDTH{1'b0}} : cap_ring_base[gs*ADDR_WIDTH +: ADDR_WIDTH],
                              (CFG_EXT != 0) ? {ADDR_WIDTH{1'b0}} : spec_ring_base[gs*ADDR_WIDTH +: ADDR_WIDTH],
                              slot_boundary_ptr[gs*32 +: 32], next_frame[gs],
                              pwr_shift[gs*5 +: 5]};
        end
        for (gs = NUM_RX; gs < 8; gs = gs + 1) begin : g_cfg_off
            assign cfg[gs] = {SW{1'b0}};
        end
    endgenerate
    reg [SW-1:0] cfg_lo, cfg_hi, cfg_sel;
    reg          sel_hi;
    // The replay's settings come in the receivers' layout (cfg_rp): its audio buffer starts at slot sample 0.
    reg          cur_rp;                                  // the frame in hand is a replay frame
    reg          cur_rp_sel /* synthesis syn_maxfan = 10000 */;
    wire [SW-1:0] cfg_rp = {rp_cap_base, rp_spec_base, 32'd0, rp_frame, rp_sh};
    reg  [2*ADDR_WIDTH-1:0] ext_q;
    wire [SW-1:0] cfg_pick = sel_hi ? cfg_hi : cfg_lo;
    assign cfg_rx = cur_rx_sel;
    always @(posedge clk) begin
        cur_rx_sel <= cur_rx;
        cfg_lo  <= cfg[{1'b0, cur_rx_sel[1:0]}];
        cfg_hi  <= cfg[{1'b1, cur_rx_sel[1:0]}];
        ext_q   <= cfg_bases;
        sel_hi  <= cur_rx_sel[2];
        cur_rp_sel <= cur_rp;                             // settles a clock before sel_hi; S_SETUP2 reads cfg_sel
        cfg_sel <= cur_rp_sel ? cfg_rp : (CFG_EXT != 0) ? {ext_q, cfg_pick[SW-2*ADDR_WIDTH-1:0]} : cfg_pick;
    end
    wire [ADDR_WIDTH-1:0] cap_ring_base_sel_r  = cfg_sel[SW-1 -: ADDR_WIDTH];
    wire [ADDR_WIDTH-1:0] spec_ring_base_sel_r = cfg_sel[SW-ADDR_WIDTH-1 -: ADDR_WIDTH];
    wire [31:0]           sel_boundary         = cfg_sel[14 +: 32];
    wire [8:0]            sel_frame            = cfg_sel[5 +: 9];
    wire [4:0]            sel_sh               = cfg_sel[4:0];
    assign rd_ring_base_sel = cap_ring_base_sel_r;
    // Power shift, ring base and frame number for the power stage and the ring writer: copied on every clock
    // (cur_rx and cur_frame hold still from S_SETUP2 until the frame's interrupt), not loaded on a state decode,
    // which did not meet timing.
    always @(posedge clk) begin
        pw_sh          <= sel_sh;
        ring_base_sel  <= spec_ring_base_sel_r;
        ring_frame_sel <= cur_frame;
    end

    // Frame completion commit, registered: the receiver as a one-hot word and cur_frame + 1 are ready from S_SETUP3
    // on, so that the write of next_frame is a plain enable and not a state decode through an 8-way select behind
    // the ring writer's idle flag.
    reg [NUM_RX-1:0] cur_onehot;
    reg [8:0]        cur_frame_p1;
    reg              commit;

    // One-clock start pulses for the three stages (registered, so each is a plain flip-flop).
    reg frd_start_reg, frame_start_reg, pw_start_reg;
    assign frd_start     = frd_start_reg;
    assign frame_start_w = frame_start_reg;
    assign pw_start       = pw_start_reg;

    integer i;
    // The scheduler state machine.  Set-up, then read, transform, power and drain one frame per pass, and the
    // bookkeeping at the end (frame counters, interrupt, replay progress, slot restart).

    always @(posedge clk) begin
        frd_start_reg   <= 1'b0;
        frame_start_reg <= 1'b0;
        pw_start_reg    <= 1'b0;
        irq             <= 1'b0;
        commit          <= 1'b0;
        if (rst) begin
            st       <= S_IDLE;
            scan_ptr <= 3'd0;
            irq_rx   <= 3'd0;
            irq_frame <= 9'd0;
            settle   <= SETTLE;
            cur_rp   <= 1'b0;
            rp_busy  <= 1'b0;
            rp_frame <= 9'd0;
            rp_done  <= 1'b0;
            for (i = 0; i < NUM_RX; i = i + 1) next_frame[i] <= 9'd0;
        end else begin
            case (st)
                S_IDLE: begin
                    if (settle != 3'd0) begin
                        settle <= settle - 3'd1;
                    end else if (pick_found) begin
                        cur_rx <= pick_rx;
                        cur_rp <= 1'b0;
                        st     <= S_SETUP;
                    end else if (rp_busy) begin
                        // no live frame is due: the next replay frame
                        cur_rp <= 1'b1;
                        st     <= S_SETUP;
                    end
                end
                S_SETUP: st <= S_SETUP1;          // cfg_sel loads from the new cur_rx:
                S_SETUP1: st <= S_SETUP4;         // cur_rx_sel, cfg_lo/hi, cfg_sel = 3 clocks
                S_SETUP4: st <= S_SETUP2;
                S_SETUP2: begin
                    cur_frame       <= sel_frame;
                    rd_first_sample <= sel_boundary + {sel_frame, 9'd0} - {sel_frame, 5'd0};
                    st              <= S_SETUP3;
                end
                S_SETUP3: begin
                    frd_start_reg <= 1'b1;
                    cur_onehot    <= cur_rp ? {NUM_RX{1'b0}} : ({{(NUM_RX-1){1'b0}}, 1'b1} << cur_rx);
                    cur_frame_p1  <= cur_frame + 9'd1;
                    st            <= S_READ;
                end
                S_READ: begin
                    if (rdr_done) begin
                        frame_start_reg <= 1'b1;
                        st <= S_XFORM;
                    end
                end
                S_XFORM: begin
                    if (frame_done_w) begin
                        pw_start_reg   <= 1'b1;
                        st <= S_POWER;
                    end
                end
                S_POWER: begin
                    if (pw_done) st <= S_DRAIN;
                end
                S_DRAIN: begin
                    // the last words may still sit in the ring writer's FIFO: the interrupt
                    // promises the frame is in DDR3
                    if (ring_idle) begin
                        commit    <= 1'b1;
                        if (!cur_rp) begin
                            scan_ptr  <= (cur_rx == NUM_RX - 1) ? 3'd0 : cur_rx + 3'd1;
                            irq       <= 1'b1;
                            irq_rx    <= cur_rx;
                            irq_frame <= cur_frame;
                        end
                        settle    <= SETTLE;
                        st <= S_IDLE;
                    end
                end
                default: st <= S_IDLE;
            endcase
            for (i = 0; i < NUM_RX; i = i + 1)
                if (commit && cur_onehot[i]) next_frame[i] <= cur_frame_p1;
            // replay bookkeeping: a frame done, the last one ends it; a start wins over both
            rp_done <= 1'b0;
            if (commit && cur_rp) begin
                rp_frame <= cur_frame_p1;
                if (cur_frame_p1 == N_TIME) begin
                    rp_busy <= 1'b0;
                    rp_done <= !rp_start;
                end
            end
            if (rp_start) begin
                rp_frame <= 9'd0;
                rp_busy  <= 1'b1;
            end
            // a new slot restarts that receiver at frame 0 (after the completion above, so it
            // wins if both land on the same clock)
            for (i = 0; i < NUM_RX; i = i + 1)
                if (slot_start[i]) next_frame[i] <= 9'd0;
            if ((slot_start != {NUM_RX{1'b0}} || rp_start) &&
                (st == S_IDLE || st == S_SETUP || st == S_SETUP1 || st == S_SETUP4 ||
                 st == S_SETUP2 || st == S_SETUP3)) begin
                // readiness is 2 clocks stale after a slot start, so a pick made around it may be
                // for a frame of the old slot: drop it (no read started yet) and re-settle
                settle        <= SETTLE;
                st            <= S_IDLE;
                frd_start_reg <= 1'b0;
            end
        end
    end

endmodule
