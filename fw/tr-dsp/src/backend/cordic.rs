// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The shared CORDIC (docs/R4_BACKEND.md section 3.4): 20 iterations, 30-bit X/Y (24-bit input,
//! 4 fraction bits, 2 bits of growth), angles in 1/2^24 turn (two's complement, so they wrap
//! for free), gain removed by one multiply with `KINV = round(2^17 / K)`.

use super::fix::wrap;
use super::tables::{ATAN, CORDIC_ITER, KINV};

const HALF_TURN: i64 = 1 << 23;
const QUARTER_TURN: i64 = 1 << 22;

#[inline]
fn gain_out(x: i64) -> i64 {
    let xr = (x + 4) >> 3;
    (xr * KINV + (1 << 17)) >> 18
}

/// Vectoring: returns `(|v|, angle(v))`, magnitude on the 24-bit input scale, angle as a signed
/// 24-bit number of 1/2^24 turns.
pub fn vector(re: i64, im: i64) -> (i64, i64) {
    let (mut x, mut y, mut z) =
        if re < 0 { (-re << 4, -im << 4, -HALF_TURN) } else { (re << 4, im << 4, 0) };
    for (i, &a) in ATAN.iter().enumerate().take(CORDIC_ITER) {
        let dx = y >> i;
        let dy = x >> i;
        if y >= 0 {
            x += dx;
            y -= dy;
            z += a;
        } else {
            x -= dx;
            y += dy;
            z -= a;
        }
    }
    (gain_out(x), wrap(z, 24))
}

/// Rotation: returns the real part of `v * e^(j 2 pi angle)` on the 24-bit input scale,
/// `angle` a signed 24-bit number of 1/2^24 turns.
pub fn rotate_re(re: i64, im: i64, angle: i64) -> i64 {
    let (mut x, mut y, mut z) = if angle >= QUARTER_TURN || angle < -QUARTER_TURN {
        (-re << 4, -im << 4, wrap(angle - HALF_TURN, 24))
    } else {
        (re << 4, im << 4, angle)
    };
    for (i, &a) in ATAN.iter().enumerate().take(CORDIC_ITER) {
        let dx = y >> i;
        let dy = x >> i;
        if z >= 0 {
            x -= dx;
            y += dy;
            z -= a;
        } else {
            x += dx;
            y -= dy;
            z += a;
        }
    }
    gain_out(x)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn k_scale() -> f64 {
        let mut k = 1.0f64;
        for i in 0..CORDIC_ITER {
            k *= libm::sqrt(1.0 + libm::ldexp(1.0, -2 * i as i32));
        }
        k * KINV as f64 / 131_072.0
    }

    #[test]
    fn vectoring_matches_float() {
        let ks = k_scale();
        for &r in &[100.0f64, 30_000.0, 8_000_000.0] {
            let (mut wm, mut wa) = (0.0f64, 0.0f64);
            for k in 0..3600 {
                let th = k as f64 * core::f64::consts::TAU / 3600.0 + 0.0001;
                let (re, im) = (libm::round(r * libm::cos(th)) as i64, libm::round(r * libm::sin(th)) as i64);
                let (m, a) = vector(re, im);
                let true_m = libm::sqrt((re * re + im * im) as f64) * ks;
                let true_a = libm::atan2(im as f64, re as f64) / core::f64::consts::TAU * 16_777_216.0;
                let mut da = a as f64 - true_a;
                if da > 8_388_608.0 {
                    da -= 16_777_216.0;
                }
                if da < -8_388_608.0 {
                    da += 16_777_216.0;
                }
                wm = wm.max(libm::fabs(m as f64 - true_m));
                wa = wa.max(libm::fabs(da));
            }
            std::println!(
                "MEASURED CORDIC vectoring at |v| = {r}: worst |M| error {wm:.2} LSB (after the constant gain error {:.2e}), worst angle error {wa:.1} / 2^24 turn",
                ks - 1.0
            );
            assert!(wm <= 1.5, "magnitude error {wm}");
            assert!(wa <= 16.0 + 3.0e8 / r, "angle error {wa}");
        }
    }

    #[test]
    fn rotation_matches_float() {
        let ks = k_scale();
        let mut worst = 0.0f64;
        for k in 0..3600 {
            let ang = (k as i64 * 23_301) % (1 << 24) - (1 << 23);
            let (re, im) = (5_000_000i64, -3_000_000i64);
            let c = rotate_re(re, im, ang);
            let th = ang as f64 / 16_777_216.0 * core::f64::consts::TAU;
            let t = (re as f64 * libm::cos(th) - im as f64 * libm::sin(th)) * ks;
            worst = worst.max(libm::fabs(c as f64 - t));
        }
        std::println!("MEASURED CORDIC rotation: worst error {worst:.2} LSB at |v| = 5.8e6");
        // Limited by the angle resolution (20 rounded arctangent steps, about 10 / 2^24 turn):
        // 3e-6 of |v| (-110 dB).
        assert!(worst < 5.8e6 * 4e-6, "rotation error {worst}");
    }
}
