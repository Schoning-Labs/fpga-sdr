// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Entry point of the stage-0 loader (docs/C2_LOADER.md), which is the code at the processor's reset
//! vector. It is linked to run in place from flash (`memory-loader-ae350.x`) on the real board, and
//! from RAM under QEMU (`memory-loader-qemu.x`). The boot sequence is:
//!
//! 1. On the real board (`board-ae350` only) the flash-programming primitives that are linked into the
//!    `.ramfunc` section are copied to DLM (`flash::init`, which calls `flash::copy_ramfunc`) before
//!    anything might need them, and the flash chip and the address mapping are checked; see the module
//!    text of `flash.rs`.
//! 2. The UART is initialized and a banner is printed, followed on the real board by the flash chip's
//!    JEDEC id and the result of the mapping check.
//! 3. The loader offers the UART handshake for a fixed window of time (`protocol::wait_for_handshake`).
//!    docs/C2_LOADER.md "Why a UART timeout window, not a button/strap" says why a timeout and not a
//!    button or a strap pin is what enters loader mode.
//! 4. If the handshake arrives, an image is received (`protocol::receive_image`) and then, according to
//!    the command byte the host sends after it, either started from RAM at once or (`board-ae350` only)
//!    programmed into the inactive flash slot.
//! 5. If it does not arrive, `board-ae350` loads the active flash slot (`flash::read_and_validate_slot`)
//!    and starts it, and tries the other slot if that one is not valid. `board-qemu` has no flash to fall
//!    back to (QEMU's `virt` machine has no SPI flash model), so it goes back to offering the handshake
//!    again; `tools/qemu_c2.sh` always starts the handshake well inside the window.
//!
//! Anything that goes wrong is printed on the UART console as a line of text, and after a failed
//! attempt the loader offers the handshake again.

#![no_std]
#![no_main]

use core::fmt::Write as _;
use core::panic::PanicInfo;

use riscv_rt::entry;
use tr_ae350::{board, uart};
use tr_loader::{layout, protocol};

/// Prints the panic message on the console and stops: the loader has no way to recover from a bug in
/// itself, and the UART line is the only place a person can see what happened.
#[panic_handler]
fn panic(info: &PanicInfo) -> ! {
    let mut con = &uart::CONSOLE;
    let _ = writeln!(con, "PANIC: {info}");
    halt()
}

/// Under QEMU a failure ends the emulator with a nonzero exit code, which is what the test script
/// looks for.
#[cfg(feature = "board-qemu")]
fn halt() -> ! {
    board::qemu::exit_fail(1)
}
/// On the board the processor goes to sleep (wait for interrupt) in a loop and does nothing more.
#[cfg(feature = "board-ae350")]
fn halt() -> ! {
    loop {
        riscv::asm::wfi();
    }
}

/// How long stage-0 waits for the sync-byte handshake (`protocol::SYNC`) before giving up on this
/// attempt (`board-ae350` then falls back to flash, `board-qemu` offers the handshake again). Two
/// seconds is long enough that a host-side sender (`tr-loader-send`, or `tools/qemu_c2.sh` driving it)
/// started just as the board or the VM boots will not realistically miss it, and the price is a one-time
/// 2 s delay on every real cold boot with nothing attached to the UART, which is an acceptable trade for
/// a hobby board that has no other console or display feedback this early in boot. The value is
/// tunable and is not a hardware fact.
///
/// `board-qemu` gets a longer window than `board-ae350`, purely to absorb host-side scheduling jitter
/// before the *first* sync byte arrives when `tools/qemu_c2.sh` runs on a loaded machine (QEMU, and the
/// virtual CPU's thread inside it, may simply not be scheduled for a while). That has nothing to do with
/// real UART timing, so it is QEMU-only and the 2 s wait of the real board with no host attached stays
/// as it is. A handshake that is already under way has no fixed total budget (see
/// `protocol::wait_for_handshake`), so this constant only has to cover the time before the host starts
/// sending at all.
#[cfg(feature = "board-ae350")]
const HANDSHAKE_WINDOW_MS: u64 = 2000;
#[cfg(feature = "board-qemu")]
const HANDSHAKE_WINDOW_MS: u64 = 5000;

