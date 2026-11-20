<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# tr-dsp: fast-convolution filters, AGC, demodulators, noise blanker, noise reduction, resampler (WP S3)

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Crate: `fw/tr-dsp`. Pure Rust, `no_std`, no allocation (every buffer is a fixed-size array —
see section 1). Builds and tests on the host (`cargo test -p tr-dsp`, used for every number in
this document) and cross-builds for `riscv32imafc-unknown-none-elf`
(`cargo build --target riscv32imafc-unknown-none-elf -p tr-dsp`); both are checked by
`tools/check.sh`.

Depends on one crate: `libm` (pure Rust, no C — the same dependency `docs/ARCHITECTURE.md`
section 5.6 already uses for `tr-gui`/Slint), for `sin`/`cos`/`atan2`/`sqrt`/`exp`/`log10`, none
of which `core` provides without `std`.

**Update (cpu-budget work, `docs/CPU_BUDGET.md` section 4):** the FFT is now a generic radix-4 `Fft<N>`
plus a real-input `RealFft<H>`; complex multiplies use fused multiply-add and square roots use `fsqrt.s` on
the AE350 (`fmath.rs`); the noise reducer is generic over its frame size (`NoiseReducer` at 48 ksps,
`NoiseReducer12k` at 12 ksps) and uses the real FFT; the resampler has a block API. Every measured number in
this document is unchanged except where noted there (instruction counts). Under the new split (ARCHITECTURE
3.10) the filters, demodulators and AGC of this crate are the reference models for the FPGA receiver back
end; the firmware itself runs only the noise reducer and AGC.

## 1. Scope and design choices

- **`no_std`, no `alloc`.** Every filter/demodulator holds fixed-size arrays sized from two
  constants: `fft::FFT_LEN = 1024` and `fastconv::BLOCK = 512`. This was a deliberate choice over
  `no_std` + `alloc`: block and FFT sizes are fixed by the CPU-budget design in
  `docs/ARCHITECTURE.md` section 5.5 (1,024-point fast convolution, 512 new samples/block), so
  there is nothing that actually needs to be sized at runtime, and fixed arrays mean no
  `#[global_allocator]` dependency and no heap fragmentation risk on the interrupt-level hot path
  (section 5.3: the IQ-block interrupt handler is a hard-deadline path). Host tests still use
  `std::vec::Vec` freely — that is test-only plumbing (`#[cfg(test)] extern crate std;` in
  `lib.rs`), not something the library itself does.
- **1,024-point FFT is hardcoded**, not generic over size: `fft::Fft1024` builds its twiddle and
  bit-reversal tables once (`Fft1024::new()`, done at receiver start-up, not per block) and every
  filter/NR stage shares one `Fft1024` instance — it holds no per-filter state, only the
  precomputed tables, so one instance serves every receiver and every filter on it.
- **Pipeline order**: receiver-bank IQ (48/96/192/384 ksps, see section 2) → `resample::Decimator`
  down to 48 ksps if needed → `blanker::NoiseBlanker` (optional, wideband) → the mode's
  demodulator (`ssb`/`cw`/`am`/`fm`, each built on `fastconv::BandpassFilter`) → optional
  `nr::NoiseReducer` on the recovered audio → AGC (built into each demodulator) → audio ring. The
  noise blanker runs *before* the channel filter (impulse energy is wideband, easiest to see
  there); noise reduction runs *after* demodulation, on real audio.

## 2. Receiver-bank input format (from the `rx-dsp` branch)

Read from `docs/RX_DSP.md` (the receiver bank this feeds from) and `docs/ARCHITECTURE.md` section 3.2:

- IQ output: `out_i[23:0]`, `out_q[23:0]` — 24-bit signed two's complement per channel, one
  sample per `out_valid` cycle, tagged with a receiver index (`out_index`) on one shared stream.
- Four selectable output rates: 48, 96, 192, or 384 ksps (`rate_sel` 0..3), all exact integer
  multiples of 48 ksps (decimation from the 76.8 MHz ADC clock is 1600/800/400/200 respectively).
