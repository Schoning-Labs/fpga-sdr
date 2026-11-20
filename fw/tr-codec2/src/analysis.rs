// SPDX-License-Identifier: LGPL-2.1-only
//
// Rust translation of parts of Codec 2 release 1.2.0 (https://github.com/drowe67/codec2):
// src/sine.c (make_analysis_window, dft_speech, two_stage_pitch_refinement,
// hs_pitch_refinement, estimate_amplitudes, est_voicing_mbe).
// Copyright (C) 1990-2010 David Rowe. All rights reserved.
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

//! The encoder's sinusoidal analysis: windowed spectrum, pitch refinement, harmonic amplitudes
//! and the voicing decision.

use crate::fft::Fft;
use crate::{Model, C32, FFT_ENC, M_PITCH, NW, PI, P_MAX, P_MIN, TWO_PI};

const V_THRESH: f32 = 6.0;

/// Analysis window `w` (Hann, 279 samples, centred in the 320-sample buffer, scaled for unit
/// energy through the FFT) and its DFT `w_dft` with the main lobe at `FFT_ENC / 2`.
pub fn make_analysis_window(fft: &Fft<FFT_ENC>, w: &mut [f32; M_PITCH], w_dft: &mut [f32; FFT_ENC]) {
    let mut m = 0.0f32;
    w.fill(0.0);
    for (j, i) in (M_PITCH / 2 - NW / 2..M_PITCH / 2 + NW / 2).enumerate() {
        w[i] = 0.5 - 0.5 * libm::cosf(TWO_PI * j as f32 / (NW as f32 - 1.0));
        m += w[i] * w[i];
    }
    let m = 1.0 / libm::sqrtf(m * FFT_ENC as f32);
    for v in w.iter_mut() {
        *v *= m;
    }
    let mut t = [C32::ZERO; FFT_ENC];
    for i in 0..NW / 2 {
        t[i].re = w[i + M_PITCH / 2];
    }
    for (j, i) in (FFT_ENC - NW / 2..FFT_ENC).enumerate() {
        t[i].re = w[M_PITCH / 2 - NW / 2 + j];
    }
    fft.forward(&mut t);
    for i in 0..FFT_ENC / 2 {
        w_dft[i] = t[i + FFT_ENC / 2].re;
        w_dft[i + FFT_ENC / 2] = t[i].re;
    }
}

/// DFT of the windowed speech buffer, centred so the phases are right.
pub fn dft_speech(fft: &Fft<FFT_ENC>, sw: &mut [C32; FFT_ENC], sn: &[f32; M_PITCH], w: &[f32; M_PITCH]) {
    sw.fill(C32::ZERO);
    for i in 0..NW / 2 {
        sw[i].re = sn[i + M_PITCH / 2] * w[i + M_PITCH / 2];
    }
    for i in 0..NW / 2 {
        sw[FFT_ENC - NW / 2 + i].re = sn[i + M_PITCH / 2 - NW / 2] * w[i + M_PITCH / 2 - NW / 2];
    }
    fft.forward(sw);
}

fn hs_pitch_refinement(model: &mut Model, sw: &[C32; FFT_ENC], pmin: f32, pmax: f32, pstep: f32) {
    model.l = (PI / model.wo) as usize;
    let mut wom = model.wo;
    let mut em = 0.0f32;
    let one_on_r = 1.0 / (TWO_PI / FFT_ENC as f32);
    let mut p = pmin;
    while p <= pmax {
        let wo = TWO_PI / p;
        let b_float = wo * one_on_r;
        let mut cur = b_float;
        let mut e = 0.0f32;
        for _ in 1..=model.l {
            let b = ((cur + 0.5) as usize).min(FFT_ENC - 1);
            e += sw[b].norm_sqr();
            cur += b_float;
        }
        if e > em {
            em = e;
            wom = wo;
        }
        p += pstep;
    }
    model.wo = wom;
}

