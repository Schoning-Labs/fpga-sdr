// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! The SFP cages in the firmware's main loop (docs/SFP_LINKS.md, docs/HL2_SFP.md): starts the transceiver, picks the
//! line mode of the copper module in cage SFP0 and brings up lane 0's PCS, which carries the Hermes-Lite 2 link. The HL2
//! session (`tr_station::hl2session`) works on the registers of the HL2 link and only needs this lane up. The network for
//! time, control and GUI is the RJ45 unit ([`crate::rj45net`]), not an SFP cage.
//!
//! One call per loop turn, [`SfpLane::poll`]. Its first call reads both cages' module memories (about
//! 20 ms, once) and writes the clock chip over I2C (about 20 ms, once); while the transceiver starts a
//! call may read the clock chip's status (about 1 ms). After that a call costs a few register reads.
//! What happened is told through [`SfpLane::take_event`], one console line each (Display).
//!
//! Cage: the HL2 is always on cage SFP0 (quad 1 lane 0, the only 1.25 Gbit/s lane; cage SFP1 is the 2.5 Gbit/s board
//! link). Both cages' modules are identified at start-up and printed; a Gigabit Ethernet module found in SFP1 while
//! SFP0 has none is reported as in the wrong cage, because lane 1 cannot carry the HL2 in this chip (the minimal test
//! build docs/HL2MIN.md has a lane-1 option, this one has not).
//!
//! Line mode: a module that says "1000BASE-T" in its memory is tried in SGMII first, any other in
//! 1000BASE-X; while there is no link the other mode is tried every 3 seconds.

use core::fmt;

use tr_fabric::n1::{Lane0Pcs, LineMode, PcsCounters};
use tr_fabric::sfp::{self, Module, ModuleInfo, Phase, Report, Serdes};
use tr_regs::RegisterSpace;

/// How long the link may stay down in one line mode before the other is tried, in milliseconds.
const MODE_TRY_MS: i64 = 3_000;

/// What [`SfpLane::poll`] has to tell.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NetEvent {
    /// Start-up: what is in cage `cage` (0 = SFP0, network; 1 = SFP1, board link), from its module memory.
    Cage { cage: u8, module: Option<ModuleInfo> },
    /// Start-up: SFP0 holds no Gigabit Ethernet module but SFP1 does; the HL2 needs it in SFP0.
    WrongCage,
    /// The transceiver's start-up.
    Serdes(Report),
    /// The line mode was set (start, or the 3 s trial of the other mode).
    Mode(LineMode),
    /// The HL2 lane's link (the PCS to the copper module) went up or down.
    Link { up: bool, mode: LineMode },
}

/// A module memory field (blank-padded ASCII) printed as text.
struct Text<'a>(&'a [u8]);

impl fmt::Display for Text<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut out = [0u8; 16];
        let n = sfp::field_text(self.0, &mut out);
        f.write_str(core::str::from_utf8(&out[..n]).unwrap_or("?"))
    }
}

fn mode_name(m: LineMode) -> &'static str {
    match m {
        LineMode::Sgmii => "SGMII",
        LineMode::Base1000X => "1000BASE-X",
    }
}

impl fmt::Display for NetEvent {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match *self {
            NetEvent::Cage { cage, module: None } => write!(f, "sfp{cage}: no module"),
            NetEvent::Cage { cage, module: Some(m) } => {
                let kind = match Module::of(Some(&m)) {
                    Module::Copper => "1000BASE-T",
                    Module::Cable => "direct-attach cable",
                    _ if m.ethernet() => "1000BASE-X",
                    _ => "not Gigabit Ethernet",
                };
                write!(
                    f,
                    "sfp{cage}: {} {} rev {} serial {}, {kind}, {} Mbaud{}",
                    Text(&m.vendor),
                    Text(&m.part),
                    Text(&m.revision),
                    Text(&m.serial),
                    m.mbaud(),
                    if m.too_fast() { " (10G module)" } else { "" }
                )
            }
            NetEvent::WrongCage => {
                write!(f, "sfp: the Ethernet module is in SFP1; the HL2 runs on SFP0 only (SFP1 is the 2.5 Gbit/s board link)")
            }
            NetEvent::Serdes(Report::LockTry { attempt, ctrl, status, chip }) => {
                write!(
                    f,
                    "sfp: lock try {attempt}: ctrl {ctrl:#04x} status {status:#010x} (lane 0 pll {} cdr {} signal {}; quad {:#04x}, buffer flags {:#x}), clock chip reg 0 ",
                    status & 1,
                    status >> 1 & 1,
                    status >> 2 & 1,
                    status >> 16 & 0xFF,
                    status >> 24 & 0xF
                )?;
                match chip {
                    Some(c) => write!(f, "{c:#04x} (SYS_INIT LOL_B LOL_A = {}{}{})", c >> 7 & 1, c >> 6 & 1, c >> 5 & 1),
                    None => f.write_str("no answer"),
                }
            }
            NetEvent::Serdes(Report::Transceiver { clock_chip, locked }) => write!(
                f,
                "sfp: clock chip {}, transceiver PLL {}",
                if clock_chip { "set to 125 MHz" } else { "does not answer on I2C" },
                if locked { "locked" } else { "not locked (HL2 lane off)" }
            ),
            NetEvent::Mode(m) => write!(f, "sfp0 (HL2): line mode {}", mode_name(m)),
            NetEvent::Link { up, mode } => write!(f, "sfp0 (HL2): link {} ({})", if up { "up" } else { "down" }, mode_name(mode)),
        }
    }
}

