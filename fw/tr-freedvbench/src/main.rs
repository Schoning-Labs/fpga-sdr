// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The QEMU program that counts the instructions the FreeDV receiver needs on the target's instruction set
//! (docs/FREEDV.md section 6), measured by QEMU at `-icount shift=0` with `minstret` in the same way as
//! docs/S2_BENCH.md does for the DSP kernels. tools/qemu_freedv.sh runs it and reads the `RESULT` and `STACK`
//! lines.
//!
//! For each mode the modulator makes a signal with a pseudo-random payload, noise is added for the stated
//! signal-to-noise ratio, and the receiver is run in the way the firmware runs it: 12 kHz audio through the
//! resampler down to 8 kHz, the modem, the error correction, the speech decoder, and finally the 8 kHz speech
//! up to 48 kHz. Every receive step is timed, and the result lines give instructions per second of audio.
//! The program also measures how much stack the receiver needs, because the target has little of it.
//!
//! The receiver itself is the `tr-freedv` crate, a port of the FreeDV and codec2 code that stays under its
//! own license (LGPL-2.1); only this benchmark program around it is ours.

#![no_std]
#![no_main]

use core::fmt::Write as _;
use core::mem::MaybeUninit;
use core::panic::PanicInfo;
use core::ptr::addr_of_mut;

use riscv_rt::entry;
use tr_ae350::board::qemu;
use tr_ae350::uart;
use tr_freedv::ofdm::{Mode, SyncState};
use tr_freedv::resample::Resampler;
use tr_freedv::{Rx, Tx, MAX_NIN, MODE_700D, MODE_700E};

/// Prints the panic message on the UART and ends the QEMU run with a failure status.
#[panic_handler]
fn panic(info: &PanicInfo) -> ! {
    let mut con = &uart::CONSOLE;
    let _ = writeln!(con, "PANIC: {info}");
    qemu::exit_fail(1);
}

// The stack under QEMU grows down from 0x8200_0000 (memory-qemu.x). This program's own frames take about
// 100 KB (modulator and signal buffers), so the 512 KB below the top are painted with a pattern before a
// step, and the part that was overwritten afterwards shows how deep the construction and the run of the
// receiver go (docs/FREEDV.md section 9, stack).
const STACK_TOP: usize = 0x8200_0000;
const STACK_BOTTOM: usize = STACK_TOP - 512 * 1024;
const PAINT: u32 = 0xA5A5_A5A5;

/// Paints the unused stack, from `STACK_BOTTOM` up to 1 KB below the current stack pointer, and returns the
/// stack pointer. It is kept out of line so that its own frame stays small and fixed.
#[inline(never)]
fn paint_stack() -> usize {
    let sp: usize;
    // SAFETY: reads the stack pointer only.
    unsafe { core::arch::asm!("mv {}, sp", out(reg) sp) };
    let mut a = STACK_BOTTOM;
    while a + 4 <= sp - 1024 {
        // SAFETY: below the stack pointer, in the stack region, nothing lives there yet.
        unsafe { core::ptr::write_volatile(a as *mut u32, PAINT) };
        a += 4;
    }
    sp
}

/// Bytes of stack used at the deepest point since painting, counted from the top: the search walks up from the
/// bottom until it meets the first word the program has overwritten.
fn stack_used() -> usize {
    let mut a = STACK_BOTTOM;
    // SAFETY: reads inside the stack region.
    while a < STACK_TOP && unsafe { core::ptr::read_volatile(a as *const u32) } == PAINT {
        a += 4;
    }
    STACK_TOP - a
}

/// One receive step in a frame of its own, so that the stack painted below the caller shows all it uses.
#[inline(never)]
fn rx_step(rx: &mut Rx, input: &[i16], out: &mut [i16; MAX_NIN]) -> (tr_freedv::RxStatus, usize) {
    rx.rx(input, out)
}

/// Builds the receiver with `Rx::new`, which builds the value on the stack and then moves it into `slot`.
#[inline(never)]
fn build_by_new(slot: &mut MaybeUninit<Rx>, mode: &'static Mode) {
    slot.write(Rx::new(mode));
}

/// Builds the receiver with `Rx::init`, which fills `slot` in place, for comparison of the stack it takes with
/// that of `build_by_new`.
#[inline(never)]
fn build_in_place(slot: &mut MaybeUninit<Rx>, mode: &'static Mode) {
    Rx::init(slot, mode);
}

