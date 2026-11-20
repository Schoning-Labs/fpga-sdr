// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Tests of the FT8 front-end model that run under `cargo test`.
//!
//! - On the WSJT-X sample recordings (fetched by `tools/fetch_test_audio.sh`, skipped without them) the fixed point
//!   front end decodes at least as many messages as mfsk-core's own single pass pipeline at the same candidate
//!   count, and every message that mfsk-core finds.
//! - A recorded fabric trace replayed to the CPU half gives the same decodes as the live model, which is what
//!   tools/qemu_s15.sh relies on for the instruction count.
//! - The second pass (subtract the decoded signals and decode the residual) finds a signal hidden under a
//!   stronger one.
//!
//! The comparison of the fixed point and floating point sensitivity (about 0.3 dB apart) takes minutes of CPU time
//! and is therefore the `ft8-frontend sweep` tool and not a unit test. Its results are in docs/S15_FT8MODEL.md.

use std::path::{Path, PathBuf};

use mfsk_core::ft8::wave_gen::{message_to_tones, tones_to_f32};
use mfsk_core::ft8::Ft8;
use mfsk_core::msg::decode_request::DecodeRequest;
use mfsk_core::msg::wsjt77::{pack77, unpack77};
use tr_modes::frontend::decode::{decode_slot, DecodeParams, ModelFabric, Recording};
use tr_modes::frontend::trace::{write_trace, TraceFabric};
use tr_modes::frontend::{Arith, SLOT_LEN};

/// Reports a skipped test on the real standard error, because the test harness hides what a passing test prints
/// with `eprintln!` and a missing `captures/` folder would otherwise look like a pass. Setting
/// `TR_REQUIRE_RECORDINGS=1` turns the skip into a failure.
fn skipped(what: &str) {
    use std::io::Write;
    let name = std::thread::current().name().unwrap_or("?").to_string();
    let _ = writeln!(std::io::stderr(), "SKIPPED {name}: {what} -- run tools/fetch_test_audio.sh");
    assert!(std::env::var_os("TR_REQUIRE_RECORDINGS").is_none(), "recordings missing and TR_REQUIRE_RECORDINGS is set");
}

/// The `captures/` folder at the repository root.
fn captures_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../captures")
}

/// Reads a WAV file's `data` chunk as 16-bit samples padded with zeros to one 15 s slot, or `None` when the file
/// is missing or has no data.
fn load_wav_i16(path: &Path) -> Option<Vec<i16>> {
    let bytes = std::fs::read(path).ok()?;
    if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return None;
    }
    let mut i = 12usize;
    let (mut off, mut len) = (0usize, 0usize);
    while i + 8 <= bytes.len() {
        let l = u32::from_le_bytes(bytes[i + 4..i + 8].try_into().ok()?) as usize;
        if &bytes[i..i + 4] == b"data" {
            off = i + 8;
            len = l.min(bytes.len() - off);
        }
        i += 8 + l + (l & 1);
    }
    if off == 0 {
        return None;
    }
    let mut v: Vec<i16> = bytes[off..off + len].chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect();
    v.resize(SLOT_LEN, 0);
    Some(v)
}

/// Message texts decoded from one slot by the fixed point model fabric.
fn model_messages(audio: &[i16], p: &DecodeParams) -> Vec<String> {
    let mut fab = ModelFabric::new(Arith::Fixed);
    decode_slot(&mut fab, audio, p, &|| 0).0.iter().filter_map(|d| unpack77(d.result.message77())).collect()
}

#[test]
fn wsjtx_samples_at_least_mfsk_core() {
    for name in ["qso3_busy", "qso1", "qso2"] {
        let path = captures_dir().join(format!("ft8/{name}.wav"));
        let Some(audio) = load_wav_i16(&path) else {
            skipped(&format!("{name}: not found"));
            continue;
        };
        let p = DecodeParams { max_cand: 30, ..DecodeParams::default() };
        let base: Vec<String> = DecodeRequest::<Ft8>::new(&audio, p.freq_min, p.freq_max, p.sync_min, p.max_cand)
            .decode()
            .results
            .into_iter()
            .filter_map(|r| unpack77(r.message77()))
            .collect();
        let ours = model_messages(&audio, &p);
        eprintln!("{name}, 30 candidates: mfsk-core {}, fixed-point front end {}", base.len(), ours.len());
        assert!(ours.len() >= base.len(), "{name}: {} decodes, mfsk-core {}", ours.len(), base.len());
        for m in &base {
            assert!(ours.contains(m), "{name}: mfsk-core decodes {m:?}, the front end does not");
        }
    }
}

