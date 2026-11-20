// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Input scaling and noise blanker (docs/R4_BACKEND.md section 3.1), at the receiver bank's
//! rate. Same algorithm as [`crate::blanker::NoiseBlanker`] (leaky-minimum floor, hold the last
//! good sample), in integers: magnitude by alpha-max-plus-beta-min (`max + 3/8 min`, at most
//! 6.8 % high), the floor as unsigned 24.16 fixed point with shift-based time constants, and the
//! threshold as a U4.4 factor.

use super::fix::sat;

/// Blanker settings (one receiver).
#[derive(Clone, Copy, Debug)]
pub struct NbConfig {
    pub enable: bool,
    /// Trigger when `mag > floor * thr / 16` (U4.4, 1..255).
    pub thr: u8,
    /// Samples to hold the last good sample once triggered.
    pub hold: u16,
    /// Floor time constant while the magnitude is below the floor: 2^k_down samples.
    pub k_down: u8,
    /// Floor time constant while the magnitude is above the floor: 2^k_up samples.
    pub k_up: u8,
}

impl Default for NbConfig {
    fn default() -> Self {
        NbConfig { enable: false, thr: 6 * 16, hold: 38, k_down: 8, k_up: 13 }
    }
}

/// State of the noise blanker of one receiver.
#[derive(Clone, Debug, Default)]
pub struct Nb {
    floor: i64,
    primed: bool,
    holding: i64,
    last: (i64, i64),
    /// Samples replaced since the receiver was enabled (status register, 32-bit wrap).
    pub blanked: u32,
}

/// alpha-max-plus-beta-min magnitude: `max + (min >> 2) + (min >> 3)`.
#[inline]
pub fn approx_mag(i: i64, q: i64) -> i64 {
    let (a, b) = (i.abs(), q.abs());
    let (mx, mn) = if a >= b { (a, b) } else { (b, a) };
    mx + (mn >> 2) + (mn >> 3)
}

impl Nb {
    /// One input sample, already scaled to 24 bits. Returns the (possibly held) sample.
    pub fn process(&mut self, cfg: &NbConfig, x: (i64, i64)) -> (i64, i64) {
        let mag = approx_mag(x.0, x.1);
        let m16 = mag << 16;
        if !self.primed {
            self.floor = m16;
            self.primed = true;
        } else if m16 < self.floor {
            self.floor += (m16 - self.floor) >> cfg.k_down;
        } else {
            self.floor += (m16 - self.floor) >> cfg.k_up;
        }
        if !cfg.enable {
            self.holding = 0;
            self.last = x;
            return x;
        }
        if self.holding == 0 && (mag << 4) > (self.floor >> 16) * cfg.thr as i64 {
            self.holding = cfg.hold as i64;
        }
        if self.holding > 0 {
            self.holding -= 1;
            self.blanked = self.blanked.wrapping_add(1);
            self.last
        } else {
            self.last = x;
            x
        }
    }
}

/// Input scaling: `sat24(v << shift)`.
#[inline]
pub fn scale_in(v: i64, shift: u8) -> i64 {
    sat(v << shift, 24)
}
