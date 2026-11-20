// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! A simulated HL2 for tests: the message-layer firmware (`msg.c` and the request handlers of
//! `main.c`, firmware version 0x0003_0001) ported line by line, over a model of the registers it
//! touches, the I2C devices and the command bus. It also answers the register bridge: reads, and
//! writes to the CPU's RAM and system block (reset, boot address, boot from RAM), so that an HL2
//! whose CPU has no program can be given one (`cpuload`), and the boot ROM's save and boot as
//! `firmware/hl2neo/bootrom/rom.c` does them: the console save datagram (`01 'S'`, CRC check of the
//! RAM before the erase, the result register, the locked state after network flashing, a flash
//! fault), the start of the saved program at a normal restart, and the stay-in-ROM control bit.
//! A lossy link and a test bench tie it to an `Hl2Control`.
//!
//! No allocation, so firmware tests can use it too (feature `sim`).

use crate::bridge::{frontend, status};
use crate::cpuload::sys;
use crate::control::Hl2Control;
use crate::filter;
use crate::msg::{self, get16, get32, put16, put32, time_reached, Header, Ring, MAX_DATAGRAM, MAX_PAYLOAD};

/// Firmware version main.c reports.
pub const FW_VERSION: u32 = 0x0003_0001;
/// Status block values of this gateware image (PROTOCOL.md 8.2).
pub const GW_VERSION: u32 = 0x4A02_D101;
pub const CAPS: u32 = 0x7C;

const RAM_SIZE: u32 = 0x4000;
const PKT_BASE: u32 = 0x4002_0000;
const FL_BASE: u32 = 0x4003_0000;
const SYS_MS: u32 = 0x4001_0018;

const PERMIT_KEY: u32 = 0x5458_0000;
const CLEAR_KEY: u32 = 0x434C_5452;
const WDOG_KEY: u32 = 0x5744_4F47;
const BIAS_KEY: u32 = 0x4249_4153;

/// ILK_STATUS of an idle radio: a cut-off present, namely "no valid lease".
pub const ILK_IDLE: u32 = (1 << 5) | (1 << 16);

/// One datagram.
#[derive(Clone, Copy)]
pub struct Datagram {
    pub len: usize,
    pub data: [u8; 512],
}

impl Datagram {
    pub fn new(d: &[u8]) -> Datagram {
        let mut data = [0u8; 512];
        let len = d.len().min(512);
        data[..len].copy_from_slice(&d[..len]);
        Datagram { len, data }
    }
    pub fn as_slice(&self) -> &[u8] {
        &self.data[..self.len]
    }
}

/// The registers, I2C devices and command bus the firmware reaches.
pub struct SimHardware {
    pub temp_code: u16,
    pub fwd_code: u16,
    pub rev_code: u16,
    pub bias_code: u16,
    pub ilk_status: u32,
    /// Front-end block INPUTS.
    pub inputs: u32,
    pub safety: u8,
    pub lease_ms: u32,
    pub maxkey_s: u32,
    pub temp_limit: u32,
    pub keytime: u32,
    pub wdog: u32,
    pub wdog_ms: u32,
    pub cmd_data: u32,
    pub cmd_count: u8,
    pub cmd_last: u8,
    /// Every command bus write, in order (address, value); the oldest are dropped after 64.
    pub cmd_log: [(u8, u32); 64],
    pub cmd_log_len: usize,
    /// Command register 0x00 as last written.
    pub reg0: u32,
    /// Status block RX_GAIN register: [6:0] last 0x0A value, [8] one was seen.
    pub rx_gain: u32,
    pub i2c_flags: u32,
    pub i2c_done: u8,
    pub i2c_refdrop: u8,
    pub i2c_rdata: u32,
    pub bias_unlock: u32,
    pub led: u32,
    pub fan: u32,
    pub pkt_count: u32,
    /// MCP23008 on bus 2 at 0x20 (registers 0-10; 0x09 GPIO, 0x0A OLAT).
    pub mcp23008: [u8; 11],
    /// MCP4662 on bus 2 at 0x2C, by memory address (register byte bits 7:4).
    pub mcp4662: [u16; 16],
    /// VersaClock 5 on bus 1 at 0x6A.
    pub vc5: [u8; 256],
    /// Counters of writes that change transmit behavior (the client must never cause any).
    pub tx_permit_writes: u32,
    pub bias_unlock_writes: u32,
    pub i2c_writes: u32,
    pub trips_cleared: u32,
    /// Fault injection: the command bus stays busy (CMD answers busy).
    pub cmd_busy: bool,
    /// Fault injection: the next I2C transfer is dropped (engine busy).
    pub i2c_drop_next: bool,
}

