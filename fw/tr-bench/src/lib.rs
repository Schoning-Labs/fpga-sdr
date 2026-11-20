// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Kernel definitions and instruction-count measurement for the `tr-dsp` kernels that run on the CPU: the
//! channel filter, AGC, each demodulator, the noise blanker, noise reduction, and the resampler at each input
//! rate. Nothing here depends on the board: it needs only `tr-dsp` and the `riscv` crate's `minstret`
//! accessor (a RISC-V privileged spec register, not specific to the AE350 or QEMU), so it builds and, in
//! principle, runs unchanged wherever a 64-bit `minstret` read is available, which means under QEMU today and
//! on the hardware counter of the real AE350 core later. Results are written through a caller-supplied
//! [`core::fmt::Write`], and the QEMU entry point (`src/bin/dsp_bench.rs`) supplies the UART console.
//!
//! The measurement method and its limits are described in docs/S2_BENCH.md. In short, this crate reads
//! `minstret` (instructions retired) and not `mcycle`, because under QEMU's TCG `mcycle` only follows the
//! executed instructions when `-icount` is active, and even then it is a synthetic cost per instruction and
//! not a model of the pipeline. The retired-instruction count is the only number here that can claim to match
//! what the real AE350 core executes (the same RV32IMAFC instruction stream), which is why every result is an
//! instruction count and not a cycle count; turning it into a cycle estimate needs an assumed instructions per
//! cycle (docs/S2_BENCH.md and docs/ARCHITECTURE.md section 5.5).

#![no_std]

use core::fmt::Write;

#[cfg(feature = "bench-ft8")]
mod ft8_bench;

use tr_dsp::agc::Agc;
use tr_dsp::am::{AmEnvelopeDemod, AmSyncDemod};
use tr_dsp::blanker::NoiseBlanker;
use tr_dsp::complex::C32;
use tr_dsp::cw::CwDemod;
use tr_dsp::fastconv::{BandpassFilter, BLOCK, MAX_TAPS};
use tr_dsp::fft::{Fft1024, RealFft};
use tr_dsp::fm::{FmDemod, Squelch};
use tr_dsp::nr::{NoiseReducer, NoiseReducer12k};
use tr_dsp::resample::Decimator;
use tr_dsp::ssb::{Sideband, SsbDemod};

/// Repeated calls per kernel, averaged. QEMU's TCG has no cache or branch-predictor state to warm up (every
/// run is functionally identical to the first), so the repetitions only smooth out the few AGC, blanker and
/// resampler calls whose instruction count depends a little on which branch the synthetic input takes on a
/// given call (attack or decay, holding or not, an output this call or not).
const REPS: u32 = 8;

/// Input samples fed per resampler measurement. The count does not depend on the decimation ratio `m`, so the
/// instructions per input sample of every ratio come from runs of the same size; docs/S3_DSP.md section 3.10
/// explains why the cost of the resampler is best given per input sample and not per output block.
const RESAMPLE_INPUT_SAMPLES: u32 = 4096;

/// Reads the 64-bit instructions-retired count, the `minstret` and `minstreth` pair of registers (the `riscv`
/// crate handles the rollover between the two 32-bit halves on RV32). The module documentation says what this
/// does and does not tell you under QEMU.
#[inline]
fn instret() -> u64 {
    riscv::register::minstret::read64()
}

/// The number a [`KernelResult`]'s `instr_total` is divided by to get an instruction count per unit, which
/// multiplied by a rate gives instructions per second of audio.
#[derive(Clone, Copy)]
pub enum Unit {
    /// `divisor` new-sample blocks of size `BLOCK` (512) were processed at `sample_rate_hz`;
    /// blocks/s = `sample_rate_hz / BLOCK`.
    Blocks,
    /// `divisor` individual input samples were fed in at `sample_rate_hz` (used for the resampler, where not
    /// every input sample produces an output and a count per output block would make little sense).
    Samples,
}

