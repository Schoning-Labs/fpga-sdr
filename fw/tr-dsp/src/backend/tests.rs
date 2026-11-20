// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

use super::tables::*;

fn read_hex(rel: &str) -> std::vec::Vec<u64> {
    let path = std::format!("{}/../../{}", env!("CARGO_MANIFEST_DIR"), rel);
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{path}: {e}"));
    text.lines().filter(|l| !l.trim().is_empty()).map(|l| u64::from_str_radix(l.trim(), 16).unwrap()).collect()
}

fn sext(v: u64, bits: u32) -> i64 {
    ((v << (64 - bits)) as i64) >> (64 - bits)
}

#[test]
fn tables_match_rtl_hex() {
    let hb = read_hex("rtl/rx_backend/bk_hb.hex");
    assert_eq!(hb.len(), HB_TAPS.len());
    for (w, &(off, c)) in hb.iter().zip(HB_TAPS.iter()) {
        assert_eq!((w >> 26) as usize, off);
        assert_eq!(sext(w & 0x3FF_FFFF, 26), c);
    }
    let l = read_hex("rtl/rx_backend/bk_log2.hex");
    assert!(l.iter().zip(LOG2.iter()).all(|(a, &b)| *a == b as u64) && l.len() == LOG2.len());
    let e = read_hex("rtl/rx_backend/bk_exp2.hex");
    assert!(e.iter().zip(EXP2.iter()).all(|(a, &b)| *a == b as u64) && e.len() == EXP2.len());
    let s = read_hex("sim/rx_backend/bk_sine.hex");
    assert!(s.iter().zip(SINE.iter()).all(|(a, &b)| sext(*a, 18) == b as i64) && s.len() == SINE.len());
    let vh = std::fs::read_to_string(std::format!("{}/../../rtl/rx_backend/bk_consts.vh", env!("CARGO_MANIFEST_DIR"))).unwrap();
    assert!(vh.contains(&std::format!("BK_KINV = {KINV};")));
    for (i, a) in ATAN.iter().enumerate() {
        assert!(vh.contains(&std::format!("5'd{i}: bk_atan = 24'd{a};")));
    }
}

// ---------------------------------------------------------------------------------------------
// Measurements through the integer chain (docs/R4_BACKEND.md section 5).
// ---------------------------------------------------------------------------------------------

use super::design;
use super::stim::Xorshift;
use super::*;
use std::vec::Vec;

const TAU: f64 = core::f64::consts::TAU;

/// Complex f64 tone rounded to integers with +/-1 LSB triangular dither.
struct DitherTone {
    f: f64,
    fs: f64,
    amp: f64,
    n: u64,
    rng: Xorshift,
}

impl DitherTone {
    fn new(f: f64, fs: f64, amp: f64, seed: u32) -> Self {
        DitherTone { f, fs, amp, n: 0, rng: Xorshift(seed | 1) }
    }
    fn dither(&mut self) -> f64 {
        (self.rng.next() as f64 + self.rng.next() as f64) / 4_294_967_296.0 - 1.0
    }
    fn next(&mut self) -> (i64, i64) {
        let ph = TAU * self.f * self.n as f64 / self.fs;
        self.n += 1;
        let (di, dq) = (self.dither(), self.dither());
        (libm::round(self.amp * libm::cos(ph) + di) as i64, libm::round(self.amp * libm::sin(ph) + dq) as i64)
    }
}

/// |mean(x * e^(-j 2 pi f n / fs))| for complex samples.
fn corr_c(x: &[(i64, i64)], f: f64, fs: f64) -> f64 {
    let (mut sr, mut si) = (0.0f64, 0.0f64);
    for (n, &(a, b)) in x.iter().enumerate() {
        let ph = -TAU * f * n as f64 / fs;
        let (c, s) = (libm::cos(ph), libm::sin(ph));
        sr += a as f64 * c - b as f64 * s;
        si += a as f64 * s + b as f64 * c;
    }
    libm::sqrt(sr * sr + si * si) / x.len() as f64
}

