// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Fast-convolution (overlap-save) bandpass filter with adjustable width and shift.
//!
//! Block size is fixed at [`BLOCK`] = 512 new samples per call through a [`FFT_LEN`] = 1024
//! FFT, matching the 1,024-point / 512-new-sample cost `docs/ARCHITECTURE.md` section 5.5
//! budgets for one channel filter (94 blocks/s at 48 ksps).
//!
//! "Width and shift" are two independent parameters, not one:
//! - **Width** is the passband shape: [`BandpassFilter::design`] takes `[low_hz, high_hz]`,
//!   which may straddle 0 (AM/FM: a symmetric channel) or sit entirely on one side of it
//!   (SSB/CW: e.g. `300..2700` Hz selects the upper sideband and rejects the lower).
//! - **Shift** is an independent post-filter frequency translation, applied by derotating every
//!   output sample with an [`Nco`] running at `shift_hz`. For plain SSB the receiver's own LO is
//!   already tuned to the suppressed carrier, so `shift_hz = 0`, a tone at 1,000 Hz in stays at
//!   1,000 Hz out, the filter's asymmetric edges are the only thing doing SSB's job. `shift_hz`
//!   exists for CW (move the recovered carrier to the operator's chosen sidetone pitch without
//!   retuning the receiver) and RIT-style fine retuning; see `docs/S3_DSP.md` section 2.

use crate::complex::C32;
use crate::fft::{Fft1024, FFT_LEN};
use crate::nco::Nco;
use crate::window::{blackman_harris, sinc};

/// New samples per call of the filter.
pub const BLOCK: usize = 512;
/// Samples of the previous block kept for the overlap-save.
pub const OVERLAP: usize = FFT_LEN - BLOCK; // 512
/// Longest impulse response that fits the overlap.
pub const MAX_TAPS: usize = OVERLAP + 1; // 513

/// Overlap-save bandpass filter with a width and a shift.
pub struct BandpassFilter {
    h_freq: [C32; FFT_LEN],
    history: [C32; OVERLAP],
    shift: Nco,
    /// `false` when `shift_hz == 0` (plain SSB, AM, FM): the derotation is skipped entirely.
    shift_active: bool,
    pub center_hz: f32,
    pub width_hz: f32,
    pub group_delay_samples: f32,
}

impl BandpassFilter {
    /// Designs a bandpass covering `[low_hz, high_hz]` of a signal sampled at `sample_rate_hz`
    /// (both may be negative; `low_hz < high_hz` required), using `ntaps` (clamped to
    /// `1..=MAX_TAPS`) windowed-sinc coefficients, with output samples derotated by `shift_hz`
    /// (pass 0.0 for a plain bandpass or standard SSB; see the module doc for what `shift_hz`
    /// is for).
    pub fn design(
        fft: &Fft1024,
        sample_rate_hz: f32,
        low_hz: f32,
        high_hz: f32,
        shift_hz: f32,
        ntaps: usize,
    ) -> Self {
        debug_assert!(high_hz > low_hz);
        let ntaps = ntaps.clamp(1, MAX_TAPS);
        let center = 0.5 * (low_hz + high_hz);
        let half_bw = 0.5 * (high_hz - low_hz);
        let mid = (ntaps - 1) as f32 / 2.0;

        // 1. Real lowpass prototype of half-width `half_bw`, Blackman-Harris windowed.
        let mut lpf = [0.0f32; MAX_TAPS];
        let mut sum = 0.0f32;
        for n in 0..ntaps {
            let t = n as f32 - mid;
            let v = 2.0 * half_bw / sample_rate_hz * sinc(2.0 * half_bw / sample_rate_hz * t)
                * blackman_harris(n, ntaps);
            lpf[n] = v;
            sum += v;
        }
        // Normalize so the lowpass's own DC gain is exactly 1, after modulation below this
        // makes |H(center_hz)| = 1 exactly (see docs/S3_DSP.md section 2).
        if sum.abs() > 1e-12 {
            for v in lpf.iter_mut().take(ntaps) {
                *v /= sum;
            }
        }

        // 2. Modulate to place the passband at `center_hz`, zero-padded into the FFT buffer.
        let mut h_time = [C32::ZERO; FFT_LEN];
        for n in 0..ntaps {
            let t = n as f32 - mid;
            let carrier = C32::from_turns(center * t / sample_rate_hz);
            h_time[n] = carrier.scale(lpf[n]);
        }

        // 3. Frequency-domain coefficients, computed once at design time.
        let mut h_freq = h_time;
        fft.forward(&mut h_freq);
        // Fold the inverse FFT's 1/N into the response, so `process_block` can use the unscaled
        // inverse and skip a pass over the buffer (docs/CPU_BUDGET.md section 4).
        let inv_n = 1.0 / FFT_LEN as f32;
        for h in h_freq.iter_mut() {
            *h = h.scale(inv_n);
        }

        BandpassFilter {
            h_freq,
            history: [C32::ZERO; OVERLAP],
            shift: Nco::new(shift_hz, sample_rate_hz),
            shift_active: shift_hz != 0.0,
            center_hz: center,
            width_hz: high_hz - low_hz,
            group_delay_samples: mid,
        }
    }

