// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Minimal DHCP server for the HL2 link (`docs/ARCHITECTURE.md` section 3.1): the firmware runs
//! it so that the HL2 gets an address within a second of power-up (by default 10.99.0.1 for the
//! Tang and 10.99.0.2 for the HL2) instead of waiting about 15 s for a link-local address.
//!
//! It hands out one fixed lease to one client, since the HL2 is the only other device on this
//! link: a DISCOVER gets an OFFER of the configured address, a REQUEST for that address gets an
//! ACK, and anything else (a different requested address, or a message type this server does not
//! handle) is ignored. Nothing is allocated and there is no clock. The lease time is a fixed value
//! written into every reply, and expiry is not tracked, because on a point-to-point link there is
//! nobody else to give the address to.
//!
//! This is a server-side subset of RFC 2131 and RFC 2132 (the BOOTP header and the options 1, 3,
//! 51, 53, 54 and 55) and not a general DHCP implementation: there is no relay agent support, no
//! second pool and no handling of declines.
//!
//! The module is `no_std`: parsing and building work in buffers that the caller supplies.

/// Fixed BOOTP header length, before the options area (RFC 2131 section 2).
pub const HEADER_LEN: usize = 236;
pub const MAGIC_COOKIE: [u8; 4] = [99, 130, 83, 99];

const OP_BOOTREQUEST: u8 = 1;
const OP_BOOTREPLY: u8 = 2;
const HTYPE_ETHERNET: u8 = 1;
const HLEN_ETHERNET: u8 = 6;

pub const PORT_SERVER: u16 = 67;
pub const PORT_CLIENT: u16 = 68;

// ---- DHCP option codes (RFC 2132) ----------------------------------------------------------
const OPT_PAD: u8 = 0;
const OPT_SUBNET_MASK: u8 = 1;
/// Not sent by this minimal server (the HL2 needs no gateway on this point-to-point link); kept
/// for documentation and for a future server that adds it.
#[allow(dead_code)]
const OPT_ROUTER: u8 = 3;
const OPT_REQUESTED_IP: u8 = 50;
const OPT_LEASE_TIME: u8 = 51;
const OPT_MSG_TYPE: u8 = 53;
const OPT_SERVER_ID: u8 = 54;
const OPT_END: u8 = 255;

/// DHCP message type (option 53).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MsgType {
    Discover,
    Offer,
    Request,
    Decline,
    Ack,
    Nak,
    Release,
    Inform,
}

impl MsgType {
    fn from_u8(v: u8) -> Option<MsgType> {
        Some(match v {
            1 => MsgType::Discover,
            2 => MsgType::Offer,
            3 => MsgType::Request,
            4 => MsgType::Decline,
            5 => MsgType::Ack,
            6 => MsgType::Nak,
            7 => MsgType::Release,
            8 => MsgType::Inform,
            _ => return None,
        })
    }
    fn to_u8(self) -> u8 {
        match self {
            MsgType::Discover => 1,
            MsgType::Offer => 2,
            MsgType::Request => 3,
            MsgType::Decline => 4,
            MsgType::Ack => 5,
            MsgType::Nak => 6,
            MsgType::Release => 7,
            MsgType::Inform => 8,
        }
    }
}

/// A parsed client request (DISCOVER, REQUEST, ...); only the fields this server needs.
#[derive(Debug, Clone, Copy)]
pub struct Request {
    pub xid: u32,
    pub chaddr: [u8; 6],
    pub msg_type: MsgType,
    /// Option 50 (requested IP), if the client sent one.
    pub requested_ip: Option<[u8; 4]>,
    /// The `ciaddr` field (client's current IP, set on a renewing REQUEST; 0.0.0.0 otherwise).
    pub ciaddr: [u8; 4],
}

/// Parse a BOOTREQUEST packet. Returns `None` if it's too short, not a BOOTREQUEST/Ethernet
/// packet, has no magic cookie, or carries no recognized message-type option.
pub fn parse_request(buf: &[u8]) -> Option<Request> {
    if buf.len() < HEADER_LEN + 4 {
        return None;
    }
    if buf[0] != OP_BOOTREQUEST || buf[1] != HTYPE_ETHERNET || buf[2] != HLEN_ETHERNET {
        return None;
    }
    let xid = u32::from_be_bytes([buf[4], buf[5], buf[6], buf[7]]);
    let mut ciaddr = [0u8; 4];
    ciaddr.copy_from_slice(&buf[12..16]);
    let mut chaddr = [0u8; 6];
    chaddr.copy_from_slice(&buf[28..34]);
    if buf[236..240] != MAGIC_COOKIE {
        return None;
    }

    let mut msg_type = None;
    let mut requested_ip = None;
    let mut i = 240;
    while i < buf.len() {
        let code = buf[i];
        if code == OPT_END {
            break;
        }
        if code == OPT_PAD {
            i += 1;
            continue;
        }
        if i + 1 >= buf.len() {
            break;
        }
        let len = buf[i + 1] as usize;
        let start = i + 2;
        if start + len > buf.len() {
            break;
        }
        let data = &buf[start..start + len];
        match code {
            OPT_MSG_TYPE if len == 1 => msg_type = MsgType::from_u8(data[0]),
            OPT_REQUESTED_IP if len == 4 => {
                let mut ip = [0u8; 4];
                ip.copy_from_slice(data);
                requested_ip = Some(ip);
            }
            _ => {}
        }
        i = start + len;
    }

    Some(Request { xid, chaddr, msg_type: msg_type?, requested_ip, ciaddr })
}

