// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Single-frequency power estimation (Goertzel algorithm) over a captured block of samples. It
//! serves the AM broadcast band level check for the high-pass polarity question of
//! `docs/ARCHITECTURE.md` section 8, which is answered by toggling bit 23 and watching the AM
//! broadcast band level in a raw capture. There is no FFT dependency: a handful of Goertzel bins
//! across the AM band, plus a couple of reference frequencies well away from the 3 MHz high-pass
//! corner, are enough to compare a level between two captures.

use core::f64::consts::PI;

/// Normalized power (mean squared magnitude per sample, i.e. comparable across capture lengths)
/// at `freq_hz` in `samples`, sampled at `sample_rate_hz`. Bin frequency is quantized to the
/// nearest DFT bin for the given block length, same as an FFT would.
pub fn goertzel_power(samples: &[i16], sample_rate_hz: f64, freq_hz: f64) -> f64 {
    let n = samples.len();
    if n == 0 {
        return 0.0;
    }
    let k = (0.5 + (n as f64) * freq_hz / sample_rate_hz).floor();
    let omega = 2.0 * PI * k / n as f64;
    let coeff = 2.0 * omega.cos();
    let (mut s1, mut s2) = (0.0, 0.0);
    for &x in samples {
        let s0 = x as f64 + coeff * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    let real = s1 - s2 * omega.cos();
    let imag = s2 * omega.sin();
    (real * real + imag * imag) / (n as f64 * n as f64)
}

/// `10 * log10(power)`, floored so a zero/near-zero reading doesn't produce `-inf`/NaN.
pub fn to_db(power: f64) -> f64 {
    10.0 * power.max(1e-18).log10()
}

/// Mean power across several frequencies, in dB (a crude band-energy estimate: average several
/// Goertzel bins spanning the band instead of summing a full FFT's worth).
pub fn band_power_db(samples: &[i16], sample_rate_hz: f64, freqs_hz: &[f64]) -> f64 {
    let sum: f64 = freqs_hz.iter().map(|&f| goertzel_power(samples, sample_rate_hz, f)).sum();
    to_db(sum / freqs_hz.len().max(1) as f64)
}

/// AM broadcast band (526.5-1,606.5 kHz per ITU Region-agnostic mediumwave allocation), sampled
/// every 100 kHz, enough spread to average over station-shaped structure without needing
/// every channel.
pub const AM_BAND_HZ: [f64; 11] =
    [600_000.0, 700_000.0, 800_000.0, 900_000.0, 1_000_000.0, 1_100_000.0, 1_200_000.0, 1_300_000.0, 1_400_000.0, 1_500_000.0, 1_600_000.0];

/// Well below the AM band, deep in the high-pass's stop-band on any polarity reading of
/// ARCHITECTURE.md section 8, should show the largest HPF-on/HPF-off difference and is a
/// sanity check that the measurement methodology itself can see the filter at all.
pub const LOW_REFERENCE_HZ: f64 = 100_000.0;
/// Well above the 3 MHz high-pass corner, should barely move between HPF-on and HPF-off if
/// the filter is doing only what the corner frequency implies.
pub const HIGH_REFERENCE_HZ: f64 = 7_000_000.0;

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(freq_hz: f64, sample_rate_hz: f64, n: usize, amplitude: f64) -> Vec<i16> {
        (0..n).map(|i| (amplitude * (2.0 * PI * freq_hz * i as f64 / sample_rate_hz).sin()) as i16).collect()
    }

    #[test]
    fn goertzel_finds_a_known_tone() {
        let fs = 76_800_000.0;
        let n = 76_800; // 1 ms block, 1 kHz bin spacing
        let samples = tone(1_000_000.0, fs, n, 1000.0);
        let on_bin = goertzel_power(&samples, fs, 1_000_000.0);
        let off_bin = goertzel_power(&samples, fs, 2_000_000.0);
        assert!(on_bin > off_bin * 100.0, "on-bin power {on_bin} should dwarf off-bin power {off_bin}");
    }

    #[test]
    fn silence_reads_near_the_floor() {
        let samples = vec![0i16; 76_800];
        let p = goertzel_power(&samples, 76_800_000.0, 1_000_000.0);
        assert_eq!(p, 0.0);
        assert!(to_db(p) < -100.0);
    }

    #[test]
    fn band_power_matches_direct_average() {
        let fs = 76_800_000.0;
        let samples = tone(1_000_000.0, fs, 76_800, 500.0);
        let direct: f64 = AM_BAND_HZ.iter().map(|&f| goertzel_power(&samples, fs, f)).sum::<f64>() / AM_BAND_HZ.len() as f64;
        assert!((band_power_db(&samples, fs, &AM_BAND_HZ) - to_db(direct)).abs() < 1e-9);
    }

    #[test]
    fn empty_capture_is_handled() {
        assert_eq!(goertzel_power(&[], 76_800_000.0, 1_000_000.0), 0.0);
    }
}
