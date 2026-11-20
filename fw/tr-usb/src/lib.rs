// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The USB descriptors of the board's USB audio device (`docs/USB_AUDIO.md`).
//!
//! The RTL (`rtl/usb/`) does all of the USB protocol, including the enumeration, so the device
//! works before and without firmware. The descriptors are written here because Rust makes them
//! easy to read and to test, and they are compiled into the descriptor ROM of the RTL
//! (`rtl/usb/usb_desc_rom.hex`) and its parameter file (`rtl/usb/usb_desc_params.vh`). The
//! `generated_files_up_to_date` test fails if either file differs from what this crate produces,
//! and it rewrites them when it runs with `TR_USB_WRITE=1`.
//!
//! The register driver is `tr_fabric::usb`.

#![no_std]

#[cfg(test)]
extern crate std;

pub mod descriptors;

#[cfg(test)]
mod generated;
