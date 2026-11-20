// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Bit-exact model of the spectrogram engine (ARCHITECTURE 3.12 (b), docs/F5_FT8SPEC.md), which
//! turns the slot's 12 ksps audio into a power spectrogram of 3.125 Hz bins every 40 ms.
//!
//! Frame j (0 .. 371) is audio samples `480 j .. 480 j + 1,919`, rectangular window, zero-padded
//! to 3,840 (as WSJT-X `sync8` and mfsk-core). The 3,840-point DFT is computed as 256 x 15:
//!
//! 1. For n1 = 0 .. 14: `u[n2] = a[15 n2 + n1]` (n2 = 0 .. 255; zero for `15 n2 + n1 >= 1,920`),
//!    through the streaming FFT at 256 points ([`super::fft256`]): `Y_n1[k1]`, 24-bit.
//! 2. For every kept bin k = 0 .. 1,023: `A[k] = sum_n1 Y_n1[k mod 256] * W_3840^(n1 k mod 3,840)`,
//!    full products (24 x 18 bit) summed exactly (at most 46 bits).
//! 3. `X[k] = (A[k] + 2^16) >> 17` (27-bit signed), `P = Xr^2 + Xi^2` (54-bit),
//!    stored `S[k] = min((P + 2^(sh-1)) >> sh, 2^32 - 1)` as u32; `sh` = `pwr_shift`, a
//!    per-receiver register (default 16; 0 means no shift and no rounding term).
//!
//! Step 2 needs only k2 = k / 256 = 0 .. 3 of the 15 outputs of each 15-point DFT, so it is a
//! plain complex multiply-accumulate (15 per bin, 15,360 per frame) and needs no Winograd
//! kernel. The spectrogram is stored time-major, `S[j * 1,024 + k]`.

use alloc::vec;
use alloc::vec::Vec;

use super::fft256::{fft256, fft256_f64, N as N256};
use super::tables::Tables;
use super::{K_BINS, NFFT, NSPS, NSTEP, N_TIME};

/// Default for the per-receiver power shift register.
pub const PWR_SHIFT_DEFAULT: u32 = 16;

/// Number of 256-point transforms per frame (the 15 of the 256 x 15 split).
const N1: usize = NFFT / N256; // 15

/// Complex value `(re, im)` of each of the 1,024 kept bins of frame `j` before the power step
/// (for tests and for dumping vectors for the RTL testbench).
pub fn frame_bins_fx(t: &Tables, audio: &[i16], j: usize) -> Vec<(i64, i64)> {
    let base = j * NSTEP;
    let sample = |i: usize| -> i64 {
        if i < NSPS {
            audio.get(base + i).copied().unwrap_or(0) as i64
        } else {
            0
        }
    };
    let mut y = vec![([0i64; N256], [0i64; N256]); N1];
    for (n1, (yr, yi)) in y.iter_mut().enumerate() {
        for n2 in 0..N256 {
            yr[n2] = sample(15 * n2 + n1);
        }
        fft256(t, yr, yi);
    }
    let mut out = Vec::with_capacity(K_BINS);
    for k in 0..K_BINS {
        let k1 = k % N256;
        let (mut ar, mut ai) = (0i64, 0i64);
        for (n1, (yr, yi)) in y.iter().enumerate() {
            let (wr, wi) = t.w3840[(n1 * k) % NFFT];
            let (wr, wi) = (wr as i64, wi as i64);
            ar += yr[k1] * wr - yi[k1] * wi;
            ai += yr[k1] * wi + yi[k1] * wr;
        }
        let xr = (ar + (1 << 16)) >> 17;
        let xi = (ai + (1 << 16)) >> 17;
        debug_assert!(xr.abs() < 1 << 26 && xi.abs() < 1 << 26, "X exceeds 27 bits");
        out.push((xr, xi));
    }
    out
}

/// Power word of one bin: `xr^2 + xi^2` shifted right by `sh` with rounding, saturated to 32 bits.
#[inline]
pub fn power_word(xr: i64, xi: i64, sh: u32) -> u32 {
    let p = (xr * xr + xi * xi) as u64;
    let v = if sh == 0 { p } else { (p + (1u64 << (sh - 1))) >> sh };
    v.min(u32::MAX as u64) as u32
}

