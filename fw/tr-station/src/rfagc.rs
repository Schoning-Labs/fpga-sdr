// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! RF AGC: sets the HL2's RX gain (the AD9866 PGA, -12 to +48 dB in 1 dB steps) from the power of
//! the whole band, measured on our side without any change to the logic. docs/HL2_CONTROL.md
//! section "RF AGC" has the measurement, its accuracy and its limits.
//!
//! **The measurement.** The full-band spectrum (docs/F2_SPECTRUM.md) writes one waterfall line of
//! 1,920 columns, 0 to 30 MHz, about 30 times a second into its DDR3 ring, whether or not a window
//! shows it. Each column byte is `clamp(((db64 + offset) * gain_q8) >> 14, 0, 255)` of the column's
//! power word in 1/64 dB (the level register `spectrum.level`), so with the reset level (offset 0,
//! 1 dB per index) a byte is the column's dB, rounded down. [`line_level`] turns every byte back
//! into a power word with the level the register holds, adds them up, and converts the sum to dBFS
//! of the ADC (0 dBFS = the power of a full-scale sine, amplitude 2,048).
//!
//! **Accuracy.** About +/-2 dB for the total: the bytes are whole dB (half a step is added back),
//! and in the spectrum's max mode (the one the radio uses) a column holds its strongest bin, not
//! the sum of its 3 or 4 bins. A fixed correction ([`MAX_MODE_CORRECTION_DB`]) centers that: white
//! noise then reads 0.7 dB low and a single carrier between 1.3 dB low and 1.6 dB high, depending
//! on where it falls in its column. Each line is the average over its 33 ms, so the measurement
//! sees average power only: it cannot see single clipped samples or short peaks, and it does not
//! see 30 to 38.4 MHz. The thresholds keep 12 dB or more of headroom below full scale for that.
//!
//! **The control.** [`RfAgc`] is pure logic: [`RfAgc::on_level`] takes each new reading and
//! decides; [`RfAgc::poll_write`] hands out the gain to send, at most one write per
//! [`AgcConfig::min_write_interval_ms`]. Fast attack: a total above the attack threshold, or a
//! column near full scale, takes the gain down at once by the excess. Slow recovery: once the
//! total has stayed below the recovery threshold for the hang time, the gain goes up 1 dB at a
//! time. Between the two thresholds the gain holds. The operator sets the lowest and highest gain
//! the AGC may use, and can switch to manual, where the gain changes only by hand.

use tr_fabric::mem::{map, FabricMem};
use tr_fabric::video::Video;
use tr_fabric::wfring::{mem_offset_of_column, LINE_BYTES, RING_LINES};
use tr_hl2::protocol::{RX_GAIN_MAX_DB, RX_GAIN_MIN_DB};
use tr_regs::generated::spectrum as sp;
use tr_regs::RegisterSpace;

/// Sum of the power words of every bin, in dB, that a 0 dBFS sine gives: 10 log10(2^21 x 16,384 x
/// sum(w^2) / 2^11) for the 16,384-point Blackman-Harris window (sum(w^2) = 4,226.5), the window's
/// gain of 8 and the rounding by 8 bits before the power (docs/F2_SPECTRUM.md, done-test theory).
pub const TOTAL_REF_DB: f32 = 108.51;
/// Power word in dB of a 0 dBFS sine in its own bin: (4 x 2,048 x sum(w) / 256)^2 with sum(w) =
/// 5,877.8. The -6 dBFS tone of the done-test reads 95.23 dB in mean mode, which is this minus 6
/// dB, minus 6.02 dB for its 4-bin column, plus 1.77 dB of main lobe.
pub const FS_SINE_BIN_DB: f32 = 105.50;
/// Added to the sum of a max-mode line (each column its strongest bin). White noise reads 3.2 dB
/// low without it, a carrier 0.9 to 3.8 dB low (numerical model of the window and column mapping).
pub const MAX_MODE_CORRECTION_DB: f32 = 2.5;
/// Added to the sum of a mean-mode line: each column is the mean of its bins, 10/3 of them on average.
pub const MEAN_MODE_CORRECTION_DB: f32 = 5.23;