/// The measurement of one kernel, as printed on a `RESULT` line by `print_result`.
pub struct KernelResult {
    /// Kernel name as it appears on the `RESULT` line, for example `filter_48k`.
    pub name: &'static str,
    /// Sample rate the kernel was run at, in Hz; 0 for a stub.
    pub sample_rate_hz: f32,
    /// What `divisor` counts.
    pub unit: Unit,
    /// Total blocks or samples processed across all [`REPS`] repetitions.
    pub divisor: u32,
    /// Total instructions retired across all repetitions. Construction and setup of the kernel are measured
    /// outside the `instret()` window in every kernel function below and are not included.
    pub instr_total: u64,
    /// `false` for a stub line (the feature of that measurement is off): no kernel ran, `instr_total` and
    /// `divisor` are both 0, and the line carries an explanation in `note` instead of a number.
    pub measured: bool,
    /// Free text for the `RESULT` line; empty is printed as `-`.
    pub note: &'static str,
}

/// A deterministic pseudo-random source (xorshift32) for the synthetic test signals. It is not cryptographic
/// and not even a good generator, but it is cheap and reproducible, which is all this harness needs from it for
/// the noise floor and the variation of the AGC input, and it saves a `rand` dependency.
struct Xorshift32(u32);

impl Xorshift32 {
    /// Starts the generator at `seed`; the lowest bit is forced on because an all-zero state would stay zero.
    fn new(seed: u32) -> Self {
        Xorshift32(seed | 1)
    }

    /// Next value in `-1.0..=1.0`.
    fn next_bipolar(&mut self) -> f32 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 17;
        self.0 ^= self.0 << 5;
        (self.0 as f32 / u32::MAX as f32) * 2.0 - 1.0
    }
}

/// A `BLOCK`-sample complex baseband block: a tone plus a little broadband noise, which is closer to what the
/// filter and demodulator kernels below have to process than a pure tone would be (a noiseless tone would
/// keep the branches in the AGC and the blanker from ever taking their less common path).
fn synth_iq_block(seed: u32, tone_hz: f32, sample_rate_hz: f32) -> [C32; BLOCK] {
    let mut rng = Xorshift32::new(seed);
    let mut out = [C32::ZERO; BLOCK];
    for (n, s) in out.iter_mut().enumerate() {
        let t = n as f32 / sample_rate_hz;
        let tone = C32::from_turns(tone_hz * t).scale(0.7);
        let noise = C32::new(rng.next_bipolar(), rng.next_bipolar()).scale(0.05);
        *s = tone + noise;
    }
    out
}

/// A `BLOCK`-sample real audio block (for [`NoiseReducer`], which runs after demodulation).
fn synth_audio_block(seed: u32, tone_hz: f32, sample_rate_hz: f32) -> [f32; BLOCK] {
    let mut rng = Xorshift32::new(seed);
    let mut out = [0.0f32; BLOCK];
    for (n, s) in out.iter_mut().enumerate() {
        let t = n as f32 / sample_rate_hz;
        *s = 0.6 * libm::sinf(core::f32::consts::TAU * tone_hz * t) + 0.05 * rng.next_bipolar();
    }
    out
}

/// Times `REPS` calls of an IQ-in, IQ-out kernel on one block, after one call that is not counted so that any
/// one-time setup inside the kernel stays out of the measurement.
fn measure_blocks<F: FnMut(&[C32; BLOCK], &mut [C32; BLOCK])>(
    name: &'static str,
    sample_rate_hz: f32,
    input: &[C32; BLOCK],
    mut call: F,
) -> KernelResult {
    let mut output = [C32::ZERO; BLOCK];
    call(input, &mut output); // one call that is not counted, so that any one-time initialization stays out
    let start = instret();
    for _ in 0..REPS {
        call(input, &mut output);
    }
    let instr_total = instret() - start;
    KernelResult {
        name,
        sample_rate_hz,
        unit: Unit::Blocks,
        divisor: REPS,
        instr_total,
        measured: true,
        note: "",
    }
}

