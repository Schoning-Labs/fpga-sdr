// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The whole FT8 chain without hardware: the firmware's own code (station logic,
//! radio glue, drivers, encoder, decoder) against a simulated fabric that does what the chip does
//! with the two rings: it plays the TX baseband ring at 48 ksps and writes 12 ksps audio blocks
//! with HL2 stamps into the receiver's ring. The audio it writes is the TX baseband's Q channel,
//! which is what the HL2's echo mode returns after the TX and RX chains. So a CQ the station sends
//! has to come back through the receive path and appear in the decode list.
//!
//! One 15 s slot in simulated time, in 20 ms steps. The same function runs in a host test and in
//! the QEMU image (`tr-app`, `ft8fw_qemu`), where it runs on the target's instruction set.
//!
//! A second self-test ([`run_freedv`]) does the same for FreeDV receive: a modulated 700D signal goes
//! into the receiver audio ring and has to come out as locked frames, text and played speech.

use alloc::vec::Vec;
use core::fmt::Write;

use tr_fabric::mock::MockFabric;
use tr_gui::ft8::{ClockStatus, Ft8Event, Ft8ScreenState, RowKind, WATERFALL_RECT};
use tr_modes::txbb::WAVE_LEN;
use tr_regs::generated as g;

use crate::radio::{decode_slot, Radio, HL2_PER_MS};
use crate::station::{slot_of, Action, Station, StationConfig};

/// The operator and the screen of a self-test run.
pub trait Ui {
    /// What the operator did since the last call; `t_ms` is the time since the run started.
    fn poll(&mut self, t_ms: i64) -> Vec<Ft8Event>;
    /// Twice per simulated second: the screen's state.
    fn show(&mut self, state: &Ft8ScreenState);
}

/// An operator who switches TX on at 0.1 s and calls CQ at 0.2 s, without a screen.
pub struct ScriptedUi;

impl Ui for ScriptedUi {
    fn poll(&mut self, t_ms: i64) -> Vec<Ft8Event> {
        match t_ms {
            100 => alloc::vec![Ft8Event::TxEnableToggle],
            200 => alloc::vec![Ft8Event::Cq],
            _ => Vec::new(),
        }
    }
    fn show(&mut self, _state: &Ft8ScreenState) {}
}

/// The chip's side of the two rings.
pub struct SimFabric<'a> {
    f: &'a MockFabric,
    t_ms: i64,
    tx_rptr: u32,
    /// TX words played.
    pub tx_played: u64,
    /// Times the TX ring ran empty after holding data.
    pub tx_ran_empty: u32,
    tx_had_data: bool,
    rx_block: [i16; 128],
    rx_fill: usize,
    rx_samples: u64,
    rx_wptr: u32,
}

/// HL2 sample index at simulated time 0.
const INDEX0: u64 = 0x12_3456_7800;

impl<'a> SimFabric<'a> {
    /// A chip that has started: ids, memory and PLLs up, the HL2 streaming.
    pub fn new(f: &'a MockFabric) -> Self {
        f.poke(g::system::id::addr(), g::system::id::RESET);
        f.poke(g::hl2_link::id::addr(), g::hl2_link::id::RESET);
        f.poke(g::rx_bank::id::addr(), g::rx_bank::id::RESET);
        f.poke(g::rx_backend::id::addr(), g::rx_backend::id::RESET);
        f.poke(g::spectrum::id::addr(), g::spectrum::id::RESET);
        f.poke(g::video::id::addr(), g::video::id::RESET);
        // The hardware waterfall writer runs on its own ring: its line must not matter here.
        f.poke(g::video::wf_write_line::addr(), 1_234);
        f.poke(g::tx::id::addr(), g::tx::id::RESET);
        f.poke(g::audio::id::addr(), g::audio::id::RESET);
        f.poke(g::ft8::id::addr(), g::ft8::id::RESET);
        f.poke(g::system::status::addr(), 0b11);
        f.poke(g::hl2_link::status::addr(), 0b11);
        f.poke(g::hl2_link::safety_byte::addr(), 0x01);
        let s = SimFabric { f, t_ms: 0, tx_rptr: 0, tx_played: 0, tx_ran_empty: 0, tx_had_data: false, rx_block: [0; 128], rx_fill: 0, rx_samples: 0, rx_wptr: 0 };
        s.poke_time();
        s
    }

