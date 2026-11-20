<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# Receiver back end in the FPGA (WP R4)

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Branch `r4-backend`. Design summary in [ARCHITECTURE.md](ARCHITECTURE.md) section 3.10; this document is
the full fixed-point specification, the measurements and the verification. Plan entry: [PLAN.md](PLAN.md),
"Proposed by cpu-budget", WP R4.

What the block does: it takes the receiver bank's shared IQ stream (8 receivers at 48, 96, 192 or 384
ksps, [RX_DSP.md](RX_DSP.md)) and turns every receiver into 12 or 24 ksps audio (or IQ) without the CPU:
noise blanker, decimation to 24 ksps, a 1,024-tap complex channel filter whose coefficients the firmware
writes, the demodulator (SSB/CW/data, AM, synchronous AM, FM, IQ pass-through), a log-domain AGC, the
S-meter level, squelch, a half-band to 12 ksps, and output samples stamped with the HL2 sample index.

Files:

| Where | What |
|---|---|
| `tools/gen_rx_backend_tables.py` | designs the half-band filters and writes every constant table twice: `rtl/rx_backend/*.hex`, `bk_consts.vh` for the RTL and `fw/tr-dsp/src/backend/tables.rs` for the model |
| `fw/tr-dsp/src/backend/` | bit-exact Rust model (integers only), coefficient designer, test stimulus, measurements (`tests.rs`) |
| `rtl/rx_backend/` | RTL |
| `sim/rx_backend/` | testbenches (`tb_rx_backend.v`, `tb_rx_backend_ring.v` in `tools/check.sh`; `r4_chain.v` in the full run), `yosys_gw5a.ys` |
| `fw/tr-dsp/examples/r4_check.rs`, `examples/r4_common/` | writes the testbench scenarios and expected results from the model; `tests/r4_fixture.rs` keeps the committed one current |
| `tools/run_r4_full.sh` | full verification run (section 6) |
| `hw/regmap/rx_backend.toml` | register map (draft) |

## 1. Numbers in short

| What | Result |
|---|---|
| Opposite-sideband rejection, USB/LSB 300-2,700 Hz, 1,024 taps | at least 140 dB for mirror tones at 500-2,500 Hz through the integer chain (float design 140-150 dB); integer coefficients within 0.3 dB of the float design down to -150 dB |
| Filter shape against the float design (USB/LSB edges, CW 300 Hz skirts) | within 0.05 dB down to -110 dB, within 0.5 dB down to -126 dB |
| AGC time constants against `tr-dsp::agc` | attack 2/5/20 ms and decay 250/300/1,000 ms within 2 % (each measured in its own domain, section 5.3) |
| Alias rejection of the decimation to 24 ksps | 113 dB (48 ksps in) to 118 dB (384 ksps in) |
| Audio SNR, clean tone, every mode, every input rate | SSB/CW 85-95 dB, AM/SAM 62-67 dB, FM 79-87 dB |
| RTL against the model | word for word equal: quick run (every mode, rate, output rate; 8 receivers; bursty `adc_valid`) in `tools/check.sh`; full run with 1,024-tap filters, real time, 8 receivers at 384 ksps; end to end from the real receiver bank |
| Throughput, 8 receivers at 384 ksps, 1,024 taps | filter unit 64 % busy, decimator 27 %, demodulator/AGC 6 % (measured in simulation) |
| Resources (yosys) | 12 DSP blocks (4 %), 81 block RAMs of 18 kbit (24 %), 16,400 LUT4, 9,300 flip-flops |
| Found on the way | two defects in the receiver bank (R1): it decimated by clocks instead of `adc_valid` pulses, and it repeated samples on its shared stream -- both fixed (section 9) |

## 2. Signal flow

```
bank stream --> input scale --> noise --> half-band x2  --> channel filter --> CORDIC --> demod --> AGC --> half-band --> 16-bit
48-384 ksps     (<< in_shift)   blanker   (1 to 4 times)    1,024 taps          |          |          gain     24 -> 12     + stamp
                                          --> 24 ksps       complex             |          |                   (optional)
                                                                                +--> S-meter, squelch
```

Every receiver has its own state; one engine per stage serves all 8 receivers in turn (section 4).

## 3. Fixed-point design

Conventions: "24-bit scale" means signed 24-bit samples, full scale +/-2^23. All shifts of signed values
are arithmetic (floor). "Round" means add half an LSB, then shift (round half up). "sat24" saturates to
24 bits. The Rust model (`fw/tr-dsp/src/backend/`) is the normative form of every formula here.

### 3.1 Input scaling and noise blanker (bank rate)

- **Input**: the bank's `out_i`, `out_q` (24 bits). The bank's samples use only about 17 of those bits
  (its CIC stages end in 16 bits and the final FIR has unity gain, [RX_DSP.md](RX_DSP.md) section 2; a
  full-scale ADC tone gives |IQ| = 10,043). So the first operation is `x = sat24(in << in_shift)`, per
  receiver, default `in_shift = 6`: a full-scale ADC tone then sits at 2^19.3 (-22.3 dB of the 24-bit
  scale), the largest possible bank sample (about 42,600) at 2.7 M (-9.8 dB), and the bank's LSB
  becomes 64 units, so everything below keeps 6 fraction bits of the bank's resolution for the
  decimation gain. If the bank ever delivers more bits, `in_shift` goes down; nothing else changes.
- **Magnitude**: `mag = max(|i|,|q|) + min/4 + min/8` (alpha-max-plus-beta-min, at most 6.8 % high;
  24 bits unsigned).
- **Floor**: unsigned 24.16 fixed point (40 bits). First sample after enable: `floor = mag << 16`. Then
  `floor += ((mag << 16) - floor) >> k` with `k = k_down` when the magnitude is below the floor and
  `k = k_up` otherwise (time constants 2^k samples; firmware picks k for the rate, e.g. 1 ms down and
  20 ms up at 384 ksps: k_down 9, k_up 13). The floor is updated from every sample, blanked or not, as
  in `tr-dsp::blanker`.
- **Trigger**: when not already holding and `mag * 16 > (floor >> 16) * thr`, with `thr` U4.4 (e.g.
  6.0 = 96). One 24 x 8 multiply.
- **Hold**: on a trigger the next `hold` samples (16 bits) are replaced by the last good sample;
  `blanked` counts them (status register). With the blanker disabled the floor still runs (so turning it
  on is seamless) and no sample is replaced.

### 3.2 Decimation to 24 ksps: half-band cascade

