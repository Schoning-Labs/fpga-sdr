// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Color level of the zoom receiver's hardware waterfall (docs/LISTEN.md section 8): the level register
//! (`zoom.backend_level`) is set so that the noise floor of the band lands on a dark blue of the
//! palette, whatever the noise is, with the operator's floor and range applied on top of that. The
//! main type is [`WfLevel`], which the LISTEN screen feeds with every new waterfall line.
//!
//! **What the logic does with the level** (`rtl/spectrum/spectrum_pipeline.v`, the zoom context's
//! color byte): `byte = clamp(((line_db64 + offset_db64) * gain_q8) >> 14, 0, 255)`, where
//! `line_db64` is 10 log10 of a column's power word in 1/64 dB (0 dB = one step of the 21-bit
//! components squared; a column whose power word is 0 gives -512 dB, so index 0). So
//! `gain_q8 = 65,536 / range_db` puts `range_db` decibels on the 256 palette entries, and
//! `offset_db64` moves the scale.
//!
//! **Automatic floor.** Every new waterfall line is read back from the ring (its visible
//! columns). Its 25th percentile is the noise floor: turned back into the line's dB with the level
//! the line was made with, it updates a running estimate (half the difference per line), and the
//! offset is set so that the estimate lands on palette index [`FLOOR_INDEX`]. A percentile of 0
//! or 255 says only "below" or "above" the scale: the estimate then moves by half the range. The
//! line made right after a level change is not measured (it may have been made with the old one).
//!
//! **Operator.** `floor_db` moves the black end of the scale up (darker background, + values) or
//! down (brighter), in dB, from where the automatic floor puts it; `range_db` is the span of the
//! palette in dB. With the floor moved so far that the noise is black (or white) on purpose, the
//! estimate is held.

/// Palette index the noise floor (the 25th percentile of a line) is put at: a dark blue of
/// `tr_fabric::video::default_palette` (0 is black).
pub const FLOOR_INDEX: i32 = 32;
/// Ranges the operator can choose, dB from black to white.
pub const RANGES_DB: [u32; 8] = [20, 30, 40, 50, 60, 80, 100, 120];
/// The range used until the operator picks another one, dB.
pub const DEFAULT_RANGE_DB: u32 = 60;
/// Step of the operator's floor control, dB.
pub const FLOOR_STEP_DB: i32 = 3;
/// The operator's floor is limited to plus or minus this many dB.
pub const FLOOR_LIMIT_DB: i32 = 30;
/// Limits of the noise floor estimate, 1/64 dB of the line.
const EST_MIN_DB64: i32 = -20 * 64;
const EST_MAX_DB64: i32 = 130 * 64;

/// The range after `steps` steps through [`RANGES_DB`] from `range_db`.
pub fn range_step(range_db: u32, steps: i32) -> u32 {
    let i = RANGES_DB.iter().position(|r| *r >= range_db).unwrap_or(RANGES_DB.len() - 1) as i32;
    RANGES_DB[(i + steps).clamp(0, RANGES_DB.len() as i32 - 1) as usize]
}

/// The floor after `steps` steps.
pub fn floor_step(floor_db: i32, steps: i32) -> i32 {
    (floor_db + steps * FLOOR_STEP_DB).clamp(-FLOOR_LIMIT_DB, FLOOR_LIMIT_DB)
}

/// What one waterfall line held (its visible columns): palette indices.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LineStats {
    /// Number of columns measured.
    pub columns: u32,
    /// Columns at index 0 (black).
    pub zeros: u32,
    /// The 25th percentile.
    pub low: u8,
    /// Mean palette index.
    pub mean: u8,
    /// Highest palette index.
    pub peak: u8,
}

impl LineStats {
    /// Measures one line of palette indices (an empty line gives all zeros).
    pub fn of(bytes: &[u8]) -> LineStats {
        let mut hist = [0u32; 256];
        let mut sum = 0u64;
        let mut peak = 0u8;
        for &b in bytes {
            hist[b as usize] += 1;
            sum += b as u64;
            peak = peak.max(b);
        }
        let n = bytes.len() as u32;
        if n == 0 {
            return LineStats::default();
        }
        // the smallest index with at least a quarter of the columns at or below it
        let want = n.div_ceil(4);
        let mut acc = 0;
        let mut low = 255u8;
        for (i, h) in hist.iter().enumerate() {
            acc += h;
            if acc >= want {
                low = i as u8;
                break;
            }
        }
        LineStats { columns: n, zeros: hist[0], low, mean: (sum / n as u64) as u8, peak }
    }
}

