// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! openHPSDR discovery (`PROTOCOL.md` section 2): broadcasts a discovery request and collects the
//! replies for a short window.
//!
//! The code comes from `discover` and `discover_on_port` in `software/rawstream/rawcap/src/hl2.rs`
//! of the Hermes-Lite2 repository (branch `hl2-rawfront-release`, same owner, Apache-2.0),
//! trimmed to discovery only. The rest of that file is in `client.rs`, rewritten there with the
//! register-write safety guard of this crate.

use crate::protocol;
use std::net::{IpAddr, SocketAddr, UdpSocket};
use std::time::{Duration, Instant};

/// One HL2 that answered a discovery request.
#[derive(Debug, Clone)]
pub struct Discovered {
    pub ip: IpAddr,
    pub response: protocol::DiscoveryResponse,
}

/// Formats a MAC address as `aa:bb:cc:dd:ee:ff`.
pub fn mac_string(mac: &[u8; 6]) -> String {
    format!("{:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5])
}

/// Broadcast discovery on the given local interface IP and collect responses for up to
/// `timeout`. Tries port 1025 first, then falls back to 1024 (PROTOCOL.md section 1: both
/// ports handle discovery).
pub fn discover(local_ip: IpAddr, timeout: Duration) -> std::io::Result<Vec<Discovered>> {
    for port in [protocol::PORT_CMD, protocol::PORT_START_STOP] {
        let found = discover_on_port(local_ip, port, timeout)?;
        if !found.is_empty() {
            return Ok(found);
        }
    }
    Ok(Vec::new())
}

fn discover_on_port(local_ip: IpAddr, port: u16, timeout: Duration) -> std::io::Result<Vec<Discovered>> {
    let sock = UdpSocket::bind(SocketAddr::new(local_ip, 0))?;
    sock.set_broadcast(true)?;
    sock.set_read_timeout(Some(Duration::from_millis(300)))?;
    let req = protocol::build_discovery_request();
    sock.send_to(&req, ("255.255.255.255", port))?;

    let mut out = Vec::new();
    let mut buf = [0u8; 128];
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        match sock.recv_from(&mut buf) {
            Ok((n, from)) => {
                if let Some(r) = protocol::parse_discovery_response(&buf[..n]) {
                    out.push(Discovered { ip: from.ip(), response: r });
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock || e.kind() == std::io::ErrorKind::TimedOut => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(out)
}
