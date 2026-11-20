// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The transceiver of the two SFP+ cages: start-up, status, the cages' pins and the board's I2C bus
//! (page 0xE80A_0000, `hw/regmap/sfp.toml`, docs/SFP_LINKS.md sections 2.3 and 7).
//!
//! The transceiver needs its 125 MHz reference before its lanes run. [`Serdes::start`] therefore holds
//! the lanes in reset and writes the clock chip ("PLL0", an MS5351M, register map of the Si5351A) over
//! I2C; [`Serdes::poll`] waits until the chip's PLL has locked, lets the lanes out of reset (their PLLs
//! with them), waits for lane 0's PLL, then lets the PCS sides go; afterwards it gives a receive reset to
//! a lane that sees a signal and does not align. I2C is done bit by bit on two register bits: [`Twi`].
//! The same bus reaches the modules' memories ([`read_module_info`]).
//!
//! Board facts, found in runs on the board: the multiplexer pin N19 is the least significant select bit ([`channel::sel_bits`]), the lane
//! reset (`pma_rstn_i`) resets the lane PLL too, so the lane must be out of reset while its PLL is to
//! lock, and the clock chip answers at 0x60 and shows in its register 0 when its PLL has locked.

use tr_regs::generated::sfp as reg;
use tr_regs::RegisterSpace;

/// I2C multiplexer channels (dock schematic rev 1.2, sheet TWI_MUX).
pub mod channel {
    pub const SFP0: u8 = 0;
    pub const SFP1: u8 = 1;
    pub const CLOCK_CHIP_0: u8 = 3;
    pub const CLOCK_CHIP_1: u8 = 4;

    /// The register's select field (`twi` bits 4:2 = `twi_sel[2:0]` = pins N19, P19, P26) for channel `ch`.
    /// Board fact (dock schematic rev 1.2, sheet TWI_MUX, the drawing of IC3 and IC4, 74HC4051, select S0 least
    /// significant): N19 drives S0, P19 S1, P26 S2, so N19 is the LEAST significant select bit. The table on that
    /// sheet and the CLOCK sheet's notes read N19 as the most significant; written that way, channel 3 selected
    /// channel 6 and the clock chip never answered (seen on the board, and confirmed against the
    /// independent design ZiyangYE/verilog_5351). Channel 3 = N19 1, P19 1, P26 0. Channels 0, 2, 5, 7 read the
    /// same either way.
    pub const fn sel_bits(ch: u8) -> u32 {
        ((ch as u32 & 1) << 4) | ((ch as u32 & 2) << 2) | ((ch as u32 >> 2 & 1) << 2)
    }
}

/// 7-bit I2C addresses.
pub const CLOCK_CHIP_ADDR: u8 = 0x60;
pub const MODULE_ADDR: u8 = 0x50;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NoAck;

/// The board's I2C bus through the register bits `twi.scl`, `twi.sda` (0 = pull low) and the multiplexer
/// select. About 100 kbit/s; `delay` waits the given microseconds.
pub struct Twi<'a, R: RegisterSpace, D: Fn(u32)> {
    regs: &'a R,
    delay: D,
    sel: u32,
}

const T: u32 = 5;

impl<'a, R: RegisterSpace, D: Fn(u32)> Twi<'a, R, D> {
    pub fn new(regs: &'a R, delay: D, channel: u8) -> Self {
        let t = Twi { regs, delay, sel: channel::sel_bits(channel) };
        t.set(true, true);
        (t.delay)(T * 4);
        t
    }

    fn set(&self, scl: bool, sda: bool) {
        self.regs.write32(reg::twi::addr(), self.sel | (sda as u32) << 1 | scl as u32);
    }

    fn sda_in(&self) -> bool {
        self.regs.read32(reg::twi::addr()) & (1 << 9) != 0
    }

    /// Releases SCL and waits for it to rise (a slave may hold it), at most 20 polls.
    fn scl_up(&self, sda: bool) {
        self.set(true, sda);
        for _ in 0..20 {
            if self.regs.read32(reg::twi::addr()) & (1 << 8) != 0 {
                break;
            }
        }
        (self.delay)(T);
    }

