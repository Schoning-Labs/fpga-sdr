// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Hermes-Lite 2 (HL2) protocol: discovery, start and stop, register writes, the register bridge
//! (Etherbone) and I2C over it, the transmit-safety byte, N2ADR filter selection, and a minimal
//! DHCP server for the HL2 link.
//!
//! The crate is `no_std` by default, which covers the core wire format (`protocol`, `bridge`,
//! `filter`, `dhcp`, and the message layer `msg` with its control policy `control`) that the AE350
//! firmware uses. The feature `std` (on by default, so that
//! `cargo test` works here out of the box) adds the `pc` module, which holds everything that needs
//! `UdpSocket` or threads to talk to a real HL2 from a PC.
//!
//! **Hard safety rules** (see `docs/ARCHITECTURE.md` and `docs/rawfront/SAFETY.md`): this crate
//! never sets the transmit key bit or any other transmit permission (no function here builds a
//! `TX_PERMIT` write, and `bridge::build_write_read` refuses one if it is attempted), never sets
//! the DAC to real output (register 0x31 bit 1, refused by
//! `pc::client::Hl2Client::write_command_register`), never flashes or reconfigures the HL2
//! gateware, and never writes the flash sector registers (no bridge write reaches `0x4003_0000`).
//! The one module that writes HL2 memory is `cpuload` (owner exception of 2026-11-20): it loads
//! the message-layer program into the CPU's RAM at 0x800, and for an update asks the boot ROM to
//! save exactly that image to the reserved program sector with the one console datagram
//! `cpuload::save_datagram_allowed` passes. Its bridge writes are limited to that RAM and four
//! CPU system registers (`cpuload::write_allowed`); it never sends the erase datagram.
//! Echo mode (register 0x31 bit 2) and the virtual DAC (bit 0 only) are allowed, because neither
//! drives the AD9866 transmit DAC or a PA or relay output.
#![cfg_attr(not(feature = "std"), no_std)]

pub mod bridge;
pub mod control;
pub mod cpuload;
pub mod dhcp;
pub mod filter;
pub mod msg;
pub mod protocol;

/// Simulated HL2 for tests (also for tests of no_std users through the feature `sim`).
#[cfg(any(test, feature = "std", feature = "sim"))]
pub mod sim;

#[cfg(feature = "std")]
pub mod pc;
