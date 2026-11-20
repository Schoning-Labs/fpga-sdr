// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Atomic operations without the RISC-V A extension. The AE350's processor stopped dead at the first `amoadd`
//! it executed on the board, and in the firmware those instructions
//! come from the reference counts in Slint. `.cargo/config.toml` switches the A extension off, so the
//! compiler calls the libatomic functions below instead. With one hart, switching interrupts off for the few
//! instructions of an update is atomic enough. Only the 4-byte forms exist, and a link error names any other
//! size that turns up.

use riscv::interrupt;

/// Defines a read-modify-write libatomic function over a `u32` that returns the old value; `$new` computes the new value from `$old` and `$v`.
macro_rules! rmw {
    ($name:ident, |$old:ident, $v:ident| $new:expr) => {
        #[no_mangle]
        pub unsafe extern "C" fn $name(ptr: *mut u32, $v: u32, _order: i32) -> u32 {
            interrupt::free(|| {
                let $old = ptr.read_volatile();
                ptr.write_volatile($new);
                $old
            })
        }
    };
}

/// Atomic load (a plain volatile read on one hart).
#[no_mangle]
pub unsafe extern "C" fn __atomic_load_4(ptr: *const u32, _order: i32) -> u32 {
    ptr.read_volatile()
}

/// Atomic store (a plain volatile write on one hart).
#[no_mangle]
pub unsafe extern "C" fn __atomic_store_4(ptr: *mut u32, v: u32, _order: i32) {
    ptr.write_volatile(v)
}

rmw!(__atomic_exchange_4, |old, v| v);
rmw!(__atomic_fetch_add_4, |old, v| old.wrapping_add(v));
rmw!(__atomic_fetch_sub_4, |old, v| old.wrapping_sub(v));
rmw!(__atomic_fetch_and_4, |old, v| old & v);
rmw!(__atomic_fetch_or_4, |old, v| old | v);
rmw!(__atomic_fetch_xor_4, |old, v| old ^ v);

/// Compare and exchange: on a mismatch the old value is written back to `expected` and `false` is returned.
#[no_mangle]
pub unsafe extern "C" fn __atomic_compare_exchange_4(ptr: *mut u32, expected: *mut u32, desired: u32, _ok: i32, _fail: i32) -> bool {
    interrupt::free(|| {
        let old = ptr.read_volatile();
        if old == expected.read() {
            ptr.write_volatile(desired);
            true
        } else {
            expected.write(old);
            false
        }
    })
}