Stages HB1 (384 -> 192), HB2 (192 -> 96), HB3 (96 -> 48), HB4 (48 -> 24); a receiver at input rate
`in_rate` uses the last `in_rate + 1` of them. Equiripple half-bands, pass band +/-9.6 kHz at every
stage, stop band from `fs_in/2 - 9.6 kHz` (the part of the input that would fold into +/-9.6 kHz at the
stage output):

| Stage | Taps (non-zero) | Stop band | Rejection (Q25 coefficients) | Delay line |
|---|---|---|---|---|
| HB1 | 11 (7) | 182.4 kHz | 134.7 dB | 16 words |
| HB2 | 15 (9) | 86.4 kHz | 136.8 dB | 16 |
| HB3 | 23 (13) | 38.4 kHz | 128.9 dB | 32 |
| HB4 | 63 (33) | 14.4 kHz | 104.4 dB | 64 |

Why +/-9.6 kHz and not the +/-10 kHz ARCHITECTURE 3.10 first named: the last stage is the expensive one
and a 100 dB stop band at 10 kHz needs 75 taps (a 128-word delay line); at 9.6 kHz 63 taps give 104 dB and
fit 64 words. Audio at 24 ksps therefore reaches 9.6 kHz, at 12 ksps 4.8 kHz.

Arithmetic: coefficients Q25 in 26 bits (the centre tap is exactly 0.5 = 2^24), data 24 bits, exact
products and sum (under 50 bits), output `sat24((acc + 2^24) >> 25)`. Tap `n` reads `x[w - offset]` from a
circular delay line; taps not yet written since enable read zero. An output is produced after every
second input (2nd, 4th, ... since enable). Why a cascade and not one polyphase filter per ratio: each
half-band has every other coefficient zero, early stages need only 7-9 multiplies at their high rate, and
one coefficient ROM of 62 entries serves all four ratios; the whole cascade costs 5.4 M MAC cycles per
second per receiver at 384 ksps.

### 3.3 Channel filter (24 ksps)

`y[k] = sum_{n < ntaps} c[n] * x[k-n]`, complex coefficients, complex data, `ntaps` 1 to 1,024.

- **Coefficients: 32-bit real and 32-bit imaginary part, plus one exponent `exp` (0-15) per bank**; value
  `c * 2^-(30 + exp)`. The firmware picks the largest `exp` that keeps every coefficient in 32 bits
  (`backend::design::quantize`), so narrow filters keep full precision (a 300 Hz CW filter uses exp 6).
  Why 32 bits, not the 18 bits ARCHITECTURE 3.10 first named: with 18 bits the USB filter's worst
  opposite-sideband point is -90 dB against -140 dB for the float design and the skirts deviate by
  1.5 dB at -80 dB (computed while designing this, section 5.2); with 24 bits -123 dB; with 27 bits
  within 4 dB; with 32 bits within 0.3 dB everywhere. A GW5A DSP block does a 27 x 36 multiply in one
  block (Gowin UG305 `MULT27X36`), so 24-bit data times a 32-bit coefficient still costs one DSP per real
  product. The price is BSRAM (section 7).
- **Data**: 24 bits (the half-band output).
- **Accumulation**: each of the four real products (56 bits) is truncated by 16 bits (floor) and summed
  (`re: cr*xr - ci*xi`, `im: cr*xi + ci*xr`) in 52-bit accumulators; this cannot overflow (at most
  2^49 after 1,024 taps). The truncation costs at most 1/8 LSB of the output.
- **Output**: `sat24((acc + 2^(13+exp)) >> (14+exp))`.
- **Coefficient banks and switching**: a pool of 6 banks per filter unit (unit 0 serves receivers 0-3,
  unit 1 receivers 4-7; section 4). Each receiver has a `bank_sel` register; the unit latches it at the
  start of every output sample, so a switch takes effect exactly between two samples, never inside one.
  The firmware writes a new filter into a bank no receiver of that unit uses, then writes `bank_sel`;
  the status field `bank_cur` shows when the old bank is free. Several receivers may share one bank (all
  FT8 receivers of a unit, for example). This is the double buffering the plan asks for, with 6 banks per
  4 receivers instead of 2 per receiver (8 banks), saving 16 BSRAM blocks.

### 3.4 CORDIC and demodulators (24 ksps)

