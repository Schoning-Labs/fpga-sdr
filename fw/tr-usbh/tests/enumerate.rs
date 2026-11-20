// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The host stack against simulated devices at the level of transactions (the logic underneath has
//! its own bench, sim/usbh/tb_usbh.v). Descriptor sets:
//!
//! - **C-Media audio adapter 0d8c:0014** ("Unitek Y-247A", a CM108-type dongle): transcribed field by
//!   field from the `lsusb -v` listing on
//!   https://wiki.vikings.net/hardware:usb_sound_adapter_aud_usbcryf_usbaryf (253 bytes: audio
//!   control with mixer, selector and three feature units, playback 2 channels and recording 1
//!   channel at 48 and 44.1 kHz, a HID interface for its buttons).
//! - **Pixart optical mouse 093a:2510**: the report descriptor printed in the Linux kernel's
//!   Documentation/hid/hidintro.rst; the 34 bytes of configuration around it are the standard ones
//!   of a boot mouse (constructed).
//! - A boot keyboard with a second (consumer keys) interface, an audio class 2.0 device, a hub and
//!   a sound card that only plays at 44.1 kHz: constructed.

use std::collections::VecDeque;

use tr_usbh::desc::{parse_config, parse_device};
use tr_usbh::hid::{self, InputEvent};
use tr_usbh::host::*;

fn device_desc(mp0: u8, class: u8, vid: u16, pid: u16) -> Vec<u8> {
    vec![18, 1, 0x10, 0x01, class, 0, 0, mp0, vid as u8, (vid >> 8) as u8, pid as u8, (pid >> 8) as u8, 0, 1, 1, 2, 0, 1]
}

/// C-Media 0d8c:0014, configuration descriptor (see the file comment).
fn cmedia_config() -> Vec<u8> {
    let d: &[&[u8]] = &[
        &[9, 2, 0xFD, 0x00, 4, 1, 0, 0x80, 50],
        // interface 0: audio control
        &[9, 4, 0, 0, 0, 1, 1, 0, 0],
        &[10, 36, 1, 0x00, 0x01, 0x64, 0x00, 2, 1, 2],
        &[12, 36, 2, 1, 0x01, 0x01, 0, 2, 0x03, 0x00, 0, 0], // input terminal 1: USB streaming
        &[12, 36, 2, 2, 0x01, 0x02, 0, 1, 0x01, 0x00, 0, 0], // input terminal 2: microphone
        &[9, 36, 3, 6, 0x01, 0x03, 0, 9, 0],                 // output terminal 6: speaker, from unit 9
        &[9, 36, 3, 7, 0x01, 0x01, 0, 8, 0],                 // output terminal 7: USB streaming, from unit 8
        &[7, 36, 5, 8, 1, 10, 0],                            // selector 8, from unit 10
        &[10, 36, 6, 9, 15, 1, 0x01, 0x02, 0x02, 0],         // feature unit 9, from mixer 15: mute, volume
        &[9, 36, 6, 10, 2, 1, 0x43, 0x00, 0],                // feature unit 10, from the microphone
        &[9, 36, 6, 13, 2, 1, 0x03, 0x00, 0],                // feature unit 13 (side tone)
        &[13, 36, 4, 15, 2, 1, 13, 2, 0x03, 0x00, 0, 0x00, 0], // mixer 15: terminal 1 and unit 13
        // interface 1: playback
        &[9, 4, 1, 0, 0, 1, 2, 0, 0],
        &[9, 4, 1, 1, 1, 1, 2, 0, 0],
        &[7, 36, 1, 1, 1, 0x01, 0x00],
        &[14, 36, 2, 1, 2, 2, 16, 2, 0x80, 0xBB, 0x00, 0x44, 0xAC, 0x00],
        &[9, 5, 0x01, 9, 0xC8, 0x00, 1, 0, 0], // isochronous, adaptive, 200 bytes
        &[7, 37, 1, 0x01, 1, 0x01, 0x00],
        // interface 2: recording
        &[9, 4, 2, 0, 0, 1, 2, 0, 0],
        &[9, 4, 2, 1, 1, 1, 2, 0, 0],
        &[7, 36, 1, 7, 1, 0x01, 0x00],
        &[14, 36, 2, 1, 1, 2, 16, 2, 0x80, 0xBB, 0x00, 0x44, 0xAC, 0x00],
        &[9, 5, 0x82, 13, 0x64, 0x00, 1, 0, 0], // isochronous, synchronous, 100 bytes
        &[7, 37, 1, 0x01, 0, 0x00, 0x00],
        // interface 3: HID (volume and mute buttons)
        &[9, 4, 3, 0, 1, 3, 0, 0, 0],
        &[9, 33, 0x00, 0x01, 0, 1, 34, 60, 0],
        &[7, 5, 0x87, 3, 4, 0, 2],
    ];
    let v: Vec<u8> = d.iter().flat_map(|x| x.iter().copied()).collect();
    assert_eq!(v.len(), 253);
    for x in d {
        assert_eq!(x[0] as usize, x.len());
    }
    v
}