impl Default for SimHardware {
    fn default() -> Self {
        SimHardware {
            temp_code: 942, // about 25 degC
            fwd_code: 0,
            rev_code: 0,
            bias_code: 0,
            ilk_status: ILK_IDLE,
            inputs: 0,
            safety: crate::protocol::SAFETY_IDLE,
            lease_ms: 100,
            maxkey_s: 600,
            temp_limit: 0x527,
            keytime: 0,
            wdog: 0,
            wdog_ms: 1000,
            cmd_data: 0,
            cmd_count: 0,
            cmd_last: 0,
            cmd_log: [(0, 0); 64],
            cmd_log_len: 0,
            reg0: 0,
            rx_gain: 0,
            i2c_flags: 0,
            i2c_done: 0,
            i2c_refdrop: 0,
            i2c_rdata: 0,
            bias_unlock: 0,
            led: 0,
            fan: 0,
            pkt_count: 0,
            mcp23008: [0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            mcp4662: [0x80; 16],
            vc5: [0; 256],
            tx_permit_writes: 0,
            bias_unlock_writes: 0,
            i2c_writes: 0,
            trips_cleared: 0,
            cmd_busy: false,
            i2c_drop_next: false,
        }
    }
}

impl SimHardware {
    /// A CPU read (the CPU's view: status mirror, system block, front-end block).
    pub fn read(&self, a: u32, now: u32) -> u32 {
        match a {
            status::ID => status::ID_EXPECTED,
            status::VERSION => GW_VERSION,
            status::CAPABILITIES => CAPS,
            status::TEMPERATURE => self.temp_code as u32,
            status::FWD_POWER => self.fwd_code as u32,
            status::REV_POWER => self.rev_code as u32,
            status::PA_BIAS => self.bias_code as u32,
            status::INPUTS => if self.safety & crate::protocol::SAFETY_PA_KEYED != 0 { crate::cpuload::INPUT_TRANSMIT_ON } else { 0 },
            status::SAFETY_BYTE => self.safety as u32,
            SYS_MS => now,
            frontend::ID => frontend::ID_EXPECTED,
            frontend::TX_PERMIT => 0,
            frontend::ILK_STATUS => self.ilk_status,
            frontend::LEASE_MS => self.lease_ms,
            frontend::MAXKEY_S => self.maxkey_s,
            frontend::TEMP_LIMIT => self.temp_limit,
            frontend::KEYTIME => self.keytime,
            frontend::WDOG => self.wdog,
            frontend::WDOG_MS => self.wdog_ms,
            frontend::CMD_DATA => self.cmd_data,
            frontend::CMD_ADDR => (self.cmd_count as u32) << 8 | self.cmd_last as u32,
            frontend::I2C_STATUS => (self.i2c_refdrop as u32) << 24 | (self.i2c_done as u32) << 16 | self.i2c_flags,
            frontend::I2C_RDATA => self.i2c_rdata,
            frontend::BIAS_UNLOCK => self.bias_unlock,
            frontend::LED => self.led,
            frontend::FAN => self.fan,
            frontend::INPUTS => self.inputs,
            a if a == PKT_BASE + 0x0C => self.pkt_count,
            a if a < RAM_SIZE => 0,
            _ => 0xFFFF_FFFF,
        }
    }

    /// The bridge's view adds the status registers the CPU mirror lacks.
    pub fn bridge_read(&self, a: u32, now: u32) -> u32 {
        match a {
            status::RX_GAIN => self.rx_gain,
            status::SCRATCH => 0x1234_5678,
            _ => self.read(a, now),
        }
    }

    /// A CPU write. Status mirror writes are ignored, as in the gateware.
    pub fn write(&mut self, a: u32, v: u32) {
        match a {
            frontend::TX_PERMIT => {
                if v & 0xFFFF_0000 == PERMIT_KEY {
                    self.tx_permit_writes += 1;
                }
            }
            frontend::ILK_CLEAR => {
                if v == CLEAR_KEY {
                    self.trips_cleared += 1;
                    self.ilk_status &= !(0x3F << 8 | 1 << 4);
                }
            }
            frontend::LEASE_MS => self.lease_ms = v.clamp(10, 1000),
            frontend::MAXKEY_S => self.maxkey_s = v.clamp(1, 600),
            frontend::TEMP_LIMIT => self.temp_limit = v.min(0x527),
            frontend::WDOG => {
                if v == WDOG_KEY {
                    self.wdog = 1 << 30 | self.wdog_ms;
                }
            }
            frontend::WDOG_MS => self.wdog_ms = v.clamp(10, 60_000),
            frontend::CMD_DATA => self.cmd_data = v,
            frontend::CMD_ADDR => self.command(v as u8 & 0x3F, self.cmd_data),
            frontend::I2C_XFER => {
                let (code, data) = self.i2c(v);
                self.i2c_finish(code, data);
            }
            frontend::BIAS_UNLOCK => {
                self.bias_unlock_writes += 1;
                self.bias_unlock = v;
            }
            frontend::LED => self.led = v & 0xFF,
            frontend::FAN => self.fan = v & 0xF,
            _ => {}
        }
    }

    /// A command bus write.
    pub fn command(&mut self, addr: u8, value: u32) {
        if self.cmd_log_len == self.cmd_log.len() {
            self.cmd_log.copy_within(1.., 0);
            self.cmd_log_len -= 1;
        }
        self.cmd_log[self.cmd_log_len] = (addr, value);
        self.cmd_log_len += 1;
        self.cmd_count = self.cmd_count.wrapping_add(1);
        self.cmd_last = addr;
        match addr {
            0x00 => {
                self.reg0 = value;
                // The gateware drives the MCP23008 from register 0x00.
                self.mcp23008[0x0A] = filter::expected_olat(value);
                self.mcp23008[0x09] = self.mcp23008[0x0A];
            }
            0x0A => self.rx_gain = (value & 0x7F) | 1 << 8,
            _ => {}
        }
    }

    pub fn commands(&self) -> &[(u8, u32)] {
        &self.cmd_log[..self.cmd_log_len]
    }

