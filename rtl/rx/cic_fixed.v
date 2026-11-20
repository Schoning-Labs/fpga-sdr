// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// cic_fixed: CIC decimating filter with a ratio that is fixed when the design is built.
//
// What a CIC filter is: a CIC (cascaded integrator-comb) filter is a low-pass filter that also lowers the sample rate
// by a whole number R, and it needs only adders and registers, with no multipliers, which makes it very cheap and the
// usual first filter behind a mixer when the sample rate is still high (see docs/learn/GLOSSARY.md for the terms).
// It is built from two halves. The first half is a chain of N integrators (cic_integrator.v), each of which adds its
// input to a running total on every input sample, and these run at the full input rate. The second half is a chain of
// N combs (cic_comb.v), each of which outputs the difference between its current and its previous input, and these
// run only once every R input samples, so the sample rate drops by R between the two halves. N is the parameter STAGES
// and R is the parameter DECIMATION. The differential delay of every comb is 1.
//
// What the filter does to a signal: the combined response is that of N cascaded moving averages of length R, so the
// gain at DC is R to the power N, and the response has deep notches at every multiple of the output rate, which are
// exactly the frequencies that would alias onto DC after the rate reduction. The more stages, the deeper the notches
// (and the more the passband droops, which a later FIR filter in the receiver usually corrects).
//
// Bit growth and why wrap-around is fine: the gain of R^N means the output can be larger than the input by about
// N times log2(R) bits, and the integrators grow even beyond that because they never forget. Instead of making the
// registers wide enough to hold the integrator totals, all registers have the width ACC_WIDTH, the input width plus the
// growth of the whole filter, and are allowed to overflow. Everything is two's complement, so an overflow only means
// that a total carries on from the other end of the number range, which is arithmetic modulo 2^ACC_WIDTH. The combs
// subtract, and subtracting two numbers that are each correct modulo 2^ACC_WIDTH gives a result that is correct
// modulo 2^ACC_WIDTH, so as long as the true output fits into ACC_WIDTH bits the overflow in the integrators cancels in
// the combs and the result is exact. No saturation exists anywhere in the chain, since it would destroy this property.
// ACC_WIDTH is a free parameter, and its intended value is IN_WIDTH plus the rounded up value of N times log2(R).
//
// Where it sits in the radio: this is the plain reference version of the first decimator for a receiver channel
// (the chip build uses rx_cic_fixed.v, which is arranged for the DSP and block RAM resources instead). It reads the
// mixer output with in_strobe as the valid flag, and it produces one output word per R valid input words together with
// the one clock pulse out_strobe.
//
// How it works, step by step:
//   1. in_data is sign extended to ACC_WIDTH bits and fed to integrator 1. Each following integrator adds the
//      registered output of the one before it, as that output was before the clock edge, and all of them update together
//      on every clock where in_strobe is high.
//   2. A 16 bit counter counts the accepted input samples. When the R-th one is accepted the counter returns to 0 and the
//      register out_strobe is set for exactly one clock.
//   3. During that clock (the one after the R-th sample was accepted) the combs update, which means comb 1 takes the
//      last integrator and comb k takes comb k-1 as it was before the edge. Every comb stage therefore adds one
//      output sample of delay, and this delay is part of the exact output sequence.
//   4. The output word is made from the last comb by keeping the top OUT_WIDTH bits and rounding to nearest with the
//      next lower bit (round half up). This part is plain logic, with no register behind it.
//
// Timing, with T being the clock cycle where the R-th in_strobe is high:
//   end of T      the integrators take that sample and out_strobe is set
//   cycle T+1     out_strobe is high, out_data still shows the result of the previous output event, so a consumer that
//                 samples out_data when out_strobe is high receives that previous result (every user relies on this)
//   end of T+1    the combs update
//   cycle T+2 on  out_data shows the new result, and it stays until the cycle after the next out_strobe
//   When in_strobe stays low nothing changes anywhere and out_strobe stays low, so there is no other output enable.
//
// Gowin specific points: only ordinary fabric (adder carry chains and flip-flops, 3 times N registers of ACC_WIDTH bits), no
// block RAM and no DSP block. in_strobe and the internal out_strobe are clock enables of the registers, so a single
// clock is enough and no gated clocks exist.

