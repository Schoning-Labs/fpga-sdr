// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The update (load, save to the flash sector, start the saved program) against the simulated HL2's
//! boot ROM (`sim::Hl2Sim`), over lossy links.

use super::*;
use crate::bridge::frontend;
use crate::msg::{MsgClient, Request, Response};
use crate::protocol::SAFETY_PA_KEYED;
use crate::sim::{Datagram, Hl2Sim, Link, SavedImage, FW_VERSION};

const BOOT_ID: u32 = 0xB007_0200;
const OLD_VERSION: u32 = 0x0003_0000;
const IMAGE_LEN: usize = 3136;

fn bytes() -> [u8; IMAGE_LEN] {
    let mut x: u32 = 0x0BAD_F00D;
    core::array::from_fn(|_| {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        x as u8
    })
}

struct Rig {
    radio: Hl2Sim,
    up: Link,
    down: Link,
    now: u32,
    /// Save datagrams still to lose on the way to the radio.
    lose_saves: u32,
    saves_sent: u32,
}

impl Rig {
    /// An HL2 running the older program, saved with `OLD_VERSION`.
    fn outdated(img: &[u8]) -> Rig {
        Rig { radio: Hl2Sim::with_saved_version(BOOT_ID, OLD_VERSION, img), up: Link::new(3), down: Link::new(5), now: 1_000, lose_saves: 0, saves_sent: 0 }
    }

    fn step(&mut self, l: &mut CpuLoader, image: &Image) {
        self.now += 1;
        let now = self.now;
        let mut buf = [0u8; 512];
        while let Some(n) = l.poll_transmit(now, &mut buf) {
            let d = &buf[..n];
            if d[0] == 0x01 {
                assert!(save_datagram_allowed(d, image), "a console datagram outside the allow-list: {d:02x?}");
                self.saves_sent += 1;
                if self.lose_saves > 0 {
                    self.lose_saves -= 1;
                    continue;
                }
            } else {
                assert_eq!(check_request(d), Ok(()), "a request outside the loader's rules: {d:02x?}");
            }
            let radio = &mut self.radio;
            self.up.pass(Datagram::new(d), |d| radio.input(now, d));
        }
        self.radio.poll(now);
        while let Some(d) = self.radio.pop_output() {
            self.down.pass(d, |d| l.handle_datagram(now, d));
        }
    }

    fn run(&mut self, l: &mut CpuLoader, image: &Image, max_ms: u32, mut until: impl FnMut(&Rig, &CpuLoader) -> bool) -> LoadState {
        for _ in 0..max_ms {
            if !matches!(l.state(), LoadState::Running(_)) || until(self, l) {
                break;
            }
            self.step(l, image);
        }
        l.state()
    }

    /// HELLO over the message layer: the firmware version, if answered within 3 s.
    fn hello(&mut self) -> Option<u32> {
        let mut c = MsgClient::new(self.now);
        c.submit(Request::Hello).unwrap();
        for _ in 0..3_500 {
            self.now += 1;
            let now = self.now;
            let mut buf = [0u8; 512];
            while let Some(n) = c.poll_transmit(now, &mut buf) {
                self.radio.input(now, &buf[..n]);
            }
            self.radio.poll(now);
            while let Some(d) = self.radio.pop_output() {
                c.handle_datagram(now, d.as_slice());
            }
            if let Some(done) = c.poll_completion() {
                return match done.result {
                    Ok(Response::Hello(h)) => Some(h.firmware_version),
                    _ => None,
                };
            }
        }
        None
    }
}

fn image(b: &[u8]) -> Image<'_> {
    Image { bytes: b, version: FW_VERSION, crc32: crc32(b) }
}

fn updater<'a>(img: &Image<'a>) -> CpuLoader<'a> {
    let mut l = CpuLoader::update(img).unwrap();
    l.set_quiet(true);
    l
}

#[test]
fn crc32_is_zlibs() {
    assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
    assert_eq!(crc32(&[]), 0);
}

