// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! `tr-modes`: FT8, FT4 and WSPR encode and decode on top of the
//! [mfsk-core](https://github.com/jl1nie/mfsk-core) crate, plus the FT8 transmit baseband and the
//! bit-exact software models of the FPGA decoder engines. Other modes (CW, RTTY, PSK31, SSTV, JS8,
//! FreeDV) are planned, see docs/PLAN.md.
//!
//! ## Shape
//!
//! The crate is `#![no_std]` plus `alloc` by default, so it cross-builds for
//! `riscv32imafc-unknown-none-elf` (the AE350 firmware target). `encode` needs no FFT (mfsk-core's
//! own `wave_gen`, `message` and `ldpc` modules are FFT-free) and therefore builds and runs under
//! `no_std` unconditionally. `decode` needs an FFT backend, and by default that is `fft`, this
//! crate's own pure-Rust `no_std` implementation wired in through mfsk-core's `fft-extern` hook
//! (feature `fft-portable`, on by default), which is what makes `decode` available under `no_std`
//! at all. An optional `fft-rustfft` feature swaps in mfsk-core's SIMD-accelerated, `std`-only
//! `rustfft` backend instead, kept only for the host-side timing comparison in `docs/S5_MODES.md`.
//! The `std` feature (on by default for host builds such as `cargo test` and the `trmodes-decode`
//! PC command line tool) only adds `mfsk-core/std`, which brings `alloc`-level conveniences, and
//! does not gate `decode`.
//!
//! See `docs/S5_MODES.md` for the WSJT-X sample decode results, the encode/decode round trip, the
//! `no_std` FFT backend's own correctness tests, and the FT8 timing measurement with its AE350
//! estimate.

#![cfg_attr(not(feature = "std"), no_std)]

extern crate alloc;

/// A cooperative yield point inside the long decodes (vendored mfsk-core, `yield_hook`; docs/NETINPUT.md).
pub use mfsk_core::yield_hook;

pub mod encode;

/// FT8 transmit baseband for the TX ring: tones, then GFSK at 48 ksps complex.
#[cfg(feature = "ft8")]
pub mod txbb;

#[cfg(any(feature = "fft-rustfft", feature = "fft-portable"))]
pub mod decode;

#[cfg(feature = "fft-portable")]
pub mod fft;

/// FT8 decoder front end: bit-exact models of the FPGA decoder engines and the CPU half of the
/// decoder on top of them (ARCHITECTURE 3.12, docs/S15_FT8MODEL.md).
#[cfg(all(feature = "ft8", any(feature = "fft-rustfft", feature = "fft-portable")))]
pub mod frontend;

#[cfg(test)]
mod tests {
    #[test]
    fn crate_builds() {
        // Presence test: if this compiles, the no_std/std feature wiring
        // above is at least self-consistent for the host build.
    }
}
