// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! FT8 decoder front end (`hw/regmap/ft8.toml`, docs/ARCHITECTURE.md 3.12, docs/F7_CAND.md).
//!
//! Two types:
//!
//! - [`Ft8FrontEnd`]: the id only. `engines_present()` is how the firmware chooses between the
//!   chip's engines and the software decoder at start (the page of the first board's image
//!   answered 0x4638_0000, "version 0", and had no registers).
//! - [`Ft8Engines`]: the engines. Per receiver: set-up ([`Ft8Engines::setup_rx`]), slot start
//!   ([`Ft8Engines::start_slot`]), the sync records when a search is done
//!   ([`Ft8Engines::take_sync`]); per pair of candidates the candidate engine's two passes
//!   ([`Ft8Engines::pass1`], [`Ft8Engines::pass2`]) and the words they leave
//!   ([`Ft8Engines::read_baseband`], [`Ft8Engines::read_symbols`]).
//!
//! **The rules of the register page are built in, so a caller cannot get them wrong:**
//!
//! 1. `cand_cmd` and the `cand_*` registers are written only while `status.cand_busy` is 0
//!    (every pass waits for it first, and a wait that does not end is an [`Error::Busy`]).
//! 2. A pass is finished when `irq_status.cand_done` is set (that bit means every output word is in
//!    DDR3), not when `cand_busy` falls; the bit is cleared before the next command.
//! 3. Everything the logic wrote (sync records, baseband, soft symbols) is read only through
//!    `take_sync`, `read_baseband` and `read_symbols`, and each of them drops the data-cache lines
//!    of the words first (the logic writes DDR3 behind the cache).
//! 4. Pass 2 works on the baseband that the immediately preceding pass 1 left in the lanes' buffers:
//!    [`Basebands`] is the receipt of that pass 1, and a new pass 1 makes every older receipt stale
//!    ([`Error::Stale`]).
//! 5. All DDR3 addresses written to the page are lane-word addresses (byte address / 8).
//! 6. The second pass (docs/FT8_PASS2.md, page version 2): [`Ft8Engines::start_residual`] writes the
//!    residual audio, writes the cache back, waits the bridge's 10 us and only then writes `p2_cmd`;
//!    it refuses while `status.p2_busy`. The records are read only through
//!    [`Ft8Engines::take_residual_sync`] (event first, cache lines dropped), and a newer residual
//!    makes the older [`Residual`] receipt stale.
//!
//! Interrupt 11 is not used: the firmware polls `irq_status` (the same event bits), which costs
//! two register reads per main-loop turn.

use core::cell::Cell;

use tr_regs::generated::ft8;
use tr_regs::RegisterSpace;

use crate::mem::FabricMem;

/// Id of the stub page.
pub const STUB_ID: u32 = 0x4638_0000;

/// Decoder receiver slots in the page's layout; the chip has [`Ft8Engines::receivers`] of them (1 to 8).
pub const MAX_RX: usize = 8;
/// Lanes of the candidate engine.
pub const LANES: usize = 2;
/// Baseband lane words per candidate (16 s at 200 sps).
pub const BB_WORDS: usize = 3_200;
/// Soft-symbol lane words per candidate (79 symbols x 8 tones).
pub const SYM_WORDS: usize = 632;
/// Lane words per sync record (8 x 32 bit).
pub const REC_LANE_WORDS: usize = 4;
/// Samples of a slot.
pub const SLOT_SAMPLES: u32 = 180_000;

/// Where the firmware puts what the FT8 engines read and write (byte addresses; docs/ARCHITECTURE.md
/// 5.4 has the rest of the map). 0x1300_0000 up is free: the back-end rings end at 0x127F_FFFF, the
/// audio ring is at 0x1280_0000 and the TX ring at 0x1290_0000.
pub mod map {
    /// Audio capture ring of receiver `rx`: 1 MB (2^19 samples, 4 per lane word).
    pub const fn cap(rx: u32) -> u32 {
        0x1300_0000 + rx * 0x10_0000
    }
    /// Spectrogram of receiver `rx`: 372 frames x 512 lane words = 1.5 MB, 2 MB apart.
    pub const fn spec(rx: u32) -> u32 {
        0x1380_0000 + rx * 0x20_0000
    }
    /// Sync records of receiver `rx`: 4 lane words (32 bytes) per carrier bin, 64 KB reserved.
    pub const fn rec(rx: u32) -> u32 {
        0x1480_0000 + rx * 0x1_0000
    }
    /// Baseband of candidate lane `lane` (3,200 lane words = 25,600 bytes), 32 KB apart.
    pub const fn baseband(lane: u32) -> u32 {
        0x1490_0000 + lane * 0x8000
    }
    /// Soft symbols of candidate lane `lane` (632 lane words = 5,056 bytes), 8 KB apart.
    pub const fn symbols(lane: u32) -> u32 {
        0x1491_0000 + lane * 0x2000
    }
    /// Second pass: its 4 MB area (`p2_base`; a multiple of 4 MB, the chip keeps only those bits).
    pub const RESIDUAL: u32 = 0x14C0_0000;
    /// The residual audio the CPU writes, at the start of the area (45,000 lane words = 360 KB).
    pub const RESIDUAL_AUDIO: u32 = RESIDUAL;
    /// The residual's spectrogram: 0x1_0000 lane words into the area (1.5 MB).
    pub const RESIDUAL_SPEC: u32 = RESIDUAL + 0x8_0000;
    /// The sync records of the residual: 0x4_0000 lane words into the area.
    pub const RESIDUAL_REC: u32 = RESIDUAL + 0x20_0000;
}

