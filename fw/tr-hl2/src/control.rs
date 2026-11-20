// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! HL2 control policy and the typed control API over the message layer (`msg`). See
//! `docs/HL2_CONTROL.md`.
//!
//! [`check_request`] is the transmit lock. `msg::MsgClient::submit` runs it on every request, so
//! nothing that could key the HL2 or change how it transmits leaves this crate:
//! - command bus (CMD) writes only to register 0x00 (filter relays, RX antenna, sync clocks off,
//!   band volts on the fan pin) and register 0x0A (RX gain). Register 0x09 (PA enable, TX gain,
//!   T/R relay), 0x0E (TX-time LNA gain), 0x31 (real DAC), 0x3A (reboot), 0x3B (AD9866 registers)
//!   and 0x3C/0x3D (I2C through the command bus) are refused, like every other address;
//! - register writes (WRITE) only to the front-end block's LED and FAN registers;
//! - I2C writes to the bias pots and configuration EEPROM (bus 2, address 0x2C) are refused, and
//!   reads there only pass with an MCP4662 read command (register byte bits 3:2 = 11);
//! - I2C writes to the N2ADR Pico IO board (bus 2, address 0x1D) are refused;
//! - LIMITS only make the interlock stricter than the values last read back from the radio;
//! - the message layer has no request type for the transmit permission or the bias unlock.
//!
//! There is no unlocked mode.

use crate::bridge::{self, frontend, i2c_bus, status};
use crate::filter::{self, Band};
use crate::msg::{
    self, Completion, Event, I2cKind, I2cOutcome, I2cXfer, Limits, MsgClient, PingData, Request, Response, SubmitError, Tag,
    Telemetry,
};
use crate::protocol;

/// Why the policy refused a request.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// A command bus address outside the allow-list (0x00, 0x0A).
    Command { addr: u8 },
    /// An allowed command address with a value outside its allowed bits or range.
    CommandValue { addr: u8, value: u32 },
    /// A register write outside the allow-list (LED, FAN).
    RegisterWrite { addr: u32 },
    /// A write to the bias pots / EEPROM (bus 2, 0x2C), or a read there that is not an MCP4662 read
    /// command.
    BiasGuard,
    /// A write to the N2ADR Pico IO board (bus 2, 0x1D).
    IoBoard,
    /// An outgoing datagram that is not a well-formed message-layer datagram of this client.
    Datagram,
    /// I2C bus outside 1-3, or a bad scan range.
    I2cBus,
    /// A limit larger than the value last read back (or outside the documented range).
    LimitsLooser,
    /// Limits can only be tightened once they have been read back.
    LimitsUnknown,
    /// READ count outside 1-32, PING body too long, or another bad argument.
    BadArgument,
}

/// Front-end block registers that WRITE may change. Neither can affect transmit.
pub const WRITE_ALLOWED: [u32; 2] = [frontend::LED, frontend::FAN];

/// Largest TEMP_LIMIT code (55 degC); the gateware caps higher writes to it.
pub const TEMP_LIMIT_MAX: u16 = 0x527;
pub const LEASE_MS_MIN: u16 = 10;
pub const LEASE_MS_MAX: u16 = 1000;
pub const MAXKEY_S_MIN: u16 = 1;
pub const MAXKEY_S_MAX: u16 = 600;

/// Command bus addresses the policy allows.
pub const CMD_ALLOWED: [u8; 2] = [protocol::REG_ADDR_FRONTEND, protocol::REG_ADDR_RX_GAIN];

/// Register 0x0A values for -12 to +48 dB.
const RX_GAIN_CODES: core::ops::RangeInclusive<u32> =
    (0x40 + 12 + protocol::RX_GAIN_MIN_DB) as u32..=(0x40 + 12 + protocol::RX_GAIN_MAX_DB) as u32;

