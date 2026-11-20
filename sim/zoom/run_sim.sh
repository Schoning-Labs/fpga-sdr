#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Runs the slow zoom tests, the ones that tools/check.sh leaves out because they take minutes to an hour each
# (docs/F3_ZOOM.md section 7.2). First the coefficient tables are made again (the window of the zoom FFT, the
# 63-tap anti-alias filter and the coefficient sets of the droop compensation) and the worst-case alias
# frequencies are worked out, then four simulations run with iverilog and vvp, one after the other:
#   1. alias-rejection measurement across the spans (sim/zoom/zoom_alias_sim.v, about 5 to 6 minutes for
#      the seven wide spans, and the narrow spans take longer)
#   2. the literal done-test at the 48 kHz span, a tone 1 kHz off the center (sim/zoom/zoom_bin48_sim.v,
#      about 30 to 35 minutes)
#   3. word-for-word comparison of the chip version of the zoom spectrum against the parallel reference
#      chain, with a steady stimulus of about 50 % duty (sim/zoom/zoom_rb1_compare_sim.v, 2 to 3 minutes)
#   4. the same comparison with real HL2 frame bursts (sim/zoom/zoom_rb1_burst_sim.v, about 10 minutes)
# Each simulation passes when its output holds a line with just PASS, and the script ends with one line
# that says whether all four did, and with an exit status of 0 only in that case.
#
# Call it from anywhere, the paths are relative to the script itself:  bash sim/zoom/run_sim.sh
# It needs Python 3 with numpy, and the oss-cad-suite tools iverilog and vvp, either on the PATH or in
# C:/tools/oss-cad-suite/bin (the PYTHON, IVERILOG and VVP environment variables override the defaults).

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# Python: python3 from the PATH, or else python (a Windows install often has no python3 alias).
PYTHON="${PYTHON:-python3}"
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  PYTHON="python"
fi

# iverilog and vvp: from the PATH, or else the oss-cad-suite install.
IVERILOG="${IVERILOG:-iverilog}"
VVP="${VVP:-vvp}"
if ! command -v "$IVERILOG" >/dev/null 2>&1; then
  IVERILOG="/c/tools/oss-cad-suite/bin/iverilog.exe"
  VVP="/c/tools/oss-cad-suite/bin/vvp.exe"
fi

# The simulations write their compiled output into sim/zoom/out, and the testbenches read their coefficient
# files and include the RTL by paths relative to the repository root, so the script goes there after making out.
mkdir -p out
cd ../..   # repo root, so `rtl/...`-relative includes in the testbenches resolve

# Tables first: the coefficients that the RTL reads and the alias analysis that the alias bench includes.
echo "== Generating zoom window, anti-alias FIR and droop-compensation coefficients =="
"$PYTHON" tools/gen_zoom_window.py || exit 1
"$PYTHON" tools/gen_zoom_fir_coeffs.py || exit 1
"$PYTHON" tools/gen_zoom_cic_comp_coeffs.py || exit 1

echo
echo "== [1/2] Alias-rejection measurement, all seven spans =="
echo "-- Computing worst-case alias frequencies --"
"$PYTHON" tools/analyze_zoom_alias.py || exit 1

# Each step compiles the bench, runs it, prints its output, and counts it as a failure unless its exit status
# is 0 and a line of exactly PASS was printed (a simulation can finish with FAIL and still exit 0).
echo "-- Compiling testbench --"
"$IVERILOG" -g2012 -o sim/zoom/out/zoom_alias.vvp sim/zoom/zoom_alias_sim.v || exit 1

echo "-- Running simulation --"
ALIAS_OUT="$("$VVP" sim/zoom/out/zoom_alias.vvp)"
ALIAS_STATUS=$?
echo "$ALIAS_OUT"
if [ "$ALIAS_STATUS" -ne 0 ] || ! grep -q "^PASS$" <<<"$ALIAS_OUT"; then
  ALIAS_STATUS=1
fi

echo
echo "== [2/2] Literal done-test: 48 kHz span, tone 1 kHz off centre =="
echo "   (this is the slow one -- 30-35 minutes, see docs/F3_ZOOM.md section 7.2)"
echo "-- Compiling testbench --"
"$IVERILOG" -g2012 -o sim/zoom/out/zoom_bin48.vvp sim/zoom/zoom_bin48_sim.v || exit 1

echo "-- Running simulation --"
BIN48_OUT="$("$VVP" sim/zoom/out/zoom_bin48.vvp)"
BIN48_STATUS=$?
echo "$BIN48_OUT"
if [ "$BIN48_STATUS" -ne 0 ] || ! grep -q "^PASS$" <<<"$BIN48_OUT"; then
  BIN48_STATUS=1
fi

echo
echo "== [3/4] Word-for-word check: time-multiplexed vs. parallel reference, steady stimulus =="
echo "-- Compiling testbench --"
"$IVERILOG" -g2012 -o sim/zoom/out/zoom_rb1_compare.vvp sim/zoom/zoom_rb1_compare_sim.v || exit 1

echo "-- Running simulation --"
RB1CMP_OUT="$("$VVP" sim/zoom/out/zoom_rb1_compare.vvp)"
RB1CMP_STATUS=$?
echo "$RB1CMP_OUT"
if [ "$RB1CMP_STATUS" -ne 0 ] || ! grep -q "^PASS$" <<<"$RB1CMP_OUT"; then
  RB1CMP_STATUS=1
fi

echo
echo "== [4/4] Word-for-word check: time-multiplexed vs. parallel reference, HL2-frame bursts =="
echo "   (this is the slow one -- about 10 minutes)"
echo "-- Compiling testbench --"
"$IVERILOG" -g2012 -o sim/zoom/out/zoom_rb1_burst.vvp sim/zoom/zoom_rb1_burst_sim.v || exit 1

echo "-- Running simulation --"
RB1BURST_OUT="$("$VVP" sim/zoom/out/zoom_rb1_burst.vvp)"
RB1BURST_STATUS=$?
echo "$RB1BURST_OUT"
if [ "$RB1BURST_STATUS" -ne 0 ] || ! grep -q "^PASS$" <<<"$RB1BURST_OUT"; then
  RB1BURST_STATUS=1
fi

# Summary of the four steps.
echo
echo "======================================================================"
if [ "$ALIAS_STATUS" -eq 0 ] && [ "$BIN48_STATUS" -eq 0 ] && [ "$RB1CMP_STATUS" -eq 0 ] && [ "$RB1BURST_STATUS" -eq 0 ]; then
  echo "OVERALL: ALL TESTS PASSED"
else
  echo "OVERALL: SOME CHECKS FAILED (alias exit=$ALIAS_STATUS, bin48 exit=$BIN48_STATUS, rb1 compare exit=$RB1CMP_STATUS, rb1 burst exit=$RB1BURST_STATUS)"
  echo "See the per-case output above for which ones and by how much."
fi
echo "======================================================================"
exit $(( ALIAS_STATUS != 0 || BIN48_STATUS != 0 || RB1CMP_STATUS != 0 || RB1BURST_STATUS != 0 ))
