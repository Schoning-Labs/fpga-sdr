// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Network time for the firmware's clock (docs/SFP_LINKS.md section 4; docs/N1_SFP.md): a DHCP client and
//! an SNTP client on one `smoltcp` interface over any [`MacRings`] (on the board the RJ45 unit, `eth::Eth` of
//! `tr-fabric`). The caller polls it from its main loop and asks it for UTC.
//!
//! - Address, mask and router come from DHCP. The time server is the router unless
//!   [`NetTime::set_server`] names another (home routers answer NTP; DHCP option 42 is not read).
//! - A request goes out 1 s after the address is there, then every 2 s until one is answered, then
//!   every 10 minutes. The clock keeps running on the board's oscillator in between and when the
//!   network goes away: [`NetTime::state`] then says how old the last answer is.
//! - A second UDP socket serves the firmware (the PC's mouse and keyboard, docs/NETINPUT.md); see
//!   [`NetTime::set_service_port`].
//! - Nothing is allocated: sockets and buffers are in a [`NetStore`] the caller owns.

use smoltcp::iface::{Config, Interface, SocketHandle, SocketSet, SocketStorage};
use smoltcp::socket::{dhcpv4, udp};
use smoltcp::time::Instant;
use smoltcp::wire::{EthernetAddress, HardwareAddress, IpAddress, IpCidr, Ipv4Address};

use crate::device::RingDevice;
use crate::rings::MacRings;
use crate::sntp::{self, SntpClient, PACKET_LEN};

/// UDP port our requests come from.
pub const LOCAL_PORT: u16 = 50123;
/// Delay between requests while none has been answered, in microseconds.
const RETRY_US: u64 = 2_000_000;
/// Delay between requests once the clock is set, in microseconds (10 minutes).
const REFRESH_US: u64 = 600_000_000;

/// Sockets and packet buffers of a [`NetTime`].
pub struct NetStore<'a> {
    sockets: [SocketStorage<'a>; 3],
    rx_meta: [udp::PacketMetadata; 2],
    tx_meta: [udp::PacketMetadata; 2],
    rx_buf: [u8; 2 * PACKET_LEN],
    tx_buf: [u8; 2 * PACKET_LEN],
    svc_rx_meta: [udp::PacketMetadata; SERVICE_RX_PACKETS],
    svc_tx_meta: [udp::PacketMetadata; SERVICE_TX_PACKETS],
    svc_rx_buf: [u8; SERVICE_RX_BYTES],
    svc_tx_buf: [u8; SERVICE_TX_BYTES],
}

/// Datagrams the service socket (see [`NetTime::set_service_port`]) holds between two main-loop passes.
pub const SERVICE_RX_PACKETS: usize = 32;
/// Bytes the service socket holds between two main-loop passes.
pub const SERVICE_RX_BYTES: usize = 8 * 1024;
const SERVICE_TX_PACKETS: usize = 4;
const SERVICE_TX_BYTES: usize = 512;

impl NetStore<'_> {
    /// An empty store: all buffers zeroed, all socket slots free.
    pub fn new() -> Self {
        NetStore {
            sockets: [SocketStorage::EMPTY; 3],
            rx_meta: [udp::PacketMetadata::EMPTY; 2],
            tx_meta: [udp::PacketMetadata::EMPTY; 2],
            rx_buf: [0; 2 * PACKET_LEN],
            tx_buf: [0; 2 * PACKET_LEN],
            svc_rx_meta: [udp::PacketMetadata::EMPTY; SERVICE_RX_PACKETS],
            svc_tx_meta: [udp::PacketMetadata::EMPTY; SERVICE_TX_PACKETS],
            svc_rx_buf: [0; SERVICE_RX_BYTES],
            svc_tx_buf: [0; SERVICE_TX_BYTES],
        }
    }
}

impl Default for NetStore<'_> {
    fn default() -> Self {
        Self::new()
    }
}

/// What [`NetTime::state`] reports about the clock.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TimeState {
    /// No link, or no address yet, and the clock was never set.
    NoNetwork,
    /// Address there, a time server asked, no answer yet.
    Waiting,
    /// Set from the network `age_s` seconds ago.
    Synced { age_s: u32 },
}

