// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Rational resampler to 48 kHz, scoped to the ratios this project actually needs: every
//! receiver-bank output rate (`docs/rawfront`/`rx-dsp` rates 48/96/192/384 ksps) is an exact
//! integer multiple of 48 kHz, so the general `L/M` polyphase resampler collapses to an
//! anti-aliased FIR decimator by `M` in `{1, 2, 4, 8}`, that is what [`Decimator`] implements.
//! `M = 1` bypasses filtering entirely (nothing to alias, nothing to remove).
//!
//! Runs on the raw receiver-bank IQ, before the channel filter (which is fixed at operating on
//! 48 kHz, 512-sample blocks, see `docs/S3_DSP.md` section 2 for the pipeline order).

use crate::complex::C32;
use crate::fmath::mul_add;
use crate::window::{blackman_harris, sinc};

/// Most taps of the anti-alias filter.
pub const MAX_TAPS: usize = 129;

/// FIR decimator by 1, 2, 4 or 8 from the receiver-bank rate to 48 kHz.
pub struct Decimator {
    m: u32,
    taps: [f32; MAX_TAPS],
    ntaps: usize,
    /// Delay line stored twice (`delay[i]` and `delay[i + ntaps]` always hold the same sample),
    /// so the last `ntaps` samples are always the contiguous run `delay[pos..pos + ntaps]`: the
    /// dot product needs no wrap-around test and the write position no `%` (an integer
    /// division) per input sample (docs/CPU_BUDGET.md section 4).
    delay: [C32; 2 * MAX_TAPS],
    pos: usize,
    counter: u32,
}

impl Decimator {
    /// `m` = 1, 2, 4, or 8 for this project's rates; any `m >= 1` works, larger ratios just get
    /// more taps (capped at [`MAX_TAPS`]).
    pub fn new(m: u32) -> Self {
        let m = m.max(1);
        let mut taps = [0.0f32; MAX_TAPS];
        let mut ntaps = 0;
        if m > 1 {
            ntaps = ((8 * m + 1) as usize).min(MAX_TAPS);
            if ntaps % 2 == 0 {
                ntaps -= 1;
            }
            let cutoff = 0.9 / (2.0 * m as f32); // cycles/sample, a bit inside the decimated Nyquist
            let mid = (ntaps - 1) as f32 / 2.0;
            let mut sum = 0.0f32;
            for n in 0..ntaps {
                let t = n as f32 - mid;
                let v = 2.0 * cutoff * sinc(2.0 * cutoff * t) * blackman_harris(n, ntaps);
                taps[n] = v;
                sum += v;
            }
            if sum.abs() > 1e-12 {
                for v in taps.iter_mut().take(ntaps) {
                    *v /= sum;
                }
            }
        }
        Decimator {
            m,
            taps,
            ntaps,
            delay: [C32::ZERO; 2 * MAX_TAPS],
            pos: 0,
            counter: 0,
        }
    }

    /// Feeds one input sample; returns `Some(output)` every `m`th call (`None` otherwise).
    #[inline]
    pub fn process(&mut self, x: C32) -> Option<C32> {
        if self.m == 1 {
            return Some(x);
        }
        self.delay[self.pos] = x;
        self.delay[self.pos + self.ntaps] = x;
        self.pos += 1;
        if self.pos == self.ntaps {
            self.pos = 0;
        }
        self.counter += 1;
        if self.counter < self.m {
            return None;
        }
        self.counter = 0;
        Some(dot_symmetric(&self.delay[self.pos..self.pos + self.ntaps], &self.taps[..self.ntaps]))
    }

