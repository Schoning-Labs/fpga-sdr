// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! `f32` DSP for the receive chain of fpga-sdr: fast-convolution
//! bandpass filters with adjustable width/shift, AGC, SSB/CW/AM/FM demodulators, a noise
//! blanker, spectral noise reduction, a rational resampler to 48 kHz, and CW keying envelope
//! shaping. Design and measured numbers: `docs/S3_DSP.md`.
//!
//! `no_std`, no allocation: every buffer is a fixed-size array sized from the constants in
//! [`fastconv`] and [`fft`] (1,024-point FFT, 512-sample blocks), so the crate has no heap
//! dependency and no `#[global_allocator]` requirement, it runs the same way on the host (for
//! `cargo test` and the `demod_wav` example, both of which need `std` only for file/Vec
//! plumbing outside this crate) and on the `riscv32imafc-unknown-none-elf` target.

#![no_std]

// Host tests need `std::vec::Vec` to hold whole test signals; the host test binary always links
// `std` regardless of this crate's own `#![no_std]`, this just makes it nameable from `tests`
// submodules below. Never used outside `#[cfg(test)]`.
#[cfg(test)]
extern crate std;

pub mod agc;
pub mod backend;
pub mod am;
pub mod blanker;
pub mod complex;
pub mod cw;
pub mod fastconv;
pub mod fft;
pub mod fmath;
pub mod fm;
pub mod nco;
pub mod nr;
pub mod resample;
pub mod ssb;
pub mod window;

pub use complex::C32;
