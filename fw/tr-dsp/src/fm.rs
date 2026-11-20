// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! FM demodulator: quadrature (phase-difference) discriminator, de-emphasis, and an
//! amplitude-threshold squelch (mutes audio when the filtered RF level drops below a
//! configurable, hysteresis-smoothed threshold, simpler than a noise-driven squelch and enough
//! for the silence between transmissions; a noise-driven squelch is not implemented, as noted in
//! `docs/S3_DSP.md`).

use crate::complex::C32;
use crate::fastconv::{BandpassFilter, BLOCK, MAX_TAPS};
use crate::fft::Fft1024;

/// FM demodulator with de-emphasis and squelch.
pub struct FmDemod {
    filter: BandpassFilter,
    prev: C32,
    sample_rate_hz: f32,
    /// De-emphasis one-pole lowpass coefficient (see [`Self::new`]'s `deemphasis_us`).
    deemph_alpha: f32,
    deemph_state: f32,
    squelch: Squelch,
}

impl FmDemod {
    /// `half_bandwidth_hz` is the channel half-width (e.g. 6-8 kHz for narrowband FM);
    /// `deemphasis_us` is the standard 50 (EU) or 75 (US) microsecond time constant, 0 to
    /// disable; `squelch` sets the RF-level mute threshold.
    pub fn new(
        fft: &Fft1024,
        sample_rate_hz: f32,
        half_bandwidth_hz: f32,
        deemphasis_us: f32,
        squelch: Squelch,
    ) -> Self {
        let deemph_alpha = if deemphasis_us > 0.0 {
            let tau_s = deemphasis_us * 1e-6;
            1.0 - libm::expf(-1.0 / (tau_s * sample_rate_hz))
        } else {
            1.0 // no filtering: alpha=1 makes the one-pole filter pass the input unchanged
        };
        FmDemod {
            filter: BandpassFilter::design(fft, sample_rate_hz, -half_bandwidth_hz, half_bandwidth_hz, 0.0, MAX_TAPS),
            prev: C32::new(1.0, 0.0),
            sample_rate_hz,
            deemph_alpha,
            deemph_state: 0.0,
            squelch,
        }
    }

    pub fn process_block(&mut self, fft: &Fft1024, input: &[C32; BLOCK], audio_out: &mut [f32; BLOCK]) {
        let mut filtered = [C32::ZERO; BLOCK];
        self.filter.process_block(fft, input, &mut filtered);
        for (a, f) in audio_out.iter_mut().zip(filtered.iter()) {
            // Discriminator: instantaneous frequency = phase advance between consecutive
            // samples, in Hz. `norm_sqr` in the denominator normalizes out the AGC-free
            // amplitude so the discriminator output does not depend on signal level.
            let ns = self.prev.norm_sqr().max(1e-12);
            let step = *f * self.prev.conj().scale(1.0 / ns);
            let freq_hz = step.arg_turns() * self.sample_rate_hz;
            self.prev = *f;

            self.deemph_state += (freq_hz - self.deemph_state) * self.deemph_alpha;

            let open = self.squelch.process(f.abs());
            *a = if open { self.deemph_state } else { 0.0 };
        }
    }
}

/// Hysteresis-smoothed RF-level squelch: opens when the smoothed magnitude rises above
/// `threshold`, closes when it falls below `threshold * (1 - hysteresis)`.
pub struct Squelch {
    threshold: f32,
    hysteresis: f32,
    smoothed: f32,
    alpha: f32,
    open: bool,
}

impl Squelch {
    /// A squelch that opens above `threshold` and closes below `threshold - hysteresis` on the level smoothed over `time_const_ms`.
    pub fn new(sample_rate_hz: f32, threshold: f32, hysteresis: f32, time_const_ms: f32) -> Self {
        let tc_samples = (time_const_ms * 0.001 * sample_rate_hz).max(1.0);
        Squelch {
            threshold,
            hysteresis: hysteresis.clamp(0.0, 0.9),
            smoothed: 0.0,
            alpha: 1.0 - libm::expf(-1.0 / tc_samples),
            open: false,
        }
    }

