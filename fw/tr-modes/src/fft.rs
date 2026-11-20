// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! A pure-Rust FFT for `no_std` plus `alloc`, wired into mfsk-core's decode pipeline through its
//! `fft-extern` hook (`mfsk_core::engine::fft`, whose own documentation names this extension
//! point, so mfsk-core needs no patch).
//!
//! It is what makes `crate::decode` available under `no_std` at all, because mfsk-core's default
//! host backend, `rustfft`, needs `std`. See docs/S5_MODES.md "no_std FFT backend" for the
//! correctness investigation, the recall and timing numbers measured against WSJT-X samples, and
//! what was tried and did not help.
//!
//! ## Two pieces
//!
//! - `mixed_radix_transform` (via `MixedRadixFft`) is a recursive, general-radix Cooley-Tukey
//!   decomposition. It is the code path every length that FT8, FT4 and WSPR plan takes, because
//!   every one of them (512, 2304, 3200, 3840, 46080, 192000 and 1474560) factors completely into
//!   2, 3 and 5, see `SMALL_PRIMES`.
//! - `bluestein_transform` (via `BluesteinFft`) is Bluestein's algorithm (the chirp z-transform)
//!   for any length `n`, expressed with `pow2_fft_inplace` at a padded power-of-two length
//!   `m >= 2n-1`. It is a fallback for lengths with a large prime factor, which no length this
//!   crate plans has, and is kept so that an unexpected length is still handled correctly
//!   instead of panicking.
//!
//! Both are **unnormalized** in both directions, which is `rustfft`'s convention: forward and
//! inverse differ only in the sign of the exponent, with no `1/N` anywhere. mfsk-core's FT8, FT4
//! and WSPR decode math was written and tested against that convention (`fft-rustfft` was the
//! only backend at first), so matching it exactly, rather than the textbook normalized inverse,
//! is what makes this a drop-in replacement.

use alloc::boxed::Box;
use alloc::vec::Vec;
use core::f64::consts::PI;

use mfsk_core::engine::fft::{Fft, FftPlanner};
use num_complex::{Complex32, Complex64};

/// Internal working precision, `f64` and deliberately not `f32`. An all-`f32` version (sin and cos
/// recomputed and the butterflies accumulated in `f32` throughout, matching the `Complex32` of the
/// public API) passes unit tests at sizes of tens to thousands of points, but it costs real
/// WSJT-X-sample recall once it is plugged into a decode: `qso3_busy.wav` drops from 8/8 to 7/8 and
/// WSPR's `150426_0918.wav` drops from 9/9 to 7/9 (docs/S5_MODES.md "no_std FFT backend" has the
/// full account). The WSPR path plans a single Bluestein transform at `n = 1_474_560`
/// (`wspr::baseband::NFFT1`), padded to `m = 4_194_304`, so a radix-2 FFT of about 2^22 points
/// with 22 butterfly stages, and the 7 decimal digits of `f32` erode over that many stages enough
/// to push signals that are already at around -20 dB SNR below the decode threshold. The same
/// algorithm with `f64` intermediates (`Complex32` only at the public `Fft::process` boundary)
/// gives back 8/8 and 9/9, as checked by the `wsjtx_samples.rs` test file.
type C = Complex64;

/// `e^(j angle)`. The trig is two `libm` calls, which is affordable because twiddles are computed
/// once per stage or per plan and the decode loops plan once and reuse the `Fft` object.
#[inline]
fn cis(angle: f64) -> C {
    C::new(libm::cos(angle), libm::sin(angle))
}

/// Smallest power of two that is at least `n`.
fn next_pow2(n: usize) -> usize {
    let mut m = 1usize;
    while m < n {
        m <<= 1;
    }
    m
}

/// Widens a single-precision sample to the internal precision.
fn to_c(x: Complex32) -> C {
    C::new(x.re as f64, x.im as f64)
}

/// Narrows an internal value back to the single precision of the public API.
fn to_c32(x: C) -> Complex32 {
    Complex32::new(x.re as f32, x.im as f32)
}