/// Prints a `STACK` line with the stack that the construction of the receiver takes below the caller, built
/// both ways (`Rx::new` and `Rx::init`), and the size of the receiver itself.
#[inline(never)]
fn stack_report<W: core::fmt::Write>(con: &mut W, mode: &'static Mode) {
    // SAFETY: single hart, no interrupts; RX is used only here and in `run`.
    let slot = unsafe { &mut *addr_of_mut!(RX) };
    let sp = paint_stack();
    let base = STACK_TOP - sp;
    build_by_new(slot, mode);
    let by_new = stack_used().saturating_sub(base);
    let sp = paint_stack();
    let base = STACK_TOP - sp;
    build_in_place(slot, mode);
    let in_place = stack_used().saturating_sub(base);
    let _ = writeln!(con, "STACK build {}: Rx::new {} bytes, Rx::init {} bytes below the caller (Rx is {} bytes)", mode.name, by_new, in_place, core::mem::size_of::<Rx>());
}

/// The 64-bit count of instructions retired so far (`minstret`).
#[inline]
fn instret() -> u64 {
    riscv::register::minstret::read64()
}

// The receiver and the modulator are large, so they live in statics and not in the stack frames of this program.
static mut RX: MaybeUninit<Rx> = MaybeUninit::uninit();
static mut TX: MaybeUninit<Tx> = MaybeUninit::uninit();

/// A linear congruential generator, enough for a payload and noise that are the same on every run.
struct Lcg(u32);
impl Lcg {
    /// Next 24-bit pseudo-random number.
    fn next(&mut self) -> u32 {
        self.0 = self.0.wrapping_mul(1664525).wrapping_add(1013904223);
        self.0 >> 8
    }
    /// About Gaussian, unit variance (sum of 12 uniform numbers).
    fn gauss(&mut self) -> f32 {
        let mut s = 0.0f32;
        for _ in 0..12 {
            s += (self.next() & 0xffff) as f32 / 65536.0;
        }
        s - 6.0
    }
}

