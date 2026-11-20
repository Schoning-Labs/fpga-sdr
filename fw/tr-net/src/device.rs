// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! [`RingDevice`]: a `smoltcp::phy::Device` over any [`crate::rings::MacRings`], which is the only
//! glue `smoltcp` needs to run over the packet rings of the FPGA (through `tr-fabric`'s driver) or
//! over an in-memory model (host tests, `tests/dhcp_sntp.rs`). Nothing is allocated: both the
//! receive and the transmit path copy through one fixed-size buffer of [`MTU`] bytes.

use crate::rings::MacRings;
use smoltcp::phy::{Device, DeviceCapabilities, Medium};
use smoltcp::time::Instant;

/// The frame size this device presents to `smoltcp`: 1500 bytes of payload plus the 14-byte
/// Ethernet header, rounded up to 1514. It matches the framing of gmii_mac_tx.v and
/// gmii_mac_rx.v, which carry the content only, without preamble, start-of-frame delimiter or FCS.
pub const MTU: usize = 1514;

/// The `smoltcp` device, borrowing the rings for as long as the interface is polled.
pub struct RingDevice<'a, R: MacRings> {
    rings: &'a mut R,
}

impl<'a, R: MacRings> RingDevice<'a, R> {
    /// Wraps `rings` for one `smoltcp` poll.
    pub fn new(rings: &'a mut R) -> Self {
        RingDevice { rings }
    }
}

/// A received frame, copied out of the ring so `smoltcp` can read it in place.
pub struct RxTok {
    buf: [u8; MTU],
    len: usize,
}

impl smoltcp::phy::RxToken for RxTok {
    fn consume<Res, F>(mut self, f: F) -> Res
    where
        F: FnOnce(&mut [u8]) -> Res,
    {
        f(&mut self.buf[..self.len])
    }
}

/// A permit to transmit one frame; the frame is built in a local buffer and handed to the ring when `smoltcp` is done.
pub struct TxTok<'a, R: MacRings> {
    rings: &'a mut R,
}

impl<'a, R: MacRings> smoltcp::phy::TxToken for TxTok<'a, R> {
    fn consume<Res, F>(self, len: usize, f: F) -> Res
    where
        F: FnOnce(&mut [u8]) -> Res,
    {
        let mut buf = [0u8; MTU];
        let res = f(&mut buf[..len]);
        self.rings.transmit(&buf[..len]);
        res
    }
}

impl<'a, R: MacRings> Device for RingDevice<'a, R> {
    type RxToken<'b> = RxTok where Self: 'b;
    type TxToken<'b> = TxTok<'b, R> where Self: 'b;

    fn receive(&mut self, _timestamp: Instant) -> Option<(Self::RxToken<'_>, Self::TxToken<'_>)> {
        let mut buf = [0u8; MTU];
        let len = self.rings.receive(&mut buf)?;
        Some((RxTok { buf, len }, TxTok { rings: self.rings }))
    }

    fn transmit(&mut self, _timestamp: Instant) -> Option<Self::TxToken<'_>> {
        if self.rings.can_transmit() {
            Some(TxTok { rings: self.rings })
        } else {
            None
        }
    }

    fn capabilities(&self) -> DeviceCapabilities {
        let mut caps = DeviceCapabilities::default();
        caps.max_transmission_unit = MTU;
        caps.medium = Medium::Ethernet;
        caps
    }
}

/// A plain in-memory pair of frame queues implementing [`MacRings`], so that `smoltcp` can be
/// tested on the host over a model of the rings. It is behind `feature = "std"` because it uses
/// `std::collections::VecDeque`; the `no_std` firmware build links `tr-fabric`'s real driver
/// instead. The two ends made by [`mock::RingModel::pair`] model a two-ended Ethernet segment
/// for `tests/dhcp_sntp.rs`.
#[cfg(feature = "std")]
pub mod mock {
    use super::MTU;
    use crate::rings::MacRings;
    use std::collections::VecDeque;
    use std::rc::Rc;
    use std::cell::RefCell;

    #[derive(Default)]
    struct Wire {
        frames: VecDeque<Vec<u8>>,
    }

    /// One end of an in-memory Ethernet segment. `tx` is this end's outgoing queue, which is the
    /// other end's `rx`, and the reverse (see [`RingModel::pair`]).
    pub struct RingModel {
        tx: Rc<RefCell<Wire>>,
        rx: Rc<RefCell<Wire>>,
    }

    impl RingModel {
        /// Two ends of one segment: what the first end transmits the second receives, and the reverse.
        pub fn pair() -> (RingModel, RingModel) {
            let w1 = Rc::new(RefCell::new(Wire::default()));
            let w2 = Rc::new(RefCell::new(Wire::default()));
            (
                RingModel { tx: w1.clone(), rx: w2.clone() },
                RingModel { tx: w2, rx: w1 },
            )
        }
    }

    impl MacRings for RingModel {
        const MTU: usize = MTU;

        fn can_transmit(&mut self) -> bool {
            true
        }

        fn transmit(&mut self, frame: &[u8]) -> bool {
            self.tx.borrow_mut().frames.push_back(frame.to_vec());
            true
        }

        fn receive(&mut self, buf: &mut [u8]) -> Option<usize> {
            let frame = self.rx.borrow_mut().frames.pop_front()?;
            let n = frame.len().min(buf.len());
            buf[..n].copy_from_slice(&frame[..n]);
            Some(n)
        }
    }
}