/// The same adapter with its playback only at 44.1 kHz and its microphone only at 16 kHz and 8 kHz.
fn odd_rates_config() -> Vec<u8> {
    let mut v = cmedia_config();
    let pat = [0x80u8, 0xBB, 0x00, 0x44, 0xAC, 0x00];
    let first = v.windows(6).position(|w| w == pat).unwrap();
    v[first..first + 6].copy_from_slice(&[0x44, 0xAC, 0x00, 0x44, 0xAC, 0x00]);
    let second = v.windows(6).position(|w| w == pat).unwrap();
    v[second..second + 6].copy_from_slice(&[0x40, 0x1F, 0x00, 0x80, 0x3E, 0x00]);
    v
}

fn mouse_config() -> Vec<u8> {
    [&[9u8, 2, 34, 0, 1, 1, 0, 0xA0, 50][..], &[9, 4, 0, 0, 1, 3, 1, 2, 0], &[9, 33, 0x11, 0x01, 0, 1, 34, 52, 0], &[7, 5, 0x81, 3, 4, 0, 10]]
        .concat()
}

/// Pixart 093a:2510 (see the file comment).
const PIXART_REPORT: [u8; 52] = [
    0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, 0x09, 0x01, 0xa1, 0x00, 0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01,
    0x75, 0x01, 0x95, 0x03, 0x81, 0x02, 0x75, 0x05, 0x95, 0x01, 0x81, 0x01, 0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38,
    0x15, 0x81, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06, 0xc0, 0xc0,
];

fn keyboard_config() -> Vec<u8> {
    [
        &[9u8, 2, 59, 0, 2, 1, 0, 0xA0, 50][..],
        &[9, 4, 0, 0, 1, 3, 1, 1, 0], // boot keyboard
        &[9, 33, 0x11, 0x01, 0, 1, 34, 65, 0],
        &[7, 5, 0x81, 3, 8, 0, 10],
        &[9, 4, 1, 0, 1, 3, 0, 0, 0], // consumer keys
        &[9, 33, 0x11, 0x01, 0, 1, 34, 50, 0],
        &[7, 5, 0x82, 3, 4, 0, 10],
    ]
    .concat()
}

fn audio2_config() -> Vec<u8> {
    [
        &[9u8, 2, 44, 0, 2, 1, 0, 0x80, 50][..],
        &[8, 11, 0, 2, 1, 0, 0x20, 0], // interface association
        &[9, 4, 0, 0, 0, 1, 1, 0x20, 0],
        &[9, 36, 1, 0x00, 0x02, 0x0A, 9, 0, 0],
        &[9, 4, 1, 0, 0, 1, 2, 0x20, 0],
    ]
    .concat()
}

// ---------------------------------------------------------------- a simulated device and bus

#[derive(Default)]
struct Dev {
    low_speed: bool,
    dev: Vec<u8>,
    cfg: Vec<u8>,
    report: Vec<u8>,
    /// SETUP packets seen, in order.
    log: Vec<[u8; 8]>,
    addr: u8,
    configured: u8,
    /// Requests (bRequest) that are answered with STALL.
    stall: Vec<u8>,
    /// Never answers.
    dead: bool,
    /// NAKs still to give on endpoint 0.
    nak: u32,
    out_data: Vec<Vec<u8>>,
}

