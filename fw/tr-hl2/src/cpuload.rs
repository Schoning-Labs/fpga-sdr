// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Loads a program into the RAM of the HL2's CPU through the register bridge (Etherbone, port
//! 1027) and starts it ([`CpuLoader::new`], what `hl2fw.py run` of the Hermes-Lite2 repository,
//! branch `hl2-rawfront-release`, `software/hl2fw/hl2fw.py`, does for a raw binary), or loads it
//! and has the boot ROM save it to the HL2's flash sector for its saved program, then restarts the
//! CPU into it ([`CpuLoader::update`], what `hl2fw.py save` followed by `hl2fw.py boot` does). The
//! memory map, the system block and the boot ROM are in that repository's `docs/rawfront/RISCV.md`,
//! the bridge in `docs/rawfront/PROTOCOL.md` section 8, the console datagram in section 11.
//!
//! The sequence, one bridge request in flight at a time, each request a write with a read-back in
//! the same packet (the bridge does writes before reads, so the reply confirms the write):
//!
//! 1. Probe: read the system block ID ("RV32"), its info word (RAM size), the control register,
//!    the transmit-safety byte, the status block inputs and the HL2's uptime. Stop if there is no
//!    CPU system, if the image does not fit the RAM, or if the HL2 reports transmit on.
//! 2. Hold the CPU in reset (control = 1) and check that it is.
//! 3. Write the image from 0x800 in chunks of 48 words, reading every word back in the same
//!    request. A chunk whose read-back differs is written again; after six tries the load fails.
//! 4. Set the boot address (0x800 for `msg.bin`, which is linked at 0x800 with its entry there),
//!    read the safety byte and the inputs once more, and stop if transmit is on.
//! 5. Control = boot RAM with reset, firmware state = 0, control = boot RAM: the CPU leaves reset,
//!    the boot ROM jumps to the boot address and sets the firmware state to 3 (application).
//! 6. Read the firmware state every 20 ms until it is 3 (done), 4 (the program stopped on a trap,
//!    failed), or 2 s passed (failed).
//!
//! An update ([`CpuLoader::update`]) does steps 1 to 4 the same way, then:
//!
//! 5. Restart the CPU in the boot ROM (control = stay in ROM with reset, firmware state = 0,
//!    control = stay in ROM) and wait until the ROM reports itself idle (state 2).
//! 6. Clear the result register, and read it back with the firmware state, the safety byte and the
//!    inputs. Stop before anything reaches the flash if transmit is on, if the ROM is not idle or
//!    if the caller does not report the HL2 quiet ([`CpuLoader::set_quiet`]).
//! 7. Send the boot ROM console datagram `01 'S'` with load address, length, entry, version and
//!    the CRC-32 computed at build time ([`build_save_datagram`]). The ROM checks the RAM against
//!    that CRC before it erases anything (result 2 if it differs), then erases the sector, writes
//!    the 32-byte header and the image, and reads everything back.
//! 8. Read the result register every 200 ms until it shows the save ('S'). The datagram is sent
//!    again (at most three sends) only while the ROM is idle with no result, which means it was
//!    lost. After 60 s without a result the update fails and the CPU is left alone.
//! 9. Result 0: restart the CPU normally (control = reset, firmware state = 0, control = 0); the
//!    ROM starts the saved program and reports state 3. Any other result fails the update; the CPU
//!    is restarted normally when nothing was written (bad arguments, CRC mismatch, locked: the old
//!    saved program runs again), and from RAM when the flash write itself failed (flash or verify
//!    error: the sector no longer holds a valid program, so the ROM would stay idle at the next
//!    power-up; the new image, verified in RAM, runs until then).
//!
//! Every write the loader builds is checked by [`write_allowed`]: RAM 0x800 to 0x3FFF, and the
//! control, boot address, firmware state and result registers with the few values the sequences
//! use. Nothing else, so the loader cannot reach the flash sector (0x4003_0000), the packet
//! interface, the boot ROM, the RAM below 0x800, the command bus (register 0x3A reboots the HL2)
//! or `TX_PERMIT`. The flash is written only by the boot ROM, on the one console datagram
//! [`save_datagram_allowed`] passes: the save of exactly the embedded image. No erase datagram
//! (`01 'E'`) is ever built. [`check_request`] applies the bridge rule to a finished datagram, for
//! a whitelist.
//!
//! [`CpuLoader`] is a transport-independent state machine like `msg::MsgClient`: the caller feeds
//! it every datagram from port 1027 with `handle_datagram`, sends what `poll_transmit` returns to
//! port 1027, and watches `state`. Lost datagrams are covered by repeating the request after
//! 100 ms (reads are idempotent, and writing the same words again is harmless). No allocation.

use core::fmt;

use crate::bridge::{self, status};
use crate::protocol::{SAFETY_HOST_MOX, SAFETY_PA_KEYED};

