// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// audio_interp_x8: raises the audio sample rate by 8, from 48 kHz to 384 kHz, for the PT8211 DAC.
//
// What it does
//   Every 48 kHz period one stereo sample (left and right, signed 16 bit) comes in, and eight stereo samples at
//   384 kHz go out, evenly spaced, one per `frame_tick`.  The result sounds the same as the input, but its
//   images (the copies of the audio spectrum that every sampled signal has around multiples of its sample rate)
//   start near 364 kHz instead of near 28 kHz, where a cheap analog output stage can remove them.  The glossary
//   entries "Interpolation", "Polyphase", "FIR filter" and "Tap" in docs/learn/GLOSSARY.md explain the terms.
//
// Where it sits in the radio
//   Fed by:  audio_ring_reader.v (48 kHz samples on a valid/ready port).
//   Feeds:   audio_pt8211_tx.v (384 kHz samples, which also supplies the `frame_tick` that paces this block).
//
// How it works
//   The textbook way is to insert seven zeros after every input sample and run the 384 kHz stream through a
//   low-pass FIR filter of 144 taps.  Seven out of eight inputs of that filter are zero, so almost all of its
//   multiplications would be by zero.  The polyphase form skips them: the 144 coefficients are split into 8
//   groups ("phases") of 18, where phase p holds coefficients p, p+8, p+16 and so on up to p+136.  One output sample
//   is the sum of 18 products of the last 18 real input samples with the 18 coefficients of the current phase,
//   and successive outputs use phases 0, 1, ... 7 and then start again with phase 0 when the next input sample has
//   arrived.  The filter (a Parks-McClellan design) has a flat pass band up to 18 kHz (0.008 dB ripple) and a
//   stop band from 28 kHz at -65.7 dB; its group delay is 8.9 input samples (186 us), and the design figures and the
//   measured image levels are in docs/A1_AUDIO.md.  It is the cheapest filter that puts the first image of a
//   20 kHz tone (at 28 kHz) 60 dB down, at the price of about 21 dB of droop at 20 kHz, so the very top of the audio
//   band is rolled off.
//
//   Because there are 312 clocks of 120 MHz between two output samples (120 MHz / 384 kHz), one multiplier
//   per channel is enough: the 18 products of an output sample are computed one per clock, and the rest of the
//   time the block is idle.  There is no parallel hardware here on purpose, it keeps timing closure easy.
//
// Interface
//   - `frame_tick`: a one-clock pulse at an average of 384 kHz from audio_pt8211_tx.v.  Each tick starts the
//     calculation of one output sample.
//   - 48 kHz input: a valid/ready port in which this block drives `smp_ready` for exactly one clock on every 8th
//     `frame_tick` (once per 48 kHz period).  The source shows `smp_valid` and stable `smp_l` and `smp_r`
//     whenever it has data, and the transfer happens on the clock where both are high.  If `smp_ready` is high
//     and `smp_valid` is not (the prefetch FIFO ran dry), the block does not advance its history, which repeats
//     the last input sample once more, and pulses `underrun` for one clock.
//   - 384 kHz output: `out_l` and `out_r` change together with a one-clock `out_valid` pulse, exactly
//     TAPS_PER_PHASE + 5 = 23 clocks after the `frame_tick` that asked for them (18 clocks for the taps and 5 for
//     the pipeline described at "sequential MAC" below).  That is far inside one 312-clock frame.
//
// Fixed point
//   Samples are signed 16 bit integers (full scale +/-32767).  Coefficients are signed 18 bit in Q17 format
//   (the real coefficient times 2^17, rounded).  The sum of products is kept in a 40-bit accumulator, which is far
//   wider than the largest value 18 products of 16 x 18 bits can reach.  A unity-gain interpolation filter has to
//   be scaled up by 8 to give the zero-stuffed samples back their amplitude, so the result is multiplied by 8,
//   which together with the Q17 scale is a right shift by 17 - 3 = 14 bits, then rounded to the nearest integer
//   and saturated to 16 bit.
//
// Gowin specifics
//   There is no block RAM: the coefficient ROM is 144 x 18 bit and is loaded from `COEFF_FILE` with $readmemh.
//   The multiplications are written as plain `*` with no Gowin primitive instantiated, and are
// left for synthesis (and a later P&R pass) to map onto the GW5AST's embedded multipliers.