    fn poke_time(&self) {
        let index = INDEX0 + self.t_ms as u64 * HL2_PER_MS as u64;
        self.f.poke(g::hl2_link::sample_index_lo::addr(), index as u32);
        self.f.poke(g::hl2_link::sample_index_hi::addr(), (index >> 32) as u32);
        self.f.poke(g::system::dsp_cycles::addr(), (self.t_ms as u64 * 120_000) as u32);
    }

    fn rx_sample(&mut self, s: i16) {
        self.rx_block[self.rx_fill] = s;
        self.rx_fill += 1;
        self.rx_samples += 1;
        if self.rx_fill < 128 {
            return;
        }
        self.rx_fill = 0;
        let f = self.f;
        if !g::rx_backend::ring_ctrl::read(f, 0).enable() || !g::rx_backend::ctrl::read(f, 0).enable() {
            return;
        }
        let blocks = 1u32 << g::rx_backend::ring_slots::read(f, 0).log2();
        let a = g::rx_backend::ring_base::read(f, 0) * 8 + (self.rx_wptr % blocks) * 34 * 8;
        let stamp = INDEX0 + (self.rx_samples - 128) * 6_400;
        for k in 0..64 {
            f.poke_mem(a + 16 + 4 * k as u32, self.rx_block[2 * k] as u16 as u32 | (self.rx_block[2 * k + 1] as u16 as u32) << 16);
        }
        // Header last, then the pointer, as the logic does.
        f.poke_mem(a, stamp as u32);
        f.poke_mem(a + 4, (stamp >> 32) as u32 & 0xFFFF);
        f.poke_mem(a + 8, self.rx_wptr);
        f.poke_mem(a + 12, 0);
        self.rx_wptr += 1;
        f.poke(g::rx_backend::ring_wptr::addr(0), self.rx_wptr);
    }

    /// `ms` milliseconds of chip time: 48 TX words played and 12 audio samples made per ms.
    pub fn advance(&mut self, ms: u32) {
        let f = self.f;
        for _ in 0..ms {
            let armed = g::tx::ctrl::read(f).enable() && g::hl2_link::tx_ctrl::read(f).enable();
            if !armed {
                // The ring reader is held in reset while the chain is off.
                self.tx_rptr = 0;
                self.tx_had_data = false;
            }
            let wptr = g::tx::ring_wptr::read(f);
            let base = g::tx::ring_base::read(f) * 4;
            for k in 0..48 {
                let mut q = 0i16;
                if armed && self.tx_rptr != wptr {
                    q = f.mem(base + (self.tx_rptr & 8_191) * 4) as u16 as i16;
                    self.tx_rptr = self.tx_rptr.wrapping_add(1);
                    self.tx_played += 1;
                    self.tx_had_data = true;
                } else if self.tx_had_data {
                    self.tx_had_data = false;
                    self.tx_ran_empty += 1;
                }
                if k % 4 == 0 {
                    // Echo at a quarter of full scale, as a received signal.
                    self.rx_sample(q / 4);
                }
            }
            f.poke(g::tx::ring_rptr::addr(), self.tx_rptr);
            self.t_ms += 1;
        }
        self.poke_time();
    }
}

/// What a run found.
#[derive(Clone, Debug, Default)]
pub struct Report {
    /// Every chip block answered with the id the driver expects.
    pub blocks_ok: bool,
    /// Both TX enables were off before the run.
    pub tx_off_at_start: bool,
    /// Transmissions started; exactly one is expected.
    pub tx_started: u32,
    /// Words the simulated chip played from the TX ring.
    pub tx_words_played: u64,
    /// Times the TX ring ran empty after holding data; once, at the end of the message.
    pub tx_ran_empty: u32,
    /// Writes to the ring pointers that broke the flush-before-pointer rule.
    pub flush_violations: usize,
    /// 12 ksps samples of the slot the radio had received when it was decoded (180,000 in a full slot).
    pub slot_samples: usize,
    /// Messages decoded from the slot.
    pub decodes: usize,
    /// Our own CQ as decoded from the receive path: audio frequency and time offset.
    pub own_cq: Option<(f32, f32)>,
    /// Both TX enables were off after the operator switched TX off.
    pub tx_off_at_end: bool,
    /// Waterfall lines the radio drew.
    pub waterfall_lines: u64,
    /// Of the newest 110 rows of the window as the compositor reads them, rows whose strongest
    /// column is at the CQ's frequency.
    pub waterfall_signal_rows: u32,
    /// (row, column, level) of the rows with a strong column elsewhere.
    pub waterfall_strays: Vec<(u32, u32, u8)>,
}

