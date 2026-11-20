// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Host test of FT8 decoding through the chip's front end, driven by the real
//! `tr_fabric::ft8fe` driver and `tr_station::chipdec` against a model of the chip.
//!
//! The model is `tr_fabric::ft8fe::chip_mock::FakeChip` (register semantics of `hw/regmap/ft8.toml`:
//! write-1-to-clear events, `cand_busy` that stays up for a few polls, results in DDR3 only when a
//! command completes, a data cache the logic's writes go behind) with the bit-exact models of the spectrogram, sync,
//! baseband and symbol engines (`tr_modes::frontend`) as its engines. The recordings go into the model's audio ring where the
//! chip's capture would have put them; the CPU side gets nothing but registers and DDR3.
//!
//! What is checked:
//! - the decodes of `qso3_busy` through the chip are the decodes of the model fabric (15 messages,
//!   among them WSJT-X's eight), those of `qso1` too (3 messages), with the same frequencies and times
//!   to the bit; two slots in a row, so the boundary of the next slot is right;
//! - eight receivers (the recordings in different places, the operator not first) decode like eight
//!   single runs, the operator first;
//! - the rules of the register page held: nothing written to `cand_*` while `cand_busy`, no read of
//!   stale cache lines;
//! - a chip that never finishes a command, and one that never finishes a search, are reported (the
//!   caller then decodes in software);
//! - the second pass (docs/FT8_PASS2.md): the operator's receiver decodes what the two-pass model
//!   decodes (19 messages on `qso3_busy`, all eight of WSJT-X's), its first pass's decodes come out
//!   before the rest of the slot's work, the residual was in DDR3 before the chip was told to replay
//!   it; a chip that never finishes the replay costs that slot a second pass in software and nothing
//!   after; the page of the first chip image (version 1) gets one pass.

use std::collections::HashMap;

use tr_fabric::ft8fe::chip_mock::{ChipEngine, FakeChip, LogicMem};
use tr_fabric::ft8fe::{map, Ft8FrontEnd, BB_WORDS};
use tr_modes::frontend::baseband::baseband_fx;
use tr_modes::frontend::decode::{decode_slot, message_text, DecodeParams, ModelFabric};
use tr_modes::frontend::spectrogram::{spectrogram_fx, PWR_SHIFT_DEFAULT};
use tr_modes::frontend::symbols::symbols_fx;
use tr_modes::frontend::sync::{sync_fx_rows, SyncBand};
use tr_modes::frontend::tables::Tables;
use tr_modes::frontend::{sched::Budget, Arith, SLOT_LEN};
use tr_regs::generated::ft8;
use tr_station::chipdec::{ChipDecoder, ChipEvent, RxPlan, SecondPass, SlotDecode, FILTER_DELAY_SAMPLES};

const RING_MASK: u32 = (1 << 19) - 1;

/// WSJT-X's own decodes of `qso3_busy` (the list `ft8-frontend sync-check` requires).
const WSJTX_QSO3_BUSY: &[&str] = &[
    "CQ F5RXL IN94",
    "N1JFU EA6EE R-07",
    "A92EE F5PSR -14",
    "W0RSJ EA3BMU RR73",
    "K1JT HA0DU KN07",
    "N1PJT HB9CQK -10",
    "K1BZM DK8NE -10",
    "KD2UGC F6GCP R-23",
];

/// A test that needs the recordings and cannot find them says so on the real standard error (the test harness hides
/// what a passing test prints with `eprintln!`, which made a missing `captures/` look like a pass).
/// `TR_REQUIRE_RECORDINGS=1` turns the skip into a failure.
fn skipped(what: &str) {
    use std::io::Write;
    let name = std::thread::current().name().unwrap_or("?").to_string();
    let _ = writeln!(std::io::stderr(), "SKIPPED {name}: {what} -- run tools/fetch_test_audio.sh");
    assert!(std::env::var_os("TR_REQUIRE_RECORDINGS").is_none(), "recordings missing and TR_REQUIRE_RECORDINGS is set");
}

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

