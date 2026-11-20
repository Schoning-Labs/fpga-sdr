// SPDX-License-Identifier: LGPL-2.1-only
//
// Rust translation of parts of Codec 2 release 1.2.0 (https://github.com/drowe67/codec2):
// src/freedv_700.c (freedv_ofdm_voice_open, freedv_comptx_ofdm, freedv_comp_short_rx_ofdm),
// src/freedv_api.c (freedv_bits_to_speech), src/interldpc.c (ofdm_ldpc_interleave_tx),
// src/ofdm.c (packet assembly and disassembly, ofdm_get_demod_stats).
// Copyright (C) 2014-2020 David Rowe. All rights reserved.
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

//! `tr-freedv`: FreeDV **700D** and **700E** digital voice in `no_std` Rust, no heap. A
//! translation of the reference implementation in David Rowe's codec2; see `NOTICE` and
//! `docs/FREEDV.md`.
//!
//! - [`Rx`]: 8 kHz modem audio in, 8 kHz speech out, with sync, SNR, frequency offset and error
//!   indicators ([`RxStats`]). [`RxStream`] wraps it for callers that hand over audio in blocks
//!   of any size.
//! - [`Tx`]: codec bits or speech to 8 kHz modem audio. The interface transmit will use; today
//!   the tests use it (no clipper or band-pass filter yet).
//! - [`resample`]: 12 kHz to 8 kHz and back up, for the radio's audio rates.

#![no_std]

pub mod ldpc;
pub mod ldpc_tables;
pub mod ofdm;
mod phi_table;
pub mod resample;
pub mod varicode;

use core::mem::MaybeUninit;
use core::ptr::addr_of_mut;
use ldpc::{DecodeInfo, MAX_CODE};
use ofdm::{Mode, Ofdm, SyncState, BITS_MAX, SPS, SYMS_MAX, UW_MAX};
use tr_codec2::{Decoder700c, Encoder700c, C32, SAMPLES_PER_FRAME};

pub use ofdm::{MODE_700D, MODE_700E};

/// Most speech samples one modem frame decodes to (700D: four 40 ms codec frames).
pub const MAX_SPEECH: usize = 4 * SAMPLES_PER_FRAME;
/// Most modem samples [`Rx::rx`] asks for in one call.
pub const MAX_NIN: usize = ofdm::SPF_MAX + SPS / 4;
/// Bits of one codec frame.
const CODEC_BITS: usize = tr_codec2::BITS_PER_FRAME;

/// What one receive call found (`rx_status` flags upstream).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RxStatus {
    /// The modem is in sync (trial or solid).
    pub sync: bool,
    /// Sync is not confirmed yet.
    pub trial_sync: bool,
    /// A frame of payload bits was decoded in this call.
    pub bits: bool,
    /// The error correction did not converge on a codeword: the frame has bit errors.
    pub bit_errors: bool,
    /// Speech was decoded into the output (otherwise the output is silence or pass-through).
    pub speech: bool,
}

/// Indicators for the operator, updated by every [`Rx::rx`] call.
#[derive(Clone, Copy, Debug)]
pub struct RxStats {
    pub sync_state: SyncState,
    /// Signal to noise ratio in 3 kHz, dB, smoothed (fast up, slow down); -5 while searching.
    pub snr_db: f32,
    /// Frequency offset of the signal from the nominal 1,500 Hz centre, Hz.
    pub foff_hz: f32,
    /// Unique word bits wrong in the last frame.
    pub uw_errors: usize,
    /// Iterations and satisfied parity checks of the last error correction run.
    pub ldpc: DecodeInfo,
    /// Frames decoded since start; frames among them whose error correction did not converge.
    pub frames: u32,
    pub frames_with_errors: u32,
    /// Normalised height of the frame timing correlation peak (0..1).
    pub sync_metric: f32,
    /// Sample clock offset of the sender against ours, as a fraction (1e-4 = 100 ppm).
    pub clock_offset: f32,
    /// Test frames only: payload bit errors before and after error correction, and bits counted.
    pub test_raw_errors: u32,
    pub test_raw_bits: u32,
    pub test_coded_errors: u32,
    pub test_coded_bits: u32,
}

