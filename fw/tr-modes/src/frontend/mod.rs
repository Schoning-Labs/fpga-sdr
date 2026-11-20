// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! FT8 decoder front end: the bit-exact reference model of the three FPGA decoder engines
//! (spectrogram, Costas sync search and candidate engine, ARCHITECTURE 3.12) plus the CPU half
//! of the decoder that consumes their output.
//!
//! The fixed-point arithmetic here is the specification the RTL must reproduce word for word,
//! and `docs/ARCHITECTURE.md` 3.12 and `docs/S15_FT8MODEL.md` restate it in prose. Every fabric
//! stage also has a float twin with the same structure and no rounding, which is used to measure
//! what the fixed-point choices cost (the limit is 0.3 dB, see docs/S15_FT8MODEL.md 4.2).
//!
//! The letters in the first column are the stage names of ARCHITECTURE 3.12.
//!
//! | Stage | Where | Module |
//! |---|---|---|
//! | (b) spectrogram: 3,840-point transform of 1,920 samples every 480, power of bins 0..1,023 | FPGA | [`spectrogram`] (uses [`fft256`], the 256-point FFT) |
//! | (c) Costas sync search: per bin best lag and score, primary and secondary window | FPGA | [`sync`] |
//! | candidate list: 40th-percentile normalization, dt interpolation, de-duplication | CPU | [`candidates`] |
//! | (d) pass 1: NCO mix, CIC/30, 65-tap FIR/2, 3,200 samples at 200 sps | FPGA | [`baseband`] |
//! | fine time/frequency sync on the 200 sps baseband (mfsk-core `fine_refine_3stage`) | CPU | [`decode`] |
//! | (d) pass 2: rotate, 79 x 8 tone DFTs of 32 samples | FPGA | [`symbols`] |
//! | LLR, belief propagation, OSD, CRC, unpack (mfsk-core) | CPU | [`decode`] |
//! | signal subtraction, second pass | CPU | [`subtract`], [`decode`] |
//! | second pass: replay of the residual audio through (b) and (c) (docs/FT8_PASS2.md) | FPGA | [`replay`] |
//! | decode scheduler: per-slot job queue, CPU cap per receiver | CPU | [`sched`] |
//!
//! [`decode::Fabric`] is the seam between the two halves: the CPU code asks it for exactly
//! what the FPGA engines would deliver. [`decode::ModelFabric`] computes the answers with the
//! models here (fixed or float), and a recorded trace of those answers lets the CPU half run
//! alone under QEMU, which is how its instruction count is measured.

pub mod baseband;
pub mod candidates;
pub mod decode;
pub mod effort;
pub mod fft256;
pub mod replay;
pub mod spectrogram;
pub mod sched;
pub mod subtract;
pub mod symbols;
pub mod sync;
pub mod tables;
pub mod trace;

/// Audio sample rate into every engine (the back end's decoder output, 3.10).
pub const FS: u32 = 12_000;
/// Samples per FT8 slot (15 s).
pub const SLOT_LEN: usize = 180_000;
/// FT8 samples per symbol.
pub const NSPS: usize = 1_920;
/// Spectrogram frame step, a quarter symbol (WSJT-X `NSTEP`).
pub const NSTEP: usize = 480;
/// Spectrogram transform length, `2 * NSPS` = 256 x 15.
pub const NFFT: usize = 3_840;
/// Spectrogram frames per slot (WSJT-X `NHSYM` = 180,000 / 480 - 3).
pub const N_TIME: usize = SLOT_LEN / NSTEP - 3;
/// Spectrogram bins the engine keeps: 0 .. 1,023 (0 to 3,196.9 Hz, 3.125 Hz apart).
pub const K_BINS: usize = 1_024;
/// Bin width of the spectrogram, Hz (exactly 3.125).
pub const DF_HZ: f32 = FS as f32 / NFFT as f32;
/// FT8 symbols per message.
pub const NN: usize = 79;
/// FT8 tones.
pub const NTONES: usize = 8;
/// FT8 tone spacing, Hz.
pub const TONE_HZ: f32 = 6.25;
/// The Costas array: tone sent at each of the 7 positions of a sync block.
pub const COSTAS: [usize; 7] = [3, 1, 4, 0, 6, 5, 2];
/// Symbol index at which each of the three Costas blocks starts.
pub const COSTAS_POS: [usize; 3] = [0, 36, 72];
/// Baseband sample rate of the candidate engine, samples per second.
pub const BB_RATE: u32 = 200;
/// Baseband samples per FT8 symbol (`BB_RATE` x 0.16 s).
pub const BB_SPS: usize = 32;
/// Baseband samples per candidate (16 s at 200 sps, as WSJT-X `NP2`).
pub const BB_LEN: usize = 3_200;
/// The candidate engine centers the signal: its NCO sits at the tone 0 frequency plus 3.5 tone
/// spacings, Hz.
pub const CENTRE_OFFSET_HZ: f32 = 21.875;

/// Which arithmetic a fabric model uses.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Arith {
    /// Bit-exact fixed point, as the three FPGA engines implement it.
    Fixed,
    /// Same structure in `f64`, nothing rounded or saturated (the reference for the 0.3 dB test).
    Float,
}