- Gain/group-delay-per-rate and the exact ADC-full-scale-to-output-full-scale gain are listed as
  still-open asks to the `rx-dsp` branch in `docs/ARCHITECTURE.md` section 3.2 (not resolved as
  of this WP) — `tr-dsp`'s filters and AGC do not depend on knowing the absolute scale (AGC
  normalizes to its own reference regardless of input level), so this crate has no open
  dependency on that number, but S4 (`tr-sim`, which wires `tr-hl2` + the receiver model + this
  crate together) will need it for S-meter calibration.

`tr-dsp`'s own IQ type (`C32`, `f32` real/imag) does not itself care whether the 24-bit fixed-point
value is scaled to full-scale ±1.0 or left at raw integer magnitude — whichever convention the
firmware's fixed-to-float conversion uses, AGC in every demodulator normalizes to its own
reference level regardless.

## 3. Modules, design, and measured numbers

All numbers below are from `cargo test -p tr-dsp -- --nocapture` (every test that reports a
number prints a line starting `MEASURED`); test names are given so any number can be reproduced
with `cargo test -p tr-dsp <name> -- --nocapture`.

### 3.1 Fast-convolution bandpass filter (`fastconv::BandpassFilter`, `fft::Fft1024`)

Overlap-save, 1,024-point complex FFT, 512 new samples/block (`fastconv::{FFT_LEN, BLOCK,
OVERLAP, MAX_TAPS}` = 1024/512/512/513). Width and shift are independent: `design(fft, fs,
low_hz, high_hz, shift_hz, ntaps)` — `[low_hz, high_hz]` sets the (possibly one-sided, for
SSB/CW) passband via a Blackman-Harris-windowed-sinc prototype, modulated to sit at
`(low_hz+high_hz)/2`; `shift_hz` is an independent post-filter derotation (an `Nco`, see 3.7)
applied to every output sample. `shift_hz = 0` for plain SSB (the receiver's own LO already sits
at the suppressed carrier); nonzero for CW pitch and RIT-style retuning. See the module doc in
`fastconv.rs` section for the derivation of why width and shift had to be separated (an earlier
version forced `shift = -center`, which is wrong for SSB: it would derotate a one-sided passband
to 0 Hz instead of leaving it at its own frequency).

Measured (`fastconv::tests`, filter `[200, 2800]` Hz at 48 kHz, 513 taps):

- Passband gain at the filter's own center (1,500 Hz): **-0.000001 dB** (`passband_gain_near_unity`).
- Stopband rejection, a tone at 8,000 Hz (well past the 2,800 Hz edge): **143.1 dB**
  (`stopband_rejects_out_of_band_tone`) — far more than the ~50 dB a 513-tap Blackman-Harris
  design predicts by hand; the tone happens to land in a very deep sidelobe null, so treat 143 dB
  as this specific test tone's number, not a general guarantee (the design guarantees the
  Blackman-Harris window's ~92 dB sidelobe floor, not better).
- `shift_hz = 0` leaves a tone's frequency unchanged (`zero_shift_leaves_frequency_unchanged`);
  `shift_hz = 700` translates a tone at the filter's own center to exactly 700 Hz
  (`nonzero_shift_translates_frequency`) — both within 2 Hz.

Cost: one `Fft1024::forward` + one `Fft1024::inverse` (5×1024×log2(1024) = 51,200 flops each,
the same convention `docs/ARCHITECTURE.md` section 5.5 already uses) + 1,024 complex bin
multiplies (6,144 flops) = **108,544 flops per 512-sample block = 212 flops/sample**, i.e.
10.2 Mflop/s at 48 ksps (94 blocks/s) — matches the architecture doc's own estimate for this
stage exactly (it was designed to this budget, not measured against it after the fact).

### 3.2 AGC (`agc::Agc`)

Attack/hang/decay: error-feedback exponential smoothing toward the gain that would put the
current sample exactly at `reference`, with a hang counter that holds gain after a loud sample
before decay resumes. Cost: ~5 flops/sample (one reciprocal, one clamp, one multiply-add).

Measured (`agc::tests`, 48 kHz, reference 1.0, a 2x step for attack/decay):

- Attack, 5 ms time constant: settles to within 5% of the full step in **14.96 ms**
  (`attack_time_matches_time_constant`) — inside the expected 1.5-17.5 ms window for a first-order
  exponential's ~3 time-constant, 95%-of-step settling.