/// Driver for the id register of the FT8 front end page.
pub struct Ft8FrontEnd<'a, R: RegisterSpace> {
    regs: &'a R,
}

impl<'a, R: RegisterSpace> Ft8FrontEnd<'a, R> {
    /// A driver on the register space `regs`.
    pub fn new(regs: &'a R) -> Self {
        Ft8FrontEnd { regs }
    }

    /// The identification register of the block.
    pub fn id(&self) -> u32 {
        ft8::id::read(self.regs)
    }

    /// True when the chip has the engines (any version above the stub's 0): the firmware then
    /// uses them; false = decode in software.
    pub fn engines_present(&self) -> bool {
        let id = self.id();
        id >> 16 == STUB_ID >> 16 && id & 0xFFFF != 0
    }

    /// True when the engines can search a residual (page version 2 or later: the `p2_*` registers,
    /// docs/FT8_PASS2.md). Version 1 decodes one pass.
    pub fn has_second_pass(&self) -> bool {
        self.engines_present() && self.id() & 0xFFFF >= 2
    }
}

/// Why a call did not complete. After `Busy` or `Timeout` the engines are not to be trusted for
/// the rest of the slot: the firmware decodes that slot in software.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    /// `status.cand_busy` stayed set (nothing was written).
    Busy,
    /// The command was written and `cand_done` never came.
    Timeout,
    /// A register did not read back what was written at set-up.
    Readback,
    /// The receipt is from before the last pass of its kind.
    Stale,
    /// No candidates, more than [`LANES`], or a buffer of the wrong length.
    BadArgs,
    /// Receiver number or band out of range, or the receiver was not set up.
    BadRx,
}

/// One receiver's set-up (docs/F6_SYNC.md, `hw/regmap/ft8.toml`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RxConfig {
    /// First and last carrier bin of the sync search, 3.125 Hz apart (`ia` 32 = 100 Hz, `ib` at most 1,009).
    pub ia: u32,
    pub ib: u32,
    /// Spectrogram power shift (default 16).
    pub pwr_shift: u32,
    /// Early sync searches, in frames of the slot (295 = 11.8 s, 337 = 13.5 s); 0 = off. The search
    /// over all 372 frames always runs.
    pub trig1: u32,
    pub trig2: u32,
}

impl Default for RxConfig {
    fn default() -> Self {
        // 100 to 3,000 Hz as `frontend::sync::SyncBand::from_hz(100, 3000)`; no early searches.
        RxConfig { ia: 32, ib: 960, pwr_shift: 16, trig1: 0, trig2: 0 }
    }
}

impl RxConfig {
    pub fn bins(&self) -> usize {
        (self.ib - self.ia + 1) as usize
    }
}

/// A finished sync search, as `take_sync` found it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SyncInfo {
    pub rx: u32,
    /// Spectrogram rows the search covered (372 = the whole slot).
    pub rows: u32,
    /// Bins `ia ..= ib` were read, `bins` of them.
    pub ia: u32,
    pub ib: u32,
    pub bins: usize,
    /// Capture sample count of the first sample of the slot this search belongs to: the value
    /// `start_slot` wrote last before the search finished. Pass 1 needs it.
    pub first_sample: u32,
}

/// Receipt of a started second pass: the residual audio is in its DDR3 buffer and the chip is
/// replaying and searching it (or has finished).
#[derive(Clone, Copy, Debug)]
pub struct Residual {
    gen: u32,
    rx: u32,
}

impl Residual {
    pub fn rx(&self) -> u32 {
        self.rx
    }
}

/// Receipt of a pass 1: the basebands of `lanes` candidates are in the lanes' buffers.
#[derive(Clone, Copy, Debug)]
pub struct Basebands {
    gen: u32,
    lanes: usize,
}

impl Basebands {
    pub fn lanes(&self) -> usize {
        self.lanes
    }
}

/// Receipt of a pass 2: the soft symbols of `lanes` candidates are in the lanes' buffers.
#[derive(Clone, Copy, Debug)]
pub struct Symbols {
    gen: u32,
    lanes: usize,
}

impl Symbols {
    pub fn lanes(&self) -> usize {
        self.lanes
    }
}

/// What pass 2 needs per candidate (fine time and frequency, from the CPU's search on the baseband).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Pass2Job {
    /// Rotation increment `round((21.875 Hz - delf) x 2^32 / 200)` (`symbols::rot_inc`).
    pub rot_inc: u32,
    /// Start sample in the baseband (200 sps), signed.
    pub i0: i32,
}

/// Polls of the status register before a wait gives up, 2 us apart: 100 ms. A pair of candidates
/// takes 3.75 ms in the chip as built (pass 1 and pass 2 together, one lane run twice, 449,603 clocks at
/// 120 MHz, docs/THIN.md; 1.4 ms and 0.2 ms with two lanes, docs/F7_CAND.md): a margin of 25.
const WAIT_POLLS: u32 = 50_000;
const POLL_US: u32 = 2;

/// The engines of the page.
pub struct Ft8Engines<'a, R: RegisterSpace, M: FabricMem> {
    regs: &'a R,
    mem: &'a M,
    /// `start_slot`'s value per receiver.
    first_sample: [Cell<u32>; MAX_RX],
    cfg: [Cell<Option<RxConfig>>; MAX_RX],
    /// Receivers the chip was built with (`system.status.num_rx`, read once here).
    rx_count: usize,
    bb_gen: Cell<u32>,
    sym_gen: Cell<u32>,
    res_gen: Cell<u32>,
}

