// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Host-test stand-in for the chip's FT8 front end page and the DDR3 behind it (feature `mock`).
//!
//! [`FakeChip`] implements the page's register semantics (write-1-to-clear events, `cand_busy`
//! that stays up for a number of polls after a command, results that appear in DDR3 only when the
//! command completes) and a data cache between the CPU and DDR3 (the CPU reads through it; the
//! logic's writes go behind it, so only an `invalidate` makes new data visible). What the engines
//! compute is a [`ChipEngine`]: a pattern generator in this crate's tests, the bit-exact models of
//! F5-F7 in `tr-station`'s.
//!
//! It counts the two mistakes a driver can make: a `cand_*` register or `cand_cmd` written while
//! `cand_busy` is set ([`FakeChip::busy_violations`]), and a CPU read that returned data older
//! than what the logic had written ([`FakeChip::cache_stale_reads`]).
//!
//! The second pass (`p2_cmd`, docs/FT8_PASS2.md): the command is ignored while one runs, stays busy
//! for a number of polls, then the engine's `replay` writes spectrogram and records and `p2_done`
//! is set. CPU writes go to the cache and reach DDR3 only on `writeback`; a `p2_cmd` that arrives
//! while words of the residual buffer are still only in the cache, or without the bridge wait
//! after the write-back, is the third mistake counted ([`FakeChip::unflushed_at_command`]).

use alloc::collections::BTreeMap;
use alloc::vec::Vec;
use core::cell::{Cell, Ref, RefCell, RefMut};

use tr_regs::generated::ft8;
use tr_regs::RegisterSpace;

use crate::mem::FabricMem;

/// The logic's view of DDR3 (byte addresses, no cache).
pub trait LogicMem {
    fn put32(&mut self, byte_addr: u32, value: u32);
    fn get32(&self, byte_addr: u32) -> u32;
}

/// What the engines compute. Addresses are lane-word addresses as the registers hold them.
pub trait ChipEngine {
    /// A sync search over `rows` rows of the slot that starts at capture sample `first_sample`,
    /// bins `ia ..= ib`: write 4 lane words per bin at `rec_lw`.
    #[allow(clippy::too_many_arguments)]
    fn sync(&mut self, io: &mut dyn LogicMem, rx: u32, rows: u32, ia: u32, ib: u32, first_sample: u32, cap_lw: u32, rec_lw: u32);
    /// Pass 1 on one lane: the slot's audio from the ring at `cap_lw` to 3,200 baseband lane words at `bb_lw`.
    fn pass1(&mut self, io: &mut dyn LogicMem, lane: u32, inc: u32, first_sample: u32, cap_lw: u32, bb_lw: u32);
    /// Second pass (`p2_cmd`): the spectrogram of the residual audio at `audio_lw` (45,000 lane words
    /// from slot sample 0, power shift `sh`) to `spec_lw`, then its sync records for bins
    /// `ia ..= ib` to `rec_lw`.
    #[allow(clippy::too_many_arguments)]
    fn replay(&mut self, io: &mut dyn LogicMem, rx: u32, ia: u32, ib: u32, sh: u32, audio_lw: u32, spec_lw: u32, rec_lw: u32);
    /// Pass 2 on one lane: the baseband at `bb_lw` to 632 soft-symbol lane words at `sym_lw`.
    fn pass2(&mut self, io: &mut dyn LogicMem, lane: u32, rot_inc: u32, i0: i32, bb_lw: u32, sym_lw: u32);
}

struct Ddr<'a>(&'a RefCell<BTreeMap<u32, u32>>);

impl LogicMem for Ddr<'_> {
    fn put32(&mut self, byte_addr: u32, value: u32) {
        self.0.borrow_mut().insert(byte_addr, value);
    }
    fn get32(&self, byte_addr: u32) -> u32 {
        self.0.borrow().get(&byte_addr).copied().unwrap_or(0)
    }
}

#[derive(Clone, Copy)]
struct Cmd {
    pass2: bool,
    lanes: u32,
    inc: [u32; 2],
    i0: [i32; 2],
    bb: [u32; 2],
    sym: [u32; 2],
    cap: u32,
    first: u32,
}

