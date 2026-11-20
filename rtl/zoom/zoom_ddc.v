// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// zoom_ddc: the digital down-converter of the zoom spectrum. A down-converter moves a chosen
// frequency band down to zero and lowers the sample rate to match the band's width. This one
// tunes a zoom center anywhere in the ADC's 0 to 38.4 MHz and decimates to one of eleven rates,
// so that the zoom FFT behind it can show anything from 3.072 MHz down to 3 kHz of spectrum around
// that center (docs/ARCHITECTURE.md 3.4, docs/F3_ZOOM.md sections 2 and 3, docs/ZOOM_IN_CHIP.md).
// It is built from the same blocks as a receiver (the NCO mixer and a fixed CIC) but with its
// own decimation plan, which is a power of two so that the span always doubles or halves. The
// terms are explained in docs/learn/GLOSSARY.md.
//
//   ADC 76.8 Msps -> nco_mixer (rtl/rx/nco_mixer.v, complex mix to the zoom center)
//                 -> rx_cic_fixed (rtl/rx/rx_channel.v; 9 stages, decimate by 10)     -> 7.68 Msps
//                 -> cic_var_pow2 (11 stages, decimate by 2^span_shift)               -> 7.68 Msps to 120 ksps
//                 -> zoom_cic_narrow (11 stages, decimate by 2^narrow_shift; only with span_shift = 6,
//                    docs/ZOOM_IN_CHIP.md section 12)                                 -> 60 to 7.5 ksps
//                 -> zoom_fir_half (63 taps, decimate by 2)                           -> 3.84 Msps to 3.75 ksps
//                 -> zoom_cic_comp (15 taps, takes out the CIC droop)
//
// Where the numbers come from: the total decimation is 10 x 2^span_shift x 2 (x 2^narrow_shift), and
// only the central 80 percent of the final rate is displayed, because the half-band filter
// (zoom_fir_half) protects only that part against aliases, by 80 dB (docs/F3_ZOOM.md section 3). So
// the displayed span is 0.8 times the final rate: 3.072 MHz at the widest setting (3.84 Msps final),
// halving at each step down to 48 kHz (span_shift 6), and then down to 3 kHz with the narrow
// stage. The CIC orders (9 for the fixed stage and 11 for the variable one, against 3 and 5 in a
// receiver) are high because at the widest span the variable CIC does not decimate at all, so the
// fixed CIC alone stands between the display and its aliases there; CIC stages use no multipliers,
// so the high order is cheap.
//
// Frequency sign: the mixer puts a tone above the tuned center at the mirror bin (the receiver bank's
// convention, docs/F3_ZOOM.md section 5). A spectrum display wants it above, so phase_inc is negated
// here, and only here.
//
// Structure for the chip (docs/ZOOM_IN_CHIP.md section 4): the fixed CIC is the receiver bank's
// fan-out-limited rx_cic_fixed (same values as rtl/rx/cic_fixed.v, 2 clocks later); the channel reset is
// seven kept registers, one per consumer, one clock behind rst | ~enable, and the ADC word and its strobe
// go through one register so gating and reset change in the same clock; the negated phase increment is
// registered. The whole chain is held in reset while the zoom is disabled, so nothing stale survives a
// disable or a span change.

`ifndef ZOOM_CIC_NARROW_V
`define ZOOM_CIC_NARROW_V
`include "rtl/zoom/zoom_cic_narrow.v"
`endif

