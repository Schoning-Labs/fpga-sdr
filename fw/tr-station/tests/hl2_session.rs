// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The HL2 link session against a model of the HL2's side, on an in-memory Ethernet
//! segment. **No real HL2 is involved.** The model answers as the raw front-end image's
//! PROTOCOL.md says it does (sections 1 to 6): DHCP client, discovery reply with the 0xD1 marker,
//! a 60-byte reply to every register write, the stream to whoever sent the start datagram while
//! raw mode is on. It also plays the Tang's chip: while it "streams" it counts raw frames in the
//! link's register (only if the firmware wrote the HL2's address there, as the real classifier
//! needs). It records every datagram it receives, so each test checks the complete list of what
//! the firmware sent. A stream the classifier does not know (the address in the link's register is
//! not the HL2's) is counted as non-raw frames at the full rate, and floods the CPU receive ring: any
//! other datagram the HL2 sends meanwhile is lost (sim/hl2sfp -DSTALE: it stays readable ~33 us).
//!
//! Port 1027 datagrams are kept apart (`FakeHl2::msgs`). With `FakeHl2::msg` set they go to the
//! simulated message-layer firmware and boot ROM (`tr_hl2::sim::Hl2Sim`), which answers exactly as
//! msg.c and rom.c do; without it they get no answer, like an HL2 without that firmware. As on the
//! real HL2, its answers leave only in the gaps of the raw stream: while it streams, an answer
//! longer than `tr_hl2::protocol::reply_room` waits until the stream stops (none fits at 948
//! samples per frame).

use tr_fabric::mock::MockFabric;
use tr_net::device::mock::RingModel;
use tr_net::rings::MacRings;
use tr_regs::generated::{hl2_link, system};
use tr_station::hl2net::{build_udp, checksum, parse, Endpoint, Rx, BROADCAST_IP, BROADCAST_MAC};
use tr_hl2::control;
use tr_hl2::msg::{self, Request};
use tr_hl2::cpuload::{self, crc32, Image, LoadError};
use tr_hl2::protocol as hp;
use tr_hl2::sim::{Hl2Sim, FW_VERSION};
use tr_station::hl2session::{msg_datagram_allowed, update_datagram_allowed, Hl2Session, MsgLayer, Phase, ProgramState, SessionConfig, TxSink, MAX_UPDATE_ATTEMPTS};
use tr_station::station::Action;

const HL2_MAC: [u8; 6] = [0x00, 0x1C, 0xC0, 0xA2, 0x13, 0xDD];
const LINK_LOCAL: [u8; 4] = [169, 254, 19, 221];

/// What the model received, in order.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Got {
    Discovery,
    Stop,
    Start,
    Reg(u8, u32),
    DhcpOffer,
    DhcpAck,
    /// Anything the protocol gives the firmware no business sending.
    Unexpected(u16, Vec<u8>),
}

struct FakeHl2<'a> {
    wire: RingModel,
    chip: &'a MockFabric,
    marker: u8,
    use_dhcp: bool,
    ip: Option<[u8; 4]>,
    next_dhcp_ms: i64,
    running: bool,
    raw_mode: bool,
    stream_to: Option<([u8; 6], [u8; 4], u16)>,
    frames: u32,
    /// Datagrams still to lose (a bad cable).
    drop_next: u32,
    powered: bool,
    got: Vec<Got>,
    /// Every port 1027 datagram received.
    msgs: Vec<Vec<u8>>,
    /// The message-layer firmware, if this HL2 has it.
    msg: Option<Hl2Sim>,
    /// Where the message layer answers (the sender of the last port 1027 datagram).
    msg_to: Option<([u8; 6], [u8; 4], u16)>,
    /// Samples per frame (register 0x30).
    samples: u16,
    /// Port 1027 answers waiting for a gap in the stream that is long enough.
    held: Vec<Vec<u8>>,
    /// Port 1027 answers that had to wait.
    starved: u32,
}

impl<'a> FakeHl2<'a> {
    fn new(wire: RingModel, chip: &'a MockFabric, use_dhcp: bool) -> Self {
        FakeHl2 { wire, chip, marker: 0xD1, use_dhcp, ip: (!use_dhcp).then_some(LINK_LOCAL), next_dhcp_ms: 0, running: false, raw_mode: false, stream_to: None, frames: 0, drop_next: 0, powered: true, got: Vec::new(), msgs: Vec::new(), msg: None, msg_to: None, samples: 968, held: Vec::new(), starved: 0 }
    }

    /// The raw stream runs.
    fn streaming(&self) -> bool {
        self.running && self.raw_mode && self.stream_to.is_some()
    }

    fn me(&self) -> Endpoint {
        Endpoint { mac: HL2_MAC, ip: self.ip.unwrap_or([0; 4]) }
    }

    /// Streaming, but not classified as raw by the chip: every frame goes to the CPU receive ring.
    fn flooding(&self) -> bool {
        let ip = self.ip.map(u32::from_be_bytes).unwrap_or(0);
        self.running && self.raw_mode && self.stream_to.is_some() && self.chip.reg(hl2_link::hl2_ip::addr()) != ip
    }

    fn send(&mut self, src_port: u16, to: ([u8; 6], [u8; 4], u16), payload: &[u8]) {
        if self.flooding() {
            return; // overwritten in the ring long before the firmware reads it
        }
        let mut f = [0u8; 1_514];
        let n = build_udp(&mut f, &self.me(), src_port, to.0, to.1, to.2, payload).unwrap();
        self.wire.transmit(&f[..n]);
    }

    fn dhcp_request(&mut self, msg_type: u8, requested: Option<[u8; 4]>) {
        let mut b = [0u8; 300];
        b[0] = 1;
        b[1] = 1;
        b[2] = 6;
        b[4..8].copy_from_slice(&0x1234_5678u32.to_be_bytes());
        b[28..34].copy_from_slice(&HL2_MAC);
        b[236..240].copy_from_slice(&[99, 130, 83, 99]);
        b[240..243].copy_from_slice(&[53, 1, msg_type]);
        let mut p = 243;
        if let Some(ip) = requested {
            b[p..p + 2].copy_from_slice(&[50, 4]);
            b[p + 2..p + 6].copy_from_slice(&ip);
            p += 6;
        }
        b[p] = 255;
        self.send(68, (BROADCAST_MAC, BROADCAST_IP, 67), &b);
    }

