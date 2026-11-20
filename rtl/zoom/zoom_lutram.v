// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// zoom_lutram: a small memory in LUT RAM that meets the clock rate at more than 32 words
// (docs/ZOOM_IN_CHIP.md section 10, docs/TANG_LESSONS.md sections 3 and 6). LUT RAM is a memory built from
// the logic cells of the FPGA instead of from a block RAM, and it is fast for small sizes, but the
// address lines have to reach every cell. So the store is cut into lanes of LANE bits, and every lane has
// its own kept copy of the write strobe, the two addresses and its data, so no address bit drives more
// than the 2^(AW-4) LUT RAM cells of one lane. Used for the zoom context's arrival queue in
// rtl/spectrum/spectrum_pipeline.v (128 x 48 bits), which Gowin otherwise builds from 6,912 registers and
// a 128-way selection when it is read without a register.
//
//   write: we, wa, wd in clock t are in the memory from clock t + 2
//   read:  rq in clock u + 2 is the word at the ra of clock u

`timescale 1ns / 1ps

module zoom_lutram #(
    parameter integer AW   = 7,     // address bits (128 words)
    parameter integer W    = 48,    // bits per word
    parameter integer LANE = 4      // bits per lane (one RAM16SDP4 cell wide)
)(
    input  wire          clock,
    input  wire          we,        // write enable
    input  wire [AW-1:0] wa,        // write address
    input  wire [W-1:0]  wd,        // write data
    input  wire [AW-1:0] ra,        // read address
    output wire [W-1:0]  rq         // read data, 2 clocks after ra
) /* synthesis syn_srlstyle = "registers" */;

    localparam integer NL = (W + LANE - 1) / LANE;
    genvar g;
    generate
        for (g = 0; g < NL; g = g + 1) begin : lane
            localparam integer LO = g * LANE;
            localparam integer LB = (W - LO < LANE) ? W - LO : LANE;
            reg          we_q /* synthesis syn_preserve = 1 */;
            reg [AW-1:0] wa_q /* synthesis syn_preserve = 1 */;
            reg [AW-1:0] ra_q /* synthesis syn_preserve = 1 */;
            reg [LB-1:0] wd_q;
            reg [LB-1:0] q;
            reg [LB-1:0] mem [0:(1<<AW)-1] /* synthesis syn_ramstyle = "distributed_ram" */;
            integer k;
            initial begin
                we_q = 1'b0; wa_q = {AW{1'b0}}; ra_q = {AW{1'b0}}; wd_q = {LB{1'b0}}; q = {LB{1'b0}};
                for (k = 0; k < (1 << AW); k = k + 1) mem[k] = {LB{1'b0}};
            end
            always @(posedge clock) begin
                we_q <= we;
                wa_q <= wa;
                wd_q <= wd[LO +: LB];
                ra_q <= ra;
                if (we_q) mem[wa_q] <= wd_q;
                q <= mem[ra_q];
            end
            assign rq[LO +: LB] = q;
        end
    endgenerate

endmodule