#[derive(Default)]
struct SimPort {
    dev: Option<Dev>,
    mode: Option<Mode>,
    low_speed: bool,
    addr: u8,
    gone: bool,
    busy: u8,
    result: u8,
    records: VecDeque<(u8, Vec<u8>)>,
    slots: [Option<(u8, u8)>; 2],
    resp: Vec<u8>,
    resp_pos: usize,
    stall_now: bool,
    mp0: usize,
}

#[derive(Default)]
struct Sim {
    ports: [SimPort; 2],
    swap: bool,
    /// The board sits the other way up.
    plug_swapped: bool,
    speaker: Option<AudioSetup>,
    mic: Option<AudioSetup>,
    starts: u32,
}

impl Sim {
    fn plug(&mut self, p: usize, d: Dev) {
        self.ports[p].mp0 = d.dev[7] as usize;
        self.ports[p].dev = Some(d);
    }
    fn unplug(&mut self, p: usize) -> Dev {
        if self.ports[p].mode == Some(Mode::Run) {
            self.ports[p].gone = true;
        }
        self.ports[p].dev.take().unwrap()
    }
    /// The device sends a report on its interrupt endpoint `ep`.
    fn report(&mut self, p: usize, ep: u8, r: &[u8]) {
        let port = &mut self.ports[p];
        for s in 0..2 {
            if port.slots[s].map(|x| x.0) == Some(ep) && port.mode == Some(Mode::Run) {
                port.records.push_back((s as u8 + 1, r.to_vec()));
            }
        }
    }
    fn crossed(&self) -> bool {
        self.swap != self.plug_swapped
    }
}

impl Bus for Sim {
    fn status(&mut self, p: usize) -> PortStatus {
        let crossed = self.crossed();
        let port = &mut self.ports[p];
        let (mut dp, mut dn) = match &port.dev {
            Some(d) if port.mode != Some(Mode::Reset) => (!d.low_speed, d.low_speed),
            _ => (false, false),
        };
        if crossed {
            core::mem::swap(&mut dp, &mut dn);
        }
        let busy = port.busy > 0;
        if busy {
            port.busy -= 1;
        }
        PortStatus { dp, dn, gone: port.gone, busy, result: port.result, slot_err: 0 }
    }
    fn set_port(&mut self, p: usize, mode: Mode, low_speed: bool, address: u8) {
        let port = &mut self.ports[p];
        if mode != Mode::Run {
            port.gone = false;
        }
        if mode == Mode::Reset {
            if let Some(d) = port.dev.as_mut() {
                d.addr = 0;
                d.configured = 0;
            }
        }
        port.mode = Some(mode);
        port.low_speed = low_speed;
        port.addr = address;
    }
    fn start(&mut self, p: usize, kind: Kind, ep: u8, toggle: bool, data: &[u8], _nak: u8) {
        self.starts += 1;
        let crossed = self.crossed();
        let port = &mut self.ports[p];
        port.busy = 1;
        let _ = toggle;
        if port.mode != Some(Mode::Run) || port.gone {
            port.result = R_NOT_RUNNING;
            return;
        }
        // a device only understands the host at its own speed, with the lines the right way round, at its address
        let Some(d) = port.dev.as_mut() else {
            port.result = R_NO_ANSWER;
            return;
        };
        if d.dead || crossed || d.low_speed != port.low_speed || d.addr != port.addr || ep != 0 {
            port.result = R_NO_ANSWER;
            return;
        }
        port.result = R_DONE;
        match kind {
            Kind::Setup => {
                let s: [u8; 8] = data.try_into().unwrap();
                d.log.push(s);
                port.resp.clear();
                port.resp_pos = 0;
                port.stall_now = d.stall.contains(&s[1]);
                let len = u16::from_le_bytes([s[6], s[7]]) as usize;
                match (s[0], s[1]) {
                    (0x80, 6) | (0x81, 6) => {
                        let src = match s[3] {
                            1 => &d.dev,
                            2 => &d.cfg,
                            0x22 => &d.report,
                            _ => {
                                port.stall_now = true;
                                &d.dev
                            }
                        };
                        port.resp = src[..len.min(src.len())].to_vec();
                    }
                    (0x00, 5) => d.addr = s[2], // (really after the status stage; the stack changes its own after it too)
                    (0x00, 9) => d.configured = s[2],
                    (0x01, 11) | (0x21, 0x0A) | (0x21, 0x0B) | (0x22, 1) | (0x21, 1) => {}
                    _ => port.stall_now = true,
                }
                if s[1] == 5 {
                    // the status stage still goes to address 0
                    port.addr = s[2];
                }
            }
            Kind::In => {
                if port.stall_now {
                    port.result = R_STALL;
                } else {
                    // NAKs are tried again by the logic, frame after frame: the transaction just takes longer
                    port.busy += d.nak as u8;
                    d.nak = 0;
                    let n = (port.resp.len() - port.resp_pos).min(port.mp0);
                    let chunk = port.resp[port.resp_pos..port.resp_pos + n].to_vec();
                    port.resp_pos += n;
                    port.records.push_back((0, chunk));
                }
            }
            Kind::Out => {
                if port.stall_now {
                    port.result = R_STALL;
                } else if !data.is_empty() {
                    d.out_data.push(data.to_vec());
                }
            }
        }
    }
    fn pop_record(&mut self, p: usize, buf: &mut [u8]) -> Option<(u8, usize)> {
        let (src, r) = self.ports[p].records.pop_front()?;
        buf[..r.len()].copy_from_slice(&r);
        Some((src, r.len()))
    }
    fn set_slot(&mut self, p: usize, slot: usize, poll: Option<(u8, u8)>) {
        self.ports[p].slots[slot] = poll;
    }
    fn set_speaker(&mut self, cfg: Option<AudioSetup>) {
        self.speaker = cfg;
    }
    fn set_mic(&mut self, cfg: Option<AudioSetup>) {
        self.mic = cfg;
    }
    fn swap(&self) -> bool {
        self.swap
    }
    fn set_swap(&mut self, swap: bool) {
        self.swap = swap;
    }
}