    /// Power cycle: everything forgotten.
    fn reboot(&mut self) {
        self.held.clear();
        self.ip = (!self.use_dhcp).then_some(LINK_LOCAL);
        self.running = false;
        self.raw_mode = false;
        self.stream_to = None;
        self.next_dhcp_ms = 0;
    }

    fn step(&mut self, now_ms: i64) {
        if !self.powered {
            let mut sink = [0u8; 1_514];
            while self.wire.receive(&mut sink).is_some() {}
            self.chip.poke(hl2_link::status::addr(), 0);
            return;
        }
        if self.use_dhcp && self.ip.is_none() && now_ms >= self.next_dhcp_ms {
            self.next_dhcp_ms = now_ms + 1_000;
            self.dhcp_request(1, None);
        }
        let mut buf = [0u8; 1_514];
        while let Some(n) = self.wire.receive(&mut buf) {
            let frame = buf[..n].to_vec();
            if self.drop_next > 0 {
                self.drop_next -= 1;
                continue;
            }
            let Rx::Udp { src_mac, src_ip, src_port, dst_port, payload } = parse(&frame) else {
                self.got.push(Got::Unexpected(0, frame.clone()));
                continue;
            };
            // The radio checks no checksum; the model does, so that ours are right.
            assert_eq!(checksum(&[&frame[14..34]]), 0, "IP header checksum");
            let from = (src_mac, src_ip, src_port);
            match (dst_port, payload) {
                (68, p) if p.len() >= 243 && p[0] == 2 => {
                    let msg = p[240..].windows(3).find(|w| w[0] == 53 && w[1] == 1).map(|w| w[2]);
                    let yiaddr = [p[16], p[17], p[18], p[19]];
                    match msg {
                        Some(2) => {
                            self.got.push(Got::DhcpOffer);
                            self.dhcp_request(3, Some(yiaddr));
                        }
                        Some(5) => {
                            self.got.push(Got::DhcpAck);
                            self.ip = Some(yiaddr);
                        }
                        _ => self.got.push(Got::Unexpected(68, p.to_vec())),
                    }
                }
                (1_024 | 1_025, [0xEF, 0xFE, 0x02, ..]) if payload.len() == 60 => {
                    self.got.push(Got::Discovery);
                    if self.ip.is_some() {
                        let reply = self.reply();
                        self.send(dst_port, from, &reply);
                    }
                }
                (1_025, [0xEF, 0xFE, 0x05, 0x7F, addr, v3, v2, v1, v0, ..]) if payload.len() == 60 => {
                    let (addr, value) = (addr >> 1, u32::from_be_bytes([*v3, *v2, *v1, *v0]));
                    self.got.push(Got::Reg(addr, value));
                    // the same command bus the message layer's CMD reaches
                    if let Some(sim) = self.msg.as_mut() {
                        sim.hw.command(addr, value);
                    }
                    if addr == 0x30 {
                        self.raw_mode = value & 1 != 0;
                        self.samples = hp::clamp_samples_per_frame((value >> 16) as u16).0;
                    }
                    if self.ip.is_some() {
                        let reply = self.reply();
                        self.send(1_025, from, &reply);
                    }
                }
                (1_024, [0xEF, 0xFE, 0x04, flags, ..]) if payload.len() == 64 => {
                    let run = flags & 1 != 0;
                    self.got.push(if run { Got::Start } else { Got::Stop });
                    if run && !self.running {
                        self.stream_to = Some(from);
                    }
                    self.running = run;
                }
                (1_027, p) => {
                    self.msgs.push(p.to_vec());
                    if let Some(sim) = self.msg.as_mut() {
                        sim.input(now_ms as u32, p);
                    }
                }
                (port, p) => self.got.push(Got::Unexpected(port, p.to_vec())),
            }
            if dst_port == 1_027 {
                self.msg_to = Some(from);
            }
        }
        if let Some(sim) = self.msg.as_mut() {
            sim.poll(now_ms as u32);
            let mut out = Vec::new();
            while let Some(d) = sim.pop_output() {
                out.push(d.as_slice().to_vec());
            }
            self.held.extend(out);
        }
        // port 1027 answers leave only in the gaps of the stream (rawstream.v "Aux room")
        if let Some(to) = self.msg_to {
            let room = if self.streaming() { hp::reply_room(self.samples, hp::HEADER_LEN) as usize } else { usize::MAX };
            let (go, wait): (Vec<_>, Vec<_>) = self.held.drain(..).partition(|d| d.len() <= room);
            self.starved += wait.len() as u32;
            self.held = wait;
            for d in go {
                self.send(1_027, to, &d);
            }
        }
        // The Tang's receive side: raw frames are counted only from the address the firmware
        // wrote into the link's registers, and only if they are sent to us.
        let ip = self.ip.map(u32::from_be_bytes).unwrap_or(0);
        let seen = self.streaming() && self.chip.reg(hl2_link::hl2_ip::addr()) == ip;
        if seen {
            self.frames += 4;
            self.chip.poke(hl2_link::raw_frame_count::addr(), self.frames);
        }
        self.chip.poke(hl2_link::status::addr(), if seen { 0b11 } else { 0 });
        if self.flooding() {
            // 80,000 frames a second, 10 ms per step
            let other = self.chip.reg(hl2_link::other_frame_count::addr());
            self.chip.poke(hl2_link::other_frame_count::addr(), other.wrapping_add(800));
        }
    }

    fn reply(&self) -> [u8; 60] {
        let mut r = [0u8; 60];
        r[0] = 0xEF;
        r[1] = 0xFE;
        r[2] = if self.running { 3 } else { 2 };
        r[3..9].copy_from_slice(&HL2_MAC);
        r[0x09] = 74;
        r[0x0C] = self.marker;
        r[0x13] = if self.marker == 0xD1 { 0 } else { 4 };
        r[0x14] = 5;
        r[0x15] = 2;
        r
    }

    fn regs(&self) -> Vec<(u8, u32)> {
        self.got.iter().filter_map(|g| if let Got::Reg(a, v) = g { Some((*a, *v)) } else { None }).collect()
    }
}

type Session<'a> = Hl2Session<'a, MockFabric, RingModel>;

