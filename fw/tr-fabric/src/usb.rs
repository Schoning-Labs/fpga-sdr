// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! USB audio device (`hw/regmap/usb.toml`, docs/USB_AUDIO.md): the board as a class-compliant USB
//! sound card, 48 kHz 16-bit stereo both ways. The logic enumerates and streams without firmware.
//! This driver reads the state, takes the PC's playback samples out of the CPU FIFO (the speech
//! and transmit-audio source), sets the monitor and loop-back switches and reads the fault
//! counters and peak meters.
//!
//! Nothing here transmits: [`UsbAudio::read`] only hands the samples to the caller.

use core::fmt;

use tr_regs::generated::usb;
use tr_regs::RegisterSpace;

pub const USB_AUDIO_RATE: u32 = 48_000;
/// Depth of the CPU FIFO in stereo samples (21 ms).
pub const FIFO_SAMPLES: u32 = 1_024;
/// The fabric interrupt line of the CPU FIFO's high-water mark, as a mask for
/// `system::System::set_irq_enable` (line 12).
pub const IRQ_FIFO: u32 = 1 << 12;

/// One stereo sample from the PC.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Stereo {
    pub left: i16,
    pub right: i16,
}

impl Stereo {
    /// From a `fifo_data` word: left in bits 15:0, right in bits 31:16.
    pub const fn from_word(w: u32) -> Self {
        Stereo { left: w as u16 as i16, right: (w >> 16) as u16 as i16 }
    }
    /// Both channels as one: (left + right) / 2.
    pub const fn mono(self) -> i16 {
        ((self.left as i32 + self.right as i32) >> 1) as i16
    }
}

/// `status` as read.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Status {
    /// A PC has enumerated and configured the device.
    pub configured: bool,
    /// The PC is playing to the radio (possibly silence).
    pub play_on: bool,
    /// The PC is recording from the radio.
    pub cap_on: bool,
    /// The playback reader is taking samples (false: start, or after an under-run).
    pub play_run: bool,
    /// Samples in the buffer between USB and the radio, 0 to 256.
    pub play_fill: u16,
}

/// The five fault counters. Each wraps at 65,535; use [`Faults::since`] for a difference.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Faults {
    /// Playback buffer ran empty while the PC was playing.
    pub underruns: u16,
    /// Playback samples dropped, buffer full.
    pub overruns: u16,
    /// Recording samples dropped, the PC did not fetch them.
    pub cap_overruns: u16,
    /// Playback samples dropped at the CPU FIFO, the firmware did not read them.
    pub fifo_overruns: u16,
    /// Playback packets dropped for a checksum error.
    pub bad_packets: u16,
}

impl Faults {
    /// The counts added since `earlier` (right across a wrap).
    pub fn since(self, earlier: Faults) -> Faults {
        Faults {
            underruns: self.underruns.wrapping_sub(earlier.underruns),
            overruns: self.overruns.wrapping_sub(earlier.overruns),
            cap_overruns: self.cap_overruns.wrapping_sub(earlier.cap_overruns),
            fifo_overruns: self.fifo_overruns.wrapping_sub(earlier.fifo_overruns),
            bad_packets: self.bad_packets.wrapping_sub(earlier.bad_packets),
        }
    }
    /// True if any fault counter is not zero.
    pub fn any(self) -> bool {
        self != Faults::default()
    }
}

/// Peak meters since the last read, 0 to 32,767.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Peaks {
    /// PC to radio.
    pub play: u16,
    /// What the PC records.
    pub capture: u16,
}

/// A peak in whole dB below full scale, rounded (0 = full scale, 90 = one count or silence).
pub fn peak_dbfs(peak: u16) -> u8 {
    // thr is full scale less db - 0.5 dB, in 1/65536 counts; one step is 10^(-1/20) = 58,409 / 65,536
    let p = (peak as u64) << 16;
    let mut thr: u64 = (32_768u64 << 16) * 61_870 >> 16; // -0.5 dB
    for db in 0..90u8 {
        if p >= thr {
            return db;
        }
        thr = thr * 58_409 >> 16;
    }
    90
}

