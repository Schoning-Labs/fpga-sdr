#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Fails when the firmware ELF contains an atomic read-modify-write instruction (amo*.w, lr.w or sc.w). One of them stopped the
# AE350's processor on the board, so the firmware has to be built without any.
# Prints the number of atomic instructions found and exits non-zero unless it is 0.
#
# Usage: tools/check_no_amo.sh [elf]   (default fw/target/riscv32imafc-unknown-none-elf/release/ft8fw)
#
# Needs the objdump of an xPack RISC-V GCC, which the script finds with the glob /c/tools/xpack-riscv-none-elf-gcc-*/bin on the
# line that sets od; that is the author's install folder, so change the glob there when the toolchain is somewhere else.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
elf="${1:-$repo_root/fw/target/riscv32imafc-unknown-none-elf/release/ft8fw}"
od="$(ls /c/tools/xpack-riscv-none-elf-gcc-*/bin/riscv-none-elf-objdump* | head -1)"
# Count the disassembled lines with an atomic mnemonic; `|| true` stops `set -e` from ending the script when the count is 0.
n=$("$od" -d "$elf" | grep -c -E "[[:space:]](amo[a-z]+\.w|lr\.w|sc\.w)" || true)
echo "$elf: $n atomic instructions"
[ "$n" -eq 0 ]
