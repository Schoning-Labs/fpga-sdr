// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The FT8 screen's waterfall, computed in software from the receiver's 12 ksps audio, as lines of
//! palette indices (one byte per screen column) for `tr_fabric::wfring::SoftWaterfall`.
//!
//! The FPGA's full-band waterfall spans 0 to 38.4 MHz, and the zoom spectrum (see `wflevel`) needs
//! the chip's zoom receiver. This software one needs neither (the QEMU image uses it) and spans the
//! audio band 0 to 3,000 Hz across the window: column `c` of `cols` shows
//! `(c + 0.5) * 3000 / cols` Hz, so the FT8 screen's frequency scale (0 to 3,000 Hz across the
//! window width) lines up with it.
//!
//! **Line.** One per FT8 symbol period ([`HOP`] = 1,920 samples = 160 ms, 6.25 lines per second).
//! The newest [`WINDOW`] = 2,048 samples (171 ms, about one symbol) are multiplied by a Hann window,
//! zero-padded to 4,096 and transformed (bins of 2.93 Hz, 2.4 per FT8 tone spacing). Each column
//! takes the strongest bin it covers.
//!
//! **Level to color.** The power of each column in dB relative to a full-scale sine; the line's
//! mean (a smoothed noise-floor estimate, time constant about 1.6 s) is mapped to palette index
//! [`NOISE_INDEX`] and each dB above it adds [`INDEX_PER_DB`], clamped to 0 to 255. So the noise sits
//! in dark blue whatever the receiver gain, and an FT8 signal 20 dB above the noise in its bin
//! shows yellow.
//!
//! **The FFT** is a plain radix-2 complex transform of 2,048 points with the real-input untangling
//! step (the 4,096-point real transform in half the work), tables on the heap. It is not the
//! decoder's: that one (`tr_modes::fft`) is f64, recursive and allocates on every call, and the
//! optimized one in `tr_dsp::fft` builds its tables (about 50 KB) on the stack, which the board's
//! 32 KB stack does not hold.

use alloc::vec;
use alloc::vec::Vec;

/// Samples transformed per line (171 ms at 12 ksps).
pub const WINDOW: usize = 2_048;
/// Samples between lines: one FT8 symbol at 12 ksps.
pub const HOP: usize = 1_920;
/// Complex transform length (the real transform is twice this).
const N: usize = 2_048;
/// Audio sample rate of the input, Hz.
pub const AUDIO_RATE: f32 = 12_000.0;
/// Top of the waterfall, Hz.
pub const SPAN_HZ: f32 = 3_000.0;
/// Palette index of the (estimated) noise level.
pub const NOISE_INDEX: f32 = 40.0;
/// Palette index steps per dB.
pub const INDEX_PER_DB: f32 = 6.0;
/// Weight of a new line in the noise estimate.
const REF_ALPHA: f32 = 0.1;
/// `20 log10(32768 * 512)`: full-scale sine, Hann window of 2,048 samples (coherent gain 1,024, half
/// of it per sideband).
const FULL_SCALE_DB: f32 = 144.49;
/// Lowest noise estimate, dB re full scale.
const MIN_REF_DB: f32 = -100.0;

/// log2 of a positive finite float to within about 1e-4 (exponent from the bits, the mantissa by the atanh series).
pub fn fast_log2(x: f32) -> f32 {
    let bits = x.to_bits();
    let e = ((bits >> 23) & 0xFF) as i32 - 127;
    let m = f32::from_bits((bits & 0x007F_FFFF) | 0x3F80_0000); // [1, 2)
    let t = (m - 1.0) / (m + 1.0);
    let t2 = t * t;
    let p = 2.885_39 * t * (1.0 + t2 * (1.0 / 3.0 + t2 * (0.2 + t2 * (1.0 / 7.0))));
    e as f32 + p
}

/// Generator of waterfall lines: owns the transform tables and the running noise estimate, so one
/// instance is kept per waterfall and fed every [`HOP`] samples.
pub struct WaterfallGen {
    /// `exp(-2 pi i k / 4096)` for k in 0..2048 (real and imaginary parts).
    tw_re: Vec<f32>,
    tw_im: Vec<f32>,
    /// Bit-reversed index of each position of the 2,048-point transform.
    rev: Vec<u16>,
    /// Hann window, [`WINDOW`] points.
    window: Vec<f32>,
    /// Work buffers of the complex transform.
    re: Vec<f32>,
    im: Vec<f32>,
    /// Power per bin 0..=1024 (0 to 3,000 Hz).
    pow: Vec<f32>,
    /// Bins each column covers: `lo[c]..=hi[c]`.
    lo: Vec<u16>,
    hi: Vec<u16>,
    /// Smoothed noise estimate, dB re full scale.
    ref_db: f32,
    /// False until the first line has set `ref_db` directly.
    primed: bool,
}

