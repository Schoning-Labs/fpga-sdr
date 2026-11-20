// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Tests against a live HL2. They are `#[ignore]` by default, so `tools/check.sh` (`cargo test`)
//! never needs the radio. The normal way to run them by hand is the `hl2ctl` binary
//! (`src/bin/hl2ctl.rs`), which prints a fuller report (see "How to run" in `docs/S1_HL2.md`),
//! and these tests exist next to it so that the same checks can also run under plain
//! `cargo test, --ignored`, which is useful for scripts and CI once the board is on the bench.
//!
//! They need two environment variables, with no defaults so that a wrong guess cannot silently
//! target the wrong host:
//!   HL2_IP        the HL2's IP address (from `hl2ctl discover`)
//!   HL2_IFACE_IP  this PC's IP address on the NIC that is cabled directly to the HL2
//!
//! Safety: like the rest of this crate, nothing here sets the transmit key bit or the real-DAC
//! bit, or touches the flash sector.

use std::env;
use std::net::IpAddr;
use std::time::Duration;
use tr_hl2::pc::{self, capture::CaptureOptions};
use tr_hl2::{bridge, filter};

fn hl2_ip() -> Option<IpAddr> {
    env::var("HL2_IP").ok().and_then(|s| s.parse().ok())
}

fn iface_ip() -> Option<IpAddr> {
    env::var("HL2_IFACE_IP").ok().and_then(|s| s.parse().ok())
}

#[test]
#[ignore = "needs a real HL2 on HL2_IP, reachable from HL2_IFACE_IP"]
fn status_read() {
    let ip = hl2_ip().expect("set HL2_IP");
    let bc = pc::BridgeClient::connect(ip).expect("connect");
    let s = bc.read_status_block().expect("read status block");
    assert_eq!(s.id, bridge::status::ID_EXPECTED, "status block ID should read \"HL2B\"");
    // capabilities bit 6: front-end register block present (needed for the filter test below)
    assert_eq!(s.capabilities & (1 << 6), 1 << 6, "front-end register block capability should be set");
}

#[test]
#[ignore = "needs a real HL2 on HL2_IP, reachable from HL2_IFACE_IP"]
fn ten_second_stream_zero_gaps() {
    let ip = hl2_ip().expect("set HL2_IP");
    let iface = iface_ip().expect("set HL2_IFACE_IP");
    let client = pc::Hl2Client::new(ip);
    client.clear_raw_mode().unwrap();
    client.set_raw_mode(true, false, false, 5968).unwrap();

    let sock = pc::socket::open_stream_socket(iface, pc::socket::DEFAULT_RCVBUF).unwrap();
    pc::client::send_start(&sock, ip).unwrap();
    let (stats, _) = pc::capture::run(sock.try_clone().unwrap(), CaptureOptions { seconds: 10.0, sample_cap: None }).unwrap();
    pc::client::send_stop(&sock, ip).unwrap();
    client.clear_raw_mode().unwrap();

    assert!(stats.frames > 0, "no frames received at all");
    assert_eq!(stats.lost_frames, 0, "sequence-number gaps: {stats:?}");
    assert_eq!(stats.lost_samples, 0, "sample-index gaps: {stats:?}");
    assert_eq!(stats.reordered_or_dup, 0, "reordered/duplicate frames: {stats:?}");
}

#[test]
#[ignore = "needs a real HL2 on HL2_IP, reachable from HL2_IFACE_IP"]
fn filter_bits_read_back_over_i2c() {
    let ip = hl2_ip().expect("set HL2_IP");
    let client = pc::Hl2Client::new(ip);
    let value = filter::band_filter_bits(filter::Band::B80m);
    client.set_frontend(value).unwrap();
    std::thread::sleep(Duration::from_millis(50));

    let bc = pc::BridgeClient::connect(ip).unwrap();
    let olat = bc.i2c_read_register(filter::MCP23008_I2C_BUS, filter::MCP23008_I2C_ADDR, filter::MCP23008_OLAT_REG).unwrap();
    assert_eq!(olat, filter::expected_olat(value), "MCP23008 output latch should match register 0x00's filter bits");

    client.set_frontend(0).unwrap(); // leave the board in a known state
}
