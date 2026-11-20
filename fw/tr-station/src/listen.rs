// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The LISTEN station (docs/LISTEN.md): general receive in LSB, USB, CW, AM, synchronous AM and FM
//! with free tuning from 100 kHz to 30 MHz. Receive only: nothing here arms, keys or feeds the
//! transmitter; the HL2 only hears about the band filter.
//!
//! Two parts, as with FT8 ([`crate::station`] and [`crate::radio`]):
//!
//! - [`ListenStation`]: what the operator chose (frequency, mode, filter, step, AGC, squelch,
//!   volume, the memory of each band) and the screen's state. No hardware; host-tested.
//! - [`ListenRadio`]: the receiver and the audio behind it, on the `tr-fabric` drivers.
//!
//! **Receiver.** Bank receiver [`RX`] (1; FT8 keeps receiver 0 and its bank 0) at 48 ksps, its
//! oscillator on the tuned frequency (CW: [`CW_PITCH_HZ`] below it, so that the carrier is heard
//! as a 600 Hz tone). The HL2 is not tuned: its raw stream at 76.8 Msps carries 0 to 38.4 MHz, and
//! the receiver's oscillator (32-bit phase step, 0.018 Hz) picks any frequency in it. The back end
//! ([`tr_fabric::backend`]) filters with a 1,023-tap complex channel filter at 24 ksps designed here
//! ([`tr_dsp::backend::design`]), demodulates (SSB/CW: the real part; AM; SAM; FM), applies the AGC
//! and the squelch, and writes 12 ksps audio into its DDR3 ring.
//!
//! **Filter banks.** Filter unit 0 serves receivers 0 to 3 and has 6 banks. FT8 uses bank 0; LISTEN
//! uses [`BANKS`] (1 and 2) in turn: a new filter goes into the bank the receiver does not use, then
//! the receiver switches to it between two samples. Banks 3 to 5 stay free for receivers 2 and 3.
//!
//! **Audio.** Ring blocks (128 samples at 12 ksps) -> 4x interpolation to 48 kHz
//! ([`tr_freedv::resample::Resampler`], 24 taps per phase) -> volume (in software: the chip's
//! volume register reaches no output, docs/AUDIO_OUT.md) -> the audio engine's ring (4,096 frames,
//! 85 ms; its size is fixed in the logic) -> headphone DAC (PT8211), S/PDIF, I2S and HDMI.
//! [`ListenRadio::service`] tops the ring up with whole blocks; the firmware calls it from the main
//! loop, from the yield hook of long jobs and from inside the screen drawing. It counts the times
//! the ring ran dry (underruns) and the longest time between two calls. Latency is held near the
//! ring's 85 ms: after a stall the blocks that no longer fit are dropped (counted), not played late.

use alloc::boxed::Box;
use alloc::format;
use alloc::string::String;
use alloc::vec;
use alloc::vec::Vec;

use tr_dsp::backend::design::{bandpass_quantized_into, FS as FILTER_FS};
use tr_dsp::backend::MAX_TAPS;
use tr_fabric::audio::{stereo_word, AudioOut};
use tr_fabric::backend::{Backend, BackendRing, Demod, RxSetup, BLOCK_SAMPLES};
use tr_fabric::mem::{map, FabricMem};
use tr_fabric::rxbank::{Rate, RxBank};
use tr_fabric::zoom::Span;
use tr_freedv::resample::Resampler;
use tr_gui::listen::{ListenAxis, ListenEvent, ListenMode, ListenScreenState, STEPS_HZ};
use tr_regs::RegisterSpace;

/// The LISTEN receiver (bank receiver and back-end receiver).
pub const RX: u32 = 1;
/// Filter unit of receivers 0 to 3.
pub const UNIT: u32 = 0;
/// The two coefficient banks LISTEN uses in turn (FT8 has bank 0).
pub const BANKS: [u32; 2] = [1, 2];
/// Taps of the channel filter at 24 ksps (21 ms delay).
pub const FILTER_TAPS: usize = 1_023;
/// Back-end ring: 2^9 blocks of 128 samples, 5.5 s at 12 ksps.
pub const RING_LOG2: u32 = 9;
/// CW: the carrier is heard at this audio frequency.
pub const CW_PITCH_HZ: i32 = 600;
/// Lowest tuning frequency, Hz.
pub const MIN_HZ: u32 = 100_000;
/// Highest tuning frequency, Hz.
pub const MAX_HZ: u32 = 30_000_000;
/// Tuning step of Page Up and Page Down, Hz.
pub const BIG_STEP_HZ: i32 = 100_000;
/// Lowest squelch level, dBFS.
pub const SQUELCH_MIN_DB: f32 = -140.0;
/// Highest squelch level, dBFS.
pub const SQUELCH_MAX_DB: f32 = -20.0;
/// The squelch closes this many dB below the level it opens at.
pub const SQUELCH_HYSTERESIS_DB: f32 = 3.0;
/// The S-meter register reads -22.3 dB for a full-scale ADC sine (docs/R4_BACKEND.md 3.6, input
/// shift 6); adding this gives dB relative to the ADC's full scale (dBFS).
pub const SMETER_TO_DBFS_DB: f32 = 22.3;
/// 48 kHz frames per ring block.
pub const FRAMES_PER_BLOCK: u32 = (BLOCK_SAMPLES * 4) as u32;
/// Blocks queued in the back-end ring before playing starts (and again after an underrun): 32 ms.
pub const PREFILL_BLOCKS: u32 = 3;
/// Blocks left in the back-end ring beyond what the audio ring takes; older ones are dropped.
pub const MAX_BACKLOG_BLOCKS: u32 = 2;
/// FM: de-emphasis time constant 530 us (6 dB per octave above 300 Hz) at 24 ksps, U0.17, and the
/// fixed gain that makes up for it (+12 dB, log2 S7.12). FM never uses the AGC.
pub const FM_DEEMPH_ALPHA: u32 = 9_909;
/// The fixed FM gain in the back end's S7.12 format (2.0 = +12 dB).
pub const FM_GAIN_S7_12: i32 = 2 * 4_096;
/// Zoom receiver waterfall lines per second asked for (the speed control's start value).
pub const ZOOM_LINES_PER_S: u32 = 7;
/// The speed control's presets, lines per second. A preset the span cannot give is the nearest rate it can
/// (`tr_fabric::zoom::averaging_k`: whole frames per line, never more lines than transforms).
pub const SPEED_PRESETS: [u32; 5] = [1, 2, 5, 10, 15];

