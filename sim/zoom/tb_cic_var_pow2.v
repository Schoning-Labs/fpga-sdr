// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Word-for-word comparison of the variable-decimation CIC filter in rtl/zoom/cic_var_pow2.v against an
// independent reference of the same filter, sim/zoom/ref/cic_var_pow2_ref.v.
//
// A CIC (cascaded integrator-comb) filter is the cheapest way to throw away most of the samples of a fast
// stream: a chain of running sums (integrators) runs at the input rate, the stream is then decimated, which
// means that only every R-th sample is kept, and a chain of differences (combs) runs at the lower rate.
// It needs no multipliers, and its gain at DC is fixed by its length, so the output is cut down to 16 bits
// again with a rounding step. The zoom DDC uses this one as its second stage, with R = 2^shift for
// shift = 0 to 6 (decimation 1 to 64), eleven stages and 16-bit words; docs/learn/GLOSSARY.md has the terms.
//
// The DUT is the form made for the chip, in which the wide adds are done serially in two halves on two
// clocks and the integrator and comb state lives in LUT RAM. The reference is the plain textbook form, built
// from the receiver bank's cic_integrator and cic_comb modules with every stage stepping on every input
// sample. It is written separately from the DUT on purpose, so that a mistake in the serial form cannot hide
// itself in a copy of the same mistake, and the two must still agree on every output word.
//
// Stimulus: for every decimation setting (shift 0 to 6), and twice per setting with a reset before each
// run, (40 << shift) + 300 input words are fed in. The fixed CIC in front of this stage in the radio
// delivers one word per ten clocks at the earliest, so the words here are spaced 10 to 13 clocks apart. The
// words are random 16-bit values, with a full-scale positive word on every 7th input and a full-scale
// negative one on every 11th, to drive the accumulators through their wrap-around. The clock is an
// arbitrary 2 ns period, because only the number of clocks matters.
//
// What counts as a pass: the DUT and the reference must produce the same number of output words (at
// least 30 per run), and the words that each one presents at its out_strobe must be equal one by one.
// More than half of all words compared must also be non-zero, which guards against both filters being
// silent. The bench prints the number of words compared and ends with PASS or FAIL.
//
// Run from the repository root, it takes about ten seconds:
//   iverilog -g2012 -s tb_cic_var_pow2 -o build/tb_cic_var_pow2.vvp sim/zoom/tb_cic_var_pow2.v && vvp build/tb_cic_var_pow2.vvp

`timescale 1ns / 1ps
// The reference is built from these two modules, and the DUT takes its helper modules from cic_var_shared.
`include "rtl/rx/cic_integrator.v"
`include "rtl/rx/cic_comb.v"
`include "rtl/rx/cic_var_shared.v"
`include "rtl/zoom/cic_var_pow2.v"
`include "sim/zoom/ref/cic_var_pow2_ref.v"

// Both filters get the same clock, reset, shift setting and input strobe and word, and each has its own
// output strobe and word.
module tb_cic_var_pow2;
    reg clock = 1'b0;
    always #1 clock = ~clock;

    reg         rst = 1'b1;
    reg  [2:0]  shift = 3'd0;
    reg         in_strobe = 1'b0;
    reg  signed [15:0] in_data = 16'sd0;
    wire        os_a, os_b;
    wire signed [15:0] od_a, od_b;

    cic_var_pow2 #(.STAGES(11), .IN_WIDTH(16), .MAX_SHIFT(6), .OUT_WIDTH(16)) dut (
        .rst_all(rst), .shift(shift), .clock(clock), .in_strobe(in_strobe), .out_strobe(os_a),
        .in_data(in_data), .out_data(od_a));
    cic_var_pow2_ref #(.STAGES(11), .IN_WIDTH(16), .MAX_SHIFT(6), .OUT_WIDTH(16)) dut_ref (
        .rst_all(rst), .shift(shift), .clock(clock), .in_strobe(in_strobe), .out_strobe(os_b),
        .in_data(in_data), .out_data(od_b));

// Every output word of each filter is stored in order, at its own out_strobe, and compared after the run.
    reg signed [15:0] qa [0:8191];
    reg signed [15:0] qb [0:8191];
    integer na = 0, nb = 0, errors = 0, total = 0, nonzero = 0;
    always @(posedge clock) begin
        if (os_a) begin qa[na] = od_a; na = na + 1; end
        if (os_b) begin qb[nb] = od_b; nb = nb + 1; end
    end

    integer s, k, n, i, part;
    // One pass through the loop is one run: a reset (as happens when the span is changed), a stimulus
    // phase, and then the comparison of everything that was collected.
    initial begin
        for (s = 0; s <= 6; s = s + 1) begin
            for (part = 0; part < 2; part = part + 1) begin
                rst = 1'b1;
                shift = s;
                repeat (8) @(posedge clock);
                na = 0; nb = 0;
                rst = 1'b0;
                repeat (4) @(posedge clock);
                // A run long enough for the filter to settle and still give at least 30 output words at shift 6.
                n = (40 << s) + 300;
                for (k = 0; k < n; k = k + 1) begin
                    // One input: the strobe lasts one clock, and the next word is put on the bus one clock after it.
                    in_strobe <= 1'b1;
                    @(posedge clock);
                    in_strobe <= 1'b0;
                    @(posedge clock);
                    // Random full-scale extremes on a fixed raster, otherwise random words.
                    in_data <= (k % 7 == 0) ? 16'sh7FFF : (k % 11 == 0) ? 16'sh8000 : $random;
                    // 8 to 11 more clocks give a spacing of 10 to 13 clocks between strobes.
                    repeat (8 + ($random & 3)) @(posedge clock);
                end
                repeat (20) @(posedge clock);
                // Check 1: both filters gave the same number of words.
                if (na != nb || na < 30) begin
                    $display("ERROR shift %0d: %0d words against %0d of the reference", s, na, nb);
                    errors = errors + 1;
                end
                // Check 2: every word of the DUT is equal to the word of the reference (!== also catches x).
                for (i = 0; i < na && i < nb; i = i + 1) begin
                    total = total + 1;
                    if (qa[i] != 0) nonzero = nonzero + 1;
                    if (qa[i] !== qb[i]) begin
                        errors = errors + 1;
                        if (errors <= 10) $display("MISMATCH shift %0d word %0d: %0d, reference %0d", s, i, qa[i], qb[i]);
                    end
                end
            end
        end
        $display("%0d words compared (%0d not zero), %0d errors", total, nonzero, errors);
        // Pass only if there were no differences and the filters were not just producing zeros.
        if (errors == 0 && nonzero > total / 2) $display("PASS");
        else $display("FAIL");
        $finish;
    end
endmodule
