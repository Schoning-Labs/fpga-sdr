// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! FT8 decoding through the chip's front end (docs/P2_FT8_FW.md section 11, docs/F7_CAND.md,
//! docs/FT8_PASS2.md). It sits between the capture rings and sync engines in the FPGA and the
//! station logic: the main loop polls it, and it hands decodes to `qso`.
//!
//! [`ChipFabric`] is `tr_modes::frontend::decode::Fabric` over the driver
//! `tr_fabric::ft8fe::Ft8Engines`: the sync records of a receiver's finished search, and the
//! candidate engine's two passes two candidates at a time. The decoder behind it is the one the
//! models and the QEMU traces already run (`SlotDecoder`: candidate list, fine time and frequency
//! on the baseband, the Costas gate, then belief propagation, OSD and the a-priori passes), with the
//! settings of the scheduler (`tr_modes::frontend::sched`): the operator's receiver first, a CPU
//! cap per receiver, the candidate count that follows the headroom.
//!
//! [`ChipDecoder`] is the per-slot rhythm, polled from the main loop. It works in steps, one per
//! call, so the main loop keeps turning and the chip can work while the CPU does something else:
//!
//! ```text
//!   slot N ends, the chip searches each receiver's spectrogram (about 50 ms each)
//!   operator's search done ->  1. operator's first pass             -> event Partial (its decodes)
//!                              2. read the slot's audio, subtract the decodes, write the residual
//!                                 to DDR3, start the chip's replay and search of it (0.14 s)
//!                              3. the other receivers, one per call ... as soon as the chip has
//!                                 finished the residual: the operator's second pass -> event Partial
//!                              4. all done                           -> event Decoded (everything)
//!   every receiver's search done -> the boundary of slot N+1 is written (the chip then catches up
//!                                   on the audio already in its ring)
//! ```
//!
//! The slot boundary is a capture sample count. It is worked out from the UTC clock and one read of
//! the receiver's `cap_wr_ptr` at the moment of writing: `count_now - (ms since the slot began) x 12
//! + 64` (12 samples per ms at 12 ksps; the channel filter's group delay, 5.3 ms = 64 samples,
//! makes the slot's first audio arrive that much after its first RF sample, as
//! `Radio::slot_audio` assumes).
//!
//! **The second pass** (operator's receiver only, the scheduler's rule): the subtraction is the
//! CPU's (`frontend::subtract`), everything else of the residual is the chip's: its spectrogram
//! engine replays the residual audio from DDR3 between the live frames, its sync engine searches
//! that, its candidate engine filters the residual like any audio ring. It is on when the page says
//! version 2 or later. If a chip step of the second pass fails, **that slot's** second pass runs on
//! the software models instead (far dearer; the CPU cap cuts it if it does not fit), and the next
//! slot uses the chip again.

use alloc::string::String;
use alloc::vec;
use alloc::vec::Vec;

use num_complex::Complex;
use tr_fabric::ft8fe::{self, Basebands, Ft8Engines, Pass2Job, Residual, RxConfig, SyncInfo, BB_WORDS, SYM_WORDS};
use tr_fabric::mem::FabricMem;
use tr_modes::frontend::decode::{
    baseband_from_words, bins_from_words, cs_from_words, message_text, Cs, DecodeParams, Decoded, Fabric, ModelFabric, SlotDecoder,
};
pub use tr_modes::frontend::sched::Budget;
use tr_modes::frontend::sched::{CandPolicy, Job, JobReport, Mode, RxConfig as SchedRx, Scheduler};
use tr_modes::frontend::sync::{BinSync, SyncBand};
use tr_modes::frontend::{Arith, NN, NTONES, N_TIME, SLOT_LEN};
use tr_regs::RegisterSpace;

use crate::qso::Heard;

