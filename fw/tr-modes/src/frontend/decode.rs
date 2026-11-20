// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Franz Schöning, https://www.schoning.com
// The fine-sync power (`fine_power`, `costas_refs`) follows WSJT-X (K1JT and contributors,
// GPL-3.0-or-later) routine `sync8d` as mfsk-core translates it; modified 2026 by Franz Schöning.

//! The CPU half of the FT8 decoder on top of the fabric front end, and the [`Fabric`] seam.
//!
//! Per pass, the sync engine's per-bin results become a candidate list ([`super::candidates`]).
//! For each candidate the fabric's pass-1 baseband feeds the fine time/frequency search
//! (mfsk-core's `fine_refine_3stage`, the WSJT-X `ft8b` three-stage search, on the baseband with
//! tone 0 moved to 0 Hz), and the fabric's pass-2 soft symbols at the refined time and frequency
//! go through the Costas gate (`nsync > 6`) and then through mfsk-core's LLR, belief propagation,
//! OSD, CRC and unpack, one candidate at a time via `decode_soft_symbols` (a per-candidate entry
//! that the vendored mfsk-core carries as a local patch, `fw/vendor/VENDOR_PATCH.md` fix 6), with
//! the effort of [`DecodeParams::effort`]. With two passes, the first pass's decodes are
//! subtracted from the audio ([`super::subtract`]) and the residual goes through the whole chain
//! again.

use alloc::boxed::Box;
use alloc::vec;
use alloc::vec::Vec;

use mfsk_core::engine::pipeline::{DecodeDepth, DecodeResult};
use mfsk_core::engine::scalar::Cmplx;
use mfsk_core::engine::sync::SyncCandidate;
use mfsk_core::ft8::decode_block::{
    decode_soft_symbols, process_candidates_into_with_cs_scratch_tuned_with_fill, CandidateOutcome, CandidateWork,
    Ft8CandidateScratch, Ft8Effort, RefinedCandidate, Rung,
};
use mfsk_core::ft8::llr::sync_quality;
use mfsk_core::ft8::refine_fine::fine_refine_3stage;
use num_complex::Complex;

use super::baseband::{baseband_f, baseband_fx, nco_inc};
use super::candidates::candidates;
use super::spectrogram::{spectrogram_f, spectrogram_fx, PWR_SHIFT_DEFAULT};
use super::subtract::Subtractor;
use super::symbols::{rot_inc, symbols_f, symbols_fx};
use super::sync::{sync_f, sync_fx, BinSync, BinSyncFx, SyncBand};
use super::tables::Tables;
use super::{Arith, BB_RATE, NN, NTONES};

/// Soft symbols as mfsk-core takes them.
pub type Cs = [[Cmplx<f32>; NTONES]; NN];

/// What the CPU asks of the FPGA engines. Candidate slots are the lanes of one batch: pass 1
/// for slot `k` leaves its baseband in the fabric's DDR3 buffer `k`, which pass 2 reads.
pub trait Fabric {
    /// The spectrogram and sync engines over `audio` (the slot, or the residual after
    /// subtraction): per-bin sync results.
    fn sync(&mut self, audio: &[i16], band: SyncBand) -> Vec<BinSync>;
    /// The candidate engine's first pass for slot `slot`: the 3,200-sample baseband as the CPU
    /// reads it.
    fn baseband(&mut self, audio: &[i16], slot: usize, inc: u32) -> Vec<Complex<f32>>;
    /// The candidate engine's second pass on slot `slot`'s baseband: the 79 x 8 soft symbols.
    fn symbols(&mut self, slot: usize, rinc: u32, i0: i32) -> Box<Cs>;