/// Driver for the USB audio device page.
pub struct UsbAudio<'a, R: RegisterSpace> {
    regs: &'a R,
}

impl<'a, R: RegisterSpace> UsbAudio<'a, R> {
    /// Leaves the device as it is: it may already be enumerated and streaming.
    pub fn new(regs: &'a R) -> Self {
        UsbAudio { regs }
    }

    /// The identification register of the block.
    pub fn id(&self) -> u32 {
        usb::id::read(self.regs)
    }

    /// True when the chip has the USB audio block (an older bitstream reads 0 here).
    pub fn present(&self) -> bool {
        self.id() == usb::id::RESET
    }

    /// Reads the device state: configured, playback and capture on, playback running, and the playback fill.
    pub fn status(&self) -> Status {
        let s = usb::status::read(self.regs);
        Status { configured: s.configured(), play_on: s.play_on(), cap_on: s.cap_on(), play_run: s.play_run(), play_fill: s.play_fill() as u16 }
    }

    /// The pull-up on D+. Off and, 10 ms or more later, on again makes the PC enumerate again.
    pub fn set_connected(&self, on: bool) {
        usb::ctrl::modify(self.regs, |c| c.with_connect(on));
    }

    /// Starts or stops storing the PC's playback in the CPU FIFO. `mark` (1 to 1,024 samples) is
    /// the fill at which interrupt line 12 ([`IRQ_FIFO`]) goes high. Stopping empties the FIFO.
    pub fn set_fifo(&self, on: bool, mark: u32) {
        usb::ctrl::modify(self.regs, |c| c.with_fifo_en(false));
        if on {
            usb::fifo_mark::write(self.regs, mark.clamp(1, FIFO_SAMPLES));
            usb::ctrl::modify(self.regs, |c| c.with_fifo_en(true));
        }
    }

    /// The PC's playback on the digital outputs (HDMI, S/PDIF, I2S), added to the receiver audio.
    pub fn set_monitor(&self, on: bool) {
        usb::ctrl::modify(self.regs, |c| c.with_monitor(on));
    }

    /// The PC records its own playback instead of the receiver audio (a test).
    pub fn set_loopback(&self, on: bool) {
        usb::ctrl::modify(self.regs, |c| c.with_loopback(on));
    }

    /// Stereo samples waiting in the CPU FIFO.
    pub fn fifo_level(&self) -> u32 {
        usb::fifo_level::read(self.regs)
    }

    /// Takes up to `out.len()` samples out of the CPU FIFO, oldest first, and returns how many.
    /// One register read for the level and one per sample.
    pub fn read(&self, out: &mut [Stereo]) -> usize {
        let n = (self.fifo_level() as usize).min(out.len());
        for s in out[..n].iter_mut() {
            *s = Stereo::from_word(usb::fifo_data::read(self.regs));
        }
        n
    }

    /// As [`Self::read`], both channels made one.
    pub fn read_mono(&self, out: &mut [i16]) -> usize {
        let n = (self.fifo_level() as usize).min(out.len());
        for s in out[..n].iter_mut() {
            *s = Stereo::from_word(usb::fifo_data::read(self.regs)).mono();
        }
        n
    }

    /// Reads the fault counters.
    pub fn faults(&self) -> Faults {
        let p = usb::play_errors::read(self.regs);
        let m = usb::more_errors::read(self.regs);
        Faults {
            underruns: p.underruns() as u16,
            overruns: p.overruns() as u16,
            cap_overruns: m.cap_overruns() as u16,
            fifo_overruns: m.fifo_overruns() as u16,
            bad_packets: usb::play_bad::read(self.regs) as u16,
        }
    }

