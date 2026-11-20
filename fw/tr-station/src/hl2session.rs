// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The HL2 link session: everything the firmware says to the HL2 so that raw samples arrive,
//! sent over the link's CPU packet path. Reference: the raw front-end image's PROTOCOL.md
//! (sections 1 to 6 and 12) and the PC-side `tr-hl2` crate, whose wire format this uses.
//!
//! What happens, in order:
//!
//! 1. **Address.** The HL2 asks for an address by DHCP at power-up; we answer (10.99.0.2, one
//!    lease). If it already has one (it fell back to 169.254.x.x after 15 s, or has a static
//!    one), nothing is needed: every reply below goes to whoever sent the request.
//! 2. **Discovery.** `EF FE 02` broadcast to port 1025 every 0.5 s until the HL2 answers. The
//!    answer must carry the raw front-end marker 0xD1; any other image is left alone.
//!    If more than [`FLOOD_FRAMES`] non-raw frames arrived since the last request, an HL2 is still
//!    streaming from an earlier session (it does not know the radio restarted, as seen on the board):
//!    the classifier does not know its address yet, so its ~80,000 frames a second go to the CPU
//!    receive ring, which then keeps a discovery reply for only about 33 us (simulated in sim/hl2sfp with -DSTALE),
//!    far less than one pass of the main loop. That request is replaced by a stop broadcast to
//!    port 1024 (the HL2 accepts broadcasts on ports 1024 and 1025, gateware udp_recv.v and
//!    dsopenhpsdr1.v); the stream ends, and the next request is answered.
//! 3. **Set-up**, radio stopped: stop; register 0x30 = raw mode on with 948 samples per frame
//!    (a 1,500-byte packet with the long header); register 0x00 = the N2ADR filter relays of
//!    the band; register 0x0A = RX gain. Each register write is repeated up to three times
//!    until the HL2's reply arrives.
//! 4. **Message layer and program** (docs/HL2_CONTROL.md), radio still stopped: a
//!    `tr_hl2::control::Hl2Control` on port 1027 sends HELLO and reads the filter latch. This has
//!    to happen before the start: the HL2 sends port 1027 datagrams only in the gaps of its raw
//!    stream, and at 948 samples per frame no gap is long enough (`tr_hl2::protocol::reply_room`),
//!    so nothing from port 1027 arrives while it streams. If the firmware was built with the
//!    message-layer program ([`SessionConfig::hl2_program`]) and HELLO reports another version, or
//!    goes unanswered within 3 s (no program), the session updates the HL2's saved program
//!    (`tr_hl2::cpuload::CpuLoader::update`: RAM written and read back, CPU restarted into the
//!    boot ROM, save to the flash sector by the ROM, CPU restarted into the saved program), then
//!    sends HELLO again and checks the version. At most [`MAX_UPDATE_ATTEMPTS`] updates per HL2
//!    start (seen as its DHCP request), one per stream start; after that the session goes on with
//!    whatever the HL2 runs.
//! 5. **Start** (`EF FE 04 81` to port 1024) from the port the chip's TX framer also uses; the
//!    HL2 streams to the sender of this datagram.
//! 6. **Watch.** No raw frame counted for 1 s, or the Ethernet link gone: the session reports the
//!    loss and starts again at 2. While streaming, the message layer is used only if the frame
//!    size leaves room for its replies (jumbo frames): then telemetry arrives every 500 ms and RX
//!    gain and filter changes go through it. Otherwise they go to port 1025, and nothing is sent
//!    to port 1027.
//!
//! # Every command this module can send to the HL2
//!
//! | Datagram | When |
//! |---|---|
//! | DHCP OFFER / ACK (port 68), ARP reply | when the HL2 asks |
//! | discovery `EF FE 02` (port 1025) | while looking for the HL2 |
//! | stop `EF FE 04 00` broadcast (port 1024) | while looking for the HL2, only if a stream floods the receive ring |
//! | stop `EF FE 04 00` (port 1024) | before set-up, and when the stream is lost |
//! | register 0x30 raw mode, 0x00 filter relays, 0x0A RX gain (port 1025) | set-up; 0x00 again on a band change |
//! | start `EF FE 04 81` (port 1024) | after set-up |
//! | register 0x31 = 1 (TX samples to the HL2's virtual DAC) or 5 (echo) | **only** for [`Action::ArmTx`], which the station logic produces only for the operator's TX switch |
//! | register 0x31 = 0 | for [`Action::DisarmTx`] (operator's switch off, HL2 trip, link lost) |
//! | register 0x0A RX gain (port 1025) | [`Hl2Session::set_rx_gain_db`], when the message layer is not up |
//! | message layer (port 1027): HELLO, filter latch read | stream stopped, see 4 above |
//! | message layer (port 1027): telemetry period, CMD 0x0A RX gain, CMD 0x00 filter relays | while streaming with room for replies, see 6 above |
//! | register bridge (port 1027): HL2 CPU RAM 0x800-0x3FFF, CPU control, boot address, firmware state and result; reads of RAM, system and status blocks | only while an update runs, see 4 above |
//! | boot ROM console (port 1027): the save datagram `01 'S'` of exactly the embedded image | only while an update runs, the stream stopped and transmit off |
//!
//! Nothing else: [`command_allowed`] is checked on every port 1025 register write and passes only
//! these, [`msg_datagram_allowed`] on every message-layer datagram, and [`update_datagram_allowed`]
//! on every register bridge and boot ROM datagram. In particular this module cannot write register
//! 0x31 with bit 1 (real DAC), cannot write register 0x09 (TX gain, PA enable), never writes the
//! front-end register block (where `TX_PERMIT` lives), the flash sector registers or the command
//! bus through the bridge, never sends the erase datagram, and on port 1027 passes only requests
//! the `tr_hl2::control` policy allows (it has no request for the transmit permission or the bias
//! unlock). The update stops before the flash is touched if the HL2 reports transmit on or the
//! stream is not stopped. An HL2 driven by this firmware cannot transmit.

use alloc::collections::VecDeque;
use alloc::string::String;
use core::fmt::Write as _;

use tr_fabric::hl2link::Hl2Link;
use tr_fabric::system::System;
use tr_hl2::dhcp::{DhcpServer, PORT_CLIENT, PORT_SERVER};
use tr_hl2::control::{self, Hl2Control, TelemetryReading};
use tr_hl2::cpuload::{self, CpuLoader, Image, LoadError, LoadState};
/// The HL2 program image type of [`SessionConfig::hl2_program`], for callers without `tr_hl2`.
pub use tr_hl2::cpuload::Image as Hl2Image;
use tr_hl2::filter::{band_filter_bits, Band};
use tr_hl2::msg::{self as hmsg, Request, Response};
use tr_hl2::protocol as hp;
use tr_net::rings::MacRings;
use tr_regs::RegisterSpace;

