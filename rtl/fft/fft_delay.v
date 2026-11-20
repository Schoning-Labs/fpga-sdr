// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// fft_delay: the delay line of one FFT butterfly stage (docs/F1_FFT.md). It advances only when
// `ce` is high, and `q` is the word that was written L enabled cycles ago, valid in the same
// cycle as `ce`. Counting enabled cycles and not clocks is what lets the FFT take samples with
// gaps: the delay line simply waits.
//
// Three implementations, chosen by the length: a plain register (L = 1), a chain of registers
// (L - 1 <= SR_MAX, short lines), or a simple dual-port RAM (longer ones, up to the 8,192 words of
// the first stage of the full-band FFT), which the Gowin tools map to block RAM, or to LUT RAM for
// 64 words or fewer. The terms are explained in docs/learn/GLOSSARY.md.
//
// The delay line sits in a loop in the butterfly (fft_bf.v): its output goes through an add and
// a select back into its own input every sample. So that this loop runs from flip-flop to
// flip-flop, the input is registered first (d_r, on `ce`) and the store behind it delays L - 1,
// and for the RAM version the read data is registered a second time (rd2). The delay is still
// exactly L enabled cycles, and the initial contents are zeros.
//
// RAM version in detail: a simple dual-port RAM of L words with one write port and one registered
// read port, plus the second register (rd2) behind the read. The word written at enabled cycle k
// (d_r = d(k - 1)) goes to address k mod L. `q` at enabled cycle m is rd2, loaded at the
// previous enabled cycle from rd, which must then hold address (m + 1) mod L (the word d(m - L)):
// so the read is issued at wp + 3 in an enabled cycle (wp still pointing at this cycle's write,
// m - 2) and at wp + 2 otherwise (wp = m - 1), however far apart the enabled cycles are. That
// address is written next at enabled cycle m + 1, after it is read. Read and write never hit
// the same address in one cycle (L >= 4; the RAM is used only for L > SR_MAX + 1).

`timescale 1ns / 1ps

module fft_delay #(
    parameter integer W      = 32,   // bits per word (a complex sample: twice the component width)
    parameter integer L      = 1024, // delay in enabled cycles
    parameter integer SR_MAX = 32,   // longest register chain
    parameter integer SR_LUT = 0,    // 1: the register chain (L - 1 <= SR_MAX) as LUT RAM
    parameter integer LUT_MAX_W = 64 // stores of this many words or fewer are LUT RAM, larger ones block RAM
) (
    input  wire         clk,
    input  wire         ce,         // clock enable: the line advances by one word on each enabled clock
    input  wire [W-1:0] d,          // word in
    output wire [W-1:0] q           // the word that was in L enabled cycles ago
);

    // syn_preserve: kept a flip-flop of its own (not merged into a RAM-based shift register)
    (* syn_preserve = 1 *) reg [W-1:0] d_r = {W{1'b0}};
    always @(posedge clk)
        if (ce)
            d_r <= d;

    generate
        if (L == 1) begin : g_one
            assign q = d_r;
        end else if (L == 2) begin : g_two
            (* syn_preserve = 1 *) reg [W-1:0] q_r = {W{1'b0}};
            always @(posedge clk)
                if (ce)
                    q_r <= d_r;
            assign q = q_r;
        end else if (L - 1 <= SR_MAX) begin : g_sr
            // the chain's last stage (q_r) is kept a flip-flop of its own too: Gowin builds the rest
            // of the chain as a block-RAM shift register, and its output is the start of the
            // butterfly's loop
            // SR_LUT = 1: LUT RAM, not block RAM; 6 to 30 words of up to 52 bits took 4
            // blocks each. (syn_srlstyle; syn_ramstyle is ignored on a chain Gowin turns into a
            // RAM itself.) Off by default: ft8_frame_core.v keeps its chains in flip-flops
            // by an attribute on its FFT instance, which an attribute here would override.
            (* syn_preserve = 1 *) reg [W-1:0] q_r = {W{1'b0}};
            integer i;
            if (SR_LUT != 0) begin : g_lut
                (* syn_srlstyle = "distributed_ram" *) reg [W-1:0] sr [0:L-3];
                initial for (i = 0; i < L - 2; i = i + 1) sr[i] = {W{1'b0}};
                always @(posedge clk) begin
                    if (ce) begin
                        sr[0] <= d_r;
                        for (i = 1; i < L - 2; i = i + 1) sr[i] <= sr[i-1];
                        q_r <= sr[L-3];
                    end
                end
            end else begin : g_blk
                reg [W-1:0] sr [0:L-3];
                initial for (i = 0; i < L - 2; i = i + 1) sr[i] = {W{1'b0}};
                always @(posedge clk) begin
                    if (ce) begin
                        sr[0] <= d_r;
                        for (i = 1; i < L - 2; i = i + 1) sr[i] <= sr[i-1];
                        q_r <= sr[L-3];
                    end
                end
            end
            assign q = q_r;
        end else begin : g_ram
            localparam integer AW = $clog2(L);
            // The store is cut into slices of at most 18 bits: Gowin builds a memory of
            // 512 words or fewer from 32/36-bit block RAMs, which place-and-route counts as two
            // blocks each (a 40-bit, 512-word store took 4 blocks, 3 cut as 18 + 18 + 4).
            // Same contents, same read latency.
            localparam integer SL = 18;
            localparam integer LUT_MAX = LUT_MAX_W;   // words (64 unless the instance says otherwise)
            localparam integer NS = (W + SL - 1) / SL;
            reg [AW-1:0] wp  = {AW{1'b0}};
            reg [W-1:0]  rd2 = {W{1'b0}};
            // wp + 2 and wp + 3 kept in registers of their own; the read address is then one
            // selection by ce (ce has 80 loads; with the two adders behind it the path into the
            // block RAM's address would be far too slow)
            reg  [AW-1:0] wp2 = 2, wp3 = 3;
            wire [AW-1:0] ra = ce ? wp3 : wp2;
            wire [W-1:0]  rd;                           // the memory's registered read
            genvar k;
            for (k = 0; k < NS; k = k + 1) begin : g_sl
                localparam integer LO = k * SL;
                localparam integer WS = (W - LO < SL) ? W - LO : SL;
                reg [WS-1:0] rds = {WS{1'b0}};
                integer i;
                if (L <= LUT_MAX) begin : g_l
                    // 64 words or fewer: LUT RAM, read into rds (a 64 x 46 store takes 4 blocks as block RAM)
                    (* syn_ramstyle = "distributed_ram" *) reg [WS-1:0] mem [0:L-1];
                    initial for (i = 0; i < L; i = i + 1) mem[i] = {WS{1'b0}};
                    always @(posedge clk) begin
                        if (ce)
                            mem[wp] <= d_r[LO +: WS];
                        rds <= mem[ra];
                    end
                end else begin : g_b
                    reg [WS-1:0] mem [0:L-1];
                    initial for (i = 0; i < L; i = i + 1) mem[i] = {WS{1'b0}};
                    always @(posedge clk) begin
                        if (ce)
                            mem[wp] <= d_r[LO +: WS];
                        rds <= mem[ra];
                    end
                end
                assign rd[LO +: WS] = rds;
            end
            always @(posedge clk) begin
                if (ce) begin
                    wp  <= wp + 1'b1;
                    wp2 <= wp2 + 1'b1;
                    wp3 <= wp3 + 1'b1;
                end
                if (ce)
                    rd2 <= rd;
            end
            assign q = rd2;
        end
    endgenerate

endmodule
