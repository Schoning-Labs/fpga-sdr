#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
# Runs the long zero-loss testbench of the HL2 link on transceiver lane 0 (docs/HL2_SFP.md section 8): compiles
# tb_hl2_sfp.v together with the transceiver lane (rtl/sfp/), the HL2 link receive path (rtl/hl2link/) and the lane
# model (sim/sfp/sfp_lane_model.v), runs it with vvp, and deletes the compiled file afterwards. Call it from the
# repository root:
#   bash sim/hl2sfp/run.sh [-DN=5968] [-DBURST=2] [-DSIM_US=20000] [-DPPM_NEG]
# The pass or fail result is printed by tb_hl2_sfp.v, see its header.
set -euo pipefail
export PATH="/c/tools/oss-cad-suite/bin:/c/tools/oss-cad-suite/lib:$PATH"
mkdir -p sim/out/hl2sfp
SRC="rtl/sfp/sfp_rx_sym.v rtl/sfp/sfp_xstat.v rtl/sfp/sfp_pcs.v rtl/sfp/sfp_phy.v rtl/n1/enc_8b10b.v
     rtl/hl2link/crc32_eth.v rtl/hl2link/cdc_word.v rtl/hl2link/cdc_sample_fifo.v rtl/hl2link/gmii_rx_in.v
     rtl/hl2link/eth_frame_rx.v rtl/hl2link/raw_frame_buffer.v rtl/hl2link/gap_filler.v rtl/hl2link/cpu_rx_ring.v
     rtl/hl2link/hl2_link_rx_top.v sim/sfp/sfp_lane_model.v"
out="sim/out/hl2sfp/tb_$$.vvp"
iverilog -g2012 -I rtl/n1 "$@" -o "$out" $SRC sim/hl2sfp/tb_hl2_sfp.v
vvp -n "$out"; rm -f "$out"
