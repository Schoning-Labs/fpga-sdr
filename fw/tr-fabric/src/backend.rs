// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Receiver back end (`hw/regmap/rx_backend.toml`, docs/R4_BACKEND.md): channel filter banks, the
//! per-receiver mode word, S-meter, and the output ring in DDR3 that carries the 12 ksps audio the
//! FT8 decoder reads.
//!
//! Output ring (R4_BACKEND 3.10), per receiver: blocks of 128 samples; block `s` starts at lane
//! word `ring_base + s * 34` (`s` modulo `2^log2`): two 64-bit header words, then 32 words of four
//! 16-bit samples, sample `j` of a word in bits `16j+15 .. 16j` (to the CPU: a plain array of
//! `i16`). Header word 0: bits 47..0 the HL2 sample index of the block's first sample; word 1:
//! bits 31..0 the block number, 47..32 the S-meter. `ring_wptr` counts whole blocks. The logic
//! does not wait for the reader.

use tr_regs::generated::rx_backend as bk;
use tr_regs::RegisterSpace;

use crate::mem::FabricMem;
use crate::rxbank::Rate;

/// Samples per ring block.
pub const BLOCK_SAMPLES: usize = 128;
/// Bytes per ring block of a 12 or 24 ksps real output (34 lane words).
pub const BLOCK_BYTES: u32 = 34 * 8;
/// HL2 samples per 12 ksps output sample.
pub const HL2_PER_SAMPLE_12K: u64 = 6_400;

/// Demodulator of a back-end receiver.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Demod {
    /// SSB, CW and data: the real part after the channel filter (the filter picks the sideband).
    Ssb = 0,
    Am = 1,
    Sam = 2,
    Fm = 3,
}

/// Per-receiver settings written by [`Backend::start`].
#[derive(Clone, Copy, Debug)]
pub struct RxSetup {
    pub demod: Demod,
    /// Must be the bank receiver's rate.
    pub in_rate: Rate,
    pub agc: bool,
    /// Coefficient bank 0-5 of the receiver's filter unit (unit 0: receivers 0-3, unit 1: 4-7).
    pub bank: u32,
}

/// One block read from a ring.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BlockHeader {
    /// HL2 sample index of the block's first sample (48 bit), filter delays not removed.
    pub stamp: u64,
    /// Block number since the ring was enabled.
    pub seq: u32,
    /// S-meter in 1/64 dB relative to an envelope of 2^23.
    pub smeter_db64: i16,
}

/// Driver for the receiver back end page.
pub struct Backend<'a, R: RegisterSpace> {
    regs: &'a R,
}

impl<'a, R: RegisterSpace> Backend<'a, R> {
    /// A driver on the register space `regs`.
    pub fn new(regs: &'a R) -> Self {
        Backend { regs }
    }

    /// The identification register of the block.
    pub fn id(&self) -> u32 {
        bk::id::read(self.regs)
    }

    /// Writes a channel filter into bank `bank` (0-5) of filter unit `unit` (0-1): complex taps
    /// with value `c * 2^-(30 + exp)` (`tr_dsp::backend::design::quantize`). Refuses (returns
    /// false, writes nothing) while a running receiver of that unit uses the bank.
    pub fn load_bank(&self, unit: u32, bank: u32, re: &[i32], im: &[i32], exp: u8) -> bool {
        assert!(unit < 2 && bank < 6 && !re.is_empty() && re.len() <= 1_024 && re.len() == im.len());
        for rx in unit * 4..unit * 4 + 4 {
            if bk::ctrl::read(self.regs, rx).enable() && bk::rx_status::read(self.regs, rx).bank_cur() == bank {
                return false;
            }
        }
        bk::coef_sel::write(self.regs, bk::coef_sel::Value(0).with_unit(unit != 0).with_bank(bank));
        for n in 0..re.len() {
            bk::coef::write(self.regs, 2 * n as u32, re[n] as u32);
            bk::coef::write(self.regs, 2 * n as u32 + 1, im[n] as u32);
        }
        bk::bank_cfg::write(self.regs, unit * 6 + bank, bk::bank_cfg::Value(0).with_ntaps(re.len() as u32).with_exp(exp as u32));
        true
    }

