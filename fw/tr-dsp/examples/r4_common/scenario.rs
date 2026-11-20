// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Test scenarios for the receiver back-end RTL (docs/R4_BACKEND.md section 6), shared by the
//! `r4_check` example (writes testbench fixtures) and the `r4_fixture` integration test (checks
//! the committed quick fixture is current).
//!
//! A scenario is 8 receivers, each with a register configuration, an integer stimulus
//! (`tr_dsp::backend::stim`, reproduced exactly by the testbench), a coefficient bank generated
//! from a few integers (also reproduced by the testbench), optionally a bank switch at a given
//! 24 ksps sample, and a number of bank samples. The model runs each receiver and produces the
//! expected output count, a hash of every output word and the final status registers; the
//! testbench compares the RTL with those, word for word through the hash.

use std::fmt::Write as _;
use std::vec::Vec;

use tr_dsp::backend::stim::{StimSpec, Tone, Xorshift};
use tr_dsp::backend::tables::SINE;
use tr_dsp::backend::{Alpha, CoefBank, Mode, NbConfig, Receiver, RxConfig};
use tr_regs::generated::rx_backend as rb;

/// A coefficient bank the testbench can generate: kind 0 = pseudo-random taps
/// `(xorshift as i32) >> shift`, kind 1 = boxcar band-pass `SINE[(n*step)..] << shift`.
#[derive(Clone, Copy, Debug)]
pub struct BankSpec {
    pub kind: u8,
    pub ntaps: u16,
    pub exp: u8,
    pub seed: u32,
    pub step: u32,
    pub shift: u8,
}

impl BankSpec {
    pub fn build(&self) -> CoefBank {
        let mut b = CoefBank::zero();
        b.ntaps = self.ntaps;
        b.exp = self.exp;
        let mut rng = Xorshift(self.seed | 1);
        for n in 0..self.ntaps as usize {
            if self.kind == 0 {
                b.re[n] = (rng.next() as i32) >> self.shift;
                b.im[n] = (rng.next() as i32) >> self.shift;
            } else {
                let idx = (n as u32).wrapping_mul(self.step) as usize & 1023;
                b.re[n] = SINE[(idx + 256) & 1023] << self.shift;
                b.im[n] = SINE[idx] << self.shift;
            }
        }
        b
    }
}

#[derive(Clone, Copy, Debug)]
pub struct RxSpec {
    pub cfg: RxConfig,
    pub stim: StimSpec,
    /// Bank index within the receiver's unit (0..5).
    pub bank: u8,
    /// Switch to `swap.1` from 24 ksps sample `swap.0` on.
    pub swap: Option<(u32, u8)>,
    /// Bank samples fed.
    pub n_in: u32,
    /// ADC samples (adc_valid pulses) between two bank samples in the testbench.
    pub d_eff: u32,
}

#[derive(Clone, Debug)]
pub struct Scenario {
    pub name: &'static str,
    pub banks: [BankSpec; 12],
    pub rx: [RxSpec; 8],
}

/// Model result for one receiver.
#[derive(Clone, Debug, Default)]
pub struct RxResult {
    pub count: u64,
    pub hash: u32,
    pub smeter: i64,
    pub gain: i64,
    pub sq_open: bool,
    pub blanked: u32,
    /// "s0 s1 stamp_off" per output, for diffing against a testbench dump.
    pub lines: Vec<String>,
}

pub fn fnv(h: u32, w: u32) -> u32 {
    (h ^ w).wrapping_mul(0x0100_0193)
}