/// Capture samples per millisecond (12 ksps).
pub const SAMPLES_PER_MS: i64 = 12;
/// The channel filter's group delay in 12 ksps samples (127 taps of 24 ksps = 5.29 ms).
pub const FILTER_DELAY_SAMPLES: i64 = 64;
/// Milliseconds a job waits for a receiver's search that its operator-receiver sibling has already
/// finished (the engine serves the receivers one after the other; a search is 65 to 70 ms at 120 MHz, so the
/// eighth receiver is ready about 0.5 s after the first: a margin of three).
pub const SYNC_WAIT_MS: u32 = 1_500;
/// After this many ms into the slot after the armed one, a search that never finished is a miss (all eight
/// searches take about 0.56 s).
pub const MISS_AFTER_MS: i64 = 4_000;
/// The chip's replay and search of the residual take about 185 ms at 120 MHz (22.1 M clocks, tools/check_ft8_pass2.sh);
/// after this many ms without the event the slot's second pass runs in software.
pub const RESIDUAL_WAIT_MS: i64 = 1_000;
/// Slot length.
const SLOT_MS: i64 = 15_000;

/// `Fabric` over the chip, for one receiver: its slot ([`ChipFabric::new`]) or the residual of its
/// slot ([`ChipFabric::residual`]).
pub struct ChipFabric<'e, 'a, R: RegisterSpace, M: FabricMem> {
    eng: &'e Ft8Engines<'a, R, M>,
    rx: u32,
    /// The slot's first capture sample, if the caller knows it better than the driver's last
    /// `start_slot` (the next slot may be armed already).
    first_sample: Option<u32>,
    /// Second pass: the residual the chip was given.
    res: Option<Residual>,
    info: Option<SyncInfo>,
    bb: Option<Basebands>,
    /// The first thing that went wrong; the decoder stops the pass when this is set.
    pub error: Option<ft8fe::Error>,
    /// The search ended early or the band is not the registers' (an early-trigger search): reported, not an error.
    pub partial_rows: Option<u32>,
}

impl<'e, 'a, R: RegisterSpace, M: FabricMem> ChipFabric<'e, 'a, R, M> {
    /// A fabric for receiver `rx`'s slot, with the driver's last `start_slot` as the slot start unless [`ChipFabric::at`] says otherwise.
    pub fn new(eng: &'e Ft8Engines<'a, R, M>, rx: u32) -> Self {
        ChipFabric { eng, rx, first_sample: None, res: None, info: None, bb: None, error: None, partial_rows: None }
    }

    /// The slot starts at capture sample `first` (whatever `start_slot` has written since).
    pub fn at(mut self, first: u32) -> Self {
        self.first_sample = Some(first);
        self
    }

    /// The second pass: the records of the residual's search and the residual as the audio.
    pub fn residual(eng: &'e Ft8Engines<'a, R, M>, res: Residual) -> Self {
        ChipFabric { eng, rx: res.rx(), first_sample: None, res: Some(res), info: None, bb: None, error: None, partial_rows: None }
    }

    /// Records the first error only; later ones are consequences of it.
    fn fail(&mut self, e: ft8fe::Error) {
        if self.error.is_none() {
            self.error = Some(e);
        }
    }

    fn zero_baseband() -> Vec<Complex<f32>> {
        vec![Complex::new(0.0, 0.0); BB_WORDS]
    }

    fn zero_symbols() -> alloc::boxed::Box<Cs> {
        cs_from_words(&[])
    }
}

