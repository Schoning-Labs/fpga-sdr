// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The payload of the stage-0 loader's QEMU test (docs/C2_LOADER.md, `tools/qemu_c2.sh`): a
//! self-contained riscv-rt binary that prints one known line, `payload ok`, and then ends the
//! emulator with a pass status. It is packed with `cargo run -p xtask -- image` and sent by
//! `tr-loader-send`, and when its line shows up on the console it proves that stage-0 received the
//! image, put it at the address in its header and jumped to it, and that the code really runs
//! there. The console is the same `tr_ae350::uart::CONSOLE` that stage-0 used, at QEMU's fixed UART
//! address, which says nothing about where this binary was placed. What the test shows about the
//! placement is that this code runs at all, because it was linked for the address given in
//! `memory-qemu.x`.

#![no_std]
#![no_main]

use core::fmt::Write as _;
use core::panic::PanicInfo;

use riscv_rt::entry;
use tr_ae350::board::qemu;
use tr_ae350::uart;

/// A panic ends the emulator with a failure status (2), so the test script sees it.
#[panic_handler]
fn panic(_info: &PanicInfo) -> ! {
    qemu::exit_fail(2)
}

/// Prints the known line and ends the emulator with a pass status.
#[entry]
fn main() -> ! {
    let mut con = &uart::CONSOLE;
    let _ = writeln!(con, "payload ok");
    qemu::exit_pass()
}
