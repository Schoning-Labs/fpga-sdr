// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Register and memory bridge (an Etherbone subset) on port 1027, specified in
//! `docs/rawfront/PROTOCOL.md` section 8 (Hermes-Lite2 repository, branch `hl2-rawfront-release`).
//! It works with the CPU running, halted or crashed, with the radio stopped or streaming, and it
//! needs no firmware.
//!
//! The module is `no_std`: packets are built and parsed in buffers that the caller supplies, and
//! nothing is allocated. The transport (sending and receiving over UDP, polling for the end of an
//! I2C transfer) lives in `client`, which needs the `std` feature.
//!
//! Safety: `TX_PERMIT` (front-end block offset 0x04) is the one register that can key the
//! transmitter. This module deliberately has no function that builds a write to it (see the doc
//! comment of `FrontEnd::TX_PERMIT`), and `build_write_read` also refuses (`None`) any write whose
//! address range overlaps it, as a second check that does not depend on that omission.

/// Etherbone magic (bytes 0-1).
const MAGIC: [u8; 2] = [0x4E, 0x6F];
/// Byte 2: version 1, not a probe.
const HDR_BYTE2: u8 = 0x10;
/// Byte 3: 32-bit addresses and data.
const HDR_BYTE3: u8 = 0x44;
/// Byte 9: byte enable, all 4 bytes of every 32-bit word.
const BYTE_ENABLE: u8 = 0x0F;

/// Longest packet either direction (PROTOCOL.md 8.1: "longer than 512 bytes ... dropped").
pub const MAX_PACKET: usize = 512;
/// Largest write or read count in one record (PROTOCOL.md 8.1).
pub const MAX_COUNT: usize = 64;

const HEADER_LEN: usize = 12;

// ---- Status block, 0x4000_0000 (PROTOCOL.md 8.2) ------------------------------------------
pub mod status {
    pub const BASE: u32 = 0x4000_0000;
    pub const ID: u32 = BASE; // reads 0x484C_3242 ("HL2B")
    pub const VERSION: u32 = BASE + 0x0004;
    pub const SCRATCH: u32 = BASE + 0x0008;
    pub const CAPABILITIES: u32 = BASE + 0x000C;
    pub const BRIDGE_REQUESTS: u32 = BASE + 0x0010;
    pub const BRIDGE_DROPPED: u32 = BASE + 0x0014;
    pub const BRIDGE_ERRORS: u32 = BASE + 0x0018;
    pub const RX_GAIN: u32 = BASE + 0x2000;
    pub const TEMPERATURE: u32 = BASE + 0x3000;
    pub const FWD_POWER: u32 = BASE + 0x3004;
    pub const REV_POWER: u32 = BASE + 0x3008;
    pub const PA_BIAS: u32 = BASE + 0x300C;
    pub const INPUTS: u32 = BASE + 0x4000;
    /// Transmit-safety byte (same value as raw-frame header byte 3), bits [7:0].
    pub const SAFETY_BYTE: u32 = BASE + 0x7000;

    pub const ID_EXPECTED: u32 = 0x484C_3242;
}

// ---- Front-end register block, 0x4004_0000 (PROTOCOL.md 8.3) ------------------------------
pub mod frontend {
    pub const BASE: u32 = 0x4004_0000;
    pub const ID: u32 = BASE; // reads 0x494F_3031 ("IO01")
    /// **Never written by `tr-hl2`.** Renews the transmit lease and requests a key. No function
    /// in this crate builds a write here; `bridge::build_write_read` also refuses it.
    pub const TX_PERMIT: u32 = BASE + 0x04;
    pub const ILK_STATUS: u32 = BASE + 0x08;
    pub const ILK_CLEAR: u32 = BASE + 0x0C;
    pub const LEASE_MS: u32 = BASE + 0x10;
    pub const MAXKEY_S: u32 = BASE + 0x14;
    pub const TEMP_LIMIT: u32 = BASE + 0x18;
    pub const KEYTIME: u32 = BASE + 0x1C;
    pub const WDOG: u32 = BASE + 0x20;
    pub const WDOG_MS: u32 = BASE + 0x24;
    pub const WDOG_DISARM: u32 = BASE + 0x28;
    pub const CMD_DATA: u32 = BASE + 0x2C;
    pub const CMD_ADDR: u32 = BASE + 0x30;
    pub const I2C_XFER: u32 = BASE + 0x34;
    pub const I2C_STATUS: u32 = BASE + 0x38;
    pub const I2C_RDATA: u32 = BASE + 0x3C;
    pub const BIAS_UNLOCK: u32 = BASE + 0x40;
    pub const LED: u32 = BASE + 0x44;
    pub const FAN: u32 = BASE + 0x48;
    pub const INPUTS: u32 = BASE + 0x4C;
    pub const ADC_SEQ: u32 = BASE + 0x50;

