// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! `xtask image`: packs a built RV32 ELF file (or an already flat binary) into a fpga-sdr boot
//! image, which is a `tr_image::ImageHeader` followed by the flattened payload bytes, and which
//! is what the stage-0 loader receives over the UART and what it keeps in a flash slot
//! (docs/C2_LOADER.md "Image format").
//!
//! Usage, from the `fw` directory:
//!
//! ```text
//! cargo run -p xtask -- image --input <elf-or-bin> --output <file.img> \
//!     [--load-addr <addr>] [--entry <addr>] [--flags <n>]
//! ```
//!
//! For an ELF input the load address defaults to the lowest segment address and the entry
//! defaults to the ELF entry point. A flat binary carries neither, so `--load-addr` is required
//! for it (and `--entry` defaults to the load address). Numbers are `0x` hex or plain decimal.
//!
//! The ELF is flattened (every `PT_LOAD` segment put at its address in one contiguous byte buffer
//! that starts at the lowest segment, with any gap between segments filled with zeros) by the
//! `object` crate, which is pure Rust and so fits docs/DECISIONS.md's "Software" section, instead
//! of by running `objcopy` or `llvm-objcopy`. The repository's toolchain (rust-toolchain.toml)
//! does not install `llvm-tools-preview`, and an external command that has to be on the path is
//! a worse dependency for one subcommand than one more crate from crates.io, of which `xtask`
//! already has some (`toml` and `serde`, see Cargo.toml).

use std::fs;
use std::path::{Path, PathBuf};

/// The command line of `xtask image`, after parsing.
struct Args {
    /// ELF or flat binary to pack.
    input: PathBuf,
    /// Where the packed image is written (missing parent directories are created).
    output: PathBuf,
    /// Address the loader copies the payload to; `None` means "take it from the ELF".
    load_addr: Option<u32>,
    /// Address the loader jumps to; `None` means "take it from the ELF, else use `load_addr`".
    entry: Option<u32>,
    /// Header `flags` field, reserved by the format and normally 0.
    flags: u16,
}

/// Parses the flags after the subcommand name; every flag takes exactly one value.
fn parse_args(mut args: impl Iterator<Item = String>) -> Result<Args, String> {
    let mut input = None;
    let mut output = None;
    let mut load_addr = None;
    let mut entry = None;
    let mut flags = 0u16;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--input" => input = Some(PathBuf::from(next_val(&mut args, "--input")?)),
            "--output" => output = Some(PathBuf::from(next_val(&mut args, "--output")?)),
            "--load-addr" => load_addr = Some(parse_num(&next_val(&mut args, "--load-addr")?)?),
            "--entry" => entry = Some(parse_num(&next_val(&mut args, "--entry")?)?),
            "--flags" => flags = parse_num(&next_val(&mut args, "--flags")?)? as u16,
            other => return Err(format!("xtask image: unknown flag {other:?}")),
        }
    }

    Ok(Args {
        input: input.ok_or("xtask image: --input <elf-or-bin> is required")?,
        output: output.ok_or("xtask image: --output <path> is required")?,
        load_addr,
        entry,
        flags,
    })
}

/// The value that follows `flag`, or an error saying that the command line ended too early.
fn next_val(args: &mut impl Iterator<Item = String>, flag: &str) -> Result<String, String> {
    args.next().ok_or_else(|| format!("xtask image: {flag} needs a value"))
}

/// Accepts `0x`-prefixed hex or plain decimal, which matches how addresses are written everywhere
/// else in this repository's docs (for example the memory map in docs/BOARD.md).
fn parse_num(s: &str) -> Result<u32, String> {
    if let Some(hex) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        u32::from_str_radix(hex, 16).map_err(|e| format!("xtask image: bad number {s:?}: {e}"))
    } else {
        s.parse::<u32>().map_err(|e| format!("xtask image: bad number {s:?}: {e}"))
    }
}