fn pair(chip: &MockFabric, use_dhcp: bool, cfg: SessionConfig) -> (Session<'_>, FakeHl2<'_>) {
    let (a, b) = RingModel::pair();
    (Hl2Session::new(chip, a, cfg, 14_074_000), FakeHl2::new(b, chip, use_dhcp))
}

/// Runs both ends in 10 ms steps from `from_ms` until `until` says so or `to_ms`; returns the time.
fn run(s: &mut Session, h: &mut FakeHl2, from_ms: i64, to_ms: i64, until: impl Fn(&Session, &FakeHl2) -> bool) -> i64 {
    let mut t = from_ms;
    while t < to_ms {
        h.step(t);
        s.poll(t);
        if until(s, h) {
            return t;
        }
        t += 10;
    }
    t
}

/// 20 m: 3 MHz high-pass and the 30/20 m low-pass.
const FILTER_20M: u32 = (1 << 23) | (1 << 20);
const RAW_ON_948: u32 = (948 << 16) | 1;
const GAIN_20DB: u32 = 0x40 + 20 + 12;

fn assert_nothing_unexpected(h: &FakeHl2) {
    for g in &h.got {
        assert!(!matches!(g, Got::Unexpected(..)), "the firmware sent something the session has no business sending: {g:?}");
    }
}

#[test]
fn power_up_with_dhcp_to_streaming() {
    let chip = MockFabric::new();
    let (mut s, mut h) = pair(&chip, true, SessionConfig::default());
    let t = run(&mut s, &mut h, 0, 8_000, |s, _| s.phase() == Phase::Streaming);
    // HELLO goes unanswered for 3 s (this HL2 has no message layer) before the start
    assert!(t < 5_000, "streaming after {t} ms");
    assert_eq!(h.ip, Some([10, 99, 0, 2]), "address from our DHCP server");
    assert_eq!(s.hl2(), Some((HL2_MAC, [10, 99, 0, 2])));
    // Our own address and the HL2's are in the link's registers (the classifier and the TX framer use them).
    assert_eq!(chip.reg(hl2_link::our_ip::addr()), 0x0A63_0001);
    assert_eq!(chip.reg(hl2_link::our_port::addr()), 51_000);
    assert_eq!(chip.reg(hl2_link::hl2_ip::addr()), 0x0A63_0002);
    assert_eq!(chip.reg(hl2_link::hl2_mac_lo::addr()), 0xC0A2_13DD);
    assert_eq!(h.stream_to, Some(([2, 0x54, 0x52, 0, 0, 1], [10, 99, 0, 1], 51_000)), "the stream goes to the port the TX framer uses");

    // Everything the HL2 received, in order, apart from the discovery requests before it had an address.
    let after: Vec<Got> = h.got.iter().filter(|g| **g != Got::Discovery).cloned().collect();
    assert_eq!(after, [Got::DhcpOffer, Got::DhcpAck, Got::Stop, Got::Reg(0x30, RAW_ON_948), Got::Reg(0x00, FILTER_20M), Got::Reg(0x0A, GAIN_20DB), Got::Start]);
    assert_nothing_unexpected(&h);
    assert!(h.regs().iter().all(|(a, _)| *a != 0x31), "register 0x31 is not touched by the session itself");
    assert_eq!(s.status(), ("HL2: streaming, 0 gaps, 0 CRC errors".to_string(), true));
    // The TX framer's enable is not the session's.
    assert!(chip.reg_writes(hl2_link::tx_ctrl::addr()).is_empty());
}

#[test]
fn a_radio_that_already_has_a_link_local_address() {
    let chip = MockFabric::new();
    let (mut s, mut h) = pair(&chip, false, SessionConfig::default());
    run(&mut s, &mut h, 0, 8_000, |s, _| s.phase() == Phase::Streaming);
    assert_eq!(s.phase(), Phase::Streaming);
    assert_eq!(chip.reg(hl2_link::hl2_ip::addr()), u32::from_be_bytes(LINK_LOCAL));
    assert_eq!(h.got, [Got::Discovery, Got::Stop, Got::Reg(0x30, RAW_ON_948), Got::Reg(0x00, FILTER_20M), Got::Reg(0x0A, GAIN_20DB), Got::Start]);
}

#[test]
fn a_radio_still_streaming_from_an_earlier_session() {
    // As seen on the board: another design started the HL2, the radio's bitstream and firmware were
    // loaded after it, and the HL2 streams on to the old destination.
    let chip = MockFabric::new();
    let (mut s, mut h) = pair(&chip, false, SessionConfig::default());
    h.running = true;
    h.raw_mode = true;
    h.stream_to = Some(([0x02, 0x48, 0x4C, 0x32, 0x00, 0x01], [169, 254, 1, 1], 1_025));
    let t = run(&mut s, &mut h, 0, 8_000, |s, _| s.phase() == Phase::Streaming);
    assert_eq!(s.phase(), Phase::Streaming, "{:?}", h.got);
    assert!(t < 6_000, "streaming after {t} ms");
    assert_eq!(s.stats.flood_stops, 1, "one stop broadcast ended the old stream");
    // The flood is seen at the first tick: the stop goes out before any discovery request.
    let stop = h.got.iter().position(|g| *g == Got::Stop).unwrap();
    assert_eq!(stop, 0, "{:?}", h.got);
    assert_eq!(h.got[stop + 1..], [Got::Discovery, Got::Stop, Got::Reg(0x30, RAW_ON_948), Got::Reg(0x00, FILTER_20M), Got::Reg(0x0A, GAIN_20DB), Got::Start]);
    assert_eq!(h.stream_to, Some(([2, 0x54, 0x52, 0, 0, 1], [10, 99, 0, 1], 51_000)), "the stream now comes to us");
    assert_nothing_unexpected(&h);
}

#[test]
fn lost_datagrams_are_repeated() {
    let chip = MockFabric::new();
    let (mut s, mut h) = pair(&chip, false, SessionConfig::default());
    // The first discovery is lost; later the raw-mode write and the first start are lost.
    h.drop_next = 1;
    run(&mut s, &mut h, 0, 5_000, |s, _| s.phase() == Phase::Configuring);
    h.drop_next = 1; // the stop
    run(&mut s, &mut h, 600, 5_000, |_, h| h.drop_next == 0);
    h.drop_next = 1; // register 0x30, first try
    let t = run(&mut s, &mut h, 700, 9_000, |s, _| s.phase() == Phase::Streaming);
    assert_eq!(s.phase(), Phase::Streaming, "at {t} ms: {:?}", h.got);
    assert_eq!(h.regs(), [(0x30, RAW_ON_948), (0x00, FILTER_20M), (0x0A, GAIN_20DB)]);
    assert_eq!(s.stats.commands_sent, 4, "one register write was sent twice");
    assert_nothing_unexpected(&h);
}