    pub const ID_EXPECTED: u32 = 0x494F_3031;
    pub const ILK_CLEAR_KEY: u32 = 0x434C_5452;
}

/// True if the inclusive word range `[addr, addr + 4*(count.max(1)-1)]` touches `TX_PERMIT`.
/// Guards every write path in this module, independent of the fact that nothing here builds a
/// TX_PERMIT write value in the first place.
fn touches_tx_permit(addr: u32, count: usize) -> bool {
    if count == 0 {
        return false;
    }
    let last = addr.wrapping_add(4 * (count as u32 - 1));
    // addr..=last, stepping by 4 (registers are word-aligned); TX_PERMIT is a single word so a
    // direct containment check is enough (no wraparound expected at these addresses).
    addr <= frontend::TX_PERMIT && frontend::TX_PERMIT <= last
}

/// Build an Etherbone write+read-back request into `out`. Writes `values` starting at
/// `write_addr` (word addresses, i.e. `write_addr`, `write_addr+4`, ...), then reads the
/// `read_addrs` (arbitrary addresses, PROTOCOL.md 8.1: "writes are done before reads"). Either
/// half may be empty. Returns the packet length, or `None` if the request doesn't fit `out`,
/// exceeds `MAX_COUNT` writes/reads, or would write `TX_PERMIT`.
pub fn build_write_read(write_addr: u32, values: &[u32], read_addrs: &[u32], out: &mut [u8]) -> Option<usize> {
    if values.len() > MAX_COUNT || read_addrs.len() > MAX_COUNT {
        return None;
    }
    if touches_tx_permit(write_addr, values.len()) {
        return None;
    }
    let len = HEADER_LEN + if values.is_empty() { 0 } else { 4 + values.len() * 4 }
        + if read_addrs.is_empty() { 0 } else { 4 + read_addrs.len() * 4 };
    if len > out.len() || len > MAX_PACKET {
        return None;
    }
    out[0] = MAGIC[0];
    out[1] = MAGIC[1];
    out[2] = HDR_BYTE2;
    out[3] = HDR_BYTE3;
    out[4..8].copy_from_slice(&[0, 0, 0, 0]);
    out[8] = 0; // record flags, ignored
    out[9] = BYTE_ENABLE;
    out[10] = values.len() as u8;
    out[11] = read_addrs.len() as u8;
    let mut p = HEADER_LEN;
    if !values.is_empty() {
        out[p..p + 4].copy_from_slice(&write_addr.to_be_bytes());
        p += 4;
        for v in values {
            out[p..p + 4].copy_from_slice(&v.to_be_bytes());
            p += 4;
        }
    }
    if !read_addrs.is_empty() {
        // Base return address: unused by tr-hl2 (values come back in read_addrs order); 0 is a
        // valid placeholder.
        out[p..p + 4].copy_from_slice(&0u32.to_be_bytes());
        p += 4;
        for a in read_addrs {
            out[p..p + 4].copy_from_slice(&a.to_be_bytes());
            p += 4;
        }
    }
    Some(p)
}

/// Build a read-only request (convenience over `build_write_read`).
pub fn build_read(read_addrs: &[u32], out: &mut [u8]) -> Option<usize> {
    build_write_read(0, &[], read_addrs, out)
}

/// Build a write-only request (convenience over `build_write_read`). Write-only packets get no
/// reply (PROTOCOL.md 8.1), use `build_write_read` with at least one read when delivery
/// matters (a common pattern: write, then read the same address back).
pub fn build_write(write_addr: u32, values: &[u32], out: &mut [u8]) -> Option<usize> {
    build_write_read(write_addr, values, &[], out)
}

