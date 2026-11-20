#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
# Runs the testbench of the board link (rtl/blink, docs/SFP_LINKS.md section 9) with iverilog: compiles the
# board link, the SFP receive and transmit parts it uses and the lane model into sim/out/blink/tb.vvp and
# runs sim/blink/tb_blink.v, which prints PASS or FAIL lines.
# Run it from the repository root: bash sim/blink/run.sh
set -euo pipefail
export PATH="/c/tools/oss-cad-suite/bin:/c/tools/oss-cad-suite/lib:$PATH"
mkdir -p sim/out/blink
iverilog -g2012 -I rtl/n1 -o sim/out/blink/tb.vvp \
    rtl/blink/blink_top.v rtl/blink/blink_tx.v rtl/blink/blink_rx.v rtl/blink/blink_rx_buf.v \
    rtl/sfp/sfp_rx_sym.v rtl/sfp/sfp_enc20.v rtl/sfp/sfp_xstat.v \
    rtl/hl2link/cdc_word.v rtl/hl2link/cdc_sample_fifo.v rtl/hl2link/gap_filler.v \
    sim/sfp/sfp_lane_model.v sim/blink/tb_blink.v
vvp -n sim/out/blink/tb.vvp
