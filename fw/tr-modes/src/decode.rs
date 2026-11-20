// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Decode side (RX) for FT8, FT4 and WSPR: thin wrappers around mfsk-core's `DecodeRequest`, one
//! submodule per mode, all returning the same [`Decoded`] shape.
//!
//! These are the software decoders that run on the CPU (or on a PC) and are the reference the
//! FPGA decoder engines are compared against, see `crate::frontend`. They need an FFT backend,
//! which is either `crate::fft` (feature `fft-portable`, on by default, `no_std`-capable) or
//! mfsk-core's SIMD-accelerated, `std`-only `rustfft` (feature `fft-rustfft`, kept only for the
//! host-side timing comparison in docs/S5_MODES.md, whose "no_std FFT backend" section also gives
//! the recall difference between the two).

use alloc::string::String;
use alloc::vec::Vec;

/// One decoded message, in the shape every mode below returns it.
#[derive(Debug, Clone)]
pub struct Decoded {
    /// Unpacked message text, e.g. `CQ JA1ABC PM95`.
    pub message: String,
    /// Audio frequency of tone 0, Hz.
    pub freq_hz: f32,
    /// Time offset of the signal from the nominal slot start, seconds.
    pub dt_sec: f32,
    /// Signal to noise ratio in dB (WSJT-X convention, 2500 Hz reference bandwidth), or `None`
    /// for decoders that do not report one (the WSPR wrapper here).
    pub snr_db: Option<f32>,
}

/// FT8: `audio` must be 180_000 i16 samples (15 s at 12 kHz), aligned to the slot.
#[cfg(feature = "ft8")]
pub mod ft8 {
    use super::{Decoded, Vec};
    use mfsk_core::ft8::Ft8;
    use mfsk_core::ft8::decode::WsjtxDepth;
    use mfsk_core::msg::decode_request::DecodeRequest;
    use mfsk_core::msg::wsjt77::unpack77;

    /// Decodes one FT8 slot. `freq_min_hz` and `freq_max_hz` are the audio-band search window,
    /// `sync_min` is the coarse-sync score floor (WSJT-X "Deep" uses 1.3) and `max_cand` is the
    /// candidate budget per slot.
    ///
    /// Uses `DecodeRequest::wsjtx_depth(.., WsjtxDepth::D3, None)`, which mirrors the decode
    /// ladder of WSJT-X's `jt9 -d3` (OSD on, staged successive interference cancellation) and is
    /// the depth the crate's WSJT-X-sample golden tests compare against. The plain single-pass
    /// `DecodeRequest::new` builder (no OSD) is what a lean embedded configuration would use
    /// instead, see docs/S5_MODES.md for the difference in recall this makes on `qso3_busy.wav`.
    pub fn decode_slot(audio: &[i16], freq_min_hz: f32, freq_max_hz: f32, sync_min: f32, max_cand: usize) -> Vec<Decoded> {
        DecodeRequest::<Ft8>::wsjtx_depth(audio, freq_min_hz, freq_max_hz, sync_min, max_cand, WsjtxDepth::D3, None)
            .decode()
            .results
            .into_iter()
            .filter_map(|r| {
                unpack77(r.message77()).map(|message| Decoded {
                    message,
                    freq_hz: r.freq_hz,
                    dt_sec: r.dt_sec,
                    snr_db: Some(r.snr_db),
                })
            })
            .collect()
    }

    /// The plain single-pass builder (no OSD, no SIC), which is WSJT-X's lightest decode setting
    /// and roughly equal to `jt9 -d1`. `decode_slot` does not use it because it needs OSD to reach
    /// WSJT-X-matching recall, but it is useful on its own for the sensitivity sweep in
    /// `src/bin/sensitivity_sweep.rs` (which wants a fast, deterministic decode at a known
    /// frequency rather than the wide-band, recall-maximizing one) and for reporting a "lightest
    /// setting" timing figure next to the default, see docs/S5_MODES.md "decode cost per slot".
    pub fn decode_slot_light(audio: &[i16], freq_min_hz: f32, freq_max_hz: f32, sync_min: f32, max_cand: usize) -> Vec<Decoded> {
        DecodeRequest::<Ft8>::new(audio, freq_min_hz, freq_max_hz, sync_min, max_cand)
            .decode()
            .results
            .into_iter()
            .filter_map(|r| {
                unpack77(r.message77()).map(|message| Decoded {
                    message,
                    freq_hz: r.freq_hz,
                    dt_sec: r.dt_sec,
                    snr_db: Some(r.snr_db),
                })
            })
            .collect()
    }
}

/// FT4: `audio` must be 90_000 i16 samples (7.5 s at 12 kHz), aligned to the slot.
#[cfg(feature = "ft4")]
pub mod ft4 {
    use super::{Decoded, Vec};
    use mfsk_core::ft4::Ft4;
    use mfsk_core::msg::decode_request::DecodeRequest;
    use mfsk_core::msg::wsjt77::unpack77;

    /// Same contract as `super::ft8::decode_slot`, for FT4. Runs 3 rounds of successive
    /// interference cancellation (`sic_rounds(3)`), the same setting mfsk-core's own
    /// `ft4_wsjtx_samples.rs` golden test uses to reach full recall parity with a real `jt9` run.
    pub fn decode_slot(audio: &[i16], freq_min_hz: f32, freq_max_hz: f32, sync_min: f32, max_cand: usize) -> Vec<Decoded> {
        DecodeRequest::<Ft4>::new(audio, freq_min_hz, freq_max_hz, sync_min, max_cand)
            .sic_rounds(3)
            .decode()
            .results
            .into_iter()
            .filter_map(|r| {
                unpack77(r.message77()).map(|message| Decoded {
                    message,
                    freq_hz: r.freq_hz,
                    dt_sec: r.dt_sec,
                    snr_db: Some(r.snr_db),
                })
            })
            .collect()
    }

    /// The FT4 counterpart of `super::ft8::decode_slot_light`: no `sic_rounds`, single pass.
    pub fn decode_slot_light(audio: &[i16], freq_min_hz: f32, freq_max_hz: f32, sync_min: f32, max_cand: usize) -> Vec<Decoded> {
        DecodeRequest::<Ft4>::new(audio, freq_min_hz, freq_max_hz, sync_min, max_cand)
            .decode()
            .results
            .into_iter()
            .filter_map(|r| {
                unpack77(r.message77()).map(|message| Decoded {
                    message,
                    freq_hz: r.freq_hz,
                    dt_sec: r.dt_sec,
                    snr_db: Some(r.snr_db),
                })
            })
            .collect()
    }
}

/// WSPR: `audio` is f32 PCM at 12 kHz, one 120 s slot (about 1.44 million samples).
#[cfg(feature = "wspr")]
pub mod wspr {
    use super::{Decoded, Vec};
    use alloc::string::ToString;
    use mfsk_core::wspr::decode::decode_scan;
    pub use mfsk_core::wspr::SearchParams;

    /// Wide-band scan of one WSPR slot with the given search parameters (`SearchParams::default()`
    /// is a reasonable starting point). `nominal_start_sample` is normally 0 for a single isolated
    /// slot.
    pub fn decode_slot(audio: &[f32], sample_rate: u32, nominal_start_sample: usize, params: &SearchParams) -> Vec<Decoded> {
        decode_scan(audio, sample_rate, nominal_start_sample, params)
            .into_iter()
            .map(|r| Decoded {
                message: r.message.to_string(),
                freq_hz: r.freq_hz,
                dt_sec: r.dt_sec,
                snr_db: None,
            })
            .collect()
    }
}