impl<R: RegisterSpace, M: FabricMem> Fabric for ChipFabric<'_, '_, R, M> {
    /// The records of the slot's last search (or of the residual's). `audio` is not used: the chip
    /// searched the audio it captured itself (or the residual it was given).
    fn sync(&mut self, _audio: &[i16], band: SyncBand) -> Vec<BinSync> {
        let Some(cfg) = self.eng.config(self.rx) else {
            self.fail(ft8fe::Error::BadRx);
            return Vec::new();
        };
        if (band.ia as u32, band.ib as u32) != (cfg.ia, cfg.ib) {
            self.fail(ft8fe::Error::BadRx);
            return Vec::new();
        }
        let mut recs = vec![[0u32; 8]; cfg.bins()];
        for _ in 0..SYNC_WAIT_MS {
            let taken = match &self.res {
                Some(res) => self.eng.take_residual_sync(res, &mut recs),
                None => self.eng.take_sync(self.rx, &mut recs),
            };
            match taken {
                Ok(Some(info)) if info.rows as usize >= N_TIME => {
                    self.info = Some(SyncInfo { first_sample: self.first_sample.unwrap_or(info.first_sample), ..info });
                    return bins_from_words(&recs);
                }
                // An early search (trigger registers): the slot is not complete, wait for the last.
                Ok(Some(info)) => self.partial_rows = Some(info.rows),
                Ok(None) => self.eng.wait_us(1_000),
                Err(e) => {
                    self.fail(e);
                    return Vec::new();
                }
            }
        }
        self.fail(ft8fe::Error::Timeout);
        Vec::new()
    }

    fn baseband(&mut self, audio: &[i16], slot: usize, inc: u32) -> Vec<Complex<f32>> {
        self.baseband_batch(audio, &[(slot, inc)]).pop().unwrap_or_default()
    }

    fn symbols(&mut self, slot: usize, rinc: u32, i0: i32) -> alloc::boxed::Box<Cs> {
        self.symbols_batch(&[(slot, rinc, i0)]).pop().unwrap_or_else(Self::zero_symbols)
    }

    fn lanes(&self) -> usize {
        ft8fe::LANES
    }

    fn baseband_batch(&mut self, _audio: &[i16], reqs: &[(usize, u32)]) -> Vec<Vec<Complex<f32>>> {
        let n = reqs.len();
        let Some(info) = self.info.filter(|_| self.error.is_none()) else {
            return (0..n).map(|_| Self::zero_baseband()).collect();
        };
        let incs: Vec<u32> = reqs.iter().map(|r| r.1).collect();
        let pass1 = match &self.res {
            Some(res) => self.eng.pass1_residual(res, &incs),
            None => self.eng.pass1(self.rx, info.first_sample, &incs),
        };
        match pass1 {
            Ok(bb) => {
                self.bb = Some(bb);
                let mut out = Vec::with_capacity(n);
                let mut words = vec![(0i32, 0i32); BB_WORDS];
                for lane in 0..n {
                    match self.eng.read_baseband(&bb, lane, &mut words) {
                        Ok(()) => out.push(baseband_from_words(&words)),
                        Err(e) => {
                            self.fail(e);
                            out.push(Self::zero_baseband());
                        }
                    }
                }
                out
            }
            Err(e) => {
                self.fail(e);
                (0..n).map(|_| Self::zero_baseband()).collect()
            }
        }
    }

    fn symbols_batch(&mut self, reqs: &[(usize, u32, i32)]) -> Vec<alloc::boxed::Box<Cs>> {
        let n = reqs.len();
        let Some(bb) = self.bb.filter(|_| self.error.is_none()) else {
            return (0..n).map(|_| Self::zero_symbols()).collect();
        };
        let jobs: Vec<Pass2Job> = reqs.iter().map(|r| Pass2Job { rot_inc: r.1, i0: r.2 }).collect();
        match self.eng.pass2(&bb, &jobs) {
            Ok(sy) => {
                let mut out = Vec::with_capacity(n);
                let mut words = vec![(0i32, 0i32); SYM_WORDS];
                debug_assert_eq!(SYM_WORDS, NN * NTONES);
                for lane in 0..n {
                    match self.eng.read_symbols(&sy, lane, &mut words) {
                        Ok(()) => out.push(cs_from_words(&words)),
                        Err(e) => {
                            self.fail(e);
                            out.push(Self::zero_symbols());
                        }
                    }
                }
                out
            }
            Err(e) => {
                self.fail(e);
                (0..n).map(|_| Self::zero_symbols()).collect()
            }
        }
    }

