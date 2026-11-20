// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The network unit on the RJ45 socket (`rtl/net/net_unit.v`): control and status, MAC address, MDIO to the RTL8211F, one frame out, frames in,
//! and interrupt flags. It runs at 100 Mbit/s full duplex only.
//!
//! The driver is described in `docs/HL2_SFP.md` section 9. The page base comes from
//! `tr-regs` (`hw/regmap/net.toml`, the one place that defines the page), the PHY start-up is timed
//! in milliseconds, `tr_net::rings::MacRings` is implemented for the
//! network stack, the chip ID registers and their readers are included (`docs/NET_ID.md`), and the PHY
//! start-up repeats until the RTL8211F answers.
//!
//! The register layout is that of the network page at 0xE924_0000 (`docs/NET_ID.md`), and the image
//! header of the loader and its PC protocol are not part of it. The offsets are in this file and the
//! page base is `tr_regs::generated::net::BASE`, and both change with `hw/regmap/net.toml`. The
//! places that use the layout are marked `NET-LAYOUT`.

use tr_net::rings::MacRings;
use tr_regs::generated::net;
use tr_regs::RegisterSpace;

// NET-LAYOUT: the offsets of the network page's registers
// Register offsets in bytes from the page base.
pub const REG_ID: u32 = 0x00;
pub const REG_CTRL: u32 = 0x04;
pub const REG_STATUS: u32 = 0x08;
pub const REG_IRQ: u32 = 0x0C;
pub const REG_IRQ_EN: u32 = 0x10;
pub const REG_MAC_LO: u32 = 0x14;
pub const REG_MAC_HI: u32 = 0x18;
pub const REG_MDIO: u32 = 0x1C;
pub const REG_TX_LEN: u32 = 0x20;
pub const REG_TX_DATA: u32 = 0x24;
pub const REG_TX_PTR: u32 = 0x28;
pub const REG_RX_LEN: u32 = 0x2C;
pub const REG_RX_DATA: u32 = 0x30;
pub const REG_RX_DONE: u32 = 0x34;
pub const REG_RX_COUNT: u32 = 0x38;
pub const REG_RX_DROPPED: u32 = 0x3C;
pub const REG_TX_COUNT: u32 = 0x40;
/// Value of the ID register of the network unit.
pub const ID: u32 = 0x4554_0001;
/// The chip ID (Gowin OTP DNA; `rtl/net/chip_dna.v`, SUG283-3.6.1E section 8.9): raw words 0x80 to 0x90 (129 bits of the read),
/// status 0x94 (bit 0 read done, 15:8 the ID width in bits), ID words 0x98 (low) and 0x9C (high): raw[95:32].
pub const REG_DNA_RAW: u32 = 0x80;
pub const REG_DNA_STATUS: u32 = 0x94;
pub const REG_DNA_LO: u32 = 0x98;
pub const REG_DNA_HI: u32 = 0x9C;

pub const IRQ_RX: u32 = 1 << 0;
pub const IRQ_TX_DONE: u32 = 1 << 1;
pub const IRQ_DROPPED: u32 = 1 << 2;
pub const IRQ_MDIO: u32 = 1 << 3;

/// Longest frame without its checksum.
pub const MAX_FRAME: usize = 1514;
/// MDIO address of the board's RTL8211F (strapped).
pub const PHY_ADDR: u8 = 1;

/// `REG_CTRL`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Control {
    pub rx: bool,
    pub tx: bool,
    /// The PHY's reset pin is held low.
    pub phy_reset: bool,
    /// Take every frame, whatever its address.
    pub all: bool,
    pub broadcast: bool,
    pub multicast: bool,
}

impl Control {
    /// The state after reset: PHY held in reset, MAC receiver and transmitter off, broadcast frames accepted.
    pub const RESET: Control = Control { rx: false, tx: false, phy_reset: true, all: false, broadcast: true, multicast: false };
    /// The register value.
    pub fn raw(&self) -> u32 {
        self.rx as u32
            | (self.tx as u32) << 1
            | (self.phy_reset as u32) << 2
            | (self.all as u32) << 3
            | (self.broadcast as u32) << 4
            | (self.multicast as u32) << 5
    }
}

/// `REG_STATUS`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Status {
    pub rx_waiting: bool,
    pub tx_busy: bool,
    /// The PHY's receive clock is running.
    pub rxc: bool,
    /// The PHY's own report between frames: link, speed in Mbit/s (10, 100, 1000), full duplex.
    pub phy_link: bool,
    pub phy_speed: u16,
    pub phy_full_duplex: bool,
}