/// The spectrogram, sync, baseband and symbol engines as the models compute them, reading the audio from the ring in DDR3.
struct ModelEngine {
    tables: Tables,
    /// Results by (audio hash, ...): the same recording on several receivers is computed once.
    sync_cache: HashMap<u64, Vec<[u32; 8]>>,
    bb_cache: HashMap<(u64, u32), Vec<(i32, i32)>>,
    /// The audio of the last extraction by (ring base, first sample), with its hash.
    audio: HashMap<(u32, u32), (Vec<i16>, u64)>,
    pass1_cmds: u32,
    replays: u32,
}

impl ModelEngine {
    fn new() -> Self {
        ModelEngine { tables: Tables::new(), sync_cache: HashMap::new(), bb_cache: HashMap::new(), audio: HashMap::new(), pass1_cmds: 0, replays: 0 }
    }

    /// The slot's 180,000 samples as the capture ring holds them (4 per lane word, sample p at
    /// word p / 4, bits 16 (p mod 4)).
    fn slot_audio(&mut self, io: &dyn LogicMem, cap_lw: u32, first: u32) -> (Vec<i16>, u64) {
        // Re-read every time a search starts (new audio in the ring); pass 1 and 2 reuse it.
        let v: Vec<i16> = (0..SLOT_LEN as u32)
            .map(|k| {
                let pos = first.wrapping_add(k) & RING_MASK;
                let w = io.get32(cap_lw * 8 + (pos / 4) * 8 + ((pos % 4) / 2) * 4);
                ((w >> ((pos % 2) * 16)) & 0xFFFF) as u16 as i16
            })
            .collect();
        let h = v.iter().fold(0xcbf2_9ce4_8422_2325u64, |h, &x| (h ^ x as u16 as u64).wrapping_mul(0x100_0000_01b3));
        self.audio.insert((cap_lw, first), (v.clone(), h));
        (v, h)
    }
}

impl ChipEngine for ModelEngine {
    fn sync(&mut self, io: &mut dyn LogicMem, _rx: u32, rows: u32, ia: u32, ib: u32, first: u32, cap_lw: u32, rec_lw: u32) {
        let (audio, h) = self.slot_audio(io, cap_lw, first);
        let key = h ^ (rows as u64) << 40 ^ (ia as u64) << 50 ^ (ib as u64) << 20;
        let recs = self
            .sync_cache
            .entry(key)
            .or_insert_with(|| {
                let s = spectrogram_fx(&self.tables, &audio, PWR_SHIFT_DEFAULT);
                sync_fx_rows(&s, SyncBand { ia: ia as usize, ib: ib as usize }, rows as usize).iter().map(|b| b.to_words()).collect()
            })
            .clone();
        for (b, w) in recs.iter().enumerate() {
            for q in 0..4 {
                let a = rec_lw * 8 + ((b * 4 + q) * 8) as u32;
                io.put32(a, w[2 * q]);
                io.put32(a + 4, w[2 * q + 1]);
            }
        }
    }

    fn pass1(&mut self, io: &mut dyn LogicMem, _lane: u32, inc: u32, first: u32, cap_lw: u32, bb_lw: u32) {
        self.pass1_cmds += 1;
        // The model reads the ring the registers name; a driver that names the wrong ring or the
        // wrong first sample gets other audio and fails the comparison with the model fabric.
        let (audio, h) = match self.audio.get(&(cap_lw, first)) {
            Some((a, h)) => (a.clone(), *h),
            None => self.slot_audio(io, cap_lw, first),
        };
        let y = self.bb_cache.entry((h, inc)).or_insert_with(|| baseband_fx(&self.tables, &audio, inc)).clone();
        for (i, &(re, im)) in y.iter().enumerate() {
            io.put32(bb_lw * 8 + (i * 8) as u32, re as u32);
            io.put32(bb_lw * 8 + (i * 8) as u32 + 4, im as u32);
        }
    }

