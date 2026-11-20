// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Host tests of the network input (docs/NETINPUT.md): the parser, scripted event streams applied through
//! `NetInputService::poll` (the function the firmware calls every pass), malformed datagrams, transmit keys, and the
//! golden datagrams that `tools/test_radio_input.py` also checks its packet builder against.

use std::collections::VecDeque;

use tr_input::*;
use tr_usbh::hid::{InputEvent, Layout, MOD_LSHIFT};

// ----- models of the screen and of the socket -----

struct Screen {
    x: i32,
    y: i32,
    log: Vec<InputEvent>,
    keys: Vec<u8>,
}

impl Screen {
    fn new() -> Self {
        Screen { x: 960, y: 540, log: Vec::new(), keys: Vec::new() }
    }
}

impl Sink for Screen {
    fn pointer(&self) -> (i32, i32) {
        (self.x, self.y)
    }
    fn input(&mut self, e: InputEvent) {
        if let InputEvent::PointerMove { dx, dy } = e {
            // the same clamp as tr_gui::input::dispatch
            self.x = (self.x + dx as i32).clamp(0, SCREEN_WIDTH - 1);
            self.y = (self.y + dy as i32).clamp(0, SCREEN_HEIGHT - 1);
        }
        self.log.push(e);
    }
    fn console_key(&mut self, c: u8) {
        self.keys.push(c);
    }
}

#[derive(Default)]
struct Socket {
    inbox: VecDeque<(Vec<u8>, ([u8; 4], u16))>,
    sent: Vec<(([u8; 4], u16), Vec<u8>)>,
}

impl Datagrams for Socket {
    fn recv(&mut self, buf: &mut [u8]) -> Option<(usize, ([u8; 4], u16))> {
        let (d, peer) = self.inbox.pop_front()?;
        let n = d.len().min(buf.len());
        buf[..n].copy_from_slice(&d[..n]);
        Some((d.len(), peer))
    }
    fn send(&mut self, to: ([u8; 4], u16), data: &[u8]) -> bool {
        self.sent.push((to, data.to_vec()));
        true
    }
}

const PC: ([u8; 4], u16) = ([192, 168, 2, 10], 50_000);

fn dg(kind: u8, seq: u16, events: &[Event]) -> Vec<u8> {
    let mut buf = [0u8; 600];
    let mut b = Builder::new(&mut buf, kind, seq);
    for e in events {
        b.push(*e);
    }
    let n = b.finish();
    buf[..n].to_vec()
}

fn events_dg(seq: u16, events: &[Event]) -> Vec<u8> {
    dg(kind::EVENTS, seq, events)
}

struct Rig {
    svc: NetInputService,
    screen: Screen,
    sock: Socket,
    now: u32,
}

impl Rig {
    fn new() -> Self {
        Rig { svc: NetInputService::new(Layout::Us), screen: Screen::new(), sock: Socket::default(), now: 1_000 }
    }
    fn send(&mut self, d: Vec<u8>) {
        self.sock.inbox.push_back((d, PC));
    }
    fn pass(&mut self) -> PassResult {
        self.now += 100;
        self.svc.poll(&mut self.sock, &mut self.screen, self.now)
    }
    fn log(&mut self) -> Vec<InputEvent> {
        std::mem::take(&mut self.screen.log)
    }
}

// ----- the parser -----

#[test]
fn parses_every_event_kind() {
    let evs = [
        Event::MoveRel { dx: -5, dy: 7 },
        Event::MoveAbs { x: 1919, y: 1079 },
        Event::ButtonDown(2),
        Event::ButtonUp(0),
        Event::Wheel(-3),
        Event::KeyDown { usage: 4, mods: 2 },
        Event::KeyUp { usage: 4, mods: 2 },
        Event::ReleaseAll,
    ];
    let d = events_dg(7, &evs);
    let p = parse(&d).unwrap();
    assert_eq!((p.kind, p.seq, p.count()), (Kind::Events, 7, 8));
    assert_eq!(p.events().collect::<Vec<_>>(), evs);
    // the wire bytes of one event, fixed by the doc
    assert_eq!(&events_dg(1, &[Event::MoveRel { dx: 1, dy: -1 }])[8..], &[0x01, 0, 1, 0xFF, 0xFF]);
    // a heartbeat has no events
    assert_eq!(parse(&events_dg(8, &[])).unwrap().count(), 0);
    assert_eq!(parse(&dg(kind::HELLO, 0, &[])).unwrap().kind, Kind::Hello);
}

