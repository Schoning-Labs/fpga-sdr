// SPDX-License-Identifier: LGPL-2.1-only
//
// Rust translation of parts of Codec 2 release 1.2.0 (https://github.com/drowe67/codec2):
// src/codec2.c, src/defines.h, src/pack.c, src/sine.c (c2const_create, codec2_rand).
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

//! `tr-codec2`: the Codec 2 **700C** speech codec (28 bits per 40 ms, 8 kHz speech) in `no_std`
//! Rust, no heap. A translation of David Rowe's C implementation; see `NOTICE` and
//! `docs/FREEDV.md`.
//!
//! - [`Decoder700c`]: 28 bits (4 bytes, first bit in the top bit of byte 0) to 320 samples.
//! - [`Encoder700c`]: 320 samples to 28 bits.
//!
//! Module map: [`newamp1`] rate-K amplitude quantiser (tables in [`tables`]), [`synth`] phase and
//! sinusoidal synthesis with the background-noise postfilter, [`analysis`] and [`nlp`] the
//! encoder's sinusoidal analysis and pitch estimator, [`fft`] the FFT they share.

#![no_std]

pub mod analysis;
pub mod fft;
pub mod newamp1;
pub mod nlp;
pub mod synth;
pub mod tables;

use fft::Fft;

/// Complex `f32`.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct C32 {
    pub re: f32,
    pub im: f32,
}

impl C32 {
    pub const ZERO: C32 = C32 { re: 0.0, im: 0.0 };
    #[inline(always)]
    pub const fn new(re: f32, im: f32) -> Self {
        Self { re, im }
    }
    #[inline(always)]
    pub fn norm_sqr(self) -> f32 {
        self.re * self.re + self.im * self.im
    }
    #[inline(always)]
    pub fn conj(self) -> Self {
        Self::new(self.re, -self.im)
    }
    #[inline(always)]
    pub fn mul(self, o: Self) -> Self {
        Self::new(self.re * o.re - self.im * o.im, self.re * o.im + self.im * o.re)
    }
    #[inline(always)]
    pub fn add(self, o: Self) -> Self {
        Self::new(self.re + o.re, self.im + o.im)
    }
    #[inline(always)]
    pub fn sub(self, o: Self) -> Self {
        Self::new(self.re - o.re, self.im - o.im)
    }
    #[inline(always)]
    pub fn scale(self, k: f32) -> Self {
        Self::new(self.re * k, self.im * k)
    }
}

/// Speech sample rate, Hz.
pub const FS: usize = 8000;
/// Samples per internal 10 ms frame.
pub const N_SAMP: usize = 80;
/// Largest number of harmonics at 8 kHz (pitch period 160 samples).
pub const MAX_AMP: usize = 80;
/// Pitch analysis window, samples.
pub const M_PITCH: usize = 320;
pub const P_MIN: usize = 20;
pub const P_MAX: usize = 160;
/// Fundamental limits, `TWO_PI / p_max` and `TWO_PI / p_min` evaluated in double as upstream does.
pub const WO_MIN: f32 = (6.283185307_f64 / P_MAX as f64) as f32;
pub const WO_MAX: f32 = (6.283185307_f64 / P_MIN as f64) as f32;
/// Analysis window length.
pub const NW: usize = 279;
/// Synthesis window overlap.
pub const TW: usize = 40;
pub const FFT_ENC: usize = 512;
pub const FFT_DEC: usize = 512;
#[allow(clippy::approx_constant)]
pub const PI: f32 = 3.141592654;
#[allow(clippy::approx_constant)]
pub const TWO_PI: f32 = 6.283185307;

/// Bits per 700C frame.
pub const BITS_PER_FRAME: usize = 28;
/// Bytes that hold one 700C frame.
pub const BYTES_PER_FRAME: usize = 4;
/// Speech samples per 700C frame (40 ms).
pub const SAMPLES_PER_FRAME: usize = 320;

