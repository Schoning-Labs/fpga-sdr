// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The operator's keys on the serial console. Without a pointer or keyboard attached to the board,
//! the FT8 screen is operated from the UART terminal:
//!
//! | Key | What |
//! |---|---|
//! | `t` | TX enable on/off (the operator's TX switch) |
//! | `c` | call CQ |
//! | `h` | halt |
//! | `s` | TX slot 00/30 or 15/45 |
//! | `0` to `9` | answer decode line 0 (newest) to 9 |
//! | `[` `]` | band down, up |
//! | `-` `+` | TX audio frequency 50 Hz down, up |
//! | `m` | switch to the FreeDV screen ([`crate::fdvstation`] has its keys; `m` there goes on to LISTEN, [`crate::listen`]) |
//!
//! The clock keys (`u` and six digits, `,` `.`) are the board program's, not the station's.

use tr_gui::ft8::Ft8Event;

use crate::station::{Station, BANDS};

/// The screen event a console key stands for, or `None` for a key that means nothing on the FT8 screen.
pub fn event_for(key: u8, station: &Station) -> Option<Ft8Event> {
    Some(match key {
        b't' => Ft8Event::TxEnableToggle,
        b'c' => Ft8Event::Cq,
        b'm' => Ft8Event::SwitchToFreedv,
        b'h' => Ft8Event::Halt,
        b's' => Ft8Event::TxParityToggle,
        b'0'..=b'9' => Ft8Event::DecodeClick((key - b'0') as usize),
        b'[' => Ft8Event::BandSelect(station.cfg.band_index.checked_sub(1)?),
        b']' => Ft8Event::BandSelect((station.cfg.band_index + 1 < BANDS.len()).then_some(station.cfg.band_index + 1)?),
        b'-' => Ft8Event::TxFreq(station.cfg.tx_audio_hz.saturating_sub(50)),
        b'+' | b'=' => Ft8Event::TxFreq(station.cfg.tx_audio_hz + 50),
        _ => return None,
    })
}

/// The screen events that transmit, arm transmitting or answer a station. The firmware drops them for a short time
/// after a button or key from the network (`tr_input::NetInputService::tx_guard_active`): the PC's mouse can click
/// the screen's own buttons, which give the same events as these keys. Not in the list: `Halt`, `SwitchToFreedv` and
/// `SwitchToListen` (all switch transmit off), band selection.
pub fn is_transmit_event(e: &Ft8Event) -> bool {
    matches!(e, Ft8Event::TxEnableToggle | Ft8Event::Cq | Ft8Event::TxParityToggle | Ft8Event::DecodeClick(_) | Ft8Event::TxFreq(_))
}

/// A clock the operator sets by typing the time of day: `u`, then `hhmmss`, the last digit typed on
/// the second. FT8 only needs the second within the minute, to a few tenths. `,` and `.` move it
/// by 100 ms (the decodes' DT column shows which way).
#[derive(Default)]
pub struct ManualClock {
    /// UTC ms minus monotonic ms.
    offset_ms: Option<i64>,
    /// Digits typed after `u`; `None` when not entering.
    entry: Option<([u8; 6], usize)>,
}

impl ManualClock {
    /// UTC in ms for the monotonic time `mono_ms`, or `None` while the clock has not been set.
    pub fn now_utc_ms(&self, mono_ms: i64) -> Option<i64> {
        self.offset_ms.map(|o| mono_ms + o)
    }

