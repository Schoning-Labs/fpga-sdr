// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Complex channel filter at 24 ksps, up to 1,024 taps (docs/R4_BACKEND.md section 3.3).
//!
//! `y[k] = sum_{n < ntaps} c[n] x[k-n]` with complex 32-bit coefficients whose value is
//! `c * 2^-(30 + exp)` (a per-bank exponent, so narrow filters use the full 32 bits) and complex
//! 24-bit data. Each of the four real products per tap is truncated by 16 bits (floor) before it
//! is accumulated, exactly as the RTL's accumulators do; the output is
//! `sat24((acc + 2^(13+exp)) >> (14+exp))`. Taps not yet covered by samples written since the
//! receiver was enabled read zero.

use super::fix::sat;

/// Most taps of the channel filter.
pub const MAX_TAPS: usize = 1024;

/// One coefficient bank (what the firmware writes through the coefficient window).
#[derive(Clone, Debug)]
pub struct CoefBank {
    /// Number of taps used, 1..=1024.
    pub ntaps: u16,
    /// Scale exponent: coefficient value = c * 2^-(30 + exp), exp 0..=15.
    pub exp: u8,
    pub re: [i32; MAX_TAPS],
    pub im: [i32; MAX_TAPS],
}

impl CoefBank {
    pub const fn zero() -> Self {
        CoefBank { ntaps: 1, exp: 0, re: [0; MAX_TAPS], im: [0; MAX_TAPS] }
    }

    /// A single-tap bank with gain 1.0 (the pass-through filter).
    pub fn identity() -> Self {
        let mut b = Self::zero();
        b.re[0] = 1 << 30;
        b
    }
}

/// The complex channel filter at 24 ksps of one receiver.
#[derive(Clone, Debug)]
pub struct ChannelFilter {
    buf: [(i64, i64); MAX_TAPS],
    w: usize,
    fill: usize,
}

impl Default for ChannelFilter {
    fn default() -> Self {
        ChannelFilter { buf: [(0, 0); MAX_TAPS], w: 0, fill: 0 }
    }
}

impl ChannelFilter {
    /// Writes one complex sample and returns the filter output for it.
    pub fn push(&mut self, bank: &CoefBank, x: (i64, i64)) -> (i64, i64) {
        let idx = self.w;
        self.buf[idx] = x;
        self.w = (self.w + 1) & (MAX_TAPS - 1);
        if self.fill < MAX_TAPS {
            self.fill += 1;
        }
        let (mut ar, mut ai) = (0i64, 0i64);
        let n = (bank.ntaps as usize).clamp(1, MAX_TAPS);
        for k in 0..n.min(self.fill) {
            let (xr, xi) = self.buf[idx.wrapping_sub(k) & (MAX_TAPS - 1)];
            let (cr, ci) = (bank.re[k] as i64, bank.im[k] as i64);
            ar += ((cr * xr) >> 16) - ((ci * xi) >> 16);
            ai += ((cr * xi) >> 16) + ((ci * xr) >> 16);
        }
        let sh = 14 + bank.exp as u32;
        let r = 1i64 << (sh - 1);
        (sat((ar + r) >> sh, 24), sat((ai + r) >> sh, 24))
    }
}
