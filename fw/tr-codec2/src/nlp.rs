// SPDX-License-Identifier: LGPL-2.1-only
//
// Rust translation of parts of Codec 2 release 1.2.0 (https://github.com/drowe67/codec2):
// src/nlp.c (the 8 kHz path).
// Copyright (C) 2009 David Rowe. All rights reserved.
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

//! Non-linear pitch estimator: the speech is squared, notch filtered at DC, low-pass filtered,
//! decimated by 5 and transformed; the pitch is the lowest strong peak (sub-multiples of the
//! global peak are tried, with a bias to the previous frame's pitch).

use crate::fft::Fft;
use crate::{C32, M_PITCH, P_MAX, P_MIN};

const COEFF: f32 = 0.95;
const PE_FFT_SIZE: usize = 512;
const DEC: usize = 5;
const SAMPLE_RATE: f32 = 8000.0;
const CNLP: f32 = 0.3;
const NLP_NTAP: usize = 48;

/// 48 tap 600 Hz low pass FIR filter coefficients.
#[rustfmt::skip]
static NLP_FIR: [f32; NLP_NTAP] = [
    -1.0818124e-03, -1.1008344e-03, -9.2768838e-04, -4.2289438e-04,
    5.5034190e-04,  2.0029849e-03,  3.7058509e-03,  5.1449415e-03,
    5.5924666e-03,  4.3036754e-03,  8.0284511e-04,  -4.8204610e-03,
    -1.1705810e-02, -1.8199275e-02, -2.2065282e-02, -2.0920610e-02,
    -1.2808831e-02, 3.2204775e-03,  2.6683811e-02,  5.5520624e-02,
    8.6305944e-02,  1.1480192e-01,  1.3674206e-01,  1.4867556e-01,
    1.4867556e-01,  1.3674206e-01,  1.1480192e-01,  8.6305944e-02,
    5.5520624e-02,  2.6683811e-02,  3.2204775e-03,  -1.2808831e-02,
    -2.0920610e-02, -2.2065282e-02, -1.8199275e-02, -1.1705810e-02,
    -4.8204610e-03, 8.0284511e-04,  4.3036754e-03,  5.5924666e-03,
    5.1449415e-03,  3.7058509e-03,  2.0029849e-03,  5.5034190e-04,
    -4.2289438e-04, -9.2768838e-04, -1.1008344e-03, -1.0818124e-03,
];

pub struct Nlp {
    w: [f32; M_PITCH / DEC],
    sq: [f32; M_PITCH],
    mem_x: f32,
    mem_y: f32,
    mem_fir: [f32; NLP_NTAP],
    fft: Fft<PE_FFT_SIZE>,
}

impl Default for Nlp {
    fn default() -> Self {
        Self::new()
    }
}

impl Nlp {
    pub fn new() -> Self {
        let mut w = [0.0; M_PITCH / DEC];
        let n = (M_PITCH / DEC) as f32;
        for (i, v) in w.iter_mut().enumerate() {
            *v = 0.5 - 0.5 * libm::cosf(2.0 * crate::PI * i as f32 / (n - 1.0));
        }
        Self { w, sq: [0.0; M_PITCH], mem_x: 0.0, mem_y: 0.0, mem_fir: [0.0; NLP_NTAP], fft: Fft::new() }
    }

    /// `sn` is the 320-sample speech buffer whose last `n` samples are new. Returns the pitch
    /// period in samples; `prev_f0` (Hz) is the tracking memory.
    pub fn run(&mut self, sn: &[f32; M_PITCH], n: usize, prev_f0: &mut f32) -> f32 {
        let m = M_PITCH;
        for i in m - n..m {
            self.sq[i] = sn[i] * sn[i];
        }
        for i in m - n..m {
            let mut notch = self.sq[i] - self.mem_x;
            notch += COEFF * self.mem_y;
            self.mem_x = self.sq[i];
            self.mem_y = notch;
            self.sq[i] = notch + 1.0;
        }
        for i in m - n..m {
            self.mem_fir.copy_within(1.., 0);
            self.mem_fir[NLP_NTAP - 1] = self.sq[i];
            let mut acc = 0.0f32;
            for j in 0..NLP_NTAP {
                acc += self.mem_fir[j] * NLP_FIR[j];
            }
            self.sq[i] = acc;
        }
        let mut fw = [C32::ZERO; PE_FFT_SIZE];
        for i in 0..m / DEC {
            fw[i].re = self.sq[i * DEC] * self.w[i];
        }
        self.fft.forward(&mut fw);
        let mut p = [0.0f32; PE_FFT_SIZE / 2];
        for (d, s) in p.iter_mut().zip(fw.iter()) {
            *d = s.norm_sqr();
        }

        let lo = PE_FFT_SIZE * DEC / P_MAX;
        let hi = PE_FFT_SIZE * DEC / P_MIN;
        let mut gmax = 0.0f32;
        let mut gmax_bin = lo;
        for i in lo..=hi {
            if p[i] > gmax {
                gmax = p[i];
                gmax_bin = i;
            }
        }
        let best_f0 = post_process_sub_multiples(&p, gmax, gmax_bin, *prev_f0);
        self.sq.copy_within(n.., 0);
        *prev_f0 = best_f0;
        SAMPLE_RATE / best_f0
    }
}

fn post_process_sub_multiples(p: &[f32; PE_FFT_SIZE / 2], gmax: f32, gmax_bin: usize, prev_f0: f32) -> f32 {
    let min_bin = PE_FFT_SIZE * DEC / P_MAX;
    let mut cmax_bin = gmax_bin;
    let prev_f0_bin = (prev_f0 * (PE_FFT_SIZE * DEC) as f32 / SAMPLE_RATE) as usize;
    let mut mult = 2;
    while gmax_bin / mult >= min_bin {
        let b = gmax_bin / mult;
        let mut bmin = (0.8 * b as f64) as usize;
        let bmax = (1.2 * b as f64) as usize;
        if bmin < min_bin {
            bmin = min_bin;
        }
        let thresh = if prev_f0_bin > bmin && prev_f0_bin < bmax { CNLP * 0.5 * gmax } else { CNLP * gmax };
        let mut lmax = 0.0f32;
        let mut lmax_bin = bmin;
        for b in bmin..=bmax {
            if p[b] > lmax {
                lmax = p[b];
                lmax_bin = b;
            }
        }
        if lmax > thresh && lmax > p[lmax_bin - 1] && lmax > p[lmax_bin + 1] {
            cmax_bin = lmax_bin;
        }
        mult += 1;
    }
    cmax_bin as f32 * SAMPLE_RATE / (PE_FFT_SIZE * DEC) as f32
}