    /// One I2C transfer: (code, data) with main.c's codes 0 ok, 1 NACK, 2 refused, 3 dropped.
    pub fn i2c(&mut self, word: u32) -> (u32, u32) {
        let bus = word >> 30;
        let read = word & 1 << 24 != 0;
        let probe = word & 1 << 23 != 0;
        let addr = (word >> 16) as u8 & 0x7F;
        let reg = (word >> 8) as u8;
        let val = word as u8;
        if self.i2c_drop_next {
            self.i2c_drop_next = false;
            return (3, 0);
        }
        if bus == 2 && addr == 0x2C && !probe && self.bias_unlock != BIAS_KEY && (!read || reg & 0x0C != 0x0C) {
            return (2, 0);
        }
        let present = matches!((bus, addr), (1, 0x6A) | (2, 0x20) | (2, 0x2C) | (3, 0x34));
        if !present {
            return (1, 0);
        }
        if probe {
            return (0, 0xFF << 24);
        }
        let byte = |s: &Self, r: u8| -> u8 {
            match (bus, addr) {
                (1, _) => s.vc5[r as usize],
                (2, 0x20) => *s.mcp23008.get(r as usize).unwrap_or(&0),
                (2, 0x2C) => s.mcp4662[(r >> 4) as usize] as u8,
                _ => 0,
            }
        };
        if read {
            let mut d = 0u32;
            for i in 0..4u8 {
                d |= (byte(self, reg.wrapping_add(i)) as u32) << (8 * i);
            }
            return (0, d);
        }
        self.i2c_writes += 1;
        match (bus, addr) {
            (1, _) => self.vc5[reg as usize] = val,
            (2, 0x20) => {
                if let Some(r) = self.mcp23008.get_mut(reg as usize) {
                    *r = val;
                }
            }
            (2, 0x2C) => self.mcp4662[(reg >> 4) as usize] = (((reg & 3) as u16) << 8) | val as u16,
            _ => {}
        }
        (0, 0)
    }

    fn i2c_finish(&mut self, code: u32, data: u32) {
        match code {
            0 | 1 => {
                self.i2c_done = self.i2c_done.wrapping_add(1);
                self.i2c_rdata = data;
                self.i2c_flags = if code == 1 { 2 } else { 0 };
            }
            c => {
                self.i2c_refdrop = self.i2c_refdrop.wrapping_add(1);
                self.i2c_flags = if c == 2 { 4 } else { 8 };
            }
        }
    }
}

/// The CPU as the register bridge sees it: RAM, the system block, and which program runs.
/// The message layer runs only after a boot of the right image (or, for `Hl2Sim::new`, from the
/// flash sector).
pub struct SimCpu {
    pub ram: [u32; (RAM_SIZE / 4) as usize],
    pub ctrl: u32,
    pub boot_addr: u32,
    pub fw_status: u32,
    /// CPU resets since power-up.
    pub resets: u16,
    /// What the flash sector holds (the boot ROM starts it at a normal restart).
    pub flash: Option<SavedImage>,
    /// Version of the program that runs (what HELLO reports).
    pub running_version: u32,
    /// Version the image `set_program` accepts reports when it runs.
    pub program_version: u32,
    /// Result register (0x4001_0014) and the ROM's result sequence.
    pub fw_result: u32,
    pub result_seq: u8,
    /// Network flashing was seen since power-up: the ROM's flash commands are refused.
    pub locked: bool,
    /// Fault injection: the flash fails after the erase (result 3; the sector is left empty).
    pub flash_fault: bool,
    /// Save datagrams the ROM acted on, erase datagrams received, and every flash erase done.
    pub saves: u32,
    pub erase_datagrams: u32,
    pub erases: u32,
    /// Length in words and hash of the message-layer image: a boot from RAM starts the message
    /// layer only if RAM from 0x800 holds exactly this.
    pub program_words: usize,
    pub program_hash: u64,
    /// The message layer runs (answers HM datagrams, sends telemetry).
    pub running: bool,
    /// Fault injection: the RAM word at this address stores the written value with these bits flipped.
    pub stuck: Option<(u32, u32)>,
    /// Bridge writes to anything but the RAM from 0x800 and the control, boot address and firmware
    /// state registers. The loader must cause none.
    pub forbidden_writes: u32,
    /// Bridge writes to RAM (words).
    pub ram_writes: u32,
    /// Boots from RAM.
    pub ram_boots: u32,
}

/// What the flash sector holds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SavedImage {
    /// The version in the saved header.
    pub version: u32,
    /// The image is the message-layer program (it runs when the ROM starts it; anything else traps).
    pub runs: bool,
    /// Length and CRC-32 in the saved header.
    pub length: u32,
    pub crc32: u32,
}

/// FNV-1a over the little-endian bytes of `words` words of `img`, zero-padded.
fn image_hash(img: impl Fn(usize) -> u32, words: usize) -> u64 {
    let mut h: u64 = 0xCBF2_9CE4_8422_2325;
    for i in 0..words {
        for b in img(i).to_le_bytes() {
            h = (h ^ b as u64).wrapping_mul(0x0000_0100_0000_01B3);
        }
    }
    h
}

impl SimCpu {
    fn new() -> SimCpu {
        SimCpu {
            ram: [0; (RAM_SIZE / 4) as usize],
            ctrl: 0,
            boot_addr: crate::cpuload::APP_START,
            fw_status: sys::FWS_APP << 24,
            resets: 0,
            flash: Some(SavedImage { version: FW_VERSION, runs: true, length: 0, crc32: 0 }),
            running_version: FW_VERSION,
            program_version: FW_VERSION,
            fw_result: 0,
            result_seq: 0,
            locked: false,
            flash_fault: false,
            saves: 0,
            erase_datagrams: 0,
            erases: 0,
            program_words: 0,
            program_hash: 0,
            running: true,
            stuck: None,
            forbidden_writes: 0,
            ram_writes: 0,
            ram_boots: 0,
        }
    }

