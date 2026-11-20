// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
#![allow(dead_code)]

//! Wire format of the Hermes-Lite 2 raw ADC Ethernet stream. This is the only place in `tr-hl2`
//! where the details of the stream and control wire format live, so if the format changes this
//! file is the only one that needs editing. It is specified in `docs/rawfront/PROTOCOL.md`
//! (Hermes-Lite2 repository, branch `hl2-rawfront-release`) and implemented in
//! `gateware/rtl/rawstream.v` there.
//!
//! The code comes from `software/rawstream/rawcap/src/protocol.rs` of that repository (same
//! owner, Apache-2.0), adapted for `no_std` (no `Vec` or `String` on the core path, callers supply
//! scratch buffers) and trimmed to what `tr-hl2` needs: discovery, start and stop, register
//! writes, raw-frame header parsing and sample unpacking. Building TX frames and the echo and aux
//! channel wire formats are left out, since this crate never sends TX frames.
//!
//! Facts this module relies on (section numbers of PROTOCOL.md):
//!   1. Header fields are big-endian on the wire (section 1).
//!   2. Discovery: `EF FE 02` plus 57 zero bytes to port 1025 or 1024, and a 60-byte `EF FE` reply
//!      (section 2).
//!   3. Register write: 60 bytes `EF FE 05 7F <addr<<1> <4-byte-BE value> + 51 zero bytes` to
//!      port 1025 (section 3).
//!   4. Start and stop: 64 bytes `EF FE 04 <flags>` plus 60 zero bytes to port 1024, sent from the
//!      socket that will receive the stream (section 4).
//!   5. Raw frame header; samples are 12-bit two's complement packed 2 per 3 bytes, big-endian;
//!      the test pattern is `(index + k) mod 4096` (section 5).

/// Bytes of frame header before the packed samples start (version 1 frames, duplex off).
pub const HEADER_LEN: usize = 20;
/// Header length of version 2 (duplex) frames: bytes 0-19 as version 1, bytes 20-39 the radio's
/// TX sink status.
pub const HEADER_LEN_V2: usize = 40;
/// Header length of version 3 (raw front-end image, duplex on) frames: as version 2, plus bytes
/// 40-47 echo offset/flags and latched interlock trips.
pub const HEADER_LEN_V3: usize = 48;

pub const FRAME_MAGIC: u8 = 0xA5;
pub const FRAME_VERSION: u8 = 0x01;
pub const FRAME_VERSION_DUPLEX: u8 = 0x02;
pub const FRAME_VERSION_RAWFRONT: u8 = 0x03;

// ---- Header flags byte (offset 2) --------------------------------------------------------
pub const FLAG_TEST_PATTERN: u8 = 1 << 0;
/// A FIFO overflow happened since start. Sticky: stays set for the rest of the run.
pub const FLAG_OVERFLOW: u8 = 1 << 1;
/// A sample in the PREVIOUS frame (not this one) was at full scale (0x7FF or 0x800).
pub const FLAG_ADC_CLIP_PREV_FRAME: u8 = 1 << 2;
pub const FLAG_QUIET_CAPTURE: u8 = 1 << 3;
pub const FLAG_FIRST_FRAME: u8 = 1 << 4;
/// Samples are missing between the previous frame and this one (after an overflow or between
/// quiet-capture blocks). Distinct from FLAG_OVERFLOW, which stays set for the whole run.
pub const FLAG_GAP: u8 = 1 << 5;

// ---- Transmit-safety status byte (offset 3, PROTOCOL.md 5.4) -----------------------------
/// Transmit off: no interlock output is on. Idle value.
pub const SAFETY_TX_FORCED_OFF: u8 = 1 << 0;
/// A PA supply, bias or T/R relay pin is driven.
pub const SAFETY_PA_KEYED: u8 = 1 << 1;
/// Transmit requested (permission lease valid and keyed).
pub const SAFETY_HOST_MOX: u8 = 1 << 2;
/// PTT input (key jack ring) closed, debounced.
pub const SAFETY_PTT_IN: u8 = 1 << 3;
/// Key input (key jack tip) closed, debounced.
pub const SAFETY_KEY_IN: u8 = 1 << 4;
/// TX inhibit input (CN8) active, debounced.
pub const SAFETY_TX_INHIBIT: u8 = 1 << 5;
/// Over-temperature cut-off present.
pub const SAFETY_OVER_TEMP: u8 = 1 << 6;
/// An interlock trip is latched.
pub const SAFETY_TRIP: u8 = 1 << 7;

