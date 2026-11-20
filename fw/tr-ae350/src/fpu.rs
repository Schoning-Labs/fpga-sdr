// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! FPU enable. This is plain RISC-V privileged-spec behavior and not an AE350-specific register:
//! `mstatus.FS` (bits 14:13) gates all F and D instructions, it resets to 0 (Off), and any such
//! instruction traps as an illegal instruction until software sets it to at least 1 (Initial).
//! MUG1031 3.1 confirms that the core implements F and D (single and double precision FPU). The
//! target this crate builds for (`riscv32imafc`) only emits F instructions, and `docs/BOARD.md`
//! ("Rust target") notes that no upstream RV32 target enables D, so double precision stays unused
//! by default even though the hardware has it.
//!
//! The enable works the same on every target and is exercised by the QEMU test script, because the
//! CPU of the QEMU `virt` machine implements F and D.

use core::arch::asm;

const MSTATUS_FS_INITIAL: usize = 0b01 << 13;

/// Sets `mstatus.FS` to Initial so F-extension instructions stop trapping. Must run before any
/// floating-point code (including code the compiler may emit implicitly, e.g. f32 in a
/// `Debug`/`Display` formatter).
///
/// # Safety
/// Must be called from machine mode before floating-point registers are touched; not reentrant
/// (though idempotent, calling it twice is harmless).
#[inline]
pub unsafe fn enable() {
    asm!("csrs mstatus, {0}", in(reg) MSTATUS_FS_INITIAL);
}

// There is no guard type that a trap handler has to open to keep its hands off the FPU. The
// custom `_start_trap` in `trap.rs` forces `mstatus.FS` to Off for every trap at the one shared
// entry point, so no handler needs extra code (and none can forget it). `trap.rs` has the details.