/// Frames per waterfall line for the preset `lps` at `span`.
pub fn speed_k(span: Span, lps: u32) -> u32 {
    tr_fabric::zoom::averaging_k(span, lps)
}

/// The rates `span` gives from [`SPEED_PRESETS`], slowest first: (frames per line, the smallest preset
/// that gives it). Presets that land on the same rate count once (12 kHz: 0.9, 1.8, 3.7 lines per
/// second; 24 kHz: 1.0, 1.8, 3.7, 7.3).
pub fn speed_choices(span: Span) -> Vec<(u32, u32)> {
    let mut v: Vec<(u32, u32)> = Vec::new();
    for p in SPEED_PRESETS {
        let k = speed_k(span, p);
        if !v.iter().any(|(kk, _)| *kk == k) {
            v.push((k, p));
        }
    }
    v.sort_by(|a, b| b.0.cmp(&a.0));
    v
}

/// The preset after `steps` steps (+ = faster) from the rate that `lps` gives at `span`; the result is a
/// preset that gives a different rate, or `lps` itself at either end.
pub fn speed_step(span: Span, lps: u32, steps: i32) -> u32 {
    let choices = speed_choices(span);
    let k = speed_k(span, lps);
    let i = choices.iter().position(|(kk, _)| *kk == k).unwrap_or(choices.len() - 1) as i32;
    let j = i + steps;
    if j < 0 || j >= choices.len() as i32 {
        return lps;
    }
    choices[j as usize].1
}

/// One band of the band buttons: its range, and where LISTEN starts in it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Band {
    /// Label of the band button.
    pub name: &'static str,
    /// Lower band edge, Hz.
    pub low_hz: u32,
    /// Upper band edge, Hz.
    pub high_hz: u32,
    /// Frequency LISTEN starts on when the band is first selected, Hz.
    pub default_hz: u32,
    /// Mode LISTEN starts in on that band.
    pub default_mode: ListenMode,
}

const fn band(name: &'static str, low_hz: u32, high_hz: u32, default_hz: u32, default_mode: ListenMode) -> Band {
    Band { name, low_hz, high_hz, default_hz, default_mode }
}

/// The 10 amateur bands and "general" (100 kHz to 30 MHz, the last entry). Default mode: LSB below
/// 10 MHz, USB above, USB on 60 m (the band's rule), CW on 30 m (no voice there), AM in general.
pub const BANDS: [Band; 11] = [
    band("160", 1_810_000, 2_000_000, 1_850_000, ListenMode::Lsb),
    band("80", 3_500_000, 4_000_000, 3_700_000, ListenMode::Lsb),
    band("60", 5_250_000, 5_450_000, 5_357_000, ListenMode::Usb),
    band("40", 7_000_000, 7_300_000, 7_150_000, ListenMode::Lsb),
    band("30", 10_100_000, 10_150_000, 10_120_000, ListenMode::Cw),
    band("20", 14_000_000, 14_350_000, 14_200_000, ListenMode::Usb),
    band("17", 18_068_000, 18_168_000, 18_130_000, ListenMode::Usb),
    band("15", 21_000_000, 21_450_000, 21_300_000, ListenMode::Usb),
    band("12", 24_890_000, 24_990_000, 24_950_000, ListenMode::Usb),
    band("10", 28_000_000, 29_700_000, 28_500_000, ListenMode::Usb),
    band("GEN", MIN_HZ, MAX_HZ, 9_650_000, ListenMode::Am),
];
/// Index of "general" in [`BANDS`].
pub const GENERAL: usize = BANDS.len() - 1;

/// The band a frequency is in (an amateur band, else general).
pub fn band_of(hz: u32) -> usize {
    BANDS[..GENERAL].iter().position(|b| (b.low_hz..=b.high_hz).contains(&hz)).unwrap_or(GENERAL)
}

/// Sideband for SSB at a frequency: lower below 10 MHz except on 60 m, upper above.
pub fn default_sideband(hz: u32) -> ListenMode {
    if hz < 10_000_000 && band_of(hz) != 2 {
        ListenMode::Lsb
    } else {
        ListenMode::Usb
    }
}

