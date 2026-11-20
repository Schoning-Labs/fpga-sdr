<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# ZOOM_FIT: the zoom small enough to fit, one FFT for both views

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Written 2026-10-13, branch `zoomfit`. Follows docs/ZOOM_IN_CHIP.md sections 10 to 16, docs/ROUTE_DIAG.md,
docs/THIN.md. Main clock 120 MHz, margin rule 7.92 ns. Results (section 6 on): Gowin EDA V1.9.12.04, GW5AST-138;
the estimates of sections 1 to 5 were made from V1.9.11.03 netlists.

Target: the zoom as built adds about 38,000 cells and 32 block RAMs to a chip that routes at about 145,000
cells and failed at 160,000. The zoom side has to come down by 15,000 to 20,000 cells.

Sections 1 to 5 are the plan, written before the work (estimates). Section 6 onward is what was built and
measured.

Sources for the chip's blocks: the primitive models in `IDE/simlib/gw5a/prim_sim.v` (SDPB: 18 kbit, widths 1, 2,
4, 8, 16, 32; SDPX9B: 9, 18, 36, so a 4,096-word memory is 4 bits per block; RAM16SDP4: 16 words x 4 bits,
written with the clock, read without one; MULT27X36 / MULTALU27X18 with input and output registers), and what
the earlier work packages took from UG300 (BSRAM), UG305 (DSP) and SUG550 (attributes) as recorded in
docs/FIT.md, and docs/TANG_LESSONS.md: no read-before-write block RAM on this chip (no memory here is
read and written at one address in one clock), `syn_ramstyle` and `syn_preserve` only in the comment form, no
inferred multiply-accumulate with load (the multipliers here are plain registered multiplies, the sums are in
logic). The PDFs were not opened again for this work. Not used: block cascade, the DSP pre-adder,
shift-register inference.

## 1. Where the zoom's cells are (before)

From docs/ZOOM_IN_CHIP.md section 14 (stand-alone run 7) and the netlist of the no-zoom chip (`impl/ls7`):

| Part | Registers | LUT + adders | LUT-RAM cells | Block RAM | DSP |
|---|---|---|---|---|---|
| Variable CIC (two channels, 11 stages x 82 bits in flip-flops) | 8,250 | about 5,000 | 0 | 0 | 0 |
| Fixed CIC (9 stages, decimate by 10, `rtl/rx`) | 3,570 | about 1,800 | 0 | 0 | 0 |
| Zoom FFT (4,096 points, complex) | 4,020 | about 3,500 | about 700 | 9 delay + 2 twiddle | about 20 |
| Narrow CIC, two filters, mixer, window, bus | 1,760 | about 2,400 | about 110 | 2 + 2 + 2 | about 10 |
| Zoom context in the spectrum pipeline | 1,100 | 1,450 | 110 | 11 | 3 |
| Whole-band FFT (16,384 points, real input), for comparison | 4,224 | 6,130 | 718 | 33 | 24 |

Correction to the task description: the whole-band FFT is 16,384 points, not 4,096 (`LOG_N = 14` in
`rtl/spectrum/spectrum_pipeline.v`); the zoom's is 4,096.

## 2. One FFT for both views

**How.** A radix-2^2 streaming FFT of 16,384 points is two stages (delays 8,192 and 4,096, one twiddle
multiplier) followed by a complete streaming 4,096-point FFT: after the first two stages the stream is four
blocks of 4,096 words, each of which the rest transforms on its own. That rest has the same structure, the same
twiddle ROM files and one bit more width than the zoom's own FFT. So the zoom's frame goes into the whole-band
FFT behind its second stage, as a fifth block between two whole-band frames:

- The zoom's windowed samples (2 x 16 bits) are collected in a frame buffer of 4,096 words.
- When a frame is complete and the whole-band input reaches a frame boundary, the whole-band input pauses,
  the 4,096 buffered samples go in at one per clock, and the whole-band input resumes with a new frame.
  Whole-band samples that arrive during the pause are dropped (the next frame starts later; frames need not
  be adjacent in time, each has its own window).
- A one-bit tag per block says at the output whose words these are. Whole-band bins and zoom bins go to the
  two contexts of the spectrum pipeline as before.

**Same values.** Butterflies are exact adds. The twiddle multipliers round the same way at any width. So the
zoom bins are word for word those of its own FFT (with the head-room bit of the first version back) and the
whole-band bins are untouched.

**What it saves:** the zoom's FFT (table above): about 4,000 registers, 3,500 LUT + adders, 700 LUT-RAM
cells, 11 block RAMs, about 20 DSP. And the zoom context's arrival queue (96 LUT-RAM cells, about 560 cells):
a zoom frame's bins now arrive in one burst long after the walk of the frame before.

