// SPDX-License-Identifier: LGPL-2.1-only
//
// Rust translation of parts of Codec 2 release 1.2.0 (https://github.com/drowe67/codec2):
// src/newamp1.c, src/quantise.c (encode_log_Wo, decode_log_Wo, quantise), src/mbest.c.
// Copyright David Rowe 2017 (newamp1), (C) 2009-2017 David Rowe (the others). All rights reserved.
// Modified 2026 by Franz Schöning, https://www.schoning.com: translated from C to Rust.
//
// This program is free software; you can redistribute it and/or modify it under the terms of
// the GNU Lesser General Public License version 2.1, as published by the Free Software
// Foundation. This program is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE. See the GNU Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public License along with this
// program; if not, see <http://www.gnu.org/licenses/>.

//! "newamp1": the harmonic amplitudes (a variable number L per frame) are resampled to a fixed
//! K = 20 points on a mel frequency axis, the mean is removed and the rest is vector quantised in
//! two stages of 9 bits. The decoder goes back to L amplitudes and derives a minimum-phase
//! spectrum from them.

use crate::fft::Fft;
use crate::tables::{ENERGY, VQ_STAGE1, VQ_STAGE2};
use crate::{pow10f, Model, C32, MAX_AMP, WO_MAX, WO_MIN};

pub use crate::tables::K;

/// FFT size of the phase synthesis.
pub const PHASE_NFFT: usize = 128;
/// Candidates kept per stage of the encoder's vector quantiser search.
pub const MBEST_DEPTH: usize = 5;

const PI: f32 = core::f32::consts::PI;

/// Fundamental of an unvoiced frame, `2.0 * M_PI / 100.0` evaluated in double as upstream does,
/// then rounded to `f32`.
fn wo_unvoiced() -> f32 {
    (2.0 * core::f64::consts::PI / 100.0) as f32
}

/// Number of harmonics, `floorf(M_PI / Wo)` as upstream evaluates it: the quotient in double,
/// rounded to `f32`, then floored. Evaluating it in `f32` gives 50 instead of 49 for an
/// unvoiced frame, which changes the harmonic count, the spectrum and the random numbers
/// drawn for every unvoiced frame (found by comparison with the C decoder, docs/FREEDV.md).
fn harmonics(wo: f32) -> usize {
    libm::floorf((core::f64::consts::PI / wo as f64) as f32) as usize
}
/// Fs / 2000: harmonic number times Wo times this over pi is kHz.
const FS_2000: f32 = 4.0;

/// Parabolic interpolation of the points (`xp`, `yp`) at the ascending positions `x`.
pub fn interp_para(y: &mut [f32], xp: &[f32], yp: &[f32], x: &[f32]) {
    let np = xp.len();
    debug_assert!(np >= 3);
    let mut k = 0;
    for (yi, &xi) in y.iter_mut().zip(x.iter()) {
        while xp[k + 1] < xi && k < np - 3 {
            k += 1;
        }
        let (x1, y1, x2, y2, x3, y3) = (xp[k], yp[k], xp[k + 1], yp[k + 1], xp[k + 2], yp[k + 2]);
        let a = ((y3 - y2) / (x3 - x2) - (y2 - y1) / (x2 - x1)) / (x3 - x1);
        let b = ((y3 - y2) / (x3 - x2) * (x2 - x1) + (y2 - y1) / (x2 - x1) * (x3 - x2)) / (x3 - x1);
        *yi = a * (xi - x2) * (xi - x2) + b * (xi - x2) + y2;
    }
}

fn ftomel(f_hz: f32) -> f32 {
    libm::floorf(2595.0 * libm::log10f(1.0 + f_hz / 700.0) + 0.5)
}

/// The K sample frequencies, 200 to 3,700 Hz evenly spaced in mel, in kHz.
pub fn mel_sample_freqs_khz() -> [f32; K] {
    let mel_start = ftomel(200.0);
    let mel_end = ftomel(3700.0);
    let step = (mel_end - mel_start) / (K as f32 - 1.0);
    let mut out = [0.0; K];
    let mut mel = mel_start;
    for o in out.iter_mut() {
        *o = 0.7 * (pow10f(mel / 2595.0) - 1.0);
        mel += step;
    }
    out
}