/// Filter widths of a mode, Hz; the first is the default.
pub fn filter_presets(mode: ListenMode) -> &'static [u32] {
    match mode {
        ListenMode::Lsb | ListenMode::Usb => &[2_400, 1_800, 2_800],
        ListenMode::Cw => &[500, 250, 800],
        ListenMode::Am | ListenMode::Sam => &[6_000, 9_000, 4_000],
        ListenMode::Fm => &[12_000],
    }
}

/// "2.4 kHz", "500 Hz".
pub fn width_name(hz: u32) -> String {
    if hz >= 1_000 {
        if hz % 1_000 == 0 {
            format!("{} kHz", hz / 1_000)
        } else {
            format!("{}.{} kHz", hz / 1_000, hz % 1_000 / 100)
        }
    } else {
        format!("{} Hz", hz)
    }
}

/// The receiver's oscillator against the tuned (shown) frequency: CW listens [`CW_PITCH_HZ`] below
/// the carrier, so the carrier is heard at the pitch.
pub fn nco_offset_hz(mode: ListenMode) -> i32 {
    if mode == ListenMode::Cw {
        -CW_PITCH_HZ
    } else {
        0
    }
}

/// The channel filter's pass band, Hz from the receiver's oscillator (what the filter is designed for).
/// SSB: 2.4 kHz = 300 to 2,700 Hz, 1.8 kHz = 400 to 2,200 Hz, 2.8 kHz = 200 to 3,000 Hz (mirrored
/// for LSB); CW: `width` around the pitch; AM, SAM, FM: `width` around the carrier.
pub fn filter_edges(mode: ListenMode, width: u32) -> (i32, i32) {
    let w = width as i32;
    let usb = match width {
        1_800 => (400, 2_200),
        2_800 => (200, 3_000),
        _ => (300, 300 + w),
    };
    match mode {
        ListenMode::Usb => usb,
        ListenMode::Lsb => (-usb.1, -usb.0),
        ListenMode::Cw => (CW_PITCH_HZ - w / 2, CW_PITCH_HZ + w / 2),
        ListenMode::Am | ListenMode::Sam | ListenMode::Fm => (-w / 2, w / 2),
    }
}

/// Demodulator of the back end for a mode.
pub fn demod(mode: ListenMode) -> Demod {
    match mode {
        ListenMode::Lsb | ListenMode::Usb | ListenMode::Cw => Demod::Ssb,
        ListenMode::Am => Demod::Am,
        ListenMode::Sam => Demod::Sam,
        ListenMode::Fm => Demod::Fm,
    }
}

/// Span of the zoom receiver's waterfall: 12 kHz for SSB and CW, 24 kHz for AM, SAM and FM
/// (12.5 Hz per pixel, +/-7.3 kHz in the window). Not 48 kHz: that span has no narrow-span gain, and
/// the receiver's own noise is then far below one step of the power word, so the waterfall cannot
/// show the noise floor at any color level (docs/LISTEN.md section 8).
pub fn zoom_span(mode: ListenMode) -> Span {
    match mode {
        ListenMode::Lsb | ListenMode::Usb | ListenMode::Cw => Span::from_shift(8),
        _ => Span::from_shift(7),
    }
}

/// `f` moved by `n` steps of `step` Hz on the step's grid: off the grid, the first step goes to the
/// next grid point in that direction. Clamped to the tuning range.
pub fn step_tune(f: u32, step: u32, n: i32) -> u32 {
    let (f, s) = (f as i64, step.max(1) as i64);
    let base = if n >= 0 { f.div_euclid(s) * s } else { (f + s - 1).div_euclid(s) * s };
    (base + n as i64 * s).clamp(MIN_HZ as i64, MAX_HZ as i64) as u32
}

/// What changed with an event; [`ListenRadio::apply`] carries it out.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Changes {
    /// Tuned frequency (or the oscillator offset of the mode).
    pub freq: bool,
    /// Mode (the demodulator restarts).
    pub mode: bool,
    /// Channel filter width.
    pub filter: bool,
    /// AGC on or off.
    pub agc: bool,
    /// Squelch on, off or level.
    pub squelch: bool,
    /// Volume.
    pub volume: bool,
    /// The operator asked for the FT8 screen.
    pub to_ft8: bool,
    /// The operator asked for the FreeDV screen.
    pub to_freedv: bool,
    /// The waterfall's floor or range.
    pub waterfall: bool,
    /// The waterfall's speed.
    pub speed: bool,
    /// The operator's RF gain - (-1) or + (+1), for the RF AGC (`crate::rfagc`); 0 = none.
    pub rf_gain_step: i32,
    /// The operator switched the RF AGC between auto and manual.
    pub rf_agc_toggle: bool,
}

impl Changes {
    /// True if the receiver or the audio has to be touched.
    pub fn any_radio(&self) -> bool {
        self.freq || self.mode || self.filter || self.agc || self.squelch || self.volume
    }
}

/// What the operator last used on a band.
#[derive(Clone, Copy, Debug)]
struct BandMem {
    hz: u32,
    mode: ListenMode,
}

/// What the operator chose. See the module text.
pub struct ListenStation {
    freq_hz: u32,
    mode: ListenMode,
    /// Filter preset per mode ([`ListenMode::index`]).
    filter: [usize; 6],
    /// Index into [`STEPS_HZ`].
    step: usize,
    agc_on: bool,
    squelch_on: bool,
    squelch_db: f32,
    volume_pct: u32,
    /// Frequency and mode last used on each of [`BANDS`].
    mem: [BandMem; 11],
    /// The chip has the zoom receiver (set by the firmware): the waterfall and click-to-tune work.
    pub zoom: bool,
    /// Waterfall floor (dB from the automatic setting, + = darker) and range (dB), `crate::wflevel`.
    wf_floor_db: i32,
    wf_range_db: u32,
    /// Waterfall speed: the preset asked for, lines per second ([`SPEED_PRESETS`], start [`ZOOM_LINES_PER_S`]).
    wf_speed: u32,
}