impl<'a, R: RegisterSpace, M: FabricMem> Ft8Engines<'a, R, M> {
    pub fn new(regs: &'a R, mem: &'a M) -> Self {
        Ft8Engines {
            regs,
            mem,
            rx_count: crate::system::System::new(regs).num_rx() as usize,
            first_sample: core::array::from_fn(|_| Cell::new(0)),
            cfg: core::array::from_fn(|_| Cell::new(None)),
            bb_gen: Cell::new(0),
            sym_gen: Cell::new(0),
            res_gen: Cell::new(0),
        }
    }

    /// Receivers the chip has (1 to 8): `rx` below it can be set up.
    pub fn receivers(&self) -> usize {
        self.rx_count
    }

    // ---- set-up --------------------------------------------------------------------------

    /// Once per receiver: buffers, band, triggers, capture and spectrogram on. Reads the base
    /// registers back; a mismatch is [`Error::Readback`] (the page is not what this driver was
    /// written for).
    pub fn setup_rx(&self, rx: u32, cfg: &RxConfig) -> Result<(), Error> {
        if rx as usize >= self.rx_count || cfg.ia > cfg.ib || cfg.ib > 1_009 || cfg.pwr_shift > 31 || cfg.trig1 > 372 || cfg.trig2 > 372 {
            return Err(Error::BadRx);
        }
        let r = self.regs;
        // Off while the buffers change.
        ft8::ctrl::write(r, rx, ft8::ctrl::Value(0));
        ft8::cap_base::write(r, rx, map::cap(rx) / 8);
        ft8::spec_base::write(r, rx, map::spec(rx) / 8);
        ft8::rec_base::write(r, rx, map::rec(rx) / 8);
        ft8::band::write(r, rx, ft8::band::Value(0).with_ia(cfg.ia).with_ib(cfg.ib));
        ft8::trig::write(r, rx, ft8::trig::Value(0).with_trig1(cfg.trig1).with_trig2(cfg.trig2));
        let ok = ft8::cap_base::read(r, rx) == map::cap(rx) / 8
            && ft8::spec_base::read(r, rx) == map::spec(rx) / 8
            && ft8::rec_base::read(r, rx) == map::rec(rx) / 8
            && ft8::band::read(r, rx).ia() == cfg.ia
            && ft8::band::read(r, rx).ib() == cfg.ib;
        if !ok {
            return Err(Error::Readback);
        }
        ft8::ctrl::write(r, rx, ft8::ctrl::Value(0).with_enable(true).with_pwr_shift(cfg.pwr_shift));
        self.cfg[rx as usize].set(Some(*cfg));
        Ok(())
    }

    /// Capture and spectrogram off for the receiver.
    pub fn disable_rx(&self, rx: u32) {
        if (rx as usize) < self.rx_count {
            ft8::ctrl::write(self.regs, rx, ft8::ctrl::Value(0));
            self.cfg[rx as usize].set(None);
        }
    }

    pub fn config(&self, rx: u32) -> Option<RxConfig> {
        self.cfg.get(rx as usize).and_then(|c| c.get())
    }

    /// Clears the sync events of the receivers in `mask` (bit r = receiver r). Only those bits are
    /// written: the register is write-1-to-clear and the other receivers' events stay.
    pub fn clear_sync_events(&self, mask: u32) {
        self.regs.write32(ft8::irq_status::addr(), mask & ft8::irq_status::SYNC_DONE_MASK);
    }

    // ---- slot ----------------------------------------------------------------------------

    /// Audio samples the receiver's capture has written since reset (ring position = this mod 2^19).
    pub fn capture_count(&self, rx: u32) -> u32 {
        ft8::cap_wr_ptr::read(self.regs, rx)
    }

    /// The capture dropped a sample at some time since reset.
    pub fn capture_overflow(&self) -> bool {
        ft8::status::read(self.regs).cap_overflow()
    }

    /// Starts a new slot for the receiver: `first_sample` is the capture sample count
    /// ([`Ft8Engines::capture_count`] units) of the slot's first sample. The spectrogram frame
    /// counter goes to 0, the sync triggers are re-armed, and the spectrogram of the previous slot
    /// is overwritten: call it only after that slot's last sync search is done and taken. A
    /// boundary that is already in the past is fine (the engine catches up on the audio in the
    /// ring); one in the future makes it wait.
    pub fn start_slot(&self, rx: u32, first_sample: u32) {
        self.first_sample[rx as usize].set(first_sample);
        ft8::slot_boundary::write(self.regs, rx, first_sample);
    }

    /// Spectrogram frames of the current slot written so far.
    pub fn frames(&self, rx: u32) -> u32 {
        ft8::frame_ptr::read(self.regs, rx).value()
    }

    /// Receivers whose sync search has finished and not yet been taken (bit r = receiver r).
    pub fn sync_pending(&self) -> u32 {
        ft8::irq_status::read(self.regs).sync_done()
    }

    /// If receiver `rx` has a finished sync search: clears its event, reads its records into `out`
    /// (as 8 words each, bins `ia ..= ib` in order; `out` must hold [`RxConfig::bins`] of them) and
    /// says what they are. `Ok(None)` if there is no finished search.
    pub fn take_sync(&self, rx: u32, out: &mut [[u32; 8]]) -> Result<Option<SyncInfo>, Error> {
        let cfg = self.config(rx).ok_or(Error::BadRx)?;
        if self.sync_pending() & (1 << rx) == 0 {
            return Ok(None);
        }
        if out.len() < cfg.bins() {
            return Err(Error::BadArgs);
        }
        // Clear first: a search that finishes while the records are read sets the bit again and is
        // taken on the next call.
        self.clear_sync_events(1 << rx);
        let rows = ft8::sync_rows::read(self.regs, rx).value();
        let bins = cfg.bins();
        self.read_records(map::rec(rx), bins, out);
        Ok(Some(SyncInfo { rx, rows, ia: cfg.ia, ib: cfg.ib, bins, first_sample: self.first_sample[rx as usize].get() }))
    }

