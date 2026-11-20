// SPDX-License-Identifier: LGPL-2.1-only
//
// Rust translation of parts of Codec 2 release 1.2.0 (https://github.com/drowe67/codec2):
// src/ofdm.c, src/ofdm_mode.c, src/ofdm_internal.h.
// Authors: David Rowe & Steve Sampson. Copyright (C) 2017-2020 David Rowe. All rights reserved.
// Modified 2026 by Franz Schöning, https://www.schoning.com: translated from C to Rust; only the
// 700D and 700E voice modes; fixed arrays; a real-valued receive buffer (the input is real audio);
// the down-conversion phase by recurrence; the frame timing correlation only over the samples it
// uses.
//
// This program is free software; you can redistribute it and/or modify it under the terms of
// the GNU Lesser General Public License version 2.1, as published by the Free Software
// Foundation. This program is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE. See the GNU Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public License along with this
// program; if not, see <http://www.gnu.org/licenses/>.

//! The OFDM modem of FreeDV 700D and 700E: QPSK carriers around 1,500 Hz of 8 kHz audio, one
//! row of pilot symbols at the start of every modem frame. Receive: coarse timing and frequency
//! search on the pilot waveform, then per frame fine timing, frequency tracking, and phase and
//! amplitude estimates from the pilots around the frame.

use crate::ldpc::{Code, HRA_112_112, HRA_56_56, QPSK};
use tr_codec2::C32;

const TAU: f32 = core::f32::consts::TAU;
/// Modem sample rate, Hz.
pub const FS: f32 = 8000.0;
/// Samples per OFDM symbol with its cyclic prefix (both modes).
pub const SPS: usize = 160;
/// Largest symbol without cyclic prefix.
pub const M_MAX: usize = 144;
/// Most carriers plus the two edge positions.
pub const NC2_MAX: usize = 23;
/// Most symbols per modem frame.
pub const NS_MAX: usize = 8;
/// Longest modem frame, samples.
pub const SPF_MAX: usize = NS_MAX * SPS;
/// Receive buffer: three frames and three symbols.
pub const NRXBUF_MAX: usize = 3 * SPF_MAX + 3 * SPS;
/// Most data symbols per modem frame.
pub const SYMS_MAX: usize = 119;
/// Most bits per modem frame.
pub const BITS_MAX: usize = 2 * SYMS_MAX;
/// Most unique word bits.
pub const UW_MAX: usize = 12;
/// Peak level of the transmit waveform.
pub const OFDM_PEAK: f32 = 16384.0;

/// Pilot symbol signs, compatible with the Octave version.
#[rustfmt::skip]
static PILOT_VALUES: [i8; 64] = [
    -1, -1, 1,  1,  -1, -1, -1, 1,  -1, 1,  -1, 1,  1,  1,  1,  1,
    1,  1,  1,  -1, -1, 1,  -1, 1,  -1, 1,  1,  1,  1,  1,  1,  1,
    1,  1,  1,  -1, 1,  1,  1,  1,  1,  -1, -1, -1, -1, -1, -1, 1,
    -1, 1,  -1, 1,  -1, -1, 1,  -1, 1,  1,  1,  1,  -1, 1,  -1, 1,
];

/// The fixed numbers of a mode (`ofdm_init_mode`).
pub struct Mode {
    pub name: &'static str,
    /// Carriers.
    pub nc: usize,
    /// Symbols per modem frame, the first is the pilot row.
    pub ns: usize,
    /// Samples per symbol without cyclic prefix.
    pub m: usize,
    /// Cyclic prefix, samples.
    pub ncp: usize,
    /// Symbol rate, Hz (carrier spacing).
    pub rs: f32,
    /// Carrier number (in units of `rs`) of the lower edge position.
    pub nlower: f32,
    pub nuwbits: usize,
    pub ntxtbits: usize,
    pub bad_uw_errors: usize,
    pub ftwindowwidth: usize,
    pub timing_mx_thresh: f32,
    pub edge_pilots: bool,
    /// The "voice2" sync state machine (700E) instead of "voice1" (700D).
    pub voice2: bool,
    pub foff_limiter: bool,
    pub amp_scale: f32,
    pub code: &'static Code,
}

