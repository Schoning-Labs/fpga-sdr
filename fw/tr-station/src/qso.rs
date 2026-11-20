// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The standard FT8 contact as a state machine (WSJT-X's Tx1 to Tx6):
//!
//! | We call CQ | We answer a CQ |
//! |---|---|
//! | `CQ ME GRID` | (they: `CQ DX GRID`) |
//! | (they: `ME DX GRID`) | `DX ME GRID` |
//! | `DX ME -10` | (they: `ME DX -12`) |
//! | (they: `ME DX R-12`) | `DX ME R-10` |
//! | `DX ME RR73` | (they: `ME DX RR73`) |
//! | (they: `ME DX 73`) | `DX ME 73` |
//!
//! Every message to us from the station we are working moves the contact to the answer that
//! message calls for, whatever we sent last (a station may skip its locator and start with a
//! report, or repeat a message we already answered). Without an answer the same message is sent
//! again in our next slot, up to a limit; then the contact is given up.
//!
//! This decides *what* to send. Whether anything is sent at all is the operator's TX switch, which
//! lives outside this module.

use alloc::format;
use alloc::string::{String, ToString};
use alloc::vec::Vec;

use crate::msg::{report_text, Parsed, Payload, TxMessage};

/// What we send next to the station we are working.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    /// Our locator (answering their CQ).
    Grid,
    /// Their report.
    Report,
    /// "R" and their report.
    RReport,
    /// RR73, sent once.
    Rr73,
    /// 73, sent once.
    S73,
}

/// Where the contact logic stands. `sent` counts the transmissions of the current message.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum State {
    /// Nothing to send.
    Idle,
    /// Sending CQ.
    CallingCq { sent: u8 },
    /// In contact with `dx`; `step` is the message sent next.
    Working { dx: String, step: Step, sent: u8 },
}

/// A message as heard, with what the decoder measured.
#[derive(Clone, Debug, PartialEq)]
pub struct Heard {
    /// Slot the message was received in (UTC seconds divided by 15).
    pub slot: i64,
    /// Signal to noise ratio in 2.5 kHz, dB.
    pub snr_db: i8,
    /// Time offset of the signal from the slot start, seconds.
    pub dt_s: f32,
    /// Audio frequency of the lowest tone, Hz.
    pub audio_hz: f32,
    /// The 13-character message text.
    pub text: String,
}

/// A finished contact.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LogEntry {
    /// The other station's call sign.
    pub dx: String,
    /// Their locator, if they sent one.
    pub dx_grid: Option<String>,
    /// The report we sent them, dB.
    pub sent_report: Option<i8>,
    /// The report they sent us, dB.
    pub rcvd_report: Option<i8>,
    /// Slot in which it was completed.
    pub slot: i64,
}

/// The operator's call sign and locator, and the give-up limits.
#[derive(Clone, Debug)]
pub struct QsoConfig {
    /// Our call sign.
    pub my_call: String,
    /// Our four-character locator.
    pub my_grid: String,
    /// CQ calls without an answer before giving up (12 = WSJT-X's 6-minute watchdog).
    pub cq_limit: u8,
    /// Times one message of a contact is sent without an answer before giving up.
    pub repeat_limit: u8,
}

impl QsoConfig {
    /// The defaults: 12 CQ calls and 5 repeats.
    pub fn new(my_call: &str, my_grid: &str) -> Self {
        QsoConfig { my_call: my_call.to_string(), my_grid: my_grid.to_string(), cq_limit: 12, repeat_limit: 5 }
    }
}

/// The contact state machine and its log.
pub struct Qso {
    /// Call sign, locator and limits; the limits may be changed while idle.
    pub cfg: QsoConfig,
    state: State,
    /// We transmit in the slots that start at second 00 and 30 (even slot numbers).
    tx_first: bool,
    /// The contact in progress: what we know of the other station.
    dx_grid: Option<String>,
    /// Their signal as we measured it (the report we send).
    sent_report: Option<i8>,
    rcvd_report: Option<i8>,
    /// True once the contact in progress is in `log`, so a repeated message does not log it twice.
    logged: bool,
    /// Finished contacts, oldest first.
    pub log: Vec<LogEntry>,
    /// Why the last contact ended, for the screen.
    last_end: &'static str,
}

