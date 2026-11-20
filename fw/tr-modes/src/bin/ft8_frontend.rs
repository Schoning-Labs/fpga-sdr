// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! `ft8-frontend`, the host tool for the FT8 front-end model of `tr_modes::frontend` (docs/S15_FT8MODEL.md).
//!
//! The model is the fixed-point (and a floating point) twin of what the FPGA and the AE350 CPU do together on an
//! FT8 slot, so this tool serves three jobs. It compares the model with mfsk-core and with WSJT-X on recordings and
//! on synthetic signals (`wav`, `sweep`, `effort-sweep`, `ladder`), it records what the fabric hands to the CPU so
//! QEMU can replay it (`trace`), and it writes the ROM contents and testbench vectors for the Verilog under `rtl/`
//! and `sim/`, plus the checks that compare the RTL's output with the model (`tables`, `*-vectors`, `*-check`).
//! The stages are the spectrogram (docs/F5_FT8SPEC.md), the sync search (docs/F6_SYNC.md), the candidate baseband
//! and symbol extraction (docs/F7_CAND.md) and the second pass (docs/FT8_PASS2.md).
//!
//! ```sh
//! ft8-frontend wav <file.wav> [max_cand] [passes] [osd_max] [effort]  decode: mfsk-core vs fixed vs float
//! ft8-frontend sweep [snr_min snr_max step trials sigma max_cand mfsk]  50 % thresholds, fixed vs float
//!                                                   (mfsk = 1 adds mfsk-core's own pipeline)
//! ft8-frontend effort-sweep <lo> <hi> <step> <trials> <kind> <max_cand> <effort>...
//!                                                   50 % thresholds of several efforts, fixed point,
//!                                                   paired trials; kind cq | std
//! ft8-frontend ladder <file.wav> <max_cand> <passes> <effort>  per-candidate rung statistics
//! ft8-frontend trace <file.wav> <out.bin> [max_cand] [passes] [effort] [osd_max]  fabric trace for QEMU
//!                                                   (effort: a spec of tr_modes::frontend::effort, or
//!                                                   0 = "none", 1 = "full")
//! ft8-frontend tables <dir>                                         ROM files for the RTL
//! ft8-frontend vectors <file.wav> <dir> [n]                         spectrogram, sync and candidate vectors
//! ft8-frontend sync-vectors <file.wav> <dir> <ia> <ib> <n_rows> [w0 w1]  sync search testbench vectors
//! ft8-frontend pass2-vectors <file.wav> <dir> [max_cand]            second pass: the residual buffer
//! ft8-frontend pass2-check <file.wav> <rtl_records.hex> <rtl_spec.hex> [max_cand]   RTL replay vs model
//! ft8-frontend sync-check <file.wav> <rtl_records.hex> [n_rows]     sync search: RTL records vs
//!                                                   model, candidate list, decodes (WSJT-X list)
//! ft8-frontend f7-vectors <file.wav> <dir> [n]                      candidate stage testbench vectors (real audio)
//! ft8-frontend f7-synth <dir>                                       candidate stage unit test vectors (LCG audio)
//! ft8-frontend cand-check <file.wav> <rtl_pass1.hex> <rtl_pass2.hex>  candidate stage: RTL words vs
//!                                                   model, LDPC on the RTL soft symbols
//! ```

use std::env;
use std::time::Instant;

use mfsk_core::ft8::Ft8;
use mfsk_core::msg::decode_request::DecodeRequest;
use mfsk_core::msg::wsjt77::unpack77;
use tr_modes::frontend::decode::{decode_slot, CandLog, DecodeParams, ModelFabric, Recording};
use tr_modes::frontend::effort::{effort_spec, parse_effort};
use tr_modes::frontend::tables::Tables;
use tr_modes::frontend::{trace, Arith, SLOT_LEN};

