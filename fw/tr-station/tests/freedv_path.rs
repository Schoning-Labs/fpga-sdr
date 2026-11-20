// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! FreeDV receive through the firmware's station path (docs/FREEDV.md section 9),
//! on the mock fabric. A recording (the FreeDV program's sample signals, `tools/fetch_freedv_test.sh`)
//! goes in as the back end's 12 ksps audio blocks in the DDR3 ring, `Radio::service` runs
//! the chain, and a model of the audio engine plays the CPU ring at 48 ksps. What it plays must be
//! sample for sample what the FreeDV crate's own chain makes of the same input (12 kHz converter,
//! `RxStream`, 48 kHz converter), with no ring or queue under- or overruns.

use std::path::PathBuf;

use tr_fabric::audio::AUDIO_RING_WORDS;
use tr_fabric::backend::{BLOCK_BYTES, BLOCK_SAMPLES, HL2_PER_SAMPLE_12K};
use tr_fabric::mem::map;
use tr_fabric::mock::MockFabric;
use tr_freedv::ofdm::SyncState;
use tr_freedv::resample::Resampler;
use tr_freedv::RxStream;
use tr_regs::generated as g;
use tr_station::freedv::{FdvMode, QUEUE_SAMPLES};
use tr_station::radio::{Radio, Sideband};

const INDEX0: u64 = 0x12_3456_7800;

fn read_wav(name: &str) -> Option<Vec<i16>> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../captures/freedv").join(name);
    let mut r = hound::WavReader::open(path).ok()?;
    assert_eq!(r.spec().sample_rate, 8000);
    Some(r.samples::<i16>().map(|s| s.unwrap()).collect())
}

/// The chip's side: the back end writing 12 ksps blocks into its ring, and the audio engine
/// reading the CPU ring.
struct Chip<'a> {
    f: &'a MockFabric,
    pending: Vec<i16>,
    samples: u64,
    wptr: u32,
    rptr: u32,
    played: Vec<i16>,
    /// Frames whose left and right words differ.
    lr_differ: u32,
    /// Times the engine found the ring empty after it had played something.
    starved: u32,
    started: bool,
}

impl<'a> Chip<'a> {
    fn new(f: &'a MockFabric) -> Self {
        Chip { f, pending: Vec::new(), samples: 0, wptr: 0, rptr: 0, played: Vec::new(), lr_differ: 0, starved: 0, started: false }
    }

    /// Audio from the receiver; whole blocks go to the ring.
    fn rx_audio(&mut self, x: &[i16]) {
        self.pending.extend_from_slice(x);
        let f = self.f;
        let blocks = 1u32 << g::rx_backend::ring_slots::read(f, 0).log2();
        while self.pending.len() >= BLOCK_SAMPLES {
            let a = g::rx_backend::ring_base::read(f, 0) * 8 + (self.wptr % blocks) * BLOCK_BYTES;
            let stamp = INDEX0 + self.samples * HL2_PER_SAMPLE_12K;
            for k in 0..BLOCK_SAMPLES / 2 {
                f.poke_mem(a + 16 + 4 * k as u32, self.pending[2 * k] as u16 as u32 | (self.pending[2 * k + 1] as u16 as u32) << 16);
            }
            f.poke_mem(a, stamp as u32);
            f.poke_mem(a + 4, (stamp >> 32) as u32 & 0xFFFF);
            f.poke_mem(a + 8, self.wptr);
            f.poke_mem(a + 12, 0);
            self.pending.drain(..BLOCK_SAMPLES);
            self.samples += BLOCK_SAMPLES as u64;
            self.wptr += 1;
            f.poke(g::rx_backend::ring_wptr::addr(0), self.wptr);
        }
    }

    /// The audio engine plays `frames` stereo frames (it stops at an empty ring).
    fn play(&mut self, frames: usize) {
        let f = self.f;
        let wptr = g::audio::ring_wptr::read(f);
        for _ in 0..frames {
            if self.rptr == wptr {
                if self.started {
                    self.starved += 1;
                }
                break;
            }
            let w = f.mem(map::AUDIO_RING + (self.rptr % AUDIO_RING_WORDS) * 4);
            let (l, r) = ((w >> 16) as u16 as i16, w as u16 as i16);
            self.lr_differ += (l != r) as u32;
            self.played.push(l);
            self.rptr = self.rptr.wrapping_add(1);
            self.started = true;
        }
        f.poke(g::audio::ring_rptr::addr(), self.rptr);
    }
}

