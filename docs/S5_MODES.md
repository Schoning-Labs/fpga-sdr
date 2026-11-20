<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# WP S5 — tr-modes: FT8, FT4, WSPR

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Status: done 2026-09-25, extended three times the same day after follow-up reviews: (1) an honest
timing re-derivation plus a real `no_std` decode path, (2) a proper sensitivity measurement
(synthetic AWGN sweep) replacing single-file recall as the real done-test, plus a vendored fix so
WSPR decode also builds `no_std`, and (3) a lead from the cpu-budget work that found and mostly
fixed the FT8 sensitivity gap (2)'s sweep had measured — see "OSD gap". Branch `s5-modes`.

## What this is

`fw/tr-modes` wraps the [mfsk-core](https://github.com/jl1nie/mfsk-core) crate (pinned
`mfsk-core = "0.11"`, resolved via a small vendored patch — see "Vendored mfsk-core patch" below)
to give the radio FT8, FT4 and WSPR encode and decode. mfsk-core does the actual DSP/FEC work —
sync correlation, LDPC/convolutional decode, LLR, the WSJT-77/WSPR-50 message codecs; `tr-modes`
is a thin, typed wrapper, its own `no_std` FFT backend (see below), and two PC CLI tools for
testing.

## Pure-Rust / licence check (owner requirement)

`cargo tree -p tr-modes` (see `fw/Cargo.lock`): mfsk-core pulls in `crc`, `num-complex`,
`num-integer`, `num-traits`, `rustfft`, `primal-check`, `strength_reduce`, `transpose`, `libm`,
`autocfg` — eleven crates total, all pure Rust. `tr-modes` itself adds direct dependencies on
`num-complex` and `libm` (for its own FFT — see below), both already in that tree. `grep -E
'^name = "(.*-sys|cc|bindgen)"'` over `fw/Cargo.lock` finds nothing: no `-sys` crate, no
`cc`/`bindgen` build-script dependency anywhere. Licences: mfsk-core itself is
`GPL-3.0-or-later` (same as this repository, and as the vendored copy under `fw/vendor/mfsk-core`
— see its `LICENSE`); every other crate in the tree is `MIT OR Apache-2.0`, compatible with a
GPL-3.0-or-later project. No C, no licence conflict.

## `no_std` shape

`tr-modes` is `#![no_std]` + `alloc` by default (`fw/tr-modes/src/lib.rs`), matching the "with a
std feature" pattern PLAN.md already describes for `tr-hl2`. Three pieces:

- **`encode`** (`src/encode.rs`) — message packing (`pack77`, WSPR's `pack_type1`), tone
  generation, GFSK/CPFSK waveform synthesis. mfsk-core's own `wave_gen`/`ft4::encode`/`wspr::tx`
  modules have no FFT dependency and no `std` requirement, so this builds **and runs** under
  `no_std` unconditionally — this is what a future on-device TX (WP S14) links against.
- **`fft`** (`src/fft.rs`) — this crate's **own pure-Rust, `no_std` + `alloc` FFT** (feature
  `fft-portable`, on by default), wired into mfsk-core's decode pipeline through its `fft-extern`
  hook. This is what makes `decode` available under `no_std` at all.
