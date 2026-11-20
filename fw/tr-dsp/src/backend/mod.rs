// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Bit-exact model of the FPGA receiver back end (docs/R4_BACKEND.md,
//! docs/ARCHITECTURE.md 3.10): input scaling and noise blanker at the receiver-bank rate,
//! half-band decimation to 24 ksps, 1,024-tap complex channel filter, CORDIC demodulator
//! (SSB/CW, AM, SAM, FM, IQ), log-domain AGC and S-meter, audio half-band to 12 ksps, 16-bit
//! output with HL2 sample-index stamps.
//!
//! One [`Receiver`] is one receiver's state; the RTL time-shares one engine across 8 of them,
//! but receivers never share state, so each receiver's output depends only on its own input,
//! configuration and coefficient bank. The RTL testbenches compare their output with this model
//! word for word (`sim/rx_backend/`).
//!
//! Integers only: every value is an `i64` holding exactly what the RTL register holds (see
//! [`fix`]). Nothing here uses floating point except the coefficient designer in [`design`],
//! which is firmware-side (it produces the integer coefficients the firmware writes).

pub mod chfilt;
pub mod cordic;
pub mod design;
pub mod fix;
pub mod halfband;
pub mod nb;
pub mod post;
pub mod stim;
pub mod tables;

pub use chfilt::{CoefBank, MAX_TAPS};
pub use nb::NbConfig;
pub use post::{AgcConfig, Alpha, Mode, Out, PostConfig};

/// One receiver's settings (the per-receiver register slot).
#[derive(Clone, Copy, Debug)]
pub struct RxConfig {
    /// Receiver-bank output rate of this receiver: 0..3 = 48/96/192/384 ksps (must equal the
    /// bank's `rate_sel`).
    pub in_rate: u8,
    /// Left shift applied to the bank's 24-bit samples before everything else (saturating).
    pub in_shift: u8,
    pub nb: NbConfig,
    pub post: PostConfig,
}

impl Default for RxConfig {
    fn default() -> Self {
        RxConfig { in_rate: 0, in_shift: 6, nb: NbConfig::default(), post: PostConfig::default() }
    }
}

/// ADC samples (HL2 time) per bank sample for `in_rate`.
pub fn adc_per_input(in_rate: u8) -> u64 {
    1600 >> in_rate
}

/// One output sample with its stamp offset: the HL2 sample index of the input sample that
/// completed it, minus the index of the receiver's first input sample (the RTL adds that base,
/// latched when the first sample arrived after enable).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Stamped {
    pub out: Out,
    pub stamp_off: u64,
}

/// State of one receiver of the back end.
#[derive(Clone, Debug)]
pub struct Receiver {
    pub cfg: RxConfig,
    nb: nb::Nb,
    dec: halfband::Decimator,
    filt: chfilt::ChannelFilter,
    post: post::Post,
    /// 24 ksps samples produced so far (the channel-filter job count).
    pub n24: u64,
    /// Output samples produced so far.
    pub n_out: u64,
    /// Channel-filter output of the last call to [`Self::push`], if it produced one (for tests
    /// that measure the filter through the whole integer chain).
    pub last_y: Option<(i64, i64)>,
}

impl Receiver {
    /// A receiver just enabled with `cfg`.
    pub fn new(cfg: RxConfig) -> Self {
        Receiver {
            cfg,
            nb: nb::Nb::default(),
            dec: halfband::Decimator::new(cfg.in_rate),
            filt: chfilt::ChannelFilter::default(),
            post: post::Post::default(),
            n24: 0,
            n_out: 0,
            last_y: None,
        }
    }

    /// One receiver-bank sample (24-bit I/Q) in. `bank` is the coefficient bank the channel
    /// filter uses if this sample completes a 24 ksps sample.
    pub fn push(&mut self, i: i64, q: i64, bank: &CoefBank) -> Option<Stamped> {
        self.last_y = None;
        let x = (nb::scale_in(i, self.cfg.in_shift), nb::scale_in(q, self.cfg.in_shift));
        let x = self.nb.process(&self.cfg.nb, x);
        let v = self.dec.push(x)?;
        let y = self.filt.push(bank, v);
        self.last_y = Some(y);
        self.n24 += 1;
        let out = self.post.push(&self.cfg.post, y)?;
        self.n_out += 1;
        let per_out: u64 = if self.cfg.post.out24 { 3_200 } else { 6_400 };
        let stamp_off = self.n_out * per_out - adc_per_input(self.cfg.in_rate);
        Some(Stamped { out, stamp_off })
    }

    /// Intermediate values of the last 24 ksps sample (see `post::Post::trace`).
    pub fn post_trace(&self) -> [i64; 7] {
        self.post.trace
    }

    /// Status registers.
    pub fn smeter_db64(&self) -> i64 {
        self.post.smeter()
    }
    /// The current AGC gain.
    pub fn agc_gain(&self) -> i64 {
        self.post.gain()
    }
    /// True while the squelch is open.
    pub fn squelch_open(&self) -> bool {
        self.post.squelch_open()
    }
    /// Number of samples the noise blanker has held.
    pub fn blanked(&self) -> u32 {
        self.nb.blanked
    }
}

#[cfg(test)]
mod tests;
