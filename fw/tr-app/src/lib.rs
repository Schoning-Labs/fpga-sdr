// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

#![no_std]

//! `tr-app`: the firmware binaries, `no_std` and built only for riscv32imafc-unknown-none-elf
//! (docs/P2_FT8_FW.md). `ft8fw` is the firmware for the board, and `ft8fw_qemu` runs the same
//! station, radio, driver, encoder, decoder and screen code under QEMU against a simulated
//! fabric. Everything the two share beyond the library crates is in this library: the heap, the
//! atomic operations, the Slint screen on a frame buffer, the network glue (RJ45 unit, SFP
//! cages, the PC's mouse and keyboard) and, on the board only, DDR3 access with the cache
//! commands.

extern crate alloc;

/// Atomic operations for a processor without the A extension.
pub mod atomics;
#[cfg(feature = "board-ae350")]
/// The board's DDR3 as the drivers' memory.
pub mod ddr;
/// The global allocator.
pub mod heap;
/// The Slint screen on a frame buffer.
pub mod screen;
/// The PC's mouse and keyboard on the screen.
pub mod netinput;
/// Network time and the service socket on the RJ45 unit.
pub mod rj45net;
/// The SFP cages in the main loop.
pub mod sfplane;
