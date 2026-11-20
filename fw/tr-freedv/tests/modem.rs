// SPDX-License-Identifier: LGPL-2.1-only
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Host tests of the FreeDV 700D / 700E receiver. What each proves is listed in docs/FREEDV.md.

mod ldpc_vectors;

mod common;
use common::{channel, Noise};
use std::path::PathBuf;
use tr_freedv::ldpc::{self, HRA_112_112, HRA_56_56};
use tr_freedv::ofdm::{Mode, SyncState, MODE_700D, MODE_700E};
use tr_freedv::resample::Resampler;
use tr_freedv::{Rx, RxStream, Tx};

fn captures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../captures/freedv")
}

fn read_raw(name: &str) -> Option<Vec<i16>> {
    let bytes = std::fs::read(captures().join(name)).ok()?;
    Some(bytes.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect())
}

fn write_wav(name: &str, samples: &[i16]) {
    let dir = captures().join("out");
    std::fs::create_dir_all(&dir).unwrap();
    let spec = hound::WavSpec { channels: 1, sample_rate: 8000, bits_per_sample: 16, sample_format: hound::SampleFormat::Int };
    let mut w = hound::WavWriter::create(dir.join(name), spec).unwrap();
    for &s in samples {
        w.write_sample(s).unwrap();
    }
    w.finalize().unwrap();
}

#[test]
fn ldpc_decodes_upstreams_test_vectors() {
    // The decoder input and the decoded codeword that ship with each code in codec2.
    for (code, input, want) in [
        (&HRA_112_112, &ldpc_vectors::HRA_112_112_INPUT[..], &ldpc_vectors::HRA_112_112_DETECTED[..]),
        (&HRA_56_56, &ldpc_vectors::HRA_56_56_INPUT[..], &ldpc_vectors::HRA_56_56_DETECTED[..]),
    ] {
        let mut dec = ldpc::Decoder::new();
        let mut out = [0u8; ldpc::MAX_CODE];
        let info = dec.decode(code, input, &mut out);
        assert_eq!(&out[..code.code_length], want, "{}", code.name);
        assert_eq!(info.parity_checks, code.parity_bits, "{}", code.name);
        // the hard decisions of the input are not already the codeword: the decoder did work
        let hard_errors = input.iter().zip(want).filter(|(l, w)| ((**l < 0.0) as u8) != **w).count();
        eprintln!("{}: {} iterations, {} input bits corrected", code.name, info.iterations, hard_errors);
        // and the decoded codeword satisfies our encoder
        let k = code.data_bits();
        let mut parity = [0u8; ldpc::MAX_PARITY];
        ldpc::encode(code, &out[..k], &mut parity[..code.parity_bits]);
        assert_eq!(&parity[..code.parity_bits], &out[k..code.code_length], "{} encoder", code.name);
    }
}

#[test]
fn ldpc_corrects_errors_and_reports_failure() {
    for code in [&HRA_112_112, &HRA_56_56] {
        let k = code.data_bits();
        let mut cw = [0u8; ldpc::MAX_CODE];
        for (i, b) in cw[..k].iter_mut().enumerate() {
            *b = ((i * 7 + i / 3) % 3 == 0) as u8;
        }
        let (data, parity) = cw.split_at_mut(k);
        ldpc::encode(code, data, &mut parity[..code.parity_bits]);
        let mut llr = [0.0f32; ldpc::MAX_CODE];
        for i in 0..code.code_length {
            llr[i] = if cw[i] == 1 { -4.0 } else { 4.0 };
        }
        // 6 % of the bits wrong with low confidence
        for i in (0..code.code_length).step_by(17) {
            llr[i] = -llr[i] * 0.3;
        }
        let mut dec = ldpc::Decoder::new();
        let mut out = [0u8; ldpc::MAX_CODE];
        let info = dec.decode(code, &llr, &mut out);
        assert_eq!(&out[..code.code_length], &cw[..code.code_length]);
        assert_eq!(info.parity_checks, code.parity_bits);
        // noise only: no codeword
        let mut n = Noise(3);
        for l in llr.iter_mut() {
            *l = n.gauss() as f32;
        }
        let info = dec.decode(code, &llr, &mut out);
        assert!(info.parity_checks < code.parity_bits, "{} decoded noise", code.name);
    }
}