    /// Sets the image a boot from RAM accepts as the message layer.
    pub fn set_program(&mut self, img: &[u8]) {
        let words = img.len().div_ceil(4);
        self.program_words = words;
        self.program_hash = image_hash(
            |i| {
                let mut b = [0u8; 4];
                for (k, x) in b.iter_mut().enumerate() {
                    *x = *img.get(4 * i + k).unwrap_or(&0);
                }
                u32::from_le_bytes(b)
            },
            words,
        );
    }

    /// True if RAM from the boot address holds the message-layer image.
    fn ram_has_program(&self) -> bool {
        self.range_is_program(self.boot_addr, 4 * self.program_words as u32)
    }

    /// True if `len` bytes of RAM from `addr` are the message-layer image.
    fn range_is_program(&self, addr: u32, len: u32) -> bool {
        let first = (addr / 4) as usize;
        addr == crate::cpuload::APP_START
            && self.program_words != 0
            && len.div_ceil(4) as usize == self.program_words
            && first + self.program_words <= self.ram.len()
            && image_hash(|i| self.ram[first + i], self.program_words) == self.program_hash
    }

    /// RAM bytes as the CPU sees them (little-endian words).
    fn ram_byte(&self, a: u32) -> u8 {
        (self.ram[(a / 4) as usize] >> (8 * (a % 4))) as u8
    }

    /// rom.c `result`.
    fn result(&mut self, op: u8, code: u8) {
        self.result_seq = self.result_seq.wrapping_add(1);
        self.fw_result = (op as u32) << 24 | (self.result_seq as u32) << 16 | code as u32;
    }

    /// rom.c `fw_save`: header checks, CRC of the RAM against the wanted one, erase, write, verify.
    fn save(&mut self, load: u32, len: u32, entry: u32, version: u32, want_crc: u32) -> u8 {
        let app_end = RAM_SIZE;
        if load < crate::cpuload::APP_START || len > 0x1_0000 - 32 || load + len > app_end || entry.wrapping_sub(load) >= len {
            return sys::FWR_BAD_ARGS;
        }
        let mut c = !0u32;
        for a in load..load + len {
            c ^= self.ram_byte(a) as u32;
            for _ in 0..8 {
                c = if c & 1 != 0 { (c >> 1) ^ 0xEDB8_8320 } else { c >> 1 };
            }
        }
        let crc = !c;
        if want_crc != 0 && want_crc != crc {
            return sys::FWR_CRC_MISMATCH;
        }
        if self.locked {
            return sys::FWR_LOCKED;
        }
        self.erases += 1;
        self.flash = None;
        if self.flash_fault {
            return sys::FWR_FLASH_ERR;
        }
        self.flash = Some(SavedImage { version, runs: self.range_is_program(load, len), length: len, crc32: crc });
        sys::FWR_OK
    }

    /// rom.c `ctrl_datagram`, while the ROM is idle.
    fn console(&mut self, d: &[u8]) {
        let le = |i: usize| u32::from_le_bytes([d[i], d[i + 1], d[i + 2], d[i + 3]]);
        match d.get(1) {
            Some(b'S') => {
                self.saves += 1;
                let code = if d.len() < 22 { sys::FWR_BAD_ARGS } else { self.save(le(2), le(6), le(10), le(14), le(18)) };
                self.result(b'S', code);
            }
            Some(b'E') => {
                self.erase_datagrams += 1;
                let code = if self.locked {
                    sys::FWR_LOCKED
                } else {
                    self.erases += 1;
                    self.flash = None;
                    sys::FWR_OK
                };
                self.result(b'E', code);
            }
            _ => {}
        }
    }

    fn read(&self, a: u32, now: u32) -> Option<u32> {
        Some(match a {
            a if a < RAM_SIZE => self.ram[(a / 4) as usize],
            sys::ID => sys::ID_EXPECTED,
            sys::INFO => 2 << 24 | 4 << 16 | (RAM_SIZE >> 10) << 8,
            sys::CTRL => self.ctrl,
            sys::BOOT_ADDR => self.boot_addr,
            sys::FW_STATUS => self.fw_status,
            sys::FW_RESULT => self.fw_result,
            sys::MS => now,
            sys::STATUS => self.resets as u32 | if self.ctrl & sys::CTRL_RESET != 0 { sys::STATUS_IN_RESET } else { 0 },
            _ => return None,
        })
    }
}

/// The simulated HL2: msg.c state plus `SimHardware`.
pub struct Hl2Sim {
    boot_id: u32,
    rx_seq: u16,
    session: bool,
    cache: [u8; MAX_DATAGRAM],
    cache_len: usize,
    tx_seq: u16,
    ev_pkt: [u8; MAX_DATAGRAM],
    ev_len: usize,
    ev_due: u32,
    ev_wait: u32,
    ev_sends: u8,
    tele_period: u32,
    tele_due: u32,
    tele_count: u32,
    ev_state: u32,
    now: u32,
    out: Ring<Datagram, 64>,
    pub hw: SimHardware,
    pub cpu: SimCpu,
    /// Request messages executed (repeats answered from the cache do not count).
    pub executed: u32,
}

impl Hl2Sim {
    pub fn new(boot_id: u32) -> Hl2Sim {
        Hl2Sim {
            boot_id,
            rx_seq: 0,
            session: false,
            cache: [0; MAX_DATAGRAM],
            cache_len: 0,
            tx_seq: 0,
            ev_pkt: [0; MAX_DATAGRAM],
            ev_len: 0,
            ev_due: 0,
            ev_wait: 0,
            ev_sends: 0,
            tele_period: 100,
            tele_due: 0,
            tele_count: 0,
            ev_state: !0,
            now: 0,
            out: Ring::new(),
            hw: SimHardware::default(),
            cpu: SimCpu::new(),
            executed: 0,
        }
    }