    // ---- candidate engine ----------------------------------------------------------------

    fn wait_idle(&self) -> Result<(), Error> {
        for _ in 0..WAIT_POLLS {
            if !ft8::status::read(self.regs).cand_busy() {
                return Ok(());
            }
            self.mem.delay_us(POLL_US);
        }
        Err(Error::Busy)
    }

    fn wait_done(&self) -> Result<(), Error> {
        for _ in 0..WAIT_POLLS {
            if ft8::irq_status::read(self.regs).cand_done() {
                ft8::irq_status::clear_cand_done(self.regs);
                return Ok(());
            }
            self.mem.delay_us(POLL_US);
        }
        Err(Error::Timeout)
    }

    /// Pass 1 for up to two candidates of receiver `rx`'s slot (`first_sample` from [`SyncInfo`]):
    /// lane k mixes the audio at NCO increment `incs[k]` (`baseband::nco_inc(f0)`) down to its
    /// baseband. Returns when both basebands are in DDR3.
    pub fn pass1(&self, rx: u32, first_sample: u32, incs: &[u32]) -> Result<Basebands, Error> {
        if rx as usize >= self.rx_count {
            return Err(Error::BadRx);
        }
        self.pass1_at(map::cap(rx), first_sample, incs)
    }

    /// Pass 1 for up to two candidates of the second pass: as [`Ft8Engines::pass1`], on the residual
    /// audio of `res` (its buffer starts at the slot's first sample).
    pub fn pass1_residual(&self, res: &Residual, incs: &[u32]) -> Result<Basebands, Error> {
        if res.gen != self.res_gen.get() {
            return Err(Error::Stale);
        }
        self.pass1_at(map::RESIDUAL_AUDIO, 0, incs)
    }

    fn pass1_at(&self, cap_base: u32, first_sample: u32, incs: &[u32]) -> Result<Basebands, Error> {
        if incs.is_empty() || incs.len() > LANES {
            return Err(Error::BadArgs);
        }
        let r = self.regs;
        self.wait_idle()?;
        ft8::irq_status::clear_cand_done(r);
        ft8::cand_cap_base::write(r, cap_base / 8);
        ft8::cand_first_sample::write(r, first_sample);
        for (k, &inc) in incs.iter().enumerate() {
            ft8::cand_inc::write(r, k as u32, inc);
            ft8::cand_bb_base::write(r, k as u32, map::baseband(k as u32) / 8);
        }
        // New basebands: every older receipt is stale from here on.
        let gen = self.bb_gen.get().wrapping_add(1);
        self.bb_gen.set(gen);
        ft8::cand_cmd::write(r, ft8::cand_cmd::Value(0).with_pass2(false).with_lanes((1 << incs.len()) - 1));
        self.wait_done()?;
        Ok(Basebands { gen, lanes: incs.len() })
    }

    /// The baseband of `bb`'s lane `lane` as (re, im) pairs, 3,200 of them (`out.len()` must be
    /// [`BB_WORDS`]).
    pub fn read_baseband(&self, bb: &Basebands, lane: usize, out: &mut [(i32, i32)]) -> Result<(), Error> {
        if bb.gen != self.bb_gen.get() {
            return Err(Error::Stale);
        }
        if lane >= bb.lanes || out.len() != BB_WORDS {
            return Err(Error::BadArgs);
        }
        self.read_words(map::baseband(lane as u32), out);
        Ok(())
    }

    /// Pass 2 on the basebands of `bb` (one job per lane, in lane order): rotates by `rot_inc`,
    /// starts at `i0` and writes the 79 x 8 soft-symbol words. Returns when they are in DDR3.
    pub fn pass2(&self, bb: &Basebands, jobs: &[Pass2Job]) -> Result<Symbols, Error> {
        if bb.gen != self.bb_gen.get() {
            return Err(Error::Stale);
        }
        if jobs.is_empty() || jobs.len() > bb.lanes {
            return Err(Error::BadArgs);
        }
        let r = self.regs;
        self.wait_idle()?;
        ft8::irq_status::clear_cand_done(r);
        for (k, j) in jobs.iter().enumerate() {
            let k = k as u32;
            ft8::cand_inc::write(r, k, j.rot_inc);
            ft8::cand_i0::write(r, k, ft8::cand_i0::Value(0).with_value(j.i0 as u32 & 0xFFFF));
            ft8::cand_sym_base::write(r, k, map::symbols(k) / 8);
        }
        let gen = self.sym_gen.get().wrapping_add(1);
        self.sym_gen.set(gen);
        ft8::cand_cmd::write(r, ft8::cand_cmd::Value(0).with_pass2(true).with_lanes((1 << jobs.len()) - 1));
        self.wait_done()?;
        Ok(Symbols { gen, lanes: jobs.len() })
    }

    /// The soft symbols of `sy`'s lane `lane`: 632 (re, im) pairs, 8 tones per symbol in order
    /// (`out.len()` must be [`SYM_WORDS`]).
    pub fn read_symbols(&self, sy: &Symbols, lane: usize, out: &mut [(i32, i32)]) -> Result<(), Error> {
        if sy.gen != self.sym_gen.get() {
            return Err(Error::Stale);
        }
        if lane >= sy.lanes || out.len() != SYM_WORDS {
            return Err(Error::BadArgs);
        }
        self.read_words(map::symbols(lane as u32), out);
        Ok(())
    }

