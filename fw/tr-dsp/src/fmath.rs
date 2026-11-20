// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Hardware floating-point square root on the AE350.
//!
//! `libm::sqrtf` has no RISC-V fast path (libm 0.2.16 only special-cases x86 SSE, aarch64 NEON
//! and wasm32), so on `riscv32imafc` it runs a bit-by-bit software square root of about a hundred
//! instructions, even though the A25's F extension has a single `fsqrt.s` instruction. `core`
//! has no stable `f32::sqrt` for `no_std` yet, so on RISC-V targets with the F extension this
//! module emits `fsqrt.s` through inline assembly (`cfg(tr_hw_fpu)`, set by `build.rs`); everywhere else (the host, for `cargo test`
//! and `tr-sim`) it calls `libm::sqrtf`. Both are correctly rounded IEEE-754 square roots, so
//! the result is bit-identical either way.
//!
//! Measured effect: docs/CPU_BUDGET.md section 4.

/// IEEE-754 single-precision square root (correctly rounded).
#[inline(always)]
pub fn sqrt(x: f32) -> f32 {
    #[cfg(tr_hw_fpu)]
    {
        let r: f32;
        // SAFETY: `fsqrt.s` reads one FP register and writes one; it touches no memory, no
        // stack and no integer state. It only exists when the F extension is present, which
        // the `cfg` above guarantees at compile time.
        unsafe {
            core::arch::asm!(
                "fsqrt.s {r}, {x}",
                r = lateout(freg) r,
                x = in(freg) x,
                options(pure, nomem, nostack)
            );
        }
        r
    }
    #[cfg(not(tr_hw_fpu))]
    {
        libm::sqrtf(x)
    }
}

/// `a * b + c`, as one fused `fmadd.s` on RISC-V with the F extension (one rounding), as a
/// separate multiply and add elsewhere. Rust only fuses when asked (`f32::mul_add` is `std`-only
/// and would call a software `fmaf` without the right target setup), so the hot loops ask here.
#[inline(always)]
pub fn mul_add(a: f32, b: f32, c: f32) -> f32 {
    #[cfg(tr_hw_fpu)]
    {
        let r: f32;
        // SAFETY: register-only FP instruction, see `sqrt`.
        unsafe {
            core::arch::asm!(
                "fmadd.s {r}, {a}, {b}, {c}",
                r = lateout(freg) r,
                a = in(freg) a,
                b = in(freg) b,
                c = in(freg) c,
                options(pure, nomem, nostack)
            );
        }
        r
    }
    #[cfg(not(tr_hw_fpu))]
    {
        a * b + c
    }
}

/// `a * b - c`, as one fused `fmsub.s` on RISC-V with the F extension.
#[inline(always)]
pub fn mul_sub(a: f32, b: f32, c: f32) -> f32 {
    #[cfg(tr_hw_fpu)]
    {
        let r: f32;
        // SAFETY: register-only FP instruction, see `sqrt`.
        unsafe {
            core::arch::asm!(
                "fmsub.s {r}, {a}, {b}, {c}",
                r = lateout(freg) r,
                a = in(freg) a,
                b = in(freg) b,
                c = in(freg) c,
                options(pure, nomem, nostack)
            );
        }
        r
    }
    #[cfg(not(tr_hw_fpu))]
    {
        a * b - c
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fused_ops_compute_the_right_thing() {
        assert_eq!(mul_add(3.0, 4.0, 5.0), 17.0);
        assert_eq!(mul_sub(3.0, 4.0, 5.0), 7.0);
    }

    #[test]
    fn matches_libm() {
        for &x in &[0.0f32, 1e-30, 0.25, 1.0, 2.0, 12345.678, 3.4e38] {
            assert_eq!(sqrt(x).to_bits(), libm::sqrtf(x).to_bits());
        }
    }
}
