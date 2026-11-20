// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Mouse and keyboard of a PC over the home network into the radio's own screen (docs/NETINPUT.md).
//!
//! The PC program (`tools/radio_input.py`) sends UDP datagrams to [`UDP_PORT`]. The firmware parses them here
//! ([`parse`]), turns the events into the same [`InputEvent`]s the USB host's mouse and keyboard make, and hands them
//! to a [`Sink`] (the screen, plus the console key queue). Input only: nothing here can reach the radio's transmit
//! path. Keys that the console and the screen map to transmitting or answering are dropped ([`is_tx_key`]); the
//! firmware drops the screen's transmit events for a short time after any button or key from the network
//! ([`NetInputService::tx_guard_active`]).
//!
//! No allocation, no blocking. One [`NetInputService::poll`] per main-loop pass drains a bounded number of datagrams,
//! merges runs of pointer movement into one movement, and answers with a status datagram.
//!
//! Wire format (all numbers big-endian):
//!
//! ```text
//! datagram  = "TRIN" version(1) kind(1) sequence(u16) events...
//! kind      = 0 hello (no events), 1 events (0 to 64 events; none = heartbeat), 2 status (board to PC)
//! event     = 01 dx(i16) dy(i16)      pointer moves by (dx, dy), pixels
//!           | 02 x(u16)  y(u16)       pointer to (x, y), x < 1920, y < 1080
//!           | 03 button | 04 button   button down | up; 0 left, 1 right, 2 middle
//!           | 05 delta(i8)            wheel clicks, positive away from the user
//!           | 06 usage mods | 07 usage mods   key down | up: USB HID usage (keyboard page), modifier bits as in a USB boot report
//!           | 08                      release every button and key
//! status    = "TRIN" version(1) 2 sequence(u16 last applied) applied(u32 datagrams) x(u16) y(u16) blocked(u16 TX keys dropped)
//! ```

#![cfg_attr(not(test), no_std)]

use tr_usbh::hid::{self, InputEvent, Layout};

/// UDP port of the radio's input service (one place: the firmware, the PC tool and the doc follow this).
pub const UDP_PORT: u16 = 21600;
/// The four bytes that start every datagram.
pub const MAGIC: [u8; 4] = *b"TRIN";
/// The protocol version, the fifth byte of every datagram.
pub const VERSION: u8 = 1;
/// Length of the header (magic, version, kind and sequence number) in bytes.
pub const HEADER_LEN: usize = 8;
/// Datagrams longer than this are dropped unread.
pub const MAX_DATAGRAM: usize = 512;
/// Most events one datagram may carry.
pub const MAX_EVENTS_PER_DATAGRAM: usize = 64;
/// Per main-loop pass: at most this many datagrams, and stop taking more once this many events were applied.
pub const MAX_DATAGRAMS_PER_PASS: usize = 16;
/// See [`MAX_DATAGRAMS_PER_PASS`].
pub const MAX_EVENTS_PER_PASS: usize = 192;
/// Held buttons and keys are let go when nothing has come from the network for this long (the PC tool sends a heartbeat
/// every 250 ms while captured).
pub const IDLE_RELEASE_MS: u32 = 3_000;
/// A status reply to an events datagram goes out at most this often (a hello is always answered).
pub const REPLY_INTERVAL_MS: u32 = 200;
/// After a button or key from the network the screen's transmit events are dropped for this long.
pub const TX_GUARD_MS: u32 = 1_000;
/// Width of the screen in pixels; an absolute pointer position must be below it.
pub const SCREEN_WIDTH: i32 = 1_920;
/// Height of the screen in pixels; an absolute pointer position must be below it.
pub const SCREEN_HEIGHT: i32 = 1_080;
/// Length of a status datagram in bytes.
pub const STATUS_LEN: usize = 18;

/// Datagram kinds.
pub mod kind {
    /// See [`super::Kind::Hello`].
    pub const HELLO: u8 = 0;
    /// See [`super::Kind::Events`].
    pub const EVENTS: u8 = 1;
    /// See [`super::Kind::Status`].
    pub const STATUS: u8 = 2;
}

