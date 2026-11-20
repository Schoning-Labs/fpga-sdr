#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Counts the instructions retired by the CPU half of the FT8 decoder (candidate list, fine sync, LLR/BP/OSD/CRC/unpack,
# subtraction and the second pass, that is everything the FPGA front end of rtl/ft8 does not do) under
# qemu-system-riscv32 -M virt -icount shift=0 (the same method as tools/qemu_s2.sh, docs/S2_BENCH.md).
#
# For each recording and setting, the host tool `ft8-frontend trace` runs the fixed-point model (docs/S15_FT8MODEL.md) and
# records every answer the fabric gives the CPU; fw/tr-ft8bench embeds that trace, replays it to the unchanged CPU code in the
# target build and prints minstret per stage. The decodes on the target must equal the host's, which this script checks.
#
# Usage: bash tools/qemu_s15.sh [wav names...]   (default: qso3_busy qso1 qso2; needs captures/, see tools/fetch_test_audio.sh).
#        It takes about a minute per run, with eight settings per recording. The QEMU output of every run (with per-candidate
#        CAND lines) stays in fw/target/s15/<tag>.out.
#        bash tools/qemu_s15.sh --smoke   is one quick run on qso3_busy, as tools/check.sh runs it, and it skips without
#        failing when captures/ has not been fetched.
#
# Needs a Rust toolchain with the riscv32imafc-unknown-none-elf target and qemu-system-riscv32. No Gowin EDA, no board.

set -uo pipefail

# --smoke runs the script again on qso3_busy alone, with the one cheapest setting.
if [ "${1:-}" = "--smoke" ]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    if [ ! -f "$root/captures/ft8/qso3_busy.wav" ]; then
        echo "SKIPPED qemu_s15.sh --smoke: captures/ft8/qso3_busy.wav not fetched; skipping (tools/fetch_test_audio.sh)"
        exit 0
    fi
    S15_SETTINGS="30,1,0,all" exec bash "${BASH_SOURCE[0]}" qso3_busy
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root/fw"

target=riscv32imafc-unknown-none-elf
elf="target/$target/release/ft8_bench"
out_dir="target/s15"
mkdir -p "$out_dir"

# QEMU from scoop has no shim on PATH for every binary, so fall back to its app folder (the author's install; change the folder if QEMU lives elsewhere).
if ! command -v qemu-system-riscv32 >/dev/null 2>&1 && [ -d "$HOME/scoop/apps/qemu/current" ]; then
    PATH="$HOME/scoop/apps/qemu/current:$PATH"
fi
command -v qemu-system-riscv32 >/dev/null 2>&1 || { echo "qemu_s15.sh: qemu-system-riscv32 not found" >&2; exit 1; }

