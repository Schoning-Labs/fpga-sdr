// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The HL2 control client (`control`, `msg`) against the simulated HL2 (`sim`).

use tr_hl2::bridge::{frontend, status};
use tr_hl2::control::{cutoff, ControlError, Hl2Control, Refusal};
use tr_hl2::filter::{self, Band};
use tr_hl2::msg::{self, Completion, Header, I2cOutcome, Limits, MsgError, Request, Response, Status, Tag};
use tr_hl2::sim::{Bench, Hl2Sim};

const BOOT: u32 = 0xB007_0001;

/// A bench plus the completions that arrived while waiting for another tag.
struct Rig {
    b: Bench,
    done: Vec<Completion>,
}

impl std::ops::Deref for Rig {
    type Target = Bench;
    fn deref(&self) -> &Bench {
        &self.b
    }
}
impl std::ops::DerefMut for Rig {
    fn deref_mut(&mut self) -> &mut Bench {
        &mut self.b
    }
}

/// Runs until the completion with `tag` arrives.
fn wait(r: &mut Rig, tag: Tag, max_ms: u32) -> Completion {
    let done = &mut r.done;
    let ok = r.b.run_until(max_ms, |b| {
        while let Some(c) = b.client.poll_completion() {
            done.push(c);
        }
        done.iter().any(|c| c.tag == tag)
    });
    assert!(ok, "no completion for tag {tag} within {max_ms} ms");
    let i = r.done.iter().position(|c| c.tag == tag).unwrap();
    r.done.remove(i)
}

fn ok(r: &mut Rig, tag: Tag) -> Response {
    let c = wait(r, tag, 5000);
    c.result.unwrap_or_else(|e| panic!("request {:?} failed: {e:?}", c.request))
}

/// A bench whose session is up (the HELLO queued by `Hl2Control::new` answered).
fn started(seed: u32) -> Rig {
    let mut b = Bench::new(seed, BOOT);
    assert!(b.run_until(1000, |b| b.client.poll_completion().is_some()));
    Rig { b, done: Vec::new() }
}

#[test]
fn session_start_and_hello() {
    let mut b = Bench::new(7, BOOT);
    assert!(!b.radio.session());
    let mut hello = None;
    assert!(b.run_until(1000, |b| {
        hello = b.client.poll_completion();
        hello.is_some()
    }));
    assert!(b.radio.session());
    match hello.unwrap().result {
        Ok(Response::Hello(h)) => {
            assert_eq!(h.protocol, 1);
            assert_eq!(h.firmware_version, 0x0003_0001);
            assert_eq!(h.gateware_version, 0x4A02_D101);
            assert_eq!(h.capabilities, 0x7C);
            assert_eq!(h.max_payload, 240);
            assert_eq!(h.telemetry_period_ms, 100);
            assert_eq!(h.io_id, frontend::ID_EXPECTED);
        }
        r => panic!("{r:?}"),
    }
    assert_eq!(b.client.msg().boot_id(), Some(BOOT));
}

#[test]
fn ping_echoes() {
    let mut b = started(11);
    let t = b.client.ping(b"hello hl2").unwrap();
    match ok(&mut b, t) {
        Response::Ping(p) => assert_eq!(p.as_slice(), b"hello hl2"),
        r => panic!("{r:?}"),
    }
    assert_eq!(b.client.ping(&[0; 33]), Err(ControlError::Refused(Refusal::BadArgument)));
}

#[test]
fn telemetry_stream() {
    let mut b = started(13);
    let first = b.client.msg().stats().telemetry;
    b.run(1000);
    let n = b.client.msg().stats().telemetry - first;
    assert!((9..=11).contains(&n), "{n} telemetry packets in 1 s at 100 ms");

    let t = b.client.telemetry().unwrap();
    assert!((t.temperature_c() - 25.0).abs() < 0.2);
    assert_eq!(t.safety(), tr_hl2::protocol::SAFETY_IDLE);
    let ilk = t.interlock();
    assert!(!ilk.tx_on && !ilk.lease_valid && ilk.cutoff_present);
    assert_eq!(ilk.cutoffs, cutoff::NO_LEASE);
    assert!(!t.inputs().key);

    b.radio.hw.bias_code = 1000;
    let tag = b.client.set_telemetry_period(20).unwrap();
    ok(&mut b, tag);
    let first = b.client.msg().stats().telemetry;
    b.run(1000);
    let n = b.client.msg().stats().telemetry - first;
    assert!((49..=51).contains(&n), "{n} telemetry packets in 1 s at 20 ms");
    assert!((b.client.telemetry().unwrap().bias_current_a() - 0.398).abs() < 0.001);
}

