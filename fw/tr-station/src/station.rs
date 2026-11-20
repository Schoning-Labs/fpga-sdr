// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The FT8 station: what the operator asked for, what was heard, what time it is, in; what the
//! radio has to do next and what the screen shows, out. No hardware here (see [`crate::radio`]).
//!
//! Timing of a 15 s slot (UTC, slots start at second 0, 15, 30, 45):
//!
//! | Into the slot | What |
//! |---|---|
//! | 0.5 s | a transmission starts (12.64 s long) |
//! | 14.2 s | the slot's audio goes to the decoder ([`StationConfig::decode_at_ms`]) |
//! | next slot, 0.5 s to 2.0 s | our answer starts as soon as the decodes are in; if that is after 0.5 s the waveform starts at the matching place, its beginning cut off ([`StationConfig::max_late_ms`]) |
//!
//! **Transmitting.** [`Action::StartTx`] is produced only while the operator's TX switch is on
//! (`Ft8Event::TxEnableToggle`, off at start) and the clock is set from the network. Switching on
//! produces [`Action::ArmTx`]; nothing else does.

use alloc::collections::VecDeque;
use alloc::format;
use alloc::string::{String, ToString};
use alloc::vec::Vec;

use tr_gui::ft8::{hms, ClockStatus, Ft8DecodeRow, Ft8Event, Ft8ScreenState, RowKind};
use tr_modes::txbb::TX_START_MS;

use crate::msg::{parse, Parsed, TxMessage};
use crate::qso::{Heard, Qso, QsoConfig};

/// Length of an FT8 slot, ms.
pub const SLOT_MS: i64 = 15_000;
/// Length of an FT8 transmission, ms.
pub const TX_LEN_MS: u32 = 12_640;

/// FT8 dial frequencies (upper sideband), the usual ones.
pub const BANDS: [(&str, u32); 10] = [
    ("160", 1_840_000),
    ("80", 3_573_000),
    ("60", 5_357_000),
    ("40", 7_074_000),
    ("30", 10_136_000),
    ("20", 14_074_000),
    ("17", 18_100_000),
    ("15", 21_074_000),
    ("12", 24_915_000),
    ("10", 28_074_000),
];

/// Slot number and milliseconds into it.
pub fn slot_of(utc_ms: i64) -> (i64, u32) {
    (utc_ms.div_euclid(SLOT_MS), utc_ms.rem_euclid(SLOT_MS) as u32)
}

/// Operator settings and timing of the station.
#[derive(Clone, Debug)]
pub struct StationConfig {
    /// Our call sign.
    pub my_call: String,
    /// Our locator.
    pub my_grid: String,
    /// Index into [`BANDS`].
    pub band_index: usize,
    /// Audio frequency of our transmission, Hz.
    pub tx_audio_hz: u32,
    /// When in the slot its audio goes to the decoder.
    pub decode_at_ms: u32,
    /// How late after 0.5 s a transmission may still start.
    pub max_late_ms: u32,
    /// Decode lines kept for the screen.
    pub rows: usize,
    /// Also decode the slots we transmit in: with the HL2 in echo mode (its RX stream carries the
    /// played TX samples) and in the self-test, our own message then shows up in the list.
    pub decode_own_slots: bool,
}

impl StationConfig {
    /// 20 m, TX at 1,500 Hz, the slot decoded at 14.2 s, a late start allowed up to 1.5 s after 0.5 s, 200 decode rows.
    pub fn new(my_call: &str, my_grid: &str) -> Self {
        StationConfig { my_call: my_call.to_string(), my_grid: my_grid.to_string(), band_index: 5, tx_audio_hz: 1_500, decode_at_ms: 14_200, max_late_ms: 1_500, rows: 200, decode_own_slots: false }
    }
}

/// What the radio has to do.
#[derive(Clone, Debug, PartialEq)]
pub enum Action {
    /// Tune receiver and TX mixer.
    Retune { dial_hz: u32 },
    /// The operator switched TX on: switch the TX path on.
    ArmTx,
    /// Switch the TX path off.
    DisarmTx,
    /// Decode the audio of slot `slot` and hand the result to [`Station::on_decodes`].
    StartDecode { slot: i64 },
    /// Start playing `msg` now; `skip_ms` of its beginning are already past.
    StartTx { slot: i64, msg: TxMessage, audio_hz: u32, skip_ms: u32 },
    /// Stop playing at once.
    StopTx,
}

/// One line of the decode list.
#[derive(Clone, Debug)]
struct Row {
    heard: Heard,
    kind: RowKind,
}