    fn start(&self) {
        self.set(true, true);
        (self.delay)(T);
        self.set(true, false);
        (self.delay)(T);
        self.set(false, false);
        (self.delay)(T);
    }

    fn stop(&self) {
        self.set(false, false);
        (self.delay)(T);
        self.scl_up(false);
        self.set(true, true);
        (self.delay)(T);
    }

    fn bit_out(&self, b: bool) {
        self.set(false, b);
        (self.delay)(T);
        self.scl_up(b);
        self.set(false, b);
    }

    fn bit_in(&self) -> bool {
        self.set(false, true);
        (self.delay)(T);
        self.scl_up(true);
        let b = self.sda_in();
        self.set(false, true);
        b
    }

    fn byte_out(&self, v: u8) -> Result<(), NoAck> {
        for i in (0..8).rev() {
            self.bit_out(v >> i & 1 != 0);
        }
        if self.bit_in() {
            Err(NoAck)
        } else {
            Ok(())
        }
    }

    fn byte_in(&self, ack: bool) -> u8 {
        let mut v = 0u8;
        for _ in 0..8 {
            v = v << 1 | self.bit_in() as u8;
        }
        self.bit_out(!ack);
        v
    }

    /// Writes one register of the device at 7-bit address `dev`.
    pub fn write_reg(&self, dev: u8, register: u8, value: u8) -> Result<(), NoAck> {
        self.start();
        let r = self.byte_out(dev << 1).and_then(|_| self.byte_out(register)).and_then(|_| self.byte_out(value));
        self.stop();
        r
    }

    /// Reads `buf.len()` bytes starting at `register`.
    pub fn read_regs(&self, dev: u8, register: u8, buf: &mut [u8]) -> Result<(), NoAck> {
        self.start();
        let mut r = self.byte_out(dev << 1).and_then(|_| self.byte_out(register));
        if r.is_ok() {
            self.start();
            r = self.byte_out(dev << 1 | 1);
        }
        if r.is_ok() {
            let n = buf.len();
            for (i, b) in buf.iter_mut().enumerate() {
                *b = self.byte_in(i + 1 < n);
            }
        }
        self.stop();
        r
    }
}

/// Register writes that set the clock chip to 125 MHz on outputs 0 and 1 (1 inverted: the pair that feeds the
/// transceiver's reference input): PLL A = 25 MHz x 30 = 750 MHz, both dividers 6, whole numbers. Si5351A
/// register map (Skyworks AN619): 3 output enable, 16/17 output control, 26-33 PLL A, 42-49 and 50-57 the
/// dividers, 177 PLL reset. P1 = 128 x ratio - 512, P2 = 0, P3 = 1.
/// PLL B (34-41) gets the same 750 MHz, unused by the outputs, so that register 0 shows no PLL unlocked
/// (seen on the board: with PLL B unset, register 0 read 0x41 and LOL_B was set).
pub const CLOCK_CHIP_125MHZ: [(u8, u8); 38] = [
    (3, 0xFF),
    (16, 0x80), (17, 0x80), (18, 0x80),
    (26, 0x00), (27, 0x01), (28, 0x00), (29, 0x0D), (30, 0x00), (31, 0x00), (32, 0x00), (33, 0x00),
    (34, 0x00), (35, 0x01), (36, 0x00), (37, 0x0D), (38, 0x00), (39, 0x00), (40, 0x00), (41, 0x00),
    (42, 0x00), (43, 0x01), (44, 0x00), (45, 0x01), (46, 0x00), (47, 0x00), (48, 0x00), (49, 0x00),
    (50, 0x00), (51, 0x01), (52, 0x00), (53, 0x01), (54, 0x00), (55, 0x00), (56, 0x00), (57, 0x00),
    (177, 0xA0),
    (3, 0xFC),
];
/// Output control written between the dividers and the PLL reset: divider's own source, whole-number mode,
/// PLL A, 8 mA; output 1 inverted.
pub const CLOCK_CHIP_OUTPUTS: [(u8, u8); 2] = [(16, 0x4F), (17, 0x5F)];

