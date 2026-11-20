// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Bit-exact transliteration of `rtl/rx/fir_decim.v` with the parameters of `rx_channel.v`
//! (`TAPS=65, DECIM=4, IN_WIDTH=16, COEFF_WIDTH=20, OUT_WIDTH=24`), reading the same
//! `rtl/rx/fir_coeffs.hex` coefficient file that the `$readmemh` of the RTL reads. The module doc
//! of `bits.rs` explains the general translation approach.
//!
//! One RTL detail is easy to miss and matters for bit-exactness: on `rst`, `snap_i` and `snap_q`
//! (the frozen snapshot of the MAC sequencer), `acc_i_latched`, `out_i` and `out_q` are not
//! cleared, and only `dcnt`, `start_mac`, the live tap shift registers, `mac_run`, `idx`, `acc`
//! and `out_strobe` are. See `FirDecim::step`.

use crate::bits::{part_select_unsigned, trunc};
use std::fs;
use std::io;
use std::path::Path;

/// Number of taps of the compensating FIR filter.
pub const TAPS: usize = 65;
const DECIM: i64 = 4;
const IN_WIDTH: u32 = 16;
const COEFF_WIDTH: u32 = 20;
const OUT_WIDTH: u32 = 24;
const PROD_WIDTH: u32 = IN_WIDTH + COEFF_WIDTH; // 36
const ACC_WIDTH: u32 = PROD_WIDTH + 8; // 44
const SHIFT: u32 = COEFF_WIDTH - 1; // 19

/// The filter coefficients as signed integers of `COEFF_WIDTH` bits.
pub type Coeffs = [i64; TAPS];

/// Reads `path` as a `$readmemh`-style file: one `COEFF_WIDTH`-bit hex value per line (as
/// `rtl/rx/fir_coeffs.hex` is), blank lines and `//` comments ignored.
pub fn load_coeffs_hex(path: &Path) -> io::Result<Coeffs> {
    let text = fs::read_to_string(path)?;
    let mut out = [0i64; TAPS];
    let mut n = 0usize;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with("//") {
            continue;
        }
        let v = i64::from_str_radix(line, 16)
            .unwrap_or_else(|e| panic!("bad hex coefficient {line:?} in {path:?}: {e}"));
        assert!(n < TAPS, "{path:?} has more than {TAPS} coefficients");
        out[n] = trunc(v, COEFF_WIDTH);
        n += 1;
    }
    assert_eq!(n, TAPS, "{path:?}: expected {TAPS} coefficients, found {n}");
    Ok(out)
}

fn round_out(acc_in: i64) -> i64 {
    let rounded = trunc(acc_in + (1i64 << (SHIFT - 1)), ACC_WIDTH);
    let hi = SHIFT + OUT_WIDTH - 1;
    let lo = SHIFT;
    let bits = part_select_unsigned(rounded, ACC_WIDTH, hi, lo);
    trunc(bits as i64, OUT_WIDTH)
}

/// The decimate-by-4 FIR filter (`rtl/rx/fir_decim.v`) in its state between two clock edges.
#[derive(Clone)]
pub struct FirDecim {
    dcnt: i64,
    start_mac: bool,
    taps_i: [i64; TAPS],
    taps_q: [i64; TAPS],
    snap_i: [i64; TAPS],
    snap_q: [i64; TAPS],
    mac_run: bool,
    idx: i64,
    acc: i64,
    acc_i_latched: i64,
    out_strobe: bool,
    out_i: i64,
    out_q: i64,
}

impl Default for FirDecim {
    fn default() -> Self {
        FirDecim {
            dcnt: 0,
            start_mac: false,
            taps_i: [0; TAPS],
            taps_q: [0; TAPS],
            snap_i: [0; TAPS],
            snap_q: [0; TAPS],
            mac_run: false,
            idx: 0,
            acc: 0,
            acc_i_latched: 0,
            out_strobe: false,
            out_i: 0,
            out_q: 0,
        }
    }
}

impl FirDecim {
    /// This-cycle `out_strobe`/`out_i`/`out_q`: plain registers, read directly (no
    /// combinational logic between them and the port).
    pub fn out(&self) -> (bool, i32, i32) {
        (self.out_strobe, self.out_i as i32, self.out_q as i32)
    }

