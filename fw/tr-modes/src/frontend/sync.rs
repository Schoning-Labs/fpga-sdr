// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Bit-exact model of the Costas sync search engine (ARCHITECTURE 3.12 (c), docs/F6_SYNC.md),
//! which scores every spectrogram bin and lag against the three Costas sync blocks of an FT8 signal.
//!
//! It computes the same quantities as WSJT-X `sync8.f90` and mfsk-core `coarse_sync`, in integers. For
//! carrier bin i (ia ..= ib) and lag L (-JZ ..= JZ, 40 ms steps), with spectrogram frame
//! `m(b, n) = JSTRT + 4 (COSTAS_POS[b] + n) + L` for Costas block b and position n, counting only
//! frames 0 <= m < 372:
//!
//! - `t_b  = sum_n S[m][i + 2 COSTAS[n]]` (power at the expected tone),
//! - `t0_b = sum_n sum_{k=0..6} S[m][i + 2 k]` (power of tones 0 .. 6),
//! - `score(t, t0) = min(floor((6 t) * 2^16 / (t0 - t + 6)), 2^32 - 1)` (Q16.16: the expected
//!   tone over the mean of the other six, +1 cell in the mean so it never divides by zero),
//! - `sync(i, L) = max(score(t_0 + t_1 + t_2, ...), score(t_1 + t_2, ...))` (all three blocks, or
//!   the last two alone, as WSJT-X).
//!
//! Per bin the engine keeps the best lag in the primary window |L| <= 10 and in the whole window,
//! first maximum on ties (lags visited in ascending order), each with the scores at L - 1, L,
//! L + 1 (0 where L +/- 1 is outside -JZ ..= JZ) for the CPU's parabolic dt refinement.
//! Record per bin: 8 words of 32 bit, [`BinSyncFx`]. One integer divider serves every lane.

use alloc::vec;
use alloc::vec::Vec;

use super::{COSTAS, COSTAS_POS, DF_HZ, K_BINS, NTONES, N_TIME};

/// Start frame of Costas block 0 at lag 0: mfsk-core's `round(0.5 s / 0.04 s)` in f32 = 13.
pub const JSTRT: i32 = 13;
/// Lag half-range: mfsk-core's `round(2.5 s / 0.04 s)` in f32 = 63 frames.
pub const JZ: i32 = 63;
/// Primary lag window (WSJT-X `MLAG`).
pub const MLAG: i32 = 10;
/// Frames per symbol.
pub const NSSY: i32 = 4;
/// Highest spectrogram bin a carrier may use: its tone 7 plus one guard bin must stay below
/// bin 1,024 (mfsk-core `max_tone_off` = 15).
pub const MAX_TONE_OFF: usize = 15;

/// The band the sync engine scans, in spectrogram bins (registers of the engine).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SyncBand {
    /// First carrier bin.
    pub ia: usize,
    /// Last carrier bin, inclusive.
    pub ib: usize,
}

impl SyncBand {
    /// mfsk-core's band rule: `ia = round(fmin / df)`, `ib = min(round(fmax / df), K - 15)`.
    pub fn from_hz(freq_min: f32, freq_max: f32) -> Self {
        let ia = libm::roundf(freq_min / DF_HZ) as usize;
        let ib = (libm::roundf(freq_max / DF_HZ) as usize).min(K_BINS - MAX_TONE_OFF);
        SyncBand { ia, ib: ib.max(ia) }
    }
    /// Number of carrier bins in the band.
    pub fn n_freq(&self) -> usize {
        self.ib - self.ia + 1
    }
}

/// Per-bin result of the fixed-point engine, which is what the FPGA writes to DDR3.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct BinSyncFx {
    /// Best lag in the primary window (|L| <= `MLAG`), in 40 ms frames.
    pub lag_p: i8,
    /// Best lag in the whole window (|L| <= `JZ`), in 40 ms frames.
    pub lag_s: i8,
    /// Scores (Q16.16) at lag_p - 1, lag_p, lag_p + 1.
    pub sp: [u32; 3],
    /// Scores at lag_s - 1, lag_s, lag_s + 1.
    pub ss: [u32; 3],
}

