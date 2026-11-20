// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! QEMU test that a trap leaves the floating-point state of the interrupted task alone: a timer interrupt handler
//! that uses floating point, firing during an FP loop in the main task, must leave the results of the main task
//! bit-identical to a run without interrupts. The custom `_start_trap` of `fw/tr-ae350/src/trap.rs` forces
//! `mstatus.FS` to Off and restores it on every trap, interrupt or exception, with no handler-side code, so
//! the test exercises the trap entry directly and not a convention a handler has to follow. `tools/qemu_c4.sh`
//! builds it the same way `tools/qemu_c1.sh` builds `qemu_smoke` (`--features board-qemu`, see the
//! `required-features` of the bin in Cargo.toml) and runs it.
//!
//! There are four phases in one QEMU run:
//!
//! 1. `baseline`: an f64 chaotic-map loop (deterministic and sensitive to any change of a bit, see the
//!    documentation of `chaotic_loop`) with the timer never armed and no `ebreak` inserted, so no trap of any kind
//!    fires during it.
//! 2. `with_interrupts`: the identical loop with a real `core_interrupt(MachineTimer)` handler firing repeatedly
//!    throughout it (it re-arms itself every `GOOD_PERIOD_TICKS`), compared bit for bit with `baseline`.
//! 3. `with_exceptions`: the identical loop again, this time with a deliberate `ebreak` (a breakpoint exception)
//!    every `BREAK_EVERY` iterations. The handler advances `mepc` past it and returns normally, so `_start_trap`
//!    takes its shared path of restoring FS and then `mret`, the same path the normal return of an interrupt
//!    handler takes. The result is compared bit for bit with `baseline` too, which checks that FS survives an
//!    exception and not only an interrupt.
//! 4. `guard`: one more timer interrupt, this time with the handler deliberately executing an `fadd.d`.
//!    `_start_trap` has already forced `mstatus.FS` to Off before the handler runs, so the instruction cannot
//!    execute and traps as an illegal instruction (RISC-V privileged specification). `illegal_instruction`
//!    below catches it, reports it and exits.

#![no_std]
#![no_main]

use core::fmt::Write as _;
use core::panic::PanicInfo;
use core::sync::atomic::{AtomicBool, AtomicU32, Ordering};

use riscv::interrupt::{Exception, Interrupt};
use riscv_rt::{entry, exception};
use tr_ae350::board::qemu;
use tr_ae350::{timer, uart};

#[panic_handler]
fn panic(info: &PanicInfo) -> ! {
    let mut con = &uart::CONSOLE;
    let _ = writeln!(con, "PANIC: {info}");
    qemu::exit_fail(1);
}

// Re-arm period for the repeated well-behaved firings of phase 2. It is short enough that dozens of interrupts
// land during the loop below (tools/qemu_c4.sh checks that the printed count is not zero, so the test cannot
// silently test nothing) and long enough that the few extra integer instructions of the trap entry
// (fw/tr-ae350/src/trap.rs) do not dominate the run.
const GOOD_PERIOD_TICKS: u64 = qemu::TIMER_HZ as u64 / 500; // 2 ms

// Iterations of the chaotic map. The loop is large enough to run for a few hundred milliseconds of QEMU wall-clock
// time under `-M virt`, whose machine timer ticks against real time and not against the instruction count (the 50 ms
// delay of tools/qemu_c1.sh is sized the same way), so the 2 ms period of GOOD_PERIOD_TICKS has many chances to
// fire during it.
const ITERS: u32 = 4_000_000;

// How often phase 3 inserts a deliberate `ebreak`. Unlike the timer this is a synchronous exception, so it fires
// exactly `ITERS / BREAK_EVERY` times whatever the speed of the host, and no tuning against wall-clock time is needed.
const BREAK_EVERY: u32 = 20_000;

/// Timer interrupts handled in phase 2.
static GOOD_FIRES: AtomicU32 = AtomicU32::new(0);
/// Breakpoint exceptions handled in phase 3.
static EXC_FIRES: AtomicU32 = AtomicU32::new(0);
/// Set for phase 4: the timer handler then executes an FP instruction on purpose.
static PROBE_ARMED: AtomicBool = AtomicBool::new(false);

#[riscv_rt::core_interrupt(Interrupt::MachineTimer)]
fn machine_timer() {
    if PROBE_ARMED.load(Ordering::SeqCst) {
        // Deliberate violation, for phase 4 only. `_start_trap` in fw/tr-ae350/src/trap.rs has already forced
        // `mstatus.FS` to Off before this handler runs, so the instruction does not execute: it traps as an
        // illegal instruction before `fa0` is touched, and `illegal_instruction` below catches it. If it did
        // execute it would silently overwrite whatever 64-bit value the interrupted `chaotic_loop` has live in
        // `fa0`, which is the corruption the trap entry exists to prevent. There is no guard call in the handler,
        // since the protection is automatic at the trap entry.
        unsafe { core::arch::asm!("fadd.d fa0, fa0, fa0") };
        // Unreachable if the trap entry did its job.
        return;
    }

    // A real handler needs only two things here, re-arming and recording that it ran. Both are plain integer and
    // memory operations that read and write no FP register, so `chaotic_loop` in the interrupted task is
    // untouched however often this fires.
    timer::arm_after(GOOD_PERIOD_TICKS);
    GOOD_FIRES.fetch_add(1, Ordering::SeqCst);
}