    fn replay(&mut self, io: &mut dyn LogicMem, _rx: u32, ia: u32, ib: u32, sh: u32, audio_lw: u32, spec_lw: u32, rec_lw: u32) {
        use tr_modes::frontend::replay::{replay, RESIDUAL_LANE_WORDS};
        self.replays += 1;
        // The residual as the logic reads it out of DDR3 (what the CPU has not written back is not there).
        let words: Vec<u64> =
            (0..RESIDUAL_LANE_WORDS as u32).map(|w| io.get32(audio_lw * 8 + w * 8) as u64 | (io.get32(audio_lw * 8 + w * 8 + 4) as u64) << 32).collect();
        let r = replay(&self.tables, &words, sh, SyncBand { ia: ia as usize, ib: ib as usize });
        for (i, pair) in r.spectrogram.chunks_exact(2).enumerate() {
            io.put32(spec_lw * 8 + (i * 8) as u32, pair[0]);
            io.put32(spec_lw * 8 + (i * 8) as u32 + 4, pair[1]);
        }
        for (b, w) in r.records.iter().enumerate() {
            for q in 0..4 {
                let a = rec_lw * 8 + ((b * 4 + q) * 8) as u32;
                io.put32(a, w[2 * q]);
                io.put32(a + 4, w[2 * q + 1]);
            }
        }
        // Pass 1 of the second pass reads this buffer: forget the audio of an earlier residual.
        self.slot_audio(io, audio_lw, 0);
    }

    fn pass2(&mut self, io: &mut dyn LogicMem, _lane: u32, rot_inc: u32, i0: i32, bb_lw: u32, sym_lw: u32) {
        // The baseband comes back out of DDR3, from the lane's buffer.
        let y: Vec<(i32, i32)> = (0..BB_WORDS as u32).map(|i| (io.get32(bb_lw * 8 + i * 8) as i32, io.get32(bb_lw * 8 + i * 8 + 4) as i32)).collect();
        let c = symbols_fx(&self.tables, &y, rot_inc, i0);
        for (i, &(re, im)) in c.iter().flat_map(|row| row.iter()).enumerate() {
            io.put32(sym_lw * 8 + (i * 8) as u32, re as u32);
            io.put32(sym_lw * 8 + (i * 8) as u32 + 4, im as u32);
        }
    }
}

type Chip = FakeChip<ModelEngine>;

fn xorshift(s: &mut u64) -> u64 {
    *s ^= *s << 13;
    *s ^= *s >> 7;
    *s ^= *s << 17;
    *s
}

/// What the capture would have written: `samples` at counts `first ..`, other counts around them
/// junk (the previous and the next slot).
fn put_ring(chip: &Chip, rx: u32, first: u32, samples: &[i16], junk_seed: u64) {
    let base = map::cap(rx);
    let mut seed = junk_seed;
    let put = |count: u32, v: i16| {
        let pos = count & RING_MASK;
        let a = base + (pos / 4) * 8 + ((pos % 4) / 2) * 4;
        let sh = (pos % 2) * 16;
        let w = (chip.ddr(a) & !(0xFFFF << sh)) | ((v as u16 as u32) << sh);
        chip.poke_ddr(a, w);
    };
    for k in 1..=2_400u32 {
        put(first.wrapping_sub(k), (xorshift(&mut seed) >> 40) as i16);
        put(first.wrapping_add(samples.len() as u32 + k), (xorshift(&mut seed) >> 40) as i16);
    }
    for (k, &v) in samples.iter().enumerate() {
        put(first.wrapping_add(k as u32), v);
    }
}

fn reference(audio: &[i16], max_cand: usize, passes: usize) -> Vec<(String, u32, u32)> {
    let p = DecodeParams { max_cand, passes, ..DecodeParams::default() };
    let (d, _) = decode_slot(&mut ModelFabric::new(Arith::Fixed), audio, &p, &|| 0);
    let mut v: Vec<(String, u32, u32)> =
        d.iter().map(|x| (message_text(x).unwrap_or_default(), x.result.freq_hz.to_bits(), x.result.dt_sec.to_bits())).collect();
    v.sort();
    v
}

fn got(d: &tr_station::chipdec::RxDecodes) -> Vec<(String, u32, u32)> {
    let mut v: Vec<(String, u32, u32)> = d.heard.iter().map(|h| (h.text.clone(), h.audio_hz.to_bits(), h.dt_s.to_bits())).collect();
    v.sort();
    v
}

