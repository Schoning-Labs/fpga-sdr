// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! A fake [`RegisterSpace`] for host tests: a fixed-size backing store, one word per address,
//! no `alloc`. Sized to cover one 64 KB register page (docs/ARCHITECTURE.md 4.1: "one 64 KB
//! page per block"), which is the largest `size` any block in `hw/regmap/` uses.
//!
//! Only reachable behind the `mock` feature (see `fw/tr-regs/Cargo.toml`): never built into
//! firmware. `fw/tr-regs/tests/*.rs` pull it in through the crate's own `[dev-dependencies]`
//! self-reference, which turns the feature on for test builds only.
//!
//! `write32` is a plain overwrite of the whole word -- it does not model real write-1-to-clear
//! (W1C) hardware, which only clears the bits written as `1` and leaves the rest alone. A test
//! that cares about W1C behaviour should check the *value a `clear_<field>()` accessor writes*
//! (it must be exactly that field's own mask, never something read back first) rather than
//! relying on this mock to apply clear-on-write-1 semantics; see
//! `fw/tr-regs/tests/example_regmap.rs` for the pattern.

use crate::RegisterSpace;
use core::cell::Cell;

const PAGE_BYTES: u32 = 0x1_0000;
const PAGE_WORDS: usize = (PAGE_BYTES / 4) as usize;

/// Backs one register block's 64 KB page, starting at `base`. Every word starts as `0`; use
/// [`MockRegisterSpace::poke`] to preload a register's documented reset value (its generated
/// `RESET` constant) where a test needs that.
pub struct MockRegisterSpace {
    base: u32,
    words: [Cell<u32>; PAGE_WORDS],
}

impl MockRegisterSpace {
    pub fn new(base: u32) -> Self {
        Self {
            base,
            words: core::array::from_fn(|_| Cell::new(0)),
        }
    }

    fn index(&self, addr: u32) -> usize {
        let offset = addr
            .checked_sub(self.base)
            .unwrap_or_else(|| panic!("address {addr:#010x} is below the mock's base {:#010x}", self.base));
        assert!(
            offset < PAGE_BYTES,
            "address {addr:#010x} is outside the mock's 64 KB page (base {:#010x})",
            self.base
        );
        assert!(offset % 4 == 0, "address {addr:#010x} is not word-aligned");
        (offset / 4) as usize
    }

    /// Set one word directly, bypassing any field logic -- e.g. to preload a reset value or to
    /// simulate hardware setting a status bit before firmware reads it.
    pub fn poke(&self, addr: u32, value: u32) {
        self.words[self.index(addr)].set(value);
    }
}

impl RegisterSpace for MockRegisterSpace {
    fn read32(&self, addr: u32) -> u32 {
        self.words[self.index(addr)].get()
    }

    fn write32(&self, addr: u32, value: u32) {
        self.words[self.index(addr)].set(value);
    }
}
