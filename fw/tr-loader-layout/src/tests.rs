// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Host tests of the flash layout and the write guard. The model chip below behaves like a SPI
//! NOR chip (erase sets a block to 0xFF, a program can only clear bits, a program must not cross a
//! page) and holds a recognizable bitstream and loader; every test that writes checks that those bytes
//! are unchanged afterwards. The last few tests read the real driver and the linker script as text,
//! because the driver cannot run on a PC, and check the properties of them that the guard depends on.

use super::*;

/// Size of a bitstream built for this chip, uncompressed.
const BITSTREAM_BYTES: usize = 5_283_212;

/// A 16 MiB SPI NOR chip in memory that also records what was done to it.
struct Model {
    /// The whole chip, indexed by chip address.
    mem: Vec<u8>,
    /// Chip address of every erase, in order.
    erases: Vec<u32>,
    /// Chip address and length of every program, in order.
    programs: Vec<(u32, usize)>,
    /// Fail the n-th program call (0-based), as a cut-off power supply would.
    fail_program_at: Option<usize>,
}

impl Model {
    /// A chip with a stand-in bitstream at the bottom, a loader (all 0x5A) at the loader's
    /// address, and everything above erased.
    fn new() -> Self {
        let mut mem = vec![0xFFu8; FLASH_SIZE as usize];
        for (i, b) in mem[..BITSTREAM_BYTES].iter_mut().enumerate() {
            *b = (i as u32).wrapping_mul(2_654_435_761).to_le_bytes()[2] | 1; // never 0xFF-only runs
        }
        for b in mem[STAGE0_CHIP as usize..(STAGE0_CHIP + STAGE0_SIZE) as usize].iter_mut() {
            *b = 0x5A;
        }
        Model { mem, erases: vec![], programs: vec![], fail_program_at: None }
    }
    /// Everything below the program area, which no write may ever change.
    fn protected(&self) -> &[u8] {
        &self.mem[..PROGRAM_AREA_START as usize]
    }
}

/// The model enforces the rules of the real chip itself (erase only on a block start, a program
/// only clears bits, no program crosses a page), so a bug in the shared loops fails an assertion.
impl Chip for Model {
    fn erase_block(&mut self, chip: u32) -> bool {
        assert_eq!(chip % ERASE_BLOCK, 0);
        self.erases.push(chip);
        self.mem[chip as usize..(chip + ERASE_BLOCK) as usize].fill(0xFF);
        true
    }
    fn program(&mut self, chip: u32, data: &[u8]) -> bool {
        assert!(!data.is_empty());
        assert_eq!(chip / PAGE, (chip + data.len() as u32 - 1) / PAGE, "a program crossed a page");
        let n = self.programs.len();
        self.programs.push((chip, data.len()));
        if self.fail_program_at == Some(n) {
            return false;
        }
        for (i, b) in data.iter().enumerate() {
            self.mem[chip as usize + i] &= *b;
        }
        true
    }
}

/// Deterministic test data of `len` bytes. The low bit is always clear so the data is never all
/// 0xFF, which is what an erased chip reads, and a missing write therefore shows up.
fn image(len: usize, seed: u8) -> Vec<u8> {
    (0..len).map(|i| (i as u8).wrapping_mul(7).wrapping_add(seed) & 0xFE).collect()
}

#[test]
fn regions_are_ordered_disjoint_and_inside_the_chip() {
    assert!(BITSTREAM_BYTES as u32 + 512 * 1024 <= BITSTREAM_END, "bitstream needs room to grow");
    assert_eq!(STAGE0_CHIP, 0x60_0000);
    assert_eq!(SLOT_A_CHIP, 0x61_0000);
    assert_eq!(SLOT_B_CHIP, 0xA1_0000);
    assert_eq!(SETTINGS_CHIP, 0xE1_0000);
    assert_eq!(PROGRAM_AREA_START, 0x61_0000);
    assert_eq!(PROGRAM_AREA_END, 0xE2_0000);
    assert!(PROGRAM_AREA_END <= FLASH_SIZE);
    assert!(SLOT_A_CHIP + SLOT_SIZE <= SLOT_B_CHIP && SLOT_B_CHIP + SLOT_SIZE <= SETTINGS_CHIP);
    // every region the loader writes starts on an erase block
    for a in [SLOT_A_CHIP, SLOT_B_CHIP, SETTINGS_CHIP] {
        assert_eq!(a % ERASE_BLOCK, 0);
    }
    assert_eq!(slot_chip(0), SLOT_A_CHIP);
    assert_eq!(slot_chip(1), SLOT_B_CHIP);
    assert_eq!(slot_chip(7), SLOT_B_CHIP);
}

