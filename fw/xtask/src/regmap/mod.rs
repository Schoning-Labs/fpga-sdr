// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! `xtask regmap`: reads every `hw/regmap/*.toml` (one file per register block of the FPGA
//! design), validates it, and writes two kinds of output from the same description:
//!
//! - `hw/regmap/generated/<block>_regs.vh`, Verilog macros for the block's addresses and fields
//!   (`verilog.rs`), and
//! - `fw/tr-regs/src/generated.rs`, typed Rust accessors for the same registers (`rust_gen.rs`).
//!
//! The TOML files are the one place a register address is written down by hand, so the hardware
//! and the firmware cannot drift apart. Both outputs are committed to the repository, and
//! `tools/check.sh` runs the generator again and fails if either file would change, which means
//! a stale generated file is caught instead of being trusted. The file format and the checks the
//! generator makes are described in docs/REGMAP.md.

mod model;
mod rust_gen;
mod verilog;

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

/// Runs the whole generator for the repository at `repo_root`: reads and validates every block
/// description, refuses duplicate block names and overlapping address ranges between blocks,
/// writes the outputs and prints one summary line per block. The first problem found is returned
/// as an error message that names the file it came from.
pub fn run(repo_root: &Path) -> Result<(), String> {
    let regmap_dir = repo_root.join("hw/regmap");
    let mut toml_paths: Vec<PathBuf> = fs::read_dir(&regmap_dir)
        .map_err(|e| format!("reading {}: {e}", regmap_dir.display()))?
        .filter_map(|entry| entry.ok().map(|e| e.path()))
        .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("toml"))
        .collect();
    // Directory listing order is not stable between machines, so sort for a reproducible run.
    toml_paths.sort();

    if toml_paths.is_empty() {
        return Err(format!("no *.toml files found under {}", regmap_dir.display()));
    }

    let mut blocks = Vec::with_capacity(toml_paths.len());
    // Block name -> file, to catch two files that declare the same block.
    let mut by_name: BTreeMap<String, PathBuf> = BTreeMap::new();
    // Block base address -> (size, file), to catch two blocks whose address pages overlap.
    let mut by_base: BTreeMap<u32, (u32, PathBuf)> = BTreeMap::new();

    for path in &toml_paths {
        let text = fs::read_to_string(path).map_err(|e| format!("reading {}: {e}", path.display()))?;
        let file: model::BlockFile = toml::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))?;
        let source = path.file_name().unwrap().to_string_lossy().to_string();
        let block = model::validate(file, &source)?;

        if let Some(prior) = by_name.insert(block.name.clone(), path.clone()) {
            return Err(format!(
                "{}: block name {:?} already used by {}",
                path.display(),
                block.name,
                prior.display()
            ));
        }
        // Two half-open ranges [base, base+size) overlap when each starts before the other ends.
        for (&other_base, (other_size, other_path)) in &by_base {
            let overlap = block.base < other_base + other_size && other_base < block.base + block.size;
            if overlap {
                return Err(format!(
                    "{}: block {:?} at {:#010x}..{:#010x} overlaps {} at {:#010x}..{:#010x}",
                    path.display(),
                    block.name,
                    block.base,
                    block.base + block.size,
                    other_path.display(),
                    other_base,
                    other_base + other_size
                ));
            }
        }
        by_base.insert(block.base, (block.size, path.clone()));

        blocks.push(block);
    }

    // The generated Rust file holds every block in one file, so its order has to be the same on
    // every run whatever the order the files were found in.
    blocks.sort_by(|a, b| a.name.cmp(&b.name));

    let vh_dir = regmap_dir.join("generated");
    fs::create_dir_all(&vh_dir).map_err(|e| format!("creating {}: {e}", vh_dir.display()))?;

    // A block that was renamed or removed would otherwise leave its old .vh file behind, still
    // looking current, so delete every generated file that no block asks for any more.
    let expected: std::collections::BTreeSet<String> =
        blocks.iter().map(|b| format!("{}_regs.vh", b.name)).collect();
    if let Ok(entries) = fs::read_dir(&vh_dir) {
        for entry in entries.flatten() {
            let file_name = entry.file_name().to_string_lossy().to_string();
            if file_name.ends_with("_regs.vh") && !expected.contains(&file_name) {
                let _ = fs::remove_file(entry.path());
            }
        }
    }

    for block in &blocks {
        let rendered = verilog::render(block);
        let out_path = vh_dir.join(format!("{}_regs.vh", block.name));
        write_if_changed(&out_path, &rendered)?;
    }

    let rust_rendered = rustfmt(&rust_gen::render(&blocks))?;
    let rust_out = repo_root.join("fw/tr-regs/src/generated.rs");
    write_if_changed(&rust_out, &rust_rendered)?;

    println!("xtask regmap: {} block(s) -> {} + fw/tr-regs/src/generated.rs", blocks.len(), vh_dir.display());
    for block in &blocks {
        println!(
            "  {:<12} base {:#010x} size {:#07x} status {} registers {}",
            block.name,
            block.base,
            block.size,
            block.status,
            block.registers.len()
        );
    }

    Ok(())
}

/// Writes `contents` to `path` only when the file does not already hold exactly that text, so a
/// run that changes nothing leaves the files' modification times alone (which keeps builds and
/// editors from seeing a change that is not there).
fn write_if_changed(path: &Path, contents: &str) -> Result<(), String> {
    if let Ok(existing) = fs::read_to_string(path) {
        if existing == contents {
            return Ok(());
        }
    }
    fs::write(path, contents).map_err(|e| format!("writing {}: {e}", path.display()))
}

/// Pipes `source` through `rustfmt` so the committed file reads like hand-written Rust and a
/// second run produces byte-identical output (the raw generator text is already valid Rust, just
/// not consistently spaced). `rust-toolchain.toml` pins the `rustfmt` component, so it is
/// expected to be on the path. Failing to start it is an error, and so is a nonzero exit from
/// it, which would mean the generator emitted invalid Rust and must not be passed through
/// silently.
fn rustfmt(source: &str) -> Result<String, String> {
    use std::io::Write;
    use std::process::{Command, Stdio};

    let mut child = Command::new("rustfmt")
        .arg("--edition=2021")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("running rustfmt (needed to format the generated tr-regs source): {e}"))?;

    child
        .stdin
        .take()
        .expect("piped stdin")
        .write_all(source.as_bytes())
        .map_err(|e| format!("writing to rustfmt's stdin: {e}"))?;

    let output = child.wait_with_output().map_err(|e| format!("waiting for rustfmt: {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "rustfmt rejected the generated tr-regs source (this means the generator itself produced invalid Rust):\n{}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    String::from_utf8(output.stdout).map_err(|e| format!("rustfmt output was not valid UTF-8: {e}"))
}
