// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The UART side of the stage-0 loader: the handshake that enters loader mode (a window of time in
//! which the host has to send four sync bytes), receiving the image header and payload straight into
//! RAM, checking both CRCs, and reading the final command byte that says whether to run the image or
//! write it to flash. docs/C2_LOADER.md "Protocol" is the wire-level specification this implements,
//! and this module is only the mechanics of it.
//!
//! The sequence on the wire is: the loader prints a prompt line that ends in [`PROMPT_MARKER`], the
//! host answers with [`SYNC`], the loader prints [`ACK_MARKER`], and the host then sends the image
//! (a `tr_image` header followed by the payload) and one command byte ([`CMD_RUN`] or [`CMD_FLASH`]).

use tr_ae350::timer;
use tr_ae350::uart::Uart;
use tr_image::{ImageError, ImageHeader, HEADER_LEN};

/// Sync bytes the host must send, in order, within the handshake window to enter loader mode
/// (docs/C2_LOADER.md "Why a UART timeout window, not a button/strap").
///
/// The word is deliberately not `"TRLD"` and shares no byte value with it. `"TRLD"` is
/// `tr_image::MAGIC`, so the packed image's own header starts with those same 4 bytes. If the sync
/// word were the same, a handshake attempt that was cut off after matching only some of the bytes
/// (the host being busy, scheduler jitter, a slow link, none of which is specific to QEMU) would
/// leave the unmatched rest of the sync bytes in front of the image header in the stream, and the
/// header's first 4 bytes would then complete a *false* sync match on a later attempt, which
/// shifts everything read after it by 4 bytes. With a sync word that has no byte in common with
/// `MAGIC` that cannot happen at all, because none of `MAGIC`'s bytes equal any of `SYNC`'s, so an
/// abandoned partial match can never be completed by them. An arbitrary payload could still contain
/// the four sync bytes by chance and cause a spurious re-sync somewhere else (1 in 2^32 per
/// possible offset, which is the residual risk of any framing marker), but the collision that
/// would have happened on every cut-off handshake is gone.
pub const SYNC: &[u8; 4] = &[0xA5, 0x5A, 0xC3, 0x3C];

/// Fixed token that `bin/stage0.rs` puts at the end of every handshake prompt line (the "send the
/// sync bytes within N ms" line, which is printed again every `HANDSHAKE_WINDOW_MS` while no
/// handshake has been seen). `fw/tr-loader-send` watches the stream for this token and not for the
/// sentence around it, to know that the loader is actually polling for `SYNC` at that moment. The
/// sender keeps its own copy of the constant, because `tr-loader` is `no_std` and board-only and
/// cannot be a dependency of a host binary (which is also why [`SYNC`] is duplicated there), so the
/// two copies have to be kept equal by hand. A token that does not depend on the wording of the
/// sentence or on the numeric value of `HANDSHAKE_WINDOW_MS` is a more robust thing to match than
/// the prose (docs/C2_LOADER.md "Protocol" explains the start-up race this exists for).
pub const PROMPT_MARKER: &str = "SYNC-PROMPT";

/// Fixed line that `bin/stage0.rs` prints immediately after [`wait_for_handshake`] returns `true`,
/// which is as soon as the loader has matched all 4 [`SYNC`] bytes and is about to poll for the
/// image header. `fw/tr-loader-send` waits for this line before it sends the image, and sends
/// [`SYNC`] again on the next [`PROMPT_MARKER`] if it never sees it (the sender has its own copy of
/// the constant). Without an acknowledgement the host would have no way to know that the loader had
/// really entered loader mode, and an image sent while the loader was still starting up would simply
/// be lost (see docs/C2_LOADER.md "Protocol").
pub const ACK_MARKER: &str = "READY";

/// Host to loader command byte, sent right after a header and payload have been accepted: run the
/// image immediately from RAM.
pub const CMD_RUN: u8 = b'R';
/// Host to loader command byte: program the image into flash (board-ae350 only, see
/// `fw/tr-loader/src/flash.rs`).
pub const CMD_FLASH: u8 = b'F';

/// Blocks, polling `try_read_byte`, until `SYNC` has been seen in order, or until `window_ticks`
/// (in `timer::now()` units) have passed with no progress. A byte that breaks a partial match is
/// itself checked as the possible start of a new match, so a stray byte in front of the sync bytes
/// does not stop them being found.
///
/// The deadline is an idle timeout and not a fixed total budget: it is pushed out by a full
/// `window_ticks` every time a byte extends (or restarts) a partial match. This matters under host
/// load, where this loop can go unpolled for a while and a handshake that is already under way
/// could otherwise be cut off by an absolute deadline after only 1 to 3 of the 4 sync bytes, leaving
/// the rest of them in the input for the next call to misread. The main protection against that is
/// that [`SYNC`] shares no byte with `tr_image::MAGIC` (see the comment there), and the idle timeout
/// is kept on top of it because it is more correct and costs nothing. With no host attached
/// `matched` never leaves 0, so the deadline is never pushed out and the window ends after exactly
/// one `window_ticks`, which means the idle timeout can only lengthen the window and the time the
/// real board waits with nothing connected is unchanged.
pub fn wait_for_handshake(uart: &Uart, window_ticks: u64) -> bool {
    let mut deadline = timer::now().wrapping_add(window_ticks);
    // How many of the sync bytes have been matched in a row so far.
    let mut matched = 0usize;
    while timer::now() < deadline {
        if let Some(b) = uart.try_read_byte() {
            // The next expected byte extends the match; anything else starts over, but a byte
            // that equals the first sync byte counts as the first byte of a new match.
            matched = if b == SYNC[matched] {
                matched + 1
            } else {
                usize::from(b == SYNC[0])
            };
            if matched == SYNC.len() {
                return true;
            }
            // Progress in a handshake pushes the deadline out (the idle timeout described above).
            if matched > 0 {
                deadline = timer::now().wrapping_add(window_ticks);
            }
        }
    }
    false
}

