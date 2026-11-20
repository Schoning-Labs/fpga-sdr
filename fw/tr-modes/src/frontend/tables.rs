// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Every constant table the fabric engines hold in ROM, generated here with the pure-Rust `libm`
//! (bit-identical on every host and on the target, unlike the platform math library) and written
//! as `$readmemh` files by `ft8-frontend tables <dir>` for the RTL.
//!
//! All twiddle-like tables are 18-bit signed, scale `TW_SCALE` = 2^17 - 1 (+1.0 is not
//! representable in Q17), rounded half away from zero, and derived from a first-octant table by
//! the same symmetry the streaming FFT uses (`tools/fft_r22sdf.py` `twiddle`), so an RTL octant
//! ROM and this model agree by construction.

use alloc::vec::Vec;

/// Twiddle width (the streaming FFT uses 18-bit signed, Q17 without +1.0).
pub const TW_BITS: u32 = 18;
/// Twiddle scale, 2^17 - 1.
pub const TW_SCALE: f64 = 131_071.0;
/// cos(45 deg) at `TW_SCALE`, the value the streaming FFT uses when the reflected index lands on Np/8.
pub const K45: i32 = 92_681;

/// NCO sine/cosine table: 4,096 entries (index = top 12 bits of a 32-bit phase).
pub const NCO_BITS: u32 = 12;
/// Number of NCO table entries.
pub const NCO_LEN: usize = 1 << NCO_BITS;

/// Candidate-engine decimation FIR: 65 taps at 400 sps, symmetric (129 measured no better: 0.05 dB
/// in the AWGN sweep, one decode fewer on qso3_busy; docs/S15_FT8MODEL.md).
pub const FIR_LEN: usize = 65;
/// Kaiser window beta of the FIR.
pub const FIR_BETA: f64 = 6.0;
/// -6 dB cut-off of the FIR, Hz at 400 sps.
pub const FIR_CUTOFF_HZ: f64 = 31.25;
/// The FIR's coefficient sum is scaled so the whole pass-1 chain has a DC gain of
/// `131071 / 2^13` (about 16): CIC gain 30^4 = 810,000, then `>> 16`, then FIR `>> 20`.
pub const FIR_SUM_TARGET: f64 = (1u64 << 36) as f64 / 810_000.0;

#[inline]
fn rnd(x: f64) -> i32 {
    libm::round(x) as i32
}

/// First-octant cos/sin table for `Np` points, entries r = 0 .. Np/8 - 1 (45 deg excluded),
/// exactly `tools/fft_r22sdf.py` `octant_table` (for Np a power of two) and its extension to
/// Np = 3,840.
pub fn octant_table(np: usize) -> (Vec<i32>, Vec<i32>) {
    let n = (np / 8).max(1);
    let mut c = Vec::with_capacity(n);
    let mut s = Vec::with_capacity(n);
    for r in 0..n {
        let a = 2.0 * core::f64::consts::PI * r as f64 / np as f64;
        c.push(rnd(libm::cos(a) * TW_SCALE));
        s.push(rnd(libm::sin(a) * TW_SCALE));
    }
    (c, s)
}

/// `W_Np^e = cos(2 pi e / Np) - j sin(2 pi e / Np)` from an octant table, mapped exactly as
/// `rtl/fft/fft_twmul.v` / `tools/fft_r22sdf.py` `twiddle` do. `np` must be a multiple of 8.
/// Returns `(wr, wi)`.
pub fn twiddle(e: usize, np: usize, table: &(Vec<i32>, Vec<i32>)) -> (i32, i32) {
    let (c_t, s_t) = table;
    let e = e % np;
    let o8 = np / 8;
    let o = e / o8;
    let r = e % o8;
    let rr = if o & 1 == 1 { o8 - r } else { r };
    let (c, s) = if rr == o8 { (K45, K45) } else { (c_t[rr], s_t[rr]) };
    let (a, b) = match o {
        0 => (c, s),
        1 => (s, c),
        2 => (-s, c),
        3 => (-c, s),
        4 => (-c, -s),
        5 => (-s, -c),
        6 => (s, -c),
        _ => (c, -s),
    };
    (a, -b)
}

/// All ROM contents of the three FPGA decoder engines.
pub struct Tables {
    /// Octant tables for the 256-point FFT's twiddle stages (Np = 256, 64, 16).
    pub f1_oct: [(Vec<i32>, Vec<i32>); 3],
    /// Spectrogram combine twiddles `W_3840^e`, e = 0 .. 3,839, as (wr, wi).
    pub w3840: Vec<(i32, i32)>,
    /// Tone DFT twiddles `W_32^e`, e = 0 .. 31, as (wr, wi).
    pub w32: Vec<(i32, i32)>,
    /// NCO table: (cos, sin) of `2 pi i / 4096`, from a quarter-wave table by symmetry.
    pub nco: Vec<(i32, i32)>,
    /// Decimation FIR, quantized (18-bit signed).
    pub fir: Vec<i32>,
    /// Same FIR before quantization, at the same scale (for the float model).
    pub fir_f: Vec<f64>,
}