/// Bit error counts of a test-frame run.
#[derive(Default, Clone, Copy)]
struct Errors {
    raw_errors: u32,
    raw_bits: u32,
    coded_errors: u32,
    coded_bits: u32,
}

/// Runs `signal` through a receiver in test-frame mode; returns the receiver, the number of
/// frames demodulated, and the bit errors counted from the first frame in confirmed sync on
/// (the frames of the trial phase can start before the signal does; the squelch mutes them).
fn run_test_frames(mode: &'static Mode, signal: &[i16]) -> (RxStream, usize, Errors) {
    let mut rx = RxStream::new(mode);
    rx.rx.test_frames = true;
    let mut frames = 0;
    let mut base: Option<Errors> = None;
    let mut before = Errors::default();
    for block in signal.chunks(333) {
        let mut confirmed = false;
        rx.push(block, |_, st| {
            frames += st.bits as usize;
            confirmed |= st.bits && !st.trial_sync;
        });
        if confirmed && base.is_none() {
            base = Some(before);
        }
        let s = rx.rx.stats();
        before = Errors { raw_errors: s.test_raw_errors, raw_bits: s.test_raw_bits, coded_errors: s.test_coded_errors, coded_bits: s.test_coded_bits };
    }
    let b = base.unwrap_or(before);
    let e = Errors {
        raw_errors: before.raw_errors - b.raw_errors,
        raw_bits: before.raw_bits - b.raw_bits,
        coded_errors: before.coded_errors - b.coded_errors,
        coded_bits: before.coded_bits - b.coded_bits,
    };
    (rx, frames, e)
}

/// The 700D signal of the upstream repository, made by the C transmitter with test frames
/// (`raw/testframes_700d.raw`, the input of upstream's own backwards-compatibility test).
#[test]
fn upstream_700d_test_signal_decodes_without_bit_errors() {
    let Some(mut x) = read_raw("testframes_700d.raw") else {
        eprintln!("skipped: captures/freedv/testframes_700d.raw missing (run tools/fetch_freedv_test.sh)");
        return;
    };
    // five frames of signal; silence after them lets the receiver work through its buffer
    x.extend(std::iter::repeat(0).take(3 * 1280));
    let (rx, frames, _) = run_test_frames(&MODE_700D, &x);
    let s = rx.rx.stats();
    eprintln!(
        "upstream 700D test signal: {frames} frames demodulated, raw errors {}/{}, coded errors {}/{}, foff {:.2} Hz",
        s.test_raw_errors, s.test_raw_bits, s.test_coded_errors, s.test_coded_bits, s.foff_hz
    );
    assert!(frames >= 1, "no frame demodulated");
    // The frames that lie wholly inside the signal must be free of errors before error
    // correction; the last calls run into the appended silence, so count the clean ones.
    let mut rx2 = RxStream::new(&MODE_700D);
    rx2.rx.test_frames = true;
    let mut clean = 0;
    let (mut last_raw, mut last_coded) = (0, 0);
    for block in x.chunks(160) {
        let mut got = false;
        rx2.push(block, |_, st| got |= st.bits);
        if got {
            let s = rx2.rx.stats();
            if s.test_raw_errors == last_raw && s.test_coded_errors == last_coded && s.ldpc.parity_checks == 112 {
                clean += 1;
            }
            last_raw = s.test_raw_errors;
            last_coded = s.test_coded_errors;
        }
    }
    eprintln!("  frames with 0 of 224 raw bit errors and all 112 parity checks met: {clean}");
    assert!(clean >= 1, "no frame of the upstream signal decoded cleanly");
}

struct Case {
    mode: &'static Mode,
    foff: f64,
    snr: Option<f64>,
    gain: f64,
    /// Highest coded bit error rate accepted, and lowest fraction of the sent frames decoded.
    max_coded_ber: f64,
    min_frames: f64,
}

