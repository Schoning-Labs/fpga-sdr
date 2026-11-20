// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Tests of the two kernels that the vendored mfsk-core carries in rewritten form (fw/vendor/VENDOR_PATCH.md
//! fix 8): each must return exactly what mfsk-core's own code returns.
//!
//! - LLRs: `compute_llr`, `compute_llr_fast` and `compute_llr_partial` (square root of the maxima only, pairwise
//!   maximum reduction) against the reference bit metrics (`compute_llr_reference`), bit for bit, on soft symbols
//!   of random tone sequences over a range of signal levels, including ties.
//! - Belief propagation: the fused normalized min-sum kernel against `bp_decode_nms_with_scratch` (result,
//!   codeword, hard errors and iteration count), with and without an a-priori mask, in `f32` and in Q11 fixed
//!   point, over a noise range where both outcomes occur.
//! - Decoding ladder: with belief propagation in the a-priori passes done as min-sum (the default) the ladder
//!   must decode the same messages as with WSJT-X's sum-product (`apbp=sp`), on the three WSJT-X sample
//!   recordings at 30 and 60 candidates and with one and two passes. This test skips when the recordings are
//!   missing (`tools/fetch_test_audio.sh` fetches them).

use mfsk_core::engine::scalar::{Cmplx, LlrScalar, Q11i16};
use mfsk_core::fec::ldpc::bp::{bp_decode_nms_with_scratch, BpResult, BpScratch};
use mfsk_core::fec::ldpc::bp_fast::bp_decode_nms_fast;
use mfsk_core::fec::ldpc::osd::ldpc_encode;
use mfsk_core::fec::ldpc::{check_crc14, crc14, Ldpc174_91Params};
use mfsk_core::ft8::llr::{compute_llr, compute_llr_fast, compute_llr_partial, compute_llr_reference};
use mfsk_core::msg::wsjt77::unpack77;
use tr_modes::frontend::decode::{decode_slot, DecodeParams, ModelFabric};
use tr_modes::frontend::effort::parse_effort;
use tr_modes::frontend::{Arith, SLOT_LEN};

const N: usize = 174;
const K: usize = 91;

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
    ldpc_encode(&info)
}

/// Bit patterns of the values, so that comparisons are exact and `NaN` safe.
fn bits(v: &[f32; N]) -> Vec<u32> {
    v.iter().map(|x| x.to_bits()).collect()
}

#[test]
fn fast_llr_equals_reference() {
    let mut n = 0;
    for seed in 0..300u64 {
        let mut r = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1);
        let amp = 0.2 + (seed % 12) as f32 * 0.3;
        let quantise = seed % 5 == 0; // integer soft symbols, as the fabric delivers them, which gives ties
        let mut cs = [[Cmplx::new(0.0f32, 0.0); 8]; 79];
        for row in cs.iter_mut() {
            let tone = (r.next() * 8.0) as usize % 8;
            for (t, c) in row.iter_mut().enumerate() {
                let (mut re, mut im) = (r.gauss() + if t == tone { amp * 3.0 } else { 0.0 }, r.gauss());
                if quantise {
                    re = (re * 4.0).round();
                    im = (im * 4.0).round();
                }
                *c = Cmplx::new(re, im);
            }
        }
        let want = compute_llr_reference::<f32>(&cs);
        let got = compute_llr::<f32>(&cs);
        assert_eq!(bits(&got.llra), bits(&want.llra), "llra, seed {seed}");
        assert_eq!(bits(&got.llrb), bits(&want.llrb), "llrb, seed {seed}");
        assert_eq!(bits(&got.llrc), bits(&want.llrc), "llrc, seed {seed}");
        assert_eq!(bits(&got.llrd), bits(&want.llrd), "llrd, seed {seed}");
        let fast = compute_llr_fast::<f32>(&cs);
        assert_eq!(bits(&fast.llra), bits(&want.llra), "fast llra, seed {seed}");
        assert_eq!(bits(&fast.llrd), bits(&want.llrd), "fast llrd, seed {seed}");
        assert_eq!(bits(&compute_llr_partial::<f32>(&cs, 2)), bits(&want.llrb), "partial 2, seed {seed}");
        assert_eq!(bits(&compute_llr_partial::<f32>(&cs, 3)), bits(&want.llrc), "partial 3, seed {seed}");
        n += 1;
    }
    eprintln!("{n} soft-symbol sets, all four variants identical");
}

/// True when both decodes gave the same result in every field, or both gave nothing.
fn same(a: &Option<BpResult>, b: &Option<BpResult>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(a), Some(b)) => {
            a.message77 == b.message77 && a.info == b.info && a.codeword == b.codeword && a.hard_errors == b.hard_errors && a.iterations == b.iterations
        }
        _ => false,
    }
}

