#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Builds the start-up program of the ladder (fw/tr-ladder, docs/LADDER.md), makes the flat file for the Gowin programmer from it,
# and prints (or runs) the two programmer commands of a ladder step. The crate is fw/tr-ladder and the bitstreams come from gowin/ladder/build.sh.
#
#   tools/ladder_fw.sh build              fw/target/ladder/tr-ladder.bin  (LADDER_UCLK_HZ=<Hz> keeps one UART clock guess)
#   tools/ladder_fw.sh write <step>       print the two programmer commands for ladder step <step>
#   tools/ladder_fw.sh write <step> --go  run them (this writes the board's flash through the debug cable)
#   tools/ladder_fw.sh chip               builds the full-chip firmware: stage-0 loader (fw/target/ladder/stage0.bin), the
#                                         FT8/FreeDV image ft8fw (fw/target/ladder/ft8fw.img, packed for the loader) and the
#                                         PC sender (fw/target/release/tr-loader-send)
#   tools/ladder_fw.sh write-chip [--go]  prints (or runs) the two programmer commands of the full chip: its bitstream
#                                         (BITSTREAM=<sdr_top.fs>, required) at flash offset 0 and stage-0 at 0x600000;
#                                         then prints the sender command that puts ft8fw into flash slot A/B (COM port: SERIAL=COMn)
# Flash layout (docs/C2_LOADER.md): bitstream at chip offset 0x000000, program at 0x600000.
# BITSTREAM=<file.fs> chooses the bitstream (default: gowin/impl/ladder<step>/ladder_top/impl/pnr/ladder_top.fs),
# FW=<file.bin> the program, DEVICE the programmer's device name (GW5AST-138C; try GW5AST-138B if the programmer
# refuses: the bitstream header says device version C, Sipeed's examples say B).
#
# Needs a Rust toolchain with the riscv32imafc-unknown-none-elf target, the objcopy of an xPack RISC-V GCC (found with the glob
# /c/tools/xpack-riscv-none-elf-gcc-*/bin on the OBJCOPY line), Gowin's programmer_cli.exe (the PROG lines name the author's
# install C:/tools/gowin-programmer, edit them for yours) and cygpath from Git Bash. The write commands go to Gowin's programmer
# directly and not through a board loader tool; run.bat (tools/radio_start.py) is the way that uses
# such a tool (set by RADIO_BOARD_TOOL), and it loads the SRAM only.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The objcopy of the xPack RISC-V GCC turns the firmware ELF into the flat binary file the programmer writes.
OBJCOPY="$(ls /c/tools/xpack-riscv-none-elf-gcc-*/bin/riscv-none-elf-objcopy* 2>/dev/null | head -1)"
# One sub-command per branch, named in the usage lines above.
case "${1:-}" in
# build: the ladder program as a flat file, which has to fit the 1 MB flash window.
build)
    [ -n "$OBJCOPY" ] || { echo "riscv-none-elf-objcopy not found under /c/tools/xpack-riscv-none-elf-gcc-*" >&2; exit 1; }
    cd "$repo_root/fw"
    cargo build --release --target riscv32imafc-unknown-none-elf -p tr-ladder --bin tr-ladder
    mkdir -p target/ladder
    elf="${CARGO_TARGET_DIR:-target}/riscv32imafc-unknown-none-elf/release/tr-ladder"
    "$OBJCOPY" -O binary "$elf" target/ladder/tr-ladder.bin
    sz=$(stat -c %s target/ladder/tr-ladder.bin)
    [ "$sz" -le 1048576 ] || { echo "tr-ladder.bin is $sz bytes: a section is outside the 1 MB flash window" >&2; exit 1; }
    ls -l target/ladder/tr-ladder.bin
    ;;
