// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Board identity (docs/NET_ID.md): the chip's factory ID (the 64-bit DNA in Gowin's one-time-programmable memory,
//! read through the network unit's register page) gives the Ethernet address and the network name.
//!
//! The two derivations (`mac_from_dna` and `host_name`) are fixed, so one board always has the same address and the same
//! `tang-xxxxxx.local` name. Only a stored setting changes that. This module has no flash chip number and
//! no fixed address of its own, since the fixed address of this board is the fallback the caller passes in.

/// Where the address came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Source {
    /// Stored on the board by the operator.
    Setting,
    /// From the FPGA's factory ID.
    Dna,
    /// Neither: the fallback the caller gave, the same on every board. Two such boards on one network collide.
    Fallback,
}

/// The Ethernet address for a 64-bit chip ID: the byte 0x02 (locally administered, unicast) followed by 40 bits of a hash
/// of the ID. The hash is FNV-1a over the ID's eight bytes, low byte first, followed by `h ^= h >> 29`. The ID never
/// changes on a chip, so neither does the address.
pub fn mac_from_dna(dna: u64) -> [u8; 6] {
    let mut h: u64 = 0xCBF2_9CE4_8422_2325;
    for b in dna.to_le_bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01B3);
    }
    h ^= h >> 29;
    let x = h & 0xFF_FFFF_FFFF;
    [0x02, (x >> 32) as u8, (x >> 24) as u8, (x >> 16) as u8, (x >> 8) as u8, x as u8]
}

/// The name on the network without ".local": "tang-" and the last three bytes of the address as six lower-case hex digits.
pub fn host_name(mac: [u8; 6]) -> [u8; 11] {
    let mut h = *b"tang-000000";
    for (i, b) in mac[3..].iter().enumerate() {
        h[5 + 2 * i] = b"0123456789abcdef"[(b >> 4) as usize];
        h[6 + 2 * i] = b"0123456789abcdef"[(b & 15) as usize];
    }
    h
}

/// Whether an address may be stored as a setting: it must be for one station (bit 0 of the first byte clear) and not all zero.
pub fn valid_setting(m: &[u8; 6]) -> bool {
    m[0] & 1 == 0 && m.iter().any(|b| *b != 0)
}

/// Picks the address in this order: a stored setting, the address from the FPGA's ID (an ID of 0 or all ones means the reader
/// is missing or read nothing, so it is skipped), then the fallback. Also returns which of the three it used.
pub fn choose(setting: Option<[u8; 6]>, dna: Option<u64>, fallback: [u8; 6]) -> ([u8; 6], Source) {
    if let Some(m) = setting.filter(valid_setting) {
        return (m, Source::Setting);
    }
    if let Some(d) = dna.filter(|d| *d != 0 && *d != u64::MAX) {
        return (mac_from_dna(d), Source::Dna);
    }
    (fallback, Source::Fallback)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An example ID (the pattern of the simulation's OTP model). The expected values were produced by an independent
    /// implementation of the two derivations, so they are the reference and not worked out again here.
    const BOARD_ID: u64 = 0x0123_4567_89AB_CDEF;

    #[test]
    fn the_example_id_gets_the_expected_address_and_name() {
        let mac = mac_from_dna(BOARD_ID);
        assert_eq!(mac, [0x02, 0x32, 0xF8, 0x2F, 0xE5, 0xCF]);
        assert_eq!(&host_name(mac), b"tang-2fe5cf");
    }

    #[test]
    fn another_id_gets_the_expected_address() {
        assert_eq!(mac_from_dna(0xDEAD_BEEF_0123_4567), [0x02, 0x9E, 0xE1, 0xC8, 0xF6, 0xA6]);
    }

    #[test]
    fn the_address_is_stable_unicast_and_local() {
        let a = mac_from_dna(BOARD_ID);
        assert_eq!(a, mac_from_dna(BOARD_ID));
        assert_ne!(a, mac_from_dna(BOARD_ID ^ 1));
        assert_eq!(a[0] & 3, 2, "locally administered, unicast");
    }

    #[test]
    fn a_stored_setting_wins_then_the_id_then_the_fallback() {
        let fb = [0x02, 0x54, 0x52, 0, 0, 2];
        let set = [0x02, 1, 1, 1, 1, 1];
        assert_eq!(choose(Some(set), Some(BOARD_ID), fb), (set, Source::Setting));
        assert_eq!(choose(None, Some(BOARD_ID), fb), (mac_from_dna(BOARD_ID), Source::Dna));
        // a setting for a group address or all zero is not taken
        assert_eq!(choose(Some([1, 2, 3, 4, 5, 6]), Some(BOARD_ID), fb).1, Source::Dna);
        assert_eq!(choose(Some([0; 6]), None, fb), (fb, Source::Fallback));
        // a reader that read nothing
        assert_eq!(choose(None, Some(0), fb), (fb, Source::Fallback));
        assert_eq!(choose(None, Some(u64::MAX), fb), (fb, Source::Fallback));
        assert_eq!(choose(None, None, fb), (fb, Source::Fallback));
    }
}
