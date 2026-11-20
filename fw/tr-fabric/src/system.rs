// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! System page (`hw/regmap/system.toml`): identification, status, the 16 interrupt lines, and a
//! monotonic microsecond clock from the free-running 120 MHz cycle counter. That clock is the
//! time base the SNTP client disciplines to UTC (`tr_net::clock`).

use core::cell::Cell;

use tr_net::clock::MonotonicUs;
use tr_regs::generated::system as sys;
use tr_regs::RegisterSpace;

/// Interrupt lines (docs/ARCHITECTURE.md 4.3).
pub mod irq {
    pub const HL2_PACKET: u32 = 1 << 0;
    pub const HL2_STATUS: u32 = 1 << 1;
    pub const AUDIO_LOW: u32 = 1 << 3;
    pub const TX_LOW: u32 = 1 << 4;
    pub const SPECTRUM_LINE: u32 = 1 << 5;
    pub const SFP_PACKET: u32 = 1 << 6;
    pub const SFP_LINK: u32 = 1 << 7;
    pub const VIDEO_FRAME: u32 = 1 << 8;
    pub const BACKEND_BLOCK: u32 = 1 << 10;
    pub const FT8: u32 = 1 << 11;
}

/// The value of `status.num_rx` as a receiver count: 0 (field not implemented) is 8, more than 8 is 8.
pub const fn rx_count(raw: u32) -> u32 {
    if raw == 0 || raw > MAX_RECEIVERS {
        MAX_RECEIVERS
    } else {
        raw
    }
}

/// The system status register: start-up and bus state.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SysStatus {
    pub ddr3_init: bool,
    pub plls_locked: bool,
    pub bus_timeout: bool,
    /// The HL2 link's receive clock is missing (no Ethernet link): its packet page reads 0xDEAD_BEEF.
    pub rx_domain_dead: bool,
    /// Receivers built into the bitstream, 1 to 8 ([`System::num_rx`]).
    pub num_rx: u32,
}

/// Receiver slots in every block's register layout: the most a bitstream can have.
pub const MAX_RECEIVERS: u32 = 8;

/// Driver for the system page.
pub struct System<'a, R: RegisterSpace> {
    regs: &'a R,
}

impl<'a, R: RegisterSpace> System<'a, R> {
    pub fn new(regs: &'a R) -> Self {
        System { regs }
    }

    /// 0x5452_0001 on this chip.
    pub fn id(&self) -> u32 {
        sys::id::read(self.regs)
    }

    /// First 8 hex digits of the git commit the bitstream was built from.
    pub fn build(&self) -> u32 {
        sys::build::read(self.regs)
    }

    /// Writes and reads back the scratch register: true if the register bus works.
    pub fn bus_test(&self) -> bool {
        [0xA5A5_5A5Au32, 0x0F0F_F0F0].iter().all(|&v| {
            sys::scratch::write(self.regs, v);
            sys::scratch::read(self.regs) == v
        })
    }

    /// Reads the system status.
    pub fn status(&self) -> SysStatus {
        let s = sys::status::read(self.regs);
        SysStatus {
            ddr3_init: s.ddr3_init(),
            plls_locked: s.plls_locked(),
            bus_timeout: s.bus_timeout(),
            rx_domain_dead: s.rx_domain_dead(),
            num_rx: rx_count(s.num_rx()),
        }
    }

    /// Receivers built into this bitstream (1 to 8; `gowin/p1/build.sh` `TR_NRX`, default 4). Read it once
    /// at start and size loops and tables with it: receivers at or above it read 0 and ignore writes in
    /// every block, but the register layout is always the 8-receiver one. A bitstream from before the
    /// field existed (or a mock that never set it) reads 0 and counts as 8.
    pub fn num_rx(&self) -> u32 {
        self.status().num_rx
    }

    /// Clears the bus-timeout flag.
    pub fn clear_bus_timeout(&self) {
        sys::status::clear_bus_timeout(self.regs);
    }