    /// `out.len()` lane words from `base` as (re, im) (re in the low half): cache lines first.
    fn read_words(&self, base: u32, out: &mut [(i32, i32)]) {
        self.mem.invalidate(base, (out.len() * 8) as u32);
        for (i, o) in out.iter_mut().enumerate() {
            let a = base + (i * 8) as u32;
            *o = (self.mem.read32(a) as i32, self.mem.read32(a + 4) as i32);
        }
    }

    // ---- second pass (docs/FT8_PASS2.md) ---------------------------------------------------

    /// True when the page has the second pass (version 2 or later).
    pub fn has_second_pass(&self) -> bool {
        Ft8FrontEnd::new(self.regs).has_second_pass()
    }

    /// Starts the second pass of receiver `rx`: writes the slot of residual audio (`audio`, from the
    /// slot's first sample; shorter is padded with zeros) to its DDR3 buffer, makes sure the logic
    /// can read it, and tells the chip to compute its spectrogram and search it with the receiver's
    /// band and power shift. Returns at once; the chip takes about 0.14 s
    /// ([`Ft8Engines::residual_done`]). `Err(Busy)` (nothing written) while an earlier one runs.
    pub fn start_residual(&self, rx: u32, audio: &[i16]) -> Result<Residual, Error> {
        self.config(rx).ok_or(Error::BadRx)?;
        let r = self.regs;
        if ft8::status::read(r).p2_busy() {
            return Err(Error::Busy);
        }
        let base = map::RESIDUAL_AUDIO;
        let s = |i: usize| audio.get(i).copied().unwrap_or(0) as u16 as u32;
        for w in 0..(SLOT_SAMPLES as usize / 4) {
            let a = base + (w * 8) as u32;
            self.mem.write32(a, s(4 * w) | (s(4 * w + 1) << 16));
            self.mem.write32(a + 4, s(4 * w + 2) | (s(4 * w + 3) << 16));
        }
        // The logic reads DDR3, not the cache: write back, wait for the bridge, then the command.
        let _flushed = crate::mem::flush_for_logic(self.mem, &[(base, SLOT_SAMPLES * 2)]);
        ft8::irq_status::clear_p2_done(r);
        ft8::p2_base::write(r, ft8::p2_base::Value(0).with_value(map::RESIDUAL / 8));
        let gen = self.res_gen.get().wrapping_add(1);
        self.res_gen.set(gen);
        ft8::p2_cmd::write(r, ft8::p2_cmd::Value(0).with_rx(rx));
        Ok(Residual { gen, rx })
    }

    /// The residual's records are in DDR3 (and not yet taken).
    pub fn residual_done(&self) -> bool {
        ft8::irq_status::read(self.regs).p2_done()
    }

    /// Frames of the residual's spectrogram written so far (0-372), for reports.
    pub fn residual_frames(&self) -> u32 {
        ft8::p2_frame::read(self.regs).value()
    }

    /// If the search of `res` has finished: clears its event and reads its records into `out` (as
    /// [`Ft8Engines::take_sync`]). `first_sample` of the answer is 0: the residual buffer starts at
    /// the slot's first sample. `Ok(None)` while the chip is still at it.
    pub fn take_residual_sync(&self, res: &Residual, out: &mut [[u32; 8]]) -> Result<Option<SyncInfo>, Error> {
        if res.gen != self.res_gen.get() {
            return Err(Error::Stale);
        }
        let cfg = self.config(res.rx).ok_or(Error::BadRx)?;
        let bins = cfg.bins();
        if out.len() < bins {
            return Err(Error::BadArgs);
        }
        if !self.residual_done() {
            return Ok(None);
        }
        ft8::irq_status::clear_p2_done(self.regs);
        self.read_records(map::RESIDUAL_REC, bins, out);
        Ok(Some(SyncInfo { rx: res.rx, rows: 372, ia: cfg.ia, ib: cfg.ib, bins, first_sample: 0 }))
    }

    /// `bins` sync records from `base` (4 lane words each): cache lines first.
    fn read_records(&self, base: u32, bins: usize, out: &mut [[u32; 8]]) {
        self.mem.invalidate(base, (bins * REC_LANE_WORDS * 8) as u32);
        for (i, rec) in out.iter_mut().take(bins).enumerate() {
            for w in 0..REC_LANE_WORDS {
                let a = base + ((i * REC_LANE_WORDS + w) * 8) as u32;
                rec[2 * w] = self.mem.read32(a);
                rec[2 * w + 1] = self.mem.read32(a + 4);
            }
        }
    }

    /// The first-sample count `start_slot` wrote last for the receiver.
    pub fn slot_first_sample(&self, rx: u32) -> u32 {
        self.first_sample[rx as usize].get()
    }

    /// The receiver's captured audio from capture sample `first_sample` on, `out.len()` samples (the
    /// ring is 2^19 samples; the range may wrap). For the second pass (the subtraction needs the
    /// slot's audio) and for tests. Two memory reads per four samples.
    pub fn read_audio(&self, rx: u32, first_sample: u32, out: &mut [i16]) {
        const RING_WORDS: u32 = 1 << 17;
        let base = map::cap(rx);
        let start = first_sample & (RING_WORDS * 4 - 1);
        let w0 = start / 4;
        let w1 = (start + out.len() as u32).div_ceil(4);
        let first = (w1.min(RING_WORDS) - w0) * 8;
        self.mem.invalidate(base + w0 * 8, first);
        if w1 > RING_WORDS {
            self.mem.invalidate(base, (w1 - RING_WORDS) * 8);
        }
        let (mut word, mut lo, mut hi) = (u32::MAX, 0u32, 0u32);
        for (k, o) in out.iter_mut().enumerate() {
            let pos = start.wrapping_add(k as u32) & (RING_WORDS * 4 - 1);
            if pos / 4 != word {
                word = pos / 4;
                lo = self.mem.read32(base + word * 8);
                hi = self.mem.read32(base + word * 8 + 4);
            }
            let half = if pos % 4 < 2 { lo } else { hi };
            *o = (half >> ((pos % 2) * 16)) as u16 as i16;
        }
    }