impl Default for ListenStation {
    fn default() -> Self {
        Self::new()
    }
}

impl ListenStation {
    /// 20 m, 14.200 MHz USB, 2.4 kHz, step 100 Hz, AGC on, squelch off at -90 dBFS, volume 50 %.
    pub fn new() -> Self {
        let mut mem = [BandMem { hz: 0, mode: ListenMode::Usb }; 11];
        for (m, b) in mem.iter_mut().zip(BANDS.iter()) {
            *m = BandMem { hz: b.default_hz, mode: b.default_mode };
        }
        ListenStation {
            freq_hz: 14_200_000,
            mode: ListenMode::Usb,
            filter: [0; 6],
            step: 1,
            agc_on: true,
            squelch_on: false,
            squelch_db: -90.0,
            volume_pct: 50,
            mem,
            zoom: true,
            wf_floor_db: 0,
            wf_range_db: crate::wflevel::DEFAULT_RANGE_DB,
            wf_speed: ZOOM_LINES_PER_S,
        }
    }

    /// The tuned (shown) frequency, Hz.
    pub fn freq_hz(&self) -> u32 {
        self.freq_hz
    }

    /// The mode.
    pub fn mode(&self) -> ListenMode {
        self.mode
    }

    /// Index in [`BANDS`] of the band the tuned frequency is in.
    pub fn band_index(&self) -> usize {
        band_of(self.freq_hz)
    }

    /// The tuning step, Hz.
    pub fn step_hz(&self) -> u32 {
        STEPS_HZ[self.step]
    }

    /// Index in [`filter_presets`] of the current width.
    pub fn filter_index(&self) -> usize {
        self.filter[self.mode.index()]
    }

    /// The channel filter width, Hz.
    pub fn filter_width(&self) -> u32 {
        filter_presets(self.mode)[self.filter_index()]
    }

    /// The receiver's oscillator frequency.
    pub fn nco_hz(&self) -> u32 {
        (self.freq_hz as i64 + nco_offset_hz(self.mode) as i64) as u32
    }

    /// Channel filter edges, Hz from the oscillator.
    pub fn filter_edges(&self) -> (i32, i32) {
        filter_edges(self.mode, self.filter_width())
    }

    /// The pass band in radio frequency, Hz from the tuned frequency.
    pub fn passband(&self) -> (i32, i32) {
        let (lo, hi) = self.filter_edges();
        let o = nco_offset_hz(self.mode);
        (lo + o, hi + o)
    }

    /// AGC as it applies: FM always runs with the fixed gain.
    pub fn agc_on(&self) -> bool {
        self.agc_on && self.mode != ListenMode::Fm
    }

    /// Squelch on or off, and its level in dBFS.
    pub fn squelch(&self) -> (bool, f32) {
        (self.squelch_on, self.squelch_db)
    }

    /// Volume, percent.
    pub fn volume_pct(&self) -> u32 {
        self.volume_pct
    }

    /// The waterfall's floor (dB from the automatic setting) and range (dB).
    pub fn waterfall_scale(&self) -> (i32, u32) {
        (self.wf_floor_db, self.wf_range_db)
    }

    /// The waterfall speed asked for, lines per second.
    pub fn waterfall_speed(&self) -> u32 {
        self.wf_speed
    }

    /// Lines per second the zoom receiver gives at the current mode's span, times 10.
    pub fn waterfall_speed_x10(&self) -> u32 {
        let span = zoom_span(self.mode);
        let r = tr_fabric::zoom::lines_per_s_at(span, speed_k(span, self.wf_speed)) * 10.0;
        (r + 0.5) as u32
    }

    /// The waterfall's scale for the current mode.
    pub fn axis(&self) -> ListenAxis {
        if self.zoom {
            ListenAxis::zoom(zoom_span(self.mode).hz())
        } else {
            ListenAxis::none()
        }
    }

    fn set_freq(&mut self, hz: u32, c: &mut Changes) {
        let hz = hz.clamp(MIN_HZ, MAX_HZ);
        if hz != self.freq_hz {
            self.freq_hz = hz;
            c.freq = true;
        }
    }

    fn set_mode(&mut self, m: ListenMode, c: &mut Changes) {
        if m != self.mode {
            self.mode = m;
            c.mode = true;
            c.filter = true;
            c.agc = true;
            // the oscillator moves for CW
            c.freq = true;
        }
    }

    /// Remembers frequency and mode for the band the frequency is in.
    fn remember(&mut self) {
        let b = band_of(self.freq_hz);
        self.mem[b] = BandMem { hz: self.freq_hz, mode: self.mode };
    }

