// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// The flash driver of the loader: the transfer routine, the bounded waits and the JEDEC and write-enable checks.
// It has two image slots and a settings sector, the shared write and
// erase loops and guard of `tr-loader-layout`, and reads through the memory-mapped window only when
// the start-up check found that it agrees with the chip.

//! AE350 SPI flash controller driver: standard SPI NOR opcodes (JEDEC id, write-enable, read-status, read,
//! page-program, 64 KiB block-erase) driven through the AE350's SPI master-mode registers. Register offsets
//! and the master-mode transfer protocol (Command/Address/Data/TransCtrl registers) are from MUG1029
//! chapter 10 "SPI" (docs/C2_LOADER.md "AE350 SPI controller"). The flash-side opcodes are the industry
//! standard SPI NOR set, and no particular chip is assumed: the loader prints the chip's JEDEC id when it
//! starts.
//!
//! This module is for the real board only and does not exist at all under `board-qemu`.
//!
//! ## What the driver guarantees (docs/C2_LOADER.md)
//!
//! - **Nothing below the program area is ever erased or programmed.** All offsets here are *chip
//!   addresses* (`layout`); [`xfer`], the one function that sends a command to the chip, refuses a
//!   program or erase command outside `layout::PROGRAM_AREA_START..PROGRAM_AREA_END`, and the loops that
//!   call it (`layout::store_image`, `erase_region`, `write_region`) check the whole range first. The
//!   bitstream (chip offset 0 up to 0x60_0000) and this loader (0x60_0000) are written by the Gowin
//!   programmer only.
//! - **A transfer holds at most as many bytes as the controller's FIFO** (configuration register 0x7C,
//!   MUG1029 table 10-21: depth "configuration dependent", from 2 words), because putting a whole
//!   256-byte page into the FIFO before starting the transfer would lose bytes on a short FIFO.
//! - Write enable is checked (status bit 1) before every program and erase, every wait is bounded, the
//!   header of an image is programmed last and the slot is verified by read commands (which do not depend
//!   on the address mapping).
//! - Reading an image uses the memory-mapped window only if [`init`] found that the processor's
//!   0x8000_0000 shows the same bytes as chip offset 0x60_0000 (`layout::MAP_CHIP`); otherwise read
//!   commands.
//!
//! ## Why the primitives run from RAM
//!
//! Reading flash is memory-mapped (XIP): the AE350's automatic AHB/EILM read engine drives the physical
//! SPI bus for any address the CPU touches with an ordinary load or instruction fetch, including this
//! crate's own code. Writing/erasing drives the *same pins* through the manual master-mode registers. If
//! code executing from flash switched the bus to manual mode, the next instruction fetch would find the
//! bus busy with the manual transfer (the classic XIP self-programming hazard). Every function that
//! touches the SPI registers is `#[link_section = ".ramfunc"]` (`ramfunc-ae350.x`), copied to DLM by
//! [`copy_ramfunc`], and each completes a whole transaction before it returns.

use crate::layout;
use core::sync::atomic::{AtomicU8, Ordering};
use tr_image::{ImageError, ImageHeader, HEADER_LEN};

/// MUG1029 table 3-1 / docs/BOARD.md AE350 table: "SPI 0xF0F0_0000".
const SPI_BASE: usize = 0xF0F0_0000;

// Register offsets of the SPI controller (MUG1029 table 10-2) and its configuration register
// (table 10-21).
const REG_TRANSCTRL: usize = 0x20; // transfer control: mode, command and address enables, lengths
const REG_CMD: usize = 0x24; // writing the opcode here starts the transfer
const REG_ADDR: usize = 0x28; // the three address bytes sent after the opcode
const REG_DATA: usize = 0x2C; // data FIFO, one 32-bit word per access
const REG_CTRL: usize = 0x30; // writing 6 (bits 1 and 2) resets the two FIFOs
const REG_STATUS: usize = 0x34; // bit 0 is set while a transfer is in progress
const REG_CONFIG: usize = 0x7C; // FIFO depths

// TRANSCTRL fields (table 10-6).
const CMD_EN: u32 = 1 << 30; // send the opcode
const ADDR_EN: u32 = 1 << 29; // send the address after the opcode
const MODE_WRITE: u32 = 1 << 24; // the data phase writes to the chip
const MODE_READ: u32 = 2 << 24; // the data phase reads from the chip
const MODE_NONE: u32 = 7 << 24; // no data phase (opcode and address only)
const WR_SHIFT: u32 = 12; // bit position of the write byte count; the read byte count is at bit 0