/// Harmonic-sum pitch refinement, coarse then fine, and the harmonic count.
pub fn two_stage_pitch_refinement(model: &mut Model, sw: &[C32; FFT_ENC]) {
    let p = TWO_PI / model.wo;
    hs_pitch_refinement(model, sw, p - 5.0, p + 5.0, 1.0);
    let p = TWO_PI / model.wo;
    hs_pitch_refinement(model, sw, p - 1.0, p + 1.0, 0.25);
    if model.wo < TWO_PI / P_MAX as f32 {
        model.wo = TWO_PI / P_MAX as f32;
    }
    if model.wo > TWO_PI / P_MIN as f32 {
        model.wo = TWO_PI / P_MIN as f32;
    }
    model.l = libm::floorf(PI / model.wo) as usize;
    if model.wo * model.l as f32 >= 0.95 * PI {
        model.l -= 1;
    }
}

/// Amplitude of each harmonic: root of the energy in its band.
pub fn estimate_amplitudes(model: &mut Model, sw: &[C32; FFT_ENC]) {
    let one_on_r = 1.0 / (TWO_PI / FFT_ENC as f32);
    for m in 1..=model.l {
        let am = ((m as f32 - 0.5) * model.wo * one_on_r + 0.5) as usize;
        let bm = ((m as f32 + 0.5) * model.wo * one_on_r + 0.5) as usize;
        let mut den = 0.0f32;
        for s in sw[am..bm].iter() {
            den += s.norm_sqr();
        }
        model.a[m] = libm::sqrtf(den);
    }
}

/// Voicing decision: how well the first 1,000 Hz fit a fully voiced model, then two sanity checks
/// on the low/high energy ratio. Returns the fit in dB.
pub fn est_voicing_mbe(model: &mut Model, sw: &[C32; FFT_ENC], w_dft: &[f32; FFT_ENC]) -> f32 {
    let l_1000 = (model.l as f32 * 1000.0 / 4000.0) as usize;
    let mut sig = 1e-4f32;
    for l in 1..=l_1000 {
        sig += model.a[l] * model.a[l];
    }
    let wo = model.wo;
    let mut error = 1e-4f32;
    for l in 1..=l_1000 {
        let al = libm::ceilf((l as f32 - 0.5) * wo * FFT_ENC as f32 / TWO_PI) as usize;
        let bl = libm::ceilf((l as f32 + 0.5) * wo * FFT_ENC as f32 / TWO_PI) as usize;
        let offset = (FFT_ENC as f32 / 2.0 - l as f32 * wo * FFT_ENC as f32 / TWO_PI + 0.5) as usize;
        let mut am = C32::ZERO;
        let mut den = 0.0f32;
        for m in al..bl {
            let wv = w_dft[offset + m];
            am.re += sw[m].re * wv;
            am.im += sw[m].im * wv;
            den += wv * wv;
        }
        am = am.scale(1.0 / den);
        for m in al..bl {
            let wv = w_dft[offset + m];
            let er = sw[m].re - am.re * wv;
            let ei = sw[m].im - am.im * wv;
            error += er * er + ei * ei;
        }
    }
    let snr = 10.0 * libm::log10f(sig / error);
    model.voiced = snr > V_THRESH;

    let l_2000 = (model.l as f32 * 2000.0 / 4000.0) as usize;
    let l_4000 = model.l;
    let mut elow = 1e-4f32;
    let mut ehigh = 1e-4f32;
    for l in 1..=l_2000 {
        elow += model.a[l] * model.a[l];
    }
    for l in l_2000..=l_4000 {
        ehigh += model.a[l] * model.a[l];
    }
    let eratio = 10.0 * libm::log10f(elow / ehigh);
    if !model.voiced && eratio > 10.0 {
        model.voiced = true;
    }
    if model.voiced {
        if eratio < -10.0 {
            model.voiced = false;
        }
        let sixty = 60.0 * TWO_PI / 8000.0;
        if eratio < -4.0 && model.wo <= sixty {
            model.voiced = false;
        }
    }
    snr
}