/// Reads a 12 kHz mono 16-bit WAV file and pads it with zeros to one 15 s slot. Panics with the path when the
/// file is missing or has another format, which is fine for a tool run by hand.
fn load_wav_i16(path: &str) -> Vec<i16> {
    let bytes = std::fs::read(path).unwrap_or_else(|e| panic!("{path}: {e}"));
    assert!(bytes.len() > 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WAVE", "{path}: not a WAV");
    let mut i = 12usize;
    let (mut rate, mut bits, mut ch, mut off, mut len) = (0u32, 0u16, 0u16, 0usize, 0usize);
    while i + 8 <= bytes.len() {
        let id = &bytes[i..i + 4];
        let l = u32::from_le_bytes(bytes[i + 4..i + 8].try_into().unwrap()) as usize;
        i += 8;
        if id == b"fmt " {
            ch = u16::from_le_bytes(bytes[i + 2..i + 4].try_into().unwrap());
            rate = u32::from_le_bytes(bytes[i + 4..i + 8].try_into().unwrap());
            bits = u16::from_le_bytes(bytes[i + 14..i + 16].try_into().unwrap());
        } else if id == b"data" {
            off = i;
            len = l.min(bytes.len() - i);
        }
        i += l + (l & 1);
    }
    assert!(ch == 1 && rate == 12_000 && bits == 16 && off > 0, "{path}: need 12 kHz mono 16-bit");
    let mut v: Vec<i16> = bytes[off..off + len].chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect();
    v.resize(SLOT_LEN, 0);
    v
}

/// Decodes with mfsk-core's own single pass pipeline (the reference the front end is compared with) and returns
/// the message texts.
fn mfsk_core_decode(audio: &[i16], p: &DecodeParams) -> Vec<String> {
    DecodeRequest::<Ft8>::new(audio, p.freq_min, p.freq_max, p.sync_min, p.max_cand)
        .decode()
        .results
        .into_iter()
        .filter_map(|r| unpack77(r.message77()))
        .collect()
}

/// Decodes with the front-end model in the given arithmetic. Each entry is message, frequency in Hz, time offset
/// in s, SNR in dB and the pass that found it (0 for the first).
fn model_decode(arith: Arith, audio: &[i16], p: &DecodeParams) -> Vec<(String, f32, f32, f32, u8)> {
    let mut fab = ModelFabric::new(arith);
    let (d, _) = decode_slot(&mut fab, audio, p, &|| 0);
    d.into_iter()
        .filter_map(|x| unpack77(x.result.message77()).map(|m| (m, x.result.freq_hz, x.result.dt_sec, x.result.snr_db, x.pass)))
        .collect()
}

/// `wav`: decodes one recording with mfsk-core and with the model in fixed and floating point, and lists
/// what each found and what only one of them found.
fn cmd_wav(args: &[String]) {
    let path = &args[0];
    let max_cand: usize = args.get(1).map(|s| s.parse().unwrap()).unwrap_or(60);
    let passes: usize = args.get(2).map(|s| s.parse().unwrap()).unwrap_or(1);
    let osd_max: usize = args.get(3).map(|s| s.parse().unwrap()).unwrap_or(usize::MAX);
    let effort = parse_effort(args.get(4).map(String::as_str).unwrap_or("full")).unwrap();
    let audio = load_wav_i16(path);
    let p = DecodeParams { max_cand, passes, osd_max, effort, ..DecodeParams::default() };
    let t = Instant::now();
    let base = mfsk_core_decode(&audio, &p);
    let t_base = t.elapsed().as_secs_f64();
    println!("{path}: max_cand {max_cand}, sync_min {}, band {}-{} Hz, passes {passes}", p.sync_min, p.freq_min, p.freq_max);
    println!("mfsk-core single pass: {} decodes ({t_base:.2} s)", base.len());
    for m in &base {
        println!("    {m}");
    }
    for arith in [Arith::Fixed, Arith::Float] {
        let t = Instant::now();
        let d = model_decode(arith, &audio, &p);
        let el = t.elapsed().as_secs_f64();
        let only: Vec<&String> = d.iter().map(|x| &x.0).filter(|m| !base.contains(m)).collect();
        let missed: Vec<&String> = base.iter().filter(|m| !d.iter().any(|x| &x.0 == *m)).collect();
        println!("model {arith:?}: {} decodes ({el:.2} s); not in mfsk-core: {}; mfsk-core only: {}", d.len(), only.len(), missed.len());
        for (m, f, dt, snr, pass) in &d {
            let tag = if base.contains(m) { " " } else { "+" };
            println!("  {tag} pass {pass} {f:7.1} Hz {dt:+5.2} s {snr:+4.0} dB  {m}");
        }
        for m in missed {
            println!("  - (missed) {m}");
        }
    }
}

// ── Sensitivity sweep (same channel and SNR convention as src/bin/sensitivity_sweep.rs) ──

/// 64-bit linear congruential generator with a Box-Muller Gaussian, the same noise source as the
/// sensitivity sweep, so a trial depends only on its seed.
struct Lcg(u64);
impl Lcg {
    fn new(seed: u64) -> Self {
        Lcg(seed.wrapping_add(0x9E37_79B9_7F4A_7C15))
    }
    fn uniform(&mut self) -> f64 {
        self.0 = self.0.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        ((self.0 >> 32) as f64 + 1.0) / 4_294_967_297.0
    }
    fn gaussian(&mut self) -> f64 {
        let (u1, u2) = (self.uniform(), self.uniform());
        (-2.0 * u1.ln()).sqrt() * (2.0 * std::f64::consts::PI * u2).cos()
    }
}

const CALLS: &[&str] = &["JA1ABC", "K1JT", "W1AW", "VE3ABC", "G4XYZ", "DL1AAA", "VK2XYZ", "PY2ABC"];
const GRIDS: &[&str] = &["PM95", "FN42", "EM12", "JO52", "IO91", "KN07", "QF56", "GG66"];

/// One trial: a CQ message at a random frequency (300 to 2,700 Hz) and time offset (+/-0.3 s) in Gaussian noise of
/// unit variance, with the SNR defined in a 2,500 Hz bandwidth. The mix is then scaled so that the noise has a
/// standard deviation of `sigma` LSB, which is the audio level the decoder sees. Returns the audio, the message
/// text to look for and the frequency.
fn make_trial(snr_db: f64, seed: u64, sigma: f64) -> (Vec<i16>, String, f32) {
    use mfsk_core::ft8::wave_gen::{message_to_tones, tones_to_f32};
    use mfsk_core::msg::wsjt77::pack77;
    let mut rng = Lcg::new(seed ^ 0xA5A5_A5A5_A5A5_A5A5);
    let call = CALLS[(rng.uniform() * CALLS.len() as f64) as usize % CALLS.len()];
    let grid = GRIDS[(rng.uniform() * GRIDS.len() as f64) as usize % GRIDS.len()];
    let freq = 300.0 + rng.uniform() * 2_400.0;
    let toff = -0.3 + rng.uniform() * 0.6;
    let msg = pack77("CQ", call, grid).unwrap();
    let amp = (4.0 * 10f64.powf(snr_db / 10.0) * 2_500.0 / 12_000.0).sqrt();
    let pcm = tones_to_f32(&message_to_tones(&msg), freq as f32, amp as f32);
    let mut mix = vec![0f64; SLOT_LEN];
    let start = ((0.5 + toff) * 12_000.0).round().max(0.0) as usize;
    for (i, &v) in pcm.iter().enumerate() {
        if start + i < SLOT_LEN {
            mix[start + i] = v as f64;
        }
    }
    let mut noise = Lcg::new(seed);
    let audio = mix.iter().map(|&s| ((s + noise.gaussian()) * sigma).round().clamp(-32_768.0, 32_767.0) as i16).collect();
    (audio, format!("CQ {call} {grid}"), freq as f32)
}

/// SNR at which the hit rate first rises through 0.5, interpolated linearly between the two neighboring steps.
/// `rows` holds (SNR in dB, hit rate) in ascending SNR order.
fn fifty_point(rows: &[(f64, f64)]) -> Option<f64> {
    for w in rows.windows(2) {
        let ((s0, r0), (s1, r1)) = (w[0], w[1]);
        if r0 < 0.5 && r1 >= 0.5 {
            return Some(s0 + (0.5 - r0) * (s1 - s0) / (r1 - r0));
        }
    }
    None
}

/// `sweep`: hit rate of the fixed point model, the floating point model and optionally mfsk-core against SNR,
/// each trial decoded in a +/-100 Hz window around the true frequency, and the 50 % points of each. Trials of one
/// SNR step run on all cores.
fn cmd_sweep(args: &[String]) {
    let g = |i: usize, d: f64| args.get(i).map(|s| s.parse().unwrap()).unwrap_or(d);
    let (lo, hi, step, trials, sigma, max_cand) = (g(0, -23.0), g(1, -18.0), g(2, 0.5), g(3, 40.0) as u64, g(4, 1_000.0), g(5, 20.0) as usize);
    println!("sweep: SNR {lo}..{hi} step {step}, {trials} trials/step, noise sigma {sigma} LSB, band +/-100 Hz, max_cand {max_cand}");
    println!("{:>7} {:>10} {:>10} {:>10}", "SNR dB", "fixed", "float", "mfsk-core");
    let with_mfsk = args.get(6).map(|s| s == "1").unwrap_or(false);
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    let mut rows = [Vec::new(), Vec::new(), Vec::new()];
    let mut snr = lo;
    while snr <= hi + 1e-9 {
        let hits = std::sync::Mutex::new([0u64; 3]);
        let next = std::sync::atomic::AtomicU64::new(0);
        std::thread::scope(|sc| {
            for _ in 0..threads {
                sc.spawn(|| loop {
                    let tr = next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    if tr >= trials {
                        break;
                    }
                    let seed = 1_000_003u64.wrapping_mul((snr * 10.0).round() as i64 as u64).wrapping_add(tr);
                    let (audio, want, f) = make_trial(snr, seed, sigma);
                    let p = DecodeParams { freq_min: (f - 100.0).max(50.0), freq_max: f + 100.0, sync_min: 1.0, max_cand, ..DecodeParams::default() };
                    let mut h = [0u64; 3];
                    for (k, arith) in [Arith::Fixed, Arith::Float].into_iter().enumerate() {
                        if model_decode(arith, &audio, &p).iter().any(|d| d.0 == want) {
                            h[k] = 1;
                        }
                    }
                    if with_mfsk && mfsk_core_decode(&audio, &p).iter().any(|m| *m == want) {
                        h[2] = 1;
                    }
                    let mut g = hits.lock().unwrap();
                    for k in 0..3 {
                        g[k] += h[k];
                    }
                });
            }
        });
        let hits = hits.into_inner().unwrap();
        let r: Vec<f64> = hits.iter().map(|&h| h as f64 / trials as f64).collect();
        println!("{snr:>7.1} {:>6}/{trials} {:>6}/{trials} {:>6}/{trials}", hits[0], hits[1], hits[2]);
        for k in 0..3 {
            rows[k].push((snr, r[k]));
        }
        snr += step;
    }
    let names = ["fixed", "float", "mfsk-core"];
    for k in 0..if with_mfsk { 3 } else { 2 } {
        match fifty_point(&rows[k]) {
            Some(v) => println!("50 % point {}: {v:.2} dB", names[k]),
            None => println!("50 % point {}: not crossed in range", names[k]),
        }
    }
    if let (Some(a), Some(b)) = (fifty_point(&rows[0]), fifty_point(&rows[1])) {
        println!("fixed minus float: {:+.2} dB (positive = fixed needs more SNR)", a - b);
    }
}

/// Like `make_trial`, but `kind` "std" gives a standard message "<call1> <call2> <grid>", so the blind-CQ a-priori
/// pass cannot help, unlike with the CQ messages of `sweep`.
fn make_trial_kind(snr_db: f64, seed: u64, sigma: f64, kind: &str) -> (Vec<i16>, String, f32) {
    if kind == "cq" {
        return make_trial(snr_db, seed, sigma);
    }
    use mfsk_core::ft8::wave_gen::{message_to_tones, tones_to_f32};
    use mfsk_core::msg::wsjt77::pack77;
    let mut rng = Lcg::new(seed ^ 0x5A5A_5A5A_5A5A_5A5A);
    let i1 = (rng.uniform() * CALLS.len() as f64) as usize % CALLS.len();
    let i2 = (i1 + 1 + (rng.uniform() * (CALLS.len() - 1) as f64) as usize % (CALLS.len() - 1)) % CALLS.len();
    let grid = GRIDS[(rng.uniform() * GRIDS.len() as f64) as usize % GRIDS.len()];
    let freq = 300.0 + rng.uniform() * 2_400.0;
    let toff = -0.3 + rng.uniform() * 0.6;
    let msg = pack77(CALLS[i1], CALLS[i2], grid).unwrap();
    let amp = (4.0 * 10f64.powf(snr_db / 10.0) * 2_500.0 / 12_000.0).sqrt();
    let pcm = tones_to_f32(&message_to_tones(&msg), freq as f32, amp as f32);
    let mut mix = vec![0f64; SLOT_LEN];
    let start = ((0.5 + toff) * 12_000.0).round().max(0.0) as usize;
    for (i, &v) in pcm.iter().enumerate() {
        if start + i < SLOT_LEN {
            mix[start + i] = v as f64;
        }
    }
    let mut noise = Lcg::new(seed);
    let audio = mix.iter().map(|&s| ((s + noise.gaussian()) * sigma).round().clamp(-32_768.0, 32_767.0) as i16).collect();
    (audio, format!("{} {} {grid}", CALLS[i1], CALLS[i2]), freq as f32)
}

/// Short label of the rung of the decoding ladder that decoded a candidate (belief propagation, OSD or one of the
/// a-priori passes, with the variant letter), or "-" when none did.
fn rung_label(l: &CandLog) -> String {
    use mfsk_core::ft8::decode_block::Rung;
    match l.rung {
        Some(Rung::Bp { variant }) => format!("bp{}", ["a", "b", "c", "d"][variant as usize]),
        Some(Rung::Osd { variant, seed }) => format!("osd{}{}", ["a", "b", "c", "d"][variant as usize], seed),
        Some(Rung::Ap { pass, variant, osd }) => format!("ap{pass}{}{}", ["a", "b", "c", "d"][variant as usize], if osd { "osd" } else { "bp" }),
        None => String::from("-"),
    }
}

/// `effort-sweep`: 50 % thresholds of several decoding efforts on the same trials (fixed point front end, +/-100 Hz
/// window, sync threshold 1.0, as in `sweep`), with the OSD work each effort spends per trial and the rungs that
/// decoded.
fn cmd_effort_sweep(args: &[String]) {
    let g = |i: usize, d: f64| args.get(i).map(|s| s.parse().unwrap()).unwrap_or(d);
    let (lo, hi, step, trials) = (g(0, -23.0), g(1, -19.0), g(2, 0.5), g(3, 200.0) as u64);
    let kind = args.get(4).cloned().unwrap_or_else(|| String::from("cq"));
    let max_cand = g(5, 20.0) as usize;
    let efforts: Vec<_> = args[6..].iter().map(|s| parse_effort(s).unwrap_or_else(|e| panic!("{s}: {e}"))).collect();
    let n = efforts.len();
    let sigma = 1_000.0;
    println!("effort-sweep: SNR {lo}..{hi} step {step}, {trials} trials/step, messages {kind}, noise {sigma} LSB, +/-100 Hz, max_cand {max_cand}");
    for (k, e) in efforts.iter().enumerate() {
        println!("  E{k}: {}", effort_spec(e));
    }
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    let mut rows: Vec<Vec<(f64, f64)>> = vec![Vec::new(); n];
    // Per effort: OSD searches, a-priori OSD searches, candidates given to the ladder; rung histogram.
    let work = std::sync::Mutex::new(vec![(0u64, 0u64, 0u64); n]);
    let rungs = std::sync::Mutex::new(vec![std::collections::BTreeMap::<String, u64>::new(); n]);
    let mut snr = lo;
    while snr <= hi + 1e-9 {
        let hits = std::sync::Mutex::new(vec![0u64; n]);
        let next = std::sync::atomic::AtomicU64::new(0);
        std::thread::scope(|sc| {
            for _ in 0..threads {
                sc.spawn(|| loop {
                    let tr = next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    if tr >= trials {
                        break;
                    }
                    let seed = 1_000_003u64.wrapping_mul((snr * 10.0).round() as i64 as u64).wrapping_add(tr);
                    let (audio, want, f) = make_trial_kind(snr, seed, sigma, &kind);
                    for (k, e) in efforts.iter().enumerate() {
                        let p = DecodeParams { freq_min: (f - 100.0).max(50.0), freq_max: f + 100.0, sync_min: 1.0, max_cand, effort: *e, ..DecodeParams::default() };
                        let mut fab = ModelFabric::new(Arith::Fixed);
                        let (d, st) = decode_slot(&mut fab, &audio, &p, &|| 0);
                        let pos = d.iter().position(|x| unpack77(x.result.message77()).as_deref() == Some(want.as_str()));
                        {
                            let mut w = work.lock().unwrap();
                            w[k].0 += st.osd_searches as u64;
                            w[k].1 += st.ap_osd_searches as u64;
                            w[k].2 += st.log.len() as u64;
                        }
                        if let Some(i) = pos {
                            hits.lock().unwrap()[k] += 1;
                            // The log entry of the decoded candidate: the decoded entry with that frequency.
                            let fr = d[i].result.freq_hz;
                            if let Some(l) = st.log.iter().find(|l| l.outcome == 0 && l.freq_hz == fr) {
                                *rungs.lock().unwrap()[k].entry(rung_label(l)).or_insert(0) += 1;
                            }
                        }
                    }
                });
            }
        });
        let hits = hits.into_inner().unwrap();
        print!("{snr:>6.1}");
        for k in 0..n {
            print!(" {:>4}/{trials}", hits[k]);
            rows[k].push((snr, hits[k] as f64 / trials as f64));
        }
        println!();
        snr += step;
    }
    let total_trials = trials * rows[0].len() as u64;
    let w = work.into_inner().unwrap();
    let r = rungs.into_inner().unwrap();
    let base = fifty_point(&rows[0]);
    for k in 0..n {
        let fp = fifty_point(&rows[k]);
        let d = match (fp, base) {
            (Some(a), Some(b)) => format!("{:+.2} dB vs E0", a - b),
            _ => String::from("-"),
        };
        let fps = fp.map(|v| format!("{v:.2} dB")).unwrap_or_else(|| String::from("not crossed"));
        println!(
            "E{k} 50 % point {fps} ({d}); per trial: OSD searches {:.2}, a-priori OSD searches {:.2}, ladder candidates {:.2}; rungs {:?}",
            w[k].0 as f64 / total_trials as f64,
            w[k].1 as f64 / total_trials as f64,
            w[k].2 as f64 / total_trials as f64,
            r[k]
        );
    }
}

/// `ladder`: per-candidate outcomes, rungs and work counts of one recording under one effort.
fn cmd_ladder(args: &[String]) {
    let audio = load_wav_i16(&args[0]);
    let max_cand: usize = args.get(1).map(|s| s.parse().unwrap()).unwrap_or(60);
    let passes: usize = args.get(2).map(|s| s.parse().unwrap()).unwrap_or(1);
    let effort = effort_arg(args.get(3));
    let osd_max: usize = args.get(4).map(|s| s.parse().unwrap()).unwrap_or(usize::MAX);
    let p = DecodeParams { max_cand, passes, osd_max, effort, ..DecodeParams::default() };
    let mut fab = ModelFabric::new(Arith::Fixed);
    let (d, st) = decode_slot(&mut fab, &audio, &p, &|| 0);
    println!("{}: effort {}, {} decodes, {} OSD searches, {} a-priori OSD searches", args[0], effort_spec(&effort), d.len(), st.osd_searches, st.ap_osd_searches);
    let names = ["decoded", "duplicate", "implausible", "failed", "below-sync"];
    for l in &st.log {
        println!(
            "  pass {} q {:2} {:11} {:10} bp {} osd {} (npre2 {}) ap-bp {} ap-osd {}",
            l.pass, l.q, names[l.outcome as usize], rung_label(l), l.work.bp_runs, l.work.osd_searches, l.work.osd_npre2, l.work.ap_bp_runs, l.work.ap_osd_searches
        );
    }
    for x in &d {
        println!("DECODE pass {} {:7.1} Hz {}", x.pass, x.result.freq_hz, unpack77(x.result.message77()).unwrap_or_default());
    }
}

/// Effort argument of the command line: a spec string, with 0 meaning "none" and 1 or no argument meaning "full".
fn effort_arg(a: Option<&String>) -> mfsk_core::ft8::decode_block::Ft8Effort {
    let spec = match a.map(String::as_str) {
        None | Some("1") => "full",
        Some("0") => "none",
        Some(s) => s,
    };
    parse_effort(spec).unwrap_or_else(|e| panic!("effort '{spec}': {e}"))
}

/// `trace`: decodes a recording with the fixed point model while recording every exchange between CPU and fabric,
/// and writes the trace for the QEMU replay (tools/qemu_s15.sh). The decodes are printed as `EXPECT` lines for
/// that replay to compare against.
fn cmd_trace(args: &[String]) {
    let audio = load_wav_i16(&args[0]);
    let max_cand: usize = args.get(2).map(|s| s.parse().unwrap()).unwrap_or(60);
    let passes: usize = args.get(3).map(|s| s.parse().unwrap()).unwrap_or(1);
    let effort = effort_arg(args.get(4));
    let osd_max: usize = args.get(5).map(|s| s.parse().unwrap()).unwrap_or(usize::MAX);
    let p = DecodeParams { max_cand, passes, osd_max, effort, ..DecodeParams::default() };
    let mut fab = ModelFabric::new(Arith::Fixed);
    fab.recording = Some(Recording::default());
    let (d, _) = decode_slot(&mut fab, &audio, &p, &|| 0);
    let rec = fab.recording.take().unwrap();
    let bytes = trace::write_trace(&audio, &p, &rec);
    std::fs::write(&args[1], &bytes).unwrap();
    println!("{}: {} events, {} bytes, {} decodes:", args[1], rec.events.len(), bytes.len(), d.len());
    for x in &d {
        println!("EXPECT {}", unpack77(x.result.message77()).unwrap_or_default());
    }
}

/// `tables`: writes the ROM contents of the fixed point model (twiddles, NCO, filter taps) as hex files for the RTL.
fn cmd_tables(args: &[String]) {
    let dir = std::path::Path::new(&args[0]);
    std::fs::create_dir_all(dir).unwrap();
    let t = Tables::new();
    let hex18 = |v: i32| format!("{:05x}", (v as u32) & 0x3_ffff);
    let pair = |(a, b): (i32, i32)| format!("{:09x}", (((a as u64) & 0x3_ffff) << 18) | ((b as u64) & 0x3_ffff));
    let write = |name: &str, lines: Vec<String>| {
        let path = dir.join(name);
        std::fs::write(&path, lines.join("\n") + "\n").unwrap();
        println!("wrote {} ({} entries)", path.display(), lines.len());
    };
    write("ft8_w3840.hex", t.w3840.iter().map(|&w| pair(w)).collect());
    // Octant-compressed ROM for the RTL combine stage (docs/F5_FT8SPEC.md): the same first-octant table that
    // `Tables::new()` uses internally to build `w3840` (`octant_table(3840)`, which is `pub`), so the RTL's
    // `ft8_tw3840.v` (address to octant, reflection and 45 degree mapping, the scheme of rtl/fft/fft_twmul.v
    // generalized to a length that is not a power of two) and the flat 3,840 entry table agree on every value by
    // construction, without spending 3,840 words of block RAM on a table of which only one eighth is independent.
    let oct3840 = tr_modes::frontend::tables::octant_table(3_840);
    let oct_lines: Vec<String> = (0..oct3840.0.len()).map(|r| pair((oct3840.0[r], oct3840.1[r]))).collect();
    write("ft8_w3840_oct.hex", oct_lines);
    write("ft8_w32.hex", t.w32.iter().map(|&w| pair(w)).collect());
    // NCO ROM of the candidate stage (docs/F7_CAND.md section 2.3): the quarter wave q[i] = sin(2 pi i / 4,096)
    // (i = 0 ..= 1,024, the table `Tables::new()` builds `nco` from) packed as 512 words {q[j], q[1,024 - j]},
    // j = 0 .. 511, which is one 512 x 36 single port block ROM. q[512] (45 degrees) is a constant in the RTL. The
    // assertion below checks that the RTL's lookup (rtl/ft8/ft8_nco.v) of every index gives the model's table.
    let q: Vec<i32> = (0..=1024).map(|i| t.nco[i % 4096].1).collect();
    let rtl_lookup = |i: usize| -> (i32, i32) {
        let (quad, r) = (i >> 10, i & 1023);
        let a = if r >= 512 { 1024 - r } else { r };
        let (qa, qb) = if a == 512 { (q[512], q[512]) } else { (q[a], q[1024 - a]) };
        let (qr, qc) = if r >= 512 { (qb, qa) } else { (qa, qb) }; // q[r], q[1024 - r]
        match quad {
            0 => (qc, qr),
            1 => (-qr, qc),
            2 => (-qc, -qr),
            _ => (qr, -qc),
        }
    };
    for i in 0..4096 {
        assert_eq!(rtl_lookup(i), t.nco[i], "NCO ROM mapping at index {i}");
    }
    write("ft8_nco_q512.hex", (0..512).map(|j| pair((q[j], q[1024 - j]))).collect());
    write("ft8_nco4096.hex", t.nco.iter().map(|&w| pair(w)).collect());
    write(&format!("ft8_fir{}.hex", t.fir.len()), t.fir.iter().map(|&h| hex18(h)).collect());
}

/// `vectors`: test vectors for the spectrogram, sync and candidate testbenches: the slot audio, the spectrogram
/// words, the sync records and, for the first `n` candidates, the baseband and symbol requests and outputs of the
/// candidate stage.
fn cmd_vectors(args: &[String]) {
    use tr_modes::frontend::decode::Event;
    use tr_modes::frontend::spectrogram::{spectrogram_fx, PWR_SHIFT_DEFAULT};
    let audio = load_wav_i16(&args[0]);
    let dir = std::path::Path::new(&args[1]);
    let n: usize = args.get(2).map(|s| s.parse().unwrap()).unwrap_or(8);
    std::fs::create_dir_all(dir).unwrap();
    let w = |name: &str, lines: Vec<String>| {
        std::fs::write(dir.join(name), lines.join("\n") + "\n").unwrap();
        println!("wrote {} ({} lines)", dir.join(name).display(), lines.len());
    };
    w("audio.hex", audio.iter().map(|&x| format!("{:04x}", x as u16)).collect());
    let t = Tables::new();
    let s = spectrogram_fx(&t, &audio, PWR_SHIFT_DEFAULT);
    w("spectrogram_sh16.hex", s.iter().map(|&x| format!("{x:08x}")).collect());
    let p = DecodeParams { max_cand: 60, ..DecodeParams::default() };
    let mut fab = ModelFabric::new(Arith::Fixed);
    fab.recording = Some(Recording::default());
    decode_slot(&mut fab, &audio, &p, &|| 0);
    let hex32 = |v: i32| format!("{:08x}", v as u32);
    let (mut nb, mut ns) = (0usize, 0usize);
    for e in &fab.recording.as_ref().unwrap().events {
        match e {
            Event::Sync { band, words } => {
                let mut l = vec![format!("# ia {} ib {}: per bin lag_p|lag_s<<8, sp[-1,0,+1], ss[-1,0,+1], 0", band.ia, band.ib)];
                l.extend(words.iter().map(|r| r.iter().map(|x| format!("{x:08x}")).collect::<Vec<_>>().join(" ")));
                w("sync.txt", l);
            }
            Event::Baseband { slot, inc, words } if nb < n => {
                let mut l = vec![format!("# slot {slot} inc {inc:08x}: 3200 lines re im")];
                l.extend(words.iter().map(|&(r, i)| format!("{} {}", hex32(r), hex32(i))));
                w(&format!("cand{nb:02}_pass1.txt"), l);
                nb += 1;
            }
            Event::Symbols { slot, rinc, i0, words } if ns < n => {
                let mut l = vec![format!("# slot {slot} rinc {rinc:08x} i0 {i0}: 79 x 8 lines re im (symbol-major)")];
                l.extend(words.iter().map(|&(r, i)| format!("{} {}", hex32(r), hex32(i))));
                w(&format!("cand{ns:02}_pass2.txt"), l);
                ns += 1;
            }
            _ => {}
        }
    }
}

// ── Testbench vectors and RTL checks for the sync and candidate stages (docs/F6_SYNC.md, docs/F7_CAND.md) ──

/// WSJT-X's own reference decodes of `qso3_busy.wav` (tests/wsjtx_samples.rs, docs/S5_MODES.md).
const WSJTX_QSO3_BUSY: &[&str] = &[
    "CQ F5RXL IN94",
    "N1JFU EA6EE R-07",
    "A92EE F5PSR -14",
    "W0RSJ EA3BMU RR73",
    "K1JT HA0DU KN07",
    "N1PJT HB9CQK -10",
    "K1BZM DK8NE -10",
    "KD2UGC F6GCP R-23",
];

/// Packs two 32-bit words into one 64-bit lane word, `lo` in the low half, as the RTL stores them, in hex.
fn lane_word(lo: u32, hi: u32) -> String {
    format!("{:016x}", ((hi as u64) << 32) | lo as u64)
}

/// Reads a hex file of 64-bit words, one per line, skipping blank lines and lines that start with `//` or `#`.
fn read_hex_u64(path: &str) -> Vec<u64> {
    std::fs::read_to_string(path)
        .unwrap_or_else(|e| panic!("{path}: {e}"))
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with("//") && !l.starts_with('#'))
        .map(|l| u64::from_str_radix(l, 16).unwrap_or_else(|e| panic!("{path}: {l:?}: {e}")))
        .collect()
}