    /// (Re)starts receiver `rx` with a 12 ksps output: disabled first, so every stage restarts and
    /// the stamp base is latched again. Call after the bank receiver was started or re-tuned in rate.
    pub fn start(&self, rx: u32, s: &RxSetup) {
        let v = bk::ctrl::Value(bk::ctrl::RESET)
            .with_enable(false)
            .with_mode(s.demod as u32)
            .with_out24(false)
            .with_in_rate(s.in_rate as u32)
            .with_agc_en(s.agc)
            .with_bank_sel(s.bank);
        bk::ctrl::write(self.regs, rx, v);
        bk::ctrl::write(self.regs, rx, v.with_enable(true));
    }

    /// Disables receiver `rx`.
    pub fn stop(&self, rx: u32) {
        bk::ctrl::modify(self.regs, rx, |v| v.with_enable(false));
    }

    /// Switches running receiver `rx` to coefficient bank `bank` (R4_BACKEND 3.3): the unit takes it
    /// at the start of the next output sample, without a restart. [`Backend::bank_in_use`] tells
    /// when the old bank is free again.
    pub fn select_bank(&self, rx: u32, bank: u32) {
        bk::ctrl::modify(self.regs, rx, |v| v.with_bank_sel(bank));
    }

    /// The bank receiver `rx`'s filter is using now (`bank_cur`).
    pub fn bank_in_use(&self, rx: u32) -> u32 {
        bk::rx_status::read(self.regs, rx).bank_cur()
    }

    /// AGC on or off while running (no restart); off applies the fixed gain of
    /// [`Backend::set_manual_gain`].
    pub fn set_agc(&self, rx: u32, on: bool) {
        bk::ctrl::modify(self.regs, rx, |v| v.with_agc_en(on));
    }

    /// Squelch on the S-meter level (R4_BACKEND 3.6), any mode: opens above `open_db64`, closes
    /// below `close_db64` (1/64 dB relative to an envelope of 2^23). No restart.
    pub fn set_squelch(&self, rx: u32, on: bool, open_db64: i16, close_db64: i16) {
        bk::squelch::write(self.regs, rx, bk::squelch::Value(0).with_open(open_db64 as u16 as u32).with_close(close_db64 as u16 as u32));
        bk::ctrl::modify(self.regs, rx, |v| v.with_sq_en(on));
    }

    /// True while the squelch lets the audio through.
    pub fn squelch_open(&self, rx: u32) -> bool {
        bk::rx_status::read(self.regs, rx).sq_open()
    }

    /// FM de-emphasis `alpha` (U0.17, 0 = off), R4_BACKEND 3.4.
    pub fn set_fm_deemphasis(&self, rx: u32, alpha: u32) {
        bk::fm_deemph::write(self.regs, rx, bk::fm_deemph::Value(0).with_alpha(alpha & 0x1_FFFF));
    }

    /// Gain the AGC applied to the last sample, log2 S.10 (the register is 18 bits, sign-extended).
    pub fn agc_gain_s10(&self, rx: u32) -> i32 {
        let v = bk::agc_gain::read(self.regs, rx) & 0x3_FFFF;
        ((v << 14) as i32) >> 14
    }

    /// Fixed gain used with the AGC off, log2 in S7.12.
    pub fn set_manual_gain(&self, rx: u32, gain_s7_12: i32) {
        bk::agc_manual::write(self.regs, rx, bk::agc_manual::Value(0).with_gain(gain_s7_12 as u32 & 0xF_FFFF));
    }

    /// S-meter in 1/64 dB relative to an envelope of 2^23.
    pub fn smeter_db64(&self, rx: u32) -> i16 {
        bk::rx_status::read(self.regs, rx).smeter() as u16 as i16
    }

