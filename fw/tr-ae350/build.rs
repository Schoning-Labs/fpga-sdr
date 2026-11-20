// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Build script that picks `memory-ae350.x` or `memory-qemu.x`, matching the `board-ae350` or
//! `board-qemu` feature (see `Cargo.toml`), and hands it to the linker under the name `memory.x`,
//! which is the pattern `riscv-rt` documents. The `link.x` of `riscv-rt` (pulled in with
//! `-C link-arg=-Tlink.x`, see `fw/.cargo/config.toml`) includes a file with exactly that name, and
//! the file has to be on the linker search path.
//!
//! The script lives in `tr-ae350` and not in the application crate because the link-search
//! directives of a build script reach every crate that links this one (directly or not), so any
//! firmware binary that depends on `tr-ae350` gets the right `memory.x` without further setup.

use std::env;
use std::fs;
use std::path::PathBuf;

fn main() {
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR not set"));

    let qemu = env::var_os("CARGO_FEATURE_BOARD_QEMU").is_some();
    let ae350 = env::var_os("CARGO_FEATURE_BOARD_AE350").is_some();
    assert!(
        qemu != ae350,
        "tr-ae350: exactly one of the board-ae350 / board-qemu features must be enabled \
         (see fw/tr-ae350/Cargo.toml and docs/C1_AE350.md)"
    );
    let src = if qemu {
        "memory-qemu.x"
    } else {
        "memory-ae350.x"
    };

    fs::copy(src, out_dir.join("memory.x")).expect("copying memory.x into OUT_DIR");
    println!("cargo:rustc-link-search={}", out_dir.display());
    println!("cargo:rerun-if-changed={src}");
    println!("cargo:rerun-if-changed=memory-ae350.x");
    println!("cargo:rerun-if-changed=memory-qemu.x");
    println!("cargo:rerun-if-env-changed=CARGO_FEATURE_BOARD_QEMU");
    println!("cargo:rerun-if-env-changed=CARGO_FEATURE_BOARD_AE350");
}
