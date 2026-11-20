// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Finds the size of the DDR3 by where it repeats, and prints one line for the start-up test
//! (`docs/MEM_1GB.md`, section 6).
//!
//! `size_probe_with` is host-tested on model memories of 256 MB, 512 MB, 1 GB and 2 GB and with a
//! dead address line. The base address, the report line and the cache calls are specific to
//! fpga-sdr.
//!
//! The data memory window of the processor is 2 GB (0x0000_0000 to 0x7FFF_FFFF, MUG1031 table
//! 3-1). The memory bridge `rtl/mem/ddr_mem.v` uses address bits 29..0 only, so with the 1 GB build
//! the word at `base + 2^30` is the word at `base`. The 256 MB fall-back build (the DDR3 controller
//! of the AE350 itself) has 2^28 bytes, and whether it repeats above that is not in any document,
//! so there the probe may print 256 MB or "no repeat".
use core::fmt::Write;

/// log2 of the board's DDR3 size: two 4 Gbit chips, 2^30 bytes (the 1 GB build, the default).
pub const DDR3_SIZE_K: u32 = 30;
/// log2 of what the 256 MB fall-back build reaches (`TR_DDR=256` in gowin/p1/build.sh).
pub const DDR3_FALLBACK_K: u32 = 28;
/// Smallest size the probe tells apart (1 MB).
pub const SIZE_MIN_K: u32 = 20;

/// Base word of the probe: the last megabyte of the heap region (docs/ARCHITECTURE.md 5.4; the
/// heap is not set up when the start-up test runs). The other words it writes are `base + 2^k`,
/// k = 20..30: 0x1000_0000 (frame buffer, not yet in use), 0x1010_0000 .. 0x2FF0_0000 (rings and
/// capture region, not yet in use) and 0x4FF0_0000 (the base itself when the memory is 1 GB).
/// None of them is in the firmware image (0x0000_0000 to 0x00FF_FFFF) at any memory size from
/// 32 MB up. Run the probe before anything uses the frame buffer or the rings.
pub const PROBE_BASE: usize = 0x0FF0_0000;

/// Result of [`size_probe`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SizeResult {
    /// The memory repeats after 2^k bytes: that is its size.
    Repeats(u32),
    /// No repeat up to 2^max_k bytes.
    NoRepeat,
    /// The word at the base holds none of the markers: (wanted, read).
    Garbage(u32, u32),
}

/// A marker goes to `base`, then one to each `base + 2^k`, from `max_k` down to [`SIZE_MIN_K`];
/// the marker left at `base` names the smallest 2^k that lands on it. `wr` and `rd` are the store
/// and the load; `flush(addr, len)` must make the store reach the memory and the next load come
/// from the memory (write the cache line back and invalidate it).
pub fn size_probe_with(
    base: usize,
    max_k: u32,
    wr: &mut dyn FnMut(usize, u32),
    rd: &mut dyn FnMut(usize) -> u32,
    flush: &mut dyn FnMut(usize, usize),
) -> SizeResult {
    const M0: u32 = 0x512E_0000;
    let mark = |k: u32| 0x512E_0000u32 | (k << 8) | k;
    wr(base, M0);
    flush(base, 4);
    for k in (SIZE_MIN_K..=max_k).rev() {
        wr(base + (1usize << k), mark(k));
        flush(base + (1usize << k), 4);
    }
    flush(base, 4);
    let got = rd(base);
    if got == M0 {
        return SizeResult::NoRepeat;
    }
    for k in SIZE_MIN_K..=max_k {
        if got == mark(k) {
            return SizeResult::Repeats(k);
        }
    }
    SizeResult::Garbage(M0, got)
}

/// [`size_probe_with`] on the memory itself, from [`PROBE_BASE`] up to 2^30, with the AE350's
/// cache calls.
///
/// # Safety
/// AE350 only. The words named at [`PROBE_BASE`] are overwritten: nothing else may use them yet.
#[cfg(feature = "board-ae350")]
pub unsafe fn size_probe() -> SizeResult {
    size_probe_with(
        PROBE_BASE,
        DDR3_SIZE_K,
        &mut |a, v| unsafe { core::ptr::write_volatile(a as *mut u32, v) },
        &mut |a| unsafe { core::ptr::read_volatile(a as *const u32) },
        &mut |a, n| unsafe {
            crate::cctl::dcache_writeback(a, n);
            crate::cctl::dcache_invalidate(a, n);
        },
    )
}

/// Prints the start-up test's line and returns true when the memory has the size the bitstream is
/// built for: `expect_k` = [`DDR3_SIZE_K`] for the 1 GB build, [`DDR3_FALLBACK_K`] for the 256 MB
/// fall-back (there "no repeat" also passes, see the module text).
pub fn size_line<W: Write>(w: &mut W, res: SizeResult, expect_k: u32) -> bool {
    let (ok, _) = match res {
        SizeResult::Repeats(k) => (
            k == expect_k,
            writeln!(
                w,
                "DDR3 size: {} MB found (the word at {:#010x} repeats at +2^{}); this build expects {} MB: {}",
                1u32 << (k - 20),
                PROBE_BASE,
                k,
                1u32 << (expect_k - 20),
                if k == expect_k { "PASS" } else { "FAIL" }
            ),
        ),
        SizeResult::NoRepeat => (
            expect_k != DDR3_SIZE_K,
            writeln!(
                w,
                "DDR3 size: no repeat from {:#010x} up to +2^{}; this build expects {} MB: {}",
                PROBE_BASE,
                DDR3_SIZE_K,
                1u32 << (expect_k - 20),
                if expect_k != DDR3_SIZE_K { "PASS (size not known)" } else { "FAIL" }
            ),
        ),
        SizeResult::Garbage(want, got) => (
            false,
            writeln!(
                w,
                "DDR3 size: the word at {:#010x} reads {:#010x}, written {:#010x}: FAIL (the memory does not hold data)",
                PROBE_BASE, got, want
            ),
        ),
    };
    ok
}
