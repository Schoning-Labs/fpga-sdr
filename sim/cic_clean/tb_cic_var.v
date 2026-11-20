// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Self checking test of cic_var.
//
// The model is written from the arithmetic of a CIC decimator with a ratio that can change at run time: 5 integrators in a
// registered chain that update on every accepted input sample, a 16 bit sample counter that is compared with the 6 bit value
// decimation minus 1 and raises out_strobe for one clock on a match, 5 combs in a registered chain that update on the clock
// where out_strobe is high, and an output register that takes, on every clock, a field of the last comb register that depends
// on decimation (the field of R = 5, 10 or 20, and the field of R = 40 for every other value). The field is bits H-1 down to
// H-16 of the comb value plus bit H-17, with H = 16 + 12, 17, 22 or 27, calculated modulo 2^16. The model uses 64 bit
// integers cut down with masks and updates its registers in descending stage order with blocking assignments, so each stage
// sees the old value of the stage before it. It shares no code with the module under test.
//
// Cases covered, each compared on out_strobe and out_data after every clock: R = 5, 10, 20, 40 and the illegal values
// 0, 1, 7 and 63, each with a sample every clock, every 10th clock and random clocks; the ratio changed while running, with
// and without reset; and the ratio lowered in the middle of a count, which has to produce the gap of about 65536 input
// samples without an output pulse.
//
// A second check does not use the model. A constant input of 1000 must settle the output at 1000 * R^5 rounded into the
// field of that ratio, for R = 5, 10, 20 and 40.
//
// Run from the repository root:
//     iverilog -g2012 -o build/tb_cic_var.vvp sim/cic_clean/tb_cic_var.v rtl/rx/cic_var.v rtl/rx/cic_integrator.v rtl/rx/cic_comb.v
//     vvp build/tb_cic_var.vvp