/// CPU system block, 0x4001_0000 (RISCV.md "System block").
pub mod sys {
    pub const BASE: u32 = 0x4001_0000;
    /// Reads 0x5256_3332 ("RV32").
    pub const ID: u32 = BASE;
    /// [15:8] RAM kB.
    pub const INFO: u32 = BASE + 0x04;
    /// [0] reset, [1] halt, [2] stay in boot ROM, [3] boot RAM. Bridge only.
    pub const CTRL: u32 = BASE + 0x08;
    /// Where the boot ROM jumps with control bit 3. Bridge only.
    pub const BOOT_ADDR: u32 = BASE + 0x0C;
    /// [31:24] 1 ROM busy, 2 ROM idle, 3 application, 4 stopped.
    pub const FW_STATUS: u32 = BASE + 0x10;
    /// Last boot ROM result: [31:24] 'S' save, 'E' erase, 'B' boot; [23:16] sequence; [7:0] code.
    pub const FW_RESULT: u32 = BASE + 0x14;
    /// Milliseconds since power-up.
    pub const MS: u32 = BASE + 0x18;
    /// [15:0] CPU resets, [16] in reset, [17] halted.
    pub const STATUS: u32 = BASE + 0x2C;

    pub const ID_EXPECTED: u32 = 0x5256_3332;
    pub const CTRL_RESET: u32 = 1;
    pub const CTRL_HALT: u32 = 2;
    pub const CTRL_STAY_ROM: u32 = 4;
    pub const CTRL_BOOT_RAM: u32 = 8;
    pub const STATUS_IN_RESET: u32 = 1 << 16;
    pub const FWS_ROM_BUSY: u32 = 1;
    pub const FWS_ROM_IDLE: u32 = 2;
    pub const FWS_APP: u32 = 3;
    pub const FWS_STOPPED: u32 = 4;
    /// Result codes (RISCV.md "System block", offset 0x14).
    pub const FWR_OK: u8 = 0;
    pub const FWR_BAD_ARGS: u8 = 1;
    pub const FWR_CRC_MISMATCH: u8 = 2;
    pub const FWR_FLASH_ERR: u8 = 3;
    pub const FWR_VERIFY_ERR: u8 = 4;
    pub const FWR_LOCKED: u8 = 5;
    pub const FWR_NO_IMAGE: u8 = 6;
    pub const FWR_BAD_IMAGE: u8 = 7;
    pub const FWR_WRONG_CPU: u8 = 8;
}

/// What a boot ROM result code means.
pub fn result_text(code: u8) -> &'static str {
    match code {
        sys::FWR_OK => "ok",
        sys::FWR_BAD_ARGS => "bad arguments",
        sys::FWR_CRC_MISMATCH => "CRC mismatch",
        sys::FWR_FLASH_ERR => "flash error",
        sys::FWR_VERIFY_ERR => "verify error",
        sys::FWR_LOCKED => "flash locked (network flashing since the HL2 started)",
        sys::FWR_NO_IMAGE => "no saved program",
        sys::FWR_BAD_IMAGE => "saved program not valid",
        sys::FWR_WRONG_CPU => "saved program is for another CPU",
        _ => "unknown code",
    }
}

/// A program image with the version and CRC-32 it was built with.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Image<'a> {
    pub bytes: &'a [u8],
    /// The version the boot ROM writes into the saved header, and the program reports in HELLO.
    pub version: u32,
    /// zlib CRC-32 of `bytes`, computed when the firmware was built.
    pub crc32: u32,
}

/// zlib CRC-32 (the boot ROM's `crc32`, Python's `zlib.crc32`).
pub fn crc32(data: &[u8]) -> u32 {
    let mut c = !0u32;
    for &b in data {
        c ^= b as u32;
        for _ in 0..8 {
            c = if c & 1 != 0 { (c >> 1) ^ 0xEDB8_8320 } else { c >> 1 };
        }
    }
    !c
}

/// Length of the boot ROM's save datagram: `01 'S'` and five little-endian words.
pub const SAVE_DATAGRAM_LEN: usize = 22;

/// The boot ROM console datagram that saves `image`, loaded at 0x800 with its entry there, to the
/// flash sector (PROTOCOL.md section 11): `01 'S'`, load address, length, entry, version, CRC-32.
pub fn build_save_datagram(image: &Image) -> [u8; SAVE_DATAGRAM_LEN] {
    let mut d = [0u8; SAVE_DATAGRAM_LEN];
    d[0] = 0x01;
    d[1] = b'S';
    for (i, v) in [APP_START, image.bytes.len() as u32, APP_START, image.version, image.crc32].into_iter().enumerate() {
        d[2 + 4 * i..6 + 4 * i].copy_from_slice(&v.to_le_bytes());
    }
    d
}

/// True only for the save datagram of exactly `image`, and only if `image`'s CRC-32 matches its
/// bytes. Every other boot ROM console datagram (erase among them) and every other header is
/// refused. For the whitelist of a caller.
pub fn save_datagram_allowed(d: &[u8], image: &Image) -> bool {
    crc32(image.bytes) == image.crc32 && d == build_save_datagram(image)
}

