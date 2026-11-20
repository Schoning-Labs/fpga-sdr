#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Smoke test of the AE350 support crate (fw/tr-ae350, docs/C1_AE350.md) under QEMU. It builds the `qemu_smoke` binary of
# fw/tr-app for `qemu-system-riscv32 -M virt` (feature board-qemu, see fw/tr-ae350/src/board.rs) and checks that it prints
# "hello ok" (UART output), "timer ok" (a real machine-timer interrupt fired) and "trap ok" (a deliberately illegal instruction
# was caught). The binary shuts QEMU down itself once it has printed all three (board::qemu::exit_pass(), through the QEMU
# "SiFive test finisher" device), and the `timeout` below is only a safety net for a QEMU version where that write does not
# behave as expected.
#
# Only the parts of tr-ae350 that do not depend on the real chip run here: UART framing, PLIC register writes, the machine-timer
# compare and the FPU enable. The CCTL cache operations exist on the AE350 only and cannot run under QEMU (the module doc of
# fw/tr-ae350/src/cctl.rs says so).
#
# Needs a Rust toolchain with the riscv32imafc-unknown-none-elf target and qemu-system-riscv32 (docs/TOOLCHAIN.md). No Gowin
# EDA, no board.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root/fw"

target=riscv32imafc-unknown-none-elf
bin=qemu_smoke
elf="target/$target/debug/$bin"

# QEMU from scoop has no shim on PATH for every binary, so fall back to its app folder (the author's install; change the folder if QEMU lives elsewhere).
if ! command -v qemu-system-riscv32 >/dev/null 2>&1 && [ -d "$HOME/scoop/apps/qemu/current" ]; then
    PATH="$HOME/scoop/apps/qemu/current:$PATH"
fi
if ! command -v qemu-system-riscv32 >/dev/null 2>&1; then
    echo "qemu_c1.sh: qemu-system-riscv32 not found on PATH" >&2
    echo "  scoop install qemu (open a new shell afterwards)" >&2
    exit 1
fi

echo "== building $bin for QEMU (--features board-qemu) =="
if ! cargo build --target "$target" -p tr-app --bin "$bin" --no-default-features --features board-qemu; then
    echo "qemu_c1.sh: FAIL (build error)" >&2
    exit 1
fi

echo "== qemu-system-riscv32 -M virt =="
output="$(timeout 20 qemu-system-riscv32 -M virt -m 128M -nographic -bios none -kernel "$elf" 2>&1)"
echo "$output"

fail=0
for expect in "hello ok" "timer ok" "trap ok"; do
    if ! grep -q "$expect" <<<"$output"; then
        echo "qemu_c1.sh: FAIL missing '$expect' in QEMU output" >&2
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "qemu_c1.sh: FAILED" >&2
    exit 1
fi

echo "qemu_c1.sh: PASS (hello over UART, a real machine-timer interrupt, and an illegal-instruction trap all confirmed under QEMU)"
