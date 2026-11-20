// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! A recorded run of the fixed-point fabric, replayed to the CPU half without the models: this
//! is how the CPU part of the decoder runs alone under QEMU for its instruction count.
//!
//! Format, all little-endian: `b"S15T"` (the front end model), u32 version (3), the decode
//! parameters (f32 freq_min, freq_max, sync_min, u32 max_cand, u32 passes, u32 osd_max, then the
//! effort as 14 u32: q_min, bp, llr_effort (0 minimal, 1 full), bp_max_iter, osd_variants,
//! osd_seeds, osd_npre2, ap_blind_cq, ap_blind_cq_q_min, ap_bp, ap_osd, ap_variants, osd_packed,
//! ap_min_sum), 180,000 i16 audio, u32 event count, then per event a u32 tag and its payload:
//! 1 = sync (u32 ia, u32 ib, u32 n, n x 8 u32), 2 = baseband (u32 slot, u32 inc, 3,200 x 2 i32),
//! 3 = symbols (u32 slot, u32 rinc, i32 i0, 632 x 2 i32).

use alloc::boxed::Box;
use alloc::vec::Vec;

use num_complex::Complex;

use super::decode::{baseband_from_words, bins_from_words, cs_from_words, Cs, DecodeParams, Event, Fabric, Recording};
use mfsk_core::engine::pipeline::LlrEffort;
use mfsk_core::ft8::decode_block::Ft8Effort;
use super::sync::{BinSync, SyncBand};
use super::{BB_LEN, NN, NTONES, SLOT_LEN};

/// First four bytes of a trace file.
const MAGIC: &[u8; 4] = b"S15T";

/// Appends `x` little-endian.
fn put_u32(v: &mut Vec<u8>, x: u32) {
    v.extend_from_slice(&x.to_le_bytes());
}

/// Serializes a recording with its audio and parameters into the trace format.
pub fn write_trace(audio: &[i16], p: &DecodeParams, rec: &Recording) -> Vec<u8> {
    let mut v = Vec::new();
    v.extend_from_slice(MAGIC);
    put_u32(&mut v, 3);
    put_u32(&mut v, p.freq_min.to_bits());
    put_u32(&mut v, p.freq_max.to_bits());
    put_u32(&mut v, p.sync_min.to_bits());
    put_u32(&mut v, p.max_cand as u32);
    put_u32(&mut v, p.passes as u32);
    put_u32(&mut v, p.osd_max.min(u32::MAX as usize) as u32);
    let e = &p.effort;
    for x in [
        e.q_min,
        e.bp as u32,
        (e.llr_effort == LlrEffort::Full) as u32,
        e.bp_max_iter,
        e.osd_variants as u32,
        e.osd_seeds as u32,
        e.osd_npre2 as u32,
        e.ap_blind_cq as u32,
        e.ap_blind_cq_q_min,
        e.ap_bp as u32,
        e.ap_osd as u32,
        e.ap_variants as u32,
        e.osd_packed as u32,
        e.ap_min_sum as u32,
    ] {
        put_u32(&mut v, x);
    }
    for i in 0..SLOT_LEN {
        v.extend_from_slice(&audio.get(i).copied().unwrap_or(0).to_le_bytes());
    }
    put_u32(&mut v, rec.events.len() as u32);
    for e in &rec.events {
        match e {
            Event::Sync { band, words } => {
                put_u32(&mut v, 1);
                put_u32(&mut v, band.ia as u32);
                put_u32(&mut v, band.ib as u32);
                put_u32(&mut v, words.len() as u32);
                for w in words {
                    for &x in w {
                        put_u32(&mut v, x);
                    }
                }
            }
            Event::Baseband { slot, inc, words } => {
                put_u32(&mut v, 2);
                put_u32(&mut v, *slot);
                put_u32(&mut v, *inc);
                for &(r, i) in words {
                    put_u32(&mut v, r as u32);
                    put_u32(&mut v, i as u32);
                }
            }
            Event::Symbols { slot, rinc, i0, words } => {
                put_u32(&mut v, 3);
                put_u32(&mut v, *slot);
                put_u32(&mut v, *rinc);
                put_u32(&mut v, *i0 as u32);
                for &(r, i) in words {
                    put_u32(&mut v, r as u32);
                    put_u32(&mut v, i as u32);
                }
            }
        }
    }
    v
}

