// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Reference model of the zoom DDC's droop compensation filter, the last stage of the chain. The CIC filters
// that decimate the stream have a pass band that is not flat, because the gain of a CIC falls towards the
// edge of its band (that fall is called droop), and over the displayed 80 % of the zoom spectrum it adds up
// to several dB. This stage is a short FIR (finite impulse response filter, a sliding weighted sum of the
// last TAPS samples) that does not decimate and whose gain rises towards the band edge by the amount that the
// CIC stages lose, so that the displayed part comes out flat. docs/learn/GLOSSARY.md has the terms and
// docs/F3_ZOOM.md section 4 the design and the measured flatness.
//
// The coefficients are read from rtl/zoom/zoom_cic_comp_coeffs.hex, which tools/gen_zoom_cic_comp_coeffs.py
// writes, as N_SPANS sets of TAPS signed values, set 0 for span_shift = 0 and so on. One set per span is
// needed because the droop has a different shape at the widest span, where the variable CIC does not
// decimate at all and the droop is that of the fixed CIC, from all the others, where the variable CIC dominates and the shape
// hardly changes with the span, and no single set flattens both. The model uses the first N_SPANS = 7 sets
// (span_shift = 0 to 6); the hex file also holds the sets for the narrow spans, which only the chip form
// rtl/zoom/zoom_cic_comp.v uses. The multiplier count does not depend on the number of sets, only the ROM does.
//
// This is the parallel form: all TAPS products are formed at once by TAPS multipliers per channel (a
// separate instance of rtl/fft/fft_mul.v for each, so that a yosys resource estimate counts them as
// multipliers) and added in one registered step, with the same clock-by-clock structure as the
// half-band reference zoom_fir_half_parallel_ref.v. It shares nothing with the chip form, which works one tap
// per clock on a single multiplier per channel, and sim/zoom/zoom_rb1_compare_sim.v holds the two to the
// same output words, one by one. The accumulator is also visible to testbenches (acc_i and acc_q, the
// sums before rounding), which sim/zoom/zoom_alias_sim.v probes to measure aliasing at full precision.
//
// Output k is the filter over the inputs that came before input k, so there is one sample of delay, and the
// first output after a reset is 0. Every strobe that comes in produces one output a few clocks later.

module zoom_cic_comp_ref #(
    parameter TAPS         = 15,
    parameter IN_WIDTH     = 16,
    parameter COEFF_WIDTH  = 18,
    parameter OUT_WIDTH    = 16,
    parameter N_SPANS      = 7,
    parameter COEFF_FILE   = "rtl/zoom/zoom_cic_comp_coeffs.hex"
)(
    input                         clock,
    input                         rst,
    input      [2:0]              span_shift, // 0..N_SPANS-1: selects the active coefficient set
    input                         in_strobe,
    input      signed [IN_WIDTH-1:0] in_i,
    input      signed [IN_WIDTH-1:0] in_q,
    output reg                    out_strobe,
    output reg signed [OUT_WIDTH-1:0] out_i,
    output reg signed [OUT_WIDTH-1:0] out_q
);

// Width of a product (input width plus coefficient width), and of the accumulator, which gets 8 more bits
// of headroom for the sum of TAPS products (15 products need 4).
localparam integer PROD_WIDTH = IN_WIDTH + COEFF_WIDTH;
localparam integer ACC_WIDTH  = PROD_WIDTH + 8; // headroom for TAPS-way accumulation
localparam integer SHIFT      = COEFF_WIDTH - 2; // coefficients are Q(COEFF_WIDTH-2): magnitude up to ~2.0

// ---------------------------------------------------------------------
// coefficient ROM: N_SPANS blocks of TAPS entries, span_shift*TAPS + k
// ---------------------------------------------------------------------
reg signed [COEFF_WIDTH-1:0] coeff [0:(N_SPANS*TAPS)-1];
initial $readmemh(COEFF_FILE, coeff);

