// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ft8_cand_lane: one lane of the FT8 candidate engine, the signal processing that turns the slot's audio into one candidate's baseband
// (pass 1) and into its 79 x 8 soft symbols (pass 2).
//
// Where it sits in the radio
//   Fed by ft8_cand.v, which reads the audio (or the baseband) from DDR3 and hands it over one sample per clock.  Its output words go back
//   through ft8_cand.v to DDR3.  The roles of the two passes are explained in ft8_cand.v and ft8_frontend.v, and this file is the
//   arithmetic.  It is bit-exact with the Rust model (pass 1 is `baseband_fx` in fw/tr-modes/src/frontend/baseband.rs, pass 2 is
//   `symbols_fx` in symbols.rs); docs/F7_CAND.md has the design and the measurements.  Glossary entries "NCO", "Mixer", "CIC filter",
//   "FIR filter", "Decimation", "DSP block" and "Soft symbol" in docs/learn/GLOSSARY.md explain the terms.
//
// Pass 1: mix, decimate, filter
//   The lane is fed the slot's audio x[n], n = 0 .. 180,091 (the engine sends zeros from 180,000 on), one sample per `x_valid`.  The goal
//   is the signal of one candidate, 50 Hz wide somewhere in 0 .. 3 kHz, at a low sample rate, so that the 3,200 complex samples that are
//   left can be searched by the CPU.  Three steps do that:
//   1. Mix.  An NCO makes the phase p[n] = n x inc (ft8_nco.v, `inc` chosen by the firmware so that the middle of the candidate's 8 tones
//      maps to 0 Hz), and the product with e^(-j p) moves the candidate to 0 Hz: mr = (x cos + 2^12) >> 13, mi = (-x sin + 2^12) >> 13.
//   2. CIC decimation by 30, 12 ksps to 400 sps.  A CIC filter (cascaded integrator-comb) is a cheap filter that needs no multipliers:
//      four integrators (running sums, 41 bits, allowed to wrap because the combs subtract again) run at the input rate, their output is
//      sampled once per 30 inputs, and four combs (differences of successive samples) follow.  The result q[j] is the 4th-order boxcar
//      sum at input 30 j + 58 (j = -1 .. 6,001), rounded by >> 16 (the CIC's gain is 30^4, about 2^19.6).
//   3. FIR decimation by 2, 400 sps to 200 sps.  A 65-tap low-pass filter (Kaiser window, cut-off 31.25 Hz at 400 sps; the coefficients are
//      in rtl/ft8/rom/ft8_fir65.hex) removes what is outside the candidate's 50 Hz and the output only needs every second value:
//      y[k] = (sum over i = 0 .. 64 of h[i] q[2k + 32 - i] + 2^19) >> 20, k = 0 .. 3,199, with q = 0 outside j = -1 .. 6,001 (after the last
//      real q the lane feeds itself zeros).  The output is 3,200 words {y_im, y_re} of 32-bit halves.
//   The integrators are a registered chain, so integrator 4 holds I4[n - 3] after input n, which is why it is sampled after the inputs
//   n = 31, 61, ..., 180,091.  The FIR keeps the q history in four 32-entry memories (I and Q, even and odd q index) and computes an output
//   with four multiply-accumulate blocks (I and Q, even and odd taps) in 33 clocks, once per two q (60 inputs); the newest even q waits in
//   a register, and an odd q that arrives during a computation is written when that is done (it stays in the comb output register until
//   the next q, 30 inputs later).
//
// Pass 2: rotate and take the tone energies
//   The lane is fed this candidate's baseband y[m] for m = i0 + 32 s + n (s = 0 .. 78 symbols, n = 0 .. 31 samples, in that order), one word per
//   `y_stb`, with `y_zero` set where m is outside 0 .. 3,199.  One symbol is 160 ms = 32 samples at 200 sps.
//   1. Rotate.  z[m] = y[m] (cos + j sin)(m x rinc), each part (... + 2^16) >> 17: this removes the fine frequency offset that the CPU measured, so
//      that tone t of the candidate lands exactly on bin t x 6.25 Hz.  It uses the two mixer multipliers, two clocks per sample, and the result is
//      stored per symbol in the same four memories (double-buffered, so the next symbol can be rotated while this one is measured).
//   2. DFT.  C[s][t] = (sum over n of z[i0 + 32 s + n] W_32^(t n mod 32) + 2^16) >> 17, t = 0 .. 7, where W_32 = e^(-j 2 pi / 32) (a 32-entry ROM,
//      rtl/ft8/rom/ft8_w32.hex).  Each bin t is the energy-carrying amplitude of tone t in symbol s, and the 8 numbers of a symbol are what the CPU
//      turns into bit probabilities.  The four multiply-accumulate blocks do one complex product per clock (a complex product is four real
//      products), so a symbol takes 8 bins x 32 samples = 256 clocks, while the next symbol is rotated.  Output: 632 words {C_im, C_re}.
//   `y_rdy` (a register) says the lane takes a word; the engine then pulses `y_stb` for one clock with the word, never in two clocks running,
//   and the lane drops `y_rdy` for the two clocks after it.
//
// Timing rules
//   Built by docs/TANG_LESSONS.md sections 3 and 6 (docs/F7_CAND.md section 3):
//   - the six multipliers are instantiated DSP blocks with input, product and output register (ft8_mac.v); the four of the FIR and the DFT
//     accumulate inside the block, and hold their sum through clocks with a zero operand, so that no sum register has a load enable;
//   - every pipeline register loads every clock, and what must hold is held by feeding zero.  The load enables that remain (integrators, phase)
//     are register outputs, the integrators' in nine copies that are reset from different taps of a delay chain so that the tool keeps them;
//   - the comb delays are one 4-word LUT RAM (two clocks per comb);
//   - rounding is a clock of its own behind the sums.
//   `start` acts one clock after it arrives.
//
// Resources
//   DSP: 6.  Block RAM: 1 (the NCO ROM).  The data memories and the tap ROMs are LUT cells.

