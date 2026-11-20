// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Memory building blocks of the receiver back end (docs/R4_BACKEND.md). Three small modules:
//   bk_ram     simple dual-port RAM, one write port and one read port with a registered read,
//              inferred as block RAM. It holds the filter delay lines and the coefficient banks.
//   bk_cfgram  16 words of LUT RAM, read without a clock, for the per-receiver settings.
//   bk_dly     a delay of N clocks for a word that travels beside a pipeline.
// A beginner can think of all three as plain arrays; the reason for having three is that the
// Gowin tools map a big array with a registered read to block RAM, a small array that is read
// without a clock to LUT RAM, and a long chain of registers to a lot of flip-flops, and each of
// the three modules is written so that it maps to the cheapest resource that suits its job.

`timescale 1ns / 1ps

// bk_ram: reading the address that is written in the same cycle returns the old word; the
// engines of the back end never do that, so the behavior in that case does not matter.
module bk_ram #(
    parameter integer DW    = 48,           // bits per word
    parameter integer AW    = 10,           // address bits
    parameter integer DEPTH = 1 << AW,      // number of words
    // SLICE > 0 and DW > SLICE: the memory is cut into slices of SLICE bits. Gowin
    // builds a memory of 512 words or fewer from 32/36-bit block RAMs, two blocks each; a
    // 512 x 48 one took 4 blocks, cut as 18 + 18 + 12 it takes 3. Same contents, same latency.
    parameter integer SLICE = 0
) (
    input  wire          clk,
    input  wire          we,        // write enable
    input  wire [AW-1:0] waddr,     // write address
    input  wire [DW-1:0] wdata,     // word to write
    input  wire [AW-1:0] raddr,     // read address
    output wire [DW-1:0] rdata      // word read, one clock after raddr
);
    localparam integer NS = (SLICE > 0 && DW > SLICE) ? (DW + SLICE - 1) / SLICE : 1;   // number of slices
    genvar k;
    generate
        for (k = 0; k < NS; k = k + 1) begin : g_sl
            localparam integer LO = (NS == 1) ? 0 : k * SLICE;      // first bit of this slice
            localparam integer WS = (NS == 1) ? DW : ((DW - LO < SLICE) ? DW - LO : SLICE);   // its width
            reg [WS-1:0] mem [0:DEPTH-1];
            reg [WS-1:0] rd;
            always @(posedge clk) begin
                if (we)
                    mem[waddr] <= wdata[LO +: WS];
                rd <= mem[raddr];
            end
            assign rdata[LO +: WS] = rd;
        end
    endgenerate
endmodule

// ---------------------------------------------------------------------------------------------
// bk_cfgram: one setting of the eight receivers (or the bank table), 16 words of W bits in LUT
// RAM: written with the clock, read without one. An engine of the back end works on one receiver
// at a time, so it reads that receiver's word with the receiver number as the address, and the
// register block (rx_backend.v) writes the word when the firmware changes the setting. Every
// word starts with the register map's reset value (the bitstream's memory contents, as a
// flip-flop's start value is); rx_backend writes the same value again while its reset is held.
module bk_cfgram #(
    parameter integer W    = 16,            // bits per word
    parameter [31:0]  RSTV = 32'd0,         // reset value of the register this memory holds
    parameter integer LO   = 0          // the lowest bit of the register this memory holds
) (
    input  wire         clk,
    input  wire         we,         // write enable
    input  wire [3:0]   wa,         // write address (receiver number)
    input  wire [W-1:0] wd,         // word to write
    input  wire [3:0]   ra,         // read address (receiver number)
    output wire [W-1:0] rd          // word read, no clock needed
);
    reg [W-1:0] mem [0:15] /* synthesis syn_ramstyle = "distributed_ram" */;
    integer i;
    localparam [95:0] RSTX = {64'd0, RSTV};      // W may be wider than the 32-bit register (the 48-bit stamp)
    initial for (i = 0; i < 16; i = i + 1) mem[i] = RSTX[LO +: W];
    always @(posedge clk)
        if (we) mem[wa] <= wd;
    assign rd = mem[ra];
endmodule

// ---------------------------------------------------------------------------------------------
// bk_dly: a delay of N clocks (3 <= N <= 16) for a word that only travels beside a pipeline. It
// is built as N words of LUT RAM with a write pointer and a read pointer that run one step
// apart, plus the output register, instead of N registers for every bit, which saves a lot of
// flip-flops for wide words. This is the same circuit as ft8_dly in rtl/ft8/ft8_dly.v under
// another name, so that rtl/rx_backend does not depend on that file.
module bk_dly #(
    parameter integer W = 8,        // bits per word
    parameter integer N = 4         // delay in clocks
) (
    input  wire         clk,
    input  wire [W-1:0] d,          // word in
    output reg  [W-1:0] q           // the word that was in N clocks ago
) /* synthesis syn_maxfan = 10000 */;

    localparam integer AW = (N > 8) ? 4 : (N > 4) ? 3 : 2;      // pointer bits
    localparam [AW-1:0] LAST = N - 1;
    reg [W-1:0]  mem [0:N-1] /* synthesis syn_ramstyle = "distributed_ram" */;
    reg [AW-1:0] wp = {AW{1'b0}};                               // write pointer, cycles 0..N-1
    reg [AW-1:0] rp = {{(AW-1){1'b0}}, 1'b1};                   // read pointer, one step ahead of wp
    integer i;
    initial begin
        for (i = 0; i < N; i = i + 1) mem[i] = {W{1'b0}};
        q = {W{1'b0}};
    end
    always @(posedge clk) begin
        mem[wp] <= d;
        q       <= mem[rp];
        wp      <= (wp == LAST) ? {AW{1'b0}} : wp + 1'b1;
        rp      <= (rp == LAST) ? {AW{1'b0}} : rp + 1'b1;
    end

endmodule