impl Report {
    /// True if every check of the run holds.
    pub fn pass(&self) -> bool {
        self.blocks_ok
            && self.tx_off_at_start
            && self.tx_started == 1
            && self.tx_words_played == WAVE_LEN as u64
            && self.tx_ran_empty == 1
            && self.flush_violations == 0
            && self.slot_samples > 169_000
            && matches!(self.own_cq, Some((hz, dt)) if (hz - 1_500.0).abs() < 3.0 && dt.abs() < 0.15)
            && self.tx_off_at_end
            && self.waterfall_lines >= 80
            && self.waterfall_signal_rows >= 60
            && self.waterfall_strays.len() <= 5
    }
}

/// Runs one slot: TX on, CQ, the CQ is played, received and decoded; then TX off. Progress goes
/// to `out` as text lines.
pub fn run(f: &MockFabric, ui: &mut dyn Ui, out: &mut dyn Write) -> Report {
    let mut rep = Report::default();
    // Log the first accesses only: enough to check the order of writes, small enough for QEMU.
    f.log_limit.set(150_000);
    let mut sim = SimFabric::new(f);
    let mut radio = Radio::new(f, f);
    let checks = radio.check();
    rep.blocks_ok = checks.iter().all(|c| c.ok());
    for c in &checks {
        let _ = writeln!(out, "block {:<10} id {:#010x} {}", c.name, c.id, if c.ok() { "ok" } else { "UNEXPECTED" });
    }
    rep.tx_off_at_start = !g::tx::ctrl::read(f).enable() && !g::hl2_link::tx_ctrl::read(f).enable();
    radio.start_receive(14_074_000);
    match radio.start_display(WATERFALL_RECT) {
        Ok(()) => {}
        Err(e) => {
            let _ = writeln!(out, "display not started: {e:?}");
        }
    }
    // The ring clear above is a lot of memory writes; the order check below is about the TX ring.
    f.clear_log();
    radio.show_display();
    let _ = writeln!(out, "receiver 0 on 14,074,000 Hz, FT8 engines in the chip: {}", radio.ft8_engines_present());

    let mut cfg = StationConfig::new("K1XYZ", "FN42");
    cfg.decode_own_slots = true;
    let mut station = Station::new(cfg);
    // 18:40:00 UTC of some day: the start of a 00/30 slot.
    let utc0: i64 = 20_738 * 86_400_000 + (18 * 3_600 + 40 * 60) * 1_000;
    let clock = ClockStatus::Synced { age_s: 1 };

    let mut t = 0i64;
    while t <= 15_000 {
        let utc = utc0 + t;
        let mut actions: Vec<Action> = Vec::new();
        for e in ui.poll(t) {
            actions.extend(station.on_event(e));
        }
        if radio.tx_forbidden() {
            actions.extend(station.force_tx_off());
        }
        actions.extend(station.tick(Some(utc)));
        for a in &actions {
            match a {
                Action::StartDecode { slot } => {
                    let (audio, n) = radio.slot_audio(slot_of(utc).1 as i64);
                    rep.slot_samples = n;
                    let _ = writeln!(out, "t {:>5} ms: decoding the slot, {} of 180000 samples received", t, n);
                    let heard = decode_slot(&audio, *slot, 30);
                    rep.decodes = heard.len();
                    for h in &heard {
                        let _ = writeln!(out, "  decoded {:>4} dB {:+.2} s {:>6.1} Hz  {}", h.snr_db, h.dt_s, h.audio_hz, h.text);
                    }
                    station.on_decodes(*slot, &heard);
                }
                Action::StartTx { msg, audio_hz, skip_ms, .. } => {
                    rep.tx_started += 1;
                    let _ = writeln!(out, "t {:>5} ms: transmit \"{}\" at {} Hz, {} ms late", t, msg.text(), audio_hz, skip_ms);
                    radio.apply(a);
                }
                other => {
                    let _ = writeln!(out, "t {:>5} ms: {:?}", t, other);
                    radio.apply(other);
                }
            }
        }
        radio.service();
        sim.advance(20);
        if t % 500 == 0 {
            let (link, ok) = radio.link_status();
            ui.show(&station.screen(Some(utc), clock, &link, ok));
        }
        t += 20;
    }

    let screen = station.screen(Some(utc0 + 15_000), clock, "", true);
    rep.own_cq = screen.decodes.iter().find(|d| d.kind == RowKind::Cq && d.message == "CQ K1XYZ FN42").map(|d| (d.audio_hz as f32, d.dt_s));
    rep.tx_words_played = sim.tx_played;
    rep.tx_ran_empty = sim.tx_ran_empty;
    rep.flush_violations = f.flush_rule_violations(&[g::tx::ring_wptr::addr(), g::video::wf_win_line::addr(0)]);
    rep.waterfall_lines = radio.waterfall_lines;
    (rep.waterfall_signal_rows, rep.waterfall_strays) = waterfall_rows(f);

    // The operator switches TX off again.
    for a in station.on_event(Ft8Event::TxEnableToggle) {
        radio.apply(&a);
    }
    rep.tx_off_at_end = !g::tx::ctrl::read(f).enable() && !g::hl2_link::tx_ctrl::read(f).enable() && !station.tx_enabled();
    let _ = writeln!(
        out,
        "TX words played {} of {}, ring ran empty {} time(s), write-order faults {}, own CQ decoded: {:?}",
        rep.tx_words_played, WAVE_LEN, rep.tx_ran_empty, rep.flush_violations, rep.own_cq
    );
    let _ = writeln!(out, "self-test {}", if rep.pass() { "PASS" } else { "FAIL" });
    rep
}