    /// Candidates the fabric takes in one batch (the chip's candidate engine has two lanes). The
    /// decoder hands them to [`Fabric::baseband_batch`] and [`Fabric::symbols_batch`] together.
    fn lanes(&self) -> usize {
        1
    }
    /// Pass 1 for the candidates of one batch (`(slot, inc)` each, at most [`Fabric::lanes`] of them).
    fn baseband_batch(&mut self, audio: &[i16], reqs: &[(usize, u32)]) -> Vec<Vec<Complex<f32>>> {
        reqs.iter().map(|&(slot, inc)| self.baseband(audio, slot, inc)).collect()
    }
    /// Pass 2 for the batch just given to [`Fabric::baseband_batch`] (`(slot, rinc, i0)` each).
    fn symbols_batch(&mut self, reqs: &[(usize, u32, i32)]) -> Vec<Box<Cs>> {
        reqs.iter().map(|&(slot, rinc, i0)| self.symbols(slot, rinc, i0)).collect()
    }
    /// True once the fabric could not deliver (the chip timed out): the decoder stops the pass
    /// and keeps what it has.
    fn failed(&self) -> bool {
        false
    }
}

/// Everything a fixed-point run hands the CPU, as raw words, in call order (for the QEMU trace).
#[derive(Default)]
pub struct Recording {
    /// One event per fabric call.
    pub events: Vec<Event>,
}

/// One recorded fabric answer, with the request that produced it.
pub enum Event {
    /// Per-bin sync records of `band` (8 words per bin).
    Sync { band: SyncBand, words: Vec<[u32; 8]> },
    /// Baseband of candidate slot `slot` for NCO increment `inc`, (re, im) words.
    Baseband { slot: u32, inc: u32, words: Vec<(i32, i32)> },
    /// Soft symbols of slot `slot` for rotation increment `rinc` and start sample `i0`, 79 x 8
    /// (re, im) words in symbol-major order.
    Symbols { slot: u32, rinc: u32, i0: i32, words: Vec<(i32, i32)> },
}

/// The models as the fabric: fixed (bit-exact) or float.
pub struct ModelFabric {
    /// Fixed (bit-exact) or float models.
    pub arith: Arith,
    /// Power shift register of the spectrogram engine.
    pub pwr_shift: u32,
    /// The ROM tables.
    pub tables: Tables,
    /// Pass-1 baseband per candidate slot, kept for pass 2 (as the chip keeps it in DDR3).
    bb_fx: Vec<Vec<(i32, i32)>>,
    bb_f: Vec<Vec<(f64, f64)>>,
    /// When set, every answer is also recorded as raw words.
    pub recording: Option<Recording>,
}

impl ModelFabric {
    /// A model fabric with the default power shift and no recording.
    pub fn new(arith: Arith) -> Self {
        ModelFabric { arith, pwr_shift: PWR_SHIFT_DEFAULT, tables: Tables::new(), bb_fx: Vec::new(), bb_f: Vec::new(), recording: None }
    }
}

/// Converts the fixed engines' words to what the CPU works with (also used by the QEMU trace).
pub fn bins_from_words(words: &[[u32; 8]]) -> Vec<BinSync> {
    words
        .iter()
        .map(|w| {
            BinSyncFx {
                lag_p: (w[0] & 0xff) as u8 as i8,
                lag_s: ((w[0] >> 8) & 0xff) as u8 as i8,
                sp: [w[1], w[2], w[3]],
                ss: [w[4], w[5], w[6]],
            }
            .to_cpu()
        })
        .collect()
}

/// The baseband words of the candidate engine as the CPU reads them.
pub fn baseband_from_words(words: &[(i32, i32)]) -> Vec<Complex<f32>> {
    words.iter().map(|&(r, i)| Complex::new(r as f32, i as f32)).collect()
}

/// The 79 x 8 soft-symbol words (symbol-major) as the arrays mfsk-core takes.
pub fn cs_from_words(words: &[(i32, i32)]) -> Box<Cs> {
    let mut cs: Box<Cs> = Box::new([[Cmplx::new(0.0, 0.0); NTONES]; NN]);
    for (i, &(r, im)) in words.iter().enumerate() {
        cs[i / NTONES][i % NTONES] = Cmplx::new(r as f32, im as f32);
    }
    cs
}