#[test]
fn cpu_address_maps_to_the_chip_and_back() {
    assert_eq!(xip_addr(STAGE0_CHIP), Some(0x8000_0000));
    assert_eq!(xip_addr(SLOT_A_CHIP), Some(0x8001_0000));
    assert_eq!(xip_addr(SLOT_B_CHIP), Some(0x8041_0000));
    assert_eq!(xip_addr(SETTINGS_CHIP), Some(0x8081_0000));
    assert_eq!(xip_addr(0), None, "the bitstream has no CPU address");
    assert_eq!(xip_addr(MAP_CHIP - 1), None);
    for chip in [STAGE0_CHIP, SLOT_A_CHIP, SLOT_B_CHIP, SETTINGS_CHIP, FLASH_SIZE - 1] {
        assert_eq!(chip_of_xip(xip_addr(chip).unwrap()), Some(chip));
    }
    assert_eq!(chip_of_xip(0x7FFF_FFFF), None);
    assert_eq!(chip_of_xip(0x9000_0000), None);
    assert_eq!(chip_of_xip(0x0000_0000), None);
    // the whole program area is inside the processor's window
    assert!(xip_addr(PROGRAM_AREA_END - 1).unwrap() - FLASH_BASE < FLASH_WINDOW);
}

#[test]
fn guard_refuses_everything_below_the_program_area() {
    // every 4 KiB step from chip offset 0 up to the first slot, with lengths from one byte to the whole chip
    let mut a = 0u32;
    while a < PROGRAM_AREA_START {
        for len in [1u32, 2, 256, 4096, ERASE_BLOCK, SLOT_SIZE, FLASH_SIZE, u32::MAX] {
            assert!(!write_allowed(a, len), "write at {a:#x} len {len:#x} was allowed");
        }
        assert!(!erase_allowed(a - a % ERASE_BLOCK), "erase at {a:#x}");
        a += 4096;
    }
    // the last byte of the loader, and ranges that start below and reach into the area
    assert!(!write_allowed(PROGRAM_AREA_START - 1, 1));
    assert!(!write_allowed(PROGRAM_AREA_START - 1, 2));
    assert!(!write_allowed(0, PROGRAM_AREA_START + 1));
    assert!(!write_allowed(STAGE0_CHIP, STAGE0_SIZE));
    assert!(!erase_allowed(STAGE0_CHIP));
    assert!(!erase_allowed(0));
    assert!(!erase_allowed(BITSTREAM_END - ERASE_BLOCK));
}

#[test]
fn guard_allows_exactly_the_program_area() {
    assert!(write_allowed(PROGRAM_AREA_START, 1));
    assert!(write_allowed(PROGRAM_AREA_START, PROGRAM_AREA_END - PROGRAM_AREA_START));
    assert!(write_allowed(PROGRAM_AREA_END - 1, 1));
    assert!(!write_allowed(PROGRAM_AREA_END - 1, 2));
    assert!(!write_allowed(PROGRAM_AREA_END, 1));
    assert!(!write_allowed(PROGRAM_AREA_START, 0), "an empty write is nothing, not an allowed write");
    assert!(erase_allowed(SLOT_A_CHIP));
    assert!(erase_allowed(SLOT_B_CHIP));
    assert!(erase_allowed(SETTINGS_CHIP));
    assert!(!erase_allowed(SETTINGS_CHIP + SETTINGS_SIZE), "the first block after the settings sector");
    assert!(!erase_allowed(SLOT_A_CHIP + 4096), "not on a block start");
}

#[test]
fn guard_does_not_wrap_around() {
    for chip in [u32::MAX, u32::MAX - 1, 0xFFFF_0000, PROGRAM_AREA_END + 1] {
        for len in [1u32, 2, 0x10000, u32::MAX] {
            assert!(!write_allowed(chip, len));
        }
    }
    assert!(!write_allowed(PROGRAM_AREA_START, u32::MAX));
    assert!(!erase_allowed(u32::MAX - ERASE_BLOCK + 1));
}

