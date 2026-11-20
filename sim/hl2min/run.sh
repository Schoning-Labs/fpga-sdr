#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
# Runs the testbench of the minimal HL2 test build (rtl/hl2min/, docs/HL2MIN.md section 7): compiles it together with the
# transceiver lane (rtl/sfp/), the HL2 link receive path (rtl/hl2link/) and the lane model (sim/sfp/sfp_lane_model.v),
# runs it with vvp, and deletes the compiled file afterwards. Call it from the repository root:
#   bash sim/hl2min/run.sh [extra iverilog defines, e.g. -DPPM_NEG -DDROP -DSIM_SECS=40]
# Receive gaps are always on (-DGAPS). The pass or fail result is printed by tb_hl2min.v, see its header.
set -euo pipefail
export PATH="/c/tools/oss-cad-suite/bin:/c/tools/oss-cad-suite/lib:$PATH"
mkdir -p sim/out/hl2min
SRC="rtl/sfp/sfp_rx_sym.v rtl/sfp/sfp_xstat.v rtl/sfp/sfp_pcs.v rtl/sfp/sfp_phy.v rtl/n1/enc_8b10b.v
     rtl/n1/fcs_append.v rtl/hl2link/crc32_eth.v rtl/hl2link/cdc_word.v rtl/hl2link/cdc_sample_fifo.v
     rtl/hl2link/gmii_rx_in.v rtl/hl2link/eth_frame_rx.v rtl/hl2link/raw_frame_buffer.v rtl/hl2link/gap_filler.v
     rtl/hl2link/cpu_rx_ring.v rtl/hl2link/hl2_link_rx_top.v rtl/hl2link/gmii_tx_out.v
     rtl/hl2min/hl2min_clkseq.v rtl/hl2min/hl2min_sender.v rtl/hl2min/hl2min_report.v rtl/hl2min/hl2min_core.v
     rtl/net/chip_dna.v sim/net/otp_model.v sim/sfp/sfp_lane_model.v"
iverilog -g2012 -I rtl/n1 -DGAPS "$@" -o sim/out/hl2min/tb_$$.vvp $SRC sim/hl2min/tb_hl2min.v
vvp -n sim/out/hl2min/tb_$$.vvp; rm -f sim/out/hl2min/tb_$$.vvp