    /// The peak meters since the last call; the read clears them.
    pub fn take_peaks(&self) -> Peaks {
        let l = usb::levels::read(self.regs);
        Peaks { play: l.play_peak() as u16, capture: l.cap_peak() as u16 }
    }

    /// One status line for the console, for example
    /// `usb: pc play+rec fill 74 play -12 dB rec -20 dB faults 0/0/0/0/0`
    /// (faults: under-runs, playback over-runs, recording over-runs, CPU FIFO over-runs, bad
    /// packets). Reading it clears the peak meters.
    pub fn status_line(&self, w: &mut impl fmt::Write) -> fmt::Result {
        if !self.present() {
            return w.write_str("usb: not in this chip");
        }
        let s = self.status();
        if !s.configured {
            return w.write_str("usb: no pc");
        }
        let what = match (s.play_on, s.cap_on) {
            (true, true) => "play+rec",
            (true, false) => "play",
            (false, true) => "rec",
            (false, false) => "idle",
        };
        let p = self.take_peaks();
        let f = self.faults();
        write!(
            w,
            "usb: pc {} fill {} play -{} dB rec -{} dB faults {}/{}/{}/{}/{}",
            what,
            s.play_fill,
            peak_dbfs(p.play),
            peak_dbfs(p.capture),
            f.underruns,
            f.overruns,
            f.cap_overruns,
            f.fifo_overruns,
            f.bad_packets
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mock::MockFabric;
    use alloc::collections::VecDeque;
    use alloc::string::String;
    use core::cell::RefCell;

    /// The CPU FIFO as the logic behaves: `fifo_data` takes a word out, `fifo_level` counts them.
    /// Every other register is a cell of a [`MockFabric`].
    struct Fifo {
        f: MockFabric,
        q: RefCell<VecDeque<u32>>,
    }
    impl RegisterSpace for Fifo {
        fn read32(&self, addr: u32) -> u32 {
            if addr == usb::fifo_data::addr() {
                self.q.borrow_mut().pop_front().unwrap_or(0)
            } else if addr == usb::fifo_level::addr() {
                self.q.borrow().len() as u32
            } else {
                self.f.read32(addr)
            }
        }
        fn write32(&self, addr: u32, value: u32) {
            self.f.write32(addr, value)
        }
    }

    #[test]
    fn switches_keep_each_other() {
        let f = MockFabric::new();
        f.poke(usb::ctrl::addr(), usb::ctrl::RESET);
        let u = UsbAudio::new(&f);
        u.set_fifo(true, 5_000);
        assert_eq!(f.reg(usb::fifo_mark::addr()), 1_024);
        assert_eq!(f.reg(usb::ctrl::addr()), 0b0011);
        u.set_monitor(true);
        u.set_loopback(true);
        assert_eq!(f.reg(usb::ctrl::addr()), 0b1111);
        u.set_connected(false);
        u.set_monitor(false);
        assert_eq!(f.reg(usb::ctrl::addr()), 0b1010);
        // the mark is written while the FIFO is off, so no interrupt at the old mark
        u.set_fifo(true, 256);
        let w = f.reg_writes(usb::ctrl::addr());
        assert_eq!(&w[w.len() - 2..], &[0b1000, 0b1010]);
        assert_eq!(f.reg(usb::fifo_mark::addr()), 256);
        u.set_fifo(false, 0);
        assert_eq!(f.reg(usb::ctrl::addr()), 0b1000);
    }

    #[test]
    fn status_and_presence() {
        let f = MockFabric::new();
        let u = UsbAudio::new(&f);
        assert!(!u.present());
        f.poke(usb::id::addr(), 0x5553_0001);
        assert!(u.present());
        f.poke(usb::status::addr(), 0b1011 | (74 << 16));
        assert_eq!(u.status(), Status { configured: true, play_on: true, cap_on: false, play_run: true, play_fill: 74 });
    }

    #[test]
    fn fifo_reader_takes_what_is_there() {
        let d = Fifo { f: MockFabric::new(), q: RefCell::new(VecDeque::new()) };
        let u = UsbAudio::new(&d);
        let mut buf = [Stereo::default(); 4];
        assert_eq!(u.read(&mut buf), 0);
        // left 1, 2, ... ; right = -left
        for k in 1..=6i16 {
            d.q.borrow_mut().push_back((k as u16 as u32) | ((-k) as u16 as u32) << 16);
        }
        assert_eq!(u.fifo_level(), 6);
        assert_eq!(u.read(&mut buf), 4);
        assert_eq!(buf[0], Stereo { left: 1, right: -1 });
        assert_eq!(buf[3], Stereo { left: 4, right: -4 });
        assert_eq!(u.read(&mut buf), 2);
        assert_eq!(buf[1], Stereo { left: 6, right: -6 });
        assert_eq!(u.read(&mut buf), 0);
        // mono: (left + right) / 2
        d.q.borrow_mut().push_back(1_000 | (3_000 << 16));
        d.q.borrow_mut().push_back(0x8000 | (0x8000 << 16));
        let mut m = [0i16; 8];
        assert_eq!(u.read_mono(&mut m), 2);
        assert_eq!(&m[..2], &[2_000, -32_768]);
    }

    #[test]
    fn faults_and_peaks() {
        let f = MockFabric::new();
        let u = UsbAudio::new(&f);
        f.poke(usb::play_errors::addr(), 3 | (7 << 16));
        f.poke(usb::more_errors::addr(), 11 | (13 << 16));
        f.poke(usb::play_bad::addr(), 2);
        let a = u.faults();
        assert_eq!(a, Faults { underruns: 3, overruns: 7, cap_overruns: 11, fifo_overruns: 13, bad_packets: 2 });
        assert!(a.any());
        // a counter that wrapped
        f.poke(usb::play_errors::addr(), 1 | (7 << 16));
        let d = u.faults().since(Faults { underruns: 65_535, ..a });
        assert_eq!(d, Faults { underruns: 2, ..Faults::default() });
        f.poke(usb::levels::addr(), 8_191 | (32_767 << 16));
        assert_eq!(u.take_peaks(), Peaks { play: 8_191, capture: 32_767 });
    }

    #[test]
    fn peak_in_db() {
        assert_eq!(peak_dbfs(32_767), 0);
        assert_eq!(peak_dbfs(16_384), 6);
        assert_eq!(peak_dbfs(8_191), 12);
        assert_eq!(peak_dbfs(3_277), 20); // 0.1 of full scale
        assert_eq!(peak_dbfs(1), 90);
        assert_eq!(peak_dbfs(0), 90);
        // never more than 0.6 dB from the true value
        for p in [100u16, 1_000, 5_000, 12_000, 23_000, 30_000] {
            let exact = 20.0 * libm_log10(32_768.0 / p as f64);
            assert!((peak_dbfs(p) as f64 - exact).abs() <= 0.6, "{p}: {} against {exact}", peak_dbfs(p));
        }
    }
    fn libm_log10(x: f64) -> f64 {
        extern crate std;
        std::primitive::f64::log10(x)
    }

    #[test]
    fn status_line_text() {
        let f = MockFabric::new();
        let u = UsbAudio::new(&f);
        let mut s = String::new();
        u.status_line(&mut s).unwrap();
        assert_eq!(s, "usb: not in this chip");
        f.poke(usb::id::addr(), 0x5553_0001);
        s.clear();
        u.status_line(&mut s).unwrap();
        assert_eq!(s, "usb: no pc");
        f.poke(usb::status::addr(), 0b1111 | (74 << 16));
        f.poke(usb::levels::addr(), 8_191 | (3_277 << 16));
        f.poke(usb::play_errors::addr(), 1);
        s.clear();
        u.status_line(&mut s).unwrap();
        assert_eq!(s, "usb: pc play+rec fill 74 play -12 dB rec -20 dB faults 1/0/0/0/0");
    }
}