impl WaterfallGen {
    /// A generator for lines of `cols` columns over 0 to 3,000 Hz.
    pub fn new(cols: usize) -> Self {
        assert!((1..=1_920).contains(&cols));
        let mut tw_re = Vec::with_capacity(N);
        let mut tw_im = Vec::with_capacity(N);
        for k in 0..N {
            let a = -core::f64::consts::TAU * k as f64 / (2 * N) as f64;
            tw_re.push(libm::cos(a) as f32);
            tw_im.push(libm::sin(a) as f32);
        }
        let bits = N.trailing_zeros();
        let rev = (0..N as u32).map(|i| (i.reverse_bits() >> (32 - bits)) as u16).collect();
        let window = (0..WINDOW).map(|n| (0.5 - 0.5 * libm::cos(core::f64::consts::TAU * n as f64 / WINDOW as f64)) as f32).collect();
        // Bin k is at k * 12000 / 4096 Hz; column c covers [c, c + 1) * 3000 / cols Hz.
        let bin_per_col = (SPAN_HZ * (2 * N) as f32 / AUDIO_RATE) / cols as f32;
        let mut lo = Vec::with_capacity(cols);
        let mut hi = Vec::with_capacity(cols);
        for c in 0..cols {
            let l = ((c as f32 * bin_per_col) as usize).max(1);
            let h = ((((c + 1) as f32 * bin_per_col) as usize).max(l)).min(N / 2);
            lo.push(l as u16);
            hi.push(h as u16);
        }
        WaterfallGen { tw_re, tw_im, rev, window, re: vec![0.0; N], im: vec![0.0; N], pow: vec![0.0; N / 2 + 1], lo, hi, ref_db: 0.0, primed: false }
    }

    /// Number of columns per line.
    pub fn cols(&self) -> usize {
        self.lo.len()
    }

    /// In-place radix-2 forward transform of `re`/`im`, input in natural order.
    fn fft(&mut self) {
        let (re, im) = (&mut self.re, &mut self.im);
        for i in 0..N {
            let j = self.rev[i] as usize;
            if j > i {
                re.swap(i, j);
                im.swap(i, j);
            }
        }
        let mut len = 2;
        while len <= N {
            let half = len / 2;
            let step = (2 * N) / len; // twiddle index step in the 4096-point table
            let mut i = 0;
            while i < N {
                for k in 0..half {
                    let (wr, wi) = (self.tw_re[k * step], self.tw_im[k * step]);
                    let (a, b) = (i + k, i + k + half);
                    let tr = re[b] * wr - im[b] * wi;
                    let ti = re[b] * wi + im[b] * wr;
                    re[b] = re[a] - tr;
                    im[b] = im[a] - ti;
                    re[a] += tr;
                    im[a] += ti;
                }
                i += len;
            }
            len *= 2;
        }
    }

    /// Powers of bins 0..=1024 of the 4,096-point real transform of `samples` (windowed, zero padded).
    fn spectrum(&mut self, samples: &[i16]) {
        // Even samples to the real part, odd to the imaginary part of z[n]; z[n] = 0 for n >= 1024.
        for n in 0..WINDOW / 2 {
            self.re[n] = samples[2 * n] as f32 * self.window[2 * n];
            self.im[n] = samples[2 * n + 1] as f32 * self.window[2 * n + 1];
        }
        for n in WINDOW / 2..N {
            self.re[n] = 0.0;
            self.im[n] = 0.0;
        }
        self.fft();
        // Untangle: E[k] = (Z[k] + conj Z[N-k]) / 2, O[k] = (Z[k] - conj Z[N-k]) / 2i, X[k] = E[k] + W^k O[k].
        let z0 = (self.re[0], self.im[0]);
        self.pow[0] = (z0.0 + z0.1) * (z0.0 + z0.1);
        for k in 1..=N / 2 {
            let j = N - k;
            let (zkr, zki, zjr, zji) = (self.re[k], self.im[k], self.re[j], self.im[j]);
            let (er, ei) = (0.5 * (zkr + zjr), 0.5 * (zki - zji));
            let (or, oi) = (0.5 * (zki + zji), -0.5 * (zkr - zjr));
            let (wr, wi) = (self.tw_re[k], self.tw_im[k]);
            let xr = er + or * wr - oi * wi;
            let xi = ei + or * wi + oi * wr;
            self.pow[k] = xr * xr + xi * xi;
        }
    }

