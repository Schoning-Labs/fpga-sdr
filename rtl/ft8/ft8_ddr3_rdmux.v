// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ft8_ddr3_rdmux: a two-way arbiter for the FT8 front end's DDR3 read clients.
//
// The read lane arbiter (rtl/ddr3/ddr3_read_arbiter.v) has one "rest" tier port, and the front end has three readers
// there: the slot reader (ft8_slot_reader.v, inside ft8_spectrogram.v), the row reader of the sync search (ft8_sync.v) and the
// replay and baseband reader of the candidate engine (ft8_cand.v).  Two of these in a chain merge them.  Port a wins ties (the
// slot reader first, because it has to keep up with the audio, then the sync search, whose results the candidate engine
// waits for, and the candidate engine last).  The convention is the same as ft8_ddr3_writer.v on the write side and the
// read arbiter itself: the owner is fixed from the moment its request is presented until its burst's `done`, and
// `rvalid`, `rdata` and `done` go only to the owner.  A burst in progress is never pre-empted.
//
// ft8_frontend.v itself uses the one-level three-way version ft8_ddr3_rmux3 in ft8_ddr3_mux.v, which is faster; this two-way
// version is kept for the stand-alone tests of the sync search.
`timescale 1ns / 1ps

module ft8_ddr3_rdmux #(
    parameter integer ADDR_WIDTH = 32
) (
    // Clock (clk_dsp, 120 MHz) and synchronous reset (active high).
    input  wire        clk,
    input  wire        rst,

    // Client a (higher priority): request, address, burst length, and its grant, read-valid, data and done.
    input  wire        a_req,
    input  wire [ADDR_WIDTH-1:0] a_addr,
    input  wire [7:0]  a_burstlen,
    output wire        a_gnt,
    output wire        a_rvalid,
    output wire [63:0] a_rdata,
    output wire        a_done,

    // Client b: the same, lower priority.
    input  wire        b_req,
    input  wire [ADDR_WIDTH-1:0] b_addr,
    input  wire [7:0]  b_burstlen,
    output wire        b_gnt,
    output wire        b_rvalid,
    output wire [63:0] b_rdata,
    output wire        b_done,

    // The upstream port, the read arbiter's "rest" tier: request, address, burst length, grant, and the read data stream with its done.
    output wire        req,
    output wire [ADDR_WIDTH-1:0] addr,
    output wire [7:0]  burstlen,
    input  wire        gnt,
    input  wire        rvalid,
    input  wire [63:0] rdata,
    input  wire        done
);

    // The owner is a pair of registers, chosen one clock before the request goes upstream (as in ft8_ddr3_writer.v, and
    // for the same reason: with two of these in a row, a choice made combinationally from the idle clients' `req` ran from
    // each client into the others' `gnt`).
    reg sel_a /* synthesis syn_maxfan = 10000 */;
    reg sel_b /* synthesis syn_maxfan = 10000 */;

    // Request, address and length come from the owner; gnt, rvalid and done go to the owner only; the data goes to both
    // (each client only looks at it when its own rvalid is high).
    assign req      = (sel_a && a_req) || (sel_b && b_req);
    assign addr     = sel_b ? b_addr : a_addr;
    assign burstlen = sel_b ? b_burstlen : a_burstlen;

    assign a_gnt    = sel_a && gnt;
    assign b_gnt    = sel_b && gnt;
    assign a_rvalid = sel_a && rvalid;
    assign b_rvalid = sel_b && rvalid;
    assign a_done   = sel_a && done;
    assign b_done   = sel_b && done;
    assign a_rdata  = rdata;
    assign b_rdata  = rdata;

    // Owner selection: idle, a wins a tie; released on `done`.

    always @(posedge clk) begin
        if (rst) begin
            sel_a <= 1'b0;
            sel_b <= 1'b0;
        end else if (!sel_a && !sel_b) begin
            // idle: a wins a tie
            sel_a <= a_req;
            sel_b <= b_req && !a_req;
        end else if (done) begin
            sel_a <= 1'b0;
            sel_b <= 1'b0;
        end
    end

endmodule