/// Test frames from our modulator through the channel into the receiver, at stated SNR,
/// frequency offset and level.
#[test]
fn test_frames_round_trip_over_snr_frequency_offset_and_level() {
    let cases = [
        Case { mode: &MODE_700D, foff: 0.0, snr: None, gain: 1.0, max_coded_ber: 0.0, min_frames: 0.9 },
        Case { mode: &MODE_700E, foff: 0.0, snr: None, gain: 1.0, max_coded_ber: 0.0, min_frames: 0.9 },
        Case { mode: &MODE_700D, foff: 11.3, snr: None, gain: 0.05, max_coded_ber: 0.0, min_frames: 0.9 },
        Case { mode: &MODE_700E, foff: -17.6, snr: None, gain: 0.05, max_coded_ber: 0.0, min_frames: 0.9 },
        Case { mode: &MODE_700D, foff: 47.0, snr: Some(10.0), gain: 0.5, max_coded_ber: 0.0, min_frames: 0.9 },
        Case { mode: &MODE_700D, foff: -52.0, snr: Some(10.0), gain: 0.5, max_coded_ber: 0.0, min_frames: 0.9 },
        Case { mode: &MODE_700E, foff: 38.0, snr: Some(10.0), gain: 0.5, max_coded_ber: 0.0, min_frames: 0.9 },
        Case { mode: &MODE_700D, foff: -10.0, snr: Some(3.0), gain: 0.5, max_coded_ber: 1e-3, min_frames: 0.85 },
        Case { mode: &MODE_700E, foff: -10.0, snr: Some(5.0), gain: 0.5, max_coded_ber: 1e-3, min_frames: 0.85 },
        Case { mode: &MODE_700D, foff: -10.0, snr: Some(0.0), gain: 0.5, max_coded_ber: 0.02, min_frames: 0.8 },
        Case { mode: &MODE_700E, foff: -10.0, snr: Some(2.0), gain: 0.5, max_coded_ber: 0.06, min_frames: 0.8 },
    ];
    for (n, c) in cases.iter().enumerate() {
        let tx = Tx::new(c.mode);
        let spf = tx.samples_per_frame();
        let nframes = 160_000 / spf; // 20 s
        let mut sig = vec![0i16; 2000];
        let mut frame = vec![0i16; spf];
        for _ in 0..nframes {
            tx.tx_test_frame(&mut frame);
            sig.extend_from_slice(&frame);
        }
        let y = channel(&sig, c.foff, c.gain, c.snr, 100 + n as u64);
        let y = if std::env::var("FDV_VIA_12K").is_ok() {
            let mut y12 = Vec::new();
            Resampler::new_8k_to_12k().process(&y, |s| y12.push(s));
            let mut y8 = Vec::new();
            Resampler::new_12k_to_8k().process(&y12, |s| y8.push(s));
            y8
        } else {
            y
        };
        let (rx, frames, e) = run_test_frames(c.mode, &y);
        let s = rx.rx.stats();
        let raw = e.raw_errors as f64 / e.raw_bits.max(1) as f64;
        let coded = e.coded_errors as f64 / e.coded_bits.max(1) as f64;
        eprintln!(
            "{} foff {:+6.1} Hz snr {:>5} level {:4.2}: {frames}/{nframes} frames, raw BER {raw:.4}, coded BER {coded:.5}, est foff {:+6.1} Hz",
            c.mode.name,
            c.foff,
            c.snr.map(|v| format!("{v:.0} dB")).unwrap_or("none".into()),
            c.gain,
            s.foff_hz
        );
        assert!(frames as f64 >= c.min_frames * nframes as f64, "case {n}: only {frames} of {nframes} frames");
        assert!(coded <= c.max_coded_ber, "case {n}: coded BER {coded}");
    }
}

/// The indicators: sync state, frequency offset and SNR estimate on a known channel; no sync
/// and no speech on noise alone.
#[test]
fn indicators_follow_the_channel_and_noise_alone_gives_no_sync() {
    for (mode, foff, snr) in [(&MODE_700D, 23.0, 8.0), (&MODE_700E, -31.0, 8.0)] {
        let tx = Tx::new(mode);
        let spf = tx.samples_per_frame();
        let mut sig = Vec::new();
        let mut frame = vec![0i16; spf];
        for _ in 0..(80_000 / spf) {
            tx.tx_test_frame(&mut frame);
            sig.extend_from_slice(&frame);
        }
        let y = channel(&sig, foff, 0.5, Some(snr), 7);
        let (rx, _, _) = run_test_frames(mode, &y);
        let s = rx.rx.stats();
        eprintln!("{}: state {:?}, foff {:+.1} Hz (sent {foff:+.1}), SNR {:.1} dB (sent {snr:.1})", mode.name, s.sync_state, s.foff_hz, s.snr_db);
        assert_eq!(s.sync_state, SyncState::Synced);
        assert!((s.foff_hz as f64 - foff).abs() < 1.0);
        assert!((s.snr_db as f64 - snr).abs() < 3.0);
    }
    // noise only, squelch on: never solid sync, no speech
    for mode in [&MODE_700D, &MODE_700E] {
        let mut n = Noise(11);
        let y: Vec<i16> = (0..160_000).map(|_| (3000.0 * n.gauss()) as i16).collect();
        let mut rx = RxStream::new(mode);
        rx.rx.squelch = true;
        let (mut speech, mut synced) = (0, 0);
        for block in y.chunks(400) {
            rx.push(block, |_, st| {
                speech += st.speech as usize;
                synced += (st.sync && !st.trial_sync) as usize;
            });
        }
        eprintln!("{} on noise: {synced} frames in solid sync, {speech} frames of speech", mode.name);
        assert_eq!(speech, 0, "{} decoded speech from noise", mode.name);
    }
}

