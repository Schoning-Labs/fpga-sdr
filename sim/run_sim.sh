#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Runs the receiver bank tests of the radio in one command. The receiver bank (rtl/rx/rx_bank.v) is the eight digital receivers that
# each mix the ADC stream down to baseband with a numerically controlled oscillator, decimate it with CIC filters and
# clean it up with a compensating FIR filter, and this script checks two things about it:
#   1. a functional test, in which synthetic ADC signals with known tones go in and check_results.py measures the amplitude
#      and frequency of each tone at the output of every receiver (rx/rx_bank_functional_sim.v is the bench);
#   2. an alias rejection test, in which full scale interferers placed at the worst case alias frequencies of every
#      receiver go in and check_alias.py measures how far down they land (rx/rx_alias_sim.v is the bench).
# Both runs compile with iverilog, run with vvp, and the script ends with one overall line that says whether every
# check passed. Call it from anywhere, since it changes into its own folder first:
#   bash sim/run_sim.sh
# Requires Python 3 with numpy, scipy and matplotlib, and oss-cad-suite (iverilog and vvp) on the PATH or in
# C:/tools/oss-cad-suite/bin. The variables PYTHON, IVERILOG and VVP override the programs that are used.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# Python: the one given in PYTHON, else python3, else the python on the PATH (a Windows install often has no python3 alias).
PYTHON="${PYTHON:-python3}"
if ! command -v "$PYTHON" >/dev/null 2>&1; then
  PYTHON="python"
fi

# iverilog and vvp: from the environment or the PATH, else the oss-cad-suite folder.
IVERILOG="${IVERILOG:-iverilog}"
VVP="${VVP:-vvp}"
if ! command -v "$IVERILOG" >/dev/null 2>&1; then
  IVERILOG="/c/tools/oss-cad-suite/bin/iverilog.exe"
  VVP="/c/tools/oss-cad-suite/bin/vvp.exe"
fi

# Scratch folder for the compiled benches and the captures (sim/out).
mkdir -p out
# The receive chain under test: mixer, the two CIC filter stages, the FIR decimator with its delay RAM, one receiver channel, and the bank of eight.
RTL_FILES="../rtl/rx/nco_mixer.v ../rtl/rx/cic_integrator.v ../rtl/rx/cic_comb.v \
  ../rtl/rx/cic_fixed.v ../rtl/rx/cic_var_shared.v ../rtl/rx/fir_decim.v ../rtl/rx/fir_delay_ram2.v \
  ../rtl/rx/rx_channel.v ../rtl/rx/rx_bank.v"

echo "== Generating compensating FIR coefficients =="
"$PYTHON" ../tools/gen_fir_coeffs.py || exit 1

echo "== [1/2] Functional test: signal accuracy across all 8 receivers =="
echo "-- Generating ADC test signals --"
"$PYTHON" ../tools/gen_signals/gen_test_signals.py || exit 1

echo "-- Compiling testbench --"
"$IVERILOG" -g2012 -DNCO_TABLE_FILE='"../rtl/rx/nco_sin_table.hex"' -o out/tb_rx_bank.vvp rx/rx_bank_functional_sim.v $RTL_FILES || exit 1

echo "-- Running simulation --"
"$VVP" out/tb_rx_bank.vvp || exit 1

echo "-- Checking results --"
"$PYTHON" check_results.py
FUNCTIONAL_STATUS=$?

echo
echo "== [2/2] Targeted alias-rejection test =="
echo "-- Computing worst-case alias frequencies --"
"$PYTHON" ../tools/analyze_alias.py || exit 1

echo "-- Generating alias test signals --"
"$PYTHON" ../tools/gen_signals/gen_alias_test_signals.py || exit 1

echo "-- Compiling testbench --"
# The NCO sine table file is handed to the benches as a define, and the include path is relative to this folder.
"$IVERILOG" -g2012 -DNCO_TABLE_FILE='"../rtl/rx/nco_sin_table.hex"' -o out/tb_alias.vvp rx/rx_alias_sim.v $RTL_FILES || exit 1

echo "-- Running simulation --"
"$VVP" out/tb_alias.vvp || exit 1

echo "-- Checking results --"
"$PYTHON" check_alias.py
ALIAS_STATUS=$?

echo
echo "======================================================================"
if [ "$FUNCTIONAL_STATUS" -eq 0 ] && [ "$ALIAS_STATUS" -eq 0 ]; then
  echo "OVERALL: ALL TESTS PASSED"
else
  echo "OVERALL: SOME CHECKS FAILED (functional exit=$FUNCTIONAL_STATUS, alias exit=$ALIAS_STATUS)"
  echo "See the per-case tables above for which ones and by how much."
fi
echo "======================================================================"
exit $(( FUNCTIONAL_STATUS != 0 || ALIAS_STATUS != 0 ))