/// The DHCP and SNTP clients with their `smoltcp` interface; see the module documentation.
pub struct NetTime<'a> {
    iface: Interface,
    sockets: SocketSet<'a>,
    dhcp: SocketHandle,
    udp: SocketHandle,
    /// A second UDP socket for a service of the firmware (the PC's mouse and keyboard, docs/NETINPUT.md).
    service: SocketHandle,
    service_port: Option<u16>,
    server: Option<Ipv4Address>,
    router: Option<Ipv4Address>,
    configured: bool,
    link_was_up: bool,
    pending: Option<SntpClient>,
    next_query_us: u64,
    offset_us: i64,
    last_sync_us: Option<u64>,
    /// Requests sent, for the console.
    pub queries: u32,
    /// Answers taken, for the console.
    pub answers: u32,
}

impl<'a> NetTime<'a> {
    /// Builds the interface with the Ethernet address `mac` and starts DHCP; `now_us` is the monotonic time in microseconds.
    pub fn new<R: MacRings>(store: &'a mut NetStore<'a>, rings: &mut R, mac: [u8; 6], now_us: u64) -> Self {
        let mut config = Config::new(HardwareAddress::Ethernet(EthernetAddress(mac)));
        config.random_seed = now_us ^ u64::from_le_bytes([mac[0], mac[1], mac[2], mac[3], mac[4], mac[5], 0x5A, 0xA5]);
        let mut dev = RingDevice::new(rings);
        let iface = Interface::new(config, &mut dev, Instant::from_micros(now_us as i64));
        let NetStore { sockets, rx_meta, tx_meta, rx_buf, tx_buf, svc_rx_meta, svc_tx_meta, svc_rx_buf, svc_tx_buf } = store;
        let mut sockets = SocketSet::new(&mut sockets[..]);
        let dhcp = sockets.add(dhcpv4::Socket::new());
        let udp = sockets.add(udp::Socket::new(
            udp::PacketBuffer::new(&mut rx_meta[..], &mut rx_buf[..]),
            udp::PacketBuffer::new(&mut tx_meta[..], &mut tx_buf[..]),
        ));
        let service = sockets.add(udp::Socket::new(
            udp::PacketBuffer::new(&mut svc_rx_meta[..], &mut svc_rx_buf[..]),
            udp::PacketBuffer::new(&mut svc_tx_meta[..], &mut svc_tx_buf[..]),
        ));
        NetTime {
            iface,
            sockets,
            dhcp,
            udp,
            service,
            service_port: None,
            server: None,
            router: None,
            configured: false,
            link_was_up: false,
            pending: None,
            next_query_us: 0,
            offset_us: 0,
            last_sync_us: None,
            queries: 0,
            answers: 0,
        }
    }

    /// Names the time server; `None` means the router DHCP gave.
    pub fn set_server(&mut self, ip: Option<[u8; 4]>) {
        self.server = ip.map(|a| Ipv4Address::new(a[0], a[1], a[2], a[3]));
    }

    /// Opens a UDP socket on `port` once the address is there (broadcasts to the port arrive as well). `None` closes it.
    pub fn set_service_port(&mut self, port: Option<u16>) {
        self.service_port = port;
        if port.is_none() {
            self.sockets.get_mut::<udp::Socket>(self.service).close();
        }
    }

    /// The next datagram the service socket holds: copied into `buf` (cut if longer), with its true length and its
    /// sender's address and port. `None` when there is none (or no address yet).
    pub fn service_recv(&mut self, buf: &mut [u8]) -> Option<(usize, [u8; 4], u16)> {
        let socket = self.sockets.get_mut::<udp::Socket>(self.service);
        let (data, meta) = socket.recv().ok()?;
        let n = data.len().min(buf.len());
        buf[..n].copy_from_slice(&data[..n]);
        let ip = match meta.endpoint.addr {
            IpAddress::Ipv4(a) => a.0,
            #[allow(unreachable_patterns)]
            _ => [0; 4],
        };
        Some((data.len(), ip, meta.endpoint.port))
    }

