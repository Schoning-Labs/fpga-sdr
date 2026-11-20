// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Tests of `tr_rxmodel::cic` against the arithmetic of the CIC specifications. Besides a few
//! hand-checked cases (strobe timing, DC gain, rounding, the live decimation input), the models
//! are compared clock by clock against a second, deliberately plain implementation that lives in
//! this file. It uses `Vec`s and `i128`, copies the whole state before every edge, and follows the
//! register equations of the specifications one to one, so it shares no structure with the model.

use tr_rxmodel::cic::{CicFixed, CicVar};

/// Small xorshift generator, so the stimulus is the same on every run and needs no dependency.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.0 = x;
        x
    }

    /// A random signed value that fills `bits` bits.
    fn signed(&mut self, bits: u32) -> i32 {
        let raw = (self.next() >> 20) as i64 & ((1i64 << bits) - 1);
        (raw << (64 - bits) >> (64 - bits)) as i32
    }

    fn chance(&mut self, one_in: u64) -> bool {
        self.next() % one_in == 0
    }
}

/// Two's complement value of `v` in `w` bits.
fn wrap(v: i128, w: u32) -> i128 {
    let m = 1i128 << w;
    let r = v.rem_euclid(m);
    if r >= m / 2 {
        r - m
    } else {
        r
    }
}

/// The reference filter, written straight from the register equations.
struct Reference {
    n: usize,
    w: u32,
    integ: Vec<i128>,
    comb_out: Vec<i128>,
    comb_prev: Vec<i128>,
    count: u32,
    strobe: bool,
}

impl Reference {
    fn new(n: usize, w: u32) -> Self {
        Reference {
            n,
            w,
            integ: vec![0; n],
            comb_out: vec![0; n],
            comb_prev: vec![0; n],
            count: 0,
            strobe: false,
        }
    }

    fn edge(&mut self, rst: bool, in_strobe: bool, x: i32, last_count: u32) {
        let old_integ = self.integ.clone();
        let old_out = self.comb_out.clone();
        let old_prev = self.comb_prev.clone();
        if rst {
            *self = Reference::new(self.n, self.w);
            return;
        }
        if self.strobe {
            for k in 0..self.n {
                let input = if k == 0 { old_integ[self.n - 1] } else { old_out[k - 1] };
                self.comb_out[k] = wrap(input - old_prev[k], self.w);
                self.comb_prev[k] = input;
            }
        }
        if in_strobe {
            for k in 0..self.n {
                let add = if k == 0 { x as i128 } else { old_integ[k - 1] };
                self.integ[k] = wrap(old_integ[k] + add, self.w);
            }
            if self.count == last_count {
                self.count = 0;
                self.strobe = true;
            } else {
                self.count = (self.count + 1) & 0xffff;
                self.strobe = false;
            }
        } else {
            self.strobe = false;
        }
    }

    fn cn(&self) -> i128 {
        self.comb_out[self.n - 1]
    }
}

/// Bits `hi` down to `hi - 15` of `cn` as a signed 16-bit word, plus the bit below them, wrapped
/// to 16 bits.
fn round16(cn: i128, w: u32, hi: u32) -> i32 {
    let raw = cn.rem_euclid(1i128 << w);
    let word = wrap((raw >> (hi - 15)) & 0xffff, 16);
    let half = (raw >> (hi - 16)) & 1;
    wrap(word + half, 16) as i32
}

#[test]
fn fixed_starts_at_zero() {
    let m = CicFixed::default();
    assert_eq!(m.out(), (false, 0));
}

#[test]
fn fixed_strobe_comes_one_cycle_after_every_tenth_sample() {
    let mut m = CicFixed::default();
    let mut strobes = Vec::new();
    for t in 0..60 {
        if m.out().0 {
            strobes.push(t);
        }
        m.step(false, true, 5);
    }
    // The tenth sample is accepted at the edge ending cycle 9, so the strobe is high in cycle 10.
    assert_eq!(strobes, vec![10, 20, 30, 40, 50]);
}

