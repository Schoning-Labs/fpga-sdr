// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
//! State of the FT8 operating screen (`ui/ft8_1920x1080.slint`, docs/P2_FT8_FW.md) as plain Rust,
//! and what the operator can ask for. No radio logic lives here: the station logic (`tr-station`)
//! fills an `Ft8ScreenState` and consumes `Ft8Event`s, and the glue in src/lib.rs moves both
//! between this module and the Slint window.
//!
//! The screen has a fixed layout, so this module also holds its geometry (the rectangle where the
//! FPGA's waterfall shows through, the decode list rows, the centers of the controls). The
//! firmware and the host tests use these numbers, and they must match `ui/ft8_view.slint`.

extern crate alloc;

use alloc::format;
use alloc::string::String;
use alloc::vec::Vec;

/// The key color rectangle of the screen, where the logic draws the waterfall: x, y, width,
/// height in pixels. The firmware gives it to the video driver as window geometry.
pub const WATERFALL_RECT: (u32, u32, u32, u32) = (20, 124, 1_172, 656);
/// The audio frequency scale under the waterfall (0 to 3,000 Hz across its width).
pub const SCALE_RECT: (u32, u32, u32, u32) = (20, 788, 1_172, 48);
/// Decode list: left edge, top of row 0, row width and row height.
pub const DECODE_ROWS: (u32, u32, u32, u32) = (1_212, 136, 692, 30);
/// Rows of the decode list that fit on the screen.
pub const DECODE_ROWS_VISIBLE: usize = 30;
/// Centers of the controls (x, y in pixels), for the host tests to click by position.
pub const TX_ENABLE_AT: (u32, u32) = (182, 906);
pub const CQ_AT: (u32, u32) = (103, 1_006);
pub const HALT_AT: (u32, u32) = (261, 1_006);
pub const TX_SLOT_AT: (u32, u32) = (477, 906);
/// Center of band button `i`.
pub const fn band_button_at(i: u32) -> (u32, u32) {
    (260 + i * 68 + 31, 44)
}

/// What the operator did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ft8Event {
    /// Index into the band buttons.
    BandSelect(usize),
    /// The TX enable switch. The only way transmitting is ever enabled.
    TxEnableToggle,
    /// Call CQ.
    Cq,
    /// Stop transmitting and drop the current exchange.
    Halt,
    /// Row index into the decode list as shown (0 is the newest).
    DecodeClick(usize),
    /// Switch between transmitting in the 00 and 30 second slots and the 15 and 45 second slots.
    TxParityToggle,
    /// TX audio frequency in Hz.
    TxFreq(u32),
    /// Go to the FreeDV screen. The firmware switches TX off first; the station logic ignores it.
    SwitchToFreedv,
    /// Go to the LISTEN screen. The firmware switches TX off first; the station logic ignores it.
    SwitchToListen,
}

/// State of the UTC clock.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClockStatus {
    /// No link to the network, or no address yet.
    NoNetwork,
    /// Asked a time server, no answer yet.
    Waiting,
    /// Set from the network; `age_s` is the seconds since the last answer.
    Synced { age_s: u32 },
    /// Typed in by the operator (no network time): good enough to decode, shown as a warning.
    Manual,
}

impl ClockStatus {
    /// 0 for no time, 1 for a warning, 2 for good: the value of `clock-level` in the screen.
    pub fn level(&self) -> i32 {
        match self {
            ClockStatus::NoNetwork => 0,
            ClockStatus::Waiting | ClockStatus::Manual => 1,
            ClockStatus::Synced { .. } => 2,
        }
    }

    /// The text of the clock status badge.
    pub fn text(&self) -> String {
        match self {
            ClockStatus::NoNetwork => String::from("no network time"),
            ClockStatus::Waiting => String::from("asking time server"),
            ClockStatus::Manual => String::from("clock set by hand"),
            ClockStatus::Synced { age_s } if *age_s < 120 => String::from("UTC from network"),
            ClockStatus::Synced { age_s } => format!("UTC, set {} min ago", age_s / 60),
        }
    }
}

