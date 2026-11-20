// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The USB descriptors of the board, and the descriptor ROM image the RTL serves them from. The
//! arrangement has a playback and a capture interface (16-bit).
//!
//! It is one full-speed configuration with three interfaces, all in one USB Audio Class 1.0
//! function (`docs/USB_AUDIO.md`, section 6):
//!
//! | Interface | What | Endpoints |
//! |---|---|---|
//! | 0 | AudioControl: USB streaming -> line connector (to the radio); line connector (from the radio) -> USB streaming | none |
//! | 1 | AudioStreaming, playback: alt 0 = off, alt 1 = 48 kHz, 2 channels, 16-bit PCM | 0x01 isochronous OUT, asynchronous; 0x81 isochronous IN, feedback |
//! | 2 | AudioStreaming, capture: alt 0 = off, alt 1 = the same format | 0x82 isochronous IN, asynchronous |
//!
//! Sources: chapter 9 (standard descriptors) and 5.12.4 (feedback) of the USB 2.0 specification,
//! and sections 4.3 to 4.6 of the USB Device Class Definition for Audio Devices 1.0 (UAC1) with
//! its Terminal Types and Data Formats companion documents.
//!
//! **ROM layout** (read by `rtl/usb/usb_ep0.v`): a directory of [`ROM_SLOTS`] slots of 4 bytes at
//! address 0 (`offset` as u16 little-endian, `length` as u16 little-endian, and a length of 0
//! means the descriptor is absent), followed by the descriptors. Slot 0 holds the device
//! descriptor, slot 1 the configuration descriptor (the whole hierarchy), and slots 2 and up hold
//! the string descriptors 0 and up (string 0 is the list of language IDs).

/// pid.codes vendor ID (open-source hardware; <https://pid.codes>).
pub const VID: u16 = 0x1209;
/// pid.codes test PID 0x0001. This is a placeholder: pid.codes reserves 0x0001 to 0x0010 for
/// testing and assigns free PIDs to open-source projects on request, so a copy of the design that
/// is built for other people should ask for its own.
pub const PID: u16 = 0x0001;
/// Device release number (BCD). Raise it whenever the interface layout changes (a later serial
/// port or MIDI): Windows remembers the layout per vendor, product and release.
pub const BCD_DEVICE: u16 = 0x0100;

/// Manufacturer string (string descriptor 1).
pub const MANUFACTURER: &str = "fpga-sdr";
/// Product string (string descriptor 2).
pub const PRODUCT: &str = "fpga-sdr transceiver";

/// Control endpoint max packet size. 64 is the largest allowed at full speed.
pub const EP0_MAX_PACKET: u8 = 64;

/// Endpoint number of the playback pair: isochronous OUT 0x01 (data) and IN 0x81 (feedback).
pub const EP_PLAY: u8 = 1;
/// Endpoint number of the isochronous capture IN endpoint (0x82).
pub const EP_CAP: u8 = 2;
/// Address of the playback data endpoint (isochronous OUT).
pub const EP_PLAY_OUT_ADDR: u8 = EP_PLAY;
/// Address of the playback feedback endpoint (isochronous IN).
pub const EP_PLAY_FB_ADDR: u8 = 0x80 | EP_PLAY;
/// Address of the capture endpoint (isochronous IN).
pub const EP_CAP_IN_ADDR: u8 = 0x80 | EP_CAP;
/// Endpoint number kept free for a MIDI port (`docs/USB_AUDIO.md`, section 6).
pub const EP_RESERVED_MIDI: u8 = 3;
/// Endpoint number kept free for the data of a serial port.
pub const EP_RESERVED_CDC_DATA: u8 = 4;
/// Endpoint number kept free for the notifications of a serial port.
pub const EP_RESERVED_CDC_NOTIFY: u8 = 5;

/// Interface number of the AudioControl interface.
pub const IF_AUDIO_CONTROL: u8 = 0;
/// Interface number of the playback AudioStreaming interface.
pub const IF_PLAY: u8 = 1;
/// Interface number of the capture AudioStreaming interface.
pub const IF_CAP: u8 = 2;
/// Number of interfaces in configuration 1.
pub const NUM_INTERFACES: u8 = 3;
/// `bConfigurationValue` of the one configuration.
pub const CONFIG_VALUE: u8 = 1;

