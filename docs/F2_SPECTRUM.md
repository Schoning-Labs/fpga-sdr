<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# F2: full-band spectrum pipeline

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Work package F2 in [PLAN.md](PLAN.md); system context in [ARCHITECTURE.md](ARCHITECTURE.md) section 3.3;
builds on the FFT decided in [F1_FFT.md](F1_FFT.md) (`rtl/fft/fft_r22sdf.v`).

## What this WP built

`rtl/spectrum/spectrum_pipeline.v`: window -> FFT -> power -> per-column reduction (max or mean)
-> K-frame averaging or peak-hold -> dB -> double-buffered spectrum line buffer + waterfall byte
stream, all in `clk_dsp` (120 MHz), one column-worth of work fully pipelined per completed FFT
frame so the design never falls behind the continuous 76.8 Msps input. Register interface:
`hw/regmap/spectrum.toml` (now `status = "final"`).

Files:

| File | What |
|---|---|
| `rtl/spectrum/spectrum_window.v` | 4-term Blackman-Harris window multiply, feeds F1's FFT |
| `rtl/spectrum/spectrum_log2db.v` | linear power -> dB (1/64 dB steps), leading-one + LUT log2 |
| `rtl/spectrum/spectrum_pipeline.v` | everything else: FFT instance, power, column reduction, K-frame accumulator, divide, line buffer, waterfall output, register port |
| `rtl/spectrum/tw/*.hex` | window ROM, log2 LUT, column-mapping ROMs -- generated, do not hand-edit |
| `tools/gen_spectrum_tables.py` | writes the four ROM files above |
| `sim/spectrum/spectrum_done_test.vh` | the done-test itself (stimulus and all checks), shared by the two files below |
| `sim/spectrum/tb_spectrum_pipeline.v` | done-test at K = 2 (about 17 s of CPU time) -- this is what `tools/check.sh` runs |
| `sim/spectrum/spectrum_noise_full_k156.v` | the same done-test at PLAN's own K = 156 (about 15 min of CPU time; not named `tb_*.v`, so `check.sh` skips it) |
| `tools/spectrum_k156.sh` | runs the K = 156 version, exits non-zero unless it passes |
| `sim/spectrum/yosys_gw5a.ys` | resource estimate |

## How it works

### Pipeline order: dB happens after averaging, not before

ARCHITECTURE 3.3 says column reduction and K-frame averaging happen "in linear power", and only
the *output* of that averaging is converted to the 16-bit dB line value. PLAN's F2 row lists the
stages in a different order ("power, dB ..., column mapping ..., averaging ...") -- that list is
not a pipeline diagram, and following it literally would mean computing a logarithm for every one
of the 8,192 useful bins per transform (4,687.5 transforms/s) instead of once per column per
finished line (1,920 times per line, 30 lines/s = 57,600/s, about 130x less log2 hardware work,
and it is what "averaged ... in linear power" in 3.3 requires arithmetically: log(mean(x)) !=
mean(log(x))). This WP followed ARCHITECTURE, converts to dB exactly once per column at the end
of each K-frame group, and used the saved hardware to keep the log2 converter simple (a
leading-one search plus a 512-entry LUT, `spectrum_log2db.v`) instead of needing it to run at full
FFT-bin rate.

### Bit-reversal: solved by addressing, not a reorder buffer

F1 left natural-order reordering to F2 on purpose (F1_FFT.md "Interface for F2 and F3"): the FFT's
`out_bin` for a given output word is exactly the bin that word belongs to, bit-reversed order and
all, so writing the *power* of that word into a per-bin (here, per-*column*) memory addressed by
`out_bin` reorders it for free, with a 30-bit power word instead of the 58-bit complex pair F1
would have had to buffer. `spectrum_pipeline.v` does this at the `cfa_mem` (column-frame-accumulator)
write: `col_idx = f(out_bin)`, no shift-register reorder anywhere in the design.

### Bin -> column mapping

0-30 MHz is 6,400 of the FFT's 8,192 unique real-input bins (bins 8,192 and up, i.e. the
odd-`out_index` words, are the mirror half and are dropped, per F1_FFT.md). 6,400 bins onto 1,920
screen columns divides exactly: 6,400/1,920 = 3.333... = 10/3, so `column = floor(bin * 3 / 10)`
is exact, no rounding drift across the whole range. The RTL computes this with the classic
unsigned divide-by-10 trick (`(bin*3 * 52429) >> 19`, exact for dividends under 65,536); each
column gets 3 or 4 bins (`tools/gen_spectrum_tables.py` checks this holds for every column and
writes the per-column count to `col_bins.hex`).

### Within-frame column reduction: no bulk clear, no read/write hazard

Bins arrive in bit-reversed (not bin-number) order, so which of a column's 3-4 bins arrives
*first* in a given frame is not the numerically smallest one -- it varies by column, but it is
completely static (a fixed permutation, computable offline). `tools/gen_spectrum_tables.py`
bit-reverses every bin number the same way the FFT does (`out_bin = bitrev(out_index)`, so
`arrival_time(bin) = bitrev(bin)`, self-inverse) and writes a 1-bit-per-bin ROM,
`col_first.hex`: 1 if this bin is the first of its column to arrive. On a 1 the RTL *writes*
the column's accumulator (starts a fresh reduction); on a 0 it does a registered
read-modify-write (max or sum, `column_mode`). This needs no per-frame clear of the 1,920-entry
accumulator and, because useful bins are guaranteed >= 2 cycles apart (every other `out_index` is
the mirror half and is skipped), the one-cycle read-then-write pipeline never sees a same-address
read racing a still-in-flight write.

The generator now also replays one frame in arrival order exactly the way the RTL reduces it and
refuses to write the ROM unless every column ends up holding the sum of all of its bins. That
check did not exist in the first version, and the ROM it wrote was wrong in 666 of the 1,920
columns ("The noise-floor fault" below).

### Why the within-frame accumulator is double-buffered but the K-frame one is not

