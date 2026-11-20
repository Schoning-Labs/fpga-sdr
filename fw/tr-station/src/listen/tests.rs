// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Host tests of the LISTEN station: frequency and oscillator arithmetic, band defaults and memory,
//! filter presets designed through `tr_dsp::backend::design`, the receiver set-up and the audio chain
//! against the mock fabric, and the keys.

use super::*;
use tr_dsp::backend::design::{bandpass, dequantize, quantize, response};
use tr_fabric::mock::MockFabric;
use tr_regs::generated::{audio as au, rx_backend as bk, rx_bank as rb};

#[test]
fn oscillator_follows_the_tuned_frequency_and_the_mode() {
    let mut st = ListenStation::new();
    assert_eq!((st.freq_hz(), st.mode(), st.nco_hz(), st.step_hz()), (14_200_000, ListenMode::Usb, 14_200_000, 100));
    assert_eq!(st.on_event(ListenEvent::Mode(ListenMode::Cw)), Changes { freq: true, mode: true, filter: true, agc: true, ..Default::default() });
    // CW: the oscillator 600 Hz below the carrier; the 500 Hz filter around the 600 Hz pitch; in radio
    // frequency the pass band sits on the carrier
    assert_eq!(st.nco_hz(), 14_199_400);
    assert_eq!(st.filter_edges(), (350, 850));
    assert_eq!(st.passband(), (-250, 250));
    st.on_event(ListenEvent::Mode(ListenMode::Lsb));
    assert_eq!((st.nco_hz(), st.filter_edges(), st.passband()), (14_200_000, (-2_700, -300), (-2_700, -300)));
    st.on_event(ListenEvent::Mode(ListenMode::Am));
    assert_eq!(st.filter_edges(), (-3_000, 3_000));
    assert_eq!(st.on_event(ListenEvent::Filter(1)), Changes { filter: true, ..Default::default() });
    assert_eq!(st.filter_edges(), (-4_500, 4_500));
    st.on_event(ListenEvent::Mode(ListenMode::Fm));
    assert_eq!((st.filter_edges(), st.agc_on()), ((-6_000, 6_000), false), "FM: 12 kHz, fixed gain");
    assert_eq!(st.on_event(ListenEvent::AgcToggle), Changes::default(), "no AGC switch in FM");
    st.on_event(ListenEvent::Mode(ListenMode::Am));
    assert_eq!(st.filter_index(), 1, "each mode keeps its filter");
    assert!(st.agc_on());
    // every preset of every mode stays inside the back end's +/-9.6 kHz (docs/R4_BACKEND.md 9)
    for m in ListenMode::ALL {
        for w in filter_presets(m) {
            let (lo, hi) = filter_edges(m, *w);
            assert!(-9_600 <= lo && lo < hi && hi <= 9_600, "{m:?} {w}");
            assert_eq!((hi - lo) as u32, *w, "{m:?} {w}");
        }
    }
}