/// Event tags.
pub mod tag {
    /// See [`super::Event::MoveRel`].
    pub const MOVE_REL: u8 = 0x01;
    /// See [`super::Event::MoveAbs`].
    pub const MOVE_ABS: u8 = 0x02;
    /// See [`super::Event::ButtonDown`].
    pub const BUTTON_DOWN: u8 = 0x03;
    /// See [`super::Event::ButtonUp`].
    pub const BUTTON_UP: u8 = 0x04;
    /// See [`super::Event::Wheel`].
    pub const WHEEL: u8 = 0x05;
    /// See [`super::Event::KeyDown`].
    pub const KEY_DOWN: u8 = 0x06;
    /// See [`super::Event::KeyUp`].
    pub const KEY_UP: u8 = 0x07;
    /// See [`super::Event::ReleaseAll`].
    pub const RELEASE_ALL: u8 = 0x08;
}

/// One event of a datagram.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Event {
    /// The pointer moves by `dx`, `dy` pixels.
    MoveRel { dx: i16, dy: i16 },
    /// The pointer goes to `x`, `y` on the screen.
    MoveAbs { x: u16, y: u16 },
    /// A button goes down: 0 left, 1 right, 2 middle.
    ButtonDown(u8),
    /// A button comes up.
    ButtonUp(u8),
    /// Wheel clicks, positive away from the user.
    Wheel(i8),
    /// A key goes down: the USB HID usage (keyboard page) and the modifier bits of a USB boot report.
    KeyDown { usage: u8, mods: u8 },
    /// A key comes up.
    KeyUp { usage: u8, mods: u8 },
    /// Every button and key is let go.
    ReleaseAll,
}

/// Why a datagram was dropped.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reject {
    /// Shorter than the header.
    TooShort,
    /// Longer than [`MAX_DATAGRAM`].
    TooLong,
    /// The first four bytes are not [`MAGIC`].
    Magic,
    /// A version other than [`VERSION`].
    Version,
    /// A kind that does not exist.
    Kind,
    /// A hello or status datagram with events behind the header.
    Body,
    /// An event runs past the end of the datagram.
    Truncated,
    /// An event tag that does not exist.
    UnknownEvent(u8),
    /// More than [`MAX_EVENTS_PER_DATAGRAM`] events.
    TooManyEvents,
    /// A button other than 0 to 2, a position outside the screen.
    Value,
    /// Same or older sequence number than the last one applied.
    Stale,
}

/// What a datagram is for (see [`kind`] for the numbers on the wire).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// The PC tool announces itself; answered at once with a status datagram.
    Hello,
    /// Input events, or none as a heartbeat.
    Events,
    /// The board's own reply to the PC.
    Status,
}

/// A datagram that passed every check.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Packet<'a> {
    /// What the datagram is for.
    pub kind: Kind,
    /// Sequence number, counting up with each datagram of one PC tool (wraps at 65536).
    pub seq: u16,
    body: &'a [u8],
    count: usize,
}

impl<'a> Packet<'a> {
    /// Number of events in the datagram.
    pub fn count(&self) -> usize {
        self.count
    }

    /// The events in order.
    pub fn events(&self) -> Events<'a> {
        Events { rest: self.body }
    }
}

/// Iterator over the events of a checked [`Packet`].
pub struct Events<'a> {
    rest: &'a [u8],
}

fn event_len(tag: u8) -> Option<usize> {
    Some(match tag {
        tag::MOVE_REL | tag::MOVE_ABS => 5,
        tag::BUTTON_DOWN | tag::BUTTON_UP | tag::WHEEL => 2,
        tag::KEY_DOWN | tag::KEY_UP => 3,
        tag::RELEASE_ALL => 1,
        _ => return None,
    })
}

/// Decodes the event at the start of `b` (its length was checked).
fn decode(b: &[u8]) -> Event {
    let i16_at = |i: usize| i16::from_be_bytes([b[i], b[i + 1]]);
    let u16_at = |i: usize| u16::from_be_bytes([b[i], b[i + 1]]);
    match b[0] {
        tag::MOVE_REL => Event::MoveRel { dx: i16_at(1), dy: i16_at(3) },
        tag::MOVE_ABS => Event::MoveAbs { x: u16_at(1), y: u16_at(3) },
        tag::BUTTON_DOWN => Event::ButtonDown(b[1]),
        tag::BUTTON_UP => Event::ButtonUp(b[1]),
        tag::WHEEL => Event::Wheel(b[1] as i8),
        tag::KEY_DOWN => Event::KeyDown { usage: b[1], mods: b[2] },
        tag::KEY_UP => Event::KeyUp { usage: b[1], mods: b[2] },
        _ => Event::ReleaseAll,
    }
}