/// Speech of the upstream repository: encoder, modulator, channel (12 Hz off, 6 dB SNR, and the
/// radio's 12 kHz audio rate in between), receiver, decoder. The decoded bits must equal the
/// encoder's; the speech is written for listening.
#[test]
fn speech_round_trip_through_the_whole_chain() {
    let Some(speech) = read_raw("ve9qrp_10s.raw") else {
        eprintln!("skipped: captures/freedv/ve9qrp_10s.raw missing (run tools/fetch_freedv_test.sh)");
        return;
    };
    for mode in [&MODE_700D, &MODE_700E] {
        let mut tx = Tx::new(mode);
        let (spf, nspeech) = (tx.samples_per_frame(), tx.speech_per_frame());
        let mut sig = vec![0i16; 1500];
        let mut frame = vec![0i16; spf];
        // the bits the transmitter's encoder makes, from a second encoder on the same speech
        let mut enc = tr_codec2::Encoder700c::new();
        let mut sent: Vec<Vec<u8>> = Vec::new();
        for chunk in speech.chunks_exact(nspeech) {
            tx.tx_speech(chunk, &mut frame);
            sig.extend_from_slice(&frame);
            let mut bits = Vec::new();
            for f in chunk.chunks_exact(320) {
                let bytes = enc.encode(f.try_into().unwrap());
                bits.extend((0..28).map(|n| (bytes[n >> 3] >> (7 - (n & 7))) & 1));
            }
            sent.push(bits);
        }
        let y = channel(&sig, 12.0, 0.5, Some(6.0), 21);
        // up to the radio's 12 kHz and back down, as the firmware will get it
        let mut y12 = Vec::new();
        Resampler::new_8k_to_12k().process(&y, |s| y12.push(s));
        let mut y8 = Vec::new();
        Resampler::new_12k_to_8k().process(&y12, |s| y8.push(s));
        if std::env::var("FDV_NO_RESAMPLE").is_ok() {
            y8 = y.clone();
        }

        let mut rx = RxStream::new(mode);
        let mut out = Vec::new();
        let mut frames = 0;
        let mut errors = 0;
        rx.rx.squelch = true;
        rx.rx.snr_squelch_db = -2.0;
        let mut got: Vec<Vec<u8>> = Vec::new();
        let k = mode.code.data_bits();
        for block in y8.chunks(256) {
            let mut n = 0;
            rx.push(block, |s, st| {
                if st.speech {
                    out.extend_from_slice(s);
                    frames += 1;
                    errors += st.bit_errors as usize;
                    n += 1;
                }
            });
            // blocks are shorter than a modem frame, so at most one frame per block
            if n > 0 {
                got.push(rx.rx.payload_bits[..k].to_vec());
            }
        }
        // Frames whose decoded bits are exactly the bits sent. The receiver starts a few frames
        // in. The first second is left out of the hard figure: 700E corrects a left-over
        // frequency error of the 1 Hz search grid by at most 0.1 Hz per frame (upstream's
        // limiter), and until then frames at this SNR can fail.
        let d = (0..8).max_by_key(|d| got.iter().enumerate().filter(|(i, g)| sent.get(i + d) == Some(*g)).count()).unwrap();
        let bad: Vec<usize> = got.iter().enumerate().filter(|(i, g)| sent.get(i + d) != Some(*g)).map(|(i, _)| i).collect();
        let first_second = 8000 / spf;
        let late_bad = bad.iter().filter(|&&i| i >= first_second).count();
        eprintln!(
            "{}: {} of {} received frames carry exactly the encoder's bits; not exact: {bad:?} ({late_bad} after the first second)",
            mode.name,
            got.len() - bad.len(),
            got.len()
        );
        assert!(late_bad * 50 <= got.len(), "{late_bad} frames after the first second not bit exact");
        let s = rx.rx.stats();
        eprintln!(
            "{} speech: {frames} of {} frames decoded to speech, {errors} of them with errors, SNR est {:.1} dB, foff {:+.1} Hz",
            mode.name,
            speech.len() / nspeech,
            s.snr_db,
            s.foff_hz
        );
        write_wav(&format!("roundtrip_{}_ve9qrp_6dB.wav", mode.name), &out);
        write_wav(&format!("roundtrip_{}_ve9qrp_6dB_modem_signal.wav", mode.name), &y8);
        assert!(frames * 10 >= speech.len() / nspeech * 9);
        // "with errors" means the error correction did not settle on a codeword; the data bits
        // can still all be right (the count of exact frames above is the hard figure)
        assert!(errors * 5 <= frames, "{errors} frames with errors");
        // the decoded speech has the loudness contour of the input (40 ms steps, any delay)
        let env = |v: &[i16]| -> Vec<f32> {
            v.chunks_exact(320).map(|c| (c.iter().map(|&s| (s as f32).powi(2)).sum::<f32>() / 320.0 + 1.0).log10() * 10.0).collect()
        };
        let (ea, eb) = (env(&speech), env(&out));
        let mut best = f32::MIN;
        for lag in 0..40 {
            let n = ea.len().min(eb.len()) - 40;
            let (a, b) = (&ea[lag..lag + n], &eb[..n]);
            let (ma, mb) = (a.iter().sum::<f32>() / n as f32, b.iter().sum::<f32>() / n as f32);
            let cov: f32 = a.iter().zip(b).map(|(p, q)| (p - ma) * (q - mb)).sum();
            let va: f32 = a.iter().map(|p| (p - ma).powi(2)).sum();
            let vb: f32 = b.iter().map(|q| (q - mb).powi(2)).sum();
            best = best.max(cov / (va * vb).sqrt());
        }
        eprintln!("  loudness contour correlation with the input speech: {best:.3}");
        assert!(best > 0.65);
    }
}

