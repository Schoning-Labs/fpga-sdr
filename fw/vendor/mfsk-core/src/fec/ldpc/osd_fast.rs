//! Bit-packed LDPC(174, 91) OSD with a linear CRC syndrome.
//!
//! [fpga-sdr vendor patch, fix 7 in `fw/vendor/VENDOR_PATCH.md`; modified 2026 by Franz
//! Schöning] Same searches, in the same order, with the same floating-point sums, as
//! [`super::osd::osd_decode_npre1`], [`super::osd::osd_decode_npre1_npre2`] and
//! [`super::osd::osd_decode_deep`] at `ndeep = 2` with `check_crc14`; the results are
//! identical (tested against them on random and real LLRs). What differs is the representation:
//!
//! - the permuted generator is kept as rows of six 32-bit words instead of one byte per bit, so
//!   a row XOR is 6 word operations instead of 174 byte operations, and the partial parity
//!   count of the npre1 gate is two population counts;
//! - the CRC-14 check of a test pattern is a 14-bit XOR. `check_crc14` is linear over GF(2) in
//!   the 91 information bits (CRC with zero initial value and no final XOR, compared with the
//!   received CRC bits), so it is the XOR of one 14-bit *syndrome* per set information bit and
//!   the codeword passes when the syndrome is zero. Each generator row carries its syndrome
//!   through the elimination (a row XOR is a syndrome XOR), so a candidate `c0 ^ row_a ^
//!   row_b` is checked with two XORs instead of unpermuting 91 bits and running a bitwise CRC
//!   over 96 bits. The codeword itself is only built when the syndrome is zero.
//!
//! On the AE350 (RV32, no bit-manipulation extension) this is what turns one OSD search from
//! millions of instructions into a few hundred thousand; the measurements are in the fpga-sdr
//! repository, `docs/FT8_OFFLOAD.md`.

use alloc::vec::Vec;

use super::osd::{GEN_PARITY, OsdResult};
use super::{LDPC_K, LDPC_N};

const K: usize = LDPC_K; // 91
const N: usize = LDPC_N; // 174
const M: usize = N - K; // 83
const W: usize = 6; // 32-bit words per row (192 >= 174)

type Row = [u32; W];

/// CRC-14 (poly 0x2757, zero initial value, MSB first) as `bp::crc14` computes it.
const fn crc14_const(bytes: &[u8; 12]) -> u16 {
    let mut crc: u16 = 0;
    let mut b = 0;
    while b < 12 {
        let byte = bytes[b];
        let mut i = 8;
        while i > 0 {
            i -= 1;
            let bit = ((byte >> i) & 1) as u16;
            let msb = (crc >> 13) & 1;
            crc = ((crc << 1) | bit) & 0x3FFF;
            if msb != 0 {
                crc ^= 0x2757;
            }
        }
        b += 1;
    }
    crc
}

/// Syndrome of information bit `i` alone: `crc14(message bits) ^ received CRC bits` for the
/// 91-bit word with only bit `i` set. `check_crc14(word)` is true exactly when the XOR of the
/// syndromes of its set bits is zero.
const fn unit_syndromes() -> [u16; K] {
    let mut u = [0u16; K];
    let mut i = 0;
    while i < 77 {
        let mut bytes = [0u8; 12];
        bytes[i / 8] = 1 << (7 - (i % 8));
        u[i] = crc14_const(&bytes);
        i += 1;
    }
    while i < K {
        u[i] = 1 << (90 - i);
        i += 1;
    }
    u
}

static UNIT_SYN: [u16; K] = unit_syndromes();

/// Rows `r` of the unpermuted generator with a 1 in parity column `j` (bit r of word r / 32).
const fn parity_columns() -> [[u32; 3]; M] {
    let mut out = [[0u32; 3]; M];
    let mut j = 0;
    while j < M {
        let mut r = 0;
        while r < K {
            if GEN_PARITY[j][r] != 0 {
                out[j][r / 32] |= 1 << (r % 32);
            }
            r += 1;
        }
        j += 1;
    }
    out
}

static PAR_COLS: [[u32; 3]; M] = parity_columns();

#[inline(always)]
fn bit(row: &Row, col: usize) -> bool {
    (row[col / 32] >> (col % 32)) & 1 != 0
}

