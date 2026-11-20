// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Trivial testbench for rtl/example/adder.v, a parametrized adder (the sum is one bit wider than the inputs).
// It exists only to give tools/check.sh one iverilog testbench to run and to show the layout of a test in this
// repository; it is not part of the radio design. It is self-contained: it includes its DUT with a path
// relative to the repository root, since tools/check.sh invokes iverilog from there and Icarus resolves an
// include relative to the invoking directory, not to the including file.
//
// Stimulus: two additions, 3 + 4 (a plain case) and 15 + 1 (the case where the sum needs the extra bit).
// Pass: both sums are correct and the bench prints "PASS", otherwise a "FAIL" line for each wrong sum.
//
// How to run: from the repository root, `iverilog -g2012 -o tb.vvp sim/example/tb_example.v && vvp tb.vvp`.

`timescale 1ns / 1ps
`include "rtl/example/adder.v"

module tb_example;

    // 4-bit inputs a and b, so the sum is 5 bits.
    reg  [3:0] a, b;
    wire [4:0] sum;
    integer errors;

    adder #(.WIDTH(4)) dut (
        .a(a),
        .b(b),
        .sum(sum)
    );

        // The sum is combinational, so 1 ns after setting the inputs is enough to read it.
    initial begin
        errors = 0;

        a = 4'd3; b = 4'd4; #1;
        if (sum !== 5'd7) begin
            $display("FAIL: 3+4 = %0d, expected 7", sum);
            errors = errors + 1;
        end

        a = 4'd15; b = 4'd1; #1;
        if (sum !== 5'd16) begin
            $display("FAIL: 15+1 = %0d, expected 16", sum);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("PASS");
        end else begin
            $display("FAIL: %0d error(s)", errors);
        end
        $finish;
    end

endmodule
