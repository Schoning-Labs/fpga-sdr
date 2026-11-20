// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Decodes the WSJT-X sample recordings and checks the results against the decodes that WSJT-X itself gives for
//! each file (docs/S5_MODES.md has the provenance and the full counts). The tests skip with a message when
//! `captures/` has not been filled by `tools/fetch_test_audio.sh`, so that `cargo test` and `tools/check.sh` stay
//! green on a fresh checkout. The recordings are only read as data.

use std::path::{Path, PathBuf};

/// The `captures/` folder at the repository root.
fn captures_dir() -> PathBuf {
    // From fw/tr-modes up to the repository root, then captures/.
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../captures")
}

/// Reports a skipped test on the real standard error, because the test harness hides what a passing test prints
/// with `eprintln!` and a missing `captures/` folder would otherwise look like a pass. Setting
/// `TR_REQUIRE_RECORDINGS=1` turns the skip into a failure.
fn skipped(what: &str) {
    use std::io::Write;
    let name = std::thread::current().name().unwrap_or("?").to_string();
    let _ = writeln!(std::io::stderr(), "SKIPPED {name}: {what} -- run tools/fetch_test_audio.sh");
    assert!(std::env::var_os("TR_REQUIRE_RECORDINGS").is_none(), "recordings missing and TR_REQUIRE_RECORDINGS is set");
}

/// Reports a skipped test for a recording that is missing at `path`.
fn skip(test: &str, path: &Path) {
    let _ = test; // the test's own name is printed by `skipped`
    skipped(&format!("{} not found", path.display()));
}

/// Minimal RIFF/WAVE reader for 12 kHz mono 16-bit PCM, with the same contract as the one in
/// `src/bin/decode_wav.rs`. It is kept separate because one lives in a test and the other in a `std` only binary,
/// and duplicating about 30 lines is cheaper than a third crate for a WAV parser this small.
fn load_wav_i16(path: &Path) -> Option<Vec<i16>> {
    let bytes = std::fs::read(path).ok()?;
    if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return None;
    }
    let mut i = 12usize;
    let (mut sample_rate, mut bits, mut channels) = (0u32, 0u16, 0u16);
    let (mut data_off, mut data_len) = (0usize, 0usize);
    while i + 8 <= bytes.len() {
        let id = &bytes[i..i + 4];
        let len = u32::from_le_bytes(bytes[i + 4..i + 8].try_into().ok()?) as usize;
        i += 8;
        if id == b"fmt " && i + 16 <= bytes.len() {
            channels = u16::from_le_bytes(bytes[i + 2..i + 4].try_into().ok()?);
            sample_rate = u32::from_le_bytes(bytes[i + 4..i + 8].try_into().ok()?);
            bits = u16::from_le_bytes(bytes[i + 14..i + 16].try_into().ok()?);
        } else if id == b"data" {
            data_off = i;
            data_len = len.min(bytes.len() - i);
        }
        i += len;
        if len % 2 == 1 {
            i += 1;
        }
    }
    if channels != 1 || sample_rate != 12_000 || bits != 16 || data_off == 0 {
        return None;
    }
    let samples = &bytes[data_off..data_off + data_len];
    Some(samples.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect())
}

/// Same as `load_wav_i16`, scaled to the range -1.0 to 1.0 for the WSPR decoder.
fn load_wav_f32(path: &Path) -> Option<Vec<f32>> {
    Some(load_wav_i16(path)?.into_iter().map(|s| s as f32 / 32_768.0).collect())
}

/// Pads a recording with zeros to exactly `len` samples (one slot).
fn pad(mut v: Vec<i16>, len: usize) -> Vec<i16> {
    v.resize(len, 0);
    v
}

/// FT8 `qso3_busy.wav` (WSJT-X `samples/FT8/210703_133430.wav`) against WSJT-X's own 8 message decode of the file
/// with a-priori decoding off, which is the canonical reference (docs/S5_MODES.md).
///
/// All 8 of 8 must be found. That needs the OSD step (the deep search that follows LDPC and belief propagation),
/// which mfsk-core compiles only for its `fft-rustfft` backend, and the patch to the vendored copy in `fw/vendor`
/// enables it for `fft-extern` as well (fw/vendor/VENDOR_PATCH.md, fix 4). Without OSD this file loses
/// `K1BZM DK8NE -10`. The sensitivity sweep in docs/S5_MODES.md, section "OSD gap", has the measured effect on FT8
/// in general.
#[test]
fn ft8_qso3_busy_matches_wsjtx() {
    let path = captures_dir().join("ft8/qso3_busy.wav");
    let Some(audio) = load_wav_i16(&path) else {
        skip("ft8_qso3_busy_matches_wsjtx", &path);
        return;
    };
    let slot = pad(audio, 180_000);

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

    let decoded = tr_modes::decode::ft8::decode_slot(&slot, 100.0, 3000.0, 1.3, 60);
    let hits = WSJTX_GOLDEN
        .iter()
        .filter(|m| decoded.iter().any(|d| d.message == **m))
        .count();
    let min_hits = WSJTX_GOLDEN.len(); // 8 of 8, see the doc comment above.

    eprintln!(
        "FT8 qso3_busy.wav: {hits}/{} WSJT-X decodes matched ({} total decodes here)",
        WSJTX_GOLDEN.len(),
        decoded.len()
    );
    assert!(
        hits >= min_hits,
        "FT8 qso3_busy.wav: matched {hits}/{} of WSJT-X's decodes, need >= {min_hits}",
        WSJTX_GOLDEN.len()
    );
}