/// In-place iterative radix-2 decimation-in-time FFT, `f64` internally (see `C` for why). The
/// length of `buf` must be a power of two (0 or 1 are no-ops). `inverse` selects only the sign of
/// the exponent (`-1` forward, `+1` inverse) and the result is **not normalized**, because the
/// module documentation explains that this has to match `rustfft`'s convention.
fn pow2_fft_inplace(buf: &mut [C], inverse: bool) {
    let n = buf.len();
    if n <= 1 {
        return;
    }
    debug_assert!(n.is_power_of_two(), "pow2_fft_inplace: {n} is not a power of two");

    // Bit-reversal permutation.
    let bits = n.trailing_zeros();
    for i in 0..n {
        let j = (i as u32).reverse_bits() >> (32 - bits);
        if j as usize > i {
            buf.swap(i, j as usize);
        }
    }

    let sign: f64 = if inverse { 1.0 } else { -1.0 };
    let mut len = 2usize;
    let mut twiddles: Vec<C> = Vec::new();
    while len <= n {
        let half = len / 2;
        // The `half` distinct twiddles of a stage depend only on `j` and not on `start`, but a
        // stage has `n/len` blocks, so computing them per block (the obvious loop nesting) would
        // repeat each `cis()` call up to `n/2` times in the smallest stages. That repetition was
        // most of this function's cost before the twiddles were hoisted, see docs/S5_MODES.md
        // "no_std FFT backend" for the timing.
        let ang_step = sign * 2.0 * PI / (len as f64);
        twiddles.clear();
        twiddles.extend((0..half).map(|j| cis(ang_step * j as f64)));
        let mut start = 0usize;
        while start < n {
            for j in 0..half {
                let w = twiddles[j];
                let u = buf[start + j];
                let v = buf[start + j + half] * w;
                buf[start + j] = u + v;
                buf[start + j + half] = u - v;
            }
            start += len;
        }
        len <<= 1;
    }
}

/// Direct backend for power-of-two lengths. It is kept only as a small independent cross-check
/// for the `p = 2` case of `mixed_radix_transform` in the tests below, because `MixedRadixFft`
/// is what gets planned in practice (see `make_fft`), so it is otherwise unused outside
/// `#[cfg(test)]`.
#[cfg_attr(not(test), allow(dead_code))]
struct Pow2Fft {
    len: usize,
    inverse: bool,
}

impl Fft for Pow2Fft {
    fn process(&self, buf: &mut [Complex32]) {
        assert_eq!(buf.len(), self.len, "Pow2Fft::process: buffer length");
        let mut work: Vec<C> = buf.iter().map(|&x| to_c(x)).collect();
        pow2_fft_inplace(&mut work, self.inverse);
        for (dst, src) in buf.iter_mut().zip(work) {
            *dst = to_c32(src);
        }
    }

    fn len(&self) -> usize {
        self.len
    }
}

/// Small primes the recursive mixed-radix decomposition splits on directly. Every FT8, FT4 and
/// WSPR FFT length in mfsk-core 0.11.0 (512, 2304, 3200, 3840, 46080, 192000 and 1474560) factors
/// completely into 2, 3 and 5. The set is a bit wider (it adds 7, 11 and 13) so that a length just
/// outside it does not need to fall all the way back to Bluestein for the sake of one extra small
/// factor.
const SMALL_PRIMES: [usize; 6] = [2, 3, 5, 7, 11, 13];

/// The smallest of `SMALL_PRIMES` that divides `n`, if any.
fn smallest_small_prime_factor(n: usize) -> Option<usize> {
    SMALL_PRIMES.into_iter().find(|&p| n % p == 0)
}

/// `true` if the prime factorization of `n` uses only `SMALL_PRIMES`, with multiplicity (so
/// `192_000 = 2^9 * 3 * 5^3` counts).
fn factors_fully_small(mut n: usize) -> bool {
    if n == 0 {
        return false;
    }
    for p in SMALL_PRIMES {
        while n % p == 0 {
            n /= p;
        }
    }
    n == 1
}

