// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Cycle-exact models of the two CIC (cascaded integrator-comb) decimators in the receiver:
//! [`CicFixed`], the first stage with a fixed ratio of 10, and [`CicVar`], the second stage whose
//! ratio is chosen at run time from 5, 10, 20 and 40.
//!
//! A CIC decimator is a low-pass filter and a sample-rate reducer built from nothing but adders
//! and registers, which is why it is the usual first step after a high-rate ADC or mixer. It has
//! two halves. The integrator half is a chain of N accumulators, each adding its input to its own
//! running total on every input sample, so the whole chain runs at the full input rate. The comb
//! half is a chain of N differentiators, each subtracting its previous input from the current one,
//! and it runs only once per R input samples, which is where the rate reduction happens. The total
//! gain at DC is R^N, so the output word needs about N * log2(R) more bits than the input, and the
//! models cut the wide result back down to 16 bits at the output with a round-half-up.
//!
//! The accumulators are allowed to overflow. Everything is arithmetic modulo 2^width, and as long
//! as the width is big enough for the final result, the combs cancel the wrap-around of the
//! integrators exactly (this is the classic result of Hogenauer, and the reason the registers
//! here are kept at 28 and 43 bits and not wider). Nothing saturates anywhere, including the
//! rounding at the output, so a result at the very top of the range wraps to the bottom.
//!
//! Both models share one private core, [`Core`], and differ only in how they pick the decimation
//! ratio and in how they read the result out of the last comb:
//!
//! * [`CicFixed`] uses three stages, a ratio of 10, an 18-bit input and 28-bit registers. The
//!   output is combinational from the last comb register, so `out()` shows the result of the
//!   previous output event during the cycle in which `out_strobe` is high, and the new one only
//!   from the cycle after.
//! * [`CicVar`] uses five stages, a 16-bit input and 43-bit registers. It takes a different bit
//!   field of the last comb for each ratio so that the gain stays about the same, and it has an
//!   output register that is reloaded on every single clock, which puts the new result two clocks
//!   after `out_strobe` and not one.
//!
//! # Calling convention
//!
//! Each model keeps its state between clock edges. `out()` returns what the ports show during the
//! current cycle, computed from the state alone, and `step(...)` moves the state across one clock
//! edge, with the inputs that are present during that cycle. The state changes in place, so a
//! caller that wants to give a downstream stage the value this stage held *before* the edge has
//! to read `out()` first and call `step` afterwards, which is exactly what `rx_channel.v` does
//! with its non-blocking assignments. Inside this file the same rule applies to every register
//! group: whatever the next value of a register needs from the old value of another register is
//! read (or the registers are visited in an order that does not disturb it) before it is
//! overwritten, and nothing is cloned for that.

use crate::bits::{bit, part_select_signed, trunc};

/// Everything that [`CicFixed`] and [`CicVar`] have in common: the integrators, the combs, the
/// input sample counter and the registered `out_strobe`. The number of stages is a const generic
/// so the registers live in plain arrays and a channel can be copied without any allocation.
#[derive(Clone)]
struct Core<const N: usize> {
    /// Width in bits of every integrator and comb register.
    acc_width: u32,
    /// Width in bits of the input word (the input is truncated to it, then sign-extended).
    in_width: u32,
    /// Integrator registers, stage 0 sees the input and stage N-1 feeds the first comb.
    integ: [i64; N],
    /// Comb output registers, stage 0 reads the last integrator and stage N-1 is the filter output.
    comb_out: [i64; N],
    /// Comb delay registers, each one holds the input its comb saw at the previous output event.
    comb_prev: [i64; N],
    /// Input samples accepted since the last output event, a 16-bit counter that wraps.
    count: u16,
    /// Registered output pulse, high for the one cycle after an output event was triggered.
    out_strobe: bool,
}

impl<const N: usize> Core<N> {
    fn new(acc_width: u32, in_width: u32) -> Self {
        Core {
            acc_width,
            in_width,
            integ: [0; N],
            comb_out: [0; N],
            comb_prev: [0; N],
            count: 0,
            out_strobe: false,
        }
    }