    /// Waits `us` microseconds (the memory driver's timer), for callers that poll `take_sync`.
    pub fn wait_us(&self, us: u32) {
        self.mem.delay_us(us);
    }

    /// The last candidate command's length in clk_dsp clocks (120 MHz; for reports).
    pub fn last_cand_clocks(&self) -> u32 {
        ft8::cand_clocks::read(self.regs)
    }

    /// The last sync search's length in clk_dsp clocks (120 MHz; for reports).
    pub fn last_sync_clocks(&self) -> u32 {
        ft8::sync_clocks::read(self.regs)
    }
}

#[cfg(any(test, feature = "mock"))]
pub mod chip_mock;

#[cfg(test)]
mod tests {
    use super::chip_mock::{ChipEngine, FakeChip, LogicMem};
    use super::*;
    use alloc::vec::Vec;
    use crate::mock::MockFabric;

    #[test]
    fn stub_is_recognised() {
        let f = MockFabric::new();
        let fe = Ft8FrontEnd::new(&f);
        f.poke(ft8::id::addr(), STUB_ID);
        assert!(!fe.engines_present());
        f.poke(ft8::id::addr(), STUB_ID | 1);
        assert!(fe.engines_present());
        f.poke(ft8::id::addr(), 0xDEAD_BEEF);
        assert!(!fe.engines_present());
    }

    /// An engine that writes recognisable words: baseband word i of a pass = (inc, i), soft symbol
    /// word i = (i0 + the baseband's first re word, rot_inc), and record bin b word w = b * 8 + w
    /// + rx * 1,000 + the offset the test sets.
    #[derive(Default)]
    struct Pattern {
        pass1_calls: u32,
        last_first_sample: u32,
        last_cap_base: u32,
        rec_offset: u32,
        replays: u32,
    }

    impl ChipEngine for Pattern {
        fn sync(&mut self, io: &mut dyn LogicMem, rx: u32, rows: u32, ia: u32, ib: u32, _first_sample: u32, _cap_lw: u32, rec_lw: u32) {
            assert!(rows == 372 || rows == 295);
            for b in 0..=(ib - ia) {
                for w in 0..8u32 {
                    io.put32(rec_lw * 8 + (b * 8 + w) * 4, b * 8 + w + rx * 1_000 + self.rec_offset);
                }
            }
        }
        fn pass1(&mut self, io: &mut dyn LogicMem, _lane: u32, inc: u32, first_sample: u32, cap_lw: u32, bb_lw: u32) {
            self.pass1_calls += 1;
            self.last_first_sample = first_sample;
            self.last_cap_base = cap_lw;
            for i in 0..BB_WORDS as u32 {
                io.put32(bb_lw * 8 + i * 8, inc);
                io.put32(bb_lw * 8 + i * 8 + 4, i);
            }
        }
        fn replay(&mut self, io: &mut dyn LogicMem, rx: u32, ia: u32, ib: u32, sh: u32, audio_lw: u32, spec_lw: u32, rec_lw: u32) {
            self.replays += 1;
            // Record bin b word w = the residual's lane word b (low half) + w + sh, so a test sees
            // that the audio was in DDR3 (not only in the cache) when the command came.
            for b in 0..=(ib - ia) {
                for w in 0..8u32 {
                    io.put32(rec_lw * 8 + (b * 8 + w) * 4, io.get32(audio_lw * 8 + b * 8).wrapping_add(w + sh + rx * 1_000));
                }
            }
            io.put32(spec_lw * 8, 0x5EC7_0000 + rx);
        }
        fn pass2(&mut self, io: &mut dyn LogicMem, _lane: u32, rot_inc: u32, i0: i32, bb_lw: u32, sym_lw: u32) {
            // The baseband must be the one pass 1 left in this lane's buffer.
            let first = io.get32(bb_lw * 8);
            for i in 0..SYM_WORDS as u32 {
                io.put32(sym_lw * 8 + i * 8, (i0 as u32).wrapping_add(first));
                io.put32(sym_lw * 8 + i * 8 + 4, rot_inc);
            }
        }
    }

    fn chip() -> FakeChip<Pattern> {
        FakeChip::new(Pattern::default())
    }

    #[test]
    fn setup_writes_lane_word_addresses_and_reads_them_back() {
        let c = chip();
        let e = Ft8Engines::new(&c, &c);
        e.setup_rx(3, &RxConfig::default()).unwrap();
        assert_eq!(c.reg(ft8::cap_base::addr(3)), map::cap(3) / 8);
        assert_eq!(c.reg(ft8::spec_base::addr(3)), map::spec(3) / 8);
        assert_eq!(c.reg(ft8::rec_base::addr(3)), map::rec(3) / 8);
        assert_eq!(ft8::band::read(&c, 3).ia(), 32);
        assert_eq!(ft8::band::read(&c, 3).ib(), 960);
        let ctrl = ft8::ctrl::read(&c, 3);
        assert!(ctrl.enable());
        assert_eq!(ctrl.pwr_shift(), 16);
        // Enable is the last write: the buffers are in place before the receiver runs.
        let w = c.reg_write_order();
        let en = w.iter().rposition(|&a| a == ft8::ctrl::addr(3)).unwrap();
        let base = w.iter().rposition(|&a| a == ft8::rec_base::addr(3)).unwrap();
        assert!(base < en);
        // Out of range.
        assert_eq!(e.setup_rx(8, &RxConfig::default()), Err(Error::BadRx));
        assert_eq!(e.setup_rx(0, &RxConfig { ib: 1_010, ..RxConfig::default() }), Err(Error::BadRx));
    }

