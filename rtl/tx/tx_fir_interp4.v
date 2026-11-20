// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// tx_fir_interp4: first stage of the transmit chain, a polyphase FIR interpolator that raises the sample rate by 4.
//
// What it does
//   Takes complex baseband (I and Q, 48 kHz) and produces I and Q at 192 kHz, four output pairs for every input pair.
//   Raising a sample rate by 4 means putting three zeros between the samples and then removing the images that
//   this creates (copies of the signal around 48 kHz, 96 kHz and so on) with a low-pass filter.  The pass band of
//   this filter is +-12 kHz and its stop band starts at 36 kHz, which is 48 kHz minus the 12 kHz edge of the nearest
//   image.  The same real-valued filter is applied to I and to Q.  The glossary entries "Interpolation",
//   "Polyphase", "FIR filter" and "Tap" in docs/learn/GLOSSARY.md explain the terms.
//
//   Because the signal is only +-12 kHz wide against the 192 kHz input rate of the CIC interpolator that follows,
//   the CIC's droop at 12 kHz is only 0.28 dB (docs/X1_TX.md) and no separate droop compensation stage is needed.
//
// Where it sits in the radio
//   Fed by: the TX ring reader through tx_chain.v (x_real, x_imag, 16 bit).  Feeds: the CIC interpolator
//   (CicInterpM5.v) in tx_chain.v, which asks for each output pair with `calc`.
//
// How it works
//   The coefficients (rtl/tx/fir_coeffs.vh) are 40 taps from a Parks-McClellan design (tools/design_tx_fir.py), 18 bit,
//   Q17, split into 4 phases of 10 taps.  Phase p is used for output number p of each input sample, and one output
//   is the sum of 10 products of the last 10 input samples with the 10 coefficients of that phase (the other
//   three quarters of a plain filter's taps would be multiplications by the inserted zeros, so they are skipped).
//
//   The calculation is time-multiplexed onto one multiplier that serves every tap of both I and Q.  That is
//   possible because `calc` is the CIC's own `req`, which comes only once per 400 clocks of the 76.8 MHz output
//   rate, so the result is only needed 400 clocks after it was asked for and a serial pass of about 25 clocks (20 for
//   the taps and a few for the pipeline) has a margin of 16 times.  The sum is the same exact integer arithmetic
//   whatever order the products are added in, so it gives the same result as 20 parallel multipliers would; this
//   module uses 1 DSP block and about 0.66 k logic cells instead of 20 DSP blocks and 12 k cells.
//
// Protocol
//   - `calc` pulses once per output pair wanted (4 pulses per input sample).
//   - `req` pulses for one clock on the edge where the 4th (last) phase of an input sample has been produced, to ask for
//     the next 48 kHz sample.  The new sample is captured from x_real and x_imag on that same edge, so the source has
//     to show the next sample before it is asked for, as the head of a FIFO does, and take it off when `req` is high.
//   - `y_real` and `y_imag` are valid and held about 25 clocks after `calc` (see "Timing pipeline" below) until
//     the next calculation completes.
//
// Gowin specifics
//   One 18 x 16 multiplier (a single `*`, mapped by the synthesizer onto one DSP block), the coefficient arrays
//   in distributed ROM (LUTs, see fir_coeffs.vh) and the sample history in flip-flops.

