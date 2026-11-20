// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ft8_cand: the candidate engine of the FT8 front end, which cuts one candidate signal out of the slot's audio and measures its
// symbols.
//
// Background
//   After the sync search (ft8_sync.v) the firmware picks the most promising candidates (frequency and start time of a probable FT8
//   signal; see ft8_frontend.v for the signal structure).  To decode one it needs, for each of the 79 symbols, the energy at each of
//   the 8 possible tones, the "soft symbols".  Getting them from the 12 ksps audio of a whole slot takes a lot of arithmetic, so it
//   is split in two passes that this engine does for up to two candidates at once:
//   pass 1 (`cmd_pass2` = 0): replay one receiver's slot (180,000 samples, from ring sample `slot_first_sample` of the capture ring at
//     `cap_ring_base`, 4 samples per lane word, as ft8_slot_capture.v writes it) once through both lanes.  Each lane has its own NCO
//     increment `lane_inc`, mixes its candidate down so that the middle of its 8 tones is at 0 Hz, filters, and decimates to 200
//     samples per second (12 ksps / 30 / 2): the candidate's whole signal, 50 Hz wide, in 3,200 complex samples ("baseband").  Each
//     lane writes its 3,200 baseband words {im, re} to `lane_bb_base`.
//   pass 2 (`cmd_pass2` = 1): the CPU has now found the exact time and frequency offset of the candidate on that baseband.  Each lane reads
//     its candidate's baseband back from `lane_bb_base` (words i0 .. i0 + 2,527 that exist, the rest count as zero), rotates it by the
//     fine frequency offset (increment `lane_inc`, start sample `lane_i0`), and for each of the 79 symbols takes a 32-point DFT, one
//     symbol being 160 ms = 32 baseband samples and the DFT bins being 200 / 32 = 6.25 Hz apart, which is the tone spacing.  It writes the
//     79 x 8 = 632 soft symbols {im, re} (symbol by symbol, 8 tones each) to `lane_sym_base`.
//   The engine is bit-exact with the Rust model (`baseband_fx` for pass 1, `symbols_fx` for pass 2).  The arithmetic of the lanes is in
//   ft8_cand_lane.v; docs/F7_CAND.md has the design, the timing and the tests.
//
// Commands
//   One command at a time, on plain ports (rtl/ft8/ft8_frontend.v wires them to its registers).  `cmd_start` begins it, `cmd_lanes`
//   enables lane 0 and/or lane 1 (at least one), `irq` pulses when every word is in DDR3, and `run_clocks` is the command's length in
//   clocks.  Only `cmd_pass2` and `cmd_lanes` are taken at `cmd_start`; the addresses, increments and start samples are read while
//   the command runs and have to hold until `irq` (the front end's registers do that, they are written only while idle).
//
// DDR3 traffic
//   Reads (one read-lane client, the lowest tier, through ft8_ddr3_mux.v) go through one 128-word FIFO in LUT RAM, in bursts of up to 64
//   words that are requested only when the FIFO has room for them.  The FIFO has to cover a video burst of about 280 clocks while the
//   lanes eat a lane word every 4 clocks (docs/F7_CAND.md section 3).
//   Pass 1 unpacks one sample per clock to both lanes: a word register is reloaded from the FIFO every fourth clock (the reload is decided
//   one clock ahead) and shifts 16 bits per clock in between.  One replay of 180,000 samples takes 1.5 ms at 120 MHz.
//   Pass 2 gives the lanes their words in the order symbol 0 lane 0, symbol 0 lane 1, symbol 1 lane 0, and so on, with zeros where the
//   start sample puts a word outside the baseband.  One word is handed over per `y_stb` pulse after the lane showed `y_rdy` (five clocks per
//   word; the lanes' DFT needs 256 clocks per symbol, so the feed costs 64 clocks per symbol with two lanes).
//   Writes (one write-lane client) come from a 16-word FIFO per lane, in bursts of 8.
//
// Timing rules
//   Built by docs/TANG_LESSONS.md sections 3 and 6: the FIFO's read side has no load enable decoded from its fill (the pass 1 reload flag
//   and the pass 2 pop are registers, and the pass 2 word register loads every clock), the request arithmetic is one add or compare per
//   clock, and the clear at the start of a command is a register of its own.