    /// One waterfall line from the newest [`WINDOW`] samples (`samples.len()` must be [`WINDOW`]) into
    /// `out` (`cols()` bytes of palette index).
    pub fn line(&mut self, samples: &[i16], out: &mut [u8]) {
        assert_eq!(samples.len(), WINDOW);
        assert!(out.len() >= self.cols());
        self.spectrum(samples);
        let cols = self.cols();
        let mut sum = 0.0f32;
        // The column levels are needed twice (mean, then mapping): the second pass recomputes the
        // maximum from the power array, which is cheaper than storing 1,172 floats and reading them back.
        for c in 0..cols {
            let mut p = 0.0f32;
            for k in self.lo[c]..=self.hi[c] {
                p = p.max(self.pow[k as usize]);
            }
            sum += 3.010_3 * fast_log2(p.max(1e-9));
        }
        // Silence (digital zero) must not drag the noise estimate to minus infinity: below about
        // the 16-bit quantization floor there is nothing to scale to.
        let mean_db = (sum / cols as f32 - FULL_SCALE_DB).max(MIN_REF_DB);
        self.ref_db = if self.primed { self.ref_db + REF_ALPHA * (mean_db - self.ref_db) } else { mean_db };
        self.primed = true;
        let offset = NOISE_INDEX - self.ref_db * INDEX_PER_DB;
        for c in 0..cols {
            let mut p = 0.0f32;
            for k in self.lo[c]..=self.hi[c] {
                p = p.max(self.pow[k as usize]);
            }
            let db = 3.010_3 * fast_log2(p.max(1e-9)) - FULL_SCALE_DB;
            out[c] = (db * INDEX_PER_DB + offset).clamp(0.0, 255.0) as u8;
        }
    }

    /// The noise level estimate, dB re full scale.
    pub fn noise_db(&self) -> f32 {
        self.ref_db
    }
}

