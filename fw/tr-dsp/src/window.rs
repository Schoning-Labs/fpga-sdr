// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Window functions used at filter-design time only (not on the per-block hot path).

use core::f32::consts::TAU;

/// Blackman-Harris 4-term window, ~92 dB sidelobes, used to taper the windowed-sinc bandpass
/// prototypes in [`crate::fastconv`] so the fast-convolution filters have a clean stopband
/// without needing a Parks-McClellan solver on the firmware side.
pub fn blackman_harris(n: usize, len: usize) -> f32 {
    const A0: f32 = 0.358_75;
    const A1: f32 = 0.488_29;
    const A2: f32 = 0.141_28;
    const A3: f32 = 0.011_68;
    if len <= 1 {
        return 1.0;
    }
    let x = TAU * n as f32 / (len - 1) as f32;
    A0 - A1 * libm::cosf(x) + A2 * libm::cosf(2.0 * x) - A3 * libm::cosf(3.0 * x)
}

/// Normalized sinc: `sin(pi x) / (pi x)`, with `sinc(0) = 1`.
pub fn sinc(x: f32) -> f32 {
    if libm::fabsf(x) < 1e-8 {
        1.0
    } else {
        let px = core::f32::consts::PI * x;
        libm::sinf(px) / px
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn window_is_zero_at_the_edges_and_one_in_the_middle() {
        let len = 65;
        assert!(blackman_harris(0, len) < 0.01);
        assert!(blackman_harris(len - 1, len) < 0.01);
        assert!(blackman_harris(len / 2, len) > 0.99);
    }

    #[test]
    fn sinc_at_zero_is_one() {
        assert!((sinc(0.0) - 1.0).abs() < 1e-6);
    }
}