/// Idle value of the transmit-safety byte (section 5.4): transmit off, nothing else set.
pub const SAFETY_IDLE: u8 = SAFETY_TX_FORCED_OFF;

// ---- UDP ports (PROTOCOL.md section 1) ----------------------------------------------------
/// Start/stop command port (`EF FE 04 xx`); raw sample frames come FROM this port too.
pub const PORT_START_STOP: u16 = 1024;
/// Discovery + general register-write command port.
pub const PORT_CMD: u16 = 1025;
/// PC -> HL2 TX sample frames (not used by this crate).
pub const PORT_TX: u16 = 1026;
/// Aux channel, register bridge (Etherbone), console, gdb, message layer.
pub const PORT_BRIDGE: u16 = 1027;

// ---- Start/stop (PROTOCOL.md section 4) ---------------------------------------------------
pub const START_STOP_LEN: usize = 64;
const START_STOP_FLAG_RUN: u8 = 1 << 0;
const START_STOP_FLAG_WATCHDOG_OFF: u8 = 1 << 7;

fn build_start_stop_packet(flags: u8) -> [u8; START_STOP_LEN] {
    let mut buf = [0u8; START_STOP_LEN];
    buf[0] = 0xEF;
    buf[1] = 0xFE;
    buf[2] = 0x04;
    buf[3] = flags;
    buf
}

/// Run + watchdog-off (the client sends nothing on port 1024 while streaming, per PROTOCOL.md).
pub fn cmd_start() -> [u8; START_STOP_LEN] {
    build_start_stop_packet(START_STOP_FLAG_RUN | START_STOP_FLAG_WATCHDOG_OFF)
}

/// The stop packet: a start/stop packet with no flags set.
pub fn cmd_stop() -> [u8; START_STOP_LEN] {
    build_start_stop_packet(0)
}

// ---- Discovery (PROTOCOL.md section 2) ----------------------------------------------------
pub const DISCOVERY_REQUEST_LEN: usize = 60;
pub const RESPONSE_LEN: usize = 60;

/// The discovery request: `EF FE 02` followed by zero bytes.
pub fn build_discovery_request() -> [u8; DISCOVERY_REQUEST_LEN] {
    let mut buf = [0u8; DISCOVERY_REQUEST_LEN];
    buf[0] = 0xEF;
    buf[1] = 0xFE;
    buf[2] = 0x02;
    buf
}

/// The fields of a discovery reply that this crate uses.
#[derive(Debug, Clone, Copy)]
pub struct DiscoveryResponse {
    pub mac: [u8; 6],
    pub running: bool,
    pub gateware_major: u8,
    pub gateware_minor: u8,
    /// 0xD1 for the raw front-end image (`hl2b5up_raw`); 0 in stock/factory images.
    pub image_marker: u8,
    /// 0 in the raw front-end image (stock images report 4).
    pub receivers: u8,
    pub board_id: u8,
}

/// Parses a discovery reply, or returns `None` if it is too short or does not start with `EF FE`.
pub fn parse_discovery_response(buf: &[u8]) -> Option<DiscoveryResponse> {
    if buf.len() < RESPONSE_LEN {
        return None;
    }
    if buf[0] != 0xEF || buf[1] != 0xFE {
        return None;
    }
    let mut mac = [0u8; 6];
    mac.copy_from_slice(&buf[3..9]);
    Some(DiscoveryResponse {
        mac,
        running: buf[2] == 3,
        gateware_major: buf[0x09],
        gateware_minor: buf[0x15],
        image_marker: buf[0x0C],
        receivers: buf[0x13],
        board_id: buf[0x14] & 0x3f,
    })
}

