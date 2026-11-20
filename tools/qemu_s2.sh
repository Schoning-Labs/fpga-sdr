#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Measures the instructions that the DSP kernels of fw/tr-dsp need. It builds the `dsp_bench` binary of fw/tr-bench (release,
# feature board-qemu, the pattern of tools/qemu_c1.sh) and runs it under `qemu-system-riscv32 -M virt` with `-icount shift=0`,
# so that the guest's `minstret` CSR counts really retired instructions and not the default approximation that QEMU scales from
# wall-clock time. docs/S2_BENCH.md ("measurement method and its limits") has the method: the QEMU build in use here (scoop,
# Windows) has plugin support compiled in but ships no prebuilt TCG plugin library, so `libinsn` is not available, and an
# -icount run that reads a counter CSR is the fallback; on a different QEMU build the plugin may be there.
#
# Two modes:
#   tools/qemu_s2.sh --smoke   is for tools/check.sh: build and run once, confirm that every kernel reported a result (or an
#                              explicit stub note) and that the run completed, with no table. It takes a few seconds.
#   tools/qemu_s2.sh           builds and runs, then turns the RESULT lines into the table of instructions per second and
#                              percent of the core that docs/S2_BENCH.md shows, printed to stdout as Markdown.
#
# CPU-budget constants (docs/ARCHITECTURE.md section 5.5): 800 MHz core clock, and BLOCK = 512 samples per channel-filter block
# (fw/tr-dsp/src/fastconv.rs). The instructions per cycle (IPC) are not measured here, because the QEMU TCG has no pipeline
# model, so the table gives both ends of an assumed range of 0.7 to 1.0, which docs/ARCHITECTURE.md section 5.5 justifies with
# the CoreMark per MHz of cores in the same class as the A25.
#
# Needs a Rust toolchain with the riscv32imafc-unknown-none-elf target, qemu-system-riscv32 and awk. The real FT8 measurement
# (feature bench-ft8) also needs captures/ft8/qso1.wav and qso3_busy.wav (tools/fetch_test_audio.sh). No Gowin EDA, no board.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root/fw"

target=riscv32imafc-unknown-none-elf
bin=dsp_bench
elf="target/$target/release/$bin"
mode="${1:-full}"

# QEMU from scoop has no shim on PATH for every binary, so fall back to its app folder (the author's install; change the folder if QEMU lives elsewhere).
if ! command -v qemu-system-riscv32 >/dev/null 2>&1 && [ -d "$HOME/scoop/apps/qemu/current" ]; then
    PATH="$HOME/scoop/apps/qemu/current:$PATH"
fi
if ! command -v qemu-system-riscv32 >/dev/null 2>&1; then
    echo "qemu_s2.sh: qemu-system-riscv32 not found on PATH" >&2
    echo "  scoop install qemu (open a new shell afterwards)" >&2
    exit 1
fi

# The real FT8 measurement (fw/tr-bench/src/ft8_bench.rs) embeds the two WSJT-X sample recordings at build time (`include_bytes!`,
# since QEMU has no filesystem; see the module doc of that file) and is off by default (feature `bench-ft8`). `--smoke`, which
# tools/check.sh runs, never turns it on, so check.sh does not need `captures/` fetched. The full run turns it on automatically once
# both files exist (fetch them first with `bash tools/fetch_test_audio.sh`) and otherwise falls back to the stub line, with a note
# that says why.
features="board-qemu"
timeout_s=60
if [ "$mode" != "--smoke" ]; then
    if [ -f "$repo_root/captures/ft8/qso1.wav" ] && [ -f "$repo_root/captures/ft8/qso3_busy.wav" ]; then
        features="board-qemu,bench-ft8"
        # FT8 decoding under strict -icount shift=0 (every guest instruction accounted for individually, with no TCG block-chaining
        # fast path) is slow: docs/CPU_BUDGET.md section 9 reports that depth 1 alone took hours under QEMU. The default setting
        # (decode_slot, the WSJT-X depth-3 multi-pass successive-interference-cancellation decode) is the expensive one, and the
        # light setting runs first and is far cheaper (see the ordering in ft8_bench.rs). The timeout is generous but not
        # unbounded: 2 hours.
        timeout_s=7200
    else
        echo "qemu_s2.sh: captures/ft8/{qso1,qso3_busy}.wav not found -- run 'bash tools/fetch_test_audio.sh' first for a real FT8 measurement; falling back to the stub line." >&2
    fi
fi

echo "== building $bin for QEMU, release (--features $features) ==" >&2
if ! cargo build --release --target "$target" -p tr-bench --bin "$bin" \
    --no-default-features --features "$features" >&2; then
    echo "qemu_s2.sh: FAIL (build error)" >&2
    exit 1
fi

echo "== qemu-system-riscv32 -M virt -icount shift=0 (timeout ${timeout_s}s) ==" >&2
# shift=0 credits one virtual "cycle" per instruction to QEMU's own deterministic-time accounting, which is no claim about the
# real core's IPC (see docs/S2_BENCH.md). What it buys here is that minstret (and mcycle, in lock-step with it under shift=0)
# advance by exactly one per retired guest instruction, deterministically, where the default is a free-running approximation of
# those CSRs scaled from wall-clock time.
output="$(timeout "$timeout_s" qemu-system-riscv32 -M virt -m 128M -nographic -bios none \
    -icount shift=0 -kernel "$elf" 2>&1)"
