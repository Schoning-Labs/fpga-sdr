<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# F3: zoom DDC + 4k complex FFT

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Work package F3 in [PLAN.md](PLAN.md); system context in [ARCHITECTURE.md](ARCHITECTURE.md) section 3.4.
Owner decisions are in [DECISIONS.md](DECISIONS.md) and are not reopened here.

**Status: alias rejection does not yet fully meet the >= 80 dB target at every span** (worst
measured case: 75.9 dB at the widest span). Section 3 has the full story, the numbers, and what is
needed to close the last few dB. Everything else in this WP (bin placement, passband flatness,
resource estimate) is complete and verified.

## 1. What this is

Tunes a zoom centre anywhere in the ADC's 0-38.4 MHz Nyquist and decimates down to one of seven
spans, 48 kHz to 3.072 MHz in powers of two, then runs a 4,096-point complex FFT over the result --
the "zoom" spectrum view alongside the full-band 0-30 MHz view (F1/F2). Same building blocks as one
receiver channel (`rtl/rx/rx_channel.v`: NCO mixer, then CIC decimation, then a final decimating
FIR -- see [RX_DSP.md](RX_DSP.md)), but its own decimation plan and its own anti-alias/compensation
filters, window and FFT:

```
ADC 76.8 Msps -> nco_mixer (mix to the zoom centre, sign-corrected -- section 5)
              -> cic_fixed (STAGES=9, DECIMATION=10, fixed)     -> 7.68 Msps
              -> cic_var_pow2 (STAGES=11, decim=2^span_shift)   -> 2x the final rate
              -> zoom_fir_half (decimate-by-2, anti-alias FIR)  -> final internal rate
              -> zoom_cic_comp (droop compensation, no decimation)
              -> zoom_window (4,096-point Blackman-Harris)
              -> fft_r22sdf (LOG_N=12, IW=17, REAL_IN=0)        -> one complex bin per cycle
```

**Revision history of this WP**: the first version of this file stopped after the two CIC stages
(span = the raw CIC-decimated rate, full Nyquist displayed). An owner review found that version's
worst-case alias rejection (about 24 dB) unacceptable for a panadapter -- a strong signal just
outside the displayed view would appear as a ghost only 24 dB down. This version adds
`zoom_fir_half.v` (a real anti-alias filter) and `zoom_cic_comp.v` (passband flattening), and only
displays the central 80% of the FFT's bins (the part `zoom_fir_half.v` actually protects). Section 3
has the current, honest state of that fix.

New files:

| File | What |
|---|---|
| `rtl/zoom/cic_var_pow2.v` | variable CIC, decimation restricted to powers of two (1..64), selected by a 3-bit shift |
| `rtl/zoom/zoom_fir_half.v` | 63-tap decimate-by-2 anti-alias FIR, symmetry-folded to 32 unique multiplies/channel |
| `rtl/zoom/zoom_cic_comp.v` | 15-tap, non-decimating CIC-droop compensation filter, 7 per-span coefficient sets |
| `rtl/zoom/zoom_ddc.v` | `cordic_mixer` + `cic_fixed` + `cic_var_pow2` + `zoom_fir_half` + `zoom_cic_comp`: the zoom DDC |
| `rtl/zoom/zoom_window.v` | 4,096-point Blackman-Harris window, applied before the FFT |
| `rtl/zoom/zoom_spectrum.v` | top level: `zoom_ddc` -> `zoom_window` -> `fft_r22sdf`, plus `out_usable` |
| `rtl/zoom/zoom_window_coeffs.hex` | window ROM, written by `tools/gen_zoom_window.py` |
| `rtl/zoom/zoom_fir_half_coeffs.hex` | anti-alias FIR ROM, written by `tools/gen_zoom_fir_coeffs.py` |
| `rtl/zoom/zoom_cic_comp_coeffs.hex` | 7 sets of compensation coefficients, written by `tools/gen_zoom_cic_comp_coeffs.py` |
| `hw/regmap/zoom.toml` | draft register block at `0xE806_0000` (phase_inc, enable, span_shift) |
| `tools/gen_zoom_window.py`, `tools/gen_zoom_fir_coeffs.py`, `tools/gen_zoom_cic_comp_coeffs.py` | coefficient generators |
| `tools/analyze_zoom_alias.py` | analytical worst-case alias-rejection calculator, full cascaded chain (see section 3) |
| `sim/zoom/tb_zoom_quick.v` | quick done-test, run by `tools/check.sh` |
| `sim/zoom/zoom_bin48_sim.v` | the literal done-test (48 kHz span, 1 kHz offset), run by `sim/zoom/run_sim.sh` |
| `sim/zoom/zoom_alias_sim.v` | alias-rejection measurement across all seven spans, run by `sim/zoom/run_sim.sh` |
| `sim/zoom/yosys_gw5a.ys` | resource estimate |