    /// Feeds one key; true if the key was the clock's.
    pub fn key(&mut self, key: u8, mono_ms: i64) -> bool {
        if let Some((mut digits, n)) = self.entry.take() {
            if !key.is_ascii_digit() {
                return key == b'u' && { self.entry = Some(([0; 6], 0)); true };
            }
            digits[n] = key - b'0';
            if n + 1 < 6 {
                self.entry = Some((digits, n + 1));
            } else {
                let d = |i: usize| digits[i] as i64;
                let s = (d(0) * 10 + d(1)) * 3_600 + (d(2) * 10 + d(3)) * 60 + d(4) * 10 + d(5);
                self.offset_ms = Some(s * 1_000 - mono_ms);
            }
            return true;
        }
        match key {
            b'u' => self.entry = Some(([0; 6], 0)),
            b',' => self.offset_ms = self.offset_ms.map(|o| o - 100),
            b'.' => self.offset_ms = self.offset_ms.map(|o| o + 100),
            _ => return false,
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::station::StationConfig;

    #[test]
    fn keys_map_to_the_screen_events() {
        let mut st = Station::new(StationConfig::new("K1XYZ", "FN42"));
        assert_eq!(event_for(b't', &st), Some(Ft8Event::TxEnableToggle));
        assert_eq!(event_for(b'3', &st), Some(Ft8Event::DecodeClick(3)));
        assert_eq!(event_for(b']', &st), Some(Ft8Event::BandSelect(6)));
        assert_eq!(event_for(b'-', &st), Some(Ft8Event::TxFreq(1_450)));
        assert_eq!(event_for(b'm', &st), Some(Ft8Event::SwitchToFreedv));
        assert_eq!(event_for(b'x', &st), None);
        st.cfg.band_index = 0;
        assert_eq!(event_for(b'[', &st), None);
        st.cfg.band_index = BANDS.len() - 1;
        assert_eq!(event_for(b']', &st), None);
    }

    /// Every console key the station maps to a transmit event, and every key that starts a number entry, is on the
    /// network input's block list (docs/NETINPUT.md). A key added to `event_for` later fails this test until the
    /// list follows it.
    #[test]
    fn the_network_input_blocks_every_transmit_key() {
        let st = Station::new(StationConfig::new("K1XYZ", "FN42"));
        let mut mapped = 0;
        for key in 0..=255u8 {
            if let Some(e) = event_for(key, &st) {
                if is_transmit_event(&e) {
                    mapped += 1;
                    assert!(tr_input::is_tx_char(key), "key {:?} gives {e:?} but the network input lets it through", key as char);
                } else {
                    // the keys that are allowed: halt, FreeDV screen, band keys
                    assert!(matches!(e, Ft8Event::Halt | Ft8Event::SwitchToFreedv | Ft8Event::BandSelect(_)), "{e:?}");
                }
            }
        }
        assert_eq!(mapped, 16, "t c s 0-9 - + =");
        // the clock's own entry key
        assert!(tr_input::is_tx_char(b'u'));
        let mut clock = ManualClock::default();
        assert!(clock.key(b'u', 0), "u starts the clock entry");
        // and the screen's transmit buttons give events the guard drops
        for e in [Ft8Event::TxEnableToggle, Ft8Event::Cq, Ft8Event::TxParityToggle, Ft8Event::DecodeClick(2), Ft8Event::TxFreq(1_500)] {
            assert!(is_transmit_event(&e));
        }
        for e in [Ft8Event::Halt, Ft8Event::SwitchToFreedv, Ft8Event::SwitchToListen, Ft8Event::BandSelect(1)] {
            assert!(!is_transmit_event(&e));
        }
    }

    #[test]
    fn clock_set_by_hand() {
        let mut c = ManualClock::default();
        assert_eq!(c.now_utc_ms(5_000), None);
        assert!(!c.key(b'c', 0), "other keys are not the clock's");
        for (i, k) in b"u183015".iter().enumerate() {
            assert!(c.key(*k, 7_000 + i as i64));
        }
        // Set at monotonic 7,006 ms to 18:30:15.
        assert_eq!(c.now_utc_ms(7_006), Some((18 * 3_600 + 30 * 60 + 15) * 1_000));
        assert_eq!(c.now_utc_ms(8_006), Some(66_616_000));
        assert!(c.key(b'.', 0));
        assert_eq!(c.now_utc_ms(7_006), Some(66_615_100));
        // After the time is in, digits are the station's again.
        assert!(!c.key(b'3', 0));
    }
}