#[test]
fn malformed_datagrams_are_rejected_whole() {
    let good = events_dg(1, &[Event::MoveRel { dx: 1, dy: 1 }, Event::ButtonDown(0)]);
    assert!(parse(&good).is_ok());
    assert_eq!(parse(&good[..7]), Err(Reject::TooShort));
    assert_eq!(parse(&[]), Err(Reject::TooShort));
    let mut bad = good.clone();
    bad[0] = b'X';
    assert_eq!(parse(&bad), Err(Reject::Magic));
    let mut bad = good.clone();
    bad[4] = 2;
    assert_eq!(parse(&bad), Err(Reject::Version));
    let mut bad = good.clone();
    bad[5] = 9;
    assert_eq!(parse(&bad), Err(Reject::Kind));
    // cut inside the second event
    assert_eq!(parse(&good[..good.len() - 1]), Err(Reject::Truncated));
    // unknown event tag
    let mut bad = good.clone();
    bad.push(0x7E);
    assert_eq!(parse(&bad), Err(Reject::UnknownEvent(0x7E)));
    // a hello with a body
    let mut bad = dg(kind::HELLO, 0, &[]);
    bad.push(1);
    assert_eq!(parse(&bad), Err(Reject::Body));
    // values off the screen or off the buttons
    assert_eq!(parse(&events_dg(1, &[Event::ButtonDown(3)])), Err(Reject::Value));
    assert_eq!(parse(&events_dg(1, &[Event::MoveAbs { x: 1920, y: 0 }])), Err(Reject::Value));
    assert_eq!(parse(&events_dg(1, &[Event::MoveAbs { x: 0, y: 1080 }])), Err(Reject::Value));
    // too many events (65 one-byte events), too long
    let mut many = events_dg(1, &[]);
    many.extend(std::iter::repeat(tag::RELEASE_ALL).take(65));
    assert_eq!(parse(&many), Err(Reject::TooManyEvents));
    many.truncate(HEADER_LEN + 64);
    assert!(parse(&many).is_ok());
    let mut long = events_dg(1, &[]);
    long.extend(std::iter::repeat(tag::RELEASE_ALL).take(MAX_DATAGRAM));
    assert_eq!(parse(&long), Err(Reject::TooLong));
}

#[test]
fn status_round_trip() {
    let s = Status { seq: 0xABCD, applied: 0x0102_0304, x: 1919, y: 1079, blocked: 7 };
    let b = s.encode();
    assert_eq!(b.len(), STATUS_LEN);
    assert_eq!(Status::decode(&b), Some(s));
    assert_eq!(Status::decode(&b[..17]), None);
    // the board's own status datagram is not input
    let mut rig = Rig::new();
    rig.send(b.to_vec());
    rig.pass();
    assert_eq!((rig.svc.input.applied, rig.svc.input.rejected), (0, 0));
}

// ----- a scripted stream through the service -----

#[test]
fn moves_are_merged_and_clamped() {
    let mut rig = Rig::new();
    rig.send(events_dg(1, &[Event::MoveRel { dx: 10, dy: 5 }, Event::MoveRel { dx: -3, dy: 20 }, Event::MoveRel { dx: 1, dy: 1 }]));
    let r = rig.pass();
    assert_eq!((r.datagrams, r.events), (1, 3));
    // three moves, one event to the screen
    assert_eq!(rig.log(), [InputEvent::PointerMove { dx: 8, dy: 26 }]);
    assert_eq!((rig.screen.x, rig.screen.y), (968, 566));
    // far past the corner: held at the corner, and the surplus does not come back later
    rig.send(events_dg(2, &[Event::MoveRel { dx: 30_000, dy: 30_000 }, Event::MoveRel { dx: -100, dy: -100 }]));
    rig.pass();
    assert_eq!((rig.screen.x, rig.screen.y), (SCREEN_WIDTH - 101, SCREEN_HEIGHT - 101));
    rig.send(events_dg(3, &[Event::MoveRel { dx: -30_000, dy: -30_000 }]));
    rig.pass();
    assert_eq!((rig.screen.x, rig.screen.y), (0, 0));
}

