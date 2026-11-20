<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# X1: TX chain

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Work package X1 in [PLAN.md](PLAN.md); design context in [ARCHITECTURE.md](ARCHITECTURE.md)
section 3.6. Branch `x1-tx`, worktree `G:/proj/worktrees/fpga-sdr-x1-tx`.

## Scope

This WP builds the TX DSP datapath: a ring reader port, a FIR interpolator (x4), a CIC
interpolator (x400), an up-mixer (the HL2's CORDIC until WP RB4, now the NCO mixer
`rtl/rx/nco_mixer.v`, see "RB4" below), and a final round/saturate stage producing a 12-bit
sample at 76.8 Msps. Two things named in section 3.6 are out of scope here, left to WP H2 (which
needs the HL2 link WP H1, and this WP does not):

- the real `pace` strobe from the HL2 link (bursty within a 150 MHz `clk_dsp`, mirroring the
  receiver bank's `adc_valid` on branch `rx-dsp`) and the one-sample-per-`adc_valid` rate lock /
  TX FIFO fill trim;
- the DDR3 ring itself (address generation, cache write-back). The ring reader port here
  (`bb_i`/`bb_q`/`bb_valid`/`bb_req`) is a plain FIFO-style read interface that a real ring
  reader can drive without changing this module.

Nothing here touches the real HL2: the testbench is pure simulation, no register writes, no key
bit, no DAC.

## Block diagram

```
 DDR3 ring (WP H2, not this WP)
       |
       v
 +-----------+   bb_req    +----------------+  cic_req   +----------------+  cic_i/q    +--------+
 | ring      |------------>| FIR interp x4  |----------->| CIC interp x400|------------>|  NCO   |
 | reader    |  bb_i, bb_q | 48k -> 192k     |  fir_i,fir_q| 192k -> 76.8M | (real, imag)| up-mix |
 | (FIFO     |<------------| 40 taps,       |<------------| 5-stage,      |             |        |
 |  port)    |             | 10/phase       |             | R=400         |             |        |
 +-----------+             +----------------+             +----------------+             +---+----+
      int16 I/Q                20-bit I/Q                     24-bit I/Q                     |
                                                                                    round + saturate
                                                                                    to 12 bits, gain
                                                                                    shift, zero on
                                                                                    !enable or trip
                                                                                               |
                                                                                               v
                                                                                     out_data[11:0] @ pace
```

`rtl/tx/tx_chain.v` is the top module; `rtl/tx/tx_fir_interp4.v` (new), `rtl/tx/CicInterpM5.v`
(reused from the HL2, see "Reuse" below) and `rtl/rx/nco_mixer.v` (WP RB4, shared with the
receivers; it replaced the HL2's `cpl_cordic.v`) are the stages.

One output sample is produced per pulse of a `pace` input (one clock cycle each, generically:
this module has no notion of wall-clock time, only of how many samples have gone by). The
done-test testbench ties `pace` high and clocks at 76.8 MHz directly, which is equivalent for
this module (see "How the testbench paces the chain" below); WP H2 will drive it from the real
150 MHz `clk_dsp` with a bursty `adc_valid`-style strobe.

## Bit widths

| Signal | Width | Notes |
|---|---|---|
| ring baseband I/Q (`bb_i`/`bb_q`) | 16, signed | int16, one format for every TX mode (A 3.6.1) |
| FIR output (`fir_i`/`fir_q`) | 20, signed | 4 extra bits of precision over the 16-bit input |
| CIC output (`cic_i`/`cic_q`) | 24, signed | kept wide (see "gain and headroom" below) |
| mixer output (`mix_out`) | 31, signed | `CIC_OBITS(24) + 7`, the width of the CORDIC it replaced (floor of the exact sum over 2^11; the rounding to 12 bits happens once, in the final stage) |
| DAC sample (`out_data`) | 12, signed | round-to-nearest then saturate (not wrap) if the shifted value does not fit |
| NCO phase increment (`nco_freq`) | 32, signed | same convention as the receiver bank on `rx-dsp`: `round(f / 76.8e6 * 2^32)` |
| `gain_shift` | 5, unsigned | extra attenuation (0-31) on top of the calibrated base shift |

## Filter design

### FIR (stage 1)

`tools/design_tx_fir.py` designs a real-valued lowpass FIR (Parks-McClellan / `scipy.signal.remez`)
applied identically to I and Q, interpolating 48 kHz to 192 kHz by 4x, polyphase-split into 4
phases of 10 taps each. Passband 0-12 kHz (test tones must sit inside this), stopband from 36 kHz
(the first image, at `48 kHz - 12 kHz`). Coefficients are Q17 signed (18-bit), written to
`rtl/tx/fir_coeffs.vh` (auto-generated, not hand-edited).

The script also checks, analytically, before writing anything: combined with the CIC that
follows, every image of a test tone (at `f0 + k*48 kHz` for every integer `k`, from the
interpolate-by-4-then-by-400 image relationship) must be comfortably under the -70 dBc target.
At 40 taps this analytical check gives -116.2 dBc worst case (the real, quantized, simulated
number is below, under "Measured results" — analytical and measured agree to within a few dB,
the rest being quantization and CORDIC approximation, both expected and small here).

The script also checks the CIC's own passband droop at the 12 kHz edge: 0.279 dB, small enough
that the architecture's suggested droop-compensation shaping in this stage is not needed (a flat
design already meets the spec; adding a peaking shape would only have traded passband flatness
the spec does not require for spur margin the design already has to spare).

### CIC (stage 2)

`rtl/tx/CicInterpM5.v`, reused from the HL2 unchanged in logic (see "Reuse" below), 5-stage,
`RRRR=400` (interpolating 192 kHz to 76.8 Msps in one stage, matching architecture 3.6). No
design choices here beyond width (see "gain and headroom"): the filter shape is fixed by the
CIC's own structure.

### Up-mixer (stage 3)

Until WP RB4: `rtl/tx/cpl_cordic.v`, reused from the HL2 unchanged in logic (`EXTRA_BITS=5`,
`IN_WIDTH` 24, full-precision 31-bit output). Since WP RB4: `rtl/rx/nco_mixer.v` in `MODE 1`
(complex in, real out, `Re{(I + jQ) e^(jt)}`), with the CORDIC's gain (52.696), sign convention
and 31-bit output width, so nothing after it changed. See "RB4" below.

## Gain and headroom

CIC output width was deliberately made wider (24 bits) than `CicInterpM5`'s own default (16):
its output extraction is a fixed bit-window into a much larger internal accumulator (the true
numeric growth through a 5-stage `R=400` interpolating CIC is `R^4`, about 34.6 bits), and a
narrow output window both throws away resolution and forces an awkward net gain. A wide window
plus the mixer's gain (52.7x from the CIC's output to its own, the CORDIC's padding and rotation
gain, kept by the NCO mixer) gives plenty of numeric range to work with; the final stage then picks how much of it to
keep with one calibrated constant (`OUTPUT_SHIFT`) plus a runtime trim (`gain_shift`).