// The flash chip's own opcodes (the standard SPI NOR set) and two bits of its status register.
const OP_JEDEC: u32 = 0x9F; // read manufacturer, type and size
const OP_STATUS: u32 = 0x05; // read the status register
const OP_WREN: u32 = 0x06; // set the write-enable latch
const OP_READ: u32 = 0x03; // read bytes
const OP_PROGRAM: u32 = 0x02; // page program
const OP_ERASE_64K: u32 = 0xD8; // erase one 64 KiB block
const SR_BUSY: u32 = 1; // an erase or program is still running
const SR_WEL: u32 = 2; // the write-enable latch is set
/// Most bytes to a transfer whatever the FIFO (the buffer on the stack).
const MAX_CHUNK: usize = 64;

// Upper limits on the polling loops, so that a controller or chip that never answers makes a
// function return false instead of hanging the loader. The values are loop counts and not times;
// the busy limit is the larger one because a 64 KiB block erase takes much longer than a transfer.
const IDLE_TRIES: u32 = 2_000_000;
const BUSY_TRIES: u32 = 4_000_000;

/// Reads a controller register. Like every function that touches the SPI registers it lives in
/// `.ramfunc` and is never inlined (an inlined copy would sit in flash again).
#[link_section = ".ramfunc"]
#[inline(never)]
unsafe fn rd(offset: usize) -> u32 {
    unsafe { core::ptr::read_volatile((SPI_BASE + offset) as *const u32) }
}

/// Writes a controller register (see [`rd`] for why it is a function in RAM).
#[link_section = ".ramfunc"]
#[inline(never)]
unsafe fn wr(offset: usize, value: u32) {
    unsafe { core::ptr::write_volatile((SPI_BASE + offset) as *mut u32, value) };
}

/// One transfer, from RAM, complete when it returns: command, three address bytes if `addr` is not
/// 0xFFFF_FFFF, then `tx_len` bytes out of `tx` (words, low byte first) or `rx_len` bytes in. The words
/// read are left in `rx`. Returns false when the guard refused it or a wait ran out.
///
/// This is the one place that sends a program or erase command: it refuses both outside the program area,
/// whoever calls it.
#[link_section = ".ramfunc"]
#[inline(never)]
unsafe fn xfer(op: u32, addr: u32, mode: u32, tx: *const u32, tx_len: u32, rx: *mut u32, rx_len: u32) -> bool {
    // The guard: this check is what keeps the bitstream and the loader itself safe, so it sits in
    // the lowest function that can send these two commands and not in the callers.
    if op == OP_PROGRAM && !layout::write_allowed(addr, tx_len) {
        return false;
    }
    if op == OP_ERASE_64K && !layout::erase_allowed(addr) {
        return false;
    }
    unsafe {
        // Wait for any earlier transfer to finish (bounded).
        let mut n = 0;
        while rd(REG_STATUS) & 1 != 0 {
            n += 1;
            if n == IDLE_TRIES {
                return false;
            }
        }
        wr(REG_CTRL, 6); // reset both FIFOs
        n = 0;
        // Wait (bounded) until the reset bits read back as 0, which means the reset is done.
        while rd(REG_CTRL) & 6 != 0 && n < 1000 {
            n += 1;
        }
        // Transfer control: send the opcode, optionally the address, and the byte counts of the
        // data phase (each field holds the count minus one).
        let mut ctrl = CMD_EN | mode;
        if addr != u32::MAX {
            wr(REG_ADDR, addr);
            ctrl |= ADDR_EN;
        }
        if tx_len > 0 {
            ctrl |= (tx_len - 1) << WR_SHIFT;
        }
        if rx_len > 0 {
            ctrl |= rx_len - 1;
        }
        wr(REG_TRANSCTRL, ctrl);
        // Data to send goes into the FIFO before the opcode is written, because writing the
        // opcode starts the transfer. `tx_len` is at most one FIFO's worth (see `chunk`).
        let mut i = 0;
        while i * 4 < tx_len {
            wr(REG_DATA, tx.add(i as usize).read());
            i += 1;
        }
        wr(REG_CMD, op);
        // Wait until the transfer is finished (bounded), then take the received words out.
        n = 0;
        while rd(REG_STATUS) & 1 != 0 {
            n += 1;
            if n == IDLE_TRIES {
                return false;
            }
        }
        i = 0;
        while i * 4 < rx_len {
            rx.add(i as usize).write(rd(REG_DATA));
            i += 1;
        }
        true
    }
}