/// Sample rate in Hz, in both directions.
pub const SAMPLE_RATE: u32 = 48_000;
/// Channels per stream (stereo).
pub const CHANNELS: u8 = 2;
/// Bytes per sample per channel (UAC1 bSubframeSize).
pub const SUBFRAME_BYTES: u8 = 2;
/// Bits per sample.
pub const BIT_RESOLUTION: u8 = 16;
/// Bytes per stereo sample frame on the wire.
pub const BYTES_PER_FRAME: u16 = CHANNELS as u16 * SUBFRAME_BYTES as u16;
/// Most samples in one 1 ms USB frame, either direction: 48 nominal, 49 when the sender's clock
/// has run slightly ahead (capture) or the feedback asks for more (playback).
pub const MAX_SAMPLES_PER_USB_FRAME: u16 = (SAMPLE_RATE / 1000) as u16 + 1;
/// Isochronous endpoint max packet size: 49 x 4 = 196 bytes (full-speed limit is 1023).
pub const AUDIO_MAX_PACKET: u16 = MAX_SAMPLES_PER_USB_FRAME * BYTES_PER_FRAME;
/// The feedback endpoint's packet: samples per frame in 10.14 fixed point, 3 bytes (USB 2.0 5.12.4.2).
pub const FEEDBACK_PACKET: u16 = 3;
/// The feedback endpoint's bRefresh: the PC asks every 2^3 = 8 ms. The RTL has a new value every frame.
pub const FEEDBACK_REFRESH: u8 = 3;

/// Terminal IDs. Playback: 1 (USB streaming) -> 2 (line connector, into the radio).
/// Capture: 3 (line connector, out of the radio) -> 4 (USB streaming).
pub const TERM_PLAY_USB: u8 = 1;
/// Terminal ID of the line connector that receives the playback stream.
pub const TERM_PLAY_LINE: u8 = 2;
/// Terminal ID of the line connector that supplies the capture stream.
pub const TERM_CAP_LINE: u8 = 3;
/// Terminal ID of the USB streaming terminal of the capture direction.
pub const TERM_CAP_USB: u8 = 4;
/// UAC1 terminal type 0x0101, USB streaming.
pub const TT_USB_STREAMING: u16 = 0x0101;
/// UAC1 terminal type 0x0603, "Line connector" (Terminal Types 1.0, table 2-5), which is what
/// class-compliant interfaces usually report. How each host names it has not been checked.
pub const TT_LINE: u16 = 0x0603;

/// ROM size in bytes (the RTL's `USB_ROM_SIZE`).
pub const ROM_SIZE: usize = 512;
/// Directory slots at the start of the ROM.
pub const ROM_SLOTS: usize = 8;
/// Offset of the first descriptor in the ROM.
pub const ROM_DATA_START: usize = ROM_SLOTS * 4;
/// String descriptors present (index 0 = language IDs, 1 = manufacturer, 2 = product).
pub const NUM_STRINGS: usize = 3;

// Descriptor type codes (USB 2.0 table 9-5, UAC1 table A-4).
pub const DT_DEVICE: u8 = 1;
pub const DT_CONFIGURATION: u8 = 2;
pub const DT_STRING: u8 = 3;
pub const DT_INTERFACE: u8 = 4;
pub const DT_ENDPOINT: u8 = 5;
pub const DT_CS_INTERFACE: u8 = 0x24;
pub const DT_CS_ENDPOINT: u8 = 0x25;

/// Little writer over a byte slice. Panics on overflow (only ever used with buffers sized for
/// the descriptors below; the tests check the sizes).
struct W<'a> {
    buf: &'a mut [u8],
    len: usize,
}

impl<'a> W<'a> {
    fn new(buf: &'a mut [u8]) -> Self {
        W { buf, len: 0 }
    }
    fn bytes(&mut self, b: &[u8]) {
        self.buf[self.len..self.len + b.len()].copy_from_slice(b);
        self.len += b.len();
    }
    fn u8(&mut self, v: u8) {
        self.bytes(&[v]);
    }
    fn u16(&mut self, v: u16) {
        self.bytes(&v.to_le_bytes());
    }
    fn u24(&mut self, v: u32) {
        self.bytes(&v.to_le_bytes()[..3]);
    }
    fn patch_u16(&mut self, at: usize, v: u16) {
        self.buf[at..at + 2].copy_from_slice(&v.to_le_bytes());
    }
}

