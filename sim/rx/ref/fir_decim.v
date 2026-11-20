// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Reference model of the receiver's compensating FIR decimator, as it was before the receiver bank
// was rebalanced. It is the last stage of one receiver (docs/RX_DSP.md has the filter design with
// its passband, stopband, ripple and droop budget), and it exists here so that sim/rx/tb_rb3_compare.v
// can run it side by side with the current rtl/rx/fir_decim.v and show that both deliver the
// same output words in the same order. The module is called fir_decim_ref so that both can be
// compiled into one bench.
//
// What it models: a finite impulse response (FIR) filter is a weighted sum of the last TAPS input
// samples (the coefficients are the weights, see docs/learn/GLOSSARY.md). This one filters I and Q
// alike, compensates the droop that the CIC filters before it leave in the passband, and
// decimates by DECIM, which means it computes one output for every DECIM input samples. The
// coefficients come from tools/gen_fir_coeffs.py, stored in fir_coeffs.hex and loaded with
// $readmemh.
//
// How: one multiplier is time multiplexed over all TAPS coefficients and over both channels, so a
// decimated output takes 2 x TAPS sequential multiply-accumulate steps. At the fastest output
// rate (384 ksps, DECIM = 4) a new input sample arrives about every 50 system clocks (76.8 MHz
// divided by 1,536 ksps) and a new output is needed only every 4 input samples, about every 200
// clocks, so the 130 steps for TAPS = 65 fit with room to spare. The input shift register is
// copied into a frozen snapshot before the sequencer starts, so that the live shift register keeps
// accepting new samples while the slower sequencer works through the snapshot. The current
// version replaces the shift register and the snapshot with a circular buffer in memory.

// TAPS coefficients, decimation by DECIM, input width, coefficient width (Q19) and output width.
module fir_decim_ref #(
  parameter TAPS         = 65,
  parameter DECIM        = 4,
  parameter IN_WIDTH     = 16,
  parameter COEFF_WIDTH  = 20,
  parameter OUT_WIDTH    = 24,
  parameter COEFF_FILE   = "fir_coeffs.hex"
)(
  input                         clock,
  input                         rst,
  input                         in_strobe,
  input  signed [IN_WIDTH-1:0]  in_i,
  input  signed [IN_WIDTH-1:0]  in_q,
  output reg                    out_strobe,
  output reg signed [OUT_WIDTH-1:0] out_i,
  output reg signed [OUT_WIDTH-1:0] out_q
);

// A product is IN_WIDTH + COEFF_WIDTH = 36 bits, the accumulator has 8 more bits of headroom for
// adding up TAPS products (44 bits), and idx counts the 2 x TAPS steps.
localparam integer PROD_WIDTH = IN_WIDTH + COEFF_WIDTH;
localparam integer ACC_WIDTH  = PROD_WIDTH + 8; // headroom for TAPS accumulation
localparam integer IDX_WIDTH  = $clog2(2*TAPS+1);

// ---------------------------------------------------------------------
// Coefficient ROM, shared by both channels, which use the same real filter
// ---------------------------------------------------------------------
reg signed [COEFF_WIDTH-1:0] coeff [0:TAPS-1];
initial $readmemh(COEFF_FILE, coeff);

// ---------------------------------------------------------------------
// Live tapped delay line (shift register), advanced on every in_strobe. dcnt counts input
// samples and raises start_mac on every DECIM-th one.
// ---------------------------------------------------------------------
reg signed [IN_WIDTH-1:0] taps_i [0:TAPS-1];
reg signed [IN_WIDTH-1:0] taps_q [0:TAPS-1];
integer k;

reg [1:0] dcnt;
reg       start_mac;

