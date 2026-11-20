// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
//! State of the FreeDV screen (`ui/fdv_view.slint`, docs/FREEDV.md section 9) as plain Rust, and
//! what the operator can ask for. No radio logic lives here: the station (`tr-station`) fills an
//! `FdvScreenState` and consumes `FdvEvent`s, and the glue in src/lib.rs moves both between this
//! module and the Slint window.
//!
//! The screen shows the modem's sync state, SNR, frequency offset and error counters, the text
//! channel of the sender, and a waterfall window where the picture comes either from the zoom
//! receiver in the FPGA or from the software waterfall. `WfAxis` maps audio frequency to window
//! pixels for both, so the scale marks and the signal marker land on the right column.

extern crate alloc;

use alloc::format;
use alloc::string::String;
use alloc::vec::Vec;

/// Width of the waterfall window in pixels (`ft8::WATERFALL_RECT`).
pub const WINDOW_PX: u32 = 1_172;
/// Window pixel that shows the middle of the zoom receiver's line (half of `WINDOW_PX`).
pub const ZOOM_CENTRE_PX: u32 = 586;
/// Hz per pixel of the zoom receiver's 6 kHz span over 1,920 columns.
pub const ZOOM_HZ_PER_PX: f32 = 3.125;

/// Centers of the controls (x, y in pixels), for the host tests to click by position.
pub const MODE_D_AT: (u32, u32) = (102, 906);
pub const MODE_E_AT: (u32, u32) = (254, 906);
pub const SQUELCH_AT: (u32, u32) = (474, 906);
pub const SQUELCH_DOWN_AT: (u32, u32) = (659, 906);
pub const SQUELCH_UP_AT: (u32, u32) = (911, 906);
pub const TUNE_DOWN_AT: (u32, u32) = (132, 1_006);
pub const TUNE_UP_AT: (u32, u32) = (344, 1_006);
/// The "< FT8" button of this screen, and the "FreeDV >" button of the FT8 screen.
pub const TO_FT8_AT: (u32, u32) = (214, 44);
pub const TO_FREEDV_AT: (u32, u32) = (153, 59);
/// The "LISTEN" button of the FT8 screen, and of this screen.
pub const FT8_TO_LISTEN_AT: (u32, u32) = (223, 59);
pub const TO_LISTEN_AT: (u32, u32) = (740, 44);

/// What the operator did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FdvEvent {
    /// Index into the band buttons.
    BandSelect(usize),
    /// 700D (`false`) or 700E (`true`).
    SelectE(bool),
    SquelchToggle,
    /// Change of the squelch SNR threshold, in dB steps.
    SquelchStep(i32),
    /// Change of the dial frequency, in Hz.
    Tune(i32),
    /// Go to the FT8 screen.
    SwitchToFt8,
    /// Go to the LISTEN screen.
    SwitchToListen,
}

/// Where in the waterfall window which audio frequency is.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct WfAxis {
    /// Audio frequency at the window's left edge, Hz.
    pub left_hz: f32,
    /// Audio Hz per pixel; negative when audio frequency falls from left to right (the zoom
    /// receiver's picture is in RF order, so the lower sideband is mirrored).
    pub hz_per_px: f32,
    /// Text shown under the waterfall to say which picture and scale this is.
    pub note: &'static str,
}

impl WfAxis {
    /// The zoom receiver's 6 kHz span centered on 1,500 Hz of audio.
    pub fn zoom(lower_sideband: bool) -> WfAxis {
        let half = ZOOM_CENTRE_PX as f32 * ZOOM_HZ_PER_PX;
        if lower_sideband {
            WfAxis { left_hz: 1_500.0 + half, hz_per_px: -ZOOM_HZ_PER_PX, note: "zoom, 3.1 Hz per pixel, RF order" }
        } else {
            WfAxis { left_hz: 1_500.0 - half, hz_per_px: ZOOM_HZ_PER_PX, note: "zoom, 3.1 Hz per pixel" }
        }
    }

    /// The software waterfall: 0 to 3,000 Hz of audio across the window.
    pub fn software() -> WfAxis {
        WfAxis { left_hz: 0.0, hz_per_px: 3_000.0 / WINDOW_PX as f32, note: "software, audio 0 to 3,000 Hz" }
    }

    /// Pixel of audio frequency `hz`, if it is inside the window.
    pub fn x_of(&self, hz: f32) -> Option<u32> {
        let x = libm::roundf((hz - self.left_hz) / self.hz_per_px);
        (0.0..WINDOW_PX as f32).contains(&x).then_some(x as u32)
    }
}