#[test]
fn tuning_steps_digits_and_range() {
    assert_eq!(step_tune(7_074_050, 100, 1), 7_074_100);
    assert_eq!(step_tune(7_074_050, 100, -1), 7_074_000);
    assert_eq!(step_tune(7_074_000, 100, -1), 7_073_900);
    assert_eq!(step_tune(1_000_000, 9_000, 1), 1_008_000, "onto the 9 kHz grid of medium wave");
    assert_eq!(step_tune(145_000, 12_500, -3), 112_500);
    assert_eq!(step_tune(150_000, 100_000, -1), MIN_HZ);
    assert_eq!(step_tune(29_900_000, 1_000_000, 1), MAX_HZ);
    let mut st = ListenStation::new();
    st.on_event(ListenEvent::TuneDigit { place: 3, dir: 1 });
    st.on_event(ListenEvent::TuneDigit { place: 0, dir: -1 });
    assert_eq!(st.freq_hz(), 14_200_999);
    assert_eq!(st.on_event(ListenEvent::TuneSteps(1)), Changes { freq: true, ..Default::default() });
    assert_eq!(st.freq_hz(), 14_201_000);
    st.on_event(ListenEvent::Step(8));
    st.on_event(ListenEvent::StepChange(1));
    assert_eq!(st.step_hz(), 1_000_000, "the largest step stays");
    st.on_event(ListenEvent::StepChange(-2));
    assert_eq!(st.step_hz(), 12_500);
    st.on_event(ListenEvent::TuneHz(-40_000_000));
    assert_eq!(st.freq_hz(), MIN_HZ);
    assert_eq!(st.on_event(ListenEvent::TuneSteps(-1)), Changes::default(), "nothing below 100 kHz");
    st.on_event(ListenEvent::TuneDigit { place: 7, dir: 1 });
    st.on_event(ListenEvent::TuneDigit { place: 7, dir: 1 });
    st.on_event(ListenEvent::TuneDigit { place: 7, dir: 1 });
    assert_eq!(st.freq_hz(), MAX_HZ);
    // a click on the waterfall: 6.25 Hz per pixel in USB, to 10 Hz
    let mut st = ListenStation::new();
    st.on_event(ListenEvent::WaterfallClick(586 + 160));
    assert_eq!(st.freq_hz(), 14_201_000);
    st.on_event(ListenEvent::WaterfallClick(586 - 3));
    assert_eq!(st.freq_hz(), 14_200_980);
    // AM: 25 Hz per pixel, onto the step's grid
    st.on_event(ListenEvent::Mode(ListenMode::Am));
    st.on_event(ListenEvent::Step(3));
    st.on_event(ListenEvent::WaterfallClick(586 + 205));
    assert_eq!(st.freq_hz(), 14_205_000);
    // no zoom receiver: a click does nothing
    st.zoom = false;
    assert_eq!(st.on_event(ListenEvent::WaterfallClick(100)), Changes::default());
}

#[test]
fn bands_default_modes_and_memory() {
    assert_eq!(band_of(7_074_000), 3);
    assert_eq!(band_of(5_357_000), 2);
    assert_eq!(band_of(9_650_000), GENERAL);
    assert_eq!(band_of(153_000), GENERAL);
    assert_eq!(default_sideband(3_700_000), ListenMode::Lsb);
    assert_eq!(default_sideband(5_357_000), ListenMode::Usb, "60 m is USB");
    assert_eq!(default_sideband(7_150_000), ListenMode::Lsb);
    assert_eq!(default_sideband(14_200_000), ListenMode::Usb);
    for b in &BANDS[..GENERAL] {
        assert!(b.low_hz <= b.default_hz && b.default_hz <= b.high_hz, "{}", b.name);
        if b.default_mode != ListenMode::Cw {
            assert_eq!(b.default_mode, default_sideband(b.default_hz), "{}", b.name);
        }
    }
    let mut st = ListenStation::new();
    assert_eq!(st.band_index(), 5);
    st.on_event(ListenEvent::BandSelect(3));
    assert_eq!((st.freq_hz(), st.mode(), st.band_index()), (7_150_000, ListenMode::Lsb, 3));
    st.on_event(ListenEvent::TuneHz(-76_000));
    st.on_event(ListenEvent::Mode(ListenMode::Cw));
    st.on_event(ListenEvent::BandSelect(10));
    assert_eq!((st.freq_hz(), st.mode()), (9_650_000, ListenMode::Am), "general: a broadcast frequency, AM");
    st.on_event(ListenEvent::BandStep(-1));
    assert_eq!((st.freq_hz(), st.mode()), (28_500_000, ListenMode::Usb));
    st.on_event(ListenEvent::BandSelect(3));
    assert_eq!((st.freq_hz(), st.mode()), (7_074_000, ListenMode::Cw), "40 m remembered");
    st.on_event(ListenEvent::BandSelect(5));
    assert_eq!((st.freq_hz(), st.mode()), (14_200_000, ListenMode::Usb), "20 m remembered from the start");
    assert_eq!(st.on_event(ListenEvent::BandStep(10)), Changes::default());
}