/// Sets the clock chip on `channel` to 125 MHz. `Err` when it does not answer.
pub fn program_clock_chip<R: RegisterSpace, D: Fn(u32)>(regs: &R, delay: D, channel: u8) -> Result<(), NoAck> {
    let twi = Twi::new(regs, delay, channel);
    let n = CLOCK_CHIP_125MHZ.len();
    for &(r, v) in &CLOCK_CHIP_125MHZ[..n - 2] {
        twi.write_reg(CLOCK_CHIP_ADDR, r, v)?;
    }
    for &(r, v) in &CLOCK_CHIP_OUTPUTS {
        twi.write_reg(CLOCK_CHIP_ADDR, r, v)?;
    }
    for &(r, v) in &CLOCK_CHIP_125MHZ[n - 2..] {
        twi.write_reg(CLOCK_CHIP_ADDR, r, v)?;
    }
    Ok(())
}

/// The clock chip's device status, register 0 (Si5351A register map, Skyworks AN619): bit 7 SYS_INIT (still
/// starting), 6 LOL_B, 5 LOL_A (PLL B / PLL A not locked), 4 LOS, 1:0 revision. `None` when it does not answer.
pub fn clock_chip_status<R: RegisterSpace, D: Fn(u32)>(regs: &R, delay: D, channel: u8) -> Option<u8> {
    let mut b = [0u8; 1];
    Twi::new(regs, delay, channel).read_regs(CLOCK_CHIP_ADDR, 0, &mut b).ok().map(|_| b[0])
}

/// Register 0 bits that must be clear before the reference is used: SYS_INIT and LOL_A (PLL A feeds outputs 0 and 1).
pub const CLOCK_CHIP_NOT_READY: u8 = 0xA0;

/// What a cage holds, from the module's memory (SFF-8472 address A0h: byte 0 identifier, 6 Ethernet
/// compliance, 8 cable technology).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Module {
    /// Nothing answers.
    None,
    /// 1000BASE-T copper module: try SGMII first.
    Copper,
    /// Fibre (1000BASE-SX/LX) or anything else: 1000BASE-X.
    Optical,
    /// Direct-attach cable.
    Cable,
}

impl Module {
    pub fn of(info: Option<&ModuleInfo>) -> Module {
        match info {
            None => Module::None,
            Some(m) if m.cable => Module::Cable,
            Some(m) if m.copper() => Module::Copper,
            Some(_) => Module::Optical,
        }
    }
}

/// The module's identification (SFF-8472, address A0h, bytes 0 to 95).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ModuleInfo {
    /// Byte 0: 0x03 = SFP or SFP+.
    pub identifier: u8,
    /// Byte 3 bits 7:4: 10G Ethernet compliance.
    pub ten_gig: u8,
    /// Byte 6: Ethernet compliance (bit 0 1000BASE-SX, 1 LX, 2 CX, 3 T).
    pub eth_codes: u8,
    /// Byte 8 bits 3:2: passive or active direct-attach cable.
    pub cable: bool,
    /// Byte 12: nominal rate in units of 100 Mbaud (0x0C, 0x0D: 1.25 Gbaud; 0x67: 10.3 Gbaud).
    pub rate_100mbd: u8,
    pub vendor: [u8; 16],
    pub part: [u8; 16],
    pub revision: [u8; 4],
    pub serial: [u8; 16],
}

impl ModuleInfo {
    /// A 1000BASE-T module (copper).
    pub fn copper(&self) -> bool {
        self.eth_codes & 0x08 != 0
    }
    /// A 10G module (10G compliance codes, or a nominal rate above 2.5 Gbaud).
    pub fn too_fast(&self) -> bool {
        self.ten_gig != 0 || self.rate_100mbd > 25
    }
    /// A Gigabit Ethernet module: 1000BASE-SX, LX, CX or T, and not a 10G module.
    pub fn ethernet(&self) -> bool {
        self.eth_codes & 0x0F != 0 && !self.too_fast()
    }
    /// Nominal rate in Mbaud.
    pub fn mbaud(&self) -> u32 {
        self.rate_100mbd as u32 * 100
    }
}