/// Direct O(p^2) DFT, used as the radix-`p` butterfly combine step in `mixed_radix_transform`
/// (`p` is always small: 2, 3, 5, 7, 11 or 13, see `SMALL_PRIMES`) and as that function's base
/// case for tiny `n`.
fn small_dft(z: &[C], sign: f64) -> Vec<C> {
    let p = z.len();
    (0..p)
        .map(|j| {
            let mut sum = C::new(0.0, 0.0);
            for (r, &zr) in z.iter().enumerate() {
                sum += zr * cis(sign * 2.0 * PI * (r * j) as f64 / p as f64);
            }
            sum
        })
        .collect()
}

/// Recursive mixed-radix Cooley-Tukey (decimation in time, general radix `p`), **unnormalized**,
/// with the same sign convention as `pow2_fft_inplace`.
///
/// The derivation, which is what justifies the butterfly shape below, splits `x[n]` by
/// `n = p*m + r` (`r = 0..p-1`, `m = 0..M-1`, `M = N/p`) into `p` subsequences of length `M`,
/// `x_r[m] = x[p*m+r]`. With `Y_r = DFT_M(x_r)` and `W_N = exp(sign*i*2*pi/N)`:
///
/// `X[k] = sum_r W_N^(r*k) * Y_r[k mod M]`
///
/// For the output index `k = k' + j*M` (`k' = 0..M-1`, `j = 0..p-1`), and because
/// `W_N^(r*j*M) = W_p^(r*j)` (since `N = p*M`), this means that for each `k'` the twiddled values
/// `Z_r = W_N^(r*k') * Y_r[k']` give `X[k'+j*M]` for `j = 0..p-1` as exactly the radix-`p` DFT of
/// `{Z_0..Z_{p-1}}` (`small_dft`). For `p = 2` this is the ordinary radix-2 butterfly.
///
/// It falls back to `bluestein_transform` once no factor in `SMALL_PRIMES` divides any further,
/// which no length this crate plans reaches (all are 5-smooth). The fallback is there so that a
/// length outside that set is still handled correctly instead of panicking or being silently
/// truncated.
fn mixed_radix_transform(x: &[C], sign: f64) -> Vec<C> {
    let n = x.len();
    if n <= 1 {
        return x.to_vec();
    }
    let Some(p) = smallest_small_prime_factor(n) else {
        if n <= 64 {
            return small_dft(x, sign);
        }
        return bluestein_transform(x, sign);
    };

    let m = n / p;
    let y: Vec<Vec<C>> = (0..p)
        .map(|r| {
            let xr: Vec<C> = (0..m).map(|k| x[p * k + r]).collect();
            mixed_radix_transform(&xr, sign)
        })
        .collect();

    let mut out = alloc::vec![C::new(0.0, 0.0); n];
    let base_ang = sign * 2.0 * PI / (n as f64);
    // One incremental step per `r`, multiplied forward as `kp` increases, instead of an
    // independent `cis()` per `(r, kp)` pair, which cuts the trig calls of this stage from `p*m`
    // to `p`. A precomputed `Vec<Vec<C>>` twiddle table one level up was tried as well and was
    // slower than plain repeated `cis()`, because the extra `Vec` allocations per recursion level
    // cost more than the trig calls they save at the small `m` of most levels. The real
    // bottleneck is the number of allocations in the recursive gather, which an iterative,
    // single-allocation planner would address, see docs/S5_MODES.md "no_std FFT backend" for the
    // numbers.
    let delta: Vec<C> = (0..p).map(|r| cis(base_ang * r as f64)).collect();
    let mut step = alloc::vec![C::new(1.0, 0.0); p];
    let mut z = alloc::vec![C::new(0.0, 0.0); p];
    for kp in 0..m {
        for r in 0..p {
            z[r] = y[r][kp] * step[r];
            step[r] *= delta[r];
        }
        let combined = small_dft(&z, sign);
        for (j, &c) in combined.iter().enumerate() {
            out[kp + j * m] = c;
        }
    }
    out
}