/// True for a slot that starts at second 00 or 30.
pub fn is_first_slot(slot: i64) -> bool {
    slot.rem_euclid(2) == 0
}

impl Qso {
    /// An idle contact logic that transmits in the even slots.
    pub fn new(cfg: QsoConfig) -> Self {
        Qso { cfg, state: State::Idle, tx_first: true, dx_grid: None, sent_report: None, rcvd_report: None, logged: false, log: Vec::new(), last_end: "" }
    }

    /// The current state.
    pub fn state(&self) -> &State {
        &self.state
    }

    /// True if we transmit in the slots that start at second 00 and 30.
    pub fn tx_first(&self) -> bool {
        self.tx_first
    }

    /// The operator's choice of TX slots. Answering a station overrides it (we send when it listens).
    pub fn set_tx_first(&mut self, first: bool) {
        self.tx_first = first;
    }

    /// True if `slot` is one we transmit in.
    pub fn is_our_slot(&self, slot: i64) -> bool {
        is_first_slot(slot) == self.tx_first
    }

    /// Starts a contact with `dx` at `step` and forgets everything about the previous one.
    fn begin(&mut self, dx: &str, step: Step) {
        self.state = State::Working { dx: dx.to_string(), step, sent: 0 };
        self.dx_grid = None;
        self.sent_report = None;
        self.rcvd_report = None;
        self.logged = false;
    }

    /// Goes idle and keeps `why` for the screen.
    fn end(&mut self, why: &'static str) {
        self.state = State::Idle;
        self.last_end = why;
    }

    /// Starts calling CQ in our next slots.
    pub fn start_cq(&mut self) {
        self.state = State::CallingCq { sent: 0 };
    }

    /// Stops whatever is going on (the HALT button).
    pub fn halt(&mut self) {
        self.end("halted");
    }

    /// The operator picked a decoded message. A CQ: call that station. A message to us: continue
    /// from it. Anything else between two stations: call the sender. We then transmit in the
    /// slots the picked station listens in. Returns false if the message offers no one to call.
    pub fn answer(&mut self, h: &Heard) -> bool {
        match crate::msg::parse(&h.text) {
            Parsed::Cq { caller, grid } if caller != self.cfg.my_call => {
                self.begin(&caller, Step::Grid);
                self.dx_grid = grid;
            }
            Parsed::Directed { to, from, payload } if from != self.cfg.my_call => {
                self.begin(&from, Step::Grid);
                if to == self.cfg.my_call {
                    self.advance(&from, &payload, h);
                }
            }
            _ => return false,
        }
        self.tx_first = !is_first_slot(h.slot);
        true
    }

    /// Moves the contact with `dx` to the answer `payload` calls for.
    fn advance(&mut self, dx: &str, payload: &Payload, h: &Heard) {
        let step = match payload {
            Payload::Grid(g) => {
                self.dx_grid = Some(g.clone());
                self.sent_report = Some(h.snr_db);
                Step::Report
            }
            Payload::Empty => {
                self.sent_report = Some(h.snr_db);
                Step::Report
            }
            Payload::Report(r) => {
                self.rcvd_report = Some(*r);
                self.sent_report.get_or_insert(h.snr_db);
                Step::RReport
            }
            Payload::RReport(r) => {
                self.rcvd_report = Some(*r);
                self.complete(dx, h.slot);
                Step::Rr73
            }
            Payload::Rrr | Payload::Rr73 => {
                self.complete(dx, h.slot);
                Step::S73
            }
            Payload::S73 => {
                self.complete(dx, h.slot);
                self.end("contact complete");
                return;
            }
        };
        self.state = State::Working { dx: dx.to_string(), step, sent: 0 };
    }

    /// Puts the contact in the log, once.
    fn complete(&mut self, dx: &str, slot: i64) {
        if !self.logged {
            self.logged = true;
            self.log.push(LogEntry { dx: dx.to_string(), dx_grid: self.dx_grid.clone(), sent_report: self.sent_report, rcvd_report: self.rcvd_report, slot });
        }
    }