#[test]
fn another_image_is_left_alone() {
    let chip = MockFabric::new();
    let (mut s, mut h) = pair(&chip, false, SessionConfig::default());
    h.marker = 0; // the factory image
    run(&mut s, &mut h, 0, 10_000, |_, _| false);
    assert_eq!(s.phase(), Phase::WrongImage);
    assert!(h.got.iter().all(|g| *g == Got::Discovery), "{:?}", h.got);
    assert_eq!(chip.reg(hl2_link::hl2_ip::addr()), 0);
    assert_eq!(s.status().0, "HL2: radio found, but not the raw front-end image");
    // Flashed with the right image later: found without a restart.
    h.marker = 0xD1;
    run(&mut s, &mut h, 10_000, 20_000, |s, _| s.phase() == Phase::Streaming);
    assert_eq!(s.phase(), Phase::Streaming);
}

#[test]
fn the_stream_is_lost_and_found_again() {
    let chip = MockFabric::new();
    let (mut s, mut h) = pair(&chip, true, SessionConfig::default());
    let t = run(&mut s, &mut h, 0, 8_000, |s, _| s.phase() == Phase::Streaming);
    // The operator has TX on when the radio is power-cycled.
    s.on_action(&Action::ArmTx);
    let t = run(&mut s, &mut h, t, t + 500, |_, h| h.regs().contains(&(0x31, 1)));
    assert!(h.regs().contains(&(0x31, 1)));
    h.reboot();
    h.got.clear();
    let lost_at = run(&mut s, &mut h, t, t + 5_000, |s, _| s.phase() != Phase::Streaming);
    assert!(lost_at - t <= 1_100, "loss noticed after {} ms", lost_at - t);
    assert!(s.take_link_lost());
    assert!(!s.take_link_lost(), "reported once");
    // The firmware switches TX off on that report (Station::force_tx_off -> DisarmTx).
    s.on_action(&Action::DisarmTx);
    let back = run(&mut s, &mut h, lost_at, lost_at + 9_000, |s, _| s.phase() == Phase::Streaming);
    assert_eq!(s.phase(), Phase::Streaming, "streaming again after {} ms", back - lost_at);
    assert_eq!(s.stats.link_losses, 1);
    // Set up again from scratch; register 0x31 is only ever written as 0 by the recovery.
    let regs = h.regs();
    assert!(regs.ends_with(&[(0x30, RAW_ON_948), (0x00, FILTER_20M), (0x0A, GAIN_20DB)]), "{regs:?}");
    assert!(regs.iter().all(|(a, v)| *a != 0x31 || *v == 0), "{regs:?}");
    assert_nothing_unexpected(&h);
    assert_eq!(s.status().0, "HL2: streaming, 0 gaps, 0 CRC errors (lost 1 time(s))");

    // The cable is pulled: the PHY's receive clock stops.
    chip.poke(system::status::addr(), 1 << 9);
    h.powered = false;
    run(&mut s, &mut h, back, back + 100, |_, _| false);
    assert_eq!(s.phase(), Phase::NoLink);
    assert!(s.take_link_lost());
    assert_eq!(s.status(), ("HL2: no Ethernet link (lost 2 time(s))".to_string(), false));
    chip.poke(system::status::addr(), 0);
    h.powered = true;
    h.reboot();
    run(&mut s, &mut h, back + 100, back + 9_000, |s, _| s.phase() == Phase::Streaming);
    assert_eq!(s.phase(), Phase::Streaming);
}

#[test]
fn band_change_and_the_operators_tx_switch() {
    let chip = MockFabric::new();
    let cfg = SessionConfig { tx_sink: TxSink::Echo, ..SessionConfig::default() };
    let (mut s, mut h) = pair(&chip, false, cfg);

    // Before the stream runs, the TX switch sends nothing to the HL2.
    s.on_action(&Action::ArmTx);
    let t = run(&mut s, &mut h, 0, 8_000, |s, _| s.phase() == Phase::Streaming);
    assert!(h.regs().iter().all(|(a, _)| *a != 0x31));
    h.got.clear();

    // 40 m: high-pass and the 60/40 m low-pass.
    s.on_action(&Action::Retune { dial_hz: 7_074_000 });
    // TX on (echo was configured), then off.
    s.on_action(&Action::ArmTx);
    let t = run(&mut s, &mut h, t, t + 1_000, |_, h| h.regs().len() == 2);
    s.on_action(&Action::DisarmTx);
    run(&mut s, &mut h, t, t + 1_000, |_, h| h.regs().len() == 3);
    assert_eq!(h.got, [Got::Reg(0x00, (1 << 23) | (1 << 19)), Got::Reg(0x31, 5), Got::Reg(0x31, 0)]);
    // Decodes, CQ, starting and stopping a transmission are nothing to the HL2.
    s.on_action(&Action::StartDecode { slot: 1 });
    s.on_action(&Action::StopTx);
    run(&mut s, &mut h, t + 1_000, t + 1_500, |_, _| false);
    assert_eq!(h.got.len(), 3);
    assert_eq!(s.stats.commands_refused, 0);

    // Stop: the stream ends and the session stays quiet.
    s.stop(t + 1_500);
    h.got.clear();
    run(&mut s, &mut h, t + 1_500, t + 4_000, |_, _| false);
    assert_eq!(h.got, [Got::Stop]);
    assert!(!h.running);
}

// ---- The message layer ----------------------------------------------------------------------

/// Jumbo frames: the stream leaves room for port 1027 answers, so the message layer works while it runs.
fn jumbo() -> SessionConfig {
    SessionConfig { samples_per_frame: 5_968, ..SessionConfig::default() }
}

