// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! PLIC (Platform-Level Interrupt Controller) driver for the standard RISC-V PLIC memory layout:
//!
//! ```text
//! priority[source]      base + 4 * source                (source = 1..=1023, 0 is reserved)
//! pending bitmap        base + 0x00_1000 + 4 * (source/32)
//! enable bitmap[ctx]    base + 0x00_2000 + 0x80 * ctx + 4 * (source/32)
//! threshold[ctx]        base + 0x20_0000 + 0x1000 * ctx
//! claim/complete[ctx]   base + 0x20_0004 + 0x1000 * ctx
//! ```
//!
//! This layout is the one QEMU's `virt` machine implements (its PLIC model is the standard
//! SiFive/RISC-V layout, wired as a generic `sifive_plic` at the PLIC base in `board.rs`, see
//! hw/riscv/virt.c in the QEMU sources). For the AE350 it is not independently confirmed:
//! MUG1031 3.1 says the core has a RISC-V PLIC with a configurable number of interrupts (1 to
//! 1023) and 15 priority levels, which matches the field widths of the standard spec, and MUG1029
//! 4.2 gives the interrupt source table (see `board.rs` and `docs/C1_AE350.md`), but neither
//! document spells out the register byte layout. Public Andes AE350 board support packages use
//! this same layout, so it is the one assumed here until it is read back on the board.

use crate::board::PlicLayout;
use core::ptr::{read_volatile, write_volatile};

const PRIORITY_OFFSET: usize = 0x00_0000;
const ENABLE_OFFSET: usize = 0x00_2000;
const ENABLE_CONTEXT_STRIDE: usize = 0x80;
const CONTEXT_OFFSET: usize = 0x20_0000;
const CONTEXT_STRIDE: usize = 0x1000;
const THRESHOLD_OFFSET: usize = 0x00; // within a context block
const CLAIM_COMPLETE_OFFSET: usize = 0x04; // within a context block

/// Driver for the PLIC of one board, reached through its [`PlicLayout`].
pub struct Plic {
    layout: &'static PlicLayout,
}

impl Plic {
    /// # Safety
    /// `layout` must describe a real standard-layout PLIC at that address; see the module-level
    /// note on AE350 verification status.
    pub const unsafe fn new(layout: &'static PlicLayout) -> Self {
        Plic { layout }
    }

    unsafe fn write32(&self, addr: usize, val: u32) {
        write_volatile(addr as *mut u32, val);
    }
    unsafe fn read32(&self, addr: usize) -> u32 {
        read_volatile(addr as *const u32)
    }

    /// Sets `source`'s priority (0 = never interrupts; MUG1031 3.1: 15 non-zero levels).
    pub fn set_priority(&self, source: u32, priority: u32) {
        unsafe {
            self.write32(
                self.layout.base + PRIORITY_OFFSET + 4 * source as usize,
                priority,
            )
        }
    }

    /// Reads a source's priority back (used by the QEMU smoke test to confirm the write above
    /// reached real, working registers rather than faulting silently or reading as zero).
    pub fn priority(&self, source: u32) -> u32 {
        unsafe { self.read32(self.layout.base + PRIORITY_OFFSET + 4 * source as usize) }
    }

    fn enable_addr(&self, source: u32) -> usize {
        self.layout.base
            + ENABLE_OFFSET
            + ENABLE_CONTEXT_STRIDE * self.layout.context
            + 4 * (source as usize / 32)
    }

    /// Enables `source` for this hart's M-mode context.
    pub fn enable(&self, source: u32) {
        let addr = self.enable_addr(source);
        let bit = 1u32 << (source % 32);
        unsafe { self.write32(addr, self.read32(addr) | bit) }
    }

    fn context_base(&self) -> usize {
        self.layout.base + CONTEXT_OFFSET + CONTEXT_STRIDE * self.layout.context
    }

    /// Interrupts with priority <= `threshold` are masked. 0 lets every non-zero-priority
    /// source through.
    pub fn set_threshold(&self, threshold: u32) {
        unsafe { self.write32(self.context_base() + THRESHOLD_OFFSET, threshold) }
    }

    /// Claims the highest-priority pending, enabled interrupt for this context. `0` means none
    /// pending. Must be followed by `complete()` with the same id once handled.
    pub fn claim(&self) -> u32 {
        unsafe { self.read32(self.context_base() + CLAIM_COMPLETE_OFFSET) }
    }

    /// Tells the PLIC that the interrupt `source`, as returned by [`Plic::claim`], is handled.
    pub fn complete(&self, source: u32) {
        unsafe { self.write32(self.context_base() + CLAIM_COMPLETE_OFFSET, source) }
    }
}

/// The board's one PLIC instance.
pub static PLIC: Plic = unsafe { Plic::new(&crate::board::active::PLIC) };
