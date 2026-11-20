// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! PC-side sender for the stage-0 UART loader (docs/C2_LOADER.md "Protocol"). Usage:
//!
//! ```text
//! tr-loader-send --tcp 127.0.0.1:7000 --image target/.../payload.img [--cmd run|flash]
//! tr-loader-send --serial COM5 --baud 115200 --image target/.../payload.img [--cmd run|flash]
//! ```
//!
//! `--tcp` is for the QEMU test (a raw socket that stands in for the emulated UART, see
//! `tools/qemu_c2.sh`) and `--serial` is for the real board's UART, where `COM5` is only an example of
//! a port name on a Windows PC. The image is a file made by `cargo run -p xtask -- image`, and `--cmd`
//! chooses between running it from RAM (the default) and writing it to flash. Two more options are
//! `--relay-secs` (how long to keep printing what the loader says after the image is sent, default 3)
//! and `--handshake-timeout-secs` (how long to wait for the loader's acknowledgement, default 30).
//!
//! The tool waits for the loader's handshake prompt marker (`PROMPT_MARKER`, below) before it sends
//! the sync bytes, and then waits for the loader's own acknowledgement (`ACK_MARKER`) before it sends
//! the raw contents of the image file (already in the header-and-payload format of `tr-image`) and the
//! one-byte run or flash command. If the loader goes back to a fresh prompt without ever acknowledging
//! (it prompts again every `HANDSHAKE_WINDOW_MS`, see `stage0.rs`), the sync bytes are sent again on
//! that prompt, so one lost attempt does not use up the whole `--handshake-timeout-secs` budget.
//!
//! The wait for the prompt and for the acknowledgement exists because of a start-up race
//! (docs/C2_LOADER.md "Protocol"). Sending the sync bytes and the whole image the moment the
//! connection opens races the loader's own start-up (initializing the UART and reaching its receive
//! loop), on QEMU, where the TCP connection is accepted as soon as the emulator's socket is listening
//! and long before the emulated processor has booted far enough to read anything, and equally on the
//! real board, where nothing stops a person from starting this tool before resetting the board. Bytes
//! sent into that window are lost, and the loader would never see the sync bytes.
//!
//! Every byte read back from the loader (and, once it jumps, from the payload) is copied to this
//! process's stdout as it arrives, during the handshake wait and then for the rest of `--relay-secs`
//! after the image is sent. A person running the tool by hand and the test script `tools/qemu_c2.sh`
//! (which searches this program's stdout) therefore see what the loader's own console shows.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// Handshake sync bytes the loader waits for. They must equal `tr_loader::protocol::SYNC`, and they
/// are copied here and not shared as a dependency because `tr-loader` is `no_std` and only built for
/// the AE350 while this tool is an ordinary host binary (docs/C2_LOADER.md "Protocol" is the one place
/// where the value is specified in prose). The word is deliberately not `tr_image::MAGIC` ("TRLD"):
/// the doc comment of `tr_loader::protocol::SYNC` explains why sharing bytes with the image's own
/// header magic would break the handshake.
const SYNC: &[u8; 4] = &[0xA5, 0x5A, 0xC3, 0x3C];

/// Fixed token that the loader (`fw/tr-loader/src/bin/stage0.rs`) puts at the end of every handshake
/// prompt line, which it prints again every `HANDSHAKE_WINDOW_MS` while no handshake has been seen.
/// It must equal `tr_loader::protocol::PROMPT_MARKER` (and is a copy for the same reason [`SYNC`]
/// above is). The tool matches this token and not the readable sentence around it, because that
/// sentence contains the numeric value of `HANDSHAKE_WINDOW_MS` and the sync bytes themselves.
const PROMPT_MARKER: &str = "SYNC-PROMPT";

/// Fixed line that the loader prints right after it has matched all 4 [`SYNC`] bytes and is about to
/// poll for the image header. It must equal `tr_loader::protocol::ACK_MARKER`. The image is sent only
/// after this line has been seen, because without it the tool cannot tell a loader that has entered
/// loader mode from one that is still booting, with the sync bytes sitting unread (or lost) in a
/// socket or FIFO buffer, which is the start-up race described at the top of this file.
const ACK_MARKER: &str = "READY";