/// 10^x as Codec 2 computes it (`POW10F`: `exp10f` in a GNU build, which is what the reference
/// programs of a Linux build use).
#[inline]
pub(crate) fn pow10f(x: f32) -> f32 {
    libm::exp10f(x)
}

/// Sinusoidal model of one 10 ms frame.
#[derive(Clone, Copy)]
pub struct Model {
    /// Fundamental, radians per sample.
    pub wo: f32,
    /// Number of harmonics.
    pub l: usize,
    /// Harmonic amplitudes, index 1..=l.
    pub a: [f32; MAX_AMP + 1],
    /// Harmonic phases, index 1..=l.
    pub phi: [f32; MAX_AMP + 1],
    pub voiced: bool,
}

impl Model {
    pub const fn new() -> Self {
        Self { wo: TWO_PI / P_MAX as f32, l: MAX_AMP, a: [0.0; MAX_AMP + 1], phi: [0.0; MAX_AMP + 1], voiced: false }
    }
}

impl Default for Model {
    fn default() -> Self {
        Self::new()
    }
}

/// Codec 2's own pseudo-random generator (`codec2_rand`, values 0..=32767). Upstream keeps one
/// state for the whole process as `unsigned long` (64 bits on Linux); here each codec instance
/// has its own.
#[derive(Clone, Copy)]
pub struct Rand(u64);

impl Rand {
    pub const MAX: f32 = 32767.0;
    pub const fn new() -> Self {
        Rand(1)
    }
    #[inline]
    pub fn next(&mut self) -> u32 {
        self.0 = self.0.wrapping_mul(1103515245).wrapping_add(12345);
        ((self.0 / 65536) % 32768) as u32
    }
}

impl Default for Rand {
    fn default() -> Self {
        Self::new()
    }
}

/// Reads `width` bits, most significant first, starting at bit `*pos` (`unpack_natural_or_gray`
/// with natural coding).
pub fn unpack(bits: &[u8], pos: &mut usize, width: usize) -> u32 {
    let mut v = 0u32;
    for _ in 0..width {
        let b = (bits[*pos >> 3] >> (7 - (*pos & 7))) & 1;
        v = (v << 1) | b as u32;
        *pos += 1;
    }
    v
}

/// Writes `width` bits of `value`, most significant first, starting at bit `*pos`.
pub fn pack(bits: &mut [u8], pos: &mut usize, value: u32, width: usize) {
    for i in (0..width).rev() {
        if (value >> i) & 1 != 0 {
            bits[*pos >> 3] |= 1 << (7 - (*pos & 7));
        }
        *pos += 1;
    }
}

/// The four quantiser indexes of a 700C frame: two 9-bit vector quantiser stages, 4-bit energy,
/// 6-bit pitch (0 = unvoiced).
pub fn unpack_indexes(bits: &[u8; BYTES_PER_FRAME]) -> [usize; 4] {
    let mut p = 0;
    [
        unpack(bits, &mut p, 9) as usize,
        unpack(bits, &mut p, 9) as usize,
        unpack(bits, &mut p, 4) as usize,
        unpack(bits, &mut p, 6) as usize,
    ]
}

pub fn pack_indexes(idx: &[usize; 4]) -> [u8; BYTES_PER_FRAME] {
    let mut out = [0u8; BYTES_PER_FRAME];
    let mut p = 0;
    pack(&mut out, &mut p, idx[0] as u32, 9);
    pack(&mut out, &mut p, idx[1] as u32, 9);
    pack(&mut out, &mut p, idx[2] as u32, 4);
    pack(&mut out, &mut p, idx[3] as u32, 6);
    out
}

