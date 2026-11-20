// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! A minimal SNTP (RFC 4330 profile of NTPv4, RFC 5905 wire format) client: builds a 48-byte
//! mode-3 (client) request and turns a mode-4 (server) reply into a [`Correction`] with the
//! standard four-timestamp offset formula.
//!
//! This is deliberately not a full NTP client: there is no peer selection, no clock filter or
//! combining across several servers, and no root-dispersion sanity check. One request gives one
//! reply and one [`Correction`], which is enough for the UTC that FT8 needs to come from the
//! network (docs/DECISIONS.md), since WSJT-X itself gets by on a plain SNTP-disciplined system
//! clock. Keep in mind that a single sample has the accuracy of that one round trip, so a link
//! with very uneven delay in the two directions would show up as a constant time error.
//!
//! The wire format is the standard 64-bit NTP fixed-point timestamp (32 bits of seconds since
//! 1900-01-01 and a 32-bit fraction). [`encode_ntp`] and [`decode_ntp`] convert to and from
//! microseconds in that same 1900 epoch, and [`NTP_UNIX_EPOCH_OFFSET_US`] converts a
//! 1900-epoch microsecond value to the Unix epoch that [`crate::clock::DisciplinedClock`] uses.

use crate::clock::Correction;

/// Length of an SNTP packet without extension fields, in bytes.
pub const PACKET_LEN: usize = 48;
/// The UDP port NTP servers listen on.
pub const NTP_PORT: u16 = 123;

/// The span from the NTP epoch (1900-01-01) to the Unix epoch (1970-01-01), in microseconds.
pub const NTP_UNIX_EPOCH_OFFSET_US: i64 = 2_208_988_800 * 1_000_000;

/// Encodes a microsecond count as the 64-bit NTP fixed-point format. The epoch is whatever the
/// caller means: 1900 for a real NTP timestamp, or this client's own monotonic clock for the
/// request's Transmit Timestamp, which the server only echoes back without looking at it.
pub fn encode_ntp(us: u64) -> [u8; 8] {
    let secs = (us / 1_000_000) as u32;
    let frac_us = us % 1_000_000;
    // The fraction (0 to 2^32) is frac_us / 1_000_000 * 2^32, computed in u64 so that it cannot overflow.
    let frac = ((frac_us << 32) / 1_000_000) as u32;
    let mut out = [0u8; 8];
    out[0..4].copy_from_slice(&secs.to_be_bytes());
    out[4..8].copy_from_slice(&frac.to_be_bytes());
    out
}

/// Inverse of [`encode_ntp`].
pub fn decode_ntp(bytes: &[u8]) -> u64 {
    let secs = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
    let frac = u32::from_be_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]);
    let frac_us = ((frac as u64) * 1_000_000) >> 32;
    secs as u64 * 1_000_000 + frac_us
}

/// One request in flight. It remembers `t1`, this client's own monotonic microseconds at the
/// moment the request was sent, so that [`on_reply`](Self::on_reply) can pair it with the reply.
#[derive(Clone, Copy, Debug)]
pub struct SntpClient {
    t1_mono_us: u64,
}

impl SntpClient {
    /// Builds the 48-byte request packet to send. `now_mono_us` is this client's own monotonic
    /// clock (see [`crate::clock::MonotonicUs`]) at the moment of sending. It is not a real NTP
    /// timestamp, since the client has no UTC yet, but the server only echoes it back, so any
    /// stable value works. Using the client's own clock means that `t1` and `t4` below are
    /// directly comparable (same units, same epoch) with no extra state.
    pub fn request(now_mono_us: u64) -> (Self, [u8; PACKET_LEN]) {
        let mut pkt = [0u8; PACKET_LEN];
        pkt[0] = 0b00_100_011; // LI=0 (no warning), VN=4, Mode=3 (client)
        pkt[40..48].copy_from_slice(&encode_ntp(now_mono_us));
        (SntpClient { t1_mono_us: now_mono_us }, pkt)
    }

