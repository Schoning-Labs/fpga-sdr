#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Runs one FT8 slot of eight decoder receivers through the decode scheduler (tr_modes::frontend::sched) under
# qemu-system-riscv32 -M virt -icount shift=0 (minstret, the method of tools/qemu_s15.sh). The answers of the fabric are replayed
# from traces that `ft8-frontend trace` records on the host (unrationed full ladder, cap off): receiver 0 is the operator's
# (two passes, cap 945 M instructions) and receivers 1 to 7 cycle through qso3_busy, qso1 and qso2 (one pass, cap 315 M). There
# are three runs, one per recording on the operator's receiver. After that a demonstration job with a 120 M cap on qso3_busy
# has to be cut at a candidate boundary.
#
# Checks: every job stays within its cap; every receiver's decodes equal the host's unrationed decodes of the same recording;
# the operator's job is first in the queue; the demonstration job is cut, stays within its cap, and its decodes are a subset of
# the unrationed ones.
#
# Usage: bash tools/qemu_s17.sh   (needs captures/, see tools/fetch_test_audio.sh; S17_JOBS=n QEMU runs at once, default 3).
# The outputs are in fw/target/s17/.
# Needs a Rust toolchain with the riscv32imafc-unknown-none-elf target and qemu-system-riscv32. No Gowin EDA, no board.

set -uo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root/fw"
target=riscv32imafc-unknown-none-elf
out_dir="target/s17"
mkdir -p "$out_dir"
jobs="${S17_JOBS:-3}"
# QEMU from scoop has no shim on PATH for every binary, so fall back to its app folder (the author's install; change the folder if QEMU lives elsewhere).
if ! command -v qemu-system-riscv32 >/dev/null 2>&1 && [ -d "$HOME/scoop/apps/qemu/current" ]; then
    PATH="$HOME/scoop/apps/qemu/current:$PATH"
fi
command -v qemu-system-riscv32 >/dev/null 2>&1 || { echo "qemu_s17.sh: qemu-system-riscv32 not found" >&2; exit 1; }

cargo build -q --release -p tr-modes --bin ft8-frontend >&2 || { echo "qemu_s17.sh: FAIL (host build)" >&2; exit 1; }
host_tool="target/release/ft8-frontend"
# The three recordings; each is the operator's in one run, and each is traced with one and with two passes.
names=(qso3_busy qso1 qso2)
fail=0
# abs PATH prints the absolute path in the native Windows form that `pwd -W` gives under Git Bash, because the build.rs that
# embeds the traces reads these paths as native ones.
abs() { echo "$(cd "$(dirname "$1")" && { pwd -W 2>/dev/null || pwd; })/$(basename "$1")"; }

for n in "${names[@]}"; do
    wav="../captures/ft8/$n.wav"
    [ -f "$wav" ] || { echo "qemu_s17.sh: $wav missing (run tools/fetch_test_audio.sh)" >&2; exit 1; }
    for p in 1 2; do
        "$host_tool" trace "$wav" "$out_dir/${n}_p$p.trace" 60 "$p" full >"$out_dir/${n}_p$p.host" \
            || { echo "qemu_s17.sh: trace failed ($n, $p passes)" >&2; exit 1; }
    done
done

# One target build per choice of the operator's recording; the traces are embedded at build time through S17_TRACES.
for op in "${names[@]}"; do
    list="$(abs "$out_dir/${op}_p2.trace");$(abs "$out_dir/qso3_busy_p1.trace");$(abs "$out_dir/qso1_p1.trace");$(abs "$out_dir/qso2_p1.trace")"
    S17_TRACES="$list" cargo build -q --release --target "$target" -p tr-ft8bench --no-default-features --features board-qemu --bin ft8_sched 2>/dev/null \
        || { echo "qemu_s17.sh: FAIL (target build)" >&2; exit 1; }
    cp "target/$target/release/ft8_sched" "$out_dir/op_$op.elf"
done

# Run the three QEMU instances, up to $jobs at once.
running=0
for op in "${names[@]}"; do
    (timeout 3600 qemu-system-riscv32 -M virt -m 128M -nographic -bios none -icount shift=0 \
        -kernel "$out_dir/op_$op.elf" >"$out_dir/op_$op.out" 2>&1) &
    running=$((running + 1))
    if [ "$running" -ge "$jobs" ]; then
        wait -n
        running=$((running - 1))
    fi