/// Codec 2 700C decoder (`codec2_decode_700c`).
pub struct Decoder700c {
    fft_phase: Fft<{ newamp1::PHASE_NFFT }>,
    fft_synth: Fft<FFT_DEC>,
    /// Mel-spaced sample frequencies of the rate-K vector, kHz.
    freqs_khz: [f32; newamp1::K],
    prev_rate_k_vec: [f32; newamp1::K],
    wo_left: f32,
    voicing_left: bool,
    ex_phase: f32,
    bg_est: f32,
    /// Synthesis overlap buffer.
    sn: [f32; 2 * N_SAMP],
    /// Synthesis window.
    pn: [f32; 2 * N_SAMP],
    rand: Rand,
    /// The amplitude postfilter (formant emphasis); on by default as upstream.
    pub post_filter: bool,
    /// Output gain; 1.5 as upstream ("700C is a little quieter").
    pub gain: f32,
}

impl Default for Decoder700c {
    fn default() -> Self {
        Self::new()
    }
}

impl Decoder700c {
    pub fn new() -> Self {
        let mut slot = core::mem::MaybeUninit::<Self>::uninit();
        Self::init(&mut slot);
        // SAFETY: `init` wrote every field.
        unsafe { slot.assume_init() }
    }

    /// Builds the decoder in `slot` itself. `new` returns the 7 KB decoder through the stack;
    /// this does not (docs/FREEDV.md section 9, stack).
    pub fn init(slot: &mut core::mem::MaybeUninit<Self>) -> &mut Self {
        use core::ptr::addr_of_mut;
        let p = slot.as_mut_ptr();
        // SAFETY: every field is written through a raw pointer to the field, none is read before.
        unsafe {
            Fft::init(&mut *(addr_of_mut!((*p).fft_phase) as *mut core::mem::MaybeUninit<Fft<{ newamp1::PHASE_NFFT }>>));
            Fft::init(&mut *(addr_of_mut!((*p).fft_synth) as *mut core::mem::MaybeUninit<Fft<FFT_DEC>>));
            addr_of_mut!((*p).freqs_khz).write(newamp1::mel_sample_freqs_khz());
            addr_of_mut!((*p).prev_rate_k_vec).write([0.0; newamp1::K]);
            addr_of_mut!((*p).wo_left).write(0.0);
            addr_of_mut!((*p).voicing_left).write(false);
            addr_of_mut!((*p).ex_phase).write(0.0);
            addr_of_mut!((*p).bg_est).write(0.0);
            addr_of_mut!((*p).sn).write([0.0; 2 * N_SAMP]);
            let mut pn = [0.0; 2 * N_SAMP];
            synth::make_synthesis_window(&mut pn);
            addr_of_mut!((*p).pn).write(pn);
            addr_of_mut!((*p).rand).write(Rand::new());
            addr_of_mut!((*p).post_filter).write(true);
            addr_of_mut!((*p).gain).write(1.5);
            slot.assume_init_mut()
        }
    }

    /// Decodes one 28-bit frame into 320 samples of 8 kHz speech.
    pub fn decode(&mut self, bits: &[u8; BYTES_PER_FRAME], speech: &mut [i16; SAMPLES_PER_FRAME]) {
        self.decode_indexes(&unpack_indexes(bits), speech)
    }

    /// The frame energy field alone (mean of the rate-K vector in dB), for squelch decisions.
    pub fn frame_energy_db(bits: &[u8; BYTES_PER_FRAME]) -> f32 {
        tables::ENERGY[unpack_indexes(bits)[2]]
    }