    /// Queues a datagram from the service port; it goes out in the next [`NetTime::poll`]. False if it did not fit.
    pub fn service_send(&mut self, to: [u8; 4], port: u16, data: &[u8]) -> bool {
        let socket = self.sockets.get_mut::<udp::Socket>(self.service);
        socket.is_open() && socket.send_slice(data, (IpAddress::Ipv4(Ipv4Address::new(to[0], to[1], to[2], to[3])), port)).is_ok()
    }

    /// Our address, once DHCP gave one.
    pub fn address(&self) -> Option<[u8; 4]> {
        if !self.configured {
            return None;
        }
        self.iface.ipv4_addr().map(|a| a.0)
    }

    /// Call from the main loop (every few milliseconds is plenty). `link_up` is the link state of the Ethernet unit.
    pub fn poll<R: MacRings>(&mut self, rings: &mut R, link_up: bool, now_us: u64) {
        if link_up != self.link_was_up {
            self.link_was_up = link_up;
            // A link that came or went may be on another network, so DHCP starts again.
            self.sockets.get_mut::<dhcpv4::Socket>(self.dhcp).reset();
            self.pending = None;
        }
        if !link_up {
            return;
        }
        let now = Instant::from_micros(now_us as i64);
        let mut dev = RingDevice::new(rings);
        self.iface.poll(now, &mut dev, &mut self.sockets);

        match self.sockets.get_mut::<dhcpv4::Socket>(self.dhcp).poll() {
            Some(dhcpv4::Event::Configured(cfg)) => {
                self.iface.update_ip_addrs(|addrs| {
                    addrs.clear();
                    let _ = addrs.push(IpCidr::Ipv4(cfg.address));
                });
                self.iface.routes_mut().remove_default_ipv4_route();
                if let Some(router) = cfg.router {
                    let _ = self.iface.routes_mut().add_default_ipv4_route(router);
                }
                self.router = cfg.router;
                self.configured = true;
                self.next_query_us = now_us + 1_000_000;
            }
            Some(dhcpv4::Event::Deconfigured) => {
                self.iface.update_ip_addrs(|addrs| addrs.clear());
                self.iface.routes_mut().remove_default_ipv4_route();
                self.configured = false;
                self.pending = None;
            }
            None => {}
        }
        if !self.configured {
            return;
        }

        let socket = self.sockets.get_mut::<udp::Socket>(self.udp);
        if !socket.is_open() {
            let _ = socket.bind(LOCAL_PORT);
        }
        while let Ok((data, _from)) = socket.recv() {
            if let Some(c) = self.pending.and_then(|p| p.on_reply(data, now_us)) {
                self.offset_us = c.utc_us - c.mono_us as i64;
                self.last_sync_us = Some(c.mono_us);
                self.pending = None;
                self.answers += 1;
                self.next_query_us = now_us + REFRESH_US;
            }
        }
        if let Some(port) = self.service_port {
            let svc = self.sockets.get_mut::<udp::Socket>(self.service);
            if !svc.is_open() {
                let _ = svc.bind(port);
            }
        }
        let socket = self.sockets.get_mut::<udp::Socket>(self.udp);
        if now_us >= self.next_query_us {
            if let Some(server) = self.server.or(self.router) {
                let (client, req) = SntpClient::request(now_us);
                if socket.can_send() && socket.send_slice(&req, (IpAddress::Ipv4(server), sntp::NTP_PORT)).is_ok() {
                    self.pending = Some(client);
                    self.queries += 1;
                }
            }
            self.next_query_us = now_us + RETRY_US;
        }
    }

    /// Whether the clock is set, and how old the setting is.
    pub fn state(&self, now_us: u64) -> TimeState {
        match self.last_sync_us {
            Some(t) => TimeState::Synced { age_s: (now_us.saturating_sub(t) / 1_000_000) as u32 },
            None if self.configured && self.link_was_up => TimeState::Waiting,
            None => TimeState::NoNetwork,
        }
    }

    /// UTC in microseconds since 1970, once the clock was set.
    pub fn utc_us(&self, now_us: u64) -> Option<i64> {
        self.last_sync_us.map(|_| now_us as i64 + self.offset_us)
    }
}