/// The transceiver, the lane 0 PCS and the line mode logic of the HL2 link.
pub struct SfpLane<'a, R: RegisterSpace> {
    regs: &'a R,
    /// The transceiver and the clock chip.
    pub serdes: Serdes<'a, R>,
    /// The PCS of lane 0.
    pub pcs: Lane0Pcs<'a, R>,
    /// What the cages hold (read once at start-up).
    pub cages: [Option<ModuleInfo>; 2],
    /// The kind of module in SFP0.
    pub module: Module,
    /// The line mode in use.
    pub mode: LineMode,
    /// The line mode was set at least once.
    started: bool,
    /// The last link state reported.
    link: bool,
    /// When the link was last up, or the mode last changed (milliseconds).
    mode_since_ms: i64,
    events: [Option<NetEvent>; 6],
}

impl<'a, R: RegisterSpace> SfpLane<'a, R> {
    /// A lane that has not started; the first [`poll`](Self::poll) starts it.
    pub fn new(regs: &'a R) -> Self {
        SfpLane {
            regs,
            serdes: Serdes::new(regs),
            pcs: Lane0Pcs::new(regs),
            cages: [None; 2],
            module: Module::None,
            mode: LineMode::Base1000X,
            started: false,
            link: false,
            mode_since_ms: 0,
            events: [None; 6],
        }
    }

    fn event(&mut self, e: NetEvent) {
        if let Some(slot) = self.events.iter_mut().find(|s| s.is_none()) {
            *slot = Some(e);
        }
    }

    /// The next thing to tell, oldest first.
    pub fn take_event(&mut self) -> Option<NetEvent> {
        let e = self.events[0].take();
        self.events.rotate_left(1);
        e
    }

    /// Call once per main-loop turn; `now_ms` is the monotonic time in milliseconds and `delay` waits the given microseconds (used for I2C only).
    pub fn poll<D: Fn(u32) + Copy>(&mut self, delay: D, now_ms: i64) {
        if self.serdes.phase() == Phase::Off {
            // Both cages are identified while the transceiver is held in reset, so the transmitters are off.
            for cage in 0..2u8 {
                let ch = if cage == 0 { sfp::channel::SFP0 } else { sfp::channel::SFP1 };
                let module = sfp::read_module_info(self.regs, delay, ch);
                self.cages[cage as usize] = module;
                self.event(NetEvent::Cage { cage, module });
            }
            let eth = |m: &Option<ModuleInfo>| m.is_some_and(|m| m.ethernet());
            if !eth(&self.cages[0]) && eth(&self.cages[1]) {
                self.event(NetEvent::WrongCage);
            }
            self.module = Module::of(self.cages[0].as_ref());
            self.serdes.start(delay, now_ms);
        }
        let phase = self.serdes.poll(delay, now_ms);
        while let Some(r) = self.serdes.take_report() {
            self.event(NetEvent::Serdes(r));
        }
        if phase != Phase::Running {
            return;
        }
        if !self.started {
            self.serdes.set_tx_disable(false, false);
            self.mode = if self.module == Module::Copper { LineMode::Sgmii } else { LineMode::Base1000X };
            self.pcs.enable(self.mode, true);
            self.event(NetEvent::Mode(self.mode));
            self.started = true;
            self.mode_since_ms = now_ms;
        }
        let up = self.pcs.link_up();
        if up != self.link {
            self.link = up;
            self.event(NetEvent::Link { up, mode: self.mode });
        }
        if up {
            self.mode_since_ms = now_ms;
        } else if now_ms - self.mode_since_ms >= MODE_TRY_MS {
            self.mode = if self.mode == LineMode::Sgmii { LineMode::Base1000X } else { LineMode::Sgmii };
            self.pcs.enable(self.mode, true);
            self.event(NetEvent::Mode(self.mode));
            self.mode_since_ms = now_ms;
        }
    }

    /// The HL2 lane's link is up (the HL2 session can run).
    pub fn link_up(&self) -> bool {
        self.link
    }

    /// The lane's PCS counters (aligner losses, code errors).
    pub fn counters(&self) -> PcsCounters {
        self.pcs.counters()
    }
}
