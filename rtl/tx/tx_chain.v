// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// tx_chain: the transmit signal chain, from 48 kHz baseband samples to 12-bit samples at 76.8 Msps.
//
// What it does
//   Firmware writes the signal to transmit as complex baseband (an I and a Q value of 16 bit each, 48,000 per
//   second, glossary entry "I/Q" in docs/learn/GLOSSARY.md) into a ring in DDR3, the same format for every mode.
//   This module turns that stream into the real-valued samples that the Hermes-Lite 2's DAC plays at 76.8 Msps,
//   centered on the carrier frequency that was asked for.  That takes four steps:
//     1. a polyphase FIR interpolator that raises the rate by 4, 48 kHz to 192 kHz (tx_fir_interp4.v);
//     2. a CIC interpolator that raises it by 400, 192 kHz to 76.8 Msps (CicInterpM5.v, from the HL2 project);
//     3. an NCO mixer that multiplies the complex signal by e^(j 2 pi f t), which moves it up to the carrier
//        frequency f, and keeps the real part (rtl/rx/nco_mixer.v in its transmit mode);
//     4. the result is shifted down to 12 bit, rounded, saturated and gated by the safety inputs.
//   Raising a sample rate in big steps works in two stages because a CIC filter is cheap (no multipliers) but
//   droops in its pass band, which is harmless when the signal is only +-12 kHz wide against an input rate of
//   192 kHz (0.28 dB of droop at 12 kHz), while the FIR with its sharp edge only has to run at the low rates.
//   Both are explained further in the files themselves; the glossary has "Interpolation", "CIC filter", "NCO"
//   and "Mixer".
//
// Where it sits in the radio
//   Fed by:  audio_ring_reader.v on the TX ring (its `smp_l` and `smp_r` are I and Q here), the register block
//            (nco_freq, gain_shift, enable) and the HL2 link's safety byte (trip).
//   Feeds:   the TX sample framer of the HL2 link (rtl/hl2link), which packs the 12-bit samples into the UDP
//            frames that go to the HL2.  `pace` also comes from there, see below.
//
// Rate
//   The chain advances by one output sample per `pace` pulse and holds its state in between, so it has no
//   notion of wall-clock time, only of how many samples have gone by.  In the radio `pace` is one pulse per sample
//   received from the HL2 (average 76.8 M per s on the 120 MHz clk_dsp, so it is high on about 64 % of the
//   clocks and can be bursty), which ties the transmit rate to the HL2's own clock, and the rate lock trims
//   it a sample at a time to keep the HL2's transmit FIFO at its target fill (docs/ARCHITECTURE.md section 3.6).
//
// Safety
//   `out_data` is forced to zero at the final register whenever `enable` is low or `trip` is high.  The zero
//   appears at the next output sample, whatever the pipeline upstream is holding.  The HL2's own interlock
//   remains the final authority (docs/ARCHITECTURE.md section 3.6, point 5), so this is a second layer on our side
//   of the link.
//
// A known limit of the mixer clocking
//   The mixer's `in_strobe` is tied high (through mix_run below), so its NCO phase advances on every edge of
//   `clock`, one step of `nco_freq` per clock.  That equals one step per output sample when `pace` is high on
//   every clock, which is how the testbench runs the chain at the output rate.  At the 120 MHz clk_dsp, where
//   `pace` is not high on every clock, the NCO steps more often than samples are produced, so `nco_freq` is
//   effectively scaled for the clock and not for the sample rate, and the phase seen by each output sample
//   depends on how many clocks came since the previous one.  Advancing the mixer once per output sample (through
//   its `in_strobe`) removes the difference; docs/X1_TX.md notes the same point.