/// The state behind the level of the zoom waterfall. See the module text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WfLevel {
    /// Noise floor of a line, 1/64 dB of the line.
    floor_est: i32,
    /// The operator's floor offset, dB.
    floor_db: i32,
    /// The operator's range, dB.
    range_db: u32,
    /// The level last given out (the register holds it).
    applied: (i16, u16),
    /// Lines not to measure (made before the last level change).
    skip: u32,
    /// Lines measured.
    pub lines: u32,
    /// The last line seen.
    pub last: LineStats,
}

impl WfLevel {
    /// A first estimate of the floor: 0 dB, a column power of one step (the noise of the 12 kHz
    /// span at a gain of 64 with no antenna is about 2 dB, docs/LISTEN.md section 8).
    pub fn new(floor_db: i32, range_db: u32) -> WfLevel {
        let mut w = WfLevel { floor_est: 0, floor_db: floor_db.clamp(-FLOOR_LIMIT_DB, FLOOR_LIMIT_DB), range_db: range_step(range_db, 0), applied: (0, 0), skip: 1, lines: 0, last: LineStats::default() };
        w.applied = w.level();
        w
    }

    /// The operator's floor offset, dB.
    pub fn floor_db(&self) -> i32 {
        self.floor_db
    }

    /// The operator's range, dB from black to white.
    pub fn range_db(&self) -> u32 {
        self.range_db
    }

    /// The noise floor estimate, dB of the line.
    pub fn floor_estimate_db(&self) -> f32 {
        self.floor_est as f32 / 64.0
    }

    /// `(offset_db64, gain_q8)` for the level register.
    pub fn level(&self) -> (i16, u16) {
        let gain = (65_536 / self.range_db.max(1)).min(0xFFFF);
        // the floor's index in 1/64 dB of the scale: FLOOR_INDEX * 64 * 256 / gain
        let index_db64 = FLOOR_INDEX * 16_384 / gain as i32;
        let off = (index_db64 - self.floor_est - self.floor_db * 64).clamp(-32_768, 32_767);
        (off as i16, gain as u16)
    }

    /// The level the last line was made with (as far as this module knows).
    pub fn applied(&self) -> (i16, u16) {
        self.applied
    }

    /// The line's dB (1/64) of palette index `b` under the level `(off, gain)`: the inverse of the logic's mapping.
    pub fn db64_of_index(b: u8, (off, gain): (i16, u16)) -> i32 {
        ((b as i32 * 16_384 + gain as i32 / 2) / (gain as i32).max(1)) - off as i32
    }

    /// New operator settings. Returns the level to write.
    pub fn set(&mut self, floor_db: i32, range_db: u32) -> (i16, u16) {
        self.floor_db = floor_db.clamp(-FLOOR_LIMIT_DB, FLOOR_LIMIT_DB);
        self.range_db = range_step(range_db, 0);
        self.give_out()
    }

    fn give_out(&mut self) -> (i16, u16) {
        let l = self.level();
        if l != self.applied {
            self.applied = l;
            self.skip = 1;
        }
        l
    }

