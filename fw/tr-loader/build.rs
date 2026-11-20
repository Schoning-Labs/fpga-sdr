// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Build script of the stage-0 loader: chooses the linker scripts. It works the same way as
// fw/tr-ae350/build.rs (see its comment): it picks memory-loader-ae350.x or memory-loader-qemu.x
// for the board-ae350 or board-qemu feature and publishes the chosen file as `memory.x` on the
// linker search path, where riscv-rt's link.x finds it. The loader has its own pair of scripts
// and does not reuse the ones of tr-ae350, because it links a different kind of image: one that
// executes in place from flash, and not a `BUILD_LOAD` image that GDB loads whole into DDR3. See
// docs/C2_LOADER.md "Linker layout: XIP, not BUILD_LOAD".
//
// Cargo runs this script from the crate's own directory, which is why the script files are
// opened by bare file name.

use std::env;
use std::fs;
use std::path::PathBuf;

fn main() {
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR not set"));

    // Cargo tells a build script which features are on through CARGO_FEATURE_* variables.
    let qemu = env::var_os("CARGO_FEATURE_BOARD_QEMU").is_some();
    let ae350 = env::var_os("CARGO_FEATURE_BOARD_AE350").is_some();
    assert!(
        qemu != ae350,
        "tr-loader: exactly one of the board-ae350 / board-qemu features must be enabled \
         (see fw/tr-loader/Cargo.toml and docs/C2_LOADER.md)"
    );
    let src = if qemu {
        "memory-loader-qemu.x"
    } else {
        "memory-loader-ae350.x"
    };

    // The linker scripts are included by name as `memory.x`, so the right one is copied under
    // that name into the build's output directory, which is then put on the linker search path.
    fs::copy(src, out_dir.join("memory.x")).expect("copying memory.x into OUT_DIR");
    println!("cargo:rustc-link-search={}", out_dir.display());
    println!("cargo:rerun-if-changed={src}");
    println!("cargo:rerun-if-changed=memory-loader-ae350.x");
    println!("cargo:rerun-if-changed=memory-loader-qemu.x");
    println!("cargo:rerun-if-env-changed=CARGO_FEATURE_BOARD_QEMU");
    println!("cargo:rerun-if-env-changed=CARGO_FEATURE_BOARD_AE350");

    // ramfunc-ae350.x (see its own header comment) only makes sense where there is a flash
    // controller to protect against, which is board-ae350. It is passed as an extra -T and is not
    // folded into memory.x, because it is a full `SECTIONS { ... } INSERT AFTER .data;` script, and
    // not something that riscv-rt's own link.x `INCLUDE`s the way it does memory.x.
    if ae350 {
        fs::copy("ramfunc-ae350.x", out_dir.join("ramfunc-ae350.x"))
            .expect("copying ramfunc-ae350.x into OUT_DIR");
        println!("cargo:rustc-link-arg=-Tramfunc-ae350.x");
        println!("cargo:rerun-if-changed=ramfunc-ae350.x");
        // Pins riscv-rt's start-up function into flash (see init-rust-ae350.x for why it would
        // otherwise end up in DLM).
        fs::copy("init-rust-ae350.x", out_dir.join("init-rust-ae350.x"))
            .expect("copying init-rust-ae350.x into OUT_DIR");
        println!("cargo:rustc-link-arg=-Tinit-rust-ae350.x");
        println!("cargo:rerun-if-changed=init-rust-ae350.x");
    }
}
