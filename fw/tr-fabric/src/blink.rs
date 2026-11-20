// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Board link on SFP1 (page 0xE80B_0000, `hw/regmap/blink.toml`, `rtl/blink/blink_top.v`,
//! docs/SFP_LINKS.md section 5): the HL2 sample stream to a second board, 32-bit control words between
//! the two CPUs, link state and counters. Board 1 calls [`BoardLink::configure`] with `send_samples`,
//! board 2 with `rx_from_link` (its receivers then take the link's stream; switch with the receivers
//! disabled). What the 32 bits of a control word mean is the caller's.

use tr_regs::generated::blink as reg;
use tr_regs::RegisterSpace;

/// Link state as read from the status register.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct LinkStatus {
    pub aligned: bool,
    pub link_up: bool,
    pub remote_link_up: bool,
    pub remote_sending: bool,
    pub remote_ctl_full: bool,
    pub ctl_tx_full: bool,
    pub ctl_rx_avail: bool,
}

/// Counters of the link. They run freely from the moment the link is enabled and are cleared when it is disabled.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct LinkCounters {
    pub rx_frames: u32,
    pub rx_bad: u32,
    pub rx_seq_jumps: u32,
    pub align_losses: u32,
    pub link_ups: u32,
    pub tx_samples: u32,
    pub rx_samples: u32,
    pub tx_frames: u32,
    pub ctl_sent: u32,
    pub ctl_received: u32,
    pub ctl_lost: u32,
    pub ctl_dropped: u32,
    pub remote_bad: u32,
    pub gap_events: u32,
    pub gap_samples: u32,
    pub resyncs: u32,
    pub tx_overflows: u32,
    pub rx_overruns: u32,
}

/// Driver for the link to a second board.
pub struct BoardLink<'a, R: RegisterSpace> {
    regs: &'a R,
}

impl<'a, R: RegisterSpace> BoardLink<'a, R> {
    /// A driver on the register space `regs`.
    pub fn new(regs: &'a R) -> Self {
        BoardLink { regs }
    }

    /// `enable` false holds the link logic in reset and clears its counters.
    pub fn configure(&self, enable: bool, send_samples: bool, rx_from_link: bool) {
        self.regs.write32(reg::ctrl::addr(), enable as u32 | (send_samples as u32) << 1 | (rx_from_link as u32) << 2);
    }

    /// Reads the link state.
    pub fn status(&self) -> LinkStatus {
        let v = self.regs.read32(reg::status::addr());
        LinkStatus {
            aligned: v & 1 != 0,
            link_up: v & 2 != 0,
            remote_link_up: v & 4 != 0,
            remote_sending: v & 8 != 0,
            remote_ctl_full: v & 16 != 0,
            ctl_tx_full: v & 32 != 0,
            ctl_rx_avail: v & 64 != 0,
        }
    }

    /// Queues a control word for the other board. `false`: our FIFO or the other board's is full, or the
    /// link is down; nothing was queued.
    pub fn send(&self, word: u32) -> bool {
        let s = self.status();
        if !s.link_up || s.ctl_tx_full || s.remote_ctl_full {
            return false;
        }
        self.regs.write32(reg::ctl_tx::addr(), word);
        true
    }

    /// Takes the waiting control word, if there is one.
    pub fn receive(&self) -> Option<u32> {
        self.status().ctl_rx_avail.then(|| self.regs.read32(reg::ctl_rx::addr()))
    }

    /// Index of the next sample of the link's stream (the HL2's sample count on board 1).
    pub fn sample_index(&self) -> u64 {
        let lo = self.regs.read32(reg::sample_index_lo::addr()) as u64;
        lo | (self.regs.read32(reg::sample_index_hi::addr()) as u64 & 0xFFFF) << 32
    }

    /// Reads the link counters.
    pub fn counters(&self) -> LinkCounters {
        let r = |a: u32| self.regs.read32(a);
        let (tx, ctl) = (r(reg::tx_counts::addr()), r(reg::ctl_counts::addr()));
        LinkCounters {
            rx_frames: r(reg::rx_frames::addr()),
            rx_bad: r(reg::rx_bad::addr()),
            rx_seq_jumps: r(reg::rx_seq_jumps::addr()),
            align_losses: r(reg::align_losses::addr()),
            link_ups: r(reg::link_ups::addr()),
            tx_samples: r(reg::tx_samples::addr()),
            rx_samples: r(reg::rx_samples::addr()),
            tx_frames: tx & 0xFFFF,
            ctl_sent: tx >> 16,
            ctl_received: ctl & 0xFFFF,
            ctl_lost: ctl >> 16,
            ctl_dropped: r(reg::ctl_dropped::addr()),
            remote_bad: r(reg::remote_bad::addr()),
            gap_events: r(reg::gap_events::addr()),
            gap_samples: r(reg::gap_samples::addr()),
            resyncs: r(reg::resyncs::addr()),
            tx_overflows: r(reg::tx_overflows::addr()),
            rx_overruns: r(reg::rx_overruns::addr()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mock::MockFabric;

    #[test]
    fn configure_and_control_words() {
        let m = MockFabric::new();
        let l = BoardLink::new(&m);
        l.configure(true, false, true);
        assert_eq!(m.reg(reg::ctrl::addr()), 0b101);
        // link down: nothing queued
        assert!(!l.send(7));
        assert!(m.reg_writes(reg::ctl_tx::addr()).is_empty());
        m.poke(reg::status::addr(), 0b000_0011);
        assert!(l.send(0xC0DE));
        assert_eq!(m.reg_writes(reg::ctl_tx::addr()), [0xC0DE]);
        m.poke(reg::status::addr(), 0b001_0011); // the other board's FIFO is full
        assert!(!l.send(8));
        assert_eq!(l.receive(), None);
        m.poke(reg::status::addr(), 0b100_0011);
        m.poke(reg::ctl_rx::addr(), 0xBEEF);
        assert_eq!(l.receive(), Some(0xBEEF));
    }

    #[test]
    fn counters_and_index() {
        let m = MockFabric::new();
        let l = BoardLink::new(&m);
        m.poke(reg::tx_counts::addr(), 0x0003_0010);
        m.poke(reg::ctl_counts::addr(), 0x0001_0005);
        m.poke(reg::sample_index_lo::addr(), 0x8000_0001);
        m.poke(reg::sample_index_hi::addr(), 0x12);
        let c = l.counters();
        assert_eq!((c.tx_frames, c.ctl_sent, c.ctl_received, c.ctl_lost), (0x10, 3, 5, 1));
        assert_eq!(l.sample_index(), 0x12_8000_0001);
    }
}
