// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The loader against the simulated HL2 (`sim::Hl2Sim::without_program`), over lossy links.

use super::*;
use crate::bridge::frontend;
use crate::msg::{MsgClient, Request, Response};
use crate::protocol::SAFETY_PA_KEYED;
use crate::sim::{Datagram, Hl2Sim, Link};

const BOOT_ID: u32 = 0xB007_0100;
/// The size of msg.bin today.
const IMAGE_LEN: usize = 3136;

/// A stand-in for the program: no real code, just bytes the simulated CPU recognizes.
fn image() -> [u8; IMAGE_LEN] {
    let mut x: u32 = 0x1234_5679;
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
}

impl Rig {
    fn new(img: &[u8]) -> Rig {
        Rig { radio: Hl2Sim::without_program(BOOT_ID, img), up: Link::new(7), down: Link::new(11), now: 1_000 }
    }

    fn step(&mut self, l: &mut CpuLoader) {
        self.now += 1;
        let now = self.now;
        let mut buf = [0u8; 512];
        while let Some(n) = l.poll_transmit(now, &mut buf) {
            assert_eq!(check_request(&buf[..n]), Ok(()), "a request outside the loader's rules: {:02x?}", &buf[..n]);
            let radio = &mut self.radio;
            self.up.pass(Datagram::new(&buf[..n]), |d| radio.input(now, d));
        }
        self.radio.poll(now);
        while let Some(d) = self.radio.pop_output() {
            self.down.pass(d, |d| l.handle_datagram(now, d));
        }
    }

    /// Runs the loader until it is done or failed, at most `max_ms`.
    fn load(&mut self, l: &mut CpuLoader, max_ms: u32) -> LoadState {
        for _ in 0..max_ms {
            if !matches!(l.state(), LoadState::Running(_)) {
                break;
            }
            self.step(l);
        }
        l.state()
    }

    /// HELLO over the message layer; true if it was answered within 3 s.
    fn hello(&mut self) -> bool {
        let mut c = MsgClient::new(self.now);
        c.submit(Request::Hello).unwrap();
        for _ in 0..3_500 {
            self.now += 1;
            let now = self.now;
            let mut buf = [0u8; 512];
            while let Some(n) = c.poll_transmit(now, &mut buf) {
                let radio = &mut self.radio;
                self.up.pass(Datagram::new(&buf[..n]), |d| radio.input(now, d));
            }
            self.radio.poll(now);
            while let Some(d) = self.radio.pop_output() {
                self.down.pass(d, |d| c.handle_datagram(now, d));
            }
            if let Some(done) = c.poll_completion() {
                return matches!(done.result, Ok(Response::Hello(_)));
            }
        }
        false
    }

    fn ram_holds(&self, img: &[u8]) -> bool {
        img.chunks(4).enumerate().all(|(i, w)| {
            let mut b = [0u8; 4];
            b[..w.len()].copy_from_slice(w);
            self.radio.cpu.ram[0x200 + i] == u32::from_le_bytes(b)
        })
    }
}

#[test]
fn load_then_hello_is_answered() {
    let img = image();
    let mut rig = Rig::new(&img);
    assert!(!rig.hello(), "no program: HELLO goes unanswered");
    let mut l = CpuLoader::new(&img).unwrap();
    assert_eq!(rig.load(&mut l, 5_000), LoadState::Done);
    assert!(rig.radio.msg_running());
    assert_ne!(rig.radio.boot_id(), BOOT_ID, "the message layer started with a new boot ID");
    assert!(rig.ram_holds(&img));
    let cpu = &rig.radio.cpu;
    assert_eq!((cpu.ctrl, cpu.boot_addr, cpu.ram_boots, cpu.forbidden_writes), (sys::CTRL_BOOT_RAM, APP_START, 1, 0));
    assert_eq!(cpu.ram_writes as usize, IMAGE_LEN / 4, "every word written once");
    assert_eq!(rig.radio.hw.tx_permit_writes, 0);
    assert_eq!(rig.radio.hw.commands().len(), 0, "nothing on the command bus");
    // 17 RAM chunks, 7 other requests and one or more state reads
    let s = l.stats();
    assert_eq!(s.retries, 0);
    assert!((17 + 7..17 + 7 + 3).contains(&s.datagrams_sent), "{s:?}");
    assert_eq!(l.progress(), (IMAGE_LEN / 4, IMAGE_LEN / 4));
    assert!(l.elapsed_ms().unwrap() < 100, "{:?} ms", l.elapsed_ms());
    assert!(rig.hello(), "HELLO answered after the load");
}