/// An ASCII field of the memory without its trailing blanks (anything that is not printable ASCII shows as `?`);
/// returns the length used in `out`.
pub fn field_text(b: &[u8], out: &mut [u8; 16]) -> usize {
    let mut n = b.len().min(16);
    while n > 0 && (b[n - 1] == b' ' || b[n - 1] == 0) {
        n -= 1;
    }
    for i in 0..n {
        out[i] = if (0x20..0x7F).contains(&b[i]) { b[i] } else { b'?' };
    }
    n
}

fn field<const N: usize>(m: &[u8], from: usize) -> [u8; N] {
    let mut a = [b' '; N];
    a.copy_from_slice(&m[from..from + N]);
    a
}

/// Reads the module's identification from bytes 0 to 95 of A0h. `None`: too short, or an identifier of 0 or 0xFF
/// (nothing there).
pub fn parse_module(m: &[u8]) -> Option<ModuleInfo> {
    if m.len() < 96 || m[0] == 0 || m[0] == 0xFF {
        return None;
    }
    Some(ModuleInfo {
        identifier: m[0],
        ten_gig: m[3] >> 4,
        eth_codes: m[6],
        cable: m[8] & 0x0C != 0,
        rate_100mbd: m[12],
        vendor: field(m, 20),
        part: field(m, 40),
        revision: field(m, 56),
        serial: field(m, 68),
    })
}

/// Reads bytes 0 to 95 of the memory of the module on multiplexer `channel` (about 10 ms). `None`: no answer at
/// 0x50 (the module-present pins are not on FPGA pins: the memory is the presence test), or nothing there.
pub fn read_module_info<R: RegisterSpace, D: Fn(u32)>(regs: &R, delay: D, channel: u8) -> Option<ModuleInfo> {
    let twi = Twi::new(regs, delay, channel);
    let mut m = [0u8; 96];
    twi.read_regs(MODULE_ADDR, 0, &mut m).ok()?;
    parse_module(&m)
}

pub fn read_module<R: RegisterSpace, D: Fn(u32)>(regs: &R, delay: D, channel: u8) -> Module {
    Module::of(read_module_info(regs, delay, channel).as_ref())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct LaneStatus {
    pub pll_lock: bool,
    pub cdr_lock: bool,
    pub signal: bool,
    pub ready: bool,
    pub aligned: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    /// `start` not called.
    Off,
    /// Clock chip written (or not answering); waiting at least 10 ms, and until its PLL A has locked (at most
    /// 100 ms), for the reference.
    Reference,
    /// Quad and lanes out of reset, PCS sides held; waiting for lane 0's PLL.
    Locking,
    /// Lanes out of reset.
    Running,
    /// Lane 0's PLL did not lock in [`LOCK_TRIES`] tries; everything held in reset.
    Failed,
}

/// What [`Serdes::poll`] has to tell (the caller prints it).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Report {
    /// The end of one lock attempt (`attempt` from 1): `serdes_ctrl` and `serdes_status` as read (status bits 23:16:
    /// the quad's own status, 27:24 the lanes' buffer flags) and the clock chip's register 0 (`None`: no answer).
    LockTry { attempt: u8, ctrl: u32, status: u32, chip: Option<u8> },
    /// The start-up ended: `clock_chip` = it answered on I2C; `locked` = lane 0's PLL locked.
    Transceiver { clock_chip: bool, locked: bool },
}

/// Lane 0 PLL lock attempts before the transceiver is given up.
pub const LOCK_TRIES: u8 = 5;

const POR_N: u32 = 1 << 0;
const LN_RST_N: u32 = 3 << 1;
const LN0_RX_RST: u32 = 1 << 3;
const LN1_RX_RST: u32 = 1 << 4;
const LN0_TX_RST: u32 = 1 << 5;
const LN1_TX_RST: u32 = 1 << 6;
const LN1_PCS_RST: u32 = LN1_RX_RST | LN1_TX_RST;
const PCS_RST: u32 = LN0_RX_RST | LN0_TX_RST | LN1_PCS_RST;
/// Before and between lock attempts: quad (`por_n`, in a build with the global reset form) and both lanes in reset,
/// both PCS sides of both lanes in reset.
pub const CTRL_HOLD: u32 = PCS_RST;
/// While a lane PLL is to lock: quad and lanes out of reset, so that the lane PLLs run; the PCS sides stay in reset.
/// The lane reset (`pma_rstn_i`) is the generated wrapper's `FABRIC_LNn_RSTN_I`, the reset of the whole lane, its PLL
/// included (IPUG1024-1.7.2E table 4-1). Held low until the PLL locked, as seen on the board, it never could.
pub const CTRL_LOCKING: u32 = POR_N | LN_RST_N | PCS_RST;

