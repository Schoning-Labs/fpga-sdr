// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! N2ADR filter board: the seven relay-switched networks (six low-pass and one high-pass), as
//! ladders of [`Branch`]es built from the published part values.
//!
//! Only the values are used here, and no schematic or bill of materials file is copied into this
//! repository (see `docs/S10_FILTERS.md`). The sources are:
//!
//! - `hardware/companions/n2adr/n2adr.sch` and `n2adr.net` in softerhardware/Hermes-Lite2, the KiCad
//!   project "HL2 Filter Board" by N2ADR, rev E5build8, dated 2019-02-20. The component values
//!   (the `F 1` fields of the schematic) and the node connectivity (the `(net ...)` blocks of the
//!   netlist) were read directly from it, and every value below carries its reference designator
//!   in a comment so it can be checked against that file.
//! - The relay part EC2-3NU (Panasonic/Aromat DPDT signal relay), from the `F 1` fields of `K1` to
//!   `K7` in the same schematic.
//! - https://james.ahlstrom.name/hl2filter/ (N2ADR's own page) for the general construction notes
//!   (630 V NP0/C0G capacitors, wirewound inductors below 680 nH on non-magnetic cores, ferrite
//!   cores above that), which are used for the Q assumptions in [`crate::abcd::QAssumptions`] and
//!   not for component values, because the page does not list values per filter.
//!
//! Topology, from the netlist: every low-pass filter is a symmetric Pi ladder, shunt C - series
//! L - shunt C - series L - shunt C. Two bands (60/40 m and 30/20 m) add a small capacitor
//! directly across each series inductor (the netlist puts it on the same two nodes as the
//! inductor), which forms an elliptic (Cauer) notch above the cutoff, while the other four bands
//! (160 m, 80 m, 17/15 m and 12/10 m) are plain 5-element Chebyshev-style ladders without such a
//! capacitor. The Rx HPF mirrors the low-pass shape with series and shunt swapped: series C -
//! shunt L - series C - shunt L - series C.

use crate::abcd::Branch;

/// One relay-selected network on the board, matching `docs/ARCHITECTURE.md` section 8's bit
/// table (register 0x00 bits 17-23, MCP23008 GP0-GP6).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FilterId {
    /// GP0 (bit 17): 160 m low-pass.
    Lpf160m,
    /// GP1 (bit 18): 80 m low-pass.
    Lpf80m,
    /// GP2 (bit 19): 60/40 m low-pass.
    Lpf60_40m,
    /// GP3 (bit 20): 30/20 m low-pass.
    Lpf30_20m,
    /// GP4 (bit 21): 17/15 m low-pass.
    Lpf17_15m,
    /// GP5 (bit 22): 12/10 m low-pass.
    Lpf12_10m,
    /// GP6 (bit 23): 3 MHz Rx high-pass.
    Hpf3m,
    /// No relay engaged: the signal goes straight through the relay bypass chain, with all seven
    /// relays on their normally-bypassed contact. Modeled as the calibrated board loss alone, see
    /// [`BOARD_THRU_R_OHM`].
    NoFilter,
}

impl FilterId {
    /// Every filter of the board plus the thru path, in bit order, so the index matches a table slot.
    pub const ALL: [FilterId; 8] = [
        FilterId::Lpf160m,
        FilterId::Lpf80m,
        FilterId::Lpf60_40m,
        FilterId::Lpf30_20m,
        FilterId::Lpf17_15m,
        FilterId::Lpf12_10m,
        FilterId::Hpf3m,
        FilterId::NoFilter,
    ];