/// One reading of the wide-band level.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct LevelReading {
    /// Total power of 0 to 30 MHz, dBFS.
    pub total_dbfs: f32,
    /// The strongest column, as dBFS of a sine in one bin.
    pub peak_dbfs: f32,
    /// Some column was at the top of the color scale: the true level is higher than read.
    pub clamped: bool,
}

/// Anything that gives a wide-band level now and then.
pub trait WidebandLevel {
    /// A new reading, or `None` if nothing new was measured since the last call.
    fn poll(&mut self) -> Option<LevelReading>;
}

/// The level of one full-band line: `bytes` are its column bytes, `level` the
/// `(offset_db64, gain_q8)` it was made with, `mean_mode` the spectrum's column mode. `None` for
/// an empty line or a gain of 0 (no scale to invert).
pub fn line_level(bytes: &[u8], level: (i16, u16), mean_mode: bool) -> Option<LevelReading> {
    let (off, gain) = level;
    if bytes.is_empty() || gain == 0 {
        return None;
    }
    let mut hist = [0u32; 256];
    for &b in bytes {
        hist[b as usize] += 1;
    }
    // byte b covers [b, b+1) steps of 16,384 / gain in 1/64 dB: take the middle
    let db_of = |b: usize| ((b as f32 + 0.5) * 16_384.0 / gain as f32 - off as f32) / 64.0;
    let mut sum = 0f32;
    let mut peak = 0usize;
    for (b, &n) in hist.iter().enumerate() {
        if n > 0 {
            sum += n as f32 * libm::powf(10.0, db_of(b) / 10.0);
            peak = b;
        }
    }
    let corr = if mean_mode { MEAN_MODE_CORRECTION_DB } else { MAX_MODE_CORRECTION_DB };
    Some(LevelReading { total_dbfs: 10.0 * libm::log10f(sum) - TOTAL_REF_DB + corr, peak_dbfs: db_of(peak) - FS_SINE_BIN_DB, clamped: hist[255] > 0 })
}

/// The full-band spectrum's waterfall lines, read back from their DDR3 ring
/// (`map::WATERFALL_RING`, the newest whole line in `video.wf_write_line`).
pub struct FullBandLevel<'a, R: RegisterSpace, M: FabricMem> {
    regs: &'a R,
    mem: &'a M,
    last_line: u32,
    buf: [u8; LINE_BYTES as usize],
    /// Lines measured.
    pub lines: u32,
}

impl<'a, R: RegisterSpace, M: FabricMem> FullBandLevel<'a, R, M> {
    /// Starts at the line the writer is on now (that one is not measured).
    pub fn new(regs: &'a R, mem: &'a M) -> Self {
        FullBandLevel { regs, mem, last_line: Video::new(regs).waterfall_line(), buf: [0; LINE_BYTES as usize], lines: 0 }
    }
}

impl<R: RegisterSpace, M: FabricMem> WidebandLevel for FullBandLevel<'_, R, M> {
    fn poll(&mut self) -> Option<LevelReading> {
        let ctrl = sp::ctrl::read(self.regs);
        if !ctrl.enable() {
            return None;
        }
        let line = Video::new(self.regs).waterfall_line();
        if line == self.last_line {
            return None;
        }
        self.last_line = line;
        let base = map::WATERFALL_RING + (line % RING_LINES) * LINE_BYTES;
        self.mem.invalidate(base, LINE_BYTES);
        for m in (0..LINE_BYTES).step_by(4) {
            let v = self.mem.read32(base + m);
            for k in 0..4 {
                // the CPU reads a lane word little-endian; column 0 is its top byte (tr_fabric::wfring)
                self.buf[mem_offset_of_column(m + k) as usize] = (v >> (8 * k)) as u8;
            }
        }
        let l = sp::level::read(self.regs);
        let r = line_level(&self.buf, (l.offset_db64() as u16 as i16, l.gain_q8() as u16), ctrl.column_mode())?;
        self.lines += 1;
        Some(r)
    }
}

/// Manual or automatic gain.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AgcMode {
    Manual,
    Auto,
}

/// Why the gain last changed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GainReason {
    /// The starting gain.
    Start,
    /// The operator's - or + (manual mode).
    Operator,
    /// The total was above the attack threshold.
    Overload,
    /// A column was near full scale.
    StrongSignal,
    /// Slow recovery after the hang time.
    Recovery,
    /// Moved into the operator's lowest to highest gain.
    Limit,
}