/// Like [`measure_blocks`], for a kernel that takes real audio in and gives real audio out.
fn measure_audio_blocks<F: FnMut(&[f32; BLOCK], &mut [f32; BLOCK])>(
    name: &'static str,
    sample_rate_hz: f32,
    input: &[f32; BLOCK],
    mut call: F,
) -> KernelResult {
    let mut output = [0.0f32; BLOCK];
    call(input, &mut output);
    let start = instret();
    for _ in 0..REPS {
        call(input, &mut output);
    }
    let instr_total = instret() - start;
    KernelResult {
        name,
        sample_rate_hz,
        unit: Unit::Blocks,
        divisor: REPS,
        instr_total,
        measured: true,
        note: "",
    }
}

/// The channel bandpass filter (fast convolution with `MAX_TAPS` taps, 300 to 2700 Hz) at 48 ksps.
fn bench_filter(fft: &Fft1024) -> KernelResult {
    let input = synth_iq_block(1, 1500.0, 48_000.0);
    let mut filter = BandpassFilter::design(fft, 48_000.0, 300.0, 2700.0, 0.0, MAX_TAPS);
    measure_blocks("filter_48k", 48_000.0, &input, |i, o| filter.process_block(fft, i, o))
}

/// The AGC at 48 ksps, fed with magnitudes only (`process_mag`).
fn bench_agc() -> KernelResult {
    let sample_rate_hz = 48_000.0;
    let mut agc = Agc::new(sample_rate_hz, 5.0, 300.0, 100.0, 0.3, 0.01, 100.0);
    let mut rng = Xorshift32::new(2);
    // Magnitudes that sweep up and down, so that both AGC branches run (loud samples drive the attack, quiet
    // ones the decay) and not just one with a flat input.
    let mut mags = [0.0f32; BLOCK];
    for (n, m) in mags.iter_mut().enumerate() {
        let sweep = 0.5 + 0.45 * libm::sinf(n as f32 * 0.05);
        *m = (sweep + 0.05 * rng.next_bipolar()).max(0.001);
    }
    let mut sink = 0.0f32;
    let mut call = || {
        for m in mags.iter() {
            sink += agc.process_mag(*m);
        }
    };
    call();
    let start = instret();
    for _ in 0..REPS {
        call();
    }
    let instr_total = instret() - start;
    core::hint::black_box(sink);
    KernelResult {
        name: "agc_48k",
        sample_rate_hz,
        unit: Unit::Blocks,
        divisor: REPS,
        instr_total,
        measured: true,
        note: "",
    }
}

/// The upper-sideband demodulator (filter plus AGC) at 48 ksps.
fn bench_ssb(fft: &Fft1024) -> KernelResult {
    let input = synth_iq_block(3, 1500.0, 48_000.0);
    let agc = Agc::new(48_000.0, 5.0, 300.0, 100.0, 0.3, 0.01, 100.0);
    let mut demod = SsbDemod::new(fft, 48_000.0, Sideband::Upper, 300.0, 2700.0, agc);
    measure_audio_via_iq("demod_ssb_usb_48k", fft, &input, move |fft, i, o| {
        demod.process_block(fft, i, o)
    })
}

/// The CW demodulator (700 Hz pitch, filter plus AGC) at 48 ksps.
fn bench_cw(fft: &Fft1024) -> KernelResult {
    let input = synth_iq_block(4, 700.0, 48_000.0);
    let agc = Agc::new(48_000.0, 5.0, 300.0, 100.0, 0.3, 0.01, 100.0);
    let mut demod = CwDemod::new(fft, 48_000.0, 700.0, 300.0, agc);
    measure_audio_via_iq("demod_cw_48k", fft, &input, move |fft, i, o| {
        demod.process_block(fft, i, o)
    })
}

/// The AM envelope demodulator at 48 ksps.
fn bench_am_env(fft: &Fft1024) -> KernelResult {
    let input = synth_iq_block(5, 1000.0, 48_000.0);
    let agc = Agc::new(48_000.0, 5.0, 300.0, 100.0, 0.3, 0.01, 100.0);
    let mut demod = AmEnvelopeDemod::new(fft, 48_000.0, 2500.0, agc);
    measure_audio_via_iq("demod_am_env_48k", fft, &input, move |fft, i, o| {
        demod.process_block(fft, i, o)
    })
}

