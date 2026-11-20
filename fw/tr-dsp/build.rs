// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Sets `cfg(tr_hw_fpu)` when building for a 32-bit RISC-V target whose ISA string includes the
//! F (single-precision float) extension, e.g. `riscv32imafc-unknown-none-elf` (the AE350).
//! `src/fmath.rs` then emits `fsqrt.s` / `fmadd.s` / `fmsub.s` directly. Needed because stable
//! Rust does not expose `target_feature = "f"` to `cfg` on RISC-V (checked with
//! `rustc --print cfg --target riscv32imafc-unknown-none-elf`, Rust 1.93: only a, c, m appear).

fn main() {
    println!("cargo:rustc-check-cfg=cfg(tr_hw_fpu)");
    println!("cargo:rerun-if-changed=build.rs");
    let target = std::env::var("TARGET").unwrap_or_default();
    if let Some(isa) = target.split('-').next().and_then(|a| a.strip_prefix("riscv32")) {
        if isa.contains('f') || isa.contains('g') {
            println!("cargo:rustc-cfg=tr_hw_fpu");
        }
    }
}