impl GainReason {
    /// A short word for the screen.
    pub fn name(self) -> &'static str {
        match self {
            GainReason::Start => "start",
            GainReason::Operator => "manual",
            GainReason::Overload => "overload",
            GainReason::StrongSignal => "strong signal",
            GainReason::Recovery => "recovery",
            GainReason::Limit => "limit",
        }
    }
}

/// Thresholds and times of the AGC.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AgcConfig {
    /// Total power above which the gain goes down at once, dBFS.
    pub attack_total_dbfs: f32,
    /// A column above this (dBFS of a sine) takes the gain down at once.
    pub attack_peak_dbfs: f32,
    /// Where an attack puts the total, dBFS.
    pub target_total_dbfs: f32,
    /// Where an attack puts the strongest column, dBFS.
    pub target_peak_dbfs: f32,
    /// Below this total the gain may come back up, dBFS.
    pub recover_below_dbfs: f32,
    /// Time below the recovery threshold before the first step up, ms.
    pub hang_ms: i64,
    /// Time between steps up of 1 dB, ms.
    pub recover_every_ms: i64,
    /// Readings within this time after a write are not used (the line may predate the new gain), ms.
    pub settle_ms: i64,
    /// Shortest time between two gain writes, ms (the HL2's command bus).
    pub min_write_interval_ms: i64,
    /// The operator's lowest and highest gain for the AGC, dB.
    pub min_gain_db: i32,
    pub max_gain_db: i32,
}

impl Default for AgcConfig {
    fn default() -> Self {
        AgcConfig {
            attack_total_dbfs: -22.0,
            attack_peak_dbfs: -12.0,
            target_total_dbfs: -28.0,
            target_peak_dbfs: -18.0,
            recover_below_dbfs: -34.0,
            hang_ms: 4_000,
            recover_every_ms: 1_000,
            settle_ms: 150,
            min_write_interval_ms: 250,
            min_gain_db: RX_GAIN_MIN_DB,
            max_gain_db: RX_GAIN_MAX_DB,
        }
    }
}

/// What the AGC reports.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AgcState {
    pub mode: AgcMode,
    /// The gain asked for, dB.
    pub gain_db: i32,
    /// The gain last handed out by [`RfAgc::poll_write`], dB.
    pub written_db: Option<i32>,
    /// Why the gain last changed.
    pub reason: GainReason,
    /// The last reading.
    pub level: Option<LevelReading>,
}

/// The RF AGC. See the module text.
#[derive(Clone, Debug)]
pub struct RfAgc {
    cfg: AgcConfig,
    mode: AgcMode,
    gain: i32,
    written: Option<i32>,
    last_write_ms: Option<i64>,
    /// Last time the level was not below the recovery threshold.
    last_loud_ms: i64,
    last_up_ms: i64,
    reason: GainReason,
    level: Option<LevelReading>,
    /// Gain writes handed out.
    pub writes: u32,
}

impl RfAgc {
    /// Manual at `start_db` (the session's starting RX gain).
    pub fn new(start_db: i32, cfg: AgcConfig) -> RfAgc {
        let mut a = RfAgc { cfg, mode: AgcMode::Manual, gain: 0, written: None, last_write_ms: None, last_loud_ms: 0, last_up_ms: 0, reason: GainReason::Start, level: None, writes: 0 };
        a.cfg.min_gain_db = cfg.min_gain_db.clamp(RX_GAIN_MIN_DB, RX_GAIN_MAX_DB);
        a.cfg.max_gain_db = cfg.max_gain_db.clamp(a.cfg.min_gain_db, RX_GAIN_MAX_DB);
        a.gain = start_db.clamp(RX_GAIN_MIN_DB, RX_GAIN_MAX_DB);
        a
    }

    pub fn config(&self) -> &AgcConfig {
        &self.cfg
    }

    pub fn state(&self) -> AgcState {
        AgcState { mode: self.mode, gain_db: self.gain, written_db: self.written, reason: self.reason, level: self.level }
    }

    pub fn mode(&self) -> AgcMode {
        self.mode
    }

