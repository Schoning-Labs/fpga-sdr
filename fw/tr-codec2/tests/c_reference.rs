// SPDX-License-Identifier: LGPL-2.1-only
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The 700C codec against the official C implementation (codec2 1.2.0, `c2enc 700C` and
//! `c2dec 700C`) without the C build: `tests/vectors/` holds what those programs made from
//! upstream's speech files; `tests/vectors/README.md` says how. Results and tolerances:
//! docs/FREEDV.md section 4.

use std::path::PathBuf;
use tr_codec2::{unpack_indexes, Decoder700c, Encoder700c, BYTES_PER_FRAME, SAMPLES_PER_FRAME};

fn vectors() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/vectors")
}

fn samples(bytes: &[u8]) -> Vec<i16> {
    bytes.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect()
}

/// The C decoder's output for a bit stream, sample by sample. Equal to within one step of the 16
/// bit output: float rounding (the two programs use different single precision functions). This
/// needed the harmonic count, the pitch and the excitation phase to be computed in double as the
/// C code does (found by this comparison; docs/FREEDV.md section 4): without that the samples
/// differ by thousands.
#[test]
fn decoder_matches_the_c_decoder() {
    for (bits_file, ref_file, frames) in [("hts1a.bit", "hts1a_dec.raw", 75), ("ve9qrp.bit", "ve9qrp_dec_6s.raw", 150)] {
        let bits = std::fs::read(vectors().join(bits_file)).unwrap();
        let reference = samples(&std::fs::read(vectors().join(ref_file)).unwrap());
        assert_eq!(reference.len(), frames * SAMPLES_PER_FRAME);
        let mut dec = Decoder700c::new();
        let (mut max, mut same, mut sq) = (0i32, 0usize, 0f64);
        for (f, c) in bits.chunks_exact(BYTES_PER_FRAME).take(frames).zip(reference.chunks_exact(SAMPLES_PER_FRAME)) {
            let mut out = [0i16; SAMPLES_PER_FRAME];
            dec.decode(f.try_into().unwrap(), &mut out);
            for (a, b) in out.iter().zip(c.iter()) {
                let d = *a as i32 - *b as i32;
                max = max.max(d.abs());
                same += (d == 0) as usize;
                sq += (d * d) as f64;
            }
        }
        let n = reference.len();
        let sig: f64 = reference.iter().map(|&v| (v as f64) * (v as f64)).sum();
        let snr = 10.0 * (sig / sq.max(1e-9)).log10();
        eprintln!("{bits_file}: {n} samples, largest difference {max}, identical {:.2} %, SNR of the difference {snr:.1} dB", 100.0 * same as f64 / n as f64);
        assert!(max <= 2);
        assert!(same * 100 >= n * 99);
        assert!(snr > 80.0);
    }
}

/// Our encoder on upstream's speech files against `c2enc 700C`: the quantiser indexes (the two
/// 9 bit vector quantiser stages, 4 bit energy, 6 bit pitch). Almost all frames are identical to
/// the bit; the few that differ (a pitch or an energy at a decision boundary, where the two
/// programs round differently) differ by one step.
#[test]
fn encoder_matches_the_c_encoder() {
    let captures = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../captures/freedv");
    for (speech_file, bits_file, max_differing_percent) in [("hts1a.raw", "hts1a.bit", 0.0), ("ve9qrp.raw", "ve9qrp.bit", 1.0)] {
        let Ok(speech) = std::fs::read(captures.join(speech_file)) else {
            eprintln!("skipped: captures/freedv/{speech_file} missing (run tools/fetch_freedv_test.sh)");
            continue;
        };
        let speech = samples(&speech);
        let reference = std::fs::read(vectors().join(bits_file)).unwrap();
        let mut enc = Encoder700c::new();
        let (mut frames, mut differing) = (0usize, 0usize);
        let mut index_equal = [0usize; 4];
        for (s, r) in speech.chunks_exact(SAMPLES_PER_FRAME).zip(reference.chunks_exact(BYTES_PER_FRAME)) {
            let ours = enc.encode(s.try_into().unwrap());
            frames += 1;
            let (a, b) = (unpack_indexes(&ours), unpack_indexes(r.try_into().unwrap()));
            for i in 0..4 {
                index_equal[i] += (a[i] == b[i]) as usize;
            }
            differing += (a != b) as usize;
            if a != b {
                assert!((a[2] as i32 - b[2] as i32).abs() <= 1, "energy index {} against {}", a[2], b[2]);
            }
        }
        assert_eq!(frames, reference.len() / BYTES_PER_FRAME);
        eprintln!("{speech_file}: {frames} frames, {differing} differ; indexes equal: {index_equal:?}");
        assert!(differing as f64 * 100.0 <= max_differing_percent * frames as f64 + 1e-9, "{differing} of {frames} frames differ");
    }
}
