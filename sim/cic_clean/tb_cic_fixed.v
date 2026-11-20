// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Self checking test of cic_fixed.
//
// The model is written from the arithmetic of a CIC decimator: N integrators in a registered chain that update on every
// accepted input sample, a sample counter that raises out_strobe for one clock after every R-th accepted sample, N combs in
// a registered chain that update on the clock where out_strobe is high, and an output that is the top OUT_WIDTH bits of the
// last comb plus the next lower bit, calculated modulo 2^OUT_WIDTH. The model uses 64 bit integers cut down with a mask
// and updates its registers in descending stage order with blocking assignments, so every stage sees the old value of the
// stage before it, which is the registered chain behavior that the specification asks for. It shares no code with the module.
//
// out_strobe and out_data of the module are compared with the model after every clock, for three parameter sets (the
// receiver's 3 stages with ratio 10, the 9 stage zoom filter, and a small set with ratio 4), with random full scale input
// and strobe patterns of every clock, every third clock and random clocks, and with a reset in the middle of a run.
//
// A second check does not use the model at all. A constant input must settle the output at
// K * R^N / 2^(ACC_WIDTH - OUT_WIDTH), rounded half up, which tests the filter gain and the output scaling independently.
//
// Run from the repository root:
//     iverilog -g2012 -o build/tb_cic_fixed.vvp sim/cic_clean/tb_cic_fixed.v rtl/rx/cic_fixed.v rtl/rx/cic_integrator.v rtl/rx/cic_comb.v
//     vvp build/tb_cic_fixed.vvp