- Decay, 300 ms time constant: reaches 63% of its step in **298.3 ms**
  (`decay_time_matches_time_constant`) — within 1% of the programmed time constant, as expected
  (63% is the definition of one time constant).
- Hang, 100 ms: gain held to within **0** (exactly, `f32`-exact) over the whole 100 ms hang
  interval, then resumes decaying afterward (`hang_holds_gain_before_decay`).

### 3.3 SSB (USB/LSB) (`ssb::SsbDemod`)

`BandpassFilter` with a one-sided passband (`[300, 2700]` Hz for USB, mirrored below 0 for LSB),
`shift_hz = 0`, detector is `Re{}` of the filtered signal, then `Agc`.

Measured (`ssb::tests`, 48 kHz, a synthetic single-tone SSB signal — see the module doc for why a
lone complex sinusoid at `carrier + audio_hz` *is* the correct complex-baseband model of a
single-tone SSB signal, not a simplification):

- USB, 1,000 Hz test tone: **111.0 dB** SNR (`usb_demodulates_tone_at_correct_frequency`).
- LSB, 1,000 Hz test tone: **111.0 dB** SNR (`lsb_demodulates_tone_at_correct_frequency`).
- Opposite-sideband rejection (measured on the filter directly, bypassing AGC — see the code
  comment for why AGC's own gain-hunting on a near-silent residual is a misleading rejection
  metric): **125.8 dB**.

Cost: filter cost (3.1) + ~1 flop/sample (`Re{}` is free) + AGC (3.2).

### 3.4 CW (`cw::CwDemod`, `cw::KeyShaper`)

Receive: structurally identical to SSB — a narrow symmetric `BandpassFilter` (e.g. 300 Hz wide)
with `shift_hz = pitch_hz`, so the recovered carrier plays at the operator's chosen sidetone
pitch regardless of a few tens/hundreds of Hz of tuning error within the passband.

Transmit: `KeyShaper` is a raised-cosine 0..1 envelope generator (`0.5 - 0.5*cos`), ramping over a
configurable `ramp_ms` on every key transition, tracking from wherever the envelope currently is
(so rapid re-keying mid-ramp does not click).

Measured (`cw::tests`, 48 kHz):

- Demod: pitch 700 Hz, carrier 50 Hz off-tune (realistic tuning error), 300 Hz filter: **41.2 dB**
  SNR at the expected 750 Hz output (`demod_recovers_pitch_tone_with_good_snr`).
- Key shaping: 5 ms ramp reaches 1.0 within 1e-3, returns to 0.0 within 1e-3, and never steps by
  more than 0.05 in one sample (no click) (`key_shaper_ramps_smoothly_and_reaches_targets`).

Cost: same as SSB (3.3) for the demodulator; the key shaper costs one `libm::cosf` only while
actively ramping (a few hundred samples per key transition), free at rest.

### 3.5 AM (`am::AmEnvelopeDemod`, `am::AmSyncDemod`)

Envelope: symmetric `BandpassFilter` (`shift_hz = 0`) → `|z|` → one-pole DC removal (~20 Hz
corner) → AGC. Synchronous: same filter → a slow (~15 Hz corner) one-pole complex low-pass
tracks the carrier phasor (the strongest, most nearly-DC component of a narrowband AM signal is
the carrier itself, so low-passing the raw complex signal is a cheap carrier tracker with no
separate PLL/NCO) → project the filtered sample onto that tracked phase (`Re{f * conj(unit
carrier)}`) → DC removal → AGC.

Measured (`am::tests`, 48 kHz, 1,000 Hz test tone, modulation index 0.7, 2,500 Hz half-bandwidth):

- Envelope: **53.7 dB** SNR (`envelope_demod_recovers_tone`).
- Synchronous, with a static 90-degree carrier phase offset (which would zero out a naive `Re{}`
  detector with no tracking): **35.8 dB** SNR (`sync_demod_recovers_tone_despite_carrier_phase_offset`).

Cost: filter (3.1) + envelope ~3 flops/sample (`sqrt`) or sync ~10 flops/sample (complex EMA +
projection) + AGC (3.2).

### 3.6 FM (`fm::FmDemod`, `fm::Squelch`)

