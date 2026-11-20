// SPDX-License-Identifier: LGPL-2.1-only
// Copyright 2026 Franz Schöning, https://www.schoning.com
// (own code, not a translation; under the crate's licence so the crate has one licence)

//! Small in-place radix-2 complex FFT in `f32`, no heap. Sign and scaling follow kiss_fft as
//! Codec 2 uses it: `forward` is exp(-j...), `inverse` is exp(+j...), neither scales.

use crate::C32;

/// FFT of length `N` (a power of two). The table is built once in [`Fft::new`].
pub struct Fft<const N: usize> {
    /// `tw[k] = exp(-j 2 pi k / N)` for `k < N/2` (the upper half is unused).
    tw: [C32; N],
}

impl<const N: usize> Default for Fft<N> {
    fn default() -> Self {
        Self::new()
    }
}

impl<const N: usize> Fft<N> {
    pub fn new() -> Self {
        let mut slot = core::mem::MaybeUninit::<Self>::uninit();
        Self::init(&mut slot);
        // SAFETY: `init` wrote every field.
        unsafe { slot.assume_init() }
    }

    /// Builds the table in `slot` itself, without a copy through the stack.
    pub fn init(slot: &mut core::mem::MaybeUninit<Self>) -> &mut Self {
        assert!(N.is_power_of_two() && N >= 4);
        let tw = slot.as_mut_ptr() as *mut C32;
        for k in 0..N {
            let c = if k < N / 2 {
                let a = -2.0 * core::f64::consts::PI * k as f64 / N as f64;
                C32::new(libm::cos(a) as f32, libm::sin(a) as f32)
            } else {
                C32::ZERO
            };
            // SAFETY: `tw` points at the N elements of the array that is the struct's only field.
            unsafe { tw.add(k).write(c) };
        }
        // SAFETY: all N elements are written.
        unsafe { slot.assume_init_mut() }
    }

    /// exp(-j 2 pi k n / N), not scaled.
    pub fn forward(&self, x: &mut [C32; N]) {
        self.run(x, false);
    }

    /// exp(+j 2 pi k n / N), not scaled.
    pub fn inverse(&self, x: &mut [C32; N]) {
        self.run(x, true);
    }

    fn run(&self, x: &mut [C32; N], inverse: bool) {
        // bit reversal
        let bits = N.trailing_zeros();
        for i in 0..N {
            let j = (i as u32).reverse_bits() >> (32 - bits);
            let j = j as usize;
            if j > i {
                x.swap(i, j);
            }
        }
        let mut len = 2;
        while len <= N {
            let half = len / 2;
            let step = N / len;
            let mut start = 0;
            while start < N {
                for k in 0..half {
                    let mut w = self.tw[k * step];
                    if inverse {
                        w.im = -w.im;
                    }
                    let a = x[start + k];
                    let b = x[start + k + half];
                    let t = C32::new(b.re * w.re - b.im * w.im, b.re * w.im + b.im * w.re);
                    x[start + k] = C32::new(a.re + t.re, a.im + t.im);
                    x[start + k + half] = C32::new(a.re - t.re, a.im - t.im);
                }
                start += len;
            }
            len *= 2;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_direct_dft() {
        let f = Fft::<64>::new();
        let mut x = [C32::ZERO; 64];
        for (i, v) in x.iter_mut().enumerate() {
            *v = C32::new(libm::sinf(0.3 * i as f32) + 0.1 * i as f32, libm::cosf(1.1 * i as f32));
        }
        let orig = x;
        f.forward(&mut x);
        for k in [0usize, 1, 7, 31, 63] {
            let mut s = (0.0f64, 0.0f64);
            for (n, v) in orig.iter().enumerate() {
                let a = -2.0 * core::f64::consts::PI * (k * n) as f64 / 64.0;
                s.0 += v.re as f64 * libm::cos(a) - v.im as f64 * libm::sin(a);
                s.1 += v.re as f64 * libm::sin(a) + v.im as f64 * libm::cos(a);
            }
            assert!((x[k].re as f64 - s.0).abs() < 1e-3 && (x[k].im as f64 - s.1).abs() < 1e-3);
        }
        f.inverse(&mut x);
        for (a, b) in x.iter().zip(orig.iter()) {
            assert!((a.re / 64.0 - b.re).abs() < 1e-4 && (a.im / 64.0 - b.im).abs() < 1e-4);
        }
    }
}
