// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! TX path: the TX chain's registers (`hw/regmap/tx.toml`), the TX baseband ring in DDR3 and the
//! link framer's enable (`hl2_link.tx_ctrl`).
//!
//! **What this can and cannot do.** Arming lets the Tang's TX chain read the ring and lets the
//! framer send its samples to the HL2. It does not key the HL2 and does not select the HL2's real
//! DAC: both are commands to the HL2 (its `TX_PERMIT` and register 0x31) that no code in this
//! repository sends. An HL2 that is not keyed radiates nothing whatever arrives here.
//!
//! **Off by default.** [`TxPath::new`] switches the chain and the framer off. They go on only
//! through [`TxPath::arm`], which takes an [`OperatorTxPermit`]: a value only
//! [`OperatorTxPermit::from_operator_action`] makes, to be called from the handler of the
//! operator's TX button and nowhere else.
//!
//! Ring format (`rtl/audio/audio_ring_reader.v` as the TX ring, `rtl/top/sdr_core.v`):
//! 8,192 words of `{I[15:0], Q[15:0]}` (I in bits 31:16) at 48 ksps, 171 ms. The fabric's read
//! pointer restarts at 0 whenever the chain is disabled.

use tr_regs::generated::{hl2_link, tx};
use tr_regs::RegisterSpace;

use crate::mem::{FabricMem, Flushed};
use crate::ring::RingCore;

/// Ring size in words. It is fixed in the fabric, and the `ring_size` register is stored but not used.
pub const TX_RING_WORDS: u32 = 8_192;
/// TX baseband sample rate.
pub const TX_RATE: u32 = 48_000;

/// One ring word from an I/Q pair.
pub const fn iq_word(i: i16, q: i16) -> u32 {
    ((i as u16 as u32) << 16) | (q as u16 as u32)
}

/// The operator's explicit permission to switch the TX path on.
pub struct OperatorTxPermit(());

impl OperatorTxPermit {
    /// Call only from the handler of an operator action (the TX enable control on the screen).
    pub fn from_operator_action() -> Self {
        OperatorTxPermit(())
    }
}

/// Driver for the TX chain and the TX baseband ring.
pub struct TxPath<'a, R: RegisterSpace, M: FabricMem> {
    regs: &'a R,
    mem: &'a M,
    ring: RingCore,
    armed: bool,
}

impl<'a, R: RegisterSpace, M: FabricMem> TxPath<'a, R, M> {
    /// Takes the TX path over in the off state: chain off, framer off, ring empty at
    /// `ring_addr` (CPU byte address, a multiple of 4).
    pub fn new(regs: &'a R, mem: &'a M, ring_addr: u32) -> Self {
        let t = TxPath { regs, mem, ring: RingCore { base: ring_addr, words: TX_RING_WORDS, wptr: 0 }, armed: false };
        t.off();
        tx::ring_base::write(regs, ring_addr / 4);
        tx::ring_size::write(regs, TX_RING_WORDS);
        t
    }

    fn off(&self) {
        hl2_link::tx_ctrl::write(self.regs, hl2_link::tx_ctrl::Value(0).with_enable(false));
        tx::ctrl::write(self.regs, tx::ctrl::Value(0).with_enable(false));
        // Moving the pointer back to 0 exposes no new data, so no flush is needed.
        tx::ring_wptr::write(self.regs, 0);
    }

    /// The identification register of the block.
    pub fn id(&self) -> u32 {
        tx::id::read(self.regs)
    }

    /// Up-mix frequency in Hz (the dial frequency: baseband 0 Hz lands there).
    pub fn set_frequency_hz(&self, hz: u32) {
        tx::nco_phase_inc::write(self.regs, tx::nco_phase_inc::Value(crate::phase_inc(hz)));
    }

    /// Extra attenuation, 0-31 right shifts (the chain reads the gain register's low 5 bits).
    pub fn set_gain_shift(&self, shift: u8) {
        tx::gain::write(self.regs, tx::gain::Value(0).with_value(shift.min(31) as u32));
    }

    /// Switches the chain and the framer on with an empty ring.
    pub fn arm(&mut self, _permit: OperatorTxPermit) {
        self.off();
        self.ring.wptr = 0;
        tx::ctrl::write(self.regs, tx::ctrl::Value(0).with_enable(true));
        hl2_link::tx_ctrl::write(self.regs, hl2_link::tx_ctrl::Value(0).with_enable(true));
        self.armed = true;
    }

    /// Switches both off; whatever is still in the ring is dropped.
    pub fn disarm(&mut self) {
        self.off();
        self.ring.wptr = 0;
        self.armed = false;
    }

    /// True once [`TxPath::arm`] has been called and the path has not been disarmed since.
    pub fn is_armed(&self) -> bool {
        self.armed
    }

    fn rptr(&self) -> u32 {
        tx::ring_rptr::read(self.regs)
    }

    /// Samples queued and not yet played.
    pub fn fill(&self) -> u32 {
        self.ring.fill(self.rptr())
    }

    /// Words that can be queued before the ring is full.
    pub fn free(&self) -> u32 {
        self.ring.free(self.rptr())
    }

