// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Filter selection logic: which relay or relays the firmware engages for a given receive
//! frequency or set of frequencies, and a helper that picks the filter which best knocks down
//! specific interfering signals while still passing the wanted one.
//!
//! The band edges and the rule "pick the tightest low-pass that still passes every active
//! receiver, plus the HPF on every band except 160 m" are an owner decision recorded in
//! `docs/ARCHITECTURE.md`, section 8, and they match the default Hermes-Lite 2 receive table of
//! Quisk (`quisk_conf_defaults.py`, lines 495 to 497, cited there).

use crate::filters::FilterId;
use crate::tables::CurveTable;

/// One amateur HF band's edges (Hz) and the low-pass filter that should be in line for it.
/// Region 1/2/3 band-edge differences (60 m channels, edges of 40/30/17/12 m in some countries)
/// do not change which of the board's seven relays is correct, since each relay covers two or
/// more whole bands; the numbers below are the widest commonly-allocated edges.
struct BandEdge {
    low_hz: f32,
    high_hz: f32,
    filter: FilterId,
}

const BAND_TABLE: [BandEdge; 6] = [
    BandEdge {
        low_hz: 1_800_000.0,
        high_hz: 2_000_000.0,
        filter: FilterId::Lpf160m,
    },
    BandEdge {
        low_hz: 3_500_000.0,
        high_hz: 4_000_000.0,
        filter: FilterId::Lpf80m,
    },
    BandEdge {
        low_hz: 5_330_500.0,
        high_hz: 7_300_000.0,
        filter: FilterId::Lpf60_40m,
    },
    BandEdge {
        low_hz: 10_100_000.0,
        high_hz: 14_350_000.0,
        filter: FilterId::Lpf30_20m,
    },
    BandEdge {
        low_hz: 18_068_000.0,
        high_hz: 21_450_000.0,
        filter: FilterId::Lpf17_15m,
    },
    BandEdge {
        low_hz: 24_890_000.0,
        high_hz: 29_700_000.0,
        filter: FilterId::Lpf12_10m,
    },
];

/// Highest frequency the widest (12/10 m) low-pass still usefully passes, from the measured
/// -3 dB cutoff (`docs/S10_FILTERS.md`); used as the fallback edge for out-of-band frequencies
/// (general coverage receive) above 10 m.
const LPF_12_10M_USABLE_TOP_HZ: f32 = 36_000_000.0;

/// The low-pass filter the firmware should select for one receive frequency: the tightest
/// (lowest-cutoff) filter whose intended band covers it, falling back to the next wider filter
/// for frequencies between bands or above 10 m, and to no filter at all above the 12/10 m
/// low-pass's usable range.
pub fn select_filter_for_freq(freq_hz: f32) -> FilterId {
    if freq_hz <= 0.0 {
        return FilterId::Lpf160m;
    }
    for edge in BAND_TABLE.iter() {
        debug_assert!(edge.low_hz <= edge.high_hz);
        if freq_hz <= edge.high_hz {
            return edge.filter;
        }
    }
    if freq_hz <= LPF_12_10M_USABLE_TOP_HZ {
        FilterId::Lpf12_10m
    } else {
        FilterId::NoFilter
    }
}

/// The filter for several simultaneous receivers, where the firmware chooses one filter set that
/// passes every active receiver (`docs/ARCHITECTURE.md`, section 8). Every low-pass on this board
/// passes everything below its own cutoff, so the filter chosen for the highest frequency in the
/// list always passes the rest too. Returns `None` for an empty list, because with nothing to
/// receive there is no requirement to pick a filter.
pub fn select_filter_for_freqs(freqs_hz: &[f32]) -> Option<FilterId> {
    let mut max_freq = None;
    for &f in freqs_hz {
        max_freq = Some(match max_freq {
            None => f,
            Some(m) => {
                if f > m {
                    f
                } else {
                    m
                }
            }
        });
    }
    max_freq.map(select_filter_for_freq)
}

/// A receiver is outside the chosen passband (`docs/ARCHITECTURE.md`, section 8: the display marks
/// receivers that fall outside it) when the modeled loss of the selected filter at its frequency
/// is worse than this. -3 dB is the conventional passband edge.
pub const OUTSIDE_PASSBAND_DB: f32 = -3.0;

/// True when `freq_hz` falls outside the passband of the filter that `table` describes.
pub fn is_outside_passband(table: &CurveTable, freq_hz: f32) -> bool {
    table.lookup_db(freq_hz) < OUTSIDE_PASSBAND_DB
}

/// Whether the Rx high-pass (GP6, "normally in line", bit 23) should be engaged for the given
/// selected low-pass. Quisk's table sets it on every band except 160 m (bit 6 clear only for
/// 160 m in `quisk_conf_defaults.py`); this board's HPF passes 3.5 MHz and up, so it would clip
/// 160 m itself if left in line there.
pub fn hpf_should_engage(selected_lpf: FilterId) -> bool {
    selected_lpf != FilterId::Lpf160m
}