/// Runs the host for `ms` milliseconds, one poll per ms.
fn run(host: &mut Host, sim: &mut Sim, now: &mut u32, ms: u32) -> Vec<Event> {
    let mut ev = Vec::new();
    for _ in 0..ms {
        *now += 1;
        host.poll(sim, *now, &mut |e| ev.push(e));
    }
    ev
}

fn headset() -> Dev {
    Dev { dev: device_desc(8, 0, 0x0d8c, 0x0014), cfg: cmedia_config(), ..Dev::default() }
}
fn mouse() -> Dev {
    Dev { low_speed: true, dev: device_desc(8, 0, 0x093a, 0x2510), cfg: mouse_config(), report: PIXART_REPORT.to_vec(), ..Dev::default() }
}
fn keyboard() -> Dev {
    Dev { low_speed: true, dev: device_desc(8, 0, 0x413c, 0x2113), cfg: keyboard_config(), report: vec![0x05, 0x01, 0x09, 0x06], ..Dev::default() }
}
fn connected(ev: &[Event], port: u8) -> Info {
    ev.iter()
        .find_map(|e| match e {
            Event::Connected { port: p, info } if *p == port => Some(*info),
            _ => None,
        })
        .unwrap_or_else(|| panic!("no Connected for port {port} in {ev:?}"))
}
fn inputs(ev: &[Event]) -> Vec<InputEvent> {
    ev.iter()
        .filter_map(|e| match e {
            Event::Input { event, .. } => Some(*event),
            _ => None,
        })
        .collect()
}

// ---------------------------------------------------------------- the tests

#[test]
fn cmedia_descriptors_parse() {
    let d = parse_device(&device_desc(8, 0, 0x0d8c, 0x0014)).unwrap();
    assert_eq!((d.vendor, d.product, d.max_packet0), (0x0d8c, 0x0014, 8));
    let c = parse_config(&cmedia_config()).unwrap();
    let s = c.speaker.unwrap();
    assert_eq!((s.iface, s.alt, s.ep, s.channels, s.subframe, s.bits, s.rate, s.max_packet), (1, 1, 1, 2, 2, 16, 48_000, 200));
    assert_eq!((s.sync, s.freq_control), (2, true)); // adaptive
    let m = c.mic.unwrap();
    assert_eq!((m.iface, m.alt, m.ep, m.channels, m.rate, m.sync), (2, 1, 2, 1, 48_000, 3));
    // speaker: terminal 6 <- feature unit 9; microphone: terminal 7 <- selector 8 <- feature unit 10
    assert_eq!(c.speaker_mute.unwrap().unit, 9);
    assert_eq!(c.mic_mute.unwrap().unit, 10);
    let h = c.hid[0].unwrap();
    assert_eq!((h.iface, h.boot, h.protocol, h.ep, h.interval_ms, h.report_len), (3, false, 0, 7, 2, 60));
    assert!(c.audio && !c.audio2 && !c.speaker_unusable);
    // cut short anywhere: no panic, and what was complete is still found
    for n in 0..253 {
        let _ = parse_config(&cmedia_config()[..n]);
    }
    assert!(parse_config(&cmedia_config()[..120]).unwrap().speaker.is_none());
}