/// The transmit lock: true for every request this crate may send. `limits` is what the radio last
/// reported (`MsgClient::limits`).
pub fn check_request(req: &Request, limits: Option<Limits>) -> Result<(), Refusal> {
    match *req {
        Request::Hello | Request::Ping(_) | Request::SetTelemetry { .. } | Request::ClearTrips => Ok(()),
        Request::Read { count, .. } => {
            if (1..=msg::READ_MAX as u8).contains(&count) {
                Ok(())
            } else {
                Err(Refusal::BadArgument)
            }
        }
        Request::Write { addr, .. } => {
            if WRITE_ALLOWED.contains(&addr) {
                Ok(())
            } else {
                Err(Refusal::RegisterWrite { addr })
            }
        }
        Request::Cmd { addr, value } => check_command(addr, value),
        Request::I2cXfer(x) => check_i2c(&x),
        Request::I2cScan { bus, first, last } => {
            if (1..=3).contains(&bus) && first <= last && last <= 127 {
                Ok(())
            } else {
                Err(Refusal::I2cBus)
            }
        }
        Request::Limits(l) => check_limits(l, limits),
    }
}

/// Command bus allow-list: register 0x00 with known bits only, register 0x0A with an RX gain code.
pub fn check_command(addr: u8, value: u32) -> Result<(), Refusal> {
    let ok = match addr {
        protocol::REG_ADDR_FRONTEND => value & !filter::KNOWN_BITS == 0,
        protocol::REG_ADDR_RX_GAIN => RX_GAIN_CODES.contains(&value),
        _ => return Err(Refusal::Command { addr }),
    };
    if ok {
        Ok(())
    } else {
        Err(Refusal::CommandValue { addr, value })
    }
}

/// Bias pots and configuration EEPROM (MCP4662) on bus 2.
pub const BIAS_I2C_ADDR: u8 = 0x2C;

/// N2ADR Pico IO board on bus 2. Writes there are refused by policy: what its registers switch
/// is not part of this API.
pub const IO_BOARD_I2C_ADDR: u8 = 0x1D;

fn check_i2c(x: &I2cXfer) -> Result<(), Refusal> {
    if !(1..=3).contains(&x.bus) || x.addr > 0x7F {
        return Err(Refusal::I2cBus);
    }
    if x.bus == i2c_bus::FRONT_END && x.addr == IO_BOARD_I2C_ADDR && x.kind == I2cKind::Write {
        return Err(Refusal::IoBoard);
    }
    if x.bus == i2c_bus::FRONT_END && x.addr == BIAS_I2C_ADDR {
        match x.kind {
            I2cKind::Probe => {}
            // A read writes the register byte first: for the MCP4662 that byte is a command, and
            // only bits 3:2 = 11 make it a read (increment and decrement are one-byte commands).
            I2cKind::Read if x.reg & 0x0C == 0x0C => {}
            _ => return Err(Refusal::BiasGuard),
        }
    }
    Ok(())
}

fn check_limits(l: Limits, cur: Option<Limits>) -> Result<(), Refusal> {
    if l == Limits::READ_ONLY {
        return Ok(());
    }
    let cur = cur.ok_or(Refusal::LimitsUnknown)?;
    let fits = |v: u16, min: u16, cur: u16| v == 0 || (min..=cur).contains(&v);
    if fits(l.lease_ms, LEASE_MS_MIN, cur.lease_ms.min(LEASE_MS_MAX))
        && fits(l.maxkey_s, MAXKEY_S_MIN, cur.maxkey_s.min(MAXKEY_S_MAX))
        && fits(l.temp_code, 1, cur.temp_code.min(TEMP_LIMIT_MAX))
    {
        Ok(())
    } else {
        Err(Refusal::LimitsLooser)
    }
}

