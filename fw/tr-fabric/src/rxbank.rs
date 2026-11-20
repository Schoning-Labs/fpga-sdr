// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Receiver bank (`hw/regmap/rx_bank.toml`): frequency and output rate of the receivers. The register
//! layout always has [`MAX_RECEIVERS`] slots; the chip has [`RxBank::count`] of them (1 to 8, 4 in the
//! default build): the others read 0 and ignore writes (`docs/DECISIONS.md`, receiver count).

use tr_regs::generated::rx_bank;
use tr_regs::RegisterSpace;

pub use crate::system::MAX_RECEIVERS;
use crate::system::System;

/// Output rate of a bank receiver (of HL2 time).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Rate {
    K48 = 0,
    K96 = 1,
    K192 = 2,
    K384 = 3,
}

/// Driver for the receiver bank page.
pub struct RxBank<'a, R: RegisterSpace> {
    regs: &'a R,
}

impl<'a, R: RegisterSpace> RxBank<'a, R> {
    /// A driver on the register space `regs`.
    pub fn new(regs: &'a R) -> Self {
        RxBank { regs }
    }

    /// The identification register of the block.
    pub fn id(&self) -> u32 {
        rx_bank::id::read(self.regs)
    }

    /// Receivers the chip was built with (1 to 8): receiver numbers below it exist.
    pub fn count(&self) -> u32 {
        System::new(self.regs).num_rx()
    }

    /// Tunes receiver `rx` (below [`RxBank::count`]): 0 Hz of its output is `hz` at the antenna. May change while running.
    pub fn set_frequency_hz(&self, rx: u32, hz: u32) {
        rx_bank::phase_inc::write(self.regs, rx, rx_bank::phase_inc::Value(crate::phase_inc(hz)));
    }

    /// Starts receiver `rx` at `rate`. The back-end receiver must be re-enabled afterwards
    /// (docs/R4_BACKEND.md, firmware obligations).
    pub fn start(&self, rx: u32, rate: Rate) {
        rx_bank::ctrl::write(self.regs, rx, rx_bank::ctrl::Value(0).with_rate_sel(rate as u32).with_enable(true));
    }

    /// Disables receiver `rx`.
    pub fn stop(&self, rx: u32) {
        rx_bank::ctrl::modify(self.regs, rx, |v| v.with_enable(false));
    }

    /// True if receiver `rx` is enabled.
    pub fn is_running(&self, rx: u32) -> bool {
        rx_bank::ctrl::read(self.regs, rx).enable()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mock::MockFabric;

    #[test]
    fn tune_and_start() {
        let f = MockFabric::new();
        let b = RxBank::new(&f);
        b.set_frequency_hz(2, 7_074_000);
        b.start(2, Rate::K48);
        assert_eq!(f.reg(0xE803_0004 + 2 * 8), crate::phase_inc(7_074_000));
        assert_eq!(f.reg(0xE803_0008 + 2 * 8), 1);
        b.start(3, Rate::K384);
        assert_eq!(f.reg(0xE803_0008 + 3 * 8), 0b111);
        b.stop(3);
        assert_eq!(f.reg(0xE803_0008 + 3 * 8), 0b110);
        assert!(b.is_running(2) && !b.is_running(3));
    }

    #[test]
    fn count_follows_the_system_page() {
        let f = MockFabric::new();
        assert_eq!(RxBank::new(&f).count(), MAX_RECEIVERS, "a chip that does not report its count has 8");
        f.poke(0xE800_001C, 4 << 16);
        assert_eq!(RxBank::new(&f).count(), 4);
    }
}