pub struct FakeChip<E: ChipEngine> {
    regs: RefCell<BTreeMap<u32, u32>>,
    ddr: RefCell<BTreeMap<u32, u32>>,
    cache: RefCell<BTreeMap<u32, [u32; 8]>>,
    engine: RefCell<E>,
    /// Status/event reads a command stays busy for.
    busy_polls: Cell<u32>,
    busy_left: Cell<u32>,
    running: Cell<Option<Cmd>>,
    hold_busy: Cell<bool>,
    never_finish: Cell<bool>,
    stuck: RefCell<Vec<u32>>,
    writes: RefCell<Vec<u32>>,
    busy_violations: Cell<u32>,
    stale_reads: Cell<u32>,
    /// CPU-written words not yet written back (byte address -> value).
    dirty: RefCell<BTreeMap<u32, u32>>,
    /// A write-back happened and the bridge wait has not been taken since.
    bridge_pending: Cell<bool>,
    unflushed: Cell<u32>,
    p2_polls: Cell<u32>,
    p2_left: Cell<u32>,
    p2_running: Cell<Option<(u32, u32, u32, u32)>>,
    p2_never: Cell<bool>,
}

impl<E: ChipEngine> FakeChip<E> {
    pub fn new(engine: E) -> Self {
        let c = FakeChip {
            regs: RefCell::new(BTreeMap::new()),
            ddr: RefCell::new(BTreeMap::new()),
            cache: RefCell::new(BTreeMap::new()),
            engine: RefCell::new(engine),
            busy_polls: Cell::new(0),
            busy_left: Cell::new(0),
            running: Cell::new(None),
            hold_busy: Cell::new(false),
            never_finish: Cell::new(false),
            stuck: RefCell::new(Vec::new()),
            writes: RefCell::new(Vec::new()),
            busy_violations: Cell::new(0),
            stale_reads: Cell::new(0),
            dirty: RefCell::new(BTreeMap::new()),
            bridge_pending: Cell::new(false),
            unflushed: Cell::new(0),
            p2_polls: Cell::new(0),
            p2_left: Cell::new(0),
            p2_running: Cell::new(None),
            p2_never: Cell::new(false),
        };
        c.regs.borrow_mut().insert(ft8::id::addr(), ft8::id::RESET);
        c
    }