impl Fabric for ModelFabric {
    fn sync(&mut self, audio: &[i16], band: SyncBand) -> Vec<BinSync> {
        match self.arith {
            Arith::Fixed => {
                let s = spectrogram_fx(&self.tables, audio, self.pwr_shift);
                let words: Vec<[u32; 8]> = sync_fx(&s, band).iter().map(|b| b.to_words()).collect();
                let bins = bins_from_words(&words);
                if let Some(r) = self.recording.as_mut() {
                    r.events.push(Event::Sync { band, words });
                }
                bins
            }
            Arith::Float => {
                let s = spectrogram_f(audio, self.pwr_shift);
                sync_f(&s, band)
            }
        }
    }

    fn baseband(&mut self, audio: &[i16], slot: usize, inc: u32) -> Vec<Complex<f32>> {
        match self.arith {
            Arith::Fixed => {
                let y = baseband_fx(&self.tables, audio, inc);
                let out = baseband_from_words(&y);
                if let Some(r) = self.recording.as_mut() {
                    r.events.push(Event::Baseband { slot: slot as u32, inc, words: y.clone() });
                }
                if self.bb_fx.len() <= slot {
                    self.bb_fx.resize(slot + 1, Vec::new());
                }
                self.bb_fx[slot] = y;
                out
            }
            Arith::Float => {
                let y = baseband_f(&self.tables, audio, inc);
                let out = y.iter().map(|&(r, i)| Complex::new(r as f32, i as f32)).collect();
                if self.bb_f.len() <= slot {
                    self.bb_f.resize(slot + 1, Vec::new());
                }
                self.bb_f[slot] = y;
                out
            }
        }
    }

    fn symbols(&mut self, slot: usize, rinc: u32, i0: i32) -> Box<Cs> {
        match self.arith {
            Arith::Fixed => {
                let c = symbols_fx(&self.tables, &self.bb_fx[slot], rinc, i0);
                let words: Vec<(i32, i32)> = c.iter().flat_map(|row| row.iter().copied()).collect();
                let cs = cs_from_words(&words);
                if let Some(r) = self.recording.as_mut() {
                    r.events.push(Event::Symbols { slot: slot as u32, rinc, i0, words });
                }
                cs
            }
            Arith::Float => {
                let c = symbols_f(&self.bb_f[slot], rinc, i0);
                let mut cs: Box<Cs> = Box::new([[Cmplx::new(0.0, 0.0); NTONES]; NN]);
                for s in 0..NN {
                    for t in 0..NTONES {
                        cs[s][t] = Cmplx::new(c[s][t].0 as f32, c[s][t].1 as f32);
                    }
                }
                cs
            }
        }
    }
}

/// Decoder settings (the knobs the scheduler turns).
#[derive(Clone, Copy, Debug)]
pub struct DecodeParams {
    /// Lowest audio frequency searched, Hz.
    pub freq_min: f32,
    /// Highest audio frequency searched, Hz.
    pub freq_max: f32,
    /// Coarse-sync score floor of the candidate list (WSJT-X "Deep" uses 1.3).
    pub sync_min: f32,
    /// Most candidates taken per pass.
    pub max_cand: usize,
    /// Per-candidate effort (mfsk-core `Ft8Effort`, VENDOR_PATCH fix 6): LLR variants, OSD
    /// variants x seeds and npre2, the blind-CQ a-priori pass. `Ft8Effort::FULL` is mfsk-core's
    /// `DecodeDepth::FULL` ladder (eight OSD searches per failed candidate).
    pub effort: Ft8Effort,
    /// 1 = single pass; 2 = subtract the first pass's decodes and decode the residual.
    pub passes: usize,
    /// With OSD in `effort`: at most this many OSD attempts (failed candidates given OSD) per
    /// pass. `usize::MAX` runs the whole ladder on every candidate in one sweep. Anything
    /// smaller first runs everything but OSD on every candidate, then only the OSD rungs
    /// (belief propagation is not repeated) on the failed candidates with the highest Costas
    /// quality (nsync), at most this many.
    pub osd_max: usize,
    /// Clock for the per-candidate work counts (`minstret` on the target); `None` on the host.
    pub clock: Option<fn() -> u64>,
    /// CPU cap for the whole slot, in ticks of the clock given to [`decode_slot`] (30 Mcycles/s
    /// x 15 s on the board, 315 M instructions under QEMU; `u64::MAX` = none).
    /// Checked at candidate boundaries: a candidate starts only if the ticks spent so far plus
    /// the reserve (the larger of [`Self::cand_reserve`] and the dearest candidate so far in
    /// this slot) stay within the cap; otherwise the pass is cut there and
    /// [`StageCounts::cut`] says where. A second pass starts only if the first was not cut and
    /// the first pass's cost again still fits.
    pub cap: u64,
    /// Ticks kept back for the next candidate before the first one has been measured.
    pub cand_reserve: u64,
    /// Test only: run mfsk-core's own multi-candidate entry with the `DecodeDepth` this effort
    /// came from (as the first model measurements did) instead of the per-candidate entry;
    /// `osd_max` is ignored.
    #[doc(hidden)]
    pub legacy_ladder: bool,
}

