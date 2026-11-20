// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

//! Regression tests for the two defects of the receiver bank that `docs/R4_BACKEND.md` section 9
//! describes, and that `rtl/rx/nco_mixer.v` (same valid tracking as the earlier `cordic_mixer.v`),
//! `rtl/rx/rx_bank.v` and this crate's `nco.rs` and `bank.rs` (kept bit-exact with them) avoid:
//!
//! 1. A bank that decimates by ADC clocks instead of by accepted `adc_valid` pulses, once the
//!    valid-tracking shift register of the mixer has filled: `out_strobe` stays high forever, so
//!    every downstream CIC and FIR stage runs free on the frozen last sample on every clock, valid
//!    or not.
//! 2. An arbiter in `rx_bank` that clears the pending flag of a granted channel one clock too late,
//!    so with nothing else pending it grants (and emits) the same unchanged sample again on the very
//!    next clock.
//!
//! Both tests run only the Rust model (no `iverilog`), which is fast enough for plain `cargo test`,
//! and just as strong as an RTL-level check here, because `bin/r2_check.rs` already proves that this
//! model is bit-exact with the RTL. A model that reproduces a defect of the RTL bit for bit fails
//! these tests while the defect is there and passes them once it is gone, as the hardware would.

use tr_rxmodel::fir::load_coeffs_hex;
use tr_rxmodel::{RxBank, RxChannel};

fn coeffs_path() -> std::path::PathBuf {
    // fw/tr-rxmodel/tests/regression_r1.rs -> CARGO_MANIFEST_DIR = fw/tr-rxmodel
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../rtl/rx/fir_coeffs.hex")
}

// Same tiny deterministic PRNG `bin/r2_check.rs` uses for its stimulus, integer-only, so there
// is no floating-point risk, and reused here only for its convenient properties (fast, gives a
// varied 12-bit ADC-like sample stream), not because these tests need to match r2_check's own
// stimulus.
fn xorshift32(state: &mut u32) -> u32 {
    let mut x = *state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    *state = x;
    x
}

fn prng_sample(state: &mut u32) -> i32 {
    let v12 = (xorshift32(state) & 0xFFF) as i32;
    if v12 & 0x800 != 0 {
        v12 - 0x1000
    } else {
        v12
    }
}

/// A receiver's total decimation from ADC rate to output rate: CORDIC(1) x cic_fixed(10) x
/// cic_var({40,20,10,5}) x fir_decim(4), `docs/RX_DSP.md` section 2.
fn total_decimation(rate_sel: u8) -> u64 {
    match rate_sel & 0b11 {
        0 => 1600, // 48 ksps
        1 => 800,  // 96 ksps
        2 => 400,  // 192 ksps
        _ => 200,  // 384 ksps
    }
}

/// (a) With a bursty `adc_valid` (about 51% duty) followed by a long dead gap, one receiver's
/// output count must equal exactly `valid samples accepted / decimation`, and the last output
/// must arrive no more than a generous pipeline-latency bound after the last accepted
/// `adc_valid` pulse. With the defect, the `out_strobe` of the mixer stays high once its pipeline
/// has filled, so the bank keeps decimating by raw clocks for as long as the gap lasts, and
/// `docs/R4_BACKEND.md` section 9 measured 950 extra samples across the bank in 40,000 clocks with
/// `adc_valid` low. A 5,000-clock dead gap at 384 ksps (decimation 200) would show roughly 25 such
/// spurious outputs, and this test requires exactly 0.
#[test]
fn bursty_valid_decimates_by_valid_pulses_not_clocks() {
    let coeffs = load_coeffs_hex(&coeffs_path()).expect("load rtl/rx/fir_coeffs.hex");
    let rate_sel: u8 = 3; // 384 ksps: smallest decimation (200), most sensitive to the bug
    let decim = total_decimation(rate_sel);
    let phase_inc = 700_000; // an arbitrary nonzero raw 32-bit NCO phase increment (not Hz)

    let mut ch = RxChannel::default();
    let mut prng: u32 = 0xA5A5_1234;

    const BURSTY_CYCLES: u32 = 20_000;
    const GAP_CYCLES: u32 = 5_000; // >> the receiver's own decimation (200) and its pipeline depth

    let mut valid_count: u64 = 0;
    let mut last_valid_cycle: i64 = -1;
    let mut last_output_cycle: i64 = -1;
    let mut output_count: u64 = 0;
    let mut cycle: i64 = 0;

    // Bursty phase: about 51% duty, exercising the strobe-gated chain with real gaps mid-stream.
    for _ in 0..BURSTY_CYCLES {
        let (out_valid, _i, _q) = ch.out();
        if out_valid {
            output_count += 1;
            last_output_cycle = cycle;
        }
        let valid = (xorshift32(&mut prng) % 100) < 51;
        let data = if valid { prng_sample(&mut prng) } else { 0 };
        if valid {
            valid_count += 1;
            last_valid_cycle = cycle;
        }
        ch.step(false, data, valid, phase_inc, rate_sel, true, &coeffs);
        cycle += 1;
    }

    // Long dead gap: adc_valid stays low for the rest of the run.
    for _ in 0..GAP_CYCLES {
        let (out_valid, _i, _q) = ch.out();
        if out_valid {
            output_count += 1;
            last_output_cycle = cycle;
        }
        ch.step(false, 0, false, phase_inc, rate_sel, true, &coeffs);
        cycle += 1;
    }

    let expected = valid_count / decim;
    assert_eq!(
        output_count, expected,
        "output count ({output_count}) must equal valid samples accepted ({valid_count}) / \
         decimation ({decim}) exactly -- extra outputs mean the bank kept decimating by clocks \
         during the dead gap instead of stopping once adc_valid stopped"
    );
    assert!(
        last_valid_cycle >= 0,
        "test bug: no adc_valid pulse was ever sent"
    );
    assert!(
        last_output_cycle < last_valid_cycle + 300,
        "an output arrived at cycle {last_output_cycle}, more than 300 clocks (comfortably more \
         than the CORDIC + FIR pipeline's actual depth) after the last accepted adc_valid pulse \
         at cycle {last_valid_cycle} -- the bank kept producing output long after adc_valid \
         stopped"
    );
}

