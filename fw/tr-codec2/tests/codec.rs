// SPDX-License-Identifier: LGPL-2.1-only
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Host tests of the 700C codec. None of them compares with the C implementation's output (the
//! upstream repository holds no encoded files or expected decoder output); see docs/FREEDV.md
//! section "What is proven".

use std::path::PathBuf;
use tr_codec2::{newamp1, pack_indexes, unpack_indexes, Decoder700c, Encoder700c, SAMPLES_PER_FRAME};

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

/// Pitch period (samples) by autocorrelation over 20..=160: the shortest lag whose peak is
/// within 15 % of the highest (a multiple of the period scores as high as the period itself).
fn pitch_period(x: &[f32]) -> usize {
    let r: Vec<f32> = (0..=161)
        .map(|lag| (0..x.len() - lag).map(|i| x[i] * x[i + lag]).sum::<f32>() / (x.len() - lag) as f32)
        .collect();
    let max = r[20..=160].iter().cloned().fold(f32::MIN, f32::max);
    for lag in 20..=160 {
        if r[lag] >= 0.85 * max && r[lag] >= r[lag - 1] && r[lag] >= r[lag + 1] {
            return lag;
        }
    }
    0
}

#[test]
fn bit_packing_is_msb_first_9_9_4_6() {
    let idx = [0x155usize, 0x0f3, 0xa, 0x2d];
    let bytes = pack_indexes(&idx);
    // 101010101 011110011 1010 101101
    assert_eq!(bytes, [0b1010_1010, 0b1011_1100, 0b1110_1010, 0b1101_0000]);
    assert_eq!(unpack_indexes(&bytes), idx);
}

#[test]
fn pitch_quantiser_round_trip_and_range() {
    // index 1 is the lowest voiced pitch, 63 the highest; 6 bits, logarithmic, 50 to 400 Hz
    let lo = newamp1::decode_log_wo(1) * 8000.0 / (2.0 * std::f32::consts::PI);
    let hi = newamp1::decode_log_wo(63) * 8000.0 / (2.0 * std::f32::consts::PI);
    assert!((lo - 51.65).abs() < 0.1, "{lo}");
    assert!((hi - 387.2).abs() < 0.5, "{hi}");
    for i in 1..64 {
        assert_eq!(newamp1::encode_log_wo(newamp1::decode_log_wo(i)), i);
    }
}

#[test]
fn mel_axis_runs_200_to_3700_hz() {
    let f = newamp1::mel_sample_freqs_khz();
    assert!((f[0] - 0.2).abs() < 0.002 && (f[19] - 3.7).abs() < 0.01, "{f:?}");
    assert!(f.windows(2).all(|w| w[1] > w[0]));
}

#[test]
fn a_voiced_frame_decodes_to_the_pitch_and_level_it_names() {
    // Any vector quantiser entry, energy index 10 (35 dB), pitch index 32.
    let mut dec = Decoder700c::new();
    let mut out = Vec::new();
    let mut speech = [0i16; SAMPLES_PER_FRAME];
    for _ in 0..12 {
        dec.decode_indexes(&[3, 7, 10, 32], &mut speech);
        out.extend(speech.iter().map(|&s| s as f32));
    }
    let tail = &out[out.len() - 1600..];
    let period = pitch_period(tail);
    let expect = 2.0 * std::f32::consts::PI / newamp1::decode_log_wo(32);
    assert!((period as f32 - expect).abs() <= 1.0, "period {period}, expected {expect}");
    let rms = (tail.iter().map(|v| v * v).sum::<f32>() / tail.len() as f32).sqrt();
    assert!(rms > 300.0 && rms < 20000.0, "rms {rms}");

    // 6 dB more in the energy field (2.5 dB per step) is 6 dB more out, within the postfilter's play
    let mut dec = Decoder700c::new();
    let mut out2 = Vec::new();
    for _ in 0..12 {
        dec.decode_indexes(&[3, 7, 14, 32], &mut speech);
        out2.extend(speech.iter().map(|&s| s as f32));
    }
    let tail2 = &out2[out2.len() - 1600..];
    let rms2 = (tail2.iter().map(|v| v * v).sum::<f32>() / tail2.len() as f32).sqrt();
    let db = 20.0 * (rms2 / rms).log10();
    assert!((db - 10.0).abs() < 1.0, "{db} dB for 10 dB in the energy field");
}