    /// An HL2 whose CPU has no program: nothing in the flash sector, the boot ROM idles, port 1027
    /// messages get no answer. `program` is the message-layer image a boot from RAM accepts.
    pub fn without_program(boot_id: u32, program: &[u8]) -> Hl2Sim {
        let mut s = Hl2Sim::new(boot_id);
        s.cpu.flash = None;
        s.cpu.running = false;
        s.cpu.fw_status = sys::FWS_ROM_IDLE << 24 | 0x06;
        s.cpu.set_program(program);
        s
    }

    /// An HL2 that runs an older message-layer program, saved with `version`. `program` is the
    /// image a boot from RAM or a save accepts as the new program (version [`FW_VERSION`]).
    pub fn with_saved_version(boot_id: u32, version: u32, program: &[u8]) -> Hl2Sim {
        let mut s = Hl2Sim::new(boot_id);
        s.cpu.flash = Some(SavedImage { version, runs: true, length: 0, crc32: 0 });
        s.cpu.running_version = version;
        s.cpu.set_program(program);
        s
    }

    /// The firmware restarts with a new boot ID (the gateware registers and the CPU keep their values).
    pub fn reboot(&mut self, boot_id: u32) {
        let hw = core::mem::take(&mut self.hw);
        let cpu = core::mem::replace(&mut self.cpu, SimCpu::new());
        let now = self.now;
        *self = Hl2Sim::new(boot_id);
        self.hw = hw;
        self.cpu = cpu;
        self.now = now;
    }

    /// The message-layer firmware runs.
    pub fn msg_running(&self) -> bool {
        self.cpu.running
    }

    pub fn boot_id(&self) -> u32 {
        self.boot_id
    }

    /// The boot ROM after the CPU leaves reset (rom.c `rom_main`).
    fn cpu_boot(&mut self) {
        self.cpu.resets = self.cpu.resets.wrapping_add(1);
        let ctrl = self.cpu.ctrl;
        let start = if ctrl & sys::CTRL_BOOT_RAM != 0 {
            self.cpu.ram_boots += 1;
            if self.cpu.ram_has_program() {
                self.cpu.running_version = self.cpu.program_version;
                true
            } else {
                // whatever is in RAM is not the program: it traps at once (illegal instruction)
                self.cpu.fw_status = sys::FWS_STOPPED << 24 | 4;
                return;
            }
        } else if ctrl & sys::CTRL_STAY_ROM != 0 {
            false
        } else {
            match self.cpu.flash {
                Some(SavedImage { runs: true, version, .. }) => {
                    self.cpu.running_version = version;
                    true
                }
                Some(_) => {
                    // a saved image that is not the program: it traps at once
                    self.cpu.fw_status = sys::FWS_STOPPED << 24 | 4;
                    return;
                }
                None => {
                    self.cpu.fw_result = (b'B' as u32) << 24 | sys::FWR_NO_IMAGE as u32;
                    false
                }
            }
        };
        if start {
            let id = self.boot_id.wrapping_add(0x0001_0000);
            self.reboot(id);
            self.cpu.running = true;
            self.cpu.fw_status = sys::FWS_APP << 24;
        } else {
            self.cpu.fw_status = sys::FWS_ROM_IDLE << 24 | if ctrl & sys::CTRL_STAY_ROM != 0 { 0 } else { 0x06 };
        }
    }

    /// One register bridge write.
    fn bridge_write(&mut self, a: u32, v: u32) {
        match a {
            a if (crate::cpuload::APP_START..RAM_SIZE).contains(&a) && a & 3 == 0 => {
                let flip = match self.cpu.stuck {
                    Some((sa, m)) if sa == a => m,
                    _ => 0,
                };
                self.cpu.ram[(a / 4) as usize] = v ^ flip;
                self.cpu.ram_writes += 1;
            }
            sys::CTRL => {
                let old = self.cpu.ctrl;
                self.cpu.ctrl = v & 0xF;
                if v & sys::CTRL_RESET != 0 {
                    self.cpu.running = false;
                } else if old & sys::CTRL_RESET != 0 {
                    self.cpu_boot();
                }
            }
            sys::BOOT_ADDR => self.cpu.boot_addr = v,
            sys::FW_STATUS => self.cpu.fw_status = v,
            sys::FW_RESULT => self.cpu.fw_result = v,
            _ => {
                self.cpu.forbidden_writes += 1;
                if a < RAM_SIZE {
                    self.cpu.ram[(a / 4) as usize] = v;
                }
            }
        }
    }

    pub fn session(&self) -> bool {
        self.session
    }
    pub fn telemetry_period(&self) -> u32 {
        self.tele_period
    }

    pub fn pop_output(&mut self) -> Option<Datagram> {
        self.out.pop()
    }

    fn send(&mut self, d: &[u8]) {
        self.hw.pkt_count = self.hw.pkt_count.wrapping_add(1 << 16);
        self.out.push_overwrite(Datagram::new(d));
    }

    fn header(&self, p: &mut [u8], flags: u8, seq: u16, len: usize) -> usize {
        Header { flags: flags | msg::F_ACK_VALID, boot_id: self.boot_id, seq, ack: self.rx_seq, len: len as u16 }.write(p);
        msg::HDR_SIZE + len
    }

    fn execute(&mut self, d: &[u8], dst: &mut [u8]) -> usize {
        let (mut i, mut o) = (0usize, 0usize);
        while i + 6 <= d.len() {
            let mlen = get16(&d[i + 4..]) as usize;
            if i + 6 + mlen > d.len() || o + 7 > MAX_PAYLOAD {
                break;
            }
            let r = self.app_request(d[i], d[i + 1], &d[i + 6..i + 6 + mlen], &mut dst[o + 6..MAX_PAYLOAD]);
            self.executed += 1;
            dst[o] = d[i];
            dst[o + 1] = d[i + 1] | msg::RESPONSE;
            dst[o + 2] = d[i + 2];
            dst[o + 3] = d[i + 3];
            put16(&mut dst[o + 4..], r as u16);
            o += 6 + r;
            i += 6 + mlen;
        }
        o
    }