/// Runs 600 random noisy codewords through the reference and the fused min-sum kernel in scalar type `T` and
/// asserts identical results. Returns how many failed and how many decoded, so the caller can check that both
/// outcomes occurred.
fn compare<T: LlrScalar>(label: &str) -> [usize; 2] {
    let mut ref_scratch = BpScratch::<Ldpc174_91Params, T>::new();
    let mut fast_scratch = BpScratch::<Ldpc174_91Params, T>::new();
    let mut outcomes = [0usize; 2];
    for seed in 0..600u64 {
        let mut r = Rng(seed.wrapping_mul(0x2545_F491_4F6C_DD1D) | 1);
        let cw = codeword(&mut r);
        let sigma = 0.6 + (seed % 20) as f32 * 0.04;
        let llr_f: [f32; N] = core::array::from_fn(|i| {
            let s = if cw[i] == 1 { 1.0 } else { -1.0 };
            2.0 * (s + sigma * r.gauss()) / (sigma * sigma)
        });
        let llr: [T; N] = core::array::from_fn(|i| T::from_f32(llr_f[i]));
        // An a-priori mask on every third seed: 29 bits locked to their true values at the largest LLR magnitude, as
        // the blind CQ pass does.
        let apmag = llr_f.iter().fold(0.0f32, |m, v| m.max(v.abs())) * 1.01;
        let mut mask = [false; N];
        let mut llr_ap = llr;
        if seed % 3 == 0 {
            for i in 0..29 {
                mask[i] = true;
                llr_ap[i] = T::from_f32(if cw[i] == 1 { apmag } else { -apmag });
            }
        }
        let m = (seed % 3 == 0).then_some(&mask);
        let a = bp_decode_nms_with_scratch::<T>(&mut ref_scratch, &llr_ap, m, 30, Some(check_crc14), 0.75);
        let b = bp_decode_nms_fast::<T>(&mut fast_scratch, &llr_ap, m, 30, Some(check_crc14), 0.75);
        assert!(same(&a, &b), "{label}: seed {seed}, sigma {sigma}");
        outcomes[a.is_some() as usize] += 1;
    }
    eprintln!("{label}: {} failed, {} decoded, all identical", outcomes[0], outcomes[1]);
    outcomes
}

#[test]
fn fast_min_sum_equals_reference() {
    for o in [compare::<f32>("f32"), compare::<Q11i16>("Q11")] {
        assert!(o[0] > 50 && o[1] > 50, "noise range must give both outcomes: {o:?}");
    }
}

/// Reports a skipped test on the real standard error, because the test harness hides what a passing test prints
/// with `eprintln!` and a missing `captures/` folder would otherwise look like a pass. Setting
/// `TR_REQUIRE_RECORDINGS=1` turns the skip into a failure.
fn skipped(what: &str) {
    use std::io::Write;
    let name = std::thread::current().name().unwrap_or("?").to_string();
    let _ = writeln!(std::io::stderr(), "SKIPPED {name}: {what} -- run tools/fetch_test_audio.sh");
    assert!(std::env::var_os("TR_REQUIRE_RECORDINGS").is_none(), "recordings missing and TR_REQUIRE_RECORDINGS is set");
}

/// Loads `captures/ft8/<name>.wav` as one 15 s slot (padded with zeros), or `None` when the file is absent.
fn load(name: &str) -> Option<Vec<i16>> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(format!("../../captures/ft8/{name}.wav"));
    let bytes = std::fs::read(&path).ok()?;
    let mut i = 12usize;
    let (mut off, mut len) = (0usize, 0usize);
    while i + 8 <= bytes.len() {
        let l = u32::from_le_bytes(bytes[i + 4..i + 8].try_into().ok()?) as usize;
        if &bytes[i..i + 4] == b"data" {
            off = i + 8;
            len = l.min(bytes.len() - off);
        }
        i += 8 + l + (l & 1);
    }
    let mut v: Vec<i16> = bytes[off..off + len].chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect();
    v.resize(SLOT_LEN, 0);
    Some(v)
}

/// Sorted message texts decoded from one slot by the fixed point model fabric.
fn messages(audio: &[i16], p: &DecodeParams) -> Vec<String> {
    let mut fab = ModelFabric::new(Arith::Fixed);
    let (d, _) = decode_slot(&mut fab, audio, p, &|| 0);
    let mut m: Vec<String> = d.iter().map(|x| unpack77(x.result.message77()).unwrap_or_default()).collect();
    m.sort();
    m
}

#[test]
fn min_sum_a_priori_decodes_the_same_messages() {
    let mut ran = 0;
    for name in ["qso3_busy", "qso1", "qso2"] {
        let Some(audio) = load(name) else {
            skipped(&format!("{name}: not found"));
            continue;
        };
        for (max_cand, passes) in [(30, 1), (60, 1), (60, 2)] {
            let new = DecodeParams { max_cand, passes, ..DecodeParams::default() };
            let old = DecodeParams { effort: parse_effort("full,apbp=sp").unwrap(), ..new };
            let (a, b) = (messages(&audio, &new), messages(&audio, &old));
            assert_eq!(a, b, "{name} {max_cand} candidates, {passes} pass(es)");
            eprintln!("{name} {max_cand}/{passes}: {} messages, same", a.len());
            ran += 1;
        }
    }
    eprintln!("{ran} comparisons");
}
