// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Checks that the bit-packed OSD of the vendored mfsk-core (`fec::ldpc::osd_fast`, fw/vendor/VENDOR_PATCH.md
//! fix 7) returns exactly what the reference OSD returns (information bits, codeword, hard errors, or nothing)
//! for the three searches the FT8 ladder uses: npre1 (WSJT-X ndeep 2), npre1 plus npre2 (ndeep 3) and the
//! unpruned order-2 search of the a-priori passes.
//!
//! The inputs are noisy LLRs of random valid codewords over a noise range where both outcomes occur, the same
//! LLRs refined by belief propagation (which is what the ladder feeds to OSD), and LLRs with ties and zeros.

use mfsk_core::fec::ldpc::bp::bp_llr_zsum;
use mfsk_core::fec::ldpc::osd::{ldpc_encode, osd_decode_deep, osd_decode_npre1, osd_decode_npre1_npre2, OsdResult};
use mfsk_core::fec::ldpc::osd_fast::{osd_decode_deep2_crc_fast, osd_decode_npre1_fast, osd_decode_npre1_npre2_fast};
use mfsk_core::fec::ldpc::{check_crc14, crc14, Ldpc174_91Params};
// Links tr-modes' FFT behind mfsk-core's `fft-extern` hook (unused here, but the library needs it).
use tr_modes as _;

const N: usize = 174;
const K: usize = 91;

/// True when both searches gave the same result, down to the last field, or both gave nothing.
fn same(a: &Option<OsdResult>, b: &Option<OsdResult>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(a), Some(b)) => a.info == b.info && a.codeword == b.codeword && a.hard_errors == b.hard_errors && a.message77 == b.message77,
        _ => false,
    }
}

/// Small xorshift generator, so the test inputs are the same on every run and every machine.
struct Rng(u64);
impl Rng {
    /// Uniform value in [0, 1).
    fn next(&mut self) -> f32 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        ((self.0 >> 11) as f64 / (1u64 << 53) as f64) as f32
    }
    /// Standard normal value (Box-Muller).
    fn gauss(&mut self) -> f32 {
        let (u1, u2) = (self.next().max(1e-9), self.next());
        (-2.0 * u1.ln()).sqrt() * (2.0 * core::f32::consts::PI * u2).cos()
    }
}

/// A random FT8 codeword: 77 message bits, the CRC-14 over them, then the LDPC(174,91) encoding.
fn codeword(r: &mut Rng) -> [u8; N] {
    let mut info = [0u8; K];
    for b in info.iter_mut().take(77) {
        *b = (r.next() < 0.5) as u8;
    }
    let mut bytes = [0u8; 12];
    for i in 0..77 {
        bytes[i / 8] |= info[i] << (7 - i % 8);
    }
    let c = crc14(&bytes);
    for i in 0..14 {
        info[77 + i] = ((c >> (13 - i)) & 1) as u8;
    }
    assert!(check_crc14(&info));
    ldpc_encode(&info)
}

/// LLRs of a random codeword after a BPSK channel with Gaussian noise of standard deviation `sigma`.
fn noisy(seed: u64, sigma: f32) -> [f32; N] {
    let mut r = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1);
    let cw = codeword(&mut r);
    core::array::from_fn(|i| {
        let s = if cw[i] == 1 { 1.0 } else { -1.0 };
        2.0 * (s + sigma * r.gauss()) / (sigma * sigma)
    })
}

#[test]
fn packed_osd_equals_reference() {
    let mut hits = [0usize; 3];
    let mut n = 0;
    for seed in 0..400u64 {
        let sigma = 0.55 + (seed % 16) as f32 * 0.05;
        let raw = noisy(seed, sigma);
        // Channel LLRs, the ladder's BP-refined seeds, and a quantized copy (ties in |LLR|).
        let z1: [f32; N] = bp_llr_zsum::<Ldpc174_91Params>(&raw, 1).try_into().unwrap();
        let z2: [f32; N] = bp_llr_zsum::<Ldpc174_91Params>(&raw, 2).try_into().unwrap();
        let q: [f32; N] = core::array::from_fn(|i| (raw[i] * 2.0).round() / 2.0);
        for l in [raw, z1, z2, q] {
            n += 1;
            let a = osd_decode_npre1(&l);
            assert!(same(&a, &osd_decode_npre1_fast(&l)), "npre1, seed {seed}, sigma {sigma}");
            hits[0] += a.is_some() as usize;
            let b = osd_decode_npre1_npre2(&l);
            assert!(same(&b, &osd_decode_npre1_npre2_fast(&l)), "npre1+npre2, seed {seed}, sigma {sigma}");
            hits[1] += b.is_some() as usize;
            if seed % 4 == 0 {
                let c = osd_decode_deep(&l, 2, Some(check_crc14));
                assert!(same(&c, &osd_decode_deep2_crc_fast(&l)), "order 2, seed {seed}, sigma {sigma}");
                hits[2] += c.is_some() as usize;
            }
        }
    }
    eprintln!("{n} LLR vectors; decoded npre1 {}, npre2 {}, order-2 {}", hits[0], hits[1], hits[2]);
    // The noise range must give both outcomes, or the comparison proves little.
    assert!(hits[0] > n / 10 && hits[0] < n * 9 / 10, "{hits:?}");
    assert!(hits[1] > hits[0] / 2, "{hits:?}");
    assert!(hits[2] > 20, "{hits:?}");
}