#[test]
fn headset_and_mouse_at_once() {
    let (mut host, mut sim, mut now) = (Host::new(), Sim::default(), 0);
    sim.plug(0, headset());
    sim.plug(1, mouse());
    let ev = run(&mut host, &mut sim, &mut now, 400);
    let h = connected(&ev, 0);
    assert_eq!((h.vendor, h.low_speed, h.keyboard, h.mouse), (0x0d8c, false, false, false));
    assert_eq!(h.speaker.unwrap().rate, 48_000);
    assert_eq!(h.mic.unwrap().channels, 1);
    assert_eq!(sim.speaker, Some(AudioSetup { port: 0, ep: 1, mono: false, bytes3: false, max_samples: 49 }));
    assert_eq!(sim.mic, Some(AudioSetup { port: 0, ep: 2, mono: true, bytes3: false, max_samples: 0 }));
    assert_eq!(host.audio_ports(), (Some(0), Some(0)));
    // what the adapter was asked, after SET_CONFIGURATION, in order
    let d = sim.ports[0].dev.as_ref().unwrap();
    let after: Vec<_> = d.log.iter().skip_while(|s| s[1] != 9).skip(1).map(|s| (s[0], s[1], s[2], s[3], s[4], s[5])).collect();
    assert_eq!(
        after,
        [
            (0x01, 11, 0, 0, 1, 0),    // playback interface off
            (0x21, 1, 0, 1, 0, 9),     // un-mute feature unit 9
            (0x01, 11, 1, 0, 1, 0),    // playback interface on
            (0x22, 1, 0, 1, 0x01, 0),  // sampling frequency of endpoint 0x01
            (0x01, 11, 0, 0, 2, 0),    // recording interface off
            (0x21, 1, 0, 1, 0, 10),    // un-mute feature unit 10
            (0x01, 11, 1, 0, 2, 0),    // recording interface on
            (0x22, 1, 0, 1, 0x82, 0),  // sampling frequency of endpoint 0x82
        ]
    );
    assert_eq!(d.out_data, [vec![0], vec![0x80, 0xBB, 0x00], vec![0], vec![0x80, 0xBB, 0x00]]);
    assert_eq!((d.addr, d.configured), (1, 1));

    let m = connected(&ev, 1);
    assert!(m.mouse && m.wheel && m.low_speed && !m.keyboard && m.speaker.is_none());
    assert_eq!(sim.ports[1].slots[0], Some((1, 10)));
    let d = sim.ports[1].dev.as_ref().unwrap();
    assert_eq!(d.addr, 2);
    assert!(d.log.iter().any(|s| s[..4] == [0x81, 6, 0, 0x22] && s[6] == 52), "report descriptor read");
    assert!(d.log.iter().any(|s| s[..3] == [0x21, 0x0B, 1]), "report protocol set");

    sim.report(1, 1, &[0x01, 10, 0xFB, 0x00]);
    sim.report(1, 1, &[0x00, 0, 0, 0x01]);
    let ev = run(&mut host, &mut sim, &mut now, 2);
    assert_eq!(
        inputs(&ev),
        [
            InputEvent::PointerMove { dx: 10, dy: -5 },
            InputEvent::Button { button: 0, down: true },
            InputEvent::Button { button: 0, down: false },
            InputEvent::Wheel { delta: 1 }
        ]
    );
}

