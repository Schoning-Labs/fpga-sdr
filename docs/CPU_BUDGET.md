<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# CPU budget: what moves to the FPGA, what stays in Rust (cpu-budget work)

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Owner decisions: [DECISIONS.md](DECISIONS.md) ("do as much as possible in hardware"). Measurement method:
[S2_BENCH.md](S2_BENCH.md) (QEMU, `-icount shift=0`, `minstret`). The new FPGA blocks are specified in
[ARCHITECTURE.md](ARCHITECTURE.md) sections 3.10 to 3.14; the recomputed budget is also in its section 5.5;
the work packages are at the end of [PLAN.md](PLAN.md) ("Proposed by cpu-budget").

## 1. Result in short

- With the old split (every receiver's filter, demodulator and AGC in firmware), the owner's normal use
  cost 55-66 % of the core and the heavy use 136-182 %, **before** FT8. FT8 decode, now measured for the
  first time (section 5), costs about 10 % of the core **per receiver** even at a light decode depth and with
  every software fix below. Eight FT8 receivers alone would take 85 %. The old split cannot work.
- **Moved to the FPGA**: per-receiver noise blanker, decimation, channel filter, demodulation (SSB, CW, AM,
  SAM, FM), AGC and S-meter (3.10); the audio mixer, clocked in HL2 time so no resampling is needed
  anywhere (3.11); the FT8/FT4 front end: spectrogram, Costas sync search, per-candidate
  down-conversion and soft symbols (3.12); VITA-49 packet framing (3.13). About 150 of the 298 DSP blocks and 150 of
  the 340 BSRAM blocks are then in use (3.14).
- **Stays in Rust**: noise reduction (at 12 ksps now), AGC after it, the decoders' back halves (LLR, LDPC,
  OSD, CRC, unpacking, signal subtraction), the GUI, TCI and all control.
- **New budget at IPC 0.7** (section 6): normal use **38.9 %** of the core (target 40 %), heavy use
  **51.4 %** (target 85 %), both including FT8 on all 8 receivers and a GUI allowance.
- **Software wins measured now** (section 4): the `tr-dsp` kernels need 2.2-3.5 times fewer instructions
  than before (new FFT, fused multiply-add, hardware square root, real FFT for noise reduction, faster
  resampler, LTO). Turning on the A25's hardware double-precision unit cuts FT8 decode instructions by 3.3
  times (section 5).

## 2. Where the cycles went (before this work)

From [S2_BENCH.md](S2_BENCH.md) section 4, instructions per block of 512 samples at 48 ksps, at the start
of this work:

| Kernel | Instr/block | Mcycles/s @ IPC 0.7 | What it is | Avoidable? |
|---|---|---|---|---|
| Channel filter (1,024-point fast convolution) | 416,162 | 55.7 | two 1,024-point FFTs per 512 samples | yes: FIR in the FPGA (3.10) |
| SSB / CW demod (filter + real part + AGC) | 439,697 / 437,880 | 58.9 / 58.6 | filter plus a few operations | yes: FPGA |
| AM env / AM sync / FM | 473,153 / 483,514 / 511,846 | 63.4 / 64.8 / 68.6 | filter plus demodulator | yes: FPGA |
| Noise reduction (48 ksps) | 504,918 | 67.6 | one more FFT pair | partly: run it at 12 ksps (4x fewer samples) |
| Noise blanker at 384 ksps | 43,791 | 46.9 | software square root per sample | yes: FPGA |
| Resampler 384 to 48 ksps | 179.8 per input sample | 98.6 | 65-tap FIR with a `%` per sample | yes: the receiver rate for listening is the FPGA's choice |

Why so much: every receiver was fed to the CPU at 48-384 ksps, and the CPU did the full chain on every
sample. Voice, CW and every digital mode need at most 12 ksps of audio. The work done at the high rate
(blanking, decimation, channel filtering) is fixed-algorithm, multiply-heavy and identical for every
receiver: what DSP blocks are for.