/// Encoder: L amplitudes to the rate-K vector in dB.
pub fn resample_const_rate_f(model: &Model, freqs_khz: &[f32; K]) -> [f32; K] {
    let mut am_db = [0.0f32; MAX_AMP + 1];
    let mut f_l = [0.0f32; MAX_AMP + 1];
    let mut peak = -100.0f32;
    for m in 1..=model.l {
        am_db[m] = 20.0 * libm::log10f(model.a[m] + 1e-16);
        if am_db[m] > peak {
            peak = am_db[m];
        }
        f_l[m] = m as f32 * model.wo * FS_2000 / PI;
    }
    for v in am_db[1..=model.l].iter_mut() {
        if *v < peak - 50.0 {
            *v = peak - 50.0;
        }
    }
    let mut out = [0.0; K];
    interp_para(&mut out, &f_l[1..=model.l], &am_db[1..=model.l], freqs_khz);
    out
}

/// Formant emphasis on the mean-removed rate-K vector, energy kept.
pub fn post_filter(vec: &mut [f32; K], freqs_khz: &[f32; K], pf_gain: f32) {
    let mut pre = [0.0f32; K];
    let mut e_before = 0.0f32;
    let mut e_after = 0.0f32;
    for k in 0..K {
        pre[k] = 20.0 * libm::log10f(freqs_khz[k] / 0.3);
        vec[k] += pre[k];
        e_before += pow10f(vec[k] / 10.0);
        vec[k] *= pf_gain;
        e_after += pow10f(vec[k] / 10.0);
    }
    let gain_db = 10.0 * libm::log10f(e_after / e_before);
    for k in 0..K {
        vec[k] -= gain_db;
        vec[k] -= pre[k];
    }
}

/// Pitch and voicing of the four 10 ms frames between two 40 ms frames.
pub fn interp_wo_v(wo1: f32, wo2: f32, v1: bool, v2: bool) -> ([f32; 4], [usize; 4], [bool; 4]) {
    let uv = wo_unvoiced();
    let mut wo = [uv; 4];
    let mut v = [false; 4];
    match (v1, v2) {
        (false, false) => {}
        (true, false) => {
            wo[0] = wo1;
            wo[1] = wo1;
            v[0] = true;
            v[1] = true;
        }
        (false, true) => {
            wo[2] = wo2;
            wo[3] = wo2;
            v[2] = true;
            v[3] = true;
        }
        (true, true) => {
            let mut c = 1.0f32;
            for i in 0..4 {
                // upstream: float * float, plus float * double, rounded once
                wo[i] = ((wo1 * c) as f64 + wo2 as f64 * (1.0 - c as f64)) as f32;
                v[i] = true;
                c -= 0.25;
            }
        }
    }
    let mut l = [0usize; 4];
    for i in 0..4 {
        l[i] = harmonics(wo[i]).min(MAX_AMP);
    }
    (wo, l, v)
}

/// Decoder: the rate-K vector back to L amplitudes.
pub fn resample_rate_l(model: &mut Model, rate_k_vec: &[f32], freqs_khz: &[f32; K]) {
    let mut vec_term = [0.0f32; K + 2];
    let mut f_term = [0.0f32; K + 2];
    f_term[K + 1] = 4.0;
    vec_term[1..=K].copy_from_slice(&rate_k_vec[..K]);
    f_term[1..=K].copy_from_slice(freqs_khz);
    let mut f_l = [0.0f32; MAX_AMP + 1];
    for m in 1..=model.l {
        f_l[m] = m as f32 * model.wo * FS_2000 / PI;
    }
    let mut am_db = [0.0f32; MAX_AMP + 1];
    interp_para(&mut am_db[1..=model.l], &f_term, &vec_term, &f_l[1..=model.l]);
    for m in 1..=model.l {
        model.a[m] = pow10f(am_db[m] / 20.0);
    }
}

/// Minimum-phase phase spectrum (radians, `PHASE_NFFT/2 + 1` points) of a magnitude spectrum in dB.
pub fn mag_to_phase(phase: &mut [f32; PHASE_NFFT / 2 + 1], gdbfk: &[f32; PHASE_NFFT / 2 + 1], fft: &Fft<PHASE_NFFT>) {
    const NS: usize = PHASE_NFFT / 2 + 1;
    let mut c = [C32::ZERO; PHASE_NFFT];
    c[0].re = gdbfk[0];
    for i in 1..NS {
        c[i].re = gdbfk[i];
        c[PHASE_NFFT - i].re = gdbfk[i];
    }
    // real cepstrum
    fft.inverse(&mut c);
    let inv = 1.0 / PHASE_NFFT as f32;
    // fold
    let mut cf = [C32::ZERO; PHASE_NFFT];
    cf[0] = c[0].scale(inv);
    for i in 1..NS - 1 {
        cf[i] = c[i].add(c[PHASE_NFFT - i]).scale(inv);
    }
    cf[NS - 1] = c[NS - 1].scale(inv);
    fft.forward(&mut cf);
    let scale = 20.0 / libm::logf(10.0);
    for i in 0..NS {
        phase[i] = cf[i].im / scale;
    }
}