/// The handshake window in timer ticks, as `wait_for_handshake` wants it. It is only as close to the
/// stated number of milliseconds as `board::active::TIMER_HZ` is to the real timer frequency, and that
/// constant is a placeholder on the real board (see its comment in `tr_ae350::board`).
fn handshake_window_ticks() -> u64 {
    (board::active::TIMER_HZ as u64) * HANDSHAKE_WINDOW_MS / 1000
}

/// Jumps to the entry point of a received or loaded image and never returns. The payload is
/// expected to be a fully independent bare-metal image whose own `_start` sets up its own stack from its
/// own linker script, exactly as stage-0's did (docs/C2_LOADER.md "Protocol"). Stage-0 prepares nothing
/// for it (and could not, since it has no idea what the payload is) beyond having placed its bytes at
/// `entry` and checked their CRC.
fn start(entry: u32) -> ! {
    let f: extern "C" fn() -> ! = unsafe { core::mem::transmute::<usize, extern "C" fn() -> !>(entry as usize) };
    f()
}

/// The boot path when nobody sends an image: tries the active flash slot first and then the other
/// one, starting the first slot whose image passes every check. It returns only when neither slot
/// holds a valid image, after printing why each one was refused.
#[cfg(feature = "board-ae350")]
fn normal_boot_from_flash(mut con: &uart::Uart) {
    use tr_loader::settings::Settings;

    // No settings record yet means slot A.
    let active = Settings::read().map(|s| s.active_slot).unwrap_or(0);
    let order: [u8; 2] = if active == 0 { [0, 1] } else { [1, 0] };
    for slot in order {
        match tr_loader::flash::read_and_validate_slot(slot, layout::DEST_BASE, layout::DEST_LEN) {
            Ok(header) => {
                let _ = writeln!(con, "OK crc, starting slot {slot} at {:#010x}", header.entry);
                start(header.entry);
            }
            Err(e) => {
                let _ = writeln!(con, "slot {slot}: {e}");
            }
        }
    }
    let _ = writeln!(con, "no valid image in flash, offering the UART loader again");
}

/// Writes the image that `receive_image` has just put in RAM (header `header`) into the flash slot
/// that is not active, and then makes that slot the active one. The order is the point of the A/B
/// scheme: the settings record is changed only after the slot has been written and read back, so a
/// failure leaves the previous slot active and bootable. The result is printed as one line that starts
/// with `OK flash` or `ERR flash`.
#[cfg(feature = "board-ae350")]
fn handle_flash_write(mut con: &uart::Uart, header: &tr_image::ImageHeader) {
    use tr_loader::settings::Settings;

    // SAFETY: protocol::receive_image already wrote and CRC-validated exactly this many bytes at
    // this address before returning Action::Flash to us.
    let payload =
        unsafe { core::slice::from_raw_parts(header.load_addr as *const u8, header.length as usize) };
    let header_bytes = header.to_bytes();

    let current = Settings::read().map(|s| s.active_slot).unwrap_or(0);
    let target_slot: u8 = if current == 0 { 1 } else { 0 }; // always write the *inactive* slot

    match tr_loader::flash::program_image(target_slot, &header_bytes, payload) {
        Ok(()) => match (Settings { active_slot: target_slot }).write() {
            Ok(()) => {
                let _ = writeln!(con, "OK flash, written to slot {target_slot}");
            }
            Err(e) => {
                let _ = writeln!(con, "ERR flash: slot {target_slot} written but the settings sector failed: {e}");
            }
        },
        Err(e) => {
            let _ = writeln!(con, "ERR flash write failed: {e}");
        }
    }
}