/// Each preset through the firmware's stack-light designer: bit for bit the design of
/// `tr_dsp::backend::design::quantize(bandpass(..))`, and its response in the pass band and outside.
#[test]
fn filter_presets_through_the_back_end_designer() {
    let mut scratch = vec![0.0f64; 2 * MAX_TAPS];
    for m in ListenMode::ALL {
        for &w in filter_presets(m) {
            let (lo, hi) = filter_edges(m, w);
            let mut re = vec![0i32; FILTER_TAPS];
            let mut im = vec![0i32; FILTER_TAPS];
            let (n, exp) = bandpass_quantized_into(FILTER_FS, lo as f64, hi as f64, FILTER_TAPS, &mut re, &mut im, &mut scratch);
            let bank = quantize(&bandpass(FILTER_FS, lo as f64, hi as f64, FILTER_TAPS));
            assert_eq!((n, exp), (bank.ntaps, bank.exp), "{m:?} {w}");
            assert_eq!(&re[..], &bank.re[..FILTER_TAPS], "{m:?} {w}");
            assert_eq!(&im[..], &bank.im[..FILTER_TAPS], "{m:?} {w}");
            let d = dequantize(&bank);
            let db = |f: f64| 20.0 * response(&d, f, FILTER_FS).log10();
            let mid = (lo + hi) as f64 / 2.0;
            assert!(db(mid).abs() < 0.1, "{m:?} {w}: {:.2} dB in the middle", db(mid));
            // 300 Hz outside either edge: down by 60 dB or more
            for f in [lo as f64 - 300.0, hi as f64 + 300.0] {
                assert!(db(f) < -60.0, "{m:?} {w}: {:.1} dB at {f} Hz", db(f));
            }
            if matches!(m, ListenMode::Usb | ListenMode::Lsb) {
                // the opposite sideband, 500 to 2,500 Hz on the other side of the carrier
                for f in [500.0, 1_500.0, 2_500.0] {
                    let f = if m == ListenMode::Usb { -f } else { f };
                    assert!(db(f) < -100.0, "{m:?} {w}: opposite sideband {:.1} dB at {f} Hz", db(f));
                }
            }
        }
    }
}

/// A block of a `hz` tone at 12 ksps, `amp` peak, into receiver 1's ring slot `seq`.
fn put_tone_block(f: &MockFabric, seq: u32, hz: f64, amp: f64) {
    let blocks = 1u32 << RING_LOG2;
    let a = map::backend_ring(RX) + (seq % blocks) * tr_fabric::backend::BLOCK_BYTES;
    f.poke_mem(a, seq * 128);
    f.poke_mem(a + 8, seq);
    f.poke_mem(a + 12, (-60i16 * 64) as u16 as u32);
    let s = |k: u32| (amp * (core::f64::consts::TAU * hz * (seq * 128 + k) as f64 / 12_000.0).sin()).round() as i16 as u16 as u32;
    for k in 0..64u32 {
        f.poke_mem(a + 16 + 4 * k, s(2 * k) | (s(2 * k + 1) << 16));
    }
}

/// The left channel of the audio ring's frames `from..to`.
fn audio_left(f: &MockFabric, from: u32, to: u32) -> Vec<i16> {
    (from..to).map(|i| (f.mem(map::AUDIO_RING + (i % 4_096) * 4) >> 16) as u16 as i16).collect()
}

