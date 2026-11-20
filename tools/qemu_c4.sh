#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Checks under QEMU that floating-point state survives interrupts and exceptions in the AE350 firmware. It builds the `qemu_c4`
# binary of fw/tr-app for `qemu-system-riscv32 -M virt` (feature board-qemu, the same pattern as tools/qemu_c1.sh) and checks
# that it prints:
#   - "bitidentical ok": an f64 chaotic-map loop in the main task, run once with no traps at all and once with a real
#     machine-timer interrupt firing dozens of times during it, gave bit-for-bit identical results both times.
#   - "exceptionbitidentical ok": the same loop again, this time with a real Breakpoint exception (not an interrupt) firing
#     dozens of times during it, again bit for bit identical, which shows that the FS save and restore of the trap entry covers
#     the synchronous-exception path as well as interrupts.
#   - "guard ok": a handler that deliberately tries to use the FPU was caught (it trapped as an illegal instruction) and did
#     not corrupt the interrupted task's FP registers, with no opt-in code in the handler: the trap entry itself forces FS off.
# The design is in fw/tr-app/src/bin/qemu_c4.rs, and fw/tr-ae350/src/trap.rs and docs/C1_AE350.md say why this firmware forbids
# FP use in interrupt handlers (enforced at the trap entry) and does not save and restore the FP registers there instead.
#
# Needs a Rust toolchain with the riscv32imafc-unknown-none-elf target and qemu-system-riscv32 (docs/TOOLCHAIN.md). No Gowin
# EDA, no board.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root/fw"

target=riscv32imafc-unknown-none-elf
bin=qemu_c4
elf="target/$target/debug/$bin"

# QEMU from scoop has no shim on PATH for every binary, so fall back to its app folder (the author's install; change the folder if QEMU lives elsewhere).
if ! command -v qemu-system-riscv32 >/dev/null 2>&1 && [ -d "$HOME/scoop/apps/qemu/current" ]; then
    PATH="$HOME/scoop/apps/qemu/current:$PATH"
fi
if ! command -v qemu-system-riscv32 >/dev/null 2>&1; then
    echo "qemu_c4.sh: qemu-system-riscv32 not found on PATH" >&2
    echo "  scoop install qemu (open a new shell afterwards)" >&2
    exit 1
fi

echo "== building $bin for QEMU (--features board-qemu) =="
if ! cargo build --target "$target" -p tr-app --bin "$bin" --no-default-features --features board-qemu; then
    echo "qemu_c4.sh: FAIL (build error)" >&2
    exit 1
fi

echo "== qemu-system-riscv32 -M virt =="
output="$(timeout 20 qemu-system-riscv32 -M virt -m 128M -nographic -bios none -kernel "$elf" 2>&1)"
echo "$output"

fail=0
for expect in "hello ok" "baseline ok" "with_interrupts ok" "bitidentical ok" \
    "with_exceptions ok" "exceptionbitidentical ok" "guard ok"; do
    if ! grep -q "$expect" <<<"$output"; then
        echo "qemu_c4.sh: FAIL missing '$expect' in QEMU output" >&2
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "qemu_c4.sh: FAILED" >&2
    exit 1
fi

echo "qemu_c4.sh: PASS (interrupts and exceptions firing during an FP loop both left it bit-identical to a run without them; FP use in a handler was caught automatically)"