/// Every request in the port 1027 message-layer datagrams the firmware sent. Register bridge and
/// boot ROM datagrams (only the program update sends them) are checked against its whitelist and
/// skipped.
fn requests(h: &FakeHl2) -> Vec<Request> {
    let mut v = Vec::new();
    for d in &h.msgs {
        if d[0] == 0x4E || d[0] == 0x01 {
            assert!(update_datagram_allowed(d, &IMAGE), "a datagram the update whitelist does not pass left the firmware: {d:02x?}");
            continue;
        }
        assert!(msg_datagram_allowed(d), "a datagram the whitelist does not pass left the firmware: {d:02x?}");
        let (_, p) = msg::Header::parse(d).expect("a message-layer datagram");
        for m in msg::messages(p) {
            v.push(Request::decode(m.class, m.op, m.body).unwrap());
        }
    }
    v
}

#[test]
fn message_layer_up_telemetry_gain_and_filter() {
    let chip = MockFabric::new();
    let (mut s, mut h) = pair(&chip, false, jumbo());
    h.msg = Some(Hl2Sim::new(0xB007_0001));
    // HELLO is answered before the stream starts
    let t = run(&mut s, &mut h, 0, 5_000, |s, _| s.hl2_status().msg_layer == MsgLayer::Up);
    assert_eq!(s.hl2_status().msg_layer, MsgLayer::Up);
    assert!(!h.running, "the stream starts after HELLO");
    let t = run(&mut s, &mut h, t, t + 2_000, |s, _| s.phase() == Phase::Streaming);
    assert_eq!(s.phase(), Phase::Streaming);
    // telemetry every 500 ms, while streaming
    let t = run(&mut s, &mut h, t, t + 2_000, |s, h| s.hl2_status().telemetry.is_some() && h.msg.as_ref().unwrap().telemetry_period() == 500);
    assert_eq!(h.msg.as_ref().unwrap().telemetry_period(), 500);
    let tel = s.hl2_status().telemetry.unwrap();
    assert!(s.hl2_line().starts_with("HL2 ") && s.hl2_line().contains(" C, fwd "), "{}", s.hl2_line());
    assert!(s.hl2_report().contains("safety 0x"), "{}", s.hl2_report());
    let n = h.msg.as_ref().unwrap().hw.temp_code;
    assert_eq!(tel.0.temp_code, n);
    assert_eq!(s.control().unwrap().frontend_reg(), FILTER_20M, "shadow seeded from the latch the set-up wrote");

    // RX gain and filter go through the message layer, not port 1025
    h.got.clear();
    s.set_rx_gain_db(10);
    s.on_action(&Action::Retune { dial_hz: 7_074_000 });
    run(&mut s, &mut h, t, t + 1_000, |_, h| h.msg.as_ref().unwrap().hw.reg0 == (1 << 23) | (1 << 19));
    let hw = &h.msg.as_ref().unwrap().hw;
    assert_eq!(hw.rx_gain & 0x7F, 0x40 + 10 + 12);
    assert_eq!(hw.reg0, (1 << 23) | (1 << 19));
    assert!(h.got.is_empty(), "{:?}", h.got);
    assert_eq!(s.hl2_status().rx_gain_db, 10);

    // what left the firmware on port 1027: only these requests, and nothing that transmits
    let reqs = requests(&h);
    assert!(reqs.iter().all(|r| matches!(
        r,
        Request::Hello | Request::I2cXfer(_) | Request::SetTelemetry { period_ms: 500 } | Request::Cmd { addr: 0x0A, .. } | Request::Cmd { addr: 0x00, .. }
    )), "{reqs:?}");
    assert!(reqs.iter().all(|r| control::check_request(r, None).is_ok()));
    let hw = &h.msg.as_ref().unwrap().hw;
    assert_eq!((hw.tx_permit_writes, hw.bias_unlock_writes, hw.i2c_writes), (0, 0, 0));
    assert_eq!(s.stats.msg_refused, 0);
    assert_eq!(h.starved, 0, "the jumbo stream leaves room for every answer");
    assert_eq!(s.phase(), Phase::Streaming);
    assert_nothing_unexpected(&h);
}

#[test]
fn no_port_1027_answer_leaves_the_hl2_beside_a_1500_byte_stream() {
    // The cause of the silent port 1027 on the board: at 948 samples per frame the HL2 holds every
    // port 1027 answer until its stream stops. The session therefore asks before the start.
    let chip = MockFabric::new();
    let (mut s, mut h) = pair(&chip, false, SessionConfig::default());
    h.msg = Some(Hl2Sim::new(0xB007_0006));
    let t = run(&mut s, &mut h, 0, 5_000, |s, _| s.phase() == Phase::Streaming);
    assert_eq!(s.hl2_status().msg_layer, MsgLayer::Up, "HELLO was answered with the stream stopped");
    // the last thing on port 1027 before the start switched the telemetry off
    assert!(matches!(requests(&h).last(), Some(Request::SetTelemetry { period_ms: 0 })), "{:?}", requests(&h));
    let sent = h.msgs.len();
    let from_1027 = s.stats.p1027_n;
    // gain and filter go to port 1025 while streaming
    h.got.clear();
    s.set_rx_gain_db(15);
    s.on_action(&Action::Retune { dial_hz: 7_074_000 });
    let t = run(&mut s, &mut h, t, t + 3_000, |_, _| false);
    assert_eq!(h.got, [Got::Reg(0x0A, 0x40 + 15 + 12), Got::Reg(0x00, (1 << 23) | (1 << 19))]);
    assert_eq!(h.msgs.len(), sent, "nothing sent to port 1027 while streaming");
    assert_eq!(s.stats.p1027_n, from_1027, "nothing arrives from port 1027 while streaming");
    assert!(h.starved > 0 && !h.held.is_empty(), "the answer to the telemetry request waits in the HL2");
    assert_eq!(s.hl2_line(), "HL2 telemetry: off while streaming");
    // the held answers leave as soon as the stream stops
    s.stop(t);
    run(&mut s, &mut h, t, t + 100, |_, _| false);
    assert!(h.held.is_empty());
    assert_nothing_unexpected(&h);
}

