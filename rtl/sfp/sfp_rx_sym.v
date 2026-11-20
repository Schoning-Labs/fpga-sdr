// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Receive side of a raw transceiver lane: finds where the 10-bit symbols start in the incoming bit
// stream (comma alignment) and decodes them from 8b/10b into bytes (docs/SFP_LINKS.md 2.2). Everything
// runs on one clock, the lane's recovered word clock. It works for N = 1 (10-bit words, the lane that
// carries the HL2 at 1.25 Gbit/s) or N = 2 (20-bit words, the board link at 2.5 Gbit/s).
//
// Why alignment is needed, for a beginner: the transceiver's hard block hands the logic a word of 10
// (or 20) bits at a time, but it does not know where one 8b/10b symbol ends and the next begins,
// so the bits of a symbol can be spread over two consecutive words, shifted by any of 10 positions.
// The 8b/10b code solves that with the comma, a special 7-bit pattern (0011111 or 1100000 in the
// bits `abcdeif` of a symbol, which is the start of the control symbol K28.5) that cannot occur
// anywhere inside or between ordinary symbols. The sender puts a comma regularly (idle between frames
// is built from commas, and so is the negotiation), so the receiver looks for it at every bit position, takes
// the position at which it appears as the start of a symbol, and cuts the stream there.
//
// `din` is in line order: bit 0 was received first. The comma is looked for at every bit position p
// of the last two words. The aligned word starts at the comma, so with N = 2 the comma symbol is
// always the first of the pair (the sender puts K28.5 only there). Search: any comma sets the
// position, and three commas in a row at the position in use give lock. In lock, commas elsewhere are
// ignored. LOSS_ERRS invalid symbols (codes that do not exist in the 8b/10b alphabet, a sign of bit
// errors or of lost alignment) within 4,096 words drop the lock.
//
// The pipeline, one stage per clock with a valid flag moving along (v1 to v4):
//   stage 1  the last two words side by side, and a comma flag for each bit position (`hit`);
//   stage 2  the lowest position with a comma, and whether the comma is at the position in use;
//   stage 3  the lock state machine, and the words delayed to match;
//   stage 4  the aligned word, cut out of the two words at the chosen offset;
//   stage 5  the decoded symbols.
// Latency din to sym: 5 clocks. The pipeline registers carry no reset; `locked` gates what the user
// takes.