/// A sender whose sample clock is 200 ppm off ours: the receiver slips its frame timing and
/// stays in sync.
#[test]
fn receiver_follows_a_sample_clock_offset() {
    for mode in [&MODE_700D, &MODE_700E] {
        let tx = Tx::new(mode);
        let spf = tx.samples_per_frame();
        let mut sig = Vec::new();
        let mut frame = vec![0i16; spf];
        for _ in 0..(480_000 / spf) {
            tx.tx_test_frame(&mut frame);
            sig.extend_from_slice(&frame);
        }
        // linear interpolation at 1 + 200e-6 samples per sample
        let ratio = 1.0 + 200e-6;
        let mut y = Vec::new();
        let mut t = 0.0f64;
        while (t as usize) + 1 < sig.len() {
            let i = t as usize;
            let f = t - i as f64;
            y.push((sig[i] as f64 * (1.0 - f) + sig[i + 1] as f64 * f) as i16);
            t += ratio;
        }
        let (rx, frames, e) = run_test_frames(mode, &y);
        let s = rx.rx.stats();
        let coded = e.coded_errors as f64 / e.coded_bits.max(1) as f64;
        eprintln!("{} at 200 ppm: {frames} frames, coded BER {coded:.5}, clock offset estimate {:.0} ppm", mode.name, s.clock_offset * 1e6);
        assert_eq!(s.sync_state, SyncState::Synced);
        assert!(coded < 1e-3);
        assert!(frames * spf * 10 >= y.len() * 9);
    }
}

fn read_wav(name: &str) -> Option<Vec<i16>> {
    let mut r = hound::WavReader::open(captures().join(name)).ok()?;
    assert_eq!(r.spec().sample_rate, 8000);
    Some(r.samples::<i16>().map(|s| s.unwrap()).collect())
}