/// Amplitude of a real tone at f.
fn corr_r(x: &[f64], f: f64, fs: f64) -> f64 {
    let (mut sr, mut si) = (0.0f64, 0.0f64);
    for (n, &a) in x.iter().enumerate() {
        let ph = -TAU * f * n as f64 / fs;
        sr += a * libm::cos(ph);
        si += a * libm::sin(ph);
    }
    2.0 * libm::sqrt(sr * sr + si * si) / x.len() as f64
}

fn db(v: f64) -> f64 {
    20.0 * libm::log10(v)
}

/// Channel-filter outputs (24 ksps) of a receiver fed `n24` samples' worth of `src` at 48 ksps.
fn filter_outputs(bank: &CoefBank, mut src: impl FnMut() -> (i64, i64), n24: usize, skip: usize) -> Vec<(i64, i64)> {
    let mut cfg = RxConfig::default();
    cfg.in_rate = 0;
    cfg.in_shift = 0;
    let mut rx = Receiver::new(cfg);
    let mut ys = Vec::new();
    while ys.len() < n24 + skip {
        let (i, q) = src();
        rx.push(i, q, bank);
        if let Some(y) = rx.last_y {
            ys.push(y);
        }
    }
    ys.split_off(skip)
}

/// Level of a tone at `f` relative to one at `f_ref`, measured at the channel-filter output of
/// the integer chain (48 ksps input, half-band, filter), and the same ratio of the float design
/// and of the integer coefficients evaluated in f64.
fn relative_level(bank: &CoefBank, fd: &design::FloatDesign, f_ref: f64, f: f64, n: usize) -> (f64, f64, f64) {
    let amp = 4_194_304.0; // 2^22, -6 dB of the 24-bit scale
    let mut tr = DitherTone::new(f_ref, 48_000.0, amp, 7);
    let r = filter_outputs(bank, || tr.next(), n, 2_048);
    let mut tt = DitherTone::new(f, 48_000.0, amp, 11);
    let t = filter_outputs(bank, || tt.next(), n, 2_048);
    let model = db(corr_c(&t, f, 24_000.0) / corr_c(&r, f_ref, 24_000.0));
    let float = db(design::response(fd, f, 24_000.0) / design::response(fd, f_ref, 24_000.0));
    let dq = design::dequantize(bank);
    let quant = db(design::response(&dq, f, 24_000.0) / design::response(&dq, f_ref, 24_000.0));
    (model, float, quant)
}

/// The done-test criterion (docs/R4_BACKEND.md section 5.2): where the float design is above
/// -110 dB the integer chain is within 1 dB of it; deeper than that the chain must reject by at
/// least 105 dB (the 24-bit filter output cannot represent a residual much below one LSB of a
/// -6 dB tone, -132 dB). The integer coefficients alone must match the float design within
/// 0.1 dB down to -130 dB and within 0.5 dB down to -150 dB.
fn check_level(what: &str, f: f64, model: f64, float: f64, quant: f64) {
    std::println!("MEASURED {what} {f:+7.0} Hz: integer chain {model:8.2} dB, float design {float:8.2} dB, integer coefficients {quant:8.2} dB");
    if float > -110.0 {
        assert!(libm::fabs(model - float) <= 1.0, "{what} {f}: chain {model} vs float {float}");
    } else {
        assert!(model <= -105.0, "{what} {f}: chain {model} dB, float {float}");
    }
    let tol = if float > -130.0 { 0.1 } else { 0.5 };
    if float > -150.0 {
        assert!(libm::fabs(quant - float) <= tol, "{what} {f}: coefficients {quant} vs float {float}");
    }
}