/// (b) No output word (receiver index, I, Q) is ever emitted twice in a row on the shared output
/// stream of the bank. With the defect, the arbiter of `rx_bank` clears the pending flag of a
/// granted channel one clock too late, so with nothing else pending it grants the same channel
/// again on the very next clock with its unchanged pending sample still sitting there, and
/// `docs/RX_DSP.md` section 6 measured 499 of 2,367 samples repeated this way. Real receiver
/// output, driven by pseudorandom ADC data through a CORDIC/CIC/FIR chain, essentially never
/// repeats a 24-bit I/Q pair by coincidence, so any adjacent duplicate in the stream is this defect.
#[test]
fn no_output_word_is_ever_repeated() {
    let coeffs = load_coeffs_hex(&coeffs_path()).expect("load rtl/rx/fir_coeffs.hex");
    let mut bank = RxBank::default();
    let mut prng: u32 = 0x1357_9BDF;

    // 8 receivers, distinct frequencies and rates, real contention on the shared stream/arbiter.
    let channels: [(u32, u8); 8] = [
        (0x0300_0000, 0),
        (0x0500_0000, 0),
        (0x0900_0000, 1),
        (0x0D00_0000, 1),
        (0x1100_0000, 2),
        (0x1500_0000, 2),
        (0x1900_0000, 3),
        (0x1D00_0000, 3),
    ];
    for (chan, &(freq_word, rate_sel)) in channels.iter().enumerate() {
        let chan = chan as u32;
        bank.step(false, 0, false, true, chan << 1, freq_word, &coeffs);
        bank.step(
            false,
            0,
            false,
            true,
            (chan << 1) | 1,
            4 | rate_sel as u32,
            &coeffs,
        );
    }

    let mut prev: Option<(usize, i32, i32)> = None;
    let mut checked = 0u64;
    // 100,000 cycles at ~60% duty, spread over 8 receivers whose decimation ranges 200-1,600,
    // gives on the order of 1,000 total output words (measured: ~1,120), enough real arbiter
    // traffic to make an undetected repeat implausible.
    const CYCLES: u32 = 100_000;
    for _ in 0..CYCLES {
        let (out_valid, idx, i, q) = bank.out();
        if out_valid {
            let word = (idx, i, q);
            assert_ne!(
                prev,
                Some(word),
                "output word {word:?} (receiver, I, Q) repeated on the next output -- rx_bank \
                 arbiter regression"
            );
            prev = Some(word);
            checked += 1;
        }
        let valid = (xorshift32(&mut prng) % 100) < 60;
        let data = if valid { prng_sample(&mut prng) } else { 0 };
        bank.step(false, data, valid, false, 0, 0, &coeffs);
    }

    assert!(
        checked > 500,
        "test bug: only {checked} output words seen, not enough traffic to exercise the arbiter"
    );
}
