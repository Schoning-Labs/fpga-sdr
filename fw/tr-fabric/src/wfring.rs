// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! A waterfall the CPU writes: lines of palette indices in DDR3, in the format and byte order the
//! compositor's waterfall window reads (docs/V2_COMPOSITOR.md sections 1 and 3, `rtl/video/waterfall_writer.v`,
//! `compositor_fetch.v`, `compositor_pix.v`).
//!
//! **Format.** A ring of 2,048 lines of 1,920 bytes (240 lane words of 64 bit) from
//! `wf_ring_base` (lane-word address). Source column `c` of a line is the byte
//! `lane_word[63 - 8 * (c % 8) -: 8]` of lane word `c / 8`: column 0 is the **top** byte of the
//! first word. The CPU sees a lane word as 8 bytes in little-endian order (every other ring in the
//! chip is read that way, `rtl/top/rd_word_adapter.v`), so column `c` is memory byte
//! `(c & !7) + 7 - (c & 7)` of the line. [`mem_offset_of_column`] is that formula; [`pack_line`]
//! writes whole words so no byte-wise access is needed.
//!
//! **Scrolling.** Each of the two waterfall windows has its own ring base (`wf_win_ring`) and its
//! own scroll line: window row `row` shows ring line `scroll line - row` (newest at the top), and
//! `wf_win_ctrl.line_src` says whether that line is a hardware writer's (full band or zoom) or
//! the CPU's (`wf_win_line`). The software waterfall here is a plain ring of 2,048 lines of its
//! own in DDR3: a new line goes into the next ring line, then `wf_win_line` moves to it. Nothing
//! on screen is overwritten as long as the window has fewer than 2,048 rows. The register is taken
//! by the compositor once per frame, at the vertical blank, so a frame never shows half an update.
//! The hardware full-band waterfall keeps its own ring and can be shown in the other window.
//!
//! Every `wf_win_line` write follows the cache write-back and the 10 us wait ([`flush_for_logic`]).

use tr_regs::generated::video as vid;
use tr_regs::RegisterSpace;

use crate::mem::{flush_for_logic, FabricMem, Flushed};

/// Bytes per ring line.
pub const LINE_BYTES: u32 = 1_920;
/// Lines in the ring (the hardware's 11-bit line index).
pub const RING_LINES: u32 = 2_048;

/// Memory byte offset within a line of source column `col` (see the module text).
pub const fn mem_offset_of_column(col: u32) -> u32 {
    (col & !7) + 7 - (col & 7)
}

/// Words (32 bit) of a line that carry `cols` columns: whole lane words, two 32-bit words each.
pub const fn words_for_columns(cols: u32) -> u32 {
    cols.div_ceil(8) * 2
}

/// Packs one line of palette indices into memory words: calls `put(word_index, value)` for the
/// `words_for_columns(idx.len())` words of the line, columns past the end of `idx` being 0.
pub fn pack_line(idx: &[u8], mut put: impl FnMut(u32, u32)) {
    let groups = idx.len().div_ceil(8);
    for g in 0..groups {
        let c = |k: usize| idx.get(8 * g + k).copied().unwrap_or(0) as u32;
        // Lane word bits 63:56 = column 0 ... 7:0 = column 7; the low 32-bit word holds columns 7..4.
        let low = c(7) | c(6) << 8 | c(5) << 16 | c(4) << 24;
        let high = c(3) | c(2) << 8 | c(1) << 16 | c(0) << 24;
        put(2 * g as u32, low);
        put(2 * g as u32 + 1, high);
    }
}

/// What the compositor reads for row `row` (0 = top), source column `col` of waterfall window
/// `window` (0 or 1): that window's `wf_win_ring`, its scroll line as `wf_win_ctrl.line_src`
/// selects it, the 64-bit lane word with the CPU's little-endian view of memory, column 0 = top
/// byte. A model of `compositor.v` / `compositor_fetch.v` / `compositor_pix.v` for host tests and
/// the QEMU twin.
pub fn compositor_view<R: RegisterSpace, M: FabricMem>(regs: &R, mem: &M, window: u32, row: u32, col: u32) -> u8 {
    let base = vid::wf_win_ring::read(regs, window) as u64;
    let top = match vid::wf_win_ctrl::read(regs, window).line_src() {
        0 => vid::wf_write_line::read(regs),
        1 => vid::wf_zoom_write_line::read(regs),
        _ => vid::wf_win_line::read(regs, window).line(),
    };
    let line = top.wrapping_sub(row) & (RING_LINES - 1);
    let a = ((base + line as u64 * (LINE_BYTES / 8) as u64 + (col / 8) as u64) * 8) as u32;
    let lane = mem.read32(a) as u64 | (mem.read32(a + 4) as u64) << 32;
    (lane >> (56 - 8 * (col % 8))) as u8
}

