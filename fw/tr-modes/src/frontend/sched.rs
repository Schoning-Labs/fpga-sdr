// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Decode scheduler: decides which receivers get a decode job at each slot boundary, with how
//! many candidates and under what CPU cap.
//!
//! At every slot boundary the receivers whose slot just ended get one decode job each: FT8
//! receivers every 15 s, FT4 receivers every 7.5 s. The operator's receiver goes first, the
//! others follow in receiver order. Each job runs with a CPU cap measured on the core's own
//! counter (`mcycle` on the board, `minstret` under QEMU), from [`Budget`]:
//!
//! - every receiver: 30 Mcycles/s (docs/CPU_BUDGET.md section 8), which is 450 Mcycles per FT8
//!   slot; under QEMU the same allowance as instructions at the assumed IPC of 0.7, 315 M;
//! - the operator's receiver: that plus 60 Mcycles/s for its second pass (945 M instructions).
//!
//! The rules for FT8 jobs are that every candidate gets mfsk-core's full ladder
//! (`Ft8Effort::FULL`, eight packed OSD searches per failed candidate, the blind-CQ a-priori pass)
//! with no OSD rationing, that the cap is enforced at candidate boundaries from the ticks spent
//! so far ([`super::decode::DecodeParams::cap`]) and a cut slot says where it stopped
//! ([`super::decode::Cut`]), and that only the operator's receiver runs two passes. Headroom goes
//! to more candidates first: after each slot a receiver's candidate count moves by
//! [`CandPolicy::step`] towards filling [`CandPolicy::fill_pct`] percent of its own (single-pass)
//! cap, measured on its first pass.
//!
//! FT4 jobs have no fabric front end yet (the front end model is FT8 only), so they run
//! mfsk-core's software FT4 decoder, which has no candidate hook. Their cost is measured and
//! reported but they are not cut.

use alloc::string::String;
use alloc::vec::Vec;

use super::decode::{decode_slot, Cut, DecodeParams, Fabric};

/// Digital mode of a decoder receiver.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// FT8, 15 s slots.
    Ft8,
    /// FT4, 7.5 s slots.
    Ft4,
}

impl Mode {
    /// Slot length in tenths of a second.
    pub const fn slot_tenths(self) -> u64 {
        match self {
            Mode::Ft8 => 150,
            Mode::Ft4 => 75,
        }
    }
}

/// CPU allowance per receiver, in ticks of the scheduler's clock per second.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Budget {
    /// Every decoder receiver.
    pub per_rx_per_s: u64,
    /// Added for the operator's receiver (its second pass).
    pub operator_extra_per_s: u64,
    /// Ticks kept back before the first candidate of a slot has been measured.
    pub cand_reserve: u64,
}

impl Budget {
    /// The board: `mcycle`, 30 Mcycles/s per receiver, 60 Mcycles/s more for the operator's.
    pub const AE350: Budget = Budget { per_rx_per_s: 30_000_000, operator_extra_per_s: 60_000_000, cand_reserve: 12_000_000 };
    /// QEMU: `minstret`, the same allowance at IPC 0.7 (315 M / 945 M instructions per FT8 slot).
    pub const QEMU: Budget = Budget { per_rx_per_s: 21_000_000, operator_extra_per_s: 42_000_000, cand_reserve: 8_000_000 };

    /// Cap of one job.
    pub fn cap(&self, mode: Mode, operator: bool) -> u64 {
        let rate = self.per_rx_per_s + if operator { self.operator_extra_per_s } else { 0 };
        rate * mode.slot_tenths() / 10
    }
}

/// How the candidate count follows the measured cost.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CandPolicy {
    /// Candidate count of a receiver's first slot.
    pub start: usize,
    /// Lowest count the policy goes down to.
    pub min: usize,
    /// Highest count the policy goes up to.
    pub max: usize,
    /// How much the count moves after one slot.
    pub step: usize,
    /// Target share of the single-pass cap, in percent: below it the count goes up by `step`.
    pub fill_pct: u64,
}

impl Default for CandPolicy {
    fn default() -> Self {
        CandPolicy { start: 60, min: 20, max: 150, step: 10, fill_pct: 85 }
    }
}

impl CandPolicy {
    /// Next slot's candidate count from this slot's: down after a cut in the first pass or a first
    /// pass over the single-pass cap, up when the first pass used less than `fill_pct` of it.
    pub fn next(&self, cur: usize, first_pass_spent: u64, single_cap: u64, cut_in_first_pass: bool) -> usize {
        if cut_in_first_pass || first_pass_spent > single_cap {
            cur.saturating_sub(self.step).max(self.min)
        } else if first_pass_spent.saturating_mul(100) < single_cap.saturating_mul(self.fill_pct) {
            (cur + self.step).min(self.max)
        } else {
            cur
        }
    }
}

