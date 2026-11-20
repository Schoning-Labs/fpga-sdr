// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The flash layout (stage-0 loader, two image slots and a settings sector), the mapping between
//! chip addresses and the processor's addresses, and the write guard all live in the host-tested
//! crate `tr-loader-layout` (docs/C2_LOADER.md "Flash layout"). This module re-exports them and adds
//! the one thing that differs between the boards, the RAM window that a received image's
//! `load_addr` and `length` are checked against before a single payload byte is written.
//!
//! Every flash offset in the layout is a *chip address* at or above 0x60_0000, because the flash is
//! one chip that also holds the FPGA bitstream from offset 0 and the loader must never write there.
//! Use [`slot_chip`] to get the chip address of a slot and [`xip_addr`] to get the address the
//! processor reads it at.

pub use tr_loader_layout::*;

/// Where a received image is copied to and executed from, and the largest `length` accepted,
/// which differs per board like every other address in this crate's dependency
/// `tr_ae350::board`.
#[cfg(feature = "board-ae350")]
pub mod ae350 {
    /// docs/ARCHITECTURE.md 5.4: "DDR3 0x0000_0000-0x00FF_FFFF firmware code, data, bss (16 MB)".
    /// A received or flashed image's header is checked against this window and not against the whole
    /// 1 GB of DDR3 (BOARD.md), so a corrupted `load_addr` cannot reach the heap, the framebuffer
    /// or the ring-buffer regions that ARCHITECTURE.md 5.4 also lists in that address space.
    pub const DEST_BASE: u32 = 0x0000_0000;
    /// Size of the window, 16 MB.
    pub const DEST_LEN: u32 = 16 * 1024 * 1024;
}

/// QEMU has no flash model (docs/C2_LOADER.md "What ran under QEMU vs. what did not"), and the
/// UART loader test only receives an image into RAM and jumps to it. The window is therefore a piece
/// of QEMU `virt` RAM (backed by `-m`, see tools/qemu_c2.sh) well away from the loader's own code
/// (`memory-loader-qemu.x`: 0x8000_0000, 4 MiB), so a received test payload cannot overwrite the
/// loader while it is still running.
#[cfg(feature = "board-qemu")]
pub mod qemu {
    /// Start of the window, just above the loader's own 4 MiB.
    pub const DEST_BASE: u32 = 0x8040_0000;
    /// Size of the window, 4 MiB.
    pub const DEST_LEN: u32 = 4 * 1024 * 1024;
}

// The two constants of whichever board is compiled in, under one name for the rest of the crate.
#[cfg(feature = "board-ae350")]
pub use ae350::{DEST_BASE, DEST_LEN};
#[cfg(feature = "board-qemu")]
pub use qemu::{DEST_BASE, DEST_LEN};