#[test]
fn storing_an_image_in_either_slot_leaves_bitstream_and_loader_alone() {
    let before = Model::new();
    for (slot, chip) in [(0u8, SLOT_A_CHIP), (1u8, SLOT_B_CHIP)] {
        let mut m = Model::new();
        let header = image(28, 3);
        let body = image(300_000 + slot as usize * 13, 9);
        store_image(&mut m, chip, &header, &body, 64).unwrap();
        assert_eq!(m.protected(), before.protected(), "bitstream or loader changed (slot {slot})");
        assert_eq!(&m.mem[chip as usize..chip as usize + 28], &header[..]);
        assert_eq!(&m.mem[chip as usize + 28..chip as usize + 28 + body.len()], &body[..]);
        // the header was written last
        let (last_addr, _) = *m.programs.last().unwrap();
        assert_eq!(last_addr, chip, "the header must be the last program");
        // nothing erased or programmed outside the slot
        assert!(m.erases.iter().all(|e| *e >= chip && *e < chip + SLOT_SIZE));
        assert!(m.programs.iter().all(|(a, n)| *a >= chip && a + *n as u32 <= chip + SLOT_SIZE));
        assert!(m.programs.iter().all(|(_, n)| *n <= 64));
        // the other slot and the settings sector stayed erased
        let other = if slot == 0 { SLOT_B_CHIP } else { SLOT_A_CHIP };
        assert!(m.mem[other as usize..(other + SLOT_SIZE) as usize].iter().all(|b| *b == 0xFF));
        assert!(m.mem[SETTINGS_CHIP as usize..(SETTINGS_CHIP + SETTINGS_SIZE) as usize].iter().all(|b| *b == 0xFF));
    }
}

#[test]
fn a_full_slot_fits_and_one_byte_more_is_refused() {
    let mut m = Model::new();
    let header = image(28, 1);
    let body = vec![0x3Cu8; SLOT_SIZE as usize - 28];
    store_image(&mut m, SLOT_B_CHIP, &header, &body, 256).unwrap();
    assert_eq!(m.protected(), Model::new().protected());
    let settings_ok = m.mem[SETTINGS_CHIP as usize..(SETTINGS_CHIP + SETTINGS_SIZE) as usize].iter().all(|b| *b == 0xFF);
    assert!(settings_ok, "a full slot B must not touch the settings sector");

    let mut m = Model::new();
    let body = vec![0x3Cu8; SLOT_SIZE as usize - 27];
    assert!(matches!(store_image(&mut m, SLOT_B_CHIP, &header, &body, 256), Err(WriteError::Refused { .. })));
    assert!(m.erases.is_empty() && m.programs.is_empty(), "a refused image must not start");
}

#[test]
fn writes_and_erases_below_the_program_area_are_refused_and_do_nothing() {
    let reference = Model::new();
    let bad = [0u32, 0x1_0000, 0x10_0000, BITSTREAM_END - ERASE_BLOCK, STAGE0_CHIP, PROGRAM_AREA_START - ERASE_BLOCK];
    for chip in bad {
        let mut m = Model::new();
        assert!(matches!(erase_region(&mut m, chip, ERASE_BLOCK), Err(WriteError::Refused { .. })), "erase {chip:#x}");
        assert!(matches!(erase_region(&mut m, chip, 3 * ERASE_BLOCK), Err(WriteError::Refused { .. })), "erase x3 {chip:#x}");
        assert!(matches!(write_region(&mut m, chip, &[0u8; 100], 64), Err(WriteError::Refused { .. })), "write {chip:#x}");
        assert!(matches!(store_image(&mut m, chip, &[1; 28], &[2; 100], 64), Err(WriteError::Refused { .. })), "store {chip:#x}");
        assert!(m.erases.is_empty() && m.programs.is_empty());
        assert_eq!(m.mem, reference.mem);
    }
    // a range that starts below and reaches into the area is refused whole
    let mut m = Model::new();
    assert!(erase_region(&mut m, PROGRAM_AREA_START - ERASE_BLOCK, 2 * ERASE_BLOCK).is_err());
    assert!(write_region(&mut m, PROGRAM_AREA_START - 10, &[0u8; 20], 64).is_err());
    assert!(m.erases.is_empty() && m.programs.is_empty());
    // and so is one that reaches past the end of the settings sector
    assert!(erase_region(&mut m, SETTINGS_CHIP, 2 * ERASE_BLOCK).is_err());
    assert!(write_region(&mut m, PROGRAM_AREA_END - 4, &[0u8; 8], 64).is_err());
    assert_eq!(m.mem, reference.mem);
}