/// One decoder receiver as the scheduler sees it.
#[derive(Clone, Copy, Debug)]
pub struct RxConfig {
    /// FT8 or FT4.
    pub mode: Mode,
    /// The operator's own receiver, which goes first and gets a second pass.
    pub operator: bool,
    /// Lowest audio frequency searched, Hz.
    pub freq_min: f32,
    /// Highest audio frequency searched, Hz.
    pub freq_max: f32,
}

/// A receiver's configuration and its current candidate count.
#[derive(Clone, Copy, Debug)]
pub struct RxState {
    /// The fixed settings.
    pub cfg: RxConfig,
    /// Candidates for the next slot, as the policy last set it.
    pub max_cand: usize,
}

/// One decode job.
#[derive(Clone, Copy, Debug)]
pub struct Job {
    /// Index of the receiver.
    pub rx: usize,
    /// FT8 or FT4.
    pub mode: Mode,
    /// Whether it is the operator's receiver.
    pub operator: bool,
    /// Everything the decoder needs, cap included.
    pub params: DecodeParams,
}

/// What a runner hands back for one job.
#[derive(Clone, Debug, Default)]
pub struct JobResult {
    /// The decoded message texts.
    pub messages: Vec<String>,
    /// Ticks spent in the first pass (for the candidate-count policy).
    pub first_pass: u64,
    /// Where the cap stopped the job, if it did.
    pub cut: Option<Cut>,
}

/// One job as it ran.
#[derive(Clone, Debug)]
pub struct JobReport {
    /// Index of the receiver.
    pub rx: usize,
    /// FT8 or FT4.
    pub mode: Mode,
    /// Whether it was the operator's receiver.
    pub operator: bool,
    /// Position in the slot's queue (0 = first).
    pub order: usize,
    /// Candidate count the job ran with.
    pub max_cand: usize,
    /// Passes the job was allowed.
    pub passes: usize,
    /// CPU cap of the job, ticks.
    pub cap: u64,
    /// Ticks from the start of the queue to this job's start.
    pub start: u64,
    /// Ticks the job took.
    pub spent: u64,
    /// Ticks of its first pass.
    pub first_pass: u64,
    /// Where the cap stopped the job, if it did.
    pub cut: Option<Cut>,
    /// The decoded message texts.
    pub messages: Vec<String>,
    /// Candidate count the policy chose for the receiver's next slot.
    pub next_max_cand: usize,
}

/// Runs one job: the FPGA front end (or its trace) and the CPU half for FT8, the software
/// decoder for FT4.
pub trait JobRunner {
    /// Runs `job`, reading time from `clock`.
    fn run(&mut self, job: &Job, clock: &dyn Fn() -> u64) -> JobResult;
}

/// The per-slot job queue.
pub struct Scheduler {
    /// CPU allowance per receiver.
    pub budget: Budget,
    /// How candidate counts follow the measured cost.
    pub policy: CandPolicy,
    /// The decoder receivers, in receiver order.
    pub rx: Vec<RxState>,
    /// Per-candidate clock for the ladder's work counts (`DecodeParams::clock`).
    pub tick: Option<fn() -> u64>,
}

impl Scheduler {
    /// A scheduler for the receivers `rx`, each starting at `policy.start` candidates.
    pub fn new(budget: Budget, policy: CandPolicy, rx: &[RxConfig]) -> Self {
        Scheduler { budget, policy, rx: rx.iter().map(|&cfg| RxState { cfg, max_cand: policy.start }).collect(), tick: None }
    }

    /// Jobs due at the slot boundary `t_tenths` (tenths of a second since a 15 s boundary; a
    /// multiple of 75): FT4 receivers at every boundary, FT8 receivers at multiples of 150. The
    /// operator's receiver first, then receiver order.
    pub fn jobs(&self, t_tenths: u64) -> Vec<Job> {
        let mut v: Vec<Job> = self
            .rx
            .iter()
            .enumerate()
            .filter(|(_, r)| t_tenths % r.cfg.mode.slot_tenths() == 0)
            .map(|(i, r)| {
                let op = r.cfg.operator;
                let params = DecodeParams {
                    freq_min: r.cfg.freq_min,
                    freq_max: r.cfg.freq_max,
                    max_cand: r.max_cand,
                    passes: if op { 2 } else { 1 },
                    cap: self.budget.cap(r.cfg.mode, op),
                    cand_reserve: self.budget.cand_reserve,
                    clock: self.tick,
                    ..DecodeParams::default()
                };
                Job { rx: i, mode: r.cfg.mode, operator: op, params }
            })
            .collect();
        v.sort_by_key(|j| (!j.operator, j.rx));
        v
    }