#[test]
fn absolute_moves_land_on_the_pixel() {
    let mut rig = Rig::new();
    rig.send(events_dg(1, &[Event::MoveAbs { x: 100, y: 200 }, Event::MoveAbs { x: 1919, y: 1079 }, Event::MoveAbs { x: 5, y: 6 }]));
    rig.pass();
    assert_eq!((rig.screen.x, rig.screen.y), (5, 6));
    assert_eq!(rig.log().len(), 1);
    // absolute then relative in one datagram
    rig.send(events_dg(2, &[Event::MoveAbs { x: 500, y: 500 }, Event::MoveRel { dx: 3, dy: -4 }]));
    rig.pass();
    assert_eq!((rig.screen.x, rig.screen.y), (503, 496));
    // the same position again: nothing to tell the screen
    rig.log();
    rig.send(events_dg(3, &[Event::MoveAbs { x: 503, y: 496 }]));
    rig.pass();
    assert!(rig.log().is_empty());
}

#[test]
fn a_click_happens_where_the_pointer_was_moved_to_first() {
    let mut rig = Rig::new();
    rig.send(events_dg(
        1,
        &[Event::MoveRel { dx: 40, dy: 0 }, Event::ButtonDown(0), Event::MoveRel { dx: 0, dy: 10 }, Event::ButtonUp(0), Event::Wheel(1), Event::MoveRel { dx: 1, dy: 1 }],
    ));
    let r = rig.pass();
    assert_eq!(r.events, 6);
    assert_eq!(
        rig.log(),
        [
            InputEvent::PointerMove { dx: 40, dy: 0 },
            InputEvent::Button { button: 0, down: true },
            InputEvent::PointerMove { dx: 0, dy: 10 },
            InputEvent::Button { button: 0, down: false },
            InputEvent::Wheel { delta: 1 },
            InputEvent::PointerMove { dx: 1, dy: 1 },
        ]
    );
    assert!(rig.svc.tx_guard_active(rig.now));
}

#[test]
fn keys_reach_the_screen_and_the_console_queue() {
    let mut rig = Rig::new();
    rig.send(events_dg(
        1,
        &[
            Event::KeyDown { usage: 0x0B, mods: 0 },      // h
            Event::KeyUp { usage: 0x0B, mods: 0 },
            Event::KeyDown { usage: 0x10, mods: 0 },      // m
            Event::KeyUp { usage: 0x10, mods: 0 },
            Event::KeyDown { usage: 0x2F, mods: 0 },      // [
            Event::KeyDown { usage: 0x29, mods: 0 },      // Escape
            Event::KeyDown { usage: 0xE1, mods: 0x02 },   // Shift
        ],
    ));
    rig.pass();
    assert_eq!(rig.screen.keys, b"hm[\x1b");
    assert_eq!(rig.log().len(), 7);
    assert!(rig.svc.input.holding());
    assert_eq!(rig.svc.input.tx_blocked, 0);
}