    /// One datagram received on port 1027.
    pub fn input(&mut self, now: u32, d: &[u8]) {
        self.now = now;
        if d.first() == Some(&0x4E) {
            self.bridge(d);
            return;
        }
        if d.first() == Some(&0x01) {
            // the boot ROM's console; it acts on save and erase only while it is idle
            if !self.cpu.running && self.cpu.fw_status >> 24 == sys::FWS_ROM_IDLE && self.cpu.ctrl & sys::CTRL_RESET == 0 {
                self.cpu.console(d);
            }
            return;
        }
        if !self.cpu.running {
            return; // no program: the boot ROM ignores message datagrams
        }
        let n = d.len();
        if n < msg::HDR_SIZE || d[0] != b'H' || d[1] != b'M' || d[2] != msg::VERSION {
            return;
        }
        let flags = d[3];
        let seq = get16(&d[8..]);
        let len = get16(&d[12..]) as usize;
        if msg::HDR_SIZE + len > n || len > MAX_PAYLOAD {
            return;
        }
        if flags & msg::F_ACK_VALID != 0 && self.ev_len != 0 && get16(&d[10..]) == self.tx_seq {
            self.ev_len = 0;
        }
        let payload = &d[msg::HDR_SIZE..msg::HDR_SIZE + len];
        let mut buf = [0u8; MAX_DATAGRAM];
        if flags & msg::F_RELIABLE != 0 {
            if flags & msg::F_RESET != 0 && (!self.session || seq != self.rx_seq) {
                self.rx_seq = seq.wrapping_sub(1);
                self.session = true;
                self.cache_len = 0;
                self.ev_len = 0;
                self.tele_due = now;
            }
            if self.session && seq == self.rx_seq.wrapping_add(1) {
                self.rx_seq = seq;
                let r = self.execute(payload, &mut buf[msg::HDR_SIZE..]);
                let mut c = [0u8; MAX_DATAGRAM];
                c[msg::HDR_SIZE..msg::HDR_SIZE + r].copy_from_slice(&buf[msg::HDR_SIZE..msg::HDR_SIZE + r]);
                self.cache_len = self.header(&mut c, 0, 0, r);
                self.cache = c;
                let c = self.cache;
                self.send(&c[..self.cache_len]);
            } else if self.session && seq == self.rx_seq && self.cache_len != 0 {
                let c = self.cache;
                self.send(&c[..self.cache_len]);
            } else {
                let l = self.header(&mut buf, 0, 0, 0);
                self.send(&buf[..l]);
            }
        } else if len != 0 {
            let r = self.execute(payload, &mut buf[msg::HDR_SIZE..]);
            let l = self.header(&mut buf, 0, 0, r);
            self.send(&buf[..l]);
        }
    }

    /// msg_poll: event retransmission, new events, telemetry.
    pub fn poll(&mut self, now: u32) {
        self.now = now;
        if !self.session || !self.cpu.running {
            return;
        }
        if self.ev_len != 0 {
            if time_reached(now, self.ev_due) {
                if self.ev_sends >= 6 {
                    self.ev_len = 0;
                } else {
                    put16(&mut self.ev_pkt[10..], self.rx_seq);
                    let p = self.ev_pkt;
                    self.send(&p[..self.ev_len]);
                    self.ev_sends += 1;
                    self.ev_due = now.wrapping_add(self.ev_wait);
                    if self.ev_wait < 800 {
                        self.ev_wait <<= 1;
                    }
                }
            }
        } else {
            let mut body = [0u8; 12];
            let n = self.app_event(&mut body);
            if n != 0 {
                let mut p = [0u8; MAX_DATAGRAM];
                p[16] = msg::class::EVENT;
                p[17] = 1;
                put16(&mut p[18..], 0);
                put16(&mut p[20..], n as u16);
                p[22..22 + n].copy_from_slice(&body[..n]);
                self.tx_seq = self.tx_seq.wrapping_add(1);
                self.ev_len = self.header(&mut p, msg::F_RELIABLE, self.tx_seq, n + 6);
                self.ev_pkt = p;
                self.ev_sends = 0;
                self.ev_wait = 50;
                self.ev_due = now;
            }
        }
        if self.tele_period != 0 && time_reached(now, self.tele_due) {
            self.tele_due = now.wrapping_add(self.tele_period);
            let mut p = [0u8; MAX_DATAGRAM];
            p[16] = msg::class::TELEMETRY;
            p[17] = 1;
            put32(&mut p[22..], self.tele_count);
            self.tele_count = self.tele_count.wrapping_add(1);
            let n = 4 + self.app_telemetry(&mut p[26..]);
            put16(&mut p[20..], n as u16);
            let l = self.header(&mut p, 0, 0, n + 6);
            self.send(&p[..l]);
        }
    }

    fn reg_write_ok(a: u32) -> bool {
        let hi = a >> 16;
        a >= RAM_SIZE && hi != 1 && hi != PKT_BASE >> 16 && hi != FL_BASE >> 16
    }