`timescale 1ns / 1ps

module sfp_rx_sym #(
    parameter integer N = 1,             // symbols per word: 1 (10 bits) or 2 (20 bits)
    parameter integer LOSS_ERRS = 16     // invalid symbols in a window of 4,096 words that drop the lock
) (
    input  wire            clk,          // the lane's recovered word clock
    input  wire            rst,          // synchronous: drops the lock
    input  wire            vld,          // din is a new word this clock
    input  wire [10*N-1:0] din,          // received word, line order (bit 0 first)
    output reg             sym_vld = 1'b0,   // the symbols below are new in this clock
    output reg  [8*N-1:0]  sym_d = {8*N{1'b0}},     // symbol 0 (first on the line) in bits 7:0
    output reg  [N-1:0]    sym_k = {N{1'b0}},       // 1: the symbol is a control (K) symbol
    output reg  [N-1:0]    sym_err = {N{1'b0}},     // not a code of the 8b/10b alphabet
    output reg             locked = 1'b0,           // the aligner has found and holds the symbol boundary
    output reg  [15:0]     cnt_loss = 16'd0         // times the lock was lost
) /* synthesis syn_srlstyle = "registers" */;

`include "tab_8b10b.vh"      // the 8b/10b tables; dec8b10b gives {valid, is_k, byte}

    localparam integer W = 10 * N;

    // ---- stage 1: the last two words, and a comma flag per bit position.
    // `comb` is the new word on top of the previous one. A comma at position g shows as seven bits
    // starting at bit g equal to 1111100 or 0000011 (written most significant bit first, which is the
    // reverse of the order on the line). `c1` to `c3` carry the two words along while the lock
    // logic decides the offset.
    reg  [W-1:0]   prev = {W{1'b0}};
    reg  [2*W-1:0] c1 = {2*W{1'b0}}, c2 = {2*W{1'b0}}, c3 = {2*W{1'b0}};
    reg  [W-1:0]   hit = {W{1'b0}};
    reg            v1 = 1'b0, v2 = 1'b0, v3 = 1'b0, v4 = 1'b0;
    wire [2*W-1:0] comb = {din, prev};
    wire [W-1:0]   hit_c;
    genvar g;
    generate
        for (g = 0; g < W; g = g + 1) begin : g_hit
            assign hit_c[g] = (comb[g+6:g] == 7'b1111100) || (comb[g+6:g] == 7'b0000011);
        end
    endgenerate

    // ---- stage 2: lowest position with a comma, found by a loop that runs from the top down, so the
    // lowest hit wins. `off` is the offset in use.
    reg [4:0] hpos = 5'd0;
    reg       hany = 1'b0, hat = 1'b0;      // a comma anywhere / at the position in use
    reg [4:0] off = 5'd0;
    integer i;
    reg [4:0] lowest;
    always @(*) begin
        lowest = 5'd0;
        for (i = W - 1; i >= 0; i = i - 1) if (hit[i]) lowest = i[4:0];
    end

    // ---- lock: `ccnt` counts commas in a row at the position in use, `win` counts words in the
    // error window, `errs` counts invalid symbols in it (it saturates at 16 through its top bit).
    reg [1:0]  ccnt = 2'd0;
    reg [11:0] win = 12'd0;
    reg [4:0]  errs = 5'd0;
    wire [1:0] nerr = (N == 2) ? ({1'b0, sym_err[0]} + {1'b0, sym_err[N-1]}) : {1'b0, sym_err[0]};

    // ---- stage 4: aligned word; stage 5: decoded symbols. The decoder wants a symbol with its first
    // bit on the line (`a`) at the top, so the bits of `al` are reversed on the way in.
    reg  [W-1:0] al = {W{1'b0}};
    wire [2*W-1:0] sh = c3 >> off;
    wire [9:0] dec0 = dec8b10b({al[0], al[1], al[2], al[3], al[4], al[5], al[6], al[7], al[8], al[9]});
    wire [9:0] dec1 = (N == 2) ? dec8b10b({al[W-10], al[W-9], al[W-8], al[W-7], al[W-6], al[W-5], al[W-4],
                                           al[W-3], al[W-2], al[W-1]}) : 10'd0;

    always @(posedge clk) begin
        v1 <= vld; v2 <= v1; v3 <= v2; v4 <= v3; sym_vld <= v4;
        if (vld) begin
            prev <= din;
            c1   <= comb;
            hit  <= hit_c;
        end
        if (v1) begin
            c2   <= c1;
            hpos <= lowest;
            hany <= |hit;
            hat  <= hit[off];
        end
        if (v2) c3 <= c2;
        if (v3) al <= sh[W-1:0];
        if (v4) begin
            sym_d[7:0] <= dec0[7:0]; sym_k[0] <= dec0[8]; sym_err[0] <= ~dec0[9];
            if (N == 2) begin
                sym_d[8*N-1:8*N-8] <= dec1[7:0]; sym_k[N-1] <= dec1[8]; sym_err[N-1] <= ~dec1[9];
            end
        end

        // Lock state, on the stage-2 flags. Not locked: a comma that is not at the position in use
        // moves the position and restarts the count, and three commas in a row at the position
        // lock it. Locked: invalid symbols are counted in a window of 4,096 words, and if LOSS_ERRS
        // of them are seen in one window the lock is dropped (and counted in cnt_loss).
        if (rst) begin
            locked <= 1'b0; ccnt <= 2'd0; errs <= 5'd0; win <= 12'd0;
        end else if (v2) begin
            if (!locked) begin
                errs <= 5'd0; win <= 12'd0;
                if (hany && !hat) begin
                    off  <= hpos;
                    ccnt <= 2'd0;
                end else if (hat) begin
                    if (ccnt == 2'd2) locked <= 1'b1;
                    else ccnt <= ccnt + 2'd1;
                end
            end else begin
                win <= win + 12'd1;
                if (win == 12'hFFF) errs <= 5'd0;
                else if (!errs[4]) errs <= errs + {3'd0, nerr};
                if (errs >= LOSS_ERRS[4:0]) begin
                    locked <= 1'b0; ccnt <= 2'd0;
                    cnt_loss <= cnt_loss + 16'd1;
                end
            end
        end
    end

endmodule
