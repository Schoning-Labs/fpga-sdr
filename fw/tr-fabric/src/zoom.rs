// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Zoom receiver (`hw/regmap/zoom.toml`, docs/ZOOM_IN_CHIP.md, docs/F3_ZOOM.md): a second spectrum
//! with its own center frequency and one of eleven spans, 3.072 MHz down to 3 kHz, across the same
//! 1,920 columns as the full-band spectrum. Its trace goes to a compositor window with
//! `source_zoom`, its waterfall through its own hardware writer into its own DDR3 ring
//! (`video::Video::set_zoom_waterfall_ring`, `video::WaterfallSource::Zoom`).
//!
//! A chip built without it answers 0 for the block id: [`Zoom::present`]. (A chip with the first
//! version of the block, seven spans, counts as without it.)
//!
//! **Scale.** The displayed span covers the 1,920 columns exactly, the center frequency at column
//! 960: one column is `span / 1,920` Hz (1.56 Hz at the narrowest span, 1.6 kHz at the widest). The
//! FFT behind it has 3,277 bins over the span, so every column holds one or two bins.
//!
//! **FT8 scale** ([`Setup::ft8_columns`], docs/ZOOM_IN_CHIP.md section 12). At the 6 kHz span
//! ([`Span::FT8`]) a bin is 1.831 Hz; with this switch the logic puts 0.71533 columns on a bin
//! instead, counted from the low edge of the span: one column is 2.5597 Hz, so the FT8 screen's
//! 1,172 columns are 3,000 Hz. The low edge is [`FT8_LOW_EDGE_BELOW_CENTRE_HZ`] below the center.
//!
//! **Line rate.** A line needs one whole 4,096-point transform and the transforms do not overlap:
//! [`Span::transforms_per_s`] is the most lines per second a span gives, 14.6 at 48 kHz, 1.83 at
//! 6 kHz (a line every 0.55 s, each showing the last 0.55 s), 0.92 at 3 kHz.
//!
//! **Changing K while running** (`backend_averaging_k`, frames per line). The logic counts the frames
//! of the line in progress and ends it when the count equals K - 1 (`rtl/spectrum/spectrum_pipeline.v`,
//! `groupB_pos == zk_last`; the count is 32 bits and only a line's end clears it). K can be written
//! at any time and takes effect at once, but a K below the count of the line in progress is never met:
//! the waterfall stops until K is raised again. So K is only raised at once, and lowered right after a
//! new line appeared (count 0), see [`averaging_k`] and `tr_station::radio`.
//!
//! **Gain of the narrow spans** ([`Setup::narrow_gain`]). The samples between the stages are 16-bit
//! words scaled for the ADC's full scale, and in a few kHz the band noise is far below one step of
//! them. The narrow spans' decimation stage can multiply by 4, 16 or 64 (saturating);
//! [`NARROW_GAIN_DEFAULT`] is 16. [`narrow_gain_db64`] is what that adds to the line, for the level.

use tr_regs::generated::zoom as zm;
use tr_regs::RegisterSpace;

/// Columns of a zoom line (and of a waterfall line).
pub const COLUMNS: u32 = 1_920;
/// Number of spans.
pub const SPANS: u32 = 11;
/// `ctrl.narrow_gain` used unless a [`Setup`] says otherwise: 2 = times 16 (24.08 dB).
pub const NARROW_GAIN_DEFAULT: u32 = 2;
/// With [`Setup::ft8_columns`] at [`Span::FT8`]: column 0 is this far below the center (1,638 bins of 1.8311 Hz).
pub const FT8_LOW_EDGE_BELOW_CENTRE_HZ: u32 = 2_999;
/// With [`Setup::ft8_columns`] at [`Span::FT8`]: Hz per column, in thousandths (7,500 / 4,096 / 0.71533).
pub const FT8_MILLIHZ_PER_COLUMN: u32 = 2_560;

/// What `narrow_gain` adds to a zoom line, in 1/64 dB (12.04 dB per step).
pub const fn narrow_gain_db64(narrow_gain: u32) -> i16 {
    (narrow_gain as i32 * 771) as i16
}

/// A span, by its index: 0 = 3.072 MHz ... 6 = 48 kHz ... 10 = 3 kHz, each half the one before.
/// (In the register: `span_shift` = the index up to 6, `narrow_shift` = what is over 6.)
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Span(u32);