/// The sample signals that ship with the FreeDV program (freedv-gui `wav/ve9qrp_700d.wav` and
/// `ve9qrp_700e.wav`): 112 s of speech sent by the C implementation's transmitter (its codec
/// encoder, clipper and band-pass filter). Our receiver must hold sync throughout and the error
/// correction must settle on a codeword in every frame, which it cannot do unless carriers,
/// pilots, unique word, interleaver and code agree with the sender's. The decoded speech is
/// written for listening. The decoded codec bits are also compared with what our own encoder
/// makes of the same speech (`raw/ve9qrp.raw`): the two encoders run on different arithmetic, so
/// this is reported, not asserted bit for bit.
#[test]
fn freedv_program_sample_signals_decode() {
    for (mode, file) in [(&MODE_700D, "ve9qrp_700d.wav"), (&MODE_700E, "ve9qrp_700e.wav")] {
        let Some(x) = read_wav(file) else {
            eprintln!("skipped: captures/freedv/{file} missing (run tools/fetch_freedv_test.sh)");
            continue;
        };
        let mut rx = RxStream::new(mode);
        rx.rx.squelch = true;
        rx.rx.snr_squelch_db = -2.0;
        let k = mode.code.data_bits();
        let mut out = Vec::new();
        let mut got: Vec<Vec<u8>> = Vec::new();
        let (mut frames, mut errors, mut lost_sync) = (0, 0, 0);
        let mut was_synced = false;
        for block in x.chunks(160) {
            let mut n = 0;
            rx.push(block, |s, st| {
                out.extend_from_slice(s);
                if st.bits && !st.trial_sync {
                    frames += 1;
                    errors += st.bit_errors as usize;
                    n += 1;
                }
                if was_synced && !st.sync {
                    lost_sync += 1;
                }
                was_synced = st.sync;
            });
            if n > 0 {
                got.push(rx.rx.payload_bits[..k].to_vec());
            }
        }
        let s = rx.rx.stats();
        let sent_frames = x.len() / mode.samples_per_frame();
        eprintln!(
            "{file}: {frames} of {sent_frames} frames in confirmed sync, {errors} without a codeword, sync lost {lost_sync} times, SNR est {:.1} dB, offset {:+.2} Hz, clock {:+.0} ppm",
            s.snr_db,
            s.foff_hz,
            s.clock_offset * 1e6
        );
        write_wav(&format!("decoded_{}", file), &out);
        assert!(frames * 100 >= sent_frames * 97, "{file}: only {frames} of {sent_frames} frames");
        assert_eq!(errors, 0, "{file}: frames without a codeword");
        assert_eq!(lost_sync, 0, "{file}: sync lost");

        // our encoder on the same speech, field by field
        if let Some(speech) = read_raw("ve9qrp.raw") {
            let mut enc = tr_codec2::Encoder700c::new();
            let ours: Vec<[usize; 4]> = speech.chunks_exact(320).map(|f| enc.encode_indexes(f.try_into().unwrap())).collect();
            let theirs: Vec<[usize; 4]> = got
                .iter()
                .flat_map(|bits| {
                    bits.chunks_exact(28)
                        .map(|b| {
                            let v = |r: std::ops::Range<usize>| r.fold(0usize, |a, i| (a << 1) | b[i] as usize);
                            [v(0..9), v(9..18), v(18..22), v(22..28)]
                        })
                        .collect::<Vec<_>>()
                })
                .collect();
            let mut best = (0usize, [0usize; 4], 0usize);
            for d in 0..40 {
                let n = theirs.len().min(ours.len().saturating_sub(d));
                let mut m = [0usize; 4];
                for i in 0..n {
                    for f in 0..4 {
                        m[f] += (theirs[i][f] == ours[i + d][f]) as usize;
                    }
                }
                if m.iter().sum::<usize>() > best.1.iter().sum::<usize>() {
                    best = (d, m, n);
                }
            }
            let (d, m, n) = best;
            let pct = |v: usize| 100.0 * v as f64 / n.max(1) as f64;
            eprintln!(
                "  against our encoder ({n} codec frames, ours {d} frames ahead): first VQ stage equal {:.1} %, second {:.1} %, energy {:.1} %, pitch/voicing {:.1} %",
                pct(m[0]),
                pct(m[1]),
                pct(m[2]),
                pct(m[3])
            );
        }
    }
}

#[test]
fn rx_struct_sizes_are_small_enough_for_the_firmware() {
    let rx = std::mem::size_of::<Rx>();
    let tx = std::mem::size_of::<Tx>();
    eprintln!("Rx {rx} bytes, Tx {tx} bytes");
    assert!(rx < 80_000);
}