Symmetric `BandpassFilter` (`shift_hz = 0`) → quadrature discriminator (`arg_turns(z[n] *
conj(z[n-1])) * fs`, normalized by `|z[n-1]|^2` so it does not depend on signal level) →
one-pole de-emphasis (50/75 us standard time constants, 0 to disable) → amplitude-threshold
squelch with hysteresis (mutes when the smoothed RF level drops below a threshold; noted as a
simplification — a noise-derived squelch is future work, see section 6).

Measured (`fm::tests`, 48 kHz, NBFM-ish parameters — 2.5 kHz deviation, 1 kHz test tone, 6 kHz
half-bandwidth channel filter; see the code comment on why a much higher deviation/tone ratio
needs a wider channel filter than this 513-tap design comfortably supports without distortion at
the passband edge, which is what the first version of this test hit):

- Discriminator: **37.3 dB** SNR, recovered peak deviation **2,499.6 Hz** (programmed 2,500 Hz)
  (`discriminator_recovers_audio_tone`).
- De-emphasis (75 us): **8.36 dB** rolloff between 100 Hz and 5,000 Hz
  (`deemphasis_attenuates_high_audio_frequencies`) — matches the analytic single-pole response
  (`fc = 1/(2*pi*75us) = 2,122 Hz`) to within 0.2 dB.
- Squelch: opens on a strong signal, stays closed on a weak one, and closes again once the signal
  drops, all confirmed with hysteresis (`squelch_opens_above_threshold_and_closes_below`).

Cost: filter (3.1) + discriminator ~10 flops/sample plus one `libm::atan2f` (the dominant cost —
budget ~20-30 flops for a typical software `atan2`) + de-emphasis ~2 flops/sample + squelch
~3 flops/sample ≈ **35-40 flops/sample** on top of the filter.

### 3.7 NCO (`nco::Nco`)

A rotating unit complex phasor (`phasor *= step` each sample), periodically renormalized (every
256 samples) to counter `f32` magnitude drift from repeated multiplication. Used for the fast-conv
filter's `shift_hz` derotation and as a general tone/BFO generator.

This module exists partly because of a real bug found and fixed while building the FM tests (see
section 6): a *different*, naive way of generating a swept-frequency test tone — accumulating a
running phase in turns via repeated `f32` addition, unbounded — accumulates error that grows
roughly with the *square* of the sample count once the accumulator itself grows large (each
addition's rounding error scales with the accumulator's own magnitude), reaching a full turn of
phase error by ~40,000 samples in one measurement. `Nco` does not have this problem because it
never accumulates an angle — it rotates a bounded-magnitude complex number instead. Measured
(`nco::tests`): magnitude stays within 1e-4 of 1.0 over 200,000 samples
(`stays_unit_magnitude_over_many_samples`); recovered instantaneous frequency matches the
programmed frequency to within 0.01 Hz (`frequency_matches_phase_advance_per_sample`).

Cost: one complex multiply (~6 flops) per sample, one renormalize (~4 flops) every 256 samples.

### 3.8 Noise blanker (`blanker::NoiseBlanker`)

Time-domain, runs on wideband IQ before the channel filter. Per-sample magnitude vs. a
leaky-minimum-tracked noise floor (fast down, ~1 ms; slow up, configurable — the same asymmetric
technique `nr::NoiseReducer` uses per FFT bin, see 3.9): when a sample exceeds the floor by
`threshold_factor`, the blanker holds the last good sample (not zero — zeroing would itself
inject a broadband click) for `hold_ms`.

Measured (`blanker::tests`, 384 ksps, a 1,000 Hz/0.1-amplitude tone with 5.0-amplitude, 3-sample
impulses every ~10.4 ms, 6x threshold, 0.1 ms hold, 20 ms floor rise time):

- Peak amplitude after blanking: **0.100** (impulses fully removed; unblanked peak was 5.0).
- Recovered tone amplitude: **0.09999** (programmed 0.1) — blanking a ~1% duty cycle of impulses
  cost negligible tone amplitude.

Cost: ~5 flops/sample (one magnitude via `abs()`, one compare, one IIR update) — no FFT, cheap
enough to run on every receiver's wideband stream even when only some receivers are audible.