impl Span {
    pub const WIDEST: Span = Span(0);
    /// 48 kHz: the narrowest span that does not use the narrow spans' stage.
    pub const K48: Span = Span(6);
    /// 6 kHz: the span of the FT8 screen's waterfall (see the module text, "FT8 scale").
    pub const FT8: Span = Span(9);
    pub const NARROWEST: Span = Span(SPANS - 1);

    /// From the index 0-10 (larger values: the narrowest).
    pub const fn from_shift(shift: u32) -> Span {
        Span(if shift >= SPANS { SPANS - 1 } else { shift })
    }

    /// True for the spans under 48 kHz.
    pub const fn is_narrow(self) -> bool {
        self.0 > 6
    }

    /// `ctrl.span_shift` of this span.
    pub const fn span_shift(self) -> u32 {
        if self.0 > 6 { 6 } else { self.0 }
    }

    /// `ctrl.narrow_shift` of this span.
    pub const fn narrow_shift(self) -> u32 {
        if self.0 > 6 { self.0 - 6 } else { 0 }
    }

    /// The narrowest span that still shows `hz` (the widest if none does).
    pub const fn at_least(hz: u32) -> Span {
        let mut s = SPANS - 1;
        while s > 0 && Span(s).hz() < hz {
            s -= 1;
        }
        Span(s)
    }

    pub const fn shift(self) -> u32 {
        self.0
    }

    /// Displayed span in Hz: 3,072,000 >> shift.
    pub const fn hz(self) -> u32 {
        3_072_000 >> self.0
    }

    /// Hz per column, in thousandths (25,000 = 25 Hz), at the scale "the span across 1,920 columns".
    pub const fn millihz_per_column(self) -> u32 {
        (self.hz() as u64 * 1_000 / COLUMNS as u64) as u32
    }

    /// 4,096-point transforms per second: the internal rate (span / 0.8) / 4,096.
    pub fn transforms_per_s(self) -> f32 {
        (76_800_000.0 / 20.0 / 4_096.0) / (1u32 << self.0) as f32
    }
}

/// Everything [`Zoom::start_with`] sets.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Setup {
    /// The frequency at column 960 (with `ft8_columns`: [`FT8_LOW_EDGE_BELOW_CENTRE_HZ`] above column 0).
    pub centre_hz: u32,
    pub span: Span,
    /// Output lines (waterfall rows) per second wanted; never more than [`Span::transforms_per_s`].
    pub lines_per_s: u32,
    /// False keeps the strongest bin of each column.
    pub mean_per_column: bool,
    pub peak_hold: bool,
    /// 0-3: gain 4^n of the narrow spans' stage (no effect at 48 kHz and wider).
    pub narrow_gain: u32,
    /// The FT8 screen's column scale instead of "the span across 1,920 columns".
    pub ft8_columns: bool,
}

pub struct Zoom<'a, R: RegisterSpace> {
    regs: &'a R,
}

impl<'a, R: RegisterSpace> Zoom<'a, R> {
    pub fn new(regs: &'a R) -> Self {
        Zoom { regs }
    }

    pub fn id(&self) -> u32 {
        zm::id::read(self.regs)
    }

    /// True if the chip has the zoom receiver.
    pub fn present(&self) -> bool {
        self.id() == zm::id::RESET
    }

    /// Moves the center (the frequency shown at column 960). Takes effect at once; the lines
    /// already averaged in keep the old center for one line.
    pub fn set_centre_hz(&self, hz: u32) {
        zm::phase_inc::write(self.regs, zm::phase_inc::Value(crate::phase_inc(hz)));
    }

    /// Starts the zoom receiver at `centre_hz` with `span`, at about `lines_per_s` output lines
    /// (waterfall rows) per second: never more than the span's transforms per second (14.6 at
    /// 48 kHz, 1.83 at 6 kHz). `mean_per_column` false keeps the strongest bin of each column.
    /// The usual column scale, [`NARROW_GAIN_DEFAULT`] at the narrow spans. The receiver is
    /// stopped first: its filters are held in reset while the span changes.
    pub fn start(&self, centre_hz: u32, span: Span, lines_per_s: u32, mean_per_column: bool, peak_hold: bool) {
        self.start_with(&Setup { centre_hz, span, lines_per_s, mean_per_column, peak_hold, narrow_gain: NARROW_GAIN_DEFAULT, ft8_columns: false });
    }