#[test]
fn no_message_layer_falls_back_to_port_1025() {
    let chip = MockFabric::new();
    let (mut s, mut h) = pair(&chip, false, SessionConfig::default());
    let t0 = run(&mut s, &mut h, 0, 5_000, |s, _| s.phase() == Phase::Program);
    let t = run(&mut s, &mut h, t0, t0 + 6_000, |s, _| s.phase() == Phase::Streaming);
    // HELLO went unanswered for 3 s, then the stream started
    assert!(t - t0 >= 3_000 && t - t0 <= 3_300, "started after {} ms", t - t0);
    assert_eq!(s.hl2_status().msg_layer, MsgLayer::Absent);
    assert!(s.control().is_none());
    assert_eq!(s.hl2_line(), "HL2 telemetry: none (no message layer)");
    assert!(s.hl2_status().telemetry.is_none());
    let sent = h.msgs.len();
    assert!(requests(&h).iter().all(|r| matches!(r, Request::Hello | Request::I2cXfer(_))));
    // the gain goes as a port 1025 register write, as the set-up does
    h.got.clear();
    s.set_rx_gain_db(15);
    s.on_action(&Action::Retune { dial_hz: 7_074_000 });
    run(&mut s, &mut h, t, t + 2_000, |_, _| false);
    assert_eq!(h.got, [Got::Reg(0x0A, 0x40 + 15 + 12), Got::Reg(0x00, (1 << 23) | (1 << 19))]);
    assert_eq!(h.msgs.len(), sent);
    assert_nothing_unexpected(&h);
    // the next set-up uses the new gain, and asks again
    h.reboot();
    h.got.clear();
    run(&mut s, &mut h, t + 2_000, t + 12_000, |s, _| s.stats.link_losses == 1 && s.phase() == Phase::Streaming);
    assert!(h.regs().contains(&(0x0A, 0x40 + 15 + 12)), "{:?}", h.regs());
    assert!(h.msgs.len() > sent, "HELLO again on the new stream");
}

#[test]
fn rf_agc_drives_the_hl2_gain_through_the_message_layer() {
    use tr_station::rfagc::{AgcConfig, AgcMode, GainReason, LevelReading, RfAgc};
    let chip = MockFabric::new();
    let (mut s, mut h) = pair(&chip, false, jumbo());
    h.msg = Some(Hl2Sim::new(0xB007_0002));
    let mut t = run(&mut s, &mut h, 0, 6_000, |s, _| s.hl2_status().msg_layer == MsgLayer::Up && s.phase() == Phase::Streaming);
    let mut agc = RfAgc::new(SessionConfig::default().rx_gain_db, AgcConfig::default());
    agc.set_mode(AgcMode::Auto, t);
    let gain_cmds = |h: &FakeHl2| requests(h).iter().filter(|r| matches!(r, Request::Cmd { addr: 0x0A, .. })).count();
    // The band's level follows the gain the HL2 really has: -15 dBFS at 20 dB, so 5 dB too strong.
    let step = |s: &mut Session, h: &mut FakeHl2, agc: &mut RfAgc, t: &mut i64, at_0db: f32, ms: i64| {
        let end = *t + ms;
        while *t < end {
            *t += 10;
            h.step(*t);
            s.poll(*t);
            if *t % 30 == 0 {
                let g = (h.msg.as_ref().unwrap().hw.rx_gain & 0x7F) as i32 - 0x40 - 12;
                agc.on_level(*t, LevelReading { total_dbfs: at_0db + g as f32, peak_dbfs: -40.0, clamped: false });
            }
            if let Some(g) = agc.poll_write(*t) {
                s.set_rx_gain_db(g);
            }
        }
    };
    let before = gain_cmds(&h);
    step(&mut s, &mut h, &mut agc, &mut t, -35.0, 1_000);
    let g = (h.msg.as_ref().unwrap().hw.rx_gain & 0x7F) as i32 - 0x40 - 12;
    assert!(g <= 7 && g >= 5, "down to the target (-28 dBFS) at once: {g} dB");
    assert_eq!(agc.state().reason, GainReason::Overload);
    assert!(gain_cmds(&h) - before <= 3, "{} gain writes", gain_cmds(&h) - before);
    // quiet again: up 1 dB a second after the hang time, at most 4 writes a second
    let before = gain_cmds(&h);
    step(&mut s, &mut h, &mut agc, &mut t, -60.0, 10_000);
    let g2 = (h.msg.as_ref().unwrap().hw.rx_gain & 0x7F) as i32 - 0x40 - 12;
    assert!((g2 - g - 6).abs() <= 1, "{g} -> {g2} dB in 10 s");
    assert!(gain_cmds(&h) - before <= 7);
    assert_eq!(s.hl2_status().rx_gain_db, g2);
    // manual: holds whatever the band does
    agc.set_mode(AgcMode::Manual, t);
    step(&mut s, &mut h, &mut agc, &mut t, 0.0, 2_000);
    assert_eq!((h.msg.as_ref().unwrap().hw.rx_gain & 0x7F) as i32 - 0x40 - 12, g2);
    assert_nothing_unexpected(&h);
}

// ---- Updating the HL2's saved program -------------------------------------------------------

/// A stand-in for msg.bin (3,136 bytes like the real one): no code, just bytes the simulated CPU
/// recognizes as the program.
const fn program() -> [u8; 3_136] {
    let mut a = [0u8; 3_136];
    let mut x: u32 = 0x2468_ACE1;
    let mut i = 0;
    while i < a.len() {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        a[i] = x as u8;
        i += 1;
    }
    a
}
static PROGRAM: [u8; 3_136] = program();
/// Its CRC-32, as build.rs computes it.
const PROGRAM_CRC: u32 = {
    let mut c = !0u32;
    let mut i = 0;
    while i < PROGRAM.len() {
        c ^= PROGRAM[i] as u32;
        let mut k = 0;
        while k < 8 {
            c = if c & 1 != 0 { (c >> 1) ^ 0xEDB8_8320 } else { c >> 1 };
            k += 1;
        }
        i += 1;
    }
    !c
};
static IMAGE: Image<'static> = Image { bytes: &PROGRAM, version: FW_VERSION, crc32: PROGRAM_CRC };
const OLD_VERSION: u32 = 0x0003_0000;

fn with_program() -> SessionConfig {
    SessionConfig { hl2_program: Some(IMAGE), ..SessionConfig::default() }
}

fn update_datagrams(h: &FakeHl2) -> usize {
    h.msgs.iter().filter(|d| d[0] == 0x4E || d[0] == 0x01).count()
}