/// Capture count of receiver `rx` at `t` ms after the start of the test (the counts run 12 per
/// ms from an arbitrary, per receiver different, start).
fn count_at(rx: u32, t: i64) -> u32 {
    (700_000 + 12_345 * rx as i64 + 12 * t) as u32
}

fn set_time(chip: &Chip, plan: &[RxPlan], t: i64) {
    for p in plan {
        chip.poke_reg(ft8::cap_wr_ptr::addr(p.rx), count_at(p.rx, t));
    }
}

/// Plays one slot: `k` slots after the first armed one. The recordings `rec[rx]` begin at the first
/// sample of the slot (at the capture count that `ChipDecoder` has to write to `slot_boundary`).
/// Returns the event at the end of the slot. `t0` is the time the armed slot starts, `slot0` its index.
fn play_slot(chip: &Chip, dec: &mut ChipDecoder<Chip, Chip>, plan: &[RxPlan], slot_idx: i64, t0: i64, rec: &dyn Fn(u32) -> Vec<i16>, never_sync: bool) -> Option<ChipEvent> {
    let clock = || 0u64;
    // The boundary the decoder wrote, against the clock: count at the slot start + the filter delay.
    for p in plan {
        let b = chip.reg(ft8::slot_boundary::addr(p.rx));
        assert_eq!(b, (count_at(p.rx, t0) as i64 + FILTER_DELAY_SAMPLES) as u32, "rx {} slot_boundary", p.rx);
        put_ring(chip, p.rx, b, &rec(p.rx), 1_000 + p.rx as u64);
    }
    // During the slot nothing happens.
    for t in [t0 + 1_000, t0 + 6_000, t0 + 11_800, t0 + 14_200] {
        set_time(chip, plan, t);
        let ms = (t - t0) % 15_000;
        assert!(dec.poll(slot_idx, ms, &clock).is_none());
    }
    // The slot is over: the last frame is written, the search runs, and every receiver's event comes.
    set_time(chip, plan, t0 + 15_050);
    if never_sync {
        return None;
    }
    for p in plan {
        chip.finish_sync(p.rx, 372);
    }
    set_time(chip, plan, t0 + 15_060);
    // The decoder works in steps, one per call: keep calling (5 ms apart) until the slot is done.
    // The operator's early decodes are kept for the test to look at.
    let mut ev = dec.poll(slot_idx + 1, 60, &clock);
    for i in 1..600 {
        match ev {
            Some(ChipEvent::Partial { .. }) => PARTIALS.with(|p| p.borrow_mut().push(ev.take().unwrap())),
            None if dec.expects(slot_idx) => {}
            _ => break,
        }
        ev = dec.poll(slot_idx + 1, 60 + 5 * i, &clock);
    }
    ev
}

thread_local! {
    /// The `Partial` events of the slots played so far in this test.
    static PARTIALS: std::cell::RefCell<Vec<ChipEvent>> = const { std::cell::RefCell::new(Vec::new()) };
}

/// The `Partial` events since the last call: (slot, pass, decodes as `got` gives them).
fn partials() -> Vec<(i64, u8, Vec<(String, u32, u32)>)> {
    PARTIALS.with(|p| {
        p.borrow_mut()
            .drain(..)
            .map(|e| match e {
                ChipEvent::Partial { slot, pass, heard, .. } => {
                    let mut v: Vec<(String, u32, u32)> = heard.iter().map(|h| (h.text.clone(), h.audio_hz.to_bits(), h.dt_s.to_bits())).collect();
                    v.sort();
                    (slot, pass, v)
                }
                other => panic!("{other:?}"),
            })
            .collect()
    })
}

fn decoded(ev: Option<ChipEvent>) -> SlotDecode {
    match ev {
        Some(ChipEvent::Decoded(d)) => d,
        other => panic!("expected a decode, got {other:?}"),
    }
}

