// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

#![cfg_attr(not(test), no_std)]

//! `tr-station` (docs/P2_FT8_FW.md): the station logic of the firmware, FT8 first, with the LISTEN
//! and FreeDV screens beside it.
//!
//! - [`msg`]: what a decoded message says; the messages we send.
//! - [`qso`]: the standard contact as a state machine.
//! - [`station`]: slot timing, decode scheduling, TX slot choice, the operator's events, the
//!   screen's state. Produces [`station::Action`]s; touches no hardware.
//! - [`chipdec`]: FT8 decoding through the chip's front end (the FPGA's sync and candidate engines, scheduled per receiver).
//! - [`radio`]: carries those actions out on the `tr-fabric` drivers, fills the slot buffer from
//!   the back end's audio ring and feeds the TX ring.
//! - [`freedv`]: FreeDV 700D/700E receive: 12 kHz audio to 48 kHz speech in a queue (docs/FREEDV.md section 9).
//! - [`listen`]: the LISTEN screen: SSB, CW, AM, SAM and FM receive with free tuning (docs/LISTEN.md).
//! - [`waterfall`]: the software waterfall lines of the FT8 and FreeDV screens, computed from the receiver audio.
//! - [`rfagc`]: the RF AGC: the HL2's RX gain from the power of the whole band (docs/HL2_CONTROL.md).
//! - [`wflevel`]: the color level of the chip's zoom waterfall (docs/LISTEN.md section 8).
//! - [`fdvstation`]: the FreeDV screen's state and events.
//! - [`keys`]: the console keys of the FT8 and FreeDV screens.
//! - [`hl2session`] (on [`hl2net`]): everything the firmware says to the HL2 so that samples arrive.
//! - `selftest` (feature `selftest`): the whole chain against a simulated fabric that loops the TX
//!   ring back into the receiver's audio ring; run by a host test and by the QEMU image.

extern crate alloc;

pub mod chipdec;
pub mod fdvstation;
pub mod freedv;
pub mod hl2net;
pub mod hl2session;
pub mod keys;
pub mod listen;
pub mod msg;
pub mod qso;
pub mod radio;
pub mod rfagc;
#[cfg(feature = "selftest")]
pub mod selftest;
pub mod station;
pub mod waterfall;
pub mod wflevel;