/// With the second pass, `qso3_busy.wav` gives all eight of WSJT-X's own reference decodes (the list in
/// tests/wsjtx_samples.rs), which a single pass of either decoder does not.
#[test]
fn qso3_busy_two_passes_has_all_wsjtx_reference_decodes() {
    const WSJTX_GOLDEN: &[&str] = &[
        "CQ F5RXL IN94",
        "N1JFU EA6EE R-07",
        "A92EE F5PSR -14",
        "W0RSJ EA3BMU RR73",
        "K1JT HA0DU KN07",
        "N1PJT HB9CQK -10",
        "K1BZM DK8NE -10",
        "KD2UGC F6GCP R-23",
    ];
    let path = captures_dir().join("ft8/qso3_busy.wav");
    let Some(audio) = load_wav_i16(&path) else {
        skipped("recording not found");
        return;
    };
    let p = DecodeParams { max_cand: 60, passes: 2, ..DecodeParams::default() };
    let ours = model_messages(&audio, &p);
    eprintln!("qso3_busy, 60 candidates, two passes: {} decodes", ours.len());
    for m in WSJTX_GOLDEN {
        assert!(ours.iter().any(|x| x == m), "missing WSJT-X reference decode {m:?}");
    }
}

/// Adds the FT8 signal "CQ <call> <grid>" at `f0` Hz with amplitude `amp`, starting at sample `start`, to `mix`,
/// and returns its message text.
fn synth(mix: &mut [f32], call: &str, grid: &str, f0: f32, amp: f32, start: usize) -> String {
    let msg = pack77("CQ", call, grid).unwrap();
    let pcm = tones_to_f32(&message_to_tones(&msg), f0, amp);
    for (i, &v) in pcm.iter().enumerate() {
        if start + i < mix.len() {
            mix[start + i] += v;
        }
    }
    format!("CQ {call} {grid}")
}

/// Adds Gaussian noise of standard deviation `sigma` LSB to `mix` (seeded, so runs repeat) and quantizes to `i16`.
fn noisy(mix: &[f32], sigma: f32, seed: u64) -> Vec<i16> {
    let mut st = seed;
    let mut gauss = || {
        let mut u = || {
            st = st.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
            ((st >> 11) as f64 + 1.0) / (1u64 << 53) as f64
        };
        let (a, b) = (u(), u());
        ((-2.0 * a.ln()).sqrt() * (2.0 * std::f64::consts::PI * b).cos()) as f32
    };
    mix.iter().map(|&s| (s + sigma * gauss()).round().clamp(-32_768.0, 32_767.0) as i16).collect()
}

/// A weak signal 12.5 Hz from a strong one with the same timing: the first pass decodes the strong one, and the
/// second pass, after subtracting it, decodes the weak one.
#[test]
fn second_pass_finds_the_hidden_signal() {
    let mut mix = vec![0f32; SLOT_LEN];
    let strong = synth(&mut mix, "JA1ABC", "PM95", 1_200.0, 1_500.0, 6_000);
    let weak = synth(&mut mix, "K1JT", "FN20", 1_212.5, 90.0, 6_000);
    let audio = noisy(&mix, 300.0, 3);
    let one = DecodeParams { freq_min: 1_000.0, freq_max: 1_400.0, max_cand: 20, ..DecodeParams::default() };
    let two = DecodeParams { passes: 2, ..one };
    let m1 = model_messages(&audio, &one);
    let m2 = model_messages(&audio, &two);
    eprintln!("one pass: {m1:?}; two passes: {m2:?}");
    assert!(m1.contains(&strong) && !m1.contains(&weak));
    assert!(m2.contains(&strong) && m2.contains(&weak));
}

/// Recording the fixed-point fabric and replaying the trace gives the same decodes.
#[test]
fn trace_replay_matches_live_model() {
    let mut mix = vec![0f32; SLOT_LEN];
    synth(&mut mix, "W1AW", "FN31", 900.0, 300.0, 7_000);
    synth(&mut mix, "DL1AAA", "JO52", 1_500.0, 200.0, 5_500);
    let audio = noisy(&mix, 1_000.0, 9);
    let p = DecodeParams { freq_min: 700.0, freq_max: 1_700.0, max_cand: 20, passes: 2, ..DecodeParams::default() };
    let mut fab = ModelFabric::new(Arith::Fixed);
    fab.recording = Some(Recording::default());
    let live: Vec<Vec<u8>> = decode_slot(&mut fab, &audio, &p, &|| 0).0.iter().map(|d| d.result.message77().to_vec()).collect();
    let bytes = write_trace(&audio, &p, fab.recording.as_ref().unwrap());
    let (mut tf, a2, p2) = TraceFabric::open(&bytes);
    assert_eq!(a2, audio);
    let replay: Vec<Vec<u8>> = decode_slot(&mut tf, &a2, &p2, &|| 0).0.iter().map(|d| d.result.message77().to_vec()).collect();
    assert_eq!(live.len(), 2);
    assert_eq!(live, replay);
}