### 3.9 Spectral noise reduction (`nr::NoiseReducer`)

STFT (overlap-add) spectral subtraction, sharing the same 1,024-point/512-hop structure as the
channel filter (50% hop satisfies the *periodic* Hann window's constant-overlap-add condition —
see section 6 for a bug this caught: the *symmetric* Hann window, correct for the FIR designs in
`window.rs`, is NOT COLA-correct at 50% hop and was the wrong window here at first). Per-bin noise
floor: the same leaky-minimum technique as the noise blanker (fast down, slow up), gain =
`max(1 - strength * noise_est/mag, gain_floor)` (classic Boll 1979 spectral subtraction).

**Important limitation, found while testing (see section 6): this only works on signals with real
gaps of silence.** A continuous, never-keyed tone is not a solvable case for any minimum-statistics-
style tracker at any tuning: with no gap, "the quietest this bin ever gets" *is* the tone's own
level, not the background noise, so the tracker cannot tell them apart — this is a property of the
algorithm family, not a bug. CW and speech both have natural gaps; this module is meant for them,
and is measured accordingly.

Measured (`nr::tests`, 48 kHz, a 1,000 Hz tone keyed 100 ms on/100 ms off in continuous broadband
noise of equal amplitude to the tone, strength 0.9, gain floor 0.1):

- SNR **-2.9 dB before, +1.4 dB after** (`improves_snr_of_a_keyed_tone_in_broadband_noise`) — a
  4.2 dB improvement on a deliberately harsh test signal (noise as loud as the tone). Real speech/
  CW at more typical SNRs and with the channel filter already run first (this test applies NR
  directly to the raw keyed-tone-plus-noise, not through a channel filter first, to isolate NR's
  own contribution) should see a larger improvement in the real pipeline.

Cost: one more FFT pair (matching `docs/ARCHITECTURE.md` section 5.5's own description of this
stage) = another 108,544 flops per 512-sample block, plus ~5 flops/bin for the gain computation
(5,120 flops/block) ≈ **113,664 flops/block = 222 flops/sample**, essentially doubling the cost
of channel filtering when noise reduction is enabled on top of it — matches the architecture
doc's "~10 Mflop/s" estimate for this stage (222 flops/sample x 48,128 samples/s = 10.7 Mflop/s).

### 3.10 Rational resampler to 48 kHz (`resample::Decimator`)

Scoped to what this project actually needs (see the module doc): every receiver-bank output rate
is an exact integer multiple of 48 kHz, so a general `L/M` polyphase resampler collapses to a
plain anti-aliased FIR decimator by `M` in `{1, 2, 4, 8}` (`M=1` bypasses filtering — nothing to
decimate or alias). Windowed-sinc design, `8*M+1` taps (capped at 129).

Measured (`resample::tests`):

- Decimate by 2 (96 -> 48 ksps): an 8 kHz in-band tone passes at **0.984** level (input 1.0, so
  -0.14 dB) and lands at the correct frequency after the rate change (within 20 Hz of 8,000 Hz).
- Decimate by 8 (384 -> 48 ksps): a tone that would alias into the decimated band is rejected by
  **120.4 dB** (`decimate_by_8_rejects_a_tone_that_would_alias`).
- `M=1` is an exact, byte-for-byte pass-through (`ratio_one_is_a_pass_through`).

**Cost finding that feeds back into the CPU budget (`docs/ARCHITECTURE.md` section 5.5):** cost
per *input* sample is `4 * ntaps / M` flops (`ntaps = 8*M+1`), which works out to roughly
**32-34 flops per input sample regardless of M** (34 for M=2, 33 for M=4, 32.5 for M=8 — the
`ntaps` scaling with `M` and the `/M` amortization nearly cancel). At a receiver's own native
input rate this is:

| Native rate | M | Input-sample cost | Resampler load |
|---|---|---|---|
| 96 ksps | 2 | 34 flops/sample | 3.3 Mflop/s |
| 192 ksps | 4 | 33 flops/sample | 6.3 Mflop/s |
| 384 ksps | 8 | 32.5 flops/sample | 12.5 Mflop/s |