`timescale 1ns / 1ps

module tx_chain #(
    // Parameters:
    //   BB_WIDTH     width of the baseband samples from the ring, 16 bit.
    //   FIR_OBITS    width of the FIR interpolator's output, 20 bit (16 bit plus 4 guard bits).
    //   CIC_R        interpolation ratio of the CIC, 400 (192 kHz x 400 = 76.8 MHz).
    //   CIC_OBITS    width of the CIC's output, 24 bit, wide enough that the mixer needs no extra gain.
    //   CIC_GBITS    bit growth of the CIC, ceil(log2(400^4)) = 35 bit: the gain of an interpolating CIC with 5
    //                stages is CIC_R to the power 5 - 1 (see CicInterpM5.v).
    //   DAC_WIDTH    width of the output samples, 12 bit (the HL2's DAC).
    //   OUTPUT_SHIFT right shift from the mixer's 31-bit output down to DAC_WIDTH bits at the lowest attenuation,
    //                found by measurement (docs/X1_TX.md, "gain and headroom").
    parameter BB_WIDTH   = 16,   // ring baseband I/Q width (int16, docs/ARCHITECTURE.md 3.6.1)
    parameter FIR_OBITS  = 20,   // tx_fir_interp4 output width
    parameter CIC_R      = 400,
    parameter CIC_OBITS  = 24,   // kept wide so the final stage does not need to boost gain
    parameter CIC_GBITS  = 35,   // ceil(log2(CIC_R**4)), see rtl/tx/CicInterpM5.v header
    parameter DAC_WIDTH  = 12,
    parameter OUTPUT_SHIFT = 15  // base right-shift from the mixer output to DAC_WIDTH bits;
                                  // calibrated empirically, see docs/X1_TX.md "gain and headroom"
) (
    // Clock (clk_dsp, 120 MHz) and synchronous reset (active high).
    input  wire clock,
    input  wire rst,

    // One output sample is produced per pulse on `pace` (see the module header).
    input  wire pace,

    // Baseband port from the ring reader: bb_i and bb_q (signed 16 bit) are valid while bb_valid is high, and
    // bb_req is the one-clock request for the next pair, given only when one is available.
    input  wire signed [BB_WIDTH-1:0] bb_i,
    input  wire signed [BB_WIDTH-1:0] bb_q,
    input  wire                       bb_valid,
    output wire                       bb_req,

    // Register interface (clk_dsp domain, register page 0xE808_0000): enable, trip (from the safety byte),
    // nco_freq (carrier frequency, signed 32 bit, round(f / 76.8e6 x 2^32), the same convention as the receivers)
    // and gain_shift (extra attenuation of 0 to 31 bits on top of OUTPUT_SHIFT).
    input  wire                enable,
    input  wire                trip,
    input  wire signed [31:0]  nco_freq,   // same convention as rx_bank: round(f/76.8e6*2^32)
    input  wire [4:0]          gain_shift, // extra attenuation in bits, 0-31, applied after the fixed shift

    // Output: out_data is the 12-bit sample (signed), valid for one clock when out_valid is high.
    output reg  signed [DAC_WIDTH-1:0] out_data,
    output reg                          out_valid
);

    // Wires between the stages are declared up front, because they are used before their driver is written: the
    // FIR's `calc` is driven by the CIC's `req`, and the CIC's x_real and x_imag come from the FIR's output.
    // Some simulators require a wire to be declared before it is used in a port connection.
    wire fir_req;
    wire signed [FIR_OBITS-1:0] fir_i, fir_q;
    wire signed [CIC_OBITS-1:0] cic_i, cic_q;
    wire cic_req;

    // `pace` is registered here in six copies (five for the CIC's register groups, one for the output stage).
    // Used straight from its source it would be the clock enable of the CIC's roughly 1,700 registers and would not
    // meet timing at 120 MHz.  Everything after pace runs one clock later because of this: the CIC, the FIR behind
    // its `req`, and the mixer, whose NCO starts one clock later (mix_run) and sees nco_freq one clock later too,
    // so its phase stays paired with the same samples.  gain_shift is delayed to match.  `enable` and `trip` gate
    // the output register directly, without that delay.
    (* syn_preserve = 1 *) reg [5:0] pace_c = 6'd0;
    reg               mix_run = 1'b0;
    reg signed [31:0] nco_freq_r = 32'sd0;
    reg [4:0]         gain_shift_r = 5'd0;
    always @(posedge clock) begin
        pace_c       <= {!rst && pace, {5{pace}}};   // the output stage's copy as its old s0_pace
        mix_run      <= 1'b1;
        nco_freq_r   <= nco_freq;
        gain_shift_r <= gain_shift;
    end

    // -- stage 2: CIC interpolate x400 (192 kHz -> 76.8 Msps), 5 stages -----------------
    // CicInterpM5's `clock_en` marks the *output* (76.8 Msps) rate.  The CIC only takes a new input
    // sample (x_real and x_imag) once every CIC_R (400) clock_en pulses, which it announces on its `req` (the
    // 192 kHz rate), and for the clocks in between it feeds itself zeros, which is the interpolator's own
    // zero-stuffing, so the FIR does not have to do any of that.  The FIR's `calc` is therefore driven from this
    // `req` and not from `pace`.  Driving it from `pace` would let the FIR run free of the CIC's sampling instant,
    // and because 400 is a multiple of the FIR's 4 phases the CIC would always take the same one of the 4 phases,
    // which shows up as spurs far above -70 dBc.
    //
    // IBITS and OBITS of the CIC are not overridden here, because Icarus Verilog cannot bind them (see
    // CicInterpM5.v).  Its defaults (400, 20, 24, 35) already match FIR_OBITS, CIC_OBITS and CIC_GBITS above.  RRRR
    // and GBITS are passed anyway, for documentation and to catch a mismatch if the defaults ever change.
    CicInterpM5 #(
        .RRRR (CIC_R),
        .GBITS(CIC_GBITS),
        .CE_COPIES(5)
    ) u_cic (
        .clock   (clock),
        .clock_en(pace_c[4:0]),
        .req     (cic_req),
        .x_real  (fir_i),
        .x_imag  (fir_q),
        .y_real  (cic_i),
        .y_imag  (cic_q)
    );

    // -- stage 1: FIR interpolate x4 (48 kHz -> 192 kHz) --------------------------------
    // The FIR is asked for a new input pair (bb_req) whenever it needs one and the ring has one (bb_valid).
    assign bb_req = fir_req & bb_valid;

    tx_fir_interp4 #(
        .IBITS(BB_WIDTH),
        .OBITS(FIR_OBITS)
    ) u_fir (
        .clock  (clock),
        .rst    (rst),
        .calc   (cic_req),
        .req    (fir_req),
        .x_real (bb_i),
        .x_imag (bb_q),
        .y_real (fir_i),
        .y_imag (fir_q)
    );

    // -- stage 3: NCO up-mix (rtl/rx/nco_mixer.v, MODE 1) --------------------------------
    // out = G Re{(cic_i + j cic_q) e^(jt)}, where t is the NCO phase, G = 107922/2048 = 52.696 is the mixer's
    // gain, and the output is 31 bits wide (CIC_OBITS plus 5 bits for the gain plus 2).  The latency is 8 clocks.
    // out_q is not used, the mixer is run in the mode that gives the real part only.
    localparam MIX_W = CIC_OBITS + 7;

    wire signed [MIX_W-1:0] mix_out;

    nco_mixer #(
        .MODE     (1),
        .IN_WIDTH (CIC_OBITS),
        .OUT_WIDTH(MIX_W)
    ) u_nco (
        .clock     (clock),
        .rst       (rst),
        .in_strobe (mix_run),
        .frequency (nco_freq_r),
        .in_i      (cic_i),
        .in_q      (cic_q),
        .out_strobe(),
        .out_i     (mix_out),
        .out_q     ()
    );

    // -- stage 4: real part, round and saturate to DAC_WIDTH bits, safety mux -----------
    // OUTPUT_SHIFT is the base gain (docs/X1_TX.md) and gain_shift adds extra attenuation at run time.  What is
    // left after the shift is rounded to the nearest value and then saturated (not wrapped) if it does not fit
    // in DAC_WIDTH bits.
    //
    // total_shift is guarded against running past the mixer output width (a large gain_shift): beyond that point
    // the result is just the sign bit repeated, and no rounding is needed.
    //
    // arith_shifted and sign_fill are each declared signed on their own and then joined with a plain mux.  Putting
    // the `>>>` straight into a ternary next to an unsigned replication would make Verilog treat the whole ternary
    // as unsigned, and that turns the arithmetic (sign-extending) shift into a logical one for negative values,
    // without any tool warning; the effect is a very visible spur in a two-tone test.
    //
    // Pipeline: the gain decode is a register of its own (a change of gain_shift takes effect one clock later),
    // the shift is done in two clocks, the shifted value and its round bit are registered before the rounding
    // add, and the sum is registered before the saturation.  `pace` goes through the same three registers, so
    // the samples on out_data and out_valid are three clocks later than a version without these registers
    // would give.  `enable` and `trip` are not delayed: they gate the output register directly, so a disable
    // or trip zeroes the output on the next output sample.
    // total_shift is the whole right shift (OUTPUT_SHIFT + gain_shift, at most 46, so 6 bits) and shift_in_range says
    // it is smaller than the mixer width MIX_W (31); both are registered.
    reg [5:0] total_shift;
    reg       shift_in_range;
    always @(posedge clock) begin
        total_shift    <= OUTPUT_SHIFT[5:0] + {1'b0, gain_shift_r};
        shift_in_range <= (OUTPUT_SHIFT[5:0] + {1'b0, gain_shift_r}) < MIX_W[5:0];
    end
    // The shift itself in two clocks: by the multiple of 8 (s0), then by the rest (s1); in range
    // total_shift < MIX_W (31), so total_shift[5] is 0 there. (x >>> 8a) >>> b = x >>> (8a+b).
    // round_bit is the most significant bit that the shift throws away (bit total_shift - 1 of the mixer output),
    // which, added back after the shift, rounds to the nearest value.  It is 0 when nothing is shifted out.
    wire round_bit = (shift_in_range && total_shift != 0) ? mix_out[total_shift[4:0]-1] : 1'b0;

    // Shift stages: s0 holds the mixer output shifted by the multiple of 8 in total_shift, s1 the result shifted by the
    // remaining 0 to 7 bits (or the sign bit repeated when total_shift is out of range).  The _round, _sign and _pace
    // registers carry the round bit, the sign and the output pulse alongside.
    reg signed [MIX_W-1:0] s0_shifted;
    reg                        s0_round, s0_sign, s0_pace;
    // (kept as separate signed wires: see the note above about >>> inside a ternary)
    wire signed [MIX_W-1:0] s0_fine = s0_shifted >>> total_shift[2:0];
    wire signed [MIX_W-1:0] s0_fill = {MIX_W{s0_sign}};
    reg signed [MIX_W-1:0] s1_shifted;
    reg                        s1_round, s1_pace;
    always @(posedge clock) begin
        if (rst) begin
            s0_shifted <= {MIX_W{1'b0}};
            s0_round   <= 1'b0;
            s0_sign    <= 1'b0;
            s0_pace    <= 1'b0;
            s1_shifted <= {MIX_W{1'b0}};
            s1_round   <= 1'b0;
            s1_pace    <= 1'b0;
        end else begin
            s0_shifted <= mix_out >>> {total_shift[4:3], 3'b000};
            s0_round   <= round_bit;
            s0_sign    <= mix_out[MIX_W-1];
            s0_pace    <= pace_c[5];
            s1_shifted <= shift_in_range ? s0_fine : s0_fill;
            s1_round   <= s0_round;
            s1_pace    <= s0_pace;
        end
    end

    // Rounding add: shifted value plus the round bit.
    reg signed [MIX_W-1:0] rounded;
    reg                        s2_pace;
    always @(posedge clock) begin
        if (rst) begin
            rounded <= {MIX_W{1'b0}};
            s2_pace <= 1'b0;
        end else begin
            rounded <= s1_shifted + s1_round;
            s2_pace <= s1_pace;
        end
    end

    // overflow if any bit above DAC_WIDTH-1 differs from the sign bit
    wire signed [MIX_W-DAC_WIDTH:0] ovf_bits = rounded[MIX_W-1 -: (MIX_W-DAC_WIDTH+1)];
    wire overflow = ~(&ovf_bits) & (|ovf_bits);
    // Saturation value: the most negative or the most positive 12-bit number, chosen by the sign of the sum.

    wire signed [DAC_WIDTH-1:0] clipped = rounded[DAC_WIDTH-1]
        ? {1'b1, {(DAC_WIDTH-1){1'b0}}}
        : {1'b0, {(DAC_WIDTH-1){1'b1}}};

    wire signed [DAC_WIDTH-1:0] sample = overflow ? clipped : rounded[DAC_WIDTH-1:0];

    // Sanity check for the fixed defaults in CicInterpM5.v noted above: it catches a silent width mismatch (a
    // simulator would otherwise just prune or pad the connection) if this module's own parameters are changed
    // without updating those defaults.  It is for simulation only: Gowin's parser does not accept a hierarchical
    // reference to another instance's parameter here ("external reference 'u_cic.IBITS' remains unresolved"),
    // even inside an initial block that it would otherwise drop, so the block is bracketed in
    // the standard translate_off/translate_on pragma (SUG550 5.19) every synthesis tool,
    // including Gowin's, is required to honour; Icarus and Verilator still simulate it (they
    // just see two comments).
    // synthesis translate_off
    initial begin
        if (u_cic.IBITS !== FIR_OBITS)
            $display("tx_chain: WARNING CicInterpM5 default IBITS (%0d) != FIR_OBITS (%0d)",
                      u_cic.IBITS, FIR_OBITS);
        if (u_cic.OBITS !== CIC_OBITS)
            $display("tx_chain: WARNING CicInterpM5 default OBITS (%0d) != CIC_OBITS (%0d)",
                      u_cic.OBITS, CIC_OBITS);
    end
    // synthesis translate_on

    // Output register: zero unless enabled and not tripped, otherwise the saturated sample, loaded on every
    // output sample (s2_pace).
    always @(posedge clock) begin
        if (rst) begin
            out_data  <= {DAC_WIDTH{1'b0}};
            out_valid <= 1'b0;
        end else begin
            out_valid <= s2_pace;
            if (s2_pace)
                out_data <= (enable && !trip) ? sample : {DAC_WIDTH{1'b0}};
        end
    end

endmodule