Reused unchanged: `rtl/rx/nco_mixer.v` (the CORDIC mixer `rtl/rx/cordic_mixer.v` until WP RB4,
section 8.2), `rtl/rx/cic_fixed.v`, `rtl/rx/cic_integrator.v`,
`rtl/rx/cic_comb.v` (see [RX_DSP.md](RX_DSP.md)), `rtl/fft/fft_mul.v` (the FFT's own registered
signed multiplier, reused here so a resource estimate counts `zoom_fir_half`/`zoom_cic_comp`'s
multiplies as DSP blocks rather than yosys mapping bare `*` operators into LUT fabric), and
`rtl/fft/fft_r22sdf.v` in its complex-input mode (`REAL_IN=0`), already exercised at `LOG_N=12,
IW=17` by `sim/fft/tb_fft_r22sdf_cplx.v` ([F1_FFT.md](F1_FFT.md)).

**Hand-off to F2**: output is at FFT-bin level, matching F1's own interface convention exactly
(`out_valid`, `out_first`, `out_bin` already bit-reverse-corrected to the natural frequency bin,
unscaled complex DFT on `out_re`/`out_im`, plus a new `out_usable` flag -- section 6). WP F2 (branch
`f2-spectrum`, not yet merged into `master` as of this work) builds the full-band pipeline's
window/power/dB/column-mapping/averaging/peak-hold/waterfall stages; this module does not depend on
that branch and does not duplicate any of it. A future zoom-spectrum equivalent of F2 consumes this
module's raw complex bin stream the same way F2 consumes F1's, and should skip bins where
`out_usable` is low.

## 2. Decimation plan

