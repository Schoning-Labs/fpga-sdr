// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Fixed-width two's-complement helpers for transliterating the register arithmetic of
//! `rtl/rx/*.v` into Rust bit for bit. Every register in the RTL is a fixed-width `reg`, every
//! assignment to it truncates the right-hand side to that width, and every arithmetic right shift
//! sign-extends. Instead of tracking raw bit patterns everywhere, every value in this crate is
//! kept as an `i64` that already is the correctly sign-extended two's-complement value of some
//! register, so `+`, `-`, `*` and `>>` with the native `i64` operators give the same bit pattern
//! as the Verilog operators (modulo 2^64, which never matters at these widths). Width therefore
//! only matters when a value is stored into a fixed-width register or read out of one with a
//! part-select: [`trunc`] truncates a value to `width` bits and sign-extends it again (what every
//! `reg <= expr;` does), and [`part_select_signed`] extracts a bit range and reinterprets it as
//! signed (what `reg[hi:lo]` does in a signed context).

/// Truncate `v` to `width` bits (2 <= width <= 63) and sign-extend the result back to `i64` --
/// exactly what storing an arbitrary-precision result into a `width`-bit two's-complement
/// `reg` does.
#[inline(always)]
pub fn trunc(v: i64, width: u32) -> i64 {
    debug_assert!((1..64).contains(&width));
    let shift = 64 - width;
    (v << shift) >> shift
}

/// The raw unsigned `width`-bit bit pattern of `v` (which must already be a `width`-bit
/// two's-complement value, e.g. the output of [`trunc`]).
#[inline(always)]
pub fn raw_bits(v: i64, width: u32) -> u64 {
    debug_assert!((1..64).contains(&width));
    (v as u64) & ((1u64 << width) - 1)
}

/// A single bit of `v` (`v`'s own width does not matter; this reads bit `n` of `v`'s
/// two's-complement representation, matching Verilog's `v[n]`).
#[inline(always)]
pub fn bit(v: i64, n: u32) -> i64 {
    (v >> n) & 1
}

/// `v[hi:lo]` of a `width`-bit register `v`, reinterpreted as a signed `(hi-lo+1)`-bit value --
/// what a Verilog part-select used in a signed assignment context evaluates to.
#[inline(always)]
pub fn part_select_signed(v: i64, width: u32, hi: u32, lo: u32) -> i64 {
    debug_assert!(hi >= lo && hi < width);
    let raw = raw_bits(v, width) >> lo;
    let sel_width = hi - lo + 1;
    trunc(raw as i64, sel_width)
}

/// `v[hi:lo]` of a `width`-bit register `v`, as a raw unsigned value, what a Verilog
/// part-select used in an unsigned context (e.g. an array/case index) evaluates to.
#[inline(always)]
pub fn part_select_unsigned(v: i64, width: u32, hi: u32, lo: u32) -> u64 {
    debug_assert!(hi >= lo && hi < width);
    (raw_bits(v, width) >> lo) & ((1u64 << (hi - lo + 1)) - 1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trunc_wraps_like_a_fixed_width_register() {
        assert_eq!(trunc(0, 8), 0);
        assert_eq!(trunc(127, 8), 127);
        assert_eq!(trunc(128, 8), -128); // 8'b1000_0000 as signed
        assert_eq!(trunc(255, 8), -1);
        assert_eq!(trunc(256, 8), 0); // wraps
        assert_eq!(trunc(-1, 8), -1);
        assert_eq!(trunc(-129, 8), 127); // wraps the other way
    }

    #[test]
    fn bit_reads_twos_complement_bit_n() {
        assert_eq!(bit(0b1010, 1), 1);
        assert_eq!(bit(0b1010, 0), 0);
        assert_eq!(bit(-1i64, 40), 1); // all-ones pattern, any bit is 1
        assert_eq!(bit(trunc(-2, 4), 0), 0); // 4'b1110
        assert_eq!(bit(trunc(-2, 4), 1), 1);
    }

    #[test]
    fn part_select_matches_verilog_slice() {
        // 8'b1011_0100 = -76 signed (two's complement of 8 bits)
        let v = trunc(0b1011_0100, 8);
        assert_eq!(part_select_unsigned(v, 8, 7, 4), 0b1011);
        assert_eq!(part_select_unsigned(v, 8, 3, 0), 0b0100);
        assert_eq!(part_select_signed(v, 8, 7, 4), -5); // 4'b1011 signed = -5
        assert_eq!(part_select_signed(v, 8, 3, 0), 4); // 4'b0100 signed = 4
    }
}
