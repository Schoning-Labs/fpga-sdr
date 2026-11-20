// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
//! State of the LISTEN screen (`ui/listen_view.slint`, docs/LISTEN.md) as plain Rust, and what the
//! operator can ask for. No radio logic lives here: the LISTEN station (`tr-station`) fills a
//! `ListenScreenState` and consumes `ListenEvent`s, and the glue in src/lib.rs moves both between
//! this module and the Slint window. The screen is receive only, nothing on it transmits.
//!
//! LISTEN is a general coverage receiver screen: a large frequency display with clickable digits,
//! mode, band, filter and step buttons, an S-meter, volume and squelch, and a waterfall of the
//! zoom receiver around the tuned frequency. `ListenAxis` maps frequency offsets to waterfall
//! pixels, and the `*_AT` constants and functions give the centers of the controls for the host
//! tests.

extern crate alloc;

use alloc::format;
use alloc::string::String;
use alloc::vec::Vec;

use crate::fdv::WINDOW_PX;

/// Demodulation of the LISTEN receiver, in the order of the screen's mode buttons.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ListenMode {
    Lsb,
    Usb,
    Cw,
    Am,
    Sam,
    Fm,
}

impl ListenMode {
    /// Every mode, in the order of the mode buttons.
    pub const ALL: [ListenMode; 6] = [ListenMode::Lsb, ListenMode::Usb, ListenMode::Cw, ListenMode::Am, ListenMode::Sam, ListenMode::Fm];

    /// The text on the mode button.
    pub fn name(self) -> &'static str {
        match self {
            ListenMode::Lsb => "LSB",
            ListenMode::Usb => "USB",
            ListenMode::Cw => "CW",
            ListenMode::Am => "AM",
            ListenMode::Sam => "SAM",
            ListenMode::Fm => "FM",
        }
    }

    /// Position of the mode in the mode buttons.
    pub fn index(self) -> usize {
        ListenMode::ALL.iter().position(|m| *m == self).unwrap_or(0)
    }

    /// The mode of mode button `i`, `None` past the last one.
    pub fn from_index(i: usize) -> Option<ListenMode> {
        ListenMode::ALL.get(i).copied()
    }
}

/// Tuning steps of the step selector, in Hz. 9 kHz and 12.5 kHz are the channel spacings of AM
/// broadcast (Europe) and of some VHF services.
pub const STEPS_HZ: [u32; 9] = [10, 100, 1_000, 5_000, 9_000, 10_000, 12_500, 100_000, 1_000_000];

/// "10 Hz", "12.5 kHz", "1 MHz".
pub fn step_name(hz: u32) -> String {
    if hz >= 1_000_000 {
        format!("{} MHz", hz / 1_000_000)
    } else if hz >= 1_000 {
        if hz % 1_000 == 0 {
            format!("{} kHz", hz / 1_000)
        } else {
            format!("{}.{} kHz", hz / 1_000, hz % 1_000 / 100)
        }
    } else {
        format!("{} Hz", hz)
    }
}

/// Digits of the frequency display: 10 MHz down to 1 Hz.
pub const DIGITS: usize = 8;

/// Where in the waterfall window which radio frequency is: the tuned frequency at pixel
/// `centre_px`, `hz_per_px` Hz per pixel, RF order (frequency rises to the right).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ListenAxis {
    /// Radio Hz per window pixel.
    pub hz_per_px: f32,
    /// Window pixel of the tuned frequency.
    pub centre_px: u32,
    /// Ticks every this many Hz.
    pub tick_hz: u32,
    /// Text shown under the waterfall to say which picture and scale this is.
    pub note: &'static str,
    /// False: the chip has no zoom receiver and the window shows nothing.
    pub waterfall: bool,
}

