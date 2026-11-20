// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The HL2 message layer on UDP port 1027, client side. The radio side is the firmware
//! `firmware/hl2neo/msg/msg.c` and `main.c` of the Hermes-Lite2 repository (branch
//! `hl2-rawfront-release`, firmware version 0x0003_0001); `docs/rawfront/PROTOCOL.md` section 10
//! describes it. Where the two differ, this module follows the firmware source.
//!
//! Wire format (little-endian): a 16-byte header ("HM", version 1, flags, boot ID, sequence, ack,
//! payload length, 0) and a payload of at most 240 bytes holding one or more messages of class
//! (u8), opcode (u8), tag (u16), length (u16) and body. A response has opcode | 0x80, the request's
//! tag, and a body that starts with a status byte.
//!
//! [`MsgClient`] is a transport-independent state machine. The caller feeds it every datagram
//! received from port 1027 with `handle_datagram`, calls `poll_transmit` until it returns `None`
//! (often, at least every few milliseconds) and sends what it returns to port 1027, and collects
//! results with `poll_completion`, `poll_event` and `telemetry`. It needs no allocation.
//!
//! Reliability, as the firmware implements it:
//! - The firmware caches the response to one reliable request only. A second request sent before
//!   the first one's response arrived could cost that response for good, so the client keeps one
//!   reliable datagram in flight and packs several queued requests into it instead.
//! - The first datagram of a session carries the reset flag. So does the next datagram after a
//!   timeout, after the firmware answered out of step, and after a new boot ID (firmware restart).
//! - A repeat of the request in flight returns the cached response without executing anything.
//! - Events come reliably with their own sequence number and are acknowledged with the ack field.
//! - Telemetry comes unreliably, every 100 ms by default, once a session exists.
//!
//! Every request goes through `control::check_request` in `submit`: requests that could change
//! transmit behavior are refused before anything is queued or sent. The transmit permission and
//! the bias unlock have no request type here at all.

use crate::control::{check_request, Refusal};

pub const VERSION: u8 = 1;
pub const HDR_SIZE: usize = 16;
pub const MAX_PAYLOAD: usize = 240;
/// Largest datagram either way (the HL2 CPU transmit buffer is 256 bytes).
pub const MAX_DATAGRAM: usize = HDR_SIZE + MAX_PAYLOAD;
/// Class, opcode, tag and length in front of every message body.
pub const MSG_HDR_SIZE: usize = 6;

pub const F_RELIABLE: u8 = 0x01;
pub const F_ACK_VALID: u8 = 0x02;
pub const F_RESET: u8 = 0x04;

/// Opcode bit of a response.
pub const RESPONSE: u8 = 0x80;

pub mod class {
    pub const SYS: u8 = 0;
    pub const REG: u8 = 1;
    pub const I2C: u8 = 2;
    pub const RF: u8 = 3;
    pub const TELEMETRY: u8 = 5;
    pub const EVENT: u8 = 6;
}

/// Opcodes this client uses. Class 3 opcode 1 (transmit permission) and opcode 3 (bias unlock)
/// are left out on purpose.
pub mod op {
    pub const HELLO: u8 = 1;
    pub const PING: u8 = 2;
    pub const TELEMETRY: u8 = 3;
    pub const READ: u8 = 1;
    pub const WRITE: u8 = 2;
    pub const I2C_XFER: u8 = 1;
    pub const I2C_SCAN: u8 = 2;
    pub const CLEAR_TRIPS: u8 = 2;
    pub const CMD: u8 = 4;
    pub const LIMITS: u8 = 5;
    /// Class 5 (telemetry) and class 6 (event) messages from the radio.
    pub const DATA: u8 = 1;
}

/// Response status codes (first body byte).
pub mod status {
    pub const OK: u8 = 0;
    pub const UNKNOWN: u8 = 0x10;
    pub const LENGTH: u8 = 0x11;
    pub const REFUSED: u8 = 0x12;
    pub const BUSY: u8 = 0x13;
}

pub fn get16(p: &[u8]) -> u16 {
    u16::from_le_bytes([p[0], p[1]])
}
pub fn get32(p: &[u8]) -> u32 {
    u32::from_le_bytes([p[0], p[1], p[2], p[3]])
}
pub fn put16(p: &mut [u8], v: u16) {
    p[..2].copy_from_slice(&v.to_le_bytes());
}
pub fn put32(p: &mut [u8], v: u32) {
    p[..4].copy_from_slice(&v.to_le_bytes());
}