    /// Queues as many of `iq` ([`iq_word`]) as fit and returns how many; 0 while not armed. The
    /// samples are flushed to DDR3 before the write pointer moves (the 10 us rule).
    pub fn push(&mut self, iq: &[u32]) -> usize {
        if !self.armed {
            return 0;
        }
        let rptr = self.rptr();
        let regs = self.regs;
        self.ring.push(self.mem, rptr, iq, |wptr, _flushed: Flushed| tx::ring_wptr::write(regs, wptr))
    }

    /// Sticky "ring ran low" flag (interrupt line 4).
    pub fn low_water(&self) -> bool {
        tx::status::read(self.regs).low_water()
    }

    /// Clears the low-water flag.
    pub fn clear_low_water(&self) {
        tx::status::clear_low_water(self.regs);
    }

    /// The rate lock is repeating a sample to hold the HL2's TX FIFO.
    pub fn trimming_up(&self) -> bool {
        tx::status::read(self.regs).trimming_up()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mem::map::TX_RING;
    use crate::mock::{Ev, MockFabric};
    use alloc::vec::Vec;

    #[test]
    fn starts_off_and_stays_off_without_a_permit() {
        let f = MockFabric::new();
        // As if something had left the path on.
        f.poke(tx::ctrl::addr(), 1);
        f.poke(hl2_link::tx_ctrl::addr(), 1);
        let mut t = TxPath::new(&f, &f, TX_RING);
        assert_eq!(f.reg(tx::ctrl::addr()), 0);
        assert_eq!(f.reg(hl2_link::tx_ctrl::addr()), 0);
        assert_eq!(f.reg(tx::ring_base::addr()), TX_RING / 4);
        assert!(!t.is_armed());
        f.clear_log();
        assert_eq!(t.push(&[iq_word(1, 2); 16]), 0);
        assert!(f.log.borrow().is_empty(), "an unarmed push must touch nothing");
    }

    #[test]
    fn arm_then_push_follows_the_flush_rule_and_wraps() {
        let f = MockFabric::new();
        let mut t = TxPath::new(&f, &f, TX_RING);
        t.arm(OperatorTxPermit::from_operator_action());
        assert_eq!(f.reg(tx::ctrl::addr()), 1);
        assert_eq!(f.reg(hl2_link::tx_ctrl::addr()), 1);

        let data: Vec<u32> = (0..8_000u32).collect();
        assert_eq!(t.push(&data), 8_000);
        assert_eq!(f.reg(tx::ring_wptr::addr()), 8_000);
        assert_eq!(t.free(), 192);
        // The reader has played 7,000: a push of 1,000 now wraps past the end of the ring.
        f.poke(tx::ring_rptr::addr(), 7_000);
        let more: Vec<u32> = (100_000..101_000u32).collect();
        assert_eq!(t.push(&more), 1_000);
        assert_eq!(f.reg(tx::ring_wptr::addr()), 9_000);
        assert_eq!(f.mem(TX_RING + 8_191 * 4), 100_191);
        assert_eq!(f.mem(TX_RING), 100_192);
        assert_eq!(f.mem(TX_RING + 807 * 4), 100_999);
        // Full ring: nothing more fits until the reader moves.
        f.poke(tx::ring_rptr::addr(), 808);
        assert_eq!(t.push(&data), 0);
        assert_eq!(f.flush_rule_violations(&[tx::ring_wptr::addr()]), 0);
        // The last pointer write is preceded by two write-backs (the wrap) and the wait.
        let log = f.log.borrow();
        let tail: Vec<&Ev> = log.iter().rev().take(4).collect();
        assert_eq!(*tail[0], Ev::RegWrite(tx::ring_wptr::addr(), 9_000));
        assert_eq!(*tail[1], Ev::Delay(crate::mem::BRIDGE_FLUSH_US));
        assert_eq!(*tail[2], Ev::Writeback(TX_RING, 808 * 4));
        assert_eq!(*tail[3], Ev::Writeback(TX_RING + 8_000 * 4, 192 * 4));
    }

    #[test]
    fn the_mock_catches_a_pointer_moved_too_early() {
        let f = MockFabric::new();
        crate::mem::FabricMem::write32(&f, TX_RING, 5);
        tx::ring_wptr::write(&f, 1);
        assert_eq!(f.flush_rule_violations(&[tx::ring_wptr::addr()]), 1);
    }

    #[test]
    fn disarm_empties_the_ring_and_switches_off() {
        let f = MockFabric::new();
        let mut t = TxPath::new(&f, &f, TX_RING);
        t.arm(OperatorTxPermit::from_operator_action());
        t.push(&[7; 100]);
        t.disarm();
        assert_eq!(f.reg(tx::ctrl::addr()), 0);
        assert_eq!(f.reg(hl2_link::tx_ctrl::addr()), 0);
        assert_eq!(f.reg(tx::ring_wptr::addr()), 0);
        assert_eq!(t.push(&[7; 4]), 0);
    }

    #[test]
    fn frequency_and_gain() {
        let f = MockFabric::new();
        let t = TxPath::new(&f, &f, TX_RING);
        t.set_frequency_hz(14_074_000);
        t.set_gain_shift(3);
        assert_eq!(f.reg(tx::nco_phase_inc::addr()), 787_075_127);
        assert_eq!(f.reg(tx::gain::addr()), 3);
        assert_eq!(iq_word(-1, 2), 0xFFFF_0002);
    }
}