/// FreeDV 700D / 700E receiver.
pub struct Rx {
    pub ofdm: Ofdm,
    ldpc: ldpc::Decoder,
    codec: Decoder700c,
    stats: RxStats,
    /// The smoothed SNR estimate. Upstream keeps it in its stats struct, starting at 0, and does
    /// not reset it while searching (only the displayed value is -5 then).
    snr_smooth: f32,
    /// Mute the speech when the SNR is below `snr_squelch_db`, and on unconfirmed sync unless
    /// the frame is error free (upstream's rule).
    pub squelch: bool,
    pub snr_squelch_db: f32,
    /// Without sync and without squelch, pass the received audio through at this gain
    /// (0 = silence; upstream uses 0.25 so the operator hears what is being tuned).
    pub passthrough_gain: f32,
    /// The sender sends test frames: count bit errors, decode no speech.
    pub test_frames: bool,
    /// Decoded payload bits of the last frame (one bit per byte), for callers that want them.
    pub payload_bits: [u8; MAX_CODE / 2],
    /// The text channel bits of the last frame (not decoded here).
    pub txt_bits: [u8; 4],
}

impl Rx {
    /// A receiver for `mode`. It builds the 37 KB struct on the stack and copies it; on the target
    /// use [`Rx::init`], which builds it where it is to live.
    pub fn new(mode: &'static Mode) -> Self {
        let mut slot = MaybeUninit::<Self>::uninit();
        Self::init(&mut slot, mode);
        // SAFETY: `init` initialised the whole struct.
        unsafe { slot.assume_init() }
    }

    /// Builds the receiver in `slot` itself, each part in place, so the stack holds none of the
    /// 37 KB at any time (the largest temporary is the 4 KB table of the speech decoder's FFT
    /// being filled, which is also written in place).
    pub fn init<'a>(slot: &'a mut MaybeUninit<Self>, mode: &'static Mode) -> &'a mut Self {
        let p = slot.as_mut_ptr();
        // SAFETY: every field is written through a raw pointer to it; none is read or referenced
        // before it is written, and `assume_init_mut` comes after the last write.
        unsafe {
            Ofdm::init(&mut *(addr_of_mut!((*p).ofdm) as *mut MaybeUninit<Ofdm>), mode);
            ldpc::Decoder::init(&mut *(addr_of_mut!((*p).ldpc) as *mut MaybeUninit<ldpc::Decoder>));
            Decoder700c::init(&mut *(addr_of_mut!((*p).codec) as *mut MaybeUninit<Decoder700c>));
            addr_of_mut!((*p).stats).write(RxStats {
                sync_state: SyncState::Search,
                snr_db: -5.0,
                foff_hz: 0.0,
                uw_errors: 0,
                ldpc: DecodeInfo::default(),
                frames: 0,
                frames_with_errors: 0,
                sync_metric: 0.0,
                clock_offset: 0.0,
                test_raw_errors: 0,
                test_raw_bits: 0,
                test_coded_errors: 0,
                test_coded_bits: 0,
            });
            addr_of_mut!((*p).snr_smooth).write(0.0);
            addr_of_mut!((*p).squelch).write(false);
            addr_of_mut!((*p).snr_squelch_db).write(0.0);
            addr_of_mut!((*p).passthrough_gain).write(0.0);
            addr_of_mut!((*p).test_frames).write(false);
            addr_of_mut!((*p).payload_bits).write([0; MAX_CODE / 2]);
            addr_of_mut!((*p).txt_bits).write([0; 4]);
            slot.assume_init_mut()
        }
    }