#[test]
fn fixed_gaps_in_the_input_hold_the_count() {
    let mut m = CicFixed::default();
    let mut accepted = 0;
    let mut strobes = 0;
    for t in 0..200 {
        let valid = t % 3 == 0;
        if m.out().0 {
            strobes += 1;
            assert_eq!(accepted % 10, 0);
        }
        if valid {
            accepted += 1;
        }
        m.step(false, valid, 1);
    }
    assert_eq!(strobes, accepted / 10);
}

#[test]
fn fixed_dc_gain_is_1000_before_the_shift_by_12() {
    for x in [2048, 1000, -1000, 131071, -131072, 3] {
        let mut m = CicFixed::default();
        for _ in 0..400 {
            m.step(false, true, x);
        }
        // 10^3 * x, then the top 16 of 28 bits plus the rounding bit.
        let expect = ((1000i64 * x as i64 + 2048) >> 12) as i32;
        assert_eq!(m.out().1, expect, "input {x}");
    }
}

#[test]
fn fixed_output_at_strobe_is_the_previous_result() {
    let mut m = CicFixed::default();
    let mut last_stable = 0;
    for _ in 0..300 {
        let (strobe, data) = m.out();
        if strobe {
            // The combs have not yet taken the new event in this cycle.
            assert_eq!(data, last_stable);
        } else {
            last_stable = data;
        }
        m.step(false, true, 40000);
    }
    assert_ne!(last_stable, 0);
}

#[test]
fn fixed_reset_clears_everything() {
    let mut m = CicFixed::default();
    for _ in 0..50 {
        m.step(false, true, 100000);
    }
    m.step(true, true, 100000);
    assert_eq!(m.out(), (false, 0));
    // After a reset the filter behaves like a new one.
    let mut fresh = CicFixed::default();
    for t in 0..100 {
        assert_eq!(m.out(), fresh.out(), "cycle {t}");
        m.step(false, true, 77);
        fresh.step(false, true, 77);
    }
}

#[test]
fn fixed_input_is_cut_to_18_bits() {
    // 2^17 does not fit in an 18-bit signed input and arrives as -2^17.
    let mut a = CicFixed::default();
    let mut b = CicFixed::default();
    for _ in 0..400 {
        a.step(false, true, 1 << 17);
        b.step(false, true, -(1 << 17));
    }
    assert_eq!(a.out(), b.out());
}

#[test]
fn fixed_matches_reference_cycle_by_cycle() {
    let mut rng = Rng(0x1234_5678_9abc_def1);
    for pattern in 0..4 {
        let mut m = CicFixed::default();
        let mut r = Reference::new(3, 28);
        for t in 0..20000 {
            let in_strobe = match pattern {
                0 => true,
                1 => t % 7 == 0,
                2 => rng.chance(2),
                _ => rng.chance(5),
            };
            let rst = (pattern >= 2 && rng.chance(3000)) || t == 0;
            let x = rng.signed(18);
            assert_eq!(m.out(), (r.strobe, round16(r.cn(), 28, 27)), "pattern {pattern} cycle {t}");
            m.step(rst, in_strobe, x);
            r.edge(rst, in_strobe, x, 9);
        }
    }
}

#[test]
fn integrators_wrap_and_combs_cancel_it() {
    // A constant full-scale input makes the last integrator wrap many times in 28 bits, and the
    // output must still settle at the DC gain of 1000.
    let mut m = CicFixed::default();
    for _ in 0..5000 {
        m.step(false, true, 131071);
    }
    assert_eq!(m.out().1, ((1000i64 * 131071 + 2048) >> 12) as i32);
}

/// Output word of the variable filter for a given ratio, from the reference.
fn var_expected(cn: i128, ratio: u32) -> i32 {
    let g = match ratio {
        5 => 12,
        10 => 17,
        20 => 22,
        _ => 27,
    };
    round16(cn, 43, 16 + g - 1)
}

#[test]
fn var_starts_at_zero() {
    let m = CicVar::default();
    assert_eq!(m.out(), (false, 0));
}

#[test]
fn var_dc_gain_for_each_ratio() {
    for (ratio, shift) in [(5i64, 12), (10, 17), (20, 22), (40, 27)] {
        let mut m = CicVar::default();
        let x = 20000i64;
        for _ in 0..2000 {
            m.step(false, ratio, true, x as i32);
        }
        // The word is bits [16+g-1 : g] plus the bit below it, so the value is shifted down by g.
        let exact = (ratio.pow(5) * x + (1i64 << (shift - 1))) >> shift;
        assert_eq!(m.out().1 as i64, exact, "ratio {ratio}");
    }
}