/// Flattens `data` (assumed to be an ELF32 file) into one contiguous buffer covering every
/// `PT_LOAD` segment, the way `objcopy -O binary` does: the buffer starts at the lowest segment
/// address and reaches to the end of the highest segment, and any gap between segments (usually
/// padding the linker left for alignment) is filled with zeros. Returns `(flat_bytes,
/// base_address, entry_point)`.
fn flatten_elf(data: &[u8]) -> Result<(Vec<u8>, u32, u32), String> {
    use object::{Object, ObjectSegment};

    let file = object::File::parse(data).map_err(|e| format!("parsing ELF: {e}"))?;
    let entry: u32 = file
        .entry()
        .try_into()
        .map_err(|_| "ELF entry point does not fit in 32 bits (expected an RV32 image)".to_string())?;

    let mut segments: Vec<(u32, Vec<u8>)> = Vec::new();
    for seg in file.segments() {
        let addr: u32 = seg
            .address()
            .try_into()
            .map_err(|_| "ELF segment address does not fit in 32 bits".to_string())?;
        let bytes = seg
            .data()
            .map_err(|e| format!("reading segment data: {e}"))?
            .to_vec();
        if bytes.is_empty() {
            continue; // a .bss-only PT_LOAD (memsz > filesz) has no file bytes to flatten
        }
        segments.push((addr, bytes));
    }
    if segments.is_empty() {
        return Err("ELF has no loadable segments with file contents".to_string());
    }
    // The segments are not necessarily listed in address order in the ELF program headers.
    segments.sort_by_key(|(addr, _)| *addr);

    let base = segments[0].0;
    let end = segments
        .iter()
        .map(|(addr, bytes)| addr + bytes.len() as u32)
        .max()
        .unwrap();
    let mut flat = vec![0u8; (end - base) as usize];
    for (addr, bytes) in &segments {
        let offset = (addr - base) as usize;
        flat[offset..offset + bytes.len()].copy_from_slice(bytes);
    }
    Ok((flat, base, entry))
}

/// First four bytes of every ELF file, used to tell an ELF input from a flat binary.
const ELF_MAGIC: [u8; 4] = [0x7f, b'E', b'L', b'F'];

/// Entry point of the subcommand: reads the input, flattens it if it is an ELF, builds the header
/// with `tr_image` (which also computes both CRC32 values), writes header and payload to the
/// output file and prints one line saying what was written. `args` is the command line after the
/// word `image`.
pub fn run(_repo_root: &Path, args: impl Iterator<Item = String>) -> Result<(), String> {
    let args = parse_args(args)?;
    let raw = fs::read(&args.input).map_err(|e| format!("reading {}: {e}", args.input.display()))?;

    let (payload, elf_info) = if raw.len() >= 4 && raw[0..4] == ELF_MAGIC {
        let (flat, base, entry) = flatten_elf(&raw)?;
        (flat, Some((base, entry)))
    } else {
        // Already a flat binary (for example the output of `rust-objcopy -O binary`): there is no
        // ELF header to read the addresses from, so --load-addr has to be given on the command
        // line (--entry falls back to it below).
        (raw, None)
    };

    let load_addr = args
        .load_addr
        .or(elf_info.map(|(base, _)| base))
        .ok_or("xtask image: --load-addr is required for a flat (non-ELF) input")?;
    let entry = args
        .entry
        .or(elf_info.map(|(_, entry)| entry))
        .unwrap_or(load_addr);

    let image = tr_image::host::pack(load_addr, entry, args.flags, &payload);

    if let Some(parent) = args.output.parent() {
        if !parent.as_os_str().is_empty() {
            fs::create_dir_all(parent).map_err(|e| format!("creating {}: {e}", parent.display()))?;
        }
    }
    fs::write(&args.output, &image).map_err(|e| format!("writing {}: {e}", args.output.display()))?;

    println!(
        "xtask image: wrote {} ({} header + {} payload bytes; load_addr={:#010x} entry={:#010x})",
        args.output.display(),
        tr_image::HEADER_LEN,
        payload.len(),
        load_addr,
        entry
    );
    Ok(())
}
