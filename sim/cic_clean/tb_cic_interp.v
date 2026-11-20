// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Self checking test of CicInterpM5.
//
// The model is written from the arithmetic of a CIC interpolator with 5 combs, zero stuffing by R and 5 integrators, for the
// real and the imaginary channel. Per clock enable it does, in this order, the integrator chain (each stage adds the old
// value of the stage before it, the first adds the last comb output), then the comb chain (on the capture count: each stage
// subtracts its delay and stores its input; on all other counts the last comb output is cleared), then the control (the input
// pair is captured on the capture count, req is set, the counter moves). All values are 64 bit integers cut down with a mask,
// and stages are updated in descending order with blocking assignments, so each stage sees the old value of the stage before
// it. The output is the top OBITS bits of the last integrator plus the bit below them, modulo 2^OBITS. The model shares no
// code with the module under test, and the module has no reset, so both start from the power-up values and are compared from
// time 0.
//
// Compared on every clock: req, y_real and y_imag, for R = 400, 1, 2 and 3, one and five copies of the clock enable, and clock
// enable on every clock, on two clocks out of three and random. New input values are applied after every req, like the FIR
// interpolator that feeds the module in the radio, and the values are random full scale numbers.
//
// Two checks without the model: with the enable on every clock, req must be high exactly after the edges R, 2R, 3R, and so on
// (for R = 3 after edges 3, 6, 9); and a constant input must settle the output at the DC gain R^4 divided by the output
// shift and rounded, which is checked for R = 3 with a growth of 7 bits and for the default R = 400.
//
// Run from the repository root:
//     iverilog -g2012 -o build/tb_cic_interp.vvp sim/cic_clean/tb_cic_interp.v rtl/tx/CicInterpM5.v
//     vvp build/tb_cic_interp.vvp