impl Iterator for Events<'_> {
    type Item = Event;
    fn next(&mut self) -> Option<Event> {
        let first = *self.rest.first()?;
        let n = event_len(first)?;
        let e = decode(self.rest.get(..n)?);
        self.rest = &self.rest[n..];
        Some(e)
    }
}

/// Checks a whole datagram. Anything malformed rejects all of it; nothing of a rejected datagram is applied.
pub fn parse(data: &[u8]) -> Result<Packet<'_>, Reject> {
    if data.len() > MAX_DATAGRAM {
        return Err(Reject::TooLong);
    }
    if data.len() < HEADER_LEN {
        return Err(Reject::TooShort);
    }
    if data[..4] != MAGIC {
        return Err(Reject::Magic);
    }
    if data[4] != VERSION {
        return Err(Reject::Version);
    }
    let kind = match data[5] {
        kind::HELLO => Kind::Hello,
        kind::EVENTS => Kind::Events,
        kind::STATUS => Kind::Status,
        _ => return Err(Reject::Kind),
    };
    let seq = u16::from_be_bytes([data[6], data[7]]);
    let body = &data[HEADER_LEN..];
    if kind != Kind::Events {
        // a status datagram is the board's own; as input it is as good as nothing
        return if body.is_empty() || kind == Kind::Status { Ok(Packet { kind, seq, body: &[], count: 0 }) } else { Err(Reject::Body) };
    }
    let mut at = 0;
    let mut count = 0;
    while at < body.len() {
        let n = event_len(body[at]).ok_or(Reject::UnknownEvent(body[at]))?;
        let e = body.get(at..at + n).ok_or(Reject::Truncated)?;
        count += 1;
        if count > MAX_EVENTS_PER_DATAGRAM {
            return Err(Reject::TooManyEvents);
        }
        match decode(e) {
            Event::ButtonDown(b) | Event::ButtonUp(b) if b > 2 => return Err(Reject::Value),
            Event::MoveAbs { x, y } if i32::from(x) >= SCREEN_WIDTH || i32::from(y) >= SCREEN_HEIGHT => return Err(Reject::Value),
            _ => {}
        }
        at += n;
    }
    Ok(Packet { kind, seq, body, count })
}

/// Builds datagrams (the PC tool does the same in Python; both are checked against `tests/golden.bin`).
pub struct Builder<'a> {
    buf: &'a mut [u8],
    len: usize,
}

impl<'a> Builder<'a> {
    /// Starts a datagram of `kind` (a number from [`kind`]) with sequence number `seq` in `buf`.
    pub fn new(buf: &'a mut [u8], kind: u8, seq: u16) -> Self {
        buf[..4].copy_from_slice(&MAGIC);
        buf[4] = VERSION;
        buf[5] = kind;
        buf[6..8].copy_from_slice(&seq.to_be_bytes());
        Builder { buf, len: HEADER_LEN }
    }

    /// Appends one event; the caller keeps to [`MAX_EVENTS_PER_DATAGRAM`] and to the room in `buf`.
    pub fn push(&mut self, e: Event) -> &mut Self {
        let mut put = |bytes: &[u8]| {
            self.buf[self.len..self.len + bytes.len()].copy_from_slice(bytes);
            self.len += bytes.len();
        };
        match e {
            Event::MoveRel { dx, dy } => {
                let (a, b) = (dx.to_be_bytes(), dy.to_be_bytes());
                put(&[tag::MOVE_REL, a[0], a[1], b[0], b[1]]);
            }
            Event::MoveAbs { x, y } => {
                let (a, b) = (x.to_be_bytes(), y.to_be_bytes());
                put(&[tag::MOVE_ABS, a[0], a[1], b[0], b[1]]);
            }
            Event::ButtonDown(b) => put(&[tag::BUTTON_DOWN, b]),
            Event::ButtonUp(b) => put(&[tag::BUTTON_UP, b]),
            Event::Wheel(d) => put(&[tag::WHEEL, d as u8]),
            Event::KeyDown { usage, mods } => put(&[tag::KEY_DOWN, usage, mods]),
            Event::KeyUp { usage, mods } => put(&[tag::KEY_UP, usage, mods]),
            Event::ReleaseAll => put(&[tag::RELEASE_ALL]),
        }
        self
    }