/// `sync-vectors`: spectrogram rows as 64-bit lane words (bin 2w low half, 2w + 1 high half; lane words
/// `w0 ..= w1` of every one of the 372 rows, default the whole row) and the model's per-bin
/// records for band `ia ..= ib` over the first `n_rows` frames, as 4 lane words per bin
/// (record words 2i low, 2i + 1 high).
fn cmd_sync_vectors(args: &[String]) {
    use tr_modes::frontend::spectrogram::{spectrogram_fx, PWR_SHIFT_DEFAULT};
    use tr_modes::frontend::sync::{sync_fx_rows, SyncBand};
    use tr_modes::frontend::{K_BINS, N_TIME};
    let audio = load_wav_i16(&args[0]);
    let dir = std::path::Path::new(&args[1]);
    let ia: usize = args[2].parse().unwrap();
    let ib: usize = args[3].parse().unwrap();
    let n_rows: usize = args[4].parse().unwrap();
    let w0: usize = args.get(5).map(|s| s.parse().unwrap()).unwrap_or(0);
    let w1: usize = args.get(6).map(|s| s.parse().unwrap()).unwrap_or(K_BINS / 2 - 1);
    std::fs::create_dir_all(dir).unwrap();
    let t = Tables::new();
    let s = spectrogram_fx(&t, &audio, PWR_SHIFT_DEFAULT);
    let mut l = Vec::with_capacity(N_TIME * (w1 - w0 + 1));
    for m in 0..N_TIME {
        for w in w0..=w1 {
            l.push(lane_word(s[m * K_BINS + 2 * w], s[m * K_BINS + 2 * w + 1]));
        }
    }
    std::fs::write(dir.join("spec_lw.hex"), l.join("\n") + "\n").unwrap();
    let band = SyncBand { ia, ib };
    let rec: Vec<String> = sync_fx_rows(&s, band, n_rows)
        .iter()
        .flat_map(|b| {
            let w = b.to_words();
            (0..4).map(move |i| lane_word(w[2 * i], w[2 * i + 1])).collect::<Vec<_>>()
        })
        .collect();
    std::fs::write(dir.join("sync_expect.hex"), rec.join("\n") + "\n").unwrap();
    println!(
        "wrote {}: spec_lw.hex ({} rows x lane words {w0}..={w1}), sync_expect.hex ({} bins {ia}..={ib}, {n_rows} rows)",
        dir.display(),
        N_TIME,
        ib - ia + 1
    );
}