`timescale 1ns / 1ps

module tx_fir_interp4 #(
    // IBITS      width of the input samples, 16 bit.
    // OBITS      width of the output samples, 20 bit (IBITS plus 4 guard bits that keep the filter's precision).
    // COEFW      width of a coefficient, 18 bit, Q17.
    // NP         taps per phase, 10 (the 40 coefficients of fir_coeffs.vh divided by 4).
    parameter IBITS = 16,
    parameter OBITS = 20,
    parameter COEFW = 18,
    parameter NP    = 10    // taps per phase (fir_coeffs.vh: NUMTAPS/4)
) (
    // Clock (the 76.8 MHz-rate clock of tx_chain, clk_dsp in the radio) and synchronous reset (active high).
    input  wire                    clock,
    input  wire                    rst,
    // calc: one-clock request for an output pair.  req: one-clock request for the next input sample.
    input  wire                    calc,
    output reg                     req,
    // Input sample (signed, IBITS wide) and output pair (signed, OBITS wide).
    input  wire signed [IBITS-1:0] x_real,
    input  wire signed [IBITS-1:0] x_imag,
    output reg  signed [OBITS-1:0] y_real,
    output reg  signed [OBITS-1:0] y_imag
);

`include "rtl/tx/fir_coeffs.vh"

    // Sample history, newest first; hist_*[0] is the most recently accepted input sample.
    // Kept in flip-flops (syn_srlstyle): otherwise Gowin synthesis makes this shift register a
    // LUT-RAM circular buffer whose pointer arithmetic sits in front of the multiplier's input.
    (* syn_srlstyle = "registers" *) reg signed [IBITS-1:0] hist_i [0:NP-1];
    (* syn_srlstyle = "registers" *) reg signed [IBITS-1:0] hist_q [0:NP-1];
    // phase (0..3) says which of the four outputs of the current input sample is next.
    reg [1:0] phase;

    // Product width: IBITS + COEFW, plus guard bits for summing NP taps.
    localparam PW    = IBITS + COEFW;
    localparam GUARD = 4;                 // ceil(log2(NP)) for NP<=16
    localparam ACCW  = PW + GUARD;
    // Coefficients are Q(COEFW-1) (sum(h) ~= 2**(COEFW-1)); shift back down to OBITS,
    // which itself carries (OBITS-IBITS) extra guard/precision bits over the input.
    localparam SHIFT = (COEFW - 1) - (OBITS - IBITS);

    reg signed [ACCW-1:0] acc_i, acc_q;
    integer k;

    // -- one-multiplier time-multiplexing --------------------------------------------------
    // State machine: idle (busy = 0) waits for `calc`.  busy = 1 walks `tap` through 0 .. NP-1 twice, once for I and
    // once for Q, and issues one product per clock into the single shared multiplier below.  The products, the sum
    // and the rounding follow through a short pipeline (see "Timing pipeline" below).
    reg       busy;
    reg [3:0] tap;      // 0..NP-1 (NP<=16, same assumption as GUARD above)
    reg       doing_q;

    // Coefficient lookup for the current phase and tap: a small run-time-indexed mux over the
    // four per-phase coefficient arrays (fir_coeffs.vh), replacing the fully unrolled case of
    // the old design. Sample lookup (hist_i[tap]/hist_q[tap]) is the same kind of run-time mux
    // over the history registers.
    reg signed [COEFW-1:0] coef_sel;
    always @(*) begin
        case (phase)
            2'd0: coef_sel = PHASE0_COEF[tap];
            2'd1: coef_sel = PHASE1_COEF[tap];
            2'd2: coef_sel = PHASE2_COEF[tap];
            default: coef_sel = PHASE3_COEF[tap];
        endcase
    end

    wire signed [IBITS-1:0] mul_a = doing_q ? hist_q[tap] : hist_i[tap];
    wire last_tap = (tap == NP-1);

    // Timing pipeline: the selection of sample and coefficient, the multiplication, the accumulation and the final
    // rounding each get their own clock, instead of all being done in one clock (history mux, multiply, 38-bit
    // add and rounding in one go is 22 logic levels, which does not reach 120 MHz).  The state machine above
    // still issues one tap per clock; each product reaches its accumulator four clocks later, and y_real and y_imag
    // (and the phase, history shift and req bookkeeping) are updated five clocks after the last tap is issued.  That
    // is invisible to tx_chain, because `calc` comes only every 400 clocks.
    //   s0: register the selected sample and coefficient
    //   s1: the shared multiplier's input registers (synthesis puts these inside the DSP
    //       block, so the selection needs the plain register s0 in front of them)
    //   s2: register the product (the one shared multiplier)
    //   s3: accumulate into acc_i or acc_q
    //   s4: round both accumulators into y_real and y_imag, and do the phase, history and req bookkeeping
    // Pipeline registers: _a is the sample, _c the coefficient, _p the product; _v says the stage holds a real tap,
    // _q says it is a Q tap (otherwise I), and _last marks the final tap of the pass.
    reg signed [IBITS-1:0] s0_a;
    reg signed [COEFW-1:0] s0_c;
    reg                    s0_v, s0_q, s0_last;
    reg signed [IBITS-1:0] s1_a;
    reg signed [COEFW-1:0] s1_c;
    reg                    s1_v, s1_q, s1_last;
    reg signed [PW-1:0]    s2_p;
    reg                    s2_v, s2_q, s2_last;
    reg                    s3_last;
    // The one shared multiplier: a single textual instance of `*`, time-shared across all
    // NP*2 tap x {I, Q} products of one output sample.
    wire signed [PW-1:0]   product = s1_a * s1_c;

    always @(posedge clock) begin
        if (rst) begin
            phase   <= 2'd0;
            req     <= 1'b0;
            y_real  <= {OBITS{1'b0}};
            y_imag  <= {OBITS{1'b0}};
            busy    <= 1'b0;
            tap     <= 4'd0;
            doing_q <= 1'b0;
            acc_i   <= {ACCW{1'b0}};
            acc_q   <= {ACCW{1'b0}};
            s0_a    <= {IBITS{1'b0}};
            s0_c    <= {COEFW{1'b0}};
            s0_v    <= 1'b0;
            s0_q    <= 1'b0;
            s0_last <= 1'b0;
            s1_a    <= {IBITS{1'b0}};
            s1_c    <= {COEFW{1'b0}};
            s1_v    <= 1'b0;
            s1_q    <= 1'b0;
            s1_last <= 1'b0;
            s2_p    <= {PW{1'b0}};
            s2_v    <= 1'b0;
            s2_q    <= 1'b0;
            s2_last <= 1'b0;
            s3_last <= 1'b0;
            for (k = 0; k < NP; k = k + 1) begin
                hist_i[k] <= {IBITS{1'b0}};
                hist_q[k] <= {IBITS{1'b0}};
            end
        end else begin
            req <= 1'b0;   // default; pulsed for exactly one cycle below

            // ---- issue: walk tap 0..NP-1 for I, then again for Q, one per clock ----
            if (!busy) begin
                if (calc) begin
                    busy    <= 1'b1;
                    tap     <= 4'd0;
                    doing_q <= 1'b0;
                    acc_i   <= {ACCW{1'b0}};
                    acc_q   <= {ACCW{1'b0}};
                end
            end else if (last_tap) begin
                tap <= 4'd0;
                if (!doing_q)
                    doing_q <= 1'b1;
                else
                    busy <= 1'b0;
            end else begin
                tap <= tap + 4'd1;
            end

            // ---- s0: operand registers ----

            s0_a    <= mul_a;
            s0_c    <= coef_sel;
            s0_v    <= busy;
            s0_q    <= doing_q;
            s0_last <= busy && doing_q && last_tap;

            // ---- s1: multiplier input registers ----
            s1_a    <= s0_a;
            s1_c    <= s0_c;
            s1_v    <= s0_v;
            s1_q    <= s0_q;
            s1_last <= s0_last;

            // ---- s2: product register ----
            s2_p    <= product;
            s2_v    <= s1_v;
            s2_q    <= s1_q;
            s2_last <= s1_last;

            // ---- s3: accumulate (acc_* are cleared by the issue stage on `calc`, which is at
            // least CIC_R clocks after the previous pass's last product landed here) ----
            if (s2_v) begin
                if (s2_q)
                    acc_q <= acc_q + s2_p;
                else
                    acc_i <= acc_i + s2_p;
            end
            s3_last <= s2_last;

            // ---- s4: both sums complete. Round to nearest -- keep the top OBITS bits of the
            // shifted accumulator, biased by the next lower bit (matches the HL2 modules' own
            // truncate-and-bias convention) -- and do the phase/hist-shift/req bookkeeping. ----
            if (s3_last) begin
                y_real <= acc_i[SHIFT+OBITS-1 -: OBITS] + acc_i[SHIFT-1];
                y_imag <= acc_q[SHIFT+OBITS-1 -: OBITS] + acc_q[SHIFT-1];

                if (phase == 2'd3) begin
                    req <= 1'b1;
                    for (k = NP-1; k > 0; k = k - 1) begin
                        hist_i[k] <= hist_i[k-1];
                        hist_q[k] <= hist_q[k-1];
                    end
                    hist_i[0] <= x_real;
                    hist_q[0] <= x_imag;
                    phase <= 2'd0;
                end else begin
                    phase <= phase + 2'd1;
                end
            end
        end
    end

endmodule