# Settings: max_cand,passes,osd,osd_max (osd 0 = no OSD, 1 = the full ladder of mfsk-core; osd_max "all" = no cap on OSD
# attempts), or max_cand:passes:effort:osd_max with an effort spec of tr_modes::frontend::effort (for example
# "60:1:osd=d,seeds=2,npre2=0,cq=bp:all"). Override with, for example, S15_SETTINGS="30,1,1,all 60,2,1,2". S15_JOBS=n runs n
# QEMU instances at once (default 1).
settings="${S15_SETTINGS:-30,1,1,all 30,1,0,all 60,1,1,all 60,1,0,all 60,1,1,2 60,1,1,4 30,2,1,2 60,2,1,2}"
jobs="${S15_JOBS:-1}"
names=("$@")
[ ${#names[@]} -eq 0 ] && names=(qso3_busy qso1 qso2)

echo "== building ft8-frontend (host) ==" >&2
cargo build -q --release -p tr-modes --bin ft8-frontend >&2 || { echo "qemu_s15.sh: FAIL (host build)" >&2; exit 1; }
host_tool="target/release/ft8-frontend"

fail=0
runs=()
# Phase 1: record each trace and build its target binary (sequential: one cargo target dir).
for name in "${names[@]}"; do
    wav="../captures/ft8/$name.wav"
    [ -f "$wav" ] || { echo "qemu_s15.sh: $wav missing (run tools/fetch_test_audio.sh)" >&2; fail=1; continue; }
    for setting in $settings; do
        if [[ "$setting" == *:* ]]; then
            IFS=: read -r mc passes effort omax <<<"$setting"
        else
            IFS=, read -r mc passes effort omax <<<"$setting"
        fi
        omax_arg="$omax"
        [ "$omax" = all ] && omax_arg=18446744073709551615
        tag="${name}_c${mc}_p${passes}_$(tr ',=' '_-' <<<"$effort")_m${omax}"
        tr="$out_dir/$tag.trace"
        if ! "$host_tool" trace "$wav" "$tr" "$mc" "$passes" "$effort" "$omax_arg" >"$out_dir/$tag.host"; then
            echo "qemu_s15.sh: trace failed ($tag)" >&2
            fail=1
            continue
        fi
        if ! S15_TRACE="$(cd "$(dirname "$tr")" && pwd)/$(basename "$tr")" \
            cargo build -q --release --target "$target" -p tr-ft8bench --no-default-features --features board-qemu 2>/dev/null; then
            echo "qemu_s15.sh: FAIL (target build)" >&2
            fail=1
            continue
        fi
        cp "$elf" "$out_dir/$tag.elf"
        runs+=("$name|$mc|$passes|$effort|$omax|$tag")
    done
done

# Phase 2: run QEMU, up to $jobs at once.
running=0
for run in "${runs[@]}"; do
    tag="${run##*|}"
    (timeout 1800 qemu-system-riscv32 -M virt -m 128M -nographic -bios none \
        -icount shift=0 -kernel "$out_dir/$tag.elf" >"$out_dir/$tag.out" 2>&1) &
    running=$((running + 1))
    if [ "$running" -ge "$jobs" ]; then
        wait -n
        running=$((running - 1))
    fi
done
wait

# Phase 3: check and tabulate.
printf "| Recording | Candidates | Passes | Effort | OSD attempts | Decodes | Total instr | Candidate list | Fine sync | LDPC/OSD/unpack | of which BP / OSD / a-priori | Subtraction | Reading fabric words | Nsync-pass cands | OSD searches (a-priori) |\n"
printf "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
for run in "${runs[@]}"; do
    IFS='|' read -r name mc passes effort omax tag <<<"$run"
    output="$(tr -d '\r' <"$out_dir/$tag.out")"
    if grep -q PANIC <<<"$output" || ! grep -q "S15 bench done" <<<"$output"; then
        echo "qemu_s15.sh: FAIL $tag" >&2
        echo "$output" | tail -5 >&2
        fail=1
        continue
    fi
    exp="$(grep '^EXPECT ' "$out_dir/$tag.host" | sed 's/^EXPECT //' | sort)"
    got="$(grep '^DECODE ' <<<"$output" | sed -E 's/^DECODE pass [0-9] [^ ]+ Hz [^ ]+ s //' | sort)"
    if [ "$exp" != "$got" ]; then
        echo "qemu_s15.sh: FAIL $tag: target decodes differ from host" >&2
        diff <(echo "$exp") <(echo "$got") >&2
        fail=1
    fi
    r="$(grep '^RESULT ' <<<"$output")"
    l="$(grep '^LADDER ' <<<"$output")"
    # val NAME and lval NAME read the value of NAME= from this run's RESULT line and LADDER line.
    val() { sed -E "s/.* $1=([^ ]+).*/\1/" <<<"$r"; }
    lval() { sed -E "s/.* $1=([^ ]+).*/\1/" <<<"$l"; }
    printf "| %s | %s | %s | %s | %s | %s | %'d | %'d | %'d | %'d | %'d / %'d / %'d | %'d | %'d | %s | %s (%s) |\n" "$name" "$mc" "$passes" "$effort" "$omax" \
        "$(val decodes)" "$(val total)" "$(val candidates)" "$(val fine_sync)" "$(val ldpc)" \
        "$(lval i_bp)" "$(lval i_osd)" "$(lval i_ap)" "$(val subtract)" \
        "$(val fabric_words)" "$(val nsync_pass)" "$(lval osd_searches)" "$(lval ap_osd_searches)"
done
if [ "$fail" -ne 0 ]; then
    echo "qemu_s15.sh: FAILED" >&2
    exit 1
fi
echo "qemu_s15.sh: PASS (target decodes equal the host's for every run)" >&2
