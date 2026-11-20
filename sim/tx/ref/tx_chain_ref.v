// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Reference copy of the transmit chain rtl/tx/tx_chain.v as it was before its FIR stage was rebuilt to share
// one multiplier over time. It is the same code, renamed to tx_chain_ref and instantiating
// tx_fir_interp4_ref (the earlier FIR, which does all multiply-adds of a phase in one clock) in place of
// tx_fir_interp4, and its up-mixer is the same NCO mixer (rtl/rx/nco_mixer.v) as the real chain's. It is kept
// only so that sim/tx/tb_tx_chain_rb2_equiv.v can check that the time-multiplexed FIR gives a bit exact
// identical output stream; it is not meant to be used anywhere else, and the real module is rtl/tx/tx_chain.v.
//
// What the chain models (docs/ARCHITECTURE.md section 3.6): the transmit path from a ring of 48 kHz complex
// baseband samples to the 12-bit samples the HL2's DAC takes at 76.8 Msps. A polyphase FIR interpolator
// raises the rate by 4 (48 kHz to 192 kHz), a 5-stage CIC interpolator by 400 (192 kHz to 76.8 Msps), and an
// NCO mixer then moves the signal up to the carrier frequency, after which the real part is rounded and
// saturated to 12 bits (docs/learn/GLOSSARY.md explains interpolation, CIC and NCO).
//
// Scope: only the DSP datapath. The pace strobe (one output sample is produced per pulse, whatever the clock
// rate) and the baseband read port (bb_i, bb_q, bb_valid, bb_req, a plain FIFO-style port) stand for the
// parts around it, the HL2 link's pacing and the DDR3 ring reader, so that either can be connected without
// changing this module. The testbench ties pace high and clocks the module at the 76.8 MHz output rate
// directly, which is equivalent because the module has no notion of time, only of how many samples have gone by.
//
// Safety: out_data is forced to zero at the final register whenever enable is low or trip is high, so it
// reaches zero on the pace edge after either changes (within 1 sample), whatever the pipeline upstream is
// doing. The HL2's own hardware interlock is still the final authority; this is a second line of defense on
// the chip's side of the link.
//
// Mixer clocking: the NCO mixer has its in_strobe tied high, so its oscillator advances on every clock edge
// and the module has to be clocked at the output sample rate. Wiring it into a faster DSP clock needs the
// mixer to advance once per output sample, through its in_strobe or a clock gated on pace.