`timescale 1ns / 1ps
`include "rtl/ft8/ft8_mac.v"
`include "rtl/ft8/ft8_nco.v"
`include "rtl/ft8/ft8_cand_lane.v"

module ft8_cand #(
    // ADDR_WIDTH: DDR3 word address width.  RING_SAMPLES: samples in the capture ring (a power of two, as in ft8_slot_capture.v).
    // BURST: longest read burst in words.
    parameter integer ADDR_WIDTH   = 32,
    parameter integer RING_SAMPLES = 1 << 19,
    parameter integer BURST        = 64,
    // LANES: lanes built, 2 (both) or 1.  With 1 a command for two lanes runs the one lane twice, first with lane 0's increment, start
    // sample and buffers and then with lane 1's.  The registers and the words at their addresses are the same, and a two-lane command
    // takes twice the clocks.
    parameter integer LANES        = 2
) (
    // Clock (clk_dsp, 120 MHz) and synchronous reset (active high).
    input  wire        clk,
    input  wire        rst,

    // Command: cmd_start (one clock), the pass and the lanes to run; the ring base and first sample of the slot (pass 1); and per
    // lane (lane 0 in the low half, lane 1 in the high half) the NCO increment, the start sample, and the baseband and soft-symbol
    // buffer bases (lane word addresses).
    input  wire                    cmd_start,
    input  wire                    cmd_pass2,
    input  wire [1:0]              cmd_lanes,
    input  wire [ADDR_WIDTH-1:0]   cap_ring_base,
    input  wire [31:0]             slot_first_sample,
    input  wire [2*32-1:0]         lane_inc,
    input  wire [2*16-1:0]         lane_i0,
    input  wire [2*ADDR_WIDTH-1:0] lane_bb_base,
    input  wire [2*ADDR_WIDTH-1:0] lane_sym_base,

    // Status: busy while a command runs, irq one clock when it is complete, run_clocks its length.
    output wire        busy,
    output reg         irq,
    output reg  [31:0] run_clocks,

    // read-lane client (rtl/ddr3/ddr3_read_arbiter.v convention)
    output reg                     rd_req,
    output reg  [ADDR_WIDTH-1:0]   rd_addr,
    output reg  [7:0]              rd_burstlen,
    input  wire                    rd_gnt,
    input  wire                    rd_rvalid,
    input  wire [63:0]             rd_rdata,
    input  wire                    rd_done,

    // write-lane client (rtl/ddr3/ddr3_write_arbiter.v convention)
    output reg                     wr_req,
    output reg  [ADDR_WIDTH-1:0]   wr_addr,
    output wire [7:0]              wr_burstlen,
    output wire [63:0]             wr_wdata,
    output wire [7:0]              wr_wmask,
    input  wire                    wr_gnt,
    input  wire                    wr_done
) /* synthesis syn_maxfan = 10000, syn_srlstyle = "registers" */;

    // RING_WORDS: ring size in lane words.  RW: bits of a word offset.  FD: depth of the read FIFO.
    localparam integer RING_WORDS = RING_SAMPLES / 4;
    localparam integer RW = $clog2(RING_WORDS);
    localparam integer FD = 128;

    // A write burst is 8 words, written whole.
    assign wr_burstlen = 8'd8;
    assign wr_wmask    = 8'hFF;

    // ================================================================ command
    // run: a command is running.  p2: it is pass 2.  len_on: the lanes enabled.
    reg         run;
    reg         p2;
    reg  [1:0]  len_on;            // lanes enabled
    // held by the caller for the whole command (no copy: 330 registers on one load enable)
    wire [ADDR_WIDTH-1:0] cap_base = cap_ring_base;
    wire [31:0] first = slot_first_sample;
    // LANES = 1: `vsel` is the caller's lane whose values the one lane works with (it changes only
    // between the two runs of a command, in the clock before `l_start`); `vnext`: lane 1 is still to run
    localparam L2 = (LANES > 1);
    reg         vsel, vnext;
    wire        v1 = !L2 && vsel;
    wire [31:0] inc0 = v1 ? lane_inc[63:32] : lane_inc[31:0];
    wire [31:0] inc1 = lane_inc[63:32];
    wire signed [15:0] i0_0 = v1 ? lane_i0[31:16] : lane_i0[15:0];
    wire signed [15:0] i0_1 = lane_i0[31:16];
    wire [ADDR_WIDTH-1:0] bb0  = v1 ? lane_bb_base[2*ADDR_WIDTH-1:ADDR_WIDTH] : lane_bb_base[ADDR_WIDTH-1:0];
    wire [ADDR_WIDTH-1:0] bb1  = lane_bb_base[2*ADDR_WIDTH-1:ADDR_WIDTH];
    wire [ADDR_WIDTH-1:0] sym0 = v1 ? lane_sym_base[2*ADDR_WIDTH-1:ADDR_WIDTH] : lane_sym_base[ADDR_WIDTH-1:0];
    wire [ADDR_WIDTH-1:0] sym1 = lane_sym_base[2*ADDR_WIDTH-1:ADDR_WIDTH];
    // clocks: length of the running command.  l_start: one clock when the command starts (and, with one lane built, when the second
    // run starts).  clr: l_start or reset, used to clear the pointers and counters.
    reg  [31:0] clocks;
    reg         l_start;           // the command starts: one clock
    reg         clr;               // l_start or reset, for the pointers and counters
    assign busy = run;

    // ================================================================ read FIFO
    // The read FIFO, written through a register stage and read without a clock (the consumers register the word).  fwp and frp are
    // its pointers, fcnt the words stored and fres the words stored or requested and not yet arrived.
    reg  [63:0] fifo [0:FD-1] /* synthesis syn_ramstyle = "distributed_ram" */;
    reg  [6:0]  fwp, frp;
    reg  [7:0]  fcnt, fres;        // words stored; stored or requested and not yet arrived
    reg         rv_q;
    reg  [63:0] rd_q;
    wire        fpop;
    wire [63:0] fhead = fifo[frp];
    always @(posedge clk) begin
        rv_q <= rd_rvalid && !rst;
        rd_q <= rd_rdata;
        if (rv_q) fifo[fwp] <= rd_q;
    end

    // ================================================================ lanes
    // The lanes' inputs: x_valid and x_s are the pass 1 sample stream (the same for both lanes), gw is the pass 2 word (the FIFO head,
    // one clock late) with yz saying it is zero, y_stb and y_rdy the hand-over, and o_valid and o_word* the output words.
    reg         x_valid;
    reg  signed [15:0] x_s;
    reg  [63:0] gw;                // pass 2: the FIFO head, one clock late
    reg         yz;
    reg         cnz_q;             // the FIFO held a word a clock ago: gw is that word
    reg  [1:0]  y_stb;
    wire [1:0]  y_rdy;
    wire [1:0]  o_valid;
    wire [63:0] o_word0, o_word1;
    wire [1:0]  l_busy;

    ft8_cand_lane u_l0 (
        .clk(clk), .rst(rst), .start(l_start && len_on[0]), .pass2(p2), .inc(inc0), .i0(i0_0),
        .x_valid(x_valid), .x(x_s),
        .y_rdy(y_rdy[0]), .y_stb(y_stb[0]), .y(gw), .y_zero(yz),
        .out_valid(o_valid[0]), .out_word(o_word0), .busy(l_busy[0]));
    generate
        if (L2) begin : g_l1
            ft8_cand_lane u_l1 (
                .clk(clk), .rst(rst), .start(l_start && len_on[1]), .pass2(p2), .inc(inc1), .i0(i0_1),
                .x_valid(x_valid), .x(x_s),
                .y_rdy(y_rdy[1]), .y_stb(y_stb[1]), .y(gw), .y_zero(yz),
                .out_valid(o_valid[1]), .out_word(o_word1), .busy(l_busy[1]));
        end else begin : g_no_l1
            assign y_rdy[1]   = 1'b0;
            assign o_valid[1] = 1'b0;
            assign o_word1    = 64'd0;
            assign l_busy[1]  = 1'b0;
        end
    endgenerate

    // ================================================================ request side
    // pass 1: slot words; pass 2: per (symbol, lane) the baseband words that exist
    reg  [RW-1:0] r_off;           // pass 1: ring word offset of the next request
    reg  [15:0] r_left;            // pass 1: words not yet requested
    reg  [6:0]  r_s;               // pass 2: symbol of the next request
    reg         r_l;               // pass 2: lane of the next request
    reg         r_done;
    reg  [3:0]  rst_q;             // request state
    reg  [RW:0] r_towrap;
    reg  [15:0] r_rem, r_la;
    reg  signed [15:0] r_m0, r_m31, r_lo, r_hi;   // pass 2: word span of (r_s, r_l), clipped
    // Request states: calculate the burst (Q_CALC .. Q_CALC3), wait for room in the FIFO (Q_ROOM), request (Q_REQ), wait for the burst to
    // finish (Q_BURST), and in pass 2 go on to the next symbol and lane (Q_NEXT).
    localparam [3:0] Q_IDLE = 4'd0, Q_CALC = 4'd1, Q_CALC1 = 4'd2, Q_CALC2 = 4'd3, Q_CALC3 = 4'd4,
                     Q_ROOM = 4'd5, Q_REQ = 4'd6, Q_BURST = 4'd7, Q_NEXT = 4'd8;
    // the lane after r_l in the walk (only enabled lanes)
    wire        r_lane_last = r_l || !len_on[1];
    wire        r_grant = (rst_q == Q_REQ) && rd_gnt;

    // Request sequencer.  Pass 1 walks the slot's 45,000 words (45,001 when the start is not word-aligned) in bursts, splitting at the end
    // of the ring.  Pass 2 asks, for each symbol and lane, for the baseband words of that symbol that exist (32 words, clipped to 0 .. 3,199).
    always @(posedge clk) begin
        if (rst || !run) begin
            rst_q  <= Q_IDLE;
            rd_req <= 1'b0;
        end else if (l_start) begin
            // the request cursors start with the command (one driver each; their load enable
            // is this registered pulse, not `run`)
            r_off  <= first[RW+1:2];
            r_left <= (first[1:0] == 2'd0) ? 16'd45000 : 16'd45001;
            r_s    <= 7'd0;
            r_l    <= !len_on[0];
            rst_q  <= Q_IDLE;
        end else begin
            case (rst_q)
                Q_IDLE: if (!r_done) rst_q <= Q_CALC;
                Q_CALC: begin
                    r_rem    <= r_left;
                    r_towrap <= RING_WORDS - r_off;
                    r_m0     <= (r_l ? i0_1 : i0_0) + $signed({2'd0, r_s, 5'd0});
                    rst_q    <= Q_CALC1;
                end
                Q_CALC1: begin
                    r_la  <= (r_rem < BURST) ? r_rem : BURST;
                    r_lo  <= (r_m0 < 0) ? 16'sd0 : r_m0;
                    r_m31 <= r_m0 + 16'sd31;
                    rst_q <= Q_CALC2;
                end
                Q_CALC2: begin
                    r_hi <= (r_m31 > 16'sd3199) ? 16'sd3199 : r_m31;
                    if (!p2) begin
                        rd_addr     <= cap_base + r_off;
                        rd_burstlen <= (r_towrap < r_la) ? r_towrap[7:0] : r_la[7:0];
                        rst_q       <= Q_ROOM;
                    end else begin
                        rst_q       <= Q_CALC3;
                    end
                end
                Q_CALC3: begin
                    if (r_lo > r_hi) begin
                        rst_q <= Q_NEXT;            // nothing of this symbol exists
                    end else begin
                        rd_addr     <= (r_l ? bb1 : bb0) + {{(ADDR_WIDTH-16){1'b0}}, r_lo[15:0]};
                        rd_burstlen <= r_hi[7:0] - r_lo[7:0] + 8'd1;
                        rst_q       <= Q_ROOM;
                    end
                end
                Q_ROOM: begin
                    if ({1'b0, fres} + {1'b0, rd_burstlen} <= FD) begin
                        rd_req <= 1'b1;
                        rst_q  <= Q_REQ;
                    end
                end
                Q_REQ: begin
                    if (rd_gnt) begin
                        rd_req <= 1'b0;
                        rst_q  <= Q_BURST;
                        if (!p2) begin
                            r_left <= r_left - {8'd0, rd_burstlen};
                            r_off  <= r_off + rd_burstlen;   // wraps mod RING_WORDS by width
                        end
                    end
                end
                Q_BURST: if (rd_done) rst_q <= p2 ? Q_NEXT : ((r_left == 16'd0) ? Q_IDLE : Q_CALC);
                Q_NEXT: begin
                    // pass 2: next (symbol, lane)
                    if (r_lane_last) begin
                        r_l <= !len_on[0];
                        r_s <= r_s + 7'd1;
                        rst_q <= (r_s == 7'd78) ? Q_IDLE : Q_CALC;
                    end else begin
                        r_l   <= 1'b1;
                        rst_q <= Q_CALC;
                    end
                end
                default: rst_q <= Q_IDLE;
            endcase
            if (rst_q == Q_BURST && rd_done && !p2 && r_left == 16'd0) r_done <= 1'b1;
            if (rst_q == Q_NEXT && r_lane_last && r_s == 7'd78) r_done <= 1'b1;
        end
        if (rst || l_start) r_done <= 1'b0;
    end

    // ================================================================ pass 1 feed
    // `uw` holds the word being unpacked, the sample to send in its low 16 bits; `urem` samples
    // of it are left. It shifts every clock and is reloaded in the clock of its last sample
    // (`ld_q`, decided the clock before from `urem`, the FIFO count and the words left). The
    // slot's first word starts at lane first[1:0]; its last word then holds first[1:0] samples
    // (180,000 is a multiple of 4). After the slot's last sample come 92 zero samples.
    reg  [63:0] uw;
    reg  [2:0]  urem;
    reg         ld_q, ld_d1;
    reg         firstw, lastw;
    reg  [15:0] wleft;             // words not yet loaded
    reg         wnone;             // wleft == 0
    reg  [6:0]  tailc;
    reg         tailph;
    reg         f_on;
    wire [1:0]  off = first[1:0];
    wire [2:0]  n_first = 3'd4 - {1'b0, off};
    wire [2:0]  n_last  = (off == 2'd0) ? 3'd4 : {1'b0, off};

    always @(posedge clk) begin
        x_valid <= f_on && !clr && ((urem != 3'd0) || tailph);
        x_s     <= tailph ? 16'sd0 : uw[15:0];
        if (clr) begin
            f_on   <= l_start && !p2;
            urem   <= 3'd0;
            ld_q   <= 1'b0;
            ld_d1  <= 1'b0;
            firstw <= 1'b1;
            lastw  <= 1'b0;
            wleft  <= (off == 2'd0) ? 16'd45000 : 16'd45001;
            wnone  <= 1'b0;
            tailc  <= 7'd92;
            tailph <= 1'b0;
        end else if (f_on) begin
            // the word comes from `gw` (the FIFO head, registered: the 128-word memory's read and the shift in one clock did not
            // meet timing).  `cnz_q` and `gw` are a clock behind the FIFO, so no reload is decided in the two clocks after one.
            ld_d1 <= ld_q;
            ld_q  <= !ld_q && !ld_d1 && (urem <= 3'd2) && cnz_q && !wnone;
            if (ld_q) begin
                case (firstw ? off : 2'd0)
                    2'd0:    uw <= gw;
                    2'd1:    uw <= {16'd0, gw[63:16]};
                    2'd2:    uw <= {32'd0, gw[63:32]};
                    default: uw <= {48'd0, gw[63:48]};
                endcase
                urem   <= firstw ? n_first : lastw ? n_last : 3'd4;
                firstw <= 1'b0;
                lastw  <= (wleft == 16'd2);
                wnone  <= (wleft == 16'd1);
                wleft  <= wleft - 16'd1;
            end else begin
                uw <= {16'd0, uw[63:16]};
                if (urem != 3'd0) urem <= urem - 3'd1;
            end
            // the zeros behind the slot follow its last sample without a gap
            if (wnone && !ld_q && (urem <= 3'd1)) tailph <= 1'b1;
            if (tailph) begin
                tailc <= tailc - 7'd1;
                if (tailc == 7'd1) begin
                    tailph <= 1'b0;
                    f_on   <= 1'b0;
                end
            end
        end
    end

    // ================================================================ pass 2 feed
    // cursor (symbol, lane, sample) and its baseband index g_m; a word that exists comes from
    // the FIFO head (`gw` follows the head every clock, so it is valid from the second clock
    // after a pop or after the FIFO got its first word, which `cnz_q` covers)
    reg  [6:0]  g_s;
    reg         g_l;
    reg  [4:0]  g_n;
    reg         g_on;
    reg  signed [15:0] g_m;
    reg         g_in;              // g_m is inside the baseband
    reg         g_lastn, g_end;
    reg         gpop;
    reg  [2:0]  gst;
    localparam [2:0] G_IDLE = 3'd0, G_PREP = 3'd1, G_LOAD = 3'd2, G_OFFER = 3'd3, G_ADV = 3'd4,
                     G_ADV2 = 3'd5;
    wire        g_lane_last = g_l || !len_on[1];

    // Pass 2 feed state machine: prepare the word (G_PREP), wait until it is in the FIFO (G_LOAD), offer it to the lane (G_OFFER), advance (G_ADV, G_ADV2).
    always @(posedge clk) begin
        gw    <= fhead;
        cnz_q <= (fcnt != 8'd0);
        y_stb <= 2'b00;
        gpop  <= 1'b0;
        if (clr) begin
            g_on <= l_start && p2;
            gst  <= (l_start && p2) ? G_PREP : G_IDLE;
            g_s  <= 7'd0;
            g_l  <= !len_on[0];
            g_n  <= 5'd0;
            g_m  <= len_on[0] ? i0_0 : i0_1;
        end else begin
            case (gst)
                G_PREP: begin
                    g_in <= (g_m >= 0) && (g_m <= 16'sd3199);
                    gst  <= G_LOAD;
                end
                G_LOAD: begin
                    if (!g_in || cnz_q) begin
                        yz  <= !g_in;
                        gst <= G_OFFER;
                    end
                end
                G_OFFER: begin
                    if (y_rdy[g_l]) begin
                        y_stb[g_l] <= 1'b1;        // the lane takes gw in the next clock
                        gpop       <= g_in;
                        gst        <= G_ADV;
                    end
                end
                G_ADV: begin
                    g_lastn <= (g_n == 5'd31);
                    g_end   <= (g_n == 5'd31) && g_lane_last && (g_s == 7'd78);
                    g_n     <= g_n + 5'd1;
                    if (g_n == 5'd31) begin
                        if (g_lane_last) begin
                            g_l <= !len_on[0];
                            g_s <= g_s + 7'd1;
                        end else begin
                            g_l <= 1'b1;
                        end
                    end
                    gst <= G_ADV2;
                end
                G_ADV2: begin
                    g_m <= g_lastn ? (g_l ? i0_1 : i0_0) + $signed({2'd0, g_s, 5'd0}) : g_m + 16'sd1;
                    if (g_end) begin
                        g_on <= 1'b0;
                        gst  <= G_IDLE;
                    end else begin
                        gst  <= G_PREP;
                    end
                end
                default: ;
            endcase
        end
    end

    // FIFO pointers: both pops are registers
    assign fpop = ld_q || gpop;
    always @(posedge clk) begin
        if (clr) begin
            fwp <= 7'd0; frp <= 7'd0; fcnt <= 8'd0; fres <= 8'd0;
        end else begin
            if (rv_q) fwp <= fwp + 7'd1;
            if (fpop) frp <= frp + 7'd1;
            fcnt <= fcnt + (rv_q ? 8'd1 : 8'd0) - (fpop ? 8'd1 : 8'd0);
            fres <= fres + (r_grant ? rd_burstlen : 8'd0) - (fpop ? 8'd1 : 8'd0);
        end
    end

    // ================================================================ output FIFOs and writer
    reg  [63:0] ofifo0 [0:15] /* synthesis syn_ramstyle = "distributed_ram" */;
    reg  [63:0] ofifo1 [0:15] /* synthesis syn_ramstyle = "distributed_ram" */;
    // ofifo*: the output FIFOs of 16 words, one per lane, with write and read pointers, fill counts, and the words written so far.
    // wl is the lane of the burst in progress, wst the writer state.
    reg  [3:0]  owp0, orp0, owp1, orp1;
    reg  [4:0]  ocnt0, ocnt1;
    reg  [15:0] owc0, owc1;        // words written so far per lane
    reg         wl;                // lane of the burst in progress
    reg  [1:0]  wst;
    wire [4:0]  ocnt0_up = ocnt0 + 5'd1, ocnt0_dn = ocnt0 - 5'd1;
    wire [4:0]  ocnt1_up = ocnt1 + 5'd1, ocnt1_dn = ocnt1 - 5'd1;
    wire        wpop0 = (wst == 2'd2) && !wl && wr_gnt;
    wire        wpop1 = (wst == 2'd2) &&  wl && wr_gnt;
    assign wr_wdata = (L2 && wl) ? ofifo1[orp1] : ofifo0[orp0];
    always @(posedge clk) begin
        if (o_valid[0]) ofifo0[owp0] <= o_word0;
        if (L2 && o_valid[1]) ofifo1[owp1] <= o_word1;
    end
    always @(posedge clk) begin
        if (clr) begin
            owp0 <= 4'd0; orp0 <= 4'd0; ocnt0 <= 5'd0; owc0 <= 16'd0;
            owp1 <= 4'd0; orp1 <= 4'd0; ocnt1 <= 5'd0; owc1 <= 16'd0;
            wst  <= 2'd0;
            wr_req <= 1'b0;
            wl   <= 1'b0;
        end else begin
            if (o_valid[0]) owp0 <= owp0 + 4'd1;
            if (L2 && o_valid[1]) owp1 <= owp1 + 4'd1;
            if (wpop0) orp0 <= orp0 + 4'd1;
            if (L2 && wpop1) orp1 <= orp1 + 4'd1;
            // up / down from the register, so that the late `wr_gnt` (through the write arbiter) selects last: with the grant in
            // front of the adder the path had 11 logic levels and did not meet timing
            ocnt0 <= o_valid[0] ? (wpop0 ? ocnt0 : ocnt0_up) : (wpop0 ? ocnt0_dn : ocnt0);
            if (L2) ocnt1 <= o_valid[1] ? (wpop1 ? ocnt1 : ocnt1_up) : (wpop1 ? ocnt1_dn : ocnt1);
            case (wst)
                2'd0: begin
                    // a lane with 8 words ready, lane 1 first if it was not served last
                    if (ocnt0 >= 5'd8 && (ocnt1 < 5'd8 || wl)) begin
                        wl      <= 1'b0;
                        wr_addr <= (p2 ? sym0 : bb0) + {{(ADDR_WIDTH-16){1'b0}}, owc0};
                        wst     <= 2'd1;
                    end else if (L2 && ocnt1 >= 5'd8) begin
                        wl      <= 1'b1;
                        wr_addr <= (p2 ? sym1 : bb1) + {{(ADDR_WIDTH-16){1'b0}}, owc1};
                        wst     <= 2'd1;
                    end
                end
                2'd1: begin
                    wr_req <= 1'b1;
                    wst    <= 2'd2;
                end
                2'd2: begin
                    if (wr_done) begin
                        wr_req <= 1'b0;
                        if (L2 && wl) owc1 <= owc1 + 16'd8; else owc0 <= owc0 + 16'd8;
                        wst <= 2'd3;
                    end
                end
                default: wst <= 2'd0;
            endcase
        end
    end

    // ================================================================ command sequencing
    // The command is done when requests and feeding are over, the lanes are idle and every output word is written.  With one lane built
    // the lane is started a second time for the caller's lane 1.

    wire lanes_idle = (l_busy == 2'b00);
    wire outs_empty = (ocnt0 == 5'd0) && (ocnt1 == 5'd0) && (wst == 2'd0);
    reg  [2:0] fin;
    reg  [1:0] ls_d;               // l_start, one and two clocks late (the lanes start a clock late)
    always @(posedge clk) begin
        l_start <= 1'b0;
        clr     <= rst;
        irq     <= 1'b0;
        ls_d    <= {ls_d[0], l_start};
        if (run) clocks <= clocks + 32'd1;
        if (rst) begin
            run <= 1'b0;
            fin <= 3'd0;
        end else if (!run) begin
            if (cmd_start) begin
                run      <= 1'b1;
                p2       <= cmd_pass2;
                len_on   <= L2 ? cmd_lanes : 2'b01;
                vsel     <= !cmd_lanes[0];
                vnext    <= (cmd_lanes == 2'b11);
                l_start  <= 1'b1;
                clr      <= 1'b1;
                clocks   <= 32'd1;
                fin      <= 3'd0;
            end
        end else begin
            // done: requests and feeding over, lanes idle, every output word written
            fin <= {fin[1:0], r_done && !f_on && !g_on && lanes_idle && outs_empty && !l_start &&
                            (ls_d == 2'b00)};
            if (fin == 3'b111 && !L2 && vnext) begin
                // one lane built: the same again for the caller's lane 1
                vsel    <= 1'b1;
                vnext   <= 1'b0;
                l_start <= 1'b1;
                clr     <= 1'b1;
                fin     <= 3'd0;
            end else if (fin == 3'b111) begin
                run        <= 1'b0;
                irq        <= 1'b1;
                run_clocks <= clocks;
            end
        end
    end

endmodule