impl Tables {
    /// Builds every table.
    pub fn new() -> Self {
        let f1_oct = [octant_table(256), octant_table(64), octant_table(16)];
        let oct3840 = octant_table(3_840);
        let w3840 = (0..3_840).map(|e| twiddle(e, 3_840, &oct3840)).collect();
        let oct32 = octant_table(32);
        let w32 = (0..32).map(|e| twiddle(e, 32, &oct32)).collect();
        // Quarter wave: q[i] = round(sin(2 pi i / 4096) * TW_SCALE), i = 0 ..= 1024.
        let q: Vec<i32> = (0..=NCO_LEN / 4)
            .map(|i| rnd(libm::sin(2.0 * core::f64::consts::PI * i as f64 / NCO_LEN as f64) * TW_SCALE))
            .collect();
        let quarter = NCO_LEN / 4;
        let sin_of = |i: usize| -> i32 {
            let i = i % NCO_LEN;
            match i / quarter {
                0 => q[i],
                1 => q[2 * quarter - i],
                2 => -q[i - 2 * quarter],
                _ => -q[NCO_LEN - i],
            }
        };
        let nco = (0..NCO_LEN).map(|i| (sin_of(i + quarter), sin_of(i))).collect();
        let (fir, fir_f) = design_fir();
        Tables { f1_oct, w3840, w32, nco, fir, fir_f }
    }
}

impl Default for Tables {
    fn default() -> Self {
        Self::new()
    }
}

/// Zeroth-order modified Bessel function (power series; converges fast for the betas used).
fn bessel_i0(x: f64) -> f64 {
    let mut sum = 1.0;
    let mut term = 1.0;
    let y = x * x / 4.0;
    for k in 1..60 {
        term *= y / (k as f64 * k as f64);
        sum += term;
        if term < 1e-17 * sum {
            break;
        }
    }
    sum
}

/// Kaiser-windowed sinc low-pass at 400 sps; returns (quantized, unquantized) at the scale that
/// makes the coefficient sum `FIR_SUM_TARGET`.
fn design_fir() -> (Vec<i32>, Vec<f64>) {
    let m = (FIR_LEN - 1) as f64 / 2.0;
    let wc = 2.0 * core::f64::consts::PI * FIR_CUTOFF_HZ / 400.0;
    let i0b = bessel_i0(FIR_BETA);
    let raw: Vec<f64> = (0..FIR_LEN)
        .map(|i| {
            let d = i as f64 - m;
            let sinc = if d == 0.0 { wc / core::f64::consts::PI } else { libm::sin(wc * d) / (core::f64::consts::PI * d) };
            let r = d / m;
            let w = bessel_i0(FIR_BETA * libm::sqrt((1.0 - r * r).max(0.0))) / i0b;
            sinc * w
        })
        .collect();
    let sum: f64 = raw.iter().sum();
    let g = FIR_SUM_TARGET / sum;
    let fir_f: Vec<f64> = raw.iter().map(|h| h * g).collect();
    let fir: Vec<i32> = fir_f.iter().map(|&h| rnd(h)).collect();
    (fir, fir_f)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The octant tables here equal the committed RTL ROM files (written by the Python model of
    /// the streaming FFT), so the 256-point FFT in this model uses the same twiddles as `fft_r22sdf.v`.
    #[test]
    fn f1_octant_tables_match_rtl_rom_files() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../rtl/fft/tw");
        for (log_np, tab) in [(8u32, 0usize), (6, 1), (4, 2)] {
            let path = dir.join(format!("fft_tw18_l{log_np:02}.hex"));
            let text = std::fs::read_to_string(&path).expect("F1 twiddle ROM file");
            let t = Tables::new();
            let (c, s) = &t.f1_oct[tab];
            let words: Vec<u64> = text.lines().filter(|l| !l.trim().is_empty()).map(|l| u64::from_str_radix(l.trim(), 16).unwrap()).collect();
            assert_eq!(words.len(), c.len(), "{}", path.display());
            let sx = |v: u64| -> i32 { let v = (v & 0x3_ffff) as i32; if v >= 1 << 17 { v - (1 << 18) } else { v } };
            for (r, w) in words.iter().enumerate() {
                assert_eq!(sx(w >> 18), c[r], "cos l{log_np} r{r}");
                assert_eq!(sx(*w), s[r], "sin l{log_np} r{r}");
            }
        }
    }

    #[test]
    fn tables_are_sane() {
        let t = Tables::new();
        assert_eq!(t.w3840[0], (131_071, 0));
        assert_eq!(t.w3840[960], (0, -131_071));
        assert_eq!(t.w32[8], (0, -131_071));
        assert_eq!(t.nco[0], (131_071, 0));
        assert_eq!(t.nco[1024], (0, 131_071));
        for (e, &(wr, wi)) in t.w3840.iter().enumerate() {
            let a = 2.0 * core::f64::consts::PI * e as f64 / 3840.0;
            assert!((wr as f64 - a.cos() * TW_SCALE).abs() <= 1.0 && (wi as f64 + a.sin() * TW_SCALE).abs() <= 1.0);
        }
        for (i, &(c, s)) in t.nco.iter().enumerate() {
            let a = 2.0 * core::f64::consts::PI * i as f64 / 4096.0;
            assert!((c as f64 - a.cos() * TW_SCALE).abs() <= 1.0 && (s as f64 - a.sin() * TW_SCALE).abs() <= 1.0);
        }
        let sum: i64 = t.fir.iter().map(|&h| h as i64).sum();
        assert!((sum as f64 - FIR_SUM_TARGET).abs() < 70.0, "FIR sum {sum}");
        assert!(t.fir.iter().all(|&h| h.abs() < 1 << 17));
        for i in 0..FIR_LEN {
            assert_eq!(t.fir[i], t.fir[FIR_LEN - 1 - i], "FIR symmetric");
        }
    }
}
