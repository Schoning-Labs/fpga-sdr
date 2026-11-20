// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Fixed-size complex FFT, in place, no allocation, plus a real-input FFT built on it.
//!
//! [`Fft<N>`] works for any power-of-two `N` from 2 to 32,768. [`Fft1024`] (`Fft<1024>`) is the
//! size the fast-convolution channel filter uses (`docs/ARCHITECTURE.md` section 5.5); smaller
//! sizes serve the 12 ksps noise reducer (`docs/CPU_BUDGET.md`).
//!
//! Algorithm (see `docs/CPU_BUDGET.md` section 4 for the measurements): iterative
//! decimation in time on bit-reversed input with **radix-4** butterflies (two radix-2 stages
//! fused, so every data word is loaded and stored half as often), and one radix-2 stage first
//! when `log2 N` is odd. The first stage has no twiddle multiplies. Twiddles are precomputed in
//! double precision per stage and stored in the order the butterflies read them, so the inner
//! loop is plain pointer walks with no index arithmetic and no bounds checks. Forward and
//! inverse are separate monomorphised loops (no per-butterfly `if inverse`).
//!
//! How the radix-4 step works on bit-reversed data: after the stages for span `L`, the buffer
//! holds consecutive length-`L` DFTs. Four consecutive blocks `A0..A3` are the DFTs of the input
//! samples whose index is 0, 2, 1, 3 (mod 4) within the next span of `4L` (bit reversal puts the
//! residues in that order). With `W = exp(-2 pi i / 4L)`, `t0 = A0[k]`, `t1 = W^k A2[k]`,
//! `t2 = W^2k A1[k]`, `t3 = W^3k A3[k]`:
//!
//! ```text
//! X[k]    = (t0 + t2) + (t1 + t3)        X[k+2L] = (t0 + t2) - (t1 + t3)
//! X[k+L]  = (t0 - t2) - i (t1 - t3)      X[k+3L] = (t0 - t2) + i (t1 - t3)
//! ```
//!
//! The inverse transform conjugates `W` and swaps the signs of the `i` terms.

use crate::complex::C32;
use crate::fmath::{mul_add, mul_sub};

/// Length of the FFT of the channel filter.
pub const FFT_LEN: usize = 1024;

/// The 1,024-point transform the channel filter uses.
pub type Fft1024 = Fft<1024>;

/// In-place complex FFT of size `N`, with its twiddle factors.
pub struct Fft<const N: usize> {
    /// Twiddles of every radix-4 stage after the first, stage by stage; within a stage of span
    /// `4L`, for each `k` in `0..L` the three values `W^k, W^2k, W^3k`. The total, `3 * (sum of
    /// L)`, is always below `N`, so an `N`-long array holds it.
    tw: [C32; N],
    /// Bit-reversal permutation as a list of index pairs to swap (`swaps[2m]`, `swaps[2m+1]`),
    /// `n_swaps` pairs; at most `N/2` pairs, so an `N`-long array holds it. Walking only the
    /// pairs that move is cheaper than testing every index.
    swaps: [u16; N],
    n_swaps: usize,
    /// `rev_even[m]` = bit reversal of `2m`, for `m` in `0..N/2` (upper half unused). Used by
    /// [`Fft::forward_overlap_save`] to gather its two input halves straight into bit-reversed
    /// order: bit-reversing an even index gives a value below `N/2`, and `rev(2m+1) =
    /// rev(2m) + N/2`, so even output slots come from the first half and odd ones from the
    /// second half at the same offset.
    rev_even: [u16; N],
}

impl<const N: usize> Fft<N> {
    pub fn new() -> Self {
        assert!(
            N.is_power_of_two() && (2..=32_768).contains(&N),
            "FFT size must be a power of two, 2..=32768"
        );
        let log2n = N.trailing_zeros();
        let mut tw = [C32::ZERO; N];
        let mut off = 0;
        let mut l = Self::first_radix4_span();
        while l < N {
            for k in 0..l {
                for r in 1..=3usize {
                    // Double precision so the table adds no rounding of its own.
                    let theta = -((r * k) as f64) / (4 * l) as f64 * core::f64::consts::TAU;
                    tw[off] = C32::new(libm::cos(theta) as f32, libm::sin(theta) as f32);
                    off += 1;
                }
            }
            l *= 4;
        }
        let mut swaps = [0u16; N];
        let mut n_swaps = 0;
        for i in 0..N {
            let j = reverse_bits(i as u32, log2n) as usize;
            if j > i {
                swaps[2 * n_swaps] = i as u16;
                swaps[2 * n_swaps + 1] = j as u16;
                n_swaps += 1;
            }
        }
        let mut rev_even = [0u16; N];
        for m in 0..N / 2 {
            rev_even[m] = reverse_bits((2 * m) as u32, log2n) as u16;
        }
        Fft { tw, swaps, n_swaps, rev_even }
    }

