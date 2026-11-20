// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Reference model of the zoom DDC's variable-decimation CIC filter. A CIC (cascaded integrator-comb) filter
// is a chain of running sums (integrators) at the input rate, then a decimation, which means that only every
// R-th sample is kept, and then a chain of differences (combs) at the lower rate, and it low-passes a stream
// before the sample rate is cut without needing a single multiplier (a Hogenauer CIC keeps every sum in a
// wide wrapping register, so no overflow protection is needed as long as the register can hold the full
// growth of the filter). docs/learn/GLOSSARY.md has the terms.
//
// This is the plain textbook form, with all STAGES integrators and all STAGES combs stepping on every
// sample, built from the receiver bank's cic_integrator and cic_comb modules (rtl/rx/cic_integrator.v and
// rtl/rx/cic_comb.v). It is written separately from the chip's form, rtl/zoom/cic_var_pow2.v, which works out
// the same sums serially in two halves on two clocks, with the state in LUT RAM. A model that shares no
// structure with the chip form is what makes a word-for-word comparison worth anything, and
// sim/zoom/tb_cic_var_pow2.v and sim/zoom/zoom_rb1_compare_sim.v hold the two to the same output words
// (zoom_ddc_ref.v also builds its second CIC stage from this module).
//
// The decimation is 2^shift for shift = 0 to MAX_SHIFT (1, 2, 4, ..., 64 for the zoom's value of 6), set by a
// 3-bit shift amount and not by the ratio itself. In the zoom DDC the fixed CIC in front delivers 7.68 Msps and
// this stage brings that down to 7.68 Msps / 2^span_shift, which the half-band filter then halves again.
// The word grows by log2(R^STAGES) = STAGES x shift bits, an exact integer because R is a power of two, so
// the output is the slice of that many bits above the discarded ones, rounded by adding the highest
// discarded bit, which makes the DC gain the same at every decimation. For shift = 0 (R = 1) each
// integrator and comb pair cancels, the output is the input, and no rounding is done because no bits are
// discarded. The accumulators are IN_WIDTH + STAGES x MAX_SHIFT bits wide.
//
// Ports: rst_all clears every stage, shift picks the decimation (change it only while rst_all is high),
// in_strobe marks an input word in in_data, and out_strobe is a one-clock pulse when out_data holds a new
// decimated, rounded output word (the output register holds its value between pulses).
//
/* verilator lint_off WIDTH */

module cic_var_pow2_ref #(
    parameter STAGES    = 5,
    parameter IN_WIDTH   = 16,
    parameter MAX_SHIFT  = 6,    // decimation up to 2^MAX_SHIFT
    parameter OUT_WIDTH  = 16
)(
    input                          rst_all,
    input      [2:0]                shift,     // decimation = 1 << shift, 0..MAX_SHIFT
    input                          clock,
    input                          in_strobe,
    output reg                     out_strobe,
    input      signed [IN_WIDTH-1:0] in_data,
    output reg signed [OUT_WIDTH-1:0] out_data
);

// Largest bit growth (STAGES x MAX_SHIFT) and the width of the accumulators that must hold it.
localparam integer MAX_GROWTH = STAGES * MAX_SHIFT;
localparam integer ACC_WIDTH  = IN_WIDTH + MAX_GROWTH;

// ---------------------------------------------------------------------------------------------------
// The decimation counter: decimation - 1 = (1 << shift) - 1 is a mask of `shift` ones, so "this is the
// R-th input since the last output" is the same as "all the bits of sample_no below `shift` are 1", which
// needs no subtraction or comparator.
wire [15:0] decim_mask = (16'd1 << shift) - 16'd1;

// Counts input words since the last output, and raises out_strobe for one clock on every R-th one.
reg [15:0] sample_no = 0;

always @(posedge clock)
  if (rst_all) begin
    sample_no <= 0;
    out_strobe <= 0;
  end else if (in_strobe) begin
    if ((sample_no & decim_mask) == decim_mask) begin
      sample_no <= 0;
      out_strobe <= 1;
    end else begin
      sample_no <= sample_no + 16'd1;
      out_strobe <= 0;
    end
  end else
    out_strobe <= 0;

// The chain of integrators (all at the input rate, enabled by in_strobe) and then the chain of combs (all at
// the output rate, enabled by out_strobe), one pair per stage. Index 0 of each array is the input of the chain.
wire signed [ACC_WIDTH-1:0] integrator_data [0:STAGES];
wire signed [ACC_WIDTH-1:0] comb_data [0:STAGES];

assign integrator_data[0] = in_data;
assign comb_data[0] = integrator_data[STAGES];

genvar i;
generate
  for (i = 0; i < STAGES; i = i + 1)
    begin : cic_stages

    cic_integrator #(ACC_WIDTH) cic_integrator_inst(
      .clock(clock),
      .rst(rst_all),
      .strobe(in_strobe),
      .in_data(integrator_data[i]),
      .out_data(integrator_data[i+1])
      );

    cic_comb #(ACC_WIDTH) cic_comb_inst(
      .clock(clock),
      .rst(rst_all),
      .strobe(out_strobe),
      .in_data(comb_data[i]),
      .out_data(comb_data[i+1])
      );
    end
endgenerate

// Output rounding, one case per shift value
// The word has grown by STAGES x shift bits, so the output is the 16-bit slice that ends there, with the highest
// discarded bit added for rounding half up. The slice's top bit is IN_WIDTH + STAGES x shift - 1 and its
// bottom bit is that minus OUT_WIDTH + 1. Shift 0 is the identity case (growth 0 and the same input and
// output width), where no bits are below the slice and so no rounding bit is added.
always @(posedge clock)
  if (rst_all)
    out_data <= {OUT_WIDTH{1'b0}};
  else
    case (shift)
      3'd0: out_data <= comb_data[STAGES][IN_WIDTH-1 -: OUT_WIDTH]; // growth=0, exact
      3'd1: out_data <= comb_data[STAGES][(IN_WIDTH+1*STAGES)-1 -: OUT_WIDTH]
                       + comb_data[STAGES][(IN_WIDTH+1*STAGES)-OUT_WIDTH-1];
      3'd2: out_data <= comb_data[STAGES][(IN_WIDTH+2*STAGES)-1 -: OUT_WIDTH]
                       + comb_data[STAGES][(IN_WIDTH+2*STAGES)-OUT_WIDTH-1];
      3'd3: out_data <= comb_data[STAGES][(IN_WIDTH+3*STAGES)-1 -: OUT_WIDTH]
                       + comb_data[STAGES][(IN_WIDTH+3*STAGES)-OUT_WIDTH-1];
      3'd4: out_data <= comb_data[STAGES][(IN_WIDTH+4*STAGES)-1 -: OUT_WIDTH]
                       + comb_data[STAGES][(IN_WIDTH+4*STAGES)-OUT_WIDTH-1];
      3'd5: out_data <= comb_data[STAGES][(IN_WIDTH+5*STAGES)-1 -: OUT_WIDTH]
                       + comb_data[STAGES][(IN_WIDTH+5*STAGES)-OUT_WIDTH-1];
      default: out_data <= comb_data[STAGES][(IN_WIDTH+6*STAGES)-1 -: OUT_WIDTH] // shift=6
                       + comb_data[STAGES][(IN_WIDTH+6*STAGES)-OUT_WIDTH-1];
    endcase

endmodule

/* verilator lint_on WIDTH */
