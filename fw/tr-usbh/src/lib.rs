// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! USB host stack for the Pmod USB host board (docs/USB_HOST.md): a headset or simple sound card
//! (USB Audio Class 1.0), a mouse and a keyboard, on two ports, full and low speed, no hubs.
//!
//! The logic (`rtl/usbh`) keeps the frames going, does one transaction at a time and streams the
//! audio by itself. This crate is the rest: [`host::Host`] enumerates a device and sets it up,
//! [`desc`] reads its descriptors, [`hid`] turns reports into key and pointer events, and
//! [`resample::Resampler`] brings a microphone's rate to the radio's. No allocation.
#![no_std]

pub mod desc;
pub mod hid;
pub mod host;
pub mod resample;
