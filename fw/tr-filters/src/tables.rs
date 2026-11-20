// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Compact insertion-loss tables for the video compositor.
//!
//! `docs/ARCHITECTURE.md`, section 3.5, says the compositor overlays the filter-board curves from a
//! per-column y table in block RAM that firmware writes, with up to 8 curves and one of them
//! highlighted. A per-column, per-pixel-y table depends on the geometry and the dB scale of the
//! window as it is at that moment, and both change whenever the operator zooms, so firmware has to
//! build that table at render time and this crate cannot. What this crate exports is independent
//! of the resolution: insertion loss in dB on a fixed grid of frequencies that spans the whole
//! 0 to 38.4 MHz range of the ADC and DAC, one table per filter. The tables are small enough that
//! firmware can hold all eight (seven filters and no filter, which is exactly the 8 curves the
//! compositor can show) in block RAM, and it can rasterize them into whatever window is on screen
//! with a simple linear interpolation.
//!
//! Layout: 385 points, 100 kHz apart, `f[i] = i * 100_000 Hz` for `i` in `0..385`, which covers 0
//! to 38.4 MHz inclusive. Loss is stored as centi-dB (`round(db * 100)`) in an `i16`, a range of
//! +/-327.67 dB that is plenty for a passive filter. One curve takes `385 * 2 = 770` bytes and all
//! eight take 6,160 bytes.

use crate::abcd::{ladder_abcd, s21_db, QAssumptions};
use crate::filters::FilterId;

/// Spacing of the table's frequency grid in Hz.
pub const FREQ_STEP_HZ: u32 = 100_000;
/// Number of points in a table, so the grid runs from 0 to 38.4 MHz inclusive.
pub const N_POINTS: usize = 385;

#[derive(Clone, Copy)]
/// Insertion loss of one filter on the 100 kHz grid.
pub struct CurveTable {
    /// Insertion loss at `i * FREQ_STEP_HZ`, in hundredths of a dB (negative = loss).
    pub db_centi: [i16; N_POINTS],
}

impl CurveTable {
    /// Frequency in Hz of the grid point with the given index.
    pub const fn freq_hz(index: usize) -> u32 {
        index as u32 * FREQ_STEP_HZ
    }

    /// Linear interpolation between grid points; clamps to the ends outside 0-38.4 MHz.
    pub fn lookup_db(&self, freq_hz: f32) -> f32 {
        if freq_hz <= 0.0 {
            return self.db_centi[0] as f32 / 100.0;
        }
        let steps = freq_hz / FREQ_STEP_HZ as f32;
        let i0 = steps as usize;
        if i0 + 1 >= N_POINTS {
            return self.db_centi[N_POINTS - 1] as f32 / 100.0;
        }
        let frac = steps - i0 as f32;
        let a = self.db_centi[i0] as f32 / 100.0;
        let b = self.db_centi[i0 + 1] as f32 / 100.0;
        a + (b - a) * frac
    }
}

/// Runs the ABCD ladder analysis at every grid point. It is plain arithmetic without any
/// allocation, so it can run on the AE350 at start-up to fill the block RAM tables, or ahead of
/// time on the PC (tests, the plotting script in `docs/`).
pub fn build_table(filter: FilterId, q: &QAssumptions) -> CurveTable {
    let mut db_centi = [0i16; N_POINTS];
    let branches = filter.branches();
    for (i, slot) in db_centi.iter_mut().enumerate() {
        let freq_hz = CurveTable::freq_hz(i) as f32;
        // At DC (i = 0) omega is 0, which makes every reactance singular (1/0). The physical board
        // passes DC through the inductors and blocks it through the series capacitors of the HPF,
        // which is 0 dB and minus infinity in the limit. The singularity is skipped by reusing the
        // next point (100 kHz), which already sits well inside either the flat passband or the
        // stopband of the HPF.
        let freq_hz = if freq_hz == 0.0 {
            FREQ_STEP_HZ as f32
        } else {
            freq_hz
        };
        let omega = 2.0 * core::f32::consts::PI * freq_hz;
        let m = ladder_abcd(branches, omega, q);
        let db = s21_db(m, 50.0);
        let centi = db * 100.0;
        *slot = if centi > i16::MAX as f32 {
            i16::MAX
        } else if centi < i16::MIN as f32 {
            i16::MIN
        } else {
            centi as i16
        };
    }
    CurveTable { db_centi }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lookup_matches_grid_points() {
        let t = build_table(FilterId::Lpf80m, &QAssumptions::DEFAULT);
        for i in [0usize, 1, 40, 384] {
            let f = CurveTable::freq_hz(i) as f32;
            let looked_up = t.lookup_db(f.max(FREQ_STEP_HZ as f32));
            let direct = t.db_centi[i] as f32 / 100.0;
            assert!(
                (looked_up - direct).abs() < 1e-3,
                "index {i}: {looked_up} vs {direct}"
            );
        }
    }

    #[test]
    fn all_eight_tables_build() {
        for f in FilterId::ALL {
            let t = build_table(f, &QAssumptions::DEFAULT);
            assert_eq!(t.db_centi.len(), N_POINTS);
        }
    }
}
