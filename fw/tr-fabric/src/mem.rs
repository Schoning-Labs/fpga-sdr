// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! DDR3 as the drivers see it, the memory map of the rings, and the 10 us rule.

/// The DDR3 shared with the logic, by CPU byte address. On the board: plain memory access plus the
/// Andes cache commands (`tr_ae350::cctl`) and a timer wait; in host tests: `mock::MockFabric`.
pub trait FabricMem {
    fn write32(&self, addr: u32, value: u32);
    fn read32(&self, addr: u32) -> u32;
    /// Write the D-cache lines of `[addr, addr + len)` back to memory (CPU-written data).
    fn writeback(&self, addr: u32, len: u32);
    /// Drop the D-cache lines of `[addr, addr + len)` (logic-written data, before reading it).
    fn invalidate(&self, addr: u32, len: u32);
    /// Wait at least `us` microseconds.
    fn delay_us(&self, us: u32);
}

/// Wait between writing the cache back and moving a pointer the logic follows (docs/MEM_1GB.md
/// section 3: the bridge keeps a written line for up to 256 bus clocks, 5.1 us at 50 MHz). There
/// is no register that says the bridge has flushed, so the wait is always taken.
pub const BRIDGE_FLUSH_US: u32 = 10;

/// Proof that CPU-written data has reached the memory the logic reads: only [`flush_for_logic`]
/// makes one, and the crate's pointer writes ask for one.
pub(crate) struct Flushed(());

/// Cache write-back of every given range, then the bridge wait.
pub(crate) fn flush_for_logic<M: FabricMem>(mem: &M, ranges: &[(u32, u32)]) -> Flushed {
    for &(addr, len) in ranges {
        if len != 0 {
            mem.writeback(addr, len);
        }
    }
    mem.delay_us(BRIDGE_FLUSH_US);
    Flushed(())
}

/// Where the firmware puts what it shares with the logic (docs/ARCHITECTURE.md 5.4). Byte addresses.
pub mod map {
    /// Slint frame buffers, 1,920 x 1,080 RGB565 each.
    pub const FRAME_BUFFER: [u32; 2] = [0x1000_0000, 0x1040_0000];
    /// Full-band waterfall ring the hardware writes (2,048 lines of 1,920 bytes = 3.75 MB; the
    /// three rings are 4 MB apart).
    pub const WATERFALL_RING: u32 = 0x1100_0000;
    /// Ring of the CPU-written waterfall (`wfring`), same size.
    pub const SOFT_WATERFALL_RING: u32 = 0x1140_0000;
    /// Ring the zoom spectrum's hardware writer writes, same size.
    pub const ZOOM_WATERFALL_RING: u32 = 0x1180_0000;
    /// Back-end audio ring of receiver `rx` (1 MB apart).
    pub const fn backend_ring(rx: u32) -> u32 {
        0x1200_0000 + rx * 0x10_0000
    }
    /// Audio ring the firmware writes (4,096 words).
    pub const AUDIO_RING: u32 = 0x1280_0000;
    /// TX baseband ring (8,192 words).
    pub const TX_RING: u32 = 0x1290_0000;
}
