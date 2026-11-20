// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Build script of the QEMU test payload: publishes memory-qemu.x as `memory.x` on the linker
// search path, the same mechanism as fw/tr-ae350/build.rs and fw/tr-loader/build.rs (see their
// comments). This crate only ever has the QEMU variant, so there is no board feature switch.
// The crate depends on tr-ae350, which has a memory.x of its own, and the one published here
// has to be the one the linker finds first; that was checked by building the crate (see
// docs/C2_LOADER.md).

use std::env;
use std::fs;
use std::path::PathBuf;

fn main() {
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR not set"));
    // Copied under the name memory.x, which is what riscv-rt's link.x includes.
    fs::copy("memory-qemu.x", out_dir.join("memory.x")).expect("copying memory.x into OUT_DIR");
    println!("cargo:rustc-link-search={}", out_dir.display());
    println!("cargo:rerun-if-changed=memory-qemu.x");
}
