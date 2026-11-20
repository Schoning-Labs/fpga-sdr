// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The streaming FFT of the FPGA (`rtl/fft/fft_r22sdf.v`, radix-2^2 single-path delay feedback,
//! docs/F1_FFT.md) at `LOG_N = 8`, complex input, as a bit-true block model: a line-for-line port
//! of `tools/fft_r22sdf.py` `model()`, which is itself bit-exact with the RTL.
//!
//! Butterflies are full precision (one bit of growth per radix-2 stage, 16-bit input becomes
//! 24-bit output); the only rounding is after each twiddle multiply (stages Np = 256, 64, 16):
//! `(p + 2^16) >> 17`, then saturation to the stage width. The output is the unscaled DFT
//! `sum x[n] e^(-j 2 pi k n / 256)`, returned here in natural bin order (the RTL emits it in
//! bit-reversed order, and the spectrogram engine addresses its accumulator by `out_bin`, so order
//! does not matter there).

use super::tables::{twiddle, Tables, TW_BITS};

/// log2 of the transform length.
pub const LOG_N: u32 = 8;
/// Transform length, 256 points.
pub const N: usize = 1 << LOG_N;
/// Input width (i16 audio) and output width (input + LOG_N).
pub const IW: u32 = 16;
/// Output width: one bit of growth per radix-2 stage.
pub const OW: u32 = IW + LOG_N;

/// Saturates `v` to a signed `w`-bit value.
#[inline]
fn sat(v: i64, w: u32) -> i64 {
    let hi = (1i64 << (w - 1)) - 1;
    let lo = -(1i64 << (w - 1));
    v.clamp(lo, hi)
}

/// Debug-build check that `v` fits a signed `w`-bit stage register.
#[inline]
fn check(v: i64, w: u32) {
    debug_assert!(v >= -(1i64 << (w - 1)) && v < (1i64 << (w - 1)), "F1 FFT stage overflow: {v} in {w} bits");
}

/// 256-point forward FFT, bit-exact with `fft_r22sdf.v` (`LOG_N = 8`, `IW = 16`,
/// `REAL_IN = 0`). `re`/`im` hold the input (each within 16 bits) and are replaced by the output
/// in natural bin order (each within 24 bits).
pub fn fft256(t: &Tables, re: &mut [i64; N], im: &mut [i64; N]) {
    let mut w = IW;
    let mut log_np = LOG_N;
    loop {
        let np = 1usize << log_np;
        let blocks = N / np;
        // BF2I, L = Np/2.
        for b in 0..blocks {
            let base = b * np;
            for i in 0..np / 2 {
                let (a, c) = (base + i, base + i + np / 2);
                let (ar, ai, br, bi) = (re[a], im[a], re[c], im[c]);
                re[a] = ar + br;
                im[a] = ai + bi;
                re[c] = ar - br;
                im[c] = ai - bi;
            }
        }
        w += 1;
        if log_np == 1 {
            break;
        }
        // BF2II, L = Np/4, the 4th quarter multiplied by -j first.
        let q = np / 4;
        for b in 0..blocks {
            let base = b * np;
            for i in 0..q {
                let p3 = base + 3 * q + i;
                let (br, bi) = (re[p3], im[p3]);
                re[p3] = bi;
                im[p3] = -br;
            }
            for h in [0usize, 2] {
                for i in 0..q {
                    let (a, c) = (base + h * q + i, base + (h + 1) * q + i);
                    let (ar, ai, br, bi) = (re[a], im[a], re[c], im[c]);
                    re[a] = ar + br;
                    im[a] = ai + bi;
                    re[c] = ar - br;
                    im[c] = ai - bi;
                }
            }
        }
        w += 1;
        if cfg!(debug_assertions) {
            for i in 0..N {
                check(re[i], w);
                check(im[i], w);
            }
        }
        // Twiddle W_Np^(n3 (k1 + 2 k2)), position q = k1 Np/2 + k2 Np/4 + n3.
        if log_np >= 3 {
            let tab = &t.f1_oct[((LOG_N - log_np) / 2) as usize];
            let half = 1i64 << (TW_BITS - 2);
            for b in 0..blocks {
                let base = b * np;
                for pos in 0..np {
                    let k1 = (pos >> (log_np - 1)) & 1;
                    let k2 = (pos >> (log_np - 2)) & 1;
                    let n3 = pos & (np / 4 - 1);
                    // e = 0 gives W = (131071, 0); the RTL multiplies by it like any other.
                    let e = n3 * (k1 + 2 * k2);
                    let (wr, wi) = twiddle(e, np, tab);
                    let (wr, wi) = (wr as i64, wi as i64);
                    let i = base + pos;
                    let pr = re[i] * wr - im[i] * wi;
                    let pi = re[i] * wi + im[i] * wr;
                    re[i] = sat((pr + half) >> (TW_BITS - 1), w);
                    im[i] = sat((pi + half) >> (TW_BITS - 1), w);
                }
            }
        }
        log_np -= 2;
        if log_np == 0 {
            break;
        }
    }
    // Output position t holds bin bitrev(t); reorder to natural order.
    let mut out_r = [0i64; N];
    let mut out_i = [0i64; N];
    for pos in 0..N {
        let k = (pos as u32).reverse_bits() >> (32 - LOG_N);
        out_r[k as usize] = re[pos];
        out_i[k as usize] = im[pos];
    }
    *re = out_r;
    *im = out_i;
}