/// True for this image (`hl2b5up_raw`, PROTOCOL.md section 2): marker 0xD1, 0 receivers
/// reported (stock/factory images report marker 0 and 4 receivers).
pub const RAWFRONT_IMAGE_MARKER: u8 = 0xD1;

impl DiscoveryResponse {
    pub fn is_rawfront_image(&self) -> bool {
        self.image_marker == RAWFRONT_IMAGE_MARKER
    }
}

// ---- Register write, port 1025 (PROTOCOL.md section 3) ------------------------------------
/// Register 0x30: raw mode, frame size, test pattern, quiet capture (PROTOCOL.md 5.1).
pub const REG_ADDR_RAWMODE: u8 = 0x30;
/// Register 0x31: duplex, real DAC, echo (PROTOCOL.md 6.1).
pub const REG_ADDR_DUPLEX: u8 = 0x31;
/// Register 0x00: front-end configuration, N2ADR filter relays, RX antenna, sync/fan bits
/// (PROTOCOL.md section 12, ARCHITECTURE.md section 8). See `filter` module.
pub const REG_ADDR_FRONTEND: u8 = 0x00;
/// Register 0x0A: RX gain (AD9866 PGA), value `0x40 + dB + 12`, range -12 to +48 dB
/// (PROTOCOL.md section 3's command table).
pub const REG_ADDR_RX_GAIN: u8 = 0x0A;

/// Lowest/highest RX gain `rx_gain_value` accepts (PROTOCOL.md: "-12 to +48 dB").
pub const RX_GAIN_MIN_DB: i32 = -12;
pub const RX_GAIN_MAX_DB: i32 = 48;

/// Build the 32-bit value for register 0x0A (RX gain): `0x40 + dB + 12`. Clamps `db` to
/// `RX_GAIN_MIN_DB..=RX_GAIN_MAX_DB` first and returns `(value, clamped_db)` so the caller can
/// report what was actually requested.
pub fn rx_gain_value(db: i32) -> (u32, i32) {
    let clamped = db.clamp(RX_GAIN_MIN_DB, RX_GAIN_MAX_DB);
    ((0x40 + clamped + 12) as u32, clamped)
}

pub const REG_RAW_ENABLE: u32 = 1 << 0;
pub const REG_RAW_TEST_PATTERN: u32 = 1 << 1;
pub const REG_RAW_QUIET_CAPTURE: u32 = 1 << 2;

/// "0 means 968", a literal 0 in the register's samples-per-frame field means the default,
/// not "zero samples" (PROTOCOL.md 5.1).
pub const DEFAULT_SAMPLES_PER_FRAME: u16 = 968;
/// "Above 5,968 is cut to 5,968 in this image" (PROTOCOL.md 5.1; the FIFO-derived hardware
/// ceiling in other rawstream images is higher, but this image's cap is 5,968).
pub const MAX_SAMPLES_PER_FRAME: u16 = 5_968;

/// Clamp a requested samples-per-frame to what the gateware will actually use: round down to
/// even, treat 0 as `DEFAULT_SAMPLES_PER_FRAME`, cut anything over `MAX_SAMPLES_PER_FRAME`.
/// Returns `(value_the_gateware_will_use, was_clamped)`.
pub fn clamp_samples_per_frame(requested: u16) -> (u16, bool) {
    let even = requested & !1;
    if even == 0 {
        return (DEFAULT_SAMPLES_PER_FRAME, requested != DEFAULT_SAMPLES_PER_FRAME);
    }
    if even > MAX_SAMPLES_PER_FRAME {
        return (MAX_SAMPLES_PER_FRAME, true);
    }
    (even, even != requested)
}

/// Build the 32-bit value for the raw-mode register (0x30): enable/test-pattern/quiet-capture
/// bits plus samples-per-frame in bits 31:16. Does NOT clamp: call `clamp_samples_per_frame`
/// first so the caller knows if/why the value changed.
pub fn reg_raw_value(enable: bool, test_pattern: bool, quiet_capture: bool, samples_per_frame: u16) -> u32 {
    let mut v: u32 = 0;
    if enable {
        v |= REG_RAW_ENABLE;
    }
    if test_pattern {
        v |= REG_RAW_TEST_PATTERN;
    }
    if quiet_capture {
        v |= REG_RAW_QUIET_CAPTURE;
    }
    v | ((samples_per_frame as u32) << 16)
}

