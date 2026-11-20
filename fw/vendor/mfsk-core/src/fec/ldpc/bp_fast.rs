//! Fused normalised min-sum belief propagation, bit-identical to
//! [`super::bp::bp_decode_generic_nms_with_scratch`].
//!
//! [fpga-sdr vendor patch, fix 8 in `fw/vendor/VENDOR_PATCH.md`; modified 2026 by Franz
//! Schöning] The reference kernel spends most of its time finding things again on every
//! iteration: the check-to-variable update scans each check row to find the slot of the
//! variable it is updating, the variable-to-check update scans each variable's three checks, and
//! the parity check re-reads every row. This kernel precomputes the pairing once per scratch
//! (`BpScratch::edge_var`, `edge_tov`) and does one pass over the rows per iteration:
//!
//! 1. variable beliefs `zn` (the same sums in the same order: `llr + tov0 + tov1 + tov2`, or the
//!    bare LLR for a-priori-locked bits);
//! 2. per check row: parity of the hard decisions, variable-to-check messages `zn - tov`, their
//!    sign product and two smallest magnitudes, then straight away the new check-to-variable
//!    messages for the same row's edges. Each `tov` entry belongs to exactly one edge, so a row
//!    reads only the previous iteration's values of its own edges and the flooding schedule is
//!    unchanged.
//!
//! The iteration's decision (parity zero and CRC, then the stall detector) is taken after the
//! row pass instead of before the message update; when it returns, the messages it computed are
//! simply dropped, so the result, the iteration count and the hard-error count are identical to
//! the reference's on every input (tested in fpga-sdr `fw/tr-modes/tests/fo3_kernels.rs`).

use alloc::vec;

use super::bp::{BpResult, BpScratch};
use super::params::LdpcParams;
use crate::engine::scalar::LlrScalar;

const NCW: usize = 3;

/// [`super::bp::bp_decode_generic_nms_with_scratch`], same arguments, same result.
pub fn bp_decode_nms_fast_with_scratch<P: LdpcParams, T: LlrScalar>(
    scratch: &mut BpScratch<P, T>,
    llr: &[T],
    ap_mask: Option<&[bool]>,
    max_iter: u32,
    verify: Option<fn(&[u8]) -> bool>,
    alpha: f32,
) -> Option<BpResult> {
    let n = P::N;
    let m_checks = P::M;
    let k = P::K;
    let max_row = P::MAX_ROW;
    debug_assert_eq!(llr.len(), n);
    let llr = &llr[..n];
    let BpScratch { tov, toc, zn, cw, edge_var, edge_tov, .. } = scratch;
    let tov = &mut tov[..n * NCW];
    let zn = &mut zn[..n];
    for v in tov.iter_mut() {
        *v = T::ZERO;
    }

    let mut ncnt = 0u32;
    let mut nclast = 0u32;
    for iter in 0..=max_iter {
        // 1. Beliefs.
        match ap_mask {
            None => {
                for (i, z) in zn.iter_mut().enumerate() {
                    let t = &tov[i * NCW..i * NCW + NCW];
                    let mut sum = llr[i].to_wide();
                    sum = T::wide_add(sum, t[0].to_wide());
                    sum = T::wide_add(sum, t[1].to_wide());
                    sum = T::wide_add(sum, t[2].to_wide());
                    *z = sum;
                }
            }
            Some(mask) => {
                for (i, z) in zn.iter_mut().enumerate() {
                    if mask[i] {
                        *z = llr[i].to_wide();
                    } else {
                        let t = &tov[i * NCW..i * NCW + NCW];
                        let mut sum = llr[i].to_wide();
                        sum = T::wide_add(sum, t[0].to_wide());
                        sum = T::wide_add(sum, t[1].to_wide());
                        sum = T::wide_add(sum, t[2].to_wide());
                        *z = sum;
                    }
                }
            }
        }

        // 2. Rows: parity, variable-to-check, min-sum, check-to-variable.
        let mut ncheck = 0u32;
        for j in 0..m_checks {
            let nrw = P::nrw(j) as usize;
            let base = j * max_row;
            let ev = &edge_var[base..base + nrw];
            let et = &edge_tov[base..base + nrw];
            let row = &mut toc[base..base + nrw];
            let mut parity = false;
            let mut sx = false;
            let mut m1 = T::POS_INF_LIKE;
            let mut m2 = T::POS_INF_LIKE;
            let mut imin = 0usize;
            for s in 0..nrw {
                let z = zn[ev[s] as usize];
                parity ^= T::wide_is_positive(z);
                let v = T::from_wide_sat(T::wide_sub(z, tov[et[s] as usize].to_wide()));
                row[s] = v;
                if v.is_negative() {
                    sx = !sx;
                }
                let av = v.abs_sat();
                if av.lt_total(m1) {
                    m2 = m1;
                    m1 = av;
                    imin = s;
                } else if av.lt_total(m2) {
                    m2 = av;
                }
            }
            ncheck += parity as u32;
            let odd = (nrw & 1) != 0;
            let s1 = m1.mul_alpha(alpha);
            let s2 = m2.mul_alpha(alpha);
            for s in 0..nrw {
                let scaled = if s == imin { s2 } else { s1 };
                tov[et[s] as usize] = if sx ^ row[s].is_negative() ^ odd { scaled.neg_sat() } else { scaled };
            }
        }

        if ncheck == 0 {
            for (c, &z) in cw[..n].iter_mut().zip(zn.iter()) {
                *c = T::wide_is_positive(z) as u8;
            }
            let mut decoded = vec![0u8; k];
            decoded.copy_from_slice(&cw[..k]);
            if verify.is_none_or(|f| f(&decoded)) {
                let mut hard_errors = 0u32;
                for i in 0..n {
                    if (cw[i] == 1) != !llr[i].is_negative() {
                        hard_errors += 1;
                    }
                }
                let mut message77 = [0u8; 77];
                message77.copy_from_slice(&decoded[..77]);
                return Some(BpResult { message77, info: decoded, codeword: cw[..n].to_vec(), hard_errors, iterations: iter });
            }
        }
        if iter > 0 {
            if ncheck < nclast {
                ncnt = 0;
            } else {
                ncnt += 1;
            }
            if ncnt >= 5 && iter >= 10 && ncheck > 15 {
                return None;
            }
        }
        nclast = ncheck;
    }
    None
}

/// LDPC(174, 91) wrapper, as [`super::bp::bp_decode_nms_with_scratch`].
pub fn bp_decode_nms_fast<T: LlrScalar>(
    scratch: &mut BpScratch<super::params::Ldpc174_91Params, T>,
    llr: &[T; super::LDPC_N],
    ap_mask: Option<&[bool; super::LDPC_N]>,
    max_iter: u32,
    verify: Option<fn(&[u8]) -> bool>,
    alpha: f32,
) -> Option<BpResult> {
    bp_decode_nms_fast_with_scratch::<super::params::Ldpc174_91Params, T>(
        scratch,
        llr.as_slice(),
        ap_mask.map(|a| a.as_slice()),
        max_iter,
        verify,
        alpha,
    )
}