/// Runs `seconds` of signal (or of noise alone, when `signal` is false) through the receiver of `mode` at the given
/// signal-to-noise ratio, and prints one `RESULT freedv` line with the instructions per second of audio for the
/// receiver, for the 12 to 8 kHz converter in front of it and for the 8 to 48 kHz converter behind it, split
/// into the calls made while the receiver was searching for sync and the calls made while it was in sync.
fn run<W: core::fmt::Write>(con: &mut W, mode: &'static Mode, label: &str, signal: bool, snr_db: f32, seconds: usize) {
    // SAFETY: single hart, no interrupts enabled; the two statics are used only here.
    let rx = unsafe { (*addr_of_mut!(RX)).write(Rx::new(mode)) };
    let tx = unsafe { (*addr_of_mut!(TX)).write(Tx::new(mode)) };
    rx.squelch = false;
    let spf = tx.samples_per_frame();
    let k = mode.code.data_bits();
    let mut lcg = Lcg(12345);
    let mut frame = [0i16; 1280];
    let mut frame_pos = spf;
    let mut demod_in = [0i16; MAX_NIN];
    let mut speech = [0i16; MAX_NIN];
    let mut up = Resampler::new_8k_to_48k();
    let mut down = Resampler::new_12k_to_8k();
    // The modulator's signal level is about 4,500 RMS (halved again below when it is fed to the receiver), and the
    // noise is scaled for the stated SNR in a 3 kHz bandwidth.
    let sig_rms = 4500.0f32;
    let sigma = sig_rms / libm_pow10(snr_db / 20.0) / 0.866;

    let (mut n_search, mut i_search, mut max_search) = (0u32, 0u64, 0u64);
    let (mut n_sync, mut i_sync, mut max_sync) = (0u32, 0u64, 0u64);
    let (mut i_up, mut n_up) = (0u64, 0u64);
    let mut samples = 0usize;
    let mut iters = 0u32;
    let mut speech_frames = 0u32;
    let mut rx_stack_max = 0usize;
    // The receiver asks for a varying number of input samples per call (`nin`), so the loop runs until the
    // requested number of seconds at 8 kHz has been fed in.
    while samples < seconds * 8000 {
        let nin = rx.nin();
        for d in demod_in[..nin].iter_mut() {
            if frame_pos == spf {
                let mut payload = [0u8; 112];
                for b in payload[..k].iter_mut() {
                    *b = (lcg.next() & 1) as u8;
                }
                tx.tx_bits(&payload[..k], &[], &mut frame);
                frame_pos = 0;
            }
            let s = if signal { frame[frame_pos] as f32 * 0.5 } else { 0.0 };
            frame_pos += 1;
            *d = (s + 0.5 * sigma * lcg.gauss()) as i16;
        }
        samples += nin;
        let searching = rx.stats().sync_state == SyncState::Search;
        let base = STACK_TOP - paint_stack();
        let t0 = instret();
        let (st, nout) = rx_step(rx, &demod_in[..nin], &mut speech);
        let dt = instret() - t0;
        rx_stack_max = rx_stack_max.max(stack_used().saturating_sub(base));
        if searching {
            n_search += 1;
            i_search += dt;
            max_search = max_search.max(dt);
        } else {
            n_sync += 1;
            i_sync += dt;
            max_sync = max_sync.max(dt);
            iters += rx.stats().ldpc.iterations as u32;
        }
        speech_frames += st.speech as u32;
        // the speech on its way to the 48 kHz audio outputs
        let t0 = instret();
        let mut acc = 0i32;
        up.process(&speech[..nout], |s| acc = acc.wrapping_add(s as i32));
        i_up += instret() - t0;
        n_up += nout as u64;
        core::hint::black_box(acc);
    }
    // the 12 kHz to 8 kHz converter in front, measured on one second
    let t0 = instret();
    let mut acc = 0i32;
    for _ in 0..10 {
        let mut block = [0i16; 1200];
        for (i, b) in block.iter_mut().enumerate() {
            *b = (i as i16).wrapping_mul(37);
        }
        down.process(&block, |s| acc = acc.wrapping_add(s as i32));
    }
    let i_down = instret() - t0;
    core::hint::black_box(acc);

    let total = i_search + i_sync;
    let per_s = total * 8000 / samples as u64;
    let up_per_s = if n_up > 0 { i_up * 8000 / n_up } else { 0 };
    let _ = writeln!(
        con,
        "RESULT freedv mode={} case={} seconds={} rx_instr_per_s={} search_calls={} search_avg={} search_max={} sync_calls={} sync_avg={} sync_max={} ldpc_iter_avg_x10={} speech_frames={} down12to8_instr_per_s={} up8to48_instr_per_s={} all_instr_per_s={} rx_stack_bytes={}",
        mode.name,
        label,
        seconds,
        per_s,
        n_search,
        if n_search > 0 { i_search / n_search as u64 } else { 0 },
        max_search,
        n_sync,
        if n_sync > 0 { i_sync / n_sync as u64 } else { 0 },
        max_sync,
        if n_sync > 0 { iters * 10 / n_sync } else { 0 },
        speech_frames,
        i_down,
        up_per_s,
        per_s + i_down + up_per_s,
        rx_stack_max,
    );
}

/// 10^x without pulling libm in here.
fn libm_pow10(x: f32) -> f32 {
    // exp(x ln 10) by its power series, which is accurate enough because x stays within +/-1 here
    let y = x * 2.302_585;
    let mut term = 1.0f32;
    let mut sum = 1.0f32;
    for n in 1..20 {
        term *= y / n as f32;
        sum += term;
    }
    sum
}

/// Measures the stack of building the receiver in both modes, then runs each mode on a clean signal, on a signal at
/// 2 dB SNR and on noise alone, and exits QEMU with a pass status.
#[entry]
fn main() -> ! {
    let mut con = &uart::CONSOLE;
    con.init(24_000_000, 115_200);
    let _ = writeln!(con, "fpga-sdr FreeDV receive benchmark (QEMU)");
    unsafe { tr_ae350::fpu::enable() };

    for mode in [&MODE_700D, &MODE_700E] {
        stack_report(&mut con, mode);
    }
    for mode in [&MODE_700D, &MODE_700E] {
        run(&mut con, mode, "clean", true, 30.0, 4);
        run(&mut con, mode, "snr2dB", true, 2.0, 6);
        run(&mut con, mode, "noise_only", false, 0.0, 4);
    }

    let _ = writeln!(con, "FreeDV bench done");
    qemu::exit_pass();
}
