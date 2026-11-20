// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! `sensitivity-sweep`, a synthetic noise sweep for FT8, FT4 and WSPR. Each trial encodes a message, adds white
//! Gaussian noise at a target SNR (the WSJT-X convention, dB in a 2,500 Hz reference bandwidth), decodes it, and
//! the trials are repeated over many combinations of message, frequency, time offset and noise seed for every SNR
//! step. The tool reports the SNR at which the decode probability crosses 50 %.
//!
//! A single real recording cannot answer whether this crate's own `no_std` FFT backend (`tr_modes::fft`) is as
//! sensitive as the reference `rustfft` backend, because with 8 or 9 signals per file (see
//! `tests/wsjtx_samples.rs`) one miss is already about 12 % of the file, which is too coarse to tell a small loss
//! of sensitivity from a signal whose noise happened to fall the wrong way. A 50 % point taken from dozens of
//! independent trials per SNR step does tell them apart.
//!
//! The noise generator and the SNR to amplitude convention follow the sweep tests of mfsk-core
//! (`tests/ft4_snr_sweep.rs` and `tests/common/channel.rs`, GPL-3.0-or-later and not vendored here), written out
//! again in the few lines it takes, so the SNR figures printed here are on the same scale as WSJT-X's own and as
//! mfsk-core's published sensitivity figures.
//!
//! ```sh
//! cargo run --release -p tr-modes --bin sensitivity-sweep -- \
//!     <ft8|ft4|wspr> [snr_min] [snr_max] [snr_step] [trials_per_step]
//! ```
//!
//! To compare the two FFT backends the tool is built twice, once per backend (docs/S5_MODES.md, section
//! "Sensitivity sweep", has the results):
//!
//! ```sh
//! cargo build --release -p tr-modes --bin sensitivity-sweep
//! cargo build --release -p tr-modes --no-default-features \
//!     --features std,ft8,ft4,wspr,fft-rustfft --bin sensitivity-sweep
//! ```

use std::env;
use std::f32::consts::PI;
use std::time::Instant;

const FS: f32 = 12_000.0;
/// WSJT-X's SNR reference bandwidth in Hz. Every SNR in this tool, like the SNR WSJT-X reports, is in dB relative
/// to the noise power in this bandwidth and not in the full audio band. `snr_to_amplitude` has the formula.
const REF_BW: f32 = 2_500.0;

/// Deterministic Gaussian noise generator with the construction of mfsk-core's
/// `tests/common/channel.rs::AwgnChannel` (a 64-bit linear congruential generator, scaled to a uniform value and
/// then turned into a Gaussian by the Box-Muller transform). It is written out here because it is only a few
/// lines, and because that file lives in mfsk-core's test tree and is not part of the published crate, so
/// `tr-modes` could not depend on it anyway.
struct Lcg {
    state: u64,
}

impl Lcg {
    /// Starts the generator from `seed`, offset by a constant.
    fn new(seed: u64) -> Self {
        Self { state: seed.wrapping_add(0x9E37_79B9_7F4A_7C15) }
    }

    /// Uniform value in (0, 1), never exactly 0 so that `ln` is safe.
    fn uniform(&mut self) -> f32 {
        self.state = self.state.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        ((self.state >> 32) as f32 + 1.0) / 4_294_967_297.0
    }

    /// Standard normal value (zero mean, unit variance).
    fn gaussian(&mut self) -> f32 {
        let u1 = self.uniform();
        let u2 = self.uniform();
        (-2.0 * u1.ln()).sqrt() * (2.0 * PI * u2).cos()
    }

    /// Uniform value in [lo, hi), used to pick the frequency and time jitter of a trial.
    fn range(&mut self, lo: f32, hi: f32) -> f32 {
        lo + self.uniform() * (hi - lo)
    }

    /// Picks one element of `items` at random.
    fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
        &items[(self.uniform() * items.len() as f32) as usize % items.len()]
    }
}

