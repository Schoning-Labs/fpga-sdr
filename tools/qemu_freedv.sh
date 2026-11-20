#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Builds the FreeDV receive benchmark (fw/tr-freedvbench, binary freedv_bench) for QEMU and runs it with instruction counting
# (the method of tools/qemu_s2.sh: -icount shift=0 and the minstret counter). It prints one RESULT line per mode and case, six
# in all, and docs/FREEDV.md section 6 has the table made from them. The script fails when the guest panics, when it does not
# print "FreeDV bench done", or when the number of RESULT lines is not 6.
#
# Usage: bash tools/qemu_freedv.sh
# Needs a Rust toolchain with the riscv32imafc-unknown-none-elf target and qemu-system-riscv32. No Gowin EDA, no board.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root/fw"

target=riscv32imafc-unknown-none-elf
elf="target/$target/release/freedv_bench"

# QEMU from scoop has no shim on PATH for every binary, so fall back to its app folder (the author's install; change the folder if QEMU lives elsewhere).
if ! command -v qemu-system-riscv32 >/dev/null 2>&1 && [ -d "$HOME/scoop/apps/qemu/current" ]; then
    PATH="$HOME/scoop/apps/qemu/current:$PATH"
fi
if ! command -v qemu-system-riscv32 >/dev/null 2>&1; then
    echo "qemu_freedv.sh: qemu-system-riscv32 not found on PATH" >&2
    exit 1
fi

if ! cargo build --release --target "$target" -p tr-freedvbench --bin freedv_bench \
    --no-default-features --features board-qemu >&2; then
    echo "qemu_freedv.sh: FAIL (build error)" >&2
    exit 1
fi

output="$(timeout 1800 qemu-system-riscv32 -M virt -m 128M -nographic -bios none \
    -icount shift=0 -kernel "$elf" 2>&1)"
echo "$output"

if grep -q "PANIC" <<<"$output"; then
    echo "qemu_freedv.sh: FAIL: guest panicked" >&2
    exit 1
fi
if ! grep -q "FreeDV bench done" <<<"$output"; then
    echo "qemu_freedv.sh: FAIL: run did not finish" >&2
    exit 1
fi
count="$(grep -c '^RESULT ' <<<"$output")"
if [ "$count" -ne 6 ]; then
    echo "qemu_freedv.sh: FAIL: expected 6 RESULT lines, got $count" >&2
    exit 1
fi
echo "qemu_freedv.sh: PASS"
