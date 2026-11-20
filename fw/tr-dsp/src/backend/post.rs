// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Everything after the channel filter, per 24 ksps sample (docs/R4_BACKEND.md sections
//! 3.4-3.7): CORDIC, S-meter level, squelch, demodulator, log-domain AGC, the audio half-band to
//! 12 ksps and the 16-bit output.

use super::cordic::{rotate_re, vector};
use super::fix::{msb, rshr, sat, wrap};
use super::halfband::HalfBand;
use super::tables::{EXP2, LOG2};

/// Demodulator mode (register field `mode`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// USB, LSB, CW and data: real part of the one-sided filter output.
    Ssb = 0,
    /// AM, envelope.
    Am = 1,
    /// AM, synchronous (phase-locked carrier).
    Sam = 2,
    /// FM discriminator with de-emphasis. The AGC is not used in this mode.
    Fm = 3,
    /// Complex pass-through for software demodulators.
    Iq = 4,
}

impl Mode {
    pub fn from_bits(v: u8) -> Mode {
        match v {
            1 => Mode::Am,
            2 => Mode::Sam,
            3 => Mode::Fm,
            4 => Mode::Iq,
            _ => Mode::Ssb,
        }
    }
}

/// AGC smoothing coefficient `alpha = a * 2^-(17 + s)`.
#[derive(Clone, Copy, Debug)]
pub struct Alpha {
    /// 0..=131071.
    pub a: u32,
    /// 0..=15.
    pub s: u8,
}

impl Alpha {
    /// Nearest representable coefficient to `1 - exp(-1 / (tc_ms * fs))`, as `tr-dsp::agc` uses.
    pub fn from_time_constant(tc_ms: f64, fs_hz: f64) -> Alpha {
        let tc = (tc_ms * 0.001 * fs_hz).max(1e-6);
        let alpha = 1.0 - libm::exp(-1.0 / tc);
        let mut s = 0u8;
        while s < 15 && alpha * (1u64 << (17 + s as u32 + 1)) as f64 <= 131_071.0 {
            s += 1;
        }
        let a = libm::round(alpha * (1u64 << (17 + s as u32)) as f64).clamp(1.0, 131_071.0) as u32;
        Alpha { a, s }
    }

    pub fn value(&self) -> f64 {
        self.a as f64 / (1u64 << (17 + self.s as u32)) as f64
    }
}

/// Settings of the log-domain AGC.
#[derive(Clone, Copy, Debug)]
pub struct AgcConfig {
    /// false = AGC bypassed: the fixed gain `manual` is applied.
    pub enable: bool,
    pub attack: Alpha,
    pub decay: Alpha,
    /// Hang time in 24 ksps samples.
    pub hang: u16,
    /// Target output level, log2 of the 24-bit-scale amplitude, U5.12.
    pub reference: i64,
    /// Gain limits and the manual gain, log2, S7.12.
    pub gmax: i64,
    pub gmin: i64,
    pub manual: i64,
}

impl Default for AgcConfig {
    fn default() -> Self {
        AgcConfig {
            enable: true,
            attack: Alpha::from_time_constant(2.0, 24_000.0),
            decay: Alpha::from_time_constant(250.0, 24_000.0),
            hang: 2_400,
            reference: 21 << 12,
            gmax: 20 << 12,
            gmin: -8 << 12,
            manual: 0,
        }
    }
}

/// Settings of everything after the channel filter.
#[derive(Clone, Copy, Debug)]
pub struct PostConfig {
    pub mode: Mode,
    /// true: output at 24 ksps (no HB5); false: 12 ksps.
    pub out24: bool,
    pub agc: AgcConfig,
    /// S-meter smoothing: 2^k_sm samples.
    pub k_sm: u8,
    /// AM/SAM carrier (DC) removal: 2^k_dc samples.
    pub k_dc: u8,
    /// SAM PLL: proportional and integral shifts.
    pub sam_kp: u8,
    pub sam_ki: u8,
    /// FM de-emphasis one-pole coefficient, U0.17; 0 = off.
    pub deemph: u32,
    pub sq_enable: bool,
    /// Squelch thresholds on the S-meter level, 1/64 dB.
    pub sq_open: i64,
    pub sq_close: i64,
}

