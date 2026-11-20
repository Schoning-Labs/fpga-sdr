// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! `trmodes-decode`, a PC command line tool that decodes a 12 kHz mono WAV file (the format of the WSJT-X
//! sample recordings) with FT8, FT4 or WSPR and prints what it found, together with the decode time.
//!
//! ```text
//! trmodes-decode <ft8|ft4|wspr> <path.wav> [freq_min_hz] [freq_max_hz] [sync_min] [max_cand] [--light]
//! ```
//!
//! `--light` (FT8 and FT4 only) selects the plain single pass decoder (`decode_slot_light`, no OSD and no
//! successive interference cancellation) instead of the default (`decode_slot`, which has OSD on for FT8 and
//! three cancellation rounds for FT4). Comparing the two timings gives the cost of the extra decoding effort,
//! which is what docs/S5_MODES.md uses to estimate the load on the AE350 CPU.
//!
//! A file longer than one slot is cut into consecutive slots (FT8 15 s, 180 000 samples, FT4 7.5 s, 90 000
//! samples) and each one is decoded on its own, with a short last slot padded with zeros. WSPR is different,
//! because the whole file is decoded as one slot of about 120 s, which is how the WSJT-X WSPR recordings are
//! cut already.

use std::env;
use std::process::ExitCode;
use std::time::Instant;

/// Prints the command line summary and exits with status 2.
fn usage() -> ! {
    eprintln!("usage: trmodes-decode <ft8|ft4|wspr> <path.wav> [freq_min_hz] [freq_max_hz]");
    std::process::exit(2);
}

/// Minimal RIFF/WAVE reader for 12 kHz mono 16-bit PCM. Chunks other than `fmt ` and `data` are skipped
/// (some WSJT-X files carry a `LIST` or `bext` chunk), and `None` comes back when the file is unreadable or
/// the format differs.
fn load_wav_i16(path: &std::path::Path) -> Option<Vec<i16>> {
    let bytes = std::fs::read(path).ok()?;
    if bytes.len() < 12 || &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        return None;
    }
    let mut i = 12usize;
    let (mut sample_rate, mut bits, mut channels) = (0u32, 0u16, 0u16);
    let (mut data_off, mut data_len) = (0usize, 0usize);
    while i + 8 <= bytes.len() {
        let id = &bytes[i..i + 4];
        let len = u32::from_le_bytes(bytes[i + 4..i + 8].try_into().ok()?) as usize;
        i += 8;
        if id == b"fmt " && i + 16 <= bytes.len() {
            channels = u16::from_le_bytes(bytes[i + 2..i + 4].try_into().ok()?);
            sample_rate = u32::from_le_bytes(bytes[i + 4..i + 8].try_into().ok()?);
            bits = u16::from_le_bytes(bytes[i + 14..i + 16].try_into().ok()?);
        } else if id == b"data" {
            data_off = i;
            data_len = len.min(bytes.len() - i);
        }
        i += len;
        if len % 2 == 1 {
            i += 1;
        }
    }
    if channels != 1 || sample_rate != 12_000 || bits != 16 || data_off == 0 {
        eprintln!(
            "warning: {} is not 12 kHz mono 16-bit PCM (channels={channels} rate={sample_rate} bits={bits})",
            path.display()
        );
        return None;
    }
    let samples = &bytes[data_off..data_off + data_len];
    Some(
        samples
            .chunks_exact(2)
            .map(|b| i16::from_le_bytes([b[0], b[1]]))
            .collect(),
    )
}

/// Same as `load_wav_i16`, with the samples scaled to the range -1.0 to 1.0 as the WSPR decoder wants them.
fn load_wav_f32(path: &std::path::Path) -> Option<Vec<f32>> {
    Some(
        load_wav_i16(path)?
            .into_iter()
            .map(|s| s as f32 / 32_768.0)
            .collect(),
    )
}

/// Brings a slot to exactly `len` samples, padding with zeros or cutting the excess.
fn pad_or_truncate(mut v: Vec<i16>, len: usize) -> Vec<i16> {
    v.resize(len, 0);
    v
}

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        usage();
    }
    let mode = args[1].as_str();
    let path = std::path::Path::new(&args[2]);
    let freq_min: f32 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(100.0);
    let freq_max: f32 = args.get(4).and_then(|s| s.parse().ok()).unwrap_or(3000.0);
    let sync_min: f32 = args.get(5).and_then(|s| s.parse().ok()).unwrap_or(1.0);
    let max_cand: usize = args.get(6).and_then(|s| s.parse().ok()).unwrap_or(200);
    let light = args.iter().any(|a| a == "--light");

    match mode {
        "ft8" | "ft4" => {
            let Some(audio) = load_wav_i16(path) else {
                eprintln!("failed to load {}", path.display());
                return ExitCode::FAILURE;
            };
            let slot_len = if mode == "ft8" { 180_000 } else { 90_000 };
            let n_slots = audio.len().div_ceil(slot_len).max(1);
            let mut total = 0usize;
            let mut total_time = std::time::Duration::ZERO;
            for slot_idx in 0..n_slots {
                let start = slot_idx * slot_len;
                let end = (start + slot_len).min(audio.len());
                let slot = pad_or_truncate(audio[start..end].to_vec(), slot_len);

                let t0 = Instant::now();
                let decoded = match (mode, light) {
                    ("ft8", false) => tr_modes::decode::ft8::decode_slot(&slot, freq_min, freq_max, sync_min, max_cand),
                    ("ft8", true) => tr_modes::decode::ft8::decode_slot_light(&slot, freq_min, freq_max, sync_min, max_cand),
                    ("ft4", false) => tr_modes::decode::ft4::decode_slot(&slot, freq_min, freq_max, sync_min, max_cand),
                    (_, true) => tr_modes::decode::ft4::decode_slot_light(&slot, freq_min, freq_max, sync_min, max_cand),
                    _ => unreachable!(),
                };
                let elapsed = t0.elapsed();
                total_time += elapsed;

                println!(
                    "slot {slot_idx}: {} decode(s) in {:.3} s",
                    decoded.len(),
                    elapsed.as_secs_f64()
                );
                for d in &decoded {
                    println!(
                        "  {:7.1} Hz  dt={:+.2} s  SNR={:+.0} dB  {}",
                        d.freq_hz,
                        d.dt_sec,
                        d.snr_db.unwrap_or(f32::NAN),
                        d.message
                    );
                }
                total += decoded.len();
            }
            println!(
                "{} slot(s), {total} decode(s) total, {:.3} s decode time total, {:.3} s/slot average",
                n_slots,
                total_time.as_secs_f64(),
                total_time.as_secs_f64() / n_slots as f64
            );
        }
        "wspr" => {
            let Some(audio) = load_wav_f32(path) else {
                eprintln!("failed to load {}", path.display());
                return ExitCode::FAILURE;
            };
            let params = tr_modes::decode::wspr::SearchParams {
                freq_min_hz: freq_min,
                freq_max_hz: freq_max,
                max_candidates: max_cand,
                score_threshold: sync_min,
                ..Default::default()
            };
            let t0 = Instant::now();
            let decoded = tr_modes::decode::wspr::decode_slot(&audio, 12_000, 0, &params);
            let elapsed = t0.elapsed();
            println!("{} decode(s) in {:.3} s", decoded.len(), elapsed.as_secs_f64());
            for d in &decoded {
                println!("  {:7.1} Hz  dt={:+.2} s  {}", d.freq_hz, d.dt_sec, d.message);
            }
        }
        _ => usage(),
    }
    ExitCode::SUCCESS
}