#[test]
fn lost_duplicated_and_reordered_datagrams() {
    let img = image();
    let mut rig = Rig::new(&img);
    for link in [&mut rig.up, &mut rig.down] {
        link.loss_pct = 20;
        link.dup_pct = 5;
        link.reorder_pct = 5;
    }
    let mut l = CpuLoader::new(&img).unwrap();
    assert_eq!(rig.load(&mut l, 20_000), LoadState::Done);
    assert!(l.stats().retries > 0);
    assert!(rig.ram_holds(&img));
    assert!(rig.radio.msg_running());
    assert_eq!(rig.radio.cpu.forbidden_writes, 0);
    rig.up.loss_pct = 0;
    rig.down.loss_pct = 0;
    assert!(rig.hello());
}

#[test]
fn a_word_that_does_not_read_back_fails_and_nothing_starts() {
    let img = image();
    let mut rig = Rig::new(&img);
    rig.radio.cpu.stuck = Some((APP_START + 4 * 100, 1 << 7));
    let mut l = CpuLoader::new(&img).unwrap();
    assert_eq!(rig.load(&mut l, 5_000), LoadState::Failed(LoadError::Verify { addr: APP_START + 4 * 100 }));
    assert_eq!(l.stats().retries as u8, TRIES - 1, "the chunk was written {TRIES} times");
    let cpu = &rig.radio.cpu;
    assert_eq!(cpu.ctrl, sys::CTRL_RESET, "CPU left in reset");
    assert_eq!(cpu.ram_boots, 0);
    assert!(!rig.radio.msg_running());
    assert!(!rig.hello());
}

#[test]
fn a_truncated_image_does_not_start_the_message_layer() {
    let img = image();
    let mut rig = Rig::new(&img);
    let mut l = CpuLoader::new(&img[..2_000]).unwrap();
    // RAM holds what was sent; the CPU traps on it, as on a wrong image
    assert!(matches!(rig.load(&mut l, 5_000), LoadState::Failed(LoadError::Stopped { .. })));
    assert_eq!(rig.radio.cpu.ram_boots, 1);
    assert!(!rig.radio.msg_running());
    assert!(!rig.hello());
}

#[test]
fn transmit_on_aborts_before_any_write() {
    let img = image();
    let mut rig = Rig::new(&img);
    rig.radio.hw.safety |= SAFETY_PA_KEYED;
    let mut l = CpuLoader::new(&img).unwrap();
    assert!(matches!(rig.load(&mut l, 5_000), LoadState::Failed(LoadError::TransmitOn { .. })));
    assert_eq!(l.stats().datagrams_sent, 1, "only the probe");
    let cpu = &rig.radio.cpu;
    assert_eq!((cpu.ctrl, cpu.ram_writes, cpu.forbidden_writes), (0, 0, 0));
}

#[test]
fn transmit_on_during_the_load_stops_it_before_the_release() {
    let img = image();
    let mut rig = Rig::new(&img);
    let mut l = CpuLoader::new(&img).unwrap();
    while l.progress().0 < 200 {
        rig.step(&mut l);
    }
    rig.radio.hw.safety |= SAFETY_PA_KEYED;
    assert!(matches!(rig.load(&mut l, 5_000), LoadState::Failed(LoadError::TransmitOn { .. })));
    assert_eq!(rig.radio.cpu.ctrl, sys::CTRL_RESET);
    assert_eq!(rig.radio.cpu.ram_boots, 0);
    assert!(!rig.radio.msg_running());
}

#[test]
fn no_reply_fails_after_the_tries() {
    let img = image();
    let mut rig = Rig::new(&img);
    rig.down.loss_pct = 100;
    let mut l = CpuLoader::new(&img).unwrap();
    assert_eq!(rig.load(&mut l, 5_000), LoadState::Failed(LoadError::NoReply(Step::Probe)));
    assert_eq!(l.stats().datagrams_sent, TRIES as u32);
    let ms = l.elapsed_ms().unwrap();
    assert!((TRIES as u32 * RETRY_MS..=TRIES as u32 * RETRY_MS + 2).contains(&ms), "{ms} ms");
}

