// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Franz Schöning, https://www.schoning.com
// The waveform follows WSJT-X (K1JT and contributors, GPL-3.0-or-later), routines `gen_ft8wave`
// and `gfsk_pulse`; modified 2026 by Franz Schöning (streaming, complex baseband at 48 ksps).

//! FT8 transmit baseband for the TX ring (docs/P2_FT8_FW.md): a message becomes 79 tones
//! (mfsk-core does the packing, CRC, LDPC, Gray map and Costas arrays) and the tones become GFSK at
//! 48 ksps complex baseband, produced in chunks while it plays, since the ring only holds 171 ms.
//!
//! The waveform is the one WSJT-X's `gen_ft8wave` makes. It is phase continuous, each symbol's
//! frequency step is smoothed by a Gaussian pulse (BT = 2.0) that is three symbols long, the first
//! and last tone are extended by one symbol to give that pulse something to work on, and a
//! raised-cosine ramp of an eighth of a symbol sits at both ends. Here `I = A cos(phi)` and
//! `Q = A sin(phi)`, with `phi' = 2 pi (f_audio + 6.25 Hz x tone, smoothed)`. Mixed up to the dial
//! frequency by the TX chain this gives an upper-sideband signal `f_audio` above the dial, which
//! is what a USB transmitter fed with WSJT-X audio radiates, and `Q` alone is WSJT-X's audio.
//!
//! A ring word is `{I[15:0], Q[15:0]}`, with I in bits 31:16 (the TX ring of `tr-fabric`).

use alloc::vec::Vec;

use mfsk_core::ft8::wave_gen::message_to_tones;
use mfsk_core::msg::wsjt77::pack77;

/// TX baseband sample rate.
pub const RATE: u32 = 48_000;
/// Samples per symbol at 48 ksps (0.16 s).
pub const NSPS: usize = 7_680;
/// Symbols per message.
pub const NSYM: usize = 79;
/// Samples of one transmission (12.64 s).
pub const WAVE_LEN: usize = NSYM * NSPS;
/// Length of the raised-cosine ramp at each end, samples.
const RAMP: usize = NSPS / 8;
/// Where in the 15 s slot WSJT-X starts a transmission, ms.
pub const TX_START_MS: u32 = 500;

/// The 79 tones (0 to 7) of a standard message such as `("CQ", "K1ABC", "FN42")` or
/// `("K1ABC", "W9XYZ", "R-09")`, where the third field may also be `"RRR"`, `"RR73"`, `"73"` or
/// empty. Returns `None` if the fields do not pack.
pub fn tones(f1: &str, f2: &str, f3: &str) -> Option<[u8; NSYM]> {
    Some(message_to_tones(&pack77(f1, f2, f3)?))
}

/// Splits message text as it is shown ("K1ABC W9XYZ R-09") into the three fields `tones` takes.
/// A missing third field comes back empty, and more than three words give `None`.
pub fn fields(text: &str) -> Option<(&str, &str, &str)> {
    let mut it = text.split_ascii_whitespace();
    let (a, b) = (it.next()?, it.next()?);
    let c = it.next().unwrap_or("");
    if it.next().is_some() {
        return None;
    }
    Some((a, b, c))
}

/// Frequency-step pulse at time `t` (in symbols, 0 at the center): the difference of two error
/// functions, so a unit step smoothed by a Gaussian filter.
fn gfsk_pulse(t: f32) -> f32 {
    // WSJT-X gfsk_pulse with BT = 2.0.
    let c = core::f32::consts::PI * libm::sqrtf(2.0 / core::f32::consts::LN_2) * 2.0;
    0.5 * (libm::erff(c * (t + 0.5)) - libm::erff(c * (t - 0.5)))
}

/// One FT8 transmission as a stream of TX ring words.
///
/// Create it with `new` or `from_message`, optionally `skip` into it, then call `fill` with ring
/// chunks until it returns 0.
pub struct Ft8Baseband {
    tones: [u8; NSYM],
    /// Pulse of one symbol, 3 symbols long, centered.
    pulse: Vec<f32>,
    /// Phase step of the audio carrier per sample, radians.
    carrier: f64,
    amplitude: f32,
    /// Running carrier phase, radians, kept in f64 so the 606,720 additions of one transmission lose no resolution.
    phase: f64,
    /// Index of the next sample.
    k: usize,
}