/// The whole slot's spectrogram, fixed point: `N_TIME x K_BINS` u32, time-major.
pub fn spectrogram_fx(t: &Tables, audio: &[i16], pwr_shift: u32) -> Vec<u32> {
    let mut s = vec![0u32; N_TIME * K_BINS];
    for j in 0..N_TIME {
        let bins = frame_bins_fx(t, audio, j);
        for (k, &(xr, xi)) in bins.iter().enumerate() {
            s[j * K_BINS + k] = power_word(xr, xi, pwr_shift);
        }
    }
    s
}

/// Float twin: exact 3,840-point DFT power of the same frames, same `2^-pwr_shift` scale, time-major
/// like `spectrogram_fx`.
pub fn spectrogram_f(audio: &[i16], pwr_shift: u32) -> Vec<f64> {
    let tw: Vec<(f64, f64)> = (0..NFFT)
        .map(|e| {
            let (s, c) = libm::sincos(2.0 * core::f64::consts::PI * e as f64 / NFFT as f64);
            (c, -s)
        })
        .collect();
    let scale = 1.0 / (1u64 << pwr_shift) as f64;
    let mut s = vec![0f64; N_TIME * K_BINS];
    let mut y = vec![([0f64; N256], [0f64; N256]); N1];
    for j in 0..N_TIME {
        let base = j * NSTEP;
        for (n1, (yr, yi)) in y.iter_mut().enumerate() {
            for n2 in 0..N256 {
                let i = 15 * n2 + n1;
                yr[n2] = if i < NSPS { audio.get(base + i).copied().unwrap_or(0) as f64 } else { 0.0 };
                yi[n2] = 0.0;
            }
            fft256_f64(yr, yi);
        }
        for k in 0..K_BINS {
            let k1 = k % N256;
            let (mut ar, mut ai) = (0f64, 0f64);
            for (n1, (yr, yi)) in y.iter().enumerate() {
                let (wr, wi) = tw[(n1 * k) % NFFT];
                ar += yr[k1] * wr - yi[k1] * wi;
                ai += yr[k1] * wi + yi[k1] * wr;
            }
            s[j * K_BINS + k] = (ar * ar + ai * ai) * scale;
        }
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The 256 x 15 structure computes the 3,840-point DFT of the zero-padded frame: compare a
    /// few frames of a two-tone-plus-noise signal against a direct double-precision DFT.
    #[test]
    fn equals_direct_dft() {
        let t = Tables::new();
        let mut st = 7u64;
        let audio: Vec<i16> = (0..30_000)
            .map(|n| {
                st = st.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
                let noise = ((st >> 40) as f64 / (1u64 << 24) as f64 - 0.5) * 2_000.0;
                let a = 2.0 * core::f64::consts::PI * n as f64 / 12_000.0;
                (8_000.0 * (a * 1_000.0).cos() + 3_000.0 * (a * 2_345.6).sin() + noise) as i16
            })
            .collect();
        for j in [0usize, 7, 40] {
            let bins = frame_bins_fx(&t, &audio, j);
            for k in [0usize, 100, 320, 321, 750, 1_023] {
                let (mut dr, mut di) = (0f64, 0f64);
                for i in 0..NSPS {
                    let x = audio[j * NSTEP + i] as f64;
                    let a = -2.0 * core::f64::consts::PI * (k * i) as f64 / NFFT as f64;
                    dr += x * a.cos();
                    di += x * a.sin();
                }
                let (xr, xi) = bins[k];
                let tol = 1e-4 * (dr.hypot(di)) + 40.0;
                assert!((xr as f64 - dr).abs() < tol && (xi as f64 - di).abs() < tol, "j{j} k{k}: {xr},{xi} vs {dr},{di}");
            }
        }
    }

    /// Full-scale input cannot overflow any stage.
    #[test]
    fn full_scale_no_overflow() {
        let t = Tables::new();
        let audio = vec![32_767i16; 4_000];
        let bins = frame_bins_fx(&t, &audio, 0);
        let expect = 1_920.0 * 32_767.0;
        assert!(((bins[0].0 as f64) - expect).abs() / expect < 1e-4);
        let neg = vec![-32_768i16; 4_000];
        let bins = frame_bins_fx(&t, &neg, 0);
        assert!(bins[0].0 < 0);
        assert_eq!(power_word(bins[0].0, bins[0].1, 0), u32::MAX);
    }
}