#[test]
fn addresses_outside_the_application_ram_are_refused() {
    use sys::*;
    // the RAM from 0x800 to 0x3FFF, nothing below or above
    assert!(write_allowed(APP_START, &[0; 48]));
    assert!(write_allowed(APP_END - 4, &[1]));
    assert!(!write_allowed(APP_START - 4, &[0]));
    assert!(!write_allowed(APP_START - 4, &[0, 0]));
    assert!(!write_allowed(APP_END - 4, &[0, 0]));
    assert!(!write_allowed(APP_END, &[0]));
    assert!(!write_allowed(APP_START + 2, &[0]));
    // flash sector, packet interface, boot ROM, status block, command bus, TX_PERMIT, bias unlock
    for a in [0x4003_0000, 0x4003_0004, 0x4003_0008, 0x4002_0000, 0x4002_0008, 0x0001_0000, 0x0001_0FFC, 0x4000_2000, frontend::CMD_DATA, frontend::CMD_ADDR, frontend::TX_PERMIT, frontend::BIAS_UNLOCK, frontend::WDOG_DISARM] {
        assert!(!write_allowed(a, &[0]) && !write_allowed(a, &[0x3A]), "0x{a:08x}");
    }
    // the CPU control registers only with the values of the sequence
    assert!(write_allowed(CTRL, &[CTRL_RESET]) && write_allowed(CTRL, &[CTRL_RESET | CTRL_BOOT_RAM]) && write_allowed(CTRL, &[CTRL_BOOT_RAM]));
    // the update's restarts: into the ROM, and a normal start
    assert!(write_allowed(CTRL, &[CTRL_RESET | CTRL_STAY_ROM]) && write_allowed(CTRL, &[CTRL_STAY_ROM]) && write_allowed(CTRL, &[0]));
    for v in [CTRL_HALT, CTRL_HALT | CTRL_RESET, CTRL_STAY_ROM | CTRL_BOOT_RAM, 0xF] {
        assert!(!write_allowed(CTRL, &[v]), "control {v}");
    }
    assert!(write_allowed(FW_RESULT, &[0]) && !write_allowed(FW_RESULT, &[1]));
    assert!(write_allowed(BOOT_ADDR, &[APP_START]));
    assert!(!write_allowed(BOOT_ADDR, &[0x0001_0000]) && !write_allowed(BOOT_ADDR, &[0]) && !write_allowed(BOOT_ADDR, &[APP_END]));
    assert!(write_allowed(FW_STATUS, &[0]) && !write_allowed(FW_STATUS, &[3 << 24]));
    assert!(!write_allowed(CTRL, &[CTRL_RESET, 0]), "no multi-word writes into the system block");

    // images that would leave the application RAM
    let big = [0u8; MAX_IMAGE + 1];
    assert_eq!(CpuLoader::new(&big).err(), Some(LoadError::TooLarge { len: MAX_IMAGE + 1 }));
    assert!(CpuLoader::new(&big[..MAX_IMAGE]).is_ok());
    assert_eq!(CpuLoader::new(&[]).err(), Some(LoadError::Empty));
    assert_eq!(CpuLoader::with_layout(&[0; 16], 0x7FC, 0x7FC).err(), Some(LoadError::AddressRefused));
    assert_eq!(CpuLoader::with_layout(&[0; 16], 0x0001_0000, 0x0001_0000).err(), Some(LoadError::AddressRefused));
    assert_eq!(CpuLoader::with_layout(&[0; 16], 0x3FF8, 0x3FF8).err(), Some(LoadError::TooLarge { len: 16 }));
    assert_eq!(CpuLoader::with_layout(&[0; 16], 0x800, 0x810).err(), Some(LoadError::AddressRefused));

    // finished datagrams: the whitelist check
    let mut b = [0u8; 512];
    let n = bridge::build_write_read(APP_START, &[1, 2], &[APP_START, APP_START + 4], &mut b).unwrap();
    assert_eq!(check_request(&b[..n]), Ok(()));
    for (a, reads) in [(0x4003_0008u32, &[][..]), (0x4003_0000, &[sys::ID][..]), (frontend::CMD_ADDR, &[][..]), (0x0001_0000, &[][..])] {
        let n = bridge::build_write_read(a, &[0x3A], reads, &mut b).unwrap();
        assert!(check_request(&b[..n]).is_err(), "0x{a:08x}");
    }
    let n = bridge::build_read(&[0x4002_0000], &mut b).unwrap();
    assert!(check_request(&b[..n]).is_err(), "reads outside RAM, system and status blocks");
    assert!(check_request(&[0x4E, 0x6F, 0x10, 0x44]).is_err());
    assert!(check_request(b"HM\x01\x05").is_err());
}

#[test]
fn simulated_cpu_resets_and_boots() {
    let rig = Rig::new(&image());
    assert_eq!(rig.radio.cpu.fw_status >> 24, sys::FWS_ROM_IDLE);
    assert!(!rig.radio.msg_running());
    // An HL2 with the program saved in flash: the message layer runs from power-up.
    let mut s = Hl2Sim::new(1);
    assert!(s.msg_running());
    // Holding the CPU in reset stops it; releasing without boot-RAM starts the saved program again.
    let mut b = [0u8; 512];
    let n = bridge::build_write_read(sys::CTRL, &[sys::CTRL_RESET], &[sys::STATUS], &mut b).unwrap();
    s.input(0, &b[..n]);
    assert!(!s.msg_running());
    let n = bridge::build_write_read(sys::CTRL, &[0], &[sys::FW_STATUS], &mut b).unwrap();
    s.input(1, &b[..n]);
    assert!(s.msg_running());
    assert_eq!(s.cpu.resets, 1);
    assert_eq!(s.cpu.forbidden_writes, 0);
}
