// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Bit-exact model of the candidate engine's first pass, the down-conversion from the 12 ksps
//! audio to a 200 sps complex baseband around one candidate (ARCHITECTURE 3.12 (d)).
//!
//! Input: the slot's audio `x[n]`, n = 0 .. 179,999 (samples outside the slot count as 0), and
//! a 32-bit NCO increment `inc` from the CPU (`round((f0 + 21.875 Hz) * 2^32 / 12,000)`: the NCO
//! sits on the center of the 8-tone signal whose tone 0 is at f0).
//!
//! 1. NCO phase `p[n] = n * inc mod 2^32` (0 at the slot's first sample); table index
//!    `((p + 2^19) mod 2^32) >> 20` (rounded; 4,096-entry cos/sin ROM, 18-bit).
//! 2. Mix to `e^(-j p)`: `mr = (x c + 2^12) >> 13`, `mi = (-x s + 2^12) >> 13` (21-bit signed).
//! 3. CIC, 4 stages, decimation 30, differential delay 1 (400 sps): exact integer sums (41-bit
//!    registers suffice; integrators may wrap). Output j is the 4th-order boxcar sum ending at
//!    input `30 j + 58`, so it is centered on input `30 j`. `q[j] = (cic + 2^15) >> 16` (25-bit).
//! 4. FIR, 65 symmetric taps (18-bit, `tables::Tables::fir`), decimation 2:
//!    `y[k] = (sum_{i=0..64} h[i] q[2k + 32 - i] + 2^19) >> 20`, k = 0 .. 3,199 (22-bit).
//!
//! So `y[k]` is centered on audio sample `60 k`, i.e. time k / 200 s from the slot start, the same
//! time base as WSJT-X's `cd0`. DC gain from x to y is `131071 / 2^13 * 810000 / 2^16 *
//! sum(h) / 2^20 = 16.0`; a tone of amplitude A at f0 + 21.875 Hz becomes a DC phasor of
//! magnitude 8 A. Response around the NCO (the eight tones sit at -21.875 .. +21.875 Hz):
//! -0.17 dB at 20 Hz, -1.1 dB at 25 Hz, -32 dB at 40 Hz, below -60 dB from 45 Hz, below -98 dB
//! from 80 Hz (aliases included).

use alloc::vec;
use alloc::vec::Vec;

use super::tables::Tables;
use super::{BB_LEN, FS, SLOT_LEN};

/// CIC decimation ratio (12,000 sps to 400 sps).
pub const CIC_R: usize = 30;
/// Number of CIC stages.
pub const CIC_N: usize = 4;
/// Samples of the 4th-order boxcar minus one: 4 x 29.
const CIC_SPAN: usize = CIC_N * (CIC_R - 1);
const CIC_CENTRE: usize = CIC_SPAN / 2; // 58
/// Half the FIR length, which is also its delay in 400 sps samples.
const FIR_HALF: usize = 32;

/// NCO table index of a 32-bit phase: the top 12 bits, rounded (`(p + 2^19) >> 20` mod 4,096),
/// so the phase error is zero-mean (at most +/- pi / 4,096).
#[inline]
pub fn nco_index(p: u32) -> usize {
    (p.wrapping_add(1 << 19) >> 20) as usize
}

/// NCO increment for a candidate whose tone 0 is at `f0_hz` (CPU side).
pub fn nco_inc(f0_hz: f64) -> u32 {
    let f = f0_hz + super::CENTRE_OFFSET_HZ as f64;
    let v = libm::round(f * 4_294_967_296.0 / FS as f64);
    (v as i64).rem_euclid(1 << 32) as u32
}

/// Four cascaded length-30 running sums: `out[n] = sum_{i=0..116} h4[i] a[n - i]`, n = 0 .. len.
fn boxcar4<T: Copy + Default + core::ops::Add<Output = T> + core::ops::Sub<Output = T>>(a: &[T], len: usize) -> Vec<T> {
    let mut cur: Vec<T> = (0..len).map(|n| a.get(n).copied().unwrap_or_default()).collect();
    for _ in 0..CIC_N {
        let mut next = vec![T::default(); len];
        let mut acc = T::default();
        for n in 0..len {
            acc = acc + cur[n];
            if n >= CIC_R {
                acc = acc - cur[n - CIC_R];
            }
            next[n] = acc;
        }
        cur = next;
    }
    cur
}

