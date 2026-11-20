// SPDX-License-Identifier: LGPL-2.1-only
// Copyright 2026 Franz Schöning, https://www.schoning.com
// (own code, not a translation; under the crate's licence so the crate has one licence)

//! Sample-rate conversion by a ratio of small integers `L / M` (polyphase windowed-sinc FIR,
//! `f32`, no heap). FreeDV works at 8 kHz; the radio's receive audio ring is 12 kHz (`L = 2`,
//! `M = 3` in, `L = 3`, `M = 2` out) and its audio outputs run at 48 kHz (`L = 6`, `M = 1`).

/// Taps per phase.
pub const TAPS: usize = 24;
/// Largest interpolation factor.
pub const L_MAX: usize = 6;

pub struct Resampler {
    l: usize,
    m: usize,
    /// `coef[phase * TAPS + k]` multiplies the sample `k` back from the newest.
    coef: [f32; L_MAX * TAPS],
    hist: [f32; TAPS],
    /// Position of the next output in units of 1/L input samples, relative to the newest input.
    phase: usize,
}

impl Resampler {
    /// Converts by `l / m` (output rate = input rate * l / m), `1 <= l <= 6`.
    pub fn new(l: usize, m: usize) -> Self {
        assert!((1..=L_MAX).contains(&l) && m >= 1);
        let n = l * TAPS;
        // prototype low-pass at the rate l * fs_in; cut-off at 46 % of the lower of the two rates
        let fc = 0.46 / l.max(m) as f64;
        let mut coef = [0.0f32; L_MAX * TAPS];
        let centre = (n as f64 - 1.0) / 2.0;
        for i in 0..n {
            let t = i as f64 - centre;
            let x = 2.0 * core::f64::consts::PI * fc * t;
            let sinc = if libm::fabs(x) < 1e-9 { 1.0 } else { libm::sin(x) / x };
            let a = 2.0 * core::f64::consts::PI * i as f64 / (n as f64 - 1.0);
            let win = 0.42 - 0.5 * libm::cos(a) + 0.08 * libm::cos(2.0 * a);
            // gain l makes up for the zeros between the input samples
            let h = 2.0 * fc * sinc * win * l as f64;
            coef[(i % l) * TAPS + i / l] = h as f32;
        }
        Self { l, m, coef, hist: [0.0; TAPS], phase: 0 }
    }

    /// 12 kHz to 8 kHz.
    pub fn new_12k_to_8k() -> Self {
        Self::new(2, 3)
    }

    /// 8 kHz to 12 kHz.
    pub fn new_8k_to_12k() -> Self {
        Self::new(3, 2)
    }

    /// 8 kHz to 48 kHz.
    pub fn new_8k_to_48k() -> Self {
        Self::new(6, 1)
    }

    /// Feeds `input`; every output sample goes to `sink`.
    pub fn process(&mut self, input: &[i16], mut sink: impl FnMut(i16)) {
        for &s in input {
            self.hist.copy_within(0..TAPS - 1, 1);
            self.hist[0] = s as f32;
            while self.phase < self.l {
                let c = &self.coef[self.phase * TAPS..(self.phase + 1) * TAPS];
                let mut acc = 0.0f32;
                for k in 0..TAPS {
                    acc += c[k] * self.hist[k];
                }
                sink(acc.clamp(-32768.0, 32767.0) as i16);
                self.phase += self.m;
            }
            self.phase -= self.l;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    extern crate std;
    use std::vec::Vec;

    fn tone_gain(l: usize, m: usize, f: f64, fs_in: f64) -> f64 {
        let mut r = Resampler::new(l, m);
        let x: Vec<i16> = (0..4800).map(|i| (10000.0 * (2.0 * std::f64::consts::PI * f * i as f64 / fs_in).sin()) as i16).collect();
        let mut y = Vec::new();
        r.process(&x, |s| y.push(s as f64));
        let tail = &y[y.len() / 2..];
        let rms = (tail.iter().map(|v| v * v).sum::<f64>() / tail.len() as f64).sqrt();
        rms / (10000.0 / 2f64.sqrt())
    }

    #[test]
    fn output_count_and_passband() {
        let mut r = Resampler::new_12k_to_8k();
        let mut n = 0;
        r.process(&[0i16; 1200], |_| n += 1);
        assert_eq!(n, 800);
        // the FreeDV signal lies between 700 and 2,300 Hz
        for f in [700.0, 1500.0, 2300.0] {
            let g = tone_gain(2, 3, f, 12000.0);
            assert!((g - 1.0).abs() < 0.02, "12k->8k at {f} Hz: gain {g}");
            let g = tone_gain(6, 1, f, 8000.0);
            assert!((g - 1.0).abs() < 0.02, "8k->48k at {f} Hz: gain {g}");
            let g = tone_gain(3, 2, f, 8000.0);
            assert!((g - 1.0).abs() < 0.02, "8k->12k at {f} Hz: gain {g}");
        }
        // 5 kHz at 12 kHz would fold to 3 kHz at 8 kHz
        assert!(tone_gain(2, 3, 5000.0, 12000.0) < 0.01);
    }
}