    fn failed(&self) -> bool {
        self.error.is_some()
    }
}

/// One decoder receiver of the chip.
#[derive(Clone, Copy, Debug)]
pub struct RxPlan {
    /// Chip receiver number (0-7). The back end must be feeding it.
    pub rx: u32,
    /// The operator's receiver: decoded first, its decodes go to the station.
    pub operator: bool,
}

/// How a receiver's second pass went.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SecondPass {
    /// None was due (not the operator's receiver, switched off, the chip has none, or the first
    /// pass failed).
    NotRun,
    /// Through the chip.
    Chip,
    /// A chip step failed (the error): this slot's second pass ran on the software models.
    Software(ft8fe::Error),
    /// Not started: the first pass was cut, or its cost did not fit the CPU cap a second time.
    NoBudget,
}

/// What one receiver's job produced.
#[derive(Clone, Debug)]
pub struct RxDecodes {
    /// Chip receiver number.
    pub rx: u32,
    /// True for the operator's receiver.
    pub operator: bool,
    /// Every decode, the first pass's first.
    pub heard: Vec<Heard>,
    /// How many of `heard` are the first pass's.
    pub first_pass: usize,
    /// The chip failed this receiver's first pass (timeout, busy): `heard` is what was found before.
    pub error: Option<ft8fe::Error>,
    /// Candidates of the first pass.
    pub candidates: u32,
    /// How the second pass went.
    pub second_pass: SecondPass,
    /// Candidates of the second pass.
    pub candidates2: u32,
}

/// One slot decoded through the chip.
#[derive(Clone, Debug)]
pub struct SlotDecode {
    /// The slot the audio belongs to (its index in `slot_of(utc)`).
    pub slot: i64,
    /// One entry per receiver, the operator's first, then by receiver number.
    pub rx: Vec<RxDecodes>,
    /// Per-job report of the scheduler: order, ticks spent, cuts, next candidate count.
    pub reports: Vec<JobReport>,
    /// How many of the operator's decodes [`ChipEvent::Partial`] has handed out already (they are
    /// the first that many of its `heard`).
    pub operator_delivered: usize,
}

/// What `ChipDecoder::poll` can tell the main loop.
#[derive(Clone, Debug)]
pub enum ChipEvent {
    /// Decodes of the operator's receiver as soon as they exist, while the slot's work goes on:
    /// the first pass's (`pass` 0), then what the second pass added (`pass` 1). `Decoded` follows.
    Partial { slot: i64, rx: u32, pass: u8, heard: Vec<Heard> },
    /// The slot is finished: every receiver, every pass.
    Decoded(SlotDecode),
    /// The operator receiver's search of this slot never finished: decode it in software.
    Missed { slot: i64 },
}

/// The operator's second pass, kept between calls of `step`.
struct Second {
    dec: SlotDecoder,
    params: DecodeParams,
    /// Index into the plan.
    plan: usize,
    /// Index into the slot's `out` and `reports`.
    at: usize,
    /// Ticks the first pass took.
    first_spent: u64,
    state: SecondState,
}

enum SecondState {
    /// Next: read the audio, subtract, give the residual to the chip.
    Prepare,
    /// The chip is replaying and searching; `since` is when it started (ms on the slot clock).
    Replaying { res: Residual, residual: Vec<i16>, since: i64 },
}

/// The slot being decoded.
struct Work {
    slot: i64,
    /// First capture sample of the slot, per plan index.
    firsts: Vec<u32>,
    jobs: Vec<Job>,
    next: usize,
    out: Vec<RxDecodes>,
    reports: Vec<JobReport>,
    t0: u64,
    second: Option<Second>,
    /// Receivers (bit = chip receiver) whose search of this slot has been seen done or taken.
    seen: u32,
    armed_next: bool,
    delivered: usize,
}