#[test]
fn outdated_program_is_saved_started_and_verified() {
    let b = bytes();
    let img = image(&b);
    let mut rig = Rig::outdated(&b);
    assert_eq!(rig.hello(), Some(OLD_VERSION));
    let mut l = updater(&img);
    assert_eq!(rig.run(&mut l, &img, 10_000, |_, _| false), LoadState::Done);
    let cpu = &rig.radio.cpu;
    assert_eq!(cpu.flash, Some(SavedImage { version: FW_VERSION, runs: true, length: IMAGE_LEN as u32, crc32: img.crc32 }));
    assert_eq!((cpu.saves, cpu.erases, cpu.erase_datagrams, cpu.forbidden_writes, cpu.ram_boots), (1, 1, 0, 0, 0));
    assert_eq!(cpu.fw_result >> 24, b'S' as u32);
    assert_eq!(cpu.fw_result & 0xFF, 0);
    assert_eq!(cpu.ctrl, 0, "a normal start: the ROM started the saved program");
    assert_eq!(rig.saves_sent, 1);
    assert_eq!(rig.radio.hw.tx_permit_writes, 0);
    assert_eq!(rig.radio.hw.commands().len(), 0, "nothing on the command bus");
    assert_eq!(rig.hello(), Some(FW_VERSION), "the new version answers");
    // the saved program also starts after a power cycle
    let mut out = [0u8; 64];
    for v in [sys::CTRL_RESET, 0] {
        let n = crate::bridge::build_write_read(sys::CTRL, &[v], &[], &mut out).unwrap();
        rig.radio.input(rig.now, &out[..n]);
    }
    assert!(rig.radio.msg_running());
    assert_eq!(rig.hello(), Some(FW_VERSION));
}

#[test]
fn lossy_links_and_a_lost_save_datagram() {
    let b = bytes();
    let img = image(&b);
    let mut rig = Rig::outdated(&b);
    for link in [&mut rig.up, &mut rig.down] {
        link.loss_pct = 15;
        link.dup_pct = 5;
        link.reorder_pct = 5;
    }
    rig.lose_saves = 1;
    let mut l = updater(&img);
    assert_eq!(rig.run(&mut l, &img, 30_000, |_, _| false), LoadState::Done);
    assert!(rig.saves_sent >= 2, "the lost save datagram was sent again");
    assert!(rig.saves_sent <= SAVE_SENDS as u32);
    let cpu = &rig.radio.cpu;
    assert_eq!(cpu.saves, 1, "saved once");
    assert_eq!(cpu.flash.map(|f| f.version), Some(FW_VERSION));
    assert_eq!(cpu.forbidden_writes, 0);
    assert_eq!(rig.hello(), Some(FW_VERSION));
}

#[test]
fn an_image_whose_crc_differs_from_the_build_is_refused_before_anything_is_sent() {
    let b = bytes();
    let bad = Image { crc32: crc32(&b) ^ 1, ..image(&b) };
    assert_eq!(CpuLoader::update(&bad).err(), Some(LoadError::ImageCrc { want: bad.crc32, got: crc32(&b) }));
    assert!(!save_datagram_allowed(&build_save_datagram(&bad), &bad), "nor would its save datagram pass");
}

#[test]
fn ram_that_differs_from_the_image_crc_is_not_saved() {
    let b = bytes();
    let img = image(&b);
    let mut rig = Rig::outdated(&b);
    let mut l = updater(&img);
    // the RAM changes after it was verified (the ROM checks it against the CRC before erasing)
    rig.run(&mut l, &img, 10_000, |_, l| l.state() == LoadState::Running(Step::ClearResult));
    rig.radio.cpu.ram[0x300] ^= 1;
    assert_eq!(rig.run(&mut l, &img, 10_000, |_, _| false), LoadState::Failed(LoadError::Save { code: sys::FWR_CRC_MISMATCH }));
    let cpu = &rig.radio.cpu;
    assert_eq!((cpu.erases, cpu.flash.map(|f| f.version)), (0, Some(OLD_VERSION)), "nothing written");
    assert_eq!(rig.hello(), Some(OLD_VERSION), "the old saved program runs again");
}

#[test]
fn locked_flash_is_a_clear_failure_and_the_old_program_runs_again() {
    let b = bytes();
    let img = image(&b);
    let mut rig = Rig::outdated(&b);
    rig.radio.cpu.locked = true;
    let mut l = updater(&img);
    let st = rig.run(&mut l, &img, 10_000, |_, _| false);
    assert_eq!(st, LoadState::Failed(LoadError::Save { code: sys::FWR_LOCKED }));
    assert!(alloc_free_text(st).contains("locked"));
    let cpu = &rig.radio.cpu;
    assert_eq!((cpu.saves, cpu.erases), (1, 0));
    assert_eq!(cpu.flash.map(|f| f.version), Some(OLD_VERSION));
    assert_eq!(rig.hello(), Some(OLD_VERSION));
}

/// The failure text, without allocation.
fn alloc_free_text(st: LoadState) -> &'static str {
    match st {
        LoadState::Failed(LoadError::Save { code }) => result_text(code),
        _ => "",
    }
}