/// Parse a reply packet, writing the returned register values into `values_out` in the order
/// the request's `read_addrs` were sent. Returns the number of values parsed, or `None` if the
/// packet is short, malformed, or `values_out` is too small.
pub fn parse_reply(buf: &[u8], values_out: &mut [u32]) -> Option<usize> {
    if buf.len() < HEADER_LEN {
        return None;
    }
    if buf[0] != MAGIC[0] || buf[1] != MAGIC[1] {
        return None;
    }
    if buf[2] != HDR_BYTE2 {
        return None; // not a non-probe reply
    }
    let count = buf[10] as usize; // W = R (echoed), R = 0 in a reply
    if count == 0 {
        return Some(0);
    }
    if count > values_out.len() {
        return None;
    }
    let needed = HEADER_LEN + 4 + count * 4;
    if buf.len() < needed {
        return None;
    }
    let mut p = HEADER_LEN + 4; // skip base return address
    for slot in values_out.iter_mut().take(count) {
        *slot = u32::from_be_bytes([buf[p], buf[p + 1], buf[p + 2], buf[p + 3]]);
        p += 4;
    }
    Some(count)
}

// ---- I2C transfer register (front-end block 0x34/0x38/0x3C, PROTOCOL.md 8.3) --------------
/// Bus numbers for `I2C_XFER` bits [31:30]. Bus 0 is refused by the gateware.
pub mod i2c_bus {
    /// VersaClock 5 clock chip (0x6A).
    pub const CLOCK: u8 = 1;
    /// N2ADR filter board MCP23008 (0x20); PA bias pots / configuration EEPROM MCP4662 (0x2C);
    /// N2ADR Pico IO board (0x1D, ROM 0x41).
    pub const FRONT_END: u8 = 2;
    /// MAX11613 slow ADC (0x34, probes only; the gateware reads it).
    pub const SLOW_ADC: u8 = 3;
}

const I2C_READ: u32 = 1 << 24;
const I2C_PROBE: u32 = 1 << 23;

/// Build the `I2C_XFER` value for a register read: sets the register pointer, then reads 4
/// bytes back (the target device's own register width decides how many of those bytes are
/// meaningful, an 8-bit I/O expander like the MCP23008 only fills the low byte).
pub fn i2c_read_value(bus: u8, addr7: u8, register: u8) -> u32 {
    ((bus as u32 & 0x3) << 30) | I2C_READ | ((addr7 as u32 & 0x7f) << 16) | ((register as u32) << 8)
}

/// Build the `I2C_XFER` value for a register write: register byte + value byte.
pub fn i2c_write_value(bus: u8, addr7: u8, register: u8, value: u8) -> u32 {
    ((bus as u32 & 0x3) << 30) | ((addr7 as u32 & 0x7f) << 16) | ((register as u32) << 8) | value as u32
}

/// Build the `I2C_XFER` value for a bus probe (one byte read, address only).
pub fn i2c_probe_value(bus: u8, addr7: u8) -> u32 {
    ((bus as u32 & 0x3) << 30) | I2C_PROBE | ((addr7 as u32 & 0x7f) << 16)
}

/// Decoded `I2C_STATUS` (front-end block offset 0x38).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct I2cStatus {
    pub busy: bool,
    pub last_nack: bool,
    pub refused_bias_guard: bool,
    pub dropped_engine_busy: bool,
    pub request_not_yet_on_bus: bool,
    /// Transfers done, mod 256, compare against a value taken before the transfer started to
    /// detect completion without racing a free-running counter.
    pub transfers_done: u8,
    /// Refused or dropped, mod 256.
    pub refused_or_dropped: u8,
}

