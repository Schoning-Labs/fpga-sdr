// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! `xtask`: the repository's own developer tools, run with `cargo run -p xtask -- <subcommand>`
//! from the `fw` directory.
//!
//! There are two subcommands.
//!
//! - `regmap` reads the register-map descriptions in `hw/regmap/*.toml` and writes the Verilog
//!   include files and the `tr-regs` Rust crate from them, so the hardware and the firmware
//!   cannot disagree about an address (docs/REGMAP.md).
//! - `image` packs a built RV32 ELF file (or an already flat binary) into a fpga-sdr boot image
//!   with a header and checksums, which is the format the stage-0 loader accepts
//!   (docs/C2_LOADER.md).

mod image;
mod regmap;

use std::path::PathBuf;

/// The repository root, found from this crate's own location so the tool works no matter which
/// directory it is started from.
fn repo_root() -> PathBuf {
    // This crate lives at <repo>/fw/xtask; CARGO_MANIFEST_DIR is <repo>/fw/xtask at build time.
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|p| p.parent())
        .expect("fw/xtask should have two parent directories (fw/, then the repo root)")
        .to_path_buf()
}

fn main() {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        Some("regmap") => {
            if let Err(e) = regmap::run(&repo_root()) {
                eprintln!("xtask regmap: {e}");
                std::process::exit(1);
            }
        }
        Some("image") => {
            if let Err(e) = image::run(&repo_root(), args) {
                eprintln!("{e}");
                std::process::exit(1);
            }
        }
        Some(other) => {
            eprintln!("xtask: unknown subcommand {other:?}");
            eprintln!("available subcommands: regmap, image");
            std::process::exit(1);
        }
        None => {
            eprintln!("xtask: no subcommand given");
            eprintln!("available subcommands: regmap, image");
            std::process::exit(1);
        }
    }
}
