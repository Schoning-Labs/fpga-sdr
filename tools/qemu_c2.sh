#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Tests the UART loader stage-0 (fw/tr-loader, docs/C2_LOADER.md) under QEMU. It builds stage-0 (feature board-qemu) and a tiny
# test payload (fw/tr-loader-testfw), packs the payload with `cargo xtask image`, and runs two scenarios under
# `qemu-system-riscv32 -M virt`:
#
#   - good-image:    a valid packed image, sent over a TCP socket that stands in for the emulated UART (QEMU's `-chardev
#                    socket`) by the PC-side sender (fw/tr-loader-send); expect the payload's "payload ok" line, which
#                    shows that it ran.
#   - corrupt-image: the same image with one payload byte flipped; expect a clear "image rejected" refusal and no
#                    "payload ok", which shows that it did not run.
#
# QEMU has no model of the board's SPI flash controller, so only the UART path (receive, CRC check, run) is exercised here and
# never reading or writing flash; docs/C2_LOADER.md ("What ran under QEMU vs. what did not") lists the board-only parts.
#
# Needs a Rust toolchain with the riscv32imafc-unknown-none-elf target, qemu-system-riscv32, and dd, od and mktemp from a
# POSIX shell (Git Bash on Windows, where `taskkill` is the last resort for ending a stuck QEMU). No Gowin EDA, no board.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root/fw"

target=riscv32imafc-unknown-none-elf

# QEMU from scoop has no shim on PATH for every binary, so fall back to its app folder (the author's install, the same fallback
# as in tools/qemu_c1.sh; change the folder if QEMU lives elsewhere).
if ! command -v qemu-system-riscv32 >/dev/null 2>&1 && [ -d "$HOME/scoop/apps/qemu/current" ]; then
    PATH="$HOME/scoop/apps/qemu/current:$PATH"
fi
if ! command -v qemu-system-riscv32 >/dev/null 2>&1; then
    echo "qemu_c2.sh: qemu-system-riscv32 not found on PATH" >&2
    echo "  scoop install qemu (open a new shell afterwards)" >&2
    exit 1
fi

echo "== building stage0 for QEMU (--features board-qemu) =="
if ! cargo build --target "$target" -p tr-loader --bin stage0 --no-default-features --features board-qemu; then
    echo "qemu_c2.sh: FAIL (stage0 build error)" >&2
    exit 1
fi
stage0_elf="target/$target/debug/stage0"

echo "== building the QEMU test payload (fw/tr-loader-testfw) =="
if ! cargo build --target "$target" -p tr-loader-testfw --bin payload; then
    echo "qemu_c2.sh: FAIL (payload build error)" >&2
    exit 1
fi
payload_elf="target/$target/debug/payload"

echo "== building xtask and tr-loader-send (host tools) =="
if ! cargo build -p xtask -p tr-loader-send; then
    echo "qemu_c2.sh: FAIL (host tool build error)" >&2
    exit 1
fi
sender="target/debug/tr-loader-send"

# Scratch folder for the packed images and the QEMU logs, removed when the script ends.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "== packing the test payload (cargo xtask image) =="
if ! cargo run -q -p xtask -- image --input "$payload_elf" --output "$work/good.img"; then
    echo "qemu_c2.sh: FAIL (xtask image)" >&2
    exit 1
fi

# A corrupt image: the last payload byte is flipped, well after the header, so that the header still parses (magic, header CRC
# and version are all still valid) and only the payload CRC check can catch it, because the test wants a corrupt image refused
# and not merely a malformed one rejected earlier. The flip is done with dd, od and printf, so neither python nor perl has to
# be installed (docs/TOOLCHAIN.md).
cp "$work/good.img" "$work/corrupt.img"
size=$(wc -c <"$work/corrupt.img")
offset=$((size - 1))
byte=$(dd if="$work/corrupt.img" bs=1 skip="$offset" count=1 2>/dev/null | od -An -tu1 | tr -d ' ')
flipped=$(((byte + 1) % 256))
printf "$(printf '\\%03o' "$flipped")" | dd of="$work/corrupt.img" bs=1 seek="$offset" count=1 conv=notrunc 2>/dev/null

fail=0