#[test]
fn transmit_keys_never_get_through() {
    let mut rig = Rig::new();
    let mut seq = 1;
    // t c s u, the digits, - and = on the main block, the number pad's digits, minus and plus: plain, shifted, with AltGr
    let mut usages = vec![0x17u8, 0x06, 0x16, 0x18, 0x2D, 0x2E, 0x56, 0x57, 0x38, 0x30];
    usages.extend(0x1E..=0x27);
    usages.extend(0x59..=0x62);
    for &u in &usages {
        for mods in [0u8, MOD_LSHIFT, 0x40, 0x01] {
            rig.send(events_dg(seq, &[Event::KeyDown { usage: u, mods }, Event::KeyUp { usage: u, mods }]));
            seq += 1;
        }
    }
    rig.pass();
    while rig.pass().datagrams > 0 {}
    assert_eq!(rig.screen.keys, b"", "a transmit key reached the console queue");
    assert!(rig.log().is_empty(), "a transmit key reached the screen");
    assert_eq!(rig.svc.input.tx_blocked as usize, usages.len() * 4);
    // the keys around them still work: h (halt), m (FreeDV screen), [ ] (band), d e q (FreeDV)
    rig.send(events_dg(seq, &[Event::KeyDown { usage: 0x0B, mods: 0 }, Event::KeyDown { usage: 0x10, mods: 0 }, Event::KeyDown { usage: 0x30, mods: 0 }]));
    // (0x30 is "]" on the US layout, "+" on the German: blocked for that reason)
    rig.pass();
    assert_eq!(rig.screen.keys, b"hm");
}

#[test]
fn every_character_the_console_maps_to_transmit_is_blocked() {
    use tr_usbh::hid::key_char;
    for layout in [Layout::Us, Layout::De] {
        for usage in 0..=255u8 {
            for mods in [0u8, 0x02, 0x20, 0x40, 0x01, 0x03, 0x42] {
                if let Some(c) = key_char(layout, usage, mods) {
                    if c.is_ascii() && is_tx_char(c as u8) {
                        assert!(is_tx_key(usage), "usage {usage:#04x} mods {mods:#04x} {layout:?} gives {c:?} and is not blocked");
                    }
                }
            }
        }
    }
    for c in b"tcsu0123456789-+=TCSU" {
        assert!(is_tx_char(*c));
    }
    for c in b"hmdeq[],.<>" {
        assert!(!is_tx_char(*c));
    }
}

/// The arrow, page and Home/End keys reach the console queue as `code`s (the LISTEN screen's tuning and volume keys),
/// Shift with up and down as their own codes; the LISTEN screen's letters pass; none of them is a transmit key.
#[test]
fn navigation_keys_and_listen_letters_reach_the_console_queue() {
    use tr_usbh::hid::key;
    let mut rig = Rig::new();
    let mut ev = Vec::new();
    for (u, m) in [(key::LEFT, 0), (key::RIGHT, 0), (key::UP, 0), (key::DOWN, 0), (key::UP, MOD_LSHIFT), (key::DOWN, MOD_LSHIFT), (key::PAGE_UP, 0), (key::PAGE_DOWN, 0), (key::HOME, 0), (key::END, 0)] {
        ev.push(Event::KeyDown { usage: u, mods: m });
        ev.push(Event::KeyUp { usage: u, mods: m });
    }
    // l k w a g f b q o , . m: the LISTEN letters (US usages)
    for u in [0x0Fu8, 0x0E, 0x1A, 0x04, 0x0A, 0x09, 0x05, 0x14, 0x12, 0x36, 0x37, 0x10] {
        ev.push(Event::KeyDown { usage: u, mods: 0 });
        ev.push(Event::KeyUp { usage: u, mods: 0 });
    }
    rig.send(events_dg(1, &ev));
    rig.pass();
    let mut want = vec![code::LEFT, code::RIGHT, code::UP, code::DOWN, code::SHIFT_UP, code::SHIFT_DOWN, code::PAGE_UP, code::PAGE_DOWN, code::HOME, code::END];
    want.extend_from_slice(b"lkwagfbqo,.m");
    assert_eq!(rig.screen.keys, want);
    assert_eq!(rig.svc.input.tx_blocked, 0);
    for c in want {
        assert!(!is_tx_char(c), "{c:#04x}");
    }
    assert_eq!(console_code(Layout::De, 0x1D, 0), Some(b'y'), "German layout: y and z swap");
    assert_eq!(console_code(Layout::Us, key::F1, 0), None);
}

