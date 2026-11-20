<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# Receiver bank (rx_dsp)

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Hardware receiver bank for fpga-sdr: turns the Hermes-Lite 2's raw 12-bit, 76.8 Msps ADC
stream into up to 8 independent, simultaneously-tunable IQ receivers at 48/96/192/384 ksps.
Verilog-2001/SystemVerilog subset only (no Gowin vendor primitives), verified with iverilog,
resource-estimated with yosys generic `synth`.

## 1. Block diagram

One receiver (`rtl/rx/rx_channel.v`):

```
adc_data[11:0] ---+
adc_valid --------+--> nco_mixer -----> cic_fixed --> cic_var --> fir_decim --> out_i[23:0]
phase_inc[31:0] -----/  (NCO, table)   (fixed x10)   (var x40..5)  (fixed x4)    out_q[23:0]
rate_sel[1:0] --------------------------------------------/                     out_valid
enable ---------> (gates adc_valid into the mixer)
```

`rtl/rx/rx_bank.v` instantiates `N` (default 8) of these off one shared ADC input, with a
register write port to configure each channel and a round-robin arbiter that muxes all N
channels' IQ output onto ONE shared stream tagged with a receiver index (see section 4 for
why one shared stream was chosen over N parallel buses).

Each channel holds its own mixer/CIC/FIR pipeline in reset whenever it is disabled
(`chan_rst = rst | ~enable` in `rx_channel.v`), not only at power-up. This was added after a
real bug turned up while building the targeted alias test (section 6.2): `cordic_mixer`'s
output-valid tracking is a shift register that only advances on `in_strobe`; if a channel is
disabled mid-stream while that register still has a `1` sitting in it, the register has nothing
left to shift it out with (no more `in_strobe` pulses are coming) and `out_strobe` gets stuck
asserted forever, which then makes every downstream CIC/FIR stage free-run on stale, frozen
data. Holding the whole channel in reset while disabled avoids this and guarantees every
re-enable starts clean -- relevant any time the RISC-V firmware changes a receiver's frequency,
rate, or on/off state during operation, not just in this test.

**A second, more general form of the same problem** (`docs/R4_BACKEND.md` section 9, defect 1,
found later by the WP R4 end-to-end test, now fixed) hit any *enabled* channel whenever
`adc_valid` itself went gappy, not just at disable/re-enable: `chan_rst` only protects the
disable/re-enable transition, but the same stuck-shift-register-bit mechanism struck a channel
that stayed enabled the whole time once its `adc_valid` stream had a real gap in it. The old
`out_strobe = valid_sr[STG]` was a plain combinational read: once `valid_sr` had filled from a
run of continuous input it stayed `1` for as long as `adc_valid` then paused, because `valid_sr`
only updates on `in_strobe` and simply holds its last value while `in_strobe` is low -- so every
downstream CIC/FIR stage free-ran on the frozen last sample on every clock with no new input at
all, i.e. the bank decimated by ADC clocks instead of by accepted `adc_valid` pulses. Fixed by
registering `out_strobe` instead: it is now loaded every clock with `in_strobe & valid_sr[STG-1]`
(see `cordic_mixer.v`'s comment; `nco_mixer.v`, which replaced it in WP RB4, section 10, keeps
the same scheme), which reproduces the exact same output timing whenever
`in_strobe` pulses every clock (the case every earlier testbench used, which is why this went
unnoticed until a genuinely gapped/bursty `adc_valid` stream was fed through the real bank end to
end) but now correctly drops to `0` the very next clock once `in_strobe` stops. `fw/tr-rxmodel`'s
`cordic.rs` mirrored this exactly, as `nco.rs` does now (`docs/R2_RXMODEL.md`).

## 2. Decimation plan and bit widths

ADC clock 76.8 MHz drives the whole channel; `adc_valid` qualifies each new ADC sample (works
at one sample per clock, and also with a sparser/gapped valid -- every stage is strobe-gated,
not free-running).

| stage | function | decimation | in width | out width | out rate (from 76.8 MHz) |
|---|---|---|---|---|---|
| `nco_mixer` | NCO quadrature mixer (table + Taylor correction, section 10; a CORDIC until WP RB4), 32-bit phase increment | 1 | 12 (ADC) | 18 (I), 18 (Q) | 76.8 Msps |
| `cic_fixed` | Hogenauer CIC, 3 stages, fixed decimation | 10 | 18 | 16 | 7.68 Msps |
| `cic_var` | Hogenauer CIC, 5 stages, decimation selected by `rate_sel` | 40 / 20 / 10 / 5 | 16 | 16 | 192k / 384k / 768k / 1536k sps (= 4 x out_rate) |
| `fir_decim` | compensating equiripple FIR, 65 taps | 4 | 16 | 24 (I), 24 (Q) | 48k / 96k / 192k / 384k sps |

`rate_sel`: `2'd0`=48 ksps, `2'd1`=96 ksps, `2'd2`=192 ksps, `2'd3`=384 ksps. Total decimation
from ADC to output = 10 x {40,20,10,5} x 4 = {1600, 800, 400, 200}, matching 76.8 MHz / out_rate
exactly for all four rates.

