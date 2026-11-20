// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! ABCD (chain) matrix analysis of an LC ladder network, terminated in 50 ohm at both ends.
//!
//! Each filter is a list of [`Branch`]es alternating series and shunt elements, although some
//! ladders put two branches of the same kind back to back (e.g. two shunt capacitors on either
//! side of a relay contact resistance). The list only has to describe the network from left to
//! right, because the type of each branch and not its position decides how it combines.
//!
//! Component loss model (see `docs/S10_FILTERS.md`, "Q assumptions", for the values and the
//! reasons): every inductor gets a series ESR of `omega * L / Q_L` and every capacitor gets a
//! series ESR of `1 / (omega * C * Q_C)`. Both scale with frequency the way the skin-effect loss
//! of a real wirewound inductor and the dielectric loss of a real NP0/C0G capacitor do, which
//! keeps Q roughly constant across the HF band, whereas a fixed resistance would be wrong by a
//! large factor at one end of the sweep.

use crate::complex::Complex32;

/// A single element in the ladder, already carrying its assumed loss.
#[derive(Clone, Copy, Debug)]
pub enum Branch {
    /// Series inductor (possibly with a parallel capacitor forming an elliptic notch/trap, when
    /// `c_pf` is `Some`). Series relay/PCB resistance can be folded into `extra_r_ohm`.
    SeriesL {
        /// Inductance in nanohenries.
        l_nh: f32,
        /// Capacitance in picofarads of the parallel trap capacitor, if there is one.
        c_pf: Option<f32>,
        /// Extra series resistance in ohms (relay contacts, copper) on top of the inductor loss.
        extra_r_ohm: f32,
    },
    /// Shunt capacitor to ground.
    ShuntC { c_pf: f32 },
    /// Series capacitor (the Rx HPF's series arms).
    SeriesC { c_pf: f32 },
    /// Shunt inductor to ground (the Rx HPF's shunt arms).
    ShuntL { l_nh: f32 },
    /// A bare series resistance (relay contacts, PCB copper). Used for the "no filter" thru
    /// path and folded into the source/load-facing ends of real filters.
    SeriesR { r_ohm: f32 },
}

/// Assumed component quality factors at HF, applied uniformly (see module docs and
/// `docs/S10_FILTERS.md`).
#[derive(Clone, Copy, Debug)]
pub struct QAssumptions {
    /// Loaded Q of the wirewound/toroidal inductors (T30-2, T37-2, T50-2 sized cores typical of
    /// this board) around the middle of the HF range.
    pub q_l: f32,
    /// Q of the NP0/C0G ceramic capacitors used throughout (per the N2ADR page, 630 V NP0/C0G in
    /// 1206/0805).
    pub q_c: f32,
}

impl QAssumptions {
    /// `Q_L = 150`, `Q_C = 1000`: reasonable mid-HF numbers for small toroidal RF inductors
    /// (T30-2/T37-2 iron powder, Q of 100-200 from 2-30 MHz per common core-loss curves) and NP0
    /// ceramic chip capacitors (ESR negligible next to the inductor loss; sources in
    /// `docs/S10_FILTERS.md`).
    pub const DEFAULT: QAssumptions = QAssumptions {
        q_l: 150.0,
        q_c: 1000.0,
    };
}

/// Impedance of a series inductor with its own ESR, or of the inductor in parallel with its
/// capacitor (a trap, which is a notch above the cutoff of an elliptic filter) when `c_pf` is given.
fn series_l_impedance(
    l_nh: f32,
    c_pf: Option<f32>,
    extra_r_ohm: f32,
    omega: f32,
    q: &QAssumptions,
) -> Complex32 {
    let l = l_nh * 1.0e-9;
    let r_l = omega * l / q.q_l;
    let z_l = Complex32::new(r_l + extra_r_ohm, omega * l);
    match c_pf {
        None => z_l,
        Some(c_pf) => {
            let c = c_pf * 1.0e-12;
            let r_c = 1.0 / (omega * c * q.q_c);
            let z_c = Complex32::new(r_c, -1.0 / (omega * c));
            // Parallel combination (the trap): z_l * z_c / (z_l + z_c).
            (z_l * z_c) / (z_l + z_c)
        }
    }
}

/// Admittance of a shunt capacitor including its ESR.
fn shunt_c_admittance(c_pf: f32, omega: f32, q: &QAssumptions) -> Complex32 {
    let c = c_pf * 1.0e-12;
    let r_c = 1.0 / (omega * c * q.q_c);
    let z_c = Complex32::new(r_c, -1.0 / (omega * c));
    z_c.recip()
}

/// Impedance of a series capacitor including its ESR.
fn series_c_impedance(c_pf: f32, omega: f32, q: &QAssumptions) -> Complex32 {
    let c = c_pf * 1.0e-12;
    let r_c = 1.0 / (omega * c * q.q_c);
    Complex32::new(r_c, -1.0 / (omega * c))
}

/// Admittance of a shunt inductor including its ESR.
fn shunt_l_admittance(l_nh: f32, omega: f32, q: &QAssumptions) -> Complex32 {
    let l = l_nh * 1.0e-9;
    let r_l = omega * l / q.q_l;
    let z_l = Complex32::new(r_l, omega * l);
    z_l.recip()
}