    /// Applies one operator event and says what changed.
    pub fn on_event(&mut self, ev: ListenEvent) -> Changes {
        let mut c = Changes::default();
        match ev {
            ListenEvent::Mode(m) => self.set_mode(m, &mut c),
            ListenEvent::Filter(i) => {
                let i = i.min(filter_presets(self.mode).len() - 1);
                if i != self.filter_index() {
                    self.filter[self.mode.index()] = i;
                    c.filter = true;
                }
            }
            ListenEvent::FilterNext => {
                let n = filter_presets(self.mode).len();
                let i = (self.filter_index() + 1) % n;
                if i != self.filter_index() {
                    self.filter[self.mode.index()] = i;
                    c.filter = true;
                }
            }
            ListenEvent::Step(i) => self.step = i.min(STEPS_HZ.len() - 1),
            ListenEvent::StepChange(d) => self.step = (self.step as i32 + d).clamp(0, STEPS_HZ.len() as i32 - 1) as usize,
            ListenEvent::TuneSteps(n) => self.set_freq(step_tune(self.freq_hz, self.step_hz(), n), &mut c),
            ListenEvent::TuneDigit { place, dir } => {
                let unit = 10i64.pow(place.min(7));
                let f = (self.freq_hz as i64 + dir as i64 * unit).clamp(MIN_HZ as i64, MAX_HZ as i64);
                self.set_freq(f as u32, &mut c);
            }
            ListenEvent::TuneHz(d) => self.set_freq((self.freq_hz as i64 + d as i64).clamp(MIN_HZ as i64, MAX_HZ as i64) as u32, &mut c),
            ListenEvent::WaterfallClick(x) => {
                let axis = self.axis();
                if axis.waterfall {
                    let f = self.freq_hz as i64 + axis.offset_of(x) as i64;
                    // SSB and CW to 10 Hz; AM, SAM and FM onto the step's grid (a broadcast channel)
                    let grid = match self.mode {
                        ListenMode::Lsb | ListenMode::Usb | ListenMode::Cw => 10,
                        _ => self.step_hz() as i64,
                    };
                    let f = ((f + grid / 2).div_euclid(grid) * grid).clamp(MIN_HZ as i64, MAX_HZ as i64);
                    self.set_freq(f as u32, &mut c);
                }
            }
            ListenEvent::BandSelect(i) => self.select_band(i, &mut c),
            ListenEvent::BandStep(d) => {
                let cur = self.band_index() as i32;
                let i = cur + d;
                if (0..BANDS.len() as i32).contains(&i) {
                    self.select_band(i as usize, &mut c);
                }
            }
            ListenEvent::AgcToggle => {
                if self.mode != ListenMode::Fm {
                    self.agc_on = !self.agc_on;
                    c.agc = true;
                }
            }
            ListenEvent::SquelchToggle => {
                self.squelch_on = !self.squelch_on;
                c.squelch = true;
            }
            ListenEvent::SquelchStep(d) => {
                self.squelch_db = (self.squelch_db + d as f32).clamp(SQUELCH_MIN_DB, SQUELCH_MAX_DB);
                c.squelch = true;
            }
            ListenEvent::VolumeStep(d) => {
                self.volume_pct = (self.volume_pct as i32 + d).clamp(0, 100) as u32;
                c.volume = true;
            }
            ListenEvent::SwitchToFt8 => c.to_ft8 = true,
            ListenEvent::SwitchToFreedv => c.to_freedv = true,
            ListenEvent::WfSensitivityStep(d) => {
                // more sensitive = the floor lower
                self.wf_floor_db = crate::wflevel::floor_step(self.wf_floor_db, -d.signum());
                c.waterfall = true;
            }
            ListenEvent::WfSensitivityAuto => {
                self.wf_floor_db = 0;
                c.waterfall = true;
            }
            ListenEvent::WfSpeedStep(d) => {
                let s = speed_step(zoom_span(self.mode), self.wf_speed, d.signum());
                if s != self.wf_speed {
                    self.wf_speed = s;
                    c.speed = true;
                }
            }
            ListenEvent::WfRangeStep(d) => {
                self.wf_range_db = crate::wflevel::range_step(self.wf_range_db, d.signum());
                c.waterfall = true;
            }
            // the RF AGC lives with the HL2 session, not here: only reported
            ListenEvent::RfGainStep(d) => c.rf_gain_step = d.signum(),
            ListenEvent::RfAgcToggle => c.rf_agc_toggle = true,
        }
        if c.freq || c.mode {
            self.remember();
        }
        c
    }

    fn select_band(&mut self, i: usize, c: &mut Changes) {
        if i >= BANDS.len() {
            return;
        }
        self.remember();
        let m = self.mem[i];
        self.set_mode(m.mode, c);
        self.set_freq(m.hz, c);
        self.remember();
    }

    /// One line of what the receiver is set to.
    pub fn info_text(&self) -> String {
        let (lo, hi) = self.filter_edges();
        format!(
            "receiver {}, oscillator {} Hz, filter {:+} to {:+} Hz, {}",
            RX,
            group(self.nco_hz()),
            lo,
            hi,
            if self.mode == ListenMode::Fm { "fixed gain" } else if self.agc_on { "AGC on" } else { "AGC off" }
        )
    }

