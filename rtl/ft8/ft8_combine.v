// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ft8_combine: the second half of the 3,840-point transform of a spectrogram frame, a sum of 15 twiddled products
// per bin.
//
// Background
//   ft8_frame_core.v explains how the 3,840-point transform is cut into 15 FFTs of 256 points, Y_n1 (n1 = 0 .. 14).  What is
//   left is to put them together:
//        A[k] = sum over n1 of  Y_n1[k mod 256] x W^(n1 k),     W = e^(-j 2 pi / 3840),  k = 256 k2 + k1,
//   where W^(n1 k) is a "twiddle factor", a complex number on the unit circle (glossary "Twiddle factor").  Only the bins
//   k = 0 .. 1,023 are kept (0 to 3,196.9 Hz), which is k2 = 0 .. 3, so the combine is 15 x 1,024 = 15,360 complex
//   multiply-accumulates per frame.  The result is bit-exact with the Rust model, `frame_bins_fx` and `power_word` in
//   `fw/tr-modes/src/frontend/spectrogram.rs`.
//
// What it does
//   It takes the 256-point FFT's output stream, one complex value Y_n1[k1] per event (`n1` the partial transform, `k1` its bin,
//   which is the FFT core's own `out_bin`), and for each of the 4 kept multiples k = 256 k2 + k1 (k2 = 0 .. 3) it adds
//   Y_n1[k1] x W^(n1 k) into a 1,024-entry accumulator.  The sums are accumulated as each partial transform's output arrives
//   instead of storing all 15 x 256 outputs first, which is possible because integer addition is exact, so the order
//   does not matter.  For n1 = 0 the fresh product is written directly (the accumulator's implicit zero) instead of
//   being added to a stale value left from the previous frame, so no separate 1,024-clock clearing pass is needed between frames.
//
// Where it sits in the radio
//   Fed by: ft8_frame_core.v (through its FIFO).  Feeds: ft8_power.v, which reads the finished sums through `rd_*`.
//
// How it works
//   One event expands internally into 4 pipelined sub-events (k2 = 0 .. 3), issued on consecutive clocks, and `ev_ready`
//   drops for those 4 clocks, so ft8_frame_core.v has to space events at least 4 clocks apart (it uses a wider fixed spacing).
//   The pipeline, counted from a sub-event's dispatch at clock T, with TWL = 9 the latency of the twiddle lookup
//   (ft8_tw3840.v): the twiddle arrives at T+1 .. T+TWL, the four partial products are registered at T+TWL+1, their sums at
//   T+TWL+2, the accumulator read is issued at T+TWL from the delayed address so that the old value is registered at T+TWL+2
//   as well, and the new sum is written at the end of that clock.  Two sub-events never touch the same accumulator address
//   within the pipeline's depth (the 4 addresses of one event are 256 apart, and the next visit to any of them is a whole
//   n1 pass, about 256 events, later), so no hazard handling is needed beyond this fixed alignment.
//
// Accumulator width
//   44 bits per component, one 88-bit word per bin (1,024 x 88 bit is five 1K x 18 block RAMs).  The tight bound is 44 bits
//   for any 16-bit input: |Y_n1[k]| is at most the sum of |u[n2]| over n2 plus the FFT's own rounding error (under 100 LSB),
//   the 15 partial transforms together cover the 1,920 window samples once, and every twiddle has magnitude at most 2^17.  So
//   |Re A| and |Im A| are at most (1,920 x 32,768 + 1,500) x 2^17 = 0.94 x 2^43, a 44-bit signed accumulator never wraps and
//   equals the model's 64-bit sum exactly.  A 46-bit one would cost one more block RAM (docs/F5_FT8SPEC.md section 4).
`timescale 1ns / 1ps
`include "rtl/ft8/ft8_tw3840.v"
`include "rtl/ft8/ft8_dly.v"

module ft8_combine #(
    // ROM_FILE: first-octant table of the 3,840-point twiddle factors (see ft8_tw3840.v).
    parameter ROM_FILE = "rtl/ft8/rom/ft8_w3840_oct.hex"
) (
    // Clock (clk_dsp, 120 MHz) and synchronous reset (active high).
    input  wire        clk,
    input  wire        rst,

    // One 256-point FFT output per event: ev_valid with ev_ready (taken when both are high), the partial transform ev_n1
    // (0 .. 14), its bin ev_k1 (0 .. 255) and the signed 24-bit real and imaginary parts.
    input  wire        ev_valid,
    output wire        ev_ready,
    input  wire [3:0]  ev_n1,      // 0 .. 14
    input  wire [7:0]  ev_k1,      // 0 .. 255 (the FFT core's out_bin)
    input  wire signed [23:0] ev_yr,
    input  wire signed [23:0] ev_yi,

    // Read-out of the finished sums (ft8_power.v), one bin per clock with rd_en and rd_addr, 1,024 in all.  There is no explicit
    // clear between frames (the rule that n1 = 0 writes instead of adding does that), and the read-out may only start after the
    // last event (see `idle`).  The memory has one read port and one write port, which the accumulate-read below shares with the
    // read-out through the mux on `rd_en`, so a read-out that overlaps a draining event would read each other's address.
    input  wire        rd_en,
    input  wire [9:0]  rd_addr,
    output reg  signed [43:0] rd_re,
    output reg  signed [43:0] rd_im,

    // High when no sub-event is anywhere in the pipeline (the event expander is idle and nothing is in flight between the twiddle
    // lookup and the accumulator write).  The caller has to wait for it before it starts a read-out, and not just for ev_ready,
    // which only means that the expander can take another event: the last event's four sub-events are still draining through the
    // twiddle lookup and the multiply-accumulate for a few more clocks after that.
    output wire        idle
);

    // ================================================================ event expander
    // busy is high while the 3 remaining sub-events of an event are issued, k2_cnt counts them, and the cur_* registers hold the event.
    // The sub_* registers are the sub-event being dispatched this clock: its partial transform, its bin k = 256 k2 + k1, the
    // sample and a "first" flag (n1 = 0, write instead of add).
    reg        busy;
    reg [1:0]  k2_cnt;
    reg [3:0]  cur_n1;
    reg [7:0]  cur_k1;
    reg signed [23:0] cur_yr, cur_yi;

    assign ev_ready = !busy;

    reg        sub_valid;
    reg [3:0]  sub_n1;
    reg [9:0]  sub_k;
    reg signed [23:0] sub_yr, sub_yi;
    reg        sub_first;

    always @(posedge clk) begin
        sub_valid <= 1'b0;
        if (rst) begin
            busy   <= 1'b0;
            k2_cnt <= 2'd0;
        end else if (ev_valid && ev_ready) begin
            busy    <= 1'b1;
            k2_cnt  <= 2'd0;
            cur_n1  <= ev_n1;
            cur_k1  <= ev_k1;
            cur_yr  <= ev_yr;
            cur_yi  <= ev_yi;
            sub_valid <= 1'b1;
            sub_n1    <= ev_n1;
            sub_k     <= {2'd0, ev_k1};       // k2 = 0 first
            sub_yr    <= ev_yr;
            sub_yi    <= ev_yi;
            sub_first <= (ev_n1 == 4'd0);
        end else if (busy) begin
            sub_valid <= 1'b1;
            sub_n1    <= cur_n1;
            sub_k     <= {k2_cnt + 2'd1, cur_k1};
            sub_yr    <= cur_yr;
            sub_yi    <= cur_yi;
            sub_first <= (cur_n1 == 4'd0);
            // k2_cnt == 2 means this clock dispatches k2 = k2_cnt + 1 = 3, the fourth and last sub-event (the acceptance
            // clock itself dispatched k2 = 0), so busy is cleared now.  Clearing it on k2_cnt == 3 would let this branch fire once
            // more and dispatch a spurious wrapped-around k2 = 0, which would double-count bin k1's accumulator on every event.
            if (k2_cnt == 2'd2) begin
                busy <= 1'b0;
            end
            k2_cnt <= k2_cnt + 2'd1;
        end
    end

    // ================================================================ twiddle lookup
    // The twiddle factor W^(n1 k) for the sub-event: 18 bit signed, real and imaginary part, TWL clocks later.
    wire tw_valid;
    wire signed [17:0] tw_wr, tw_wi;
    ft8_tw3840 #(.ROM_FILE(ROM_FILE)) u_tw (
        .clk(clk), .rst(rst),
        .in_valid(sub_valid), .n1(sub_n1), .k(sub_k),
        .out_valid(tw_valid), .wr(tw_wr), .wi(tw_wi)
    );

    // ================================================================ accumulator memory
    // One 88-bit word per bin ({im[43:0], re[43:0]}), 1,024 deep: five 1K x 18 BSRAM.
    reg [87:0] acc [0:1023];

    // Side channel, index = clocks after dispatch (sub_* is T+0).
    localparam integer TWL = 9;            // ft8_tw3840.v's LATENCY
    localparam integer MD  = TWL + 2;      // clock of the accumulator write
    reg [9:0]         k_d     [1:MD];
    reg               first_d [1:MD];
    reg               v_d     [1:MD];
    // The sample alongside the twiddle lookup, delayed by TWL clocks in a LUT-RAM delay (ft8_dly.v, 12 cells and 48 registers).  As
    // flip-flops it would be TWL x 48 registers, and left to the tool as a shift register it became two 32-bit-wide block RAMs,
    // which count 4 block RAMs.
    wire signed [23:0] yr_t, yi_t;         // sub_yr, sub_yi at T+TWL
    ft8_dly #(.W(48), .N(TWL)) u_yd (.clk(clk), .d({sub_yr, sub_yi}), .q({yr_t, yi_t}));
    integer di;
    // The side channel (address k, "first" flag and valid) travels along the same number of clocks, MD = TWL + 2.
    always @(posedge clk) begin
        k_d[1] <= sub_k;  first_d[1] <= sub_first;  v_d[1] <= sub_valid && !rst;
        for (di = 2; di <= MD; di = di + 1) begin
            k_d[di] <= k_d[di-1]; first_d[di] <= first_d[di-1]; v_d[di] <= v_d[di-1] && !rst;
        end
    end

    // A single read port, shared (muxed) between the accumulate-read (address k_d[TWL], data registered at T+TWL+1 and again at
    // T+TWL+2) and the read-out of ft8_power.v, so that the memory infers as one read port and one write port (the simple
    // dual-port primitive of the Gowin block RAM).  The caller keeps the two uses apart in time (the `idle` output).
    wire [9:0] rd_port_addr = rd_en ? rd_addr : k_d[TWL];
    reg [87:0] acc_q0, m_acc;
    always @(posedge clk) begin
        acc_q0 <= acc[rd_port_addr];
        m_acc  <= acc_q0;
    end

    // ================================================================ multiply-accumulate
    // Full 24 x 18-bit products (no rounding here, ft8_power.v rounds the finished sum).  A complex product
    // (yr + j yi)(wr + j wi) is yr wr - yi wi for the real part and yr wi + yi wr for the imaginary part: four
    // multiplications and two additions.
    reg signed [41:0] p_rr, p_ii, p_ri, p_ir;
    reg signed [42:0] prod_re, prod_im;
    always @(posedge clk) begin
        p_rr <= yr_t * tw_wr;              // T+TWL+1
        p_ii <= yi_t * tw_wi;
        p_ri <= yr_t * tw_wi;
        p_ir <= yi_t * tw_wr;
        prod_re <= p_rr - p_ii;            // T+TWL+2
        prod_im <= p_ri + p_ir;
    end

    // The accumulator update at the end of the pipeline: the old sum (or zero for n1 = 0) plus the product, written back to the same address.
    wire        m_valid = v_d[MD];
    wire [9:0]  m_k     = k_d[MD];
    wire        m_first = first_d[MD];
    wire signed [43:0] old_re = m_acc[43:0];
    wire signed [43:0] old_im = $signed(m_acc[87:44]);
    wire signed [43:0] new_re = m_first ? {prod_re[42], prod_re} : old_re + {prod_re[42], prod_re};
    wire signed [43:0] new_im = m_first ? {prod_im[42], prod_im} : old_im + {prod_im[42], prod_im};

    always @(posedge clk) begin
        if (m_valid) acc[m_k] <= {new_im, new_re};
    end

    // In-flight counter: +1 on each clock a sub-event is dispatched (sub_valid), -1 on each clock one commits (m_valid).  The block is idle
    // once it is back to 0 and the expander is not in the middle of an event either.  At most MD + 1 = 12 are in flight (one per clock).
    reg [3:0] inflight;
    always @(posedge clk) begin
        if (rst) begin
            inflight <= 4'd0;
        end else begin
            case ({sub_valid, m_valid})
                2'b10:   inflight <= inflight + 4'd1;
                2'b01:   inflight <= inflight - 4'd1;
                default: ;
            endcase
        end
    end
    assign idle = !busy && (inflight == 4'd0) && !sub_valid && !m_valid;

    // ================================================================ readout (ft8_power.v)
    // Two clocks of latency from rd_addr and rd_en to rd_re and rd_im: acc_q0 (the same read port as the accumulate-read above, steered
    // by rd_en's mux) holds the block RAM word one clock after rd_en, and this stage registers it out one clock after that.  ft8_power.v
    // issues one rd_en per clock and has two requests in flight to match.

    always @(posedge clk) begin
        rd_re <= acc_q0[43:0];
        rd_im <= $signed(acc_q0[87:44]);
    end

endmodule