#[test]
fn events_delivered_once_and_acknowledged() {
    let mut b = started(17);
    b.run(100);
    // The first event after the firmware starts reports the idle state.
    let e = b.client.poll_event().expect("initial event");
    assert_eq!(e.ilk_status, tr_hl2::sim::ILK_IDLE);
    assert!(b.client.poll_event().is_none());

    // Lose half of the acknowledgements: the radio repeats, the client delivers once.
    b.up.loss_pct = 50;
    b.radio.hw.inputs |= 1 << 18; // TX inhibit, debounced
    b.run(2000);
    let e = b.client.poll_event().expect("inhibit event");
    assert_eq!(e.inputs & (1 << 18), 1 << 18);
    assert!(b.client.poll_event().is_none());
    assert_eq!(b.client.msg().stats().events, 2);
}

#[test]
fn loss_duplication_reordering() {
    let mut b = started(19);
    for l in [&mut b.b.up, &mut b.b.down] {
        l.loss_pct = 20;
        l.dup_pct = 10;
        l.reorder_pct = 10;
    }
    let before = b.radio.executed;
    let mut sent = 0;
    for round in 0..5u8 {
        let mut tags = Vec::new();
        for i in 0..4u8 {
            let data = [round, i, 0x55];
            tags.push((b.client.ping(&data).unwrap(), data));
            sent += 1;
        }
        for (t, data) in tags {
            match ok(&mut b, t) {
                Response::Ping(p) => assert_eq!(p.as_slice(), &data),
                r => panic!("{r:?}"),
            }
        }
    }
    assert!(b.client.msg().stats().retransmits > 0);
    // Every request executed exactly once despite repeats and duplicates.
    assert_eq!(b.radio.executed - before, sent);
}

#[test]
fn requests_share_one_datagram() {
    let mut b = started(23);
    let sent0 = b.client_sent;
    let tags: Vec<Tag> = (0..8).map(|i| b.client.ping(&[i]).unwrap()).collect();
    assert_eq!(b.client.ping(&[9]), Err(ControlError::QueueFull));
    for t in tags {
        ok(&mut b, t);
    }
    assert_eq!(b.client_sent - sent0, 1);
}

#[test]
fn boot_id_change_restarts_session() {
    let mut b = started(29);
    b.radio.reboot(0xB007_0002);
    assert!(!b.radio.session());
    let t = b.client.ping(b"again").unwrap();
    ok(&mut b, t);
    assert_eq!(b.client.msg().restarts(), 1);
    assert_eq!(b.client.msg().boot_id(), Some(0xB007_0002));
    assert!(b.radio.session());
    let n = b.client.msg().stats().telemetry;
    b.run(300);
    assert!(b.client.msg().stats().telemetry > n);
}

#[test]
fn stale_cache_from_previous_client_is_not_taken() {
    let mut b = started(0x0001_0005);
    let executed = b.radio.executed;
    // A new client whose first sequence number equals the radio's current one, with other tags.
    b.client = Hl2Control::new(0x0002_0005);
    let mut c = None;
    assert!(b.run_until(1000, |b| {
        c = b.client.poll_completion();
        c.is_some()
    }));
    assert!(matches!(c.unwrap().result, Ok(Response::Hello(_))));
    // HELLO and the filter latch read of the new session, executed once each
    assert_eq!(b.radio.executed, executed + 2);
}

#[test]
fn filter_set_and_read_back_over_i2c() {
    let mut b = started(31);
    for band in [Band::B160m, Band::B80m, Band::B60_40m, Band::B30_20m, Band::B17_15m, Band::B12_10m] {
        let t = b.client.set_band_filter(band).unwrap();
        assert_eq!(ok(&mut b, t), Response::Cmd);
        let t = b.client.read_filter_latch().unwrap();
        match ok(&mut b, t) {
            Response::I2cXfer { outcome: I2cOutcome::Ok, data } => {
                assert_eq!(data as u8, filter::expected_olat(filter::band_filter_bits(band)));
            }
            r => panic!("{r:?}"),
        }
    }
    let t = b.client.set_rx_antenna(true).unwrap();
    ok(&mut b, t);
    let t = b.client.read_filter_latch().unwrap();
    match ok(&mut b, t) {
        Response::I2cXfer { data, .. } => assert_eq!(data as u8, filter::expected_olat(filter::band_filter_bits(Band::B12_10m)) | 0x80),
        r => panic!("{r:?}"),
    }
    assert_eq!(b.radio.hw.reg0, filter::band_filter_bits(Band::B12_10m) | filter::BIT_RX_ANTENNA);
}