    /// The screen's state; the measurements come from the radio when it runs.
    pub fn screen<R: RegisterSpace, M: FabricMem>(&self, radio: Option<&ListenRadio<'_, R, M>>, link_text: &str, link_ok: bool) -> ListenScreenState {
        let mut s = ListenScreenState {
            freq_hz: self.freq_hz,
            mode: self.mode,
            band_names: BANDS.iter().map(|b| b.name).collect(),
            band_index: self.band_index(),
            filter_names: filter_presets(self.mode).iter().map(|w| width_name(*w)).collect(),
            filter_index: self.filter_index(),
            step_index: self.step,
            agc_on: self.agc_on(),
            squelch_on: self.squelch_on,
            squelch_db: self.squelch_db,
            squelch_open: true,
            volume_pct: self.volume_pct,
            smeter_dbfs: -140.0,
            passband: self.passband(),
            axis: self.axis(),
            info_text: self.info_text(),
            audio_text: String::new(),
            audio_ok: true,
            link_text: link_text.into(),
            link_ok,
            wf_sensitivity_db: -self.wf_floor_db,
            wf_range_db: self.wf_range_db,
            wf_speed_x10: self.waterfall_speed_x10(),
            ..ListenScreenState::default()
        };
        if let Some(r) = radio {
            s.smeter_dbfs = r.smeter_dbfs().clamp(-160.0, 0.0);
            s.squelch_open = r.squelch_open();
            s.audio_ok = r.underruns == 0 && r.ring_lost() == 0;
            s.audio_text = format!(
                "audio: 48 kHz, ring {} ms, underruns {}, blocks lost {}, dropped {}, longest gap {} ms",
                r.audio_fill_ms(),
                r.underruns,
                r.ring_lost(),
                r.skipped_blocks,
                r.longest_gap_us / 1_000
            );
        }
        s
    }
}

/// "14.200.000"
pub fn group(hz: u32) -> String {
    format!("{}.{:03}.{:03}", hz / 1_000_000, hz / 1_000 % 1_000, hz % 1_000)
}

/// The console keys of the LISTEN screen (docs/LISTEN.md section 4). None of them is on the network
/// input's transmit block list, and no LISTEN event transmits.
///
/// | Key | What |
/// |---|---|
/// | left, right arrow | tune one step down, up |
/// | up, down arrow | volume 5 % up, down |
/// | Shift + up, down | squelch level 2 dB up, down |
/// | Page Up, Page Down | tune 100 kHz up, down |
/// | Home, End, `[`, `]` | band down, up |
/// | `l` `k` `w` `a` `g` `f` | LSB, USB, CW, AM, SAM, FM |
/// | `b` | next filter width |
/// | `,` `<` / `.` `>` | smaller, larger step |
/// | `o` | AGC on/off |
/// | `q` | squelch on/off |
/// | `e` / `d` | waterfall sensitivity 3 dB more (brighter) / less (darker) |
/// | `r` / `v` | waterfall contrast: the range one step wider / narrower |
/// | `x` / `z` | waterfall speed one preset faster / slower |
/// | `m` | to the FT8 screen (`m` cycles FT8, FreeDV, LISTEN) |
pub fn event_for(key: u8) -> Option<ListenEvent> {
    use tr_input::code;
    Some(match key {
        code::LEFT => ListenEvent::TuneSteps(-1),
        code::RIGHT => ListenEvent::TuneSteps(1),
        code::UP => ListenEvent::VolumeStep(5),
        code::DOWN => ListenEvent::VolumeStep(-5),
        code::SHIFT_UP => ListenEvent::SquelchStep(2),
        code::SHIFT_DOWN => ListenEvent::SquelchStep(-2),
        code::PAGE_UP => ListenEvent::TuneHz(BIG_STEP_HZ),
        code::PAGE_DOWN => ListenEvent::TuneHz(-BIG_STEP_HZ),
        code::HOME | b'[' => ListenEvent::BandStep(-1),
        code::END | b']' => ListenEvent::BandStep(1),
        b'l' => ListenEvent::Mode(ListenMode::Lsb),
        b'k' => ListenEvent::Mode(ListenMode::Usb),
        b'w' => ListenEvent::Mode(ListenMode::Cw),
        b'a' => ListenEvent::Mode(ListenMode::Am),
        b'g' => ListenEvent::Mode(ListenMode::Sam),
        b'f' => ListenEvent::Mode(ListenMode::Fm),
        b'b' => ListenEvent::FilterNext,
        b',' | b'<' => ListenEvent::StepChange(-1),
        b'.' | b'>' => ListenEvent::StepChange(1),
        b'o' => ListenEvent::AgcToggle,
        b'q' => ListenEvent::SquelchToggle,
        b'e' => ListenEvent::WfSensitivityStep(1),
        b'd' => ListenEvent::WfSensitivityStep(-1),
        b'r' => ListenEvent::WfRangeStep(1),
        b'v' => ListenEvent::WfRangeStep(-1),
        b'x' => ListenEvent::WfSpeedStep(1),
        b'z' => ListenEvent::WfSpeedStep(-1),
        b'm' => ListenEvent::SwitchToFt8,
        _ => return None,
    })
}

/// A designed filter, kept so that switching back costs nothing.
struct CachedFilter {
    /// Pass band the filter was designed for, Hz from the oscillator.
    edges: (i32, i32),
    /// Taps in use, and the block exponent of the coefficients.
    ntaps: u16,
    exp: u8,
    /// Quantized coefficients, real and imaginary parts.
    re: Box<[i32]>,
    im: Box<[i32]>,
}

