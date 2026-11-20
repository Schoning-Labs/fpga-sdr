// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Minimal `f32` complex arithmetic without an external complex-number crate, so the crate stays
//! `no_std`. Only the operations the ABCD ladder analysis in [`crate::abcd`] needs are here:
//! add, subtract, multiply, divide, reciprocal and magnitude.

#[derive(Clone, Copy, Debug, PartialEq)]
/// A complex number with single-precision real and imaginary parts.
pub struct Complex32 {
    pub re: f32,
    pub im: f32,
}

impl Complex32 {
    /// Zero, the additive identity.
    pub const ZERO: Complex32 = Complex32 { re: 0.0, im: 0.0 };
    /// One, the multiplicative identity.
    pub const ONE: Complex32 = Complex32 { re: 1.0, im: 0.0 };

    /// Builds a number from its real and imaginary parts.
    pub const fn new(re: f32, im: f32) -> Self {
        Complex32 { re, im }
    }

    /// Builds a purely real number.
    pub const fn real(re: f32) -> Self {
        Complex32 { re, im: 0.0 }
    }

    /// j*omega for a reactance, i.e. `Complex32::j_omega(w) == 0 + j*w`.
    pub const fn j_omega(w: f32) -> Self {
        Complex32 { re: 0.0, im: w }
    }

    /// Absolute value, `sqrt(re^2 + im^2)`.
    pub fn magnitude(self) -> f32 {
        libm::sqrtf(self.re * self.re + self.im * self.im)
    }

    /// Reciprocal, `1 / self`.
    pub fn recip(self) -> Complex32 {
        let d = self.re * self.re + self.im * self.im;
        Complex32 {
            re: self.re / d,
            im: -self.im / d,
        }
    }
}

impl core::ops::Add for Complex32 {
    type Output = Complex32;
    fn add(self, rhs: Complex32) -> Complex32 {
        Complex32::new(self.re + rhs.re, self.im + rhs.im)
    }
}

impl core::ops::Sub for Complex32 {
    type Output = Complex32;
    fn sub(self, rhs: Complex32) -> Complex32 {
        Complex32::new(self.re - rhs.re, self.im - rhs.im)
    }
}

impl core::ops::Mul for Complex32 {
    type Output = Complex32;
    fn mul(self, rhs: Complex32) -> Complex32 {
        Complex32::new(
            self.re * rhs.re - self.im * rhs.im,
            self.re * rhs.im + self.im * rhs.re,
        )
    }
}

impl core::ops::Div for Complex32 {
    type Output = Complex32;
    // Complex division as multiplication by the reciprocal is the standard implementation, not
    // an accidental `*`/`/` mix-up.
    #[allow(clippy::suspicious_arithmetic_impl)]
    fn div(self, rhs: Complex32) -> Complex32 {
        self * rhs.recip()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reciprocal_of_j_is_minus_j() {
        let j = Complex32::j_omega(1.0);
        let r = j.recip();
        assert!((r.re - 0.0).abs() < 1e-6);
        assert!((r.im - (-1.0)).abs() < 1e-6);
    }

    #[test]
    fn magnitude_of_3_4_is_5() {
        let c = Complex32::new(3.0, 4.0);
        assert!((c.magnitude() - 5.0).abs() < 1e-6);
    }

    #[test]
    fn division_round_trip() {
        let a = Complex32::new(2.0, 3.0);
        let b = Complex32::new(-1.0, 0.5);
        let q = a / b;
        let back = q * b;
        assert!((back.re - a.re).abs() < 1e-4);
        assert!((back.im - a.im).abs() < 1e-4);
    }
}