impl Status {
    /// Decodes a status register value.
    pub fn from_raw(v: u32) -> Self {
        Status {
            rx_waiting: v & 1 != 0,
            tx_busy: v & 2 != 0,
            rxc: v & 4 != 0,
            phy_link: v & 8 != 0,
            phy_speed: [10, 100, 1000, 0][(v >> 4 & 3) as usize],
            phy_full_duplex: v & 64 != 0,
        }
    }
    /// The MAC works at 100 Mbit/s full duplex only.
    pub fn usable(&self) -> bool {
        self.rxc && self.phy_link && self.phy_speed == 100 && self.phy_full_duplex
    }
}

/// The network unit's page.
pub struct Eth<'a, R: RegisterSpace>(pub &'a R);

impl<R: RegisterSpace> Eth<'_, R> {
    fn rd(&self, off: u32) -> u32 {
        self.0.read32(net::BASE + off)
    }
    fn wr(&self, off: u32, v: u32) {
        self.0.write32(net::BASE + off, v)
    }
    /// True if the page answers with the ID of the network unit.
    pub fn present(&self) -> bool {
        self.rd(REG_ID) == ID
    }
    /// The chip's factory ID (64 bits, Gowin OTP "DNA") once the start-up read is done; `None` while it runs, when the bitstream
    /// has no reader, or when it read zeros or ones only.
    pub fn chip_id(&self) -> Option<u64> {
        if self.rd(REG_DNA_STATUS) & 1 == 0 {
            return None;
        }
        let id = (self.rd(REG_DNA_HI) as u64) << 32 | self.rd(REG_DNA_LO) as u64;
        (id != 0 && id != u64::MAX).then_some(id)
    }
    /// The 129 raw bits of the ID read (for a start-up report that shows where the bits sit on the board).
    pub fn chip_id_raw(&self) -> [u32; 5] {
        let mut w = [0u32; 5];
        for (i, x) in w.iter_mut().enumerate() {
            *x = self.rd(REG_DNA_RAW + 4 * i as u32);
        }
        w
    }
    /// Writes the control register.
    pub fn set_control(&self, c: Control) {
        self.wr(REG_CTRL, c.raw())
    }
    /// Reads the status register.
    pub fn status(&self) -> Status {
        Status::from_raw(self.rd(REG_STATUS))
    }
    /// The interrupt flags that are currently set (`IRQ_RX`, `IRQ_TX_DONE`, `IRQ_DROPPED`, `IRQ_MDIO`).
    pub fn irq_flags(&self) -> u32 {
        self.rd(REG_IRQ)
    }
    /// Clear the held flags (`IRQ_TX_DONE`, `IRQ_DROPPED`, `IRQ_MDIO`).
    pub fn irq_clear(&self, flags: u32) {
        self.wr(REG_IRQ, flags)
    }
    /// Selects which flags raise the interrupt.
    pub fn irq_enable(&self, flags: u32) {
        self.wr(REG_IRQ_EN, flags)
    }
    /// Sets the MAC address that the receiver accepts.
    pub fn set_mac(&self, m: [u8; 6]) {
        self.wr(REG_MAC_LO, u32::from_le_bytes([m[0], m[1], m[2], m[3]]));
        self.wr(REG_MAC_HI, u16::from_le_bytes([m[4], m[5]]) as u32);
    }
    /// The MAC address that the receiver accepts.
    pub fn mac(&self) -> [u8; 6] {
        let (lo, hi) = (self.rd(REG_MAC_LO).to_le_bytes(), self.rd(REG_MAC_HI).to_le_bytes());
        [lo[0], lo[1], lo[2], lo[3], hi[0], hi[1]]
    }

    fn mdio_wait(&self) -> Option<u16> {
        // a transfer takes about 41 us at 100 MHz (MDC = clk / 64); each register read crosses into the unit's clock
        for _ in 0..10_000 {
            let v = self.rd(REG_MDIO);
            if v >> 31 == 0 {
                return Some(v as u16);
            }
        }
        None
    }
    /// Read a PHY register; `None` if the MDIO unit does not finish.
    pub fn mdio_read(&self, phy: u8, reg: u8) -> Option<u16> {
        self.wr(REG_MDIO, 1 << 30 | (phy as u32 & 31) << 21 | (reg as u32 & 31) << 16);
        self.mdio_wait()
    }
    /// Writes a PHY register; false if the MDIO unit does not finish.
    pub fn mdio_write(&self, phy: u8, reg: u8, value: u16) -> bool {
        self.wr(REG_MDIO, (phy as u32 & 31) << 21 | (reg as u32 & 31) << 16 | value as u32);
        self.mdio_wait().is_some()
    }

    /// Send one frame (destination, source, type, payload; no checksum; shorter than 60 bytes is padded by the MAC).
    /// False if the transmitter is busy or off, or the frame is too long: nothing is sent.
    pub fn send(&self, frame: &[u8]) -> bool {
        if frame.is_empty() || frame.len() > MAX_FRAME || self.rd(REG_TX_LEN) & 1 != 0 {
            return false;
        }
        self.wr(REG_TX_PTR, 0);
        for c in frame.chunks(4) {
            let mut b = [0u8; 4];
            b[..c.len()].copy_from_slice(c);
            self.wr(REG_TX_DATA, u32::from_le_bytes(b));
        }
        self.wr(REG_TX_LEN, frame.len() as u32);
        true
    }

    /// Length of the waiting frame, if any.
    pub fn rx_len(&self) -> Option<usize> {
        match self.rd(REG_RX_LEN) & 0x7FF {
            0 => None,
            n => Some(n as usize),
        }
    }
    /// Take the waiting frame into `buf` and release it. Returns its length; a frame longer than `buf` is cut.
    pub fn recv(&self, buf: &mut [u8]) -> Option<usize> {
        let n = self.rx_len()?;
        let take = n.min(buf.len());
        for c in buf[..take].chunks_mut(4) {
            let w = self.rd(REG_RX_DATA).to_le_bytes();
            c.copy_from_slice(&w[..c.len()]);
        }
        self.wr(REG_RX_DONE, 0);
        Some(take)
    }

    /// Good frames received, frames sent.
    pub fn counts(&self) -> (u32, u32) {
        (self.rd(REG_RX_COUNT), self.rd(REG_TX_COUNT))
    }
    /// Frames dropped since the last call: for lack of room, with a wrong checksum or length.
    pub fn dropped(&self) -> (u16, u16) {
        let v = self.rd(REG_RX_DROPPED);
        (v as u16, (v >> 16) as u16)
    }
}

