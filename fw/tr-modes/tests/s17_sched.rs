// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Tests of the receiver scheduler (`tr_modes::frontend::sched`) on the host, with the instruction counts left to
//! QEMU (tools/qemu_s17.sh).
//!
//! - Eight receivers fed from the three WSJT-X sample recordings through the scheduler must decode what the
//!   unrationed full ladder decodes on each recording (two passes for the operator's receiver, one for the
//!   others), with the operator's receiver run first.
//! - With a clock that runs out, a slot is cut at a candidate boundary and says so, its decodes are a subset of the
//!   uncut ones, and a cut first pass means no second pass.
//!
//! Both tests skip when the recordings are missing (`tools/fetch_test_audio.sh` fetches them).

use std::cell::Cell;

use mfsk_core::msg::wsjt77::unpack77;
use tr_modes::frontend::decode::{decode_slot, DecodeParams, ModelFabric};
use tr_modes::frontend::sched::{run_ft8, Budget, CandPolicy, Job, JobResult, JobRunner, Mode, RxConfig, Scheduler};
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
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("../../captures/ft8/{name}.wav"));
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

/// The messages in sorted order, for comparing two decodes.
fn sorted(mut v: Vec<String>) -> Vec<String> {
    v.sort();
    v
}

/// Sorted message texts of the full ladder with no time budget and `passes` passes.
fn unrationed(audio: &[i16], passes: usize) -> Vec<String> {
    let p = DecodeParams { passes, ..DecodeParams::default() };
    let (d, _) = decode_slot(&mut ModelFabric::new(Arith::Fixed), audio, &p, &|| 0);
    sorted(d.iter().map(|x| unpack77(x.result.message77()).unwrap_or_default()).collect())
}

/// Job runner that decodes each receiver's job from its own recording with the fixed point model fabric.
struct Models<'a>(Vec<&'a [i16]>);
impl JobRunner for Models<'_> {
    fn run(&mut self, job: &Job, clock: &dyn Fn() -> u64) -> JobResult {
        run_ft8(&mut ModelFabric::new(Arith::Fixed), self.0[job.rx], &job.params, clock)
    }
}

#[test]
fn eight_receivers_decode_what_the_unrationed_ladder_decodes() {
    let names = ["qso3_busy", "qso1", "qso2"];
    let Some(audio): Option<Vec<Vec<i16>>> = names.iter().map(|n| load(n)).collect() else {
        skipped("recording not found");
        return;
    };
    let map = [0usize, 0, 1, 2, 0, 1, 2, 0];
    let rx: Vec<RxConfig> =
        (0..8).map(|i| RxConfig { mode: Mode::Ft8, operator: i == 3, freq_min: 100.0, freq_max: 3_000.0 }).collect();
    let mut s = Scheduler::new(Budget::QEMU, CandPolicy::default(), &rx);
    let jobs = s.jobs(0);
    assert_eq!(jobs[0].rx, 3, "operator first");
    let mut runner = Models(map.iter().map(|&k| audio[k].as_slice()).collect());
    let reports = s.run(&jobs, &mut runner, &|| 0);
    for r in &reports {
        let passes = if r.operator { 2 } else { 1 };
        assert_eq!(r.passes, passes);
        assert!(r.cut.is_none());
        assert_eq!(sorted(r.messages.clone()), unrationed(&audio[map[r.rx]], passes), "rx {}", r.rx);
    }
}

#[test]
fn cut_at_a_candidate_boundary() {
    let Some(audio) = load("qso3_busy") else {
        skipped("recording not found");
        return;
    };
    // A clock that advances 1,000 ticks per reading, so the cap is reached part way through the ladder.
    let t = Cell::new(0u64);
    let clock = || {
        t.set(t.get() + 1_000);
        t.get()
    };
    let full = unrationed(&audio, 2);
    // Where the ladder of the first pass starts and ends on this clock.
    let (_, st) = decode_slot(&mut ModelFabric::new(Arith::Fixed), &audio, &DecodeParams::default(), &clock);
    let (start, len) = (st.per_pass_total[0] - st.ldpc, st.ldpc);
    t.set(0);
    for cap in [start + len / 4, start + len / 2] {
        t.set(0);
        let p = DecodeParams { passes: 2, cap, cand_reserve: 5_000, ..DecodeParams::default() };
        let (d, st) = decode_slot(&mut ModelFabric::new(Arith::Fixed), &audio, &p, &clock);
        let cut = st.cut.expect("cut reported");
        assert!(!cut.pass_skipped && cut.pass == 0 && cut.done > 0 && cut.left > 0, "{cut:?}");
        assert!(cut.spent + cut.reserve > cap);
        assert_eq!(st.log.len() as u32, cut.done, "candidates stop at the cut");
        assert_eq!(st.per_pass_total[1], 0, "no second pass after a cut first pass");
        let got: Vec<String> = d.iter().map(|x| unpack77(x.result.message77()).unwrap_or_default()).collect();
        assert!(got.iter().all(|m| full.contains(m)));
        eprintln!("cap {cap}: cut after {} of {} candidates, {} decodes", cut.done, cut.done + cut.left, got.len());
    }
}
