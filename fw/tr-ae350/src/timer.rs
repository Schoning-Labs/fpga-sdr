// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Machine timer (`mtime` and `mtimecmp`, hart 0 only, since MUG1031 3.1 confirms a single Andes
//! A25 hart). The two boards put these registers at different offsets, so there are two small
//! implementations behind the `board-ae350` and `board-qemu` features, and both expose the same
//! `now()` and `arm_after(delta_ticks)` API that trap code, interrupt code and the QEMU test use.
//!
//! Interrupt wiring (the same on both boards): this is the RISC-V local machine-timer interrupt
//! (`mtip` in `mip` and `mie`, MUG1029 table 4-1) and it does not go through the PLIC, which only
//! carries `meip` and `seip` (MUG1029 4.1). The `#[core_interrupt(Interrupt::MachineTimer)]`
//! attribute of `riscv-rt` wires up the handler.

use core::ptr::{read_volatile, write_volatile};

#[cfg(feature = "board-ae350")]
mod backend {
    use super::*;
    use crate::board::ae350::TIMER_BASE;

    // MUG1029 chapter 15 (PLMT), Table 15-1: mtime lo/hi at +0x00/+0x04; mtimecmp0 (hart 0)
    // lo/hi at +0x08/+0x0C.
    const MTIME_LO: usize = TIMER_BASE;
    const MTIME_HI: usize = TIMER_BASE + 0x04;
    const MTIMECMP0_LO: usize = TIMER_BASE + 0x08;
    const MTIMECMP0_HI: usize = TIMER_BASE + 0x0C;

    pub fn now() -> u64 {
        read_split(MTIME_LO, MTIME_HI)
    }
    pub fn set_compare(value: u64) {
        write_split(MTIMECMP0_LO, MTIMECMP0_HI, value);
    }
}

#[cfg(feature = "board-qemu")]
mod backend {
    use super::*;
    use crate::board::qemu::CLINT_BASE;

    // Standard SiFive CLINT layout (QEMU hw/riscv/virt.c `VIRT_CLINT`): `mtimecmp0` (hart 0) is a
    // single 8-byte register at +0x4000 and `mtime` is a single 8-byte register at +0xBFF8. Each is
    // a little-endian u64, so the lo and hi halves sit at the register address and at +4, which is
    // exactly what `read_split` and `write_split` assume, because both boards are little-endian
    // RV32 (the AE350's PLMT splits its registers the same way, only at different offsets).
    const MTIME_LO: usize = CLINT_BASE + 0xBFF8;
    const MTIME_HI: usize = CLINT_BASE + 0xBFFC;
    const MTIMECMP0_LO: usize = CLINT_BASE + 0x4000;
    const MTIMECMP0_HI: usize = CLINT_BASE + 0x4004;

    pub fn now() -> u64 {
        read_split(MTIME_LO, MTIME_HI)
    }
    pub fn set_compare(value: u64) {
        write_split(MTIMECMP0_LO, MTIMECMP0_HI, value);
    }
}

/// Race-free 64-bit read of a lo/hi register pair on a 32-bit core (standard RISC-V idiom: read
/// hi, read lo, read hi again, retry if hi changed under us, mtime can tick between the two
/// reads).
fn read_split(lo_addr: usize, hi_addr: usize) -> u64 {
    loop {
        unsafe {
            let hi1 = read_volatile(hi_addr as *const u32);
            let lo = read_volatile(lo_addr as *const u32);
            let hi2 = read_volatile(hi_addr as *const u32);
            if hi1 == hi2 {
                return ((hi1 as u64) << 32) | lo as u64;
            }
        }
    }
}

/// Writes a 64-bit lo/hi register pair. Per the RISC-V privileged spec (and MUG1029 15.1.2:
/// "the timer interrupt input is de-asserted when this register is written"), mtimecmp writes
/// should set the high word to all-ones first so a stale low word can never briefly form a
/// smaller-than-intended comparison value that fires a spurious interrupt.
fn write_split(lo_addr: usize, hi_addr: usize, value: u64) {
    unsafe {
        write_volatile(hi_addr as *mut u32, u32::MAX);
        write_volatile(lo_addr as *mut u32, value as u32);
        write_volatile(hi_addr as *mut u32, (value >> 32) as u32);
    }
}

/// Current tick count.
pub fn now() -> u64 {
    backend::now()
}

/// Arms the timer to interrupt `delta_ticks` from now. Does not itself enable `mie.MTIE` or
/// `mstatus.MIE`, callers do that once, at start-up (see docs/C1_AE350.md).
pub fn arm_after(delta_ticks: u64) {
    backend::set_compare(now().wrapping_add(delta_ticks));
}

/// Pushes the compare value to the far future, which the RISC-V privileged spec guarantees
/// de-asserts the pending timer interrupt without needing to touch `mie`.
pub fn disarm() {
    backend::set_compare(u64::MAX);
}
