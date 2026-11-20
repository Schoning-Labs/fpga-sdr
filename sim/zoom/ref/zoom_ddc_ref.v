// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Reference model of the zoom DDC (digital down-converter), the chain that tunes a zoom center anywhere in
// the ADC's 0 to 38.4 MHz and decimates the result (keeps only a fraction of the samples) to one of seven
// rates for the zoom FFT. It is built from the plain parallel reference stages (the *_ref modules in this
// folder) and from the receiver bank's own blocks, and it is written separately from the chip form,
// rtl/zoom/zoom_ddc.v, whose filters work one add at a time with their state in LUT RAM. The two are meant
// to give the same words, and sim/zoom/zoom_rb1_compare_sim.v and sim/zoom/zoom_rb1_burst_sim.v check that
// word for word through zoom_spectrum_ref.v, which is why this model has to stay free of the chip form's
// tricks. It has only the seven spans (span_shift 0 to 6), without the narrow spans, so it has no
// narrow_shift and narrow_gain ports. docs/ARCHITECTURE.md section 3.4 and docs/F3_ZOOM.md sections 2 and 3
// describe the design; docs/learn/GLOSSARY.md explains the terms.
//
//   ADC 76.8 Msps -> nco_mixer (complex mix to the zoom center: a numerically controlled oscillator, which
//                    is a phase accumulator and a sine table, makes a complex sine of the wanted frequency,
//                    and multiplying the ADC samples by it moves the zoom center to 0 Hz)
//                 -> cic_fixed (9 stages, decimate by 10)            -> 7.68 Msps
//                 -> cic_var_pow2_ref (11 stages, decimate by 2^span_shift)
//                                                                   -> 7.68 Msps down to 120 ksps
//                 -> zoom_fir_half_ref (63 taps, decimate by 2)     -> 3.84 Msps down to 60 ksps
//                 -> zoom_cic_comp_ref (15 taps, takes out the CIC droop, no decimation)
//
// The total decimation is 10 x 2^span_shift x 2 = 20 x 2^span_shift, so the final rate is 3.84 MHz /
// 2^span_shift. Only the central 80 % of that rate is displayed, because the half-band filter protects only
// that part against aliases (by at least 80 dB, docs/F3_ZOOM.md section 3), which gives displayed spans of
// 0.8 x 3.84 MHz = 3.072 MHz down to 48 kHz, seven round numbers a factor of two apart.
//
// Frequency sign: nco_mixer, which the receiver bank shares, puts a tone above the tuned center at the mirror
// bin (docs/F3_ZOOM.md section 5). A spectrum display wants it above, so phase_inc is negated in this module,
// and only here, which leaves the receiver bank alone. With that, a tone above the tuned center lands
// in the bin above it.

module zoom_ddc_ref #(
    parameter ADC_WIDTH = 12
)(
    input                        clock,     // clk_dsp, which also times the ADC strobes (adc_valid)
    input                        rst,
    input      [ADC_WIDTH-1:0]   adc_data,
    input                        adc_valid,

    input  signed [31:0]         phase_inc, // NCO phase increment for the zoom centre (see the sign-convention note above)
    input      [2:0]             span_shift, // 0..6: pre-FIR rate = 7.68 MHz >> span_shift
    input                        enable,

    output                       out_valid,
    output signed [15:0]         out_i,
    output signed [15:0]         out_q
);

// Strobe and reset: the ADC strobe is gated by enable, and the whole chain is held in reset while disabled, so
// that nothing stale (a stuck mixer strobe, an old CIC sum) can survive a disable and enable or a span change.
wire adc_valid_gated = adc_valid & enable;
wire chan_rst = rst | ~enable;

// The sign of the frequency is changed here only (see the header).
wire signed [31:0] cordic_freq = -phase_inc;

// ---------------------------------------------------------------------
// stage 1: CORDIC mixer to the zoom centre
// ---------------------------------------------------------------------
wire               cordic_strobe;
wire signed [17:0] cordic_i, cordic_q;