#[test]
fn receiver_set_up_on_receiver_1_with_its_own_banks() {
    let f = MockFabric::new();
    f.log_limit.set(1);
    let mut st = ListenStation::new();
    st.on_event(ListenEvent::BandSelect(3)); // 7.150 MHz LSB
    let mut r = ListenRadio::start(&f, &f, &st);
    // receiver 1 at 48 ksps on the oscillator; FT8's receiver 0 untouched
    assert_eq!(f.reg(rb::phase_inc::addr(RX)), tr_fabric::phase_inc(7_150_000));
    assert_eq!(f.reg(rb::ctrl::addr(RX)) & 1, 1);
    assert_eq!(f.reg(rb::phase_inc::addr(0)), 0);
    assert_eq!(f.reg(bk::ctrl::addr(0)), 0, "receiver 0's back end is not written");
    // back end: enabled, SSB, 48 ksps in, AGC on, bank 1; the filter in unit 0 bank 1, 1,023 taps
    let ctrl = f.reg(bk::ctrl::addr(RX));
    assert_eq!(ctrl & 1, 1);
    assert_eq!((ctrl >> 1) & 7, Demod::Ssb as u32);
    assert_eq!((ctrl >> 11) & 1, 1);
    assert_eq!((ctrl >> 13) & 7, BANKS[0]);
    assert_eq!(f.reg(bk::bank_cfg::addr(BANKS[0])) & 0x7FF, FILTER_TAPS as u32);
    assert_eq!(f.reg(bk::ring_base::addr(RX)), map::backend_ring(RX) / 8);
    // audio engine on, every output, volume register full (the volume is applied in software)
    assert_eq!(f.reg(au::ctrl::addr()), 1);
    assert_eq!(f.reg(au::out_ctrl::addr()), 0b011);
    assert_eq!(f.reg(au::volume::addr()), 255);
    assert_eq!(r.designs, 1);

    // a new filter goes into the other bank, and the receiver switches to it without a restart
    let enables = f.reg_writes(bk::ctrl::addr(RX)).len();
    let c = st.on_event(ListenEvent::Filter(1));
    r.apply(&st, &c);
    assert_eq!((f.reg(bk::ctrl::addr(RX)) >> 13) & 7, BANKS[1]);
    assert_eq!(r.bank(), BANKS[1]);
    assert!(f.reg_writes(bk::ctrl::addr(RX)).iter().skip(enables).all(|v| v & 1 == 1), "never disabled");
    // the logic still runs bank 2 (bank_cur): the next filter has to wait for bank 1 to come free
    f.poke(bk::rx_status::addr(RX), BANKS[0] << 17);
    let c = st.on_event(ListenEvent::Filter(0));
    r.apply(&st, &c);
    assert!(r.filter_pending());
    assert_eq!(r.bank(), BANKS[1]);
    f.poke(bk::rx_status::addr(RX), BANKS[1] << 17);
    r.service(1_000);
    assert!(!r.filter_pending());
    assert_eq!(r.bank(), BANKS[0]);
    assert_eq!(r.designs, 2, "the first filter came from the cache");

    // tuning moves only the oscillator
    let c = st.on_event(ListenEvent::TuneSteps(5));
    r.apply(&st, &c);
    assert_eq!(f.reg(rb::phase_inc::addr(RX)), tr_fabric::phase_inc(7_150_500));
    // AM: the back end restarts with the AM demodulator
    let c = st.on_event(ListenEvent::Mode(ListenMode::Am));
    f.clear_log();
    f.log_limit.set(0);
    r.apply(&st, &c);
    let w = f.reg_writes(bk::ctrl::addr(RX));
    assert!(w.iter().any(|v| v & 1 == 0) && w.last().unwrap() & 1 == 1, "stopped and started again");
    assert_eq!((f.reg(bk::ctrl::addr(RX)) >> 1) & 7, Demod::Am as u32);
    // AGC off holds the gain the AGC had: -1,000 in S.10 is -4,000 in S7.12
    f.poke(bk::agc_gain::addr(RX), (-1_000i32 as u32) & 0x3_FFFF);
    let c = st.on_event(ListenEvent::AgcToggle);
    r.apply(&st, &c);
    assert_eq!(f.reg(bk::agc_manual::addr(RX)), (-4_000i32 as u32) & 0xF_FFFF);
    assert_eq!((f.reg(bk::ctrl::addr(RX)) >> 11) & 1, 0);
    // squelch at -90 dBFS: opens above -112.3 dB of the register's scale, closes 3 dB lower
    let c = st.on_event(ListenEvent::SquelchToggle);
    r.apply(&st, &c);
    assert_eq!((f.reg(bk::ctrl::addr(RX)) >> 12) & 1, 1);
    let sq = f.reg(bk::squelch::addr(RX));
    assert_eq!((sq & 0xFFFF) as u16 as i16, (-112.3f32 * 64.0) as i16);
    assert_eq!((sq >> 16) as u16 as i16, (-115.3f32 * 64.0) as i16);
    // FM: de-emphasis and the fixed gain
    let c = st.on_event(ListenEvent::Mode(ListenMode::Fm));
    r.apply(&st, &c);
    assert_eq!(f.reg(bk::fm_deemph::addr(RX)), FM_DEEMPH_ALPHA);
    assert_eq!(f.reg(bk::agc_manual::addr(RX)), FM_GAIN_S7_12 as u32);
    assert_eq!((f.reg(bk::ctrl::addr(RX)) >> 1) & 7, Demod::Fm as u32);
    // S-meter in dBFS: the register's -60 dB is -37.7 dBFS
    f.poke(bk::rx_status::addr(RX), (-60i16 * 64) as u16 as u32);
    assert!((r.smeter_dbfs() + 37.7).abs() < 0.01);
    r.stop();
    assert_eq!(f.reg(bk::ctrl::addr(RX)) & 1, 0);
    assert_eq!(f.reg(au::ctrl::addr()), 0);
}