    pub fn engine(&self) -> Ref<'_, E> {
        self.engine.borrow()
    }
    pub fn engine_mut(&self) -> RefMut<'_, E> {
        self.engine.borrow_mut()
    }

    /// A command stays busy for this many reads of `status` / `irq_status` after it is written.
    pub fn set_busy_polls(&self, n: u32) {
        self.busy_polls.set(n);
    }
    /// `status.cand_busy` reads 1 whatever the engine does.
    pub fn hold_busy(&self, on: bool) {
        self.hold_busy.set(on);
    }
    /// Commands are accepted and never complete.
    pub fn never_finish(&self) {
        self.never_finish.set(true);
    }
    /// A second pass stays busy for this many reads of `status` / `irq_status`.
    pub fn set_p2_polls(&self, n: u32) {
        self.p2_polls.set(n);
    }
    /// `p2_cmd` is accepted and never completes (`on` = false: back to normal, the stuck one is dropped).
    pub fn p2_never_finish(&self, on: bool) {
        self.p2_never.set(on);
        if !on {
            self.p2_running.set(None);
        }
    }
    /// Words of the residual buffer that were not in DDR3 when `p2_cmd` came, plus commands that
    /// came without the bridge wait after the write-back.
    pub fn unflushed_at_command(&self) -> u32 {
        self.unflushed.get()
    }
    /// The register ignores writes (a page that is not what the driver expects).
    pub fn stuck(&self, addr: u32) {
        self.stuck.borrow_mut().push(addr);
    }
    /// The page answers a different id (the stub of the first board's image, or nothing).
    pub fn set_id(&self, id: u32) {
        self.poke_reg(ft8::id::addr(), id);
    }

    /// Register values as the logic would set them.
    pub fn poke_reg(&self, addr: u32, value: u32) {
        self.regs.borrow_mut().insert(addr, value);
    }
    pub fn reg(&self, addr: u32) -> u32 {
        self.regs.borrow().get(&addr).copied().unwrap_or(0)
    }
    /// Addresses of the registers the CPU wrote, in order.
    pub fn reg_write_order(&self) -> Vec<u32> {
        self.writes.borrow().clone()
    }
    pub fn clear_log(&self) {
        self.writes.borrow_mut().clear();
    }
    /// A word as the logic would write it (behind the cache).
    pub fn poke_ddr(&self, byte_addr: u32, value: u32) {
        self.ddr.borrow_mut().insert(byte_addr, value);
    }
    pub fn ddr(&self, byte_addr: u32) -> u32 {
        self.ddr.borrow().get(&byte_addr).copied().unwrap_or(0)
    }

    pub fn busy_violations(&self) -> u32 {
        self.busy_violations.get()
    }
    pub fn cache_stale_reads(&self) -> u32 {
        self.stale_reads.get()
    }

    /// A sync search of receiver `rx` over `rows` rows finishes: the engine writes the records and
    /// the event is set.
    pub fn finish_sync(&self, rx: u32, rows: u32) {
        let band = ft8::band::read(self, rx);
        let (cap, rec) = (self.reg(ft8::cap_base::addr(rx)), self.reg(ft8::rec_base::addr(rx)));
        let first = self.reg(ft8::slot_boundary::addr(rx));
        self.engine.borrow_mut().sync(&mut Ddr(&self.ddr), rx, rows, band.ia(), band.ib(), first, cap, rec);
        self.poke_reg(ft8::sync_rows::addr(rx), rows);
        let irq = self.reg(ft8::irq_status::addr());
        self.poke_reg(ft8::irq_status::addr(), irq | (1 << rx));
    }

    fn is_cand_reg(addr: u32) -> bool {
        addr == ft8::cand_cmd::addr()
            || addr == ft8::cand_cap_base::addr()
            || addr == ft8::cand_first_sample::addr()
            || (0..2).any(|l| {
                addr == ft8::cand_inc::addr(l) || addr == ft8::cand_i0::addr(l) || addr == ft8::cand_bb_base::addr(l) || addr == ft8::cand_sym_base::addr(l)
            })
    }

    fn start(&self) {
        let cmd = ft8::cand_cmd::read(self);
        let l = |f: fn(u32) -> u32| [self.reg(f(0)), self.reg(f(1))];
        let i0 = l(ft8::cand_i0::addr);
        self.running.set(Some(Cmd {
            pass2: cmd.pass2(),
            lanes: cmd.lanes(),
            inc: l(ft8::cand_inc::addr),
            i0: [i0[0] as u16 as i16 as i32, i0[1] as u16 as i16 as i32],
            bb: l(ft8::cand_bb_base::addr),
            sym: l(ft8::cand_sym_base::addr),
            cap: self.reg(ft8::cand_cap_base::addr()),
            first: self.reg(ft8::cand_first_sample::addr()),
        }));
        self.busy_left.set(self.busy_polls.get());
        self.maybe_complete();
    }

    fn maybe_complete(&self) {
        let Some(c) = self.running.get() else { return };
        if self.busy_left.get() > 0 || self.never_finish.get() {
            return;
        }
        for lane in 0..2u32 {
            if c.lanes & (1 << lane) == 0 {
                continue;
            }
            let k = lane as usize;
            let mut e = self.engine.borrow_mut();
            if c.pass2 {
                e.pass2(&mut Ddr(&self.ddr), lane, c.inc[k], c.i0[k], c.bb[k], c.sym[k]);
            } else {
                e.pass1(&mut Ddr(&self.ddr), lane, c.inc[k], c.first, c.cap, c.bb[k]);
            }
        }
        self.running.set(None);
        let irq = self.reg(ft8::irq_status::addr());
        self.poke_reg(ft8::irq_status::addr(), irq | (1 << 8));
    }

    fn poll(&self) {
        if self.running.get().is_some() && self.busy_left.get() > 0 {
            self.busy_left.set(self.busy_left.get() - 1);
        }
        self.maybe_complete();
        if self.p2_running.get().is_some() && self.p2_left.get() > 0 {
            self.p2_left.set(self.p2_left.get() - 1);
        }
        self.p2_maybe_complete();
    }

    fn p2_start(&self) {
        let rx = ft8::p2_cmd::read(self).rx();
        // The chip keeps the base's upper bits only; the three parts of the area are fixed.
        let base = self.reg(ft8::p2_base::addr()) & !0x7_FFFF & 0x7FF_FFFF;
        let (audio, spec, rec) = (base, base + 0x1_0000, base + 0x4_0000);
        // The logic reads DDR3: residual words still only in the cache are the driver's mistake.
        let lo = audio * 8;
        let n = self.dirty.borrow().range(lo..lo + 45_000 * 8).count() as u32;
        self.unflushed.set(self.unflushed.get() + n + self.bridge_pending.get() as u32);
        self.p2_running.set(Some((rx, audio, spec, rec)));
        self.p2_left.set(self.p2_polls.get());
        self.p2_maybe_complete();
    }

    fn p2_maybe_complete(&self) {
        let Some((rx, audio, spec, rec)) = self.p2_running.get() else { return };
        if self.p2_left.get() > 0 || self.p2_never.get() {
            return;
        }
        let band = ft8::band::read(self, rx);
        let sh = ft8::ctrl::read(self, rx).pwr_shift();
        self.engine.borrow_mut().replay(&mut Ddr(&self.ddr), rx, band.ia(), band.ib(), sh, audio, spec, rec);
        self.p2_running.set(None);
        let irq = self.reg(ft8::irq_status::addr());
        self.poke_reg(ft8::irq_status::addr(), irq | (1 << ft8::irq_status::P2_DONE_LSB));
    }
}

