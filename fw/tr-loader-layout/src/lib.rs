// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

#![cfg_attr(not(test), no_std)]

//! Where everything lies in the one flash chip, how the processor's flash address maps onto it, and the
//! guard that keeps every erase and write away from the FPGA bitstream (docs/C2_LOADER.md "Flash
//! layout").
//!
//! The crate is `no_std` and has no hardware access, which is why it exists apart from `tr-loader`:
//! the stage-0 loader's real flash driver and the model chip in this crate's host tests both implement
//! the [`Chip`] trait and therefore run exactly the same erase and write loops and the same guard, and
//! the guard can be tested on a PC against a model of the whole chip.
//!
//! **One chip holds the bitstream and the processor's program.** Gowin's own procedure writes the
//! bitstream at chip offset 0 and the processor's program at 0x60_0000 (MUG1030 2.6.8 and 3.4.5);
//! a bitstream is 5.04 MiB, so it fits below 0x60_0000. The loader's image slots therefore have to lie at or above 0x60_0000, since anything
//! below that is FPGA configuration and the first write there would erase it.
//!
//! **Two address spaces, never mixed.** A *chip address* is what the flash chip itself is given (the
//! address bytes of read, program and erase commands). A *CPU address* is what the processor loads from
//! (memory-mapped, execute in place). The mapping is `CPU = FLASH_BASE + (chip - MAP_CHIP)`: the
//! processor's 0x8000_0000 is chip offset 0x60_0000. That is an inference from Gowin's procedure (the
//! stage-0 loader is written at 0x60_0000 and runs from 0x8000_0000) and not a figure from a manual, so
//! the loader checks it at start-up against the chip (`flash::init` in `tr-loader`) and says on the
//! console whether it holds.
//! Every write and every erase uses chip addresses and is checked by [`write_allowed`]; reading uses the
//! mapping only while that check has passed, and the chip's read command otherwise.
//!
//! Layout (chip addresses):
//!
//! | Region | Chip offset | Size |
//! |---|---|---|
//! | FPGA bitstream (Gowin programmer only) | 0x00_0000 | 6 MiB (bitstream 5.04 MiB) |
//! | Stage-0 loader (Gowin programmer only) | 0x60_0000 | 64 KiB |
//! | Image slot A | 0x61_0000 | 4 MiB |
//! | Image slot B | 0xA1_0000 | 4 MiB |
//! | Settings sector (active slot) | 0xE1_0000 | 64 KiB |
//! | free | 0xE2_0000 | 1.87 MiB |
//!
//! The loader writes only the slots and the settings sector: the program area
//! [`PROGRAM_AREA_START`]`..`[`PROGRAM_AREA_END`]. It never rewrites itself or the bitstream.

/// The processor's reset vector and the base of its memory-mapped flash window (MUG1029 table 16-12).
pub const FLASH_BASE: u32 = 0x8000_0000;
/// Size of the processor's flash window (docs/BOARD.md: instruction memory 0x8000_0000 to 0x8FFF_FFFF).
pub const FLASH_WINDOW: u32 = 0x1000_0000;
/// Chip address that appears at [`FLASH_BASE`] (see the module text: inferred, checked at start-up).
pub const MAP_CHIP: u32 = 0x60_0000;

/// One 128 Mbit = 16 MiB SPI NOR chip (docs/BOARD.md; part number not read yet: the loader prints the
/// chip's JEDEC ID).
pub const FLASH_SIZE: u32 = 16 * 1024 * 1024;

/// The bitstream's place ends here. A bitstream for this chip is about 5.3 MB uncompressed (5,283,212
/// bytes for one example), which leaves room to grow.
pub const BITSTREAM_END: u32 = 0x60_0000;
/// The stage-0 loader (the processor's reset code), written by the Gowin programmer.
pub const STAGE0_CHIP: u32 = 0x60_0000;
/// Must equal the `FLASH` `LENGTH` in `memory-loader-ae350.x` (a test reads that file).
pub const STAGE0_SIZE: u32 = 0x1_0000;