always @(posedge clock) begin
  if (rst) begin
    dcnt <= 2'd0;
    start_mac <= 1'b0;
    for (k = 0; k < TAPS; k = k + 1) begin
      taps_i[k] <= {IN_WIDTH{1'b0}};
      taps_q[k] <= {IN_WIDTH{1'b0}};
    end
  end else begin
    start_mac <= 1'b0;
    if (in_strobe) begin
      taps_i[0] <= in_i;
      taps_q[0] <= in_q;
      for (k = 1; k < TAPS; k = k + 1) begin
        taps_i[k] <= taps_i[k-1];
        taps_q[k] <= taps_q[k-1];
      end
      if (dcnt == DECIM-1) begin
        dcnt <= 2'd0;
        start_mac <= 1'b1;
      end else begin
        dcnt <= dcnt + 2'd1;
      end
    end
  end
end

// ---------------------------------------------------------------------
// Frozen snapshot for the MAC sequencer, so that it is not disturbed by further shifting
// ---------------------------------------------------------------------
reg signed [IN_WIDTH-1:0] snap_i [0:TAPS-1];
reg signed [IN_WIDTH-1:0] snap_q [0:TAPS-1];

// mac_run is high while the sequencer works, acc is the running sum and acc_i_latched keeps the
// finished I sum while the Q sum is being formed.
reg               mac_run;
reg [IDX_WIDTH-1:0] idx;      // 0..TAPS-1 = I channel, TAPS..2*TAPS-1 = Q channel
reg signed [ACC_WIDTH-1:0] acc;
reg signed [ACC_WIDTH-1:0] acc_i_latched;

// The multiplier input: the snapshot sample and the coefficient of tap tap_idx, from the I snapshot
// during the first TAPS steps and from the Q snapshot during the next TAPS.
wire               is_q_phase = (idx >= TAPS);
wire [IDX_WIDTH-1:0] tap_idx  = is_q_phase ? (idx - TAPS) : idx;
wire signed [IN_WIDTH-1:0] mac_data = is_q_phase ? snap_q[tap_idx] : snap_i[tap_idx];
wire signed [COEFF_WIDTH-1:0] mac_coeff = coeff[tap_idx];
wire signed [PROD_WIDTH-1:0] mac_product = mac_data * mac_coeff;

// Output scaling: the coefficients are fixed point with COEFF_WIDTH - 1 fraction bits (a passband
// of unity gain sums to about 2^(COEFF_WIDTH-1) - 1), so the sum is shifted down by
// COEFF_WIDTH - 1 bits and rounded (half an LSB is added before the shift).
localparam integer SHIFT = COEFF_WIDTH - 1;

// Rounds the accumulator to OUT_WIDTH bits.
function signed [OUT_WIDTH-1:0] round_out;
  input signed [ACC_WIDTH-1:0] acc_in;
  reg signed [ACC_WIDTH-1:0] rounded;
  begin
    rounded = acc_in + (1 <<< (SHIFT-1));
    round_out = rounded[SHIFT +: OUT_WIDTH];
  end
endfunction

// The sequencer: at start_mac it takes the snapshot and clears the accumulator, and then it
// takes one multiply-accumulate step per clock.
always @(posedge clock) begin
  if (rst) begin
    mac_run <= 1'b0;
    idx <= {IDX_WIDTH{1'b0}};
    acc <= {ACC_WIDTH{1'b0}};
    out_strobe <= 1'b0;
  end else begin
    out_strobe <= 1'b0;

    if (start_mac) begin
      for (k = 0; k < TAPS; k = k + 1) begin
        snap_i[k] <= taps_i[k];
        snap_q[k] <= taps_q[k];
      end
      mac_run <= 1'b1;
      idx <= {IDX_WIDTH{1'b0}};
      acc <= {ACC_WIDTH{1'b0}};
    end else if (mac_run) begin
      if (idx == 0) begin
        acc <= mac_product;
      end else if (idx == TAPS) begin
      // First Q step: keep the finished I sum and start a new sum.
        acc_i_latched <= acc;
        acc <= mac_product;
      end else begin
        acc <= acc + mac_product;
      end

      // The last step: the I output is the kept sum and the Q output is the sum including this
      // last product, and out_strobe pulses for one clock.
      if (idx == 2*TAPS-1) begin
        out_i <= round_out(acc_i_latched);
        out_q <= round_out(acc + mac_product);
        out_strobe <= 1'b1;
        mac_run <= 1'b0;
      end else begin
        idx <= idx + 1'b1;
      end
    end
  end
end

endmodule
