// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Model of the replay channel, which sends the second decode pass through the chip
//! (docs/FT8_PASS2.md).
//!
//! The CPU subtracts the first pass's decodes from the slot's audio ([`super::subtract`]) and
//! writes the residual to a DDR3 buffer: 180,000 samples from slot sample 0, four 16-bit samples
//! per 64-bit lane word, sample `4w + k` in bits `16k + 15 .. 16k` of word `w` (the layout of the
//! capture rings). On `p2_cmd` the spectrogram engine transforms that buffer exactly as it
//! transforms a live slot ([`super::spectrogram::spectrogram_fx`], frames 0 to 371), and the sync
//! engine then searches the result exactly as it searches a receiver's own spectrogram
//! ([`super::sync::sync_fx`]). So the model of the replay is the two existing models applied to
//! the samples as they come back out of the buffer; this module fixes the buffer layout and puts
//! the two together, for the testbench vectors and for the chip model of the firmware tests.

use alloc::vec::Vec;

use super::spectrogram::spectrogram_fx;
use super::sync::{sync_fx, SyncBand};
use super::tables::Tables;
use super::SLOT_LEN;

/// Lane words of a slot of residual audio.
pub const RESIDUAL_LANE_WORDS: usize = SLOT_LEN / 4;

/// The residual buffer as the CPU writes it: [`RESIDUAL_LANE_WORDS`] lane words. Audio shorter than
/// a slot is followed by zeros, longer audio is cut.
pub fn pack_residual(audio: &[i16]) -> Vec<u64> {
    (0..RESIDUAL_LANE_WORDS)
        .map(|w| (0..4).fold(0u64, |a, k| a | ((audio.get(4 * w + k).copied().unwrap_or(0) as u16 as u64) << (16 * k))))
        .collect()
}

/// The samples the engines read out of a residual buffer.
pub fn unpack_residual(words: &[u64]) -> Vec<i16> {
    let mut v: Vec<i16> = words.iter().flat_map(|&w| (0..4).map(move |k| (w >> (16 * k)) as u16 as i16)).collect();
    v.resize(SLOT_LEN, 0);
    v
}

/// What the chip leaves in DDR3 after `p2_cmd`: the residual's spectrogram (372 x 1,024 power
/// words; in lane words, bin `2m` is the low half and `2m + 1` the high half) and the sync records
/// of band `ia ..= ib` (8 words per bin; in lane words, word `2k` low and `2k + 1` high).
pub struct Replay {
    /// Power spectrogram, frame-major, 1,024 bins per frame.
    pub spectrogram: Vec<u32>,
    /// One sync record per bin of the searched band, in the 8-word layout of `BinSync::to_words`.
    pub records: Vec<[u32; 8]>,
}

/// The replay of the residual buffer `words` with power shift `pwr_shift`, searched over `band`.
pub fn replay(t: &Tables, words: &[u64], pwr_shift: u32, band: SyncBand) -> Replay {
    let audio = unpack_residual(words);
    let spectrogram = spectrogram_fx(t, &audio, pwr_shift);
    let records = sync_fx(&spectrogram, band).iter().map(|b| b.to_words()).collect();
    Replay { spectrogram, records }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_buffer_layout_round_trips_and_pads_with_zeros() {
        let audio: Vec<i16> = (0..1_003).map(|i| (i * 37 - 20_000) as i16).collect();
        let w = pack_residual(&audio);
        assert_eq!(w.len(), RESIDUAL_LANE_WORDS);
        // Sample 4w + k in bits 16k + 15 .. 16k.
        assert_eq!(w[1], 0x0000u64 | (audio[4] as u16 as u64) | ((audio[5] as u16 as u64) << 16) | ((audio[6] as u16 as u64) << 32) | ((audio[7] as u16 as u64) << 48));
        let back = unpack_residual(&w);
        assert_eq!(back.len(), SLOT_LEN);
        assert_eq!(&back[..1_003], &audio[..]);
        assert!(back[1_003..].iter().all(|&x| x == 0));
    }
}