    pub fn gain_db(&self) -> i32 {
        self.gain
    }

    /// Manual or automatic. Auto starts from the current gain, moved into the operator's limits.
    pub fn set_mode(&mut self, mode: AgcMode, now_ms: i64) {
        if mode == self.mode {
            return;
        }
        self.mode = mode;
        if mode == AgcMode::Auto {
            self.last_loud_ms = now_ms;
            self.last_up_ms = now_ms;
            self.clamp_to_limits();
        }
    }

    /// The operator's - (negative) or + (positive). In auto mode this switches to manual first.
    pub fn step(&mut self, db: i32) {
        self.mode = AgcMode::Manual;
        let g = (self.gain + db).clamp(RX_GAIN_MIN_DB, RX_GAIN_MAX_DB);
        if g != self.gain {
            self.gain = g;
            self.reason = GainReason::Operator;
        }
    }

    /// The operator's lowest and highest gain for the AGC.
    pub fn set_limits(&mut self, min_db: i32, max_db: i32) {
        self.cfg.min_gain_db = min_db.clamp(RX_GAIN_MIN_DB, RX_GAIN_MAX_DB);
        self.cfg.max_gain_db = max_db.clamp(self.cfg.min_gain_db, RX_GAIN_MAX_DB);
        if self.mode == AgcMode::Auto {
            self.clamp_to_limits();
        }
    }

    fn clamp_to_limits(&mut self) {
        let g = self.gain.clamp(self.cfg.min_gain_db, self.cfg.max_gain_db);
        if g != self.gain {
            self.gain = g;
            self.reason = GainReason::Limit;
        }
    }

    /// A new wide-band reading at `now_ms`.
    pub fn on_level(&mut self, now_ms: i64, r: LevelReading) {
        self.level = Some(r);
        if self.mode != AgcMode::Auto {
            return;
        }
        if self.last_write_ms.is_some_and(|t| now_ms - t < self.cfg.settle_ms) {
            return;
        }
        let c = self.cfg;
        // the gain the reading was made with: the one last written (the wanted one may not be out yet)
        let base = self.written.unwrap_or(self.gain);
        let over_total = r.total_dbfs - c.attack_total_dbfs;
        let over_peak = r.peak_dbfs - c.attack_peak_dbfs;
        if over_total > 0.0 || over_peak > 0.0 || r.clamped {
            self.last_loud_ms = now_ms;
            let by_total = r.total_dbfs - c.target_total_dbfs;
            let by_peak = if r.clamped { 12.0 } else { r.peak_dbfs - c.target_peak_dbfs };
            let down = libm::ceilf(by_total.max(by_peak)).max(1.0) as i32;
            let g = (base - down).max(c.min_gain_db);
            if g < self.gain {
                self.gain = g;
                self.reason = if by_peak > by_total { GainReason::StrongSignal } else { GainReason::Overload };
            }
            return;
        }
        if r.total_dbfs >= c.recover_below_dbfs {
            self.last_loud_ms = now_ms;
            return;
        }
        if self.gain < c.max_gain_db && now_ms - self.last_loud_ms >= c.hang_ms && now_ms - self.last_up_ms >= c.recover_every_ms && self.written == Some(self.gain) {
            self.gain += 1;
            self.last_up_ms = now_ms;
            self.reason = GainReason::Recovery;
        }
    }

