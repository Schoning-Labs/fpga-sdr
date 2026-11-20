// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! SSB (USB/LSB) demodulator: an asymmetric [`BandpassFilter`] (the one-sided passband rejects
//! the unwanted sideband) with `shift_hz = 0` (the receiver's own LO already sits at the
//! suppressed carrier, see `fastconv` module doc), followed by [`Agc`] on the real part of the
//! filtered signal (this is the whole demodulator: SSB's "detector" is just `Re{}`).

use crate::agc::Agc;
use crate::complex::C32;
use crate::fastconv::{BandpassFilter, BLOCK, MAX_TAPS};
use crate::fft::Fft1024;

/// Which sideband the demodulator keeps.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Sideband {
    Upper,
    Lower,
}

/// SSB demodulator: one-sided bandpass filter followed by AGC.
pub struct SsbDemod {
    filter: BandpassFilter,
    agc: Agc,
}

impl SsbDemod {
    /// `low_hz`/`high_hz` are positive audio-band edges (e.g. 300, 2700 Hz); for `Lower` they
    /// are mirrored below 0 automatically.
    pub fn new(
        fft: &Fft1024,
        sample_rate_hz: f32,
        sideband: Sideband,
        low_hz: f32,
        high_hz: f32,
        agc: Agc,
    ) -> Self {
        let (lo, hi) = match sideband {
            Sideband::Upper => (low_hz, high_hz),
            Sideband::Lower => (-high_hz, -low_hz),
        };
        SsbDemod {
            filter: BandpassFilter::design(fft, sample_rate_hz, lo, hi, 0.0, MAX_TAPS),
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::vec::Vec;

    const FS: f32 = 48_000.0;

    fn synth_ssb_tone(carrier_offset_hz: f32, n: usize, fs: f32) -> Vec<C32> {
        // A single-tone SSB signal's complex baseband IS a single complex sinusoid at
        // (suppressed carrier + audio tone), see module doc: that is what makes `Re{}` after
        // sideband-selecting filtering the correct detector.
        let mut nco = crate::nco::Nco::new(carrier_offset_hz, fs);
        let mut out = std::vec![C32::ZERO; n];
        for s in out.iter_mut() {
            *s = nco.next();
        }
        out
    }

    fn measure_tone_freq_and_snr(audio: &[f32], fs: f32, expect_hz: f32) -> (f32, f32) {
        // Simple Goertzel-style measure: correlate against the expected tone to get its
        // amplitude, and use total power minus tone power for a noise estimate.
        let mut nco = crate::nco::Nco::new(expect_hz, fs);
        let mut acc = C32::ZERO;
        for &a in audio {
            let lo = nco.next();
            acc += C32::new(a, 0.0) * lo.conj();
        }
        let tone_amp = acc.abs() * 2.0 / audio.len() as f32;
        let tone_power = 0.5 * tone_amp * tone_amp;
        let total_power: f32 = audio.iter().map(|a| a * a).sum::<f32>() / audio.len() as f32;
        let noise_power = (total_power - tone_power).max(1e-12);
        let snr_db = 10.0 * libm::log10f(tone_power / noise_power);
        (tone_amp, snr_db)
    }

    #[test]
    fn usb_demodulates_tone_at_correct_frequency() {
        let fft = Fft1024::new();
        let agc = Agc::new(FS, 5.0, 300.0, 100.0, 0.5, 0.1, 20.0);
        let mut demod = SsbDemod::new(&fft, FS, Sideband::Upper, 300.0, 2700.0, agc);

        let n = 80 * BLOCK;
        let sig = synth_ssb_tone(1000.0, n, FS);
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
        let (_amp, snr_db) = measure_tone_freq_and_snr(settled, FS, 1000.0);
        std::println!("MEASURED USB SNR: {snr_db} dB");
        assert!(snr_db > 30.0, "USB demod SNR at 1000 Hz only {snr_db} dB");

        // Confirm the opposite sideband (a tone below the suppressed carrier) is rejected.
        // Measured directly on the filter (bypassing AGC): AGC alone will crank its gain toward
        // max on a genuinely near-silent opposite-sideband residual, which amplifies whatever
        // tiny leakage is left and makes AGC-referenced amplitude a misleading rejection metric
        // (AGC's own behavior is already covered by `agc::tests`), so this checks the same
        // `[300, 2700]` one-sided passband `SsbDemod` builds internally, the same way
        // `fastconv::tests::stopband_rejects_out_of_band_tone` measures rejection.
        let mut bpf_pass = BandpassFilter::design(&fft, FS, 300.0, 2700.0, 0.0, MAX_TAPS);
        let in_band = synth_ssb_tone(1000.0, n, FS);
        let pass_level = filtered_rms(&mut bpf_pass, &fft, &in_band);

        let mut bpf_image = BandpassFilter::design(&fft, FS, 300.0, 2700.0, 0.0, MAX_TAPS);
        let image_side = synth_ssb_tone(-1000.0, n, FS);
        let image_level = filtered_rms(&mut bpf_image, &fft, &image_side);

        let rejection_db = 20.0 * libm::log10f(pass_level / image_level);
        std::println!("MEASURED opposite-sideband rejection: {rejection_db} dB");
        assert!(rejection_db > 35.0, "opposite-sideband rejection only {rejection_db} dB");
    }

    fn filtered_rms(bpf: &mut BandpassFilter, fft: &Fft1024, input: &[C32]) -> f32 {
        let mut sum_sq = 0.0f32;
        let mut count = 0usize;
        let mut i = 0;
        while i + BLOCK <= input.len() {
            let mut in_block = [C32::ZERO; BLOCK];
            in_block.copy_from_slice(&input[i..i + BLOCK]);
            let mut out_block = [C32::ZERO; BLOCK];
            bpf.process_block(fft, &in_block, &mut out_block);
            if i >= 20 * BLOCK {
                for s in out_block.iter() {
                    sum_sq += s.norm_sqr();
                    count += 1;
                }
            }
            i += BLOCK;
        }
        libm::sqrtf(sum_sq / count as f32)
    }

    #[test]
    fn lsb_demodulates_tone_at_correct_frequency() {
        let fft = Fft1024::new();
        let agc = Agc::new(FS, 5.0, 300.0, 100.0, 0.5, 0.1, 20.0);
        let mut demod = SsbDemod::new(&fft, FS, Sideband::Lower, 300.0, 2700.0, agc);

        let n = 80 * BLOCK;
        let sig = synth_ssb_tone(-1000.0, n, FS); // LSB: audio tone appears below the carrier
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
        let (_amp, snr_db) = measure_tone_freq_and_snr(settled, FS, 1000.0);
        std::println!("MEASURED LSB SNR: {snr_db} dB");
        assert!(snr_db > 30.0, "LSB demod SNR at 1000 Hz only {snr_db} dB");
    }
}
