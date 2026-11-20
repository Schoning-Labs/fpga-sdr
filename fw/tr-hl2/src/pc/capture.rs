// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Receives the raw ADC stream for a fixed duration, counts gaps (`PROTOCOL.md` section 5), and
//! optionally keeps the unpacked samples for offline analysis (the AM band high-pass polarity
//! check, see `goertzel`).
//!
//! It runs two threads, the way the client of `docs/rawfront/TOOLCHAIN.md` (`rawcap`) does: one
//! does nothing but `recv_from`, so it never falls behind the roughly 12,900 datagrams per second
//! of the stream, and hands each datagram to a bounded channel, while the other parses the headers
//! and updates the running statistics. `sample_cap` bounds the memory when the caller wants the
//! raw samples back.

use crate::protocol;
use std::io;
use std::net::UdpSocket;
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

/// What to capture.
pub struct CaptureOptions {
    pub seconds: f64,
    /// If `Some(n)`, keep up to `n` unpacked samples (first-arrived), for offline analysis.
    pub sample_cap: Option<usize>,
}

/// What a capture saw, counted from the frame headers.
#[derive(Debug, Default, Clone)]
pub struct CaptureStats {
    pub frames: u64,
    pub bytes: u64,
    pub samples: u64,
    /// Frame sequence-number gaps (PROTOCOL.md 5.2: "lost samples can be counted exactly").
    pub lost_frames: u64,
    /// Sample-index gaps, the number of samples the HL2 reports as missing (dropped by an
    /// overflow, or a frame lost/corrupted in transit and dropped by our own CRC-less-UDP
    /// receive: PROTOCOL.md section 1 notes the radio checks no Ethernet/IP/UDP checksum, and we
    /// don't add one on receive either here, so a corrupted-but-still-parseable frame would only
    /// be caught by its index/sequence continuity, same as `rawcap`).
    pub lost_samples: u64,
    pub reordered_or_dup: u64,
    pub hl2_overflow_frames: u64,
    pub hl2_gap_frames: u64,
    pub fifo_high_water: u16,
    pub safety_last: u8,
    /// Bitwise OR of every safety byte seen (quick way to notice any bit that ever went high).
    pub safety_any: u8,
    pub safety_changes: u64,
    pub recv_errors: u64,
    /// Datagrams the channel dropped because the checker thread fell behind.
    pub channel_drops: u64,
}

impl CaptureStats {
    /// The done-test's "0 gaps" bar: no lost frames, no lost samples, no reordering, and at
    /// least one frame actually arrived.
    pub fn zero_gaps(&self) -> bool {
        self.frames > 0 && self.lost_frames == 0 && self.lost_samples == 0 && self.reordered_or_dup == 0
    }
}

const MAX_FRAME: usize = 9200;
/// Channel depth: comfortably more than one jumbo frame's worth of queued datagrams, so a short
/// GC-style stall in the checker thread doesn't force the recv thread to drop.
const CHANNEL_DEPTH: usize = 4096;

/// Run the receive+check loop for `opts.seconds`. `sock` must already be open (and, for a real
/// HL2 run, `client::send_start` already sent on it).
pub fn run(sock: UdpSocket, opts: CaptureOptions) -> io::Result<(CaptureStats, Vec<i16>)> {
    let (tx, rx) = mpsc::sync_channel::<Vec<u8>>(CHANNEL_DEPTH);
    let recv_sock = sock.try_clone()?;
    let stop_recv = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let stop_recv_thread = stop_recv.clone();

    let recv_thread = thread::Builder::new().name("tr-hl2-recv".into()).spawn(move || {
        let mut scratch = [0u8; MAX_FRAME];
        let mut drops = 0u64;
        while !stop_recv_thread.load(std::sync::atomic::Ordering::Relaxed) {
            match recv_sock.recv_from(&mut scratch) {
                Ok((n, _from)) => {
                    if tx.try_send(scratch[..n].to_vec()).is_err() {
                        drops += 1;
                    }
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock || e.kind() == io::ErrorKind::TimedOut => continue,
                Err(_) => break,
            }
        }
        drops
    })?;

    let sample_cap = opts.sample_cap.unwrap_or(0);
    let mut samples: Vec<i16> = Vec::with_capacity(sample_cap.min(64 * 1024 * 1024));
    let mut stats = CaptureStats::default();
    let mut last_seq: Option<u32> = None;
    let mut last_index_end: Option<u64> = None;
    let mut sample_scratch = [0i16; 6000];

    let deadline = Instant::now() + Duration::from_secs_f64(opts.seconds);
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break;
        }
        match rx.recv_timeout(remaining.min(Duration::from_millis(200))) {
            Ok(data) => process_one(&data, &mut last_seq, &mut last_index_end, &mut stats, &mut samples, sample_cap, &mut sample_scratch),
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }

    stop_recv.store(true, std::sync::atomic::Ordering::Relaxed);
    let recv_drops = recv_thread.join().unwrap_or(0);
    stats.channel_drops += recv_drops;
    // Drain anything still queued so the drop count reflects reality, not an artifact of
    // stopping mid-queue.
    while let Ok(data) = rx.try_recv() {
        process_one(&data, &mut last_seq, &mut last_index_end, &mut stats, &mut samples, sample_cap, &mut sample_scratch);
    }

    Ok((stats, samples))
}

fn process_one(
    data: &[u8],
    last_seq: &mut Option<u32>,
    last_index_end: &mut Option<u64>,
    stats: &mut CaptureStats,
    samples: &mut Vec<i16>,
    sample_cap: usize,
    scratch: &mut [i16],
) {
    let header = match protocol::FrameHeader::parse(data) {
        Some(h) => h,
        None => {
            stats.recv_errors += 1;
            return;
        }
    };

    let safety = header.safety;
    if stats.frames > 0 && stats.safety_last != safety {
        stats.safety_changes += 1;
    }
    stats.safety_last = safety;
    stats.safety_any |= safety;

    stats.frames += 1;
    stats.bytes += data.len() as u64;
    stats.samples += header.samples_in_frame as u64;

    if let Some(prev) = *last_seq {
        let expected = prev.wrapping_add(1);
        if header.seq != expected {
            if header.seq > expected {
                stats.lost_frames += (header.seq - expected) as u64;
            } else {
                stats.reordered_or_dup += 1;
            }
        }
    }
    *last_seq = Some(header.seq);

    let this_end = header.first_sample_index + header.samples_in_frame as u64;
    if let Some(expected_start) = *last_index_end {
        if header.first_sample_index > expected_start {
            stats.lost_samples += header.first_sample_index - expected_start;
        } else if header.first_sample_index < expected_start {
            stats.reordered_or_dup += 1;
        }
    }
    *last_index_end = Some(this_end);

    if header.is_overflow() {
        stats.hl2_overflow_frames += 1;
    }
    if header.is_gap() {
        stats.hl2_gap_frames += 1;
    }
    stats.fifo_high_water = stats.fifo_high_water.max(header.fifo_high_water);

    if sample_cap > 0 && samples.len() < sample_cap {
        let payload = &data[header.header_len..];
        let want = scratch.len().min(sample_cap - samples.len());
        let n = protocol::unpack_samples_into(payload, &mut scratch[..want]);
        samples.extend_from_slice(&scratch[..n]);
    }
}
