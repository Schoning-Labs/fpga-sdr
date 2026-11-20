#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Runs the done-test of the zoom back end (docs/F2_SPECTRUM.md "Zoom backend done-test") in its literal form through the real
# zoom DDC and FFT: sim/zoom/zoom_backend_full_sim.v feeds a 1 kHz tone off center at a 48 kHz span, averages K = 2 frames and
# adds noise. That takes on the order of an hour, so tools/check.sh runs sim/zoom/tb_zoom_backend_quick.v instead, which
# injects synthetic FFT bins and covers the same logic quickly. The script exits non-zero unless the testbench prints PASS.
#
# Usage: tools/zoom_backend_full_sim.sh   (from anywhere)
# Needs iverilog and vvp on PATH, for example from oss-cad-suite. No Gowin EDA, no board.

set -uo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

out="$(mktemp -d)/zoom_backend_full_sim.vvp"
iverilog -g2012 -o "$out" sim/zoom/zoom_backend_full_sim.v || { echo "FAIL: compile"; exit 1; }
output="$(vvp "$out")"
status=$?
rm -f "$out"
echo "$output"
if [ "$status" -ne 0 ] || ! grep -q "^PASS" <<<"$output"; then
    echo "FAIL: zoom_backend_full_sim"
    exit 1
fi
echo "PASS: zoom_backend_full_sim"