## 3. The split, and why

Rule applied: a function goes to the FPGA if its algorithm is fixed and its cost is per sample; it stays in
Rust if the algorithm is still changing, needs large state or search, or runs rarely. Candidates ranked by
CPU saved per DSP block (owner steer: use up to about 70 % of the DSP blocks for this):

| Candidate | DSP | BSRAM (36 kbit) | CPU saved, normal use | CPU saved, heavy use | Decision |
|---|---|---|---|---|---|
| (1) Receiver back end: blanker, decimation to 24/12 ksps, channel filter, SSB/CW/AM/SAM/FM, AGC, S-meter (3.10) + mixer (3.11) | 16 | 40 | 2 audible receivers at 96 ksps (2 x 43.2) + 6 decoder receivers (6 x 26.5): about **245 Mcycles/s, 31 %** | 8 audible receivers at 384 ksps (8 x 84.4): about **675 Mcycles/s, 84 %** | **move** |
| (2) FT8/FT4 front end: spectrogram, Costas sync search, candidate down-conversion and soft symbols (3.12) | 34 | 32 | 8 receivers x 71 Mcycles/s: about **570 Mcycles/s, 71 %** | same, more at deeper decode | **move** |
| (3) Noise reduction in the FPGA | about 8 | about 8 | 2 x 5.0 = **10 Mcycles/s, 1.3 %** | 8 x 5.0 = **40 Mcycles/s, 5 %** | **keep in Rust** (see below) |
| (4) VITA-49 framing (3.13) | 0 | 4 | 4 streams at 192 ksps: 13 Mcycles/s, 1.6 % | 8 at 384 ksps: 53 Mcycles/s, 6.6 % | move (low priority, needs the SFP link) |

Arithmetic behind the "saved" column (all at IPC 0.7, from section 4's measured kernels after the software
fixes, i.e. what the firmware would still cost if nothing moved):

- One audible receiver at 96 ksps: SSB demod 26.49 + resampler by 2 12.55 + blanker 3.81 + noise reduction
  at 48 ksps would be replaced by noise reduction at 12 ksps (counted separately) = 42.85, rounded 43.2 with
  AGC glue. At 384 ksps: 26.49 + 42.60 + 15.29 = 84.4.
- One decoder receiver needs audio at 12 ksps; in firmware that is at least the SSB demodulator at 48 ksps,
  26.5.
- FT8 front end: lean decode 894 M instructions per slot, of which the FPGA takes 83 % (section 5):
  0.83 x 894 M / 15 s / 0.7 = 70.7 Mcycles/s per receiver.
- Noise reduction: 3.51 M instructions/s per receiver (section 4, with AGC and glue) / 0.7 = 5.0.

Why noise reduction stays in Rust (candidate 3): it saves at most 5 % of the core in the heavy case, it is
the stage most likely to be replaced by a better algorithm (the current spectral subtraction is a first
version), and the budget in section 6 fits without it. It remains a clean later option: the back end's
audio ring and return ring (3.10) are exactly the interface an FPGA noise reducer would use, so moving it
later changes no other block. **Owner decision 3 in section 8.**

Why the decoders' back halves stay in Rust: LDPC belief propagation, ordered-statistics decoding, CRC,
message unpacking and signal subtraction are branchy, data-dependent and different per mode; together they
are about 11-13 % of a lean FT8 decode (section 5). The owner steer names the same split.

## 4. Software changes and measured gain

All numbers: `bash tools/qemu_s2.sh`, instructions retired under QEMU, identical binary for the AE350.
"Before" is the S2 measurement at the start of this work (master `fcbc44a`); "after" is this branch.

