<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# Bit-exact receiver-bank model (`tr-rxmodel`, WP R2)

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

`fw/tr-rxmodel`: a bit-exact Rust model of `rtl/rx/*.v` (the receiver bank WP R1 built --
`docs/RX_DSP.md`). Pure Rust, PC-only (plain `std`, not `no_std` -- this does not run on the
AE350, it stands in for the FPGA on a PC). New crate, not a module inside `tr-dsp`: two other work packages (`cpu-budget`, `s5-modes`) were actively changing `tr-dsp` at the same time this WP ran
(`git worktree list` showed both, and `git diff --stat master...HEAD -- fw/tr-dsp` on
`cpu-budget` alone touched eight files), so this model lives where it cannot collide with either.

## 1. Scope

The NCO quadrature mixer (a CORDIC mixer until WP RB4, section 7), both CIC decimation stages (fixed x10, variable x{5,10,20,40}),
the compensating FIR, output rounding at every stage, and the enable/reset behaviour --
including the disable/re-enable fix `docs/RX_DSP.md` section 1 describes (holding a whole
channel in reset while disabled, which the RTL implements by resetting the mixer's own
"sample in flight" tracker but *not* its phase accumulator or pipeline registers -- see section
2) -- plus `rx_bank`'s round-robin output arbiter, so the order receivers' samples interleave
onto the shared output stream is reproduced too, not just each receiver's own values.

## 2. Translation approach

Every register in the RTL (`rtl/rx/nco_mixer.v`, `cic_integrator.v`, `cic_comb.v`,
`cic_fixed.v`, `cic_var.v`, `fir_decim.v`, `rx_channel.v`, `rx_bank.v`) has a matching field in
one of this crate's modules (`nco.rs`, `cic.rs`, `fir.rs`, `channel.rs`, `bank.rs`; until WP RB4
the mixer was `cordic_mixer.v`, modelled by `cordic.rs`, now removed); every
`always @(posedge clock)` block has a matching computation in that module's `step` method. This
is a structural transliteration, not a re-derived mathematical model -- deliberately, since the
done-test (section 3) demands bit-for-bit agreement with the actual RTL, including whatever
fixed-point rounding quirks and quadrant-folding offsets that RTL happens to have, not
"functionally equivalent" behaviour.

Two things make this non-trivial to get right, both handled once in `bits.rs` and then used
everywhere:

- **Fixed-width two's-complement arithmetic.** Every value is kept as an `i64` that already IS
  the correctly sign-extended value of some register. `trunc(v, width)` truncates to `width`
  bits and re-sign-extends -- what a Verilog `reg <= expr;` does on every assignment. Because
  `+`/`-`/`*`/arithmetic-`>>` on such values give the identical bit pattern (mod 2^64, which
  never matters at these widths) as the Verilog operators, width only has to be handled at the
  moment a value is *stored*, not throughout every expression -- including the handful of places
  the RTL's Verilog signed/unsigned expression-context rules would otherwise matter (e.g. a
  bit-select is always unsigned even of a `signed` vector): those rules only affect the
  bit-pattern of intermediate additions in ways that vanish once you truncate at the end, which
  `bits.rs`'s doc comment works through once so every module doesn't have to re-derive it.
