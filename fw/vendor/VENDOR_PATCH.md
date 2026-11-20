# Vendored patch: mfsk-core 0.11.0 no_std fixes, plus FT8 OSD and sensitivity-parity gates under
# `fft-extern`, per-candidate decode hooks, a bit-packed OSD, and faster LLRs and belief propagation

Source: `mfsk-core = "0.11"` (resolves to 0.11.0 on crates.io), GPL-3.0-or-later, by Naoki
Sakurai (jl1nie) and contributors, https://github.com/jl1nie/mfsk-core. Vendored under
`fw/vendor/mfsk-core/` (`src/`, `Cargo.toml`, `README.md`, `LICENSE` only — `tests/`/`examples/`
dropped, not needed to build the library). Wired in via `fw/Cargo.toml`'s `[patch.crates-io]`, so
it applies to the whole `fw/` workspace, not just `tr-modes`.

## Why

Building `tr-modes` for `riscv32imafc-unknown-none-elf` with WSPR decode enabled
(`--features ft8,ft4,wspr,fft-portable`, i.e. `no_std` + an FFT backend) failed with six compile
errors, all inside mfsk-core's own `wspr` module, none in `tr-modes`'s code. FT8 and FT4 decode
already built `no_std` cleanly — this was specific to WSPR. Each of the three files fixed here
already builds fine `no_std` when no FFT backend is enabled (WSPR's *encode*/TX path, which
`tr-modes` used from day one of WP S5) — the breakage only appears once an FFT backend
(`fft-rustfft` or `fft-extern`) turns on WSPR's *decode* modules, which apparently were only ever
built and tested with `std` implicitly available.

## The three fixes

1. **`src/wspr/osd.rs`, `gen_matrix()`** — was cached behind `static GEN: std::sync::OnceLock<...>`
   (`use std::sync::OnceLock;`, unconditional, no `no_std` fallback). Changed to recompute the
   (small, pure, deterministic — 50 convolutional-code encodes) generator matrix on every call
   instead of caching it, and to return it by value (`[[u8; N]; K]`) rather than
   `&'static [[u8; N]; K]`. Both call sites only ever index into the result, so this needed no
   caller changes. Correctness is unaffected; the only cost is repeating a cheap computation
   instead of caching it — negligible next to everything else `osd_decode` does.
2. **`src/wspr/decode.rs`** — `Vec<(String, Option<String>)>` (~line 114) used `String` without
   importing it; `std`'s prelude brings that in for free, `alloc`'s doesn't. Added
   `use alloc::string::String;`.