use crate::hl2net::{build_arp_reply, build_udp, parse, Endpoint, Rx, BROADCAST_IP, BROADCAST_MAC, MAX_FRAME};
use crate::station::Action;

/// Where played TX samples go inside the HL2 while the operator's TX switch is on. Neither
/// drives the transmit DAC.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TxSink {
    /// A register in the HL2 that only counts them. Reception goes on.
    VirtualDac,
    /// They replace the ADC samples in the RX stream: the station hears itself and nothing else.
    Echo,
}

impl TxSink {
    /// The value for register 0x31 (duplex) that selects this sink.
    pub fn duplex_value(self) -> u32 {
        match self {
            TxSink::VirtualDac => hp::REG_DUPLEX_ENABLE,
            TxSink::Echo => hp::REG_DUPLEX_ENABLE | hp::REG_DUPLEX_ECHO,
        }
    }
}

/// True for the register writes this firmware may send (the table in the module text).
///
/// Register 0x00 passes only the N2ADR filter bits, 0x0A only an RX gain code between 0x40 and
/// 0x40 + 60, 0x30 only raw mode on or off (no test pattern), and 0x31 only off, virtual DAC or
/// echo. Every other register, TX gain and PA enable included, is refused.
pub fn command_allowed(addr: u8, value: u32) -> bool {
    const FILTER_BITS: u32 = 0x7F << 17;
    match addr {
        hp::REG_ADDR_FRONTEND => value & !FILTER_BITS == 0,
        hp::REG_ADDR_RX_GAIN => (0x40..=0x40 + 60).contains(&value),
        hp::REG_ADDR_RAWMODE => value & 0xFFFE == 0,
        hp::REG_ADDR_DUPLEX => value & !(hp::REG_DUPLEX_ENABLE | hp::REG_DUPLEX_ECHO) == 0 && value != hp::REG_DUPLEX_ECHO,
        _ => false,
    }
}

/// True for the port 1027 datagrams this firmware may send: message-layer datagrams whose every
/// request passes the `tr_hl2::control` policy (`check_datagram`; limits are never loosened, since
/// none were read). Register bridge datagrams (first byte 0x4E) never pass here; the program
/// update's go through [`update_datagram_allowed`], and only while an update runs.
pub fn msg_datagram_allowed(d: &[u8]) -> bool {
    d.first() != Some(&0x4E) && control::check_datagram(d, None).is_ok()
}

/// True for the datagrams of a program update of `image`: register bridge requests that write only
/// the HL2 CPU's RAM from 0x800 and its control, boot address, firmware state and result registers
/// with the values of the sequence, and read only the RAM, the CPU system block and the status
/// block (`tr_hl2::cpuload::check_request`); and the one boot ROM console datagram that saves
/// exactly `image` (`tr_hl2::cpuload::save_datagram_allowed`). Nothing else reaches the flash: no
/// bridge write to 0x4003_0000, no erase. The session sends them only while an update runs.
pub fn update_datagram_allowed(d: &[u8], image: &Image) -> bool {
    match d.first() {
        Some(&0x4E) => cpuload::check_request(d).is_ok(),
        Some(&0x01) => cpuload::save_datagram_allowed(d, image),
        _ => false,
    }
}

/// Updates of the HL2's program per HL2 start (an HL2 start is seen as its DHCP request).
pub const MAX_UPDATE_ATTEMPTS: u8 = 2;
/// The stream must have been quiet (no raw frame counted) this long before the save datagram goes out.
const QUIET_MS: i64 = 100;
/// How long an update waits for a stale stream to die down (Stop is sent again every 500 ms) before it gives up.
const QUIET_WAIT_MS: i64 = 6_000;

/// Whether the HL2 speaks the message layer (port 1027).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MsgLayer {
    /// Not tried yet.
    Off,
    /// HELLO sent, no answer yet.
    Probing,
    /// HELLO answered. While streaming, telemetry, gain and filter go through it only if the frame
    /// size leaves room for its replies.
    Up,
    /// The HL2's saved program is being updated. HELLO is sent again when that is done.
    Updating,
    /// HELLO not answered: no message-layer firmware. Port 1025 only, until the next stream start.
    Absent,
}

/// The HL2's saved message-layer program, compared with the one built into the firmware.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProgramState {
    /// The firmware was built without the program (no `HL2_MSG_BIN`).
    NotBuiltIn,
    /// Built in, not checked yet.
    Idle,
    /// The HL2 runs the built-in version.
    UpToDate,
    Updating,
    /// Saved, started and answering with the built-in version.
    Updated,
    Failed(LoadError),
}

impl core::fmt::Display for ProgramState {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            ProgramState::NotBuiltIn => write!(f, "not built in"),
            ProgramState::Idle => write!(f, "not checked"),
            ProgramState::UpToDate => write!(f, "up to date"),
            ProgramState::Updating => write!(f, "updating"),
            ProgramState::Updated => write!(f, "updated"),
            ProgramState::Failed(e) => write!(f, "failed: {e}"),
        }
    }
}

/// What the station shows about the HL2 beyond the stream.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Hl2Status {
    pub msg_layer: MsgLayer,
    /// The HL2's saved program.
    pub program: ProgramState,
    /// Latest telemetry (message layer only).
    pub telemetry: Option<TelemetryReading>,
    /// The RX gain last set, dB.
    pub rx_gain_db: i32,
}

/// The N2ADR filter group of an FT8 dial frequency.
pub fn filter_band(dial_hz: u32) -> Band {
    match dial_hz {
        0..=2_500_000 => Band::B160m,
        2_500_001..=4_500_000 => Band::B80m,
        4_500_001..=8_000_000 => Band::B60_40m,
        8_000_001..=15_000_000 => Band::B30_20m,
        15_000_001..=22_000_000 => Band::B17_15m,
        _ => Band::B12_10m,
    }
}

/// Settings of a session: our addresses, the raw frame size and the RX gain.
#[derive(Clone, Copy, Debug)]
pub struct SessionConfig {
    /// Our MAC and IP address on the link.
    pub us: Endpoint,
    /// Our UDP port: source of every datagram, destination of the stream, and the TX framer's source.
    pub port: u16,
    /// Raw samples per UDP frame (948 fills a 1,500-byte packet).
    pub samples_per_frame: u16,
    /// RX gain in dB for the set-up, converted to the register 0x0A code. [`Hl2Session::set_rx_gain_db`] changes it.
    pub rx_gain_db: i32,
    /// Where played TX samples go while the operator's TX switch is on.
    pub tx_sink: TxSink,
    /// The HL2's message-layer program (`msg.bin`, linked at 0x800) with its version and build-time
    /// CRC-32: saved to the HL2's flash sector when HELLO reports another version or goes
    /// unanswered. `None`: the HL2's program is never touched.
    pub hl2_program: Option<Image<'static>>,
}