/// Of the newest 110 rows of the waterfall window, as the compositor would read them from the ring:
/// (rows whose strongest column is at the CQ's 1,500 to 1,550 Hz, rows with a strong column
/// anywhere else).
fn waterfall_rows(f: &MockFabric) -> (u32, Vec<(u32, u32, u8)>) {
    use tr_fabric::wfring::compositor_view;
    let cols = WATERFALL_RECT.2;
    let (c0, c1) = (crate::waterfall::column_of(1_490.0, cols as usize) as u32, crate::waterfall::column_of(1_560.0, cols as usize) as u32);
    let (mut signal, mut stray) = (0, Vec::new());
    for row in 0..110 {
        // The strongest columns (a loud tone saturates a plateau): their center.
        let (mut best, mut first, mut last) = (0u8, 0u32, 0u32);
        for c in 0..cols {
            let v = compositor_view(f, f, 0, row, c);
            if v > best {
                (best, first, last) = (v, c, c);
            } else if v == best {
                last = c;
            }
        }
        let at = (first + last) / 2;
        if best >= 150 {
            if (c0..=c1).contains(&at) {
                signal += 1;
            } else {
                stray.push((row, at, best));
            }
        }
    }
    (signal, stray)
}

// ======================================================================== FreeDV

/// 12 ksps audio of a FreeDV signal: random payload bits (the codec makes noise-like speech of
/// them) and "VK5DGR" repeated in the text channel, modulated by the crate modulator and converted
/// from 8 to 12 kHz as a receiver back end would give it. A whole number of 1,920-sample steps.
pub fn freedv_signal_12k(mode: crate::freedv::FdvMode, seconds: usize) -> Vec<i16> {
    use tr_freedv::resample::Resampler;
    use tr_freedv::varicode::{encode, MAX_BITS};
    use tr_freedv::Tx;
    let m = mode.ofdm();
    let tx = Tx::new(m);
    let (spf, k, ntxt) = (tx.samples_per_frame(), m.code.data_bits(), m.ntxtbits);
    let mut text_bits: Vec<u8> = Vec::new();
    for c in b"VK5DGR\r".iter().cycle().take(7 * 30) {
        let mut b = [0u8; MAX_BITS];
        let n = encode(*c, &mut b);
        text_bits.extend_from_slice(&b[..n]);
    }
    let (mut lcg, mut at) = (12345u32, 0usize);
    let mut x8: Vec<i16> = Vec::new();
    let mut frame = alloc::vec![0i16; spf];
    while x8.len() < seconds * 8_000 {
        let payload: Vec<u8> = (0..k)
            .map(|_| {
                lcg = lcg.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                (lcg >> 24) as u8 & 1
            })
            .collect();
        let mut bits = alloc::vec![0u8; ntxt];
        for b in bits.iter_mut() {
            *b = text_bits.get(at).copied().unwrap_or(0);
            at += 1;
        }
        tx.tx_bits(&payload, &bits, &mut frame);
        x8.extend_from_slice(&frame);
    }
    let mut x12 = Vec::new();
    Resampler::new_8k_to_12k().process(&x8, |s| x12.push(s));
    x12.truncate(x12.len() / 1_920 * 1_920);
    x12
}