#[test]
fn audio_chain_resamples_scales_counts_underruns_and_holds_the_latency() {
    let f = MockFabric::new();
    f.log_limit.set(1);
    let st = ListenStation::new(); // volume 50 %: gain 0.5
    let mut r = ListenRadio::start(&f, &f, &st);
    // two blocks: below the 3 that start playing
    for s in 0..2 {
        put_tone_block(&f, s, 1_000.0, 10_000.0);
    }
    f.poke(bk::ring_wptr::addr(RX), 2);
    r.service(0);
    assert_eq!(r.frames_out, 0);
    for s in 2..6 {
        put_tone_block(&f, s, 1_000.0, 10_000.0);
    }
    f.poke(bk::ring_wptr::addr(RX), 6);
    r.service(10_000);
    assert_eq!(r.frames_out, 6 * 512);
    assert_eq!(f.reg(au::ring_wptr::addr()), 6 * 512);
    // a 1 kHz tone at 48 kHz, peak 5,000 (half of 10,000), past the interpolator's start
    let a = audio_left(&f, 1_000, 3_000);
    let peak = a.iter().map(|v| v.unsigned_abs()).max().unwrap();
    assert!((4_850..=5_150).contains(&peak), "peak {peak}");
    let crossings = a.windows(2).filter(|w| w[0] < 0 && w[1] >= 0).count();
    assert!((41..=42).contains(&crossings), "{crossings} rising zero crossings in 2,000 frames");
    // the engine plays everything and finds the ring empty: one underrun, then the prefill again
    f.poke(au::ring_rptr::addr(), 6 * 512);
    r.service(20_000);
    assert_eq!(r.underruns, 1);
    assert_eq!(r.frames_out, 6 * 512);
    // a long stall: 40 blocks wait; 8 fit the empty audio ring, 2 stay, 30 are dropped
    for s in 6..46 {
        put_tone_block(&f, s, 1_000.0, 10_000.0);
    }
    f.poke(bk::ring_wptr::addr(RX), 46);
    r.service(500_000);
    assert_eq!(r.skipped_blocks, 30);
    assert_eq!(r.frames_out, (6 + 8) * 512);
    assert_eq!(r.audio_fill_ms(), 85);
    assert_eq!(r.ring_lost(), 0);
    // the console line: the longest gap between services was the stall, 480 ms
    let line = r.status_line(&st, 123);
    assert!(line.starts_with("LISTEN 14.200.000 Hz USB 2.4 kHz, S-meter "), "{line}");
    assert!(line.contains("underruns 1") && line.contains("dropped 30") && line.contains("longest service gap 480 ms") && line.contains("longest pass 123 ms"), "{line}");
    assert!(line.contains("audio peak -16."), "peak 5,000 of 32,768 is -16.3 dBFS: {line}");
    // volume 0: silence
    let mut st = st;
    let c = st.on_event(ListenEvent::VolumeStep(-100));
    r.apply(&st, &c);
    f.poke(au::ring_rptr::addr(), (14 * 512) - 100);
    put_tone_block(&f, 46, 1_000.0, 10_000.0);
    f.poke(bk::ring_wptr::addr(RX), 47);
    let before = r.frames_out as u32;
    r.service(510_000);
    assert!(audio_left(&f, before, r.frames_out as u32).iter().all(|v| *v == 0));
    // the screen's audio line
    let s = st.screen(Some(&r), "HL2", true);
    assert!(!s.audio_ok);
    assert!(s.audio_text.contains("underruns 1"), "{}", s.audio_text);
}