#[test]
fn ssb_opposite_sideband_rejection_matches_float_design() {
    let n = 6_000;
    for (name, lo, hi, sign) in [("USB 300-2700", 300.0, 2700.0, 1.0), ("LSB 300-2700", -2700.0, -300.0, -1.0)] {
        let fd = design::bandpass(24_000.0, lo, hi, 1024);
        let bank = design::quantize(&fd);
        for f in [-2500.0, -1500.0, -1000.0, -500.0, -300.0, -200.0, 0.0, 150.0, 200.0, 250.0, 300.0, 350.0, 2650.0, 2700.0, 2750.0, 2800.0, 3000.0] {
            let (model, float, quant) = relative_level(&bank, &fd, sign * 1000.0, sign * f, n);
            check_level(name, sign * f, model, float, quant);
        }
    }
}

#[test]
fn cw_300hz_filter_skirts_match_float_design() {
    let n = 6_000;
    let fd = design::bandpass(24_000.0, 550.0, 850.0, 1024);
    let bank = design::quantize(&fd);
    for off in [-600.0, -300.0, -250.0, -225.0, -200.0, -175.0, -150.0, -100.0, 100.0, 150.0, 175.0, 200.0, 225.0, 250.0, 300.0, 600.0] {
        let (model, float, quant) = relative_level(&bank, &fd, 700.0, 700.0 + off, n);
        check_level("CW 300 Hz at 700", 700.0 + off, model, float, quant);
    }
}

// ---------------------------------------------------------------------------------------------
// AGC against tr-dsp::agc (docs/R4_BACKEND.md section 5.3).
// ---------------------------------------------------------------------------------------------

const FS24: f64 = 24_000.0;

/// Log2 gain (per 24 ksps sample) of the integer AGC for a tone whose envelope follows `env`.
fn model_gain_trace(agc: AgcConfig, env: &[f64]) -> Vec<f64> {
    let cfg = PostConfig { mode: Mode::Ssb, out24: true, agc, ..PostConfig::default() };
    let mut p = post::Post::default();
    let mut g = Vec::with_capacity(env.len());
    for (n, &a) in env.iter().enumerate() {
        let ph = TAU * 1000.0 * n as f64 / FS24;
        p.push(&cfg, (libm::round(a * libm::cos(ph)) as i64, libm::round(a * libm::sin(ph)) as i64));
        g.push(p.gain() as f64 / 1024.0);
    }
    g
}

/// Linear gain of tr-dsp's float AGC on the same envelope.
fn trdsp_gain_trace(attack_ms: f32, decay_ms: f32, hang_ms: f32, reference: f32, gmin: f32, gmax: f32, env: &[f64]) -> Vec<f64> {
    let mut a = crate::agc::Agc::new(FS24 as f32, attack_ms, decay_ms, hang_ms, reference, gmin, gmax);
    env.iter().map(|&e| a.process_mag(e as f32) as f64).collect()
}

/// Samples until `trace[k]` has covered `frac` of the way from `trace[start]` to `target`.
fn time_to(trace: &[f64], start: usize, target: f64, frac: f64) -> f64 {
    let from = trace[start];
    for (k, &v) in trace.iter().enumerate().skip(start) {
        if (v - from) / (target - from) >= frac {
            return (k - start) as f64 / FS24 * 1000.0;
        }
    }
    f64::NAN
}

fn agc_cfg(attack_ms: f64, decay_ms: f64, hang_ms: f64) -> AgcConfig {
    AgcConfig {
        enable: true,
        attack: Alpha::from_time_constant(attack_ms, FS24),
        decay: Alpha::from_time_constant(decay_ms, FS24),
        hang: libm::round(hang_ms * 24.0) as u16,
        reference: 21 << 12,
        gmax: 12 << 12,
        gmin: -8 << 12,
        manual: 0,
    }
}