/// Checks a whole outgoing message-layer datagram: a valid header, and every message in it a
/// request this client can build that passes [`check_request`]. A datagram with no messages (an
/// acknowledgement) passes. For a transport that wants to check what leaves it independently of
/// `MsgClient` (the station's port 1027 whitelist).
pub fn check_datagram(d: &[u8], limits: Option<Limits>) -> Result<(), Refusal> {
    let (_, payload) = msg::Header::parse(d).ok_or(Refusal::Datagram)?;
    let mut used = 0;
    for m in msg::messages(payload) {
        let req = Request::decode(m.class, m.op, m.body).ok_or(Refusal::Datagram)?;
        check_request(&req, limits)?;
        used += msg::MSG_HDR_SIZE + m.body.len();
    }
    if used != payload.len() {
        return Err(Refusal::Datagram);
    }
    Ok(())
}

// ---- Decoding -----------------------------------------------------------------------------

/// Temperature in degC from the 12-bit slow ADC code (PROTOCOL.md 8.2).
pub fn temperature_c(code: u16) -> f32 {
    (3.26 * code as f32 / 4096.0 - 0.5) / 0.01
}

/// PA bias current in A from the slow ADC code (PROTOCOL.md 8.2).
pub fn bias_current_a(code: u16) -> f32 {
    (3.26 * code as f32 / 4096.0) / 50.0 / 0.04
}

/// RX gain in dB from the status block RX_GAIN register (bridge only), or `None` if no 0x0A
/// command has been seen since power-up.
pub fn rx_gain_db_from_status(v: u32) -> Option<i32> {
    if v & (1 << 8) == 0 {
        return None;
    }
    Some((v & 0x7F) as i32 - 0x40 - 12)
}

/// Cut-off and trip reason bits (ILK_STATUS 21:16 and 13:8, PROTOCOL.md 9.2).
pub mod cutoff {
    pub const NO_LEASE: u8 = 1 << 0;
    pub const OVER_TEMP: u8 = 1 << 1;
    pub const TX_INHIBIT: u8 = 1 << 2;
    pub const WATCHDOG: u8 = 1 << 3;
    pub const MAX_KEY_DOWN: u8 = 1 << 4;
    pub const TEMP_STALE: u8 = 1 << 5;
}

/// Decoded ILK_STATUS (PROTOCOL.md 9.3).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Interlock {
    pub tx_on: bool,
    pub pa_on: bool,
    pub lease_valid: bool,
    pub tx_requested: bool,
    pub trip_latched: bool,
    pub cutoff_present: bool,
    pub key_bit: bool,
    /// Latched trip reasons (`cutoff::*`; bit 0 = lease expired while keyed).
    pub trips: u8,
    /// Cut-offs now (`cutoff::*`).
    pub cutoffs: u8,
    pub pa_enable: bool,
    pub tr_disable: bool,
    pub vna: bool,
}

impl Interlock {
    pub fn decode(v: u32) -> Interlock {
        let b = |n: u32| v & (1 << n) != 0;
        Interlock {
            tx_on: b(0),
            pa_on: b(1),
            lease_valid: b(2),
            tx_requested: b(3),
            trip_latched: b(4),
            cutoff_present: b(5),
            key_bit: b(6),
            trips: ((v >> 8) & 0x3F) as u8,
            cutoffs: ((v >> 16) & 0x3F) as u8,
            pa_enable: b(24),
            tr_disable: b(25),
            vna: b(26),
        }
    }
}

/// Decoded front-end block INPUTS (PROTOCOL.md 8.3).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Inputs {
    /// Pin levels, bits 12:0 as the register has them (tip, ring, CN8, CN9, CN10, DB1-2, DB1-5,
    /// hl2link rx 2 bits, TP2 TP7 TP8 TP9).
    pub pins: u16,
    pub key: bool,
    pub ptt: bool,
    pub tx_inhibit: bool,
}

impl Inputs {
    pub fn decode(v: u32) -> Inputs {
        Inputs { pins: (v & 0x1FFF) as u16, key: v & (1 << 16) != 0, ptt: v & (1 << 17) != 0, tx_inhibit: v & (1 << 18) != 0 }
    }
}

