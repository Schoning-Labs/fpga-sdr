// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Video (`hw/regmap/video.toml`, docs/V2_COMPOSITOR.md): the two Slint frame buffers, the up to
//! four windows the logic draws into (spectrum trace or waterfall, shown where the Slint layer
//! holds the key color), the waterfall palette and the status the compositor reports.
//!
//! What the firmware has to do to show a frame (V2_COMPOSITOR.md
//! section 6), and where it is done:
//!
//! 1. Draw RGB565 into a buffer: stride [`STRIDE`] (3,840 bytes), base a multiple of 8
//!    ([`FrameBuffers::new`] checks), key color [`KEY_COLOUR`] in every window rectangle (the
//!    screen's, and the register `key` written by [`Video::start`]), data cache written back
//!    ([`FrameBuffers::present`]).
//! 2. Windows ([`Video::set_window`]), palette ([`Video::set_palette`]), `fb_stride`, `key`.
//! 3. `ctrl.enable` ([`Video::start`]) only once the first frame is in DDR3: until then the
//!    compositor shows its own color bars and reads no DDR3.
//! 4. Swap: `fb_base` after the cache write-back and the 10 us wait ([`FrameBuffers::present`]);
//!    the old buffer is free once `fb_active` reads the new base ([`FrameBuffers::back_free`]).
//! 5. [`Video::status`] shows underruns and lane errors; they are the first thing to look at when
//!    the picture tears on the board.

use tr_regs::generated::video as vid;
use tr_regs::RegisterSpace;

use crate::mem::{flush_for_logic, FabricMem, Flushed};

pub const WIDTH: u32 = 1_920;
pub const HEIGHT: u32 = 1_080;
/// Bytes per frame buffer line (RGB565): the compositor's `fb_stride` reset value.
pub const STRIDE: u32 = WIDTH * 2;
/// The color the Slint layer leaves where the logic draws (RGB565 magenta); the `key` register's
/// reset value, written anyway.
pub const KEY_COLOUR: u16 = 0xF81F;
pub const WINDOWS: u32 = 4;
/// Windows that can be waterfalls (two waterfall line buffers in the chip).
pub const WATERFALL_WINDOWS: u32 = 2;
/// A swap that `fb_active` has not confirmed after this long is given up on ([`FrameBuffers::back_free`]).
pub const SWAP_TIMEOUT_MS: u32 = 100;

/// Whose scroll line a waterfall window follows (`wf_win_ctrl.line_src`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WaterfallSource {
    /// The full-band spectrum's hardware writer.
    FullBand,
    /// The zoom spectrum's hardware writer.
    Zoom,
    /// A line the CPU writes (`wfring::SoftWaterfall` owns the window then).
    Cpu,
}

/// What a window shows.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WindowKind {
    SpectrumTrace,
    Waterfall,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Window {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
    pub kind: WindowKind,
    /// Zoom spectrum instead of the full band (trace windows; the zoom is not in the chip yet).
    pub zoom: bool,
    /// First source column: window column 0 shows source column `src_x0` (spectrum line or
    /// waterfall line, 0-1,919).
    pub src_x0: u32,
}

/// Why a window was not placed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WindowError {
    /// Index 4 or more.
    NoSuchWindow,
    /// A waterfall in window 2 or 3 (only 0 and 1 can be).
    NotWaterfallCapable,
    /// Empty, or past the 1,920 x 1,080 screen, or source columns past 1,920.
    BadGeometry,
}

/// The compositor's status registers.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct VideoStatus {
    /// Sticky: a displayed line was not in its line buffer in time.
    pub underrun: bool,
    /// Sticky: a DDR3 read burst was not granted or delivered in time.
    pub lane_error: bool,
    /// Underrun lines since the last [`Video::clear_status`] (counted only while enabled).
    pub underrun_count: u32,
    /// Frames shown since reset.
    pub frame_count: u32,
}

