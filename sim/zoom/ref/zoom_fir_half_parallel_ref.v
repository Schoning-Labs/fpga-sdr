// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Reference model of the zoom DDC's anti-alias filter (docs/F3_ZOOM.md section 3). It is a 63-tap FIR
// (finite impulse response filter, a sliding weighted sum of the last 63 samples) that low-passes the
// complex stream and then keeps every second output, which is a decimation by 2. It sits behind the two CIC
// stages of the zoom DDC and is what gives the displayed part of the zoom spectrum (the central 80 % of the
// FFT's bins, the outer ones are computed but not shown) at least 80 dB of alias rejection, where the
// CIC stages alone give about 24 dB. docs/learn/GLOSSARY.md has the terms.
//
// The coefficients are in rtl/zoom/zoom_fir_half_coeffs.hex, made by tools/gen_zoom_fir_coeffs.py with a
// Remez design (an equiripple design) with the pass band up to 0.2 and the stop band from 0.3 cycles per
// sample at this module's own input rate. The ideal stop band attenuation is 108.1 dB, and 98.8 dB after
// the coefficients are rounded to 20 bits, which leaves a comfortable margin over the 80 dB target
// (the CIC stages in front add rejection of their own at every span, docs/F3_ZOOM.md section 3).
//
// This is the parallel form, and it is written separately from the chip form rtl/zoom/zoom_fir_half.v on
// purpose, so that the two can be compared word for word (sim/zoom/tb_zoom_fir_half.v does it for the
// filter alone, and sim/zoom/zoom_rb1_compare_sim.v for the whole chain). Every unique tap's product is
// formed in every sample: the coefficients are symmetric, so the two samples that share a coefficient are
// added first and multiplied once, which makes 32 multiplications per channel and 64 in all, where a full
// 63-tap filter would need 126. A serial sequencer, as in rtl/rx/fir_decim.v, does not fit this stage, because
// at the widest span its input arrives only every 10 clocks and the decimation by 2 leaves 20 clocks
// for each output, which is too few for a serial 63-tap sum with a single multiplier (the chip form gets there
// with two multipliers per channel and a schedule of four taps per clock).
//
// Pipeline: a register stage for the products (the multipliers of rtl/fft/fft_mul.v are registered), then a
// register stage that adds all the products of a word at once. The wide add is not split into a tree, because
// this is a model for comparison and not a design that has to close timing. The ports follow
// rtl/rx/fir_decim.v (in_strobe and out_strobe, complex in_i and in_q to out_i and out_q), so that the
// module drops into zoom_ddc_ref.v in the same way.

module zoom_fir_half_ref #(
    parameter TAPS         = 63,
    parameter IN_WIDTH     = 16,
    parameter COEFF_WIDTH  = 18,
    parameter OUT_WIDTH    = 16,
    parameter COEFF_FILE   = "rtl/zoom/zoom_fir_half_coeffs.hex"
)(
    input                         clock,
    input                         rst,
    input                         in_strobe,
    input      signed [IN_WIDTH-1:0] in_i,
    input      signed [IN_WIDTH-1:0] in_q,
    output reg                    out_strobe,
    output reg signed [OUT_WIDTH-1:0] out_i,
    output reg signed [OUT_WIDTH-1:0] out_q
);

// TAPS is odd and the filter is linear-phase Type I (coeff[k] == coeff[TAPS-1-k], as the Remez design in
// tools/gen_zoom_fir_coeffs.py gives), so there are UNIQUE_TAPS = (TAPS + 1) / 2 = 32 distinct
// coefficients. The two delay line taps that share a coefficient are added first and multiplied once, which
// halves the multiplier count (126 products become 64 in all).
localparam integer UNIQUE_TAPS = (TAPS + 1) / 2;
localparam integer PAIR_WIDTH  = IN_WIDTH + 1; // one extra bit for the pair sum
localparam integer PROD_WIDTH  = PAIR_WIDTH + COEFF_WIDTH;
localparam integer ACC_WIDTH   = PROD_WIDTH + 8; // headroom for UNIQUE_TAPS-way accumulation
localparam integer SHIFT       = COEFF_WIDTH - 1; // coefficients are Q(COEFF_WIDTH-1)

// ---------------------------------------------------------------------
// coefficient ROM (shared by both channels, both are the same real filter)
// ---------------------------------------------------------------------
reg signed [COEFF_WIDTH-1:0] coeff [0:TAPS-1];
initial $readmemh(COEFF_FILE, coeff);

// ---------------------------------------------------------------------
// tapped delay line
// ---------------------------------------------------------------------
reg signed [IN_WIDTH-1:0] taps_i [0:TAPS-1];
reg signed [IN_WIDTH-1:0] taps_q [0:TAPS-1];
integer k;

// ---------------------------------------------------------------------
// stage 0: the symmetric pair sums, and then UNIQUE_TAPS products, registered. The pair sums and products
// are formed from the values that the taps had before this clock's shift, because a non-blocking assignment
// gives the right-hand side the old value, so every strobe both forms the products from the window as it
// was and shifts in the new sample, in the same clock, with no snapshot step.
// ---------------------------------------------------------------------
wire signed [PAIR_WIDTH-1:0] pair_i [0:UNIQUE_TAPS-1];
wire signed [PAIR_WIDTH-1:0] pair_q [0:UNIQUE_TAPS-1];
genvar gp;
generate
  for (gp = 0; gp < UNIQUE_TAPS; gp = gp + 1) begin : pair_gen
    if (gp == UNIQUE_TAPS-1) begin : mid_tap
      // TAPS odd: the middle tap (index UNIQUE_TAPS-1) has no partner.
      assign pair_i[gp] = {taps_i[gp][IN_WIDTH-1], taps_i[gp]};
      assign pair_q[gp] = {taps_q[gp][IN_WIDTH-1], taps_q[gp]};
    end else begin : sym_pair
      assign pair_i[gp] = taps_i[gp] + taps_i[TAPS-1-gp];
      assign pair_q[gp] = taps_q[gp] + taps_q[TAPS-1-gp];
    end
  end