// The mixer is the receiver bank's nco_mixer, the same one that the chip form uses, so that the word-for-word
// comparison checks what comes after the mixer. The instance keeps the name u_cordic from an older mixer.
nco_mixer #(
  .MODE(0), .IN_WIDTH(ADC_WIDTH), .OUT_WIDTH(18)
) u_cordic (
  .clock      (clock),
  .rst        (chan_rst),
  .in_strobe  (adc_valid_gated),
  .frequency  (cordic_freq),
  .in_i       (adc_data),
  .in_q       ({ADC_WIDTH{1'b0}}),
  .out_strobe (cordic_strobe),
  .out_i      (cordic_i),
  .out_q      (cordic_q)
);

// ---------------------------------------------------------------------
// stage 2: fixed CIC, decimate by 10 -> 7.68 Msps
// ---------------------------------------------------------------------
// Decimation 10 is the value of the receiver channel's own fixed CIC (docs/RX_DSP.md section 2). With the
// variable CIC's range 0 to 6 and the half-band filter's decimation by 2, the total of 20 x 2^shift puts the
// displayed span (80 % of the final rate) exactly on the seven round numbers of the specification
// (docs/F3_ZOOM.md section 3 has the derivation). The order is 9 stages, where the receiver channel has 3: at
// the widest span the variable CIC does not decimate (shift = 0, an identity), so this stage alone stands
// between the display and aliasing there. Order 5 gave 62.6 dB and order 7 gave 87.7 dB against a single
// tone, but 7 was not enough once measured with a real two-sided interferer through the whole chain
// including the droop compensation's gain variation, and order 9 leaves a comfortable margin at the cost of
// adder width only, the same observation that docs/RX_DSP.md section 8 makes for the receiver's fixed CIC.
// The accumulator is 48 bits: 18 bits in plus ceil(9 x log2(10)) = 30 bits of growth.
localparam CIC1_DECIM  = 10;
localparam CIC1_STAGES = 9;
localparam CIC1_ACC_W  = 48; // IN_WIDTH(18) + ceil(9*log2(10))=30

wire cic1_strobe_i, cic1_strobe_q;
wire signed [15:0] cic1_i, cic1_q;

cic_fixed #(
  .STAGES(CIC1_STAGES), .DECIMATION(CIC1_DECIM),
  .IN_WIDTH(18), .ACC_WIDTH(CIC1_ACC_W), .OUT_WIDTH(16)
) u_cic1_i (
  .rst_all(chan_rst), .clock(clock),
  .in_strobe(cordic_strobe), .out_strobe(cic1_strobe_i),
  .in_data(cordic_i), .out_data(cic1_i)
);

cic_fixed #(
  .STAGES(CIC1_STAGES), .DECIMATION(CIC1_DECIM),
  .IN_WIDTH(18), .ACC_WIDTH(CIC1_ACC_W), .OUT_WIDTH(16)
) u_cic1_q (
  .rst_all(chan_rst), .clock(clock),
  .in_strobe(cordic_strobe), .out_strobe(cic1_strobe_q),
  .in_data(cordic_q), .out_data(cic1_q)
);

// Variable power-of-two CIC, decimating by 2^span_shift to twice the final rate (the half-band filter takes
// the last factor of 2). 11 stages: docs/F3_ZOOM.md section 3 measures the alias rejection of every span
// against the whole chain with a real two-sided interferer, and with 11 stages every span stays above
// the 80 dB target with margin, again at the cost of adder width only.
wire cic2_strobe_i, cic2_strobe_q;
wire signed [15:0] cic2_i, cic2_q;

cic_var_pow2_ref #(
  .STAGES(11), .IN_WIDTH(16), .MAX_SHIFT(6), .OUT_WIDTH(16)
) u_cic2_i (
  .rst_all(chan_rst), .shift(span_shift), .clock(clock),
  .in_strobe(cic1_strobe_i), .out_strobe(cic2_strobe_i),
  .in_data(cic1_i), .out_data(cic2_i)
);

cic_var_pow2_ref #(
  .STAGES(11), .IN_WIDTH(16), .MAX_SHIFT(6), .OUT_WIDTH(16)
) u_cic2_q (
  .rst_all(chan_rst), .shift(span_shift), .clock(clock),
  .in_strobe(cic1_strobe_q), .out_strobe(cic2_strobe_q),
  .in_data(cic1_q), .out_data(cic2_q)
);

// Anti-alias half-band FIR, decimating by 2 to the final internal rate (the filter has 20-bit coefficients here).
// Only the central 80 % of this rate is displayed, docs/F3_ZOOM.md section 3.
wire fir_strobe;
wire signed [15:0] fir_i, fir_q;

zoom_fir_half_ref #(
  .TAPS(63), .IN_WIDTH(16), .COEFF_WIDTH(20), .OUT_WIDTH(16)
) u_fir (
  .clock(clock), .rst(chan_rst),
  .in_strobe(cic2_strobe_i), // I and Q strobes are always coincident
  .in_i(cic2_i), .in_q(cic2_q),
  .out_strobe(fir_strobe),
  .out_i(fir_i), .out_q(fir_q)
);

// Droop compensation (docs/F3_ZOOM.md section 3): the CIC stages' own droop would reach 4 to 5.2 dB at the
// edge of the displayed band, and this filter brings the band flat again. One coefficient set per span (see
// zoom_cic_comp_parallel_ref.v), and this model holds only the first 7.
// ---------------------------------------------------------------------
zoom_cic_comp_ref #(
  .TAPS(15), .IN_WIDTH(16), .COEFF_WIDTH(18), .OUT_WIDTH(16), .N_SPANS(7)
) u_comp (
  .clock(clock), .rst(chan_rst),
  .span_shift(span_shift),
  .in_strobe(fir_strobe),
  .in_i(fir_i), .in_q(fir_q),
  .out_strobe(out_valid),
  .out_i(out_i), .out_q(out_q)
);

endmodule