/// Amplitude of a signal that has the SNR `snr_db` against noise of unit variance per sample.
///
/// This is the convention of mfsk-core's `ft4_snr_sweep.rs`, which follows WSJT-X and weakmon. With a noise variance
/// of 1 over the full `FS` wide band, a continuous tone sits at `snr_db` relative to the noise power in the
/// `REF_BW` wide reference band when its amplitude is `A = sqrt(4 * 10^(snr_db/10) * REF_BW / FS)`. Each
/// synthesized waveform is made with this amplitude, the noise (standard deviation 1) is added on top, and the
/// whole mixed buffer is then peak scaled to fit `i16`, which keeps the SNR ratio because the scale is uniform.
fn snr_to_amplitude(snr_db: f32) -> f32 {
    let snr_lin = 10f32.powf(snr_db / 10.0);
    (4.0 * snr_lin * REF_BW / FS).sqrt()
}

/// Adds unit variance noise to `mix` and scales the sum so its peak is 29,000, then quantizes to 16 bit.
fn mix_and_quantize(mut mix: Vec<f32>, seed: u64) -> Vec<i16> {
    let mut rng = Lcg::new(seed);
    for s in mix.iter_mut() {
        *s += rng.gaussian();
    }
    let peak = mix.iter().map(|x| x.abs()).fold(0.0f32, f32::max).max(1e-6);
    let scale = 29_000.0 / peak;
    mix.iter().map(|&s| (s * scale).clamp(-32_768.0, 32_767.0) as i16).collect()
}

// ── FT8 ──────────────────────────────────────────────────────────────────

#[cfg(feature = "ft8")]
mod ft8 {
    use super::*;
    use mfsk_core::ft8::wave_gen::{message_to_tones, tones_to_f32};
    use mfsk_core::msg::wsjt77::pack77;

    const SLOT: usize = 180_000;
    const CALLS: &[&str] = &["JA1ABC", "K1JT", "W1AW", "VE3ABC", "G4XYZ", "DL1AAA", "VK2XYZ", "PY2ABC"];
    const GRIDS: &[&str] = &["PM95", "FN42", "EM12", "JO52", "IO91", "KN07", "QF56", "GG66"];

    /// Builds the slot audio of one trial together with the exact message text to look for and the frequency.
    /// Frequency, time offset, callsign and grid all depend on `seed`, which is new for every trial, so that the
    /// sweep does not measure one lucky or unlucky combination over and over.
    fn make_trial(freq_lo: f32, freq_hi: f32, snr_db: f32, seed: u64) -> (Vec<i16>, String, f32) {
        let mut rng = Lcg::new(seed ^ 0xA5A5_A5A5_A5A5_A5A5);
        let call = rng.pick(CALLS);
        let grid = rng.pick(GRIDS);
        let freq_hz = rng.range(freq_lo, freq_hi);
        // +/-0.3 s of time jitter around the nominal 0.5 s transmit start. It stays well inside the +/-2.5 s that
        // WSJT-X tolerates, and it makes the decoder search for the time offset instead of finding it dead center.
        let time_offset = rng.range(-0.3, 0.3);

        let msg77 = pack77("CQ", call, grid).expect("valid FT8 message");
        let tones = message_to_tones(&msg77);
        let pcm = tones_to_f32(&tones, freq_hz, snr_to_amplitude(snr_db));

        let mut mix = vec![0.0f32; SLOT];
        let start = ((0.5 + time_offset) * FS).round().max(0.0) as usize;
        let n = pcm.len().min(SLOT.saturating_sub(start));
        mix[start..start + n].copy_from_slice(&pcm[..n]);

        let audio = mix_and_quantize(mix, seed);
        (audio, format!("CQ {call} {grid}"), freq_hz)
    }

    /// Runs `trials` trials at `snr_db` and returns how many decoded the message. The search window is +/-100 Hz
    /// around the true frequency, using the plain single pass decoder.
    pub fn run(snr_db: f32, trials: u64, seed_base: u64) -> u64 {
        let mut hits = 0;
        for t in 0..trials {
            let seed = seed_base.wrapping_add(t);
            let (audio, want, freq_hz) = make_trial(300.0, 2700.0, snr_db, seed);
            let decoded = tr_modes::decode::ft8::decode_slot_light(&audio, (freq_hz - 100.0).max(50.0), freq_hz + 100.0, 1.0, 50);
            if decoded.iter().any(|d| d.message == want) {
                hits += 1;
            }
        }
        hits
    }
}