    /// Filters one block of `BLOCK` new input samples and applies the `shift_hz` derotation, in
    /// place through a scratch FFT buffer (`fft` is shared/reused across filters and channels , 
    /// it holds no per-filter state).
    pub fn process_block(&mut self, fft: &Fft1024, input: &[C32; BLOCK], output: &mut [C32; BLOCK]) {
        // [history | input] -> spectrum, and history = input, in one gather pass.
        let mut buf = [C32::ZERO; FFT_LEN];
        fft.forward_overlap_save(&mut self.history, input, &mut buf);
        for (b, h) in buf.iter_mut().zip(self.h_freq.iter()) {
            *b *= *h;
        }
        fft.inverse_unscaled(&mut buf); // 1/N is already in h_freq

        if self.shift_active {
            for (o, b) in output.iter_mut().zip(buf[OVERLAP..].iter()) {
                *o = *b * self.shift.next();
            }
        } else {
            output.copy_from_slice(&buf[OVERLAP..]);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::vec::Vec;

    const FS: f32 = 48_000.0;

    /// Tests run several seconds of audio through the filter, so they use `std::vec::Vec` (the
    /// host test binary always links `std`, independent of the crate's own `#![no_std]`); the
    /// crate itself never allocates.
    fn tone(freq_hz: f32, n_samples: usize, fs: f32) -> Vec<C32> {
        let mut nco = Nco::new(freq_hz, fs);
        let mut out = std::vec![C32::ZERO; n_samples];
        for s in out.iter_mut() {
            *s = nco.next();
        }
        out
    }

    fn run_filter(f: &mut BandpassFilter, fft: &Fft1024, input: &[C32]) -> Vec<C32> {
        let mut out = Vec::with_capacity(input.len());
        let mut i = 0;
        while i + BLOCK <= input.len() {
            let mut in_block = [C32::ZERO; BLOCK];
            in_block.copy_from_slice(&input[i..i + BLOCK]);
            let mut out_block = [C32::ZERO; BLOCK];
            f.process_block(fft, &in_block, &mut out_block);
            out.extend_from_slice(&out_block);
            i += BLOCK;
        }
        out
    }

    fn rms(x: &[C32]) -> f32 {
        let sum: f32 = x.iter().map(|s| s.norm_sqr()).sum();
        libm::sqrtf(sum / x.len() as f32)
    }

    /// Passband: a tone at the filter's center should come through near 0 dB.
    #[test]
    fn passband_gain_near_unity() {
        let fft = Fft1024::new();
        let mut bpf = BandpassFilter::design(&fft, FS, 200.0, 2800.0, 0.0, MAX_TAPS);
        let n = 40 * BLOCK; // ~0.43 s, several times the filter's settling time
        let sig = tone(1500.0, n, FS); // mid-passband
        let out = run_filter(&mut bpf, &fft, &sig);
        // Discard the first block (filter settling / overlap-save fill-in). Input tone is a
        // unit-magnitude phasor (rms 1.0), so gain in dB is just 20*log10(output rms).
        let settled = &out[BLOCK..];
        let gain_db = 20.0 * libm::log10f(rms(settled));
        std::println!("MEASURED passband gain: {gain_db} dB");
        assert!(gain_db.abs() < 0.6, "passband gain {gain_db} dB (want ~0 dB)");
    }

    /// Stopband: a tone well outside `[low_hz, high_hz]` should be rejected by at least 50 dB
    /// relative to the same tone in the passband.
    #[test]
    fn stopband_rejects_out_of_band_tone() {
        let fft = Fft1024::new();
        let n = 40 * BLOCK;

        let mut bpf_pass = BandpassFilter::design(&fft, FS, 200.0, 2800.0, 0.0, MAX_TAPS);
        let in_band = tone(1500.0, n, FS);
        let out_pass = run_filter(&mut bpf_pass, &fft, &in_band);
        let pass_level = rms(&out_pass[BLOCK..]);

        let mut bpf_stop = BandpassFilter::design(&fft, FS, 200.0, 2800.0, 0.0, MAX_TAPS);
        let out_of_band = tone(8000.0, n, FS); // well past the 2800 Hz edge
        let out_stop = run_filter(&mut bpf_stop, &fft, &out_of_band);
        let stop_level = rms(&out_stop[BLOCK..]);

        let rejection_db = 20.0 * libm::log10f(pass_level / stop_level);
        std::println!("MEASURED stopband rejection: {rejection_db} dB");
        assert!(rejection_db > 50.0, "stopband rejection only {rejection_db} dB");
    }

    /// SSB filtering with `shift_hz = 0`: a tone stays at its own frequency (only the opposite
    /// sideband is rejected, nothing is translated).
    #[test]
    fn zero_shift_leaves_frequency_unchanged() {
        let fft = Fft1024::new();
        let mut bpf = BandpassFilter::design(&fft, FS, 300.0, 2700.0, 0.0, MAX_TAPS);
        let n = 60 * BLOCK;
        let sig = tone(1000.0, n, FS);
        let out = run_filter(&mut bpf, &fft, &sig);
        let settled = &out[10 * BLOCK..];
        let residual_hz = avg_freq(settled, FS);
        assert!((residual_hz - 1000.0).abs() < 2.0, "tone moved to {residual_hz} Hz, expected 1000 Hz");
    }

    /// Nonzero `shift_hz` translates the output frequency by exactly that amount (used for CW
    /// pitch and RIT).
    #[test]
    fn nonzero_shift_translates_frequency() {
        let fft = Fft1024::new();
        let mut bpf = BandpassFilter::design(&fft, FS, -1500.0, 1500.0, 700.0, MAX_TAPS);
        let n = 60 * BLOCK;
        let sig = tone(0.0, n, FS); // carrier at passband center, 0 Hz
        let out = run_filter(&mut bpf, &fft, &sig);
        let settled = &out[10 * BLOCK..];
        let residual_hz = avg_freq(settled, FS);
        assert!((residual_hz - 700.0).abs() < 2.0, "tone landed at {residual_hz} Hz, expected 700 Hz");
    }

    /// Average frequency of a (mostly single-tone) complex signal, from the mean phase advance
    /// between consecutive samples.
    fn avg_freq(x: &[C32], fs: f32) -> f32 {
        let mut phase_sum = 0.0f32;
        let mut count = 0;
        for w in x.windows(2) {
            if w[0].norm_sqr() > 1e-9 {
                let step = w[1] * w[0].conj().scale(1.0 / w[0].norm_sqr());
                phase_sum += step.arg_turns();
                count += 1;
            }
        }
        (phase_sum / count as f32) * fs
    }
}