echo "$output" >&2

if grep -q "PANIC" <<<"$output"; then
    echo "qemu_s2.sh: FAIL: guest panicked" >&2
    exit 1
fi
if ! grep -q "S2 bench done" <<<"$output"; then
    echo "qemu_s2.sh: FAIL: run did not reach completion ('S2 bench done' not seen -- with" \
        "bench-ft8 on, this can mean the ${timeout_s}s timeout was too short for the default" \
        "(WSJT-X depth-3) FT8 setting; any RESULT lines already printed are still shown above)" >&2
    exit 1
fi

result_lines="$(grep '^RESULT ' <<<"$output")"
result_count="$(grep -c '^RESULT ' <<<"$output")"
# 18 tr-dsp kernels (filter, AGC, 5 demodulators, NR 48k/12k, AGC 12k, NB x4 rates, resampler x3 ratios, GUI stub) plus FT8:
# 1 stub line normally, or 4 real lines (2 files x {default, light}) once `bench-ft8` has measured it for real, see `run_all`
# in fw/tr-bench/src/lib.rs and fw/tr-bench/src/ft8_bench.rs.
if [[ "$features" == *bench-ft8* ]]; then
    expected_count=22
else
    expected_count=19
fi
if [ "$result_count" -ne "$expected_count" ]; then
    echo "qemu_s2.sh: FAIL: expected $expected_count RESULT lines, got $result_count" >&2
    exit 1
fi

if [ "$mode" = "--smoke" ]; then
    echo "qemu_s2.sh: PASS ($result_count kernel results, run completed cleanly)"
    exit 0
fi

# Full mode turns each RESULT line into the table of docs/S2_BENCH.md. BLOCK is fastconv::BLOCK of fw/tr-dsp, duplicated here
# and not read from the crate because this is a shell script; it is fixed by the CPU-budget design in docs/ARCHITECTURE.md
# section 5.5, and docs/S2_BENCH.md says what to do if it ever changes. The field order is fixed by the `writeln!` in `run_all`
# of fw/tr-bench/src/lib.rs:
#   RESULT <name> measured=<0|1> rate_hz=<f> unit=<blocks|samples> divisor=<u> instr_total=<u> note=<rest of line, may contain spaces>
# The text of `note` (the FT8 and GUI stub explanations) can contain spaces, so it is not parsed as a whitespace-delimited field
# like the rest: it is everything from the literal "note=" onward.
echo "$result_lines" | awk '
BEGIN {
    BLOCK = 512
    CORE_HZ = 800000000
    printf "| Kernel | Rate | Instr/unit | Instructions/s of audio | Mcycles/s @ IPC 0.7 | Mcycles/s @ IPC 1.0 | %% of 800 MHz core @ IPC 0.7 | @ IPC 1.0 |\n"
    printf "|---|---|---|---|---|---|---|---|\n"
}
{
    name = $2
    split($3, a, "="); measured = a[2]
    split($4, b, "="); rate_hz = b[2]
    split($5, c, "="); unit = c[2]
    split($6, d, "="); divisor = d[2]
    split($7, e, "="); instr_total = e[2]
    note = $0
    sub(/^.*note=/, "", note)
    if (measured == "0") {
        printf "| %s | - | - | not measured (%s) | - | - | - | - |\n", name, note
        next
    }
    if (name ~ /^ft8_/) {
        # One whole 15 s slot per RESULT line, not a per-block/
        # per-sample streaming kernel -- the generic BLOCK-based math below
        # does not apply (see fw/tr-bench/src/ft8_bench.rs). Report
        # instructions/slot directly (what docs/CPU_BUDGET.md section 5
        # itself reports FT8 as) plus the derived Mcycles/s *per receiver*
        # this one slot implies (instr_total / 15 s / IPC), matching the
        # "Mcycles/s at IPC 0.7 (X% of the core) per receiver" convention
        # docs/CPU_BUDGET.md section 5 already uses.
        mc07 = instr_total / 15.0 / 0.7 / 1000000
        mc10 = instr_total / 15.0 / 1.0 / 1000000
        pct07 = instr_total / 15.0 / 0.7 / CORE_HZ * 100
        pct10 = instr_total / 15.0 / 1.0 / CORE_HZ * 100
        printf "| %s (%s) | 15 s slot | %.0f instr/slot | - | %.2f | %.2f | %.2f%% | %.2f%% |\n", \
            name, note, instr_total, mc07, mc10, pct07, pct10
        next
    }
    if (unit == "blocks") {
        instr_per_unit = instr_total / divisor
        per_s = instr_per_unit * (rate_hz / BLOCK)
        unit_label = sprintf("%.0f/block", instr_per_unit)
    } else {
        instr_per_unit = instr_total / divisor
        per_s = instr_per_unit * rate_hz
        unit_label = sprintf("%.1f/sample", instr_per_unit)
    }
    mc07 = per_s / 0.7 / 1000000
    mc10 = per_s / 1.0 / 1000000
    pct07 = per_s / 0.7 / CORE_HZ * 100
    pct10 = per_s / 1.0 / CORE_HZ * 100
    printf "| %s | %.0f Hz | %s | %.0f | %.2f | %.2f | %.2f%% | %.2f%% |\n", \
        name, rate_hz, unit_label, per_s, mc07, mc10, pct07, pct10
}
'