/// A terminal's escape sequences for the same keys become the same codes; other bytes pass unchanged.
#[test]
fn terminal_escape_sequences_become_console_codes() {
    let mut a = AnsiKeys::new();
    let mut out = Vec::new();
    for b in b"\x1b[A\x1b[B\x1b[C\x1b[D\x1b[5~\x1b[6~\x1b[H\x1b[4~\x1b[1;2A\x1b[1;2B\x1bOAx[\x1b\x1bq\x1b[99Zm" {
        if let Some(c) = a.feed(*b) {
            out.push(c);
        }
    }
    let mut want = vec![code::UP, code::DOWN, code::RIGHT, code::LEFT, code::PAGE_UP, code::PAGE_DOWN, code::HOME, code::END, code::SHIFT_UP, code::SHIFT_DOWN, code::UP];
    want.extend_from_slice(b"x[qm");
    assert_eq!(out, want);
}

#[test]
fn malformed_and_stale_datagrams_change_nothing() {
    let mut rig = Rig::new();
    rig.send(events_dg(10, &[Event::MoveRel { dx: 5, dy: 5 }]));
    rig.pass();
    rig.log();
    let applied = rig.svc.input.applied;
    // garbage, truncated, wrong version, oversize
    rig.send(vec![1, 2, 3]);
    rig.send(events_dg(11, &[Event::MoveRel { dx: 9, dy: 9 }, Event::ButtonDown(0)])[..14].to_vec());
    let mut v = events_dg(12, &[Event::MoveRel { dx: 9, dy: 9 }]);
    v[4] = 99;
    rig.send(v);
    let mut big = events_dg(13, &[Event::MoveRel { dx: 9, dy: 9 }]);
    big.resize(2_000, 0);
    rig.send(big);
    // the same sequence again, and an older one
    rig.send(events_dg(10, &[Event::MoveRel { dx: 9, dy: 9 }]));
    rig.send(events_dg(9, &[Event::MoveRel { dx: 9, dy: 9 }]));
    rig.pass();
    assert!(rig.log().is_empty());
    assert_eq!(rig.svc.input.applied, applied);
    assert_eq!(rig.svc.input.rejected, 4);
    assert_eq!(rig.svc.input.stale, 2);
    assert!(!rig.svc.input.holding());
    // a newer one, across the wrap of the 16-bit counter, still works
    rig.send(events_dg(0x7000, &[Event::MoveRel { dx: 1, dy: 0 }]));
    rig.send(events_dg(0xE000, &[Event::MoveRel { dx: 1, dy: 0 }]));
    rig.send(events_dg(0x5000, &[Event::MoveRel { dx: 1, dy: 0 }]));
    rig.pass();
    assert_eq!(rig.log().len(), 3);
}

#[test]
fn a_new_sequence_is_taken_after_a_silence() {
    let mut rig = Rig::new();
    rig.send(events_dg(500, &[Event::MoveRel { dx: 1, dy: 0 }]));
    rig.pass();
    rig.now += IDLE_RELEASE_MS + 1;
    rig.send(events_dg(3, &[Event::MoveRel { dx: 1, dy: 0 }]));
    rig.pass();
    assert_eq!(rig.screen.x, 962);
}

#[test]
fn a_hello_restarts_the_sequence_and_is_answered_at_once() {
    let mut rig = Rig::new();
    rig.send(events_dg(500, &[Event::MoveAbs { x: 10, y: 20 }]));
    rig.pass();
    rig.sock.sent.clear();
    // the PC tool starts again with a low sequence number: ignored until it says hello
    rig.send(events_dg(3, &[Event::MoveRel { dx: 1, dy: 1 }]));
    rig.pass();
    assert_eq!((rig.screen.x, rig.screen.y), (10, 20));
    rig.send(dg(kind::HELLO, 0, &[]));
    let r = rig.pass();
    assert!(r.replied);
    let (to, bytes) = rig.sock.sent.last().unwrap().clone();
    assert_eq!(to, PC);
    let s = Status::decode(&bytes).unwrap();
    assert_eq!((s.x, s.y, s.seq, s.applied), (10, 20, 500, 1));
    rig.send(events_dg(3, &[Event::MoveRel { dx: 1, dy: 1 }]));
    rig.pass();
    assert_eq!((rig.screen.x, rig.screen.y), (11, 21));
}

