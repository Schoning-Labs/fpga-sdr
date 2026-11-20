// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Demodulates a raw IQ capture file to a WAV file, using the same `tr-dsp` demodulators the
//! firmware runs, which makes it the way to listen to a real capture from an HL2 antenna (see
//! "Testing before the board arrives" in `docs/DECISIONS.md`). It is a plain `std` binary, like
//! every example and binary in this workspace outside the AE350-only crates (`tr-ae350`,
//! `tr-fabric`, `tr-net` and `tr-app`), while `tr-dsp` itself stays `no_std`.
//!
//! Input format: raw interleaved 32-bit float IQ samples (`I0 Q0 I1 Q1 ...`, native endianness),
//! the same layout as the `.cfile` and `.fc32` files of GNU Radio, which is a simple and well-known
//! convention, chosen because the on-the-wire framing of the receiver-bank IQ writer
//! (`docs/ARCHITECTURE.md` section 3.2) is a separate matter. If that framing is different, only
//! the reader in this file needs to change, and every demodulator below is unaffected.
//!
//! Usage:
//!   `cargo run -p tr-dsp --example demod_wav, <input.cf32> <sample_rate_hz> <mode> <output.wav>`
//!
//! `sample_rate_hz` must be 48000, 96000, 192000, or 384000 (the receiver-bank output rates,
//! `docs/rawfront`/`rx-dsp`'s `rate_sel`); anything above 48000 is decimated down first.
//! `mode` is one of: `usb`, `lsb`, `cw`, `am-env`, `am-sync`, `fm`.

use std::env;
use std::fs::File;
use std::io::{BufReader, Read};
use std::process::ExitCode;

use tr_dsp::agc::Agc;
use tr_dsp::am::{AmEnvelopeDemod, AmSyncDemod};
use tr_dsp::cw::CwDemod;
use tr_dsp::fastconv::BLOCK;
use tr_dsp::fft::Fft1024;
use tr_dsp::fm::{FmDemod, Squelch};
use tr_dsp::resample::Decimator;
use tr_dsp::ssb::{Sideband, SsbDemod};
use tr_dsp::C32;

const AUDIO_RATE: f32 = 48_000.0;

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    if args.len() != 5 {
        eprintln!(
            "usage: {} <input.cf32> <sample_rate_hz> <mode: usb|lsb|cw|am-env|am-sync|fm> <output.wav>",
            args.first().map(String::as_str).unwrap_or("demod_wav")
        );
        return ExitCode::FAILURE;
    }
    let input_path = &args[1];
    let sample_rate_hz: f32 = match args[2].parse() {
        Ok(v) => v,
        Err(_) => {
            eprintln!("invalid sample rate: {}", args[2]);
            return ExitCode::FAILURE;
        }
    };
    let mode = args[3].as_str();
    let output_path = &args[4];

    let decim = match sample_rate_hz as u32 {
        48_000 => 1,
        96_000 => 2,
        192_000 => 4,
        384_000 => 8,
        other => {
            eprintln!("unsupported sample rate {other} Hz (expected 48000/96000/192000/384000)");
            return ExitCode::FAILURE;
        }
    };

    let iq = match read_cf32(input_path) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("reading {input_path}: {e}");
            return ExitCode::FAILURE;
        }
    };
    eprintln!("read {} IQ samples from {input_path} at {sample_rate_hz} Hz", iq.len());

    let mut dec = Decimator::new(decim);
    let mut audio_iq = Vec::with_capacity(iq.len() / decim as usize + 1);
    for &s in &iq {
        if let Some(y) = dec.process(s) {
            audio_iq.push(y);
        }
    }
    eprintln!("decimated to {} samples at {AUDIO_RATE} Hz", audio_iq.len());

    let fft = Fft1024::new();
    let mut audio = Vec::with_capacity(audio_iq.len());
    let mut i = 0;
    while i + BLOCK <= audio_iq.len() {
        let mut in_block = [C32::ZERO; BLOCK];
        in_block.copy_from_slice(&audio_iq[i..i + BLOCK]);
        let mut out_block = [0.0f32; BLOCK];
        run_mode(mode, &fft, &in_block, &mut out_block);
        audio.extend_from_slice(&out_block);
        i += BLOCK;
    }

    if let Err(e) = write_wav(output_path, &audio, AUDIO_RATE as u32) {
        eprintln!("writing {output_path}: {e}");
        return ExitCode::FAILURE;
    }
    eprintln!("wrote {} audio samples to {output_path}", audio.len());
    ExitCode::SUCCESS
}