#[test]
fn an_unvoiced_frame_is_noise_and_silence_stays_bounded() {
    let mut dec = Decoder700c::new();
    let mut speech = [0i16; SAMPLES_PER_FRAME];
    let mut out = Vec::new();
    for _ in 0..12 {
        dec.decode_indexes(&[100, 200, 8, 0], &mut speech);
        out.extend(speech.iter().map(|&s| s as f32));
    }
    let tail = &out[out.len() - 1600..];
    // no strong periodicity: normalised autocorrelation peak well below 1
    let e: f32 = tail.iter().map(|v| v * v).sum();
    let p = pitch_period(tail);
    let r: f32 = (0..tail.len() - p).map(|i| tail[i] * tail[i + p]).sum::<f32>() / e;
    assert!(r < 0.5, "unvoiced frame looks periodic: r = {r}");
}

/// A synthetic vowel: pulse train at `f0` through two resonators.
fn vowel(f0: f32, n: usize) -> Vec<i16> {
    let mut x = vec![0.0f32; n];
    let period = 8000.0 / f0;
    let mut t = 0.0f32;
    while (t as usize) < n {
        x[t as usize] = 1.0;
        t += period;
    }
    for &(fc, bw) in &[(700.0f32, 130.0f32), (1220.0, 170.0), (2600.0, 250.0)] {
        let r = (-std::f32::consts::PI * bw / 8000.0).exp();
        let c = 2.0 * r * (2.0 * std::f32::consts::PI * fc / 8000.0).cos();
        let (mut y1, mut y2) = (0.0f32, 0.0f32);
        for v in x.iter_mut() {
            let y = *v + c * y1 - r * r * y2;
            y2 = y1;
            y1 = y;
            *v = y;
        }
    }
    let peak = x.iter().fold(0.0f32, |a, &b| a.max(b.abs()));
    x.iter().map(|v| (v / peak * 8000.0) as i16).collect()
}

#[test]
fn encoder_finds_pitch_and_voicing_of_a_synthetic_vowel_and_the_decoder_gives_it_back() {
    for &f0 in &[100.0f32, 125.0, 180.0, 240.0] {
        let x = vowel(f0, 8000);
        let mut enc = Encoder700c::new();
        let mut dec = Decoder700c::new();
        let mut out = Vec::new();
        let mut speech = [0i16; SAMPLES_PER_FRAME];
        let mut last = [0usize; 4];
        for frame in x.chunks_exact(SAMPLES_PER_FRAME) {
            let idx = enc.encode_indexes(frame.try_into().unwrap());
            last = idx;
            dec.decode_indexes(&idx, &mut speech);
            out.extend(speech.iter().map(|&s| s as f32));
        }
        assert!(last[3] != 0, "f0 {f0}: frame not voiced");
        let got = newamp1::decode_log_wo(last[3]) * 8000.0 / (2.0 * std::f32::consts::PI);
        assert!((got / f0 - 1.0).abs() < 0.04, "f0 {f0}: encoder says {got}");
        let period = pitch_period(&out[out.len() - 2400..]);
        assert!((period as f32 - 8000.0 / f0).abs() <= 2.0, "f0 {f0}: decoded period {period}");
    }
}

