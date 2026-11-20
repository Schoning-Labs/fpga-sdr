// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Done-test of the full-band spectrum pipeline (rtl/spectrum/spectrum_pipeline.v) in its fast version, the
// one tools/check.sh runs: K = 2 frames are averaged into a line, the smallest K that still exercises the
// accumulate path over several frames, and the run takes well under a minute. The stimulus, the test body
// and all five checks (tone column and level, a column by column comparison with an independent model of
// everything after the FFT, and the level and spread of the noise floor against exact theory) are in
// sim/spectrum/spectrum_done_test.vh, which this file only parametrizes. The same body at K = 156 is
// sim/spectrum/spectrum_noise_full_k156.v (tools/spectrum_k156.sh). Run it from the repository root with
// `iverilog -g2012 -o tb.vvp sim/spectrum/tb_spectrum_pipeline.v` and `vvp tb.vvp`; it prints PASS on
// success (docs/F2_SPECTRUM.md "Done-test").

`define SPECTRUM_DT_MODULE tb_spectrum_pipeline
`define SPECTRUM_DT_K 2
`include "sim/spectrum/spectrum_done_test.vh"
