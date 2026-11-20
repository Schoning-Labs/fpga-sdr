// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! End-to-end scenario: a 12-bit ADC stream through the receiver bank (bit-exact model
//! `tr-rxmodel`) into the back end (`tr_dsp::backend`), against `rtl/rx/rx_bank.v` feeding
//! `rtl/rx_backend/rx_backend.v` in `sim/rx_backend/r4_chain.v`. It checks the interface between
//! the two blocks with the real bank's timing and bursty `adc_valid`: 8 receivers, two per bank
//! rate. The ADC stream is integer-only (tones from a phase accumulator and the sine table, xorshift
//! noise, a new sample only on valid clocks) so the testbench generates the identical stream.

use std::fmt::Write as _;
use std::vec::Vec;

use tr_dsp::backend::stim::Xorshift;
use tr_dsp::backend::tables::SINE;
use tr_dsp::backend::{Mode, Receiver, RxConfig};
use tr_rxmodel::RxBank;

use super::scenario::{fnv, regs, BankSpec, RxResult, RxSpec};

pub const RESET_CYCLES: usize = 5;
/// Default clocks of ADC stream.
pub const QUICK_CYCLES: usize = 140_000;
/// Clocks with adc_valid low after the stream (the testbench's drain, so every receiver's
/// already-accepted samples finish draining through the bank and the back end). Before the
/// receiver-bank fix (docs/R4_BACKEND.md section 9) the bank kept emitting spurious samples for
/// the whole drain, since its decimation counted clocks instead of adc_valid pulses; fixed, the
/// bank emits nothing at all once adc_valid stops (see r4_chain.v's `drain_samples` check).
pub const DRAIN_CYCLES: usize = 40_000;

/// ADC tones: (amplitude, phase increment per ADC sample).
pub const TONES: [(i32, u32); 4] = [(500, 0x0626_4000), (400, 0x0EB8_5000), (450, 0x1788_8800), (350, 0x2F1A_9000)];
pub const NOISE_SHIFT: u32 = 23;

pub struct Chain {
    pub banks: [BankSpec; 12],
    pub rx: [RxSpec; 8],
    pub phase_inc: [u32; 8],
    pub cycles: usize,
}

pub fn chain(cycles: usize) -> Chain {
    let rnd = |seed: u32, ntaps: u16, shift: u8, exp: u8| BankSpec { kind: 0, ntaps, exp, seed, step: 0, shift };
    let boxcar = |step: u32, ntaps: u16, exp: u8| BankSpec { kind: 1, ntaps, exp, seed: 0, step, shift: 13 };
    let banks = [
        boxcar(0, 64, 6),
        boxcar(3, 128, 7),
        rnd(0xA1A1_0001, 48, 4, 1),
        boxcar(1020, 96, 7),
        boxcar(0, 1, 0),
        rnd(0xB2B2_0002, 200, 6, 3),
        boxcar(2, 128, 7),
        rnd(0xC3C3_0003, 64, 5, 1),
        boxcar(0, 32, 5),
        boxcar(1021, 256, 8),
        boxcar(0, 1, 0),
        rnd(0xD4D4_0004, 100, 5, 2),
    ];
    let modes = [Mode::Ssb, Mode::Am, Mode::Iq, Mode::Fm, Mode::Sam, Mode::Ssb, Mode::Iq, Mode::Am];
    // tuned near the ADC tones: receiver k hears tone (k % 4) about 700 Hz off
    let tune_hz = [4_600_000.0, 11_060_000.0, 17_650_000.0, 35_300_000.0, 4_601_500.0, 11_059_000.0, 17_652_000.0, 35_299_500.0];
    let mut rx: Vec<RxSpec> = Vec::new();
    let mut phase_inc = [0u32; 8];
    for k in 0..8 {
        let rate = (k / 2) as u8; // 48, 48, 96, 96, 192, 192, 384, 384 ksps
        let mut c = RxConfig { in_rate: rate, in_shift: 6, ..RxConfig::default() };
        c.post.mode = modes[k];
        c.post.out24 = k % 3 == 1;
        c.nb.enable = k % 2 == 0;
        c.post.agc.attack = tr_dsp::backend::Alpha::from_time_constant(0.5, 24_000.0);
        c.post.agc.decay = tr_dsp::backend::Alpha::from_time_constant(10.0, 24_000.0);
        c.post.agc.hang = 48;
        rx.push(RxSpec { cfg: c, stim: Default::default(), bank: (k % 4 + k / 4) as u8, swap: None, n_in: 0, d_eff: 0 });
        phase_inc[k] = (libm::round(tune_hz[k] / 76.8e6 * 4_294_967_296.0) as i64) as u32;
    }
    Chain { banks, rx: rx.try_into().unwrap(), phase_inc, cycles }
}

