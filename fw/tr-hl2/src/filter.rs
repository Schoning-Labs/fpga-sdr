// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! N2ADR filter board control through register 0x00 (`docs/ARCHITECTURE.md` section 8 and
//! `PROTOCOL.md` section 12). Bits 23 to 17 of the command register drive the MCP23008 I/O
//! expander (I2C address 0x20, bus 2) that switches the filter relays, and bit 13 selects the RX
//! antenna input.
//!
//! | Register bit | MCP23008 pin | Filter |
//! |---|---|---|
//! | 17 | GP0 | 160 m low-pass |
//! | 18 | GP1 | 80 m low-pass |
//! | 19 | GP2 | 60/40 m low-pass |
//! | 20 | GP3 | 30/20 m low-pass |
//! | 21 | GP4 | 17/15 m low-pass |
//! | 22 | GP5 | 12/10 m low-pass |
//! | 23 | GP6 | 3 MHz high-pass (receive) |
//! | 13 | GP7 | RX antenna select |

/// Register 0x00 bit for each MCP23008 pin GP0-GP6 (filter relays) and GP7 (RX antenna, bit 13
/// rather than 24, since it isn't part of the contiguous GP0-GP6 field).
pub const BIT_LPF_160M: u32 = 1 << 17; // GP0
pub const BIT_LPF_80M: u32 = 1 << 18; // GP1
pub const BIT_LPF_60_40M: u32 = 1 << 19; // GP2
pub const BIT_LPF_30_20M: u32 = 1 << 20; // GP3
pub const BIT_LPF_17_15M: u32 = 1 << 21; // GP4
pub const BIT_LPF_12_10M: u32 = 1 << 22; // GP5
/// 3 MHz high-pass (receive path). Open question (ARCHITECTURE.md section 8): which relay
/// contact this bit selects, bypassed or in-line, is what the AM-band level test settles.
pub const BIT_HPF_3MHZ: u32 = 1 << 23; // GP6
pub const BIT_RX_ANTENNA: u32 = 1 << 13; // GP7

/// Bit 12: switching-supply sync clocks off. Bit 11: band volts on the fan pin. Neither is a
/// filter-board bit, but they share register 0x00, a write must preserve them (PROTOCOL.md
/// section 12: "always as a full 32-bit value that keeps the other bits of register 0x00").
pub const BIT_SYNC_OFF: u32 = 1 << 12;
pub const BIT_BAND_VOLTS_FAN: u32 = 1 << 11;

/// Mask of every bit register 0x00 writes are documented to affect (filter relays, RX antenna,
/// sync-off, band-volts-on-fan). Used to warn if a caller's "current value" has stray bits.
pub const KNOWN_BITS: u32 = BIT_LPF_160M
    | BIT_LPF_80M
    | BIT_LPF_60_40M
    | BIT_LPF_30_20M
    | BIT_LPF_17_15M
    | BIT_LPF_12_10M
    | BIT_HPF_3MHZ
    | BIT_RX_ANTENNA
    | BIT_SYNC_OFF
    | BIT_BAND_VOLTS_FAN;

/// N2ADR filter board I2C address and bus (PROTOCOL.md 8.3 I2C bus list).
pub const MCP23008_I2C_ADDR: u8 = 0x20;
pub const MCP23008_I2C_BUS: u8 = crate::bridge::i2c_bus::FRONT_END;
/// MCP23008 output latch register (OLAT): reading it back over I2C confirms what the relays
/// were actually told to do, independent of the register-0x00 write reaching the gateware.
pub const MCP23008_OLAT_REG: u8 = 0x0A;

/// A receive band, for `band_filter_bits`. Matches Quisk's default receive table for the HL2
/// (`quisk_conf_defaults.py` lines 495-497, ARCHITECTURE.md section 8): the band's own low-pass
/// in line, plus the high-pass bit set on every band except 160 m.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Band {
    B160m,
    B80m,
    B60_40m,
    B30_20m,
    B17_15m,
    B12_10m,
}

/// Register 0x00 bits (LPF + HPF only, not the antenna bit) for one band, following Quisk's
/// table. Does not touch `BIT_RX_ANTENNA`, `BIT_SYNC_OFF` or `BIT_BAND_VOLTS_FAN`, the caller
/// ORs in whichever of those it also wants before writing register 0x00.
pub fn band_filter_bits(band: Band) -> u32 {
    match band {
        Band::B160m => BIT_LPF_160M,
        Band::B80m => BIT_HPF_3MHZ | BIT_LPF_80M,
        Band::B60_40m => BIT_HPF_3MHZ | BIT_LPF_60_40M,
        Band::B30_20m => BIT_HPF_3MHZ | BIT_LPF_30_20M,
        Band::B17_15m => BIT_HPF_3MHZ | BIT_LPF_17_15M,
        Band::B12_10m => BIT_HPF_3MHZ | BIT_LPF_12_10M,
    }
}

/// The 8 MCP23008 GPIO bits (GP0-GP7, bit 0 = GP0) that register-0x00 bits [23:17]+[13] are
/// expected to produce on the OLAT readback, given a register 0x00 value. GP7 (bit 7) comes
/// from `BIT_RX_ANTENNA`, GP0-GP6 (bits 0-6) from bits 17-23.
pub fn expected_olat(reg0_value: u32) -> u8 {
    let gp0_6 = ((reg0_value >> 17) & 0x7f) as u8;
    let gp7 = if reg0_value & BIT_RX_ANTENNA != 0 { 1 } else { 0 };
    gp0_6 | (gp7 << 7)
}

/// The register 0x00 bits that produce the MCP23008 latch `olat` (the inverse of
/// [`expected_olat`]). Bits 11 and 12 are not in the latch and come back as 0.
pub fn reg0_from_olat(olat: u8) -> u32 {
    (((olat & 0x7F) as u32) << 17) | if olat & 0x80 != 0 { BIT_RX_ANTENNA } else { 0 }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quisk_table_matches_architecture_doc() {
        // ARCHITECTURE.md section 8: 160m 0b0000001; 80m 0b1000010; 60/40m 0b1000100;
        // 30/20m 0b1001000; 17/15m 0b1010000; 12/10m 0b1100000 (bit order GP6..GP0).
        assert_eq!(expected_olat(band_filter_bits(Band::B160m)), 0b0000001);
        assert_eq!(expected_olat(band_filter_bits(Band::B80m)), 0b1000010);
        assert_eq!(expected_olat(band_filter_bits(Band::B60_40m)), 0b1000100);
        assert_eq!(expected_olat(band_filter_bits(Band::B30_20m)), 0b1001000);
        assert_eq!(expected_olat(band_filter_bits(Band::B17_15m)), 0b1010000);
        assert_eq!(expected_olat(band_filter_bits(Band::B12_10m)), 0b1100000);
    }

    #[test]
    fn antenna_bit_sets_gp7() {
        assert_eq!(expected_olat(BIT_RX_ANTENNA), 0b1000_0000);
        assert_eq!(expected_olat(band_filter_bits(Band::B80m) | BIT_RX_ANTENNA), 0b1100_0010);
    }

    #[test]
    fn latch_back_to_register() {
        for v in [0, band_filter_bits(Band::B80m) | BIT_RX_ANTENNA, band_filter_bits(Band::B160m)] {
            assert_eq!(reg0_from_olat(expected_olat(v)), v);
        }
    }

    #[test]
    fn sync_and_fan_bits_do_not_leak_into_olat() {
        assert_eq!(expected_olat(BIT_SYNC_OFF | BIT_BAND_VOLTS_FAN), 0);
    }
}
