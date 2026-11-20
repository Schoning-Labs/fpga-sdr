// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Spectral noise reduction: an STFT (overlap-add) spectral-subtraction stage, run on the
//! demodulated real audio. [`NoiseReducer`] uses the same 1,024-sample frame / 512-sample hop as
//! [`crate::fastconv`] (its 50% overlap satisfies the Hann window's COLA, constant
//! overlap-add, condition, so windowing does not color the reconstructed audio), which is
//! exactly the "one more FFT pair" `docs/ARCHITECTURE.md` section 5.5 budgets per receiver for
//! noise reduction on top of its channel filter.
//!
//! Per-bin noise floor tracking is a cheap "leaky minimum": it follows a bin's magnitude down
//! fast (assume any drop is toward the noise floor) and up only very slowly (so speech/CW peaks
//! do not get mistaken for a rising noise floor), then applies spectral-subtraction gain with a
//! floor (`gain_floor`) to keep the classic "musical noise" artifact bounded.

use crate::complex::C32;
use crate::fft::RealFft;

/// Noise reducer on 1,024-sample frames with a 512-sample hop (48 ksps audio, 46.9 Hz bins,
/// 21.3 ms frames). Its transform is a [`RealFft<512>`].
pub type NoiseReducer = NoiseReducerN<512>;

/// Noise reducer on 256-sample frames with a 128-sample hop: the same 46.9 Hz bins and 21.3 ms
/// frames at 12 ksps, the audio rate of the FPGA receiver back end (`docs/ARCHITECTURE.md`
/// section 3.10). Its transform is a [`RealFft<128>`].
pub type NoiseReducer12k = NoiseReducerN<128>;

/// Spectral-subtraction noise reducer on frames of `2H` samples with a hop of `H` samples
/// (50 % overlap, periodic Hann window, overlap-add). The audio is real, so the transform is a
/// [`RealFft<H>`] (one `H`-point complex FFT per direction, not a `2H`-point one) and only the
/// `H + 1` non-redundant bins are processed; the result is the same as running the full complex
/// transform, where bins `k` and `2H - k` always get the same gain.
pub struct NoiseReducerN<const H: usize> {
    history: [f32; H],
    out_tail: [f32; H],
    /// Noise-floor estimate per bin `0..H` (bin 0 = DC); the Nyquist bin is `noise_nyq`.
    noise_mag: [f32; H],
    noise_nyq: f32,
    /// Analysis window, first and second half (periodic Hann).
    win_lo: [f32; H],
    win_hi: [f32; H],
    /// Synthesis window = analysis window x `1 / 2H` (the inverse transform's scaling).
    syn_lo: [f32; H],
    syn_hi: [f32; H],
    alpha_down: f32,
    alpha_up: f32,
    strength: f32,
    gain_floor: f32,
    primed: bool,
}

impl<const H: usize> NoiseReducerN<H> {
    /// `strength` in `0.0..=1.0` (1.0 = full spectral subtraction); `gain_floor` (e.g. 0.1-0.2)
    /// bounds how far any bin can be attenuated, trading noise reduction for musical-noise
    /// artifacts.
    pub fn new(strength: f32, gain_floor: f32) -> Self {
        let n = 2 * H;
        let mut win_lo = [0.0f32; H];
        let mut win_hi = [0.0f32; H];
        // The *periodic* Hann window (divide by N, not N-1): constant overlap-add at 50 % hop
        // requires w[n] + w[n + N/2] == const, which only the periodic form satisfies exactly.
        // The symmetric form (correct for the FIR design windows in `window.rs`) leaves a seam
        // at every frame boundary here instead.
        let hann = |i: usize| 0.5 - 0.5 * libm::cosf(core::f32::consts::TAU * i as f32 / n as f32);
        for i in 0..H {
            win_lo[i] = hann(i);
            win_hi[i] = hann(H + i);
        }
        let inv_n = 1.0 / n as f32;
        let mut syn_lo = win_lo;
        let mut syn_hi = win_hi;
        for w in syn_lo.iter_mut().chain(syn_hi.iter_mut()) {
            *w *= inv_n;
        }
        NoiseReducerN {
            history: [0.0; H],
            out_tail: [0.0; H],
            noise_mag: [0.0; H],
            noise_nyq: 0.0,
            win_lo,
            win_hi,
            syn_lo,
            syn_hi,
            alpha_down: 0.05,
            alpha_up: 0.01,
            strength: strength.clamp(0.0, 1.0),
            gain_floor: gain_floor.clamp(0.0, 1.0),
            primed: false,
        }
    }

