#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Downloads the speech and modem test files that the FreeDV tests use (docs/FREEDV.md) into the git-ignored folder
# captures/freedv/. From the Codec 2 repository, release 1.2.0 (David Rowe and contributors, LGPL-2.1) come speech samples at
# 8 kHz and a FreeDV 700D modem signal that carries the test frames and was made by the C implementation (its own
# backwards-compatibility test uses the same file). From the FreeDV program's repository (drowe67/freedv-gui, wav/) come the
# sample modem signals it ships: 112 s of the speech ve9qrp.raw sent in 700D, 700E and 1600 by the C implementation's
# transmitter. Files that are already present are skipped, so the script can be run again after a failed download.
#
# Usage: bash tools/fetch_freedv_test.sh
# Needs curl and an internet connection. The tests write listening samples to captures/freedv/out.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="$repo_root/captures/freedv"
base="https://raw.githubusercontent.com/drowe67"

# Each entry is the local file name, a bar, and the path of the file below $base.
files=(
    "hts1a.raw|codec2/1.2.0/raw/hts1a.raw"
    "ve9qrp_10s.raw|codec2/1.2.0/raw/ve9qrp_10s.raw"
    "ve9qrp.raw|codec2/1.2.0/raw/ve9qrp.raw"
    "testframes_700d.raw|codec2/1.2.0/raw/testframes_700d.raw"
    "ve9qrp_700d.wav|freedv-gui/master/wav/ve9qrp_700d.wav"
    "ve9qrp_700e.wav|freedv-gui/master/wav/ve9qrp_700e.wav"
    "ve9qrp_1600.wav|freedv-gui/master/wav/ve9qrp_1600.wav"
)

mkdir -p "$out_dir/out"
fail=0
for entry in "${files[@]}"; do
    rel_out="${entry%%|*}"
    src_path="${entry##*|}"
    dest="$out_dir/$rel_out"
    if [ -s "$dest" ]; then
        echo "skip (already present): $rel_out"
        continue
    fi
    echo "fetching $rel_out <- $base/$src_path"
    if ! curl -fsSL -A "Mozilla/5.0" --max-time 60 -o "$dest.tmp" "$base/$src_path"; then
        echo "FAILED: $rel_out" >&2
        rm -f "$dest.tmp"
        fail=1
        continue
    fi
    mv "$dest.tmp" "$dest"
    echo "  ok, $(wc -c <"$dest" | tr -d ' ') bytes"
done

if [ "$fail" -ne 0 ]; then
    echo "fetch_freedv_test.sh: one or more downloads failed" >&2
    exit 1
fi
echo "fetch_freedv_test.sh: done, files under $out_dir; the tests write listening samples to $out_dir/out"
