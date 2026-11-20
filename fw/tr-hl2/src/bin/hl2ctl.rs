// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Manual test tool for `tr-hl2` against a real HL2 (see "How to run" in `docs/S1_HL2.md`). It has
//! no dependency beyond `socket2` (the `std` feature dependency of `tr-hl2`), and the arguments
//! are parsed by hand, like in the other PC tools of this repository (`rawcap`).
//!
//! Subcommands: `discover`, `status`, `stream`, `filter`, `amband`, and `done-test`, which runs all
//! of the others in the order in which `docs/PLAN.md` lists them.

use std::fs::File;
use std::io::Write as _;
use std::net::IpAddr;
use std::process::ExitCode;
use std::time::Duration;
use tr_hl2::pc::{self, capture::CaptureOptions};
use tr_hl2::{bridge, filter};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(cmd) = args.first().map(|s| s.as_str()) else {
        print_usage();
        return ExitCode::FAILURE;
    };
    let rest = &args[1..];
    let result = match cmd {
        "discover" => cmd_discover(rest),
        "status" => cmd_status(rest),
        "stream" => cmd_stream(rest),
        "filter" => cmd_filter(rest),
        "amband" => cmd_amband(rest),
        "capture" => cmd_capture(rest),
        "done-test" => cmd_done_test(rest),
        _ => {
            print_usage();
            return ExitCode::FAILURE;
        }
    };
    match result {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => ExitCode::FAILURE,
        Err(e) => {
            eprintln!("hl2ctl: error: {e}");
            ExitCode::FAILURE
        }
    }
}

fn print_usage() {
    eprintln!(
        "usage: hl2ctl <discover|status|stream|filter|amband|done-test> [options]\n\
         \n\
         discover  --iface-ip <ip>\n\
         status    --ip <hl2-ip>\n\
         stream    --ip <hl2-ip> --iface-ip <ip> [--seconds N] [--samples-per-frame N]\n\
         filter    --ip <hl2-ip> --band 160m|80m|60-40m|30-20m|17-15m|12-10m|off [--antenna]\n\
         amband    --ip <hl2-ip> --iface-ip <ip> [--seconds N]\n\
         capture   --ip <hl2-ip> --iface-ip <ip> --out <file> [--seconds N] [--gain-db N]\n\
         done-test --ip <hl2-ip> --iface-ip <ip>"
    );
}

fn arg_value(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned()
}

fn has_flag(args: &[String], name: &str) -> bool {
    args.iter().any(|a| a == name)
}

fn parse_ip(args: &[String], name: &str) -> IoResult<IpAddr> {
    arg_value(args, name)
        .ok_or_else(|| format!("missing {name}"))?
        .parse()
        .map_err(|e| format!("bad {name}: {e}"))
}

type IoResult<T> = Result<T, String>;

// ---- discover -------------------------------------------------------------------------------
fn cmd_discover(args: &[String]) -> IoResult<bool> {
    let iface_ip = parse_ip(args, "--iface-ip")?;
    let found = pc::discover::discover(iface_ip, Duration::from_secs(2)).map_err(|e| e.to_string())?;
    if found.is_empty() {
        println!("hl2ctl: no HL2 found on {iface_ip} within 2 s");
        return Ok(false);
    }
    for d in &found {
        let r = &d.response;
        println!(
            "hl2ctl: found {} mac {} gateware {}.{} image-marker 0x{:02X} ({}) receivers {} board-id {} {}",
            d.ip,
            pc::discover::mac_string(&r.mac),
            r.gateware_major,
            r.gateware_minor,
            r.image_marker,
            if r.is_rawfront_image() { "raw front-end" } else { "NOT the raw front-end image" },
            r.receivers,
            r.board_id,
            if r.running { "running" } else { "stopped" }
        );
    }
    Ok(true)
}