    /// main.c `app_request`, including the requests the client never sends (transmit permission,
    /// bias unlock), so that the model stays complete.
    fn app_request(&mut self, cls: u8, op: u8, b: &[u8], o: &mut [u8]) -> usize {
        let len = b.len();
        let max = o.len();
        let now = self.now;
        o[0] = msg::status::OK;
        let hw = &mut self.hw;
        match (cls, op) {
            (0, 1) => {
                o[1] = msg::VERSION;
                o[2] = 0;
                o[3] = 0;
                put32(&mut o[4..], GW_VERSION);
                put32(&mut o[8..], self.cpu.running_version);
                put32(&mut o[12..], CAPS);
                put16(&mut o[16..], MAX_PAYLOAD as u16);
                put16(&mut o[18..], self.tele_period as u16);
                put32(&mut o[20..], frontend::ID_EXPECTED);
                return 24;
            }
            (0, 2) => {
                let mut i = 0;
                while i < len && i + 1 < max {
                    o[1 + i] = b[i];
                    i += 1;
                }
                return 1 + i;
            }
            (0, 3) => {
                if len >= 2 {
                    self.tele_period = get16(b) as u32;
                    self.tele_due = now;
                    return 1;
                }
            }
            (1, 1) => {
                if !(len < 5 || b[4] == 0 || b[4] > 32 || 1 + 4 * b[4] as usize > max) {
                    let mut v = get32(b);
                    for i in 0..b[4] as usize {
                        put32(&mut o[1 + 4 * i..], hw.read(v, now));
                        v = v.wrapping_add(4);
                    }
                    return 1 + 4 * b[4] as usize;
                }
            }
            (1, 2) => {
                if !(len < 8 || len & 3 != 0) {
                    let mut v = get32(b);
                    let mut i = 4;
                    while i < len {
                        if !Self::reg_write_ok(v) {
                            o[0] = msg::status::REFUSED;
                            break;
                        }
                        hw.write(v, get32(&b[i..]));
                        i += 4;
                        v = v.wrapping_add(4);
                    }
                    o[1] = ((i - 4) / 4) as u8;
                    return 2;
                }
            }
            (2, 1) => {
                if !(len < 5 || b[0] < 1 || b[0] > 3) {
                    let word = (b[0] as u32) << 30
                        | if b[2] & 1 != 0 { 1 << 24 } else { 0 }
                        | if b[2] & 2 != 0 { 1 << 24 | 1 << 23 } else { 0 }
                        | ((b[1] & 0x7F) as u32) << 16
                        | (b[3] as u32) << 8
                        | b[4] as u32;
                    let (code, data) = hw.i2c(word);
                    hw.i2c_finish(code, data);
                    o[1] = code as u8;
                    put32(&mut o[2..], data);
                    return 6;
                }
            }
            (2, 2) => {
                if !(len < 3 || b[0] < 1 || b[0] > 3 || b[2] > 127 || max < 17) {
                    o[1..17].fill(0);
                    let mut i = b[1] as u32;
                    while i <= b[2] as u32 {
                        let (n, data) = hw.i2c((b[0] as u32) << 30 | 1 << 24 | 1 << 23 | i << 16);
                        hw.i2c_finish(n, data);
                        if n == 0 {
                            o[1 + (i / 8) as usize] |= 1 << (i % 8);
                        } else if n > 1 {
                            o[0] = msg::status::BUSY;
                        }
                        i += 1;
                    }
                    return 17;
                }
            }
            (3, 1) => {
                if len >= 1 {
                    hw.write(frontend::TX_PERMIT, PERMIT_KEY | (b[0] & 7) as u32);
                    put32(&mut o[1..], hw.ilk_status);
                    return 5;
                }
            }
            (3, 2) => {
                hw.write(frontend::ILK_CLEAR, CLEAR_KEY);
                put32(&mut o[1..], hw.ilk_status);
                return 5;
            }
            (3, 3) => {
                if len >= 1 {
                    hw.write(frontend::BIAS_UNLOCK, if b[0] != 0 { BIAS_KEY } else { 0 });
                    return 1;
                }
            }
            (3, 4) => {
                if !(len < 5 || b[0] > 63) {
                    if hw.cmd_busy {
                        o[0] = msg::status::BUSY;
                        return 1;
                    }
                    hw.write(frontend::CMD_DATA, get32(&b[1..]));
                    hw.write(frontend::CMD_ADDR, b[0] as u32);
                    return 1;
                }
            }
            (3, 5) => {
                if len >= 6 {
                    for (k, a) in [frontend::LEASE_MS, frontend::MAXKEY_S, frontend::TEMP_LIMIT].into_iter().enumerate() {
                        let v = get16(&b[2 * k..]) as u32;
                        if v != 0 {
                            hw.write(a, v);
                        }
                    }
                    put16(&mut o[1..], hw.lease_ms as u16);
                    put16(&mut o[3..], hw.maxkey_s as u16);
                    put16(&mut o[5..], hw.temp_limit as u16);
                    return 7;
                }
            }
            _ => {
                o[0] = msg::status::UNKNOWN;
                return 1;
            }
        }
        o[0] = msg::status::LENGTH;
        1
    }

    fn app_telemetry(&self, o: &mut [u8]) -> usize {
        let hw = &self.hw;
        put32(o, self.now);
        put16(&mut o[4..], hw.temp_code);
        put16(&mut o[6..], hw.fwd_code);
        put16(&mut o[8..], hw.rev_code);
        put16(&mut o[10..], hw.bias_code);
        put32(&mut o[12..], hw.inputs);
        put32(&mut o[16..], hw.ilk_status);
        put32(&mut o[20..], hw.read(frontend::I2C_STATUS, self.now));
        put32(&mut o[24..], hw.fan);
        put32(&mut o[28..], hw.keytime);
        put32(&mut o[32..], hw.safety as u32 | hw.pkt_count << 8);
        36
    }

