#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Full-frame check of the HDMI video and audio path: runs tools/video/tb_hdmi_video_full.v for one whole frame in each of the
# three video modes (1920x1080 at 60 Hz, 1920x1080 at 30 Hz and the 1280x720 at 60 Hz fallback), checking every active pixel
# exactly against the color-bar generator and every steady-state Audio Sample Packet against the 1 kHz test tone. It is not run
# by tools/check.sh, because a full 1080p60 frame is about 2.5 million pixel clocks, which is too slow for the quick pass
# (sim/video/tb_hdmi_video.v runs 100 lines of the 720p60 mode instead, see docs/V1_VIDEO.md, "How to run"). Run it by hand
# after any change to the video or audio RTL, and before a release.
#
# Needs iverilog and vvp on PATH (oss-cad-suite). Prints PASS or FAIL per mode and exits non-zero if any mode fails. No Gowin
# EDA, no board.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if ! command -v iverilog >/dev/null 2>&1; then
    echo "iverilog not found on PATH (expected from oss-cad-suite)" >&2
    exit 1
fi

fail=0

# One compile and run per mode; the mode is chosen by the define of the same name in the testbench.
for mode in MODE_1080P60 MODE_1080P30 MODE_720P60; do
    echo "== $mode =="
    out="tools/video/obj_full_$mode.vvp"
    if ! iverilog -g2012 -D"$mode" -o "$out" tools/video/tb_hdmi_video_full.v; then
        echo "FAIL: $mode (compile error)"
        fail=1
        continue
    fi
    output="$(vvp "$out")"
    status=$?
    # Leave out the simulator's warnings about unique and priority case statements and constant selects, which only hide the result.
    echo "$output" | grep -v "priority or unique case\|Scope:\|value is unhandled\|sorry: constant selects\|always_comb process\|unique/unique0"
    rm -f "$out"
    if [ "$status" -ne 0 ] || ! grep -q "PASS" <<<"$output"; then
        echo "FAIL: $mode"
        fail=1
    else
        echo "PASS: $mode"
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "run_v1_video_full.sh: FAILED"
    exit 1
fi

echo "run_v1_video_full.sh: all modes passed"