/// Standard device descriptor (USB 2.0 table 9-8). bcdUSB 2.00 on a full-speed-only device is
/// allowed; such a device answers GET_DESCRIPTOR(DEVICE_QUALIFIER) with STALL (USB 2.0 9.6.2),
/// which the RTL does.
pub fn device_descriptor() -> [u8; 18] {
    let mut d = [0u8; 18];
    let mut w = W::new(&mut d);
    w.u8(18);
    w.u8(DT_DEVICE);
    w.u16(0x0200); // bcdUSB
    w.u8(0); // bDeviceClass: defined per interface
    w.u8(0);
    w.u8(0);
    w.u8(EP0_MAX_PACKET);
    w.u16(VID);
    w.u16(PID);
    w.u16(BCD_DEVICE);
    w.u8(1); // iManufacturer
    w.u8(2); // iProduct
    w.u8(0); // iSerialNumber: none
    w.u8(1); // bNumConfigurations
    d
}

/// Standard interface descriptor.
fn interface(w: &mut W, number: u8, alt: u8, endpoints: u8, subclass: u8) {
    w.bytes(&[9, DT_INTERFACE, number, alt, endpoints, 0x01 /* audio */, subclass, 0, 0]);
}

/// 9-byte endpoint descriptor (the audio-class form with bRefresh and bSynchAddress, UAC1
/// sections 4.6.1.1 and 4.6.2.1).
fn endpoint9(w: &mut W, addr: u8, attributes: u8, max_packet: u16, refresh: u8, synch: u8) {
    w.u8(9);
    w.u8(DT_ENDPOINT);
    w.u8(addr);
    w.u8(attributes);
    w.u16(max_packet);
    w.u8(1); // bInterval: every frame
    w.u8(refresh);
    w.u8(synch);
}

/// Input terminal (UAC1 table 4-3), stereo.
fn input_terminal(w: &mut W, id: u8, kind: u16) {
    w.bytes(&[12, DT_CS_INTERFACE, 0x02, id]);
    w.u16(kind);
    w.u8(0); // bAssocTerminal
    w.u8(CHANNELS);
    w.u16(0x0003); // wChannelConfig: left front, right front
    w.u8(0); // iChannelNames
    w.u8(0); // iTerminal
}

/// Output terminal (UAC1 table 4-4).
fn output_terminal(w: &mut W, id: u8, kind: u16, source: u8) {
    w.bytes(&[9, DT_CS_INTERFACE, 0x03, id]);
    w.u16(kind);
    w.u8(0); // bAssocTerminal
    w.u8(source);
    w.u8(0); // iTerminal
}

/// The class-specific part of an AudioStreaming alternate setting 1: AS general (UAC1 table
/// 4-19) and the Type I format with one discrete rate (Data Formats 1.0 table 2-1).
fn streaming_format(w: &mut W, terminal: u8) {
    w.bytes(&[7, DT_CS_INTERFACE, 0x01, terminal, 1 /* bDelay, frames */]);
    w.u16(0x0001); // wFormatTag: PCM
    w.bytes(&[11, DT_CS_INTERFACE, 0x02, 0x01, CHANNELS, SUBFRAME_BYTES, BIT_RESOLUTION, 1]);
    w.u24(SAMPLE_RATE);
}