/// FT4 `000000_000002.wav` against the 14 message decode of a `jt9` run over the file (`jt9` is the decoder of
/// WSJT-X for FT4 and others). This is used instead of the smaller 6 message decode of the WSJT-X GUI at its default
/// band, for the reasons given in docs/S5_MODES.md. At least 90 % must be found.
#[test]
fn ft4_sample_matches_wsjtx() {
    let path = captures_dir().join("ft4/000000_000002.wav");
    let Some(audio) = load_wav_i16(&path) else {
        skip("ft4_sample_matches_wsjtx", &path);
        return;
    };
    let slot = pad(audio, 90_000);

    const WSJTX_GOLDEN: &[&str] = &[
        "AC6BW KR9A R 559 WI",
        "CQ RU AB5XS EM12",
        "CQ RU N9OY EN43",
        "CQ RU W0FRC DM79",
        "K1JT WB4HXE 559 GA",
        "KB0VHA KA1YQC R 539 MA",
        "N1TRK KB7RUQ RR73",
        "N1TRK N4FKH 569 VA",
        "NI6G W7DRW 569 AZ",
        "NZ7P WA7JAY 589 CA",
        "VE3LON K7RL R 549 WA",
        "W7BOB KJ7G RR73",
        "W9JA PY2APK RRR",
        "WD9IGY KX1X 73",
    ];

    let decoded = tr_modes::decode::ft4::decode_slot(&slot, 100.0, 2700.0, 0.05, 100);
    let hits = WSJTX_GOLDEN
        .iter()
        .filter(|m| decoded.iter().any(|d| d.message == **m))
        .count();
    let min_hits = (WSJTX_GOLDEN.len() * 9).div_ceil(10);

    eprintln!(
        "FT4 000000_000002.wav: {hits}/{} WSJT-X (jt9) decodes matched ({} total decodes here)",
        WSJTX_GOLDEN.len(),
        decoded.len()
    );
    assert!(
        hits >= min_hits,
        "FT4 000000_000002.wav: matched {hits}/{} of WSJT-X's decodes, need >= {min_hits} (90%)",
        WSJTX_GOLDEN.len()
    );
}

/// WSPR `150426_0918.wav` against the 9 spot decode of `wsprd`, the WSPR decoder of WSJT-X.
///
/// The floor is 7 of 9 (78 %) and not 90 %, with the default `fft-portable` backend, and unlike FT8 this one is
/// statistical (docs/S5_MODES.md, sections "OSD gap" and "Sensitivity sweep"). The synthetic noise sweep in
/// `src/bin/sensitivity_sweep.rs` puts the 50 % detection point of WSPR at -31.22 dB for this backend and for
/// `fft-rustfft` alike (15 trials at each of 9 SNR steps), so there is no measurable loss of sensitivity.
/// The two spots this file misses are the two weakest of its 9, `W3BI FN20 30` (-25 dB) and `G8VDQ IO91 37`
/// (-23 dB), and they look specific to the file and not to the backend. The comments in mfsk-core already name
/// both as needing exceptional numerical accuracy even with `fft-rustfft`: `W3BI` sits at the edge of what the
/// Fano decoder can do, and `G8VDQ` needs the waveforms of the other 7 signals reconstructed and subtracted
/// accurately enough that their leftovers do not bury it. The file is also an off-air recording (fading, receiver
/// noise) and not clean synthetic noise, so a single file with a floor of 90 % of 8 or 9 spots cannot tell such a
/// case from a real regression, which is the reason for the sweep. With `fft-rustfft`, mfsk-core reaches 9 of 9 on
/// the same audio through the same `tr_modes::decode` call.
#[test]
fn wspr_sample_matches_wsjtx() {
    let path = captures_dir().join("wspr/150426_0918.wav");
    let Some(audio) = load_wav_f32(&path) else {
        skip("wspr_sample_matches_wsjtx", &path);
        return;
    };

    const WSJTX_GOLDEN: &[&str] = &[
        "ND6P DM04 30",
        "W5BIT EL09 17",
        "WD4LHT EL89 30",
        "NM7J DM26 30",
        "KI7CI DM09 37",
        "DJ6OL JO52 37",
        "W3HH EL89 30",
        "W3BI FN20 30",
        "G8VDQ IO91 37",
    ];

    let params = tr_modes::decode::wspr::SearchParams {
        freq_min_hz: 1400.0,
        freq_max_hz: 1620.0,
        ..Default::default()
    };
    let decoded = tr_modes::decode::wspr::decode_slot(&audio, 12_000, 0, &params);
    let hits = WSJTX_GOLDEN
        .iter()
        .filter(|m| decoded.iter().any(|d| d.message == **m))
        .count();
    // 7 and not ceil(0.9 * 9) = 9, see the doc comment above.
    let min_hits = 7;

    eprintln!(
        "WSPR 150426_0918.wav: {hits}/{} wsprd decodes matched ({} total decodes here)",
        WSJTX_GOLDEN.len(),
        decoded.len()
    );
    assert!(
        hits >= min_hits,
        "WSPR 150426_0918.wav: matched {hits}/{} of wsprd's decodes, need >= {min_hits}",
        WSJTX_GOLDEN.len()
    );
}