// ---- status ----------------------------------------------------------------------------------
fn cmd_status(args: &[String]) -> IoResult<bool> {
    let ip = parse_ip(args, "--ip")?;
    print_status(ip).map_err(|e| e.to_string())
}

fn print_status(ip: IpAddr) -> std::io::Result<bool> {
    let bc = pc::BridgeClient::connect(ip)?;
    let s = bc.read_status_block()?;
    let id_ok = s.id == bridge::status::ID_EXPECTED;
    println!("hl2ctl: status block ID 0x{:08X} ({})", s.id, if id_ok { "matches \"HL2B\"" } else { "UNEXPECTED" });
    println!("hl2ctl: version word 0x{:08X}", s.version);
    println!(
        "hl2ctl: capabilities 0x{:02X} (receivers={} tx={} raw={} duplex={} aux={} cpu={} frontend-block={})",
        s.capabilities,
        s.capabilities & 1,
        (s.capabilities >> 1) & 1,
        (s.capabilities >> 2) & 1,
        (s.capabilities >> 3) & 1,
        (s.capabilities >> 4) & 1,
        (s.capabilities >> 5) & 1,
        (s.capabilities >> 6) & 1
    );
    println!("hl2ctl: transmit-safety byte 0x{:02X}", s.safety_byte);
    println!(
        "hl2ctl: ILK_STATUS 0x{:08X} (tx_on={} pa_dac_on={} lease_valid={} tx_requested={} trip_latched={} cutoff_now={})",
        s.ilk_status,
        s.ilk_status & 1,
        (s.ilk_status >> 1) & 1,
        (s.ilk_status >> 2) & 1,
        (s.ilk_status >> 3) & 1,
        (s.ilk_status >> 4) & 1,
        (s.ilk_status >> 5) & 1
    );
    Ok(id_ok)
}

// ---- stream ----------------------------------------------------------------------------------
fn cmd_stream(args: &[String]) -> IoResult<bool> {
    let ip = parse_ip(args, "--ip")?;
    let iface_ip = parse_ip(args, "--iface-ip")?;
    let seconds: f64 = arg_value(args, "--seconds").and_then(|s| s.parse().ok()).unwrap_or(10.0);
    let spf: u16 = arg_value(args, "--samples-per-frame").and_then(|s| s.parse().ok()).unwrap_or(5968);
    let (stats, _samples) = run_stream(ip, iface_ip, seconds, spf, None).map_err(|e| e.to_string())?;
    print_capture_stats(&stats, seconds);
    Ok(stats.zero_gaps())
}

fn run_stream(
    ip: IpAddr,
    iface_ip: IpAddr,
    seconds: f64,
    samples_per_frame: u16,
    sample_cap: Option<usize>,
) -> std::io::Result<(pc::CaptureStats, Vec<i16>)> {
    let client = pc::Hl2Client::new(ip);
    client.clear_raw_mode()?; // stopped-state register writes only, PROTOCOL.md 5.1
    client.set_raw_mode(true, false, false, samples_per_frame)?;

    let stream_sock = pc::socket::open_stream_socket(iface_ip, pc::socket::DEFAULT_RCVBUF)?;
    pc::client::send_start(&stream_sock, ip)?;

    let result = pc::capture::run(stream_sock.try_clone()?, CaptureOptions { seconds, sample_cap });

    pc::client::send_stop(&stream_sock, ip)?;
    client.clear_raw_mode()?;
    result
}