/// The command line, after parsing.
struct Args {
    /// `host:port` of a raw TCP socket standing in for the UART (QEMU).
    tcp: Option<String>,
    /// Name of a serial port (the real board).
    serial: Option<String>,
    /// Baud rate for `serial`.
    baud: u32,
    /// The image file to send.
    image: PathBuf,
    /// The command byte sent after the image, `b'R'` (run) or `b'F'` (flash); these are
    /// `CMD_RUN` and `CMD_FLASH` of `tr_loader::protocol`.
    cmd: u8,
    /// How long to keep relaying the loader's output after the image has been sent.
    relay_secs: u64,
    /// Total time allowed for the handshake, over all connection attempts.
    handshake_timeout_secs: u64,
}

/// Reads the command line. Exactly one of `--tcp` and `--serial` is required, and so is `--image`.
/// The default baud rate is 115,200, which is the rate the loader requests when it sets up its UART.
/// The rate the real UART runs at depends on the UART clock that `tr_ae350::board` assumes, so
/// `--baud` has to be set to what the console really uses if that differs.
fn parse_args() -> Result<Args, String> {
    let mut tcp = None;
    let mut serial = None;
    let mut baud = 115_200u32;
    let mut image = None;
    let mut cmd = b'R';
    let mut relay_secs = 3u64;
    let mut handshake_timeout_secs = 30u64;

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let mut next = || args.next().ok_or_else(|| format!("{arg}: needs a value"));
        match arg.as_str() {
            "--tcp" => tcp = Some(next()?),
            "--serial" => serial = Some(next()?),
            "--baud" => baud = next()?.parse().map_err(|e| format!("--baud: {e}"))?,
            "--image" => image = Some(PathBuf::from(next()?)),
            "--relay-secs" => relay_secs = next()?.parse().map_err(|e| format!("--relay-secs: {e}"))?,
            "--handshake-timeout-secs" => {
                handshake_timeout_secs = next()?.parse().map_err(|e| format!("--handshake-timeout-secs: {e}"))?
            }
            "--cmd" => {
                cmd = match next()?.as_str() {
                    "run" => b'R',
                    "flash" => b'F',
                    other => return Err(format!("--cmd: expected \"run\" or \"flash\", got {other:?}")),
                }
            }
            other => return Err(format!("unknown flag {other:?}")),
        }
    }

    if tcp.is_some() == serial.is_some() {
        return Err("exactly one of --tcp <host:port> or --serial <device> is required".to_string());
    }
    Ok(Args {
        tcp,
        serial,
        baud,
        image: image.ok_or("--image <path> is required")?,
        cmd,
        relay_secs,
        handshake_timeout_secs,
    })
}

/// Puts a TCP socket (QEMU's `-chardev socket`, `tools/qemu_c2.sh`) and a real serial port (the
/// board) behind one `Read + Write` type, so the handshake, send and relay code below does not
/// care which of them it was given.
enum Conn {
    Tcp(TcpStream),
    Serial(Box<dyn serialport::SerialPort>),
}

impl Conn {
    /// Sets a short read timeout, so the handshake and relay loops below can check their own
    /// deadlines now and then instead of blocking for good on a peer that has nothing to say.
    fn set_poll_timeout(&mut self, timeout: Duration) -> Result<(), String> {
        match self {
            Conn::Tcp(s) => s.set_read_timeout(Some(timeout)).map_err(|e| format!("setting TCP read timeout: {e}")),
            Conn::Serial(s) => s.set_timeout(timeout).map_err(|e| format!("setting serial read timeout: {e}")),
        }
    }
}

impl Read for Conn {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        match self {
            Conn::Tcp(s) => s.read(buf),
            Conn::Serial(s) => s.read(buf),
        }
    }
}

impl Write for Conn {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        match self {
            Conn::Tcp(s) => s.write(buf),
            Conn::Serial(s) => s.write(buf),
        }
    }
    fn flush(&mut self) -> std::io::Result<()> {
        match self {
            Conn::Tcp(s) => s.flush(),
            Conn::Serial(s) => s.flush(),
        }
    }
}

