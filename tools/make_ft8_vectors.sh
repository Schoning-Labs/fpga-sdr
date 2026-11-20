#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Makes the seven FT8 testbench vector files in sim/ft8/vectors/ that are values taken from two WSJT-X sample recordings
# (qso1.wav and qso3_busy.wav, GPL-3.0-or-later, from the samples/ tree of WSJT-X). The files are not committed, because a
# vector file holds samples of the recording itself or the fixed-point model's output for it. They are made here from the
# recordings that tools/fetch_test_audio.sh downloads into captures/ft8/.
#
# What is made, and how (all with the host tool ft8-frontend of fw/tr-modes, the bit-true Rust model of the FT8 front end):
#   qso1_small_audio.hex, qso3_busy_small_audio.hex   the first 3,840 samples of the recording, one 16 bit sample per line
#   qso1_small_power.hex, qso3_busy_small_power.hex   the first 5 x 1,024 power words of the model's spectrogram (`vectors`)
#   f6_qso1_spec_lw.hex                               lane words 200 to 221 of all 372 spectrogram rows of qso1 (`sync-vectors`)
#   f6_qso1_sync295.hex, f6_qso1_sync372.hex          the model's sync records for bins 401 to 431 over the first 295 and
#                                                     the first 372 rows of qso1 (`sync-vectors`)
# The testbenches tb_ft8_frame_core.v, tb_ft8_spectrogram.v and tb_ft8_sync.v read these files; tools/check.sh runs this script
# before them and skips a testbench whose vectors are missing.
#
# Usage: bash tools/fetch_test_audio.sh && bash tools/make_ft8_vectors.sh
# Needs cargo (it builds ft8-frontend in release mode, which takes a few minutes the first time).

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

for name in qso1 qso3_busy; do
    if [ ! -f "captures/ft8/$name.wav" ]; then
        echo "captures/ft8/$name.wav not found; run 'bash tools/fetch_test_audio.sh' first" >&2
        exit 1
    fi
done

vec_dir="sim/ft8/vectors"
work="sim/ft8/out/make_vectors"
mkdir -p "$vec_dir" "$work"

# The tool runs from fw/ and the paths are given relative to it, because a native Windows program cannot open MSYS style
# /g/... paths.
frontend() { (cd fw && cargo run -q --release -p tr-modes --bin ft8-frontend -- "$@" >/dev/null); }

for name in qso1 qso3_busy; do
    frontend vectors "../captures/ft8/$name.wav" "../$work/$name"
    head -n 3840 "$work/$name/audio.hex" > "$vec_dir/${name}_small_audio.hex"
    head -n 5120 "$work/$name/spectrogram_sh16.hex" > "$vec_dir/${name}_small_power.hex"
done

# The spectrogram rows are the same in both runs, only the number of rows the sync search covers differs.
for rows in 295 372; do
    frontend sync-vectors ../captures/ft8/qso1.wav "../$work/sync$rows" 401 431 "$rows" 200 221
    cp "$work/sync$rows/sync_expect.hex" "$vec_dir/f6_qso1_sync$rows.hex"
done
cp "$work/sync372/spec_lw.hex" "$vec_dir/f6_qso1_spec_lw.hex"

rm -rf "$work"
echo "wrote the FT8 vectors from the WSJT-X recordings into $vec_dir"
