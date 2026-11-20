#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Counts the instructions retired by each FT8 back-end kernel on its own (LLRs, min-sum and sum-product belief propagation, OSD
# seeds, and each OSD search in mfsk-core's reference form and in the bit-packed form of fw/vendor/VENDOR_PATCH.md), under
# qemu-system-riscv32 -M virt -icount shift=0 (the method of tools/qemu_s2.sh, docs/S2_BENCH.md), on candidates that belief
# propagation cannot decode. The binary checks every packed result against the reference. It also measures the rewritten LLR
# and fused min-sum kernels (f32 and Q11) next to the ones they replace, each checked equal, and prints the per-failed-candidate
# sums on the PER_FAILED_CANDIDATE line (docs/FT8_CPU.md section 3.1).
#
# Usage: bash tools/qemu_fo1_kernels.sh   (about five minutes)
# Needs a Rust toolchain with the riscv32imafc-unknown-none-elf target and qemu-system-riscv32. No Gowin EDA, no board.

set -uo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root/fw"
target=riscv32imafc-unknown-none-elf
# QEMU from scoop has no shim on PATH for every binary, so fall back to its app folder (the author's install; change the folder if QEMU lives elsewhere).
if ! command -v qemu-system-riscv32 >/dev/null 2>&1 && [ -d "$HOME/scoop/apps/qemu/current" ]; then
    PATH="$HOME/scoop/apps/qemu/current:$PATH"
fi
command -v qemu-system-riscv32 >/dev/null 2>&1 || { echo "qemu_fo1_kernels.sh: qemu-system-riscv32 not found" >&2; exit 1; }
cargo build -q --release --target "$target" -p tr-ft8bench --no-default-features --features board-qemu --bin ft8_kernels 2>/dev/null \
    || { echo "qemu_fo1_kernels.sh: FAIL (target build)" >&2; exit 1; }
output="$(timeout 3600 qemu-system-riscv32 -M virt -m 128M -nographic -bios none -icount shift=0 \
    -kernel "target/$target/release/ft8_kernels" 2>&1 | tr -d '\r')"
echo "$output"
if grep -q PANIC <<<"$output" || ! grep -q "FO1 kernels done" <<<"$output"; then
    echo "qemu_fo1_kernels.sh: FAIL" >&2
    exit 1
fi
echo "qemu_fo1_kernels.sh: PASS (packed OSD equals the reference on every input)" >&2
