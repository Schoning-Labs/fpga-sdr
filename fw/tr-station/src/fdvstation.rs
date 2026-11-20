// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The FreeDV receive station: what the operator chose (band, tuning, 700D or 700E,
//! squelch), what that asks of the radio, and the screen's state. The counterpart of
//! [`crate::station::Station`] for the FT8 screen. No transmit: nothing here arms or keys anything.
//!
//! Console keys while the FreeDV screen is shown (the board has no pointer; same scheme as the FT8
//! screen, [`crate::keys`]):
//!
//! | Key | What |
//! |---|---|
//! | `d` `e` | 700D, 700E |
//! | `q` | squelch on/off |
//! | `-` `+` | squelch level 1 dB down, up |
//! | `[` `]` | band down, up |
//! | `<` `>` | dial frequency 100 Hz down, up (the tuning aid is the frequency offset on the screen) |
//! | `m` | on to the LISTEN screen (`m` cycles FT8, FreeDV, LISTEN; the screen's "< FT8" button goes back to FT8) |

use alloc::format;
use alloc::vec::Vec;

use tr_fabric::mem::FabricMem;
use tr_gui::fdv::{FdvEvent, FdvScreenState, WfAxis};
use tr_regs::RegisterSpace;

use crate::freedv::{FdvMode, QUEUE_SAMPLES};
use crate::radio::{Ft8Waterfall, Radio, Sideband};
use tr_freedv::ofdm::SyncState;

/// FreeDV calling frequencies (dial, in the sideband the voice modes use there: lower below 10
/// MHz, upper above). These are the frequencies where FreeDV activity is usually announced.
pub const FDV_BANDS: [(&str, u32, Sideband); 6] = [
    ("80", 3_643_000, Sideband::Lower),
    ("40", 7_177_000, Sideband::Lower),
    ("20", 14_236_000, Sideband::Upper),
    ("17", 18_118_000, Sideband::Upper),
    ("15", 21_313_000, Sideband::Upper),
    ("10", 28_330_000, Sideband::Upper),
];

/// The largest distance in Hz the tuning buttons can move the dial from the band's frequency.
pub const TUNE_MAX_HZ: i32 = 5_000;
/// Lowest squelch level, dB SNR.
pub const SQUELCH_MIN_DB: f32 = -10.0;
/// Highest squelch level, dB SNR.
pub const SQUELCH_MAX_DB: f32 = 20.0;

/// What the radio has to do.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum FdvAction {
    /// Tune the receiver to a new dial frequency and sideband.
    Retune { dial_hz: u32, sideband: Sideband },
    /// Switch between 700D and 700E.
    Mode(FdvMode),
    /// Set the squelch.
    Squelch { on: bool, level_db: f32 },
    /// Show the FT8 screen.
    SwitchToFt8,
    /// Show the LISTEN screen.
    SwitchToListen,
}

/// The operator's FreeDV choices: band, fine tuning, mode and squelch.
pub struct FdvStation {
    band_index: usize,
    tune_hz: i32,
    mode: FdvMode,
    squelch_on: bool,
    squelch_db: f32,
}

impl Default for FdvStation {
    fn default() -> Self {
        Self::new()
    }
}

impl FdvStation {
    /// 20 m, 700D, squelch on at -2 dB SNR (the level the tests use).
    pub fn new() -> Self {
        FdvStation { band_index: 2, tune_hz: 0, mode: FdvMode::D700, squelch_on: true, squelch_db: -2.0 }
    }

    /// The dial frequency in Hz: the band's calling frequency plus the tuning offset.
    pub fn dial_hz(&self) -> u32 {
        (FDV_BANDS[self.band_index].1 as i64 + self.tune_hz as i64) as u32
    }

    /// The sideband of the current band.
    pub fn sideband(&self) -> Sideband {
        FDV_BANDS[self.band_index].2
    }

    /// The selected mode.
    pub fn mode(&self) -> FdvMode {
        self.mode
    }

    /// Squelch on or off, and the level in dB SNR.
    pub fn squelch(&self) -> (bool, f32) {
        (self.squelch_on, self.squelch_db)
    }

    /// Index into `FDV_BANDS`.
    pub fn band_index(&self) -> usize {
        self.band_index
    }