/// The synchronous AM demodulator at 48 ksps.
fn bench_am_sync(fft: &Fft1024) -> KernelResult {
    let input = synth_iq_block(6, 1000.0, 48_000.0);
    let agc = Agc::new(48_000.0, 5.0, 300.0, 100.0, 0.3, 0.01, 100.0);
    let mut demod = AmSyncDemod::new(fft, 48_000.0, 2500.0, agc);
    measure_audio_via_iq("demod_am_sync_48k", fft, &input, move |fft, i, o| {
        demod.process_block(fft, i, o)
    })
}

/// The FM demodulator (75 us de-emphasis, with squelch) at 48 ksps.
fn bench_fm(fft: &Fft1024) -> KernelResult {
    let input = synth_iq_block(7, 2000.0, 48_000.0);
    let squelch = Squelch::new(48_000.0, 0.05, 0.1, 50.0);
    let mut demod = FmDemod::new(fft, 48_000.0, 6000.0, 75.0, squelch);
    measure_audio_via_iq("demod_fm_48k", fft, &input, move |fft, i, o| {
        demod.process_block(fft, i, o)
    })
}

/// The measurement loop shared by the demodulators above: they all take complex IQ in and give real audio
/// out, so their array types differ from those of [`measure_blocks`], which is IQ in and IQ out and is used
/// only by the bare filter kernel.
fn measure_audio_via_iq<F>(
    name: &'static str,
    fft: &Fft1024,
    input: &[C32; BLOCK],
    mut call: F,
) -> KernelResult
where
    F: FnMut(&Fft1024, &[C32; BLOCK], &mut [f32; BLOCK]),
{
    let mut output = [0.0f32; BLOCK];
    call(fft, input, &mut output);
    let start = instret();
    for _ in 0..REPS {
        call(fft, input, &mut output);
    }
    let instr_total = instret() - start;
    KernelResult {
        name,
        sample_rate_hz: 48_000.0,
        unit: Unit::Blocks,
        divisor: REPS,
        instr_total,
        measured: true,
        note: "",
    }
}

/// Noise reduction at 48 ksps, on 512-sample blocks.
fn bench_nr() -> KernelResult {
    let rfft = RealFft::<512>::new();
    let input = synth_audio_block(8, 800.0, 48_000.0);
    let mut nr = NoiseReducer::new(0.9, 0.1);
    measure_audio_blocks("nr_48k", 48_000.0, &input, |i, o| nr.process_block(&rfft, i, o))
}

/// Samples per 12 ksps hop of [`NoiseReducer12k`] (256-sample frames).
const HOP_12K: usize = 128;

/// Noise reduction at 12 ksps (256-sample frames, 128-sample hop). This is the only per-sample DSP that the
/// CPU keeps for an audible receiver, because the FPGA receiver back end delivers demodulated audio at
/// 12 ksps (docs/ARCHITECTURE.md section 3.10, docs/CPU_BUDGET.md). The result is given per input sample
/// (`Unit::Samples`), since the hop is not the 512-sample `BLOCK` that the block unit assumes.
fn bench_nr_12k() -> KernelResult {
    let sample_rate_hz = 12_000.0;
    let rfft = RealFft::<HOP_12K>::new();
    let mut rng = Xorshift32::new(11);
    let mut input = [0.0f32; HOP_12K];
    for (n, s) in input.iter_mut().enumerate() {
        let t = n as f32 / sample_rate_hz;
        *s = 0.6 * libm::sinf(core::f32::consts::TAU * 800.0 * t) + 0.05 * rng.next_bipolar();
    }
    let mut nr = NoiseReducer12k::new(0.9, 0.1);
    let mut output = [0.0f32; HOP_12K];
    nr.process_block(&rfft, &input, &mut output);
    let start = instret();
    for _ in 0..REPS {
        nr.process_block(&rfft, &input, &mut output);
    }
    let instr_total = instret() - start;
    core::hint::black_box(&output);
    KernelResult {
        name: "nr_12k",
        sample_rate_hz,
        unit: Unit::Samples,
        divisor: HOP_12K as u32 * REPS,
        instr_total,
        measured: true,
        note: "",
    }
}