/// The fallback of `mixed_radix_transform` for lengths that do not factor into `SMALL_PRIMES`
/// (no length this crate plans needs it). It is the free-function form of the Bluestein algorithm
/// that `BluesteinFft` implements as a cached `Fft`, kept separate because it is called in the
/// middle of the recursion on owned `Vec`s and not planned once and reused, so caching its chirp
/// tables the way `BluesteinFft` does would buy nothing here.
fn bluestein_transform(x: &[C], sign: f64) -> Vec<C> {
    let n = x.len();
    let m = next_pow2(2 * n - 1);

    // `sign` selects forward or inverse for the outer DFT this call computes, and it is baked
    // entirely into `w` (the chirp) below. The two inner FFTs that implement the circular
    // convolution are always "forward, then inverse" whatever `sign` is, because that pair is
    // simply how a convolution is computed with an FFT (the derivation at `BluesteinFft` is the
    // same). Letting `sign` pick the inner direction would compute the wrong transform whenever
    // `sign` selects the inverse, and a forward-then-inverse round trip would still pass because
    // the two errors cancel, so the tests compare against a naive DFT in both directions.
    let w: Vec<C> = (0..n)
        .map(|i| {
            let ii = (i as u64 * i as u64) % (2 * n as u64);
            cis(sign * PI * (ii as f64) / (n as f64))
        })
        .collect();

    let mut kernel = alloc::vec![C::new(0.0, 0.0); m];
    kernel[0] = w[0].conj();
    for i in 1..n {
        let c = w[i].conj();
        kernel[i] = c;
        kernel[m - i] = c;
    }
    pow2_fft_inplace(&mut kernel, false);

    let mut a = alloc::vec![C::new(0.0, 0.0); m];
    for i in 0..n {
        a[i] = x[i] * w[i];
    }
    pow2_fft_inplace(&mut a, false);
    for i in 0..m {
        a[i] *= kernel[i];
    }
    pow2_fft_inplace(&mut a, true);

    let inv_m = 1.0 / m as f64;
    (0..n).map(|i| a[i] * inv_m * w[i]).collect()
}

/// Portable `Fft` backend for lengths that factor completely into `SMALL_PRIMES`, which is every
/// length this crate is asked to plan (see `make_fft`).
struct MixedRadixFft {
    len: usize,
    inverse: bool,
}

impl Fft for MixedRadixFft {
    fn process(&self, buf: &mut [Complex32]) {
        assert_eq!(buf.len(), self.len, "MixedRadixFft::process: buffer length");
        let sign: f64 = if self.inverse { 1.0 } else { -1.0 };
        let work: Vec<C> = buf.iter().map(|&x| to_c(x)).collect();
        let out = mixed_radix_transform(&work, sign);
        for (dst, src) in buf.iter_mut().zip(out) {
            *dst = to_c32(src);
        }
    }

    fn len(&self) -> usize {
        self.len
    }
}

/// Bluestein's algorithm (the chirp z-transform): a DFT of any length built entirely out of
/// `pow2_fft_inplace`. The chirp sequence and the FFT of the padded convolution kernel are
/// computed once at construction (once per `FftPlanner::plan_forward` or `plan_inverse` call),
/// and `process()` then costs two power-of-two FFTs of length `m` plus O(m) elementwise work.
///
/// The derivation is the standard one, restated because the sign and normalization choices are
/// what make this match `rustfft`'s unnormalized convention and not the textbook one.
///
/// `X[k] = sum_n x[n] * exp(sign*i*2*pi*k*n/N)`. Using `kn = (k^2 + n^2 - (k-n)^2) / 2`:
///
/// `X[k] = w[k] * sum_n (x[n]*w[n]) * conj(w[k-n])`, where `w[m] = exp(sign*i*pi*m^2/N)`.
///
/// That inner sum is a linear convolution of `a[n] = x[n]*w[n]` (length `N`) with `conj(w[m])` for
/// `m` in `-(N-1)..=(N-1)` (length `2N-1`, symmetric since `w` depends only on `m^2`). It is
/// computed as a circular convolution of size `m = next_pow2(2N-1)`: `a` is zero-padded to length
/// `m`, and the kernel is wrapped (`b[i] = conj(w[i])` for `i=0..N-1` and `b[m-i] = conj(w[i])`
/// for `i=1..N-1`, zero elsewhere) so that the circular wrap reproduces the negative-lag half.
/// Then `X[k] = w[k] * ifft_unnormalized(fft(a) .* fft(b))[k] / m`.
struct BluesteinFft {
    n: usize,
    m: usize,
    /// `w[i] = exp(sign*i*pi*i^2/n)` for `i=0..n`, see the derivation above. It is used both to
    /// build `a` in `process()` and for the final `w[k]` multiply.
    w: Vec<C>,
    /// `fft(b)`, length `m`, computed once so that `process()` does not repeat it on every call.
    kernel_fft: Vec<C>,
}

