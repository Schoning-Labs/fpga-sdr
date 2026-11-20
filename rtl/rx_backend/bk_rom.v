// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// bk_rom: a read-only table with a registered read (the data appears one clock after the
// address), filled at start-up from a hex file. The back end uses it for the two tables of the
// AGC (bk_post.v): the log2 table (1,024 words of 12 bits) and the 2^x table that turns a gain in
// octaves back into a multiplier (1,024 words of 17 bits). The hex files are written by
// tools/gen_rx_backend_tables.py, which writes the same numbers into the software model, so the
// model and the RTL tables agree by construction. The path is relative to the simulator's
// working directory (the repository root for tools/check.sh).

`timescale 1ns / 1ps

module bk_rom #(
    parameter integer DW    = 12,                       // bits per word
    parameter integer AW    = 10,                       // address bits
    parameter integer DEPTH = 1 << AW,                  // number of words
    parameter         FILE  = "rtl/rx_backend/bk_log2.hex"   // one word per line, hexadecimal
) (
    input  wire          clk,
    input  wire [AW-1:0] addr,      // word to read
    output reg  [DW-1:0] data       // that word, one clock later
);
    reg [DW-1:0] mem [0:DEPTH-1];
    initial $readmemh(FILE, mem);
    always @(posedge clk)
        data <= mem[addr];
endmodule
