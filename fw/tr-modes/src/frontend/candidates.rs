// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Franz Schöning, https://www.schoning.com
// Follows the tail of WSJT-X (K1JT and contributors, GPL-3.0-or-later) routine `sync8` through
// mfsk-core's `coarse_sync`; modified 2026 by Franz Schöning to take the FPGA sync engine's output.

//! CPU side: the candidate list built from the sync engine's per-bin results, formed exactly as
//! the tail of mfsk-core's `coarse_sync` (and WSJT-X `sync8`) forms it. Each window's best scores
//! are normalized by their 40th percentile over the band, bins at or above `sync_min` are kept,
//! dt is refined by a parabola through the scores at lag - 1, lag and lag + 1, the list is sorted
//! by score, near-duplicates (under 4 Hz and 0.04 s apart) are dropped and at most `max_cand` are
//! kept. With about 1,000 bins this costs well under a million instructions.

use alloc::vec::Vec;

use mfsk_core::engine::sync::SyncCandidate;

use super::sync::{BinSync, SyncBand, JZ};
use super::{DF_HZ, FS, NSTEP};

/// The 40th percentile of the scores, used as the noise floor to normalize by (never below
/// `f32::EPSILON`, so the division is safe).
fn percentile_floor(red: &[f32]) -> f32 {
    let n = red.len();
    let mut sorted: Vec<f32> = red.to_vec();
    let idx = ((0.40 * n as f32) as usize).min(n - 1);
    sorted.select_nth_unstable_by(idx, |a, b| a.partial_cmp(b).unwrap_or(core::cmp::Ordering::Equal));
    sorted[idx].max(f32::EPSILON)
}

/// Fractional lag offset (in spectrogram frames, within +/-1) of the score peak, from a parabola
/// through the scores `y` at lag - 1, lag and lag + 1. Zero at the edges of the lag range.
fn dt_quanta(lag: i32, y: &[f32; 3]) -> f32 {
    if lag > -JZ && lag < JZ {
        let denom = y[0] - 2.0 * y[1] + y[2];
        if denom.abs() > f32::EPSILON {
            return (0.5 * (y[0] - y[2]) / denom).clamp(-1.0, 1.0);
        }
    }
    0.0
}

/// Candidate list, strongest first, at most `max_cand` long.
pub fn candidates(bins: &[BinSync], band: SyncBand, sync_min: f32, max_cand: usize) -> Vec<SyncCandidate> {
    if bins.is_empty() {
        return Vec::new();
    }
    let tstep = NSTEP as f32 / FS as f32;
    let red_p: Vec<f32> = bins.iter().map(|b| b.sp[1]).collect();
    let red_s: Vec<f32> = bins.iter().map(|b| b.ss[1]).collect();
    let base_p = percentile_floor(&red_p);
    let base_s = percentile_floor(&red_s);
    let mut cands: Vec<SyncCandidate> = Vec::new();
    for (fi, b) in bins.iter().enumerate() {
        let freq_hz = (band.ia + fi) as f32 * DF_HZ;
        let norm_p = b.sp[1] / base_p;
        if norm_p.is_finite() && norm_p >= sync_min {
            let dt_lag = b.lag_p as f32 + dt_quanta(b.lag_p, &b.sp);
            cands.push(SyncCandidate { freq_hz, dt_sec: (dt_lag - 0.5) * tstep, score: norm_p });
        }
        if b.lag_s != b.lag_p {
            let norm_s = b.ss[1] / base_s;
            if norm_s.is_finite() && norm_s >= sync_min {
                let dt_lag = b.lag_s as f32 + dt_quanta(b.lag_s, &b.ss);
                cands.push(SyncCandidate { freq_hz, dt_sec: (dt_lag - 0.5) * tstep, score: norm_s });
            }
        }
    }
    cands.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(core::cmp::Ordering::Equal));
    let mut out: Vec<SyncCandidate> = Vec::with_capacity(max_cand);
    for c in cands {
        if c.score < sync_min {
            break;
        }
        if out.iter().any(|k| (c.freq_hz - k.freq_hz).abs() < 4.0 && (c.dt_sec - k.dt_sec).abs() < 0.04) {
            continue;
        }
        out.push(c);
        if out.len() >= max_cand {
            break;
        }
    }
    out
}
