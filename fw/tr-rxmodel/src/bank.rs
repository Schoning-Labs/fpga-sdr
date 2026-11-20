// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Bit-exact transliteration of `rtl/rx/rx_bank.v`: `N` [`RxChannel`]s that share one ADC input
//! and one register write port, with a one-entry skid buffer per channel and a round-robin arbiter
//! that puts them on one shared `(out_valid, out_index, out_i, out_q)` stream. `docs/RX_DSP.md`
//! section 4 gives the reasons for one shared stream and an arbiter instead of N parallel buses,
//! and the module doc of `channel.rs` explains the general translation approach.
//!
//! `N` is fixed at 8 here (`RX_N`) because that is the only configuration in which `rx_bank.v` is
//! instantiated in this design (`docs/DECISIONS.md` asks for 4 to 8 independent receivers, and every
//! testbench and the resource estimate in `docs/RX_DSP.md` section 5 use `N = 8`). The round-robin
//! pointer in the RTL (`rr_ptr <= found_idx + 1`) is a plain `$clog2(N)`-bit register that is not
//! reduced modulo `N`, and it only matches a plain `% N` when `N` is a power of 2, which 8 is.

use crate::channel::RxChannel;
use crate::fir::Coeffs;

/// Number of receivers in the bank.
pub const RX_N: usize = 8;

/// The receiver bank: `RX_N` channels, their register file, the skid buffers and the arbiter, in
/// the state they hold between two ADC clock edges.
#[derive(Clone)]
pub struct RxBank {
    phase_inc: [i32; RX_N],
    rate_sel: [u8; RX_N],
    ch_enable: [bool; RX_N],
    channels: [RxChannel; RX_N],

    pend_valid: [bool; RX_N],
    pend_i: [i32; RX_N],
    pend_q: [i32; RX_N],

    rr_ptr: usize,
    out_valid: bool,
    out_index: usize,
    out_i: i32,
    out_q: i32,
}

impl Default for RxBank {
    fn default() -> Self {
        RxBank {
            phase_inc: [0; RX_N],
            rate_sel: [0; RX_N],
            ch_enable: [false; RX_N],
            channels: core::array::from_fn(|_| RxChannel::default()),
            pend_valid: [false; RX_N],
            pend_i: [0; RX_N],
            pend_q: [0; RX_N],
            rr_ptr: 0,
            out_valid: false,
            out_index: 0,
            out_i: 0,
            out_q: 0,
        }
    }
}

impl RxBank {
    /// This-cycle `(out_valid, out_index, out_i, out_q)`, from `self` (pre-edge state) alone.
    pub fn out(&self) -> (bool, usize, i32, i32) {
        (self.out_valid, self.out_index, self.out_i, self.out_q)
    }

    /// One ADC-clock edge. `reg_wr`, `reg_addr` and `reg_wdata` are the register write port
    /// (`reg_addr` bit 0 selects phase_inc or control, and bits `[3:1]` are the channel index for
    /// `N = 8`; control word bit 2 = enable, bits `[1:0]` = rate_sel, see `docs/RX_DSP.md` section 4).
    ///
    /// Mutates in place. Every dependency between the steps below is resolved either by their
    /// order (the register file is updated only after every channel has stepped on its old values,
    /// which is the one order that needs no extra bookkeeping) or by capturing a small local
    /// snapshot (a few dozen bytes, not the whole bank) of a field before a later part of the same
    /// call overwrites it. The module doc of `cic.rs` explains why this matters, and
    /// `docs/R2_RXMODEL.md` section 4 shows how much faster it is than cloning the whole bank.
    #[allow(clippy::too_many_arguments)]
    pub fn step(
        &mut self,
        rst: bool,
        adc_data: i32,
        adc_valid: bool,
        reg_wr: bool,
        reg_addr: u32,
        reg_wdata: u32,
        coeffs: &Coeffs,
    ) {
        // ---- snapshot everything a later step below needs as it stood before this edge -----
        let pend_valid_old = self.pend_valid;
        let pend_i_old = self.pend_i;
        let pend_q_old = self.pend_q;
        let rr_ptr_old = self.rr_ptr;

        let mut ch_valid = [false; RX_N];
        let mut ch_i = [0i32; RX_N];
        let mut ch_q = [0i32; RX_N];
        for i in 0..RX_N {
            let (v, ii, qq) = self.channels[i].out();
            ch_valid[i] = v;
            ch_i[i] = ii;
            ch_q[i] = qq;
        }

        // ---- step every channel first, using the still-untouched (old) per-channel config --
        for i in 0..RX_N {
            self.channels[i].step(
                rst,
                adc_data,
                adc_valid,
                self.phase_inc[i],
                self.rate_sel[i],
                self.ch_enable[i],
                coeffs,
            );
        }

        // ---- register file (one write per clock, one cycle of latency) ---------------------
        // Updated only now, after every channel above already read the old values, the RTL's
        // rx_channel instances read phase_inc/rate_sel/ch_enable exactly as they stood before
        // this edge too, so doing the channel step first and the register write second needs
        // no extra snapshot to get that right.
        if rst {
            self.phase_inc = [0; RX_N];
            self.rate_sel = [0; RX_N];
            self.ch_enable = [false; RX_N];
        } else if reg_wr {
            let idx = ((reg_addr >> 1) & 0b111) as usize; // reg_addr[3:1], N=8
            if reg_addr & 1 == 0 {
                self.phase_inc[idx] = reg_wdata as i32;
            } else {
                self.rate_sel[idx] = (reg_wdata & 0b11) as u8;
                self.ch_enable[idx] = ((reg_wdata >> 2) & 1) != 0;
            }
        }

        // ---- round-robin selection: which pending channel (if any) is granted THIS edge -----
        // Computed here from the old (pre-edge) pend_valid and rr_ptr, before the skid-buffer update
        // below, and shared by the pend_valid clear and by the out_valid and out_index update, the
        // same way the RTL shares one combinational `found` and `found_idx` between its two `always`
        // blocks (see the comment in rx_bank.v). If the grant were computed after the skid-buffer
        // update, or if the skid buffer cleared on the previous out_valid and out_index, the
        // granted entry would stay pend_valid for one extra edge and the same search would grant it
        // again on the next edge (docs/RX_DSP.md section 6; docs/R4_BACKEND.md section 9, defect 2).
        let mut found = false;
        let mut found_idx = rr_ptr_old;
        for si in 0..RX_N {
            let cand = (rr_ptr_old + si) % RX_N;
            if !found && pend_valid_old[cand] {
                found = true;
                found_idx = cand;
            }
        }

        // ---- per-channel 1-entry skid buffer ------------------------------------------------
        if rst {
            self.pend_valid = [false; RX_N];
        } else {
            for i in 0..RX_N {
                if ch_valid[i] {
                    self.pend_valid[i] = true;
                    self.pend_i[i] = ch_i[i];
                    self.pend_q[i] = ch_q[i];
                } else if found && found_idx == i {
                    self.pend_valid[i] = false;
                }
            }
        }

        // ---- output register update, using this edge's found/found_idx ---------------------
        if rst {
            self.rr_ptr = 0;
            self.out_valid = false;
            self.out_index = 0;
            self.out_i = 0;
            self.out_q = 0;
        } else if found {
            self.out_valid = true;
            self.out_index = found_idx;
            self.out_i = pend_i_old[found_idx];
            self.out_q = pend_q_old[found_idx];
            self.rr_ptr = (found_idx + 1) % RX_N; // RX_N is a power of 2, see module doc
        } else {
            self.out_valid = false;
            // out_index/out_i/out_q not touched when nothing is pending, hold.
        }
    }
}
