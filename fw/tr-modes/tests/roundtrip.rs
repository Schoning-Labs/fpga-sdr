// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Encode and decode round trip for FT8, FT4 and WSPR. A message is synthesized with `tr_modes::encode`, passed
//! straight to `tr_modes::decode` without any channel impairment, and the text must come back exactly. This
//! checks function and says nothing about sensitivity. It needs no external file and therefore always runs,
//! unlike the WSJT-X sample tests in `wsjtx_samples.rs`, which skip when `captures/` is missing.

#[test]
fn ft8_roundtrip() {
    let pcm = tr_modes::encode::ft8::encode_i16("CQ", "JA1ABC", "PM95", 1500.0, 20_000)
        .expect("valid FT8 message");
    // FT8 messages start 0.5 s into the 15 s slot (`Ft8::TX_START_OFFSET_S`), and the rest of the slot is silence.
    let mut audio = vec![0i16; 180_000];
    let start = (0.5 * 12_000.0) as usize;
    let end = (start + pcm.len()).min(audio.len());
    audio[start..end].copy_from_slice(&pcm[..end - start]);

    let decoded = tr_modes::decode::ft8::decode_slot(&audio, 100.0, 3000.0, 1.0, 50);
    assert!(
        decoded.iter().any(|d| d.message == "CQ JA1ABC PM95"),
        "expected \"CQ JA1ABC PM95\" among decodes, got {decoded:?}"
    );
}

#[test]
fn ft4_roundtrip() {
    let pcm = tr_modes::encode::ft4::encode_i16("CQ", "JA1ABC", "PM95", 1500.0, 20_000)
        .expect("valid FT4 message");
    let mut audio = vec![0i16; 90_000];
    let start = (0.5 * 12_000.0) as usize;
    let end = (start + pcm.len()).min(audio.len());
    audio[start..end].copy_from_slice(&pcm[..end - start]);

    let decoded = tr_modes::decode::ft4::decode_slot(&audio, 100.0, 3000.0, 1.0, 50);
    assert!(
        decoded.iter().any(|d| d.message == "CQ JA1ABC PM95"),
        "expected \"CQ JA1ABC PM95\" among decodes, got {decoded:?}"
    );
}

#[test]
fn wspr_roundtrip() {
    let audio = tr_modes::encode::wspr::encode_f32("K1ABC", "FN42", 37, 1500.0, 0.3)
        .expect("valid WSPR message");
    // WSPR starts 1 s into its 120 s slot, and the encoder emits one transmission of about 110.6 s (162 symbols of
    // 8192 samples at 12 kHz), so both ends are padded with silence out to a full slot.
    let mut slot = vec![0f32; 120 * 12_000];
    let start = 12_000usize; // 1 s
    let end = (start + audio.len()).min(slot.len());
    slot[start..end].copy_from_slice(&audio[..end - start]);

    let params = tr_modes::decode::wspr::SearchParams {
        freq_min_hz: 1400.0,
        freq_max_hz: 1600.0,
        ..Default::default()
    };
    let decoded = tr_modes::decode::wspr::decode_slot(&slot, 12_000, 0, &params);
    assert!(
        decoded.iter().any(|d| d.message == "K1ABC FN42 37"),
        "expected \"K1ABC FN42 37\" among decodes, got {decoded:?}"
    );
}
