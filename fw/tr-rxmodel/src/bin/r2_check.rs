// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Bit-exact check of the receiver bank: the same stimulus goes through `iverilog` (the real RTL,
//! `rtl/rx/*.v` via `sim/rx/r2_replay.v`) and through [`tr_rxmodel`], and the output words must be
//! identical for all 8 receivers and all 4 output rates. This binary is the single source of that
//! stimulus (a deterministic ADC stream from a PRNG plus a schedule of channel configuration and
//! disable and re-enable register writes, see [`build_stimulus`]). It writes the stimulus once to
//! `sim/rx/out/r2_stimulus.txt`, runs the generic Verilog replay harness on it, runs the same
//! stimulus through the Rust model directly (it is already in memory, so nothing is parsed again),
//! and compares the two output streams word for word and in order, so the output ordering of the
//! round-robin arbiter is checked as well as the values of each receiver. It then measures the
//! speed of the model (a single receiver, in the `--release` build of this binary) against the
//! 76.8 Msps that the simulator needs to keep up with real time.
//!
//! `tools/check.sh` runs it as `cargo run -q -p tr-rxmodel --release --bin r2_check`, and
//! `docs/R2_RXMODEL.md` has the numbers it produces.

use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

use tr_rxmodel::fir::{self, Coeffs};
use tr_rxmodel::{channel::RxChannel, RxBank};

/// Must match `sim/rx/r2_replay.v`'s `RESET_CYCLES`/`DRAIN_CYCLES` localparams exactly, both
/// sides replay the identical schedule, so both must idle for the identical number of cycles
/// around it.
const RESET_CYCLES: u32 = 5;
const DRAIN_CYCLES: u32 = 32;

const FS_HZ: f64 = 76_800_000.0;

struct ChanCfg {
    freq_hz: f64,
    rate_sel: u8,
}

/// Two receivers per output rate, at frequencies spread across the HF band, the same
/// arrangement `docs/RX_DSP.md` section 6.1's functional test uses, chosen here only to give
/// the NCO mixer a variety of quadrant/phase-increment values, not for any spectral measurement
/// (bit-exactness does not depend on what the stimulus "looks like").
const CHANNELS: [ChanCfg; 8] = [
    ChanCfg {
        freq_hz: 1_840_000.0,
        rate_sel: 0,
    },
    ChanCfg {
        freq_hz: 3_573_000.0,
        rate_sel: 0,
    },
    ChanCfg {
        freq_hz: 7_074_000.0,
        rate_sel: 1,
    },
    ChanCfg {
        freq_hz: 10_136_000.0,
        rate_sel: 1,
    },
    ChanCfg {
        freq_hz: 14_074_000.0,
        rate_sel: 2,
    },
    ChanCfg {
        freq_hz: 18_100_000.0,
        rate_sel: 2,
    },
    ChanCfg {
        freq_hz: 21_074_000.0,
        rate_sel: 3,
    },
    ChanCfg {
        freq_hz: 28_074_000.0,
        rate_sel: 3,
    },
];

/// Cycle counts for the stimulus plan (see [`build_stimulus`]). Rate 0 (48 ksps) decimates by
/// 1600, so 50,000 + 6,000 + 6,000 ADC cycles gives it roughly 38 output words across the three
/// streaming phases, enough to exercise steady-state operation, the disable, and the
/// recovery, for the slowest (most decimated) receiver in the bank.
const STREAM1: u32 = 50_000;
const STREAM2: u32 = 6_000;
const STREAM3: u32 = 6_000;
const BURSTY: u32 = 20_000;

// ---------------------------------------------------------------------------------------------
// deterministic stimulus PRNG (xorshift32), integer-only, so there is no cross-language
// floating-point risk: the RTL side never generates or recomputes this data, it only replays
// whatever this binary writes to the stimulus file (see sim/rx/r2_replay.v's module doc).
// ---------------------------------------------------------------------------------------------

fn xorshift32(state: &mut u32) -> u32 {
    let mut x = *state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    x
}

/// A 12-bit signed ADC sample (matches `rx_bank`'s `ADC_WIDTH=12`), full range including the
/// extremes.
fn prng_sample(state: &mut u32) -> i32 {
    let v12 = (xorshift32(state) & 0xFFF) as i32;
    if v12 & 0x800 != 0 {
        v12 - 0x1000
    } else {
        v12
    }
}

/// One stimulus line: `(code, f1, f2)`. `code=0`: one ADC cycle, `f1`=adc_valid (0/1),
/// `f2`=adc_data (signed 12-bit). `code=1`: one register-write cycle, `f1`=reg_addr,
/// `f2`=reg_wdata. Exactly what `sim/rx/r2_replay.v` parses and what [`run_model`] replays.
type StimLine = (i64, i64, i64);

fn phase_inc_for(freq_hz: f64) -> i32 {
    (freq_hz / FS_HZ * 4_294_967_296.0).round() as i64 as i32
}

