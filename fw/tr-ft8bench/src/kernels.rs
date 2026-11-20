// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The QEMU program that measures the kernels of the FT8 back end one by one, as instructions retired
//! (`minstret`, with QEMU at `-icount shift=0`), for the study of which of them to move into the FPGA
//! (docs/FT8_OFFLOAD.md). The kernels are the conversion of soft symbols to log-likelihood ratios (LLRs),
//! one normalized min-sum belief propagation (the first two steps of the decoding ladder), one sum-product
//! belief propagation (used by the a-priori passes in their original form), the OSD seeds refined by belief
//! propagation, and each OSD search in the reference form of `mfsk-core` and in its bit-packed form. The
//! rewritten LLR kernel and the fused min-sum kernel are measured next to the ones they replace, in `f32` and in
//! the fixed-point `Q11i16` type, with each result checked to be equal, and the cost per failed candidate is
//! summed up at the end.
//!
//! The inputs are noisy LLRs of random valid codewords at a noise level where belief propagation fails (the
//! case that OSD exists for), made by the same generator as `tr-modes/tests/fo1_osd_fast.rs`. Every packed
//! result is checked against the reference result, and a mismatch stops the program with a panic.
//! tools/qemu_fo1_kernels.sh runs it and reads the `KERNEL` lines.

#![no_std]
#![no_main]

extern crate alloc;

#[path = "rt.rs"]
mod rt;
const HEAP_BYTES: usize = 20 << 20;

use core::fmt::Write as _;

use mfsk_core::engine::scalar::{Cmplx, LlrScalar, Q11i16};
use mfsk_core::fec::ldpc::bp::{bp_decode, bp_decode_nms_with_scratch, bp_llr_zsum, BpResult, BpScratch};
use mfsk_core::fec::ldpc::bp_fast::bp_decode_nms_fast;
use mfsk_core::fec::ldpc::osd::{ldpc_encode, osd_decode_deep, osd_decode_npre1, osd_decode_npre1_npre2, OsdResult};
use mfsk_core::fec::ldpc::osd_fast::{osd_decode_deep2_crc_fast, osd_decode_npre1_fast, osd_decode_npre1_npre2_fast};
use mfsk_core::fec::ldpc::{check_crc14, crc14, Ldpc174_91Params};
use riscv_rt::entry;
use tr_ae350::board::qemu;
use tr_ae350::uart;

/// Code length and information bits (77 message bits and the 14-bit CRC) of the FT8 LDPC code.
const N: usize = 174;
const K: usize = 91;
/// Failing candidates to measure: a candidate counts only when belief propagation could not decode it.
const TRIALS: u64 = 12;

/// A small xorshift64 generator with Gaussian noise, so that the benchmark needs no `rand` crate and every run
/// sees the same inputs.
struct Rng(u64);
impl Rng {
    /// Next uniform number in [0, 1).
    fn next(&mut self) -> f32 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        ((self.0 >> 11) as f64 / (1u64 << 53) as f64) as f32
    }
    /// Next Gaussian number of unit variance (Box-Muller).
    fn gauss(&mut self) -> f32 {
        let (u1, u2) = (self.next().max(1e-9), self.next());
        libm::sqrtf(-2.0 * libm::logf(u1)) * libm::cosf(2.0 * core::f32::consts::PI * u2)
    }
}

/// Makes a random valid codeword (77 random message bits, CRC-14, LDPC encoding) and returns its LLRs after
/// BPSK transmission over Gaussian noise of standard deviation `sigma`, together with the codeword.
fn noisy(seed: u64, sigma: f32) -> ([f32; N], [u8; N]) {
    let mut r = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1);
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
    let cw = ldpc_encode(&info);
    (core::array::from_fn(|i| 2.0 * (if cw[i] == 1 { 1.0 } else { -1.0 } + sigma * r.gauss()) / (sigma * sigma)), cw)
}

/// True when two belief propagation results are equal in codeword, hard errors and iteration count.
fn same_bp(a: &Option<BpResult>, b: &Option<BpResult>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(a), Some(b)) => a.codeword == b.codeword && a.hard_errors == b.hard_errors && a.iterations == b.iterations,
        _ => false,
    }
}

