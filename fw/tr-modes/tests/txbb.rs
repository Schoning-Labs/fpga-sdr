// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Tests of the FT8 transmit baseband (`tr_modes::txbb`) against the decoder and against mfsk-core's own
//! synthesizer: tone sequence, waveform and sideband, a transmission that starts late, and a whole QSO decoded
//! from the generated audio. The repository holds no WSJT-X tone or waveform vectors, so there is no comparison
//! with WSJT-X's own output here.

use mfsk_core::engine::dsp::gfsk::{synth_f32, GfskCfg};
use tr_modes::txbb::{fields, tones, word_iq, Ft8Baseband, NSPS, NSYM, RATE, WAVE_LEN};

/// Generates a whole transmission from `bb` as I/Q pairs, filling the ring buffer words in uneven chunk sizes
/// (as the firmware does) and checking that exactly `WAVE_LEN` words come out.
fn whole(mut bb: Ft8Baseband) -> Vec<(i16, i16)> {
    let mut words = vec![0u32; WAVE_LEN];
    let mut done = 0;
    // In uneven chunks, as the firmware feeds the ring.
    for chunk in [1usize, 777, 4_096, 8_192, 1_000_000] {
        let end = (done + chunk).min(WAVE_LEN);
        done += bb.fill(&mut words[done..end]);
    }
    assert_eq!(done, WAVE_LEN);
    assert_eq!(bb.fill(&mut [0u32; 8]), 0);
    words.into_iter().map(word_iq).collect()
}

#[test]
fn tones_have_the_costas_blocks_and_match_the_packer() {
    let t = tones("CQ", "K1ABC", "FN42").unwrap();
    for start in [0, 36, 72] {
        assert_eq!(&t[start..start + 7], &[3, 1, 4, 0, 6, 5, 2]);
    }
    assert!(t.iter().all(|&x| x < 8));
    assert_ne!(t, tones("CQ", "K1ABC", "FN43").unwrap());
    assert!(tones("CQ", "NOT A CALL!", "FN42").is_none());
    assert_eq!(fields("K1ABC W9XYZ R-09"), Some(("K1ABC", "W9XYZ", "R-09")));
    assert_eq!(fields("K1ABC W9XYZ"), Some(("K1ABC", "W9XYZ", "")));
    assert_eq!(fields("CQ DX K1ABC FN42"), None);
}

#[test]
fn waveform_equals_mfsk_cores_synthesiser_and_is_upper_sideband() {
    let f0 = 1_234.0f32;
    let amp = 16_000i16;
    let t = tones("K1ABC", "W9XYZ", "R-09").unwrap();
    let iq = whole(Ft8Baseband::new(t, f0, amp));

    // Q is the audio WSJT-X would make: compare with mfsk-core's generator set to 48 ksps.
    let cfg = GfskCfg { sample_rate: RATE as f32, samples_per_symbol: NSPS, bt: 2.0, hmod: 1.0, ramp_samples: NSPS / 8 };
    let reference = synth_f32(&t, f0, amp as f32, &cfg);
    assert_eq!(reference.len(), WAVE_LEN);
    let (mut dot, mut e1, mut e2) = (0.0f64, 0.0f64, 0.0f64);
    for (k, r) in reference.iter().enumerate() {
        let q = iq[k].1 as f64;
        dot += q * *r as f64;
        e1 += q * q;
        e2 += (*r as f64) * (*r as f64);
    }
    let corr = dot / (e1 * e2).sqrt();
    assert!(corr > 0.999, "correlation with mfsk-core's waveform {corr}");

    // Constant envelope away from the ramps, zero at the very start and end.
    assert_eq!(iq[0], (0, 0));
    let last = iq[WAVE_LEN - 1];
    assert!(last.0.abs() <= 1 && last.1.abs() <= 1);
    for k in (NSPS..WAVE_LEN - NSPS).step_by(997) {
        let m = ((iq[k].0 as f64).powi(2) + (iq[k].1 as f64).powi(2)).sqrt();
        assert!((m - amp as f64).abs() < 2.0, "modulus {m} at {k}");
    }

    // Upper sideband: in the middle of symbol 40 the energy is at +(f0 + 6.25 tone), not at minus.
    let sym = 40;
    let f = f0 as f64 + 6.25 * t[sym] as f64;
    let (mut pos, mut neg) = ((0.0f64, 0.0f64), (0.0f64, 0.0f64));
    let (a, b) = (sym * NSPS + NSPS / 4, sym * NSPS + 3 * NSPS / 4);
    for k in a..b {
        let ph = std::f64::consts::TAU * f * k as f64 / RATE as f64;
        let (i, q) = (iq[k].0 as f64, iq[k].1 as f64);
        // (i + jq) * exp(-j ph) and (i + jq) * exp(+j ph)
        pos = (pos.0 + i * ph.cos() + q * ph.sin(), pos.1 + q * ph.cos() - i * ph.sin());
        neg = (neg.0 + i * ph.cos() - q * ph.sin(), neg.1 + q * ph.cos() + i * ph.sin());
    }
    let n = (b - a) as f64;
    let (p, m) = ((pos.0.powi(2) + pos.1.powi(2)).sqrt() / n, (neg.0.powi(2) + neg.1.powi(2)).sqrt() / n);
    assert!(p > 0.95 * amp as f64, "level at +f {p}");
    assert!(m < 0.02 * amp as f64, "level at -f {m}");
}

