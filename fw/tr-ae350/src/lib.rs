// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

#![no_std]

//! AE350 start-up, trap handling, PLIC, machine timer, UART, CCTL cache operations and FPU enable.
//! The crate is `no_std` and runs only on `riscv32imafc-unknown-none-elf`, so there is no host
//! build (see `default-members` in `fw/Cargo.toml`).
//!
//! Every register fact used here and its source (MUG1029, MUG1031, or "not in either document,
//! taken from elsewhere and worth confirming on the board") is listed in `docs/C1_AE350.md`, and
//! the doc comment of each module below gives the short version.
//!
//! The board is chosen with a Cargo feature, `board-ae350` (the default) or `board-qemu`, and not
//! at run time, so exactly one of them is compiled in (see `board.rs`). Start-up itself (the reset
//! vector, the `.data` and `.bss` initialization and the jump to `main`) comes from the `riscv-rt`
//! crate and is not written by hand here. `docs/C1_AE350.md` gives the reasons, and
//! `memory-ae350.x`, `memory-qemu.x` and `build.rs` show how the linker script of that crate is
//! tied to the memory map in `docs/ARCHITECTURE.md`.

pub mod board;
#[cfg(feature = "board-ae350")]
pub mod cctl;
pub mod fpu;
pub mod memprobe;
pub mod plic;
pub mod timer;
mod trap;
pub mod uart;

/// Re-exports of the `riscv-rt` and `riscv` items that the trap handlers of a firmware binary
/// need. The handlers (`#[exception(...)]` and `#[core_interrupt(...)]`) have to live in the
/// binary crate and not in this one (see `docs/C1_AE350.md`), so a binary only has to write
/// `use tr_ae350::rt::*;` to get `entry`, `exception`, `core_interrupt`, `TrapFrame`, `Exception`
/// and `Interrupt`.
pub mod rt {
    pub use riscv::interrupt::{Exception, Interrupt};
    pub use riscv_rt::{core_interrupt, entry, exception, TrapFrame};
}

/// Reads `mcause`, the trap-cause CSR (RISC-V privileged spec, not AE350-specific). Exception
/// handlers use it to report what happened, for example in the QEMU smoke test of the
/// illegal-instruction trap.
#[inline]
pub fn mcause() -> usize {
    let value: usize;
    unsafe { core::arch::asm!("csrr {0}, mcause", out(reg) value) };
    value
}

/// Reads `mepc`, the PC at the trapping instruction.
#[inline]
pub fn mepc() -> usize {
    let value: usize;
    unsafe { core::arch::asm!("csrr {0}, mepc", out(reg) value) };
    value
}

/// Enables the machine timer interrupt (`mie.MTIE`, RISC-V bit 7) and global machine-mode
/// interrupts (`mstatus.MIE`, bit 3). Both are standard privileged-spec bits, not AE350-specific.
///
/// # Safety
/// A `#[core_interrupt(Interrupt::MachineTimer)]` handler must already be defined in the calling
/// binary (riscv-rt routes the trap there once this is called); calling this before `timer::
/// arm_after()` will fire on whatever stale `mtimecmp` value is currently set.
#[inline]
pub unsafe fn enable_timer_interrupt() {
    core::arch::asm!("csrs mie, {0}", in(reg) 1usize << 7);
    core::arch::asm!("csrs mstatus, {0}", in(reg) 1usize << 3);
}

/// A single instruction that is guaranteed to be illegal. An all-zero word is reserved and traps
/// as an illegal instruction on every RISC-V implementation, with or without the compressed
/// extension (see the section on the illegal instruction encoding in the RISC-V unprivileged
/// spec). It is used by the QEMU trap test, and it is kept here so the question of whether it is
/// really illegal in both the compressed and the normal decode only has to be answered once.
#[inline(always)]
pub fn illegal_instruction() {
    unsafe { core::arch::asm!(".word 0x00000000") };
}
