// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Microphone rate converter (docs/USB_HOST.md section 5): the samples of a USB microphone come at
//! the device's own rate (8, 16, 32, 44.1 or 48 kHz nominal, and never exactly that); the radio
//! wants 48 kHz. Linear interpolation between neighboring samples, which is enough for speech
//! (the speech path low-passes at 3 kHz afterwards); the ratio can be trimmed while running so
//! that the FIFO in front neither fills nor empties.
//!
//! Only for an input rate at or below the output rate (there is no low-pass in front).

/// Linear-interpolation rate converter with a ratio that can be trimmed while it runs.
#[derive(Clone, Copy, Debug)]
pub struct Resampler {
    /// Input samples per output sample, 32.32 fixed point, as set.
    nominal: u64,
    /// The same with the trim.
    step: u64,
    /// Position between `a` and `b`, 32.32; the whole part is the number of input samples still to fetch.
    pos: u64,
    a: i16,
    b: i16,
}

impl Resampler {
    /// A converter from `in_hz` to `out_hz`.
    pub fn new(in_hz: u32, out_hz: u32) -> Self {
        let nominal = ((in_hz as u64) << 32) / out_hz.max(1) as u64;
        // start by fetching two samples
        Resampler { nominal, step: nominal, pos: 2 << 32, a: 0, b: 0 }
    }

    /// Uses the input faster (positive) or slower by `ppm` parts per million.
    pub fn trim(&mut self, ppm: i32) {
        let d = (self.nominal as i128 * ppm.clamp(-20_000, 20_000) as i128 / 1_000_000) as i64;
        self.step = self.nominal.wrapping_add(d as u64);
    }

    /// Trim from the fill of the FIFO in front: above `target` the input is used up faster.
    /// 16 ppm per sample of error, limited to 2,000 ppm: slow enough not to be heard.
    pub fn steer(&mut self, fill: usize, target: usize) {
        let err = fill as i32 - target as i32;
        self.trim((err * 16).clamp(-2000, 2000));
    }

    /// Converts as much as fits: returns (input samples used, output samples written).
    pub fn process(&mut self, input: &[i16], out: &mut [i16]) -> (usize, usize) {
        let (mut i, mut o) = (0, 0);
        loop {
            while self.pos >> 32 != 0 {
                if i == input.len() {
                    return (i, o);
                }
                self.a = self.b;
                self.b = input[i];
                i += 1;
                self.pos -= 1 << 32;
            }
            if o == out.len() {
                return (i, o);
            }
            let f = (self.pos >> 17) as i32; // 15 bits
            out[o] = (self.a as i32 + (((self.b as i32 - self.a as i32) * f) >> 15)) as i16;
            o += 1;
            self.pos += self.step;
        }
    }
}

#[cfg(test)]
mod tests {
    extern crate std;
    use super::*;
    use std::vec;
    use std::vec::Vec;

    fn run(in_hz: u32, n_in: usize, tone_hz: f64) -> Vec<i16> {
        let input: Vec<i16> =
            (0..n_in).map(|k| (10_000.0 * (2.0 * core::f64::consts::PI * tone_hz * k as f64 / in_hz as f64).sin()) as i16).collect();
        let mut r = Resampler::new(in_hz, 48_000);
        let mut out = vec![0i16; n_in * 7];
        // in uneven pieces, as a FIFO delivers
        let (mut i, mut o) = (0, 0);
        let mut piece = 1;
        while i < n_in {
            let end = (i + piece).min(n_in);
            let (ci, co) = r.process(&input[i..end], &mut out[o..]);
            i += ci;
            o += co;
            piece = piece % 50 + 7;
        }
        out.truncate(o);
        out
    }

    fn crossings(x: &[i16]) -> usize {
        x.windows(2).filter(|w| w[0] < 0 && w[1] >= 0).count()
    }

    #[test]
    fn rates_and_tone() {
        for hz in [8_000u32, 16_000, 32_000, 44_100, 48_000] {
            let out = run(hz, hz as usize, 440.0);
            // one second in, one second out
            assert!((out.len() as i64 - 48_000).abs() <= 8, "{hz}: {} samples out", out.len());
            let c = crossings(&out);
            assert!((c as i64 - 440).abs() <= 1, "{hz}: {c} cycles");
            let peak = out.iter().map(|v| v.unsigned_abs()).max().unwrap();
            assert!((9_000..=10_000).contains(&peak), "{hz}: peak {peak}");
        }
    }

    #[test]
    fn same_rate_is_a_copy() {
        let mut r = Resampler::new(48_000, 48_000);
        let input: Vec<i16> = (0..100).map(|k| k * 100).collect();
        let mut out = [0i16; 100];
        let (i, o) = r.process(&input, &mut out);
        assert_eq!(i, 100);
        assert!(o >= 98);
        assert_eq!(&out[..o], &input[..o]);
    }

    #[test]
    fn trim_changes_the_ratio() {
        let mut r = Resampler::new(48_000, 48_000);
        r.steer(200, 100); // too full: use the input 1,600 ppm faster
        let input = vec![0i16; 100_000];
        let mut out = vec![0i16; 100_000];
        let (i, o) = r.process(&input, &mut out);
        assert_eq!(i, 100_000);
        assert!((99_830..=99_850).contains(&o), "{o}");
    }
}
