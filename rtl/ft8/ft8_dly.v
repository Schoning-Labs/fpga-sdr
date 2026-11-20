// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ft8_dly and ft8_cfg8: two small memory helpers of the FT8 front end, both built from LUT RAM.
//
// ft8_dly: a delay of N clocks (3 <= N <= 16) for a word that only travels beside a pipeline: q(t) = d(t - N), every clock,
// with no enable and no reset.  A delay like this is usually a shift register, which costs N flip-flops per bit, and flip-flops
// fed by flip-flops are what the dense regions of the chip are made of (docs/ROUTE_DIAG.md section 6), which makes routing
// harder.  Here it is N words of LUT RAM (one cell per 4 bits) and the output register: the word written in clock t is read
// N - 1 clocks later, from the address that the write pointer reaches next, into `q`.  That is a ring of N words with two
// pointers, a write pointer and a read pointer that is one step ahead.
//
// It is written as a memory with two pointers and `syn_ramstyle`, and not left to the tool's own shift-register inference
// (docs/TANG_LESSONS.md section 8: that one shares a toggle between chains, or picks block RAM).  The read goes into a register
// and nowhere else (section 6).  The contents start as zeros.

`ifndef FT8_DLY_V
`define FT8_DLY_V
`timescale 1ns / 1ps

module ft8_dly #(
    // W: width of the delayed word in bits.  N: delay in clocks.
    parameter integer W = 8,
    parameter integer N = 4
) (
    // clk: clock.  d: the word to delay.  q: the same word N clocks later.
    input  wire         clk,
    input  wire [W-1:0] d,
    output reg  [W-1:0] q
) /* synthesis syn_maxfan = 10000 */;

    // Pointer width (2, 3 or 4 bits for up to 4, 8 or 16 words) and the last address of the ring.
    localparam integer AW = (N > 8) ? 4 : (N > 4) ? 3 : 2;
    localparam [AW-1:0] LAST = N - 1;
    // The ring of N words, and the write and read pointers (rp starts one ahead of wp).
    reg [W-1:0]  mem [0:N-1] /* synthesis syn_ramstyle = "distributed_ram" */;
    reg [AW-1:0] wp = {AW{1'b0}};
    reg [AW-1:0] rp = {{(AW-1){1'b0}}, 1'b1};
    integer i;
    initial begin
        for (i = 0; i < N; i = i + 1) mem[i] = {W{1'b0}};
        q = {W{1'b0}};
    end
    // Every clock: write the input at wp, read at rp into q, and advance both pointers with a wrap at N - 1.
    always @(posedge clk) begin
        mem[wp] <= d;
        q       <= mem[rp];
        wp      <= (wp == LAST) ? {AW{1'b0}} : wp + 1'b1;
        rp      <= (rp == LAST) ? {AW{1'b0}} : rp + 1'b1;
    end

endmodule

// ft8_cfg8: one setting of W bits per receiver (8 words of LUT RAM, written with the clock and read without one) with NR
// readers, each at its own receiver number.  That makes NR copies of the memory, written together.  The FT8 front end's ring
// bases used to be 8 x 27 flip-flops each, with an 8-way select in every engine that read them, and this replaces that.  A
// reader must take `rd` into a register and nowhere else (docs/TANG_LESSONS.md section 6).  The contents start as zeros.
module ft8_cfg8 #(
    // W: width of one setting.  NR: number of readers.
    parameter integer W  = 27,
    parameter integer NR = 2
) (
    // clk, we, wa and wd: write one word (wd) at receiver number wa when we is high.  ra: NR receiver numbers, 3 bits each,
    // one per reader.  rd: the NR words read, W bits each, with no clock (a LUT RAM read).
    input  wire            clk,
    input  wire            we,
    input  wire [2:0]      wa,
    input  wire [W-1:0]    wd,
    input  wire [3*NR-1:0] ra,
    output wire [W*NR-1:0] rd
);
    // One copy of the memory per reader, all written together.

    genvar k;
    generate
        for (k = 0; k < NR; k = k + 1) begin : g_r
            reg [W-1:0] mem [0:7] /* synthesis syn_ramstyle = "distributed_ram" */;
            integer i;
            initial for (i = 0; i < 8; i = i + 1) mem[i] = {W{1'b0}};
            always @(posedge clk) if (we) mem[wa] <= wd;
            assign rd[W*k +: W] = mem[ra[3*k +: 3]];
        end
    endgenerate
endmodule
`endif
