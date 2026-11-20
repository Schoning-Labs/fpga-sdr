// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Message packing, tone generation and waveform synthesis for the transmit side of FT8, FT4 and
//! WSPR, as audio PCM at 12 kHz.
//!
//! It has no FFT dependency, so it builds and runs under `no_std` plus `alloc` without any
//! feature, unlike `crate::decode` (see the crate-level documentation). All three modes share the
//! same shape: the operator's fields are packed into the WSJT or WSPR bit message, that becomes
//! a tone sequence, and the tones are synthesized to PCM samples at a chosen audio carrier
//! frequency. The 48 ksps complex baseband that actually feeds the TX ring is in `crate::txbb`.

use alloc::vec::Vec;

/// FT8: 15 s slot, 12 kHz sample rate, 79 tone symbols.
#[cfg(feature = "ft8")]
pub mod ft8 {
    use super::Vec;
    use mfsk_core::ft8::wave_gen::{message_to_tones, tones_to_i16};
    use mfsk_core::msg::wsjt77::pack77;

    /// Encodes a standard 3-field WSJT 77-bit message (e.g. `("CQ", "JA1ABC", "PM95")` or
    /// `("JA1ABC", "K1JT", "R-09")`) to 12 kHz i16 PCM with tone 0 at `freq_hz` audio frequency.
    /// Returns `None` if the fields do not pack into a standard 77-bit message.
    pub fn encode_i16(f1: &str, f2: &str, f3: &str, freq_hz: f32, amplitude: i16) -> Option<Vec<i16>> {
        let msg77 = pack77(f1, f2, f3)?;
        let tones = message_to_tones(&msg77);
        Some(tones_to_i16(&tones, freq_hz, amplitude))
    }
}

/// FT4: 7.5 s slot, 12 kHz sample rate, 105 tone symbols.
#[cfg(feature = "ft4")]
pub mod ft4 {
    use super::Vec;
    use mfsk_core::ft4::encode::{message_to_tones, tones_to_i16};
    use mfsk_core::msg::wsjt77::pack77;

    /// Same contract as `super::ft8::encode_i16`, for FT4.
    pub fn encode_i16(f1: &str, f2: &str, f3: &str, freq_hz: f32, amplitude: i16) -> Option<Vec<i16>> {
        let msg77 = pack77(f1, f2, f3)?;
        let tones = message_to_tones(&msg77);
        Some(tones_to_i16(&tones, freq_hz, amplitude))
    }
}

/// WSPR: about 110.6 s of a 120 s slot, 12 kHz sample rate, 162 tone symbols.
#[cfg(feature = "wspr")]
pub mod wspr {
    use super::Vec;

    /// Encodes a WSPR Type-1 message (callsign, 4-character grid, power in dBm) to 12 kHz f32 PCM
    /// at `freq_hz` audio frequency. Returns `None` if the fields do not fit the Type-1 layout
    /// (a non-standard callsign, for example).
    pub fn encode_f32(callsign: &str, grid: &str, power_dbm: i32, freq_hz: f32, amplitude: f32) -> Option<Vec<f32>> {
        mfsk_core::wspr::tx::synthesize_type1(callsign, grid, power_dbm, 12_000, freq_hz, amplitude)
    }
}

#[cfg(all(test, feature = "ft8"))]
mod tests {
    use super::ft8;

    #[test]
    fn ft8_encode_produces_full_slot_length() {
        // 79 symbols x 1920 samples/symbol (NSPS @ 12 kHz) = 151_680.
        let pcm = ft8::encode_i16("CQ", "JA1ABC", "PM95", 1500.0, 20_000).expect("valid message");
        assert_eq!(pcm.len(), mfsk_core::ft8::wave_gen::TONES_OUTPUT_LEN);
    }
}