/// What a decode list row is, which sets its color. The numbers are what `ui/ft8_model.slint`
/// expects in `kind`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RowKind {
    /// Traffic between other stations.
    Other = 0,
    /// Someone calling CQ.
    Cq = 1,
    /// A message addressed to us.
    ToMe = 2,
    /// Our own transmission, shown in the list as well.
    MyTx = 3,
}

/// One line of the decode list.
#[derive(Clone, Debug, PartialEq)]
pub struct Ft8DecodeRow {
    /// "18:32:15", the start of the slot.
    pub utc: String,
    /// Signal-to-noise ratio in dB (WSJT-X convention, 2500 Hz bandwidth).
    pub snr_db: i8,
    /// Time offset from the slot start in seconds.
    pub dt_s: f32,
    /// Audio frequency of the signal in Hz.
    pub audio_hz: u16,
    pub message: String,
    pub kind: RowKind,
}

impl Ft8DecodeRow {
    /// The dB column: a signed number, or "TX" for our own transmission.
    pub fn snr_text(&self) -> String {
        if self.kind == RowKind::MyTx {
            String::from("TX")
        } else {
            format!("{:+}", self.snr_db)
        }
    }

    /// The DT column as "+0.1" (empty for our own transmission, which has no offset).
    pub fn dt_text(&self) -> String {
        if self.kind == RowKind::MyTx {
            return String::new();
        }
        let tenths = libm::roundf(self.dt_s * 10.0) as i32;
        format!("{}{}.{}", if tenths < 0 { "-" } else { "+" }, tenths.abs() / 10, tenths.abs() % 10)
    }

    /// The Hz column.
    pub fn freq_text(&self) -> String {
        format!("{}", self.audio_hz)
    }
}

/// Everything the FT8 screen shows. The station logic keeps one and the glue pushes it into
/// the window (`apply_state` and `apply_state_diff` in src/lib.rs).
#[derive(Clone, Debug, PartialEq)]
pub struct Ft8ScreenState {
    pub band_names: Vec<&'static str>,
    pub band_index: usize,
    /// Dial frequency in Hz.
    pub dial_hz: u32,
    /// Seconds since midnight UTC, `None` while the clock is not set.
    pub utc_s_of_day: Option<u32>,
    pub clock: ClockStatus,
    /// How far through the 15 second slot we are, 0 to 1.
    pub slot_progress: f32,
    /// The current slot is one we transmit in.
    pub slot_is_ours: bool,
    /// The TX enable switch of the screen; off until the operator switches it on.
    pub tx_enabled: bool,
    /// The transmitter is on the air.
    pub transmitting: bool,
    /// True when we transmit in the slots that start at second 00 and 30.
    pub tx_first: bool,
    /// Audio frequency of our transmission in Hz.
    pub tx_audio_hz: u32,
    /// Audio frequency the receiver listens at, in Hz.
    pub rx_audio_hz: u32,
    /// The message that is sent next, or is being sent.
    pub tx_message: String,
    /// One line on where the exchange stands ("idle", "working DL1ABC ...").
    pub qso_text: String,
    pub my_call: String,
    /// Status line for the HL2 link, shown with `link_ok` as the color.
    pub link_text: String,
    pub link_ok: bool,
    /// Newest first.
    pub decodes: Vec<Ft8DecodeRow>,
}

impl Default for Ft8ScreenState {
    fn default() -> Self {
        Ft8ScreenState {
            band_names: alloc::vec!["160", "80", "60", "40", "30", "20", "17", "15", "12", "10"],
            band_index: 5,
            dial_hz: 14_074_000,
            utc_s_of_day: None,
            clock: ClockStatus::NoNetwork,
            slot_progress: 0.0,
            slot_is_ours: false,
            tx_enabled: false,
            transmitting: false,
            tx_first: true,
            tx_audio_hz: 1_500,
            rx_audio_hz: 1_500,
            tx_message: String::new(),
            qso_text: String::from("idle"),
            my_call: String::new(),
            link_text: String::from("HL2: no link"),
            link_ok: false,
            decodes: Vec::new(),
        }
    }
}

