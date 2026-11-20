// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ft8_mac: one DSP block as a registered multiply-accumulate, for the FT8 candidate engine.
//
// What it does
//   Computes p = acc ? (p + a x b) : (PRELOAD + a x b), one product per clock.  A multiply-accumulate (a MAC, glossary
//   "DSP block") is the core operation of a filter or a correlation: multiply a sample by a coefficient and add it to a running
//   sum.  With acc = 0 and PRELOAD = 0 the block is a plain registered multiplier.  The result is available 3 clocks after the
//   operands: an input register, a product register, and an output register with the addition inside the DSP block.  The
//   block has no load enable here, so a clock with a zero operand and acc = 1 holds the sum.
//
// Where it sits in the radio
//   Used by ft8_cand_lane.v for the multiplications of the mixer, the FIR filter and the DFT.
//
// Gowin specifics
//   The Gowin builds (`GOWIN_DSP` defined) instantiate MULTALU27X18, the 27 x 18-bit multiplier with a 48-bit adder
//   (Gowin's DSP user guide for this family).  It is used in the multiply-accumulate mode with a dynamic accumulate select
//   (ACCSEL, `acc` here), the registers for A, B, the accumulate select, the product (PREG) and the output (OREG) enabled on
//   CLK0 with CE0, the rest of the input registers bypassed, the pre-adder and the 12 x 12 mode unused, and the load
//   value `PRELOAD` as the block's PRE_LOAD parameter, which is what the sum restarts from when acc = 0.  Without
//   `GOWIN_DSP` (simulation) a model with the same three clocks of latency is used.  It is the same instance, with the same
//   parameters, as rx_mac in rtl/rx/fir_decim.v, under another name so that rtl/ft8 does not depend on that file's include
//   order, and the model was checked against Gowin's primitive model (docs/TANG_LESSONS.md section 6).

`timescale 1ns / 1ps

module ft8_mac #(
    // PRELOAD: the value that the sum restarts from when acc = 0 (a rounding constant in some uses).
  parameter [47:0] PRELOAD = 48'd0
)(
    // clock; a: signed 27-bit operand; b: signed 18-bit operand.
  input                     clock,
  input  signed [26:0]      a,
  input  signed [17:0]      b,
  input                     acc,   // 1: add to the previous result, 0: start from PRELOAD (set together with a and b)
  output signed [47:0]      p      // the accumulated result, 3 clocks after a, b and acc
);
  // The block's primitive instance (built for Gowin only).
`ifdef GOWIN_DSP
  wire [47:0] caso;
  wire [26:0] soa;
  MULTALU27X18 #(
    .AREG_CLK("CLK0"), .AREG_CE("CE0"), .AREG_RESET("RESET0"),
    .BREG_CLK("CLK0"), .BREG_CE("CE0"), .BREG_RESET("RESET0"),
    .DREG_CLK("BYPASS"), .DREG_CE("CE0"), .DREG_RESET("RESET0"),
    .C_IREG_CLK("BYPASS"), .C_IREG_CE("CE0"), .C_IREG_RESET("RESET0"),
    .PSEL_IREG_CLK("BYPASS"), .PSEL_IREG_CE("CE0"), .PSEL_IREG_RESET("RESET0"),
    .PADDSUB_IREG_CLK("BYPASS"), .PADDSUB_IREG_CE("CE0"), .PADDSUB_IREG_RESET("RESET0"),
    .ADDSUB0_IREG_CLK("BYPASS"), .ADDSUB0_IREG_CE("CE0"), .ADDSUB0_IREG_RESET("RESET0"),
    .ADDSUB1_IREG_CLK("BYPASS"), .ADDSUB1_IREG_CE("CE0"), .ADDSUB1_IREG_RESET("RESET0"),
    .CSEL_IREG_CLK("BYPASS"), .CSEL_IREG_CE("CE0"), .CSEL_IREG_RESET("RESET0"),
    .CASISEL_IREG_CLK("BYPASS"), .CASISEL_IREG_CE("CE0"), .CASISEL_IREG_RESET("RESET0"),
    .ACCSEL_IREG_CLK("CLK0"), .ACCSEL_IREG_CE("CE0"), .ACCSEL_IREG_RESET("RESET0"),
    .PREG_CLK("CLK0"), .PREG_CE("CE0"), .PREG_RESET("RESET0"),
    .ADDSUB0_PREG_CLK("BYPASS"), .ADDSUB0_PREG_CE("CE0"), .ADDSUB0_PREG_RESET("RESET0"),
    .ADDSUB1_PREG_CLK("BYPASS"), .ADDSUB1_PREG_CE("CE0"), .ADDSUB1_PREG_RESET("RESET0"),
    .CSEL_PREG_CLK("BYPASS"), .CSEL_PREG_CE("CE0"), .CSEL_PREG_RESET("RESET0"),
    .CASISEL_PREG_CLK("BYPASS"), .CASISEL_PREG_CE("CE0"), .CASISEL_PREG_RESET("RESET0"),
    .ACCSEL_PREG_CLK("CLK0"), .ACCSEL_PREG_CE("CE0"), .ACCSEL_PREG_RESET("RESET0"),
    .C_PREG_CLK("BYPASS"), .C_PREG_CE("CE0"), .C_PREG_RESET("RESET0"),
    .FB_PREG_EN("FALSE"), .SOA_PREG_EN("FALSE"),
    .OREG_CLK("CLK0"), .OREG_CE("CE0"), .OREG_RESET("RESET0"),
    .MULT_RESET_MODE("SYNC"), .PRE_LOAD(PRELOAD),
    .DYN_P_SEL("FALSE"), .P_SEL(1'b0), .DYN_P_ADDSUB("FALSE"), .P_ADDSUB(1'b0),
    .DYN_A_SEL("FALSE"), .A_SEL(1'b0),
    .DYN_ADD_SUB_0("FALSE"), .ADD_SUB_0(1'b0), .DYN_ADD_SUB_1("FALSE"), .ADD_SUB_1(1'b0),
    .DYN_C_SEL("FALSE"), .C_SEL(1'b0),
    .DYN_CASI_SEL("FALSE"), .CASI_SEL(1'b0),
    .DYN_ACC_SEL("TRUE"), .ACC_SEL(1'b0), .MULT12X12_EN("FALSE")
  ) u (
    .DOUT(p), .CASO(caso), .SOA(soa), .A(a), .B(b), .C(48'd0), .D(26'd0), .SIA(27'd0), .CASI(48'd0),
    .PSEL(1'b0), .ASEL(1'b0), .CSEL(1'b0), .CASISEL(1'b0), .PADDSUB(1'b0), .ACCSEL(acc),
    .ADDSUB(2'b00), .CLK({1'b0, clock}), .CE(2'b01), .RESET(2'b00)
  );
`else
  // Simulation model: three register stages, as in the DSP block (a and b, then the product and the accumulate flag, then the sum).

  reg signed [26:0] ar = 27'sd0;
  reg signed [17:0] br = 18'sd0;
  reg signed [44:0] mr = 45'sd0;
  reg               s0 = 1'b0, s1 = 1'b0;
  reg signed [47:0] o  = 48'sd0;
  wire signed [47:0] ld = s1 ? o : PRELOAD;
  always @(posedge clock) begin
    ar <= a;
    br <= b;
    s0 <= acc;
    mr <= ar * br;
    s1 <= s0;
    o  <= ld + {{3{mr[44]}}, mr};
  end
  assign p = o;
`endif
endmodule