/// Decodes the `I2C_STATUS` register value.
pub fn parse_i2c_status(v: u32) -> I2cStatus {
    I2cStatus {
        busy: v & (1 << 0) != 0,
        last_nack: v & (1 << 1) != 0,
        refused_bias_guard: v & (1 << 2) != 0,
        dropped_engine_busy: v & (1 << 3) != 0,
        request_not_yet_on_bus: v & (1 << 4) != 0,
        transfers_done: ((v >> 16) & 0xff) as u8,
        refused_or_dropped: ((v >> 24) & 0xff) as u8,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn write_read_roundtrip() {
        let mut buf = [0u8; MAX_PACKET];
        let n = build_write_read(frontend::I2C_XFER, &[0xdead_beef], &[frontend::I2C_STATUS, frontend::I2C_RDATA], &mut buf).unwrap();
        assert_eq!(&buf[0..4], &[0x4E, 0x6F, 0x10, 0x44]);
        assert_eq!(buf[10], 1); // W
        assert_eq!(buf[11], 2); // R
        assert_eq!(&buf[12..16], &frontend::I2C_XFER.to_be_bytes());
        assert_eq!(&buf[16..20], &0xdead_beefu32.to_be_bytes());
        // base return address (0) then the two read addresses
        assert_eq!(&buf[20..24], &[0, 0, 0, 0]);
        assert_eq!(&buf[24..28], &frontend::I2C_STATUS.to_be_bytes());
        assert_eq!(&buf[28..32], &frontend::I2C_RDATA.to_be_bytes());
        assert_eq!(n, 32);
    }

    #[test]
    fn read_only_has_no_write_words() {
        let mut buf = [0u8; MAX_PACKET];
        let n = build_read(&[status::ID, status::SAFETY_BYTE], &mut buf).unwrap();
        assert_eq!(buf[10], 0);
        assert_eq!(buf[11], 2);
        assert_eq!(n, HEADER_LEN + 4 + 2 * 4);
    }

    #[test]
    fn refuses_tx_permit_write() {
        let mut buf = [0u8; MAX_PACKET];
        assert!(build_write(frontend::TX_PERMIT, &[0x5458_0001], &mut buf).is_none());
        // a multi-word write starting at ID (0x00) and spanning through TX_PERMIT (0x04) is
        // refused too, even though its first word is an unrelated register.
        assert!(build_write(frontend::ID, &[0, 0, 0], &mut buf).is_none());
        // but a write that stops just short of TX_PERMIT is fine.
        assert!(build_write(frontend::ID, &[0], &mut buf).is_some());
    }

    #[test]
    fn reply_parses_in_request_order() {
        // Build a reply by hand as the gateware would send it: header (W=R echoed, R=0), base
        // return address, then R values.
        let mut reply = [0u8; MAX_PACKET];
        reply[0] = 0x4E;
        reply[1] = 0x6F;
        reply[2] = 0x10;
        reply[3] = 0x44;
        reply[10] = 2; // W (=R requested)
        reply[11] = 0; // R
        reply[16..20].copy_from_slice(&status::ID_EXPECTED.to_be_bytes());
        reply[20..24].copy_from_slice(&0x0000_0001u32.to_be_bytes());
        let mut out = [0u32; 4];
        let n = parse_reply(&reply[..24], &mut out).unwrap();
        assert_eq!(n, 2);
        assert_eq!(out[0], status::ID_EXPECTED);
        assert_eq!(out[1], 1);
    }

    #[test]
    fn reply_rejects_short_packet() {
        let mut reply = [0u8; 20];
        reply[0] = 0x4E;
        reply[1] = 0x6F;
        reply[2] = 0x10;
        reply[10] = 3; // claims 3 values but the packet is too short to hold them
        let mut out = [0u32; 4];
        assert!(parse_reply(&reply, &mut out).is_none());
    }

    #[test]
    fn i2c_xfer_values() {
        // bus 2, MCP23008 (0x20), register 0x0A (OLAT), read
        let v = i2c_read_value(i2c_bus::FRONT_END, 0x20, 0x0A);
        assert_eq!(v, (2u32 << 30) | I2C_READ | (0x20 << 16) | (0x0A << 8));
        let w = i2c_write_value(i2c_bus::FRONT_END, 0x20, 0x0A, 0x55);
        assert_eq!(w, (2u32 << 30) | (0x20 << 16) | (0x0A << 8) | 0x55);
    }

    #[test]
    fn i2c_status_bits() {
        let s = parse_i2c_status((5 << 24) | (3 << 16) | (1 << 1) | 1);
        assert!(s.busy);
        assert!(s.last_nack);
        assert_eq!(s.transfers_done, 3);
        assert_eq!(s.refused_or_dropped, 5);
    }
}