    /// Span `L` of the first radix-4 stage that needs twiddles: after a twiddle-free radix-4
    /// stage (`L = 1`) when `log2 N` is even, after a radix-2 first stage when it is odd.
    const fn first_radix4_span() -> usize {
        if N.trailing_zeros() % 2 == 0 {
            4
        } else {
            2
        }
    }

    /// In-place forward FFT (no scaling).
    pub fn forward(&self, buf: &mut [C32; N]) {
        self.transform::<false>(buf);
    }

    /// In-place inverse FFT, scaled by `1/N` so `inverse(forward(x)) == x`.
    pub fn inverse(&self, buf: &mut [C32; N]) {
        self.transform::<true>(buf);
        let scale = 1.0 / N as f32;
        for s in buf.iter_mut() {
            *s = s.scale(scale);
        }
    }

    /// In-place inverse FFT **without** the `1/N` scaling. Callers that multiply the spectrum by
    /// something anyway (the fast-convolution filter's frequency response, the noise reducer's
    /// synthesis window) fold `1/N` into that and save a pass over the buffer.
    pub fn inverse_unscaled(&self, buf: &mut [C32; N]) {
        self.transform::<true>(buf);
    }

    /// Forward FFT (no scaling) of the `N` samples `[history | input]` (each `N/2` long) into
    /// `buf`, then `history = input`: the whole input side of a 50 %-overlap overlap-save
    /// filter in one pass. Gathering straight into bit-reversed order saves assembling the
    /// frame, the permutation pass and the history copy (`docs/CPU_BUDGET.md` section 4).
    pub fn forward_overlap_save(&self, history: &mut [C32], input: &[C32], buf: &mut [C32; N]) {
        let h = N / 2;
        assert!(history.len() == h && input.len() == h, "overlap-save halves must be N/2 long");
        for (pair, &r) in buf.chunks_exact_mut(2).zip(self.rev_even[..h].iter()) {
            let r = r as usize;
            pair[0] = history[r];
            pair[1] = input[r];
            history[r] = input[r];
        }
        self.butterflies::<false>(buf);
    }

    fn transform<const INV: bool>(&self, buf: &mut [C32; N]) {
        for p in self.swaps[..2 * self.n_swaps].chunks_exact(2) {
            buf.swap(p[0] as usize, p[1] as usize);
        }
        self.butterflies::<INV>(buf);
    }

    /// All butterfly stages, on data already in bit-reversed order.
    fn butterflies<const INV: bool>(&self, buf: &mut [C32; N]) {

        // First stage, no twiddles.
        if N.trailing_zeros() % 2 == 1 {
            for c in buf.chunks_exact_mut(2) {
                let (a, b) = (c[0], c[1]);
                c[0] = a + b;
                c[1] = a - b;
            }
        } else {
            for c in buf.chunks_exact_mut(4) {
                let (t0, t2, t1, t3) = (c[0], c[1], c[2], c[3]);
                let (u0, u1, u2, u3) = (t0 + t2, t0 - t2, t1 + t3, t1 - t3);
                c[0] = u0 + u2;
                c[2] = u0 - u2;
                let r = rot_i::<INV>(u3);
                c[1] = u1 + r;
                c[3] = u1 - r;
            }
        }

        // Remaining radix-4 stages.
        let mut off = 0;
        let mut l = Self::first_radix4_span();
        while l < N {
            let tw = &self.tw[off..off + 3 * l];
            for group in buf.chunks_exact_mut(4 * l) {
                let (a0, rest) = group.split_at_mut(l);
                let (a1, rest) = rest.split_at_mut(l);
                let (a2, a3) = rest.split_at_mut(l);
                for ((((x0, x1), x2), x3), w) in a0
                    .iter_mut()
                    .zip(a1.iter_mut())
                    .zip(a2.iter_mut())
                    .zip(a3.iter_mut())
                    .zip(tw.chunks_exact(3))
                {
                    let t0 = *x0;
                    let t1 = cmul::<INV>(*x2, w[0]);
                    let t2 = cmul::<INV>(*x1, w[1]);
                    let t3 = cmul::<INV>(*x3, w[2]);
                    let (u0, u1, u2, u3) = (t0 + t2, t0 - t2, t1 + t3, t1 - t3);
                    *x0 = u0 + u2;
                    *x2 = u0 - u2;
                    let r = rot_i::<INV>(u3);
                    *x1 = u1 + r;
                    *x3 = u1 - r;
                }
            }
            off += 3 * l;
            l *= 4;
        }
    }
}

