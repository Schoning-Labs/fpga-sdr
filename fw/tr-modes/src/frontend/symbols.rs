// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Bit-exact model of the candidate engine's second pass, which turns one candidate's baseband
//! into the 79 x 8 complex tone values the soft-decision decoder works on (ARCHITECTURE 3.12 (d)).
//!
//! Input: one candidate's pass-1 baseband `y[m]` (m = 0 .. 3,199, zero outside), a 32-bit
//! rotation increment `rinc = round((21.875 Hz - delf) * 2^32 / 200)` and a start sample `i0`
//! (both from the CPU's fine sync: delf in 0.5 Hz steps, i0 in 5 ms steps, may be negative).
//!
//! 1. Rotate (phase continuous over the whole baseband, 0 at m = 0), table index
//!    `((m * rinc + 2^19) mod 2^32) >> 20`: `z = y (c + j s)`, each part `(... + 2^16) >> 17` (22-bit).
//!    This moves tone 0 of the refined carrier to 0 Hz and tone t to t x 6.25 Hz.
//! 2. For symbol s = 0 .. 78 and tone t = 0 .. 7: `C[s][t] = (sum_{n=0..31} z[i0 + 32 s + n]
//!    W_32^(t n mod 32) + 2^16) >> 17` per part (27-bit), W from the 32-entry twiddle ROM.
//!
//! The result is what WSJT-X `ft8b` gets from `twkfreq` followed by a 32-point DFT per symbol
//! (bins 0 .. 7 only), with the same per-symbol phase reference, so the coherent 2- and 3-symbol
//! LLRs work unchanged.

use super::tables::Tables;
use super::{BB_LEN, BB_RATE, BB_SPS, NN, NTONES};

/// Fixed-point tone values: `[symbol][tone]` as (re, im), 27-bit signed.
pub type SymbolsFx = [[(i32, i32); NTONES]; NN];
/// Float twin of `SymbolsFx`, same scale.
pub type SymbolsF = [[(f64, f64); NTONES]; NN];

/// Rotation increment for a fine frequency offset `delf_hz` (CPU side).
pub fn rot_inc(delf_hz: f64) -> u32 {
    let f = super::CENTRE_OFFSET_HZ as f64 - delf_hz;
    let v = libm::round(f * 4_294_967_296.0 / BB_RATE as f64);
    (v as i64).rem_euclid(1 << 32) as u32
}

/// Fixed-point pass 2 for the baseband `y`, rotation increment `rinc` and start sample `i0`.
/// The `debug_assert` checks the 27-bit width stated in the module header.
pub fn symbols_fx(t: &Tables, y: &[(i32, i32)], rinc: u32, i0: i32) -> SymbolsFx {
    let z = |m: i64| -> (i64, i64) {
        if m < 0 || m >= BB_LEN as i64 || m as usize >= y.len() {
            return (0, 0);
        }
        let p = (m as u32).wrapping_mul(rinc);
        let (c, s) = t.nco[super::baseband::nco_index(p)];
        let (c, s) = (c as i64, s as i64);
        let (yr, yi) = (y[m as usize].0 as i64, y[m as usize].1 as i64);
        ((yr * c - yi * s + (1 << 16)) >> 17, (yr * s + yi * c + (1 << 16)) >> 17)
    };
    let mut out = [[(0i32, 0i32); NTONES]; NN];
    for (s, row) in out.iter_mut().enumerate() {
        let start = i0 as i64 + (s * BB_SPS) as i64;
        let zs: [(i64, i64); BB_SPS] = core::array::from_fn(|n| z(start + n as i64));
        for (tone, cell) in row.iter_mut().enumerate() {
            let (mut ar, mut ai) = (0i64, 0i64);
            for (n, &(zr, zi)) in zs.iter().enumerate() {
                let (wr, wi) = t.w32[(tone * n) % BB_SPS];
                let (wr, wi) = (wr as i64, wi as i64);
                ar += zr * wr - zi * wi;
                ai += zr * wi + zi * wr;
            }
            let cr = (ar + (1 << 16)) >> 17;
            let ci = (ai + (1 << 16)) >> 17;
            debug_assert!(cr.abs() < 1 << 26 && ci.abs() < 1 << 26);
            *cell = (cr as i32, ci as i32);
        }
    }
    out
}

/// Float twin of `symbols_fx`: exact trig, no rounding, same scale.
pub fn symbols_f(y: &[(f64, f64)], rinc: u32, i0: i32) -> SymbolsF {
    let z = |m: i64| -> (f64, f64) {
        if m < 0 || m >= BB_LEN as i64 || m as usize >= y.len() {
            return (0.0, 0.0);
        }
        let p = (m as u32).wrapping_mul(rinc);
        let (s, c) = libm::sincos(2.0 * core::f64::consts::PI * p as f64 / 4_294_967_296.0);
        let (yr, yi) = y[m as usize];
        (yr * c - yi * s, yr * s + yi * c)
    };
    let mut out = [[(0f64, 0f64); NTONES]; NN];
    for (s, row) in out.iter_mut().enumerate() {
        let start = i0 as i64 + (s * BB_SPS) as i64;
        let zs: [(f64, f64); BB_SPS] = core::array::from_fn(|n| z(start + n as i64));
        for (tone, cell) in row.iter_mut().enumerate() {
            let (mut ar, mut ai) = (0f64, 0f64);
            for (n, &(zr, zi)) in zs.iter().enumerate() {
                let (sn, cs) = libm::sincos(2.0 * core::f64::consts::PI * ((tone * n) % BB_SPS) as f64 / BB_SPS as f64);
                let (wr, wi) = (cs, -sn);
                ar += zr * wr - zi * wi;
                ai += zr * wi + zi * wr;
            }
            *cell = (ar, ai);
        }
    }
    out
}