#[test]
fn a_store_cut_off_part_way_leaves_no_valid_header() {
    let mut m = Model::new();
    m.fail_program_at = Some(40);
    let header = image(28, 5);
    let body = image(100_000, 1);
    let r = store_image(&mut m, SLOT_A_CHIP, &header, &body, 64);
    assert!(matches!(r, Err(WriteError::Chip { .. })));
    assert!(m.mem[SLOT_A_CHIP as usize..SLOT_A_CHIP as usize + 28].iter().all(|b| *b == 0xFF), "header must still be erased");
    assert_eq!(m.protected(), Model::new().protected());
}

#[test]
fn the_settings_sector_can_be_rewritten_and_nothing_after_it() {
    let mut m = Model::new();
    erase_region(&mut m, SETTINGS_CHIP, SETTINGS_SIZE).unwrap();
    write_region(&mut m, SETTINGS_CHIP, &[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], 64).unwrap();
    assert_eq!(m.erases, vec![SETTINGS_CHIP]);
    assert_eq!(&m.mem[SETTINGS_CHIP as usize..SETTINGS_CHIP as usize + 3], &[1, 2, 3]);
    assert!(erase_region(&mut m, SETTINGS_CHIP + SETTINGS_SIZE, ERASE_BLOCK).is_err());
    assert_eq!(m.protected(), Model::new().protected());
}

#[test]
fn chunks_never_cross_a_page_whatever_the_start() {
    for start_off in [0u32, 1, 63, 64, 250, 255] {
        let mut m = Model::new();
        erase_region(&mut m, SLOT_A_CHIP, ERASE_BLOCK).unwrap();
        // Model::program asserts that no chunk crosses a page
        write_region(&mut m, SLOT_A_CHIP + start_off, &image(1000, 2), 64).unwrap();
        assert!(m.programs.iter().all(|(_, n)| *n <= 64));
    }
}

// ---- the real driver and the linker script, read as text (the driver itself cannot run on the PC)

/// Reads a source file of a sibling crate, given relative to this crate's directory.
fn read(rel: &str) -> String {
    let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(rel);
    std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display()))
}

// STAGE0_SIZE decides where slot A starts, so it has to be the same size as the flash region the
// loader is linked into.
#[test]
fn stage0_size_matches_the_linker_script() {
    let ld = read("../tr-loader/memory-loader-ae350.x");
    let line = ld.lines().find(|l| l.contains("FLASH (rx)")).expect("FLASH region");
    assert!(line.contains("ORIGIN = 0x80000000"), "{line}");
    assert!(line.contains(&format!("LENGTH = {}K", STAGE0_SIZE / 1024)), "{line}");
}

#[test]
fn the_driver_checks_the_guard_at_the_lowest_level() {
    let src = read("../tr-loader/src/flash.rs");
    // the one function that sends a command to the chip refuses program and erase outside the area
    let start = src.find("unsafe fn xfer(").expect("xfer");
    let end = src[start..].find("\nfn ").map(|i| start + i).expect("end of xfer");
    let body = &src[start..end];
    assert!(body.contains("OP_PROGRAM") && body.contains("OP_ERASE_64K"), "xfer must look at the opcode");
    assert!(body.contains("layout::write_allowed("), "xfer must call the guard");
    // the driver goes through the shared loops
    assert!(src.contains("layout::store_image(") && src.contains("layout::erase_region(") && src.contains("layout::write_region("));
    // the loader must not use any chip-offset constant that is not above the bitstream
    for old in ["SLOT_A_OFFSET", "SLOT_B_OFFSET", "SETTINGS_OFFSET", "slot_offset"] {
        for f in ["../tr-loader/src/flash.rs", "../tr-loader/src/settings.rs", "../tr-loader/src/bin/stage0.rs", "../tr-loader/src/layout.rs"] {
            assert!(!read(f).contains(old), "{f} still uses {old}");
        }
    }
}

// riscv-rt's start-up function would otherwise be placed after the last code section, which is the
// RAM function section, and the reset code in flash would jump into RAM that holds nothing yet.
#[test]
fn the_start_up_function_is_pinned_into_flash() {
    let b = read("../tr-loader/build.rs");
    assert!(b.contains("init-rust-ae350.x"), "build.rs must pass the .init.rust script");
    let x = read("../tr-loader/init-rust-ae350.x");
    assert!(x.contains(".init.rust") && x.contains("> FLASH") && x.contains("INSERT AFTER .text"));
}
