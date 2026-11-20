// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Time-domain impulse noise blanker: runs on the wideband IQ stream *before* the channel
//! filter (an impulse's energy is spread across the whole receiver bandwidth, so it is far
//! easier to see and remove here than after narrowband filtering has smeared it in time).
//!
//! Detection: a fast, per-sample magnitude compared against a noise-floor estimate tracked by a
//! "leaky minimum" (follows a dropping magnitude quickly, a rising one only slowly, the same
//! technique [`crate::nr::NoiseReducer`] uses per FFT bin). That makes the floor estimate itself
//! immune to the impulses it is trying to detect: a loud pulse barely moves it, while genuine
//! steady-state signal is tracked down onto within one fast time constant. The floor is updated
//! from every incoming sample's raw magnitude, including while blanking is in effect, so a run
//! of holds (which pauses the demodulated output, not the detector) can never starve it.
//!
//! When the floor is exceeded by `threshold_factor`, the blanker holds the last good sample
//! (instead of zeroing, which would itself inject a broadband click) for `hold_samples`, so a
//! short ignition/relay-click impulse is replaced by silence-at-signal-level rather than by a
//! transient of its own. Cost per sample: one magnitude, one compare, one IIR update, no FFT
//! or multiply-heavy step, so it is cheap enough to run on every receiver even when only some
//! are audible.

use crate::complex::C32;

/// Impulse noise blanker for the wideband IQ stream.
pub struct NoiseBlanker {
    floor: f32,
    floor_alpha_down: f32,
    floor_alpha_up: f32,
    threshold_factor: f32,
    hold_samples: u32,
    holding: u32,
    last_good: C32,
    primed: bool,
    pub blanked_count: u32,
}

impl NoiseBlanker {
    /// `threshold_factor`: trigger when a sample's magnitude exceeds `floor * threshold_factor`
    /// (6-10 typical). `hold_ms`: how long to hold the last good sample once triggered (covers
    /// the width of a typical ignition/relay pulse, ~0.05-0.5 ms). `floor_tc_ms`: time constant
    /// of the noise-floor average's slow rise (a steady loudness increase takes this long to be
    /// accepted as the new floor rather than treated as signal/impulse); the floor's fall is a
    /// fixed, much faster 1 ms so it locks onto a real signal quickly at start-up.
    pub fn new(sample_rate_hz: f32, threshold_factor: f32, hold_ms: f32, floor_tc_ms: f32) -> Self {
        let up_tc_samples = (floor_tc_ms * 0.001 * sample_rate_hz).max(1.0);
        let down_tc_samples = (1.0 * 0.001 * sample_rate_hz).max(1.0);
        NoiseBlanker {
            floor: 0.0,
            floor_alpha_down: 1.0 - libm::expf(-1.0 / down_tc_samples),
            floor_alpha_up: 1.0 - libm::expf(-1.0 / up_tc_samples),
            threshold_factor,
            hold_samples: (hold_ms * 0.001 * sample_rate_hz).max(1.0) as u32,
            holding: 0,
            last_good: C32::ZERO,
            primed: false,
            blanked_count: 0,
        }
    }

    /// Passes one sample, or the last good one while an impulse is being blanked.
    #[inline]
    pub fn process(&mut self, x: C32) -> C32 {
        let mag = x.abs();
        if !self.primed {
            self.floor = mag;
            self.primed = true;
        } else if mag < self.floor {
            self.floor += (mag - self.floor) * self.floor_alpha_down;
        } else {
            self.floor += (mag - self.floor) * self.floor_alpha_up;
        }

        if self.holding == 0 && mag > self.floor * self.threshold_factor {
            self.holding = self.hold_samples;
        }
        if self.holding > 0 {
            self.holding -= 1;
            self.blanked_count += 1;
            self.last_good
        } else {
            self.last_good = x;
            x
        }
    }

    /// Runs [`NoiseBlanker::process`] over a block.
    pub fn process_block(&mut self, input: &[C32], output: &mut [C32]) {
        for (o, i) in output.iter_mut().zip(input.iter()) {
            *o = self.process(*i);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::vec::Vec;

    const FS: f32 = 384_000.0; // wideband, pre-decimation-style rate

    fn synth_with_impulses(tone_hz: f32, tone_amp: f32, impulse_amp: f32, n: usize, fs: f32) -> Vec<C32> {
        let mut nco = crate::nco::Nco::new(tone_hz, fs);
        let mut out = std::vec![C32::ZERO; n];
        let period = 4000; // an impulse roughly every ~10.4 ms
        for (i, s) in out.iter_mut().enumerate() {
            *s = nco.next().scale(tone_amp);
            if i % period < 3 {
                *s = C32::new(impulse_amp, 0.0);
            }
        }
        out
    }

    #[test]
    fn blanks_impulses_without_destroying_the_tone() {
        let n = 200_000;
        let sig = synth_with_impulses(1000.0, 0.1, 5.0, n, FS);

        let mut nb = NoiseBlanker::new(FS, 6.0, 0.1, 20.0);
        let mut out = std::vec![C32::ZERO; n];
        nb.process_block(&sig, &mut out);

        // Settle the floor tracker on the pre-impulse region, then check peak amplitude in the
        // steady state is close to the tone (not the 5.0 impulse level).
        let settled = &out[20_000..];
        let peak = settled.iter().map(|s: &C32| s.abs()).fold(0.0f32, f32::max);
        std::println!("MEASURED blanked peak amplitude: {peak}");
        assert!(peak < 0.3, "peak amplitude after blanking is {peak}, impulses were not removed");
        assert!(nb.blanked_count > 0, "blanker never triggered");

        // Tone recovery: correlate against the known tone frequency over a region with several
        // blanked impulses; losing a handful of samples out of thousands should cost only a
        // little SNR.
        // Note: this is a complex-IQ correlation (unlike the real-audio SNR helpers elsewhere in
        // this crate), so recovered amplitude is `|acc|/N` directly, no factor of 2, since the
        // signal and the reference are both single complex exponentials, not a real cosine split
        // across positive and negative frequency.
        let mut tone_nco = crate::nco::Nco::new(1000.0, FS);
        let mut acc = C32::ZERO;
        for &s in settled {
            acc += s * tone_nco.next().conj();
        }
        let amp = acc.abs() / settled.len() as f32;
        std::println!("MEASURED recovered tone amplitude: {amp} (input 0.1)");
        assert!((amp - 0.1).abs() < 0.02, "recovered tone amplitude {amp}, expected ~0.1");
    }

    #[test]
    fn passes_a_clean_signal_unchanged() {
        let n = 50_000;
        let sig = synth_with_impulses(1000.0, 0.1, 0.1, n, FS); // no impulses (same amplitude as tone)
        let mut nb = NoiseBlanker::new(FS, 6.0, 0.1, 20.0);
        let mut out = std::vec![C32::ZERO; n];
        nb.process_block(&sig, &mut out);
        assert_eq!(nb.blanked_count, 0, "blanker fired on a signal with no impulses");
    }
}