// ── FT4 ──────────────────────────────────────────────────────────────────

#[cfg(feature = "ft4")]
mod ft4 {
    use super::*;
    use mfsk_core::ft4::encode::{message_to_tones, tones_to_f32};
    use mfsk_core::msg::wsjt77::pack77;

    const SLOT: usize = 90_000;
    const CALLS: &[&str] = &["JA1ABC", "K1JT", "W1AW", "VE3ABC", "G4XYZ", "DL1AAA", "VK2XYZ", "PY2ABC"];
    const GRIDS: &[&str] = &["PM95", "FN42", "EM12", "JO52", "IO91", "KN07", "QF56", "GG66"];

    /// Same as the FT8 trial, with +/-0.2 s of time jitter.
    fn make_trial(freq_lo: f32, freq_hi: f32, snr_db: f32, seed: u64) -> (Vec<i16>, String, f32) {
        let mut rng = Lcg::new(seed ^ 0x5A5A_5A5A_5A5A_5A5A);
        let call = rng.pick(CALLS);
        let grid = rng.pick(GRIDS);
        let freq_hz = rng.range(freq_lo, freq_hi);
        let time_offset = rng.range(-0.2, 0.2);

        let msg77 = pack77("CQ", call, grid).expect("valid FT4 message");
        let tones = message_to_tones(&msg77);
        let pcm = tones_to_f32(&tones, freq_hz, snr_to_amplitude(snr_db));

        let mut mix = vec![0.0f32; SLOT];
        let start = ((0.5 + time_offset) * FS).round().max(0.0) as usize;
        let n = pcm.len().min(SLOT.saturating_sub(start));
        mix[start..start + n].copy_from_slice(&pcm[..n]);

        let audio = mix_and_quantize(mix, seed);
        (audio, format!("CQ {call} {grid}"), freq_hz)
    }

    /// Runs `trials` trials at `snr_db` and returns how many decoded the message, with the default
    /// decoder in a +/-400 Hz window.
    pub fn run(snr_db: f32, trials: u64, seed_base: u64) -> u64 {
        let mut hits = 0;
        for t in 0..trials {
            let seed = seed_base.wrapping_add(t);
            let (audio, want, freq_hz) = make_trial(300.0, 2700.0, snr_db, seed);
            // A narrower window than this (+/-100 Hz works fine for FT8 above) measurably lowered FT4's recall even
            // at a strong 0 dB SNR (docs/S5_MODES.md, section "Sensitivity sweep", has the diagnosis), because
            // FT4's coarse sync seems to want more of the band around a candidate to resolve it reliably. The
            // +/-400 Hz used here is the narrowest window that stopped costing recall.
            let decoded = tr_modes::decode::ft4::decode_slot(&audio, (freq_hz - 400.0).max(100.0), (freq_hz + 400.0).min(3000.0), 1.0, 50);
            if decoded.iter().any(|d| d.message == want) {
                hits += 1;
            } else if std::env::var("SWEEP_DEBUG").is_ok() {
                eprintln!("MISS want={want:?} freq_hz={freq_hz:.1} got={decoded:?}");
            }
        }
        hits
    }
}

// ── WSPR ─────────────────────────────────────────────────────────────────

#[cfg(feature = "wspr")]
mod wspr {
    use super::*;

    const SLOT: usize = (120.0 * FS) as usize;
    const CALLS: &[&str] = &["K1ABC", "W1AW", "VE3ABC", "G4XYZ", "DL1AAA", "VK2XYZ", "PY2ABC", "JA1XYZ"];
    const GRIDS: &[&str] = &["FN42", "EM12", "JO52", "IO91", "KN07", "QF56", "GG66", "PM95"];

