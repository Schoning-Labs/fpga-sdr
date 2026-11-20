// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ft8_sync_div: a pipelined divider for the Costas sync score.
//
// What it computes
//   The sync search (ft8_sync.v) scores every frequency and time offset by comparing the energy at the tones of the Costas
//   pattern, t, with the energy of all seven tones at the same positions, t0: the score is the expected tone over the mean of
//   the other six.  With a division that is
//
//     q = min(floor(6 t x 2^16 / d), 2^32 - 1),   d = t0 - t + 6
//
//   (the +6 makes sure the divisor is never zero, and the 2^16 gives the quotient 16 fraction bits).  It is bit-exact with `score_fx`
//   in fw/tr-modes/src/frontend/sync.rs (docs/F6_SYNC.md section 2.2).  The input is t < 2^37 (21 spectrogram cells of up to
//   2^32) and d < 2^40 (147 cells).  A divider is needed because the alternative, comparing scores by cross-multiplying, would
//   need 80-bit products, and one divider that takes a new job every 8 clocks serves all lanes of the sync engine at once.
//
// Where it sits in the radio
//   Used by ft8_sync.v, which hands it (6 t, d) pairs and takes back the quotients in the same order.
//
// How it works
//   Saturation first: floor(N / d) >= 2^32 exactly when floor(N / 2^32) >= d, and with N = 6 t x 2^16 that is (6 t >> 16) >= d,
//   which the caller works out as `in_sat`.  Otherwise the quotient fits into 32 bits and is found by 32 steps of restoring long
//   division (the schoolbook method, done in binary: shift the next dividend bit into the remainder, subtract the divisor if
//   it fits, and that gives the next quotient bit).  It starts from the remainder R = 6 t >> 16, which is smaller than d, and
//   shifts in the 32 low bits of N, which are the low 16 bits of 6 t followed by 16 zeros.  The quotient bits are shifted into
//   the same register that the dividend bits leave, so one 32-bit register holds both.
//
//   Each step is a 41-bit compare-subtract and a select.  To meet timing a step takes two clocks, and no clock does more than a
//   select and a 21-bit carry chain (the 41-bit subtract with the select behind it, with its select net on 41 loads, was the
//   slowest path in the sync engine):
//     A  picks the last step's result (the difference or the old remainder, according to that step's registered `ge`, "greater
//        or equal"), shifts the next dividend bit in, and subtracts the low 21 bits;
//     B  subtracts the high 20 bits with the borrow and registers `ge`.
//   The pipeline is folded: four A/B pairs sit in a ring of 8 registers, a job enters at pair 0 and goes round the ring eight times
//   (4 steps per lap, 32 steps, 64 clocks).  The 8 slots of the ring each hold one job, so one job finishes every 8 clocks when the
//   ring is kept full.  Results leave in the order the jobs came in.
//
// Hand-over
//   The caller holds a job on `in_valid` with its data.  `in_take` (a register) is high for the one clock in which the job is
//   taken, and the data has to hold through that clock.  The decision is made one clock ahead, from the slot that will be free
//   then.  `in_room` is the caller's own condition (there is room for the result).
//
// Gowin specifics
//   Only adders and registers, no DSP and no block RAM; about 21-bit carry chains.