    /// The last comb register, which both models read their output from.
    fn last_comb(&self) -> i64 {
        self.comb_out[N - 1]
    }

    /// One clock edge. `last_count` is the counter value at which an input sample completes a
    /// group (the decimation ratio minus one), `reset` has priority over everything else.
    fn advance(&mut self, reset: bool, in_strobe: bool, in_data: i32, last_count: u16) {
        let w = self.acc_width;

        if reset {
            self.integ = [0; N];
            self.comb_out = [0; N];
            self.comb_prev = [0; N];
            self.count = 0;
            self.out_strobe = false;
            return;
        }

        // The combs run on the edge that follows an output event, which is when the registered
        // `out_strobe` is high, so they see the integrator as it was before this edge's input
        // sample was added. Going from the last comb down to the first keeps every stage's input
        // (the register of the stage below it) untouched until the stage above has read it.
        if self.out_strobe {
            for k in (0..N).rev() {
                let input = if k == 0 {
                    self.integ[N - 1]
                } else {
                    self.comb_out[k - 1]
                };
                self.comb_out[k] = trunc(input - self.comb_prev[k], w);
                self.comb_prev[k] = input;
            }
        }

        // The integrators run on every accepted input sample. Stage 0 adds the input, every other
        // stage adds the old value of the stage below it, so the chain is registered (one clock
        // of delay per stage) and the same top-down order protects the values still needed.
        if in_strobe {
            for k in (1..N).rev() {
                self.integ[k] = trunc(self.integ[k] + self.integ[k - 1], w);
            }
            let x = trunc(in_data as i64, self.in_width);
            self.integ[0] = trunc(self.integ[0] + x, w);

            if self.count == last_count {
                self.count = 0;
                self.out_strobe = true;
            } else {
                self.count = self.count.wrapping_add(1);
                self.out_strobe = false;
            }
        } else {
            self.out_strobe = false;
        }
    }
}

/// Takes `out_width` bits of a `acc_width`-bit register `cn`, ending at bit `hi`, and adds the
/// bit just below them as 0 or 1. That is a round-half-up of the discarded low bits. The sum is
/// cut to `out_width` bits again, so the most positive word plus one becomes the most negative.
fn rounded_slice(cn: i64, acc_width: u32, hi: u32, out_width: u32) -> i32 {
    let lo = hi + 1 - out_width;
    let word = part_select_signed(cn, acc_width, hi, lo);
    trunc(word + bit(cn, lo - 1), out_width) as i32
}

/// Number of integrator and comb stages in [`CicFixed`].
const FIXED_STAGES: usize = 3;
/// Decimation ratio of [`CicFixed`].
const FIXED_DECIMATION: u16 = 10;
/// Input width of [`CicFixed`] in bits (the mixer output).
const FIXED_IN_WIDTH: u32 = 18;
/// Register width of [`CicFixed`]: 18 bits of input plus ceil(3 * log2(10)) = 10 bits of growth.
const FIXED_ACC_WIDTH: u32 = 28;
/// Output width of [`CicFixed`] in bits.
const FIXED_OUT_WIDTH: u32 = 16;

/// The fixed CIC decimator: three stages, ratio 10, 18-bit signed input, 16-bit signed output.
///
/// The output is the top 16 of the 28 register bits, rounded with the bit below them, whatever the
/// ratio or stage count (they never change here). It is combinational from the last comb register,
/// so it keeps showing the previous output event's result in the cycle where [`out`](Self::out)
/// reports the strobe high, and the new result from the next cycle on. A consumer that latches the
/// data at the strobe therefore gets the previous result, and the rest of the receiver counts on it.
#[derive(Clone)]
pub struct CicFixed {
    core: Core<FIXED_STAGES>,
}

impl Default for CicFixed {
    fn default() -> Self {
        CicFixed {
            core: Core::new(FIXED_ACC_WIDTH, FIXED_IN_WIDTH),
        }
    }
}

