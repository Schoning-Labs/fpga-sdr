// SPDX-License-Identifier: LGPL-2.1-only
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Makes the signal files that the reference programs were run on for `tests/c_reference.rs`
//! (docs/FREEDV.md section 4, tests/vectors/README.md): raw 16-bit 8 kHz.
//!
//! `fdvnoise ch in.wav out.raw FOFF_HZ SNR_DB|none SEED SECONDS` : the first seconds of a recording through the
//! test channel (frequency shift, white noise)
//! `fdvnoise tf 700D|700E out.raw FOFF_HZ SNR_DB|none SEED SECONDS` : test frames from our modulator, through the channel
//! `fdvnoise tx 700D|700E speech.raw out.raw SECONDS` : speech and the text "cq cq cq hello world" from our encoder and modulator

#[path = "../tests/common/mod.rs"]
mod common;

use tr_freedv::{MODE_700D, MODE_700E};

fn mode(s: &str) -> &'static tr_freedv::ofdm::Mode {
    match s {
        "700D" => &MODE_700D,
        "700E" => &MODE_700E,
        _ => panic!("mode"),
    }
}

fn write_raw(path: &str, x: &[i16]) {
    let mut b = Vec::new();
    for v in x {
        b.extend_from_slice(&v.to_le_bytes());
    }
    std::fs::write(path, b).unwrap();
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let snr = |s: &str| if s == "none" { None } else { Some(s.parse::<f64>().unwrap()) };
    match a[1].as_str() {
        "ch" => {
            let mut r = hound::WavReader::open(&a[2]).unwrap();
            let x: Vec<i16> = r.samples::<i16>().map(|s| s.unwrap()).collect();
            let n = (a[7].parse::<usize>().unwrap() * 8000).min(x.len());
            write_raw(&a[3], &common::channel(&x[..n], a[4].parse().unwrap(), 1.0, snr(&a[5]), a[6].parse().unwrap()));
        }
        "tf" => {
            let x = common::test_frame_signal(mode(&a[2]), a[7].parse().unwrap());
            write_raw(&a[3], &common::channel(&x, a[4].parse().unwrap(), 0.5, snr(&a[5]), a[6].parse().unwrap()));
        }
        "tx" => {
            let speech: Vec<i16> = std::fs::read(&a[3]).unwrap().chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect();
            write_raw(&a[4], &common::speech_text_signal(mode(&a[2]), &speech, b"cq cq cq hello world\r", a[5].parse().unwrap()));
        }
        _ => panic!("ch, tf or tx"),
    }
}
