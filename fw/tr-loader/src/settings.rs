// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The settings sector (`layout::SETTINGS_CHIP`, `layout::SETTINGS_SIZE`) holds one small record that
//! says which of the two image slots (A or B, `layout::slot_chip`) a normal boot should load. This is
//! the usual A/B pattern for firmware updates: a new image is always written to the *inactive* slot
//! (`handle_flash_write` in `bin/stage0.rs`), and the old slot stops being used only once the new
//! image has been written, read back and verified (`flash::program_image`) and this record has been
//! changed to point at it. A write that fails part way through (a power loss, a bad page) therefore
//! leaves the slot that worked before untouched and still bootable.
//!
//! Reading goes through `flash::read_chip` (the memory-mapped window while it agrees with the chip, and
//! read commands otherwise), and only writing needs the manual SPI primitives of
//! `flash::write_settings`. The sector lies at `layout::SETTINGS_CHIP`, above the bitstream and the
//! loader.
//!
//! The module exists for the real board only, like its sibling `flash.rs`, and is not compiled
//! under `board-qemu`.

use crate::{flash, layout};
use tr_image::crc32;

/// Distinct from `tr_image::MAGIC` ("TRLD") so the settings sector and an image header cannot be
/// mistaken for one another even if a bug ever pointed one reader at the other's address.
const MAGIC: u32 = u32::from_le_bytes(*b"TRST");

/// magic(4) + active_slot(1) + reserved(3, must be 0) + crc32(4). The CRC covers the first 8 bytes.
const RECORD_LEN: usize = 12;

/// The contents of the settings sector.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Settings {
    /// 0 means slot A and 1 means slot B. The loader only ever stores one of these two values, and
    /// `layout::slot_chip` treats any non-zero value as B.
    pub active_slot: u8,
}

impl Settings {
    /// Reads and validates the record at the start of the settings sector. `None` means that
    /// there are no settings yet, either because the sector is still erased (all `0xFF`, since
    /// nothing has been programmed there) or because its magic or CRC do not match. That is not
    /// treated as an error: the normal-boot path in `bin/stage0.rs` falls back to slot A when
    /// this returns `None`.
    pub fn read() -> Option<Settings> {
        let mut buf = [0u8; RECORD_LEN];
        if !flash::read_chip(layout::SETTINGS_CHIP, &mut buf) {
            return None;
        }
        let bytes = &buf[..];
        if bytes.iter().all(|&b| b == 0xFF) {
            return None;
        }
        let magic = u32::from_le_bytes(bytes[0..4].try_into().unwrap());
        if magic != MAGIC {
            return None;
        }
        let stored_crc = u32::from_le_bytes(bytes[8..12].try_into().unwrap());
        if crc32(&bytes[0..8]) != stored_crc {
            return None;
        }
        Some(Settings { active_slot: bytes[4] })
    }

    /// The 12-byte on-flash form of the record, with its CRC filled in.
    fn to_bytes(self) -> [u8; RECORD_LEN] {
        let mut buf = [0u8; RECORD_LEN];
        buf[0..4].copy_from_slice(&MAGIC.to_le_bytes());
        buf[4] = self.active_slot;
        // buf[5..8] left 0 (reserved).
        let crc = crc32(&buf[0..8]);
        buf[8..12].copy_from_slice(&crc.to_le_bytes());
        buf
    }

    /// Erases the settings sector and writes this record (read back; the error says what failed).
    pub fn write(self) -> Result<(), flash::ProgramError> {
        flash::write_settings(&self.to_bytes())
    }
}