**What it costs:**

- A frame buffer: 4,096 x 32 bits = **8 block RAMs**. Block RAM net: -3.
- About 300 cells for the buffer control, the input selection and the tags.
- Whole-band line rate: each zoom frame takes 4,096 of the 76.8 M samples a second. At the 48 kHz span
  (14.6 zoom frames a second) that is 0.08 %; at the widest span (up to 937 frames a second) up to 5 %. The
  number of frames averaged per line (K) does not change, a line just takes that much longer.
- Zoom: samples that arrive between "frame complete" and "frame played" are dropped (at most 213 us waiting
  for the whole-band frame boundary plus 34 us of playing). 48 kHz span: about 15 of 4,096 samples, the line
  rate goes from 14.65 to 14.59 a second. Narrow spans: 0 to 2 samples. Widest span: up to 950 samples, about
  810 frames a second instead of 937. A line is at most 0.3 ms later.
- The whole-band FFT now runs whenever samples arrive; `spectrum.ctrl.enable` gates the power stage (it
  already did) and no longer the FFT input. Otherwise a disabled whole-band view stopped mid-frame would
  block the zoom.

**The alternative, "the whole-band view as a second zoom receiver at span 38.4 MHz": worse.** A second
instance with the DDC bypassed is a second window, a second 4,096-point FFT and a second set of column
memories. It would replace the 16,384-point FFT (10,350 cells with its LUT RAM as place-and-route counts it,
33 block RAMs) by a 4,096-point one (about 8,000 cells, 11 block RAMs): 2,300 cells and 22 block RAMs
saved, for a whole-band bin of 18.75 kHz instead of 4.69 kHz (1,600 bins for 1,920 columns up to 30 MHz: fewer
bins than columns) and a line that sees a quarter of the samples. The shared FFT saves more cells (about
8,800) and keeps the whole-band resolution. **Decided: shared FFT, whole-band view stays 16,384 points.**
If block RAM, not cells, were the limit, a 4,096-point whole-band view through the same shared FFT would free
17 more blocks (delay lines 8 + 9); the owner would decide on the resolution.

## 3. The variable CIC

Today: 11 integrators and 11 combs per channel, 82 bits each, in flip-flops: 8,250 registers.

A CIC that decimates by R = 2^s is exactly a CIC that decimates by 2 followed by one that decimates by
R / 2 (the running sum over R samples is the sum over 2, summed over R / 2 pairs). And an 11-stage CIC that
decimates by 2 is a 12-tap filter with the binomial coefficients 1, 11, 55, 165, 330, 462, ... So:

1. **Decimate by 2 as a 12-tap filter** computed once per output (every second input, 20 clocks or more):
   the last 16 input samples in LUT RAM, one multiplier, a 27-bit sum. No integrators at the input rate.
2. **The rest, R / 2, as a serial CIC**: samples are now 20 clocks or more apart, so one adder does the 11
   integrators one per clock (each add in two halves on two clocks), a second one the 11 combs; state in
   LUT RAM (16 words x 82 bits each).
3. The existing output selection and rounding. The existing strobe timing; a 32-word output delay makes the
   sequence equal to today's from the first word after reset.

Same numbers: every sum is exact (82 bits, modular), the only rounding is the last one. Test:
`tb_cic_var_pow2`, every decimation word for word against the first version. All spans kept; the narrow
spans' stage and the filters behind are untouched, so the alias figures cannot change (they are properties of
the transfer function, which is the same).

Estimate: 8,250 registers and about 5,000 LUT + adders become about 1,300 registers, 1,100 LUT + adders, 110
LUT-RAM cells and 2 DSP. The earlier plan (ZOOM_IN_CHIP section 16: all eleven stages at the input rate, two
per clock) had the same register estimate but needs two 82-bit pipelines per channel; this one has none at
the input rate.

## 4. Other candidates