| Kernel | Before | After | Gain |
|---|---|---|---|
| Channel filter, 48 ksps (instr/block) | 416,162 | 179,666 | 2.32x |
| AGC, 48 ksps (instr/block) | 18,493 | 12,397 | 1.49x |
| SSB demod | 439,697 | 197,787 | 2.22x |
| CW demod | 437,880 | 200,726 | 2.18x |
| AM envelope demod | 473,153 | 200,746 | 2.36x |
| AM synchronous demod | 483,514 | 218,061 | 2.22x |
| FM demod | 511,846 | 238,162 | 2.15x |
| Noise reduction, 48 ksps | 504,918 | 143,868 | 3.51x |
| Noise blanker (any rate) | 43,718 | 14,209 | 3.08x |
| Resampler 96 / 192 / 384 ksps (instr/input sample) | 191.0 / 183.5 / 179.8 | 91.5 / 82.3 / 77.6 | 2.1-2.3x |
| **New:** noise reduction at 12 ksps (instr/sample) | | **250.6** | 3.0 M instr/s per receiver |
| **New:** AGC at 12 ksps (instr/sample) | | **22.1** | 0.27 M instr/s per receiver |

What changed (branch commit "tr-dsp: radix-4 FFT ..."):

1. **FFT** (`tr-dsp/src/fft.rs`): radix-4 instead of radix-2 (each data word loaded and stored half as
   often), twiddles stored per stage in the order the butterflies read them (no index arithmetic, no
   bounds checks), no `if inverse` in the inner loop, bit reversal as a list of swap pairs, an
   `inverse_unscaled` so callers fold 1/N into a multiply they do anyway, and a gather entry for
   overlap-save that builds the bit-reversed frame and updates the history in one pass. 1,024-point
   forward transform, same compiler settings: 171,559 instructions before, 77,348 after (2.2x). Checked against a double-precision
   DFT for every size from 2 to 1,024.
2. **Fused multiply-add and hardware square root** (`tr-dsp/src/fmath.rs`): `libm::sqrtf` has no RISC-V
   fast path and ran a bit-by-bit software square root; Rust never fuses `a*b+c` on its own. Inline
   `fsqrt.s` / `fmadd.s` / `fmsub.s`, enabled by `cfg(tr_hw_fpu)` from `tr-dsp/build.rs` because stable
   Rust does not expose `target_feature = "f"` to `cfg` on RISC-V. The host keeps `libm` and plain
   arithmetic (square roots are bit-identical; fused results differ in the last bit, inside every test
   tolerance). Complex multiply and `norm_sqr` use it everywhere.
3. **Real-input FFT for noise reduction** (`RealFft<H>`): the audio is real, so one `N/2`-point complex FFT
   plus an untangling pass replaces an `N`-point complex FFT, and only the non-redundant half of the bins
   is processed. Same output as before (the test SNR is identical to 6 digits: +1.3643 dB after NR, same
   signal). `NoiseReducerN<H>` is generic; `NoiseReducer12k` (256-sample frames, 128-sample hop, the same
   46.9 Hz bins and 21.3 ms frames as before) is the one the new split uses.
4. **Fast convolution**: 1/N folded into the stored response, the output rotation skipped when the shift
   is 0 (SSB, AM, FM).
5. **Resampler**: delay line stored twice so the window is always contiguous (no `%` per sample, which is
   an integer division), symmetric taps folded (one multiply per two samples), two accumulators, and a
   block API that keeps the state in registers.
6. **Release profile**: `codegen-units = 1`, `lto = "fat"` in `fw/Cargo.toml`. Effect under 3 % on most
   kernels, 33-49 % on the AGC (clamps and `fabsf` inlined).
7. **Hardware double precision** (`-C target-feature=+d` in `fw/.cargo/config.toml`): no effect on
   `tr-dsp` (all `f32`), 3.3x on FT8 decode (section 5).

Checked and **not** adopted:

- `-C target-cpu=andes-a25`: valid in Rust 1.93 (LLVM's Andes A25 model); it enables the D extension and
  the Andes performance extension (XAndesPerf: `nds.lea.*` address arithmetic, `nds.bfoz` bit-field
  extract, compare-and-branch with constants). QEMU cannot execute XAndesPerf, so it cannot be measured
  here or used in the QEMU checks. Measured proxy: `+zba` (standard instructions equivalent to `nds.lea`)
  saves only about 1 % on these kernels, because the rewritten loops already walk pointers. Worth trying
  on the board (PLAN B8) for integer-heavy code; not needed for the budget.
- **Andes P extension (packed SIMD, "DSP supported" in MUG1031)**: the A25 in the AE350 has it, but LLVM's
  `andes-a25` model does not include it and rustc has no target feature for it (checked:
  `rustc --print target-features` lists no P or Andes DSP feature). It could only be used through
  hand-written `.insn` assembly, and it operates on 8/16-bit integer lanes, not on `f32`. Not worth it:
  the heavy per-sample integer work is going to the FPGA anyway.
- Fixed-point rewrites of the `f32` kernels: the A25 has single-cycle-issue FP multiply-add; no gain
  expected, and they would lose the host/target equivalence of the tests.

## 5. FT8 decode, measured

Measured for this work with mfsk-core 0.11 (the decoder `tr-modes` wraps on branch `s5-modes`) built for
`riscv32imafc` and run under QEMU with the same `minstret` method, on the two WSJT-X sample slots in
`captures/ft8/` (15 s at 12 ksps). The harness was a throw-away program (mfsk-core, the s5-modes portable
FFT, a mixed-radix Stockham FFT written for this measurement, a size-class allocator, and a sampling
profiler on the machine timer); it is not committed because `tr-modes` is not on master yet. PLAN WP S16
turns it into the committed `bench-ft8` kernel.

| Decode setting | Slot | Decodes | Instructions, soft `f64` | Instructions, hardware `f64` (`+d`) |
|---|---|---|---|---|
| Lean: `DecodeRequest::new`, 30 candidates, no OSD | qso1 | 3 | 2,839,745,529 | 736,198,333 |
| Lean | qso3_busy | 7 | 2,971,233,407 | 893,664,156 |
| WSJT-X depth 1 (`wsjtx_depth(.., D1)`, 60 candidates; OSD compiled out on the target) | qso1 | 4 | 67,963,730,958 | not run |
| WSJT-X depth 1 | qso3_busy | 16 | not run | 234,099,041,481 |

The first finding is the biggest: **62 % of the lean decode's instructions were software double-precision
arithmetic** (`__adddf3`, `__muldf3`, `__divdf3`): mfsk-core uses `f64` in its hot loops, and the
`riscv32imafc` target does not use the A25's D unit. `-C target-feature=+d` fixes it (3.3x fewer
instructions). The ABI stays `ilp32f`, so the precompiled `core` library links unchanged; rustc warns
that `d` is an unstable target feature, but the flag works on stable Rust 1.93.

Where the lean decode of the busy slot goes with `+d` (sampling profile, 17,855 samples, one per 50,000
instructions, attributed through inlining to the mfsk-core function that owns the code):