/// First byte of the application RAM (below it is the boot ROM's workspace).
pub const APP_START: u32 = 0x800;
/// End of the RAM (exclusive): 16 kB.
pub const APP_END: u32 = 0x4000;
/// Largest image: 14 kB.
pub const MAX_IMAGE: usize = (APP_END - APP_START) as usize;
/// Words per write request. 48 words written and 48 read back make a 404-byte request, inside
/// the bridge's 512-byte limit (hl2fw.py uses the same number).
pub const CHUNK_WORDS: usize = 48;
/// A request without a usable reply is sent again after this many ms.
pub const RETRY_MS: u32 = 100;
/// Sends of one request before the load fails.
pub const TRIES: u8 = 6;
/// Time the program has to report itself running after the release.
pub const START_TIMEOUT_MS: u32 = 2_000;
/// Time the boot ROM has to start the saved program (it copies it from the flash byte by byte).
pub const FLASH_BOOT_TIMEOUT_MS: u32 = 5_000;
/// Result register reads while the save runs.
pub const SAVE_POLL_MS: u32 = 200;
/// A save datagram is sent again if the ROM is still idle with no result this long after it.
pub const SAVE_RESEND_MS: u32 = 1_500;
/// Sends of the save datagram at most.
pub const SAVE_SENDS: u8 = 3;
/// Time the save has to report a result (hl2fw.py waits as long).
pub const SAVE_TIMEOUT_MS: u32 = 60_000;
/// Firmware state reads while waiting for that.
pub const START_POLL_MS: u32 = 20;
/// Status block inputs bit 4: transmit on.
pub const INPUT_TRANSMIT_ON: u32 = 1 << 4;

/// Where the load is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    Probe,
    HoldReset,
    WriteRam,
    BootAddress,
    PrepareRelease,
    ClearState,
    Release,
    WaitStart,
    ClearResult,
    Save,
    WaitSave,
}

impl Step {
    fn name(self) -> &'static str {
        match self {
            Step::Probe => "reading the CPU state",
            Step::HoldReset => "holding the CPU in reset",
            Step::WriteRam => "writing the RAM",
            Step::BootAddress => "setting the boot address",
            Step::PrepareRelease | Step::ClearState | Step::Release => "releasing the CPU",
            Step::WaitStart => "waiting for the program",
            Step::ClearResult => "preparing the save",
            Step::Save | Step::WaitSave => "saving to the flash",
        }
    }
}

/// Why a load did not happen or did not finish.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LoadError {
    /// The image is empty.
    Empty,
    /// The image does not fit between its load address and the end of the RAM.
    TooLarge { len: usize },
    /// The load address or entry is outside the application RAM, or a write the loader built
    /// was refused by [`write_allowed`].
    AddressRefused,
    /// The system block does not read "RV32": this HL2 image has no CPU.
    NoCpu { id: u32 },
    /// The HL2 reports transmit on (safety byte or inputs). Nothing more is written.
    TransmitOn { safety: u8, inputs: u32 },
    /// No usable reply after [`TRIES`] sends.
    NoReply(Step),
    /// The control register does not show the CPU held in reset.
    NotHeld { ctrl: u32 },
    /// A RAM word read back different from the image.
    Verify { addr: u32 },
    /// The boot address read back different from the entry.
    BootAddress { read: u32 },
    /// The program stopped on a trap right after the start (firmware state 4).
    Stopped { fw_status: u32 },
    /// The program did not report itself running within [`START_TIMEOUT_MS`].
    NotStarted { fw_status: u32 },
    /// The embedded image's CRC-32 is not the one computed when the firmware was built. Nothing
    /// is written.
    ImageCrc { want: u32, got: u32 },
    /// The caller did not report the HL2 quiet (stream stopped). Nothing reaches the flash.
    NotQuiet,
    /// The boot ROM did not report itself idle after the restart into it. Nothing reaches the flash.
    NoRom { fw_status: u32 },
    /// The boot ROM's save result was not 0 ([`result_text`]).
    Save { code: u8 },
    /// No save result within [`SAVE_TIMEOUT_MS`].
    SaveTimeout,
    /// After the save, the boot ROM did not start the saved program (it stays idle).
    BootFailed { fw_status: u32 },
    /// After the update, HELLO reports another firmware version than the image's.
    VersionMismatch { want: u32, got: u32 },
    /// After the update, HELLO is not answered.
    NoHello,
}

