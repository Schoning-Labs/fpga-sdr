// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Integer helpers with exactly the RTL's semantics. Every value in the model is an `i64` that
//! holds the correctly sign-extended value of an RTL register or wire; `>>` on `i64` is an
//! arithmetic (floor) shift, the same as Verilog `>>>` on a signed operand.

/// Saturates `v` to a `bits`-bit two's-complement range.
#[inline]
pub fn sat(v: i64, bits: u32) -> i64 {
    let hi = (1i64 << (bits - 1)) - 1;
    let lo = -(1i64 << (bits - 1));
    v.clamp(lo, hi)
}

/// Round half up, then arithmetic shift right: `(v + 2^(k-1)) >> k`; `k = 0` returns `v`.
#[inline]
pub fn rshr(v: i64, k: u32) -> i64 {
    if k == 0 {
        v
    } else {
        (v + (1i64 << (k - 1))) >> k
    }
}

/// Wraps `v` to a signed `bits`-bit value (two's-complement truncation).
#[inline]
pub fn wrap(v: i64, bits: u32) -> i64 {
    let s = 64 - bits;
    (v << s) >> s
}

/// Position of the most significant set bit of a positive value (0 for 1).
#[inline]
pub fn msb(v: i64) -> u32 {
    debug_assert!(v > 0);
    63 - v.leading_zeros()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn helpers() {
        assert_eq!(sat(1 << 23, 24), (1 << 23) - 1);
        assert_eq!(sat(-(1 << 23) - 5, 24), -(1 << 23));
        assert_eq!(rshr(3, 1), 2);
        assert_eq!(rshr(-3, 1), -1);
        assert_eq!(rshr(-4, 2), -1);
        assert_eq!(wrap(0x80_0000, 24), -0x80_0000);
        assert_eq!(wrap(0xFF_FFFF, 24), -1);
        assert_eq!(msb(1), 0);
        assert_eq!(msb(1 << 20), 20);
    }
}