module zoom_ddc #(
    parameter ADC_WIDTH = 12
)(
    input                        clock,     // clk_dsp
    input                        rst,       // synchronous reset
    input      [ADC_WIDTH-1:0]   adc_data,  // raw ADC sample, two's complement
    input                        adc_valid, // one-clock pulse per ADC sample

    input  signed [31:0]         phase_inc, // NCO phase increment of the zoom center
    input      [2:0]             span_shift, // 0..6: rate in front of the half-band filter = 7.68 Msps >> span_shift
    input      [2:0]             narrow_shift, // 1..4 with span_shift = 6: that rate once more >> narrow_shift (else 0)
    input      [1:0]             narrow_gain,  // gain 4^narrow_gain of the narrow spans' stage, saturating
    input                        enable,    // 0 holds the whole chain in reset

    output                       out_valid, // one-clock pulse per output sample
    output signed [15:0]         out_i,     // I, droop-corrected
    output signed [15:0]         out_q      // Q
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;

// The settings are registered here, and the whole chain is held in reset while disabled.
// nar_q is the narrow shift in use (0 unless span_shift is 6), and spanx_q the span index 0..10 that
// selects the droop filter's coefficient set (span_shift plus the narrow shift in use).
// crst_q bits: [0] mixer, [1] fixed CIC I, [2] fixed CIC Q, [3] variable CIC I, [4] variable CIC Q, [5] the two filters,
// [6] the narrow spans' CIC
reg [6:0]            crst_q /* synthesis syn_preserve = 1 */;
reg                  v_q;
reg [ADC_WIDTH-1:0]  adc_q;
reg signed [31:0]    mix_freq;
reg [2:0]            span_q;
reg [2:0]            nar_q;                 // narrow_shift in use: 0 unless span_shift = 6; at most 4
reg [1:0]            ngain_q;
reg [3:0]            spanx_q;               // span index 0..10 = span_shift + narrow shift in use
initial begin crst_q = 7'h7F; v_q = 1'b0; adc_q = {ADC_WIDTH{1'b0}}; mix_freq = 32'sd0; span_q = 3'd0;
              nar_q = 3'd0; ngain_q = 2'd0; spanx_q = 4'd0; end
always @(posedge clock) begin
  nar_q    <= (span_shift != 3'd6) ? 3'd0 : (narrow_shift > 3'd4) ? 3'd4 : narrow_shift;
  ngain_q  <= narrow_gain;
  spanx_q  <= {1'b0, span_q} + {1'b0, nar_q};
  crst_q   <= {7{rst | ~enable}};
  v_q      <= adc_valid & enable;
  adc_q    <= adc_data;
  mix_freq <= -phase_inc;
  span_q   <= span_shift;
end

// ---------------------------------------------------------------------
// stage 1: NCO mixer to the zoom center
// ---------------------------------------------------------------------
wire               mix_strobe;
wire signed [17:0] mix_i, mix_q;

nco_mixer #(
  .MODE(0), .IN_WIDTH(ADC_WIDTH), .OUT_WIDTH(18)
) u_nco (
  .clock      (clock),
  .rst        (crst_q[0]),
  .in_strobe  (v_q),
  .frequency  (mix_freq),
  .in_i       (adc_q),
  .in_q       ({ADC_WIDTH{1'b0}}),
  .out_strobe (mix_strobe),
  .out_i      (mix_i),
  .out_q      (mix_q)
);

// ---------------------------------------------------------------------
// stage 2: fixed CIC, decimate by 10 -> 7.68 Msps. 9 stages (the receiver's has 3): at the widest span
// the variable CIC does not decimate, so this stage alone stands between the display and its alias.
// ---------------------------------------------------------------------
localparam CIC1_DECIM  = 10;
localparam CIC1_STAGES = 9;
localparam CIC1_ACC_W  = 48; // IN_WIDTH(18) + ceil(9*log2(10)) = 30

wire cic1_strobe_i, cic1_strobe_q;
wire signed [15:0] cic1_i, cic1_q;

rx_cic_fixed #(
  .STAGES(CIC1_STAGES), .DECIM(CIC1_DECIM),
  .IN_WIDTH(18), .ACC_WIDTH(CIC1_ACC_W), .OUT_WIDTH(16)
) u_cic1_i (
  .rst(crst_q[1]), .clock(clock),
  .in_strobe(mix_strobe), .out_strobe(cic1_strobe_i),
  .in_data(mix_i), .out_data(cic1_i)
);

rx_cic_fixed #(
  .STAGES(CIC1_STAGES), .DECIM(CIC1_DECIM),
  .IN_WIDTH(18), .ACC_WIDTH(CIC1_ACC_W), .OUT_WIDTH(16)
) u_cic1_q (
  .rst(crst_q[2]), .clock(clock),
  .in_strobe(mix_strobe), .out_strobe(cic1_strobe_q),
  .in_data(mix_q), .out_data(cic1_q)
);

// ---------------------------------------------------------------------
// stage 3: variable CIC, decimate by 2^span_shift
// ---------------------------------------------------------------------
wire cic2_strobe_i, cic2_strobe_q;
wire signed [15:0] cic2_i, cic2_q;

cic_var_pow2 #(
  .STAGES(11), .IN_WIDTH(16), .MAX_SHIFT(6), .OUT_WIDTH(16)
) u_cic2_i (
  .rst_all(crst_q[3]), .shift(span_q), .clock(clock),
  .in_strobe(cic1_strobe_i), .out_strobe(cic2_strobe_i),
  .in_data(cic1_i), .out_data(cic2_i)
);

cic_var_pow2 #(
  .STAGES(11), .IN_WIDTH(16), .MAX_SHIFT(6), .OUT_WIDTH(16)
) u_cic2_q (
  .rst_all(crst_q[4]), .shift(span_q), .clock(clock),
  .in_strobe(cic1_strobe_q), .out_strobe(cic2_strobe_q),
  .in_data(cic1_q), .out_data(cic2_q)
);

// ---------------------------------------------------------------------
// stage 3b: the narrow spans' CIC, decimate by 2^nar_q (0: passes the samples through, one clock later)
// ---------------------------------------------------------------------
wire cic3_strobe;
wire signed [15:0] cic3_i, cic3_q;

zoom_cic_narrow #(
  .STAGES(11), .WIDTH(16), .MAX_SHIFT(4)
) u_cic3 (
  .clock(clock), .rst(crst_q[6]), .shift(nar_q), .gain(ngain_q),
  .in_strobe(cic2_strobe_i), // I and Q strobes are always coincident
  .in_i(cic2_i), .in_q(cic2_q),
  .out_strobe(cic3_strobe), .out_i(cic3_i), .out_q(cic3_q)
);

// ---------------------------------------------------------------------
// stage 4: anti-alias FIR, decimate by 2
// ---------------------------------------------------------------------
wire fir_strobe;
wire signed [15:0] fir_i, fir_q;

zoom_fir_half #(
  .TAPS(63), .IN_WIDTH(16), .COEFF_WIDTH(20), .OUT_WIDTH(16)
) u_fir (
  .clock(clock), .rst(crst_q[5]),
  .in_strobe(cic3_strobe),
  .in_i(cic3_i), .in_q(cic3_q),
  .out_strobe(fir_strobe),
  .out_i(fir_i), .out_q(fir_q)
);

// ---------------------------------------------------------------------
// stage 5: CIC-droop compensation, one coefficient set per span
// ---------------------------------------------------------------------
zoom_cic_comp #(
  .TAPS(15), .IN_WIDTH(16), .COEFF_WIDTH(18), .OUT_WIDTH(16), .N_SPANS(11)
) u_comp (
  .clock(clock), .rst(crst_q[5]),
  .span_shift(spanx_q),
  .in_strobe(fir_strobe),
  .in_i(fir_i), .in_q(fir_q),
  .out_strobe(out_valid),
  .out_i(out_i), .out_q(out_q)
);

endmodule