impl fmt::Display for LoadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match *self {
            LoadError::Empty => write!(f, "empty image"),
            LoadError::TooLarge { len } => write!(f, "image of {len} bytes does not fit the RAM"),
            LoadError::AddressRefused => write!(f, "address outside the application RAM"),
            LoadError::NoCpu { id } => write!(f, "no CPU in this HL2 image (ID 0x{id:08x})"),
            LoadError::TransmitOn { safety, inputs } => write!(f, "HL2 reports transmit on (safety 0x{safety:02x}, inputs 0x{inputs:x})"),
            LoadError::NoReply(s) => write!(f, "no reply while {}", s.name()),
            LoadError::NotHeld { ctrl } => write!(f, "CPU not held in reset (control 0x{ctrl:x})"),
            LoadError::Verify { addr } => write!(f, "RAM word 0x{addr:04x} does not read back"),
            LoadError::BootAddress { read } => write!(f, "boot address reads 0x{read:08x}"),
            LoadError::Stopped { fw_status } => write!(f, "program stopped on a trap (state 0x{fw_status:08x})"),
            LoadError::NotStarted { fw_status } => write!(f, "program did not start (state 0x{fw_status:08x})"),
            LoadError::ImageCrc { want, got } => write!(f, "image CRC-32 {got:08x}, built with {want:08x}"),
            LoadError::NotQuiet => write!(f, "HL2 not quiet"),
            LoadError::NoRom { fw_status } => write!(f, "boot ROM not idle (state 0x{fw_status:08x})"),
            LoadError::Save { code } => write!(f, "save: {}", result_text(code)),
            LoadError::SaveTimeout => write!(f, "no save result within 60 s"),
            LoadError::BootFailed { fw_status } => write!(f, "saved program did not start (state 0x{fw_status:08x})"),
            LoadError::VersionMismatch { want, got } => write!(f, "HL2 reports version 0x{got:08x}, not 0x{want:08x}"),
            LoadError::NoHello => write!(f, "no answer to HELLO after the update"),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LoadState {
    Running(Step),
    Done,
    Failed(LoadError),
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LoadStats {
    pub datagrams_sent: u32,
    /// Sends after the first of the same request.
    pub retries: u32,
    pub replies: u32,
}

/// True if the loader may write `values` to consecutive words from `addr`.
pub fn write_allowed(addr: u32, values: &[u32]) -> bool {
    if values.is_empty() {
        return true;
    }
    if addr & 3 != 0 || values.len() > bridge::MAX_COUNT {
        return false;
    }
    let Some(end) = addr.checked_add(4 * values.len() as u32) else { return false };
    if addr >= APP_START && end <= APP_END {
        return true;
    }
    if values.len() != 1 {
        return false;
    }
    let v = values[0];
    match addr {
        // reset, boot RAM (with reset), stay in ROM (with reset), and 0: a normal start
        sys::CTRL => matches!(v, 0 | sys::CTRL_RESET | 9 | sys::CTRL_BOOT_RAM | 5 | sys::CTRL_STAY_ROM),
        sys::BOOT_ADDR => (APP_START..APP_END).contains(&v) && v & 1 == 0,
        sys::FW_STATUS | sys::FW_RESULT => v == 0,
        _ => false,
    }
}

/// True if the loader may read `addr`: the RAM, the system block, the status block.
fn read_allowed(addr: u32) -> bool {
    addr < APP_END || (sys::BASE..sys::BASE + 0x40).contains(&addr) || (status::BASE..status::BASE + 0x8000).contains(&addr)
}

fn be32(d: &[u8], i: usize) -> u32 {
    u32::from_be_bytes([d[i], d[i + 1], d[i + 2], d[i + 3]])
}

/// Checks a finished bridge request (as `poll_transmit` builds it) against the loader's rules:
/// the Etherbone header this crate builds, writes that pass [`write_allowed`], and reads of the
/// RAM, the system block and the status block only. For the whitelist of a caller.
pub fn check_request(d: &[u8]) -> Result<(), LoadError> {
    let bad = Err(LoadError::AddressRefused);
    if d.len() < 12 || d.len() > bridge::MAX_PACKET || d[..4] != [0x4E, 0x6F, 0x10, 0x44] || d[9] != 0x0F {
        return bad;
    }
    let (w, r) = (d[10] as usize, d[11] as usize);
    let len = 12 + if w > 0 { 4 + 4 * w } else { 0 } + if r > 0 { 4 + 4 * r } else { 0 };
    if w > CHUNK_WORDS || r > CHUNK_WORDS || d.len() != len {
        return bad;
    }
    let mut p = 12;
    if w > 0 {
        let base = be32(d, p);
        let mut v = [0u32; CHUNK_WORDS];
        for (i, x) in v.iter_mut().enumerate().take(w) {
            *x = be32(d, p + 4 + 4 * i);
        }
        if !write_allowed(base, &v[..w]) {
            return bad;
        }
        p += 4 + 4 * w;
    }
    if r > 0 {
        for i in 0..r {
            if !read_allowed(be32(d, p + 4 + 4 * i)) {
                return bad;
            }
        }
    }
    Ok(())
}

/// One bridge request: words written from `waddr`, then addresses read.
struct Req {
    waddr: u32,
    nw: usize,
    values: [u32; CHUNK_WORDS],
    nr: usize,
    reads: [u32; CHUNK_WORDS],
}

impl Req {
    fn new() -> Req {
        Req { waddr: 0, nw: 0, values: [0; CHUNK_WORDS], nr: 0, reads: [0; CHUNK_WORDS] }
    }
    fn read(addrs: &[u32]) -> Req {
        let mut r = Req::new();
        r.reads[..addrs.len()].copy_from_slice(addrs);
        r.nr = addrs.len();
        r
    }
    fn write_read(addr: u32, value: u32, addrs: &[u32]) -> Req {
        let mut r = Req::read(addrs);
        r.waddr = addr;
        r.values[0] = value;
        r.nw = 1;
        r
    }
}

/// What a reply means for the step in flight.
enum Outcome {
    Next,
    /// Send the request again (a lost write, or a late reply to an earlier request); fail with
    /// this error when the tries are used up.
    Retry(LoadError),
    Fail(LoadError),
    /// Not there yet: read again after this many ms.
    Wait(u32),
}

/// What the loader is for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Goal {
    /// Start the image from RAM.
    Run,
    /// Save the image to the flash sector and start the saved program.
    Save { version: u32, crc32: u32 },
}

/// The loader. See the module text.
pub struct CpuLoader<'a> {
    image: &'a [u8],
    base: u32,
    entry: u32,
    goal: Goal,
    /// Control bits of the restart in progress (boot RAM, stay in ROM, or 0 for a normal start).
    release_ctrl: u32,
    /// Why an update failed, while the CPU is restarted after it; the update ends with this error.
    pending: Option<LoadError>,
    /// The save result was 0.
    saved: bool,
    quiet: bool,
    save_sends: u8,
    save_sent_ms: u32,
    save_started_ms: u32,
    words: usize,
    state: LoadState,
    /// Next word of the image to write.
    offset: usize,
    tries: u8,
    awaiting: bool,
    due: u32,
    last_problem: Option<LoadError>,
    started_ms: Option<u32>,
    start_deadline: u32,
    finished_ms: Option<u32>,
    uptime_ms: Option<u32>,
    stats: LoadStats,
}