| What | Saves | Cost | Decision |
|---|---|---|---|
| Zoom context's arrival queue | 96 LUT-RAM cells, 560 cells | none with the shared FFT | do |
| `TW_M1_ONE`, `FFT_LUT_MAX_W = 512` on the zoom FFT | nothing: that FFT is gone | | n/a |
| Fixed CIC: combs (9 x 48 bits x 2, at 7.68 Msps) through one adder | about 1,200 registers, 800 adders | `rtl/rx` file of the other work package; 9 combs in 10 clocks is tight | later |
| Giving up the 3.072 MHz span | fixed CIC 9 -> 5 stages: about 1,500 registers, 900 adders; the half-band filter's second multiplier pair (2 DSP, 2 block RAM) | a feature | owner |
| Column and K-frame memories as floating-point words (12-bit and 21-bit mantissa) | 4 block RAMs in the zoom context, 7 in the whole-band context | about 3,000 cells; values no longer exact (0.004 dB); the shared walk engine changes | not now: cells are the limit |
| Frame buffer and zoom column memory in one 4,096 x 36 memory | 4 block RAMs | address selection on the context's slowest path | not now |
| Frame buffer in DDR3 | 8 block RAMs | a write and a read client on the arbiters | not now |
| Whole-band line buffer: one, not two (as the zoom's) | 2 block RAMs | a copy during a walk can be half old, half new | if block RAM is short |

## 5. Expected result

| | Registers | LUT + adders | LUT-RAM cells | Block RAM | DSP |
|---|---|---|---|---|---|
| Zoom receiver + zoom context, before | 18,800 | 14,200 | 920 | 30 + 2 compositor | about 33 |
| Shared FFT | -4,100 | -3,700 | -800 | -3 | -20 |
| Variable CIC | -6,900 | -3,900 | +110 | 0 | +2 |
| After | about 7,800 | about 6,600 | about 230 | 27 + 2 | about 15 |

About 19,000 cells less (LUT-RAM cells counted 6 each, as place-and-route does: 22,000). Block RAM: the zoom
then adds about 29 where the budget says 12; the table in section 4 lists what closes that (17 blocks: both
floating-point rows, the shared memory and the single line buffer), at the price of cells.

---

# What was built and measured

## 6. Result

All figures here are from Gowin V1.9.12.04 (owner's order of 2026-10-13: that version only). Zoom receiver +
the whole spectrum pipeline (both views), stand-alone, wrapper `gowin/wrap/zoom_only.v` with the whole band
active, wrapper cells subtracted. Counts from the synthesis netlists (`tools/gowin_mems.py`); "before" is the
old design (commit c3d6ee3) synthesized with the same version and wrapper.

| | LUT | Adders | LUT-RAM cells | Registers | Block RAM | DSP |
|---|---|---|---|---|---|---|
| Before | 12,122 | 10,261 | 1,761 | 25,032 | 84 | 68 |
| Step 1, one FFT (zoom FFT and arrival queue out; frame buffer, tags, pause control in) | about -4,300 | -1,490 | -780 | about -5,000 | -3 | -20 |
| Step 2, variable CIC (two channels: about 750 / 6,000 / 0 / 8,250 -> 1,051 / 410 / 112 / 1,305) | about +700 | -3,340 | +110 | about -6,200 | 0 | +2 |
| Step 3, whole-band line buffer one instead of two; fan-out limit in the FFT stages | about +50 | 0 | 0 | about +30 | -2 | 0 |
| **After** | **8,573** | **5,437** | **1,095** | **13,851** | **79** | **50** (place-and-route counts 55 of 298: a 27 x 36 multiplier is two) |

(The steps were not synthesized one by one with this version; their split is from the per-unit counts of the
before and after netlists and is approximate. The totals are measured.)

- **Cells: 47,415 -> 27,861 (LUT + adders + registers), 19,550 less, and 666 LUT-RAM cells less.** As
  place-and-route counts it: logic 18,084, registers 13,851.
- Of the after-figure the whole-band view alone is about 16,000 cells; the zoom now adds about 11,500 cells
  (it added about 31,000) and 22 block RAMs (it added 29).
- Variable CIC per channel: 525 LUT, 205 adders, 56 LUT-RAM cells, 652 registers, 1 DSP.
- What is largest now: the fixed CIC, 1,625 registers and 880 adders per channel.

## 7. Timing alone (7.92 ns, place 3 / route 1)

**Gowin V1.9.12.04, the branch with master 2f23463 merged: 134.0 MHz, 0 failing end points** (worst slack
+0.46 ns, in the whole-band window). The tightest path of the new logic is the block tag queue's write,
+1.48 ns. The version raised no PA2122 (a memory read and written at one address) in these files.
Reports: `gowin/reports/zoom/zoomfit_v1912_*`.

Three earlier runs were made with V1.9.11.03 before the order; they are **not results**, only how the one
timing fix was found: the first had 25 failing end points (109 MHz), all in the whole-band FFT, a stage's
`out_valid` with 137 to 176 loads into the read of the next stage's LUT-RAM delay line; `syn_maxfan` written
on the port did nothing; `syn_maxfan = 48` on the modules `fft_bf` and `fft_twmul` (about 25 registers)
removed them. That limit also applies to the FT8 front end's FFT (same modules; same values).

## 8. Checks

| Test | Result |
|---|---|
| `sim/zoom/zoom_shared_sim.v` (new; 5 minutes, so not a `tb_`) | zoom: 16,384 bins of 4 frames equal to a 4,096-point FFT of its own; whole band: 330,055 bins (20 frames) equal to a 16,384-point FFT of its own fed with the samples taken; 5 zoom frames played, all at whole-band frame boundaries; no zoom bin during a zoom walk; lines from both contexts |
| `tb_cic_var_pow2` | 1,746 words against the first version, 0 differ; again with strobes exactly 8 clocks apart: 0 differ |
| `zoom_rb1_compare_sim` (whole DDC + FFT against the first version) | 0 of 4,096 words differ |
| `tb_zoom_quick`, `tb_zoom_backend_quick`, `tb_spectrum_pipeline` (also after the line buffer change), `tb_spectrum_two_ctx`, `tb_fft_r22sdf`, `tb_fft_r22sdf_cplx`, `tb_sdr_core` | PASS |
| `zoom_rb1_burst_sim` (the same with the samples in HL2 bursts) | 0 of 4,096 words differ, 28 bursts |
| `zoom_alias_sim`, eleven spans (5 hours) | the line at the landing frequency is 110.6 to 128 dB under the reference at every span. The largest output word, the first version's measure: 2 steps (81.9 dB) at spans 1 to 9, none at 3 kHz, 4 steps (75.9 dB) at the widest span, where the simulation ends with FAIL as before. Unmodified master 2f23463 gives the same figures at the widest span (reference 25,017.34, 4 steps, 75.9 dB; run for that span only), and the steps of spans 1 to 9 are those of 2026-10-12; the dB values differ from that file by 0.85 dB because the reference tone now reads 25,017 instead of 27,590, on master too. Output: `sim/zoom/zoom_alias_result_2026-10-13.txt` |

Not run: `tb_compositor` (its inputs are unchanged in form), `zoom_bin48_sim`, `zoom_backend_full_sim`, the
firmware tests, any full-chip build.

## 9. What changed for the user and for firmware

- Spans, filters and alias figures: unchanged (the DDC's output words are the same).
- Zoom line rate: 48 kHz span 14.65 -> about 14.59 lines a second at most; narrow spans unchanged; widest
  span about 810 transforms a second instead of 937. A zoom line is up to 0.3 ms later.
- Whole-band line rate: up to 5 % slower at the widest zoom span, 0.08 % at 48 kHz, nothing with the zoom
  off. With the zoom built in, the whole-band FFT runs whenever samples arrive; `spectrum.ctrl.enable` still
  decides whether lines are produced.
- `spectrum.line_status.ready_buffer` now reads 0 always (one line buffer; the compositor has its own
  copy). No register was added: no regmap change, no generated file touched.
- A chip without the zoom (`ZOOM = 0`) is as before except for the single line buffer and the FFT fan-out
  limit.

## 10. Block RAM, and what else could go

The zoom + display path is at 79 blocks (84 before); without the zoom it is 57 (59 before the single line
buffer), so the zoom adds 22 where it added 29 (plus the compositor's zoom snapshot, 2, unchanged). The
8-receiver chip without zoom stood at 243; master's cut to 4 receivers frees 45 (docs of branch `nrx`), so the
chip with this zoom should be near 218 of the 255 allowed. That is a sum, not a build. If more is needed, in
order of cost:

| What | Block RAM | Cells | Other cost |
|---|---|---|---|
| Whole-band K-frame memory 45 bits instead of 48, saturating | -1 | 0 | a full-scale carrier clips above about 500 averaged frames |
| Frame buffer and zoom column memory in one 4,096 x 36 memory | -4 | about +100 | address selection on the context's slowest path; a few more dropped zoom samples |
| Column and K-frame memories as floating-point words, zoom context | -4 | about +1,500 | values to 0.004 dB, not exact; the shared walk engine changes |
| The same for the whole-band context (and its arrival queue 53 -> 30 bits) | -7 | about +1,500 | as above |
| Frame buffer in DDR3 | -8 | about +400 | a write and a read client on the arbiters |
| Whole-band view 4,096 points through the same shared FFT | -17 | about -3,000 | bin 18.75 kHz instead of 4.69 kHz: fewer bins than columns |

Cells that could still go:

| What | Cells | Cost |
|---|---|---|
| Fixed CIC: the 9 combs of 48 bits per channel through one adder with LUT-RAM state (a zoom copy of `rx_cic_fixed`) | about -2,000 | 9 subtractions in the 10 clocks between samples: needs two overlapping passes |
| Giving up the 3.072 MHz span: fixed CIC 5 stages instead of 9; half-band with one multiplier pair | about -2,400, -2 DSP, -2 block RAM | a feature; owner decides |
| Narrow CIC into the new serial CIC (one engine for both) | about -800 | its 16-bit rounding in between must stay for equal words |