/// Phase 3's deliberate, recoverable exception. `chaotic_loop` inserts the `ebreak` as the raw 4-byte
/// encoding (`.word 0x00100073`, so its width does not depend on what the assembler would choose), and
/// resuming past it means `mepc + 4`. The processor does not advance `mepc` on an exception, and writing it back
/// here is what makes this recoverable and not an endless loop of traps. Returning normally (not `-> !`) sends
/// execution through the shared exit path of `_start_trap` (fw/tr-ae350/src/trap.rs), which restores `mstatus.FS`
/// from the value saved on entry, restores the integer registers and executes `mret`, so `chaotic_loop` resumes
/// right after the `ebreak` with its FP state exactly as it was.
#[exception(Exception::Breakpoint)]
unsafe fn breakpoint(_frame: &riscv_rt::TrapFrame) {
    let mepc = tr_ae350::mepc();
    core::arch::asm!("csrw mepc, {0}", in(reg) mepc + 4);
    EXC_FIRES.fetch_add(1, Ordering::SeqCst);
}

#[exception(Exception::IllegalInstruction)]
unsafe fn illegal_instruction(_frame: &riscv_rt::TrapFrame) -> ! {
    let mut con = &uart::CONSOLE;
    if PROBE_ARMED.load(Ordering::SeqCst) {
        let _ = writeln!(
            con,
            "guard ok (fp-in-handler caught, mcause={:#x} mepc={:#x})",
            tr_ae350::mcause(),
            tr_ae350::mepc()
        );
        qemu::exit_pass();
    }
    let _ = writeln!(
        con,
        "PANIC: unexpected illegal instruction (mcause={:#x} mepc={:#x})",
        tr_ae350::mcause(),
        tr_ae350::mepc()
    );
    qemu::exit_fail(2);
}

/// A logistic map (`x' = r*x*(1-x)`) just inside its chaotic regime (`r` close to 4). The rounding of each
/// iteration is amplified by the next, so if a single bit of `x` were ever wrong, for instance because a trap
/// handler clobbered the FP register holding it, the final result would diverge completely from a clean run and
/// not just differ in a low bit. That makes bit-for-bit equality with `baseline` a meaningful check and not a
/// coincidence of rounding. `#[inline(never)]` keeps `x` genuinely live across loop iterations (in some 64-bit
/// FP register, or spilled to the stack) and stops the optimizer from folding the whole loop at compile time.
///
/// `break_every`: if nonzero, a deliberate `ebreak` is executed every `break_every` iterations (phase 3). Zero
/// means never, which is the case for phases 1 and 2 (phase 2 uses the machine timer instead).
#[inline(never)]
fn chaotic_loop(iters: u32, break_every: u32) -> f64 {
    const R: f64 = 3.999_999;
    let mut x: f64 = 0.512_345_678_9;
    for i in 0..iters {
        x = R * x * (1.0 - x);
        if break_every != 0 && i % break_every == 0 {
            unsafe { core::arch::asm!(".word 0x00100073") }; // ebreak, fixed 4-byte encoding
        }
    }
    x
}

#[entry]
fn main() -> ! {
    let mut con = &uart::CONSOLE;
    con.init(24_000_000, 115_200);
    let _ = writeln!(con, "fpga-sdr C4 QEMU FP-trap test");
    let _ = writeln!(con, "hello ok");

    unsafe { tr_ae350::fpu::enable() };

    // Phase 1: the baseline, with no trap of any kind during the loop.
    let baseline = chaotic_loop(ITERS, 0);
    let _ = writeln!(
        con,
        "baseline ok (x={baseline} bits={:#018x})",
        baseline.to_bits()
    );

    // Phase 2: the identical loop with a real machine-timer interrupt firing repeatedly throughout it. Each
    // firing is a genuine hardware trap into `machine_timer` above and not a simulated call.
    timer::arm_after(GOOD_PERIOD_TICKS);
    unsafe { tr_ae350::enable_timer_interrupt() };
    let with_interrupts = chaotic_loop(ITERS, 0);
    timer::disarm();
    let fires = GOOD_FIRES.load(Ordering::SeqCst);
    let _ = writeln!(
        con,
        "with_interrupts ok (x={with_interrupts} bits={:#018x}, {fires} timer interrupts fired)",
        with_interrupts.to_bits()
    );
    assert!(
        fires > 10,
        "timer fired only {fires} times during the loop -- test does not exercise interrupts \
         firing repeatedly; widen ITERS or shrink GOOD_PERIOD_TICKS"
    );
    assert_eq!(
        baseline.to_bits(),
        with_interrupts.to_bits(),
        "chaotic_loop's result changed when a timer interrupt fired during it"
    );
    let _ = writeln!(con, "bitidentical ok");

    // Phase 3: the identical loop again, this time with a real breakpoint exception (not an interrupt) firing
    // repeatedly throughout it. This shows that the FS save and restore of the trap entry works for the
    // synchronous exception path as well as for interrupts.
    let with_exceptions = chaotic_loop(ITERS, BREAK_EVERY);
    let exc_fires = EXC_FIRES.load(Ordering::SeqCst);
    let _ = writeln!(
        con,
        "with_exceptions ok (x={with_exceptions} bits={:#018x}, {exc_fires} breakpoint exceptions fired)",
        with_exceptions.to_bits()
    );
    assert!(
        exc_fires > 10,
        "breakpoint fired only {exc_fires} times during the loop -- test does not exercise \
         exceptions firing repeatedly; widen ITERS or shrink BREAK_EVERY"
    );
    assert_eq!(
        baseline.to_bits(),
        with_exceptions.to_bits(),
        "chaotic_loop's result changed when a breakpoint exception fired during it"
    );
    let _ = writeln!(con, "exceptionbitidentical ok");

    // Phase 4: a handler that deliberately tries to use the FPU must be caught, with nothing required of the handler.
    PROBE_ARMED.store(true, Ordering::SeqCst);
    timer::arm_after(GOOD_PERIOD_TICKS);
    unsafe { tr_ae350::enable_timer_interrupt() };
    loop {
        riscv::asm::wfi();
    }
}