impl<const N: usize> Default for Fft<N> {
    fn default() -> Self {
        Self::new()
    }
}

/// `x * w` (forward) or `x * conj(w)` (inverse): the same instruction count either way, so the
/// inverse transform needs no second twiddle table.
#[inline(always)]
fn cmul<const INV: bool>(x: C32, w: C32) -> C32 {
    if INV {
        C32::new(mul_add(x.re, w.re, x.im * w.im), mul_sub(x.im, w.re, x.re * w.im))
    } else {
        C32::new(mul_sub(x.re, w.re, x.im * w.im), mul_add(x.re, w.im, x.im * w.re))
    }
}

/// `-i * u` (forward) or `+i * u` (inverse).
#[inline(always)]
fn rot_i<const INV: bool>(u: C32) -> C32 {
    if INV {
        C32::new(-u.im, u.re)
    } else {
        C32::new(u.im, -u.re)
    }
}

fn reverse_bits(mut v: u32, bits: u32) -> u32 {
    let mut r = 0u32;
    for _ in 0..bits {
        r = (r << 1) | (v & 1);
        v >>= 1;
    }
    r
}

/// FFT of a real signal of length `2H` through one complex FFT of length `H` (even samples in
/// the real part, odd samples in the imaginary part, then one untangling pass): about half the
/// work of a complex `2H` transform of the same data.
///
/// Spectrum layout (`[C32; H]`, "packed"): element `k` for `1 <= k < H` is bin `k`; element 0
/// holds the two purely real bins, **DC in `.re` and Nyquist (bin `H`) in `.im`**. Bins above
/// `H` are the complex conjugates of those below and are not stored. `H` must be at least 2.
pub struct RealFft<const H: usize> {
    fft: Fft<H>,
    /// `exp(-2 pi i k / 2H)` for `k` in `0..H`.
    w: [C32; H],
}

impl<const H: usize> RealFft<H> {
    pub fn new() -> Self {
        let mut w = [C32::ZERO; H];
        for (k, v) in w.iter_mut().enumerate() {
            let theta = -(k as f64) / (2 * H) as f64 * core::f64::consts::TAU;
            *v = C32::new(libm::cos(theta) as f32, libm::sin(theta) as f32);
        }
        RealFft { fft: Fft::new(), w }
    }

    /// Forward transform of `2H` real samples given as two halves (`first` = samples `0..H`,
    /// `second` = samples `H..2H`; two halves because stable Rust cannot name `[f32; 2 * H]`).
    /// No scaling.
    pub fn forward(&self, first: &[f32; H], second: &[f32; H], out: &mut [C32; H]) {
        let half = H / 2;
        for n in 0..half {
            out[n] = C32::new(first[2 * n], first[2 * n + 1]);
            out[half + n] = C32::new(second[2 * n], second[2 * n + 1]);
        }
        self.fft.forward(out);
        let z0 = out[0];
        out[0] = C32::new(z0.re + z0.im, z0.re - z0.im);
        // Bins k and H-k come out of the same pair Z[k], Z[H-k].
        for k in 1..=half {
            let j = H - k;
            let zk = out[k];
            let zj = out[j];
            // E[k] = (Z[k] + conj Z[j]) / 2, O[k] = (Z[k] - conj Z[j]) / 2i
            let e = C32::new(0.5 * (zk.re + zj.re), 0.5 * (zk.im - zj.im));
            let o = C32::new(0.5 * (zk.im + zj.im), -0.5 * (zk.re - zj.re));
            let wo = o * self.w[k];
            out[k] = e + wo;
            // X[j] = E[j] + W^j O[j] with E[j] = conj E[k], O[j] = conj O[k], W^j = -conj W^k,
            // so X[j] = conj(E[k] - W^k O[k]).
            let xj = e - wo;
            out[j] = C32::new(xj.re, -xj.im);
        }
    }

