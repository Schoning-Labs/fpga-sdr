<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# WP S2: CPU benchmark harness — measured instruction counts

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

docs/PLAN.md WP S2. Replaces the flop-based estimates in `docs/ARCHITECTURE.md` section 5.5 with
instruction counts measured under QEMU, for every `tr-dsp` kernel named in the work package
(filter, AGC, each demodulator, noise blanker, noise reduction, resampler, at each of the
receiver bank's four output rates where that applies). FT8 decode (`tr-modes`, WP S5) and Slint
1,920x1,080 software rendering (`tr-gui`, WP S11) are stubs: both branches (`s5-modes`,
`s11-gui`) are still separate from `master` as of this WP, so this harness reports them as "not
measured" rather than guessing at their unmerged API. Cycle counts on the real board follow in
PLAN WP B8.

**Update (cpu-budget work):** the numbers below are the measurement at the start of that work. After its
software changes every kernel needs 2.2-3.5 times fewer instructions, the harness has two more kernels
(noise reduction and AGC at 12 ksps, 19 results in total), and the budget was recomputed for a new
FPGA/firmware split: see `docs/CPU_BUDGET.md` sections 4 and 6.

**Headline finding: the measured cost is 2-4x the flop-based estimate, in cycle-equivalent
terms, for every DSP kernel measured.** Recomputing `docs/ARCHITECTURE.md` section 5.5's own
"typical full load" scenario with these numbers lands at 55-66% of the 800 MHz core, not the
37% originally estimated — essentially the same cost the architecture doc's own "may not fit"
scenario predicted for it. And that "may not fit" scenario itself (noise reduction + full
demodulation on all 8 receivers, FT8 on all 8, full-rate streaming) recomputes to **136-182% of
the core** — it does not fit, at either end of the assumed IPC range, not just "may". See
[section 5](#5-scenario-recomputed) below.

## 1. How to run

Prerequisites: `docs/TOOLCHAIN.md` WP T4 (Rust with the `riscv32imafc-unknown-none-elf` target;
QEMU for RISC-V via `scoop install qemu`).

```sh
# Quick check (what tools/check.sh runs): build, run once under QEMU, confirm every kernel
# reported a result (or an explicit stub note), no table. A few seconds.
bash tools/qemu_s2.sh --smoke

# The real thing: build, run, print the instructions/s and %-of-core table as Markdown.
bash tools/qemu_s2.sh
```

Both build `fw/tr-bench`'s `dsp_bench` binary in **release** mode for
`riscv32imafc-unknown-none-elf` (`--no-default-features --features board-qemu`, the same pattern
`tools/qemu_c1.sh` uses for WP C1's `qemu_smoke` binary — see `fw/tr-ae350/src/board.rs`), then
run it under `qemu-system-riscv32 -M virt -icount shift=0`. The binary itself
(`fw/tr-bench/src/bin/dsp_bench.rs`) enables the FPU, runs every kernel
(`fw/tr-bench/src/lib.rs::run_all`, board-agnostic — everything kernel-specific lives there, not
in the QEMU entry point), and prints one `RESULT ...` line per kernel over UART before shutting
QEMU down; `tools/qemu_s2.sh`'s `awk` step turns those lines into the table below.

`tools/check.sh` runs `tools/qemu_s2.sh --smoke` (not the full run) as its WP S2 check — the
benchmark itself does not need to run inside `check.sh` (PLAN.md WP S2's own done-test is "a
table... replacing the estimates", not a CI gate), but a quick pass/fail run under QEMU is cheap
enough (a few seconds) to be worth catching a build or crash regression early.

## 2. Measurement method and its limits

**What is measured**: the `minstret`/`minstreth` composite CSR (`riscv::register::minstret::
read64()`), i.e. instructions retired — a count of actual RV32IMAFC instructions executed,
directly comparable to what the real AE350 core would execute for the same code (same ISA, same
compiled binary in principle). This is **not** a cycle count: it says nothing about pipeline
stalls, cache misses, or branch mispredicts, none of which QEMU's TCG (a functional, not
timing, emulator) models at all.

**Why `-icount shift=0`, not a TCG plugin**: WP S2's task description asks for the QEMU plugin `libinsn` if
available in this PC's scoop QEMU build, else `-icount` with a CSR read. Checked for this WP:
this build (`qemu-system-riscv32 --version` reports `11.1.0 (v11.1.0-12130-ge470268ff4)`, scoop
package `qemu` 11.1.0) supports the `-plugin` flag (QEMU itself was built with TCG plugin
support), but **ships no prebuilt plugin library** — `contrib/plugins` (where `libinsn.so`/`.dll`
would come from) is source-only in upstream QEMU and this Windows binary distribution does not
build or bundle it (confirmed: no `.dll` anywhere under the scoop package matching `insn`,
`plugin`, `hotblocks`, etc., besides the unrelated GTK/GDK-pixbuf plugin loader). So this WP uses
the fallback: `-icount shift=0` forces QEMU into deterministic instruction-counted mode (each
guest instruction advances the emulated clock by exactly `2^shift = 1` "cycle"), which makes
`minstret` (and `mcycle`, since they move in lock-step under `shift=0`) advance by exactly one
per instruction retired, instead of QEMU's default behavior of deriving those CSRs from a
free-running, wall-clock-scaled approximation that has nothing to do with actual guest
instruction count.

**Limits of this method, specifically**:

- **`mcycle` under `-icount` is not a timing model.** `shift=0` credits exactly one QEMU "cycle"
  per instruction by construction, so `mcycle`'s delta always equals `minstret`'s delta here —
  it carries zero additional information about real hardware timing. This is why `tr-bench` reads
  `minstret` only; a real cycle estimate is built afterward from an assumed IPC (section 3), not
  read from `mcycle`.
- **No cache/pipeline model at all.** The real AE350 core (A25, RV32IMAFC, 32 KB + 32 KB L1
  caches per `docs/ARCHITECTURE.md` section 5.1) will stall on cache misses, branch
  mispredicts, and FPU/load-use hazards that QEMU TCG cannot produce, since it does not model
  them. The 0.7-1.0 IPC range this doc applies (section 3) is how that gap is bridged — a
  measured, not assumed, real-hardware IPC is PLAN WP B8's job once the board exists.
- **Determinism confirmed, not assumed**: `tools/qemu_s2.sh` was run twice for this WP; every
  `instr_total` was bit-for-bit identical both times (`-icount shift=0` is deterministic by
  design — no host-timing jitter reaches the guest's instruction stream).
  - **Reproduce**: `bash tools/qemu_s2.sh` twice, `diff` the `RESULT` lines.
- **Retired-instruction count is a legitimate real-hardware proxy, with one caveat.** Every
  kernel here is straight-line/loop arithmetic (FFT butterflies, FIR taps, AGC/NR per-sample
  updates) with no syscalls, no memory-mapped I/O, and no undefined behavior that would make
  QEMU's translation diverge from what real silicon executes for the same RV32IMAFC encoding —
  so the instruction *count* itself should transfer to the real AE350 essentially unchanged
  (modulo compiler codegen differences between the `riscv32imafc-unknown-none-elf` target used
  here and whatever eventually runs on the board, which is the same target). What does **not**
  transfer is how long each instruction takes, which is exactly what section 3's IPC range is
  for.
- **If a future QEMU build on this PC does ship `libinsn`** (rebuilding QEMU from source with
  `--enable-plugins`, or a different package manager's build): it would measure the same
  quantity (instructions executed) by a different mechanism (a TCG callback per translated
  instruction, not a CSR read) and should reproduce these numbers; it was not available for this
  WP, so this was not cross-checked.

## 3. From instructions to cycles: the IPC assumption

Neither this WP nor `docs/ARCHITECTURE.md` section 5.5 (before this WP) has a measured
instructions-per-cycle number for the Andes A25 (that is PLAN WP B8, on the real board). WP S2's
task description states the range to use: **0.7-1.0 IPC**, "same class" framing `docs/ARCHITECTURE.md`
section 5.5 already uses for the A25 (3.22 CoreMark/MHz, comparable to a 480 MHz Cortex-M7 — an
in-order or shallow-pipeline core, where less than 1 instruction/cycle on FPU- and load/store-
heavy DSP code like this is the expected range, not the exception). Every table below reports
**both** bounds:

- **IPC 0.7** (conservative: more cycles for the same instruction count) — call this the
  "worst-case" column.
- **IPC 1.0** (optimistic: one instruction per cycle, no stalls at all) — the "best-case" column,
  a ceiling this design will not beat, not a number expected on real hardware.

`cycles/s = instructions/s / IPC`; `% of core = cycles/s / 800,000,000 * 100`.

## 4. Measured kernel table

One block = 512 samples (`fastconv::BLOCK`, the fixed FFT/overlap-save block size
`docs/ARCHITECTURE.md` section 5.5 and `docs/S3_DSP.md` both already design to). Filter, AGC, and
every demodulator run at 48 kHz — the fixed post-resampling design rate (`docs/S3_DSP.md` section
1's pipeline order: resample down to 48 kHz happens *before* the channel filter/demod). Noise
blanker and resampler run at each of the receiver bank's four native output rates
(48/96/192/384 ksps), since both operate on the wideband IQ stream before decimation.

| Kernel | Rate | Instr/unit | Instructions/s of audio | Mcycles/s @ IPC 0.7 | Mcycles/s @ IPC 1.0 | % of 800 MHz core @ IPC 0.7 | @ IPC 1.0 |
|---|---|---|---|---|---|---|---|
| Channel filter (bandpass, 1,024-pt FFT, USB-shaped 300-2,700 Hz) | 48,000 Hz | 416,162/block | 39,015,141 | 55.74 | 39.02 | 6.97% | 4.88% |
| AGC alone | 48,000 Hz | 18,493/block | 1,733,742 | 2.48 | 1.73 | 0.31% | 0.22% |
| SSB (USB) demod (filter + `Re{}` + AGC) | 48,000 Hz | 439,697/block | 41,221,559 | 58.89 | 41.22 | 7.36% | 5.15% |
| CW demod | 48,000 Hz | 437,880/block | 41,051,203 | 58.64 | 41.05 | 7.33% | 5.13% |
| AM envelope demod | 48,000 Hz | 473,153/block | 44,358,059 | 63.37 | 44.36 | 7.92% | 5.54% |
| AM synchronous demod | 48,000 Hz | 483,514/block | 45,329,391 | 64.76 | 45.33 | 8.09% | 5.67% |
| FM demod (discriminator + de-emphasis + squelch) | 48,000 Hz | 511,846/block | 47,985,609 | 68.55 | 47.99 | 8.57% | 6.00% |
| Noise reduction (one more FFT pair) | 48,000 Hz | 504,918/block | 47,336,109 | 67.62 | 47.34 | 8.45% | 5.92% |
| Noise blanker | 48,000 Hz | 43,718/block | 4,098,562 | 5.86 | 4.10 | 0.73% | 0.51% |
| Noise blanker | 96,000 Hz | 43,731/block | 8,199,516 | 11.71 | 8.20 | 1.46% | 1.02% |
| Noise blanker | 192,000 Hz | 43,757/block | 16,408,781 | 23.44 | 16.41 | 2.93% | 2.05% |
| Noise blanker | 384,000 Hz | 43,791/block | 32,843,250 | 46.92 | 32.84 | 5.86% | 4.11% |
| Resampler, decimate by 2 (96 -> 48 ksps) | 96,000 Hz | 191.0/input sample | 18,336,410 | 26.19 | 18.34 | 3.27% | 2.29% |
| Resampler, decimate by 4 (192 -> 48 ksps) | 192,000 Hz | 183.5/input sample | 35,232,820 | 50.33 | 35.23 | 6.29% | 4.40% |
| Resampler, decimate by 8 (384 -> 48 ksps) | 384,000 Hz | 179.8/input sample | 69,025,641 | 98.61 | 69.03 | 12.33% | 8.63% |
| FT8/FT4 decode (mfsk-core) | — | — | **not measured**: `s5-modes` (WP S5) not yet on `master`. Enable Cargo feature `bench-ft8` on `tr-bench` and wire the call in `fw/tr-bench/src/lib.rs::bench_ft8` once it lands (that function already has the exact steps in a `compile_error!` if the feature is turned on without doing so). | — | — | — | — |
| Slint full 1,920x1,080 software redraw | — | — | **not measured**: `s11-gui` (WP S11) not yet on `master`. Same pattern, `bench-gui` feature, `fw/tr-bench/src/lib.rs::bench_gui`. | — | — | — | — |

Raw data (what `tools/qemu_s2.sh` parses; reproduce with `bash tools/qemu_s2.sh --smoke` and read
the QEMU transcript it prints to stderr, or drop `--smoke`):

```
RESULT filter_48k measured=1 rate_hz=48000 unit=blocks divisor=8 instr_total=3329292 note=-
RESULT agc_48k measured=1 rate_hz=48000 unit=blocks divisor=8 instr_total=147946 note=-
RESULT demod_ssb_usb_48k measured=1 rate_hz=48000 unit=blocks divisor=8 instr_total=3517573 note=-
RESULT demod_cw_48k measured=1 rate_hz=48000 unit=blocks divisor=8 instr_total=3503036 note=-
RESULT demod_am_env_48k measured=1 rate_hz=48000 unit=blocks divisor=8 instr_total=3785221 note=-
RESULT demod_am_sync_48k measured=1 rate_hz=48000 unit=blocks divisor=8 instr_total=3868108 note=-
RESULT demod_fm_48k measured=1 rate_hz=48000 unit=blocks divisor=8 instr_total=4094772 note=-
RESULT nr_48k measured=1 rate_hz=48000 unit=blocks divisor=8 instr_total=4039348 note=-
RESULT nb_48k measured=1 rate_hz=48000 unit=blocks divisor=8 instr_total=349744 note=-
RESULT nb_96k measured=1 rate_hz=96000 unit=blocks divisor=8 instr_total=349846 note=-
RESULT nb_192k measured=1 rate_hz=192000 unit=blocks divisor=8 instr_total=350054 note=-
RESULT nb_384k measured=1 rate_hz=384000 unit=blocks divisor=8 instr_total=350328 note=-
RESULT resamp_m2_96k measured=1 rate_hz=96000 unit=samples divisor=32768 instr_total=6258828 note=-
RESULT resamp_m4_192k measured=1 rate_hz=192000 unit=samples divisor=32768 instr_total=6013068 note=-
RESULT resamp_m8_384k measured=1 rate_hz=384000 unit=samples divisor=32768 instr_total=5890188 note=-
RESULT ft8_decode measured=0 rate_hz=0 unit=blocks divisor=0 instr_total=0 note=s5-modes not yet on master (docs/PLAN.md WP S5); enable feature bench-ft8 once it lands
RESULT gui_full_redraw_1920x1080 measured=0 rate_hz=0 unit=blocks divisor=0 instr_total=0 note=s11-gui not yet on master (docs/PLAN.md WP S11); enable feature bench-gui once it lands
```

**Sanity check against `docs/S3_DSP.md`'s flop counts**: the channel filter's own flop-based
figure is 212 flops/sample (`docs/S3_DSP.md` section 3.1); the measured instruction count here is
416,162 instructions/block / 512 samples/block = 813 instructions/sample — about **3.8x** the
flop count. That ratio (roughly 3-6x across every kernel in the table) is expected, not a bug:
"flops" counts arithmetic operations only, while a real instruction stream also has to load each
operand, store each result, compute FFT/ring-buffer addresses, and execute loop-control branches
— none of which are flops but all of which are real instructions the core has to retire. This is
the mechanical reason the recomputed cycle estimates in section 5 come out higher than
`docs/ARCHITECTURE.md` section 5.5's original "1.5 cycles per f32 operation" heuristic: that
heuristic was scaling the flop count directly, not an instruction count.

## 5. Scenario, recomputed

`docs/ARCHITECTURE.md` section 5.5 defines two scenarios. Recomputed here with the measured
numbers above wherever a matching kernel exists; three line items in the original scenario have
no matching WP S2 kernel (they were not in this WP's kernel list) and are **carried over
unchanged** from the architecture doc's own flop-based estimate, clearly marked — this is not a
full recomputation of the whole CPU budget, only of the kernels WP S2 was asked to measure.

**One audible receiver, with noise reduction** (used as the per-receiver building block below):
assembled from three measured kernels at a 96 ksps native rate (matching
`docs/S3_DSP.md` section 3.10's own basis for "accurate for a 96 ksps receiver" — the
architecture doc's original ~15 Mflop/s per-receiver line already assumed a resampler was
running): SSB demod (58.89 / 41.22 Mcycles/s) + decimate-by-2 resampler (26.19 / 18.34) + noise
reduction (67.62 / 47.34) =

| | @ IPC 0.7 | @ IPC 1.0 |
|---|---|---|
| One audible receiver + NR (96 ksps native) | **152.70 Mcycles/s** | **106.90 Mcycles/s** |

against `docs/ARCHITECTURE.md`'s original 37 Mcycles/s for the same thing — **2.9x to 4.1x**
higher, measured.

**Typical full load** (`docs/ARCHITECTURE.md`'s own scenario: 2 audible receivers with NR, 6
decoder receivers, FT8 on all 8, GUI, streaming 4 receivers):

| Line item | @ IPC 0.7 | @ IPC 1.0 | Source |
|---|---|---|---|
| 2 audible receivers + NR | 305.40 | 213.80 | measured (above, x2) |
| 6 decoder receivers (mix/decimate to 12 kHz) | 12 | 12 | carried over — not a WP S2 kernel |
| FT8 on all 8 (average) | 170 | 170 | carried over — stub, WP S5 not landed |
| GUI (partial redraw) | 13 | 13 | carried over — stub, WP S11 not landed |
| Streaming 4 receivers (VITA-49/TCI) | 25 | 25 | carried over — not a WP S2 kernel |
| HL2 control, lease, network idle | <5 | <5 | carried over — not a WP S2 kernel |
| **Total** | **~530 Mcycles/s** | **~439 Mcycles/s** | |
| **% of 800 MHz core** | **~66%** | **~55%** | |

`docs/ARCHITECTURE.md` originally estimated this scenario at "about 300 Mcycles/s, 37%". The
recomputed range (439-530 Mcycles/s, 55-66%) is **not the same scenario the architecture doc
thought it was** — at the conservative IPC bound it numerically matches what the architecture doc
itself called the risky "may not fit" case (530 Mcycles/s, 66%), for what was meant to be the
comfortable, everyday scenario.

**"May not fit"** (`docs/ARCHITECTURE.md`'s own scenario: noise reduction + full demodulation on
all 8 receivers, FT8 on all 8, full-rate streaming on all 8):

| Line item | @ IPC 0.7 | @ IPC 1.0 | Source |
|---|---|---|---|
| 8 audible receivers + NR | 1,221.60 | 855.20 | measured (above, x8) |
| FT8 on all 8 | 170 | 170 | carried over — stub |
| Full-rate streaming, 8 receivers | 50 | 50 | carried over — not a WP S2 kernel |
| GUI | 13 | 13 | carried over — stub |
| **Total** | **~1,455 Mcycles/s** | **~1,088 Mcycles/s** | |
| **% of 800 MHz core** | **~182%** | **~136%** | |

`docs/ARCHITECTURE.md` originally called this "about 530 Mcycles/s (66%)" — a scenario it
thought might not fit but was in the same ballpark as the "typical" one. Measured: **it does not
fit, at either end of the assumed IPC range** — 136% of the core at the most optimistic IPC
(1.0, one instruction/cycle, no stalls at all, not expected on real hardware) and 182% at the
conservative bound. `docs/ARCHITECTURE.md` section 5.5's own mitigation ("limit: noise reduction
only on audible receivers; streaming only on request") is confirmed necessary, not just prudent —
this WP's numbers make it load-bearing, not optional headroom.

**A single receiver at its full native rate is expensive on its own**: one receiver at 384 ksps
native (the receiver bank's fastest output rate) with NR but *without* the noise blanker costs
demod (58.89/41.22) + decimate-by-8 resampler (98.61/69.03) + NR (67.62/47.34) = **225.12 /
157.59 Mcycles/s — 28.1% / 19.7% of the entire core, for one receiver.** Adding the noise
blanker at that rate (46.92/32.84) pushes it to 272.04/190.43 Mcycles/s (34.0%/23.8%). This
matches and sharpens `docs/S3_DSP.md` section 3.10's own finding that the resampler alone costs
about 4x the architecture doc's blanket assumption at 384 ksps.

## 6. What this means, flagged plainly

- **The "typical full load" scenario `docs/ARCHITECTURE.md` designed around has little to no
  real headroom** — recomputed at 55-66% of the core rather than the estimated 37%, using
  measured numbers for the receivers/NR/resampler/blanker and the architecture doc's own
  unchanged estimates for the three pieces this WP did not remeasure (FT8, GUI, streaming). If
  FT8/GUI/streaming turn out to also cost more than estimated (plausible, given every measured
  kernel here came in over its own flop-based estimate), this scenario goes over 100%.
- **The "may not fit" scenario does not fit**, confirmed at both ends of the assumed IPC range
  (136-182% of the core), not just at the conservative one. `docs/ARCHITECTURE.md`'s existing
  mitigation (NR only on audible receivers, streaming only on request) must be enforced by the
  firmware, not left as an informal guideline.
- **Native sample rate matters more than the architecture doc's per-receiver estimate assumed**:
  a receiver at 384 ksps costs roughly 1.5-1.8x what the same receiver costs at 96 ksps (compare
  section 5's 152.70/106.90 at 96 ksps against 225.12/157.59 at 384 ksps, both with NR, no
  blanker) — almost entirely the resampler (12.5 Mflop/s at 384 ksps vs. an assumed 3 Mflop/s in
  the original per-receiver line, per `docs/S3_DSP.md` section 3.10, now confirmed in measured
  instructions too).
- **Every measured kernel costs 2-4x its own flop-based cycle estimate** (section 4's sanity
  check: ~3.8x for the channel filter specifically, roughly consistent — 3-6x — across the whole
  table), because a flop count does not include load/store/address/branch instructions. Any
  future CPU-budget estimate for a not-yet-built `tr-dsp` module should apply a similar
  correction factor to a flop-based guess, or better, add a kernel to this harness once the
  module exists.
- **FT8 and the Slint full-redraw cost are still unmeasured** (stubs; WP S5/S11 not yet on
  `master`) and, on the evidence above, are more likely to come in over their own architecture-doc
  estimates than under. Re-run this harness (`bench-ft8`/`bench-gui` features) as soon as either
  branch lands, before trusting either scenario table again.

## 7. What is not covered

- FT8/FT4/WSPR decode and Slint software rendering: stubs, as above.
- VITA-49/TCI streaming, the HL2 control/lease path, and the "decoder receiver" (mix/decimate to
  12 kHz for a non-audible receiver feeding a decoder) kernel: not in WP S2's named kernel list,
  so not built here; their figures in section 5 are `docs/ARCHITECTURE.md`'s original estimates,
  unchanged.
- Real hardware cycle counts (PLAN WP B8): this document's Mcycles/s figures are all `measured
  instructions / assumed IPC`, never a directly measured cycle count. `mcycle` on the real
  AE350, once the board exists, replaces the assumption in section 3 with a measurement.
- The bit-exact FPGA receiver-bank model (WP R2) is not what feeds these kernels; each kernel is
  driven by a synthetic tone-plus-noise signal generated in `fw/tr-bench/src/lib.rs`, not R1's
  actual RTL output (same caveat `docs/S3_DSP.md` section 3 already carries for its own
  synthetic-signal tests).
