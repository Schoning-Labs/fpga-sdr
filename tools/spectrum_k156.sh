#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Runs the done-test of the spectrum pipeline (docs/F2_SPECTRUM.md "Done-test") at its full averaging count of K = 156 frames,
# with the testbench sim/spectrum/spectrum_noise_full_k156.v. That takes several minutes, so tools/check.sh runs the K = 2
# version of the same test instead. The script exits non-zero unless the testbench prints a line that starts with PASS.
#
# Usage: tools/spectrum_k156.sh   (from anywhere)
# Needs iverilog and vvp on PATH, for example from oss-cad-suite. No Gowin EDA, no board.

set -uo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

out="$(mktemp -d)/spectrum_noise_full_k156.vvp"
iverilog -g2012 -o "$out" sim/spectrum/spectrum_noise_full_k156.v || { echo "FAIL: compile"; exit 1; }
output="$(vvp "$out")"
status=$?
rm -f "$out"
echo "$output"
if [ "$status" -ne 0 ] || ! grep -q "^PASS" <<<"$output"; then
    echo "FAIL: spectrum_noise_full_k156"
    exit 1
fi
echo "PASS: spectrum_noise_full_k156"