fn print_capture_stats(stats: &pc::CaptureStats, seconds: f64) {
    println!(
        "hl2ctl: {} frames, {} samples ({:.3} Msps average), {} bytes over {:.1} s",
        stats.frames,
        stats.samples,
        stats.samples as f64 / seconds / 1e6,
        stats.bytes,
        seconds
    );
    println!(
        "hl2ctl: lost_frames={} lost_samples={} reordered_or_dup={} hl2_overflow_frames={} hl2_gap_frames={} fifo_high_water={} channel_drops={} recv_errors={}",
        stats.lost_frames,
        stats.lost_samples,
        stats.reordered_or_dup,
        stats.hl2_overflow_frames,
        stats.hl2_gap_frames,
        stats.fifo_high_water,
        stats.channel_drops,
        stats.recv_errors
    );
    println!(
        "hl2ctl: transmit-safety byte: last=0x{:02X} any-bit-seen=0x{:02X} changes={}",
        stats.safety_last, stats.safety_any, stats.safety_changes
    );
    println!("hl2ctl: {}", if stats.zero_gaps() { "PASS: zero gaps" } else { "FAIL: gaps detected" });
}

// ---- filter ------------------------------------------------------------------------------------
fn parse_band(s: &str) -> IoResult<Option<filter::Band>> {
    Ok(match s {
        "160m" => Some(filter::Band::B160m),
        "80m" => Some(filter::Band::B80m),
        "60-40m" => Some(filter::Band::B60_40m),
        "30-20m" => Some(filter::Band::B30_20m),
        "17-15m" => Some(filter::Band::B17_15m),
        "12-10m" => Some(filter::Band::B12_10m),
        "off" => None,
        other => return Err(format!("unknown --band {other}")),
    })
}

fn cmd_filter(args: &[String]) -> IoResult<bool> {
    let ip = parse_ip(args, "--ip")?;
    let band_arg = arg_value(args, "--band").ok_or("missing --band")?;
    let band = parse_band(&band_arg)?;
    let antenna = has_flag(args, "--antenna");
    let ok = run_filter_test(ip, band, antenna).map_err(|e| e.to_string())?;
    Ok(ok)
}

fn run_filter_test(ip: IpAddr, band: Option<filter::Band>, antenna: bool) -> std::io::Result<bool> {
    let mut value = band.map(filter::band_filter_bits).unwrap_or(0);
    if antenna {
        value |= filter::BIT_RX_ANTENNA;
    }
    let client = pc::Hl2Client::new(ip);
    client.set_frontend(value)?;
    // The gateware needs a moment to walk the write to the I2C engine (i2c_bus2.v) before the
    // MCP23008's output latch reflects it.
    std::thread::sleep(Duration::from_millis(50));

    let bc = pc::BridgeClient::connect(ip)?;
    let olat = bc.i2c_read_register(filter::MCP23008_I2C_BUS, filter::MCP23008_I2C_ADDR, filter::MCP23008_OLAT_REG)?;
    let expected = filter::expected_olat(value);
    println!(
        "hl2ctl: wrote register 0x00 = 0x{value:08X} ({}{}), MCP23008 OLAT read back = 0b{olat:07b} (expected 0b{expected:07b})",
        band.map(|b| format!("{b:?}")).unwrap_or_else(|| "off".into()),
        if antenna { " +antenna" } else { "" }
    );
    let ok = olat == expected;
    println!("hl2ctl: {}", if ok { "PASS: MCP23008 latch matches the register write" } else { "FAIL: MCP23008 latch does not match" });
    Ok(ok)
}

// ---- amband ------------------------------------------------------------------------------------
fn cmd_amband(args: &[String]) -> IoResult<bool> {
    let ip = parse_ip(args, "--ip")?;
    let iface_ip = parse_ip(args, "--iface-ip")?;
    let seconds: f64 = arg_value(args, "--seconds").and_then(|s| s.parse().ok()).unwrap_or(0.3);
    run_amband_test(ip, iface_ip, seconds).map_err(|e| e.to_string())
}