impl ListenAxis {
    /// The zoom receiver centered on the tuned frequency, `span_hz` over its 1,920 columns, the
    /// middle 1,172 of them in the window.
    pub fn zoom(span_hz: u32) -> ListenAxis {
        let hz_per_px = span_hz as f32 / 1_920.0;
        let (tick_hz, note) = if span_hz <= 12_000 {
            (1_000, "waterfall: zoom receiver, 6.25 Hz per pixel")
        } else if span_hz <= 24_000 {
            (2_000, "waterfall: zoom receiver, 12.5 Hz per pixel")
        } else {
            (5_000, "waterfall: zoom receiver, 25 Hz per pixel")
        };
        ListenAxis { hz_per_px, centre_px: WINDOW_PX / 2, tick_hz, note, waterfall: true }
    }

    /// No zoom receiver in the chip.
    pub fn none() -> ListenAxis {
        ListenAxis { hz_per_px: 6.25, centre_px: WINDOW_PX / 2, tick_hz: 1_000, note: "no waterfall: the chip has no zoom receiver", waterfall: false }
    }

    /// Pixel of `offset_hz` from the tuned frequency, clamped to the window.
    pub fn x_of(&self, offset_hz: i32) -> i32 {
        let x = self.centre_px as f32 + offset_hz as f32 / self.hz_per_px;
        (libm::roundf(x) as i32).clamp(0, WINDOW_PX as i32 - 1)
    }

    /// Offset from the tuned frequency of window pixel `x`.
    pub fn offset_of(&self, x: i32) -> i32 {
        libm::roundf((x - self.centre_px as i32) as f32 * self.hz_per_px) as i32
    }
}

/// What the operator did on the LISTEN screen (or with its keys).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ListenEvent {
    /// Select a demodulation mode.
    Mode(ListenMode),
    /// Filter preset of the current mode (0 = the default width).
    Filter(usize),
    /// Next filter preset of the current mode.
    FilterNext,
    /// Index into `STEPS_HZ`.
    Step(usize),
    /// Smaller (-1) or larger (+1) tuning step.
    StepChange(i32),
    /// Tune by this many steps (left/right keys, the wheel over the waterfall).
    TuneSteps(i32),
    /// Tune by `dir` units of the digit worth `10^place` Hz (click or wheel on that digit).
    TuneDigit { place: u32, dir: i32 },
    /// Tune by this many Hz (Page Up / Page Down).
    TuneHz(i32),
    /// A click on the waterfall at this pixel of the window.
    WaterfallClick(i32),
    /// Index into the band buttons.
    BandSelect(usize),
    /// Band down (-1) or up (+1).
    BandStep(i32),
    AgcToggle,
    SquelchToggle,
    /// Change of the squelch level, in dB.
    SquelchStep(i32),
    /// Change of the volume, in percent.
    VolumeStep(i32),
    /// Go to the FT8 screen.
    SwitchToFt8,
    /// Go to the FreeDV screen.
    SwitchToFreedv,
    /// Waterfall sensitivity one step up (+1: brighter, more sensitive) or down (-1: darker).
    WfSensitivityStep(i32),
    /// Back to the automatic floor (sensitivity 0 dB).
    WfSensitivityAuto,
    /// Waterfall contrast: the range from black to white one step wider (+1) or narrower (-1).
    WfRangeStep(i32),
    /// Waterfall speed one preset faster (+1) or slower (-1).
    WfSpeedStep(i32),
    /// The HL2's RX gain down (-1) or up (+1) by 1 dB. Switches the RF AGC to manual.
    RfGainStep(i32),
    /// RF AGC between automatic and manual.
    RfAgcToggle,
}