    /// The relay-chain contact resistance every path (filtered or not) picks up, as its own
    /// branch, followed by the filter's own ladder (empty for [`FilterId::NoFilter`]).
    pub fn branches(self) -> &'static [Branch] {
        match self {
            FilterId::Lpf160m => &LPF_160M,
            FilterId::Lpf80m => &LPF_80M,
            FilterId::Lpf60_40m => &LPF_60_40M,
            FilterId::Lpf30_20m => &LPF_30_20M,
            FilterId::Lpf17_15m => &LPF_17_15M,
            FilterId::Lpf12_10m => &LPF_12_10M,
            FilterId::Hpf3m => &HPF_3M,
            FilterId::NoFilter => &NO_FILTER,
        }
    }

    /// Short human name for logs/UI, e.g. `"60/40m"`.
    pub const fn name(self) -> &'static str {
        match self {
            FilterId::Lpf160m => "160m",
            FilterId::Lpf80m => "80m",
            FilterId::Lpf60_40m => "60/40m",
            FilterId::Lpf30_20m => "30/20m",
            FilterId::Lpf17_15m => "17/15m",
            FilterId::Lpf12_10m => "12/10m",
            FilterId::Hpf3m => "HPF",
            FilterId::NoFilter => "thru",
        }
    }
}

/// Relay contact + PCB/connector loss common to every path, calibrated from the measured
/// "Board_thru" VNA trace on the HL2 wiki (about -0.2 dB, essentially flat from 1-30 MHz) rather
/// than derived from a relay datasheet: `docs/S10_FILTERS.md` "Q and loss assumptions" has the
/// derivation and the honest caveat that a real EC2-3NU's contact resistance (not found in a
/// public datasheet) would only account for a fraction of this. Applied as one series resistor
/// per path, seven relay contacts' worth combined into a single lumped value since the ladder
/// analysis does not need them separated.
pub const BOARD_THRU_R_OHM: f32 = 2.3;

const THRU: Branch = Branch::SeriesR {
    r_ohm: BOARD_THRU_R_OHM,
};

const NO_FILTER: [Branch; 1] = [THRU];

/// 160 m low-pass (relay K1). Shunt C21 1800p - series L5 3.9u - shunt C22 3300p - series L6
/// 3.9u - shunt C23 1800p. Symmetric 5-element Pi ladder, no elliptic notch capacitor.
const LPF_160M: [Branch; 6] = [
    THRU,
    Branch::ShuntC { c_pf: 1800.0 }, // C21
    Branch::SeriesL {
        l_nh: 3900.0, // L5
        c_pf: None,
        extra_r_ohm: 0.0,
    },
    Branch::ShuntC { c_pf: 3300.0 }, // C22
    Branch::SeriesL {
        l_nh: 3900.0, // L6
        c_pf: None,
        extra_r_ohm: 0.0,
    },
    Branch::ShuntC { c_pf: 1800.0 }, // C23
];

/// 80 m low-pass (relay K2). Shunt C8 1000p - series L1 1.8u - shunt C9 1800p - series L2 1.8u -
/// shunt C10 1000p.
const LPF_80M: [Branch; 6] = [
    THRU,
    Branch::ShuntC { c_pf: 1000.0 }, // C8
    Branch::SeriesL {
        l_nh: 1800.0, // L1
        c_pf: None,
        extra_r_ohm: 0.0,
    },
    Branch::ShuntC { c_pf: 1800.0 }, // C9
    Branch::SeriesL {
        l_nh: 1800.0, // L2
        c_pf: None,
        extra_r_ohm: 0.0,
    },
    Branch::ShuntC { c_pf: 1000.0 }, // C10
];

/// 60/40 m low-pass (relay K3). Elliptic: shunt C32 270p - [series L9 1000n || C35 100p] -
/// shunt C37 560p - [series L12 680n || C40 270p] - shunt C42 220p.
const LPF_60_40M: [Branch; 6] = [
    THRU,
    Branch::ShuntC { c_pf: 270.0 }, // C32
    Branch::SeriesL {
        l_nh: 1000.0,      // L9
        c_pf: Some(100.0), // C35, parallel trap
        extra_r_ohm: 0.0,
    },
    Branch::ShuntC { c_pf: 560.0 }, // C37
    Branch::SeriesL {
        l_nh: 680.0,       // L12
        c_pf: Some(270.0), // C40, parallel trap
        extra_r_ohm: 0.0,
    },
    Branch::ShuntC { c_pf: 220.0 }, // C42
];