/// Size of each image slot: header plus program. 4 MiB is generous (no flash-resident program of this
/// project has been measured, and one instrument program on this chip is 1.2 MB), so it is worth
/// revisiting once the size of the real `tr-app` image is known.
pub const SLOT_SIZE: u32 = 4 * 1024 * 1024;
/// Image slot A, directly behind the loader.
pub const SLOT_A_CHIP: u32 = STAGE0_CHIP + STAGE0_SIZE;
/// Image slot B, directly behind slot A.
pub const SLOT_B_CHIP: u32 = SLOT_A_CHIP + SLOT_SIZE;
/// The settings sector: one 64 KiB erase block (the largest block any common SPI NOR part has).
pub const SETTINGS_CHIP: u32 = SLOT_B_CHIP + SLOT_SIZE;
/// Size of the settings sector, one erase block.
pub const SETTINGS_SIZE: u32 = 64 * 1024;

/// The only chip range the loader may erase or program.
pub const PROGRAM_AREA_START: u32 = SLOT_A_CHIP;
/// End (exclusive) of the program area, which is the end of the settings sector.
pub const PROGRAM_AREA_END: u32 = SETTINGS_CHIP + SETTINGS_SIZE;

/// Erase block (opcode 0xD8) and program page of the chip (universal for SPI NOR).
pub const ERASE_BLOCK: u32 = 64 * 1024;
/// Program page: one program command must not cross a 256-byte boundary.
pub const PAGE: u32 = 256;

// Compile-time checks of the layout above: the regions are ordered and do not overlap, the program
// area starts and ends on erase blocks and lies inside the chip, and the whole of it lies inside the
// processor's memory-mapped window (so it can be read by ordinary loads). A change to a constant that
// breaks one of these stops the build.
const _LAYOUT: () = {
    assert!(BITSTREAM_END <= STAGE0_CHIP);
    assert!(STAGE0_CHIP + STAGE0_SIZE == SLOT_A_CHIP);
    assert!(PROGRAM_AREA_START % ERASE_BLOCK == 0);
    assert!(PROGRAM_AREA_END as u64 <= FLASH_SIZE as u64);
    assert!(SLOT_SIZE % ERASE_BLOCK == 0 && SETTINGS_SIZE % ERASE_BLOCK == 0);
    assert!(SETTINGS_CHIP + SETTINGS_SIZE - MAP_CHIP <= FLASH_WINDOW);
};

/// Chip address of image slot `slot` (0 = A; anything else is B).
pub const fn slot_chip(slot: u8) -> u32 {
    if slot == 0 {
        SLOT_A_CHIP
    } else {
        SLOT_B_CHIP
    }
}

/// The processor's address of chip address `chip`; `None` when the chip address is below the window.
pub const fn xip_addr(chip: u32) -> Option<u32> {
    if chip < MAP_CHIP {
        None
    } else {
        Some(FLASH_BASE + (chip - MAP_CHIP))
    }
}

/// The chip address behind the processor's flash address `cpu`; `None` outside the window.
pub const fn chip_of_xip(cpu: u32) -> Option<u32> {
    if cpu < FLASH_BASE || cpu - FLASH_BASE >= FLASH_WINDOW {
        None
    } else {
        Some(MAP_CHIP + (cpu - FLASH_BASE))
    }
}

/// The write guard: `len` bytes from chip address `chip` lie wholly in the program area (and `len` is not
/// 0). The arithmetic is arranged so it cannot overflow: an address near `u32::MAX` is refused and
/// does not wrap around into the allowed range.
#[inline(always)]
pub const fn write_allowed(chip: u32, len: u32) -> bool {
    len != 0 && chip >= PROGRAM_AREA_START && chip <= PROGRAM_AREA_END && len <= PROGRAM_AREA_END - chip
}

/// The erase guard: `chip` starts an erase block and the whole block lies in the program area.
#[inline(always)]
pub const fn erase_allowed(chip: u32) -> bool {
    chip % ERASE_BLOCK == 0 && write_allowed(chip, ERASE_BLOCK)
}