/// A command with no data phase (write enable, block erase). Pass `u32::MAX` as `addr` for a command
/// without an address.
fn no_data(op: u32, addr: u32) -> bool {
    unsafe { xfer(op, addr, MODE_NONE, core::ptr::null(), 0, core::ptr::null_mut(), 0) }
}

/// A command without an address that reads up to 4 bytes back (JEDEC id, status register); the
/// bytes are returned in one word, first byte in the low bits. `None` when the transfer failed.
fn read_small(op: u32, n: u32) -> Option<u32> {
    let mut w = [0u32; 1];
    unsafe { xfer(op, u32::MAX, MODE_READ, core::ptr::null(), 0, w.as_mut_ptr(), n) }.then_some(w[0])
}

/// Bytes to one transfer: the smaller of the two FIFOs (configuration register: bits 3:0 transmit depth,
/// 7:4 receive depth, code `c` = 2 << c words for c <= 6), at most [`MAX_CHUNK`].
fn chunk() -> usize {
    let cfg = unsafe { rd(REG_CONFIG) };
    let words = |code: u32| if code <= 6 { 2usize << code } else { 2 };
    (words(cfg >> 4 & 15).min(words(cfg & 15)) * 4).min(MAX_CHUNK)
}

/// The chip's JEDEC ID (maker, type, size); `None`: no chip answers.
pub fn jedec() -> Option<[u8; 3]> {
    let w = read_small(OP_JEDEC, 3)?.to_le_bytes();
    let id = [w[0], w[1], w[2]];
    (id != [0; 3] && id != [0xFF; 3]).then_some(id)
}

/// The chip's status register.
fn status() -> Option<u32> {
    read_small(OP_STATUS, 1).map(|w| w & 0xFF)
}

/// Sets the write-enable latch and reads the status register back to confirm that it is set; a chip
/// that does not accept the command fails here instead of silently ignoring the program or erase.
fn write_enable() -> bool {
    no_data(OP_WREN, u32::MAX) && status().is_some_and(|s| s & SR_WEL != 0)
}

/// Polls the status register until the chip is no longer busy with an erase or program. Returns
/// false if the chip stops answering or stays busy for `BUSY_TRIES` polls.
fn wait_done() -> bool {
    for _ in 0..BUSY_TRIES {
        match status() {
            Some(s) if s & SR_BUSY == 0 => return true,
            Some(_) => {}
            None => return false,
        }
    }
    false
}

/// Reads `out.len()` bytes at chip address `addr` by read commands (independent of the address mapping).
pub fn read_cmd(mut addr: u32, out: &mut [u8]) -> bool {
    let c = chunk();
    let mut w = [0u32; MAX_CHUNK / 4];
    for part in out.chunks_mut(c) {
        if !unsafe { xfer(OP_READ, addr, MODE_READ, core::ptr::null(), 0, w.as_mut_ptr(), part.len() as u32) } {
            return false;
        }
        // Unpack the little-endian words the controller delivered into bytes.
        for (i, b) in part.iter_mut().enumerate() {
            *b = (w[i / 4] >> (8 * (i % 4))) as u8;
        }
        addr += part.len() as u32;
    }
    true
}

/// The real chip as a `layout::Chip`: the shared erase and write loops run on it.
struct Hw;

impl layout::Chip for Hw {
    fn erase_block(&mut self, chip: u32) -> bool {
        write_enable() && no_data(OP_ERASE_64K, chip) && wait_done()
    }
    fn program(&mut self, chip: u32, data: &[u8]) -> bool {
        // Pack the bytes into little-endian words for the FIFO; unused bytes stay 0xFF.
        let mut w = [0xFFFF_FFFFu32; MAX_CHUNK / 4];
        for (i, b) in data.iter().enumerate().take(MAX_CHUNK) {
            w[i / 4] = w[i / 4] & !(0xFF << (8 * (i % 4))) | (*b as u32) << (8 * (i % 4));
        }
        data.len() <= MAX_CHUNK
            && write_enable()
            && unsafe { xfer(OP_PROGRAM, chip, MODE_WRITE, w.as_ptr(), data.len() as u32, core::ptr::null_mut(), 0) }
            && wait_done()
    }
}

