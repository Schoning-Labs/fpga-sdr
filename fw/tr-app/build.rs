// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

// The HL2's message-layer program (docs/HL2_CONTROL.md, "Updating the HL2's program"). When the
// environment variable HL2_MSG_BIN names the file (`msg.bin` of the HL2 repository, built by
// `firmware/hl2neo/build.py` there; `tools/hl2_msg_bin.sh` prints the lines to set), the feature
// `hl2-msg-load` is switched on and the firmware embeds the file with `include_bytes!`. The
// variable HL2_MSG_VERSION (hex, for example 0x00030001) is then required: it is the version the
// HL2's boot ROM writes into the saved header and the program reports in HELLO. This script
// computes the file's CRC-32 and writes both numbers to `$OUT_DIR/hl2_image.rs`; the firmware
// refuses to update the HL2 if the embedded bytes do not match that CRC. Without HL2_MSG_BIN the
// firmware builds as before and says on the console that the program is not built in. The image
// itself is never part of this repository.

use std::env;
use std::fs;
use std::path::Path;

/// The HL2 CPU's application RAM, 0x800 to 0x3FFF.
const MAX_IMAGE: u64 = 0x3800;

/// zlib CRC-32, as the HL2's boot ROM computes it.
fn crc32(data: &[u8]) -> u32 {
    let mut c = !0u32;
    for &b in data {
        c ^= b as u32;
        for _ in 0..8 {
            c = if c & 1 != 0 { (c >> 1) ^ 0xEDB8_8320 } else { c >> 1 };
        }
    }
    !c
}

fn main() {
    println!("cargo:rerun-if-env-changed=HL2_MSG_BIN");
    println!("cargo:rerun-if-env-changed=HL2_MSG_VERSION");
    let explicit = env::var_os("CARGO_FEATURE_HL2_MSG_LOAD").is_some();
    let out = Path::new(&env::var("OUT_DIR").unwrap()).join("hl2_image.rs");
    match env::var("HL2_MSG_BIN") {
        Ok(path) if !path.is_empty() => {
            println!("cargo:rerun-if-changed={path}");
            let bytes = fs::read(&path).unwrap_or_else(|e| panic!("HL2_MSG_BIN={path}: {e}"));
            let len = bytes.len() as u64;
            if len == 0 || len > MAX_IMAGE {
                panic!("HL2_MSG_BIN={path}: {len} bytes, the HL2 CPU's application RAM holds 1 to {MAX_IMAGE}");
            }
            let text = env::var("HL2_MSG_VERSION")
                .unwrap_or_else(|_| panic!("HL2_MSG_BIN is set, so HL2_MSG_VERSION must be too: the program's version in hex, for example 0x00030001"));
            let hex = text.trim().trim_start_matches("0x").trim_start_matches("0X");
            let version = u32::from_str_radix(hex, 16).unwrap_or_else(|_| panic!("HL2_MSG_VERSION={text}: not a 32-bit hex number"));
            let crc = crc32(&bytes);
            let code = format!(
                "/// Version of the embedded HL2 program (HL2_MSG_VERSION).\npub const HL2_MSG_VERSION: u32 = 0x{version:08X};\n\
                 /// CRC-32 of the embedded HL2 program, computed at build time.\npub const HL2_MSG_CRC32: u32 = 0x{crc:08X};\n"
            );
            fs::write(&out, code).unwrap();
            if !explicit {
                println!("cargo:rustc-cfg=feature=\"hl2-msg-load\"");
            }
        }
        _ if explicit => panic!("the feature hl2-msg-load needs HL2_MSG_BIN, the path of the HL2's msg.bin, and HL2_MSG_VERSION (tools/hl2_msg_bin.sh)"),
        _ => fs::write(&out, "").unwrap(),
    }
}
