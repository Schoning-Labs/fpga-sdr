#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Checks the second decode pass of the FT8 front end (docs/FT8_PASS2.md) on the WSJT-X sample recordings. For each recording the
# first pass of the fixed-point Rust FT8 model (docs/S15_FT8MODEL.md) is subtracted from the audio (`ft8-frontend
# pass2-vectors`), the residual goes into the DDR3 model where the CPU would write it, and the front end as the chip
# instantiates it replays the residual and searches it on `p2_cmd`, with video traffic loading the DDR3 model
# (sim/ft8/ft8_pass2_wav_harness.v, docs/F4_DDR.md). `ft8-frontend pass2-check` then compares the replay's spectrogram and the
# search's records with the model bit for bit and runs the two-pass decode whose second pass starts from the RTL's records
# (for qso3_busy all eight of WSJT-X's reference decodes must be found). The simulated time of the replay and of the search
# is printed.
#
# The script skips without failing when captures/ has not been fetched (tools/fetch_test_audio.sh) or iverilog is missing.
# Runtime is about 20 million clocks per recording in Icarus.
#
# Usage: bash tools/check_ft8_pass2.sh [wav ...]   (default captures/ft8/qso1.wav and qso3_busy.wav)
#        PASS2_CAND=70 sets the candidate count of the first pass (default 60)
# Needs iverilog and vvp on PATH (oss-cad-suite) and cargo, which builds the host tool ft8-frontend. No Gowin EDA, no board.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

wavs=("$@")
[ "${#wavs[@]}" -eq 0 ] && wavs=(captures/ft8/qso1.wav captures/ft8/qso3_busy.wav)
for w in "${wavs[@]}"; do
    if [ ! -f "$w" ]; then
        echo "SKIPPED check_ft8_pass2.sh: $w not fetched; skipping (tools/fetch_test_audio.sh)"
        exit 0
    fi
done
command -v iverilog >/dev/null 2>&1 || { echo "SKIPPED check_ft8_pass2.sh: iverilog not found; skipping" >&2; exit 0; }

echo "== building ft8-frontend (host) ==" >&2
(cd fw && cargo build -q --release -p tr-modes --bin ft8-frontend) || { echo "FAIL: host build"; exit 1; }
# The host tool is built in release mode; on Windows cargo names it ft8-frontend.exe.
tool="fw/target/release/ft8-frontend"
[ -x "$tool.exe" ] && tool="$tool.exe"

# The decode band of 100 to 3,000 Hz as FFT bins (SyncBand::from_hz(100, 3000) in the Rust model).
ia=32; ib=960
cand="${PASS2_CAND:-60}"
fail=0
for w in "${wavs[@]}"; do
    name="$(basename "$w" .wav)"
    dir="sim/ft8/out/p2_$name${PASS2_TAG:-}"   # repo-relative, because the simulator is a native Windows program and cannot open /g/... paths
    mkdir -p "$dir"
    "$tool" pass2-vectors "$w" "$dir" "$cand" >&2 || { echo "FAIL: vectors $name"; fail=1; continue; }
    vvp_out="$dir/harness.vvp"
    if ! iverilog -g2012 -DRES_FILE=\"$dir/residual_lw.hex\" -DOUT_FILE=\"$dir/rtl_records.hex\" \
            -DSPEC_OUT=\"$dir/rtl_spec.hex\" -DBAND_IA=$ia -DBAND_IB=$ib -o "$vvp_out" sim/ft8/ft8_pass2_wav_harness.v; then
        echo "FAIL: compile"; fail=1; continue
    fi
    echo "== $name: RTL replay and search of the residual ==" >&2
    out="$(vvp "$vvp_out")"
    echo "$out" | grep -v '^VCD'
    if ! grep -q DONE <<<"$out"; then echo "FAIL: $name harness"; fail=1; continue; fi
    res="$("$tool" pass2-check "$w" "$dir/rtl_records.hex" "$dir/rtl_spec.hex" "$cand")"
    echo "$res"
    grep -q "PASS: pass2-check" <<<"$res" || fail=1
done

if [ "$fail" -ne 0 ]; then echo "FAIL: check_ft8_pass2.sh"; exit 1; fi
echo "PASS: check_ft8_pass2.sh"
