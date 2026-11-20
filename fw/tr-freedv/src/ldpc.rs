// SPDX-License-Identifier: LGPL-2.1-only
//
// Rust translation of parts of Codec 2 release 1.2.0 (https://github.com/drowe67/codec2):
// src/mpdecode_core.c (encode, init_c_v_nodes, SumProduct, run_ldpc_decoder, Demod2D, Somap,
// symbols_to_llrs), src/interldpc.c, src/gp_interleaver.c.
// Authors: Matthew C. Valenti, Rohit Iyer Seshadri, David Rowe. Copyright (C) 2006 Matthew C.
// Valenti (Iterative Solutions Coded Modulation Library), (C) 2016-2018 David Rowe.
// Modified 2026 by Franz Schöning, https://www.schoning.com: translated from C to Rust, fixed
// arrays instead of allocated node lists, exact phi function instead of the table.
//
// This program is free software; you can redistribute it and/or modify it under the terms of
// the GNU Lesser General Public License version 2.1, as published by the Free Software
// Foundation. This program is distributed in the hope that it will be useful, but WITHOUT ANY
// WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE. See the GNU Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public License along with this
// program; if not, see <http://www.gnu.org/licenses/>.

//! The two short rate-1/2 LDPC codes of FreeDV 700D (224,112) and 700E (112,56): encoder,
//! sum-product decoder, QPSK symbols to log likelihood ratios, and the symbol interleaver.

use crate::ldpc_tables::{HRA_112_112_H_ROWS, HRA_56_56_H_ROWS};
use crate::phi_table::{PHI_X, PHI_Y};
use tr_codec2::C32;

/// Longest codeword handled.
pub const MAX_CODE: usize = 224;
/// Most parity checks.
pub const MAX_PARITY: usize = 112;
/// Ones per check in the data part.
const ROW_WEIGHT: usize = 3;
/// Edges of the graph: per check 3 data bits and up to 2 parity bits.
const MAX_EDGES: usize = MAX_PARITY * (ROW_WEIGHT + 2);

/// A repeat-accumulate LDPC code: `h_rows` is the data part, the parity part is a double diagonal.
pub struct Code {
    pub name: &'static str,
    pub code_length: usize,
    pub parity_bits: usize,
    pub h_rows: &'static [u16],
    /// Golden-prime interleaver step for `code_length / 2` symbols.
    pub interleaver_b: usize,
    pub max_iter: usize,
}

impl Code {
    pub const fn data_bits(&self) -> usize {
        self.code_length - self.parity_bits
    }
}

/// FreeDV 700D.
pub static HRA_112_112: Code =
    Code { name: "HRA_112_112", code_length: 224, parity_bits: 112, h_rows: &HRA_112_112_H_ROWS, interleaver_b: 71, max_iter: 100 };
/// FreeDV 700E.
pub static HRA_56_56: Code =
    Code { name: "HRA_56_56", code_length: 112, parity_bits: 56, h_rows: &HRA_56_56_H_ROWS, interleaver_b: 37, max_iter: 100 };

/// Parity bits of `data` (one bit per byte).
pub fn encode(code: &Code, data: &[u8], parity: &mut [u8]) {
    let np = code.parity_bits;
    let mut prev = 0u8;
    for p in 0..np {
        let mut par = 0u8;
        for i in 0..ROW_WEIGHT {
            let ind = code.h_rows[p + i * np] as usize;
            if ind != 0 {
                par ^= data[ind - 1] & 1;
            }
        }
        prev ^= par;
        parity[p] = prev;
    }
}

/// phi(x) = ln((e^x + 1) / (e^x - 1)) by upstream's step table (`phi0.c`), so that the decoder
/// takes the same decisions as the reference on marginal frames. The table has regular steps from
/// 1.0 (1/16) and from 5.0 (1/2), found by index; below 1.0 the steps are geometric and a binary
/// search over 29 entries finds them.
#[inline]
fn phi0(x: f32) -> f32 {
    let k = (x * 65536.0) as i32;
    let k = if k < 0 { 0 } else { k as u32 };
    PHI_Y[phi_index(k)]
}