    fn app_event(&mut self, o: &mut [u8]) -> usize {
        let ilk = self.hw.ilk_status;
        let inp = self.hw.inputs;
        let s = (ilk & 0x073E_3F7B) ^ ((inp >> 16) & 7) << 28;
        if s == self.ev_state {
            return 0;
        }
        self.ev_state = s;
        put32(o, ilk);
        put32(&mut o[4..], inp);
        put32(&mut o[8..], self.now);
        12
    }

    /// Etherbone (PROTOCOL.md 8.1): writes first, then reads; a reply only when there are reads.
    /// Writes reach the RAM and the CPU system block (`bridge_write`); every other write is
    /// counted in `cpu.forbidden_writes` and otherwise ignored.
    fn bridge(&mut self, d: &[u8]) {
        if d.len() < 12 || d.len() > 512 || d[1] != 0x6F || d[2] & 0xF0 != 0x10 || d[3] != 0x44 {
            return;
        }
        let (w, r) = (d[10] as usize, d[11] as usize);
        if w > 64 || r > 64 {
            return;
        }
        let need = 12 + if w > 0 { 4 + 4 * w } else { 0 } + if r > 0 { 4 + 4 * r } else { 0 };
        if d.len() < need {
            return;
        }
        let be = |i: usize| u32::from_be_bytes([d[i], d[i + 1], d[i + 2], d[i + 3]]);
        let mut q = 12;
        if w > 0 {
            let base = be(q);
            for i in 0..w {
                self.bridge_write(base.wrapping_add(4 * i as u32), be(q + 4 + 4 * i));
            }
            q += 4 + 4 * w;
        }
        if r == 0 {
            return;
        }
        let mut p = [0u8; 512];
        p[..4].copy_from_slice(&[0x4E, 0x6F, 0x10, 0x44]);
        p[9] = 0x0F;
        p[10] = r as u8;
        p[12..16].copy_from_slice(&d[q..q + 4]);
        for i in 0..r {
            let a = be(q + 4 + 4 * i);
            let v = self.cpu.read(a, self.now).unwrap_or_else(|| self.hw.bridge_read(a, self.now));
            p[16 + 4 * i..20 + 4 * i].copy_from_slice(&v.to_be_bytes());
        }
        let n = 16 + 4 * r;
        self.send(&p[..n]);
    }
}

// ---- Lossy link and test bench -------------------------------------------------------------

/// One direction of a link with loss, duplication and reordering (percentages, deterministic).
pub struct Link {
    rng: u32,
    pub loss_pct: u32,
    pub dup_pct: u32,
    pub reorder_pct: u32,
    held: Option<Datagram>,
    pub passed: u32,
    pub dropped: u32,
}

impl Link {
    pub fn new(seed: u32) -> Link {
        Link { rng: seed | 1, loss_pct: 0, dup_pct: 0, reorder_pct: 0, held: None, passed: 0, dropped: 0 }
    }

    fn roll(&mut self, pct: u32) -> bool {
        if pct == 0 {
            return false;
        }
        self.rng ^= self.rng << 13;
        self.rng ^= self.rng >> 17;
        self.rng ^= self.rng << 5;
        self.rng % 100 < pct
    }

    /// Passes one datagram; `deliver` gets what comes out (0, 1 or more datagrams).
    pub fn pass(&mut self, d: Datagram, mut deliver: impl FnMut(&[u8])) {
        if self.roll(self.loss_pct) {
            self.dropped += 1;
            return;
        }
        if self.held.is_none() && self.roll(self.reorder_pct) {
            self.held = Some(d);
            return;
        }
        self.passed += 1;
        deliver(d.as_slice());
        if self.roll(self.dup_pct) {
            deliver(d.as_slice());
        }
        if let Some(h) = self.held.take() {
            deliver(h.as_slice());
        }
    }
}

/// An `Hl2Control` and an `Hl2Sim` joined by two `Link`s, on a millisecond clock.
pub struct Bench {
    pub client: Hl2Control,
    pub radio: Hl2Sim,
    pub up: Link,
    pub down: Link,
    pub now: u32,
    /// Datagrams the client sent.
    pub client_sent: u32,
}

impl Bench {
    pub fn new(seed: u32, boot_id: u32) -> Bench {
        Bench {
            client: Hl2Control::new(seed),
            radio: Hl2Sim::new(boot_id),
            up: Link::new(seed ^ 0x5A5A_1234),
            down: Link::new(seed ^ 0x0F0F_9876),
            now: 1000,
            client_sent: 0,
        }
    }

    /// Advances the clock by 1 ms and moves every datagram due.
    pub fn step(&mut self) {
        self.now = self.now.wrapping_add(1);
        let now = self.now;
        let mut buf = [0u8; 512];
        while let Some(n) = self.client.poll_transmit(now, &mut buf) {
            self.client_sent += 1;
            let radio = &mut self.radio;
            self.up.pass(Datagram::new(&buf[..n]), |d| radio.input(now, d));
        }
        self.radio.poll(now);
        while let Some(d) = self.radio.pop_output() {
            let client = &mut self.client;
            self.down.pass(d, |d| client.handle_datagram(now, d));
        }
    }

    pub fn run(&mut self, ms: u32) {
        for _ in 0..ms {
            self.step();
        }
    }

    /// Runs until `done` is true or `max_ms` passed. Returns whether `done` became true.
    pub fn run_until(&mut self, max_ms: u32, mut done: impl FnMut(&mut Bench) -> bool) -> bool {
        for _ in 0..max_ms {
            if done(self) {
                return true;
            }
            self.step();
        }
        done(self)
    }
}