# run_scenario NAME IMAGE PORT EXPECT_PASS starts QEMU with stage-0 on PORT, sends IMAGE with tr-loader-send, makes sure that QEMU
# is gone, and sets fail=1 when the outcome differs from the expected one (EXPECT_PASS yes: the payload ran; no: the image was
# refused with "image rejected" and the payload did not run).
run_scenario() {
    local name="$1" image="$2" port="$3" expect_pass="$4"
    echo "== QEMU scenario: $name (port $port) =="
    qemu-system-riscv32 -M virt -m 128M -nographic -bios none -kernel "$stage0_elf" \
        -chardev socket,id=uart0,host=127.0.0.1,port="$port",server=on,wait=off \
        -serial chardev:uart0 \
        >"$work/$name.qemu.log" 2>&1 &
    local qemu_pid=$!

    # The timeouts here are generous on purpose, so that a loaded host passes as well as a quiet one. The board-qemu build of
    # stage-0 offers its handshake for 5 s per attempt (HANDSHAKE_WINDOW_MS in fw/tr-loader/src/bin/stage0.rs), and a heavily
    # loaded host can use up more than one attempt before the virtual CPU is scheduled, in which case tr-loader-send repeats its
    # sync bytes at every new prompt it sees until one is acknowledged (docs/C2_LOADER.md, "Protocol"). 30 s for the handshake,
    # 20 s for the relay and 25 s for the poll loop cover several such retries plus the transfer and the shutdown, and on an idle
    # host the scenario still ends in well under a second.
    local sender_out
    sender_out="$("$sender" --tcp "127.0.0.1:$port" --image "$image" --cmd run --handshake-timeout-secs 30 --relay-secs 20 2>&1)"
    echo "$sender_out"

    # exit_pass() and exit_fail() shut QEMU down by themselves once a scenario is decided, which only happens for good-image
    # (corrupt-image keeps offering the handshake and never exits on its own), so this loop is the safety net for the first and
    # the explicit timeout for the second.
    local waited=0
    while kill -0 "$qemu_pid" 2>/dev/null && [ "$waited" -lt 25 ]; do
        sleep 1
        waited=$((waited + 1))
    done
    if kill -0 "$qemu_pid" 2>/dev/null; then
        # A plain `kill` (SIGTERM) is not reliably honored by the native qemu-system-riscv32.exe under Git Bash on Windows, and it
        # can leave the process alive and still bound to $port after this function returns, where a later scenario that uses the
        # same port would talk to the leftover process and not to its own QEMU. So the process is ended in steps: SIGTERM, then
        # SIGKILL, then `taskkill` on this one PID (never by image name, since other sessions may run QEMU as well), and the port
        # is free when the function returns.
        kill "$qemu_pid" 2>/dev/null || true
        sleep 1
        if kill -0 "$qemu_pid" 2>/dev/null; then
            kill -9 "$qemu_pid" 2>/dev/null || true
            sleep 1
        fi
        if kill -0 "$qemu_pid" 2>/dev/null; then
            taskkill //F //PID "$qemu_pid" >/dev/null 2>&1 || true
        fi
    fi
    wait "$qemu_pid" 2>/dev/null || true

    if [ "$expect_pass" = "yes" ]; then
        if ! grep -q "payload ok" <<<"$sender_out"; then
            echo "qemu_c2.sh: FAIL ($name): expected \"payload ok\", did not see it" >&2
            fail=1
        fi
    else
        if grep -q "payload ok" <<<"$sender_out"; then
            echo "qemu_c2.sh: FAIL ($name): the payload ran, but it should have been refused" >&2
            fail=1
        fi
        if ! grep -q "image rejected" <<<"$sender_out"; then
            echo "qemu_c2.sh: FAIL ($name): expected a clear \"image rejected\" refusal message, did not see one" >&2
            fail=1
        fi
    fi
}

# The ports are derived from the process ID of this script and are not fixed, so a QEMU that an earlier run failed to end can
# never be mistaken for the QEMU of this run: with a fixed port such a leftover would receive the handshake and the image of the
# next run in place of its own fresh QEMU, which shows up as a corrupted image or as a handshake that is never seen.
port_good=$((20000 + ($$ % 20000)))
port_corrupt=$((port_good + 1))

run_scenario "good-image" "$work/good.img" "$port_good" yes
run_scenario "corrupt-image" "$work/corrupt.img" "$port_corrupt" no

if [ "$fail" -ne 0 ]; then
    echo "qemu_c2.sh: FAILED" >&2
    exit 1
fi

echo "qemu_c2.sh: PASS (a valid image sent over the emulated UART was loaded, CRC-checked and started; a corrupt image was refused with a clear message)"
