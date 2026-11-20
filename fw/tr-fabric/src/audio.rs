// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Audio outputs (`hw/regmap/audio.toml`, docs/A1_AUDIO.md, docs/AUDIO_OUT.md): the 48 kHz stereo
//! ring the firmware writes, the PT8211 volume, and the digital outputs (S/PDIF, I2S, HDMI audio,
//! test tone) with their status.
//!
//! Ring format: 4,096 words of `{L[15:0], R[15:0]}` (left in bits 31:16), 85 ms. The fabric's read
//! pointer restarts at 0 whenever the engine is disabled.

use tr_regs::generated::audio;
use tr_regs::RegisterSpace;

use crate::mem::{FabricMem, Flushed};
use crate::ring::RingCore;

/// Size of the audio ring in words, one stereo frame per word.
pub const AUDIO_RING_WORDS: u32 = 4_096;
/// Sample rate of the audio ring in Hz.
pub const AUDIO_RATE: u32 = 48_000;

/// Packs one stereo frame into a ring word, with the left sample in bits 31:16.
pub const fn stereo_word(left: i16, right: i16) -> u32 {
    ((left as u16 as u32) << 16) | (right as u16 as u32)
}

/// `out_status` as read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct OutStatus {
    pub pll_lock: bool,
    /// S/PDIF and I2S are sending samples.
    pub run: bool,
    /// The last sample came from the audio engine (not zeros or the tone).
    pub live: bool,
    pub slips: u8,
    pub errors: u8,
}

/// Driver for the audio ring and the audio outputs.
pub struct AudioOut<'a, R: RegisterSpace, M: FabricMem> {
    regs: &'a R,
    mem: &'a M,
    ring: RingCore,
}

impl<'a, R: RegisterSpace, M: FabricMem> AudioOut<'a, R, M> {
    /// Takes the engine over, disabled, ring empty at `ring_addr` (CPU byte address).
    pub fn new(regs: &'a R, mem: &'a M, ring_addr: u32) -> Self {
        let a = AudioOut { regs, mem, ring: RingCore { base: ring_addr, words: AUDIO_RING_WORDS, wptr: 0 } };
        audio::ctrl::write(regs, audio::ctrl::Value(0).with_enable(false));
        audio::ring_wptr::write(regs, 0);
        audio::ring_base::write(regs, ring_addr / 4);
        audio::ring_size::write(regs, AUDIO_RING_WORDS);
        a
    }

    /// The identification register of the block.
    pub fn id(&self) -> u32 {
        audio::id::read(self.regs)
    }

    /// Engine on or off (PT8211 and the stream behind the digital outputs). Either way the ring
    /// starts empty.
    pub fn set_enable(&mut self, on: bool) {
        audio::ctrl::write(self.regs, audio::ctrl::Value(0).with_enable(false));
        self.ring.wptr = 0;
        audio::ring_wptr::write(self.regs, 0);
        if on {
            audio::ctrl::write(self.regs, audio::ctrl::Value(0).with_enable(true));
        }
    }

    /// PT8211 volume, 0-255 linear.
    pub fn set_volume(&self, volume: u8) {
        audio::volume::write(self.regs, volume as u32);
    }

    /// Digital outputs: S/PDIF and I2S on PMOD2, and the 1 kHz test tone on S/PDIF, I2S and HDMI
    /// (the tone needs neither the engine nor DDR3: the first sound check on a new board).
    pub fn set_outputs(&self, spdif: bool, i2s: bool, tone: bool) {
        audio::out_ctrl::write(self.regs, audio::out_ctrl::Value(0).with_spdif(spdif).with_i2s(i2s).with_tone(tone));
    }

    /// Reads `out_status`: lock of the output PLL, run and live flags, and the slip and error counts.
    pub fn out_status(&self) -> OutStatus {
        let s = audio::out_status::read(self.regs);
        OutStatus { pll_lock: s.pll_lock(), run: s.run(), live: s.live(), slips: s.slips() as u8, errors: s.errors() as u8 }
    }

    fn rptr(&self) -> u32 {
        audio::ring_rptr::read(self.regs)
    }

    /// Words in the ring that the logic has not read yet.
    pub fn fill(&self) -> u32 {
        self.ring.fill(self.rptr())
    }

    /// Words that can be queued before the ring is full.
    pub fn free(&self) -> u32 {
        self.ring.free(self.rptr())
    }

    /// Queues as many stereo frames ([`stereo_word`]) as fit and returns how many. The samples are
    /// flushed to DDR3 before the write pointer moves (the 10 us rule).
    pub fn push(&mut self, frames: &[u32]) -> usize {
        let rptr = self.rptr();
        let regs = self.regs;
        self.ring.push(self.mem, rptr, frames, |wptr, _flushed: Flushed| audio::ring_wptr::write(regs, wptr))
    }

    /// True if the ring ran low since the flag was last cleared.
    pub fn low_water(&self) -> bool {
        audio::status::read(self.regs).low_water()
    }

    /// Clears the low-water flag.
    pub fn clear_low_water(&self) {
        audio::status::clear_low_water(self.regs);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mem::map::AUDIO_RING;
    use crate::mock::MockFabric;

    #[test]
    fn ring_and_volume() {
        let f = MockFabric::new();
        let mut a = AudioOut::new(&f, &f, AUDIO_RING);
        assert_eq!(f.reg(audio::ring_base::addr()), AUDIO_RING / 4);
        a.set_enable(true);
        a.set_volume(200);
        assert_eq!(f.reg(audio::ctrl::addr()), 1);
        assert_eq!(f.reg(audio::volume::addr()), 200);
        assert_eq!(a.push(&[stereo_word(100, -100); 5_000]), 4_096);
        assert_eq!(a.fill(), 4_096);
        assert_eq!(f.mem(AUDIO_RING + 4), 0x0064_FF9C);
        f.poke(audio::ring_rptr::addr(), 4_000);
        assert_eq!(a.push(&[1, 2, 3]), 3);
        assert_eq!(f.mem(AUDIO_RING + 2 * 4), 3);
        assert_eq!(f.reg(audio::ring_wptr::addr()), 4_099);
        assert_eq!(f.flush_rule_violations(&[audio::ring_wptr::addr()]), 0);
    }

    #[test]
    fn digital_outputs_and_status() {
        let f = MockFabric::new();
        let a = AudioOut::new(&f, &f, AUDIO_RING);
        a.set_outputs(true, false, true);
        assert_eq!(f.reg(audio::out_ctrl::addr()), 0b101);
        // pll_lock, run, live; 3 slips; 1 error
        f.poke(audio::out_status::addr(), 0b111 | (3 << 8) | (1 << 16));
        assert_eq!(a.out_status(), OutStatus { pll_lock: true, run: true, live: true, slips: 3, errors: 1 });
    }
}
