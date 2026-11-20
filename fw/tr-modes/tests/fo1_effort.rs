// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Tests for the three hooks that the vendored mfsk-core carries for the FT8 effort ladder
//! (fw/vendor/VENDOR_PATCH.md fix 6), run on the WSJT-X sample recordings.
//!
//! - The per-candidate entry `decode_soft_symbols` with `Ft8Effort::from_depth(d)` must give exactly the decodes
//!   (message, frequency, time, pass id and hard errors) of mfsk-core's own multi-candidate entry with
//!   `DecodeDepth` d. This is checked at 30 and 60 candidates, with one and two passes, and once more with
//!   mfsk-core's reference OSD kernels in place of the bit-packed ones (fix 7).
//! - The effort knobs must do what they say: the OSD search count per failed candidate follows variants times
//!   seeds, no OSD runs with `osd=-` and the a-priori OSD off, and the capped two-sweep decode never repeats belief
//!   propagation and finds whatever the uncapped one finds when the cap covers every failure.
//!
//! The tests skip when the recordings are missing (`tools/fetch_test_audio.sh` fetches them).

use std::path::{Path, PathBuf};

use mfsk_core::engine::pipeline::DecodeDepth;
use mfsk_core::msg::wsjt77::unpack77;
use tr_modes::frontend::decode::{decode_slot, DecodeParams, ModelFabric};
use tr_modes::frontend::effort::parse_effort;
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

/// Loads `captures/ft8/<name>.wav` as one 15 s slot (padded with zeros), or `None` when the file is absent.
fn load(name: &str) -> Option<Vec<i16>> {
    let path: PathBuf = Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("../../captures/ft8/{name}.wav"));
    let bytes = std::fs::read(&path).ok()?;
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
    let mut v: Vec<i16> = bytes[off..off + len].chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect();
    v.resize(SLOT_LEN, 0);
    Some(v)
}

/// What identifies a decode: message text, frequency bits, time bits, pass id and hard error count.
type Key = (String, u32, u32, u8, u32);

/// Decodes one slot with the fixed point model fabric and returns the sorted decode keys and the stage counters.
fn run(audio: &[i16], p: &DecodeParams) -> (Vec<Key>, tr_modes::frontend::decode::StageCounts) {
    let mut fab = ModelFabric::new(Arith::Fixed);
    let (d, st) = decode_slot(&mut fab, audio, p, &|| 0);
    let mut k: Vec<Key> = d
        .iter()
        .map(|x| {
            let r = &x.result;
            (unpack77(r.message77()).unwrap_or_default(), r.freq_hz.to_bits(), r.dt_sec.to_bits(), r.pass, r.hard_errors)
        })
        .collect();
    k.sort();
    (k, st)
}

#[test]
fn per_candidate_entry_equals_mfsk_core_ladder() {
    let mut ran = 0;
    for name in ["qso3_busy", "qso1", "qso2"] {
        let Some(audio) = load(name) else {
            skipped(&format!("{name}: not found"));
            continue;
        };
        for (max_cand, passes) in [(30, 1), (60, 1), (30, 2)] {
            for depth in [DecodeDepth::FULL, DecodeDepth::BP_ONLY] {
                let p = DecodeParams { max_cand, passes, ..DecodeParams::default() }.with_depth(depth);
                let (new, _) = run(&audio, &p);
                let (old, _) = run(&audio, &DecodeParams { legacy_ladder: true, ..p });
                assert_eq!(new, old, "{name} {max_cand} cand, {passes} pass(es), osd {}", depth.osd);
                // Again with mfsk-core's reference OSD kernels instead of the packed ones (VENDOR_PATCH fix 7).
                let mut r = p;
                r.effort.osd_packed = false;
                let (reference, _) = run(&audio, &r);
                assert_eq!(new, reference, "{name} {max_cand} cand, {passes} pass(es): packed vs reference OSD");
                ran += 1;
            }
        }
    }
    eprintln!("{ran} comparisons");
}

#[test]
fn effort_knobs() {
    let Some(audio) = load("qso3_busy") else {
        skipped("recording not found");
        return;
    };
    let base = DecodeParams { max_cand: 60, ..DecodeParams::default() };
    // Full ladder: every OSD attempt that fails runs 8 searches, one that succeeds at most 8.
    let (full, st_full) = run(&audio, &base);
    let failed_osd: Vec<_> = st_full.log.iter().filter(|l| l.outcome == 3 && l.work.osd_searches > 0).collect();
    assert!(!failed_osd.is_empty());
    assert!(failed_osd.iter().all(|l| l.work.osd_searches == 8));
    assert!(st_full.log.iter().all(|l| l.work.osd_searches <= 8));
    // One variant, one seed: at most one search per candidate.
    let one = DecodeParams { effort: parse_effort("osd=d,seeds=2").unwrap(), ..base };
    let (_, st_one) = run(&audio, &one);
    assert!(st_one.log.iter().all(|l| l.work.osd_searches <= 1));
    assert!(st_one.log.iter().any(|l| l.work.osd_searches == 1));
    // No OSD at all.
    let none = DecodeParams { effort: parse_effort("none").unwrap(), ..base };
    let (_, st_none) = run(&audio, &none);
    assert_eq!(st_none.osd_searches + st_none.ap_osd_searches, 0);
    // Blind-CQ pass off: no a-priori work.
    let nocq = DecodeParams { effort: parse_effort("cq=off").unwrap(), ..base };
    let (_, st_nocq) = run(&audio, &nocq);
    assert!(st_nocq.log.iter().all(|l| l.work.ap_bp_runs == 0 && l.work.ap_osd_searches == 0));
    // Capped with a cap that covers every failure: same decodes as uncapped, and the OSD sweep
    // runs no belief propagation.
    let capped = DecodeParams { osd_max: 1_000, ..base };
    let (cap, st_cap) = run(&audio, &capped);
    let names = |v: &[Key]| {
        let mut n: Vec<String> = v.iter().map(|k| k.0.clone()).collect();
        n.sort();
        n
    };
    assert_eq!(names(&cap), names(&full));
    assert!(st_cap.log.iter().filter(|l| l.osd_sweep).all(|l| l.work.bp_runs == 0 && l.work.ap_bp_runs == 0));
    assert!(st_cap.log.iter().any(|l| l.osd_sweep));
}