/// "18:32:15" from seconds since midnight (wrapping at 86,400).
pub fn hms(s_of_day: u32) -> String {
    let s = s_of_day % 86_400;
    format!("{:02}:{:02}:{:02}", s / 3_600, s / 60 % 60, s % 60)
}

impl Ft8ScreenState {
    /// The dial frequency as "14.074.000".
    pub fn dial_text(&self) -> String {
        format!("{}.{:03}.{:03}", self.dial_hz / 1_000_000, self.dial_hz / 1_000 % 1_000, self.dial_hz % 1_000)
    }

    /// The UTC clock as "18:32:15", or dashes while the clock is not set.
    pub fn utc_text(&self) -> String {
        match self.utc_s_of_day {
            Some(s) => hms(s),
            None => String::from("--:--:--"),
        }
    }

    /// A screen full of plausible content, for screenshots.
    pub fn demo() -> Self {
        let row = |utc: &str, snr: i8, dt: f32, hz: u16, msg: &str, kind: RowKind| Ft8DecodeRow {
            utc: String::from(utc),
            snr_db: snr,
            dt_s: dt,
            audio_hz: hz,
            message: String::from(msg),
            kind,
        };
        Ft8ScreenState {
            utc_s_of_day: Some(18 * 3_600 + 32 * 60 + 37),
            clock: ClockStatus::Synced { age_s: 40 },
            slot_progress: 7.0 / 15.0,
            slot_is_ours: false,
            tx_enabled: true,
            tx_audio_hz: 1_840,
            rx_audio_hz: 1_203,
            tx_message: String::from("DL1ABC K1XYZ R-08"),
            qso_text: String::from("working DL1ABC: report received, sending R-08"),
            my_call: String::from("K1XYZ FN42"),
            link_text: String::from("HL2: streaming, 0 gaps, 41 C"),
            link_ok: true,
            decodes: alloc::vec![
                row("18:32:15", -8, 0.1, 1_203, "K1XYZ DL1ABC -12", RowKind::ToMe),
                row("18:32:15", 3, -0.2, 412, "CQ JA1XYZ PM95", RowKind::Cq),
                row("18:32:15", -14, 0.4, 2_006, "W1AW EA3XYZ JN11", RowKind::Other),
                row("18:32:00", 0, 0.0, 1_840, "DL1ABC K1XYZ FN42", RowKind::MyTx),
                row("18:31:45", -6, 0.0, 1_203, "CQ DL1ABC JO62", RowKind::Cq),
                row("18:31:45", -18, 0.3, 877, "VE3ABC W1AW R-09", RowKind::Other),
                row("18:31:45", -2, -0.1, 1_655, "CQ PY2XYZ GG66", RowKind::Cq),
                row("18:31:30", -11, 0.2, 233, "W1AW DL9ABC RR73", RowKind::Other),
                row("18:31:15", -20, -0.3, 2_622, "CQ VK2XYZ QF56", RowKind::Cq),
                row("18:31:15", 1, 0.1, 1_988, "JA1XYZ K1ABC 73", RowKind::Other),
            ],
            ..Default::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn texts() {
        let mut s = Ft8ScreenState::default();
        assert_eq!(s.dial_text(), "14.074.000");
        assert_eq!(s.utc_text(), "--:--:--");
        s.dial_hz = 3_573_000;
        s.utc_s_of_day = Some(86_399);
        assert_eq!(s.dial_text(), "3.573.000");
        assert_eq!(s.utc_text(), "23:59:59");
        assert!(!s.tx_enabled, "TX is off in the default state");
        let r = Ft8DecodeRow { utc: String::new(), snr_db: -7, dt_s: -0.26, audio_hz: 950, message: String::new(), kind: RowKind::Cq };
        assert_eq!((r.snr_text().as_str(), r.dt_text().as_str(), r.freq_text().as_str()), ("-7", "-0.3", "950"));
        assert_eq!(ClockStatus::Synced { age_s: 600 }.text(), "UTC, set 10 min ago");
    }
}