#[test]
fn keys_are_receive_only_and_never_on_the_transmit_list() {
    use tr_input::code;
    let mut mapped = 0;
    for key in 0..=255u8 {
        if let Some(e) = event_for(key) {
            mapped += 1;
            assert!(!tr_input::is_tx_char(key), "key {key:#04x} gives {e:?} but is on the network's transmit list");
        }
    }
    assert_eq!(mapped, 32);
    assert_eq!(event_for(b'e'), Some(ListenEvent::WfSensitivityStep(1)));
    assert_eq!(event_for(b'd'), Some(ListenEvent::WfSensitivityStep(-1)));
    assert_eq!(event_for(b'r'), Some(ListenEvent::WfRangeStep(1)));
    assert_eq!(event_for(b'v'), Some(ListenEvent::WfRangeStep(-1)));
    assert_eq!(event_for(b'x'), Some(ListenEvent::WfSpeedStep(1)));
    assert_eq!(event_for(b'z'), Some(ListenEvent::WfSpeedStep(-1)));
    assert_eq!(event_for(code::LEFT), Some(ListenEvent::TuneSteps(-1)));
    assert_eq!(event_for(code::RIGHT), Some(ListenEvent::TuneSteps(1)));
    assert_eq!(event_for(code::UP), Some(ListenEvent::VolumeStep(5)));
    assert_eq!(event_for(code::PAGE_DOWN), Some(ListenEvent::TuneHz(-100_000)));
    assert_eq!(event_for(code::SHIFT_UP), Some(ListenEvent::SquelchStep(2)));
    assert_eq!(event_for(b'k'), Some(ListenEvent::Mode(ListenMode::Usb)));
    assert_eq!(event_for(b'g'), Some(ListenEvent::Mode(ListenMode::Sam)));
    assert_eq!(event_for(b'm'), Some(ListenEvent::SwitchToFt8));
    for k in b"tcsu0123456789-+=" {
        assert_eq!(event_for(*k), None);
    }
    // the letters' keys pass the network's key check on both layouts
    for usage in [0x0Fu8, 0x0E, 0x1A, 0x04, 0x0A, 0x09, 0x05, 0x12, 0x14, 0x36, 0x37, 0x10, 0x2F, 0x08, 0x07, 0x15, 0x19] {
        assert!(!tr_input::is_tx_key(usage), "{usage:#04x}");
    }
    assert!(tr_input::is_tx_key(0x30), "] is '+' on a German keyboard: from the network, End steps the band up instead");
}