/// The AGC at 12 ksps, counted per sample. The CPU runs it after noise reduction for the receivers that have
/// noise reduction switched on, and the AGC of the FPGA back end covers the others (docs/ARCHITECTURE.md
/// section 3.10).
fn bench_agc_12k() -> KernelResult {
    let sample_rate_hz = 12_000.0;
    let mut agc = Agc::new(sample_rate_hz, 5.0, 300.0, 100.0, 0.3, 0.01, 100.0);
    let mut rng = Xorshift32::new(12);
    let mut x = [0.0f32; BLOCK];
    for (n, v) in x.iter_mut().enumerate() {
        *v = (0.5 + 0.45 * libm::sinf(n as f32 * 0.05)) * libm::sinf(n as f32 * 0.4) + 0.05 * rng.next_bipolar();
    }
    let mut sink = 0.0f32;
    let mut call = || {
        for v in x.iter() {
            sink += agc.process(*v);
        }
    };
    call();
    let start = instret();
    for _ in 0..REPS {
        call();
    }
    let instr_total = instret() - start;
    core::hint::black_box(sink);
    KernelResult {
        name: "agc_12k",
        sample_rate_hz,
        unit: Unit::Samples,
        divisor: BLOCK as u32 * REPS,
        instr_total,
        measured: true,
        note: "",
    }
}

/// The noise blanker on IQ blocks at the given sample rate (the benchmark runs it at 48, 96, 192 and 384 ksps).
fn bench_nb(sample_rate_hz: f32, name: &'static str) -> KernelResult {
    let input = synth_iq_block(9, 1000.0, sample_rate_hz);
    let mut nb = NoiseBlanker::new(sample_rate_hz, 6.0, 0.1, 20.0);
    let mut output = [C32::ZERO; BLOCK];
    nb.process_block(&input, &mut output);
    let start = instret();
    for _ in 0..REPS {
        nb.process_block(&input, &mut output);
    }
    let instr_total = instret() - start;
    KernelResult {
        name,
        sample_rate_hz,
        unit: Unit::Blocks,
        divisor: REPS,
        instr_total,
        measured: true,
        note: "",
    }
}

/// The decimator that brings a receiver stream of `48 kHz * m` down to 48 kHz, fed with
/// `RESAMPLE_INPUT_SAMPLES` input samples per call.
fn bench_resampler(m: u32, name: &'static str) -> KernelResult {
    let native_rate_hz = 48_000.0 * m as f32;
    let mut rng = Xorshift32::new(10 + m);
    let mut samples = [C32::ZERO; RESAMPLE_INPUT_SAMPLES as usize];
    for (n, s) in samples.iter_mut().enumerate() {
        let t = n as f32 / native_rate_hz;
        *s = C32::from_turns(1000.0 * t).scale(0.7) + C32::new(rng.next_bipolar(), rng.next_bipolar()).scale(0.05);
    }
    let mut dec = Decimator::new(m);
    let mut sink = C32::ZERO;
    // The block path (`Decimator::process_block`) is the one the firmware uses; docs/CPU_BUDGET.md section 4
    // has the figure of the per-sample path for comparison.
    let mut out = [C32::ZERO; RESAMPLE_INPUT_SAMPLES as usize / 2 + 1];
    let mut run = || {
        let n = dec.process_block(&samples, &mut out);
        sink += out[n - 1];
    };
    run();
    let start = instret();
    for _ in 0..REPS {
        run();
    }
    let instr_total = instret() - start;
    core::hint::black_box(sink);
    KernelResult {
        name,
        sample_rate_hz: native_rate_hz,
        unit: Unit::Samples,
        divisor: RESAMPLE_INPUT_SAMPLES * REPS,
        instr_total,
        measured: true,
        note: "",
    }
}

/// A result line for a measurement that was not run: `measured` is false, the counts are zero, and `note`
/// says why.
fn stub(name: &'static str, note: &'static str) -> KernelResult {
    KernelResult {
        name,
        sample_rate_hz: 0.0,
        unit: Unit::Blocks,
        divisor: 0,
        instr_total: 0,
        measured: false,
        note,
    }
}

