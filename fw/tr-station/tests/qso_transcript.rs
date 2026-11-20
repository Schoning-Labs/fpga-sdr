// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The station logic run through whole contacts in simulated time: UTC advances in
//! 100 ms ticks, the decoder's answer for each slot comes from a decode list in WSJT-X ALL.TXT
//! layout (`tests/data/*.txt`, written by hand; the repository holds no recordings) a set time
//! after the station asked for it, and the operator's actions come from a script. Checked: which
//! message is transmitted in which slot and how late, what is logged, and that nothing is
//! transmitted without the operator's TX switch or without network time.

use std::collections::HashMap;

use tr_gui::ft8::{Ft8Event, RowKind};
use tr_station::qso::{Heard, State};
use tr_station::station::{slot_of, Action, Station, StationConfig};

/// Midnight UTC of some day, ms. Slot numbers only need a multiple of 60 s.
const DAY0_MS: i64 = 20_738 * 86_400_000;

fn at(hhmmss: &str, ms: i64) -> i64 {
    let n: i64 = hhmmss.parse().unwrap();
    DAY0_MS + ((n / 10_000) * 3_600 + (n / 100 % 100) * 60 + n % 100) * 1_000 + ms
}

fn load(name: &str) -> HashMap<i64, Vec<Heard>> {
    let path = format!("{}/tests/data/{name}", env!("CARGO_MANIFEST_DIR"));
    let mut map: HashMap<i64, Vec<Heard>> = HashMap::new();
    for line in std::fs::read_to_string(path).unwrap().lines().filter(|l| !l.starts_with('#') && !l.trim().is_empty()) {
        let f: Vec<&str> = line.split_whitespace().collect();
        let slot = slot_of(at(f[0].split('_').nth(1).unwrap(), 0)).0;
        let heard = Heard { slot, snr_db: f[4].parse().unwrap(), dt_s: f[5].parse().unwrap(), audio_hz: f[6].parse().unwrap(), text: f[7..].join(" ") };
        map.entry(slot).or_default().push(heard);
    }
    map
}