/// The unit as the network stack's frame rings (`tr_net`): a frame goes out when the PHY reports a usable link.
impl<R: RegisterSpace> MacRings for Eth<'_, R> {
    const MTU: usize = MAX_FRAME;

    fn can_transmit(&mut self) -> bool {
        let s = self.status();
        s.usable() && !s.tx_busy
    }

    fn transmit(&mut self, frame: &[u8]) -> bool {
        self.status().usable() && self.send(frame)
    }

    fn receive(&mut self, buf: &mut [u8]) -> Option<usize> {
        self.recv(buf)
    }
}

// ------------------------------------------------------------------------------- PHY start-up

/// PHY registers of IEEE 802.3 clause 22 used here.
pub mod phy {
    /// Control: bit 12 auto-negotiation on, bit 9 restart auto-negotiation.
    pub const BMCR: u8 = 0;
    /// Status: bit 2 link up (stays low after a loss until read), bit 5 auto-negotiation done.
    pub const BMSR: u8 = 1;
    pub const ID1: u8 = 2;
    pub const ID2: u8 = 3;
    /// What is offered at 10 and 100 Mbit/s: bit 8 100BASE-TX full duplex; bits 4:0 = 1 (802.3).
    pub const ANAR: u8 = 4;
    /// What is offered at 1000 Mbit/s (bits 9, 8).
    pub const GBCR: u8 = 9;
    pub const BMCR_AN_RESTART: u16 = 1 << 12 | 1 << 9;
    pub const ANAR_100_FULL_ONLY: u16 = 1 << 8 | 1;
    /// The board's RTL8211F (docs/H3_PHY.md).
    pub const RTL8211F_ID: u32 = 0x001C_C916;
}

/// Reset pin low for 12 ms, then 100 ms before the first MDIO access. On this board the RTL8211F read all
/// ones on MDIO 35 ms after its reset pin was released and answered at 70 ms (docs/H3_PHY.md says 10 and 30 ms); a start-up
/// that fails runs again from the reset with the wait doubled each time (up to 32 times: 100 ms to 3.2 s).
pub const PHY_RESET_MS: u32 = 12;
pub const PHY_SETTLE_MS: u32 = 100;
/// The link state is read once per second; a failed start-up is repeated after the same time.
pub const PHY_WATCH_MS: u32 = 1_000;