impl DecodeParams {
    /// The ladder as a `DecodeDepth` (what the model measurements of docs/S15_FT8MODEL.md used).
    pub fn with_depth(mut self, depth: DecodeDepth) -> Self {
        self.effort = Ft8Effort::from_depth(depth, mfsk_core::ft8::params::BP_MAX_ITER);
        self
    }
}

impl Default for DecodeParams {
    fn default() -> Self {
        DecodeParams {
            freq_min: 100.0,
            freq_max: 3_000.0,
            sync_min: 1.3,
            max_cand: 60,
            effort: Ft8Effort::FULL,
            passes: 1,
            osd_max: usize::MAX,
            clock: None,
            cap: u64::MAX,
            cand_reserve: 0,
            legacy_ladder: false,
        }
    }
}

/// One candidate as the ladder left it (statistics for studying how much effort a candidate needs).
#[derive(Clone, Copy, Debug)]
pub struct CandLog {
    /// Pass (0 or 1) the candidate came from.
    pub pass: u8,
    /// Carrier frequency (Hz) of the candidate, as a decode from it reports it.
    pub freq_hz: f32,
    /// Costas sync quality (`nsync`, 0 to 21).
    pub q: u32,
    /// 0 decoded, 1 duplicate, 2 implausible, 3 failed, 4 below the sync gate.
    pub outcome: u8,
    /// The rung of the ladder that decoded it, if any.
    pub rung: Option<Rung>,
    /// `true` for the OSD-only sweep of a capped run.
    pub osd_sweep: bool,
    /// What the candidate cost.
    pub work: CandidateWork,
}

/// CPU instruction (or time) counts per stage, from the caller's clock.
#[derive(Clone, Debug, Default)]
pub struct StageCounts {
    /// Building the candidate list.
    pub candidates: u64,
    /// Fine time/frequency search and sub-sample dt, plus the Costas gate.
    pub fine_sync: u64,
    /// LLR, belief propagation, OSD, CRC and unpack.
    pub ldpc: u64,
    /// Subtracting the first pass's decodes.
    pub subtract: u64,
    /// Fabric calls (0 on the target with a trace, apart from word conversion).
    pub fabric: u64,
    /// Total of each pass, including the fabric, plus the subtraction for the second.
    pub per_pass_total: [u64; 2],
    /// Candidates of each pass.
    pub n_cand: [u32; 2],
    /// Candidates of each pass that passed the Costas gate.
    pub n_nsync_pass: [u32; 2],
    /// Inside `ldpc`, from [`DecodeParams::clock`]: belief propagation (with its LLRs), OSD
    /// (with its LLR set and seeds), a-priori passes.
    pub ticks_bp: u64,
    pub ticks_osd: u64,
    pub ticks_ap: u64,
    /// Candidates that got an OSD search (ordinary or a-priori), OSD searches, a-priori OSD
    /// searches.
    pub osd_attempts: u32,
    pub osd_searches: u32,
    pub ap_osd_searches: u32,
    /// Every candidate given to the ladder, in order.
    pub log: Vec<CandLog>,
    /// Set when [`DecodeParams::cap`] stopped the slot early.
    pub cut: Option<Cut>,
}

