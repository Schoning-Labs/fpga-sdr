// SPDX-License-Identifier: LGPL-2.1-only
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The receiver against the official C implementation (codec2 1.2.0, `freedv_rx`), without the C
//! build: `tests/vectors/` holds what `freedv_rx --vv` printed for each call (trace files, format
//! in `tools/fdvref/trace2bin.py`), the text it decoded, its error counts, and its first four
//! seconds of speech for the two sample signals. `tests/vectors/README.md` says how each was
//! made. The signals the C program was run on are rebuilt here: the FreeDV program's sample
//! recordings (`tools/fetch_freedv_test.sh`) through the fixed-seed channel and our modulator
//! (`tests/common`). Results and tolerances: docs/FREEDV.md section 4.

mod common;

use std::path::PathBuf;
use tr_freedv::ofdm::{Mode, SyncState};
use tr_freedv::varicode;
use tr_freedv::{Rx, MAX_NIN, MODE_700D, MODE_700E};

fn vectors() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/vectors")
}

fn captures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../captures/freedv")
}

fn read_wav(name: &str) -> Option<Vec<i16>> {
    let mut r = hound::WavReader::open(captures().join(name)).ok()?;
    assert_eq!(r.spec().sample_rate, 8000);
    Some(r.samples::<i16>().map(|s| s.unwrap()).collect())
}

fn read_raw(path: PathBuf) -> Option<Vec<i16>> {
    let bytes = std::fs::read(path).ok()?;
    Some(bytes.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect())
}

/// What the C program printed for one call (`--vv`), in the units it printed them.
#[derive(Debug, PartialEq)]
struct RefCall {
    nin: usize,
    flags: u8,
    state: u8,
    uw_errors: u8,
    iterations: u8,
    parity_checks: u8,
    /// 0.1 Hz
    foff: i16,
    /// 0.1 dB, 0 when the call decoded no frame
    snr: i16,
}

fn load_trace(name: &str) -> Vec<RefCall> {
    let b = std::fs::read(vectors().join(format!("{name}.trace"))).unwrap();
    b.chunks_exact(12)
        .map(|c| RefCall {
            nin: u16::from_le_bytes([c[0], c[1]]) as usize,
            flags: c[2],
            state: c[3],
            uw_errors: c[4],
            iterations: c[5],
            parity_checks: c[6],
            foff: i16::from_le_bytes([c[8], c[9]]),
            snr: i16::from_le_bytes([c[10], c[11]]),
        })
        .collect()
}

/// Our receiver, called the way `freedv_rx` calls its (`nin` samples per call, upstream's
/// pass-through gain, squelch off). Returns one record per call, the speech, the text channel,
/// and the receiver.
fn run(mode: &'static Mode, signal: &[i16], test_frames: bool) -> (Vec<RefCall>, Vec<i16>, Vec<u8>, Rx) {
    let mut rx = Rx::new(mode);
    rx.passthrough_gain = 0.25;
    rx.test_frames = test_frames;
    let (mut calls, mut speech_all, mut text) = (Vec::new(), Vec::new(), Vec::new());
    let mut vdec = varicode::Decoder::new();
    let mut speech = [0i16; MAX_NIN];
    let mut pos = 0;
    loop {
        let nin = rx.nin();
        if pos + nin > signal.len() {
            break;
        }
        let (st, n) = rx.rx(&signal[pos..pos + nin], &mut speech);
        pos += nin;
        speech_all.extend_from_slice(&speech[..n]);
        if st.bits {
            for &b in &rx.txt_bits[..mode.ntxtbits] {
                if let Some(c) = vdec.push_bit(b) {
                    text.push(c);
                }
            }
        }
        let s = rx.stats();
        calls.push(RefCall {
            nin: rx.ofdm.nin,
            flags: (st.bit_errors as u8) << 3 | (st.bits as u8) << 2 | (st.sync as u8) << 1 | st.trial_sync as u8,
            state: match rx.ofdm.last_sync_state {
                SyncState::Search => 0,
                SyncState::Trial => 1,
                SyncState::Synced => 2,
            },
            uw_errors: s.uw_errors as u8,
            iterations: if st.bits { s.ldpc.iterations as u8 } else { 0 },
            parity_checks: if st.bits { s.ldpc.parity_checks as u8 } else { 0 },
            foff: (rx.ofdm.foff_est_hz * 10.0).round() as i16,
            snr: if st.bits { (s.snr_db * 10.0).round() as i16 } else { 0 },
        });
    }
    (calls, speech_all, text, rx)
}