    /// Everything decoded in one slot. Only messages to us from the station we work (or, while
    /// calling CQ, from the first station that answers) change anything.
    pub fn on_decodes(&mut self, decodes: &[Heard]) {
        for h in decodes {
            let Parsed::Directed { to, from, payload } = crate::msg::parse(&h.text) else { continue };
            if to != self.cfg.my_call {
                continue;
            }
            match &self.state {
                State::CallingCq { .. } => {
                    if matches!(payload, Payload::Grid(_) | Payload::Report(_) | Payload::Empty) {
                        self.begin(&from, Step::Report);
                        self.advance(&from, &payload, h);
                    }
                }
                State::Working { dx, .. } if *dx == from => {
                    let dx = dx.clone();
                    self.advance(&dx, &payload, h);
                }
                _ => {}
            }
        }
    }

    /// The message for our slot `slot`, or `None` if there is nothing to send. Counts the
    /// transmission: call it once per slot, and only when the message will be sent.
    pub fn next_tx(&mut self, slot: i64) -> Option<TxMessage> {
        if !self.is_our_slot(slot) {
            return None;
        }
        let me = self.cfg.my_call.clone();
        match self.state.clone() {
            State::Idle => None,
            State::CallingCq { sent } => {
                if sent >= self.cfg.cq_limit {
                    self.end("no answer to CQ");
                    return None;
                }
                self.state = State::CallingCq { sent: sent + 1 };
                Some(TxMessage::new("CQ", &me, &self.cfg.my_grid))
            }
            State::Working { dx, step, sent } => {
                // The two closing messages go out once; the others until the limit.
                let limit = if matches!(step, Step::Rr73 | Step::S73) { 1 } else { self.cfg.repeat_limit };
                if sent >= limit {
                    self.end(if self.logged { "contact complete" } else { "no answer" });
                    return None;
                }
                let third = match step {
                    Step::Grid => self.cfg.my_grid.clone(),
                    Step::Report => report_text(self.sent_report.unwrap_or(-15)),
                    Step::RReport => format!("R{}", report_text(self.sent_report.unwrap_or(-15))),
                    Step::Rr73 => "RR73".to_string(),
                    Step::S73 => "73".to_string(),
                };
                self.state = State::Working { dx: dx.clone(), step, sent: sent + 1 };
                Some(TxMessage::new(&dx, &me, &third))
            }
        }
    }