    /// One new waterfall line, its visible columns as the logic wrote them. Returns the level to
    /// write if it changed.
    pub fn line(&mut self, bytes: &[u8]) -> Option<(i16, u16)> {
        let s = LineStats::of(bytes);
        self.last = s;
        if s.columns == 0 {
            return None;
        }
        if self.skip > 0 {
            self.skip -= 1;
            return None;
        }
        self.lines += 1;
        let half_range = self.range_db as i32 * 32;
        // where the floor should be on the palette with the operator's floor
        let expected = FLOOR_INDEX - self.floor_db * 256 / self.range_db as i32;
        if s.low == 0 {
            if expected > 8 {
                self.floor_est -= half_range;
            }
        } else if s.low == 255 {
            if expected < 247 {
                self.floor_est += half_range;
            }
        } else {
            let measured = Self::db64_of_index(s.low, self.applied);
            self.floor_est += (measured - self.floor_est) / 2;
        }
        self.floor_est = self.floor_est.clamp(EST_MIN_DB64, EST_MAX_DB64);
        let before = self.applied;
        let l = self.give_out();
        (l != before).then_some(l)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The logic's color byte (spectrum_pipeline.v, zoom context).
    fn byte(db64: i32, (off, gain): (i16, u16)) -> u8 {
        let p = ((db64 + off as i32) as i64 * gain as i64) >> 14;
        p.clamp(0, 255) as u8
    }

    /// A line of noise whose columns are spread around `floor_db` (deterministic, a few dB each way).
    fn noise_line(floor_db: f32, level: (i16, u16)) -> [u8; 1_172] {
        let mut l = [0u8; 1_172];
        let mut x = 12_345u32;
        for b in l.iter_mut() {
            x = x.wrapping_mul(1_103_515_245).wrapping_add(12_345);
            let d = ((x >> 16) % 13) as f32 - 4.0; // -4 .. +8 dB
            *b = byte(((floor_db + d) * 64.0) as i32, level);
        }
        l
    }

    #[test]
    fn scale_and_inverse() {
        let w = WfLevel::new(0, DEFAULT_RANGE_DB);
        let (off, gain) = w.level();
        // 60 dB over the palette, the estimate (0 dB) at index 32: offset 7.5 dB
        assert_eq!(gain, 1_092);
        assert_eq!(off, 480);
        assert_eq!(byte(0, (off, gain)), 31);
        assert_eq!(byte(64, (off, gain)), 36);
        // a fixed level of -24.08 dB offset and 1 dB per index puts a column 24 dB above one step at index 0
        assert_eq!(byte(24 * 64, (-1_542, 256)), 0);
        for b in [1u8, 31, 100, 254] {
            let d = WfLevel::db64_of_index(b, (off, gain));
            assert!((byte(d, (off, gain)) as i32 - b as i32).abs() <= 1, "{b}: {d}");
        }
        assert_eq!(range_step(60, 1), 80);
        assert_eq!(range_step(60, -1), 50);
        assert_eq!(range_step(120, 1), 120);
        assert_eq!(range_step(20, -5), 20);
        assert_eq!(range_step(55, 0), 60);
        assert_eq!(floor_step(0, 1), 3);
        assert_eq!(floor_step(29, 1), 30);
        assert_eq!(floor_step(-30, -1), -30);
        let s = LineStats::of(&[0, 0, 10, 20, 30, 40, 50, 255]);
        assert_eq!((s.columns, s.zeros, s.low, s.peak, s.mean), (8, 2, 0, 255, 50));
        let s = LineStats::of(&[5; 100]);
        assert_eq!((s.low, s.mean, s.peak, s.zeros), (5, 5, 5, 0));
    }

    #[test]
    fn floor_lands_on_the_floor_index_from_far_below_and_far_above() {
        for true_floor in [-8.0f32, 2.0, 30.0, 95.0] {
            let mut w = WfLevel::new(0, DEFAULT_RANGE_DB);
            let mut level = w.level();
            for _ in 0..40 {
                if let Some(l) = w.line(&noise_line(true_floor, level)) {
                    level = l;
                }
            }
            let s = LineStats::of(&noise_line(true_floor, level));
            assert!((s.low as i32 - FLOOR_INDEX).abs() <= 6, "floor {true_floor} dB: low {} (index {FLOOR_INDEX})", s.low);
            assert!(s.zeros == 0, "floor {true_floor} dB: {} black columns", s.zeros);
        }
    }

    #[test]
    fn operator_floor_and_range_move_the_scale_and_hold_the_estimate() {
        let mut w = WfLevel::new(0, DEFAULT_RANGE_DB);
        let mut level = w.level();
        for _ in 0..30 {
            if let Some(l) = w.line(&noise_line(10.0, level)) {
                level = l;
            }
        }
        let est = w.floor_estimate_db();
        let base = LineStats::of(&noise_line(10.0, level)).low as i32;
        // floor +6 dB at 60 dB: the noise 25 or 26 indices darker
        level = w.set(6, 60);
        for _ in 0..10 {
            if let Some(l) = w.line(&noise_line(10.0, level)) {
                level = l;
            }
        }
        let darker = LineStats::of(&noise_line(10.0, level)).low as i32;
        assert!((base - darker - 26).abs() <= 2, "{base} -> {darker}");
        // floor +30 dB: the noise is black on purpose; the estimate holds
        level = w.set(30, 60);
        for _ in 0..10 {
            if let Some(l) = w.line(&noise_line(10.0, level)) {
                level = l;
            }
        }
        assert!((w.floor_estimate_db() - est).abs() < 1.0, "{est} -> {}", w.floor_estimate_db());
        // range 30 dB: twice the indices per dB, the floor still near its index
        level = w.set(0, 30);
        assert_eq!(level.1, 2_184);
        for _ in 0..10 {
            if let Some(l) = w.line(&noise_line(10.0, level)) {
                level = l;
            }
        }
        let s = LineStats::of(&noise_line(10.0, level));
        assert!((s.low as i32 - FLOOR_INDEX).abs() <= 8, "{}", s.low);
    }

    #[test]
    fn the_line_after_a_change_is_not_measured() {
        let mut w = WfLevel::new(0, 60);
        // the first line is skipped (made before the level was written)
        assert_eq!(w.line(&[0; 100]), None);
        assert_eq!(w.lines, 0);
        assert!(w.line(&[0; 100]).is_some(), "all black: the floor estimate goes down by half the range");
        assert_eq!(w.lines, 1);
        assert_eq!(w.floor_estimate_db(), -20.0, "down by half the range (30 dB), held at the lower limit");
        // the next is skipped again
        assert_eq!(w.line(&[0; 100]), None);
        assert_eq!(w.lines, 1);
    }
}
