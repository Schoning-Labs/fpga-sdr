// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Build script of tr-ft8bench. It prepares the two files that the benchmark programs pull in with
//! `include_bytes!`: `trace.bin` is a copy of the trace named by `S15_TRACE` (written by `ft8-frontend trace`,
//! see tools/qemu_s15.sh), or an empty file when the variable is not set, so that a plain build still links;
//! and `sched.bin` packs the traces named by `S17_TRACES` for the scheduler benchmark (tools/qemu_s17.sh).

use std::env;
use std::fs;
use std::path::PathBuf;

/// Writes `trace.bin` and `sched.bin` into OUT_DIR and tells Cargo to rerun when their sources change.
fn main() {
    let out = PathBuf::from(env::var("OUT_DIR").unwrap()).join("trace.bin");
    match env::var("S15_TRACE") {
        Ok(p) if !p.is_empty() => {
            fs::copy(&p, &out).unwrap_or_else(|e| panic!("S15_TRACE={p}: {e}"));
            println!("cargo:rerun-if-changed={p}");
        }
        _ => fs::write(&out, []).unwrap(),
    }
    println!("cargo:rerun-if-env-changed=S15_TRACE");

    // The traces named by S17_TRACES (separated by ';') go into one file for the scheduler benchmark, as a
    // little-endian u32 count and then, for each trace, a u32 length followed by the bytes.
    let out = PathBuf::from(env::var("OUT_DIR").unwrap()).join("sched.bin");
    let mut v: Vec<u8> = Vec::new();
    let list = env::var("S17_TRACES").unwrap_or_default();
    let paths: Vec<&str> = list.split(';').filter(|p| !p.is_empty()).collect();
    v.extend_from_slice(&(paths.len() as u32).to_le_bytes());
    for p in paths {
        let b = fs::read(p).unwrap_or_else(|e| panic!("S17_TRACES {p}: {e}"));
        v.extend_from_slice(&(b.len() as u32).to_le_bytes());
        v.extend_from_slice(&b);
        println!("cargo:rerun-if-changed={p}");
    }
    fs::write(&out, v).unwrap();
    println!("cargo:rerun-if-env-changed=S17_TRACES");
}