- **Same-edge read ordering.** Real RTL is synchronous: every `always @(posedge clock)` block
  reads *only* the register values as they stood before this clock edge, no matter which other
  block wrote them last, or in what textual order. This crate's `step` methods mutate `&mut
  self` in place (see section 4 for why), which means anything a later computation in the same
  `step` call still needs has to be captured into a local *before* it gets overwritten --
  `cic.rs`'s module doc states this discipline once; every module's doc comment flags the
  specific place(s) it applies (e.g. `fir.rs`: block 2's MAC-start snapshot must read the tap
  shift register as it stood before block 1's shift this same cycle, not after; `nco.rs`: the
  pipeline stages are computed from the output backwards, so every line reads a register no
  earlier line of the same `step` has overwritten yet; the removed `cordic.rs` used one local
  snapshot of its stage arrays for the same reason).

## 3. Done-test: bit-exact comparison against iverilog

`fw/tr-rxmodel/src/bin/r2_check.rs` is both the stimulus generator and the comparison: it is the
single source of truth for a deterministic test schedule (an `xorshift32`-seeded 12-bit ADC
stream -- integer-only, so there is no cross-language floating-point risk between it and the
RTL side, unlike a `$cos`-generated tone would be), covering:

- all 8 receivers, two per output rate (48/96/192/384 ksps), each tuned to a different frequency;
- a plain full-rate streaming segment (50,000 ADC cycles);
- a disable/re-enable of one receiver mid-stream (the regression case for the bug
  `docs/RX_DSP.md` section 1 describes), each side of it another streaming segment
  (6,000 cycles);
- a bursty `adc_valid` segment (~55% duty, 20,000 cycles), exercising the strobe-gated logic
  with real gaps, not just a continuous stream (`docs/RX_DSP.md` section 1: "works ... also with
  a sparser/gapped valid").

It writes that schedule once to `sim/rx/out/r2_stimulus.txt` (gitignored), runs it through the
real RTL via a **generic** replay harness (`sim/rx/r2_replay.v`, not named `tb_*.v` so
`tools/check.sh`'s generic testbench loop does not try to run it standalone before the stimulus
file exists -- it is invoked directly by `r2_check.rs` instead) compiled and run with
`iverilog`/`vvp`, replays the identical schedule through this crate's model directly in memory,
and diffs the two `(receiver index, I, Q)` output streams word for word, in order -- checking
the round-robin arbiter's output ordering, not just each receiver's own values.

**Result: bit-exact.** 1,360 output words, identical between iverilog and the model, in the
same order, on the first schedule this WP's stimulus generator was pointed at (no mismatches
needed fixing after the initial transliteration passed its own unit tests -- the per-module
translation notes in section 2 held up against the real RTL without a single word differing).
Per-receiver word counts confirm every receiver and every rate was actually exercised, not just
present in the config: 41/45 words (48 ksps, the disabled/re-enabled pair), 91/91 (96 ksps),
182/182 (192 ksps), 364/364 (384 ksps).

(These counts changed from an earlier version of this document's 1,953/63/51/102/102/204/204/
409/818 after the R1 receiver-bank fix, `docs/R4_BACKEND.md` section 9 and `docs/RX_DSP.md`
sections 1 and 4: the old, buggy RTL decimated by ADC clocks instead of `adc_valid` pulses once
`cordic_mixer`'s valid pipeline had filled, so the bursty segment's gaps used to produce extra,
spurious output words that this same bit-exact comparison never caught -- the model reproduced
the bug identically, so comparing model against RTL alone could not tell the difference. Fixed,
both sides agree on the smaller, now-correct counts; see the dedicated regression tests below for
checks that do not depend on the model and RTL merely agreeing with each other.)

Run: `cargo run -p tr-rxmodel --release --bin r2_check` (needs `iverilog`/`vvp` on `PATH`).
Wired into `tools/check.sh` as its own section (a few seconds -- comparable to the project's
other `tb_*.v` smoke tests, not `sim/run_sim.sh`'s multi-minute thorough run).

**Regression tests independent of the model/RTL comparison**
(`fw/tr-rxmodel/tests/regression_r1.rs`, part of plain `cargo test -p tr-rxmodel`, so also covered
by `tools/check.sh`'s `cargo test` step): the bit-exact comparison above cannot, by construction,
catch a bug the model reproduces identically from the RTL -- which is exactly what happened with
both R1 defects (`docs/R4_BACKEND.md` section 9) for as long as every existing testbench only fed
continuous, gap-free `adc_valid`. These two tests instead check the actual physical invariant,
independent of what the RTL happens to do:

- `bursty_valid_decimates_by_valid_pulses_not_clocks`: feeds one receiver a bursty `adc_valid`
  (about 51% duty) followed by a long dead gap, and asserts its output count equals exactly
  `valid samples accepted / decimation` and that no output arrives more than a generous
  pipeline-latency bound after the last accepted `adc_valid` pulse.
- `no_output_word_is_ever_repeated`: feeds all 8 receivers a bursty stream with real contention on
  the shared output stream, and asserts no `(receiver, I, Q)` word is ever emitted twice in a row.

Both fail against the pre-fix model code (verified while fixing R1: reverting just `cordic.rs` and
`bank.rs` to their pre-fix content fails both tests, with an output count of 124 against an
expected 51 for the first, and an immediate repeated `(7, 0, 0)` word for the second) and pass
against the fixed code -- proof these are genuine regression tests, not tautologies against the
model's own logic.

## 4. Speed

Measured by the same `r2_check` binary: a single receiver (`RxChannel`), `adc_valid` asserted
every cycle (the worst case -- real hardware feeds one ADC sample per clock), tuned to a
384 ksps output rate (the rate with the most CIC/FIR decimator work per input sample, so the
more demanding of the four to model), 20,000,000 simulated ADC cycles, this binary's own
`--release` build.

**Measured: roughly 15-22 Msps** on the development machine (`RUSTFLAGS="-C target-cpu=native"`,
scoped to just this one `cargo run` in `tools/check.sh` -- see the comment there for why it is
not applied workspace-wide; a representative run printed 17.7 Msps). The range reflects real
run-to-run variance on this machine (it runs several builds at once), not a flaw in the benchmark itself. This is **short of the 76.8 Msps real-time
target** WP S4 needs for one receiver (a live HL2 feeds ADC samples at 76.8 MHz continuously) by
roughly 4-5x.

Where the time goes, measured by isolating each stage during development: the CORDIC mixer
alone is the bottleneck, at roughly the same ~20 Msps as the whole channel -- both CIC stages
run at 100-400 Msps in isolation (comfortably above real-time) and the FIR's MAC sequencer, even
forced to run flat out every cycle (an unrealistically pessimistic case; in the real pipeline it
runs only while decimated samples are actually arriving), still measured 15-30 Msps alone. The
CORDIC runs at the full undecimated ADC rate with no decimation of its own (docs/RX_DSP.md
section 2's block diagram: it is the only stage with decimation 1), so it alone gates the whole
channel's throughput regardless of how fast the later, decimated stages are.

Two optimisation passes were tried and kept (both correctness-neutral -- re-verified against
`iverilog` after each): replacing the CORDIC's 15-iteration runtime loop with 15 `const`-generic
monomorphized calls (one specialized function body per stage index, so every shift amount and
arctan-table index becomes a compile-time constant instead of a runtime one), and replacing the
per-stage `if z_sign {a} else {b}` (a branch on pseudo-random-signal-driven, so unpredictable,
data) with the standard branchless conditional-negate (`(v ^ m) - m`). Neither produced more
than roughly a 2x improvement individually; `-C target-cpu=native` was worth close to another
2x on top. A workspace-wide `lto = true, codegen-units = 1` release-profile override was tried
and measured **no further improvement** here (tested, then reverted -- not worth its ~8x longer
build time for every other crate in this workspace for no measured gain).

**Not attempted, and the most likely way to close the remaining gap**: batching. Every one of
the CORDIC's 15 stages, for one ADC sample, reads only pre-this-edge state and is independent of
every other stage that same cycle (true in the RTL by construction: it is a pipeline, not a
loop) -- but consecutive *samples* are also largely independent work once expressed this way,
so processing several in flight at once with SIMD lanes (rather than one scalar sample at a
time, as this version does) is a real, structured opportunity that was not pursued here; doing
it without breaking bit-exactness (still one `trunc`/`part_select` per lane, not a shortcut
formula) is a meaningfully larger change than this WP's scope.

## 5. What this WP did not do

- **No real-time speedup beyond what section 4 describes.** WP S4 will need either the batching
  idea above, or to accept audio-rate (not ADC-rate) throughput requirements if its own pipeline
  turns out not to need every ADC sample individually (out of scope to resolve here -- S4 is a
  separate, blocked-on-this WP).
- **No `rx_bank` register-write-port timing edge cases beyond straightforward use.** The
  done-test's register writes only ever happen while `adc_valid` is deasserted (realistic
  firmware usage) and never change a channel's rate while active; `rx_bank.v`'s register file
  and its `cic2_decim` derivation (moved from `rx_channel.v` to `rx_bank.v` in WP RB3, see
  section 6) are still modelled with the RTL's real one-cycle write latency (see `bank.rs`), just
  not stress-tested against a same-cycle write-while-rate-changing-mid-block scenario the RTL
  itself does not obviously define cleanly either.
- **No `no_std`/embedded build.** This crate runs on the PC only (`RxBank`/`RxChannel` are plain
  `std`); nothing in this WP was meant to run on the AE350.

## 6. WP RB3 (FIR delay lines as circular buffers, shared variable-CIC engines): no model changes

WP RB3 replaced the RTL's per-receiver `cic_var` instances with a shared, time-multiplexed engine
(`rtl/rx/cic_var_shared.v`) and the FIR's shift-register-plus-snapshot delay line with a circular
buffer (`rtl/rx/fir_decim.v`, `rtl/rx/fir_delay_ram2.v`) -- see `docs/RX_DSP.md` section 9 for the
design. **This crate needed no changes at all.** The shared CIC engine's internal scheduling
latency never reaches its own interface (`docs/RX_DSP.md` section 9.1 has the full argument: the
per-context decimation-boundary counter and the `out_strobe`/`out_data` refresh stay immediate
and per-context, unaffected by how many extra clocks the shared engine takes to actually update
the accumulator state behind them), so `CicVar` here -- unchanged, still one dedicated instance
per context in this model, exactly mirroring the pre-RB3 RTL's own timing -- continues to predict
bit-identical output to the new, shared-hardware RTL. `r2_check`'s comparison (RTL, now built from
the RB3 files, against this unmodified model) is the proof: it still passes, 1,360 words,
bit-exact, same order, with no changes here at all.

This is worth calling out explicitly because it is the one place this crate's own translation
philosophy (section 2: mirror the RTL's structure, not just its net behaviour) could have been
read as requiring an update whenever the RTL's structure changes. It does not, when the RTL
change in question provably does not alter the modelled interface's observable timing -- which
is exactly the argument WP RB3 had to make and verify (twice: this unmodified-model comparison,
and independently, `sim/rx/tb_rb3_compare.v`'s word-for-word comparison of the new RTL against
the pre-RB3 RTL kept under `sim/rx/ref/`) before relying on it.

## 7. WP RB4 (NCO mixer instead of the CORDIC): `nco.rs` replaces `cordic.rs`

WP RB4 replaced `rtl/rx/cordic_mixer.v` with `rtl/rx/nco_mixer.v` (`docs/RX_DSP.md` section 10),
which gives different output words (a table-based mixer, not a CORDIC), so the model changed with
it: `cordic.rs` is removed and `nco.rs` transliterates the new mixer's receive mode register for
register (seven pipeline stages, the valid tracking unchanged in form). It reads the RTL's own
table file, `rtl/rx/nco_sin_table.hex`, with `include_str!`, so the two cannot drift apart.
`channel.rs` swaps the one field; nothing else in the crate changed.

- `r2_check`: **PASS, 1,360 output words bit-exact** between iverilog and the model, same order.
- Speed: the mixer was the model's bottleneck (section 4); the NCO model is a handful of
  multiplies and adds per sample instead of 15 CORDIC stages, and a single receiver now measures
  **26.6 Msps** (was 15-22). Still short of real time (76.8 Msps); where the rest of the time goes
  was not measured again.
- New unit tests in `nco.rs`: the table matches its definition, and the model's output is within
  1.2 LSB of the ideal mix at every sample.