endgenerate

wire signed [PROD_WIDTH-1:0] prod_i [0:UNIQUE_TAPS-1];
wire signed [PROD_WIDTH-1:0] prod_q [0:UNIQUE_TAPS-1];
reg                          prod_valid;

// The products come from UNIQUE_TAPS instances of rtl/fft/fft_mul.v (a plain registered signed multiply, the
// same one that the FFT's twiddle multipliers use) and not from an inline multiplication operator, so that a
// resource estimate counts them as DSP multipliers. Left to itself yosys builds a bare 16 x 20 multiplier out
// of LUT fabric, which bloated this block to about 66 % of the device's LUTs before the
// symmetry-folding pass, which is not what real Gowin synthesis would
// do with it either. fft_mul registers a * b on every clock, which does no harm here because pair_i and
// pair_q only change on a strobe, so a product formed between strobes is the same value again, and
// prod_valid is what marks a product that is fresh.
genvar gk;
generate
  for (gk = 0; gk < UNIQUE_TAPS; gk = gk + 1) begin : mul_gen
    fft_mul #(.AW(PAIR_WIDTH), .BW(COEFF_WIDTH)) u_mul_i (
      .clk(clock), .a(pair_i[gk]), .b(coeff[gk]), .p(prod_i[gk])
    );
    fft_mul #(.AW(PAIR_WIDTH), .BW(COEFF_WIDTH)) u_mul_q (
      .clk(clock), .a(pair_q[gk]), .b(coeff[gk]), .p(prod_q[gk])
    );
  end
endgenerate

always @(posedge clock) begin
  if (rst) begin
    prod_valid <= 1'b0;
    for (k = 0; k < TAPS; k = k + 1) begin
      taps_i[k] <= {IN_WIDTH{1'b0}};
      taps_q[k] <= {IN_WIDTH{1'b0}};
    end
  end else begin
    prod_valid <= in_strobe;
    if (in_strobe) begin
      taps_i[0] <= in_i;
      taps_q[0] <= in_q;
      for (k = 1; k < TAPS; k = k + 1) begin
        taps_i[k] <= taps_i[k-1];
        taps_q[k] <= taps_q[k-1];
      end
    end
  end
end

// ---------------------------------------------------------------------
// stage 1: accumulate all UNIQUE_TAPS products (each already the sum of a
// symmetric tap pair, times their shared coefficient) into one word per
// channel
// ---------------------------------------------------------------------
reg signed [ACC_WIDTH-1:0] acc_i, acc_q;
reg                        acc_valid;
reg signed [ACC_WIDTH-1:0] sum_i, sum_q; // procedural accumulation temporaries
integer                    m;

always @(posedge clock) begin
  if (rst) begin
    acc_valid <= 1'b0;
  end else begin
    acc_valid <= prod_valid;
    if (prod_valid) begin
      sum_i = {ACC_WIDTH{1'b0}};
      sum_q = {ACC_WIDTH{1'b0}};
      for (m = 0; m < UNIQUE_TAPS; m = m + 1) begin
        sum_i = sum_i + prod_i[m];
        sum_q = sum_q + prod_q[m];
      end
      acc_i <= sum_i;
      acc_q <= sum_q;
    end
  end
end

// ---------------------------------------------------------------------
// Decimation by 2: `phase` toggles on every strobe and is delayed by two plain registers (that
// advance on every clock) to stay in step with prod_valid and acc_valid, which are plain two-clock delays of in_strobe, so
// they never drift apart. An output is kept when phase was 1 before the input, which fixes which of two
// possible phases of the decimation this model has. The chip form follows it for inputs at least 3 clocks apart.
// ---------------------------------------------------------------------
reg phase, phase_d1, phase_d2;

always @(posedge clock) begin
  if (rst) begin
    phase <= 1'b0; phase_d1 <= 1'b0; phase_d2 <= 1'b0;
  end else begin
    if (in_strobe) phase <= ~phase;
    phase_d1 <= phase;
    phase_d2 <= phase_d1;
  end
end

// Rounds the accumulator to OUT_WIDTH bits: adds half a step and drops SHIFT bits (the coefficients are
// Q(COEFF_WIDTH-1), so the sum has that many fractional bits).
function signed [OUT_WIDTH-1:0] round_out;
  input signed [ACC_WIDTH-1:0] acc_in;
  reg signed [ACC_WIDTH-1:0] rounded;
  begin
    rounded = acc_in + (1 <<< (SHIFT-1));
    round_out = rounded[SHIFT +: OUT_WIDTH];
  end
endfunction

always @(posedge clock) begin
  if (rst) begin
    out_strobe <= 1'b0;
  end else begin
    out_strobe <= acc_valid && phase_d2;
    if (acc_valid && phase_d2) begin
      out_i <= round_out(acc_i);
      out_q <= round_out(acc_q);
    end
  end
end

endmodule