/// The receiver and the audio behind it. See the module text.
pub struct ListenRadio<'a, R: RegisterSpace, M: FabricMem> {
    regs: &'a R,
    mem: &'a M,
    ring: BackendRing,
    audio: AudioOut<'a, R, M>,
    up: Resampler,
    /// Bank the receiver uses (one of [`BANKS`]).
    bank: u32,
    /// A filter waiting for its bank to come free: its edges.
    pending_filter: Option<(i32, i32)>,
    /// Filters designed so far.
    cache: Vec<CachedFilter>,
    /// Work space of the filter design.
    scratch: Vec<f64>,
    /// Software volume, Q15 (the chip's volume register reaches no output).
    gain_q15: i32,
    /// The audio ring is being fed (false before the first prefill and after an underrun).
    playing: bool,
    /// 48 kHz frames given to the audio ring since playing started.
    pushed: u64,
    /// Times the audio ring ran dry while playing.
    pub underruns: u32,
    /// Blocks dropped to hold the latency after a stall.
    pub skipped_blocks: u32,
    /// 48 kHz frames given to the audio ring.
    pub frames_out: u64,
    /// Time of the last [`ListenRadio::service`] call, us.
    last_service_us: Option<u64>,
    /// Longest time between two calls of [`ListenRadio::service`] since [`ListenRadio::take_window`].
    pub longest_gap_us: u64,
    /// Largest output sample since [`ListenRadio::take_window`].
    peak: i32,
    /// Filter designs made (the cache's misses).
    pub designs: u32,
}

impl<'a, R: RegisterSpace, M: FabricMem> ListenRadio<'a, R, M> {
    /// Starts the receiver and the audio engine for `st`'s settings.
    pub fn start(regs: &'a R, mem: &'a M, st: &ListenStation) -> Self {
        let backend = Backend::new(regs);
        backend.stop(RX);
        let mut audio = AudioOut::new(regs, mem, map::AUDIO_RING);
        // the chip's volume register reaches no output (docs/AUDIO_OUT.md); full, the volume is applied here
        audio.set_volume(255);
        audio.set_outputs(true, true, false);
        audio.set_enable(true);
        // the ring first (its write pointer starts at 0), the receiver behind it
        let ring = backend.open_ring(RX, map::backend_ring(RX), RING_LOG2);
        let mut r = ListenRadio {
            regs,
            mem,
            ring,
            audio,
            up: Resampler::new(4, 1),
            bank: BANKS[0],
            pending_filter: None,
            cache: Vec::new(),
            scratch: vec![0.0; 2 * MAX_TAPS],
            gain_q15: 0,
            playing: false,
            pushed: 0,
            underruns: 0,
            skipped_blocks: 0,
            frames_out: 0,
            last_service_us: None,
            longest_gap_us: 0,
            peak: 0,
            designs: 0,
        };
        r.load(BANKS[0], st.filter_edges());
        let bank = RxBank::new(regs);
        bank.set_frequency_hz(RX, st.nco_hz());
        bank.start(RX, Rate::K48);
        r.restart_backend(st);
        r.set_volume(st.volume_pct());
        r
    }

    /// Receiver and audio engine off.
    pub fn stop(&mut self) {
        Backend::new(self.regs).stop(RX);
        RxBank::new(self.regs).stop(RX);
        self.audio.set_enable(false);
        self.playing = false;
    }

    /// Starts the back end for the station's mode, AGC and squelch.
    fn restart_backend(&mut self, st: &ListenStation) {
        let backend = Backend::new(self.regs);
        backend.start(RX, &RxSetup { demod: demod(st.mode()), in_rate: Rate::K48, agc: st.agc_on(), bank: self.bank });
        if st.mode() == ListenMode::Fm {
            backend.set_fm_deemphasis(RX, FM_DEEMPH_ALPHA);
            backend.set_manual_gain(RX, FM_GAIN_S7_12);
        } else {
            backend.set_fm_deemphasis(RX, 0);
        }
        self.apply_squelch(st);
    }

    fn apply_squelch(&self, st: &ListenStation) {
        let (on, db) = st.squelch();
        let raw = |d: f32| ((d - SMETER_TO_DBFS_DB) * 64.0).clamp(-32_768.0, 32_767.0) as i16;
        Backend::new(self.regs).set_squelch(RX, on, raw(db), raw(db - SQUELCH_HYSTERESIS_DB));
    }

    fn set_volume(&mut self, pct: u32) {
        // audio taper: (pct / 100)^2, up to 2 (+6 dB) at 100 %
        let v = pct.min(100) as i64;
        self.gain_q15 = (v * v * 2 * 32_768 / 10_000) as i32;
    }

    /// Writes the filter for `edges` into `bank` (designed once, then from the cache). False if the
    /// bank is still in use (the caller tries again later).
    fn load(&mut self, bank: u32, edges: (i32, i32)) -> bool {
        let i = match self.cache.iter().position(|c| c.edges == edges) {
            Some(i) => i,
            None => {
                let mut re = vec![0i32; FILTER_TAPS].into_boxed_slice();
                let mut im = vec![0i32; FILTER_TAPS].into_boxed_slice();
                let (ntaps, exp) = bandpass_quantized_into(FILTER_FS, edges.0 as f64, edges.1 as f64, FILTER_TAPS, &mut re, &mut im, &mut self.scratch);
                self.designs += 1;
                self.cache.push(CachedFilter { edges, ntaps, exp, re, im });
                self.cache.len() - 1
            }
        };
        let c = &self.cache[i];
        Backend::new(self.regs).load_bank(UNIT, bank, &c.re[..c.ntaps as usize], &c.im[..c.ntaps as usize], c.exp)
    }