impl Default for PostConfig {
    fn default() -> Self {
        PostConfig {
            mode: Mode::Ssb,
            out24: false,
            agc: AgcConfig::default(),
            k_sm: 7,
            k_dc: 10,
            sam_kp: 7,
            sam_ki: 15,
            deemph: 0,
            sq_enable: false,
            sq_open: -6400,
            sq_close: -6656,
        }
    }
}

/// `L = log2(M)` in U5.12 from the leading one and a 1,024-entry table (M = 0 gives 0).
pub fn log2_fix(m: i64) -> i64 {
    if m <= 0 {
        return 0;
    }
    let p = msb(m) as i64;
    let idx = if p >= 10 { (m >> (p - 10)) & 1023 } else { (m << (10 - p)) & 1023 };
    (p << 12) + LOG2[idx as usize] as i64
}

/// S-meter level in 1/64 dB relative to a 2^23 amplitude, from the smoothed log level (U5.20).
pub fn smeter_db64(sm: i64) -> i64 {
    (((sm >> 8) - 23 * 4096) * 6165) >> 16
}

/// `sat24(a * 2^(g / 1024))`, `g` the gain in S.10 log2 units.
pub fn apply_gain(a: i64, g: i64) -> i64 {
    let n = g >> 10;
    let m = EXP2[(g & 1023) as usize] as i64;
    let p = a * m;
    let t = (n - 16).clamp(-48, 24);
    if t >= 0 {
        sat(p << t, 24)
    } else {
        sat(rshr(p, (-t) as u32), 24)
    }
}

/// Output sample of the back end.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Out {
    /// Audio, or I in IQ mode.
    pub s0: i16,
    /// Q in IQ mode, else 0.
    pub s1: i16,
}

/// State of the post-processing of one receiver.
#[derive(Clone, Debug)]
pub struct Post {
    first: bool,
    sm: i64,
    sq_open: bool,
    dc: i64,
    theta: i64,
    freq: i64,
    phi_prev: i64,
    deemph: i64,
    g: i64,
    hang: i64,
    hb5: HalfBand,
    /// Intermediate values of the last sample, for tracing against the RTL:
    /// [M, L, audio before gain, gain S.10, theta, freq, dc].
    pub trace: [i64; 7],
}

impl Default for Post {
    fn default() -> Self {
        Post {
            first: true,
            sm: 0,
            sq_open: false,
            dc: 0,
            theta: 0,
            freq: 0,
            phi_prev: 0,
            deemph: 0,
            g: 0,
            hang: 0,
            hb5: HalfBand::new(3),
            trace: [0; 7],
        }
    }
}

impl Post {
    /// Current S-meter level, 1/64 dB relative to a 2^23 amplitude (status register).
    pub fn smeter(&self) -> i64 {
        smeter_db64(self.sm)
    }

    /// Current AGC gain, log2 S.10 (status register; the gain actually applied).
    pub fn gain(&self) -> i64 {
        self.g >> 14
    }

    /// True while the squelch is open.
    pub fn squelch_open(&self) -> bool {
        self.sq_open
    }