impl CicFixed {
    /// This-cycle `(out_strobe, out_data)`, from the state alone.
    pub fn out(&self) -> (bool, i32) {
        let data = rounded_slice(
            self.core.last_comb(),
            FIXED_ACC_WIDTH,
            FIXED_ACC_WIDTH - 1,
            FIXED_OUT_WIDTH,
        );
        (self.core.out_strobe, data)
    }

    /// One clock edge. `rst` clears every register, `in_strobe` marks `in_data` as a valid sample.
    /// With `in_strobe` low nothing changes except that the output strobe drops.
    pub fn step(&mut self, rst: bool, in_strobe: bool, in_data: i32) {
        self.core
            .advance(rst, in_strobe, in_data, FIXED_DECIMATION - 1);
    }
}

/// Number of integrator and comb stages in [`CicVar`].
const VAR_STAGES: usize = 5;
/// Input width of [`CicVar`] in bits (the output width of [`CicFixed`]).
const VAR_IN_WIDTH: u32 = 16;
/// Register width of [`CicVar`]: 16 bits of input plus 27 bits of growth for the largest ratio, 40.
const VAR_ACC_WIDTH: u32 = 43;
/// Output width of [`CicVar`] in bits.
const VAR_OUT_WIDTH: u32 = 16;

/// Bits of growth to drop for a decimation ratio, which is ceil(5 * log2(R)) for the five stages
/// that are built. A ratio of 40 and every value that is not 5, 10 or 20 take the largest one.
fn var_growth(decimation: u32) -> u32 {
    match decimation {
        5 => 12,
        10 => 17,
        20 => 22,
        _ => 27,
    }
}

/// The variable CIC decimator: five stages, ratio 5, 10, 20 or 40, 16-bit signed input and output.
///
/// The gain at DC is R^5, so for each ratio the output word is taken from a different place in the
/// 43-bit result, which keeps the gain between the ratios at about the same level. The `decimation`
/// given to [`step`](Self::step) is a 6-bit value that is used live and never copied: it sets the
/// counter compare on every input sample and the output bit field on every clock. Ratios other than
/// 5, 10, 20 and 40 still work for the counter (0 counts like 64, 1 gives a strobe on every sample)
/// but select the field of 40.
///
/// Lowering the ratio while the counter is already past the new limit makes the counter run up
/// through 65535 and wrap before it matches again, so there is no output strobe for up to 65536
/// input samples. Resetting together with a change of ratio avoids that, and the receiver does so.
///
/// The output is a register that takes the rounded field of the last comb on every clock, even
/// during reset, so the result shows up two clocks after the strobe, and the cycle in which the
/// strobe is high still shows the result of the output event before.
#[derive(Clone)]
pub struct CicVar {
    core: Core<VAR_STAGES>,
    /// The output register, reloaded on every clock edge and not touched by `rst`.
    out_data: i32,
}

impl Default for CicVar {
    fn default() -> Self {
        CicVar {
            core: Core::new(VAR_ACC_WIDTH, VAR_IN_WIDTH),
            out_data: 0,
        }
    }
}

impl CicVar {
    /// This-cycle `(out_strobe, out_data)`, both plain registers.
    pub fn out(&self) -> (bool, i32) {
        (self.core.out_strobe, self.out_data)
    }

    /// One clock edge. `decimation` is the live 6-bit ratio (only its low 6 bits count), `rst`
    /// clears the filter but leaves the output register alone, and `in_strobe` marks `in_data` as
    /// a valid sample.
    pub fn step(&mut self, rst: bool, decimation: i64, in_strobe: bool, in_data: i32) {
        let ratio = (decimation & 0x3f) as u32;

        // The output register loads from the last comb as it stands before this edge, and that
        // has to be read before `advance` lets the combs move.
        let top = VAR_IN_WIDTH + var_growth(ratio) - 1;
        let next_out = rounded_slice(self.core.last_comb(), VAR_ACC_WIDTH, top, VAR_OUT_WIDTH);

        // The compare value is the ratio minus one worked out in 6 bits, so a ratio of 0 gives 63.
        let last_count = (ratio.wrapping_sub(1) & 0x3f) as u16;
        self.core.advance(rst, in_strobe, in_data, last_count);

        self.out_data = next_out;
    }
}