/// `wf_win_ctrl.line_src`: the CPU writes the scroll line.
pub const LINE_SRC_CPU: u32 = 2;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WfError {
    /// Window index not 0 or 1, rows outside 1..=2047, columns outside 1..=1920, or a ring address
    /// that is not a multiple of 8.
    Geometry,
}

/// The software waterfall of one waterfall window: owns that window's `wf_win_ring`,
/// `wf_win_ctrl` and `wf_win_line`, and [`RING_BYTES`] of DDR3.
pub struct SoftWaterfall<'a, R: RegisterSpace, M: FabricMem> {
    regs: &'a R,
    mem: &'a M,
    window: u32,
    ring_addr: u32,
    cols: u32,
    /// Ring line of the newest line (the window's top row).
    top_line: u32,
    /// Lines pushed since start.
    pub lines: u64,
}

/// DDR3 bytes of a ring.
pub const RING_BYTES: u32 = RING_LINES * LINE_BYTES;

impl<'a, R: RegisterSpace, M: FabricMem> SoftWaterfall<'a, R, M> {
    /// Gives waterfall window `window` (0 or 1) a ring of its own at CPU byte address `ring_addr`
    /// ([`RING_BYTES`] long), for a window of `rows` x `cols` (columns start at source column 0).
    /// Clears the rows the window shows to palette index 0, then points the window at the ring
    /// with a CPU-written scroll line. No other window and no hardware writer is touched.
    pub fn new(regs: &'a R, mem: &'a M, window: u32, ring_addr: u32, rows: u32, cols: u32) -> Result<Self, WfError> {
        if window >= 2 || rows == 0 || rows >= RING_LINES || cols == 0 || cols > LINE_BYTES || ring_addr % 8 != 0 {
            return Err(WfError::Geometry);
        }
        // Start with the newest line at ring line `rows - 1`: the window shows lines rows-1 .. 0,
        // one contiguous piece of memory to clear and write back.
        let w = SoftWaterfall { regs, mem, window, ring_addr, cols, top_line: rows - 1, lines: 0 };
        let words = words_for_columns(cols);
        for r in 0..rows {
            for k in 0..words {
                mem.write32(ring_addr + r * LINE_BYTES + 4 * k, 0);
            }
        }
        let proof = flush_for_logic(mem, &[(ring_addr, rows * LINE_BYTES)]);
        vid::wf_win_ring::write(regs, window, ring_addr / 8);
        w.show_top(proof);
        vid::wf_win_ctrl::write(regs, window, vid::wf_win_ctrl::Value(0).with_line_src(LINE_SRC_CPU));
        Ok(w)
    }

    fn show_top(&self, _flushed: Flushed) {
        vid::wf_win_line::write(self.regs, self.window, vid::wf_win_line::Value(0).with_line(self.top_line));
    }

    /// CPU byte address of the newest line.
    pub fn newest_line_addr(&self) -> u32 {
        self.ring_addr + self.top_line * LINE_BYTES
    }

