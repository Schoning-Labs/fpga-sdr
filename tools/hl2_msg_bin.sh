#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Finds (and with --build, first builds) the HL2's message-layer program msg.bin in a checkout of the
# Hermes-Lite2 repository, branch hl2-rawfront-release, and prints the lines that make the radio
# firmware embed it with its version (docs/HL2_CONTROL.md, "Updating the HL2's program"). The
# version is read from FW_VERSION in firmware/hl2neo/msg/main.c, the number the program reports in
# HELLO:
#
#   tools/hl2_msg_bin.sh [--build] [HL2_REPOSITORY]
#   eval "$(tools/hl2_msg_bin.sh /path/to/Hermes-Lite2)"     # then build the firmware as usual
#
# The repository path comes from the argument or from HL2_FORK_DIR. --build runs
# `python firmware/hl2neo/build.py` there, which needs the xPack RISC-V GCC (RISCV_PREFIX) and also
# rewrites that repository's boot ROM files (gateware/variants/hl2b5up_raw/bootrom.mif and the
# simulation hex files). The image is never copied into this repository.

set -e

build=0
if [ "$1" = "--build" ]; then
    build=1
    shift
fi
repo=${1:-$HL2_FORK_DIR}
if [ -z "$repo" ]; then
    echo "usage: $0 [--build] HL2_REPOSITORY   (or set HL2_FORK_DIR)" >&2
    exit 2
fi
if [ ! -f "$repo/firmware/hl2neo/build.py" ]; then
    echo "$repo: no firmware/hl2neo/build.py (not the hl2-rawfront-release branch?)" >&2
    exit 1
fi
if [ "$build" = 1 ]; then
    (cd "$repo" && python firmware/hl2neo/build.py) >&2
fi

bin="$repo/firmware/hl2neo/build/msg.bin"
if [ ! -f "$bin" ]; then
    echo "$bin is missing: run $0 --build $repo" >&2
    exit 1
fi
size=$(wc -c < "$bin" | tr -d ' ')
# the HL2 CPU's application RAM, 0x800 to 0x3FFF
if [ "$size" -eq 0 ] || [ "$size" -gt 14336 ]; then
    echo "$bin: $size bytes, the HL2 CPU's application RAM holds 1 to 14336" >&2
    exit 1
fi
# pwd -W gives the Windows form (G:/...) under Git Bash, which cargo on Windows needs
abs=$(cd "$(dirname "$bin")" && { pwd -W 2>/dev/null || pwd; })/msg.bin
version=$(sed -n 's/^#define FW_VERSION *\(0x[0-9A-Fa-f]*\).*/\1/p' "$repo/firmware/hl2neo/msg/main.c" | tr -d '\r')
if [ -z "$version" ]; then
    echo "$repo/firmware/hl2neo/msg/main.c: no FW_VERSION" >&2
    exit 1
fi
echo "msg.bin: $size bytes, version $version" >&2
echo "export HL2_MSG_BIN='$abs'"
echo "export HL2_MSG_VERSION=$version"
