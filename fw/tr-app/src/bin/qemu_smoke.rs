// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Smoke test of the target-independent parts of the firmware under QEMU's `virt` machine: hello over the
//! UART, the FPU, the PLIC registers, a machine-timer interrupt and a trap on an illegal instruction.
//! `tools/qemu_c1.sh` builds it with `--no-default-features --features board-qemu` (the `required-features`
//! of the bin in Cargo.toml keep it out of every other build) and runs it.
//!
//! The steps run in this order: UART hello, FPU sanity check, PLIC register check, arm and wait for a real
//! machine-timer interrupt, then deliberately execute an illegal instruction and let the trap handler report
//! it and exit. Each step prints "<name> ok" so that the script can search the transcript for it, and the
//! last line ("trap ok ...") is followed by a clean QEMU shutdown (`board::qemu::exit_pass()`), so the
//! script does not need to guess how long to wait.

#![no_std]
#![no_main]

use core::fmt::Write as _;
use core::panic::PanicInfo;
use core::sync::atomic::{AtomicBool, Ordering};

use riscv::interrupt::{Exception, Interrupt};
use riscv_rt::{entry, exception};
use tr_ae350::board::qemu;
use tr_ae350::{plic, timer, uart};

#[panic_handler]
fn panic(info: &PanicInfo) -> ! {
    let mut con = &uart::CONSOLE;
    let _ = writeln!(con, "PANIC: {info}");
    qemu::exit_fail(1);
}

/// Set by the timer interrupt handler, polled by `main`.
static TIMER_FIRED: AtomicBool = AtomicBool::new(false);

// Ticks to wait before the timer interrupt fires. board::qemu::TIMER_HZ is 10 MHz (the fixed timebase of
// QEMU's virt machine, see board.rs), so this is 50 ms: long enough to be clearly a real wait and not a compare
// value that is already pending, and short enough not to slow the check down.
const TIMER_DELAY_TICKS: u64 = qemu::TIMER_HZ as u64 / 20;

#[riscv_rt::core_interrupt(Interrupt::MachineTimer)]
fn machine_timer() {
    // Push mtimecmp out to the far future first (timer::disarm() does exactly that), so that the interrupt
    // does not fire again on the next `wfi` before main has acted on the flag.
    timer::disarm();
    let mut con = &uart::CONSOLE;
    let _ = writeln!(con, "timer ok (now={})", timer::now());
    TIMER_FIRED.store(true, Ordering::SeqCst);
}

#[exception(Exception::IllegalInstruction)]
unsafe fn illegal_instruction(_frame: &riscv_rt::TrapFrame) -> ! {
    let mut con = &uart::CONSOLE;
    let _ = writeln!(
        con,
        "trap ok (mcause={:#x} mepc={:#x})",
        tr_ae350::mcause(),
        tr_ae350::mepc()
    );
    qemu::exit_pass();
}

#[entry]
fn main() -> ! {
    let mut con = &uart::CONSOLE;
    // QEMU's ns16550a model does not rate-limit by the programmed divisor, so the exact uclk value does not
    // affect the test. It is passed to exercise the same init() path that the real AE350 UART2 uses.
    con.init(24_000_000, 115_200);
    let _ = writeln!(con, "fpga-sdr C1 QEMU smoke test");
    let _ = writeln!(con, "hello ok");

    unsafe { tr_ae350::fpu::enable() };
    let product: f32 = 1.5 * 2.0;
    let _ = writeln!(con, "fpu ok (1.5*2 = {product})");
    assert_eq!(product, 3.0);

    plic::PLIC.set_priority(qemu::UART_IRQ, 1);
    let readback = plic::PLIC.priority(qemu::UART_IRQ);
    plic::PLIC.set_threshold(0);
    let _ = writeln!(con, "plic ok (priority readback = {readback})");
    assert_eq!(readback, 1);

    timer::arm_after(TIMER_DELAY_TICKS);
    unsafe { tr_ae350::enable_timer_interrupt() };
    while !TIMER_FIRED.load(Ordering::SeqCst) {
        riscv::asm::wfi();
    }

    // Deliberately illegal: the `illegal_instruction` handler above takes over from here and never returns
    // (it calls qemu::exit_pass()), so nothing after this line runs.
    tr_ae350::illegal_instruction();
    unreachable!("illegal_instruction() should have trapped");
}