/// The register value that turns raw mode fully off.
pub fn reg_raw_off() -> u32 {
    0
}

/// The largest UDP payload the HL2 can send from port 1027 (register bridge replies, message-layer
/// and boot ROM datagrams) while it streams `n` samples per frame with a header of `header_len`
/// bytes (20, or 48 with duplex on).
///
/// The HL2 sends port 1027 datagrams only in the gap between two raw frames, and only when the
/// whole datagram fits before the next frame is due (PROTOCOL.md 7 and 8.1, RISCV.md "Packet
/// interface"). Its gateware computes that room as `1.625 x (N - fill - 32) - 80` bytes
/// (`gateware/rtl/rawstream.v`, "Aux room"), and a datagram waits until the room is at least its
/// length. Right after a frame the FIFO holds the samples that arrived while the frame was on the
/// wire (0.6144 samples per byte time at 76.8 Msps and 125 Mbyte/s), so this is the most room there
/// ever is. At N = 948 (a 1,500-byte packet) it is 0: a reply from port 1027 is never sent while
/// the stream runs, and it goes out only after the stream stops.
pub fn reply_room(n: u16, header_len: usize) -> u16 {
    let n = n as u32;
    // UDP payload, UDP, IP and Ethernet headers, FCS, preamble, inter-frame gap
    let wire_bytes = header_len as u32 + 3 * n / 2 + 8 + 20 + 14 + 4 + 8 + 12;
    let arrived = (wire_bytes * 6_144).div_ceil(10_000);
    let Some(rm) = n.checked_sub(arrived + 32) else { return 0 };
    let rm_b = rm + (rm >> 1) + (rm >> 3);
    if rm_b < 81 {
        0
    } else {
        (rm_b - 80).min(u16::MAX as u32) as u16
    }
}

/// The longest port 1027 reply this crate asks for: a register bridge reply with 48 read-backs
/// (16 + 4 x 48 bytes) and the CPU's datagrams (at most 256 bytes, RISCV.md "Packet interface").
pub const LONGEST_REPLY: u16 = 256;

/// Bit 0: TX sink on (only active while raw streaming runs).
pub const REG_DUPLEX_ENABLE: u32 = 1 << 0;
/// Bit 1: real DAC. **`tr-hl2` never sets this bit**, see `client::write_command_register`'s
/// safety guard.
pub const REG_DUPLEX_REAL: u32 = 1 << 1;
/// Bit 2: echo (played TX samples replace ADC samples in the RX stream; the DAC is never
/// driven). Allowed, it drives no output.
pub const REG_DUPLEX_ECHO: u32 = 1 << 2;

/// Build the 60-byte register-write command packet (PROTOCOL.md section 3):
/// `EF FE 05 7F <addr<<1> <4-byte-BE value> <51 zero bytes>`.
pub fn build_command_packet(addr: u8, value: u32) -> [u8; RESPONSE_LEN] {
    let mut buf = [0u8; RESPONSE_LEN];
    buf[0] = 0xEF;
    buf[1] = 0xFE;
    buf[2] = 0x05;
    buf[3] = 0x7F;
    buf[4] = addr << 1;
    buf[5..9].copy_from_slice(&value.to_be_bytes());
    buf
}

// ---- Stream frame header (PROTOCOL.md section 5) -------------------------------------------
/// The header of one raw-stream frame (`PROTOCOL.md` section 5).
#[derive(Debug, Clone, Copy, Default)]
pub struct FrameHeader {
    pub flags: u8,
    /// Transmit-safety status byte (header byte 3, `SAFETY_*` bits; 0 in older images).
    pub safety: u8,
    pub seq: u32,
    /// 48-bit value, widened. Counts every ADC clock since start.
    pub first_sample_index: u64,
    pub samples_in_frame: u16,
    /// FIFO overflow events since start. Saturates at 65,535.
    pub overflow_count: u16,
    /// Highest raw FIFO fill since start, in samples (FIFO depth 8,192 in this image).
    pub fifo_high_water: u16,
    /// 20 for version 1 frames, 40 for version 2, 48 for version 3.
    pub header_len: usize,
}