| Part | Share | Instructions per slot | Goes to |
|---|---|---|---|
| Soft-symbol DFTs per candidate (`fill_symbol_spectra`: 8 tones x 79 symbols x 1,920 samples, direct correlation) | 39.5 % | 353 M | FPGA (3.12 (d): down-conversion to 200 sps, then 32-point tone DFTs) |
| FFTs: spectrogram 372 x 3,840 points (212 M), whole-slot 192,000 points (44 M), 30 x 3,200 points (14 M) | 30.1 % | 269 M | FPGA (spectrogram; the other two are the software down-conversion the FPGA replaces) |
| Spectrogram power and accumulation | 5.9 % | 52 M | FPGA |
| Coarse (Costas) sync search | 4.9 % | 43 M | FPGA |
| FFT planning (twiddles recomputed with `libm` sin/cos on every plan) | 6.0 % | 53 M | software fix: cache plans |
| Fine sync | 2.1 % | 19 M | stays (runs on the FPGA's 200 sps baseband) |
| Down-conversion glue | 0.5 % | 4 M | FPGA |
| LDPC belief propagation, LLRs, candidate bookkeeping, unpacking, memory | 11.2 % | 100 M | stays |

So with the FPGA front end (3.12) and plan caching the CPU keeps **about 120 M instructions per slot per
receiver** at lean depth (100 M + fine sync 19 M): 8.0 M instructions/s, **11.4 Mcycles/s at IPC 0.7
(1.4 % of the core) per receiver**, against 85 Mcycles/s (10.6 %) in software with `+d` and 283 Mcycles/s
(35 %) without it.

### WP S16: the committed `bench-ft8` kernel, and OSD's real cost measured

PLAN WP S16 turned the throw-away harness above into `fw/tr-bench/src/ft8_bench.rs`, run by
`tools/qemu_s2.sh` (not `--smoke`) whenever `captures/ft8/{qso1,qso3_busy}.wav` exist (fetch with
`bash tools/fetch_test_audio.sh` first). It measures the real, committed `tr-modes` decoder (this
section's own harness above used a separate, uncommitted Stockham FFT and is superseded by this
one) at `tr-modes`'s own two named settings, both with `-C target-feature=+d` (already the default
for this target, `fw/.cargo/config.toml`) and both **with OSD on** — `decode_slot`/
`decode_slot_light` both default to `DecodeDepth::FULL` (`osd: true`); the "light" vs "default"
axis is single-pass vs. WSJT-X's multi-pass depth-3 SIC driver, not OSD on vs. off. This table is
therefore **not directly comparable** to the "Lean" row above (no OSD) — it is the first real
measurement of OSD's actual on-target cost, which section 9 below previously listed as "not
measured":

| Setting | Slot | Decodes | Instructions (`+d`, OSD on) |
|---|---|---|---|
| Light (`decode_slot_light`, single pass, `max_cand=60`) | qso1 | 3 | 15,364,465,307 |
| Light | qso3_busy | 14 | 15,747,094,991 |
| Default (`decode_slot`, WSJT-X depth-3 multi-pass SIC, `max_cand=60`) | qso1 | not measured | ran out of time this pass -- see below |
| Default | qso3_busy | not measured | ran out of time this pass -- see below |

**Default setting not measured to completion.** A first attempt (16 MiB heap) exhausted the
allocator partway through qso1's default-setting decode; raised to 28 MiB (see
`fw/tr-bench/src/ft8_bench.rs`'s own doc comment) and re-run, but the default setting's own
multi-pass SIC driver (three coarse-sync + BP/OSD passes over the whole candidate list, each
subtracting and re-scanning) is, as expected, far more expensive than the light setting under
QEMU's instruction-exact `-icount shift=0` emulation (the same "no block-chaining fast path, every
guest instruction accounted for individually" cost this section already recorded for the old
harness's depth-1 run: "depth 1 alone took hours under QEMU"), and did not complete within this
pass's time budget. Not extrapolated to a fake-precise instruction count here (the old harness's
own lean-to-depth-1 ratio, ~262x, mixes two changes at once -- OSD going from off to on, and
single-pass going to multi-pass -- so it is not a safe multiplier to apply to the light setting
above, which already has OSD on and differs from default by the multi-pass axis alone). Qualitative
expectation only: several times to some tens of times the light setting's ~15.4-15.7 G
instructions, consistent with three coarse-sync/candidate passes instead of one. Left as a concrete
follow-up: either a longer QEMU run (multiple hours, unattended), a smaller `max_cand` for the
default-setting measurement specifically, or waiting for real board cycle counts (PLAN B8), which
won't share `-icount`'s block-chaining penalty.

