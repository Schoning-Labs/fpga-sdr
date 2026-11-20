// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! HL2 link (`hw/regmap/hl2_link.toml`, `hl2_pkt.toml`; docs/H1_LINK_RX.md, docs/H2_LINK_TX.md):
//! addressing, status, counters, the safety byte, the HL2 sample index, and the packet path for
//! everything that is not a raw sample frame (discovery, commands, ARP, DHCP) as
//! [`tr_net::rings::MacRings`].
//!
//! The TX sample framer's enable (`tx_ctrl`) is not here: it belongs to [`crate::tx::TxPath`],
//! behind the operator's permit.
//!
//! Receive ring (`rtl/hl2link/cpu_rx_ring.v`): 4,096 bytes; each frame is a 2-byte big-endian
//! length, then the frame from the destination MAC to the last payload byte, padded to an even
//! number of bytes. `ring_wptr` is one past the newest whole frame. There is no read pointer in
//! the logic, so a reader that falls a whole ring behind reads garbage: [`Hl2Packets::receive`]
//! drops everything and starts again at the write pointer when a length makes no sense.

use tr_net::rings::MacRings;
use tr_regs::generated::{hl2_link as link, hl2_pkt as pkt};
use tr_regs::RegisterSpace;

/// Bits of the HL2's safety byte (rawfront PROTOCOL 5.4).
pub mod safety {
    pub const TX_FORCED_OFF: u8 = 1 << 0;
    pub const PA_KEYED: u8 = 1 << 1;
    pub const HOST_MOX: u8 = 1 << 2;
    pub const PTT_IN: u8 = 1 << 3;
    pub const KEY_IN: u8 = 1 << 4;
    pub const TX_INHIBIT: u8 = 1 << 5;
    pub const OVER_TEMP: u8 = 1 << 6;
    pub const TRIP: u8 = 1 << 7;
}

/// Free-running link counters, as read.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LinkCounters {
    pub raw_frames: u32,
    pub other_frames: u32,
    pub crc_errors: u32,
    pub gaps: u32,
    pub gap_samples: u32,
    pub resyncs: u32,
    pub ring_frames: u16,
    pub ring_dropped: u16,
    pub tx_inserted: u16,
    pub tx_skipped: u16,
}

/// Loss accounting of the raw stream from the HL2 on SFP cage 0 (docs/HL2_SFP.md section 6). All
/// of them run freely from the receive reset of the link, and the 16-bit ones stop at 0xFFFF. The
/// requirement is that `seq_lost` stays 0, and with it every other field except `seq_restarts`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LossCounters {
    /// Raw frames missing by the HL2's sequence number (lost before the commit, for whatever reason).
    pub seq_lost: u32,
    /// Sequence number of the newest committed raw frame.
    pub last_seq: u32,
    /// The sequence went back or the HL2 started again (flag 4): counting started over.
    pub seq_restarts: u16,
    /// Frames dropped for a code error of the lane (also in [`LinkCounters::crc_errors`]).
    pub code_frames: u16,
    /// Raw frames with a good FCS but a length that is not 3N/2.
    pub len_errors: u16,
    /// Raw frames that say the HL2 itself lost samples before them (its FIFO overflowed).
    pub hl2_missing: u16,
    /// Committed frames not drained (the previous one was still draining).
    pub drain_drops: u16,
    /// Samples written over before they were drained.
    pub overruns: u16,
    /// Frame indices lost (index FIFO full).
    pub idx_drops: u16,
    /// The HL2's own overflow count from its newest header.
    pub hl2_ovf: u16,
}

impl LossCounters {
    /// Nothing lost on our side: the line, the module and the receive chain (`hl2_missing` and `hl2_ovf` are the
    /// HL2's own).
    pub fn none_lost(&self) -> bool {
        self.seq_lost == 0 && self.len_errors == 0 && self.drain_drops == 0 && self.overruns == 0 && self.idx_drops == 0
    }
}

/// Driver for the HL2 link page.
pub struct Hl2Link<'a, R: RegisterSpace> {
    regs: &'a R,
}

impl<'a, R: RegisterSpace> Hl2Link<'a, R> {
    pub fn new(regs: &'a R) -> Self {
        Hl2Link { regs }
    }

    /// The identification register of the block.
    pub fn id(&self) -> u32 {
        link::id::read(self.regs)
    }