`OUTPUT_SHIFT` was calibrated empirically, not derived by hand: the closed-form gain through a
5-stage CIC's own bit-extraction, the CORDIC's approximate 2.33x/1.647x rotation-gain formula,
and its 5-bit zero-padding compound in a way that is easy to get wrong by many dB by hand (an
early estimate here was off by about 12 dB). The testbench was run with a few trial values of
`OUTPUT_SHIFT` and the resulting peak level and worst-spur number both recorded; `OUTPUT_SHIFT=15`
(the shipped default) puts each of the two design tones at about -9.5 dBFS, leaving the combined
two-tone in-phase peak (about -3.5 dBFS, twice the single-tone amplitude) comfortably under
clipping while using most of the 12-bit range. `gain_shift` (a register, 0-31) adds further
attenuation on top of this for calibration once real levels are measured on the board; it cannot
increase gain beyond `OUTPUT_SHIFT`'s baseline, by design, since the point of that baseline is to
guarantee headroom against the worst-case two-tone (or wider, multi-tone digital-mode) peak.

The final stage rounds to nearest (adding the bit below the kept field, matching the rounding
convention already used inside the reused HL2 filters) and saturates instead of wrapping if a
value does not fit in 12 bits — a wrap on gain misconfiguration would put an unbounded-looking
transient on the air; a clip just compresses peaks.

## Safety

