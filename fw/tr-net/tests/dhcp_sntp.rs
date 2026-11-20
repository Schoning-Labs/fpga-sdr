// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Host test of the network stack: `smoltcp` runs over an in-memory model of the rings and
//! completes DHCP and an SNTP exchange against a test server model, which sets the time to within
//! 1 ms of the time the server serves.
//!
//! One end of [`tr_net::device::mock::RingModel::pair`] carries a real `smoltcp` `Interface`
//! (DHCPv4 client socket, then a UDP socket for SNTP) through [`tr_net::device::RingDevice`]; the
//! other end is driven directly by this test (`server_step` below), which is not a second
//! `smoltcp` stack but a small hand-rolled model of just enough of a DHCP server and an SNTP
//! server to answer this client -- parsing/building Ethernet+IPv4+UDP frames with `smoltcp`'s own
//! wire types, so both ends agree on the wire format without a second full stack's worth of code.

use smoltcp::iface::{Config, Interface, SocketSet};
use smoltcp::socket::{dhcpv4, udp};
use smoltcp::time::Instant;
use smoltcp::wire::{
    ArpOperation, ArpPacket, ArpRepr, EthernetAddress, EthernetFrame, EthernetProtocol, EthernetRepr,
    HardwareAddress, IpAddress, IpCidr, IpProtocol, Ipv4Address, Ipv4Packet, Ipv4Repr, UdpPacket, UdpRepr,
};

use tr_net::device::mock::RingModel;
use tr_net::device::RingDevice;
use tr_net::sntp::{self, SntpClient};

const CLIENT_MAC: EthernetAddress = EthernetAddress([0x02, 0x00, 0x00, 0x00, 0x00, 0x01]);
const SERVER_MAC: EthernetAddress = EthernetAddress([0x02, 0x00, 0x00, 0x00, 0x00, 0x02]);
const SERVER_IP: Ipv4Address = Ipv4Address::new(192, 168, 1, 1);
const OFFERED_IP: Ipv4Address = Ipv4Address::new(192, 168, 1, 50);

/// UTC (Unix epoch) microseconds the test server model reports, and what the test checks the
/// client's disciplined clock against once the SNTP exchange completes.
const SERVED_UTC_US: i64 = 1_735_000_000_000_000; // an arbitrary but realistic 2024-ish instant

fn main_step(iface: &mut Interface, dev: &mut RingDevice<RingModel>, sockets: &mut SocketSet, now: Instant) {
    iface.poll(now, dev, sockets);
}

/// Reads every frame currently waiting on `server_rings` and answers DHCP (port 67) and SNTP
/// (port 123) requests. Returns `true` if it sent an SNTP reply (so the test knows the exchange
/// is done).
fn server_step(server_rings: &mut RingModel) -> bool {
    use tr_net::rings::MacRings;
    let mut sent_sntp_reply = false;
    let mut buf = [0u8; 1514];
    while let Some(len) = server_rings.receive(&mut buf) {
        let frame = &buf[..len];
        let Ok(eth) = EthernetFrame::new_checked(frame) else { continue };
        if eth.ethertype() == EthernetProtocol::Arp {
            handle_arp(server_rings, eth.payload());
            continue;
        }
        if eth.ethertype() != EthernetProtocol::Ipv4 {
            continue;
        }
        let Ok(ip) = Ipv4Packet::new_checked(eth.payload()) else { continue };
        if ip.next_header() != IpProtocol::Udp {
            continue;
        }
        let Ok(udp) = UdpPacket::new_checked(ip.payload()) else { continue };
        let dst_port = udp.dst_port();
        let payload = udp.payload();

        if dst_port == 67 {
            handle_dhcp(server_rings, payload);
        } else if dst_port == sntp::NTP_PORT {
            handle_sntp(server_rings, ip.src_addr(), udp.src_port(), payload);
            sent_sntp_reply = true;
        }
    }
    sent_sntp_reply
}