    /// Our end: MAC, IPv4 address (host order, 10.99.0.1 = 0x0A63_0001) and the UDP source port of
    /// TX sample frames.
    pub fn set_our_address(&self, mac: [u8; 6], ip: u32, tx_port: u16) {
        link::our_mac_hi::write(self.regs, u16::from_be_bytes([mac[0], mac[1]]) as u32);
        link::our_mac_lo::write(self.regs, u32::from_be_bytes([mac[2], mac[3], mac[4], mac[5]]));
        link::our_ip::write(self.regs, ip);
        link::our_port::write(self.regs, tx_port as u32);
    }

    /// The HL2's MAC and IP, from its discovery reply. The raw-frame classifier matches on the IP,
    /// so no sample arrives before this is written.
    pub fn set_hl2_address(&self, mac: [u8; 6], ip: u32) {
        link::hl2_mac_hi::write(self.regs, u16::from_be_bytes([mac[0], mac[1]]) as u32);
        link::hl2_mac_lo::write(self.regs, u32::from_be_bytes([mac[2], mac[3], mac[4], mac[5]]));
        link::hl2_ip::write(self.regs, ip);
    }

    /// Classifier and raw-frame parser on or off.
    pub fn set_rx_enable(&self, on: bool) {
        link::ctrl::modify(self.regs, |v| v.with_rx_enable(on));
    }

    /// Raw sample frames are arriving and passing their CRC.
    pub fn streaming(&self) -> bool {
        link::status::read(self.regs).streaming()
    }

    /// The safety byte of the newest raw frame ([`safety`]).
    pub fn safety_byte(&self) -> u8 {
        link::safety_byte::read(self.regs).value() as u8
    }

    /// True if the safety byte changed since this was last called.
    pub fn take_safety_changed(&self) -> bool {
        let c = link::safety_byte::read(self.regs).changed();
        if c {
            link::safety_byte::clear_changed(self.regs);
        }
        c
    }

    /// HL2 sample index of the next expected ADC sample (48 bit, 76.8 Msps): the radio's own time.
    pub fn sample_index(&self) -> u64 {
        // Reading the low word latches the high word.
        let lo = link::sample_index_lo::read(self.regs) as u64;
        let hi = link::sample_index_hi::read(self.regs) as u64 & 0xFFFF;
        (hi << 32) | lo
    }

    /// The HL2's TX FIFO fill as it reports it (target 12,000 of 16,384).
    pub fn tx_fifo_fill(&self) -> u32 {
        link::tx_fifo_fill::read(self.regs)
    }

    /// The loss counters ([`LossCounters`]).
    pub fn loss(&self) -> LossCounters {
        let a = link::loss_a::read(self.regs);
        let b = link::loss_b::read(self.regs);
        let c = link::loss_c::read(self.regs);
        let d = link::loss_d::read(self.regs);
        LossCounters {
            seq_lost: link::seq_lost::read(self.regs),
            last_seq: link::rx_seq::read(self.regs),
            seq_restarts: a.seq_restarts() as u16,
            code_frames: a.code_frames() as u16,
            len_errors: b.len_errors() as u16,
            hl2_missing: b.hl2_missing() as u16,
            drain_drops: c.drain_drops() as u16,
            overruns: c.overruns() as u16,
            idx_drops: d.idx_drops() as u16,
            hl2_ovf: d.hl2_ovf() as u16,
        }
    }

    /// Reads the loss counters.
    pub fn counters(&self) -> LinkCounters {
        let ring = link::ring_frames::read(self.regs);
        let txc = link::tx_counts::read(self.regs);
        LinkCounters {
            raw_frames: link::raw_frame_count::read(self.regs),
            other_frames: link::other_frame_count::read(self.regs),
            crc_errors: link::crc_error_count::read(self.regs),
            gaps: link::gap_count::read(self.regs),
            gap_samples: link::gap_sample_count::read(self.regs),
            resyncs: link::resync_count::read(self.regs),
            ring_frames: ring.committed() as u16,
            ring_dropped: ring.dropped() as u16,
            tx_inserted: txc.inserted() as u16,
            tx_skipped: txc.skipped() as u16,
        }
    }
}

const RING_BYTES: u32 = 4_096;
/// Longest Ethernet frame without FCS.
pub const MTU: usize = 1_514;
/// Shortest frame the MAC is given (shorter ones are padded with zeros).
const MIN_FRAME: usize = 60;

/// The HL2 link's CPU packet path.
pub struct Hl2Packets<'a, R: RegisterSpace> {
    regs: &'a R,
    /// Byte offset of the next unread frame in the receive ring.
    cursor: u32,
    /// Times the reader had to drop the ring's contents and start again.
    pub resyncs: u32,
}