    /// One channel-filter output sample in; an output sample out at 12 or 24 ksps.
    pub fn push(&mut self, cfg: &PostConfig, y: (i64, i64)) -> Option<Out> {
        let first = self.first;
        self.first = false;
        let (m, phi) = vector(y.0, y.1);
        let l = log2_fix(m);

        // S-meter and squelch.
        if first {
            self.sm = l << 8;
        } else {
            self.sm += ((l << 8) - self.sm) >> cfg.k_sm;
        }
        let db = smeter_db64(self.sm);
        if first {
            self.sq_open = false;
        }
        if db > cfg.sq_open {
            self.sq_open = true;
        } else if db < cfg.sq_close {
            self.sq_open = false;
        }

        // Demodulator.
        let mut b = 0i64;
        let mut a = match cfg.mode {
            Mode::Ssb => y.0,
            Mode::Iq => {
                b = y.1;
                y.0
            }
            Mode::Am | Mode::Sam => {
                let c = if cfg.mode == Mode::Am {
                    m
                } else {
                    if first {
                        self.theta = 0;
                        self.freq = 0;
                    }
                    let th24 = wrap(self.theta >> 8, 24);
                    let c = rotate_re(y.0, y.1, wrap(-th24, 24));
                    let e32 = wrap(phi - th24, 24) << 8;
                    self.freq = (self.freq + (e32 >> cfg.sam_ki)).clamp(-(1 << 27), 1 << 27);
                    self.theta = (self.theta + self.freq + (e32 >> cfg.sam_kp)) & 0xFFFF_FFFF;
                    c
                };
                if first {
                    self.dc = c << 16;
                } else {
                    self.dc += ((c << 16) - self.dc) >> cfg.k_dc;
                }
                c - (self.dc >> 16)
            }
            Mode::Fm => {
                if first {
                    self.phi_prev = phi;
                    self.deemph = 0;
                }
                let d = wrap(phi - self.phi_prev, 24);
                self.phi_prev = phi;
                if cfg.deemph == 0 {
                    d
                } else {
                    self.deemph += ((d - self.deemph) * cfg.deemph as i64 + (1 << 16)) >> 17;
                    self.deemph
                }
            }
        };

        // AGC in the log domain.
        let agc = &cfg.agc;
        let (gmin, gmax) = (agc.gmin << 12, agc.gmax << 12);
        if first {
            self.g = gmax;
            self.hang = 0;
        }
        if agc.enable && cfg.mode != Mode::Fm {
            let gt = ((agc.reference - l) << 12).clamp(gmin, gmax);
            let step = |d: i64, al: &Alpha| ((d >> 8) * al.a as i64 + (1i64 << (8 + al.s))) >> (9 + al.s);
            if l + (self.g >> 12) > agc.reference {
                self.g += step(gt - self.g, &agc.attack);
                self.hang = agc.hang as i64;
            } else if self.hang > 0 {
                self.hang -= 1;
            } else {
                self.g += step(gt - self.g, &agc.decay);
            }
            self.g = self.g.clamp(gmin, gmax);
        } else {
            self.g = agc.manual << 12;
        }
        let ga = self.g >> 14;
        self.trace = [m, l, a, ga, self.theta, self.freq, self.dc];
        a = apply_gain(a, ga);
        b = apply_gain(b, ga);
        if cfg.sq_enable && !self.sq_open {
            a = 0;
            b = 0;
        }

        // Audio half-band and output.
        let v = if cfg.out24 { (a, b) } else { self.hb5.push((a, b))? };
        let s0 = sat(rshr(v.0, 8), 16) as i16;
        let s1 = if cfg.mode == Mode::Iq { sat(rshr(v.1, 8), 16) as i16 } else { 0 };
        Some(Out { s0, s1 })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn log2_and_exp2_are_accurate() {
        let mut worst = 0.0f64;
        for k in 1..4000i64 {
            let m = (k * k * 523) % 16_000_000 + 1;
            let l = log2_fix(m) as f64 / 4096.0;
            worst = worst.max((l - libm::log2(m as f64)).abs());
        }
        std::println!("MEASURED log2 worst error {:.5} octave ({:.4} dB)", worst, worst * 6.0206);
        assert!(worst < 0.0016);
        // gain 2^(g/1024) on a 1,000,000 amplitude
        for g in [-5000i64, -1024, 0, 1, 777, 10_240, 12_000] {
            let out = apply_gain(1_000_000, g) as f64;
            let want = (1_000_000.0 * libm::pow(2.0, g as f64 / 1024.0)).min(8_388_607.0);
            assert!((out - want).abs() <= want * 2e-5 + 1.0, "g {g}: {out} vs {want}");
        }
    }

    #[test]
    fn alpha_quantisation() {
        for tc in [0.5, 2.0, 5.0, 100.0, 300.0, 2000.0, 10_000.0] {
            let a = Alpha::from_time_constant(tc, 24_000.0);
            let want = 1.0 - libm::exp(-1.0 / (tc * 24.0));
            assert!(((a.value() - want) / want).abs() < 1e-4, "tc {tc}: {} vs {want}", a.value());
        }
    }
}