#[inline(always)]
fn xor(a: &Row, b: &Row) -> Row {
    [a[0] ^ b[0], a[1] ^ b[1], a[2] ^ b[2], a[3] ^ b[3], a[4] ^ b[4], a[5] ^ b[5]]
}

/// Parity part (columns 91..174) of a row as an 83-bit vector at bit 0.
#[inline(always)]
fn parity_of(r: &Row) -> [u32; 3] {
    // column 91 = word 2, bit 27
    [(r[2] >> 27) | (r[3] << 5), (r[3] >> 27) | (r[4] << 5), (r[4] >> 27) | (r[5] << 5)]
}

/// Sum of `w[j]` over the set bits `j` of `v` (first `len` bits), ascending `j`, starting from
/// 0.0: the order the reference's `for j in 0..len { if bit { s += w[j] } }` adds in.
#[inline(always)]
fn weighted<const NW: usize>(v: &[u32; NW], w: &[f32]) -> f32 {
    let mut s = 0.0f32;
    for (wi, &word) in v.iter().enumerate() {
        let mut x = word;
        while x != 0 {
            let t = x.trailing_zeros() as usize;
            s += w[wi * 32 + t];
            x &= x - 1;
        }
    }
    s
}

/// Everything a search needs, after sorting and elimination.
struct Setup {
    perm: [u8; N],
    g: [Row; K],
    syn: [u16; K],
    /// Parity parts of the rows (for the npre1 gate).
    par: [[u32; 3]; K],
    hdec: Row,
    absrx: [f32; N],
    /// Order-0 codeword (`m0` encoded) and its syndrome.
    c0: Row,
    c0syn: u16,
}

/// Sort, permuted generator, elimination: the same operations as `osd_setup_ldpc174_91` (and
/// `osd_setup_generic_packed::<Ldpc174_91Params>`, which is the same algorithm), including the
/// pivot choice. `m0` uses `pivot_col` as both references do.
fn setup(llr: &[f32; N]) -> Option<Setup> {
    let mut perm_us: Vec<usize> = (0..N).collect();
    perm_us.sort_unstable_by(|&a, &b| llr[b].abs().partial_cmp(&llr[a].abs()).unwrap_or(core::cmp::Ordering::Equal));
    let mut perm = [0u8; N];
    for (c, &p) in perm_us.iter().enumerate() {
        perm[c] = p as u8;
    }

    // Row r, column c = G[r][perm[c]]; each row starts with the syndrome of original row r,
    // whose information part is the unit vector e_r.
    let mut g = [[0u32; W]; K];
    let mut syn = [0u16; K];
    for c in 0..N {
        let j = perm[c] as usize;
        let (w, b) = (c / 32, 1u32 << (c % 32));
        if j < K {
            g[j][w] |= b;
        } else {
            let pc = &PAR_COLS[j - K];
            for (rw, &word) in pc.iter().enumerate() {
                let mut x = word;
                while x != 0 {
                    let r = rw * 32 + x.trailing_zeros() as usize;
                    g[r][w] |= b;
                    x &= x - 1;
                }
            }
        }
    }
    syn.copy_from_slice(&UNIT_SYN);

    let mut pivot_col = [0u8; K];
    let mut pivot_row = 0usize;
    for col in 0..N {
        if pivot_row >= K {
            break;
        }
        let Some(r) = (pivot_row..K).find(|&r| bit(&g[r], col)) else { continue };
        if r != pivot_row {
            g.swap(r, pivot_row);
            syn.swap(r, pivot_row);
        }
        let pivot = g[pivot_row];
        let psyn = syn[pivot_row];
        for r2 in 0..K {
            if r2 != pivot_row && bit(&g[r2], col) {
                g[r2] = xor(&g[r2], &pivot);
                syn[r2] ^= psyn;
            }
        }
        pivot_col[pivot_row] = col as u8;
        pivot_row += 1;
    }
    if pivot_row < K {
        return None;
    }

    let mut hdec = [0u32; W];
    let mut absrx = [0.0f32; N];
    for c in 0..N {
        let v = llr[perm[c] as usize];
        if v > 0.0 {
            hdec[c / 32] |= 1 << (c % 32);
        }
        absrx[c] = v.abs();
    }
    let mut c0 = [0u32; W];
    let mut c0syn = 0u16;
    for r in 0..K {
        if llr[perm[pivot_col[r] as usize] as usize] > 0.0 {
            c0 = xor(&c0, &g[r]);
            c0syn ^= syn[r];
        }
    }
    let mut par = [[0u32; 3]; K];
    for r in 0..K {
        par[r] = parity_of(&g[r]);
    }
    Some(Setup { perm, g, syn, par, hdec, absrx, c0, c0syn })
}