/// A fabric whose first sync answer is the RTL's records, the rest from the fixed-point model;
/// it keeps each pass's candidate list.
struct RtlSyncFabric {
    inner: ModelFabric,
    rtl: Option<Vec<[u32; 8]>>,
    cands_pass: Vec<Vec<mfsk_core::engine::sync::SyncCandidate>>,
}

impl tr_modes::frontend::decode::Fabric for RtlSyncFabric {
    fn sync(&mut self, audio: &[i16], band: tr_modes::frontend::sync::SyncBand) -> Vec<tr_modes::frontend::sync::BinSync> {
        use tr_modes::frontend::decode::bins_from_words;
        let bins = match self.rtl.take() {
            Some(words) => bins_from_words(&words),
            None => self.inner.sync(audio, band),
        };
        let p = DecodeParams::default();
        self.cands_pass.push(tr_modes::frontend::candidates::candidates(&bins, band, p.sync_min, p.max_cand));
        bins
    }
    fn baseband(&mut self, audio: &[i16], slot: usize, inc: u32) -> Vec<num_complex::Complex<f32>> {
        self.inner.baseband(audio, slot, inc)
    }
    fn symbols(&mut self, slot: usize, rinc: u32, i0: i32) -> Box<tr_modes::frontend::decode::Cs> {
        self.inner.symbols(slot, rinc, i0)
    }
}