    /// The length of the finished datagram in bytes.
    pub fn finish(self) -> usize {
        self.len
    }
}

/// What the board tells the PC.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Status {
    /// Sequence number of the last datagram applied.
    pub seq: u16,
    /// Datagrams applied since start-up.
    pub applied: u32,
    /// Pointer position on the screen.
    pub x: u16,
    /// Pointer position on the screen.
    pub y: u16,
    /// Transmit-class keys dropped since start-up (saturating).
    pub blocked: u16,
}

impl Status {
    /// The status datagram as sent, big-endian as in the module documentation.
    pub fn encode(&self) -> [u8; STATUS_LEN] {
        let mut b = [0u8; STATUS_LEN];
        b[..4].copy_from_slice(&MAGIC);
        b[4] = VERSION;
        b[5] = kind::STATUS;
        b[6..8].copy_from_slice(&self.seq.to_be_bytes());
        b[8..12].copy_from_slice(&self.applied.to_be_bytes());
        b[12..14].copy_from_slice(&self.x.to_be_bytes());
        b[14..16].copy_from_slice(&self.y.to_be_bytes());
        b[16..18].copy_from_slice(&self.blocked.to_be_bytes());
        b
    }

    /// Reads a status datagram; `None` unless length, magic, version and kind all match.
    pub fn decode(b: &[u8]) -> Option<Status> {
        if b.len() != STATUS_LEN || b[..4] != MAGIC || b[4] != VERSION || b[5] != kind::STATUS {
            return None;
        }
        Some(Status {
            seq: u16::from_be_bytes([b[6], b[7]]),
            applied: u32::from_be_bytes([b[8], b[9], b[10], b[11]]),
            x: u16::from_be_bytes([b[12], b[13]]),
            y: u16::from_be_bytes([b[14], b[15]]),
            blocked: u16::from_be_bytes([b[16], b[17]]),
        })
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Transmit keys
// ---------------------------------------------------------------------------------------------------------------

/// The console characters (case ignored) that must never come from the network: what `tr_station::keys::event_for`
/// maps to transmit enable (`t`), CQ (`c`), the TX slot (`s`) and answering a decode line (`0` to `9`), the TX audio
/// frequency (`-` `+` `=`, FT8 screen), and `u` (starts the clock entry, whose digits are answer keys). A test in
/// tr-station checks that every key `event_for` maps to a transmit event is in this list. Allowed on purpose: `h`
/// (halt, stops transmitting), `m` (FreeDV screen, switches transmit off), band and tuning keys, `,` `.`.
pub const TX_KEY_CHARS: &[u8] = b"tcsu0123456789-+=";

/// A console character from [`TX_KEY_CHARS`].
pub fn is_tx_char(c: u8) -> bool {
    TX_KEY_CHARS.contains(&c.to_ascii_lowercase())
}

/// A key (HID usage) that gives a character of [`TX_KEY_CHARS`] on the US or the German layout, plain, shifted or with
/// AltGr. The number pad keys count, as does the key for `=` and `-`. Decided by the key, never by the modifiers the
/// PC claims, and for both layouts so that the firmware's layout setting does not matter.
pub fn is_tx_key(usage: u8) -> bool {
    for layout in [Layout::Us, Layout::De] {
        for mods in [0, hid::MOD_LSHIFT, hid::MOD_RALT] {
            if let Some(c) = hid::key_char(layout, usage, mods) {
                if c.is_ascii() && is_tx_char(c as u8) {
                    return true;
                }
            }
        }
    }
    false
}

// ---------------------------------------------------------------------------------------------------------------
// Console key codes: the one place a key (HID usage) becomes a console key
// ---------------------------------------------------------------------------------------------------------------

/// Console key codes for keys without an ASCII character. They are above 0x7F, so they never collide with a typed
/// character, and none of them is on the transmit block list.
pub mod code {
    pub const LEFT: u8 = 0x80;
    pub const RIGHT: u8 = 0x81;
    pub const UP: u8 = 0x82;
    pub const DOWN: u8 = 0x83;
    pub const PAGE_UP: u8 = 0x84;
    pub const PAGE_DOWN: u8 = 0x85;
    pub const HOME: u8 = 0x86;
    pub const END: u8 = 0x87;
    /// Up and down with Shift held.
    pub const SHIFT_UP: u8 = 0x88;
    pub const SHIFT_DOWN: u8 = 0x89;
}

/// The console key a key gives: its ASCII character, or a [`code`] for the arrow, page and Home/End keys, or
/// nothing. Used for the USB keyboard and for the network's keys (the key queue of the console handlers), so both
/// give the same codes. Transmit keys are decided before this, by usage ([`is_tx_key`]).
pub fn console_code(layout: Layout, usage: u8, mods: u8) -> Option<u8> {
    let shift = mods & hid::MOD_SHIFT != 0;
    let c = match usage {
        hid::key::LEFT => code::LEFT,
        hid::key::RIGHT => code::RIGHT,
        hid::key::UP if shift => code::SHIFT_UP,
        hid::key::DOWN if shift => code::SHIFT_DOWN,
        hid::key::UP => code::UP,
        hid::key::DOWN => code::DOWN,
        hid::key::PAGE_UP => code::PAGE_UP,
        hid::key::PAGE_DOWN => code::PAGE_DOWN,
        hid::key::HOME => code::HOME,
        hid::key::END => code::END,
        _ => {
            let c = hid::key_char(layout, usage, mods)?;
            return c.is_ascii().then_some(c as u8);
        }
    };
    Some(c)
}

/// The serial console's escape sequences for the same keys (a terminal sends `ESC [ A` for the up arrow, `ESC [ 5 ~`
/// for Page Up), turned into [`code`]s; every other byte passes unchanged. An escape sequence it does not know is
/// dropped whole, and so is a lone Escape (no console handler uses it).
#[derive(Clone, Copy, Debug, Default)]
pub struct AnsiKeys {
    /// 0 idle, 1 after ESC, 2 after ESC [ or ESC O, 3 after a parameter digit (`p` holds it)
    state: u8,
    p: u8,
}

impl AnsiKeys {
    /// A decoder waiting for the first byte.
    pub const fn new() -> Self {
        AnsiKeys { state: 0, p: 0 }
    }

    /// One byte from the terminal; the console key it completes, if any.
    pub fn feed(&mut self, b: u8) -> Option<u8> {
        match self.state {
            0 if b == 0x1B => {
                self.state = 1;
                None
            }
            0 => Some(b),
            1 if b == b'[' || b == b'O' => {
                self.state = 2;
                None
            }
            1 => {
                // a lone Escape, then an ordinary key
                self.state = 0;
                self.feed(b)
            }
            2 => {
                self.state = 0;
                match b {
                    b'A' => Some(code::UP),
                    b'B' => Some(code::DOWN),
                    b'C' => Some(code::RIGHT),
                    b'D' => Some(code::LEFT),
                    b'H' => Some(code::HOME),
                    b'F' => Some(code::END),
                    b'0'..=b'9' => {
                        self.p = b - b'0';
                        self.state = 3;
                        None
                    }
                    _ => None,
                }
            }
            3 => {
                if b.is_ascii_digit() {
                    self.p = self.p.saturating_mul(10).saturating_add(b - b'0');
                    return None;
                }
                self.state = 0;
                match (b, self.p) {
                    (b'~', 5) => Some(code::PAGE_UP),
                    (b'~', 6) => Some(code::PAGE_DOWN),
                    (b'~', 1 | 7) => Some(code::HOME),
                    (b'~', 4 | 8) => Some(code::END),
                    // ESC [ 1 ; 2 A: an arrow with a modifier (2 = Shift)
                    (b';', _) => {
                        self.state = 4;
                        self.p = 0;
                        None
                    }
                    _ => None,
                }
            }
            _ => {
                if b.is_ascii_digit() {
                    self.p = self.p.saturating_mul(10).saturating_add(b - b'0');
                    return None;
                }
                self.state = 0;
                let shift = self.p == 2;
                match b {
                    b'A' => Some(if shift { code::SHIFT_UP } else { code::UP }),
                    b'B' => Some(if shift { code::SHIFT_DOWN } else { code::DOWN }),
                    b'C' => Some(code::RIGHT),
                    b'D' => Some(code::LEFT),
                    _ => None,
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------
// Applying events
// ---------------------------------------------------------------------------------------------------------------

/// Where the events go: the screen, and the console key queue (the same keys as the console's).
pub trait Sink {
    /// Where the pointer is now.
    fn pointer(&self) -> (i32, i32);
    /// One event, as the USB host would give it.
    fn input(&mut self, e: InputEvent);
    /// A key with an ASCII character, as typed on the console.
    fn console_key(&mut self, c: u8);
}

/// What one datagram did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// A hello datagram, which is answered at once.
    Hello,
    /// `events` applied; `pressed`: it held a button or key event (the caller starts the transmit guard).
    Applied { events: usize, pressed: bool },
    /// A status datagram (ours coming back, or someone else's): ignored.
    Ignored,
    /// Dropped whole, for the reason given.
    Rejected(Reject),
}

const HELD_KEYS: usize = 8;

/// The state of the network input: the counters, what is held down, the sequence number.
#[derive(Clone, Debug)]
pub struct NetInput {
    layout: Layout,
    last_seq: Option<u16>,
    last_rx_ms: u32,
    buttons: u8,
    keys: [u8; HELD_KEYS],
    key_count: usize,
    /// Datagrams taken from the socket, before any check.
    pub seen: u32,
    /// Datagrams with events applied.
    pub applied: u32,
    /// Datagrams dropped because they were malformed.
    pub rejected: u32,
    /// Datagrams dropped because their sequence number was not newer than the last one applied.
    pub stale: u32,
    /// Events applied.
    pub events: u32,
    /// Transmit-class keys dropped.
    pub tx_blocked: u32,
    /// Sequence number of the last datagram applied.
    pub last_applied_seq: u16,
}

/// The pointer's position while a datagram is applied, and what has not been handed on yet.
struct Move {
    /// Pointer as the sink last reported it.
    base: (i32, i32),
    /// Where it will be after the pending movement.
    at: (i32, i32),
}

impl Move {
    fn new(sink: &impl Sink) -> Self {
        let p = sink.pointer();
        Move { base: p, at: p }
    }

    fn rel(&mut self, dx: i32, dy: i32) {
        self.at = ((self.at.0 + dx).clamp(0, SCREEN_WIDTH - 1), (self.at.1 + dy).clamp(0, SCREEN_HEIGHT - 1));
    }

    fn abs(&mut self, x: i32, y: i32) {
        self.at = (x.clamp(0, SCREEN_WIDTH - 1), y.clamp(0, SCREEN_HEIGHT - 1));
    }

    /// One movement for everything since the last flush.
    fn flush(&mut self, sink: &mut impl Sink) {
        let (dx, dy) = (self.at.0 - self.base.0, self.at.1 - self.base.1);
        if dx != 0 || dy != 0 {
            sink.input(InputEvent::PointerMove { dx: dx as i16, dy: dy as i16 });
        }
        self.base = sink.pointer();
        self.at = self.base;
    }
}

impl NetInput {
    /// A fresh state for a keyboard of `layout`.
    pub const fn new(layout: Layout) -> Self {
        NetInput {
            layout,
            last_seq: None,
            last_rx_ms: 0,
            buttons: 0,
            keys: [0; HELD_KEYS],
            key_count: 0,
            seen: 0,
            applied: 0,
            rejected: 0,
            stale: 0,
            events: 0,
            tx_blocked: 0,
            last_applied_seq: 0,
        }
    }

    /// One datagram. `budget` counts the events this pass may still apply; it goes down by what was applied.
    pub fn apply_datagram(&mut self, data: &[u8], now_ms: u32, sink: &mut impl Sink, budget: &mut usize) -> Outcome {
        let packet = match parse(data) {
            Ok(p) => p,
            Err(r) => {
                self.rejected = self.rejected.wrapping_add(1);
                return Outcome::Rejected(r);
            }
        };
        match packet.kind {
            Kind::Status => return Outcome::Ignored,
            Kind::Hello => {
                // a new PC tool starts a new sequence
                self.last_seq = None;
                self.last_rx_ms = now_ms;
                return Outcome::Hello;
            }
            Kind::Events => {}
        }
        // after a silence a datagram starts a new sequence (a PC tool that was restarted without a hello)
        let quiet = now_ms.wrapping_sub(self.last_rx_ms) > IDLE_RELEASE_MS;
        if let Some(last) = self.last_seq.filter(|_| !quiet) {
            let ahead = packet.seq.wrapping_sub(last);
            if ahead == 0 || ahead >= 0x8000 {
                self.stale = self.stale.wrapping_add(1);
                return Outcome::Rejected(Reject::Stale);
            }
        }
        self.last_seq = Some(packet.seq);
        self.last_applied_seq = packet.seq;
        self.last_rx_ms = now_ms;
        let mut mv = Move::new(sink);
        let mut pressed = false;
        let mut n = 0;
        for e in packet.events() {
            n += 1;
            match e {
                Event::MoveRel { dx, dy } => mv.rel(i32::from(dx), i32::from(dy)),
                Event::MoveAbs { x, y } => mv.abs(i32::from(x), i32::from(y)),
                Event::ButtonDown(b) => {
                    mv.flush(sink);
                    pressed = true;
                    self.buttons |= 1 << b;
                    sink.input(InputEvent::Button { button: b, down: true });
                }
                Event::ButtonUp(b) => {
                    mv.flush(sink);
                    pressed = true;
                    self.buttons &= !(1 << b);
                    sink.input(InputEvent::Button { button: b, down: false });
                }
                Event::Wheel(delta) => {
                    mv.flush(sink);
                    sink.input(InputEvent::Wheel { delta });
                }
                Event::KeyDown { usage, mods } => {
                    pressed = true;
                    self.key(usage, mods, true, sink);
                }
                Event::KeyUp { usage, mods } => {
                    pressed = true;
                    self.key(usage, mods, false, sink);
                }
                Event::ReleaseAll => {
                    mv.flush(sink);
                    self.release_all(sink);
                }
            }
        }
        mv.flush(sink);
        self.applied = self.applied.wrapping_add(1);
        self.events = self.events.wrapping_add(n as u32);
        *budget = budget.saturating_sub(n);
        Outcome::Applied { events: n, pressed }
    }

    fn key(&mut self, usage: u8, mods: u8, down: bool, sink: &mut impl Sink) {
        if is_tx_key(usage) {
            if down {
                self.tx_blocked = self.tx_blocked.wrapping_add(1);
            }
            return;
        }
        if down {
            if !self.keys[..self.key_count].contains(&usage) && self.key_count < HELD_KEYS {
                self.keys[self.key_count] = usage;
                self.key_count += 1;
            }
            sink.input(InputEvent::Key { usage, down: true, mods });
            if let Some(c) = console_code(self.layout, usage, mods) {
                sink.console_key(c);
            }
        } else {
            if let Some(i) = self.keys[..self.key_count].iter().position(|k| *k == usage) {
                self.keys.copy_within(i + 1..self.key_count, i);
                self.key_count -= 1;
            }
            sink.input(InputEvent::Key { usage, down: false, mods });
        }
    }

    /// Lets go of every button and key held.
    pub fn release_all(&mut self, sink: &mut impl Sink) {
        for b in 0..3u8 {
            if self.buttons & (1 << b) != 0 {
                sink.input(InputEvent::Button { button: b, down: false });
            }
        }
        self.buttons = 0;
        for i in 0..self.key_count {
            sink.input(InputEvent::Key { usage: self.keys[i], down: false, mods: 0 });
        }
        self.key_count = 0;
    }

    /// Anything held down.
    pub fn holding(&self) -> bool {
        self.buttons != 0 || self.key_count != 0
    }

    /// Call every pass: lets go of what is held once the network has been quiet for [`IDLE_RELEASE_MS`] (a lost
    /// "up" would otherwise leave a button down for good).
    pub fn tick(&mut self, now_ms: u32, sink: &mut impl Sink) -> bool {
        if self.holding() && now_ms.wrapping_sub(self.last_rx_ms) > IDLE_RELEASE_MS {
            self.release_all(sink);
            return true;
        }
        false
    }

    /// The counters and the pointer position as the status datagram reports them.
    pub fn status(&self, sink: &impl Sink) -> Status {
        let (x, y) = sink.pointer();
        Status {
            seq: self.last_applied_seq,
            applied: self.applied,
            x: x.clamp(0, SCREEN_WIDTH - 1) as u16,
            y: y.clamp(0, SCREEN_HEIGHT - 1) as u16,
            blocked: self.tx_blocked.min(u32::from(u16::MAX)) as u16,
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------
// The service: datagrams in, status out, once per main-loop pass
// ---------------------------------------------------------------------------------------------------------------

/// The datagram socket under the service: the UDP socket of `tr_net` on the board, a model in the tests.
/// The peer is an IPv4 address and a port.
pub trait Datagrams {
    /// The next datagram, copied into `buf` (cut if longer); returns its true length and the sender.
    fn recv(&mut self, buf: &mut [u8]) -> Option<(usize, ([u8; 4], u16))>;
    /// Queues a datagram; false if there was no room.
    fn send(&mut self, to: ([u8; 4], u16), data: &[u8]) -> bool;
}

/// What one pass did.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PassResult {
    /// Datagrams taken from the socket.
    pub datagrams: usize,
    /// Events applied.
    pub events: usize,
    /// A status datagram was queued.
    pub replied: bool,
}

/// The network input as the firmware runs it: [`NetInput`] plus the transmit guard and the reply to the PC.
pub struct NetInputService {
    /// The parser state and counters.
    pub input: NetInput,
    guard_until_ms: Option<u32>,
    /// A button or key from the network has been applied and the screen's events have not been taken since: the
    /// guard holds however long that takes (a long job in the main loop can keep the screen events waiting for seconds).
    guard_pending: bool,
    last_peer: Option<([u8; 4], u16)>,
    last_reply_ms: Option<u32>,
}

impl NetInputService {
    /// A fresh service for a keyboard of `layout`.
    pub const fn new(layout: Layout) -> Self {
        NetInputService { input: NetInput::new(layout), guard_until_ms: None, guard_pending: false, last_peer: None, last_reply_ms: None }
    }

    /// The pass's network input: call before the screen's events are collected. Takes at most
    /// [`MAX_DATAGRAMS_PER_PASS`] datagrams and about [`MAX_EVENTS_PER_PASS`] events (the rest waits in the socket),
    /// applies them to `sink`, releases held keys after a silence, and queues one status reply.
    pub fn poll(&mut self, io: &mut impl Datagrams, sink: &mut impl Sink, now_ms: u32) -> PassResult {
        let mut res = PassResult::default();
        let mut budget = MAX_EVENTS_PER_PASS;
        let mut buf = [0u8; MAX_DATAGRAM];
        let mut hello_from = None;
        let mut applied_from = None;
        for _ in 0..MAX_DATAGRAMS_PER_PASS {
            if budget == 0 {
                break;
            }
            let Some((n, peer)) = io.recv(&mut buf) else { break };
            res.datagrams += 1;
            self.input.seen = self.input.seen.wrapping_add(1);
            if n > MAX_DATAGRAM {
                self.input.rejected = self.input.rejected.wrapping_add(1);
                continue;
            }
            match self.input.apply_datagram(&buf[..n], now_ms, sink, &mut budget) {
                Outcome::Hello => hello_from = Some(peer),
                Outcome::Applied { events, pressed } => {
                    res.events += events;
                    applied_from = Some(peer);
                    if pressed {
                        self.guard_until_ms = Some(now_ms.wrapping_add(TX_GUARD_MS));
                        self.guard_pending = true;
                    }
                }
                Outcome::Ignored | Outcome::Rejected(_) => {}
            }
        }
        if self.input.tick(now_ms, sink) {
            self.guard_until_ms = Some(now_ms.wrapping_add(TX_GUARD_MS));
            self.guard_pending = true;
        }
        // a hello is answered at once, to its sender; applied events at most every REPLY_INTERVAL_MS, to the last sender
        let reply_to = if let Some(p) = hello_from {
            Some(p)
        } else if let Some(p) = applied_from {
            let due = self.last_reply_ms.map_or(true, |t| now_ms.wrapping_sub(t) >= REPLY_INTERVAL_MS);
            due.then_some(p)
        } else {
            None
        };
        if let Some(p) = reply_to {
            self.last_peer = Some(p);
            if io.send(p, &self.input.status(sink).encode()) {
                self.last_reply_ms = Some(now_ms);
                res.replied = true;
            }
        }
        res
    }

    /// While true the firmware drops the screen's transmit events (a click on the screen's own TX or CQ button, an
    /// answer click on a decode line): they would come from the network.
    pub fn tx_guard_active(&self, now_ms: u32) -> bool {
        self.guard_pending || self.guard_until_ms.is_some_and(|t| (t.wrapping_sub(now_ms) as i32) > 0)
    }

    /// Call after the screen's events were taken (and filtered with [`NetInputService::tx_guard_active`]): the
    /// guard then lasts only its [`TX_GUARD_MS`].
    pub fn events_taken(&mut self) {
        self.guard_pending = false;
    }

    /// The last PC that talked to the board.
    pub fn last_peer(&self) -> Option<([u8; 4], u16)> {
        self.last_peer
    }
}
