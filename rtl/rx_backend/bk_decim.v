// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// bk_decim: the decimation stage of the receiver back end. It brings every receiver's stream
// from the bank's rate (48, 96, 192 or 384 ksps) down to 24 ksps with a cascade of up to four
// half-band filters, HB1 (384 to 192 ksps), HB2 (192 to 96), HB3 (96 to 48) and HB4 (48 to 24).
// A receiver whose input rate is 384 ksps uses all four, a receiver at 48 ksps only the last. One
// engine does the work of all 8 receivers, one job (one input sample) at a time. Model:
// fw/tr-dsp/src/backend/halfband.rs; the specification is docs/R4_BACKEND.md section 3.2. The
// terms are explained in docs/learn/GLOSSARY.md.
//
// What a half-band filter is: a low-pass FIR for decimation by 2 whose pass band ends at
// a quarter of its input sample rate, designed so that every second coefficient (except the
// center one, which is exactly 0.5) is zero. Only the non-zero taps need a multiply, so the
// early stages, which run at a high rate, take only 7 or 9 multiplies each (11 and 15 taps).
// The four stages have 11, 15, 23 and 63 taps (7, 9, 13 and 33 non-zero) with the same pass band
// of +/-9.6 kHz at every stage and a stop band that starts where the input would fold into
// that pass band (alias rejection 134.7, 136.8, 128.9 and 104.4 dB). The whole cascade rejects
// aliases at 113 dB (48 ksps in) to 118 dB (384 ksps in). The last stage is the expensive one
// since its transition band is the narrowest, and a pass band edge of 9.6 kHz instead of 10 kHz
// is what lets it fit 63 taps and a 64-word delay line. One coefficient table of 62 entries
// serves all four ratios.
//
// Arithmetic: coefficients are 26-bit numbers with 25 fraction bits (the center tap is exactly
// 0.5 = 2^24), samples 24 bits, products and sums are exact (under 52 bits), and the output is
// sat24((acc + 2^24) >> 25), which is the sum rounded to nearest and limited to 24 bits.
//
// Delay lines: one RAM of 8 receivers x 128 words of {I, Q} (24 bits each); per receiver HB1 uses
// words 0-15, HB2 16-31, HB3 32-63 and HB4 64-127, each used as a circular buffer. Coefficients:
// bk_hb.hex, 62 entries of {offset[5:0], Q25 coefficient[25:0]} written by
// tools/gen_rx_backend_tables.py, where the offset says how many samples back the tap reads. A
// tap that has not been written since the receiver was enabled reads as zero.
//
// How a job runs: the input sample is accepted and written into the first stage's delay line
// (2 clocks, plus 2 for decoding the job word). On every second sample of a stage (the stage
// keeps a phase bit that flips on every sample) that stage computes one output, taking its
// non-zero taps one per clock (7, 9, 13 or 33) plus 5 clocks of multiplier pipeline, and the
// output goes into the next stage in the same job. Two multipliers (I and Q, 24 x 26 bits) work
// in parallel. A receiver at 384 ksps costs about 5.4 M clocks per second, 8 of them 43 M of the
// 120 M available. The first sample after a receiver is enabled marks its four stages empty.
//
// Where it sits: bk_front.v feeds it through a FIFO and its output goes through another FIFO to
// bk_chfilt.v. Every output carries the epoch, receiver number and first-sample flag along with
// the sample.