pub struct Serdes<'a, R: RegisterSpace> {
    regs: &'a R,
    phase: Phase,
    since_ms: i64,
    /// Start of the present wait for the reference (the 100 ms limit on the clock chip's lock).
    ref_since_ms: i64,
    unaligned_ms: [i64; 2],
    rx_reset: [bool; 2],
    reports: [Option<Report>; 2],
    /// The clock chip answered on I2C.
    pub clock_chip_ok: bool,
    /// Lock attempts that ended without lane 0's PLL locked.
    pub lock_retries: u32,
    /// Lock attempts so far (reported).
    pub tries: u8,
    /// Receive resets given to lane 0 and lane 1.
    pub rx_resets: [u32; 2],
}

impl<'a, R: RegisterSpace> Serdes<'a, R> {
    pub fn new(regs: &'a R) -> Self {
        regs.write32(reg::serdes_ctrl::addr(), CTRL_HOLD);
        Serdes {
            regs,
            phase: Phase::Off,
            since_ms: 0,
            ref_since_ms: 0,
            unaligned_ms: [0; 2],
            rx_reset: [false; 2],
            reports: [None; 2],
            clock_chip_ok: false,
            lock_retries: 0,
            tries: 0,
            rx_resets: [0; 2],
        }
    }

    /// Holds the transceiver in reset, writes the clock chip (about 20 ms, blocking) and starts the sequence.
    pub fn start<D: Fn(u32)>(&mut self, delay: D, now_ms: i64) {
        self.regs.write32(reg::serdes_ctrl::addr(), CTRL_HOLD);
        self.clock_chip_ok = program_clock_chip(self.regs, delay, channel::CLOCK_CHIP_0).is_ok();
        self.phase = Phase::Reference;
        self.since_ms = now_ms;
        self.ref_since_ms = now_ms;
    }

    pub fn phase(&self) -> Phase {
        self.phase
    }

    /// The next thing to tell, oldest first.
    pub fn take_report(&mut self) -> Option<Report> {
        let r = self.reports[0].take();
        self.reports[0] = self.reports[1].take();
        r
    }

    fn report(&mut self, r: Report) {
        if self.reports[0].is_none() {
            self.reports[0] = Some(r);
        } else {
            self.reports[1] = Some(r);
        }
    }

    pub fn lanes(&self) -> [LaneStatus; 2] {
        let v = self.regs.read32(reg::serdes_status::addr());
        let lane = |s: u32| LaneStatus { pll_lock: s & 1 != 0, cdr_lock: s & 2 != 0, signal: s & 4 != 0, ready: s & 8 != 0, aligned: s & 16 != 0 };
        [lane(v), lane(v >> 8)]
    }

    /// Turns the modules' transmitters on or off (the reset state is off).
    pub fn set_tx_disable(&self, sfp0: bool, sfp1: bool) {
        self.regs.write32(reg::cage::addr(), sfp0 as u32 | (sfp1 as u32) << 1);
    }

    fn lock_try(&mut self, delay: impl Fn(u32)) {
        self.tries = self.tries.saturating_add(1);
        let ctrl = self.regs.read32(reg::serdes_ctrl::addr());
        let status = self.regs.read32(reg::serdes_status::addr());
        let chip = clock_chip_status(self.regs, delay, channel::CLOCK_CHIP_0);
        self.report(Report::LockTry { attempt: self.tries, ctrl, status, chip });
    }