impl BluesteinFft {
    fn new(n: usize, inverse: bool) -> Self {
        assert!(n > 0);
        let m = next_pow2(2 * n - 1);
        let sign: f64 = if inverse { 1.0 } else { -1.0 };

        let mut w = Vec::with_capacity(n);
        for i in 0..n {
            // i*i can overflow usize (or lose precision) for large n, so it is reduced mod 2n
            // first, which is exact because exp(i*pi*m/n) has period 2n in m.
            let ii = (i as u64 * i as u64) % (2 * n as u64);
            w.push(cis(sign * PI * (ii as f64) / (n as f64)));
        }

        let mut b = alloc::vec![C::new(0.0, 0.0); m];
        b[0] = w[0].conj();
        for i in 1..n {
            let c = w[i].conj();
            b[i] = c;
            b[m - i] = c;
        }
        pow2_fft_inplace(&mut b, false);

        Self { n, m, w, kernel_fft: b }
    }
}

impl Fft for BluesteinFft {
    fn process(&self, buf: &mut [Complex32]) {
        assert_eq!(buf.len(), self.n, "BluesteinFft::process: buffer length");

        let mut a = alloc::vec![C::new(0.0, 0.0); self.m];
        for i in 0..self.n {
            a[i] = to_c(buf[i]) * self.w[i];
        }
        pow2_fft_inplace(&mut a, false);
        for i in 0..self.m {
            a[i] *= self.kernel_fft[i];
        }
        pow2_fft_inplace(&mut a, true);

        let inv_m = 1.0f64 / self.m as f64;
        for i in 0..self.n {
            buf[i] = to_c32(a[i] * inv_m * self.w[i]);
        }
    }

    fn len(&self) -> usize {
        self.n
    }
}

/// Picks the backend for `len`: mixed radix when it factors into small primes (or is trivial),
/// Bluestein otherwise.
fn make_fft(len: usize, inverse: bool) -> Box<dyn Fft> {
    if len <= 1 || factors_fully_small(len) {
        Box::new(MixedRadixFft { len, inverse })
    } else {
        Box::new(BluesteinFft::new(len, inverse))
    }
}

/// The `FftPlanner` this crate registers with mfsk-core (see `mfsk_core_make_default_fft_planner`
/// below). It does not cache plans across calls, because every FT8, FT4 and WSPR call site that
/// matters plans once and reuses the returned `Fft` object in a loop already, so a cache would add
/// complexity for no gain.
pub struct PortablePlanner;

impl PortablePlanner {
    /// A planner (it holds no state).
    pub fn new() -> Self {
        Self
    }
}

impl Default for PortablePlanner {
    fn default() -> Self {
        Self::new()
    }
}

impl FftPlanner for PortablePlanner {
    fn plan_forward(&mut self, len: usize) -> Box<dyn Fft> {
        make_fft(len, false)
    }

    fn plan_inverse(&mut self, len: usize) -> Box<dyn Fft> {
        make_fft(len, true)
    }
}

