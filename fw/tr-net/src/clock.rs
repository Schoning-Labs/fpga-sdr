// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! UTC-disciplined system clock (docs/PLAN.md 5a). It has no hardware timer of its own: it turns
//! whatever monotonic microsecond counter the caller already has (the AE350's free-running timer
//! on the board, a plain counter in tests) into UTC, by keeping a running correction that
//! [`crate::sntp::SntpClient`] refreshes each time an SNTP exchange completes.
//!
//! A correction is applied as a direct set and not as a slew. The first correction after boot can
//! be arbitrarily large, because the monotonic counter starts at an arbitrary point, and FT8 needs
//! its slot boundary right from the start, so there is nothing close enough to slew from. A later
//! correction (SNTP re-runs periodically while the link stays up for hours) does jump the clock
//! forward or back by however much the local oscillator drifted since the last one, which for a
//! crystal oscillator over ten minutes is far below the timing FT8 tolerates. If it ever matters,
//! hysteresis or a slew limit would be added here.

/// A monotonic microsecond counter that never resets or wraps within any lifetime that matters
/// (a `u64` of microseconds lasts about 584,000 years). `tr-ae350` implements it on the target,
/// a plain incrementing counter does in tests.
pub trait MonotonicUs {
    /// Microseconds since an arbitrary start.
    fn now_us(&self) -> u64;
}

/// One SNTP exchange's result. [`DisciplinedClock::apply`] derives the running offset from the two fields.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Correction {
    /// This clock's own monotonic reading, in microseconds, at the moment the exchange completed
    /// (see [`crate::sntp::SntpClient::on_reply`]).
    pub mono_us: u64,
    /// The server's corresponding UTC time, in microseconds since the Unix epoch.
    pub utc_us: i64,
}

/// UTC = `MonotonicUs::now_us()` (as `i64`) + `offset_us`. `offset_us` starts at 0, which means
/// UTC is unknown and the clock reports monotonic time from an arbitrary epoch, until the first
/// [`apply`](Self::apply).
pub struct DisciplinedClock {
    offset_us: i64,
    synced: bool,
}

impl DisciplinedClock {
    /// A clock that has not been set yet.
    pub const fn new() -> Self {
        DisciplinedClock { offset_us: 0, synced: false }
    }

    /// Applies one SNTP-derived correction (see [`Correction`]).
    pub fn apply(&mut self, c: Correction) {
        self.offset_us = c.utc_us - c.mono_us as i64;
        self.synced = true;
    }

    /// `true` once at least one [`apply`](Self::apply) has run.
    pub fn is_synced(&self) -> bool {
        self.synced
    }

    /// Current UTC time in microseconds since the Unix epoch. Until [`is_synced`](Self::is_synced)
    /// the value is only monotonic time from an arbitrary epoch.
    pub fn now_utc_us<M: MonotonicUs>(&self, mono: &M) -> i64 {
        mono.now_us() as i64 + self.offset_us
    }
}

impl Default for DisciplinedClock {
    fn default() -> Self {
        Self::new()
    }
}

/// Milliseconds until the next slot boundary, from a UTC time in milliseconds. FT8 (15 s) and FT4
/// (7.5 s) slots are aligned to UTC, as in WSJT-X, so a slot starts every `slot_len_ms`
/// milliseconds counted from the epoch. The caller that dispatches the per-slot decode jobs
/// (`fw/tr-modes/src/frontend/sched.rs`) uses it; this crate has no dependency on `tr-modes`.
pub fn ms_until_next_slot_boundary(utc_ms: i64, slot_len_ms: i64) -> i64 {
    let into_slot = utc_ms.rem_euclid(slot_len_ms);
    if into_slot == 0 {
        0
    } else {
        slot_len_ms - into_slot
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct FakeMono(core::cell::Cell<u64>);
    impl MonotonicUs for FakeMono {
        fn now_us(&self) -> u64 {
            self.0.get()
        }
    }

    #[test]
    fn unsynced_clock_tracks_monotonic_from_zero_offset() {
        let mono = FakeMono(core::cell::Cell::new(1_000_000));
        let clk = DisciplinedClock::new();
        assert!(!clk.is_synced());
        assert_eq!(clk.now_utc_us(&mono), 1_000_000);
    }

    #[test]
    fn apply_sets_utc_exactly_at_the_correction_instant() {
        let mono = FakeMono(core::cell::Cell::new(5_000_000));
        let mut clk = DisciplinedClock::new();
        clk.apply(Correction { mono_us: 5_000_000, utc_us: 1_700_000_000_000_000 });
        assert!(clk.is_synced());
        assert_eq!(clk.now_utc_us(&mono), 1_700_000_000_000_000);

        mono.0.set(5_000_500); // 500 us later
        assert_eq!(clk.now_utc_us(&mono), 1_700_000_000_000_500);
    }

    #[test]
    fn slot_boundary_math() {
        assert_eq!(ms_until_next_slot_boundary(0, 15_000), 0);
        assert_eq!(ms_until_next_slot_boundary(1, 15_000), 14_999);
        assert_eq!(ms_until_next_slot_boundary(14_999, 15_000), 1);
        assert_eq!(ms_until_next_slot_boundary(15_000, 15_000), 0);
        assert_eq!(ms_until_next_slot_boundary(7_500, 7_500), 0);
    }
}
