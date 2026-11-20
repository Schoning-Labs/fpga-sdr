// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// spectrum_walk_core: the column-walk engine that the full-band spectrum and the zoom spectrum share
// (docs/ARCHITECTURE.md 3.14 change C6d; docs/F2_SPECTRUM.md, docs/F3_ZOOM.md). After the FFT frames have
// been squeezed into display columns, the spectrum is averaged over K frames and turned into dB; both
// steps happen in a "walk" over all columns, one column per clock. One instance of this engine serves
// whichever of the two contexts (A the full-band spectrum, B the zoom) completes a frame next: it reads
// that context's per-frame column accumulator and its K-frame accumulator, combines them (accumulate,
// or peak-hold, which keeps the larger value), writes the K-frame accumulator back, and, on the K-th
// ("finalize") walk of a group, feeds rtl/spectrum/spectrum_ratio_db.v (the log-domain K-average) to
// produce one line's worth of 1/64 dB values. The terms are explained in docs/learn/GLOSSARY.md.
//
// This module owns none of the per-context memories (column buffer, K-frame accumulator, line buffer,
// column tables). The caller (rtl/spectrum/spectrum_pipeline.v) has two contexts' worth of those, addresses
// BOTH of them every cycle with this module's col_addr (cheap: an unused read on whichever context is not
// currently walking), and muxes the read data back in by active_ctx before presenting it here.
// Write-back (kacc_wr_*) and line output (line_*) carry their own context tag (kacc_wr_ctx, line_ctx),
// which the caller uses to demux them.
//
// Arbitration: a request is a level (req_x_valid), held by the caller from the moment a context's frame
// completes until this module grants it (grant_x, a 1-cycle pulse); see the per-context request holding
// logic in spectrum_pipeline.v, including its defensive retry for the case that a second frame completes
// before the first request is granted. Only one request is served at a time; ties (both valid in the
// same cycle) favor context A (the full-band spectrum, the higher-rate stream). The combined load is
// about 7 percent of clk_dsp, so contention is rare and a losing request simply waits one walk's worth
// of cycles, which is negligible next to either context's frame period.
//
// Latency from a column's read address (col_addr) to that column's K-frame write-back is 4 cycles:
// stage A latches the address, stage A2 gives the block RAM read data its own settling cycle, and
// stage B is split into B1 and B2 because the combine logic (a 48-bit add or compare and a select) is
// too long for one clock; from there to a finalize walk's dB output is spectrum_ratio_db.v's own
// 7-cycle latency. Throughput: one column issued per cycle, gap-free, so a full walk (NUM_COLS columns)
// plus pipeline drain takes NUM_COLS + about 12 cycles.

`timescale 1ns / 1ps

`include "rtl/spectrum/spectrum_ratio_db.v"