/// What the next call of `step` does.
enum Act {
    Prepare,
    Second { done: bool },
    Job,
    Wait,
    Finish,
}

/// The per-slot rhythm of the chip path for a set of receivers.
pub struct ChipDecoder<'a, R: RegisterSpace, M: FabricMem> {
    eng: Ft8Engines<'a, R, M>,
    plan: Vec<RxPlan>,
    sched: Scheduler,
    /// The slot whose boundary is written and whose search we are waiting for.
    armed: Option<i64>,
    work: Option<Work>,
    /// Slots in a row in which the operator's receiver gave nothing (miss or chip error).
    pub bad_slots: u32,
    /// Slots finished with the operator's receiver decoded without a chip error.
    pub slots_decoded: u32,
    /// Slots whose search never finished (see `MISS_AFTER_MS`).
    pub slots_missed: u32,
    /// The operator's receiver gets a second pass with the chip's help. On when the chip has it.
    pub second_pass: bool,
    /// Slots whose second pass had to run in software because a chip step failed.
    pub second_pass_fallbacks: u32,
}

/// Turns the decoder's results into `Heard` entries (SNR clamped to -30..50 dB) and their message texts.
fn heard_of(slot: i64, dec: &[Decoded]) -> (Vec<Heard>, Vec<String>) {
    let mut heard = Vec::new();
    let mut messages = Vec::new();
    for d in dec {
        if let Some(text) = message_text(d) {
            heard.push(Heard {
                slot,
                snr_db: libm::roundf(d.result.snr_db).clamp(-30.0, 50.0) as i8,
                dt_s: d.result.dt_sec,
                audio_hz: d.result.freq_hz,
                text: text.clone(),
            });
            messages.push(text);
        }
    }
    (heard, messages)
}

impl<'a, R: RegisterSpace, M: FabricMem> ChipDecoder<'a, R, M> {
    /// Sets up every receiver of `plan` (decoder receivers 100 to 3,000 Hz, FT8, no early
    /// searches) and takes the budget of the scheduler. An error here is the front end not being
    /// what this driver was written for: use the software decoder.
    pub fn new(regs: &'a R, mem: &'a M, plan: &[RxPlan], budget: Budget) -> Result<Self, ft8fe::Error> {
        let eng = Ft8Engines::new(regs, mem);
        let rxs: Vec<SchedRx> = plan.iter().map(|p| SchedRx { mode: Mode::Ft8, operator: p.operator, freq_min: 100.0, freq_max: 3_000.0 }).collect();
        for p in plan {
            let band = SyncBand::from_hz(100.0, 3_000.0);
            eng.setup_rx(p.rx, &RxConfig { ia: band.ia as u32, ib: band.ib as u32, ..RxConfig::default() })?;
        }
        eng.clear_sync_events(0xFF);
        let second_pass = eng.has_second_pass();
        Ok(ChipDecoder {
            eng,
            plan: plan.to_vec(),
            sched: Scheduler::new(budget, CandPolicy::default(), &rxs),
            armed: None,
            work: None,
            bad_slots: 0,
            slots_decoded: 0,
            slots_missed: 0,
            second_pass,
            second_pass_fallbacks: 0,
        })
    }