impl Mode {
    pub const fn samples_per_frame(&self) -> usize {
        self.ns * SPS
    }
    pub const fn bits_per_frame(&self) -> usize {
        (self.ns - 1) * self.nc * 2
    }
    pub const fn syms_per_frame(&self) -> usize {
        (self.ns - 1) * self.nc
    }
    pub const fn rows_per_frame(&self) -> usize {
        self.ns - 1
    }
    pub const fn nrxbuf(&self) -> usize {
        3 * self.samples_per_frame() + 3 * SPS
    }
    /// Symbol index of unique word symbol `i`.
    pub const fn uw_ind_sym(&self, i: usize) -> usize {
        let nuwsyms = self.nuwbits / 2;
        let mut step = self.nc + 1;
        if nuwsyms * step / 2 >= self.syms_per_frame() {
            step = self.nc - 1;
        }
        (i + 1) * step / 2
    }
}

/// FreeDV 700D: 17 carriers, 20 ms symbols with 2 ms prefix, 160 ms frames.
pub static MODE_700D: Mode = Mode {
    name: "700D",
    nc: 17,
    ns: 8,
    m: 144,
    ncp: 16,
    rs: 1.0 / 0.018,
    nlower: 18.0,
    nuwbits: 10,
    ntxtbits: 4,
    bad_uw_errors: 3,
    ftwindowwidth: 32,
    timing_mx_thresh: 0.30,
    edge_pilots: true,
    voice2: false,
    foff_limiter: false,
    amp_scale: 245e3,
    code: &HRA_112_112,
};

