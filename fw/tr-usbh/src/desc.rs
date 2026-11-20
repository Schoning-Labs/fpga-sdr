// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Descriptor parser: the device descriptor, and from a configuration descriptor the things this
//! host can use: HID interfaces (keyboard, mouse), class 1.0 audio streaming formats with their
//! endpoints, and the mute controls on the way to the speaker and from the microphone.
//!
//! USB 2.0 chapter 9; USB Audio 1.0 section 4 and Data Formats 2.2; HID 1.11 section 6.2.

/// Descriptor types.
pub const DT_DEVICE: u8 = 1;
pub const DT_CONFIG: u8 = 2;
pub const DT_INTERFACE: u8 = 4;
pub const DT_ENDPOINT: u8 = 5;
pub const DT_HID: u8 = 0x21;
pub const DT_REPORT: u8 = 0x22;
pub const DT_CS_INTERFACE: u8 = 0x24;
pub const DT_CS_ENDPOINT: u8 = 0x25;

/// Interface class of audio devices.
pub const CLASS_AUDIO: u8 = 1;
/// Interface class of human interface devices (keyboard, mouse).
pub const CLASS_HID: u8 = 3;
/// Device class of hubs.
pub const CLASS_HUB: u8 = 9;

/// The fields of the device descriptor that the host uses.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct DeviceDesc {
    /// USB version in BCD (0x0200 for USB 2.0).
    pub usb_bcd: u16,
    /// Device class, 0 when it is given per interface.
    pub class: u8,
    /// Maximum packet size of endpoint 0, in bytes.
    pub max_packet0: u8,
    /// Vendor ID.
    pub vendor: u16,
    /// Product ID.
    pub product: u16,
    /// Number of configurations.
    pub configurations: u8,
}

/// The first 8 bytes are enough for `max_packet0`; the rest reads 0 then.
pub fn parse_device(d: &[u8]) -> Option<DeviceDesc> {
    if d.len() < 8 || d[1] != DT_DEVICE {
        return None;
    }
    let w = |i: usize| if d.len() > i + 1 { u16::from_le_bytes([d[i], d[i + 1]]) } else { 0 };
    let mp = d[7];
    if !matches!(mp, 8 | 16 | 32 | 64) {
        return None;
    }
    Some(DeviceDesc {
        usb_bcd: w(2),
        class: d[4],
        max_packet0: mp,
        vendor: w(8),
        product: w(10),
        configurations: if d.len() > 17 { d[17] } else { 0 },
    })
}

/// One HID interface with its interrupt IN endpoint.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct HidIface {
    /// Interface number.
    pub iface: u8,
    /// Interface subclass 1: the device can do the boot protocol.
    pub boot: bool,
    /// Interface protocol: 1 keyboard, 2 mouse, 0 neither.
    pub protocol: u8,
    /// Endpoint number of the interrupt IN endpoint, without the direction bit.
    pub ep: u8,
    /// Polling interval in milliseconds.
    pub interval_ms: u8,
    /// Maximum packet size of the endpoint, in bytes.
    pub max_packet: u16,
    /// Length of the report descriptor in bytes, 0 if the interface has none.
    pub report_len: u16,
}

/// One usable alternate setting of an audio streaming interface.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AudioAlt {
    /// Interface number of the AudioStreaming interface.
    pub iface: u8,
    /// Alternate setting number.
    pub alt: u8,
    /// Endpoint number, without the direction bit.
    pub ep: u8,
    /// Number of channels.
    pub channels: u8,
    /// Bytes per sample (2 or 3).
    pub subframe: u8,
    /// Bits per sample that are used.
    pub bits: u8,
    /// The rate chosen from the ones this setting offers.
    pub rate: u32,
    /// Maximum packet size of the endpoint, in bytes.
    pub max_packet: u16,
    /// Synchronization type of the endpoint: 1 asynchronous, 2 adaptive, 3 synchronous.
    pub sync: u8,
    /// The endpoint has a sampling-frequency control (the rate must be set).
    pub freq_control: bool,
}