pub fn run(s: &Scenario) -> Vec<RxResult> {
    let banks: Vec<CoefBank> = s.banks.iter().map(|b| b.build()).collect();
    let mut out = Vec::new();
    for (r, spec) in s.rx.iter().enumerate() {
        let unit = r / 4;
        let mut rx = Receiver::new(spec.cfg);
        let mut stim = tr_dsp::backend::stim::Stim::new(spec.stim);
        let mut res = RxResult { hash: 0x811C_9DC5, ..Default::default() };
        for _ in 0..spec.n_in {
            let (i, q) = stim.next();
            let bank = match spec.swap {
                Some((at, b)) if rx.n24 >= at as u64 => b,
                _ => spec.bank,
            };
            if let Some(o) = rx.push(i, q, &banks[unit * 6 + bank as usize]) {
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

// -------------------------------------------------------------------------------------------
// register words (field positions from the generated tr-regs, i.e. hw/regmap/rx_backend.toml)
// -------------------------------------------------------------------------------------------

fn f(v: u32, lsb: u32, width: u32) -> u32 {
    (v & ((1u64 << width) - 1) as u32) << lsb
}

pub struct Regs {
    pub ctrl: u32,
    pub nb: u32,
    pub hold: u32,
    pub att: u32,
    pub dec: u32,
    pub hang: u32,
    pub reference: u32,
    pub gmax: u32,
    pub gmin: u32,
    pub gman: u32,
    pub loops: u32,
    pub deemph: u32,
    pub squelch: u32,
}

pub fn regs(spec: &RxSpec) -> Regs {
    use rb::*;
    let c = &spec.cfg;
    let p = &c.post;
    let a = &p.agc;
    Regs {
        ctrl: f(p.mode as u32, ctrl::MODE_LSB, ctrl::MODE_WIDTH)
            | f(p.out24 as u32, ctrl::OUT24_LSB, 1)
            | f(c.in_rate as u32, ctrl::IN_RATE_LSB, ctrl::IN_RATE_WIDTH)
            | f(c.in_shift as u32, ctrl::IN_SHIFT_LSB, ctrl::IN_SHIFT_WIDTH)
            | f(c.nb.enable as u32, ctrl::NB_EN_LSB, 1)
            | f(a.enable as u32, ctrl::AGC_EN_LSB, 1)
            | f(p.sq_enable as u32, ctrl::SQ_EN_LSB, 1)
            | f(spec.bank as u32, ctrl::BANK_SEL_LSB, ctrl::BANK_SEL_WIDTH),
        nb: f(c.nb.thr as u32, nb::THR_LSB, nb::THR_WIDTH)
            | f(c.nb.k_down as u32, nb::K_DOWN_LSB, nb::K_DOWN_WIDTH)
            | f(c.nb.k_up as u32, nb::K_UP_LSB, nb::K_UP_WIDTH),
        hold: c.nb.hold as u32,
        att: f(a.attack.a, agc_attack::A_LSB, agc_attack::A_WIDTH) | f(a.attack.s as u32, agc_attack::S_LSB, agc_attack::S_WIDTH),
        dec: f(a.decay.a, agc_decay::A_LSB, agc_decay::A_WIDTH) | f(a.decay.s as u32, agc_decay::S_LSB, agc_decay::S_WIDTH),
        hang: a.hang as u32,
        reference: f(a.reference as u32, 0, 17),
        gmax: f(a.gmax as u32, 0, 20),
        gmin: f(a.gmin as u32, 0, 20),
        gman: f(a.manual as u32, 0, 20),
        loops: f(p.k_sm as u32, loops::K_SM_LSB, loops::K_SM_WIDTH)
            | f(p.k_dc as u32, loops::K_DC_LSB, loops::K_DC_WIDTH)
            | f(p.sam_kp as u32, loops::SAM_KP_LSB, loops::SAM_KP_WIDTH)
            | f(p.sam_ki as u32, loops::SAM_KI_LSB, loops::SAM_KI_WIDTH),
        deemph: p.deemph,
        squelch: f(p.sq_open as u32, squelch::OPEN_LSB, 16) | f(p.sq_close as u32, squelch::CLOSE_LSB, 16),
    }
}

/// The testbench include: a task that loads the scenario and the expected results into the
/// testbench's arrays.
pub fn emit_vh(s: &Scenario, res: &[RxResult], generator: &str) -> String {
    let mut o = String::new();
    let _ = writeln!(o, "// SPDX-License-Identifier: Apache-2.0");
    let _ = writeln!(o, "// Copyright 2026 Franz Schöning, https://www.schoning.com");
    let _ = writeln!(o, "//");
    let _ = writeln!(o, "// GENERATED by {generator} from the bit-exact model (fw/tr-dsp/src/backend) -- do not edit.");
    let _ = writeln!(o, "// Scenario \"{}\" for sim/rx_backend/tb_rx_backend.v (docs/R4_BACKEND.md section 6).", s.name);
    let _ = writeln!(o);
    let _ = writeln!(o, "task scn_load;");
    let _ = writeln!(o, "begin");
    for (k, b) in s.banks.iter().enumerate() {
        let _ = writeln!(
            o,
            "    bk_kind[{k}] = {}; bk_ntaps[{k}] = {}; bk_exp[{k}] = {}; bk_seed[{k}] = 32'h{:08x}; bk_step[{k}] = {}; bk_shift[{k}] = {};",
            b.kind, b.ntaps, b.exp, b.seed, b.step, b.shift
        );
    }
    for (r, (spec, e)) in s.rx.iter().zip(res).enumerate() {
        let g = regs(spec);
        let st = &spec.stim;
        let _ = writeln!(o, "    // receiver {r}: {:?}, {} ksps in, {} ksps out", spec.cfg.post.mode, 48 << spec.cfg.in_rate, if spec.cfg.post.out24 { 24 } else { 12 });
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
            "    st_amp0[{r}] = {}; st_inc0[{r}] = 32'h{:08x}; st_amp1[{r}] = {}; st_inc1[{r}] = 32'h{:08x}; st_nsh[{r}] = {}; st_seed[{r}] = 32'h{:08x}; st_imp_per[{r}] = {}; st_imp_amp[{r}] = {};",
            st.tones[0].amp, st.tones[0].inc, st.tones[1].amp, st.tones[1].inc, st.noise_shift, st.seed, st.imp_period, st.imp_amp
        );
        let (swap_at, swap_bank) = spec.swap.map(|(a, b)| (a as i64, b)).unwrap_or((-1, 0));
        let _ = writeln!(o, "    n_in[{r}] = {}; d_eff[{r}] = {}; swap_at[{r}] = {}; swap_bank[{r}] = {};", spec.n_in, spec.d_eff, swap_at, swap_bank);
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

// -------------------------------------------------------------------------------------------
// scenarios
// -------------------------------------------------------------------------------------------

fn inc(f_hz: f64, fs: f64) -> u32 {
    tr_dsp::backend::stim::inc_for(f_hz, fs)
}

fn fs(rate: u8) -> f64 {
    (48_000u32 << rate) as f64
}

fn tone(amp: i32, f_hz: f64, rate: u8) -> Tone {
    Tone { amp, inc: inc(f_hz, fs(rate)) }
}

fn base_cfg(rate: u8, mode: Mode) -> RxConfig {
    let mut c = RxConfig { in_rate: rate, in_shift: 6, ..RxConfig::default() };
    c.post.mode = mode;
    c.nb = NbConfig { enable: false, thr: 96, hold: 20, k_down: 6, k_up: 10 };
    c
}

/// Bank samples needed for `outs` outputs at 12 (or 24) ksps.
fn n_for(rate: u8, out24: bool, outs: u32) -> u32 {
    let per = if out24 { 2u32 } else { 4 } << rate;
    outs * per + per / 2
}

/// Quick scenario for tools/check.sh: every mode, every input rate, both output rates, blanker,
/// AGC on/off, squelch, SAM and de-emphasis, a bank switch, saturation; short filters and 4x
/// compressed time so it runs in well under a minute of iverilog.
pub fn quick() -> Scenario {
    let rnd = |seed: u32, ntaps: u16, shift: u8, exp: u8| BankSpec { kind: 0, ntaps, exp, seed, step: 0, shift };
    let boxcar = |step: u32, ntaps: u16, exp: u8| BankSpec { kind: 1, ntaps, exp, seed: 0, step, shift: 13 };
    let banks = [
        rnd(0x1234_5678, 96, 6, 2),
        boxcar(3, 128, 7),
        boxcar(1017, 64, 6),
        rnd(0x0BAD_F00D, 40, 4, 0),
        boxcar(5, 200, 8),
        rnd(0x5EED_0001, 1, 1, 0),
        rnd(0xCAFE_0002, 160, 7, 3),
        boxcar(7, 48, 6),
        rnd(0x7777_1111, 256, 8, 4),
        boxcar(1021, 96, 7),
        rnd(0x1357_9BDF, 24, 3, 0),
        boxcar(2, 32, 5),
    ];
    let mk = |cfg: RxConfig, stim: StimSpec, bank: u8, outs: u32| RxSpec {
        cfg,
        stim,
        bank,
        swap: None,
        n_in: n_for(cfg.in_rate, cfg.post.out24, outs),
        d_eff: (1600u32 >> cfg.in_rate) / 4,
    };
    let noise = |seed: u32, sh: u8| StimSpec { noise_shift: sh, seed, ..StimSpec::default() };

    // 0: SSB at 384 ksps, blanker on with impulses, AGC
    let mut c0 = base_cfg(3, Mode::Ssb);
    c0.nb.enable = true;
    let s0 = StimSpec { tones: [tone(12_000, 1_000.0, 3), tone(3_000, -2_500.0, 3)], noise_shift: 20, seed: 11, imp_period: 700, imp_amp: 30_000 };
    let r0 = mk(c0, s0, 0, 160);
    // 1: AM at 192 ksps, squelch on
    let mut c1 = base_cfg(2, Mode::Am);
    c1.post.sq_enable = true;
    c1.post.sq_open = -60 * 64;
    c1.post.sq_close = -62 * 64;
    let s1 = StimSpec { tones: [tone(9_000, 0.0, 2), tone(4_000, 600.0, 2)], noise_shift: 19, seed: 21, ..StimSpec::default() };
    let r1 = mk(c1, s1, 1, 140);
    // 2: SAM at 96 ksps, carrier 40 Hz off, faster loop
    let mut c2 = base_cfg(1, Mode::Sam);
    c2.post.sam_kp = 5;
    c2.post.sam_ki = 11;
    c2.post.k_dc = 7;
    let s2 = StimSpec { tones: [tone(15_000, 40.0, 1), tone(5_000, 900.0, 1)], noise_shift: 21, seed: 31, ..StimSpec::default() };
    let r2 = mk(c2, s2, 2, 140);
    // 3: FM at 48 ksps with de-emphasis, noise, 24 ksps out
    let mut c3 = base_cfg(0, Mode::Fm);
    c3.post.deemph = 74_108;
    c3.post.out24 = true;
    let s3 = StimSpec { tones: [tone(20_000, 1_500.0, 0), Tone::default()], noise_shift: 17, seed: 41, ..StimSpec::default() };
    let r3 = mk(c3, s3, 3, 200);
    // 4: IQ at 384 ksps, 24 ksps out, AGC off (manual gain +1.5 octaves)
    let mut c4 = base_cfg(3, Mode::Iq);
    c4.post.out24 = true;
    c4.post.agc.enable = false;
    c4.post.agc.manual = 6_144;
    let s4 = StimSpec { tones: [tone(8_000, -3_000.0, 3), tone(8_000, 70_000.0, 3)], noise_shift: 20, seed: 51, ..StimSpec::default() };
    let r4 = mk(c4, s4, 4, 160);
    // 5: SSB at 192 ksps, 24 ksps out, blanker on, bank switch at 24 ksps sample 60
    let mut c5 = base_cfg(2, Mode::Ssb);
    c5.nb.enable = true;
    c5.post.out24 = true;
    c5.post.agc.attack = Alpha::from_time_constant(0.5, 24_000.0);
    c5.post.agc.decay = Alpha::from_time_constant(20.0, 24_000.0);
    c5.post.agc.hang = 100;
    let s5 = StimSpec { tones: [tone(6_000, 1_200.0, 2), Tone::default()], noise_shift: 18, seed: 61, imp_period: 555, imp_amp: -20_000 };
    let mut r5 = mk(c5, s5, 1, 160);
    r5.swap = Some((60, 2));
    // 6: FM at 96 ksps, no de-emphasis, strong signal, AGC setting ignored in FM
    let c6 = base_cfg(1, Mode::Fm);
    let s6 = StimSpec { tones: [tone(30_000, 3_000.0, 1), tone(2_000, -4_000.0, 1)], noise_shift: 22, seed: 71, ..StimSpec::default() };
    let r6 = mk(c6, s6, 3, 140);
    // 7: IQ at 48 ksps, 12 ksps out, AGC on, in_shift 7 with saturating input
    let mut c7 = base_cfg(0, Mode::Iq);
    c7.in_shift = 7;
    let s7 = noise(81, 8);
    let r7 = mk(c7, s7, 0, 140);

    Scenario { name: "quick", banks, rx: [r0, r1, r2, r3, r4, r5, r6, r7] }
}

/// Full scenarios (tools/run_r4_full.sh): 1,024-tap and other realistic filters, real-time bank
/// pacing, longer runs; together every mode at every input rate, and one run with all 8
/// receivers at 384 ksps with 1,024 taps (the throughput worst case).
pub fn full() -> Vec<Scenario> {
    let rnd = |seed: u32, ntaps: u16, shift: u8, exp: u8| BankSpec { kind: 0, ntaps, exp, seed, step: 0, shift };
    let boxcar = |step: u32, ntaps: u16, exp: u8| BankSpec { kind: 1, ntaps, exp, seed: 0, step, shift: 13 };
    let modes = [Mode::Ssb, Mode::Am, Mode::Sam, Mode::Fm, Mode::Iq];
    let mut scns = Vec::new();
    // Runs 1-3: 20 mode x rate combinations spread over 3 runs of 8 receivers (4 left over
    // receivers repeat SSB and IQ at other settings).
    let mut combos: Vec<(Mode, u8)> = Vec::new();
    for m in modes {
        for rate in 0..4u8 {
            combos.push((m, rate));
        }
    }
    combos.push((Mode::Ssb, 3));
    combos.push((Mode::Iq, 0));
    combos.push((Mode::Am, 3));
    combos.push((Mode::Fm, 2));
    for run in 0..3usize {
        let banks = [
            boxcar(3, 1024, 10),
            rnd(0x1111_0000 + run as u32, 1024, 9, 3),
            boxcar(1019, 511, 9),
            rnd(0x2222_0000 + run as u32, 777, 8, 3),
            boxcar(9, 255, 8),
            rnd(0x3333_0000 + run as u32, 1, 1, 0),
            rnd(0x4444_0000 + run as u32, 1024, 9, 3),
            boxcar(6, 1024, 10),
            rnd(0x5555_0000 + run as u32, 300, 7, 2),
            boxcar(1015, 700, 9),
            boxcar(4, 1024, 10),
            rnd(0x6666_0000 + run as u32, 64, 5, 1),
        ];
        let mut rx: Vec<RxSpec> = Vec::new();
        for k in 0..8 {
            let (mode, rate) = combos[run * 8 + k];
            let mut c = base_cfg(rate, mode);
            c.post.out24 = (run + k) % 3 == 0;
            c.nb.enable = k % 2 == 0;
            c.post.agc.enable = !(k == 5 && run == 1);
            c.post.sq_enable = k == 3;
            c.post.sq_open = -70 * 64;
            c.post.sq_close = -72 * 64;
            if mode == Mode::Fm && k % 2 == 1 {
                c.post.deemph = 55_869;
            }
            if mode == Mode::Sam {
                c.post.sam_kp = 6;
                c.post.sam_ki = 13;
            }
            let seed = 1000 * run as u32 + 17 * k as u32 + 3;
            let stim = StimSpec {
                tones: [tone(10_000 + 1_000 * k as i32, 300.0 + 250.0 * k as f64, rate), tone(3_000, -1_700.0 + 100.0 * run as f64, rate)],
                noise_shift: 18 + (k % 3) as u8,
                seed,
                imp_period: if k % 2 == 0 { 1_000 + 97 * k as u32 } else { 0 },
                imp_amp: 25_000,
            };
            let outs = 300;
            rx.push(RxSpec {
                cfg: c,
                stim,
                bank: (k % 6) as u8,
                swap: if k == 1 { Some((200, 4)) } else { None },
                n_in: n_for(rate, c.post.out24, outs),
                d_eff: 1600u32 >> rate,
            });
        }
        scns.push(Scenario { name: ["full-1", "full-2", "full-3"][run], banks, rx: rx.try_into().unwrap() });
    }
    // Run 4: all 8 receivers at 384 ksps with 1,024-tap filters, real time: the throughput case.
    let banks = [
        boxcar(3, 1024, 10),
        rnd(0x7777_0000, 1024, 9, 3),
        boxcar(11, 1024, 10),
        rnd(0x7777_0001, 1024, 9, 3),
        boxcar(13, 1024, 10),
        rnd(0x7777_0002, 1024, 9, 3),
        boxcar(3, 1024, 10),
        rnd(0x7777_0003, 1024, 9, 3),
        boxcar(17, 1024, 10),
        rnd(0x7777_0004, 1024, 9, 3),
        boxcar(19, 1024, 10),
        rnd(0x7777_0005, 1024, 9, 3),
    ];
    let mut rx: Vec<RxSpec> = Vec::new();
    for k in 0..8 {
        let mode = [Mode::Iq, Mode::Ssb, Mode::Sam, Mode::Fm, Mode::Am, Mode::Iq, Mode::Ssb, Mode::Fm][k];
        let mut c = base_cfg(3, mode);
        c.nb.enable = true;
        c.post.out24 = k >= 5;
        let stim = StimSpec {
            tones: [tone(12_000, 200.0 * k as f64 - 700.0, 3), tone(2_000, 55_000.0, 3)],
            noise_shift: 19,
            seed: 9000 + k as u32,
            imp_period: 3_001,
            imp_amp: -28_000,
        };
        rx.push(RxSpec { cfg: c, stim, bank: (k % 4) as u8, swap: None, n_in: n_for(3, c.post.out24, 300), d_eff: 200 });
    }
    scns.push(Scenario { name: "full-4 (8 x 384 ksps, 1,024 taps)", banks, rx: rx.try_into().unwrap() });
    scns
}