One iterative CORDIC, 20 iterations, X/Y 30 bits (24-bit input, 4 fraction bits, 2 bits growth), angles
in 1/2^24 turn (two's complement, so wrapping is free), arctangent table rounded to 24 bits. The gain
`K = 1.6467602581` is removed by one multiply with `KINV = round(2^17/K) = 79,594`:
`out = ((x + 4) >> 3) * KINV + 2^17) >> 18`. Measured against `f64`: magnitude within 1.1 LSB (after the
constant 1.8e-6 gain error of KINV), angle within 7/2^24 turn at |v| = 8 M.

Every 24 ksps sample is first vectored: `M = |y|` (24-bit scale) and `phi = angle(y)`. Then per mode:

| Mode (`mode`) | Audio `a` (24-bit scale) |
|---|---|
| 0 SSB (USB, LSB, CW, data) | `Re(y)`; the one-sided filter selects the sideband, CW pitch comes from tuning the receiver `pitch` Hz off the carrier and centring the filter there |
| 1 AM | `M - dc`, `dc += ((M << 16) - dc) >> k_dc` (dc 24.16; first sample primes it) |
| 2 SAM | `C = Re(y * e^(-j theta))` (CORDIC rotation), `e = phi - theta` (24-bit wrap); `freq += (e << 8) >> ki` clamped to +/-2^27 (+/-750 Hz), `theta += freq + ((e << 8) >> kp)` (32-bit); audio `C - dc` as AM |
| 3 FM | `d = phi - phi_prev` (24-bit wrap: +/-2^23 = +/-12 kHz); optional de-emphasis `de += ((d - de) * alpha + 2^16) >> 17` with `alpha` U0.17 (0 = off) |
| 4 IQ | `(Re y, Im y)` |

### 3.5 AGC in the log domain (24 ksps)

- **Level**: `L = log2(M)` in U5.12: position of the leading one plus a 1,024-entry table of
  `round(4096 * log2(1 + m/1024))` indexed by the next 10 bits (worst error 0.0014 octave = 0.009 dB).
  The detector is the envelope `M` of the filter output in every mode (smooth for SSB; the carrier for
  AM), not the audio waveform.
- **Gain** `G`: log2, S.24 fraction (32 bits), clamped to `[gmin, gmax]` (S7.12 registers). Target
  `Gt = clamp((R - L) << 12)`, with `R` the reference level (U5.12; default 21: an envelope of 2^21,
  -12 dB of the output scale).
- **Update** (same structure as `tr-dsp::agc`): if `L + G > R` (output above the reference): attack,
  `G += alpha_a * (Gt - G)`, hang counter reloaded; else if the hang counter is running it counts down;
  else decay, `G += alpha_d * (Gt - G)`. `alpha = a * 2^-(17+s)` (a 17 bits, s 0-15, so time constants
  from 0.04 ms to beyond 10 s keep 4 significant digits); the product is
  `(((Gt - G) >> 8) * a + 2^(8+s)) >> (9+s)`, one 25 x 17 multiply. First sample after enable: `G = gmax`.
- **Applying the gain**: `ga = G >> 14` (S.10), `m = round(65536 * 2^((ga & 1023)/1024))` from a
  1,024-entry table, `out = sat24(round(a * m * 2^((ga >> 10) - 16)))`: one multiply and a barrel shift.
- **Bypass** (`agc_en = 0`) and **FM**: the fixed gain `manual` (S7.12) is applied instead. FM always uses
  it (an FM discriminator's output does not depend on the signal level).
- Why the log domain: the target gain is a subtraction (no divider), gains span 40 octaves without wide
  multipliers, and an attack moves the gain by equal dB steps. The time constant means the same as in
  `tr-dsp::agc` (section 5.3).

### 3.6 S-meter and squelch

- `sm += ((L << 8) - sm) >> k_sm` (U5.20; first sample primes it), `smeter = (((sm >> 8) - 23 * 4096) *
  6165) >> 16`: the level in 1/64 dB relative to an envelope of 2^23 (6165 = 2^16 * 20 log10(2) * 64 /
  4096). A full-scale ADC tone at `in_shift` 6 reads -22.3 dB; the firmware adds its calibration. For
  noise the log average reads 2.5 dB below the power average (the mean of the log of a Rayleigh envelope);
  steady carriers read exactly.
- Squelch (any mode, `sq_en`): opens when `smeter > sq_open`, closes when `smeter < sq_close` (1/64 dB
  units, hysteresis by choosing two levels); closed means the audio (after the AGC) is zero.

### 3.7 Audio half-band and output

- `out24 = 0`: HB5, the HB4 coefficients again (pass band 4.8 kHz, stop band from 7.2 kHz at 24 ksps,
  104 dB), real in audio modes, complex in IQ mode, decimates to 12 ksps. `out24 = 1`: no HB5.
- Output `s = sat16((v + 128) >> 8)`: 16-bit audio, or 16-bit I and Q in IQ mode.
- The AGC runs before HB5, not after it as ARCHITECTURE 3.10 first listed: the detector then sees every
  24 ksps sample and HB5 smooths the gain changes; the cost is the same.

### 3.8 Stamps (HL2 time)

Every output sample carries the HL2 sample index of the bank sample that completed it. The back end
latches `base` = the link's `hl2_index` when the receiver's first bank sample after enable arrives; bank
sample `n` then has index `base + n * D` (`D` = 1,600/800/400/200 ADC samples per bank sample, exact
because the bank decimates by counting `adc_valid`), and output `k` (from 0) has
`base + (k + 1) * P - D` with `P` = 6,400 (12 ksps) or 3,200 (24 ksps). `base` is off from the true index of
bank sample 0 by the bank's pipeline latency (tens of ADC samples, constant per enable) plus the filters'
group delays, which the firmware subtracts: bank FIR, half-bands and channel filter (`(ntaps-1)/2` samples
at 24 ksps for the linear-phase designs). Differences between stamps are exact.

### 3.9 Enable, first sample, epochs

Disabling a receiver drops its samples at the input; re-enabling starts every stage from zero state (the
first sample after enable carries a `first` flag through the pipeline and resets each stage's state for
that receiver when it gets there). Each enable also flips the receiver's epoch bit, which travels with
every job; a stage drops jobs of an old epoch, so a disable/enable pair can come at any time without
stale samples reaching the output.

### 3.10 Output rings

Each receiver's samples also go to a DDR3 ring (`bk_ring.v`, one write-lane client port with
the `rtl/ddr3/ddr3_write_arbiter.v` handshake). Blocks of 128 samples; slot `s` of receiver `r` starts at
lane word `ring_base + s * W` with `W` = 34 (2 header words + 32 words of 4 x 16-bit samples) or 66 (IQ:
2 + 64 words of 2 x {I, Q}); `s` runs modulo `2^ring_slots`. Header word 0: bits 47..0 the HL2 stamp of
the block's first sample, 50..48 the receiver, 56 the IQ flag; word 1: bits 31..0 the block sequence
number, 47..32 the S-meter when the block completed. The header is written after the payload, and
`ring_wptr` (blocks, free-running) and `irq_status` advance only once the header has landed, so the
firmware never sees a half-written slot. No back-pressure: the fabric overwrites old slots, and the
firmware has one block time (10.7 ms at 12 ksps) per slot of ring to read.

## 4. RTL

```
rx_bank stream --> bk_front --> FIFO 64 --> bk_decim --> FIFO 8 --> bk_chfilt unit 0 --> FIFO 8 --+--> bk_post --> out stream --> mixer (A2)
(8 receivers,      scale, NB,               half-bands             (receivers 0-3)                |    CORDIC,              --> bk_ring --> DDR3 lane
 <= 1 per clock)   first/epoch              2 DSP                   4 DSP, 6 banks                |    demod, AGC,
                   1 DSP                                  FIFO 8 --> bk_chfilt unit 1 --> FIFO 8 --+    S-meter, HB5
                                                                    (receivers 4-7)                     1 DSP
```

| Module | What | Scheduling |
|---|---|---|
| `bk_front.v` | input scaling, noise blanker, first-sample and epoch tagging | 6-stage pipeline, one sample per clock; per-receiver state in registers |
| `bk_decim.v` | HB1-HB4 for all receivers | one job per bank sample: write, then for every second sample of a stage its taps, one per clock, I and Q in parallel (2 multipliers 24 x 26); output of one stage goes straight into the next in the same job |
| `bk_chfilt.v` (x2) | 1,024-tap complex FIR for 4 receivers, coefficient pool of 6 banks | one job per 24 ksps sample: `ntaps + 16` clocks, one complex tap per clock (4 multipliers 24 x 32) |
| `bk_cordic.v` | iterative CORDIC | 21 clocks per vectoring or rotation |
| `bk_post.v` | everything after the filter | sequential, one job per 24 ksps sample, one shared multiplier (27 x 36); about 60 clocks (SSB) to 90 (SAM), plus 36 (real) or 72 (IQ) for HB5 on every second job |
| `bk_ring.v` | output rings | one lane word per request |
| `rx_backend.v` | registers, epochs, stamps, FIFOs, interrupt | |

Worst-case load at 150 MHz, 8 receivers at 384 ksps, 1,024 taps (computed from the clock counts above;
section 6 has the measured busy fractions): decimator about 47 M clocks/s (31 %), each filter unit
4 x 24,000 x 1,040 = 99.8 M (67 %), post-processor under 45 M (30 %). These include the extra clocks of the
timing work (gowin/reports/README.md: slow single-clock steps of every engine split over several clocks,
a few clocks per job; the post-processor's second pass added about 25 clocks per job: every multiply two
clocks longer, the variable shifts and clamps split; busy 38 % -> 44 % in the quick test). The input FIFO has 64 entries because
receivers enabled together deliver their samples in the same few clocks and a 384 ksps sample that
completes all four half-bands occupies the decimator for about 97 clocks; the measured peak in the
testbench was 22.

Every multiplier is a `bk_mul` instance (registered inputs and product, at most 27 x 36, one GW5A DSP
block in `MULT27X36` mode, Gowin UG305 4.1.2); that is where the vendor primitive goes (PLAN R3). Memories
are `bk_ram` (simple dual port, registered read) and `bk_rom`. Constants and table files come from
`tools/gen_rx_backend_tables.py`; register addresses and fields from the generated
`hw/regmap/generated/rx_backend_regs.vh`.

## 5. Measurements (bit-exact model)

All from `cargo test -p tr-dsp --release backend -- --nocapture --test-threads 1` (lines starting
`MEASURED`); every measurement runs the integer model, so it describes the RTL too.

### 5.1 Method

Test tones are generated in `f64` and rounded with +/-1 LSB triangular dither, fed at the bank rate with
`in_shift` 6 or 0. Filter responses are measured at the channel-filter output (24 bits) of the whole
integer chain (scale, half-band, filter) by correlating over 6,000 samples; audio measurements by a
least-squares sine fit at the expected frequency (all rates are exact ratios, so the output frequency
is exact).

### 5.2 Filters against the float design

Float design = `design::bandpass` in `f64` (the same windowed-sinc formula as
`fastconv::BandpassFilter::design`), 1,024 taps at 24 ksps. "Integer coefficients" = the 32-bit
quantised bank evaluated in `f64`.

USB 300-2,700 Hz, level relative to a +1 kHz tone (LSB is the mirror image and measures the same):

| Tone | Integer chain | Float design | Integer coefficients |
|---|---|---|---|
| -2,500 Hz (mirror of +2,500) | -182.9 dB | -150.0 dB | -149.9 dB |
| -1,500 Hz | -180.7 dB | -149.9 dB | -149.6 dB |
| -1,000 Hz | -172.1 dB | -147.2 dB | -147.2 dB |
| -500 Hz | -145.6 dB | -139.9 dB | -140.0 dB |
| -200 Hz | -192.9 dB | -156.0 dB | -155.5 dB |
| 0 Hz (carrier) | -126.4 dB | -126.0 dB | -126.0 dB |
| +150 Hz | -122.8 dB | -122.9 dB | -122.9 dB |
| +200 Hz | -109.34 dB | -109.31 dB | -109.31 dB |
| +250 Hz | -32.93 dB | -32.93 dB | -32.93 dB |
| +300 Hz | -6.02 dB | -6.02 dB | -6.02 dB |
| +350 Hz | -0.20 dB | -0.20 dB | -0.20 dB |
| +2,700 Hz | -6.02 dB | -6.02 dB | -6.02 dB |
| +2,800 Hz | -109.35 dB | -109.31 dB | -109.32 dB |
| +3,000 Hz | -125.5 dB | -126.0 dB | -126.0 dB |

CW 300 Hz (550-850 Hz, pitch 700 Hz), relative to 700 Hz; both skirts measure the same:

| Offset from 700 Hz | Integer chain | Float design |
|---|---|---|
| +/-100 Hz | -0.20 dB | -0.20 dB |
| +/-150 Hz | -6.02 dB | -6.02 dB |
| +/-175 Hz | -15.57 dB | -15.57 dB |
| +/-200 Hz | -32.93 dB | -32.93 dB |
| +/-225 Hz | -65.07 dB | -65.07 dB |
| +/-250 Hz | -109.85 dB | -109.82 dB |
| +/-300 Hz | -122.1 dB | -121.7 dB |
| +/-600 Hz | below one LSB (output 0) | -147.6 dB |

Criterion applied (`check_level` in `tests.rs`): where the float design is above -110 dB the chain is
within 1 dB (measured: within 0.05 dB); deeper than that the chain must reject by at least 105 dB, because
a -6 dB tone attenuated by more than about 132 dB is below one LSB of the 24-bit filter output and the
measurement then shows the arithmetic, not the filter (the "better than float" values in the table are
that effect). The integer coefficients alone match the float design within 0.1 dB down to -130 dB and
within 0.5 dB down to -150 dB. **Opposite-sideband rejection: at least 140 dB at every mirror frequency
from 500 to 2,500 Hz.**

Why 32-bit coefficients (checked while designing, same filters, worst point of the opposite sideband /
largest skirt error above -80 dB): 18 bits: -90 dB / 1.5 dB; 24 bits: -123 dB / 0.008 dB; 27 bits:
-136 dB / 0.001 dB; 32 bits: -140 dB (the float value) / 0.

### 5.3 AGC against `tr-dsp::agc`

Same attack/decay/hang parameters in both (the model's coefficients from
`Alpha::from_time_constant`, which uses tr-dsp's formula), envelope steps of 6 dB and 46 dB at 24 ksps.
Each AGC is measured in the domain it is exponential in: the fixed-point AGC smooths the gain in dB, so its
time constant is the time to cover 63 % of the step in dB; `tr-dsp::agc` smooths the linear gain, so its
time constant is the time to cover 63 % of the linear step.

| Programmed | Fixed-point (63 % in dB) | tr-dsp (63 % linear) | Difference |
|---|---|---|---|
| attack 2 ms, 6 / 46 dB step | 2.04 / 2.00 ms | 2.00 / 2.00 ms | 2.0 % / 0 % |
| attack 5 ms | 5.00 / 5.00 ms | 5.04 / 5.04 ms | 0.8 % |
| attack 20 ms | 20.04 / 20.00 ms | 20.04 / 20.04 ms | 0.2 % |
| decay 250 ms | 250.4 / 250.0 ms | 250.0 / 250.0 ms | 0.2 % |
| decay 300 ms | 300.5 / 300.0 ms | 300.0 / 300.0 ms | 0.2 % |
| decay 1,000 ms | 1,001.6 / 999.9 ms | 1,000.1 / 1,000.1 ms | 0.2 % |

Hang: the gain stays exactly constant for the programmed 2,400 samples (100 ms) after the last attack
sample, then decays (`agc_hang_holds_the_gain`).

The trajectories differ in shape for large steps, by design. Measured across domains on the 46 dB step
with a 5 ms attack: the fixed-point AGC covers 63 % of the *linear* gain step in 1.08 ms, tr-dsp covers
63 % of the step *in dB* only after 17.5 ms. In words: after a strong signal appears, tr-dsp's AGC leaves the
output tens of dB too loud for several time constants; the log-domain AGC removes the excess in equal dB
steps. On a 6 dB step the two differ by 20-25 % across domains.

### 5.4 Every mode at every input rate

Tone at -16 dB of the 24-bit scale (bank amplitude 20,000, `in_shift` 6), default AGC (reference 21:
envelope 8,192 on the 16-bit output), 12 ksps out; `every_mode_at_every_input_rate`:

| Mode | 48 ksps in | 96 | 192 | 384 |
|---|---|---|---|---|
| USB, +1 kHz tone: 1,000.00 Hz, amplitude 8,190, SNR | 85.4 dB | 89.2 dB | 86.4 dB | 95.0 dB |
| LSB, -1 kHz tone | 85.4 dB | 89.2 dB | 86.4 dB | 95.0 dB |
| CW 300 Hz, +700 Hz tone | 85.6 dB | 85.8 dB | 86.3 dB | 89.1 dB |
| AM 70 % at 1 kHz: amplitude 3,374 (peak AGC: 0.7/1.7 x 8,192 = 3,373), SNR | 66.5 dB | 62.6 dB | 67.2 dB | 62.5 dB |
| SAM, carrier 30 Hz off and 100 degrees rotated | 66.5 dB | 62.6 dB | 67.1 dB | 62.4 dB |
| FM, 2.5 kHz deviation at 1 kHz: amplitude 6,807 (6,827 x sinc(1/24) = 6,807), SNR | 87.3 dB | 82.4 dB | 83.7 dB | 78.6 dB |
| IQ, 24 ksps out, -3 kHz tone: amplitude / image | 5,000.0 / -130 dB | 4,999.5 / -127 dB | 4,999.9 / -116 dB | 4,999.5 / -307 dB |

Other checks: decimation to 24 ksps rejects every tone at 1 kHz + k x 24 kHz by 113.1 dB (48 ksps in),
117.6, 117.8 and 117.9 dB (96, 192, 384 ksps); the noise blanker at 384 ksps with 3-sample impulses of
70 times the tone every 10.4 ms raises the audio SNR from 17.9 dB to 37.3 dB (the held samples themselves
limit it, as in `tr-dsp::blanker`); the S-meter reads -30.02 dB and -60.02 dB for tones at -30 and
-60 dB of the scale and the squelch follows its thresholds; stamps count exactly 6,400 (3,200) ADC samples
per output sample at every rate. The CORDIC alone: magnitude within 1.1 LSB, angle within 7/2^24 turn at
|v| = 8 M.

## 6. Bit-exact verification (RTL against the model)

`sim/rx_backend/tb_rx_backend.v`: 8 receivers at once, fed by a stand-in for the receiver bank that
puts each receiver's samples on the shared stream every `d_eff` `adc_valid` pulses, `adc_valid` bursty
(runs of 1-48 valid clocks and gaps of 1-46, 51 %), round-robin onto the stream as the bank does. The
stimulus is the model's integer stimulus (`backend::stim`: tones from a phase accumulator and the sine table
`sim/rx_backend/bk_sine.hex`, xorshift32 noise, impulses), computed identically in Verilog; coefficient
banks are generated from a few integers the same way on both sides (pseudo-random or boxcar band-pass)
and written through the coefficient window; every register value comes from the model's configuration
packed with the generated field positions (`tr-regs`). The model writes the scenario and the expected
results into `sim/rx_backend/tb_rx_backend_scn.vh` (`cargo run -p tr-dsp --example r4_check -- quick`;
`cargo test` fails if the committed file is stale). The testbench compares, per receiver: the output
count, an FNV hash over every output word and every stamp (as an offset from the latched base), and after
the run the S-meter, squelch, AGC gain, blanked-count and output-count registers, plus the overflow flags.
`+dump=<prefix>` writes the outputs for a line-by-line diff with the model's files.

| Run | What | Result |
|---|---|---|
| quick (`tools/check.sh`, about 50 s) | every mode, every input rate, 12 and 24 ksps out, blanker, AGC on and off, squelch, SAM with a 40 Hz offset, FM de-emphasis, a bank switch at a 24 ksps sample, saturating input; filters of 1-256 taps; bank time compressed 4 x | bit-exact: 1,240 outputs of 8 receivers, every word, stamp and status register equal; engines busy: decimator 48 %, filter units 18/20 %, post 24 %; input FIFO peak 22 of 64 |
| full (`tools/run_r4_full.sh`, four runs in parallel) | runs 1-3: all 20 mode x rate combinations plus 4 more, 1,024/777/511/300/255/64/1-tap filters, real-time bank pacing, bank switches; run 4: all 8 receivers at 384 ksps with 1,024-tap filters (the throughput worst case) | bit-exact: 4 x 2,400 outputs (3.8 M clocks each). Run 4 (8 x 384 ksps, 1,024 taps, real time): filter unit 0 64 % busy (4 receivers the whole run), decimator 27 %, post 6 %, input FIFO peak 17 of 64, no overflow |

`sim/rx_backend/r4_chain.v` (in the full run): the real receiver bank (`rtl/rx/rx_bank.v`, 8 receivers,
two per rate) fed a 12-bit ADC stream with bursty `adc_valid`, its shared stream straight into
`rx_backend`, against `tr-rxmodel` (WP R2) chained into the back-end model: bit-exact (60,000 stream
clocks plus 40,000 without `adc_valid` in development; in the full run 200,000 stream clocks (103,085 ADC
samples) plus 40,000). This is the test that found the two receiver-bank defects in section 9, and is now
also their regression test: it asserts zero repeats and zero samples emitted after `adc_valid` stopped
(before the fix, this same 200,000-cycle run measured 5,691 bank samples, 1,199 of them repeats and 950
emitted after `adc_valid` stopped; after the fix, 1,928 bank samples, 0 repeats, 0 emitted after `adc_valid`
stopped).

`sim/rx_backend/tb_rx_backend_ring.v` (also in `tools/check.sh`, about 10 s): the ring writer alone with
three receivers (audio, IQ, audio) through the behavioural DDR3 lane with random stalls, rings wrapping,
every payload and header word of the last 4 slots checked, pointer and block pulses counted; then the
whole back end with one IQ receiver's ring and interrupt, 3 blocks, register pointer, interrupt and
W1C clear, ring contents equal to the output stream including stamps.

Bugs the comparison found while bringing the RTL up (all fixed): the input FIFO (16 entries at first)
overflowed when receivers delivered samples in the same clocks; the post-processor's IQ gain pass
started from an unreset flag and lost the first sample's I value; and in the SAM phase update a
part-select made a Verilog expression unsigned, so `e >>> kp` became a logical shift.

## 7. Resources

yosys 0.69 `synth_gowin -family gw5a` of `rx_backend` (`sim/rx_backend/yosys_gw5a.ys`, synthesis only;
Gowin place-and-route is PLAN R3). `bk_mul` is kept a black box and counted as one DSP block each (every
instance is at most 27 x 36, one GW5A DSP in `MULT27X36` mode).

| Resource | Count | Of the GW5AST-138 | Where |
|---|---|---|---|
| DSP blocks | **12** | 4 % of 298 | filter units 2 x 4, decimator 2, post-processor 1, blanker 1 |
| Block RAM, 18 kbit | **81** | 24 % of 340 | coefficient pools 48 (2 units x 6 banks x 1,024 x 64 bit), filter delay lines 24 (8 x 1,024 x 48 bit), decimator delay lines 3, HB5 2, log2/exp2 tables 2, other 2 (24 DPB, 51 DPX9B, 4 SDPX9B, 2 SPX9) |
| LUT4 (all sizes) | 16,422 | | plus 1,682 MUX2 and 3,318 ALU (carry) cells |
| Flip-flops | 9,334 | | |
| Distributed RAM | 239 RAM16SDP4 | | FIFOs, per-receiver state |

Against the plan's allotment (about 16 DSP and 40 BSRAM): DSP well under (12). BSRAM 81 blocks of
18 kbit; the plan's 40 were "36 kbit" blocks, so the same order (about 40 in those units), but see section 9
on units. Options if BSRAM gets tight, with their price: 27-bit coefficients (3 instead of 4 blocks per
bank: -12 blocks; opposite-sideband rejection within 4-7 dB of the float design instead of 0.3 dB at the
-140 dB level), or 5 instead of 6 banks per unit (-8 blocks; only one receiver per unit can be mid-switch).
More DSP would not save BSRAM: the design is memory-bound, not multiplier-bound.

Timing (Gowin place-and-route at 150 MHz, `gowin/reports/rx_backend/`): `bk_front` 154.0, `bk_decim`
160.3, `bk_chfilt` 151.8 and `bk_ring` 156.5 MHz meet it; `bk_post` is at 116.1 MHz (102.5 before the
second pass). Its multiplier operands now come from single-source registers picked by a one-hot select,
the AGC decision is made two states ahead, the operands and the product are registered in the fabric
(every multiply two clocks longer), and the variable shifts and clamps take two clocks each. What is
left is the 64-state machine itself: its next-state and load-enable logic, spread over the block's
7,400 LUTs, is 2 ns short. `bk_ring` registers `ring_en` (a ring is enabled or disabled
one clock later) and reads the S-meter for a block header a clock after the sample (bk_post changes a
receiver's S-meter only in that receiver's next job).

**Third pass (branch `bkfix`).** Tried writing `bk_post`'s state as explicit one-hot flags (a 64-bit
one-hot register, the outer dispatch as `case (1'b1)` on its bits with a `parallel_case, full_case`
hint) in place of the `syn_encoding = "onehot"` pragma on the 6-bit state register. Measured worse,
not better: 81.8 MHz without the parallel_case hint (a 64-way priority chain), 102.6 MHz with it --
both below the existing 116.1 MHz. Reverted; `bk_post` stays at 116.1 MHz. Splitting the engine in
two is still the open path to 150 MHz here; not attempted in this pass.