    /// The driver underneath, for the console and tests.
    pub fn engines(&self) -> &Ft8Engines<'a, R, M> {
        &self.eng
    }

    /// The candidate count the scheduler will use next for the receiver at `plan` index `i`.
    pub fn max_cand(&self, i: usize) -> usize {
        self.sched.rx[i].max_cand
    }

    /// True if the decode of `slot` is coming from the chip (its boundary is written, or it is
    /// being decoded).
    pub fn expects(&self, slot: i64) -> bool {
        self.armed == Some(slot) || self.work.as_ref().is_some_and(|w| w.slot == slot)
    }

    /// Bit mask of the operator's receiver (the first one if none is marked).
    fn operator_bit(&self) -> u32 {
        let p = self.plan.iter().find(|p| p.operator).or(self.plan.first());
        p.map_or(0, |p| 1 << p.rx)
    }

    /// Bit mask of every receiver in the plan.
    fn plan_mask(&self) -> u32 {
        self.plan.iter().fold(0, |m, p| m | 1 << p.rx)
    }

    /// Writes the boundary of slot `target` for every receiver. `slot` and `ms` are the UTC slot
    /// now and the milliseconds since it began.
    fn arm(&mut self, target: i64, slot: i64, ms: i64) {
        for p in &self.plan {
            let now = self.eng.capture_count(p.rx) as i64;
            let first = now + ((target - slot) * SLOT_MS - ms) * SAMPLES_PER_MS + FILTER_DELAY_SAMPLES;
            self.eng.start_slot(p.rx, first as u32);
        }
        self.armed = Some(target);
    }

    /// Call every turn of the main loop with the UTC slot and the milliseconds into it. Does one
    /// step of the slot's work (module text) and returns an event when there is something for the
    /// station. `clock` is the scheduler's tick counter (`mcycle` on the board).
    pub fn poll(&mut self, slot: i64, ms: i64, clock: &dyn Fn() -> u64) -> Option<ChipEvent> {
        if self.work.is_some() {
            return self.step(slot, ms, clock);
        }
        let Some(armed) = self.armed else {
            self.eng.clear_sync_events(0xFF);
            self.arm(slot + 1, slot, ms);
            return None;
        };
        if self.eng.sync_pending() & self.operator_bit() != 0 {
            // The slot's first sample per receiver, before the next boundary overwrites it.
            let firsts = self.plan.iter().map(|p| self.eng.slot_first_sample(p.rx)).collect();
            self.work = Some(Work {
                slot: armed,
                firsts,
                jobs: self.sched.jobs(0),
                next: 0,
                out: Vec::new(),
                reports: Vec::new(),
                t0: clock(),
                second: None,
                seen: 0,
                armed_next: false,
                delivered: 0,
            });
            return self.step(slot, ms, clock);
        }
        if slot > armed && ms > MISS_AFTER_MS {
            self.slots_missed += 1;
            self.bad_slots += 1;
            self.eng.clear_sync_events(0xFF);
            self.arm((armed + 1).max(slot), slot, ms);
            return Some(ChipEvent::Missed { slot: armed });
        }
        None
    }

    /// The next slot's boundary, once every receiver's search of the old slot is done (its
    /// spectrogram may then be overwritten; the records and the audio ring stay).
    fn arm_next_if_free(&mut self, slot: i64, ms: i64, force: bool) {
        let mask = self.plan_mask();
        let pending = self.eng.sync_pending();
        let target = {
            let Some(w) = self.work.as_mut() else { return };
            if w.armed_next {
                return;
            }
            w.seen |= pending;
            if !force && w.seen & mask != mask {
                return;
            }
            w.armed_next = true;
            (w.slot + 1).max(slot)
        };
        self.arm(target, slot, ms);
    }

    /// One step of the slot's work: the second pass if it is due, else the next receiver's job, else the end of the slot.
    fn step(&mut self, slot: i64, ms: i64, clock: &dyn Fn() -> u64) -> Option<ChipEvent> {
        self.arm_next_if_free(slot, ms, false);
        let now_ms = slot * SLOT_MS + ms;
        // The operator's second pass: prepared right after its first, run as soon as the chip has
        // the residual's records; the other receivers in between.
        let act = {
            let w = self.work.as_ref()?;
            let jobs_left = w.next < w.jobs.len();
            match w.second.as_ref().map(|s| &s.state) {
                Some(SecondState::Prepare) => Act::Prepare,
                Some(SecondState::Replaying { since, .. }) => {
                    let done = self.eng.residual_done();
                    if done || now_ms - since > RESIDUAL_WAIT_MS {
                        Act::Second { done }
                    } else if jobs_left {
                        Act::Job
                    } else {
                        Act::Wait
                    }
                }
                None if jobs_left => Act::Job,
                None => Act::Finish,
            }
        };
        match act {
            Act::Prepare => self.prepare_second(now_ms, clock),
            Act::Second { done } => self.run_second(done, clock),
            Act::Job => self.run_job(clock),
            Act::Wait => None,
            Act::Finish => {
                // Stale sync events of this slot must not start the next slot's decode.
                self.arm_next_if_free(slot, ms, true);
                self.eng.clear_sync_events(0xFF);
                let w = self.work.take()?;
                let mut order: Vec<usize> = (0..w.out.len()).collect();
                order.sort_by_key(|&i| (!w.out[i].operator, w.out[i].rx));
                let rx: Vec<RxDecodes> = order.iter().map(|&i| w.out[i].clone()).collect();
                let op_ok = rx.iter().find(|r| r.operator).map_or(true, |r| r.error.is_none());
                if op_ok {
                    self.bad_slots = 0;
                    self.slots_decoded += 1;
                } else {
                    self.bad_slots += 1;
                }
                Some(ChipEvent::Decoded(SlotDecode { slot: w.slot, rx, reports: w.reports, operator_delivered: w.delivered }))
            }
        }
    }

    /// The next job of the queue: one receiver's first pass.
    fn run_job(&mut self, clock: &dyn Fn() -> u64) -> Option<ChipEvent> {
        let w = self.work.as_mut()?;
        let order = w.next;
        let job = w.jobs[order];
        w.next += 1;
        let plan = self.plan[job.rx];
        let second = self.second_pass && job.operator && job.params.passes >= 2;
        let params = DecodeParams { passes: if second { 2 } else { 1 }, ..job.params };

        let start = clock() - w.t0;
        let mut fab = ChipFabric::new(&self.eng, plan.rx).at(w.firsts[job.rx]);
        let mut dec = SlotDecoder::new();
        dec.run_pass(&mut fab, &[], &params, 0, clock);
        let error = fab.error;
        w.seen |= 1 << plan.rx;
        let spent = clock() - w.t0 - start;

        let (heard, messages) = heard_of(w.slot, &dec.all);
        let first_pass = dec.st.per_pass_total[0];
        let cut_first = dec.st.cut.is_some_and(|c| c.pass == 0);
        let single = self.sched.budget.cap(job.mode, false);
        let next_max_cand = self.sched.policy.next(job.params.max_cand, first_pass, single, cut_first);
        self.sched.rx[job.rx].max_cand = next_max_cand;
        let at = w.out.len();
        w.out.push(RxDecodes {
            rx: plan.rx,
            operator: plan.operator,
            first_pass: heard.len(),
            heard: heard.clone(),
            error,
            candidates: dec.st.n_cand[0],
            second_pass: SecondPass::NotRun,
            candidates2: 0,
        });
        w.reports.push(JobReport {
            rx: job.rx,
            mode: job.mode,
            operator: job.operator,
            order,
            max_cand: job.params.max_cand,
            passes: params.passes,
            cap: job.params.cap,
            start,
            spent,
            first_pass,
            cut: dec.st.cut,
            messages,
            next_max_cand,
        });
        let more_jobs = w.next < w.jobs.len();
        if second && error.is_none() {
            let first_spent = dec.spent();
            w.second = Some(Second { dec, params, plan: job.rx, at, first_spent, state: SecondState::Prepare });
        }
        // The operator's decodes go out now if the slot's work goes on.
        if plan.operator && error.is_none() && (more_jobs || w.second.is_some()) {
            w.delivered = heard.len();
            return Some(ChipEvent::Partial { slot: w.slot, rx: plan.rx, pass: 0, heard });
        }
        None
    }

    /// Reads the slot's audio from the capture ring, subtracts the first pass's decodes and hands the
    /// residual to the chip.
    fn prepare_second(&mut self, now_ms: i64, clock: &dyn Fn() -> u64) -> Option<ChipEvent> {
        let w = self.work.as_mut()?;
        let mut sec = w.second.take()?;
        let rx = self.plan[sec.plan].rx;
        if !sec.dec.second_pass_fits(false, &sec.params) {
            w.out[sec.at].second_pass = SecondPass::NoBudget;
            w.reports[sec.at].cut = sec.dec.st.cut;
            return None;
        }
        let t0 = clock();
        let mut audio = vec![0i16; SLOT_LEN];
        self.eng.read_audio(rx, w.firsts[sec.plan], &mut audio);
        let t1 = clock();
        let residual = sec.dec.subtract(&audio, clock);
        drop(audio);
        let t2 = clock();
        let started = self.eng.start_residual(rx, &residual);
        sec.dec.charge((t1 - t0) + (clock() - t2));
        match started {
            Ok(res) => {
                sec.state = SecondState::Replaying { res, residual, since: now_ms };
                w.second = Some(sec);
                None
            }
            Err(e) => {
                // The chip did not take it: this slot's second pass in software, now.
                w.second = Some(sec);
                self.finish_second(None, residual, Some(e), clock)
            }
        }
    }

    /// The chip has finished the residual (`done`), or took too long: the second pass.
    fn run_second(&mut self, done: bool, clock: &dyn Fn() -> u64) -> Option<ChipEvent> {
        let w = self.work.as_mut()?;
        let sec = w.second.as_mut()?;
        let SecondState::Replaying { res, residual, .. } = core::mem::replace(&mut sec.state, SecondState::Prepare) else {
            return None;
        };
        if done {
            self.finish_second(Some(res), residual, None, clock)
        } else {
            self.finish_second(None, residual, Some(ft8fe::Error::Timeout), clock)
        }
    }

    /// The second pass over `residual`: through the chip (`res`), or on the software models when a
    /// chip step failed (`failed`, or an error during the pass).
    fn finish_second(&mut self, res: Option<Residual>, residual: Vec<i16>, failed: Option<ft8fe::Error>, clock: &dyn Fn() -> u64) -> Option<ChipEvent> {
        let w = self.work.as_mut()?;
        let mut sec = w.second.take()?;
        let mut failed = failed;
        if let Some(res) = res {
            let mut fab = ChipFabric::residual(&self.eng, res);
            sec.dec.run_pass(&mut fab, &residual, &sec.params, 1, clock);
            failed = fab.error;
        }
        if failed.is_some() {
            // For this slot only: the software models do what the chip did not.
            self.second_pass_fallbacks += 1;
            let mut soft = ModelFabric::new(Arith::Fixed);
            sec.dec.run_pass(&mut soft, &residual, &sec.params, 1, clock);
        }
        let (heard, messages) = heard_of(w.slot, &sec.dec.all);
        let out = &mut w.out[sec.at];
        let new: Vec<Heard> = heard[out.heard.len().min(heard.len())..].to_vec();
        out.heard = heard;
        out.candidates2 = sec.dec.st.n_cand[1];
        out.second_pass = failed.map_or(SecondPass::Chip, SecondPass::Software);
        let rep = &mut w.reports[sec.at];
        rep.spent += sec.dec.spent() - sec.first_spent;
        rep.cut = sec.dec.st.cut;
        rep.messages = messages;
        let rx = out.rx;
        if !new.is_empty() && w.next < w.jobs.len() {
            w.delivered = out.heard.len();
            return Some(ChipEvent::Partial { slot: w.slot, rx, pass: 1, heard: new });
        }
        None
    }
}

/// Text of a decode list, one line per message, for the console.
pub fn describe(heard: &[Heard]) -> String {
    use core::fmt::Write as _;
    let mut s = String::new();
    for h in heard {
        let _ = writeln!(s, "{:>4} dB {:+.1} s {:>6.1} Hz  {}", h.snr_db, h.dt_s, h.audio_hz, h.text);
    }
    s
}
