// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Build script of tr-ladder.
//! It does two things for the linker. It publishes memory-ladder.x as `memory.x` on the linker search path,
//! which riscv-rt's `link.x` includes; this crate's build output is searched before that of tr-ae350, so this
//! memory map is the one that is used, the same mechanism as in fw/tr-loader/build.rs (docs/C2_LOADER.md). And
//! it passes fw/tr-loader/init-rust-ae350.x as a linker script, which keeps riscv-rt's `_start_rust` in flash;
//! without it the linker can place that function in RAM, and the reset code in flash would then jump into
//! empty memory.

use std::env;
use std::fs;
use std::path::PathBuf;

/// Copies the two linker scripts into OUT_DIR, adds OUT_DIR to the linker search path and tells Cargo to rerun
/// when either source file changes.
fn main() {
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR not set"));
    fs::copy("memory-ladder.x", out_dir.join("memory.x")).expect("copying memory.x into OUT_DIR");
    println!("cargo:rustc-link-search={}", out_dir.display());
    println!("cargo:rerun-if-changed=memory-ladder.x");
    fs::copy("../tr-loader/init-rust-ae350.x", out_dir.join("init-rust-ae350.x"))
        .expect("copying ../tr-loader/init-rust-ae350.x into OUT_DIR");
    println!("cargo:rustc-link-arg=-Tinit-rust-ae350.x");
    println!("cargo:rerun-if-changed=../tr-loader/init-rust-ae350.x");
}