fn control_word(enable: bool, rate_sel: u8) -> i64 {
    ((enable as i64) << 2) | (rate_sel as i64 & 0b11)
}

fn build_stimulus() -> Vec<StimLine> {
    let mut lines: Vec<StimLine> =
        Vec::with_capacity((16 + STREAM1 + 8 + 1 + STREAM2 + 8 + 1 + STREAM3 + BURSTY) as usize);
    let mut prng: u32 = 0x1234_5678;

    // ---- configure all 8 channels (idle: no adc streaming while writing) -------------------
    for (chan, cfg) in CHANNELS.iter().enumerate() {
        let addr_phase = (chan as i64) << 1;
        let addr_ctrl = addr_phase | 1;
        lines.push((1, addr_phase, phase_inc_for(cfg.freq_hz) as i64));
        lines.push((1, addr_ctrl, control_word(true, cfg.rate_sel)));
    }

    // ---- phase 1: full-rate streaming, all 8 channels enabled ------------------------------
    for _ in 0..STREAM1 {
        lines.push((0, 1, prng_sample(&mut prng) as i64));
    }

    // ---- disable channel 0 (48 ksps, slowest, most decimation, best regression target for
    // the disable/re-enable bug docs/RX_DSP.md section 1 describes) -------------------------
    for _ in 0..4 {
        lines.push((0, 0, 0));
    }
    lines.push((1, 1, control_word(false, CHANNELS[0].rate_sel))); // addr = (0<<1)|1
    for _ in 0..4 {
        lines.push((0, 0, 0));
    }

    // ---- phase 2: streaming with channel 0 disabled -----------------------------------------
    for _ in 0..STREAM2 {
        lines.push((0, 1, prng_sample(&mut prng) as i64));
    }

    // ---- re-enable channel 0 -----------------------------------------------------------------
    for _ in 0..4 {
        lines.push((0, 0, 0));
    }
    lines.push((1, 1, control_word(true, CHANNELS[0].rate_sel)));
    for _ in 0..4 {
        lines.push((0, 0, 0));
    }

    // ---- phase 3: streaming with channel 0 recovered -----------------------------------------
    for _ in 0..STREAM3 {
        lines.push((0, 1, prng_sample(&mut prng) as i64));
    }

    // ---- phase 4: bursty adc_valid (~55% duty), all channels still enabled ------------------
    // exercises the strobe-gated logic with gaps mid-stream (docs/RX_DSP.md section 1 notes
    // every stage is strobe-gated, "works ... also with a sparser/gapped valid").
    for _ in 0..BURSTY {
        let valid = (xorshift32(&mut prng) % 100) < 55;
        let data = if valid {
            prng_sample(&mut prng) as i64
        } else {
            0
        };
        lines.push((0, valid as i64, data));
    }

    lines
}

fn write_stimulus_file(path: &Path, lines: &[StimLine]) -> io::Result<()> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let mut buf = String::with_capacity(lines.len() * 10);
    for (code, f1, f2) in lines {
        buf.push_str(&format!("{code} {f1} {f2}\n"));
    }
    fs::write(path, buf)
}

// ---------------------------------------------------------------------------------------------
// Rust model side
// ---------------------------------------------------------------------------------------------

fn run_model(lines: &[StimLine], coeffs: &Coeffs) -> Vec<(usize, i32, i32)> {
    let mut bank = RxBank::default();
    let mut out = Vec::new();

    let record = |bank: &RxBank, out: &mut Vec<(usize, i32, i32)>| {
        let (valid, idx, i, q) = bank.out();
        if valid {
            out.push((idx, i, q));
        }
    };

    for _ in 0..RESET_CYCLES {
        bank.step(true, 0, false, false, 0, 0, coeffs);
        record(&bank, &mut out);
    }
    for &(code, f1, f2) in lines {
        if code == 0 {
            bank.step(false, f2 as i32, f1 != 0, false, 0, 0, coeffs);
        } else {
            bank.step(false, 0, false, true, f1 as u32, f2 as u32, coeffs);
        }
        record(&bank, &mut out);
    }
    for _ in 0..DRAIN_CYCLES {
        bank.step(false, 0, false, false, 0, 0, coeffs);
        record(&bank, &mut out);
    }

    out
}

// ---------------------------------------------------------------------------------------------
// RTL (iverilog) side
// ---------------------------------------------------------------------------------------------

