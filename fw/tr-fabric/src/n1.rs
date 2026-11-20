// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Lane 0 of the transceiver (SFP cage 0): its PCS settings and status in page 0xE80A_0000 (`hw/regmap/sfp.toml`,
//! `rtl/sfp/sfp_top.v`, docs/SFP_LINKS.md section 4). The lane carries the Hermes-Lite 2 through a
//! 1000BASE-T copper module (docs/DECISIONS.md, docs/HL2_SFP.md): the bytes of the PCS go to the HL2 link in
//! logic ([`crate::hl2link`]), and the network of the processor is the RJ45 unit ([`crate::eth`]), so this page
//! has no packet memory and no `MacRings` implementation.
//!
//! The transceiver has to be started first ([`crate::sfp`]).

use tr_regs::generated::sfp as reg;
use tr_regs::RegisterSpace;

const NET_ENABLE: u32 = 1 << 0;
const NET_SGMII: u32 = 1 << 1;
const NET_AUTONEG: u32 = 1 << 2;
const NET_RESTART: u32 = 1 << 3;

/// What the cage's module speaks towards us.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LineMode {
    /// 1000BASE-X: a fibre module, or a copper module set to 1000BASE-X (the 88E1111 module).
    Base1000X,
    /// SGMII: many 1000BASE-T copper modules.
    Sgmii,
}

/// Status of the PCS of lane 0.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PcsStatus {
    pub link_up: bool,
    pub an_done: bool,
    pub rx_sync: bool,
    pub rx_idle: bool,
    /// The link partner's configuration word.
    pub partner: u16,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PcsCounters {
    /// Times lane 0's aligner lost its lock.
    pub align_losses: u32,
    /// Symbols outside the 8b/10b alphabet while locked.
    pub code_errors: u32,
}

/// Lane 0's PCS (towards the HL2's copper module).
pub struct Lane0Pcs<'a, R: RegisterSpace> {
    regs: &'a R,
}

impl<'a, R: RegisterSpace> Lane0Pcs<'a, R> {
    /// The PCS is left disabled; [`enable`](Self::enable) starts it.
    pub fn new(regs: &'a R) -> Self {
        regs.write32(reg::net_ctrl::addr(), 0);
        Lane0Pcs { regs }
    }

    /// Resets the PCS (and with it the HL2 link's receive side), then starts it in `mode`.
    pub fn enable(&mut self, mode: LineMode, autoneg: bool) {
        self.regs.write32(reg::net_ctrl::addr(), 0);
        let v = NET_ENABLE | if mode == LineMode::Sgmii { NET_SGMII } else { 0 } | if autoneg { NET_AUTONEG } else { 0 };
        self.regs.write32(reg::net_ctrl::addr(), v);
    }

    /// Switches the PCS off.
    pub fn disable(&mut self) {
        self.regs.write32(reg::net_ctrl::addr(), 0);
    }

    /// Restarts the auto-negotiation with the link partner.
    pub fn restart_negotiation(&self) {
        let v = self.regs.read32(reg::net_ctrl::addr()) & 7;
        self.regs.write32(reg::net_ctrl::addr(), v | NET_RESTART);
    }

    /// Reads the PCS status.
    pub fn status(&self) -> PcsStatus {
        let v = self.regs.read32(reg::net_status::addr());
        PcsStatus { link_up: v & 1 != 0, an_done: v & 2 != 0, rx_sync: v & 4 != 0, rx_idle: v & 8 != 0, partner: (v >> 16) as u16 }
    }

    /// True if the link is up.
    pub fn link_up(&self) -> bool {
        self.status().link_up
    }

    /// Reads the error counters of the PCS.
    pub fn counters(&self) -> PcsCounters {
        PcsCounters {
            align_losses: self.regs.read32(reg::align_losses::addr()),
            code_errors: self.regs.read32(reg::code_errors::addr()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mock::MockFabric;

    #[test]
    fn enable_resets_then_starts() {
        let m = MockFabric::new();
        let mut n = Lane0Pcs::new(&m);
        n.enable(LineMode::Sgmii, true);
        assert_eq!(m.reg_writes(reg::net_ctrl::addr()), [0, 0, 7]);
        n.enable(LineMode::Base1000X, true);
        assert_eq!(m.reg(reg::net_ctrl::addr()), 5);
    }

    #[test]
    fn status_and_counters() {
        let m = MockFabric::new();
        let n = Lane0Pcs::new(&m);
        m.poke(reg::net_status::addr(), 0x4020_000F);
        let s = n.status();
        assert!(s.link_up && s.an_done && s.rx_sync && s.rx_idle);
        assert_eq!(s.partner, 0x4020);
        m.poke(reg::align_losses::addr(), 2);
        m.poke(reg::code_errors::addr(), 9);
        assert_eq!(n.counters(), PcsCounters { align_losses: 2, code_errors: 9 });
    }
}