    #[test]
    fn a_register_that_does_not_read_back_is_reported() {
        let c = chip();
        c.stuck(ft8::rec_base::addr(0));
        let e = Ft8Engines::new(&c, &c);
        assert_eq!(e.setup_rx(0, &RxConfig::default()), Err(Error::Readback));
        assert!(!ft8::ctrl::read(&c, 0).enable());
    }

    #[test]
    fn take_sync_clears_only_its_receiver_and_reads_the_records_through_the_cache() {
        let c = chip();
        let e = Ft8Engines::new(&c, &c);
        for rx in [1, 2] {
            e.setup_rx(rx, &RxConfig { ia: 100, ib: 109, ..RxConfig::default() }).unwrap();
        }
        e.start_slot(2, 777);
        assert_eq!(c.reg(ft8::slot_boundary::addr(2)), 777);
        let mut out = [[0u32; 8]; 10];
        assert_eq!(e.take_sync(1, &mut out), Ok(None));
        // Receivers 1 and 2 both finish a search.
        c.finish_sync(1, 372);
        c.finish_sync(2, 372);
        assert_eq!(e.sync_pending(), 0b110);
        let info = e.take_sync(2, &mut out).unwrap().unwrap();
        assert_eq!((info.rx, info.rows, info.ia, info.ib, info.bins, info.first_sample), (2, 372, 100, 109, 10, 777));
        assert_eq!(out[0][0], 2_000);
        assert_eq!(out[9][7], 9 * 8 + 7 + 2_000);
        // Receiver 1's event is still there.
        assert_eq!(e.sync_pending(), 0b010);
        // A second search for receiver 2 with different data: stale cache lines must not show.
        c.engine_mut().rec_offset = 5_000;
        c.finish_sync(2, 295);
        let info = e.take_sync(2, &mut out).unwrap().unwrap();
        assert_eq!(info.rows, 295);
        assert_eq!(out[0][0], 5_000 + 2_000);
        assert_eq!(c.cache_stale_reads(), 0);
        // Too small a buffer.
        assert_eq!(e.take_sync(1, &mut out[..5]), Err(Error::BadArgs));
    }

    #[test]
    fn pass1_and_pass2_follow_the_rules_of_the_page() {
        let c = chip();
        c.set_busy_polls(7);
        let e = Ft8Engines::new(&c, &c);
        e.setup_rx(5, &RxConfig::default()).unwrap();
        let bb = e.pass1(5, 4_321, &[0x1111, 0x2222]).unwrap();
        assert_eq!(bb.lanes(), 2);
        assert_eq!(c.engine().pass1_calls, 2);
        assert_eq!((c.engine().last_first_sample, c.engine().last_cap_base), (4_321, map::cap(5) / 8));
        let (mut a, mut b) = ([(0, 0); BB_WORDS], [(0, 0); BB_WORDS]);
        e.read_baseband(&bb, 0, &mut a).unwrap();
        e.read_baseband(&bb, 1, &mut b).unwrap();
        assert_eq!((a[0], a[3_199]), ((0x1111, 0), (0x1111, 3_199)));
        assert_eq!(b[7], (0x2222, 7));
        let sy = e.pass2(&bb, &[Pass2Job { rot_inc: 9, i0: -3 }, Pass2Job { rot_inc: 10, i0: 4 }]).unwrap();
        let (mut s0, mut s1) = ([(0, 0); SYM_WORDS], [(0, 0); SYM_WORDS]);
        e.read_symbols(&sy, 0, &mut s0).unwrap();
        e.read_symbols(&sy, 1, &mut s1).unwrap();
        assert_eq!(s0[5], (-3i32 + 0x1111, 9));
        assert_eq!(s1[631], (4 + 0x2222, 10));
        // The page's rules, as the fake chip counted them.
        assert_eq!(c.busy_violations(), 0, "a cand_* register or cand_cmd written while cand_busy");
        assert_eq!(c.cache_stale_reads(), 0);
        // A second pair with a single candidate (one lane): only lane 0 runs, and the first pair's
        // receipts are stale.
        let bb2 = e.pass1(5, 4_321, &[0x3333]).unwrap();
        assert_eq!(bb2.lanes(), 1);
        assert_eq!(e.read_baseband(&bb, 0, &mut a), Err(Error::Stale));
        assert_eq!(e.pass2(&bb, &[Pass2Job { rot_inc: 1, i0: 0 }]).unwrap_err(), Error::Stale);
        e.read_baseband(&bb2, 0, &mut a).unwrap();
        assert_eq!(a[0], (0x3333, 0), "stale cache lines of the first pair were not dropped");
        assert_eq!(e.read_baseband(&bb2, 1, &mut b), Err(Error::BadArgs));
        let sy2 = e.pass2(&bb2, &[Pass2Job { rot_inc: 2, i0: 1 }]).unwrap();
        e.read_symbols(&sy2, 0, &mut s0).unwrap();
        assert_eq!(s0[0], (1 + 0x3333, 2));
        assert_eq!(e.read_symbols(&sy, 0, &mut s0), Err(Error::Stale));
        assert_eq!(c.busy_violations(), 0);
        assert_eq!(c.cache_stale_reads(), 0);
        // More jobs than lanes in the receipt, none at all, too many candidates.
        assert_eq!(e.pass2(&bb2, &[Pass2Job { rot_inc: 1, i0: 0 }; 2]).unwrap_err(), Error::BadArgs);
        assert_eq!(e.pass1(5, 0, &[]).unwrap_err(), Error::BadArgs);
        assert_eq!(e.pass1(5, 0, &[1, 2, 3]).unwrap_err(), Error::BadArgs);
    }