impl Default for SessionConfig {
    fn default() -> Self {
        SessionConfig { us: Endpoint { mac: [0x02, 0x54, 0x52, 0x00, 0x00, 0x01], ip: [10, 99, 0, 1] }, port: 51_000, samples_per_frame: 948, rx_gain_db: 20, tx_sink: TxSink::VirtualDac, hl2_program: None }
    }
}

/// Where the session is in the sequence described in the module text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    /// No Ethernet link (no receive clock from the PHY).
    NoLink,
    /// Broadcasting discovery requests until an HL2 answers.
    Discovering,
    /// Something answered discovery that is not the raw front-end image. Left alone.
    WrongImage,
    /// Sending the stop and the register writes, one at a time, each waiting for its reply.
    Configuring,
    /// Stream stopped: HELLO, and an update of the HL2's program if it needs one.
    Program,
    /// Start sent, waiting for the first raw frame.
    Starting,
    /// Raw frames are arriving.
    Streaming,
}

/// One datagram to the HL2 that is queued and, for a register write, acknowledged.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Cmd {
    Stop,
    Reg(u8, u32),
}

/// Counters for the console and for tests.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SessionStats {
    /// Discovery requests broadcast.
    pub discoveries_sent: u32,
    /// DHCP offers and acknowledgements sent to the HL2.
    pub dhcp_replies: u32,
    /// ARP replies sent for our address.
    pub arp_replies: u32,
    /// UDP datagrams no rule above took: how many, and the last one's source port, destination port, length and first 4 bytes.
    pub other_udp: u32,
    /// Port 1027 datagrams from the HL2: how many, and the last one's length and first 12 bytes.
    pub p1027_n: u32,
    /// Frames the parser did not take as ARP or UDP: how many, and the last one's length, EtherType, IP protocol, IP flags/fragment word and ports.
    pub unparsed_n: u32,
    /// Every frame the loop took, and a sample (length, first 24 bytes) of about every 1,000th.
    pub polled: u32,
    pub sample: (u16, [u8; 24]),
    /// Frames taken by the DHCP arm and by the command-port arm (what the HL2 sends from port 1025 or 1024).
    pub dhcp_seen: u32,
    pub cmdport_seen: u32,
    pub arp_seen: u32,
    pub unparsed_last: (u16, u16, u8, u16, u16, u16),
    pub p1027_last: (u16, [u8; 12]),
    pub other_last: (u16, u16, u16, [u8; 4]),
    /// Register writes handed to the link (repeats included).
    pub commands_sent: u32,
    /// Register writes that got no reply after all tries.
    pub commands_unanswered: u32,
    /// Register writes that `command_allowed` rejected.
    pub commands_refused: u32,
    /// Start commands sent.
    pub starts: u32,
    /// Times the stream or the Ethernet link was lost while streaming.
    pub link_losses: u32,
    /// Datagrams dropped because the link's transmit path was busy.
    pub tx_busy: u32,
    /// Stops broadcast because a stream from an earlier session flooded the receive ring.
    pub flood_stops: u32,
    /// Port 1027 datagrams sent, and the ones [`msg_datagram_allowed`] stopped.
    pub msg_sent: u32,
    pub msg_refused: u32,
    /// Datagrams of the program update sent, and the ones [`update_datagram_allowed`] stopped.
    pub update_sent: u32,
    pub update_refused: u32,
    /// Program updates started.
    pub updates: u32,
    /// RX gain changes sent (either port).
    pub gain_writes: u32,
}

/// Time between discovery requests; four times as long after a wrong image answered.
const DISCOVERY_EVERY_MS: i64 = 500;
/// How long a register write waits for its reply before it is repeated.
const ACK_WAIT_MS: i64 = 200;
/// Attempts for a register write, and for the start command.
const TRIES: u8 = 3;
/// How long to wait for the first raw frame after a start.
const START_WAIT_MS: i64 = 1_000;
/// No raw frame for this long while streaming counts as a lost stream.
const STREAM_LOSS_MS: i64 = 1_000;
/// Telemetry period asked of the message layer, ms.
pub const TELEMETRY_PERIOD_MS: u16 = 500;
/// Port 1027 datagrams sent per poll at most.
const MSG_TX_PER_POLL: usize = 4;

/// Non-raw frames per discovery interval above which a stream is taken to flood the CPU receive ring. A streaming
/// HL2 sends about 40,000 in 0.5 s; DHCP, ARP and replies are a few.
pub const FLOOD_FRAMES: u32 = 200;

/// The session state machine. It owns the CPU packet path (`pkt`) and borrows the register space
/// of the link; the main loop calls [`Hl2Session::poll`] and passes the station's actions in.
pub struct Hl2Session<'a, R: RegisterSpace, P: MacRings> {
    regs: &'a R,
    pkt: P,
    cfg: SessionConfig,
    dhcp: DhcpServer,
    phase: Phase,
    hl2: Option<([u8; 6], [u8; 4])>,
    band: Band,
    queue: VecDeque<Cmd>,
    /// Command sent and not yet answered: the command, tries so far, when to give up waiting.
    inflight: Option<(Cmd, u8, i64)>,
    /// Next time something periodic is due in the current phase.
    due_ms: i64,
    start_tries: u8,
    last_frames: u32,
    last_frame_ms: i64,
    /// The link's non-raw frame count at the last discovery tick.
    last_other: u32,
    link_lost: bool,
    /// The message-layer session while streaming.
    ctl: Option<Hl2Control>,
    msg_layer: MsgLayer,
    /// Firmware restarts seen by `ctl` (the telemetry period goes back to 100 ms on each).
    ctl_restarts: u32,
    /// The program update in progress.
    updater: Option<CpuLoader<'static>>,
    program: ProgramState,
    /// Updates since the HL2 last started (its DHCP request), and whether this stream start had one.
    update_attempts: u8,
    updated_this_stream: bool,
    /// HELLO is sent to check the version an update saved.
    verifying: bool,
    /// Since when no raw frame was counted (the HL2 is quiet), in the program phase.
    quiet_since_ms: i64,
    /// An update that waits for the HL2 to go quiet: the image, since when, and when Stop goes out next.
    pending_update: Option<Image<'static>>,
    pending_since_ms: i64,
    next_stop_ms: i64,
    /// The frame size leaves room for port 1027 replies while streaming.
    reply_room: bool,
    /// How long the last finished update took, ms.
    last_update_ms: Option<u32>,
    pub stats: SessionStats,
}

