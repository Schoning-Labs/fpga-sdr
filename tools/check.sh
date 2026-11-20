#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Franz Schöning, https://www.schoning.com
#
# Runs the whole check set of the project from the repository root: it regenerates the register map from hw/regmap/*.toml and
# checks that the generated files are committed, runs every Verilog testbench under sim/, compares the Rust receiver-bank model
# bit for bit with the RTL, checks the FT8 front end against real recordings, runs the Verilator testbenches, `cargo test` for
# the host crates of fw/, the target builds for riscv32imafc-unknown-none-elf and the QEMU tests of tools/qemu_*.sh. It exits
# non-zero when anything fails, and it runs every step even after a failure, so one run lists everything that is wrong.
#
# Testbench convention: a file named tb_*.v anywhere under sim/ has to be self-contained. It `include`s whatever DUT and support
# files it needs, with paths relative to the repository root, because this script starts iverilog from that directory and
# Icarus resolves `include relative to the invoking directory, so every testbench can be compiled standalone with iverilog. It
# must print PASS on success, and anything else, or a non-zero vvp exit code, counts as a failure. Verilator testbenches
# (tb_*.sv, run with `verilator --binary`) are handled the same way when there are any; at present there are none.
#
# Environment: FT8_WAV_FRAMES (how many frames the recording check uses, 20 here), FT8_LONG=1 (adds the sync and candidate
# checks over the recordings, which take an hour or more).
#
# Needs bash, git, cargo with the riscv32imafc-unknown-none-elf target, qemu-system-riscv32, and iverilog and vvp (and verilator
# for .sv testbenches) on PATH, which oss-cad-suite provides (C:/tools/oss-cad-suite in the author's setup). It does not use
# Gowin EDA or the board.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# fail is set to 1 by every step that goes wrong and reported once at the end.
fail=0

echo "== xtask regmap (hw/regmap/*.toml -> hw/regmap/generated/*.vh + fw/tr-regs/src/generated.rs) =="
if [ -d fw ]; then
    if ! (cd fw && cargo run -q -p xtask -- regmap); then
        echo "FAIL: xtask regmap"
        fail=1
    fi
else
    echo "fw/ not found" >&2
    fail=1
fi
# The generated files are committed (docs/REGMAP.md says why), and this step catches an edited .toml whose regenerated output
# was never committed, or a hand edit of the generated files themselves. `status --porcelain` is used (and not
# `diff --exit-code`) so that a brand-new generated file with no earlier commit is caught as well as a changed one.
stale="$(git status --porcelain -- hw/regmap/generated fw/tr-regs/src/generated.rs)"
if [ -n "$stale" ]; then
    echo "FAIL: generated register-map files are stale or uncommitted:"
    echo "$stale"
    echo "run: (cd fw && cargo run -p xtask -- regmap), then commit hw/regmap/generated/ and fw/tr-regs/src/generated.rs"
    fail=1
fi

echo "== FT8 vectors from the WSJT-X recordings (tools/make_ft8_vectors.sh) =="
if [ -f captures/ft8/qso1.wav ] && [ -f captures/ft8/qso3_busy.wav ]; then
    if ! bash tools/make_ft8_vectors.sh; then
        echo "FAIL: make_ft8_vectors.sh"
        fail=1
    fi
else
    echo "skipping (recordings not fetched: bash tools/fetch_test_audio.sh)"
fi

echo "== Verilog testbenches (sim/**/tb_*.v) =="
if command -v iverilog >/dev/null 2>&1; then
    tb_count=0
    while IFS= read -r -d '' tb; do
        tb_count=$((tb_count + 1))
        out="${tb%.v}.vvp"
        echo "-- $tb --"
        # A testbench that reads vector files made from the WSJT-X recordings (sim/ft8/README.md) is skipped when they are missing.
        missing=""
        for v in $(grep -o 'sim/ft8/vectors/[A-Za-z0-9_]*[.]hex' "$tb" | sort -u); do
            [ -f "$v" ] || missing="$missing $v"
        done
        if [ -n "$missing" ]; then
            echo "SKIPPED: $tb (vectors not made:$missing)"
            continue
        fi
        if ! iverilog -g2012 -o "$out" "$tb"; then
            echo "FAIL: $tb (compile error)"
            fail=1
            continue
        fi
        output="$(vvp "$out")"
        status=$?
        echo "$output"
        rm -f "$out"
        if [ "$status" -ne 0 ] || ! grep -q "PASS" <<<"$output"; then
            echo "FAIL: $tb"
            fail=1
        else
            echo "PASS: $tb"
        fi
    done < <(find sim -name 'tb_*.v' -print0 | sort -z)
    if [ "$tb_count" -eq 0 ]; then
        echo "no tb_*.v testbenches found under sim/"
    fi
else
    echo "iverilog not found on PATH (expected from oss-cad-suite)" >&2
    fail=1
fi

echo "== bit-exact Rust receiver-bank model vs iverilog (fw/tr-rxmodel) =="
# This is not a tb_*.v (see the header of sim/rx/r2_replay.v): the binary writes its own stimulus, drives iverilog (rtl/rx/*
# through sim/rx/r2_replay.v) and the Rust model over it, and diffs the two output streams word for word. -C target-cpu=native
# applies to this one invocation only and not to the workspace's shared build configuration; it roughly doubled the model's
# measured throughput, and this check also reports that throughput number (docs/R2_RXMODEL.md), so it is worth having even
# though it makes this one binary unportable to a different build machine.
if [ -d fw ] && command -v iverilog >/dev/null 2>&1; then
    if ! (cd fw && RUSTFLAGS="-C target-cpu=native" cargo run -q -p tr-rxmodel --release --bin r2_check); then
        echo "FAIL: model-vs-RTL comparison"
        fail=1
    fi