/// The ADC stream and `adc_valid` pattern, one call per clock after the setup phase.
pub struct Adc {
    vrng: u32,
    vleft: u32,
    valid: bool,
    rng: Xorshift,
    ph: [u32; 4],
}

impl Adc {
    pub fn new() -> Self {
        Adc { vrng: 0x2545_F491, vleft: 0, valid: false, rng: Xorshift(0x1234_5679), ph: [0; 4] }
    }
    /// (adc_valid, adc_data) of this clock.
    pub fn next(&mut self) -> (bool, i32) {
        if self.vleft == 0 {
            let mut x = self.vrng;
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            self.vrng = x;
            self.valid = !self.valid;
            self.vleft = if self.valid { 1 + x % 48 } else { 1 + x % 46 };
        }
        self.vleft -= 1;
        if !self.valid {
            return (false, 0);
        }
        let mut v: i64 = 0;
        for (t, &(a, inc)) in TONES.iter().enumerate() {
            v += (a as i64 * SINE[(self.ph[t] >> 22) as usize] as i64) >> 17;
            self.ph[t] = self.ph[t].wrapping_add(inc);
        }
        v += (self.rng.next() as i32 as i64) >> NOISE_SHIFT;
        (true, v.clamp(-2048, 2047) as i32)
    }
}

pub fn run(ch: &Chain, coeffs: &tr_rxmodel::fir::Coeffs) -> Vec<RxResult> {
    let mut bank = RxBank::default();
    for _ in 0..RESET_CYCLES {
        bank.step(true, 0, false, false, 0, 0, coeffs);
    }
    // register writes, one per clock: phase_inc then control {enable, rate_sel} per channel
    for k in 0..8u32 {
        bank.step(false, 0, false, true, k << 1, ch.phase_inc[k as usize], coeffs);
        bank.step(false, 0, false, true, (k << 1) | 1, 4 | ch.rx[k as usize].cfg.in_rate as u32, coeffs);
    }
    let mut samples: Vec<Vec<(i64, i64)>> = vec![Vec::new(); 8];
    let mut adc = Adc::new();
    let verbose = std::env::var("R4_CHAIN_VERBOSE").is_ok();
    let mut shown = 0;
    for cyc in 0..ch.cycles + DRAIN_CYCLES {
        let (v, idx, i, q) = bank.out();
        if v {
            samples[idx].push((i as i64, q as i64));
            if verbose && shown < 1_000_000 {
                eprintln!("B {cyc} {idx} {i} {q}");
                shown += 1;
            }
        }
        let (valid, data) = if cyc < ch.cycles { adc.next() } else { (false, 0) };
        bank.step(false, data, valid, false, 0, 0, coeffs);
    }
    if std::env::var("R4_CHAIN_VERBOSE").is_ok() {
        let nv = { let mut a = Adc::new(); (0..ch.cycles).filter(|_| a.next().0).count() };
        eprintln!("adc samples {nv}, bank samples per receiver {:?}", samples.iter().map(|s| s.len()).collect::<Vec<_>>());
    }
    let banks: Vec<_> = ch.banks.iter().map(|b| b.build()).collect();
    let mut out = Vec::new();
    for (k, spec) in ch.rx.iter().enumerate() {
        let mut rx = Receiver::new(spec.cfg);
        let mut res = RxResult { hash: 0x811C_9DC5, ..Default::default() };
        for &(i, q) in &samples[k] {
            if let Some(o) = rx.push(i, q, &banks[(k / 4) * 6 + spec.bank as usize]) {
                let w0 = ((o.out.s1 as u16 as u32) << 16) | o.out.s0 as u16 as u32;
                res.hash = fnv(fnv(res.hash, w0), o.stamp_off as u32);
                res.count += 1;
                res.lines.push(format!("{} {} {}", o.out.s0, o.out.s1, o.stamp_off));
            }
        }
        res.smeter = rx.smeter_db64();
        res.gain = rx.agc_gain();
        res.sq_open = rx.squelch_open();
        res.blanked = rx.blanked();
        out.push(res);
    }
    out
}