Gain plan: the mixer has a fixed gain of 52.696 from ADC counts to its 18-bit output (the HL2
CORDIC's own gain, 32 x 1.64676, kept exactly by the NCO mixer that replaced it, section 10). `cic_fixed` and
`cic_var` each round their internal (much wider) accumulator back down to a fixed output width
via a decimation-dependent bit-select (`cic_var`'s `MSB{5,10,20,40}`/`LSB{...}` constants) so
that DC gain stays close to unity regardless of which decimation is selected -- this is what
makes ONE compensating FIR coefficient set valid for all four output rates (see section 3).
`fir_decim`'s coefficients are unity-DC-gain by construction (normalized in
`tools/gen_fir_coeffs.py`).

Reused HL2/openHPSDR code (headers kept, "modified 2026 by Franz Schöning" added), from
`G:/proj/Hermes-Lite2/gateware/rtl/radio_openhpsdr1/`:
- `cordic.v` -> `rtl/rx/cordic_mixer.v` (added strobe gating so the pipeline holds when
  `adc_valid` is not asserted every clock; algorithm and arctan table unchanged)
- `cic.v` -> `rtl/rx/cic_fixed.v`, `varcic.v` -> `rtl/rx/cic_var.v` (trimmed to the one
  decimation family {5,10,20,40} this design needs; otherwise unchanged)
- `cic_integrator.v`, `cic_comb.v` -> reused verbatim

New code (GPL-3.0-or-later, Copyright 2026 Franz Schöning): `fir_decim.v`, `rx_channel.v`,
`rx_bank.v`, and the FIR design/coefficient and test-signal generator scripts under `tools/`.

## 3. Compensating FIR design

`tools/gen_fir_coeffs.py` designs `fir_decim`'s 65-tap, decimate-by-4, equiripple (Parks-McClellan
via `scipy.signal.remez`) lowpass and writes `rtl/rx/fir_coeffs.hex` ($readmemh, one 20-bit
two's-complement coefficient per line).

- Passband edge: 0.06 cyc/sample (of `fir_decim`'s own input rate, i.e. 4x the selected output
  rate) -- this is less than the alias-free ideal of 0.125 cyc/sample (1/8) on purpose, trading
  usable bandwidth for a real (non-brick-wall) transition band.
- Stopband edge: 0.19 cyc/sample (= 0.25 - passband edge, the alias-free limit for decimate-by-4).
- Usable receiver passband: +/-48% of the full output Nyquist, i.e. +/-0.48 x out_rate/2
  (e.g. +/-11.5 kHz at 48 ksps, +/-92 kHz at 384 ksps).
- `cic_var` (order 5) has sinc^5 passband droop that this filter does NOT pre-compensate in its
  shape (a multi-band remez attempt to bake in compensation did not converge reliably at this
  transition width); instead the passband edge is chosen small enough that residual droop stays
  well under the 0.5 dB amplitude budget. `cic_fixed`'s droop is negligible in every case: its
  decimation (10) is modest and its output rate (7.68 MHz) is always far above the passband
  edges used here.
- Coefficients are 20-bit signed, wider than the GW5AST DSP's 18-bit port -- see section 5 for
  why that is still cheap.

Design numbers, as printed by `tools/gen_fir_coeffs.py` (65 taps, 20-bit quantized coefficients):

| quantity | value |
|---|---|
| passband edge | 0.06 cyc/sample (of fir_decim's own input rate) |
| stopband edge | 0.19 cyc/sample |
| usable output passband | +/-48% of full output Nyquist |
| passband ripple (FIR only) | 0.0001 dB |
| stopband attenuation (this FIR's own decimate-by-4 image rejection) | 99.2 dB |
| `cic_var` sinc^5 droop at the passband edge (uncompensated) | -0.257 dB |
| combined worst-case passband amplitude error (FIR + CIC droop) | 0.258 dB |

## 4. Register interface and output stream

Register write port (`rx_bank`): one write per clock, `reg_wr` pulses high for one cycle.

- `reg_addr[0]` = 0 -> writes `phase_inc` (32-bit NCO frequency word, `phase_inc = round(LO_Hz /
  76.8e6 * 2^32)`), = 1 -> writes the control word.
- `reg_addr[IDX_W:1]` = receiver index (0..N-1).
- Control word (`reg_wdata`): bit 2 = `enable`, bits [1:0] = `rate_sel`.

Output stream: **one shared stream** (`out_valid`, `out_index`, `out_i[23:0]`, `out_q[23:0]`)
instead of N parallel IQ buses. Chosen because everything downstream (VITA-49 packetizer, DDR3
buffering, the RISC-V firmware reading it) has to serialize samples into one stream or one
memory region anyway, so N always-there parallel buses would just move the serialization problem
downstream for no benefit. The cost is a small 1-entry skid buffer per channel plus a
round-robin arbiter inside `rx_bank`, which is safe because the minimum gap between two samples
from the same channel (>=200 ADC clocks even at 384 ksps) is far longer than the arbiter ever
needs to drain a collision between up to N channels (<=N ADC clocks).

**Repeat bug, found and fixed** (`docs/R4_BACKEND.md` section 9, defect 2): the arbiter's
per-channel pending flag (`pend_valid`) used to be cleared on `out_valid && out_index == pi` --
the REGISTERED `out_valid`/`out_index`, which only reflect a grant one clock after the
combinational `found`/`found_idx` search actually decided it. That left the just-granted
channel's `pend_valid` still set for one extra clock, so with nothing else pending the same
search granted it again on the very next clock, re-emitting its (unchanged) sample a second time
-- measured 499 of 2,367 samples repeated (section 6) before the fix. Fixed by clearing
`pend_valid` on `found && found_idx == pi` instead: the same this-edge combinational decision
that drives `out_valid`/`out_index`, so the granted entry is cleared the same clock it is
granted, not one clock late. `fw/tr-rxmodel`'s `bank.rs` mirrors this exactly
(`docs/R2_RXMODEL.md`).

## 5. Resource estimate

From `yosys -p "read_verilog rtl/rx/*.v; hierarchy -top rx_bank -check; synth -top rx_bank -run
coarse; stat"` (coarse/generic synthesis -- multiplies and memories are still visible as
`$macc_v2`/`$mem_v2` cells rather than mapped to gates, which is what matters for a DSP/BSRAM
estimate; this is a generic gate-level estimate, not a Gowin-specific LUT count):

- **Multipliers**: `fir_decim` is the ONLY place a real multiply happens -- ONE 16x20 signed
  multiply-accumulate, time-multiplexed across all 65 taps and both I/Q channels (130 sequential
  steps per decimated output, see the comment in `fir_decim.v` for the cycle-budget argument:
  even at the fastest configured rate there are ~200 ADC clocks between decimated outputs, so
  130 steps with margin). Yosys confirms exactly one `$macc_v2` cell per `fir_decim` instance.
  `cordic_mixer` and both CIC stages are pure shift/add (no `*` operator anywhere in those
  files, matching the original openHPSDR/HL2 algorithm) -- yosys's coarse stat shows 31
  `$macc_v2`-shaped cells per `cordic_mixer` instance too, but these are multi-operand adder
  chains yosys's `alumacc` pass represents with the same generic cell type, not real multipliers
  (there is no `*` in the source to synthesize into one).
  - Per receiver: 1 real multiplier. Bank of 8: **8 real multiplies**.
  - The coefficient is 20 bits, wider than the GW5AST's 18-bit DSP port, so each multiply likely
    costs 2 cascaded DSP48-class blocks on the real device instead of 1.
  - **Estimated DSP usage: ~16 of 298 (about 5%)** -- comfortably under the 1/3 (about 99)
    budget, with room to spare even if real Gowin mapping costs more than this estimate assumes.
- **Memory**: `fir_decim`'s 65 x 20-bit coefficient ROM is the main `$mem_v2` user (1 per
  instance, 8 total); the tapped delay lines (`taps_i/q`, `snap_i/q`, 65 entries x 16 bits each)
  did not infer as block memory at the coarse stage (irregular parallel shift/snapshot access
  pattern), so they cost distributed flip-flops instead -- 8 receivers x 4 arrays x 65 x 16 bits
  is on the order of 33k flip-flops, trivial next to a 138K-LUT device.
  - **Estimated BSRAM usage: under 10 of ~340** -- negligible against the budget.
- **Timing**: every stage is a short combinational path (CORDIC: one shift + 2-3 adds per
  stage; CIC: one add per stage; FIR: one 16x20 multiply + one wide add per MAC step) between
  registers, clocked entirely from the 76.8 MHz ADC clock -- no stage was designed assuming
  153.6 MHz. This should plausibly close at 76.8 MHz on the GW5AST-138 (dedicated carry chains
  handle the CIC's wide adders; the widest single adder is `cic_var`'s 43-bit accumulator, still
  a single carry-chain add, not multi-cycle). Real Gowin place-and-route timing has not been run
  (no netlist/constraints for the actual GW5AST-138 device were built as part of this task) --
  this is a plausibility argument from the RTL structure, not a signed-off timing closure.

## 6. Test results

Run with: `sim/run_sim.sh` -- one command, runs BOTH of the following tests back to back and
prints a combined pass/fail (see section 7).

### 6.1 Functional test: signal accuracy across all 8 receivers at once

Test signal: `tools/gen_signals/gen_test_signals.py` generates one 76.8 Msps, 12-bit-signed ADC
capture containing:
- 9 simultaneous CW carriers at chosen frequencies/levels (table below), one assigned to each of
  the 8 receivers (receiver 0 gets a close two-tone pair, 2 kHz apart, to check the passband
  captures two closely spaced signals cleanly)
- broadband white noise added at an assumed -50 dBFS rms floor (full 0..38.4 MHz Nyquist) as a
  stand-in for a realistic receiver noise floor, ahead of the real HL2 captures the project plans
  to take once the antenna is connected (per `docs/DECISIONS.md`)

Deviation from the task's illustrative "14.074 MHz at -100 dBFS" example: a 12-bit ADC's
quantization noise floor for a single tone sits around -74 dBFS, so a -100 dBFS tone cannot be
resolved at all in a straight 12-bit sample dump; the weakest tone here is -60 dBFS instead
(kept at the OTHER example's exact frequency/level, 7.074 MHz at -60 dBFS), which is realistically
resolvable and still exercises selectivity hard.

All 8 receivers were tuned to different frequencies AND different output rates simultaneously in
one simulation run (2 receivers each at 48/96/192/384 ksps), confirming the bank works with all
8 channels active together, each independently tuned.

Measurement method: capture each receiver's IQ stream, discard the first 15% of samples (filter
settling), window (Blackman-Harris) and FFT the rest to find each tone's approximate bin, then
refine the frequency with parabolic interpolation of the log-magnitude around that bin and
re-measure the amplitude with an exact-frequency correlator (a single-bin DFT evaluated at the
refined frequency rather than read off the nearest coarse FFT bin) -- this is what let receiver
0's two close tones (2 kHz apart, sharing a short, low-resolution capture) be measured accurately
without needing a much longer capture. FFT magnitude is normalized by sample count and window
coherent gain so receivers with different output rates (different numbers of captured samples
from the same fixed capture length) are measured on the same absolute scale. A single calibration
constant (the median, across all 9 tone measurements, of "known input level minus measured raw
level") converts raw level to dBFS -- valid because the chain's overall DC gain is a fixed design
constant independent of frequency or rate (`fir_decim`'s coefficients are unity-DC-gain by
design, and `cic_var`'s bit-select normalizes every decimation setting back to matching gain,
confirmed by feeding all four decimation settings identical input and checking for identical
output). Applying ONE constant to every receiver and landing within a fraction of a dB per
receiver is itself evidence the gain really is consistent across the bank.

| rx | tuned to | rate | expected level | measured level | amplitude error | expected offset | measured offset | frequency error |
|---|---|---|---|---|---|---|---|---|
| 0 | 1.839 MHz | 48 ksps | -20 dBFS | -20.00 dBFS | -0.00 dB | -1000 Hz | -1000.4 Hz | -0.4 Hz |
| 0 | 1.841 MHz | 48 ksps | -20 dBFS | -20.00 dBFS | -0.00 dB | +1000 Hz | +1000.3 Hz | +0.3 Hz |
| 1 | 3.573 MHz | 48 ksps | -30 dBFS | -30.01 dBFS | -0.01 dB | 0 Hz | -0.0 Hz | -0.0 Hz |
| 2 | 7.074 MHz | 96 ksps | -60 dBFS | -59.83 dBFS | +0.17 dB | 0 Hz | +0.2 Hz | +0.2 Hz |
| 3 | 10.136 MHz | 96 ksps | -40 dBFS | -40.02 dBFS | -0.02 dB | 0 Hz | +0.3 Hz | +0.3 Hz |
| 4 | 14.074 MHz | 192 ksps | -55 dBFS | -55.00 dBFS | +0.00 dB | 0 Hz | -1.0 Hz | -1.0 Hz |
| 5 | 18.100 MHz | 192 ksps | -35 dBFS | -35.00 dBFS | -0.00 dB | 0 Hz | -0.3 Hz | -0.3 Hz |
| 6 | 21.074 MHz | 384 ksps | -45 dBFS | -44.98 dBFS | +0.02 dB | 0 Hz | -0.4 Hz | -0.4 Hz |
| 7 | 28.074 MHz | 384 ksps | -25 dBFS | -25.00 dBFS | +0.00 dB | 0 Hz | +0.0 Hz | +0.0 Hz |

All 9 tone measurements, including receiver 0's two-tone pair (2 kHz apart, sharing one
receiver's passband), land within 0.17 dB and 1.0 Hz of expected -- comfortably inside the 0.5 dB
amplitude target the task description asks for. The two-tone pair specifically, which an earlier version of
this test measured at 0.51 dB (just over target, limited by plain FFT bin resolution), now
measures 0.00 dB with the parabolic-interpolation + exact-frequency-correlator refinement
described above.

**Adjacent-signal rejection** (the strongest OTHER peak in each receiver's own output spectrum,
relative to its wanted tone -- with all 9 tones present simultaneously spread across the HF band,
some land close enough in frequency to a receiver's own passband edge to show up here):

| rx | tuned to | strongest nearby signal offset | rejection |
|---|---|---|---|
| 0 | 1.839/1.841 MHz | -16771 Hz | 68.8 dB |
| 1 | 3.573 MHz | -17639 Hz | 56.5 dB |
| 2 | 7.074 MHz | +21398 Hz | 27.5 dB |
| 3 | 10.136 MHz | -16771 Hz | 49.0 dB |
| 4 | 14.074 MHz | -19403 Hz | 31.6 dB |
| 5 | 18.100 MHz | +63131 Hz | 51.2 dB |
| 6 | 21.074 MHz | +7240 Hz | 39.7 dB |
| 7 | 28.074 MHz | -4489 Hz | 62.2 dB |

These numbers describe ordinary passband/transition-band selectivity against other signals that
happen to be nearby in frequency (tens of kHz, in this test) -- NOT the decimation-alias
rejection the redesign task in section 6.2 is about, which is a different phenomenon at
MHz-scale offsets tied to each decimating stage's own sample rate. An earlier version of this
document conflated the two and reported these adjacent-signal numbers as if they were alias
rejection; section 6.2's dedicated, deliberately-placed test is the correct way to measure alias
rejection, and that is where the 90 dB target is actually checked.

### 6.2 Targeted alias-rejection test

Decimating filters alias energy from specific, narrow frequency bands sitting at exact multiples
of that stage's own output rate away from the tuned frequency -- a few hundred kHz to a few MHz
away for this design's `cic_fixed` and `cic_var` stages, not the essentially-arbitrary
frequencies the section 6.1 test tones happen to sit at. Confirming 90 dB rejection means placing
a strong interferer exactly there and measuring what gets through, which `tools/analyze_alias.py`
computes and `tools/gen_signals/gen_alias_test_signals.py` / `sim/rx/rx_alias_sim.v` /
`sim/check_alias.py` carry out:

1. `tools/analyze_alias.py` computes, analytically, the exact worst-case frequency for each of
   the two decimating stages (`cic_fixed`, fixed x10; `cic_var`, x40/20/10/5 depending on output
   rate) and each of the 4 output rates -- 8 cases -- using each stage's own CIC magnitude
   formula evaluated across every alias band that could fold into that receiver's own passband.
2. `tools/gen_signals/gen_alias_test_signals.py` builds one ADC capture with a full-scale
   (0 dBFS) CW interferer at each of those 8 exact frequencies, each in its own isolated time
   segment (several of the worst-case frequencies are only tens of kHz apart, so a wide-passband
   384 ksps receiver would otherwise also pick up a narrower-rate receiver's interferer).
3. `sim/rx/rx_alias_sim.v` tunes each of the 8 receivers to baseband (phase_inc=0) and enables it only
   during its own segment, so whatever lands near DC in its output during that window is the
   measured alias.
4. `sim/check_alias.py` reads the result and reports rejection in dB. It reads `fir_decim`'s
   44-bit pre-rounding MAC accumulator directly (probed via hierarchical reference in the
   testbench) rather than the normal 24-bit rounded output: this is an exact, noiseless
   simulation with no dither, so a residual under 1 count of the normal output reads as exactly
   0, indistinguishable between "just barely 90 dB" and "150 dB" alike -- the wider accumulator
   has the headroom to actually resolve rejection this deep.

| rx | rate | stage | interferer freq | predicted rejection | measured rejection |
|---|---|---|---|---|---|
| 0 | 48 ksps | cic_fixed | 7.6685 MHz | 169.0 dB | 158.5 dB |
| 1 | 48 ksps | cic_var | 0.1805 MHz | 119.7 dB | 122.6 dB |
| 2 | 96 ksps | cic_fixed | 7.6570 MHz | 150.9 dB | 148.2 dB |
| 3 | 96 ksps | cic_var | 0.3610 MHz | 119.6 dB | 121.7 dB |
| 4 | 192 ksps | cic_fixed | 7.6339 MHz | 132.7 dB | 138.5 dB |
| 5 | 192 ksps | cic_var | 0.7219 MHz | 119.1 dB | 120.7 dB |
| 6 | 384 ksps | cic_fixed | 7.5878 MHz | 114.5 dB | 91.1 dB |
| 7 | 384 ksps | cic_var | 1.4438 MHz | 117.2 dB | 122.7 dB |

Worst-case measured rejection per output rate (the smaller of the `cic_fixed`/`cic_var` cases for
that rate -- this is the number that answers "for a full-scale signal anywhere in 0-38.4 MHz,
what is the worst attenuation this receiver provides before its alias could land in the
passband"):

| output rate | worst-case measured rejection | limiting stage |
|---|---|---|
| 48 ksps | 122.6 dB | cic_var |
| 96 ksps | 121.7 dB | cic_var |
| 192 ksps | 120.7 dB | cic_var |
| 384 ksps | 91.1 dB | cic_fixed |

All four rates clear the 90 dB target, with the least margin at 384 ksps (91.1 dB measured
against a 114.5 dB analytical prediction for that stage -- see section 8 for why that gap is
plausible and what would tighten it if more margin is wanted later). No redesign of the
decimation stages (CIC order, decimation split) was needed: the existing `cic_fixed` (order 3,
x10) and `cic_var` (order 5) already provide far more rejection at their own alias points than
the 90 dB target requires, confirmed both analytically and by direct RTL simulation.

Spectrum plots per receiver: `sim/out/rx{0..7}_spectrum.png` (gitignored, regenerate with
`sim/run_sim.sh`). FIR design response plot: `sim/out/fir_response.png`.

## 7. Running the tests

Two ways to run these, for two different purposes:

- `bash tools/check.sh` (repo-wide, project convention) runs `sim/rx/tb_rx_bank.v` and
  `sim/rx/tb_alias.v` -- fast (a few seconds total), self-contained (no Python, no generated
  input files, `rtl/rx/fir_coeffs.hex` used as a checked-in fixture), single-case smoke tests: do
  the receivers still broadly work, does a receiver recover cleanly after being disabled and
  re-enabled (a regression check for the bug in section 1), does the worst alias case still clear
  90 dB. Not a substitute for section 6's numbers.
- `sim/run_sim.sh` (below) is the real, thorough test behind every number in section 6: many
  receivers, many frequencies and rates, FFT-based measurement, all 8 alias cases. Slower (a few
  minutes), so it is not part of `tools/check.sh`.

```
cd sim
./run_sim.sh
```

This regenerates the FIR coefficients, then runs the two tests from section 6 back to back: the
functional test (compiles and runs `rx/rx_bank_functional_sim.v`, then `check_results.py`, which prints a table
of measured vs. expected tone frequency/amplitude per receiver plus the strongest adjacent
signal for each, and writes PNG spectrum plots to `sim/out/`, gitignored) and the targeted alias
test (`tools/analyze_alias.py`, then compiles and runs `rx/rx_alias_sim.v`, then `check_alias.py`, which
prints measured vs. predicted rejection per case). Ends with one combined pass/fail line. Total
wall time: ~4 minutes (measured 4m07s).

A longer, higher-resolution run of either test is possible (raise `N_OUT_48K` in
`tools/gen_signals/gen_test_signals.py`, or `SETTLE_OUTPUT_POINTS` in
`tools/gen_signals/gen_alias_test_signals.py`) at the cost of proportionally longer simulation
time -- not needed to confirm the numbers in section 6, but available for extra margin.

Individual steps, if needed:
```
python ../tools/gen_fir_coeffs.py                  # rtl/rx/fir_coeffs.hex + sim/out/fir_response.png
python ../tools/gen_signals/gen_test_signals.py     # functional-test ADC file + sim/rx_config.vh
iverilog -g2005 -o out/tb_rx_bank.vvp rx/rx_bank_functional_sim.v ../rtl/rx/*.v
vvp out/tb_rx_bank.vvp
python check_results.py

python ../tools/analyze_alias.py                    # tools/gen_signals/out/alias_plan.json
python ../tools/gen_signals/gen_alias_test_signals.py  # alias-test ADC file + sim/alias_config.vh
iverilog -g2005 -o out/tb_alias.vvp rx/rx_alias_sim.v ../rtl/rx/*.v
vvp out/tb_alias.vvp
python check_alias.py
```

## 8. Known limitations / not done

- **384 ksps has the least alias-rejection margin**: ~91 dB measured against the `cic_fixed`
  stage's own analytical prediction of 114.5 dB for that rate (section 6.2) -- still clears the
  90 dB target, but with only about 1 dB to spare, versus 20+ dB of margin at the other three
  rates. The measured/predicted gap is plausible rather than alarming: 384 ksps has this test's
  shortest settle time (its alias-test segment is the shortest, since it is the fastest rate),
  and the ideal-math CIC formula the prediction comes from does not account for the real
  fixed-point rounding in `cic_fixed`/`cic_var`'s bit-select normalization. If more margin is
  wanted here later: lengthen `SETTLE_OUTPUT_POINTS` in
  `tools/gen_signals/gen_alias_test_signals.py` for a cleaner measurement first (to confirm
  whether the gap is really settling-related), and if a real shortfall remains, raising
  `cic_fixed`'s STAGES from 3 is a cheap fix (CIC order costs no DSP or BSRAM, only some extra
  adder logic and accumulator width -- see section 5).
- Real Gowin place-and-route (timing closure, actual DSP/BSRAM mapping) was not run -- section 5
  is a plausibility estimate from generic synthesis and hand analysis, not a signed-off result.
- `cic_var`'s droop is not explicitly pre-compensated in the FIR's shape (see section 3);
  acceptable at the chosen passband width but would need revisiting if a wider usable passband
  is wanted later.
- The register write port is a bare synchronous bus (address + data + write strobe); it has no
  bus protocol (ready/ack) of its own -- whatever connects it (likely a Wishbone/AXI-lite bridge
  from the RISC-V firmware side) needs to guarantee one write per clock is acceptable, which is
  a reasonable assumption for a control-register bus but is not yet validated against the actual
  bus fabric because that has not been designed yet.
- `sim/rx/rx_alias_sim.v`'s hi-precision capture reads `fir_decim`'s internal accumulator via a
  hierarchical reference from the testbench (`dut.firs[k].u_fir.acc_i_latched` etc.) rather
  than through a port -- standard practice for a testbench probe, but it means that measurement
  is coupled to `fir_decim`'s current internal signal names/structure and would need updating if
  those change.

## 9. WP RB3: FIR delay lines as circular buffers, shared variable-CIC engines

ARCHITECTURA.md 3.14 changes C2 and C3, done on branch `rb3-rxbank`. Two changes to the same
bank, both to cut logic and registers rather than change any measured behaviour:

- **C2**: `fir_decim.v`'s delay line (`rtl/rx/fir_decim.v`) is a circular buffer in memory instead
  of a 65-entry shift register plus a 65-entry snapshot copy. The memory itself now lives in a
  small companion module, `rtl/rx/fir_delay_ram2.v`, so two receivers can eventually share one
  physical block; today it is two independent same-shape arrays in that one module (see "What
  this WP did and did not achieve" below for why the sharing does not yet show up as fewer BSRAM
  in this project's yosys-based resource count).
- **C3**: the per-receiver variable CIC (`cic_var.v`, 5-stage Hogenauer, decimate by
  {5,10,20,40}) is replaced by `rtl/rx/cic_var_shared.v`: one shared integrator/comb arithmetic
  engine per group of up to 4 receivers (8 contexts: I and Q of each), granted to one pending
  context per clock by a round-robin arbiter, instead of one dedicated `cic_var` instance per
  receiver x channel (16 instances for N=8 before this change).

`rtl/rx/rx_channel.v` now stops at the fixed CIC (`cic_fixed`, decimate-by-10) -- the CORDIC
mixer and that stage are unchanged and stay one-per-receiver (a later work package replaces the
CORDIC with an NCO mixer; out of scope here). `rtl/rx/rx_bank.v` instantiates the shared CIC
engines (one per group of up to 4 receivers) and the FIR pairs itself, wiring each receiver's
front end into them.

### 9.1 Why the shared CIC engine's scheduling is invisible at the interface

Every receiver in the bank shares the same `adc_valid`/`enable` input, so `cic_fixed`'s own
decimate-by-10 boundary lands on the identical clock for every receiver whenever none is
individually disabled -- in the common case, all 8 contexts a shared engine serves become
pending on the same cycle, every time. The engine services one pending context per clock
(round-robin), so draining a full batch of 8 takes at most 8 clocks -- comfortably inside the
minimum 10-clock gap before the same context can become pending again (`cic_fixed`'s own
decimate-by-10 rate, even with `adc_valid` high every clock), which is why no queue deeper than
one pending flag per context is ever needed (matches the "82% busy during an HL2 frame burst"
sizing in ARCHITECTURE.md 3.14 change C3).

That scheduling delay never reaches the interface because `cic_var`'s own `out_data` register
was already an "off by one decimation period" design before this change: it is refreshed
unconditionally every clock from the comb chain's own top stage, which itself only actually
changes value once per decimation period, so at the moment a *new* boundary is detected,
`out_data` still shows the *previous* period's settled result (see `cic_var.v`'s own header and
`fw/tr-rxmodel/src/cic.rs`'s module doc, which already relied on this property before RB3). This
work kept that structure explicit: `cic_var_shared.v` runs the decimation-boundary counter
(`sample_no`) and the `out_strobe`/`out_data` refresh per context, immediately and independently
of scheduling (cheap -- a handful of flip-flops per context), and only the expensive 43-bit
integrator/comb accumulator state is behind the shared, scheduled engine. A context's *own*
fresh result only has to be written back before that *same* context's *next* boundary, one full
decimation period (>=5 accepted samples) away -- not immediately -- so the shared engine's
internal latency (a handful of clocks in the worst case) never changes a delivered value or its
timing.

This was verified two ways, not just argued: `fw/tr-rxmodel` needed **no changes at all** --
`tools/check.sh`'s WP R2 bit-exact check (RTL vs. the unmodified Rust model, which still mirrors
the pre-RB3 per-instance timing) passes unchanged, and a dedicated comparison testbench
(`sim/rx/tb_rb3_compare.v`, below) confirms the full bank's shared output stream is bit-for-bit
identical to the pre-RB3 RTL, order included.

### 9.2 A real bug this design change introduced, and its fix

Removing the FIR's snapshot copy (C2 asks for "no snapshot copy") is not simply "read the live
buffer instead of a copy": the old snapshot existed specifically so a live write during the MAC
sequencer's ~130-clock pass could never reach a tap the (slower) sequencer had not read yet. A
circular buffer exactly `TAPS` (65) entries deep does not have that property -- a single write
during the pass advances the write pointer one slot past the sequence's own `base_ptr`, which in
a 65-deep ring is the *same memory cell* as the oldest tap (65 slots behind `base_ptr`), so it
silently overwrites that tap before the Q-channel copy of the sequence reads it (dead last, at
the very end of the pass). This was not caught by inspection or by the quick smoke tests --
it showed up as exactly 2 of 846 output words differing by 1 count, both on the 384 ksps
receiver, in the `sim/rx/tb_rb3_compare.v` done-test comparison described below, and took
step-by-step hierarchical tracing against the saved reference RTL to isolate. Fixed by giving
the ring 128 entries (63 spare slots) instead of 65: comfortably more than the at-most-3 writes
that can land inside one MAC pass even at the fastest configured rate (`fir_decim`'s own input
rate is at least one sample every 50 clocks), and a power of two besides, so the ring's own
address wraparound is a plain bit-width truncation rather than a compare-and-subtract. See
`fir_decim.v`'s own header comment for the full derivation.

### 9.3 Done-test: word-for-word comparison against the pre-RB3 RTL

The pre-RB3 RTL is kept verbatim under `sim/rx/ref/` (every module renamed with a `_ref` suffix
so both versions can be compiled into one testbench without a name clash). `sim/rx/tb_rb3_compare.v`
drives both `rx_bank` (N=8) and `rx_bank_ref` (N=8) with the identical stimulus -- two receivers
per output rate, both an `adc_valid`-every-clock pass and a bursty (~51% duty) pass, 60,000 ADC
cycles total -- and diffs the two `(index, i, q)` output streams for exact equality, word for
word, including order (same method as the WP R2 comparison). **Result: PASS, 846 words, identical
between the two.** Wired into `tools/check.sh`'s generic `tb_*.v` loop (a couple of minutes).

The existing done-tests all still pass unchanged: the WP R2 bit-exact check (`tools/check.sh`),
the `fw/tr-rxmodel` regression tests independent of the model/RTL comparison
(`regression_r1.rs`), the quick smoke tests (`tb_rx_bank.v`, `tb_alias.v` -- the latter rewritten
to instantiate `rx_bank` with N=1 instead of `rx_channel` directly, since `rx_channel` no longer
carries the whole per-receiver chain), and the full functional and alias-rejection tests
(`sim/run_sim.sh`): worst-case measured alias rejection per rate is unchanged at 122.6 / 121.7 /
120.7 / 91.1 dB (48/96/192/384 ksps), i.e. inside the 91-123 dB range measured before this WP.

### 9.4 What this WP did and did not achieve on resources

Measured with `tools/yosys_res.sh rx_bank` (N=8, every `rtl/rx/*.v` file this bank now uses):
**8 DSP, 8 BSRAM (18 kbit), about 42,000 logic, about 24,600 registers.** Against the targets
this WP was set (logic at most 38,000 with the CORDIC mixers still in place, registers at most
20,000, BSRAM at most 6): DSP is comfortably inside budget; **logic, registers and BSRAM are
not** -- roughly 10%, 23% and 33% over, respectively.

Root cause: `cic_var_shared.v`'s shared accumulator state (`integ`, `cmb_out`, `cmb_prev`) is
declared as ordinary Verilog register arrays indexed by a round-robin-selected context each
cycle. yosys's generic memory inference does not recognise this access pattern (a `for` loop
over every context with a per-iteration conditional write) as a candidate for block RAM --
its own log says so explicitly ("Replacing memory \\integ with list of registers", and the same
for `cmb_out`, `cmb_prev`, and the small per-context control arrays) -- so the "expensive" state
this change was meant to move into BSRAM (ARCHITECTURE.md 3.14 change C3's own estimate: "+2
BSRAM" against "-9.7k logic") stays in flip-flops instead, with a full comparator/mux network
attached to every one of the 8 contexts each shared engine serves. Measured in isolation
(`tools/yosys_res.sh cic_var_shared`), one 8-context engine costs about 4,700 logic and 5,400
registers; two of them (N=8) together cost only a little less than the 16 dedicated per-receiver
`cic_var` instances they replace (measured indirectly: `cic_fixed`'s own 216 logic per instance,
subtracted from ARCHITECTURE.md 3.14's own measured "~1.5k logic per receiver" for the combined
CIC pair, puts the old 16-instance total at roughly 10,300 logic) -- a real but modest saving
(roughly 900 logic), nowhere near the "-9.7k" ARCHITECTURE.md 3.14 estimated for a version whose
state actually reaches BSRAM.

`fir_decim.v`'s own circular buffer, in contrast, **does** map to real block RAM on its own (no
"replacing memory" warning for it) -- a single clean `always @(posedge) begin if (write) mem[w]
<= data; read_reg <= mem[r]; end` pattern, one write address and one read address, is exactly the
shape yosys's memory inference wants. `fir_delay_ram2.v` keeps that same shape as two separate
same-depth arrays (one per receiver) rather than one array addressed by a computed
`{region_bit, offset}` expression -- that concatenated-index version was tried and measured far
worse (0 BSRAM, everything fell back to flip-flops, logic and registers both roughly 1.7x
higher), because yosys's memory pass wants a plain index signal, not a concatenation expression.
Two separate arrays in one module do not yet reduce the *measured* BSRAM count below one-per-
receiver (yosys's generic `stat` here counts each inferred memory object as its own primitive; it
does not pack two small, separately-inferred memories into one physical block the way Gowin's own
place-and-route might -- ARCHITECTURE.md 3.14's own methodology notes this generic-synthesis
limitation), but the module is structured so that packing, if the real Gowin flow does it, would
show up automatically without any further RTL change.

Closing the gap (getting `cic_var_shared`'s state into real BSRAM) needs the accumulator array
restructured so the *only* writes to it are of the shape `mem[svc_idx] <= ...` (a single runtime
index, not a `for`-loop-scanned one) for the arithmetic path, plus a separate, slower sweep for
per-context reset clearing (the same technique `fir_decim.v` already uses for the ring's own
reset, `clr_addr`) instead of a per-cycle, all-context conditional clear -- both real,
non-trivial rework, not attempted in this WP given the risk of destabilising the correctness
work above late in the work; left for a follow-up resource-optimisation pass.

## 10. WP RB4: NCO mixer instead of the CORDIC

ARCHITECTURE.md 3.14 change C1. `rtl/rx/nco_mixer.v` replaces the HL2 CORDIC mixer in the
receiver bank (8 instances, `rx_channel.v`), the zoom DDC (`rtl/zoom/zoom_ddc.v`) and, in its
transmit mode, the TX chain (`rtl/tx/tx_chain.v`, where it replaced `cpl_cordic.v`). It keeps the
CORDICs' gain (52.696, measured on their RTL), sign convention (`x e^(+jt)`, zero phase offset),
output widths (18 bits receive, 31 bits transmit), strobe gating and valid tracking, so nothing
downstream changed.

### 10.1 Design

- **Phase accumulator**, 32 bits, `phase <= 0` while the frequency word is 0 (as the CORDIC).
- **Table**: T[k] = round(107,922 sin((k + 0.5) pi / 2048)), k = 0..1023 (a quarter wave, 18-bit
  entries, all positive). The half-step offset makes T[1023 - k] the cosine of T[k]'s angle, so
  one read gives sine and cosine. Stored as 512 words of 36 bits, {T[j], T[1023 - j]}: one
  single-port 512 x 36 ROM, **one block RAM** by Gowin place-and-route's count; address
  min(k, 1023 - k), halves swapped for k >= 512. Written as a 1,024 x 18 ROM with two read ports,
  Gowin synthesis builds two ROMs (2 BSRAM, measured). The amplitude 107,922 = 52.696 x 2,048
  sets the gain. `tools/gen_nco_table.py` writes `rtl/rx/nco_sin_table.hex`.
- **Quadrant**: odd quadrants use the mirrored angle (the 30 in-quadrant phase bits inverted), so
  the table always gives sine and cosine of the in-quadrant angle; the quadrant then only sets two
  signs, applied to the 12-bit sample (receive) or to the 18-bit sine and cosine (transmit).
- **Taylor correction**: residual d = the 10 phase bits below the table address, centred on the
  table sample by an appended 1 bit (|d| <= pi / 4096). sin(a + d) = sin a + d cos a and
  cos(a + d) = cos a - d sin a: 2 multiplies (19 x 18 bits). The factor 2 pi (d is in phase
  units) is 201/32 = 6.28125, made with two small adds (3d and 9d, then 64 x 3d + 9d); its 3e-4
  relative error is at most 0.03 table steps.
- **Widths**: receive mode keeps E = 4 extra fraction bits in the corrected sine and cosine
  (22 bits, on the DSP's 27-bit port against the 13-bit signed sample); transmit mode keeps
  E = 0 (18 bits), because its 24-bit samples need the 27-bit port. Correction truncated
  (floor). Receive output rounded half up to 18 bits; transmit output floor to 31 bits (the TX
  chain rounds again after its own shift).
- **4 multiplies**: 2 for the correction, 2 for the mix, each at most 27 x 18 (1 DSP each).
- **Latency**: 7 accepted samples (receive) and 8 clocks (transmit), against the CORDICs' 17 and
  28. Only the fixed delay changes; every consumer works on strobes.

### 10.2 Why these sizes (error budget, relative to a full-scale output tone of 107,922 steps)

| Source | Size | Level |
|---|---|---|
| table rounding (18-bit entries) | 0.5 step | -106.7 dB at one point; noise-like over random tuning words |
| receive output rounding (18 bits, as the CORDIC) | 0.5 LSB | -106.7 dB, noise-like |
| Taylor remainder d^2/2 | 3e-7 | -130 dB |
| residual truncation (10 bits) | 0.04 step | -128 dB |
| 2 pi as 201/32 | 0.03 step | -131 dB |
| correction floor, E = 4 | 1/16 step | -124 dB |

Explored on a bit-exact Python model before the RTL (40 random tuning words, worst mixer spur):
E = 4 with 10 or 12 residual bits 120.6 dBc; 8 residual bits 118.0; E = 2 115.4; E = 0 104.3.
E = 6 gained nothing: table and output rounding are the floor. A wider table entry does not fit
one block RAM (1,024 x 18 is its full size), and the output rounding is fixed by the 18-bit
interface to the CICs. Structured tuning words (fs/4, fs/8, 3 fs/16, fs/3, fs/10 with coherent
input tones, where all errors repeat with a short period) gave 101.0 dBc at worst.

### 10.3 Measured (done test)

**Standalone** (`python tools/rb4_nco_sfdr.py`, the RTL under iverilog via
`sim/rx/nco_sfdr_sim.v`): 1,000 random tuning words, a full-scale 12-bit tone at a random
frequency and phase, 4,096-point FFT (Kaiser window, beta 38). A real input tone gives two output
tones, both excluded. The CORDIC column is the same test run on `master`.

| | NCO mixer | CORDIC |
|---|---|---|
| mixer spurious-free range: worst bin of (output - ideal output), ideal = exact mix of the same 12-bit input words | **117.3 dBc** worst, 121.7 median | 98.4 worst, 104.7 median |
| output spurious-free range (includes the input tone's own 12-bit quantisation spurs) | 85.5 worst, 92.8 median | 85.5 worst, 92.6 median |
| same, ideal mixer on the same input | 85.5 worst | 85.5 worst |
| tone level against the ideal mixer | **0.00001 dB** worst | 0.00004 dB |

The raw output spectrum cannot reach 100 dBc with any mixer: a full-scale 12-bit tone carries its
own quantisation spurs (85.5 dBc at worst over these 1,000 tones), which an ideal mixer passes
unchanged. The mixer's own spur level is therefore measured on the difference between its output
and the ideal output for the same input words; the NCO mixer moves the worst raw spur of any case
by at most 0.27 dB. `sim/rx/tb_nco_mixer.v` (in `tools/check.sh`) checks every output of both
modes against the ideal mix within a bound (receive: 1.05 LSB at most, bound 1.15), the latency,
gapped strobes, frequency 0 and reset.

**In place**, against the CORDIC version (`master`, same tests, same day):

| Test | CORDIC | NCO |
|---|---|---|
| Receiver alias rejection, `sim/run_sim.sh`, worst per rate 48/96/192/384 ksps | 122.6 / 121.7 / 120.7 / 91.1 dB | 122.6 / 121.7 / 120.7 / 91.1 dB |
| Receiver functional test, `sim/run_sim.sh`, 9 tones | within 0.17 dB, 0.9 Hz | within 0.17 dB, 0.8 Hz |
| `tb_alias.v` (384 ksps, `cic_fixed` worst case) | 91.1 dB | 91.3 dB |
| Zoom alias rejection, `sim/zoom/zoom_alias_sim.v`, widest span / the other six | 79.6 / 83.2 dB | 79.6 / 83.2 dB |
| TX two-tone, `sim/tx/tb_tx_chain.v`, worst spur | -92.9 dBc | -93.0 dBc |
| R2: `tr-rxmodel` against the RTL (`r2_check`) | 1,360 words bit-exact | 1,360 words bit-exact; model 26.6 Msps (was about 18) |

The word-for-word checks of the later work packages keep working: `tb_rb3_compare.v` (RB3),
`zoom_rb1_compare_sim.v` and `zoom_rb1_burst_sim.v` (RB1), `tb_tx_chain_rb2_equiv.v` (RB2). Their
reference copies (`sim/rx/ref/rx_channel.v`, `sim/zoom/ref/zoom_ddc_ref.v`,
`sim/tx/ref/tx_chain_ref.v`) now instantiate the same NCO mixer; all pass.

### 10.4 Resources and timing

| | yosys (`tools/yosys_res.sh`) | Gowin, place-and-route at 150 MHz (`gowin/res.sh --wrap`) |
|---|---|---|
| `nco_mixer`, receive | 4 DSP, 1 BSRAM, 261 logic, 424 registers | 4 DSP, 1 BSRAM, 306 logic, 203 registers, **Fmax 191.0 MHz** |
| `nco_mixer`, transmit | 4 DSP, 1 BSRAM, 273 logic, 680 registers | inside `tx_chain` (its paths +0.18 ns slack) |
| `rx_bank` (8 receivers) | 40 DSP, 16 BSRAM, 18,627 logic, 21,285 registers (CORDIC: 8, 8, 41,953, 24,613) | RB10 |
| `zoom_ddc` | 8 DSP, 6 BSRAM, 7,023 logic (CORDIC: 4, 5, 9,976) | RB10 |
| `tx_chain` | 5 DSP, 1 BSRAM, 2,426 logic (CORDIC: 1, 0, 6,301) | 5 DSP, 3 BSRAM, 1,855 logic, 2,064 registers, **Fmax 142.4 MHz** (was 119.8) |

yosys counts one BSRAM per inferred memory, so its 16 for the bank is the 8 FIR delay-line memories
plus the 8 tables. `tx_chain` now fails 150 MHz only on 30 paths inside `CicInterpM5`: the `pace`
clock enable reaching every CIC register (0.36 ns short); no CORDIC or mixer path remains among
them.

## 11. Decision: shared-CIC state stays in flip-flops (2026-09-27)

Branch `rx-cicram` (commit fcf287c, kept unmerged for reference; its section 10 has the full analysis)
moved the shared variable-CIC state into block RAM. It stayed bit-exact, but because each context's
state (5 integrators + 5 combs, 43 bits each) must be read and written in one step to keep up with
61 M context updates/s, it needed about 18 BSRAM per engine: 44 BSRAM for the bank instead of 8,
for a saving of about 7-11k registers and about 3k logic (yosys). Registers are not a scarce resource
on this chip; block RAM is (ledger in ARCHITECTURE 3.14), and the Gowin place-and-route of that
version did not finish in 90 minutes. The RB3 version was therefore kept (state in
flip-flops). Revisit only if Gowin measurements show the receiver bank's logic, not registers, is the
problem.
