// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

#![no_std]

//! Drivers for the register blocks of the fabric and the DDR3 rings behind them, built on the
//! `RegisterSpace` of [`tr_regs`] and on [`mem::FabricMem`] of this crate (see also
//! `docs/P2_FT8_FW.md`). The crate is `no_std`, and its tests run on the host against
//! `mock::MockFabric`.
//!
//! The blocks and what each module drives:
//!
//! | Module | Block |
//! |---|---|
//! | [`system`] | id, build, interrupts, status, a monotonic clock from the 120 MHz cycle counter |
//! | [`hl2link`] | HL2 link settings, status, counters, safety byte, sample index; the CPU packet ring and transmit queue as `tr_net::rings::MacRings` |
//! | [`rxbank`] | receiver tuning and rate |
//! | [`backend`] | channel filter banks, per-receiver mode, S-meter, the 12 ksps audio ring |
//! | [`ft8fe`] | FT8 front end: the id only (the page is a stub in the chip) |
//! | [`tx`] | TX chain, TX baseband ring, the operator's TX permit |
//! | [`spectrum`] | full-band spectrum control |
//! | [`zoom`] | zoom receiver: center frequency, span, enable (absent in a chip built without it) |
//! | [`video`] | frame buffers, FPGA windows, palette, status |
//! | [`wfring`] | a waterfall the CPU writes into the compositor's ring (the FT8 screen's) |
//! | [`audio`] | audio ring, volume, digital outputs (`out_ctrl`, `out_status`) |
//! | [`sfp`] | transceiver of the two SFP+ cages: start-up, clock chip and module memories over I2C |
//! | [`n1`] | lane 0 (SFP0) PCS towards the HL2's copper module: line mode, negotiation, status |
//! | [`eth`] | the network unit on the RJ45 socket (the network page): frames, MDIO, PHY start-up; `MacRings` |
//! | [`blink`] | link to a second board on SFP1: sample stream, control words, counters |
//! | [`usb`] | USB audio device: status, the playback samples from the PC, monitor and loop-back, fault counters, peak meters |
//!
//! **The 10 us rule** (docs/MEM_1GB.md section 3): data the CPU writes for the logic to read (TX
//! ring, audio ring, frame buffer) stays in the DDR3 bridge for up to 5.1 us after the cache line
//! is written back. No public function here moves a pointer the logic follows; the functions that
//! write the data ([`tx::TxPath::push`], [`audio::AudioOut::push`], [`video::FrameBuffers::present`])
//! write the cache back, wait [`mem::BRIDGE_FLUSH_US`] and move the pointer themselves.

#[cfg(any(test, feature = "mock"))]
extern crate alloc;

pub mod audio;
pub mod backend;
pub mod blink;
pub mod eth;
pub mod ft8fe;
pub mod hl2link;
pub mod mem;
#[cfg(any(test, feature = "mock"))]
pub mod mock;
pub mod n1;
mod ring;
pub mod rxbank;
pub mod sfp;
pub mod spectrum;
pub mod system;
pub mod tx;
pub mod usb;
pub mod usbh;
pub mod video;
pub mod wfring;
pub mod zoom;

/// NCO phase increment of the receiver bank and the TX mixer: `round(f / 76.8e6 * 2^32)`.
pub fn phase_inc(freq_hz: u32) -> u32 {
    const FS: u64 = 76_800_000;
    ((((freq_hz as u64) << 32) + FS / 2) / FS) as u32
}

#[cfg(test)]
mod tests {
    #[test]
    fn phase_inc_values() {
        assert_eq!(super::phase_inc(0), 0);
        assert_eq!(super::phase_inc(19_200_000), 0x4000_0000);
        // 14.074 MHz: 14,074,000 / 76,800,000 * 2^32 = 787,075,126.6
        assert_eq!(super::phase_inc(14_074_000), 787_075_127);
    }
}