/// `sync-check`, the done-test of the sync search on one recording: the RTL's per-bin records (4 lane words per bin, band
/// 100-3,000 Hz as `DecodeParams::default()`) equal the model's; the candidate list built from
/// them (60 candidates, sync threshold 1.3); the two-pass decode that starts from them, each
/// decode with the nearest candidate of each pass's list; for `qso3_busy`, WSJT-X's own eight
/// decodes.
fn cmd_sync_check(args: &[String]) {
    use tr_modes::frontend::spectrogram::{spectrogram_fx, PWR_SHIFT_DEFAULT};
    use tr_modes::frontend::sync::{sync_fx_rows, SyncBand};
    use tr_modes::frontend::N_TIME;
    let audio = load_wav_i16(&args[0]);
    let lw = read_hex_u64(&args[1]);
    let n_rows: usize = args.get(2).map(|s| s.parse().unwrap()).unwrap_or(N_TIME);
    let p = DecodeParams { max_cand: 60, passes: 2, ..DecodeParams::default() };
    let band = SyncBand::from_hz(p.freq_min, p.freq_max);
    let t = Tables::new();
    let s = spectrogram_fx(&t, &audio, PWR_SHIFT_DEFAULT);
    let model: Vec<[u32; 8]> = sync_fx_rows(&s, band, n_rows).iter().map(|b| b.to_words()).collect();
    assert_eq!(lw.len(), 4 * model.len(), "{}: {} lane words, want 4 x {} bins", args[1], lw.len(), model.len());
    let rtl: Vec<[u32; 8]> = lw.chunks_exact(4).map(|c| core::array::from_fn(|i| (c[i / 2] >> (32 * (i % 2))) as u32)).collect();
    let mism = rtl.iter().zip(&model).filter(|(a, b)| a != b).count();
    println!(
        "{}: band {}..={} ({} bins), {n_rows} rows: {} of {} RTL records differ from the model",
        args[0],
        band.ia,
        band.ib,
        model.len(),
        mism,
        model.len()
    );
    if n_rows != N_TIME {
        println!("{}", if mism == 0 { "PASS: sync-check (records only; early-decode rows)" } else { "FAIL: sync-check" });
        return;
    }
    let mut fab = RtlSyncFabric { inner: ModelFabric::new(Arith::Fixed), rtl: Some(rtl), cands_pass: Vec::new() };
    let (d, _) = decode_slot(&mut fab, &audio, &p, &|| 0);
    let msgs: Vec<(String, f32, f32, u8)> =
        d.iter().filter_map(|x| unpack77(x.result.message77()).map(|m| (m, x.result.freq_hz, x.result.dt_sec, x.pass))).collect();
    let c1 = fab.cands_pass[0].clone();
    println!("pass-1 candidate list from the RTL records: {} candidates; {} decodes in two passes", c1.len(), msgs.len());
    let near = |f: f32, dt: f32, list: &[mfsk_core::engine::sync::SyncCandidate]| -> Option<(usize, f32, f32)> {
        list.iter()
            .enumerate()
            .map(|(i, c)| (i, c.freq_hz - f, c.dt_sec - dt))
            .filter(|&(_, df, ddt)| df.abs() <= 3.2 && ddt.abs() <= 0.1)
            .min_by(|a, b| (a.1.abs() + 10.0 * a.2.abs()).partial_cmp(&(b.1.abs() + 10.0 * b.2.abs())).unwrap())
    };
    let show = |n: Option<(usize, f32, f32)>| match n {
        Some((i, df, ddt)) => format!("#{i:2} (df {df:+.2} Hz, ddt {ddt:+.3} s)"),
        None => String::from("none within 3.2 Hz / 0.1 s"),
    };
    for (m, f, dt, pass) in &msgs {
        let n2 = fab.cands_pass.get(1).and_then(|c2| near(*f, *dt, c2));
        println!("  pass {pass} {f:7.1} Hz {dt:+5.2} s  {m:24} pass-1 list {}; pass-2 list {}", show(near(*f, *dt, &c1)), show(n2));
    }
    let mut missing = 0;
    if args[0].contains("qso3_busy") {
        for g in WSJTX_QSO3_BUSY {
            match msgs.iter().find(|x| x.0 == *g) {
                Some((_, f, dt, pass)) => println!(
                    "  WSJT-X {g:20} decoded in pass {pass}; pass-1 list {}",
                    show(near(*f, *dt, &c1))
                ),
                None => {
                    println!("  WSJT-X {g:20} NOT decoded");
                    missing += 1;
                }
            }
        }
    }
    let ok = mism == 0 && missing == 0;
    println!("{}", if ok { "PASS: sync-check" } else { "FAIL: sync-check" });
}

