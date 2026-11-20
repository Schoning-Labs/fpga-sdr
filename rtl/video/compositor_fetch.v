// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// compositor_fetch: the DDR3 side of the screen compositor. It reads the picture data of the next screen line out of DDR3
// memory into on-chip line buffers, a line ahead of the time the pixel side needs them.
//
// WHERE IT SITS
// compositor.v instantiates it next to the register file and the pixel pipeline (compositor_pix.v). It runs in clk_dsp
// (120 MHz). It reads the description of the picture (`snap`, laid out in compositor_cfg.vh) and the number of the line
// that the monitor is currently drawing (`cy_gray`, from the pixel clock side), and it talks to the video tier of the
// DDR3 read arbiter (rtl/ddr3/ddr3_read_arbiter.v) to fetch data, which goes into the line buffers (block RAM, defined in
// compositor.v) through the write ports `sl_*` and `wf*_*`. Its only message back to the pixel side is `done_gray`, the
// number of the last line it has completely fetched.
//
// WHY IT EXISTS
// The picture is made of up to three layers: the GUI framebuffer that the firmware's Slint renderer draws (RGB565, 2 bytes
// per pixel, 1,920 x 1080), and the waterfall lines of up to two waterfall windows (1 byte per pixel, a color index). All of
// them live in DDR3, which has a long and variable delay and cannot deliver a pixel every pixel clock for a whole frame
// directly. A monitor needs its pixels at a fixed pace, so each line is first fetched in bursts into a small on-chip
// memory, and the pixel side then reads it out at the pixel rate with a fixed latency.
//
// HOW IT WORKS
//   1. The pixel side shows line n. This module's target line is n + 1 (`tgt`), taken from the gray coded line counter. A
//      gray code is a way of counting in which only one bit changes from one value to the next, which makes it safe to pass
//      a counter between two unrelated clocks through plain flip-flops: a value caught during a change is either the old or
//      the new number, never something in between.
//   2. When the target changes, a short pipeline (PREP_CYC = 8 clocks) computes the start addresses of up to three jobs for
//      that line: job 0 is the GUI framebuffer line (W / 4 = 480 words of 64 bits, four 16-bit pixels each), job 1 the line
//      of waterfall window 0 and job 2 the line of waterfall window 1 (only the words that the window shows, at most 240,
//      one byte per pixel, taken from the window's own ring and scroll line, see rtl/video/waterfall_writer.v). The
//      address of a framebuffer line is base + line x stride. The address of a ring line is the ring's base plus
//      (scroll line - row of the window) x 240 words plus the first word, where 240 = 256 - 16 is done as a shift and a
//      subtraction instead of a multiplier.
//   3. Each job is cut into bursts of up to BURST (160) words. A burst is requested (`rd_req`, with the address and length)
//      and as soon as it is granted the next one is requested, so the DDR3 lane is never idle between the bursts of a line.
//      Long bursts matter: with bursts of 8 words the fixed cost of each burst would leave the video short of data.
//   4. While a burst is requested its description (which buffer it goes to, at which word, how long) is put into a small
//      queue of 4. The data sink takes the words as they come back (`rd_rvalid`) and writes each into the right buffer
//      at the right word, following the head of the queue.
//   5. After the last burst the module waits until every word has been written, and only then writes the line number into
//      `done_gray`. The pixel side compares that number with the line it is starting; if they differ, the line was late and
//      it is counted as an underrun.
//
// TIME LIMITS: the module never waits for the lane without a limit. A burst that is not granted within GNT_TO clocks, or
// data that does not arrive within DRN_TO clocks, ends the line: `lane_err` pulses once, nothing is marked complete, and
// the pixel side sees an underrun. A new target line also cancels the line in progress. The line time at 1080p30 is 2,200
// pixel clocks of 74.17 MHz = 29.66 us = 3,559 clocks of clk_dsp, and a line needs at most 3 + 4 = 7 bursts (a framebuffer
// line in 3, a 240-word waterfall line in 2 each), so there is much room; the limits are 3,000 clocks = 25 us.
//
// LINE BUFFER LAYOUT (words of 64 bits): the GUI buffer holds 1,024 words = 2 lines x 512 (the line parity in bit 9, the
// word in bits 8:0). Each waterfall buffer holds 512 words = 2 lines x 256 (the parity in bit 8, the word in bits 7:0).
// Parity (the lowest bit of the line number) means that while line n is read out from one half, line n + 1 is written
// into the other.