/// Centers of the controls (x, y in pixels), for the host tests to click by position.
pub const TO_FT8_AT: (u32, u32) = (236, 44);
pub const TO_FREEDV_AT: (u32, u32) = (342, 44);
/// Mode button `i` (the order of `ListenMode::ALL`).
pub const fn mode_button_at(i: u32) -> (u32, u32) {
    (32 + i * 128 + 58, 906)
}
/// Filter button `i`.
pub const fn filter_button_at(i: u32) -> (u32, u32) {
    (32 + i * 168 + 78, 1_006)
}
pub const AGC_AT: (u32, u32) = (885, 906);
pub const SQUELCH_AT: (u32, u32) = (1_303, 764);
pub const VOLUME_UP_AT: (u32, u32) = (1_857, 656);
pub const VOLUME_DOWN_AT: (u32, u32) = (1_259, 656);
/// Step button `i` (the order of `STEPS_HZ`).
pub const fn step_button_at(i: u32) -> (u32, u32) {
    (1_228 + (i % 5) * 133 + 63, 340 + (i / 5) * 52 + 22)
}
/// Digit `k` of the frequency display (0 = 10 MHz), upper half (tune up) and lower half (down).
pub const fn digit_at(k: u32, upper: bool) -> (u32, u32) {
    let x = 1_236 + k * 76 + if k >= 2 { 28 } else { 0 } + if k >= 5 { 28 } else { 0 } + 33;
    (x, if upper { 150 } else { 230 })
}
/// Band button `i`.
pub const fn band_button_at(i: u32) -> (u32, u32) {
    (430 + i * 66 + 30, 44)
}
/// Waterfall controls (one row at the bottom right): sensitivity -/+, contrast -/+, speed -/+, Auto.
pub const WF_SENS_DOWN_AT: (u32, u32) = (1_250, 964);
pub const WF_SENS_UP_AT: (u32, u32) = (1_386, 964);
pub const WF_RANGE_DOWN_AT: (u32, u32) = (1_440, 964);
pub const WF_RANGE_UP_AT: (u32, u32) = (1_576, 964);
pub const WF_SPEED_DOWN_AT: (u32, u32) = (1_630, 964);
pub const WF_SPEED_UP_AT: (u32, u32) = (1_766, 964);
pub const WF_AUTO_AT: (u32, u32) = (1_843, 964);
/// RF gain - and +, and the AUTO/MANUAL button of the RF AGC (bottom right of the controls).
pub const RF_GAIN_DOWN_AT: (u32, u32) = (1_006, 954);
pub const RF_GAIN_UP_AT: (u32, u32) = (1_158, 954);
pub const RF_AGC_AT: (u32, u32) = (1_082, 1_019);

/// Everything the LISTEN screen shows. The station keeps one and the glue pushes it into the
/// window (`apply_listen_state` and `apply_listen_state_diff` in src/lib.rs).
#[derive(Clone, Debug, PartialEq)]
pub struct ListenScreenState {
    /// Tuned frequency in Hz.
    pub freq_hz: u32,
    pub mode: ListenMode,
    pub band_names: Vec<&'static str>,
    pub band_index: usize,
    /// Names of the filter presets of the current mode, the first being the default width.
    pub filter_names: Vec<String>,
    pub filter_index: usize,
    /// Index into `STEPS_HZ`.
    pub step_index: usize,
    pub agc_on: bool,
    pub squelch_on: bool,
    /// Squelch threshold in dBFS, on the same scale as `smeter_dbfs`.
    pub squelch_db: f32,
    /// The squelch is open, so audio is playing.
    pub squelch_open: bool,
    /// Volume, 0 to 100 percent.
    pub volume_pct: u32,
    /// S-meter of the receiver, dB relative to full scale.
    pub smeter_dbfs: f32,
    /// Pass band of the filter in radio frequency, Hz from the tuned frequency.
    pub passband: (i32, i32),
    /// Scale of the waterfall window.
    pub axis: ListenAxis,
    /// One line about the receiver (which one, oscillator, filter, AGC).
    pub info_text: String,
    /// Status line for the audio output, shown with `audio_ok` as the color.
    pub audio_text: String,
    pub audio_ok: bool,
    /// Status line for the HL2 link, shown with `link_ok` as the color.
    pub link_text: String,
    pub link_ok: bool,
    /// Waterfall sensitivity, in dB from the automatic setting (+ is brighter).
    pub wf_sensitivity_db: i32,
    /// Waterfall contrast as the range in dB from black to white.
    pub wf_range_db: u32,
    /// Waterfall speed in lines per second times 10: the rate the zoom receiver gives, which is
    /// not always the preset that was asked for.
    pub wf_speed_x10: u32,
    /// The HL2's RX gain, dB.
    pub rf_gain_db: i32,
    /// The RF AGC sets the gain (false: manual).
    pub rf_agc_auto: bool,
    /// One line about the HL2 itself: temperature and power codes.
    pub hl2_text: String,
}