/// FreeDV 700E: 21 carriers, 14 ms symbols with 6 ms prefix, 80 ms frames.
pub static MODE_700E: Mode = Mode {
    name: "700E",
    nc: 21,
    ns: 4,
    m: 112,
    ncp: 48,
    rs: 1.0 / 0.014,
    nlower: 10.0,
    nuwbits: 12,
    ntxtbits: 2,
    bad_uw_errors: 3,
    ftwindowwidth: 80,
    timing_mx_thresh: 0.30,
    edge_pilots: false,
    voice2: true,
    foff_limiter: true,
    amp_scale: 155e3,
    code: &HRA_56_56,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SyncState {
    Search,
    Trial,
    Synced,
}

#[inline]
fn cis(a: f32) -> C32 {
    C32::new(libm::cosf(a), libm::sinf(a))
}

#[inline]
fn cabs(c: C32) -> f32 {
    libm::sqrtf(c.norm_sqr())
}

/// The two bits of a QPSK symbol, in transmit order.
#[inline]
pub fn qpsk_demod(s: C32) -> [u8; 2] {
    let r = s.mul(cis(core::f32::consts::FRAC_PI_4));
    [(r.im <= 0.0) as u8, (r.re <= 0.0) as u8]
}

/// QPSK symbol of two bits, in transmit order.
#[inline]
pub fn qpsk_mod(b0: u8, b1: u8) -> C32 {
    QPSK[(((b0 & 1) << 1) | (b1 & 1)) as usize]
}

/// Modem state (`struct OFDM`).
pub struct Ofdm {
    pub mode: &'static Mode,
    pilots: [C32; NC2_MAX],
    /// Time-domain pilot symbol with the cyclic prefix zeroed.
    pilot_samples: [C32; SPS],
    timing_norm: f32,
    /// Radians per sample of one carrier spacing.
    doc: f32,
    rxbuf: [f32; NRXBUF_MAX],
    rx_sym: [[C32; NC2_MAX]; NS_MAX + 3],
    /// Data symbols of the last frame after phase correction, and their amplitude estimates.
    pub rx_np: [C32; SYMS_MAX],
    pub rx_amp: [f32; SYMS_MAX],
    pub foff_est_hz: f32,
    pub coarse_foff_est_hz: f32,
    foff_est_gain: f32,
    pub timing_est: i32,
    sample_point: i32,
    pub timing_valid: bool,
    pub timing_mx: f32,
    /// Samples the next call wants.
    pub nin: usize,
    pub mean_amp: f32,
    pub clock_offset_counter: i32,
    low_bw: bool,
    pub sync_state: SyncState,
    pub last_sync_state: SyncState,
    pub uw_errors: usize,
    pub sync_counter: usize,
    pub frame_count: usize,
}

impl Ofdm {
    pub fn new(mode: &'static Mode) -> Self {
        let mut slot = core::mem::MaybeUninit::<Self>::uninit();
        Self::init(&mut slot, mode);
        // SAFETY: `init` initialised the whole struct.
        unsafe { slot.assume_init() }
    }

    /// Builds the modem in `slot` itself: `new` would build the 22 KB struct on the stack and
    /// copy it.
    pub fn init<'a>(slot: &'a mut core::mem::MaybeUninit<Self>, mode: &'static Mode) -> &'a mut Self {
        use core::ptr::addr_of_mut;
        let p = slot.as_mut_ptr();
        // SAFETY: the struct holds numbers, bools, arrays of them, `SyncState` (zero is `Search`)
        // and one reference. All bytes are zeroed first, then the reference is written, all through
        // raw pointers; only then is a `&mut` made.
        unsafe {
            core::ptr::write_bytes(p, 0, 1);
            addr_of_mut!((*p).mode).write(mode);
            addr_of_mut!((*p).foff_est_gain).write(0.1);
            addr_of_mut!((*p).nin).write(mode.samples_per_frame());
            addr_of_mut!((*p).doc).write(TAU / (FS / mode.rs));
            addr_of_mut!((*p).sync_state).write(SyncState::Search);
            addr_of_mut!((*p).last_sync_state).write(SyncState::Search);
        }
        // SAFETY: every field now holds a valid value.
        let o = unsafe { slot.assume_init_mut() };
        for i in 0..mode.nc + 2 {
            o.pilots[i].re = PILOT_VALUES[i] as f32;
        }
        if !mode.edge_pilots {
            o.pilots[0] = C32::ZERO;
            o.pilots[mode.nc + 1] = C32::ZERO;
        }
        let mut temp = [C32::ZERO; M_MAX];
        let pilots = o.pilots;
        o.idft(&mut temp, &pilots);
        o.pilot_samples[mode.ncp..mode.ncp + mode.m].copy_from_slice(&temp[..mode.m]);
        let acc: f32 = o.pilot_samples.iter().map(|c| c.norm_sqr()).sum();
        o.timing_norm = SPS as f32 * acc;
        o
    }

    /// One symbol's carriers to `m` time samples.
    fn idft(&self, result: &mut [C32; M_MAX], vector: &[C32; NC2_MAX]) {
        let m = self.mode.m;
        let n = self.mode.nc + 2;
        let inv_m = 1.0 / m as f32;
        for row in 0..m {
            let mut c = cis(self.mode.nlower * self.doc * row as f32);
            let delta = cis(self.doc * row as f32);
            let mut acc = C32::ZERO;
            for v in vector[..n].iter() {
                acc = acc.add(v.mul(c));
                c = c.mul(delta);
            }
            result[row] = acc.scale(inv_m);
        }
    }

    /// `m` time samples to one symbol's carriers.
    fn dft(&self, result: &mut [C32; NC2_MAX], vector: &[C32]) {
        let m = self.mode.m;
        for col in 0..self.mode.nc + 2 {
            let delta = cis(-(self.mode.nlower + col as f32) * self.doc);
            let mut c = delta;
            let mut acc = vector[0];
            for v in vector[1..m].iter() {
                acc = acc.add(v.mul(c));
                c = c.mul(delta);
            }
            result[col] = acc;
        }
    }

    /// Conjugate pilot waveform shifted by `fcoarse` Hz (-40, 0 or +40).
    fn wvec_pilot(&self, fcoarse: i32) -> [C32; SPS] {
        let mut w = [C32::ZERO; SPS];
        let step = TAU * 40.0 / FS;
        for (j, o) in w.iter_mut().enumerate() {
            let wval = cis(-step * j as f32);
            *o = match fcoarse {
                -40 => wval.mul(self.pilot_samples[j]).conj(),
                40 => wval.mul(self.pilot_samples[j].conj()),
                _ => self.pilot_samples[j].conj(),
            };
        }
        w
    }

    /// Coarse frame timing on real samples: correlates with the pilot waveform at `i` and one
    /// frame later. Returns (position, normalised peak, valid).
    fn est_timing_real(&self, rx: &[f32], fcoarse: i32, step: usize) -> (usize, f32, bool) {
        let spf = self.mode.samples_per_frame();
        let ncorr = rx.len() - (spf + SPS);
        let acc: f32 = rx.iter().map(|v| v * v).sum();
        let av_level = 1.0 / (2.0 * libm::sqrtf(self.timing_norm * acc / rx.len() as f32) + 1e-12);
        let w = self.wvec_pilot(fcoarse);
        let mut timing_est = 0;
        let mut timing_mx = 0.0f32;
        let mut i = 0;
        while i < ncorr {
            let (mut sr, mut si, mut er, mut ei) = (0.0f32, 0.0f32, 0.0f32, 0.0f32);
            let a = &rx[i..i + SPS];
            let b = &rx[i + spf..i + spf + SPS];
            for j in 0..SPS {
                sr += a[j] * w[j].re;
                si += a[j] * w[j].im;
                er += b[j] * w[j].re;
                ei += b[j] * w[j].im;
            }
            let corr = (libm::sqrtf(sr * sr + si * si) + libm::sqrtf(er * er + ei * ei)) * av_level;
            if corr > timing_mx {
                timing_mx = corr;
                timing_est = i;
            }
            i += step;
        }
        let valid = libm::fabsf(rx[timing_est]) > 0.0 && timing_mx > self.mode.timing_mx_thresh;
        (timing_est, timing_mx, valid)
    }

    /// Frequency offset within +/-20 Hz of `fcoarse` by correlation with the pilot waveform.
    fn est_freq_offset_pilot_corr(&self, rx: &[f32], timing_est: usize, fcoarse: i32) -> f32 {
        let spf = self.mode.samples_per_frame();
        let wvec = self.wvec_pilot(fcoarse);
        let mut foff_est = 0.0f32;
        let mut cabs_max = 0.0f32;
        for f in -20..20 {
            let delta = cis(-TAU * f as f32 / FS);
            let mut w = C32::new(1.0, 0.0);
            let mut st = C32::ZERO;
            let mut en = C32::ZERO;
            for i in 0..SPS {
                let csam = wvec[i].mul(w);
                st = st.add(csam.scale(rx[timing_est + i]));
                en = en.add(csam.scale(rx[timing_est + i + spf]));
                w = w.mul(delta);
            }
            let c = cabs(st) + cabs(en);
            if c > cabs_max {
                cabs_max = c;
                foff_est = f as f32;
            }
        }
        foff_est
    }

    fn shift_in(&mut self, samples: &[i16]) {
        let nrxbuf = self.mode.nrxbuf();
        let nin = samples.len();
        debug_assert!(nin <= nrxbuf);
        self.rxbuf.copy_within(nin..nrxbuf, 0);
        for (d, s) in self.rxbuf[nrxbuf - nin..nrxbuf].iter_mut().zip(samples.iter()) {
            *d = *s as f32 / 32767.0;
        }
    }

    /// Looks for the start of a frame (`ofdm_sync_search_shorts`); `samples.len()` must be
    /// [`Ofdm::nin`]. Sets `timing_valid`, the coarse frequency estimate and the next `nin`.
    pub fn sync_search(&mut self, samples: &[i16]) -> bool {
        debug_assert_eq!(samples.len(), self.nin);
        self.shift_in(samples);
        let spf = self.mode.samples_per_frame();
        let st = spf + SPS;
        let en = st + 2 * spf + SPS;
        let mut fcoarse = 0;
        let mut timing_mx = 0.0f32;
        let mut ct_est = 0;
        let mut timing_valid = false;
        for af in [-40, 0, 40] {
            let (act_est, amx, avalid) = self.est_timing_real(&self.rxbuf[st..en], af, 2);
            if amx > timing_mx {
                ct_est = act_est;
                timing_mx = amx;
                fcoarse = af;
                timing_valid = avalid;
            }
        }
        self.coarse_foff_est_hz = self.est_freq_offset_pilot_corr(&self.rxbuf[st..en], ct_est, fcoarse) + fcoarse as f32;
        self.timing_valid = timing_valid;
        if timing_valid {
            self.nin = ct_est;
            self.sample_point = 0;
            self.timing_est = 0;
            self.foff_est_hz = self.coarse_foff_est_hz;
        } else {
            self.nin = spf;
        }
        self.timing_mx = timing_mx;
        timing_valid
    }

    /// `out[k] = rxbuf[st + k] * exp(-j woff (st + k))`.
    fn downconvert(&self, out: &mut [C32], st: usize, woff: f32) {
        let delta = cis(-woff);
        let mut c = cis(-woff * st as f32);
        for (k, o) in out.iter_mut().enumerate() {
            *o = c.scale(self.rxbuf[st + k]);
            c = c.mul(delta);
            if k & 63 == 63 {
                // keep the recurrence on the unit circle
                c = c.scale(1.0 / cabs(c));
            }
        }
    }

    /// Demodulates one modem frame (`ofdm_demod_shorts`); `samples.len()` must be [`Ofdm::nin`].
    /// Fills `rx_np`, `rx_amp` and returns the hard bits in `rx_bits`.
    pub fn demod(&mut self, rx_bits: &mut [u8; BITS_MAX], samples: &[i16]) {
        debug_assert_eq!(samples.len(), self.nin);
        self.shift_in(samples);
        let mode = self.mode;
        let spf = mode.samples_per_frame();
        let (nc, ns, m) = (mode.nc, mode.ns, mode.m);
        let prev_timing_est = self.timing_est;
        let woff_est = TAU * self.foff_est_hz / FS;

        // fine timing at the start of every frame
        {
            let ftw = mode.ftwindowwidth;
            let st = (SPS + spf - ftw / 2) as i32 + self.timing_est;
            let st = st.max(0) as usize;
            let len = spf - 1 + SPS + ftw;
            let ncorr = len - (spf + SPS);
            let acc: f32 = self.rxbuf[st..st + len].iter().map(|v| v * v).sum();
            let av_level = 1.0 / (2.0 * libm::sqrtf(self.timing_norm * acc / len as f32) + 1e-12);
            // the two stretches the correlation reads, frequency corrected
            let mut wa = [C32::ZERO; SPS + 80];
            let mut wb = [C32::ZERO; SPS + 80];
            let wl = ncorr + SPS;
            self.downconvert(&mut wa[..wl], st, woff_est);
            self.downconvert(&mut wb[..wl], st + spf, woff_est);
            let mut ft_est = 0usize;
            let mut mx = 0.0f32;
            for i in 0..ncorr {
                let mut cs = C32::ZERO;
                let mut ce = C32::ZERO;
                for j in 0..SPS {
                    let p = self.pilot_samples[j].conj();
                    cs = cs.add(wa[i + j].mul(p));
                    ce = ce.add(wb[i + j].mul(p));
                }
                let corr = (cabs(cs) + cabs(ce)) * av_level;
                if corr > mx {
                    mx = corr;
                    ft_est = i;
                }
            }
            self.timing_mx = mx;
            self.timing_valid = libm::fabsf(self.rxbuf[st + ft_est]) > 0.0 && mx > mode.timing_mx_thresh;
            self.timing_est += ft_est as i32 - ftw.div_ceil(2) as i32 + 1;
            self.sample_point = self.sample_point.max(self.timing_est + 4);
            self.sample_point = self.sample_point.min(self.timing_est + mode.ncp as i32 - 4);
        }

        // symbols to carriers: previous pilot, this frame with the next pilot, future pilot
        let mut work = [C32::ZERO; M_MAX];
        let base = (SPS as i32 + 1 + self.sample_point).max(0) as usize;
        let limit = mode.nrxbuf() - m;
        let mut row = [C32::ZERO; NC2_MAX];
        let grab = |this: &Self, st: usize, work: &mut [C32; M_MAX], row: &mut [C32; NC2_MAX]| {
            this.downconvert(&mut work[..m], st.min(limit), woff_est);
            this.dft(row, &work[..m]);
        };
        grab(self, base, &mut work, &mut row);
        self.rx_sym[0] = row;
        for rr in 0..=ns {
            grab(self, base + spf + rr * SPS, &mut work, &mut row);
            self.rx_sym[rr + 1] = row;
        }
        grab(self, base + 3 * spf, &mut work, &mut row);
        self.rx_sym[ns + 2] = row;

        // frequency error from the phase change between this pilot row and the next
        {
            let sum = |r: &[C32; NC2_MAX]| r[..nc + 2].iter().fold(C32::ZERO, |a, b| a.add(*b));
            let mut e = sum(&self.rx_sym[1]).conj().mul(sum(&self.rx_sym[ns + 1]));
            e.re += 1e-6;
            let mut freq_err_hz = libm::atan2f(e.im, e.re) * mode.rs / (TAU * ns as f32);
            if mode.foff_limiter {
                freq_err_hz = freq_err_hz.clamp(-1.0, 1.0);
            }
            self.foff_est_hz += self.foff_est_gain * freq_err_hz;
        }

        // phase and amplitude of each carrier from the pilots
        let mut phase = [C32::new(1.0, 0.0); NC2_MAX];
        let mut amp = [0.0f32; NC2_MAX];
        for i in 1..=nc {
            let rect = if self.low_bw {
                // three carriers by four pilot rows
                let mut a = C32::ZERO;
                for r in [1, ns + 1, 0, ns + 2] {
                    for j in i - 1..=i + 1 {
                        a = a.add(self.rx_sym[r][j].mul(self.pilots[j].conj()));
                    }
                }
                a.scale(1.0 / 12.0)
            } else {
                // this pilot row and the next only: follows fast fading
                let a = self.rx_sym[1][i].mul(self.pilots[i].conj());
                a.add(self.rx_sym[ns + 1][i].mul(self.pilots[i].conj())).scale(0.5)
            };
            let mag = cabs(rect);
            amp[i] = mag;
            // exp(-j arg(rect))
            phase[i] = if mag > 0.0 { rect.conj().scale(1.0 / mag) } else { C32::new(1.0, 0.0) };
        }

        let mut bit_index = 0;
        let mut sum_amp = 0.0f32;
        for rr in 0..mode.rows_per_frame() {
            for i in 1..=nc {
                let rx_corr = self.rx_sym[rr + 2][i].mul(phase[i]);
                self.rx_np[rr * nc + i - 1] = rx_corr;
                self.rx_amp[rr * nc + i - 1] = amp[i];
                sum_amp += amp[i];
                let b = qpsk_demod(rx_corr);
                rx_bits[bit_index] = b[0];
                rx_bits[bit_index + 1] = b[1];
                bit_index += 2;
            }
        }
        self.mean_amp = 0.9 * self.mean_amp + 0.1 * sum_amp / mode.syms_per_frame() as f32;

        // follow the sample clock: take a quarter symbol more or less next time
        self.nin = spf;
        self.clock_offset_counter += prev_timing_est - self.timing_est;
        let thresh = (SPS / 8) as i32;
        let tshift = (SPS / 4) as i32;
        if self.timing_est > thresh {
            self.nin = spf + tshift as usize;
            self.timing_est -= tshift;
            self.sample_point -= tshift;
        } else if self.timing_est < -thresh {
            self.nin = spf - tshift as usize;
            self.timing_est += tshift;
            self.sample_point += tshift;
        }
    }

    /// The unique word bits of the frame in `rx_np`.
    pub fn extract_uw(&self, rx_uw: &mut [u8; UW_MAX]) {
        for u in 0..self.mode.nuwbits / 2 {
            let b = qpsk_demod(self.rx_np[self.mode.uw_ind_sym(u)]);
            rx_uw[2 * u] = b[0];
            rx_uw[2 * u + 1] = b[1];
        }
    }

    /// Advances the sync state machine with this frame's unique word (all zeros is sent).
    pub fn sync_state_machine(&mut self, rx_uw: &[u8; UW_MAX]) {
        let mut next = self.sync_state;
        if self.sync_state == SyncState::Search && self.timing_valid {
            self.frame_count = 0;
            self.sync_counter = 0;
            self.clock_offset_counter = 0;
            next = SyncState::Trial;
        }
        if self.sync_state != SyncState::Search {
            self.frame_count += 1;
            self.uw_errors = rx_uw[..self.mode.nuwbits].iter().map(|&b| b as usize).sum();
            if self.mode.voice2 {
                if self.sync_state == SyncState::Trial {
                    next = if self.uw_errors <= self.mode.bad_uw_errors { SyncState::Synced } else { SyncState::Search };
                }
                if self.sync_state == SyncState::Synced {
                    if self.uw_errors > self.mode.bad_uw_errors {
                        self.sync_counter += 1;
                    } else {
                        self.sync_counter = 0;
                    }
                    if self.sync_counter == 6 {
                        next = SyncState::Search;
                    }
                }
            } else {
                if self.sync_state == SyncState::Trial {
                    if self.uw_errors > 2 {
                        self.sync_counter += 1;
                        self.frame_count = 0;
                    }
                    if self.sync_counter == 2 {
                        next = SyncState::Search;
                        self.low_bw = false;
                    }
                    if self.frame_count == 4 {
                        next = SyncState::Synced;
                        self.low_bw = true;
                    }
                }
                if self.sync_state == SyncState::Synced {
                    if self.uw_errors > 2 {
                        self.sync_counter += 1;
                    } else {
                        self.sync_counter = 0;
                    }
                    if self.sync_counter > 6 {
                        next = SyncState::Search;
                        self.low_bw = false;
                    }
                }
            }
        }
        self.last_sync_state = self.sync_state;
        self.sync_state = next;
    }

    /// Modulates one frame of `syms_per_frame()` data symbols (unique word and text symbols
    /// already in place) into `samples_per_frame()` complex samples, not yet scaled
    /// (`ofdm_txframe` without the clipper and band-pass filter).
    pub fn txframe(&self, tx: &mut [C32], tx_sym_lin: &[C32]) {
        let mode = self.mode;
        let mut sym = [C32::ZERO; M_MAX];
        let mut s = 0;
        for r in 0..mode.ns {
            let mut row = [C32::ZERO; NC2_MAX];
            if r == 0 {
                row = self.pilots;
            } else {
                for j in 1..=mode.nc {
                    row[j] = tx_sym_lin[s];
                    s += 1;
                }
            }
            self.idft(&mut sym, &row);
            let out = &mut tx[r * SPS..(r + 1) * SPS];
            out[..mode.ncp].copy_from_slice(&sym[mode.m - mode.ncp..mode.m]);
            out[mode.ncp..].copy_from_slice(&sym[..mode.m]);
        }
    }
}

/// Es/No in dB from the scatter of QPSK symbols around the axes (`ofdm_esno_est_calc`).
pub fn esno_est_calc(rx_sym: &[C32]) -> f32 {
    let n_all = rx_sym.len() as f32;
    let sig_var: f32 = rx_sym.iter().map(|s| s.norm_sqr()).sum::<f32>() / n_all;
    let sig_rms = libm::sqrtf(sig_var);
    let (mut sum_x, mut sum_xx, mut n) = (0.0f32, 0.0f32, 0.0f32);
    for s in rx_sym.iter() {
        if cabs(*s) > sig_rms {
            let v = if libm::fabsf(s.re) > libm::fabsf(s.im) { s.im } else { s.re };
            sum_x += v;
            sum_xx += v * v;
            n += 1.0;
        }
    }
    let noise_var = 2.0 * if n > 1.0 { (n * sum_xx - sum_x * sum_x) / (n * (n - 1.0)) } else { sig_var };
    10.0 * libm::log10f((1e-12 + sig_var) / (1e-12 + noise_var))
}

/// SNR in 3 kHz from Es/No (`ofdm_snr_from_esno`).
pub fn snr_from_esno(mode: &Mode, esno_db: f32) -> f32 {
    let cyclic_power = 10.0 * libm::log10f((mode.ncp + mode.m) as f32 / mode.m as f32);
    esno_db + 10.0 * libm::log10f(mode.nc as f32 * mode.rs / 3000.0) + cyclic_power
}

/// The payload bits of a test frame (`ofdm_generate_payload_data_bits`).
pub fn test_frame_bits(out: &mut [u8]) {
    let mut seed: u64 = 1;
    for o in out.iter_mut() {
        seed = (1103515245u64.wrapping_mul(seed) + 12345) % 32768;
        *o = (seed > 16384) as u8;
    }
}