/// True when two OSD results are equal in information bits, codeword and hard errors.
fn same(a: &Option<OsdResult>, b: &Option<OsdResult>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(a), Some(b)) => a.info == b.info && a.codeword == b.codeword && a.hard_errors == b.hard_errors,
        _ => false,
    }
}

/// Measures every kernel on `TRIALS` candidates that belief propagation fails on, prints one `KERNEL` line per
/// kernel (mean instructions per call) and a `PER_FAILED_CANDIDATE` line, then exits QEMU with a pass status.
#[entry]
fn main() -> ! {
    let mut con = &uart::CONSOLE;
    con.init(24_000_000, 115_200);
    // The FPU has to be on before the first f32 instruction, or the core traps.
    unsafe { tr_ae350::fpu::enable() };
    let _ = writeln!(con, "fpga-sdr FO1 FT8 back-end kernels (QEMU), {TRIALS} failing candidates");
    // One entry per kernel: name, total instructions, calls. The index of an entry is the number the `add`
    // calls below use, and the entries are printed in this order.
    let mut acc: [(&str, u64, u64); 16] = [
        ("llr_from_soft_symbols", 0, 0),
        ("bp_min_sum_30_iter", 0, 0),
        ("bp_sum_product_30_iter", 0, 0),
        ("osd_seed_1_iter", 0, 0),
        ("osd_seed_2_iter", 0, 0),
        ("osd_npre1_reference", 0, 0),
        ("osd_npre1_packed", 0, 0),
        ("osd_npre1_npre2_reference", 0, 0),
        ("osd_npre1_npre2_packed", 0, 0),
        ("osd_order2_crc_reference", 0, 0),
        ("osd_order2_crc_packed", 0, 0),
        ("fo3_llr_from_soft_symbols", 0, 0),
        ("fo3_bp_min_sum_fused", 0, 0),
        ("q11_bp_min_sum_30_iter", 0, 0),
        ("q11_fo3_bp_min_sum_fused", 0, 0),
        ("fo3_llr_nsym1_a_d", 0, 0),
    ];
    let mut add = |k: usize, t: u64| {
        acc[k].1 += t;
        acc[k].2 += 1;
    };
    let mut scratch = BpScratch::<Ldpc174_91Params, f32>::new();
    let mut scratch_q = BpScratch::<Ldpc174_91Params, Q11i16>::new();
    let mut seed = 0u64;
    let mut done = 0u64;
    let mut osd_hits = 0u64;
    while done < TRIALS {
        seed += 1;
        // sigma = 0.95 is a noise level at which belief propagation usually fails.
        let (llr, cw) = noisy(seed, 0.95);
        // Soft symbols from the codeword's tones, so the LLR kernel sees realistic input: 79 symbols of eight
        // tone bins each, with the transmitted tone raised above the noise.
        let mut cs = [[Cmplx::new(0.0f32, 0.0); 8]; 79];
        let mut r = Rng(seed | 3);
        for s in 0..79 {
            let tone = (cw[(s * 3) % N] as usize) * 4 + (cw[(s * 3 + 1) % N] as usize) * 2 + cw[(s * 3 + 2) % N] as usize;
            for t in 0..8 {
                cs[s][t] = Cmplx::new(r.gauss() + if t == tone { 1.5 } else { 0.0 }, r.gauss());
            }
        }
        let t0 = rt::instret();
        let l = mfsk_core::ft8::llr::compute_llr_reference::<f32>(&cs);
        let t_llr_ref = rt::instret() - t0;
        core::hint::black_box(&l);
        let t0 = rt::instret();
        let lf = mfsk_core::ft8::llr::compute_llr::<f32>(&cs);
        let t_llr_fast = rt::instret() - t0;
        assert!(lf.llra == l.llra && lf.llrb == l.llrb && lf.llrc == l.llrc && lf.llrd == l.llrd, "LLR mismatch, seed {seed}");
        let t0 = rt::instret();
        core::hint::black_box(mfsk_core::ft8::llr::compute_llr_fast::<f32>(&cs));
        let t_llr_ad = rt::instret() - t0;

        let t0 = rt::instret();
        let bp = bp_decode_nms_with_scratch::<f32>(&mut scratch, &llr, None, 30, Some(check_crc14), 0.75);
        let t_nms = rt::instret() - t0;
        if bp.is_some() {
            continue; // only candidates belief propagation cannot decode
        }
        add(0, t_llr_ref);
        add(11, t_llr_fast);
        add(15, t_llr_ad);
        add(1, t_nms);
        let t0 = rt::instret();
        let bpf = bp_decode_nms_fast::<f32>(&mut scratch, &llr, None, 30, Some(check_crc14), 0.75);
        add(12, rt::instret() - t0);
        assert!(same_bp(&bp, &bpf), "min-sum mismatch, seed {seed}");
        let llr_q: [Q11i16; N] = core::array::from_fn(|i| Q11i16::from_f32(llr[i]));
        let t0 = rt::instret();
        let a = bp_decode_nms_with_scratch::<Q11i16>(&mut scratch_q, &llr_q, None, 30, Some(check_crc14), 0.75);
        add(13, rt::instret() - t0);
        let t0 = rt::instret();
        let b = bp_decode_nms_fast::<Q11i16>(&mut scratch_q, &llr_q, None, 30, Some(check_crc14), 0.75);
        add(14, rt::instret() - t0);
        assert!(same_bp(&a, &b), "Q11 min-sum mismatch, seed {seed}");
        let t0 = rt::instret();
        core::hint::black_box(bp_decode(&llr, None, 30, Some(check_crc14)));
        add(2, rt::instret() - t0);
        let t0 = rt::instret();
        let z1: [f32; N] = bp_llr_zsum::<Ldpc174_91Params>(&llr, 1).try_into().unwrap();
        add(3, rt::instret() - t0);
        let t0 = rt::instret();
        let z2: [f32; N] = bp_llr_zsum::<Ldpc174_91Params>(&llr, 2).try_into().unwrap();
        add(4, rt::instret() - t0);
        for z in [z1, z2] {
            let t0 = rt::instret();
            let a = osd_decode_npre1(&z);
            add(5, rt::instret() - t0);
            let t0 = rt::instret();
            let b = osd_decode_npre1_fast(&z);
            add(6, rt::instret() - t0);
            assert!(same(&a, &b), "npre1 mismatch, seed {seed}");
            osd_hits += a.is_some() as u64;
            let t0 = rt::instret();
            let a = osd_decode_npre1_npre2(&z);
            add(7, rt::instret() - t0);
            let t0 = rt::instret();
            let b = osd_decode_npre1_npre2_fast(&z);
            add(8, rt::instret() - t0);
            assert!(same(&a, &b), "npre2 mismatch, seed {seed}");
        }
        let t0 = rt::instret();
        let a = osd_decode_deep(&llr, 2, Some(check_crc14));
        add(9, rt::instret() - t0);
        let t0 = rt::instret();
        let b = osd_decode_deep2_crc_fast(&llr);
        add(10, rt::instret() - t0);
        assert!(same(&a, &b), "order-2 mismatch, seed {seed}");
        done += 1;
    }
    for (name, tot, n) in acc.iter().filter(|a| a.2 > 0) {
        let _ = writeln!(con, "KERNEL {name} calls={n} mean_instr={}", tot / n);
    }
    // Per failed candidate of the full ladder: the LLR set and four min-sum runs (the first two steps), plus the
    // four belief propagation runs of the blind-CQ a-priori pass (sum-product in the original form, min-sum in
    // the rewritten one); "before" and "after" refer to the original and the rewritten kernels.
    let m = |k: usize| acc[k].1 / acc[k].2.max(1);
    let (old12, new12) = (m(0) + 4 * m(1), m(11) + 4 * m(12));
    let (old_ap, new_ap) = (old12 + 4 * m(2), new12 + 4 * m(12));
    let _ = writeln!(con, "PER_FAILED_CANDIDATE steps12_before={old12} steps12_after={new12} with_ap_before={old_ap} with_ap_after={new_ap}");
    let _ = writeln!(con, "candidates tried {seed}, BP failures measured {done}, OSD searches that found a codeword {osd_hits}");
    let _ = writeln!(con, "FO1 kernels done");
    qemu::exit_pass();
}