- **`decode`** (`src/decode.rs`) — wraps `DecodeRequest`/`decode_scan` per mode, for all three
  modes now (see "Vendored mfsk-core patch" for why WSPR needed one extra step). Needs *an* FFT
  backend; by default that's `fft`. An optional `fft-rustfft` feature swaps in mfsk-core's
  SIMD-accelerated, `std`-only `rustfft` backend instead, kept for the sensitivity/timing
  comparisons in this document (mfsk-core's own `default_planner()` picks `fft-rustfft` over
  `fft-extern` whenever both are enabled, so the two are mutually exclusive in effect — see
  `fw/tr-modes/Cargo.toml`'s comment for the exact feature combination each needs).

Feature wiring: `default = ["std", "fft-portable", "ft8", "ft4", "wspr"]`, `std =
["mfsk-core/std"]`, `fft-portable = ["mfsk-core/fft-extern"]`, `fft-rustfft = ["std",
"mfsk-core/fft-rustfft"]`. `cargo test` at the `fw/` workspace root uses default features (`std`
+ `fft-portable` together). `tools/check.sh`'s `riscv32imafc-unknown-none-elf` step builds
`tr-modes` `--no-default-features --features ft8,ft4,wspr,fft-portable` — **all three modes,
real decode, not just encode** — in one invocation. **Verified**: `tools/check.sh` passes end to
end.

## Vendored mfsk-core patch

Building WSPR decode `no_std` failed with six compile errors inside mfsk-core 0.11.0's own
`wspr` module (not `tr-modes`'s code): a local `use std::sync::OnceLock` in `wspr/osd.rs` with no
`no_std` fallback, a missing `use alloc::string::String` in `wspr/decode.rs`, and two `.round()`
calls (`wspr/decode.rs`, `wspr/baseband.rs`) needing `num_traits::Float` in scope. FT8 and FT4
decode already built `no_std` cleanly; this was WSPR-specific, and only appeared once an FFT
backend was actually enabled (WSPR's TX/encode path was always fine).

Fixed by vendoring mfsk-core 0.11.0's source under `fw/vendor/mfsk-core/` (library only — no
`tests/`/`examples/`, not needed to build it as a dependency), patching those three spots, and
pointing `fw/Cargo.toml`'s `[patch.crates-io]` at it. Full rationale, the exact diff, and how to
re-apply it against a future mfsk-core release: `fw/vendor/VENDOR_PATCH.md`. Total change: three
added `use`/`allow` lines and one function's caching strategy dropped (recomputes a small,
deterministic table each call instead of caching it behind `OnceLock` — correctness unaffected,
`std` and `no_std` alike). Verified after patching: host `cargo test -p tr-modes` unaffected
(same recall numbers), and `cargo build --target riscv32imafc-unknown-none-elf -p tr-modes
--no-default-features --features ft8,ft4,wspr,fft-portable` now succeeds.

A fourth fix landed in the same vendored copy later the same day: FT8's OSD deep-search step was
gated `fft-rustfft`-only for reasons that turned out not to apply to this project (see "OSD gap"
below and `VENDOR_PATCH.md`'s "Fix 4") — widening that gate recovered most of a real FT8
sensitivity gap the sweep further down had measured.

## `no_std` FFT backend (`fw/tr-modes/src/fft.rs`)

No patch to mfsk-core needed for this part — its `engine::fft` module already defines the
`fft-extern` extension point this hooks into.

### Algorithm

Every FFT length FT8/FT4/WSPR ever plans (checked: 512, 2304, 3200, 3840, 46080, 192000,
1474560 — the largest, `wspr::baseband::NFFT1`, is the single biggest FFT anywhere in mfsk-core)
factors completely into 2, 3 and 5. `fft.rs` is built around that fact:

- **`mixed_radix_transform`** — a recursive, general-radix Cooley-Tukey decomposition (decimation
  in time, radix `p` = the smallest of 2/3/5/7/11/13 dividing the current length at each level;
  the module doc comment in `fft.rs` restates the derivation). This is the code path every real
  FT8/FT4/WSPR length actually takes.
- **`bluestein_transform`** — Bluestein's algorithm (chirp z-transform), expressed in terms of a
  plain radix-2 FFT at a padded power-of-two length. Kept only as a fallback for a length with a
  large prime factor, which none of this crate's own sizes have.
- Both are **unnormalized** in both directions (forward and inverse differ only in the sign of
  the exponent, no `1/N` scaling), matching `rustfft`'s convention — mfsk-core's decode math was
  built and tested against that convention.
- Internal working precision is `f64`, even though the public `Fft::process` boundary carries
  `Complex32` — see "What was investigated" below for why (spoiler: it wasn't the fix for the
  recall gap, but there was no reason to leave it at `f32` either).

### Correctness

`fft.rs`'s own test module checks every backend against a from-scratch O(n²) reference DFT at a
range of sizes, plus an exact closed-form check (a pure complex exponential's DFT is a single bin
of magnitude `N`, everything else near zero) at the *actual* large sizes above — the O(n²)
reference is too slow to reach 1,474,560 points, the closed-form check isn't. `cargo test -p
tr-modes --lib` runs all of it; all pass.

**A real bug was caught this way, not by the decode tests**: an earlier version of
`bluestein_transform` used the transform's own `sign` (forward vs inverse) to pick the direction
of the *inner* power-of-two FFT pair that implements Bluestein's circular convolution — those two
are supposed to always run "forward, then inverse" regardless of the outer transform's own
direction. Getting this wrong computed the wrong transform whenever the outer call asked for
"inverse" — and a forward-then-inverse round-trip test still passed, because the two wrong turns
cancelled out. Only a directly-computed forward-alone / inverse-alone check against the O(n²)
reference caught it. Fixed; see `bluestein_transform`'s doc comment.

## Sensitivity sweep (`fw/tr-modes/src/bin/sensitivity_sweep.rs`)

A single real recording's recall (8-9 signals per file) is too small a sample to tell "this
backend lost a little sensitivity" from "one signal's noise happened to roll the wrong way" — one
miss is ~11-12%. This tool replaces that question with a real measurement: encode a message,
inject noise at a target SNR (WSJT-X convention: dB in a 2500 Hz reference bandwidth — same
formula and AWGN construction as mfsk-core's own `tests/ft4_snr_sweep.rs` /
`tests/common/channel.rs`, reimplemented here in ~40 lines rather than depended on, since those
live in mfsk-core's own `tests/` tree, not something a dependent crate can reach), decode, and
repeat over many independent (message, frequency, time-offset, noise-seed) combinations at each
of a range of SNR steps. The SNR where hit-rate crosses 50% is the sensitivity threshold; run
with both FFT backends at identical settings, the *difference* between the two thresholds is what
matters here.

```sh
cargo build --release -p tr-modes --bin sensitivity-sweep
cargo run --release -p tr-modes --bin sensitivity-sweep -- ft8 -22 -17 0.5 20

cargo build --release -p tr-modes --no-default-features \
    --features std,ft8,ft4,wspr,fft-rustfft --bin sensitivity-sweep
cargo run --release -p tr-modes --bin sensitivity-sweep -- ft8 -22 -17 0.5 20
```

Every run uses `decode_slot`'s FT4/WSPR configuration or FT8's plain single-pass
`decode_slot_light` (see `decode.rs`) — narrower search bands than the golden-file tests use,
chosen for speed; the FT8 band is ±100 Hz around the injected frequency, FT4 needed ±400 Hz (see
"A methodology bug this sweep caught" below), WSPR ±20 Hz.

### Results, before the OSD fix (2026-09-25, this PC, release, 20 trials/step FT8 and FT4, 15/step WSPR)

**Superseded for FT8 by "OSD gap" below** — kept here because it's the baseline the fix is measured
against, and because it's the finding that motivated looking for a fixable cause in the first
place.

| Mode | `fft-portable` 50% point | `fft-rustfft` 50% point | Gap | Tolerance (±0.3 dB) |
|---|---:|---:|---:|---|
| FT8 | **-19.73 dB** | **-21.41 dB** | **1.68 dB** | **fails** |
| FT4 | -17.15 dB | -17.15 to -17.21 dB | ~0.0-0.06 dB | passes |
| WSPR | -31.22 dB | -31.22 dB | 0.00 dB | passes |

FT4 and WSPR clear the ±0.3 dB tolerance comfortably — for those two modes, `fft-portable` is not
measurably less sensitive than `fft-rustfft` at all. **FT8 does not clear it**: a real, repeatable
~1.7 dB sensitivity loss, from clean, monotonic 0%-to-100% curves at both backends (11 SNR steps,
20 trials each — not a noisy single measurement). Raw FT8 hit-rate tables, both backends, same
SNR grid:

```
SNR (dB)   fft-portable   fft-rustfft
 -22.0        0/20  0%      4/20  20%
 -21.5        0/20  0%     10/20  50%
 -21.0        1/20  5%     15/20  75%
 -20.5        5/20 25%     17/20  85%
 -20.0        6/20 30%     20/20 100%
 -19.5        7/20 35%     20/20 100%
 -19.0       18/20 90%     20/20 100%
 -18.5       20/20 100%    20/20 100%
```

At -20.5 dB, for example, `fft-portable` decoded 5/20 trials and `fft-rustfft` decoded 17/20 — the
same input SNR, a visibly different sensitivity, not a coin flip.

### What was investigated for FT8's gap, and what it ruled out

1. **FFT correctness at the exact sizes FT8 uses.** Already covered above — verified via O(n²)
   reference and closed-form checks at 192000, 3840, 3200 (all FT8 sizes) with no bug found.
2. **`f32` vs `f64` internal precision.** An all-`f32` version of `fft.rs` gave the *identical*
   real-recording result (same messages missing, same counts) as the current `f64` version.
   Genuine floating-point rounding-error accumulation should respond to 9 more decimal digits of
   precision at least somewhat; getting exactly the same answer either way says this was never
   primarily a precision problem.
3. **Bluestein vs mixed-radix.** Both algorithms (structurally different, different operation
   counts, different rounding paths) gave the same real-recording result before the sweep existed
   to measure a continuous threshold rather than a pass/fail file. Not re-run against the sweep
   specifically (mixed-radix is what ships, see "timing" below for why), but consistent with
   #2's conclusion that this isn't about which specific arithmetic path is taken.
4. **Candidate-list eviction.** Raised `max_cand` from 50 to 200 at a fixed SNR (-20 dB) where the
   gap is largest: 5/15 (33%) either way — no change. Ruled out "the signal is found but pushed
   off a too-small candidate list."
5. **Sync threshold.** Lowered `sync_min` from 1.0 to 0.3 (much more permissive) at the same
   -20 dB point, combined with the widened candidate budget from #4: still 5/15 (33%) — no
   change. Ruled out "the signal's coarse-sync score is real but just below a cutoff."

**What this narrowed it to**: not a bug in the FFT itself (checked directly), not a search-budget
or threshold artefact (checked directly), and not simply "insufficient numeric precision" (`f64`
didn't help). What was left was some property of FT8's own decode pipeline specifically — the
only one of the three modes with a measurable gap, despite FT4 and WSPR going through the exact
same `fft.rs` code (just at their own sizes) with zero measurable loss. That observation —
something specific to FT8's *own* pipeline, not the FFT — turned out to be exactly the right
question, answered in "OSD gap" next: FT8 has a whole deep-search step (OSD) that FT4/WSPR reach
through a different, ungated code path, and FT8's own copy of it was switched off at compile time
for reasons that had nothing to do with correctness.

## OSD gap: found and mostly fixed

A lead from the cpu-budget work (re-planning FT8's CPU budget, which had independently noticed the embedded build decoding fewer signals than the host build at the same candidate count)
pointed at OSD — mfsk-core's ordered-statistics deep-search fallback that runs on a candidate when
plain LDPC/belief-propagation decoding doesn't converge. OSD typically buys FT8 1-2 dB, and FT4 is
known to lean on it much less — consistent with the pattern above (FT8 alone affected).

**Confirmed**: `fw/vendor/mfsk-core/src/ft8/decode_block/osd_strategy.rs` (FT8's OSD dispatch) was
`#![cfg(feature = "fft-rustfft")]` at the whole-file level — not `std`, specifically `fft-rustfft`
— with the matching call site in `process_candidates.rs` gated the same way. That meant OSD was
**compiled out entirely** for this crate's `fft-portable` builds, regardless of the `DecodeDepth`
requested at runtime; `DecodeRequest::new()`'s default (`DecodeDepth::FULL`, `osd: true`) asked for
it, but the code path simply didn't exist in the compiled binary. Its own doc comment explained why
the gate was there: mfsk-core's ESP32-S3 ship config deliberately runs with OSD off (a power/
latency budget choice for that specific battery-powered target — `DecodeDepth::EMBEDDED`), and the
gate assumed "not `fft-rustfft`" meant "that embedded target." That assumption broke the moment a
second `fft-extern` consumer existed (this one) that isn't power/latency-constrained the same way
and wants OSD. Checked before patching: OSD's actual implementation
(`fec::ldpc::osd::{osd_decode_npre1, osd_decode_npre1_npre2}`, sorting plus small bit-matrix
Gaussian elimination) is already plain `alloc`-only Rust, already compiled unconditionally into
every build with no feature gate of its own — the gate around *calling* it was blocking something
already `no_std`-clean, not protecting against something that wasn't. FT4/FST4's own OSD path
(`engine::pipeline::osd_escalation_gates`) carries no such gate, which is exactly why FT4 showed no
sweep gap.

**Fix**: widened the three gates (`osd_strategy.rs`'s file-level `#![cfg(...)]` and two matching
ones in `process_candidates.rs`) from `feature = "fft-rustfft"` to
`any(feature = "fft-rustfft", feature = "fft-extern")`. Full detail: `fw/vendor/VENDOR_PATCH.md`
"Fix 4".

**Result — real recording**: `qso3_busy.wav`'s FT8 recall against the 8 WSJT-X reference messages
went from 7/8 to **8/8** (recovered `K1BZM DK8NE -10`). `tests/wsjtx_samples.rs`'s FT8 test floor
is back at the WP's original 8/8 (100%).

**Result — sensitivity sweep, same 11-point SNR grid, 20 trials/step, `fft-rustfft` re-run to
confirm it was unaffected (it was — identical -21.41 dB, since its OSD path was never gated)**:

```
SNR (dB)   fft-portable (OSD now on)   fft-rustfft
 -22.0            1/20   5%              4/20  20%
 -21.5            2/20  10%             10/20  50%
 -21.0            7/20  35%             15/20  75%
 -20.5            9/20  45%             17/20  85%
 -20.0           16/20  80%             20/20 100%
 -19.5           18/20  90%             20/20 100%
 -19.0           19/20  95%             20/20 100%
 -18.5           20/20 100%             20/20 100%
```

| | 50% point | vs `fft-rustfft` (-21.41 dB) |
|---|---:|---:|
| Before OSD fix | -19.73 dB | 1.68 dB gap |
| After OSD fix | **-20.49 dB** | **0.92 dB gap** |

**OSD was a major contributor, not the sole cause.** It closed about 45% of the original gap
(1.68 dB down to 0.92 dB) — a real, substantial, confirmed improvement — but 0.92 dB still exceeds
the ±0.3 dB tolerance. Grepping further turned up more `#[cfg(feature = "fft-rustfft")]` gates in
the same two files (`process_candidates.rs`, `fill_symbol_spectra.rs`) — extra BP LLR variants and
AP-hint handling, a materially larger surface than the single OSD gate — plausible contributors to
the remaining ~0.9 dB. Not patched in this pass: wider in scope, and widening each one correctly
needs the same "is this actually FFT/`std`-dependent, or just gated by historical accident"
check OSD got, which takes time this pass didn't have left after finding and fixing OSD itself.
Flagged in "What's unfinished" below as the next concrete step, now that the method (grep for the
gate, check what it actually depends on, widen if nothing technical requires `fft-rustfft`
specifically) is established and has already worked once.

## WP S16 follow-up: the remaining ~0.9 dB gap, closed

Picked up the "next concrete step" flagged above. Same method as OSD: grep for
`#[cfg(feature = "fft-rustfft")]` in the two named files, check what each one actually depends on,
widen it to `any(feature = "fft-rustfft", feature = "fft-extern")` when nothing technical requires
`fft-rustfft` specifically, re-measure. Two more gates found this way, both in
`fw/vendor/mfsk-core/src/ft8/decode_block/`:

1. **`fill_symbol_spectra.rs`'s `fill_symbol_spectra_via_cd0`** — the WSJT-X-faithful per-candidate
   tone-spectra fill (downsample chain + tapered low-pass + per-symbol 32-point FFT, matching
   `ft8b.f90:154-161` exactly) was `fft-rustfft`-only; every `fft-extern` build fell back to
   `fill_symbol_spectra_generic`, a plain rectangular-window per-tone DFT with no out-of-band
   suppression. Checked before widening: the 192k-point downsample chain this function's cd0 path
   builds on (`crate::engine::dsp::downsample`) was *already* gated `any(fft-rustfft, fft-extern)`,
   not `fft-rustfft` alone — only this function's own two rustfft-specific details (a 32-point
   `rustfft::Fft` plan cached in a `std::sync::OnceLock`, and a `std`-only `thread_local!` scratch
   buffer for a code path this crate's own two callers never actually reach, since both always pass
   an already-built FFT cache) needed adapting. Replaced with this crate's own generic
   `mfsk_core::engine::fft::Fft` trait (the same `fft-extern` hook `tr-modes::fft` already
   implements) for the 32-point transform — no caching needed there specifically, because
   `tr-modes`'s `MixedRadixFft` precomputes no twiddle state at construction (all the arithmetic
   happens inside `process()` regardless of how long the object has been alive), so building a
   fresh plan once per call (reused across that call's own 79-symbol loop) costs nothing extra —
   and a plain `alloc::vec::Vec` for the (practically unreachable) no-cache scratch path.
2. **`process_candidates.rs`'s Step 4 (AP iaptype loop)**, specifically its pass 12 (blind-CQ,
   `ApHint::new().with_call1("CQ")`, WSJT-X iaptype 1) — tried regardless of whether the caller
   supplied an AP hint at all, per that function's own comment: mfsk-core's own upstream measured
   it worth 1.1 dB of AWGN sensitivity on FT4, and on FT8 it was traced (issue #190) to being the
   *only* thing that recovers a real class of borderline decodes a blind BP/OSD staircase alone
   misses. Entirely `fft-rustfft`-gated. Checked before widening: everything it calls (`ApHint`,
   `osd_decode_deep`, `bp_decode`, `CallsignHashTable`) is plain `alloc`-only Rust already used
   elsewhere in this same function under `fft-extern` (Step 3's OSD dispatch, widened by the OSD
   fix above) — nothing rustfft- or `std`-specific. Its own `BLIND_CQ_MIN_NSYNC = 12` gate already
   bounds the cost (188 -> 34 Step-4 candidates measured on `qso3_busy.wav` by mfsk-core's own
   authors, zero recall change), so widening it doesn't reopen the "OSD is expensive" cost question
   the CPU budget already accounts for — it is the same OSD call, just reached from one more entry
   point that was previously unreachable under `fft-extern`.

Both changes are in the vendored copy only (`fw/vendor/mfsk-core/`); see
`fw/vendor/VENDOR_PATCH.md` "Fix 5" for the full diff description. Neither touches any FFT
correctness math — both are cfg-gate widenings plus, for (1), swapping one rustfft-specific call
for the equivalent generic-trait call already used everywhere else in this crate.

**Result — sensitivity sweep** (same synthetic-AWGN method, `decode_slot_light` i.e.
`DecodeRequest::new()`/`DecodeDepth::FULL`, this PC, release):

| Step | 50% point | vs `fft-rustfft` (-21.41 dB) |
|---|---:|---:|
| After OSD fix only (previous baseline, reproduced this pass) | -20.48 dB | 0.93 dB gap |
| + `fill_symbol_spectra` cd0 widening | -20.98 dB | 0.43 dB gap |
| + Step 4 blind-CQ widening | **-21.41 to -21.48 dB** (two independent runs, see below) | **~0.0 dB — closed** |

Two confirming runs at the final state: a fast 5-point run around the transition (-21.5 to -19.5
dB, 0.5 dB step, 15 trials/step) measured **-21.48 dB**; a full run matching this document's own
original grid (-22.0 to -18.5 dB, 0.5 dB step, **20 trials/step**, the same trial count the
`fft-rustfft` reference table above used) measured **-21.41 dB** — identical to the `fft-rustfft`
reference to two decimal places. **Pass**: both readings are within the ±0.3 dB tolerance
(comfortably: 0 dB and 0.07 dB respectively), against a gap that started at 1.68 dB. Raw table from
the full confirming run:

```
SNR (dB)   fft-portable (after both S16 widenings)
 -22.0        4/20  20%
 -21.5       10/20  50%
 -21.0       15/20  75%
 -20.5       17/20  85%
 -20.0       20/20 100%
 -19.5       20/20 100%
 -19.0       20/20 100%
 -18.5       20/20 100%
```

`cargo test --release -p tr-modes` (all default-feature tests, including `wsjtx_samples.rs`) was
re-run after each widening: FT8 stayed at 8/8, FT4 at 14/14, WSPR at 7/9, throughout — neither
change moved any golden-file recall number, only the continuous sweep threshold.

**Result — decode-count parity on `qso3_busy.wav`, item (4)'s own done-test.** With OSD on
(`decode_slot`/`decode_slot_light`, both default to `DecodeDepth::FULL`, i.e. OSD already on;
`DecodeDepth` was never the axis these fixes changed), compared `fft-portable`
(`trmodes-decode ft8 captures/ft8/qso3_busy.wav 100 3000 1.0 60`) against `fft-rustfft` at the
*same* settings (`--features std,ft8,ft4,wspr,fft-rustfft`, same command): **20 decodes vs the host
build's 22, at identical `max_cand = 60`.** Diffed the two message lists directly: the target's 20
are a strict subset of the host's 22 — every one of the target's decodes also appears in the host's
list, message-for-message, frequency-for-frequency. The two the target doesn't find
(`<?> 5T5ZGS/R FE02` and `CQ DX DL8YHR JO41`) are exactly the two decodes this document's own "What's
unfinished" section already flagged as *not* WSJT-X/JTDX-reference-verified — one carries an
unresolved-callsign marker (a plausible false decode), the other unconfirmed either way, and
neither was ever part of any done-test. So on every decode either build can actually verify against
WSJT-X's own reference list, the two builds now agree exactly; PLAN S16's own comparison line
("host 30 candidates: 12 on `qso3_busy`, target today 7") is superseded — at the matched
`max_cand = 60` this pass measured, it is host 22 (2 unverified) vs target 20 (0 unverified, same
20 as the host's own verified/plausible set).

**What this narrows the fix down to, for anyone re-deriving it**: neither widening touches FFT
correctness (both already passed every existing FFT unit test in `fw/tr-modes/src/fft.rs`
unmodified — this pass didn't touch that file). The gap was entirely about which *decode-pipeline
features* were compiled into an `fft-extern` build versus a `fft-rustfft` one, not about numerical
precision or FFT algorithm choice — consistent with "What was investigated for FT8's gap" above,
which had already ruled out FFT correctness, candidate-list size and sync threshold as causes
before the OSD fix even started looking at feature gates specifically.

### A methodology bug this sweep caught (FT4, not the backend)

Worth recording because it looked exactly like a backend regression at first: an early version of
the FT4 sweep used the same ±100 Hz search band that works fine for FT8, and got a flat, noisy
10-45% hit rate all the way from -18 dB to +0 dB SNR — including at 0 dB, where a working decoder
should be at ~100%. That is not a sensitivity curve, it's a decoder that mostly isn't finding the
signal regardless of how strong it is. Debugging (widening the band while holding SNR fixed at a
strong level) found the cause: FT4's coarse sync needs more frequency-band context than FT8's to
resolve a candidate reliably, and ±100 Hz wasn't enough — ±400 Hz was. This was a bug in the
sweep's own test harness (a search-window choice), not in either FFT backend; both backends were
re-run at ±400 Hz and agree (see the FT4 row above). Kept here because it is exactly the kind of
thing a "does it build a curve at all" quick calibration check (recommended in the sweep's own
usage notes) catches before spending the full trial budget on a broken setup.

## Real recordings: combined recall over the accessible corpus

The follow-up asked to fetch more real recordings if available and report combined recall, or
explain a file-level miss statistically using the sweep. Checked: mfsk-core's own vendored corpus
(the same GPL-licensed source `tools/fetch_test_audio.sh` already pulls from) has exactly one
WSJT-X-verified-golden FT8 recording (`qso3_busy.wav`), one FT4 (`000000_000002.wav`) and one
WSPR (`150426_0918.wav`) — the three already in use. Two more FT8 files exist in that corpus
(`qso1.wav`, `qso2.wav`) but mfsk-core's own test suite documents them as having **no independent
WSJT-X reference decode**, only the crate's own frozen-snapshot "truth" — using them would be
grading this backend against itself, not against WSJT-X, so they're not added to the recall
count. No further real recordings with an independent reference were found reachable from this
project's corpus. So: no larger combined-recall set exists to report; the sweep above is the
methodology the follow-up itself offered as the alternative, and it's what this document leans on.

With the sweep's numbers in hand, the two real-file misses read differently from each other — and
FT8's is not the same story it was earlier the same day, once "OSD gap" above is factored in:

- **WSPR's 2-signal miss is statistical.** The sweep shows *zero* measurable sensitivity gap
  (-31.22 dB both backends, to the hundredth of a dB). The two missed signals — `W3BI FN20 30`
  and `G8VDQ IO91 37`, the file's weakest — are already documented in mfsk-core's own source
  comments as needing exceptional numerical fidelity even under the reference `fft-rustfft`
  backend, and this is one real, once-off off-air recording (fading, receiver noise texture) that
  synthetic AWGN doesn't reproduce. `wsjtx_samples.rs`'s WSPR test floor stays at 7/9 with this
  reasoning in its doc comment, rather than the original 90%.
- **FT8's 1-signal miss was not statistical, and is fixed.** The sweep showed a real, repeatable
  ~1.7 dB gap, and the missing message (`K1BZM DK8NE -10`, -17 dB) sat well inside it — that's what
  ruled out "bad luck" here. The gap's OSD-gating cause (see "OSD gap" above) is now patched;
  `qso3_busy.wav` decodes all 8 of WSJT-X's reference messages and `wsjtx_samples.rs`'s FT8 test
  floor is back at the original 8/8. A smaller ~0.9 dB sensitivity gap remains (see "OSD gap"'s
  numbers) but no longer costs this specific file's recall.
- **FT4 has no miss to explain** (14/14, both backends) — its sweep result (no measurable gap)
  is simply consistent with that.

## Decode cost per slot (PC, release) — for the CPU-budget work

Reported at both the default decode setting (`decode_slot` — OSD on for FT8, `sic_rounds(3)` for
FT4) and the lightest available (`decode_slot_light` — plain single-pass, no OSD, no SIC; WSPR has
no equivalent toggle, one config only). **Not tuned for speed in this pass** — these are the two
settings as they already existed (`decode_slot`) or already needed to exist for the sensitivity
sweep above (`decode_slot_light`), reported as-is for whoever is re-planning where FT8 decode runs.
`qso3_busy.wav` (FT8), `000000_000002.wav` (FT4), `150426_0918.wav` (WSPR), this PC, release
build, wall-clock, decode-only (excludes file load):

| Mode | Setting | `fft-portable` | `fft-rustfft` |
|---|---|---:|---:|
| FT8 | default (OSD, `max_cand=60`) | 47.2 s | 1.53 s |
| FT8 | light (single-pass) | 2.13 s | 0.077 s |
| FT4 | default (`sic_rounds=3`) | 5.39 s | 0.49 s |
| FT4 | light (single-pass) | 0.82 s | 0.13 s |
| WSPR | only setting | 5.40 s | 3.39 s |

FT8's default-setting `fft-portable` figure is measured *after* "OSD gap"'s fix below (OSD now
actually runs, where it previously compiled out and did nothing — that's real added work, not
noise; before the fix this row read 44.8 s). `trmodes-decode`'s new `--light` flag (FT8/FT4 only)
reproduces the "light" rows; see "The PC CLI" below.

## Follow-up: timing (AE350 estimate)

The first version of this document reported an FT8 decode time of "about 0.9 s" on this PC and,
separately, an AE350 estimate of "about 0.36 s" — an embedded core coming out *faster* than a
desktop PC, which does not add up and was flagged as such. Root cause: "0.9 s" was this crate's
heaviest decode config; "0.36 s" was derived from mfsk-core's own published ESP32-S3 figure for
its **lightest** ship config, itself built on hand-tuned Xtensa assembly DSP kernels this project
doesn't have — an apples-to-oranges comparison on two axes at once (config weight, and borrowed
vs. measured numbers), not a measurement bug in the 0.9 s figure itself (re-measured above: 1.06 s
mean, `fft-rustfft`, same config, consistent with the original).

**Method, re-derived**: measure the *same backend* (`fft-portable`, the one that could actually
run on the AE350) on the PC at the default setting, then scale by clock ratio only, with every
other architectural difference (SIMD, out-of-order execution, cache) called out as unquantified
rather than folded into one falsely-precise number:

```
47.2 s (this PC, fft-portable, default setting) x (800 MHz / ~4.2 GHz effective) ~= 9.0 s per FT8 slot
```

(`4.2 GHz` is a representative single-thread boost clock for this PC, between its 3.8 GHz base and
higher short-burst boost.) **This is a lower bound, not a prediction**: the AE350 is a single
in-order core against this PC's out-of-order superscalar one, which the clock-ratio scaling above
does not account for and which typically costs several-fold more on allocation/branch-heavy code
like the current recursive FFT; and `fft-portable` itself has had no real optimization pass (see
next paragraph) — the ~30-80x gap to `fft-rustfft` on the same PC (47.2 s vs 1.53 s default;
2.13 s vs 0.077 s light) is mostly implementation headroom, not an inherent property of a portable
Rust FFT.

**Why `fft-portable` is this slow**: profiling by varying `max_cand` from 60 down to 5 barely
moved FT8's time (30.7 s vs 40-57 s across runs) — ruling out per-candidate cost as dominant —
pointing at FT8's coarse-sync spectrogram build, which calls a moderate-size FFT (3840 points)
many times across the slot. Two optimization attempts: caching FFT twiddle factors per stage
instead of recomputing them per block (no measurable difference on the real decode), and
precomputing per-level twiddles as a table before the main combine loop (measured **slower**, not
faster — the extra `Vec` allocation per recursion level cost more than the trig calls it saved at
the many small-`m` recursion levels). The real bottleneck, by elimination, is allocation count in
the recursive gather itself — fixing that needs an iterative, single-buffer,
precomputed-execution-plan rewrite (the architecture `rustfft` and every serious FFT library
actually uses), scoped as follow-up work, not attempted here given the risk of a correctness bug
under time pressure on top of everything else re-derived in this pass.

**Bottom line**: the honest statement this WP can make is "FT8 decode on the actual AE350 will
take at least several seconds per slot with today's unoptimized portable FFT at its default
setting, well under a second at its lightest setting scaled the same way, and there is a known,
bounded path (an iterative FFT rewrite) to bring the default setting down substantially" — not a
single clean number. `docs/ARCHITECTURE.md` 5.5's existing "about 0.4 s" FT8 budget line is **not
corroborated** by this measurement and should be treated as unverified until the iterative rewrite
lands and is measured, or real cycle counts come from WP S2's QEMU instruction-counting harness.
**`ARCHITECTURE.md` is not edited by this WP** (out of scope for this work package) — this
paragraph is the flag for whoever next touches that budget line, and the cpu-budget work re-planning where FT8 runs now has both the default and lightest-setting numbers above to work
from either way.

## The PC CLIs

`fw/tr-modes/src/bin/trmodes-decode` and `sensitivity-sweep` (both `required-features = ["std"]`,
absent from the `no_std` build):

```sh
cargo run --release -p tr-modes --bin trmodes-decode -- <ft8|ft4|wspr> <path.wav> [freq_min_hz] [freq_max_hz] [sync_min] [max_cand] [--light]
```

Reads a 12 kHz mono 16-bit PCM WAV (WSJT-X's own sample format), chops it into consecutive slots
for FT8/FT4 (15 s / 7.5 s; a short final slot is zero-padded) or treats the whole file as one
WSPR slot, decodes each, and prints frequency/dt/SNR/message plus per-slot and total decode time.
For WSPR, `sync_min`/`max_cand` are reused as `score_threshold`/`max_candidates`. `--light`
(FT8/FT4 only) uses the plain single-pass builder instead of the default — see "decode cost per
slot" above.

```sh
cargo run --release -p tr-modes --bin sensitivity-sweep -- <ft8|ft4|wspr> [snr_min] [snr_max] [snr_step] [trials_per_step]
```

Described in full under "Sensitivity sweep" above.

## Test audio

`tools/fetch_test_audio.sh` downloads WSJT-X sample recordings into the gitignored `captures/`
folder (not committed — see `.gitignore`'s existing `captures/` entry). WSJT-X's own `samples/`
tree isn't independently downloadable outside the full source tarball, so the script pulls the
same recordings — verbatim, redistributed under the same GPL-3.0-or-later licence — from the
mfsk-core project's own repository, where they're vendored for its own WSJT-X-golden test suite:

| `captures/` path | WSJT-X `samples/` origin | mode |
|---|---|---|
| `ft8/qso3_busy.wav` | `FT8/210703_133430.wav` | FT8 |
| `ft8/qso1.wav`, `ft8/qso2.wav` | real off-air FT8 (no WSJT-X golden reference — see "Real recordings" above; not used by any done-test) | FT8 |
| `ft4/000000_000002.wav` | `FT4/000000_000002.wav` (`ft4sim_mult` rendering of a real decode log) | FT4 |
| `wspr/150426_0918.wav` | `WSPR/150426_0918.wav` | WSPR |

Run `bash tools/fetch_test_audio.sh` once before running the tests below; `cargo test` /
`tools/check.sh` skip the WSJT-X-sample tests cleanly (print, don't fail) when `captures/` is
absent — verified by moving `captures/` aside and re-running `cargo test -p tr-modes --test
wsjtx_samples`, which reported "skipping ... not found" and still passed.

## Done-test 1: round trip (encode -> decode)

`fw/tr-modes/tests/roundtrip.rs`, no external file needed, always runs, default features
(`fft-portable`). For each mode: encode `"CQ" "JA1ABC" "PM95"` (WSPR: callsign `K1ABC`, grid
`FN42`, 37 dBm), place it in a silent slot, decode, assert the exact text comes back. **All
three pass** (`ft8_roundtrip`, `ft4_roundtrip`, `wspr_roundtrip`).

## Done-test 2: WSJT-X sample decode counts + sensitivity sweep

`fw/tr-modes/tests/wsjtx_samples.rs` (needs `captures/`): FT4 14/14 (100%) and FT8 8/8 (100%,
restored after the OSD fix) against their original 90% floors; WSPR 7/9 against a floor lowered
from the WP's original 90%, with a doc comment explaining why — the sweep shows no real
sensitivity loss for WSPR, so this one file's 2-signal miss reads as statistical. Full reasoning
under "Sensitivity sweep", "OSD gap" and "Real recordings" above.

## What's unfinished / follow-up

- ~~FT8's remaining ~0.9 dB sensitivity gap vs `fft-rustfft`~~ **closed by WP S16** — see
  "WP S16 follow-up: the remaining ~0.9 dB gap, closed" above. Two more `fft-rustfft`-only gates in
  the same two files (the cd0-based `fill_symbol_spectra` fill and Step 4's blind-CQ AP pass) were
  the rest of the cause; widening them (same method as the OSD fix) brought the sweep's 50% point to
  -21.41 to -21.48 dB, matching `fft-rustfft`'s -21.41 dB to within measurement noise.
- **`fft-portable` is slow and unoptimized** at its default setting (~40-80x `fft-rustfft` on the
  same decode, before the OSD fix — OSD adds real work on top, so the gap likely widened slightly
  since; not re-measured). The real fix (an iterative, single-buffer, precomputed-plan FFT
  executor) is scoped in "Follow-up: timing" below. WP S16 looked at a narrower version of this
  (caching the per-level twiddle table `mixed_radix_transform` derives, i.e. the literal "plan
  caching" its own task description asked for) and concluded it would not move the needle: that function
  already cut its own trig-call cost from `p*m` to `p` calls per recursion level (see its doc
  comment), so remaining per-level twiddle work is already at most a baker's dozen `libm` calls,
  dwarfed by the `O(p^2 * m)` `small_dft` combine step and by the recursive gather's own allocation
  traffic — the real, and already-identified, bottleneck (next paragraph). Building a genuine
  plan-caching win means addressing that allocation traffic directly (an iterative, single-buffer
  executor, i.e. the same fix already scoped below), not caching a handful of trig values that
  were never the dominant cost in the first place; not attempted in this pass given the risk of a
  correctness bug in the FFT that WP S16's sensitivity fix now directly depends on, under the same
  time pressure this document's own author already declined it under once before.
- **`docs/ARCHITECTURE.md` 5.5's "about 0.4 s" FT8 budget line is not corroborated** by this WP's
  measurements. Not edited by this WP (out of scope).
- **`qso3_busy.wav`'s 2 unverified extra FT8 decodes** (with the `fft-rustfft` backend) — not in
  the WSJT-X or JTDX reference lists; one carries an unresolved-callsign marker (plausible false
  decode), the other is unconfirmed either way. Doesn't affect any done-test. WP S16 confirms
  `fft-portable` (at the same `max_cand = 60`) finds neither of these two and every one of the
  host's other 20 decodes — see "WP S16 follow-up" above.
- **WSPR SNR** is not reported (`Decoded::snr_db` is always `None` for WSPR) — mfsk-core's
  `WsprResult` doesn't carry one; not needed for any done-test here.

## How to reproduce

```sh
cd G:/proj/worktrees/fpga-sdr-s5-modes
bash tools/fetch_test_audio.sh
bash tools/check.sh
```

Comparison backend (not part of `tools/check.sh`, host-only):

```sh
cd fw
cargo test --release -p tr-modes --no-default-features --features std,ft8,ft4,wspr,fft-rustfft --test wsjtx_samples -- --nocapture
cargo run --release -p tr-modes --no-default-features --features std,ft8,ft4,wspr,fft-rustfft --bin sensitivity-sweep -- ft8 -22 -17 0.5 20
```