/// Phase of each harmonic from the amplitudes: `h[m] = exp(j phase(m Wo))`.
pub fn determine_phase(h: &mut [C32; MAX_AMP + 1], model: &Model, fft: &Fft<PHASE_NFFT>) {
    const NS: usize = PHASE_NFFT / 2 + 1;
    let mut am_db = [0.0f32; MAX_AMP + 1];
    let mut f_l = [0.0f32; MAX_AMP + 1];
    for m in 1..=model.l {
        am_db[m] = 20.0 * libm::log10f(model.a[m]);
        f_l[m] = m as f32 * model.wo * FS_2000 / PI;
    }
    let mut f = [0.0f32; NS];
    for (i, v) in f.iter_mut().enumerate() {
        *v = 8.0 * i as f32 / PHASE_NFFT as f32;
    }
    let mut gdbfk = [0.0f32; NS];
    interp_para(&mut gdbfk, &f_l[1..=model.l], &am_db[1..=model.l], &f);
    let mut phase = [0.0f32; NS];
    mag_to_phase(&mut phase, &gdbfk, fft);
    for m in 1..=model.l {
        let b = libm::floorf(0.5 + m as f32 * model.wo * PHASE_NFFT as f32 / (2.0 * PI)) as usize;
        let b = b.min(NS - 1);
        h[m] = C32::new(libm::cosf(phase[b]), libm::sinf(phase[b]));
    }
}

/// Pitch quantiser, 6 bits, logarithmic between the lowest and highest pitch.
pub fn encode_log_wo(wo: f32) -> usize {
    let levels = 64.0;
    let norm = (log10f_acc(wo) - log10f_acc(WO_MIN)) / (log10f_acc(WO_MAX) - log10f_acc(WO_MIN));
    let index = libm::floorf(levels * norm + 0.5);
    index.clamp(0.0, levels - 1.0) as usize
}

/// `log10f` and `exp10f` rounded correctly (computed in double), as glibc's give them. The
/// pitch goes through them and the pitch phase integrates every rounding error for as long as
/// the decoder runs; `libm`'s single-precision versions are up to 3 ulp off and showed as a
/// slowly growing phase difference against the C decoder.
fn log10f_acc(x: f32) -> f32 {
    libm::log10(x as f64) as f32
}

fn exp10f_acc(x: f32) -> f32 {
    libm::exp10(x as f64) as f32
}

pub fn decode_log_wo(index: usize) -> f32 {
    let step = (log10f_acc(WO_MAX) - log10f_acc(WO_MIN)) / 64.0;
    exp10f_acc(log10f_acc(WO_MIN) + step * index as f32)
}

/// Quantised rate-K vector (dB) of a frame's indexes.
pub fn indexes_to_rate_k_vec(indexes: &[usize; 4], freqs_khz: &[f32; K], post_filter_en: bool) -> [f32; K] {
    let n1 = indexes[0] & 511;
    let n2 = indexes[1] & 511;
    let mut v = [0.0f32; K];
    for k in 0..K {
        v[k] = VQ_STAGE1[K * n1 + k] + VQ_STAGE2[K * n2 + k];
    }
    if post_filter_en {
        post_filter(&mut v, freqs_khz, 1.5);
    }
    let mean = ENERGY[indexes[2] & 15];
    for x in v.iter_mut() {
        *x += mean;
    }
    v
}

/// The decoder: one frame's indexes to four 10 ms models and their harmonic phase filters.
#[allow(clippy::too_many_arguments)]
pub fn indexes_to_model(
    models: &mut [Model; 4],
    h: &mut [[C32; MAX_AMP + 1]; 4],
    prev_rate_k_vec: &mut [f32; K],
    wo_left: &mut f32,
    voicing_left: &mut bool,
    freqs_khz: &[f32; K],
    fft: &Fft<PHASE_NFFT>,
    indexes: &[usize; 4],
    post_filter_en: bool,
) {
    let rate_k_vec = indexes_to_rate_k_vec(indexes, freqs_khz, post_filter_en);
    let (wo_right, voicing_right) =
        if indexes[3] != 0 { (decode_log_wo(indexes[3] & 63), true) } else { (wo_unvoiced(), false) };

    // 25 Hz vectors back to 100 Hz, linearly
    let mut surface = [[0.0f32; K]; 4];
    let mut c = 1.0f32;
    for row in surface.iter_mut() {
        for k in 0..K {
            row[k] = prev_rate_k_vec[k] * c + rate_k_vec[k] * (1.0 - c);
        }
        c -= 0.25;
    }
    let (wo, l, v) = interp_wo_v(*wo_left, wo_right, *voicing_left, voicing_right);
    for i in 0..4 {
        models[i].wo = wo[i];
        models[i].l = l[i];
        models[i].voiced = v[i];
        resample_rate_l(&mut models[i], &surface[i], freqs_khz);
        determine_phase(&mut h[i], &models[i], fft);
    }
    *prev_rate_k_vec = rate_k_vec;
    *wo_left = wo_right;
    *voicing_left = voicing_right;
}