    /// Appends a line of `cols` palette indices (shorter: padded with 0; longer: cut) as the new top
    /// row. The window contents move down one row at the next vertical blank.
    pub fn push_line(&mut self, idx: &[u8]) {
        let idx = &idx[..idx.len().min(self.cols as usize)];
        let words = words_for_columns(self.cols);
        let line = (self.top_line + 1) & (RING_LINES - 1);
        let at = self.ring_addr + line * LINE_BYTES;
        let mem = self.mem;
        pack_line(idx, |k, v| mem.write32(at + 4 * k, v));
        // pack_line pads only inside the last group of a short `idx`; the words up to `cols` here.
        let packed = idx.len().div_ceil(8) as u32 * 2;
        for k in packed..words {
            mem.write32(at + 4 * k, 0);
        }
        let proof = flush_for_logic(self.mem, &[(at, words * 4)]);
        self.top_line = line;
        self.lines += 1;
        self.show_top(proof);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mock::{Ev, MockFabric};
    use alloc::vec::Vec;

    const REGION: u32 = 0x1100_0000;

    fn compositor_pixel(f: &MockFabric, row: u32, col: u32) -> u8 {
        compositor_view(f, f, 0, row, col)
    }

    fn fabric() -> MockFabric {
        let f = MockFabric::new();
        // The hardware writers run on their own: their lines must not matter to a CPU-scrolled window.
        f.poke(vid::wf_write_line::addr(), 1_234);
        f.poke(vid::wf_zoom_write_line::addr(), 77);
        f
    }

    #[test]
    fn byte_order_matches_the_lane_word() {
        assert_eq!(mem_offset_of_column(0), 7);
        assert_eq!(mem_offset_of_column(7), 0);
        assert_eq!(mem_offset_of_column(8), 15);
        assert_eq!(mem_offset_of_column(1_919), 1_912);
        let idx: Vec<u8> = (0..20).map(|c| c as u8 + 1).collect();
        let mut words = [0u32; 6];
        pack_line(&idx, |k, v| words[k as usize] = v);
        // 20 columns = 3 lane words = 6 words; every column is at its memory byte.
        let bytes: Vec<u8> = words.iter().flat_map(|w| w.to_le_bytes()).collect();
        for c in 0..20u32 {
            assert_eq!(bytes[mem_offset_of_column(c) as usize], c as u8 + 1, "column {c}");
        }
        // Columns 20..23 (past the end) are zero.
        assert_eq!(bytes[mem_offset_of_column(21) as usize], 0);
        assert_eq!(words_for_columns(20), 6);
        assert_eq!(words_for_columns(1_172), 294);
    }

    #[test]
    fn new_clears_and_points_the_window_after_the_flush() {
        let f = fabric();
        f.poke_mem(REGION + 4, 0xDEAD_BEEF);
        let w = SoftWaterfall::new(&f, &f, 0, REGION, 656, 1_172).unwrap();
        assert_eq!(f.mem(REGION + 4), 0);
        assert_eq!(w.newest_line_addr(), REGION + 655 * 1_920);
        assert_eq!(vid::wf_win_ring::read(&f, 0) * 8, REGION);
        assert_eq!(vid::wf_win_line::read(&f, 0).line(), 655);
        assert_eq!(vid::wf_win_ctrl::read(&f, 0).line_src(), LINE_SRC_CPU);
        // The other window and the hardware writers' ring registers are not touched.
        assert!(f.reg_writes(vid::wf_win_ring::addr(1)).is_empty());
        assert!(f.reg_writes(vid::wf_ring_base::addr()).is_empty());
        assert!(f.reg_writes(vid::wf_zoom_ring_base::addr()).is_empty());
        assert_eq!(f.flush_rule_violations(&[vid::wf_win_line::addr(0)]), 0);
        let wb = f.log.borrow().iter().filter(|e| matches!(e, Ev::Writeback(..))).count();
        assert_eq!(wb, 1);
        // The line register is written before the window is switched to it.
        let order: Vec<u32> = f.log.borrow().iter().filter_map(|e| if let Ev::RegWrite(a, _) = e { Some(*a) } else { None }).collect();
        assert_eq!(order, [vid::wf_win_ring::addr(0), vid::wf_win_line::addr(0), vid::wf_win_ctrl::addr(0)]);
    }

    #[test]
    fn rejects_what_it_cannot_show() {
        let f = fabric();
        assert_eq!(SoftWaterfall::new(&f, &f, 2, REGION, 656, 1_172).err(), Some(WfError::Geometry));
        assert_eq!(SoftWaterfall::new(&f, &f, 0, REGION + 4, 656, 1_172).err(), Some(WfError::Geometry));
        assert_eq!(SoftWaterfall::new(&f, &f, 0, REGION, 656, 2_000).err(), Some(WfError::Geometry));
        assert_eq!(SoftWaterfall::new(&f, &f, 0, REGION, 0, 100).err(), Some(WfError::Geometry));
        assert_eq!(SoftWaterfall::new(&f, &f, 0, REGION, 2_048, 100).err(), Some(WfError::Geometry));
        assert!(f.log.borrow().is_empty(), "a refused waterfall writes nothing");
    }

    #[test]
    fn lines_scroll_down_in_the_compositors_view_around_the_ring() {
        // A 6-row, 21-column window; 2,100 lines go once around the 2,048-line ring.
        let f = fabric();
        let rows = 6u32;
        let cols = 21u32;
        let mut w = SoftWaterfall::new(&f, &f, 0, REGION, rows, cols).unwrap();
        f.log_limit.set(1);
        let line_of = |n: u32| -> Vec<u8> { (0..cols).map(|c| ((n * 7 + c * 3) % 251) as u8 + 1).collect() };
        for n in 0..2_100u32 {
            w.push_line(&line_of(n));
            // Row r shows the line pushed r pushes ago; rows older than the history are the cleared 0.
            if n < 40 || n > 2_030 {
                for r in 0..rows {
                    for c in 0..cols {
                        let want = if r <= n { line_of(n - r)[c as usize] } else { 0 };
                        assert_eq!(compositor_pixel(&f, r, c), want, "after {} lines, row {r} column {c}", n + 1);
                    }
                }
            }
        }
        assert_eq!(w.lines, 2_100);
        assert_eq!(vid::wf_win_line::read(&f, 0).line(), (rows - 1 + 2_100) % 2_048);
        // All of it inside the ring's own memory.
        assert!(w.newest_line_addr() >= REGION && w.newest_line_addr() < REGION + RING_BYTES);
    }

    #[test]
    fn every_push_is_flushed_before_the_line_moves_and_two_windows_do_not_meet() {
        let f = fabric();
        let mut w0 = SoftWaterfall::new(&f, &f, 0, REGION, 6, 21).unwrap();
        let mut w1 = SoftWaterfall::new(&f, &f, 1, REGION + RING_BYTES, 4, 16).unwrap();
        for n in 0..70u8 {
            w0.push_line(&[n + 1; 21]);
            if n % 2 == 0 {
                w1.push_line(&[200 - n; 16]);
            }
        }
        assert_eq!(f.flush_rule_violations(&[vid::wf_win_line::addr(0), vid::wf_win_line::addr(1)]), 0);
        // The scroll line only ever moves by one line.
        let lines = f.reg_writes(vid::wf_win_line::addr(0));
        assert!(lines.windows(2).all(|p| p[1] == (p[0] + 1) % 2_048));
        assert_eq!((compositor_view(&f, &f, 0, 0, 20), compositor_view(&f, &f, 0, 5, 0)), (70, 65));
        assert_eq!((compositor_view(&f, &f, 1, 0, 15), compositor_view(&f, &f, 1, 3, 0)), (200 - 68, 200 - 62));
    }

    #[test]
    fn a_window_on_a_hardware_ring_follows_that_writers_line() {
        // Window 1 shows the full-band hardware ring, then the zoom ring: the view follows the
        // writer's line register, not the CPU's.
        let f = fabric();
        let ring = REGION + 2 * RING_BYTES;
        vid::wf_win_ring::write(&f, 1, ring / 8);
        vid::wf_win_ctrl::write(&f, 1, vid::wf_win_ctrl::Value(0).with_line_src(0));
        let put = |line: u32, v: u8| pack_line(&[v; 8], |k, w| f.poke_mem(ring + line * LINE_BYTES + 4 * k, w));
        put(1_234, 11);
        put(1_233, 12);
        put(77, 21);
        put(76, 22);
        assert_eq!((compositor_view(&f, &f, 1, 0, 3), compositor_view(&f, &f, 1, 1, 3)), (11, 12));
        vid::wf_win_ctrl::write(&f, 1, vid::wf_win_ctrl::Value(0).with_line_src(1));
        assert_eq!((compositor_view(&f, &f, 1, 0, 3), compositor_view(&f, &f, 1, 1, 3)), (21, 22));
    }

    #[test]
    fn short_lines_are_padded_and_long_ones_cut() {
        let f = fabric();
        let mut w = SoftWaterfall::new(&f, &f, 0, REGION, 4, 16).unwrap();
        w.push_line(&[9; 5]);
        assert_eq!((compositor_pixel(&f, 0, 4), compositor_pixel(&f, 0, 5), compositor_pixel(&f, 0, 15)), (9, 0, 0));
        w.push_line(&[7; 40]);
        assert_eq!((compositor_pixel(&f, 0, 15), compositor_pixel(&f, 1, 4)), (7, 9));
        // Nothing past column 15 was written.
        let past = f.mem(w.newest_line_addr() + 16);
        assert_eq!(past, 0);
    }
}
