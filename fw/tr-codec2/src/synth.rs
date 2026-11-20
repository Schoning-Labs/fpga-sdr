// SPDX-License-Identifier: LGPL-2.1-only
//
// Rust translation of parts of Codec 2 release 1.2.0 (https://github.com/drowe67/codec2):
// src/phase.c (phase_synth_zero_order), src/postfilter.c, src/sine.c (make_synthesis_window,
// synthesise), src/codec2.c (ear_protection).
// Copyright (C) 1990-2012 David Rowe. All rights reserved.
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

//! The decoder's back half: harmonic phases from a pitch-pulse excitation through the
//! minimum-phase filter, the background-noise postfilter, and overlap-add sinusoidal synthesis by
//! inverse FFT.

use crate::fft::Fft;
use crate::{pow10f, Model, Rand, C32, FFT_DEC, MAX_AMP, N_SAMP, TW, TWO_PI};

/// Phases of the harmonics: excitation (a pulse train when voiced, random when not) times `h`.
pub fn phase_synth_zero_order(n_samp: usize, model: &mut Model, ex_phase: &mut f32, h: &[C32; MAX_AMP + 1], rand: &mut Rand) {
    *ex_phase += model.wo * n_samp as f32;
    // upstream evaluates the wrap in double (TWO_PI is a double constant); the error would
    // otherwise accumulate in the pitch phase
    const TWO_PI_D: f64 = 6.283185307;
    let k = libm::floorf((*ex_phase as f64 / TWO_PI_D + 0.5) as f32);
    *ex_phase = (*ex_phase as f64 - TWO_PI_D * k as f64) as f32;
    for m in 1..=model.l {
        let ex = if model.voiced {
            let a = *ex_phase * m as f32;
            C32::new(libm::cosf(a), libm::sinf(a))
        } else {
            let phi = TWO_PI * rand.next() as f32 / Rand::MAX;
            C32::new(libm::cosf(phi), libm::sinf(phi))
        };
        let a = h[m].mul(ex);
        model.phi[m] = libm::atan2f(a.im, a.re + 1e-12);
    }
}

const BG_THRESH: f32 = 40.0;
const BG_BETA: f32 = 0.1;
const BG_MARGIN: f32 = 6.0;

/// Harmonics below the tracked background noise level get random phase in voiced frames.
pub fn postfilter(model: &mut Model, bg_est: &mut f32, rand: &mut Rand) {
    let mut e = 1e-12f32;
    for m in 1..=model.l {
        e += model.a[m] * model.a[m];
    }
    let e = 10.0 * libm::log10f(e / model.l as f32);
    if e < BG_THRESH && !model.voiced {
        *bg_est = *bg_est * (1.0 - BG_BETA) + e * BG_BETA;
    }
    let thresh = pow10f((*bg_est + BG_MARGIN) / 20.0);
    if model.voiced {
        for m in 1..=model.l {
            if model.a[m] < thresh {
                model.phi[m] = (TWO_PI / Rand::MAX) * rand.next() as f32;
            }
        }
    }
}

/// Trapezoidal synthesis window over two frames.
pub fn make_synthesis_window(pn: &mut [f32; 2 * N_SAMP]) {
    let n = N_SAMP;
    let mut win = 0.0f32;
    for i in n / 2 - TW..n / 2 + TW {
        pn[i] = win;
        win += 1.0 / (2 * TW) as f32;
    }
    for p in pn[n / 2 + TW..3 * n / 2 - TW].iter_mut() {
        *p = 1.0;
    }
    win = 1.0;
    for i in 3 * n / 2 - TW..3 * n / 2 + TW {
        pn[i] = win;
        win -= 1.0 / (2 * TW) as f32;
    }
}

/// Adds one frame of synthesised speech to the overlap buffer `sn`; afterwards `sn[..N_SAMP]`
/// is the finished frame. (`synthesise` with `shift = 1`.)
pub fn synthesise(fft: &Fft<FFT_DEC>, sn: &mut [f32; 2 * N_SAMP], model: &Model, pn: &[f32; 2 * N_SAMP]) {
    let n = N_SAMP;
    sn.copy_within(n..2 * n - 1, 0);
    sn[n - 1] = 0.0;

    // Hermitian spectrum with one harmonic per bin, then the complex inverse FFT (the real
    // inverse FFT upstream uses gives the same samples).
    let mut sw = [C32::ZERO; FFT_DEC];
    for l in 1..=model.l {
        let mut b = (l as f32 * model.wo * FFT_DEC as f32 / TWO_PI + 0.5) as usize;
        if b > FFT_DEC / 2 - 1 {
            b = FFT_DEC / 2 - 1;
        }
        let v = C32::new(model.a[l] * libm::cosf(model.phi[l]), model.a[l] * libm::sinf(model.phi[l]));
        sw[b] = v;
        sw[FFT_DEC - b] = v.conj();
    }
    fft.inverse(&mut sw);

    for i in 0..n - 1 {
        sn[i] += sw[FFT_DEC - n + 1 + i].re * pn[i];
    }
    for (j, i) in (n - 1..2 * n).enumerate() {
        sn[i] = sw[j].re * pn[i];
    }
}

/// Reduces a frame that peaks above 30,000 (bit errors, overdrive).
pub fn ear_protection(frame: &mut [f32]) {
    let mut max = 0.0f32;
    for &v in frame.iter() {
        if v > max {
            max = v;
        }
    }
    let over = max / 30000.0;
    if over > 1.0 {
        let gain = 1.0 / (over * over);
        for v in frame.iter_mut() {
            *v *= gain;
        }
    }
}
