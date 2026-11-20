// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Full-band spectrum (`hw/regmap/spectrum.toml`, docs/F2_SPECTRUM.md): 0 to 38.4 MHz across
//! 1,920 columns, the source of the spectrum trace and the waterfall the logic draws.

use tr_regs::generated::spectrum as sp;
use tr_regs::RegisterSpace;

/// Transforms per second of the 16,384-point FFT at 76.8 Msps.
pub const TRANSFORMS_PER_S: f32 = 4_687.5;

/// Driver for the full-band spectrum page.
pub struct Spectrum<'a, R: RegisterSpace> {
    regs: &'a R,
}

impl<'a, R: RegisterSpace> Spectrum<'a, R> {
    /// A driver on the register space `regs`.
    pub fn new(regs: &'a R) -> Self {
        Spectrum { regs }
    }

    /// The identification register of the block.
    pub fn id(&self) -> u32 {
        sp::id::read(self.regs)
    }

    /// Starts the spectrum at about `lines_per_s` output lines (waterfall rows) per second.
    /// `mean_per_column` false keeps the strongest bin of each column (narrow signals stay visible).
    pub fn start(&self, lines_per_s: u32, mean_per_column: bool, peak_hold: bool) {
        let k = (TRANSFORMS_PER_S / lines_per_s.max(1) as f32 + 0.5) as u32;
        sp::averaging_k::write(self.regs, k.max(1));
        sp::ctrl::write(self.regs, sp::ctrl::Value(0).with_enable(true).with_column_mode(mean_per_column).with_peak_hold(peak_hold));
    }

    /// Stops the spectrum.
    pub fn stop(&self) {
        sp::ctrl::modify(self.regs, |v| v.with_enable(false));
    }

    /// Waterfall color mapping: `offset_db64` (signed, 1/64 dB) is added and the result scaled by
    /// `gain_q8` (Q8.8) before the 8-bit color index.
    pub fn set_level(&self, offset_db64: i16, gain_q8: u16) {
        sp::level::write(self.regs, sp::level::Value(0).with_offset_db64(offset_db64 as u16 as u32).with_gain_q8(gain_q8 as u32));
    }

    /// Lines produced so far (free-running).
    pub fn line_count(&self) -> u32 {
        sp::line_count::read(self.regs)
    }

    /// Which of the two line buffers holds the newest whole line.
    pub fn ready_buffer(&self) -> u32 {
        sp::line_status::read(self.regs).ready_buffer() as u32
    }

    /// Clears the line-done flag.
    pub fn clear_line_done(&self) {
        sp::line_status::clear_line_done(self.regs);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mock::MockFabric;

    #[test]
    fn start_and_level() {
        let f = MockFabric::new();
        let s = Spectrum::new(&f);
        s.start(30, false, false);
        assert_eq!(f.reg(sp::averaging_k::addr()), 156);
        assert_eq!(f.reg(sp::ctrl::addr()), 1);
        s.set_level(-640, 0x0180);
        assert_eq!(f.reg(sp::level::addr()), 0x0180_FD80);
        s.stop();
        assert_eq!(f.reg(sp::ctrl::addr()), 0);
        f.poke(sp::line_status::addr(), 1);
        assert_eq!(s.ready_buffer(), 1);
    }
}