impl<'a, R: RegisterSpace> Hl2Packets<'a, R> {
    /// Starts reading at the current write pointer (frames already in the ring are skipped).
    pub fn new(regs: &'a R) -> Self {
        Hl2Packets { regs, cursor: link::ring_wptr::read(regs) & (RING_BYTES - 1), resyncs: 0 }
    }

    fn ring_byte(&self, offset: u32, cache: &mut (u32, u32)) -> u8 {
        let o = offset & (RING_BYTES - 1);
        if cache.0 != o / 4 {
            *cache = (o / 4, pkt::rx_ring::read(self.regs, o / 4));
        }
        (cache.1 >> (8 * (o % 4))) as u8
    }
}

impl<R: RegisterSpace> MacRings for Hl2Packets<'_, R> {
    const MTU: usize = MTU;

    fn can_transmit(&mut self) -> bool {
        !pkt::tx_status::read(self.regs).busy()
    }

    fn transmit(&mut self, frame: &[u8]) -> bool {
        if frame.len() > MTU || !self.can_transmit() {
            return false;
        }
        let len = frame.len().max(MIN_FRAME);
        for w in 0..len.div_ceil(4) {
            let mut v = 0u32;
            for k in 0..4 {
                v |= (frame.get(4 * w + k).copied().unwrap_or(0) as u32) << (8 * k);
            }
            pkt::tx_queue::write(self.regs, w as u32, v);
        }
        pkt::tx_send::write(self.regs, pkt::tx_send::Value(0).with_length(len as u32));
        true
    }

    fn receive(&mut self, buf: &mut [u8]) -> Option<usize> {
        let wptr = link::ring_wptr::read(self.regs) & (RING_BYTES - 1);
        if wptr == self.cursor {
            return None;
        }
        let mut cache = (u32::MAX, 0);
        let len = (self.ring_byte(self.cursor, &mut cache) as usize) << 8 | self.ring_byte(self.cursor + 1, &mut cache) as usize;
        let span = (2 + len as u32 + 1) & !1;
        let available = wptr.wrapping_sub(self.cursor) & (RING_BYTES - 1);
        if len == 0 || len > MTU || span > available {
            self.cursor = wptr;
            self.resyncs += 1;
            return None;
        }
        let n = len.min(buf.len());
        for (i, b) in buf[..n].iter_mut().enumerate() {
            *b = self.ring_byte(self.cursor + 2 + i as u32, &mut cache);
        }
        self.cursor = (self.cursor + span) & (RING_BYTES - 1);
        Some(n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mock::MockFabric;
    use alloc::vec::Vec;

    /// Puts `frame` into the mock's receive ring at byte offset `at` the way the logic does and
    /// returns the new write pointer.
    fn put_frame(f: &MockFabric, at: u32, frame: &[u8]) -> u32 {
        let mut bytes: Vec<u8> = Vec::new();
        bytes.extend_from_slice(&(frame.len() as u16).to_be_bytes());
        bytes.extend_from_slice(frame);
        if bytes.len() % 2 == 1 {
            bytes.push(0);
        }
        for (i, b) in bytes.iter().enumerate() {
            let o = (at + i as u32) % RING_BYTES;
            let a = pkt::rx_ring::addr(o / 4);
            let sh = 8 * (o % 4);
            f.poke(a, (f.reg(a) & !(0xFF << sh)) | ((*b as u32) << sh));
        }
        let w = (at + bytes.len() as u32) % RING_BYTES;
        f.poke(link::ring_wptr::addr(), w);
        w
    }

    #[test]
    fn loss_counters_are_read_from_their_fields() {
        let m = MockFabric::new();
        let l = Hl2Link::new(&m);
        m.poke(link::seq_lost::addr(), 7);
        m.poke(link::rx_seq::addr(), 1234);
        m.poke(link::loss_a::addr(), 0x0002_0001);
        m.poke(link::loss_b::addr(), 0x0004_0003);
        m.poke(link::loss_c::addr(), 0x0006_0005);
        m.poke(link::loss_d::addr(), 0x0008_0007);
        let c = l.loss();
        assert_eq!((c.seq_lost, c.last_seq, c.seq_restarts, c.code_frames), (7, 1234, 1, 2));
        assert_eq!((c.len_errors, c.hl2_missing, c.drain_drops, c.overruns, c.idx_drops, c.hl2_ovf), (3, 4, 5, 6, 7, 8));
        assert!(!c.none_lost());
        assert!(LossCounters { seq_restarts: 3, hl2_missing: 1, ..LossCounters::default() }.none_lost());
    }

    #[test]
    fn addresses_and_status() {
        let f = MockFabric::new();
        let l = Hl2Link::new(&f);
        l.set_our_address([0x02, 0x54, 0x52, 0x00, 0x00, 0x01], 0x0A63_0001, 51_000);
        l.set_hl2_address([0x00, 0x1C, 0xC0, 0xA2, 0x13, 0xDD], 0x0A63_0002);
        assert_eq!(f.reg(link::our_mac_hi::addr()), 0x0254);
        assert_eq!(f.reg(link::our_mac_lo::addr()), 0x5200_0001);
        assert_eq!(f.reg(link::hl2_mac_lo::addr()), 0xC0A2_13DD);
        assert_eq!(f.reg(link::hl2_ip::addr()), 0x0A63_0002);
        f.poke(link::ctrl::addr(), 2);
        l.set_rx_enable(true);
        assert_eq!(f.reg(link::ctrl::addr()), 3);
        f.poke(link::safety_byte::addr(), 0x100 | safety::TRIP as u32 | safety::TX_FORCED_OFF as u32);
        assert_eq!(l.safety_byte(), 0x81);
        assert!(l.take_safety_changed());
        f.poke(link::sample_index_lo::addr(), 0xFFFF_FFF0);
        f.poke(link::sample_index_hi::addr(), 0x12);
        assert_eq!(l.sample_index(), 0x12_FFFF_FFF0);
        f.poke(link::ring_frames::addr(), (2 << 16) | 40);
        let c = l.counters();
        assert_eq!((c.ring_frames, c.ring_dropped), (40, 2));
    }

    #[test]
    fn never_touches_the_tx_framer() {
        let f = MockFabric::new();
        let l = Hl2Link::new(&f);
        l.set_our_address([0; 6], 1, 2);
        l.set_hl2_address([0; 6], 3);
        l.set_rx_enable(true);
        let mut p = Hl2Packets::new(&f);
        p.transmit(&[0xFF; 64]);
        assert!(f.reg_writes(link::tx_ctrl::addr()).is_empty());
    }

    #[test]
    fn receive_frames_including_one_across_the_ring_end() {
        let f = MockFabric::new();
        f.poke(link::ring_wptr::addr(), 4_000);
        let mut p = Hl2Packets::new(&f);
        let mut buf = [0u8; MTU];
        assert_eq!(p.receive(&mut buf), None);
        let a: Vec<u8> = (0..61u8).collect(); // odd length: padded in the ring
        let b: Vec<u8> = (100..200u8).collect(); // wraps: starts at 4,064
        let w = put_frame(&f, 4_000, &a);
        assert_eq!(w, 4_064);
        put_frame(&f, w, &b);
        assert_eq!(p.receive(&mut buf), Some(61));
        assert_eq!(&buf[..61], &a[..]);
        assert_eq!(p.receive(&mut buf), Some(100));
        assert_eq!(&buf[..100], &b[..]);
        assert_eq!(p.receive(&mut buf), None);
        assert_eq!(p.resyncs, 0);
    }

    #[test]
    fn a_nonsense_length_resyncs_instead_of_reading_garbage() {
        let f = MockFabric::new();
        let mut p = Hl2Packets::new(&f);
        f.poke(pkt::rx_ring::addr(0), 0x0000_FFFF); // length 0xFFFF
        f.poke(link::ring_wptr::addr(), 200);
        let mut buf = [0u8; MTU];
        assert_eq!(p.receive(&mut buf), None);
        assert_eq!(p.resyncs, 1);
        let w = put_frame(&f, 200, &[9; 64]);
        assert_eq!(w, 266);
        assert_eq!(p.receive(&mut buf), Some(64));
    }

    #[test]
    fn transmit_packs_little_endian_words_pads_and_respects_busy() {
        let f = MockFabric::new();
        let mut p = Hl2Packets::new(&f);
        let frame: Vec<u8> = (1..=42u8).collect();
        assert!(p.transmit(&frame));
        assert_eq!(f.reg(pkt::tx_queue::addr(0)), 0x0403_0201);
        assert_eq!(f.reg(pkt::tx_queue::addr(10)), 0x0000_2A29);
        assert_eq!(f.reg(pkt::tx_send::addr()), 60, "padded to the Ethernet minimum");
        f.poke(pkt::tx_status::addr(), 1);
        f.clear_log();
        assert!(!p.transmit(&frame));
        assert!(f.log.borrow().is_empty());
        f.poke(pkt::tx_status::addr(), 0);
        assert!(!p.transmit(&[0u8; MTU + 1]));
    }
}