`timescale 1ns/1ps

module chk_fixed #(
    parameter STAGES = 3,
    parameter DEC    = 10,
    parameter INW    = 18,
    parameter ACCW   = 28,
    parameter OUTW   = 16,
    parameter SEED   = 1
) (
    output reg        done,
    output reg [31:0] errors,
    output reg [31:0] dc_errors,
    output reg [31:0] pulses
);
    reg clock = 0;
    reg rst_all = 1;
    reg in_strobe = 0;
    reg [INW-1:0] in_data = 0;
    wire out_strobe;
    wire [OUTW-1:0] out_data;

    cic_fixed #(.STAGES(STAGES), .DECIMATION(DEC), .IN_WIDTH(INW), .ACC_WIDTH(ACCW), .OUT_WIDTH(OUTW)) dut (
        .rst_all(rst_all), .clock(clock), .in_strobe(in_strobe), .out_strobe(out_strobe),
        .in_data(in_data), .out_data(out_data)
    );

    always #5 clock = ~clock;

    // ------------------------------------------------------------------ the model
    wire [63:0] amask = (64'd1 << ACCW) - 64'd1;
    wire [63:0] omask = (64'd1 << OUTW) - 64'd1;

    reg [63:0] mi [1:STAGES];     // integrator registers
    reg [63:0] mc [1:STAGES];     // comb output registers
    reg [63:0] md [1:STAGES];     // comb delay registers
    integer    mcount;
    reg        mos;
    integer    k;
    reg [63:0] x_ext;
    reg [63:0] inp;

    initial begin
        for (k = 1; k <= STAGES; k = k + 1) begin mi[k] = 0; mc[k] = 0; md[k] = 0; end
        mcount = 0;
        mos = 0;
    end

    always @(posedge clock) begin
        if (rst_all) begin
            for (k = 1; k <= STAGES; k = k + 1) begin mi[k] = 0; mc[k] = 0; md[k] = 0; end
            mcount = 0;
            mos = 0;
        end else begin
            // Combs first, because they must see the integrator value from before this edge.
            if (mos) begin
                for (k = STAGES; k >= 1; k = k - 1) begin
                    inp = (k == 1) ? mi[STAGES] : mc[k-1];
                    mc[k] = (inp - md[k]) & amask;
                    md[k] = inp;
                end
            end
            if (in_strobe) begin
                // Sign extension of the input to 64 bits, then cut to the accumulator width.
                x_ext = {{(64-INW){in_data[INW-1]}}, in_data};
                for (k = STAGES; k >= 2; k = k - 1)
                    mi[k] = (mi[k] + mi[k-1]) & amask;
                mi[1] = (mi[1] + x_ext) & amask;
                if (mcount == DEC - 1) begin
                    mcount = 0;
                    mos = 1;
                end else begin
                    mcount = mcount + 1;
                    mos = 0;
                end
            end else
                mos = 0;
        end
    end

    // Expected output from the last comb register: top OUTW bits plus the next lower bit.
    wire [63:0] top_bits  = (mc[STAGES] >> (ACCW - OUTW)) & omask;
    wire [63:0] rnd_bit   = (mc[STAGES] >> (ACCW - OUTW - 1)) & 64'd1;
    wire [63:0] exp_out   = (top_bits + rnd_bit) & omask;

    // ------------------------------------------------------------------ stimulus
    integer seed;
    integer n;
    integer mode;      // 0 every clock, 1 every third clock, 2 random half, 3 random half with random resets
    reg [63:0] r;

    // One clock of the test: compare, then choose the next inputs at the falling edge.
    task step;
        input integer m;
        begin
            @(negedge clock);
            if (out_strobe !== mos || out_data !== exp_out[OUTW-1:0]) begin
                errors = errors + 1;
                if (errors < 5)
                    $display("fixed (%0d,%0d,%0d,%0d,%0d) mismatch: strobe dut %b model %b, data dut %h model %h",
                             STAGES, DEC, INW, ACCW, OUTW, out_strobe, mos, out_data, exp_out[OUTW-1:0]);
            end
            if (out_strobe === 1'b1) pulses = pulses + 1;
            r = {$random(seed), $random(seed)};
            in_data = r[INW-1:0];
            rst_all = 0;
            case (m)
                0: in_strobe = 1;
                1: in_strobe = (n % 3 == 0);
                2: in_strobe = r[40];
                default: begin
                    in_strobe = r[40] | r[41];
                    rst_all = (r[55:46] == 10'd0);          // about 1 in 1000 clocks
                end
            endcase
        end
    endtask

    // Expected value of the constant input check, from the plain formula of the filter gain.
    reg [63:0] gain;
    reg [63:0] dc_expect;
    integer j;
    initial begin
        done = 0; errors = 0; dc_errors = 0; pulses = 0; seed = SEED; n = 0;
        repeat (3) @(negedge clock);
        // The first mode of the run: after reset, every clock a sample.
        for (mode = 0; mode < 4; mode = mode + 1) begin
            for (n = 0; n < 5000; n = n + 1) step(mode);
        end
        // Reset in the middle of a run with strobes going, held for one clock together with a strobe.
        for (n = 0; n < 700; n = n + 1) step(0);
        rst_all = 1; in_strobe = 1;
        for (n = 0; n < 700; n = n + 1) step(2);

        // Constant input check (no model): in = 1000 for several filter lengths.
        @(negedge clock); rst_all = 1; in_strobe = 0;
        @(negedge clock); rst_all = 0;
        in_data = 1000;
        in_strobe = 1;
        gain = 1000;
        for (j = 0; j < STAGES; j = j + 1) gain = gain * DEC;
        dc_expect = ((gain + (64'd1 << (ACCW - OUTW - 1))) >> (ACCW - OUTW)) & omask;
        repeat ((2 * STAGES + 4) * DEC) @(negedge clock);
        for (j = 0; j < 3 * DEC; j = j + 1) begin
            @(negedge clock);
            if (out_data !== dc_expect[OUTW-1:0]) begin
                dc_errors = dc_errors + 1;
                if (dc_errors < 3) $display("fixed DC (%0d,%0d) dut %0d expect %0d", STAGES, DEC, out_data, dc_expect[OUTW-1:0]);
            end
        end
        done = 1;
    end
endmodule

module tb_cic_fixed;
    wire [2:0] done;
    wire [31:0] e0, e1, e2, d0, d1, d2, p0, p1, p2;
    chk_fixed #(3, 10, 18, 28, 16, 31) c0 (.done(done[0]), .errors(e0), .dc_errors(d0), .pulses(p0));
    chk_fixed #(9, 10, 18, 48, 16, 32) c1 (.done(done[1]), .errors(e1), .dc_errors(d1), .pulses(p1));
    chk_fixed #(3, 4,  18, 24, 16, 33) c2 (.done(done[2]), .errors(e2), .dc_errors(d2), .pulses(p2));

    initial begin
        wait (&done);
        #1;
        $display("fixed: model errors %0d %0d %0d, constant input errors %0d %0d %0d, output pulses %0d %0d %0d",
                 e0, e1, e2, d0, d1, d2, p0, p1, p2);
        if (e0 + e1 + e2 + d0 + d1 + d2 == 0 && p0 > 1000 && p1 > 1000 && p2 > 1000) $display("PASS");
        else $display("FAIL");
        $finish;
    end
endmodule