    /// The gain to send now, if it differs from the one last sent and the last write is at least
    /// [`AgcConfig::min_write_interval_ms`] ago. The caller sends it (`Hl2Session::set_rx_gain_db`).
    pub fn poll_write(&mut self, now_ms: i64) -> Option<i32> {
        if self.written == Some(self.gain) {
            return None;
        }
        if self.last_write_ms.is_some_and(|t| now_ms - t < self.cfg.min_write_interval_ms) {
            return None;
        }
        self.written = Some(self.gain);
        self.last_write_ms = Some(now_ms);
        self.writes += 1;
        Some(self.gain)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The column byte of `db` at the reset level (offset 0, 1 dB per index).
    fn byte(db: f32) -> u8 {
        (db.floor()).clamp(0.0, 255.0) as u8
    }

    #[test]
    fn full_scale_sine_and_noise() {
        // A 0 dBFS carrier: its own bin at 105.5 dB plus the neighbor about 3.3 dB down in the
        // next column, everything else empty.
        let mut l = [0u8; 1_920];
        l[456] = byte(FS_SINE_BIN_DB);
        l[457] = byte(FS_SINE_BIN_DB - 3.3);
        let r = line_level(&l, (0, 256), false).unwrap();
        assert!(r.total_dbfs.abs() < 2.0, "{r:?}");
        assert!((r.peak_dbfs).abs() < 1.0, "{r:?}");
        assert!(!r.clamped);
        // ADC noise of sigma 4 LSB: -52.2 dBFS in 0 to 30 MHz. Mean power word per bin
        // 16 x 4,226.5 x 64 / 65,536 = 66.0 = 18.2 dB; the strongest of a column about 2.3 dB more.
        let l = [byte(20.5); 1_920];
        let r = line_level(&l, (0, 256), false).unwrap();
        assert!((r.total_dbfs + 52.2).abs() < 2.0, "{r:?}");
        // the level register is inverted: the same line at 2 indices per dB and +10 dB of offset
        let l2 = [((20.5 * 64.0 + 640.0) * 512.0 / 16_384.0) as u8; 1_920];
        let r2 = line_level(&l2, (640, 512), false).unwrap();
        assert!((r2.total_dbfs - r.total_dbfs).abs() < 0.5, "{r:?} {r2:?}");
        assert_eq!(line_level(&l, (0, 0), false), None);
        assert!(line_level(&[255; 4], (0, 256), false).unwrap().clamped);
    }

    #[test]
    fn full_band_line_read_back_from_the_ring() {
        use tr_fabric::mock::MockFabric;
        use tr_fabric::wfring::pack_line;
        use tr_regs::generated::video as vid;
        let f = MockFabric::new();
        let mut w = FullBandLevel::new(&f, &f);
        assert_eq!(w.poll(), None, "spectrum off");
        sp::ctrl::write(&f, sp::ctrl::Value(0).with_enable(true));
        sp::level::write(&f, sp::level::Value(0).with_gain_q8(256));
        assert_eq!(w.poll(), None, "no new line");
        let mut cols = [byte(20.5); 1_920];
        cols[1_000] = byte(FS_SINE_BIN_DB - 20.0);
        let base = map::WATERFALL_RING + 7 * LINE_BYTES;
        pack_line(&cols, |i, v| f.poke_mem(base + 4 * i, v));
        f.poke(vid::wf_write_line::addr(), 7);
        let r = w.poll().unwrap();
        assert!((r.peak_dbfs + 20.0).abs() < 1.0, "{r:?}");
        assert_eq!(r, line_level(&cols, (0, 256), false).unwrap());
        assert_eq!(w.poll(), None);
        assert_eq!(w.lines, 1);
    }

    fn reading(total: f32) -> LevelReading {
        LevelReading { total_dbfs: total, peak_dbfs: total - 20.0, clamped: false }
    }

    /// Runs the AGC for `ms` with a reading every 33 ms whose level follows the written gain.
    fn run(a: &mut RfAgc, t: &mut i64, ms: i64, level_at_0db: f32, writes: &mut Vec<(i64, i32)>) {
        let end = *t + ms;
        while *t < end {
            *t += 33;
            let g = a.state().written_db.unwrap_or(a.gain_db());
            a.on_level(*t, reading(level_at_0db + g as f32));
            if let Some(w) = a.poll_write(*t) {
                writes.push((*t, w));
            }
        }
    }

    #[test]
    fn attack_fast_recover_slow() {
        let mut a = RfAgc::new(20, AgcConfig::default());
        a.set_mode(AgcMode::Auto, 0);
        let (mut t, mut w) = (0i64, Vec::new());
        run(&mut a, &mut t, 1_000, -60.0, &mut w);
        assert_eq!(w, vec![(33, 20)], "quiet band at 20 dB: the start gain only");
        // a strong band: -60 + 20 = -40 becomes -10 dBFS at 20 dB, over the -22 threshold
        w.clear();
        run(&mut a, &mut t, 1_000, -30.0, &mut w);
        assert_eq!(a.state().reason, GainReason::Overload);
        assert!(w[0].1 <= 2, "one write takes it to the target (-28 dBFS): {w:?}");
        assert!(w.len() <= 2, "{w:?}");
        let low = a.gain_db();
        assert!(-30.0 + low as f32 <= -22.0);
        // the band goes quiet again: nothing for the hang time, then 1 dB a second
        w.clear();
        run(&mut a, &mut t, 3_900, -60.0, &mut w);
        assert!(w.is_empty(), "hang time: {w:?}");
        run(&mut a, &mut t, 5_000, -60.0, &mut w);
        assert!((4..=6).contains(&w.len()), "{w:?}");
        assert!(w.windows(2).all(|p| p[1].1 == p[0].1 + 1 && p[1].0 - p[0].0 >= 990), "{w:?}");
        assert_eq!(a.state().reason, GainReason::Recovery);
        // it stops once the total reaches the recovery threshold: -60 + 26 = -34 dBFS
        run(&mut a, &mut t, 60_000, -60.0, &mut w);
        assert_eq!(a.gain_db(), 26);
    }

    #[test]
    fn recovery_stops_at_the_threshold_and_limits_hold() {
        let mut cfg = AgcConfig::default();
        cfg.min_gain_db = 0;
        cfg.max_gain_db = 30;
        let mut a = RfAgc::new(20, cfg);
        a.set_mode(AgcMode::Auto, 0);
        let (mut t, mut w) = (0i64, Vec::new());
        // -60 dBFS at 0 dB: up from 20 dB until the total reaches -34 dBFS, not to the highest gain (30 dB)
        run(&mut a, &mut t, 60_000, -60.0, &mut w);
        assert_eq!(a.gain_db(), 26);
        // a huge overload: down to the lowest gain the operator allows, not below
        run(&mut a, &mut t, 2_000, 10.0, &mut w);
        assert_eq!(a.gain_db(), 0);
        // nothing but quiet: up to 30 dB, no higher
        run(&mut a, &mut t, 120_000, -90.0, &mut w);
        assert_eq!(a.gain_db(), 30);
        // limits narrowed while in auto: the gain follows
        a.set_limits(5, 25);
        assert_eq!((a.gain_db(), a.state().reason), (25, GainReason::Limit));
    }

    #[test]
    fn strong_column_and_clamped_line_attack() {
        let mut a = RfAgc::new(30, AgcConfig::default());
        a.set_mode(AgcMode::Auto, 0);
        assert_eq!(a.poll_write(0), Some(30));
        a.on_level(500, LevelReading { total_dbfs: -30.0, peak_dbfs: -5.0, clamped: false });
        assert_eq!((a.gain_db(), a.state().reason), (30 - 13, GainReason::StrongSignal));
        assert_eq!(a.poll_write(500), Some(17));
        a.on_level(1_000, LevelReading { total_dbfs: -40.0, peak_dbfs: -40.0, clamped: true });
        assert_eq!(a.gain_db(), 17 - 12);
    }

    #[test]
    fn manual_holds_and_writes_are_rate_limited() {
        let mut a = RfAgc::new(20, AgcConfig::default());
        assert_eq!(a.mode(), AgcMode::Manual);
        assert_eq!(a.poll_write(0), Some(20));
        // manual: a strong band does not move it
        a.on_level(1_000, reading(0.0));
        assert_eq!(a.gain_db(), 20);
        assert_eq!(a.poll_write(1_000), None);
        // ten presses within 100 ms: one write now, one with the sum 250 ms later
        for _ in 0..10 {
            a.step(1);
        }
        assert_eq!(a.poll_write(1_000), Some(30));
        a.step(-3);
        assert_eq!(a.poll_write(1_100), None);
        assert_eq!(a.poll_write(1_249), None);
        assert_eq!(a.poll_write(1_250), Some(27));
        assert_eq!(a.state().reason, GainReason::Operator);
        // the HL2's range is the end of the manual steps
        a.step(100);
        assert_eq!(a.gain_db(), RX_GAIN_MAX_DB);
        a.step(-100);
        assert_eq!(a.gain_db(), RX_GAIN_MIN_DB);
        // a press in auto mode switches to manual
        a.set_mode(AgcMode::Auto, 2_000);
        a.step(1);
        assert_eq!(a.mode(), AgcMode::Manual);
    }
}
