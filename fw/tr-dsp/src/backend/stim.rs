// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Integer test stimulus for the bit-exact comparison with the RTL. `sim/rx_backend/tb_*.v`
//! generates the identical sequence in Verilog (same table, same arithmetic), so a testbench
//! needs no input files: up to two complex tones from a 32-bit phase accumulator and a
//! 1,024-entry sine table, uniform noise from xorshift32, and optional periodic impulses.

use super::fix::sat;
use super::tables::SINE;

/// The xorshift32 pseudorandom generator, which the testbench implements identically.
#[derive(Clone, Copy, Debug)]
pub struct Xorshift(pub u32);

impl Xorshift {
    #[inline]
    pub fn next(&mut self) -> u32 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.0 = x;
        x
    }
}

/// One tone of the stimulus.
#[derive(Clone, Copy, Debug, Default)]
pub struct Tone {
    /// Amplitude (the sine table is Q17, so the tone peaks at `amp`).
    pub amp: i32,
    /// Phase increment per sample, 2^32 = one turn (negative frequencies wrap).
    pub inc: u32,
}

/// What the stimulus consists of.
#[derive(Clone, Copy, Debug, Default)]
pub struct StimSpec {
    pub tones: [Tone; 2],
    /// 0 = no noise; else each of I and Q gets `(xorshift as i32) >> noise_shift`.
    pub noise_shift: u8,
    pub seed: u32,
    /// 0 = none; else samples `n % period` in {0, 1} are replaced by `(imp, -(imp >> 1))`.
    pub imp_period: u32,
    pub imp_amp: i32,
}

/// Generator of the stimulus samples.
#[derive(Clone, Debug)]
pub struct Stim {
    spec: StimSpec,
    ph: [u32; 2],
    rng: Xorshift,
    n: u32,
}

impl Stim {
    pub fn new(spec: StimSpec) -> Self {
        Stim { spec, ph: [0, 0], rng: Xorshift(spec.seed | 1), n: 0 }
    }

    /// Next 24-bit (I, Q) bank sample.
    pub fn next(&mut self) -> (i64, i64) {
        let (mut i, mut q) = (0i64, 0i64);
        for t in 0..2 {
            let tone = self.spec.tones[t];
            if tone.amp != 0 {
                let idx = (self.ph[t] >> 22) as usize;
                i += (tone.amp as i64 * SINE[(idx + 256) & 1023] as i64) >> 17;
                q += (tone.amp as i64 * SINE[idx] as i64) >> 17;
            }
            self.ph[t] = self.ph[t].wrapping_add(tone.inc);
        }
        if self.spec.noise_shift > 0 {
            i += (self.rng.next() as i32 as i64) >> self.spec.noise_shift;
            q += (self.rng.next() as i32 as i64) >> self.spec.noise_shift;
        }
        if self.spec.imp_period > 0 && self.n % self.spec.imp_period < 2 {
            i = self.spec.imp_amp as i64;
            q = -((self.spec.imp_amp >> 1) as i64);
        }
        self.n = self.n.wrapping_add(1);
        (sat(i, 24), sat(q, 24))
    }
}

/// Phase increment for `f_hz` at `fs_hz`.
pub fn inc_for(f_hz: f64, fs_hz: f64) -> u32 {
    let v = libm::round(f_hz / fs_hz * 4_294_967_296.0) as i64;
    v as u32
}