/// The column that shows audio frequency `hz` in a line of `cols` columns.
pub fn column_of(hz: f32, cols: usize) -> usize {
    ((hz * cols as f32 / SPAN_HZ) as usize).min(cols - 1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloc::vec::Vec;

    struct Lcg(u32);
    impl Lcg {
        /// Uniform in [-1, 1).
        fn next(&mut self) -> f32 {
            self.0 = self.0.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            (self.0 >> 8) as f32 / (1u32 << 23) as f32 - 1.0
        }
        /// Roughly Gaussian (sum of 4 uniforms), unit variance.
        fn gauss(&mut self) -> f32 {
            (self.next() + self.next() + self.next() + self.next()) * 0.866
        }
    }

    /// Center of the columns at the line's maximum (saturated tones are a plateau).
    fn argmax(line: &[u8]) -> usize {
        let m = *line.iter().max().unwrap();
        let first = line.iter().position(|&v| v == m).unwrap();
        let last = line.iter().rposition(|&v| v == m).unwrap();
        (first + last) / 2
    }

    #[allow(dead_code)]
    fn argmax_first(line: &[u8]) -> usize {
        line.iter().enumerate().max_by_key(|&(i, &v)| (v, core::cmp::Reverse(i))).unwrap().0
    }

    #[test]
    fn log2_is_accurate() {
        for &x in &[1e-9f32, 0.3, 1.0, 1.5, 1.999, 2.0, 7.7, 12_345.6, 3.0e9] {
            assert!((fast_log2(x) - libm::log2f(x)).abs() < 5e-4, "{x}: {} vs {}", fast_log2(x), libm::log2f(x));
        }
    }

    #[test]
    fn spectrum_matches_a_direct_dft() {
        let mut g = WaterfallGen::new(1_172);
        let mut rng = Lcg(7);
        let s: Vec<i16> = (0..WINDOW).map(|n| (6_000.0 * libm::sinf(0.3 * n as f32) + 2_000.0 * rng.gauss()) as i16).collect();
        g.spectrum(&s);
        for &k in &[1usize, 5, 100, 130, 511, 777, 1_024] {
            let (mut re, mut im) = (0.0f64, 0.0f64);
            for (n, &x) in s.iter().enumerate() {
                let w = 0.5 - 0.5 * libm::cos(core::f64::consts::TAU * n as f64 / WINDOW as f64);
                let a = -core::f64::consts::TAU * (k * n) as f64 / 4096.0;
                re += x as f64 * w * libm::cos(a);
                im += x as f64 * w * libm::sin(a);
            }
            let want = re * re + im * im;
            let got = g.pow[k] as f64;
            assert!((got - want).abs() <= 1e-3 * want + 1e3, "bin {k}: {got} vs {want}");
        }
    }

    #[test]
    fn tone_lands_in_its_column() {
        let cols = 1_172;
        let mut g = WaterfallGen::new(cols);
        let mut out = vec![0u8; cols];
        let mut rng = Lcg(1);
        for &hz in &[210.0f32, 1_000.0, 1_500.0, 2_000.0, 2_937.5] {
            let s: Vec<i16> = (0..WINDOW)
                .map(|n| (3_000.0 * libm::sinf(core::f32::consts::TAU * hz * n as f32 / AUDIO_RATE) + 300.0 * rng.gauss()) as i16)
                .collect();
            g.line(&s, &mut out);
            let want = column_of(hz, cols) as i32;
            let got = argmax(&out) as i32;
            assert!((got - want).abs() <= 1, "{hz} Hz: column {got}, expected {want}");
            // Far above the floor, which sits at the noise index.
            assert!(out[got as usize] > 200, "{hz} Hz: level {}", out[got as usize]);
            let median = {
                let mut v = out.clone();
                v.sort_unstable();
                v[cols / 2]
            };
            assert!((20..90).contains(&median), "median {median}");
        }
    }

    #[test]
    fn ft8_tones_land_in_their_columns() {
        use tr_modes::encode::ft8::encode_i16;
        use tr_modes::txbb::tones;
        let cols = 1_172;
        let f0 = 1_500.0f32;
        let (f1, f2, f3) = ("CQ", "K1XYZ", "FN42");
        let tone = tones(f1, f2, f3).unwrap();
        let mut audio = encode_i16(f1, f2, f3, f0, 6_000).unwrap();
        // Noise 4,000 rms: about -5 dB in 2.5 kHz, 24 dB above the noise in a 2.9 Hz bin.
        let mut rng = Lcg(99);
        audio.resize(79 * 1_920 + 4_096, 0);
        for s in audio.iter_mut() {
            *s = (*s as f32 + 4_000.0 * rng.gauss()) as i16;
        }
        let mut g = WaterfallGen::new(cols);
        let mut out = vec![0u8; cols];
        let mut good = 0;
        // Symbol s covers samples [s * 1920, (s + 1) * 1920); a line centred on it.
        for s in 1..79usize {
            let start = s * HOP + HOP / 2 - WINDOW / 2;
            g.line(&audio[start..start + WINDOW], &mut out);
            let want = column_of(f0 + 6.25 * tone[s] as f32, cols) as i32;
            let got = argmax(&out) as i32;
            if (got - want).abs() <= 1 {
                good += 1;
            }
        }
        assert!(good >= 74, "{good} of 78 symbols in the right column");
        // A line with no signal has no column above the middle of the palette.
        let quiet = &audio[79 * 1_920..79 * 1_920 + WINDOW];
        g.line(quiet, &mut out);
        assert!(out.iter().all(|&v| v < 140), "max {}", out.iter().max().unwrap());
    }

    #[test]
    fn noise_floor_is_held_at_its_index_whatever_the_gain() {
        let cols = 1_172;
        let mut rng = Lcg(5);
        let mut floors = Vec::new();
        for amp in [30.0f32, 300.0, 3_000.0] {
            let mut g = WaterfallGen::new(cols);
            let mut out = vec![0u8; cols];
            let mut sum = 0u64;
            for _ in 0..20 {
                let s: Vec<i16> = (0..WINDOW).map(|_| (amp * rng.gauss()) as i16).collect();
                g.line(&s, &mut out);
            }
            for &v in &out {
                sum += v as u64;
            }
            floors.push(sum as f32 / cols as f32);
        }
        for f in &floors {
            assert!((*f - NOISE_INDEX).abs() < 25.0, "{floors:?}");
        }
        assert!((floors[0] - floors[2]).abs() < 6.0, "{floors:?}");
    }
}