`timescale 1ns/1ps

module tb_cic_var;
    localparam N    = 5;
    localparam INW  = 16;
    localparam ACCW = 43;
    localparam OUTW = 16;

    reg clock = 0;
    reg rst_all = 1;
    reg [5:0] decimation = 6'd10;
    reg in_strobe = 0;
    reg [INW-1:0] in_data = 0;
    wire out_strobe;
    wire [OUTW-1:0] out_data;

    cic_var #(.STAGES(N), .IN_WIDTH(INW), .ACC_WIDTH(ACCW), .OUT_WIDTH(OUTW)) dut (
        .rst_all(rst_all), .decimation(decimation), .clock(clock), .in_strobe(in_strobe),
        .out_strobe(out_strobe), .in_data(in_data), .out_data(out_data)
    );

    always #5 clock = ~clock;

    // ------------------------------------------------------------------ the model
    localparam [63:0] AMASK = (64'd1 << ACCW) - 64'd1;
    localparam [63:0] OMASK = (64'd1 << OUTW) - 64'd1;

    reg [63:0] mi [1:N];
    reg [63:0] mc [1:N];
    reg [63:0] md [1:N];
    integer    mcount;
    reg        mos;
    reg [63:0] mout;
    integer    k;
    reg [63:0] x_ext;
    reg [63:0] inp;
    integer    h;

    // Growth bits for a ratio: 12, 17 and 22 for 5, 10 and 20, and 27 for everything else.
    function integer growth;
        input [5:0] dec;
        begin
            if (dec == 6'd5) growth = 12;
            else if (dec == 6'd10) growth = 17;
            else if (dec == 6'd20) growth = 22;
            else growth = 27;
        end
    endfunction

    initial begin
        for (k = 1; k <= N; k = k + 1) begin mi[k] = 0; mc[k] = 0; md[k] = 0; end
        mcount = 0; mos = 0; mout = 0;
    end

    always @(posedge clock) begin
        // The output register loads on every clock, also during reset, from the comb value before this edge.
        h = INW + growth(decimation);
        mout = (((mc[N] >> (h - OUTW)) & OMASK) + ((mc[N] >> (h - OUTW - 1)) & 64'd1)) & OMASK;
        if (rst_all) begin
            for (k = 1; k <= N; k = k + 1) begin mi[k] = 0; mc[k] = 0; md[k] = 0; end
            mcount = 0;
            mos = 0;
        end else begin
            if (mos) begin
                for (k = N; k >= 1; k = k - 1) begin
                    inp = (k == 1) ? mi[N] : mc[k-1];
                    mc[k] = (inp - md[k]) & AMASK;
                    md[k] = inp;
                end
            end
            if (in_strobe) begin
                x_ext = {{(64-INW){in_data[INW-1]}}, in_data};
                for (k = N; k >= 2; k = k - 1)
                    mi[k] = (mi[k] + mi[k-1]) & AMASK;
                mi[1] = (mi[1] + x_ext) & AMASK;
                // The compare value is decimation minus 1 in 6 bits.
                if (mcount == ((decimation - 1) & 63)) begin
                    mcount = 0;
                    mos = 1;
                end else begin
                    mcount = (mcount + 1) & 65535;
                    mos = 0;
                end
            end else
                mos = 0;
        end
    end

    // ------------------------------------------------------------------ stimulus and comparison
    integer errors = 0;
    integer pulses = 0;
    integer dc_errors = 0;
    integer seed = 77;
    integer n;
    reg [63:0] r;

    // One clock: compare at the falling edge, then pick the next inputs. mode 0 every clock, 1 every 10th, 2 random half.
    task step;
        input integer m;
        begin
            @(negedge clock);
            if (out_strobe !== mos || out_data !== mout[OUTW-1:0]) begin
                errors = errors + 1;
                if (errors < 6)
                    $display("var mismatch (R=%0d): strobe dut %b model %b, data dut %h model %h",
                             decimation, out_strobe, mos, out_data, mout[OUTW-1:0]);
            end
            if (out_strobe === 1'b1) pulses = pulses + 1;
            r = {$random(seed), $random(seed)};
            in_data = r[INW-1:0];
            rst_all = 0;
            case (m)
                0: in_strobe = 1;
                1: in_strobe = (n % 10 == 0);
                default: in_strobe = r[40];
            endcase
        end
    endtask

    // A reset of two clocks, compared like every other clock.
    task do_reset;
        begin
            @(negedge clock); rst_all = 1; in_strobe = 0;
            @(negedge clock); rst_all = 1;
            step(0);
        end
    endtask

    integer vals [0:7];
    integer vi, mode;
    reg [63:0] gain, dc_expect;
    integer hh, j;
    integer dcv [0:3];

    initial begin
        vals[0] = 5; vals[1] = 10; vals[2] = 20; vals[3] = 40; vals[4] = 0; vals[5] = 1; vals[6] = 7; vals[7] = 63;
        dcv[0] = 5; dcv[1] = 10; dcv[2] = 20; dcv[3] = 40;
        repeat (3) @(negedge clock);

        // Every ratio from the list, each with the three strobe patterns and a reset before each run.
        for (vi = 0; vi < 8; vi = vi + 1) begin
            decimation = vals[vi];
            for (mode = 0; mode < 3; mode = mode + 1) begin
                do_reset;
                for (n = 0; n < 3000; n = n + 1) step(mode);
            end
        end

        // The ratio changed while running, without a reset (all pass through the counter compare as it is).
        do_reset;
        for (vi = 0; vi < 8; vi = vi + 1) begin
            decimation = vals[7 - vi];
            for (n = 0; n < 1500; n = n + 1) step(2);
        end

        // The ratio changed together with a reset, three times.
        for (vi = 0; vi < 3; vi = vi + 1) begin
            decimation = vals[vi];
            do_reset;
            for (n = 0; n < 1500; n = n + 1) step(0);
        end

        // Lowering in the middle of a count: R = 40 with 30 samples counted, then R = 5 without a reset. The counter is above
        // the new compare value, so it has to run through 65535 and wrap before the first pulse.
        decimation = 40;
        do_reset;
        for (n = 0; n < 30; n = n + 1) step(0);
        decimation = 5;
        pulses = 0;
        for (n = 0; n < 70000; n = n + 1) step(0);
        // 30 samples were counted, so the counter needs 65536-30 more to wrap, and then one pulse per 5 samples: about
        // 70000-65506 samples left, so only about 900 pulses, instead of the 14000 a working R = 5 would give.
        if (pulses > 1000 || pulses < 500) begin
            errors = errors + 1;
            $display("var long gap check: %0d pulses in 70000 samples", pulses);
        end

        // Constant input check against the plain formula (no model).
        for (vi = 0; vi < 4; vi = vi + 1) begin
            decimation = dcv[vi];
            @(negedge clock); rst_all = 1; in_strobe = 0;
            @(negedge clock); rst_all = 0;
            in_data = 1000; in_strobe = 1;
            gain = 1000;
            for (j = 0; j < N; j = j + 1) gain = gain * dcv[vi];
            hh = INW + growth(decimation);
            dc_expect = (((gain + (64'd1 << (hh - OUTW - 1))) >> (hh - OUTW))) & OMASK;
            repeat ((2 * N + 4) * dcv[vi]) @(negedge clock);
            for (j = 0; j < 3 * dcv[vi]; j = j + 1) begin
                @(negedge clock);
                if (out_data !== dc_expect[OUTW-1:0]) begin
                    dc_errors = dc_errors + 1;
                    if (dc_errors < 4) $display("var DC R=%0d dut %0d expect %0d", dcv[vi], out_data, dc_expect[OUTW-1:0]);
                end
            end
        end

        $display("var: model errors %0d, constant input errors %0d, output pulses %0d", errors, dc_errors, pulses);
        if (errors == 0 && dc_errors == 0) $display("PASS");
        else $display("FAIL");
        $finish;
    end
endmodule