/// The whole configuration descriptor hierarchy. Returns its length; `buf` must hold at least
/// [`CONFIG_TOTAL_LENGTH`] bytes.
pub fn config_descriptor(buf: &mut [u8]) -> usize {
    let mut w = W::new(buf);

    // Configuration (USB 2.0 table 9-10).
    w.u8(9);
    w.u8(DT_CONFIGURATION);
    w.u16(0); // wTotalLength, patched below
    w.u8(NUM_INTERFACES);
    w.u8(CONFIG_VALUE);
    w.u8(0); // iConfiguration
    // bmAttributes: bit 7 (always 1) + self-powered. The board has its own supply (docs/BOARD.md
    // "USB": the port cannot power the board).
    w.u8(0xC0);
    // bMaxPower in 2 mA units, 50 = 100 mA. What the board really draws from VBUS has not been measured.
    w.u8(50);

    // Interface 0: AudioControl (UAC1 4.3.1).
    interface(&mut w, IF_AUDIO_CONTROL, 0, 0, 0x01);
    // Class-specific AC header (UAC1 table 4-2): collection = interfaces 1 and 2.
    let ac_start = w.len;
    w.bytes(&[10, DT_CS_INTERFACE, 0x01]);
    w.u16(0x0100); // bcdADC 1.00
    let ac_total_at = w.len;
    w.u16(0); // wTotalLength, patched
    w.u8(2); // bInCollection
    w.u8(IF_PLAY);
    w.u8(IF_CAP);
    // Playback: the PC's stream -> the radio. No feature unit: the PC's own mixer does volume.
    input_terminal(&mut w, TERM_PLAY_USB, TT_USB_STREAMING);
    output_terminal(&mut w, TERM_PLAY_LINE, TT_LINE, TERM_PLAY_USB);
    // Capture: the radio -> the PC's stream.
    input_terminal(&mut w, TERM_CAP_LINE, TT_LINE);
    output_terminal(&mut w, TERM_CAP_USB, TT_USB_STREAMING, TERM_CAP_LINE);
    let ac_len = (w.len - ac_start) as u16;
    w.patch_u16(ac_total_at, ac_len);

    // Interface 1: playback. Alt 0 has no endpoint (zero bandwidth), alt 1 streams.
    interface(&mut w, IF_PLAY, 0, 0, 0x02);
    interface(&mut w, IF_PLAY, 1, 2, 0x02);
    streaming_format(&mut w, TERM_PLAY_USB);
    // Isochronous OUT, asynchronous (bmAttributes bits 3:2 = 01); its feedback endpoint is named
    // in bSynchAddress (UAC1 4.6.1.1).
    endpoint9(&mut w, EP_PLAY_OUT_ADDR, 0x05, AUDIO_MAX_PACKET, 0, EP_PLAY_FB_ADDR);
    // Class-specific iso endpoint (UAC1 table 4-21): no sampling-frequency control, no pitch
    // control, so hosts have no reason to send endpoint requests (the RTL still answers them).
    w.bytes(&[7, DT_CS_ENDPOINT, 0x01, 0x00, 0, 0, 0]);
    // Feedback: isochronous IN, no synchronization, usage "feedback" (USB 2.0 table 9-13: bits
    // 5:4 = 01; UAC1 was written for USB 1.1 and has 0x01 here). Whether Windows minds the usage
    // bits has not been checked.
    endpoint9(&mut w, EP_PLAY_FB_ADDR, 0x11, FEEDBACK_PACKET, FEEDBACK_REFRESH, 0);

    // Interface 2: capture.
    interface(&mut w, IF_CAP, 0, 0, 0x02);
    interface(&mut w, IF_CAP, 1, 1, 0x02);
    streaming_format(&mut w, TERM_CAP_USB);
    // Isochronous IN, asynchronous: the device sends as many samples as it made.
    endpoint9(&mut w, EP_CAP_IN_ADDR, 0x05, AUDIO_MAX_PACKET, 0, 0);
    w.bytes(&[7, DT_CS_ENDPOINT, 0x01, 0x00, 0, 0, 0]);

    let total = w.len;
    w.patch_u16(2, total as u16);
    total
}

/// Length of [`config_descriptor`]'s output.
pub const CONFIG_TOTAL_LENGTH: usize = 9 + (9 + 10 + 12 + 9 + 12 + 9) + (9 + 9 + 7 + 11 + 9 + 7 + 9) + (9 + 9 + 7 + 11 + 9 + 7);

/// String descriptor `index` (0 = language IDs) into `buf`. Returns its length, or `None` if the
/// string does not exist. Strings are ASCII, sent as UTF-16LE.
pub fn string_descriptor(index: usize, buf: &mut [u8]) -> Option<usize> {
    let s = match index {
        0 => {
            buf[..4].copy_from_slice(&[4, DT_STRING, 0x09, 0x04]); // en-US
            return Some(4);
        }
        1 => MANUFACTURER,
        2 => PRODUCT,
        _ => return None,
    };
    let len = 2 + 2 * s.len();
    buf[0] = len as u8;
    buf[1] = DT_STRING;
    for (i, c) in s.bytes().enumerate() {
        buf[2 + 2 * i] = c;
        buf[3 + 2 * i] = 0;
    }
    Some(len)
}

