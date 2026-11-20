// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! A bit-exact Rust model of the receiver bank in `rtl/rx/*.v`. Every register in the RTL has a
//! matching field in this crate, and every `always @(posedge clock)` block has a matching
//! computation in a `step` method. `docs/R2_RXMODEL.md` describes the design and the measured
//! numbers, and the module doc of `bits.rs` explains the translation approach that the whole crate
//! uses.
//!
//! The crate runs on a PC only (plain `std`, not `no_std`) and is not meant for the AE350. It
//! stands in for the real FPGA receiver bank on a PC, either for the bit-exact comparison against
//! `iverilog` (see `bin/r2_check.rs`) or for the simulator in `tr-sim`, where a live
//! Hermes-Lite 2 stream or a capture goes through this model, then `tr-dsp`, and ends as audio.

pub mod bank;
pub mod bits;
pub mod channel;
pub mod cic;
pub mod fir;
pub mod nco;

pub use bank::RxBank;
pub use channel::RxChannel;
