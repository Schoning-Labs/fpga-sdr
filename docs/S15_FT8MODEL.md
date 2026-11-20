<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# WP S15 — FT8 front-end reference model

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Status: done 2026-09-26, branch `s15-ft8model`.
Work package in [PLAN.md](PLAN.md) ("Proposed by cpu-budget", S15). The fixed-point specification the RTL
work packages F5, F6 and F7 build from is in [ARCHITECTURE.md](ARCHITECTURE.md) section 3.12; this document
has the reasoning and the measurements.

## 1. Result in short

- **The model**: `fw/tr-modes/src/frontend/`, pure Rust, `no_std` + `alloc`. Bit-exact models of the three
  FPGA engines (spectrogram F5, Costas sync search F6, candidate engine F7 passes 1 and 2), each with a float
  twin of the same structure, plus the CPU half of the decoder on top of them: candidate list, fine sync,
  mfsk-core's LLR/LDPC/OSD/CRC/unpack (unchanged, through its public API), signal subtraction and a second pass.
- **Decode counts** (done-test 1): on the three WSJT-X sample recordings the fixed-point front end decodes at
  least as many messages as mfsk-core's own pipeline at the same candidate count, including every message
  mfsk-core finds: busy slot 12 against 12 at 30 candidates and 15 against 14 at 60; the other two slots equal
  (mfsk-core as patched by PLAN S16). With the second pass the busy slot gives 19, among them all 8 of
  WSJT-X's reference decodes.
- **Fixed point costs nothing measurable** (done-test 2): 50 % decode thresholds of the fixed-point and the
  float front end differ by at most 0.03 dB (limit 0.3 dB) at audio levels from 10 to 6,000 LSB of noise.
  The front end is as sensitive as mfsk-core's own (S16-patched) pipeline in the same sweep: -21.54 against
  -21.57 dB.
- **CPU part under QEMU** (done-test 3): without OSD the CPU part is 57-139 M instructions per slot per
  receiver at 30 candidates and 135-213 M at 60 (mfsk-core's blind-CQ a-priori attempt, enabled by PLAN S16,
  included): under the 315 M cap. mfsk-core's OSD costs 50-140 M per attempt on the target, so uncapped OSD
  exceeds the cap in 5 of 6 runs (148-748 M); the cap can afford OSD only rationed to about one attempt per slot, or after
  mfsk-core exposes a cheaper OSD (section 5). The second pass (subtraction 8-11 M per signal plus a second
  decode) belongs in the operator receiver's extra allowance.
- **Refinements to the first sketch of 3.12**, all justified in section 3: the 15-point stage is a plain
  multiply-accumulate (only 4 of its 15 outputs are needed); the sync score uses one integer divider instead of
  80-bit cross-products; pass 1 decimates by CIC/30 plus a 65-tap FIR/2 with the NCO on the signal's centre;
  pass 2 is WSJT-X's frequency tweak plus a 32-point tone DFT. The DSP estimate for the front end rises from 34
  to about 58 blocks (20 of them can be time-shared away).

## 2. What was built

