// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The FT8 decode benchmark (feature `bench-ft8`): it decodes the two WSJT-X sample recordings
//! (`captures/ft8/qso1.wav` and `captures/ft8/qso3_busy.wav`, fetched by `tools/fetch_test_audio.sh` into the
//! `captures/` folder that git ignores) with `tr_modes::decode::ft8::decode_slot` (the default setting, with
//! OSD and the WSJT-X depth 3 ladder) and with `decode_slot_light` (a single pass, no OSD and no signal
//! subtraction), under QEMU, and counts instructions with `minstret` in the same way as every other kernel in
//! this crate (docs/S2_BENCH.md).
//!
//! ## Why this module has its own allocator
//!
//! Every other kernel in this crate (`tr-dsp`) is deliberately free of allocation, with fixed-size arrays
//! throughout and no `#[global_allocator]`. `tr-modes` and `mfsk-core` are not, because they are `#![no_std]`
//! plus `alloc` (docs/S5_MODES.md), and an FT8 decode allocates real memory for its candidate lists,
//! downsample buffers and per-candidate results. Linking them into this binary needs a `GlobalAlloc`
//! implementation, and `linked_list_allocator` (pure Rust, `no_std`, MIT OR Apache-2.0, no C code, so it
//! fits the license checks of every other `tr-modes` dependency) is a small free-list allocator that does the
//! job. Because it gives memory back, the four decodes below can run one after the other in the same heap, which
//! a bump allocator that never frees could not do without running out partway through.
//!
//! ## Why the WAVs are embedded instead of read from a filesystem
//!
//! This binary runs bare-metal under QEMU (`-bios none -kernel`), where there is no filesystem and no host I/O
//! apart from the UART console that `tr-bench` writes its results to, so there is nothing to open a file from.
//! The two recordings are pulled in with `include_bytes!` when the binary is built on the host, which is why
//! `bench-ft8` needs `captures/` to exist already on the machine that runs `cargo build` (see the feature
//! comment in Cargo.toml and `tools/qemu_s2.sh`, which checks for the files before it turns the feature on).

extern crate alloc;
use alloc::vec::Vec;

/// A 28 MiB heap inside the 32 MiB RAM region of `tr-ae350/memory-qemu.x`, next to the roughly 700 KB of embedded
/// WAV data, this binary's code and data, and the 64 KB hart stack (`_hart_stack_size` in that linker script).
/// A 16 MiB heap was enough for the light setting on both files but ran out of memory in the default setting
/// (WSJT-X depth 3, several passes with signal subtraction), which keeps much more candidate and result data
/// alive at the same time (docs/CPU_BUDGET.md section 5); 28 MiB is about as much as fits next to everything else.
/// A decode that needs more still does not corrupt anything: the allocator returns null,
/// `alloc::alloc::handle_alloc_error` panics, and QEMU prints the message.
const HEAP_SIZE: usize = 28 * 1024 * 1024;

/// The heap's backing memory. It is a `static mut` array that is written exactly once, by `init_heap_once`
/// below and before the first allocation, and this binary is single-hart and single-threaded with no
/// interrupts enabled while `run_all` runs (see `dsp_bench.rs`), so nothing can reach it concurrently.
static mut HEAP: [u8; HEAP_SIZE] = [0; HEAP_SIZE];

#[global_allocator]
static ALLOCATOR: linked_list_allocator::LockedHeap = linked_list_allocator::LockedHeap::empty();

/// Gives the allocator its memory. `run_all` calls this before its first allocation, and the flag makes a
/// second call harmless, so the same backing array cannot be initialized twice.
fn init_heap_once() {
    use core::sync::atomic::{AtomicBool, Ordering};
    static INIT: AtomicBool = AtomicBool::new(false);
    if !INIT.swap(true, Ordering::SeqCst) {
        unsafe {
            #[allow(static_mut_refs)]
            ALLOCATOR.lock().init(HEAP.as_mut_ptr(), HEAP_SIZE);
        }
    }
}

/// FT8 slot length: 15 s at 12 ksps mono, the format of the WSJT-X sample recordings and of every real FT8
/// decode path in `tr-modes`.
const SLOT_LEN: usize = 180_000;

// Paths are relative to this file, so they point at captures/ft8/ in the root of the repository.
const QSO1_WAV: &[u8] = include_bytes!("../../../captures/ft8/qso1.wav");
const QSO3_BUSY_WAV: &[u8] = include_bytes!("../../../captures/ft8/qso3_busy.wav");