/// The loader's main loop. It never returns: it either jumps into an image or keeps offering the
/// handshake again, and every failure ends up as a line on the console.
#[entry]
fn main() -> ! {
    // board-ae350: copy the flash primitives to RAM, then compare 64 bytes of this loader as the
    // processor fetches them (0x8000_0000) with chip offset 0x60_0000 read by a read command.
    #[cfg(feature = "board-ae350")]
    let mapping = tr_loader::flash::init();

    let mut con = &uart::CONSOLE;
    // The UART clock frequency of each board is given in `tr_ae350::board` (the real board's
    // value is marked there as not yet verified, see docs/C1_AE350.md and docs/C2_LOADER.md).
    // QEMU's ns16550a model does not rate-limit by the programmed divisor either way, so the value
    // only matters when the real UART is read with a terminal program.
    con.init(board::active::UART_CLOCK_HZ, 115_200);
    let _ = writeln!(con, "fpga-sdr stage-0 loader");
    #[cfg(feature = "board-ae350")]
    {
        use tr_loader::flash::{jedec, Mapping};
        match jedec() {
            Some(id) => {
                let _ = writeln!(con, "flash chip JEDEC id {:02x}{:02x}{:02x}", id[0], id[1], id[2]);
            }
            None => {
                let _ = writeln!(con, "flash chip: no answer to the JEDEC id command (flash writes will be refused)");
            }
        }
        let _ = writeln!(
            con,
            "flash mapping: CPU {:#010x} = chip {:#08x}: {}",
            layout::FLASH_BASE,
            layout::MAP_CHIP,
            match mapping {
                Mapping::Agrees => "confirmed (same bytes by memory-mapped read and by read command)",
                Mapping::Differs => "DIFFERS (images are read by read commands; the loader is not where the CPU runs it)",
                Mapping::Unknown => "not checked (the chip did not answer a read command)",
            }
        );
    }

    let window_ticks = handshake_window_ticks();
    loop {
        // The prompt ends with PROMPT_MARKER, the fixed token the sender (`tr-loader-send`) waits
        // for before it sends the sync bytes.
        let _ = writeln!(
            con,
            "loader: send the sync bytes {:02x?} within {HANDSHAKE_WINDOW_MS}ms to enter UART loader mode {}",
            protocol::SYNC,
            protocol::PROMPT_MARKER
        );
        if protocol::wait_for_handshake(con, window_ticks) {
            // Tell the sender that the sync bytes were taken and the image may follow.
            let _ = writeln!(con, "{}", protocol::ACK_MARKER);
            // SAFETY: layout::DEST_BASE/DEST_LEN is this board's documented, exclusive
            // destination window (layout.rs); nothing else runs concurrently on this single-hart
            // loader.
            match unsafe { protocol::receive_image(con, layout::DEST_BASE, layout::DEST_LEN) } {
                Ok((header, protocol::Action::Run)) => {
                    let _ = writeln!(con, "OK crc, starting at {:#010x}", header.entry);
                    start(header.entry);
                }
                Ok((header, protocol::Action::Flash)) => {
                    #[cfg(feature = "board-ae350")]
                    handle_flash_write(con, &header);
                    #[cfg(feature = "board-qemu")]
                    {
                        let _ = header;
                        let _ = writeln!(con, "ERR flash-write is board-only, not available under QEMU");
                    }
                }
                Err(e) => {
                    let _ = writeln!(con, "{e}");
                }
            }
        } else {
            #[cfg(feature = "board-ae350")]
            normal_boot_from_flash(con);
            #[cfg(feature = "board-qemu")]
            let _ = writeln!(con, "no handshake seen (QEMU has no flash to fall back to)");
        }
    }
}

// The A extension is off for all firmware (fw/.cargo/config.toml), so the compiler calls the libatomic functions for
// atomic accesses. Stage 0 runs on one hart with nothing else to interrupt it, so a plain volatile access is atomic
// enough. These are the one-byte forms that `core` asks for here; tr-app has the four-byte forms (tr-app/src/atomics.rs).
#[no_mangle]
pub unsafe extern "C" fn __atomic_load_1(ptr: *const u8, _order: i32) -> u8 {
    ptr.read_volatile()
}

#[no_mangle]
pub unsafe extern "C" fn __atomic_store_1(ptr: *mut u8, value: u8, _order: i32) {
    ptr.write_volatile(value)
}