/// Time `a` is at or after time `b` on a wrapping millisecond clock (as msg.c compares).
pub fn time_reached(now: u32, due: u32) -> bool {
    now.wrapping_sub(due) < 0x8000_0000
}

// ---- Header and message framing ----------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Header {
    pub flags: u8,
    pub boot_id: u32,
    pub seq: u16,
    pub ack: u16,
    pub len: u16,
}

impl Header {
    /// Parses a datagram with the checks msg.c makes on input. Returns the header and the payload.
    pub fn parse(d: &[u8]) -> Option<(Header, &[u8])> {
        if d.len() < HDR_SIZE || d[0] != b'H' || d[1] != b'M' || d[2] != VERSION {
            return None;
        }
        let len = get16(&d[12..]) as usize;
        if HDR_SIZE + len > d.len() || len > MAX_PAYLOAD {
            return None;
        }
        let h = Header { flags: d[3], boot_id: get32(&d[4..]), seq: get16(&d[8..]), ack: get16(&d[10..]), len: len as u16 };
        Some((h, &d[HDR_SIZE..HDR_SIZE + len]))
    }

    /// Writes the 16 header bytes to `out[..16]`.
    pub fn write(&self, out: &mut [u8]) {
        out[0] = b'H';
        out[1] = b'M';
        out[2] = VERSION;
        out[3] = self.flags;
        put32(&mut out[4..], self.boot_id);
        put16(&mut out[8..], self.seq);
        put16(&mut out[10..], self.ack);
        put16(&mut out[12..], self.len);
        put16(&mut out[14..], 0);
    }
}

/// One message inside a payload.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MsgRef<'a> {
    pub class: u8,
    pub op: u8,
    pub tag: u16,
    pub body: &'a [u8],
}

/// Iterator over the messages of a payload. Stops at the first message that does not fit, as
/// msg.c's `execute` does.
pub struct Messages<'a> {
    d: &'a [u8],
    i: usize,
}

pub fn messages(payload: &[u8]) -> Messages<'_> {
    Messages { d: payload, i: 0 }
}

impl<'a> Iterator for Messages<'a> {
    type Item = MsgRef<'a>;
    fn next(&mut self) -> Option<MsgRef<'a>> {
        let (d, i) = (self.d, self.i);
        if i + MSG_HDR_SIZE > d.len() {
            return None;
        }
        let mlen = get16(&d[i + 4..]) as usize;
        if i + MSG_HDR_SIZE + mlen > d.len() {
            self.i = d.len();
            return None;
        }
        self.i = i + MSG_HDR_SIZE + mlen;
        Some(MsgRef { class: d[i], op: d[i + 1], tag: get16(&d[i + 2..]), body: &d[i + MSG_HDR_SIZE..i + MSG_HDR_SIZE + mlen] })
    }
}

/// Writes one message (header and body) at the start of `out`. Returns its length, or `None` if
/// it does not fit.
pub fn put_message(out: &mut [u8], class: u8, op: u8, tag: u16, body: &[u8]) -> Option<usize> {
    let n = MSG_HDR_SIZE + body.len();
    if n > out.len() || body.len() > u16::MAX as usize {
        return None;
    }
    out[0] = class;
    out[1] = op;
    put16(&mut out[2..], tag);
    put16(&mut out[4..], body.len() as u16);
    out[MSG_HDR_SIZE..n].copy_from_slice(body);
    Some(n)
}

// ---- Requests ---------------------------------------------------------------------------

/// Longest PING body this client sends.
pub const PING_MAX: usize = 32;
/// Longest request body (PING).
pub const REQ_BODY_MAX: usize = PING_MAX;
/// Most registers one READ returns (main.c: count 1-32).
pub const READ_MAX: usize = 32;

/// Fixed-size byte string for PING bodies.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PingData {
    len: u8,
    data: [u8; PING_MAX],
}

impl PingData {
    pub fn new(d: &[u8]) -> Option<PingData> {
        if d.len() > PING_MAX {
            return None;
        }
        let mut data = [0u8; PING_MAX];
        data[..d.len()].copy_from_slice(d);
        Some(PingData { len: d.len() as u8, data })
    }
    pub fn as_slice(&self) -> &[u8] {
        &self.data[..self.len as usize]
    }
}

