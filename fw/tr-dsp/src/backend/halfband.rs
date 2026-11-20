// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Half-band decimate-by-2 stages (docs/R4_BACKEND.md sections 3.2 and 3.7): the cascade from
//! the bank's 48-384 ksps down to 24 ksps (HB1..HB4) and the audio half-band from 24 to 12 ksps
//! (HB5, the HB4 coefficients again).
//!
//! Semantics the RTL follows exactly: the new sample is written at the write index `w`, taps
//! read `x[w - offset]` (circular, delay-line length a power of two); a tap whose offset is not
//! yet covered by samples written since the receiver was enabled reads zero; an output is
//! computed after every second input (the 2nd, 4th, ... since enable), as
//! `sat24((sum(c * x) + 2^24) >> 25)` with Q25 coefficients.

use super::fix::sat;
use super::tables::{HB_LAYOUT, HB_TAPS};

/// Longest delay line of a half-band stage.
pub const MAX_LEN: usize = 64;

/// One half-band decimate-by-2 stage.
#[derive(Clone, Debug)]
pub struct HalfBand {
    stage: usize,
    buf: [(i64, i64); MAX_LEN],
    w: usize,
    fill: usize,
    phase: bool,
}

impl HalfBand {
    /// `stage` 0..3 = HB1..HB4 (HB5 uses stage 3's coefficients).
    pub fn new(stage: usize) -> Self {
        HalfBand { stage, buf: [(0, 0); MAX_LEN], w: 0, fill: 0, phase: false }
    }

    /// Pushes one complex sample; returns an output after every second call.
    pub fn push(&mut self, x: (i64, i64)) -> Option<(i64, i64)> {
        let (start, count, len) = HB_LAYOUT[self.stage];
        let mask = len - 1;
        let idx = self.w;
        self.buf[idx] = x;
        self.w = (self.w + 1) & mask;
        if self.fill < len {
            self.fill += 1;
        }
        self.phase = !self.phase;
        if self.phase {
            return None;
        }
        let (mut ai, mut aq) = (0i64, 0i64);
        for &(off, c) in &HB_TAPS[start..start + count] {
            if off < self.fill {
                let s = self.buf[(idx.wrapping_sub(off)) & mask];
                ai += c * s.0;
                aq += c * s.1;
            }
        }
        Some((sat((ai + (1 << 24)) >> 25, 24), sat((aq + (1 << 24)) >> 25, 24)))
    }
}

/// The decimation cascade for one input rate (`in_rate` 0..3 = 48/96/192/384 ksps).
#[derive(Clone, Debug)]
pub struct Decimator {
    stages: [HalfBand; 4],
    first: usize,
}

impl Decimator {
    /// A stage for the bank rate selected by `in_rate`.
    pub fn new(in_rate: u8) -> Self {
        Decimator {
            stages: [HalfBand::new(0), HalfBand::new(1), HalfBand::new(2), HalfBand::new(3)],
            first: 3 - in_rate as usize,
        }
    }

    /// One bank-rate sample in; a 24 ksps sample out when the cascade completes one.
    pub fn push(&mut self, x: (i64, i64)) -> Option<(i64, i64)> {
        let mut v = x;
        for s in self.first..4 {
            v = self.stages[s].push(v)?;
        }
        Some(v)
    }
}
