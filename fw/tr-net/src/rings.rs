// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The boundary between this crate's `smoltcp` glue and whatever actually moves Ethernet frames:
//! `tr-fabric`'s driver for the packet rings of the Ethernet units on the AE350 target, or
//! [`crate::device::mock::RingModel`] (a plain in-memory queue pair) in host tests. Neither side
//! needs to know about the other, because [`crate::device::RingDevice`] is generic over this trait alone.

/// One side of a full-duplex Ethernet link: a place to hand a frame to transmit, and a place to
/// pull the next received one from. There is no allocation: callers copy into and out of a
/// caller-owned buffer, which is the shape the byte-addressed ports of the packet rings in the
/// FPGA (n1_pkt_tx_ring.v and n1_pkt_rx_ring.v) have, so a `tr-fabric` implementation copies
/// between that memory and the buffer, one register-mapped word at a time on the real hardware.
pub trait MacRings {
    /// Maximum frame size this implementation can carry, in bytes. A frame is the content only,
    /// from the destination MAC through the last payload byte, without preamble, start-of-frame
    /// delimiter or FCS (the framing of gmii_mac_tx.v and gmii_mac_rx.v).
    const MTU: usize;

    /// `true` if a frame can be handed to [`transmit`](Self::transmit) right now, i.e. the transmit
    /// ring is not busy with a previous frame (`busy` and `tx_has_frame` of n1_pkt_tx_ring.v).
    fn can_transmit(&mut self) -> bool;

    /// Hand one frame to the transmit ring, with `frame.len() <= Self::MTU`. Returns `false` if the
    /// ring was not actually free; callers check [`can_transmit`](Self::can_transmit) first, and
    /// this is the fallback for the case where something else took the slot in between.
    fn transmit(&mut self, frame: &[u8]) -> bool;

    /// If a frame is waiting in the receive ring, copy it into `buf` and return its length;
    /// otherwise `None`. `buf` is at least `Self::MTU` bytes.
    fn receive(&mut self, buf: &mut [u8]) -> Option<usize>;
}