    /// One line for the screen.
    pub fn describe(&self) -> String {
        match &self.state {
            State::Idle if self.last_end.is_empty() => "idle".to_string(),
            State::Idle => format!("idle ({})", self.last_end),
            State::CallingCq { sent } => format!("calling CQ ({} sent)", sent),
            State::Working { dx, step, sent } => {
                let what = match step {
                    Step::Grid => "calling",
                    Step::Report => "sending report",
                    Step::RReport => "report received, sending R report",
                    Step::Rr73 => "sending RR73",
                    Step::S73 => "sending 73",
                };
                format!("working {}: {} ({} sent)", dx, what, sent)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn heard(slot: i64, snr: i8, text: &str) -> Heard {
        Heard { slot, snr_db: snr, dt_s: 0.1, audio_hz: 1_200.0, text: text.to_string() }
    }

    fn qso() -> Qso {
        Qso::new(QsoConfig::new("K1XYZ", "FN42"))
    }

    #[test]
    fn answering_a_cq_runs_to_73_and_logs() {
        let mut q = qso();
        // Heard in slot 101 (odd): we transmit in even slots.
        assert!(q.answer(&heard(101, -8, "CQ DL1ABC JO62")));
        assert!(q.tx_first());
        assert_eq!(q.next_tx(101), None, "not our slot");
        assert_eq!(q.next_tx(102).unwrap().text(), "DL1ABC K1XYZ FN42");
        q.on_decodes(&[heard(103, -6, "K1XYZ DL1ABC -12"), heard(103, 0, "W1AW DL1ABC -01")]);
        assert_eq!(q.next_tx(104).unwrap().text(), "DL1ABC K1XYZ R-06");
        q.on_decodes(&[heard(105, -7, "K1XYZ DL1ABC RR73")]);
        assert_eq!(q.log.len(), 1);
        assert_eq!(q.log[0], LogEntry { dx: "DL1ABC".into(), dx_grid: Some("JO62".into()), sent_report: Some(-6), rcvd_report: Some(-12), slot: 105 });
        assert_eq!(q.next_tx(106).unwrap().text(), "DL1ABC K1XYZ 73");
        assert_eq!(q.next_tx(108), None, "73 goes out once");
        assert_eq!(*q.state(), State::Idle);
        assert_eq!(q.log.len(), 1);
    }

    #[test]
    fn calling_cq_answered_with_a_locator() {
        let mut q = qso();
        q.set_tx_first(false);
        q.start_cq();
        assert_eq!(q.next_tx(201).unwrap().text(), "CQ K1XYZ FN42");
        q.on_decodes(&[heard(202, -15, "K1XYZ W9XYZ EN37"), heard(202, -3, "K1XYZ JA1XYZ PM95")]);
        // The first caller is worked; the second is ignored.
        assert_eq!(q.next_tx(203).unwrap().text(), "W9XYZ K1XYZ -15");
        q.on_decodes(&[heard(204, -14, "K1XYZ W9XYZ R-09")]);
        assert_eq!(q.next_tx(205).unwrap().text(), "W9XYZ K1XYZ RR73");
        assert_eq!(q.log[0].rcvd_report, Some(-9));
        q.on_decodes(&[heard(206, -14, "K1XYZ W9XYZ 73")]);
        assert_eq!(*q.state(), State::Idle);
        assert_eq!(q.next_tx(207), None);
        assert_eq!(q.log.len(), 1);
    }

    #[test]
    fn a_caller_that_starts_with_a_report_gets_an_r_report() {
        let mut q = qso();
        q.start_cq();
        q.next_tx(300);
        q.on_decodes(&[heard(301, 2, "K1XYZ G0XYZ -04")]);
        assert_eq!(q.next_tx(302).unwrap().text(), "G0XYZ K1XYZ R+02");
    }

    #[test]
    fn repeats_without_an_answer_then_gives_up() {
        let mut q = qso();
        q.answer(&heard(1, -8, "CQ DL1ABC JO62"));
        for k in 0..5 {
            assert_eq!(q.next_tx(2 + 2 * k).unwrap().text(), "DL1ABC K1XYZ FN42");
        }
        assert_eq!(q.next_tx(12), None);
        assert_eq!(*q.state(), State::Idle);
        assert!(q.log.is_empty());
        assert_eq!(q.describe(), "idle (no answer)");
    }

    #[test]
    fn a_repeated_r_report_gets_rr73_again_and_one_log_entry() {
        let mut q = qso();
        q.start_cq();
        q.next_tx(0);
        q.on_decodes(&[heard(1, -10, "K1XYZ W9XYZ EN37")]);
        q.next_tx(2);
        q.on_decodes(&[heard(3, -10, "K1XYZ W9XYZ R-05")]);
        assert_eq!(q.next_tx(4).unwrap().text(), "W9XYZ K1XYZ RR73");
        // They did not copy it and send their R report again.
        q.on_decodes(&[heard(5, -10, "K1XYZ W9XYZ R-05")]);
        assert_eq!(q.next_tx(6).unwrap().text(), "W9XYZ K1XYZ RR73");
        assert_eq!(q.next_tx(8), None);
        assert_eq!(q.log.len(), 1);
        assert_eq!(q.describe(), "idle (contact complete)");
    }

    #[test]
    fn cq_stops_at_the_limit_and_halt_stops_at_once() {
        let mut q = qso();
        q.cfg.cq_limit = 3;
        q.start_cq();
        assert!(q.next_tx(0).is_some() && q.next_tx(2).is_some() && q.next_tx(4).is_some());
        assert_eq!(q.next_tx(6), None);
        q.start_cq();
        q.halt();
        assert_eq!(q.next_tx(8), None);
    }

    #[test]
    fn picking_a_message_to_us_continues_from_it() {
        let mut q = qso();
        assert!(q.answer(&heard(11, -3, "K1XYZ PY2XYZ -17")));
        assert!(q.tx_first());
        assert_eq!(q.next_tx(12).unwrap().text(), "PY2XYZ K1XYZ R-03");
        // Our own call in a CQ, or free text, offers no one to call.
        assert!(!q.answer(&heard(11, 0, "CQ K1XYZ FN42")));
        assert!(!q.answer(&heard(11, 0, "TNX BOB 73 GL")));
    }
}
