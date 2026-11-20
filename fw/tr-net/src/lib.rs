// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

#![cfg_attr(not(feature = "std"), no_std)]

//! `tr-net`: the `no_std` network layer of the firmware, essentially the small amount of code that sits
//! between `smoltcp` (which does the TCP/IP work, so none of it is hand-rolled here) and the Ethernet
//! hardware on one side and the station logic on the other (docs/N1_SFP.md, docs/SFP_LINKS.md).
//!
//! - [`rings`]: [`rings::MacRings`], the trait a frame-moving driver implements (`tr-fabric` on the
//!   board, [`device::mock::RingModel`] in host tests).
//! - [`device`]: [`device::RingDevice`], a `smoltcp::phy::Device` over any [`rings::MacRings`].
//! - [`clock`]: [`clock::DisciplinedClock`], a monotonic clock plus an SNTP-learned offset. It does not
//!   step or slew anything, it keeps a running correction so `now_utc_us()` stays monotonic between
//!   the SNTP exchanges that refresh the correction.
//! - [`sntp`]: [`sntp::SntpClient`], which builds NTPv4 client (mode 3) requests and turns a server's
//!   reply into a [`clock::Correction`] with the standard four-timestamp offset formula.
//! - [`nettime`]: [`nettime::NetTime`], a DHCP client and an SNTP client on one `smoltcp` interface,
//!   polled from the firmware's main loop, plus a UDP service socket for the PC's mouse and keyboard.
//! - [`ident`]: the Ethernet address and the network name derived from the FPGA's factory ID.
//!
//! `std` is a default feature so that `cargo test` runs the host tests (`tests/dhcp_sntp.rs`) without
//! a cross toolchain. The firmware builds this crate with `default-features = false`, and none of the
//! modules need `std` or `alloc` in that case.

pub mod clock;
pub mod device;
pub mod ident;
pub mod nettime;
pub mod rings;
pub mod sntp;