    /// Switches to the filter for `edges` through the bank the receiver does not use.
    fn switch_filter(&mut self, edges: (i32, i32)) {
        let other = if self.bank == BANKS[0] { BANKS[1] } else { BANKS[0] };
        if self.load(other, edges) {
            Backend::new(self.regs).select_bank(RX, other);
            self.bank = other;
            self.pending_filter = None;
        } else {
            self.pending_filter = Some(edges);
        }
    }

    /// Carries out what changed.
    pub fn apply(&mut self, st: &ListenStation, c: &Changes) {
        let backend = Backend::new(self.regs);
        if c.mode {
            // a new demodulator starts from a clean state: filter first, then a restart of the back end
            backend.stop(RX);
            self.pending_filter = None;
            if !self.load(self.bank, st.filter_edges()) {
                // cannot happen with the receiver stopped; keep the old filter if it does
                self.pending_filter = Some(st.filter_edges());
            }
            self.restart_backend(st);
        } else if c.filter {
            self.switch_filter(st.filter_edges());
        }
        if c.freq || c.mode {
            RxBank::new(self.regs).set_frequency_hz(RX, st.nco_hz());
        }
        if c.agc && !c.mode && st.mode() != ListenMode::Fm {
            if !st.agc_on() {
                // AGC off holds the gain the AGC had (S.10 -> S7.12)
                backend.set_manual_gain(RX, backend.agc_gain_s10(RX) << 2);
            }
            backend.set_agc(RX, st.agc_on());
        }
        if c.squelch && !c.mode {
            self.apply_squelch(st);
        }
        if c.volume {
            self.set_volume(st.volume_pct());
        }
    }

    /// Tops the audio ring up from the back-end ring. Call often: from the main loop, the yield
    /// hook and the screen drawing (the ring holds 85 ms). `now_us`: a free-running microsecond clock.
    pub fn service(&mut self, now_us: u64) {
        if let Some(last) = self.last_service_us {
            self.longest_gap_us = self.longest_gap_us.max(now_us.wrapping_sub(last));
        }
        self.last_service_us = Some(now_us);
        if let Some(edges) = self.pending_filter {
            self.switch_filter(edges);
        }
        let regs = self.regs;
        if self.playing && self.pushed > 0 && self.audio.fill() == 0 {
            // the engine played everything it was given and found the ring empty
            self.underruns += 1;
            self.playing = false;
        }
        let pending = self.ring.pending(regs);
        if !self.playing {
            if pending < PREFILL_BLOCKS {
                return;
            }
            self.playing = true;
            self.pushed = 0;
        }
        let room = self.audio.free() / FRAMES_PER_BLOCK;
        if pending > room + MAX_BACKLOG_BLOCKS {
            self.skipped_blocks += self.ring.skip(regs, pending - room - MAX_BACKLOG_BLOCKS);
        }
        let (up, audio, gain, peak) = (&mut self.up, &mut self.audio, self.gain_q15, &mut self.peak);
        let mut frames = [0u32; FRAMES_PER_BLOCK as usize];
        let mut out = 0u64;
        self.ring.poll_max(regs, self.mem, room, |_, s| {
            let mut n = 0;
            up.process(s, |v| {
                let a = ((v as i32 * gain) >> 15).clamp(-32_768, 32_767);
                *peak = (*peak).max(a.abs());
                if n < frames.len() {
                    frames[n] = stereo_word(a as i16, a as i16);
                    n += 1;
                }
            });
            out += audio.push(&frames[..n]) as u64;
        });
        self.frames_out += out;
        self.pushed += out;
    }

    /// Audio queued in the engine's ring, ms.
    pub fn audio_fill_ms(&self) -> u32 {
        self.audio.fill() / 48
    }

    /// Blocks the back end overwrote before they were read.
    pub fn ring_lost(&self) -> u32 {
        self.ring.lost
    }

    /// S-meter, dB relative to the ADC's full scale.
    pub fn smeter_dbfs(&self) -> f32 {
        Backend::new(self.regs).smeter_db64(RX) as f32 / 64.0 + SMETER_TO_DBFS_DB
    }

    /// True while the squelch lets audio through.
    pub fn squelch_open(&self) -> bool {
        Backend::new(self.regs).squelch_open(RX)
    }

    /// Peak output level since the last call, dBFS, and the longest gap between services (us);
    /// both start again.
    pub fn take_window(&mut self) -> (f32, u64) {
        let p = core::mem::take(&mut self.peak).max(1) as f32 / 32_768.0;
        (20.0 * libm::log10f(p), core::mem::take(&mut self.longest_gap_us))
    }

    /// The console's 5 s line.
    pub fn status_line(&mut self, st: &ListenStation, longest_pass_ms: i64) -> String {
        let (peak_db, gap_us) = self.take_window();
        format!(
            "LISTEN {} Hz {} {}, S-meter {:.1} dBFS, audio peak {:.1} dBFS, ring {} ms, underruns {}, blocks lost {}, dropped {}, longest service gap {} ms, longest pass {} ms",
            group(st.freq_hz()),
            st.mode().name(),
            width_name(st.filter_width()),
            self.smeter_dbfs(),
            peak_db,
            self.audio_fill_ms(),
            self.underruns,
            self.ring_lost(),
            self.skipped_blocks,
            gap_us / 1_000,
            longest_pass_ms
        )
    }

    /// Bank the receiver is set to use.
    pub fn bank(&self) -> u32 {
        self.bank
    }

    /// Filters waiting for their bank.
    pub fn filter_pending(&self) -> bool {
        self.pending_filter.is_some()
    }
}

#[cfg(test)]
mod tests;
