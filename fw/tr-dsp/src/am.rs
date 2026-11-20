// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! AM demodulators: envelope (simple, phase-independent) and synchronous (tracks the carrier
//! phase, immune to the phase/amplitude wobble of selective fading that confuses an envelope
//! detector). Both start from the same symmetric [`BandpassFilter`] (`shift_hz = 0`, the
//! receiver LO is tuned to the carrier).

use crate::agc::Agc;
use crate::complex::C32;
use crate::fastconv::{BandpassFilter, BLOCK, MAX_TAPS};
use crate::fft::Fft1024;

/// AM demodulator that follows the envelope of the filtered signal.
pub struct AmEnvelopeDemod {
    filter: BandpassFilter,
    dc_avg: f32,
    dc_alpha: f32,
    agc: Agc,
}

impl AmEnvelopeDemod {
    pub fn new(fft: &Fft1024, sample_rate_hz: f32, half_bandwidth_hz: f32, agc: Agc) -> Self {
        AmEnvelopeDemod {
            filter: BandpassFilter::design(fft, sample_rate_hz, -half_bandwidth_hz, half_bandwidth_hz, 0.0, MAX_TAPS),
            dc_avg: 0.0,
            dc_alpha: 20.0 / sample_rate_hz, // ~20 Hz DC-removal corner
            agc,
        }
    }

    pub fn process_block(&mut self, fft: &Fft1024, input: &[C32; BLOCK], audio_out: &mut [f32; BLOCK]) {
        let mut filtered = [C32::ZERO; BLOCK];
        self.filter.process_block(fft, input, &mut filtered);
        for (a, f) in audio_out.iter_mut().zip(filtered.iter()) {
            let env = f.abs();
            self.dc_avg += (env - self.dc_avg) * self.dc_alpha;
            *a = self.agc.process(env - self.dc_avg);
        }
    }
}

/// Synchronous AM demodulator that tracks the carrier phase.
pub struct AmSyncDemod {
    filter: BandpassFilter,
    /// Slow low-pass estimate of the carrier phasor: since the carrier is the strongest,
    /// near-DC component of a narrowband AM signal, low-passing the complex signal itself is a
    /// cheap carrier tracker (no separate PLL/NCO needed).
    carrier_est: C32,
    carrier_alpha: f32,
    dc_avg: f32,
    dc_alpha: f32,
    agc: Agc,
}

impl AmSyncDemod {
    pub fn new(fft: &Fft1024, sample_rate_hz: f32, half_bandwidth_hz: f32, agc: Agc) -> Self {
        AmSyncDemod {
            filter: BandpassFilter::design(fft, sample_rate_hz, -half_bandwidth_hz, half_bandwidth_hz, 0.0, MAX_TAPS),
            carrier_est: C32::new(1.0, 0.0),
            carrier_alpha: 15.0 / sample_rate_hz, // ~15 Hz carrier-tracking corner
            dc_avg: 0.0,
            dc_alpha: 20.0 / sample_rate_hz,
            agc,
        }
    }

    pub fn process_block(&mut self, fft: &Fft1024, input: &[C32; BLOCK], audio_out: &mut [f32; BLOCK]) {
        let mut filtered = [C32::ZERO; BLOCK];
        self.filter.process_block(fft, input, &mut filtered);
        for (a, f) in audio_out.iter_mut().zip(filtered.iter()) {
            self.carrier_est += (*f - self.carrier_est).scale(self.carrier_alpha);
            let mag = self.carrier_est.abs().max(1e-6);
            let unit = self.carrier_est.scale(1.0 / mag);
            let coherent = (*f * unit.conj()).re; // project onto the tracked carrier phase
            self.dc_avg += (coherent - self.dc_avg) * self.dc_alpha;
            *a = self.agc.process(coherent - self.dc_avg);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::vec::Vec;

    const FS: f32 = 48_000.0;

    /// `carrier_phase_turns`: static phase offset of the carrier relative to the receiver's I
    /// axis, to check the synchronous demodulator actually tracks it (an envelope detector does
    /// not need to and is tested at phase 0).
    fn synth_am(audio_hz: f32, mod_index: f32, carrier_phase_turns: f32, n: usize, fs: f32) -> Vec<C32> {
        let carrier = C32::from_turns(carrier_phase_turns);
        let mut aud_nco = crate::nco::Nco::new(audio_hz, fs);
        let mut out = std::vec![C32::ZERO; n];
        for s in out.iter_mut() {
            let env = 1.0 + mod_index * aud_nco.next_real();
            *s = carrier.scale(env);
        }
        out
    }

    fn run<D>(mut step: D, sig: &[C32]) -> Vec<f32>
    where
        D: FnMut(&[C32; BLOCK], &mut [f32; BLOCK]),
    {
        let mut audio = Vec::with_capacity(sig.len());
        let mut i = 0;
        while i + BLOCK <= sig.len() {
            let mut in_block = [C32::ZERO; BLOCK];
            in_block.copy_from_slice(&sig[i..i + BLOCK]);
            let mut out_block = [0.0f32; BLOCK];
            step(&in_block, &mut out_block);
            audio.extend_from_slice(&out_block);
            i += BLOCK;
        }
        audio
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
    fn envelope_demod_recovers_tone() {
        let fft = Fft1024::new();
        let agc = Agc::new(FS, 5.0, 300.0, 100.0, 0.3, 0.1, 20.0);
        let mut demod = AmEnvelopeDemod::new(&fft, FS, 2500.0, agc);
        let n = 80 * BLOCK;
        let sig = synth_am(1000.0, 0.7, 0.0, n, FS);
        let audio = run(|i, o| demod.process_block(&fft, i, o), &sig);
        let settled = &audio[20 * BLOCK..];
        let snr = tone_snr_db(settled, FS, 1000.0);
        std::println!("MEASURED AM envelope SNR: {snr} dB");
        assert!(snr > 25.0, "AM envelope demod SNR only {snr} dB");
    }

    #[test]
    fn sync_demod_recovers_tone_despite_carrier_phase_offset() {
        let fft = Fft1024::new();
        let agc = Agc::new(FS, 5.0, 300.0, 100.0, 0.3, 0.1, 20.0);
        let mut demod = AmSyncDemod::new(&fft, FS, 2500.0, agc);
        let n = 80 * BLOCK;
        // A quarter-turn carrier phase offset would zero out a naive Re{} envelope-less detector;
        // the tracking loop should still lock on and recover the tone.
        let sig = synth_am(1000.0, 0.7, 0.25, n, FS);
        let audio = run(|i, o| demod.process_block(&fft, i, o), &sig);
        let settled = &audio[30 * BLOCK..]; // extra settling time for the carrier tracker
        let snr = tone_snr_db(settled, FS, 1000.0);
        std::println!("MEASURED AM sync SNR: {snr} dB");
        assert!(snr > 20.0, "AM sync demod SNR only {snr} dB");
    }
}
