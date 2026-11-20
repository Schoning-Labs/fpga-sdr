#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Checks the FT8 candidate engine (rtl/ft8/ft8_cand.v, docs/F7_CAND.md section 5) on the WSJT-X sample recordings, against the
# fixed-point FT8 model written in Rust (docs/S15_FT8MODEL.md). The testbench sim/ft8/ft8_cand_wav_harness.v runs ft8_cand.v
# over 480 candidates (8 receivers with 60 candidates each, the candidates of the model's one-pass decode of qso3_busy and
# qso1, four receivers per recording) while video traffic loads the DDR3 model (docs/F4_DDR.md), compares every baseband and
# soft-symbol word with the model's and prints the simulated time. Then `ft8-frontend cand-check` runs the model's decode
# (LDPC and the rest, from mfsk-core) on the RTL's own pass-1 and pass-2 words and checks that it gives the model's messages.
#
# The script skips without failing when captures/ has not been fetched (tools/fetch_test_audio.sh) or iverilog is missing.
# Runtime is about 50 million clocks in Icarus, which is well over an hour. FT8_CAND_RX=<n> runs only the first n receivers
# (the decode check needs n >= 2).
#
# Usage: bash tools/check_ft8_cand.sh
# Needs iverilog and vvp on PATH (oss-cad-suite) and cargo, which builds the host tool ft8-frontend. No Gowin EDA, no board.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

for w in captures/ft8/qso1.wav captures/ft8/qso3_busy.wav; do
    if [ ! -f "$w" ]; then
        echo "SKIPPED check_ft8_cand.sh: $w not fetched; skipping (tools/fetch_test_audio.sh)"
        exit 0
    fi
done
command -v iverilog >/dev/null 2>&1 || { echo "SKIPPED check_ft8_cand.sh: iverilog not found; skipping" >&2; exit 0; }

echo "== building ft8-frontend (host) ==" >&2
(cd fw && cargo build -q --release -p tr-modes --bin ft8-frontend) || { echo "FAIL: host build"; exit 1; }
# The host tool is built in release mode; on Windows cargo names it ft8-frontend.exe.
tool="fw/target/release/ft8-frontend"
[ -x "$tool.exe" ] && tool="$tool.exe"

out="sim/ft8/out/f7"   # repo-relative, because the simulator is a native Windows program and cannot open /g/... paths
mkdir -p "$out"
for name in qso3_busy qso1; do
    "$tool" f7-vectors "captures/ft8/$name.wav" "$out/vec_$name" 60 >&2 || { echo "FAIL: vectors $name"; exit 1; }
done

n_rx="${FT8_CAND_RX:-8}"
if ! iverilog -g2012 -DVEC3=\"$out/vec_qso3_busy\" -DVEC1=\"$out/vec_qso1\" -DOUT_DIR=\"$out\" \
        -DN_RX=$n_rx -o "$out/harness.vvp" sim/ft8/ft8_cand_wav_harness.v; then
    echo "FAIL: compile"; exit 1
fi
echo "== RTL candidate engine: $n_rx receivers x 60 candidates ==" >&2
res="$(vvp "$out/harness.vvp")"
echo "$res"
fail=0
grep -q "PASS: ft8_cand_wav_harness" <<<"$res" || fail=1

if [ "$n_rx" -ge 2 ]; then
    for name in qso3_busy qso1; do
        r="$("$tool" cand-check "captures/ft8/$name.wav" "$out/rtl_${name}_pass1.hex" "$out/rtl_${name}_pass2.hex")"
        echo "$r"
        grep -q "PASS: cand-check" <<<"$r" || fail=1
    done
fi

if [ "$fail" -ne 0 ]; then echo "FAIL: check_ft8_cand.sh"; exit 1; fi
echo "PASS: check_ft8_cand.sh"