fn send_udp_frame(
    rings: &mut RingModel,
    dst_ip: Ipv4Address,
    dst_port: u16,
    src_port: u16,
    payload: &[u8],
) {
    use tr_net::rings::MacRings;

    let udp_repr = UdpRepr { src_port, dst_port };
    let ip_repr = Ipv4Repr {
        src_addr: SERVER_IP,
        dst_addr: dst_ip,
        next_header: IpProtocol::Udp,
        payload_len: udp_repr.header_len() + payload.len(),
        hop_limit: 64,
    };
    let eth_repr = EthernetRepr { src_addr: SERVER_MAC, dst_addr: CLIENT_MAC, ethertype: EthernetProtocol::Ipv4 };

    let mut buf = [0u8; 1514];
    let eth_len = eth_repr.buffer_len();
    let ip_len = ip_repr.buffer_len();
    let udp_len = udp_repr.header_len() + payload.len();

    {
        let mut eth = EthernetFrame::new_unchecked(&mut buf[..eth_len + ip_len + udp_len]);
        eth_repr.emit(&mut eth);
    }
    {
        let mut ip = Ipv4Packet::new_unchecked(&mut buf[eth_len..eth_len + ip_len + udp_len]);
        ip_repr.emit(&mut ip, &smoltcp::phy::ChecksumCapabilities::default());
    }
    {
        let mut udp = UdpPacket::new_unchecked(&mut buf[eth_len + ip_len..eth_len + ip_len + udp_len]);
        udp_repr.emit(
            &mut udp,
            &IpAddress::Ipv4(SERVER_IP),
            &IpAddress::Ipv4(dst_ip),
            payload.len(),
            |p| p.copy_from_slice(payload),
            &smoltcp::phy::ChecksumCapabilities::default(),
        );
    }

    rings.transmit(&buf[..eth_len + ip_len + udp_len]);
}

/// Answers "who has SERVER_IP" (smoltcp resolves the server's MAC before it will send the SNTP
/// request UDP frame -- without this the request never leaves the client's neighbor cache).
fn handle_arp(rings: &mut RingModel, payload: &[u8]) {
    use tr_net::rings::MacRings;
    let Ok(pkt) = ArpPacket::new_checked(payload) else { return };
    let Ok(ArpRepr::EthernetIpv4 { operation: ArpOperation::Request, target_protocol_addr, source_hardware_addr, source_protocol_addr, .. }) =
        ArpRepr::parse(&pkt)
    else {
        return;
    };
    if target_protocol_addr != SERVER_IP {
        return;
    }
    let reply = ArpRepr::EthernetIpv4 {
        operation: ArpOperation::Reply,
        source_hardware_addr: SERVER_MAC,
        source_protocol_addr: SERVER_IP,
        target_hardware_addr: source_hardware_addr,
        target_protocol_addr: source_protocol_addr,
    };
    let eth_repr = EthernetRepr { src_addr: SERVER_MAC, dst_addr: source_hardware_addr, ethertype: EthernetProtocol::Arp };
    let mut buf = [0u8; 64];
    let total = eth_repr.buffer_len() + reply.buffer_len();
    {
        let mut eth = EthernetFrame::new_unchecked(&mut buf[..total]);
        eth_repr.emit(&mut eth);
        let mut arp = ArpPacket::new_unchecked(eth.payload_mut());
        reply.emit(&mut arp);
    }
    rings.transmit(&buf[..total]);
}

/// Minimal DHCP server: DISCOVER -> OFFER, REQUEST -> ACK. Raw BOOTP/DHCP layout (RFC 2131) --
/// smoltcp's own wire module has no server-side DHCP builder, only the client side it uses
/// itself, so this hand-builds the fixed part and the handful of options a `smoltcp` DHCP client
/// actually looks at (message type, server id, subnet mask, router, lease time).
fn handle_dhcp(rings: &mut RingModel, req: &[u8]) {
    if req.len() < 240 || &req[236..240] != [99, 130, 83, 99] {
        return; // not a DHCP packet (bad magic cookie)
    }
    let xid = &req[4..8];
    let chaddr = &req[28..34];
    let msg_type = find_option(&req[240..], 53).map(|v| v[0]);

    let (yiaddr, dhcp_msg_type): (Ipv4Address, u8) = match msg_type {
        Some(1) => (OFFERED_IP, 2), // DISCOVER -> OFFER
        Some(3) => (OFFERED_IP, 5), // REQUEST -> ACK
        _ => return,
    };

    let mut pkt = [0u8; 300];
    pkt[0] = 2; // BOOTREPLY
    pkt[1] = 1; // htype ethernet
    pkt[2] = 6; // hlen
    pkt[4..8].copy_from_slice(xid);
    pkt[16..20].copy_from_slice(&yiaddr.as_bytes());
    pkt[28..34].copy_from_slice(chaddr);
    pkt[236..240].copy_from_slice(&[99, 130, 83, 99]);

    let mut o = 240;
    pkt[o] = 53; pkt[o + 1] = 1; pkt[o + 2] = dhcp_msg_type; o += 3;
    pkt[o] = 54; pkt[o + 1] = 4; pkt[o + 2..o + 6].copy_from_slice(&SERVER_IP.as_bytes()); o += 6;
    pkt[o] = 51; pkt[o + 1] = 4; pkt[o + 2..o + 6].copy_from_slice(&3600u32.to_be_bytes()); o += 6;
    pkt[o] = 1; pkt[o + 1] = 4; pkt[o + 2..o + 6].copy_from_slice(&Ipv4Address::new(255, 255, 255, 0).as_bytes()); o += 6;
    pkt[o] = 3; pkt[o + 1] = 4; pkt[o + 2..o + 6].copy_from_slice(&SERVER_IP.as_bytes()); o += 6;
    pkt[o] = 255; o += 1;

    send_udp_frame(rings, Ipv4Address::BROADCAST, 68, 67, &pkt[..o]);
}