    pub fn mode(&self) -> &'static Mode {
        self.ofdm.mode
    }

    /// Modem samples the next [`Rx::rx`] call must be given (it changes from call to call, and
    /// can be 0).
    pub fn nin(&self) -> usize {
        self.ofdm.nin
    }

    /// Speech samples a decoded modem frame gives.
    pub fn speech_per_frame(&self) -> usize {
        self.codec_frames() * SAMPLES_PER_FRAME
    }

    fn codec_frames(&self) -> usize {
        self.ofdm.mode.code.data_bits() / CODEC_BITS
    }

    pub fn stats(&self) -> &RxStats {
        &self.stats
    }

    /// One receive step: exactly [`Rx::nin`] samples of 8 kHz modem audio in; returns the status
    /// and how many 8 kHz samples were written to `speech_out`.
    pub fn rx(&mut self, demod_in: &[i16], speech_out: &mut [i16; MAX_NIN]) -> (RxStatus, usize) {
        let mode = self.ofdm.mode;
        let code = mode.code;
        let mut status = RxStatus::default();
        let mut rx_uw = [0u8; UW_MAX];

        if self.ofdm.sync_state == SyncState::Search {
            self.ofdm.sync_search(demod_in);
            self.stats.snr_db = -5.0;
        } else {
            status.sync = true;
            status.trial_sync = self.ofdm.sync_state == SyncState::Trial;
            let mut rx_bits = [0u8; BITS_MAX];
            self.ofdm.demod(&mut rx_bits, demod_in);
            self.ofdm.extract_uw(&mut rx_uw);

            // take the unique word out, undo the interleaver, decode
            let nsyms = mode.syms_per_frame();
            let ntxtsyms = mode.ntxtbits / 2;
            let npayload = code.code_length / 2;
            let mut syms = [C32::ZERO; SYMS_MAX];
            let mut amps = [0.0f32; SYMS_MAX];
            let (mut p, mut u) = (0, 0);
            for s in 0..nsyms - ntxtsyms {
                if u < mode.nuwbits / 2 && s == mode.uw_ind_sym(u) {
                    u += 1;
                } else {
                    syms[p] = self.ofdm.rx_np[s];
                    amps[p] = self.ofdm.rx_amp[s];
                    p += 1;
                }
            }
            debug_assert_eq!(p, npayload);
            for t in 0..ntxtsyms {
                let b = ofdm::qpsk_demod(self.ofdm.rx_np[nsyms - ntxtsyms + t]);
                self.txt_bits[2 * t] = b[0];
                self.txt_bits[2 * t + 1] = b[1];
            }
            let mut syms_de = [C32::ZERO; SYMS_MAX];
            let mut amps_de = [0.0f32; SYMS_MAX];
            ldpc::deinterleave(&mut syms_de[..npayload], &syms[..npayload], code.interleaver_b);
            ldpc::deinterleave(&mut amps_de[..npayload], &amps[..npayload], code.interleaver_b);
            let mut llr = [0.0f32; MAX_CODE];
            // Es/No fixed at 3 as upstream ("further work: estimate this properly from signal")
            ldpc::symbols_to_llrs(&mut llr[..2 * npayload], &syms_de[..npayload], &amps_de[..npayload], 3.0, self.ofdm.mean_amp);
            let mut codeword = [0u8; MAX_CODE];
            let info = self.ldpc.decode(code, &llr, &mut codeword);
            let k = code.data_bits();
            self.payload_bits[..k].copy_from_slice(&codeword[..k]);
            status.bits = true;
            status.bit_errors = info.parity_checks != code.parity_bits;
            self.stats.ldpc = info;
            self.stats.frames += 1;
            self.stats.frames_with_errors += status.bit_errors as u32;

            if self.test_frames {
                let mut data = [0u8; MAX_CODE / 2];
                ofdm::test_frame_bits(&mut data[..k]);
                let mut parity = [0u8; MAX_CODE / 2];
                ldpc::encode(code, &data[..k], &mut parity[..code.parity_bits]);
                for i in 0..npayload {
                    let b = ofdm::qpsk_demod(syms_de[i]);
                    for j in 0..2 {
                        let n = 2 * i + j;
                        let want = if n < k { data[n] } else { parity[n - k] };
                        self.stats.test_raw_errors += (b[j] != want) as u32;
                    }
                }
                // upstream also counts the unique word bits (all zero when sent) in this figure
                self.stats.test_raw_errors += rx_uw[..mode.nuwbits].iter().filter(|&&b| b != 0).count() as u32;
                self.stats.test_raw_bits += (code.code_length + mode.nuwbits) as u32;
                for i in 0..k {
                    self.stats.test_coded_errors += (data[i] != self.payload_bits[i]) as u32;
                }
                self.stats.test_coded_bits += k as u32;
            }

            // SNR from the scatter of all symbols of the frame; fast attack, slow decay
            let snr = ofdm::snr_from_esno(mode, ofdm::esno_est_calc(&self.ofdm.rx_np[..nsyms]));
            self.snr_smooth = if snr > self.snr_smooth { snr } else { 0.9 * self.snr_smooth + 0.1 * snr };
            self.stats.snr_db = self.snr_smooth;
        }

        let nin_prev = demod_in.len();
        self.ofdm.sync_state_machine(&rx_uw);

        self.stats.sync_state = self.ofdm.sync_state;
        self.stats.foff_hz = self.ofdm.foff_est_hz;
        self.stats.uw_errors = self.ofdm.uw_errors;
        self.stats.sync_metric = self.ofdm.timing_mx;
        let total = (self.ofdm.frame_count * mode.samples_per_frame()) as f32;
        self.stats.clock_offset = if total != 0.0 { self.ofdm.clock_offset_counter as f32 / total } else { 0.0 };

        // speech, silence or pass-through (freedv_bits_to_speech)
        let mut nout = 0;
        if !status.sync {
            nout = nin_prev;
            let g = if self.squelch { 0.0 } else { self.passthrough_gain };
            for (o, s) in speech_out.iter_mut().zip(demod_in.iter()) {
                *o = (g * *s as f32) as i16;
            }
        }
        if status.sync && status.bits {
            let decode = if self.test_frames {
                false
            } else if !self.squelch {
                true
            } else if status.trial_sync {
                !status.bit_errors
            } else {
                self.stats.snr_db > self.snr_squelch_db
            };
            nout = self.speech_per_frame();
            if decode {
                for i in 0..self.codec_frames() {
                    let mut bytes = [0u8; tr_codec2::BYTES_PER_FRAME];
                    for (n, &b) in self.payload_bits[i * CODEC_BITS..(i + 1) * CODEC_BITS].iter().enumerate() {
                        bytes[n >> 3] |= (b & 1) << (7 - (n & 7));
                    }
                    let out: &mut [i16; SAMPLES_PER_FRAME] =
                        (&mut speech_out[i * SAMPLES_PER_FRAME..(i + 1) * SAMPLES_PER_FRAME]).try_into().unwrap();
                    self.codec.decode(&bytes, out);
                }
                status.speech = true;
            } else {
                speech_out[..nout].fill(0);
            }
        }
        (status, nout)
    }
}