`timescale 1ns / 1ps

module tx_chain_ref #(
    parameter BB_WIDTH   = 16,   // ring baseband I/Q width (int16, docs/ARCHITECTURE.md 3.6.1)
    parameter FIR_OBITS  = 20,   // tx_fir_interp4 output width
    parameter CIC_R      = 400,
    parameter CIC_OBITS  = 24,   // kept wide so the final stage does not need to boost gain
    parameter CIC_GBITS  = 35,   // ceil(log2(CIC_R**4)), see rtl/tx/CicInterpM5.v header
    parameter DAC_WIDTH  = 12,
    parameter OUTPUT_SHIFT = 15  // base right-shift from the CORDIC output to DAC_WIDTH bits;
                                  // calibrated empirically, see docs/X1_TX.md "gain and headroom"
) (
    input  wire clock,
    input  wire rst,

    // one output sample is produced per `pace` pulse; see module header
    input  wire pace,

    // ring reader port (FIFO-style; see module header)
    input  wire signed [BB_WIDTH-1:0] bb_i,
    input  wire signed [BB_WIDTH-1:0] bb_q,
    input  wire                       bb_valid,
    output wire                       bb_req,

    // register interface (clk_dsp domain; A 4.1 0xE808_0000)
    input  wire                enable,
    input  wire                trip,
    input  wire signed [31:0]  nco_freq,   // same convention as rx_bank: round(f/76.8e6*2^32)
    input  wire [4:0]          gain_shift, // extra attenuation, 0-31, applied after the fixed
                                            // CORDIC-width-to-12-bit shift; see docs/X1_TX.md

    output reg  signed [DAC_WIDTH-1:0] out_data,
    output reg                          out_valid
);

    // Inter-stage wires are declared up front, because the FIR's calc is driven by the CIC's req and the
    // CIC's x_real and x_imag come from the FIR's output, so each instance below uses a wire that the other
    // one drives, and Icarus Verilog wants a module-level wire declared before its first use in a port
    // connection.
    wire fir_req;
    wire signed [FIR_OBITS-1:0] fir_i, fir_q;
    wire signed [CIC_OBITS-1:0] cic_i, cic_q;
    wire cic_req;

    // -- stage 2: CIC interpolate x400 (192 kHz -> 76.8 Msps), 5 stages -----------------
    // CicInterpM5's clock_en marks the output (76.8 Msps) rate, and the CIC only samples x_real and x_imag once
    // every RRRR clock_en pulses (at its own req, the 192 kHz rate); for every clock in between it feeds itself
    // zeros, which is the interpolator's own zero stuffing and nothing the FIR has to do beforehand. The FIR's
    // calc therefore comes from this req and not from pace directly: since 400 is a multiple of the FIR's 4
    // phases, a calc taken from pace would leave the FIR running out of step with the CIC's sampling instant,
    // and the CIC would always pick up the same one of the FIR's 4 phases, which shows up as spurs far above
    // -70 dBc next to the wanted tones.
    //
    // IBITS and OBITS are not overridden here (Icarus cannot bind them, see CicInterpM5.v) and its defaults
    // (400, 20, 24, 35) match FIR_OBITS, CIC_OBITS and CIC_GBITS above. RRRR and GBITS are passed anyway, for
    // documentation and to catch a mismatch if either module's defaults change.
    CicInterpM5 #(
        .RRRR (CIC_R),
        .GBITS(CIC_GBITS)
    ) u_cic (
        .clock   (clock),
        .clock_en(pace),
        .req     (cic_req),
        .x_real  (fir_i),
        .x_imag  (fir_q),
        .y_real  (cic_i),
        .y_imag  (cic_q)
    );

    // -- stage 1: FIR interpolate x4 (48 kHz -> 192 kHz) --------------------------------
    // A new baseband sample is requested from the ring only when the FIR wants one and one is valid.
    assign bb_req = fir_req & bb_valid;

    tx_fir_interp4_ref #(
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

    // -- stage 3: up-mix ------------------------------------------------------------------
    // The NCO mixer in mode 1 multiplies the complex CIC output with the oscillator and gives the real
    // part at CORDIC_WR bits, which is the CIC width plus CORDIC_EXTRA bits of gain headroom plus 2. The
    // names kept the prefix of the CORDIC that this stage once used.
    localparam CORDIC_EXTRA = 5;
    localparam CORDIC_WR    = CIC_OBITS + CORDIC_EXTRA + 2;

    wire signed [CORDIC_WR-1:0] cordic_i;

    nco_mixer #(.MODE(1), .IN_WIDTH(CIC_OBITS), .OUT_WIDTH(CORDIC_WR)) u_cordic (
        .clock     (clock),
        .rst       (rst),
        .in_strobe (1'b1),
        .frequency (nco_freq),
        .in_i      (cic_i),
        .in_q      (cic_q),
        .out_strobe(),
        .out_i     (cordic_i),
        .out_q     ()
    );

    // -- stage 4: real part, round and saturate to DAC_WIDTH bits, safety mux -----------
    // OUTPUT_SHIFT is the base gain (docs/X1_TX.md) and gain_shift adds attenuation at run time on top of it.
    // What is left after the shift is rounded to nearest and then saturated (not wrapped) if it does not fit
    // in DAC_WIDTH bits.
    //
    // total_shift can run past the mixer's output width for a large gain_shift, and beyond that point the
    // result is only the sign bit repeated, so no rounding is needed.
    //
    // arith_shifted and sign_fill are declared signed separately and combined with a plain mux, because putting
    // the >>> straight into a ternary beside an unsigned replication makes Verilog treat the whole ternary as
    // unsigned, which turns the arithmetic (sign-extending) shift into a logical one for negative values
    // without any tool warning.
    wire [5:0] total_shift = OUTPUT_SHIFT[5:0] + {1'b0, gain_shift};
    wire shift_in_range = total_shift < CORDIC_WR[5:0];
    wire signed [CORDIC_WR-1:0] arith_shifted = cordic_i >>> total_shift;
    wire signed [CORDIC_WR-1:0] sign_fill     = {CORDIC_WR{cordic_i[CORDIC_WR-1]}};
    wire signed [CORDIC_WR-1:0] shifted = shift_in_range ? arith_shifted : sign_fill;
    wire round_bit = (shift_in_range && total_shift != 0) ? cordic_i[total_shift[4:0]-1] : 1'b0;
    wire signed [CORDIC_WR-1:0] rounded = shifted + round_bit;

    // overflow if any bit above DAC_WIDTH-1 differs from the sign bit
    wire signed [CORDIC_WR-DAC_WIDTH:0] ovf_bits = rounded[CORDIC_WR-1 -: (CORDIC_WR-DAC_WIDTH+1)];
    wire overflow = ~(&ovf_bits) & (|ovf_bits);
    wire signed [DAC_WIDTH-1:0] clipped = rounded[DAC_WIDTH-1]
        ? {1'b1, {(DAC_WIDTH-1){1'b0}}}
        : {1'b0, {(DAC_WIDTH-1){1'b1}}};

    wire signed [DAC_WIDTH-1:0] sample = overflow ? clipped : rounded[DAC_WIDTH-1:0];

    // Sanity check of the fixed defaults of CicInterpM5: a silent width mismatch would otherwise just be
    // pruned or padded at the connection, so a change of this module's parameters that is not followed in
    // CicInterpM5 prints a warning.
    initial begin
        if (u_cic.IBITS !== FIR_OBITS)
            $display("tx_chain: WARNING CicInterpM5 default IBITS (%0d) != FIR_OBITS (%0d)",
                      u_cic.IBITS, FIR_OBITS);
        if (u_cic.OBITS !== CIC_OBITS)
            $display("tx_chain: WARNING CicInterpM5 default OBITS (%0d) != CIC_OBITS (%0d)",
                      u_cic.OBITS, CIC_OBITS);
    end

    // Output register: out_valid follows pace, and with every pace pulse the sample goes out, or zero while
    // disabled or tripped.
    always @(posedge clock) begin
        if (rst) begin
            out_data  <= {DAC_WIDTH{1'b0}};
            out_valid <= 1'b0;
        end else begin
            out_valid <= pace;
            if (pace)
                out_data <= (enable && !trip) ? sample : {DAC_WIDTH{1'b0}};
        end
    end

endmodule
