// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The runtime shared by the three QEMU programs of tr-ft8bench (ft8_bench, ft8_kernels and ft8_sched): a heap,
//! a panic handler and the instruction counter. Each program includes this file with `#[path]` and defines its
//! own heap size as `HEAP_BYTES` in its crate root, which `ARENA` below picks up.

use core::alloc::{GlobalAlloc, Layout};
use core::cell::UnsafeCell;
use core::fmt::Write as _;
use core::panic::PanicInfo;

use tr_ae350::board::qemu;
use tr_ae350::uart;

// ── Size-class allocator: power-of-two classes from 16 bytes to 16 MB (21 of them), one free list each, with
// fresh blocks carved from a static arena by a bump pointer. A freed block goes onto the free list of its
// class and is reused as it is, which keeps the allocator very small at the price of some wasted space inside
// each block. The benchmark runs on a single hart with no interrupts, so there is no locking.
const ARENA: usize = crate::HEAP_BYTES;
const CLASSES: usize = 21;

/// The global allocator: the arena and its bookkeeping. `state` is public so that a program can read the peak.
pub struct Heap {
    arena: UnsafeCell<[u8; ARENA]>,
    /// (bump offset into the arena, head address of the free list of each class, peak of the bump offset)
    pub state: UnsafeCell<(usize, [usize; CLASSES], usize)>,
}
// SAFETY: single hart and no interrupts, see above.
unsafe impl Sync for Heap {}

#[global_allocator]
pub static HEAP: Heap = Heap { arena: UnsafeCell::new([0; ARENA]), state: UnsafeCell::new((0, [0; CLASSES], 0)) };

/// The size class of a layout: its size or alignment (whichever is larger, at least 16) rounded up to a power
/// of two, counted from class 0 = 16 bytes.
fn class_of(l: &Layout) -> usize {
    let size = l.size().max(l.align()).max(16).next_power_of_two();
    size.trailing_zeros() as usize - 4
}

unsafe impl GlobalAlloc for Heap {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        let c = class_of(&l);
        // Larger than the largest class: refuse, which ends in the allocation-error panic.
        if c >= CLASSES {
            return core::ptr::null_mut();
        }
        let st = &mut *self.state.get();
        // A freed block of this class is reused first; its first word holds the address of the next free one.
        let head = st.1[c];
        if head != 0 {
            st.1[c] = *(head as *const usize);
            return head as *mut u8;
        }
        // Otherwise carve a fresh block from the arena, aligned to its own size up to 4096 bytes (or to the
        // layout's alignment when that is larger), and return null when the arena is used up.
        let size = 16usize << c;
        let base = self.arena.get() as usize;
        let align = size.min(4096).max(l.align());
        let p = (base + st.0 + align - 1) & !(align - 1);
        if p + size > base + ARENA {
            return core::ptr::null_mut();
        }
        st.0 = p + size - base;
        st.2 = st.2.max(st.0);
        p as *mut u8
    }
    // A freed block is pushed onto the free list of its class; nothing is ever returned to the arena.
    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        let c = class_of(&l);
        let st = &mut *self.state.get();
        *(p as *mut usize) = st.1[c];
        st.1[c] = p as usize;
    }
}

/// Prints the panic message on the UART and ends the QEMU run with a failure status.
#[panic_handler]
fn panic(info: &PanicInfo) -> ! {
    let mut con = &uart::CONSOLE;
    let _ = writeln!(con, "PANIC: {info}");
    qemu::exit_fail(1);
}

/// The 64-bit count of instructions retired so far (`minstret`).
pub fn instret() -> u64 {
    riscv::register::minstret::read64()
}