/// A minimal RIFF/WAVE reader that returns the samples of the `data` chunk, good for the two embedded files
/// and for nothing else. `tr-modes` has a fuller reader in its host tool `fw/tr-modes/src/bin/decode_wav.rs`,
/// but that one needs `std` and checks `fmt` fields that need no checking here, since both files are known to be
/// 12 kHz mono 16-bit PCM, fetched unchanged by `tools/fetch_test_audio.sh`. The function walks the chunks
/// looking for `data` and panics on a file that is not RIFF/WAVE or has no `data` chunk, which is the right
/// behavior for a fixed test file as opposed to arbitrary input.
fn parse_wav_i16(bytes: &[u8]) -> Vec<i16> {
    assert!(
        bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WAVE",
        "ft8_bench: embedded file is not a RIFF/WAVE"
    );
    let mut i = 12usize;
    let mut data_off = 0usize;
    let mut data_len = 0usize;
    // Each chunk is a four-byte id and a four-byte little-endian length, then the data, padded to an even length.
    while i + 8 <= bytes.len() {
        let id = &bytes[i..i + 4];
        let len = u32::from_le_bytes([bytes[i + 4], bytes[i + 5], bytes[i + 6], bytes[i + 7]]) as usize;
        i += 8;
        if id == b"data" {
            data_off = i;
            data_len = len.min(bytes.len().saturating_sub(i));
        }
        i += len;
        if len % 2 == 1 {
            i += 1;
        }
    }
    assert!(data_off != 0, "ft8_bench: no data chunk found in embedded WAV");
    bytes[data_off..data_off + data_len]
        .chunks_exact(2)
        .map(|b| i16::from_le_bytes([b[0], b[1]]))
        .collect()
}

/// Zero-pads or truncates to exactly one FT8 slot. Both embedded files are about one slot long already, but
/// `decode_slot`, like the host tool it mirrors, expects exactly `SLOT_LEN` samples.
fn pad_slot(mut v: Vec<i16>) -> Vec<i16> {
    v.resize(SLOT_LEN, 0);
    v
}

/// The 64-bit `minstret` read that every other kernel in this crate uses (`super::instret`), written out again
/// here so that this module does not depend on a function of `lib.rs` that is unused in a build without
/// `bench-ft8`.
#[inline]
fn instret() -> u64 {
    riscv::register::minstret::read64()
}

/// Frequency search band and candidate limit used for both settings, so that the only difference between the
/// "default" and the "light" measurement of a file is the decode ladder itself (OSD and WSJT-X depth 3 against
/// a plain single pass) and not the search window. The band of 100 to 3000 Hz is the default search band of the
/// host decoder tool, and 60 candidates is the "WSJT-X depth 1" convention of docs/CPU_BUDGET.md section 5.
const FREQ_MIN_HZ: f32 = 100.0;
const FREQ_MAX_HZ: f32 = 3000.0;
const SYNC_MIN: f32 = 1.0;
const MAX_CAND: usize = 60;

/// Runs the FT8 decode of both embedded slots at both settings and writes one `RESULT ft8_<file>_<setting> ...`
/// line per combination straight to `out`, four lines in all. They do not go through the fixed `KernelResult`
/// array of `super::run_all`, whose one line per kernel does not fit a measurement that comes out as two files
/// times two settings. Without the `bench-ft8` feature, `super::bench_ft8` prints a single stub line instead.
pub fn run_all<W: core::fmt::Write>(out: &mut W) {
    init_heap_once();

    let files: [(&str, &[u8]); 2] = [("qso1", QSO1_WAV), ("qso3_busy", QSO3_BUSY_WAV)];

    // The light setting runs first, on both files, and the much heavier default setting (several passes of
    // WSJT-X depth 3) afterwards. Under QEMU's strict `-icount shift=0` instruction accounting
    // (docs/S2_BENCH.md) the default setting can run for hours (docs/CPU_BUDGET.md reports this for depth 1),
    // and every `RESULT` line is printed right after its own decode, so a run that has to be cut off still
    // leaves the light numbers in the UART transcript.
    for (fname, wav) in files {
        let audio = pad_slot(parse_wav_i16(wav));
        let start = instret();
        let decoded = tr_modes::decode::ft8::decode_slot_light(&audio, FREQ_MIN_HZ, FREQ_MAX_HZ, SYNC_MIN, MAX_CAND);
        let instr_light = instret() - start;
        let n_light = decoded.len();
        let _ = writeln!(
            out,
            "RESULT ft8_{fname}_light measured=1 rate_hz=12000 unit=blocks divisor=1 \
             instr_total={instr_light} note=15s slot, {n_light} decode(s), single-pass (DecodeDepth::FULL, no SIC/D3 passes), max_cand={MAX_CAND}"
        );
    }

    for (fname, wav) in files {
        let audio = pad_slot(parse_wav_i16(wav));
        let start = instret();
        let decoded = tr_modes::decode::ft8::decode_slot(&audio, FREQ_MIN_HZ, FREQ_MAX_HZ, SYNC_MIN, MAX_CAND);
        let instr_default = instret() - start;
        let n_default = decoded.len();
        let _ = writeln!(
            out,
            "RESULT ft8_{fname}_default measured=1 rate_hz=12000 unit=blocks divisor=1 \
             instr_total={instr_default} note=15s slot, {n_default} decode(s), wsjtx_depth D3 (multi-pass SIC), max_cand={MAX_CAND}"
        );
    }
}
