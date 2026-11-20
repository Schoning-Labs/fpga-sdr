// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// cic_var: CIC decimating filter whose decimation ratio is chosen while the radio runs (5, 10, 20 or 40).
//
// What a CIC filter is: a CIC (cascaded integrator-comb) filter is a low-pass filter that also lowers the sample rate
// by a whole number R, using only adders and registers and no multipliers (see docs/learn/GLOSSARY.md for the terms).
// A chain of N integrators (cic_integrator.v) runs at the high input rate and adds up its input, then the rate drops
// by R, and a chain of N combs (cic_comb.v) runs at the low output rate and takes differences of its input. Here N is
// the parameter STAGES, the differential delay of every comb is 1, and the DC gain of the whole filter is R to the
// power N. A radio that offers several bandwidths needs several values of R, and this module takes R from the input
// decimation, so the same hardware serves all of them.
//
// Why the output is taken from a different bit field for each R: the gain R^N grows quickly with R, so a bigger R
// produces larger numbers at the end of the comb chain. To keep the output level about the same for every R, the output
// word is cut out of the comb result at a bit position that depends on R. The bit growth of the filter is
// ceil(5 * log2 R) for the default of 5 stages, which is 12 bits for R=5, 17 for R=10, 22 for R=20 and 27 for R=40, and
// these four numbers are fixed constants in this file (they do not follow the STAGES parameter). With H being IN_WIDTH
// plus that growth, the output is bits H-1 down to H-OUT_WIDTH of the last comb, rounded to nearest using the next lower
// bit (round half up). Bits above H-1 are discarded, since the true value fits in H bits anyway. Any value of
// decimation other than 5, 10 and 20 uses the growth of 27, which includes the legal 40 and every illegal value.
//
// Bit growth and why wrap-around is fine: the integrators never forget their input, so their totals overflow all the time,
// and all registers have the width ACC_WIDTH (IN_WIDTH plus 27, the growth for R=40 with 5 stages). Everything is two's
// complement, so an overflow only moves a total to the other end of the number range, which is arithmetic modulo
// 2^ACC_WIDTH. The combs subtract, a difference of two numbers that are each correct modulo 2^ACC_WIDTH is again correct
// modulo 2^ACC_WIDTH, and so the overflow cancels exactly as long as the true result fits into the register. Nothing
// in the chain saturates, because that would break the cancellation.
//
// Where it sits in the radio: it is the second decimator behind cic_fixed.v in the reference receiver channel, running
// at one tenth of the first decimator's output rate. The chip build uses cic_var_shared.v instead, which shares the
// hardware between the two receiver quadrature paths.
//
// How it works, step by step:
//   1. in_data is sign extended to ACC_WIDTH bits and goes through the integrator chain on every clock where in_strobe
//      is high. Each stage adds the registered output of the stage before it, as it was before the clock edge.
//   2. A 16 bit counter counts accepted input samples. At the sample where the counter equals decimation minus 1 (computed
//      in 6 bits), the counter returns to 0 and out_strobe is set for one clock.
//   3. During the clock where out_strobe is high the combs update, and each comb stage adds one output sample of delay.
//   4. On every clock edge, with no condition at all and not even reset, the output register takes the rounded field of the
//      last comb register as it was before that edge, using the decimation value that is present at that edge.
//
// Timing, with T being the cycle where the R-th in_strobe is high:
//   end of T      the integrators take that sample, the counter wraps and out_strobe is set
//   cycle T+1     out_strobe is high and out_data shows the result of the previous output event, so a consumer that samples
//                 out_data at out_strobe receives that previous result (the shared version relies on this)
//   end of T+1    the combs update, and out_data takes the old comb value again
//   cycle T+2     out_data still shows the previous event's result
//   cycle T+3 on  out_data shows the new result, which is 2 clocks after out_strobe
//
// Changing the ratio while running: decimation is used live and no copy of it is kept.
//   - The counter compare uses the value at every in_strobe edge. When decimation is lowered while the counter is already
//     above the new value minus 1, the counter has to count up through 65535 and wrap before it matches, which is a gap of
//     up to about 65536 input samples without any out_strobe. Resetting with rst_all whenever the ratio changes avoids
//     this, and that is what callers are expected to do.
//   - decimation = 1 gives an out_strobe after every input sample, and decimation = 0 compares with 63, so the period is 64.
//   - The output field is selected from decimation on every clock, so a change rescales the held comb value within one
//     clock, without waiting for the next output event.
//
// Gowin specific points: ordinary fabric only (adder carry chains and flip-flops, 3 times STAGES registers of ACC_WIDTH
// bits), with no block RAM and no DSP block. in_strobe and out_strobe are clock enables, so a single clock is enough.