    /// Decimates a whole block: the same result as calling [`process`](Self::process) on every
    /// input sample, but with the filter state kept in registers across the block. Writes the
    /// outputs to the front of `output` and returns how many there were (at most
    /// `input.len() / m + 1`; `output` must have room for that many).
    pub fn process_block(&mut self, input: &[C32], output: &mut [C32]) -> usize {
        if self.m == 1 {
            output[..input.len()].copy_from_slice(input);
            return input.len();
        }
        let (ntaps, m) = (self.ntaps, self.m);
        let (mut pos, mut counter, mut n_out) = (self.pos, self.counter, 0);
        for &x in input {
            self.delay[pos] = x;
            self.delay[pos + ntaps] = x;
            pos += 1;
            if pos == ntaps {
                pos = 0;
            }
            counter += 1;
            if counter == m {
                counter = 0;
                output[n_out] = dot_symmetric(&self.delay[pos..pos + ntaps], &self.taps[..ntaps]);
                n_out += 1;
            }
        }
        self.pos = pos;
        self.counter = counter;
        n_out
    }

    /// The decimation ratio.
    pub fn ratio(&self) -> u32 {
        self.m
    }
}

/// Dot product of the last `ntaps` samples (oldest first) with a **symmetric** odd-length tap set
/// (every windowed-sinc design here is): mirrored samples are added first, so each tap is
/// multiplied once for two samples. Two accumulators per component halve the length of the
/// dependent fused-multiply-add chain the FPU has to wait on.
#[inline(always)]
fn dot_symmetric(window: &[C32], taps: &[f32]) -> C32 {
    let n = taps.len();
    let h = n / 2;
    let (mut re0, mut im0, mut re1, mut im1) = (0.0f32, 0.0f32, 0.0f32, 0.0f32);
    let lo = &window[..h];
    let hi = &window[n - h..];
    // lo[j] pairs with hi[h-1-j]; two taps per step (rchunks walks hi from its end).
    let lo2 = lo.chunks_exact(2);
    let t2 = taps[..h].chunks_exact(2);
    let (lo_rem, t_rem) = (lo2.remainder(), t2.remainder());
    for ((a, b), t) in lo2.zip(hi.rchunks_exact(2)).zip(t2) {
        re0 = mul_add(a[0].re + b[1].re, t[0], re0);
        im0 = mul_add(a[0].im + b[1].im, t[0], im0);
        re1 = mul_add(a[1].re + b[0].re, t[1], re1);
        im1 = mul_add(a[1].im + b[0].im, t[1], im1);
    }
    if let (Some(a), Some(&t)) = (lo_rem.first(), t_rem.first()) {
        // h odd: lo[h-1] pairs with hi[0].
        re0 = mul_add(a.re + hi[0].re, t, re0);
        im0 = mul_add(a.im + hi[0].im, t, im0);
    }
    if n % 2 == 1 {
        re0 = mul_add(window[h].re, taps[h], re0);
        im0 = mul_add(window[h].im, taps[h], im0);
    }
    C32::new(re0 + re1, im0 + im1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::vec::Vec;

    fn run(dec: &mut Decimator, input: &[C32]) -> Vec<C32> {
        let mut out = Vec::new();
        for &x in input {
            if let Some(y) = dec.process(x) {
                out.push(y);
            }
        }
        out
    }

    fn tone(freq_hz: f32, n: usize, fs: f32) -> Vec<C32> {
        let mut nco = crate::nco::Nco::new(freq_hz, fs);
        let mut out = std::vec![C32::ZERO; n];
        for s in out.iter_mut() {
            *s = nco.next();
        }
        out
    }

    fn rms(x: &[C32]) -> f32 {
        let sum: f32 = x.iter().map(|s| s.norm_sqr()).sum();
        libm::sqrtf(sum / x.len() as f32)
    }

    #[test]
    fn decimate_by_2_preserves_in_band_tone_rate_and_level() {
        let fs_in = 96_000.0;
        let n = 20_000;
        let sig = tone(8_000.0, n, fs_in); // well inside the decimated (48k) Nyquist of 24k
        let mut dec = Decimator::new(2);
        let out = run(&mut dec, &sig);
        assert!((out.len() as i64 - n as i64 / 2).abs() <= 1, "output length {} expected ~{}", out.len(), n / 2);

        let settled = &out[200..];
        let level = rms(settled);
        std::println!("MEASURED decimate-by-2 passband level: {level}");
        assert!((level - 1.0).abs() < 0.05, "passband level after decimation: {level}, expected ~1.0");

        // Frequency should read back as 8 kHz at the new 48 ksps rate.
        let mut phase_sum = 0.0f32;
        for w in settled.windows(2) {
            let step = w[1] * w[0].conj().scale(1.0 / w[0].norm_sqr().max(1e-9));
            phase_sum += step.arg_turns();
        }
        let freq = (phase_sum / (settled.len() - 1) as f32) * 48_000.0;
        assert!((freq - 8_000.0).abs() < 20.0, "decimated tone frequency {freq} Hz, expected 8000 Hz");
    }

    #[test]
    fn decimate_by_8_rejects_a_tone_that_would_alias() {
        let fs_in = 384_000.0;
        let n = 40_000;
        // 20 kHz is inside the decimated Nyquist (24 kHz), passband reference.
        let pass = tone(20_000.0, n, fs_in);
        let mut dec_pass = Decimator::new(8);
        let out_pass = run(&mut dec_pass, &pass);
        let pass_level = rms(&out_pass[500..]);

        // 180 kHz would alias to 384/8 grid folding near the decimated band if not filtered.
        let alias_candidate = tone(180_000.0, n, fs_in);
        let mut dec_stop = Decimator::new(8);
        let out_stop = run(&mut dec_stop, &alias_candidate);
        let stop_level = rms(&out_stop[500..]);

        let rejection_db = 20.0 * libm::log10f(pass_level / stop_level);
        std::println!("MEASURED decimate-by-8 anti-alias rejection: {rejection_db} dB");
        assert!(rejection_db > 40.0, "anti-alias rejection only {rejection_db} dB");
    }

    #[test]
    fn block_and_per_sample_paths_match_a_direct_convolution() {
        for m in [2u32, 4, 8] {
            let fs = 48_000.0 * m as f32;
            let sig: Vec<C32> = tone(3_000.0, 3001, fs)
                .iter()
                .enumerate()
                .map(|(i, s)| *s + C32::new(0.001 * (i % 7) as f32, -0.002 * (i % 5) as f32))
                .collect();
            let mut a = Decimator::new(m);
            let per_sample = run(&mut a, &sig);
            let mut b = Decimator::new(m);
            let mut block = std::vec![C32::ZERO; sig.len() / m as usize + 1];
            let mut n_out = 0;
            for chunk in sig.chunks(777) {
                n_out += b.process_block(chunk, &mut block[n_out..]);
            }
            block.truncate(n_out);
            assert_eq!(per_sample, block, "m={m}: block path differs from per-sample path");

            // Direct convolution: output j is sum_k taps[k] * x[(j+1)*m - 1 - k].
            let ref_dec = Decimator::new(m);
            for (j, y) in per_sample.iter().enumerate() {
                let newest = (j + 1) * m as usize - 1;
                let mut acc = (0.0f64, 0.0f64);
                for k in 0..ref_dec.ntaps {
                    if newest >= k {
                        let x = sig[newest - k];
                        acc.0 += ref_dec.taps[k] as f64 * x.re as f64;
                        acc.1 += ref_dec.taps[k] as f64 * x.im as f64;
                    }
                }
                assert!((y.re as f64 - acc.0).abs() < 1e-5 && (y.im as f64 - acc.1).abs() < 1e-5, "m={m} output {j}");
            }
        }
    }

    #[test]
    fn ratio_one_is_a_pass_through() {
        let mut dec = Decimator::new(1);
        let sig = tone(1000.0, 1000, 48_000.0);
        let out = run(&mut dec, &sig);
        assert_eq!(out.len(), sig.len());
        for (a, b) in out.iter().zip(sig.iter()) {
            assert_eq!(a.re, b.re);
            assert_eq!(a.im, b.im);
        }
    }
}