`docs/ARCHITECTURE.md` section 5.5 bundles the resampler into one receiver's "~15 Mflop/s" line
alongside AGC and demod at an assumed "3 Mflop/s" for the resampler specifically — accurate for a
96 ksps receiver (3.3 Mflop/s measured), but a receiver running at its full native 384 ksps before
decimation costs closer to **12.5 Mflop/s just for the resampler**, about 4x the estimate. This
does not change the architecture doc (out of scope for this WP and the owner's instruction not to
edit `docs/PLAN.md`), but the CPU-budget table (section 5.5) should be revisited with this number
when WP S2 does its measured pass, especially for the "streaming 4 receivers" and "full load"
scenarios that assume higher native rates.

## 4. CPU cost summary (per audible receiver, at 48 ksps output)

| Stage | Flops/block (512 samples) | Flops/sample | Mflop/s at 48 ksps |
|---|---|---|---|
| Channel filter (fast convolution) | 108,544 | 212 | 10.2 |
| AGC | ~2,560 | ~5 | ~0.24 |
| SSB/CW extra (`Re{}`) | ~512 | ~1 | ~0.05 |
| AM envelope extra | ~1,536 | ~3 | ~0.14 |
| AM sync extra | ~5,120 | ~10 | ~0.48 |
| FM discriminator+de-emphasis+squelch extra | ~17,920-20,480 | ~35-40 | ~1.7-1.9 |
| Noise reduction (optional, one more FFT pair) | 113,664 | 222 | 10.7 |
| Noise blanker (optional, wideband, pre-decimation) | ~5 flops/sample at the *input* rate, not 48 ksps | | 0.24-1.9 depending on native rate |
| Resampler (only for receivers not already at 48 ksps) | | 32-34/input sample | 3.3-12.5 depending on native rate (see 3.10) |

These match `docs/ARCHITECTURE.md` section 5.5's own per-stage estimates closely (channel filter
and noise reduction almost exactly, since both were designed to that budget), with one correction
worth carrying forward: the resampler at a receiver's full native rate (384 ksps) costs
meaningfully more than the 3 Mflop/s the architecture doc assumed (3.10).

## 5. `demod_wav` example: real-capture done-test, pending real captures

`docs/DECISIONS.md` ("Testing before the board arrives"): real HL2 captures wait on the owner
connecting an antenna, which had not happened as of this WP. The done-test's "real capture
demodulated to a WAV file that sounds right" half is therefore not runnable yet — but
`fw/tr-dsp/examples/demod_wav.rs` is ready for the moment one exists:

```
cargo run -p tr-dsp --example demod_wav -- <input.cf32> <sample_rate_hz> <mode> <output.wav>
```

`mode` is one of `usb`, `lsb`, `cw`, `am-env`, `am-sync`, `fm`. Input format: raw interleaved
32-bit float IQ (`I0 Q0 I1 Q1 ...`), the same layout as GNU Radio's `.cfile`/`.fc32` — chosen
because the receiver-bank IQ writer's actual on-the-wire framing (WP R1/R3) is not built yet; if
that framing differs, only this file's reader needs to change. `sample_rate_hz` must be one of the
receiver bank's four output rates; anything above 48,000 is decimated down first
(`resample::Decimator`).

