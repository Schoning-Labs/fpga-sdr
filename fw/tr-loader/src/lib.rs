// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

#![no_std]

//! The stage-0 loader (docs/C2_LOADER.md): the first program the AE350 processor runs after reset.
//! It either receives a firmware image over the UART (and runs it from RAM or writes it to flash)
//! or, when nobody sends one, loads the firmware image that is already in flash and starts it.
//!
//! The library holds the UART protocol (`protocol`, which does not know the image format beyond
//! `tr-image`), the flash layout both boards agree on (`layout`), and flash read, program and erase
//! for the real board only (`flash`, with the record of the active slot in `settings`).
//! `bin/stage0.rs` wires these into the boot sequence.
//!
//! The crate is `no_std` unconditionally, like `tr-ae350` (see that crate's `lib.rs`), because it only
//! ever targets `riscv32imafc-unknown-none-elf`. `tools/check.sh` cross-builds it, `tools/qemu_c2.sh`
//! runs it under QEMU, and it is never run with `cargo test` on the host: what is host-tested is the
//! image format it relies on (`tr-image`) and the flash layout and write guard (`tr-loader-layout`).
//!
//! Board selection mirrors `tr-ae350`: exactly one of the features `board-ae350` (the default) and
//! `board-qemu` is compiled in.

#[cfg(all(feature = "board-ae350", feature = "board-qemu"))]
compile_error!("tr-loader: enable exactly one of board-ae350 / board-qemu, not both");
#[cfg(not(any(feature = "board-ae350", feature = "board-qemu")))]
compile_error!("tr-loader: enable exactly one of board-ae350 / board-qemu");

pub mod layout;
pub mod protocol;

#[cfg(feature = "board-ae350")]
pub mod flash;
#[cfg(feature = "board-ae350")]
pub mod settings;