#[test]
fn agc_time_constants_match_tr_dsp() {
    // Levels relative to the reference 2^21: attack steps 6 dB and 46 dB, decay the reverse.
    let r = (1u64 << 21) as f64;
    for (attack_ms, decay_ms) in [(2.0, 250.0), (5.0, 300.0), (20.0, 1000.0)] {
        for step_db in [6.0206, 46.0] {
            let lo = r * libm::pow(10.0, -step_db / 20.0);
            let hi = r;
            let pre = 24_000usize;
            let n = pre + (10.0 * decay_ms * 24.0) as usize;
            // attack: lo (gain settles at lo's target) -> hi
            let env: Vec<f64> = (0..n).map(|k| if k < pre { lo } else { hi }).collect();
            let gm = model_gain_trace(agc_cfg(attack_ms, decay_ms, 0.0), &env);
            let gf = trdsp_gain_trace(attack_ms as f32, decay_ms as f32, 0.0, r as f32, 1.0 / 256.0, 4096.0, &env);
            let tm = time_to(&gm, pre, 0.0, 1.0 - libm::exp(-1.0));
            let tf = time_to(&gf, pre, 1.0, 1.0 - libm::exp(-1.0));
            // the same 63 % point, but of tr-dsp's trajectory measured in dB (the model's domain)
            let gf_log: Vec<f64> = gf.iter().map(|v| libm::log2(*v)).collect();
            let tf_db = time_to(&gf_log, pre, 0.0, 1.0 - libm::exp(-1.0));
            let tm95 = time_to(&gm, pre, 0.0, 0.95);
            let gm_lin: Vec<f64> = gm.iter().map(|v| libm::pow(2.0, *v)).collect();
            let tm_lin = time_to(&gm_lin, pre, 1.0, 1.0 - libm::exp(-1.0));
            std::println!(
                "MEASURED AGC attack, tc {attack_ms} ms, {step_db:.0} dB step: fixed-point {tm:.2} ms (63 % in dB), tr-dsp {tf:.2} ms (63 % of linear gain); \
                 cross-domain: tr-dsp in dB {tf_db:.2} ms, fixed-point in linear gain {tm_lin:.2} ms; fixed-point 95 % in dB {tm95:.2} ms"
            );
            assert!(libm::fabs(tm - tf) <= 0.1 * tf, "attack {attack_ms} ms: {tm} vs {tf}");
            // decay: hi -> lo, hang 0
            let env: Vec<f64> = (0..n).map(|k| if k < pre { hi } else { lo }).collect();
            let gm = model_gain_trace(agc_cfg(attack_ms, decay_ms, 0.0), &env);
            let gf = trdsp_gain_trace(attack_ms as f32, decay_ms as f32, 0.0, r as f32, 1.0 / 256.0, 4096.0, &env);
            let target_log = step_db / 6.0206;
            let tm = time_to(&gm, pre, target_log, 1.0 - libm::exp(-1.0));
            let tf = time_to(&gf, pre, libm::pow(2.0, target_log), 1.0 - libm::exp(-1.0));
            std::println!("MEASURED AGC decay, tc {decay_ms} ms, {step_db:.0} dB step: fixed-point {tm:.1} ms (63 % in dB), tr-dsp {tf:.1} ms (63 % of linear gain)");
            assert!(libm::fabs(tm - tf) <= 0.1 * tf, "decay {decay_ms} ms: {tm} vs {tf}");
        }
    }
}

#[test]
fn agc_hang_holds_the_gain() {
    let r = (1u64 << 21) as f64;
    let pre = 12_000usize;
    let hang_ms = 100.0;
    // Loud enough that the gain sits at its minimum and every sample is an attack sample, so the
    // hang counter is reloaded on the last sample before the drop.
    let env: Vec<f64> = (0..pre + 6_000).map(|k| if k < pre { 4.0 * r } else { r / 100.0 }).collect();
    let mut cfg = agc_cfg(2.0, 250.0, hang_ms);
    cfg.gmin = -1 << 12;
    let g = model_gain_trace(cfg, &env);
    let hang = (hang_ms * 24.0) as usize;
    let held = g[pre..pre + hang].iter().all(|v| *v == g[pre - 1]);
    let moved = g[pre + hang + 1] > g[pre - 1];
    std::println!("MEASURED AGC hang: gain unchanged for {hang} samples ({hang_ms} ms): {held}; rising after: {moved}");
    assert!(held && moved);
}