// The coefficients of the span that is active are copied into one register per tap whenever span_shift
// changes (and at reset, from set 0). The alternative of adding span_shift x TAPS to the address of
// every tap read, on every clock, would make the indexing below more complicated, and the set changes
// only when the span is changed, which is rare next to the sample rate.
reg signed [COEFF_WIDTH-1:0] active_coeff [0:TAPS-1];
reg [2:0] span_shift_d;
integer   c;
always @(posedge clock) begin
  if (rst) begin
    span_shift_d <= 3'd0;
    for (c = 0; c < TAPS; c = c + 1)
      active_coeff[c] <= coeff[c];
  end else if (span_shift != span_shift_d) begin
    span_shift_d <= span_shift;
    for (c = 0; c < TAPS; c = c + 1)
      active_coeff[c] <= coeff[span_shift * TAPS + c];
  end
end

// ---------------------------------------------------------------------
// tapped delay line
// ---------------------------------------------------------------------
reg signed [IN_WIDTH-1:0] taps_i [0:TAPS-1];
reg signed [IN_WIDTH-1:0] taps_q [0:TAPS-1];
integer k;

// ---------------------------------------------------------------------
// stage 0: TAPS products at once, registered, on the taps as they were before this strobe's shift
// ---------------------------------------------------------------------
wire signed [PROD_WIDTH-1:0] prod_i [0:TAPS-1];
wire signed [PROD_WIDTH-1:0] prod_q [0:TAPS-1];
reg                          prod_valid;

// The products come from TAPS instances of rtl/fft/fft_mul.v (a plain registered signed multiply) and not
// from an inline `*`, so that a resource estimate counts them as DSP multipliers and does not let yosys
// build them out of LUTs. fft_mul registers a * b on every clock, and prod_valid marks the product that
// follows a strobe.
genvar gk;
generate
  for (gk = 0; gk < TAPS; gk = gk + 1) begin : mul_gen
    fft_mul #(.AW(IN_WIDTH), .BW(COEFF_WIDTH)) u_mul_i (
      .clk(clock), .a(taps_i[gk]), .b(active_coeff[gk]), .p(prod_i[gk])
    );
    fft_mul #(.AW(IN_WIDTH), .BW(COEFF_WIDTH)) u_mul_q (
      .clk(clock), .a(taps_q[gk]), .b(active_coeff[gk]), .p(prod_q[gk])
    );
  end
endgenerate

// The tap delay line shifts in a new sample on each strobe. The multipliers see the old values in the same
// clock (non-blocking assignments), so each product uses the taps from before the strobe, which is
// the one sample of delay.
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
// stage 1: accumulate all TAPS products, round, output (no decimation)
// ---------------------------------------------------------------------
reg signed [ACC_WIDTH-1:0] sum_i, sum_q;
integer                    m;

// Rounds the accumulator to OUT_WIDTH bits: adds half of the last discarded step, then drops
// SHIFT bits (the coefficients are Q(COEFF_WIDTH-2), so the sum has that many fractional bits).
function signed [OUT_WIDTH-1:0] round_out;
  input signed [ACC_WIDTH-1:0] acc_in;
  reg signed [ACC_WIDTH-1:0] rounded;
  begin
    rounded = acc_in + (1 <<< (SHIFT-1));
    round_out = rounded[SHIFT +: OUT_WIDTH];
  end
endfunction

// acc_i and acc_q hold the wide sum before rounding, registered with a non-blocking assignment, which
// makes them safe to probe from a testbench in the same way as in rtl/rx/fir_decim.v (a blocking
// scratch variable would be seen at a different time depending on the simulator's order of events).
reg signed [ACC_WIDTH-1:0] acc_i, acc_q;
reg                        acc_valid;

// Sum of the TAPS products, one registered word per channel, one clock after prod_valid.
always @(posedge clock) begin
  if (rst) begin
    acc_valid <= 1'b0;
  end else begin
    acc_valid <= prod_valid;
    if (prod_valid) begin
      sum_i = {ACC_WIDTH{1'b0}};
      sum_q = {ACC_WIDTH{1'b0}};
      for (m = 0; m < TAPS; m = m + 1) begin
        sum_i = sum_i + prod_i[m];
        sum_q = sum_q + prod_q[m];
      end
      acc_i <= sum_i;
      acc_q <= sum_q;
    end
  end
end

// Rounded output, one more clock later.
always @(posedge clock) begin
  if (rst) begin
    out_strobe <= 1'b0;
  end else begin
    out_strobe <= acc_valid;
    if (acc_valid) begin
      out_i <= round_out(acc_i);
      out_q <= round_out(acc_q);
    end
  end
end

endmodule