impl Default for ListenScreenState {
    fn default() -> Self {
        ListenScreenState {
            freq_hz: 14_200_000,
            mode: ListenMode::Usb,
            band_names: alloc::vec!["160", "80", "60", "40", "30", "20", "17", "15", "12", "10", "GEN"],
            band_index: 5,
            filter_names: alloc::vec![String::from("2.4 kHz"), String::from("1.8 kHz"), String::from("2.8 kHz")],
            filter_index: 0,
            step_index: 1,
            agc_on: true,
            squelch_on: false,
            squelch_db: -100.0,
            squelch_open: true,
            volume_pct: 50,
            smeter_dbfs: -140.0,
            passband: (300, 2_700),
            axis: ListenAxis::zoom(12_000),
            info_text: String::new(),
            audio_text: String::new(),
            audio_ok: true,
            link_text: String::from("HL2: no link"),
            link_ok: false,
            wf_sensitivity_db: 0,
            wf_range_db: 60,
            wf_speed_x10: 70,
            rf_gain_db: 20,
            rf_agc_auto: false,
            hl2_text: String::new(),
        }
    }
}

/// Lowest and highest S-meter reading the bar shows, in dBFS.
pub const SMETER_MIN_DBFS: f32 = -140.0;
pub const SMETER_MAX_DBFS: f32 = -20.0;

impl ListenScreenState {
    /// The 8 digits, 10 MHz first.
    pub fn digits(&self) -> [u8; DIGITS] {
        let mut d = [0u8; DIGITS];
        let mut f = self.freq_hz;
        for k in (0..DIGITS).rev() {
            d[k] = (f % 10) as u8;
            f /= 10;
        }
        d
    }

    /// Leading zeros (shown dim): 1 below 10 MHz.
    pub fn lead_zeros(&self) -> usize {
        self.digits().iter().take(DIGITS - 1).take_while(|d| **d == 0).count()
    }

    /// The tuned frequency as "14.200.000".
    pub fn freq_text(&self) -> String {
        format!("{}.{:03}.{:03}", self.freq_hz / 1_000_000, self.freq_hz / 1_000 % 1_000, self.freq_hz % 1_000)
    }

    /// The S-meter level as "-78.4 dBFS".
    pub fn smeter_text(&self) -> String {
        format!("{:.1} dBFS", self.smeter_dbfs)
    }

    /// 0 to 1 over `SMETER_MIN_DBFS` to `SMETER_MAX_DBFS`.
    pub fn smeter_fraction(&self) -> f32 {
        ((self.smeter_dbfs - SMETER_MIN_DBFS) / (SMETER_MAX_DBFS - SMETER_MIN_DBFS)).clamp(0.0, 1.0)
    }

    /// Where the squelch level is on the S-meter bar, 0 to 1.
    pub fn squelch_fraction(&self) -> f32 {
        ((self.squelch_db - SMETER_MIN_DBFS) / (SMETER_MAX_DBFS - SMETER_MIN_DBFS)).clamp(0.0, 1.0)
    }

    /// The squelch level as "-100 dBFS".
    pub fn squelch_text(&self) -> String {
        format!("{:.0} dBFS", self.squelch_db)
    }

    /// The volume as "50 %".
    pub fn volume_text(&self) -> String {
        format!("{} %", self.volume_pct)
    }

    /// "0 dB" (automatic), "+3 dB", "-6 dB".
    pub fn wf_sensitivity_text(&self) -> String {
        if self.wf_sensitivity_db == 0 {
            String::from("0 dB")
        } else {
            format!("{:+} dB", self.wf_sensitivity_db)
        }
    }

    /// "5 /s", "1.8 /s".
    pub fn wf_speed_text(&self) -> String {
        let (w, f) = (self.wf_speed_x10 / 10, self.wf_speed_x10 % 10);
        if f == 0 {
            format!("{} /s", w)
        } else {
            format!("{}.{} /s", w, f)
        }
    }

