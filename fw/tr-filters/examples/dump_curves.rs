// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Host-only tool that dumps the computed insertion-loss table of every filter as CSV on stdout,
//! in the form `freq_hz,filter,db`. It uses `std` for `println!`, while the library itself stays
//! `no_std`. The output feeds `docs/plot_s10_filters.py`, which overlays it on the digitized DK1CG
//! network analyzer measurement and renders the PNGs in `docs/img/`.
//!
//! Run it with `cargo run --example dump_curves -p tr-filters > computed.csv`.

use tr_filters::{build_table, FilterId, QAssumptions};

fn main() {
    println!("freq_hz,filter,db");
    for filter in FilterId::ALL {
        let table = build_table(filter, &QAssumptions::DEFAULT);
        for i in 0..tr_filters::N_POINTS {
            let freq_hz = i as u32 * tr_filters::FREQ_STEP_HZ;
            let db = table.db_centi[i] as f32 / 100.0;
            println!("{freq_hz},{},{db}", filter.name());
        }
    }
}