/// What the FreeDV crate's own chain makes of 12 kHz audio.
fn reference(mode: FdvMode, x12: &[i16], squelch: Option<f32>) -> Vec<i16> {
    let mut down = Resampler::new_12k_to_8k();
    let mut up = Resampler::new_8k_to_48k();
    let mut rx = RxStream::new(mode.ofdm());
    rx.rx.squelch = squelch.is_some();
    rx.rx.snr_squelch_db = squelch.unwrap_or(0.0);
    rx.rx.passthrough_gain = tr_station::freedv::PASSTHROUGH_GAIN;
    let mut y8 = Vec::new();
    down.process(x12, |s| y8.push(s));
    let mut out = Vec::new();
    for blk in y8.chunks(160) {
        rx.push(blk, |speech, _| up.process(speech, |s| out.push(s)));
    }
    out
}

struct Run {
    played: Vec<i16>,
    reference: Vec<i16>,
    underruns: u32,
    overruns: u32,
    starved: u32,
    lr_differ: u32,
    ring_lost: u32,
    sync: SyncState,
    frames: u32,
    frames_with_errors: u32,
    queue_peak: usize,
    muted_at_end: bool,
}

/// `x8`: the recording at 8 kHz, `seconds` of it (rounded down to whole 1,920-sample steps at 12 kHz).
fn run(mode: FdvMode, x8: &[i16], seconds: usize, squelch: Option<f32>, sideband: Sideband, step_ms: usize) -> Run {
    let mut up12 = Resampler::new_8k_to_12k();
    let mut x12 = Vec::new();
    up12.process(&x8[..seconds * 8_000], |s| x12.push(s));
    x12.truncate(x12.len() / 1_920 * 1_920);
    // a little silence after the signal lets the last frame through
    x12.extend(std::iter::repeat(0).take(1_920 * 2));

    let f = MockFabric::new();
    f.log_limit.set(1);
    let mut radio = Radio::new(&f, &f);
    radio.enter_freedv(14_236_000, sideband, mode, (squelch.is_some(), squelch.unwrap_or(0.0)));
    let mut chip = Chip::new(&f);
    let per_step = 12 * step_ms;
    for chunk in x12.chunks(per_step) {
        chip.rx_audio(chunk);
        radio.service();
        chip.play(48 * chunk.len() / 12);
    }
    let fdv = radio.freedv().unwrap();
    let ind = fdv.rx.indicators();
    Run {
        played: chip.played,
        reference: reference(mode, &x12[..chip.samples as usize], squelch),
        underruns: fdv.out.underruns,
        overruns: fdv.rx.queue.overruns,
        starved: chip.starved,
        lr_differ: chip.lr_differ,
        ring_lost: radio.ring_lost(),
        sync: ind.sync,
        frames: ind.frames,
        frames_with_errors: ind.frames_with_errors,
        queue_peak: fdv.rx.queue.peak,
        muted_at_end: fdv.rx.analog_muted(),
    }
}

fn check_equal(r: &Run, what: &str) {
    assert!(!r.played.is_empty());
    assert!(r.played.len() <= r.reference.len(), "{what}: more played than made");
    // what is still in the queue and the ring at the end is at most 0.7 s + 85 ms
    assert!(r.reference.len() - r.played.len() <= QUEUE_SAMPLES + AUDIO_RING_WORDS as usize, "{what}: {} of {} played", r.played.len(), r.reference.len());
    let first_diff = r.played.iter().zip(&r.reference).position(|(a, b)| a != b);
    assert_eq!(first_diff, None, "{what}: the speech differs from the FreeDV crate's chain at sample {first_diff:?}");
    assert_eq!(r.lr_differ, 0, "{what}: left and right differ");
    assert_eq!((r.underruns, r.overruns, r.starved, r.ring_lost), (0, 0, 0, 0), "{what}: ring underruns, queue overruns, engine starved, back-end blocks lost");
}

#[test]
fn freedv_program_sample_signals_through_the_station_path() {
    for (mode, file, squelch) in [(FdvMode::D700, "ve9qrp_700d.wav", Some(-2.0)), (FdvMode::E700, "ve9qrp_700e.wav", Some(-2.0))] {
        let Some(x) = read_wav(file) else {
            eprintln!("skipped: captures/freedv/{file} missing (run tools/fetch_freedv_test.sh)");
            continue;
        };
        let r = run(mode, &x, 30, squelch, Sideband::Upper, 20);
        eprintln!(
            "{file}: {} samples played of {}, sync {:?}, {} frames ({} without codeword), queue peak {} samples, underruns {}, overruns {}",
            r.played.len(),
            r.reference.len(),
            r.sync,
            r.frames,
            r.frames_with_errors,
            r.queue_peak,
            r.underruns,
            r.overruns
        );
        check_equal(&r, file);
        assert_eq!(r.sync, SyncState::Synced, "{file}: in sync at the end");
        assert!(r.frames > 100 && r.frames_with_errors <= 3, "{file}: {} frames, {} errors", r.frames, r.frames_with_errors);
        // speech came out: loud, not silence
        let loud = r.played.iter().filter(|s| s.abs() > 500).count();
        assert!(loud > r.played.len() / 10, "{file}: only {loud} loud samples");
        assert!(r.muted_at_end || r.sync == SyncState::Synced);
    }
}