pub fn emit_vh(ch: &Chain, res: &[RxResult], generator: &str) -> String {
    let mut o = String::new();
    let _ = writeln!(o, "// SPDX-License-Identifier: Apache-2.0");
    let _ = writeln!(o, "// Copyright 2026 Franz Schöning, https://www.schoning.com");
    let _ = writeln!(o, "//");
    let _ = writeln!(o, "// GENERATED by {generator} from the bit-exact models (tr-rxmodel + tr-dsp::backend) -- do not edit.");
    let _ = writeln!(o, "// Receiver bank -> back end chain for sim/rx_backend/r4_chain.v (docs/R4_BACKEND.md section 6).");
    let _ = writeln!(o);
    let _ = writeln!(o, "localparam integer CHAIN_CYCLES = {};", ch.cycles);
    let _ = writeln!(o, "localparam integer CHAIN_DRAIN = {DRAIN_CYCLES};");
    let _ = writeln!(o, "task scn_load;");
    let _ = writeln!(o, "begin");
    for (k, b) in ch.banks.iter().enumerate() {
        let _ = writeln!(
            o,
            "    bk_kind[{k}] = {}; bk_ntaps[{k}] = {}; bk_exp[{k}] = {}; bk_seed[{k}] = 32'h{:08x}; bk_step[{k}] = {}; bk_shift[{k}] = {};",
            b.kind, b.ntaps, b.exp, b.seed, b.step, b.shift
        );
    }
    for (t, &(a, inc)) in TONES.iter().enumerate() {
        let _ = writeln!(o, "    tone_amp[{t}] = {a}; tone_inc[{t}] = 32'h{inc:08x};");
    }
    let _ = writeln!(o, "    noise_shift = {NOISE_SHIFT};");
    for (r, (spec, e)) in ch.rx.iter().zip(res).enumerate() {
        let g = regs(spec);
        let _ = writeln!(o, "    // receiver {r}: {:?}, {} ksps in, {} ksps out", spec.cfg.post.mode, 48 << spec.cfg.in_rate, if spec.cfg.post.out24 { 24 } else { 12 });
        let _ = writeln!(o, "    bank_inc[{r}] = 32'h{:08x}; bank_rate[{r}] = {};", ch.phase_inc[r], spec.cfg.in_rate);
        let _ = writeln!(
            o,
            "    cfg_ctrl[{r}] = 32'h{:08x}; cfg_nb[{r}] = 32'h{:08x}; cfg_hold[{r}] = 32'h{:08x}; cfg_att[{r}] = 32'h{:08x}; cfg_dec[{r}] = 32'h{:08x};",
            g.ctrl, g.nb, g.hold, g.att, g.dec
        );
        let _ = writeln!(
            o,
            "    cfg_hang[{r}] = 32'h{:08x}; cfg_ref[{r}] = 32'h{:08x}; cfg_gmax[{r}] = 32'h{:08x}; cfg_gmin[{r}] = 32'h{:08x}; cfg_gman[{r}] = 32'h{:08x};",
            g.hang, g.reference, g.gmax, g.gmin, g.gman
        );
        let _ = writeln!(o, "    cfg_loops[{r}] = 32'h{:08x}; cfg_deemph[{r}] = 32'h{:08x}; cfg_sq[{r}] = 32'h{:08x};", g.loops, g.deemph, g.squelch);
        let _ = writeln!(
            o,
            "    exp_count[{r}] = {}; exp_hash[{r}] = 32'h{:08x}; exp_smeter[{r}] = {}; exp_gain[{r}] = {}; exp_sq[{r}] = {}; exp_blanked[{r}] = {};",
            e.count, e.hash, e.smeter, e.gain, e.sq_open as u8, e.blanked
        );
    }
    let _ = writeln!(o, "end");
    let _ = writeln!(o, "endtask");
    o
}