/// Band energies in dB of `x` over 8 bands up to 4 kHz, long-term.
fn band_profile(x: &[f32]) -> [f32; 8] {
    let n = 256;
    let mut acc = [0.0f64; 8];
    for frame in x.chunks_exact(n) {
        for b in 0..8 {
            for k in (b * 16)..((b + 1) * 16) {
                let (mut re, mut im) = (0.0f64, 0.0f64);
                for (i, &v) in frame.iter().enumerate() {
                    let a = -2.0 * std::f64::consts::PI * (k * i) as f64 / n as f64;
                    re += v as f64 * a.cos();
                    im += v as f64 * a.sin();
                }
                acc[b] += re * re + im * im;
            }
        }
    }
    let mut out = [0.0f32; 8];
    for b in 0..8 {
        out[b] = 10.0 * (acc[b] + 1e-9).log10() as f32;
    }
    out
}

/// Speech of the upstream repository through our encoder and our decoder. Checks what can be
/// checked without the C program: the loudness contour follows the input, the long-term spectrum
/// has the input's shape, and voiced speech stays voiced. Writes the result for listening.
#[test]
fn upstream_speech_through_encoder_and_decoder() {
    let mut done = 0;
    for name in ["hts1a", "ve9qrp_10s"] {
        let Some(x) = read_raw(&format!("{name}.raw")) else {
            eprintln!("skipped: captures/freedv/{name}.raw missing (run tools/fetch_freedv_test.sh)");
            continue;
        };
        let mut enc = Encoder700c::new();
        let mut dec = Decoder700c::new();
        let mut out: Vec<i16> = Vec::new();
        let mut speech = [0i16; SAMPLES_PER_FRAME];
        let mut voiced = 0;
        let mut frames = 0;
        for frame in x.chunks_exact(SAMPLES_PER_FRAME) {
            let bits = enc.encode(frame.try_into().unwrap());
            voiced += (unpack_indexes(&bits)[3] != 0) as usize;
            frames += 1;
            dec.decode(&bits, &mut speech);
            out.extend_from_slice(&speech);
        }
        write_wav(&format!("codec_roundtrip_{name}_700c.wav"), &out);

        // loudness contour, 40 ms frames; the codec delays by about one frame
        let env = |v: &[i16]| -> Vec<f32> {
            v.chunks_exact(320).map(|c| (c.iter().map(|&s| (s as f32).powi(2)).sum::<f32>() / 320.0 + 1.0).log10() * 10.0).collect()
        };
        let (ea, eb) = (env(&x), env(&out));
        let mut best = f32::MIN;
        for lag in 0..4 {
            let n = ea.len() - 4;
            let (a, b) = (&ea[..n], &eb[lag..lag + n]);
            let (ma, mb) = (a.iter().sum::<f32>() / n as f32, b.iter().sum::<f32>() / n as f32);
            let cov: f32 = a.iter().zip(b).map(|(p, q)| (p - ma) * (q - mb)).sum();
            let va: f32 = a.iter().map(|p| (p - ma).powi(2)).sum();
            let vb: f32 = b.iter().map(|q| (q - mb).powi(2)).sum();
            best = best.max(cov / (va * vb).sqrt());
        }
        assert!(best > 0.85, "{name}: loudness contour correlation {best}");

        let xa: Vec<f32> = x.iter().map(|&s| s as f32).collect();
        let xb: Vec<f32> = out.iter().map(|&s| s as f32).collect();
        let (pa, pb) = (band_profile(&xa), band_profile(&xb));
        // compare shape over 0.5 to 3.5 kHz (bands 1..=6), level removed
        let d: Vec<f32> = (1..7).map(|b| pb[b] - pa[b]).collect();
        let mean = d.iter().sum::<f32>() / d.len() as f32;
        let worst = d.iter().map(|v| (v - mean).abs()).fold(0.0f32, f32::max);
        eprintln!("{name}: {frames} frames, {voiced} voiced, contour r = {best:.3}, level {mean:+.1} dB, band shape within {worst:.1} dB");
        assert!(worst < 8.0, "{name}: long-term spectrum differs by {worst} dB in a band: {d:?}");
        assert!(mean.abs() < 8.0, "{name}: level differs by {mean} dB");
        assert!(voiced * 5 > frames, "{name}: only {voiced} of {frames} frames voiced");
        done += 1;
    }
    eprintln!("{done} of 2 recordings run");
}