/// An IPv4 address as the u32 the link's registers take (first octet in the top byte).
fn ip_u32(ip: [u8; 4]) -> u32 {
    u32::from_be_bytes(ip)
}

impl<'a, R: RegisterSpace, P: MacRings> Hl2Session<'a, R, P> {
    /// Writes our address into the link's registers and starts looking for the HL2.
    pub fn new(regs: &'a R, pkt: P, cfg: SessionConfig, dial_hz: u32) -> Self {
        let link = Hl2Link::new(regs);
        link.set_our_address(cfg.us.mac, ip_u32(cfg.us.ip), cfg.port);
        link.set_rx_enable(true);
        let mut dhcp = DhcpServer::default_addressing();
        dhcp.server_ip = cfg.us.ip;
        dhcp.offer_ip = [cfg.us.ip[0], cfg.us.ip[1], cfg.us.ip[2], cfg.us.ip[3].wrapping_add(1)];
        Hl2Session {
            regs,
            pkt,
            cfg,
            dhcp,
            phase: Phase::Discovering,
            hl2: None,
            band: filter_band(dial_hz),
            queue: VecDeque::new(),
            inflight: None,
            due_ms: 0,
            start_tries: 0,
            last_frames: 0,
            last_frame_ms: 0,
            last_other: Hl2Link::new(regs).counters().other_frames,
            link_lost: false,
            ctl: None,
            msg_layer: MsgLayer::Off,
            ctl_restarts: 0,
            updater: None,
            program: if cfg.hl2_program.is_some() { ProgramState::Idle } else { ProgramState::NotBuiltIn },
            update_attempts: 0,
            updated_this_stream: false,
            verifying: false,
            quiet_since_ms: 0,
            pending_update: None,
            pending_since_ms: 0,
            next_stop_ms: 0,
            reply_room: {
                let (n, _) = hp::clamp_samples_per_frame(cfg.samples_per_frame);
                hp::reply_room(n, hp::HEADER_LEN_V3) >= hp::LONGEST_REPLY
            },
            last_update_ms: None,
            stats: SessionStats::default(),
        }
    }

    /// The current phase.
    pub fn phase(&self) -> Phase {
        self.phase
    }

    /// The HL2's MAC and IP once it has answered discovery.
    pub fn hl2(&self) -> Option<([u8; 6], [u8; 4])> {
        self.hl2
    }

    /// True once after the stream or the link was lost. The caller must then switch TX off
    /// (`Station::force_tx_off`): this module does not switch the HL2's TX sink back on by itself.
    pub fn take_link_lost(&mut self) -> bool {
        core::mem::take(&mut self.link_lost)
    }

    /// Builds a UDP frame from our address and hands it to the link. False if it did not fit or the link was busy.
    fn send(&mut self, dst_mac: [u8; 6], dst_ip: [u8; 4], src_port: u16, dst_port: u16, payload: &[u8]) -> bool {
        let mut frame = [0u8; MAX_FRAME];
        let Some(n) = build_udp(&mut frame, &self.cfg.us, src_port, dst_mac, dst_ip, dst_port, payload) else { return false };
        let ok = self.pkt.transmit(&frame[..n]);
        if !ok {
            self.stats.tx_busy += 1;
        }
        ok
    }

    /// Sends a stop or a register write to the HL2's command ports. Register writes go through `command_allowed` first.
    fn send_cmd(&mut self, cmd: Cmd) -> bool {
        let Some((mac, ip)) = self.hl2 else { return false };
        match cmd {
            Cmd::Stop => self.send(mac, ip, self.cfg.port, hp::PORT_START_STOP, &hp::cmd_stop()),
            Cmd::Reg(addr, value) => {
                if !command_allowed(addr, value) {
                    self.stats.commands_refused += 1;
                    return false;
                }
                self.stats.commands_sent += 1;
                self.send(mac, ip, self.cfg.port, hp::PORT_CMD, &hp::build_command_packet(addr, value))
            }
        }
    }

    fn queue_reg(&mut self, addr: u8, value: u32) {
        // A newer value for the same register replaces one still waiting.
        self.queue.retain(|c| !matches!(c, Cmd::Reg(a, _) if *a == addr));
        self.queue.push_back(Cmd::Reg(addr, value));
    }

    /// Back to discovery. `lost` marks a lost stream for [`Hl2Session::take_link_lost`].
    fn restart(&mut self, now_ms: i64, lost: bool) {
        if lost {
            self.link_lost = true;
            self.stats.link_losses += 1;
        }
        self.queue.clear();
        self.inflight = None;
        self.ctl = None;
        self.msg_layer = MsgLayer::Off;
        self.verifying = false;
        if self.updater.take().is_some() {
            // abandoned with the link; the next stream start may try again
            self.program = ProgramState::Idle;
        }
        self.phase = Phase::Discovering;
        self.due_ms = now_ms;
        self.last_other = Hl2Link::new(self.regs).counters().other_frames;
    }

    /// What the station logic decided, as far as it concerns the HL2: the band's filter relays,
    /// and the operator's TX switch.
    pub fn on_action(&mut self, action: &Action) {
        match action {
            Action::Retune { dial_hz } => {
                self.band = filter_band(*dial_hz);
                if self.phase == Phase::Streaming {
                    let sent = self.msg_layer == MsgLayer::Up && self.ctl.as_mut().is_some_and(|c| c.set_band_filter(self.band).is_ok());
                    if !sent {
                        self.queue_reg(hp::REG_ADDR_FRONTEND, band_filter_bits(self.band));
                    }
                }
            }
            // The operator's TX switch, on: the one place register 0x31 gets a value other than 0.
            Action::ArmTx if self.phase == Phase::Streaming => self.queue_reg(hp::REG_ADDR_DUPLEX, self.cfg.tx_sink.duplex_value()),
            Action::DisarmTx if self.hl2.is_some() && matches!(self.phase, Phase::Streaming | Phase::Discovering) => {
                if self.phase == Phase::Streaming {
                    self.queue_reg(hp::REG_ADDR_DUPLEX, 0);
                } else {
                    // The stream is gone; say it once anyway, unacknowledged, in case the HL2 hears.
                    self.send_cmd(Cmd::Reg(hp::REG_ADDR_DUPLEX, 0));
                }
            }
            _ => {}
        }
    }