/// The model's residual of a recording: the first pass at `max_cand` candidates, its decodes
/// subtracted. Returns the decoder (first pass done), the residual and the settings.
fn pass2_residual(audio: &[i16], max_cand: usize) -> (tr_modes::frontend::decode::SlotDecoder, Vec<i16>, DecodeParams) {
    use tr_modes::frontend::decode::SlotDecoder;
    let p = DecodeParams { max_cand, passes: 2, ..DecodeParams::default() };
    let mut fab = ModelFabric::new(Arith::Fixed);
    let mut d = SlotDecoder::new();
    d.run_pass(&mut fab, audio, &p, 0, &|| 0);
    let residual = d.subtract(audio, &|| 0);
    (d, residual, p)
}

/// `pass2-vectors`: vectors for sim/ft8/ft8_pass2_wav_harness.v (docs/FT8_PASS2.md): the residual of
/// the model's first pass as the CPU writes it to DDR3 (`residual_lw.hex`, 45,000 lane words).
fn cmd_pass2_vectors(args: &[String]) {
    use tr_modes::frontend::replay::pack_residual;
    let audio = load_wav_i16(&args[0]);
    let dir = std::path::Path::new(&args[1]);
    let max_cand: usize = args.get(2).map(|s| s.parse().unwrap()).unwrap_or(60);
    std::fs::create_dir_all(dir).unwrap();
    let (d, residual, _) = pass2_residual(&audio, max_cand);
    let l: Vec<String> = pack_residual(&residual).iter().map(|w| format!("{w:016x}")).collect();
    std::fs::write(dir.join("residual_lw.hex"), l.join("\n") + "\n").unwrap();
    println!("wrote {}: residual_lw.hex ({} lane words; {} first-pass decodes subtracted, {max_cand} candidates)", dir.display(), l.len(), d.all.len());
}

/// A fabric whose second sync answer (the residual's) is the RTL's records; everything else from
/// the fixed-point model.
struct RtlPass2Fabric {
    inner: ModelFabric,
    rtl: Option<Vec<[u32; 8]>>,
    syncs: usize,
}