fn find_option(options: &[u8], code: u8) -> Option<&[u8]> {
    let mut i = 0;
    while i + 1 < options.len() {
        let opt = options[i];
        if opt == 255 || opt == 0 {
            break;
        }
        let len = options[i + 1] as usize;
        if i + 2 + len > options.len() {
            break;
        }
        if opt == code {
            return Some(&options[i + 2..i + 2 + len]);
        }
        i += 2 + len;
    }
    None
}

/// Minimal SNTP server: echoes the client's Transmit Timestamp into Origin Timestamp, and
/// reports [`SERVED_UTC_US`] (converted to the NTP 1900 epoch) as both Receive and Transmit
/// Timestamp -- a "server" with zero processing time, which is fine here (the round trip's
/// network delay is also ~0 in this in-memory model, so the offset formula's symmetric-delay
/// assumption holds trivially).
fn handle_sntp(rings: &mut RingModel, client_ip: Ipv4Address, client_port: u16, req: &[u8]) {
    if req.len() < sntp::PACKET_LEN {
        return;
    }
    let served_ntp_us = (SERVED_UTC_US + sntp::NTP_UNIX_EPOCH_OFFSET_US) as u64;
    let mut reply = [0u8; sntp::PACKET_LEN];
    reply[0] = 0b00_100_100; // LI=0, VN=4, Mode=4 (server)
    reply[1] = 1; // stratum 1
    reply[24..32].copy_from_slice(&req[40..48]); // echo client's Transmit Timestamp
    reply[32..40].copy_from_slice(&sntp::encode_ntp(served_ntp_us));
    reply[40..48].copy_from_slice(&sntp::encode_ntp(served_ntp_us));

    send_udp_frame(rings, client_ip, client_port, sntp::NTP_PORT as u16, &reply);
}