impl<'a> CpuLoader<'a> {
    /// A raw binary linked at 0x800 with its entry there (`msg.bin`; `hl2fw.py` loads a raw
    /// binary the same way).
    pub fn new(image: &'a [u8]) -> Result<CpuLoader<'a>, LoadError> {
        CpuLoader::with_layout(image, APP_START, APP_START)
    }

    /// An image for another load address and entry, both inside the application RAM.
    pub fn with_layout(image: &'a [u8], base: u32, entry: u32) -> Result<CpuLoader<'a>, LoadError> {
        if image.is_empty() {
            return Err(LoadError::Empty);
        }
        let words = image.len().div_ceil(4);
        if base & 3 != 0 || !(APP_START..APP_END).contains(&base) {
            return Err(LoadError::AddressRefused);
        }
        if base as usize + 4 * words > APP_END as usize {
            return Err(LoadError::TooLarge { len: image.len() });
        }
        if entry < base || entry as usize >= base as usize + 4 * words || entry & 1 != 0 {
            return Err(LoadError::AddressRefused);
        }
        Ok(CpuLoader {
            image,
            base,
            entry,
            goal: Goal::Run,
            release_ctrl: sys::CTRL_BOOT_RAM,
            pending: None,
            saved: false,
            quiet: false,
            save_sends: 0,
            save_sent_ms: 0,
            save_started_ms: 0,
            words,
            state: LoadState::Running(Step::Probe),
            offset: 0,
            tries: 0,
            awaiting: false,
            due: 0,
            last_problem: None,
            started_ms: None,
            start_deadline: 0,
            finished_ms: None,
            uptime_ms: None,
            stats: LoadStats::default(),
        })
    }

    /// An update: `image` (linked at 0x800 with its entry there) is loaded, saved to the flash
    /// sector by the boot ROM, and started from there. Refused with nothing sent if the image's
    /// CRC-32 is not the one it was built with.
    pub fn update(image: &Image<'a>) -> Result<CpuLoader<'a>, LoadError> {
        let got = crc32(image.bytes);
        if got != image.crc32 {
            return Err(LoadError::ImageCrc { want: image.crc32, got });
        }
        let mut l = CpuLoader::new(image.bytes)?;
        l.goal = Goal::Save { version: image.version, crc32: image.crc32 };
        l.release_ctrl = sys::CTRL_STAY_ROM;
        Ok(l)
    }

    /// Whether the HL2 is quiet (its stream stopped, nothing else talking to it). An update sends
    /// the save datagram only while this is true; the caller sets it on every pass.
    pub fn set_quiet(&mut self, quiet: bool) {
        self.quiet = quiet;
    }

    /// True for an update (save to the flash), false for a start from RAM.
    pub fn is_update(&self) -> bool {
        matches!(self.goal, Goal::Save { .. })
    }

    pub fn state(&self) -> LoadState {
        self.state
    }

    pub fn stats(&self) -> LoadStats {
        self.stats
    }

    /// Image words written and verified, and the total.
    pub fn progress(&self) -> (usize, usize) {
        (self.offset, self.words)
    }

    /// The HL2's milliseconds since power-up, as the probe read them.
    pub fn hl2_uptime_ms(&self) -> Option<u32> {
        self.uptime_ms
    }

    /// Time from the first datagram to Done or Failed, ms.
    pub fn elapsed_ms(&self) -> Option<u32> {
        Some(self.finished_ms?.wrapping_sub(self.started_ms?))
    }

    fn step(&self) -> Option<Step> {
        match self.state {
            LoadState::Running(s) => Some(s),
            _ => None,
        }
    }

    fn finish(&mut self, now: u32, state: LoadState) {
        self.state = state;
        self.awaiting = false;
        self.finished_ms = Some(now);
    }

    fn go(&mut self, now: u32, step: Step) {
        self.state = LoadState::Running(step);
        self.tries = 0;
        self.awaiting = false;
        self.last_problem = None;
        self.due = now;
    }

    fn word(&self, i: usize) -> u32 {
        let mut b = [0u8; 4];
        for (k, x) in b.iter_mut().enumerate() {
            *x = *self.image.get(4 * i + k).unwrap_or(&0);
        }
        u32::from_le_bytes(b)
    }

    fn request(&self, step: Step) -> Req {
        use sys::*;
        match step {
            Step::Probe => Req::read(&[ID, INFO, CTRL, status::SAFETY_BYTE, status::INPUTS, MS]),
            Step::HoldReset => Req::write_read(CTRL, CTRL_RESET, &[CTRL, STATUS]),
            Step::WriteRam => {
                let n = (self.words - self.offset).min(CHUNK_WORDS);
                let a = self.base + 4 * self.offset as u32;
                let mut r = Req::new();
                r.waddr = a;
                r.nw = n;
                r.nr = n;
                for i in 0..n {
                    r.values[i] = self.word(self.offset + i);
                    r.reads[i] = a + 4 * i as u32;
                }
                r
            }
            Step::BootAddress => Req::write_read(BOOT_ADDR, self.entry, &[BOOT_ADDR, status::SAFETY_BYTE, status::INPUTS, CTRL]),
            Step::PrepareRelease => Req::write_read(CTRL, self.release_ctrl | CTRL_RESET, &[CTRL]),
            Step::ClearState => Req::write_read(FW_STATUS, 0, &[FW_STATUS]),
            Step::Release => Req::write_read(CTRL, self.release_ctrl, &[CTRL]),
            Step::WaitStart => Req::read(&[FW_STATUS]),
            Step::ClearResult => Req::write_read(FW_RESULT, 0, &[FW_RESULT, FW_STATUS, status::SAFETY_BYTE, status::INPUTS]),
            // the save is a console datagram, built in poll_transmit
            Step::Save => Req::new(),
            Step::WaitSave => Req::read(&[FW_RESULT, FW_STATUS]),
        }
    }

    /// The next datagram to send to port 1027, if one is due. Call often (every pass of a loop).
    pub fn poll_transmit(&mut self, now: u32, out: &mut [u8]) -> Option<usize> {
        let step = self.step()?;
        if self.started_ms.is_none() {
            self.started_ms = Some(now);
            self.due = now;
        }
        if !crate::msg::time_reached(now, self.due) {
            return None;
        }
        if self.tries >= TRIES {
            // no reply in time, or replies that asked for a repeat, every time
            let e = self.last_problem.unwrap_or(LoadError::NoReply(step));
            self.finish(now, LoadState::Failed(e));
            return None;
        }
        if step == Step::Save {
            return self.send_save(now, out);
        }
        let r = self.request(step);
        if !write_allowed(r.waddr, &r.values[..r.nw]) {
            self.finish(now, LoadState::Failed(LoadError::AddressRefused));
            return None;
        }
        let n = bridge::build_write_read(r.waddr, &r.values[..r.nw], &r.reads[..r.nr], out)?;
        if self.tries > 0 {
            self.stats.retries += 1;
        }
        self.tries += 1;
        self.stats.datagrams_sent += 1;
        self.awaiting = true;
        self.due = now.wrapping_add(RETRY_MS);
        Some(n)
    }

    /// Feeds one datagram received from port 1027. Anything that is not a bridge reply of the
    /// size the request in flight expects is ignored.
    pub fn handle_datagram(&mut self, now: u32, d: &[u8]) {
        let Some(step) = self.step() else { return };
        if !self.awaiting || d.first() != Some(&0x4E) {
            return;
        }
        let r = self.request(step);
        let mut v = [0u32; bridge::MAX_COUNT];
        match bridge::parse_reply(d, &mut v) {
            Some(n) if n == r.nr && d.len() == 16 + 4 * n => {}
            _ => return,
        }
        self.stats.replies += 1;
        let v = &v[..r.nr];
        let outcome = self.judge(now, step, &r, v);
        match outcome {
            Outcome::Next => {}
            Outcome::Retry(e) => {
                self.last_problem = Some(e);
                self.awaiting = false;
                self.due = now;
            }
            Outcome::Fail(e) => self.finish(now, LoadState::Failed(e)),
            Outcome::Wait(ms) => {
                self.tries = 0;
                self.awaiting = false;
                self.last_problem = None;
                self.due = now.wrapping_add(ms);
            }
        }
    }

    /// The save datagram, if the HL2 is still quiet; otherwise the update stops here, before the flash.
    fn send_save(&mut self, now: u32, out: &mut [u8]) -> Option<usize> {
        let Goal::Save { version, crc32 } = self.goal else {
            self.finish(now, LoadState::Failed(LoadError::AddressRefused));
            return None;
        };
        if !self.quiet {
            self.restart(now, 0, Some(LoadError::NotQuiet));
            return None;
        }
        let d = build_save_datagram(&Image { bytes: self.image, version, crc32 });
        let o = out.get_mut(..SAVE_DATAGRAM_LEN)?;
        o.copy_from_slice(&d);
        if self.save_sends == 0 {
            self.save_started_ms = now;
        }
        self.save_sends += 1;
        self.save_sent_ms = now;
        self.stats.datagrams_sent += 1;
        self.go(now, Step::WaitSave);
        self.due = now.wrapping_add(SAVE_POLL_MS);
        Some(SAVE_DATAGRAM_LEN)
    }

    /// Restarts the CPU with control bits `ctrl` (0: the ROM starts the saved program; boot RAM:
    /// the ROM jumps to the image in RAM). With `error`, the update ends with it after the restart.
    fn restart(&mut self, now: u32, ctrl: u32, error: Option<LoadError>) {
        self.release_ctrl = ctrl;
        if error.is_some() {
            self.pending = error;
        }
        self.go(now, Step::PrepareRelease);
    }

    /// The restart has ended (`outcome` is how): the next step, or the end.
    fn restarted(&mut self, now: u32, outcome: Result<(), LoadError>) -> Outcome {
        if let Some(e) = self.pending {
            self.finish(now, LoadState::Failed(e));
            return Outcome::Next;
        }
        match (self.goal, self.release_ctrl, outcome) {
            (Goal::Save { .. }, sys::CTRL_STAY_ROM, Err(e)) => {
                // nothing was saved: let the old saved program run again
                self.restart(now, 0, Some(e));
                Outcome::Next
            }
            (_, _, Err(e)) => Outcome::Fail(e),
            (Goal::Save { .. }, sys::CTRL_STAY_ROM, Ok(())) => {
                self.go(now, Step::ClearResult);
                Outcome::Next
            }
            (Goal::Save { .. }, _, Ok(())) if !self.saved => Outcome::Fail(LoadError::AddressRefused),
            (_, _, Ok(())) => {
                self.offset = self.words;
                self.finish(now, LoadState::Done);
                Outcome::Next
            }
        }
    }

    fn transmit_on(safety: u32, inputs: u32) -> Option<LoadError> {
        let s = safety as u8;
        if s & (SAFETY_PA_KEYED | SAFETY_HOST_MOX) != 0 || inputs & INPUT_TRANSMIT_ON != 0 {
            Some(LoadError::TransmitOn { safety: s, inputs })
        } else {
            None
        }
    }

    fn judge(&mut self, now: u32, step: Step, r: &Req, v: &[u32]) -> Outcome {
        use sys::*;
        match step {
            Step::Probe => {
                if v[0] != ID_EXPECTED {
                    return Outcome::Fail(LoadError::NoCpu { id: v[0] });
                }
                let ram_end = (((v[1] >> 8) & 0xFF) << 10).min(APP_END);
                if self.base as usize + 4 * self.words > ram_end as usize {
                    return Outcome::Fail(LoadError::TooLarge { len: self.image.len() });
                }
                if let Some(e) = Self::transmit_on(v[3], v[4]) {
                    return Outcome::Fail(e);
                }
                self.uptime_ms = Some(v[5]);
                self.go(now, Step::HoldReset);
            }
            Step::HoldReset => {
                if v[0] & CTRL_RESET == 0 || v[1] & STATUS_IN_RESET == 0 {
                    return Outcome::Retry(LoadError::NotHeld { ctrl: v[0] });
                }
                self.offset = 0;
                self.go(now, Step::WriteRam);
            }
            Step::WriteRam => {
                if let Some(i) = (0..r.nw).find(|&i| v[i] != r.values[i]) {
                    return Outcome::Retry(LoadError::Verify { addr: r.reads[i] });
                }
                self.offset += r.nw;
                if self.offset >= self.words {
                    self.go(now, Step::BootAddress);
                } else {
                    self.go(now, Step::WriteRam);
                }
            }
            Step::BootAddress => {
                if let Some(e) = Self::transmit_on(v[1], v[2]) {
                    if self.is_update() {
                        // the CPU is held in reset: let the saved program run again
                        self.restart(now, 0, Some(e));
                        return Outcome::Next;
                    }
                    return Outcome::Fail(e);
                }
                if v[0] != self.entry {
                    return Outcome::Retry(LoadError::BootAddress { read: v[0] });
                }
                if v[3] & CTRL_RESET == 0 {
                    // someone released the CPU meanwhile: the RAM is no longer ours to trust
                    return Outcome::Fail(LoadError::NotHeld { ctrl: v[3] });
                }
                self.go(now, Step::PrepareRelease);
            }
            Step::PrepareRelease => {
                if v[0] != self.release_ctrl | CTRL_RESET {
                    return Outcome::Retry(LoadError::NotHeld { ctrl: v[0] });
                }
                self.go(now, Step::ClearState);
            }
            Step::ClearState => {
                if v[0] >> 24 != 0 {
                    return Outcome::Retry(LoadError::NoReply(Step::ClearState));
                }
                self.go(now, Step::Release);
            }
            Step::Release => {
                if v[0] & CTRL_RESET != 0 {
                    return Outcome::Retry(LoadError::NoReply(Step::Release));
                }
                self.go(now, Step::WaitStart);
                let timeout = if self.release_ctrl == 0 { FLASH_BOOT_TIMEOUT_MS } else { START_TIMEOUT_MS };
                self.start_deadline = now.wrapping_add(timeout);
                self.due = now.wrapping_add(START_POLL_MS);
            }
            Step::WaitStart => {
                let state = v[0] >> 24;
                let late = crate::msg::time_reached(now, self.start_deadline);
                return match self.release_ctrl {
                    CTRL_STAY_ROM => match state {
                        FWS_ROM_IDLE => self.restarted(now, Ok(())),
                        _ if late => self.restarted(now, Err(LoadError::NoRom { fw_status: v[0] })),
                        _ => Outcome::Wait(START_POLL_MS),
                    },
                    ctrl => match state {
                        FWS_APP => self.restarted(now, Ok(())),
                        FWS_STOPPED => self.restarted(now, Err(LoadError::Stopped { fw_status: v[0] })),
                        // a normal start that ends in the idle ROM: the saved program did not start
                        FWS_ROM_IDLE if ctrl == 0 => self.restarted(now, Err(LoadError::BootFailed { fw_status: v[0] })),
                        _ if late => self.restarted(now, Err(LoadError::NotStarted { fw_status: v[0] })),
                        _ => Outcome::Wait(START_POLL_MS),
                    },
                };
            }
            Step::ClearResult => {
                if v[0] != 0 {
                    return Outcome::Retry(LoadError::NoReply(Step::ClearResult));
                }
                if let Some(e) = Self::transmit_on(v[2], v[3]) {
                    self.restart(now, 0, Some(e));
                } else if v[1] >> 24 != FWS_ROM_IDLE {
                    self.restart(now, 0, Some(LoadError::NoRom { fw_status: v[1] }));
                } else if !self.quiet {
                    self.restart(now, 0, Some(LoadError::NotQuiet));
                } else {
                    self.save_sends = 0;
                    self.go(now, Step::Save);
                }
            }
            // sent in poll_transmit; no reply
            Step::Save => {}
            Step::WaitSave => {
                if v[0] >> 24 == b'S' as u32 {
                    let code = v[0] as u8;
                    if code == FWR_OK {
                        self.saved = true;
                        self.restart(now, 0, None);
                    } else {
                        // nothing was written for bad arguments, CRC mismatch or locked: the old
                        // saved program starts again; after a flash or verify error it is gone,
                        // and the image verified in RAM runs instead
                        let ctrl = if matches!(code, FWR_FLASH_ERR | FWR_VERIFY_ERR) { CTRL_BOOT_RAM } else { 0 };
                        self.restart(now, ctrl, Some(LoadError::Save { code }));
                    }
                    return Outcome::Next;
                }
                if now.wrapping_sub(self.save_started_ms) >= SAVE_TIMEOUT_MS {
                    // the ROM may still be writing: leave the CPU alone
                    return Outcome::Fail(LoadError::SaveTimeout);
                }
                if v[1] >> 24 == FWS_ROM_IDLE && now.wrapping_sub(self.save_sent_ms) >= SAVE_RESEND_MS {
                    // idle with no result: the datagram was lost
                    if self.save_sends >= SAVE_SENDS {
                        self.restart(now, 0, Some(LoadError::NoReply(Step::Save)));
                        return Outcome::Next;
                    }
                    self.go(now, Step::Save);
                    return Outcome::Next;
                }
                return Outcome::Wait(SAVE_POLL_MS);
            }
        }
        Outcome::Next
    }
}

#[cfg(test)]
mod tests;
#[cfg(test)]
mod update_tests;