impl tr_modes::frontend::decode::Fabric for RtlPass2Fabric {
    fn sync(&mut self, audio: &[i16], band: tr_modes::frontend::sync::SyncBand) -> Vec<tr_modes::frontend::sync::BinSync> {
        self.syncs += 1;
        match (self.syncs, self.rtl.take()) {
            (2, Some(words)) => tr_modes::frontend::decode::bins_from_words(&words),
            (_, keep) => {
                self.rtl = keep;
                self.inner.sync(audio, band)
            }
        }
    }
    fn baseband(&mut self, audio: &[i16], slot: usize, inc: u32) -> Vec<num_complex::Complex<f32>> {
        self.inner.baseband(audio, slot, inc)
    }
    fn symbols(&mut self, slot: usize, rinc: u32, i0: i32) -> Box<tr_modes::frontend::decode::Cs> {
        self.inner.symbols(slot, rinc, i0)
    }
}

/// `pass2-check`, the done-test of the second pass on one recording (docs/FT8_PASS2.md): the spectrogram the RTL's replay
/// wrote (`rtl_spec.hex`, 372 x 512 lane words) and the records of its search (`rtl_records.hex`,
/// 4 lane words per bin of 100-3,000 Hz) equal the model's replay of the same residual; the
/// two-pass decode whose second pass starts from the RTL's records; for `qso3_busy`, WSJT-X's own
/// eight decodes must all be there.
fn cmd_pass2_check(args: &[String]) {
    use tr_modes::frontend::replay::{pack_residual, replay};
    use tr_modes::frontend::spectrogram::PWR_SHIFT_DEFAULT;
    use tr_modes::frontend::sync::SyncBand;
    use tr_modes::frontend::{K_BINS, N_TIME};
    let audio = load_wav_i16(&args[0]);
    let rec_lw = read_hex_u64(&args[1]);
    let spec_lw = read_hex_u64(&args[2]);
    let max_cand: usize = args.get(3).map(|s| s.parse().unwrap()).unwrap_or(60);
    let (first, residual, p) = pass2_residual(&audio, max_cand);
    let band = SyncBand::from_hz(p.freq_min, p.freq_max);
    let t = Tables::new();
    let model = replay(&t, &pack_residual(&residual), PWR_SHIFT_DEFAULT, band);
    assert_eq!(spec_lw.len(), N_TIME * K_BINS / 2, "{}: {} lane words, want {}", args[2], spec_lw.len(), N_TIME * K_BINS / 2);
    assert_eq!(rec_lw.len(), 4 * model.records.len(), "{}: {} lane words, want 4 x {} bins", args[1], rec_lw.len(), model.records.len());
    let spec_mism = spec_lw.iter().enumerate().filter(|&(i, &w)| (w as u32, (w >> 32) as u32) != (model.spectrogram[2 * i], model.spectrogram[2 * i + 1])).count();
    let rtl: Vec<[u32; 8]> = rec_lw.chunks_exact(4).map(|c| core::array::from_fn(|i| (c[i / 2] >> (32 * (i % 2))) as u32)).collect();
    let rec_mism = rtl.iter().zip(&model.records).filter(|(a, b)| a != b).count();
    println!(
        "{}: residual after {} first-pass decodes: {} of {} spectrogram lane words and {} of {} records of the RTL differ from the model",
        args[0],
        first.all.len(),
        spec_mism,
        spec_lw.len(),
        rec_mism,
        rtl.len()
    );
    let mut fab = RtlPass2Fabric { inner: ModelFabric::new(Arith::Fixed), rtl: Some(rtl), syncs: 0 };
    let (d, st) = decode_slot(&mut fab, &audio, &p, &|| 0);
    let n1 = d.iter().filter(|x| x.pass == 0).count();
    println!("decode with the RTL's records for the second pass: {} messages in pass 1, {} more in pass 2 ({} candidates)", n1, d.len() - n1, st.n_cand[1]);
    let msgs: Vec<(String, u8)> = d.iter().filter_map(|x| unpack77(x.result.message77()).map(|m| (m, x.pass))).collect();
    for (m, pass) in msgs.iter().filter(|x| x.1 == 1) {
        println!("  pass {} {m}", pass + 1);
    }
    let mut missing = 0;
    if args[0].contains("qso3_busy") {
        for g in WSJTX_QSO3_BUSY {
            match msgs.iter().find(|x| x.0 == *g) {
                Some((_, pass)) => println!("  WSJT-X {g:20} decoded in pass {}", pass + 1),
                None => {
                    println!("  WSJT-X {g:20} NOT decoded");
                    missing += 1;
                }
            }
        }
    }
    let ok = spec_mism == 0 && rec_mism == 0 && missing == 0 && fab.syncs == 2;
    println!("{}", if ok { "PASS: pass2-check" } else { "FAIL: pass2-check" });
}

/// Writes the candidate stage vector files: `cands.hex` (NCO increment, rotation increment and start sample per
/// candidate), `pass1.hex` (baseband words) and `pass2.hex` (symbol words).
fn write_f7_files(dir: &std::path::Path, cands: &[(u32, u32, i32)], p1: &[Vec<(i32, i32)>], p2: &[Vec<(i32, i32)>]) {
    std::fs::create_dir_all(dir).unwrap();
    let l: Vec<String> = cands.iter().map(|&(inc, rinc, i0)| format!("{inc:08x}{rinc:08x}{:08x}", i0 as u32)).collect();
    std::fs::write(dir.join("cands.hex"), l.join("\n") + "\n").unwrap();
    let w = |v: &[Vec<(i32, i32)>]| -> String {
        v.iter().flatten().map(|&(r, i)| lane_word(r as u32, i as u32)).collect::<Vec<_>>().join("\n") + "\n"
    };
    std::fs::write(dir.join("pass1.hex"), w(p1)).unwrap();
    std::fs::write(dir.join("pass2.hex"), w(p2)).unwrap();
    println!(
        "wrote {}: {} candidates (cands.hex: inc rinc i0; pass1.hex 3,200 and pass2.hex 632 lane words each, re low)",
        dir.display(),
        cands.len()
    );
}

/// `f7-vectors`: candidate stage vectors from a recording: the slot audio as 45,000 lane words (sample 4w + k in bits
/// 16k + 15 .. 16k), and the first `n` candidates of the model's one-pass decode at 60
/// candidates, in call order, with their pass-1 and pass-2 words.
fn cmd_f7_vectors(args: &[String]) {
    use tr_modes::frontend::decode::Event;
    let audio = load_wav_i16(&args[0]);
    let dir = std::path::Path::new(&args[1]);
    let n: usize = args.get(2).map(|s| s.parse().unwrap()).unwrap_or(60);
    std::fs::create_dir_all(dir).unwrap();
    let aw: Vec<String> = audio
        .chunks(4)
        .map(|c| format!("{:016x}", c.iter().enumerate().fold(0u64, |a, (k, &x)| a | ((x as u16 as u64) << (16 * k)))))
        .collect();
    std::fs::write(dir.join("audio_lw.hex"), aw.join("\n") + "\n").unwrap();
    let p = DecodeParams { max_cand: 60, ..DecodeParams::default() };
    let mut fab = ModelFabric::new(Arith::Fixed);
    fab.recording = Some(Recording::default());
    decode_slot(&mut fab, &audio, &p, &|| 0);
    let (mut incs, mut p1, mut rest, mut p2) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());
    for e in &fab.recording.as_ref().unwrap().events {
        match e {
            Event::Baseband { inc, words, .. } if p1.len() < n => {
                incs.push(*inc);
                p1.push(words.clone());
            }
            Event::Symbols { rinc, i0, words, .. } if p2.len() < n => {
                rest.push((*rinc, *i0));
                p2.push(words.clone());
            }
            _ => {}
        }
    }
    let cands: Vec<(u32, u32, i32)> = incs.iter().zip(&rest).map(|(&a, &(b, c))| (a, b, c)).collect();
    write_f7_files(dir, &cands, &p1[..cands.len()], &p2[..cands.len()]);
}