impl VideoStatus {
    /// True if the compositor reports neither an underrun nor a lane error.
    pub fn healthy(&self) -> bool {
        !self.underrun && !self.lane_error
    }
}

/// Driver for the video page.
pub struct Video<'a, R: RegisterSpace> {
    regs: &'a R,
}

impl<'a, R: RegisterSpace> Video<'a, R> {
    /// A driver on the register space `regs`.
    pub fn new(regs: &'a R) -> Self {
        Video { regs }
    }

    /// The identification register of the block.
    pub fn id(&self) -> u32 {
        vid::id::read(self.regs)
    }

    /// Writes the key color. The compositor shows the FPGA layer where the Slint layer holds it.
    pub fn set_key_colour(&self, rgb565: u16) {
        vid::key::write(self.regs, vid::key::Value(0).with_rgb565(rgb565 as u32));
    }

    /// Shows the composed picture (from the next vertical blank) instead of color bars. Call it
    /// once the first frame has been presented and the windows and palette are set. `mode_30hz`
    /// is informational (the mode is chosen at build time).
    pub fn start(&self, mode_30hz: bool) {
        self.set_key_colour(KEY_COLOUR);
        vid::ctrl::write(self.regs, vid::ctrl::Value(0).with_enable(true).with_mode_30hz(mode_30hz));
    }

    /// Back to the compositor's color bars (and no DDR3 reads).
    pub fn stop(&self) {
        vid::ctrl::write(self.regs, vid::ctrl::Value(0));
    }

    /// Places window `index` (0-3) and shows it. The window and its key-color rectangle in the
    /// Slint layer must be moved together by the caller. Windows must not overlap.
    pub fn set_window(&self, index: u32, win: &Window) -> Result<(), WindowError> {
        if index >= WINDOWS {
            return Err(WindowError::NoSuchWindow);
        }
        if win.kind == WindowKind::Waterfall && index >= WATERFALL_WINDOWS {
            return Err(WindowError::NotWaterfallCapable);
        }
        if win.w == 0 || win.h == 0 || win.x + win.w > WIDTH || win.y + win.h > HEIGHT || win.src_x0 >= WIDTH {
            return Err(WindowError::BadGeometry);
        }
        vid::win_ctrl::write(self.regs, index, vid::win_ctrl::Value(0));
        vid::win_pos::write(self.regs, index, vid::win_pos::Value(0).with_x(win.x).with_y(win.y));
        vid::win_size::write(self.regs, index, vid::win_size::Value(0).with_w(win.w).with_h(win.h));
        vid::win_src::write(self.regs, index, vid::win_src::Value(0).with_x0(win.src_x0));
        let ctrl = vid::win_ctrl::Value(0).with_enable(true).with_type_waterfall(win.kind == WindowKind::Waterfall).with_source_zoom(win.zoom);
        vid::win_ctrl::write(self.regs, index, ctrl);
        Ok(())
    }

    /// Stops the logic from drawing window `index`.
    pub fn hide_window(&self, index: u32) {
        vid::win_ctrl::modify(self.regs, index, |v| v.with_enable(false));
    }

    /// Loads the 256-entry palette of waterfall window `which` (0 or 1), colors as 0xRRGGBB.
    /// Takes effect at once (not at the vertical blank).
    pub fn set_palette(&self, which: u32, rgb: &[u32; 256]) {
        for (i, &c) in rgb.iter().enumerate() {
            vid::palette_index::write(self.regs, vid::palette_index::Value(0).with_value(i as u32).with_which(which & 1 != 0));
            vid::palette_data::write(self.regs, vid::palette_data::Value(0).with_rgb(c));
        }
    }

    /// Tells the full-band hardware waterfall writer where its ring is (CPU byte address, a
    /// multiple of 8; the register counts 64-bit lane words). Call before the spectrum is started.
    pub fn set_waterfall_ring(&self, addr: u32) {
        vid::wf_ring_base::write(self.regs, addr / 8);
    }