    /// Applies a screen event and returns what the radio has to do about it. A band change resets the tuning offset.
    pub fn on_event(&mut self, ev: FdvEvent) -> Vec<FdvAction> {
        let mut out = Vec::new();
        match ev {
            FdvEvent::BandSelect(i) => {
                if i < FDV_BANDS.len() && i != self.band_index {
                    self.band_index = i;
                    self.tune_hz = 0;
                    out.push(FdvAction::Retune { dial_hz: self.dial_hz(), sideband: self.sideband() });
                }
            }
            FdvEvent::SelectE(e) => {
                let m = if e { FdvMode::E700 } else { FdvMode::D700 };
                if m != self.mode {
                    self.mode = m;
                    out.push(FdvAction::Mode(m));
                }
            }
            FdvEvent::SquelchToggle => {
                self.squelch_on = !self.squelch_on;
                out.push(FdvAction::Squelch { on: self.squelch_on, level_db: self.squelch_db });
            }
            FdvEvent::SquelchStep(d) => {
                self.squelch_db = (self.squelch_db + d as f32).clamp(SQUELCH_MIN_DB, SQUELCH_MAX_DB);
                out.push(FdvAction::Squelch { on: self.squelch_on, level_db: self.squelch_db });
            }
            FdvEvent::Tune(d) => {
                self.tune_hz = (self.tune_hz + d).clamp(-TUNE_MAX_HZ, TUNE_MAX_HZ);
                out.push(FdvAction::Retune { dial_hz: self.dial_hz(), sideband: self.sideband() });
            }
            FdvEvent::SwitchToFt8 => out.push(FdvAction::SwitchToFt8),
            FdvEvent::SwitchToListen => out.push(FdvAction::SwitchToListen),
        }
        out
    }

    /// The screen's state from the radio's FreeDV chain (the defaults while there is none).
    pub fn screen<R: RegisterSpace, M: FabricMem>(&self, radio: &Radio<'_, R, M>, link_text: &str, link_ok: bool) -> FdvScreenState {
        let lower = self.sideband() == Sideband::Lower;
        let axis = match radio.waterfall_shown() {
            Ft8Waterfall::FpgaZoom => WfAxis::zoom(lower),
            Ft8Waterfall::Software => WfAxis::software(),
        };
        let mut s = FdvScreenState {
            band_names: FDV_BANDS.iter().map(|b| b.0).collect(),
            band_index: self.band_index,
            dial_hz: self.dial_hz(),
            lower_sideband: lower,
            mode_d: self.mode == FdvMode::D700,
            squelch_on: self.squelch_on,
            squelch_db: self.squelch_db,
            link_text: link_text.into(),
            link_ok,
            axis,
            uw_bits: self.mode.ofdm().nuwbits as u32,
            ..Default::default()
        };
        if let Some(f) = radio.freedv() {
            let i = f.rx.indicators();
            s.sync_level = match i.sync {
                SyncState::Search => 0,
                SyncState::Trial => 1,
                SyncState::Synced => 2,
            };
            s.snr_db = i.snr_db;
            s.foff_hz = i.foff_hz;
            s.uw_errors = i.uw_errors as u32;
            s.frames = i.frames;
            s.frames_with_errors = i.frames_with_errors;
            s.last_frame_error = i.last_frame_error;
            s.speech = i.speech;
            let t = f.rx.text();
            s.text = t.display().into();
            s.text_partial = if t.display() == t.partial() { "".into() } else { t.partial().into() };
            let (under, over) = (f.out.underruns, f.rx.queue.overruns);
            s.audio_ok = under == 0 && over == 0 && radio.ring_lost() == 0;
            s.audio_text = format!(
                "audio: {} ms queued of {}, ring underruns {}, queue overruns {}, blocks lost {}",
                f.rx.queue.len() / 48,
                QUEUE_SAMPLES / 48,
                under,
                over,
                radio.ring_lost()
            );
        }
        s
    }
}