`cic_var_pow2.v` is `cic_var.v` (docs/RX_DSP.md section 2's variable CIC) restricted to decimation
values that are exact powers of two, so the DC-gain bit-select is computed directly
(`growth(shift) = STAGES * shift`, no `ceil()`) instead of `cic_var.v`'s per-value case table.
`shift = 0` (decimation 1) is the identity function.

`cic_fixed`'s decimation changed from an earlier version's 25 to **10** (the same value
`rx_channel.v`'s own `cic_fixed` uses), and `zoom_fir_half` takes a final factor of 2, so the total
chain is `10 * 2^shift * 2 = 20 * 2^shift`. Combined with showing only the **central 80%** of the
resulting FFT bins (`USABLE_FRACTION` in `tools/gen_zoom_fir_coeffs.py` and
`tools/gen_zoom_cic_comp_coeffs.py`, and `out_usable` in `zoom_spectrum.v` -- section 6), this lands
the *displayed* span exactly on the seven round numbers PLAN WP F3 names, 48 kHz to 3.072 MHz, while
the FFT itself runs at a slightly wider *internal* rate (up to 3.84 MHz at the widest span) so the
outer 20% of bins can be safely discarded instead of displayed.

**CIC order**: `rx_channel.v` uses `STAGES=3`/`STAGES=5` because its downstream `fir_decim` supplies
additional rejection at every rate. The zoom path's own anti-alias FIR (`zoom_fir_half.v`) plays
that role here, but at the widest span `cic_var_pow2` does not decimate at all (shift=0, identity),
so `cic_fixed` alone stands between the display and its alias there. Both stages ended up at
**`STAGES=9`** (`cic_fixed`) and **`STAGES=11`** (`cic_var_pow2`) after several rounds of measuring
the actual combined chain (section 3) and raising order for margin; both are free in DSP/BSRAM terms
(confirmed in section 7: `zoom_ddc`'s own two CIC stages contribute zero DSP multipliers), the same
"CIC order is cheap" property [RX_DSP.md](RX_DSP.md) section 8 notes for `cic_fixed`.

## 3. Alias rejection within the displayed span

**Status: the widest span (3.072 MHz) measures 75.9 dB, short of the 80 dB target; every other span
measures 81.9 dB or better.** This section states the numbers plainly, explains the (now understood)
root cause of the shortfall, and what was tried.

### 3.1 Method

Alias rejection is judged against the **central 80% of the displayed FFT bins** (section 2), not the
whole decimated Nyquist a first version of this WP used. `tools/analyze_zoom_alias.py` computes the
analytical worst case by scoring every candidate ADC-domain frequency against the **full cascaded
chain** (`cic_fixed` response at that frequency, plus `cic_var_pow2`'s response at the frequency that
folds to, plus `zoom_fir_half`'s response at the frequency that folds to next), restricted to
candidates whose final landing frequency actually falls inside the displayed 80% -- an earlier
version of this script scored each stage's own worst case independently and took the minimum, which
is wrong (a frequency bad for one stage is not necessarily bad for the others; see that script's own
docstring for the specific case this missed).

`sim/zoom/zoom_alias_sim.v` (run via `sim/zoom/run_sim.sh`) measures the real RTL: a full-scale (0
dBFS) interferer at the analytically-worst frequency per span, zoom DDC tuned to baseband, peak
`|I+jQ|` of the production 16-bit output over a settled window, compared against a calibrated
on-tune reference. Two details this needed, both confirmed empirically while building it:

- **A real ADC tone is inherently dual-sideband** (`cos(wt) = 0.5(e^{jwt}+e^{-jwt})`); both mirror
  images fold through the chain and can add with an arbitrary relative phase, up to +6 dB
  (2x amplitude) worse than a single-tone analytical number in the worst case. The test tracks the
  **peak** over a settled window (not one snapshot) specifically to catch that worst case, which is
  also the physically meaningful number for "how far down could an operator see a ghost."
- **The transient before a CIC settles scales with decimated samples, not ADC clocks**: at
  `STAGES=9`/`11`, several dozen decimated samples are needed before the CIC's own startup transient
  fully decays, which is a very different number of *ADC clocks* at the widest span (fast
  decimation) than the narrowest (slow decimation). The test's settle window and skip are both
  scaled by each span's own total decimation for this reason.

### 3.2 Results

Analytical prediction, full cascaded chain (`python tools/analyze_zoom_alias.py`):

| displayed span | worst combined (ideal arithmetic) | interferer (ADC-domain) | lands at |
|---|---|---|---|
| 3,072.00 kHz | 112.8 dB | 6.1441 MHz | -1,535.93 kHz |
| 1,536.00 kHz | 116.6 dB | 1.1867 MHz | -733.34 kHz |
| 768.00 kHz | 117.1 dB | 0.5933 MHz | -366.72 kHz |
| 384.00 kHz | 117.3 dB | 0.2967 MHz | -183.31 kHz |
| 192.00 kHz | 117.3 dB | 0.1483 MHz | -91.71 kHz |
| 96.00 kHz | 117.3 dB | 0.0741 MHz | -45.87 kHz |
| 48.00 kHz | 117.3 dB | 0.0371 MHz | -22.93 kHz |

Measured (`sim/zoom/zoom_alias_sim.v`, production 16-bit output, peak over a settled window):

| displayed span | measured | predicted | vs. 80 dB target |
|---|---|---|---|
| 3,072.00 kHz | **75.9 dB** | 112.8 dB | **below target** |
| 1,536.00 kHz | 81.9 dB | 116.6 dB | meets target |
| 768.00 kHz | 81.9 dB | 117.1 dB | meets target |
| 384.00 kHz | 81.9 dB | 117.3 dB | meets target |
| 192.00 kHz | 81.9 dB | 117.3 dB | meets target |
| 96.00 kHz | 81.9 dB | 117.3 dB | meets target |
| 48.00 kHz | 81.9 dB | 117.3 dB | meets target |

**Worst measured rejection across all seven spans: 75.9 dB, at the widest (3.072 MHz) span.**

### 3.3 Root cause of the measured-vs-predicted gap

The ~35-40 dB gap between the analytical prediction (112.8-117.3 dB) and the measurement is **not**
a flaw in the filter shapes -- it is a **word-width limitation of this specific RTL
implementation**. `cic_fixed`, `cic_var_pow2` and `zoom_fir_half` each round their output to 16 bits
between stages (the same width `rx_channel.v` uses for its own equivalent internal signals). Each
16-bit rounding reintroduces quantization noise at roughly -88 dBFS (1 LSB of a signal near full
scale); that noise, once it becomes the *next* stage's input, is not an alias for that stage to
reject -- it is just in-band noise, which a low-pass stage passes through close to unattenuated.
Cascading three such 16-bit roundings caps the *whole chain's* achievable rejection at roughly
76-82 dB regardless of how deep any individual filter's stopband was designed to go -- consistent
with all six passing spans converging on almost exactly the same 81.9 dB ceiling, and the widest
span (where `cic_fixed` alone, with the least margin of the three stages at that span, sets the
floor) landing a few dB lower.

This was diagnosed by directly probing `cic_fixed`'s and `zoom_fir_half`'s own 16-bit outputs during
the interferer test: both showed nothing but +/-1-2 count values (i.e. already at their own
rounding floor) rather than a clean, much smaller residual, confirming the bottleneck is
this rounding, not a design defect in the filters themselves.

**Attempted fix, reverted**: widening the intermediate stage width from 16 to 24 bits (matching
`rx_channel.v`'s own *final* receiver output width, `out_i[23:0]`/`out_q[23:0]`) is the standard fix
and was implemented (only the very last stage, `zoom_cic_comp`, still rounds to 16 bits for
`zoom_window.v`). It compiled cleanly and an isolated test of the widened `cic_var_pow2` confirmed
correct behaviour once given enough settling time. However, a full-chain test with a real tone
showed the DDC's output failing to settle into a clean sinusoid even after the expected transient
window -- a second, unexplained interaction between the wider accumulators and `STAGES=11` that
was not root-caused within this work package's time. Rather than ship an unverified change, this
was reverted; the RTL in this repository is the known-good, 16-bit-stage version measured above.

**Next step to close the gap**: re-attempt the intermediate width increase with more time to isolate
the new instability (a good starting point: bisect which of `cic_fixed`, `cic_var_pow2`,
`zoom_fir_half` first produces a non-clean output when only *that one* stage is widened, rather than
widening all three at once as this attempt did).

## 4. Passband flatness (CIC-droop compensation)

Without `zoom_cic_comp.v`, the CIC stages' own passband droop reaches 4-5.2 dB at the edge of the
displayed band (measured analytically) -- an order of magnitude over the owner's 0.5 dB flatness
target, because `cic_fixed`'s droop shape (significant only at the widest span, where
`cic_var_pow2` does not decimate at all) and `cic_var_pow2`'s droop shape (dominant at every other
span, and nearly span-independent there) do not resemble each other closely enough for one static
equalizer curve to flatten both -- an early attempt at a single shared compensation curve left the
widest span about 1.2 dB off. `zoom_cic_comp.v` instead stores **seven** compensation coefficient
sets (one per span, `tools/gen_zoom_cic_comp_coeffs.py`, each matched to that span's own exact
combined droop shape via `scipy.signal.firls`), selected by `span_shift` -- this costs only
coefficient ROM (small, LUT RAM/BSRAM), not extra DSP multipliers, regardless of how many span sets
are stored.

Residual flatness after compensation, quantized (18-bit) coefficients, all seven spans:

| span_shift | 0 | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|---|
| max deviation from flat | 0.0042 dB | 0.0046 dB | 0.0047 dB | 0.0053 dB | 0.0048 dB | 0.0049 dB | 0.0053 dB |

Comfortably within the 0.5 dB target at every span, with about 100x margin.

## 5. Frequency-to-bin sign convention (fixed in this module)

The mixer's `frequency` input (the HL2/openHPSDR CORDIC's convention, kept by the NCO mixer that
replaced it in WP RB4; shared with the receiver bank) puts a tone **above** the tuned centre at the **mirror** bin (`N - bin`) instead of
directly above it -- confirmed empirically while building `sim/zoom/tb_zoom_quick.v`. That
convention is counter-intuitive for a spectrum display specifically (a receiver only ever cares
about one frequency, so the sign never mattered for `rx_channel.v`'s own tests), so **`zoom_ddc.v`
negates `phase_inc` before it reaches the mixer** -- fixed HERE ONLY, not in
`rtl/rx/nco_mixer.v` itself, so `rx_channel.v`'s behaviour is untouched. With this fix,
`zoom_spectrum`'s own `phase_inc` input has the intuitive meaning: a tone above the tuned centre
lands at the bin above centre, matching what firmware and any display code would naturally expect.

## 6. Displayed bins (`out_usable`)

`zoom_spectrum.v` exposes `out_usable`, a 1-bit flag alongside every `out_bin`/`out_re`/`out_im`
word: high when that bin is within the alias-protected, displayed central 80% (`out_bin <= 1,638` or
`out_bin >= 2,458` of the 4,096, accounting for the FFT's bin-0-centred wraparound convention) --
3,277 of 4,096 bins, 80.0% almost exactly. The outer 20% are still valid FFT output (not garbage),
just not alias-protected to the target level; a future averaging/dB/waterfall consumer should simply
not draw them, the same way it would not draw bins beyond the full-band FFT's own Nyquist.

## 6.1 WP RB6: the zoom averaging/dB/waterfall backend

Section 1's "Hand-off to F2" note said a future averaging/dB/waterfall stage for the zoom stream
would consume this module's raw complex bin stream the way `docs/F2_SPECTRUM.md`'s full-band
pipeline consumes F1's FFT output. WP RB6 built that stage (`docs/ARCHITECTURE.md` section 3.14
change C6d) -- inside `rtl/spectrum/spectrum_pipeline.v`, not a new file here, because it shares
its expensive arithmetic (the log-domain K-average and the leading-one/LUT log2 estimator) with
the full-band spectrum's own walk engine through one `rtl/spectrum/spectrum_walk_core.v` instance,
rather than duplicating it. Full design notes, the bin -> column mapping for this module's own
3,277 usable bins, the bugs found while building it and its own done-test are all in
`docs/F2_SPECTRUM.md` "WP RB6: log-domain average, window ROM interpolation, single buffer, shared
zoom backend" -- not repeated here to avoid the two documents drifting apart on one shared design.
This module (`zoom_spectrum.v`, its DDC and its FFT) is unchanged by that work: it still stops at
`out_valid`/`out_first`/`out_bin`/`out_usable`/`out_re`/`out_im`, now consumed by
`spectrum_pipeline.v`'s `zoom_in_*` ports instead of only by a testbench.

The zoom backend's own registers (`backend_averaging_k`, `backend_level`, `backend_line_count`,
`backend_line_status`, and two new bits in `ctrl`) were added to this module's own register page,
`hw/regmap/zoom.toml` -- the "averaging/dB/waterfall registers ... not drafted here" the top of
that file used to say before this WP.

## 7. Test results

### 7.1 Quick (done-test mechanism check, `tools/check.sh`)

`sim/zoom/tb_zoom_quick.v`: widest span (`span_shift=0`), a tone at an exact bin offset (45 kHz = 48
bins at the full internal rate of 3.84 MHz) above an arbitrary 10 MHz zoom centre.

| | Result | Pass limit |
|---|---|---|
| Peak bin | **48** (expected 48) | exact match |
| Peak vs. best bin outside its own main lobe (+/-8 bins) | **2.629e14 vs 7.83e4** (about 105 dB) | >= 6 dB |
| Frame capture | 4,096/4,096 words | exact |

Runtime: about 30 s (iverilog).

### 7.2 Full literal done-test (`sim/zoom/run_sim.sh`)

`sim/zoom/zoom_bin48_sim.v`: the literal WP F3 done-test -- 48 kHz displayed span (`span_shift=6`,
total decimation 1,280), a tone 1 kHz above an arbitrary 7.1 MHz zoom centre (expected bin
`round(1000 / (60000/4096)) = 68`, using the FFT's full 60 kHz internal rate, not the 48 kHz
displayed span). Not re-run to completion in this work (about 20-30 minutes each run); the
mechanism is identical to 7.1's quick test, which passes, and to the pre-fix version of this same
test, which also passed at its own (different) expected bin. Re-running this before relying on it
for a release is recommended.

## 8. Resources (estimate from yosys, not place-and-route)

`sim/zoom/yosys_gw5a.ys`: yosys 0.69, `synth_gowin -family gw5a`, top = `zoom_spectrum`. `fft_mul`
kept as a black box (yosys does not map multipliers to GW5A DSP blocks), so each instance is counted
as one 27x18-class DSP multiplier; the CORDIC/CIC stages have no `*` operator anywhere in their RTL
(pure shift/add), so they contribute zero DSP multipliers.

| Resource | `zoom_spectrum` total | Share of GW5AST-138 |
|---|---|---|
| DSP multipliers | 114 | 298 DSP blocks: 38.3% |
| Block RAM (18 kbit primitives) | 17 | 340: 5.0% |
| LUT RAM (RAM16SDP4) | 48 | |
| LUT (LUT1-LUT4) + MUX2 | 17,651 + 6,883 = 24,534 | 138,240: 17.8% |
| Carry-chain adder bits (ALU) | 10,950 | |
| Registers | 16,882 | 138,240: 12.2% |

Breakdown by sub-block (separate yosys runs):

| Sub-block | DSP | Notes |
|---|---|---|
| `zoom_ddc`'s two CIC stages (CORDIC + `cic_fixed` + `cic_var_pow2`, I and Q) | 0 | pure shift/add, confirms section 2's "CIC order is free" claim |
| `zoom_fir_half` (63 taps, symmetry-folded to 32 unique multiplies/channel) | 64 | half of the naive 2x63=126, via Type-I linear-phase tap pairing |
| `zoom_cic_comp` (15 taps x 2 channels, not symmetry-folded) | 30 | small enough that folding it too was not worth the added complexity |
| `fft_r22sdf` (LOG_N=12, IW=17, complex) | 20 | unchanged from before this WP's alias-rejection fix |

114 of 298 DSPs (38.3%) is comfortably inside a "roughly half the device already committed"
budget. `zoom_fir_half`'s symmetry folding (halving 126 DSPs to 64) was worth doing specifically to
fit that budget; `zoom_cic_comp` was left unfolded since even its full 30 DSPs did not threaten it.

Timing at 150 MHz is **not** checked yet: no Gowin place-and-route until the Standard licence
(PLAN WP T1).

**Superseded by section 8.1**: `zoom_fir_half` and `zoom_cic_comp` are no longer the parallel
designs measured above -- PLAN WP RB1 time-multiplexed both. The numbers in this section 8 are kept
as the historical record of what the first (parallel) version of this WP measured; section 8.1 has
the current numbers.

## 8.1 PLAN WP RB1: zoom FIRs time-multiplexed

Change C7 in `docs/ARCHITECTURE.md` section 3.14: `zoom_fir_half` and `zoom_cic_comp` each moved
from computing every folded tap in parallel (64 and 30 DSP respectively) to ONE multiplier per
channel (2 DSP each, 4 total), a `sim/zoom/ref/`-kept copy of the old parallel RTL serving only as
the word-for-word test reference described below. Branch `rb1-zoomfir`.

**Why this needed more than "just serialize the multiply"**: `adc_valid` arrives in HL2-frame
bursts (a whole 5,968-sample frame on consecutive clocks, section 3.2), during which the input rate
to these filters doubles and a one-multiplier engine (needing about 32 clocks per job for the
half-band, 15 for the compensator) falls behind by up to about 240 samples per frame -- caught up in
the roughly 49% average idle gap before the next frame. So the tap delay line in each filter is not
a fixed-depth shift register but a **circular buffer** deep enough to double as that backlog queue
(at least 63 + 256 = 319 samples for the half-band, 15 + 256 = 271 for the compensator; both rounded
up to 512, one BSRAM's worth of depth) -- new samples are simply written further ahead of the serial
engine's own read index without being overwritten before their turn comes.

**The one subtlety that cost the most debugging time**: the old parallel RTL decided which samples
to KEEP (the half-band decimates by 2) with a `phase` register toggled by `in_strobe` and checked two
CLOCK CYCLES later -- not two SAMPLES later. Those only coincide if `in_strobe` pulses are spaced
exactly one clock apart forever, which was true of every test this WP had before RB1 (the old design
had no throughput limit, so nothing ever needed to know, in the abstract, "which sample indices are
kept"). Once real spacing varies -- which any serial engine's very existence requires -- assuming
"every even sample index is kept" is simply wrong (confirmed by direct comparison against the
reference RTL: correct at one clock spacing, wrong at another). The fix was to not guess: a small
shadow copy of that exact `phase`/`phase_d1`/`phase_d2` pipeline runs alongside the serial engine,
decoupled from it by a small FIFO of pending write-indices, so the new RTL keeps precisely the same
samples the old one would have, regardless of timing.

**Done-test results**:

| Test | Result |
|---|---|
| `sim/zoom/tb_zoom_quick.v` (part of `tools/check.sh`; stimulus changed to a steady ~50% `adc_valid` duty -- see that file's own header for why a continuous, gap-free drive is not a condition either design needs to sustain forever) | PASS: peak bin 48, peak magnitude and the next-highest bin's magnitude both bit-identical to the parallel reference (2.629e14 and 7.833e4) |
| `sim/zoom/zoom_rb1_compare_sim.v` (steady ~50% duty, full first FFT frame, word for word against `sim/zoom/ref/`) | PASS: 0 / 4,096 words differ |
| `sim/zoom/zoom_rb1_burst_sim.v` (whole 5,968-sample HL2 frames on consecutive clocks, 51% average duty, widest span, full first FFT frame, word for word against `sim/zoom/ref/`) | PASS: 0 / 4,096 words differ |

**Resources** (`tools/yosys_res.sh zoom_spectrum`, the project's current resource-ledger tool --
ARCHITECTURE.md 3.14 -- rather than this file's own older `sim/zoom/yosys_gw5a.ys`, which does not
count multipliers or logic the same way):

| Resource | Before RB1 (parallel) | After RB1 | RB1 target |
|---|---|---|---|
| DSP multipliers | 114 | **26** (4 of them the two FIRs; 20 unchanged in `fft_r22sdf`, 2 unchanged in `zoom_window`) | at most 26 |
| Logic (LUT1-4 + ALU + 6 x RAM16SDP4) | 29,747 | **15,741** | at most 15,500 |
| Block RAM (18 kbit primitives) | 17 | 22 | not limited by the done-test |

DSP and the word-for-word tests are within target. Logic is **241 above target (1.6%)**. Both new
filters are lean on their own (`zoom_fir_half` 452, `zoom_cic_comp` 469 logic, measured standalone --
together barely a third of one percent of the chip): the shortfall is almost entirely in the
`cordic_mixer` + two CIC stages underneath them (measured together with the new filters as
`zoom_ddc`: about 9,055 of the 9,976 logic there is the CORDIC/CIC, unchanged by this WP) plus
`zoom_window`/`fft_r22sdf` (about 5,765, also unchanged) -- both already above the level the
ARCHITECTURE.md C7 sketch assumed when it set this WP's 15,500 target, and neither is in this WP's
scope: replacing the CORDIC with an NCO mixer is PLAN WP RB4, a separate, later change. Two
optimizations specific to this WP's own new RTL are already folded into the 15,741 figure and are
worth naming since they were the difference between comfortably meeting budget and missing it by a
lot:

- `zoom_cic_comp`'s per-span coefficient reload (`active_coeff`) used to update all 15 taps in the
  same clock, each independently reading `coeff[span_shift*TAPS + k]` -- a 7-way dynamic-address mux
  repeated per tap, measured at about 3.4k logic for a reload path that only ever runs when the
  operator changes span (never in the sample-rate loop). Reloading serially instead, one tap per
  clock over 15 clocks, needs one dynamic read address instead of fifteen; saved about 3.4k logic
  for a cost of, at most, 15 clocks of stale coefficients immediately after a span change (invisible
  to every done-test here, which holds span fixed for its whole run).
- `zoom_fir_half`'s folded coefficient ROM is sized to exactly the 32 entries it ever reads (not the
  full 63), and the index register that addresses it is sized to exactly 5 bits (not a wider,
  round-number width) -- so synthesis can prove the other half of the ROM is unreachable instead of
  needing to be told.

Given the done-test's own resource script is explicitly a synthesis-only estimate (no Gowin
place-and-route exists yet, PLAN WP T1) and the shortfall sits almost entirely in logic this WP does
not touch, 241 logic units over target is reported here rather than chased further; PLAN WP RB4 (the
CORDIC-to-NCO change, `docs/ARCHITECTURE.md` change C1) is the natural place to close this gap, since
it specifically targets the block responsible for most of it.

## 8.2 PLAN WP RB4: NCO mixer instead of the CORDIC

`zoom_ddc.v`'s mixer is now `rtl/rx/nco_mixer.v` (receive mode), the same design as the receiver
bank's (`docs/RX_DSP.md` section 10: table, Taylor correction, 4 DSP, 1 BSRAM). Same gain,
sign convention (the negation in section 5 is unchanged) and 18-bit output as the CORDIC.

- Alias rejection, `sim/zoom/zoom_alias_sim.v`, CORDIC (`master`) against NCO, same test on the same
  day: widest span 79.6 dB both, the other six spans 83.2 dB both: **unchanged**. (This test
  now reads 79.6 / 83.2 dB on `master` too, above the 75.9 / 81.9 dB of section 3's table, which
  was measured before later changes to the filters.)
- `sim/zoom/tb_zoom_quick.v`, and the RB1 word-for-word checks (`zoom_rb1_compare_sim.v`,
  `zoom_rb1_burst_sim.v`, whose reference `sim/zoom/ref/zoom_ddc_ref.v` now instantiates the same
  NCO mixer) pass: 0 of 4,096 words differ.
- Resources, `tools/yosys_res.sh zoom_ddc`: 8 DSP, 6 BSRAM, 7,014 logic (CORDIC: 4 DSP, 5 BSRAM,
  9,976 logic): -2,962 logic, +4 DSP, +1 BSRAM.

## 9. Known limitations / not done

- **WP RB6's own literal done-test through the real DDC and FFT
  (`sim/zoom/zoom_backend_full_sim.v`) did not finish in this work.** It needs on the order of
  an hour (twice `sim/zoom/zoom_bin48_sim.v`'s own already-long 20-30 minutes, since it adds noise
  and averages K = 2 frames instead of one bare tone), and the machine had several other long
  Verilog/yosys/Gowin runs competing for the same CPU at the same time; after more than two hours
  it was killed, still running, to let `tools/check.sh` finish instead. The fast equivalent that
  does run in this work, `sim/zoom/tb_zoom_backend_quick.v` (part of `tools/check.sh`), injects
  synthetic bin values directly rather than decimating real ADC samples and passed every check
  (docs/F2_SPECTRUM.md "Zoom backend done-test"); re-running the literal version to completion,
  ideally on an otherwise idle machine, is recommended before relying on it for a release, the same
  recommendation this file already makes for `zoom_bin48_sim.v` itself below.
- **Alias rejection at the widest span (3.072 MHz) measures 75.9 dB, below the 80 dB target**
  (section 3). Root cause identified (16-bit inter-stage rounding) and a fix attempted (widening to
  24 bits) but reverted after it exposed a second, unresolved issue. This is the one open item this
  WP did not finish; every other span already measures 81.9 dB or better. **Not re-attempted during
  PLAN WP RB1**: RB1's own scope (time-multiplexing the two FIRs, section 8.1) was substantial enough
  on its own that widening one stage's word length -- a separate, already-once-reverted change this
  file's own "next step" note says needs isolating which of three stages first goes unstable when
  widened alone, with real simulation time to do that isolation -- was not attempted alongside it.
  Left for a dedicated pass.
- `sim/zoom/zoom_bin48_sim.v` (the literal 48 kHz/1 kHz-offset done-test) was not re-run to
  completion after this work's changes (each run is 20-30 minutes); it passed before this work's alias-rejection work began, with the *lands-in-the-right-bin* mechanism unchanged by
  that work, but re-running it is recommended before relying on it for a release.
- **Frequency-to-bin sign convention** (section 5) needs to be respected by firmware/display code
  building on this module -- it is fixed in `zoom_ddc.v` specifically, not in `rtl/rx/nco_mixer.v`,
  so `rx_channel.v`'s own behaviour (and every receiver-bank test that depends on it) is untouched.
- Real Gowin place-and-route (timing closure, actual DSP/BSRAM mapping) was not run -- section 8 is
  a plausibility estimate from generic synthesis, not a signed-off result, same caveat as every
  other WP before PLAN WP T1's licence.
- `hw/regmap/zoom.toml` is `status = "draft"`: the register layout is this WP's own proposal
  (phase_inc, enable, span_shift), matching what `zoom_ddc.v`/`zoom_spectrum.v` actually expose, but
  not yet wired to a real register port (no `reg_wr`/`reg_addr` interface exists on these modules
  yet -- PLAN F3 did not ask for one).
- `zoom_cic_comp`'s 15-tap filter was not symmetry-folded (unlike `zoom_fir_half`'s 63-tap filter) --
  its 30 DSPs did not threaten the resource budget, so the extra complexity was not worth it, but
  folding it would save about 14 more DSPs if ever needed.

## 10. How to run

Quick (part of `tools/check.sh`, about a minute since PLAN WP RB1 -- `tb_zoom_quick.v`'s own header
explains why its `adc_valid` stimulus now runs at a steady ~50% duty instead of every clock, roughly
doubling its wall-clock cost):
```sh
bash tools/check.sh                                              # runs every tb_*.v, including this WP's
iverilog -g2012 -o /tmp/zq.vvp sim/zoom/tb_zoom_quick.v && vvp /tmp/zq.vvp
```

Full (not part of `check.sh`; the 48 kHz literal case alone is 20-30 minutes, the two PLAN WP RB1
word-for-word checks against the parallel reference RTL add another 2-3 and about 10 minutes):
```sh
cd sim/zoom
./run_sim.sh
```

Individual steps:
```sh
python tools/gen_zoom_window.py                        # rtl/zoom/zoom_window_coeffs.hex
python tools/gen_zoom_fir_coeffs.py                     # rtl/zoom/zoom_fir_half_coeffs.hex
python tools/gen_zoom_cic_comp_coeffs.py                # rtl/zoom/zoom_cic_comp_coeffs.hex
python tools/analyze_zoom_alias.py                      # zoom_alias_config.vh (full cascaded chain)
iverilog -g2012 -o /tmp/za.vvp sim/zoom/zoom_alias_sim.v && vvp /tmp/za.vvp    # ~5-6 min
iverilog -g2012 -o /tmp/zb.vvp sim/zoom/zoom_bin48_sim.v && vvp /tmp/zb.vvp    # ~20-30 min
yosys -s sim/zoom/yosys_gw5a.ys | tail -60              # resource estimate, about 3 minutes
```