    /// The same for the zoom spectrum's writer.
    pub fn set_zoom_waterfall_ring(&self, addr: u32) {
        vid::wf_zoom_ring_base::write(self.regs, addr / 8);
    }

    /// Waterfall window `window` (0 or 1) shows the ring at `ring_addr` (CPU byte address) and
    /// scrolls with a hardware writer's line: give the address that writer's ring was set to.
    /// (`WaterfallSource::Cpu` is set up by `wfring::SoftWaterfall`, which also writes the line.)
    pub fn show_hardware_waterfall(&self, window: u32, source: WaterfallSource, ring_addr: u32) -> Result<(), WindowError> {
        if window >= WATERFALL_WINDOWS {
            return Err(WindowError::NotWaterfallCapable);
        }
        let src = match source {
            WaterfallSource::FullBand => 0,
            WaterfallSource::Zoom => 1,
            WaterfallSource::Cpu => return Err(WindowError::BadGeometry),
        };
        vid::wf_win_ring::write(self.regs, window, ring_addr / 8);
        vid::wf_win_ctrl::write(self.regs, window, vid::wf_win_ctrl::Value(0).with_line_src(src));
        Ok(())
    }

    /// Newest whole line of the full-band hardware writer, 0-2,047.
    pub fn waterfall_line(&self) -> u32 {
        vid::wf_write_line::read(self.regs)
    }

    /// Newest whole line of the zoom hardware writer, 0-2,047.
    pub fn zoom_waterfall_line(&self) -> u32 {
        vid::wf_zoom_write_line::read(self.regs)
    }

    /// Ring line waterfall window `window` shows in its top row in the current frame.
    pub fn waterfall_top_line(&self, window: u32) -> u32 {
        vid::wf_win_top::read(self.regs, window & 1)
    }

    /// Underrun and lane-error flags and counters.
    pub fn status(&self) -> VideoStatus {
        let s = vid::status::read(self.regs);
        VideoStatus {
            underrun: s.underrun(),
            lane_error: s.lane_error(),
            underrun_count: vid::underrun_count::read(self.regs),
            frame_count: vid::frame_count::read(self.regs),
        }
    }

    /// Clears both sticky flags (and with `underrun`, the counter).
    pub fn clear_status(&self) {
        vid::status::clear_lane_error(self.regs);
        vid::status::clear_underrun(self.regs);
    }

    /// The frame buffer base the compositor has taken over (`fb_active`).
    pub fn fb_active(&self) -> u32 {
        vid::fb_active::read(self.regs)
    }
}

/// A dark blue to yellow to white waterfall palette, 0xRRGGBB.
pub fn default_palette() -> [u32; 256] {
    let mut p = [0u32; 256];
    let mut i = 0;
    while i < 256 {
        let v = i as u32;
        // red rises over the upper two thirds, green over the middle, blue is high first and last
        let r = if v < 96 { 0 } else { ((v - 96) * 255 / 159).min(255) };
        let g = if v < 48 { 0 } else { ((v - 48) * 255 / 160).min(255) };
        let b = if v < 96 { v * 255 / 96 } else if v < 192 { (192 - v) * 255 / 96 } else { (v - 192) * 255 / 63 };
        p[i] = (r << 16) | (g << 8) | b.min(255);
        i += 1;
    }
    p
}

/// The two frame buffers and the pointer the logic scans out from.
pub struct FrameBuffers<'a, R: RegisterSpace, M: FabricMem> {
    regs: &'a R,
    mem: &'a M,
    addr: [u32; 2],
    front: usize,
    /// A swap written at this time (ms) that `fb_active` has not confirmed yet.
    pending: Option<u32>,
    /// Swaps given up on after [`SWAP_TIMEOUT_MS`] (the compositor did not confirm).
    pub swap_timeouts: u32,
}