/// Picks, among the filters that still pass `wanted_freq_hz` reasonably (loss better than
/// [`OUTSIDE_PASSBAND_DB`]), the one that leaves the strongest interferer weakest after filtering,
/// which minimizes the worst-case residual level. `interferers` holds `(freq_hz, level_db)` for
/// each strong out-of-band signal seen in the spectrum, where `level_db` can be in any consistent
/// relative unit (dBm, or dB above the noise floor), since only differences matter.
/// `tables` must cover every [`FilterId`] that could be chosen (normally all of
/// [`FilterId::ALL`] except [`FilterId::NoFilter`], since bypassing the filter board can never
/// help). Returns `None` if no candidate filter passes the wanted frequency at all.
pub fn best_filter_for_interferers(
    wanted_freq_hz: f32,
    interferers: &[(f32, f32)],
    tables: &[(FilterId, CurveTable)],
) -> Option<FilterId> {
    let mut best: Option<(FilterId, f32)> = None;
    for (id, table) in tables {
        let wanted_loss = table.lookup_db(wanted_freq_hz);
        if wanted_loss < OUTSIDE_PASSBAND_DB {
            continue; // would clip the wanted signal too
        }
        let mut worst_residual = f32::NEG_INFINITY;
        for &(freq, level) in interferers {
            let residual = level + table.lookup_db(freq); // loss is negative dB
            if residual > worst_residual {
                worst_residual = residual;
            }
        }
        let is_better = match best {
            None => true,
            Some((_, best_worst)) => worst_residual < best_worst,
        };
        if is_better {
            best = Some((*id, worst_residual));
        }
    }
    best.map(|(id, _)| id)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::abcd::QAssumptions;
    use crate::tables::build_table;

    #[test]
    fn band_edges_pick_expected_filter() {
        assert_eq!(select_filter_for_freq(1_900_000.0), FilterId::Lpf160m);
        assert_eq!(select_filter_for_freq(3_700_000.0), FilterId::Lpf80m);
        assert_eq!(select_filter_for_freq(7_100_000.0), FilterId::Lpf60_40m);
        assert_eq!(select_filter_for_freq(14_200_000.0), FilterId::Lpf30_20m);
        assert_eq!(select_filter_for_freq(21_200_000.0), FilterId::Lpf17_15m);
        assert_eq!(select_filter_for_freq(28_400_000.0), FilterId::Lpf12_10m);
    }

    #[test]
    fn multi_receiver_picks_highest_frequency_filter() {
        let freqs = [1_900_000.0, 7_100_000.0, 14_200_000.0];
        assert_eq!(select_filter_for_freqs(&freqs), Some(FilterId::Lpf30_20m));
        assert_eq!(select_filter_for_freqs(&[]), None);
    }

    #[test]
    fn hpf_only_off_on_160m() {
        assert!(!hpf_should_engage(FilterId::Lpf160m));
        assert!(hpf_should_engage(FilterId::Lpf80m));
        assert!(hpf_should_engage(FilterId::Lpf12_10m));
    }

    #[test]
    fn interferer_helper_avoids_clipping_wanted_signal() {
        let q = QAssumptions::DEFAULT;
        let tables: [(FilterId, CurveTable); 2] = [
            (FilterId::Lpf80m, build_table(FilterId::Lpf80m, &q)),
            (FilterId::Lpf60_40m, build_table(FilterId::Lpf60_40m, &q)),
        ];
        // Wanted signal at 7.1 MHz (40 m): the 80 m filter's cutoff (~5.3 MHz) would clip it, so
        // only 60/40 m qualifies even though a strong out-of-band interferer near 3.8 MHz would
        // otherwise favor the tighter 80 m filter for some other wanted frequency.
        let interferers = [(3_800_000.0, -20.0)];
        let chosen = best_filter_for_interferers(7_100_000.0, &interferers, &tables);
        assert_eq!(chosen, Some(FilterId::Lpf60_40m));
    }

    #[test]
    fn interferer_helper_prefers_tighter_filter_when_both_pass() {
        let q = QAssumptions::DEFAULT;
        let tables: [(FilterId, CurveTable); 2] = [
            (FilterId::Lpf60_40m, build_table(FilterId::Lpf60_40m, &q)),
            (FilterId::Lpf30_20m, build_table(FilterId::Lpf30_20m, &q)),
        ];
        // Wanted 7.1 MHz passes both filters; a strong interferer at 12 MHz (between the two
        // cutoffs) is knocked down hard by 60/40 m but barely touched by 30/20 m.
        let interferers = [(12_000_000.0, -10.0)];
        let chosen = best_filter_for_interferers(7_100_000.0, &interferers, &tables);
        assert_eq!(chosen, Some(FilterId::Lpf60_40m));
    }
}
