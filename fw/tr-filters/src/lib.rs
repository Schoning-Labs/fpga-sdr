// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Insertion-loss curves of the N2ADR filter board, computed from the part values on its published
//! schematic and bill of materials. The curves are used on the AE350 side, where the tables this
//! crate builds are written into block RAM for the video compositor (see `docs/ARCHITECTURE.md`,
//! section 3.5) and where the band-selection helpers run at receive time, so the crate is
//! `no_std` and nothing in it may depend on `std`. `cargo test` still works because the test
//! harness links `std` into the test binary, which is separate from what the crate links into the
//! firmware image.
//!
//! See `docs/S10_FILTERS.md` for the sources, the Q and loss assumptions, and the comparison with
//! the DK1CG network analyzer measurements on the Hermes-Lite 2 wiki.
//!
//! Module map:
//! - [`complex`]: minimal `f32` complex arithmetic.
//! - [`abcd`]: ABCD (chain) matrix analysis of an LC ladder between two 50 ohm ports.
//! - [`filters`]: the seven N2ADR filters as ladders of real component values, plus the
//!   "no filter" thru path.
//! - [`tables`]: compact frequency and loss tables built from the ABCD model, in the format the
//!   compositor reads.
//! - [`bands`]: Hermes-Lite 2 band-select logic and the strong-interferer filter-choice helper.

#![no_std]

pub mod abcd;
pub mod bands;
pub mod complex;
pub mod filters;
pub mod tables;

pub use abcd::QAssumptions;
pub use bands::{
    best_filter_for_interferers, hpf_should_engage, is_outside_passband, select_filter_for_freq,
    select_filter_for_freqs, OUTSIDE_PASSBAND_DB,
};
pub use filters::FilterId;
pub use tables::{build_table, CurveTable, FREQ_STEP_HZ, N_POINTS};