    /// Feeds one level sample and returns true while the squelch is open.
    pub fn process(&mut self, level: f32) -> bool {
        self.smoothed += (level - self.smoothed) * self.alpha;
        if self.open {
            if self.smoothed < self.threshold * (1.0 - self.hysteresis) {
                self.open = false;
            }
        } else if self.smoothed > self.threshold {
            self.open = true;
        }
        self.open
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::vec::Vec;

    const FS: f32 = 48_000.0;

    fn synth_fm(audio_hz: f32, deviation_hz: f32, amplitude: f32, n: usize, fs: f32) -> Vec<C32> {
        let mut phase_turns = 0.0f32;
        let mut aud_phase = 0.0f32;
        let mut out = std::vec![C32::ZERO; n];
        for s in out.iter_mut() {
            let inst_freq = deviation_hz * libm::cosf(core::f32::consts::TAU * aud_phase);
            phase_turns += inst_freq / fs;
            // Wrap both running phases back into a small range after every step. `cos`/`sin`
            // are periodic so this is mathematically exact, and it matters in f32: left to grow
            // unboundedly over tens of thousands of samples, an accumulator's rounding error
            // grows with its own magnitude (each addition's ULP grows too), so total drift grows
            // roughly with the SQUARE of the sample count, by 40,000 samples that reached a
            // full extra turn of phase error here before this fix. `crate::nco::Nco` avoids the
            // whole problem by rotating a unit complex phasor instead of accumulating an angle;
            // this test-only helper needs a literal running phase (to modulate its frequency),
            // so it wraps explicitly instead.
            if phase_turns > 1.0 {
                phase_turns -= 1.0;
            } else if phase_turns < -1.0 {
                phase_turns += 1.0;
            }
            aud_phase += audio_hz / fs;
            if aud_phase > 1.0 {
                aud_phase -= 1.0;
            }
            *s = C32::from_turns(phase_turns).scale(amplitude);
        }
        out
    }

    fn tone_snr_db(audio: &[f32], fs: f32, tone_hz: f32) -> f32 {
        let mut nco = crate::nco::Nco::new(tone_hz, fs);
        let mut acc = C32::ZERO;
        for &a in audio {
            acc += C32::new(a, 0.0) * nco.next().conj();
        }
        let amp = acc.abs() * 2.0 / audio.len() as f32;
        let tone_power = 0.5 * amp * amp;
        let total_power: f32 = audio.iter().map(|a| a * a).sum::<f32>() / audio.len() as f32;
        let noise_power = (total_power - tone_power).max(1e-12);
        10.0 * libm::log10f(tone_power / noise_power)
    }

    #[test]
    fn discriminator_recovers_audio_tone() {
        let fft = Fft1024::new();
        let squelch = Squelch::new(FS, 0.01, 0.3, 20.0); // effectively always open, amplitude=1
        // Standard NBFM-ish parameters: 2.5 kHz deviation, 1 kHz test tone (Carson bandwidth
        // 2*(2.5k+1k) = 7 kHz), well inside a 12 kHz-wide (+/-6 kHz) channel filter, a
        // deviation/tone ratio much higher than this needs a channel filter wider than the
        // 513-tap design here comfortably supports without edge-of-band distortion.
        let mut demod = FmDemod::new(&fft, FS, 6000.0, 0.0, squelch); // de-emphasis off for a clean frequency measurement
        let n = 80 * BLOCK;
        let sig = synth_fm(1000.0, 2500.0, 1.0, n, FS);
        let mut audio = Vec::with_capacity(n);
        let mut i = 0;
        while i + BLOCK <= n {
            let mut in_block = [C32::ZERO; BLOCK];
            in_block.copy_from_slice(&sig[i..i + BLOCK]);
            let mut out_block = [0.0f32; BLOCK];
            demod.process_block(&fft, &in_block, &mut out_block);
            audio.extend_from_slice(&out_block);
            i += BLOCK;
        }
        let settled = &audio[20 * BLOCK..];
        std::eprintln!("first 20 settled samples: {:?}", &settled[..20]);
        std::eprintln!("min {} max {}", settled.iter().cloned().fold(f32::MAX, f32::min), settled.iter().cloned().fold(f32::MIN, f32::max));
        let snr = tone_snr_db(settled, FS, 1000.0);
        std::println!("MEASURED FM discriminator SNR: {snr} dB");
        assert!(snr > 25.0, "FM discriminator SNR only {snr} dB");

        // Peak deviation of the recovered tone should be close to the programmed 2500 Hz.
        let peak = settled.iter().cloned().fold(0.0f32, f32::max);
        std::println!("MEASURED FM recovered peak deviation: {peak} Hz");
        assert!((peak - 2500.0).abs() < 250.0, "recovered deviation peak {peak} Hz, expected ~2500 Hz");
    }

    #[test]
    fn squelch_opens_above_threshold_and_closes_below() {
        let mut sq = Squelch::new(FS, 0.5, 0.3, 5.0);
        for _ in 0..2000 {
            assert!(!sq.process(0.05), "squelch opened on a weak signal");
        }
        for _ in 0..2000 {
            sq.process(1.0);
        }
        assert!(sq.process(1.0), "squelch did not open on a strong signal");
        for _ in 0..2000 {
            sq.process(0.01);
        }
        assert!(!sq.process(0.01), "squelch did not close once the signal dropped");
    }

    #[test]
    fn deemphasis_attenuates_high_audio_frequencies() {
        let fft = Fft1024::new();
        let deviation = 3000.0;
        let n = 80 * BLOCK;

        let measure_at = |audio_hz: f32| -> f32 {
            let squelch = Squelch::new(FS, 0.01, 0.3, 20.0);
            let mut demod = FmDemod::new(&fft, FS, 8000.0, 75.0, squelch);
            let sig = synth_fm(audio_hz, deviation, 1.0, n, FS);
            let mut audio = Vec::with_capacity(n);
            let mut i = 0;
            while i + BLOCK <= n {
                let mut in_block = [C32::ZERO; BLOCK];
                in_block.copy_from_slice(&sig[i..i + BLOCK]);
                let mut out_block = [0.0f32; BLOCK];
                demod.process_block(&fft, &in_block, &mut out_block);
                audio.extend_from_slice(&out_block);
                i += BLOCK;
            }
            let settled = &audio[20 * BLOCK..];
            let mut nco = crate::nco::Nco::new(audio_hz, FS);
            let mut acc = C32::ZERO;
            for &a in settled {
                acc += C32::new(a, 0.0) * nco.next().conj();
            }
            acc.abs() * 2.0 / settled.len() as f32
        };

        // A single-pole 75 us de-emphasis has its corner at 1/(2*pi*75us) = 2122 Hz; the
        // standard broadcast-FM comparison points (300 Hz vs 3000 Hz) are both close enough to
        // that corner that the true rolloff between them is only ~4.7 dB (checked against the
        // analytic |H(f)| = 1/sqrt(1+(f/fc)^2) response), not a dramatic difference by itself --
        // so this measures further apart, 100 Hz vs 5000 Hz, where the analytic rolloff is
        // ~8.2 dB, to get a clear, low-tolerance pass/fail margin.
        let low = measure_at(100.0);
        let high = measure_at(5000.0);
        let rolloff_db = 20.0 * libm::log10f(low / high);
        std::println!("MEASURED de-emphasis rolloff (100 Hz vs 5000 Hz): {rolloff_db} dB");
        assert!(rolloff_db > 6.0, "de-emphasis rolloff only {rolloff_db} dB from 100 Hz to 5000 Hz");
    }
}
