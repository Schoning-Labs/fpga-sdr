// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The QEMU entry point of the CPU benchmark: it enables the FPU (every kernel works on `f32`), runs every
//! `tr-bench` kernel through `tr_bench::run_all` (which does not depend on the board, see src/lib.rs), and
//! prints one `RESULT ...` line per kernel over the UART before it shuts QEMU down. tools/qemu_s2.sh runs it
//! and parses the transcript into the table of docs/S2_BENCH.md, and that script and document also explain
//! the `-icount` flag the measurement depends on and why.
//!
//! The structure follows fw/tr-app/src/bin/qemu_smoke.rs, the QEMU smoke test of the board support crate:
//! the same restriction to the `board-qemu` feature (`required-features` in Cargo.toml), the same panic
//! handler that prints to the UART and then exits with a failure code, and the same clean shutdown through
//! QEMU's "SiFive test finisher" once the run is done.

#![no_std]
#![no_main]

use core::fmt::Write as _;
use core::panic::PanicInfo;

use riscv_rt::entry;
use tr_ae350::board::qemu;
use tr_ae350::uart;

/// Prints the panic message on the UART and ends the QEMU run with a failure status.
#[panic_handler]
fn panic(info: &PanicInfo) -> ! {
    let mut con = &uart::CONSOLE;
    let _ = writeln!(con, "PANIC: {info}");
    qemu::exit_fail(1);
}

/// Sets up the console and the FPU, runs all kernels and exits QEMU with a pass status.
#[entry]
fn main() -> ! {
    let mut con = &uart::CONSOLE;
    // As in qemu_smoke.rs, QEMU's ns16550a model does not pace the output by the programmed divisor, so
    // the exact input clock value given here does not matter.
    con.init(24_000_000, 115_200);
    let _ = writeln!(con, "fpga-sdr S2 CPU benchmark (QEMU)");

    // Every kernel measured below does real f32 arithmetic (FFT butterflies, AGC, filters), and the first
    // f32 instruction traps while mstatus.FS is still Off, which is how the core starts; qemu_smoke.rs has
    // the same requirement for its own "fpu ok" check.
    unsafe { tr_ae350::fpu::enable() };

    tr_bench::run_all(&mut con);

    let _ = writeln!(con, "S2 bench done");
    qemu::exit_pass();
}