/// The real FT8 measurement, which prints its own `RESULT` lines straight to `out` instead of returning one
/// [`KernelResult`] for the fixed array of [`run_all`]. With the `bench-ft8` feature it prints four lines, one for
/// each of the files qso1 and qso3_busy at the default and the light setting (`ft8_bench::run_all` explains
/// why), and without the feature one stub line.
#[cfg(feature = "bench-ft8")]
fn bench_ft8<W: Write>(out: &mut W) {
    ft8_bench::run_all(out);
}

// Without `bench-ft8` the build needs neither the sample recordings nor the allocator, so only a stub line is printed.
#[cfg(not(feature = "bench-ft8"))]
fn bench_ft8<W: Write>(out: &mut W) {
    let s = stub(
        "ft8_decode",
        "bench-ft8 feature off; run `bash tools/fetch_test_audio.sh` then `bash tools/qemu_s2.sh` \
         (not --smoke) for a real measurement",
    );
    print_result(out, &s);
}

// Placeholder for the measurement of a full 1,920 x 1,080 software render of the GUI (`tr-gui`). It is not wired
// up, so turning `bench-gui` on stops the build with the message below, which says what to add.
#[cfg(feature = "bench-gui")]
fn bench_gui() -> KernelResult {
    compile_error!(
        "tr-bench: bench-gui was turned on but no call into tr-gui has been wired up here yet -- \
         to wire it up, add `tr-gui = { path = \"../tr-gui\" }` to \
         Cargo.toml, replace this function body with an instret-measured full 1,920x1,080 \
         software-render pass, and return a KernelResult with unit = Unit::Blocks, divisor = \
         number of full redraws timed, sample_rate_hz = 0.0 (a redraw is not an audio-rate task; \
         report instructions/redraw and instructions/s at the redraw rate you choose instead)."
    );
}

#[cfg(not(feature = "bench-gui"))]
fn bench_gui() -> KernelResult {
    stub(
        "gui_full_redraw_1920x1080",
        "no call into tr-gui is wired up in tr-bench yet; the bench-gui feature stops the build until one is",
    )
}

/// Prints one kernel's `RESULT` line. The fields are separated by spaces and `tools/qemu_s2.sh` parses them
/// (docs/S2_BENCH.md):
///
/// `RESULT <name> measured=<0|1> rate_hz=<f32> unit=<blocks|samples> divisor=<u32>
/// instr_total=<u64> note=<text or `-`>`
///
/// Used by the loop over the fixed array in [`run_all`] and by the stub of [`bench_ft8`], while the real FT8
/// measurement prints its own lines in the same format.
fn print_result<W: Write>(out: &mut W, r: &KernelResult) {
    let unit_str = match r.unit {
        Unit::Blocks => "blocks",
        Unit::Samples => "samples",
    };
    let note = if r.note.is_empty() { "-" } else { r.note };
    let _ = writeln!(
        out,
        "RESULT {} measured={} rate_hz={} unit={} divisor={} instr_total={} note={}",
        r.name,
        r.measured as u8,
        r.sample_rate_hz,
        unit_str,
        r.divisor,
        r.instr_total,
        note
    );
}

/// Runs every kernel of this crate and writes one `RESULT` line per result to `out`. The FT8 measurement goes
/// through [`bench_ft8`], which prints its own lines instead of using the fixed array below.
pub fn run_all<W: Write>(out: &mut W) {
    let fft = Fft1024::new();

    let results = [
        bench_filter(&fft),
        bench_agc(),
        bench_ssb(&fft),
        bench_cw(&fft),
        bench_am_env(&fft),
        bench_am_sync(&fft),
        bench_fm(&fft),
        bench_nr(),
        bench_nr_12k(),
        bench_agc_12k(),
        bench_nb(48_000.0, "nb_48k"),
        bench_nb(96_000.0, "nb_96k"),
        bench_nb(192_000.0, "nb_192k"),
        bench_nb(384_000.0, "nb_384k"),
        bench_resampler(2, "resamp_m2_96k"),
        bench_resampler(4, "resamp_m4_192k"),
        bench_resampler(8, "resamp_m8_384k"),
        bench_gui(),
    ];

    for r in results.iter() {
        print_result(out, r);
    }

    bench_ft8(out);
}