/// Sorted list of the best candidates of a search (`struct MBEST`).
#[derive(Clone, Copy)]
struct MBest {
    /// (stage-1 index that led here, index in the searched table, error)
    list: [(usize, usize, f32); MBEST_DEPTH],
}

impl MBest {
    fn new() -> Self {
        Self { list: [(0, 0, 1e32); MBEST_DEPTH] }
    }
    fn insert(&mut self, parent: usize, index: usize, error: f32) {
        for i in 0..MBEST_DEPTH {
            if error < self.list[i].2 {
                self.list.copy_within(i..MBEST_DEPTH - 1, i + 1);
                self.list[i] = (parent, index, error);
                return;
            }
        }
    }
    fn search(&mut self, cb: &[f32], vec: &[f32; K], parent: usize) {
        for (j, row) in cb.chunks_exact(K).enumerate() {
            let mut e = 0.0f32;
            for i in 0..K {
                let d = row[i] - vec[i];
                e += d * d;
            }
            if e < self.list[MBEST_DEPTH - 1].2 {
                self.insert(parent, j, e);
            }
        }
    }
}

/// Two-stage search for the mean-removed rate-K vector; returns the two indexes.
pub fn rate_k_mbest_encode(x: &[f32; K]) -> (usize, usize) {
    let mut stage1 = MBest::new();
    let mut stage2 = MBest::new();
    stage1.search(&VQ_STAGE1, x, 0);
    for j in 0..MBEST_DEPTH {
        let n1 = stage1.list[j].1;
        let mut target = [0.0f32; K];
        for i in 0..K {
            target[i] = x[i] - VQ_STAGE1[K * n1 + i];
        }
        stage2.search(&VQ_STAGE2, &target, n1);
    }
    (stage2.list[0].0, stage2.list[0].1)
}

/// The "front equaliser" before the vector quantiser (`newamp1_eq`); always tracks, only applied
/// when `eq_en`.
pub fn eq(rate_k_vec_no_mean: &mut [f32; K], eq_state: &mut [f32; K], eq_en: bool) {
    const IDEAL: [f32; K] =
        [8.0, 10.0, 12.0, 14.0, 14.0, 14.0, 14.0, 14.0, 14.0, 14.0, 14.0, 14.0, 14.0, 14.0, 14.0, 14.0, 14.0, 14.0, 14.0, -20.0];
    let gain = 0.02f32;
    for k in 0..K {
        let update = rate_k_vec_no_mean[k] - IDEAL[k];
        eq_state[k] = (1.0 - gain) * eq_state[k] + gain * update;
        if eq_state[k] < 0.0 {
            eq_state[k] = 0.0;
        }
        if eq_en {
            rate_k_vec_no_mean[k] -= eq_state[k];
        }
    }
}

/// The encoder: the model of the last of four 10 ms frames to the frame's indexes.
pub fn model_to_indexes(model: &Model, freqs_khz: &[f32; K], eq_state: &mut [f32; K], eq_en: bool) -> [usize; 4] {
    let rate_k_vec = resample_const_rate_f(model, freqs_khz);
    let mean = rate_k_vec.iter().sum::<f32>() / K as f32;
    let mut no_mean = [0.0f32; K];
    for k in 0..K {
        no_mean[k] = rate_k_vec[k] - mean;
    }
    eq(&mut no_mean, eq_state, eq_en);
    let (n1, n2) = rate_k_mbest_encode(&no_mean);
    // scalar quantiser of the mean
    let mut besti = 0;
    let mut beste = 1e32f32;
    for (j, &c) in ENERGY.iter().enumerate() {
        let d = c - mean;
        if d * d < beste {
            beste = d * d;
            besti = j;
        }
    }
    // the lowest pitch index signals an unvoiced frame
    let wo_index = if model.voiced { encode_log_wo(model.wo).max(1) } else { 0 };
    [n1, n2, besti, wo_index]
}