impl<'a, R: RegisterSpace, M: FabricMem> FrameBuffers<'a, R, M> {
    /// Sets `fb_stride` and points the logic at buffer 0 (whatever it holds: keep `ctrl.enable`
    /// off until the first [`present`](Self::present)); buffer 1 is the one to draw into. The
    /// base addresses must be multiples of 8 (the lane word).
    pub fn new(regs: &'a R, mem: &'a M, addr: [u32; 2]) -> Self {
        assert!(addr[0] % 8 == 0 && addr[1] % 8 == 0, "frame buffer base must be a multiple of 8");
        vid::fb_stride::write(regs, STRIDE);
        vid::fb_base::write(regs, addr[0]);
        FrameBuffers { regs, mem, addr, front: 0, pending: None, swap_timeouts: 0 }
    }

    /// CPU byte address of the buffer to draw the next frame into (`STRIDE * HEIGHT` bytes). Only
    /// draw into it when [`back_free`](Self::back_free) is true.
    pub fn back_addr(&self) -> u32 {
        self.addr[1 - self.front]
    }

    /// True when the buffer to draw into is not in use: no swap is pending, or `fb_active` now
    /// shows the new base (the previous front buffer is then free). A swap that is not confirmed
    /// within [`SWAP_TIMEOUT_MS`] counts in `swap_timeouts` and frees the buffer anyway.
    pub fn back_free(&mut self, now_ms: u32) -> bool {
        let Some(since) = self.pending else { return true };
        if vid::fb_active::read(self.regs) == self.addr[self.front] {
            self.pending = None;
            return true;
        }
        if now_ms.wrapping_sub(since) >= SWAP_TIMEOUT_MS {
            self.pending = None;
            self.swap_timeouts += 1;
            return true;
        }
        false
    }

    /// Shows the back buffer: its lines `first_line .. first_line + lines` (the ones drawn since it
    /// was last shown) are written back from the data cache to DDR3, the 10 us wait is taken, then
    /// `fb_base` moves to it (the swap happens at the next vertical blank) and the other buffer
    /// becomes the back buffer, free again when [`back_free`](Self::back_free) says so.
    pub fn present(&mut self, first_line: u32, lines: u32, now_ms: u32) {
        let back = self.back_addr();
        let first = first_line.min(HEIGHT);
        let n = lines.min(HEIGHT - first);
        let proof = flush_for_logic(self.mem, &[(back + first * STRIDE, n * STRIDE)]);
        self.show(back, proof);
        self.front = 1 - self.front;
        self.pending = Some(now_ms);
    }