/// The operator and the screen of a FreeDV self-test run.
pub trait FdvUi {
    /// What the operator did since the last call; `t_ms` is the time since the run started.
    fn poll(&mut self, t_ms: i64) -> Vec<tr_gui::fdv::FdvEvent>;
    /// Twice per simulated second: the screen's state.
    fn show(&mut self, state: &tr_gui::fdv::FdvScreenState);
}

/// An operator who switches the squelch off at 0.1 s and on again at 0.2 s, without a screen.
pub struct ScriptedFdvUi;

impl FdvUi for ScriptedFdvUi {
    fn poll(&mut self, t_ms: i64) -> Vec<tr_gui::fdv::FdvEvent> {
        match t_ms {
            100 | 200 => alloc::vec![tr_gui::fdv::FdvEvent::SquelchToggle],
            _ => Vec::new(),
        }
    }
    fn show(&mut self, _state: &tr_gui::fdv::FdvScreenState) {}
}

/// What a FreeDV run found.
#[derive(Clone, Debug, Default)]
pub struct FdvReport {
    /// Seconds of signal fed in.
    pub seconds: usize,
    /// The modem was in sync at the end.
    pub locked: bool,
    /// Modem frames received.
    pub frames: u32,
    /// Of those, frames without a valid codeword.
    pub frames_with_errors: u32,
    /// The text channel as decoded.
    pub text: alloc::string::String,
    /// Estimated SNR in 3 kHz, dB.
    pub snr_db: f32,
    /// Estimated frequency offset, Hz.
    pub foff_hz: f32,
    /// Audio ring run-dry events.
    pub underruns: u32,
    /// Speech queue overruns.
    pub overruns: u32,
    /// Back-end blocks lost.
    pub ring_lost: u32,
    /// Times the audio engine model found its ring empty.
    pub starved: u32,
    /// Stereo frames the engine model played.
    pub played: u64,
    /// Squelch setting at the end: on or off, and the level in dB.
    pub squelch_after: (bool, f32),
    /// Both TX enables were off at the end.
    pub tx_off: bool,
    /// Screen states produced.
    pub shows: u32,
}

impl FdvReport {
    /// True if every check of the run holds.
    pub fn pass(&self) -> bool {
        let frames_sent = (self.seconds * 1000 / 160) as u32;
        self.locked
            && self.frames * 10 >= frames_sent * 7
            && self.frames_with_errors <= 3
            && self.text.contains("VK5DGR")
            && self.underruns == 0
            && self.overruns == 0
            && self.ring_lost == 0
            && self.starved == 0
            && self.played as usize >= self.seconds * 48_000 * 7 / 10
            && self.squelch_after == (true, -2.0)
            && self.tx_off
            && self.shows > 5
    }
}