else
    echo "skipping the receiver-bank model check (fw/ or iverilog missing)" >&2
    fail=1
fi

echo "== FT8 spectrogram frame core vs the Rust model over a real recording =="
# This is not a tb_*.v either, because it needs vectors generated from captures/ft8/ (see the header of tools/check_ft8_wav.sh)
# and skips without failing when those have not been fetched. It uses 20 frames spread across the slot here, while the script on
# its own checks all 372 (about 20 minutes).
if ! FT8_WAV_FRAMES="${FT8_WAV_FRAMES:-20}" bash tools/check_ft8_wav.sh; then
    echo "FAIL: spectrogram recording check"
    fail=1
fi

echo "== sync search and candidate engine over the real recordings (FT8_LONG=1) =="
# These are not tb_*.v either (vectors from captures/ft8/, millions of clocks): tools/check_ft8_sync.sh takes about 30 minutes
# and tools/check_ft8_cand.sh well over an hour, so they run only with FT8_LONG=1. The short unit tests sim/ft8/tb_ft8_sync.v
# and tb_ft8_cand.v run above either way.
if [ "${FT8_LONG:-0}" = 1 ]; then
    bash tools/check_ft8_sync.sh || { echo "FAIL: sync recording check"; fail=1; }
    bash tools/check_ft8_cand.sh || { echo "FAIL: candidate recording check"; fail=1; }
else
    echo "skipped (set FT8_LONG=1)"
fi

echo "== Verilator testbenches (sim/**/tb_*.sv) =="
if command -v verilator >/dev/null 2>&1; then
    sv_count=0
    while IFS= read -r -d '' tb; do
        sv_count=$((sv_count + 1))
        name="$(basename "${tb%.sv}")"
        bin="$(dirname "$tb")/obj_dir_$name/V$name"
        echo "-- $tb --"
        if ! verilator --binary -Wno-fatal --top-module "$name" -Mdir "$(dirname "$tb")/obj_dir_$name" "$tb" >/dev/null; then
            echo "FAIL: $tb (compile error)"
            fail=1
            continue
        fi
        output="$("$bin")"
        status=$?
        echo "$output"
        rm -rf "$(dirname "$tb")/obj_dir_$name"
        if [ "$status" -ne 0 ] || ! grep -q "PASS" <<<"$output"; then
            echo "FAIL: $tb"
            fail=1
        else
            echo "PASS: $tb"
        fi
    done < <(find sim -name 'tb_*.sv' -print0 | sort -z)
    if [ "$sv_count" -eq 0 ]; then
        echo "no tb_*.sv testbenches found under sim/"
    fi
else
    echo "verilator not found on PATH (expected from oss-cad-suite); skipping" >&2
fi

echo "== cargo test (host fw/ crates) =="
if [ -d fw ]; then
    if ! (cd fw && cargo test); then
        fail=1
    fi
else
    echo "fw/ not found" >&2
    fail=1
fi

echo "== cargo build --target riscv32imafc-unknown-none-elf (AE350-only fw/ crates, plus tr-gui) =="
if [ -d fw ]; then
    if ! (cd fw && cargo build --target riscv32imafc-unknown-none-elf \
        -p tr-ae350 -p tr-fabric -p tr-net -p tr-app -p tr-regs -p tr-gui -p tr-bench -p tr-loader -p tr-ft8bench); then
        fail=1
    fi
else
    fail=1
fi

echo "== tools/qemu_c1.sh (UART hello, timer interrupt, illegal-instruction trap under QEMU) =="
if ! bash tools/qemu_c1.sh; then
    fail=1
fi

echo "== tools/qemu_c4.sh (FP registers survive a real interrupt firing during an FP loop; FP use in a handler is caught) =="
if ! bash tools/qemu_c4.sh; then
    fail=1
fi

echo "== tools/qemu_s2.sh (CPU benchmark harness smoke run under QEMU) =="
if ! bash tools/qemu_s2.sh --smoke; then
    fail=1
fi

echo "== tools/qemu_s15.sh --smoke (FT8 decoder CPU part replayed from a fabric trace under QEMU) =="
if ! bash tools/qemu_s15.sh --smoke; then
    fail=1
fi

echo "== tools/qemu_c2.sh (UART loader receives, CRC-checks and starts an image; refuses a corrupt one) =="
if ! bash tools/qemu_c2.sh; then
    fail=1
fi

echo "== cargo build --target riscv32imafc-unknown-none-elf (tr-modes, no_std encode+decode) =="
# tr-modes is a default member of the workspace (it needs `cargo test` on the host, with "std" on by default) but it also has to
# cross-build as no_std for the AE350 target, see fw/tr-modes/Cargo.toml and docs/S5_MODES.md ("no_std shape" and "no_std FFT
# backend"). --no-default-features drops "std", and "fft-portable" (this crate's own pure-Rust FFT, wired through mfsk-core's
# fft-extern hook) is what makes decoding, and not only encoding, available here for every mode of the crate.
#
# wspr needs a small vendored patch to mfsk-core itself (fw/vendor/mfsk-core, wired in through [patch.crates-io] in
# fw/Cargo.toml) that removes three std-only paths in its wspr::osd, wspr::decode and wspr::baseband modules, which only show up
# once an FFT backend (fft-extern) is enabled. docs/S5_MODES.md, "no_std FFT backend", lists them and says why the fix is a
# vendored patch.
if [ -d fw ]; then
    if ! (cd fw && cargo build --target riscv32imafc-unknown-none-elf \
        -p tr-modes --no-default-features --features ft8,ft4,wspr,fft-portable); then
        fail=1
    fi
else
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "check.sh: FAILED"
    exit 1
fi

echo "check.sh: all checks passed"