/// Compares the traces call by call. Exact: sync state, flags, unique word errors, the number of
/// samples asked for, decoder iterations and parity checks (in frames the decoder gives up on,
/// `give_up_ok`, only the iterations). Within the printed resolution: frequency offset (0.1 Hz).
/// SNR estimate: 0.1 dB, and only below 40 dB (above, the estimate divides by noise that is
/// nearly zero and differs by float rounding). Returns the number of frames compared.
fn compare_traces(label: &str, ours: &[RefCall], theirs: &[RefCall], give_up_ok: bool) -> usize {
    assert_eq!(ours.len(), theirs.len(), "{label}: number of calls");
    let mut frames = 0;
    for (i, (o, t)) in ours.iter().zip(theirs.iter()).enumerate() {
        assert_eq!((o.nin, o.flags, o.state, o.uw_errors), (t.nin, t.flags, t.state, t.uw_errors), "{label}: call {i}: {o:?} against {t:?}");
        assert!((o.foff - t.foff).abs() <= 1, "{label}: call {i}: frequency offset {} against {} (0.1 Hz)", o.foff, t.foff);
        if o.flags & 4 != 0 {
            frames += 1;
            let gave_up = t.iterations == 100;
            if !(give_up_ok && gave_up) {
                assert_eq!((o.iterations, o.parity_checks), (t.iterations, t.parity_checks), "{label}: call {i}: decoder");
            } else {
                assert_eq!(o.iterations, t.iterations, "{label}: call {i}: decoder iterations");
            }
            if t.snr < 400 {
                assert!((o.snr - t.snr).abs() <= 1, "{label}: call {i}: SNR {} against {} (0.1 dB)", o.snr, t.snr);
            }
        }
    }
    frames
}

/// Speech against the C program's: the same bits give the same samples to within float rounding.
fn compare_speech(label: &str, ours: &[i16], theirs: &[i16]) {
    assert!(ours.len() >= theirs.len(), "{label}: only {} samples", ours.len());
    let (mut max, mut same) = (0i32, 0usize);
    for (a, b) in ours.iter().zip(theirs.iter()) {
        let d = (*a as i32 - *b as i32).abs();
        max = max.max(d);
        same += (d == 0) as usize;
    }
    eprintln!("{label}: speech {} samples, largest difference {max}, identical {:.2} %", theirs.len(), 100.0 * same as f64 / theirs.len() as f64);
    assert!(max <= 2, "{label}: largest sample difference {max}");
    assert!(same * 100 >= theirs.len() * 99, "{label}: only {same} of {} samples identical", theirs.len());
}

fn text_of(name: &str) -> Vec<u8> {
    std::fs::read(vectors().join(format!("{name}.txt"))).unwrap()
}

/// The FreeDV program's sample recordings, whole (112 s): every call, the text, and the first 4 s
/// of speech. Exact: the decisions; within float rounding: the samples.
#[test]
fn sample_signals_match_the_c_receiver() {
    for (mode, wav, name) in [(&MODE_700D, "ve9qrp_700d.wav", "s700d"), (&MODE_700E, "ve9qrp_700e.wav", "s700e")] {
        let Some(x) = read_wav(wav) else {
            eprintln!("skipped: captures/freedv/{wav} missing (run tools/fetch_freedv_test.sh)");
            continue;
        };
        let (calls, speech, text, _) = run(mode, &x, false);
        let frames = compare_traces(name, &calls, &load_trace(name), false);
        eprintln!("{name}: {} calls, {frames} frames, all as the C receiver's", calls.len());
        assert_eq!(text, text_of(name), "{name}: text channel");
        compare_speech(name, &speech, &read_raw(vectors().join(format!("{name}_speech_4s.raw"))).unwrap());
    }
}