/// Where the PHY start-up is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PhyState {
    /// Reset pin low since time t (ms).
    ResetLow(u32),
    /// Reset released at time t.
    Settle(u32),
    /// Set up; the link is watched.
    Watch,
    /// MDIO did not answer, or no PHY on any address, at time t; the start-up runs again `PHY_WATCH_MS` later.
    Failed(u32),
}

/// What [`Phy::poll`] has to tell.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PhyEvent {
    /// Set up; `id` = registers 2 and 3; `known`: it is the RTL8211F. [`Phy::addr`] and [`Phy::fails`] say where it answered
    /// and how many start-ups failed before.
    Ready { id: u32, known: bool },
    /// MDIO gave no answer (`None`), or this is what address 1 read (all ones or zero), which is no PHY, and no other address
    /// answered. Only the first failure is an event; the start-up goes on.
    NoPhy(Option<u32>),
    /// The link state changed (the PHY's own report between frames, and its status register).
    Link { up: bool, speed: u16, full_duplex: bool, usable: bool },
}

/// PHY start-up and link watch: reset timing, 100 Mbit/s full duplex only, link state. The MAC's receiver and
/// transmitter are switched on when the PHY is set up. Called from the main loop with a millisecond clock; nothing here
/// waits except an MDIO transfer.
///
/// The identifier is read at the strapped address ([`PHY_ADDR`]) first, then at every address 0 to 31 if that shows nothing.
/// A start-up that fails (MDIO all ones, as the RTL8211F gives before it is ready) runs again from the reset every second;
/// meanwhile the receiver takes every frame, so that a console can say whether the wire is alive.
pub struct Phy {
    pub state: PhyState,
    pub id: u32,
    /// The MDIO address the PHY answered on.
    pub addr: u8,
    /// Start-ups that failed since the start.
    pub fails: u16,
    last_watch: u32,
    link: Option<(bool, u16, bool)>,
}

impl Phy {
    /// Pulls the PHY's reset pin low (it is low after the chip's reset anyway), the MAC off.
    pub fn start<R: RegisterSpace>(eth: &Eth<R>, now_ms: u32) -> Self {
        eth.set_control(Control::RESET);
        Phy { state: PhyState::ResetLow(now_ms), id: 0, addr: PHY_ADDR, fails: 0, last_watch: now_ms, link: None }
    }

    /// The identifier (registers 2 and 3) at one address: `Err` if the MDIO unit does not finish.
    fn read_id<R: RegisterSpace>(eth: &Eth<R>, addr: u8) -> Result<u32, ()> {
        match (eth.mdio_read(addr, phy::ID1), eth.mdio_read(addr, phy::ID2)) {
            (Some(a), Some(b)) => Ok((a as u32) << 16 | b as u32),
            _ => Err(()),
        }
    }

    fn fail<R: RegisterSpace>(&mut self, eth: &Eth<R>, now_ms: u32, ev: PhyEvent) -> Option<PhyEvent> {
        eth.set_control(Control { rx: true, all: true, phy_reset: false, ..Control::RESET });
        self.state = PhyState::Failed(now_ms);
        self.fails = self.fails.saturating_add(1);
        (self.fails == 1).then_some(ev)
    }