/// Runs until the stream is up, and checks that nothing reached port 1027 after the start command.
fn run_to_stream(s: &mut Session, h: &mut FakeHl2, from: i64, to: i64) -> i64 {
    let t = run(s, h, from, to, |s, _| s.phase() == Phase::Streaming);
    assert_eq!(s.phase(), Phase::Streaming, "{:?}", s.hl2_status());
    t
}

#[test]
fn up_to_date_nothing_is_written() {
    let chip = MockFabric::new();
    let (mut s, mut h) = pair(&chip, false, with_program());
    h.msg = Some(Hl2Sim::new(0xB007_0010));
    assert_eq!(PROGRAM_CRC, crc32(&PROGRAM));
    assert_eq!(s.hl2_status().program, ProgramState::Idle);
    let t = run_to_stream(&mut s, &mut h, 0, 6_000);
    assert_eq!(s.hl2_status().program, ProgramState::UpToDate);
    assert_eq!(s.hl2_line(), "HL2 program: up to date");
    assert!(s.hl2_report().contains("HL2 program up to date"), "{}", s.hl2_report());
    run(&mut s, &mut h, t, t + 3_000, |_, _| false);
    let cpu = &h.msg.as_ref().unwrap().cpu;
    assert_eq!((update_datagrams(&h), s.stats.updates, cpu.resets, cpu.saves, cpu.ram_writes), (0, 0, 0, 0, 0));
}

#[test]
fn an_outdated_program_is_updated_and_verified_before_the_stream_starts() {
    let chip = MockFabric::new();
    let (mut s, mut h) = pair(&chip, false, with_program());
    h.msg = Some(Hl2Sim::with_saved_version(0xB007_0011, OLD_VERSION, &PROGRAM));
    let t = run(&mut s, &mut h, 0, 5_000, |s, _| s.hl2_status().program == ProgramState::Updating);
    assert_eq!(s.hl2_line(), "HL2 program: updating");
    assert_eq!(s.status().0, "HL2: updating its program");
    let t = run_to_stream(&mut s, &mut h, t, t + 8_000);
    assert_eq!(s.hl2_status().program, ProgramState::Updated);
    assert_eq!(s.hl2_status().msg_layer, MsgLayer::Up);
    assert_eq!(s.hl2_line(), "HL2 program: updated");
    assert!(s.last_update_ms().is_some_and(|ms| ms < 2_000), "{:?}", s.last_update_ms());
    let sim = h.msg.as_ref().unwrap();
    assert_eq!(sim.cpu.flash.map(|f| (f.version, f.runs)), Some((FW_VERSION, true)));
    assert_eq!(sim.cpu.running_version, FW_VERSION);
    assert_eq!((sim.cpu.saves, sim.cpu.erases, sim.cpu.erase_datagrams, sim.cpu.forbidden_writes, sim.hw.tx_permit_writes), (1, 1, 0, 0, 0));
    assert_eq!((s.stats.updates, s.stats.update_refused), (1, 0));
    assert_eq!(update_datagrams(&h) as u32, s.stats.update_sent);
    requests(&h);
    // the stream started only after the update: no update datagram after the start command
    let n = update_datagrams(&h);
    run(&mut s, &mut h, t, t + 3_000, |_, _| false);
    assert_eq!(update_datagrams(&h), n);
    // a later stream start finds it up to date and writes nothing
    h.reboot();
    let t = run(&mut s, &mut h, t + 3_000, t + 6_000, |s, _| s.phase() != Phase::Streaming);
    let _ = s.take_link_lost();
    run_to_stream(&mut s, &mut h, t, t + 8_000);
    assert_eq!(update_datagrams(&h), n);
    assert_eq!(h.msg.as_ref().unwrap().cpu.saves, 1);
    assert_nothing_unexpected(&h);
}

#[test]
fn an_hl2_without_a_program_gets_it_saved() {
    let chip = MockFabric::new();
    let (mut s, mut h) = pair(&chip, false, with_program());
    h.msg = Some(Hl2Sim::without_program(0xB007_0012, &PROGRAM));
    // HELLO unanswered for 3 s, then the update
    let t = run_to_stream(&mut s, &mut h, 0, 12_000);
    assert_eq!(s.hl2_status().program, ProgramState::Updated);
    let sim = h.msg.as_ref().unwrap();
    assert!(sim.msg_running());
    assert_eq!(sim.cpu.flash.map(|f| f.version), Some(FW_VERSION));
    assert_eq!((sim.cpu.saves, sim.cpu.forbidden_writes, sim.cpu.ram_boots), (1, 0, 0));
    requests(&h);
    let _ = t;
    assert_nothing_unexpected(&h);
}

#[test]
fn an_image_that_fails_its_build_crc_is_never_sent() {
    let chip = MockFabric::new();
    let bad = Image { crc32: PROGRAM_CRC ^ 1, ..IMAGE };
    let (mut s, mut h) = pair(&chip, false, SessionConfig { hl2_program: Some(bad), ..SessionConfig::default() });
    h.msg = Some(Hl2Sim::with_saved_version(0xB007_0013, OLD_VERSION, &PROGRAM));
    run_to_stream(&mut s, &mut h, 0, 6_000);
    assert!(matches!(s.hl2_status().program, ProgramState::Failed(LoadError::ImageCrc { .. })), "{:?}", s.hl2_status().program);
    assert!(s.hl2_line().starts_with("HL2 program: failed: image CRC-32"), "{}", s.hl2_line());
    let cpu = &h.msg.as_ref().unwrap().cpu;
    assert_eq!((update_datagrams(&h), cpu.resets, cpu.ram_writes), (0, 0, 0));
}

#[test]
fn transmit_on_aborts_the_update_before_anything_is_written() {
    let chip = MockFabric::new();
    let (mut s, mut h) = pair(&chip, false, with_program());
    let mut sim = Hl2Sim::with_saved_version(0xB007_0014, OLD_VERSION, &PROGRAM);
    sim.hw.safety = hp::SAFETY_PA_KEYED;
    h.msg = Some(sim);
    run_to_stream(&mut s, &mut h, 0, 8_000);
    assert!(matches!(s.hl2_status().program, ProgramState::Failed(LoadError::TransmitOn { .. })), "{:?}", s.hl2_status().program);
    let cpu = &h.msg.as_ref().unwrap().cpu;
    assert_eq!((cpu.resets, cpu.ram_writes, cpu.saves, cpu.erases), (0, 0, 0, 0));
    assert_eq!(cpu.running_version, OLD_VERSION);
}