/// Opens the transport named on the command line: a TCP connection (retried for up to about five
/// seconds) or a serial port.
fn connect(args: &Args) -> Result<Conn, String> {
    if let Some(addr) = &args.tcp {
        // A few retries: tools/qemu_c2.sh starts this right after launching QEMU, and QEMU's
        // `-chardev socket,server=on,wait=off` listener may take a moment to come up.
        let mut last_err = None;
        for _ in 0..50 {
            match TcpStream::connect(addr) {
                Ok(s) => return Ok(Conn::Tcp(s)),
                Err(e) => {
                    last_err = Some(e);
                    std::thread::sleep(Duration::from_millis(100));
                }
            }
        }
        return Err(format!(
            "connecting to {addr}: {}",
            last_err.map(|e| e.to_string()).unwrap_or_default()
        ));
    }
    if let Some(device) = &args.serial {
        let port = serialport::new(device, args.baud)
            .timeout(Duration::from_millis(200))
            .open()
            .map_err(|e| format!("opening serial port {device}: {e}"))?;
        return Ok(Conn::Serial(port));
    }
    unreachable!("parse_args guarantees exactly one of --tcp/--serial");
}

/// One read attempt (bounded by the transport's poll timeout, `Conn::set_poll_timeout`). Whatever
/// came back is written to stdout at once, byte for byte, so a person or a script watching stdout
/// sees exactly what the transport produced. If `seen` is given the same bytes are also appended to
/// it (decoded leniently, since this is the channel for markers and diagnostics and not the path of
/// the image data) for the marker search in [`consume_marker`]. `seen` is only needed during the
/// handshake; the relay after it passes `None`, so a long session does not grow a string that nobody
/// will search again.
fn pump(conn: &mut Conn, stdout: &mut std::io::Stdout, seen: Option<&mut String>) -> Result<(), String> {
    let mut buf = [0u8; 256];
    match conn.read(&mut buf) {
        Ok(0) => Err("connection closed by the loader".to_string()),
        Ok(n) => {
            let _ = stdout.write_all(&buf[..n]);
            let _ = stdout.flush();
            if let Some(seen) = seen {
                seen.push_str(&String::from_utf8_lossy(&buf[..n]));
            }
            Ok(())
        }
        Err(e) if e.kind() == std::io::ErrorKind::TimedOut || e.kind() == std::io::ErrorKind::WouldBlock => Ok(()),
        Err(e) => Err(format!("reading from the loader: {e}")),
    }
}

/// Looks for `marker` in `seen[*cursor..]`. If it is found, `*cursor` is moved past it, so the same
/// occurrence is never matched twice, and the function returns `true`.
fn consume_marker(seen: &str, cursor: &mut usize, marker: &str) -> bool {
    match seen[*cursor..].find(marker) {
        Some(pos) => {
            *cursor += pos + marker.len();
            true
        }
        None => false,
    }
}

/// One connection attempt's worth of handshake: connect, wait for [`PROMPT_MARKER`], send [`SYNC`],
/// and wait for [`ACK_MARKER`], sending `SYNC` again on every fresh `PROMPT_MARKER` that arrives
/// before the acknowledgement (the loader prompts again every `HANDSHAKE_WINDOW_MS` for as long as
/// no handshake completes). Returns the connected transport once the loader has acknowledged, or an
/// `Err` that describes the connection problem or timeout that stopped it. The caller
/// ([`handshake`]) decides whether reconnecting is worth trying.
fn try_handshake(
    args: &Args,
    image_len: usize,
    stdout: &mut std::io::Stdout,
    deadline: Instant,
    sync_sends: &mut u32,
) -> Result<Conn, String> {
    let mut conn = connect(args)?;
    conn.set_poll_timeout(Duration::from_millis(200))?;
    println!(
        "tr-loader-send: connected, waiting for the loader's handshake prompt ({} bytes + command {:?} ready to send once it acknowledges)",
        image_len,
        args.cmd as char
    );

    // Everything the loader has printed so far, and how far into it each marker search has got
    // (a marker that was matched once must not be matched again).
    let mut seen = String::new();
    let mut prompt_cursor = 0usize;
    let mut ack_cursor = 0usize;
    // False until the sync bytes have been sent for the first time.
    let mut awaiting_ack = false;

    while Instant::now() < deadline {
        pump(&mut conn, stdout, Some(&mut seen))?;

        if !awaiting_ack {
            if consume_marker(&seen, &mut prompt_cursor, PROMPT_MARKER) {
                conn.write_all(SYNC).map_err(|e| format!("sending handshake sync bytes: {e}"))?;
                conn.flush().ok();
                *sync_sends += 1;
                awaiting_ack = true;
            }
        } else {
            if consume_marker(&seen, &mut ack_cursor, ACK_MARKER) {
                return Ok(conn);
            }
            // The loader looped back to a fresh prompt without ever acknowledging our last sync
            // attempt -- it did not see (all of) SYNC in time. Re-send now, on this fresh prompt,
            // rather than waiting out the whole handshake-timeout budget on one lost attempt.
            if consume_marker(&seen, &mut prompt_cursor, PROMPT_MARKER) {
                conn.write_all(SYNC).map_err(|e| format!("re-sending handshake sync bytes: {e}"))?;
                conn.flush().ok();
                *sync_sends += 1;
            }
        }
    }
    Err("handshake-timeout-secs elapsed while connected".to_string())
}