/// The per-bin result as the CPU uses it (scores in plain units).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct BinSync {
    /// Best lag in the primary window, frames.
    pub lag_p: i32,
    /// Scores at `lag_p` - 1, `lag_p`, `lag_p` + 1.
    pub sp: [f32; 3],
    /// Best lag in the whole window, frames.
    pub lag_s: i32,
    /// Scores at `lag_s` - 1, `lag_s`, `lag_s` + 1.
    pub ss: [f32; 3],
}

impl BinSyncFx {
    /// Converts the Q16.16 scores to plain floating-point units.
    pub fn to_cpu(&self) -> BinSync {
        let f = |v: u32| v as f32 / 65_536.0;
        BinSync {
            lag_p: self.lag_p as i32,
            sp: [f(self.sp[0]), f(self.sp[1]), f(self.sp[2])],
            lag_s: self.lag_s as i32,
            ss: [f(self.ss[0]), f(self.ss[1]), f(self.ss[2])],
        }
    }
    /// The 8 x 32-bit words of the DDR3 record: word 0 = lag_p (bits 7:0) | lag_s (15:8),
    /// then sp[0..3], ss[0..3], then a zero pad word.
    pub fn to_words(&self) -> [u32; 8] {
        [
            (self.lag_p as u8 as u32) | ((self.lag_s as u8 as u32) << 8),
            self.sp[0],
            self.sp[1],
            self.sp[2],
            self.ss[0],
            self.ss[1],
            self.ss[2],
            0,
        ]
    }
}

/// Fixed-point score of a sum `t` of expected-tone power and a sum `t0` of the power of tones 0 to 6
/// over the same cells (`t0 >= t`): Q16.16, saturated to 32 bits.
#[inline]
pub fn score_fx(t: u64, t0: u64) -> u32 {
    debug_assert!(t0 >= t);
    let q = ((6 * t) << 16) / (t0 - t + 6);
    q.min(u32::MAX as u64) as u32
}

/// Spectrogram frame that Costas block `b`, position `n` falls on at `lag`, or `None` outside the slot.
#[inline]
fn frame(b: usize, n: usize, lag: i32, n_rows: usize) -> Option<usize> {
    let m = JSTRT + NSSY * (COSTAS_POS[b] + n) as i32 + lag;
    (m >= 0 && (m as usize) < n_rows).then_some(m as usize)
}

/// Generic engine over a cell type; `score` turns (t, t0) into a comparable score.
fn run<C: Copy + Default + core::ops::Add<Output = C> + PartialOrd, Sc: Copy + PartialOrd + Default>(
    s: &[C],
    band: SyncBand,
    n_rows: usize,
    score: impl Fn(C, C) -> Sc,
) -> Vec<(i32, [Sc; 3], i32, [Sc; 3])> {
    let n_rows = n_rows.min(N_TIME);
    let n_freq = band.n_freq();
    let n_lag = (2 * JZ + 1) as usize;
    // allsum[m][fi] = sum_{k=0..6} S[m][ia + fi + 2k]
    let mut allsum = vec![C::default(); N_TIME * n_freq];
    for m in 0..N_TIME {
        let row = &s[m * K_BINS..(m + 1) * K_BINS];
        for fi in 0..n_freq {
            let i = band.ia + fi;
            let mut acc = C::default();
            for k in 0..NTONES - 1 {
                acc = acc + row[i + 2 * k];
            }
            allsum[m * n_freq + fi] = acc;
        }
    }
    let mut out = Vec::with_capacity(n_freq);
    let mut line = vec![Sc::default(); n_lag];
    for fi in 0..n_freq {
        let i = band.ia + fi;
        for (li, lag) in (-JZ..=JZ).enumerate() {
            let mut t = [C::default(); 3];
            let mut t0 = [C::default(); 3];
            for b in 0..3 {
                for (n, &c) in COSTAS.iter().enumerate() {
                    if let Some(m) = frame(b, n, lag, n_rows) {
                        t[b] = t[b] + s[m * K_BINS + i + 2 * c];
                        t0[b] = t0[b] + allsum[m * n_freq + fi];
                    }
                }
            }
            let a = score(t[0] + t[1] + t[2], t0[0] + t0[1] + t0[2]);
            let tl = score(t[1] + t[2], t0[1] + t0[2]);
            line[li] = if tl > a { tl } else { a };
        }
        let at = |lag: i32| -> Sc {
            if (-JZ..=JZ).contains(&lag) {
                line[(lag + JZ) as usize]
            } else {
                Sc::default()
            }
        };
        let argmax = |lo: i32, hi: i32| -> i32 {
            let mut best = lo;
            for lag in lo + 1..=hi {
                if at(lag) > at(best) {
                    best = lag;
                }
            }
            best
        };
        let lp = argmax(-MLAG.min(JZ), MLAG.min(JZ));
        let ls = argmax(-JZ, JZ);
        out.push((lp, [at(lp - 1), at(lp), at(lp + 1)], ls, [at(ls - 1), at(ls), at(ls + 1)]));
    }
    out
}

