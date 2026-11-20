// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Done-test of the full-band spectrum pipeline (rtl/spectrum/spectrum_pipeline.v) at K = 156, which is the
// number of FFT frames averaged into one line that the design is specified for: 156 frames are
// 156 * 16,384 = 2.57 million ADC samples, so the run takes several minutes. It is not named tb_*.v, which
// is why tools/check.sh skips it and runs the K = 2 version (sim/spectrum/tb_spectrum_pipeline.v)
// instead; run this one with tools/spectrum_k156.sh, which fails unless the bench prints PASS. The body
// and all checks are shared with the fast version in sim/spectrum/spectrum_done_test.vh, and at this K
// the standard deviation of the noise floor in dB is checked against theory as well, because with 156
// frames the averaged floor is smooth enough for that figure to mean something. Measured results are in
// docs/F2_SPECTRUM.md ("Measured results").

`define SPECTRUM_DT_MODULE spectrum_noise_full_k156
`define SPECTRUM_DT_K 156
`include "sim/spectrum/spectrum_done_test.vh"