/// A feature unit with a mute control on its master channel.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Mute {
    /// Unit ID of the feature unit.
    pub unit: u8,
    /// Interface number of the AudioControl interface that the requests go to.
    pub control_iface: u8,
}

/// Most HID interfaces of one configuration that are kept.
pub const MAX_HID: usize = 4;

/// What the host found in a configuration descriptor and can use.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Config {
    /// `bConfigurationValue`, the number that selects this configuration.
    pub value: u8,
    /// Total length of the configuration descriptor in bytes.
    pub total_len: u16,
    /// The HID interfaces (keyboard, mouse).
    pub hid: [Option<HidIface>; MAX_HID],
    /// Best setting for the radio's 48 kHz stream to the device, if it has one.
    pub speaker: Option<AudioAlt>,
    /// Best setting for the microphone, if it has one.
    pub mic: Option<AudioAlt>,
    /// Mute control on the way to the speaker.
    pub speaker_mute: Option<Mute>,
    /// Mute control on the way from the microphone.
    pub mic_mute: Option<Mute>,
    /// The device has an audio function at all.
    pub audio: bool,
    /// An audio interface says class 2.0 (interface protocol 0x20): not supported.
    pub audio2: bool,
    /// It has playback, but no setting does 48 kHz with 1 or 2 channels of 16 or 24 bits.
    pub speaker_unusable: bool,
}

/// Walks the descriptors of a configuration: (type, bytes of the whole descriptor).
pub struct Walk<'a> {
    d: &'a [u8],
}

/// Starts walking the descriptors in `d`.
pub fn walk(d: &[u8]) -> Walk<'_> {
    Walk { d }
}