    #[test]
    fn the_second_pass_follows_the_rules_of_the_page() {
        let c = chip();
        c.set_p2_polls(3);
        let e = Ft8Engines::new(&c, &c);
        assert!(e.has_second_pass());
        e.setup_rx(2, &RxConfig { ia: 100, ib: 109, pwr_shift: 14, ..RxConfig::default() }).unwrap();
        assert_eq!(e.start_residual(5, &[0; 8]).unwrap_err(), Error::BadRx, "receiver 5 is not set up");
        // The residual: sample k = k, so lane word b holds 4b | (4b + 1) << 16 in its low half.
        let audio: Vec<i16> = (0..SLOT_SAMPLES as i32).map(|k| (k % 30_000) as i16).collect();
        c.clear_log();
        let res = e.start_residual(2, &audio).unwrap();
        // The command is the last register write, after the area's base (a lane-word address,
        // a multiple of 2^19 as the chip wants it).
        let w = c.reg_write_order();
        assert_eq!(*w.last().unwrap(), ft8::p2_cmd::addr());
        assert_eq!(c.reg(ft8::p2_base::addr()), map::RESIDUAL / 8);
        assert_eq!((map::RESIDUAL / 8) & 0x7_FFFF, 0);
        assert_eq!(ft8::p2_cmd::read(&c).rx(), 2);
        // The whole slot is in DDR3, 4 samples per lane word, and was written back before the command.
        assert_eq!(c.ddr(map::RESIDUAL_AUDIO + 8), 4 | (5 << 16));
        assert_eq!(c.ddr(map::RESIDUAL_AUDIO + 8 + 4), 6 | (7 << 16));
        assert_eq!(c.ddr(map::RESIDUAL_AUDIO + 44_999 * 8 + 4), (179_998 % 30_000) | ((179_999 % 30_000) << 16));
        assert_eq!(c.unflushed_at_command(), 0, "p2_cmd written before the residual was written back and the bridge waited");
        // Busy: a second start is refused and writes nothing.
        c.clear_log();
        assert_eq!(e.start_residual(2, &audio).unwrap_err(), Error::Busy);
        assert!(c.reg_write_order().is_empty(), "wrote to a busy second pass");
        // Not done yet, then done.
        let mut out = [[0u32; 8]; 10];
        assert_eq!(e.take_residual_sync(&res, &mut out), Ok(None));
        while !e.residual_done() {}
        let info = e.take_residual_sync(&res, &mut out).unwrap().unwrap();
        assert_eq!((info.rx, info.rows, info.ia, info.ib, info.bins, info.first_sample), (2, 372, 100, 109, 10, 0));
        assert_eq!(out[0][0], (1 << 16) + 14 + 2_000, "bin 0 word 0: lane word 0 + shift 14 + rx 2");
        assert_eq!(out[9][7], ((36 | (37 << 16)) + 7 + 14 + 2_000));
        assert!(!e.residual_done(), "the event is cleared by taking it");
        assert_eq!(c.engine().replays, 1);
        // The second pass's candidates: pass 1 on the residual buffer from sample 0.
        let bb = e.pass1_residual(&res, &[0x4444]).unwrap();
        assert_eq!((c.engine().last_first_sample, c.engine().last_cap_base), (0, map::RESIDUAL_AUDIO / 8));
        let mut a = [(0, 0); BB_WORDS];
        e.read_baseband(&bb, 0, &mut a).unwrap();
        assert_eq!(a[5], (0x4444, 5));
        // A new residual makes the old receipt stale; its records are the new ones (no stale cache).
        let audio2: Vec<i16> = audio.iter().map(|&x| x.wrapping_add(100)).collect();
        let res2 = e.start_residual(2, &audio2).unwrap();
        assert_eq!(e.take_residual_sync(&res, &mut out), Err(Error::Stale));
        assert_eq!(e.pass1_residual(&res, &[1]).unwrap_err(), Error::Stale);
        while !e.residual_done() {}
        e.take_residual_sync(&res2, &mut out).unwrap().unwrap();
        assert_eq!(out[0][0], (100 | (101 << 16)) + 14 + 2_000);
        assert_eq!(c.cache_stale_reads(), 0);
        assert_eq!(c.busy_violations(), 0);
        // A receiver's own sync event is untouched by all this.
        c.finish_sync(2, 372);
        assert_eq!(e.sync_pending(), 0b100);
        // The page of the first chip image has no second pass.
        c.set_id(0x4638_0001);
        assert!(!e.has_second_pass());
    }

    #[test]
    fn a_chip_that_stays_busy_or_never_finishes_is_an_error_and_nothing_is_written_while_busy() {
        let c = chip();
        c.hold_busy(true);
        let e = Ft8Engines::new(&c, &c);
        e.setup_rx(0, &RxConfig::default()).unwrap();
        c.clear_log();
        assert_eq!(e.pass1(0, 0, &[1]).unwrap_err(), Error::Busy);
        assert!(c.reg_write_order().is_empty(), "wrote to a busy engine");
        c.hold_busy(false);
        c.never_finish();
        assert_eq!(e.pass1(0, 0, &[1]).unwrap_err(), Error::Timeout);
    }
}
