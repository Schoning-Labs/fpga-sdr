// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ft8_sync: the Costas sync search of the FT8 front end.
//
// What the search is for
//   A receiver does not know when a station started sending (the clocks differ by a fraction of a second) or on which audio
//   frequency (see ft8_frontend.v for the signal structure).  What it does know is that every FT8 signal contains three blocks
//   of 7 symbols with the same tone pattern, the Costas array 3 1 4 0 6 5 2, starting at symbols 0, 36 and 72.  So for every
//   candidate frequency and start time it adds up the energy found at the tones where the Costas array should be, compares it
//   with the energy at the other tones, and the offsets where the ratio is high are the signals worth decoding.  This is what the
//   WSJT-X decoder calls `sync8`, and this block follows its arithmetic with fixed-point numbers (the Rust model in
//   fw/tr-modes/src/frontend/sync.rs, `sync_fx_rows`, which this block equals bit for bit).  Design, timing and done-tests are in
//   docs/F6_SYNC.md.
//
// What it computes
//   Over the spectrogram that ft8_spectrogram.v wrote into the receiver's DDR3 ring (S[m][b], frame m and bin b; the bins are
//   3.125 Hz apart and a tone is 2 bins from the next), for every carrier bin i = ia .. ib of one decoder receiver and every lag
//   L = -63 .. 63 (in frames of 40 ms, so up to +-2.5 s around the nominal start):
//
//   t_b  = sum_n S[m][i + 2 COSTAS[n]],   t0_b = sum_n sum_{k=0..6} S[m][i + 2k],
//   m    = 13 + 4 (COSTAS_POS[b] + n) + L,  only frames 0 <= m < n_rows count,
//
//   where b = 0 .. 2 is the Costas block, n = 0 .. 6 the position in it, 13 is the frame where block 0 starts when L = 0 (the
//   transmission starts 0.5 s into the slot, and 4 frames are one symbol), t_b is the energy at the expected tone and t0_b the
//   energy at all 7 tones of the block.  Then
//
//   sync = max(score(t_0 + t_1 + t_2, t0_0 + t0_1 + t0_2), score(t_1 + t_2, t0_1 + t0_2)),
//
//   which takes the better of the score over all three blocks and the score over the last two (a signal that started late in
//   the slot may be missing its first block), and score(t, t0) = 6 t x 2^16 / (t0 - t + 6) is computed by ft8_sync_div.v.  Per
//   bin the search keeps the first maximum over |L| <= 10 (the "primary") and over all L (the "secondary"), each with the scores at
//   L - 1, L and L + 1, which the firmware needs to interpolate the time.
//
//   Record per bin, 8 x 32-bit words (lag_p | lag_s << 8, three primary scores, three secondary scores, 0), which is 4 DDR3 lane
//   words at rec_base + 4 (i - ia), word 2k in the low half.
//
// How it works
//   There is no stripe buffer.  The engine streams spectrogram rows from DDR3 in lag order.  One pass covers 64 carriers (32
//   carrier pairs).  For each lag it reads the segments of the 21 Costas rows (bins cs .. cs + 75, that is 38 lane words, since a
//   carrier needs the 13 bins from i to i + 12), in the block order 1, 2, 0, and adds each row into per-carrier sums t and t0 as the
//   words arrive (two carriers per word, one word per clock, with no row buffer).  After block 2 the sums are the "last two
//   blocks" pair and after block 0 the "all three blocks" pair.  Both go to the divider (one score per 8 or more clocks) through
//   a 32-entry queue, and the scores to the per-carrier best-lag tracker (one 1,024 x 36 block RAM, 16 words per carrier).  At the
//   end of a pass the tracker is read out into the records.  Rows outside 0 .. n_rows - 1 are streamed as zeros without a DDR3 read.
//
//   Because the t0 sums are over 7 words, a sliding window (add the new word, subtract the one 7 words back) does them in one
//   step per word, and the expected tone is picked from the delay memory.  The stream pipeline is described below at its registers.
//
// Timing rules
//   It is built by the rules in docs/TANG_LESSONS.md sections 3 and 6 (docs/F6_SYNC.md section 4): the stream pipeline and the
//   divider feed have no load enables (a stage that has nothing valid adds zero, and the feed registers run freely behind a read
//   pointer that moves only when a job is taken); every memory but the tracker is LUT RAM with a registered address; and no clock
//   holds two carry chains.
//
// Starting a search
//   Early-decode triggers: per receiver `trig1` and `trig2` (frame counts, 0 = off) and the slot's last frame (372) queue a search
//   over the first `trig` frames when that receiver's frame counter (`frame_ptr`, from ft8_spectrogram.v) reaches them, so that
//   the first decodes can come before the slot has ended; `slot_start` re-arms all three.  `cmd_start` queues one directly (for
//   example for a second decode pass over a residual spectrogram).  One search per receiver can be pending, and a later request
//   with more rows replaces it.  Receivers are served round-robin.  `irq` pulses when a search's records are all in DDR3 (`irq_rx`
//   and `irq_rows` say which), and `run_clocks` is that search's length in clocks.
//
// Configuration
//   Plain input ports (as in ft8_spectrogram.v); `band_ib` has to be at most 1,009 (the model's K - 15) and at least `band_ia`.

`timescale 1ns / 1ps
`include "rtl/ft8/ft8_sync_div.v"