# write: print (or with --go run) the bitstream and program commands of one ladder step.
write)
    step="${2:?usage: tools/ladder_fw.sh write <1|2|3> [--go]}"
    # The programmer of the author's Gowin programmer install; change the path to your own programmer_cli.exe.
    PROG="C:/tools/gowin-programmer/bin/programmer_cli.exe"
    DEVICE="${DEVICE:-GW5AST-138C}"
    BITSTREAM="${BITSTREAM:-$(cygpath -m "$repo_root")/gowin/impl/ladder${step}/ladder_top/impl/pnr/ladder_top.fs}"
    FW="${FW:-$(cygpath -m "$repo_root")/fw/target/ladder/tr-ladder.bin}"
    c1=("$PROG" --device "$DEVICE" --run 54 --fsFile "$BITSTREAM" --spiaddr 0x000000)
    c2=("$PROG" --device "$DEVICE" --run 56 --mcuFile "$FW" --spiaddr 0x600000)
    echo "1. bitstream of ladder step $step (flash offset 0):"; printf ' %q' "${c1[@]}"; echo
    echo "2. ladder program (flash offset 0x600000):"; printf ' %q' "${c2[@]}"; echo
    if [ "${3:-}" != "--go" ]; then echo "Not written. Add --go to execute both."; exit 0; fi
    [ -f "$BITSTREAM" ] || { echo "no bitstream at $BITSTREAM" >&2; exit 1; }
    [ -f "$FW" ] || { echo "run tools/ladder_fw.sh build first" >&2; exit 1; }
    "${c1[@]}"
    "${c2[@]}"
    echo "Done. Power-cycle the board, open the serial port at 115200 baud."
    ;;
# chip: the full-chip firmware, that is the stage-0 loader (at most 64 KiB), the packed ft8fw image and the PC sender.
chip)
    [ -n "$OBJCOPY" ] || { echo "riscv-none-elf-objcopy not found under /c/tools/xpack-riscv-none-elf-gcc-*" >&2; exit 1; }
    cd "$repo_root/fw"
    mkdir -p target/ladder
    cargo build --release --target riscv32imafc-unknown-none-elf -p tr-loader --bin stage0
    "$OBJCOPY" -O binary "${CARGO_TARGET_DIR:-target}/riscv32imafc-unknown-none-elf/release/stage0" target/ladder/stage0.bin
    sz=$(stat -c %s target/ladder/stage0.bin)
    [ "$sz" -le 65536 ] || { echo "stage0.bin is $sz bytes: more than the 64 KiB the layout gives it" >&2; exit 1; }
    cargo build --release --target riscv32imafc-unknown-none-elf -p tr-app --bin ft8fw
    cargo run -q -p xtask -- image --input "${CARGO_TARGET_DIR:-target}/riscv32imafc-unknown-none-elf/release/ft8fw" --output target/ladder/ft8fw.img
    cargo build --release -p tr-loader-send
    ls -l target/ladder/stage0.bin target/ladder/ft8fw.img
    ;;
# write-chip: the same two commands for the full chip, then the sender command that puts ft8fw into the flash.
write-chip)
    # The programmer of the author's Gowin programmer install; change the path to your own programmer_cli.exe.
    PROG="C:/tools/gowin-programmer/bin/programmer_cli.exe"
    DEVICE="${DEVICE:-GW5AST-138C}"
    BITSTREAM="${BITSTREAM:?set BITSTREAM=<path of sdr_top.fs>}"
    S0="${S0:-$(cygpath -m "$repo_root")/fw/target/ladder/stage0.bin}"
    IMG="${IMG:-$(cygpath -m "$repo_root")/fw/target/ladder/ft8fw.img}"
    c1=("$PROG" --device "$DEVICE" --run 54 --fsFile "$BITSTREAM" --spiaddr 0x000000)
    c2=("$PROG" --device "$DEVICE" --run 56 --mcuFile "$S0" --spiaddr 0x600000)
    echo "1. full-chip bitstream (flash offset 0):"; printf ' %q' "${c1[@]}"; echo
    echo "2. stage-0 loader (flash offset 0x600000; replaces the ladder program):"; printf ' %q' "${c2[@]}"; echo
    echo "3. after a power cycle, with the loader's prompt showing on the serial port, send the firmware into the flash:"
    echo " $(cygpath -m "$repo_root")/fw/target/release/tr-loader-send --serial ${SERIAL:-COM5} --baud 115200 --image $IMG --cmd flash"
    echo "   (--cmd run starts it from RAM without writing the flash)"
    if [ "${2:-}" != "--go" ]; then echo "Not written. Add --go to run 1 and 2."; exit 0; fi
    [ -f "$BITSTREAM" ] || { echo "no bitstream at $BITSTREAM" >&2; exit 1; }
    [ -f "$S0" ] || { echo "run tools/ladder_fw.sh chip first" >&2; exit 1; }
    "${c1[@]}"
    "${c2[@]}"
    echo "Done. Power-cycle the board, then run command 3."
    ;;
*) echo "usage: tools/ladder_fw.sh build | write <step> [--go] | chip | write-chip [--go]" >&2; exit 1 ;;
esac