/// Toggle register-0x00 bit 23 (the 3 MHz high-pass, ARCHITECTURE.md section 8) and compare the
/// AM broadcast band's level between the two captures, the test that settles which relay
/// contact the bit selects. Always PASS/reports rather than fails outright when the difference
/// is too small to read: with no antenna connected, ARCHITECTURE.md's own open question may
/// simply be unmeasurable here, and that is a fact to report, not a bug.
fn run_amband_test(ip: IpAddr, iface_ip: IpAddr, seconds: f64) -> IoResult<bool> {
    let client = pc::Hl2Client::new(ip);
    let sample_cap = (76_800_000.0 * seconds) as usize;

    client.set_frontend(0).map_err(|e| e.to_string())?; // HPF bit off, no LPF, no antenna bit
    std::thread::sleep(Duration::from_millis(50));
    let (_stats_off, samples_off) =
        run_stream(ip, iface_ip, seconds, 5968, Some(sample_cap)).map_err(|e| format!("capture (HPF off): {e}"))?;

    client.set_frontend(filter::BIT_HPF_3MHZ).map_err(|e| e.to_string())?; // HPF bit on only
    std::thread::sleep(Duration::from_millis(50));
    let (_stats_on, samples_on) =
        run_stream(ip, iface_ip, seconds, 5968, Some(sample_cap)).map_err(|e| format!("capture (HPF on): {e}"))?;

    client.set_frontend(0).map_err(|e| e.to_string())?; // leave the board in a known state

    if samples_off.is_empty() || samples_on.is_empty() {
        println!("hl2ctl: FAIL: capture returned no samples (check the stream is running)");
        return Ok(false);
    }

    let fs = 76_800_000.0;
    let low_off = pc::goertzel::goertzel_power(&samples_off, fs, pc::goertzel::LOW_REFERENCE_HZ);
    let low_on = pc::goertzel::goertzel_power(&samples_on, fs, pc::goertzel::LOW_REFERENCE_HZ);
    let am_off = pc::goertzel::band_power_db(&samples_off, fs, &pc::goertzel::AM_BAND_HZ);
    let am_on = pc::goertzel::band_power_db(&samples_on, fs, &pc::goertzel::AM_BAND_HZ);
    let high_off = pc::goertzel::goertzel_power(&samples_off, fs, pc::goertzel::HIGH_REFERENCE_HZ);
    let high_on = pc::goertzel::goertzel_power(&samples_on, fs, pc::goertzel::HIGH_REFERENCE_HZ);

    println!("hl2ctl: {} samples per capture ({:.3} s at 76.8 Msps)", samples_off.len().min(samples_on.len()), seconds);
    println!(
        "hl2ctl: 100 kHz reference: HPF-off {:.1} dB, HPF-on {:.1} dB, delta {:.1} dB",
        pc::goertzel::to_db(low_off),
        pc::goertzel::to_db(low_on),
        pc::goertzel::to_db(low_on) - pc::goertzel::to_db(low_off)
    );
    println!("hl2ctl: AM broadcast band (0.6-1.6 MHz): HPF-off {:.1} dB, HPF-on {:.1} dB, delta {:.1} dB", am_off, am_on, am_on - am_off);
    println!(
        "hl2ctl: 7 MHz reference: HPF-off {:.1} dB, HPF-on {:.1} dB, delta {:.1} dB",
        pc::goertzel::to_db(high_off),
        pc::goertzel::to_db(high_on),
        pc::goertzel::to_db(high_on) - pc::goertzel::to_db(high_off)
    );

    let am_delta = am_on - am_off;
    if am_delta.abs() < 3.0 {
        println!(
            "hl2ctl: AM-band delta is {am_delta:.1} dB, under the 3 dB floor this tool treats as measurable -- likely \
             unmeasurable with no antenna connected (ARCHITECTURE.md section 8's polarity question stays open)"
        );
    } else if am_delta < 0.0 {
        println!("hl2ctl: AM band is WEAKER with bit 23 on: consistent with bit 23 = high-pass IN LINE (blocking the AM band)");
    } else {
        println!("hl2ctl: AM band is STRONGER with bit 23 on: consistent with bit 23 = high-pass BYPASSED");
    }
    // This test always "passes" in the sense of completing and reporting a real reading; the
    // exit code reflects whether both captures ran cleanly, not the polarity finding itself.
    Ok(true)
}