/// Where a slot was stopped by its CPU cap: at a candidate boundary, or before a second pass.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cut {
    /// Pass (0 or 1) in which the cut happened.
    pub pass: u8,
    /// Candidates of that pass decoded before the cut.
    pub done: u32,
    /// Candidates of that pass left undecoded.
    pub left: u32,
    /// `true` when the cut is the second pass not being started at all.
    pub pass_skipped: bool,
    /// Ticks spent when the cut was decided, and the reserve that decided it.
    pub spent: u64,
    /// The reserve that decided the cut.
    pub reserve: u64,
}

/// Tone-0-at-DC baseband from the engine's centered baseband: multiply by `e^(j 2 pi 21.875 m / 200)`,
/// which is `e^(j 2 pi 7 m / 64)`.
fn recentre(y: &[Complex<f32>], rot: &[Complex<f32>; 64]) -> Vec<Complex<f32>> {
    y.iter().enumerate().map(|(m, &v)| v * rot[(7 * m) % 64]).collect()
}

/// The 64 values of `e^(j 2 pi i / 64)` that `recentre` indexes.
fn recentre_table() -> [Complex<f32>; 64] {
    core::array::from_fn(|i| {
        let (s, c) = libm::sincos(2.0 * core::f64::consts::PI * i as f64 / 64.0);
        Complex::new(c as f32, s as f32)
    })
}

/// Costas correlation power at start sample `i` (WSJT-X `sync8d`, as mfsk-core's
/// `fine_sync_power_signed` without the frequency tweak): used only for the sub-sample dt
/// the subtraction wants.
fn fine_power(cd0: &[Complex<f32>], i: i32, refs: &[[Complex<f32>; 32]; 7]) -> f32 {
    let mut total = 0.0f32;
    for block in [0i32, 36, 72] {
        for (k, r) in refs.iter().enumerate() {
            let start = i + (block + k as i32) * 32;
            if start < 0 || start + 32 > cd0.len() as i32 {
                continue;
            }
            let mut z = Complex::new(0.0f32, 0.0);
            for j in 0..32 {
                z += cd0[start as usize + j] * r[j];
            }
            total += z.norm_sqr();
        }
    }
    total
}

/// The seven Costas tones as 32-sample complex references at the baseband rate, shifted by the
/// fine frequency offset `delf` (Hz).
fn costas_refs(delf: f32) -> [[Complex<f32>; 32]; 7] {
    core::array::from_fn(|k| {
        let tone = super::COSTAS[k] as f64;
        core::array::from_fn(|j| {
            let ph = -2.0 * core::f64::consts::PI * (tone / 32.0 + delf as f64 / BB_RATE as f64) * j as f64;
            let (s, c) = libm::sincos(ph);
            Complex::new(c as f32, s as f32)
        })
    })
}

/// One decode with what the subtraction needs.
#[derive(Clone, Debug)]
pub struct Decoded {
    /// The decode as mfsk-core reports it.
    pub result: DecodeResult,
    /// dt with a parabolic sub-sample correction (seconds), for the subtraction.
    pub dt_fine: f32,
    /// Pass (0 or 1) that found it.
    pub pass: u8,
}

/// The message text of a decode (None if the 77 bits do not unpack).
pub fn message_text(d: &Decoded) -> Option<alloc::string::String> {
    mfsk_core::msg::wsjt77::unpack77(d.result.message77())
}

/// One slot's decode in steps: [`SlotDecoder::run_pass`] for the first pass, then, for a second
/// pass, [`SlotDecoder::second_pass_fits`], [`SlotDecoder::subtract`] (which gives the residual
/// audio) and `run_pass` again on the residual. [`decode_slot`] is these steps in a row; a caller
/// that takes them one at a time can hand out the first pass's decodes at once and do other work
/// while the chip replays the residual (docs/FT8_PASS2.md). The CPU cap counts the ticks spent
/// inside the steps, not the time between them.
pub struct SlotDecoder {
    /// Every decode so far, first pass first.
    pub all: Vec<Decoded>,
    /// Counts per stage so far.
    pub st: StageCounts,
    /// Ticks spent in the steps so far.
    spent: u64,
    /// Ticks of the subtraction, added to the second pass's total when it has run.
    carry: u64,
    sub: Option<Subtractor>,
    rot: [Complex<f32>; 64],
}

