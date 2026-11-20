// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// bk_chfilt: the channel filter of the receiver back end, a complex FIR filter of up to 1,024
// taps that runs at 24 ksps and selects the part of the spectrum that the listener wants (an SSB
// sideband from 300 to 2,700 Hz, a 300 Hz CW filter around the pitch, an AM or FM channel). One
// unit serves 4 receivers (unit 0 receivers 0-3, unit 1 receivers 4-7), doing one tap per clock
// with four 24 x 32 multipliers (one GW5A DSP block each, in its 27 x 36 mode). Model:
// fw/tr-dsp/src/backend/chfilt.rs; specification: docs/R4_BACKEND.md section 3.3. The terms
// are explained in docs/learn/GLOSSARY.md.
//
// What it computes: y[k] = sum over n of c[n] x[k-n], where the data x (24 bits) and the
// coefficients c are both complex. Per tap that is a complex multiply, which takes four real
// multiplies and two adds: re = cr xr - ci xi and im = cr xi + ci xr. Because the coefficients
// are complex, the response does not have to be symmetric around 0 Hz, so one filter can keep
// the upper sideband and reject the lower one, which a real filter cannot. The firmware designs
// the coefficients (tr_dsp::backend::design) and writes them through the coefficient window.
//
// Coefficient format: 32-bit real and 32-bit imaginary part, plus one exponent `exp` (0 to 15)
// for the whole bank, so the value is c x 2^-(30 + exp). The firmware picks the largest exp that
// keeps every coefficient in 32 bits, so narrow filters keep full precision (a 300 Hz CW filter
// uses exp 6). 32 bits are needed because with 18-bit coefficients the opposite sideband of a
// USB filter would only be 90 dB down against 140 dB for the floating point design.
//
// Arithmetic: each of the four 56-bit products is truncated by 16 bits (floor), the real and
// imaginary sums are formed and added into 52-bit accumulators, which cannot overflow (at most
// 2^49 after 1,024 taps). The output is sat24((acc + 2^(13+exp)) >> (14+exp)), which is the
// sum scaled back, rounded to nearest and limited to 24 bits.
//
// Memories: the delay lines (4 receivers x 1,024 words of {I, Q}, 24 bits each) and a coefficient
// pool of 6 banks x 1,024 taps x {re, im} 32 bits. The CPU writes the pool through the coefficient
// window (a second RAM port), the MAC reads it. A receiver's bank_sel register is latched when
// its job starts, so a switch of filter takes effect exactly between two output samples. The
// firmware writes a new filter into a bank that none of the unit's receivers uses and then
// writes bank_sel, which gives glitch-free switching with 6 banks for 4 receivers; receivers
// may also share one bank (all FT8 receivers of a unit, for example).
//
// Cost: ntaps + 16 clocks per 24 ksps sample; 4 receivers with 1,024 taps take 99 M of the 120 M
// clocks per second (83 percent of the unit).
//
// Where it sits: bk_decim.v feeds it through a FIFO and its output goes through another FIFO to
// bk_post.v (demodulator, AGC, S-meter).