**Verified against a synthetic capture** (not a real one, but exercises the whole example
end-to-end): a 2-second, 48 ksps synthetic USB signal (a 1,200 Hz single-tone SSB baseband, see
`ssb.rs`'s module doc for why that is exactly a single complex sinusoid) was written as a `.cf32`
file, run through `demod_wav ... usb ...`, and the resulting WAV's 1,200 Hz content measured back
out at amplitude 0.300 (the demodulator's programmed AGC reference is 0.3) — confirming the
example's file I/O, decimation, and demod plumbing all work correctly end to end. This was a
one-off manual check (not a committed test, since it would need a checked-in binary test fixture
for no real benefit over the unit tests in section 3, which already cover the demodulator math);
the example itself is what matters for when a real capture exists.

## 6. Bugs found and fixed while building this (worth knowing for later WPs)

- **`shift_hz` cannot be derived from the passband edges.** The first version of
  `BandpassFilter::design` forced the post-filter derotation to `-center` of the passband, which
  is right for a general "retune an arbitrary sub-band to 0 Hz" filter but wrong for SSB: SSB's
  passband is intentionally asymmetric (e.g. `[300, 2700]` Hz), and forcing `shift = -1500 Hz`
  moved a correctly-demodulated audio tone to the wrong frequency. Fixed by making `shift_hz` an
  explicit, independent parameter (section 3.1).
- **`f32` phase accumulation is not safe over tens of thousands of samples.** The FM test's first
  attempt at synthesizing a swept-frequency signal accumulated a running phase in turns via plain
  `f32 += ...` without wrapping. Because unwrapped accumulation lets the accumulator's own
  magnitude grow, and each addition's rounding error scales with that magnitude, total error grew
  roughly with the square of the sample count — by 40,000 samples (under 1 second at 48 kHz) it
  had reached a full turn of spurious phase, completely decorrelating the recovered signal from
  what was intended. Fixed by wrapping the phase modulo 1 turn every sample (exact, since `sin`/
  `cos` are periodic). `nco::Nco` does not have this problem at all, because it rotates a
  bounded-magnitude complex phasor instead of accumulating an angle — worth remembering for any
  future code (firmware or test) that needs a running phase over long uptimes.
- **The STFT noise reducer's window must be the *periodic* form, not the *symmetric* one.**
  `window::blackman_harris` (correct for the FIR filter designs in `fastconv`/`resample`, which
  want a window that is exactly zero at both ends of a finite tap array) was reused at first for
  `nr::NoiseReducer`'s analysis/synthesis window. At 50% overlap-add hop, constant-overlap-add
  reconstruction needs the *periodic* Hann window (`cos(2*pi*n/N)`, not `cos(2*pi*n/(N-1))`); the
  symmetric form leaves a small seam at every frame boundary. Fixed by computing a periodic Hann
  window directly in `nr.rs` instead of reusing the FIR-design helper.
- **Spectral-subtraction noise reduction cannot be fairly tested with a continuous tone.** The
  first version of the noise-reduction test used an always-on tone in noise and found NR made SNR
  *worse* (continuous tone: -15 dB after NR; continuous noise alone: only -7.5 dB after NR — the
  tone was being suppressed harder than the noise it was meant to be protected from). This is not
  a bug in `NoiseReducer`; it is a fundamental limit of any minimum-statistics-style tracker
  applied to a signal with no silence in it (section 3.9). Fixed the *test*, not the code: it now
  uses a keyed (on/off) tone, which is representative of what this module actually demodulates.
- **AGC settling-time tests must measure relative to the size of the step, not the absolute
  target value.** An early version of the attack-time test called anything within 5% of the
  *target gain's own value* "settled", which for a large step (gain 100 down to 0.5) demands far
  more time constants than the standard "3 time constants to reach 95% of the step" definition —
  it was measuring against a much smaller number (5% of 0.5) than intended. Fixed by comparing
  against 5% of the actual step size.

## 7. What is not done / open items

- **Real-capture WAV test** (section 5): blocked on the owner connecting an antenna
  (`docs/DECISIONS.md`); the `demod_wav` example is ready.
- **FM squelch is amplitude-threshold, not noise-derived** (section 3.6): simpler, and enough for
  "mute between transmissions", but a real noise-driven squelch (comparing in-band vs.
  just-outside-band energy, or high-frequency discriminator hiss) would perform better on weak
  signals. Noted as future work, not attempted here.
- **Resampler CPU cost at native rates above 48 ksps is higher than `docs/ARCHITECTURE.md`
  assumed** (section 3.10) — a finding to carry into WP S2's measured CPU-budget pass, not a
  change made to the architecture doc itself.
- **Bit-exact receiver-bank model (WP R2)** is a separate, blocked-on-R1 work package; this crate
  does not include it. `tr-dsp`'s filters/demodulators were tested against directly-synthesized
  complex baseband signals (documented per-module above), not against R1's actual RTL output.
- **This crate has no `unsafe` code** and no clippy run wired into `tools/check.sh` (only
  `cargo test` + the two `cargo build` invocations, per the existing script) — a `cargo clippy -p
  tr-dsp` pass was run manually during development (a handful of minor style lints, e.g.
  `needless_range_loop`, left as-is since fixing them would touch working, tested numeric code for
  no functional gain) but is not part of the automated check.