/// Best candidate so far (packed, permuted) and its weighted distance.
struct Best {
    cw: Option<Row>,
    dd: f32,
}

impl Best {
    fn new() -> Self {
        Best { cw: None, dd: f32::INFINITY }
    }
}

/// `(information bits, codeword)` in the original bit order, as the reference's
/// `try_candidate_ldpc174_91` returns them.
fn unpermute(s: &Setup, cw: &Row) -> (Vec<u8>, Vec<u8>) {
    let mut c = alloc::vec![0u8; N];
    for col in 0..N {
        c[s.perm[col] as usize] = bit(cw, col) as u8;
    }
    (c[..K].to_vec(), c)
}

fn result(llr: &[f32; N], s: &Setup, best: Best) -> Option<OsdResult> {
    let cw = best.cw?;
    let (decoded, codeword) = unpermute(s, &cw);
    let mut hard_errors = 0u32;
    for i in 0..N {
        if (codeword[i] == 1) != (llr[i] > 0.0) {
            hard_errors += 1;
        }
    }
    let mut message77 = [0u8; 77];
    message77.copy_from_slice(&decoded[..77]);
    Some(OsdResult { message77, info: decoded, codeword, hard_errors })
}

/// `osd_npre1_pass`: order 0, the 91 single flips and the pair flips that pass the
/// `ntheta` gate on the first 40 parity bits.
fn npre1(s: &Setup, best: &mut Best, ntheta: u32) {
    let hpar = parity_of(&s.hdec);
    let c0par = parity_of(&s.c0);
    let wpar = &s.absrx[K..];
    // Order 0 (weighted distance over the parity columns only, as the reference).
    {
        let e = [c0par[0] ^ hpar[0], c0par[1] ^ hpar[1], c0par[2] ^ hpar[2]];
        let wd = weighted(&e, wpar);
        if wd < best.dd && s.c0syn == 0 {
            best.cw = Some(s.c0);
            best.dd = wd;
        }
    }
    let base = [c0par[0] ^ hpar[0], c0par[1] ^ hpar[1], c0par[2] ^ hpar[2]];
    for iflag in (0..K).rev() {
        let p = &s.par[iflag];
        let e2sub = [base[0] ^ p[0], base[1] ^ p[1], base[2] ^ p[2]];
        let pe = e2sub[0].count_ones() + (e2sub[1] & 0xFF).count_ones();
        let d1 = s.absrx[iflag];
        let syn1 = s.c0syn ^ s.syn[iflag];
        // The syndrome test comes first: it is two XORs and passes one pattern in 16,384, and
        // the order of the two tests does not change which candidate is kept.
        if pe < ntheta && syn1 == 0 {
            let dd = d1 + weighted(&e2sub, wpar);
            if dd < best.dd {
                best.cw = Some(xor(&s.c0, &s.g[iflag]));
                best.dd = dd;
            }
        }
        for n1 in (0..iflag).rev() {
            let q = &s.par[n1];
            let w0 = e2sub[0] ^ q[0];
            let w1 = e2sub[1] ^ q[1];
            let pe2 = w0.count_ones() + (w1 & 0xFF).count_ones();
            if pe2 + 2 > ntheta || syn1 ^ s.syn[n1] != 0 {
                continue;
            }
            let e2 = [w0, w1, e2sub[2] ^ q[2]];
            let dd = d1 + s.absrx[n1] + weighted(&e2, wpar);
            if dd < best.dd {
                best.cw = Some(xor(&xor(&s.c0, &s.g[iflag]), &s.g[n1]));
                best.dd = dd;
            }
        }
    }
}