    fn show(&self, addr: u32, _flushed: Flushed) {
        vid::fb_base::write(self.regs, addr);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mem::map::FRAME_BUFFER;
    use crate::mock::{Ev, MockFabric};

    #[test]
    fn windows_key_and_palette() {
        let f = MockFabric::new();
        let v = Video::new(&f);
        let win = Window { x: 10, y: 150, w: 1_446, h: 500, kind: WindowKind::Waterfall, zoom: false, src_x0: 8 };
        assert_eq!(v.set_window(1, &win), Ok(()));
        assert_eq!(f.reg(vid::win_pos::addr(1)), 10 | (150 << 16));
        assert_eq!(f.reg(vid::win_size::addr(1)), 1_446 | (500 << 16));
        assert_eq!(f.reg(vid::win_src::addr(1)), 8);
        assert_eq!(f.reg(vid::win_ctrl::addr(1)), 0b011);
        // Hidden while it is moved: the first write to its control register is 0.
        assert_eq!(f.reg_writes(vid::win_ctrl::addr(1)), [0, 3]);
        // Waterfalls only in windows 0 and 1; geometry checked; trace windows allowed anywhere.
        assert_eq!(v.set_window(2, &win), Err(WindowError::NotWaterfallCapable));
        assert_eq!(v.set_window(4, &win), Err(WindowError::NoSuchWindow));
        assert_eq!(v.set_window(0, &Window { w: 1_911, x: 10, ..win }), Err(WindowError::BadGeometry));
        assert_eq!(v.set_window(0, &Window { h: 0, ..win }), Err(WindowError::BadGeometry));
        assert_eq!(v.set_window(3, &Window { kind: WindowKind::SpectrumTrace, ..win }), Ok(()));
        assert_eq!(f.reg(vid::win_ctrl::addr(3)), 0b001);
        // The key color is written by start, together with the enable bit.
        f.clear_log();
        v.start(false);
        assert_eq!(f.reg(vid::key::addr()), 0xF81F);
        assert_eq!(f.reg(vid::ctrl::addr()), 1);
        assert_eq!(*f.log.borrow(), [Ev::RegWrite(vid::key::addr(), 0xF81F), Ev::RegWrite(vid::ctrl::addr(), 1)]);
        v.stop();
        assert_eq!(f.reg(vid::ctrl::addr()), 0);

        // Palette: 24-bit colors, index and palette select in one register, data written second.
        let p = default_palette();
        v.set_palette(1, &p);
        let idx = f.reg_writes(vid::palette_index::addr());
        assert_eq!(idx.len(), 256);
        assert_eq!(idx[0], 1 << 8);
        assert_eq!(idx[255], (1 << 8) | 255);
        assert_eq!(f.reg_writes(vid::palette_data::addr())[255], 0xFF_FF_FF);
        v.set_palette(0, &p);
        assert_eq!(f.reg_writes(vid::palette_index::addr())[256], 0);
        // index and data alternate, index first
        let order: alloc::vec::Vec<u32> = f
            .log
            .borrow()
            .iter()
            .filter_map(|e| match e {
                Ev::RegWrite(a, _) if *a == vid::palette_index::addr() => Some(0),
                Ev::RegWrite(a, _) if *a == vid::palette_data::addr() => Some(1),
                _ => None,
            })
            .collect();
        assert!(order.chunks(2).all(|c| c == [0, 1]));
        assert_eq!(p[0], 0);
        assert_eq!(p[255], 0x00FF_FFFF);
        v.set_waterfall_ring(crate::mem::map::WATERFALL_RING);
        assert_eq!(f.reg(vid::wf_ring_base::addr()), 0x1100_0000 / 8);
        v.set_zoom_waterfall_ring(crate::mem::map::ZOOM_WATERFALL_RING);
        assert_eq!(f.reg(vid::wf_zoom_ring_base::addr()), 0x1180_0000 / 8);
        // A window on a hardware ring: its own ring base and line source; window 0 untouched.
        assert_eq!(v.show_hardware_waterfall(1, WaterfallSource::FullBand, crate::mem::map::WATERFALL_RING), Ok(()));
        assert_eq!((f.reg(vid::wf_win_ring::addr(1)), f.reg(vid::wf_win_ctrl::addr(1))), (0x1100_0000 / 8, 0));
        assert_eq!(v.show_hardware_waterfall(1, WaterfallSource::Zoom, crate::mem::map::ZOOM_WATERFALL_RING), Ok(()));
        assert_eq!((f.reg(vid::wf_win_ring::addr(1)), f.reg(vid::wf_win_ctrl::addr(1))), (0x1180_0000 / 8, 1));
        assert!(f.reg_writes(vid::wf_win_ring::addr(0)).is_empty());
        assert_eq!(v.show_hardware_waterfall(2, WaterfallSource::Zoom, 0), Err(WindowError::NotWaterfallCapable));
        assert_eq!(v.show_hardware_waterfall(0, WaterfallSource::Cpu, 0), Err(WindowError::BadGeometry));
        // The three rings do not overlap.
        use crate::mem::map::{SOFT_WATERFALL_RING, WATERFALL_RING, ZOOM_WATERFALL_RING};
        assert!(WATERFALL_RING + crate::wfring::RING_BYTES <= SOFT_WATERFALL_RING);
        assert!(SOFT_WATERFALL_RING + crate::wfring::RING_BYTES <= ZOOM_WATERFALL_RING);
        assert!(ZOOM_WATERFALL_RING + crate::wfring::RING_BYTES <= crate::mem::map::backend_ring(0));
    }

    #[test]
    fn status_and_clear() {
        let f = MockFabric::new();
        let v = Video::new(&f);
        assert!(v.status().healthy());
        f.poke(vid::status::addr(), 0b11);
        f.poke(vid::underrun_count::addr(), 17);
        f.poke(vid::frame_count::addr(), 4_000);
        let s = v.status();
        assert!(s.underrun && s.lane_error && !s.healthy());
        assert_eq!((s.underrun_count, s.frame_count), (17, 4_000));
        v.clear_status();
        // One write of 1 per flag, never a read-modify-write of both at once.
        assert_eq!(f.reg_writes(vid::status::addr()), [0b10, 0b01]);
    }

    #[test]
    fn present_flushes_then_swaps_and_waits_for_fb_active() {
        let f = MockFabric::new();
        let mut fb = FrameBuffers::new(&f, &f, FRAME_BUFFER);
        assert_eq!(f.reg(vid::fb_stride::addr()), 3_840);
        assert_eq!(f.reg(vid::fb_base::addr()), FRAME_BUFFER[0]);
        assert_eq!(fb.back_addr(), FRAME_BUFFER[1]);
        assert!(fb.back_free(0), "nothing pending before the first swap");
        // The renderer drew lines 100-119 of the back buffer.
        crate::mem::FabricMem::write32(&f, FRAME_BUFFER[1] + 100 * STRIDE, 0xF81F_F81F);
        f.clear_log();
        crate::mem::FabricMem::write32(&f, FRAME_BUFFER[1] + 119 * STRIDE + 3_836, 1);
        fb.present(100, 20, 1_000);
        assert_eq!(
            *f.log.borrow(),
            [
                Ev::MemWrite(FRAME_BUFFER[1] + 119 * STRIDE + 3_836, 1),
                Ev::Writeback(FRAME_BUFFER[1] + 100 * STRIDE, 20 * STRIDE),
                Ev::Delay(crate::mem::BRIDGE_FLUSH_US),
                Ev::RegWrite(vid::fb_base::addr(), FRAME_BUFFER[1]),
            ]
        );
        assert_eq!(f.flush_rule_violations(&[vid::fb_base::addr()]), 0);
        assert_eq!(fb.back_addr(), FRAME_BUFFER[0]);
        // The old buffer is free only when fb_active shows the new base.
        assert!(!fb.back_free(1_010));
        f.poke(vid::fb_active::addr(), FRAME_BUFFER[0]);
        assert!(!fb.back_free(1_020), "fb_active still shows the old base");
        f.poke(vid::fb_active::addr(), FRAME_BUFFER[1]);
        assert!(fb.back_free(1_030));
        assert_eq!(fb.swap_timeouts, 0);
        // Second swap; the compositor never confirms: freed after the time-out, counted.
        fb.present(0, 1080, 2_000);
        assert_eq!(f.reg(vid::fb_base::addr()), FRAME_BUFFER[0]);
        assert!(!fb.back_free(2_099));
        assert!(fb.back_free(2_100));
        assert_eq!(fb.swap_timeouts, 1);
    }

    #[test]
    fn buffers_and_stride_meet_the_compositors_rules() {
        // Base multiple of 8, buffers hold 1,080 lines of the stride, do not overlap.
        for a in FRAME_BUFFER {
            assert_eq!(a % 8, 0);
        }
        assert_eq!(STRIDE % 8, 0);
        assert!(FRAME_BUFFER[1] - FRAME_BUFFER[0] >= STRIDE * HEIGHT);
        assert_eq!(KEY_COLOUR, 0xF81F);
    }
}