    /// Same as the FT8 trial for WSPR, with +/-1 s of time jitter and the audio as `f32` (the WSPR decoder takes
    /// floating point samples).
    fn make_trial(freq_lo: f32, freq_hi: f32, snr_db: f32, seed: u64) -> (Vec<f32>, String, f32) {
        let mut rng = Lcg::new(seed ^ 0x3C3C_3C3C_3C3C_3C3C);
        let call = rng.pick(CALLS);
        let grid = rng.pick(GRIDS);
        let power = 37;
        let freq_hz = rng.range(freq_lo, freq_hi);
        // WSPR transmissions nominally start 1 s into the 120 s slot, and +/-1 s of jitter stays inside the default
        // time search of the decoder.
        let time_offset = rng.range(-1.0, 1.0);

        let pcm = tr_modes::encode::wspr::encode_f32(call, grid, power, freq_hz, snr_to_amplitude(snr_db)).expect("valid WSPR message");

        let mut mix = vec![0.0f32; SLOT];
        let start = ((1.0 + time_offset) * FS).round().max(0.0) as usize;
        let n = pcm.len().min(SLOT.saturating_sub(start));
        mix[start..start + n].copy_from_slice(&pcm[..n]);

        // The amplitude formula above already sets the signal level, so the noise is added directly, without the
        // peak scaling and `i16` quantization of the other modes.
        let mut rng2 = Lcg::new(seed);
        for s in mix.iter_mut() {
            *s += rng2.gaussian();
        }

        (mix, format!("{call} {grid} {power}"), freq_hz)
    }

    /// Runs `trials` trials at `snr_db` and returns how many decoded the message, in a +/-20 Hz window.
    pub fn run(snr_db: f32, trials: u64, seed_base: u64) -> u64 {
        let mut hits = 0;
        for t in 0..trials {
            let seed = seed_base.wrapping_add(t);
            let (audio, want, freq_hz) = make_trial(1400.0, 1600.0, snr_db, seed);
            let params = tr_modes::decode::wspr::SearchParams {
                freq_min_hz: (freq_hz - 20.0).max(1350.0),
                freq_max_hz: freq_hz + 20.0,
                max_candidates: 30,
                ..Default::default()
            };
            let decoded = tr_modes::decode::wspr::decode_slot(&audio, 12_000, 0, &params);
            if decoded.iter().any(|d| d.message == want) {
                hits += 1;
            }
        }
        hits
    }
}

// ── driver ───────────────────────────────────────────────────────────────

/// SNR at which the fitted hit rate crosses 0.5, from an ordinary least squares line through the (SNR, rate)
/// points, solved for `a*snr + b = 0.5`. Returns `None` for fewer than two points or a flat line.
///
/// A plain interpolation between the two points that first straddle 0.5 is avoided on purpose. With tens of
/// trials per step, and not hundreds, the rate of one step carries real sampling noise, so a step reading lower
/// than the step below it is expected now and then and does not mean the curve is non-monotonic, and an
/// interpolation anchored on two adjacent points can land exactly on such noise. A least squares fit uses all the
/// trials at once and is far less sensitive to any one step, which matters for a threshold that is meant to be
/// compared to a precision of 0.3 dB. The transition of a detection curve in Gaussian noise is close enough to a
/// straight line over the few dB a sweep covers for this to be a reasonable fit, although it is not a logistic
/// regression.
fn linear_fit_50pct(points: &[(f32, f64)]) -> Option<f32> {
    if points.len() < 2 {
        return None;
    }
    let n = points.len() as f64;
    let sum_x: f64 = points.iter().map(|&(x, _)| x as f64).sum();
    let sum_y: f64 = points.iter().map(|&(_, y)| y).sum();
    let sum_xx: f64 = points.iter().map(|&(x, _)| (x as f64) * (x as f64)).sum();
    let sum_xy: f64 = points.iter().map(|&(x, y)| (x as f64) * y).sum();
    let denom = n * sum_xx - sum_x * sum_x;
    if denom.abs() < 1e-9 {
        return None;
    }
    let a = (n * sum_xy - sum_x * sum_y) / denom;
    let b = (sum_y - a * sum_x) / n;
    if a.abs() < 1e-9 {
        return None; // flat fit, so no transition was ever detected
    }
    Some(((0.5 - b) / a) as f32)
}