`timescale 1ns / 1ps

module ft8_sync_div #(
    // TAG_W: width of the tag that travels with each job, so that the caller knows which job a result belongs to.
    parameter integer TAG_W = 14,
    // PAIRS: A/B pairs in the ring, 4, 2 or 1.  With 4 a job can be taken every 8 clocks, with 2 or 1 every 16 or 32 clocks, for
    // half or a quarter of the registers, with the same steps and the same results in the same order.  Below, "pair 3" is the last pair
    // and "pair 2" the one before it (with one pair, the pair itself).
    parameter integer PAIRS = 4
) (
    // Clock (clk_dsp, 120 MHz) and synchronous reset (active high).
    input  wire              clk,
    input  wire              rst,

    // Job input: in_valid is held by the caller while it has a job, in_room says there is room for the result, and in_take (a register,
    // one clock) says the job is taken in this clock.  in_t6 is 6 t, in_d the divisor t0 - t + 6, in_sat the precomputed saturation
    // flag (6 t >> 16 >= d) and in_tag the tag that comes back with the result.
    input  wire              in_valid,
    input  wire              in_room,
    output reg               in_take /* synthesis syn_maxfan = 10000 */,
    input  wire [39:0]       in_t6,       // 6 t (t < 2^37)
    input  wire [39:0]       in_d,        // t0 - t + 6, never zero
    input  wire              in_sat,      // (6 t >> 16) >= d, precomputed by the caller: the quotient saturates
    input  wire [TAG_W-1:0]  in_tag,

    // Result: out_valid for one clock with the 32-bit quotient out_q and the job's tag, in the order the jobs came in.  in_flight is
    // the number of jobs inside.
    output reg               out_valid,
    output reg  [31:0]       out_q,
    output reg  [TAG_W-1:0]  out_tag,
    output wire [3:0]        in_flight
);

    // The ring.  The B registers of pair s feed the A stage of pair s + 1 (pair 3 feeds pair 0).  Each register group below carries one
    // job: bv (valid), bc (step count), br2 ({remainder, next dividend bit} before the subtract), bdl and bdh (the difference,
    // low 21 bits and high bits), bge (the step's subtract succeeded), bd (the divisor), bnb (the dividend bits still to come, with the
    // quotient bits shifted in behind them), bsat and btg (saturation flag and tag).
    wire              bv  [0:PAIRS-1];
    wire [4:0]        bc  [0:PAIRS-1];
    wire [40:0]       br2 [0:PAIRS-1];      // {remainder, next dividend bit} before the subtract
    wire [20:0]       bdl [0:PAIRS-1];      // difference, low 21 bits
    wire [19:0]       bdh [0:PAIRS-1];      // difference, bits 40:21
    wire              bge [0:PAIRS-1];
    wire [39:0]       bd  [0:PAIRS-1];
    wire [31:0]       bnb [0:PAIRS-1];      // dividend bits still to come, before this step's shift
    wire              bsat[0:PAIRS-1];
    wire [TAG_W-1:0]  btg [0:PAIRS-1];

    // PREV: the pair before the last.  fin: the last pair's step now is a job's 32nd, so the job finishes.  nfl counts the jobs in flight.
    localparam integer PREV = (2 * PAIRS - 2) % PAIRS;
    wire fin;                         // pair 3's step now is a job's 32nd
    reg  [3:0] nfl;
    assign in_flight = nfl;

    genvar s;
    generate
        for (s = 0; s < PAIRS; s = s + 1) begin : g_p
            localparam integer P = (s + PAIRS - 1) % PAIRS;
            // ---- A: select the last step's result, shift the next dividend bit in, subtract the low 21 bits
            // (the A registers below hold the intermediate values and the borrow out of the low half)
            wire [39:0] reff = bge[P] ? {bdh[P][18:0], bdl[P]} : br2[P][39:0];
            wire [40:0] r2n  = {reff, bnb[P][30]};
            wire [21:0] lsub = {1'b0, r2n[20:0]} - {1'b0, bd[P][20:0]};
            reg              av;
            reg [4:0]        ac;
            reg [40:0]       ar2;
            reg [20:0]       adl;
            reg              abw;
            reg [39:0]       ad;
            reg [31:0]       anb;
            reg              asat;
            reg [TAG_W-1:0]  atg;
            always @(posedge clk) begin
                av   <= bv[P] && !rst;
                ac   <= bc[P] + 5'd1;
                ar2  <= r2n;
                adl  <= lsub[20:0];
                abw  <= lsub[21];
                ad   <= bd[P];
                anb  <= {bnb[P][30:0], bge[P]};
                asat <= bsat[P];
                atg  <= btg[P];
            end
            // ---- B: high half with the borrow: a - b - bw = a + ~b + !bw, as one adder
            wire [20:0] ha   = {1'b0, ar2[40:21]};
            wire [20:0] hb   = {2'b00, ad[39:21]};
            wire [21:0] hsum = {ha, 1'b1} + {~hb, !abw};
            wire [20:0] hsub = hsum[21:1];              // bit 20: the subtract borrowed
            reg              rv;
            reg [4:0]        rc;
            reg [40:0]       rr2;
            reg [20:0]       rdl;
            reg [19:0]       rdh;
            reg              rge /* synthesis syn_maxfan = 10000 */;
            reg [39:0]       rd;
            reg [31:0]       rnb;
            reg              rsat;
            reg [TAG_W-1:0]  rtg;
            // Pair 3 (the last): this is where a new job enters the ring (in place of the slot that is empty or has just finished)
            // and where a finished job leaves.
            if (s == PAIRS - 1) begin : g_last
                assign fin = av && (ac == 5'd31);
                always @(posedge clk) begin
                    rdl <= adl;
                    rdh <= hsub[19:0];
                    if (in_take) begin
                        // a new job in place of the slot that is empty or has just finished;
                        // ge = 0 makes pair 0 start from rr2's remainder
                        rv   <= !rst;
                        rc   <= 5'd31;
                        rr2  <= {17'd0, in_t6[39:16]};
                        rge  <= 1'b0;
                        rd   <= in_d;
                        rnb  <= {1'b0, in_t6[15:0], 15'd0};
                        rsat <= in_sat;
                        rtg  <= in_tag;
                    end else begin
                        rv   <= av && !fin && !rst;
                        rc   <= ac;
                        rr2  <= ar2;
                        rge  <= !hsub[20];
                        rd   <= ad;
                        rnb  <= anb;
                        rsat <= asat;
                        rtg  <= atg;
                    end
                    out_valid <= fin && !rst;
                    out_q     <= asat ? 32'hFFFF_FFFF : {anb[30:0], !hsub[20]};
                    out_tag   <= atg;
                end
            end else begin : g_mid
            // The other pairs pass everything on.
                always @(posedge clk) begin
                    rv   <= av && !rst;
                    rc   <= ac;
                    rr2  <= ar2;
                    rdl  <= adl;
                    rdh  <= hsub[19:0];
                    rge  <= !hsub[20];
                    rd   <= ad;
                    rnb  <= anb;
                    rsat <= asat;
                    rtg  <= atg;
                end
            end
            assign bv[s]   = rv;
            assign bc[s]   = rc;
            assign br2[s]  = rr2;
            assign bdl[s]  = rdl;
            assign bdh[s]  = rdh;
            assign bge[s]  = rge;
            assign bd[s]   = rd;
            assign bnb[s]  = rnb;
            assign bsat[s] = rsat;
            assign btg[s]  = rtg;
        end
    endgenerate

    // Taking a job: the slot in pair 2's B registers is in pair 3's A registers in the next clock, with its step count one higher,
    // so it is free then when it is empty now or its count is 30 now.  in_take is therefore decided a clock ahead.
    always @(posedge clk) begin
        if (rst) begin
            in_take <= 1'b0;
            nfl     <= 4'd0;
        end else begin
            in_take <= in_valid && !in_take && in_room && (!bv[PREV] || (bc[PREV] == 5'd30));
            nfl     <= nfl + (in_take ? 4'd1 : 4'd0) - (fin ? 4'd1 : 4'd0);
        end
    end

endmodule