// ---- capture -------------------------------------------------------------------------------
/// Save a raw sample capture (no antenna needed, used for noise-floor references) at a given
/// RX gain to a flat file of little-endian i16 samples. No test-pass/fail here: this is a data
/// grab for later offline use, not a done-test item.
fn cmd_capture(args: &[String]) -> IoResult<bool> {
    let ip = parse_ip(args, "--ip")?;
    let iface_ip = parse_ip(args, "--iface-ip")?;
    let out = arg_value(args, "--out").ok_or("missing --out")?;
    let seconds: f64 = arg_value(args, "--seconds").and_then(|s| s.parse().ok()).unwrap_or(3.0);
    let gain_db: i32 = arg_value(args, "--gain-db").and_then(|s| s.parse().ok()).unwrap_or(0);

    let client = pc::Hl2Client::new(ip);
    let applied_db = client.set_rx_gain_db(gain_db).map_err(|e| e.to_string())?;
    std::thread::sleep(Duration::from_millis(50));

    let sample_cap = (76_800_000.0 * seconds) as usize;
    let (stats, samples) =
        run_stream(ip, iface_ip, seconds, 5968, Some(sample_cap)).map_err(|e| e.to_string())?;

    let mut bytes = Vec::with_capacity(samples.len() * 2);
    for s in &samples {
        bytes.extend_from_slice(&s.to_le_bytes());
    }
    let mut f = File::create(&out).map_err(|e| format!("creating {out}: {e}"))?;
    f.write_all(&bytes).map_err(|e| format!("writing {out}: {e}"))?;

    println!(
        "hl2ctl: wrote {} samples ({} bytes, {:.2} s at 76.8 Msps) to {out}, RX gain {} dB (requested {} dB)",
        samples.len(),
        bytes.len(),
        samples.len() as f64 / 76_800_000.0,
        applied_db,
        gain_db
    );
    println!(
        "hl2ctl: lost_frames={} hl2_overflow_frames={} hl2_gap_frames={}",
        stats.lost_frames, stats.hl2_overflow_frames, stats.hl2_gap_frames
    );
    Ok(true)
}

// ---- done-test ---------------------------------------------------------------------------------
fn cmd_done_test(args: &[String]) -> IoResult<bool> {
    let ip = parse_ip(args, "--ip")?;
    let iface_ip = parse_ip(args, "--iface-ip")?;

    println!("== status ==");
    let status_ok = print_status(ip).map_err(|e| e.to_string())?;

    println!("\n== 10 s stream, 0 gaps ==");
    let (stats, _) = run_stream(ip, iface_ip, 10.0, 5968, None).map_err(|e| e.to_string())?;
    print_capture_stats(&stats, 10.0);

    println!("\n== filter bits + MCP23008 readback (80 m) ==");
    let filter_ok = run_filter_test(ip, Some(filter::Band::B80m), false).map_err(|e| e.to_string())?;
    run_filter_test(ip, None, false).map_err(|e| e.to_string())?; // leave filters off afterward

    println!("\n== AM-band level, bit 23 (high-pass) on vs off ==");
    let amband_ok = run_amband_test(ip, iface_ip, 0.3)?;

    println!("\n== summary ==");
    println!("status read:            {}", if status_ok { "PASS" } else { "FAIL" });
    println!("10 s stream, 0 gaps:     {}", if stats.zero_gaps() { "PASS" } else { "FAIL" });
    println!("filter + I2C readback:   {}", if filter_ok { "PASS" } else { "FAIL" });
    println!("AM-band level (bit 23):  {}", if amband_ok { "ran (see the delta above for the finding)" } else { "FAIL" });

    Ok(status_ok && stats.zero_gaps() && filter_ok && amband_ok)
}
