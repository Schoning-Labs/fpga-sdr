// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
// Reference copy of rtl/rx/cic_integrator.v with the module names suffixed _ref, so the reference receiver in this folder can be simulated next to the chip's own modules.
//
// cic_integrator: one integrator stage of a CIC decimating filter.
//
// What a CIC filter is: a CIC (cascaded integrator-comb) filter is a low-pass filter that lowers the sample rate of a
// signal by a whole number R (the decimation ratio), and it does this using nothing but adders and registers, with no
// multipliers at all, which is why it is the usual first filter behind an analog-to-digital converter or a numerically
// controlled oscillator mixer (see docs/learn/GLOSSARY.md for the terms). It has two halves. The first half is a chain
// of N integrators, each of which simply adds its input to a running total on every input sample, and the second half
// is a chain of N combs (see cic_comb.v), each of which subtracts the previous sample from the current one, and the
// combs only run once every R input samples. The integrators run fast, the combs run slow, and between the two halves
// the sample rate drops by R.
//
// What this module is: exactly one integrator, so a decimator with N stages uses N copies of it in a row. It holds a
// single accumulator register that is WIDTH bits wide, and every time the strobe input is high at a clock edge the
// accumulator becomes accumulator plus in_data. The output is the accumulator register itself, so a stage costs one
// adder and one register and nothing else.
//
// Where it sits in the radio: cic_fixed.v and cic_var.v put N of these in a chain at the high input rate, and the last
// one feeds the first comb. When stages are chained, each stage adds the registered output of the stage in front of it
// as that output was before the clock edge, so every stage adds one extra clock of delay. That chaining is done by the
// wiring in the parent module, and nothing about it is inside this file.
//
// Bit growth and wrap-around: an integrator never forgets, so a constant input makes the total grow without limit and
// the register will overflow sooner or later. That is fine, and it is in fact relied on. The numbers are two's
// complement, so an overflow just means the total continues from the other end of the number range, and the answer is
// correct modulo 2^WIDTH. The comb section after the integrators takes differences, and a difference of two values
// that are both correct modulo 2^WIDTH is again correct modulo 2^WIDTH, so the wrap cancels exactly as long as the
// final filter output fits into WIDTH bits. The parent therefore chooses WIDTH as the input width plus the bit growth of
// the whole filter (roughly N times log2 of R), and no saturation or rounding is done in here, because either of them
// would break the cancellation.
//
// Latency: one clock. The sum that includes a sample is visible on out_data right after the clock edge at which
// strobe was high with that sample on in_data.
//
// Gowin specific points: the stage maps onto ordinary fabric (an adder carry chain and WIDTH flip-flops), with no block
// RAM and no DSP block. The clock is expected to be on a global clock line, and strobe is a clock enable, so the stage
// holds its value when strobe is low and no gated clock is needed.

module cic_integrator_ref #(
    // Width in bits of the input, the accumulator and the output (two's complement).
    parameter WIDTH = 64
) (
    input  wire                    clock,    // system clock, all registers change on its rising edge
    input  wire                    rst,      // synchronous reset, active high, sets the accumulator to 0 (wins over strobe)
    input  wire                    strobe,   // clock enable, high for one clock for every input sample that is valid
    input  wire signed [WIDTH-1:0] in_data,  // input sample, signed, same width as the accumulator
    output wire signed [WIDTH-1:0] out_data  // the accumulator, signed, a register output (changes one clock after strobe)
);

    // The running total. It starts at 0 in simulation and on the chip (the initial value is honored by the Gowin tools),
    // so a design without a reset pulse still begins from a clean state, and so 4-state simulators never see an X.
    reg signed [WIDTH-1:0] total = {WIDTH{1'b0}};

    // The adder result, formed with the same width as the register on purpose: a signed sum of two WIDTH bit numbers
    // is truncated to WIDTH bits, and dropping the carry out of the top bit is exactly the wrap-around described above.
    wire signed [WIDTH-1:0] next_total = total + in_data;

    always @(posedge clock) begin
        if (rst)
            total <= {WIDTH{1'b0}};       // reset has priority, a strobe in the same clock is ignored
        else if (strobe)
            total <= next_total;          // add the new sample, with silent wrap on overflow
        // with strobe low the register keeps its value, which is how the stage waits between input samples
    end

    // The output is the register itself, no extra register and no logic in between.
    assign out_data = total;

endmodule