/// I2C transfer kind (request flags: 0 write, 1 read, 2 probe).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum I2cKind {
    /// Register byte, then value byte.
    Write,
    /// Register pointer written, then 4 bytes read (first byte in data bits 7:0).
    Read,
    /// Address only, one byte read (in data bits 31:24).
    Probe,
}

impl I2cKind {
    pub fn flags(self) -> u8 {
        match self {
            I2cKind::Write => 0,
            I2cKind::Read => 1,
            I2cKind::Probe => 2,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct I2cXfer {
    pub bus: u8,
    pub addr: u8,
    pub kind: I2cKind,
    pub reg: u8,
    pub value: u8,
}

/// The three interlock limits (front-end block LEASE_MS, MAXKEY_S, TEMP_LIMIT). In a LIMITS
/// request 0 means "keep"; a request with all three 0 only reads them back.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Limits {
    pub lease_ms: u16,
    pub maxkey_s: u16,
    pub temp_code: u16,
}

impl Limits {
    pub const READ_ONLY: Limits = Limits { lease_ms: 0, maxkey_s: 0, temp_code: 0 };
}

/// Every request this client can send.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Request {
    Hello,
    Ping(PingData),
    /// Telemetry period in ms, 0 = off.
    SetTelemetry { period_ms: u16 },
    Read { addr: u32, count: u8 },
    /// One word. The control policy allows only a few addresses.
    Write { addr: u32, value: u32 },
    I2cXfer(I2cXfer),
    I2cScan { bus: u8, first: u8, last: u8 },
    ClearTrips,
    /// Command bus write (the same as a port-1025 register write). Checked by the control policy.
    Cmd { addr: u8, value: u32 },
    Limits(Limits),
}

impl Request {
    pub fn class_op(&self) -> (u8, u8) {
        match self {
            Request::Hello => (class::SYS, op::HELLO),
            Request::Ping(_) => (class::SYS, op::PING),
            Request::SetTelemetry { .. } => (class::SYS, op::TELEMETRY),
            Request::Read { .. } => (class::REG, op::READ),
            Request::Write { .. } => (class::REG, op::WRITE),
            Request::I2cXfer(_) => (class::I2C, op::I2C_XFER),
            Request::I2cScan { .. } => (class::I2C, op::I2C_SCAN),
            Request::ClearTrips => (class::RF, op::CLEAR_TRIPS),
            Request::Cmd { .. } => (class::RF, op::CMD),
            Request::Limits(_) => (class::RF, op::LIMITS),
        }
    }

    /// Encodes the request body. Returns its length.
    pub fn encode_body(&self, out: &mut [u8; REQ_BODY_MAX]) -> usize {
        match *self {
            Request::Hello | Request::ClearTrips => 0,
            Request::Ping(p) => {
                out[..p.as_slice().len()].copy_from_slice(p.as_slice());
                p.as_slice().len()
            }
            Request::SetTelemetry { period_ms } => {
                put16(out, period_ms);
                2
            }
            Request::Read { addr, count } => {
                put32(out, addr);
                out[4] = count;
                5
            }
            Request::Write { addr, value } => {
                put32(out, addr);
                put32(&mut out[4..], value);
                8
            }
            Request::I2cXfer(x) => {
                out[..5].copy_from_slice(&[x.bus, x.addr, x.kind.flags(), x.reg, x.value]);
                5
            }
            Request::I2cScan { bus, first, last } => {
                out[..3].copy_from_slice(&[bus, first, last]);
                3
            }
            Request::Cmd { addr, value } => {
                out[0] = addr;
                put32(&mut out[1..], value);
                5
            }
            Request::Limits(l) => {
                put16(out, l.lease_ms);
                put16(&mut out[2..], l.maxkey_s);
                put16(&mut out[4..], l.temp_code);
                6
            }
        }
    }

