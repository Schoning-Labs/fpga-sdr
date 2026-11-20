// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// CicInterpM5: CIC interpolating filter for a complex (real and imaginary) sample stream, 5 stages, differential delay 1.
//
// What a CIC interpolator is: a CIC (cascaded integrator-comb) filter built from adders and registers only, with no
// multipliers (see docs/learn/GLOSSARY.md for the terms). As a decimator, a CIC filter adds up its input in a chain of
// integrators and lowers the sample rate afterwards. As an interpolator it works the other way around and raises the
// sample rate by a whole number R (the parameter RRRR). The signal first goes through a chain of N combs at the low
// input rate, where each comb outputs the difference between its current and its previous input. Then R-1 zeros are put
// after every sample (zero stuffing) so that the rate is R times higher, and the result goes through a chain of N
// integrators at the high output rate, where each integrator adds its input to a running total. The integrators smooth
// the stuffed zeros into a continuous curve, and the combined response is that of N cascaded moving averages of length R.
// Here N is 5, the differential delay of every comb is 1, and the module treats two channels, real and imaginary, that
// are exactly alike and independent of each other. The two share only the control logic.
//
// Where it sits in the radio: it is the last interpolating stage of the transmit chain in tx_chain.v. The FIR
// interpolator in front of it delivers 20 bit samples at a low rate, and this module raises the rate by RRRR = 400 to
// the 76.8 Msps pace at which the converter side runs. The output req is a one clock pulse that asks the FIR interpolator
// for the next input sample, so that the FIR stage calculates only when a new value is really needed.
//
// How it works, step by step, for either channel:
//   1. A 9 bit counter K counts the clock enables from 0 to RRRR-1. The flag P (the register capture_now below) is high
//      exactly when K is RRRR-1, and is kept as its own register so that nothing has to compare the counter on the
//      critical path.
//   2. At the clock enable where P is high the input sample is captured into the register X (sign extended to the
//      calculation width) and req is set, which makes req a one clock pulse in the clock after the capture.
//   3. At every clock enable where P is high the five combs step together as a registered chain. Comb 1 subtracts its delay
//      register from X, comb k subtracts its delay register from the output of comb k-1, and every stage stores its input
//      as the next delay. All of them use the values from before the edge, so X is still the sample captured at the
//      previous process edge, and one stage adds one input period of delay.
//   4. At every clock enable where P is low the last comb output is set to 0. This is the zero stuffing, so the first
//      integrator sees one real value and then R-1 zeros, repeatedly.
//   5. At every clock enable the five integrators add up as a registered chain. Integrator 1 adds the last comb output, and
//      integrator k adds integrator k-1, always from values before the edge.
//   6. The output is the top OBITS bits of the last integrator, rounded to nearest with the bit below them (round half up),
//      and it is plain logic with no register behind it.
//
// Bit growth and why wrap-around is fine: the DC gain from input to output is R^(N-1), so for N = 5 the filter makes
// the signal bigger by a factor of R^4, which needs GBITS = ceil(log2(R^4)) extra bits (35 for R = 400). The calculation
// width C is therefore IBITS + GBITS, which is 55 bits with the defaults, and every register in the combs and the
// integrators has C bits. The integrators in particular grow without limit when their input has a constant part, so they
// are allowed to overflow. All numbers are two's complement, so an overflow only moves a total to the other end of the
// number range, which is arithmetic modulo 2^C, and the sum of the whole chain is still right modulo 2^C. As long as
// the final output fits into C bits it is exact, and for that reason nothing in the chain saturates or rounds before the
// output.
//
// The output shift is C - OBITS, which is 31 with the defaults, so y is the last integrator divided by 2^31 and rounded.
//
// Timing, with ce being a clock edge at which the enable is high:
//   - A sample is captured at every RRRR-th ce, the first one being the RRRR-th ce after power-up (K starts at 0).
//   - req is high in the clock after the capture edge, and low whenever clock_en is low. The caller has to present the next
//     input within the next RRRR clock enables, and tx_chain.v uses req to calculate exactly that sample.
//   - A comb result is created on a process edge and exists for exactly one ce (it is added into integrator 1 at the next
//     ce and cleared by the zero stuffing). With RRRR = 1 it is never cleared.
//   - A captured sample reaches the last comb register 5 process edges after its capture, and the first change of y
//     comes 5 * RRRR + 5 enables after the capture edge (RRRR = 400 gives 2005), and the last integrator shows
//     a result 4 enables after the first one has taken it.
//   - y changes only in the cycle after a clock enable of the integrator group. Gating clock_en low freezes everything, and
//     only req is forced to 0.
//
// There is no reset input. All state comes from the initial values below, which the Gowin tools honor on the chip and which
// simulators need to avoid X values. The registers all start at 0, and P starts at 1 only when RRRR is 1.
//
// Clock enable copies: with a total of 5 register groups at 76.8 MHz the enable signal has a large fan-out, so the caller may
// deliver CE_COPIES = 5 equal copies in the vector clock_en, and each group uses its own copy. The groups are numbered 0
// for the control (counter, P, X, req), 1 and 2 for the combs of the real and imaginary channel, and 3 and 4 for the
// integrators of the real and imaginary channel, and group g uses bit (g mod CE_COPIES) of clock_en. With CE_COPIES = 1
// every group uses bit 0. The copies have to be driven with equal values, and P is updated by copy 0 only.
//
// Gowin specific points: ordinary fabric only (adder carry chains and flip-flops, where each of the 2 channels has 5 comb
// outputs, 5 comb delays, 5 integrators and 1 input register of C bits), with no block RAM and no DSP block. Every enable is a plain clock enable on
// the single global clock line.