/// Copies `.ramfunc` from flash to RAM, the same way the start-up code copies `.data`; must run once
/// before anything else here (see [`init`]). The symbols come from `ramfunc-ae350.x`.
pub fn copy_ramfunc() {
    extern "C" {
        static mut _ramfunc_start: u8;
        static _ramfunc_end: u8;
        static _ramfunc_lma: u8;
    }
    unsafe {
        let start = core::ptr::addr_of_mut!(_ramfunc_start);
        let end = core::ptr::addr_of!(_ramfunc_end);
        let lma = core::ptr::addr_of!(_ramfunc_lma);
        core::ptr::copy_nonoverlapping(lma, start, (end as usize) - (start as usize));
    }
}

// The result of the start-up mapping check in [`init`], kept for `read_chip`.
const MAP_UNKNOWN: u8 = 0;
const MAP_AGREES: u8 = 1;
const MAP_DIFFERS: u8 = 2;
static MAPPING: AtomicU8 = AtomicU8::new(MAP_UNKNOWN);

/// What [`init`] found out about the address mapping.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mapping {
    /// The processor's 0x8000_0000 shows the same bytes as chip offset `layout::MAP_CHIP`.
    Agrees,
    /// It does not: reads of images use read commands.
    Differs,
    /// The chip did not answer a read command, so nothing could be compared.
    Unknown,
}

/// Start-up: copies `.ramfunc` to RAM, then compares 64 bytes of this loader's own code as the processor
/// fetches them (0x8000_0000) with the same bytes read from chip offset `layout::MAP_CHIP` by a read
/// command. Call once, first thing in `main`.
pub fn init() -> Mapping {
    copy_ramfunc();
    let mut cmd = [0u8; 64];
    if !read_cmd(layout::MAP_CHIP, &mut cmd) {
        return Mapping::Unknown;
    }
    // SAFETY: the processor's flash window, 64 bytes of the code this loader is running from.
    let xip = unsafe { core::slice::from_raw_parts(layout::FLASH_BASE as *const u8, 64) };
    // Equal bytes only count as agreement when they are not all 0xFF, because two reads of an
    // erased (or absent) chip would also be equal.
    if cmd == *xip && cmd.iter().any(|b| *b != 0xFF) {
        MAPPING.store(MAP_AGREES, Ordering::Relaxed);
        Mapping::Agrees
    } else {
        MAPPING.store(MAP_DIFFERS, Ordering::Relaxed);
        Mapping::Differs
    }
}

/// Reads `out.len()` bytes at chip address `chip`: through the memory-mapped window unless [`init`] found
/// that the mapping differs (or the address has none), else by read commands.
pub fn read_chip(chip: u32, out: &mut [u8]) -> bool {
    if MAPPING.load(Ordering::Relaxed) != MAP_DIFFERS {
        if let Some(cpu) = layout::xip_addr(chip) {
            // SAFETY: inside the processor's flash window (layout asserts the program area is).
            out.copy_from_slice(unsafe { core::slice::from_raw_parts(cpu as *const u8, out.len()) });
            return true;
        }
    }
    read_cmd(chip, out)
}

/// Why an image was not written to its slot.
#[derive(Debug, Clone, Copy)]
pub enum ProgramError {
    /// Header and payload together do not fit in a slot.
    TooLarge { length: u32, max: u32 },
    /// No flash chip answers the JEDEC ID command.
    NoChip,
    /// The guard refused the range (a bug in the caller: nothing was touched).
    Refused { chip: u32 },
    /// The chip did not carry out an erase or a program at this chip address.
    Chip { chip: u32 },
    /// What is read back differs from what was sent.
    Verify { chip: u32 },
}

impl core::fmt::Display for ProgramError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            ProgramError::TooLarge { length, max } => write!(f, "image too large for a flash slot: {length} bytes, max {max}"),
            ProgramError::NoChip => write!(f, "no flash chip answers"),
            ProgramError::Refused { chip } => write!(f, "write refused by the guard at chip address {chip:#08x}"),
            ProgramError::Chip { chip } => write!(f, "erase or program failed at chip address {chip:#08x}"),
            ProgramError::Verify { chip } => write!(f, "read back differs at chip address {chip:#08x}"),
        }
    }
}

/// Converts the error of the shared erase and write loops into this module's error type.
fn from_write(e: layout::WriteError) -> ProgramError {
    match e {
        layout::WriteError::Refused { chip, .. } => ProgramError::Refused { chip },
        layout::WriteError::Chip { chip } => ProgramError::Chip { chip },
    }
}