    /// Mutates in place (see `cic.rs`'s module doc for why, and for the general "capture
    /// anything still needed into a local before overwriting it" discipline this follows). The
    /// tap shift (`taps_i[k] = taps_i[k-1]`) is safe to do in place specifically *because* it
    /// iterates `k` from high to low, writing `taps_i[k]` never disturbs `taps_i[k-1]`, which
    /// has not been read yet.
    pub fn step(&mut self, rst: bool, in_strobe: bool, in_i: i32, in_q: i32, coeffs: &Coeffs) {
        if rst {
            self.dcnt = 0;
            self.start_mac = false;
            self.taps_i = [0; TAPS];
            self.taps_q = [0; TAPS];
            self.mac_run = false;
            self.idx = 0;
            self.acc = 0;
            self.out_strobe = false;
            // snap_i/q, acc_i_latched, out_i, out_q: not reset in the RTL, hold (see doc).
            return;
        }

        // ---- block 1: live tap shift register + decimation counter --------------------
        let start_mac_old = self.start_mac; // block 2 (below) must see last cycle's value
                                            // Block 2's snapshot (below) needs taps_i/q as they stood *before* block 1's shift
                                            // runs, not after, both blocks trigger on this same edge, so in true RTL block 2
                                            // would never see this cycle's shift. Only copy the (65-entry) arrays when they will
                                            // actually be needed (start_mac_old, true on roughly 1 in DECIM*(cic2 decimation)
                                            // cycles) rather than unconditionally every cycle, this is the whole reason `step`
                                            // mutates in place instead of cloning (docs/R2_RXMODEL.md section 4).
        let old_taps = start_mac_old.then(|| (self.taps_i, self.taps_q));

        self.start_mac = false;
        if in_strobe {
            for k in (1..TAPS).rev() {
                self.taps_i[k] = self.taps_i[k - 1];
                self.taps_q[k] = self.taps_q[k - 1];
            }
            self.taps_i[0] = trunc(in_i as i64, IN_WIDTH);
            self.taps_q[0] = trunc(in_q as i64, IN_WIDTH);

            if self.dcnt == DECIM - 1 {
                self.dcnt = 0;
                self.start_mac = true;
            } else {
                self.dcnt += 1;
            }
        }

        // ---- block 2: MAC sequencer -----------------------------------------------------
        self.out_strobe = false;
        if let Some((taps_i_old, taps_q_old)) = old_taps {
            self.snap_i = taps_i_old;
            self.snap_q = taps_q_old;
            self.mac_run = true;
            self.idx = 0;
            self.acc = 0;
        } else if self.mac_run {
            let is_q_phase = self.idx >= TAPS as i64;
            let tap_idx = (if is_q_phase {
                self.idx - TAPS as i64
            } else {
                self.idx
            }) as usize;
            let mac_data = if is_q_phase {
                self.snap_q[tap_idx]
            } else {
                self.snap_i[tap_idx]
            };
            let mac_product = trunc(mac_data * coeffs[tap_idx], PROD_WIDTH);

            if self.idx == 0 {
                self.acc = trunc(mac_product, ACC_WIDTH);
            } else if self.idx == TAPS as i64 {
                self.acc_i_latched = self.acc; // finished I accumulator (read before overwriting acc)
                self.acc = trunc(mac_product, ACC_WIDTH);
            } else {
                self.acc = trunc(self.acc + mac_product, ACC_WIDTH);
            }

            if self.idx == (2 * TAPS - 1) as i64 {
                self.out_i = round_out(self.acc_i_latched);
                self.out_q = round_out(self.acc);
                self.out_strobe = true;
                self.mac_run = false;
            } else {
                self.idx += 1;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bits::bit as bit_fn;

    #[test]
    fn round_out_matches_hand_computed_example() {
        // acc_in chosen so the rounding bit (bit SHIFT-1 = 18) is set, forcing a carry into
        // the kept bits, a decent smoke test that the shift/mask math is wired correctly.
        let acc_in = (1i64 << 18) | (5i64 << 19);
        let out = round_out(acc_in);
        assert_eq!(out, 6); // (5<<19 + 1<<18) rounds up to 6<<19, >>19 = 6
        assert_eq!(bit_fn(acc_in, 18), 1);
    }
}