#[test]
fn a_flash_fault_is_reported_and_the_new_image_runs_from_ram() {
    let chip = MockFabric::new();
    let (mut s, mut h) = pair(&chip, false, with_program());
    let mut sim = Hl2Sim::with_saved_version(0xB007_0015, OLD_VERSION, &PROGRAM);
    sim.cpu.flash_fault = true;
    h.msg = Some(sim);
    run_to_stream(&mut s, &mut h, 0, 8_000);
    assert_eq!(s.hl2_status().program, ProgramState::Failed(LoadError::Save { code: cpuload::sys::FWR_FLASH_ERR }));
    assert_eq!(s.hl2_line(), "HL2 program: failed: save: flash error");
    assert_eq!(s.hl2_status().msg_layer, MsgLayer::Up, "the image runs from RAM and answers");
    let cpu = &h.msg.as_ref().unwrap().cpu;
    assert_eq!((cpu.flash, cpu.ram_boots, cpu.running_version), (None, 1, FW_VERSION));
}

#[test]
fn locked_flash_fails_clearly_and_never_more_than_two_tries_per_hl2_start() {
    let chip = MockFabric::new();
    let (mut s, mut h) = pair(&chip, false, with_program());
    let mut sim = Hl2Sim::with_saved_version(0xB007_0016, OLD_VERSION, &PROGRAM);
    sim.cpu.locked = true;
    h.msg = Some(sim);
    let mut t = 0;
    for stream in 1..=MAX_UPDATE_ATTEMPTS as u32 + 2 {
        t = run_to_stream(&mut s, &mut h, t, t + 10_000);
        assert_eq!(s.stats.updates, stream.min(MAX_UPDATE_ATTEMPTS as u32), "stream {stream}");
        assert_eq!(s.hl2_status().program, ProgramState::Failed(LoadError::Save { code: cpuload::sys::FWR_LOCKED }));
        assert!(s.hl2_line().starts_with("HL2 program: failed: save: flash locked"), "{}", s.hl2_line());
        assert_eq!(s.hl2_status().msg_layer, MsgLayer::Up, "the old program runs again");
        // the stream is lost (no DHCP: no new HL2 start is seen)
        h.reboot();
        t = run(&mut s, &mut h, t, t + 3_000, |s, _| s.phase() != Phase::Streaming);
        let _ = s.take_link_lost();
    }
    let cpu = &h.msg.as_ref().unwrap().cpu;
    assert_eq!((cpu.saves, cpu.erases, cpu.erase_datagrams, cpu.forbidden_writes), (MAX_UPDATE_ATTEMPTS as u32, 0, 0, 0));
    assert_eq!(cpu.running_version, OLD_VERSION);
    requests(&h);
    assert_nothing_unexpected(&h);
}

#[test]
fn forbidden_datagrams_never_leave() {
    // Message-layer datagrams the policy refuses: the whitelist stops each one.
    let build = |reqs: &[(u8, u8, &[u8])]| {
        let mut d = vec![0u8; msg::HDR_SIZE];
        for (i, (c, o, b)) in reqs.iter().enumerate() {
            let mut m = vec![0u8; msg::MSG_HDR_SIZE + b.len()];
            msg::put_message(&mut m, *c, *o, i as u16, b).unwrap();
            d.extend_from_slice(&m);
        }
        let len = (d.len() - msg::HDR_SIZE) as u16;
        msg::Header { flags: msg::F_RELIABLE, len, ..Default::default() }.write(&mut d);
        d
    };
    let ok = build(&[(msg::class::SYS, msg::op::HELLO, &[])]);
    assert!(msg_datagram_allowed(&ok));
    for bad in [
        build(&[(msg::class::RF, 1, &[1])]),                                            // transmit permission
        build(&[(msg::class::RF, 3, &[0x54, 0x58])]),                                   // bias unlock
        build(&[(msg::class::RF, msg::op::CMD, &[0x09, 0, 0x08, 0, 0])]),               // PA enable
        build(&[(msg::class::RF, msg::op::CMD, &[0x31, 0, 0, 0, 2])]),                  // real DAC
        build(&[(msg::class::REG, msg::op::WRITE, &[0x40, 0x04, 0, 0x00, 0, 0, 0, 1])]), // a register outside LED and FAN
        build(&[(msg::class::I2C, msg::op::I2C_XFER, &[2, 0x2C, 0, 0, 0x80])]),          // bias pot
        build(&[(msg::class::I2C, msg::op::I2C_XFER, &[2, 0x1D, 0, 0, 1])]),             // IO board
        build(&[(msg::class::SYS, msg::op::HELLO, &[]), (msg::class::RF, msg::op::CMD, &[0x3A, 0, 0, 0, 1])]),
    ] {
        assert!(!msg_datagram_allowed(&bad), "{bad:02x?}");
    }
    // register bridge: never through the message-layer whitelist, read or write
    assert!(!msg_datagram_allowed(&[0x4E, 0x6F, 0x10, 0x44, 0, 0, 0, 0]));
    // the update whitelist: the save of exactly the embedded image, nothing else for the boot ROM
    assert!(update_datagram_allowed(&cpuload::build_save_datagram(&IMAGE), &IMAGE));
    assert!(!update_datagram_allowed(&[0x01, b'E'], &IMAGE), "erase");
    assert!(!update_datagram_allowed(&cpuload::build_save_datagram(&Image { version: OLD_VERSION, ..IMAGE }), &IMAGE));
    assert!(!update_datagram_allowed(&ok, &IMAGE), "message-layer datagrams do not pass here");
    // and no bridge write to the flash sector, the packet interface or the front end
    let mut b = [0u8; 64];
    for a in [0x4003_0000u32, 0x4003_0004, 0x4003_0008, 0x4002_0008, 0x4004_0004, 0x4004_0030] {
        let n = tr_hl2::bridge::build_write_read(a, &[1], &[], &mut b);
        assert!(n.is_none_or(|n| !update_datagram_allowed(&b[..n], &IMAGE)), "0x{a:08x}");
    }
}
