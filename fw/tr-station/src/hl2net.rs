// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The little networking the HL2 link needs, on whole Ethernet frames (destination MAC to last
//! payload byte, no FCS, as the packet path carries them): UDP over IPv4 without options, and ARP
//! for our own address. The link is one cable with one device on it; there is no routing, no
//! fragmentation and no TCP. The HL2 checks no checksum (PROTOCOL section 1); ours are right anyway.

/// Ethernet broadcast address.
pub const BROADCAST_MAC: [u8; 6] = [0xFF; 6];
/// IPv4 limited broadcast address, used before the HL2 has an address we know.
pub const BROADCAST_IP: [u8; 4] = [255; 4];
/// Ethernet + IPv4 + UDP headers.
pub const UDP_HEADERS: usize = 14 + 20 + 8;
/// Longest frame built or accepted.
pub const MAX_FRAME: usize = 1_514;

const ETHERTYPE_IPV4: [u8; 2] = [0x08, 0x00];
const ETHERTYPE_ARP: [u8; 2] = [0x08, 0x06];

/// Our end of the link.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Endpoint {
    /// Ethernet address.
    pub mac: [u8; 6],
    /// IPv4 address.
    pub ip: [u8; 4],
}

/// One's-complement sum of big-endian 16-bit words, folded.
pub fn checksum(parts: &[&[u8]]) -> u16 {
    let mut sum = 0u32;
    for p in parts {
        let mut i = 0;
        while i + 1 < p.len() {
            sum += u16::from_be_bytes([p[i], p[i + 1]]) as u32;
            i += 2;
        }
        if i < p.len() {
            sum += (p[i] as u32) << 8;
        }
    }
    while sum >> 16 != 0 {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    !(sum as u16)
}

/// Builds a UDP datagram into `frame` and returns the frame length, `None` if it does not fit.
pub fn build_udp(frame: &mut [u8], from: &Endpoint, src_port: u16, dst_mac: [u8; 6], dst_ip: [u8; 4], dst_port: u16, payload: &[u8]) -> Option<usize> {
    let len = UDP_HEADERS + payload.len();
    if len > frame.len() || len > MAX_FRAME {
        return None;
    }
    frame[0..6].copy_from_slice(&dst_mac);
    frame[6..12].copy_from_slice(&from.mac);
    frame[12..14].copy_from_slice(&ETHERTYPE_IPV4);
    // IPv4 header: version 4, length 5 words, don't-fragment, TTL 64, protocol 17 (UDP).
    let ip_len = (20 + 8 + payload.len()) as u16;
    let ip = &mut frame[14..34];
    ip.copy_from_slice(&[0x45, 0, 0, 0, 0, 0, 0x40, 0, 64, 17, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    ip[2..4].copy_from_slice(&ip_len.to_be_bytes());
    ip[12..16].copy_from_slice(&from.ip);
    ip[16..20].copy_from_slice(&dst_ip);
    let c = checksum(&[&frame[14..34]]);
    frame[24..26].copy_from_slice(&c.to_be_bytes());
    let udp_len = (8 + payload.len()) as u16;
    frame[34..36].copy_from_slice(&src_port.to_be_bytes());
    frame[36..38].copy_from_slice(&dst_port.to_be_bytes());
    frame[38..40].copy_from_slice(&udp_len.to_be_bytes());
    frame[40..42].copy_from_slice(&[0, 0]);
    frame[42..len].copy_from_slice(payload);
    // The UDP checksum covers a pseudo header (addresses, protocol, length) and the datagram; a result of 0 is sent as 0xFFFF.
    let pseudo = [from.ip[0], from.ip[1], from.ip[2], from.ip[3], dst_ip[0], dst_ip[1], dst_ip[2], dst_ip[3], 0, 17, (udp_len >> 8) as u8, udp_len as u8];
    let c = match checksum(&[&pseudo, &frame[34..len]]) {
        0 => 0xFFFF,
        c => c,
    };
    frame[40..42].copy_from_slice(&c.to_be_bytes());
    Some(len)
}

/// A received frame, as far as the session cares.
#[derive(Debug, PartialEq, Eq)]
pub enum Rx<'a> {
    /// A UDP datagram; `payload` is bounded by the UDP length, so MAC padding is not part of it.
    Udp { src_mac: [u8; 6], src_ip: [u8; 4], src_port: u16, dst_port: u16, payload: &'a [u8] },
    /// Someone asks for the MAC of `target_ip`.
    ArpRequest { sender_mac: [u8; 6], sender_ip: [u8; 4], target_ip: [u8; 4] },
    /// Anything else: other protocols, IP options, truncated frames.
    Other,
}

fn arr<const N: usize>(b: &[u8]) -> [u8; N] {
    let mut a = [0u8; N];
    a.copy_from_slice(&b[..N]);
    a
}

/// Sorts a received frame into UDP, ARP request or other. Frames shorter than 42 bytes (the ARP size) are `Other`.
pub fn parse(frame: &[u8]) -> Rx<'_> {
    if frame.len() < 42 {
        return Rx::Other;
    }
    if frame[12..14] == ETHERTYPE_ARP {
        // Ethernet/IPv4 ARP request
        if frame[14..22] == [0, 1, 8, 0, 6, 4, 0, 1] {
            return Rx::ArpRequest { sender_mac: arr(&frame[22..28]), sender_ip: arr(&frame[28..32]), target_ip: arr(&frame[38..42]) };
        }
        return Rx::Other;
    }
    if frame[12..14] != ETHERTYPE_IPV4 || frame[14] != 0x45 || frame[23] != 17 {
        return Rx::Other;
    }
    let udp_len = u16::from_be_bytes([frame[38], frame[39]]) as usize;
    if udp_len < 8 || 34 + udp_len > frame.len() {
        return Rx::Other;
    }
    Rx::Udp {
        src_mac: arr(&frame[6..12]),
        src_ip: arr(&frame[26..30]),
        src_port: u16::from_be_bytes([frame[34], frame[35]]),
        dst_port: u16::from_be_bytes([frame[36], frame[37]]),
        payload: &frame[42..34 + udp_len],
    }
}

/// The ARP reply "`from.ip` is at `from.mac`" to whoever asked. 42 bytes.
pub fn build_arp_reply(frame: &mut [u8], from: &Endpoint, asker_mac: [u8; 6], asker_ip: [u8; 4]) -> usize {
    frame[0..6].copy_from_slice(&asker_mac);
    frame[6..12].copy_from_slice(&from.mac);
    frame[12..14].copy_from_slice(&ETHERTYPE_ARP);
    frame[14..22].copy_from_slice(&[0, 1, 8, 0, 6, 4, 0, 2]);
    frame[22..28].copy_from_slice(&from.mac);
    frame[28..32].copy_from_slice(&from.ip);
    frame[32..38].copy_from_slice(&asker_mac);
    frame[38..42].copy_from_slice(&asker_ip);
    42
}

#[cfg(test)]
mod tests {
    use super::*;

    const US: Endpoint = Endpoint { mac: [2, 0x54, 0x52, 0, 0, 1], ip: [10, 99, 0, 1] };

    #[test]
    fn udp_round_trip_with_valid_checksums() {
        let mut f = [0u8; 128];
        let n = build_udp(&mut f, &US, 51_000, [0, 0x1C, 0xC0, 1, 2, 3], [10, 99, 0, 2], 1_025, &[0xEF, 0xFE, 2]).unwrap();
        assert_eq!(n, 45);
        // A checksum over data that includes its own checksum is 0.
        assert_eq!(checksum(&[&f[14..34]]), 0);
        let pseudo = [10, 99, 0, 1, 10, 99, 0, 2, 0, 17, 0, 11];
        assert_eq!(checksum(&[&pseudo, &f[34..n]]), 0);
        assert_eq!(parse(&f[..n]), Rx::Udp { src_mac: US.mac, src_ip: US.ip, src_port: 51_000, dst_port: 1_025, payload: &[0xEF, 0xFE, 2] });
        // Padded to the Ethernet minimum by the MAC: the UDP length still bounds the payload.
        assert_eq!(parse(&f[..60]), Rx::Udp { src_mac: US.mac, src_ip: US.ip, src_port: 51_000, dst_port: 1_025, payload: &[0xEF, 0xFE, 2] });
        assert!(build_udp(&mut [0u8; 44], &US, 1, [0; 6], [0; 4], 2, &[0; 3]).is_none());
    }

    #[test]
    fn arp() {
        let mut req = [0u8; 60];
        req[0..6].copy_from_slice(&BROADCAST_MAC);
        req[6..12].copy_from_slice(&[0, 0x1C, 0xC0, 1, 2, 3]);
        req[12..22].copy_from_slice(&[8, 6, 0, 1, 8, 0, 6, 4, 0, 1]);
        req[22..28].copy_from_slice(&[0, 0x1C, 0xC0, 1, 2, 3]);
        req[28..32].copy_from_slice(&[10, 99, 0, 2]);
        req[38..42].copy_from_slice(&US.ip);
        assert_eq!(parse(&req), Rx::ArpRequest { sender_mac: [0, 0x1C, 0xC0, 1, 2, 3], sender_ip: [10, 99, 0, 2], target_ip: US.ip });
        let mut rep = [0u8; 60];
        assert_eq!(build_arp_reply(&mut rep, &US, [0, 0x1C, 0xC0, 1, 2, 3], [10, 99, 0, 2]), 42);
        assert_eq!(rep[20..22], [0, 2]);
        assert_eq!(rep[22..28], US.mac);
        assert_eq!(rep[38..42], [10, 99, 0, 2]);
        assert_eq!(parse(&[0u8; 20]), Rx::Other);
    }
}