Two per-frame column buffers (`cfa_mem[0]`/`cfa_mem[1]`) ping-pong by frame parity: while frame
N+1's bins are being written into one buffer (spread across that frame's full ~16,384-cycle
window), a "walk" over the *other* buffer (frame N's completed data) merges it into the K-frame
accumulator (`kacc_mem`, 1,920 x 40 bit, matching ARCHITECTURE 3.3's own sizing -- see "Why 40
bits" below). The walk issues one column read per cycle and completes in about 1,930 cycles
(pipeline fill plus 1,920 columns), so a buffer is always free again with a full extra frame period
(~16,384 cycles) to spare before its next write -- see "Timing margin" below for the numbers this
claim rests on.

`kacc_mem` itself is *not* double-buffered. It does not need to be: the *same* walk that merges a
frame's data into it also does that group's line-finalize (divide, log2, line-buffer write,
waterfall output) inline, for whichever columns are being visited, the instant `group_pos` shows
this is the K-th frame of the group -- there is never a second, later pass that reads `kacc_mem`
after new data may already have started overwriting it. This is also why the very first frame of
a new K-group does not need an explicit clear of `kacc_mem`: `first_of_group_w` (`group_pos == 0`)
makes that frame's merge a plain overwrite instead of an accumulate.

### Timing margin

Everything above depends on one claim: a walk (1,920 columns, divide + log2 + line/waterfall
output on every column during a finalizing walk) finishes well inside one FFT frame period
(16,384 cycles at 150 MHz = 109.2 us), so back-to-back walks (one is started by every completed
frame, 4,687.5/s) never queue up. The walk issues one new column's memory reads every cycle with
no stalls (`spectrum_log2db` is itself a fixed-latency, gap-free pipeline, and the divide is a
plain combinational `/`), so total walk latency is `1920 + pipeline_depth` cycles, about 1,930 --
**17.8x** inside the 16,384-cycle budget. Measured directly in simulation (below): the interval
from one `line_count_reg` increment (last column of a finalizing walk written to the line buffer)
back to the frame boundary that started it is well under one frame period every time, for all 156 frames of the done-test run. A
`walk_pending` latch exists as a defensive fallback (queues a second walk start if one ever arrives
while a walk is still active) but the margin above means it is not expected to ever fire; nothing
in the done-test run triggered it.

### Why 40 bits became 48: the truncation shift almost broke the noise floor

ARCHITECTURE 3.3 sizes the K-frame accumulator at "1,920 x 40 bit". Working backward from a
worst-case-overflow bound alone (full-scale signal in all 4 of a column's bins, every one of up to
512 frames) gives a truncation shift of `RSH = 14` bits (dropping the low 14 of the FFT's 29-bit
output before squaring) to just fit that bound in 40 bits, and that is what this WP built first.
It passed a single-tone, no-noise check to 0.003 dB. It then failed the done-test badly on the
*noise* floor: measured mean -510 dB against a -18 dB theory, spread over 26 dB against a
predicted few tenths of a dB. The cause: `RSH = 14` divides the FFT's noise-floor amplitude
(typically about 1,470 counts per component at this design's noise level, ADC sigma 4 LSB) down
to about 0.1 -- rounds to exactly 0 on all but the rare multi-sigma outlier -- so the K-frame
average was averaging a column of near-constant zeros, landing on the `spectrum_log2db.v`
"no signal" sentinel almost everywhere except the one column the tone dominated.

The overflow bound was real but too pessimistic to build the truncation shift from: it sizes for
4 simultaneous full-scale bins for hundreds of frames, a signal combination this system will never
actually see, while a single truncation shift also has to leave the *noise floor* (which this WP's
own done-test has to measure) with usable resolution. `RSH = 8` (typical noise component ~5.7,
quantization floor about -120 dBFS, still far below any real noise floor) fixes this. Sized from
`RSH = 8`: per-bin power (`POW_W`) up to 2^41, needs 42 bits; summed over up to 4 bins in a column
(mean mode) up to 2^43, needs 44 bits (`ACCW1`); summed again over frames up to 2^43 x K needs
`ACCW2` bits, and this WP sized that at 48 (covers the pessimistic 4-bin-full-scale case to about
K = 32 before saturating, and the realistic single-dominant-tone case to about K = 1,200) rather
than trying to hold the full pessimistic bound at some very wide width no real design would want.
Both the within-frame and K-frame accumulators saturate (clamp) rather than wrap on overflow past
that, so the failure mode beyond it is a column reading full brightness, not a corrupted number.
48 bits is bigger than ARCHITECTURE's 40-bit estimate; the difference is exactly the noise-floor
resolution the done-test needed and the original estimate did not account for.

### Rounding the K-frame divide

The first working version of `linear_w = kacc_combined / divisor` used a plain Verilog `/`, which
truncates (always rounds toward zero). That is an unbiased choice for a large quotient, but the
noise floor's accumulated values are often only a few times the divisor (weak signal in, few
frames' worth of it summed), where losing up to 1 count to truncation is a large *relative* error,
and because truncation always rounds the same way, those per-column errors do not average out --
they show up as a several-tenths-of-a-dB *low* bias on the averaged noise floor's mean, plus extra
spread on top of the real statistical spread the done-test is trying to measure. Adding half the
divisor to the dividend before dividing (round to nearest instead of down) removes the bias; it
costs one more adder, already inside the one-cycle-per-column combinational path the walk uses, so
no extra pipeline stage.

### Main-lobe dilution in mean mode

The done-test's first run also showed the *tone's own* level reading about 1.77 dB high against a
naive theory. Cause: mean mode sums power over all of a column's bins, and the theory this WP
first wrote assumed the other 3 bins in the tone's column carry only negligible leakage. That is
true of a window's *sidelobes* (Blackman-Harris keeps those below -92 dB here), but not of its
*main lobe*, which is several bins wide even for a tone sitting exactly on one bin -- the adjacent
bin alone carries about -3.3 dBc (46% of the peak bin's power) for this window. A numpy check of
the actual windowed DFT of a bin-1,520 tone (`sum(|X[1520..1523]|^2) / |X[1520]|^2`) gives
1.50218 -- 1.767 dB -- matching the measured discrepancy to 0.005 dB. This is not an RTL bug: the
per-bin power formula was independently confirmed bit-exact against `power2` during development
(0.002-0.02 dB across several checks, see below), and mean mode summing the whole column's real
window-shaped power is exactly what ARCHITECTURE 3.3 asks it to do. The done-test's theory now
includes this factor (a fixed property of this window and of bin 1,520 being the first of its
column, so the ratio applies to offsets 0/+1/+2/+3 specifically); a differently-positioned tone
bin would need the matching offset pattern recomputed the same way.

### log2/dB conversion (`spectrum_log2db.v`)

`dB = 10*log10(power) = log2(power) * (10/log2(10))`. `log2(power) = msb_pos + log2(1+f)`, where
`power = 2^msb_pos * (1+f)`: `msb_pos` from a combinational leading-one search (a barrel shift then
normalizes the value so the leading one sits at a fixed bit position), `log2(1+f)` from a 512-entry
LUT sampled at each bucket's midpoint (`tools/gen_spectrum_tables.py` reports the table's own
worst-case error: 0.0007 dB, negligible next to the 0.5 dB the done-test asks for). The
`10/log2(10)` multiply uses a 24-bit fixed-point constant good to about 2e-5 relative error, same
order of negligibility. `power = 0` (no signal, e.g. gap-fill-only input before the ADC stream
starts) maps to the sentinel `-32768` (1/64 dB units) rather than computing `log2(0)`. 4-stage
pipeline, gap-free (a new `power_in` every cycle is accepted with no back-pressure), which is what
lets the walk above issue one column per cycle.

### Waterfall colour index

`color = clamp(((db64 + offset_db64) * gain_q8) >> 14, 0, 255)`, where `db64` and `offset_db64`
are both already in 1/64 dB units (so adding them is exact) and `gain_q8` is Q8.8 (0x0100 = 1.0,
the reset default, giving 1 colour step per dB with zero offset). This is this WP's own choice --
ARCHITECTURE 3.3 says only that firmware-set offset and gain apply before the colour index, not
the exact formula -- documented here so firmware (a later WP) knows what the registers mean.

### Simplification: several registers are read live, not latched per-frame/per-group

`ctrl.column_mode` is read live by the bin-arrival accumulate logic (so a change takes effect on
whatever bin arrives next, not cleanly at a frame boundary); `ctrl.peak_hold` and `averaging_k` are
read live by the per-column merge/finalize step (so a change mid-walk could, in principle, apply
to only some of the 1,920 columns of that walk). Both are edge cases, not hazards: no X-propagation,
no stuck state, nothing that needs a reset to recover from -- worst case is a visually inconsistent
single line if firmware changes these registers while a K-group is in flight. Full latching
(capture at frame/group boundaries) was judged not worth the extra registers for this WP given the
done-test holds all three constant for the whole run, exactly as real firmware will in normal
operation (set once, then let averaging run). A future WP can add the latches if firmware ever
needs to change these mid-average without a visible glitch.

### Register interface (not yet a fixed repository-wide convention)

No other WP has wired a real block onto the AHB slave yet (ARCHITECTURE 4.1), so there is no
established register-bus convention to match. This WP used a plain synchronous port: `reg_wr`,
`reg_rd`, `reg_addr[15:0]` (byte offset within the block's page), `reg_wdata[31:0]`,
registered `reg_rdata[31:0]`. Both this port and the zoom backend's `zreg_*` port register the
whole bus (address, write data, `reg_wr`/`reg_rd`) once before decoding it (gowin/reports/README.md
"spectrum_pipeline" third pass, same fix as `rx_backend`), so a write lands one clock after
`reg_wr` and a read returns data two clocks after `reg_rd`, not one. Whoever builds the AHB
adapter (a future WP) maps onto this.

### Other exposed interfaces

- **Spectrum line buffer read** (for the compositor, WP V2): `line_rd_addr[10:0]` in,
  `line_rd_data[15:0]` out (1-cycle synchronous read), always reads the *ready* buffer
  (`line_status.ready_buffer`); the other buffer is mid-write and not exposed.
- **Waterfall byte stream** (for the waterfall writer, WP F4): `wf_valid`, `wf_sol` (start of
  line), `wf_eol` (end of line), `wf_data[7:0]`, one word per column, **no back-pressure** --
  the same convention ARCHITECTURE 3.2 already uses for the IQ writer ("no back-pressure, the IQ
  writer always accepts"). F4 must consume at the rate this block produces (57,600 words/s at
  30 lines/s); nothing here throttles for a slow consumer.
- `irq_line_done`: level, follows `line_status.line_done` (set on every completed line, firmware
  clears by writing 1 to that W1C bit) -- fabric interrupt line 5, ARCHITECTURE 4.3.

## Done-test

PLAN's wording: "Tones of known frequency and level plus noise: peak in the expected column, level
within 0.5 dB, averaged noise-floor spread matches theory for K = 156."

The test lives in `sim/spectrum/spectrum_done_test.vh` and is run at two sizes: K = 2 by
`tools/check.sh` (`sim/spectrum/tb_spectrum_pipeline.v`, about 17 s of CPU time), and PLAN's
K = 156 by `tools/spectrum_k156.sh` (`sim/spectrum/spectrum_noise_full_k156.v`, about 15 min of CPU
time). Stimulus: one continuous stream, one sample per clock, of a -6 dBFS tone exactly on bin
1,520 (7.125 MHz -- an exact bin avoids scalloping loss, so the tone's level has a clean closed
form) plus Gaussian noise, sigma 4 ADC LSB. `column_mode = mean`, `peak_hold = 0`. The first
completed line (FFT output frames 0 .. K-1) is read back through the line-buffer port and checked
five ways:

1. **Peak column**: the tone's column, 456.
2. **Tone level**: within 0.5 dB of the closed form below.
3. **Every column against an independent model of everything after the FFT.** The testbench taps
   the FFT's output (F1's verified interface: `out_index`, `out_re`, `out_im`) and does the rest
   itself in plain integer arithmetic: rounding shift, power, bin -> column (`bin * 3 / 10`, its
   own count of bins per column, its own frame count), sum over the column's bins and K frames,
   round-half-up divide by K x bins, 10 log10. All 1,920 line values must be defined (no X) and
   within 0.02 dB of that model (log2 table error 0.0007 dB plus the 1/64 dB output step). This is
   the check that pins a fault after the FFT to the exact column, independent of any statistics.
4. **Noise-floor level**: mean *linear* power of the noise-only columns (column 0 and the 10 columns
   either side of the tone left out) against the closed form below. Linear, not dB: the mean of dB
   values sits below the dB of the mean by an amount that depends on K (about 0.7 dB at K = 2,
   0.01 dB at K = 156), the linear mean does not, so the check means the same thing at any K.
   Tolerance: 0.05 dB plus 6 standard errors of the mean (0.39 dB at K = 2, 0.09 dB at K = 156).
5. **Noise-floor spread**: coefficient of variation (standard deviation / mean, linear) across the
   noise-only columns, separately for 3-bin and 4-bin columns, within 15% of the exact theory below.
   From K = 32 up, the standard deviation of the dB values (PLAN's "spread") is also held to 15% of
   its theory.

### How the done-test's theory numbers were derived

- **Tone level**: for a real cosine of amplitude `A` exactly on bin `B`, windowed by `w[n]`, the
  windowed DFT at bin `B` is `(A/2) * sum(w)` (the "-B" image aliases far away and is negligible at
  this tolerance). The window module then scales by 8 (its 3 fraction bits) before the FFT, and
  this WP's power stage divides FFT amplitude by `2^RSH` (`RSH = 8`, "Why 40 bits became 48" above)
  before squaring, so the power word this pipeline computes for the tone's own bin is
  `(4*A*sum(w) / 2^RSH)^2`. Mean mode sums the whole column, and the window's main lobe puts real
  power into the other 3 bins too ("Main-lobe dilution in mean mode" above) -- a fixed ratio
  (`MAIN_LOBE_SUM_RATIO`, 1.50218 for bin 1,520). The tone is exactly periodic in the frame, so
  every frame contributes the same value, and the predicted line value is
  `10*log10((4*A*sum(w)/2^RSH)^2 * MAIN_LOBE_SUM_RATIO / bins_in_col)`.
- **Noise-floor level**: for independent input noise of variance `sigma^2` (ADC LSB^2), windowed-DFT
  bin power has mean `64 * sigma^2 * sum(w^2)` at every bin (`64 = 8^2`, the window's fixed-point
  scale, squared). After the `/2^RSH` rounding of each component the mean per-bin power word is
  `sigma^2 * sum(w^2) * 64 / 2^(2*RSH) + 2/12` (the last term is the rounding error of re and im,
  1/12 each; 0.011 dB here). Averaging does not change a mean, so this is also the averaged floor.
  `sigma^2` is measured from the samples actually fed in (16.09 rather than 16: `$dist_normal`
  returns integers, and the tone's own rounding to the ADC grid adds about 1/12).
- **Noise-floor spread**: each bin's power is exponentially distributed (coefficient of variation
  1), but neighbouring bins are *not* independent under a window this wide. For complex Gaussian
  bins the correlation between the powers of bins `d` apart is `|rho(d)|^2`, with
  `rho(d) = |sum w[n]^2 e^(-j 2 pi d n/N)| / sum w[n]^2`; for this window `rho(1) = 0.816`,
  `rho(2) = 0.439`, `rho(3) = 0.150`. The variance of the mean of `m` adjacent bins over `K`
  independent frames is then exactly `mu^2 * sum_{i,j} |rho(i-j)|^2 / (m^2 K)`, so
  `CV^2 = (3 + 4 rho1^2 + 2 rho2^2) / (9K)` for a 3-bin column and
  `(4 + 6 rho1^2 + 4 rho2^2 + 2 rho3^2) / (16K)` for a 4-bin one. A 3-bin column is worth 1.49
  independent bins, a 4-bin column 1.82. The dB standard deviation is `10/ln(10) * CV` when CV is
  small (true at K = 156, not at K = 2, which is why check 5 uses CV). At K = 156 this gives a dB
  spread of 0.276 dB (the earlier version of this document bracketed it between 0.17 and 0.35 dB
  because it did not model the correlation).

### Measured results

| Check | K = 2 (`check.sh`) | K = 156 (`tools/spectrum_k156.sh`) |
|---|---|---|
| Peak column (expect 456) | 456 | 456 |
| Tone level vs theory 95.230 dB | 95.234 dB (+0.005) | 95.234 dB (+0.005) |
| Columns off the post-FFT model by > 0.02 dB | 0 of 1,920 (worst 0.012 dB) | 0 of 1,920 (worst 0.012 dB) |
| Noise floor, linear mean vs theory | 18.257 vs 18.233 dB (+0.024) | 18.253 vs 18.245 dB (+0.007) |
| Spread, 3-bin columns: CV vs theory | 0.582 vs 0.580 | 0.0710 vs 0.0656 (+8%) |
| Spread, 4-bin columns: CV vs theory | 0.540 vs 0.525 | 0.0597 vs 0.0594 |
| Spread, dB standard deviation vs theory | 2.51 vs 2.44 dB (reported only) | 0.291 vs 0.276 dB (+5%) |

All checks pass at both sizes. The K = 156 run took about 21 minutes of wall time on a heavily
loaded PC; the K = 2 run is about 17 s of CPU time (70 s wall on the same loaded PC).

The 3-bin spread at K = 156 sits 8% above theory, about 3 standard errors. That excess is in this
particular noise sequence, not in the design: a double-precision numpy model of the ideal window,
FFT and column average, fed the identical 2.56 million samples from Icarus's `$dist_normal` (seed
12345), gives 0.0708 for the 3-bin CV and 0.290 dB for the dB spread -- the RTL's 0.0710 and 0.291
dB to within 0.3%. Six runs of the same numpy model on numpy's own Gaussian noise give 3-bin CVs
of 0.062-0.067, around the 0.0656 theory.

### The noise-floor fault (found and fixed)

Before the fix, the K = 156 run put the tone in the right column at the right level, but the noise
floor read 0.73 dB below theory with a column-to-column spread of 1.53 dB, and K = 8 gave almost the
same (0.92 dB low, 1.94 dB): more averaging barely helped, as if only about two frames counted.

**How it was found.** A debug run (K = 2, noise only) dumped the signals at every stage boundary
and compared each with a model of the stage before: the per-bin power words against a numpy FFT of
the same input samples (correct), the per-frame column sums the walk reads against sums of those
dumped power words (wrong in about a third of the columns), and from there on (K-frame
accumulator, divide, dB) each stage against the previous stage's dump (correct), plus the line
buffer itself (last 5 columns undefined). Two independent bugs, both deterministic per column,
which is why averaging more frames could not shrink the spread they caused.

**Cause 1: the "first bin of the column" ROM was wrong in 666 of 1,920 columns.** Within a frame,
the first of a column's bins to arrive overwrites the column's sum and the others add to it
("Within-frame column reduction" above); `col_first.hex` says which bin arrives first.
`tools/gen_spectrum_tables.py` compared a bin's arrival time against the *bin number* of the best
candidate so far instead of that candidate's arrival time. In the affected columns the flag sat on
a bin that arrives second or third, so the sum restarted part-way through the frame and one or two
of the column's 3-4 bins were dropped, every frame, in the same columns. Those columns read up to
several dB low and are noisier (fewer bins averaged), a fixed pattern that no amount of averaging
removes. The tone's column happened to be one of the correct ones, which is why the tone checks
passed. Fixed in the generator (compare arrival with arrival), the ROM regenerated, and the
generator now replays a frame the way the RTL reduces it and refuses to write a ROM that loses a
bin.

**Cause 2: the line buffer swapped 5 columns too early.** `write_buf` (which half of the
double-buffered line the dB converter writes into), `ready_buf_reg` and `line_count_reg` changed
when the walk *issued* its last column, but the walk's read stage and the 4-stage dB converter
still held the last 5 columns at that point. Those 5 were written into the other half: the line
handed to the reader had 5 undefined (never written) columns 1,915-1,919, and the next line got
stale values there. The old testbench read the undefined values as 0 dB, which alone adds about
0.9 dB of spread to a 17-18 dB floor. Fixed by swapping on the dB converter's last output
(`line_complete_pulse`, the same event that already raised the line-done interrupt), so the line
count, the ready buffer and the interrupt now all change together, after the last column is
written.

**What had misled the earlier investigation**: every check it ran looked at one column (the tone's
or DC's), and both of those columns were correct; the "effective K of about 2" reading came from
treating a fixed per-column error as if it were random noise that averaging should shrink. The column-by-column model comparison
(check 3 above) now catches both bugs directly at K = 2: with the old ROM it reports 665 columns
off (worst 11 dB) and the noise-floor level 0.55 dB low; with the old line swap it reports the 5
undefined columns.

### Frame margin at the end of the stimulus

The testbench keeps feeding samples for `N + 616` cycles after the last sample of the group. The
FFT is a single-path delay-feedback pipeline: output frame f comes out *while input frame f + 1
goes in* (docs/F1_FFT.md "Interface for F2 and F3"), so the last frame of a group only reaches
the spectrum stages once almost another whole frame has been fed after it. A margin shorter than
`N` (the earlier 2,000-4,000) therefore never completes a line; it is not a drain-time bug. In the
real system the ADC stream never stops, so this only matters to testbenches.

### The group_pos latch

`first_of_group_w` (whether this is the first frame merged into a K-group, so the accumulator is
overwritten rather than added to) used to read `group_pos` directly. `group_pos` advances at the
same walk-ending event that lets the *next* walk start, and because the pipeline still has that
walk's last column or two in flight when this happens, the last column of every walk was
evaluating `first_of_group_w` against the *next* walk's group position, not its own. Fixed by
latching a `walk_first_of_group` register at the same points `walk_finalize` is already latched
(walk start, and the defensive pending-walk restart), so the whole walk sees one consistent value
for the whole 1,920-column pass, matching how `walk_finalize` was already handled.

### Testbench notes

While developing the register bus, a two-line register-write helper task that set `reg_addr`,
`reg_wdata`, `reg_wr` with a plain blocking assignment immediately after `@(posedge clk)` produced
a corrupted write (`averaging_k` ended up holding the *next* write's data, `1`, instead of `156`)
in Icarus: the testbench's `initial` block and the DUT's `always @(posedge clk)` block are two
separate processes triggered by the same edge, and Verilog does not define their relative
execution order when both use blocking assignment in that situation. Adding a 1 ns delay
(`@(posedge clk); #1; ...`) after the edge before driving the bus fixes it -- the DUT's block,
scheduled at the edge itself, always sees the *previous* cycle's stable values, and the new values
are settled well before the next edge. `sim/spectrum/spectrum_done_test.vh` uses this pattern for
every register write; any future testbench driving this bus (or any other synchronous input) from
a separate process should too.

## WP RB6: log-domain average, window ROM interpolation, single buffer, shared zoom backend

WP RB6 (`docs/ARCHITECTURE.md` section 3.14, changes C6a-C6d; branch `rb6-specback`) made four
changes inside `rtl/spectrum/spectrum_pipeline.v`, and gave the zoom spectrum (`docs/F3_ZOOM.md`)
its own averaging/dB/waterfall backend by extending the same file rather than writing a second,
separate implementation of the expensive parts.

### (a) The K-frame divide is gone

`kacc_combined / divisor` (a 48-bit by 23-bit plain `/`, 7.9k logic in the original synthesis
estimate below) is replaced by `rtl/spectrum/spectrum_ratio_db.v`: `db = 10*log10(num) -
10*log10(den)`, computed from two `rtl/spectrum/log2_core.v` instances (the leading-one search
plus LUT this WP's own predecessor, `spectrum_log2db.v`, already used for a single value -- that
file is removed, split into `log2_core.v`, reusable, and `spectrum_ratio_db.v`, the new
subtract-in-the-log-domain wrapper) run in parallel on the numerator and denominator. This is not
only cheaper, it is *more* accurate than the design it replaces: the old code rounded
`kacc_combined / divisor` to the nearest **integer** before taking its log2, which lost real
information whenever a column's sum was only a few times its divisor (exactly the noise-floor
columns the done-test measures); the log-domain method never forms that intermediate integer
quotient at all. Measured effect on the done-test: the tone level and noise-floor level both moved
*closer* to their closed-form theory than before (tone diff -0.011 dB vs the pre-RB6 measurement of
+0.005 dB; noise floor diff +0.016 dB vs +0.024 dB), and the model check's worst per-column error
(check 3, docs below) is 0.012 dB at K = 2, identical to the F2 baseline.

### (b) Window ROM: every 8th sample, linearly interpolated

`rtl/spectrum/tw/window_coeffs.hex` keeps only every 8th sample of the symmetric half (1,025
entries instead of 8,192, i = 0, 8, .., 8,192); `spectrum_window.v` reads the two neighbouring
stored samples and interpolates (one extra pipeline stage: ROM read -> interpolate -> multiply, was
ROM read -> multiply). Measured worst-case interpolation error (`tools/gen_spectrum_tables.py`):
4.7e-6 of full scale, under the 18-bit coefficient's own quantization step (7.6e-6) -- the actual
measurement came in about 3x the -- 1.4e-6 -- back-of-envelope bound `docs/ARCHITECTURE.md`'s own
change note used, but is still comfortably under one coefficient LSB, so the window's -92 dB side
lobes are unaffected (confirmed by the done-test's own tone-level and noise-floor checks passing at
the same tolerances as before).

### (c) One column buffer plus an arrival FIFO -- 1,024 deep, not 512

The ping-ponged pair of per-frame column accumulators (`cfa_mem[0:1][0:1919]`) is now one buffer
(`cfa_mem[0:1919]`) plus a small FIFO that queues bin arrivals for as long as the (now shared, see
(d)) walk engine is reading that buffer, draining once it is free -- `docs/ARCHITECTURE.md`'s own
change note for this estimates "at most about 400" bins arrive during a walk and suggested sizing
the FIFO at 512. Measured directly in simulation (feeding a real stimulus and watching the FIFO's
own fill level): the full-band side's peak is **exactly 750**, not "about 400" -- and it is exact,
not statistical, because bin arrival times depend only on the FFT's fixed bit-reversal structure
(`NUM_COLS * NUM_BINS / N` = 1,920 * 6,400 / 16,384 = 750 precisely), not on the input signal, so
every walk sees the identical count. A 512-entry FIFO silently wraps once the backlog passes 512,
overwriting not-yet-drained entries with no error indication -- this went unnoticed until the
done-test's model check (below) started reporting hundreds of columns off by a few dB, which traced
back to exactly this. The FIFO is 1,024 entries now (`FIFO_AW = 10` in `spectrum_pipeline.v`),
comfortably above 750; the zoom side's own worst case is far smaller (its front end sees a new bin
only once every several tens of `clk_dsp` cycles, not every ~2.6) but shares the same depth for one
uniform design rather than two FIFO sizes.

A second, independent bug in the same area, also found via the done-test: queueing bin arrivals
only *while the walk is busy* is not enough. A bin that arrives once the walk has just finished can
overtake an **earlier** bin for the *same column* that is still sitting in the FIFO, not yet
drained -- the later, "not first" bin would then accumulate onto stale data, and the earlier,
actually-first bin would overwrite it once drained, silently discarding the later bin's
contribution. The fix (`rtl/spectrum/spectrum_pipeline.v`'s `queueA_mode`/`queueB_mode`): a new
arrival queues whenever there is *any* backlog left to stay behind, not only while the walk is
literally busy; direct (bypass-the-FIFO) processing only resumes once the FIFO is completely empty.
Mean mode (sum) and max mode (max) are both commutative, so *within* the FIFO or *within* live
processing, arrival order never matters -- only the ordering *between* the two paths did.

### (d) One shared walk engine, now also serving the zoom spectrum

`rtl/spectrum/spectrum_walk_core.v` is the sequential per-column engine (address sequencing, the
K-frame combine, and -- via `spectrum_ratio_db.v` -- the log-domain average and dB conversion) that
used to be inlined once, for the full-band side only, inside `spectrum_pipeline.v`. It is now a
separate module, one instance, arbitrated between two request lines: the full-band spectrum (which
still keeps its own `cfa_mem`, `kacc_mem`, `col_bins_rom`/`col_first_rom` and double-buffered line
buffer) and the new zoom backend (its own `zcfa_mem`, `zkacc_mem`, `zcol_bins_rom`/`zcol_first_rom`
and line buffer, driven by a raw complex bin stream from `rtl/zoom/zoom_spectrum.v` on new
`zoom_in_*` ports -- that module's own DDC and FFT are unchanged and not duplicated). Only one walk
runs at a time; ties favour the full-band side (the higher-rate stream). Combined occupancy is
about 7% of `clk_dsp` (the full-band side alone was already about 6%), so contention is rare and
costs at most one walk's worth of cycles (about 1,930) to the loser, negligible next to either
side's own frame period.

Zoom's own bin -> column mapping (3,277 usable bins of the 4,096-point complex FFT, `docs/F3_ZOOM.md`
section 6, onto the same 1,920 screen columns) is not a small exact fraction the way the full-band
side's 6,400/1,920 = 3.33 is, so `tools/gen_spectrum_tables.py`'s `gen_zoom_column_tables()` finds
an exact multiply-shift constant by brute-force search (`mult = 614,363`, `shift = 20`) instead of
hand-deriving one, verified the same way the full-band tables are: a full-frame replay that must
recover every usable bin's contribution with none dropped. `rtl/zoom/zcol_first.hex` and
`rtl/zoom/zcol_bins.hex` play the same roles as the full-band side's `col_first.hex`/`col_bins.hex`.

The zoom backend's registers (`ctrl` bits 4-5, `backend_averaging_k`, `backend_level`,
`backend_line_count`, `backend_line_status`) were added to `hw/regmap/zoom.toml`, the same page the
zoom DDC/FFT's own `phase_inc`/`ctrl.enable`/`ctrl.span_shift` already live on (that file's own
description already said this page covers "zoom DDC and zoom spectrum"); no SoC top wires the two
blocks' register decodes onto one physical bus yet, so `spectrum_pipeline.v`'s zoom register port
only decodes its own fields -- see that module's own port comment.

### A subtle timing bug the shared engine's own isolated test caught

`spectrum_walk_core.v` originally re-registered `cfa_rdata`/`kacc_rdata`/`bins_rdata` a second time
internally, on top of the caller's own registered memory read (which already supplies data one
cycle behind the address, the same convention WP F2's original single-context walk used with a
single, direct memory read). That left the address tag one cycle *ahead* of the data describing it,
so every column from the second one on read as the *previous* column's value, and the true last
column's value was dropped entirely -- caught by a small standalone testbench for
`spectrum_walk_core.v` alone (eight synthetic columns, no FFT, no front end) before it was ever
wired into `spectrum_pipeline.v`, precisely because that isolation made "column N's output should
equal column N's known input" trivial to check column by column. Fixed by not re-registering the
already-registered inputs; the column tag downstream (`line_col`) is now carried through
`spectrum_ratio_db.v`'s own fixed 5-cycle latency as a delay line on the address itself, rather than
a free-running counter reset at walk start -- deliberate, not just simpler: a free-running counter
would be corrupted by a *different* context's walk being granted while this walk's own tail is still
draining through the shared arithmetic, which the address delay line is immune to by construction
(each column's tag travels with its own data).

### Zoom backend done-test

`sim/zoom/tb_zoom_backend_quick.v` (run by `tools/check.sh`) exercises exactly what this WP built --
the shared walk engine, the log-domain average, the zoom column-mapping tables and the
single-buffer-plus-FIFO front end -- by injecting a synthetic complex bin stream directly onto
`spectrum_pipeline.v`'s `zoom_in_*` ports instead of decimating real ADC samples through the zoom
DDC and FFT (already covered by WP F3's own tests): a full zoom FFT frame at the narrowest span
needs 4,096 x 1,280 = 5,242,880 ADC clocks, several times `check.sh`'s whole budget for one test.
One usable bin gets a fixed tone value every frame, every other usable bin gets an independent
Gaussian value every frame (real and imaginary parts, so K-frame averaging is genuinely exercised);
since these are synthetic bin values rather than a real window's output, adjacent bins are
independent (no window main-lobe correlation to model, unlike the full-band side's real windowed
FFT). Checks mirror WP F2's own five, adapted for the zoom side's own column/bin counts. Measured:
peak in the expected column; every one of 1,920 columns within 0.02 dB of an independent model
(worst 0.011 dB); noise-floor level within 0.05 dB of the closed-form theory for independent bins;
noise-floor spread (CV) within 10% of theory.

Two more bugs surfaced building this test (both in the *test*, not the RTL -- worth recording since
they cost real time and are easy to hit again): (1) Icarus mishandles a signed 32-bit `integer`
combined with a wider **unsigned** `reg` in the same arithmetic expression (`ref_sum[c] + re_i*re_i
+ im_i*im_i` with `ref_sum` a 64-bit unsigned `reg` and `re_i`/`im_i` 32-bit signed `integer`s
computed a squared term that was always non-negative but got reinterpreted through zero-extension
as if `re_i` itself were unsigned, producing values near 2^64 for ordinary small negative inputs) --
worked around by computing the squared term into a separate 32-bit `integer` first, then adding
that (WP F2's own model sidesteps this by keeping every accumulator variable the same signed
64-bit width throughout, never mixing widths). (2) modelling `(s + RHALF) >>> RSH` as real-valued
round-half-away-from-zero disagreed with the RTL's actual round-half-*up* (toward +infinity, from
the arithmetic shift) at the tie itself (`s = -128` rounds to 0 in the RTL, -1 under symmetric
rounding) -- fixed by doing the rounding in plain integer arithmetic, bit for bit like the RTL,
instead of in real numbers.

The literal WP F3 done-test wording ("1 kHz tone off centre at 48 kHz span"), run through the real
DDC and FFT with noise added, is `sim/zoom/zoom_backend_full_sim.v`
(`tools/zoom_backend_full_sim.sh`; not part of `check.sh` -- see that file's own header for why, the
same reason `sim/zoom/zoom_bin48_sim.v` already is not).

## Resources (estimate from yosys, not place-and-route)

`sim/spectrum/yosys_gw5a.ys`: yosys 0.69 `synth_gowin -family gw5a`, whole `spectrum_pipeline`
including its FFT instance. Unlike `sim/fft/yosys_gw5a.ys`, **`fft_mul` is not blackboxed here**
(the `.ys` file explains why: `spectrum_pipeline.v` is self-contained via `` `include ``, the same
convention `tools/check.sh` requires of a testbench, and re-reading `fft_mul.v` after a separate
blackbox read is a duplicate-module error in yosys) -- its 6 twiddle multiplies are folded into
generic logic here instead of appearing as 24 DSP entries the way docs/F1_FFT.md's own run
reports. Add those 24 DSPs back in when comparing the two runs' totals, and expect this run's
LUT/ALU numbers to run well above F1's for that reason, on top of this WP's own new logic:

| Resource | Used | GW5AST-138 has | Share |
|---|---|---|---|
| LUT (LUT1-LUT4) + MUX2_LUTx | 45,626 | 138,240 | 33.0% |
| Carry-chain adder cells (ALU) | 7,060 | -- | -- |
| Registers (DFF + DFFRE + DFFSE) | 7,046 | 138,240 | 5.1% |
| Block RAM (18 kbit-class: DPB 12, DPX9B 41, SDPX9B 6, SPX9 15) | 74 | 340 | 21.8% |
| Block RAM, other (SP) | 2 | 340 | 0.6% |
| LUT RAM (RAM16SDP4) | 48 | -- | -- |
| DSP multipliers | 0 (not inferred without blackboxing `fft_mul`; add F1's 24 back in) | 298 | -- |

(Measured after the `RSH = 8` / 48-bit-accumulator sizing described above; small further changes
since -- rounding the K-frame divide, latching `walk_first_of_group`, moving the line-buffer swap
to the dB converter's last output -- were not re-measured, and would not change this table by more
than a handful of cells either way.)

No dedicated multiplier or divider primitive appears at all: yosys's generic `synth_gowin` flow
did not infer GW5A DSP blocks for anything in this design (matching the caveat F1 already
documented for its own multiplies). The LUT/ALU total here is dominated by logic that a real
Gowin synthesis run would very likely map very differently -- the window multiply, the two power
squares, the colour-index multiply, and above all the K-frame divide (`kacc_combined / divisor`,
a 40-bit by 23-bit plain `/`) are all candidates a vendor DSP wrapper or a purpose-built divider
would shrink substantially (PLAN R3 does the same job for the receiver bank; see "Open" below).
Treat this table as "it synthesizes, elaborates, and passes yosys's own checks with 0 problems
found" rather than as a real area budget -- that needs Gowin place-and-route (PLAN T1), same
caveat as F1's own resource numbers. Superseded by "WP RB6: measured resources" below, which uses
`tools/yosys_res.sh` (the project's current resource-ledger tool, ARCHITECTURE.md 3.14) instead of
this section's own older `sim/spectrum/yosys_gw5a.ys`, and adds real Gowin place-and-route numbers.

## WP RB6: measured resources (yosys and real Gowin place-and-route)

`tools/yosys_res.sh spectrum_pipeline rtl/spectrum/spectrum_pipeline.v` -- this WP's target
(docs/ARCHITECTURE.md 3.14 change C6d): F1 + F2 + the zoom backend together at most 15k logic and
81 BSRAM (18-kbit primitives).

| Resource | Used | Target |
|---|---|---|
| DSP multipliers | 34 | -- |
| BSRAM (18-kbit primitives) | 87 | at most 81 |
| Logic (LUT1-4 + ALU + 6 x RAM16SDP4) | 10,519 | at most 15,000 |
| Registers | 8,004 | -- |

Logic is comfortably inside target (30% margin). **BSRAM is 87, 6 over the 81 target.** Where it
goes: this design now has many more separate memories than the pre-RB6 F2 alone did -- two 44/48
bit K-frame-and-column accumulators, two 1,024/128-entry arrival FIFOs, four column-mapping ROMs
and four line buffers, one per context, plus the shared walk engine's own two log2 lookup tables
-- and yosys maps each memory's *width* to whole 9-bit-wide GW5A primitive lanes: a change of
2 depth (the zoom side's own arrival FIFO went from 1,024 to 128 entries once its real worst-case
backlog was worked out, ~96 vs the full-band side's 750 -- see "Why the arrival FIFO is 1,024
deep" above) only bought back 1 of the 88 BSRAM the shared-FIFO-depth first version measured,
confirming width, not depth, is what is driving this number. Closing the remaining 6 needs either
narrower per-context accumulators sized to the zoom side's own smaller bin count (1-2 bins per
column, not the full-band side's 3-4, so its own RSH/power width could shrink independently of
the full-band side's) or sharing the two log2 lookup tables' identical content through one
dual-port memory instead of two copies -- both real, both credible, and both left for a follow-up
pass rather than risked without the simulation time to re-verify them properly (a lesson already
paid for twice in this same work package: see "A subtle timing bug" and the FIFO ordering bug
above, both found only because the done-test was run after each change, not assumed correct from
reasoning about it alone).

**Gowin place-and-route** (`gowin/res.sh`, PLAN WP T1's own tool): `spectrum_pipeline` has 316
ports (208 in + 120 out, excluding clk/rst -- WP RB6's new zoom ports pushed it over the
GW5AST-138's 292 regular user I/O), so it needs the shift-chain wrapper
`gowin/wrap/spectrum_pipeline_ooc_wrap.v` the same way `gowin/wrap/rx_backend_ooc_wrap.v` and the
DDR3 arbiter wrappers already do (see that file's own header).

| Run | Logic | Register | DSP | BSRAM | Fmax | Worst path |
|---|---|---|---|---|---|---|
| Before WP RB6 (`gowin/reports/spectrum_pipeline/summary.txt`, full-band only, no zoom backend) | 10,871/138,240 | 1,731 | 34 | 101 | **4.604 MHz** | the K-frame divide, `kacc_mem` into the old `spectrum_log2db`'s ROM address |
| After WP RB6, before pipelining the window interpolator | 7,790/138,240 | 2,532 | 41 | 117 | 81.894 MHz | the new window interpolator, ROM read into the interpolated-coefficient register (`spectrum_window.v`) |
| After splitting that interpolator over two pipeline stages | 7,712/138,240 | 2,566 | 41 | 117 | 81.902 MHz | `spectrum_walk_core.v`'s combine logic, `cfa_mem`'s own BSRAM read landing directly on `kacc_combined`'s register with no register in between |
| After adding a settling register for that BSRAM read too (stage A2, `spectrum_walk_core.v`) | 7,753/138,240 | 2,683 | 41 | 117 | **83.457 MHz** | moved outside WP RB6 entirely -- `rtl/fft/fft_twmul.v`'s own twiddle ROM read into a multiplier operand, inside WP F1's FFT (`u_fft/g_st[2].g_mul.u_mul`), unchanged by this WP |

Removing the K-frame divide alone took Fmax from 4.6 MHz to 81.9 MHz, an 18x improvement, before
any pipelining aimed at 150 MHz specifically -- confirming the divide, not anything else in this
design, was the dominant timing problem the pre-RB6 measurement found. Two more rounds of
pipelining WP RB6's own new logic (the window interpolator's multiply/round/add/clamp chain, then
the walk engine's BSRAM-read-to-combine path) each moved the worst path to the next-slowest thing
in the design, netting only a further 1.6 MHz combined -- both are plain latency changes with no
effect on any value this WP's done-tests check (all three re-passed after each change, docs above).

**The critical path is now outside WP RB6's own files.** The fourth row's worst path is inside
`rtl/fft/fft_twmul.v`, part of WP F1's FFT core (`docs/F1_FFT.md`), completely unchanged by this
WP -- it was always there, simply hidden behind the much slower divide and (briefly) the window
interpolator and walk engine paths this WP has now removed. Closing the remaining gap to 150 MHz
needs pipelining *that* twiddle multiplier, which is WP F1's own file, not touched by RB6's task description
(this WP's scope is `rtl/spectrum/`, plus the zoom backend it added there) and not something this
work verified against F1's own done-test (`docs/F1_FFT.md`) or its bit-exactness with the
Python model that test checks against. Recorded here as this WP's honest stopping point on timing:
every critical path this WP's own changes introduced or could remove has been removed (18x, then
another 2%, over the three rows above); the one that remains is a pre-existing WP F1 issue this
WP's own tests do not cover and this WP does not have the mandate to change.

## Timing, second pass (Gowin place-and-route at 150 MHz)

`gowin/reports/spectrum_pipeline/`: 82.3 MHz on the RB6 RTL, **116.5 MHz** after this pass
(not closed; the pass was stopped there by owner priority). Every change keeps the values
(checked against the previous RTL: identical window, FFT, line and waterfall outputs in both
done-tests); only clocks were added:

- Column buffer read-modify-write (`cfa_mem`, `zcfa_mem`): four clocks instead of two (read,
  read data registered, sum and max compare registered, select written). A column's next update
  must be issued at least four jobs later instead of two; bins of one column arrive thousands of
  samples apart in the FFT's bit-reversed order, and the walk's reads of columns 0 and 1 come more
  than three clocks after the last job that could touch them.
- Front end: the column number, first-bin flag and power get one more register stage (stage 3)
  before the job select; everything after it, the walk request included, is one clock later.
- Walk engine: the combine stage is two clocks (write-back 4 clocks after the address, was 3);
  `log2_core.v` has 4 stages (was 3), so `spectrum_ratio_db.v` is 6 clocks (was 5).
- Window: 7 pipeline registers (was 4): the interpolation's multiply, round/add and clamp, and the
  output multiply, each registered.
- **Bug fixed**: the walk's K-accumulator write-back and line output were steered by the engine's
  current context, which switches to the next walk's context two clocks after the last address
  while the previous walk's last columns are still in the pipeline. With both spectra running, a
  zoom walk granted straight after a full-band walk took the full-band walk's last write-backs and
  line outputs, its line-complete pulse included (and the other way round). Each column now carries
  its own context. `sim/spectrum/tb_spectrum_two_ctx.v` runs both contexts with back-to-back walks
  and checks each line's columns (the previous RTL fails it). The existing done-tests run one
  context at a time and did not see it.

Remaining paths at 116.5 MHz: the register-bus write decode and the averaging-K clamp in front of
the settings and the walk request, the column sum's saturation, and the walk-busy flag into the
column buffer's address select.

## Open

- **Resolved by WP RB6**: the K-frame divide (was the dominant timing and logic cost, see that
  section's own before/after) is gone, replaced by the log-domain method; the window ROM is
  smaller and interpolated; the zoom spectrum now has its own column-mapping constants and its own
  full averaging/dB/waterfall backend, sharing the walk engine and log2 unit with this one.
- `spectrum_window.v`'s and the colour-index computation's multiplies, like F1's `fft_mul`, are
  candidates for a Gowin DSP wrapper (PLAN R3 does the same for the receiver bank); none of them
  are wrapped yet. `rtl/spectrum/log2_core.v`'s leading-one search (a 48-bit combinational priority
  encoder, run twice per column in `spectrum_ratio_db.v`) is a new candidate WP RB6 added; not
  evaluated against 150 MHz timing beyond the Gowin place-and-route run this WP itself did (see
  "WP RB6" above) -- pipeline it further if that run's own critical path ever lands there instead
  of somewhere else.
- Peak-hold mode (`ctrl.peak_hold = 1`) is implemented and exercised only informally during
  development (the quick functional check while building this pipeline, not the committed
  done-test, which uses averaging mode per PLAN's own "K = 156" wording); a dedicated peak-hold
  testbench would strengthen confidence in that mode specifically. WP RB6 did not add one for the
  zoom side's own peak-hold bit either.
- The zoom backend's literal done-test through the real DDC and FFT
  (`sim/zoom/zoom_backend_full_sim.v`, `tools/zoom_backend_full_sim.sh`) takes on the order of an
  hour and did not finish in this work (several other long runs were competing for the same CPU
  at the same time; it was killed, still running, after two hours to let `tools/check.sh` finish
  instead) -- see `docs/F3_ZOOM.md` section 9 and this document's own "Zoom backend done-test"
  above for what it covers and why the fast version that did run in this work
  (`sim/zoom/tb_zoom_backend_quick.v`) is believed to already exercise the same logic correctly.
  Re-running this one to completion, ideally without other heavy jobs competing for CPU, is
  recommended before relying on it for a release.
- No SoC top wires the zoom DDC/FFT's own register decode and the zoom backend's new one onto the
  same physical `hw/regmap/zoom.toml` page yet (both are separate module ports today); see
  `spectrum_pipeline.v`'s own port comment for exactly what that integration will need to do.