    /// The RX gain (AD9866 PGA), -12 to +48 dB (clamped). While streaming it is sent at once, through
    /// the message layer when it is up and as a port 1025 register write otherwise; it is also the
    /// gain of every later set-up.
    pub fn set_rx_gain_db(&mut self, db: i32) {
        let db = db.clamp(hp::RX_GAIN_MIN_DB, hp::RX_GAIN_MAX_DB);
        self.cfg.rx_gain_db = db;
        if self.phase != Phase::Streaming {
            return;
        }
        self.stats.gain_writes += 1;
        let sent = self.msg_layer == MsgLayer::Up && self.ctl.as_mut().is_some_and(|c| c.set_rx_gain_db(db).is_ok());
        if !sent {
            self.queue_reg(hp::REG_ADDR_RX_GAIN, hp::rx_gain_value(db).0);
        }
    }

    /// The message layer's state, the latest telemetry and the RX gain.
    pub fn hl2_status(&self) -> Hl2Status {
        Hl2Status { msg_layer: self.msg_layer, program: self.program, telemetry: self.ctl.as_ref().and_then(|c| c.telemetry()), rx_gain_db: self.cfg.rx_gain_db }
    }

    /// The program update in progress (for tests and the console).
    pub fn updater(&self) -> Option<&CpuLoader<'static>> {
        self.updater.as_ref()
    }

    /// How long the last finished program update took, from its first datagram to done or failed, ms.
    pub fn last_update_ms(&self) -> Option<u32> {
        self.last_update_ms
    }

    /// The message-layer client, while there is one (for tests and the console).
    pub fn control(&self) -> Option<&Hl2Control> {
        self.ctl.as_ref()
    }

    /// Starts the message layer: HELLO and the filter latch read are queued by `Hl2Control::new`.
    fn start_msg_layer(&mut self, now_ms: i64) {
        let seed = (now_ms as u32).wrapping_mul(2_654_435_761) ^ Hl2Link::new(self.regs).counters().raw_frames;
        self.ctl = Some(Hl2Control::new(seed));
        self.ctl_restarts = 0;
        self.msg_layer = MsgLayer::Probing;
    }

    /// Results, telemetry period, and the datagrams due on port 1027. Returns the HELLO result
    /// (the firmware version, or `None` for no answer) when one arrived in this call.
    fn service_msg_layer(&mut self, now_ms: i64) -> Option<Option<u32>> {
        let c = self.ctl.as_mut()?;
        let now = now_ms as u32;
        let mut hello = None;
        while let Some(done) = c.poll_completion() {
            match (done.request, done.result) {
                (Request::Hello, Ok(Response::Hello(h))) if self.msg_layer == MsgLayer::Probing => {
                    self.msg_layer = MsgLayer::Up;
                    hello = Some(Some(h.firmware_version));
                }
                (Request::Hello, Err(_)) if self.msg_layer == MsgLayer::Probing => hello = Some(None),
                _ => {}
            }
        }
        if c.msg().restarts() != self.ctl_restarts {
            self.ctl_restarts = c.msg().restarts();
            if self.msg_layer == MsgLayer::Up && self.reply_room {
                let _ = c.set_telemetry_period(TELEMETRY_PERIOD_MS);
            }
        }
        if hello.is_none() || matches!(hello, Some(Some(_))) {
            self.transmit_msgs(now);
        }
        hello
    }

    /// Sends the message-layer datagrams that are due.
    fn transmit_msgs(&mut self, now: u32) {
        let Some((mac, ip)) = self.hl2 else { return };
        let mut out = [0u8; hmsg::MAX_DATAGRAM];
        let mut sent = 0;
        while sent < MSG_TX_PER_POLL {
            let Some(c) = self.ctl.as_mut() else { break };
            let Some(n) = c.poll_transmit(now, &mut out) else { break };
            sent += 1;
            if !msg_datagram_allowed(&out[..n]) {
                self.stats.msg_refused += 1;
                continue;
            }
            self.stats.msg_sent += 1;
            self.send(mac, ip, self.cfg.port, hp::PORT_BRIDGE, &out[..n]);
        }
    }

    /// The stream is stopped and the set-up done: HELLO, and the program check.
    fn enter_program_phase(&mut self, now_ms: i64) {
        self.phase = Phase::Program;
        self.updated_this_stream = false;
        self.verifying = false;
        self.quiet_since_ms = now_ms;
        self.last_frames = Hl2Link::new(self.regs).counters().raw_frames;
        self.start_msg_layer(now_ms);
    }

    /// The program phase: HELLO, then the version check, the update and the HELLO after it. Ends
    /// in `Starting`.
    fn program_phase(&mut self, now_ms: i64) {
        let frames = Hl2Link::new(self.regs).counters().raw_frames;
        if frames != self.last_frames {
            self.last_frames = frames;
            self.quiet_since_ms = now_ms;
        }
        if let Some(img) = self.pending_update {
            if now_ms - self.quiet_since_ms >= QUIET_MS {
                self.pending_update = None;
                if !self.start_update(img) {
                    self.go_start(now_ms);
                }
            } else if now_ms - self.pending_since_ms > QUIET_WAIT_MS {
                self.pending_update = None;
                self.program = ProgramState::Failed(LoadError::NotQuiet);
                self.go_start(now_ms);
            } else if now_ms >= self.next_stop_ms {
                self.send_cmd(Cmd::Stop);
                self.next_stop_ms = now_ms + 500;
            }
            return;
        }
        if self.updater.is_some() {
            let quiet = now_ms - self.quiet_since_ms >= QUIET_MS;
            self.service_updater(now_ms, quiet);
            return;
        }
        let Some(hello) = self.service_msg_layer(now_ms) else {
            if self.ctl.is_none() {
                self.go_start(now_ms);
            }
            return;
        };
        let image = self.cfg.hl2_program;
        if self.verifying {
            self.verifying = false;
            self.program = match (hello, image) {
                (Some(v), Some(img)) if v == img.version => ProgramState::Updated,
                (Some(v), Some(img)) => ProgramState::Failed(LoadError::VersionMismatch { want: img.version, got: v }),
                _ => ProgramState::Failed(LoadError::NoHello),
            };
        } else if let Some(img) = image {
            match hello {
                Some(v) if v == img.version => {
                    // after a failed update this stream start, the failure stays on the screen
                    if !self.updated_this_stream && !matches!(self.program, ProgramState::Updated) {
                        self.program = ProgramState::UpToDate;
                    }
                }
                // an older or different version, or no program at all
                // an update waits until the stream has died down, so that the save is never sent beside a stream
                _ if !self.updated_this_stream && self.update_attempts < MAX_UPDATE_ATTEMPTS => {
                    self.pending_update = Some(img);
                    self.pending_since_ms = now_ms;
                    self.next_stop_ms = now_ms;
                    self.program = ProgramState::Updating;
                    return;
                }
                _ => {}
            }
        }
        if hello.is_none() {
            self.msg_layer = MsgLayer::Absent;
            self.ctl = None;
        }
        self.go_start(now_ms);
    }

    /// Starts an update of the HL2's program, if this stream start had none and fewer than
    /// [`MAX_UPDATE_ATTEMPTS`] were made since the HL2 started.
    fn start_update(&mut self, img: Image<'static>) -> bool {
        if self.updated_this_stream || self.update_attempts >= MAX_UPDATE_ATTEMPTS {
            return false;
        }
        match CpuLoader::update(&img) {
            Ok(l) => {
                self.updater = Some(l);
                self.update_attempts += 1;
                self.updated_this_stream = true;
                self.program = ProgramState::Updating;
                self.msg_layer = MsgLayer::Updating;
                self.ctl = None;
                self.stats.updates += 1;
                true
            }
            Err(e) => {
                self.program = ProgramState::Failed(e);
                false
            }
        }
    }

    /// The datagrams of the update in progress, and its end: HELLO again either way.
    fn service_updater(&mut self, now_ms: i64, quiet: bool) {
        let (Some((mac, ip)), Some(img)) = (self.hl2, self.cfg.hl2_program) else { return };
        let now = now_ms as u32;
        let mut out = [0u8; tr_hl2::bridge::MAX_PACKET];
        for _ in 0..MSG_TX_PER_POLL {
            let Some(l) = self.updater.as_mut() else { return };
            l.set_quiet(quiet);
            let Some(n) = l.poll_transmit(now, &mut out) else { break };
            if !update_datagram_allowed(&out[..n], &img) {
                self.stats.update_refused += 1;
                continue;
            }
            self.stats.update_sent += 1;
            self.send(mac, ip, self.cfg.port, hp::PORT_BRIDGE, &out[..n]);
        }
        let Some(state) = self.updater.as_ref().map(|l| l.state()) else { return };
        match state {
            LoadState::Running(_) => {}
            LoadState::Done => {
                self.last_update_ms = self.updater.take().and_then(|l| l.elapsed_ms());
                self.verifying = true;
                self.start_msg_layer(now_ms);
            }
            LoadState::Failed(e) => {
                self.last_update_ms = self.updater.take().and_then(|l| l.elapsed_ms());
                self.program = ProgramState::Failed(e);
                // the HL2 may run its old program (or the new one from RAM): ask, without another update
                self.start_msg_layer(now_ms);
            }
        }
    }

    /// The program phase is over: start the stream. Without room for port 1027 replies while it
    /// runs, the message layer rests until the next stop.
    fn go_start(&mut self, now_ms: i64) {
        if self.msg_layer == MsgLayer::Up && self.reply_room {
            if let Some(c) = self.ctl.as_mut() {
                let _ = c.set_telemetry_period(TELEMETRY_PERIOD_MS);
            }
        } else {
            if self.msg_layer == MsgLayer::Up {
                // its telemetry could not leave the HL2 while it streams: switch it off, unacknowledged
                if let Some(c) = self.ctl.as_mut() {
                    let _ = c.set_telemetry_period(0);
                }
                self.transmit_msgs(now_ms as u32);
            }
            self.ctl = None;
        }
        self.phase = Phase::Starting;
        self.start_tries = 0;
        self.due_ms = now_ms;
        self.last_frames = Hl2Link::new(self.regs).counters().raw_frames;
    }

    /// Handles up to eight received frames per call: ARP and DHCP requests for us, and replies from the HL2.
    fn receive(&mut self, now_ms: i64) {
        let mut buf = [0u8; MAX_FRAME];
        for _ in 0..64 {
            let Some(n) = self.pkt.receive(&mut buf) else { break };
            self.stats.polled += 1;
            if self.stats.polled % 997 == 1 {
                let mut h = [0u8; 24];
                let k = n.min(24);
                h[..k].copy_from_slice(&buf[..k]);
                self.stats.sample = (n as u16, h);
            }
            match parse(&buf[..n]) {
                Rx::ArpRequest { sender_mac, sender_ip, target_ip } if target_ip == self.cfg.us.ip => {
                    self.stats.arp_seen += 1;
                    let mut reply = [0u8; 60];
                    let len = build_arp_reply(&mut reply, &self.cfg.us, sender_mac, sender_ip);
                    self.pkt.transmit(&reply[..len]);
                    self.stats.arp_replies += 1;
                }
                Rx::Udp { dst_port: PORT_SERVER, payload, .. } => {
                    self.stats.dhcp_seen += 1;
                    let mut reply = [0u8; 400];
                    if let Some(len) = self.dhcp.handle(payload, &mut reply) {
                        // The client has no address yet: the answer goes to everyone.
                        self.send(BROADCAST_MAC, BROADCAST_IP, PORT_SERVER, PORT_CLIENT, &reply[..len]);
                        self.stats.dhcp_replies += 1;
                        // an HL2 asks for an address when it starts: a new chance for an update
                        self.update_attempts = 0;
                    }
                }
                Rx::Udp { src_mac, src_ip, src_port: hp::PORT_BRIDGE, dst_port, payload } if dst_port == self.cfg.port && Some((src_mac, src_ip)) == self.hl2 => {
                    let mut head = [0u8; 12];
                    let k = payload.len().min(12);
                    head[..k].copy_from_slice(&payload[..k]);
                    self.stats.p1027_n += 1;
                    if payload.first() == Some(&0x4E) || payload.first() == Some(&b'H') || self.stats.p1027_n < 3 {
                        self.stats.p1027_last = (payload.len() as u16, head);
                    }
                    if let Some(c) = self.ctl.as_mut() {
                        c.handle_datagram(now_ms as u32, payload);
                    }
                    if let Some(l) = self.updater.as_mut() {
                        l.handle_datagram(now_ms as u32, payload);
                    }
                }
                Rx::Udp { src_mac, src_ip, src_port, dst_port, payload } if dst_port == self.cfg.port && (src_port == hp::PORT_CMD || src_port == hp::PORT_START_STOP) => {
                    self.stats.cmdport_seen += 1;
                    let Some(reply) = hp::parse_discovery_response(payload) else { continue };
                    if src_ip == [0; 4] {
                        continue; // a radio without an address cannot be streamed from yet
                    }
                    match self.phase {
                        Phase::Discovering | Phase::WrongImage => self.discovered(now_ms, src_mac, src_ip, &reply),
                        // Any reply from the HL2's command port answers the command in flight.
                        _ if Some((src_mac, src_ip)) == self.hl2 && matches!(self.inflight, Some((Cmd::Reg(..), _, _))) => self.inflight = None,
                        _ => {}
                    }
                }
                Rx::Udp { src_port, dst_port, payload, .. } => {
                    let mut head = [0u8; 4];
                    let k = payload.len().min(4);
                    head[..k].copy_from_slice(&payload[..k]);
                    self.stats.other_udp += 1;
                    self.stats.other_last = (src_port, dst_port, payload.len() as u16, head);
                }
                _ => {
                    let f = &buf[..n];
                    let g = |i: usize| if f.len() > i + 1 { u16::from_be_bytes([f[i], f[i + 1]]) } else { 0 };
                    self.stats.unparsed_n += 1;
                    self.stats.unparsed_last = (n as u16, g(12), f.get(23).copied().unwrap_or(0), g(20), g(34), g(36));
                }
            }
        }
    }

    /// An HL2 answered discovery: remember its address and queue the set-up commands, or park in `WrongImage`.
    fn discovered(&mut self, now_ms: i64, mac: [u8; 6], ip: [u8; 4], reply: &hp::DiscoveryResponse) {
        if !reply.is_rawfront_image() {
            self.phase = Phase::WrongImage;
            self.hl2 = None;
            self.due_ms = now_ms + 4 * DISCOVERY_EVERY_MS;
            return;
        }
        self.hl2 = Some((mac, ip));
        Hl2Link::new(self.regs).set_hl2_address(mac, ip_u32(ip));
        let (n, _) = hp::clamp_samples_per_frame(self.cfg.samples_per_frame);
        let (gain, _) = hp::rx_gain_value(self.cfg.rx_gain_db);
        self.queue.clear();
        self.queue.push_back(Cmd::Stop);
        self.queue.push_back(Cmd::Reg(hp::REG_ADDR_RAWMODE, hp::reg_raw_value(true, false, false, n)));
        self.queue.push_back(Cmd::Reg(hp::REG_ADDR_FRONTEND, band_filter_bits(self.band)));
        self.queue.push_back(Cmd::Reg(hp::REG_ADDR_RX_GAIN, gain));
        self.inflight = None;
        self.phase = Phase::Configuring;
    }

    /// Works the command queue. Returns false if a command went unanswered three times.
    fn pump(&mut self, now_ms: i64) -> bool {
        if let Some((cmd, tries, deadline)) = self.inflight {
            if now_ms < deadline {
                return true;
            }
            match cmd {
                Cmd::Stop => self.inflight = None,
                Cmd::Reg(..) if tries < TRIES => {
                    self.send_cmd(cmd);
                    self.inflight = Some((cmd, tries + 1, now_ms + ACK_WAIT_MS));
                    return true;
                }
                Cmd::Reg(..) => {
                    self.inflight = None;
                    self.stats.commands_unanswered += 1;
                    return false;
                }
            }
        }
        if let Some(cmd) = self.queue.pop_front() {
            self.send_cmd(cmd);
            // A stop has no reply: give the HL2 a moment, then go on.
            self.inflight = Some((cmd, 1, now_ms + if cmd == Cmd::Stop { 50 } else { ACK_WAIT_MS }));
        }
        true
    }

    /// Call every pass of the main loop with a monotonic time in ms. Never blocks.
    pub fn poll(&mut self, now_ms: i64) {
        self.receive(now_ms);
        if System::new(self.regs).status().rx_domain_dead {
            if self.phase != Phase::NoLink {
                let lost = self.phase == Phase::Streaming;
                self.restart(now_ms, lost);
                self.phase = Phase::NoLink;
            }
            return;
        }
        let link = Hl2Link::new(self.regs);
        match self.phase {
            Phase::NoLink => self.restart(now_ms, false),
            Phase::Discovering | Phase::WrongImage => {
                if now_ms >= self.due_ms {
                    self.due_ms = now_ms + DISCOVERY_EVERY_MS * if self.phase == Phase::WrongImage { 4 } else { 1 };
                    let other = link.counters().other_frames;
                    let flood = other.wrapping_sub(self.last_other) > FLOOD_FRAMES;
                    self.last_other = other;
                    if flood && self.phase == Phase::Discovering {
                        // A stream nobody here started: its reply would be lost in the ring. Stop it first.
                        self.stats.flood_stops += 1;
                        self.send(BROADCAST_MAC, BROADCAST_IP, self.cfg.port, hp::PORT_START_STOP, &hp::cmd_stop());
                    } else {
                        self.stats.discoveries_sent += 1;
                        self.send(BROADCAST_MAC, BROADCAST_IP, self.cfg.port, hp::PORT_CMD, &hp::build_discovery_request());
                    }
                }
            }
            Phase::Configuring => {
                if !self.pump(now_ms) {
                    self.restart(now_ms, false);
                } else if self.queue.is_empty() && self.inflight.is_none() {
                    self.enter_program_phase(now_ms);
                }
            }
            Phase::Program => self.program_phase(now_ms),
            Phase::Starting => {
                if link.counters().raw_frames != self.last_frames {
                    self.phase = Phase::Streaming;
                    self.last_frames = link.counters().raw_frames;
                    self.last_frame_ms = now_ms;
                } else if now_ms >= self.due_ms {
                    if self.start_tries >= TRIES {
                        self.restart(now_ms, false);
                    } else if let Some((mac, ip)) = self.hl2 {
                        self.start_tries += 1;
                        self.stats.starts += 1;
                        self.due_ms = now_ms + START_WAIT_MS;
                        self.send(mac, ip, self.cfg.port, hp::PORT_START_STOP, &hp::cmd_start());
                    }
                }
            }
            Phase::Streaming => {
                let frames = link.counters().raw_frames;
                if frames != self.last_frames {
                    self.last_frames = frames;
                    self.last_frame_ms = now_ms;
                } else if now_ms - self.last_frame_ms >= STREAM_LOSS_MS {
                    self.send_cmd(Cmd::Stop);
                    self.restart(now_ms, true);
                    return;
                }
                self.pump(now_ms);
                if self.reply_room {
                    self.service_msg_layer(now_ms);
                }
            }
        }
    }

    /// Stops the stream (before a restart of the firmware, or to hand the HL2 to a PC).
    pub fn stop(&mut self, now_ms: i64) {
        if self.hl2.is_some() {
            self.send_cmd(Cmd::Stop);
        }
        self.restart(now_ms + 3_600_000, false);
    }

    /// One line for the screen, and whether samples are arriving.
    pub fn status(&self) -> (String, bool) {
        let mut s = String::new();
        let _ = match self.phase {
            Phase::NoLink => write!(s, "HL2: no Ethernet link"),
            Phase::Discovering => write!(s, "HL2: looking for the radio"),
            Phase::WrongImage => write!(s, "HL2: radio found, but not the raw front-end image"),
            Phase::Configuring => write!(s, "HL2: found, setting up"),
            Phase::Program if self.program == ProgramState::Updating => write!(s, "HL2: updating its program"),
            Phase::Program => write!(s, "HL2: checking its program"),
            Phase::Starting => write!(s, "HL2: starting the stream"),
            Phase::Streaming => {
                let link = Hl2Link::new(self.regs);
                let c = link.counters();
                let sb = link.safety_byte();
                let _ = write!(s, "HL2: streaming, {} gaps, {} CRC errors", c.gaps, c.crc_errors);
                if sb & tr_fabric::hl2link::safety::TRIP != 0 {
                    let _ = write!(s, ", TRIP");
                }
                if sb & tr_fabric::hl2link::safety::OVER_TEMP != 0 {
                    let _ = write!(s, ", over temperature");
                }
                Ok(())
            }
        };
        if self.stats.link_losses > 0 {
            let _ = write!(s, " (lost {} time(s))", self.stats.link_losses);
        }
        (s, self.phase == Phase::Streaming)
    }

    /// One short line for the screen: temperature and power codes, or why there are none, and the
    /// state of the HL2's program ("HL2 program: up to date / updating / updated / failed: reason").
    pub fn hl2_line(&self) -> String {
        let mut s = String::new();
        let st = self.hl2_status();
        let program = match st.program {
            ProgramState::UpToDate | ProgramState::Updating | ProgramState::Updated | ProgramState::Failed(_) => Some(st.program),
            _ => None,
        };
        let _ = match (st.msg_layer, st.telemetry, program) {
            (_, _, Some(p @ (ProgramState::Updating | ProgramState::Failed(_)))) => write!(s, "HL2 program: {p}"),
            (MsgLayer::Up, Some(t), p) => {
                let _ = write!(s, "HL2 {:.1} C, fwd {}, rev {}", t.temperature_c(), t.forward_code(), t.reverse_code());
                match p {
                    Some(p) => write!(s, ", program {p}"),
                    None => Ok(()),
                }
            }
            (_, _, Some(p)) => write!(s, "HL2 program: {p}"),
            (MsgLayer::Up, None, None) if self.phase == Phase::Streaming && !self.reply_room => write!(s, "HL2 telemetry: off while streaming"),
            (MsgLayer::Up, None, None) | (MsgLayer::Probing | MsgLayer::Updating, _, None) => write!(s, "HL2 telemetry: waiting"),
            (MsgLayer::Absent, _, None) => write!(s, "HL2 telemetry: none (no message layer)"),
            (MsgLayer::Off, _, None) => Ok(()),
        };
        s
    }

    /// One line for the console: message layer, telemetry with bias, interlock and safety byte, gain.
    pub fn hl2_report(&self) -> String {
        let mut s = String::new();
        let st = self.hl2_status();
        let _ = write!(s, "HL2 message layer {:?}, RX gain {} dB, port 1027 sent {} refused {}", st.msg_layer, st.rx_gain_db, self.stats.msg_sent, self.stats.msg_refused);
        let _ = write!(s, ", HL2 program {}", st.program);
        let _ = write!(s, ", other udp {} last {:?}, from 1027 {} last {:x?}, dhcp {} cmdport {} arp {}, polled {} sample {:x?}, unparsed {} last {:x?}", self.stats.other_udp, self.stats.other_last, self.stats.p1027_n, self.stats.p1027_last, self.stats.dhcp_seen, self.stats.cmdport_seen, self.stats.arp_seen, self.stats.polled, self.stats.sample, self.stats.unparsed_n, self.stats.unparsed_last);
        if let Some(l) = self.updater.as_ref() {
            let (done, all) = l.progress();
            let _ = write!(s, " ({done} of {all} words, {:?})", l.state());
        }
        if self.stats.updates > 0 {
            let _ = write!(s, ", updates {} datagrams sent {} refused {}", self.stats.updates, self.stats.update_sent, self.stats.update_refused);
        }
        if let Some(t) = st.telemetry {
            let i = t.interlock();
            let _ = write!(
                s,
                ", {:.1} C, fwd {}, rev {}, bias {:.3} A, safety 0x{:02x}, interlock tx {} trip {} cutoffs 0x{:02x}",
                t.temperature_c(),
                t.forward_code(),
                t.reverse_code(),
                t.bias_current_a(),
                t.safety(),
                i.tx_on as u8,
                i.trip_latched as u8,
                i.cutoffs
            );
        }
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_listed_register_writes_pass() {
        assert!(command_allowed(0x30, (948 << 16) | 1));
        assert!(command_allowed(0x30, 0));
        assert!(!command_allowed(0x30, (948 << 16) | 3), "test pattern is not ours to set");
        assert!(command_allowed(0x00, band_filter_bits(Band::B30_20m)));
        assert!(!command_allowed(0x00, 1 << 13), "RX antenna bit is not used");
        assert!(command_allowed(0x0A, 0x40 + 20 + 12));
        // Register 0x31: off, virtual DAC, echo. Never the real DAC.
        assert!(command_allowed(0x31, 0) && command_allowed(0x31, 1) && command_allowed(0x31, 5));
        assert!(!command_allowed(0x31, 2) && !command_allowed(0x31, 3) && !command_allowed(0x31, 7));
        assert!(!command_allowed(0x31, 4), "echo without duplex is not a value we send");
        // TX gain / PA enable, reboot, AD9866, I2C, clocks: none.
        for addr in [0x01u8, 0x09, 0x0E, 0x32, 0x39, 0x3A, 0x3B, 0x3C, 0x3D] {
            assert!(!command_allowed(addr, 0) && !command_allowed(addr, 1));
        }
        assert_eq!(TxSink::VirtualDac.duplex_value(), 1);
        assert_eq!(TxSink::Echo.duplex_value(), 5);
    }

    #[test]
    fn filter_groups_of_the_ft8_dials() {
        let dials = [1_840_000, 3_573_000, 5_357_000, 7_074_000, 10_136_000, 14_074_000, 18_100_000, 21_074_000, 24_915_000, 28_074_000];
        let want = [Band::B160m, Band::B80m, Band::B60_40m, Band::B60_40m, Band::B30_20m, Band::B30_20m, Band::B17_15m, Band::B17_15m, Band::B12_10m, Band::B12_10m];
        for (d, w) in dials.iter().zip(want) {
            assert_eq!(filter_band(*d), w, "{d}");
        }
    }
}