    /// Advances the start-up and the link watch. `now_ms` is a millisecond clock that may wrap.
    pub fn poll<R: RegisterSpace>(&mut self, eth: &Eth<R>, now_ms: u32) -> Option<PhyEvent> {
        match self.state {
            PhyState::ResetLow(t) if now_ms.wrapping_sub(t) >= PHY_RESET_MS => {
                eth.set_control(Control { phy_reset: false, ..Control::RESET });
                self.state = PhyState::Settle(now_ms);
                None
            }
            // (a start-up that failed waits twice as long after the next reset, up to 32 times)
            PhyState::Settle(t) if now_ms.wrapping_sub(t) >= PHY_SETTLE_MS << self.fails.min(5) => {
                let at1 = match Self::read_id(eth, PHY_ADDR) {
                    Ok(id) => id,
                    Err(()) => return self.fail(eth, now_ms, PhyEvent::NoPhy(None)),
                };
                let (addr, id) = if at1 != 0 && at1 != 0xFFFF_FFFF {
                    (PHY_ADDR, at1)
                } else {
                    // nothing at the strapped address: look at all 32
                    let mut found = None;
                    for a in (0..32u8).filter(|a| *a != PHY_ADDR) {
                        match Self::read_id(eth, a) {
                            Ok(i) if i != 0 && i != 0xFFFF_FFFF => {
                                found = Some((a, i));
                                break;
                            }
                            Ok(_) => {}
                            Err(()) => return self.fail(eth, now_ms, PhyEvent::NoPhy(None)),
                        }
                    }
                    match found {
                        Some(f) => f,
                        None => return self.fail(eth, now_ms, PhyEvent::NoPhy(Some(at1))),
                    }
                };
                self.id = id;
                self.addr = addr;
                // offer 100BASE-TX full duplex only, then negotiate again
                let ok = eth.mdio_write(addr, phy::GBCR, 0)
                    && eth.mdio_write(addr, phy::ANAR, phy::ANAR_100_FULL_ONLY)
                    && eth.mdio_write(addr, phy::BMCR, phy::BMCR_AN_RESTART);
                if !ok {
                    return self.fail(eth, now_ms, PhyEvent::NoPhy(None));
                }
                eth.set_control(Control { rx: true, tx: true, phy_reset: false, ..Control::RESET });
                self.state = PhyState::Watch;
                self.last_watch = now_ms;
                Some(PhyEvent::Ready { id, known: id == phy::RTL8211F_ID })
            }
            PhyState::Failed(t) if now_ms.wrapping_sub(t) >= PHY_WATCH_MS => {
                // again from the reset (the straps are read when the reset pin rises)
                eth.set_control(Control::RESET);
                self.state = PhyState::ResetLow(now_ms);
                None
            }
            PhyState::Watch if now_ms.wrapping_sub(self.last_watch) >= PHY_WATCH_MS => {
                self.last_watch = now_ms;
                let s = eth.status();
                // the status register's link bit stays low after a loss until it is read: read twice
                let _ = eth.mdio_read(self.addr, phy::BMSR);
                let up = eth.mdio_read(self.addr, phy::BMSR).is_some_and(|v| v & 4 != 0);
                let now_link = (up, s.phy_speed, s.phy_full_duplex);
                if self.link != Some(now_link) {
                    self.link = Some(now_link);
                    return Some(PhyEvent::Link { up, speed: s.phy_speed, full_duplex: s.phy_full_duplex, usable: up && s.usable() });
                }
                None
            }
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    extern crate std;
    use super::*;
    use core::cell::RefCell;
    use std::collections::VecDeque;
    use std::vec;
    use std::vec::Vec;

    /// The page as the driver sees it: a send buffer that turns a frame around into the receive ring, an MDIO unit
    /// that is busy for two reads and holds 32 registers.
    #[derive(Default)]
    struct Fake {
        ctrl: RefCell<u32>,
        mac: RefCell<[u32; 2]>,
        txbuf: RefCell<Vec<u32>>,
        rx: RefCell<VecDeque<Vec<u8>>>,
        rd_pos: RefCell<usize>,
        phy: RefCell<[u16; 32]>,
        mdio: RefCell<(u32, u32)>,
        dropped: RefCell<u32>,
        sent: RefCell<u32>,
        /// the only MDIO address that answers (`None`: `PHY_ADDR`)
        phy_at: RefCell<Option<u8>>,
        /// the chip ID read: done, ID
        dna: RefCell<(bool, u64)>,
    }
    impl RegisterSpace for Fake {
        fn read32(&self, addr: u32) -> u32 {
            match addr - net::BASE {
                REG_ID => ID,
                REG_CTRL => *self.ctrl.borrow(),
                REG_STATUS => !self.rx.borrow().is_empty() as u32 | 4 | 8 | 1 << 4 | 64,
                REG_MAC_LO => self.mac.borrow()[0],
                REG_MAC_HI => self.mac.borrow()[1],
                REG_MDIO => {
                    let mut m = self.mdio.borrow_mut();
                    if m.0 > 0 {
                        m.0 -= 1;
                        1 << 31
                    } else {
                        m.1
                    }
                }
                REG_RX_LEN => self.rx.borrow().front().map_or(0, |f| f.len() as u32),
                REG_RX_DATA => {
                    let rx = self.rx.borrow();
                    let f = rx.front().unwrap();
                    let mut p = self.rd_pos.borrow_mut();
                    let mut b = [0u8; 4];
                    for (i, x) in b.iter_mut().enumerate() {
                        *x = *f.get(*p + i).unwrap_or(&0xEE);
                    }
                    *p += 4;
                    u32::from_le_bytes(b)
                }
                REG_RX_DROPPED => self.dropped.replace(0),
                REG_TX_COUNT => *self.sent.borrow(),
                REG_DNA_STATUS => 64 << 8 | self.dna.borrow().0 as u32,
                REG_DNA_LO => self.dna.borrow().1 as u32,
                REG_DNA_HI => (self.dna.borrow().1 >> 32) as u32,
                // raw words: register bits 31:0 are the user region (made up), the ID sits at 95:32
                x if (REG_DNA_RAW..REG_DNA_RAW + 20).contains(&x) => match (x - REG_DNA_RAW) / 4 {
                    0 => 0x5555_5555,
                    1 => self.dna.borrow().1 as u32,
                    2 => (self.dna.borrow().1 >> 32) as u32,
                    3 => 0xABCD_1234,
                    _ => 0,
                },
                _ => 0,
            }
        }
        fn write32(&self, addr: u32, v: u32) {
            match addr - net::BASE {
                REG_CTRL => *self.ctrl.borrow_mut() = v,
                REG_MAC_LO => self.mac.borrow_mut()[0] = v,
                REG_MAC_HI => self.mac.borrow_mut()[1] = v & 0xFFFF,
                REG_MDIO => {
                    let (phy, reg) = ((v >> 21 & 31) as u8, (v >> 16 & 31) as usize);
                    let val = if phy != self.phy_at.borrow().unwrap_or(PHY_ADDR) {
                        0xFFFF
                    } else if v >> 30 & 1 != 0 {
                        self.phy.borrow()[reg] as u32
                    } else {
                        self.phy.borrow_mut()[reg] = v as u16;
                        0
                    };
                    *self.mdio.borrow_mut() = (2, val);
                }
                REG_TX_PTR => self.txbuf.borrow_mut().clear(),
                REG_TX_DATA => self.txbuf.borrow_mut().push(v),
                REG_TX_LEN => {
                    let mut f: Vec<u8> = self.txbuf.borrow().iter().flat_map(|w| w.to_le_bytes()).collect();
                    f.truncate(v as usize);
                    f.resize((v as usize).max(60), 0);
                    self.rx.borrow_mut().push_back(f);
                    *self.sent.borrow_mut() += 1;
                }
                REG_RX_DONE => {
                    self.rx.borrow_mut().pop_front();
                    *self.rd_pos.borrow_mut() = 0;
                }
                _ => {}
            }
        }
    }

    #[test]
    fn page_base_is_the_regmap_one() {
        assert_eq!(net::BASE, 0xE924_0000, "the network page (docs/NET_ID.md)");
        assert_eq!(net::id::RESET, ID);
    }

    #[test]
    fn control_status_address() {
        let f = Fake::default();
        let e = Eth(&f);
        assert!(e.present());
        assert_eq!(Control::RESET.raw(), 0x14);
        e.set_control(Control { rx: true, tx: true, phy_reset: false, ..Control::RESET });
        assert_eq!(*f.ctrl.borrow(), 0x13);
        let s = e.status();
        assert!(s.usable() && !s.rx_waiting && s.phy_speed == 100);
        assert!(!Status::from_raw(4 | 8 | 2 << 4 | 64).usable());
        e.set_mac([0x02, 0x54, 0x52, 0x00, 0x00, 0x02]);
        assert_eq!(e.mac(), [0x02, 0x54, 0x52, 0x00, 0x00, 0x02]);
    }

    #[test]
    fn mdio() {
        let f = Fake::default();
        f.phy.borrow_mut()[2] = 0x001C;
        let e = Eth(&f);
        assert_eq!(e.mdio_read(PHY_ADDR, 2), Some(0x001C));
        assert!(e.mdio_write(PHY_ADDR, 4, 0x0101));
        assert_eq!(e.mdio_read(PHY_ADDR, 4), Some(0x0101));
        assert_eq!(e.mdio_read(2, 2), Some(0xFFFF));
    }

    #[test]
    fn frame_out_and_in_also_as_mac_rings() {
        let f = Fake::default();
        let mut e = Eth(&f);
        let frame: Vec<u8> = (0..71u8).collect();
        assert!(e.can_transmit());
        assert!(e.transmit(&frame));
        assert!(!e.send(&vec![0u8; MAX_FRAME + 1]));
        let mut buf = [0u8; 128];
        assert_eq!(e.receive(&mut buf), Some(71));
        assert_eq!(&buf[..71], &frame[..]);
        assert_eq!(e.receive(&mut buf), None);
        assert!(e.send(&[1, 2, 3]));
        assert_eq!(e.rx_len(), Some(60));
        assert_eq!(e.counts().1, 2);
        *f.dropped.borrow_mut() = 3 << 16 | 1;
        assert_eq!(e.dropped(), (1, 3));
        assert_eq!(e.dropped(), (0, 0));
    }

    #[test]
    fn phy_start_up_and_link_watch() {
        let f = Fake::default();
        f.phy.borrow_mut()[2] = 0x001C;
        f.phy.borrow_mut()[3] = 0xC916;
        f.phy.borrow_mut()[9] = 0x0300;
        let e = Eth(&f);
        let mut p = Phy::start(&e, 1000);
        assert_eq!(*f.ctrl.borrow() & 4, 4, "reset pin low");
        assert_eq!(p.poll(&e, 1000 + PHY_RESET_MS - 1), None);
        assert_eq!(p.poll(&e, 1000 + PHY_RESET_MS), None);
        assert_eq!(*f.ctrl.borrow(), 0x10, "reset released, receiver and transmitter off");
        let t = 1000 + PHY_RESET_MS;
        assert_eq!(p.poll(&e, t + PHY_SETTLE_MS - 1), None);
        assert_eq!(f.phy.borrow()[4], 0, "no MDIO access before the settle time");
        assert_eq!(p.poll(&e, t + PHY_SETTLE_MS), Some(PhyEvent::Ready { id: 0x001C_C916, known: true }));
        assert_eq!((f.phy.borrow()[9], f.phy.borrow()[4], f.phy.borrow()[0]), (0, 0x0101, 0x1200));
        assert_eq!(*f.ctrl.borrow(), 0x13, "MAC on once the PHY is set up");
        let t = t + PHY_SETTLE_MS;
        f.phy.borrow_mut()[1] = 4;
        assert_eq!(p.poll(&e, t + PHY_WATCH_MS), Some(PhyEvent::Link { up: true, speed: 100, full_duplex: true, usable: true }));
        assert_eq!(p.poll(&e, t + 2 * PHY_WATCH_MS), None, "no change, no event");
        f.phy.borrow_mut()[1] = 0;
        assert_eq!(p.poll(&e, t + 3 * PHY_WATCH_MS), Some(PhyEvent::Link { up: false, speed: 100, full_duplex: true, usable: false }));
        let g = Fake::default();
        g.phy.borrow_mut()[2] = 0xFFFF;
        g.phy.borrow_mut()[3] = 0xFFFF;
        let e = Eth(&g);
        let mut p = Phy::start(&e, 0);
        p.poll(&e, PHY_RESET_MS);
        assert_eq!(p.poll(&e, PHY_RESET_MS + PHY_SETTLE_MS), Some(PhyEvent::NoPhy(Some(0xFFFF_FFFF))));
        assert_eq!(p.state, PhyState::Failed(PHY_RESET_MS + PHY_SETTLE_MS));
        assert_eq!(*g.ctrl.borrow(), 0x01 | 0x08 | 0x10, "receiver takes every frame while the PHY is missing, reset released");
    }

    /// The RTL8211F read all ones 35 ms after its reset pin rose and answered at 70 ms (measured on this board).
    /// The first wait is 100 ms; a start-up that fails starts again from the reset with twice the wait.
    #[test]
    fn phy_start_up_is_repeated_until_the_phy_answers() {
        let f = Fake::default();
        f.phy.borrow_mut()[2] = 0xFFFF;
        f.phy.borrow_mut()[3] = 0xFFFF;
        let e = Eth(&f);
        let mut p = Phy::start(&e, 0);
        assert_eq!(p.poll(&e, PHY_RESET_MS), None);
        let t1 = PHY_RESET_MS + PHY_SETTLE_MS;
        assert_eq!(p.poll(&e, t1 - 1), None, "no MDIO access before 100 ms");
        // all ones at every address: the first failure is an event
        assert_eq!(p.poll(&e, t1), Some(PhyEvent::NoPhy(Some(0xFFFF_FFFF))));
        assert_eq!((p.state, p.fails), (PhyState::Failed(t1), 1));
        // the PHY is ready by now; a second later the start-up begins again from the reset pin
        f.phy.borrow_mut()[2] = 0x001C;
        f.phy.borrow_mut()[3] = 0xC916;
        assert_eq!(p.poll(&e, t1 + PHY_WATCH_MS - 1), None);
        assert_eq!(p.poll(&e, t1 + PHY_WATCH_MS), None);
        assert_eq!(p.state, PhyState::ResetLow(t1 + PHY_WATCH_MS));
        assert_eq!(*f.ctrl.borrow() & 4, 4, "PHY reset held again");
        let t2 = t1 + PHY_WATCH_MS + PHY_RESET_MS;
        assert_eq!(p.poll(&e, t2), None);
        assert_eq!(p.poll(&e, t2 + 2 * PHY_SETTLE_MS - 1), None, "after one failure the wait is twice as long");
        assert_eq!(p.poll(&e, t2 + 2 * PHY_SETTLE_MS), Some(PhyEvent::Ready { id: 0x001C_C916, known: true }));
        assert_eq!((p.addr, p.fails), (PHY_ADDR, 1));
        assert_eq!(*f.ctrl.borrow(), 0x13);
    }

    #[test]
    fn a_failed_start_up_is_reported_once_and_the_wait_stops_doubling_at_32() {
        let f = Fake::default();
        f.phy.borrow_mut()[2] = 0xFFFF;
        f.phy.borrow_mut()[3] = 0xFFFF;
        let e = Eth(&f);
        let mut p = Phy::start(&e, 0);
        let mut t = 0;
        let mut events = 0;
        for k in 0..8u32 {
            t += PHY_RESET_MS;
            assert_eq!(p.poll(&e, t), None);
            t += PHY_SETTLE_MS << k.min(5);
            events += p.poll(&e, t).is_some() as u32;
            assert_eq!(p.fails as u32, k + 1);
            t += PHY_WATCH_MS;
            assert_eq!(p.poll(&e, t), None);
        }
        assert_eq!(events, 1, "only the first failure is an event");
    }

    #[test]
    fn a_phy_on_another_mdio_address_is_found() {
        let f = Fake::default();
        *f.phy_at.borrow_mut() = Some(7);
        f.phy.borrow_mut()[2] = 0x001C;
        f.phy.borrow_mut()[3] = 0xC916;
        let e = Eth(&f);
        let mut p = Phy::start(&e, 0);
        assert_eq!(p.poll(&e, PHY_RESET_MS), None);
        assert_eq!(p.poll(&e, PHY_RESET_MS + PHY_SETTLE_MS), Some(PhyEvent::Ready { id: 0x001C_C916, known: true }));
        assert_eq!(p.addr, 7);
        // the link watch uses that address
        f.phy.borrow_mut()[1] = 4;
        assert_eq!(
            p.poll(&e, PHY_RESET_MS + PHY_SETTLE_MS + PHY_WATCH_MS),
            Some(PhyEvent::Link { up: true, speed: 100, full_duplex: true, usable: true })
        );
    }

    /// The link test accepts 100 Mbit/s full duplex (what the unit and the PHY's offer give) and nothing else.
    #[test]
    fn only_100_mbit_full_duplex_is_usable() {
        let rxc_link = 4 | 8;
        assert!(Status::from_raw(rxc_link | 1 << 4 | 64).usable());
        assert!(!Status::from_raw(rxc_link | 2 << 4 | 64).usable(), "1000 Mbit/s");
        assert!(!Status::from_raw(rxc_link | 0 << 4 | 64).usable(), "10 Mbit/s");
        assert!(!Status::from_raw(rxc_link | 1 << 4).usable(), "half duplex");
        assert!(!Status::from_raw(8 | 1 << 4 | 64).usable(), "no receive clock");
    }

    #[test]
    fn chip_id_from_the_network_page() {
        let f = Fake::default();
        let e = Eth(&f);
        assert_eq!(e.chip_id(), None, "the read has not finished");
        *f.dna.borrow_mut() = (true, 0x0123_4567_89AB_CDEF);
        assert_eq!(e.chip_id(), Some(0x0123_4567_89AB_CDEF));
        assert_eq!(e.chip_id_raw(), [0x5555_5555, 0x89AB_CDEF, 0x0123_4567, 0xABCD_1234, 0]);
        *f.dna.borrow_mut() = (true, 0);
        assert_eq!(e.chip_id(), None, "zeros: no reader or nothing read");
        *f.dna.borrow_mut() = (true, u64::MAX);
        assert_eq!(e.chip_id(), None);
    }
}
