<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# A1 - audio engine

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Work package A1 (docs/PLAN.md), design section docs/ARCHITECTURE.md 3.7. Board facts:
docs/BOARD.md "Audio" section. Everything here is simulation-only (iverilog, oss-cad-suite); the
board has not arrived yet (docs/DECISIONS.md: expected 2026-09-29).

## 1. What this builds

Firmware writes 48 kHz stereo int16 PCM into a ring buffer in DDR3. This work package takes it
from there to the PT8211 DAC pins, and hands the same 48 kHz samples off to the HDMI audio path
(built in another work package, branch `v1-video`):

```
DDR3 ring --> audio_ring_reader --> audio_interp_x8 (x8, 48k->384k) --> audio_pt8211_tx --> BCK/WS/DIN pins
                    |
                    +--> hdmi_audio_l/r + hdmi_audio_valid (48 kHz, see section 5)
```

Files:

| File | What |
|---|---|
| `rtl/audio/audio_ring_reader.v` | DDR3 ring read, small prefetch FIFO, HDMI tap |
| `rtl/audio/audio_interp_x8.v` | x8 polyphase FIR interpolator |
| `rtl/audio/audio_interp_coeffs.hex` | its 144 filter coefficients (generated, see below) |
| `rtl/audio/audio_nco_tick.v` | generic fractional-rate tick generator (NCO) |
| `rtl/audio/audio_pt8211_tx.v` | PT8211 BCK/WS/DIN generation |
| `rtl/audio/audio_engine.v` | wires the three together, top-level ports |
| `tools/gen_audio_interp_coeffs.py` | regenerates the coefficient file from the filter design |
| `sim/audio/ddr3_behav_model.v` | behavioural DDR3 stand-in (sim only) |
| `sim/audio/tb_audio_ring_reader.v` | ring reader test |
| `sim/audio/tb_audio_interp_x8.v` | interpolator test (image rejection, this WP's done-test) |
| `sim/audio/tb_audio_pt8211_tx.v` | serializer test (pin-level decode) |
| `sim/audio/tb_audio_engine.v` | end-to-end test (this WP's done-test, full chain) |

All five pass under `bash tools/check.sh`.

## 2. PT8211 timing, from the datasheet

docs/BOARD.md already cites the datasheet (`https://www.pjrc.com/store/pt8211.pdf`) for the
headline facts (16-bit, two's complement, MSB first, LSB-justified, no master clock, 8x
oversampling at 48 kHz supported). Fetching the datasheet directly for this work package to get
exact bit-level timing found:

- **Format** ("FUNCTION DESCRIPTION"): "The serial bus input data format of PT8211 is Japanese or
  called LSBJ (Least Significant Bit Justified) format. Each valid DIN data will be shifted to
  the input register in the rising edge of the BCK... The DIN data must be the 2's complementary
  format and the MSB (Most Significant Bit) must be the first. When the Word Select (WS) clock in
  the Low level, the DIN data will be shifted to the right input register. likewise, the DIN data
  will be shifted to the left input register when WS clock in the High level."
- **Timing Characteristics table**: bit clock frequency (Fbck) max **18.4 MHz**, word clock
  frequency (Fws) max 384 kHz, input data rate max 18.4 Mbit/s, H-level time min 25 ns, rise/fall
  time max 20 ns each.

**Discrepancy worth flagging**: the datasheet's own prose in "FUNCTION DESCRIPTION" says "The
clock frequency of the BCK could run up to 20MHz", but the numeric Timing Characteristics table
(the one that actually carries a Min/Typ/Max column) caps Fbck at 18.4 MHz. docs/BOARD.md's "BCK
up to 20 MHz" note was written from the prose. This design's BCK (12.288 MHz, see section 4)
clears both figures, with 33% margin below the datasheet's own 18.4 MHz table limit (39% below
the 20 MHz prose figure), so it does not matter for this work package, but it
would matter if a future change pushed the oversampling ratio or word rate higher.

With 16 bits per channel and exactly 16 BCK cycles available per WS half-period (this design's
BCK = word rate x 32, see section 4), LSBJ and I2S/left-justified framing coincide: there is no
padding, so bit 0 of each channel (MSB) is captured on the first BCK rising edge after the WS
edge and bit 15 (LSB) on the 16th, right before the next WS edge. `audio_pt8211_tx.v` uses this
directly: `din` is a pure function of a single 0-31 bit-position counter (`idx`), changed on the
BCK falling edge (a full half-period of setup before the capturing rising edge).

## 3. Ring reader

`audio_ring_reader.v` reads one 32-bit word (one packed {L,R} pair) at a time from a generic,
single-outstanding memory read port, into an 8-entry prefetch FIFO, and streams samples out on a
plain valid/ready port. The memory port is deliberately generic (docs/PLAN.md WP F4, the shared
DDR3 read-lane arbiter that docs/ARCHITECTURE.md 3.9 reserves a place for "audio and TX rings" on,
does not exist yet); `sim/audio/ddr3_behav_model.v` is a fixed-latency behavioural stand-in used
only in simulation. Wiring the real port is left to whichever work package integrates F4.

`sim/audio/tb_audio_ring_reader.v` writes 200 distinct sample pairs into a ring only 16 words
deep (so the ring wraps more than 12 times over the course of the test), respecting the same
"don't overwrite what the reader has not fetched yet" flow control real firmware must observe,
and checks all 200 come out of both the main port and the HDMI tap, in order, unchanged. **PASS.**

## 4. x8 interpolator

### 4.1 Filter design

A single 144-tap FIR (not a cascade of half-band stages), used in an 8-way polyphase structure
(18 taps per phase - 144 divides evenly, no padding phase). Designed with
`scipy.signal.remez` (Parks-McClellan): passband 0-18 kHz, stopband from 28 kHz (=
48 kHz - 20 kHz, the nearest zero-stuffing image edge for audio content up to 20 kHz), evaluated
at the interpolated (384 kHz) rate. `tools/gen_audio_interp_coeffs.py` does this and writes
`rtl/audio/audio_interp_coeffs.hex`; re-run it if the filter design ever changes (the two files
must be regenerated together, not hand-edited).

Coefficients are quantized to 18-bit signed, Q17 (scale 2^17). Quantized-filter response (a
floating-point `freqz` evaluation of the quantized coefficients, not yet the fixed-point RTL
itself):

| Measure | Value |
|---|---|
| Passband ripple, 0-18 kHz | 0.0081 dB |
| Worst-case stopband level, >= 28 kHz | **-65.69 dB** |
| DC gain (sum of taps / 2^17) | 0.999542 (not exactly 1 - see section 4.3) |
| Group delay | 71.5 samples at 384 kHz = 186.2 us = 8.9375 samples at 48 kHz |

A plain CIC interpolator (the usual cheap choice for x8) was considered and rejected: with the
zero-stuffing image starting right at 28 kHz (48 kHz - 20 kHz) and needing to be down 60 dB
there, a CIC's sinc^N rolloff cannot get there without either enormous order or ruinous passband
droop (checked numerically: an order-8 CIC interpolate-by-8 only reaches about -44 dB at the
image edge for 20 kHz content, at the cost of 20.8 dB of passband droop - see the log of this
work package's design work for the sweep). A single remez-designed FIR reaches -65.69 dB with
0.008 dB of ripple.

### 4.2 RTL

`audio_interp_x8.v` is a sequential (one-multiply-per-clock, per channel) implementation: an
18-tap dot product, one multiply-accumulate per clock, driven by a `frame_tick` (384 kHz average,
see section 5). At clk_dsp = 120 MHz (docs/ARCHITECTURE.md section 2) a frame is about 312 clocks
long; the 18-cycle MAC pass finishes with about 370 clocks to spare, so there was no reason to
build a parallel/pipelined multiplier tree for this work package. Plain Verilog `*` is used and
left for synthesis to map onto the GW5AST's embedded multipliers; place-and-route timing closure
at 150 MHz is not yet checked (that belongs with WP R3-style Gowin-primitive wrapping, not here).

One implementation bug is worth recording because it was silent in the frequency-domain test
until fixed: the new 48 kHz sample is captured at the same clock edge the last phase (phase 7) of
the current output block starts computing, and phase 7's computation still needs the *old*
(pre-shift) delay line. Shifting the delay line on that same edge made the phase-7 MAC read
already-shifted data on the following cycle - silently computing the wrong phase's output on 1
sample in 8. The fix (`shift_pending`/`pend_l`/`pend_r` in `audio_interp_x8.v`) defers the actual
shift until that in-flight MAC pass finishes reading the old contents. Caught by the image-level
test in section 4.4 reading -12 to -14 dB instead of -60-plus before the fix.

### 4.3 Known gain

The 144 taps do not sum to exactly 2^17 (0.999542x instead), and the 8 individual polyphase
phases do not sum to exactly equal values either (see the table below) - both are consequences of
designing a general lowpass rather than a Nyquist/interpolating filter with special constraints
on the tap sums. The practical effect, checked in `sim/audio/tb_audio_engine.v`, is that a
constant (DC) input does not interpolate to an exactly constant output: it settles to one of 8
slightly different values depending on which of the 8 output phases is being produced, cycling
with the 384 kHz output:

| Phase | Tap sum | 12000 -> | -9000 -> | 32000 -> | -32000 -> |
|---|---|---|---|---|---|
| 0 | 16386 | 12001 | -9001 | 32004 | -32004 |
| 1 | 16368 | 11988 | -8991 | 31969 | -31969 |
| 2 | 16376 | 11994 | -8996 | 31984 | -31984 |
| 3 | 16376 | 11994 | -8996 | 31984 | -31984 |
| 4 | 16376 | 11994 | -8996 | 31984 | -31984 |
| 5 | 16376 | 11994 | -8996 | 31984 | -31984 |
| 6 | 16368 | 11988 | -8991 | 31969 | -31969 |
| 7 | 16386 | 12001 | -9001 | 32004 | -32004 |

(Computed by the exact `round_sat` rule in section 4.2, not estimated; matches what
`tb_audio_engine.v` checks against and what the RTL actually produces.)

The spread (phase 0 vs phase 1, about 35 out of 64000 peak-to-peak at full scale) is itself just
the filter's own image rejection applied to a 0 Hz tone - consistent with, not contradicting, the
-60 dB figure in section 4.4 (20*log10(35/64000) = -65.2 dB). This is the "known gain" the done-test
allows for: not unity, but exactly computable from the coefficient file, and what
`tb_audio_engine.v` checks the decoded PT8211 pins against exactly (not a tolerance).

A related test-writing trap, recorded here in case a similar test is written again: phase 0 and
phase 7 (and phase 1 and phase 6) come out to the *same* expected value in the table above, since
`audio_interp_coeffs.hex` is symmetric (a linear-phase FIR). A first version of
`tb_audio_engine.v`'s scoreboard picked its 8-phase rotation alignment by matching only the first
sample of a check window, which - because of that coincidence - could lock onto the wrong
rotation and then legitimately fail on the following samples even though the RTL was correct.
Fixed by requiring a full-window match before accepting a rotation (see the comment in that
file). The bug in section 4.2 above was found and fixed *before* this test bug was found; both
were real, in different places.

### 4.4 Done-test: image rejection (measured)

`sim/audio/tb_audio_interp_x8.v` feeds three full-scale tones (12, 15 and 18 kHz - representative
of audio content up to the filter's 18 kHz passband edge) through the interpolator and measures,
with a Goertzel single-bin DFT exact at both the tone's own frequency and its nearest
zero-stuffing image (at 48 kHz - f0), the image level relative to the tone. All bins are chosen
as exact multiples of the analysis window's frequency resolution (125 Hz, from a 3072-sample
window), so there is no spectral leakage in the measurement.

| Tone | Image | Measured level (relative to the tone) |
|---|---|---|
| 12 kHz | 36 kHz | -68.40 dB |
| 15 kHz | 33 kHz | -84.06 dB |
| 18 kHz | 30 kHz | **-67.63 dB** (worst measured) |

All three clear the -60 dB requirement with margin (the worst, at the filter's own designed
passband edge, is 7.6 dB below the requirement). This is consistent with the -65.69 dB
whole-stopband worst case from the filter design in section 4.1 (that number is taken right at
the 28 kHz stopband edge, which is what a 20 kHz tone - just past this test's 18 kHz - would
image to). **PASS.**

## 5. PT8211 serializer

`audio_pt8211_tx.v` generates BCK, WS and DIN. BCK = 384 kHz x 32 = 12.288 MHz (comfortably under
both PT8211 figures in section 2). 120 MHz / 12.288 MHz is not an integer (9.765625), so a
plain clock divider cannot hit this rate; BCK is instead generated by a phase accumulator
(`audio_nco_tick.v`, a standard fractional-N/DDS technique also used directly for the 384 kHz
tick in the interpolator's own testbench). Measured (from the accumulator math, not simulated
directly, since the same computation would either verify itself, but it lines up with the exact
frame-timing seen in every testbench above):

| Signal | Target | Actual (32-bit accumulator) | Error |
|---|---|---|---|
| BCK | 12.288 MHz | 12,288,000.0039 Hz | 0.0003 ppm |
| WS / frame rate | 384 kHz | 384,000.0001 Hz | 0.0003 ppm |

Jitter: any single BCK edge can land up to one clk_dsp period (8.33 ns at 120 MHz) early or late
relative to its ideal time - inherent to this technique. For 16-bit audio, the jitter-noise
formula (SNR_jitter ~ -20*log10(2*pi*f*t_jitter)) says jitter needs to stay under about 141 ns at
20 kHz to keep jitter-induced noise below the -85 dB the PT8211 itself claims (dynamic range,
docs/BOARD.md cites the datasheet's "16-bit dynamic range"); 6.67 ns is over 20x under that,
negligible.

### Done-test: bit-exact decode

`sim/audio/tb_audio_pt8211_tx.v` drives 24 test values (0, +/-full scale, alternating bit
patterns, a ramp) into the serializer and decodes bck/ws/din back into samples with a
bus-functional model of the PT8211 itself (shift a bit in on every BCK rising edge, route to
left/right by WS, MSB first). Every value decodes back exactly. **PASS.**

## 6. End-to-end done-test

`sim/audio/tb_audio_engine.v` is this work package's done-test as written in docs/PLAN.md,
exercised through the full chain: a testbench "firmware" process writes four DC plateaus (12000,
-9000, 32000, -32000) into a behavioural DDR3 ring (RING_SIZE_WORDS = 64, so this also exercises
wraparound), through `audio_engine.v` (ring reader -> interpolator -> serializer), decoded back
from the bck/ws/din pins the same way as section 5's test. Once each plateau has been held long
enough to settle (measured at about 28 input samples for the 18-tap delay line to fully turn
over; this test waits for 34, comfortably more), the decoded samples are checked to exactly equal
the per-phase values in section 4.3's table - the documented "known gain", not raw equality with
the input, per docs/PLAN.md's own wording. **PASS**, all 4 plateaus, all 16 checked samples per
plateau (2 full 8-phase cycles each).

This also exercises the fixed pipeline latency end to end (ring prefetch + interpolator's 23-cycle (18 taps plus its 5-stage timing pipeline, gowin/reports/README.md)
MAC + serializer capture): the test does not assume or hardcode a latency figure, it waits on the
real decoded-sample count, so it passes regardless of exactly how many clocks that latency turns
out to be (measured during development at a handful of decoded samples, dwarfed by the ~48-sample
plateau length).

## 7. HDMI audio hand-off (for branch `v1-video`)

`audio_engine.v` exposes the same 48 kHz samples that feed the PT8211 path as a clean port,
before the x8 interpolation (docs/ARCHITECTURE.md 3.7: "the same 48 kHz samples into the HDMI
audio packets"):

| Port | Width | Meaning |
|---|---|---|
| `hdmi_audio_valid` | 1 | one clk_dsp-cycle pulse per sample, 48 kHz average rate |
| `hdmi_audio_l` | 16, signed | left sample, two's complement PCM, full scale +/-32767 |
| `hdmi_audio_r` | 16, signed | right sample, same format |

Contract: `hdmi_audio_l`/`hdmi_audio_r` are valid and stable on the same clk_dsp cycle
`hdmi_audio_valid` is high; register them on that edge. This is the clk_dsp domain (120 MHz,
docs/ARCHITECTURE.md section 2), not clk_pix - crossing into the pixel-clock domain and building
the HDMI audio sample packets and InfoFrame (docs/ARCHITECTURE.md 3.5: "HDMI audio clock
regeneration (N/CTS) is counted against clk_pix") is v1-video's own work, not done here. No files
under that branch's own work were touched by this work package.

## 8. Left for later

- **AHB register block** (0xE809_0000, docs/ARCHITECTURE.md section 4.1: "audio: ring pointers,
  outputs, sidetone"): not built. `audio_engine.v`'s `ring_base`/`wr_ptr` inputs and
  `ring_low_water`/`interp_underrun` status outputs stand in for it. Building the real register
  page means going through the T3 register-map generator once it exists (docs/ARCHITECTURE.md
  4.1: "Hand-kept copies are not allowed").
- **Shared-DDR3 read-lane arbiter** (WP F4): `audio_ring_reader.v`'s memory port is generic
  single-outstanding word reads; wiring it to the real arbiter is a later integration step.
- **Underrun behaviour**: if the ring reader's FIFO is empty when a sample is needed,
  `audio_interp_x8.v` repeats its last input sample (`underrun` pulses but does not zero the
  output) rather than muting. Not tested here since the ring reader's own prefetch (see section 3)
  keeps this from happening under any of this work package's test conditions; worth a dedicated
  test once real DDR3 arbitration latency (which can vary, unlike the fixed-latency behavioural
  model here) is in the loop.
- **Place-and-route timing** for the interpolator's 18x18 multiply and 40-bit accumulate at
  150 MHz: not checked (see section 4.2).
- **CW sidetone generator** (docs/ARCHITECTURE.md 3.7, listed there as "Later"): not built.