/// Build a reply (OFFER or ACK) into `out`. Returns the packet length, or `None` if `out` is
/// too small.
#[allow(clippy::too_many_arguments)]
fn build_reply(
    msg_type: MsgType,
    xid: u32,
    chaddr: [u8; 6],
    your_ip: [u8; 4],
    server_ip: [u8; 4],
    subnet_mask: [u8; 4],
    lease_secs: u32,
    out: &mut [u8],
) -> Option<usize> {
    const OPTIONS_LEN: usize = 3 + 6 + 6 + 6 + 1; // msg-type, server-id, lease-time, subnet-mask, end
    let total = HEADER_LEN + 4 + OPTIONS_LEN;
    if out.len() < total {
        return None;
    }
    for b in out[..total].iter_mut() {
        *b = 0;
    }
    out[0] = OP_BOOTREPLY;
    out[1] = HTYPE_ETHERNET;
    out[2] = HLEN_ETHERNET;
    out[4..8].copy_from_slice(&xid.to_be_bytes());
    out[16..20].copy_from_slice(&your_ip);
    out[28..34].copy_from_slice(&chaddr);
    out[236..240].copy_from_slice(&MAGIC_COOKIE);

    let mut p = 240;
    out[p] = OPT_MSG_TYPE;
    out[p + 1] = 1;
    out[p + 2] = msg_type.to_u8();
    p += 3;
    out[p] = OPT_SERVER_ID;
    out[p + 1] = 4;
    out[p + 2..p + 6].copy_from_slice(&server_ip);
    p += 6;
    out[p] = OPT_LEASE_TIME;
    out[p + 1] = 4;
    out[p + 2..p + 6].copy_from_slice(&lease_secs.to_be_bytes());
    p += 6;
    out[p] = OPT_SUBNET_MASK;
    out[p + 1] = 4;
    out[p + 2..p + 6].copy_from_slice(&subnet_mask);
    p += 6;
    out[p] = OPT_END;
    p += 1;
    Some(p)
}

/// One fixed lease, offered to whichever client asks first, because this link has exactly one
/// other device, the HL2.
pub struct DhcpServer {
    pub server_ip: [u8; 4],
    pub offer_ip: [u8; 4],
    pub subnet_mask: [u8; 4],
    pub lease_secs: u32,
}

impl DhcpServer {
    /// Default addressing from ARCHITECTURE.md section 3.1: Tang 10.99.0.1, HL2 10.99.0.2.
    pub const fn default_addressing() -> DhcpServer {
        DhcpServer {
            server_ip: [10, 99, 0, 1],
            offer_ip: [10, 99, 0, 2],
            subnet_mask: [255, 255, 255, 0],
            lease_secs: 3600,
        }
    }

