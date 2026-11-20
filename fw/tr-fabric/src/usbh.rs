// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! USB host (`hw/regmap/usbh.toml`, docs/USB_HOST.md): the register side of the two host ports on
//! the Pmod board. [`UsbHost`] is the [`tr_usbh::host::Bus`] the host stack (`fw/tr-usbh`) runs on,
//! plus the audio counters and the speech-source switch of the device page.
//!
//! Use: one [`tr_usbh::host::Host`], and in the main loop
//! `host.poll(&mut UsbHost::new(regs), now_ms, &mut |event| ...)` every few ms. Nothing here
//! transmits on the air: the microphone's samples only reach the CPU FIFO of `usb`.

use core::fmt;

use tr_regs::generated::{usb, usbh};
use tr_regs::RegisterSpace;
use tr_usbh::host::{AudioSetup, Bus, Kind, Mode, PortStatus};

/// The fabric interrupt line of the USB host, as a mask for `system::System::set_irq_enable` (line 13).
pub const IRQ_USBH: u32 = 1 << 13;

/// Audio counters; both wrap.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AudioStatus {
    /// Samples waiting in the speaker buffer, about 48 at the start of a frame.
    pub spk_fill: u8,
    /// Speaker samples dropped, buffer full.
    pub spk_overruns: u8,
    /// Microphone packets dropped for a checksum error.
    pub mic_bad_packets: u16,
}

/// Driver for the USB host page, the bus of the host stack.
pub struct UsbHost<'a, R: RegisterSpace> {
    regs: &'a R,
}

impl<'a, R: RegisterSpace> UsbHost<'a, R> {
    /// A driver on the register space `regs`.
    pub fn new(regs: &'a R) -> Self {
        UsbHost { regs }
    }

    /// True when the chip has the USB host block (an older bitstream reads 0 here).
    pub fn present(&self) -> bool {
        usbh::id::read(self.regs) == usbh::id::RESET
    }

    /// Which events raise interrupt line 13: a record waiting, a transaction done, a line change.
    pub fn set_irq(&self, rx: bool, done: bool, line: bool) {
        usbh::ctrl::modify(self.regs, |c| c.with_irq_rx(rx).with_irq_done(done).with_irq_line(line));
    }

    /// Reads the speaker fill and overrun counts and the microphone packet error count.
    pub fn audio_status(&self) -> AudioStatus {
        let s = usbh::audio_status::read(self.regs);
        AudioStatus { spk_fill: s.spk_fill() as u8, spk_overruns: s.spk_overruns() as u8, mic_bad_packets: s.mic_bad_packets() as u16 }
    }

    /// Microphone samples received since reset (wraps). Two readings a known time apart give the
    /// device's true rate.
    pub fn mic_count(&self) -> u32 {
        usbh::mic_count::read(self.regs)
    }

    /// The speech input (the CPU FIFO of the `usb` page, `tr_fabric::usb::UsbAudio::read`) takes the
    /// USB host's microphone (`true`) or the PC's playback (`false`).
    pub fn set_speech_from_mic(&self, mic: bool) {
        usb::ctrl::modify(self.regs, |c| c.with_speech_src(mic));
    }

    /// One line for a console.
    pub fn status_line(&self, out: &mut impl fmt::Write) -> fmt::Result {
        let a = self.audio_status();
        let spk = usbh::spk::read(self.regs);
        let mic = usbh::mic::read(self.regs);
        write!(out, "usbh:")?;
        for p in 0..2 {
            let s = usbh::port_status::read(self.regs, p);
            let c = usbh::port_ctrl::read(self.regs, p);
            let what = match (c.mode(), s.gone(), s.dp(), s.dn()) {
                (2, false, _, _) => {
                    if c.low_speed() {
                        "low speed"
                    } else {
                        "full speed"
                    }
                }
                (_, _, false, false) => "empty",
                _ => "device, not up",
            };
            write!(out, " port {} {}", p + 1, what)?;
        }
        if spk.enable() {
            write!(out, ", speaker on port {} fill {} dropped {}", spk.port() as u8 + 1, a.spk_fill, a.spk_overruns)?;
        }
        if mic.enable() {
            write!(out, ", microphone on port {} bad packets {}", mic.port() as u8 + 1, a.mic_bad_packets)?;
        }
        Ok(())
    }
}

