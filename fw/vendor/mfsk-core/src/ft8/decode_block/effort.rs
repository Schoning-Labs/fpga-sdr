//! Per-candidate decode effort, outcome and entry point.
//!
//! [fpga-sdr vendor patch, fix 6 in `fw/vendor/VENDOR_PATCH.md`; modified 2026 by Franz
//! Schöning] Three hooks a caller with a hard CPU budget needs, none of which changes what the
//! existing entries do:
//!
//! 1. [`decode_soft_symbols`]: a documented entry "decode these 79 x 8 soft symbols for this
//!    candidate" that returns the outcome per candidate ([`CandidateOutcome`]: decoded,
//!    duplicate, implausible, failed, below the sync gate), which rung of the ladder succeeded
//!    ([`Rung`]) and how much work it took ([`CandidateWork`]).
//! 2. [`Ft8Effort`]'s OSD fields: which LLR variants OSD runs on, which BP-refined seeds
//!    (WSJT-X `zsave(:,1)` / `zsave(:,2)`), and whether the deeper npre2 search may run for
//!    clean candidates. Today's ladder is all four variants x both seeds = eight OSD searches
//!    per failed candidate.
//! 3. [`Ft8Effort`]'s a-priori fields: whether the blind-CQ a-priori pass (WSJT-X iaptype 1)
//!    runs, and whether its belief propagation and its OSD run.
//!
//! [`Ft8Effort::from_depth`] reproduces the pre-patch ladder exactly; `process_one_candidate_inner`
//! (every existing caller) goes through it, so existing results are bit-identical.

use super::super::decode::{ApHint, DecodeDepth, DecodeResult, DecodeStrictness, LlrEffort};
use super::super::llr::sync_quality;
use super::super::params::DEFAULT_BP_MAX_ITER;
use crate::engine::scalar::Cmplx;
use crate::engine::sync::SyncCandidate;
use crate::msg::decode_request::DefaultPolicy;

/// How hard to try on one candidate. See the module documentation.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Ft8Effort {
    /// Candidates with Costas sync quality (nsync, 0..=21) at or below this are not decoded
    /// ([`CandidateOutcome::BelowSync`]). WSJT-X and every mfsk-core ladder use 6.
    pub q_min: u32,
    /// Run belief propagation (Steps 1-2 of the ladder). `false` lets a caller that already
    /// ran belief propagation on a candidate (and saw it fail) spend a later budget on OSD
    /// only, without repeating it.
    pub bp: bool,
    /// LLR variants for belief propagation: `Minimal` (a, d) or `Full` (a, b, c, d).
    pub llr_effort: LlrEffort,
    /// Belief-propagation iteration cap.
    pub bp_max_iter: u32,
    /// LLR variants OSD runs on, bit 0 = a, 1 = b, 2 = c, 3 = d (WSJT-X `llra..llrd`).
    /// `0` = no OSD. Tried in the order a, b, c, d.
    pub osd_variants: u8,
    /// BP-refined OSD seeds per variant, bit 0 = one BP iteration (`zsave(:,1)`), bit 1 = two
    /// (`zsave(:,2)`). Tried in that order within each variant (WSJT-X's order).
    pub osd_seeds: u8,
    /// Allow the deeper npre2 search (WSJT-X ndeep = 3) for candidates with nsync >= 18.
    /// `false` runs the npre1 search (ndeep = 2) on every candidate.
    pub osd_npre2: bool,
    /// Push the blind-CQ a-priori pass (WSJT-X iaptype 1: the first callsign is "CQ") when
    /// nsync >= [`Self::ap_blind_cq_q_min`].
    pub ap_blind_cq: bool,
    /// Minimum nsync for the blind-CQ pass (mfsk-core's `BLIND_CQ_MIN_NSYNC`, 12).
    pub ap_blind_cq_q_min: u32,
    /// Belief propagation in the a-priori passes.
    pub ap_bp: bool,
    /// [fpga-sdr vendor patch, fix 8] Run the a-priori passes' belief propagation as the
    /// ladder's normalised min-sum (the fused kernel of `fec::ldpc::bp_fast`) instead of
    /// WSJT-X's sum-product (`bp_decode`, tanh/atanh per edge). `false` in
    /// [`Self::from_depth`] (the old ladder exactly), `true` in [`Self::FULL`] and
    /// [`Self::BP_ONLY`].
    pub ap_min_sum: bool,
    /// OSD (order 2, unpruned) in the a-priori passes.
    pub ap_osd: bool,
    /// LLR variants the a-priori passes use, bit 0 = a .. bit 3 = d.
    pub ap_variants: u8,
    /// Hard-error ceilings.
    pub strictness: DecodeStrictness,
    /// Run OSD with the bit-packed kernels of `fec::ldpc::osd_fast` (VENDOR_PATCH fix 7). Same
    /// results as the reference kernels, a fraction of the instructions; `false` runs the
    /// reference kernels (for measurements).
    pub osd_packed: bool,
}