    /// [`Zoom::start`] with every setting given.
    pub fn start_with(&self, s: &Setup) {
        self.start_with_k(s, rounded_k(s.span, s.lines_per_s));
    }

    /// [`Zoom::start_with`] with the frames per output line given (`lines_per_s` is not used). See
    /// [`averaging_k`] and the module's note on lowering K.
    pub fn start_with_k(&self, s: &Setup, k: u32) {
        let gain = if s.span.is_narrow() { s.narrow_gain.min(3) } else { 0 };
        let modes = zm::ctrl::Value(0)
            .with_span_shift(s.span.span_shift())
            .with_narrow_shift(s.span.narrow_shift())
            .with_narrow_gain(gain)
            .with_backend_column_mode(s.mean_per_column)
            .with_backend_peak_hold(s.peak_hold)
            .with_backend_ft8_columns(s.ft8_columns);
        zm::ctrl::write(self.regs, modes);
        self.set_centre_hz(s.centre_hz);
        zm::backend_averaging_k::write(self.regs, k.max(1));
        zm::ctrl::write(self.regs, modes.with_enable(true));
    }

    /// Frames averaged per output line, as the register holds it.
    pub fn averaging_k(&self) -> u32 {
        zm::backend_averaging_k::read(self.regs)
    }

    /// Writes the frames averaged per output line while the receiver runs; no restart. See the
    /// module's note on lowering K: only raise it freely, lower it right after a new line appeared.
    pub fn set_averaging_k(&self, k: u32) {
        zm::backend_averaging_k::write(self.regs, k.max(1));
    }

    pub fn stop(&self) {
        zm::ctrl::modify(self.regs, |v| v.with_enable(false));
    }

    /// The span the receiver is set to.
    pub fn span(&self) -> Span {
        let c = zm::ctrl::read(self.regs);
        Span::from_shift(if c.span_shift() >= 6 { 6 + c.narrow_shift() } else { c.span_shift() })
    }

    pub fn running(&self) -> bool {
        zm::ctrl::read(self.regs).enable()
    }

    /// Waterfall color mapping, as `spectrum::Spectrum::set_level`.
    pub fn set_level(&self, offset_db64: i16, gain_q8: u16) {
        zm::backend_level::write(self.regs, zm::backend_level::Value(0).with_offset_db64(offset_db64 as u16 as u32).with_gain_q8(gain_q8 as u32));
    }

    /// Lines produced so far (free-running).
    pub fn line_count(&self) -> u32 {
        zm::backend_line_count::read(self.regs)
    }

    pub fn clear_line_done(&self) {
        zm::backend_line_status::clear_line_done(self.regs);
    }
}

/// Frames per output line for about `lines_per_s`, `transforms_per_s / lines_per_s` rounded: what
/// [`Zoom::start_with`] writes.
pub fn rounded_k(span: Span, lines_per_s: u32) -> u32 {
    ((span.transforms_per_s() / lines_per_s.max(1) as f32 + 0.5) as u32).max(1)
}

/// Frames per output line (`backend_averaging_k`) that gives the line rate nearest to `lines_per_s`
/// (nearest in ratio, between the two whole values around `transforms_per_s / lines_per_s`); at
/// least 1, so never more than [`Span::transforms_per_s`] lines per second.
pub fn averaging_k(span: Span, lines_per_s: u32) -> u32 {
    let t = span.transforms_per_s();
    let want = lines_per_s.max(1) as f32;
    let lo = ((t / want) as u32).max(1);
    let hi = lo + 1;
    let (r_lo, r_hi) = (t / lo as f32, t / hi as f32);
    // r_lo >= want >= r_hi unless want exceeds t: then lo (= 1) is the answer
    if r_lo <= want || r_lo / want <= want / r_hi {
        lo
    } else {
        hi
    }
}

/// Lines per second at `k` frames per line.
pub fn lines_per_s_at(span: Span, k: u32) -> f32 {
    span.transforms_per_s() / k.max(1) as f32
}

/// Column (0-1,919) of `f_hz` in a zoom line centerd on `centre_hz`, or `None` outside the span.
pub fn column_of(centre_hz: u32, span: Span, f_hz: u32) -> Option<u32> {
    let off = f_hz as i64 - centre_hz as i64;
    let col = (COLUMNS as i64 / 2) + (off * COLUMNS as i64).div_euclid(span.hz() as i64);
    (0..COLUMNS as i64).contains(&col).then_some(col as u32)
}