/// `osd_npre2_pass` with `ntau` <= 16: the hash table of row-pair keys over the first `ntau`
/// parity bits (same insertion and iteration order), weighted distance over all 174 columns.
fn npre2(s: &Setup, best: &mut Best, ntau: usize) {
    let key_of = |p: &[u32; 3]| -> usize {
        // bit j of the parity part goes to key bit ntau-1-j (the reference's packing)
        let mut k = 0usize;
        for j in 0..ntau {
            if (p[j / 32] >> (j % 32)) & 1 != 0 {
                k |= 1 << (ntau - 1 - j);
            }
        }
        k
    };
    let buckets = 1usize << ntau;
    let mut fp: Vec<u16> = alloc::vec![u16::MAX; buckets];
    let npairs = K * (K - 1) / 2;
    let mut pairs: Vec<(u8, u8)> = Vec::with_capacity(npairs);
    let mut next: Vec<u16> = Vec::with_capacity(npairs);
    let mut row_keys = [0usize; K];
    for i in 0..K {
        row_keys[i] = key_of(&s.par[i]);
    }
    for i1 in 0..K {
        for i2 in 0..i1 {
            let key = row_keys[i1] ^ row_keys[i2];
            let idx = pairs.len() as u16;
            pairs.push((i1 as u8, i2 as u8));
            next.push(fp[key]);
            fp[key] = idx;
        }
    }
    let hpar = parity_of(&s.hdec);
    for iflag in (0..K).rev() {
        let ce_misub = xor(&s.c0, &s.g[iflag]);
        let mp = parity_of(&ce_misub);
        let e2sub = [mp[0] ^ hpar[0], mp[1] ^ hpar[1], mp[2] ^ hpar[2]];
        let base_key = key_of(&e2sub);
        let syn1 = s.c0syn ^ s.syn[iflag];
        for i2 in 0..=ntau {
            let key = if i2 == 0 { base_key } else { base_key ^ (1 << (ntau - i2)) };
            let mut cur = fp[key];
            while cur != u16::MAX {
                let (in1, in2) = pairs[cur as usize];
                cur = next[cur as usize];
                let (a, b) = (in1 as usize, in2 as usize);
                if iflag == a || iflag == b || a == b || syn1 ^ s.syn[a] ^ s.syn[b] != 0 {
                    continue;
                }
                let ce = xor(&xor(&ce_misub, &s.g[a]), &s.g[b]);
                let dd = weighted(&xor(&ce, &s.hdec), &s.absrx);
                if dd < best.dd {
                    best.cw = Some(ce);
                    best.dd = dd;
                }
            }
        }
    }
}

/// Same result as [`super::osd::osd_decode_npre1`].
pub fn osd_decode_npre1_fast(llr: &[f32; N]) -> Option<OsdResult> {
    let s = setup(llr)?;
    let mut best = Best::new();
    npre1(&s, &mut best, 10);
    result(llr, &s, best)
}

/// Same result as [`super::osd::osd_decode_npre1_npre2`].
pub fn osd_decode_npre1_npre2_fast(llr: &[f32; N]) -> Option<OsdResult> {
    let s = setup(llr)?;
    let mut best = Best::new();
    npre1(&s, &mut best, 12);
    npre2(&s, &mut best, 14);
    result(llr, &s, best)
}

/// Same result as [`super::osd::osd_decode_deep`]`(llr, 2, Some(check_crc14))`: order 0, all
/// single and all pair flips of the most reliable basis, the CRC-passing candidate with the
/// smallest weighted distance over all 174 columns (first one on ties).
pub fn osd_decode_deep2_crc_fast(llr: &[f32; N]) -> Option<OsdResult> {
    let s = setup(llr)?;
    let mut best = Best::new();
    let try_one = |cw: Row, best: &mut Best| {
        let wd = weighted(&xor(&cw, &s.hdec), &s.absrx);
        if best.cw.is_none() || wd < best.dd {
            best.cw = Some(cw);
            best.dd = wd;
        }
    };
    if s.c0syn == 0 {
        try_one(s.c0, &mut best);
    }
    for k1 in 0..K {
        let syn1 = s.c0syn ^ s.syn[k1];
        if syn1 == 0 {
            try_one(xor(&s.c0, &s.g[k1]), &mut best);
        }
        for k2 in (k1 + 1)..K {
            if syn1 ^ s.syn[k2] == 0 {
                try_one(xor(&xor(&s.c0, &s.g[k1]), &s.g[k2]), &mut best);
            }
        }
    }
    result(llr, &s, best)
}

// Tests: fpga-sdr `fw/tr-modes/tests/fo1_osd_fast.rs` (this vendored copy's own tests are not
// built by the fpga-sdr workspace).