enum Op {
    Event(Ft8Event),
    /// Click the newest decode line with this text.
    Click(&'static str),
    ForceTxOff,
}

/// One transmission as the radio was told to make it.
#[derive(Debug, PartialEq)]
struct Tx {
    hhmmss: String,
    text: String,
    skip_ms: u32,
}

struct Run {
    tx: Vec<Tx>,
    armed: u32,
    disarmed: u32,
    stops: u32,
    decodes_asked: Vec<i64>,
    station: Station,
}

fn run(list: &str, from: &str, to: &str, decode_ms: i64, clock_set: bool, script: Vec<(i64, Op)>) -> Run {
    let decodes = load(list);
    let mut st = Station::new(StationConfig::new("K1XYZ", "FN42"));
    let mut r = Run { tx: Vec::new(), armed: 0, disarmed: 0, stops: 0, decodes_asked: Vec::new(), station: Station::new(StationConfig::new("K1XYZ", "FN42")) };
    let mut due: Vec<(i64, i64)> = Vec::new(); // (deliver at, slot)
    let mut script = script;
    let mut t = at(from, 0);
    while t <= at(to, 0) {
        let mut actions = Vec::new();
        while let Some(pos) = script.iter().position(|(when, _)| *when <= t) {
            match script.remove(pos).1 {
                Op::Event(e) => actions.extend(st.on_event(e)),
                Op::Click(text) => {
                    let rows = st.screen(Some(t), tr_gui::ft8::ClockStatus::Synced { age_s: 1 }, "", true).decodes;
                    let i = rows.iter().position(|d| d.message == text && d.kind != RowKind::MyTx).unwrap_or_else(|| panic!("no line {text:?} on the screen"));
                    actions.extend(st.on_event(Ft8Event::DecodeClick(i)));
                }
                Op::ForceTxOff => actions.extend(st.force_tx_off()),
            }
        }
        while let Some(pos) = due.iter().position(|(when, _)| *when <= t) {
            let slot = due.remove(pos).1;
            st.on_decodes(slot, decodes.get(&slot).map(Vec::as_slice).unwrap_or(&[]));
        }
        actions.extend(st.tick(clock_set.then_some(t)));
        for a in actions {
            match a {
                Action::ArmTx => r.armed += 1,
                Action::DisarmTx => r.disarmed += 1,
                Action::StopTx => r.stops += 1,
                Action::Retune { .. } => {}
                Action::StartDecode { slot } => {
                    r.decodes_asked.push(slot);
                    due.push((t + decode_ms, slot));
                }
                Action::StartTx { slot, msg, skip_ms, audio_hz } => {
                    assert!(st.tx_enabled(), "a transmission with the TX switch off");
                    assert_eq!(slot, slot_of(t).0);
                    assert_eq!(audio_hz, 1_500);
                    let s = (slot * 15).rem_euclid(86_400);
                    r.tx.push(Tx { hhmmss: format!("{:02}{:02}{:02}", s / 3_600, s / 60 % 60, s % 60), text: msg.text(), skip_ms });
                }
            }
        }
        t += 100;
    }
    r.station = st;
    r
}

fn tx(hhmmss: &str, text: &str, skip_ms: u32) -> Tx {
    Tx { hhmmss: hhmmss.into(), text: text.into(), skip_ms }
}

#[test]
fn answering_a_cq_by_clicking_it() {
    let script = vec![
        (at("182950", 0), Op::Event(Ft8Event::TxEnableToggle)),
        // The decodes of the 18:30:00 slot are on the screen 0.1 s into the next slot; click at 0.3 s.
        (at("183015", 300), Op::Click("CQ DL1ABC JO62")),
    ];
    let r = run("answer_cq.txt", "182945", "183215", 900, true, script);
    assert_eq!(
        r.tx,
        [
            tx("183015", "DL1ABC K1XYZ FN42", 0),
            tx("183045", "DL1ABC K1XYZ R-05", 0),
            tx("183115", "DL1ABC K1XYZ 73", 0),
        ]
    );
    assert_eq!(r.armed, 1);
    assert_eq!(r.stops, 3, "each transmission is stopped when its waveform ends");
    assert_eq!(*r.station.qso.state(), State::Idle);
    let log = &r.station.qso.log;
    assert_eq!(log.len(), 1);
    assert_eq!((log[0].dx.as_str(), log[0].dx_grid.as_deref(), log[0].sent_report, log[0].rcvd_report), ("DL1ABC", Some("JO62"), Some(-5), Some(-12)));
    // Slots we transmitted in are not sent to the decoder.
    let tx_slots: Vec<i64> = ["183015", "183045", "183115"].iter().map(|s| slot_of(at(s, 0)).0).collect();
    assert!(r.decodes_asked.iter().all(|s| !tx_slots.contains(s)));
    assert!(r.decodes_asked.contains(&slot_of(at("183030", 0)).0));
    // The screen: our transmissions and the messages to us are marked.
    let rows = r.station.screen(Some(at("183215", 0)), tr_gui::ft8::ClockStatus::Synced { age_s: 1 }, "", true).decodes;
    assert_eq!(rows.iter().filter(|d| d.kind == RowKind::MyTx).count(), 3);
    assert_eq!(rows.iter().filter(|d| d.kind == RowKind::ToMe).count(), 2);
    assert_eq!(rows.iter().filter(|d| d.kind == RowKind::Cq).count(), 4);
    let first_tx = rows.iter().rev().find(|d| d.kind == RowKind::MyTx).unwrap();
    assert_eq!((first_tx.utc.as_str(), first_tx.message.as_str()), ("18:30:15", "DL1ABC K1XYZ FN42"));
}

#[test]
fn calling_cq_with_a_missed_answer_repeats_the_report() {
    let script = vec![(at("183940", 0), Op::Event(Ft8Event::TxEnableToggle)), (at("183950", 0), Op::Event(Ft8Event::Cq))];
    let r = run("call_cq.txt", "183930", "184330", 900, true, script);
    assert_eq!(
        r.tx,
        [
            tx("184000", "CQ K1XYZ FN42", 0),
            tx("184030", "W9XYZ K1XYZ -15", 0),
            tx("184100", "W9XYZ K1XYZ -15", 0),
            tx("184130", "W9XYZ K1XYZ RR73", 0),
        ]
    );
    assert_eq!(*r.station.qso.state(), State::Idle);
    assert_eq!(r.station.qso.log.len(), 1);
    assert_eq!(r.station.qso.log[0].rcvd_report, Some(-9));
}

#[test]
fn a_slow_decoder_makes_the_answer_start_late_but_in_time() {
    let script = vec![(at("183940", 0), Op::Event(Ft8Event::TxEnableToggle)), (at("183950", 0), Op::Event(Ft8Event::Cq))];
    // Decodes arrive 2.0 s after they were asked for: 1.2 s into the next slot.
    let r = run("call_cq.txt", "183930", "184050", 2_000, true, script);
    // Every transmission waits for the decodes of the slot before it, so each starts 0.7 s late,
    // with the first 0.7 s of its waveform left out.
    assert_eq!(r.tx, [tx("184000", "CQ K1XYZ FN42", 700), tx("184030", "W9XYZ K1XYZ -15", 700)]);

    // 3.5 s: too late for this slot's start. The station does not wait past 2.0 s into the slot;
    // it sends what it had (CQ again), and the answer goes out one cycle later.
    let script = vec![(at("183940", 0), Op::Event(Ft8Event::TxEnableToggle)), (at("183950", 0), Op::Event(Ft8Event::Cq))];
    let r = run("call_cq.txt", "183930", "184110", 3_500, true, script);
    assert_eq!(r.tx[1], tx("184030", "CQ K1XYZ FN42", 1_400));
    assert_eq!(r.tx[2].text, "W9XYZ K1XYZ -15");
    assert_eq!(r.tx[2].hhmmss, "184100");
}

#[test]
fn nothing_is_transmitted_without_the_tx_switch_or_without_network_time() {
    // TX switch never touched: the contact is followed on the screen, nothing is sent.
    let script = vec![(at("183950", 0), Op::Event(Ft8Event::Cq)), (at("184031", 0), Op::Click("K1XYZ W9XYZ EN37"))];
    let r = run("call_cq.txt", "183930", "184330", 900, true, script);
    assert!(r.tx.is_empty());
    assert_eq!(r.armed, 0);
    assert!(!r.station.tx_enabled());

    // TX switch on, but the clock was never set: no slots, no transmission, no decode.
    let script = vec![(at("183940", 0), Op::Event(Ft8Event::TxEnableToggle)), (at("183950", 0), Op::Event(Ft8Event::Cq))];
    let r = run("call_cq.txt", "183930", "184330", 900, false, script);
    assert!(r.tx.is_empty());
    assert!(r.decodes_asked.is_empty());
}

#[test]
fn a_trip_stops_the_transmission_and_tx_stays_off() {
    let script = vec![
        (at("183940", 0), Op::Event(Ft8Event::TxEnableToggle)),
        (at("183950", 0), Op::Event(Ft8Event::Cq)),
        (at("184005", 0), Op::ForceTxOff), // in the middle of the first CQ
    ];
    let r = run("call_cq.txt", "183930", "184330", 900, true, script);
    assert_eq!(r.tx, [tx("184000", "CQ K1XYZ FN42", 0)]);
    assert_eq!((r.stops, r.disarmed), (1, 1));
    assert!(!r.station.tx_enabled());

    // HALT in the middle of a transmission stops it; switching TX off also disarms.
    let script = vec![
        (at("183940", 0), Op::Event(Ft8Event::TxEnableToggle)),
        (at("183950", 0), Op::Event(Ft8Event::Cq)),
        (at("184005", 0), Op::Event(Ft8Event::Halt)),
        (at("184020", 0), Op::Event(Ft8Event::TxEnableToggle)),
    ];
    let r = run("call_cq.txt", "183930", "184330", 900, true, script);
    assert_eq!(r.tx.len(), 1);
    assert_eq!((r.stops, r.armed, r.disarmed), (1, 1, 1));
}

#[test]
fn band_change_retunes_and_drops_the_contact() {
    let mut st = Station::new(StationConfig::new("K1XYZ", "FN42"));
    st.on_event(Ft8Event::Cq);
    assert_eq!(st.on_event(Ft8Event::BandSelect(3)), [Action::Retune { dial_hz: 7_074_000 }]);
    assert_eq!(*st.qso.state(), State::Idle);
    assert!(st.on_event(Ft8Event::BandSelect(3)).is_empty());
    assert!(st.on_event(Ft8Event::BandSelect(99)).is_empty());
    st.on_event(Ft8Event::TxFreq(50));
    assert_eq!(st.cfg.tx_audio_hz, 200);
    st.on_event(Ft8Event::TxParityToggle);
    assert!(!st.qso.tx_first());
}