impl Ft8Baseband {
    /// `audio_hz`: frequency of tone 0 above the dial; `amplitude`: peak of I and Q.
    pub fn new(tones: [u8; NSYM], audio_hz: f32, amplitude: i16) -> Self {
        let pulse = (0..3 * NSPS).map(|i| gfsk_pulse((i as f32 - 1.5 * NSPS as f32) / NSPS as f32)).collect();
        Ft8Baseband {
            tones,
            pulse,
            carrier: core::f64::consts::TAU * audio_hz as f64 / RATE as f64,
            amplitude: amplitude.max(0) as f32,
            phase: 0.0,
            k: 0,
        }
    }

    /// Packs the three message fields (see `tones`) and builds the baseband, or `None` if they
    /// do not pack.
    pub fn from_message(f1: &str, f2: &str, f3: &str, audio_hz: f32, amplitude: i16) -> Option<Self> {
        Some(Self::new(tones(f1, f2, f3)?, audio_hz, amplitude))
    }

    /// The 79 tones this transmission was built from.
    pub fn tones(&self) -> &[u8; NSYM] {
        &self.tones
    }

    /// Samples still to come.
    pub fn remaining(&self) -> usize {
        WAVE_LEN - self.k
    }

    /// Phase step of sample `k`: the carrier plus every symbol whose pulse reaches it.
    fn step(&self, k: usize) -> f64 {
        let s = (k / NSPS) as isize;
        let mut m = 0.0f32;
        for j in s - 1..=s + 1 {
            let tone = self.tones[j.clamp(0, NSYM as isize - 1) as usize];
            // Symbol j's pulse is centered on its middle: index 0 is 1 symbol before its start.
            let idx = k as isize - j * NSPS as isize + NSPS as isize;
            if (-1..=NSYM as isize).contains(&j) && idx >= 0 && (idx as usize) < self.pulse.len() {
                m += tone as f32 * self.pulse[idx as usize];
            }
        }
        self.carrier + core::f64::consts::TAU * m as f64 / NSPS as f64
    }

    /// Amplitude envelope of sample `k`: the raised-cosine ramps at both ends, 1.0 in between.
    fn envelope(k: usize) -> f32 {
        let ramp = |i: usize| 0.5 * (1.0 - libm::cosf(core::f32::consts::PI * i as f32 / RAMP as f32));
        if k < RAMP {
            ramp(k)
        } else if k >= WAVE_LEN - RAMP {
            ramp(WAVE_LEN - 1 - k)
        } else {
            1.0
        }
    }

    /// Moves one sample forward, wrapping the phase to keep it small.
    fn advance(&mut self) {
        self.phase += self.step(self.k);
        if self.phase > core::f64::consts::TAU {
            self.phase -= core::f64::consts::TAU;
        }
        self.k += 1;
    }

    /// Drops the next `n` samples (a transmission that starts late keeps its place in time).
    pub fn skip(&mut self, n: usize) {
        for _ in 0..n.min(self.remaining()) {
            self.advance();
        }
    }

    /// Writes the next samples as ring words and returns how many (0 = finished).
    pub fn fill(&mut self, out: &mut [u32]) -> usize {
        let n = out.len().min(self.remaining());
        for w in out[..n].iter_mut() {
            let a = self.amplitude * Self::envelope(self.k);
            let (s, c) = libm::sincosf(self.phase as f32);
            let (i, q) = (libm::roundf(a * c) as i16, libm::roundf(a * s) as i16);
            *w = ((i as u16 as u32) << 16) | (q as u16 as u32);
            self.advance();
        }
        n
    }
}

/// Splits a ring word into its signed 16-bit I (bits 31:16) and Q (bits 15:0).
pub const fn word_iq(w: u32) -> (i16, i16) {
    ((w >> 16) as u16 as i16, w as u16 as i16)
}
