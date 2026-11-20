#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
# Runs the testbenches of the SFP block (rtl/sfp, docs/SFP_LINKS.md section 9) with iverilog: the coder and
# aligner bench (tb_sfp_codec.v) and the network socket bench (tb_sfp_net.v), the latter in four variants
# (1000BASE-X or SGMII, each without and with gaps in the receive words). The outputs go to sim/out/sfp.
# Run it from the repository root: bash sim/sfp/run.sh [codec|net|gaps], with no argument for all of them.
# Each run prints PASS lines or FAIL lines from the bench itself, and the oss-cad-suite tools are taken from
# C:/tools/oss-cad-suite when they are not on the PATH.
set -euo pipefail
export PATH="/c/tools/oss-cad-suite/bin:/c/tools/oss-cad-suite/lib:$PATH"
mkdir -p sim/out/sfp
SRC="rtl/sfp/sfp_rx_sym.v rtl/sfp/sfp_enc20.v rtl/sfp/sfp_xstat.v rtl/sfp/sfp_pcs.v rtl/sfp/sfp_phy.v rtl/sfp/sfp_net.v rtl/sfp/sfp_top.v
     rtl/n1/enc_8b10b.v rtl/n1/dec_8b10b.v rtl/n1/gmii_mac_tx.v rtl/n1/fcs_append.v rtl/n1/gmii_mac_rx.v
     rtl/hl2link/crc32_eth.v rtl/hl2link/cdc_word.v sim/sfp/sfp_lane_model.v"
what="${1:-all}"
if [ "$what" = all ] || [ "$what" = codec ]; then
    iverilog -g2012 -I rtl/n1 -o sim/out/sfp/codec.vvp $SRC sim/sfp/tb_sfp_codec.v && vvp -n sim/out/sfp/codec.vvp
fi
if [ "$what" = all ] || [ "$what" = net ]; then
    iverilog -g2012 -I rtl/n1 -o sim/out/sfp/net.vvp $SRC sim/sfp/tb_sfp_net.v && vvp -n sim/out/sfp/net.vvp
    iverilog -g2012 -I rtl/n1 -DSGMII -o sim/out/sfp/net_sg.vvp $SRC sim/sfp/tb_sfp_net.v && vvp -n sim/out/sfp/net_sg.vvp
fi
# receive words with gaps (the transceiver's receive buffer read with a faster clock), both modes
if [ "$what" = all ] || [ "$what" = gaps ]; then
    iverilog -g2012 -I rtl/n1 -DGAPS -o sim/out/sfp/net_gaps.vvp $SRC sim/sfp/tb_sfp_net.v && vvp -n sim/out/sfp/net_gaps.vvp
    iverilog -g2012 -I rtl/n1 -DGAPS -DSGMII -o sim/out/sfp/net_gaps_sg.vvp $SRC sim/sfp/tb_sfp_net.v && vvp -n sim/out/sfp/net_gaps_sg.vvp
fi