/// A slower main loop (60 ms between calls) still keeps the 85 ms ring from running dry; a stall
/// longer than the ring is counted as an underrun.
#[test]
fn loop_jitter_and_stalls() {
    let Some(x) = read_wav("ve9qrp_700e.wav") else {
        eprintln!("skipped: captures/freedv/ve9qrp_700e.wav missing");
        return;
    };
    let r = run(FdvMode::E700, &x, 12, Some(-2.0), Sideband::Upper, 60);
    check_equal(&r, "700E with a 60 ms loop");

    // 300 ms between calls: the ring (85 ms) runs dry; the chip model sees it and the firmware counts it
    let r = run(FdvMode::E700, &x, 12, Some(-2.0), Sideband::Upper, 300);
    assert!(r.underruns > 0 && r.starved > 0, "a 300 ms stall must be counted (underruns {}, starved {})", r.underruns, r.starved);
}

/// Squelch off: what is not in sync is passed through at a quarter of its level, in the
/// firmware's chain exactly as in the crate's. Lower sideband changes only the receiver's filter.
#[test]
fn squelch_off_passes_the_band_through_until_sync() {
    let Some(x) = read_wav("ve9qrp_700d.wav") else {
        eprintln!("skipped: captures/freedv/ve9qrp_700d.wav missing");
        return;
    };
    let r = run(FdvMode::D700, &x, 8, None, Sideband::Lower, 20);
    check_equal(&r, "700D squelch off");
    // the first second is the modem searching: the audio is the signal itself, at 0.25
    let early: i64 = r.played[..24_000].iter().map(|s| s.unsigned_abs() as i64).sum();
    assert!(early > 24_000 * 100, "passthrough while searching: mean {}", early / 24_000);
}

#[test]
fn the_queue_counts_what_does_not_fit() {
    use tr_station::freedv::SpeechQueue;
    let mut q = SpeechQueue::new();
    for i in 0..QUEUE_SAMPLES + 10 {
        q.push(i as i16);
    }
    assert_eq!((q.len(), q.overrun_samples, q.overruns), (QUEUE_SAMPLES, 10, 1));
    let mut out = [0u32; 4];
    assert_eq!(q.pop_stereo(&mut out), 4);
    assert_eq!(out[1], tr_fabric::audio::stereo_word(1, 1));
    for i in 0..6 {
        q.push(i);
    }
    assert_eq!((q.overrun_samples, q.overruns), (12, 2), "four fit, two are lost in a second episode");
}

/// The receiver and the waterfall window of the FreeDV screen, in register values.
#[test]
fn receiver_and_waterfall_set_up_for_both_sidebands() {
    use tr_dsp::backend::design::{bandpass, quantize, FS};
    use tr_regs::generated::{rx_backend as bk, video as vid, zoom as zm};
    let rect = (20, 124, 1_172, 656);
    for (sb, dial, lo, hi, centre) in [(Sideband::Upper, 14_236_000u32, 100.0, 3_100.0, 14_237_500u32), (Sideband::Lower, 7_177_000, -3_100.0, -100.0, 7_175_500)] {
        let f = MockFabric::new();
        f.log_limit.set(1);
        f.poke(zm::id::addr(), zm::id::RESET);
        let mut r = Radio::new(&f, &f);
        r.enter_freedv(dial, sb, FdvMode::D700, (true, -2.0));
        r.start_display_freedv(rect).unwrap();
        let coef = quantize(&bandpass(FS, lo, hi, 255));
        for n in [3usize, 100, 127, 200] {
            assert_eq!(f.reg(bk::coef::addr(2 * n as u32)), coef.re[n] as u32, "{sb:?} tap {n} real");
            assert_eq!(f.reg(bk::coef::addr(2 * n as u32 + 1)), coef.im[n] as u32, "{sb:?} tap {n} imaginary");
        }
        assert_eq!(f.reg(tr_regs::generated::rx_bank::ctrl::addr(0)) & 1, 1, "receiver running");
        // 6 kHz span at 3.125 Hz per column, centered on the middle of the audio band, in the middle of the 1,920 columns
        assert_eq!(f.reg(zm::phase_inc::addr()), tr_fabric::phase_inc(centre));
        assert_eq!(f.reg(zm::ctrl::addr()) >> 11 & 1, 0, "not the FT8 column scale");
        assert_eq!(f.reg(vid::win_src::addr(0)), (1_920 - 1_172) / 2);
        assert_eq!(f.reg(vid::wf_win_ctrl::addr(0)), 1, "zoom waterfall");
        assert_eq!(r.waterfall_ring().is_none(), true);
        // a retune in the same sideband moves the zoom with it; the other sideband restarts the receiver
        r.freedv_retune(dial + 100, sb);
        assert_eq!(f.reg(zm::phase_inc::addr()), tr_fabric::phase_inc(centre + 100));
        // TX stays off through all of it
        assert!(!r.tx.is_armed());
        r.leave_freedv(14_074_000);
        assert!(r.freedv().is_none());
        assert_eq!(f.reg(g::audio::ctrl::addr()), 0, "audio engine off");
    }
}