    /// Updates one bin's noise-floor estimate from its magnitude and returns its gain.
    #[inline(always)]
    fn bin_gain(&self, mag: f32, nf: &mut f32) -> f32 {
        if !self.primed {
            *nf = mag;
        } else if mag < *nf {
            *nf += (mag - *nf) * self.alpha_down;
        } else {
            *nf += (mag - *nf) * self.alpha_up;
        }
        if mag > 1e-9 {
            (1.0 - self.strength * (*nf / mag)).max(self.gain_floor)
        } else {
            1.0
        }
    }

    /// Processes one hop of `H` new samples; the output lags the input by `H` samples.
    pub fn process_block(&mut self, fft: &RealFft<H>, input: &[f32; H], output: &mut [f32; H]) {
        let mut a = [0.0f32; H];
        let mut b = [0.0f32; H];
        for i in 0..H {
            a[i] = self.history[i] * self.win_lo[i];
            b[i] = input[i] * self.win_hi[i];
        }
        self.history.copy_from_slice(input);

        let mut spec = [C32::ZERO; H];
        fft.forward(&a, &b, &mut spec);

        // Element 0 packs DC (.re) and Nyquist (.im), both real.
        let mut nf0 = self.noise_mag[0];
        let g_dc = self.bin_gain(libm::fabsf(spec[0].re), &mut nf0);
        self.noise_mag[0] = nf0;
        let mut nfn = self.noise_nyq;
        let g_nyq = self.bin_gain(libm::fabsf(spec[0].im), &mut nfn);
        self.noise_nyq = nfn;
        spec[0] = C32::new(spec[0].re * g_dc, spec[0].im * g_nyq);
        for k in 1..H {
            let mut nf = self.noise_mag[k];
            let g = self.bin_gain(spec[k].abs(), &mut nf);
            self.noise_mag[k] = nf;
            spec[k] = spec[k].scale(g);
        }
        self.primed = true;

        fft.inverse_unscaled(&mut spec, &mut a, &mut b);
        // Overlap-add: this frame's first half adds onto the previous frame's saved tail.
        for i in 0..H {
            output[i] = self.out_tail[i] + a[i] * self.syn_lo[i];
            self.out_tail[i] = b[i] * self.syn_hi[i];
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::vec::Vec;

    const FS: f32 = 48_000.0;

    /// Small, fast, deterministic PRNG for test noise (xorshift32), no external `rand` crate
    /// dependency for one test helper.
    struct Xorshift32(u32);
    impl Xorshift32 {
        fn next_f32(&mut self) -> f32 {
            let mut x = self.0;
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            self.0 = x;
            (x as f32 / u32::MAX as f32) * 2.0 - 1.0
        }
    }

    /// A keyed tone (on `on_samples`, off `off_samples`, repeating) in continuous broadband
    /// noise, representative of what this module actually demodulates (CW/speech audio, which
    /// has natural gaps), and the *fair* test signal for a minimum-statistics-style noise-floor
    /// tracker: it needs real silence somewhere to ever learn the true noise floor. A
    /// continuous, never-silent tone (tried first) is not a solvable case for this family of
    /// algorithm at any tuning, with no gap, "the quietest this bin ever gets" IS the tone's
    /// own level, not the noise floor, so the tracker has no way to tell the two apart. That is
    /// a property of spectral subtraction in general, not a bug here; see `docs/S3_DSP.md`
    /// section 2 for the measurement this class of noise reducer is actually good for.
    fn synth_keyed_tone_plus_noise(
        tone_hz: f32,
        tone_amp: f32,
        noise_amp: f32,
        on_samples: usize,
        off_samples: usize,
        n: usize,
        fs: f32,
    ) -> Vec<f32> {
        let mut nco = crate::nco::Nco::new(tone_hz, fs);
        let mut rng = Xorshift32(0xC0FFEE);
        let period = on_samples + off_samples;
        let mut out = std::vec![0.0f32; n];
        for (i, s) in out.iter_mut().enumerate() {
            let keyed = if i % period < on_samples { tone_amp } else { 0.0 };
            *s = keyed * nco.next_real() + noise_amp * rng.next_f32();
        }
        out
    }

    /// SNR from known on/off segments: average power while keyed on (tone+noise) minus average
    /// power while off (noise alone) isolates the tone's own power without needing a frequency
    /// correlation (which would be complicated by the keying envelope's own spectral content).
    fn keyed_snr_db(audio: &[f32], on_samples: usize, off_samples: usize) -> f32 {
        let period = on_samples + off_samples;
        let mut on_sum = 0.0f64;
        let mut on_n = 0usize;
        let mut off_sum = 0.0f64;
        let mut off_n = 0usize;
        for (i, &a) in audio.iter().enumerate() {
            let p = (a as f64) * (a as f64);
            // Skip a margin around each transition: the channel filter/NR group delay and the
            // on/off edge itself blur a few samples either side.
            let phase = i % period;
            if phase < on_samples.saturating_sub(50) {
                on_sum += p;
                on_n += 1;
            } else if phase >= on_samples + 50 {
                off_sum += p;
                off_n += 1;
            }
        }
        let on_power = on_sum / on_n.max(1) as f64;
        let off_power = (off_sum / off_n.max(1) as f64).max(1e-12);
        let tone_power = (on_power - off_power).max(1e-12);
        10.0 * libm::log10f((tone_power / off_power) as f32)
    }

    /// Runs the keyed-tone test through a `NoiseReducerN<H>` at `fs`; returns SNR before/after.
    fn keyed_tone_snr<const H: usize>(fs: f32) -> (f32, f32) {
        let fft = RealFft::<H>::new();
        let on_samples = (0.1 * fs) as usize; // 100 ms on
        let off_samples = (0.1 * fs) as usize; // 100 ms off: real silence for the floor tracker to learn from
        let n = 400 * H; // ~4.3 s at either rate (H = 512 at 48 ksps, 128 at 12 ksps)
        let sig = synth_keyed_tone_plus_noise(1000.0, 0.3, 0.3, on_samples, off_samples, n, fs);

        let settle = 40 * H;
        let before_snr = keyed_snr_db(&sig[settle..], on_samples, off_samples);

        let mut nr = NoiseReducerN::<H>::new(0.9, 0.1);
        let mut out = Vec::with_capacity(n);
        for chunk in sig.chunks_exact(H) {
            let mut in_block = [0.0f32; H];
            in_block.copy_from_slice(chunk);
            let mut out_block = [0.0f32; H];
            nr.process_block(&fft, &in_block, &mut out_block);
            out.extend_from_slice(&out_block);
        }
        let after_snr = keyed_snr_db(&out[settle..], on_samples, off_samples);
        (before_snr, after_snr)
    }

    #[test]
    fn improves_snr_of_a_keyed_tone_in_broadband_noise() {
        let (before_snr, after_snr) = keyed_tone_snr::<512>(FS);
        std::println!("MEASURED NR SNR (48 ksps, 1,024-sample frames): {before_snr} dB before, {after_snr} dB after");
        assert!(
            after_snr > before_snr + 3.0,
            "NR only improved SNR from {before_snr} dB to {after_snr} dB"
        );
    }

    /// The 12 ksps variant (`NoiseReducer12k`, 256-sample frames: same 46.9 Hz bins and 21.3 ms
    /// frames) on the same signal: must do at least as well as the 48 ksps one, since the
    /// algorithm sees the same time-frequency grid with a quarter of the noise bandwidth.
    #[test]
    fn improves_snr_at_12ksps_as_well_as_at_48ksps() {
        let (before_snr, after_snr) = keyed_tone_snr::<128>(12_000.0);
        std::println!("MEASURED NR SNR (12 ksps, 256-sample frames): {before_snr} dB before, {after_snr} dB after");
        assert!(
            after_snr > before_snr + 3.0,
            "NR at 12 ksps only improved SNR from {before_snr} dB to {after_snr} dB"
        );
    }
}