`timescale 1ns / 1ps
`include "rtl/video/compositor_cfg.vh"

module compositor_fetch #(
    parameter integer W      = 1920,  // visible pixels per line (framebuffer words per line = W / 4)
    parameter integer H      = 1080,  // visible lines per frame; only lines below H are fetched
    parameter integer FH     = 1125,  // total lines per frame including the blanking (1125 for 1080p), the wrap point of the line counter
    parameter integer BURST  = 160,  // words per burst, the longest burst requested (at most 255, the burst length field is 8 bits)
    parameter integer GNT_TO = 3000,  // clocks to wait for a burst grant before giving up on the line
    parameter integer DRN_TO = 3000  // clocks to wait for data to arrive before giving up on the line
) (
    input  wire                 clk,  // clk_dsp, 120 MHz
    input  wire                 rst,  // synchronous reset, high = reset
    input  wire [`CF_W-1:0]     snap,  // picture description of this frame (compositor_cfg.vh), steady during the frame
    input  wire [10:0]          cy_gray,        // the pixel side's line counter cy as a gray code, already through two synchronizing registers in clk_dsp
    output reg  [10:0]          done_gray,      // gray code of the last line completely fetched, read by the pixel side through two synchronizing registers
    // video tier of the DDR3 read arbiter (the convention of rtl/ddr3/ddr3_read_arbiter.v: request held until granted)
    output reg                  rd_req,  // high from the request of a burst until it is granted
    output reg  [31:0]          rd_addr,  // DDR3 address of the burst's first word, in 64-bit lane words, held while requested
    output reg  [7:0]           rd_burstlen,  // number of words in the burst, 1 to BURST
    input  wire                 rd_gnt,  // one-clock pulse: the burst is accepted, its words follow
    input  wire                 rd_rvalid,  // high for each clock a data word is on `rd_rdata`
    input  wire [63:0]          rd_rdata,  // the data word, 64 bits
    // line buffer write ports (the data bus is shared by all three buffers, only one write enable is high at a time)
    output reg  [63:0]          wdat,  // the word to write, 64 bits
    output reg                  sl_we,  // write enable of the GUI line buffer
    output reg  [9:0]           sl_wa,  // GUI line buffer word address: {line parity, word 8:0}
    output reg                  wf0_we,  // write enable of waterfall window 0's line buffer
    output reg                  wf1_we,  // write enable of waterfall window 1's line buffer
    output reg  [8:0]           wf_wa,  // waterfall line buffer word address: {line parity, word 7:0}
    output reg                  lane_err        // one-clock pulse
) /* synthesis syn_maxfan = 10000 */;
// WPL: 64-bit words in a GUI framebuffer line (4 pixels of 16 bits per word): 1,920 / 4 = 480.
    localparam integer WPL = W / 4;             // Slint words per line

    // ------------------------------------------------------------------------ target line
    // g2b converts a gray code back to the plain number: the top bit stays, and every lower bit is the XOR of the next
    // higher result bit with the gray bit.
    function [10:0] g2b(input [10:0] g);
        integer j;
        begin
            g2b[10] = g[10];
            for (j = 9; j >= 0; j = j - 1) g2b[j] = g2b[j+1] ^ g[j];
        end
    endfunction

    // cyb: the line the pixel side is on, as a plain number. tgt: the line to fetch, one more (and 0 after the last line of
    // the frame, so that the fetch for line 0 of the next frame is made during the last blanking line).
    reg [10:0] cyb = 11'd0, tgt = 11'd0;
    always @(posedge clk) begin
        cyb <= g2b(cy_gray);
        tgt <= (cyb == FH - 1) ? 11'd0 : cyb + 11'd1;
    end

    // ------------------------------------------------------------------------ snapshot fields
    // en: the compositor is enabled (otherwise no GUI line is fetched). fbw: framebuffer base in 64-bit words. fbsw: line
    // stride in words (480 for 3,840 bytes).
    wire        en      = snap[`CF_EN_L];
    wire [28:0] fbw     = snap[`CF_FBW_L +: `CF_FBW_W];
    wire [19:0] fbsw    = snap[`CF_FBSW_L +: `CF_FBSW_W];

    // ------------------------------------------------------------------------ job preparation
    // A free-running pipeline that computes the address of the GUI line for the target `cur_t` (held steady while a line is
    // being fetched): the multiplier line x stride is split over two clocks, mul1 and mul2, and added to the base. The
    // results are valid PREP_CYC clocks after `cur_t` changes.
    reg [10:0] cur_t = 11'd0;
    reg [10:0] t_a = 11'd0, t_b = 11'd0;
    reg [19:0] fbsw_r = 20'd0;
    reg [30:0] mul1 = 31'd0, mul2 = 31'd0;
    reg [31:0] slint_addr = 32'd0;
    always @(posedge clk) begin
        t_a     <= cur_t;
        fbsw_r  <= fbsw;
        mul1    <= t_a * fbsw_r;
        mul2    <= mul1;
        slint_addr <= {3'b000, fbw} + {1'b0, mul2};
    end

    // The same for the two waterfall windows, generated once for each. `wv` says the job exists for this line, `wfa` is the
    // lane word address of its first word, `wfn` the number of words, `wfs` the first word number within the ring line.
    wire [1:0]  wv;                             // waterfall job j valid for cur_t
    wire [63:0] wfa;                            // lane word address of the job's first word
    wire [17:0] wfn;                            // number of words
    wire [15:0] wfs;                            // first word number
    genvar j;
    generate
        for (j = 0; j < 2; j = j + 1) begin : wfj
            wire [10:0] wy  = snap[`CF_WY_L  + 11*j +: 11];
            wire [10:0] wye = snap[`CF_WYE_L + 11*j +: 11];
            wire        ok  = snap[`CF_WEN_L + j] & snap[`CF_WF_L + j];
            wire [7:0]  fw0 = snap[`CF_WFW0_L + 8*j +: 8];
            wire [8:0]  fn  = snap[`CF_WFN_L + 9*j +: 9];
            wire [31:0] wfring = snap[`CF_WFRING_L + 32*j +: 32];      // this window's ring
            wire [10:0] wltop  = snap[`CF_WLTOP_L + 11*j +: 11];       // and its scroll line
            reg  [10:0] r1 = 11'd0, l2 = 11'd0;
            reg  [21:0] lx3 = 22'd0;
            reg  [31:0] a4 = 32'd0;
            reg         ge1 = 1'b0, lt1 = 1'b0, v2 = 1'b0, v3 = 1'b0, v4 = 1'b0;
            reg  [7:0]  fw1 = 8'd0, fw2 = 8'd0, fw3 = 8'd0, fw4 = 8'd0;
            reg  [8:0]  n1 = 9'd0, n2 = 9'd0, n3 = 9'd0, n4 = 9'd0;
            always @(posedge clk) begin
            // Stage 1: row of the line inside the window (cur_t - top edge), and whether the line is inside the window at
            // all (>= top edge and < bottom edge).
                r1  <= cur_t - wy;
                ge1 <= (cur_t >= wy);
                lt1 <= (cur_t <  wye);
                fw1 <= fw0;  n1 <= fn;
                // stage 2: ring line (newest at the top row)
                l2  <= wltop - r1;
                v2  <= ok & ge1 & lt1;
                fw2 <= fw1;  n2 <= n1;
                // stage 3: ring line x 240 words = ring line x 256 - ring line x 16
                lx3 <= {l2, 8'd0} - {4'd0, l2, 4'd0};
                v3  <= v2;
                fw3 <= fw2;  n3 <= n2;
                // stage 4: lane word address of the first word
                a4  <= wfring + {10'd0, lx3} + {24'd0, fw3};
                v4  <= v3;
                fw4 <= fw3;  n4 <= n3;
            end
            assign wv[j]            = v4;
            assign wfa[32*j +: 32]  = a4;
            assign wfn[9*j +: 9]    = n4;
            assign wfs[8*j +: 8]    = fw4;
        end
    endgenerate

    // ------------------------------------------------------------------------ descriptor queue and sink
    // The queue holds the descriptors of bursts that have been granted and whose data has not been written yet: for each
    // the destination buffer (0 = GUI, 1 = waterfall 0, 2 = waterfall 1), the first word number in that buffer (10 bits)
    // and the length. qwp and qrp are the write and read pointers, qcnt the number of entries; `inflight` counts bursts
    // granted and not completely written, which tells the state machine when it may finish.
    reg [47:0] qd = 48'd0;                      // 4 x {dest[1:0], wa[9:0]}
    reg [31:0] ql = 32'd0;                      // 4 x len[7:0]
    reg [1:0]  qwp = 2'd0, qrp = 2'd0;
    reg [2:0]  qcnt = 3'd0;
    reg [2:0]  inflight = 3'd0;

// the descriptor of the burst being requested: destination and first buffer word (the address and length are rd_addr and
// rd_burstlen)
    reg [1:0]  dsc_dest = 2'd0;
    reg [9:0]  dsc_wa = 10'd0;                  // wa of the burst's first word
    // rd_addr / rd_burstlen are the other half of the descriptor

    // The sink: rv_q and rdat_q are the data registered once. sk_* describe the burst being written (active only for bursts
    // longer than one word: the first word of a burst is written straight from the queue head, the rest from sk_*).
    reg        rv_q = 1'b0;
    reg [63:0] rdat_q = 64'd0;
    reg        sk_active = 1'b0;
    reg [9:0]  sk_wa = 10'd0;
    reg [7:0]  sk_left = 8'd0;
    reg [1:0]  sk_dest = 2'd0;
    wire [11:0] qh_d = qd[qrp*12 +: 12];
    wire [7:0]  qh_l = ql[qrp*8 +: 8];
    wire        push = rd_gnt;
    reg         sink_last = 1'b0, sink_err = 1'b0;
    reg         force_clear = 1'b0;

    wire [9:0] cur_wa   = sk_active ? sk_wa   : qh_d[9:0];
    wire [1:0] cur_dest = sk_active ? sk_dest : qh_d[11:10];
    wire [7:0] cur_left = sk_active ? sk_left : qh_l;
    wire       have     = sk_active | (qcnt != 3'd0);
    wire       pop_now  = rv_q & ~sk_active & (qcnt != 3'd0);

    // Sink and queue: on a grant, the descriptor is pushed; on every data word, it is written to the buffer the descriptor
    // names and the word number counted up; a word that arrives with no descriptor is dropped.
    always @(posedge clk) begin
        rv_q   <= rd_rvalid;
        rdat_q <= rd_rdata;
        sl_we  <= 1'b0;
        wf0_we <= 1'b0;
        wf1_we <= 1'b0;
        sink_last <= 1'b0;
        sink_err  <= 1'b0;
        if (push) begin
            qd[qwp*12 +: 12] <= {dsc_dest, dsc_wa};
            ql[qwp*8 +: 8]   <= rd_burstlen;
            qwp <= qwp + 2'd1;
        end
        if (rv_q) begin
            if (have) begin
                wdat <= rdat_q;
                sl_wa <= cur_wa;
                wf_wa <= cur_wa[8:0];
                sl_we  <= (cur_dest == 2'd0);
                wf0_we <= (cur_dest == 2'd1);
                wf1_we <= (cur_dest == 2'd2);
                if (!sk_active) begin
                    qrp <= qrp + 2'd1;
                    if (qh_l > 8'd1) begin
                        sk_active <= 1'b1;
                        sk_wa     <= qh_d[9:0] + 10'd1;
                        sk_dest   <= qh_d[11:10];
                        sk_left   <= qh_l - 8'd1;
                    end else sink_last <= 1'b1;
                end else begin
                    sk_wa   <= sk_wa + 10'd1;
                    sk_left <= sk_left - 8'd1;
                    if (sk_left == 8'd1) begin sk_active <= 1'b0; sink_last <= 1'b1; end
                end
            end else begin
                sink_err <= 1'b1;               // beat with no descriptor: dropped
            end
        end
        qcnt     <= qcnt + (push ? 3'd1 : 3'd0) - (pop_now ? 3'd1 : 3'd0);
        inflight <= inflight + (push ? 3'd1 : 3'd0) - (sink_last ? 3'd1 : 3'd0);
        if (force_clear) begin
            qwp <= 2'd0; qrp <= 2'd0; qcnt <= 3'd0; inflight <= 3'd0; sk_active <= 1'b0;
        end
    end

    // ------------------------------------------------------------------------ line state machine
    // States: IDLE (wait for a new target line), PREP (wait for the address pipeline), JOB0 and JOB1 (select job jidx and
    // check that it exists; jidx runs 0, 1, 2 and then 3 means done), LD (load the job's address, length and destination),
    // REQ (request a burst, wait for the grant), UPD (step the address and the remaining length past the burst), DRAIN (wait
    // for all data to arrive) and ABORT (give up this line). The wide registers (rd_addr, left, dsc_*) are loaded under
    // kept copies of a strobe (ldv: load the job, upv: step to the next burst), each copy driving about 8 enables, and the
    // job to load is selected by free-running registers: no enable signal has more than about 12 loads.
    localparam [3:0] S_IDLE = 4'd0, S_PREP = 4'd1, S_JOB0 = 4'd2, S_JOB1 = 4'd3, S_LD = 4'd4,
                     S_REQ = 4'd5, S_UPD = 4'd6, S_DRAIN = 4'd7, S_ABORT = 4'd8;
    localparam integer PREP_CYC = 8;
    reg [3:0]  st = S_IDLE;
    reg        started = 1'b0;
    reg [3:0]  pcnt = 4'd0;
    reg [1:0]  jidx = 2'd0;
    reg [9:0]  left = 10'd0;
    reg [11:0] to_cnt = 12'd0;
    reg        aborted = 1'b0;
    // new_tgt: the target differs from the line in progress. `nt` is the same signal registered; tgt_act: the target is a
    // displayed line (below H), as opposed to a blanking line, for which nothing is fetched.
    wire       new_tgt = (tgt != cur_t);
    reg        nt = 1'b0;                                // the same, registered (cur_t changes only in S_IDLE; S_PREP
    reg        tgt_act = 1'b0;                           // ignores it for its first clocks)
    always @(posedge clk) begin nt <= new_tgt; tgt_act <= (tgt < H); end
// length of the next burst: what is left of the job, up to BURST
    wire [9:0] blen_w = (left > BURST) ? BURST : left;

    // The job selected by jidx, in free-running registers: valid, DDR3 address, words to fetch, destination buffer and first
    // word number in that buffer. The word number is {line parity, 0} for the GUI line and {parity, first word} for waterfall.
    reg        jb_v = 1'b0;
    reg [31:0] jb_addr = 32'd0;
    reg [9:0]  jb_left = 10'd0, jb_wa = 10'd0;
    reg [1:0]  jb_dest = 2'd0;
    always @(posedge clk) begin
        case (jidx)
            2'd0:    begin jb_v <= en;    jb_addr <= slint_addr;  jb_left <= WPL;                jb_dest <= 2'd0; jb_wa <= {cur_t[0], 9'd0}; end
            2'd1:    begin jb_v <= wv[0]; jb_addr <= wfa[31:0];   jb_left <= {1'b0, wfn[8:0]};   jb_dest <= 2'd1; jb_wa <= {1'b0, cur_t[0], wfs[7:0]}; end
            default: begin jb_v <= wv[1]; jb_addr <= wfa[63:32];  jb_left <= {1'b0, wfn[17:9]};  jb_dest <= 2'd2; jb_wa <= {1'b0, cur_t[0], wfs[15:8]}; end
        endcase
    end

    // ldv and upv: kept copies of the load and the step strobes. addr_nx: the address after the current burst.
    reg [3:0] ldv /* synthesis syn_preserve = 1 */;
    reg [3:0] upv /* synthesis syn_preserve = 1 */;
    initial begin ldv = 4'd0; upv = 4'd0; end
    wire [31:0] addr_nx = rd_addr + {24'd0, rd_burstlen};
    // Load the job into the address, remaining length and descriptor registers, or step them past a burst just granted.
    always @(posedge clk) begin
        if (ldv[0]) rd_addr[7:0]   <= jb_addr[7:0];   else if (upv[0]) rd_addr[7:0]   <= addr_nx[7:0];
        if (ldv[1]) rd_addr[15:8]  <= jb_addr[15:8];  else if (upv[1]) rd_addr[15:8]  <= addr_nx[15:8];
        if (ldv[2]) rd_addr[23:16] <= jb_addr[23:16]; else if (upv[2]) rd_addr[23:16] <= addr_nx[23:16];
        if (ldv[3]) rd_addr[31:24] <= jb_addr[31:24]; else if (upv[3]) rd_addr[31:24] <= addr_nx[31:24];
        if (ldv[0]) left    <= jb_left;  else if (upv[0]) left   <= left - {2'd0, rd_burstlen};
        if (ldv[1]) dsc_wa  <= jb_wa;    else if (upv[1]) dsc_wa <= dsc_wa + {2'd0, rd_burstlen};
        if (ldv[1]) dsc_dest <= jb_dest;
    end

    // The state machine. `done_gray` is set only when all the data of the line has been written and the line was neither
    // abandoned nor replaced by a new target, so a partly fetched line is never reported as complete.
    always @(posedge clk) begin
        lane_err    <= 1'b0;
        force_clear <= 1'b0;
        ldv         <= 4'd0;
        upv         <= 4'd0;
        if (rst) begin
            st <= S_IDLE; rd_req <= 1'b0; done_gray <= 11'd0; started <= 1'b0; cur_t <= 11'd0;
        end else begin
            case (st)
                S_IDLE: begin
                    rd_req <= 1'b0;
                    if (nt || !started) begin
                        cur_t   <= tgt;
                        started <= 1'b1;
                        pcnt    <= 4'd0;
                        jidx    <= 2'd0;
                        aborted <= 1'b0;
                        st      <= tgt_act ? S_PREP : S_IDLE;
                    end
                end
                S_PREP: begin
                    pcnt <= pcnt + 4'd1;
                    if (pcnt >= 4'd2 && nt) st <= S_IDLE;           // cannot happen in practice; resync
                    else if (pcnt == PREP_CYC) st <= S_JOB0;
                end
                S_JOB0: begin                                       // jidx is stable: jb_* follow
                    st <= S_JOB1;
                    if (nt) begin st <= S_ABORT; aborted <= 1'b1; end
                end
                S_JOB1: begin
                    to_cnt <= 12'd0;
                    if (nt) begin st <= S_ABORT; aborted <= 1'b1; end
                    else if (jidx == 2'd3) st <= S_DRAIN;
                    else if (jb_v) begin ldv <= 4'hF; st <= S_LD; end
                    else begin jidx <= jidx + 2'd1; st <= S_JOB0; end
                end
                S_LD: st <= S_REQ;                                  // ldv is active in this clock
                S_REQ: begin
                    if (left == 10'd0) begin
                        rd_req <= 1'b0; jidx <= jidx + 2'd1; st <= S_JOB0;
                    end else begin
                        rd_req      <= 1'b1;
                        rd_burstlen <= blen_w[7:0];
                        to_cnt      <= to_cnt + 12'd1;
                        if (rd_gnt) begin
                            rd_req <= 1'b0;
                            upv    <= 4'hF;
                            st     <= S_UPD;
                        end else if (to_cnt >= GNT_TO) begin
                            rd_req <= 1'b0; lane_err <= 1'b1; aborted <= 1'b1; st <= S_ABORT;
                        end else if (nt) begin
                            rd_req <= 1'b0; aborted <= 1'b1; st <= S_ABORT;
                        end
                    end
                end
                S_UPD: begin                                        // upv is active in this clock
                    to_cnt <= 12'd0;
                    st     <= S_REQ;
                end
                S_ABORT: begin                                      // let a grant that is just arriving be seen
                    rd_req <= 1'b0;
                    to_cnt <= 12'd0;
                    st     <= S_DRAIN;
                end
                S_DRAIN: begin
                    to_cnt <= to_cnt + 12'd1;
                    if (!have && inflight == 3'd0 && !rv_q && to_cnt > 12'd4) begin
                        if (!aborted && !nt) begin
                            done_gray <= cur_t ^ {1'b0, cur_t[10:1]};
                        end
                        st <= S_IDLE;
                    end else if (to_cnt >= DRN_TO) begin
                        lane_err <= 1'b1; force_clear <= 1'b1; st <= S_IDLE;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