/// Column (0-1,919) of `f_hz` in a zoom line at the FT8 scale ([`Setup::ft8_columns`] at
/// [`Span::FT8`]) whose column 0 starts at `low_edge_hz`, or `None` outside the line.
pub fn ft8_column_of(low_edge_hz: u32, f_hz: u32) -> Option<u32> {
    let off = f_hz as i64 - low_edge_hz as i64;
    let col = (off * 1_000).div_euclid(FT8_MILLIHZ_PER_COLUMN as i64);
    (off >= 0 && col < COLUMNS as i64).then_some(col as u32)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mock::MockFabric;

    #[test]
    fn spans() {
        assert_eq!(Span::WIDEST.hz(), 3_072_000);
        assert_eq!(Span::K48.hz(), 48_000);
        assert_eq!(Span::K48.millihz_per_column(), 25_000);
        assert_eq!(Span::FT8.hz(), 6_000);
        assert_eq!(Span::NARROWEST.hz(), 3_000);
        assert_eq!(Span::NARROWEST.millihz_per_column(), 1_562);
        assert_eq!(Span::at_least(3_000), Span::NARROWEST);
        assert_eq!(Span::at_least(3_001), Span::FT8);
        assert_eq!(Span::at_least(48_001).hz(), 96_000);
        assert_eq!(Span::at_least(10_000_000), Span::WIDEST);
        assert_eq!(Span::from_shift(19), Span::NARROWEST);
        assert_eq!((Span::K48.span_shift(), Span::K48.narrow_shift(), Span::K48.is_narrow()), (6, 0, false));
        assert_eq!((Span::FT8.span_shift(), Span::FT8.narrow_shift(), Span::FT8.is_narrow()), (6, 3, true));
        assert_eq!((Span::NARROWEST.span_shift(), Span::NARROWEST.narrow_shift()), (6, 4));
        // 76.8 Msps / 20 / 64 = 60 ksps; / 4,096 = 14.65 transforms per second
        assert!((Span::K48.transforms_per_s() - 14.648).abs() < 0.01);
        assert!((Span::WIDEST.transforms_per_s() - 937.5).abs() < 0.01);
        // 6 kHz: 7,500 samples per second, a transform every 0.546 s; 3 kHz: every 1.09 s
        assert!((Span::FT8.transforms_per_s() - 1.831).abs() < 0.001);
        assert!((Span::NARROWEST.transforms_per_s() - 0.9155).abs() < 0.001);
        // the FT8 scale: 0.71533 columns on a bin of 7,500 / 4,096 Hz; 1,172 columns are 3,000 Hz
        let col_hz = 7_500.0 / 4_096.0 / (750_080.0 / 1_048_576.0);
        assert!((col_hz * 1_000.0 - FT8_MILLIHZ_PER_COLUMN as f32).abs() < 1.0);
        assert!((col_hz * 1_172.0 - 3_000.0).abs() < 0.5);
        assert!((1_638.0 * 7_500.0 / 4_096.0 - FT8_LOW_EDGE_BELOW_CENTRE_HZ as f32).abs() < 1.0);
        assert_eq!(narrow_gain_db64(2), 1_542);
    }

    #[test]
    fn start_stops_first_then_sets_everything_then_enables() {
        let f = MockFabric::new();
        let z = Zoom::new(&f);
        assert!(!z.present());
        f.poke(zm::id::addr(), zm::id::RESET);
        assert!(z.present());
        z.start(14_075_500, Span::K48, 7, false, false);
        // ctrl: span 6 with enable off, then the same with enable on; the phase increment and K in between
        assert_eq!(f.reg_writes(zm::ctrl::addr()), [6 << 1, (6 << 1) | 1]);
        assert_eq!(f.reg(zm::phase_inc::addr()), crate::phase_inc(14_075_500));
        assert_eq!(f.reg(zm::backend_averaging_k::addr()), 2);
        assert!(z.running());
        assert_eq!(z.span(), Span::K48);
        // more lines per second than transforms: every transform is a line
        z.start(7_100_000, Span::K48, 30, true, true);
        assert_eq!(f.reg(zm::backend_averaging_k::addr()), 1);
        assert_eq!(f.reg(zm::ctrl::addr()), (1 << 5) | (1 << 4) | (6 << 1) | 1);
        // a narrow span: span_shift 6, narrow_shift 3, the default gain; one line per transform
        z.start(14_077_000, Span::FT8, 2, false, false);
        assert_eq!(f.reg(zm::ctrl::addr()), (2 << 9) | (3 << 6) | (6 << 1) | 1);
        assert_eq!(f.reg(zm::backend_averaging_k::addr()), 1);
        assert_eq!(z.span(), Span::FT8);
        // every setting: the FT8 column scale, gain 3
        z.start_with(&Setup { centre_hz: 14_077_000, span: Span::NARROWEST, lines_per_s: 1, mean_per_column: false, peak_hold: false, narrow_gain: 3, ft8_columns: true });
        assert_eq!(f.reg(zm::ctrl::addr()), (1 << 11) | (3 << 9) | (4 << 6) | (6 << 1) | 1);
        assert_eq!(z.span(), Span::NARROWEST);
        z.start(7_100_000, Span::WIDEST, 30, false, false);
        assert_eq!(f.reg(zm::backend_averaging_k::addr()), 31);
        z.stop();
        assert!(!z.running());
        assert_eq!(z.span(), Span::WIDEST);
        z.set_level(-640, 0x0180);
        assert_eq!(f.reg(zm::backend_level::addr()), 0x0180_FD80);
    }

    #[test]
    fn averaging_k_gives_the_nearest_line_rate_and_can_change_while_running() {
        let (s12, s24) = (Span::from_shift(8), Span::from_shift(7));
        // 12 kHz: 3.66 transforms per s; 24 kHz: 7.32
        let ks12 = [1u32, 2, 5, 10, 15, 7].map(|p| averaging_k(s12, p));
        assert_eq!(ks12, [4, 2, 1, 1, 1, 1]);
        let ks24 = [1u32, 2, 5, 10, 15, 7].map(|p| averaging_k(s24, p));
        assert_eq!(ks24, [7, 4, 2, 1, 1, 1]);
        assert!((lines_per_s_at(s24, 2) - 3.66).abs() < 0.01);
        // K48 at 7 lines per s, as start() has always done
        assert_eq!(averaging_k(Span::K48, 7), 2);
        let f = MockFabric::new();
        let z = Zoom::new(&f);
        f.poke(zm::id::addr(), zm::id::RESET);
        z.start_with_k(&Setup { centre_hz: 7_100_000, span: s12, lines_per_s: 99, mean_per_column: false, peak_hold: false, narrow_gain: 3, ft8_columns: false }, 4);
        assert_eq!(z.averaging_k(), 4);
        let writes = f.reg_writes(zm::ctrl::addr()).len();
        z.set_averaging_k(2);
        assert_eq!(z.averaging_k(), 2);
        assert_eq!(f.reg_writes(zm::ctrl::addr()).len(), writes, "no restart: ctrl is not written");
        assert!(z.running());
    }

    #[test]
    fn columns() {
        let c = 14_075_500;
        assert_eq!(column_of(c, Span::K48, c), Some(960));
        assert_eq!(column_of(c, Span::K48, c + 25), Some(961));
        assert_eq!(column_of(c, Span::K48, c - 1), Some(959));
        assert_eq!(column_of(c, Span::K48, c - 24_000), Some(0));
        assert_eq!(column_of(c, Span::K48, c + 23_999), Some(1_919));
        assert_eq!(column_of(c, Span::K48, c + 24_000), None);
        assert_eq!(column_of(c, Span::K48, c - 24_001), None);
        // an FT8 sub-band of 3 kHz is 120 columns at 48 kHz, 960 at 6 kHz, all 1,920 at 3 kHz
        assert_eq!(column_of(c, Span::K48, c + 1_500).unwrap() - column_of(c, Span::K48, c - 1_500).unwrap(), 120);
        assert_eq!(column_of(c, Span::FT8, c + 1_500).unwrap() - column_of(c, Span::FT8, c - 1_500).unwrap(), 960);
        assert_eq!(column_of(c, Span::NARROWEST, c - 1_500), Some(0));
        // the FT8 scale: the low edge at column 0, 3,000 Hz above it at column 1,172
        let low = c - FT8_LOW_EDGE_BELOW_CENTRE_HZ;
        assert_eq!(ft8_column_of(low, low), Some(0));
        assert_eq!(ft8_column_of(low, low + 1_500), Some(585));
        assert_eq!(ft8_column_of(low, low + 2_999), Some(1_171));
        assert_eq!(ft8_column_of(low, low - 1), None);
        assert_eq!(ft8_column_of(low, low + 4_916), None);
    }
}