#[test]
fn status_reply_is_rate_limited_and_carries_counters() {
    let mut rig = Rig::new();
    rig.send(events_dg(1, &[Event::MoveAbs { x: 300, y: 400 }, Event::KeyDown { usage: 0x17, mods: 0 }]));
    assert!(rig.pass().replied);
    let s = Status::decode(&rig.sock.sent[0].1).unwrap();
    assert_eq!((s.seq, s.applied, s.x, s.y, s.blocked), (1, 1, 300, 400, 1));
    // a second datagram 100 ms later: applied, no reply yet
    rig.send(events_dg(2, &[Event::MoveRel { dx: 1, dy: 0 }]));
    assert!(!rig.pass().replied);
    rig.send(events_dg(3, &[Event::MoveRel { dx: 1, dy: 0 }]));
    assert!(rig.pass().replied);
    let s = Status::decode(&rig.sock.sent[1].1).unwrap();
    assert_eq!((s.seq, s.applied, s.x), (3, 3, 302));
    // nothing came: nothing is sent
    let n = rig.sock.sent.len();
    rig.pass();
    assert_eq!(rig.sock.sent.len(), n);
}

#[test]
fn a_flood_is_taken_in_slices() {
    let mut rig = Rig::new();
    for i in 0..40u16 {
        rig.send(events_dg(i + 1, &[Event::MoveRel { dx: 1, dy: 0 }; 10]));
    }
    let r = rig.pass();
    assert!(r.datagrams <= MAX_DATAGRAMS_PER_PASS);
    assert!(r.events <= MAX_EVENTS_PER_PASS + MAX_EVENTS_PER_DATAGRAM);
    assert!(!rig.sock.inbox.is_empty(), "the rest waits in the socket");
    let mut passes = 1;
    while !rig.sock.inbox.is_empty() {
        rig.pass();
        passes += 1;
        assert!(passes < 20);
    }
    assert_eq!(rig.svc.input.applied, 40);
    assert_eq!(rig.svc.input.seen, 40);
    assert_eq!(rig.screen.x, 960 + 400);
}

#[test]
fn held_buttons_and_keys_are_let_go_after_a_silence_and_on_request() {
    let mut rig = Rig::new();
    rig.send(events_dg(1, &[Event::ButtonDown(0), Event::KeyDown { usage: 0xE1, mods: 2 }, Event::KeyDown { usage: 0x0B, mods: 0 }]));
    rig.pass();
    rig.log();
    // heartbeats keep them held
    for i in 0..40u16 {
        rig.send(events_dg(2 + i, &[]));
        rig.pass();
    }
    assert!(rig.svc.input.holding());
    assert!(rig.log().is_empty());
    // ... silence for more than IDLE_RELEASE_MS lets go
    let mut released = Vec::new();
    for _ in 0..40 {
        rig.pass();
        released.extend(rig.log());
        if !rig.svc.input.holding() {
            break;
        }
    }
    assert_eq!(released.len(), 3);
    assert!(released.contains(&InputEvent::Button { button: 0, down: false }));
    assert!(rig.svc.tx_guard_active(rig.now));
    // and the same on request
    rig.send(events_dg(100, &[Event::ButtonDown(1), Event::ReleaseAll]));
    rig.pass();
    assert_eq!(rig.log(), [InputEvent::Button { button: 1, down: true }, InputEvent::Button { button: 1, down: false }]);
    assert!(!rig.svc.input.holding());
}

#[test]
fn the_transmit_guard_runs_out() {
    let mut rig = Rig::new();
    assert!(!rig.svc.tx_guard_active(rig.now));
    rig.send(events_dg(1, &[Event::MoveRel { dx: 1, dy: 1 }]));
    rig.pass();
    assert!(!rig.svc.tx_guard_active(rig.now), "a pointer move alone is not a click");
    rig.send(events_dg(2, &[Event::ButtonDown(0), Event::ButtonUp(0)]));
    rig.pass();
    assert!(rig.svc.tx_guard_active(rig.now));
    assert!(rig.svc.tx_guard_active(rig.now + TX_GUARD_MS - 1));
    // a long job keeps the screen's events waiting past the time: the guard holds until they were taken
    assert!(rig.svc.tx_guard_active(rig.now + 20_000));
    rig.svc.events_taken();
    assert!(rig.svc.tx_guard_active(rig.now + TX_GUARD_MS - 1));
    assert!(!rig.svc.tx_guard_active(rig.now + TX_GUARD_MS));
}