/// A 2x2 complex chain (ABCD) matrix, row-major: `[[a, b], [c, d]]`.
#[derive(Clone, Copy, Debug)]
pub struct Abcd {
    pub a: Complex32,
    pub b: Complex32,
    pub c: Complex32,
    pub d: Complex32,
}

impl Abcd {
    /// The matrix of an empty chain, which passes the signal through unchanged.
    pub const IDENTITY: Abcd = Abcd {
        a: Complex32::ONE,
        b: Complex32::ZERO,
        c: Complex32::ZERO,
        d: Complex32::ONE,
    };

    fn series(z: Complex32) -> Abcd {
        Abcd {
            a: Complex32::ONE,
            b: z,
            c: Complex32::ZERO,
            d: Complex32::ONE,
        }
    }

    fn shunt(y: Complex32) -> Abcd {
        Abcd {
            a: Complex32::ONE,
            b: Complex32::ZERO,
            c: y,
            d: Complex32::ONE,
        }
    }

    /// Cascade `self` then `rhs` (signal flows through `self` first).
    fn cascade(self, rhs: Abcd) -> Abcd {
        Abcd {
            a: self.a * rhs.a + self.b * rhs.c,
            b: self.a * rhs.b + self.b * rhs.d,
            c: self.c * rhs.a + self.d * rhs.c,
            d: self.c * rhs.b + self.d * rhs.d,
        }
    }
}

/// Chains every branch's ABCD matrix at angular frequency `omega` (`2*pi*f`).
pub fn ladder_abcd(branches: &[Branch], omega: f32, q: &QAssumptions) -> Abcd {
    let mut total = Abcd::IDENTITY;
    for branch in branches {
        let stage = match *branch {
            Branch::SeriesL {
                l_nh,
                c_pf,
                extra_r_ohm,
            } => Abcd::series(series_l_impedance(l_nh, c_pf, extra_r_ohm, omega, q)),
            Branch::ShuntC { c_pf } => Abcd::shunt(shunt_c_admittance(c_pf, omega, q)),
            Branch::SeriesC { c_pf } => Abcd::series(series_c_impedance(c_pf, omega, q)),
            Branch::ShuntL { l_nh } => Abcd::shunt(shunt_l_admittance(l_nh, omega, q)),
            Branch::SeriesR { r_ohm } => Abcd::series(Complex32::real(r_ohm)),
        };
        total = total.cascade(stage);
    }
    total
}

/// `|S21|` in dB for a two-port matched into `z0` ohm at both ends:
/// `S21 = 2 / (A + B/Z0 + C*Z0 + D)`, `insertion_loss_db = 20*log10(|S21|)` (negative in the
/// passband, matching how the DK1CG VNA plots and Quisk both report it).
pub fn s21_db(m: Abcd, z0: f32) -> f32 {
    let z0c = Complex32::real(z0);
    let denom = m.a + m.b / z0c + m.c * z0c + m.d;
    let s21 = Complex32::new(2.0, 0.0) / denom;
    let mag = s21.magnitude();
    // A passive network with finite Q never gives exactly zero, but the logarithm needs the guard.
    let mag = if mag < 1.0e-12 { 1.0e-12 } else { mag };
    20.0 * libm::log10f(mag)
}

#[cfg(test)]
mod tests {
    use super::*;
    use core::f32::consts::PI;

    #[test]
    fn thru_wire_is_zero_db() {
        let m = ladder_abcd(&[], 2.0 * PI * 10.0e6, &QAssumptions::DEFAULT);
        let db = s21_db(m, 50.0);
        assert!(db.abs() < 1.0e-4, "expected 0 dB thru, got {db}");
    }

    #[test]
    fn single_series_resistor_matches_voltage_divider() {
        // A single series R between matched 50 ohm source/load is a simple voltage divider:
        // classic result S21 = 2*Z0 / (2*Z0 + R).
        let r = 10.0_f32;
        let m = ladder_abcd(&[Branch::SeriesR { r_ohm: r }], 1.0, &QAssumptions::DEFAULT);
        let db = s21_db(m, 50.0);
        let expect = 20.0 * libm::log10f(2.0 * 50.0 / (2.0 * 50.0 + r));
        assert!((db - expect).abs() < 1.0e-3, "{db} vs {expect}");
    }

    #[test]
    fn ideal_lc_lowpass_is_symmetric_pi() {
        // A lossless 3-element Pi (C - L - C) low-pass should have unity |S21| well below
        // cutoff (loss only from mismatch, which is ~0 near DC) and roll off above it.
        let q = QAssumptions {
            q_l: 1.0e6,
            q_c: 1.0e6,
        };
        let branches = [
            Branch::ShuntC { c_pf: 1000.0 },
            Branch::SeriesL {
                l_nh: 1800.0,
                c_pf: None,
                extra_r_ohm: 0.0,
            },
            Branch::ShuntC { c_pf: 1000.0 },
        ];
        let low = ladder_abcd(&branches, 2.0 * PI * 1.0e6, &q);
        let db_low = s21_db(low, 50.0);
        assert!(
            db_low.abs() < 0.3,
            "near-DC loss should be ~0 dB, got {db_low}"
        );

        let high = ladder_abcd(&branches, 2.0 * PI * 100.0e6, &q);
        let db_high = s21_db(high, 50.0);
        assert!(
            db_high < -20.0,
            "should be well into the stopband, got {db_high}"
        );
    }
}