#[test]
fn a_late_start_keeps_its_place_in_time() {
    let t = tones("W9XYZ", "K1ABC", "RR73").unwrap();
    let full = whole(Ft8Baseband::new(t, 900.0, 12_000));
    let mut late = Ft8Baseband::new(t, 900.0, 12_000);
    late.skip(RATE as usize); // one second late
    assert_eq!(late.remaining(), WAVE_LEN - RATE as usize);
    let mut words = vec![0u32; 5_000];
    assert_eq!(late.fill(&mut words), 5_000);
    for (k, w) in words.iter().enumerate() {
        assert_eq!(word_iq(*w), full[RATE as usize + k]);
    }
}

/// The whole standard QSO, each message at its own audio frequency in one slot: encode at 48 ksps,
/// take the audio (Q) at 12 ksps, decode with the receiver's decoder.
#[test]
fn every_message_of_a_qso_decodes() {
    let messages = [
        ("CQ", "K1ABC", "FN42", 400.0f32),
        ("K1ABC", "W9XYZ", "EN37", 800.0),
        ("W9XYZ", "K1ABC", "-11", 1_200.0),
        ("K1ABC", "W9XYZ", "R-09", 1_600.0),
        ("W9XYZ", "K1ABC", "RR73", 2_000.0),
        ("K1ABC", "W9XYZ", "73", 2_400.0),
        ("W9XYZ", "K1ABC", "RRR", 2_800.0),
    ];
    let mut audio = vec![0i16; 180_000];
    let start = 6_000; // 0.5 s into the slot
    for (f1, f2, f3, hz) in messages {
        let iq = whole(Ft8Baseband::from_message(f1, f2, f3, hz, 3_000).unwrap());
        for k in 0..WAVE_LEN / 4 {
            audio[start + k] += iq[4 * k].1;
        }
    }
    let decoded = tr_modes::decode::ft8::decode_slot(&audio, 100.0, 3_100.0, 1.0, 50);
    for (f1, f2, f3, hz) in messages {
        let text = format!("{f1} {f2} {f3}");
        let d = decoded.iter().find(|d| d.message == text).unwrap_or_else(|| panic!("{text} not decoded; got {decoded:?}"));
        assert!((d.freq_hz - hz).abs() < 2.0, "{text}: decoded at {} Hz, sent at {hz}", d.freq_hz);
        assert!(d.dt_sec.abs() < 0.1, "{text}: dt {}", d.dt_sec);
    }
    assert_eq!(NSYM, 79);
}