module ft8_sync #(
    // NUM_RX: decoder receivers.  ADDR_WIDTH: DDR3 word address width.  N_TIME: frames per slot (372).
    parameter integer NUM_RX     = 8,
    parameter integer ADDR_WIDTH = 32,
    parameter integer N_TIME     = 372,
    // DIV_PAIRS: A/B pairs of the score divider's ring (ft8_sync_div.v).  1 gives a score every 32 clocks, so the divider then
    // sets the pace of a lag: 4,096 clocks against about 3,600 from the memory.  4 gives a score every 8 clocks.
    parameter integer DIV_PAIRS  = 1,
    // CFG_EXT = 1: {spectrogram ring base, record base} of receiver `cfg_rx` come in on `cfg_bases` from LUT RAM in the caller,
    // and not through the 8-way selects here; `spec_ring_base` and `rec_base` are then unused.
    parameter integer CFG_EXT    = 0
) (
    // Clock (clk_dsp, 120 MHz) and synchronous reset (active high).
    input  wire        clk,
    input  wire        rst,

    // Per-receiver configuration: ring bases (lane word addresses), the carrier band, and the early-decode triggers.
    input  wire [NUM_RX*ADDR_WIDTH-1:0] spec_ring_base,  // spectrogram ring of each receiver, lane words
    input  wire [NUM_RX*ADDR_WIDTH-1:0] rec_base,        // sync records, lane words
    // With CFG_EXT = 1: the receiver number the caller looks up (cfg_rx) and the two bases it answers with (cfg_bases).
    output wire [2:0]                   cfg_rx,
    input  wire [2*ADDR_WIDTH-1:0]      cfg_bases,
    // band_ia and band_ib: first and last carrier bin of the search (10 bits per receiver, 3.125 Hz per bin).
    input  wire [NUM_RX*10-1:0]         band_ia,
    input  wire [NUM_RX*10-1:0]         band_ib,
    // trig1 and trig2: frame counts at which an early search starts (9 bits per receiver, 0 = off).  frame_ptr: frames of
    // the running slot already in DDR3.  slot_start: a one-clock pulse per receiver that re-arms the triggers.
    input  wire [NUM_RX*9-1:0]          trig1,           // early-decode frame counts, 0 = off
    input  wire [NUM_RX*9-1:0]          trig2,
    input  wire [NUM_RX*9-1:0]          frame_ptr,       // from ft8_spectrogram.v
    input  wire [NUM_RX-1:0]            slot_start,      // re-arm the triggers
    // Direct request: a one-clock cmd_start with the receiver cmd_rx and the number of frames cmd_rows to search.
    input  wire                         cmd_start,
    input  wire [2:0]                   cmd_rx,
    input  wire [8:0]                   cmd_rows,
    // second decode pass (docs/FT8_PASS2.md): one more request, a search over all N_TIME rows of
    // the residual's spectrogram at `alt_spec_base`, records to `alt_rec_base`, with the band of
    // receiver `alt_rx`. A receiver's own search goes first. The three inputs must hold from
    // `alt_start` until the search's `irq` (the front end's registers do).
    input  wire                         alt_start,
    input  wire [2:0]                   alt_rx,
    input  wire [ADDR_WIDTH-1:0]        alt_spec_base,
    input  wire [ADDR_WIDTH-1:0]        alt_rec_base,

    // Status: busy while a search runs; irq (one clock) when its records are in DDR3, with the receiver (irq_rx), the rows
    // searched (irq_rows) and, in irq_alt, whether it was the residual's search; run_clocks is its length in clocks.
    output wire                         busy,
    output reg                          irq,
    output reg  [2:0]                   irq_rx,
    output reg  [8:0]                   irq_rows,
    output reg                          irq_alt,     // with irq: it was the residual's search
    output reg  [31:0]                  run_clocks,

    // read-lane client (rtl/ddr3/ddr3_read_arbiter.v convention, "rest" tier through the FT8
    // read sub-arbiter)
    output reg                          rd_req,
    output reg  [ADDR_WIDTH-1:0]        rd_addr,
    output reg  [7:0]                   rd_burstlen,
    input  wire                         rd_gnt,
    input  wire                         rd_rvalid,
    input  wire [63:0]                  rd_rdata,
    input  wire                         rd_done,

    // write-lane client (rtl/ddr3/ddr3_write_arbiter.v convention)
    output reg                          wr_req,
    output reg  [ADDR_WIDTH-1:0]        wr_addr,
    output wire [7:0]                   wr_burstlen,
    output reg  [63:0]                  wr_wdata,
    output wire [7:0]                   wr_wmask,
    input  wire                         wr_gnt,
    input  wire                         wr_done
);

    // A record is one burst of 4 lane words, written whole (mask all ones).
    assign wr_burstlen = 8'd4;
    assign wr_wmask    = 8'hFF;

    // ================================================================ requests and triggers
    // Per receiver, in registers of its own (packed into the vectors below; a register array
    // written in a loop is what Gowin turned into a "RAMREG", docs/TANG_LESSONS.md section 8).
    // The rows of a trigger that meets a request already pending (the larger of the two) are
    // formed a clock ahead (mx1, mx2), so the update is one select per bit.
    // armed: the three triggers still armed per receiver (bit 0 trigger 1, bit 1 trigger 2, bit 2 the slot's last frame).
    // pend and pend_rows: a search is pending for the receiver and its length in frames.
    wire [NUM_RX*3-1:0] armed;
    wire [NUM_RX-1:0]   pend;
    wire [NUM_RX*9-1:0] pend_rows;
    // hit1, hit2 and hitf say that the receiver's frame counter has reached trigger 1, trigger 2 or the last frame (compared
    // one clock late); t1r and t2r are the trigger values, registered.
    reg [NUM_RX-1:0] hit1, hit2, hitf;
    reg [8:0]        t1r [0:NUM_RX-1];
    reg [8:0]        t2r [0:NUM_RX-1];
    reg              take;          // scheduler takes cur_rx's request this clock
    reg              pend_alt;      // the residual's search is asked for
    reg              take_alt;      // scheduler takes it this clock
    reg              cur_alt /* synthesis syn_maxfan = 10000 */;   // the running search is the residual's
    reg [2:0]        cur_rx;
    genvar gr;
    generate
        for (gr = 0; gr < NUM_RX; gr = gr + 1) begin : g_trig
            // fp is this receiver's frame counter.
            wire [8:0] fp = frame_ptr[gr*9 +: 9];
            always @(posedge clk) begin
                t1r[gr]  <= trig1[gr*9 +: 9];
                t2r[gr]  <= trig2[gr*9 +: 9];
                hit1[gr] <= (t1r[gr] != 9'd0) && (fp >= t1r[gr]);
                hit2[gr] <= (t2r[gr] != 9'd0) && (fp >= t2r[gr]);
                hitf[gr] <= (fp >= N_TIME);
            end

            // Request state of this receiver: arm_r (the armed triggers), pend_r (a search is pending), rows_r (its length in
            // frames), mx1 and mx2 (the rows of the trigger, or those of a pending request if larger), tk (the request is being taken).
            reg [2:0] arm_r;
            reg       pend_r;
            reg [8:0] rows_r, mx1, mx2;
            reg       tk;                  // this receiver's request is being taken
            assign armed[gr*3 +: 3]     = arm_r;
            assign pend[gr]             = pend_r;
            assign pend_rows[gr*9 +: 9] = rows_r;
            // Triggers, direct command and take: a hit makes a request, a later request with more rows replaces the pending one.
            always @(posedge clk) begin
                tk  <= take && (cur_rx == gr);
                mx1 <= (pend_r && !tk && rows_r > t1r[gr]) ? rows_r : t1r[gr];
                mx2 <= (pend_r && !tk && rows_r > t2r[gr]) ? rows_r : t2r[gr];
                if (rst) begin
                    arm_r  <= 3'b000;
                    pend_r <= 1'b0;
                    rows_r <= 9'd0;
                end else begin
                    if (take && cur_rx == gr) pend_r <= 1'b0;
                    if (slot_start[gr]) begin
                        arm_r <= 3'b111;
                    end else begin
                        // a hit acts only while its trigger is still armed (the compare is a
                        // clock behind the arming)
                        if (arm_r[2] && hitf[gr]) begin
                            arm_r  <= 3'b000;
                            pend_r <= 1'b1;
                            rows_r <= N_TIME;
                        end else if (arm_r[1] && hit2[gr]) begin
                            arm_r[1] <= 1'b0;
                            pend_r   <= 1'b1;
                            rows_r   <= mx2;
                        end else if (arm_r[0] && hit1[gr]) begin
                            arm_r[0] <= 1'b0;
                            pend_r   <= 1'b1;
                            rows_r   <= mx1;
                        end
                    end
                    if (cmd_start && cmd_rx == gr) begin
                        pend_r <= 1'b1;
                        rows_r <= cmd_rows;
                    end
                end
            end
        end
    endgenerate

    // The residual's search (pass 2) has one request flag of its own.
    always @(posedge clk) begin
        if (rst) pend_alt <= 1'b0;
        else if (alt_start) pend_alt <= 1'b1;
        else if (take_alt) pend_alt <= 1'b0;
    end

    // Round-robin pick of the next pending receiver, registered, in the same way as the scheduler in ft8_spectrogram.v.
    reg [2:0] scan_ptr;
    reg       pick_found;
    reg [2:0] pick_rx;
    reg [2*NUM_RX-1:0] pend2;
    reg [NUM_RX-1:0]   rot;
    reg [2:0]          first;
    integer pk;
    reg [NUM_RX-1:0]   rot_q;
    reg [2:0]          scan_q;
    always @* begin
        pend2 = {pend, pend} >> scan_ptr;
        rot   = pend2[NUM_RX-1:0];
        first = 3'd0;
        for (pk = NUM_RX - 1; pk >= 0; pk = pk - 1)
            if (rot_q[pk]) first = pk;
    end
    // two clocks behind `pend` and `scan_ptr`: S_DONE waits them out before S_IDLE looks
    wire [3:0] pick_sum = scan_q + first;
    always @(posedge clk) begin
        rot_q      <= rot;
        scan_q     <= scan_ptr;
        pick_found <= |rot_q;
        pick_rx    <= (pick_sum >= NUM_RX) ? pick_sum - NUM_RX : pick_sum;      // mod NUM_RX (mod 8 by width for 8)
    end

    // the selected receiver's settings, in two registered steps (as ft8_spectrogram.v)
    localparam integer CW = 2 * ADDR_WIDTH + 20;
    wire [CW-1:0] cfg [0:7];        // 8 entries whatever NUM_RX is: the ones that are not built are 0
    generate
        for (gr = 0; gr < NUM_RX; gr = gr + 1) begin : g_cfg
            assign cfg[gr] = {(CFG_EXT != 0) ? {(2*ADDR_WIDTH){1'b0}}
                                             : {spec_ring_base[gr*ADDR_WIDTH +: ADDR_WIDTH], rec_base[gr*ADDR_WIDTH +: ADDR_WIDTH]},
                              band_ia[gr*10 +: 10], band_ib[gr*10 +: 10]};
        end
        for (gr = NUM_RX; gr < 8; gr = gr + 1) begin : g_cfg_off
            assign cfg[gr] = {CW{1'b0}};
        end
    endgenerate
    reg [2:0]    cur_rx_sel /* synthesis syn_maxfan = 10000 */;
    reg [CW-1:0] cfg_lo, cfg_hi, cfg_sel;
    reg          sel_hi /* synthesis syn_maxfan = 10000 */;
    reg  [2*ADDR_WIDTH-1:0] ext_q;
    wire [CW-1:0] cfg_pick = sel_hi ? cfg_hi : cfg_lo;
    assign cfg_rx = cur_rx_sel;
    always @(posedge clk) begin
        cur_rx_sel <= cur_rx;
        cfg_lo   <= cfg[{1'b0, cur_rx_sel[1:0]}];
        cfg_hi   <= cfg[{1'b1, cur_rx_sel[1:0]}];
        sel_hi   <= cur_rx_sel[2];
        ext_q    <= cfg_bases;
        cfg_sel  <= (CFG_EXT != 0) ? {ext_q, cfg_pick[19:0]} : cfg_pick;
    end

    // The running search: bases, band, number of rows, and the counters of its position.  cs is the first carrier of the pass,
    // row_base the address of the row's segment, npairs and nw the carrier pairs and lane words of the pass (a full pass has 32
    // pairs and 38 words), dcs the carriers still to do, lag the lag, and q, qb and qn the row number (0 .. 20) with its block
    // (in the order 1, 2, 0) and its position in the block.
    // ================================================================ job state
    reg [ADDR_WIDTH-1:0] spec_base, rec_b;
    reg [9:0]  ia, ib;
    reg [8:0]  rows;
    reg [9:0]  cs;              // first carrier of the pass (even)
    reg [ADDR_WIDTH-1:0] row_base;  // spec_base + cs / 2
    reg [5:0]  npairs;          // carrier pairs in the pass, 1 .. 32
    reg [5:0]  nw;              // lane words per row segment = npairs + 6
    reg [5:0]  nwm1;            // nw - 1
    reg [9:0]  dcs;             // ib - cs
    reg        last_pass;       // no carrier is left after this pass
    reg [5:0]  oci_last;        // last carrier of the pass, 2 npairs - 1
    reg        zrow /* synthesis syn_maxfan = 10000 */;   // the row is outside the slot: zeros
    reg [3:0]  rowoff;          // (Costas tone of the row - 6) mod 16
    reg signed [7:0] lag;       // -63 .. 63
    reg [4:0]  q;               // row 0 .. 20 of the lag: blocks 1, 2, 0
    reg [1:0]  qb;              // block-order index 0, 1, 2 (= Costas block 1, 2, 0)
    reg [2:0]  qn;              // position 0 .. 6 in the block

    // The row being streamed: row_first (the first row of a lag, which writes instead of adds), row_pushb and row_pusha (the row
    // after which the sums go to the divider: after block 2, and after block 0), row_c (its Costas tone), row_m (its frame
    // number), row_in (inside the slot) and wk (the word index in the row).
    // row being streamed (flags travel with its words down the pipeline)
    reg        row_first, row_pushb, row_pusha;
    reg [2:0]  row_c;
    reg signed [9:0] row_m;
    reg        row_in;
    reg [5:0]  wk;              // word index in the row

    // Main sequencer states: configuration select (S_CFG*), start of a pass (S_PASS0, S_PASS), the rows (S_ROW, S_ROW2, S_ROW2B,
    // S_ROW3, S_REQ, S_STREAM or S_ZERO, S_NEXT), draining the pipeline (S_DRAIN), the read-out of the records (S_OUT, S_OUT2,
    // S_WR) and the end (S_DONE and following).
    localparam [4:0] S_IDLE = 5'd0, S_CFG1 = 5'd1, S_CFG2 = 5'd2, S_CFG3 = 5'd3, S_CFG4 = 5'd4,
                     S_PASS = 5'd5, S_ROW = 5'd6, S_ROW2 = 5'd7, S_ROW3 = 5'd8, S_REQ = 5'd9,
                     S_STREAM = 5'd10, S_ZERO = 5'd11, S_NEXT = 5'd12, S_DRAIN = 5'd13,
                     S_OUT = 5'd14, S_OUT2 = 5'd15, S_WR = 5'd16, S_DONE = 5'd17,
                     S_PASS0 = 5'd18, S_ROW2B = 5'd19, S_DONE2 = 5'd20, S_DONE3 = 5'd21;
    reg [4:0] st;
    assign busy = (st != S_IDLE);
    // The states that load wide registers do it through a flag registered one clock ahead (each
    // always follows one state), so those load enables are register outputs, not state decodes.
    reg       s_cfg4, s_row2b;
    always @(posedge clk) begin
        s_cfg4  <= (st == S_CFG3) && !rst;
        s_row2b <= (st == S_ROW2) && !rst;
    end

    // Costas tone of position n, and the start positions of the blocks in the order 1, 2, 0
    function [2:0] costas(input [2:0] n);
        case (n)
            3'd0: costas = 3'd3; 3'd1: costas = 3'd1; 3'd2: costas = 3'd4; 3'd3: costas = 3'd0;
            3'd4: costas = 3'd6; 3'd5: costas = 3'd5; default: costas = 3'd2;
        endcase
    endfunction
    function [6:0] blkpos(input [1:0] b);
        blkpos = (b == 2'd0) ? 7'd36 : (b == 2'd1) ? 7'd72 : 7'd0;
    endfunction

    // ================================================================ stream pipeline
    // One lane word (two bins, one carrier pair) per clock, six stages, none with a load enable.
    // For word k of a row (k = wk when it arrives), with w_i the row's words:
    //   S0  the word as it arrives, zero for a row outside the slot
    //   S1  into the two 16-word delay memories (slot k mod 16); w_(k-7) read, zero for k < 7
    //   S2  delta = w_k - w_(k-7) per half; pair index j = k - 6; address of the expected-tone
    //       word w_(k-6+c), c the row's Costas tone
    //   S3  running 7-bin sums se, so (+ delta; restarted at k = 0); the expected-tone word and
    //       the pair's accumulator entry read
    //   S4  the new sums t (expected tone) and t0 (7 bins) for the even and the odd carrier
    //   S5  written back to the accumulator and, on a row that ends a block set, to the queue
    // The accumulator entry of pair j is read at S3 and written at S5 of the same word; the next
    // read of that pair is a row later.
    wire       in_v = (st == S_STREAM && rd_rvalid) || (st == S_ZERO);

    reg        v0;
    reg [63:0] d0;
    reg [5:0]  k0;
    reg [3:0]  ra0;
    reg        m0 /* synthesis syn_maxfan = 10000 */;
    reg        f0, pb0, pa0;
    reg [6:0]  l0;
    // S0: the word as it arrives.
    always @(posedge clk) begin
        v0  <= in_v && !rst;
        d0  <= zrow ? 64'd0 : rd_rdata;
        k0  <= wk;
        ra0 <= wk[3:0] - 4'd7;
        m0  <= (wk >= 6'd7);
        f0  <= row_first;
        pb0 <= row_pushb;
        pa0 <= row_pusha;
        l0  <= lag[6:0];
    end

    // the row's last 16 words, twice: one read port each (the 7-back word, the tone word)
    reg [63:0] dla [0:15] /* synthesis syn_ramstyle = "distributed_ram" */;
    reg [63:0] dlb [0:15] /* synthesis syn_ramstyle = "distributed_ram" */;
    always @(posedge clk) begin
        if (v0) begin
            dla[k0[3:0]] <= d0;
            dlb[k0[3:0]] <= d0;
        end
    end
    wire [63:0] old_w = dla[ra0];

    reg        v1 /* synthesis syn_maxfan = 10000 */;
    reg [63:0] d1, old1;
    reg [5:0]  k1;
    reg        z1, f1, pb1, pa1;
    reg [6:0]  l1;
    // S1: delay memories written; the word from 7 words back read.
    always @(posedge clk) begin
        v1   <= v0 && !rst;
        d1   <= d0;
        old1 <= m0 ? old_w : 64'd0;
        k1   <= k0;
        z1   <= (k0 == 6'd0);
        f1   <= f0;
        pb1  <= pb0;
        pa1  <= pa0;
        l1   <= l0;
    end

    reg               g2;                  // a valid word that completes a carrier pair (k >= 6)
    reg signed [32:0] de2, do2;
    reg               z2 /* synthesis syn_maxfan = 10000 */;
    reg [4:0]         j2 /* synthesis syn_maxfan = 10000 */;
    reg [3:0]         tb2 /* synthesis syn_maxfan = 10000 */;
    reg               f2, pb2, pa2;
    reg [6:0]         l2;
    wire signed [32:0] dif_e = {1'b0, d1[31:0]}  - {1'b0, old1[31:0]};
    wire signed [32:0] dif_o = {1'b0, d1[63:32]} - {1'b0, old1[63:32]};
    // S2: the difference between the new word and the one 7 back, for each half (carrier).
    always @(posedge clk) begin
        g2  <= v1 && (k1 >= 6'd6) && !rst;
        de2 <= v1 ? dif_e : 33'sd0;        // a clock without a word adds nothing
        do2 <= v1 ? dif_o : 33'sd0;
        z2  <= v1 && z1;
        j2  <= k1[4:0] - 5'd6;
        tb2 <= k1[3:0] + rowoff;
        f2  <= f1;
        pb2 <= pb1;
        pa2 <= pa1;
        l2  <= l1;
    end

    // accumulator: per pair {t 37, t0 40} for the even carrier and the same for the odd one, in
    // two LUT RAMs (their write enables are registers reset from different taps, so the tool
    // keeps them apart: 39 RAM cells each)
    localparam integer HW = 77;
    localparam integer AW = 2 * HW;
    reg [HW-1:0] acc_e [0:31] /* synthesis syn_ramstyle = "distributed_ram" */;
    reg [HW-1:0] acc_o [0:31] /* synthesis syn_ramstyle = "distributed_ram" */;
    reg        g3;
    reg [35:0] se, so;
    reg [31:0] te3, to3;
    reg [HW-1:0] ae3, ao3;
    reg [4:0]  j3;
    reg        f3 /* synthesis syn_maxfan = 10000 */;
    reg        pb3, pa3;
    reg [6:0]  l3;
    wire [63:0] tone_w = dlb[tb2];
    // S3: running sums over 7 words (se and so), the expected-tone word, and the accumulator entry of the pair.
    always @(posedge clk) begin
        g3  <= g2 && !rst;
        se  <= (z2 ? 36'd0 : se) + {{3{de2[32]}}, de2};
        so  <= (z2 ? 36'd0 : so) + {{3{do2[32]}}, do2};
        te3 <= tone_w[31:0];
        to3 <= tone_w[63:32];
        ae3 <= acc_e[j2];
        ao3 <= acc_o[j2];
        j3  <= j2;
        f3  <= f2;
        pb3 <= pb2;
        pa3 <= pa2;
        l3  <= l2;
    end

    // the first row of a lag writes instead of adding, so no clearing pass is needed
    reg        rst_d;
    reg        g4e, g4o, push4e, push4o;
    reg [36:0] nte, nto;
    reg [39:0] nt0e, nt0o;
    reg [4:0]  j4 /* synthesis syn_maxfan = 10000 */;
    reg        pa4;
    reg [6:0]  l4;
    // S4: the new sums t and t0 for the even and the odd carrier; S5 (below) writes them back to the accumulator.
    always @(posedge clk) begin
        rst_d  <= rst;
        g4e    <= g3 && !rst;
        g4o    <= g3 && !rst_d;
        push4e <= g3 && (pb3 || pa3) && !rst;
        push4o <= g3 && (pb3 || pa3) && !rst_d;
        nte    <= (f3 ? 37'd0 : ae3[76:40]) + {5'd0, te3};
        nt0e   <= (f3 ? 40'd0 : ae3[39:0])  + {4'd0, se};
        nto    <= (f3 ? 37'd0 : ao3[76:40]) + {5'd0, to3};
        nt0o   <= (f3 ? 40'd0 : ao3[39:0])  + {4'd0, so};
        j4     <= j3;
        pa4    <= pa3;
        l4     <= l3;
    end
    always @(posedge clk) begin
        if (g4e) acc_e[j4] <= {nte, nt0e};
        if (g4o) acc_o[j4] <= {nto, nt0o};
    end

    // words in the pipeline (S0 .. S5)
    // pv: valid flags of the words in S0 .. S5, to tell when the pipeline is empty.
    reg [5:0] pv;
    always @(posedge clk) pv <= rst ? 6'd0 : {pv[4:0], in_v};

    // job queue: 32 carrier pairs, {sums, kind (1 = all three blocks), lag, pair}, the even
    // carrier's sums in one LUT RAM and the odd carrier's with the tag in another
    localparam integer QTW = 1 + 7 + 5;
    reg  [HW-1:0]     qm_e [0:31] /* synthesis syn_ramstyle = "distributed_ram" */;
    reg  [HW+QTW-1:0] qm_o [0:31] /* synthesis syn_ramstyle = "distributed_ram" */;
    reg  [4:0]    qwp /* synthesis syn_maxfan = 10000 */;
    reg  [4:0]    qrp /* synthesis syn_maxfan = 10000 */;
    reg  [5:0]    qcnt;
    always @(posedge clk) begin
        if (push4e) qm_e[qwp] <= {nte, nt0e};
        if (push4o) qm_o[qwp] <= {nto, nt0o, pa4, l4, j4};
    end

    // ================================================================ divider feed
    // The job is one half (even, then odd carrier) of the queue head, picked by (qrp, fh).
    // Feed stages F1 to F4.  F1: its sums; F2: 6 t and t0 - t; F3: d = t0 - t + 6; F4: the saturation test. The four
    // stages run freely behind (qrp, fh), which only move when the divider takes the job, so F4
    // holds the job FWAIT clocks after the head changed or the queue got its first entry.
    localparam integer TW = 14;              // tag: {kind, lag[6:0], pair[4:0], odd}
    localparam [2:0]   FWAIT = 3'd5;
    reg          fh /* synthesis syn_maxfan = 10000 */;   // half of the head: 0 even, 1 odd
    reg  [36:0]  ft1;
    reg  [39:0]  ft01;
    reg  [TW-1:0] ftag1, ftag2, ftag3, ftag4;
    reg  [39:0]  f6t2, fdf2, f6t3, fd3, f6t4, fd4;
    reg          fsat4;
    wire [HW-1:0]     qh_e = qm_e[qrp];
    wire [HW+QTW-1:0] qh_o = qm_o[qrp];
    always @(posedge clk) begin
        ft1   <= fh ? qh_o[HW+QTW-1 -: 37] : qh_e[76:40];
        ft01  <= fh ? qh_o[HW+QTW-38 -: 40] : qh_e[39:0];
        ftag1 <= {qh_o[QTW-1:0], fh};
        f6t2  <= {1'b0, ft1, 2'b00} + {2'b00, ft1, 1'b0};
        fdf2  <= ft01 - {3'd0, ft1};
        ftag2 <= ftag1;
        f6t3  <= f6t2;
        fd3   <= fdf2 + 40'd6;
        ftag3 <= ftag2;
        f6t4  <= f6t3;
        fd4   <= fd3;
        fsat4 <= {16'd0, f6t3[39:16]} >= fd3;
        ftag4 <= ftag3;
    end

    reg  [2:0]   fwait;
    reg          jv;                         // F4 holds the job of (qrp, fh)
    reg  [3:0]   occ;                        // jobs in the divider plus results queued
    reg  [2:0]   fifo_cnt;
    reg          rpop;
    wire         dv_take;
    wire [3:0]   dv_inflight;
    wire         qpush = push4o;
    // (qrp, fh) and the queue count move the clock after the take, on registered copies of it
    // (the read pointer and `fh` are copied by the tool for the queue memories' address pins;
    // the copies' load enables hang on these). The copies are reset from different taps so the
    // tool keeps them apart.
    reg          rst_d2;
    reg          tk_fh;                      // a job was taken
    reg          tk_rp, tk_cn;               // ... and it was the head's second half
    always @(posedge clk) begin
        rst_d2 <= rst_d;
        tk_fh  <= dv_take && !rst;
        tk_rp  <= dv_take && fh && !rst_d;
        tk_cn  <= dv_take && fh && !rst_d2;
    end
    // Queue pointers and counts: qwp and qrp write and read, qcnt entries in the queue, fh which half of the head is the current
    // job, jv a job is ready, fwait the clocks the feed stages need, and occ the jobs in the divider and results queued.
    always @(posedge clk) begin
        if (rst) begin
            fh <= 1'b0; jv <= 1'b0; fwait <= FWAIT; occ <= 4'd0;
            qwp <= 5'd0; qrp <= 5'd0; qcnt <= 6'd0;
        end else begin
            if (qpush) qwp <= qwp + 5'd1;
            if (tk_rp) qrp <= qrp + 5'd1;
            if (tk_fh) fh  <= !fh;
            qcnt <= qcnt + (qpush ? 6'd1 : 6'd0) - (tk_cn ? 6'd1 : 6'd0);
            occ  <= occ + (dv_take ? 4'd1 : 4'd0) - (rpop ? 4'd1 : 4'd0);
            if (dv_take) begin
                jv    <= 1'b0;
                fwait <= FWAIT;
            end else if (qcnt == 6'd0) begin
                fwait <= FWAIT;
            end else if (fwait != 3'd0) begin
                fwait <= fwait - 3'd1;
            end else begin
                jv <= 1'b1;
            end
        end
    end

    // results queued never exceed 7 (the result FIFO holds 8, its count 7)
    wire          dv_out;
    wire [31:0]   dv_q;
    wire [TW-1:0] dv_tag;
    ft8_sync_div #(.TAG_W(TW), .PAIRS(DIV_PAIRS)) u_div (
        .clk(clk), .rst(rst),
        .in_valid(jv), .in_room(occ < 4'd7), .in_take(dv_take),
        .in_t6(f6t4), .in_d(fd4), .in_sat(fsat4), .in_tag(ftag4),
        .out_valid(dv_out), .out_q(dv_q), .out_tag(dv_tag), .in_flight(dv_inflight)
    );

    // result FIFO, 8 entries of {score, tag}
    reg  [31+TW:0] rfifo [0:7] /* synthesis syn_ramstyle = "distributed_ram" */;
    reg  [2:0]     rwp, rrp;
    always @(posedge clk) begin
        if (dv_out) rfifo[rwp] <= {dv_q, dv_tag};
        if (rst) begin
            rwp <= 3'd0; rrp <= 3'd0; fifo_cnt <= 3'd0;
        end else begin
            if (dv_out) rwp <= rwp + 3'd1;
            if (rpop)   rrp <= rrp + 3'd1;
            fifo_cnt <= fifo_cnt + (dv_out ? 3'd1 : 3'd0) - (rpop ? 3'd1 : 3'd0);
        end
    end
    wire [31+TW:0] rhead   = rfifo[rrp];
    wire [31:0]    rh_q    = rhead[31+TW -: 32];
    wire           rh_all  = rhead[13];                 // 1: score of all three blocks
    wire signed [7:0] rh_lag = {rhead[12], rhead[12:6]};
    wire [5:0]     rh_ci   = rhead[5:0];                // carrier in the pass: {pair, odd}

    // ================================================================ tracker
    // 64 carriers x 16 words of 36 bits (one 1,024 x 36 simple-dual-port BSRAM):
    //   0 {p_pend, s_pend, prev}   1 p_s0   2 s_s0   3 p_sm1   4 p_sp1   5 s_sm1   6 s_sp1
    //   7 p_lag   8 this lag's last-two-blocks score   9 s_lag
    // "prev" is the carrier's sync score at the previous lag; a pending flag means the best
    // lag was set at the previous lag and its "+1" score is still to come. Read data is valid
    // two clocks after the state that sets t_raddr.
    reg  [35:0] tmem [0:1023];
    reg  [9:0]  t_raddr, t_waddr;
    reg  [35:0] t_rdata, t_wdata;
    reg         t_we;
    always @(posedge clk) begin
        if (t_we) tmem[t_waddr] <= t_wdata;
        t_rdata <= tmem[t_raddr];
    end

    // Tracker states: idle, read steps T_R1 .. T_R5 (words 8, 0, 1, 2 of the carrier), decide (T_DEC), write steps (T_W), and the
    // read-out of a carrier's words (T_OUT).
    localparam [3:0] T_IDLE = 4'd0, T_R1 = 4'd1, T_R2 = 4'd2, T_R3 = 4'd3, T_R4 = 4'd4,
                     T_DEC = 4'd5, T_W = 4'd6, T_OUT = 4'd7, T_R5 = 4'd8;
    reg  [3:0]  tst;
    reg         t_idle;         // tst == T_IDLE, a register: the load enable of the result registers
    // ta: the score that just came out of the divider (the all-three-blocks one, or the last-two stored in word 8), tb the other,
    // tprev the previous lag's sync score, tps0 and tss0 the best primary and secondary score so far, tsv this lag's sync score.
    // tpp and tsp are the pending flags of the two bests, tci the carrier in the pass and tl the lag.
    reg  [31:0] ta, tb, tprev, tps0, tss0, tsv;
    reg         tpp, tsp;
    reg  [5:0]  tci;
    reg  signed [7:0] tl;
    reg         tl_first /* synthesis syn_maxfan = 10000 */;   // tl == -63
    reg         tl_m10, tl_win;                             // tl == -10, tl in -10 .. 10
    reg         tgt /* synthesis syn_maxfan = 10000 */;        // ta > tb
    reg  [9:0]  wmask;          // words to write (bit n = word n)
    reg  [3:0]  wi /* synthesis syn_maxfan = 10000 */;         // word of the write step
    reg         ro_req;         // the readout wants the read port
    reg  [9:0]  ro_raddr;

    // c_newp and c_news: this lag's sync score is a new best (primary: inside |L| <= 10, first maximum wins, so strictly greater, or
    // the first lag of the window; secondary: any lag).  c_resp and c_ress: no new best but the best was set at the previous lag,
    // so this lag's score is its "+1" score.
    wire        c_newp = tl_win && (tl_m10 || (tsv > tps0));
    wire        c_news = tl_first || (tsv > tss0);
    wire        c_resp = !c_newp && tpp;
    wire        c_ress = !c_news && tsp;

    // The result registers follow the FIFO head whenever the tracker is idle; the head only
    // moves on a pop, which the idle state itself starts.
    always @(posedge clk) begin
        if (t_idle) begin
            tci      <= rh_ci;
            ta       <= rh_q;
            tl       <= rh_lag;
            tl_first <= (rh_lag == -8'sd63);
            tl_m10   <= (rh_lag == -8'sd10);
            tl_win   <= (rh_lag >= -8'sd10) && (rh_lag <= 8'sd10);
        end
    end

    // Tracker state machine.  A "last two blocks" result is stored (word 8).  An "all three blocks" result starts the decision:
    // the sync score is the larger of the two, compared with the best so far, and the words that change are written back
    // (the write mask in T_DEC).
    always @(posedge clk) begin
        t_we <= 1'b0;
        rpop <= 1'b0;
        if (rst) begin
            tst    <= T_IDLE;
            t_idle <= 1'b1;
            wmask  <= 10'd0;
        end else begin
            case (tst)
                T_IDLE: begin
                    if (ro_req && fifo_cnt == 3'd0 && !rpop) begin
                        tst     <= T_OUT;
                        t_idle  <= 1'b0;
                        t_raddr <= ro_raddr;
                    end else if (fifo_cnt != 3'd0 && !rpop) begin
                        rpop <= 1'b1;
                        if (!rh_all) begin
                            t_we    <= 1'b1;
                            t_waddr <= {rh_ci, 4'd8};
                            t_wdata <= {4'd0, rh_q};
                        end else begin
                            t_raddr <= {rh_ci, 4'd8};
                            tst     <= T_R1;
                            t_idle  <= 1'b0;
                        end
                    end
                end
                T_R1: begin t_raddr <= {tci, 4'd0}; tst <= T_R2; end
                T_R2: begin t_raddr <= {tci, 4'd1}; tb <= t_rdata[31:0]; tst <= T_R3; end
                T_R3: begin
                    t_raddr <= {tci, 4'd2};
                    // at the first lag the previous score is at(-64) = 0 and nothing is pending
                    tprev <= tl_first ? 32'd0 : t_rdata[31:0];
                    tpp   <= tl_first ? 1'b0  : t_rdata[33];
                    tsp   <= tl_first ? 1'b0  : t_rdata[32];
                    tgt   <= (ta > tb);
                    tst   <= T_R4;
                end
                T_R4: begin tps0 <= t_rdata[31:0]; tsv <= tgt ? ta : tb; tst <= T_R5; end
                T_R5: begin tss0 <= t_rdata[31:0]; tst <= T_DEC; end
                T_DEC: begin
                    // decide and write word 0
                    t_we    <= 1'b1;
                    t_waddr <= {tci, 4'd0};
                    t_wdata <= {2'd0, c_newp, c_news, tsv};
                    wmask   <= {c_news, 1'b0, c_newp, c_ress, c_news, c_resp, c_newp, c_news, c_newp, 1'b0};
                    wi      <= 4'd1;
                    tst     <= T_W;
                end
                T_W: begin
                    // words 1 .. 7 and 9 in turn, each written if its bit is set
                    t_we    <= wmask[wi];
                    t_waddr <= {tci, wi};
                    case (wi)
                        4'd3, 4'd5: t_wdata <= {4'd0, tprev};
                        4'd7, 4'd9: t_wdata <= {28'd0, tl};
                        default:    t_wdata <= {4'd0, tsv};
                    endcase
                    wi <= (wi == 4'd7) ? 4'd9 : wi + 4'd1;
                    if (wi == 4'd9) begin
                        tst    <= T_IDLE;
                        t_idle <= 1'b1;
                    end
                end
                T_OUT: begin
                    // the readout (main sequencer S_OUT .. S_WR) drives the read address
                    t_raddr <= ro_raddr;
                    if (!ro_req) begin
                        tst    <= T_IDLE;
                        t_idle <= 1'b1;
                    end
                end
                default: begin
                    tst    <= T_IDLE;
                    t_idle <= 1'b1;
                end
            endcase
        end
    end
    wire tracker_idle = (tst == T_IDLE) && (fifo_cnt == 3'd0) && !rpop;

    // ================================================================ main sequencer
    // Main sequencer registers.  clocks counts the search's length.  The read-out of one carrier's record: oci the carrier, ork
    // the read step, o_* the words captured, wbeat the beat of the write.
    reg [31:0] clocks;
    // readout of one carrier's record
    reg [5:0]  oci;             // carrier in the pass, 0 .. 63
    reg [3:0]  ork;             // read step
    reg [7:0]  o_lp, o_ls;
    reg [31:0] o_psm1, o_ps0, o_psp1, o_ssm1, o_ss0, o_ssp1;
    reg        o_ppend, o_spend;
    reg [1:0]  wbeat /* synthesis syn_maxfan = 10000 */;
    reg [9:0]  ocar, orel;

    // The four beats of a record, two 32-bit words each (low half first): beat 0 the lag word (primary lag | secondary lag << 8)
    // and the primary score at L-1; beat 1 the primary scores at L and L+1 (0 if still pending); beat 2 the secondary scores at L-1
    // and L; beat 3 the secondary score at L+1 (0 if still pending) and 0.
    always @* begin
        case (wbeat)
            2'd0:    wr_wdata = {o_psm1, 16'd0, o_ls, o_lp};
            2'd1:    wr_wdata = {(o_ppend ? 32'd0 : o_psp1), o_ps0};
            2'd2:    wr_wdata = {o_ss0, o_ssm1};
            default: wr_wdata = {32'd0, (o_spend ? 32'd0 : o_ssp1)};
        endcase
    end

    // The pass has drained when the stream pipeline, the divider and the tracker are all empty.
    wire pipeline_empty = !in_v && (pv == 6'd0);
    wire divider_empty  = (qcnt == 6'd0) && !jv && !dv_take && !tk_fh && (dv_inflight == 4'd0) && !dv_out;
    // Registered: once a pass has drained nothing starts again (no row is streamed in S_DRAIN,
    // and each stage hands over without a clock in which neither side shows the item), so a
    // clock-old "all empty" is still true.
    reg  drain_ok, qz_q;
    always @(posedge clk) begin
        drain_ok <= pipeline_empty && divider_empty && tracker_idle && (st == S_DRAIN) && !rst;
        qz_q     <= (qcnt == 6'd0) && !push4o;
    end
    // readout capture strobes: step k of S_OUT2 (ork counts 0 .. 10 without a stop)
    reg [10:0] ostb;
    always @(posedge clk) ostb <= rst ? 11'd0 : {ostb[9:0], (st == S_OUT) && (tst == T_OUT)};
    always @(posedge clk) begin
        if (ostb[2])  o_lp   <= t_rdata[7:0];
        if (ostb[3])  o_ls   <= t_rdata[7:0];
        if (ostb[4])  begin o_ppend <= t_rdata[33]; o_spend <= t_rdata[32]; end
        if (ostb[5])  o_psm1 <= t_rdata[31:0];
        if (ostb[6])  o_ps0  <= t_rdata[31:0];
        if (ostb[7])  o_psp1 <= t_rdata[31:0];
        if (ostb[8])  o_ssm1 <= t_rdata[31:0];
        if (ostb[9])  o_ss0  <= t_rdata[31:0];
        if (ostb[10]) o_ssp1 <= t_rdata[31:0];
    end

    // pos is the Costas symbol position of the row, m_calc its frame number 13 + lag + 4 pos, and m_in says that frame is inside the slot.
    reg [6:0]        pos;
    reg signed [9:0] m_calc;
    wire m_in = (m_calc >= 10'sd0) && (m_calc < $signed({1'b0, rows}));
    // Loads of wide registers behind registered strobes: the configuration (s_cfg4), and the row's registers (s_row2b).
    always @(posedge clk) begin
        if (s_cfg4) begin
            spec_base <= cur_alt ? alt_spec_base : cfg_sel[CW-1 -: ADDR_WIDTH];
            rec_b     <= cur_alt ? alt_rec_base  : cfg_sel[CW-ADDR_WIDTH-1 -: ADDR_WIDTH];
            ia        <= cfg_sel[19:10];
            ib        <= cfg_sel[9:0];
        end
        if (s_row2b) begin
            row_first   <= (q == 5'd0);
            row_pushb   <= (q == 5'd13);
            row_pusha   <= (q == 5'd20);
            row_c       <= costas(qn);
            rowoff      <= {1'b0, costas(qn)} + 4'd10;
            zrow        <= !m_in;
            row_m       <= m_calc;
            row_in      <= m_in;
            rd_addr     <= row_base + {{(ADDR_WIDTH-18){1'b0}}, m_calc[8:0], 9'd0};
            rd_burstlen <= {2'd0, nw};
        end
    end
    // Main sequencer: it picks a request, loads its configuration, then for every pass of 64 carriers loops over the 127 lags
    // and the 21 Costas rows of each (position, frame number, request the burst or stream zeros), drains, reads out the records
    // and writes them to DDR3, and finally pulses `irq`.  A row that pushes a lag's sums waits for the job queue to empty first.

    always @(posedge clk) begin
        take <= 1'b0;
        take_alt <= 1'b0;
        irq  <= 1'b0;
        if (st != S_IDLE) clocks <= clocks + 32'd1;
        if (rst) begin
            cur_alt  <= 1'b0;
            irq_alt  <= 1'b0;
            st       <= S_IDLE;
            scan_ptr <= 3'd0;
            rd_req   <= 1'b0;
            wr_req   <= 1'b0;
            ro_req   <= 1'b0;
            clocks   <= 32'd0;
            wk       <= 6'd0;
        end else begin
            case (st)
                S_IDLE: begin
                    if (pick_found && !take) begin
                        cur_rx  <= pick_rx;
                        cur_alt <= 1'b0;
                        rows    <= pend_rows[pick_rx*9 +: 9];
                        take    <= 1'b1;
                        clocks  <= 32'd1;
                        st      <= S_CFG1;
                    end else if (pend_alt && !take_alt && !take) begin
                        // the residual's search: receiver alt_rx's band, the alt_* bases
                        cur_rx   <= alt_rx;
                        cur_alt  <= 1'b1;
                        rows     <= N_TIME;
                        take_alt <= 1'b1;
                        clocks   <= 32'd1;
                        st       <= S_CFG1;
                    end
                end
                S_CFG1: st <= S_CFG2;                  // cur_rx_sel, cfg_lo/hi, cfg_sel
                S_CFG2: st <= S_CFG3;
                S_CFG3: st <= S_CFG4;
                S_CFG4: begin
                    // spec_base, rec_b, ia, ib load in this clock (s_cfg4)
                    cs        <= {cfg_sel[19:11], 1'b0};
                    st        <= S_PASS0;
                end
                S_PASS0: begin
                    dcs <= ib - cs;
                    st  <= S_PASS;
                end
                S_PASS: begin
                    // carrier pairs in this pass: min(32, (ib - cs) / 2 + 1)
                    row_base  <= spec_base + {{(ADDR_WIDTH-9){1'b0}}, cs[9:1]};
                    npairs    <= (dcs >= 10'd62) ? 6'd32 : dcs[6:1] + 6'd1;
                    nw        <= (dcs >= 10'd62) ? 6'd38 : dcs[6:1] + 6'd7;
                    nwm1      <= (dcs >= 10'd62) ? 6'd37 : dcs[6:1] + 6'd6;
                    oci_last  <= (dcs >= 10'd62) ? 6'd63 : {dcs[5:1], 1'b1};
                    last_pass <= (dcs < 10'd64);
                    lag    <= -8'sd63;
                    q      <= 5'd0;
                    qb     <= 2'd0;
                    qn     <= 3'd0;
                    st     <= S_ROW;
                end
                S_ROW: begin
                    pos <= blkpos(qb) + {4'd0, qn};
                    st  <= S_ROW2;
                end
                S_ROW2: begin
                    m_calc <= 10'sd13 + lag + $signed({1'b0, pos, 2'b00});
                    st     <= S_ROW2B;
                end
                S_ROW2B: st <= S_ROW3;          // the row's registers load (s_row2b)
                S_ROW3: begin
                    // a row that pushes a lag's sums waits for the job queue to empty (the row
                    // before it pushes nothing, so the count only falls while this waits)
                    wk <= 6'd0;
                    if (!(row_pushb || row_pusha) || qz_q) begin
                        if (row_in) begin
                            rd_req <= 1'b1;
                            st     <= S_REQ;
                        end else begin
                            st     <= S_ZERO;
                        end
                    end
                end
                S_REQ: begin
                    if (rd_gnt) begin
                        rd_req <= 1'b0;
                        st     <= S_STREAM;
                    end
                end
                S_STREAM: begin
                    if (rd_rvalid) wk <= wk + 6'd1;
                    if (rd_done) st <= S_NEXT;
                end
                S_ZERO: begin
                    wk <= wk + 6'd1;
                    if (wk == nwm1) st <= S_NEXT;
                end
                S_NEXT: begin
                    wk <= 6'd0;
                    if (q == 5'd20) begin
                        q  <= 5'd0; qb <= 2'd0; qn <= 3'd0;
                        if (lag == 8'sd63) begin
                            st <= S_DRAIN;
                        end else begin
                            lag <= lag + 8'sd1;
                            st  <= S_ROW;
                        end
                    end else begin
                        q <= q + 5'd1;
                        if (qn == 3'd6) begin
                            qn <= 3'd0;
                            qb <= qb + 2'd1;
                        end else begin
                            qn <= qn + 3'd1;
                        end
                        st <= S_ROW;
                    end
                end
                S_DRAIN: begin
                    if (drain_ok) begin
                        oci    <= 6'd0;
                        ro_req <= 1'b1;
                        st     <= S_OUT;
                    end
                end
                S_OUT: begin
                    ocar <= cs + {4'd0, oci};
                    orel <= cs + {4'd0, oci} - ia;
                    ork  <= 4'd0;
                    if (tst == T_OUT) st <= S_OUT2;
                end
                S_OUT2: begin
                    // ro_raddr follows ork; its data arrives two steps later
                    // the record's words are captured by the ostb strobes
                    ork <= ork + 4'd1;
                    if (ork == 4'd10) begin
                        if ((ocar >= ia) && (ocar <= ib)) begin
                            wr_addr <= rec_b + {20'd0, orel, 2'b00};
                            wr_req  <= 1'b1;
                        end
                        wbeat <= 2'd0;
                        st    <= S_WR;
                    end
                end
                S_WR: begin
                    if (wr_gnt) wbeat <= wbeat + 2'd1;
                    if (!wr_req || wr_done) begin
                        wr_req <= 1'b0;
                        if (oci == oci_last) begin
                            ro_req <= 1'b0;
                            if (last_pass) begin
                                st <= S_DONE;
                            end else begin
                                cs <= cs + 10'd64;
                                st <= S_PASS0;
                            end
                        end else begin
                            oci <= oci + 6'd1;
                            st  <= S_OUT;
                        end
                    end
                end
                S_DONE: begin
                    // wait for the tracker to hand the read port back
                    if (tst == T_IDLE) begin
                        irq        <= 1'b1;
                        irq_rx     <= cur_rx;
                        irq_rows   <= rows;
                        irq_alt    <= cur_alt;
                        run_clocks <= clocks;
                        if (!cur_alt) scan_ptr <= (cur_rx == NUM_RX - 1) ? 3'd0 : cur_rx + 3'd1;
                        st         <= S_DONE2;
                    end
                end
                S_DONE2: st <= S_DONE3;         // the pick catches up with pend and scan_ptr
                S_DONE3: st <= S_IDLE;
                default: st <= S_IDLE;
            endcase
        end
    end

    // readout read addresses by step: 7 (p_lag), 9 (s_lag), 0, 3, 1, 4, 5, 2, 6
    always @* begin
        case (ork)
            4'd0:    ro_raddr = {oci, 4'd7};
            4'd1:    ro_raddr = {oci, 4'd9};
            4'd2:    ro_raddr = {oci, 4'd0};
            4'd3:    ro_raddr = {oci, 4'd3};
            4'd4:    ro_raddr = {oci, 4'd1};
            4'd5:    ro_raddr = {oci, 4'd4};
            4'd6:    ro_raddr = {oci, 4'd5};
            4'd7:    ro_raddr = {oci, 4'd2};
            default: ro_raddr = {oci, 4'd6};
        endcase
    end

endmodule