#[test]
fn frontend_shadow_seeded_from_the_latch() {
    // A PC client left the 40 m filter and the RX antenna on before this session started.
    let mut b = Bench::new(33, BOOT);
    b.radio.hw.command(0x00, filter::band_filter_bits(Band::B60_40m) | filter::BIT_RX_ANTENNA);
    let before = b.radio.hw.cmd_log_len;
    assert!(b.client.frontend_seed_pending());
    assert!(b.run_until(1000, |b| {
        while b.client.poll_completion().is_some() {}
        !b.client.frontend_seed_pending()
    }));
    assert_eq!(b.client.frontend_reg(), filter::band_filter_bits(Band::B60_40m) | filter::BIT_RX_ANTENNA);
    // the first filter call keeps the antenna relay
    let mut r = Rig { b, done: Vec::new() };
    let t = r.client.set_band_filter(Band::B30_20m).unwrap();
    ok(&mut r, t);
    assert_eq!(r.radio.hw.reg0, filter::band_filter_bits(Band::B30_20m) | filter::BIT_RX_ANTENNA);
    assert_eq!(r.radio.hw.cmd_log_len, before + 1, "the seed read itself writes nothing");
}

#[test]
fn rx_gain_set_and_read_back() {
    let mut b = started(37);
    let t = b.client.set_rx_gain_db(20).unwrap();
    ok(&mut b, t);
    // Message layer: the command bus registers show the last command.
    let t = b.client.read_register(frontend::CMD_DATA, 2).unwrap();
    match ok(&mut b, t) {
        Response::Read(v) => {
            assert_eq!(v.as_slice()[0], 0x40 + 12 + 20);
            assert_eq!(v.as_slice()[1] & 0x3F, 0x0A);
        }
        r => panic!("{r:?}"),
    }
    // The status block RX_GAIN register is not in the CPU's mirror: unmapped there.
    let t = b.client.read_register(status::RX_GAIN, 1).unwrap();
    match ok(&mut b, t) {
        Response::Read(v) => assert_eq!(v.as_slice()[0], 0xFFFF_FFFF),
        r => panic!("{r:?}"),
    }
    // The bridge reads it.
    b.client.request_rx_gain_readback();
    assert!(b.run_until(100, |b| b.client.rx_gain_readback().is_some()));
    assert_eq!(b.client.rx_gain_readback(), Some(Some(20)));
    assert_eq!(b.client.set_rx_gain_db(49), Err(ControlError::Refused(Refusal::BadArgument)));
    assert_eq!(b.client.set_rx_gain_db(-13), Err(ControlError::Refused(Refusal::BadArgument)));
}

#[test]
fn forbidden_operations_are_refused_and_send_nothing() {
    let mut b = started(41);
    b.run(50);
    let mut buf = [0u8; 512];
    let c = &mut b.b.client;
    let refused = |r: Result<Tag, ControlError>| matches!(r, Err(ControlError::Refused(_)));

    // Command bus: transmit configuration, TX-time LNA gain, real DAC, reboot, AD9866, I2C.
    for (a, v) in [(0x09u8, 1u32 << 19), (0x09, 0xF000_0000), (0x0E, 0), (0x31, 3), (0x3A, 1), (0x3B, 0x0600_0000), (0x3C, 0), (0x3D, 0), (0x30, 1), (0x01, 7_074_000)] {
        assert_eq!(c.msg_mut().submit(Request::Cmd { addr: a, value: v }), Err(msg::SubmitError::Refused(Refusal::Command { addr: a })));
    }
    assert!(refused(c.msg_mut().submit(Request::Cmd { addr: 0x00, value: 1 << 24 }).map_err(Into::into)));
    assert!(refused(c.msg_mut().submit(Request::Cmd { addr: 0x0A, value: 0x7D }).map_err(Into::into)));
    assert!(refused(c.set_filter_bits(filter::BIT_RX_ANTENNA)));
    assert!(refused(c.set_filter_bits(1 << 24)));

    // Register writes outside LED and FAN.
    for a in [
        frontend::TX_PERMIT,
        frontend::BIAS_UNLOCK,
        frontend::CMD_DATA,
        frontend::CMD_ADDR,
        frontend::WDOG,
        frontend::WDOG_MS,
        frontend::WDOG_DISARM,
        frontend::ILK_CLEAR,
        frontend::LEASE_MS,
        frontend::MAXKEY_S,
        frontend::TEMP_LIMIT,
        frontend::I2C_XFER,
        0x4001_0008, // CPU control
        0x4003_0008, // flash command
        0x0000_0800, // firmware RAM
    ] {
        assert_eq!(c.write_register(a, 0x5458_0001), Err(ControlError::Refused(Refusal::RegisterWrite { addr: a })));
    }

    // Bias pots and EEPROM.
    assert_eq!(c.i2c_write(2, 0x2C, 0x00, 0x80), Err(ControlError::Refused(Refusal::BiasGuard)));
    assert_eq!(c.i2c_read(2, 0x2C, 0x04), Err(ControlError::Refused(Refusal::BiasGuard)));
    assert_eq!(c.i2c_read(2, 0x2C, 0x08), Err(ControlError::Refused(Refusal::BiasGuard)));
    // N2ADR Pico IO board: no writes.
    assert_eq!(c.i2c_write(2, 0x1D, 0x00, 0x01), Err(ControlError::Refused(Refusal::IoBoard)));
    assert!(refused(c.i2c_read(0, 0x20, 0)));
    assert!(refused(c.i2c_write(4, 0x20, 0, 0)));
    assert!(refused(c.i2c_scan(2, 10, 5)));
    assert!(refused(c.i2c_scan(2, 0, 128)));
    assert!(refused(c.read_register(0, 0)));
    assert!(refused(c.read_register(0, 33)));
    assert_eq!(c.set_limits(Limits { lease_ms: 50, maxkey_s: 0, temp_code: 0 }), Err(ControlError::Refused(Refusal::LimitsUnknown)));

    assert!(c.msg().is_idle());
    let now = b.now + 1;
    assert_eq!(b.client.poll_transmit(now, &mut buf), None);
    let executed = b.radio.executed;
    b.run(500);
    assert_eq!(b.radio.executed, executed);
    let hw = &b.b.radio.hw;
    assert_eq!((hw.tx_permit_writes, hw.bias_unlock_writes, hw.i2c_writes, hw.cmd_log_len), (0, 0, 0, 0));
}

