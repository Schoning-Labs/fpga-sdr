// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Socket setup for the raw-stream receive path. The stream is about 12,900 jumbo datagrams per
//! second at 931 Mbit/s (`docs/rawfront/TOOLCHAIN.md` section 8), and a plain
//! `std::net::UdpSocket` does not expose the sizing of `SO_RCVBUF`, so this module uses `socket2`
//! for that one thing and hands back an ordinary `UdpSocket`.

use socket2::{Domain, Socket, Type};
use std::io;
use std::net::{IpAddr, SocketAddr, UdpSocket};
use std::time::Duration;

/// A generous default: holds several jumbo frames' worth of slack if a receive thread stalls
/// briefly (docs/rawfront/TOOLCHAIN.md section 8 recommends the NIC driver's own maximum
/// receive-buffer setting for the same reason).
pub const DEFAULT_RCVBUF: usize = 32 * 1024 * 1024;

/// Open, size and bind the socket used both to send start/stop and to receive the stream. Must
/// be bound BEFORE start is sent (PROTOCOL.md section 4: an unopened receive socket gets an
/// ICMP port-unreachable, which stops the stream).
pub fn open_stream_socket(local_ip: IpAddr, requested_rcvbuf: usize) -> io::Result<UdpSocket> {
    let domain = match local_ip {
        IpAddr::V4(_) => Domain::IPV4,
        IpAddr::V6(_) => Domain::IPV6,
    };
    let sock = Socket::new(domain, Type::DGRAM, None)?;
    let _ = sock.set_recv_buffer_size(requested_rcvbuf); // best-effort; some platforms cap this
    sock.bind(&SocketAddr::new(local_ip, 0).into())?;
    sock.set_read_timeout(Some(Duration::from_secs(2)))?;
    Ok(sock.into())
}

/// The socket's current `SO_RCVBUF`, for reporting to the operator (what was actually granted
/// may be less than requested).
pub fn recv_buffer_size(sock: &UdpSocket) -> io::Result<usize> {
    // try_clone duplicates the OS handle, so the temporary Socket wrapper can close its own
    // copy on drop without affecting the caller's socket.
    let s = Socket::from(sock.try_clone()?);
    s.recv_buffer_size()
}