`timescale 1ns/1ps

// Compares the module with the model for one parameter set and one enable pattern.
// ce_mode: 0 every clock, 1 two clocks out of three, 2 random half of the clocks.
module chk_interp #(
    parameter R       = 400,
    parameter G       = 35,
    parameter COPIES  = 1,
    parameter CE_MODE = 0,
    parameter SEED    = 1,
    parameter CLOCKS  = 4000
) (
    output reg        done,
    output reg [31:0] errors,
    output reg [31:0] req_errors,
    output reg [31:0] changes
);
    localparam IB = 20;
    localparam OB = 24;
    localparam C  = IB + G;

    reg clock = 0;
    reg [COPIES-1:0] clock_en = {COPIES{1'b0}};
    reg [IB-1:0] x_real = 0;
    reg [IB-1:0] x_imag = 0;
    wire req;
    wire [OB-1:0] y_real, y_imag;

    CicInterpM5 #(.RRRR(R), .IBITS(IB), .OBITS(OB), .GBITS(G), .CE_COPIES(COPIES)) dut (
        .clock(clock), .clock_en(clock_en), .req(req),
        .x_real(x_real), .x_imag(x_imag), .y_real(y_real), .y_imag(y_imag)
    );

    always #5 clock = ~clock;

    // ------------------------------------------------------------------ the model
    localparam [63:0] CMASK = (64'd1 << C) - 64'd1;
    localparam [63:0] OMASK = (64'd1 << OB) - 64'd1;

    reg [63:0] mx [0:1];          // captured input, per channel
    reg [63:0] mc [0:1][1:5];     // comb outputs
    reg [63:0] md [0:1][1:5];     // comb delays
    reg [63:0] ms [0:1][1:5];     // integrators
    integer    mk;
    reg        mp;
    reg        mreq;
    integer    ch, st;
    reg [63:0] inp;
    reg [63:0] xin;
    integer    edges;

    initial begin
        for (ch = 0; ch < 2; ch = ch + 1) begin
            mx[ch] = 0;
            for (st = 1; st <= 5; st = st + 1) begin mc[ch][st] = 0; md[ch][st] = 0; ms[ch][st] = 0; end
        end
        mk = 0; mp = (R == 1); mreq = 0; edges = 0;
    end

    always @(posedge clock) begin
        if (clock_en[0]) begin
            edges = edges + 1;               // counts the edges where the enable is high
            for (ch = 0; ch < 2; ch = ch + 1) begin
                // Integrators, from the old comb output.
                for (st = 5; st >= 2; st = st - 1)
                    ms[ch][st] = (ms[ch][st] + ms[ch][st-1]) & CMASK;
                ms[ch][1] = (ms[ch][1] + mc[ch][5]) & CMASK;
                // Combs, from the old captured input.
                if (mp) begin
                    for (st = 5; st >= 1; st = st - 1) begin
                        inp = (st == 1) ? mx[ch] : mc[ch][st-1];
                        mc[ch][st] = (inp - md[ch][st]) & CMASK;
                        md[ch][st] = inp;
                    end
                end else
                    mc[ch][5] = 0;
                // Capture of the input pair.
                if (mp) begin
                    xin = (ch == 0) ? x_real : x_imag;
                    mx[ch] = {{(64-IB){xin[IB-1]}}, xin[IB-1:0]} & CMASK;
                end
            end
            mreq = mp;
            if (mk == R - 1) mk = 0; else mk = mk + 1;
            mp = (mk == R - 1);
        end else
            mreq = 0;
    end

    wire [63:0] exp_r = ((ms[0][5] >> (C - OB)) + ((ms[0][5] >> (C - OB - 1)) & 64'd1)) & OMASK;
    wire [63:0] exp_i = ((ms[1][5] >> (C - OB)) + ((ms[1][5] >> (C - OB - 1)) & 64'd1)) & OMASK;

    // ------------------------------------------------------------------ stimulus and comparison
    integer seed;
    integer n;
    reg [63:0] rr;
    reg [OB-1:0] last_y;
    reg ce_now;

    initial begin
        done = 0; errors = 0; req_errors = 0; changes = 0; seed = SEED; last_y = 0;
        for (n = 0; n < CLOCKS; n = n + 1) begin
            @(negedge clock);
            // Compare, from time 0 on.
            if (req !== mreq || y_real !== exp_r[OB-1:0] || y_imag !== exp_i[OB-1:0]) begin
                errors = errors + 1;
                if (errors < 5)
                    $display("interp R=%0d copies=%0d ce_mode=%0d mismatch at clock %0d: req dut %b model %b, y_real dut %h model %h, y_imag dut %h model %h",
                             R, COPIES, CE_MODE, n, req, mreq, y_real, exp_r[OB-1:0], y_imag, exp_i[OB-1:0]);
            end
            // With the enable on every clock req must be high exactly after the edges R, 2R, 3R, and so on (the edge count of the model).
            if (CE_MODE == 0 && n >= 2 && req !== ((edges % R) == 0)) req_errors = req_errors + 1;
            if (y_real !== last_y) changes = changes + 1;
            last_y = y_real;
            // New inputs after every req (before the capture edge R enables later), random full scale values.
            if (req === 1'b1) begin
                rr = {$random(seed), $random(seed)};
                x_real = rr[IB-1:0];
                x_imag = rr[IB+31:32];
            end
            // The enable pattern, all copies equal.
            case (CE_MODE)
                0: ce_now = 1;
                1: ce_now = (n % 3 != 0);
                default: ce_now = $random(seed);
            endcase
            clock_en = {COPIES{ce_now}};
        end
        done = 1;
    end
endmodule

// Constant input check without the model.
module chk_interp_dc #(
    parameter R       = 3,
    parameter G       = 7,
    parameter COPIES  = 1,
    parameter CLOCKS  = 400
) (
    output reg        done,
    output reg [31:0] errors
);
    localparam IB = 20;
    localparam OB = 24;
    localparam C  = IB + G;

    reg clock = 0;
    reg [COPIES-1:0] clock_en = {COPIES{1'b1}};
    reg [IB-1:0] x_real = 100000;
    reg [IB-1:0] x_imag = 20000;
    wire req;
    wire [OB-1:0] y_real, y_imag;

    CicInterpM5 #(.RRRR(R), .IBITS(IB), .OBITS(OB), .GBITS(G), .CE_COPIES(COPIES)) dut (
        .clock(clock), .clock_en(clock_en), .req(req),
        .x_real(x_real), .x_imag(x_imag), .y_real(y_real), .y_imag(y_imag)
    );
    always #5 clock = ~clock;

    reg [63:0] gain_r, gain_i, exp_r, exp_i;
    integer j, n;
    initial begin
        done = 0; errors = 0;
        gain_r = 100000; gain_i = 20000;
        for (j = 0; j < 4; j = j + 1) begin gain_r = gain_r * R; gain_i = gain_i * R; end
        exp_r = ((gain_r + (64'd1 << (C - OB - 1))) >> (C - OB)) & ((64'd1 << OB) - 1);
        exp_i = ((gain_i + (64'd1 << (C - OB - 1))) >> (C - OB)) & ((64'd1 << OB) - 1);
        repeat (CLOCKS) @(negedge clock);
        for (n = 0; n < 50; n = n + 1) begin
            @(negedge clock);
            if (y_real !== exp_r[OB-1:0] || y_imag !== exp_i[OB-1:0]) begin
                errors = errors + 1;
                if (errors < 3) $display("interp DC R=%0d: dut %0d %0d expect %0d %0d", R, y_real, y_imag, exp_r[OB-1:0], exp_i[OB-1:0]);
            end
        end
        done = 1;
    end
endmodule

module tb_cic_interp;
    // The model comparison: 4 ratios, 2 copy counts, 3 enable patterns, some of them left out to keep the run short.
    wire [15:0] done;
    wire [31:0] e [0:15];
    wire [31:0] q [0:15];
    wire [31:0] ch [0:15];

    chk_interp #(400, 35, 1, 0, 101, 14000) a0  (.done(done[0]),  .errors(e[0]),  .req_errors(q[0]),  .changes(ch[0]));
    chk_interp #(400, 35, 5, 0, 102, 14000) a1  (.done(done[1]),  .errors(e[1]),  .req_errors(q[1]),  .changes(ch[1]));
    chk_interp #(400, 35, 5, 1, 103, 14000) a2  (.done(done[2]),  .errors(e[2]),  .req_errors(q[2]),  .changes(ch[2]));
    chk_interp #(400, 35, 1, 2, 104, 20000) a3  (.done(done[3]),  .errors(e[3]),  .req_errors(q[3]),  .changes(ch[3]));
    chk_interp #(1,   6,  1, 0, 105, 3000)  a4  (.done(done[4]),  .errors(e[4]),  .req_errors(q[4]),  .changes(ch[4]));
    chk_interp #(1,   6,  5, 2, 106, 3000)  a5  (.done(done[5]),  .errors(e[5]),  .req_errors(q[5]),  .changes(ch[5]));
    chk_interp #(2,   6,  1, 0, 107, 3000)  a6  (.done(done[6]),  .errors(e[6]),  .req_errors(q[6]),  .changes(ch[6]));
    chk_interp #(2,   6,  5, 1, 108, 3000)  a7  (.done(done[7]),  .errors(e[7]),  .req_errors(q[7]),  .changes(ch[7]));
    chk_interp #(3,   7,  1, 0, 109, 3000)  a8  (.done(done[8]),  .errors(e[8]),  .req_errors(q[8]),  .changes(ch[8]));
    chk_interp #(3,   7,  5, 0, 110, 3000)  a9  (.done(done[9]),  .errors(e[9]),  .req_errors(q[9]),  .changes(ch[9]));
    chk_interp #(3,   7,  1, 1, 111, 3000)  a10 (.done(done[10]), .errors(e[10]), .req_errors(q[10]), .changes(ch[10]));
    chk_interp #(3,   7,  5, 2, 112, 6000)  a11 (.done(done[11]), .errors(e[11]), .req_errors(q[11]), .changes(ch[11]));
    chk_interp #(3,   30, 1, 0, 113, 3000)  a12 (.done(done[12]), .errors(e[12]), .req_errors(q[12]), .changes(ch[12]));
    chk_interp #(400, 35, 1, 1, 114, 14000) a13 (.done(done[13]), .errors(e[13]), .req_errors(q[13]), .changes(ch[13]));
    chk_interp #(2,   30, 5, 2, 115, 4000)  a14 (.done(done[14]), .errors(e[14]), .req_errors(q[14]), .changes(ch[14]));
    chk_interp #(400, 35, 5, 2, 116, 20000) a15 (.done(done[15]), .errors(e[15]), .req_errors(q[15]), .changes(ch[15]));

    // The constant input checks.
    wire d1, d2, d3;
    wire [31:0] dc1, dc2, dc3;
    chk_interp_dc #(3,   7,  1, 400)  b1 (.done(d1), .errors(dc1));
    chk_interp_dc #(3,   7,  5, 400)  b2 (.done(d2), .errors(dc2));
    chk_interp_dc #(400, 35, 5, 6000) b3 (.done(d3), .errors(dc3));

    integer i;
    reg [31:0] total;
    initial begin
        wait ((&done) && d1 && d2 && d3);
        #1;
        total = dc1 + dc2 + dc3;
        for (i = 0; i < 16; i = i + 1) total = total + e[i] + q[i];
        $display("interp: model errors %0d, req timing errors %0d, constant input errors %0d, output changes (R=400, R=3) %0d %0d",
                 e[0]+e[1]+e[2]+e[3]+e[4]+e[5]+e[6]+e[7]+e[8]+e[9]+e[10]+e[11]+e[12]+e[13]+e[14]+e[15],
                 q[0]+q[1]+q[4]+q[6]+q[8]+q[9]+q[12], dc1+dc2+dc3, ch[0], ch[8]);
        if (total == 0 && ch[0] > 100 && ch[8] > 100) $display("PASS");
        else $display("FAIL");
        $finish;
    end
endmodule
