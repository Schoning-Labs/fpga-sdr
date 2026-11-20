// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Channel-filter coefficient design for the back end (firmware side: the firmware calls it to build the banks it writes).
//!
//! The float design is the same windowed-sinc as [`crate::fastconv::BandpassFilter::design`]
//! (Blackman-Harris lowpass of half-width `(high-low)/2`, DC gain normalized to 1, modulated to
//! the pass-band center with `t = n - (ntaps-1)/2`), in `f64` and at 24 ksps with up to 1,024
//! taps. [`quantize`] turns it into the integer bank the firmware writes: 32-bit real and
//! imaginary parts and one exponent, chosen so the largest coefficient uses the full 32 bits.

use super::chfilt::{CoefBank, MAX_TAPS};

/// Sample rate of the channel filter in Hz.
pub const FS: f64 = 24_000.0;

/// Float coefficients of one design.
#[derive(Clone)]
pub struct FloatDesign {
    pub ntaps: usize,
    pub re: [f64; MAX_TAPS],
    pub im: [f64; MAX_TAPS],
}

fn blackman_harris(n: usize, len: usize) -> f64 {
    if len <= 1 {
        return 1.0;
    }
    let x = core::f64::consts::TAU * n as f64 / (len - 1) as f64;
    0.358_75 - 0.488_29 * libm::cos(x) + 0.141_28 * libm::cos(2.0 * x) - 0.011_68 * libm::cos(3.0 * x)
}

fn sinc(x: f64) -> f64 {
    if libm::fabs(x) < 1e-12 {
        1.0
    } else {
        let px = core::f64::consts::PI * x;
        libm::sin(px) / px
    }
}

/// Band-pass `[low_hz, high_hz]` at sample rate `fs` (either edge may be negative).
pub fn bandpass(fs: f64, low_hz: f64, high_hz: f64, ntaps: usize) -> FloatDesign {
    let ntaps = ntaps.clamp(1, MAX_TAPS);
    let center = 0.5 * (low_hz + high_hz);
    let half_bw = 0.5 * (high_hz - low_hz);
    let mid = (ntaps - 1) as f64 / 2.0;
    let mut lpf = [0.0f64; MAX_TAPS];
    let mut sum = 0.0;
    for (n, v) in lpf.iter_mut().enumerate().take(ntaps) {
        let t = n as f64 - mid;
        *v = 2.0 * half_bw / fs * sinc(2.0 * half_bw / fs * t) * blackman_harris(n, ntaps);
        sum += *v;
    }
    let mut d = FloatDesign { ntaps, re: [0.0; MAX_TAPS], im: [0.0; MAX_TAPS] };
    for n in 0..ntaps {
        let t = n as f64 - mid;
        let ph = core::f64::consts::TAU * center * t / fs;
        let v = lpf[n] / sum;
        d.re[n] = v * libm::cos(ph);
        d.im[n] = v * libm::sin(ph);
    }
    d
}

/// Integer bank for a float design: exponent as large as possible (0..15) with every
/// coefficient still inside 32 bits.
pub fn quantize(d: &FloatDesign) -> CoefBank {
    let mut peak = 0.0f64;
    for n in 0..d.ntaps {
        peak = peak.max(libm::fabs(d.re[n])).max(libm::fabs(d.im[n]));
    }
    let mut exp = 0u8;
    while exp < 15 && libm::round(peak * libm::ldexp(1.0, 31 + exp as i32)) <= 2_147_483_647.0 {
        exp += 1;
    }
    let scale = libm::ldexp(1.0, 30 + exp as i32);
    let mut b = CoefBank::zero();
    b.ntaps = d.ntaps as u16;
    b.exp = exp;
    for n in 0..d.ntaps {
        b.re[n] = libm::round(d.re[n] * scale) as i32;
        b.im[n] = libm::round(d.im[n] * scale) as i32;
    }
    b
}

/// [`quantize`]`(&`[`bandpass`]`(fs, low_hz, high_hz, ntaps))` without the 24 KB of arrays on the
/// stack: the float taps go into `scratch` (at least `2 * ntaps` values, any memory), the integer
/// taps into `re` and `im` (at least `ntaps` each). Bit for bit the same result. Returns the tap
/// count and the exponent of the bank. For a firmware whose stack is small (the AE350's is 32 KB).
pub fn bandpass_quantized_into(fs: f64, low_hz: f64, high_hz: f64, ntaps: usize, re: &mut [i32], im: &mut [i32], scratch: &mut [f64]) -> (u16, u8) {
    let ntaps = ntaps.clamp(1, MAX_TAPS);
    assert!(re.len() >= ntaps && im.len() >= ntaps && scratch.len() >= 2 * ntaps);
    let (fre, fim) = scratch.split_at_mut(ntaps);
    let center = 0.5 * (low_hz + high_hz);
    let half_bw = 0.5 * (high_hz - low_hz);
    let mid = (ntaps - 1) as f64 / 2.0;
    // the low-pass first (in `fre`), summed in the same order as `bandpass`
    let mut sum = 0.0;
    for (n, v) in fre.iter_mut().enumerate().take(ntaps) {
        let t = n as f64 - mid;
        *v = 2.0 * half_bw / fs * sinc(2.0 * half_bw / fs * t) * blackman_harris(n, ntaps);
        sum += *v;
    }
    let mut peak = 0.0f64;
    for n in 0..ntaps {
        let t = n as f64 - mid;
        let ph = core::f64::consts::TAU * center * t / fs;
        let v = fre[n] / sum;
        fre[n] = v * libm::cos(ph);
        fim[n] = v * libm::sin(ph);
        peak = peak.max(libm::fabs(fre[n])).max(libm::fabs(fim[n]));
    }
    let mut exp = 0u8;
    while exp < 15 && libm::round(peak * libm::ldexp(1.0, 31 + exp as i32)) <= 2_147_483_647.0 {
        exp += 1;
    }
    let scale = libm::ldexp(1.0, 30 + exp as i32);
    for n in 0..ntaps {
        re[n] = libm::round(fre[n] * scale) as i32;
        im[n] = libm::round(fim[n] * scale) as i32;
    }
    (ntaps as u16, exp)
}

/// Magnitude of a float design's response at `f_hz`.
pub fn response(d: &FloatDesign, f_hz: f64, fs: f64) -> f64 {
    let (mut sr, mut si) = (0.0, 0.0);
    for n in 0..d.ntaps {
        let ph = -core::f64::consts::TAU * f_hz * n as f64 / fs;
        let (c, s) = (libm::cos(ph), libm::sin(ph));
        sr += d.re[n] * c - d.im[n] * s;
        si += d.re[n] * s + d.im[n] * c;
    }
    libm::sqrt(sr * sr + si * si)
}

/// The float design an integer bank represents exactly (for comparisons).
pub fn dequantize(b: &CoefBank) -> FloatDesign {
    let scale = libm::ldexp(1.0, -(30 + b.exp as i32));
    let mut d = FloatDesign { ntaps: b.ntaps as usize, re: [0.0; MAX_TAPS], im: [0.0; MAX_TAPS] };
    for n in 0..d.ntaps {
        d.re[n] = b.re[n] as f64 * scale;
        d.im[n] = b.im[n] as f64 * scale;
    }
    d
}
