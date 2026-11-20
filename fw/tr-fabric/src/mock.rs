// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Host-test stand-in for the fabric: every register page and the DDR3 in one object, with a log
//! of every write, cache command and wait in the order they happened. Registers are plain memory
//! cells (a W1C write stores the mask written); tests set read-only registers with [`MockFabric::poke`].

use alloc::collections::BTreeMap;
use alloc::vec::Vec;
use core::cell::RefCell;

use tr_regs::RegisterSpace;

use crate::mem::{FabricMem, BRIDGE_FLUSH_US};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ev {
    RegWrite(u32, u32),
    MemWrite(u32, u32),
    Writeback(u32, u32),
    Invalidate(u32, u32),
    Delay(u32),
}

#[derive(Default)]
pub struct MockFabric {
    regs: RefCell<BTreeMap<u32, u32>>,
    mem: RefCell<BTreeMap<u32, u32>>,
    pub log: RefCell<Vec<Ev>>,
    /// Entries after which the log stops growing (0 = no limit). For long runs on small heaps.
    pub log_limit: core::cell::Cell<usize>,
}

impl MockFabric {
    pub fn new() -> Self {
        Self::default()
    }
    /// Set a register as the logic would.
    pub fn poke(&self, addr: u32, value: u32) {
        self.regs.borrow_mut().insert(addr, value);
    }
    pub fn reg(&self, addr: u32) -> u32 {
        self.regs.borrow().get(&addr).copied().unwrap_or(0)
    }
    /// Set a memory word as the logic would (no log entry).
    pub fn poke_mem(&self, addr: u32, value: u32) {
        self.mem.borrow_mut().insert(addr, value);
    }
    pub fn mem(&self, addr: u32) -> u32 {
        self.mem.borrow().get(&addr).copied().unwrap_or(0)
    }
    pub fn reg_writes(&self, addr: u32) -> Vec<u32> {
        self.log.borrow().iter().filter_map(|e| if let Ev::RegWrite(a, v) = e { (*a == addr).then_some(*v) } else { None }).collect()
    }
    fn record(&self, e: Ev) {
        let mut log = self.log.borrow_mut();
        let limit = self.log_limit.get();
        if limit == 0 || log.len() < limit {
            log.push(e);
        }
    }
    pub fn clear_log(&self) {
        self.log.borrow_mut().clear();
    }

    /// Checks the 10 us rule for the pointer registers `ptrs`: every write of one of them that
    /// follows new memory writes must come after (1) a cache write-back covering each of those
    /// words and (2) waits adding up to [`BRIDGE_FLUSH_US`] after the last write-back. Returns the
    /// number of pointer writes that break it.
    pub fn flush_rule_violations(&self, ptrs: &[u32]) -> usize {
        let mut dirty: Vec<u32> = Vec::new();
        let mut waited = 0u32;
        let mut new_data = false;
        let mut bad = 0;
        for e in self.log.borrow().iter() {
            match *e {
                Ev::MemWrite(a, _) => {
                    dirty.push(a);
                    new_data = true;
                    waited = 0;
                }
                Ev::Writeback(a, len) => {
                    let (lo, hi) = (a & !31, (a + len + 31) & !31);
                    dirty.retain(|&d| d < lo || d >= hi);
                    waited = 0;
                }
                Ev::Delay(us) => waited += us,
                Ev::RegWrite(a, _) if ptrs.contains(&a) => {
                    if new_data && (!dirty.is_empty() || waited < BRIDGE_FLUSH_US) {
                        bad += 1;
                    }
                    new_data = false;
                }
                _ => {}
            }
        }
        bad
    }
}

impl RegisterSpace for MockFabric {
    fn read32(&self, addr: u32) -> u32 {
        self.reg(addr)
    }
    fn write32(&self, addr: u32, value: u32) {
        self.regs.borrow_mut().insert(addr, value);
        self.record(Ev::RegWrite(addr, value));
    }
}

impl FabricMem for MockFabric {
    fn write32(&self, addr: u32, value: u32) {
        assert!(addr % 4 == 0, "unaligned memory write {addr:#x}");
        self.mem.borrow_mut().insert(addr, value);
        self.record(Ev::MemWrite(addr, value));
    }
    fn read32(&self, addr: u32) -> u32 {
        self.mem(addr)
    }
    fn writeback(&self, addr: u32, len: u32) {
        self.record(Ev::Writeback(addr, len));
    }
    fn invalidate(&self, addr: u32, len: u32) {
        self.record(Ev::Invalidate(addr, len));
    }
    fn delay_us(&self, us: u32) {
        self.record(Ev::Delay(us));
    }
}
