// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Numerically controlled oscillator: a running unit-magnitude phasor, advanced one fixed
//! rotation per sample. Used to re-derotate a fast-convolution bandpass filter's output down to
//! baseband (the "shift" half of "bandpass filters with adjustable width and shift", see
//! `docs/S3_DSP.md`), and as the CW sidetone/BFO generator.
//!
//! Cost: one complex multiply (4 mul + 2 add) plus, every [`RENORM_PERIOD`] samples, one
//! normalize (1 rsqrt-ish + 2 mul) to stop the rotator's magnitude drifting off 1.0 under
//! repeated f32 multiplication.

use crate::complex::C32;

const RENORM_PERIOD: u32 = 256;

/// Phasor oscillator with a fixed rotation per sample.
pub struct Nco {
    phasor: C32,
    step: C32,
    since_renorm: u32,
}

impl Nco {
    /// `freq_hz` positive turns the phasor forward (counter-clockwise); pass a negative
    /// frequency to derotate a positive-frequency shift back to baseband.
    pub fn new(freq_hz: f32, sample_rate_hz: f32) -> Self {
        Nco {
            phasor: C32::new(1.0, 0.0),
            step: C32::from_turns(freq_hz / sample_rate_hz),
            since_renorm: 0,
        }
    }

    /// Sets the rotation per sample for an oscillator at `freq_hz` when samples come at `sample_rate_hz`.
    pub fn set_freq(&mut self, freq_hz: f32, sample_rate_hz: f32) {
        self.step = C32::from_turns(freq_hz / sample_rate_hz);
    }

    /// Returns the current phasor and advances by one sample.
    #[inline]
    pub fn next(&mut self) -> C32 {
        let out = self.phasor;
        self.phasor *= self.step;
        self.since_renorm += 1;
        if self.since_renorm >= RENORM_PERIOD {
            self.since_renorm = 0;
            let mag = self.phasor.abs();
            if mag > 1e-6 {
                self.phasor = self.phasor.scale(1.0 / mag);
            }
        }
        out
    }

    /// Real-valued sample (for a CW sidetone or test-tone generator): `next()` reinterpreted as
    /// a cosine.
    #[inline]
    pub fn next_real(&mut self) -> f32 {
        self.next().re
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stays_unit_magnitude_over_many_samples() {
        let mut nco = Nco::new(1234.5, 48_000.0);
        let mut max_dev = 0.0f32;
        for _ in 0..200_000 {
            let z = nco.next();
            max_dev = max_dev.max((z.abs() - 1.0).abs());
        }
        assert!(max_dev < 1e-4, "max magnitude deviation {max_dev}");
    }

    #[test]
    fn frequency_matches_phase_advance_per_sample() {
        let fs = 48_000.0;
        let f = 1000.0;
        let mut nco = Nco::new(f, fs);
        let a = nco.next();
        let b = nco.next();
        // b = a * step, so step's angle should be 2*pi*f/fs.
        let step = b * a.conj().scale(1.0 / a.norm_sqr());
        let got_freq = step.arg_turns() * fs;
        assert!((got_freq - f).abs() < 1e-2, "got {got_freq} Hz");
    }
}
