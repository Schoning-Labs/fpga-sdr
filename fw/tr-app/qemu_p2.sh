#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Builds the FT8 firmware twice and checks the whole program end to end under QEMU: `ft8fw` (release) is the image for the
# Tang board, and its twin `ft8fw_qemu` (release, feature board-qemu) is the same program built for the virt machine of
# qemu-system-riscv32. The script prints the size of the board image and then runs the twin under
# `qemu-system-riscv32 -M virt`, where the screen is rendered, TX is enabled and CQ is clicked, the CQ is sent through the TX
# ring of a simulated fabric, looped back into the receiver's audio ring and decoded. The instruction count of the waterfall
# line generator is read from the `minstret` counter, which is why QEMU runs with `-icount shift=0` (see tools/qemu_s2.sh).
# The test passes when the output contains "P2 QEMU PASS". The design is in docs/P2_FT8_FW.md.
#
# Run it from anywhere (it changes into fw/ itself) and expect a few minutes, so start it in the background. The QEMU output
# is also kept in fw/target/p2/qemu.out.
#
# Needs a Rust toolchain with the riscv32imafc-unknown-none-elf target and qemu-system-riscv32 on PATH. It does not use
# Gowin EDA or the board.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
target=riscv32imafc-unknown-none-elf
out=target/p2
mkdir -p "$out"

# QEMU from scoop has no shim on PATH for every binary, so fall back to its app folder (the author's install; change the folder if QEMU lives elsewhere).
if ! command -v qemu-system-riscv32 >/dev/null 2>&1 && [ -d "$HOME/scoop/apps/qemu/current" ]; then
    PATH="$HOME/scoop/apps/qemu/current:$PATH"
fi
command -v qemu-system-riscv32 >/dev/null 2>&1 || { echo "qemu_p2.sh: qemu-system-riscv32 not found" >&2; exit 1; }

# First build: the image for the board. The build log goes to $out/build_board.log and its last lines are shown on a failure.
echo "== board image (ft8fw, release) =="
cargo build -q --release --target "$target" -p tr-app --bin ft8fw 2>"$out/build_board.log" \
    || { tail -30 "$out/build_board.log" >&2; echo "qemu_p2.sh: FAIL (board image build)" >&2; exit 1; }
ls -l "target/$target/release/ft8fw" | awk '{print "ft8fw ELF " $5 " bytes"}'

# Second build: the same program for QEMU, without the board features.
echo "== QEMU twin (ft8fw_qemu, release) =="
cargo build -q --release --target "$target" -p tr-app --bin ft8fw_qemu --no-default-features --features board-qemu 2>"$out/build_qemu.log" \
    || { tail -30 "$out/build_qemu.log" >&2; echo "qemu_p2.sh: FAIL (QEMU build)" >&2; exit 1; }

# The run is given 30 minutes at most; the program ends QEMU itself when it is done.
echo "== qemu-system-riscv32 -M virt -m 128M -icount shift=0 =="
timeout 1800 qemu-system-riscv32 -M virt -m 128M -icount shift=0 -nographic -bios none \
    -kernel "target/$target/release/ft8fw_qemu" >"$out/qemu.out" 2>&1
tr -d '\r' <"$out/qemu.out"
if grep -q "P2 QEMU PASS" "$out/qemu.out"; then
    echo "qemu_p2.sh: PASS"
else
    echo "qemu_p2.sh: FAIL" >&2
    exit 1
fi