/// What the caller should do after [`receive_image`] returns successfully.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    /// Start the image from RAM now ([`CMD_RUN`]).
    Run,
    /// Write the image to the inactive flash slot ([`CMD_FLASH`]).
    Flash,
}

/// Why one receive attempt was refused. `Display` (below) is the exact text that
/// `fw/tr-loader/src/bin/stage0.rs` prints, so a corrupt image is refused with a clear message on
/// the console.
#[derive(Debug, Clone, Copy)]
pub enum ReceiveError {
    /// The header is not valid (wrong magic, version or header CRC).
    Header(ImageError),
    /// The header is valid but the payload would not lie inside the destination window.
    Bounds { load_addr: u32, length: u32 },
    /// The payload arrived but does not match the CRC in the header.
    Payload(ImageError),
    /// The byte after the payload was neither [`CMD_RUN`] nor [`CMD_FLASH`].
    BadCommand(u8),
}

impl core::fmt::Display for ReceiveError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            ReceiveError::Header(e) => write!(f, "image rejected: {e}"),
            ReceiveError::Bounds { load_addr, length } => write!(
                f,
                "image rejected: load address {load_addr:#010x} length {length} bytes falls outside the destination window"
            ),
            ReceiveError::Payload(e) => write!(f, "image rejected: {e}"),
            ReceiveError::BadCommand(b) => {
                write!(f, "image rejected: bad command byte {b:#04x} (expected 'R' or 'F')")
            }
        }
    }
}

/// Reads exactly `buf.len()` bytes, polling. There is no timeout: once the handshake has succeeded
/// the host is assumed to keep sending, so a host that stalls leaves the loader waiting, which is
/// preferred over the loader guessing at a timeout that could be too short for a slow link
/// (docs/C2_LOADER.md "Protocol").
fn read_exact(uart: &Uart, buf: &mut [u8]) {
    for slot in buf.iter_mut() {
        loop {
            if let Some(b) = uart.try_read_byte() {
                *slot = b;
                break;
            }
        }
    }
}

/// Receives one header, its payload and the command byte over `uart`. The payload is written
/// directly into `[dest_base, dest_base + dest_len)` with no buffer in between (the destination
/// on both boards is ordinary addressable RAM, see `layout::DEST_BASE` and `DEST_LEN`), so this
/// never allocates and never needs a buffer as large as the biggest possible image. The header's
/// `load_addr` and `length` are checked against that window *before* a single payload byte is
/// written, and the payload CRC is checked before the command byte is read.
///
/// # Safety
/// `dest_base..dest_base+dest_len` must be valid to read and write as plain bytes for the whole
/// call, and must not overlap memory that the caller (or its own code and stack) needs unmodified
/// while this function runs. See the notes for each board in `layout.rs`.
pub unsafe fn receive_image(
    uart: &Uart,
    dest_base: u32,
    dest_len: u32,
) -> Result<(ImageHeader, Action), ReceiveError> {
    let mut header_buf = [0u8; HEADER_LEN];
    read_exact(uart, &mut header_buf);
    let header = ImageHeader::from_bytes(&header_buf).map_err(ReceiveError::Header)?;

    // Overflow-safe bounds check (see docs/C2_LOADER.md "Protocol"). It is the same test as
    // `load_addr + length > dest_base + dest_len` (the image has to end inside the window), written
    // so that no two u32 values that could overflow are ever added.
    let out_of_range = header.load_addr < dest_base
        || header.length > dest_len
        || header.load_addr - dest_base > dest_len - header.length;
    if out_of_range {
        return Err(ReceiveError::Bounds {
            load_addr: header.load_addr,
            length: header.length,
        });
    }

    // SAFETY: bounds just checked against the caller's contract for dest_base/dest_len.
    let dest = unsafe {
        core::slice::from_raw_parts_mut(header.load_addr as *mut u8, header.length as usize)
    };
    read_exact(uart, dest);

    header
        .validate_payload(dest, header.length)
        .map_err(ReceiveError::Payload)?;

    let mut cmd = [0u8; 1];
    read_exact(uart, &mut cmd);
    let action = match cmd[0] {
        CMD_RUN => Action::Run,
        CMD_FLASH => Action::Flash,
        other => return Err(ReceiveError::BadCommand(other)),
    };
    Ok((header, action))
}