/// The station state: the operator's settings, the contact logic, the decode list and the slot timing.
pub struct Station {
    /// Settings, changed by screen events.
    pub cfg: StationConfig,
    /// The contact logic.
    pub qso: Qso,
    /// The operator's TX switch.
    tx_enabled: bool,
    /// Decode list, newest first.
    rows: VecDeque<Row>,
    /// Audio frequency of the station picked from the list, for the screen's marker.
    rx_audio_hz: u32,
    /// Slot whose decode has been asked for and not delivered.
    decode_pending: Option<i64>,
    /// Newest slot a decode was asked for.
    decode_asked: i64,
    /// Newest slot for which the TX decision was taken.
    tx_decided: i64,
    /// Slot we are transmitting in, with the message.
    transmitting: Option<(i64, TxMessage)>,
    /// Newest slot we started a transmission in.
    last_tx_slot: i64,
}

impl Station {
    /// A station with TX switched off and an empty decode list.
    pub fn new(cfg: StationConfig) -> Self {
        let qso = Qso::new(QsoConfig::new(&cfg.my_call, &cfg.my_grid));
        Station { rx_audio_hz: cfg.tx_audio_hz, cfg, qso, tx_enabled: false, rows: VecDeque::new(), decode_pending: None, decode_asked: i64::MIN, tx_decided: i64::MIN, transmitting: None, last_tx_slot: i64::MIN }
    }

    /// The dial frequency of the selected band, Hz.
    pub fn dial_hz(&self) -> u32 {
        BANDS[self.cfg.band_index].1
    }

    /// The state of the operator's TX switch.
    pub fn tx_enabled(&self) -> bool {
        self.tx_enabled
    }

    /// True while a transmission is playing.
    pub fn is_transmitting(&self) -> bool {
        self.transmitting.is_some()
    }

    /// Ends the transmission in progress, if any, and asks the radio to stop playing.
    fn stop_tx(&mut self, out: &mut Vec<Action>) {
        if self.transmitting.take().is_some() {
            out.push(Action::StopTx);
        }
    }

    /// Something the operator did on the screen.
    pub fn on_event(&mut self, ev: Ft8Event) -> Vec<Action> {
        let mut out = Vec::new();
        match ev {
            Ft8Event::TxEnableToggle => {
                self.tx_enabled = !self.tx_enabled;
                if self.tx_enabled {
                    out.push(Action::ArmTx);
                } else {
                    self.stop_tx(&mut out);
                    out.push(Action::DisarmTx);
                }
            }
            Ft8Event::Cq => self.qso.start_cq(),
            Ft8Event::Halt => {
                self.qso.halt();
                self.stop_tx(&mut out);
            }
            Ft8Event::DecodeClick(i) => {
                if let Some(row) = self.rows.get(i).cloned() {
                    if row.kind != RowKind::MyTx && self.qso.answer(&row.heard) {
                        self.rx_audio_hz = row.heard.audio_hz as u32;
                    }
                }
            }
            Ft8Event::TxParityToggle => {
                let first = self.qso.tx_first();
                self.qso.set_tx_first(!first);
            }
            Ft8Event::TxFreq(hz) => self.cfg.tx_audio_hz = hz.clamp(200, 2_900),
            // The firmware switches screens; nothing for the contact logic.
            Ft8Event::SwitchToFreedv | Ft8Event::SwitchToListen => {}
            Ft8Event::BandSelect(i) => {
                if i < BANDS.len() && i != self.cfg.band_index {
                    self.cfg.band_index = i;
                    self.qso.halt();
                    self.stop_tx(&mut out);
                    out.push(Action::Retune { dial_hz: self.dial_hz() });
                }
            }
        }
        out
    }

    /// The radio may not transmit (HL2 trip, over-temperature, link lost): TX goes off and stays
    /// off until the operator switches it on again.
    pub fn force_tx_off(&mut self) -> Vec<Action> {
        let mut out = Vec::new();
        if self.tx_enabled || self.transmitting.is_some() {
            self.tx_enabled = false;
            self.stop_tx(&mut out);
            out.push(Action::DisarmTx);
        }
        out
    }

    /// The decoder's result for slot `slot`.
    pub fn on_decodes(&mut self, slot: i64, decodes: &[Heard]) {
        if self.decode_pending == Some(slot) {
            self.decode_pending = None;
        }
        for h in decodes {
            let kind = match parse(&h.text) {
                Parsed::Cq { .. } => RowKind::Cq,
                Parsed::Directed { to, .. } if to == self.cfg.my_call => RowKind::ToMe,
                _ => RowKind::Other,
            };
            self.push_row(Row { heard: h.clone(), kind });
        }
        self.qso.on_decodes(decodes);
    }

    /// Adds a row at the top of the list and drops the oldest beyond `cfg.rows`.
    fn push_row(&mut self, row: Row) {
        self.rows.push_front(row);
        self.rows.truncate(self.cfg.rows);
    }