The light-setting numbers (~15.4-15.7 G instructions, roughly **20x** the old no-OSD "Lean" row's
~2.8-3.0 G) are the honest, on-target cost of turning OSD on — matching this section's own
qualitative expectation ("OSD typically buys FT8 1-2 dB" per `docs/S5_MODES.md` "OSD gap") applied
at real embedded scale: no free lunch, but recall on `qso3_busy.wav` at `max_cand=60` goes from the
target's old 7 (OSD compiled out, PLAN S16's own comparison line) up to 20 of the 22 the host build
itself finds at the same `max_cand` (the other two are not WSJT-X-reference-verified either way —
see `docs/S5_MODES.md` "WP S16 follow-up" for the full decode-count comparison) once OSD plus the
two other `fft-extern` feature gates this WP widened are all counted together. At 15.5-15.7 G
instructions per 15 s slot: 1.03-1.05 G instructions/s,
**1,470-1,500 Mcycles/s at IPC 0.7 per receiver** (184-188 % of the whole 800 MHz core, for one
receiver, at the light setting alone) — confirming section 6's existing FT8 cap (30 Mcycles/s per
receiver, OSD limited to what fits under it) is not a precaution but a hard requirement, now with
the light setting's own real number behind it rather than only the old harness's no-OSD one.

