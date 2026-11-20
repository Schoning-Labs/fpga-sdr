// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// zoom_spectrum: the zoom DDC, the window and a 4,096-point complex FFT chained into one self-contained
// zoom spectrum (docs/ARCHITECTURE.md 3.4, docs/F3_ZOOM.md). In the chip the zoom uses zoom_frontend.v and
// the whole-band FFT instead, so this module is the version with a private FFT that the simulations use
// as the reference for it. The terms are explained in docs/learn/GLOSSARY.md.
//
// The output is at FFT-bin level: the raw unscaled complex DFT, one word per bin, with the bit
// reversal of the FFT's output order already undone through out_bin. A later stage (averaging,
// dB conversion, waterfall line) takes it from there the same way it takes the full-band FFT's
// output (docs/F3_ZOOM.md section 1, "Hand-off to F2").
//
// span_shift (0..6) selects the decimation 2^span_shift of cic_var_pow2 inside the zoom DDC; the FFT
// itself always runs at the DDC's full (uncropped) internal rate (3.84 MHz down to 60 kHz, and
// lower with the narrow spans). Only the `out_usable` bins are alias-protected to at least 80 dB
// (docs/F3_ZOOM.md section 3) and meant to be displayed: the central 3,277 of 4,096 bins (80.0 percent),
// which is bin 0 and 1,638 bins to either side of it across the wrap-around
// (`out_bin <= 1,638 or out_bin >= 2,458`). The displayed span, 0.8 times the full internal rate, is
// 3.072 MHz at the widest setting and halves with every step down to 48 kHz, and then 24 kHz to 3 kHz with
// the narrow spans; the bin spacing on it is that span divided by 3,277 (docs/F3_ZOOM.md section 3 has
// the exact numbers per span). The outer 20 percent of the bins are still valid FFT output, just not
// protected against aliases, so a consumer should not draw them, the same way it would not draw bins
// beyond the full-band FFT's own Nyquist.

module zoom_spectrum #(
    parameter ADC_WIDTH = 12,    // bits of one ADC sample
    parameter LOG_N      = 12,   // 4,096-point FFT
    parameter WIN_OUT_W  = 17,   // window output width = FFT's IW
    parameter TW_DIR      = "rtl/fft/tw/",
    parameter integer SR_LUT = 1, // the FFT's delay lines of up to 32 words as LUT RAM, not block RAM (as the full-band FFT)
    parameter integer FFT_TW_LUT_MAX = 32, // the FFT's twiddle ROMs of up to this many words in LUTs (the chip: 128)
    parameter integer FFT_LUT_MAX_W = 128 // the FFT's delay lines of up to this many words as LUT RAM (the chip: 512)
)(
    input                        clock,       // clk_dsp
    input                        rst,         // synchronous reset
    input      [ADC_WIDTH-1:0]   adc_data,    // raw ADC sample
    input                        adc_valid,   // one-clock pulse per sample

    input  signed [31:0]         phase_inc,  // zoom-center NCO phase increment (see zoom_ddc.v for the sign convention)
    input      [2:0]             span_shift, // 0..6: pre-FIR rate = 7.68 MHz >> span_shift
    input      [2:0]             narrow_shift, // 1..4 with span_shift = 6: the narrow spans, 24 kHz to 3 kHz (zoom_ddc.v)
    input      [1:0]             narrow_gain,  // their gain, 4^narrow_gain
    input                        enable,

    output                       out_valid,  // an FFT output word is valid
    output                       out_first,  // the first word of a frame
    output      [LOG_N-1:0]      out_bin,    // frequency bin of the word (0 is the zoom center, bins above N/2 are below it)
    output                       out_usable, // 1 = this bin is within the alias-protected, displayed 80%
    output      [WIN_OUT_W+LOG_N-1:0] out_re,    // unscaled DFT value, real part
    output      [WIN_OUT_W+LOG_N-1:0] out_im     // imaginary part
) /* synthesis syn_maxfan = 10000 */;

// Usable half-width in bins = floor(0.4 * N) (80% total, split symmetrically
// around bin 0 with its wraparound mirror at bin N-1..N-USABLE_HALF, as the module
// header says).
localparam integer N            = 1 << LOG_N;
localparam integer USABLE_HALF  = (N * 4) / 10;
assign out_usable = (out_bin <= USABLE_HALF) || (out_bin >= (N - USABLE_HALF));

wire               ddc_valid;
wire signed [15:0] ddc_i, ddc_q;

zoom_ddc #(
  .ADC_WIDTH(ADC_WIDTH)
) u_ddc (
  .clock(clock), .rst(rst),
  .adc_data(adc_data), .adc_valid(adc_valid),
  .phase_inc(phase_inc), .span_shift(span_shift), .narrow_shift(narrow_shift), .narrow_gain(narrow_gain),
  .enable(enable),
  .out_valid(ddc_valid), .out_i(ddc_i), .out_q(ddc_q)
);

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
  .LOG_N(LOG_N), .IW(WIN_OUT_W), .REAL_IN(0), .TW_DIR(TW_DIR), .SR_LUT(SR_LUT),
  .TW_LUT_MAX(FFT_TW_LUT_MAX),
  .LUT_MAX_W(FFT_LUT_MAX_W)   // 128: the 128-word delay line in LUT RAM (Gowin made it 4 block RAMs); 512: the
                              // 256- and 512-word ones too (4 and 3 blocks), docs/ZOOM_IN_CHIP.md section 11
) u_fft (
  .clk(clock), .rst(rst),
  .in_valid(win_valid), .in_re(win_re), .in_im(win_im),
  .out_valid(out_valid), .out_first(out_first),
  .out_index(fft_out_index), .out_bin(out_bin),
  .out_re(out_re), .out_im(out_im)
);

endmodule