/// Reads `data.len()` bytes back from chip address `addr` by read commands and compares them with
/// `data`. The first difference is reported with the chip address of the 256-byte piece it is in.
fn verify(mut addr: u32, data: &[u8]) -> Result<(), ProgramError> {
    let mut buf = [0u8; 256];
    for part in data.chunks(256) {
        let b = &mut buf[..part.len()];
        if !read_cmd(addr, b) || b != part {
            return Err(ProgramError::Verify { chip: addr });
        }
        addr += part.len() as u32;
    }
    Ok(())
}

/// Erases and programs flash slot `slot` (0 = A, 1 = B) with a complete image: `header_bytes` (the packed
/// `ImageHeader`) followed by `payload`, the same layout `cargo xtask image` writes to a file. The payload
/// is programmed first and the header last; both are read back by read commands.
pub fn program_image(slot: u8, header_bytes: &[u8; HEADER_LEN], payload: &[u8]) -> Result<(), ProgramError> {
    let total = HEADER_LEN as u32 + payload.len() as u32;
    if total > layout::SLOT_SIZE {
        return Err(ProgramError::TooLarge { length: total, max: layout::SLOT_SIZE });
    }
    if jedec().is_none() {
        return Err(ProgramError::NoChip);
    }
    let base = layout::slot_chip(slot);
    // store_image erases the slot, writes the payload and then the header (so an interrupted write
    // leaves no header that looks valid); the readback below uses read commands and not the
    // memory-mapped window.
    layout::store_image(&mut Hw, base, header_bytes, payload, chunk()).map_err(from_write)?;
    verify(base + HEADER_LEN as u32, payload)?;
    verify(base, header_bytes)
}

/// Erases the settings sector and writes `record` (at most `layout::SETTINGS_SIZE` bytes).
pub fn write_settings(record: &[u8]) -> Result<(), ProgramError> {
    if jedec().is_none() {
        return Err(ProgramError::NoChip);
    }
    layout::erase_region(&mut Hw, layout::SETTINGS_CHIP, layout::SETTINGS_SIZE).map_err(from_write)?;
    layout::write_region(&mut Hw, layout::SETTINGS_CHIP, record, chunk()).map_err(from_write)?;
    verify(layout::SETTINGS_CHIP, record)
}

/// Why [`read_and_validate_slot`] refused a flash slot's contents.
#[derive(Debug, Clone, Copy)]
pub enum SlotError {
    /// The chip did not answer a read command.
    Read,
    /// The slot's header is not valid (no image there, or a damaged one).
    Header(ImageError),
    /// Structurally valid header, but `load_addr`/`length` fall outside the destination window
    /// (`layout::DEST_BASE`/`DEST_LEN`) or the slot.
    Bounds,
    /// The payload was copied but does not match the CRC in the header.
    Payload(ImageError),
}

impl core::fmt::Display for SlotError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            SlotError::Read => write!(f, "the flash chip does not answer read commands"),
            SlotError::Header(e) => write!(f, "{e}"),
            SlotError::Bounds => write!(f, "load address/length outside the DDR3 destination window or the slot"),
            SlotError::Payload(e) => write!(f, "{e}"),
        }
    }
}

/// Reads slot `slot`'s header; if it validates, copies its payload to `header.load_addr` and CRC-checks it
/// there. Used by the normal-boot path in `bin/stage0.rs`. `dest_base` and `dest_len` are the RAM window
/// the image must lie in (`layout::DEST_BASE` and `DEST_LEN`).
pub fn read_and_validate_slot(slot: u8, dest_base: u32, dest_len: u32) -> Result<ImageHeader, SlotError> {
    let base = layout::slot_chip(slot);
    let mut hb = [0u8; HEADER_LEN];
    if !read_chip(base, &mut hb) {
        return Err(SlotError::Read);
    }
    let header = ImageHeader::from_bytes(&hb).map_err(SlotError::Header)?;
    let out_of_range = header.load_addr < dest_base
        || header.length > dest_len
        || header.load_addr - dest_base > dest_len - header.length
        || HEADER_LEN as u32 + header.length > layout::SLOT_SIZE;
    if out_of_range {
        return Err(SlotError::Bounds);
    }
    // SAFETY: the window is the caller's own, checked above; nothing else runs.
    let dest = unsafe { core::slice::from_raw_parts_mut(header.load_addr as *mut u8, header.length as usize) };
    if !read_chip(base + HEADER_LEN as u32, dest) {
        return Err(SlotError::Read);
    }
    header.validate_payload(dest, header.length).map_err(SlotError::Payload)?;
    Ok(header)
}