module CicInterpM5 #(
    // Interpolation ratio R, legal 1 to 512 (the counter K has 9 bits).
    parameter RRRR      = 400,
    // Width of the input samples in bits.
    parameter IBITS     = 20,
    // Width of the output samples in bits.
    parameter OBITS     = 24,
    // Growth bits, ceil(log2(R^4)), which is 35 for R = 400.
    parameter GBITS     = 35,
    // Number of copies of the clock enable, 1 or 5.
    parameter CE_COPIES = 1
) (
    input  wire                       clock,     // system clock, all registers change on its rising edge
    input  wire [CE_COPIES-1:0]       clock_en,  // enable at the output sample rate, all bits carry the same value
    output reg                        req,       // one clock pulse that asks the caller for the next input sample
    input  wire signed [IBITS-1:0]    x_real,    // input sample, real part, signed, read at the capture edge
    input  wire signed [IBITS-1:0]    x_imag,    // input sample, imaginary part, signed, read at the capture edge
    output wire signed [OBITS-1:0]    y_real,    // output sample, real part, signed, combinational from the last integrator
    output wire signed [OBITS-1:0]    y_imag     // output sample, imaginary part, signed, combinational from the last integrator
);

    // Calculation width of all combs and integrators, 55 bits with the defaults.
    localparam C = IBITS + GBITS;

    // The count value at which a sample is captured, one less than the ratio.
    localparam [8:0] LAST_K = RRRR - 1;

    // ---------------------------------------------------------------------------------------------------------------
    // Control group: counter K, flag P and the pulse req. It uses clock enable copy 0.
    // ---------------------------------------------------------------------------------------------------------------

    // The enable for each register group, picked from the copies as bit (group mod CE_COPIES).
    wire ce_control   = clock_en[0 % CE_COPIES];
    wire ce_comb_r    = clock_en[1 % CE_COPIES];
    wire ce_comb_i    = clock_en[2 % CE_COPIES];
    wire ce_integ_r   = clock_en[3 % CE_COPIES];
    wire ce_integ_i   = clock_en[4 % CE_COPIES];

    // Counter of clock enables within one input period, from 0 to RRRR-1.
    reg [8:0] k_count = 9'd0;

    // High while k_count equals RRRR-1, so it is the flag "the next enabled edge is the capture and combs edge". For
    // RRRR = 1 the counter never leaves 0 and the flag is high from the start.
    reg capture_now = (RRRR == 1);

    // The counter value one step ahead, used both to move the counter and to prepare the flag for the next round.
    wire [8:0] k_next = capture_now ? 9'd0 : (k_count + 9'd1);

    initial req = 1'b0;

    always @(posedge clock) begin
        if (ce_control) begin
            k_count <= k_next;
            capture_now <= (k_next == LAST_K);   // the flag follows the counter, one clock enable ahead
            req     <= capture_now;              // pulse in the clock after the capture edge
        end else begin
            req <= 1'b0;                     // nothing happens while the enable is low, and req is never held
        end
    end

    // ---------------------------------------------------------------------------------------------------------------
    // The two channels. Both are built the same way, only the input, the enables and the output differ.
    // ---------------------------------------------------------------------------------------------------------------

    // The inputs and outputs of the two channels side by side, real part in the lowest bits.
    wire [2*IBITS-1:0] x_both = {x_imag, x_real};
    wire [2*OBITS-1:0] y_both;

    assign y_real = y_both[0*OBITS +: OBITS];
    assign y_imag = y_both[1*OBITS +: OBITS];

    genvar ch;
    generate
        for (ch = 0; ch < 2; ch = ch + 1) begin : chan

            // The clock enables of this channel's comb group and integrator group.
            wire ce_comb  = (ch == 0) ? ce_comb_r  : ce_comb_i;
            wire ce_integ = (ch == 0) ? ce_integ_r : ce_integ_i;

            // The input sample of this channel, picked out of the pair and widened to the calculation width (a signed
            // wire copies the sign bit into the new upper bits).
            wire signed [IBITS-1:0] x_in   = x_both[ch*IBITS +: IBITS];
            wire signed [C-1:0]     x_wide = x_in;

            // The captured input sample, taken when the control group reaches the end of a round.
            reg signed [C-1:0] x_hold = {C{1'b0}};

            always @(posedge clock) begin
                if (ce_control && capture_now)
                    x_hold <= x_wide;
            end

            // -------------------------------------------------------------------------------------------------------
            // Comb section, 5 stages. Every stage has its own output register and its own delay register, declared
            // inside the loop, and comb_out collects the five outputs side by side with stage 1 in the lowest C bits.
            // -------------------------------------------------------------------------------------------------------
            wire [5*C-1:0] comb_out;

            genvar st;
            for (st = 0; st < 5; st = st + 1) begin : comb
                // What this stage subtracts from: the held sample for stage 1, the output of the stage before for the others.
                wire signed [C-1:0] stage_in;
                if (st == 0) begin : first
                    assign stage_in = x_hold;
                end else begin : later
                    assign stage_in = comb_out[(st-1)*C +: C];
                end

                reg signed [C-1:0] out_reg   = {C{1'b0}};   // result of this stage
                reg signed [C-1:0] delay_reg = {C{1'b0}};   // the input this stage saw at the previous process edge

                // The difference of this stage, formed with C bits so that it wraps modulo 2^C.
                wire signed [C-1:0] stage_diff = stage_in - delay_reg;

                always @(posedge clock) begin
                    if (ce_comb) begin
                        if (capture_now) begin
                            out_reg   <= stage_diff;
                            delay_reg <= stage_in;
                        end else if (st == 4) begin
                            out_reg <= {C{1'b0}};   // zero stuffing, only the last comb output is cleared
                        end
                    end
                end

                assign comb_out[st*C +: C] = out_reg;
            end

            // -------------------------------------------------------------------------------------------------------
            // Integrator section, 5 stages, running on every enable of the integrator group. integ_out collects the
            // five totals side by side with stage 1 in the lowest C bits.
            // -------------------------------------------------------------------------------------------------------
            wire [5*C-1:0] integ_out;

            genvar sj;
            for (sj = 0; sj < 5; sj = sj + 1) begin : integrator
                // Stage 1 adds the last comb output, the other stages add the output of the stage before them.
                wire signed [C-1:0] stage_in;
                if (sj == 0) begin : first
                    assign stage_in = comb_out[4*C +: C];
                end else begin : later
                    assign stage_in = integ_out[(sj-1)*C +: C];
                end

                reg signed [C-1:0] total = {C{1'b0}};

                // The new total, formed with C bits so that it wraps modulo 2^C.
                wire signed [C-1:0] stage_sum = total + stage_in;

                always @(posedge clock) begin
                    if (ce_integ)
                        total <= stage_sum;
                end

                assign integ_out[sj*C +: C] = total;
            end

            // -------------------------------------------------------------------------------------------------------
            // Output: the top OBITS bits of the last integrator, plus the bit below them as 0 or 1 for rounding.
            // -------------------------------------------------------------------------------------------------------
            wire [C-1:0]     integ_last = integ_out[4*C +: C];
            wire [OBITS-1:0] top_bits   = integ_last[C-1 -: OBITS];
            wire             round_bit  = integ_last[C-OBITS-1];

            // The sum keeps OBITS bits, so the largest positive word plus 1 wraps to the most negative word.
            assign y_both[ch*OBITS +: OBITS] = top_bits + round_bit;
        end
    endgenerate

endmodule