// ---------------------------------------------------------------------------------------------
// Every mode at every input rate (docs/R4_BACKEND.md section 5.4).
// ---------------------------------------------------------------------------------------------

fn in_fs(rate: u8) -> f64 {
    (48_000u32 << rate) as f64
}

/// Runs a receiver until `n_out` outputs exist; returns them.
fn run_rx(cfg: RxConfig, bank: &CoefBank, mut src: impl FnMut(u64) -> (i64, i64), n_out: usize) -> Vec<Stamped> {
    let mut rx = Receiver::new(cfg);
    let mut out = Vec::new();
    let mut n = 0u64;
    while out.len() < n_out {
        let (i, q) = src(n);
        n += 1;
        if let Some(o) = rx.push(i, q, bank) {
            out.push(o);
        }
    }
    out
}

/// Least-squares fit of `c + a cos + b sin` at frequency f; returns (amplitude, residual power).
fn tone_fit(x: &[f64], f: f64, fs: f64) -> (f64, f64) {
    // normal equations for [1, cos, sin]
    let mut m = [[0.0f64; 3]; 3];
    let mut v = [0.0f64; 3];
    for (n, &y) in x.iter().enumerate() {
        let ph = TAU * f * n as f64 / fs;
        let b = [1.0, libm::cos(ph), libm::sin(ph)];
        for r in 0..3 {
            v[r] += b[r] * y;
            for c in 0..3 {
                m[r][c] += b[r] * b[c];
            }
        }
    }
    // Gaussian elimination
    for col in 0..3 {
        for r in col + 1..3 {
            let k = m[r][col] / m[col][col];
            for c in 0..3 {
                m[r][c] -= k * m[col][c];
            }
            v[r] -= k * v[col];
        }
    }
    let mut p = [0.0f64; 3];
    for r in (0..3).rev() {
        let mut acc = v[r];
        for c in r + 1..3 {
            acc -= m[r][c] * p[c];
        }
        p[r] = acc / m[r][r];
    }
    let mut res = 0.0;
    for (n, &y) in x.iter().enumerate() {
        let ph = TAU * f * n as f64 / fs;
        let e = y - p[0] - p[1] * libm::cos(ph) - p[2] * libm::sin(ph);
        res += e * e;
    }
    (libm::sqrt(p[1] * p[1] + p[2] * p[2]), res / x.len() as f64)
}

/// Frequency of the strongest component of a real signal (coarse search, then refinement), and
/// the amplitude and SNR (fitted tone power over the residual, DC removed) of a tone at
/// `f_expected`, which the chain reproduces exactly (every rate is an exact ratio).
fn tone_and_snr(x: &[f64], fs: f64, f_expected: f64) -> (f64, f64, f64) {
    let mut best = (0.0, 0.0);
    let mut f = 50.0;
    while f < fs / 2.0 - 50.0 {
        let a = corr_r(x, f, fs);
        if a > best.1 {
            best = (f, a);
        }
        f += 10.0;
    }
    let mut fbest = best.0;
    let mut abest = tone_fit(x, fbest, fs).0;
    let mut step = 5.0;
    while step > 0.001 {
        for cand in [fbest - step, fbest + step] {
            let a = tone_fit(x, cand, fs).0;
            if a > abest {
                abest = a;
                fbest = cand;
            }
        }
        step /= 2.0;
    }
    let (a, res) = tone_fit(x, f_expected, fs);
    (fbest, a, 10.0 * libm::log10(a * a / 2.0 / res.max(1e-12)))
}

fn tone_src(f: f64, fs: f64, amp: f64, seed: u32) -> impl FnMut(u64) -> (i64, i64) {
    let mut t = DitherTone::new(f, fs, amp, seed);
    move |_| t.next()
}

