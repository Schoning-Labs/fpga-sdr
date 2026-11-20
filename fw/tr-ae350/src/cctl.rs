// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Andes CCTL cache control: enabling the L1 instruction and data caches and issuing per-address
//! invalidate and write-back operations. `docs/ARCHITECTURE.md` (4.2) describes where they are
//! needed: the firmware invalidates the D-cache lines of new data (the Andes CCTL command
//! `L1D_VA_INVAL`) before reading what the fabric wrote, and it writes back the lines of a ring that
//! the CPU wrote (`L1D_VA_WB`) before moving the write pointer.
//!
//! The module exists only on the AE350 and not under `board-qemu`. The generic RV32 CPU model of
//! the QEMU `virt` machine has none of the custom machine CSRs of Andes (`mcache_ctl`,
//! `mcctlbeginaddr` and `mcctlcommand` do not exist there), so any instruction in this file would
//! itself take an illegal-instruction trap, and there is nothing target-independent here for the
//! QEMU test script to run.
//!
//! Register and command facts taken from MUG1029:
//! - Cache Control Register bit layout: 6.2, table 6-3 (`IC_EN` bit 0, `DC_EN` bit 1,
//!   `IC_ECCEN` bits 3:2, `DC_ECCEN` bits 5:4, `EC_RWECC` bit 6, `DC_RWECC` bit 7, `IC_FIRST_WORLD`
//!   bit 8 (read only), `CCTL_SUEN` bit 11).
//! - CCTL command encoding: 6.3, table 6-4 (the indexes used below are 0 = `L1D_VA_INVAL`,
//!   1 = `L1D_VA_WB`, 6 = `L1D_WBINVAL_ALL`, 7 = `L1D_WB_ALL`, 23 = `L1D_INVAL_ALL`).
//!
//! Not stated in MUG1029 or MUG1031, which document what the registers mean and never give their
//! CSR numbers: the Cache Control Register of table 6-3 is the custom CSR `mcache_ctl`, and a CCTL
//! command is issued by writing the target address to `mcctlbeginaddr` and then the command index
//! to `mcctlcommand`. Both come from the public Andes V5 CSR references (the same way the Andes
//! platform code of OpenSBI and U-Boot uses them) and not from a document that `docs/BOARD.md`
//! cites. Reading `micm_cfg` and `mdcm_cfg` first (the application example in MUG1029 27.18 prints
//! them as a check that CSR access works at all) is a cheap way to confirm them on the board.

use core::arch::asm;

const CSR_MCACHE_CTL: u32 = 0x7CA;  // Cache Control Register, from the Andes V5 CSR references (see the module docs).
const CSR_MCCTLBEGINADDR: u32 = 0x7CB;  // Start address of a CCTL command, same source.
const CSR_MCCTLCOMMAND: u32 = 0x7CC;  // CCTL command register, same source.

const CACHE_CTL_IC_EN: u32 = 1 << 0;
const CACHE_CTL_DC_EN: u32 = 1 << 1;

// MUG1029 Table 6-4.
const CMD_L1D_VA_INVAL: u32 = 0;
const CMD_L1D_VA_WB: u32 = 1;
const CMD_L1D_WBINVAL_ALL: u32 = 6;
const CMD_L1D_WB_ALL: u32 = 7;
const CMD_L1D_INVAL_ALL: u32 = 23;

// `asm!`'s `csr` operand class needs a value known at compile time, so the CSR number is a
// const generic parameter (`csrrs::<CSR_MCACHE_CTL>(...)`) rather than a runtime argument.
#[inline]
unsafe fn csrrs<const CSR: u32>(set: u32) -> u32 {
    let out: u32;
    asm!("csrrs {0}, {csr}, {1}", out(reg) out, in(reg) set, csr = const CSR);
    out
}

#[inline]
unsafe fn csrrw<const CSR: u32>(val: u32) {
    asm!("csrrw x0, {csr}, {0}", in(reg) val, csr = const CSR);
}

/// Enables the L1 instruction and data caches (`IC_EN`, `DC_EN` in the Cache Control Register).
///
/// # Safety
/// AE350 only; must run once at start-up before relying on cached memory being coherent with the
/// assumptions the rest of the firmware makes (ARCHITECTURE.md 4.2: fabric rings are kept
/// coherent by explicit CCTL calls, not hardware snooping).
pub unsafe fn enable_caches() {
    csrrs::<CSR_MCACHE_CTL>(CACHE_CTL_IC_EN | CACHE_CTL_DC_EN);
}

unsafe fn issue_va_command(addr: usize, command: u32) {
    csrrw::<CSR_MCCTLBEGINADDR>(addr as u32);
    csrrw::<CSR_MCCTLCOMMAND>(command);
}

/// Invalidates the D-cache line(s) covering `[addr, addr+len)` without writing them back first.
/// This is for use before reading a fabric-written ring (ARCHITECTURE.md 4.2), so stale cached data is
/// not read back instead of what the fabric wrote to DDR3.
///
/// # Safety
/// `addr`/`len` must describe memory the caller is not concurrently relying on still holding
/// unwritten-back CPU data (this discards, it does not flush).
pub unsafe fn dcache_invalidate(addr: usize, len: usize) {
    for_each_line(addr, len, |line| issue_va_command(line, CMD_L1D_VA_INVAL));
}

/// Writes back the D-cache line(s) covering `[addr, addr+len)` to memory without invalidating --
/// use before moving a CPU-written ring's write pointer (ARCHITECTURE.md 4.2), so the fabric
/// reads the CPU's data rather than stale DDR3 contents.
///
/// # Safety
/// See `dcache_invalidate`.
pub unsafe fn dcache_writeback(addr: usize, len: usize) {
    for_each_line(addr, len, |line| issue_va_command(line, CMD_L1D_VA_WB));
}

/// Whole-D-cache write-back + invalidate (MUG1029 Table 6-4 command 6), e.g. before disabling
/// the cache.
///
/// # Safety
/// AE350 only (see module docs); must not run concurrently with anything relying on cached data
/// remaining valid.
pub unsafe fn dcache_writeback_invalidate_all() {
    csrrw::<CSR_MCCTLCOMMAND>(CMD_L1D_WBINVAL_ALL);
}

/// Whole-D-cache write-back without invalidating (command 7).
///
/// # Safety
/// AE350 only (see module docs).
pub unsafe fn dcache_writeback_all() {
    csrrw::<CSR_MCCTLCOMMAND>(CMD_L1D_WB_ALL);
}

/// Whole-D-cache invalidate without writing back (command 23), only safe when nothing cached
/// is dirty, e.g. immediately after `enable_caches()`.
///
/// # Safety
/// AE350 only (see module docs); discards any dirty cache lines instead of writing them back.
pub unsafe fn dcache_invalidate_all() {
    csrrw::<CSR_MCCTLCOMMAND>(CMD_L1D_INVAL_ALL);
}

/// D-cache line size (MUG1029 Table 6-2: 32 bytes).
const DCACHE_LINE: usize = 32;

fn for_each_line(addr: usize, len: usize, mut f: impl FnMut(usize)) {
    let start = addr & !(DCACHE_LINE - 1);
    let end = (addr + len + DCACHE_LINE - 1) & !(DCACHE_LINE - 1);
    let mut line = start;
    while line < end {
        f(line);
        line += DCACHE_LINE;
    }
}