/// Fixed-point pass 1: 3,200 complex samples (re, im) at 200 sps for the NCO increment `inc`.
/// The `debug_assert`s check the register widths stated in the module header.
pub fn baseband_fx(t: &Tables, audio: &[i16], inc: u32) -> Vec<(i32, i32)> {
    let n_in = audio.len().min(SLOT_LEN);
    let mut mr = vec![0i64; n_in];
    let mut mi = vec![0i64; n_in];
    for n in 0..n_in {
        let p = (n as u32).wrapping_mul(inc);
        let (c, s) = t.nco[nco_index(p)];
        let x = audio[n] as i64;
        mr[n] = (x * c as i64 + (1 << 12)) >> 13;
        mi[n] = (-x * s as i64 + (1 << 12)) >> 13;
    }
    let len = SLOT_LEN + CIC_SPAN;
    let br = boxcar4(&mr, len);
    let bi = boxcar4(&mi, len);
    // q[j] for j = -1 .. JQ; index offset 1 so q[-1] is stored at 0.
    let jq = (len - 1 - CIC_CENTRE) / CIC_R + 1;
    let q = |b: &Vec<i64>, j: isize| -> i64 {
        let n = j * CIC_R as isize + CIC_CENTRE as isize;
        if n < 0 || n as usize >= len {
            0
        } else {
            let v = (b[n as usize] + (1 << 15)) >> 16;
            debug_assert!(v.abs() < 1 << 24, "CIC output exceeds 25 bits");
            v
        }
    };
    let qr: Vec<i64> = (-1..jq as isize).map(|j| q(&br, j)).collect();
    let qi: Vec<i64> = (-1..jq as isize).map(|j| q(&bi, j)).collect();
    let qat = |v: &Vec<i64>, j: isize| -> i64 {
        if j < -1 || j + 1 >= v.len() as isize {
            0
        } else {
            v[(j + 1) as usize]
        }
    };
    let mut out = Vec::with_capacity(BB_LEN);
    for k in 0..BB_LEN {
        let (mut ar, mut ai) = (0i64, 0i64);
        for (i, &h) in t.fir.iter().enumerate() {
            let j = (2 * k + FIR_HALF) as isize - i as isize;
            ar += h as i64 * qat(&qr, j);
            ai += h as i64 * qat(&qi, j);
        }
        let yr = (ar + (1 << 19)) >> 20;
        let yi = (ai + (1 << 19)) >> 20;
        debug_assert!(yr.abs() < 1 << 21 && yi.abs() < 1 << 21, "baseband exceeds 22 bits");
        out.push((yr as i32, yi as i32));
    }
    out
}

/// Float twin: exact NCO phase and trig, exact CIC, unquantized FIR, same scale.
pub fn baseband_f(t: &Tables, audio: &[i16], inc: u32) -> Vec<(f64, f64)> {
    let n_in = audio.len().min(SLOT_LEN);
    let g = super::tables::TW_SCALE / 8_192.0;
    let mut mr = vec![0f64; n_in];
    let mut mi = vec![0f64; n_in];
    for n in 0..n_in {
        let p = (n as u32).wrapping_mul(inc);
        let a = 2.0 * core::f64::consts::PI * p as f64 / 4_294_967_296.0;
        let (s, c) = libm::sincos(a);
        let x = audio[n] as f64 * g;
        mr[n] = x * c;
        mi[n] = -x * s;
    }
    let len = SLOT_LEN + CIC_SPAN;
    let br = boxcar4(&mr, len);
    let bi = boxcar4(&mi, len);
    let sc = 1.0 / 65_536.0;
    let q = |b: &Vec<f64>, j: isize| -> f64 {
        let n = j * CIC_R as isize + CIC_CENTRE as isize;
        if n < 0 || n as usize >= len {
            0.0
        } else {
            b[n as usize] * sc
        }
    };
    let mut out = Vec::with_capacity(BB_LEN);
    for k in 0..BB_LEN {
        let (mut ar, mut ai) = (0f64, 0f64);
        for (i, &h) in t.fir_f.iter().enumerate() {
            let j = (2 * k + FIR_HALF) as isize - i as isize;
            ar += h * q(&br, j);
            ai += h * q(&bi, j);
        }
        out.push((ar / 1_048_576.0, ai / 1_048_576.0));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(f: f64, a: f64) -> Vec<i16> {
        (0..SLOT_LEN).map(|n| (a * (2.0 * core::f64::consts::PI * f * n as f64 / 12_000.0).cos()).round() as i16).collect()
    }

    /// A tone on the NCO frequency comes out as a steady phasor of 8 A; the fixed and float
    /// models agree to a small fraction of an LSB-scaled amount.
    #[test]
    fn tone_gain_and_float_agreement() {
        let t = Tables::new();
        let f0 = 1_000.0;
        let inc = nco_inc(f0);
        let a = 10_000.0;
        let audio = tone(f0 + 21.875, a);
        let y = baseband_fx(&t, &audio, inc);
        let yf = baseband_f(&t, &audio, inc);
        for k in [500usize, 1_500, 2_900] {
            let m = ((y[k].0 as f64).powi(2) + (y[k].1 as f64).powi(2)).sqrt();
            assert!((m / (8.0 * a) - 1.0).abs() < 0.01, "k{k}: |y| = {m}");
            assert!((y[k].0 as f64 - yf[k].0).abs() < 8.0 && (y[k].1 as f64 - yf[k].1).abs() < 8.0);
        }
    }

    /// A tone 45 Hz off the NCO is in the stop band; one 20 Hz off is in the pass band.
    #[test]
    fn selectivity() {
        let t = Tables::new();
        let inc = nco_inc(1_000.0);
        let centre = 1_021.875;
        let lvl = |df: f64| -> f64 {
            let y = baseband_fx(&t, &tone(centre + df, 10_000.0), inc);
            let p: f64 = y[600..2_600].iter().map(|v| (v.0 as f64).powi(2) + (v.1 as f64).powi(2)).sum::<f64>() / 2_000.0;
            10.0 * (p.sqrt() / 80_000.0).log10() * 2.0
        };
        for df in [0.0, 10.0, 20.0, 25.0, 30.0, 35.0, 40.0, 45.0, 50.0, 60.0, 80.0, 120.0, 180.0] {
            eprintln!("FIR response {df:5.1} Hz off centre: {:7.2} dB", lvl(df));
        }
        assert!(lvl(20.0).abs() < 0.5, "20 Hz: {}", lvl(20.0));
        assert!(lvl(-20.0).abs() < 0.5);
        assert!(lvl(45.0) < -40.0, "45 Hz: {}", lvl(45.0));
        assert!(lvl(-60.0) < -55.0, "-60 Hz: {}", lvl(-60.0));
        assert!(lvl(180.0) < -60.0, "180 Hz (alias): {}", lvl(180.0));
    }
}