/// Telemetry with the documented conversions.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TelemetryReading(pub Telemetry);

impl TelemetryReading {
    pub fn temperature_c(&self) -> f32 {
        temperature_c(self.0.temp_code)
    }
    /// Forward power code, uncalibrated.
    pub fn forward_code(&self) -> u16 {
        self.0.fwd_code
    }
    /// Reverse power code, uncalibrated.
    pub fn reverse_code(&self) -> u16 {
        self.0.rev_code
    }
    pub fn bias_current_a(&self) -> f32 {
        bias_current_a(self.0.bias_code)
    }
    pub fn interlock(&self) -> Interlock {
        Interlock::decode(self.0.ilk_status)
    }
    pub fn inputs(&self) -> Inputs {
        Inputs::decode(self.0.inputs)
    }
    /// Transmit-safety byte (`protocol::SAFETY_*`).
    pub fn safety(&self) -> u8 {
        self.0.safety
    }
    pub fn i2c_status(&self) -> bridge::I2cStatus {
        bridge::parse_i2c_status(self.0.i2c_status)
    }
}

// ---- Control API --------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ControlError {
    Refused(Refusal),
    QueueFull,
}

impl From<SubmitError> for ControlError {
    fn from(e: SubmitError) -> Self {
        match e {
            SubmitError::Refused(r) => ControlError::Refused(r),
            SubmitError::QueueFull => ControlError::QueueFull,
        }
    }
}

/// Register 0x00 bits of the N2ADR filter relays (bits 23:17).
pub const FILTER_FIELD: u32 = 0x7F << 17;

/// Bridge packet the readback of the RX gain uses (the CPU's status mirror has no RX gain register,
/// so the message layer cannot read it).
const BRIDGE_MAGIC: u8 = 0x4E;

/// Typed HL2 control over one message-layer session, plus the one Etherbone read the message
/// layer cannot do (RX gain readback). Transport-independent like `MsgClient`: feed every datagram
/// from port 1027 to `handle_datagram`, send everything `poll_transmit` returns to port 1027.
///
/// Every operation returns the request's tag at once; its result arrives as a `Completion` with
/// that tag from `poll_completion`. A refused operation returns an error and queues nothing.
pub struct Hl2Control {
    msg: MsgClient,
    /// Shadow of command register 0x00 (written as a full value each time). Seeded from the filter
    /// latch at session start (`new`); 0 until then, and if the latch cannot be read.
    reg0: u32,
    /// Tag of the filter latch read queued at session start, until it seeds `reg0`. Cleared when
    /// register 0x00 is written first.
    seed_tag: Option<Tag>,
    bridge_rx_gain_due: bool,
    rx_gain_readback: Option<Option<i32>>,
}

impl Hl2Control {
    /// Starts a session: HELLO is queued as the first request, then a read of the filter latch
    /// (`read_filter_latch`) whose answer seeds the register 0x00 shadow, so that the first filter
    /// or antenna call does not change the other relays. `seed`: see `MsgClient::new`.
    pub fn new(seed: u32) -> Hl2Control {
        let mut c = Hl2Control { msg: MsgClient::new(seed), reg0: 0, seed_tag: None, bridge_rx_gain_due: false, rx_gain_readback: None };
        let _ = c.msg.submit(Request::Hello);
        c.seed_tag = c.read_filter_latch().ok();
        c
    }

    /// True while the start-of-session latch read has not answered yet (and no register 0x00
    /// write was made before it did).
    pub fn frontend_seed_pending(&self) -> bool {
        self.seed_tag.is_some()
    }

    pub fn msg(&self) -> &MsgClient {
        &self.msg
    }
    pub fn msg_mut(&mut self) -> &mut MsgClient {
        &mut self.msg
    }