**Plan-caching the `fft-extern` FFT backend**, this row's own leftover line item above ("FFT
planning ... 53 M instructions, 6 %: software fix: cache plans") — checked for this WP and found to
not apply the way that line implied. That 53 M figure was measured against the old, uncommitted
Stockham FFT harness this section's table above used, not against `tr-modes`'s own committed
`fft.rs` (a different, recursive mixed-radix Cooley-Tukey design — see `docs/S5_MODES.md`'s "no_std
FFT backend"). `fft.rs`'s own recursive transform already cuts its per-level twiddle cost from
`p*m` `libm` calls down to `p` (at most 13, since every FT8/FT4/WSPR length factors into 2/3/5 — see
`fft.rs`'s `SMALL_PRIMES`), so there is very little trig-call cost left to cache away: the dominant
remaining cost, by the same document's own earlier profiling, is the recursive gather's allocation
traffic, not repeated `sin`/`cos` calls. A genuine plan-caching win would need to address that
allocation traffic directly (an iterative, single-buffer, precomputed-execution-plan FFT, already
scoped in `docs/S5_MODES.md` "Follow-up: timing" as follow-up work) — not attempted here given the
risk of a correctness bug in the FFT this WP's own sensitivity fix (above) now directly depends on.

**Deeper decode settings.** Timed natively on this PC (mfsk-core with its `rustfft` backend, best of 3,
`qso3_busy`): 30 candidates 0.038 s (12 decodes), 60 candidates 0.080 s (14), WSJT-X depth 1 0.34 s (14),
depth 2 2.2 s (22), depth 3 2.8 s (22). Scaled by the lean ratio, depth 3 would be about 70 times the lean
decode: tens of G instructions per slot, several whole cores for one receiver. Two things found while
checking this:

- **OSD is compiled out of mfsk-core's embedded builds.** Its `osd_strategy` module is built only with the
  host `fft-rustfft` backend ("`DecodeDepth::osd` is a no-op on embedded builds"). That is why the target
  build finds 7 signals on the busy slot where the host build with the same 30 candidates finds 12 (the host
  trace shows 4 OSD attempts). OSD is worth having; enabling it on the AE350 needs an mfsk-core change or
  our own OSD (PLAN S16). Its cost on the target is not measured yet.
- WSJT-X-style depths 2 and 3 (many passes, OSD everywhere) are not affordable on this CPU in mfsk-core's
  form, with or without the FPGA front end. The budget therefore uses a **per-receiver cap** (section 6)
  and only a second pass on the operator's receiver.

Measured on the target build: depth 1 on the busy slot is **234 G instructions** (16 decodes), 262 times
the lean decode: about 22 G cycles per second of slot at IPC 0.7, 28 whole cores. Deep settings are out of
reach on this CPU in mfsk-core's form; the per-receiver cap is not a precaution but a necessity.

Latency (a reply needs the decode within about 2-3 s of the slot end): the spectrogram is built while the
slot runs; at slot end the sync search takes about 20 ms per receiver and the candidate engine about 0.1 s
for 8 receivers x 60 candidates (3.12). The CPU part at the 30 Mcycles/s cap is at most 315 M instructions
per receiver, 0.45 s at IPC 0.7. Decoding the operator's active receiver first gives its results about
0.5 s after slot end; all 8 are done in about 3.5 s, which is fine for monitoring.

## 6. The new budget

The full tables, with every line's arithmetic and source, are in ARCHITECTURE.md section 5.5. Summary:

**IPC assumption: 0.7 instructions per cycle** (conservative), 1.0 shown as the best case. Source: the WP S2
task description's range (0.7-1.0), with the A25 being a 5-stage in-order single-issue core (MUG1031 figure 2-1, BOARD)
so it cannot exceed 1.0. Not measured yet: PLAN B8 measures `mcycle` against `minstret` on the board. Two
things make 0.7 optimistic for some code: FT8 decode works on megabytes (the slot, the candidate buffers)
while the data cache is 32 KB, and `fdiv`/`fsqrt` are one instruction but many cycles. The margin to the
targets is what covers that.

| Line (Mcycles/s at IPC 0.7) | Normal | Heavy |
|---|---|---|
| Audible receivers with noise reduction, 5.02 each (NR 3.007 + AGC 0.265 + glue 0.24 M instr/s, / 0.7) | 2 x 5.02 = 10.0 | 8 x 5.02 = 40.1 |
| Decoder receivers, per-sample work | 0 | 0 |
| FT8 on 8 receivers, 30.0 each (cap; measured CPU part at 30 candidates without OSD: 11.4) | 240.0 | 240.0 |
| Second FT8 pass on the operator's receiver | 0 | 60.0 |
| GUI allowance (13 estimated x 3) | 40.0 | 40.0 |
| VITA-49 through the FPGA framer (4 / 8 receivers) | 1.0 | 1.0 |
| TCI allowance | 10.0 | 20.0 |
| HL2 control, network idle | 5.0 | 5.0 |
| TX baseband allowance | 5.0 | 5.0 |
| **Total** | **311.0 = 38.9 %** | **411.1 = 51.4 %** |
| Same at IPC 1.0 | 217.7 = 27.2 % | 287.8 = 36.0 % |
| Target | 40 % | 85 % |

Compared with the start of this work: normal use 55-66 % became 38.9 %, heavy use 136-182 % became 51.4 %,
and both now include FT8 on 8 receivers at a measured cost (the old numbers carried an unmeasured 21
Mcycles/s per receiver; the real software cost was 283 Mcycles/s per receiver before `+d` and 85 after).

Normal use has little margin (1.1 points at IPC 0.7). FT8 is 77 % of it, so the FT8 cap is the lever: at
20 Mcycles/s per receiver normal use drops to 29 %. Without the VITA-49 framer, software streaming adds 13.2
(normal, 40.5 %) or 52.7 Mcycles/s (heavy, 58.0 %). Without the FT8 front end, FT8 in software is 80
Mcycles/s per receiver (with `+d` and plan caching) and normal use would be about 89 %: **the FT8 front end
is what makes FT8 on 8 receivers possible.**

## 7. What the firmware's real-time work looks like now

- Interrupt line 10 (back-end audio block ready) for receivers with noise reduction: 128 samples at
  12 ksps every 10.7 ms; the handler only wakes the NR task; NR, AGC and the return-ring write run there.
- The IQ-block interrupt (line 2) is only needed for receivers the firmware streams or demodulates in
  software (IQ pass-through mode).
- No firmware task touches audio for plain listening; the audio ring (3.7) carries only system sounds, TX
  monitor and TCI audio.
- FT8/FT4 decoding runs as embassy tasks after each slot, fed by the FPGA's candidate lists and soft
  symbols, operator's receiver first.

Finding for the trap handler (not caused by this work, made more visible by it): riscv-rt's trap entry saves
only integer registers. Any interrupt handler that uses the FPU corrupts the interrupted task's FP
registers, and with `+d` those registers are 64 bits wide. Either keep FP out of interrupt handlers (the
plan above) or save the caller-saved FP registers with `fsd`/`fld`. PLAN C4 covers it.

## 8. Owner decisions needed

1. **FT8 decode depth: a cap per receiver.** Proposed: every FT8/FT4 receiver gets 30 Mcycles/s (3.75 % of
   the core, 315 M instructions per slot) for its CPU part; the decoder takes as many candidates and OSD
   attempts as fit (about 60 candidates with belief propagation, OSD on the best). A second decode pass
   (subtract and decode again) only on the operator's active receiver. WSJT-X-style deep decoding on all 8
   is not affordable on this CPU. Alternative if more recall is wanted on every receiver: an OSD engine in
   the FPGA (GF(2) row operations suit logic well), which goes against the steer to keep LDPC on the CPU,
   so it is not proposed without the owner's yes.
   **Update (PLAN FO1, `docs/FT8_OFFLOAD.md`):** neither an OSD engine nor a second (soft) CPU is needed.
   With mfsk-core's OSD rewritten in packed form (identical results) the full ladder, OSD on every
   candidate, fits this cap on all 8 receivers; the cap itself is unchanged.
   **Update (PLAN FO3, S17, FO2, `docs/FT8_CPU.md`):** after FO3 the full ladder costs 124-174 M of the
   315 M per slot; the decode scheduler enforces the cap with `mcycle` at candidate boundaries.
2. **Hardware double precision via an unstable rustc flag** (`-C target-feature=+d`, rustc warns on every
   build). Adopted on this branch because it cuts FT8 decode 3.3 times and works on the pinned toolchain;
   the alternative is a custom target file. No action unless the owner objects.
3. **Noise reduction stays in software** (section 3, candidate 3). Recommended; the FPGA option stays open.

## 9. Not done / limits

- ~~FT8 was measured with a scratch harness, not the committed `tr-bench`~~ **done**: PLAN S16
  committed it (`fw/tr-bench/src/ft8_bench.rs`); see "WP S16: the committed `bench-ft8` kernel"
  above.
- ~~FT8 with OSD on the target is not measured~~ **done, and no longer compiled out**: PLAN S16 found
  OSD was compiled out of this project's `fft-extern` build for the same historical reason
  `docs/S5_MODES.md`'s "OSD gap" already fixed for the sensitivity sweep (WP S5's Fix 4) — this was
  the same gate, just not yet reflected in this document's own wording. OSD is on by default for
  both `tr-modes` settings (`DecodeDepth::FULL`); its measured on-target cost is the "light" row
  above (~20x the old no-OSD "Lean" row).
- Depth 3 (`decode_slot`'s WSJT-X depth-3 multi-pass SIC, this document's own "default" setting) on
  the target was attempted under WP S16 and, consistent with this bullet's own prior note for depth
  1, did not complete in the time available under QEMU's instruction-exact `-icount shift=0`
  emulation (see "WP S16: the committed `bench-ft8` kernel" above) — the light setting's own
  measured cost (~20x lean) already shows deep settings are out of reach, and the budget excludes
  them by the cap (owner decision 1, above).
- Slint rendering is not measured (another branch); the GUI line is an allowance.
- The FPGA block estimates (DSP, BSRAM) are arithmetic, not synthesis.
- IPC is assumed (section 6) until PLAN B8.
- `tools/qemu_c2.sh` failed once and passed on rerun while several QEMU instances were running here: its
  loader waits a fixed 2 s for the handshake, which a heavily loaded PC can miss.