    /// Routes the given lines ([`irq`]) to the processor.
    pub fn set_irq_enable(&self, lines: u32) {
        sys::irq_enable::write(self.regs, sys::irq_enable::Value(0).with_lines(lines & 0xFFFF));
    }

    /// Lines that fired since they were last taken; clears exactly those.
    pub fn take_irqs(&self) -> u32 {
        let p = sys::irq_pending::read(self.regs).lines();
        if p != 0 {
            self.regs.write32(sys::irq_pending::addr(), p);
        }
        p
    }

    /// The free-running 120 MHz cycle counter of the logic (32 bits, it wraps).
    pub fn dsp_cycles(&self) -> u32 {
        sys::dsp_cycles::read(self.regs)
    }
}

/// Monotonic microseconds from `system.dsp_cycles` (120 MHz, 32 bit: wraps every 35.8 s). Each
/// reading extends the count, so it must be read at least once per 35 s; the firmware's main loop
/// reads it many times per second.
pub struct CycleClock<'a, R: RegisterSpace> {
    regs: &'a R,
    last: Cell<u32>,
    total: Cell<u64>,
}

impl<'a, R: RegisterSpace> CycleClock<'a, R> {
    pub const HZ: u64 = 120_000_000;

    pub fn new(regs: &'a R) -> Self {
        CycleClock { regs, last: Cell::new(sys::dsp_cycles::read(regs)), total: Cell::new(0) }
    }

    /// Cycles since this clock was made.
    pub fn cycles(&self) -> u64 {
        let now = sys::dsp_cycles::read(self.regs);
        self.total.set(self.total.get() + now.wrapping_sub(self.last.get()) as u64);
        self.last.set(now);
        self.total.get()
    }
}

impl<R: RegisterSpace> MonotonicUs for CycleClock<'_, R> {
    fn now_us(&self) -> u64 {
        self.cycles() / 120
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mock::MockFabric;

    #[test]
    fn status_and_interrupts() {
        let f = MockFabric::new();
        let s = System::new(&f);
        assert!(s.bus_test());
        f.poke(sys::status::addr(), 0b11 | (1 << 9));
        assert_eq!(s.status(), SysStatus { ddr3_init: true, plls_locked: true, bus_timeout: false, rx_domain_dead: true, num_rx: 8 });
        s.set_irq_enable(irq::HL2_PACKET | irq::BACKEND_BLOCK);
        assert_eq!(f.reg(sys::irq_enable::addr()), 0x401);
        f.poke(sys::irq_pending::addr(), 0x401);
        f.clear_log();
        assert_eq!(s.take_irqs(), 0x401);
        assert_eq!(f.reg_writes(sys::irq_pending::addr()), [0x401]);
    }

    #[test]
    fn receiver_count_from_the_status_register() {
        let f = MockFabric::new();
        let s = System::new(&f);
        assert_eq!(s.num_rx(), 8, "an unset field is an 8-receiver chip");
        f.poke(sys::status::addr(), 0b11 | (4 << 16));
        assert_eq!(s.num_rx(), 4);
        f.poke(sys::status::addr(), 8 << 16);
        assert_eq!(s.num_rx(), 8);
        f.poke(sys::status::addr(), 15 << 16);
        assert_eq!(s.num_rx(), 8, "more than the layout holds is clamped");
        assert_eq!((rx_count(0), rx_count(1), rx_count(5)), (8, 1, 5));
    }

    #[test]
    fn cycle_clock_extends_across_the_wrap() {
        let f = MockFabric::new();
        f.poke(sys::dsp_cycles::addr(), 0xFFFF_FF00);
        let c = CycleClock::new(&f);
        assert_eq!(c.now_us(), 0);
        f.poke(sys::dsp_cycles::addr(), 0x0000_0050); // 0x150 = 336 cycles later, across the wrap
        assert_eq!(c.cycles(), 336);
        f.poke(sys::dsp_cycles::addr(), 0x0000_0050 + 120_000_000);
        assert_eq!(c.now_us(), 1_000_002);
    }
}