impl<R: RegisterSpace> Bus for UsbHost<'_, R> {
    fn status(&mut self, port: usize) -> PortStatus {
        let s = usbh::port_status::read(self.regs, port as u32);
        PortStatus { dp: s.dp(), dn: s.dn(), gone: s.gone(), busy: s.busy(), result: s.result() as u8, slot_err: s.slot_err() as u8 }
    }

    fn set_port(&mut self, port: usize, mode: Mode, low_speed: bool, address: u8) {
        let v = usbh::port_ctrl::Value(0).with_mode(mode as u32).with_low_speed(low_speed).with_address(address as u32);
        usbh::port_ctrl::write(self.regs, port as u32, v);
    }

    fn start(&mut self, port: usize, kind: Kind, ep: u8, toggle: bool, data: &[u8], nak_limit: u8) {
        let data = if kind == Kind::In { &[][..] } else { &data[..data.len().min(64)] };
        for (i, w) in data.chunks(4).enumerate() {
            let mut b = [0u8; 4];
            b[..w.len()].copy_from_slice(w);
            let word = u32::from_le_bytes(b);
            if port == 0 {
                usbh::tx::write(self.regs, i as u32, word);
            } else {
                usbh::tx1::write(self.regs, i as u32, word);
            }
        }
        let v = usbh::xfer::Value(0)
            .with_kind(kind as u32)
            .with_ep(ep as u32)
            .with_toggle(toggle)
            .with_len(data.len() as u32)
            .with_nak_limit(nak_limit as u32);
        usbh::xfer::write(self.regs, port as u32, v);
    }

    fn pop_record(&mut self, port: usize, buf: &mut [u8]) -> Option<(u8, usize)> {
        let mut n = 0;
        // a record is at most 64 bytes and its end word; a longer run means the FIFO is out of step
        for _ in 0..80 {
            let w = usbh::rx_pop::read(self.regs, port as u32);
            if !w.valid() {
                return None;
            }
            if w.end() {
                return Some((w.data() as u8 & 3, n));
            }
            if n < buf.len() {
                buf[n] = w.data() as u8;
                n += 1;
            }
        }
        None
    }

    fn set_slot(&mut self, port: usize, slot: usize, poll: Option<(u8, u8)>) {
        let (on, ep, interval) = match poll {
            Some((ep, interval)) => (true, ep, interval.max(1)),
            None => (false, 0, 10),
        };
        if port == 0 {
            let v = usbh::slot::Value(0).with_enable(on).with_ep(ep as u32).with_interval(interval as u32);
            usbh::slot::write(self.regs, slot as u32, v);
        } else {
            let v = usbh::slot1::Value(0).with_enable(on).with_ep(ep as u32).with_interval(interval as u32);
            usbh::slot1::write(self.regs, slot as u32, v);
        }
    }

    fn set_speaker(&mut self, cfg: Option<AudioSetup>) {
        // the fields first, the enable after them: the logic reads them when the enable arrives
        let off = usbh::spk::read(self.regs).with_enable(false);
        usbh::spk::write(self.regs, off);
        if let Some(c) = cfg {
            let v = usbh::spk::Value(0)
                .with_port(c.port != 0)
                .with_ep(c.ep as u32)
                .with_mono(c.mono)
                .with_bytes3(c.bytes3)
                .with_max_samples(c.max_samples.clamp(1, 49) as u32);
            usbh::spk::write(self.regs, v);
            usbh::spk::write(self.regs, v.with_enable(true));
        }
    }

    fn set_mic(&mut self, cfg: Option<AudioSetup>) {
        let off = usbh::mic::read(self.regs).with_enable(false);
        usbh::mic::write(self.regs, off);
        if let Some(c) = cfg {
            let v = usbh::mic::Value(0).with_port(c.port != 0).with_ep(c.ep as u32).with_mono(c.mono).with_bytes3(c.bytes3);
            usbh::mic::write(self.regs, v);
            usbh::mic::write(self.regs, v.with_enable(true));
        }
    }

    fn swap(&self) -> bool {
        usbh::ctrl::read(self.regs).swap()
    }

    fn set_swap(&mut self, swap: bool) {
        usbh::ctrl::modify(self.regs, |c| c.with_swap(swap));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tr_regs::mock::MockRegisterSpace;

    #[test]
    fn register_words() {
        let regs = MockRegisterSpace::new(usbh::BASE);
        let mut h = UsbHost::new(&regs);
        h.set_port(1, Mode::Run, true, 5);
        assert_eq!(regs.read32(usbh::BASE + 0x200), 2 | 1 << 3 | 5 << 4);
        // a SETUP: the 8 bytes little-endian in two words of the port's send buffer, then the start word
        h.start(0, Kind::Setup, 0, false, &[0x80, 6, 0, 1, 0, 0, 18, 0], 50);
        assert_eq!(regs.read32(usbh::BASE + 0x140), 0x0100_0680);
        assert_eq!(regs.read32(usbh::BASE + 0x144), 0x0012_0000);
        assert_eq!(regs.read32(usbh::BASE + 0x108), 8 << 7 | 50 << 16);
        h.start(1, Kind::Out, 0, true, &[0x80, 0xBB, 0x00], 250);
        assert_eq!(regs.read32(usbh::BASE + 0x240), 0x0000_BB80);
        assert_eq!(regs.read32(usbh::BASE + 0x208), 1 | 1 << 6 | 3 << 7 | 250 << 16);
        h.start(1, Kind::In, 0, true, &[1, 2, 3], 0);
        assert_eq!(regs.read32(usbh::BASE + 0x208), 2 | 1 << 6);
        h.set_slot(0, 1, Some((3, 8)));
        assert_eq!(regs.read32(usbh::BASE + 0x114), 1 | 3 << 1 | 8 << 5);
        h.set_slot(1, 0, Some((1, 10)));
        assert_eq!(regs.read32(usbh::BASE + 0x210), 1 | 1 << 1 | 10 << 5);
        h.set_slot(1, 0, None);
        assert_eq!(regs.read32(usbh::BASE + 0x210) & 1, 0);
        h.set_speaker(Some(AudioSetup { port: 1, ep: 1, mono: true, bytes3: false, max_samples: 48 }));
        assert_eq!(regs.read32(usbh::BASE + 0x010), 1 | 1 << 1 | 1 << 2 | 1 << 6 | 48 << 8);
        h.set_mic(Some(AudioSetup { port: 0, ep: 2, mono: false, bytes3: true, max_samples: 0 }));
        assert_eq!(regs.read32(usbh::BASE + 0x014), 1 | 2 << 2 | 1 << 7);
        h.set_mic(None);
        assert_eq!(regs.read32(usbh::BASE + 0x014) & 1, 0);
        h.set_swap(true);
        assert!(h.swap());
        // status word: D- high, busy, result 3, slot 1 stopped
        regs.poke(usbh::BASE + 0x104, 0b10 | 1 << 3 | 3 << 4 | 2 << 10);
        let s = h.status(0);
        assert_eq!((s.dp, s.dn, s.gone, s.busy, s.result, s.slot_err), (false, true, false, true, 3, 2));
    }

    #[test]
    fn empty_fifo_and_speech_switch() {
        let regs = MockRegisterSpace::new(usbh::BASE);
        let mut h = UsbHost::new(&regs);
        let mut buf = [0u8; 64];
        assert_eq!(h.pop_record(0, &mut buf), None);
        // an end word alone: a record of no bytes from slot 1
        regs.poke(usbh::BASE + 0x20C, 1 << 31 | 1 << 8 | 2);
        assert_eq!(h.pop_record(1, &mut buf), Some((2, 0)));
        let regs = MockRegisterSpace::new(usb::BASE);
        UsbHost::new(&regs).set_speech_from_mic(true);
        assert_eq!(regs.read32(usb::BASE + 4) & 0x10, 0x10);
    }
}
