// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! CPU side: subtracts a decoded FT8 signal from the slot audio, so that weaker signals hidden
//! under it can be found in a second pass. It does the job of WSJT-X's `subtractft8` with a
//! much cheaper method (the waveform shape, the 79 tones, the GFSK pulse and the ramps are the
//! same as WSJT-X's `gen_ft8wave`).
//!
//! The reference is the transmitted waveform itself: the decoded message's 79 tones, GFSK
//! (BT = 2, the WSJT-X pulse) with the half-cosine ramps, unit amplitude, starting at the
//! decode's time with a sub-sample dt from the fine sync. The unknown complex amplitude (level,
//! phase, slow fading, the last fraction of a hertz of frequency error) is `x * conj(ref)`
//! low-pass filtered; WSJT-X filters with a 4,001-sample cos^2 window through two 180,000-point
//! FFTs per signal. Here the product is summed in 5 ms blocks (60 samples, nulls at multiples
//! of 200 Hz, so the 2 f term and other stations drop out), the block sums are smoothed by a
//! triangle of +/-33 blocks (two cascaded 33-block running sums, about the same 0.33 s span),
//! normalized by the same filter run over the block weights (so the ends of the slot are
//! handled), and interpolated linearly back to every sample. Then `x -= 2 Re(a * ref)`.
//!
//! Cost is linear in the signal length: two passes over its 151,680 samples.

use alloc::boxed::Box;
use alloc::vec;
use alloc::vec::Vec;

use mfsk_core::ft8::wave_gen::message_to_tones;

use super::{FS, NN, NSPS, TONE_HZ};

/// Samples per amplitude block (5 ms at 12 ksps).
const BLOCK: usize = 60;
/// Length of each of the two running sums that make the smoothing triangle, in blocks.
const TRI: usize = 33;
/// Length of the ramp at each end of the waveform, samples (an eighth of a symbol).
const RAMP: usize = NSPS / 8;
/// Index width of the sine/cosine lookup table.
const LUT_BITS: u32 = 12;

/// Reconstructs decoded FT8 signals and subtracts them from the audio. Holds the tables and a
/// scratch buffer, so one instance is reused for every signal of a slot.
pub struct Subtractor {
    /// GFSK frequency pulse over three symbols (5,760 samples), in NCO increment units per tone
    /// step (6.25 Hz = 2,236,962.1 per sample at 2^32 per cycle).
    pulse: Vec<i32>,
    /// e^(j 2 pi i / 4096).
    lut: Box<[(f32, f32); 1 << LUT_BITS]>,
    /// Half-cosine ramp over 240 samples (rising).
    ramp: Vec<f32>,
    /// Scratch for the reference waveform of the signal being subtracted (79 x 1,920 samples).
    rref: Vec<(f32, f32)>,
}

impl Default for Subtractor {
    fn default() -> Self {
        Self::new()
    }
}

impl Subtractor {
    /// Builds the pulse, sine and ramp tables.
    pub fn new() -> Self {
        let bt = 2.0f64;
        let c = core::f64::consts::PI * libm::sqrt(2.0 / core::f64::consts::LN_2);
        let per_tone = TONE_HZ as f64 * 4_294_967_296.0 / FS as f64;
        let pulse = (0..3 * NSPS)
            .map(|i| {
                let t = (i as f64 - 1.5 * NSPS as f64) / NSPS as f64;
                let p = 0.5 * (libm::erf(c * bt * (t + 0.5)) - libm::erf(c * bt * (t - 0.5)));
                libm::round(p * per_tone) as i32
            })
            .collect();
        let lut = Box::new(core::array::from_fn(|i| {
            let (s, c) = libm::sincos(2.0 * core::f64::consts::PI * i as f64 / (1u64 << LUT_BITS) as f64);
            (c as f32, s as f32)
        }));
        let ramp = (0..RAMP)
            .map(|i| ((1.0 - libm::cos(2.0 * core::f64::consts::PI * i as f64 / (2.0 * RAMP as f64))) / 2.0) as f32)
            .collect();
        Subtractor { pulse, lut, ramp, rref: Vec::new() }
    }

