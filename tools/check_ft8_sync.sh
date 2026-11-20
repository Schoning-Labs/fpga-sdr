#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Checks the FT8 sync search (rtl/ft8/ft8_sync.v, docs/F6_SYNC.md section 5) on the WSJT-X sample recordings. For each recording
# the spectrogram of the fixed-point Rust FT8 model (docs/S15_FT8MODEL.md) goes into the DDR3 model, ft8_sync.v searches the
# whole decode band (100 to 3,000 Hz, bins 32 to 960) with video traffic loading the DDR3 model
# (sim/ft8/ft8_sync_wav_harness.v, docs/F4_DDR.md), and `ft8-frontend sync-check` then checks the RTL's records against the model
# bit for bit, builds the candidate list from them and runs the two-pass decode that starts from it (for qso3_busy all eight of
# WSJT-X's reference decodes must be found). The simulated time of each search is printed.
#
# The script skips without failing when captures/ has not been fetched (tools/fetch_test_audio.sh) or iverilog is missing.
# Runtime is about 6 million clocks per recording in Icarus, several minutes each.
#
# Usage: bash tools/check_ft8_sync.sh [wav ...]   (default captures/ft8/qso1.wav and qso3_busy.wav)
# Needs iverilog and vvp on PATH (oss-cad-suite) and cargo, which builds the host tool ft8-frontend. No Gowin EDA, no board.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

wavs=("$@")
[ "${#wavs[@]}" -eq 0 ] && wavs=(captures/ft8/qso1.wav captures/ft8/qso3_busy.wav)
for w in "${wavs[@]}"; do
    if [ ! -f "$w" ]; then
        echo "SKIPPED check_ft8_sync.sh: $w not fetched; skipping (tools/fetch_test_audio.sh)"
        exit 0
    fi
done
command -v iverilog >/dev/null 2>&1 || { echo "SKIPPED check_ft8_sync.sh: iverilog not found; skipping" >&2; exit 0; }

echo "== building ft8-frontend (host) ==" >&2
(cd fw && cargo build -q --release -p tr-modes --bin ft8-frontend) || { echo "FAIL: host build"; exit 1; }
# The host tool is built in release mode; on Windows cargo names it ft8-frontend.exe.
tool="fw/target/release/ft8-frontend"
[ -x "$tool.exe" ] && tool="$tool.exe"

# The decode band of 100 to 3,000 Hz as FFT bins (SyncBand::from_hz(100, 3000) in the Rust model).
ia=32; ib=960
fail=0
for w in "${wavs[@]}"; do
    name="$(basename "$w" .wav)"
    dir="sim/ft8/out/f6_$name"   # repo-relative, because the simulator is a native Windows program and cannot open /g/... paths
    mkdir -p "$dir"
    "$tool" sync-vectors "$w" "$dir" "$ia" "$ib" 372 >&2 || { echo "FAIL: vectors $name"; fail=1; continue; }
    vvp_out="$dir/harness.vvp"
    if ! iverilog -g2012 -DSPEC_FILE=\"$dir/spec_lw.hex\" -DOUT_FILE=\"$dir/rtl_records.hex\" \
            -DBAND_IA=$ia -DBAND_IB=$ib -o "$vvp_out" sim/ft8/ft8_sync_wav_harness.v; then
        echo "FAIL: compile"; fail=1; continue
    fi
    echo "== $name: RTL sync search ==" >&2
    out="$(vvp "$vvp_out")"
    echo "$out" | grep -v '^VCD'
    if ! grep -q DONE <<<"$out"; then echo "FAIL: $name harness"; fail=1; continue; fi
    res="$("$tool" sync-check "$w" "$dir/rtl_records.hex")"
    echo "$res"
    grep -q "PASS: sync-check" <<<"$res" || fail=1
done

if [ "$fail" -ne 0 ]; then echo "FAIL: check_ft8_sync.sh"; exit 1; fi
echo "PASS: check_ft8_sync.sh"
