#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Downloads the WSJT-X sample recordings that the golden decode tests of tr-modes use into the git-ignored folder captures/
# (see .gitignore). They are not committed.
#
# The WSJT project (Joe Taylor K1JT and collaborators, GPL-3.0-or-later) ships these recordings in the samples/ tree of WSJT-X,
# but that tree cannot be downloaded without the full WSJT-X source tarball. The mfsk-core project (also GPL-3.0-or-later)
# keeps verbatim copies of the same recordings in its GitHub repository, for its own WSJT-X-golden test suite
# (mfsk-core/tests/*_wsjtx_samples.rs and mfsk-core/tests/ft8_qso3_*.rs), and this script pulls them from there.
# docs/S5_MODES.md, section "test audio", says which WSJT-X samples/ path each file corresponds to and lists the golden
# decodes that the tests check against. Files that are already present are skipped.
#
# Usage: bash tools/fetch_test_audio.sh
# Needs curl and an internet connection.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out_dir="$repo_root/captures"

base="https://raw.githubusercontent.com/jl1nie/mfsk-core/main"

# rel_out_path | source URL path (relative to $base)
files=(
    "ft8/qso1.wav|embedded-poc/assets/qso1.wav"
    "ft8/qso2.wav|embedded-poc/assets/qso2.wav"
    "ft8/qso3_busy.wav|embedded-poc/assets/qso3_busy.wav"
    "ft4/000000_000002.wav|embedded-poc/assets/golden/ft4/000000_000002.wav"
    "wspr/150426_0918.wav|embedded-poc/assets/golden/wspr/150426_0918.wav"
)

fail=0
for entry in "${files[@]}"; do
    rel_out="${entry%%|*}"
    src_path="${entry##*|}"
    dest="$out_dir/$rel_out"
    mkdir -p "$(dirname "$dest")"
    if [ -s "$dest" ]; then
        echo "skip (already present): $rel_out"
        continue
    fi
    url="$base/$src_path"
    echo "fetching $rel_out <- $url"
    if ! curl -fsSL -A "Mozilla/5.0" --max-time 60 -o "$dest.tmp" "$url"; then
        echo "FAILED: $rel_out" >&2
        rm -f "$dest.tmp"
        fail=1
        continue
    fi
    mv "$dest.tmp" "$dest"
    size="$(wc -c <"$dest" | tr -d ' ')"
    echo "  ok, $size bytes"
done

if [ "$fail" -ne 0 ]; then
    echo "fetch_test_audio.sh: one or more downloads failed" >&2
    exit 1
fi

echo "fetch_test_audio.sh: done, files under $out_dir"