#[test]
fn a_flash_fault_leaves_the_new_image_running_from_ram() {
    let b = bytes();
    let img = image(&b);
    let mut rig = Rig::outdated(&b);
    rig.radio.cpu.flash_fault = true;
    let mut l = updater(&img);
    assert_eq!(rig.run(&mut l, &img, 10_000, |_, _| false), LoadState::Failed(LoadError::Save { code: sys::FWR_FLASH_ERR }));
    let cpu = &rig.radio.cpu;
    assert_eq!(cpu.flash, None, "the sector was erased and holds no valid program now");
    assert_eq!((cpu.ram_boots, cpu.ctrl), (1, sys::CTRL_BOOT_RAM), "restarted from RAM");
    assert_eq!(rig.hello(), Some(FW_VERSION), "the verified image runs until the next power-up");
}

#[test]
fn transmit_on_stops_the_update_before_the_flash() {
    let b = bytes();
    let img = image(&b);
    // on from the start: nothing is written at all
    let mut rig = Rig::outdated(&b);
    rig.radio.hw.safety = SAFETY_PA_KEYED;
    let mut l = updater(&img);
    assert!(matches!(rig.run(&mut l, &img, 10_000, |_, _| false), LoadState::Failed(LoadError::TransmitOn { .. })));
    assert_eq!((rig.radio.cpu.ram_writes, rig.radio.cpu.resets), (0, 0));
    // on after the RAM was written: no save, the old program runs again
    let mut rig = Rig::outdated(&b);
    let mut l = updater(&img);
    rig.run(&mut l, &img, 10_000, |_, l| l.state() == LoadState::Running(Step::ClearResult));
    rig.radio.hw.safety = SAFETY_PA_KEYED;
    assert!(matches!(rig.run(&mut l, &img, 10_000, |_, _| false), LoadState::Failed(LoadError::TransmitOn { .. })));
    assert_eq!((rig.radio.cpu.saves, rig.radio.cpu.erases, rig.saves_sent), (0, 0, 0));
    rig.radio.hw.safety = 0;
    assert_eq!(rig.hello(), Some(OLD_VERSION));
}

#[test]
fn not_quiet_stops_the_update_before_the_flash() {
    let b = bytes();
    let img = image(&b);
    let mut rig = Rig::outdated(&b);
    let mut l = CpuLoader::update(&img).unwrap();
    assert_eq!(rig.run(&mut l, &img, 10_000, |_, _| false), LoadState::Failed(LoadError::NotQuiet));
    assert_eq!((rig.radio.cpu.saves, rig.saves_sent), (0, 0));
    assert_eq!(rig.hello(), Some(OLD_VERSION));
}

#[test]
fn only_the_save_of_the_embedded_image_reaches_the_boot_rom() {
    let b = bytes();
    let img = image(&b);
    let d = build_save_datagram(&img);
    assert_eq!(d[..2], [0x01, b'S']);
    assert_eq!(u32::from_le_bytes([d[2], d[3], d[4], d[5]]), APP_START);
    assert_eq!(u32::from_le_bytes([d[6], d[7], d[8], d[9]]), IMAGE_LEN as u32);
    assert_eq!(u32::from_le_bytes([d[14], d[15], d[16], d[17]]), FW_VERSION);
    assert_eq!(u32::from_le_bytes([d[18], d[19], d[20], d[21]]), img.crc32);
    assert!(save_datagram_allowed(&d, &img));
    // erase, other console commands, any other header
    assert!(!save_datagram_allowed(&[0x01, b'E'], &img));
    assert!(!save_datagram_allowed(&[0x01, b'A'], &img));
    for i in 2..22 {
        let mut e = d;
        e[i] ^= 1;
        assert!(!save_datagram_allowed(&e, &img), "byte {i}");
    }
    assert!(!save_datagram_allowed(&d[..21], &img));
    assert!(!save_datagram_allowed(&build_save_datagram(&Image { version: 0x0004_0000, ..img }), &img));
    // the register bridge never writes the flash sector, the packet interface, the front-end block,
    // halt, or any result value but 0
    let mut out = [0u8; 64];
    let mut bridge_ok = |a: u32, v: u32| {
        let n = crate::bridge::build_write_read(a, &[v], &[a], &mut out);
        n.is_some_and(|n| check_request(&out[..n]).is_ok())
    };
    for a in [0x4003_0000u32, 0x4003_0004, 0x4003_0008, 0x4002_0008, frontend::TX_PERMIT, frontend::CMD_ADDR, 0x0001_0000, 0x7FC] {
        assert!(!bridge_ok(a, 1), "0x{a:08x}");
    }
    assert!(!bridge_ok(sys::CTRL, sys::CTRL_HALT));
    assert!(!bridge_ok(sys::FW_RESULT, 1));
    assert!(bridge_ok(sys::FW_RESULT, 0));
    assert!(bridge_ok(sys::CTRL, sys::CTRL_STAY_ROM) && bridge_ok(sys::CTRL, 0));
}