#[inline]
fn phi_index(k: u32) -> usize {
    if k >= 655_360 {
        PHI_X.len() - 1
    } else if k >= 327_680 {
        92 + ((k - 327_680) >> 15) as usize
    } else if k >= 65_536 {
        28 + ((k - 65_536) >> 12) as usize
    } else {
        PHI_X[..29].partition_point(|&t| t <= k) - 1
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The index arithmetic finds the same table entry as a search of the whole table, for every
    /// input from 0 to 12 (16.16 fixed point).
    #[test]
    fn phi_index_equals_a_full_search() {
        for k in 0..800_000u32 {
            assert_eq!(phi_index(k), PHI_X.partition_point(|&t| t <= k) - 1, "k = {k}");
        }
    }
}

/// Result of a decode.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct DecodeInfo {
    pub iterations: usize,
    /// Parity checks satisfied when the decoder stopped; equal to the code's `parity_bits` for a
    /// codeword.
    pub parity_checks: usize,
}

/// Sum-product decoder working memory (no heap): about 9 KB.
pub struct Decoder {
    /// For each check: first edge; edges of check `j` are `c_start[j]..c_start[j + 1]`.
    c_start: [u16; MAX_PARITY + 1],
    /// Variable of each edge.
    e_var: [u16; MAX_EDGES],
    /// For each variable: its edges.
    v_start: [u16; MAX_CODE + 1],
    v_edges: [u16; MAX_EDGES],
    /// Messages per edge: check to variable; variable to check (magnitude through phi, and sign).
    c_msg: [f32; MAX_EDGES],
    v_msg: [f32; MAX_EDGES],
    v_sign: [bool; MAX_EDGES],
    built_for: usize,
}

impl Default for Decoder {
    fn default() -> Self {
        Self::new()
    }
}

impl Decoder {
    pub const fn new() -> Self {
        Self {
            c_start: [0; MAX_PARITY + 1],
            e_var: [0; MAX_EDGES],
            v_start: [0; MAX_CODE + 1],
            v_edges: [0; MAX_EDGES],
            c_msg: [0.0; MAX_EDGES],
            v_msg: [0.0; MAX_EDGES],
            v_sign: [false; MAX_EDGES],
            built_for: 0,
        }
    }

    /// Builds the decoder in `slot` itself (all fields start at zero).
    pub fn init(slot: &mut core::mem::MaybeUninit<Self>) -> &mut Self {
        // SAFETY: every field is an integer, a float or a bool, and all-zero bytes are `new()`.
        unsafe {
            core::ptr::write_bytes(slot.as_mut_ptr(), 0, 1);
            slot.assume_init_mut()
        }
    }

    fn build(&mut self, code: &Code) {
        let np = code.parity_bits;
        let k = code.data_bits();
        let mut e = 0usize;
        for j in 0..np {
            self.c_start[j] = e as u16;
            for i in 0..ROW_WEIGHT {
                let ind = code.h_rows[j + i * np];
                if ind != 0 {
                    self.e_var[e] = ind - 1;
                    e += 1;
                }
            }
            if j > 0 {
                self.e_var[e] = (k + j - 1) as u16;
                e += 1;
            }
            self.e_var[e] = (k + j) as u16;
            e += 1;
        }
        self.c_start[np] = e as u16;
        // edges per variable
        let n = code.code_length;
        let mut count = [0u16; MAX_CODE];
        for &v in self.e_var[..e].iter() {
            count[v as usize] += 1;
        }
        let mut acc = 0u16;
        for i in 0..n {
            self.v_start[i] = acc;
            acc += count[i];
            count[i] = 0;
        }
        self.v_start[n] = acc;
        for (edge, &v) in self.e_var[..e].iter().enumerate() {
            let v = v as usize;
            self.v_edges[(self.v_start[v] + count[v]) as usize] = edge as u16;
            count[v] += 1;
        }
        self.built_for = code.code_length;
    }