    /// The request a message with `class`, `op` and `body` carries: the inverse of `class_op` and
    /// `encode_body`. `None` for anything this client never sends, or a body of the wrong length.
    /// Used to check outgoing datagrams against the policy (`control::check_datagram`).
    pub fn decode(class: u8, op: u8, b: &[u8]) -> Option<Request> {
        let len = |n: usize| if b.len() == n { Some(()) } else { None };
        Some(match (class, op) {
            (class::SYS, op::HELLO) => len(0).map(|_| Request::Hello)?,
            (class::SYS, op::PING) => Request::Ping(PingData::new(b)?),
            (class::SYS, op::TELEMETRY) => len(2).map(|_| Request::SetTelemetry { period_ms: get16(b) })?,
            (class::REG, op::READ) => len(5).map(|_| Request::Read { addr: get32(b), count: b[4] })?,
            (class::REG, op::WRITE) => len(8).map(|_| Request::Write { addr: get32(b), value: get32(&b[4..]) })?,
            (class::I2C, op::I2C_XFER) => {
                len(5)?;
                let kind = match b[2] {
                    0 => I2cKind::Write,
                    1 => I2cKind::Read,
                    2 => I2cKind::Probe,
                    _ => return None,
                };
                Request::I2cXfer(I2cXfer { bus: b[0], addr: b[1], kind, reg: b[3], value: b[4] })
            }
            (class::I2C, op::I2C_SCAN) => len(3).map(|_| Request::I2cScan { bus: b[0], first: b[1], last: b[2] })?,
            (class::RF, op::CLEAR_TRIPS) => len(0).map(|_| Request::ClearTrips)?,
            (class::RF, op::CMD) => len(5).map(|_| Request::Cmd { addr: b[0], value: get32(&b[1..]) })?,
            (class::RF, op::LIMITS) => {
                len(6)?;
                Request::Limits(Limits { lease_ms: get16(b), maxkey_s: get16(&b[2..]), temp_code: get16(&b[4..]) })
            }
            _ => return None,
        })
    }

    /// Longest response body the firmware returns for this request, status byte included.
    pub fn response_len(&self) -> usize {
        match *self {
            Request::Hello => 24,
            Request::Ping(p) => 1 + p.as_slice().len(),
            Request::SetTelemetry { .. } | Request::Cmd { .. } => 1,
            Request::Read { count, .. } => 1 + 4 * count as usize,
            Request::Write { .. } => 2,
            Request::I2cXfer(_) => 6,
            Request::I2cScan { .. } => 17,
            Request::ClearTrips => 5,
            Request::Limits(_) => 7,
        }
    }
}

// ---- Responses --------------------------------------------------------------------------

/// Non-zero response status.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    Unknown,
    Length,
    Refused,
    Busy,
    Other(u8),
}