impl Default for SlotDecoder {
    fn default() -> Self {
        Self::new()
    }
}

impl SlotDecoder {
    /// An empty decoder for a new slot.
    pub fn new() -> Self {
        SlotDecoder { all: Vec::new(), st: StageCounts::default(), spent: 0, carry: 0, sub: None, rot: recentre_table() }
    }

    /// Ticks spent in the steps so far.
    pub fn spent(&self) -> u64 {
        self.spent
    }

    /// Ticks the caller spent on this slot outside the steps (moving the audio to and from the
    /// chip): they count against the cap and into the second pass's total.
    pub fn charge(&mut self, ticks: u64) {
        self.spent += ticks;
        self.carry += ticks;
    }

    /// A second pass may start: the first ran to its end, the fabric delivered, and the first
    /// pass's cost fits the cap once more. Otherwise the cut is recorded and the answer is no.
    pub fn second_pass_fits(&mut self, fabric_failed: bool, p: &DecodeParams) -> bool {
        if self.st.cut.is_some() || fabric_failed || self.spent.saturating_add(self.st.per_pass_total[0]) > p.cap {
            if self.st.cut.is_none() {
                self.st.cut = Some(Cut { pass: 1, done: 0, left: 0, pass_skipped: true, spent: self.spent, reserve: self.st.per_pass_total[0] });
            }
            return false;
        }
        true
    }

    /// The residual: `audio` with every decode so far subtracted.
    pub fn subtract(&mut self, audio: &[i16], clock: &dyn Fn() -> u64) -> Vec<i16> {
        let t0 = clock();
        let mut r = audio.to_vec();
        let s = self.sub.get_or_insert_with(Subtractor::new);
        for d in self.all.iter() {
            s.subtract(&mut r, d.result.message77(), d.result.freq_hz, d.dt_fine);
        }
        let dt = clock() - t0;
        self.st.subtract += dt;
        self.carry += dt;
        self.spent += dt;
        r
    }

