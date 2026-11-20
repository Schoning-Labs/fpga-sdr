// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Minimal `f32` complex number, no external dependency (avoids pulling `num-complex` for one
//! struct). Used for IQ samples and FFT bins throughout `tr-dsp`.

use core::ops::{Add, AddAssign, Mul, MulAssign, Sub};

/// A complex number with `f32` parts, used for IQ samples and FFT bins.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct C32 {
    pub re: f32,
    pub im: f32,
}

impl C32 {
    /// Zero.
    pub const ZERO: C32 = C32 { re: 0.0, im: 0.0 };

    /// Builds a number from its real and imaginary parts.
    #[inline]
    pub const fn new(re: f32, im: f32) -> Self {
        C32 { re, im }
    }

    /// Unit-magnitude complex number at angle `theta_cycles` full turns (not radians, a turn
    /// is one full 2*pi cycle, which keeps phase-accumulator code free of pi altogether).
    #[inline]
    pub fn from_turns(theta_cycles: f32) -> Self {
        let theta = theta_cycles * core::f32::consts::TAU;
        C32::new(libm::cosf(theta), libm::sinf(theta))
    }

    /// The complex conjugate.
    #[inline]
    pub fn conj(self) -> Self {
        C32::new(self.re, -self.im)
    }

    /// Squared magnitude, `re^2 + im^2`.
    #[inline]
    pub fn norm_sqr(self) -> f32 {
        crate::fmath::mul_add(self.re, self.re, self.im * self.im)
    }

    /// Magnitude.
    #[inline]
    pub fn abs(self) -> f32 {
        crate::fmath::sqrt(self.norm_sqr())
    }

    /// Angle in cycles (turns), not radians, for the same reason as `from_turns`.
    #[inline]
    pub fn arg_turns(self) -> f32 {
        libm::atan2f(self.im, self.re) / core::f32::consts::TAU
    }

    /// Both parts multiplied by `k`.
    #[inline]
    pub fn scale(self, k: f32) -> Self {
        C32::new(self.re * k, self.im * k)
    }
}

impl Add for C32 {
    type Output = C32;
    #[inline]
    fn add(self, rhs: C32) -> C32 {
        C32::new(self.re + rhs.re, self.im + rhs.im)
    }
}

impl AddAssign for C32 {
    #[inline]
    fn add_assign(&mut self, rhs: C32) {
        self.re += rhs.re;
        self.im += rhs.im;
    }
}

impl Sub for C32 {
    type Output = C32;
    #[inline]
    fn sub(self, rhs: C32) -> C32 {
        C32::new(self.re - rhs.re, self.im - rhs.im)
    }
}

impl Mul for C32 {
    type Output = C32;
    #[inline]
    fn mul(self, rhs: C32) -> C32 {
        // Fused multiply-add on the AE350 (`crate::fmath`): 2 multiplies + 2 fused ops instead
        // of 4 multiplies + 2 adds.
        C32::new(
            crate::fmath::mul_sub(self.re, rhs.re, self.im * rhs.im),
            crate::fmath::mul_add(self.re, rhs.im, self.im * rhs.re),
        )
    }
}

impl MulAssign for C32 {
    #[inline]
    fn mul_assign(&mut self, rhs: C32) {
        *self = *self * rhs;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rotation_is_unit_magnitude() {
        let z = C32::from_turns(0.125);
        assert!((z.abs() - 1.0).abs() < 1e-6);
    }

    #[test]
    fn mul_matches_hand_computation() {
        let a = C32::new(1.0, 2.0);
        let b = C32::new(3.0, -1.0);
        let p = a * b;
        assert!((p.re - 5.0).abs() < 1e-6);
        assert!((p.im - 5.0).abs() < 1e-6);
    }
}