/// SNR at which the hit rate crosses 0.5. `linear_fit_50pct` is applied only to the transition band (the points
/// with `0 < rate < 1`) plus one saturated point on each side, and not to the whole swept range.
///
/// The long flat tails at 0 % and 100 % that a sweep includes on both sides of the transition say only that the
/// crossing lies outside their SNR and nothing about where it is, but they pull the slope of a least squares line
/// down and bias the reported crossing. In one early sweep of FT8 with the `rustfft` backend the raw rates cross
/// 50 % between -21.5 dB (50 %) and -22.0 dB (20 %), while a fit over the whole range reported -22.20 dB, which is
/// outside the swept range. The extra point on each side keeps the fit stable when only one or two points lie
/// strictly between 0 and 1.
fn interpolate_50pct(points: &[(f32, f64)]) -> Option<f32> {
    let mut lo = None;
    let mut hi = None;
    for (i, &(_, rate)) in points.iter().enumerate() {
        if rate > 0.0 && rate < 1.0 {
            lo = Some(lo.map_or(i, |l: usize| l.min(i)));
            hi = Some(hi.map_or(i, |h: usize| h.max(i)));
        }
    }
    match (lo, hi) {
        (Some(l), Some(h)) => {
            let start = l.saturating_sub(1);
            let end = (h + 1).min(points.len() - 1);
            linear_fit_50pct(&points[start..=end]).or_else(|| linear_fit_50pct(points))
        }
        // No point lies strictly in between (the transition fell exactly on a grid step, or the sweep did not
        // bracket it), so the whole range is used instead of reporting nothing.
        _ => linear_fit_50pct(points),
    }
}

/// Runs the sweep for the mode named on the command line, printing the hit count per SNR step and then the 50 %
/// point.
fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 {
        eprintln!("usage: sensitivity-sweep <ft8|ft4|wspr> [snr_min] [snr_max] [snr_step] [trials_per_step]");
        std::process::exit(2);
    }
    let mode = args[1].as_str();
    let (default_min, default_max): (f32, f32) = match mode {
        "ft8" => (-26.0, -16.0),
        "ft4" => (-22.0, -12.0),
        "wspr" => (-32.0, -22.0),
        _ => {
            eprintln!("unknown mode {mode:?}, expected ft8|ft4|wspr");
            std::process::exit(2);
        }
    };
    let snr_min: f32 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(default_min);
    let snr_max: f32 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(default_max);
    let snr_step: f32 = args.get(4).and_then(|s| s.parse().ok()).unwrap_or(0.5);
    let trials: u64 = args.get(5).and_then(|s| s.parse().ok()).unwrap_or(30);

    println!("=== {mode} sensitivity sweep: {snr_min} to {snr_max} dB step {snr_step} dB, {trials} trials/step ===");
    let mut points: Vec<(f32, f64)> = Vec::new();
    let t_start = Instant::now();
    let mut snr = snr_min;
    let mut step_idx: u64 = 0;
    while snr <= snr_max + 1e-3 {
        let seed_base = 0x1000_0000u64.wrapping_add(step_idx.wrapping_mul(1_000_003));
        let t0 = Instant::now();
        let hits = match mode {
            #[cfg(feature = "ft8")]
            "ft8" => ft8::run(snr, trials, seed_base),
            #[cfg(feature = "ft4")]
            "ft4" => ft4::run(snr, trials, seed_base),
            #[cfg(feature = "wspr")]
            "wspr" => wspr::run(snr, trials, seed_base),
            _ => unreachable!(),
        };
        let rate = hits as f64 / trials as f64;
        points.push((snr, rate));
        println!("  {snr:+6.1} dB: {hits:>3}/{trials}  ({:>5.1}%)  [{:.1}s]", rate * 100.0, t0.elapsed().as_secs_f64());
        snr += snr_step;
        step_idx += 1;
    }
    println!("total sweep time: {:.1}s", t_start.elapsed().as_secs_f64());

    match interpolate_50pct(&points) {
        Some(t) => println!("50% threshold: {t:+.2} dB"),
        None => println!("50% threshold: not reached within swept range"),
    }
}