    pub fn handle_datagram(&mut self, now: u32, d: &[u8]) {
        if d.first() == Some(&BRIDGE_MAGIC) {
            let mut v = [0u32; 1];
            if bridge::parse_reply(d, &mut v) == Some(1) {
                self.rx_gain_readback = Some(rx_gain_db_from_status(v[0]));
            }
            return;
        }
        self.msg.handle_datagram(now, d);
    }

    pub fn poll_transmit(&mut self, now: u32, out: &mut [u8]) -> Option<usize> {
        if self.bridge_rx_gain_due {
            self.bridge_rx_gain_due = false;
            return bridge::build_read(&[status::RX_GAIN], out);
        }
        self.msg.poll_transmit(now, out)
    }

    /// The next result. The start-of-session latch read also arrives here (its tag was never
    /// handed out); on success it has already seeded the register 0x00 shadow.
    pub fn poll_completion(&mut self) -> Option<Completion> {
        let c = self.msg.poll_completion()?;
        if Some(c.tag) == self.seed_tag {
            self.seed_tag = None;
            if let Ok(Response::I2cXfer { outcome: I2cOutcome::Ok, data }) = c.result {
                // bits 11 (band volts on the fan pin) and 12 (sync clocks off) are not in the latch: stock value 0
                self.reg0 = filter::reg0_from_olat(data as u8);
            }
        }
        Some(c)
    }
    pub fn poll_event(&mut self) -> Option<Event> {
        self.msg.poll_event()
    }
    pub fn telemetry(&self) -> Option<TelemetryReading> {
        self.msg.telemetry().copied().map(TelemetryReading)
    }

    fn submit(&mut self, r: Request) -> Result<Tag, ControlError> {
        Ok(self.msg.submit(r)?)
    }

    pub fn hello(&mut self) -> Result<Tag, ControlError> {
        self.submit(Request::Hello)
    }
    pub fn ping(&mut self, data: &[u8]) -> Result<Tag, ControlError> {
        let p = PingData::new(data).ok_or(ControlError::Refused(Refusal::BadArgument))?;
        self.submit(Request::Ping(p))
    }
    /// Telemetry period in ms, 0 = off (firmware default 100 ms after every start).
    pub fn set_telemetry_period(&mut self, ms: u16) -> Result<Tag, ControlError> {
        self.submit(Request::SetTelemetry { period_ms: ms })
    }

    /// RX gain (AD9866 PGA), -12 to +48 dB. Outside that range: refused, nothing sent.
    pub fn set_rx_gain_db(&mut self, db: i32) -> Result<Tag, ControlError> {
        if !(protocol::RX_GAIN_MIN_DB..=protocol::RX_GAIN_MAX_DB).contains(&db) {
            return Err(ControlError::Refused(Refusal::BadArgument));
        }
        let (value, _) = protocol::rx_gain_value(db);
        self.submit(Request::Cmd { addr: protocol::REG_ADDR_RX_GAIN, value })
    }

    /// Asks for the RX gain register over the bridge; the answer shows in `rx_gain_readback`.
    pub fn request_rx_gain_readback(&mut self) {
        self.rx_gain_readback = None;
        self.bridge_rx_gain_due = true;
    }
    /// `None`: no answer yet. `Some(None)`: the HL2 has seen no RX gain command since power-up.
    pub fn rx_gain_readback(&self) -> Option<Option<i32>> {
        self.rx_gain_readback
    }

    /// Filter relays for a receive band (Quisk's table, `filter::band_filter_bits`).
    pub fn set_band_filter(&mut self, band: Band) -> Result<Tag, ControlError> {
        self.set_filter_bits(filter::band_filter_bits(band))
    }

    /// Filter relays as register 0x00 bits 23:17 (`filter::BIT_*`). Other bits: refused.
    pub fn set_filter_bits(&mut self, bits: u32) -> Result<Tag, ControlError> {
        if bits & !FILTER_FIELD != 0 {
            return Err(ControlError::Refused(Refusal::BadArgument));
        }
        self.write_reg0((self.reg0 & !FILTER_FIELD) | bits)
    }