/// The descriptor ROM image served by the RTL (see the module doc for the layout).
pub fn build_rom() -> [u8; ROM_SIZE] {
    let mut rom = [0u8; ROM_SIZE];
    let mut at = ROM_DATA_START;
    let mut put = |rom: &mut [u8; ROM_SIZE], slot: usize, bytes: &[u8]| {
        rom[at..at + bytes.len()].copy_from_slice(bytes);
        rom[slot * 4..slot * 4 + 2].copy_from_slice(&(at as u16).to_le_bytes());
        rom[slot * 4 + 2..slot * 4 + 4].copy_from_slice(&(bytes.len() as u16).to_le_bytes());
        at += bytes.len();
    };
    put(&mut rom, 0, &device_descriptor());
    let mut cfg = [0u8; CONFIG_TOTAL_LENGTH];
    let n = config_descriptor(&mut cfg);
    put(&mut rom, 1, &cfg[..n]);
    for i in 0..NUM_STRINGS {
        let mut s = [0u8; 64];
        let n = string_descriptor(i, &mut s).expect("string exists");
        put(&mut rom, 2 + i, &s[..n]);
    }
    rom
}

/// Look a descriptor up in a ROM image the way `rtl/usb/usb_ep0.v` does. Returns the bytes, or
/// `None` where the RTL answers STALL.
pub fn rom_lookup(rom: &[u8; ROM_SIZE], desc_type: u8, index: u8) -> Option<&[u8]> {
    let slot = match desc_type {
        DT_DEVICE => 0,
        DT_CONFIGURATION if index == 0 => 1,
        DT_STRING if (index as usize) < ROM_SLOTS - 2 => 2 + index as usize,
        _ => return None,
    };
    let off = u16::from_le_bytes([rom[slot * 4], rom[slot * 4 + 1]]) as usize;
    let len = u16::from_le_bytes([rom[slot * 4 + 2], rom[slot * 4 + 3]]) as usize;
    if len == 0 {
        None
    } else {
        Some(&rom[off..off + len])
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::vec::Vec;

    fn cfg() -> Vec<u8> {
        let mut b = [0u8; 512];
        let n = config_descriptor(&mut b);
        b[..n].to_vec()
    }

    /// Split a descriptor hierarchy into its descriptors, checking every bLength.
    fn walk(bytes: &[u8]) -> Vec<&[u8]> {
        let mut out = Vec::new();
        let mut i = 0;
        while i < bytes.len() {
            let l = bytes[i] as usize;
            assert!(l >= 2 && i + l <= bytes.len(), "bad bLength at {i}");
            out.push(&bytes[i..i + l]);
            i += l;
        }
        out
    }

    #[test]
    fn config_total_length_matches() {
        let c = cfg();
        assert_eq!(c.len(), CONFIG_TOTAL_LENGTH);
        assert_eq!(c.len(), 183);
        assert_eq!(u16::from_le_bytes([c[2], c[3]]) as usize, c.len());
        assert_eq!(walk(&c).iter().map(|d| d.len()).sum::<usize>(), c.len());
    }

    #[test]
    fn interfaces_and_endpoints() {
        let c = cfg();
        let ds = walk(&c);
        // number, alternate setting, endpoints, subclass
        let ifaces: Vec<_> = ds.iter().filter(|d| d[1] == DT_INTERFACE).map(|d| (d[2], d[3], d[4], d[6])).collect();
        assert_eq!(ifaces, [(0, 0, 0, 1), (1, 0, 0, 2), (1, 1, 2, 2), (2, 0, 0, 2), (2, 1, 1, 2)]);
        // address, attributes, max packet, interval, refresh, synch address
        let eps: Vec<_> = ds
            .iter()
            .filter(|d| d[1] == DT_ENDPOINT)
            .map(|d| (d[2], d[3], u16::from_le_bytes([d[4], d[5]]), d[6], d[7], d[8]))
            .collect();
        assert_eq!(eps, [(0x01, 0x05, 196, 1, 0, 0x81), (0x81, 0x11, 3, 1, 3, 0), (0x82, 0x05, 196, 1, 0, 0)]);
        assert!(ds.iter().filter(|d| d[1] == DT_ENDPOINT).all(|d| d.len() == 9));
        assert_eq!(c[4], NUM_INTERFACES);
        // the endpoint numbers kept for later functions are not in use
        for e in eps {
            assert!(![EP_RESERVED_MIDI, EP_RESERVED_CDC_DATA, EP_RESERVED_CDC_NOTIFY].contains(&(e.0 & 0x0F)));
        }
    }

    #[test]
    fn audio_control_topology() {
        let c = cfg();
        let ds = walk(&c);
        let ac = ds.iter().position(|d| d[1] == DT_CS_INTERFACE && d[2] == 0x01 && d.len() == 10).unwrap();
        // wTotalLength = header + four terminals; the collection is interfaces 1 and 2
        assert_eq!(u16::from_le_bytes([ds[ac][5], ds[ac][6]]) as usize, 10 + 12 + 9 + 12 + 9);
        assert_eq!(&ds[ac][7..10], &[2, IF_PLAY, IF_CAP]);
        // input terminals: id, type; output terminals: id, type, source
        let its: Vec<_> = ds.iter().filter(|d| d[1] == DT_CS_INTERFACE && d[2] == 0x02 && d.len() == 12).map(|d| (d[3], u16::from_le_bytes([d[4], d[5]]))).collect();
        assert_eq!(its, [(1, 0x0101), (3, 0x0603)]);
        let ots: Vec<_> = ds.iter().filter(|d| d[1] == DT_CS_INTERFACE && d[2] == 0x03 && d.len() == 9).map(|d| (d[3], u16::from_le_bytes([d[4], d[5]]), d[7])).collect();
        assert_eq!(ots, [(2, 0x0603, 1), (4, 0x0101, 3)]);
        // each streaming interface is linked to its USB streaming terminal
        let links: Vec<u8> = ds.iter().filter(|d| d[1] == DT_CS_INTERFACE && d[2] == 0x01 && d.len() == 7).map(|d| d[3]).collect();
        assert_eq!(links, [TERM_PLAY_USB, TERM_CAP_USB]);
    }

    #[test]
    fn audio_format_and_bandwidth() {
        let c = cfg();
        let ds = walk(&c);
        let fmts: Vec<_> = ds.iter().filter(|d| d[1] == DT_CS_INTERFACE && d[2] == 0x02 && d.len() == 11).collect();
        assert_eq!(fmts.len(), 2);
        for fmt in fmts {
            assert_eq!(&fmt[3..8], &[1, 2, 2, 16, 1]);
            assert_eq!(fmt[8] as u32 | (fmt[9] as u32) << 8 | (fmt[10] as u32) << 16, 48_000);
        }
        // Full speed: all isochronous packets of one 1 ms frame together stay far below the bus's
        // 1,500 bytes per frame: 196 out + 3 feedback + 196 in.
        assert!(2 * AUDIO_MAX_PACKET + FEEDBACK_PACKET < 500);
        assert_eq!(SAMPLE_RATE * BYTES_PER_FRAME as u32 * 8, 1_536_000);
    }

    #[test]
    fn device_descriptor_fields() {
        let d = device_descriptor();
        assert_eq!(d[0], 18);
        assert_eq!(d[4], 0); // class per interface
        assert_eq!(d[7], 64);
        assert_eq!(u16::from_le_bytes([d[8], d[9]]), 0x1209);
        assert_eq!(d[17], 1);
    }

    #[test]
    fn strings() {
        let mut b = [0u8; 64];
        assert_eq!(string_descriptor(0, &mut b), Some(4));
        let n = string_descriptor(2, &mut b).unwrap();
        assert_eq!(n, 2 + 2 * PRODUCT.len());
        assert_eq!(b[2], b'f');
        assert_eq!(string_descriptor(3, &mut b), None);
    }

    #[test]
    fn rom_directory_and_lookup() {
        let rom = build_rom();
        assert_eq!(rom_lookup(&rom, DT_DEVICE, 0).unwrap(), &device_descriptor());
        assert_eq!(rom_lookup(&rom, DT_CONFIGURATION, 0).unwrap(), &cfg()[..]);
        let mut b = [0u8; 64];
        let n = string_descriptor(1, &mut b).unwrap();
        assert_eq!(rom_lookup(&rom, DT_STRING, 1).unwrap(), &b[..n]);
        assert!(rom_lookup(&rom, DT_STRING, 3).is_none());
        assert!(rom_lookup(&rom, DT_STRING, 200).is_none());
        assert!(rom_lookup(&rom, DT_CONFIGURATION, 1).is_none());
        assert!(rom_lookup(&rom, 6, 0).is_none()); // device qualifier: STALL on a full-speed device
        let end = (0..ROM_SLOTS)
            .map(|s| u16::from_le_bytes([rom[s * 4], rom[s * 4 + 1]]) as usize + u16::from_le_bytes([rom[s * 4 + 2], rom[s * 4 + 3]]) as usize)
            .max()
            .unwrap();
        // room left for a serial port's and a MIDI port's descriptors (about 66 + 65 + 16 bytes)
        assert!(end + 150 <= ROM_SIZE);
        std::println!("descriptor ROM: {end} of {ROM_SIZE} bytes used");
    }
}