`timescale 1ns / 1ps

`include "rtl/ft8/ft8_dly.v"

`ifndef FT8_FIR_ROM
`define FT8_FIR_ROM "rtl/ft8/rom/ft8_fir65.hex"
`endif
`ifndef FT8_W32_ROM
`define FT8_W32_ROM "rtl/ft8/rom/ft8_w32.hex"
`endif

module ft8_cand_lane (
    // Clock (clk_dsp, 120 MHz) and synchronous reset (active high).
    input  wire               clk,
    input  wire               rst,

    input  wire               start,     // begin a job (one clock): pass2, inc and i0 are taken one clock later
    input  wire               pass2,     // 0: pass 1 (audio to baseband), 1: pass 2 (baseband to soft symbols)
    input  wire [31:0]        inc,       // NCO phase increment per sample (one turn = 2^32): pass 1 the mixing frequency, pass 2 the rotation
    input  wire signed [15:0] i0,        // pass 2: start sample of the first symbol in the baseband (may be negative)

    input  wire               x_valid,   // pass 1 audio stream: one sample per clock where x_valid is high
    input  wire signed [15:0] x,

    output reg                y_rdy,     // pass 2 baseband stream: the lane takes a word when y_rdy is high
    input  wire               y_stb,     // one clock: y is handed over
    input  wire [63:0]        y,         // a baseband word {im[31:0], re[31:0]}, only the 22 low bits of each half are used
    input  wire               y_zero,    // this word is outside the baseband and counts as zero

    output reg                out_valid, // one clock: out_word is an output word
    output reg  [63:0]        out_word,  // pass 1 baseband word or pass 2 soft symbol {im[31:0], re[31:0]}
    output reg                busy       // a job is running
) /* synthesis syn_maxfan = 10000, syn_srlstyle = "registers" */;

    // ================================================================ start, kept copies
    // rch is a delay chain of the reset, whose taps are different for each copy, so that the tool cannot merge the copies below into one
    // register.  sq is `start` one clock late, which is what the lane acts on.  sc are 12 copies of it (one per wide clear), so that no
    // single net has to drive all the clears.
    reg  [11:0] rch;               // reset delay chain: its taps make the copies below unequal
    reg         sq;                // start, one clock late: what the lane acts on
    reg  [11:0] sc /* synthesis syn_preserve = 1 */;   // the 12 copies of sq
    integer ci;
    always @(posedge clk) begin
        rch <= {rch[10:0], rst};
        sq  <= start && !rst;
        for (ci = 0; ci < 12; ci = ci + 1) sc[ci] <= start && !rch[ci];
    end

    // ================================================================ job state
    // Job state: p2 is the pass of the running job, incr the NCO increment, ph the phase accumulator and ph_add what the next clock adds to it,
    // ph_q the phase of the sample that is being issued to the NCO.
    reg         p2;
    reg  [31:0] incr;
    reg  [31:0] ph;                // NCO phase accumulator
    reg  [31:0] ph_add;            // what the next clock adds to it
    reg  [31:0] ph_q;              // phase of the sample being issued to the NCO
    // pass 2 start phase m0 x rinc, by shift and add (12 clocks): the first sample that is inside the baseband, max(0, i0), times the
    // rotation increment, so that the rotation of every later sample is a simple addition of `inc` per sample
    reg  [11:0] mul_m;
    reg  [31:0] mul_a;
    reg  [3:0]  mul_n;
    reg         mul_run, mul_d1, mul_d2;

    // pass 2 rotation issue: rs and rn are the symbol and the sample being rotated, rot_on says the rotation runs, rot_done counts symbols
    // rotated and stored, dft_rel counts symbols whose DFT has read its buffer for the last time (so the buffer can be reused)
    reg  [6:0]  rs;                // symbol being rotated, 0 .. 79
    reg  [4:0]  rn;                // its sample, 0 .. 31
    reg         rot_on;
    reg  [6:0]  rot_done;          // symbols rotated and stored
    reg  [6:0]  dft_rel;           // symbols whose DFT has read its buffer for the last time

    // ================================================================ input, phase, NCO issue
    // I0: the sample or word as it arrives. I1: the phase step it causes. I2: its NCO request,
    // with the phase before that step.
    localparam integer PW = 22 + 22 + 5 + 1 + 1;   // pass 1 x; pass 2 {yr, yi, n, buf, last}
    reg         iv0, adv0;
    reg  signed [15:0] x0;
    reg  [63:0] y0;
    reg         yz0;
    reg  [6:0]  tag0;
    reg         iv1;
    reg  [PW-1:0] pl1;
    reg         nco_iv;
    always @(posedge clk) begin
        iv0  <= busy && !rst && (p2 ? y_stb : x_valid);
        adv0 <= busy && !rst && (p2 ? (y_stb && !y_zero) : x_valid);
        x0   <= x;
        y0   <= y;
        yz0  <= y_zero;
        tag0 <= {rn, rs[0], (rn == 5'd31)};

        iv1    <= iv0;
        ph_add <= mul_run ? (mul_m[0] ? mul_a : 32'd0) : (adv0 ? incr : 32'd0);
        pl1    <= p2 ? {(yz0 ? 22'd0 : y0[21:0]), (yz0 ? 22'd0 : y0[53:32]), tag0}
                     : {{(PW-16){1'b0}}, x0};

        nco_iv <= iv1;
        ph_q   <= ph;
        if (sc[11]) ph <= 32'd0;
        else        ph <= ph + ph_add;
    end

    wire        nco_ov;
    wire signed [17:0] nco_c, nco_s;
    ft8_nco u_nco (.clk(clk), .in_valid(nco_iv), .phase(ph_q), .out_valid(nco_ov),
                   .cos_o(nco_c), .sin_o(nco_s));

    // payload travelling alongside the NCO: pl_o is pl1 six clocks late (one beside the NCO request, five beside the NCO).  It is a
    // LUT-RAM delay (ft8_dly.v) and not six registers of 51 bits.
    wire [PW-1:0] pl_o;
    ft8_dly #(.W(PW), .N(6)) u_pl (.clk(clk), .d(pl1), .q(pl_o));
    wire signed [21:0] pl_yr = pl_o[PW-1 -: 22];
    wire signed [21:0] pl_yi = pl_o[PW-23 -: 22];
    wire signed [15:0] pl_x  = pl_o[15:0];

    // ================================================================ multipliers 0, 1
    // T0 = the clock of nco_ov. Operand registers load at its end (pass 1: x cos, x sin; pass 2
    // first multiply: yr cos, yi sin) and one clock later (pass 2 second multiply: yr sin,
    // yi cos, from the copies below); the products are there three clocks after the operands.
    // Multipliers 0 and 1 are the mixer (pass 1: x cos and x sin) and the rotation (pass 2: four products over two clocks, yr cos, yi sin
    // and then yr sin, yi cos).
    reg  signed [21:0] yr_h, yi_h;
    reg  signed [17:0] c_h, s_h;
    reg         nv1, nv2, nv3, nv4, nv5, nv6;         // nco_ov, 1 .. 6 clocks late
    reg  [6:0]  tg1, tg2, tg3, tg4, tg5, tg6;         // pass 2 tag {n, buf, last}, likewise
    reg  signed [21:0] a0q, a1q;
    reg  signed [17:0] b0q, b1q;
    wire signed [47:0] mp0, mp1;
    always @(posedge clk) begin
        yr_h <= pl_yr;
        yi_h <= pl_yi;
        c_h  <= nco_c;
        s_h  <= nco_s;
        nv1  <= nco_ov && !rst;
        nv2  <= nv1; nv3 <= nv2; nv4 <= nv3; nv5 <= nv4; nv6 <= nv5;
        tg1  <= pl_o[6:0];
        tg2  <= tg1; tg3 <= tg2; tg4 <= tg3; tg5 <= tg4; tg6 <= tg5;
        if (nv1 && p2) begin
            a0q <= yr_h; b0q <= s_h; a1q <= yi_h; b1q <= c_h;
        end else if (p2) begin
            a0q <= pl_yr; b0q <= nco_c; a1q <= pl_yi; b1q <= nco_s;
        end else begin
            a0q <= {{6{pl_x[15]}}, pl_x}; b0q <= nco_c;
            a1q <= {{6{pl_x[15]}}, pl_x}; b1q <= nco_s;
        end
    end
    ft8_mac u_m0 (.clock(clk), .a({{5{a0q[21]}}, a0q}), .b(b0q), .acc(1'b0), .p(mp0));
    ft8_mac u_m1 (.clock(clk), .a({{5{a1q[21]}}, a1q}), .b(b1q), .acc(1'b0), .p(mp1));
    wire signed [40:0] m0w = mp0[40:0];
    wire signed [40:0] m1w = mp1[40:0];

    // ================================================================ pass 1: mix, CIC
    // products valid in T0 + 4; mixer output registered, into the integrators in T0 + 5
    reg  signed [40:0] mr_q, mi_q;
    reg  [8:0]  mvq /* synthesis syn_preserve = 1 */;   // "mixer output valid", one per register
    reg  signed [40:0] ir1, ir2, ir3, ir4, iq1, iq2, iq3, iq4;
    reg  [17:0] ncnt;              // index of the next sample into the integrators
    reg  [4:0]  n30;               // ncnt mod 30
    reg         samp /* synthesis syn_maxfan = 10000 */;   // integrator 4 holds I4 of a sampling point now
    integer mi;
    always @(posedge clk) begin
        mr_q <= (m0w + 41'sd4096) >>> 13;
        mi_q <= (41'sd4096 - m1w) >>> 13;
        for (mi = 0; mi < 9; mi = mi + 1) mvq[mi] <= nv4 && !p2 && !rch[mi];
        if (sc[0]) ir1 <= 41'sd0; else if (mvq[0]) ir1 <= ir1 + mr_q;
        if (sc[1]) ir2 <= 41'sd0; else if (mvq[1]) ir2 <= ir2 + ir1;
        if (sc[2]) ir3 <= 41'sd0; else if (mvq[2]) ir3 <= ir3 + ir2;
        if (sc[3]) ir4 <= 41'sd0; else if (mvq[3]) ir4 <= ir4 + ir3;
        if (sc[4]) iq1 <= 41'sd0; else if (mvq[4]) iq1 <= iq1 + mi_q;
        if (sc[5]) iq2 <= 41'sd0; else if (mvq[5]) iq2 <= iq2 + iq1;
        if (sc[6]) iq3 <= 41'sd0; else if (mvq[6]) iq3 <= iq3 + iq2;
        if (sc[7]) iq4 <= 41'sd0; else if (mvq[7]) iq4 <= iq4 + iq3;
        samp <= 1'b0;
        if (sc[8]) begin
            ncnt <= 18'd0; n30 <= 5'd0;
        end else if (mvq[8]) begin
            ncnt <= ncnt + 18'd1;
            n30  <= (n30 == 5'd29) ? 5'd0 : n30 + 5'd1;
            samp <= (n30 == 5'd1) && (ncnt >= 18'd31);
        end
    end

    // Combs at the decimated rate. The four delays are one 4-word LUT RAM (I and Q in one word),
    // cleared by four writes of zero after a start. With S the clock of `samp`: the integrators'
    // values are taken at its end; comb s reads its delay in S + 1 + 2 s and subtracts and
    // writes in S + 2 + 2 s; q = (c4 + 2^15) >> 16 is registered in S + 9 and `q_ev` is S + 10.
    // `cur` loads every clock: it subtracts `zq`, which is zero outside a subtract clock.
    reg  [81:0] zmem [0:3] /* synthesis syn_ramstyle = "distributed_ram" */;
    reg  signed [40:0] cur_r, cur_q, zq_r, zq_q;
    reg  [8:0]  cc;                // one-hot: cc[k] is clock S + 1 + k
    reg  [3:0]  zi;                // the four clearing writes after a start
    reg         rdf /* synthesis syn_maxfan = 10000 */;    // a delay is read this clock
    reg         zwe;               // a delay is written this clock
    reg  [1:0]  csr;               // the comb being worked on
    reg         q_ev /* synthesis syn_maxfan = 10000 */;
    reg  signed [24:0] q_r, q_i;
    wire [81:0] zrd = zmem[csr];
    wire signed [40:0] qr_w = (cur_r + 41'sd32768) >>> 16;
    wire signed [40:0] qi_w = (cur_q + 41'sd32768) >>> 16;
    always @(posedge clk) begin
        cc   <= rst ? 9'd0 : {cc[7:0], samp};
        zi   <= rst ? 4'd0 : {zi[2:0], sq};
        rdf  <= samp || cc[1] || cc[3] || cc[5];
        zwe  <= !rst && (cc[0] || cc[2] || cc[4] || cc[6] || sq || zi[0] || zi[1] || zi[2]);
        csr  <= (sq || samp) ? 2'd0 : zwe ? csr + 2'd1 : csr;
        zq_r <= rdf ? $signed(zrd[40:0])  : 41'sd0;
        zq_q <= rdf ? $signed(zrd[81:41]) : 41'sd0;
        if (sc[9])  cur_r <= 41'sd0; else cur_r <= samp ? ir4 : cur_r - zq_r;
        if (sc[10]) cur_q <= 41'sd0; else cur_q <= samp ? iq4 : cur_q - zq_q;
        if (zwe) zmem[csr] <= {cur_q, cur_r};
        if (cc[8]) begin                 // held until the next q (the FIR sequencer relies on it)
            q_r <= qr_w[24:0];
            q_i <= qi_w[24:0];
        end
        q_ev <= cc[8] && !rst;
    end

    // ================================================================ pass 2: rotation result
    // first multiply (yr c, yi s) valid in T0 + 4, second (yr s, yi c) in T0 + 5; difference and
    // sum registered, rounded a clock later, written in T0 + 7
    reg  signed [40:0] zd, zs;
    reg  signed [21:0] zr_a;
    reg         zw;                // write z this clock
    reg  signed [21:0] zw_r, zw_i;
    reg  [6:0]  zw_tag;            // {n, buf, last}
    wire signed [40:0] zr_w = (zd + 41'sd65536) >>> 17;
    wire signed [40:0] zi_w = (zs + 41'sd65536) >>> 17;
    always @(posedge clk) begin
        zd     <= m0w - m1w;
        zs     <= m0w + m1w;
        zr_a   <= zr_w[21:0];
        zw_r   <= zr_a;
        zw_i   <= zi_w[21:0];
        zw     <= nv6 && p2 && !rst;
        zw_tag <= tg6;
    end

    // ================================================================ data memories
    // I even, I odd, Q even, Q odd; 32 x 25 bits each, LUT RAM. Pass 1: q history, entry
    // (u >> 1) mod 32 for q index u = j + 32. Pass 2: z of two symbols, entry {buf, n >> 1}.
    reg  [24:0] mie [0:31] /* synthesis syn_ramstyle = "distributed_ram" */;
    reg  [24:0] mio [0:31] /* synthesis syn_ramstyle = "distributed_ram" */;
    reg  [24:0] mqe [0:31] /* synthesis syn_ramstyle = "distributed_ram" */;
    reg  [24:0] mqo [0:31] /* synthesis syn_ramstyle = "distributed_ram" */;
    reg         we_e, we_o;
    reg  [4:0]  wa_e, wa_o;
    reg  [24:0] wd_ie, wd_qe, wd_io, wd_qo;
    always @(posedge clk) begin
        if (we_e) begin mie[wa_e] <= wd_ie; mqe[wa_e] <= wd_qe; end
        if (we_o) begin mio[wa_o] <= wd_io; mqo[wa_o] <= wd_qo; end
    end

    // FIR taps and W_32 (LUT ROMs)
    reg  [17:0] fir [0:64] /* synthesis syn_romstyle = "distributed_rom" */;
    reg  [35:0] w32 [0:31] /* synthesis syn_romstyle = "distributed_rom" */;
    initial begin
        $readmemh(`FT8_FIR_ROM, fir);
        $readmemh(`FT8_W32_ROM, w32);
    end

    // ================================================================ control state
    // FIR sequencer, one-hot
    localparam integer FI = 0, FM = 1, FW = 2, FN = 3, FO = 4;   // idle, taps, wait, write newest, write odd
    reg  [4:0]  fst;
    reg  [12:0] u;                 // next q index (q[j] is u = j + 32)
    reg  [12:0] un;                // newest even q of the output being computed
    reg  signed [24:0] nw_r, nw_i; // its value
    reg         pend;              // an odd q waiting for the computation to end
    reg  [12:0] pend_u;
    reg  [5:0]  fc;                // tap step 0 .. 32
    reg  [11:0] kc;                // outputs so far
    reg         tail;              // all real q seen: feed zeros
    reg  [12:0] ue_c, uo_c;        // q indices of tap pair c: even tap at un - 2c, odd at un - 1 - 2c
    // DFT
    reg  [6:0]  ds;                // symbol in the DFT
    reg  [2:0]  dt;
    reg  [4:0]  dn;
    reg  [4:0]  wix;               // (t n) mod 32
    reg         d_on;

    // one q event (real or tail zero): into the history, or start an output
    // registered a clock behind kc and u: kc moves two states before the idle state looks, and
    // u passes 64 once, while q events are 30 inputs apart
    reg         kdone, u_ge64;
    always @(posedge clk) begin
        kdone  <= (kc == 12'd3200);
        u_ge64 <= (u >= 13'd64);
    end
    wire        tail_ev = tail && fst[FI] && !pend && !kdone && !q_ev;
    wire        qe_v = !p2 && busy && (q_ev || tail_ev);
    wire [12:0] qe_u = u;
    wire signed [24:0] qe_r = q_ev ? q_r : 25'sd0;
    wire signed [24:0] qe_i = q_ev ? q_i : 25'sd0;

    // the newest even q: follows the q events while the sequencer is idle, held from the clock
    // it leaves idle (its load enable is the idle state bit itself)
    always @(posedge clk) begin
        if (fst[FI]) begin
            nw_r <= qe_r;
            nw_i <= qe_i;
        end
    end

    // memory write data, loaded every clock (the write enables come from the sequencer)
    always @(posedge clk) begin
        if (p2) begin
            wd_ie <= {{3{zw_r[21]}}, zw_r}; wd_qe <= {{3{zw_i[21]}}, zw_i};
            wd_io <= {{3{zw_r[21]}}, zw_r}; wd_qo <= {{3{zw_i[21]}}, zw_i};
        end else begin
            wd_ie <= fst[FN] ? nw_r : qe_r;
            wd_qe <= fst[FN] ? nw_i : qe_i;
            wd_io <= fst[FO] ? q_r : qe_r;       // the waiting odd q is still the comb output
            wd_qo <= fst[FO] ? q_i : qe_i;
        end
    end

    // ================================================================ multiply-accumulate
    // J1 (set by the sequencer): what to multiply. J2: the operands, read from the memories and
    // ROMs, zero in a clock without an issue. Then the four blocks, their sums valid 3 clocks
    // after J2; the sums of the last product are combined in the next clock, rounded in the one
    // after, and `out_valid` is 5 clocks after the last J2.
    //   operand code: 0 zero, 1 even memory, 2 the newest even q, 3 the other parity's memory
    reg         j_v, j_first, j_last;
    reg  [1:0]  j_ce, j_co;
    reg  [4:0]  j_ae, j_ao;
    reg  [5:0]  j_fc;
    reg  [4:0]  j_wi;
    reg  signed [24:0] o_ie, o_io, o_qe, o_qo;
    reg  signed [17:0] k_ie, k_io, k_qe, k_qo;
    reg         o_acc, o_last;
    wire [35:0] w_rd = w32[j_wi];
    wire [17:0] fir_e = fir[{j_fc, 1'b0}];
    wire [17:0] fir_o = fir[{j_fc[4:0], 1'b1}];
    always @(posedge clk) begin
        case (j_ce)
            2'd1:    begin o_ie <= $signed(mie[j_ae]); o_qe <= $signed(mqe[j_ae]); end
            2'd2:    begin o_ie <= nw_r;               o_qe <= nw_i;               end
            2'd3:    begin o_ie <= $signed(mio[j_ao]); o_qe <= $signed(mqo[j_ao]); end
            default: begin o_ie <= 25'sd0;             o_qe <= 25'sd0;             end
        endcase
        case (j_co)
            2'd1:    begin o_io <= $signed(mio[j_ao]); o_qo <= $signed(mqo[j_ao]); end
            2'd3:    begin o_io <= $signed(mie[j_ae]); o_qo <= $signed(mqe[j_ae]); end
            default: begin o_io <= 25'sd0;             o_qo <= 25'sd0;             end
        endcase
        if (p2) begin
            k_ie <= $signed(w_rd[35:18]);   // zr wr
            k_qe <= $signed(w_rd[17:0]);    // zi wi
            k_io <= $signed(w_rd[17:0]);    // zr wi
            k_qo <= $signed(w_rd[35:18]);   // zi wr
        end else begin
            k_ie <= $signed(fir_e);
            k_qe <= $signed(fir_e);
            k_io <= j_fc[5] ? 18'sd0 : $signed(fir_o);   // tap step 32 has no odd tap
            k_qo <= j_fc[5] ? 18'sd0 : $signed(fir_o);
        end
        o_acc  <= !(j_v && j_first);
        o_last <= j_v && j_last && !rst;
    end

    wire signed [47:0] p_ie, p_io, p_qe, p_qo;
    ft8_mac u_mie (.clock(clk), .a({{2{o_ie[24]}}, o_ie}), .b(k_ie), .acc(o_acc), .p(p_ie));
    ft8_mac u_mio (.clock(clk), .a({{2{o_io[24]}}, o_io}), .b(k_io), .acc(o_acc), .p(p_io));
    ft8_mac u_mqe (.clock(clk), .a({{2{o_qe[24]}}, o_qe}), .b(k_qe), .acc(o_acc), .p(p_qe));
    ft8_mac u_mqo (.clock(clk), .a({{2{o_qo[24]}}, o_qo}), .b(k_qo), .acc(o_acc), .p(p_qo));

    // results: pass 1 y = (even + odd + 2^19) >> 20; pass 2 C = (re / im + 2^16) >> 17.  Three small steps instead of one, because select,
    // add, shift and cut in one clock were 12 logic levels and did not meet timing: the sums; the sum of the pass (pass 1's shifted right by
    // 3: floor((floor(s / 8) + 2^16) / 2^17) = floor((s + 2^19) / 2^20), so both passes round at bit 17); and the rounding.  `out_valid` comes
    // 6 clocks after the last J2.
    reg         l1, l2, l3, fin_v, fin_w;
    reg  signed [47:0] sy_re, sy_im, sc_re, sc_im;
    reg  signed [47:0] sm_re, sm_im;
    wire signed [47:0] r_re = (sm_re + 48'sd65536) >>> 17;
    wire signed [47:0] r_im = (sm_im + 48'sd65536) >>> 17;
    always @(posedge clk) begin
        l1 <= o_last; l2 <= l1; l3 <= l2;
        fin_v <= l3 && !rst;                 // the sums are final in this clock's registers
        fin_w <= fin_v && !rst;
        sy_re <= p_ie + p_io;
        sy_im <= p_qe + p_qo;
        sc_re <= p_ie - p_qe;
        sc_im <= p_io + p_qo;
        sm_re <= p2 ? sc_re : (sy_re >>> 3);
        sm_im <= p2 ? sc_im : (sy_im >>> 3);
        out_word  <= {r_im[31:0], r_re[31:0]};
        out_valid <= fin_w && !rst;
    end

    // ================================================================ sequencers
    // FIR sequencer states, one-hot: FI idle (waiting for a q event), FM issue the 33 tap pairs, FW wait for the sum, FN write the newest
    // even q into the history, FO write the waiting odd q.
    wire [4:0]  ae_c = ue_c[5:1];
    wire [4:0]  ao_c = uo_c[5:1];
    wire [4:0]  da   = {ds[0], dn[4:1]};

    // Sequencers: the job start (`sq`), the pass 1 FIR sequencer (above), and for pass 2 the rotation of a symbol, the storing into the buffer, and
    // the DFT of the previous symbol (loops over bin t = 0 .. 7 and sample n = 0 .. 31, with the ROM index (t n) mod 32 stepping by t).
    always @(posedge clk) begin
        // addresses of the issue, loaded every clock (they matter only with an operand code)
        j_ae  <= p2 ? da : ae_c;
        j_ao  <= p2 ? da : ao_c;
        j_fc  <= fc;
        j_wi  <= wix;
        j_v   <= 1'b0;
        j_ce  <= 2'd0;
        j_co  <= 2'd0;
        we_e  <= 1'b0;
        we_o  <= 1'b0;
        mul_d1 <= 1'b0;
        mul_d2 <= mul_d1;
        y_rdy <= !rst && busy && p2 && rot_on && !y_stb && (rs < 7'd79) && (rs < dft_rel + 7'd2);
        if (rst) begin
            busy    <= 1'b0;
            fst     <= 5'd1 << FI;
            mul_run <= 1'b0;
            rot_on  <= 1'b0;
            d_on    <= 1'b0;
        end else if (sq) begin
            busy     <= 1'b1;
            p2       <= pass2;
            incr     <= inc;
            fst      <= 5'd1 << FI;
            u        <= 13'd31;
            kc       <= 12'd0;
            pend     <= 1'b0;
            tail     <= 1'b0;
            rs <= 7'd0; rn <= 5'd0; rot_done <= 7'd0; dft_rel <= 7'd0;
            ds <= 7'd0; dt <= 3'd0; dn <= 5'd0; wix <= 5'd0; d_on <= 1'b0;
            rot_on   <= 1'b0;
            // pass 2: phase of the first in-range sample, max(0, i0) x rinc
            mul_m    <= (i0 < 0) ? 12'd0 : i0[11:0];
            mul_a    <= inc;
            mul_n    <= 4'd0;
            mul_run  <= pass2;
        end else if (busy) begin
            // ---------------- pass 2 start phase (the sum lands two clocks after the last step)
            if (mul_run) begin
                mul_m <= mul_m >> 1;
                mul_a <= mul_a << 1;
                mul_n <= mul_n + 4'd1;
                if (mul_n == 4'd11) begin
                    mul_run <= 1'b0;
                    mul_d1  <= 1'b1;
                end
            end
            if (mul_d2) rot_on <= 1'b1;

            if (!p2) begin
                // ---------------- pass 1: FIR
                if (qe_v) u <= u + 13'd1;
                if (qe_v && qe_u == 13'd6033) tail <= 1'b1;
                if (fst[FI]) begin
                    if (qe_v) begin
                        if (qe_u[0]) begin
                            we_o <= 1'b1; wa_o <= qe_u[5:1];
                        end else if (!u_ge64) begin
                            we_e <= 1'b1; wa_e <= qe_u[5:1];
                        end else begin
                            un   <= qe_u;
                            ue_c <= qe_u;
                            uo_c <= qe_u - 13'd1;
                            fc   <= 6'd0;
                            fst  <= 5'd1 << FM;
                        end
                    end
                end
                if (fst[FM]) begin
                    // tap pair c: even tap 2c (c = 0: the newest q), odd tap 2c + 1
                    j_v     <= 1'b1;
                    j_first <= (fc == 6'd0);
                    j_last  <= (fc == 6'd32);
                    j_ce    <= (fc == 6'd0) ? 2'd2 : (ue_c < 13'd31) ? 2'd0 : 2'd1;
                    j_co    <= (fc == 6'd32 || uo_c < 13'd31) ? 2'd0 : 2'd1;
                    fc      <= fc + 6'd1;
                    ue_c    <= ue_c - 13'd2;
                    uo_c    <= uo_c - 13'd2;
                    if (fc == 6'd32) fst <= 5'd1 << FW;
                    if (qe_v) begin       // an odd q during the computation waits
                        pend <= 1'b1; pend_u <= qe_u;
                    end
                end
                if (fst[FW]) begin
                    if (qe_v) begin
                        pend <= 1'b1; pend_u <= qe_u;
                    end
                    if (fin_v) begin
                        kc  <= kc + 12'd1;
                        fst <= 5'd1 << FN;
                    end
                end
                if (fst[FN]) begin
                    we_e <= 1'b1; wa_e <= un[5:1];
                    if (qe_v) begin
                        pend <= 1'b1; pend_u <= qe_u;
                    end
                    fst <= (pend || qe_v) ? (5'd1 << FO) : (5'd1 << FI);
                    if (kc == 12'd3200 && !pend && !qe_v) busy <= 1'b0;
                end
                if (fst[FO]) begin
                    we_o <= 1'b1; wa_o <= pend_u[5:1];
                    pend <= 1'b0;
                    fst  <= 5'd1 << FI;
                    if (kc == 12'd3200) busy <= 1'b0;
                end
            end else begin
                // ---------------- pass 2: a word taken
                if (y_stb) begin
                    rn <= rn + 5'd1;
                    if (rn == 5'd31) rs <= rs + 7'd1;
                end
                // rotated sample into the symbol buffer
                if (zw) begin
                    // tag {n[4:0], buf, last}: entry {buf, n >> 1} of the memory of n's parity
                    if (zw_tag[2]) begin
                        we_o <= 1'b1; wa_o <= {zw_tag[1], zw_tag[6:3]};
                    end else begin
                        we_e <= 1'b1; wa_e <= {zw_tag[1], zw_tag[6:3]};
                    end
                    if (zw_tag[0]) rot_done <= rot_done + 7'd1;
                end
                // ---------------- pass 2: tone DFTs of the symbol ds
                if (!d_on && ds < 7'd79 && rot_done > ds) d_on <= 1'b1;
                if (d_on) begin
                    j_v     <= 1'b1;
                    j_first <= (dn == 5'd0);
                    j_last  <= (dn == 5'd31);
                    // zr from the I memory, zi from the Q memory, of n's parity
                    j_ce    <= dn[0] ? 2'd3 : 2'd1;
                    j_co    <= dn[0] ? 2'd1 : 2'd3;
                    wix     <= (dn == 5'd31) ? 5'd0 : wix + {2'd0, dt};
                    dn      <= dn + 5'd1;
                    if (dn == 5'd31) begin
                        dt <= dt + 3'd1;
                        if (dt == 3'd7) begin
                            ds      <= ds + 7'd1;
                            dft_rel <= dft_rel + 7'd1;
                            d_on    <= 1'b0;
                        end
                    end
                end
                if (fin_v) begin
                    kc <= kc + 12'd1;
                    if (kc == 12'd631) busy <= 1'b0;
                end
            end
        end
    end

endmodule