impl Status {
    pub fn from_code(c: u8) -> Status {
        match c {
            status::UNKNOWN => Status::Unknown,
            status::LENGTH => Status::Length,
            status::REFUSED => Status::Refused,
            status::BUSY => Status::Busy,
            c => Status::Other(c),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MsgError {
    /// The radio answered with a non-zero status.
    Status(Status),
    /// The response body was shorter than its type needs.
    Malformed,
    /// The response datagram came back without a message for this request (the firmware stops
    /// executing a datagram when the responses no longer fit).
    NoResponse,
    /// No response within the request timeout.
    Timeout,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HelloInfo {
    pub protocol: u8,
    pub gateware_version: u32,
    pub firmware_version: u32,
    pub capabilities: u32,
    pub max_payload: u16,
    pub telemetry_period_ms: u16,
    /// Front-end register block ID (0x494F_3031 "IO01").
    pub io_id: u32,
}

/// I2C transfer result code of an I2C XFER response.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum I2cOutcome {
    Ok,
    Nack,
    /// Refused by the gateware's bias guard (bus 2, address 0x2C).
    RefusedBiasGuard,
    /// Dropped because the engine was busy (retry).
    Dropped,
    Timeout,
    Other(u8),
}

impl I2cOutcome {
    pub fn from_code(c: u8) -> I2cOutcome {
        match c {
            0 => I2cOutcome::Ok,
            1 => I2cOutcome::Nack,
            2 => I2cOutcome::RefusedBiasGuard,
            3 => I2cOutcome::Dropped,
            4 => I2cOutcome::Timeout,
            c => I2cOutcome::Other(c),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ReadValues {
    pub count: u8,
    pub values: [u32; READ_MAX],
}

impl ReadValues {
    pub fn as_slice(&self) -> &[u32] {
        &self.values[..self.count as usize]
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Response {
    Hello(HelloInfo),
    Ping(PingData),
    TelemetrySet,
    Read(ReadValues),
    Write { words: u8 },
    I2cXfer { outcome: I2cOutcome, data: u32 },
    /// Bitmap of acknowledging addresses: address a is bit a % 8 of byte a / 8.
    I2cScan([u8; 16]),
    ClearTrips { ilk_status: u32 },
    Cmd,
    Limits(Limits),
}

/// Parses the response body (status byte first) to `req`.
pub fn parse_response(req: &Request, body: &[u8]) -> Result<Response, MsgError> {
    let s = *body.first().ok_or(MsgError::Malformed)?;
    if s != status::OK {
        return Err(MsgError::Status(Status::from_code(s)));
    }
    let b = &body[1..];
    let need = req.response_len() - 1;
    // PING echoes up to the request length; everything else has a fixed length.
    if !matches!(req, Request::Ping(_)) && b.len() < need {
        return Err(MsgError::Malformed);
    }
    Ok(match *req {
        Request::Hello => Response::Hello(HelloInfo {
            protocol: b[0],
            gateware_version: get32(&b[3..]),
            firmware_version: get32(&b[7..]),
            capabilities: get32(&b[11..]),
            max_payload: get16(&b[15..]),
            telemetry_period_ms: get16(&b[17..]),
            io_id: get32(&b[19..]),
        }),
        Request::Ping(_) => Response::Ping(PingData::new(b).ok_or(MsgError::Malformed)?),
        Request::SetTelemetry { .. } => Response::TelemetrySet,
        Request::Read { count, .. } => {
            let mut values = [0u32; READ_MAX];
            for (i, v) in values.iter_mut().enumerate().take(count as usize) {
                *v = get32(&b[4 * i..]);
            }
            Response::Read(ReadValues { count, values })
        }
        Request::Write { .. } => Response::Write { words: b[0] },
        Request::I2cXfer(_) => Response::I2cXfer { outcome: I2cOutcome::from_code(b[0]), data: get32(&b[1..]) },
        Request::I2cScan { .. } => {
            let mut m = [0u8; 16];
            m.copy_from_slice(&b[..16]);
            Response::I2cScan(m)
        }
        Request::ClearTrips => Response::ClearTrips { ilk_status: get32(b) },
        Request::Cmd { .. } => Response::Cmd,
        Request::Limits(_) => Response::Limits(Limits { lease_ms: get16(b), maxkey_s: get16(&b[2..]), temp_code: get16(&b[4..]) }),
    })
}

// ---- Radio to client: telemetry and events ----------------------------------------------

/// Telemetry message (class 5 / 1). main.c's `app_telemetry` body, after the u32 counter that
/// msg.c puts in front of it (the counter is not in PROTOCOL.md's table).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Telemetry {
    /// Telemetry packets sent since the firmware started.
    pub count: u32,
    /// Radio milliseconds since power-up.
    pub ms: u32,
    pub temp_code: u16,
    pub fwd_code: u16,
    pub rev_code: u16,
    pub bias_code: u16,
    /// Front-end block INPUTS.
    pub inputs: u32,
    pub ilk_status: u32,
    pub i2c_status: u32,
    pub fan: u32,
    pub keytime: u32,
    /// Transmit-safety byte (`protocol::SAFETY_*`).
    pub safety: u8,
    /// Datagrams the CPU receive ring dropped (mod 65,536).
    pub ring_drops: u16,
    /// Datagrams the CPU sent (mod 256).
    pub sent: u8,
}

pub const TELEMETRY_BODY_LEN: usize = 40;

impl Telemetry {
    pub fn parse(b: &[u8]) -> Option<Telemetry> {
        if b.len() < TELEMETRY_BODY_LEN {
            return None;
        }
        let last = get32(&b[36..]);
        Some(Telemetry {
            count: get32(b),
            ms: get32(&b[4..]),
            temp_code: get16(&b[8..]),
            fwd_code: get16(&b[10..]),
            rev_code: get16(&b[12..]),
            bias_code: get16(&b[14..]),
            inputs: get32(&b[16..]),
            ilk_status: get32(&b[20..]),
            i2c_status: get32(&b[24..]),
            fan: get32(&b[28..]),
            keytime: get32(&b[32..]),
            safety: last as u8,
            ring_drops: (last >> 8) as u16,
            sent: (last >> 24) as u8,
        })
    }
}

/// Event message (class 6 / 1): sent when the transmit state, a trip reason, a cut-off other than
/// the lease, or a debounced input changes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Event {
    pub ilk_status: u32,
    pub inputs: u32,
    pub ms: u32,
}

impl Event {
    pub fn parse(b: &[u8]) -> Option<Event> {
        if b.len() < 12 {
            return None;
        }
        Some(Event { ilk_status: get32(b), inputs: get32(&b[4..]), ms: get32(&b[8..]) })
    }
}

// ---- Fixed-capacity queue ---------------------------------------------------------------

pub(crate) struct Ring<T, const N: usize> {
    buf: [Option<T>; N],
    head: usize,
    len: usize,
}

impl<T, const N: usize> Ring<T, N> {
    pub(crate) fn new() -> Self {
        Ring { buf: core::array::from_fn(|_| None), head: 0, len: 0 }
    }
    pub(crate) fn len(&self) -> usize {
        self.len
    }
    pub(crate) fn push(&mut self, v: T) -> Result<(), T> {
        if self.len == N {
            return Err(v);
        }
        self.buf[(self.head + self.len) % N] = Some(v);
        self.len += 1;
        Ok(())
    }
    /// Pushes, dropping the oldest entry when full.
    pub(crate) fn push_overwrite(&mut self, v: T) {
        if self.len == N {
            self.pop();
        }
        let _ = self.push(v);
    }
    pub(crate) fn pop(&mut self) -> Option<T> {
        if self.len == 0 {
            return None;
        }
        let v = self.buf[self.head].take();
        self.head = (self.head + 1) % N;
        self.len -= 1;
        v
    }
    pub(crate) fn peek(&self) -> Option<&T> {
        if self.len == 0 {
            None
        } else {
            self.buf[self.head].as_ref()
        }
    }
}

// ---- Client state machine ---------------------------------------------------------------

pub type Tag = u16;

/// Requests waiting to be sent.
pub const QUEUE_LEN: usize = 8;
const DONE_LEN: usize = 16;
const EVENT_LEN: usize = 8;

/// First retransmission after this many ms, then doubling up to `RTO_MAX_MS`.
pub const RTO_FIRST_MS: u32 = 100;
pub const RTO_MAX_MS: u32 = 800;
/// Default time after which a request in flight fails with `MsgError::Timeout`.
pub const DEFAULT_TIMEOUT_MS: u32 = 3000;

/// The result of one submitted request.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Completion {
    pub tag: Tag,
    pub request: Request,
    pub result: Result<Response, MsgError>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SubmitError {
    /// Refused by the control policy; nothing was queued.
    Refused(Refusal),
    /// The queue is full; try again after `poll_transmit`.
    QueueFull,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Stats {
    pub datagrams_sent: u32,
    pub retransmits: u32,
    pub datagrams_received: u32,
    pub malformed: u32,
    pub timeouts: u32,
    pub events: u32,
    pub telemetry: u32,
}

#[derive(Clone, Copy)]
struct Slot {
    tag: Tag,
    req: Request,
}

struct InFlight {
    seq: u16,
    reset: bool,
    payload: [u8; MAX_PAYLOAD],
    len: usize,
    slots: [Option<Slot>; QUEUE_LEN],
    first_sent: u32,
    due: u32,
    rto: u32,
    sends: u32,
}

/// Client side of the message layer. See the module text.
pub struct MsgClient {
    boot_id: Option<u32>,
    next_seq: u16,
    reset_next: bool,
    next_tag: Tag,
    queue: Ring<Slot, QUEUE_LEN>,
    inflight: Option<InFlight>,
    last_event_seq: Option<u16>,
    ack_owed: bool,
    done: Ring<Completion, DONE_LEN>,
    events: Ring<Event, EVENT_LEN>,
    telemetry: Option<Telemetry>,
    limits: Option<Limits>,
    restarts: u32,
    timeout_ms: u32,
    stats: Stats,
}

impl MsgClient {
    /// `seed` picks the first sequence number and tag. Use something that differs between runs
    /// (a clock): a new client that happened to start at the firmware's current sequence number
    /// would get the previous session's cached response (the client detects that by its tags).
    pub fn new(seed: u32) -> MsgClient {
        MsgClient {
            boot_id: None,
            next_seq: (seed as u16) | 1,
            reset_next: true,
            next_tag: ((seed >> 16) as u16) | 1,
            queue: Ring::new(),
            inflight: None,
            last_event_seq: None,
            ack_owed: false,
            done: Ring::new(),
            events: Ring::new(),
            telemetry: None,
            limits: None,
            restarts: 0,
            timeout_ms: DEFAULT_TIMEOUT_MS,
            stats: Stats::default(),
        }
    }

    pub fn set_timeout_ms(&mut self, ms: u32) {
        self.timeout_ms = ms;
    }

    /// Queues a request after the control policy check. Returns its tag; the result arrives as a
    /// `Completion` with that tag.
    pub fn submit(&mut self, req: Request) -> Result<Tag, SubmitError> {
        check_request(&req, self.limits).map_err(SubmitError::Refused)?;
        let tag = self.next_tag;
        self.queue.push(Slot { tag, req }).map_err(|_| SubmitError::QueueFull)?;
        self.next_tag = self.next_tag.wrapping_add(1);
        if self.next_tag == 0 {
            self.next_tag = 1; // tag 0 is what telemetry and events carry
        }
        Ok(tag)
    }

    /// Feeds one datagram received from the radio's port 1027. Datagrams that are not messages
    /// (bridge replies, console) are ignored.
    pub fn handle_datagram(&mut self, now: u32, d: &[u8]) {
        let Some((h, payload)) = Header::parse(d) else {
            if d.first() == Some(&b'H') {
                self.stats.malformed += 1;
            }
            return;
        };
        self.stats.datagrams_received += 1;

        match self.boot_id {
            Some(b) if b != h.boot_id => {
                // The firmware restarted: its session, sequence and cached response are gone.
                self.boot_id = Some(h.boot_id);
                self.restarts += 1;
                self.last_event_seq = None;
                self.ack_owed = false;
                self.reset_next = true;
                if let Some(f) = self.inflight.as_mut() {
                    f.reset = true;
                    f.due = now;
                }
            }
            None => self.boot_id = Some(h.boot_id),
            _ => {}
        }

        if h.flags & F_RELIABLE != 0 {
            // An event (the only reliable packet the radio sends). Always acknowledge, deliver once.
            if self.last_event_seq != Some(h.seq) {
                for m in messages(payload) {
                    if m.class == class::EVENT && m.op == op::DATA {
                        if let Some(e) = Event::parse(m.body) {
                            self.events.push_overwrite(e);
                            self.stats.events += 1;
                        }
                    }
                }
            }
            self.last_event_seq = Some(h.seq);
            self.ack_owed = true;
            return;
        }

        let mut is_response = false;
        for m in messages(payload) {
            if m.class == class::TELEMETRY && m.op == op::DATA {
                if let Some(t) = Telemetry::parse(m.body) {
                    self.telemetry = Some(t);
                    self.stats.telemetry += 1;
                }
            } else if m.op & RESPONSE != 0 {
                is_response = true;
            }
        }

        let Some(f) = self.inflight.as_mut() else { return };
        if h.flags & F_ACK_VALID == 0 {
            return;
        }
        if !is_response {
            if payload.is_empty() && h.ack != f.seq && h.ack != f.seq.wrapping_sub(1) {
                // A bare ack: the firmware is out of step with us. Start over with the reset flag.
                f.reset = true;
                f.due = now;
            }
            return;
        }
        if h.ack != f.seq {
            return; // a late copy of an earlier response
        }

        let mut results: [Option<Result<Response, MsgError>>; QUEUE_LEN] = [None; QUEUE_LEN];
        let mut matched = 0;
        for m in messages(payload) {
            if m.op & RESPONSE == 0 {
                continue;
            }
            for (i, s) in f.slots.iter().enumerate() {
                let Some(s) = s else { continue };
                let (c, o) = s.req.class_op();
                if results[i].is_none() && s.tag == m.tag && c == m.class && (o | RESPONSE) == m.op {
                    results[i] = Some(parse_response(&s.req, m.body));
                    matched += 1;
                    break;
                }
            }
        }
        if matched == 0 {
            // A cached response from someone else's session that had the same sequence number.
            f.seq = self.next_seq;
            self.next_seq = self.next_seq.wrapping_add(1);
            f.reset = true;
            f.due = now;
            return;
        }
        let f = self.inflight.take().unwrap();
        self.reset_next = false;
        for (i, s) in f.slots.iter().enumerate() {
            let Some(s) = s else { continue };
            let result = results[i].unwrap_or(Err(MsgError::NoResponse));
            if let Ok(Response::Limits(l)) = result {
                self.limits = Some(l);
            }
            self.done.push_overwrite(Completion { tag: s.tag, request: s.req, result });
        }
    }

    /// Writes the next datagram to send into `out` (at least `MAX_DATAGRAM` bytes) and returns its
    /// length, or `None` when nothing is due. Call until it returns `None`.
    pub fn poll_transmit(&mut self, now: u32, out: &mut [u8]) -> Option<usize> {
        if let Some(f) = &self.inflight {
            if now.wrapping_sub(f.first_sent) >= self.timeout_ms {
                let f = self.inflight.take().unwrap();
                self.stats.timeouts += 1;
                self.reset_next = true;
                for s in f.slots.iter().flatten() {
                    self.done.push_overwrite(Completion { tag: s.tag, request: s.req, result: Err(MsgError::Timeout) });
                }
            }
        }
        if self.inflight.is_none() && self.queue.len() > 0 {
            self.start_datagram(now);
        }
        if let Some(f) = self.inflight.as_mut() {
            if time_reached(now, f.due) {
                if f.sends > 0 {
                    self.stats.retransmits += 1;
                }
                f.sends += 1;
                let mut flags = F_RELIABLE;
                if f.reset {
                    flags |= F_RESET;
                }
                if self.last_event_seq.is_some() {
                    flags |= F_ACK_VALID;
                }
                let h = Header {
                    flags,
                    boot_id: self.boot_id.unwrap_or(0),
                    seq: f.seq,
                    ack: self.last_event_seq.unwrap_or(0),
                    len: f.len as u16,
                };
                h.write(out);
                out[HDR_SIZE..HDR_SIZE + f.len].copy_from_slice(&f.payload[..f.len]);
                f.due = now.wrapping_add(f.rto);
                f.rto = (f.rto * 2).min(RTO_MAX_MS);
                self.ack_owed = false;
                self.stats.datagrams_sent += 1;
                return Some(HDR_SIZE + f.len);
            }
        }
        if self.ack_owed {
            self.ack_owed = false;
            let h = Header {
                flags: F_ACK_VALID,
                boot_id: self.boot_id.unwrap_or(0),
                seq: 0,
                ack: self.last_event_seq.unwrap_or(0),
                len: 0,
            };
            h.write(out);
            self.stats.datagrams_sent += 1;
            return Some(HDR_SIZE);
        }
        None
    }

    /// Packs queued requests into one datagram so that both the requests and their responses fit
    /// in 240 bytes.
    fn start_datagram(&mut self, now: u32) {
        let mut f = InFlight {
            seq: self.next_seq,
            reset: self.reset_next,
            payload: [0; MAX_PAYLOAD],
            len: 0,
            slots: [None; QUEUE_LEN],
            first_sent: now,
            due: now,
            rto: RTO_FIRST_MS,
            sends: 0,
        };
        self.next_seq = self.next_seq.wrapping_add(1);
        let (mut resp, mut n) = (0usize, 0usize);
        while let Some(s) = self.queue.peek() {
            let mut body = [0u8; REQ_BODY_MAX];
            let bl = s.req.encode_body(&mut body);
            let rneed = MSG_HDR_SIZE + s.req.response_len();
            if n > 0 && (f.len + MSG_HDR_SIZE + bl > MAX_PAYLOAD || resp + rneed > MAX_PAYLOAD) {
                break;
            }
            let (c, o) = s.req.class_op();
            let Some(w) = put_message(&mut f.payload[f.len..], c, o, s.tag, &body[..bl]) else { break };
            f.len += w;
            resp += rneed;
            f.slots[n] = self.queue.pop();
            n += 1;
        }
        self.inflight = Some(f);
    }

    pub fn poll_completion(&mut self) -> Option<Completion> {
        self.done.pop()
    }

    pub fn poll_event(&mut self) -> Option<Event> {
        self.events.pop()
    }

    /// The latest telemetry received.
    pub fn telemetry(&self) -> Option<&Telemetry> {
        self.telemetry.as_ref()
    }

    /// The limits last read back from the radio (any LIMITS response).
    pub fn limits(&self) -> Option<Limits> {
        self.limits
    }

    pub fn boot_id(&self) -> Option<u32> {
        self.boot_id
    }

    /// Firmware restarts seen (boot ID changes).
    pub fn restarts(&self) -> u32 {
        self.restarts
    }

    /// Nothing queued and nothing in flight.
    pub fn is_idle(&self) -> bool {
        self.inflight.is_none() && self.queue.len() == 0
    }

    pub fn stats(&self) -> Stats {
        self.stats
    }
}
