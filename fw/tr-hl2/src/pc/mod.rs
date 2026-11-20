// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! PC-side networking (feature `std`): everything that needs `UdpSocket` and threads. The `no_std`
//! core (`protocol`, `bridge`, `filter`, `dhcp`) knows nothing about sockets, and this module is
//! the only place where `tr-hl2` opens one.
//!
//! Hard safety rules enforced here (see `docs/rawfront/SAFETY.md`): no function in this module or
//! its submodules sends a `TX_PERMIT` write (the bridge module refuses to even build the packet),
//! sets the real-DAC bit (register 0x31 bit 1, refused by
//! `client::Hl2Client::write_command_register`), or writes the flash-sector interface of the
//! front-end register block. Echo mode (register 0x31 bit 2) and the virtual DAC are allowed,
//! because neither drives the AD9866 transmit DAC or a PA or relay output.

pub mod bridge_client;
pub mod capture;
pub mod client;
pub mod discover;
pub mod goertzel;
pub mod socket;

pub use bridge_client::BridgeClient;
pub use capture::{CaptureOptions, CaptureStats};
pub use client::Hl2Client;
pub use discover::Discovered;
// Note: `discover::discover` (the function) is deliberately not re-exported at this level --
// `pc::discover` already names the `discover` submodule, and `pc::discover::discover(...)` /
// `pc::discover::mac_string(...)` reads clearly enough without a second, shadowing meaning for
// the same path segment.
