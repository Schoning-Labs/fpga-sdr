// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Bit-exact transliteration of `rtl/rx/nco_mixer.v` in `MODE 0` (receive: real 12-bit input,
//! complex 18-bit output), with the parameters that `rx_channel.v` instantiates it with. Every
//! register in the RTL has a matching field here, the one `always @(posedge clock) if (in_strobe)`
//! datapath has a matching computation in [`Nco::step`], and the valid tracking (`valid_sr`,
//! `out_strobe_r`) has its own.
//! matching field here; the one `always @(posedge clock) if (in_strobe)` datapath has a matching
//! computation in [`Nco::step`], and the valid tracking (`valid_sr`, `out_strobe_r`) its own.
//!
//! The general translation approach is the crate's usual one (`docs/R2_RXMODEL.md` section 2):
//! every value is kept as a canonical sign-extended `i64`, and [`crate::bits`] does the
//! fixed-width truncation a register assignment does. Here almost every value provably fits its
//! register (the widths were chosen that way, see the RTL header), so `trunc` appears only where
//! the RTL relies on a wrap or a part-select.
//!
//! The sine table is the RTL's own `$readmemh` file, `rtl/rx/nco_sin_table.hex` (512 words of 36
//! bits, word j = {T[j], T[1023 - j]}), compiled in with `include_str!`, so the model and the RTL
//! cannot use different tables.

use crate::bits::{bit, trunc};
use std::sync::OnceLock;

const E: u32 = 4; // extra fraction bits of the corrected sine/cosine (MODE 0)
const SH: u32 = 28 - E; // (dc * 201) * table >> SH = correction in 2^-E table steps
const LAT: u32 = 7; // register levels from input to output
const OUT_WIDTH: u32 = 18;
const VALID_SR_MASK: u32 = (1 << (LAT - 1)) - 1;

static TABLE_HEX: &str = include_str!("../../../rtl/rx/nco_sin_table.hex");

/// The 512 36-bit table words (the RTL's `rom`), parsed once.
fn table() -> &'static [i64; 512] {
    static T: OnceLock<[i64; 512]> = OnceLock::new();
    T.get_or_init(|| {
        let mut t = [0i64; 512];
        let mut n = 0;
        for line in TABLE_HEX.lines() {
            let s = line.trim();
            if s.is_empty() {
                continue;
            }
            t[n] =
                i64::from_str_radix(s, 16).expect("nco_sin_table.hex: bad hex") & ((1 << 36) - 1);
            n += 1;
        }
        assert_eq!(n, 512, "nco_sin_table.hex must have 512 words");
        t
    })
}

/// This-cycle outputs (the RTL's continuous assigns of the output registers).
pub struct NcoOut {
    /// High for one cycle when `out_i` and `out_q` hold a new sample.
    pub out_strobe: bool,
    /// In-phase output, 18-bit signed.
    pub out_i: i32,
    /// Quadrature output, 18-bit signed.
    pub out_q: i32,
}

/// The numerically controlled oscillator and mixer (`rtl/rx/nco_mixer.v`) in its state between two
/// clock edges.
#[derive(Clone)]
pub struct Nco {
    table: &'static [i64; 512],
    valid_sr: u32,
    out_strobe: bool,
    // stage A
    phase: u32,
    rd_w: i64,
    sw_a: bool,
    d_a: i64,
    q_a: u32,
    x_a: i64,
    // stage B
    s_b: i64,
    c_b: i64,
    d3_b: i64,
    d9_b: i64,
    q_b: u32,
    x_b: i64,
    // stage C
    s_c: i64,
    c_c: i64,
    ds_c: i64,
    q_c: u32,
    x_c: i64,
    // stage D
    pc_d: i64,
    ps_d: i64,
    s_d: i64,
    c_d: i64,
    q_d: u32,
    x_d: i64,
    // stage E
    bs_e: i64,
    bc_e: i64,
    xs_e: i64,
    xc_e: i64,
    // stage F
    mi_f: i64,
    mq_f: i64,
    // stage G
    oi_g: i64,
    oq_g: i64,
}