module cic_var #(
    // Number of integrator stages and of comb stages (N). The output bit positions below assume the default of 5.
    parameter STAGES    = 5,
    // Width of in_data in bits.
    parameter IN_WIDTH  = 16,
    // Width of every integrator and comb register, IN_WIDTH + 27 which is the growth for R=40 with 5 stages.
    parameter ACC_WIDTH = 43,
    // Width of out_data in bits.
    parameter OUT_WIDTH = 16
) (
    input  wire                         rst_all,     // synchronous reset, active high, clears the filter (not out_data)
    input  wire [5:0]                   decimation,  // decimation ratio R, unsigned, normally 5, 10, 20 or 40
    input  wire                         clock,       // system clock, all registers change on its rising edge
    input  wire                         in_strobe,   // high for one clock for every valid in_data sample
    output reg                          out_strobe,  // one clock pulse after every R-th accepted input sample
    input  wire signed [IN_WIDTH-1:0]   in_data,     // input sample, signed
    output reg  signed [OUT_WIDTH-1:0]  out_data     // filter output, signed, a register that is refreshed on every clock
);

    // ---------------------------------------------------------------------------------------------------------------
    // Input sample counter and the one clock output pulse.
    // ---------------------------------------------------------------------------------------------------------------

    // Counts accepted input samples. It is 16 bits wide on purpose, so that it can reach any value up to 65535 even when
    // decimation is changed under it (see the note above about lowering the ratio).
    reg [15:0] sample_count = 16'd0;

    // The match value, decimation minus 1 computed in 6 bits (so 0 minus 1 gives 63) and then widened with zeros.
    wire [5:0]  last_count6 = decimation - 6'd1;
    wire [15:0] last_count  = {10'd0, last_count6};

    always @(posedge clock) begin
        if (rst_all) begin
            sample_count <= 16'd0;
            out_strobe   <= 1'b0;
        end else if (in_strobe) begin
            if (sample_count == last_count) begin
                sample_count <= 16'd0;       // round finished, start the next one
                out_strobe   <= 1'b1;        // pulse for the clock after this edge
            end else begin
                sample_count <= sample_count + 16'd1;   // wraps from 65535 to 0 by itself
                out_strobe   <= 1'b0;
            end
        end else begin
            out_strobe <= 1'b0;              // the pulse never lasts longer than one clock
        end
    end

    // ---------------------------------------------------------------------------------------------------------------
    // Integrator section: STAGES accumulators in a registered chain, running on in_strobe.
    // ---------------------------------------------------------------------------------------------------------------

    // The input sample widened to the accumulator width, with the sign bit copied into the new upper bits.
    wire signed [ACC_WIDTH-1:0] sample_wide = in_data;

    // The registered outputs of all integrators side by side, stage 1 in the lowest ACC_WIDTH bits.
    wire [STAGES*ACC_WIDTH-1:0] integ_out;

    genvar gi;
    generate
        for (gi = 0; gi < STAGES; gi = gi + 1) begin : integ
            // Stage 1 adds the input, the other stages add the registered output of the stage before them.
            wire signed [ACC_WIDTH-1:0] stage_in;
            if (gi == 0) begin : first
                assign stage_in = sample_wide;
            end else begin : later
                assign stage_in = integ_out[(gi-1)*ACC_WIDTH +: ACC_WIDTH];
            end

            cic_integrator #(ACC_WIDTH) u_integrator (
                .clock   (clock),
                .rst     (rst_all),
                .strobe  (in_strobe),
                .in_data (stage_in),
                .out_data(integ_out[gi*ACC_WIDTH +: ACC_WIDTH])
            );
        end
    endgenerate

    // ---------------------------------------------------------------------------------------------------------------
    // Comb section: STAGES differentiators in a registered chain, running on out_strobe.
    // ---------------------------------------------------------------------------------------------------------------

    // The registered outputs of all combs side by side, stage 1 in the lowest ACC_WIDTH bits.
    wire [STAGES*ACC_WIDTH-1:0] comb_out;

    genvar gc;
    generate
        for (gc = 0; gc < STAGES; gc = gc + 1) begin : comb
            // Comb 1 reads the last integrator, the other combs read the registered output of the comb before them.
            wire signed [ACC_WIDTH-1:0] stage_in;
            if (gc == 0) begin : first
                assign stage_in = integ_out[(STAGES-1)*ACC_WIDTH +: ACC_WIDTH];
            end else begin : later
                assign stage_in = comb_out[(gc-1)*ACC_WIDTH +: ACC_WIDTH];
            end

            cic_comb #(ACC_WIDTH) u_comb (
                .clock   (clock),
                .rst     (rst_all),
                .strobe  (out_strobe),
                .in_data (stage_in),
                .out_data(comb_out[gc*ACC_WIDTH +: ACC_WIDTH])
            );
        end
    endgenerate

    wire [ACC_WIDTH-1:0] comb_last = comb_out[(STAGES-1)*ACC_WIDTH +: ACC_WIDTH];

    // ---------------------------------------------------------------------------------------------------------------
    // Output field selection, rounding and the output register.
    // ---------------------------------------------------------------------------------------------------------------

    // Bit growth of the filter for each legal ratio, with 5 stages: ceil(5 * log2 R). These four numbers are constants
    // and do not change with the STAGES parameter.
    localparam GROWTH_R5  = 12;   // 5^5  = 3125,        needs 12 bits
    localparam GROWTH_R10 = 17;   // 10^5 = 100000,      needs 17 bits
    localparam GROWTH_R20 = 22;   // 20^5 = 3200000,     needs 22 bits
    localparam GROWTH_R40 = 27;   // 40^5 = 102400000,   needs 27 bits, and this is also used for every other value

    // Cuts the output word out of a comb value, for a given total width h of the true result (IN_WIDTH plus growth).
    // Shifting right by h-OUT_WIDTH-1 puts the rounding bit (bit h-OUT_WIDTH-1 of the original) at bit 0 and the wanted
    // OUT_WIDTH bits right above it. Anything above h-1 in the original lands above those bits and is not taken.
    function [OUT_WIDTH-1:0] cut_field;
        input [ACC_WIDTH-1:0] value;
        input integer         h;
        reg   [ACC_WIDTH-1:0] shifted;
        begin
            shifted   = value >> (h - OUT_WIDTH - 1);
            cut_field = shifted[OUT_WIDTH:1] + shifted[0];   // the rounding bit is added as 0 or 1, sum kept to OUT_WIDTH bits
        end
    endfunction

    // The field for each ratio, computed from the same comb register in parallel.
    wire [OUT_WIDTH-1:0] field_r5  = cut_field(comb_last, IN_WIDTH + GROWTH_R5);
    wire [OUT_WIDTH-1:0] field_r10 = cut_field(comb_last, IN_WIDTH + GROWTH_R10);
    wire [OUT_WIDTH-1:0] field_r20 = cut_field(comb_last, IN_WIDTH + GROWTH_R20);
    wire [OUT_WIDTH-1:0] field_r40 = cut_field(comb_last, IN_WIDTH + GROWTH_R40);

    // The output register is loaded on every clock with the field that fits the present decimation value, and it is
    // not affected by reset or by any strobe. It therefore lags the comb chain by one clock more than the comb register.
    always @(posedge clock) begin
        case (decimation)
            6'd5:    out_data <= field_r5;
            6'd10:   out_data <= field_r10;
            6'd20:   out_data <= field_r20;
            default: out_data <= field_r40;   // 40 and every illegal value
        endcase
    end

    // Both registers that have no reset start at 0 in simulation and on the chip.
    initial begin
        out_strobe = 1'b0;
        out_data   = {OUT_WIDTH{1'b0}};
    end

endmodule