`out_data` is forced to zero at the final register on every `pace` edge where `enable` is low or
`trip` is high, regardless of what the upstream pipeline is doing — so the very next output
sample after either changes is zero, meeting the done-test's "within 1 sample" requirement
directly rather than by draining a pipeline. This is on top of, not instead of, the HL2's own
hardware interlock (ARCHITECTURE.md 3.6 point 5), which stays the final authority; `enable`
lets firmware (or a testbench) gate this stage's own output as well.

## Reuse

`rtl/tx/CicInterpM5.v` and `rtl/tx/cpl_cordic.v` are reused from
`G:/proj/Hermes-Lite2` `gateware/rtl/radio_openhpsdr1/` (GPL-2.0-or-later and
LGPL-2.0-or-later respectively; both compatible with this repository's GPL-3.0-or-later, per
ARCHITECTURE.md section 7). Their algorithms and logic are unchanged. Both needed one
restructuring change to build at all here: their `parameter`s that size port declarations
(`IBITS`/`OBITS` for the CIC, `IN_WIDTH`/derived `WR`/`WO`/`WF` for the CORDIC) were declared
*after* the port list, which is legal Verilog but which Icarus Verilog (the project's simulator,
`oss-cad-suite`, checked 2026-09) cannot elaborate at all if anything about the module needs its
non-default width — not even reliably at its own defaults once a downstream localparam like `WR`
is involved. Both files were restructured to a standard ANSI parameter port list (parameters
declared before the ports that use them); values are unchanged except each file's now-default
width, changed to what this WP needs (documented in each file's header) so no instance override
is attempted at all (attempting one hits the same Icarus limitation). Each file's header carries
a `modified 2026 by Franz Schöning` note describing exactly this.

`rtl/tx/tx_fir_interp4.v` is new, modelled on the HL2's `FirInterp8_1024.v` handshake protocol
(`calc`/`req`) but implemented from scratch: the original is interpolate-by-8 with a BRAM-backed
coefficient ROM and sample RAM sized for that; this WP needs interpolate-by-4 with only 10
taps/phase, small enough to hold directly in registers.

## Measured results

From `sim/tx/tb_tx_chain.v` (`bash tools/check.sh`, or run directly, see below):

- Two baseband tones at +7,031.25 Hz and -8,203.125 Hz (both inside the +-12 kHz FIR passband),
  amplitude 9,000 each (of a 32,767 int16 full scale), up-mixed to a 14.1 MHz local oscillator.
- Both tones land at the predicted output frequency (14,107,031.250 Hz and 14,091,796.875 Hz)
  and are, as expected, the two largest components in the spectrum.
- Tone levels: -9.5 dBFS and -9.6 dBFS (the two design amplitudes were equal; the 0.1 dB
  difference is the FIR's passband ripple between the two tone frequencies).
- **Worst spur: -92.9 dBc**, at 14,109,375.000 Hz (2 bins from the wanted tone) — comfortably
  past the -70 dBc design target (DECISIONS.md), over every bin from 0 to 38.4 MHz.
- Output goes to exactly zero within 1 sample of `enable` going low and of `trip` going high, and
  recovers within 1 sample of `enable` going back high.

These are exact, not estimated: the two baseband tones and the NCO frequency were chosen so both
output tones land exactly on a bin of a 65,536-point FFT of the 76.8 Msps output (bin spacing
1,171.875 Hz — chosen as a power of 2 so an integer NCO phase increment lands the LO exactly on a
bin too), which avoids window functions and spectral leakage entirely; the testbench's own
radix-2 FFT (computed in `real` arithmetic, no external tools) reads the spectrum directly.

## How the testbench paces the chain

The testbench ties `pace` high on every clock edge and clocks at the sample rate directly (an
arbitrary period; only the sample sequence matters, not wall-clock time) rather than modelling
the real 150 MHz `clk_dsp` with a bursty `adc_valid`-style `pace`. This is equivalent for this
module: every stage advances by exactly one sample per `pace` pulse and holds state otherwise, so
the resulting sample *sequence* does not depend on how much real time separates the pulses — only
the up-mixer needs care here, since its NCO advances every clock edge (`in_strobe` tied high, as
the CORDIC before it had no clock enable); a real 150 MHz integration must advance it once per
`pace` (WP H2 or later, see the note in `tx_chain.v`'s header). Exercising the true bursty
150 MHz timing together with the HL2 link's gap filler is WP H1/H2's job, not this one's.

## How to run

```
cd G:/proj/worktrees/fpga-sdr-x1-tx
bash tools/check.sh                                    # runs every testbench, this one included
# or directly:
iverilog -g2012 -o tb.vvp sim/tx/tb_tx_chain.v && vvp tb.vvp
```

Takes a few seconds (real time under a minute): about 370,000 simulated output samples (filter
settling, then one 65,536-sample FFT capture window), plus the FFT itself.

To regenerate the FIR coefficients (only needed if the passband/stopband/tap count changes):

```
py tools/design_tx_fir.py    # needs numpy + scipy; a system Python, not oss-cad-suite's
```

## RB2: FIR time-multiplexed onto one multiplier

`docs/PLAN.md` WP RB2 (ARCHITECTURE.md 3.14 change C8), branch `rb2-txfir`, worktree
`G:/proj/worktrees/fpga-sdr-rb2-txfir`. `rtl/tx/tx_fir_interp4.v` no longer computes all
NP*2 = 20 tap x {I, Q} products of one output sample in the single clock cycle `calc` pulses
on (which needed 20 parallel multipliers). It now walks a `tap` counter 0..NP-1 twice (I pass,
then Q pass) through one shared multiplier, one product per clock, then rounds the settled
accumulators into `y_real`/`y_imag` and does the phase/history-shift/`req` bookkeeping on the
last (Q, `tap == NP-1`) cycle. This is safe because `calc` is driven by the CIC interpolator's
own `req`, which only pulses once every `CIC_R` (400) clocks of the 76.8 MHz output clock (see
"how the testbench paces the chain" above): the new `y_real`/`y_imag` only need to be settled
before the CIC's *next* sampling instant, 400 clocks later, and the serial pass (2*NP + 2 = 22
clocks here) has about eighteen times the margin it needs. Summing the same 20 signed products
in a different order does not change the result (fixed-point addition on the same
wide-enough accumulator is exact, associative integer arithmetic, unchanged from before), so
the output is bit-exact with the previous parallel design.

Checked two ways:

- `sim/tx/tb_tx_chain.v` (unchanged) still passes against the new FIR: same two tone
  levels (-9.5, -9.6 dBFS), same worst spur (**-92.9 dBc**, same bin), same disable/trip
  zeroing behaviour, as before RB2.
- New done-test `sim/tx/tb_tx_chain_rb2_equiv.v`: runs the current `tx_chain` side by side
  with a pre-RB2 reference copy (`sim/tx/ref/tx_chain_ref.v` + `sim/tx/ref/tx_fir_interp4_ref.v`,
  the previous parallel-multiplier RTL, unmodified except renamed so both can be compiled into
  one simulation), each with its own independent baseband generator pulling the identical
  two-tone waveform on its own `bb_req` (RB2 changes how many clocks after `calc` `req` pulses,
  about 22 now vs. 1 before, so the two chains do not pull a given sample on the same absolute
  cycle, only in the same order). Covers disabled startup, two-tone steady state, and the
  disable/trip/re-enable sequence, comparing `out_data` and `out_valid` every clock: **0
  mismatches over 86,000 compared cycles**, both chains pulling the same number of baseband
  samples (53).

Resources (`tools/yosys_res.sh tx_chain rtl/tx/tx_fir_interp4.v rtl/tx/CicInterpM5.v
rtl/tx/cpl_cordic.v rtl/tx/tx_chain.v`, on this PC needed `OUT_DIR` pointing at a
Windows-style path rather than the script's `/tmp` default -- the installed yosys build and
Git Bash's `/tmp` resolve to different directories here):

- **FIR: 1 DSP multiplier** (down from 20), meeting the done-test's DSP target exactly.
- **tx_chain total: 10,869 logic** (LUT 5,690 + ALU 5,179), down from the pre-RB2 measured
  21,284 -- essentially the whole-chain rebalance the FIR change was meant to deliver -- but
  **over the done-test's "at most 10k" target by 869 (8.7%)**.
- Root cause, isolated by measuring each block standalone: `cpl_cordic` alone is 9,215 logic
  and `CicInterpM5` alone is 1,030 (10,245 together), both completely unchanged by this WP and
  out of its scope (ARCHITECTURE.md 3.14 change C1, "NCO mixer instead of CORDIC", is a
  separate, not-yet-built WP, RB4, that replaces `cpl_cordic` entirely and is the only thing
  that removes this cost). `tx_fir_interp4` alone is now only 660 logic (was 12,433). The FIR
  side of this WP is essentially as small as it can get without breaking bit-exactness (its
  accumulator widths are fixed by the rounding formula that must match the old design bit for
  bit); the shortfall against the 10k figure is entirely the unmodified CORDIC and CIC, which
  this WP does not touch.
- This was checked directly, not assumed: shrinking the FIR further (an earlier two-state
  version measured 773 logic; merging its "finish" step into the last multiply-accumulate
  cycle brought it to 660) moved the whole-chain total by less than the FIR's own saving,
  confirming the CORDIC/CIC pair is the binding constraint, not the FIR.

Owner note: WP RB2 as specified (FIR change only) cannot reach the stated 10k logic budget
without also doing RB4 (C1, NCO mixer). The DSP part of the done-test (1 DSP) is met exactly,
and the FIR-only design is bit-exact and about as small as this arithmetic allows; whether to
accept 10,869 for now (pending RB4) or fold C1 into this branch is an owner decision.

## RB4: NCO up-mixer instead of the CORDIC

`docs/PLAN.md` WP RB4 (ARCHITECTURE.md 3.14 change C1), branch `rb4`. `rtl/tx/cpl_cordic.v` is
removed; the up-mixer is `rtl/rx/nco_mixer.v` in `MODE 1` (the receiver bank's mixer design,
`docs/RX_DSP.md` section 10): quarter-wave table in one block RAM, first-order Taylor correction,
`out = floor(I x cos / 2^11) - floor(Q x sin / 2^11)` with 18-bit sine and cosine against the
24-bit CIC samples, 4 DSP. Same gain (52.696), sign convention and 31-bit output as the CORDIC,
so `OUTPUT_SHIFT` and the output stage are unchanged. Latency 8 clocks instead of 28: `out_data`
is the same stream 20 clocks earlier. The NCO still advances every clock (`in_strobe` tied high),
as the CORDIC did.

- Two-tone test (`sim/tx/tb_tx_chain.v`): tones -9.5 / -9.6 dBFS as before, **worst spur
  -93.0 dBc** (CORDIC -92.9), same bin, disable/trip zeroing unchanged.
- `sim/tx/tb_tx_chain_rb2_equiv.v`: its reference `sim/tx/ref/tx_chain_ref.v` now uses the same
  mixer, so it still checks the RB2 changes word for word: 0 mismatches over 86,000 cycles.
- Resources, `tools/yosys_res.sh tx_chain`: 5 DSP, 1 BSRAM, 2,426 logic (CORDIC: 1 DSP, 0 BSRAM,
  6,301 logic). Gowin place-and-route at 150 MHz (`gowin/reports/tx_chain/`): 5 DSP, 3 BSRAM (2
  FIR coefficient tables + the mixer table), 1,855 logic, 2,064 registers; **Fmax 119.8 ->
  142.4 MHz**. The CORDIC paths are gone; the 30 paths still short (by 0.36 ns at most) are all
  the `pace` clock enable fanning out to every register of `CicInterpM5`.

## Known limitations / follow-ups

- The up-mixer's NCO advances on every clock (its `in_strobe` is tied high, as the CORDIC had no
  clock enable at all); when wired into the real 150 MHz `clk_dsp` domain it must advance once
  per output sample instead (its `in_strobe`, or a clock gated on `pace`); this WP's own
  testbench does not exercise that because `pace` is always 1 here.
- The ring reader here is a plain FIFO-style port, not a DDR3 reader; wiring in the real ring
  (address generation, cache write-back per ARCHITECTURE.md 4.2) is WP H2's job and should not
  need any interface change on this side.
- `gain_shift` is a bare register input in this WP; deciding its actual runtime value (and
  `OUTPUT_SHIFT`'s continued correctness) against measured HL2 DAC levels is for the firmware
  side (`tr-fabric`/`tr-hl2`) once the board and HL2 are both available.