    /// Handle one client packet, writing a reply into `out` if one is due. Returns the reply
    /// length, or `None` if the packet didn't parse or needs no reply from this server (a
    /// REQUEST for a different address is silently ignored, per RFC 2131, another server, if
    /// one existed on this link, would answer instead; on the point-to-point HL2 link there is
    /// none, so an ignored REQUEST simply gets no reply and the client times out and retries).
    pub fn handle(&self, request: &[u8], out: &mut [u8]) -> Option<usize> {
        let req = parse_request(request)?;
        match req.msg_type {
            MsgType::Discover => {
                build_reply(MsgType::Offer, req.xid, req.chaddr, self.offer_ip, self.server_ip, self.subnet_mask, self.lease_secs, out)
            }
            MsgType::Request => {
                let wants = req.requested_ip.or(if req.ciaddr != [0, 0, 0, 0] { Some(req.ciaddr) } else { None });
                if wants == Some(self.offer_ip) {
                    build_reply(MsgType::Ack, req.xid, req.chaddr, self.offer_ip, self.server_ip, self.subnet_mask, self.lease_secs, out)
                } else {
                    None
                }
            }
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn build_request(msg_type: MsgType, xid: u32, chaddr: [u8; 6], requested_ip: Option<[u8; 4]>, ciaddr: [u8; 4]) -> [u8; 260] {
        let mut buf = [0u8; 260];
        buf[0] = OP_BOOTREQUEST;
        buf[1] = HTYPE_ETHERNET;
        buf[2] = HLEN_ETHERNET;
        buf[4..8].copy_from_slice(&xid.to_be_bytes());
        buf[12..16].copy_from_slice(&ciaddr);
        buf[28..34].copy_from_slice(&chaddr);
        buf[236..240].copy_from_slice(&MAGIC_COOKIE);
        let mut p = 240;
        buf[p] = OPT_MSG_TYPE;
        buf[p + 1] = 1;
        buf[p + 2] = msg_type.to_u8();
        p += 3;
        if let Some(ip) = requested_ip {
            buf[p] = OPT_REQUESTED_IP;
            buf[p + 1] = 4;
            buf[p + 2..p + 6].copy_from_slice(&ip);
            p += 6;
        }
        buf[p] = OPT_END;
        buf
    }

    #[test]
    fn discover_gets_offer() {
        let server = DhcpServer::default_addressing();
        let chaddr = [0x00, 0x1c, 0xc0, 0x01, 0x02, 0x03];
        let req = build_request(MsgType::Discover, 0x1234_5678, chaddr, None, [0, 0, 0, 0]);
        let mut out = [0u8; 300];
        let n = server.handle(&req, &mut out).expect("offer expected");
        assert_eq!(out[0], OP_BOOTREPLY);
        assert_eq!(&out[4..8], &0x1234_5678u32.to_be_bytes());
        assert_eq!(&out[16..20], &server.offer_ip);
        assert_eq!(&out[28..34], &chaddr);
        // parse the option area back out
        let parsed_offer = &out[..n];
        assert_eq!(find_opt(parsed_offer, OPT_MSG_TYPE), Some(&[MsgType::Offer.to_u8()][..]));
        assert_eq!(find_opt(parsed_offer, OPT_SERVER_ID), Some(&server.server_ip[..]));
        assert_eq!(find_opt(parsed_offer, OPT_SUBNET_MASK), Some(&server.subnet_mask[..]));
    }

    #[test]
    fn request_for_offered_address_gets_ack() {
        let server = DhcpServer::default_addressing();
        let chaddr = [1, 2, 3, 4, 5, 6];
        let req = build_request(MsgType::Request, 42, chaddr, Some(server.offer_ip), [0, 0, 0, 0]);
        let mut out = [0u8; 300];
        let n = server.handle(&req, &mut out).expect("ack expected");
        assert_eq!(find_opt(&out[..n], OPT_MSG_TYPE), Some(&[MsgType::Ack.to_u8()][..]));
        assert_eq!(&out[16..20], &server.offer_ip);
    }

    #[test]
    fn request_for_a_different_address_is_ignored() {
        let server = DhcpServer::default_addressing();
        let req = build_request(MsgType::Request, 42, [1, 2, 3, 4, 5, 6], Some([10, 99, 0, 99]), [0, 0, 0, 0]);
        let mut out = [0u8; 300];
        assert!(server.handle(&req, &mut out).is_none());
    }

    #[test]
    fn renewing_request_uses_ciaddr() {
        let server = DhcpServer::default_addressing();
        let req = build_request(MsgType::Request, 7, [1, 2, 3, 4, 5, 6], None, server.offer_ip);
        let mut out = [0u8; 300];
        let n = server.handle(&req, &mut out).expect("ack expected");
        assert_eq!(find_opt(&out[..n], OPT_MSG_TYPE), Some(&[MsgType::Ack.to_u8()][..]));
    }

    #[test]
    fn malformed_packet_is_rejected() {
        assert!(parse_request(&[0u8; 10]).is_none());
        let mut bad_cookie = [0u8; 260];
        bad_cookie[0] = OP_BOOTREQUEST;
        bad_cookie[1] = HTYPE_ETHERNET;
        bad_cookie[2] = HLEN_ETHERNET;
        assert!(parse_request(&bad_cookie).is_none());
    }

    /// Test helper: find option `code`'s data in a built packet's option area.
    fn find_opt(buf: &[u8], code: u8) -> Option<&[u8]> {
        let mut i = 240;
        while i < buf.len() {
            let c = buf[i];
            if c == OPT_END {
                return None;
            }
            if c == OPT_PAD {
                i += 1;
                continue;
            }
            let len = buf[i + 1] as usize;
            let data = &buf[i + 2..i + 2 + len];
            if c == code {
                return Some(data);
            }
            i += 2 + len;
        }
        None
    }
}