`timescale 1ns / 1ps

module audio_interp_x8 #(
    // IN_WIDTH      width of the audio samples, 16 bit.
    // COEFF_WIDTH   width of one coefficient, 18 bit, Q17.
    // TAPS_PER_PHASE number of taps in one polyphase branch, 18 (144 taps / 8 phases).
    // NUM_PHASES    interpolation ratio, 8 (a power of two, so the phase counter wraps by itself).
    // ACC_WIDTH     width of the accumulator, 40 bit.
    // COEFF_FILE    hex file with the 144 coefficients, one per line, in direct-form order (tap 0 first).
    parameter integer IN_WIDTH        = 16,
    parameter integer COEFF_WIDTH     = 18,
    parameter integer TAPS_PER_PHASE  = 18,
    parameter integer NUM_PHASES      = 8,
    parameter integer ACC_WIDTH       = 40,
    parameter         COEFF_FILE      = "rtl/audio/audio_interp_coeffs.hex"
) (
    // Clock (clk_dsp, 120 MHz) and synchronous reset, active high.
    input  wire                        clk,
    input  wire                        rst,

    // Pace from audio_pt8211_tx.v: a one-clock pulse each 384 kHz word.
    input  wire                        frame_tick,

    // 48 kHz input side (see Interface above).  smp_ready is a one-clock request, smp_valid says the source has a
    // sample, smp_l and smp_r are the sample (signed), underrun is a one-clock pulse when none was there.
    output wire                        smp_ready,
    input  wire                        smp_valid,
    input  wire signed [IN_WIDTH-1:0]  smp_l,
    input  wire signed [IN_WIDTH-1:0]  smp_r,
    output reg                         underrun,

    // 384 kHz output side: the interpolated sample pair (signed 16 bit), valid on the clock where out_valid is high
    // and held until the next output.
    output reg  signed [IN_WIDTH-1:0]  out_l,
    output reg  signed [IN_WIDTH-1:0]  out_r,
    output reg                         out_valid
);

    // Sizes derived from the parameters: bits to count the phases, bits to count the taps, number of coefficients.
    localparam integer PHASE_BITS = $clog2(NUM_PHASES);
    localparam integer TAP_BITS   = $clog2(TAPS_PER_PHASE);
    localparam integer ROM_DEPTH  = TAPS_PER_PHASE * NUM_PHASES;

    // ---------------------------------------------------------------- coefficient ROM
    // Coefficient ROM.  Distributed (LUT) ROM, 144 words of 18 bit, read one word per clock in the MAC pipeline below.
    reg signed [COEFF_WIDTH-1:0] coeff_rom [0:ROM_DEPTH-1];
    initial $readmemh(COEFF_FILE, coeff_rom);

    // Index of the coefficient for phase p and tap k in the direct-form filter: tap number 8k + p, so that phase p
    // picks every 8th coefficient starting at p.
    function [$clog2(ROM_DEPTH)-1:0] rom_addr(input [PHASE_BITS-1:0] p, input [TAP_BITS-1:0] k);
        rom_addr = k * NUM_PHASES + p;
    endfunction

    // ---------------------------------------------------------------- input delay line
    // Input history: the last TAPS_PER_PHASE input samples per channel, newest in entry 0.  A sample is shifted in
    // once per 48 kHz period, and the multiplier reads entries directly by tap index.
    // Kept in flip-flops (syn_srlstyle): left to itself Gowin synthesis turns this shift register
    // into a LUT-RAM circular buffer with a modulo-18 pointer, and the pointer + tap_idx
    // arithmetic in front of the RAM read address was this block's critical path.
    (* syn_srlstyle = "registers" *) reg signed [IN_WIDTH-1:0] dly_l [0:TAPS_PER_PHASE-1];
    (* syn_srlstyle = "registers" *) reg signed [IN_WIDTH-1:0] dly_r [0:TAPS_PER_PHASE-1];
    integer di;

    // ---------------------------------------------------------------- phase / frame sequencing
    // phase_reg counts the 384 kHz outputs inside one 48 kHz period (0..7) and wraps after 7.  The input sample
    // is requested on the tick that finishes phase 7, so a new sample is always available for phase 0.
    reg [PHASE_BITS-1:0] phase_reg;
    wire want_new_sample = frame_tick && (phase_reg == NUM_PHASES - 1);
    assign smp_ready = want_new_sample;

    wire consume = smp_ready && smp_valid;

    always @(posedge clk) begin
        if (rst) begin
            phase_reg <= {PHASE_BITS{1'b0}};
        end else if (frame_tick) begin
            if (phase_reg == NUM_PHASES - 1)
                phase_reg <= {PHASE_BITS{1'b0}};
            else
                phase_reg <= phase_reg + 1'b1;
        end
    end

    // A new sample is taken on the clock where smp_ready and smp_valid are both high, but it is not shifted into
    // the delay line at once.  That clock is the very one on which the multiplier pass for phase 7 starts, and
    // the pass still has to read the old contents of the delay line.  Shifting right then would show the pass the
    // new samples one clock later, and every 8th output would come out wrong.  So the new sample waits in
    // pend_l and pend_r until that pass has finished (see shift_pending and shift_go below), which is always
    // long before the next tick: 18 clocks against about 312.
    reg                        shift_pending;
    reg signed [IN_WIDTH-1:0]  pend_l, pend_r;

    // Declared here, ahead of their use, because the delay-line block needs them; they are driven by the
    // multiplier sequencing further down.
    reg                     busy;
    reg [TAP_BITS-1:0]      tap_idx;
    // apply_shift is true on the clock where the running pass reads its last tap, which is the first clock where the
    // old delay line contents are no longer needed.
    wire apply_shift = busy && shift_pending && (tap_idx == TAPS_PER_PHASE - 1);
    reg  shift_go;
    // shift_go is apply_shift one clock later, a register (see the comment in the block below).
    always @(posedge clk)
        shift_go <= !rst && apply_shift;

    // Delay line and input handshake: remember a taken sample, flag an underrun, and shift the line.
    always @(posedge clk) begin
        if (rst) begin
            underrun      <= 1'b0;
            shift_pending <= 1'b0;
            pend_l        <= {IN_WIDTH{1'b0}};
            pend_r        <= {IN_WIDTH{1'b0}};
            for (di = 0; di < TAPS_PER_PHASE; di = di + 1) begin
                dly_l[di] <= {IN_WIDTH{1'b0}};
                dly_r[di] <= {IN_WIDTH{1'b0}};
            end
        end else begin
            underrun <= want_new_sample && !smp_valid;
            if (consume) begin
                shift_pending <= 1'b1;
                pend_l        <= smp_l;
                pend_r        <= smp_r;
            end
            // The shift happens one clock after the last tap was read (shift_go, a registered copy of apply_shift),
            // and not on that clock itself, because it is a clock enable on all 2 x 18 x 16 delay-line flip-flops
            // and decoding it from tap_idx in the same clock was a critical path.  The next pass starts about
            // 312 clocks later, so the extra clock does not matter.
            if (shift_go) begin
                shift_pending <= 1'b0;
                dly_l[0] <= pend_l;
                dly_r[0] <= pend_r;
                for (di = 1; di < TAPS_PER_PHASE; di = di + 1) begin
                    dly_l[di] <= dly_l[di-1];
                    dly_r[di] <= dly_r[di-1];
                end
            end
        end
    end

    // ---------------------------------------------------------------- sequential MAC
    // Sequential multiply-accumulate.  On `frame_tick` the phase is copied into phase_snap and 18 taps are
    // issued, one per clock, reading the delay line live.  That is safe (see shift_pending above): the only shift
    // that could land in the middle of a pass is the deferred one, which takes effect after the pass's last tap
    // has been read.
    //
    // The datapath is cut into stages so that each clock does one thing only (an 18-way delay-line selection,
    // the multiplication, a 40-bit addition and the rounding in a single clock would not reach 120 MHz).  The
    // numbers are the same as in a single-clock version, they only appear 5 clocks later:
    //   s0: register the selected samples and the coefficient (this is also the coefficient ROM read)
    //   s0: register the selected samples and coefficient (the coefficient ROM read)
    //   s1: the multiplier's input registers (synthesis puts these inside the DSP block, so
    //       they need a plain register, s0, in front of them for the selection logic)
    //   s2: register the two products (left and right)
    //   s3: accumulate into acc_l and acc_r
    //   s4: round, which means adding half an LSB of the output (BIAS) and shifting right by SHIFT
    //   s5: saturate to 16 bit into out_l and out_r, and pulse out_valid
    // The _v and _last registers travel with the data and say "this stage holds a real tap" and "this is the
    // pass's final tap", which is what starts the rounding and the output pulse.
    reg [PHASE_BITS-1:0]    phase_snap;
    reg signed [ACC_WIDTH-1:0] acc_l, acc_r;

    reg signed [IN_WIDTH-1:0]    s0_l, s0_r;
    reg signed [COEFF_WIDTH-1:0] s0_c;
    reg                          s0_v, s0_last;
    reg signed [IN_WIDTH-1:0]    s1_l, s1_r;
    reg signed [COEFF_WIDTH-1:0] s1_c;
    reg                          s1_v, s1_last;
    reg signed [IN_WIDTH+COEFF_WIDTH-1:0] s2_l, s2_r;
    reg                          s2_v, s2_last;
    reg                          s3_last;
    reg signed [ACC_WIDTH-1:0]   s4_l, s4_r;
    reg                          s4_v;

    wire signed [IN_WIDTH+COEFF_WIDTH-1:0] prod_l = s1_l * s1_c;
    wire signed [IN_WIDTH+COEFF_WIDTH-1:0] prod_r = s1_r * s1_c;

    // result = round(acc x 8 / 2^17) = round(acc / 2^14): the 8 restores the amplitude of the zero-stuffed input
    // and 2^17 is the Q17 scale of the coefficients, so the right shift is COEFF_FRAC - 3 = 14 bits.
    localparam integer SHIFT = COEFF_WIDTH - 1 - 3; // 17 - 3 = 14
    // The limits and the rounding bias are computed in accumulator-wide signed arithmetic, so that the most
    // negative 16-bit value does not overflow the way a same-width negation would.
    localparam signed [ACC_WIDTH-1:0] OUT_MAX = (1 <<< (IN_WIDTH - 1)) - 1;
    localparam signed [ACC_WIDTH-1:0] OUT_MIN = -(1 <<< (IN_WIDTH - 1));
    localparam signed [ACC_WIDTH-1:0] BIAS    = (1 <<< (SHIFT - 1));

    // Saturate: values outside the 16-bit range are clamped to the nearest end, anything else passes through.
    function signed [IN_WIDTH-1:0] sat(input signed [ACC_WIDTH-1:0] shifted);
        begin
            if (shifted > OUT_MAX)
                sat = OUT_MAX[IN_WIDTH-1:0];
            else if (shifted < OUT_MIN)
                sat = OUT_MIN[IN_WIDTH-1:0];
            else
                sat = shifted[IN_WIDTH-1:0];
        end
    endfunction

    // MAC sequencer and pipeline stages.
    always @(posedge clk) begin
        if (rst) begin
            busy      <= 1'b0;
            tap_idx   <= {TAP_BITS{1'b0}};
            acc_l     <= {ACC_WIDTH{1'b0}};
            acc_r     <= {ACC_WIDTH{1'b0}};
            out_l     <= {IN_WIDTH{1'b0}};
            out_r     <= {IN_WIDTH{1'b0}};
            out_valid <= 1'b0;
            s0_v      <= 1'b0;
            s0_last   <= 1'b0;
            s1_v      <= 1'b0;
            s1_last   <= 1'b0;
            s2_v      <= 1'b0;
            s2_last   <= 1'b0;
            s3_last   <= 1'b0;
            s4_v      <= 1'b0;
        end else begin
            // ---- issue ----
            if (frame_tick && !busy) begin
                busy       <= 1'b1;
                tap_idx    <= {TAP_BITS{1'b0}};
                phase_snap <= phase_reg;
                acc_l      <= {ACC_WIDTH{1'b0}};
                acc_r      <= {ACC_WIDTH{1'b0}};
            end else if (busy) begin
                if (tap_idx == TAPS_PER_PHASE - 1)
                    busy <= 1'b0;
                else
                    tap_idx <= tap_idx + 1'b1;
            end

            // ---- s0: selected operands ----
            s0_l    <= dly_l[tap_idx];
            s0_r    <= dly_r[tap_idx];
            s0_c    <= coeff_rom[rom_addr(phase_snap, tap_idx)];
            s0_v    <= busy;
            s0_last <= busy && (tap_idx == TAPS_PER_PHASE - 1);

            // ---- s1: multiplier input registers ----
            s1_l    <= s0_l;
            s1_r    <= s0_r;
            s1_c    <= s0_c;
            s1_v    <= s0_v;
            s1_last <= s0_last;

            // ---- s2: products ----
            s2_l    <= prod_l;
            s2_r    <= prod_r;
            s2_v    <= s1_v;
            s2_last <= s1_last;

            // ---- s3: accumulate (the accumulators are cleared at the start of the next pass, about 312 clocks later) ----

            if (s2_v) begin
                acc_l <= acc_l + s2_l;
                acc_r <= acc_r + s2_r;
            end
            s3_last <= s2_last;

            // ---- s4: round ----
            s4_l <= (acc_l + BIAS) >>> SHIFT;
            s4_r <= (acc_r + BIAS) >>> SHIFT;
            s4_v <= s3_last;

            // ---- s5: saturate ----
            out_valid <= s4_v;
            if (s4_v) begin
                out_l <= sat(s4_l);
                out_r <= sat(s4_r);
            end
        end
    end

endmodule