    /// Decodes `llr` (positive = bit 0) into `out` (the whole codeword, data bits first).
    pub fn decode(&mut self, code: &Code, llr: &[f32], out: &mut [u8]) -> DecodeInfo {
        let n = code.code_length;
        let np = code.parity_bits;
        debug_assert!(llr.len() >= n && out.len() >= n);
        if self.built_for != n {
            self.build(code);
        }
        let edges = self.c_start[np] as usize;
        for e in 0..edges {
            let x = llr[self.e_var[e] as usize];
            self.v_msg[e] = phi0(libm::fabsf(x));
            self.v_sign[e] = x < 0.0;
        }
        let mut info = DecodeInfo { iterations: code.max_iter, parity_checks: 0 };
        for iter in 0..code.max_iter {
            // checks
            let mut ssum = 0;
            for j in 0..np {
                let (a, b) = (self.c_start[j] as usize, self.c_start[j + 1] as usize);
                let mut sign = false;
                let mut phi_sum = 0.0f32;
                for e in a..b {
                    phi_sum += self.v_msg[e];
                    sign ^= self.v_sign[e];
                }
                if !sign {
                    ssum += 1;
                }
                for e in a..b {
                    let m = phi0(phi_sum - self.v_msg[e]);
                    self.c_msg[e] = if sign ^ self.v_sign[e] { -m } else { m };
                }
            }
            // variables
            let mut data_all_zero = true;
            for i in 0..n {
                let (a, b) = (self.v_start[i] as usize, self.v_start[i + 1] as usize);
                let mut qi = llr[i];
                for &e in self.v_edges[a..b].iter() {
                    qi += self.c_msg[e as usize];
                }
                out[i] = (qi < 0.0) as u8;
                if i < n - np && out[i] != 0 {
                    data_all_zero = false;
                }
                for &e in self.v_edges[a..b].iter() {
                    let t = qi - self.c_msg[e as usize];
                    self.v_msg[e as usize] = phi0(libm::fabsf(t));
                    self.v_sign[e as usize] = t <= 0.0;
                }
            }
            // upstream stops on all-zero data before it stores the check count
            if data_all_zero {
                info.iterations = iter + 1;
                break;
            }
            info.parity_checks = ssum;
            if ssum == np {
                info.iterations = iter + 1;
                break;
            }
        }
        info
    }
}

// Upstream's constants are doubles and `max_star0` computes in double (the operands are floats,
// the constants are not), returning a float. The error correction is sensitive enough that frames
// it cannot decode come out with different bits if this is done in `f32`.
const AJIAN: f64 = -0.249_041_631_954_36;
const TJIAN: f64 = 2.506_817_404_209_44;

/// The linear-log-MAP approximation of ln(e^a + e^b).
#[inline]
fn max_star0(delta1: f32, delta2: f32) -> f32 {
    let diff = (delta2 - delta1) as f64;
    if diff > TJIAN {
        delta2
    } else if diff < -TJIAN {
        delta1
    } else if diff > 0.0 {
        (delta2 as f64 + AJIAN * (diff - TJIAN)) as f32
    } else {
        (delta1 as f64 - AJIAN * (diff + TJIAN)) as f32
    }
}

/// QPSK constellation in the order of the two bits (first bit is the high bit of the index).
pub const QPSK: [C32; 4] = [C32::new(1.0, 0.0), C32::new(0.0, 1.0), C32::new(0.0, -1.0), C32::new(-1.0, 0.0)];

/// Log likelihood ratios (positive = bit 0) of QPSK symbols with their amplitude estimates.
pub fn symbols_to_llrs(llr: &mut [f32], syms: &[C32], amps: &[f32], es_no: f32, mean_amp: f32) {
    let mean_amp = if mean_amp > 1e-12 { mean_amp } else { 1e-12 };
    for (n, (s, &fade)) in syms.iter().zip(amps.iter()).enumerate() {
        let mut num = [-1_000_000.0f32; 2];
        let mut den = [-1_000_000.0f32; 2];
        for (i, c) in QPSK.iter().enumerate() {
            let er = s.re / mean_amp - fade * c.re / mean_amp;
            let ei = s.im / mean_amp - fade * c.im / mean_amp;
            let metric = -es_no * (er * er + ei * ei);
            for k in 0..2 {
                if i & (2 >> k) != 0 {
                    num[k] = max_star0(num[k], metric);
                } else {
                    den[k] = max_star0(den[k], metric);
                }
            }
        }
        llr[2 * n] = -(num[0] - den[0]);
        llr[2 * n + 1] = -(num[1] - den[1]);
    }
}

/// Golden-prime interleaver: `out[(b i) mod n] = input[i]`.
pub fn interleave<T: Copy>(out: &mut [T], input: &[T], b: usize) {
    let n = input.len();
    for i in 0..n {
        out[(b * i) % n] = input[i];
    }
}

/// Inverse of [`interleave`].
pub fn deinterleave<T: Copy>(out: &mut [T], input: &[T], b: usize) {
    let n = input.len();
    for i in 0..n {
        out[i] = input[(b * i) % n];
    }
}