#[test]
fn allowed_register_writes_and_reads() {
    let mut b = started(43);
    let t = b.client.write_register(frontend::FAN, 15).unwrap();
    assert_eq!(ok(&mut b, t), Response::Write { words: 1 });
    let t = b.client.write_register(frontend::LED, 0xF1).unwrap();
    ok(&mut b, t);
    let t = b.client.read_register(frontend::LED, 2).unwrap();
    match ok(&mut b, t) {
        Response::Read(v) => assert_eq!(v.as_slice(), &[0xF1, 15]),
        r => panic!("{r:?}"),
    }
    let t = b.client.read_register(status::ID, 1).unwrap();
    match ok(&mut b, t) {
        Response::Read(v) => assert_eq!(v.as_slice(), &[status::ID_EXPECTED]),
        r => panic!("{r:?}"),
    }
    let t = b.client.clear_trips().unwrap();
    assert_eq!(ok(&mut b, t), Response::ClearTrips { ilk_status: tr_hl2::sim::ILK_IDLE });
    assert_eq!(b.radio.hw.trips_cleared, 1);
}

#[test]
fn limits_only_stricter() {
    let mut b = started(47);
    let t = b.client.read_limits().unwrap();
    assert_eq!(ok(&mut b, t), Response::Limits(Limits { lease_ms: 100, maxkey_s: 600, temp_code: 0x527 }));

    let looser = [
        Limits { lease_ms: 101, maxkey_s: 0, temp_code: 0 },
        Limits { lease_ms: 0, maxkey_s: 601, temp_code: 0 },
        Limits { lease_ms: 0, maxkey_s: 0, temp_code: 0x528 },
        Limits { lease_ms: 9, maxkey_s: 0, temp_code: 0 },
    ];
    for l in looser {
        assert_eq!(b.client.set_limits(l), Err(ControlError::Refused(Refusal::LimitsLooser)));
    }
    let t = b.client.set_limits(Limits { lease_ms: 50, maxkey_s: 10, temp_code: 0x400 }).unwrap();
    assert_eq!(ok(&mut b, t), Response::Limits(Limits { lease_ms: 50, maxkey_s: 10, temp_code: 0x400 }));
    assert_eq!((b.radio.hw.lease_ms, b.radio.hw.maxkey_s, b.radio.hw.temp_limit), (50, 10, 0x400));
    // The new values are the new ceiling.
    assert_eq!(b.client.set_limits(Limits { lease_ms: 60, maxkey_s: 0, temp_code: 0 }), Err(ControlError::Refused(Refusal::LimitsLooser)));
    let t = b.client.set_limits(Limits { lease_ms: 0, maxkey_s: 5, temp_code: 0 }).unwrap();
    ok(&mut b, t);
    assert_eq!(b.radio.hw.maxkey_s, 5);
}