/// The fixed-point engine over a spectrogram from [`super::spectrogram::spectrogram_fx`].
pub fn sync_fx(s: &[u32], band: SyncBand) -> Vec<BinSyncFx> {
    sync_fx_rows(s, band, N_TIME)
}

/// [`sync_fx`] over only the first `n_rows` spectrogram frames (the rest count as outside the
/// slot, exactly like frames past 371): what the engine computes when an early decode starts
/// before the slot ends (docs/F6_SYNC.md). `n_rows = N_TIME` is [`sync_fx`].
pub fn sync_fx_rows(s: &[u32], band: SyncBand, n_rows: usize) -> Vec<BinSyncFx> {
    // Sums of at most 147 u32 cells: u64 is exact.
    let s64: Vec<u64> = s.iter().map(|&v| v as u64).collect();
    run(&s64, band, n_rows, score_fx)
        .into_iter()
        .map(|(lp, sp, ls, ss)| BinSyncFx { lag_p: lp as i8, sp, lag_s: ls as i8, ss })
        .collect()
}

/// Float twin (same formula, `f64`, no quantization).
pub fn sync_f(s: &[f64], band: SyncBand) -> Vec<BinSync> {
    run(s, band, N_TIME, |t: f64, t0: f64| 6.0 * t / (t0 - t + 6.0))
        .into_iter()
        .map(|(lp, sp, ls, ss)| BinSync {
            lag_p: lp,
            sp: [sp[0] as f32, sp[1] as f32, sp[2] as f32],
            lag_s: ls,
            ss: [ss[0] as f32, ss[1] as f32, ss[2] as f32],
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// JSTRT and JZ are what mfsk-core's f32 expressions give (its coarse_sync uses them).
    #[test]
    fn constants_match_mfsk_core_expressions() {
        let tstep = 480.0f32 / 12_000.0f32;
        assert_eq!((0.5f32 / tstep).round() as i32, JSTRT);
        assert_eq!((2.5f32 / tstep).round() as i32, JZ);
        // bounded_sync_lag_steps: block 1's frames stay inside the slot for every lag.
        assert!(JSTRT + NSSY * 36 - JZ >= 0 && JSTRT + NSSY * 42 + JZ < N_TIME as i32);
    }

    #[test]
    fn finds_a_synthetic_costas_pattern() {
        let mut s = vec![100u32; N_TIME * K_BINS];
        let (i0, lag0) = (400usize, 7i32);
        for b in 0..3 {
            for (n, &c) in COSTAS.iter().enumerate() {
                let m = (JSTRT + NSSY * (COSTAS_POS[b] + n) as i32 + lag0) as usize;
                s[m * K_BINS + i0 + 2 * c] = 5_000;
            }
        }
        let band = SyncBand { ia: 390, ib: 410 };
        let r = sync_fx(&s, band);
        let best = r.iter().enumerate().max_by_key(|(_, b)| b.sp[1]).unwrap();
        assert_eq!(best.0 + band.ia, i0);
        assert_eq!(best.1.lag_p as i32, lag0);
        assert_eq!(best.1.lag_s as i32, lag0);
    }
}