/// [`Rx`] behind a small queue, for audio that arrives in blocks of any size.
pub struct RxStream {
    pub rx: Rx,
    fifo: [i16; MAX_NIN],
    fill: usize,
    /// Status of the last receive step.
    pub last: RxStatus,
}

impl RxStream {
    pub fn new(mode: &'static Mode) -> Self {
        let mut slot = MaybeUninit::<Self>::uninit();
        Self::init(&mut slot, mode);
        // SAFETY: `init` initialised the whole struct.
        unsafe { slot.assume_init() }
    }

    /// Builds the stream in `slot` itself, as [`Rx::init`].
    pub fn init<'a>(slot: &'a mut MaybeUninit<Self>, mode: &'static Mode) -> &'a mut Self {
        let p = slot.as_mut_ptr();
        // SAFETY: as in `Rx::init`: all fields written through raw pointers.
        unsafe {
            Rx::init(&mut *(addr_of_mut!((*p).rx) as *mut MaybeUninit<Rx>), mode);
            addr_of_mut!((*p).fifo).write([0; MAX_NIN]);
            addr_of_mut!((*p).fill).write(0);
            addr_of_mut!((*p).last).write(RxStatus::default());
            slot.assume_init_mut()
        }
    }

    /// Feeds 8 kHz modem audio; `sink` gets every block of 8 kHz output audio as it is ready.
    pub fn push(&mut self, mut samples: &[i16], mut sink: impl FnMut(&[i16], RxStatus)) {
        let mut out = [0i16; MAX_NIN];
        loop {
            let nin = self.rx.nin();
            let take = (nin - self.fill).min(samples.len());
            self.fifo[self.fill..self.fill + take].copy_from_slice(&samples[..take]);
            self.fill += take;
            samples = &samples[take..];
            if self.fill < nin {
                return;
            }
            let (status, n) = self.rx.rx(&self.fifo[..nin], &mut out);
            self.fill = 0;
            self.last = status;
            sink(&out[..n], status);
        }
    }
}