impl FrameHeader {
    /// Parse a frame header from the start of a UDP payload. Returns None if too short or the
    /// magic/version bytes don't match (i.e. not a rawstream frame). Version 2/3 payload (TX
    /// sink status, echo status) is not decoded here, because this crate never uses duplex or echo.
    pub fn parse(buf: &[u8]) -> Option<FrameHeader> {
        if buf.len() < HEADER_LEN {
            return None;
        }
        if buf[0] != FRAME_MAGIC {
            return None;
        }
        let header_len = match buf[1] {
            FRAME_VERSION => HEADER_LEN,
            FRAME_VERSION_DUPLEX if buf.len() >= HEADER_LEN_V2 => HEADER_LEN_V2,
            FRAME_VERSION_RAWFRONT if buf.len() >= HEADER_LEN_V3 => HEADER_LEN_V3,
            _ => return None,
        };
        let flags = buf[2];
        let safety = buf[3];
        let seq = u32::from_be_bytes([buf[4], buf[5], buf[6], buf[7]]);
        let mut idx_bytes = [0u8; 8];
        idx_bytes[2..8].copy_from_slice(&buf[8..14]);
        let first_sample_index = u64::from_be_bytes(idx_bytes);
        let samples_in_frame = u16::from_be_bytes([buf[14], buf[15]]);
        let overflow_count = u16::from_be_bytes([buf[16], buf[17]]);
        let fifo_high_water = u16::from_be_bytes([buf[18], buf[19]]);
        Some(FrameHeader {
            flags,
            safety,
            seq,
            first_sample_index,
            samples_in_frame,
            overflow_count,
            fifo_high_water,
            header_len,
        })
    }

    pub fn is_test_pattern(&self) -> bool {
        self.flags & FLAG_TEST_PATTERN != 0
    }
    pub fn is_overflow(&self) -> bool {
        self.flags & FLAG_OVERFLOW != 0
    }
    pub fn is_gap(&self) -> bool {
        self.flags & FLAG_GAP != 0
    }
}

/// Number of payload bytes needed to carry `n` packed 12-bit samples (2 samples -> 3 bytes).
pub fn packed_len(n_samples: usize) -> usize {
    (n_samples * 3 + 1) / 2
}

/// Unpack 12-bit samples packed 2-per-3-bytes, big-endian: `a[11:4]`, `{a[3:0],b[11:8]}`,
/// `b[7:0]`. Writes sign-extended i16 values into `out`, returns the count written. `out` may be
/// shorter than the payload holds; excess payload is ignored. No allocation: usable from
/// `no_std` code.
pub fn unpack_samples_into(payload: &[u8], out: &mut [i16]) -> usize {
    let pairs = (payload.len() / 3).min((out.len() + 1) / 2);
    for i in 0..pairs {
        let b0 = payload[i * 3] as u16;
        let b1 = payload[i * 3 + 1] as u16;
        let b2 = payload[i * 3 + 2] as u16;
        let a = (b0 << 4) | (b1 >> 4);
        let b = ((b1 & 0x0f) << 8) | b2;
        out[i * 2] = sign_extend_12(a);
        if i * 2 + 1 < out.len() {
            out[i * 2 + 1] = sign_extend_12(b);
        }
    }
    (pairs * 2).min(out.len())
}

/// Sign-extends a 12-bit two's complement value to 16 bits.
#[inline]
pub fn sign_extend_12(v: u16) -> i16 {
    let v = v & 0x0fff;
    if v & 0x0800 != 0 {
        (v | 0xf000) as i16
    } else {
        v as i16
    }
}

/// Expected test-pattern value for sample `k` (0-based) of a frame whose header says the first
/// sample's index is `first_sample_index`: `(I + k) mod 4096` (PROTOCOL.md 5.5).
#[inline]
pub fn expected_pattern_value(first_sample_index: u64, k: usize) -> u16 {
    ((first_sample_index.wrapping_add(k as u64)) % 4096) as u16
}