/// The console keys of the FreeDV screen (see the module text).
pub fn event_for(key: u8, st: &FdvStation) -> Option<FdvEvent> {
    Some(match key {
        b'd' => FdvEvent::SelectE(false),
        b'e' => FdvEvent::SelectE(true),
        b'q' => FdvEvent::SquelchToggle,
        b'-' => FdvEvent::SquelchStep(-1),
        b'+' | b'=' => FdvEvent::SquelchStep(1),
        b'[' => FdvEvent::BandSelect(st.band_index().checked_sub(1)?),
        b']' => FdvEvent::BandSelect((st.band_index() + 1 < FDV_BANDS.len()).then_some(st.band_index() + 1)?),
        b'<' => FdvEvent::Tune(-100),
        b'>' => FdvEvent::Tune(100),
        b'm' => FdvEvent::SwitchToListen,
        _ => return None,
    })
}

/// Carries one action out on the radio. Returns the new dial frequency when it changed, for the
/// HL2 session (its band filter follows the dial).
pub fn apply<R: RegisterSpace, M: FabricMem>(radio: &mut Radio<'_, R, M>, a: &FdvAction) -> Option<u32> {
    match *a {
        FdvAction::Retune { dial_hz, sideband } => {
            radio.freedv_retune(dial_hz, sideband);
            Some(dial_hz)
        }
        FdvAction::Mode(m) => {
            radio.freedv_set_mode(m);
            None
        }
        FdvAction::Squelch { on, level_db } => {
            radio.freedv_set_squelch(on, level_db);
            None
        }
        FdvAction::SwitchToFt8 | FdvAction::SwitchToListen => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn events_become_actions() {
        let mut s = FdvStation::new();
        assert_eq!((s.dial_hz(), s.sideband(), s.mode(), s.squelch()), (14_236_000, Sideband::Upper, FdvMode::D700, (true, -2.0)));
        assert_eq!(s.on_event(FdvEvent::BandSelect(1)), [FdvAction::Retune { dial_hz: 7_177_000, sideband: Sideband::Lower }]);
        assert!(s.on_event(FdvEvent::BandSelect(1)).is_empty(), "the band it is on");
        assert!(s.on_event(FdvEvent::BandSelect(9)).is_empty());
        s.on_event(FdvEvent::Tune(100));
        s.on_event(FdvEvent::Tune(100));
        assert_eq!(s.dial_hz(), 7_177_200);
        s.on_event(FdvEvent::BandSelect(5));
        assert_eq!(s.dial_hz(), 28_330_000, "tuning is per band");
        for _ in 0..100 {
            s.on_event(FdvEvent::Tune(1_000));
        }
        assert_eq!(s.dial_hz(), 28_335_000);
        assert_eq!(s.on_event(FdvEvent::SelectE(true)), [FdvAction::Mode(FdvMode::E700)]);
        assert!(s.on_event(FdvEvent::SelectE(true)).is_empty());
        assert_eq!(s.on_event(FdvEvent::SquelchToggle), [FdvAction::Squelch { on: false, level_db: -2.0 }]);
        assert_eq!(s.on_event(FdvEvent::SquelchStep(-100)), [FdvAction::Squelch { on: false, level_db: -10.0 }]);
        assert_eq!(s.on_event(FdvEvent::SwitchToFt8), [FdvAction::SwitchToFt8]);
    }

    #[test]
    fn keys_map_to_the_screen_events() {
        let mut s = FdvStation::new();
        assert_eq!(event_for(b'e', &s), Some(FdvEvent::SelectE(true)));
        assert_eq!(event_for(b'd', &s), Some(FdvEvent::SelectE(false)));
        assert_eq!(event_for(b'q', &s), Some(FdvEvent::SquelchToggle));
        assert_eq!(event_for(b'+', &s), Some(FdvEvent::SquelchStep(1)));
        assert_eq!(event_for(b']', &s), Some(FdvEvent::BandSelect(3)));
        assert_eq!(event_for(b'<', &s), Some(FdvEvent::Tune(-100)));
        assert_eq!(event_for(b'm', &s), Some(FdvEvent::SwitchToListen), "m cycles on to LISTEN");
        assert_eq!(event_for(b't', &s), None, "no TX key here");
        s.on_event(FdvEvent::BandSelect(0));
        assert_eq!(event_for(b'[', &s), None);
        s.on_event(FdvEvent::BandSelect(FDV_BANDS.len() - 1));
        assert_eq!(event_for(b']', &s), None);
    }
}
