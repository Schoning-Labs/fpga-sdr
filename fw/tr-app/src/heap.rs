// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The firmware's heap: power-of-two size classes from 16 bytes to 16 MB, one free list each,
//! carved from one memory range by a bump pointer. It is the allocator of `tr-ft8bench`, with the
//! range given at start-up. There is one processor and no allocation in interrupt handlers, so
//! there is no locking. Freed blocks go back to the list of their size class and are never
//! merged or split, which suits the decoders, because they ask for the same few sizes every slot.

use core::alloc::{GlobalAlloc, Layout};
use core::cell::UnsafeCell;

/// Size classes 16 << 0 to 16 << 20 bytes, so 16 bytes to 16 MB.
const CLASSES: usize = 21;

struct State {
    /// Start and length of the memory range.
    base: usize,
    len: usize,
    /// Offset of the first byte never handed out.
    bump: usize,
    /// Head of each class's free list (0 when empty). A free block holds the address of the next one in its first word.
    free: [usize; CLASSES],
    /// The highest `bump` reached.
    peak: usize,
}

/// The global allocator. A single static instance exists; [`init`] gives it its memory.
pub struct Heap(UnsafeCell<State>);
unsafe impl Sync for Heap {}

#[global_allocator]
static HEAP: Heap = Heap(UnsafeCell::new(State { base: 0, len: 0, bump: 0, free: [0; CLASSES], peak: 0 }));

/// Gives the heap its memory. Before this every allocation fails.
///
/// # Safety
/// `[base, base + len)` must be memory nothing else uses; call once, before the first allocation.
pub unsafe fn init(base: usize, len: usize) {
    let st = &mut *HEAP.0.get();
    st.base = base;
    st.len = len;
    st.bump = 0;
}

/// Most bytes ever taken from the range.
pub fn peak() -> usize {
    unsafe { (*HEAP.0.get()).peak }
}

/// The size class for a layout: the size (or the alignment if larger) rounded up to a power of two of at least 16.
fn class_of(l: &Layout) -> usize {
    let size = l.size().max(l.align()).max(16).next_power_of_two();
    size.trailing_zeros() as usize - 4
}

unsafe impl GlobalAlloc for Heap {
    unsafe fn alloc(&self, l: Layout) -> *mut u8 {
        let c = class_of(&l);
        if c >= CLASSES {
            return core::ptr::null_mut();
        }
        let st = &mut *self.0.get();
        let head = st.free[c];
        if head != 0 {
            st.free[c] = *(head as *const usize);
            return head as *mut u8;
        }
        let size = 16usize << c;
        // A block is aligned to its own size up to 4096 bytes, which also covers any alignment the layout asks for.
        let align = size.min(4096).max(l.align());
        let p = (st.base + st.bump + align - 1) & !(align - 1);
        if st.len == 0 || p + size > st.base + st.len {
            return core::ptr::null_mut();
        }
        st.bump = p + size - st.base;
        st.peak = st.peak.max(st.bump);
        p as *mut u8
    }

    unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
        let c = class_of(&l);
        let st = &mut *self.0.get();
        *(p as *mut usize) = st.free[c];
        st.free[c] = p as usize;
    }
}