module cic_fixed #(
    // Number of integrator stages and of comb stages (N).
    parameter STAGES     = 3,
    // Decimation ratio R, from 1 to 65536, which is the limit of the 16 bit sample counter.
    parameter DECIMATION = 10,
    // Width of in_data in bits.
    parameter IN_WIDTH   = 18,
    // Width of every integrator and comb register, intended to be IN_WIDTH + ceil(STAGES * log2(DECIMATION)).
    // It must be at least IN_WIDTH and larger than OUT_WIDTH.
    parameter ACC_WIDTH  = 28,
    // Width of out_data in bits.
    parameter OUT_WIDTH  = 16
) (
    input  wire                         rst_all,     // synchronous reset, active high, clears every register of the filter
    input  wire                         clock,       // system clock, all registers change on its rising edge
    input  wire                         in_strobe,   // high for one clock for every valid in_data sample
    output reg                          out_strobe,  // one clock pulse after every R-th accepted input sample
    input  wire signed [IN_WIDTH-1:0]   in_data,     // input sample, signed
    output wire signed [OUT_WIDTH-1:0]  out_data     // filter output, signed, combinational from the last comb register
);

    // ---------------------------------------------------------------------------------------------------------------
    // Input sample counter and the one clock output pulse.
    // ---------------------------------------------------------------------------------------------------------------

    // Counts accepted input samples from 0 up to DECIMATION-1 and then starts again. 16 bits are enough for ratios up to
    // 65536. The initial value makes the counter correct after power-up even if no reset arrives.
    reg [15:0] sample_count = 16'd0;

    // The last count value of one round, written as a 16 bit constant so the comparison below has equal widths.
    localparam [15:0] LAST_COUNT = DECIMATION - 1;

    // High exactly when the sample that is accepted at the next in_strobe edge is the R-th one of a round.
    wire round_done = (sample_count == LAST_COUNT);

    // Starting value of the pulse register. The pulse is 0 after power-up.
    initial out_strobe = 1'b0;

    always @(posedge clock) begin
        if (rst_all) begin
            sample_count <= 16'd0;
            out_strobe   <= 1'b0;
        end else if (in_strobe) begin
            if (round_done) begin
                sample_count <= 16'd0;       // round finished, start the next one
                out_strobe   <= 1'b1;        // pulse for the clock after this edge
            end else begin
                sample_count <= sample_count + 16'd1;
                out_strobe   <= 1'b0;
            end
        end else begin
            out_strobe <= 1'b0;              // the pulse never lasts longer than one clock, and nothing else changes
        end
    end

    // ---------------------------------------------------------------------------------------------------------------
    // Integrator section: STAGES accumulators in a registered chain, running on in_strobe.
    // ---------------------------------------------------------------------------------------------------------------

    // The input sample widened to the width of the accumulators. Because the signal is declared signed, the assignment
    // copies the sign bit into all the new upper bits.
    wire signed [ACC_WIDTH-1:0] sample_wide = in_data;

    // The registered outputs of all integrators side by side, stage 1 in the lowest ACC_WIDTH bits.
    wire [STAGES*ACC_WIDTH-1:0] integ_out;

    genvar gi;
    generate
        for (gi = 0; gi < STAGES; gi = gi + 1) begin : integ
            // The first stage adds the input sample, every other stage adds the registered output of the stage before
            // it (the value it had before the common clock edge, because that is what a register output shows).
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
            // Comb 1 reads the last integrator, every other comb reads the registered output of the comb before it.
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

    // ---------------------------------------------------------------------------------------------------------------
    // Output scaling and rounding.
    // ---------------------------------------------------------------------------------------------------------------

    // The result of the last comb, which still has the full growth of the filter (gain R^N) in it.
    wire [ACC_WIDTH-1:0] comb_last = comb_out[(STAGES-1)*ACC_WIDTH +: ACC_WIDTH];

    // Dropping the lowest ACC_WIDTH-OUT_WIDTH bits divides by 2^(ACC_WIDTH-OUT_WIDTH), which brings the DC gain of
    // R^N back down to something that fits the output width. The shift only depends on the two widths, and not on the
    // ratio or the number of stages, so a design that changes R has to change ACC_WIDTH with it.
    wire [OUT_WIDTH-1:0] kept_bits = comb_last[ACC_WIDTH-1 -: OUT_WIDTH];

    // The highest bit that is thrown away. Adding it as 0 or 1 rounds to the nearest value, with exact halves going up.
    wire round_bit = comb_last[ACC_WIDTH-OUT_WIDTH-1];

    // The sum keeps OUT_WIDTH bits, so the largest positive word plus 1 wraps to the most negative word. Saturation is
    // not done, because a correctly sized filter never gets there.
    assign out_data = kept_bits + round_bit;

endmodule