#[test]
fn every_mode_at_every_input_rate() {
    let usb = design::quantize(&design::bandpass(FS24, 300.0, 2700.0, 1024));
    let lsb = design::quantize(&design::bandpass(FS24, -2700.0, -300.0, 1024));
    let cw = design::quantize(&design::bandpass(FS24, 550.0, 850.0, 1024));
    let am = design::quantize(&design::bandpass(FS24, -4000.0, 4000.0, 511));
    // +/-8 kHz: with +/-6 kHz the 5th Bessel sideband pair of 2.5 kHz deviation at 1 kHz is cut
    // and the audio has a -45 dB 5th harmonic.
    let fm = design::quantize(&design::bandpass(FS24, -8000.0, 8000.0, 255));
    for rate in 0..4u8 {
        let fs = in_fs(rate);
        let base = RxConfig { in_rate: rate, in_shift: 6, ..RxConfig::default() };
        let amp = 20_000.0; // bank scale; x64 = 1.28e6 on the 24-bit scale (-16 dB)
        let n_out = 3_000;
        let settle = 1_200;
        let audio = |o: &[Stamped]| o[settle..].iter().map(|s| s.out.s0 as f64).collect::<Vec<f64>>();

        // USB, LSB, CW: a tone at +1000 / -1000 / +700 Hz.
        for (name, bank, f_in, f_out) in [("USB", &usb, 1000.0, 1000.0), ("LSB", &lsb, -1000.0, 1000.0), ("CW", &cw, 700.0, 700.0)] {
            let o = run_rx(base, bank, tone_src(f_in, fs, amp, 3), n_out);
            let (f, a, snr) = tone_and_snr(&audio(&o), 12_000.0, f_out);
            std::println!("MEASURED {name} at {} ksps in: {f:.2} Hz, amplitude {a:.0} (AGC target 8192), SNR {snr:.1} dB", fs / 1e3);
            assert!(libm::fabs(f - f_out) < 0.5 && libm::fabs(a / 8192.0 - 1.0) < 0.05 && snr > 60.0);
        }

        // AM envelope and synchronous: carrier + 70 % modulation at 1 kHz; SAM with the carrier
        // 30 Hz off and rotated by 100 degrees. The AGC is a peak AGC: it puts the envelope peak
        // (1.7 x carrier) at the reference, so the audio amplitude is 0.7 / 1.7 x 8192 = 3373.
        // Longer run: the carrier (DC) remover has a 43 ms time constant.
        for (mode, off_hz, ph0) in [(Mode::Am, 0.0, 0.0), (Mode::Sam, 30.0, 1.745)] {
            let mut cfg = base;
            cfg.post.mode = mode;
            let o = run_rx(
                cfg,
                &am,
                |n| {
                    let t = n as f64 / fs;
                    let env = amp * (1.0 + 0.7 * libm::cos(TAU * 1000.0 * t));
                    let ph = TAU * off_hz * t + ph0;
                    (libm::round(env * libm::cos(ph)) as i64, libm::round(env * libm::sin(ph)) as i64)
                },
                7_000,
            );
            let x: Vec<f64> = o[5_000..].iter().map(|s| s.out.s0 as f64).collect();
            let (f, a, snr) = tone_and_snr(&x, 12_000.0, 1000.0);
            std::println!("MEASURED {mode:?} at {} ksps in: {f:.2} Hz, amplitude {a:.0} (expected 3373), SNR {snr:.1} dB", fs / 1e3);
            assert!(libm::fabs(f - 1000.0) < 0.5 && libm::fabs(a / 3373.0 - 1.0) < 0.05 && snr > 50.0);
        }

        // FM: 2.5 kHz deviation at 1 kHz, no de-emphasis; the output is 2^23 x deviation / 12 kHz
        // on the 24-bit scale (manual gain 0 dB in FM mode).
        let mut cfg = base;
        cfg.post.mode = Mode::Fm;
        let o = run_rx(
            cfg,
            &fm,
            |n| {
                let t = n as f64 / fs;
                let ph = 2500.0 / 1000.0 * libm::sin(TAU * 1000.0 * t);
                (libm::round(amp * libm::cos(ph)) as i64, libm::round(amp * libm::sin(ph)) as i64)
            },
            n_out,
        );
        let (f, a, snr) = tone_and_snr(&audio(&o), 12_000.0, 1000.0);
        let want = 2500.0 / 12_000.0 * 32_768.0;
        std::println!("MEASURED FM at {} ksps in: {f:.2} Hz, amplitude {a:.0} (expected {want:.0}), SNR {snr:.1} dB", fs / 1e3);
        // 0.29 % low: a one-sample phase difference is a discriminator with a sinc(f/24 kHz) response.
        assert!(libm::fabs(f - 1000.0) < 0.5 && libm::fabs(a / want - 1.0) < 0.01 && snr > 60.0);

        // IQ pass-through at 24 ksps out: a tone at -3 kHz stays at -3 kHz.
        let mut cfg = base;
        cfg.post.mode = Mode::Iq;
        cfg.post.out24 = true;
        cfg.post.agc.enable = false;
        let o = run_rx(cfg, &fm, tone_src(-3000.0, fs, amp, 5), n_out);
        let iq: Vec<(i64, i64)> = o[settle..].iter().map(|s| (s.out.s0 as i64, s.out.s1 as i64)).collect();
        let pos = corr_c(&iq, 3000.0, FS24);
        let neg = corr_c(&iq, -3000.0, FS24);
        let want = amp * 64.0 / 256.0;
        std::println!("MEASURED IQ at {} ksps in, 24 ksps out: -3 kHz tone amplitude {neg:.1} (expected {want:.1}), image {:.1} dB", fs / 1e3, db(pos / neg));
        assert!(libm::fabs(neg / want - 1.0) < 0.01 && db(pos / neg) < -80.0);
    }
}