    /// Parses a reply (mode 4) received at `now_mono_us`, this client's monotonic clock at
    /// reception (`t4`). Returns `None` if `reply` is not a well-formed matching SNTP reply, which
    /// means it is too short, has the wrong mode, or has an Origin Timestamp that does not echo
    /// this request's `t1` (the anti-spoofing check of RFC 4330).
    pub fn on_reply(&self, reply: &[u8], now_mono_us: u64) -> Option<Correction> {
        if reply.len() < PACKET_LEN {
            return None;
        }
        let mode = reply[0] & 0x07;
        if mode != 4 {
            return None;
        }
        // Anti-spoofing check (RFC 4330): the reply must echo this request's own Transmit
        // Timestamp back as its Origin Timestamp. The comparison has a small tolerance because
        // encode_ntp and decode_ntp round-trip to within about 1 us (the precision of the 32-bit
        // NTP fraction) and not bit-exactly, so an honest echo can decode one microsecond off from
        // what was sent, and an exact comparison would reject every real reply.
        let origin = decode_ntp(&reply[24..32]);
        if origin.abs_diff(self.t1_mono_us) > 2 {
            return None;
        }
        let t1 = self.t1_mono_us as i128;
        let t2 = decode_ntp(&reply[32..40]) as i128; // server receive time, NTP (1900) epoch
        let t3 = decode_ntp(&reply[40..48]) as i128; // server transmit time, NTP (1900) epoch
        let t4 = now_mono_us as i128;

        // Standard NTP offset: server clock minus client clock, averaged over the round trip.
        // t1 and t4 are this client's monotonic microseconds (arbitrary epoch), t2 and t3 are the
        // server's real NTP-epoch microseconds, so subtracting across the two epochs folds the
        // epoch difference and the true offset into one number, which is what is wanted here.
        let offset_ntp_epoch_us = ((t2 - t1) + (t3 - t4)) / 2;
        let offset_unix_epoch_us = (offset_ntp_epoch_us - NTP_UNIX_EPOCH_OFFSET_US as i128) as i64;

        Some(Correction { mono_us: now_mono_us, utc_us: now_mono_us as i64 + offset_unix_epoch_us })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_decode_roundtrip_is_exact_to_the_microsecond() {
        for us in [0u64, 1, 999_999, 1_700_000_000_000_000, u32::MAX as u64 * 1_000_000 + 500_000] {
            let enc = encode_ntp(us);
            let dec = decode_ntp(&enc);
            assert!((dec as i64 - us as i64).abs() <= 1, "us={us} dec={dec}");
        }
    }

    #[test]
    fn request_then_matching_reply_recovers_the_server_offset() {
        let (client, req) = SntpClient::request(1_000_000); // t1 = 1 s of client uptime
        assert_eq!(req[0] & 0x07, 3);

        // Model server: real UTC (NTP epoch) is exactly 1_800_000_000 seconds since 1900. The
        // network delay is symmetric at 7.5 ms each way and the server takes 5 ms to answer, so
        // its receive time (T2) is 7.5 ms of client time after t1 and its reply arrives back at
        // the client (t4) 7.5 ms after it is sent (T3), for a 20 ms round trip in total.
        let server_now_ntp_us = 1_800_000_000u64 * 1_000_000;
        let t2 = server_now_ntp_us;
        let t3 = t2 + 5_000; // 5 ms server processing time
        let mut reply = [0u8; PACKET_LEN];
        reply[0] = 0b00_100_100; // Mode = 4 (server)
        reply[24..32].copy_from_slice(&req[40..48]); // echo Origin Timestamp = client's T1
        reply[32..40].copy_from_slice(&encode_ntp(t2));
        reply[40..48].copy_from_slice(&encode_ntp(t3));

        let t4_mono_us = 1_020_000u64; // client uptime 20 ms after t1: 7.5 + 5 + 7.5 ms
        let corr = client.on_reply(&reply, t4_mono_us).expect("reply should parse");

        // True UTC when the reply arrives (t4) is the server's transmit instant (T3) plus the
        // 7.5 ms return trip, because T3 is the server's clock reading 7.5 ms before the client
        // actually receives the reply.
        let true_utc_at_t4 = t3 as i64 - NTP_UNIX_EPOCH_OFFSET_US + 7_500;
        assert!((corr.utc_us - true_utc_at_t4).abs() <= 1_000, "corr={corr:?} true={true_utc_at_t4}");
    }

    #[test]
    fn reply_with_mismatched_origin_is_rejected() {
        let (client, req) = SntpClient::request(42);
        let mut reply = [0u8; PACKET_LEN];
        reply[0] = 0b00_100_100;
        reply[24..32].copy_from_slice(&encode_ntp(999)); // wrong origin
        let _ = req;
        assert!(client.on_reply(&reply, 1000).is_none());
    }
}