    /// Call several times a second with UTC in ms, `None` while the clock is not set (then nothing
    /// is transmitted and no slot is decoded: without UTC there are no slots).
    pub fn tick(&mut self, utc_ms: Option<i64>) -> Vec<Action> {
        let mut out = Vec::new();
        let Some(utc_ms) = utc_ms else {
            self.stop_tx(&mut out);
            return out;
        };
        let (slot, ms) = slot_of(utc_ms);

        // A transmission ends with its waveform, or with its slot.
        if let Some((tx_slot, _)) = &self.transmitting {
            if *tx_slot != slot || ms >= TX_START_MS + TX_LEN_MS {
                self.stop_tx(&mut out);
            }
        }

        // The slot's audio to the decoder (not of a slot we transmitted in: we heard nothing).
        if ms >= self.cfg.decode_at_ms && self.decode_asked < slot {
            self.decode_asked = slot;
            if self.last_tx_slot != slot || self.cfg.decode_own_slots {
                self.decode_pending = Some(slot);
                out.push(Action::StartDecode { slot });
            }
        }

        // Our turn? Decide once per slot, after the previous slot's decodes are in or it is too
        // late to wait for them.
        let last_start = TX_START_MS + self.cfg.max_late_ms;
        if self.tx_decided < slot && ms >= TX_START_MS && ms <= last_start {
            let waiting = self.decode_pending == Some(slot - 1) && ms + 100 < last_start;
            if !waiting {
                self.tx_decided = slot;
                if self.tx_enabled && self.qso.is_our_slot(slot) {
                    if let Some(msg) = self.qso.next_tx(slot) {
                        let heard = Heard { slot, snr_db: 0, dt_s: 0.0, audio_hz: self.cfg.tx_audio_hz as f32, text: msg.text() };
                        self.push_row(Row { heard, kind: RowKind::MyTx });
                        self.transmitting = Some((slot, msg.clone()));
                        self.last_tx_slot = slot;
                        out.push(Action::StartTx { slot, msg, audio_hz: self.cfg.tx_audio_hz, skip_ms: ms - TX_START_MS });
                    }
                }
            }
        }
        out
    }

    /// The screen's state.
    pub fn screen(&self, utc_ms: Option<i64>, clock: ClockStatus, link_text: &str, link_ok: bool) -> Ft8ScreenState {
        let (slot, ms) = utc_ms.map(slot_of).unwrap_or((0, 0));
        let tx_message = match &self.transmitting {
            Some((_, m)) => m.text(),
            None => self.preview(),
        };
        Ft8ScreenState {
            band_names: BANDS.iter().map(|b| b.0).collect(),
            band_index: self.cfg.band_index,
            dial_hz: self.dial_hz(),
            utc_s_of_day: utc_ms.map(|t| (t.div_euclid(1_000).rem_euclid(86_400)) as u32),
            clock,
            slot_progress: ms as f32 / SLOT_MS as f32,
            slot_is_ours: utc_ms.is_some() && self.qso.is_our_slot(slot),
            tx_enabled: self.tx_enabled,
            transmitting: self.transmitting.is_some(),
            tx_first: self.qso.tx_first(),
            tx_audio_hz: self.cfg.tx_audio_hz,
            rx_audio_hz: self.rx_audio_hz,
            tx_message,
            qso_text: self.qso.describe(),
            my_call: format!("{} {}", self.cfg.my_call, self.cfg.my_grid),
            link_text: link_text.to_string(),
            link_ok,
            decodes: self
                .rows
                .iter()
                .map(|r| Ft8DecodeRow {
                    utc: hms((r.heard.slot * 15).rem_euclid(86_400) as u32),
                    snr_db: r.heard.snr_db,
                    dt_s: r.heard.dt_s,
                    audio_hz: r.heard.audio_hz as u16,
                    message: r.heard.text.clone(),
                    kind: r.kind,
                })
                .collect(),
        }
    }

    /// What would be sent next, without counting it as sent.
    fn preview(&self) -> String {
        use crate::qso::{State, Step};
        let me = &self.cfg.my_call;
        match self.qso.state() {
            State::Idle => String::new(),
            State::CallingCq { .. } => format!("CQ {} {}", me, self.cfg.my_grid),
            State::Working { dx, step, .. } => match step {
                Step::Grid => format!("{} {} {}", dx, me, self.cfg.my_grid),
                Step::Report => format!("{} {} (report)", dx, me),
                Step::RReport => format!("{} {} (R report)", dx, me),
                Step::Rr73 => format!("{} {} RR73", dx, me),
                Step::S73 => format!("{} {} 73", dx, me),
            },
        }
    }
}
