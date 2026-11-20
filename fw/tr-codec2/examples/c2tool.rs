// SPDX-License-Identifier: LGPL-2.1-only
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Host tool with the command line of upstream's `c2enc 700C` / `c2dec 700C`, for comparing the
//! two implementations (docs/FREEDV.md section 4).
//!
//! `c2tool enc in.raw out.c2` : 8 kHz 16-bit speech to 700C frames (4 bytes each)
//! `c2tool dec in.c2 out.raw` : 700C frames to 8 kHz 16-bit speech

use tr_codec2::{Decoder700c, Encoder700c, BYTES_PER_FRAME, SAMPLES_PER_FRAME};

fn main() {
    let a: Vec<String> = std::env::args().collect();
    assert!(a.len() == 4, "usage: c2tool enc|dec in out");
    let input = std::fs::read(&a[2]).unwrap();
    let mut out = Vec::new();
    match a[1].as_str() {
        "enc" => {
            let mut enc = Encoder700c::new();
            for f in input.chunks_exact(2 * SAMPLES_PER_FRAME) {
                let mut s = [0i16; SAMPLES_PER_FRAME];
                for (d, b) in s.iter_mut().zip(f.chunks_exact(2)) {
                    *d = i16::from_le_bytes([b[0], b[1]]);
                }
                out.extend_from_slice(&enc.encode(&s));
            }
        }
        "dec" => {
            let mut dec = Decoder700c::new();
            for f in input.chunks_exact(BYTES_PER_FRAME) {
                let mut s = [0i16; SAMPLES_PER_FRAME];
                dec.decode(f.try_into().unwrap(), &mut s);
                for v in s {
                    out.extend_from_slice(&v.to_le_bytes());
                }
            }
        }
        _ => panic!("enc or dec"),
    }
    std::fs::write(&a[3], out).unwrap();
}