3. **`src/wspr/decode.rs`** (~line 1371) and **`src/wspr/baseband.rs`** (~line 66) — both call
   `.round()` on a bare `f32`, which is an inherent method under `std` but needs a `Float` trait
   (from `num_traits`, already a dependency) in scope under `no_std`. Added
   `#[allow(unused_imports)] use num_traits::Float;` (the `allow` because the import is genuinely
   unused, and correctly so, on a `std` build — the inherent method still wins there — this project
   builds and tests both configurations, so a warning-as-noise on one of them wasn't left in).

Total diff: three added `use` lines, one function's caching strategy removed, one return-type
change (reference to owned value) that needed no caller updates. Applied directly in the vendored
copy; a matching pull request to https://github.com/jl1nie/mfsk-core would be the same three
changes verbatim.

## Fix 4: FT8's OSD step, gated to `fft-rustfft` for no technical reason

Found investigating `docs/S5_MODES.md`'s sensitivity-sweep gap (this backend measurably less
sensitive than `fft-rustfft` on FT8 specifically, ~1.7 dB). `src/ft8/decode_block/osd_strategy.rs`
— FT8's ordered-statistics-decoding fallback, the deep-search step that runs after LDPC/BP fails
on a candidate — was `#![cfg(feature = "fft-rustfft")]` at the whole-file level, with the matching
dispatch call in `src/ft8/decode_block/process_candidates.rs` gated the same way. Its own doc
comment said why: `DecodeDepth::osd` is a deliberate no-op on mfsk-core's own ESP32-S3 embedded
ship config (a power/latency budget choice for that specific battery-powered target), and the
whole module was compiled out of any non-`fft-rustfft` build on the assumption that "not
`fft-rustfft`" means "that embedded target" — which was true when this crate had only one `no_std`
backend (`fft-extern`, provided by whichever chip's port needed it) and no reason to ship OSD
there. It stopped being a safe assumption once a second `fft-extern` consumer (this one) exists
that is not power/latency-constrained the way ESP32-S3 is and wants OSD.

Checked before patching: everything `osd_strategy.rs` actually calls
(`crate::fec::ldpc::osd::{osd_decode_npre1, osd_decode_npre1_npre2}`,
`crate::fec::ldpc::bp::bp_llr_zsum_with_scratch`) is already plain `alloc`-only Rust — sorting and
small matrix operations (Gaussian elimination over a bit matrix), no FFT, no `std`-only API,
already compiled unconditionally today into every build (`fec/ldpc/osd.rs` itself carries no
feature gate at all). Confirmed by grep for `std::`/`rustfft` inside `osd_strategy.rs`: none. So
the `fft-rustfft`-only gate was blocking something already `no_std`-clean, not protecting against
something that wasn't.

**The fix**: widened three gates from `feature = "fft-rustfft"` to
`any(feature = "fft-rustfft", feature = "fft-extern")` — `osd_strategy.rs`'s whole-file
`#![cfg(...)]`, and the two matching gates around its call site and its `prefetched_llr`
optimization in `process_candidates.rs`. FT4/FST4's own OSD path
(`engine::pipeline::osd_escalation_gates`) was never gated this way (confirmed by grep — no
`fft-rustfft`-only gate anywhere near it), which is exactly why the sensitivity sweep found a real
gap on FT8 specifically and none on FT4.

**Result**: `qso3_busy.wav`'s FT8 recall against the 8 WSJT-X reference decodes went from 7/8 to
8/8 (recovered `K1BZM DK8NE -10`). The sensitivity sweep's FT8 50%-detection point moved from
-19.73 dB to -20.49 dB against `fft-rustfft`'s -21.41 dB — most of the ~1.7 dB gap closed, not all
of it (~0.9 dB remains). `docs/S5_MODES.md` "OSD gap" has the full before/after sweep tables and
what's still open. There are further `#[cfg(feature = "fft-rustfft")]` gates elsewhere in
`process_candidates.rs` and `fill_symbol_spectra.rs` (extra BP LLR variants, AP-hint handling) that
were not touched in this pass — plausible contributors to the remaining ~0.9 dB, flagged as
follow-up rather than patched here given the larger surface and correspondingly higher risk of a
change under time pressure.

## What was verified after patching

- `cargo build -p tr-modes` (host, default features) — unaffected, same behaviour except OSD now
  running under `fft-extern` too (fixes 1-3), and FT8 recall improved (fix 4).
- `cargo test --release -p tr-modes` — all pass: `tests/wsjtx_samples.rs`'s FT8 test is back at its
  original 8/8 floor; WSPR's recall numbers are unchanged (its OSD path was never gated this way).
- `cargo build --target riscv32imafc-unknown-none-elf -p tr-modes --no-default-features --features ft8,ft4,wspr,fft-portable`
  — succeeds (fixes 1-3 close the WSPR gap; fix 4 needed no build-side changes, only a compile-time
  gate, and was already exercised by this same command).

## Fix 5 (fpga-sdr WP S16): the rest of the ~0.9 dB FT8 gap

Fix 4 above left docs/S5_MODES.md's own "What was investigated" section pointing at "further
`#[cfg(feature = "fft-rustfft")]` gates elsewhere in `process_candidates.rs` and
`fill_symbol_spectra.rs`" as the likely remaining cause. WP S16 checked those, using the same
method Fix 4 established (grep for the gate, confirm what it actually depends on technically,
widen it if nothing requires `fft-rustfft` specifically, re-measure with the sensitivity sweep).
Two gates, both real contributors:

1. **`ft8/decode_block/fill_symbol_spectra.rs`: `fill_symbol_spectra_via_cd0` and its dispatcher.**
   This is the WSJT-X-faithful per-candidate tone-spectra fill (downsample chain + tapered
   low-pass + per-symbol 32-point FFT, `ft8b.f90:154-161`) — out-of-band signals are suppressed by
   the downsample's edge-tapered filter here, instead of leaking into per-tone DFT sidelobes the
   way they do in the rectangular-window fallback (`fill_symbol_spectra_generic`) every
   `fft-extern` build fell back to before this fix. Checked before widening: the 192k-point
   downsample chain this builds on (`crate::engine::dsp::downsample`) was *already*
   `any(fft-rustfft, fft-extern)`-gated, not `fft-rustfft`-only — this function's own two
   rustfft-specific details (a 32-point `rustfft::Fft` plan cached in a `std::sync::OnceLock`, and
   a `std`-only `thread_local!` scratch buffer for a `fft_cache = None` code path this crate's own
   two callers — `ft8::decode::triage_candidate`, `ft8::decode::run_candidate_ladder` — never
   actually reach, since both always pass an already-built cache) were the only things standing in
   the way. Widened the two dispatcher functions and `fill_symbol_spectra_via_cd0` itself from
   `feature = "fft-rustfft"` to `any(feature = "fft-rustfft", feature = "fft-extern")`, and added an
   `fft-extern`-only arm for the 32-point FFT using this crate's own generic
   `mfsk_core::engine::fft::Fft` trait (the same `fft-extern` hook `tr-modes::fft` implements)
   instead of `rustfft` directly — no caching needed for that arm specifically, because a
   `fft-extern` backend's `Fft`/`FftPlanner` impl is not guaranteed to precompute anything at
   `plan_forward` time the way `rustfft` does (and `tr-modes`'s own `MixedRadixFft` doesn't:
   everything happens inside `process()`, so a fresh plan per call costs nothing beyond
   constructing a two-field struct) — and a plain `alloc::vec::Vec` for the (practically
   unreachable) no-cache scratch arm.
2. **`ft8/decode_block/process_candidates.rs`: Step 4 of `process_one_candidate_inner`** (the AP
   iaptype loop), plus its `osd_decode_deep` import and `BLIND_CQ_MIN_NSYNC` constant. Specifically
   pass 12 (blind-CQ, `ApHint::new().with_call1("CQ")`, WSJT-X iaptype 1) matters here: it runs
   regardless of whether the caller supplied any AP hint at all, and this function's own comment
   documents it (issue #190) as recovering real decodes a blind BP/OSD staircase alone misses —
   mfsk-core's own upstream measured the FT4 analog of this pass worth 1.1 dB of AWGN sensitivity.
   Entirely `fft-rustfft`-gated before this fix. Checked before widening: everything Step 4 calls
   (`ApHint` — plain `alloc`-only, no gate of its own in `msg/ap.rs` — `osd_decode_deep`,
   `bp_decode`, `CallsignHashTable`) is exactly the same kind of `alloc`-only code Step 3's OSD
   dispatch (Fix 4, above) already runs under `fft-extern` — nothing rustfft- or `std`-specific.
   `BLIND_CQ_MIN_NSYNC = 12` already bounds Step 4's cost (188 -> 34 Step-4 candidates measured on
   `qso3_busy.wav` by mfsk-core's own authors, zero recall change), so widening it doesn't reopen
   the OSD-cost question the CPU budget already accounts for — same OSD call, one more (bounded)
   entry point.

Neither change touches FFT correctness math: (1) swaps one rustfft-specific call for the
equivalent generic-trait call already used everywhere else in this crate, and (2) is a pure
cfg-gate widening of already-existing, already-tested decode logic.

**Result — sensitivity sweep** (`decode_slot_light`, i.e. `DecodeRequest::new()` /
`DecodeDepth::FULL`, same synthetic-AWGN method): 50% point moved -20.49 dB (Fix 4's own result,
reproduced this pass) -> **-20.98 dB** after widening (1) alone -> **-21.41 to -21.48 dB** (two
independent runs) after widening (2) on top — against the `fft-rustfft` reference's **-21.41 dB**.
Gap: 0.92 dB -> 0.43 dB -> **~0.0 dB, within the ±0.3 dB tolerance**. Full before/after tables:
`docs/S5_MODES.md` "WP S16 follow-up: the remaining ~0.9 dB gap, closed".

**Result — decode-count parity, `qso3_busy.wav`, `max_cand = 60`, OSD on both sides**:
`fft-portable` 20 decodes vs `fft-rustfft` 22, and the target's 20 are an exact subset of the
host's 22 — the two the target misses are the same two decodes `docs/S5_MODES.md`'s own "What's
unfinished" section already flagged as *not* WSJT-X/JTDX-reference-verified (one has an
unresolved-callsign marker, the other is unconfirmed either way). On every decode either build can
verify against WSJT-X's own reference list, the two builds now agree exactly.

**What was verified**: `cargo test --release -p tr-modes` (FT8 8/8, FT4 14/14, WSPR 7/9, all
unchanged) and `cargo build --target riscv32imafc-unknown-none-elf -p tr-modes
--no-default-features --features ft8,ft4,wspr,fft-portable` (succeeds) after each of the two
widenings individually and combined.

## Fix 6 (fpga-sdr PLAN FO1): per-candidate entry, OSD effort, a-priori switch

The three hooks `docs/S15_FT8MODEL.md` section 2 asked for, so the decode scheduler (PLAN S17)
can spend a CPU budget per candidate. New file `src/ft8/decode_block/effort.rs`, re-exported
from `mfsk_core::ft8::decode_block`:

1. **`decode_soft_symbols(cs, cand, effort, known, ap_hint, scratch) -> CandidateReport`**: a
   documented entry that decodes one candidate's 79 x 8 soft symbols and reports the outcome
   (`CandidateOutcome::{Decoded, Duplicate, Implausible, Failed, BelowSync}`), the rung that
   produced the codeword (`Rung::{Bp, Osd, Ap}` with LLR variant, seed, a-priori pass) and the
   work done (`CandidateWork`: belief-propagation runs, OSD searches, npre2 searches,
   a-priori BP runs and OSD searches, and clock ticks per ladder step when
   `Ft8CandidateScratch::clock` is set, e.g. to `minstret`).
2. **`Ft8Effort`**: `bp` (run Steps 1-2 or skip them when the caller already saw them fail),
   `llr_effort`, `bp_max_iter`, `osd_variants` (mask of LLR variants a-d), `osd_seeds` (mask of
   the one- and two-iteration BP-refined seeds), `osd_npre2` (allow ndeep 3 for nsync >= 18).
   Today's ladder, eight OSD searches per failed candidate, is `Ft8Effort::FULL`.
3. **`Ft8Effort`'s a-priori fields**: `ap_blind_cq` (push the blind-CQ pass, WSJT-X iaptype 1),
   `ap_blind_cq_q_min` (the nsync gate, 12), `ap_bp` and `ap_osd` (which rungs the a-priori
   passes run), `ap_variants`.

How it is wired, so re-applying is mechanical:

- `process_candidates.rs`: the body of `process_one_candidate_inner` moved into the new
  `process_one_candidate_effort` (same code, with `depth`/`bp_max_iter` read from an
  `Ft8Effort`, the pass id replaced by a `Rung`, counters and clock samples added, and the
  outcome returned as a `CandidateOutcome`). `process_one_candidate_inner` keeps its signature
  and calls it with `Ft8Effort::from_depth(depth, bp_max_iter)`, which is the old ladder
  exactly, so every existing entry point is unchanged. One saving that changes no result: the
  a-priori LLR set is computed only when an a-priori pass will actually run (it used to be
  computed for every failed candidate, also when the pass list was empty). `LlrT` became
  `pub(super)`.
- `osd_strategy.rs`: `try_fallback` takes the `Ft8Effort` (variants, seeds, npre2) and the
  work counter, and returns a `Rung`; the search order is unchanged (variant-outer, seed-inner).
- `decode_block.rs`: `mod effort;` and the re-exports.

Verified (fpga-sdr `fw/tr-modes/tests/fo1_effort.rs`): on the three WSJT-X sample recordings,
30 and 60 candidates, one and two passes, `DecodeDepth::FULL` and `BP_ONLY`, the per-candidate
entry gives exactly the decodes (message, frequency, time, pass id, hard errors) of mfsk-core's
own multi-candidate entry; the knobs give the counted work (eight searches per failed candidate
under `FULL`, at most one with one variant and one seed, none with OSD off, no a-priori work
with the blind-CQ pass off).

## Fix 7 (fpga-sdr PLAN FO1): bit-packed OSD kernels with a linear CRC syndrome

New file `src/fec/ldpc/osd_fast.rs` (`pub mod osd_fast;` in `src/fec/ldpc/mod.rs`):
`osd_decode_npre1_fast`, `osd_decode_npre1_npre2_fast` and `osd_decode_deep2_crc_fast`, the
same searches as `osd_decode_npre1`, `osd_decode_npre1_npre2` and
`osd_decode_deep(llr, 2, Some(check_crc14))`, in the same order, with the same f32 sums in the
same order, so the results are identical. Two changes of representation:

- the permuted generator stays packed (six 32-bit words per row) instead of being unpacked to
  one byte per bit, so row XORs and the npre1 gate's partial parity count are word operations;
- the syndrome test (below) comes before the weighted distance; both must pass for a pattern to
  be kept, so the order changes nothing but the work;
- `check_crc14` is linear over GF(2) in the 91 information bits, so each generator row carries
  its 14-bit CRC syndrome through the elimination and a test pattern is checked with two XORs;
  the codeword is only built when the syndrome is zero.

The ladder uses them when `Ft8Effort::osd_packed` is true (the default, also in
`from_depth`); `false` runs the reference kernels (for measurements). Verified: fpga-sdr
`fw/tr-modes/tests/fo1_osd_fast.rs` (1,600 LLR vectors: channel LLRs, the ladder's one- and
two-iteration BP-refined seeds, quantised copies with ties; both outcomes well represented; all
three searches identical), and `fo1_effort.rs` (every recording and setting above decodes
identically with packed and reference kernels). Cost on the AE350 (QEMU, `tools/qemu_s15.sh`):
one npre1 search 0.44 M instructions instead of 6.1 M, one npre1 + npre2 search 1.9 M instead
of 16-260 M, one a-priori order-2 search 0.32 M instead of 19.5 M (`tools/qemu_fo1_kernels.sh`);
the full ladder on the busy sample slot at 60 candidates 195 M instructions per slot instead of
746 M (`docs/FT8_OFFLOAD.md` in the fpga-sdr repository has the tables).

## Fix 8 (fpga-sdr PLAN FO3): faster LLRs and belief propagation

Two kernels rewritten with identical results, and one deliberate change of algorithm in the
a-priori passes.

1. **LLRs** (`src/engine/llr.rs`, `fill_bmet_for_nsym`): the bit metrics are maxima of tone-group
   magnitudes. Now `s2` holds squared magnitudes and the square root is taken of the two maxima per
   bit only (a correctly rounded square root is monotone, so the largest root is the root of the
   largest square; on `no_std` each root was a libm call, 512 per 3-symbol group); the top-level
   combine writes straight into `s2` (new `group_power`); and the per-bit maxima come from a
   pairwise reduction (after `b` halvings entry `i` is the maximum of the original block `i` of
   size `2^b`, so even entries are the bit-`b` = 0 half and odd ones the bit-`b` = 1 half: `nt`
   element visits in all instead of `nt` per bit). The old function stays as
   `fill_bmet_for_nsym_ref` behind the `#[doc(hidden)]` `engine::llr::compute_llr_reference` and
   `ft8::llr::compute_llr_reference`, for the equivalence tests only.
2. **Normalised min-sum belief propagation** (new `src/fec/ldpc/bp_fast.rs`,
   `bp_decode_nms_fast[_with_scratch]`, generic over `LdpcParams` and `LlrScalar`, f32 and Q11):
   `BpScratch` gains two edge tables built once in `new()` (`edge_var`, `edge_tov`: per check-row
   slot, the variable and the index of that edge's message in `tov`), and one pass over the rows
   per iteration does parity, variable-to-check messages, the two minima and the new
   check-to-variable messages of the same row (each `tov` entry belongs to one edge, so the
   flooding schedule is unchanged). The same float operations in the same order as
   `bp_decode_generic_nms_with_scratch`; result, codeword, hard errors and iteration count are
   identical. `bp_step_select` (both variants) uses it.
3. **A-priori passes' belief propagation** (`process_one_candidate_effort`, Step 4): new
   `Ft8Effort::ap_min_sum`. `true` runs the a-priori passes' belief propagation with the fused
   min-sum kernel (with the a-priori mask) instead of `bp_decode` (WSJT-X's sum-product, tanh and
   atanh per edge). `Ft8Effort::from_depth` keeps `false` (every pre-existing entry point is the
   old ladder exactly); `Ft8Effort::FULL` and `BP_ONLY` set it (`with_ap_min_sum`). This one
   changes results in principle; measured: identical 50 % points in both sensitivity sweeps and the
   same messages on the three recordings (fpga-sdr `docs/FT8_CPU.md`).
4. **LLR sets built for what reads them** (`llr_need`, `llr_set_for` in `process_candidates.rs`):
   the f32 set for OSD and the a-priori passes reuses Steps 1-2's arrays and computes a missing
   variant only if OSD's `osd_variants` or the passes' `ap_variants` include it (before, a
   candidate that skipped Steps 1-2, or ran with `LlrEffort::Minimal`, or reached the a-priori
   passes without OSD, recomputed all four). Values are identical (each variant is normalised on
   its own). Not under `fixed-point`, which keeps its recompute.

Verified (fpga-sdr): `fw/tr-modes/tests/fo3_kernels.rs` (all four LLR variants bit for bit on
300 soft-symbol sets, including integer ones with ties; the fused min-sum equals the reference on
600 LLR vectors in f32 and Q11, with and without an a-priori mask, both outcomes well
represented; the ladder decodes the same messages with min-sum and sum-product a-priori passes on
the three recordings at 30/60 candidates, one and two passes) and `fo1_effort.rs` (unchanged:
per-candidate entry equals mfsk-core's own multi-candidate entry). On the AE350 (QEMU,
`tools/qemu_fo1_kernels.sh`): LLR set 2.32 M instructions to 0.68 M, one min-sum run 2.22 M to
0.99 M (Q11: 2.76 M to 1.41 M).

## Ninth change (2026-10-21): a cooperative yield point

`src/yield_hook.rs` (new) and calls to `crate::yield_hook::call()` at the top of each time step of
`ft8/decode_block/spectrogram.rs` (two functions) and at the start of `triage_candidate` in `ft8/decode.rs`.
Nothing happens unless the firmware registers a function with `yield_hook::scope` around a decode; it then serves the
network and the operator's input between steps (fpga-sdr docs/NETINPUT.md). Results are unchanged. Not interruptible:
the 192,000-point FFT of `build_fft_cache`, one candidate's belief propagation and OSD.

## Re-applying against a future mfsk-core release

If `tr-modes`'s `mfsk-core = "0.11"` pin is ever bumped, re-vendor from the new version's source
(`~/.cargo/registry/src/*/mfsk-core-<version>/`) and re-apply the eight fixes above and the ninth change by hand (fixes 6, 7 and 8 add three files and touch
`process_candidates.rs`, `osd_strategy.rs`, `decode_block.rs`, `effort.rs`, `engine/llr.rs`, `ft8/llr.rs`,
`fec/ldpc/bp.rs` and `fec/ldpc/mod.rs`) —
they're small enough that a mechanical diff/patch file wasn't worth maintaining separately from
this document.
