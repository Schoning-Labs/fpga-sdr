// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Unit test of the twiddle factor lookup rtl/ft8/ft8_tw3840.v. A twiddle factor is a point on the
// unit circle, W^e = cos(2 pi e / 3,840) - j sin(2 pi e / 3,840), that a Fourier transform
// multiplies its data with (docs/learn/GLOSSARY.md). The FT8 spectrogram combines fifteen 256
// point sub-transforms into one 3,840 point transform, and the combine stage needs W^(n1 k) for
// the sub-transform number n1 (0 .. 14) and the output bin k (0 .. 1,023). The RTL keeps only
// the first octant (480 entries) in a block ROM and rebuilds the other seven by reflection and
// sign changes, and this bench shows that the rebuilt values are exactly the model's.
//
// Stimulus: one lookup per clock for all 15 x 1,024 = 15,360 (n1, k) pairs the combine stage
// uses, in order, with in_valid held high throughout, so that the pipelined lookup (a fixed
// latency of 9 clocks) is also exercised at full rate.
//
// Pass criterion: every (wr, wi) pair equals the entry of sim/ft8/vectors/ft8_w3840_full.hex at
// index (n1 * k) mod 3,840. That file holds all 3,840 values of the Rust reference model's table
// (written by `ft8-frontend tables`), each packed as {wr[17:0], wi[17:0]} with 17 fractional bits,
// so full scale is 2^17 - 1. The bench prints "PASS: tb_ft8_tw3840 (15360 combinations)" on
// success and a "FAIL" line otherwise, with the first 20 mismatches listed.
//
// Run from the repository root, as tools/check.sh does for every tb_*.v: iverilog -g2012 -o
// out.vvp sim/ft8/tb_ft8_tw3840.v, then vvp out.vvp.

`timescale 1ns / 1ps
`include "rtl/ft8/ft8_tw3840.v"

module tb_ft8_tw3840;
    reg clk = 0;
    // 100 MHz bench clock (10 ns period).
    always #5 clk = ~clk;
    reg rst = 1;

    reg        in_valid;
    reg [3:0]  n1;
    reg [9:0]  k;
    wire       out_valid;
    wire signed [17:0] wr, wi;

    // n1 and k are 4 and 10 bits wide, wr and wi 18 bit signed with 17 fractional bits.
    ft8_tw3840 dut (
        .clk(clk), .rst(rst), .in_valid(in_valid), .n1(n1), .k(k),
        .out_valid(out_valid), .wr(wr), .wi(wi)
    );

    // The model's full table, one 36 bit word per exponent e = 0 .. 3,839: wr in bits 35:18 and wi in 17:0.
    reg [35:0] ref_rom [0:3839];
    initial $readmemh("sim/ft8/vectors/ft8_w3840_full.hex", ref_rom);

    // Scoreboard: remembers which (n1, k) was issued on each clock so that it can be matched
    // with the DUT's output when out_valid arrives after the fixed latency (LATENCY = 9 clocks).
    reg [3:0] n1_q [0:15];   // in-flight queue, deeper than the lookup latency
    reg [9:0] k_q  [0:15];
    integer wp, rp;
    integer errors, checked;
    integer i;
    reg [11:0] exp_e;
    reg signed [17:0] exp_wr, exp_wi;

    initial begin
        errors = 0;
        checked = 0;
        in_valid = 0;
        n1 = 0;
        k = 0;
        wp = 0;
        rp = 0;
        repeat (4) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // Stimulus changes are held to just after the clock edge (#1), not right at it. New values
        // set exactly at the edge race the DUT's own `always @(posedge clk)` blocks, because the
        // order of two processes sensitive to the same edge is not defined.
        for (i = 0; i < 15 * 1024; i = i + 1) begin
            #1;
            in_valid = 1;
            n1 = i / 1024;
            k  = i % 1024;
            n1_q[wp[3:0]] = n1;
            k_q[wp[3:0]]  = k;
            wp = wp + 1;
            @(posedge clk);
            check_pending;
        end
        // Stop feeding and let the last lookups drain out of the pipeline.
        #1;
        in_valid = 0;
        n1 = 0;
        k  = 0;
        repeat (16) begin
            @(posedge clk);
            check_pending;
        end

        // Every issued lookup must have produced a result.
        if (checked != 15 * 1024) begin
            $display("FAIL: checked %0d results, expected %0d", checked, 15 * 1024);
            errors = errors + 1;
        end
        if (errors == 0) $display("PASS: tb_ft8_tw3840 (%0d combinations)", checked);
        else $display("FAIL: tb_ft8_tw3840, %0d errors of %0d", errors, checked);
        $finish;
    end

    task check_pending;
        begin
            if (out_valid) begin
                // ref_rom[e] already holds the final (wr, wi) pair of the model's twiddle
                // function, negation included, packed like the entries of ft8_w3840_oct.hex but at
                // full 3,840 entry depth. The exponent is the product n1 * k reduced mod 3,840.
                exp_e  = (n1_q[rp[3:0]] * k_q[rp[3:0]]) % 3840;
                exp_wr = $signed(ref_rom[exp_e][35:18]);
                exp_wi = $signed(ref_rom[exp_e][17:0]);
                rp = rp + 1;
                checked = checked + 1;
                if (wr !== exp_wr || wi !== exp_wi) begin
                    errors = errors + 1;
                    if (errors <= 20)
                        $display("MISMATCH e=%0d: got (%0d,%0d) want (%0d,%0d)", exp_e, wr, wi, exp_wr, exp_wi);
                end
            end
        end
    endtask
endmodule