#[test]
fn one_receiver_two_slots_decode_like_the_model_fabric() {
    let (Some(a3), Some(a1)) = (load("qso3_busy"), load("qso1")) else {
        skipped("recording not found");
        return;
    };
    let chip: Chip = FakeChip::new(ModelEngine::new());
    chip.set_busy_polls(3);
    let plan = [RxPlan { rx: 0, operator: true }];
    let mut dec = ChipDecoder::new(&chip, &chip, &plan, Budget::QEMU).expect("set-up");
    assert!(Ft8FrontEnd::new(&chip).engines_present());
    // This test is the single pass; the second pass has its own below.
    assert!(dec.second_pass, "on by default with a version 2 page");
    dec.second_pass = false;
    // Slot index 1,000 is in progress, 3 s in; the next one is armed.
    let slot = 1_000;
    set_time(&chip, &plan, 3_000);
    assert!(dec.poll(slot, 3_000, &|| 0).is_none());
    assert!(dec.expects(slot + 1) && !dec.expects(slot));

    // Slot 1,001: qso1 at the scheduler's first candidate count (60): the model's 3 messages.
    let t0 = 15_000;
    let d1 = decoded(play_slot(&chip, &mut dec, &plan, slot + 1, t0, &|_| a1.clone(), false));
    assert_eq!(d1.slot, slot + 1);
    let want1 = reference(&a1, 60, 1);
    assert_eq!(got(&d1.rx[0]), want1);
    assert!(d1.rx[0].error.is_none());
    println!("qso1 through the chip: {} decodes from {} candidates", want1.len(), d1.rx[0].candidates);
    assert_eq!(want1.len(), 3, "the model's count (docs/F7_CAND.md)");

    // Slot 1,002: qso3_busy, boundary re-armed after the decode. The scheduler's policy raised the
    // candidate count after a slot with headroom (clock 0): 70.
    assert!(dec.expects(slot + 2));
    assert_eq!(dec.max_cand(0), 70);
    let t0 = 30_000;
    let d2 = decoded(play_slot(&chip, &mut dec, &plan, slot + 2, t0, &|_| a3.clone(), false));
    assert_eq!(d2.slot, slot + 2);
    assert_eq!(d2.reports[0].max_cand, 70);
    let want3 = reference(&a3, 70, 1);
    assert_eq!(got(&d2.rx[0]), want3);
    println!("qso3_busy through the chip: {} decodes from {} candidates", want3.len(), d2.rx[0].candidates);
    // One pass: six of WSJT-X's eight. K1BZM DK8NE needs more than 70 candidates (it comes at
    // about 100), KD2UGC F6GCP hides under a stronger neighbor 7 Hz away and needs the second pass.
    assert_eq!(want3.len(), 15);
    for g in WSJTX_QSO3_BUSY {
        let found = d2.rx[0].heard.iter().any(|h| h.text == *g);
        assert_eq!(found, *g != "KD2UGC F6GCP R-23" && *g != "K1BZM DK8NE -10", "WSJT-X decode {g}");
    }

    assert_eq!(chip.busy_violations(), 0, "a cand_* register written while cand_busy");
    assert_eq!(chip.cache_stale_reads(), 0, "stale cache lines read");
    // Two candidates per command: each slot wrote cand_cmd twice per pair (pass 1 and pass 2).
    let cmds = chip.reg_write_order().iter().filter(|&&a| a == ft8::cand_cmd::addr()).count() as u32;
    assert_eq!(cmds, 2 * (d1.rx[0].candidates.div_ceil(2) + d2.rx[0].candidates.div_ceil(2)));
    assert_eq!(chip.engine().pass1_cmds, d1.rx[0].candidates + d2.rx[0].candidates, "every candidate went through pass 1 once");
    assert_eq!((dec.slots_decoded, dec.bad_slots), (2, 0));
    // One receiver, one pass: nothing to hand out early, and the chip was never asked for a replay.
    assert!(partials().is_empty());
    assert_eq!(d2.operator_delivered, 0);
    assert_eq!(chip.engine().replays, 0);
}

