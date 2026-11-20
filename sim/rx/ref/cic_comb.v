// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
// Reference copy of rtl/rx/cic_comb.v with the module names suffixed _ref, so the reference receiver in this folder can be simulated next to the chip's own modules.
//
// cic_comb: one comb stage of a CIC decimating filter, with a differential delay of one sample.
//
// What a CIC filter is: a CIC (cascaded integrator-comb) filter lowers the sample rate of a signal by a whole number R
// using only adders and registers (see docs/learn/GLOSSARY.md for the terms). A chain of integrators (cic_integrator.v)
// runs at the high input rate, the rate then drops by R, and a chain of combs runs at the low output rate. A comb is the
// opposite of an integrator: where an integrator adds up everything it has ever seen, a comb outputs the difference
// between the sample it sees now and the sample it saw one output period ago, which is why the two sections together
// give a plain moving-average type of low-pass response.
//
// What this module is: exactly one comb, so a decimator with N stages uses N copies of it in a row. It has two
// registers of WIDTH bits, a delay register that remembers the previous input sample and an output register that holds
// the difference. Every time strobe is high at a clock edge, with x being the value on in_data at that edge,
//
//     out_data <= x - delay          (the difference to the previous sample)
//     delay    <= x                  (remember x for the next time)
//
// so the output is the first difference of the strobed input sequence, y(m) = x(m) - x(m-1). The strobe here is the
// slow one, a single pulse for every decimated sample, and the parent module generates it by counting input samples.
//
// Where it sits in the radio: cic_fixed.v and cic_var.v put the first comb right behind the last integrator and then
// chain N of them. When combs are chained, each stage takes the registered output of the stage in front of it as it was
// before the common strobe edge, so every comb stage adds one output sample of delay, and that delay is part of the
// exact output sequence of the filter.
//
// Wrap-around: the integrators in front of the combs overflow all the time, and nothing in this stage tries to prevent
// it. The subtraction is done in two's complement with the same width as the registers, so the result is correct
// modulo 2^WIDTH. A difference of two numbers that are each correct modulo 2^WIDTH is again correct modulo 2^WIDTH, and
// as long as the true filter output fits into WIDTH bits the overflow of the integrators cancels here without a trace.
// For that reason there is no saturation and no rounding in this module.
//
// Latency: one clock. The new difference is visible on out_data right after the clock edge at which strobe was high.
//
// Gowin specific points: ordinary fabric only (a subtractor carry chain and 2 times WIDTH flip-flops), no block RAM and
// no DSP block. strobe is a clock enable, so both registers hold between output samples and no gated clock is needed.

module cic_comb_ref #(
    // Width in bits of the data path and of both registers (two's complement).
    parameter WIDTH = 64
) (
    input  wire                    clock,    // system clock, all registers change on its rising edge
    input  wire                    rst,      // synchronous reset, active high, clears both registers (wins over strobe)
    input  wire                    strobe,   // clock enable, high for one clock for every decimated sample
    input  wire signed [WIDTH-1:0] in_data,  // input sample, signed, valid at the clock edge where strobe is high
    output wire signed [WIDTH-1:0] out_data  // difference to the previous sample, signed, a register output
);

    // The one-sample memory (differential delay of 1) and the output register. Both start at 0 so that the first
    // difference after power-up is the first input sample itself, and so that 4-state simulators never see an X.
    reg signed [WIDTH-1:0] previous = {WIDTH{1'b0}};
    reg signed [WIDTH-1:0] diff     = {WIDTH{1'b0}};

    // Subtraction with a result of the same width as the registers, so the borrow out of the top bit is dropped and the
    // value wraps modulo 2^WIDTH as described above.
    wire signed [WIDTH-1:0] next_diff = in_data - previous;

    always @(posedge clock) begin
        if (rst) begin
            previous <= {WIDTH{1'b0}};     // reset wins over a strobe in the same clock
            diff     <= {WIDTH{1'b0}};
        end else if (strobe) begin
            diff     <= next_diff;         // x minus the old memory content
            previous <= in_data;           // x becomes the memory for the next strobe
        end
        // with strobe low both registers hold, so the stage keeps its result between decimated samples
    end

    // The output is the difference register itself.
    assign out_data = diff;

endmodule