#[test]
fn screen_state_from_the_station() {
    let mut st = ListenStation::new();
    st.on_event(ListenEvent::Mode(ListenMode::Cw));
    let s = st.screen::<MockFabric, MockFabric>(None, "HL2: no link", false);
    assert_eq!(s.filter_names, ["500 Hz", "250 Hz", "800 Hz"]);
    assert_eq!(s.passband, (-250, 250));
    assert_eq!(s.band_names.len(), 11);
    assert_eq!(s.info_text, "receiver 1, oscillator 14.199.400 Hz, filter +350 to +850 Hz, AGC on");
    st.zoom = false;
    assert!(!st.screen::<MockFabric, MockFabric>(None, "", false).axis.waterfall);
    // the waterfall's sensitivity (+ = brighter = the floor lower) and contrast (range)
    assert_eq!((s.wf_sensitivity_db, s.wf_range_db), (0, 60));
    let c = st.on_event(ListenEvent::WfSensitivityStep(1));
    assert!(c.waterfall && !c.any_radio() && !c.speed);
    st.on_event(ListenEvent::WfRangeStep(-1));
    st.on_event(ListenEvent::WfRangeStep(-1));
    assert_eq!(st.waterfall_scale(), (-3, 40), "more sensitive: the floor 3 dB lower");
    let s = st.screen::<MockFabric, MockFabric>(None, "", false);
    assert_eq!((s.wf_sensitivity_db, s.wf_sensitivity_text(), s.wf_range_text()), (3, String::from("+3 dB"), String::from("40 dB")));
    st.on_event(ListenEvent::WfSensitivityStep(-1));
    st.on_event(ListenEvent::WfSensitivityStep(-1));
    let s = st.screen::<MockFabric, MockFabric>(None, "", false);
    assert_eq!((s.wf_sensitivity_db, s.wf_sensitivity_text()), (-3, String::from("-3 dB")));
    let c = st.on_event(ListenEvent::WfSensitivityAuto);
    assert!(c.waterfall);
    let s = st.screen::<MockFabric, MockFabric>(None, "", false);
    assert_eq!((s.wf_sensitivity_db, s.wf_sensitivity_text()), (0, String::from("0 dB")));
    assert_eq!(st.waterfall_scale().0, 0);
    for _ in 0..20 {
        st.on_event(ListenEvent::WfSensitivityStep(1));
        st.on_event(ListenEvent::WfRangeStep(1));
    }
    assert_eq!(st.waterfall_scale(), (-30, 120));
    for _ in 0..20 {
        st.on_event(ListenEvent::WfSensitivityStep(-1));
    }
    assert_eq!(st.waterfall_scale().0, 30);
}

#[test]
fn waterfall_speed_presets_are_clamped_to_what_the_span_gives() {
    use tr_fabric::zoom::Span;
    let (s12, s24) = (zoom_span(ListenMode::Usb), zoom_span(ListenMode::Am));
    assert_eq!((s12.hz(), s24.hz()), (12_000, 24_000));
    // (frames per line, preset): 12 kHz gives 3.66 transforms per second, 24 kHz 7.32
    assert_eq!(speed_choices(s12), [(4, 1), (2, 2), (1, 5)]);
    assert_eq!(speed_choices(s24), [(7, 1), (4, 2), (2, 5), (1, 10)]);
    // a span of 48 kHz (14.6 per second) would give all five
    assert_eq!(speed_choices(Span::K48).len(), 5);
    assert_eq!(ZOOM_LINES_PER_S, 7);
    assert_eq!((speed_k(s12, 7), speed_k(s24, 7)), (1, 1), "the start value is every transform at both spans, as before");
    let mut st = ListenStation::new();
    st.on_event(ListenEvent::Mode(ListenMode::Usb));
    let screen = |st: &ListenStation| st.screen::<MockFabric, MockFabric>(None, "", false);
    assert_eq!((screen(&st).wf_speed_x10, screen(&st).wf_speed_text()), (37, String::from("3.7 /s")));
    // already the fastest: + does nothing, and says nothing changed
    assert!(!st.on_event(ListenEvent::WfSpeedStep(1)).speed);
    let c = st.on_event(ListenEvent::WfSpeedStep(-1));
    assert!(c.speed && !c.waterfall && !c.any_radio());
    assert_eq!((st.waterfall_speed(), screen(&st).wf_speed_text()), (2, String::from("1.8 /s")));
    assert!(st.on_event(ListenEvent::WfSpeedStep(-1)).speed);
    assert_eq!((st.waterfall_speed(), screen(&st).wf_speed_x10, screen(&st).wf_speed_text()), (1, 9, String::from("0.9 /s")));
    assert!(!st.on_event(ListenEvent::WfSpeedStep(-1)).speed, "the slowest");
    // the preset stays when the mode (and the span) changes
    st.on_event(ListenEvent::Mode(ListenMode::Am));
    assert_eq!((st.waterfall_speed(), screen(&st).wf_speed_text()), (1, String::from("1 /s")));
    for (steps, want) in [(1, "1.8 /s"), (1, "3.7 /s"), (1, "7.3 /s")] {
        assert!(st.on_event(ListenEvent::WfSpeedStep(steps)).speed);
        assert_eq!(screen(&st).wf_speed_text(), want);
    }
    assert!(!st.on_event(ListenEvent::WfSpeedStep(1)).speed);
    // 10 per second asked for at 12 kHz is every transform
    st.on_event(ListenEvent::Mode(ListenMode::Usb));
    assert_eq!(screen(&st).wf_speed_text(), "3.7 /s");
}