**Whole `rx_backend`'s register bus** (the earlier, whole-block-only failure: 68.7 MHz, all in
`rx_backend.v`'s own read mux and write decode, gowin/reports/README.md "rx_backend" second pass).
Registering the bus once before decoding, as that pass's own next step said, measured **worse**
(62.1 MHz): the read mux itself, not just its input, was too deep for one clock (an 8-way select
by receiver chained into a 24-way select by field). Splitting that same mux across two more
clocks -- by receiver first, into 24 parallel per-field registers, then by field, a plain mux with
no more per-receiver indexing -- measured 80.4 MHz: better than the second pass, but not closed.
The new worst path is one field read from another engine's output (`bk_ring`'s per-receiver write
pointers) rather than from a register `rx_backend.v` itself keeps; a few more fields have the same
shape (`bk_post`'s S-meter and AGC gain, `bk_chfilt`'s current bank, `bk_front`'s blanked count).
Likely next step: have each of those engines register its own by-receiver-selected value locally
instead of handing `rx_backend.v` the whole array to select from centrally. Not attempted here.

**Net effect on the whole block**: register bus 68.7 -> 80.4 MHz; `bk_post` unchanged at
116.1 MHz alone. The whole block does not reach 150 MHz: the register bus is still the worst path,
and even once it closes, `bk_post` alone would cap the block at 116.1 MHz until it is split.

**Fourth pass (branch `bkclose`), not closed: best whole-block result 132.4 MHz.** All numbers are
the whole `rx_backend` through `gowin/res.sh --wrap` with `rtl/rx_backend/rx_backend.sdc`
(gowin/reports/README.md "Fourth pass" has every run).

- *Register bus: two-clock paths instead of more pipelining.* CPU register accesses are rare and
  already take several clocks, so the read and write paths are declared two-clock paths in
  `rtl/rx_backend/rx_backend.sdc` (`set_multicycle_path -from [get_regs {*rbmc_*}] -setup -end 2`,
  hold `-start 1`) rather than cut into more stages. The RTL makes that constraint true
  (`rx_backend.v`, "register bus"): every `rbmc_*` register loads only on an access (latched
  address and data, latched read address, read fields) and holds for at least two clocks; every
  register those paths end on loads only on a plain one-clock flag (`w_go2`, `wr_en2`, `w_go`,
  `r_go2`, `r_go4`) that is high two or more clocks after the `rbmc_*` registers were loaded; live
  values (engine status, settings, stamps, counters) enter the read fields through one-clock
  paths only. Bus contract: at least two clocks between two writes, and between two reads; a
  simulation check reports a violation (none in any testbench). The write decode (134 one-hot
  flags) is itself a two-clock path from the latched address, with address and data carried to
  the commit in `rbmc_wa2`/`rbmc_wd2`. Result: the register bus left the failing paths entirely
  (68.7 / 80.4 MHz before, all register bus); the two-clock paths have 2.7 to 5.5 ns slack.
  Latency: a write lands five clocks after `reg_wr` is sampled (was one), read data is valid five
  clocks after `reg_rd` is sampled (was two); the testbenches' `rd()` tasks wait three clocks more.
- *`bk_post`'s state machine.* The 64 states are now separate flags `s[S_x]`, each state's work
  its own `if (s[S_x])` block, every clock `s` cleared and the active state's block setting its
  successor (no `case`, `syn_preserve` so Gowin does not re-extract a state machine). A flag's next
  value is an OR over its few predecessors; the S_MAC -> S_GAIN3_D path (Gowin's extracted one-hot
  machine, 116.1 MHz) is gone. The multiply issue (operand select and return state) is one AND-OR
  of the seven issuing conditions; the operand select is copied a clock later (one more wait
  state, S_W5). No engine split or microcode was needed.
- *Paths that only show on the whole block.* With the register bus out of the way, the whole
  block showed a long tail of 0.5-4 ns failures at engine boundaries and on nets with a fan-out of
  30-130 (routes of 3-5 ns). Fixed in the RTL: `bk_fifo` has an output register (every engine's
  take starts at a flip-flop; entries visible a clock later, capacity +1); `bk_front` registers its
  input and `en` (the HL2 index for the stamps is delayed to match: same stamps); `bk_post` takes
  the job word in S_IDLE and decodes it in a new state S_TK0, the job's settings through twelve
  copies of the receiver number, `w_dc` and the CORDIC inputs on registered load flags, the SAM
  CORDIC inputs set in S_SM3 for every mode, the AGC step shift, the squelch decision and the log
  index shift over two clocks each (new states S_AGC2_BH, S_SM4, S_MAG2B), the magnitude rounding
  as a 25-bit increment, the demodulator dispatch as parallel flags; `bk_cordic` takes `start` a
  clock later from copies, its start values and "last iteration" flag from registers; `bk_ring`
  registers its input sample, counts each ring's pointer with its own adder, clears pointers and
  sequence counters from a register, reads its slot masks from registers; `bk_decim` takes the
  receiver's first stage from registers and uses copies of the receiver and stage numbers per
  state array; `bk_chfilt` uses copies of the output exponent and of the coefficient bank select;
  `rx_backend.v` registers `bk_post`'s output once more (one-hot receiver flags for the stamps
  and counters, each receiver's own adders) and works out the first-sample stamp over three
  clocks. Every value is unchanged: `tb_rx_backend`, `tb_rx_backend_ring` and
  `tools/run_r4_full.sh` (four scenarios and the receiver-bank chain) pass bit-exact.
- *Tool options.* Gowin's register replication (`--opt "replicate_resources 1"`) and the slower,
  better router (`--opt "route_option 1"`), first used together with a batch of RTL fixes, took
  the block from 92.5 to 121.8 MHz and from -424 to -128 ns total negative slack (the two effects
  were not measured apart). On one RTL, placement algorithms 1 and 4 gave -110 and -174 ns total
  negative slack against -39 ns for the default (3) (Fmax 105.7 and 107.3 against 88.6 MHz, the
  default run's Fmax set by two single nets routed 4-8.5 ns long). Over-constraining to 167 MHz
  did not help (121.4 against 132.4 MHz). The whole-block build uses these two options and the
  .sdc.
- *Busy and latency.* `bk_post` takes about 12 clocks more per job than after the third pass
  (busy 44 % -> 47 % in the quick test; limit 70 %). Output stream one clock later (the extra
  output register), plus each FIFO's extra clock and the new states; latency is not checked by
  any testbench beyond the rd() waits.
- *Where it stands.* Results swing by 10-40 MHz from run to run with small RTL changes: 115.7,
  88.6 (two single nets routed 4-8.5 ns long), 132.4, 132.4, then 81.0 for the last batch, which
  had indexed a part-select as `jrx*5 + 2` (Gowin built the index product in a DSP block: DSP 23
  -> 23.5, and the placement degraded around it). That part was reverted before the commit; the
  committed RTL is the 132.4 MHz RTL plus four small changes (squelch decision and log index shift
  over two clocks, registered clear of the ring sequence counters, copies of the decimator's stage
  number for the fill and phase writes) and has not been place-and-routed. At 132.4 MHz, 27
  endpoints failed (total -14.8 ns): the ring sequence counters' load enable (-0.9 ns), the
  squelch compare (-0.6), the log index shift (-0.3), the decimator stage copies (-0.2), each
  addressed by one of those four changes.
- **Next step**: one place-and-route of the committed RTL (the command in gowin/reports/README.md
  "Fourth pass", with `--sdc rtl/rx_backend/rx_backend.sdc --opt "replicate_resources 1" --opt
  "route_option 1"`). If it is below 150 MHz, fix the named paths the same way (copies, a
  registered load flag, one more state) and repeat; the remaining failures have been 0.1-2 ns,
  at most a few dozen endpoints, and different ones each run, so it may take two or three runs.
  Do not index a part-select with an expression beyond `r*W` (see the DSP above).

## 8. Registers

`hw/regmap/rx_backend.toml` (page 0xE80C_0000, status draft), generated into
`hw/regmap/generated/rx_backend_regs.vh` and `tr-regs`. The bus (address, write data,
`reg_wr`/`reg_rd`) is registered once in `rx_backend.v`, and the read and write paths behind it
are two-clock paths (`rtl/rx_backend/rx_backend.sdc`; timing, fourth pass above): a write lands
five clocks after `reg_wr` is sampled, and read data is valid five clocks after `reg_rd` is
sampled (a testbench raising `reg_rd` for one clock reads six clocks later). Two writes, and two
reads, must be at least two clocks apart. Register map and values are unchanged.

| Offset | Register | Contents |
|---|---|---|
| 0x000 | `id` | 0x5242_0001 |
| 0x004 | `status` | sticky W1C overflow flags: input FIFO, filter FIFOs, demodulator FIFO, ring queue |
| 0x008, 0x00C | `irq_status`, `irq_enable` | block ready per receiver (interrupt line 10) |
| 0x010 | `coef_sel` | which unit and bank the coefficient window writes |
| 0x040 + 4k | `bank_cfg[12]` | per bank (unit x 6 + bank): tap count, exponent |
| 0x100 + 0x80 r | `ctrl` | enable, mode, out24, in_rate, in_shift, blanker/AGC/squelch on, bank_sel |
| +0x04, +0x08 | `nb`, `nb_hold` | blanker threshold, floor shifts, hold |
| +0x0C..+0x24 | `agc_attack`, `agc_decay`, `agc_hang`, `agc_ref`, `agc_gmax`, `agc_gmin`, `agc_manual` | AGC |
| +0x28, +0x2C, +0x30 | `loops`, `fm_deemph`, `squelch` | S-meter and carrier smoothing, SAM loop, de-emphasis, squelch levels |
| +0x34..+0x48 | `rx_status`, `agc_gain`, `blanked`, `stamp_base_lo/hi`, `out_count` | read-only status |
| +0x50..+0x5C | `ring_base`, `ring_slots`, `ring_ctrl`, `ring_wptr` | output ring |
| 0x8000 + 4i | `coef[2048]` | coefficient window: tap n real part at 8n, imaginary at 8n + 4 |

The reset values of the AGC registers equal the model's defaults (attack 2 ms, decay 250 ms, hang
100 ms, reference 21, gain limits +120/-48 dB).

## 9. What this changes elsewhere, and findings

- **BSRAM units in ARCHITECTURE 3.14.** The GW5AST-138 has 340 block RAMs of **18 kbit** (6,120 kbit / 340,
  DS1104 via BOARD.md; F1 counted its 35 blocks as 18-kbit primitives). ARCHITECTURE 3.14 labels the column
  "36 kbit" and halves F1's count (35 -> 18). If the other rows are 36-kbit estimates too, the chip-wide
  BSRAM total is about double what the table says (roughly 294 of 340 instead of 147). This block's
  numbers below are 18-kbit blocks. Worth a check by whoever owns 3.14 before more blocks are added.
- **The receiver bank's output uses 17 of its 24 bits** (16-bit CIC output, unity FIR; a full-scale ADC
  tone gives |IQ| = 10,043). The bank's rounding then sets a floor of roughly 88 dB below a full-scale
  tone in 24 kHz (about 98 dB in 2.4 kHz), above the ADC's own noise in narrow bandwidths. `in_shift` = 6
  aligns the back end to what the bank delivers; if R1 widens its CIC output, only `in_shift` changes.