#[test]
fn status_codes_and_i2c_outcomes() {
    let mut b = started(53);
    b.radio.hw.cmd_busy = true;
    let t = b.client.set_rx_gain_db(0).unwrap();
    assert_eq!(wait(&mut b, t, 1000).result, Err(MsgError::Status(Status::Busy)));
    b.radio.hw.cmd_busy = false;

    let t = b.client.i2c_read(2, 0x55, 0).unwrap();
    assert!(matches!(ok(&mut b, t), Response::I2cXfer { outcome: I2cOutcome::Nack, .. }));
    b.radio.hw.i2c_drop_next = true;
    let t = b.client.i2c_read(2, 0x20, 0x0A).unwrap();
    assert!(matches!(ok(&mut b, t), Response::I2cXfer { outcome: I2cOutcome::Dropped, .. }));
    let t = b.client.i2c_probe(2, 0x2C).unwrap();
    assert!(matches!(ok(&mut b, t), Response::I2cXfer { outcome: I2cOutcome::Ok, .. }));
    let t = b.client.i2c_read(2, 0x2C, 0x0C).unwrap();
    assert!(matches!(ok(&mut b, t), Response::I2cXfer { outcome: I2cOutcome::Ok, data: 0x8080_8080 }));
    let t = b.client.i2c_scan(2, 0, 127).unwrap();
    match ok(&mut b, t) {
        Response::I2cScan(m) => {
            let found: Vec<u8> = (0..128u8).filter(|a| m[*a as usize / 8] & (1 << (a % 8)) != 0).collect();
            assert_eq!(found, vec![0x20, 0x2C]);
        }
        r => panic!("{r:?}"),
    }
    // Write and read back a VersaClock register on bus 1.
    let t = b.client.i2c_write(1, 0x6A, 0x10, 0xA5).unwrap();
    ok(&mut b, t);
    let t = b.client.i2c_read(1, 0x6A, 0x10).unwrap();
    assert!(matches!(ok(&mut b, t), Response::I2cXfer { outcome: I2cOutcome::Ok, data } if data as u8 == 0xA5));
}

#[test]
fn timeout_when_radio_is_silent() {
    let mut b = started(59);
    b.down.loss_pct = 100;
    let t = b.client.ping(b"x").unwrap();
    assert_eq!(wait(&mut b, t, 4000).result, Err(MsgError::Timeout));
    // The link comes back: the next request starts over with the reset flag and works.
    b.down.loss_pct = 0;
    let t = b.client.ping(b"y").unwrap();
    ok(&mut b, t);
}

/// The simulated firmware itself, with raw datagrams: status codes the client never provokes.
#[test]
fn sim_answers_like_the_firmware() {
    let mut r = Hl2Sim::new(BOOT);
    let mut d = [0u8; 64];
    let mut p = 0;
    for (c, o, body) in [(9u8, 1u8, &[][..]), (1, 1, &[0, 0, 0][..]), (1, 2, &[0, 8, 0, 0, 1, 0, 0, 0][..]), (0, 3, &[1][..])] {
        p += msg::put_message(&mut d[16 + p..], c, o, 0x100 + c as u16, body).unwrap();
    }
    Header { flags: msg::F_RELIABLE | msg::F_RESET, boot_id: 0, seq: 40, ack: 0, len: p as u16 }.write(&mut d);
    r.input(1, &d[..16 + p]);
    let out = r.pop_output().unwrap();
    let (h, payload) = Header::parse(out.as_slice()).unwrap();
    assert_eq!((h.boot_id, h.seq, h.ack, h.flags), (BOOT, 0, 40, msg::F_ACK_VALID));
    let st: Vec<(u8, u8, u8)> = msg::messages(payload).map(|m| (m.class, m.op, m.body[0])).collect();
    assert_eq!(st, vec![(9, 0x81, 0x10), (1, 0x81, 0x11), (1, 0x82, 0x12), (0, 0x83, 0x11)]);

    // A repeat gets the cached response and executes nothing; an old sequence gets a bare ack.
    let ex = r.executed;
    r.input(2, &d[..16 + p]);
    assert_eq!(r.pop_output().unwrap().as_slice(), out.as_slice());
    assert_eq!(r.executed, ex);
    Header { flags: msg::F_RELIABLE, boot_id: 0, seq: 30, ack: 0, len: 0 }.write(&mut d);
    r.input(3, &d[..16]);
    let bare = r.pop_output().unwrap();
    assert_eq!(bare.len, 16);
    assert_eq!(Header::parse(bare.as_slice()).unwrap().0.ack, 40);
}