impl<E: ChipEngine> RegisterSpace for FakeChip<E> {
    fn read32(&self, addr: u32) -> u32 {
        if addr == ft8::status::addr() {
            self.poll();
            let busy = self.hold_busy.get() || self.running.get().is_some();
            return (busy as u32) << ft8::status::CAND_BUSY_LSB | (self.p2_running.get().is_some() as u32) << ft8::status::P2_BUSY_LSB;
        }
        if addr == ft8::irq_status::addr() {
            self.poll();
        }
        self.reg(addr)
    }

    fn write32(&self, addr: u32, value: u32) {
        self.writes.borrow_mut().push(addr);
        if Self::is_cand_reg(addr) && (self.hold_busy.get() || self.running.get().is_some()) {
            self.busy_violations.set(self.busy_violations.get() + 1);
            return;
        }
        if self.stuck.borrow().contains(&addr) {
            return;
        }
        if addr == ft8::irq_status::addr() {
            // Write 1 to clear.
            let v = self.reg(addr) & !value;
            self.poke_reg(addr, v);
            return;
        }
        if addr == ft8::p2_cmd::addr() && self.p2_running.get().is_some() {
            // The chip ignores a second-pass command while one runs.
            return;
        }
        self.poke_reg(addr, value);
        if addr == ft8::cand_cmd::addr() {
            self.start();
        }
        if addr == ft8::p2_cmd::addr() {
            self.p2_start();
        }
    }
}

impl<E: ChipEngine> FabricMem for FakeChip<E> {
    fn write32(&self, addr: u32, value: u32) {
        // Into the cache: the word reaches DDR3 (where the logic reads) with `writeback`.
        self.dirty.borrow_mut().insert(addr, value);
        if let Some(l) = self.cache.borrow_mut().get_mut(&(addr & !31)) {
            l[((addr & 31) / 4) as usize] = value;
        }
    }

    fn read32(&self, addr: u32) -> u32 {
        if let Some(&v) = self.dirty.borrow().get(&addr) {
            return v;
        }
        let line = addr & !31;
        let mut cache = self.cache.borrow_mut();
        let ddr = self.ddr.borrow();
        let l = cache.entry(line).or_insert_with(|| core::array::from_fn(|i| ddr.get(&(line + 4 * i as u32)).copied().unwrap_or(0)));
        let v = l[((addr & 31) / 4) as usize];
        if v != ddr.get(&addr).copied().unwrap_or(0) {
            self.stale_reads.set(self.stale_reads.get() + 1);
        }
        v
    }

    fn writeback(&self, addr: u32, len: u32) {
        let mut dirty = self.dirty.borrow_mut();
        let keys: Vec<u32> = dirty.range(addr & !31..addr + len).map(|(&a, _)| a).collect();
        for a in keys {
            if let Some(v) = dirty.remove(&a) {
                self.ddr.borrow_mut().insert(a, v);
            }
        }
        self.bridge_pending.set(true);
    }

    fn invalidate(&self, addr: u32, len: u32) {
        let mut cache = self.cache.borrow_mut();
        let mut a = addr & !31;
        while a < addr + len {
            cache.remove(&a);
            a += 32;
        }
    }

    fn delay_us(&self, us: u32) {
        if us >= crate::mem::BRIDGE_FLUSH_US {
            self.bridge_pending.set(false);
        }
    }
}