    /// One pass (`pass` 0 or 1) over `a`: the slot's audio, or the residual. New messages are
    /// added to [`SlotDecoder::all`]; returns how many.
    pub fn run_pass<F: Fabric>(&mut self, fab: &mut F, a: &[i16], p: &DecodeParams, pass: usize, clock: &dyn Fn() -> u64) -> usize {
        let pass = pass.min(1);
        let t_pass = clock();
        // "Spent in this slot" for the cap: what the earlier steps took plus this pass so far.
        let t_slot = t_pass.wrapping_sub(self.spent);
        let band = SyncBand::from_hz(p.freq_min, p.freq_max);
        let st = &mut self.st;
        let rot = &self.rot;
        let before = self.all.len();

        let t0 = clock();
        let bins = fab.sync(a, band);
        let t1 = clock();
        let cands: Vec<SyncCandidate> = candidates(&bins, band, p.sync_min, p.max_cand);
        let t2 = clock();
        st.fabric += t1 - t0;
        st.candidates += t2 - t1;
        st.n_cand[pass] = cands.len() as u32;

        let mut refined: Vec<RefinedCandidate> = Vec::new();
        let mut fine_dt: Vec<(f32, f32, f32)> = Vec::new(); // (freq, dt, dt_fine)
        let lanes = fab.lanes().max(1);
        for (b, batch) in cands.chunks(lanes).enumerate() {
            if fab.failed() {
                break;
            }
            // Pass 1 for the whole batch, then the CPU's fine search on each baseband, then pass 2
            // for the whole batch (the chip's two lanes run together).
            let first = b * lanes;
            let t0 = clock();
            let reqs: Vec<(usize, u32)> = batch.iter().enumerate().map(|(k, c)| (first + k, nco_inc(c.freq_hz as f64))).collect();
            let bbs = fab.baseband_batch(a, &reqs);
            let t1 = clock();
            let mut fines: Vec<(f32, f32, f32, i32)> = Vec::with_capacity(batch.len()); // (delf, dt, dt_fine, i0)
            for (c, bb) in batch.iter().zip(bbs.iter()) {
                let cd0 = recentre(bb, rot);
                let fr = fine_refine_3stage(&cd0, c.dt_sec);
                let i0 = libm::roundf((fr.dt_sec + 0.5) * BB_RATE as f32) as i32;
                // Sub-sample dt for the subtraction: parabola through the Costas power at i0 - 1,
                // i0, i0 + 1 (at the refined frequency).
                let refs = costas_refs(fr.delf_hz);
                let (pm, p0, pp) = (fine_power(&cd0, i0 - 1, &refs), fine_power(&cd0, i0, &refs), fine_power(&cd0, i0 + 1, &refs));
                let den = pm - 2.0 * p0 + pp;
                let frac = if den < 0.0 { (0.5 * (pm - pp) / den).clamp(-0.5, 0.5) } else { 0.0 };
                fines.push((fr.delf_hz, fr.dt_sec, fr.dt_sec + frac / BB_RATE as f32, i0));
            }
            let t2 = clock();
            let sreqs: Vec<(usize, u32, i32)> = fines.iter().enumerate().map(|(k, f)| (first + k, rot_inc(f.0 as f64), f.3)).collect();
            let css = fab.symbols_batch(&sreqs);
            let t3 = clock();
            st.fabric += (t1 - t0) + (t3 - t2);
            st.fine_sync += t2 - t1;
            for ((c, f), cs) in batch.iter().zip(fines.iter()).zip(css) {
                let q = sync_quality(&cs);
                if q <= 6 {
                    continue;
                }
                let freq = c.freq_hz + f.0;
                refined.push((SyncCandidate { freq_hz: freq, dt_sec: f.1, score: c.score }, cs, q));
                fine_dt.push((freq, f.1, f.2));
            }
            st.fine_sync += clock() - t3;
        }
        st.n_nsync_pass[pass] = refined.len() as u32;

        let t0 = clock();
        let results = if p.legacy_ladder {
            let depth = DecodeDepth { llr_effort: p.effort.llr_effort, osd: p.effort.osd_searches_max() > 0 };
            ldpc_legacy(a, refined, depth)
        } else {
            run_ldpc(refined, p, pass as u8, st, &|| clock().wrapping_sub(t_slot))
        };
        for r in results {
            if self.all.iter().any(|d| d.result.message77() == r.message77()) {
                continue;
            }
            let dt_fine = fine_dt
                .iter()
                .find(|&&(f, d, _)| f == r.freq_hz && d == r.dt_sec)
                .map(|&(_, _, x)| x)
                .unwrap_or(r.dt_sec);
            self.all.push(Decoded { result: r, dt_fine, pass: pass as u8 });
        }
        let t_end = clock();
        st.ldpc += t_end - t0;
        st.per_pass_total[pass] += (t_end - t_pass) + core::mem::take(&mut self.carry);
        self.spent += t_end - t_pass;
        self.all.len() - before
    }

    /// All decodes of the slot and the counts.
    pub fn finish(self) -> (Vec<Decoded>, StageCounts) {
        (self.all, self.st)
    }
}

/// Decode one slot. `clock` returns a monotonic counter (`minstret` on the target, 0 on the
/// host); the returned counts are its differences per stage.
pub fn decode_slot<F: Fabric>(fab: &mut F, audio: &[i16], p: &DecodeParams, clock: &dyn Fn() -> u64) -> (Vec<Decoded>, StageCounts) {
    let mut d = SlotDecoder::new();
    d.run_pass(fab, audio, p, 0, clock);
    if p.passes >= 2 && d.second_pass_fits(fab.failed(), p) {
        let residual = d.subtract(audio, clock);
        d.run_pass(fab, &residual, p, 1, clock);
    }
    d.finish()
}