/// Everything the FreeDV screen shows. The station keeps one and the glue pushes it into the
/// window (`apply_fdv_state` and `apply_fdv_state_diff` in src/lib.rs).
#[derive(Clone, Debug, PartialEq)]
pub struct FdvScreenState {
    pub band_names: Vec<&'static str>,
    pub band_index: usize,
    /// Dial frequency in Hz.
    pub dial_hz: u32,
    /// The sideband the receiver demodulates, which also decides the direction of the zoom axis.
    pub lower_sideband: bool,
    /// 700D (true) or 700E.
    pub mode_d: bool,
    /// 0 searching, 1 trial sync, 2 locked.
    pub sync_level: u8,
    /// Estimated SNR of the modem in dB.
    pub snr_db: f32,
    /// Estimated frequency offset of the signal from 1,500 Hz of audio, in Hz.
    pub foff_hz: f32,
    /// Unique word bit errors in the last frame.
    pub uw_errors: u32,
    /// Bits in the unique word (the denominator of `uw_errors`).
    pub uw_bits: u32,
    /// Frames received since the screen was started or reset.
    pub frames: u32,
    /// How many of `frames` had bit errors.
    pub frames_with_errors: u32,
    /// The most recent frame had bit errors.
    pub last_frame_error: bool,
    /// The decoder is producing speech.
    pub speech: bool,
    pub squelch_on: bool,
    /// Squelch threshold: speech is muted below this SNR, in dB.
    pub squelch_db: f32,
    /// Text channel: the line to show, and the one being received.
    pub text: String,
    pub text_partial: String,
    /// Status line for the audio output (queue depth, underruns), shown with `audio_ok` as the color.
    pub audio_text: String,
    pub audio_ok: bool,
    /// Status line for the HL2 link, shown with `link_ok` as the color.
    pub link_text: String,
    pub link_ok: bool,
    /// Scale of the waterfall window in use.
    pub axis: WfAxis,
}

impl Default for FdvScreenState {
    fn default() -> Self {
        FdvScreenState {
            band_names: alloc::vec!["80", "40", "20", "17", "15", "10"],
            band_index: 2,
            dial_hz: 14_236_000,
            lower_sideband: false,
            mode_d: true,
            sync_level: 0,
            snr_db: -5.0,
            foff_hz: 0.0,
            uw_errors: 0,
            uw_bits: 10,
            frames: 0,
            frames_with_errors: 0,
            last_frame_error: false,
            speech: false,
            squelch_on: false,
            squelch_db: 0.0,
            text: String::new(),
            text_partial: String::new(),
            audio_text: String::new(),
            audio_ok: true,
            link_text: String::from("HL2: no link"),
            link_ok: false,
            axis: WfAxis::zoom(false),
        }
    }
}

impl FdvScreenState {
    /// The dial frequency as "14.236.000".
    pub fn dial_text(&self) -> String {
        format!("{}.{:03}.{:03}", self.dial_hz / 1_000_000, self.dial_hz / 1_000 % 1_000, self.dial_hz % 1_000)
    }