/// 30/20 m low-pass (relay K4). Elliptic: shunt C33 150p - [series L10 560n || C36 39p] -
/// shunt C38 270p - [series L13 270n || C41 220p] - shunt C43 68p.
const LPF_30_20M: [Branch; 6] = [
    THRU,
    Branch::ShuntC { c_pf: 150.0 }, // C33
    Branch::SeriesL {
        l_nh: 560.0,      // L10
        c_pf: Some(39.0), // C36, parallel trap
        extra_r_ohm: 0.0,
    },
    Branch::ShuntC { c_pf: 270.0 }, // C38
    Branch::SeriesL {
        l_nh: 270.0,       // L13
        c_pf: Some(220.0), // C41, parallel trap
        extra_r_ohm: 0.0,
    },
    Branch::ShuntC { c_pf: 68.0 }, // C43
];

/// 17/15 m low-pass (relay K5). Shunt C34 180p - series L11 390n - shunt C39 330p - series L14
/// 390n - shunt C44 180p.
const LPF_17_15M: [Branch; 6] = [
    THRU,
    Branch::ShuntC { c_pf: 180.0 }, // C34
    Branch::SeriesL {
        l_nh: 390.0, // L11
        c_pf: None,
        extra_r_ohm: 0.0,
    },
    Branch::ShuntC { c_pf: 330.0 }, // C39
    Branch::SeriesL {
        l_nh: 390.0, // L14
        c_pf: None,
        extra_r_ohm: 0.0,
    },
    Branch::ShuntC { c_pf: 180.0 }, // C44
];

/// 12/10 m low-pass (relay K6). Shunt C24 150p - series L7 220n - shunt C25 330p - series L8
/// 220n - shunt C26 150p.
const LPF_12_10M: [Branch; 6] = [
    THRU,
    Branch::ShuntC { c_pf: 150.0 }, // C24
    Branch::SeriesL {
        l_nh: 220.0, // L7
        c_pf: None,
        extra_r_ohm: 0.0,
    },
    Branch::ShuntC { c_pf: 330.0 }, // C25
    Branch::SeriesL {
        l_nh: 220.0, // L8
        c_pf: None,
        extra_r_ohm: 0.0,
    },
    Branch::ShuntC { c_pf: 150.0 }, // C26
];

/// Rx 3 MHz high-pass (relay K7). Mirrors the low-pass shape with series/shunt swapped: series
/// C47 1500p - shunt L15 1.8u - series C48 680p - shunt L4 1.8u - series C49 1500p.
const HPF_3M: [Branch; 6] = [
    THRU,
    Branch::SeriesC { c_pf: 1500.0 }, // C47
    Branch::ShuntL { l_nh: 1800.0 },  // L15
    Branch::SeriesC { c_pf: 680.0 },  // C48
    Branch::ShuntL { l_nh: 1800.0 },  // L4
    Branch::SeriesC { c_pf: 1500.0 }, // C49
];

#[cfg(test)]
mod tests {
    use super::*;
    use crate::abcd::{ladder_abcd, s21_db, QAssumptions};
    use core::f32::consts::PI;

    #[test]
    fn every_filter_has_branches() {
        for f in FilterId::ALL {
            assert!(!f.branches().is_empty());
        }
    }

    #[test]
    fn lowpass_filters_pass_hf_and_reject_vhf() {
        let q = QAssumptions::DEFAULT;
        for f in [
            FilterId::Lpf160m,
            FilterId::Lpf80m,
            FilterId::Lpf60_40m,
            FilterId::Lpf30_20m,
            FilterId::Lpf17_15m,
            FilterId::Lpf12_10m,
        ] {
            let low = s21_db(ladder_abcd(f.branches(), 2.0 * PI * 1.0e6, &q), 50.0);
            let high = s21_db(ladder_abcd(f.branches(), 2.0 * PI * 200.0e6, &q), 50.0);
            assert!(low > -2.0, "{}: 1 MHz loss {low} too high", f.name());
            assert!(
                high < -15.0,
                "{}: 200 MHz loss {high} too shallow",
                f.name()
            );
        }
    }
}