    /// Call every few milliseconds. `delay` waits the given microseconds (I2C to the clock chip while it starts).
    pub fn poll<D: Fn(u32) + Copy>(&mut self, delay: D, now_ms: i64) -> Phase {
        let lanes = self.lanes();
        match self.phase {
            Phase::Off | Phase::Failed => {}
            Phase::Reference => {
                if now_ms - self.since_ms >= 10 {
                    // the lanes leave reset only once the clock chip's PLL A (outputs 0 and 1, the reference) has
                    // locked: register 0 SYS_INIT and LOL_A clear; at most 100 ms, then it goes ahead anyway
                    let waiting = self.clock_chip_ok
                        && now_ms - self.ref_since_ms < 100
                        && clock_chip_status(self.regs, delay, channel::CLOCK_CHIP_0).is_some_and(|s| s & CLOCK_CHIP_NOT_READY != 0);
                    if !waiting {
                        self.regs.write32(reg::serdes_ctrl::addr(), CTRL_LOCKING);
                        self.phase = Phase::Locking;
                        self.since_ms = now_ms;
                    }
                }
            }
            Phase::Locking => {
                if lanes[0].pll_lock {
                    self.lock_try(delay);
                    // the PCS sides out of reset; lane 1's (board link) only once its own PLL has locked
                    let ctrl = POR_N | LN_RST_N | if lanes[1].pll_lock { 0 } else { LN1_PCS_RST };
                    self.regs.write32(reg::serdes_ctrl::addr(), ctrl);
                    self.phase = Phase::Running;
                    self.unaligned_ms = [now_ms; 2];
                    self.report(Report::Transceiver { clock_chip: self.clock_chip_ok, locked: true });
                } else if now_ms - self.since_ms >= 100 {
                    self.lock_try(delay);
                    self.lock_retries += 1;
                    // no lock: quad and lanes in reset again; the reference gets its settling time before the next try
                    self.regs.write32(reg::serdes_ctrl::addr(), CTRL_HOLD);
                    self.since_ms = now_ms;
                    self.ref_since_ms = now_ms;
                    if self.tries >= LOCK_TRIES {
                        self.phase = Phase::Failed;
                        self.report(Report::Transceiver { clock_chip: self.clock_chip_ok, locked: false });
                    } else {
                        self.phase = Phase::Reference;
                    }
                }
            }
            Phase::Running => {
                let mut ctrl = POR_N | LN_RST_N;
                if !lanes[1].pll_lock {
                    ctrl |= LN1_PCS_RST;
                }
                for i in 0..2 {
                    if self.rx_reset[i] {
                        self.rx_reset[i] = false; // one poll long
                        self.unaligned_ms[i] = now_ms;
                    } else if lanes[i].aligned || !lanes[i].signal {
                        self.unaligned_ms[i] = now_ms;
                    } else if now_ms - self.unaligned_ms[i] >= 100 {
                        self.rx_reset[i] = true;
                        self.rx_resets[i] += 1;
                        ctrl |= if i == 0 { LN0_RX_RST } else { LN1_RX_RST };
                    }
                }
                self.regs.write32(reg::serdes_ctrl::addr(), ctrl);
            }
        }
        self.phase
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mock::{Ev, MockFabric};
    use alloc::vec::Vec;

    /// The bytes an I2C slave would have seen, from the writes to the `twi` register: a bit is SDA at a rising
    /// SCL; start and stop (SDA moving while SCL is high) separate the messages. Ninth bits (acknowledge) dropped.
    fn decode(m: &MockFabric) -> Vec<Vec<u8>> {
        let (mut msgs, mut cur, mut bits, mut n) = (Vec::new(), Vec::new(), 0u16, 0);
        let (mut scl, mut sda) = (true, true);
        for e in m.log.borrow().iter() {
            if let Ev::RegWrite(a, v) = *e {
                if a != reg::twi::addr() {
                    continue;
                }
                let (c, d) = (v & 1 != 0, v & 2 != 0);
                if scl && c && sda != d {
                    if !d {
                        (bits, n) = (0, 0); // start, or a repeated start inside a message
                    } else if !cur.is_empty() {
                        msgs.push(core::mem::take(&mut cur)); // stop
                    }
                } else if !scl && c {
                    bits = bits << 1 | d as u16;
                    n += 1;
                    if n == 9 {
                        cur.push((bits >> 1) as u8);
                        (bits, n) = (0, 0);
                    }
                }
                (scl, sda) = (c, d);
            }
        }
        msgs
    }

    #[test]
    fn multiplexer_select_has_n19_as_least_significant_bit() {
        // register bits 4:2 = N19, P19, P26 (twi_sel[2:0]); N19 is S0 of the 74HC4051
        assert_eq!(channel::sel_bits(channel::CLOCK_CHIP_0), 0b1_1000); // N19 1, P19 1, P26 0
        assert_eq!(channel::sel_bits(channel::SFP1), 0b1_0000); // N19 1
        assert_eq!(channel::sel_bits(channel::CLOCK_CHIP_1), 0b0_0100); // P26 1
        assert_eq!(channel::sel_bits(channel::SFP0), 0);
        for ch in [0u8, 2, 5, 7] {
            assert_eq!(channel::sel_bits(ch), (ch as u32) << 2, "channel {ch} reads the same either way");
        }
    }

    #[test]
    fn clock_chip_gets_its_registers_in_order() {
        let m = MockFabric::new();
        assert!(program_clock_chip(&m, |_| {}, channel::CLOCK_CHIP_0).is_ok());
        let msgs = decode(&m);
        assert_eq!(msgs.len(), 40);
        assert_eq!(msgs[0], [0xC0, 3, 0xFF]); // outputs off first
        assert_eq!(msgs[7], [0xC0, 29, 0x0D]); // PLL A: 128 x 30 - 512 = 0x0D00
        assert_eq!(msgs[15], [0xC0, 37, 0x0D]); // PLL B the same
        assert_eq!(msgs[36], [0xC0, 16, 0x4F]);
        assert_eq!(msgs[37], [0xC0, 17, 0x5F]); // output 1 inverted
        assert_eq!(msgs[38], [0xC0, 177, 0xA0]);
        assert_eq!(msgs[39], [0xC0, 3, 0xFC]); // outputs 0 and 1 on last
        // every write carried multiplexer channel 3: N19 and P19 high
        assert!(m.reg_writes(reg::twi::addr()).iter().all(|v| v >> 2 & 7 == 0b110));
        // 25 MHz x 30 / 6 = 125 MHz
        let p1_pll = 0x0D00u32;
        let p1_div = 0x0100u32;
        assert_eq!(25 * (p1_pll + 512) / 128 * 128 / (p1_div + 512), 125);
    }

    fn memory(eth: u8, cable: u8, rate: u8, ten_gig: u8) -> [u8; 96] {
        let mut m = [b' '; 96];
        m[0] = 0x03;
        m[3] = ten_gig << 4;
        m[6] = eth;
        m[8] = cable;
        m[12] = rate;
        m[20..27].copy_from_slice(b"OEM    ");
        m[40..50].copy_from_slice(b"SFP-GE-T  ");
        m
    }

    #[test]
    fn module_memory_is_parsed_and_classified() {
        let c = parse_module(&memory(0x08, 0, 0x0D, 0)).unwrap();
        assert!(c.copper() && c.ethernet() && !c.too_fast());
        assert_eq!(c.mbaud(), 1300);
        assert_eq!(Module::of(Some(&c)), Module::Copper);
        let mut out = [0u8; 16];
        let n = field_text(&c.part, &mut out);
        assert_eq!(&out[..n], b"SFP-GE-T");
        let sx = parse_module(&memory(0x01, 0, 0x0D, 0)).unwrap();
        assert_eq!(Module::of(Some(&sx)), Module::Optical);
        assert!(sx.ethernet());
        let dac = parse_module(&memory(0, 0x04, 0x67, 0)).unwrap();
        assert_eq!(Module::of(Some(&dac)), Module::Cable);
        assert!(!dac.ethernet() && dac.too_fast());
        let ten = parse_module(&memory(0, 0, 0x67, 0x1)).unwrap();
        assert!(!ten.ethernet());
        // nothing there: identifier 0 or 0xFF, or a short read
        assert_eq!(parse_module(&[0u8; 96]), None);
        assert_eq!(parse_module(&[0xFFu8; 96]), None);
        assert_eq!(parse_module(&[3u8; 40]), None);
        assert_eq!(Module::of(None), Module::None);
    }

    #[test]
    fn read_addresses_the_module_and_reads_96_bytes() {
        let m = MockFabric::new();
        // the mock answers every bit with 0: acknowledged, all bytes 0 = nothing there
        assert_eq!(read_module_info(&m, |_| {}, channel::SFP1), None);
        let msgs = decode(&m);
        assert_eq!(msgs[0][..2], [0xA0, 0]);
        assert_eq!(msgs[0][2], 0xA1);
        assert_eq!(msgs[0].len(), 3 + 96);
        // channel 1: N19 high
        assert!(m.reg_writes(reg::twi::addr()).iter().all(|v| v >> 2 & 7 == 0b100));
    }

    #[test]
    fn start_up_releases_the_lanes_before_the_lock_and_the_pcs_after_it() {
        let m = MockFabric::new();
        let mut s = Serdes::new(&m);
        assert_eq!(m.reg(reg::serdes_ctrl::addr()), CTRL_HOLD);
        s.start(|_| {}, 1000);
        assert!(s.clock_chip_ok);
        assert_eq!(m.reg(reg::serdes_ctrl::addr()), CTRL_HOLD);
        assert_eq!(s.poll(|_| {}, 1005), Phase::Reference);
        // 10 ms, and the clock chip's register 0 reads 0 (the mock): PLL A locked
        assert_eq!(s.poll(|_| {}, 1010), Phase::Locking);
        // quad and both lanes out of reset (lane PLLs run), every PCS side held
        assert_eq!(m.reg(reg::serdes_ctrl::addr()), 0b111_1111);
        // no lock within 100 ms: one try reported, back into reset
        assert_eq!(s.poll(|_| {}, 1110), Phase::Reference);
        assert_eq!(m.reg(reg::serdes_ctrl::addr()), CTRL_HOLD);
        assert_eq!(s.lock_retries, 1);
        assert!(matches!(s.take_report(), Some(Report::LockTry { attempt: 1, ctrl: 0b111_1111, .. })));
        assert_eq!(s.take_report(), None);
        assert_eq!(s.poll(|_| {}, 1120), Phase::Locking);
        // lane 0 locks, lane 1 not yet: lane 0's PCS goes, lane 1's PCS stays held
        m.poke(reg::serdes_status::addr(), 0x0001);
        assert_eq!(s.poll(|_| {}, 1125), Phase::Running);
        assert_eq!(m.reg(reg::serdes_ctrl::addr()), 0b101_0111);
        assert!(matches!(s.take_report(), Some(Report::LockTry { attempt: 2, status: 1, .. })));
        assert_eq!(s.take_report(), Some(Report::Transceiver { clock_chip: true, locked: true }));
        // lane 1 locks: its PCS goes too
        m.poke(reg::serdes_status::addr(), 0x0101);
        s.poll(|_| {}, 1130);
        assert_eq!(m.reg(reg::serdes_ctrl::addr()), 0b111);
        // lane 1 has a signal and does not align for 100 ms: one poll of receive reset
        m.poke(reg::serdes_status::addr(), 0x0501);
        assert_eq!(s.poll(|_| {}, 1200), Phase::Running);
        assert_eq!(m.reg(reg::serdes_ctrl::addr()), 0b111);
        s.poll(|_| {}, 1230);
        assert_eq!(m.reg(reg::serdes_ctrl::addr()), 0b10111);
        assert_eq!(s.rx_resets, [0, 1]);
        s.poll(|_| {}, 1235);
        assert_eq!(m.reg(reg::serdes_ctrl::addr()), 0b111);
    }

    #[test]
    fn start_up_gives_up_after_five_tries() {
        let m = MockFabric::new();
        let mut s = Serdes::new(&m);
        s.start(|_| {}, 0);
        let mut t = 0;
        let mut tries = 0;
        while s.phase() != Phase::Failed && t < 2_000 {
            t += 5;
            s.poll(|_| {}, t);
            while let Some(r) = s.take_report() {
                match r {
                    Report::LockTry { .. } => tries += 1,
                    Report::Transceiver { locked, .. } => assert!(!locked),
                }
            }
        }
        assert_eq!(s.phase(), Phase::Failed);
        assert_eq!(tries, LOCK_TRIES as u32);
        assert_eq!(m.reg(reg::serdes_ctrl::addr()), CTRL_HOLD);
    }
}
