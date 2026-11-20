#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Runs the full scenarios of the receiver back end (docs/R4_BACKEND.md section 6): the back-end RTL against the bit-exact Rust
# model with 1,024-tap and other realistic filters, real-time bank pacing, every demodulator mode at every input rate, bank
# switches, and one run with all 8 receivers at 384 ksps with 1,024 taps (the throughput worst case). It also runs the
# end-to-end chain, in which the real receiver bank (rtl/rx) feeds the back end and the result is compared with tr-rxmodel
# feeding the back-end model (sim/rx_backend/r4_chain.v).
#
# The model (fw/tr-dsp/examples/r4_check.rs) writes the scenario includes and the expected outputs, the scenarios run in parallel
# under iverilog with sim/rx_backend/tb_rx_backend.v, and on a failure the first differing output lines per receiver are shown.
# It is not part of tools/check.sh, because it takes about 30 to 40 minutes on a busy PC and the quick scenario there covers
# the same logic with short filters. Everything is written under sim/rx_backend/out/full (logs in k*/log.txt).
#
# Usage: bash tools/run_r4_full.sh   (from anywhere; needs cargo, and iverilog and vvp on PATH, for example from oss-cad-suite)
# No Gowin EDA, no board.

set -uo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
out=sim/rx_backend/out/full
rm -rf "$out"
mkdir -p "$out"

echo "== model: scenarios and expected outputs =="
(cd fw && cargo run -q -p tr-dsp --example r4_check -- full "../$out") || { echo "FAIL: model"; exit 1; }

mkdir -p "$out/chain"
(cd fw && cargo run -q -p tr-dsp --example r4_check -- chain 200000 "../$out/chain/chain_scn.vh" > /dev/null) || { echo "FAIL: chain model"; exit 1; }

# Number of scenarios the model wrote; each one gets its own folder k<N> and its own simulation.
n=$(ls "$out"/scn_*.vh | wc -l)
pids=()
if ! iverilog -g2012 -I "$out/chain" -o "$out/chain/tb.vvp" sim/rx_backend/r4_chain.v; then
    echo "FAIL: compile chain"
    exit 1
fi
# The chain run goes to the background and the scenario runs below join it, so everything runs in parallel.
(vvp "$out/chain/tb.vvp" > "$out/chain/log.txt" 2>&1) &
pids+=($!)
# One compile and one background run per scenario, with the scenario copied in as scn_full.vh.
for ((k = 0; k < n; k++)); do
    d="$out/k$k"
    mkdir -p "$d"
    cp "$out/scn_$k.vh" "$d/scn_full.vh"
    if ! iverilog -g2012 -DFULL_SCN -I "$d" -o "$d/tb.vvp" sim/rx_backend/tb_rx_backend.v; then
        echo "FAIL: compile scenario $k"
        exit 1
    fi
    (vvp "$d/tb.vvp" "+dump=$d/rtl" > "$d/log.txt" 2>&1) &
    pids+=($!)
done
echo "== running $n scenarios in parallel (logs in $out/k*/log.txt) =="
for p in "${pids[@]}"; do wait "$p"; done

# Report each scenario in turn; for a failed one the first lines where each receiver's output differs from the model's are shown.
fail=0
for ((k = 0; k < n; k++)); do
    d="$out/k$k"
    echo "-- scenario $k: $(head -1 "$out/scn_$k.vh" >/dev/null; grep -o 'Scenario "[^"]*"' "$out/scn_$k.vh") --"
    grep -v '^VCD\|\$finish' "$d/log.txt"
    if ! grep -q '^PASS' "$d/log.txt"; then
        fail=1
        for ((r = 0; r < 8; r++)); do
            if [ -f "$d/rtl_rx$r.txt" ]; then
                diff <(tr -d '\r' < "$d/rtl_rx$r.txt") <(tr -d '\r' < "$out/exp_${k}_rx$r.txt") | head -4 | sed "s/^/   rx$r: /"
            fi
        done
    fi
done
echo "-- chain: receiver bank -> back end --"
grep -v '\$finish' "$out/chain/log.txt"
grep -q '^PASS' "$out/chain/log.txt" || fail=1
if [ "$fail" -ne 0 ]; then
    echo "run_r4_full: FAILED"
    exit 1
fi
echo "run_r4_full: all scenarios and the chain bit-exact"