- **Changes against the first ARCHITECTURE 3.10 text** (3.10 now describes the built design): pass band
  9.6 kHz instead of 10 kHz; 32-bit coefficients instead of 18-bit; a pool of 6 banks per 4 receivers
  instead of 2 banks per receiver; the AGC before the 12 ksps half-band; squelch on the S-meter level for
  every mode.
- **Firmware obligations** (PLAN S18): write `in_rate` equal to the bank's `rate_sel`; re-enable the
  back-end receiver whenever the bank receiver is re-enabled or changes rate (its stamp base and state
  restart); never write a bank a receiver of that unit is using (`bank_cur`); keep channel filters within
  +/-9.6 kHz (the decimation's alias-free band); read ring blocks within their slot time; add the pipeline
  and filter delays to stamps (section 3.8).
- **Clock crossing**: the back end runs in `clk_dsp`; the register port and the ring's lane client are
  plain synchronous ports. Integration needs the AHB bridge's synchroniser for the registers and an
  asynchronous FIFO between `bk_ring`'s write queue and its lane state machine for the DDR3 fabric clock.
- **Audio mixer (A2)** takes `out_valid`/`out_rx`/`out_s0`/`out_s1`/`out_stamp` directly.
- **Two receiver-bank (R1) defects found by the end-to-end test** (`r4_chain.v`) -- **both fixed**
  (WP r1-fix, in `rtl/rx/cordic_mixer.v` and `rtl/rx/rx_bank.v` together with `fw/tr-rxmodel`'s
  `cordic.rs`/`bank.rs`, so the model stays bit-exact with the RTL; `tools/check.sh`'s R2 check and
  `r4_chain.v` pass again, and `r4_chain.v` now asserts zero repeats and zero late-emitted samples as
  its own regression test, see section 6):
  1. **The bank decimated by clocks, not by `adc_valid` pulses, once its CORDIC's valid pipeline was
     full.** `cordic_mixer.v` drove `out_strobe = valid_sr[STG]`, and that shift register only moved on
     `in_strobe`, so after the first few valid samples `out_strobe` stayed high on every clock, and the
     CIC stages integrated the held sample again on clocks without `adc_valid`. Measured: with `adc_valid`
     at 51 % a 384 ksps receiver delivered a sample every 200 clocks instead of every 200 valid samples,
     and after `adc_valid` stopped the 8 receivers delivered 950 more samples in 40,000 clocks. Output
     rates and HL2 time were only right when `adc_valid` was high on every clock (which R1's own
     testbenches used, which is why this went unnoticed until now). Fixed by making `out_strobe` a
     one-clock pulse per accepted input: a register loaded every clock with `in_strobe & valid_sr[STG-1]`
     (`docs/RX_DSP.md` section 1 has the full explanation).
  2. **The shared-stream arbiter repeated a sample** on the next clock when no other receiver was
     pending: `pend_valid` was cleared one clock after the grant, and the arbiter saw it still set.
     Measured: 499 of 2,367 samples repeated. Fixed by clearing `pend_valid` in the same clock as the
     grant, using the same combinational `found`/`found_idx` decision that drives the output register
     instead of the one-clock-late registered `out_valid`/`out_index` (`docs/RX_DSP.md` section 4).
  With either defect the back end received samples that were not in HL2 time, so stamps and all rates
  were wrong on the real bank; both are fixed now and the back end itself needed no change. New
  regression coverage independent of the model-vs-RTL comparison (which could not have caught either
  defect, since `tr-rxmodel` reproduced both bit for bit): `fw/tr-rxmodel/tests/regression_r1.rs`
  (`docs/R2_RXMODEL.md` section 3) and `r4_chain.v`'s `repeats`/`drain_samples` assertions above.

## 10. Not done

- **Gowin place-and-route and timing** (PLAN R3): the vendor DSP wrapper in `bk_mul.v`, block RAM
  primitives, and pipeline registers where the paths named in section 7 miss 150 MHz.
- **Clock-domain crossings** for the register port (AHB bridge) and the ring writer's lane side
  (asynchronous FIFO), and the connection to a port of the DDR3 write-lane arbiter (the arbiter has three
  fixed clients today: IQ writer, waterfall, capture).
- **Firmware** (PLAN S18): the driver (register writes, coefficient upload through `design::quantize`,
  ring reading), and the delay constants for stamps.
- Noise-derived FM squelch (the squelch here uses the S-meter level, as `tr-dsp` uses the RF level).
