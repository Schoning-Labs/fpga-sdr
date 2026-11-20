// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// adder: a plain unsigned adder, WIDTH bits plus WIDTH bits giving a WIDTH+1 bit sum.
//
// WHERE IT SITS
// Nothing in the radio uses this module. It is the smallest possible piece of Verilog in the repository, there so
// that the simulation check script (tools/check.sh) always has one testbench to run, and so that a beginner can read
// a complete module (parameter, ports, one assignment) before opening the real blocks under rtl/.
//
// HOW IT WORKS
// The sum is combinational, which means there is no clock and no register: the output follows the inputs after the
// delay of the carry chain. The output is one bit wider than the inputs so the carry out of the top bit has a place
// to go, which is why 4 + 4 bits can show up to 15 + 15 = 30 in 5 bits. In the Gowin chip such an adder is mapped to
// the fast carry logic of the logic cells (the ALU mode, see docs/learn/GLOSSARY.md) and needs no DSP block.

`timescale 1ns / 1ps

module adder #(
    // WIDTH: bit width of both inputs (the sum has WIDTH+1 bits)
    parameter WIDTH = 4
) (
    input  wire [WIDTH-1:0] a,  // first addend, unsigned
    input  wire [WIDTH-1:0] b,  // second addend, unsigned
    output wire [WIDTH:0]   sum  // a + b, unsigned, one bit wider than the inputs so no carry is lost
);

    // Combinational add; the result is as wide as the output, so the carry out of the top bit is kept.
    assign sum = a + b;

endmodule