/// One-shot dispatch: builds a fresh demodulator per call, which is wasteful for anything other
/// than a whole-file batch run like this example (the firmware keeps one demodulator instance
/// per receiver alive across blocks, as every `tr-dsp` test does), fine here since this
/// example processes the whole file in one pass with no state that needs to persist afterward.
fn run_mode(mode: &str, fft: &Fft1024, input: &[C32; BLOCK], output: &mut [f32; BLOCK]) {
    // A single call only ever handles one block; callers that want the mode built once per file
    // should inline this match instead. Kept simple here since demod_wav processes one file.
    thread_local_demod::with(mode, fft, |demod_state| match demod_state {
        DemodState::Usb(d) => d.process_block(fft, input, output),
        DemodState::Lsb(d) => d.process_block(fft, input, output),
        DemodState::Cw(d) => d.process_block(fft, input, output),
        DemodState::AmEnv(d) => d.process_block(fft, input, output),
        DemodState::AmSync(d) => d.process_block(fft, input, output),
        DemodState::Fm(d) => d.process_block(fft, input, output),
    });
}

enum DemodState {
    Usb(SsbDemod),
    Lsb(SsbDemod),
    Cw(CwDemod),
    AmEnv(AmEnvelopeDemod),
    AmSync(AmSyncDemod),
    Fm(FmDemod),
}

/// Keeps exactly one demodulator alive across the whole file (built on first call, reused after)
/// without threading extra state through `main`'s loop, a thin wrapper, not actual
/// thread-local storage semantics beyond what `std::cell` gives a single-threaded example.
mod thread_local_demod {
    use super::*;
    use std::cell::RefCell;

    thread_local! {
        static STATE: RefCell<Option<DemodState>> = const { RefCell::new(None) };
    }

    pub fn with(mode: &str, fft: &Fft1024, f: impl FnOnce(&mut DemodState)) {
        STATE.with(|cell| {
            let mut slot = cell.borrow_mut();
            if slot.is_none() {
                *slot = Some(build(mode, fft));
            }
            f(slot.as_mut().unwrap());
        });
    }

    fn build(mode: &str, fft: &Fft1024) -> DemodState {
        let agc = || Agc::new(AUDIO_RATE, 5.0, 300.0, 100.0, 0.3, 0.05, 20.0);
        match mode {
            "usb" => DemodState::Usb(SsbDemod::new(fft, AUDIO_RATE, Sideband::Upper, 300.0, 2700.0, agc())),
            "lsb" => DemodState::Lsb(SsbDemod::new(fft, AUDIO_RATE, Sideband::Lower, 300.0, 2700.0, agc())),
            "cw" => DemodState::Cw(CwDemod::new(fft, AUDIO_RATE, 700.0, 300.0, agc())),
            "am-env" => DemodState::AmEnv(AmEnvelopeDemod::new(fft, AUDIO_RATE, 2500.0, agc())),
            "am-sync" => DemodState::AmSync(AmSyncDemod::new(fft, AUDIO_RATE, 2500.0, agc())),
            "fm" => {
                let squelch = Squelch::new(AUDIO_RATE, 0.02, 0.3, 100.0);
                DemodState::Fm(FmDemod::new(fft, AUDIO_RATE, 6000.0, 75.0, squelch))
            }
            other => {
                eprintln!("unknown mode '{other}', defaulting to usb");
                DemodState::Usb(SsbDemod::new(fft, AUDIO_RATE, Sideband::Upper, 300.0, 2700.0, agc()))
            }
        }
    }
}

fn read_cf32(path: &str) -> std::io::Result<Vec<C32>> {
    let mut reader = BufReader::new(File::open(path)?);
    let mut bytes = Vec::new();
    reader.read_to_end(&mut bytes)?;
    let n = bytes.len() / 8; // 2 x f32 per sample
    let mut out = Vec::with_capacity(n);
    for chunk in bytes.chunks_exact(8) {
        let i = f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
        let q = f32::from_le_bytes([chunk[4], chunk[5], chunk[6], chunk[7]]);
        out.push(C32::new(i, q));
    }
    Ok(out)
}

fn write_wav(path: &str, audio: &[f32], sample_rate: u32) -> Result<(), hound::Error> {
    let spec = hound::WavSpec {
        channels: 1,
        sample_rate,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };
    let mut writer = hound::WavWriter::create(path, spec)?;
    for &s in audio {
        let clipped = s.clamp(-1.0, 1.0);
        writer.write_sample((clipped * i16::MAX as f32) as i16)?;
    }
    writer.finalize()
}