module spectrum_walk_core #(
    parameter integer NUM_COLS  = 1920,
    parameter integer ACCW1     = 44,     // per-frame column accumulator width
    parameter integer ACCW2     = 48,     // K-frame accumulator width
    parameter integer DIV_W     = 23,     // K x bins width
    parameter integer FRAC_BITS = 9,
    parameter integer LUT_W     = 12,
    parameter         TW_DIR    = "rtl/spectrum/tw/",
    localparam integer COLW     = $clog2(NUM_COLS)
) (
    input  wire clk,
    input  wire rst,

    // ---- request/grant (levels held by the caller; see module header) ----
    // finalize: this walk is the K-th of its group, so produce a dB line; first_of_group: this walk
    // starts a new group, so the K-frame accumulator takes the column value instead of adding to it;
    // peak_hold: keep the larger of the two values instead of summing; k_clamp: K, at least 1
    input  wire                req_a_valid,
    input  wire                req_a_finalize,
    input  wire                req_a_first_of_group,
    input  wire                req_a_peak_hold,
    input  wire [19:0]         req_a_k_clamp,
    output reg                 grant_a,           // one-clock pulse: request A has been accepted

    input  wire                req_b_valid,
    input  wire                req_b_finalize,
    input  wire                req_b_first_of_group,
    input  wire                req_b_peak_hold,
    input  wire [19:0]         req_b_k_clamp,
    output reg                 grant_b,

    output wire                busy,              // a walk is issuing column addresses
    output wire                active_ctx,        // 0 = A, 1 = B; valid while busy or draining

    // ---- column address issued to both contexts' memories; caller muxes the read data back ----
    output reg  [COLW-1:0]     col_addr,          // the column being issued, 0 .. NUM_COLS-1
    output reg                 col_addr_v,        // col_addr is valid

    input  wire [ACCW1-1:0]    cfa_rdata,         // 1-cycle latency behind col_addr, muxed by ctx
    input  wire [2:0]          bins_rdata,        // same latency, muxed by ctx
    input  wire [ACCW2-1:0]    kacc_rdata,        // same latency, muxed by ctx

    // ---- K-frame accumulator write-back; caller demuxes by active_ctx ----
    output wire                kacc_wr_v,         // write the K-frame accumulator
    output wire [COLW-1:0]     kacc_wr_addr,
    output wire [ACCW2-1:0]    kacc_wr_data,
    output wire                kacc_wr_ctx,       // the context this write-back belongs to

    // ---- line output; caller demuxes by active_ctx ----
    output wire                line_v,            // one dB value of a finished line
    output wire [COLW-1:0]     line_col,          // its column
    output wire signed [15:0]  line_db64,         // 1/64 dB
    output wire                line_last,         // with the last column of the line
    output wire                line_ctx           // the context this line output belongs to
) /* synthesis syn_srlstyle = "registers" */;

    // ================================================================
    // arbitration: one context walks at a time, A has priority on a tie
    // ================================================================
    reg              busy_r;
    reg              ctx_r;
    reg              finalize_r, first_of_group_r, peak_hold_r;
    reg  [19:0]      k_clamp_r;

    assign busy       = busy_r;
    assign active_ctx = ctx_r;

    wire walk_addr_last = (col_addr == NUM_COLS[COLW-1:0] - 1'b1);

    always @(posedge clk) begin
        grant_a <= 1'b0;
        grant_b <= 1'b0;
        if (rst) begin
            busy_r     <= 1'b0;
            col_addr   <= {COLW{1'b0}};
            col_addr_v <= 1'b0;
        end else if (!busy_r) begin
            col_addr_v <= 1'b0;
            if (req_a_valid) begin
                busy_r <= 1'b1; ctx_r <= 1'b0;
                finalize_r <= req_a_finalize; first_of_group_r <= req_a_first_of_group;
                peak_hold_r <= req_a_peak_hold; k_clamp_r <= req_a_k_clamp;
                col_addr <= {COLW{1'b0}}; col_addr_v <= 1'b1;
                grant_a <= 1'b1;
            end else if (req_b_valid) begin
                busy_r <= 1'b1; ctx_r <= 1'b1;
                finalize_r <= req_b_finalize; first_of_group_r <= req_b_first_of_group;
                peak_hold_r <= req_b_peak_hold; k_clamp_r <= req_b_k_clamp;
                col_addr <= {COLW{1'b0}}; col_addr_v <= 1'b1;
                grant_b <= 1'b1;
            end
        end else begin
            if (walk_addr_last) begin
                busy_r     <= 1'b0;
                col_addr_v <= 1'b0;
            end else begin
                col_addr <= col_addr + 1'b1;
            end
        end
    end

    // ================================================================
    // stage A: register the read (1 cycle after col_addr/col_addr_v)
    // cfa_rdata/bins_rdata/kacc_rdata are already 1 cycle behind col_addr (the caller's own registered
    // memory reads, addressed by col_addr), so this stage does NOT register them again: a_addr is latched
    // from col_addr with that same single cycle of delay, so a_addr and the read data line up directly.
    // Registering the read data a second time here would leave a_addr one cycle ahead of the data it
    // describes and corrupt every column but the first.
    // ================================================================
    reg              a_v, a_ctx;
    reg  [COLW-1:0]  a_addr;
    reg              a_finalize, a_first_of_group, a_peak_hold;
    reg  [19:0]      a_k_clamp;

    always @(posedge clk) begin
        a_v     <= rst ? 1'b0 : col_addr_v;
        a_addr  <= col_addr;
        a_ctx   <= ctx_r;
        a_finalize        <= finalize_r;
        a_first_of_group  <= first_of_group_r;
        a_peak_hold       <= peak_hold_r;
        a_k_clamp         <= k_clamp_r;
    end

    // ================================================================
    // stage A2: register the block RAM read data itself (cfa_rdata/bins_rdata/kacc_rdata), one cycle after
    // stage A latches the matching address. The block RAM's own read latency, landing directly on the
    // combine logic of stage B with no register in between, is too slow at the DSP clock rate. Every
    // signal here is a plain one-cycle pass-through: the data is registered for the first time, and the
    // address and flags are carried forward another cycle to match, so that data and address stay aligned.
    // ================================================================
    reg              a2_v, a2_ctx;
    reg  [COLW-1:0]  a2_addr;
    reg              a2_finalize, a2_first_of_group, a2_peak_hold;
    reg  [19:0]      a2_k_clamp;
    reg  [ACCW1-1:0] a2_cfa;
    reg  [ACCW2-1:0] a2_kacc;
    reg  [2:0]       a2_bins;

    always @(posedge clk) begin
        a2_v              <= rst ? 1'b0 : a_v;
        a2_addr           <= a_addr;
        a2_ctx            <= a_ctx;
        a2_finalize       <= a_finalize;
        a2_first_of_group <= a_first_of_group;
        a2_peak_hold      <= a_peak_hold;
        a2_k_clamp        <= a_k_clamp;
        a2_cfa            <= cfa_rdata;
        a2_kacc           <= kacc_rdata;
        a2_bins           <= bins_rdata;
    end

    // ================================================================
    // stage B: combine (accumulate or peak-hold), write K-frame accumulator, compute divisor
    // ================================================================
    function [ACCW2-1:0] sat_add2;
        input [ACCW2-1:0] x;
        input [ACCW2-1:0] y;
        reg [ACCW2:0] s;
        begin
            s = x + y;
            sat_add2 = s[ACCW2] ? {ACCW2{1'b1}} : s[ACCW2-1:0];
        end
    endfunction

    // Stage B is two clocks. B1 registers the saturating sum and the max compare side by side, and
    // B2 selects from registers (a 48-bit add or compare and the select in one clock, from the read
    // data of either context's memories, is too long). The divisor is K x (bins in the column), or 1
    // for peak hold.
    wire [ACCW2-1:0] cfa_ext = {{(ACCW2-ACCW1){1'b0}}, a2_cfa};

    wire [DIV_W-1:0] divisor_w = a2_peak_hold ? {{(DIV_W-1){1'b0}}, 1'b1}
                                               : (a2_k_clamp * {{(DIV_W-3){1'b0}}, a2_bins});

    reg  b1_v, b1_ctx;
    reg  [COLW-1:0] b1_addr;
    reg  [ACCW2-1:0] b1_cfa, b1_kacc, b1_sum;
    reg  b1_gt, b1_first_of_group, b1_peak_hold, b1_finalize;
    reg  [DIV_W-1:0] b1_divisor;
    always @(posedge clk) begin
        b1_v              <= rst ? 1'b0 : a2_v;
        b1_ctx            <= a2_ctx;
        b1_addr           <= a2_addr;
        b1_cfa            <= cfa_ext;
        b1_kacc           <= a2_kacc;
        b1_sum            <= sat_add2(a2_kacc, cfa_ext);
        b1_gt             <= a2_kacc > cfa_ext;
        b1_first_of_group <= a2_first_of_group;
        b1_peak_hold      <= a2_peak_hold;
        b1_finalize       <= a2_finalize;
        b1_divisor        <= divisor_w;
    end

    wire [ACCW2-1:0] kacc_combined = b1_first_of_group ? b1_cfa
                                    : (b1_peak_hold ? (b1_gt ? b1_kacc : b1_cfa) : b1_sum);

    reg  b_v, b_ctx;
    reg  [COLW-1:0] b_addr;
    reg  [ACCW2-1:0] b_kacc_combined;
    reg  [DIV_W-1:0] b_divisor;
    reg  b_finalize;
    always @(posedge clk) begin
        b_v             <= rst ? 1'b0 : b1_v;
        b_ctx           <= b1_ctx;
        b_addr          <= b1_addr;
        b_kacc_combined <= kacc_combined;
        b_divisor       <= b1_divisor;
        b_finalize      <= b1_finalize;
    end

    assign kacc_wr_v    = b_v;
    assign kacc_wr_addr = b_addr;
    assign kacc_wr_data = b_kacc_combined;
    assign kacc_wr_ctx  = b_ctx;

    // ================================================================
    // dB conversion (only fed during a finalize walk) + output column tag
    // ================================================================
    wire ratio_valid_in = b_v & b_finalize;

    spectrum_ratio_db #(
        .NUM_IW(ACCW2), .DEN_IW(DIV_W), .FRAC_BITS(FRAC_BITS), .LUT_W(LUT_W), .TW_DIR(TW_DIR)
    ) u_ratio (
        .clk(clk), .rst(rst),
        .valid_in(ratio_valid_in), .num_in(b_kacc_combined), .den_in(b_divisor),
        .valid_out(line_v), .db64_out(line_db64)
    );

    // Column tag: carried alongside the data through spectrum_ratio_db.v's own latency (a fixed
    // 7 cycles from valid_in to valid_out) instead of a free-running counter reset at walk start. This
    // is deliberate: with a shared engine, a new walk for the OTHER context can be granted as soon as
    // this one's column-address sequence ends (busy drops the cycle after the last address), which is
    // still several cycles before this walk's own last column has finished draining through
    // spectrum_ratio_db.v, so a counter reset by the new walk's grant pulse would corrupt the tags of
    // the old walk's still-in-flight tail columns. Carrying each column's own address through a
    // matching delay line has no such hazard: every line_col is exactly the address that produced it,
    // whatever any other walk is doing at the same time.
    //
    // The same goes for the context: steering the write-back and the line output by active_ctx would
    // be wrong, because active_ctx switches to the next walk's context two clocks after this walk's
    // last address, while this walk's last columns are still in the pipeline (a few write-backs and
    // about ten line outputs). Each column therefore carries its own context (kacc_wr_ctx, line_ctx).
    localparam integer RATIO_LATENCY = 7;
    reg [COLW-1:0] addr_dly [0:RATIO_LATENCY-1];
    reg [RATIO_LATENCY-1:0] ctx_dly;
    integer li;
    always @(posedge clk) begin
        addr_dly[0] <= b_addr;
        for (li = 1; li < RATIO_LATENCY; li = li + 1) addr_dly[li] <= addr_dly[li-1];
        ctx_dly <= {ctx_dly[RATIO_LATENCY-2:0], b_ctx};
    end

    assign line_col  = addr_dly[RATIO_LATENCY-1];
    assign line_ctx  = ctx_dly[RATIO_LATENCY-1];
    assign line_last = line_v & (line_col == NUM_COLS[COLW-1:0] - 1'b1);

endmodule
