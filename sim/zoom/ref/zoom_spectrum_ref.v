// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Reference model of the zoom spectrum top level: the zoom DDC reference (zoom_ddc_ref.v) feeding the window
// (rtl/zoom/zoom_window.v) and the 4,096-point complex FFT (rtl/fft/fft_r22sdf.v). It has the same ports as
// rtl/zoom/zoom_spectrum.v except for the narrow-span controls, and the only difference in the chain is the
// DDC: this one is built from the plain parallel stages, which is what the chip version is compared with, word
// for word, by sim/zoom/zoom_rb1_compare_sim.v and sim/zoom/zoom_rb1_burst_sim.v. docs/ARCHITECTURE.md section
// 3.4 and docs/F3_ZOOM.md describe the design, and docs/learn/GLOSSARY.md the terms.
//
// The output is at FFT-bin level: the raw, unscaled complex DFT output, one word per bin, with the bit
// reversal of the FFT already undone through out_bin. The averaging, dB conversion and waterfall of the
// back end are in rtl/spectrum/spectrum_pipeline.v and are not part of this module (docs/F3_ZOOM.md section 1
// says what that back end needs from this output).
//
// span_shift (0 to 6) selects the decimation 2^span_shift of the variable CIC inside the DDC, and the FFT always
// runs at the full internal rate of the DDC (3.84 MHz down to 60 kHz). Only the bins flagged by out_usable are
// alias-protected to at least 80 dB (docs/F3_ZOOM.md section 3) and meant to be displayed: the central
// 3,277 of the 4,096 bins (80 %), which are bin 0 plus 1,638 bins on either side across the wrap-around
// (out_bin <= 1,638 or out_bin >= 2,458). The displayed span is 0.8 times the full rate, 3.072 MHz down to
// 48 kHz in seven steps, and the bin spacing on it is (0.8 x full rate) / 3,277 (docs/F3_ZOOM.md section 3 has the
// figures for every span). The outer 20 % of the bins are valid FFT output as well, only not alias-protected,
// so a consumer should simply not draw them, in the same way that it would not draw bins beyond the Nyquist
// frequency of a full-band FFT.

// Ports: the same as the chip version, with the 12-bit ADC stream (adc_data and adc_valid), the zoom center as an NCO
// phase increment, the span, the enable, and the FFT output words (out_valid for a word, out_first on the
// first word of a frame, out_bin the bin number, out_re and out_im the 29-bit unscaled real and imaginary part:
// 17-bit window output plus 12 bits of FFT growth).
module zoom_spectrum_ref #(
    parameter ADC_WIDTH = 12,
    parameter LOG_N      = 12,   // 4,096-point FFT
    parameter WIN_OUT_W  = 17,   // window output width = FFT's IW
    parameter TW_DIR      = "rtl/fft/tw/"
)(
    input                        clock,
    input                        rst,
    input      [ADC_WIDTH-1:0]   adc_data,
    input                        adc_valid,

    input  signed [31:0]         phase_inc,  // zoom-centre NCO phase increment (see zoom_ddc.v for the sign convention)
    input      [2:0]             span_shift, // 0..6: pre-FIR rate = 7.68 MHz >> span_shift
    input                        enable,

    output                       out_valid,
    output                       out_first,
    output      [LOG_N-1:0]      out_bin,
    output                       out_usable, // 1 = this bin is within the alias-protected, displayed 80%
    output      [WIN_OUT_W+LOG_N-1:0] out_re,
    output      [WIN_OUT_W+LOG_N-1:0] out_im
);

// The usable half-width in bins is floor(0.4 x N), which is 80 % of the bins in all, split evenly around
// bin 0 with its wrap-around mirror at bins N - 1 down to N - USABLE_HALF.
localparam integer N            = 1 << LOG_N;
localparam integer USABLE_HALF  = (N * 4) / 10;
assign out_usable = (out_bin <= USABLE_HALF) || (out_bin >= (N - USABLE_HALF));

// The zoom DDC reference.
wire               ddc_valid;
wire signed [15:0] ddc_i, ddc_q;

zoom_ddc_ref #(
  .ADC_WIDTH(ADC_WIDTH)
) u_ddc (
  .clock(clock), .rst(rst),
  .adc_data(adc_data), .adc_valid(adc_valid),
  .phase_inc(phase_inc), .span_shift(span_shift), .enable(enable),
  .out_valid(ddc_valid), .out_i(ddc_i), .out_q(ddc_q)
);

// The window, then the FFT, which are the same modules as in the chip version.
wire                     win_valid;
wire signed [WIN_OUT_W-1:0] win_re, win_im;

zoom_window #(
  .N(1 << LOG_N), .IN_WIDTH(16), .OUT_WIDTH(WIN_OUT_W)
) u_win (
  .clock(clock), .rst(rst),
  .in_valid(ddc_valid), .in_i(ddc_i), .in_q(ddc_q),
  .out_valid(win_valid), .out_re(win_re), .out_im(win_im)
);

wire [LOG_N-1:0] fft_out_index;

fft_r22sdf #(
  .LOG_N(LOG_N), .IW(WIN_OUT_W), .REAL_IN(0), .TW_DIR(TW_DIR)
) u_fft (
  .clk(clock), .rst(rst),
  .in_valid(win_valid), .in_re(win_re), .in_im(win_im),
  .out_valid(out_valid), .out_first(out_first),
  .out_index(fft_out_index), .out_bin(out_bin),
  .out_re(out_re), .out_im(out_im)
);

endmodule