impl<'a> Iterator for Walk<'a> {
    type Item = (u8, &'a [u8]);
    fn next(&mut self) -> Option<Self::Item> {
        if self.d.len() < 2 {
            return None;
        }
        let n = self.d[0] as usize;
        if n < 2 || n > self.d.len() {
            self.d = &[];
            return None;
        }
        let (one, rest) = self.d.split_at(n);
        self.d = rest;
        Some((one[1], one))
    }
}

/// Microphone rates in the order they are wanted (docs/USB_HOST.md section 5).
const MIC_RATES: [u32; 7] = [48_000, 44_100, 32_000, 16_000, 8_000, 22_050, 11_025];

fn score_format(channels: u8, subframe: u8, bits: u8, speaker: bool) -> u32 {
    let width = match (subframe, bits) {
        (2, 16) => 4,
        (3, 24) => 2,
        (2, 9..=15) | (3, 17..=23) => 1,
        _ => return 0,
    };
    let ch = match (channels, speaker) {
        (2, true) | (1, false) => 2,
        (1, true) | (2, false) => 1,
        _ => return 0,
    };
    width * 4 + ch
}

#[derive(Clone, Copy, Default)]
struct Unit {
    id: u8,
    /// 2 input terminal, 3 output terminal, 6 feature unit, other: passed through.
    kind: u8,
    source: u8,
    terminal_type: u16,
    mute: bool,
}

/// `d`: the whole configuration descriptor (shorter is fine: what is there is used).
pub fn parse_config(d: &[u8]) -> Option<Config> {
    if d.len() < 9 || d[1] != DT_CONFIG {
        return None;
    }
    let mut c = Config { value: d[5], total_len: u16::from_le_bytes([d[2], d[3]]), ..Config::default() };
    let mut units = [Unit::default(); 24];
    let mut n_units = 0;
    let mut ac_iface = 0u8;

    // the interface being read
    let (mut if_num, mut if_alt, mut if_class, mut if_sub, mut if_proto) = (0u8, 0u8, 0u8, 0u8, 0u8);
    let mut hid_len = 0u16;
    let mut n_hid = 0;
    // the audio format of this alternate setting, until its endpoint comes
    let mut fmt: Option<(u8, u8, u8)> = None;
    let mut rates = [0u32; 12];
    let mut n_rates = 0usize;
    let mut range: Option<(u32, u32)> = None;
    let mut pcm = false;
    // candidate endpoint waiting for its class-specific descriptor
    let mut pending: Option<(AudioAlt, bool, u32)> = None;
    let (mut best_spk, mut best_mic) = (0u32, 0u32);
    let mut had_playback = false;

    let flush = |pending: &mut Option<(AudioAlt, bool, u32)>, c: &mut Config, best_spk: &mut u32, best_mic: &mut u32| {
        if let Some((alt, out, score)) = pending.take() {
            if out {
                if score > *best_spk {
                    *best_spk = score;
                    c.speaker = Some(alt);
                }
            } else if score > *best_mic {
                *best_mic = score;
                c.mic = Some(alt);
            }
        }
    };

    for (ty, b) in walk(d) {
        match ty {
            DT_INTERFACE if b.len() >= 9 => {
                flush(&mut pending, &mut c, &mut best_spk, &mut best_mic);
                if_num = b[2];
                if_alt = b[3];
                if_class = b[5];
                if_sub = b[6];
                if_proto = b[7];
                hid_len = 0;
                fmt = None;
                n_rates = 0;
                range = None;
                pcm = false;
                if if_class == CLASS_AUDIO {
                    c.audio = true;
                    if if_proto == 0x20 {
                        c.audio2 = true;
                    }
                    if if_sub == 1 {
                        ac_iface = if_num;
                    }
                }
            }
            DT_HID if if_class == CLASS_HID && b.len() >= 9 => {
                // the report descriptor's length: the first class descriptor of type 0x22
                let n = b[5] as usize;
                for i in 0..n {
                    let o = 6 + 3 * i;
                    if b.len() >= o + 3 && b[o] == DT_REPORT {
                        hid_len = u16::from_le_bytes([b[o + 1], b[o + 2]]);
                        break;
                    }
                }
            }
            DT_CS_INTERFACE if if_class == CLASS_AUDIO && if_proto != 0x20 && b.len() >= 3 => {
                if if_sub == 1 {
                    // audio control: terminals and units, for the mute controls
                    let u = match b[2] {
                        2 if b.len() >= 6 => Some(Unit { id: b[3], kind: 2, source: 0, terminal_type: u16::from_le_bytes([b[4], b[5]]), mute: false }),
                        3 if b.len() >= 8 => Some(Unit { id: b[3], kind: 3, source: b[7], terminal_type: u16::from_le_bytes([b[4], b[5]]), mute: false }),
                        6 if b.len() >= 7 => Some(Unit { id: b[3], kind: 6, source: b[4], terminal_type: 0, mute: b[5] >= 1 && b[6] & 1 != 0 }),
                        // mixer, selector: the first input pin; processing, extension: likewise
                        4 | 5 if b.len() >= 6 => Some(Unit { id: b[3], kind: b[2], source: b[5], terminal_type: 0, mute: false }),
                        7 | 8 if b.len() >= 8 => Some(Unit { id: b[3], kind: b[2], source: b[7], terminal_type: 0, mute: false }),
                        _ => None,
                    };
                    if let (Some(u), true) = (u, n_units < units.len()) {
                        units[n_units] = u;
                        n_units += 1;
                    }
                } else if if_sub == 2 && if_alt != 0 {
                    match b[2] {
                        1 if b.len() >= 7 => pcm = u16::from_le_bytes([b[5], b[6]]) == 1,
                        2 if b.len() >= 8 && b[3] == 1 => {
                            fmt = Some((b[4], b[5], b[6]));
                            n_rates = 0;
                            range = None;
                            if b[7] == 0 && b.len() >= 14 {
                                let r = |o: usize| u32::from_le_bytes([b[o], b[o + 1], b[o + 2], 0]);
                                range = Some((r(8), r(11)));
                            } else {
                                for i in 0..b[7] as usize {
                                    let o = 8 + 3 * i;
                                    if b.len() >= o + 3 && n_rates < rates.len() {
                                        rates[n_rates] = u32::from_le_bytes([b[o], b[o + 1], b[o + 2], 0]);
                                        n_rates += 1;
                                    }
                                }
                            }
                        }
                        _ => {}
                    }
                }
            }
            DT_ENDPOINT if b.len() >= 7 => {
                let addr = b[2];
                let attr = b[3];
                let mp = u16::from_le_bytes([b[4], b[5]]) & 0x7FF;
                if if_class == CLASS_HID && attr & 3 == 3 && addr & 0x80 != 0 && n_hid < MAX_HID {
                    // one entry per interface: its first interrupt IN endpoint
                    let seen = c.hid[..n_hid].iter().any(|h| h.map(|h| h.iface) == Some(if_num));
                    if !seen && if_alt == 0 {
                        c.hid[n_hid] = Some(HidIface {
                            iface: if_num,
                            boot: if_sub == 1,
                            protocol: if_proto,
                            ep: addr & 0x0F,
                            interval_ms: b[6].max(1),
                            max_packet: mp,
                            report_len: hid_len,
                        });
                        n_hid += 1;
                    }
                } else if if_class == CLASS_AUDIO && if_sub == 2 && if_proto != 0x20 && attr & 3 == 1 {
                    flush(&mut pending, &mut c, &mut best_spk, &mut best_mic);
                    let out = addr & 0x80 == 0;
                    if out {
                        had_playback = true;
                    }
                    if let (Some((ch, sub, bits)), true) = (fmt, pcm) {
                        let offers = |hz: u32| match range {
                            Some((lo, hi)) => hz >= lo && hz <= hi,
                            None => rates[..n_rates].contains(&hz),
                        };
                        let (rate, rate_score) = if out {
                            (48_000, if offers(48_000) { 1 } else { 0 })
                        } else {
                            let mut r = (0, 0);
                            for (i, hz) in MIC_RATES.iter().enumerate() {
                                if offers(*hz) {
                                    r = (*hz, (MIC_RATES.len() - i) as u32);
                                    break;
                                }
                            }
                            r
                        };
                        let frame = ch as u32 * sub as u32;
                        // the packet must hold a frame's samples (and one more for a 44.1 kHz microphone)
                        let need = frame * (rate / 1000 + if out { 0 } else { 1 });
                        let fs = score_format(ch, sub, bits, out);
                        if fs != 0 && rate_score != 0 && (mp as u32 >= need || !out) && frame != 0 {
                            let alt = AudioAlt {
                                iface: if_num,
                                alt: if_alt,
                                ep: addr & 0x0F,
                                channels: ch,
                                subframe: sub,
                                bits,
                                rate,
                                max_packet: mp,
                                sync: (attr >> 2) & 3,
                                freq_control: false,
                            };
                            pending = Some((alt, out, rate_score * 64 + fs));
                        }
                    }
                }
            }
            DT_CS_ENDPOINT if b.len() >= 4 && b[2] == 1 => {
                if let Some((alt, _, _)) = pending.as_mut() {
                    alt.freq_control = b[3] & 1 != 0;
                }
            }
            _ => {}
        }
    }
    flush(&mut pending, &mut c, &mut best_spk, &mut best_mic);
    c.speaker_unusable = had_playback && c.speaker.is_none() && !c.audio2;

    // mute controls: from each output terminal back towards its source, the first feature unit with a mute
    let units = &units[..n_units];
    for ot in units.iter().filter(|u| u.kind == 3) {
        let mut id = ot.source;
        let mut found = None;
        for _ in 0..8 {
            let Some(u) = units.iter().find(|u| u.id == id) else { break };
            if u.kind == 6 && u.mute {
                found = Some(Mute { unit: u.id, control_iface: ac_iface });
                break;
            }
            if u.kind == 2 {
                break;
            }
            id = u.source;
        }
        // an output terminal of type "USB streaming" (0x0101) is the microphone's way to the host
        if ot.terminal_type == 0x0101 {
            c.mic_mute = c.mic_mute.or(found);
        } else {
            c.speaker_mute = c.speaker_mute.or(found);
        }
    }
    Some(c)
}
