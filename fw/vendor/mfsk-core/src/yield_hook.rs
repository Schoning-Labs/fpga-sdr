// SPDX-License-Identifier: GPL-3.0-or-later
// Added 2026-10-21 by Franz Schöning for fpga-sdr (docs/NETINPUT.md; not in upstream mfsk-core).
//
//! A cooperative yield point for single-threaded firmware. A long decode calls [`call`] between units of work
//! (one spectrogram row, one candidate); the firmware registers a function with [`scope`] for the time of a decode,
//! and that function serves the network and the operator's input. Outside a [`scope`], and inside the hook itself,
//! [`call`] does nothing. One hart, no interrupts touch this: plain `static mut`, no atomics.

use core::ptr::addr_of_mut;

static mut HOOK: Option<*mut (dyn FnMut() + 'static)> = None;
static mut RUNNING: bool = false;

/// Runs the registered hook, if any, unless it is already running.
#[inline]
pub fn call() {
    // SAFETY: single hart; `HOOK` is set only by `scope` around a closure that outlives the scope, and `RUNNING`
    // keeps the hook from being entered twice.
    unsafe {
        if let Some(h) = *addr_of_mut!(HOOK) {
            if !*addr_of_mut!(RUNNING) {
                *addr_of_mut!(RUNNING) = true;
                (*h)();
                *addr_of_mut!(RUNNING) = false;
            }
        }
    }
}

/// Registers `hook` while `f` runs. The caller must not use anything the hook captured while `f` runs (the borrow
/// checker enforces that for the closures involved). Scopes do not nest: an inner one replaces the outer one for its
/// duration.
pub fn scope<R>(hook: &mut dyn FnMut(), f: impl FnOnce() -> R) -> R {
    // SAFETY: the lifetime of the pointer is erased, but it is removed again before `scope` returns (also on unwind
    // by the guard), so it never outlives `hook`.
    struct Restore(Option<*mut (dyn FnMut() + 'static)>);
    impl Drop for Restore {
        fn drop(&mut self) {
            unsafe { *addr_of_mut!(HOOK) = self.0 };
        }
    }
    unsafe {
        let erased: *mut (dyn FnMut() + 'static) = core::mem::transmute::<&mut dyn FnMut(), *mut (dyn FnMut() + 'static)>(hook);
        let _restore = Restore(*addr_of_mut!(HOOK));
        *addr_of_mut!(HOOK) = Some(erased);
        f()
    }
}