/// LLR, belief propagation, OSD, CRC and unpack on the gated candidates, one at a time through
/// mfsk-core's `decode_soft_symbols`, with the OSD cap of [`DecodeParams::osd_max`].
fn run_ldpc(refined: Vec<RefinedCandidate>, p: &DecodeParams, pass: u8, st: &mut StageCounts, spent: &dyn Fn() -> u64) -> Vec<DecodeResult> {
    let mut scratch = Ft8CandidateScratch::new();
    scratch.clock = p.clock;
    let e = p.effort;
    let has_osd = e.osd_searches_max() > 0 || e.ap_osd;
    let capped = has_osd && p.osd_max != usize::MAX;
    // Sweep 1: the whole ladder, or (capped) everything but OSD.
    let first = if capped { Ft8Effort { osd_variants: 0, ap_osd: false, ..e } } else { e };
    let mut out: Vec<DecodeResult> = Vec::new();
    let mut failed: Vec<(usize, u32)> = Vec::new();
    let mut run = |i: usize, eff: &Ft8Effort, out: &mut Vec<DecodeResult>, st: &mut StageCounts, osd_sweep: bool| -> bool {
        let (c, cs, _) = &refined[i];
        let rep = decode_soft_symbols(cs, c, eff, out, None, &mut scratch);
        let w = rep.work;
        st.ticks_bp += w.ticks_bp;
        st.ticks_osd += w.ticks_osd;
        st.ticks_ap += w.ticks_ap;
        st.osd_searches += w.osd_searches as u32;
        st.ap_osd_searches += w.ap_osd_searches as u32;
        if w.osd_searches > 0 || w.ap_osd_searches > 0 {
            st.osd_attempts += 1;
        }
        let (code, rung) = match &rep.outcome {
            CandidateOutcome::Decoded { rung, .. } => (0, Some(*rung)),
            CandidateOutcome::Duplicate { rung } => (1, Some(*rung)),
            CandidateOutcome::Implausible { rung } => (2, Some(*rung)),
            CandidateOutcome::Failed => (3, None),
            CandidateOutcome::BelowSync => (4, None),
        };
        st.log.push(CandLog { pass, freq_hz: c.freq_hz, q: rep.q, outcome: code, rung, osd_sweep, work: w });
        let failed = rep.outcome.is_failed();
        if let CandidateOutcome::Decoded { result, .. } = rep.outcome {
            out.push(result);
        }
        failed
    };
    // Candidate-boundary cap: the dearest candidate so far is the reserve.
    let mut dearest = p.cand_reserve;
    for i in 0..refined.len() {
        if p.cap != u64::MAX {
            let s = spent();
            if s.saturating_add(dearest) > p.cap {
                st.cut = Some(Cut { pass, done: i as u32, left: (refined.len() - i) as u32, pass_skipped: false, spent: s, reserve: dearest });
                break;
            }
        }
        let t0 = spent();
        if run(i, &first, &mut out, st, false) {
            failed.push((i, refined[i].2));
        }
        dearest = dearest.max(spent() - t0);
    }
    if capped {
        // Sweep 2: only the OSD rungs on the best failures, highest nsync first.
        let osd_only = Ft8Effort { bp: false, ap_bp: false, ..e };
        failed.sort_by_key(|&(_, q)| core::cmp::Reverse(q));
        for &(i, _) in failed.iter().take(p.osd_max) {
            run(i, &osd_only, &mut out, st, true);
        }
    }
    out
}

/// mfsk-core's own multi-candidate entry on the same soft symbols, as the first model measurements ran it (for the
/// equivalence test of the per-candidate entry; not used by the decoder).
#[doc(hidden)]
pub fn ldpc_legacy(audio: &[i16], refined: Vec<RefinedCandidate>, depth: DecodeDepth) -> Vec<DecodeResult> {
    let mut scratch: Box<Cs> = Box::new([[Cmplx::new(0.0, 0.0); NTONES]; NN]);
    let iters = mfsk_core::ft8::params::BP_MAX_ITER;
    process_candidates_into_with_cs_scratch_tuned_with_fill(audio, refined, depth, 6, iters, &mut scratch, |_, _, _| {})
}

/// Convenience for host tools: run the model fabric over one slot.
pub fn decode_with_model(arith: Arith, audio: &[i16], p: &DecodeParams) -> Vec<Decoded> {
    let mut fab = ModelFabric::new(arith);
    let mut a = vec![0i16; super::SLOT_LEN];
    let n = audio.len().min(super::SLOT_LEN);
    a[..n].copy_from_slice(&audio[..n]);
    decode_slot(&mut fab, &a, p, &|| 0).0
}
