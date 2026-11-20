// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! UDP transport for the register bridge (`bridge` module) and I2C transfers over it
//! (`PROTOCOL.md` section 8). This is the only place where `tr-hl2` sends an I2C transaction. It
//! is used to read back the output latch of the MCP23008 on the N2ADR filter board and to read
//! status and telemetry registers, and never to write the PA bias pots or the transmit interlock.

use crate::bridge::{self, frontend};
use std::io;
use std::net::{IpAddr, SocketAddr, UdpSocket};
use std::time::{Duration, Instant};

/// UDP client for the register bridge of one HL2.
pub struct BridgeClient {
    sock: UdpSocket,
    hl2_addr: SocketAddr,
}

impl BridgeClient {
    /// Opens a socket to the bridge port of the HL2 at `hl2_ip`, with a 300 ms read timeout.
    pub fn connect(hl2_ip: IpAddr) -> io::Result<Self> {
        let sock = UdpSocket::bind("0.0.0.0:0")?;
        sock.set_read_timeout(Some(Duration::from_millis(300)))?;
        Ok(BridgeClient { sock, hl2_addr: SocketAddr::new(hl2_ip, crate::protocol::PORT_BRIDGE) })
    }

    /// Read several registers in one round trip, in order. Retries once on a timeout (PROTOCOL.md
    /// 8.1: "reads are idempotent: retry on timeout").
    pub fn read_many(&self, addrs: &[u32]) -> io::Result<Vec<u32>> {
        let mut req = [0u8; bridge::MAX_PACKET];
        let n = bridge::build_read(addrs, &mut req)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "read request too large"))?;
        let mut last_err = None;
        for _ in 0..2 {
            match self.round_trip(&req[..n], addrs.len()) {
                Ok(v) => return Ok(v),
                Err(e) => last_err = Some(e),
            }
        }
        Err(last_err.unwrap())
    }

    /// Reads one 32-bit register.
    pub fn read_one(&self, addr: u32) -> io::Result<u32> {
        Ok(self.read_many(&[addr])?[0])
    }

    fn round_trip(&self, req: &[u8], expected_values: usize) -> io::Result<Vec<u32>> {
        self.sock.send_to(req, self.hl2_addr)?;
        let mut reply = [0u8; bridge::MAX_PACKET];
        let (rn, _) = self.sock.recv_from(&mut reply)?;
        let mut values = vec![0u32; expected_values];
        let got = bridge::parse_reply(&reply[..rn], &mut values)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "malformed or short bridge reply"))?;
        if got != expected_values {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "bridge reply value count mismatch"));
        }
        Ok(values)
    }

    /// Write-only (no reply expected). Refused (PermissionDenied) if `addr` is `TX_PERMIT` --
    /// `bridge::build_write` already refuses to build that packet; this turns the `None` into an
    /// explicit error instead of silently doing nothing.
    pub fn write(&self, addr: u32, value: u32) -> io::Result<()> {
        let mut req = [0u8; bridge::MAX_PACKET];
        let n = bridge::build_write(addr, &[value], &mut req).ok_or_else(|| {
            io::Error::new(io::ErrorKind::PermissionDenied, "tr-hl2 refuses to write the transmit-permission register")
        })?;
        self.sock.send_to(&req[..n], self.hl2_addr).map(|_| ())
    }

    /// Write then read the same address back in one packet (PROTOCOL.md 8.1: write-only packets
    /// get no reply, so read back in the same packet when delivery matters).
    pub fn write_read_back(&self, addr: u32, value: u32) -> io::Result<u32> {
        let mut req = [0u8; bridge::MAX_PACKET];
        let n = bridge::build_write_read(addr, &[value], &[addr], &mut req).ok_or_else(|| {
            io::Error::new(io::ErrorKind::PermissionDenied, "tr-hl2 refuses to write the transmit-permission register")
        })?;
        Ok(self.round_trip(&req[..n], 1)?[0])
    }

    /// Read one register byte over I2C via the front-end block's I2C_XFER engine (PROTOCOL.md
    /// 8.3): write the transaction, poll I2C_STATUS until its "transfers done" counter moves (or
    /// a NACK/refusal is reported), then read I2C_RDATA.
    pub fn i2c_read_register(&self, bus: u8, addr7: u8, register: u8) -> io::Result<u8> {
        let before = bridge::parse_i2c_status(self.read_one(frontend::I2C_STATUS)?);
        self.write(frontend::I2C_XFER, bridge::i2c_read_value(bus, addr7, register))?;
        self.poll_i2c_result(before)
    }

    /// Probe an I2C address (one byte read, PROTOCOL.md 8.3): true if it acknowledged.
    pub fn i2c_probe(&self, bus: u8, addr7: u8) -> io::Result<bool> {
        let before = bridge::parse_i2c_status(self.read_one(frontend::I2C_STATUS)?);
        self.write(frontend::I2C_XFER, bridge::i2c_probe_value(bus, addr7))?;
        match self.poll_i2c_result(before) {
            Ok(_) => Ok(true),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false), // NACK: nothing at that address
            Err(e) => Err(e),
        }
    }

    fn poll_i2c_result(&self, before: bridge::I2cStatus) -> io::Result<u8> {
        let deadline = Instant::now() + Duration::from_millis(250);
        loop {
            let status = bridge::parse_i2c_status(self.read_one(frontend::I2C_STATUS)?);
            if status.transfers_done != before.transfers_done {
                if status.last_nack {
                    return Err(io::Error::new(io::ErrorKind::NotFound, "I2C transfer NACKed"));
                }
                let rdata = self.read_one(frontend::I2C_RDATA)?;
                return Ok((rdata & 0xff) as u8);
            }
            if status.refused_or_dropped != before.refused_or_dropped {
                return Err(io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "I2C transfer refused or dropped (engine busy) -- PROTOCOL.md 8.3 says retry",
                ));
            }
            if Instant::now() >= deadline {
                return Err(io::Error::new(io::ErrorKind::TimedOut, "I2C transfer did not complete"));
            }
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    /// ID (0x4000_0000), gateware/marker version (0x4000_0004), capabilities (0x4000_000C) and
    /// the transmit-safety byte (0x4000_7000), in one round trip.
    pub fn read_status_block(&self) -> io::Result<StatusBlock> {
        let v = self.read_many(&[
            bridge::status::ID,
            bridge::status::VERSION,
            bridge::status::CAPABILITIES,
            bridge::status::SAFETY_BYTE,
            frontend::ILK_STATUS,
        ])?;
        Ok(StatusBlock { id: v[0], version: v[1], capabilities: v[2], safety_byte: (v[3] & 0xff) as u8, ilk_status: v[4] })
    }
}

/// Identification and status registers of the bridge, read in one go.
#[derive(Debug, Clone, Copy)]
pub struct StatusBlock {
    pub id: u32,
    pub version: u32,
    pub capabilities: u32,
    pub safety_byte: u8,
    pub ilk_status: u32,
}