/// Replays a trace: the header is read by [`TraceFabric::open`]; every fabric call must match
/// the recorded request exactly, or the replay stops with a panic ("trace diverged").
pub struct TraceFabric<'a> {
    data: &'a [u8],
    pos: usize,
    events_left: u32,
}

impl<'a> TraceFabric<'a> {
    /// Reads the next little-endian u32.
    fn u32(&mut self) -> u32 {
        let b = &self.data[self.pos..self.pos + 4];
        self.pos += 4;
        u32::from_le_bytes([b[0], b[1], b[2], b[3]])
    }

    /// Parses the header and returns the fabric, the slot audio and the recorded parameters.
    pub fn open(data: &'a [u8]) -> (Self, Vec<i16>, DecodeParams) {
        assert!(data.len() > 40 && &data[0..4] == MAGIC, "not an S15 trace");
        let mut f = TraceFabric { data, pos: 4, events_left: 0 };
        assert_eq!(f.u32(), 3, "trace version");
        let mut p = DecodeParams::default();
        p.freq_min = f32::from_bits(f.u32());
        p.freq_max = f32::from_bits(f.u32());
        p.sync_min = f32::from_bits(f.u32());
        p.max_cand = f.u32() as usize;
        p.passes = f.u32() as usize;
        p.osd_max = match f.u32() {
            u32::MAX => usize::MAX,
            n => n as usize,
        };
        let e: [u32; 14] = core::array::from_fn(|_| f.u32());
        p.effort = Ft8Effort {
            q_min: e[0],
            bp: e[1] != 0,
            llr_effort: if e[2] != 0 { LlrEffort::Full } else { LlrEffort::Minimal },
            bp_max_iter: e[3],
            osd_variants: e[4] as u8,
            osd_seeds: e[5] as u8,
            osd_npre2: e[6] != 0,
            ap_blind_cq: e[7] != 0,
            ap_blind_cq_q_min: e[8],
            ap_bp: e[9] != 0,
            ap_osd: e[10] != 0,
            ap_variants: e[11] as u8,
            osd_packed: e[12] != 0,
            ap_min_sum: e[13] != 0,
            ..Ft8Effort::FULL
        };
        let mut audio = Vec::with_capacity(SLOT_LEN);
        for _ in 0..SLOT_LEN {
            let b = &f.data[f.pos..f.pos + 2];
            audio.push(i16::from_le_bytes([b[0], b[1]]));
            f.pos += 2;
        }
        f.events_left = f.u32();
        (f, audio, p)
    }

    /// Consumes the next event tag and panics if it is not `tag`.
    fn expect(&mut self, tag: u32) {
        assert!(self.events_left > 0, "trace diverged: no more events");
        self.events_left -= 1;
        let t = self.u32();
        assert_eq!(t, tag, "trace diverged: event tag");
    }

    /// Reads `n` (re, im) word pairs.
    fn pairs(&mut self, n: usize) -> Vec<(i32, i32)> {
        (0..n).map(|_| (self.u32() as i32, self.u32() as i32)).collect()
    }
}

impl Fabric for TraceFabric<'_> {
    fn sync(&mut self, _audio: &[i16], band: SyncBand) -> Vec<BinSync> {
        self.expect(1);
        let (ia, ib) = (self.u32() as usize, self.u32() as usize);
        assert!(ia == band.ia && ib == band.ib, "trace diverged: sync band");
        let n = self.u32() as usize;
        let words: Vec<[u32; 8]> = (0..n).map(|_| core::array::from_fn(|_| self.u32())).collect();
        bins_from_words(&words)
    }

    fn baseband(&mut self, _audio: &[i16], slot: usize, inc: u32) -> Vec<Complex<f32>> {
        self.expect(2);
        assert_eq!(self.u32() as usize, slot, "trace diverged: baseband slot");
        assert_eq!(self.u32(), inc, "trace diverged: NCO increment");
        let w = self.pairs(BB_LEN);
        baseband_from_words(&w)
    }

    fn symbols(&mut self, slot: usize, rinc: u32, i0: i32) -> Box<Cs> {
        self.expect(3);
        assert_eq!(self.u32() as usize, slot, "trace diverged: symbols slot");
        assert_eq!(self.u32(), rinc, "trace diverged: rotation increment");
        assert_eq!(self.u32() as i32, i0, "trace diverged: start sample");
        let w = self.pairs(NN * NTONES);
        cs_from_words(&w)
    }
}