#[test]
fn var_result_arrives_two_clocks_after_the_strobe() {
    let mut m = CicVar::default();
    let mut strobe = vec![false; 400];
    let mut data = vec![0i32; 400];
    for t in 0..400 {
        (strobe[t], data[t]) = m.out();
        m.step(false, 10, true, 12345);
    }
    // With ratio 10 and a strobe in every clock, the strobe is high in cycles 10, 20, 30 ...
    assert!(strobe[10] && strobe[20] && strobe[30] && !strobe[11] && !strobe[9]);
    // The output only ever changes two cycles after a strobe cycle, while the filter settles.
    let mut changes = 0;
    for t in 1..400 {
        if data[t] != data[t - 1] {
            changes += 1;
            assert!(strobe[t - 2], "change at cycle {t}");
        }
    }
    assert!(changes >= 2);
}

#[test]
fn var_reset_leaves_the_output_register_alone() {
    let mut m = CicVar::default();
    for _ in 0..2000 {
        m.step(false, 10, true, 20000);
    }
    let held = m.out().1;
    assert_ne!(held, 0);
    // The register reloads from the last comb as it was before the edge, so one reset edge
    // still shows the old result, and the cleared comb reaches the output register one edge later.
    m.step(true, 10, true, 20000);
    assert_eq!(m.out(), (false, held));
    m.step(false, 10, false, 0);
    assert_eq!(m.out().1, 0);
}

#[test]
fn var_counter_follows_the_live_ratio() {
    // A ratio of 1 gives a strobe after every sample, 0 counts like 64, 63 counts 63.
    for (ratio, period) in [(1i64, 1usize), (0, 64), (63, 63), (7, 7), (5, 5)] {
        let mut m = CicVar::default();
        let mut strobes = Vec::new();
        for t in 0..(period * 6 + 5) {
            if m.out().0 {
                strobes.push(t);
            }
            m.step(false, ratio, true, 1);
        }
        // The strobe is high in the cycle after the edge that accepts sample number `period`.
        let expect: Vec<usize> = (1..=6).map(|k| k * period).collect();
        assert_eq!(&strobes[..6], &expect[..], "ratio {ratio}");
    }
}

#[test]
fn var_lowering_the_ratio_mid_count_leaves_a_long_gap() {
    let mut m = CicVar::default();
    // Count 30 samples under ratio 40, then drop to ratio 5 without a reset.
    for _ in 0..30 {
        m.step(false, 40, true, 1);
    }
    let mut gap = 0usize;
    loop {
        m.step(false, 5, true, 1);
        gap += 1;
        if m.out().0 {
            break;
        }
        assert!(gap < 100_000, "never strobed");
    }
    // The counter was at 30, counts through 65535, wraps, and matches at 4: 65536 - 30 + 4 + 1.
    assert_eq!(gap, 65536 - 30 + 4 + 1);
}

#[test]
fn var_matches_reference_cycle_by_cycle() {
    let mut rng = Rng(0x0fed_cba9_8765_4321);
    let ratios = [5u32, 10, 20, 40, 0, 1, 7, 63];
    for pattern in 0..3 {
        let mut m = CicVar::default();
        let mut r = Reference::new(5, 43);
        let mut out_reg = 0i32;
        let mut ratio = 40u32;
        for t in 0..60000 {
            // Change the ratio now and then, sometimes together with a reset.
            let mut rst = t == 0;
            if rng.chance(2500) {
                ratio = ratios[(rng.next() % ratios.len() as u64) as usize];
                rst = rng.chance(2);
            }
            let in_strobe = match pattern {
                0 => true,
                1 => t % 10 == 0,
                _ => rng.chance(3),
            };
            let x = rng.signed(16);
            assert_eq!(m.out(), (r.strobe, out_reg), "pattern {pattern} cycle {t}");
            m.step(rst, ratio as i64, in_strobe, x);
            out_reg = var_expected(r.cn(), ratio);
            let last = (ratio.wrapping_sub(1) & 0x3f) as u32;
            r.edge(rst, in_strobe, x, last);
        }
    }
}