fn collect24(rate: u8, bank: &CoefBank, mut src: impl FnMut() -> (i64, i64)) -> Vec<(i64, i64)> {
    let cfg = RxConfig { in_rate: rate, in_shift: 0, ..RxConfig::default() };
    let mut rx = Receiver::new(cfg);
    let mut ys = Vec::new();
    while ys.len() < 4_000 {
        let (i, q) = src();
        rx.push(i, q, bank);
        if let Some(y) = rx.last_y {
            ys.push(y);
        }
    }
    ys.split_off(400)
}

#[test]
fn decimator_rejects_every_alias_by_100_db() {
    // Identity channel filter: the 24 ksps output shows what the half-bands let through. A tone at
    // 1 kHz + k x 24 kHz lands on 1 kHz after decimation unless rejected.
    let bank = CoefBank::identity();
    for rate in 0..4u8 {
        let fs = in_fs(rate);
        let amp = 4_194_304.0;
        let reference = {
            let mut t = DitherTone::new(1000.0, fs, amp, 9);
            corr_c(&collect24(rate, &bank, || t.next()), 1000.0, FS24)
        };
        let mut worst: f64 = -300.0;
        let kmax = (fs / 2.0 / 24_000.0) as i64;
        for k in -kmax..=kmax {
            let f = 1000.0 + k as f64 * 24_000.0;
            if k == 0 || libm::fabs(f) >= fs / 2.0 {
                continue;
            }
            let mut t = DitherTone::new(f, fs, amp, 13);
            let lvl = db(corr_c(&collect24(rate, &bank, || t.next()), 1000.0, FS24) / reference);
            worst = worst.max(lvl);
        }
        std::println!("MEASURED decimation {} ksps -> 24 ksps: worst alias onto 1 kHz {worst:.1} dB", fs / 1e3);
        assert!(worst < -100.0);
    }
}