    pub fn decode_indexes(&mut self, indexes: &[usize; 4], speech: &mut [i16; SAMPLES_PER_FRAME]) {
        let mut models = [Model::new(); 4];
        let mut hh = [[C32::ZERO; MAX_AMP + 1]; 4];
        newamp1::indexes_to_model(
            &mut models,
            &mut hh,
            &mut self.prev_rate_k_vec,
            &mut self.wo_left,
            &mut self.voicing_left,
            &self.freqs_khz,
            &self.fft_phase,
            indexes,
            self.post_filter,
        );
        for i in 0..4 {
            let model = &mut models[i];
            synth::phase_synth_zero_order(N_SAMP, model, &mut self.ex_phase, &hh[i], &mut self.rand);
            synth::postfilter(model, &mut self.bg_est, &mut self.rand);
            synth::synthesise(&self.fft_synth, &mut self.sn, model, &self.pn);
            let mut frame = [0.0f32; N_SAMP];
            for (f, s) in frame.iter_mut().zip(self.sn.iter()) {
                *f = *s * self.gain;
            }
            synth::ear_protection(&mut frame);
            for (o, f) in speech[i * N_SAMP..(i + 1) * N_SAMP].iter_mut().zip(frame.iter()) {
                *o = if *f > 32767.0 {
                    32767
                } else if *f < -32767.0 {
                    -32767
                } else {
                    *f as i16
                };
            }
        }
    }
}

/// Codec 2 700C encoder (`codec2_encode_700c`). The equaliser is off, as upstream has it by
/// default (FreeDV 700E switches it on at the transmitter; see [`Encoder700c::eq`]).
pub struct Encoder700c {
    fft: Fft<FFT_ENC>,
    /// Analysis window and its DFT.
    w: [f32; M_PITCH],
    w_dft: [f32; FFT_ENC],
    sn: [f32; M_PITCH],
    nlp: nlp::Nlp,
    prev_f0: f32,
    freqs_khz: [f32; newamp1::K],
    eq_state: [f32; newamp1::K],
    /// Transmit equaliser (`codec2_700c_eq`).
    pub eq: bool,
}

impl Default for Encoder700c {
    fn default() -> Self {
        Self::new()
    }
}

impl Encoder700c {
    pub fn new() -> Self {
        let fft = Fft::new();
        let mut w = [0.0; M_PITCH];
        let mut w_dft = [0.0; FFT_ENC];
        analysis::make_analysis_window(&fft, &mut w, &mut w_dft);
        Self {
            fft,
            w,
            w_dft,
            sn: [1.0; M_PITCH],
            nlp: nlp::Nlp::new(),
            prev_f0: 1.0 / 0.02,
            freqs_khz: newamp1::mel_sample_freqs_khz(),
            eq_state: [0.0; newamp1::K],
            eq: false,
        }
    }

    /// Sinusoidal analysis of 80 new samples (`analyse_one_frame`).
    pub fn analyse(&mut self, speech: &[i16], model: &mut Model) {
        debug_assert_eq!(speech.len(), N_SAMP);
        self.sn.copy_within(N_SAMP.., 0);
        for (d, s) in self.sn[M_PITCH - N_SAMP..].iter_mut().zip(speech.iter()) {
            *d = *s as f32;
        }
        let mut sw = [C32::ZERO; FFT_ENC];
        analysis::dft_speech(&self.fft, &mut sw, &self.sn, &self.w);
        let pitch = self.nlp.run(&self.sn, N_SAMP, &mut self.prev_f0);
        model.wo = TWO_PI / pitch;
        model.l = (PI / model.wo) as usize;
        analysis::two_stage_pitch_refinement(model, &sw);
        analysis::estimate_amplitudes(model, &sw);
        analysis::est_voicing_mbe(model, &sw, &self.w_dft);
    }

    /// Encodes 320 samples of 8 kHz speech into the four quantiser indexes.
    pub fn encode_indexes(&mut self, speech: &[i16; SAMPLES_PER_FRAME]) -> [usize; 4] {
        let mut model = Model::new();
        for i in 0..4 {
            self.analyse(&speech[i * N_SAMP..(i + 1) * N_SAMP], &mut model);
        }
        newamp1::model_to_indexes(&model, &self.freqs_khz, &mut self.eq_state, self.eq)
    }

    /// Encodes 320 samples into 28 bits (4 bytes, first bit in the top bit of byte 0).
    pub fn encode(&mut self, speech: &[i16; SAMPLES_PER_FRAME]) -> [u8; BYTES_PER_FRAME] {
        pack_indexes(&self.encode_indexes(speech))
    }
}