/// What the chip must offer to [`erase_region`] and [`write_region`]. The real driver
/// (`tr-loader/src/flash.rs`) and the tests' model chip both implement it; both therefore run the same
/// loops and the same guard.
pub trait Chip {
    /// Erases the block starting at `chip`. Returns false when the chip did not do it.
    fn erase_block(&mut self, chip: u32) -> bool;
    /// Programs `data` (not past a page end) at `chip`. Returns false when the chip did not do it.
    fn program(&mut self, chip: u32, data: &[u8]) -> bool;
}

/// Why a write or erase did not happen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WriteError {
    /// The guard refused the range: it is not wholly in the program area.
    Refused { chip: u32, len: u32 },
    /// The chip did not carry out the operation at this chip address.
    Chip { chip: u32 },
}

/// Erases the blocks covering `len` bytes from `chip` (`chip` block-aligned). The whole range is
/// checked by [`write_allowed`] first and every block again by [`erase_allowed`] just before it is
/// erased, so nothing outside the program area is ever erased, and a refused range erases nothing.
pub fn erase_region<C: Chip>(c: &mut C, chip: u32, len: u32) -> Result<(), WriteError> {
    if !write_allowed(chip, len) {
        return Err(WriteError::Refused { chip, len });
    }
    // `chip + len` cannot overflow here because write_allowed has just shown the range to be
    // inside the program area.
    let mut a = chip;
    let end = chip + len;
    while a < end {
        if !erase_allowed(a) {
            return Err(WriteError::Refused { chip: a, len: ERASE_BLOCK });
        }
        if !c.erase_block(a) {
            return Err(WriteError::Chip { chip: a });
        }
        a += ERASE_BLOCK;
    }
    Ok(())
}

/// Programs `data` from chip address `chip` in pieces of at most `max_chunk` bytes that never cross a
/// page. The whole range is checked by [`write_allowed`] first; nothing is written when it is refused.
pub fn write_region<C: Chip>(c: &mut C, chip: u32, data: &[u8], max_chunk: usize) -> Result<(), WriteError> {
    if data.is_empty() {
        return Ok(());
    }
    let len = data.len() as u32;
    if data.len() > u32::MAX as usize || !write_allowed(chip, len) {
        return Err(WriteError::Refused { chip, len });
    }
    // Each piece is the smallest of what is left, the caller's chunk limit (which follows the
    // controller's FIFO size) and the distance to the next page boundary, because a program
    // command that crosses a page wraps around inside the page on a SPI NOR chip.
    let mut addr = chip;
    let mut rest = data;
    while !rest.is_empty() {
        let to_page_end = (PAGE - addr % PAGE) as usize;
        let n = rest.len().min(max_chunk.max(1)).min(to_page_end);
        if !c.program(addr, &rest[..n]) {
            return Err(WriteError::Chip { chip: addr });
        }
        addr += n as u32;
        rest = &rest[n..];
    }
    Ok(())
}

/// Stores an image in a slot: erases the blocks for `header + body` at `chip`, writes `body` first
/// and `header` last, so a write that is cut off leaves no image that looks valid. `chip` must be
/// a slot start, the image must fit the slot.
pub fn store_image<C: Chip>(c: &mut C, chip: u32, header: &[u8], body: &[u8], max_chunk: usize) -> Result<(), WriteError> {
    let total = header.len() as u64 + body.len() as u64;
    if (chip != SLOT_A_CHIP && chip != SLOT_B_CHIP) || total > SLOT_SIZE as u64 {
        return Err(WriteError::Refused { chip, len: total.min(u32::MAX as u64) as u32 });
    }
    // Whole erase blocks, at least one, covering header and body together.
    let blocks = (total as u32).div_ceil(ERASE_BLOCK).max(1);
    erase_region(c, chip, blocks * ERASE_BLOCK)?;
    write_region(c, chip + header.len() as u32, body, max_chunk)?;
    write_region(c, chip, header, max_chunk)
}

// Host tests, in tests.rs.
#[cfg(test)]
mod tests;