#[test]
fn noise_blanker_removes_impulses() {
    let bank = design::quantize(&design::bandpass(FS24, 300.0, 2700.0, 1024));
    let fs = in_fs(3);
    for enable in [false, true] {
        let mut cfg = RxConfig { in_rate: 3, in_shift: 6, ..RxConfig::default() };
        cfg.nb = NbConfig { enable, thr: 6 * 16, hold: 38, k_down: 9, k_up: 13 };
        cfg.post.agc.enable = false;
        cfg.post.agc.manual = 2 << 12;
        let mut tone = DitherTone::new(1000.0, fs, 5_000.0, 21);
        let mut rx = Receiver::new(cfg);
        let mut out = Vec::new();
        let mut n = 0u64;
        while out.len() < 3_000 {
            let (mut i, mut q) = tone.next();
            if n % 4_000 < 3 && n > 20_000 {
                i = 3_000_000;
                q = -2_000_000;
            }
            n += 1;
            if let Some(o) = rx.push(i, q, &bank) {
                out.push(o.out.s0 as f64);
            }
        }
        let (_, a, snr) = tone_and_snr(&out[600..], 12_000.0, 1000.0);
        std::println!(
            "MEASURED noise blanker {}: 1 kHz tone amplitude {a:.0}, SNR {snr:.1} dB, blanked {} samples",
            if enable { "on " } else { "off" },
            rx.blanked()
        );
        if enable {
            // The held samples themselves (0.1 ms every 10.4 ms) limit it; tr-dsp's blanker too.
            assert!(snr > 30.0 && rx.blanked() > 0);
        } else {
            assert!(snr < 20.0);
        }
    }
}

#[test]
fn stamps_count_hl2_samples() {
    let bank = CoefBank::identity();
    for rate in 0..4u8 {
        for out24 in [false, true] {
            let mut cfg = RxConfig { in_rate: rate, ..RxConfig::default() };
            cfg.post.out24 = out24;
            let o = run_rx(cfg, &bank, |_| (0, 0), 5);
            let per = if out24 { 3_200 } else { 6_400 };
            for (k, s) in o.iter().enumerate() {
                assert_eq!(s.stamp_off, (k as u64 + 1) * per - adc_per_input(rate));
            }
        }
    }
}

#[test]
fn squelch_follows_the_smeter() {
    let bank = design::quantize(&design::bandpass(FS24, -4000.0, 4000.0, 255));
    let mut cfg = RxConfig { in_rate: 0, in_shift: 6, ..RxConfig::default() };
    cfg.post.mode = Mode::Fm;
    cfg.post.sq_enable = true;
    cfg.post.sq_open = -40 * 64;
    cfg.post.sq_close = -45 * 64;
    // -30 dB of the 24-bit scale for 0.5 s, then -60 dB
    let loud = libm::pow(10.0, -30.0 / 20.0) * 8_388_608.0 / 64.0;
    let mut t1 = DitherTone::new(500.0, 48_000.0, loud, 1);
    let mut t2 = DitherTone::new(500.0, 48_000.0, loud / 31.623, 2);
    let mut rx = Receiver::new(cfg);
    let mut states = Vec::new();
    for n in 0..48_000u64 {
        let (i, q) = if n < 24_000 { t1.next() } else { t2.next() };
        if rx.push(i, q, &bank).is_some() {
            states.push((rx.squelch_open(), rx.smeter_db64()));
        }
    }
    let (open_mid, db_mid) = states[5_000];
    let (open_end, db_end) = states[states.len() - 1];
    std::println!(
        "MEASURED squelch: S-meter {:.2} dB -> open {open_mid}; S-meter {:.2} dB -> open {open_end}",
        db_mid as f64 / 64.0,
        db_end as f64 / 64.0
    );
    assert!(open_mid && !open_end);
    assert!(libm::fabs(db_mid as f64 / 64.0 + 30.0) < 0.2 && libm::fabs(db_end as f64 / 64.0 + 60.0) < 0.3);
}