impl Ft8Effort {
    /// The ladder exactly as [`DecodeDepth`] runs it (every existing entry point).
    pub const fn from_depth(depth: DecodeDepth, bp_max_iter: u32) -> Self {
        Ft8Effort {
            q_min: 6,
            bp: true,
            llr_effort: depth.llr_effort,
            bp_max_iter,
            osd_variants: if depth.osd { 0b1111 } else { 0 },
            osd_seeds: 0b11,
            osd_npre2: true,
            ap_blind_cq: true,
            ap_blind_cq_q_min: 12,
            ap_bp: true,
            ap_min_sum: false,
            ap_osd: depth.osd,
            ap_variants: 0b1111,
            strictness: DecodeStrictness::Normal,
            osd_packed: true,
        }
    }
    /// `DecodeDepth::FULL` at the default iteration cap: full LLR ladder, eight OSD searches
    /// per failed candidate, blind-CQ a-priori pass with belief propagation (min-sum, fix 8)
    /// and OSD.
    pub const FULL: Self = Self::from_depth(DecodeDepth::FULL, DEFAULT_BP_MAX_ITER).with_ap_min_sum();
    /// Belief propagation only (no OSD anywhere), blind-CQ pass by belief propagation
    /// (min-sum, fix 8).
    pub const BP_ONLY: Self = Self::from_depth(DecodeDepth::BP_ONLY, DEFAULT_BP_MAX_ITER).with_ap_min_sum();

    /// The same effort with min-sum belief propagation in the a-priori passes.
    pub const fn with_ap_min_sum(mut self) -> Self {
        self.ap_min_sum = true;
        self
    }

    /// OSD searches one failed candidate costs at most (variants x seeds).
    pub fn osd_searches_max(&self) -> u32 {
        (self.osd_variants & 0xF).count_ones() * (self.osd_seeds & 0b11).count_ones()
    }
}

impl Default for Ft8Effort {
    fn default() -> Self {
        Self::FULL
    }
}

/// Which rung of the ladder produced a codeword.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Rung {
    /// Belief propagation on LLR variant 0..=3 (a, b, c, d).
    Bp { variant: u8 },
    /// OSD on LLR variant `variant` (0..=3) seeded with `seed` (1 or 2) BP iterations.
    Osd { variant: u8, seed: u8 },
    /// A-priori pass `pass` (mfsk-core pass ids 5..=12; 12 = blind CQ) on LLR variant
    /// `variant`, by belief propagation or by OSD.
    Ap { pass: u8, variant: u8, osd: bool },
}

impl Rung {
    /// mfsk-core's pass id (`DecodeResult::pass`): BP 0..=3 (a, b, c, d), OSD zsave-1 14..=17,
    /// OSD zsave-2 19..=22, a-priori 5..=12.
    pub fn pass_id(&self) -> u8 {
        match *self {
            Rung::Bp { variant } => variant,
            Rung::Osd { variant, seed } => (if seed == 1 { 14 } else { 19 }) + variant,
            Rung::Ap { pass, .. } => pass,
        }
    }
}

/// What happened to one candidate.
#[derive(Debug, Clone)]
pub enum CandidateOutcome {
    /// A new message.
    Decoded { result: DecodeResult, rung: Rung },
    /// A codeword passed CRC and the hard-error gate, but its message is already in `known`.
    Duplicate { rung: Rung },
    /// A codeword passed CRC, but its message did not unpack or the codec rejected it as
    /// implausible. The ladder stops at the first CRC-passing codeword (as it always has), so
    /// this candidate is finished too.
    Implausible { rung: Rung },
    /// Every rung the effort allowed ran and none produced a codeword.
    Failed,
    /// nsync at or below [`Ft8Effort::q_min`]; nothing ran.
    BelowSync,
}