    /// HL2 sample index latched at the receiver's first sample after enable.
    pub fn stamp_base(&self, rx: u32) -> u64 {
        let lo = bk::stamp_base_lo::read(self.regs, rx) as u64;
        let hi = bk::stamp_base_hi::read(self.regs, rx) as u64 & 0xFFFF;
        (hi << 32) | lo
    }

    /// Sticky "a sample was lost" flags (front, decimator, filter, ring); reads and clears them.
    pub fn take_overflows(&self) -> u32 {
        let v = bk::status::read(self.regs).0 & 0xF;
        if v != 0 {
            self.regs.write32(bk::status::addr(), v);
        }
        v
    }

    /// Starts receiver `rx`'s output ring at `addr` (CPU byte address, a multiple of 8) with
    /// `2^log2` blocks and returns its reader.
    pub fn open_ring(&self, rx: u32, addr: u32, log2: u32) -> BackendRing {
        assert!(log2 <= 15 && addr % 8 == 0);
        bk::ring_ctrl::write(self.regs, rx, bk::ring_ctrl::Value(0).with_enable(false));
        bk::ring_base::write(self.regs, rx, addr / 8);
        bk::ring_slots::write(self.regs, rx, bk::ring_slots::Value(0).with_log2(log2));
        bk::ring_ctrl::write(self.regs, rx, bk::ring_ctrl::Value(0).with_enable(true));
        BackendRing { rx, addr, blocks: 1 << log2, next: 0, lost: 0 }
    }
}

/// Reader of one receiver's output ring.
pub struct BackendRing {
    rx: u32,
    addr: u32,
    blocks: u32,
    /// Next block number to hand out.
    next: u32,
    /// Blocks the logic overwrote before they were read.
    pub lost: u32,
}

impl BackendRing {
    /// The receiver this ring belongs to.
    pub fn rx(&self) -> u32 {
        self.rx
    }

    /// Hands every block written since the last call to `f`, oldest first, and returns how many.
    /// If the logic lapped the reader, the overwritten blocks are counted in `lost` and reading
    /// resumes with the oldest block that is still whole (one block of margin).
    pub fn poll<R: RegisterSpace, M: FabricMem>(&mut self, regs: &R, mem: &M, f: impl FnMut(&BlockHeader, &[i16; BLOCK_SAMPLES])) -> u32 {
        self.poll_max(regs, mem, u32::MAX, f)
    }

    /// Blocks written and not read yet (lapped blocks counted in `lost` and passed over, as in
    /// [`BackendRing::poll`]).
    pub fn pending<R: RegisterSpace>(&mut self, regs: &R) -> u32 {
        let wptr = bk::ring_wptr::read(regs, self.rx);
        let pending = wptr.wrapping_sub(self.next);
        if pending > self.blocks - 1 {
            let skip = pending - (self.blocks - 1);
            self.lost = self.lost.wrapping_add(skip);
            self.next = self.next.wrapping_add(skip);
            return self.blocks - 1;
        }
        pending
    }

    /// Passes over the oldest `n` unread blocks (at most what is pending); returns how many.
    pub fn skip<R: RegisterSpace>(&mut self, regs: &R, n: u32) -> u32 {
        let n = n.min(self.pending(regs));
        self.next = self.next.wrapping_add(n);
        n
    }