| File | What |
|---|---|
| `fw/tr-modes/src/frontend/fft256.rs` | F1 FFT (`fft_r22sdf.v`) at 256 points, bit-true block model ported from `tools/fft_r22sdf.py`; checked bit for bit against it |
| `fw/tr-modes/src/frontend/spectrogram.rs` | F5: 15 x FFT256 + 15-term combine = 3,840-point DFT, power words |
| `fw/tr-modes/src/frontend/sync.rs` | F6: per-bin best lag and Q16.16 score, primary and secondary window |
| `fw/tr-modes/src/frontend/candidates.rs` | CPU: 40th-percentile normalisation, dt parabola, de-duplication (mfsk-core `coarse_sync`'s tail) |
| `fw/tr-modes/src/frontend/baseband.rs` | F7 pass 1: NCO, mixer, CIC/30, FIR/2 to 200 sps |
| `fw/tr-modes/src/frontend/symbols.rs` | F7 pass 2: rotation, 79 x 8 tone DFTs |
| `fw/tr-modes/src/frontend/tables.rs` | every ROM table (twiddles, NCO, FIR design), generated with `libm` |
| `fw/tr-modes/src/frontend/decode.rs` | the `Fabric` seam, the model fabric, the CPU decoder (one or two passes, OSD cap) |
| `fw/tr-modes/src/frontend/subtract.rs` | CPU: signal subtraction |
| `fw/tr-modes/src/frontend/trace.rs` | recording and replaying the fabric's answers (for QEMU) |
| `fw/tr-modes/src/bin/ft8_frontend.rs` | host tool: `wav`, `sweep`, `trace`, `tables`, `vectors` |
| `fw/tr-modes/tests/s15_frontend.rs` | done-test 1 on the recordings, second-pass test, trace-replay test |
| `fw/tr-ft8bench/` | QEMU binary: replays a trace to the CPU half, counts `minstret` per stage |
| `tools/qemu_s15.sh` | builds traces, runs QEMU, checks target decodes equal the host's, prints the table |
| `tools/gen_s15_fft256_vector.py` | writes the FFT256 test vector from the F1 Python model |

`fw/Cargo.toml` gains the `tr-ft8bench` member and `opt-level = 3` for `mfsk-core` and `tr-modes` in dev/test
builds (the FT8 tests went from minutes to seconds; debug assertions and overflow checks stay on).
`tools/check.sh` gains `tools/qemu_s15.sh --smoke` (one QEMU run on the busy slot; skipped when `captures/` has
not been fetched) and the target build of `tr-ft8bench`.

**How mfsk-core is used.** No change to `fw/vendor/mfsk-core` by this WP (the branch carries PLAN S16's patch,
merged in). The soft symbols go in through
`ft8::decode_block::process_candidates_into_with_cs_scratch_tuned_with_fill` (public, `#[doc(hidden)]`, "for
host research"): it takes refined candidates with their 79 x 8 complex soft symbols and runs the same
LLR/BP/a-priori/OSD ladder, CRC, unpack and plausibility filter as mfsk-core's own decode
(`process_one_candidate_inner`), with the fill callback left empty. Fine sync is
`ft8::refine_fine::fine_refine_3stage` (public).

**Hooks wanted in mfsk-core** (for whoever maintains the vendored copy, PLAN S16; the scheduler PLAN S17
needs them to stay inside the cap, section 5):

1. A documented, non-hidden entry "decode these soft symbols for this candidate", returning the outcome per
   candidate (decoded, duplicate, failed) and which rung succeeded.
2. OSD effort as a parameter instead of fixed: which LLR variants (1-4), how many seeds (1-2), npre2 on or
   off. Today one failed candidate runs eight OSD searches (50-140 M instructions); one npre1 search on
   one variant would be about an eighth.
3. A switch for the blind-CQ a-priori attempt (on today whenever the Costas quality is 12 or more; 20-76 M
   per slot on these recordings), and whether it may use OSD.

**Done in PLAN FO1** (`docs/FT8_OFFLOAD.md`, VENDOR_PATCH fixes 6 and 7): all three hooks, and bit-packed OSD
kernels with identical results that make the unrationed ladder cost 3-4 times less than the tables below.

## 3. Design decisions (refinements of ARCHITECTURE 3.12's first sketch)

1. **3,840 = 256 x 15, second stage as multiply-accumulate.** With k = k1 + 256 k2, the spectrogram needs bins
   0 .. 1,023 only, so k2 = 0 .. 3: four outputs of each 15-point DFT, i.e. `A[k] = sum_n1 Y_n1[k mod 256]
   W_3840^(n1 k)`. That is 15 complex multiply-accumulates per bin, simpler than a Winograd 3 x 5 kernel and
   with a single rounding at the end. The 256-point stage is exactly F1's FFT, so its RTL and bit-true model
   already exist.
2. **Power as a 32-bit word with a per-receiver shift.** The full-precision power needs 54 bits. With a shift of
   16 the noise floor stays a few counts even at 10 LSB of audio noise, and only a near-full-scale single tone
   saturates. Measured (section 4.2): no loss at any level from 10 to 6,000 LSB. The shift is a register so the
   firmware can follow a very different level.
3. **One divider instead of cross-multiplication.** The score is a ratio of 40-bit quantities; comparing two
   ratios by cross-multiplying needs 80-bit products in every lane. One pipelined divider (about 240,000
   divides per receiver per slot, under 2 ms) makes every score a plain Q16.16 number, so the per-bin maxima,
   the CPU's percentile and the dt parabola need no further arithmetic in the fabric.
4. **Sync constants from mfsk-core.** Block-0 start frame 13 and lag range +/-63 are what mfsk-core's f32
   expressions round to (WSJT-X truncates to 12 and uses 62); keeping mfsk-core's makes the candidate list
   directly comparable with its pipeline.
5. **Pass 1: NCO on the signal's centre, real symmetric filter.** WSJT-X keeps f0 - 9.4 .. f0 + 53.1 Hz, an
   asymmetric band. Putting the NCO at f0 + 21.875 Hz makes the band symmetric (+/-31 Hz), so the filter has
   real coefficients (half the multipliers of a complex one). CIC/30 (4 stages) to 400 sps, then a 65-tap FIR
   decimating by 2: the CIC alone attenuates aliases by 77 dB or more, the FIR sets the band edge. Timing is
   aligned so output k is centred on audio sample 60 k, the same time base as WSJT-X's `cd0`. A 129-tap FIR
   (sharper edge) was measured: 0.05 dB better in the AWGN sweep (within its noise), one decode fewer on the
   busy slot at 60 candidates; the 65-tap version is specified.
6. **Pass 2: tweak and 32-point DFT, phase reference per symbol.** The rotation brings tone 0 of the refined
   carrier to 0 Hz, continuous in phase over the whole baseband, and each symbol's DFT starts its own phase at
   the symbol start, exactly WSJT-X `ft8b`. With any other reference the coherent 2- and 3-symbol LLRs (which
   add tone values across symbols) would see a tone-dependent phase error.
7. **Rounded NCO table index.** Truncating the 32-bit phase to 12 bits biases the phase by half a table step;
   rounding (one adder) makes the error zero-mean. Found by the fixed-versus-float comparison of the baseband.
8. **Fine sync on the CPU on the baseband** (mfsk-core's `fine_refine_3stage` unchanged, on the baseband moved
   back to tone 0 at 0 Hz by a 64-entry rotation), and a parabola through the Costas power at the best start
   sample and its neighbours for the sub-sample dt the subtraction needs.
9. **Cheap subtraction.** WSJT-X's `subtractft8` low-passes `x conj(ref)` with a 4,001-sample window through two
   180,000-point FFTs per signal; mfsk-core's `no_std` version does the same window as a direct 4,001-tap
   convolution per sample (about 2.4 G operations per signal). Here the product is summed in 5 ms blocks
   (nulls at multiples of 200 Hz), smoothed by a triangle of +/-33 blocks and interpolated back: two linear
   passes over the signal. A clean signal at an off-grid time and 0.2 Hz frequency error is removed to -39.8 dB.
10. **OSD cap.** mfsk-core's OSD costs 50-140 M instructions per failed candidate on the target (section 5).
    `DecodeParams::osd_max` runs belief propagation on every candidate first, then the full ladder with OSD
    on at most `osd_max` failures, highest Costas quality first. On the busy slot at 60 candidates
    `osd_max = 4` keeps every decode that unlimited OSD finds, `osd_max = 2` all but one.

## 4. Done-tests

### 4.1 Decode counts on the WSJT-X sample recordings

`ft8-frontend wav captures/ft8/<name>.wav <max_cand> <passes>`; band 100-3,000 Hz, sync threshold 1.3, OSD on
(mfsk-core's default `DecodeRequest::new` settings, `fft-portable` backend, the build the target runs).
"mfsk-core" is its own single-pass pipeline on the same audio with the same settings.

| Recording | Candidates | mfsk-core | Front end, fixed | Front end, float | Fixed, two passes |
|---|---|---|---|---|---|
| `qso3_busy` (WSJT-X `210703_133430`) | 30 | 12 | **12** | 12 | 17 |
| `qso3_busy` | 60 | 14 | **15** | 15 | 19 |
| `qso1` | 30 | 3 | **3** | 3 | 5 |
| `qso1` | 60 | 3 | **3** | 3 | 5 |
| `qso2` | 30 | 5 | **5** | 5 | 5 |
| `qso2` | 60 | 5 | **5** | 5 | 5 |

mfsk-core here includes PLAN S16's patch (merged into this branch): the higher-quality symbol spectra and the
blind-CQ a-priori attempt. Before it, mfsk-core found 11 and 12 on `qso3_busy`; the front end's counts did not
change. Every message mfsk-core decodes is also decoded by the front end, in every row. The front end's extra
single-pass decodes on `qso3_busy` (against the unpatched mfsk-core) are `XE2X HA2NP RR73`, `N1API HA6FQ -23` and `CQ EA2BFM IN83`; mfsk-core's own source
comments name the first and the last as real signals of this file that its other decode paths find; the middle
one has no reference (a plausible QSO). With two passes `qso3_busy` gives 19 messages including all 8 of WSJT-X's own
reference list (`K1BZM DK8NE -10` and `KD2UGC F6GCP R-23` appear only after subtraction, as in WSJT-X); `qso1`
gains `TK4LS YC1MRF 73` and `OH3NIV ZS6S -03`. `tests/s15_frontend.rs` asserts the 30-candidate rows and the
8 reference decodes.

### 4.2 Fixed point against float (the 0.3 dB test)

`ft8-frontend sweep -23 -19 0.5 200 <sigma> 20`: per SNR step 200 trials, each a `CQ <call> <grid>` message at
a random frequency (300-2,700 Hz) and time offset (+/-0.3 s) in white Gaussian noise, SNR in 2,500 Hz as
WSJT-X (the same channel and convention as the S5 `sensitivity-sweep`), noise scaled to `sigma` LSB of the
16-bit audio, decoded over +/-100 Hz with 20 candidates and threshold 1.0. The fixed and float front ends see
identical audio (paired trials). 50 % point by linear interpolation.

| Noise level (LSB) | Fixed 50 % point | Float 50 % point | Fixed minus float |
|---|---|---|---|
| 6,000 (the S5 sweep's level, audio near full scale) | -21.54 dB | -21.54 dB | 0.00 dB |
| 1,000 | -21.55 dB | -21.55 dB | 0.00 dB |
| 100 | -21.54 dB | -21.54 dB | 0.00 dB |
| 30 | -21.57 dB | -21.55 dB | -0.02 dB |
| 10 (power shift 16 leaves about 3 counts of noise per bin) | -21.52 dB | -21.55 dB | +0.03 dB |

Hit counts per step differ between fixed and float by at most 7 of 200 (at 10 LSB, in both directions),
elsewhere by at most 6. Same sweep with 100 trials at 1,000 LSB including mfsk-core's own pipeline: front end
-21.54 dB fixed, -21.56 dB float, mfsk-core -21.57 dB. These runs use the S16-patched mfsk-core back half; with
the unpatched one (a-priori attempt off) the same sweep gave -20.95 dB for both fixed and float at every level
(fixed minus float 0.00 to -0.02 dB) and -20.39 dB for mfsk-core. The a-priori gain is large here because every
test message is a CQ.

### 4.3 CPU part under QEMU

`bash tools/qemu_s15.sh` (about 25 minutes): for each recording and setting the host model records every
answer the engines give the CPU (sync records, basebands, soft symbols); `fw/tr-ft8bench` replays that trace
to the unchanged CPU code built for the AE350 (`riscv32imafc`, `+d`) under `qemu-system-riscv32 -icount
shift=0` and reads `minstret` around each stage. The script checks that the target decodes exactly the
host's messages (it did, every run). Millions of instructions per 15 s slot for one receiver, **bold** = within
the 315 M cap (30 Mcycles/s at IPC 0.7, `docs/CPU_BUDGET.md` section 8 decision 1). mfsk-core as merged from
PLAN S16 (its blind-CQ a-priori attempt is on, WSJT-X's pass for an unknown station calling CQ; it runs for
every candidate that fails belief propagation with Costas quality 12 or more, with OSD if OSD is on). "OSD
attempts": `all` = mfsk-core's ladder on every candidate; `none` = belief propagation (and the a-priori
attempt without OSD) only; a number = at most that many OSD attempts per pass, best Costas quality first
(`DecodeParams::osd_max`).

| Recording | Candidates | Passes | OSD attempts | Decodes | **Total** | Candidate list | Fine sync | LLR/BP/AP/OSD/unpack | Subtraction | Reading engine words | Candidates past the Costas gate (pass 1, 2) |
|---|---|---|---|---|---|---|---|---|---|---|---|
| qso3_busy | 30 | 1 | all | 12 | 338.8 | 0.3 | 24.7 | 308.4 | 0.0 | 5.5 | 14, 0 |
| qso3_busy | 30 | 1 | none | 10 | **132.7** | 0.3 | 24.7 | 102.3 | 0.0 | 5.5 | 14, 0 |
| qso3_busy | 60 | 1 | all | 15 | 747.7 | 0.3 | 49.0 | 687.6 | 0.0 | 10.8 | 18, 0 |
| qso3_busy | 60 | 1 | none | 12 | **213.0** | 0.3 | 49.0 | 152.9 | 0.0 | 10.8 | 18, 0 |
| qso3_busy | 60 | 1 | 2 | 14 | 496.6 | 0.3 | 49.0 | 436.4 | 0.0 | 10.8 | 18, 0 |
| qso3_busy | 60 | 1 | 4 | 15 | 676.5 | 0.3 | 49.0 | 616.3 | 0.0 | 10.8 | 18, 0 |
| qso3_busy | 30 | 2 | 2 | 17 | 661.7 | 0.5 | 48.9 | 488.0 | 113.1 | 11.1 | 14, 9 |
| qso3_busy | 60 | 2 | 2 | 17 | 1,009.9 | 0.5 | 97.3 | 758.7 | 131.3 | 22.0 | 18, 15 |
| qso1 | 30 | 1 | all | 3 | **148.0** | 0.2 | 24.5 | 117.8 | 0.0 | 5.5 | 5, 0 |
| qso1 | 30 | 1 | none | 3 | **57.2** | 0.2 | 24.5 | 27.0 | 0.0 | 5.5 | 5, 0 |
| qso1 | 60 | 1 | all | 3 | 707.9 | 0.2 | 48.4 | 648.5 | 0.0 | 10.8 | 8, 0 |
| qso1 | 60 | 1 | none | 3 | **135.0** | 0.2 | 48.4 | 75.6 | 0.0 | 10.8 | 8, 0 |
| qso1 | 60 | 1 | 2 | 3 | 607.4 | 0.2 | 48.4 | 548.1 | 0.0 | 10.8 | 8, 0 |
| qso1 | 60 | 1 | 4 | 3 | 725.1 | 0.2 | 48.4 | 665.8 | 0.0 | 10.8 | 8, 0 |
| qso1 | 30 | 2 | 2 | 4 | 1,024.0 | 0.3 | 48.8 | 932.6 | 31.1 | 11.1 | 5, 6 |
| qso1 | 60 | 2 | 2 | 4 | 1,553.4 | 0.4 | 97.5 | 1,402.5 | 31.1 | 22.0 | 8, 10 |
| qso2 | 30 | 1 | all | 5 | 504.2 | 0.2 | 24.5 | 474.1 | 0.0 | 5.5 | 13, 0 |
| qso2 | 30 | 1 | none | 5 | **139.3** | 0.2 | 24.5 | 109.2 | 0.0 | 5.5 | 13, 0 |
| qso2 | 60 | 1 | all | 5 | 651.8 | 0.2 | 49.1 | 591.7 | 0.0 | 10.8 | 15, 0 |
| qso2 | 60 | 1 | none | 5 | **197.8** | 0.2 | 49.1 | 137.8 | 0.0 | 10.8 | 15, 0 |
| qso2 | 60 | 1 | 2 | 5 | 315.4 | 0.2 | 49.1 | 255.3 | 0.0 | 10.8 | 15, 0 |
| qso2 | 60 | 1 | 4 | 5 | 431.4 | 0.2 | 49.1 | 371.3 | 0.0 | 10.8 | 15, 0 |
| qso2 | 30 | 2 | 2 | 5 | 676.5 | 0.3 | 48.5 | 567.2 | 49.3 | 11.1 | 13, 8 |
| qso2 | 60 | 2 | 2 | 5 | 983.4 | 0.3 | 97.6 | 814.1 | 49.3 | 22.0 | 15, 24 |

Before PLAN S16's patch (a-priori attempt compiled out on this build) the same runs were 50-76 M lower on
`qso3_busy` and 19-23 M lower on the other two without OSD, and the decode counts were the same.

## 5. Where the CPU instructions go

- **Without OSD everything fits**, a-priori attempt included: 57-139 M at 30 candidates, 135-213 M at 60
  candidates, one pass. Fine sync is 0.8 M per candidate (49 M at 60), the candidate list 0.3 M, reading
  the engines' words 0.18 M per candidate; belief propagation, LLRs, the a-priori attempt and unpacking are
  the rest (27-153 M).
- **OSD does not fit as mfsk-core runs it.** One OSD attempt (a candidate that failed belief propagation)
  costs 50-140 M instructions: mfsk-core runs OSD on each of the four LLR variants with two seeds, eight
  searches, with the deeper npre2 search when the Costas quality is 18 or more. On `qso2` uncapped OSD costs
  365-454 M and decodes nothing extra; on `qso3_busy` it buys 2-3 decodes. With the cap at 2 attempts, 60
  candidates: 315-607 M. So the per-receiver cap affords **candidates plus the a-priori attempt, and OSD only
  after it is made cheaper**; at 60 candidates without OSD there is about 100-180 M of headroom, room for
  about one of today's OSD attempts, or several if one attempt were one search (npre1, one LLR variant, one
  seed: about an eighth) — the hook asked of mfsk-core in section 2. The scheduler (PLAN S17) should spend
  the headroom per slot with `osd_max` and the measured count, not a fixed setting.
- **Second pass**: subtraction costs 8-11 M per subtracted signal (113-131 M for the 12-15 decodes of
  `qso3_busy`), and the second pass's decoding is about another first pass. With `osd_max = 2` two passes
  cost 660-1,550 M; without OSD they would be about 2 x (first pass) + subtraction, 150-560 M, inside the
  operator receiver's 30 + 60 Mcycles/s allowance (about 945 M instructions per slot at IPC 0.7).
- The counts include parsing the recorded trace (a little more than reading DDR3 words would cost) and
  a size-class heap allocator. mfsk-core's own full pipeline on the target at the same light setting is
  15.4-15.7 G instructions per slot (PLAN S16, `docs/CPU_BUDGET.md`); the front end removes all of it but
  the rows above.

## 6. How to reproduce

```sh
cd <repository root>
bash tools/fetch_test_audio.sh
cd fw
cargo test -p tr-modes --lib frontend            # unit tests: F1 bit-exact, tables, DFT, filters, sync
cargo test -p tr-modes --test s15_frontend        # decode counts, second pass, trace replay
cargo run --release -p tr-modes --bin ft8-frontend -- wav ../captures/ft8/qso3_busy.wav 60 2
cargo run --release -p tr-modes --bin ft8-frontend -- sweep -23 -19 0.5 200 1000 20
cargo run --release -p tr-modes --bin ft8-frontend -- tables ../rtl/ft8/rom       # ROM files for F5-F7
cargo run --release -p tr-modes --bin ft8-frontend -- vectors ../captures/ft8/qso3_busy.wav /tmp/ft8vec
cd .. && bash tools/qemu_s15.sh                   # about 25 minutes; --smoke for one run
```

## 7. What remains, and limits

- **RTL** (F5-F7) does not exist; the models here are its reference. `ft8-frontend tables` writes the ROM
  files; they are not committed yet because no RTL loads them.
- **FT4 and JS8** are not modelled (other symbol lengths, 4 tones, other Costas patterns).
- **Early decodes** (sync search at 11.8 s and 13.5 s) are not modelled.
- **OSD cost** dominates the CPU part when it runs (section 5); the scheduler (PLAN S17) must ration it, and a
  cheaper OSD (npre1 only, fewer LLR variants and seeds) needs an mfsk-core option (PLAN S16 owns the vendored
  copy). The blind-CQ a-priori attempt has no switch either; its cost (20-76 M per slot here) is inside every
  number above.
- The instruction counts include parsing the recorded trace, a little more than reading the engines' words
  from DDR3 would cost. IPC on the real core is still assumed (PLAN B10).
- The real-signal evidence is three recordings; the extra decodes' correctness is checked only where a
  reference exists.