impl CandidateOutcome {
    /// `true` only for [`CandidateOutcome::Failed`]: the candidate may decode with more effort.
    pub fn is_failed(&self) -> bool {
        matches!(self, CandidateOutcome::Failed)
    }
}

/// Work done on one candidate (counts, and instruction or cycle counts when the scratch has
/// a clock).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CandidateWork {
    /// Belief-propagation decodes in Steps 1-2.
    pub bp_runs: u16,
    /// OSD searches (npre1 or npre1 + npre2) in Step 3.
    pub osd_searches: u16,
    /// Of those, how many ran the deeper npre2 search.
    pub osd_npre2: u16,
    /// Belief-propagation decodes in the a-priori passes.
    pub ap_bp_runs: u16,
    /// OSD searches in the a-priori passes.
    pub ap_osd_searches: u16,
    /// Clock ticks in Steps 1-2 (LLRs and belief propagation), Step 3 (OSD, including its
    /// LLR set and seeds), Step 4 (a-priori passes) and the rest (sync quality, unpack, SNR).
    /// All zero when [`Ft8CandidateScratch::clock`] is `None`.
    pub ticks_bp: u64,
    pub ticks_osd: u64,
    pub ticks_ap: u64,
    pub ticks_other: u64,
}

/// One candidate's result.
#[derive(Debug, Clone)]
pub struct CandidateReport {
    pub outcome: CandidateOutcome,
    /// Costas sync quality (nsync) of the soft symbols.
    pub q: u32,
    pub work: CandidateWork,
}

/// Reusable per-caller state for [`decode_soft_symbols`].
pub struct Ft8CandidateScratch {
    pub(super) bp: crate::fec::ldpc::bp::BpScratch<crate::fec::ldpc::params::Ldpc174_91Params, super::process_candidates::LlrT>,
    /// Optional monotonic counter (`minstret`, `mcycle`, a timer) sampled around each ladder
    /// step to fill [`CandidateWork`]'s tick fields.
    pub clock: Option<fn() -> u64>,
}

impl Ft8CandidateScratch {
    pub fn new() -> Self {
        Ft8CandidateScratch { bp: crate::fec::ldpc::bp::BpScratch::new(), clock: None }
    }
    pub(super) fn now(&self) -> u64 {
        self.clock.map(|c| c()).unwrap_or(0)
    }
}

impl Default for Ft8CandidateScratch {
    fn default() -> Self {
        Self::new()
    }
}

/// Decode one candidate from its 79 x 8 complex soft symbols (tone amplitudes per symbol,
/// WSJT-X `cs`, the same array mfsk-core's own pipeline builds): sync-quality gate, LLRs,
/// belief propagation, OSD and a-priori passes as `effort` allows, CRC, unpack and the
/// plausibility filter. `cand.dt_sec` is reported as the decode's time offset; `known` is the
/// list of messages already decoded (a match is reported as [`CandidateOutcome::Duplicate`]);
/// `ap_hint` adds WSJT-X's a-priori passes 5..11 for a known station (`None`: blind decode,
/// only the blind-CQ pass).
pub fn decode_soft_symbols(
    cs: &[[Cmplx<f32>; 8]; 79],
    cand: &SyncCandidate,
    effort: &Ft8Effort,
    known: &[DecodeResult],
    ap_hint: Option<&ApHint>,
    scratch: &mut Ft8CandidateScratch,
) -> CandidateReport {
    let t0 = scratch.now();
    let q = sync_quality(cs);
    let mut work = CandidateWork::default();
    if q <= effort.q_min {
        work.ticks_other = scratch.now().wrapping_sub(t0);
        return CandidateReport { outcome: CandidateOutcome::BelowSync, q, work };
    }
    let clock = scratch.clock;
    let outcome = super::process_candidates::process_one_candidate_effort(
        cs,
        cand,
        cand.dt_sec,
        q,
        effort,
        &mut scratch.bp,
        clock,
        known,
        ap_hint,
        0.0,
        &DefaultPolicy,
        &mut work,
    );
    let total = scratch.now().wrapping_sub(t0);
    work.ticks_other = total.saturating_sub(work.ticks_bp + work.ticks_osd + work.ticks_ap);
    CandidateReport { outcome, q, work }
}