// ----- golden datagrams, shared with the PC tool's test -----

/// The datagrams the PC tool's test builds (`tools/test_radio_input.py`, `golden_datagrams`).
fn golden_script() -> Vec<(Vec<u8>, Vec<Event>)> {
    let s: Vec<(u8, u16, Vec<Event>)> = vec![
        (kind::HELLO, 0, vec![]),
        (kind::EVENTS, 1, vec![Event::MoveRel { dx: 5, dy: -3 }, Event::MoveRel { dx: -300, dy: 200 }, Event::Wheel(-1)]),
        (
            kind::EVENTS,
            2,
            vec![
                Event::MoveAbs { x: 1919, y: 1079 },
                Event::ButtonDown(0),
                Event::ButtonUp(0),
                Event::ButtonDown(1),
                Event::ButtonUp(1),
                Event::ButtonDown(2),
                Event::ButtonUp(2),
            ],
        ),
        (
            kind::EVENTS,
            3,
            vec![
                Event::KeyDown { usage: 0x04, mods: 0x02 },
                Event::KeyUp { usage: 0x04, mods: 0x02 },
                Event::KeyDown { usage: 0x28, mods: 0 },
                Event::KeyUp { usage: 0x28, mods: 0 },
                Event::KeyDown { usage: 0x17, mods: 0 },
            ],
        ),
        (kind::EVENTS, 4, vec![]),
        (kind::EVENTS, 30000, vec![Event::ReleaseAll, Event::MoveRel { dx: -32768, dy: 32767 }]),
    ];
    s.into_iter().map(|(k, q, e)| (dg(k, q, &e), e)).collect()
}

fn golden_path() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests").join("golden.bin")
}

/// Container: for each datagram a u16 big-endian length, then the bytes.
fn pack(list: &[(Vec<u8>, Vec<Event>)]) -> Vec<u8> {
    let mut out = Vec::new();
    for (d, _) in list {
        out.extend((d.len() as u16).to_be_bytes());
        out.extend(d);
    }
    out
}

#[test]
fn golden_datagrams_parse_to_the_expected_events() {
    let script = golden_script();
    if std::env::var_os("TR_INPUT_WRITE_GOLDEN").is_some() {
        std::fs::write(golden_path(), pack(&script)).unwrap();
    }
    let file = std::fs::read(golden_path()).expect("tests/golden.bin (TR_INPUT_WRITE_GOLDEN=1 writes it)");
    assert_eq!(file, pack(&script), "the file and the Rust builder differ");
    let mut at = 0;
    for (d, expected) in &script {
        let n = u16::from_be_bytes([file[at], file[at + 1]]) as usize;
        let bytes = &file[at + 2..at + 2 + n];
        assert_eq!(bytes, &d[..]);
        let p = parse(bytes).unwrap();
        assert_eq!(p.events().collect::<Vec<_>>(), *expected);
        at += 2 + n;
    }
    assert_eq!(at, file.len());
}

#[test]
fn golden_stream_applied_end_to_end() {
    let mut rig = Rig::new();
    for (d, _) in golden_script() {
        rig.send(d);
    }
    while {
        rig.pass();
        !rig.sock.inbox.is_empty()
    } {}
    // moved, wheel, corner, three clicks, keys (a, Enter; 't' dropped), release, a move to the left edge and the bottom
    assert_eq!(rig.svc.input.tx_blocked, 1);
    assert_eq!(rig.screen.keys, b"A\n");
    assert_eq!(rig.svc.input.applied, 5);
    assert_eq!(rig.svc.input.last_applied_seq, 30000);
    assert_eq!((rig.screen.x, rig.screen.y), (0, SCREEN_HEIGHT - 1));
}