fn run_iverilog(repo_root: &Path) -> io::Result<Vec<(usize, i32, i32)>> {
    let out_dir = repo_root.join("sim/rx/out");
    fs::create_dir_all(&out_dir)?;
    let vvp_path = out_dir.join("r2_replay.vvp");

    let compile = Command::new("iverilog")
        .current_dir(repo_root)
        .arg("-g2012")
        .arg("-o")
        .arg(&vvp_path)
        .arg("sim/rx/r2_replay.v")
        .output()?;
    if !compile.status.success() {
        io::stderr().write_all(&compile.stderr)?;
        return Err(io::Error::other(
            "iverilog compile of sim/rx/r2_replay.v failed",
        ));
    }

    let run = Command::new("vvp")
        .current_dir(repo_root)
        .arg(&vvp_path)
        .output()?;
    let _ = fs::remove_file(&vvp_path);

    let stdout = String::from_utf8_lossy(&run.stdout).into_owned();
    if !run.status.success() || !stdout.lines().any(|l| l == "PASS") {
        eprintln!("{stdout}");
        io::stderr().write_all(&run.stderr)?;
        return Err(io::Error::other("sim/rx/r2_replay.v did not report PASS"));
    }

    let mut result = Vec::new();
    for line in stdout.lines() {
        if let Some(rest) = line.strip_prefix("O ") {
            let parts: Vec<&str> = rest.split_whitespace().collect();
            if parts.len() != 3 {
                continue;
            }
            result.push((
                parts[0].parse().expect("bad index in RTL output line"),
                parts[1].parse().expect("bad i in RTL output line"),
                parts[2].parse().expect("bad q in RTL output line"),
            ));
        }
    }
    Ok(result)
}

// ---------------------------------------------------------------------------------------------
// speed benchmark: one receiver, running flat out with adc_valid on every cycle, which is the
// worst case because the real hardware feeds one ADC sample per clock at 76.8 MHz. This is the
// speed that a live Hermes-Lite 2 stream or a capture needs from the model to run in real time.
// ---------------------------------------------------------------------------------------------

fn bench_speed_msps(coeffs: &Coeffs, n: u64) -> f64 {
    let mut ch = RxChannel::default();
    let mut prng: u32 = 0xC0FFEE;
    let start = Instant::now();
    for _ in 0..n {
        let data = prng_sample(&mut prng);
        ch.step(false, data, true, 700_000, 3, true, coeffs); // rate_sel=3: most decimator work/sample
    }
    let elapsed = start.elapsed().as_secs_f64();
    std::hint::black_box(&ch);
    (n as f64 / elapsed) / 1.0e6
}

// ---------------------------------------------------------------------------------------------

fn repo_root() -> PathBuf {
    // fw/tr-rxmodel/src/bin/r2_check.rs -> CARGO_MANIFEST_DIR = fw/tr-rxmodel
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("locate repo root from CARGO_MANIFEST_DIR")
}

fn main() {
    let repo_root = repo_root();
    let coeffs = fir::load_coeffs_hex(&repo_root.join("rtl/rx/fir_coeffs.hex"))
        .expect("load rtl/rx/fir_coeffs.hex");

    let lines = build_stimulus();
    let stim_path = repo_root.join("sim/rx/out/r2_stimulus.txt");
    write_stimulus_file(&stim_path, &lines).expect("write stimulus file");
    println!(
        "R2 check: {} stimulus lines ({} reset + drain cycles either side)",
        lines.len(),
        RESET_CYCLES + DRAIN_CYCLES
    );

    let model_out = run_model(&lines, &coeffs);
    println!("model:  {} output words", model_out.len());

    let rtl_out = match run_iverilog(&repo_root) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("FAIL: {e}");
            std::process::exit(1);
        }
    };
    println!("RTL:    {} output words", rtl_out.len());

    if model_out.len() != rtl_out.len() {
        eprintln!(
            "FAIL: word count differs: model={} rtl={}",
            model_out.len(),
            rtl_out.len()
        );
        std::process::exit(1);
    }

    let mut mismatches = 0u32;
    for (n, (m, r)) in model_out.iter().zip(rtl_out.iter()).enumerate() {
        if m != r {
            if mismatches < 10 {
                eprintln!("mismatch at word {n}: model={m:?} rtl={r:?}");
            }
            mismatches += 1;
        }
    }
    if mismatches > 0 {
        eprintln!(
            "FAIL: {mismatches} of {} output words differ",
            model_out.len()
        );
        std::process::exit(1);
    }

    let mut per_rx = [0u32; 8];
    for (idx, _, _) in &model_out {
        per_rx[*idx] += 1;
    }
    for (i, count) in per_rx.iter().enumerate() {
        if *count == 0 {
            eprintln!("FAIL: receiver {i} produced no output words -- test coverage gap");
            std::process::exit(1);
        }
    }
    println!(
        "per-receiver word counts: {per_rx:?} (all 4 rates present: rx0/1=48k, rx2/3=96k, rx4/5=192k, rx6/7=384k)"
    );

    println!(
        "PASS: {} output words bit-exact between iverilog and the Rust model, same order",
        model_out.len()
    );

    let msps = bench_speed_msps(&coeffs, 20_000_000);
    println!("speed: {msps:.1} Msps (single receiver, this binary's own build)");
    if msps < 76.8 {
        eprintln!(
            "NOTE: {msps:.1} Msps is short of the 76.8 Msps real-time target for one receiver \
             (if this was not built with --release, that is almost all of the gap -- rerun with \
             it). docs/R2_RXMODEL.md section 4 has the measured breakdown and what would close \
             the remaining gap; this does not fail the check, which is the \
             bit-exact comparison above."
        );
    }
}