`timescale 1ns / 1ps

module bk_decim #(
    parameter HB_FILE = "rtl/rx_backend/bk_hb.hex",
    parameter integer NRX = 8       // receivers built (rx_backend.v): the delay line and the stage state are sized by it
) (
    input  wire         clk,        // DSP clock
    input  wire         rst,        // synchronous reset

    input  wire         in_empty,   // input FIFO empty (in_data is valid while low)
    input  wire [52:0]  in_data,    // {epoch, rx[2:0], first, i[23:0], q[23:0]}
    output reg          in_pop,     // one-clock pulse: take the sample

    input  wire [7:0]   en,         // per receiver: enabled
    input  wire [7:0]   epoch,      // per receiver: current epoch bit (a sample of another epoch is dropped)
    input  wire [15:0]  in_rate,    // 2 bits per receiver: input rate 0 = 48, 1 = 96, 2 = 192, 3 = 384 ksps

    output reg          out_push,   // one push per 24 ksps sample
    output reg  [52:0]  out_data    // {epoch, rx[2:0], first, i[23:0], q[23:0]}
);
    `include "rtl/rx_backend/bk_consts.vh"

    // ---------------------------------------------------------------- coefficient ROM (LUTs)
    // The 62 table entries (stage 1 at 0..6, stage 2 at 7..15, stage 3 at 16..28, stage 4 at 29..61),
    // read in the clock that the tap is issued. The four functions below give the start, length
    // (number of non-zero taps), delay line size and delay line base address of a stage.
    (* syn_romstyle = "distributed_rom" *) reg [31:0] hb [0:BK_HB_ENTRIES-1];
    initial $readmemh(HB_FILE, hb);

    function [6:0] st_start;  input [1:0] s;
        case (s) 2'd0: st_start = BK_HB1_START; 2'd1: st_start = BK_HB2_START;
                 2'd2: st_start = BK_HB3_START; default: st_start = BK_HB4_START; endcase
    endfunction
    function [6:0] st_count;  input [1:0] s;
        case (s) 2'd0: st_count = BK_HB1_COUNT; 2'd1: st_count = BK_HB2_COUNT;
                 2'd2: st_count = BK_HB3_COUNT; default: st_count = BK_HB4_COUNT; endcase
    endfunction
    function [6:0] st_len;    input [1:0] s;
        case (s) 2'd0: st_len = BK_HB1_LEN; 2'd1: st_len = BK_HB2_LEN;
                 2'd2: st_len = BK_HB3_LEN; default: st_len = BK_HB4_LEN; endcase
    endfunction
    function [6:0] st_base;   input [1:0] s;
        case (s) 2'd0: st_base = 7'd0; 2'd1: st_base = 7'd16;
                 2'd2: st_base = 7'd32; default: st_base = 7'd64; endcase
    endfunction

    // bits of a receiver number in the memories' addresses: 1 for NRX <= 2, 2 for <= 4, 3 above (the rest of
    // the module keeps 3-bit receiver numbers; the top bits are 0 for the receivers that are built)
    localparam integer RW  = (NRX > 4) ? 3 : (NRX > 2) ? 2 : 1;
    localparam integer SMN = 4 << RW;                 // stage-state words: {receiver, stage}

    // ---------------------------------------------------------------- per (receiver, stage) state
    // Per (receiver, stage), index {rx, stage}: {phase, fill[6:0], wp[5:0]} in one 32-word LUT RAM.
    // phase says whether the next sample completes a pair (and so produces an output), fill is how
    // many words of the delay line hold data since the enable, and wp is the write pointer. `sv`
    // says the word counts: a receiver's first sample clears the flags of its four stages instead
    // of writing four words, and a word whose flag is clear reads as zero. One read per clock
    // (S_TAKE2: this stage, S_OUT: the next), one write (S_WR).
    reg [13:0] sm [0:SMN-1] /* synthesis syn_ramstyle = "distributed_ram" */;
    reg [SMN-1:0] sv = {SMN{1'b0}};
    integer    smi;
    initial for (smi = 0; smi < SMN; smi = smi + 1) sm[smi] = 14'd0;
    reg [7:0] first24;           // per receiver: the next 24 ksps output is the first after enable

    // ---------------------------------------------------------------- delay-line RAM
    reg         ram_we;
    reg  [RW+6:0] ram_waddr;
    reg  [47:0] ram_wdata;
    reg  [RW+6:0] ram_raddr;
    wire [47:0] ram_rdata;
    // 512 words or fewer: cut into slices of 18 bits (see bk_ram.v: three block RAMs instead of four)
    bk_ram #(.DW(48), .AW(RW+7), .SLICE(RW < 3 ? 18 : 0)) u_ram (
        .clk(clk), .we(ram_we), .waddr(ram_waddr), .wdata(ram_wdata),
        .raddr(ram_raddr), .rdata(ram_rdata)
    );

    // ---------------------------------------------------------------- MAC pipeline
    // edge 0: the tap word read from the coefficient ROM                      (iss0)
    // edge 1: RAM read address and the tap (coefficient, valid) registered   (iss1)
    // edge 2: RAM data out; tap moved along to line up with it                (iss2)
    // edge 3: operands registered inside bk_mul; edge 4: product; edge 5: accumulated
    // (edge 0 is its own clock because the ROM read, if it fed the read-address arithmetic in the
    // same clock, would be the slowest path of this block)
    // A tap whose offset reaches back further than the samples written so far reads as zero
    // (iss*_ok). The accumulators add one product per clock.
    reg               iss0_v;
    reg        [31:0] iss0_w;
    reg               iss1_v, iss2_v;
    reg signed [25:0] iss1_c, iss2_c;
    reg               iss1_ok, iss2_ok;
    wire signed [23:0] d_i = iss2_ok ? ram_rdata[47:24] : 24'sd0;
    wire signed [23:0] d_q = iss2_ok ? ram_rdata[23:0]  : 24'sd0;
    wire signed [50:0] p_i, p_q;
    bk_mul #(.AW(25), .BW(26)) u_mi (.clk(clk), .a({d_i[23], d_i}), .b(iss2_c), .p(p_i));
    bk_mul #(.AW(25), .BW(26)) u_mq (.clk(clk), .a({d_q[23], d_q}), .b(iss2_c), .p(p_q));
    reg [1:0] vpipe;                  // iss2_v delayed to line up with p_i / p_q
    reg signed [51:0] acc_i, acc_q;

    // ---------------------------------------------------------------- job FSM
    localparam S_IDLE = 3'd0, S_WR = 3'd1, S_MAC = 3'd2, S_WAIT = 3'd3, S_OUT = 3'd4,
               S_TAKE = 3'd5, S_OUT0 = 3'd6, S_TAKE2 = 3'd7;
    // The job state machine: S_IDLE waits for a job, S_TAKE and S_TAKE2 decode the job word, S_WR
    // writes the sample into the delay line, S_MAC issues the taps, S_WAIT drains the multiplier
    // pipeline, S_OUT0 rounds and S_OUT saturates and hands the result to the next stage or out.
    // one-hot (syn_encoding): see bk_chfilt.v
    (* syn_encoding = "onehot" *) reg [2:0] st;
    reg        acc_clr;             // clear the accumulators (set in S_WR, acted on a clock later)
    // out24 in two clocks: S_OUT0 rounds and shifts (rnd_i/rnd_q), S_OUT saturates
    reg signed [51:0] rnd_i, rnd_q;
    function signed [23:0] sat24;
        input signed [51:0] r;
        begin
            if (r > 52'sd8388607)       sat24 = 24'sd8388607;
            else if (r < -52'sd8388608) sat24 = -24'sd8388608;
            else                        sat24 = r[23:0];
        end
    endfunction
    reg [2:0]  rx;
    // copies of rx (syn_preserve) for the per-(receiver, stage) state: rx_w selects what S_WR
    // writes, rx_p what S_TAKE2/S_OUT fetch; one rx for all of it would have a fan-out of about
    // 260 and was too slow to route
    (* syn_preserve = 1 *) reg [2:0] rx_w, rx_p;
    reg        take_ok;              // S_TAKE -> S_TAKE2: the sample is for an enabled receiver
    reg        s_last;               // s == 3, kept with s (S_OUT's branch, without the compare)
    reg        ep;
    reg [1:0]  s;                     // current stage
    // copies of s for the per-(receiver, stage) state, to keep the fan-out low: s_w is what S_WR
    // writes, s_p what the fetches of wp, fill and phase read
    (* syn_preserve = 1 *) reg [1:0] s_w, s_p;
    reg signed [23:0] xi, xq;
    reg [5:0]  idx;                   // write index of the current sample
    reg [6:0]  t;                     // tap counter
    reg [3:0]  drain;
    wire [RW+1:0] sid = {rx[RW-1:0], s};

    // The job word is registered when it is popped (S_IDLE) and decoded over the next two clocks
    // (S_TAKE, S_TAKE2), and the (receiver, stage) state that S_WR needs is fetched into
    // wp_c/fill_c/phase_c in the clock before S_WR (in S_TAKE2 or S_OUT) instead of being read
    // through the 32-way muxes inside S_WR, which costs two clocks more per input sample. jr is
    // kept in flip-flops (syn_preserve): otherwise Gowin merges it into the input FIFO's block
    // RAM as its output register, and the RAM's slow clock-to-output then feeds the decode of
    // S_TAKE and is far too slow.
    (* syn_preserve = 1 *) reg [52:0] jr;
    reg [5:0]  wp_c;
    reg [6:0]  fill_c, fill_n;       // fill_n: the stage's fill after this sample, for the MAC
    reg        phase_c;
    reg        first_c;              // S_TAKE -> S_WR: reset the receiver's four stages
    wire [2:0] jrx  = jr[51:49];
    // each receiver's first stage (3 - in_rate) and whether it is also the last (rate 48 ksps),
    // registered from the setting instead of being worked out in S_TAKE; a rate change reaches
    // S_TAKE a clock later
    reg  [1:0] js_r [0:NRX-1];
    reg  [7:0] jl_r;
    integer    kj;
    always @(posedge clk)
        for (kj = 0; kj < NRX; kj = kj + 1) begin
            js_r[kj] <= 2'd3 - in_rate[kj*2 +: 2];
            jl_r[kj] <= in_rate[kj*2 +: 2] == 2'd0;
        end
    wire [1:0] js   = js_r[jrx];


    // the table address st_start(s) + t, kept as its own counter (ta) so the table read is
    // not behind an adder (the address fans out to every table LUT)
    reg  [6:0]  ta;
    wire [31:0] tap_w  = hb[ta];
    wire [5:0]  tap_off = iss0_w[31:26];
    wire [6:0]  lenm1  = st_len(s) - 7'd1;
    // the stage state memory: read (into wp_c / fill_c / phase_c only), and S_WR's write
    wire [RW+1:0] sra   = (st == S_OUT) ? {rx_p[RW-1:0], s_p + 2'd1} : {rx_p[RW-1:0], s_p};
    wire [13:0] srd     = sv[sra] ? sm[sra] : 14'd0;
    wire [6:0]  sm_fill = (fill_c != st_len(s)) ? fill_c + 7'd1 : fill_c;
    wire [5:0]  sm_wp   = (wp_c + 6'd1) & lenm1[5:0];
    always @(posedge clk)
        if (!rst && st == S_WR) sm[{rx_w[RW-1:0], s_w}] <= {!phase_c, sm_fill, sm_wp};

    integer k;
    always @(posedge clk) begin
        in_pop   <= 1'b0;
        out_push <= 1'b0;
        ram_we   <= 1'b0;
        iss0_v   <= 1'b0;
        iss1_v   <= iss0_v;
        iss2_v   <= iss1_v;
        if (iss0_v) begin
            iss1_c    <= iss0_w[25:0];
            iss1_ok   <= {1'b0, tap_off} < fill_n;
            ram_raddr <= {rx[RW-1:0], st_base(s) + {1'b0, (idx - tap_off) & lenm1[5:0]}};
        end
        iss2_c   <= iss1_c;
        iss2_ok  <= iss1_ok;
        vpipe    <= {vpipe[0], iss2_v};
        if (vpipe[1]) begin
            acc_i <= acc_i + p_i;
            acc_q <= acc_q + p_q;
        end
        acc_clr <= 1'b0;
        if (acc_clr) begin
            acc_i <= 52'sd0;
            acc_q <= 52'sd0;
        end
        if (rst) begin
            st <= S_IDLE;
            first24 <= 8'd0;
            vpipe <= 2'd0;
            iss0_v <= 1'b0;
            iss1_v <= 1'b0;
            iss2_v <= 1'b0;
        end else case (st)
            S_IDLE: if (!in_empty && !in_pop) begin
                in_pop <= 1'b1;
                jr <= in_data;
                st <= S_TAKE;
            end
            S_TAKE: begin
                rx   <= jrx;
                rx_w <= jrx;
                rx_p <= jrx;
                ep <= jr[52];
                xi <= jr[47:24];
                xq <= jr[23:0];
                s  <= js;
                s_w <= js;
                s_p <= js;
                s_last <= jl_r[jrx];
                first_c <= jr[48];
                take_ok <= en[jrx] && epoch[jrx] == jr[52];
                st <= S_TAKE2;
            end
            S_TAKE2: begin
                // (its own clock: the receiver's rate select, the stage number and the 32-way
                // fetch below would otherwise be one long path from the popped job word)
                if (!take_ok) begin
                    first_c <= 1'b0;
                    st <= S_IDLE;
                end else begin
                    if (first_c)
                        first24[rx] <= 1'b1;
                    wp_c    <= first_c ? 6'd0 : srd[5:0];
                    fill_c  <= first_c ? 7'd0 : srd[12:6];
                    phase_c <= first_c ? 1'b0 : srd[13];
                    st <= S_WR;
                end
            end
            S_WR: begin
                // first sample after enable: the receiver's four stages start empty (their
                // entry for this stage is written again just below, from wp_c/fill_c/phase_c,
                // which S_TAKE2 already set to the reset values)
                if (first_c) begin
                    for (k = 0; k < 4; k = k + 1)
                        sv[{rx_w[RW-1:0], k[1:0]}] <= 1'b0;
                end
                sv[{rx_w[RW-1:0], s_w}] <= 1'b1;       // this stage's word is written in this clock (below)
                first_c   <= 1'b0;
                ram_we    <= 1'b1;
                ram_waddr <= {rx[RW-1:0], st_base(s) + {1'b0, wp_c}};
                ram_wdata <= {xi, xq};
                idx       <= wp_c;
                fill_n    <= sm_fill;
                if (!phase_c) begin
                    st <= S_IDLE;                 // first of a pair: no output yet
                end else begin
                    t <= 7'd0;
                    ta <= st_start(s);
                    acc_clr <= 1'b1;
                    st <= S_MAC;
                end
            end
            S_MAC: begin
                iss0_v    <= 1'b1;
                iss0_w    <= tap_w;
                if (t == st_count(s) - 7'd1) begin
                    drain <= 4'd5;   // last tap accumulates 6 edges after issue (multiplier pipeline)
                    st <= S_WAIT;
                end
                t <= t + 7'd1;
                ta <= ta + 7'd1;
            end
            S_WAIT: begin
                if (drain == 4'd0)
                    st <= S_OUT0;
                drain <= drain - 4'd1;
            end
            S_OUT0: begin
                rnd_i <= (acc_i + 52'sd16777216) >>> 25;
                rnd_q <= (acc_q + 52'sd16777216) >>> 25;
                st <= S_OUT;
            end
            S_OUT: begin
                if (s_last) begin
                    out_push <= 1'b1;
                    out_data <= {ep, rx, first24[rx], sat24(rnd_i), sat24(rnd_q)};
                    first24[rx] <= 1'b0;
                    st <= S_IDLE;
                end else begin
                    s  <= s + 2'd1;
                    s_w <= s + 2'd1;
                    s_p <= s + 2'd1;
                    s_last <= (s == 2'd2);
                    xi <= sat24(rnd_i);
                    xq <= sat24(rnd_q);
                    wp_c    <= srd[5:0];
                    fill_c  <= srd[12:6];
                    phase_c <= srd[13];
                    st <= S_WR;
                end
            end
            default: st <= S_IDLE;
        endcase
    end
endmodule