/// Samples per frame for a given IP MTU, rounded down to an even count.
///   samples_per_frame = floor((ip_mtu - 28 - header_len) / 3) * 2
pub fn samples_per_frame_for_ip_mtu_hdr(ip_mtu: usize, header_len: usize) -> u16 {
    let samples_payload = ip_mtu.saturating_sub(28).saturating_sub(header_len);
    ((samples_payload / 3) * 2).min(u16::MAX as usize) as u16
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_port_1027_reply_fits_beside_a_1500_byte_stream() {
        // The board's setting: 948 samples per frame. The line is 97.7 % busy with raw frames and
        // the gap after each is about 22 samples, less than the gateware's 32-sample margin.
        assert_eq!(reply_room(948, HEADER_LEN), 0);
        assert_eq!(reply_room(948, HEADER_LEN_V3), 0);
        assert_eq!(reply_room(968, HEADER_LEN), 0);
        // Not even the shortest bridge reply (16 + 4 bytes) fits below about 1,900 samples.
        assert!(reply_room(1_800, HEADER_LEN) < 20);
        // Jumbo frames leave room ("about 50 Mbit/s of aux payload" at 5,968, PROTOCOL.md 7.3).
        let r = reply_room(5_968, HEADER_LEN);
        assert!((520..=560).contains(&r), "{r}");
        assert!(reply_room(4_096, HEADER_LEN) >= LONGEST_REPLY);
        assert!(reply_room(3_600, HEADER_LEN) < LONGEST_REPLY);
    }

    #[test]
    fn header_roundtrip() {
        let mut buf = [0u8; HEADER_LEN];
        buf[0] = FRAME_MAGIC;
        buf[1] = FRAME_VERSION;
        buf[2] = FLAG_TEST_PATTERN | FLAG_FIRST_FRAME;
        buf[3] = SAFETY_IDLE;
        buf[4..8].copy_from_slice(&42u32.to_be_bytes());
        let idx: u64 = 123_456_789;
        buf[8..14].copy_from_slice(&idx.to_be_bytes()[2..8]);
        buf[14..16].copy_from_slice(&5968u16.to_be_bytes());
        buf[16..18].copy_from_slice(&3u16.to_be_bytes());
        buf[18..20].copy_from_slice(&2000u16.to_be_bytes());

        let parsed = FrameHeader::parse(&buf).unwrap();
        assert_eq!(parsed.seq, 42);
        assert_eq!(parsed.first_sample_index, idx);
        assert_eq!(parsed.samples_in_frame, 5968);
        assert_eq!(parsed.overflow_count, 3);
        assert_eq!(parsed.fifo_high_water, 2000);
        assert_eq!(parsed.header_len, HEADER_LEN);
        assert!(parsed.is_test_pattern());
        assert!(!parsed.is_overflow());
        assert_eq!(parsed.safety, SAFETY_IDLE);
    }

    #[test]
    fn v3_header_is_recognised_but_not_over_read() {
        let mut buf = [0u8; HEADER_LEN_V3];
        buf[0] = FRAME_MAGIC;
        buf[1] = FRAME_VERSION_RAWFRONT;
        let parsed = FrameHeader::parse(&buf).unwrap();
        assert_eq!(parsed.header_len, HEADER_LEN_V3);
        // too short for the version 3 body: rejected, not silently truncated.
        assert!(FrameHeader::parse(&buf[..44]).is_none());
    }

    #[test]
    fn clamp_matches_protocol_md() {
        assert_eq!(clamp_samples_per_frame(0), (968, true));
        assert_eq!(clamp_samples_per_frame(968), (968, false));
        assert_eq!(clamp_samples_per_frame(969), (968, true));
        assert_eq!(clamp_samples_per_frame(5_968), (5_968, false));
        assert_eq!(clamp_samples_per_frame(8_000), (5_968, true));
        assert_eq!(clamp_samples_per_frame(u16::MAX), (5_968, true));
    }

    #[test]
    fn start_stop_packets() {
        let start = cmd_start();
        let stop = cmd_stop();
        assert_eq!(&start[0..4], &[0xEF, 0xFE, 0x04, 0x81]);
        assert_eq!(&stop[0..4], &[0xEF, 0xFE, 0x04, 0x00]);
        assert!(start[4..].iter().all(|&b| b == 0));
        assert!(stop[4..].iter().all(|&b| b == 0));
    }

    #[test]
    fn discovery_request_and_response() {
        let req = build_discovery_request();
        assert_eq!(&req[0..3], &[0xEF, 0xFE, 0x02]);
        assert_eq!(req.len(), DISCOVERY_REQUEST_LEN);

        let mut resp = [0u8; RESPONSE_LEN];
        resp[0] = 0xEF;
        resp[1] = 0xFE;
        resp[2] = 3; // running
        resp[3..9].copy_from_slice(&[0x00, 0x1c, 0xc0, 0x01, 0x02, 0x03]);
        resp[0x09] = 74;
        resp[0x0C] = RAWFRONT_IMAGE_MARKER;
        resp[0x13] = 0;
        resp[0x14] = 5;
        resp[0x15] = 2;
        let d = parse_discovery_response(&resp).unwrap();
        assert!(d.running);
        assert_eq!(d.mac, [0x00, 0x1c, 0xc0, 0x01, 0x02, 0x03]);
        assert_eq!((d.gateware_major, d.gateware_minor), (74, 2));
        assert!(d.is_rawfront_image());
        assert_eq!(d.receivers, 0);
        assert_eq!(d.board_id, 5);
    }

    #[test]
    fn command_packet_layout() {
        let pkt = build_command_packet(0x30, 0x1750_0001);
        assert_eq!(&pkt[0..5], &[0xEF, 0xFE, 0x05, 0x7F, 0x60]);
        assert_eq!(&pkt[5..9], &0x1750_0001u32.to_be_bytes());
        assert!(pkt[9..].iter().all(|&b| b == 0));
    }

    #[test]
    fn pack_unpack_roundtrip() {
        // a[11:4], {a[3:0],b[11:8]}, b[7:0]
        let a: u16 = 0x123;
        let b: u16 = 0xabc;
        let payload = [
            (a >> 4) as u8,
            (((a & 0x0f) << 4) | (b >> 8)) as u8,
            (b & 0xff) as u8,
        ];
        let mut out = [0i16; 2];
        let n = unpack_samples_into(&payload, &mut out);
        assert_eq!(n, 2);
        assert_eq!(out[0] as u16 & 0x0fff, a);
        assert_eq!(out[1] as u16 & 0x0fff, b);
    }

    #[test]
    fn sign_extension() {
        assert_eq!(sign_extend_12(0x000), 0);
        assert_eq!(sign_extend_12(0x7FF), 2047);
        assert_eq!(sign_extend_12(0x800), -2048);
        assert_eq!(sign_extend_12(0xFFF), -1);
    }

    #[test]
    fn pattern_value_wraps_at_4096() {
        assert_eq!(expected_pattern_value(0, 0), 0);
        assert_eq!(expected_pattern_value(4095, 1), 0);
        assert_eq!(expected_pattern_value(1_000_000, 0), (1_000_000u64 % 4096) as u16);
    }

    #[test]
    fn known_table_values_from_protocol_md() {
        assert_eq!(samples_per_frame_for_ip_mtu_hdr(1500, HEADER_LEN), 968);
        assert_eq!(samples_per_frame_for_ip_mtu_hdr(9000, HEADER_LEN), 5968);
    }

    #[test]
    fn rx_gain_value_matches_protocol_md_formula() {
        // "0x40 + dB + 12", range -12 to +48 dB.
        assert_eq!(rx_gain_value(-12), (0x40, -12));
        assert_eq!(rx_gain_value(0), (0x40 + 12, 0));
        assert_eq!(rx_gain_value(48), (0x40 + 48 + 12, 48));
    }

    #[test]
    fn rx_gain_value_clamps_out_of_range() {
        assert_eq!(rx_gain_value(-100), (0x40, -12));
        assert_eq!(rx_gain_value(1000), (0x40 + 48 + 12, 48));
    }
}