/// The same transform in `f64` (plain radix-2, nothing rounded) for the float model.
pub fn fft256_f64(re: &mut [f64; N], im: &mut [f64; N]) {
    // Bit reversal.
    for i in 0..N {
        let j = ((i as u32).reverse_bits() >> (32 - LOG_N)) as usize;
        if j > i {
            re.swap(i, j);
            im.swap(i, j);
        }
    }
    let tw = f64_twiddles();
    let mut len = 2;
    while len <= N {
        let stride = N / len;
        for start in (0..N).step_by(len) {
            for k in 0..len / 2 {
                let (c, s) = tw[k * stride];
                let a = start + k;
                let b = a + len / 2;
                let tr = re[b] * c - im[b] * s;
                let ti = re[b] * s + im[b] * c;
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] += tr;
                im[a] += ti;
            }
        }
        len <<= 1;
    }
}

/// `e^(-j 2 pi k / 256)` as (cos, -sin), k = 0 .. 127, computed once.
fn f64_twiddles() -> &'static [(f64, f64); N / 2] {
    static TW: spin_once::Once<[(f64, f64); N / 2]> = spin_once::Once::new();
    TW.get_or_init(|| {
        core::array::from_fn(|k| {
            let (s, c) = libm::sincos(-2.0 * core::f64::consts::PI * k as f64 / N as f64);
            (c, s)
        })
    })
}

/// A minimal `no_std` once-cell (the float models are host tools, but the crate is `no_std`).
mod spin_once {
    use core::cell::UnsafeCell;
    use core::sync::atomic::{AtomicU8, Ordering};

    pub struct Once<T> {
        state: AtomicU8,
        value: UnsafeCell<Option<T>>,
    }
    unsafe impl<T: Send + Sync> Sync for Once<T> {}
    impl<T> Once<T> {
        pub const fn new() -> Self {
            Once { state: AtomicU8::new(0), value: UnsafeCell::new(None) }
        }
        pub fn get_or_init(&self, f: impl FnOnce() -> T) -> &T {
            loop {
                match self.state.compare_exchange(0, 1, Ordering::Acquire, Ordering::Acquire) {
                    Ok(_) => {
                        unsafe { *self.value.get() = Some(f()) };
                        self.state.store(2, Ordering::Release);
                    }
                    Err(2) => {}
                    Err(_) => {
                        core::hint::spin_loop();
                        continue;
                    }
                }
                return unsafe { (*self.value.get()).as_ref().unwrap() };
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lcg(state: &mut u64) -> i64 {
        *state = state.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        ((*state >> 33) as i64 % 65_536) - 32_768
    }

    /// Against a double-precision DFT: the fixed-point error stays tiny (three rounded twiddle
    /// stages) and full-scale input does not overflow.
    #[test]
    fn matches_float_dft() {
        let t = Tables::new();
        let mut st = 1u64;
        for trial in 0..4 {
            let mut re = [0i64; N];
            let mut im = [0i64; N];
            for i in 0..N {
                re[i] = if trial == 3 { 32_767 } else { lcg(&mut st) };
                im[i] = if trial >= 2 { 0 } else { lcg(&mut st) };
            }
            let mut fr = [0f64; N];
            let mut fi = [0f64; N];
            for i in 0..N {
                fr[i] = re[i] as f64;
                fi[i] = im[i] as f64;
            }
            fft256(&t, &mut re, &mut im);
            fft256_f64(&mut fr, &mut fi);
            let mut max_err: f64 = 0.0;
            for k in 0..N {
                // The fixed-point twiddles are (2^17 - 1)/2^17 of unity in three stages.
                let g = (131_071.0f64 / 131_072.0).powi(3);
                max_err = max_err.max((re[k] as f64 - fr[k] * g).abs()).max((im[k] as f64 - fi[k] * g).abs());
                assert!(re[k].abs() < 1 << 23 && im[k].abs() < 1 << 23);
            }
            assert!(max_err < 16.0, "trial {trial}: max error {max_err}");
        }
    }

    /// Bit-exact against the Python model of the streaming FFT: vector written by
    /// `python tools/fft_r22sdf.py`'s `model()` for LOG_N = 8, IW = 16 (see
    /// `tools/gen_s15_fft256_vector.py`).
    #[test]
    fn bit_exact_with_f1_python_model() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/data/s15_fft256_vector.txt");
        let text = std::fs::read_to_string(&path).expect("vector file");
        let t = Tables::new();
        let mut lines = text.lines().filter(|l| !l.starts_with('#'));
        let n_frames: usize = lines.next().unwrap().trim().parse().unwrap();
        for _ in 0..n_frames {
            let mut re = [0i64; N];
            let mut im = [0i64; N];
            let mut exp_r = [0i64; N];
            let mut exp_i = [0i64; N];
            for k in 0..N {
                let v: Vec<i64> = lines.next().unwrap().split_whitespace().map(|x| x.parse().unwrap()).collect();
                re[k] = v[0];
                im[k] = v[1];
                exp_r[k] = v[2];
                exp_i[k] = v[3];
            }
            fft256(&t, &mut re, &mut im);
            assert_eq!(re, exp_r);
            assert_eq!(im, exp_i);
        }
    }
}