    /// RX antenna input (register 0x00 bit 13, MCP23008 GP7).
    pub fn set_rx_antenna(&mut self, on: bool) -> Result<Tag, ControlError> {
        let v = if on { self.reg0 | filter::BIT_RX_ANTENNA } else { self.reg0 & !filter::BIT_RX_ANTENNA };
        self.write_reg0(v)
    }

    fn write_reg0(&mut self, v: u32) -> Result<Tag, ControlError> {
        let t = self.submit(Request::Cmd { addr: protocol::REG_ADDR_FRONTEND, value: v })?;
        self.reg0 = v;
        self.seed_tag = None;
        Ok(t)
    }

    /// The register 0x00 value last sent.
    pub fn frontend_reg(&self) -> u32 {
        self.reg0
    }

    /// Reads the MCP23008 output latch (what the filter relays were told); the data's low byte
    /// should equal `filter::expected_olat(frontend_reg())`.
    pub fn read_filter_latch(&mut self) -> Result<Tag, ControlError> {
        self.i2c_read(filter::MCP23008_I2C_BUS, filter::MCP23008_I2C_ADDR, filter::MCP23008_OLAT_REG)
    }

    pub fn i2c_read(&mut self, bus: u8, addr: u8, reg: u8) -> Result<Tag, ControlError> {
        self.submit(Request::I2cXfer(I2cXfer { bus, addr, kind: I2cKind::Read, reg, value: 0 }))
    }
    pub fn i2c_write(&mut self, bus: u8, addr: u8, reg: u8, value: u8) -> Result<Tag, ControlError> {
        self.submit(Request::I2cXfer(I2cXfer { bus, addr, kind: I2cKind::Write, reg, value }))
    }
    pub fn i2c_probe(&mut self, bus: u8, addr: u8) -> Result<Tag, ControlError> {
        self.submit(Request::I2cXfer(I2cXfer { bus, addr, kind: I2cKind::Probe, reg: 0, value: 0 }))
    }
    pub fn i2c_scan(&mut self, bus: u8, first: u8, last: u8) -> Result<Tag, ControlError> {
        self.submit(Request::I2cScan { bus, first, last })
    }

    /// Reads 1-32 consecutive registers (CPU view: the status mirror, system, packet, flash and
    /// front-end blocks; unmapped addresses read 0xFFFF_FFFF).
    pub fn read_register(&mut self, addr: u32, count: u8) -> Result<Tag, ControlError> {
        self.submit(Request::Read { addr, count })
    }
    /// Writes one register from `WRITE_ALLOWED`.
    pub fn write_register(&mut self, addr: u32, value: u32) -> Result<Tag, ControlError> {
        self.submit(Request::Write { addr, value })
    }

    /// Clears latched trips whose cause is gone.
    pub fn clear_trips(&mut self) -> Result<Tag, ControlError> {
        self.submit(Request::ClearTrips)
    }