/// The symbol of mfsk-core's `fft-extern` contract (see the documentation of
/// `engine::fft::default_planner`): the crate that wants `no_std` decode defines exactly this
/// function. It is linked in wherever `tr-modes` is built with `fft-portable`. A build that also
/// enables `mfsk-core/fft-rustfft` does not use it, since rustfft wins in mfsk-core's own `#[cfg]`
/// priority, and that is not an error.
#[unsafe(no_mangle)]
pub extern "Rust" fn mfsk_core_make_default_fft_planner() -> Box<dyn FftPlanner> {
    Box::new(PortablePlanner::new())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Slow, obviously correct O(n^2) reference DFT with its own `f64` internals, independent of
    /// `pow2_fft_inplace` and `BluesteinFft`, so that both backends are checked against it and
    /// not against each other. It takes and returns `Complex32` to match the public
    /// `Fft::process` boundary that the tests exercise.
    fn naive_dft(input: &[Complex32], inverse: bool) -> Vec<Complex32> {
        let n = input.len();
        let sign: f64 = if inverse { 1.0 } else { -1.0 };
        (0..n)
            .map(|k| {
                let mut sum = C::new(0.0, 0.0);
                for (j, &x) in input.iter().enumerate() {
                    let ang = sign * 2.0 * PI * (k * j) as f64 / n as f64;
                    sum += to_c(x) * cis(ang);
                }
                to_c32(sum)
            })
            .collect()
    }

    fn close(a: &[Complex32], b: &[Complex32], tol: f32) -> bool {
        a.len() == b.len() && a.iter().zip(b).all(|(x, y)| (x - y).norm() <= tol)
    }

    #[test]
    fn pow2_forward_matches_naive_dft() {
        let input: Vec<Complex32> = (0..16).map(|i| Complex32::new((i as f32).sin(), (i as f32 * 0.3).cos())).collect();
        let got = { let mut b = input.clone(); Pow2Fft { len: 16, inverse: false }.process(&mut b); b };
        let want = naive_dft(&input, false);
        assert!(close(&got, &want, 1e-3), "{got:?} vs {want:?}");
    }

    #[test]
    fn pow2_forward_then_inverse_scales_by_n() {
        let input: Vec<Complex32> = (0..32).map(|i| Complex32::new(i as f32 - 16.0, 0.0)).collect();
        let mut buf = input.clone();
        Pow2Fft { len: 32, inverse: false }.process(&mut buf);
        Pow2Fft { len: 32, inverse: true }.process(&mut buf);
        let n = input.len() as f32;
        let want: Vec<Complex32> = input.iter().map(|&x| x * n).collect();
        assert!(close(&buf, &want, 1e-2), "{buf:?} vs {want:?}");
    }

    /// `BluesteinFft` against the naive DFT at composite (non-power-of-two) lengths, both
    /// directions.
    #[test]
    fn bluestein_matches_naive_dft_forward_and_inverse() {
        for &n in &[6usize, 15, 45, 100, 3840] {
            let input: Vec<Complex32> = (0..n).map(|i| Complex32::new((i as f32 * 0.7).sin(), (i as f32 * 1.3).cos())).collect();

            let fwd = BluesteinFft::new(n, false);
            let mut got = input.clone();
            fwd.process(&mut got);
            let want = naive_dft(&input, false);
            assert!(close(&got, &want, 5e-2), "n={n} forward: {got:?} vs {want:?}");

            let inv = BluesteinFft::new(n, true);
            let mut got_inv = input.clone();
            inv.process(&mut got_inv);
            let want_inv = naive_dft(&input, true);
            assert!(close(&got_inv, &want_inv, 5e-2), "n={n} inverse: {got_inv:?} vs {want_inv:?}");
        }
    }

    #[test]
    fn bluestein_matches_pow2_at_a_power_of_two_length() {
        // Bluestein is not used at power-of-two lengths in practice (`make_fft` routes those to
        // `MixedRadixFft`), but it must still be correct there, and this is a convenient
        // independent check of the two implementations against each other.
        let n = 64usize;
        let input: Vec<Complex32> = (0..n).map(|i| Complex32::new((i as f32 * 0.11).sin(), 0.0)).collect();
        let mut a = input.clone();
        Pow2Fft { len: n, inverse: false }.process(&mut a);
        let b = BluesteinFft::new(n, false);
        let mut got = input.clone();
        b.process(&mut got);
        assert!(close(&a, &got, 5e-2), "{a:?} vs {got:?}");
    }

    /// A pure complex exponential `x[n] = exp(i*2*pi*k0*n/N)` has an exact, closed-form forward
    /// DFT: `X[k] = N` at `k = k0` and 0 everywhere else. That is cheap to check even at large
    /// `N`, with no O(n^2) reference, which matters because the FT8, FT4 and WSPR sizes that count
    /// (192_000, 46_080 and 1_474_560 among them) are far too big for `naive_dft` in a test.
    fn assert_single_bin_impulse(n: usize, k0: usize) {
        let mut planner = PortablePlanner::new();
        let fwd = planner.plan_forward(n);
        let input: Vec<Complex32> = (0..n)
            .map(|i| {
                let ang = 2.0 * core::f64::consts::PI * (k0 as f64) * (i as f64) / (n as f64);
                to_c32(cis(ang))
            })
            .collect();
        let mut buf = input;
        fwd.process(&mut buf);

        let want_peak = n as f32;
        let got_peak = buf[k0].norm();
        assert!(
            (got_peak - want_peak).abs() <= want_peak * 1e-3,
            "n={n} k0={k0}: peak bin magnitude {got_peak} vs expected {want_peak}"
        );
        // Every other bin should be near zero. The ratio to the peak is checked and not an
        // absolute tolerance, since `n` varies so much.
        let mut max_other: f32 = 0.0;
        for (k, c) in buf.iter().enumerate() {
            if k != k0 {
                max_other = max_other.max(c.norm());
            }
        }
        assert!(
            max_other <= want_peak * 1e-3,
            "n={n} k0={k0}: largest non-peak bin {max_other} vs peak {want_peak} \
             (ratio {})",
            max_other / want_peak
        );
    }

    #[test]
    fn single_bin_impulse_at_ft8_downsample_size() {
        // ft8::downsample::FT8_CFG.fft1_size (192_000 = 2^9*3*5^3) is the largest FFT the FT8
        // decode path plans, and it is not a power of two, so this goes through the mixed-radix
        // path.
        assert_single_bin_impulse(192_000, 12345);
    }

    #[test]
    fn single_bin_impulse_at_wspr_baseband_sizes() {
        // wspr::baseband::NFFT2 = 46_080 and NFFT1 = 1_474_560 are the two sizes
        // wspr::baseband::decimate_to_baseband plans, and NFFT1 is the largest FFT anywhere in
        // this crate.
        assert_single_bin_impulse(46_080, 777);
        assert_single_bin_impulse(1_474_560, 500_000);
    }

    /// `MixedRadixFft` (via `PortablePlanner`, the code path `default_planner()` uses) against the
    /// naive O(n^2) reference DFT at composite 5-smooth lengths, which are the ones `make_fft`
    /// routes to it (`SMALL_PRIMES` lists the sizes the real FT8, FT4 and WSPR lengths come from).
    #[test]
    fn mixed_radix_matches_naive_dft_via_planner() {
        for &n in &[6usize, 12, 45, 100, 3840] {
            let input: Vec<Complex32> = (0..n).map(|i| Complex32::new((i as f32 * 0.37).sin(), (i as f32 * 0.19).cos())).collect();
            let mut planner = PortablePlanner::new();

            let fwd = planner.plan_forward(n);
            let mut got = input.clone();
            fwd.process(&mut got);
            let want = naive_dft(&input, false);
            assert!(close(&got, &want, 5e-2), "n={n} forward: {got:?} vs {want:?}");

            let inv = planner.plan_inverse(n);
            let mut got_inv = input.clone();
            inv.process(&mut got_inv);
            let want_inv = naive_dft(&input, true);
            assert!(close(&got_inv, &want_inv, 5e-2), "n={n} inverse: {got_inv:?} vs {want_inv:?}");
        }
    }

    #[test]
    fn planner_round_trip_at_ft8_spectrogram_size() {
        // NFFT_SPEC from mfsk-core's ft8 module (3840 = 2^8*3*5), a size this backend is planned
        // at during decode.
        let n = 3840usize;
        let input: Vec<Complex32> = (0..n).map(|i| Complex32::new((i as f32 * 0.01).sin(), 0.0)).collect();

        let mut planner = PortablePlanner::new();
        let fwd = planner.plan_forward(n);
        let inv = planner.plan_inverse(n);

        let mut buf = input.clone();
        fwd.process(&mut buf);
        inv.process(&mut buf);
        let scale = n as f32;
        let want: Vec<Complex32> = input.iter().map(|&x| x * scale).collect();
        assert!(close(&buf, &want, 5.0), "round trip drifted too far: max diff exceeds tolerance");
    }
}