    /// Removes the signal `msg77` at tone-0 frequency `f0` Hz and time `dt` (seconds after the
    /// nominal 0.5 s start) from `audio` in place. Does nothing if the signal lies wholly outside
    /// the audio.
    pub fn subtract(&mut self, audio: &mut [i16], msg77: &[u8], f0: f32, dt: f32) {
        let tones = message_to_tones(msg77);
        let nwave = NN * NSPS;
        let start = libm::round((dt as f64 + 0.5) * FS as f64) as i64;
        // Samples k of the waveform that fall inside the audio.
        let k_lo = (-start).clamp(0, nwave as i64) as usize;
        let k_hi = (audio.len() as i64 - start).clamp(0, nwave as i64) as usize;
        if k_lo >= k_hi {
            return;
        }

        // Pass A1: the unit-amplitude GFSK reference. Phase in a 32-bit accumulator; the
        // instantaneous frequency is f0 plus the tone offset through the pulse, with symbol s's
        // two neighbours (the virtual symbols before the first and after the last repeat the end
        // tones, as WSJT-X's gen_ft8wave).
        self.rref.resize(nwave, (0.0, 0.0));
        let base = libm::round(f0 as f64 * 4_294_967_296.0 / FS as f64) as i64 as u32;
        let (p_next, rest) = self.pulse.split_at(NSPS);
        let (p_cur, p_prev) = rest.split_at(NSPS);
        let lut = &*self.lut;
        let mut phase: u32 = 0;
        for s in 0..NN {
            let tp = tones[s.saturating_sub(1)] as i32;
            let tc = tones[s] as i32;
            let tn = tones[(s + 1).min(NN - 1)] as i32;
            let out = &mut self.rref[s * NSPS..(s + 1) * NSPS];
            for (((r, &a), &b), &c) in out.iter_mut().zip(p_prev).zip(p_cur).zip(p_next) {
                *r = lut[(phase >> (32 - LUT_BITS)) as usize];
                phase = phase.wrapping_add(base.wrapping_add((tp * a + tc * b + tn * c) as u32));
            }
        }
        for i in 0..RAMP {
            let e = self.ramp[i];
            let a = &mut self.rref[i];
            *a = (a.0 * e, a.1 * e);
            let b = &mut self.rref[nwave - 1 - i];
            *b = (b.0 * e, b.1 * e);
        }

        // Pass A2: x * conj(ref), summed per 60-sample block (blocks are aligned to the
        // waveform, 32 per symbol), with the number of samples that fell inside the audio.
        let nb = nwave / BLOCK;
        let mut re = vec![0f32; nb];
        let mut im = vec![0f32; nb];
        let mut bw = vec![0f32; nb];
        for b in k_lo / BLOCK..k_hi.div_ceil(BLOCK) {
            let (lo, hi) = ((b * BLOCK).max(k_lo), ((b + 1) * BLOCK).min(k_hi));
            let (mut ar, mut ai) = (0f32, 0f32);
            let x = &audio[(start + lo as i64) as usize..(start + hi as i64) as usize];
            for (&xv, r) in x.iter().zip(&self.rref[lo..hi]) {
                let xv = xv as f32;
                ar += xv * r.0;
                ai -= xv * r.1;
            }
            re[b] = ar;
            im[b] = ai;
            bw[b] = (hi - lo) as f32;
        }

        // Pass B: triangle smoothing of the block sums and of the weights, centered.
        let (sr, si, sw) = (smooth(&re), smooth(&im), smooth(&bw));
        let amp: Vec<(f32, f32)> = (0..nb).map(|b| if sw[b] > 0.5 { (sr[b] / sw[b], si[b] / sw[b]) } else { (0.0, 0.0) }).collect();

        // Pass C: amplitude linear between block centers (k = 60 b + 29.5), constant beyond the
        // first and last center; subtract 2 Re(a ref), round half up, clamp.
        let half = BLOCK / 2; // the first sample after center b is 60 b + 30
        let step = 1.0 / BLOCK as f32;
        let last = (nb - 1) * BLOCK + half;
        let mut k = k_lo;
        while k < k_hi {
            // Segment [seg_lo, seg_end): before the first center, after the last, or between
            // centers b and b + 1, where a(k) = amp[b] + (k - seg_lo + 0.5) / 60 (amp[b+1] - amp[b]).
            let (seg_lo, seg_end, a0, da) = if k < half {
                (0, half, amp[0], (0.0, 0.0))
            } else if k >= last {
                (last, nwave, amp[nb - 1], (0.0, 0.0))
            } else {
                let b = (k - half) / BLOCK;
                let d = ((amp[b + 1].0 - amp[b].0) * step, (amp[b + 1].1 - amp[b].1) * step);
                (b * BLOCK + half, b * BLOCK + half + BLOCK, amp[b], d)
            };
            let seg_start = seg_lo;
            let hi = seg_end.min(k_hi);
            // Position of sample k inside its segment, +0.5 for the half-sample center offset.
            let mut a = (a0.0 + da.0 * ((k - seg_start) as f32 + 0.5), a0.1 + da.1 * ((k - seg_start) as f32 + 0.5));
            let x = &mut audio[(start + k as i64) as usize..(start + hi as i64) as usize];
            for (xv, r) in x.iter_mut().zip(&self.rref[k..hi]) {
                let v = (*xv as f32 - 2.0 * (a.0 * r.0 - a.1 * r.1)).max(-32_768.0).min(32_767.0);
                // v + 32768.5 is in [0.5, 65535.5]: truncation is round half up, and the cast
                // cannot overflow.
                *xv = (unsafe { (v + 32_768.5).to_int_unchecked::<i32>() } - 32_768) as i16;
                a.0 += da.0;
                a.1 += da.1;
            }
            k = hi;
        }
    }
}