    /// Runs `jobs` in order and moves each receiver's candidate count for its next slot.
    pub fn run<R: JobRunner>(&mut self, jobs: &[Job], runner: &mut R, clock: &dyn Fn() -> u64) -> Vec<JobReport> {
        let t0 = clock();
        let mut out = Vec::with_capacity(jobs.len());
        for (order, job) in jobs.iter().enumerate() {
            let start = clock() - t0;
            let res = runner.run(job, &|| clock());
            let spent = clock() - t0 - start;
            let single = self.budget.cap(job.mode, false);
            let cut_first = res.cut.is_some_and(|c| c.pass == 0);
            let next = self.policy.next(job.params.max_cand, res.first_pass, single, cut_first);
            self.rx[job.rx].max_cand = next;
            out.push(JobReport {
                rx: job.rx,
                mode: job.mode,
                operator: job.operator,
                order,
                max_cand: job.params.max_cand,
                passes: job.params.passes,
                cap: job.params.cap,
                start,
                spent,
                first_pass: res.first_pass,
                cut: res.cut,
                messages: res.messages,
                next_max_cand: next,
            });
        }
        out
    }
}

/// An FT8 job on a fabric (the engines, or a recorded trace of them).
pub fn run_ft8<F: Fabric>(fab: &mut F, audio: &[i16], p: &DecodeParams, clock: &dyn Fn() -> u64) -> JobResult {
    let (d, st) = decode_slot(fab, audio, p, clock);
    let messages = d.iter().map(|x| mfsk_core::msg::wsjt77::unpack77(x.result.message77()).unwrap_or_default()).collect();
    JobResult { messages, first_pass: st.per_pass_total[0], cut: st.cut }
}

/// An FT4 job in software (mfsk-core's FT4 decoder; measured, not cut).
#[cfg(feature = "ft4")]
pub fn run_ft4_software(audio: &[i16], p: &DecodeParams, clock: &dyn Fn() -> u64) -> JobResult {
    let t0 = clock();
    let d = crate::decode::ft4::decode_slot_light(audio, p.freq_min, p.freq_max, p.sync_min, p.max_cand);
    JobResult { messages: d.into_iter().map(|x| x.message).collect(), first_pass: clock() - t0, cut: None }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg(mode: Mode, operator: bool) -> RxConfig {
        RxConfig { mode, operator, freq_min: 100.0, freq_max: 3_000.0 }
    }

    #[test]
    fn caps() {
        let b = Budget::QEMU;
        assert_eq!(b.cap(Mode::Ft8, false), 315_000_000);
        assert_eq!(b.cap(Mode::Ft8, true), 945_000_000);
        assert_eq!(b.cap(Mode::Ft4, false), 157_500_000);
        assert_eq!(Budget::AE350.cap(Mode::Ft8, false), 450_000_000);
    }

    #[test]
    fn queue_order_and_due_jobs() {
        let rx = [cfg(Mode::Ft8, false), cfg(Mode::Ft4, false), cfg(Mode::Ft8, true), cfg(Mode::Ft8, false)];
        let s = Scheduler::new(Budget::QEMU, CandPolicy::default(), &rx);
        let j = s.jobs(0);
        assert_eq!(j.iter().map(|j| j.rx).collect::<Vec<_>>(), [2, 0, 1, 3]);
        assert_eq!(j[0].params.passes, 2);
        assert_eq!(j[0].params.cap, 945_000_000);
        assert!(j[1..].iter().all(|j| j.params.passes == 1));
        assert_eq!(j[2].params.cap, 157_500_000);
        // Half-way through an FT8 slot only the FT4 receiver is due.
        assert_eq!(s.jobs(75).iter().map(|j| j.rx).collect::<Vec<_>>(), [1]);
    }

    #[test]
    fn candidate_policy() {
        let p = CandPolicy::default();
        let cap = 315_000_000;
        assert_eq!(p.next(60, 200_000_000, cap, false), 70); // headroom: more candidates
        assert_eq!(p.next(60, 290_000_000, cap, false), 60); // near the cap: hold
        assert_eq!(p.next(60, 300_000_000, cap, true), 50); // cut: fewer
        assert_eq!(p.next(20, 300_000_000, cap, true), 20);
        assert_eq!(p.next(150, 1, cap, false), 150);
    }

    struct Fake(Vec<u64>);
    impl JobRunner for Fake {
        fn run(&mut self, job: &Job, _clock: &dyn Fn() -> u64) -> JobResult {
            JobResult { messages: Vec::new(), first_pass: self.0[job.rx], cut: None }
        }
    }

    #[test]
    fn run_adapts_counts() {
        let rx = [cfg(Mode::Ft8, true), cfg(Mode::Ft8, false)];
        let mut s = Scheduler::new(Budget::QEMU, CandPolicy::default(), &rx);
        let jobs = s.jobs(0);
        let r = s.run(&jobs, &mut Fake(alloc::vec![100_000_000, 310_000_000]), &|| 0);
        assert_eq!(r[0].next_max_cand, 70);
        assert_eq!(r[1].next_max_cand, 60);
        assert_eq!(s.rx[0].max_cand, 70);
    }
}
