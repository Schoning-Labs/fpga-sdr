// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

#![no_std]

//! Register access for the fabric's memory-mapped register blocks (docs/ARCHITECTURE.md 4.1).
//!
//! Everything under [`generated`] is produced by `cargo run -p xtask -- regmap` from
//! `hw/regmap/*.toml` -- see `docs/REGMAP.md`, which documents the TOML format this crate
//! assumes. Do not hand-edit `src/generated.rs`; edit the TOML and regenerate.
//!
//! Every accessor is generic over [`RegisterSpace`], so the same generated code runs against
//! [`Mmio`] on the real AE350 target and against `mock::MockRegisterSpace` in host tests
//! (`fw/tr-regs/tests/`, gated behind the `mock` feature). That is how the check --
//! an iverilog testbench and a Rust test agreeing on every address and field of the sample
//! block -- works without real hardware.

pub mod generated;
#[cfg(feature = "mock")]
pub mod mock;

/// One 32-bit register read or write, on whatever backs a block's page: the real AHB bus on
/// the target, or a fake page of words in a host test. Every generated accessor in
/// [`generated`] is generic over this trait instead of touching memory directly.
pub trait RegisterSpace {
    fn read32(&self, addr: u32) -> u32;
    fn write32(&self, addr: u32, value: u32);
}

/// The real register space: `addr` is the absolute AHB address (docs/ARCHITECTURE.md 4.1,
/// `0xE800_0000` + 128 MB window). Only meaningful on the AE350 target -- on a PC these
/// addresses are not mapped, so host code uses `mock::MockRegisterSpace` instead.
pub struct Mmio;

impl RegisterSpace for Mmio {
    fn read32(&self, addr: u32) -> u32 {
        // SAFETY: callers only reach this through the generated accessors in `generated`,
        // which only ever pass addresses from a block's own TOML-derived address range, and
        // this type is only meant to be used on the AE350 target where that whole 128 MB
        // window is mapped I/O (docs/ARCHITECTURE.md 4.1).
        unsafe { core::ptr::read_volatile(addr as *const u32) }
    }

    fn write32(&self, addr: u32, value: u32) {
        // SAFETY: see `read32`.
        unsafe { core::ptr::write_volatile(addr as *mut u32, value) }
    }
}