`timescale 1ns / 1ps

module bk_chfilt #(
    // receivers this unit serves, 1 to 4 (rx_backend.v: NRX - 4 * unit, at most 4): the delay line holds
    // 2 receivers' worth for 1 or 2, 4 for 3 or 4 (its address is {receiver, tap}; a power of two)
    parameter integer NRU = 4
) (
    input  wire         clk,        // DSP clock
    input  wire         rst,        // synchronous reset

    input  wire         in_empty,   // input FIFO empty (in_data is valid while low)
    input  wire [52:0]  in_data,    // {epoch, rx[2:0], first, i[23:0], q[23:0]}
    output reg          in_pop,     // one-clock pulse: take the sample

    input  wire [3:0]   en,         // this unit's 4 receivers
    input  wire [3:0]   epoch,      // their current epoch bits
    input  wire [11:0]  bank_sel,   // 3 bits per receiver
    output wire [2:0]   cfg_bank,   // the bank whose settings are wanted (of this unit's 6)
    input  wire [10:0]  bank_ntaps, // that bank's, from rx_backend's memory: number of taps
    input  wire [3:0]   bank_exp,   // that bank's coefficient exponent

    input  wire         coef_we,    // coefficient window write
    input  wire [2:0]   coef_bank,  // bank written
    input  wire [9:0]   coef_tap,   // tap number written
    input  wire         coef_im,    // 0 = real part, 1 = imaginary part
    input  wire [31:0]  coef_data,  // coefficient word

    output reg          out_push,   // one push per filtered sample
    output reg  [52:0]  out_data,   // {epoch, rx[2:0], first, re[23:0], im[23:0]}
    output reg  [11:0]  bank_cur    // bank used for the last sample, 3 bits per receiver
);
    // ---------------------------------------------------------------- memories
    localparam integer RW = (NRU > 2) ? 2 : 1;      // bits of the unit's receiver number
    reg         d_we;
    reg  [RW+9:0] d_waddr;
    reg  [47:0] d_wdata;
    reg  [RW+9:0] d_raddr;
    wire [47:0] d_rdata;
    bk_ram #(.DW(48), .AW(RW+10)) u_delay (
        .clk(clk), .we(d_we), .waddr(d_waddr), .wdata(d_wdata), .raddr(d_raddr), .rdata(d_rdata)
    );

    // Coefficient pool: one 1,024 x 32 RAM per bank and part (re/im) rather than one 6,144-deep
    // RAM per part. Gowin synthesis rounds a 6,144-deep memory up to 8,192 (16 BSRAM per part
    // instead of 12), so the six banks are separate RAMs read at the
    // same tap address, and the bank index, delayed to line up with the registered read, picks
    // the output.
    reg  [12:0] c_raddr;
    wire [12:0] c_waddr = {coef_bank, coef_tap};
    wire [6*32-1:0] c_re_b, c_im_b;
    reg  [2:0]  c_rbank;
    genvar gb;
    generate
        for (gb = 0; gb < 6; gb = gb + 1) begin : cbank
            bk_ram #(.DW(32), .AW(10)) u_cre (
                .clk(clk), .we(coef_we && !coef_im && coef_bank == gb), .waddr(coef_tap),
                .wdata(coef_data), .raddr(c_raddr[9:0]), .rdata(c_re_b[gb*32 +: 32])
            );
            bk_ram #(.DW(32), .AW(10)) u_cim (
                .clk(clk), .we(coef_we && coef_im && coef_bank == gb), .waddr(coef_tap),
                .wdata(coef_data), .raddr(c_raddr[9:0]), .rdata(c_im_b[gb*32 +: 32])
            );
        end
    endgenerate
    // each bank's output registered as it leaves its RAM (c_re_q/c_im_q), then the bank picked
    reg  [2:0]      c_rbank2;
    // (c_rbank2 in copies, one per 16 output bits; as one register its decode would fan out to
    // 64 bits and be too slow)
    // The selected bank's output is formed 16 bits at a time (rb0..rb3), and a bank number of 6
    // or 7 (none exists) selects zero.
    (* syn_preserve = 1 *) reg [11:0] c_rbank2c;
    reg  [6*32-1:0] c_re_q, c_im_q;
    always @(posedge clk) begin
        c_rbank  <= c_raddr[12:10];
        c_rbank2 <= c_rbank;
        c_rbank2c <= {4{c_rbank}};
        c_re_q   <= c_re_b;
        c_im_q   <= c_im_b;
    end
    wire [2:0] rb0 = c_rbank2c[2:0], rb1 = c_rbank2c[5:3], rb2 = c_rbank2c[8:6], rb3 = c_rbank2c[11:9];
    wire [31:0] c_re_m = {(rb1 < 3'd6) ? c_re_q[rb1*32 + 16 +: 16] : 16'd0,
                          (rb0 < 3'd6) ? c_re_q[rb0*32 +: 16] : 16'd0};
    wire [31:0] c_im_m = {(rb3 < 3'd6) ? c_im_q[rb3*32 + 16 +: 16] : 16'd0,
                          (rb2 < 3'd6) ? c_im_q[rb2*32 +: 16] : 16'd0};

    // ---------------------------------------------------------------- MAC pipeline
    // edge 1: read addresses and tap-valid registered; edge 2: data and coefficients out of the
    // RAMs; edge 3: the RAM outputs registered; edge 4: the coefficient bank picked and the
    // sample (or 0) registered; edge 5: operands registered in bk_mul; edge 6: products; edge 7:
    // the two sums of truncated products registered; edge 8: accumulated. (Edges 3 and 4 are
    // their own clocks, since RAM output, bank select and multiplier input in one clock would be
    // a path that is too long.)
    reg        iss1_v, iss2_v, iss1_ok, iss2_ok, iss3_ok;
    reg [47:0] d_q;
    reg signed [23:0] xr, xi;
    reg        [31:0] c_re, c_im;
    always @(posedge clk) begin
        d_q     <= d_rdata;
        iss3_ok <= iss2_ok;
        xr   <= iss3_ok ? d_q[47:24] : 24'sd0;
        xi   <= iss3_ok ? d_q[23:0]  : 24'sd0;
        c_re <= c_re_m;
        c_im <= c_im_m;
    end
    wire signed [55:0] p_rr, p_ii, p_ri, p_ir;
    bk_mul #(.AW(24), .BW(32)) u_m0 (.clk(clk), .a(xr), .b(c_re), .p(p_rr));
    bk_mul #(.AW(24), .BW(32)) u_m1 (.clk(clk), .a(xi), .b(c_im), .p(p_ii));
    bk_mul #(.AW(24), .BW(32)) u_m2 (.clk(clk), .a(xi), .b(c_re), .p(p_ri));
    bk_mul #(.AW(24), .BW(32)) u_m3 (.clk(clk), .a(xr), .b(c_im), .p(p_ir));
    // each product truncated by 16 bits (floor) before the sums, so that the accumulator stays at 52 bits
    wire signed [39:0] t_rr = p_rr >>> 16, t_ii = p_ii >>> 16, t_ri = p_ri >>> 16, t_ir = p_ir >>> 16;
    reg signed [40:0] sum_r, sum_i;
    reg [4:0] vpipe;
    reg signed [51:0] acc_r, acc_i;
    reg        acc_clr;             // clear the accumulators (set in S_WR, acted on a clock later)

    // ---------------------------------------------------------------- per receiver state
    // wp is the write pointer of the receiver's delay line and fill counts how many words have been
    // written since the enable (a tap that reaches back further than that reads as zero)
    reg [9:0]  wp   [0:NRU-1];
    reg [10:0] fill [0:NRU-1];

    // ---------------------------------------------------------------- job FSM
    localparam S_IDLE = 4'd0, S_WR = 4'd1, S_MAC = 4'd2, S_WAIT = 4'd3, S_OUT = 4'd4,
               S_RND1 = 4'd5, S_RND2 = 4'd6, S_RND3 = 4'd7, S_RND4 = 4'd8, S_WR2 = 4'd9;
    // The state machine of a job: S_IDLE takes a sample from the FIFO, S_WR writes it into the
    // delay line, S_WR2 and S_MAC issue the taps (one per clock), S_WAIT lets the multiplier
    // pipeline drain, S_RND1..S_RND4 wait for the rounding pipeline and S_OUT pushes the result.
    // one-hot (syn_encoding): the state drives the load enables of most registers here, and a
    // binary decode of it for each was a critical path
    (* syn_encoding = "onehot" *) reg [3:0] st;
    reg [2:0]  rx;
    reg        ep, first;
    // the input FIFO's output, registered every clock: in S_WR it holds the entry S_IDLE popped
    // (its sample goes straight into the delay-line write data, with no load enable)
    reg [52:0] jr;
    reg [2:0]  bank;
    reg [10:0] ntaps, nt_raw;
    // ex, the bank's output exponent, in four copies for the rounding pipeline (as one register
    // its fan-out of 98 took 4.4 ns of routing): ex_c[3:0] the bias, [7:4] rnd2_r, [11:8] rnd2_i,
    // [15:12] rnd3
    (* syn_preserve = 1 *) reg [15:0] ex_c;
    reg [9:0]  idx;
    reg [10:0] n;
    reg [3:0]  drain;
    wire [1:0] lrx = rx[1:0];

    // Output rounding and saturation, out24(a, e) = sat24((a + 2^(13+e)) >>> (14+e)): done in
    // one clock it would be the slowest path of this block, so it is a four-stage pipeline that
    // runs every clock from the accumulators, with no load enables (rnd1: add the bias; rnd2,
    // rnd3: shift by 14 + ex in two steps; rnd_sat: saturate); the FSM waits in S_RND1-S_RND4
    // until the finished sums have come through, and S_OUT takes rnd_sat.
    reg signed [51:0] rnd1_r, rnd1_i, rnd2_r, rnd2_i, rnd3_r, rnd3_i;
    reg        [47:0] rnd_sat;
    reg signed [51:0] rnd_bias;         // 2^(13+ex), from ex (constant during a job)
    function signed [23:0] sat24;
        input signed [51:0] r;
        begin
            if (r > 52'sd8388607)       sat24 = 24'sd8388607;
            else if (r < -52'sd8388608) sat24 = -24'sd8388608;
            else                        sat24 = r[23:0];
        end
    endfunction

    wire [1:0]  in_lrx = in_data[50:49];
    wire [2:0]  in_bank = bank_sel[in_lrx*3 +: 3];

    always @(posedge clk) begin
        jr       <= in_data;
        rnd_bias <= 52'sd1 <<< (13 + ex_c[3:0]);
        rnd1_r   <= acc_r + rnd_bias;
        rnd1_i   <= acc_i + rnd_bias;
        rnd2_r   <= rnd1_r >>> (14 + {ex_c[7:6], 2'b00});
        rnd2_i   <= rnd1_i >>> (14 + {ex_c[11:10], 2'b00});
        rnd3_r   <= rnd2_r >>> ex_c[13:12];
        rnd3_i   <= rnd2_i >>> ex_c[13:12];
        rnd_sat  <= {sat24(rnd3_r), sat24(rnd3_i)};
        d_wdata  <= jr[47:0];
        in_pop   <= 1'b0;
        out_push <= 1'b0;
        d_we     <= 1'b0;
        iss1_v   <= 1'b0;
        iss2_v   <= iss1_v;
        iss2_ok  <= iss1_ok;
        vpipe    <= {vpipe[3:0], iss2_v};
        sum_r    <= t_rr - t_ii;
        sum_i    <= t_ri + t_ir;
        if (vpipe[4]) begin
            acc_r <= acc_r + sum_r;
            acc_i <= acc_i + sum_i;
        end
        acc_clr <= 1'b0;
        if (acc_clr) begin
            acc_r <= 52'sd0;
            acc_i <= 52'sd0;
        end
        if (rst) begin
            st <= S_IDLE;
            vpipe <= 5'd0;
            iss2_v <= 1'b0;
            bank_cur <= 12'd0;
        end else case (st)
            S_IDLE: if (!in_empty && !in_pop) begin
                in_pop <= 1'b1;
                rx    <= in_data[51:49];
                ep    <= in_data[52];
                first <= in_data[48];
                bank  <= in_bank;
                if (en[in_lrx] && epoch[in_lrx] == in_data[52])
                    st <= S_WR;
            end
            S_WR: begin : wr
                // (the bank's tap count and output exponent are looked up here and in S_WR2
                // from the registered bank, and the first-sample reset of the receiver's write
                // pointer and fill is applied here from the registered `first`, rather than
                // all in S_IDLE from the input FIFO's output)
                reg [9:0]  wp_cur;
                reg [10:0] fill_cur;
                wp_cur   = first ? 10'd0 : wp[lrx];
                fill_cur = first ? 11'd0 : fill[lrx];
                nt_raw  <= bank_ntaps;
                ex_c    <= {4{bank_exp}};
                d_we    <= 1'b1;
                d_waddr <= {lrx[RW-1:0], wp_cur};
                idx     <= wp_cur;
                wp[lrx] <= wp_cur + 10'd1;
                fill[lrx] <= (fill_cur != 11'd1024) ? fill_cur + 11'd1 : fill_cur;
                bank_cur[lrx*3 +: 3] <= bank;
                n       <= 11'd0;
                acc_clr <= 1'b1;
                st      <= S_WR2;
            end
            S_WR2: begin
                ntaps <= (nt_raw == 11'd0) ? 11'd1 : (nt_raw > 11'd1024) ? 11'd1024 : nt_raw;
                st    <= S_MAC;
            end
            S_MAC: begin
                iss1_v  <= 1'b1;
                iss1_ok <= n < fill[lrx];
                d_raddr <= {lrx[RW-1:0], idx - n[9:0]};
                c_raddr <= {bank, n[9:0]};
                if (n == ntaps - 11'd1) begin
                    drain <= 4'd6;   // last tap accumulates 7 edges after issue (multiplier pipeline)
                    st <= S_WAIT;
                end
                n <= n + 11'd1;
            end
            S_WAIT: begin
                if (drain == 4'd0)
                    st <= S_RND1;
                drain <= drain - 4'd1;
            end
            S_RND1: st <= S_RND2;       // the rounding pipeline above runs meanwhile
            S_RND2: st <= S_RND3;
            S_RND3: st <= S_RND4;
            S_RND4: st <= S_OUT;
            S_OUT: begin
                out_push <= 1'b1;
                out_data <= {ep, rx, first, rnd_sat};
                st <= S_IDLE;
            end
            default: st <= S_IDLE;
        endcase
    end
    assign cfg_bank = bank;
endmodule