#[test]
fn eight_receivers_with_the_operator_in_the_middle() {
    let (Some(a3), Some(a1), Some(a2)) = (load("qso3_busy"), load("qso1"), load("qso2")) else {
        skipped("recording not found");
        return;
    };
    let recs = [&a3, &a1, &a2];
    let which = [0usize, 1, 2, 0, 1, 2, 0, 1];
    let chip: Chip = FakeChip::new(ModelEngine::new());
    chip.set_busy_polls(2);
    let plan: Vec<RxPlan> = (0..8).map(|rx| RxPlan { rx, operator: rx == 3 }).collect();
    let mut dec = ChipDecoder::new(&chip, &chip, &plan, Budget::QEMU).expect("set-up");
    set_time(&chip, &plan, 9_000);
    assert!(dec.poll(7, 9_000, &|| 0).is_none());
    let rec = |rx: u32| recs[which[rx as usize]].clone();
    let d = decoded(play_slot(&chip, &mut dec, &plan, 8, 15_000, &rec, false));
    assert_eq!(d.slot, 8);
    assert_eq!(d.rx.len(), 8);
    assert_eq!(d.rx[0].rx, 3, "operator first");
    assert!(d.reports[0].operator && d.reports[0].rx == 3, "the scheduler ran the operator's job first");
    let mut total = 0;
    for r in &d.rx {
        assert!(r.error.is_none(), "rx {}: {:?}", r.rx, r.error);
        // The operator's receiver (3, qso3_busy) gets the second pass, the others one.
        let passes = if r.operator { 2 } else { 1 };
        assert_eq!(got(r), reference(recs[which[r.rx as usize]], 60, passes), "rx {}", r.rx);
        assert_eq!(r.second_pass, if r.operator { SecondPass::Chip } else { SecondPass::NotRun }, "rx {}", r.rx);
        total += r.heard.len();
    }
    // The operator's decodes came out early: the first pass's before any other receiver was
    // decoded, the second pass's additions while other receivers were still to do.
    let p = partials();
    assert_eq!(p.len(), 2, "{p:?}");
    assert_eq!((p[0].0, p[0].1), (8, 0));
    assert_eq!(p[0].2, reference(&a3, 60, 1));
    assert_eq!((p[1].0, p[1].1), (8, 1));
    assert_eq!(p[0].2.len() + p[1].2.len(), d.rx[0].heard.len());
    assert_eq!(d.operator_delivered, d.rx[0].heard.len());
    assert!(d.reports[0].spent >= d.reports[0].first_pass);
    assert_eq!(chip.unflushed_at_command(), 0);
    println!("eight receivers through the chip: {total} decodes in all");
    assert!(d.reports.iter().all(|r| r.cut.is_none()));
    assert_eq!(chip.busy_violations(), 0);
    assert_eq!(chip.cache_stale_reads(), 0);
    // Every receiver's engine page values are its own.
    for rx in 0..8u32 {
        assert_eq!(chip.reg(ft8::cap_base::addr(rx)), map::cap(rx) / 8);
        assert!(ft8::ctrl::read(&chip, rx).enable());
    }
}

#[test]
fn a_chip_that_never_finishes_a_command_is_reported_and_the_slot_gives_nothing() {
    let Some(a3) = load("qso3_busy") else { skipped("recording not found"); return };
    let chip: Chip = FakeChip::new(ModelEngine::new());
    let plan = [RxPlan { rx: 0, operator: true }];
    let mut dec = ChipDecoder::new(&chip, &chip, &plan, Budget::QEMU).unwrap();
    set_time(&chip, &plan, 3_000);
    dec.poll(1, 3_000, &|| 0);
    chip.never_finish();
    let d = decoded(play_slot(&chip, &mut dec, &plan, 2, 15_000, &|_| a3.clone(), false));
    assert_eq!(d.rx[0].error, Some(tr_fabric::ft8fe::Error::Timeout));
    assert!(d.rx[0].heard.is_empty());
    assert_eq!(dec.bad_slots, 1);
    assert_eq!(dec.slots_decoded, 0);
}