    /// Inverse of [`forward`](Self::forward), **unscaled**: the output is `2H` times the
    /// original samples (fold `1 / 2H` into whatever multiplies the result next). The spectrum
    /// buffer is used as scratch.
    pub fn inverse_unscaled(&self, spec: &mut [C32; H], first: &mut [f32; H], second: &mut [f32; H]) {
        let half = H / 2;
        let x0 = spec[0];
        // Z'[0] = (DC + Nyq) + i (DC - Nyq)
        spec[0] = C32::new(x0.re + x0.im, x0.re - x0.im);
        for k in 1..=half {
            let j = H - k;
            let xk = spec[k];
            let xj = spec[j];
            // Z'[k] = s + i W^-k d, with s = X[k] + conj X[j], d = X[k] - conj X[j]
            let s = C32::new(xk.re + xj.re, xk.im - xj.im);
            let d = C32::new(xk.re - xj.re, xk.im + xj.im);
            let wd = d * self.w[k].conj();
            spec[k] = s + C32::new(-wd.im, wd.re);
            // Z'[j] = conj(s) + i conj(W^-k d)  (W^-j = -conj W^-k, X[j] - conj X[k] = -conj d)
            spec[j] = C32::new(s.re, -s.im) + C32::new(wd.im, wd.re);
        }
        self.fft.inverse_unscaled(spec);
        for n in 0..half {
            first[2 * n] = spec[n].re;
            first[2 * n + 1] = spec[n].im;
            second[2 * n] = spec[half + n].re;
            second[2 * n + 1] = spec[half + n].im;
        }
    }
}

impl<const H: usize> Default for RealFft<H> {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::vec::Vec;

    fn test_signal(n: usize) -> Vec<C32> {
        (0..n)
            .map(|i| C32::new(libm::sinf(0.01 * i as f32) + 0.3, libm::cosf(0.017 * i as f32) - 0.1))
            .collect()
    }

    /// Direct O(N^2) DFT in double precision: the reference every size is checked against.
    fn dft(x: &[C32], inverse: bool) -> Vec<(f64, f64)> {
        let n = x.len();
        let sign = if inverse { 1.0 } else { -1.0 };
        (0..n)
            .map(|k| {
                let mut acc = (0.0f64, 0.0f64);
                for (m, s) in x.iter().enumerate() {
                    let th = sign * core::f64::consts::TAU * ((k * m) % n) as f64 / n as f64;
                    let (c, si) = (libm::cos(th), libm::sin(th));
                    acc.0 += s.re as f64 * c - s.im as f64 * si;
                    acc.1 += s.re as f64 * si + s.im as f64 * c;
                }
                acc
            })
            .collect()
    }

    fn dist(g: C32, w: (f64, f64)) -> f64 {
        libm::sqrt((g.re as f64 - w.0) * (g.re as f64 - w.0) + (g.im as f64 - w.1) * (g.im as f64 - w.1))
    }

    fn check_size<const N: usize>() {
        let fft = Fft::<N>::new();
        let x = test_signal(N);
        let mut buf = [C32::ZERO; N];
        buf.copy_from_slice(&x);
        fft.forward(&mut buf);
        let want = dft(&x, false);
        let peak = want.iter().map(|w| libm::sqrt(w.0 * w.0 + w.1 * w.1)).fold(1.0, f64::max);
        for (k, (g, w)) in buf.iter().zip(want.iter()).enumerate() {
            let e = dist(*g, *w);
            assert!(e < 2e-6 * peak, "N={N}: forward bin {k} error {e} (peak {peak})");
        }

        fft.inverse(&mut buf);
        for (a, b) in buf.iter().zip(x.iter()) {
            let e = (*a - *b).abs();
            assert!(e < 1e-5, "N={N}: round-trip error {e}");
        }

        let mut ibuf = [C32::ZERO; N];
        ibuf.copy_from_slice(&x);
        fft.inverse_unscaled(&mut ibuf);
        let iwant = dft(&x, true);
        for (k, (g, w)) in ibuf.iter().zip(iwant.iter()).enumerate() {
            let e = dist(*g, *w);
            assert!(e < 2e-6 * peak, "N={N}: inverse bin {k} error {e}");
        }
    }