/// The text channel: a modulated signal carrying a call sign in the varicode text bits goes through
/// the whole station path and the call sign comes out at the other end.
#[test]
fn text_channel_carries_a_call_sign_through_the_station_path() {
    use tr_freedv::varicode::{encode, MAX_BITS};
    use tr_freedv::Tx;
    for mode in [FdvMode::D700, FdvMode::E700] {
        let m = mode.ofdm();
        let tx = Tx::new(m);
        let (spf, k, ntxt) = (tx.samples_per_frame(), m.code.data_bits(), m.ntxtbits);
        // "VK5DGR" and a carriage return, repeated, then idle zeros
        let mut text_bits: Vec<u8> = Vec::new();
        for _ in 0..40 {
            for c in b"VK5DGR\r" {
                let mut b = [0u8; MAX_BITS];
                let n = encode(*c, &mut b);
                text_bits.extend_from_slice(&b[..n]);
            }
        }
        let mut lcg = 12345u32;
        let mut x8: Vec<i16> = Vec::new();
        let mut frame = vec![0i16; spf];
        let mut at = 0;
        while x8.len() < 20 * 8_000 {
            let payload: Vec<u8> = (0..k)
                .map(|_| {
                    lcg = lcg.wrapping_mul(1664525).wrapping_add(1013904223);
                    (lcg >> 24) as u8 & 1
                })
                .collect();
            let mut bits = vec![0u8; ntxt];
            for b in bits.iter_mut() {
                *b = text_bits.get(at).copied().unwrap_or(0);
                at += 1;
            }
            tx.tx_bits(&payload, &bits, &mut frame);
            x8.extend_from_slice(&frame);
        }
        let r = run_text(mode, &x8);
        eprintln!("{}: text channel gave {:?} ({} characters)", mode.name(), r.0, r.1);
        assert!(r.0.contains("VK5DGR"), "{}: {:?}", mode.name(), r.0);
        // and the screen's state says the same
        let scr = r.2;
        assert_eq!((scr.sync_level, scr.text.as_str(), scr.audio_ok), (2, "VK5DGR", true), "{}", mode.name());
        assert!(scr.frames > 100 && scr.snr_db > 10.0 && scr.foff_hz.abs() < 1.0, "{} frames, {:.1} dB, {:.1} Hz", scr.frames, scr.snr_db, scr.foff_hz);
        assert!(scr.audio_text.contains("underruns 0"));
    }
}

fn run_text(mode: FdvMode, x8: &[i16]) -> (String, u32, tr_gui::fdv::FdvScreenState) {
    let mut up12 = Resampler::new_8k_to_12k();
    let mut x12 = Vec::new();
    up12.process(x8, |s| x12.push(s));
    x12.truncate(x12.len() / 1_920 * 1_920);
    let f = MockFabric::new();
    f.log_limit.set(1);
    let mut radio = Radio::new(&f, &f);
    radio.enter_freedv(14_236_000, Sideband::Upper, mode, (false, 0.0));
    let mut chip = Chip::new(&f);
    for chunk in x12.chunks(240) {
        chip.rx_audio(chunk);
        radio.service();
        chip.play(960);
    }
    let scr = tr_station::fdvstation::FdvStation::new().screen(&radio, "", true);
    let t = radio.freedv().unwrap().rx.text();
    (t.display().to_string(), t.chars, scr)
}