    pub fn read_limits(&mut self) -> Result<Tag, ControlError> {
        self.submit(Request::Limits(Limits::READ_ONLY))
    }
    /// Tightens limits (0 = keep). Each value must be at most the one last read back.
    pub fn set_limits(&mut self, l: Limits) -> Result<Tag, ControlError> {
        self.submit(Request::Limits(l))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_allow_list() {
        assert!(check_command(0x00, filter::band_filter_bits(Band::B80m) | filter::BIT_RX_ANTENNA).is_ok());
        assert!(check_command(0x00, 1 << 24).is_err());
        assert!(check_command(0x0A, 0x40 + 12 + 20).is_ok());
        assert!(check_command(0x0A, 0x7D).is_err());
        for a in [0x09u8, 0x0E, 0x31, 0x3A, 0x3B, 0x3C, 0x3D, 0x30, 0x01] {
            assert_eq!(check_command(a, 0), Err(Refusal::Command { addr: a }));
        }
    }

    #[test]
    fn bias_guard() {
        let x = |kind, reg| I2cXfer { bus: 2, addr: 0x2C, kind, reg, value: 0 };
        assert_eq!(check_i2c(&x(I2cKind::Write, 0)), Err(Refusal::BiasGuard));
        assert_eq!(check_i2c(&x(I2cKind::Read, 0x04)), Err(Refusal::BiasGuard));
        assert!(check_i2c(&x(I2cKind::Read, 0x0C)).is_ok());
        assert!(check_i2c(&x(I2cKind::Probe, 0)).is_ok());
    }

    #[test]
    fn io_board_writes_refused() {
        let x = |kind| I2cXfer { bus: 2, addr: IO_BOARD_I2C_ADDR, kind, reg: 0, value: 1 };
        assert_eq!(check_i2c(&x(I2cKind::Write)), Err(Refusal::IoBoard));
        assert!(check_i2c(&x(I2cKind::Read)).is_ok());
        assert!(check_i2c(&x(I2cKind::Probe)).is_ok());
        // the same address on another bus is another device
        assert!(check_i2c(&I2cXfer { bus: 1, ..x(I2cKind::Write) }).is_ok());
    }

    #[test]
    fn datagram_check() {
        let mut d = [0u8; msg::MAX_DATAGRAM];
        let mut put = |reqs: &[Request]| {
            let mut n = msg::HDR_SIZE;
            for (i, r) in reqs.iter().enumerate() {
                let mut b = [0u8; msg::REQ_BODY_MAX];
                let bl = r.encode_body(&mut b);
                let (c, o) = r.class_op();
                n += msg::put_message(&mut d[n..], c, o, i as u16, &b[..bl]).unwrap();
            }
            msg::Header { flags: msg::F_RELIABLE, len: (n - msg::HDR_SIZE) as u16, ..Default::default() }.write(&mut d);
            d[..n].to_vec()
        };
        let good = put(&[Request::Hello, Request::SetTelemetry { period_ms: 500 }, Request::Cmd { addr: 0x0A, value: 0x40 + 12 + 20 }]);
        assert_eq!(check_datagram(&good, None), Ok(()));
        let bad = put(&[Request::Hello, Request::Cmd { addr: 0x09, value: 1 }]);
        assert_eq!(check_datagram(&bad, None), Err(Refusal::Command { addr: 0x09 }));
        let io = put(&[Request::I2cXfer(I2cXfer { bus: 2, addr: 0x1D, kind: I2cKind::Write, reg: 0, value: 0 })]);
        assert_eq!(check_datagram(&io, None), Err(Refusal::IoBoard));
        // transmit permission (class 3 opcode 1): not a request of this client
        let mut tx = put(&[Request::ClearTrips]);
        tx[msg::HDR_SIZE + 1] = 1;
        assert_eq!(check_datagram(&tx, None), Err(Refusal::Datagram));
        assert_eq!(check_datagram(&[0x4E, 0x6F, 0x10, 0x44], None), Err(Refusal::Datagram));
        let ack = put(&[]);
        assert_eq!(check_datagram(&ack, None), Ok(()));
    }

    #[test]
    fn conversions() {
        // 25 degC: code = (0.25 + 0.5) / 3.26 * 4096 = 942.3
        assert!((temperature_c(942) - 24.97).abs() < 0.05);
        assert!((temperature_c(TEMP_LIMIT_MAX) - 55.0).abs() < 0.1);
        assert!((bias_current_a(1000) - 0.398).abs() < 0.001);
        assert_eq!(rx_gain_db_from_status(0x100 | (0x40 + 12 + 20)), Some(20));
        assert_eq!(rx_gain_db_from_status(0x40), None);
    }
}
