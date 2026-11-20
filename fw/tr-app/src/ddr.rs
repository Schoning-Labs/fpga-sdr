// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The board's DDR3 as the drivers' `FabricMem`: plain memory access, the Andes cache commands,
//! and waits counted on the fabric's 120 MHz cycle counter. That counter is used for the waits
//! because it is the one clock on the board whose frequency is certain, while the frequency of
//! the machine timer is not (docs/C1_AE350.md).

use tr_ae350::cctl;
use tr_fabric::mem::FabricMem;
use tr_regs::generated::system;
use tr_regs::Mmio;

/// The zero-sized handle the drivers receive. Memory is accessed by raw address, because the rings and buffers sit at
/// fixed addresses in DDR3.
pub struct Ddr;

impl FabricMem for Ddr {
    fn write32(&self, addr: u32, value: u32) {
        // SAFETY: the drivers only pass addresses inside the rings and buffers of
        // `tr_fabric::mem::map`, in the DDR3 range the linker script keeps free (DDR_FABRIC).
        unsafe { core::ptr::write_volatile(addr as *mut u32, value) }
    }

    fn read32(&self, addr: u32) -> u32 {
        // SAFETY: as `write32`.
        unsafe { core::ptr::read_volatile(addr as *const u32) }
    }

    fn writeback(&self, addr: u32, len: u32) {
        // SAFETY: AE350 only; writing back lines that are not dirty is harmless.
        unsafe { cctl::dcache_writeback(addr as usize, len as usize) }
    }

    fn invalidate(&self, addr: u32, len: u32) {
        // SAFETY: the ranges are logic-written rings the CPU never writes, so no dirty line is lost.
        unsafe { cctl::dcache_invalidate(addr as usize, len as usize) }
    }

    fn delay_us(&self, us: u32) {
        // Waits on the chip's FT8 engines come through here, so this is a point where the network and the input get served.
        tr_modes::yield_hook::call();
        let start = system::dsp_cycles::read(&Mmio);
        let ticks = us * 120; // 120 cycles of the 120 MHz counter per microsecond
        while system::dsp_cycles::read(&Mmio).wrapping_sub(start) < ticks {}
    }
}