/// FreeDV receive through the whole station path on the simulated fabric: the signal goes into the
/// receiver audio ring as the back end would write it, `Radio::service` runs the chain, a model of
/// the audio engine plays the CPU ring at 48 ksps, the operator script runs through the station
/// logic, and the screen state is built twice a second. 700D, `seconds` of signal.
pub fn run_freedv(f: &MockFabric, seconds: usize, ui: &mut dyn FdvUi, out: &mut dyn Write) -> FdvReport {
    use tr_fabric::audio::AUDIO_RING_WORDS;
    use tr_fabric::backend::{BLOCK_BYTES, BLOCK_SAMPLES, HL2_PER_SAMPLE_12K};

    use crate::fdvstation::{apply, FdvAction, FdvStation};
    use crate::freedv::FdvMode;
    use crate::radio::Sideband;

    let mut rep = FdvReport { seconds, ..Default::default() };
    f.log_limit.set(1);
    let mut radio = Radio::new(f, f);
    let mut st = FdvStation::new();
    radio.enter_freedv(st.dial_hz(), Sideband::Upper, FdvMode::D700, st.squelch());
    let x12 = freedv_signal_12k(FdvMode::D700, seconds);
    let _ = writeln!(out, "FreeDV 700D, {} s of signal ({} samples at 12 kHz), dial {} Hz", seconds, x12.len(), st.dial_hz());

    let (mut pending, mut samples, mut wptr, mut rptr, mut played, mut starved, mut started) = (Vec::<i16>::new(), 0u64, 0u32, 0u32, 0u64, 0u32, false);
    let blocks = 1u32 << g::rx_backend::ring_slots::read(f, 0).log2();
    let mut t = 0i64;
    for chunk in x12.chunks(240) {
        for e in ui.poll(t) {
            for a in st.on_event(e) {
                if a != FdvAction::SwitchToFt8 {
                    apply(&mut radio, &a);
                }
            }
        }
        // the back end: whole blocks of 128 samples, stamped, into the ring
        pending.extend_from_slice(chunk);
        while pending.len() >= BLOCK_SAMPLES {
            let a = g::rx_backend::ring_base::read(f, 0) * 8 + (wptr % blocks) * BLOCK_BYTES;
            let stamp = INDEX0 + samples * HL2_PER_SAMPLE_12K;
            for k in 0..BLOCK_SAMPLES / 2 {
                f.poke_mem(a + 16 + 4 * k as u32, pending[2 * k] as u16 as u32 | (pending[2 * k + 1] as u16 as u32) << 16);
            }
            f.poke_mem(a, stamp as u32);
            f.poke_mem(a + 4, (stamp >> 32) as u32 & 0xFFFF);
            f.poke_mem(a + 8, wptr);
            f.poke_mem(a + 12, 0);
            pending.drain(..BLOCK_SAMPLES);
            samples += BLOCK_SAMPLES as u64;
            wptr += 1;
            f.poke(g::rx_backend::ring_wptr::addr(0), wptr);
        }
        radio.service();
        // the audio engine: 48 stereo frames per millisecond from the CPU ring
        let want = g::audio::ring_wptr::read(f);
        for _ in 0..48 * 20 {
            if rptr == want {
                if started {
                    starved += 1;
                }
                break;
            }
            let _ = f.mem(tr_fabric::mem::map::AUDIO_RING + (rptr % AUDIO_RING_WORDS) * 4);
            rptr = rptr.wrapping_add(1);
            played += 1;
            started = true;
        }
        f.poke(g::audio::ring_rptr::addr(), rptr);
        if t % 500 == 0 {
            rep.shows += 1;
            ui.show(&st.screen(&radio, "HL2: simulated", true));
        }
        t += 20;
    }
    let scr = st.screen(&radio, "", true);
    let fdv = radio.freedv().unwrap();
    rep.locked = scr.sync_level == 2;
    rep.frames = scr.frames;
    rep.frames_with_errors = scr.frames_with_errors;
    rep.text = scr.text.clone();
    rep.snr_db = scr.snr_db;
    rep.foff_hz = scr.foff_hz;
    rep.underruns = fdv.out.underruns;
    rep.overruns = fdv.rx.queue.overruns;
    rep.ring_lost = radio.ring_lost();
    rep.starved = starved;
    rep.played = played;
    rep.squelch_after = st.squelch();
    rep.tx_off = !g::tx::ctrl::read(f).enable() && !g::hl2_link::tx_ctrl::read(f).enable() && !radio.tx.is_armed();
    let _ = writeln!(
        out,
        "FreeDV: {} frames ({} without codeword), {}, SNR {:.1} dB, offset {:+.1} Hz, text {:?}, played {} frames, ring underruns {}, queue overruns {}, blocks lost {}, engine starved {}, TX off {}",
        rep.frames,
        rep.frames_with_errors,
        scr.sync_text(),
        rep.snr_db,
        rep.foff_hz,
        rep.text,
        rep.played,
        rep.underruns,
        rep.overruns,
        rep.ring_lost,
        rep.starved,
        rep.tx_off
    );
    let _ = writeln!(out, "FreeDV self-test {}", if rep.pass() { "PASS" } else { "FAIL" });
    rep
}
