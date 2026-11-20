// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Behavioral stand-in for the `dcfifo` megafunction of Intel's Quartus (a dual clock FIFO), written so that the
// HL2's rawstream.v can be simulated here. rawstream.v is the HL2's own sample packer and instantiates `dcfifo`
// directly for its sample FIFO, and the vendor's simulation model (altera_mf.v) cannot be included through a
// relative path in this repo, so this file provides the small part of the interface that rawstream.v uses (showahead
// mode, 12 bit data, a power of two depth), reimplemented from the documented behavior of the megafunction and not
// copied from Intel's file. It is only for simulation, nothing under rtl/ refers to it, and it is included by
// tb_h1_link_rx.v and tb_h2_link_tx.v.
//
// Showahead semantics: `q` and `rdempty` show the oldest unread word as soon as it exists, without a read request first
// (a peek), and one read request for one read clock pops it, after which `q` shows the next word. The write
// and read pointers cross between the two clock domains as Gray code (only one bit changes per step, so a
// pointer sampled in the middle of a change is at worst one step old, never garbage), through two flip-flops
// each, the same pattern as rtl/hl2link/cdc_sample_fifo.v.

`timescale 1ns / 1ps

module dcfifo #(
    parameter intended_device_family = "Cyclone IV E",
    parameter lpm_numwords            = 16384,
    parameter lpm_showahead           = "ON",
    parameter lpm_type                = "dcfifo",
    parameter lpm_width               = 12,
    parameter lpm_widthu              = 15,
    parameter add_usedw_msb_bit       = "ON",
    parameter overflow_checking       = "ON",
    parameter underflow_checking      = "ON",
    parameter rdsync_delaypipe        = 4,
    parameter wrsync_delaypipe        = 4,
    parameter use_eab                 = "ON"
) (
    input  wire                     aclr,
    input  wire                     wrclk,
    input  wire                     wrreq,
    input  wire [lpm_width-1:0]     data,
    output wire                     wrfull,
    output wire                     wrempty,
    output wire [lpm_widthu-1:0]    wrusedw,

    input  wire                     rdclk,
    input  wire                     rdreq,
    output reg  [lpm_width-1:0]     q,
    output reg                      rdempty,
    output wire                     rdfull,
    output wire [lpm_widthu-1:0]    rdusedw
);

    localparam AW = lpm_widthu - 1;   // lpm_numwords = 2**AW
    localparam DEPTH = 32'd1 << AW;

    reg [lpm_width-1:0] mem [0:DEPTH-1];

    reg [AW:0] wr_bin = {(AW+1){1'b0}};
    reg [AW:0] wr_gray = {(AW+1){1'b0}};
    reg [AW:0] rd_bin = {(AW+1){1'b0}};
    reg [AW:0] rd_gray = {(AW+1){1'b0}};

    (* preserve *) reg [AW:0] rd_gray_wq1 = {(AW+1){1'b0}};
    (* preserve *) reg [AW:0] rd_gray_wq2 = {(AW+1){1'b0}};

    // wrfull means "full now" and is computed from registers only, as in the real megafunction. rawstream.v gates wrreq
    // with wrfull combinationally, so a wrfull derived from the pointer after this write would be a loop with no
    // register in it, which never settles once the FIFO is one word short of full.
    assign wrfull = (wr_gray == {~rd_gray_wq2[AW:AW-1], rd_gray_wq2[AW-2:0]});

    wire [AW:0] wr_bin_next = wr_bin + (wrreq & ~wrfull);
    wire [AW:0] wr_gray_next = wr_bin_next ^ (wr_bin_next >> 1);

    always @(posedge wrclk) begin
        if (aclr) begin
            wr_bin  <= {(AW+1){1'b0}};
            wr_gray <= {(AW+1){1'b0}};
        end else begin
            if (wrreq & ~wrfull) mem[wr_bin[AW-1:0]] <= data;
            wr_bin  <= wr_bin_next;
            wr_gray <= wr_gray_next;
        end
        rd_gray_wq1 <= rd_gray;
        rd_gray_wq2 <= rd_gray_wq1;
    end

    assign wrempty = (wr_gray == rd_gray_wq2);
    // rawstream.v never connects wrusedw (only rdusedw), so it is left undriven here, which saves a Gray to binary
    // conversion every write clock for a value that nothing reads.

    function [AW:0] gray2bin_w(input [AW:0] g);
        integer i;
        begin
            gray2bin_w[AW] = g[AW];
            for (i = AW - 1; i >= 0; i = i - 1) gray2bin_w[i] = g[i] ^ gray2bin_w[i+1];
        end
    endfunction

    // ---- read side: showahead (q/rdempty valid before rdreq; rdreq advances) ----
    (* preserve *) reg [AW:0] wr_gray_rq1 = {(AW+1){1'b0}};
    (* preserve *) reg [AW:0] wr_gray_rq2 = {(AW+1){1'b0}};

    // The read that happens in this cycle is taken into account before `rdempty` and `q` are updated, as in the real
    // showahead FIFO. rawstream.v keeps `rdreq` high while `rdempty` is low (in its R_OFF and R_FLUSH states), so a
    // `rdempty` computed from the pointer before this cycle's read would let it read one word past the end, the read
    // pointer would overtake the write pointer, and the FIFO would never look empty again.
    initial rdempty = 1'b1;   // aclr is tied low by rawstream.v, so this is the only reset
    wire        rd_do       = rdreq & ~rdempty;
    wire [AW:0] rd_bin_next = rd_bin + rd_do;
    wire [AW:0] rd_gray_next = rd_bin_next ^ (rd_bin_next >> 1);

    always @(posedge rdclk) begin
        if (aclr) begin
            rd_bin  <= {(AW+1){1'b0}};
            rd_gray <= {(AW+1){1'b0}};
            rdempty <= 1'b1;
        end else begin
            rd_bin  <= rd_bin_next;
            rd_gray <= rd_gray_next;
            rdempty <= (rd_gray_next == wr_gray_rq2);
            q       <= mem[rd_bin_next[AW-1:0]];
        end
        wr_gray_rq1 <= wr_gray;
        wr_gray_rq2 <= wr_gray_rq1;
    end

    assign rdusedw = gray2bin_w(wr_gray_rq2) - rd_bin;
    assign rdfull  = 1'b0;   // rawstream.v does not use rdfull

endmodule
