// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! CW: receive demodulator (narrow bandpass, shifted to the operator's sidetone pitch) and the
//! transmit keying-envelope shaper (raised-cosine ramps, so the keyed carrier does not click).

use crate::agc::Agc;
use crate::complex::C32;
use crate::fastconv::{BandpassFilter, BLOCK, MAX_TAPS};
use crate::fft::Fft1024;

/// CW receive demodulator: the receiver LO is tuned near the CW carrier (typically offset by
/// about `pitch_hz` so the carrier sits inside a narrow filter centered near 0), and the output
/// is shifted so the recovered tone plays at `pitch_hz` regardless of small tuning error within
/// `bandwidth_hz`. Structurally identical to [`crate::ssb::SsbDemod`] (a bandpass + `Re{}` +
/// AGC) with a narrow symmetric passband and a nonzero shift.
pub struct CwDemod {
    filter: BandpassFilter,
    agc: Agc,
}

impl CwDemod {
    /// `pitch_hz` is the sidetone frequency the operator wants to hear; `bandwidth_hz` is the
    /// total passband width around the expected carrier position (typically 100-500 Hz).
    pub fn new(fft: &Fft1024, sample_rate_hz: f32, pitch_hz: f32, bandwidth_hz: f32, agc: Agc) -> Self {
        let half = bandwidth_hz * 0.5;
        CwDemod {
            filter: BandpassFilter::design(fft, sample_rate_hz, -half, half, pitch_hz, MAX_TAPS),
            agc,
        }
    }

    pub fn process_block(&mut self, fft: &Fft1024, input: &[C32; BLOCK], audio_out: &mut [f32; BLOCK]) {
        let mut filtered = [C32::ZERO; BLOCK];
        self.filter.process_block(fft, input, &mut filtered);
        for (a, f) in audio_out.iter_mut().zip(filtered.iter()) {
            *a = self.agc.process(f.re);
        }
    }
}

/// Raised-cosine keying envelope shaper for CW transmit: turns a hard on/off key state into a
/// smooth 0..1 amplitude ramp over `ramp_ms`, so keying does not splatter (no rectangular-pulse
/// sidebands). One `libm::cosf` + a couple of multiplies per sample, only while ramping, a
/// steady key-down or key-up costs one branch.
pub struct KeyShaper {
    ramp_samples: f32,
    /// Position within the current ramp, 0.0 (key transitioned) .. 1.0 (ramp complete). Also
    /// used at rest: 0.0 = fully off, 1.0 = fully on (so a partial ramp reversed mid-flight
    /// starts from wherever the envelope already is, avoiding a click on rapid re-keying).
    envelope: f32,
    target: f32,
    step: f32,
}

impl KeyShaper {
    /// A shaper whose ramps take `ramp_ms` at `sample_rate_hz`.
    pub fn new(sample_rate_hz: f32, ramp_ms: f32) -> Self {
        KeyShaper {
            ramp_samples: (ramp_ms * 0.001 * sample_rate_hz).max(1.0),
            envelope: 0.0,
            target: 0.0,
            step: 0.0,
        }
    }

    /// Sets the key state: down starts the rising ramp and up starts the falling one.
    pub fn set_key(&mut self, down: bool) {
        self.target = if down { 1.0 } else { 0.0 };
    }

    /// Returns the next envelope sample (0.0..=1.0); multiply the CW carrier/sidetone by this.
    pub fn next(&mut self) -> f32 {
        if (self.envelope - self.target).abs() > 1e-6 {
            self.step += 1.0;
            // Raised-cosine ramp from the envelope's current value toward target, parameterized
            // by fractional progress through one `ramp_samples`-long transition.
            let frac = (self.step / self.ramp_samples).min(1.0);
            let shape = 0.5 - 0.5 * libm::cosf(core::f32::consts::PI * frac);
            self.envelope = if self.target > 0.5 { shape } else { 1.0 - shape };
            if frac >= 1.0 {
                self.envelope = self.target;
                self.step = 0.0;
            }
        } else {
            self.step = 0.0;
        }
        self.envelope
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::vec::Vec;

    const FS: f32 = 48_000.0;

    #[test]
    fn demod_recovers_pitch_tone_with_good_snr() {
        let fft = Fft1024::new();
        let pitch = 700.0;
        let agc = Agc::new(FS, 5.0, 300.0, 100.0, 0.5, 0.1, 20.0);
        let mut demod = CwDemod::new(&fft, FS, pitch, 300.0, agc);

        // Carrier sits 50 Hz off the receiver's exact tuning (realistic tuning error), well
        // inside the 300 Hz filter, so the recovered tone should land at pitch + 50 Hz.
        let carrier_offset = 50.0;
        let mut nco = crate::nco::Nco::new(carrier_offset, FS);
        let n = 80 * BLOCK;
        let mut audio = Vec::with_capacity(n);
        let mut i = 0;
        while i < n {
            let mut in_block = [C32::ZERO; BLOCK];
            for s in in_block.iter_mut() {
                *s = nco.next();
            }
            let mut out_block = [0.0f32; BLOCK];
            demod.process_block(&fft, &in_block, &mut out_block);
            audio.extend_from_slice(&out_block);
            i += BLOCK;
        }

        let settled = &audio[20 * BLOCK..];
        let expected_hz = pitch + carrier_offset; // shift moves the carrier to pitch, offset rides along
        let mut tone_nco = crate::nco::Nco::new(expected_hz, FS);
        let mut acc = C32::ZERO;
        for &a in settled {
            acc += C32::new(a, 0.0) * tone_nco.next().conj();
        }
        let tone_amp = acc.abs() * 2.0 / settled.len() as f32;
        let tone_power = 0.5 * tone_amp * tone_amp;
        let total_power: f32 = settled.iter().map(|a| a * a).sum::<f32>() / settled.len() as f32;
        let noise_power = (total_power - tone_power).max(1e-12);
        let snr_db = 10.0 * libm::log10f(tone_power / noise_power);
        std::println!("MEASURED CW SNR: {snr_db} dB at {expected_hz} Hz");
        assert!(snr_db > 30.0, "CW demod SNR at {expected_hz} Hz only {snr_db} dB");
    }

    #[test]
    fn key_shaper_ramps_smoothly_and_reaches_targets() {
        let mut shaper = KeyShaper::new(FS, 5.0); // 5 ms ramp
        shaper.set_key(true);
        let ramp_samples = (0.005 * FS) as usize;
        let mut max_step = 0.0f32;
        let mut prev = 0.0f32;
        for _ in 0..ramp_samples + 10 {
            let v = shaper.next();
            max_step = max_step.max((v - prev).abs());
            prev = v;
        }
        assert!((prev - 1.0).abs() < 1e-3, "envelope did not reach 1.0, got {prev}");
        // No single-sample jump anywhere close to a full-scale step (that would click).
        assert!(max_step < 0.05, "envelope step too abrupt: {max_step} per sample");

        shaper.set_key(false);
        for _ in 0..ramp_samples + 10 {
            prev = shaper.next();
        }
        assert!(prev.abs() < 1e-3, "envelope did not return to 0.0, got {prev}");
    }
}
