// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// zoom_window: multiplies every sample of a 4,096-sample frame by a window coefficient before the zoom
// FFT (docs/F3_ZOOM.md). An FFT assumes that its frame repeats forever, and a signal that does not fit
// the frame exactly would leak into all bins, hiding weak signals next to strong ones. Fading the
// samples at the two ends of the frame to zero with a window avoids most of that. This is a 4-term
// Blackman-Harris window (side lobes about -92 dB, the same as the full-band FFT's,
// docs/ARCHITECTURE.md 3.3), applied to the complex output of the zoom DDC. The terms are explained
// in docs/learn/GLOSSARY.md.
//
// Frames are 4,096 consecutive input samples counted from reset, the same convention as
// rtl/fft/fft_r22sdf.v, so the two stay aligned as long as both are reset together.
//
// Coefficients: rtl/zoom/zoom_window_coeffs.hex, unsigned Q0.16 (a number between 0 and 1 with 16
// fraction bits), written by tools/gen_zoom_window.py. The window is symmetric, so only the first half
// (2,048 entries) is stored; the second half is read with the address mirrored (inverted). The
// product of a 16-bit sample and a coefficient is 17 bits wider, rounded half up at 2^-16 and cut to
// OUT_WIDTH bits.
//
// Pipeline, 6 clocks from in_valid to out_valid; the ROM is a block RAM read with a registered
// address and an output register, the multiplier has an input and an output register, and the
// rounding add has its own clock. The next sample is at least 15 clocks away (the fixed CIC in
// the DDC decimates by 10 and the later stages are slower), so the sample can simply be held:
//   clock 1  sample and ROM address    clock 2  ROM read       clock 3  ROM output register
//   clock 4  multiplier inputs         clock 5  product        clock 6  rounded output

module zoom_window #(
    parameter integer N            = 4096,   // frame length, a power of two
    parameter integer IN_WIDTH     = 16,   // zoom_ddc.out_i/out_q width
    parameter integer COEFF_WIDTH  = 16,   // unsigned Q0.16
    parameter integer OUT_WIDTH    = 17,   // fft_r22sdf's IW for the zoom FFT
    parameter         COEFF_FILE   = "rtl/zoom/zoom_window_coeffs.hex"
)(
    input                         clock,
    input                         rst,           // synchronous reset, restarts the frame count
    input                         in_valid,      // one-clock pulse per input sample
    input      signed [IN_WIDTH-1:0] in_i,       // sample, real part
    input      signed [IN_WIDTH-1:0] in_q,       // imaginary part

    output reg                    out_valid,     // windowed sample valid, 6 clocks after in_valid
    output reg signed [OUT_WIDTH-1:0] out_re,    // windowed sample, real part
    output reg signed [OUT_WIDTH-1:0] out_im     // imaginary part
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;

localparam integer HALF_BITS  = $clog2(N/2);
localparam integer POS_BITS   = $clog2(N);
localparam integer SHIFT      = COEFF_WIDTH;
localparam integer PROD_WIDTH = IN_WIDTH + COEFF_WIDTH + 1;   // +1: the coefficient's sign bit (always 0)

reg [COEFF_WIDTH-1:0] win_rom [0:(N/2)-1];
initial $readmemh(COEFF_FILE, win_rom);

// frame position 0 .. N-1, counted from reset; the window address is the position in the first half
// and its inverse (the mirror) in the second half
reg [POS_BITS-1:0] frame_pos = {POS_BITS{1'b0}};
always @(posedge clock)
  if (rst)           frame_pos <= {POS_BITS{1'b0}};
  else if (in_valid) frame_pos <= frame_pos + 1'b1;          // N is a power of two: wraps by itself

wire [HALF_BITS-1:0] win_addr = frame_pos[POS_BITS-1] ? ~frame_pos[HALF_BITS-1:0]
                                                      :  frame_pos[HALF_BITS-1:0];

reg [4:0]                    v = 5'd0;
reg [HALF_BITS-1:0]          a1 = {HALF_BITS{1'b0}};
reg signed [IN_WIDTH-1:0]    i1 = {IN_WIDTH{1'b0}}, q1 = {IN_WIDTH{1'b0}};
reg [COEFF_WIDTH-1:0]        c2 = {COEFF_WIDTH{1'b0}}, c3 = {COEFF_WIDTH{1'b0}};
reg signed [IN_WIDTH-1:0]    mi = {IN_WIDTH{1'b0}}, mq = {IN_WIDTH{1'b0}};
reg signed [COEFF_WIDTH:0]   mc = {(COEFF_WIDTH+1){1'b0}};
reg signed [PROD_WIDTH-1:0]  pi = {PROD_WIDTH{1'b0}}, pq = {PROD_WIDTH{1'b0}};

wire signed [PROD_WIDTH-1:0] ri = pi + (1 <<< (SHIFT-1));
wire signed [PROD_WIDTH-1:0] rq = pq + (1 <<< (SHIFT-1));

always @(posedge clock) begin
  v <= rst ? 5'd0 : {v[3:0], in_valid};
  // clock 1: the sample is held (the next one is at least 15 clocks away)
  if (in_valid) begin
    a1 <= win_addr;
    i1 <= in_i;
    q1 <= in_q;
  end
  c2 <= win_rom[a1];                                         // clock 2
  c3 <= c2;                                                  // clock 3
  mi <= i1;  mq <= q1;  mc <= {1'b0, c3};                    // clock 4
  pi <= mi * mc;                                             // clock 5
  pq <= mq * mc;
  out_valid <= rst ? 1'b0 : v[4];                            // clock 6
  if (v[4]) begin
    out_re <= ri[SHIFT +: OUT_WIDTH];
    out_im <= rq[SHIFT +: OUT_WIDTH];
  end
end

endmodule