/// The synthetic slot audio of the candidate stage unit testbench (sim/ft8/tb_ft8_cand.v generates the same
/// in Verilog): x[n] = the top 16 bits of a 32-bit LCG (s = 1,664,525 s + 1,013,904,223, seed
/// 0x0F7C_A11D), full-scale random.
fn f7_synth_audio() -> Vec<i16> {
    let mut s: u32 = 0x0F7C_A11D;
    (0..SLOT_LEN)
        .map(|_| {
            s = s.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            (s >> 16) as u16 as i16
        })
        .collect()
}

/// `f7-synth`: candidate stage unit test vectors on the synthetic audio: two candidates (the two lanes of one batch),
/// pass 1 and pass 2, the second with a start sample before the baseband's first sample.
fn cmd_f7_synth(args: &[String]) {
    use tr_modes::frontend::baseband::{baseband_fx, nco_inc};
    use tr_modes::frontend::symbols::{rot_inc, symbols_fx};
    let dir = std::path::Path::new(&args[0]);
    let audio = f7_synth_audio();
    let t = Tables::new();
    let cands = [(nco_inc(1_234.5), rot_inc(0.5), 1_203), (nco_inc(2_871.25), rot_inc(-2.0), -9)];
    let (mut p1, mut p2) = (Vec::new(), Vec::new());
    for &(inc, rinc, i0) in &cands {
        let y = baseband_fx(&t, &audio, inc);
        let c = symbols_fx(&t, &y, rinc, i0);
        p2.push(c.iter().flat_map(|r| r.iter().copied()).collect());
        p1.push(y);
    }
    write_f7_files(dir, &cands, &p1, &p2);
}

/// A fabric answering pass 1 and pass 2 with the RTL's words (candidate k = the k-th call).
struct RtlCandFabric {
    inner: ModelFabric,
    p1: Vec<Vec<(i32, i32)>>,
    p2: Vec<Vec<(i32, i32)>>,
    n1: usize,
    n2: usize,
    mism: usize,
}

impl tr_modes::frontend::decode::Fabric for RtlCandFabric {
    fn sync(&mut self, audio: &[i16], band: tr_modes::frontend::sync::SyncBand) -> Vec<tr_modes::frontend::sync::BinSync> {
        self.inner.sync(audio, band)
    }
    fn baseband(&mut self, audio: &[i16], slot: usize, inc: u32) -> Vec<num_complex::Complex<f32>> {
        use tr_modes::frontend::decode::baseband_from_words;
        let m = self.inner.baseband(audio, slot, inc);
        let k = self.n1;
        self.n1 += 1;
        match self.p1.get(k) {
            Some(r) => {
                let rtl = baseband_from_words(r);
                if rtl != m {
                    self.mism += 1;
                }
                rtl
            }
            None => m,
        }
    }
    fn symbols(&mut self, slot: usize, rinc: u32, i0: i32) -> Box<tr_modes::frontend::decode::Cs> {
        use tr_modes::frontend::decode::cs_from_words;
        let m = self.inner.symbols(slot, rinc, i0);
        let k = self.n2;
        self.n2 += 1;
        match self.p2.get(k) {
            Some(r) => {
                let rtl = cs_from_words(r);
                if *rtl != *m {
                    self.mism += 1;
                }
                rtl
            }
            None => m,
        }
    }
}

/// `cand-check`, the done-test of the candidate stage on one recording: the RTL's pass-1 and pass-2 words for the
/// candidates of the model's one-pass decode at 60 candidates equal the model's, and that decode, run on the RTL's
/// words, gives the same messages as the model alone.
fn cmd_cand_check(args: &[String]) {
    use tr_modes::frontend::{BB_LEN, NN, NTONES};
    let audio = load_wav_i16(&args[0]);
    let split = |v: Vec<u64>, len: usize| -> Vec<Vec<(i32, i32)>> {
        v.chunks_exact(len).map(|c| c.iter().map(|&w| (w as u32 as i32, (w >> 32) as u32 as i32)).collect()).collect()
    };
    let p1 = split(read_hex_u64(&args[1]), BB_LEN);
    let p2 = split(read_hex_u64(&args[2]), NN * NTONES);
    let p = DecodeParams { max_cand: 60, ..DecodeParams::default() };
    let want = model_decode(Arith::Fixed, &audio, &p);
    let mut fab = RtlCandFabric { inner: ModelFabric::new(Arith::Fixed), p1, p2, n1: 0, n2: 0, mism: 0 };
    let (d, _) = decode_slot(&mut fab, &audio, &p, &|| 0);
    let got: Vec<String> = d.iter().filter_map(|x| unpack77(x.result.message77())).collect();
    let used1 = fab.p1.len().min(fab.n1);
    let used2 = fab.p2.len().min(fab.n2);
    println!(
        "{}: RTL words used for {used1} pass-1 and {used2} pass-2 calls (of {} / {} calls), {} differ from the model",
        args[0], fab.n1, fab.n2, fab.mism
    );
    println!("decodes from the RTL's soft symbols: {} (S15 model: {})", got.len(), want.len());
    for m in &got {
        println!("    {m}");
    }
    let same = got.len() == want.len() && want.iter().all(|w| got.contains(&w.0));
    let all_rtl = used1 == fab.n1 && used2 == fab.n2;
    println!("{}", if same && fab.mism == 0 && all_rtl { "PASS: cand-check" } else { "FAIL: cand-check" });
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let rest = if args.len() > 2 { &args[2..] } else { &[][..] };
    match args.get(1).map(String::as_str) {
        Some("wav") if !rest.is_empty() => cmd_wav(rest),
        Some("sweep") => cmd_sweep(rest),
        Some("trace") if rest.len() >= 2 => cmd_trace(rest),
        Some("effort-sweep") if rest.len() >= 7 => cmd_effort_sweep(rest),
        Some("ladder") if !rest.is_empty() => cmd_ladder(rest),
        Some("tables") if !rest.is_empty() => cmd_tables(rest),
        Some("vectors") if rest.len() >= 2 => cmd_vectors(rest),
        Some("sync-vectors") if rest.len() >= 5 => cmd_sync_vectors(rest),
        Some("sync-check") if rest.len() >= 2 => cmd_sync_check(rest),
        Some("pass2-vectors") if rest.len() >= 2 => cmd_pass2_vectors(rest),
        Some("pass2-check") if rest.len() >= 3 => cmd_pass2_check(rest),
        Some("f7-vectors") if rest.len() >= 2 => cmd_f7_vectors(rest),
        Some("f7-synth") if !rest.is_empty() => cmd_f7_synth(rest),
        Some("cand-check") if rest.len() >= 3 => cmd_cand_check(rest),
        _ => {
            eprintln!("usage: ft8-frontend wav <file> [max_cand] [passes] [osd_max] [effort] | sweep [lo hi step trials sigma max_cand] | effort-sweep lo hi step trials cq|std max_cand effort... | ladder <wav> [max_cand] [passes] [effort] [osd_max] | trace <wav> <out> [max_cand] [passes] [effort] [osd_max] | tables <dir> | vectors <wav> <dir> [n]");
            std::process::exit(2);
        }
    }
}
