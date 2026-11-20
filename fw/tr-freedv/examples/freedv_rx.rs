// SPDX-License-Identifier: LGPL-2.1-only
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Host harness: a recording of a FreeDV 700D or 700E signal in, decoded speech out.
//!
//! `cargo run --release -p tr-freedv --example freedv_rx -- 700D in.wav out.wav [--squelch dB] [--testframes]`
//!
//! The input is a mono 16-bit WAV at 8 or 12 kHz (12 kHz is converted as the firmware does), or
//! a headerless 16-bit 8 kHz `.raw` file. The output is 8 kHz speech. One line per second shows
//! sync state, SNR estimate, frequency offset and error counts.

use tr_freedv::resample::Resampler;
use tr_freedv::{RxStream, MODE_700D, MODE_700E};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("usage: freedv_rx 700D|700E in.wav|in.raw out.wav [--squelch dB] [--testframes]");
        std::process::exit(2);
    }
    let mode = match args[1].as_str() {
        "700D" | "700d" => &MODE_700D,
        "700E" | "700e" => &MODE_700E,
        m => panic!("unknown mode {m}"),
    };
    let mut input: Vec<i16> = if args[2].ends_with(".raw") {
        std::fs::read(&args[2]).unwrap().chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect()
    } else {
        let mut r = hound::WavReader::open(&args[2]).unwrap();
        let spec = r.spec();
        assert_eq!(spec.channels, 1, "mono input only");
        let x: Vec<i16> = r.samples::<i16>().map(|s| s.unwrap()).collect();
        match spec.sample_rate {
            8000 => x,
            12000 => {
                let mut y = Vec::new();
                Resampler::new_12k_to_8k().process(&x, |s| y.push(s));
                y
            }
            r => panic!("sample rate {r} not handled (8000 or 12000)"),
        }
    };
    input.extend(std::iter::repeat(0).take(4000));
    let mut rx = RxStream::new(mode);
    let mut i = 4;
    while i < args.len() {
        match args[i].as_str() {
            "--squelch" => {
                rx.rx.squelch = true;
                rx.rx.snr_squelch_db = args[i + 1].parse().unwrap();
                i += 1;
            }
            "--testframes" => rx.rx.test_frames = true,
            a => panic!("unknown option {a}"),
        }
        i += 1;
    }
    let mut out: Vec<i16> = Vec::new();
    let (mut speech_frames, mut frames) = (0u32, 0u32);
    for (sec, block) in input.chunks(8000).enumerate() {
        for part in block.chunks(160) {
            rx.push(part, |s, st| {
                out.extend_from_slice(s);
                frames += st.bits as u32;
                speech_frames += st.speech as u32;
            });
        }
        let s = rx.rx.stats();
        println!(
            "{sec:4} s  {:6?}  SNR {:5.1} dB  offset {:+6.1} Hz  UW errors {:2}  frames {:4}  with errors {:4}  clock {:+5.0} ppm",
            s.sync_state,
            s.snr_db,
            s.foff_hz,
            s.uw_errors,
            s.frames,
            s.frames_with_errors,
            s.clock_offset * 1e6
        );
    }
    let s = rx.rx.stats();
    println!("frames decoded: {frames}, to speech: {speech_frames}, with errors: {}", s.frames_with_errors);
    if rx.rx.test_frames {
        println!(
            "test frames: raw BER {:.5} ({}/{}), coded BER {:.5} ({}/{})",
            s.test_raw_errors as f64 / s.test_raw_bits.max(1) as f64,
            s.test_raw_errors,
            s.test_raw_bits,
            s.test_coded_errors as f64 / s.test_coded_bits.max(1) as f64,
            s.test_coded_errors,
            s.test_coded_bits
        );
    }
    let spec = hound::WavSpec { channels: 1, sample_rate: 8000, bits_per_sample: 16, sample_format: hound::SampleFormat::Int };
    let mut w = hound::WavWriter::create(&args[3], spec).unwrap();
    for v in out {
        w.write_sample(v).unwrap();
    }
    w.finalize().unwrap();
}
