// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Bit-exact transliteration of `rtl/rx/rx_channel.v`: one receiver (NCO mixer, fixed CIC,
//! variable CIC, compensating FIR), wired the way the RTL wires its four stages. That includes
//! `chan_rst = rst | ~enable`, which holds the whole channel in reset while it is disabled (see
//! `docs/RX_DSP.md` section 1 for the reason), and the I/Q strobe simplification that the RTL
//! documents itself: the `in_strobe` of `fir_decim` is driven only from the `out_strobe` of the
//! I-channel `cic_var`, because the I and Q strobes always coincide (both `cic_var` instances share
//! one `decimation` and one `in_strobe`, so they cannot drift apart).

use crate::cic::{CicFixed, CicVar};
use crate::fir::{Coeffs, FirDecim};
use crate::nco::Nco;

/// One receiver channel in the state it holds between two ADC clock edges.
#[derive(Clone, Default)]
pub struct RxChannel {
    nco: Nco,
    cic1_i: CicFixed,
    cic1_q: CicFixed,
    cic2_i: CicVar,
    cic2_q: CicVar,
    fir: FirDecim,
}

/// `rate_sel` -> `cic_var` decimation, `rx_channel.v`'s `cic2_decim` combinational lookup.
fn cic2_decimation(rate_sel: u8) -> i64 {
    match rate_sel & 0b11 {
        0 => 40, // 48 ksps
        1 => 20, // 96 ksps
        2 => 10, // 192 ksps
        _ => 5,  // 384 ksps
    }
}

impl RxChannel {
    /// This-cycle `(out_valid, out_i, out_q)`, from `self` (pre-edge state) alone.
    pub fn out(&self) -> (bool, i32, i32) {
        self.fir.out()
    }

    /// Mutates in place: every submodule's own `step` reads its OWN old state internally, and
    /// the "old, pre-edge" values threaded between submodules here (`mix_out`, `cic1_*_out`,
    /// `cic2_*_out`) are captured via each submodule's `out()` *before* that submodule's `step`
    /// runs, so this still gives every downstream stage the value its upstream neighbor held
    /// before this edge, exactly as the RTL's cross-module NBA reads do.
    #[allow(clippy::too_many_arguments)]
    pub fn step(
        &mut self,
        rst: bool,
        adc_data: i32,
        adc_valid: bool,
        phase_inc: i32,
        rate_sel: u8,
        enable: bool,
        coeffs: &Coeffs,
    ) {
        let chan_rst = rst || !enable;
        let adc_valid_gated = adc_valid && enable;

        let mix_out = self.nco.out();
        self.nco
            .step(chan_rst, adc_valid_gated, phase_inc, adc_data);

        let cic1_i_out = self.cic1_i.out();
        let cic1_q_out = self.cic1_q.out();
        self.cic1_i
            .step(chan_rst, mix_out.out_strobe, mix_out.out_i);
        self.cic1_q
            .step(chan_rst, mix_out.out_strobe, mix_out.out_q);

        let decim = cic2_decimation(rate_sel);
        let cic2_i_out = self.cic2_i.out();
        let cic2_q_out = self.cic2_q.out();
        self.cic2_i
            .step(chan_rst, decim, cic1_i_out.0, cic1_i_out.1);
        self.cic2_q
            .step(chan_rst, decim, cic1_q_out.0, cic1_q_out.1);

        // fir_decim's in_strobe is wired only from the I-channel cic_var (see module doc).
        self.fir
            .step(chan_rst, cic2_i_out.0, cic2_i_out.1, cic2_q_out.1, coeffs);
    }
}