    #[test]
    fn every_size_matches_a_double_precision_dft() {
        check_size::<2>();
        check_size::<4>();
        check_size::<8>();
        check_size::<16>();
        check_size::<32>();
        check_size::<64>();
        check_size::<128>();
        check_size::<256>();
        check_size::<512>();
        check_size::<1024>();
    }

    #[test]
    fn overlap_save_gather_equals_plain_forward() {
        fn check<const N: usize>() {
            let fft = Fft::<N>::new();
            let x = test_signal(N);
            let mut history: Vec<C32> = x[..N / 2].to_vec();
            let input: Vec<C32> = x[N / 2..].to_vec();
            let mut got = [C32::ZERO; N];
            fft.forward_overlap_save(&mut history, &input, &mut got);
            let mut want = [C32::ZERO; N];
            want.copy_from_slice(&x);
            fft.forward(&mut want);
            assert_eq!(got, want, "N={N}");
            assert_eq!(history, input, "N={N}: history not updated");
        }
        check::<2>();
        check::<8>();
        check::<64>();
        check::<1024>();
    }

    #[test]
    fn round_trip_is_identity() {
        let fft = Fft1024::new();
        let mut buf = [C32::ZERO; FFT_LEN];
        buf.copy_from_slice(&test_signal(FFT_LEN));
        let original = buf;
        fft.forward(&mut buf);
        fft.inverse(&mut buf);
        let mut max_err = 0.0f32;
        for (a, b) in buf.iter().zip(original.iter()) {
            max_err = max_err.max((*a - *b).abs());
        }
        assert!(max_err < 1e-5, "round-trip max error {max_err}");
    }

    #[test]
    fn single_bin_tone_lands_in_its_bin() {
        let fft = Fft1024::new();
        let bin = 37;
        let mut buf = [C32::ZERO; FFT_LEN];
        for (n, s) in buf.iter_mut().enumerate() {
            *s = C32::from_turns(bin as f32 * n as f32 / FFT_LEN as f32);
        }
        fft.forward(&mut buf);
        for (k, s) in buf.iter().enumerate() {
            let mag = s.abs();
            if k == bin {
                assert!((mag - FFT_LEN as f32).abs() < 1e-2, "peak bin magnitude {mag}");
            } else {
                assert!(mag < 1e-2, "leakage at bin {k}: {mag}");
            }
        }
    }

    fn check_real<const H: usize>() {
        let rfft = RealFft::<H>::new();
        let x: Vec<f32> = (0..2 * H)
            .map(|i| libm::sinf(0.013 * i as f32) + 0.2 * libm::cosf(0.41 * i as f32) + 0.05)
            .collect();
        let mut first = [0.0f32; H];
        let mut second = [0.0f32; H];
        first.copy_from_slice(&x[..H]);
        second.copy_from_slice(&x[H..]);
        let mut spec = [C32::ZERO; H];
        rfft.forward(&first, &second, &mut spec);

        let xc: Vec<C32> = x.iter().map(|&v| C32::new(v, 0.0)).collect();
        let want = dft(&xc, false);
        let peak = want.iter().map(|w| libm::sqrt(w.0 * w.0 + w.1 * w.1)).fold(1.0, f64::max);
        let tol = 4e-6 * peak;
        assert!((spec[0].re as f64 - want[0].0).abs() < tol, "H={H}: DC");
        assert!((spec[0].im as f64 - want[H].0).abs() < tol, "H={H}: Nyquist");
        for k in 1..H {
            let e = dist(spec[k], want[k]);
            assert!(e < tol, "H={H}: bin {k} error {e}");
        }

        let mut o1 = [0.0f32; H];
        let mut o2 = [0.0f32; H];
        rfft.inverse_unscaled(&mut spec, &mut o1, &mut o2);
        let scale = 1.0 / (2 * H) as f32;
        for (i, &v) in o1.iter().chain(o2.iter()).enumerate() {
            assert!((v * scale - x[i]).abs() < 1e-5, "H={H}: round trip sample {i}: {} vs {}", v * scale, x[i]);
        }
    }

    #[test]
    fn real_fft_matches_complex_dft() {
        check_real::<2>();
        check_real::<8>();
        check_real::<64>();
        check_real::<128>();
        check_real::<512>();
    }
}