impl Default for Nco {
    fn default() -> Self {
        Nco {
            table: table(),
            valid_sr: 0,
            out_strobe: false,
            phase: 0,
            rd_w: 0,
            sw_a: false,
            d_a: 0,
            q_a: 0,
            x_a: 0,
            s_b: 0,
            c_b: 0,
            d3_b: 0,
            d9_b: 0,
            q_b: 0,
            x_b: 0,
            s_c: 0,
            c_c: 0,
            ds_c: 0,
            q_c: 0,
            x_c: 0,
            pc_d: 0,
            ps_d: 0,
            s_d: 0,
            c_d: 0,
            q_d: 0,
            x_d: 0,
            bs_e: 0,
            bc_e: 0,
            xs_e: 0,
            xc_e: 0,
            mi_f: 0,
            mq_f: 0,
            oi_g: 0,
            oq_g: 0,
        }
    }
}

impl Nco {
    /// This-cycle outputs, from the pre-edge state alone.
    #[inline(always)]
    pub fn out(&self) -> NcoOut {
        NcoOut {
            out_strobe: self.out_strobe,
            out_i: self.oi_g as i32,
            out_q: self.oq_g as i32,
        }
    }

    /// One clock edge. `rst` clears only the valid tracking, as in the RTL; the datapath
    /// registers advance only on `in_strobe`. Every right-hand side below reads the pre-edge
    /// value of its register: the stages are written from the output backwards, so each
    /// assignment reads a field no earlier line has overwritten yet.
    #[inline(always)]
    pub fn step(&mut self, rst: bool, in_strobe: bool, frequency: i32, in_data: i32) {
        // out_strobe_r <= in_strobe & valid_sr[LAT-2] (pre-edge valid_sr), cleared by rst
        self.out_strobe = !rst && in_strobe && bit(self.valid_sr as i64, LAT - 2) != 0;
        self.valid_sr = if rst {
            0
        } else if in_strobe {
            ((self.valid_sr << 1) | 1) & VALID_SR_MASK
        } else {
            self.valid_sr
        };
        if !in_strobe {
            return;
        }

        // stage G: round half up to 18 bits: floor(m / 2^15) + m[14]
        let sh_o = 11 + E;
        self.oi_g = trunc((self.mi_f >> sh_o) + bit(self.mi_f, sh_o - 1), OUT_WIDTH);
        self.oq_g = trunc((self.mq_f >> sh_o) + bit(self.mq_f, sh_o - 1), OUT_WIDTH);

        // stage F: mix
        self.mi_f = self.xc_e * self.bc_e;
        self.mq_f = self.xs_e * self.bs_e;

        // stage E: Taylor correction (floor), signs applied to the sample
        self.bs_e = (self.s_d << E) + (self.pc_d >> SH);
        self.bc_e = (self.c_d << E) - (self.ps_d >> SH);
        let q1 = (self.q_d >> 1) & 1;
        let q0 = self.q_d & 1;
        self.xs_e = if q1 != 0 { -self.x_d } else { self.x_d };
        self.xc_e = if (q1 ^ q0) != 0 { -self.x_d } else { self.x_d };

        // stage D: d * cos, d * sin
        self.pc_d = self.ds_c * self.c_c;
        self.ps_d = self.ds_c * self.s_c;
        self.s_d = self.s_c;
        self.c_d = self.c_c;
        self.q_d = self.q_c;
        self.x_d = self.x_c;

        // stage C: ds = (3 dc << 6) + 9 dc = 201 dc
        self.s_c = self.s_b;
        self.c_c = self.c_b;
        self.ds_c = (self.d3_b << 6) + self.d9_b;
        self.q_c = self.q_b;
        self.x_c = self.x_b;

        // stage B: sin/cos from the table word (halves swapped for k >= 512); 3 dc, 9 dc with
        // dc = {d_a, 1}
        let dc = 2 * self.d_a + 1;
        let (hi, lo) = ((self.rd_w >> 18) & 0x1_FFFF, self.rd_w & 0x1_FFFF);
        (self.s_b, self.c_b) = if self.sw_a { (lo, hi) } else { (hi, lo) };
        self.d3_b = 3 * dc;
        self.d9_b = 9 * dc;
        self.q_b = self.q_a;
        self.x_b = self.x_a;

        // stage A: table read, residual, quadrant, sample, phase accumulator
        let q0a = (self.phase >> 30) & 1;
        let um = ((self.phase >> 10) & 0xF_FFFF) ^ if q0a != 0 { 0xF_FFFF } else { 0 };
        let addr_s = (um >> 10) as usize;
        let addr_w = (addr_s & 0x1FF) ^ if addr_s & 0x200 != 0 { 0x1FF } else { 0 };
        self.rd_w = self.table[addr_w];
        self.sw_a = addr_s & 0x200 != 0;
        // d_a = {~um[9], um[8:0]} as a signed 10-bit value = um[9:0] - 512
        self.d_a = (um & 0x3FF) as i64 - 512;
        self.q_a = self.phase >> 30;
        self.x_a = in_data as i64;
        self.phase = if frequency == 0 {
            0
        } else {
            self.phase.wrapping_add(frequency as u32)
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The table is the RTL's file: word j = {sin, cos} of angle (j + 0.5) pi / 2048, both
    /// positive, below 2^17, rounded to the nearest step of 1/107,922.
    #[test]
    fn table_is_a_half_offset_quarter_wave() {
        let t = table();
        for j in 0..512 {
            let (hi, lo) = (t[j] >> 18, t[j] & 0x3_FFFF);
            assert!(hi > 0 && hi < (1 << 17) && lo > 0 && lo < (1 << 17));
            let a = (j as f64 + 0.5) * std::f64::consts::PI / 2048.0;
            assert!((hi as f64 - 107_922.0 * a.sin()).abs() <= 0.5 + 1e-9);
            assert!((lo as f64 - 107_922.0 * a.cos()).abs() <= 0.5 + 1e-9);
        }
    }

    /// Against the ideal mix G x e^(j 2 pi phase / 2^32), G = 107922/2048: every output within
    /// 1.2 LSB (the RTL testbench sim/rx/tb_nco_mixer.v uses the same bound), latency LAT.
    #[test]
    fn matches_the_ideal_mix_within_bound() {
        let g = 107_922.0 / 2048.0;
        let mut m = Nco::default();
        let mut s = 12345u32;
        let freq: i32 = 0x1234_5679;
        let mut phase = 0u32;
        let mut want = Vec::new();
        let mut got = Vec::new();
        for _ in 0..20_000 {
            s ^= s << 13;
            s ^= s >> 17;
            s ^= s << 5;
            let x = ((s & 0xFFF) as i32) << 20 >> 20;
            let o = m.out();
            if o.out_strobe {
                got.push((o.out_i, o.out_q));
            }
            let th = 2.0 * std::f64::consts::PI * phase as f64 / 4_294_967_296.0;
            want.push((g * x as f64 * th.cos(), g * x as f64 * th.sin(), x));
            phase = phase.wrapping_add(freq as u32);
            m.step(false, true, freq, x);
        }
        // the output read before edge n (n >= LAT) belongs to sample n - LAT
        assert_eq!(got.len(), 20_000 - LAT as usize);
        for (k, &(oi, oq)) in got.iter().enumerate() {
            let (wi, wq, x) = want[k];
            let bound = 0.6 * (x.abs() as f64 / 2048.0) + 0.55;
            assert!(
                (oi as f64 - wi).abs() <= bound && (oq as f64 - wq).abs() <= bound,
                "sample {k}"
            );
        }
    }
}