#[test]
fn a_search_that_never_finishes_is_a_miss_after_four_seconds() {
    let Some(a3) = load("qso3_busy") else { skipped("recording not found"); return };
    let chip: Chip = FakeChip::new(ModelEngine::new());
    let plan = [RxPlan { rx: 0, operator: true }];
    let mut dec = ChipDecoder::new(&chip, &chip, &plan, Budget::QEMU).unwrap();
    set_time(&chip, &plan, 3_000);
    dec.poll(1, 3_000, &|| 0);
    assert!(play_slot(&chip, &mut dec, &plan, 2, 15_000, &|_| a3.clone(), true).is_none());
    // Slot 3 has begun; nothing came.
    set_time(&chip, &plan, 30_000 + 3_900);
    assert!(dec.poll(3, 3_900, &|| 0).is_none());
    set_time(&chip, &plan, 30_000 + 4_100);
    match dec.poll(3, 4_100, &|| 0) {
        Some(ChipEvent::Missed { slot }) => assert_eq!(slot, 2),
        other => panic!("{other:?}"),
    }
    // Armed again for the slot that is running.
    assert!(dec.expects(3));
    assert_eq!(chip.reg(ft8::slot_boundary::addr(0)), (count_at(0, 30_000) as i64 + FILTER_DELAY_SAMPLES) as u32);
    assert_eq!((dec.bad_slots, dec.slots_missed), (1, 1));
}

#[test]
fn the_stub_page_of_the_first_boards_image_is_not_taken_for_the_engines() {
    let chip: Chip = FakeChip::new(ModelEngine::new());
    chip.set_id(tr_fabric::ft8fe::STUB_ID);
    assert!(!Ft8FrontEnd::new(&chip).engines_present());
    chip.set_id(0x4638_0001);
    assert!(Ft8FrontEnd::new(&chip).engines_present());
    assert!(!Ft8FrontEnd::new(&chip).has_second_pass());
    chip.set_id(0x4638_0002);
    assert!(Ft8FrontEnd::new(&chip).has_second_pass());
}

#[test]
fn the_second_pass_through_the_chip_finds_all_eight_of_wsjtx() {
    let (Some(a3), Some(a1)) = (load("qso3_busy"), load("qso1")) else { skipped("recording not found"); return };
    let chip: Chip = FakeChip::new(ModelEngine::new());
    chip.set_busy_polls(2);
    chip.set_p2_polls(40);
    let plan = [RxPlan { rx: 0, operator: true }, RxPlan { rx: 1, operator: false }];
    let mut dec = ChipDecoder::new(&chip, &chip, &plan, Budget::QEMU).unwrap();
    assert!(dec.second_pass);
    set_time(&chip, &plan, 3_000);
    dec.poll(1, 3_000, &|| 0);
    let d = decoded(play_slot(&chip, &mut dec, &plan, 2, 15_000, &|_| a3.clone(), false));
    let want = reference(&a3, 60, 2);
    assert_eq!(got(&d.rx[0]), want, "the two-pass model's decodes, to the bit");
    println!("qso3_busy, both passes through the chip: {} decodes ({} + {}), second pass from {} candidates", want.len(), d.rx[0].first_pass, want.len() - d.rx[0].first_pass, d.rx[0].candidates2);
    assert_eq!(want.len(), 19);
    assert_eq!(d.rx[0].first_pass, 15);
    assert_eq!(d.rx[0].second_pass, SecondPass::Chip);
    for g in WSJTX_QSO3_BUSY {
        assert!(d.rx[0].heard.iter().any(|h| h.text == *g), "WSJT-X decode {g} missing");
    }
    // The first pass's decodes were handed out before the second pass (and before receiver 1).
    let p = partials();
    assert_eq!((p[0].0, p[0].1), (2, 0));
    assert_eq!(p[0].2, reference(&a3, 60, 1));
    // The other receiver stays at one pass.
    assert_eq!(got(&d.rx[1]), reference(&a3, 60, 1));
    assert_eq!(d.rx[1].second_pass, SecondPass::NotRun);
    // The rules: the residual was in DDR3 (written back, bridge waited) when p2_cmd came; one replay.
    assert_eq!(chip.unflushed_at_command(), 0, "p2_cmd before the residual was in DDR3");
    assert_eq!(chip.busy_violations(), 0);
    assert_eq!(chip.cache_stale_reads(), 0);
    assert_eq!(chip.engine().replays, 1);
    assert_eq!(chip.reg(ft8::p2_base::addr()), map::RESIDUAL / 8);
    assert_eq!(dec.second_pass_fallbacks, 0);

    // The next slot (another recording, the count the policy moved to): the residual buffer, its
    // records and the lanes' buffers are all new, nothing of the slot before shows.
    assert_eq!(dec.max_cand(0), 70);
    let d = decoded(play_slot(&chip, &mut dec, &plan, 3, 30_000, &|_| a1.clone(), false));
    let want = reference(&a1, 70, 2);
    assert_eq!(got(&d.rx[0]), want);
    println!("qso1, both passes through the chip: {} decodes ({} in the first pass)", want.len(), d.rx[0].first_pass);
    assert_eq!(d.rx[0].second_pass, SecondPass::Chip);
    assert_eq!(chip.engine().replays, 2);
    assert_eq!(chip.unflushed_at_command(), 0);
    assert_eq!(chip.cache_stale_reads(), 0);
    assert_eq!((dec.slots_decoded, dec.bad_slots, dec.second_pass_fallbacks), (2, 0, 0));
}

