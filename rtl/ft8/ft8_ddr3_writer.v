// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ft8_ddr3_writer: a two-way arbiter for the FT8 front end's DDR3 write clients.
//
// It combines the traffic of ft8_slot_capture.v and ft8_ring_writer.v onto the single "ft8" client port of
// rtl/ddr3/ddr3_write_arbiter.v (its lowest-priority tier).  The slot capture wins ties: it is live real-time audio that
// would otherwise need buffering of its own to ride out being held off, while the spectrogram ring write already sits in
// ft8_ring_writer.v's own FIFO and can simply wait a beat longer.  The convention is the same as the write arbiter's: one
// client at a time until its burst's `done`.
//
// ft8_frontend.v itself uses the one-level four-way version ft8_ddr3_wmux4 in ft8_ddr3_mux.v, which is faster; this two-way
// version is kept for the stand-alone tests of the spectrogram engine.

`timescale 1ns / 1ps

module ft8_ddr3_writer #(
    parameter integer ADDR_WIDTH = 32
) (
    // Clock (clk_dsp, 120 MHz) and synchronous reset (active high).
    input  wire        clk,
    input  wire        rst,

    // -------- slot capture (higher priority): request, address, burst length, data, byte mask, and its grant and done --------
    input  wire        cap_req,
    input  wire [ADDR_WIDTH-1:0] cap_addr,
    input  wire [7:0]  cap_burstlen,
    input  wire [63:0] cap_wdata,
    input  wire [7:0]  cap_wmask,
    output wire        cap_gnt,
    output wire        cap_done,

    // -------- spectrogram ring writer (lower priority): the same signals --------
    input  wire        ring_req,
    input  wire [ADDR_WIDTH-1:0] ring_addr,
    input  wire [7:0]  ring_burstlen,
    input  wire [63:0] ring_wdata,
    input  wire [7:0]  ring_wmask,
    output wire        ring_gnt,
    output wire        ring_done,

    // -------- upstream: the write arbiter's FT8 client port --------
    output reg          req,
    output reg  [ADDR_WIDTH-1:0] addr,
    output reg  [7:0]   burstlen,
    output reg  [63:0]  wdata,
    output reg  [7:0]   wmask,
    input  wire          gnt,
    input  wire          done
);

    // The owner is a pair of registers, chosen one clock before anything is passed upstream: while idle, `req` upstream is 0.
    // Choosing combinationally while idle (`cap_req || !ring_req`) would have `req` of every client run through the selects
    // of all the levels into every other client's `gnt`, with 64 data bits behind it, which is too slow once several
    // of these are in a row (docs/FT8_PASS2.md section 8).  A burst now starts one clock later per level.  Because `req` only
    // shows upstream once the owner is latched, a grant in the first clock of `req` goes to the right client by construction.
    reg sel_cap  /* synthesis syn_maxfan = 10000 */;
    reg sel_ring /* synthesis syn_maxfan = 10000 */;

    // Request, address, length, data and mask come from the owner.
    always @* begin
        req      = (sel_cap && cap_req) || (sel_ring && ring_req);
        addr     = sel_ring ? ring_addr     : cap_addr;
        burstlen = sel_ring ? ring_burstlen : cap_burstlen;
        wdata    = sel_ring ? ring_wdata    : cap_wdata;
        wmask    = sel_ring ? ring_wmask    : cap_wmask;
    end

    // gnt and done go to the owner only.
    assign cap_gnt   = sel_cap  && gnt;
    assign ring_gnt  = sel_ring && gnt;
    assign cap_done  = sel_cap  && done;
    assign ring_done = sel_ring && done;

    // Owner selection: when idle the capture side wins a tie; released on `done`.

    always @(posedge clk) begin
        if (rst) begin
            sel_cap  <= 1'b0;
            sel_ring <= 1'b0;
        end else if (!sel_cap && !sel_ring) begin
            // idle: the capture side wins a tie
            sel_cap  <= cap_req;
            sel_ring <= ring_req && !cap_req;
        end else if (done) begin
            sel_cap  <= 1'b0;
            sel_ring <= 1'b0;
        end
    end

endmodule
