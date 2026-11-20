// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! A ring of 32-bit words the CPU writes and the logic reads (`rtl/audio/audio_ring_reader.v`: the
//! audio ring and the TX baseband ring). Pointers are free-running word counts, masked to the ring
//! size only to form an address.

use crate::mem::{flush_for_logic, FabricMem, Flushed};

pub(crate) struct RingCore {
    /// CPU byte address of word 0.
    pub base: u32,
    /// Ring size in words, a power of two.
    pub words: u32,
    /// Our write pointer (what the pointer register holds).
    pub wptr: u32,
}

impl RingCore {
    /// Words queued and not yet read, given the logic's read pointer.
    pub fn fill(&self, rptr: u32) -> u32 {
        self.wptr.wrapping_sub(rptr).min(self.words)
    }

    /// Words that can still be written, given the read pointer `rptr` of the logic.
    pub fn free(&self, rptr: u32) -> u32 {
        self.words - self.fill(rptr)
    }

    /// Writes as many of `data` as fit, makes them visible to the logic (write-back, bridge wait)
    /// and only then hands the new pointer to `move_ptr` together with the proof. Returns the
    /// number of words taken.
    pub fn push<M: FabricMem>(&mut self, mem: &M, rptr: u32, data: &[u32], move_ptr: impl FnOnce(u32, Flushed)) -> usize {
        let n = (data.len() as u32).min(self.free(rptr));
        if n == 0 {
            return 0;
        }
        let mask = self.words - 1;
        let start = self.wptr & mask;
        for (i, &w) in data[..n as usize].iter().enumerate() {
            mem.write32(self.base + ((start + i as u32) & mask) * 4, w);
        }
        let first = n.min(self.words - start);
        let proof = flush_for_logic(mem, &[(self.base + start * 4, first * 4), (self.base, (n - first) * 4)]);
        self.wptr = self.wptr.wrapping_add(n);
        move_ptr(self.wptr, proof);
        n as usize
    }
}