    /// "LSB" or "USB".
    pub fn sideband_text(&self) -> &'static str {
        if self.lower_sideband {
            "LSB"
        } else {
            "USB"
        }
    }

    /// "700D" or "700E".
    pub fn mode_text(&self) -> &'static str {
        if self.mode_d {
            "700D"
        } else {
            "700E"
        }
    }

    /// The sync badge text for `sync_level`.
    pub fn sync_text(&self) -> &'static str {
        match self.sync_level {
            0 => "SEARCHING",
            1 => "TRIAL SYNC",
            _ => "LOCKED",
        }
    }

    /// The SNR as "+8.6 dB", or dashes while the modem has no sync.
    pub fn snr_text(&self) -> String {
        if self.sync_level == 0 {
            String::from("--- dB")
        } else {
            format!("{:+.1} dB", self.snr_db)
        }
    }

    /// 0 to 1 over -5 to +20 dB.
    pub fn snr_fraction(&self) -> f32 {
        if self.sync_level == 0 {
            0.0
        } else {
            ((self.snr_db + 5.0) / 25.0).clamp(0.0, 1.0)
        }
    }

    /// The frequency offset as "+3.2 Hz", or dashes while the modem has no sync.
    pub fn foff_text(&self) -> String {
        if self.sync_level == 0 {
            String::from("--- Hz")
        } else {
            format!("{:+.1} Hz", self.foff_hz)
        }
    }

    /// -1 to 1 over -100 to +100 Hz.
    pub fn foff_fraction(&self) -> f32 {
        if self.sync_level == 0 {
            0.0
        } else {
            (self.foff_hz / 100.0).clamp(-1.0, 1.0)
        }
    }

    /// The unique word line, which is how well the modem sees the frame sync pattern.
    pub fn uw_text(&self) -> String {
        if self.sync_level == 0 {
            String::from("unique word: -")
        } else {
            format!("unique word errors: {} of {}", self.uw_errors, self.uw_bits)
        }
    }

    /// Frame counters with the share of frames that had bit errors.
    pub fn frames_text(&self) -> String {
        let pct = if self.frames == 0 { 0.0 } else { 100.0 * self.frames_with_errors as f32 / self.frames as f32 };
        format!("frames: {}, with bit errors: {} ({:.1} %)", self.frames, self.frames_with_errors, pct)
    }

    /// Text for the speech indicator when no speech is playing: "muted" when the squelch is on
    /// and the modem is in sync, "no speech" otherwise.
    pub fn speech_text(&self) -> &'static str {
        match (self.sync_level, self.squelch_on) {
            (0, _) => "no speech",
            (_, true) => "muted",
            _ => "no speech",
        }
    }

    /// The squelch button text, "SNR > -2 dB" or "squelch off".
    pub fn squelch_text(&self) -> String {
        if self.squelch_on {
            format!("SNR > {:+.0} dB", self.squelch_db)
        } else {
            String::from("squelch off")
        }
    }

    /// Scale marks: every 250 Hz of audio that is inside the window, as (pixel, text).
    pub fn ticks(&self) -> Vec<(u32, String)> {
        (0..=12).filter_map(|k| self.axis.x_of(k as f32 * 250.0).map(|x| (x, format!("{}", k * 250)))).collect()
    }

    /// Pixel of the sender's signal center (1,500 Hz plus the offset), if the modem has one and it
    /// is inside the window.
    pub fn signal_x(&self) -> Option<u32> {
        if self.sync_level == 0 {
            None
        } else {
            self.axis.x_of(1_500.0 + self.foff_hz)
        }
    }

    /// Pixel of 1,500 Hz, where a perfectly tuned signal sits.
    pub fn nominal_x(&self) -> u32 {
        self.axis.x_of(1_500.0).unwrap_or(ZOOM_CENTRE_PX)
    }

    /// A screen in use, for the host screenshot tests.
    pub fn demo() -> Self {
        FdvScreenState {
            sync_level: 2,
            snr_db: 8.6,
            foff_hz: 3.2,
            uw_errors: 0,
            frames: 412,
            frames_with_errors: 3,
            speech: true,
            squelch_on: true,
            squelch_db: -2.0,
            text: String::from("VK5DGR"),
            text_partial: String::from("VK5D"),
            audio_text: String::from("audio: 183 ms queued, ring underruns 0, queue overruns 0"),
            link_text: String::from("HL2: streaming, 0 gaps"),
            link_ok: true,
            ..Default::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scale_follows_the_waterfall() {
        let upper = FdvScreenState::default();
        // 1,500 Hz is in the middle of the window, 3.125 Hz per pixel
        assert_eq!(upper.nominal_x(), 586);
        assert_eq!(upper.axis.x_of(1_500.0 + 312.5), Some(686));
        let t = upper.ticks();
        assert_eq!(t.first(), Some(&(106, String::from("0"))), "0 Hz is {} pixels left of the middle ...", 586 - 106);
        let lower = FdvScreenState { lower_sideband: true, axis: WfAxis::zoom(true), ..Default::default() };
        // mirrored: more audio frequency is further left
        assert!(lower.axis.x_of(2_000.0).unwrap() < lower.axis.x_of(1_000.0).unwrap());
        assert_eq!(lower.nominal_x(), 586);
        let soft = WfAxis::software();
        assert_eq!(soft.x_of(0.0), Some(0));
        assert_eq!(soft.x_of(1_500.0), Some(586));
        assert_eq!(soft.x_of(3_100.0), None);
    }

    #[test]
    fn indicator_texts() {
        let mut s = FdvScreenState::default();
        assert_eq!((s.sync_text(), s.snr_text().as_str(), s.foff_text().as_str()), ("SEARCHING", "--- dB", "--- Hz"));
        assert_eq!(s.signal_x(), None);
        s = FdvScreenState::demo();
        assert_eq!((s.sync_text(), s.snr_text().as_str(), s.foff_text().as_str()), ("LOCKED", "+8.6 dB", "+3.2 Hz"));
        assert_eq!(s.frames_text(), "frames: 412, with bit errors: 3 (0.7 %)");
        assert_eq!(s.signal_x(), Some(587));
        assert_eq!(s.dial_text(), "14.236.000");
        assert_eq!(s.squelch_text(), "SNR > -2 dB");
        assert!((s.snr_fraction() - 0.544).abs() < 0.01);
    }
}