/// FreeDV 700D / 700E modulator: the interface transmit will use (speech source, clipper and
/// band-pass filter still to come; see docs/FREEDV.md).
pub struct Tx {
    ofdm: Ofdm,
    codec: Encoder700c,
    /// Peak level of the output; the waveform is clipped here.
    pub peak: f32,
}

impl Tx {
    pub fn new(mode: &'static Mode) -> Self {
        Self { ofdm: Ofdm::new(mode), codec: Encoder700c::new(), peak: ofdm::OFDM_PEAK }
    }

    /// The codec's transmit equaliser (`freedv_set_eq`; off by default as upstream).
    pub fn set_eq(&mut self, on: bool) {
        self.codec.eq = on;
    }

    pub fn mode(&self) -> &'static Mode {
        self.ofdm.mode
    }

    pub fn samples_per_frame(&self) -> usize {
        self.ofdm.mode.samples_per_frame()
    }

    pub fn speech_per_frame(&self) -> usize {
        self.ofdm.mode.code.data_bits() / CODEC_BITS * SAMPLES_PER_FRAME
    }

    /// One modem frame from payload bits (one bit per byte, `code.data_bits()` of them) and the
    /// text channel bits.
    pub fn tx_bits(&self, payload: &[u8], txt_bits: &[u8], out: &mut [i16]) {
        let mode = self.ofdm.mode;
        let code = mode.code;
        let k = code.data_bits();
        let npayload = code.code_length / 2;
        let mut codeword = [0u8; MAX_CODE];
        codeword[..k].copy_from_slice(&payload[..k]);
        let (data, parity) = codeword.split_at_mut(k);
        ldpc::encode(code, data, &mut parity[..code.parity_bits]);
        let mut syms = [C32::ZERO; SYMS_MAX];
        for i in 0..npayload {
            syms[i] = ofdm::qpsk_mod(codeword[2 * i], codeword[2 * i + 1]);
        }
        let mut inter = [C32::ZERO; SYMS_MAX];
        ldpc::interleave(&mut inter[..npayload], &syms[..npayload], code.interleaver_b);
        // unique word (all zero bits), payload, text
        let nsyms = mode.syms_per_frame();
        let ntxtsyms = mode.ntxtbits / 2;
        let mut packet = [C32::ZERO; SYMS_MAX];
        let (mut p, mut u) = (0, 0);
        for s in 0..nsyms - ntxtsyms {
            if u < mode.nuwbits / 2 && s == mode.uw_ind_sym(u) {
                packet[s] = ofdm::qpsk_mod(0, 0);
                u += 1;
            } else {
                packet[s] = inter[p];
                p += 1;
            }
        }
        for t in 0..ntxtsyms {
            let b0 = txt_bits.get(2 * t).copied().unwrap_or(0);
            let b1 = txt_bits.get(2 * t + 1).copied().unwrap_or(0);
            packet[nsyms - ntxtsyms + t] = ofdm::qpsk_mod(b0, b1);
        }
        let mut tx = [C32::ZERO; ofdm::SPF_MAX];
        let spf = mode.samples_per_frame();
        self.ofdm.txframe(&mut tx[..spf], &packet[..nsyms]);
        for (o, t) in out[..spf].iter_mut().zip(tx.iter()) {
            *o = (t.re * mode.amp_scale).clamp(-self.peak, self.peak) as i16;
        }
    }

    /// One modem frame of test bits known to the receiver.
    pub fn tx_test_frame(&self, out: &mut [i16]) {
        let mut data = [0u8; MAX_CODE / 2];
        let k = self.ofdm.mode.code.data_bits();
        ofdm::test_frame_bits(&mut data[..k]);
        self.tx_bits(&data[..k], &[], out);
    }

    /// One modem frame from [`Tx::speech_per_frame`] samples of 8 kHz speech.
    pub fn tx_speech(&mut self, speech: &[i16], out: &mut [i16]) {
        let mut data = [0u8; MAX_CODE / 2];
        for (i, frame) in speech.chunks_exact(SAMPLES_PER_FRAME).enumerate() {
            let bytes = self.codec.encode(frame.try_into().unwrap());
            for n in 0..CODEC_BITS {
                data[i * CODEC_BITS + n] = (bytes[n >> 3] >> (7 - (n & 7))) & 1;
            }
        }
        self.tx_bits(&data, &[], out);
    }
}
