// SPDX-License-Identifier: LGPL-2.1-only
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Host tool with the behaviour of upstream's `freedv_rx 700D|700E in out.raw` for comparing the
//! two receivers (docs/FREEDV.md section 4): raw 16-bit 8 kHz in (or a 8 kHz mono WAV), raw
//! speech out, the same calls with the same `nin`, and one trace line per call in the format of
//! upstream's `--vv` output (`st`, `euw`, `sync_counter`, frequency offset, SNR, iterations,
//! parity checks, flags).
//!
//! `fdvtrace 700D in.raw out.raw [--squelch dB] [--testframes] [--trace file]`

use std::fmt::Write as _;
use tr_freedv::{Rx, MAX_NIN, MODE_700D, MODE_700E};

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let mode = match a[1].as_str() {
        "700D" => &MODE_700D,
        "700E" => &MODE_700E,
        m => panic!("mode {m}"),
    };
    let input: Vec<i16> = if a[2].ends_with(".wav") {
        let mut r = hound::WavReader::open(&a[2]).unwrap();
        assert_eq!(r.spec().sample_rate, 8000);
        r.samples::<i16>().map(|s| s.unwrap()).collect()
    } else {
        std::fs::read(&a[2]).unwrap().chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect()
    };
    let mut rx = Rx::new(mode);
    rx.passthrough_gain = 0.25; // upstream's default
    let mut trace_path = None;
    let mut txt_path = None;
    let mut i = 4;
    while i < a.len() {
        match a[i].as_str() {
            "--squelch" => {
                rx.squelch = true;
                rx.snr_squelch_db = a[i + 1].parse().unwrap();
                i += 1;
            }
            "--testframes" => rx.test_frames = true,
            "--txt" => {
                txt_path = Some(a[i + 1].clone());
                i += 1;
            }
            "--trace" => {
                trace_path = Some(a[i + 1].clone());
                i += 1;
            }
            o => panic!("option {o}"),
        }
        i += 1;
    }
    let (mut out, mut trace) = (Vec::<u8>::new(), String::new());
    let (mut pos, mut printed, mut calls, mut nout_total) = (0usize, 0usize, 0usize, 0usize);
    let mut speech = [0i16; MAX_NIN];
    let (mut prev_raw, mut prev_coded) = (0u32, 0u32);
    let mut vdec = tr_freedv::varicode::Decoder::new();
    let mut text = Vec::<u8>::new();
    loop {
        let nin = rx.nin();
        if pos + nin > input.len() {
            break;
        }
        let (st, mut n) = rx.rx(&input[pos..pos + nin], &mut speech);
        pos += nin;
        calls += 1;
        if rx.squelch && !st.speech {
            n = 0; // upstream outputs no samples when squelched; ours outputs zeros
        }
        for v in &speech[..n] {
            out.extend_from_slice(&v.to_le_bytes());
        }
        nout_total += n;
        if st.bits {
            let bits = rx.txt_bits;
            for &b in &bits[..mode.ntxtbits] {
                if let Some(c) = vdec.push_bit(b) {
                    text.push(c);
                }
            }
        }
        let s = rx.stats();
        let (de, dc) = (s.test_raw_errors - prev_raw, s.test_coded_errors - prev_coded);
        prev_raw = s.test_raw_errors;
        prev_coded = s.test_coded_errors;
        let flags = format!(
            "{}{}{}{}",
            if st.bit_errors { 'E' } else { '-' },
            if st.bits { 'B' } else { '-' },
            if st.sync { 'S' } else { '-' },
            if st.trial_sync { 'T' } else { '-' }
        );
        // upstream prints a line for every call with bits or bit errors, and (verbose 2) for the
        // others; the state shown is the one before the state machine ran
        let name = match rx.ofdm.last_sync_state {
            tr_freedv::ofdm::SyncState::Search => "search",
            tr_freedv::ofdm::SyncState::Trial => "trial",
            tr_freedv::ofdm::SyncState::Synced => "synced",
        };
        let _ = writeln!(
            trace,
            "{printed:3} nin: {:4} st: {name:<6} euw: {:2} {:2} f: {:5.1} snr: {:4.1} eraw: {de:4} ecdd: {dc:4} iter: {:3} pcc: {:4} rxst: {flags}",
            rx.ofdm.nin, s.uw_errors, rx.ofdm.sync_counter, rx.ofdm.foff_est_hz, s.snr_db, s.ldpc.iterations, s.ldpc.parity_checks
        );
        printed += 1;
    }
    std::fs::write(&a[3], out).unwrap();
    if let Some(p) = trace_path {
        std::fs::write(p, trace).unwrap();
    }
    if let Some(p) = txt_path {
        std::fs::write(p, &text).unwrap();
    }
    let s = rx.stats();
    eprintln!("frames decoded: {calls}  output speech samples: {nout_total}");
    if rx.test_frames {
        eprintln!("BER......: {:5.4}  Tbits: {:8}  Terrs: {:8}", s.test_raw_errors as f64 / s.test_raw_bits as f64, s.test_raw_bits, s.test_raw_errors);
        eprintln!("Coded BER: {:5.4}  Tbits: {:8}  Terrs: {:8}", s.test_coded_errors as f64 / s.test_coded_bits as f64, s.test_coded_bits, s.test_coded_errors);
    }
}