#[test]
fn dhcp_then_sntp_sets_time_within_1ms() {
    let (mut client_rings, mut server_rings) = RingModel::pair();

    let mut config = Config::new(HardwareAddress::Ethernet(CLIENT_MAC));
    config.random_seed = 0x1234_5678;
    let mut dev = RingDevice::new(&mut client_rings);
    let mut now = Instant::from_millis(0);
    let mut iface = Interface::new(config, &mut dev, now);

    let mut sockets = SocketSet::new(vec![]);
    let dhcp_socket = dhcpv4::Socket::new();
    let dhcp_handle = sockets.add(dhcp_socket);

    let mut rx_meta = [udp::PacketMetadata::EMPTY; 4];
    let mut rx_buf = [0u8; 4096];
    let mut tx_meta = [udp::PacketMetadata::EMPTY; 4];
    let mut tx_buf = [0u8; 4096];
    let udp_socket = udp::Socket::new(
        udp::PacketBuffer::new(&mut rx_meta[..], &mut rx_buf[..]),
        udp::PacketBuffer::new(&mut tx_meta[..], &mut tx_buf[..]),
    );
    let udp_handle = sockets.add(udp_socket);

    // --- DHCP: poll both ends until the client has an IP address ---
    let mut configured = false;
    let mut sntp_sent = false;
    let mut sntp_client: Option<SntpClient> = None;
    let mut got_reply = false;

    for step in 0..2000u32 {
        now = Instant::from_millis(step as i64);
        main_step(&mut iface, &mut dev, &mut sockets, now);
        server_step(&mut server_rings);
        main_step(&mut iface, &mut dev, &mut sockets, now); // let the client see the server's reply

        if !configured {
            let event = sockets.get_mut::<dhcpv4::Socket>(dhcp_handle).poll();
            if let Some(dhcpv4::Event::Configured(cfg)) = event {
                iface.update_ip_addrs(|addrs| {
                    addrs.clear();
                    addrs.push(IpCidr::Ipv4(cfg.address)).unwrap();
                });
                if let Some(router) = cfg.router {
                    iface.routes_mut().add_default_ipv4_route(router).unwrap();
                }
                configured = true;
            }
        } else if !sntp_sent {
            let socket = sockets.get_mut::<udp::Socket>(udp_handle);
            if !socket.is_open() {
                socket.bind(sntp::NTP_PORT).unwrap();
            }
            let (client, req) = SntpClient::request((now.total_millis() as u64) * 1000);
            if socket.can_send()
                && socket
                    .send_slice(&req, (IpAddress::Ipv4(SERVER_IP), sntp::NTP_PORT))
                    .is_ok()
            {
                sntp_client = Some(client);
                sntp_sent = true;
            }
        } else if !got_reply {
            server_step(&mut server_rings);
            main_step(&mut iface, &mut dev, &mut sockets, now);
            let socket = sockets.get_mut::<udp::Socket>(udp_handle);
            if socket.can_recv() {
                let (data, _endpoint) = socket.recv().unwrap();
                let now_mono_us = (now.total_millis() as u64) * 1000;
                if let Some(corr) = sntp_client.unwrap().on_reply(data, now_mono_us) {
                    let mut clk = tr_net::clock::DisciplinedClock::new();
                    clk.apply(corr);
                    struct FixedMono(u64);
                    impl tr_net::clock::MonotonicUs for FixedMono {
                        fn now_us(&self) -> u64 {
                            self.0
                        }
                    }
                    let got = clk.now_utc_us(&FixedMono(now_mono_us));
                    assert!(
                        (got - SERVED_UTC_US).abs() <= 1_000,
                        "disciplined UTC {got} not within 1 ms of served {SERVED_UTC_US}"
                    );
                    got_reply = true;
                }
            }
        } else {
            break;
        }
    }

    assert!(configured, "DHCP never completed");
    assert!(sntp_sent, "SNTP request was never sent");
    assert!(got_reply, "SNTP reply was never processed / time was never set");
}

/// The same exchange through `tr_net::nettime::NetTime`, the object the firmware polls: address by
/// DHCP, the router asked for the time, the clock set, and its age reported once the link is gone.
#[test]
fn nettime_sets_the_clock_and_keeps_it_without_a_link() {
    use tr_net::nettime::{NetStore, NetTime, TimeState};
    let (mut client_rings, mut server_rings) = RingModel::pair();
    let mut store = NetStore::new();
    let mut nt = NetTime::new(&mut store, &mut client_rings, CLIENT_MAC.0, 0);
    assert_eq!(nt.state(0), TimeState::NoNetwork);
    assert_eq!(nt.utc_us(0), None);
    let mut t = 0u64;
    for step in 0..8000u64 {
        t = step * 1000;
        nt.poll(&mut client_rings, true, t);
        while server_step(&mut server_rings) {}
        nt.poll(&mut client_rings, true, t);
        if matches!(nt.state(t), TimeState::Synced { .. }) {
            break;
        }
    }
    assert_eq!(nt.address(), Some(OFFERED_IP.0));
    assert!(matches!(nt.state(t), TimeState::Synced { age_s: 0 }), "state {:?} after {} ms", nt.state(t), t / 1000);
    let utc = nt.utc_us(t).unwrap();
    assert!((utc - SERVED_UTC_US).abs() <= 2_000, "UTC {utc}, served {SERVED_UTC_US}");
    assert_eq!((nt.queries, nt.answers), (1, 1));
    // the link goes away: the clock runs on, and says how old its setting is
    nt.poll(&mut client_rings, false, t + 7_000_000);
    assert_eq!(nt.state(t + 7_000_000), TimeState::Synced { age_s: 7 });
    assert_eq!(nt.utc_us(t + 7_000_000), Some(utc + 7_000_000));
}