done
wait

# expect NAME lists the host's decodes from a trace log; field NAME LINE reads NAME= from a line of the guest output.
expect() { grep '^EXPECT ' "$out_dir/$1.host" | sed 's/^EXPECT //' | sort; }
field() { sed -E "s/.* $1=([^ ]+).*/\1/" <<<"$2"; }
# One table row per job of each run, as Markdown on stdout; the checks on each row set fail.
printf "| Operator's recording | Receiver | Recording | Queue position | Passes | Cap (M) | Spent (M) | First pass (M) | Decodes | Equal to unrationed | Cut | Next slot's candidates |\n"
printf "|---|---|---|---|---|---|---|---|---|---|---|---|\n"
# Name of the recording behind each trace position of the list given to the builds (position 0 is the operator's own).
trace_name=(op qso3_busy qso1 qso2)
for op in "${names[@]}"; do
    o="$(tr -d '\r' <"$out_dir/op_$op.out")"
    if grep -q PANIC <<<"$o" || ! grep -q "S17 bench done" <<<"$o"; then
        echo "qemu_s17.sh: FAIL run with operator on $op" >&2
        tail -5 <<<"$o" >&2
        fail=1
        continue
    fi
    while read -r line; do
        rx="$(field rx "$line")"; tr_i="$(field trace "$line")"
        passes="$(field passes "$line")"; cap="$(field cap "$line")"; spent="$(field spent "$line")"
        rec="${trace_name[$tr_i]}"; [ "$rec" = op ] && rec="$op"
        exp="$(expect "${rec}_p$passes")"
        got="$(grep "^DECODE rx=$rx " <<<"$o" | sed -E 's/^DECODE rx=[0-9]+ //' | sort)"
        eq=yes
        [ "$exp" = "$got" ] || { eq=NO; fail=1; echo "qemu_s17.sh: FAIL rx $rx ($rec): decodes differ from unrationed" >&2; }
        [ "$spent" -le "$cap" ] || { fail=1; echo "qemu_s17.sh: FAIL rx $rx ($rec): $spent over cap $cap" >&2; }
        if [ "$(field operator "$line")" = 1 ] && [ "$(field order "$line")" != 0 ]; then
            fail=1; echo "qemu_s17.sh: FAIL operator not first" >&2
        fi
        printf "| %s | %s | %s | %s | %s | %.0f | %.1f | %.1f | %s | %s | %s | %s |\n" "$op" "$rx" "$rec" "$(field order "$line")" "$passes" \
            "$(awk "BEGIN{print $cap/1e6}")" "$(awk "BEGIN{print $spent/1e6}")" "$(awk "BEGIN{print $(field first_pass "$line")/1e6}")" \
            "$(field decodes "$line")" "$eq" "$(field cut "$line")" "$(field next_max_cand "$line")"
    done < <(grep '^JOB ' <<<"$o")
    slot="$(grep '^SLOT ' <<<"$o")"
    echo "SLOT (operator on $op): total $(awk "BEGIN{printf \"%.1f\", $(field total "$slot")/1e6}") M of a $(awk "BEGIN{printf \"%.0f\", $(field budget "$slot")/1e6}") M budget" >&2
    demo="$(grep '^DEMO ' <<<"$o")"
    dspent="$(field spent "$demo")"; dcap="$(field cap "$demo")"; dcut="$(field cut "$demo")"
    echo "DEMO (operator run $op): cap $dcap, spent $dspent, cut $dcut, decodes $(field decodes "$demo")" >&2
    [ "$dcut" != none ] && [ "$dspent" -le "$dcap" ] || { fail=1; echo "qemu_s17.sh: FAIL demo job not cut within its cap" >&2; }
    extra="$(comm -13 <(expect qso3_busy_p1) <(grep '^DEMO_DECODE ' <<<"$o" | sed 's/^DEMO_DECODE //' | sort))"
    [ -z "$extra" ] || { fail=1; echo "qemu_s17.sh: FAIL demo decoded something the unrationed run did not: $extra" >&2; }
done
if [ "$fail" -ne 0 ]; then
    echo "qemu_s17.sh: FAILED" >&2
    exit 1
fi
echo "qemu_s17.sh: PASS (every job within its cap, decodes equal the unrationed full ladder's, operator first, demo cut)" >&2