#[test]
fn keyboard_boot_protocol_and_layouts() {
    let (mut host, mut sim, mut now) = (Host::new(), Sim::default(), 0);
    sim.plug(1, keyboard());
    let ev = run(&mut host, &mut sim, &mut now, 300);
    let k = connected(&ev, 1);
    assert!(k.keyboard && !k.mouse);
    let d = sim.ports[1].dev.as_ref().unwrap();
    assert!(d.log.iter().any(|s| s[..6] == [0x21, 0x0B, 0, 0, 0, 0]), "boot protocol on interface 0");
    assert_eq!(sim.ports[1].slots, [Some((1, 10)), None]); // the consumer-key interface is not polled
    sim.report(1, 1, &[hid::MOD_LSHIFT, 0, 0x1C, 0, 0, 0, 0, 0]);
    sim.report(1, 1, &[0; 8]);
    let ev = run(&mut host, &mut sim, &mut now, 2);
    let keys = inputs(&ev);
    assert_eq!(keys.len(), 4);
    let InputEvent::Key { usage, down, mods } = keys[1] else { panic!() };
    assert_eq!((usage, down), (0x1C, true));
    assert_eq!(hid::key_char(hid::Layout::Us, usage, mods), Some('Y'));
    assert_eq!(hid::key_char(hid::Layout::De, usage, mods), Some('Z'));
    // pulled with a key down: the key goes up
    sim.report(1, 1, &[0, 0, 0x04, 0, 0, 0, 0, 0]);
    run(&mut host, &mut sim, &mut now, 2);
    sim.unplug(1);
    let ev = run(&mut host, &mut sim, &mut now, 5);
    assert_eq!(inputs(&ev), [InputEvent::Key { usage: 0x04, down: false, mods: 0 }]);
    assert!(ev.contains(&Event::Disconnected { port: 1 }));
    assert_eq!(sim.ports[1].slots, [None, None]);
}

#[test]
fn mouse_without_a_readable_report_descriptor_uses_the_boot_protocol() {
    let (mut host, mut sim, mut now) = (Host::new(), Sim::default(), 0);
    let mut m = mouse();
    m.report = vec![0xFF; 52];
    sim.plug(0, m);
    let ev = run(&mut host, &mut sim, &mut now, 300);
    let i = connected(&ev, 0);
    assert!(i.mouse && !i.wheel);
    assert!(sim.ports[0].dev.as_ref().unwrap().log.iter().any(|s| s[..3] == [0x21, 0x0B, 0]), "boot protocol set");
    sim.report(0, 1, &[0x02, 0xFF, 0x02]);
    assert_eq!(
        inputs(&run(&mut host, &mut sim, &mut now, 2)),
        [InputEvent::PointerMove { dx: -1, dy: 2 }, InputEvent::Button { button: 1, down: true }]
    );
}

#[test]
fn unsupported_devices_are_reported() {
    let (mut host, mut sim, mut now) = (Host::new(), Sim::default(), 0);
    sim.plug(0, Dev { dev: device_desc(64, 0xEF, 0x1234, 0x0002), cfg: audio2_config(), ..Dev::default() });
    sim.plug(1, Dev { dev: device_desc(64, 9, 0x05e3, 0x0608), cfg: vec![9, 2, 9, 0, 0, 1, 0, 0xE0, 50], ..Dev::default() });
    let ev = run(&mut host, &mut sim, &mut now, 400);
    assert!(ev.contains(&Event::Problem { port: 0, what: Problem::Audio2 }));
    assert!(ev.contains(&Event::Problem { port: 1, what: Problem::Hub }));
    assert!(!ev.iter().any(|e| matches!(e, Event::Connected { .. })));
    assert_eq!(sim.speaker, None);
    // they are left alone until pulled; then the port is free again
    let n = sim.starts;
    run(&mut host, &mut sim, &mut now, 500);
    assert_eq!(sim.starts, n);
    sim.unplug(1);
    sim.plug(1, mouse());
    assert!(connected(&run(&mut host, &mut sim, &mut now, 400), 1).mouse);
}