    /// The RF gain as "20 dB".
    pub fn rf_gain_text(&self) -> String {
        format!("{} dB", self.rf_gain_db)
    }

    /// The waterfall contrast range as "60 dB".
    pub fn wf_range_text(&self) -> String {
        format!("{} dB", self.wf_range_db)
    }

    /// The labels of the step buttons.
    pub fn step_names(&self) -> Vec<String> {
        STEPS_HZ.iter().map(|h| step_name(*h)).collect()
    }

    /// AGC switch usable: FM always runs with a fixed gain.
    pub fn agc_available(&self) -> bool {
        self.mode != ListenMode::Fm
    }

    /// Scale marks under the waterfall: every `tick_hz` from the tuned frequency, as (pixel, text in kHz).
    pub fn ticks(&self) -> Vec<(u32, String)> {
        let mut v = Vec::new();
        let half = (self.axis.centre_px as f32 * self.axis.hz_per_px) as i32;
        let t = self.axis.tick_hz as i32;
        let mut k = -(half / t);
        while k * t <= half {
            let x = self.axis.x_of(k * t);
            if x > 0 && x < WINDOW_PX as i32 - 1 {
                let text = if k == 0 { String::from("0") } else { format!("{:+}", k * t / 1_000) };
                v.push((x as u32, text));
            }
            k += 1;
        }
        v
    }

    /// The filter's pass band on the scale: left and right pixel.
    pub fn passband_px(&self) -> (i32, i32) {
        (self.axis.x_of(self.passband.0), self.axis.x_of(self.passband.1).max(self.axis.x_of(self.passband.0) + 2))
    }

    /// A screen in use, for the host screenshot tests.
    pub fn demo() -> Self {
        ListenScreenState {
            freq_hz: 7_074_000,
            mode: ListenMode::Lsb,
            band_index: 3,
            passband: (-2_700, -300),
            smeter_dbfs: -78.4,
            squelch_open: true,
            info_text: String::from("receiver 1, oscillator 7.074.000 Hz, filter -2,700 to -300 Hz, AGC on"),
            audio_text: String::from("audio: 48 kHz, ring 81 ms, underruns 0, blocks lost 0, longest gap 12 ms"),
            link_text: String::from("HL2: streaming, 0 gaps, 0 CRC errors"),
            link_ok: true,
            wf_sensitivity_db: 6,
            wf_speed_x10: 37,
            rf_gain_db: 14,
            rf_agc_auto: true,
            hl2_text: String::from("HL2 38.6 C, fwd 0, rev 0"),
            ..Default::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_values() {
        let mut s = ListenScreenState::default();
        assert_eq!(s.digits(), [1, 4, 2, 0, 0, 0, 0, 0]);
        assert_eq!(s.lead_zeros(), 0);
        s.freq_hz = 153_000;
        assert_eq!(s.digits(), [0, 0, 1, 5, 3, 0, 0, 0]);
        assert_eq!(s.lead_zeros(), 2);
        assert_eq!(s.freq_text(), "0.153.000");
        assert_eq!(step_name(12_500), "12.5 kHz");
        assert_eq!(step_name(9_000), "9 kHz");
        assert_eq!(step_name(1_000_000), "1 MHz");
        assert_eq!(step_name(10), "10 Hz");
        // 6.25 Hz per pixel: 2,700 Hz is 432 pixels right of the middle
        assert_eq!(s.axis.x_of(2_700), 586 + 432);
        assert_eq!(s.axis.offset_of(586 - 160), -1_000);
        let t = s.ticks();
        assert_eq!(t.len(), 7, "-3 to +3 kHz: {t:?}");
        assert!(t.contains(&(586, String::from("0"))));
        assert_eq!(s.passband_px(), (586 + 48, 586 + 432));
        s.smeter_dbfs = -80.0;
        assert!((s.smeter_fraction() - 0.5).abs() < 1e-6);
    }
}