/// Two cascaded running sums of `TRI` blocks, centered: a triangle of +/-(TRI - 1) blocks.
fn smooth(v: &[f32]) -> Vec<f32> {
    let h = TRI / 2;
    let run = |a: &[f32]| -> Vec<f32> {
        let mut out = vec![0f32; a.len()];
        let mut acc = 0f32;
        for i in 0..a.len() + h {
            if i < a.len() {
                acc += a[i];
            }
            if i >= TRI {
                acc -= a[i - TRI];
            }
            if i >= h {
                out[i - h] = acc;
            }
        }
        out
    };
    run(&run(v))
}

#[cfg(all(test, feature = "std"))]
mod tests {
    use super::*;
    use mfsk_core::ft8::wave_gen::{message_to_tones, tones_to_f32};
    use mfsk_core::msg::wsjt77::pack77;

    /// A clean signal with an off-grid dt and a fractional frequency is removed to well below
    /// its own level.
    #[test]
    fn removes_a_clean_signal() {
        let msg = pack77("CQ", "JA1ABC", "PM95").unwrap();
        let tones = message_to_tones(&msg);
        let f0 = 1_234.3f32;
        let pcm = tones_to_f32(&tones, f0, 8_000.0);
        let mut audio = vec![0i16; 180_000];
        let start = 6_000 + 137;
        for (i, &v) in pcm.iter().enumerate() {
            if start + i < audio.len() {
                audio[start + i] = v.round() as i16;
            }
        }
        let p0: f64 = audio.iter().map(|&v| (v as f64).powi(2)).sum();
        let dt = start as f32 / 12_000.0 - 0.5;
        let mut s = Subtractor::new();
        s.subtract(&mut audio, &msg, f0 + 0.2, dt);
        let p1: f64 = audio.iter().map(|&v| (v as f64).powi(2)).sum();
        let db = 10.0 * (p1 / p0).log10();
        eprintln!("subtraction residual {db:.1} dB");
        assert!(db < -25.0, "residual {db:.1} dB");
    }
}