/// Runs [`try_handshake`], reconnecting (a new TCP connection or a reopened serial port) whenever it
/// fails with a connection-level error before reaching [`ACK_MARKER`]. Such failures do happen
/// transiently on a heavily loaded host: the TCP connection is accepted and then reset before a
/// single byte comes back, and neither side's protocol code can do anything about that.
/// Reconnecting is always safe here, because nothing the loader could be part-way through parsing
/// has been written yet (the image itself is sent only once, by the caller, after this function has
/// returned `Ok`). The whole thing is bounded by `deadline`, which is shared by all attempts.
fn handshake(args: &Args, image_len: usize, stdout: &mut std::io::Stdout, deadline: Instant) -> Result<Conn, String> {
    let mut sync_sends = 0u32;
    let mut last_err: Option<String> = None;
    loop {
        if Instant::now() >= deadline {
            return Err(format!(
                "no {ACK_MARKER:?} acknowledgement from the loader within {}s (sent the sync bytes {} time{}){}; \
                 is the loader running and connected to this transport?",
                args.handshake_timeout_secs,
                sync_sends,
                if sync_sends == 1 { "" } else { "s" },
                last_err.map(|e| format!(" (last connection error: {e})")).unwrap_or_default(),
            ));
        }
        match try_handshake(args, image_len, stdout, deadline, &mut sync_sends) {
            Ok(conn) => {
                println!(
                    "tr-loader-send: handshake acknowledged after {sync_sends} sync attempt{}",
                    if sync_sends == 1 { "" } else { "s" }
                );
                return Ok(conn);
            }
            Err(e) => {
                if Instant::now() < deadline {
                    println!("tr-loader-send: {e}; reconnecting");
                }
                last_err = Some(e);
            }
        }
    }
}

/// The whole run: reads the image and checks that its header is valid before any connection is made
/// (a bad file is reported at once instead of after the handshake), performs the handshake, sends
/// the image and the command byte, and then relays the loader's output for `--relay-secs`.
fn run() -> Result<(), String> {
    let args = parse_args()?;
    let image = std::fs::read(&args.image).map_err(|e| format!("reading {}: {e}", args.image.display()))?;
    tr_image::ImageHeader::from_bytes(&image)
        .map_err(|e| format!("{}: not a valid fpga-sdr image: {e}", args.image.display()))?;

    let mut stdout = std::io::stdout();
    let handshake_deadline = Instant::now() + Duration::from_secs(args.handshake_timeout_secs);
    let mut conn = handshake(&args, image.len(), &mut stdout, handshake_deadline)?;

    conn.write_all(&image).map_err(|e| format!("sending image: {e}"))?;
    conn.write_all(&[args.cmd]).map_err(|e| format!("sending command byte: {e}"))?;
    conn.flush().ok();
    println!("tr-loader-send: sent {} bytes + command {:?}", image.len(), args.cmd as char);

    // Keep relaying whatever the loader (and, once it jumps, the payload) sends back for the rest
    // of --relay-secs, because both a person running this by hand and the QEMU test script (which
    // searches this program's stdout) want to see it. A connection failure here ends the loop and
    // is not retried, unlike in `handshake` above: the image has already been sent once, and the
    // loader has no way to tell a resumed connection from a second, overlapping transfer.
    let relay_deadline = Instant::now() + Duration::from_secs(args.relay_secs);
    while Instant::now() < relay_deadline {
        if pump(&mut conn, &mut stdout, None).is_err() {
            break; // connection closed (e.g. QEMU exited after the payload ran) -- done.
        }
    }
    Ok(())
}

/// Runs the sender and turns an error into a message on stderr and exit status 1, which is what the
/// test script looks at.
fn main() {
    if let Err(e) = run() {
        eprintln!("tr-loader-send: {e}");
        std::process::exit(1);
    }
}