/// Reads what the server model receives, answers ARP, and returns the payloads of UDP datagrams sent to `port`.
fn drain_udp_to(server_rings: &mut RingModel, port: u16) -> Vec<(u16, Vec<u8>)> {
    use tr_net::rings::MacRings;
    let mut out = Vec::new();
    let mut buf = [0u8; 1514];
    while let Some(len) = server_rings.receive(&mut buf) {
        let Ok(eth) = EthernetFrame::new_checked(&buf[..len]) else { continue };
        if eth.ethertype() == EthernetProtocol::Arp {
            handle_arp(server_rings, eth.payload());
        } else if eth.ethertype() == EthernetProtocol::Ipv4 {
            let Ok(ip) = Ipv4Packet::new_checked(eth.payload()) else { continue };
            if ip.next_header() != IpProtocol::Udp {
                continue;
            }
            let Ok(udp) = UdpPacket::new_checked(ip.payload()) else { continue };
            if udp.dst_port() == port {
                out.push((udp.src_port(), udp.payload().to_vec()));
            }
        }
    }
    out
}

/// The service socket (the PC's mouse and keyboard, docs/NETINPUT.md): it opens once DHCP has given an address, takes a
/// unicast and a broadcast datagram for its port, reports sender and true length, and sends an answer to the sender.
#[test]
fn service_socket_takes_unicast_and_broadcast_and_answers() {
    use tr_net::nettime::{NetStore, NetTime};
    const PORT: u16 = 21600;
    const PC_PORT: u16 = 50_000;
    let (mut client_rings, mut server_rings) = RingModel::pair();
    let mut store = NetStore::new();
    let mut nt = NetTime::new(&mut store, &mut client_rings, CLIENT_MAC.0, 0);
    nt.set_service_port(Some(PORT));
    let mut buf = [0u8; 64];
    assert_eq!(nt.service_recv(&mut buf), None, "nothing before the address");
    assert!(!nt.service_send([1, 2, 3, 4], 5, b"x"), "no socket before the address");
    let mut t = 0u64;
    for step in 0..8000u64 {
        t = step * 1000;
        nt.poll(&mut client_rings, true, t);
        server_step(&mut server_rings);
        nt.poll(&mut client_rings, true, t);
        if nt.address().is_some() {
            break;
        }
    }
    assert_eq!(nt.address(), Some(OFFERED_IP.0));
    t += 1000;
    nt.poll(&mut client_rings, true, t); // opens the socket
    // a unicast datagram, a broadcast one, and one longer than the caller's buffer
    send_udp_frame(&mut server_rings, OFFERED_IP, PORT, PC_PORT, b"unicast");
    send_udp_frame(&mut server_rings, Ipv4Address::BROADCAST, PORT, PC_PORT, b"broadcast");
    send_udp_frame(&mut server_rings, OFFERED_IP, PORT, PC_PORT, &[7u8; 100]);
    // and one for another port, which the service must not see
    send_udp_frame(&mut server_rings, OFFERED_IP, 9, PC_PORT, b"other");
    t += 1000;
    nt.poll(&mut client_rings, true, t);
    let (n, ip, port) = nt.service_recv(&mut buf).expect("unicast");
    assert_eq!((&buf[..n], ip, port), (&b"unicast"[..], SERVER_IP.0, PC_PORT));
    let (n, ip, port) = nt.service_recv(&mut buf).expect("broadcast");
    assert_eq!((&buf[..n], ip, port), (&b"broadcast"[..], SERVER_IP.0, PC_PORT));
    let (n, _, _) = nt.service_recv(&mut buf).expect("long one");
    assert_eq!(n, 100, "the true length is reported even though the buffer holds 64");
    assert_eq!(nt.service_recv(&mut buf), None);
    // the answer goes to the sender's port, from the service port
    assert!(nt.service_send(SERVER_IP.0, PC_PORT, b"status"));
    let mut got = Vec::new();
    for _ in 0..50 {
        t += 1000;
        nt.poll(&mut client_rings, true, t);
        got.extend(drain_udp_to(&mut server_rings, PC_PORT));
        if !got.is_empty() {
            break;
        }
    }
    assert_eq!(got, [(PORT, b"status".to_vec())]);
}