#[test]
fn waterfall_on_the_zoom_receiver_centred_on_the_tuned_frequency() {
    use tr_gui::ft8::WATERFALL_RECT;
    use tr_regs::generated::{video as vid, zoom as zm};
    let f = MockFabric::new();
    f.log_limit.set(1);
    f.poke(zm::id::addr(), zm::id::RESET);
    let mut radio = crate::radio::Radio::new(&f, &f);
    radio.start_receive(14_074_000);
    assert!(radio.start_display_listen(WATERFALL_RECT, 7_150_000, zoom_span(ListenMode::Lsb)).unwrap());
    assert_eq!(f.reg(zm::phase_inc::addr()), tr_fabric::phase_inc(7_150_000));
    // 12 kHz span (span_shift 6, narrow_shift 2), gain 64, enabled; the middle 1,172 columns in the window
    assert_eq!(f.reg(zm::ctrl::addr()), (3 << 9) | (2 << 6) | (6 << 1) | 1);
    // the color level of crate::wflevel: 60 dB over the palette, the noise floor (first guess 0 dB) at index 32
    assert_eq!(f.reg(zm::backend_level::addr()), (1_092 << 16) | 480);
    assert_eq!(f.reg(vid::win_src::addr(0)), (1_920 - 1_172) / 2);
    assert_eq!(f.reg(vid::wf_win_ctrl::addr(0)), 1);
    radio.set_listen_zoom_centre(7_151_000);
    assert_eq!(f.reg(zm::phase_inc::addr()), tr_fabric::phase_inc(7_151_000));
    // the FT8 receiver stays on its dial
    assert_eq!(f.reg(rb::phase_inc::addr(0)), tr_fabric::phase_inc(14_074_000));
    // AM: 24 kHz span (narrow_shift 1), gain 64
    radio.start_display_listen(WATERFALL_RECT, 9_650_000, zoom_span(ListenMode::Am)).unwrap();
    assert_eq!(f.reg(zm::ctrl::addr()), (3 << 9) | (1 << 6) | (6 << 1) | 1);
    assert_eq!(zoom_span(ListenMode::Fm).hz(), 24_000);
    // without the zoom receiver: no window
    let f = MockFabric::new();
    f.log_limit.set(1);
    let mut radio = crate::radio::Radio::new(&f, &f);
    assert!(!radio.start_display_listen(WATERFALL_RECT, 7_150_000, zoom_span(ListenMode::Lsb)).unwrap());
    assert_eq!(f.reg(vid::win_ctrl::addr(0)) & 1, 0);
}

#[test]
fn rf_gain_buttons_are_reported_and_touch_nothing_else() {
    let mut st = ListenStation::new();
    let c = st.on_event(ListenEvent::RfGainStep(5));
    assert_eq!((c.rf_gain_step, c.rf_agc_toggle, c.any_radio()), (1, false, false));
    let c = st.on_event(ListenEvent::RfGainStep(-1));
    assert_eq!(c.rf_gain_step, -1);
    let c = st.on_event(ListenEvent::RfAgcToggle);
    assert_eq!((c.rf_gain_step, c.rf_agc_toggle, c.any_radio()), (0, true, false));
    assert_eq!(st.freq_hz(), 14_200_000);
}