#[test]
fn speaker_only_at_44k1_and_microphone_at_16k() {
    let c = parse_config(&odd_rates_config()).unwrap();
    assert!(c.speaker.is_none() && c.speaker_unusable);
    assert_eq!(c.mic.unwrap().rate, 16_000);
    let (mut host, mut sim, mut now) = (Host::new(), Sim::default(), 0);
    sim.plug(0, Dev { dev: device_desc(8, 0, 0x0d8c, 0x0014), cfg: odd_rates_config(), ..Dev::default() });
    let ev = run(&mut host, &mut sim, &mut now, 400);
    assert!(ev.contains(&Event::Problem { port: 0, what: Problem::SpeakerFormat }));
    let i = connected(&ev, 0);
    assert_eq!((i.speaker, i.mic.unwrap().rate), (None, 16_000));
    assert_eq!(sim.speaker, None);
    assert!(sim.mic.is_some());
    assert_eq!(sim.ports[0].dev.as_ref().unwrap().out_data.last().unwrap(), &vec![0x80, 0x3E, 0x00]);
}

#[test]
fn board_the_other_way_up_is_found_out() {
    let (mut host, mut sim, mut now) = (Host::new(), Sim::default(), 0);
    sim.plug_swapped = true;
    sim.plug(0, headset());
    let ev = run(&mut host, &mut sim, &mut now, 2000);
    assert!(sim.swap, "the swap bit was set");
    assert!(connected(&ev, 0).speaker.is_some());
    assert!(!ev.iter().any(|e| matches!(e, Event::Problem { .. })));
}

#[test]
fn a_dead_device_is_given_up_and_nothing_hangs() {
    let (mut host, mut sim, mut now) = (Host::new(), Sim::default(), 0);
    sim.plug(0, Dev { dead: true, ..headset() });
    let ev = run(&mut host, &mut sim, &mut now, 3000);
    assert_eq!(ev, [Event::Problem { port: 0, what: Problem::Enumeration }]);
    let n = sim.starts;
    assert!(n <= 8, "{n} transactions for a dead device");
    run(&mut host, &mut sim, &mut now, 1000);
    assert_eq!(sim.starts, n, "left alone afterwards");
    // the other port still works
    sim.plug(1, keyboard());
    assert!(connected(&run(&mut host, &mut sim, &mut now, 400), 1).keyboard);
}

#[test]
fn naks_and_stalls_in_the_class_setup_are_survived() {
    let (mut host, mut sim, mut now) = (Host::new(), Sim::default(), 0);
    // sampling-frequency and mute requests (class request 1) and SET_IDLE answered with STALL; ten NAKs on the way
    sim.plug(0, Dev { stall: vec![1, 0x0A], nak: 10, ..headset() });
    let ev = run(&mut host, &mut sim, &mut now, 500);
    let i = connected(&ev, 0);
    assert!(i.speaker.is_some() && i.mic.is_some());
}

#[test]
fn replug_second_headset_and_supply_trouble() {
    let (mut host, mut sim, mut now) = (Host::new(), Sim::default(), 0);
    sim.plug(0, headset());
    run(&mut host, &mut sim, &mut now, 400);
    // a second headset: the first keeps the audio
    sim.plug(1, headset());
    let ev = run(&mut host, &mut sim, &mut now, 400);
    assert!(ev.contains(&Event::Problem { port: 1, what: Problem::AudioBusy }));
    assert_eq!(host.audio_ports(), (Some(0), Some(0)));
    sim.unplug(1);
    run(&mut host, &mut sim, &mut now, 10);
    // stays up for more than 3 s, then is pulled: no supply warning
    run(&mut host, &mut sim, &mut now, 4000);
    let d = sim.unplug(0);
    let ev = run(&mut host, &mut sim, &mut now, 10);
    assert_eq!(ev, [Event::Disconnected { port: 0 }]);
    assert_eq!((sim.speaker, sim.mic, host.audio_ports()), (None, None, (None, None)));
    // drops off three times shortly after coming up
    let mut d = Some(d);
    let mut all = Vec::new();
    for _ in 0..3 {
        sim.plug(0, d.take().unwrap());
        all.extend(run(&mut host, &mut sim, &mut now, 400));
        assert!(sim.speaker.is_some());
        d = Some(sim.unplug(0));
        all.extend(run(&mut host, &mut sim, &mut now, 10));
    }
    assert_eq!(all.iter().filter(|e| matches!(e, Event::Connected { .. })).count(), 3);
    assert_eq!(all.iter().filter(|e| **e == Event::Problem { port: 0, what: Problem::Power }).count(), 1);
}