    /// [`BackendRing::poll`] for at most `max` blocks (the oldest); the rest stay for the next call.
    pub fn poll_max<R: RegisterSpace, M: FabricMem>(&mut self, regs: &R, mem: &M, max: u32, mut f: impl FnMut(&BlockHeader, &[i16; BLOCK_SAMPLES])) -> u32 {
        let pending = self.pending(regs).min(max);
        let mut samples = [0i16; BLOCK_SAMPLES];
        for _ in 0..pending {
            let a = self.addr + (self.next & (self.blocks - 1)) * BLOCK_BYTES;
            mem.invalidate(a, BLOCK_BYTES);
            let h0 = mem.read32(a) as u64 | (mem.read32(a + 4) as u64) << 32;
            let h1 = mem.read32(a + 8) as u64 | (mem.read32(a + 12) as u64) << 32;
            for k in 0..BLOCK_SAMPLES / 2 {
                let w = mem.read32(a + 16 + 4 * k as u32);
                samples[2 * k] = w as u16 as i16;
                samples[2 * k + 1] = (w >> 16) as u16 as i16;
            }
            let hdr = BlockHeader { stamp: h0 & 0xFFFF_FFFF_FFFF, seq: h1 as u32, smeter_db64: (h1 >> 32) as u16 as i16 };
            f(&hdr, &samples);
            self.next = self.next.wrapping_add(1);
        }
        pending
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mem::map::backend_ring;
    use crate::mock::{Ev, MockFabric};
    use alloc::vec::Vec;

    fn put_block(f: &MockFabric, addr: u32, blocks: u32, seq: u32, stamp: u64) {
        let a = addr + (seq % blocks) * BLOCK_BYTES;
        f.poke_mem(a, stamp as u32);
        f.poke_mem(a + 4, (stamp >> 32) as u32);
        f.poke_mem(a + 8, seq);
        f.poke_mem(a + 12, 0xFFC0); // S-meter -64 = -1 dB
        for k in 0..64u32 {
            let s0 = (seq * 128 + 2 * k) as u16 as u32;
            let s1 = (seq * 128 + 2 * k + 1) as u16 as u32;
            f.poke_mem(a + 16 + 4 * k, s0 | (s1 << 16));
        }
    }

    #[test]
    fn bank_and_receiver_setup() {
        let f = MockFabric::new();
        let b = Backend::new(&f);
        assert!(b.load_bank(1, 2, &[1, -2, 3], &[4, 5, -6], 3));
        assert_eq!(f.reg(bk::coef_sel::addr()), 1 | (2 << 1));
        assert_eq!(f.reg(bk::coef::addr(2)), -2i32 as u32);
        assert_eq!(f.reg(bk::coef::addr(5)), -6i32 as u32);
        assert_eq!(f.reg(bk::bank_cfg::addr(8)), 3 | (3 << 12));
        b.start(5, &RxSetup { demod: Demod::Ssb, in_rate: Rate::K48, agc: true, bank: 2 });
        // enable, mode 0, 12 ksps, 48 ksps in, in_shift 6, AGC on, bank 2
        assert_eq!(f.reg(bk::ctrl::addr(5)), 1 | (6 << 7) | (1 << 11) | (2 << 13));
        assert_eq!(f.reg_writes(bk::ctrl::addr(5)).len(), 2, "disabled first, then enabled");
        // The bank is in use by a running receiver of unit 1: a rewrite is refused.
        f.poke(bk::rx_status::addr(5), 2 << 17);
        f.clear_log();
        assert!(!b.load_bank(1, 2, &[1], &[0], 0));
        assert!(f.log.borrow().is_empty());
        assert!(b.load_bank(0, 2, &[1], &[0], 0), "the other unit's bank 2 is free");
    }

    #[test]
    fn ring_reader_reads_blocks_in_order_and_invalidates_first() {
        let f = MockFabric::new();
        let b = Backend::new(&f);
        let addr = backend_ring(0);
        let mut ring = b.open_ring(0, addr, 4);
        assert_eq!(f.reg(bk::ring_base::addr(0)), addr / 8);
        assert_eq!(f.reg(bk::ring_ctrl::addr(0)), 1);
        for s in 0..3 {
            put_block(&f, addr, 16, s, 1_000_000 + s as u64 * 128 * HL2_PER_SAMPLE_12K);
        }
        f.poke(bk::ring_wptr::addr(0), 3);
        f.clear_log();
        let mut got: Vec<(BlockHeader, i16, i16)> = Vec::new();
        assert_eq!(ring.poll(&f, &f, |h, s| got.push((*h, s[0], s[127]))), 3);
        assert_eq!(got[1].0, BlockHeader { stamp: 1_000_000 + 819_200, seq: 1, smeter_db64: -64 });
        assert_eq!((got[2].1, got[2].2), (256, 383));
        assert_eq!(f.log.borrow()[0], Ev::Invalidate(addr, BLOCK_BYTES));
        assert_eq!(ring.poll(&f, &f, |_, _| panic!("nothing new")), 0);
    }

    #[test]
    fn ring_reader_counts_lost_blocks_when_lapped() {
        let f = MockFabric::new();
        let addr = backend_ring(1);
        let mut ring = Backend::new(&f).open_ring(1, addr, 2); // 4 blocks
        for s in 0..10 {
            put_block(&f, addr, 4, s, 0);
        }
        f.poke(bk::ring_wptr::addr(1), 10);
        let mut seqs = Vec::new();
        ring.poll(&f, &f, |h, _| seqs.push(h.seq));
        assert_eq!(seqs, [7, 8, 9]);
        assert_eq!(ring.lost, 7);
    }

    #[test]
    fn running_receiver_controls_and_partial_reads() {
        let f = MockFabric::new();
        let b = Backend::new(&f);
        b.start(1, &RxSetup { demod: Demod::Am, in_rate: Rate::K48, agc: true, bank: 1 });
        let before = f.reg(bk::ctrl::addr(1));
        f.clear_log();
        b.select_bank(1, 2);
        b.set_agc(1, false);
        b.set_squelch(1, true, -100 * 64, -103 * 64);
        // enable and mode kept, no disable on the way (no restart)
        assert_eq!(f.reg(bk::ctrl::addr(1)), (before & !(7 << 13) & !(1 << 11)) | (2 << 13) | (1 << 12));
        assert!(f.reg_writes(bk::ctrl::addr(1)).iter().all(|v| v & 1 == 1));
        assert_eq!(f.reg(bk::squelch::addr(1)), ((-103i16 * 64) as u16 as u32) << 16 | (-100i16 * 64) as u16 as u32);
        f.poke(bk::agc_gain::addr(1), 0x3_FC00); // -1,024 (S.10: -1 octave), 18-bit sign
        assert_eq!(b.agc_gain_s10(1), -1_024);
        f.poke(bk::rx_status::addr(1), 2 << 17 | 1 << 16);
        assert_eq!((b.bank_in_use(1), b.squelch_open(1)), (2, true));

        let addr = backend_ring(1);
        let mut ring = b.open_ring(1, addr, 3); // 8 blocks
        for s in 0..5 {
            put_block(&f, addr, 8, s, 0);
        }
        f.poke(bk::ring_wptr::addr(1), 5);
        let mut seqs = Vec::new();
        assert_eq!(ring.pending(&f), 5);
        assert_eq!(ring.poll_max(&f, &f, 2, |h, _| seqs.push(h.seq)), 2);
        assert_eq!(ring.skip(&f, 1), 1);
        assert_eq!(ring.poll(&f, &f, |h, _| seqs.push(h.seq)), 2);
        assert_eq!(seqs, [0, 1, 3, 4]);
        assert_eq!(ring.skip(&f, 5), 0);
    }

    #[test]
    fn status_reads() {
        let f = MockFabric::new();
        let b = Backend::new(&f);
        f.poke(bk::rx_status::addr(0), 0xFF00); // -256/64 = -4 dB
        f.poke(bk::stamp_base_lo::addr(0), 0x1234_5678);
        f.poke(bk::stamp_base_hi::addr(0), 0x9A);
        f.poke(bk::status::addr(), 0b1000);
        assert_eq!(b.smeter_db64(0), -256);
        assert_eq!(b.stamp_base(0), 0x9A_1234_5678);
        assert_eq!(b.take_overflows(), 8);
        assert_eq!(f.reg_writes(bk::status::addr()), [8]);
    }
}