#[test]
fn a_replay_the_chip_never_finishes_costs_that_slot_a_software_second_pass_and_nothing_after() {
    let Some(a3) = load("qso3_busy") else { skipped("recording not found"); return };
    let chip: Chip = FakeChip::new(ModelEngine::new());
    let plan = [RxPlan { rx: 0, operator: true }];
    let mut dec = ChipDecoder::new(&chip, &chip, &plan, Budget::QEMU).unwrap();
    set_time(&chip, &plan, 3_000);
    dec.poll(1, 3_000, &|| 0);
    // Slot 2: the replay never finishes. After a second the models take the residual.
    chip.p2_never_finish(true);
    let d = decoded(play_slot(&chip, &mut dec, &plan, 2, 15_000, &|_| a3.clone(), false));
    assert_eq!(d.rx[0].second_pass, SecondPass::Software(tr_fabric::ft8fe::Error::Timeout));
    assert!(d.rx[0].error.is_none(), "the first pass was fine: the slot is not a chip failure");
    assert_eq!(got(&d.rx[0]), reference(&a3, 60, 2), "the software second pass decodes the same");
    assert_eq!(partials()[0].2, reference(&a3, 60, 1), "the first pass's decodes went out at once all the same");
    assert_eq!((dec.second_pass_fallbacks, dec.bad_slots, dec.slots_decoded), (1, 0, 1));
    assert_eq!(chip.engine().replays, 0);
    // Slot 3: the chip is tried again, and works.
    chip.p2_never_finish(false);
    let d = decoded(play_slot(&chip, &mut dec, &plan, 3, 30_000, &|_| a3.clone(), false));
    assert_eq!(d.rx[0].second_pass, SecondPass::Chip);
    assert_eq!(got(&d.rx[0]), reference(&a3, 70, 2));
    assert_eq!((dec.second_pass_fallbacks, chip.engine().replays), (1, 1));
    assert!(dec.second_pass, "never switched off");
}

#[test]
fn the_first_chip_image_without_the_second_pass_gets_one_pass() {
    let Some(a3) = load("qso3_busy") else { skipped("recording not found"); return };
    let chip: Chip = FakeChip::new(ModelEngine::new());
    chip.set_id(0x4638_0001);
    let plan = [RxPlan { rx: 0, operator: true }];
    let mut dec = ChipDecoder::new(&chip, &chip, &plan, Budget::QEMU).unwrap();
    assert!(!dec.second_pass);
    set_time(&chip, &plan, 3_000);
    dec.poll(1, 3_000, &|| 0);
    let d = decoded(play_slot(&chip, &mut dec, &plan, 2, 15_000, &|_| a3.clone(), false));
    assert_eq!(got(&d.rx[0]), reference(&a3, 60, 1));
    assert_eq!(d.rx[0].second_pass, SecondPass::NotRun);
    assert!(!chip.reg_write_order().contains(&ft8::p2_cmd::addr()));
}
