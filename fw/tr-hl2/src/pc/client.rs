// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! HL2 control: register writes on port 1025 and start and stop on port 1024. The wire bytes come
//! only from `protocol`.
//!
//! **Safety.** `write_command_register` refuses any write to register 0x31 (duplex) that sets the
//! real-DAC bit (bit 1), because `tr-hl2` must never drive the AD9866 transmit DAC. No function in
//! this crate writes the `TX_PERMIT` register of the bridge, which is the only way to request the
//! key bit (see `bridge.rs`).

use crate::protocol;
use std::io;
use std::net::{IpAddr, UdpSocket};
use std::time::Duration;

/// Control connection to one HL2, with the safety guard on register writes.
pub struct Hl2Client {
    pub ip: IpAddr,
}

impl Hl2Client {
    /// A client for the HL2 at `ip`.
    pub fn new(ip: IpAddr) -> Self {
        Hl2Client { ip }
    }

    /// Write the raw-mode/frame-size register (0x30, PROTOCOL.md 5.1).
    pub fn set_raw_mode(&self, enable: bool, test_pattern: bool, quiet_capture: bool, samples_per_frame: u16) -> io::Result<()> {
        let (clamped, was_clamped) = protocol::clamp_samples_per_frame(samples_per_frame);
        if was_clamped {
            eprintln!("tr-hl2: samples_per_frame {samples_per_frame} clamped to {clamped} (PROTOCOL.md 5.1)");
        }
        let value = protocol::reg_raw_value(enable, test_pattern, quiet_capture, clamped);
        self.write_command_register(protocol::REG_ADDR_RAWMODE, value)
    }

    /// Turn raw mode fully off (register 0x30 = 0). Raw mode stays on until explicitly cleared
    /// (or the HL2 is power-cycled); leaving it on means the next normal SDR client gets raw
    /// frames instead of IQ data.
    pub fn clear_raw_mode(&self) -> io::Result<()> {
        self.write_command_register(protocol::REG_ADDR_RAWMODE, protocol::reg_raw_off())
    }

    /// Register 0x31: duplex/real-DAC/echo. Refuses the real-DAC bit, see the module doc.
    /// Echo (bit 2) and the plain duplex-enable bit (bit 0, virtual DAC) are allowed.
    pub fn set_duplex_value(&self, value: u32) -> io::Result<()> {
        self.write_command_register(protocol::REG_ADDR_DUPLEX, value)
    }

    /// Clears register 0x31, which switches echo and the virtual DAC off.
    pub fn clear_duplex(&self) -> io::Result<()> {
        self.write_command_register(protocol::REG_ADDR_DUPLEX, 0)
    }

    /// N2ADR filter board / RX antenna / front-end register 0x00 (ARCHITECTURE.md section 8,
    /// `filter` module). `value` should be built from `filter::band_filter_bits` and the
    /// `filter::BIT_*` constants, keeping any sync-off/band-volts bits the caller wants to
    /// preserve (PROTOCOL.md section 12: writes replace the whole register).
    pub fn set_frontend(&self, value: u32) -> io::Result<()> {
        self.write_command_register(protocol::REG_ADDR_FRONTEND, value)
    }

    /// RX gain (AD9866 PGA), register 0x0A, -12 to +48 dB (PROTOCOL.md section 3). Clamps out of
    /// range and returns the dB actually sent, so the caller can report what was applied.
    pub fn set_rx_gain_db(&self, db: i32) -> io::Result<i32> {
        let (value, clamped) = protocol::rx_gain_value(db);
        self.write_command_register(protocol::REG_ADDR_RX_GAIN, value)?;
        Ok(clamped)
    }

    /// Write any command register (port 1025, PROTOCOL.md section 3), with the real-DAC guard.
    /// Public so a caller can reach registers this wrapper doesn't name yet, without losing the
    /// safety check.
    pub fn write_command_register(&self, addr: u8, value: u32) -> io::Result<()> {
        if addr == protocol::REG_ADDR_DUPLEX && value & protocol::REG_DUPLEX_REAL != 0 {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "tr-hl2 refuses to write register 0x31 with the real-DAC bit (bit 1) set -- \
                 that requires an explicit owner instruction outside this crate (SAFETY.md)",
            ));
        }
        let pkt = protocol::build_command_packet(addr, value);
        let sock = UdpSocket::bind("0.0.0.0:0")?;
        sock.set_read_timeout(Some(Duration::from_millis(500)))?;
        sock.send_to(&pkt, (self.ip, protocol::PORT_CMD))?;
        let mut buf = [0u8; 128];
        // Best-effort ack read; not fatal if none arrives (PROTOCOL.md doesn't promise one for
        // every write path, and a dropped ack on this direct link is not itself an error).
        let _ = sock.recv_from(&mut buf);
        Ok(())
    }
}

/// Send the start command on the given (already open) socket. PROTOCOL.md section 4: the
/// receiving socket must be open BEFORE this is sent, or an ICMP port-unreachable stops the
/// stream immediately.
pub fn send_start(sock: &UdpSocket, hl2_ip: IpAddr) -> io::Result<()> {
    sock.send_to(&protocol::cmd_start(), (hl2_ip, protocol::PORT_START_STOP)).map(|_| ())
}

/// Sends the stop packet to the HL2 from `sock`.
pub fn send_stop(sock: &UdpSocket, hl2_ip: IpAddr) -> io::Result<()> {
    sock.send_to(&protocol::cmd_stop(), (hl2_ip, protocol::PORT_START_STOP)).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refuses_real_dac_bit() {
        let c = Hl2Client::new("169.254.202.183".parse().unwrap());
        let err = c.write_command_register(protocol::REG_ADDR_DUPLEX, protocol::REG_DUPLEX_REAL).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::PermissionDenied);
        // echo (bit 2) alone is fine to attempt to send (no network here, so this only checks
        // the guard doesn't fire; the actual send may fail in this sandboxed test environment
        // and that's fine, only the immediate PermissionDenied guard is under test).
        let combined = protocol::REG_DUPLEX_ENABLE | protocol::REG_DUPLEX_REAL;
        assert_eq!(
            c.write_command_register(protocol::REG_ADDR_DUPLEX, combined).unwrap_err().kind(),
            io::ErrorKind::PermissionDenied
        );
    }
}