/// The same recordings through the test channel (frequency shift, white noise, fixed seed), 30 s:
/// two cases with noise that leave 6 to 15 % of the frames without a codeword, two shifted by 40
/// Hz without noise. The decisions of the two receivers must be the same in every call.
#[test]
fn noisy_and_shifted_signals_match_the_c_receiver() {
    // (mode, recording, case, shift Hz, SNR dB in 3 kHz, seed)
    let cases: [(&'static Mode, &str, &str, f64, Option<f64>, u64); 4] = [
        (&MODE_700D, "ve9qrp_700d.wav", "chd", -33.0, Some(1.0), 7),
        (&MODE_700E, "ve9qrp_700e.wav", "che", -35.0, Some(3.0), 8),
        (&MODE_700D, "ve9qrp_700d.wav", "ofd", -40.0, None, 0),
        (&MODE_700E, "ve9qrp_700e.wav", "ofe", 40.0, None, 0),
    ];
    for (mode, wav, name, foff, snr, seed) in cases {
        let Some(x) = read_wav(wav) else {
            eprintln!("skipped: captures/freedv/{wav} missing (run tools/fetch_freedv_test.sh)");
            continue;
        };
        let y = common::channel(&x[..30 * 8000], foff, 1.0, snr, seed);
        let (calls, _, text, _) = run(mode, &y, false);
        let theirs = load_trace(name);
        let frames = compare_traces(name, &calls, &theirs, false);
        let bad = theirs.iter().filter(|c| c.flags & 8 != 0).count();
        eprintln!("{name}: {frames} frames, {bad} without a codeword, identical call by call");
        assert_eq!(text, text_of(name), "{name}: text channel");
    }
}

/// Test frames from our modulator through the channel, read by the C receiver (`--testframes`) and
/// by ours. Frames the decoder cannot solve (100 iterations) may end in different bits, so those
/// are compared by flag and iteration count only and the coded error totals may differ a little;
/// the uncoded error count (it counts the unique word too) must be equal.
#[test]
fn test_frames_from_our_modulator_give_the_c_receivers_counts() {
    for (mode, name, foff, snr, seed) in [(&MODE_700D, "tfd", -25.0, 0.0, 9), (&MODE_700E, "tfe", -30.0, 3.0, 10)] {
        let x = common::test_frame_signal(mode, 30);
        let y = common::channel(&x, foff, 0.5, Some(snr), seed);
        let (calls, _, text, rx) = run(mode, &y, true);
        let frames = compare_traces(name, &calls, &load_trace(name), true);
        let counts = std::fs::read_to_string(vectors().join(format!("{name}.counts"))).unwrap();
        let get = |k: &str| -> u32 { counts.split_whitespace().find_map(|w| w.strip_prefix(&format!("{k}=")).map(|v| v.parse().unwrap())).unwrap() };
        let s = rx.stats();
        eprintln!(
            "{name}: {frames} frames; raw errors {} (C {}), coded errors {} (C {}) in {} packets, {} without a codeword (C {})",
            s.test_raw_errors,
            get("raw_errors"),
            s.test_coded_errors,
            get("coded_errors"),
            get("packets"),
            s.frames_with_errors,
            get("packet_errors")
        );
        assert_eq!(frames as u32, get("packets"));
        assert_eq!(s.test_raw_bits, get("raw_bits"));
        assert_eq!(s.test_raw_errors, get("raw_errors"));
        assert_eq!(s.test_coded_bits, get("coded_bits"));
        let (a, b) = (s.test_coded_errors as i64, get("coded_errors") as i64);
        assert!((a - b).abs() * 100 <= b.max(100) * 3, "coded errors {a} against {b}");
        assert_eq!(text, text_of(name));
    }
}

/// Speech and text from our encoder and modulator (clean, 10 s), read by the C receiver and by
/// ours: the C receiver finds every frame and the text, and the two traces are the same.
#[test]
fn signals_from_our_modulator_are_read_by_the_c_receiver() {
    let Some(speech) = read_raw(captures().join("ve9qrp_10s.raw")) else {
        eprintln!("skipped: captures/freedv/ve9qrp_10s.raw missing (run tools/fetch_freedv_test.sh)");
        return;
    };
    for (mode, name) in [(&MODE_700D, "txd"), (&MODE_700E, "txe")] {
        let x = common::speech_text_signal(mode, &speech, b"cq cq cq hello world\r", 10);
        let (calls, _, text, _) = run(mode, &x, false);
        let theirs = load_trace(name);
        let frames = compare_traces(name, &calls, &theirs, false);
        assert!(theirs.iter().all(|c| c.flags & 8 == 0), "the C receiver found a frame without a codeword");
        eprintln!("{name}: {frames} frames, the C receiver found all of them and no error");
        assert_eq!(text, text_of(name));
        assert!(text.starts_with(b"cq cq cq hello world\rcq cq cq"));
    }
}
