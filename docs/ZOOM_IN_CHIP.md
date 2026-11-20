<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# The zoom receiver in the chip

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Branch `zoom`, 2026-10-12. Work package F3 (docs/F3_ZOOM.md) was built and tested alone; this puts it into
`rtl/top/sdr_core.v`. **Nothing here has run on a board.** A second pass (timing, block RAM 43 to 32,
spans down to 3 kHz, the FT8 screen on the zoom waterfall) is in sections 10 to 13 at the end; where they differ
from sections 3, 6 and 7, they hold. Sections 6 and 7 are what the owner has to read:
the block RAM budget is not met, and the FT8 screen does not use the zoom waterfall by default.

## 1. What existed

| Piece | State before |
|---|---|
| Zoom DDC, window, 4,096-point FFT (`rtl/zoom/zoom_spectrum.v`) | built and tested alone, not in the chip; written before the timing lessons (one 82-bit add per clock, filters with a memory read, an add and a multiply in one clock) |
| Zoom averaging, dB, line buffer, waterfall bytes | inside `rtl/spectrum/spectrum_pipeline.v` as its second context; its input was tied to 0 in the core, so synthesis removed it |
| Compositor | parameter `ZOOM_SNAP` (a second line in the trace snapshot memory), off |
| Registers | `hw/regmap/zoom.toml` a draft; the DDC's part (centre, span, enable) had no register port |
| Waterfall | one writer, one ring, for the full band |

## 2. What is in the chip now

```
HL2 samples (as the receiver bank) -> zoom_frontend: page 0x06 registers (id, phase_inc, ctrl.enable, ctrl.span_shift)
                                      + zoom_spectrum: mixer, CIC / 10, CIC / 2^span, half-band / 2, droop filter,
                                        window, 4,096-point FFT
   bins -> spectrum_pipeline, zoom context (ctrl bits 4, 5 and backend_* of the same page): columns, averaging, dB
        -> trace line  -> compositor's zoom snapshot  -> any trace window with win_ctrl.source_zoom
        -> waterfall bytes -> second waterfall_writer -> zoom ring in DDR3 (video page: wf_zoom_ring_base,
           wf_zoom_write_line) -> a waterfall window with wf_win_ctrl.line_src = 1 (V2_COMPOSITOR.md section 10)
```

- New: `rtl/zoom/zoom_frontend.v`. Both it and the spectrum pipeline see page 0x06; each answers 0 for registers
  that are not its own and the core ORs the two read words. Block id `0x5A4D_0001`; a chip without the zoom reads 0.
- `sdr_core` has a parameter `ZOOM` (default 1). `ZOOM = 0` leaves the receiver, its writer and the
  compositor's zoom snapshot out: the chip as it was.
- The zoom waterfall writer uses the write arbiter's capture tier (see section 7).
- All core edits are between `zoom begin` / `zoom end`, in the compositor block, in the zoom ports of the spectrum
  instance and in the capture-tier lines of the write arbiter instance.

## 3. Spans and rejection

Unchanged: seven spans, 3.072 MHz to 48 kHz, 3,277 bins across 1,920 columns. The new chain gives **the same
values as the first version, word for word** (section 5), so the measured alias rejection of docs/F3_ZOOM.md
section 8.2 stands: 79.6 dB at the widest span, 83.2 dB at the other six (6 of 7 spans reach 80 dB). The alias
simulation itself was not run again.

## 4. What changed in the RTL, and why (docs/TANG_LESSONS.md sections 3 to 6)

| File | Change |
|---|---|
| `zoom_ddc.v` | fixed CIC is the receiver bank's fan-out-limited `rx_cic_fixed` (straight swap); six kept reset copies; ADC word, strobe and the negated phase increment registered |
| `cic_var_pow2.v` | rewritten: the 82-bit accumulators add in two halves on two clocks with the carry in a register; resets and enables as kept copies of at most 10 loads (`rx_fan`, `rx_vreg`); output select and rounding in two clocks. Needs inputs 8 clocks apart (it gets 10). The first version is `sim/zoom/ref/cic_var_pow2_ref.v` |
| `zoom_fir_half.v`, `zoom_cic_comp.v` | rewritten as a pipeline of one short step per clock around the receiver bank's `rx_mac` (the instantiated DSP block: input, product and output register, the sum inside the block, rounding constant as its start value). A job's taps follow the previous job's without a gap, so the half-band made an output in 32 clocks. Since 2026-10-12 (clock 120 MHz) it has two multipliers per channel and makes one in 16 (18 with the two writes of a burst), see the header of `rtl/zoom/zoom_fir_half.v`; its delay line is 4 block RAMs (two banks by address bit 4) instead of 2. The half-band's job queue (a 256-entry memory) became a counter; the droop filter's delay line went from 512 words of block RAM to 32 of LUT RAM, its coefficient sets are read from a LUT ROM directly |
| `zoom_window.v` | ROM read with registered address and output register, multiplier with input and output register, rounding its own clock |
| `zoom_spectrum.v` | FFT with `SR_LUT = 1` (as the full-band FFT) and its 128-word delay line in LUT RAM (`LUT_MAX_W`, a new parameter of `rtl/fft/fft_delay.v`, default unchanged); `syn_maxfan = 10` |
| `spectrum_pipeline.v` | the zoom context's 128-entry arrival FIFO as LUT RAM (it is read without a register; as block RAM it took 6 blocks) |

Manuals: no new primitive or tool setting is used. The DSP block is used only through `rx_mac`, whose settings and
manual references are those of the receiver bank's timing work (header of `rtl/rx/fir_decim.v`); block RAM and LUT
RAM follow the rules already written down in TANG_LESSONS sections 4 and 6. I did not open Gowin's guides again.

## 5. Verified

| Test | Result |
|---|---|
| `sim/zoom/zoom_rb1_compare_sim.v`: new chain against the first version (`sim/zoom/ref/`), a whole FFT frame, widest span | 0 of 4,096 words differ |
| `sim/zoom/tb_cic_var_pow2.v` (new): the variable CIC against its first version at all 7 decimations, random full-scale words, a reset in each run | 1,746 words, 0 differ |
| `sim/zoom/tb_zoom_quick.v` | PASS: peak in bin 48, 2.629e14 |
| `sim/zoom/zoom_rb1_burst_sim.v`: whole HL2 frames on consecutive clocks, against the first version | 0 of 4,096 words differ (28 bursts) |
| `sim/video/tb_compositor.v`, built with the zoom snapshot, one window showing the zoom line | 15,478 pixels, 0 errors |
| `sim/top/tb_sdr_core.v` with the zoom receiver in the core | PASS (it does not drive the zoom's registers) |
| `cargo test -p tr-fabric -p tr-station` | pass |

Not run: the alias simulation over all spans, the 48 kHz literal test (`zoom_bin48_sim.v`), the zoom back end's
long test, the QEMU script after step 2 (its screen path is the same software waterfall as in step 1). The zoom
simulations are now slow in iverilog (18 minutes for the quick one, was one): the kept register groups are
thousands of small processes.

## 6. Cost and timing

Whole chip, synthesis only, counted the way place-and-route counts (`gowin/reports/zoom/chip_syn.txt`):

| | Zoom receiver (DDC, window, FFT) | Zoom context of the spectrum pipeline | Compositor snapshot, writer | Zoom in all | Whole chip with zoom |
|---|---|---|---|---|---|
| Block RAM (of 340) | 26 | 15 | 2 + 0 | **43** | **284 = 83.5 %** |
| DSP (of 298) | 30 | about 3 | 0 | about 33 | about 145 = 48 % |
| Logic (LUT + adders + 6 x LUT RAM) | 14.6k | about 2k | 0.5k | about 17k = 12 % of the chip | 86.8k = 63 % |
| Registers | 16.7k | about 1.5k | 0.2k | about 18k | 90.6k = 65 % |

**Block RAM is over the budget.** The budget was 75 % (255 blocks) with about 30 blocks of FT8 front end still to
come. This branch without the zoom is 241 blocks (71 %) by the same count, with it 284 (83.5 %), and with the FT8
front end about 314 (92 %). No arrangement of the zoom as designed fits: 255 - 30 - 241 leaves no block at all.

Where the 43 are: FFT delay lines and twiddle ROMs 18, half-band delay line 4, mixer table 2, window 2; column
accumulator 5, averaging accumulator 6, two line buffers 4; snapshot 2. What could still come off without a new
design: the FFT's 256-word delay line cut properly (4 to 3), its 128-word twiddle ROM in LUTs (2), the half-band
delay line as two true-dual-port memories with the engine pausing on a write (4 to 2): about 5 blocks. A real cut
needs a different zoom FFT (inputs arrive at most every 15 clocks, so one butterfly and one memory could do the
work of the 12-stage pipeline) or the accumulators in DDR3: its own work package.

**Timing alone** (three stand-alone Gowin runs, place option 3, route option 1, 6.35 ns = 150 MHz + 5 %):

| Run | What | Result |
|---|---|---|
| 1 | zoom receiver + spectrum pipeline + zoom writer | 93.9 MHz, 1,532 end points; every listed path is in the full-band FFT, which in this wrapper shares one merged register with 70 to 374 loads. Says nothing about the zoom; used for sizes |
| 2 | zoom receiver alone | **148.0 MHz**, 12 end points, worst -0.41 ns |
| 3 | the same after putting carry and borrow on the adders' carry inputs | **142.1 MHz**, 33 end points, worst -0.69 ns: the same paths, another placement |

So the zoom receiver alone misses 150 MHz by 0.1 to 0.4 ns and the 5 % margin by 0.4 to 0.7 ns. Every failing
class but one is in `cic_var_pow2`: the registered borrow into the 41-bit high half (8 levels, 2.9 ns of cells,
4 ns of routing at fan-out 1), and the output select from `span_q`. The one other is inside the FFT (-0.10 ns in
run 2). Next step, not done because the run budget is used up: three parts of 27 or 28 bits instead of two halves
(the events are 10 clocks apart, so the clocks are there), and a register between the two levels of the output
select. The zoom context inside the spectrum pipeline has not been timed alone at all (run 1 could not show it).
Classes: `gowin/reports/zoom/run2_classes.md`, `run3_classes.md`.

## 7. Defaults taken that the owner should confirm

1. **Block RAM: the zoom is in, and the chip is at 83.5 %.** Default: built in (`ZOOM = 1`), as asked. `ZOOM = 0`
   gives the 71 % chip back. Decision needed before the FT8 front end is merged: zoom out, FT8 front end smaller,
   or a zoom redesign for memory.
2. **The FT8 screen keeps the software waterfall.** The zoom's narrowest span is 48 kHz: 25 Hz per column. The
   FT8 screen's window is drawn for 0 to 3,000 Hz at 2.56 Hz per column, and an FT8 signal (50 Hz wide) would be
   two columns. With the zoom waterfall the window shows 29.3 kHz of band, the FT8 sub-band 120 columns of it.
   Default: `tr_station::radio::FT8_WATERFALL = Software`; one constant switches it, and
   `Radio::start_display_with(.., Ft8Waterfall::FpgaZoom)` at run time (it falls back to software in a chip
   without the zoom). The zoom receiver is started anyway, centred 1,500 Hz above the dial, 48 kHz, 7 lines per
   second, following every retune, its waterfall going into its own ring for the other window. To make the zoom
   the FT8 waterfall it needs two to four more decimation steps (12 to 3 kHz spans) or a wider FT8 window scale.
3. **The zoom waterfall writer sits on the write arbiter's capture tier**, which is free because raw capture is
   not built. When capture is built it needs a fifth tier or the two waterfall writers behind one.
4. **No interrupt for "zoom line done"**: the status bit is in `backend_line_status`; interrupt lines 12 to 15
   are free.
5. **Memory map**: full-band ring 0x1100_0000, software ring 0x1140_0000, zoom ring 0x1180_0000 (4 MB apart).
6. **Levels**: the zoom's and the full-band spectrum's waterfall level registers are left at their reset values;
   the right values are a board matter.

## 8. Firmware

- `fw/tr-fabric/src/zoom.rs`: `Zoom::present`, `start(centre, span, lines per second, ...)` (stops the DDC, sets
  span, centre and averaging, starts it), `set_centre_hz`, `stop`, `set_level`, `line_count`; `Span` (0 to 6,
  `at_least(hz)`), `column_of(centre, span, f)`.
- `fw/tr-fabric/src/video.rs`: `set_zoom_waterfall_ring`, `show_hardware_waterfall(window, FullBand | Zoom, ring)`.
- `fw/tr-station/src/radio.rs`: `Ft8Waterfall`, `FT8_WATERFALL`, `start_display_with`, `waterfall_shown`,
  `zoom_running`; the board image prints both at start.

## 9. Left

- Timing of `cic_var_pow2` (section 6) and a timed look at the zoom context; then the whole-chip build.
- The owner decisions of section 7, first of all block RAM.
- The alias simulation over the seven spans, once, on an idle machine (hours now).
- On the board: zoom id reads `0x5A4D_0001`; a carrier at the zoom centre lands at column 960 and one above it to
  the right; `wf_zoom_write_line` moves; `underrun_count` stays 0 with a zoom waterfall window.
- `gowin/p1/build.sh` got the seven zoom files in its source list (the timing work package owns that script: a two-line
  addition to merge).

---

# Second pass (branch `zoom2`, 2026-10-12): timing, block RAM, narrow spans

Sections 1 to 9 describe the zoom as it was merged. This pass changed three things; where a number below
differs from sections 3, 6 or 7, the one below holds. **Still nothing has run on a board, and there was no
whole-chip build: every figure is from stand-alone Gowin runs of the zoom (place option 3, route option 1,
6.35 ns) or from simulation.**

## 10. Timing

Four stand-alone runs (the budget). Runs 4, 6 and 7 use a new wrapper, `gowin/wrap/zoom_only.v`: the zoom
receiver and the spectrum pipeline with its full-band input idle, so the report shows the zoom context
(run 1 of section 6 could not).

| Run | What | Fmax | Failing end points | What it showed |
|---|---|---|---|---|
| 4 | receiver + context, after the first `cic_var_pow2` fix | 80.1 MHz | 8,310 | all in the zoom context, never timed before (below) |
| 5 | receiver alone, all block RAM cuts, narrow spans | 108.3 MHz | 72 | the FFT's 512-word delay line as LUT RAM, 2.9 ns short; CIC carries still 0.7 ns short |
| 6 | receiver + context, context reworked | 120.9 MHz | 216 | CIC carries 1.3 ns short although the chain was 21 bits: see below |
| 7 | the same, after the fixes of run 6 | 120.3 MHz | 105 | no CIC path, no FFT path, no memory path fails; 4 classes left in files of this work (fixed after the run, not timed), 26 end points in the shared walk engine and the full-band context |

**What was wrong, and what was done.**

- **`cic_var_pow2` carries.** Halving the adders (section 4), then three parts, then four did not help: the
  node list of run 6 showed 2.4 ns from a LUT into the carry chain's carry input and 3 ns from its carry
  output through a LUT to the register, on general wiring; the chain itself was 1 ns. Written as
  `{a, 1} + {b, c}` Gowin turns the constant bit into a LUT that drives the carry input, and a reset on the
  carry register becomes a LUT behind the carry output. Now the carry between two parts is two registers
  (carry and its inverse), which enter the next part as the two inputs of an adder cell of its own below
  bit 0 and leave it as the two sum bits above the top; no reset on them. Run 7: every `cic_var_pow2`
  class meets 6.35 ns (worst +0.12 ns). Four parts of 20 or 21 bits, output select in two clocks. Same
  values: `tb_cic_var_pow2`, 1,746 words, 0 differ. **Worth applying to `rtl/rx/cic_var_shared.v` and any
  other split adder; it belongs in docs/TANG_LESSONS.md section 6.**
- **Zoom context: the arrival queue was 6,912 flip-flops.** The 128-word queue, read without a register,
  was built as registers behind a 128-way selection; its read pointer drove 1,697 loads (run 4). It is in
  the chip as merged, so the chip's spectrum block carries those registers too. Now LUT RAM in lanes of
  4 bits with kept address copies per lane and a registered read (`rtl/zoom/zoom_lutram.v`): 96 LUT RAM
  cells, 276 registers.
- **Zoom context: the column step** (bin to frequency index, a 12 x 20 multiply, a 3,277-word LUT ROM in
  one clock) is three clocks. The ROM is gone: the first-arriving bin of a column is the even one of two
  neighbours (the FFT delivers bins bit-reversed), so the flag comes from the bin's parity and the
  product's fraction; the bins-per-column table is a running fraction during the walk. Both checked
  against the old tables for every bin and column; `zcol_first.hex` and `zcol_bins.hex` are no longer read.
- Column memory read-modify-write one clock longer (compare in two halves, write word chosen from kept
  flags per 9 bits); colour byte in three clocks; group counter flags as registers; the power word kept
  as a register behind the multipliers.
- `zoom_fir_half`: last-tap flag as a register. `zoom_cic_narrow`: its 60-bit value takes orders from a
  command register in six kept copies.

**Not timed (changed after run 7, the last of the budget):** the four classes run 7 still listed in this
work's files: the power word's saturation (36 end points, -1.7 ns), the narrow CIC's value register (59,
-1.7 ns), the group counter compare (1, -1.6 ns), the line-done flag (1, -0.5 ns). The first three are
changed in the source as described above and pass their simulations; the fourth is register-bus decode and
was left. A fifth stand-alone run would settle them.

**Not in this work's files:**

- `rtl/spectrum/spectrum_ratio_db.v`, shared walk engine: a multiplier output goes through 6 LUT levels to
  `db64_out` in one clock, 6.2 ns of cells, 15 end points, -1.96 ns. It limits the full-band spectrum as
  much as the zoom. Also `shamt0` to its ROM, -0.10 ns.
- `rtl/spectrum/spectrum_pipeline.v`, full-band context: the walk engine's `busy` / `ctx` register drives
  102 to 114 loads into the full-band queue and column memory (-0.4 to -1.1 ns here, with the full-band
  side idle). The module has no `syn_maxfan`.
- `rtl/fft/fft_delay.v` reads its LUT RAM without an address register. At 128 and 256 words the zoom FFT
  meets 6.35 ns (+0.16 ns at 256); at 512 words it was 2.9 ns short. With an address register per lane (as
  `zoom_lutram.v`) the 512-word delay line could leave block RAM too: 3 more blocks.
- `rtl/fft/fft_twmul.v`: the 128-word twiddle ROM in LUTs (2 blocks; today only up to 32 words), and the
  512-word one as one dual-port 1,024 x 18 block instead of a 36-bit one (1 block). `rtl/rx/nco_mixer.v`:
  the same for the 512 x 36 sine table (1 block).

## 11. Block RAM

| | Before | Now | How |
|---|---|---|---|
| Half-band delay line | 4 | 2 | one copy in two true-dual-port 16-bit memories; port B writes in the clock after a sample and the tap counter waits that clock (34 clocks per output at most, 4.41 M per second against 3.84 M needed). Gowin builds it as `DPB16 x 2` |
| FFT 1,024-word delay line | 3 | 2 | the window's output fits 16 bits, so the FFT runs one bit narrower (36 bits = two 18-bit blocks, was 38). Same values; the 17th bit was head-room for a complex sample longer than 2^15, which now saturates in the twiddle multiplier |
| FFT 512-word delay line | 3 | 3 | LUT RAM tried: 2.9 ns short (section 10) |
| FFT 256-word delay line | 4 | 0 | LUT RAM (`FFT_LUT_MAX_W = 256` on the zoom's instance): about 1,700 logic |
| FFT 2,048-word delay line, twiddle ROMs, mixer table, window | 12 | 12 | unchanged |
| **Zoom receiver** | **26** | **19** | |
| Column memory | 5 | 4 | 36 bits instead of 44: at most 2 bins per column, a full-scale ADC tone is 2^33 per bin; saturates above that |
| K-frame memory | 6 | 5 | 45 bits instead of 48, saturating: K up to 2,048 frames of a full-scale tone |
| Line buffer | 4 | 2 | one buffer, not two: the compositor keeps its own copy. A copy taken during a walk can be half the old line and half the new one, for one picture. `backend_line_status.ready_buffer` reads 0 |
| **Zoom context** | **15** | **11** | |
| Compositor snapshot | 2 | 2 | not in this work's files |
| **Zoom in all** | **43** | **32** | |

Logic of the receiver, counted as place-and-route does: 14.6k to 17.5k (LUT RAM for the FFT delay line,
the narrow CIC, the four-part adders); registers 16.7k to 17.6k. The zoom context lost about 6,600
registers (the queue). DSP unchanged (30 + 3).

**Looked at and not done:** the two accumulators as floating-point words (18 and 27 bits: 6 more blocks).
The words must be expanded on the way into the shared walk engine, which takes its read data one clock
after the address; that needs one more clock of read latency in `spectrum_walk_core.v`, a shared file. A
2,048-point FFT (4 blocks) halves the bins to 1,638 for 1,920 columns: not done, it costs resolution.

## 12. Narrow spans: 24, 12, 6 and 3 kHz

- **How.** `cic_var_pow2` stays at its largest decimation (64, 120 ksps) and a third CIC follows it,
  `rtl/zoom/zoom_cic_narrow.v`: 11 stages, decimation 2 to 16. Its input samples are 640 clocks apart, so
  it works one add at a time with one adder and its state in LUT RAM: about 450 LUT, no block RAM, no
  multiplier. Then the same half-band filter and droop filter (eleven coefficient sets now).
  Register: `ctrl.narrow_shift` 1 to 4 with `span_shift` = 6; block id version 2.
- **Gain (`ctrl.narrow_gain`, 0 to 3 = 0, 12, 24, 36 dB, saturating; firmware default 24 dB).** The
  samples between the stages are 16-bit words scaled for the ADC's full scale and the spectrum squares
  21-bit words. In a 6 kHz span the ADC's own noise is about a quarter of one step of those 16-bit words
  and a weak FT8 signal less than one step of the 21-bit words, so without gain the bottom of the
  waterfall would be rounding, not band noise. **The same holds, less severely, at the existing 48 kHz
  span and was not changed there.** The firmware takes the gain off again in the level register.
- **Flatness and aliases** (`sim/zoom/zoom_narrow_chain_sim.v`, the narrow stage with both filters, fed at
  120 ksps): flat within 0.002 dB over the displayed band at all four spans; a full-scale tone at the
  chain's worst alias frequency leaves a line 106 dB or more under full scale (the analysis says 117 dB,
  as for the other spans). The largest single output word in that test is 2 steps, 78 dB under full
  scale: rounding noise of the three 16-bit words in the chain, there with or without the tone. The
  first version's test measured exactly that largest word (83.2 dB at the old spans is 1 step), so by
  that measure the narrow spans read 78 dB; the alias itself is far below both. Through the whole DDC
  (`sim/zoom/zoom_alias_sim.v`, now eleven spans, both figures): section 13.
- **Line rate and latency.** A line needs one whole 4,096-point transform; transforms do not overlap.

  | Span | Samples per second into the FFT | Bin | Lines per second, at most | A line shows the last |
  |---|---|---|---|---|
  | 48 kHz | 60,000 | 14.6 Hz | 14.6 | 0.07 s |
  | 24 kHz | 30,000 | 7.3 Hz | 7.3 | 0.14 s |
  | 12 kHz | 15,000 | 3.7 Hz | 3.7 | 0.27 s |
  | 6 kHz | 7,500 | 1.83 Hz | 1.83 | 0.55 s |
  | 3 kHz | 3,750 | 0.92 Hz | 0.92 | 1.09 s |

  The software waterfall draws 6.25 lines a second from 0.17 s of audio each. Overlapping transforms
  (half: 3.7 lines a second at 6 kHz) need the last 2,048 samples kept: 4 block RAMs. Not built.
- **FT8 column scale (`ctrl.backend_ft8_columns`).** The usual scale puts the 3,277 displayed bins on
  1,920 columns: 3.125 Hz per column at 6 kHz, not the FT8 screen's 2.56. With this bit the zoom context
  puts 0.71533 columns on a bin, counted from the low edge of the span: 2.5597 Hz per column at the 6 kHz
  span, 1,172 columns = 3,000 Hz; bins beyond column 1,919 (4.9 kHz) are dropped. It costs a second
  constant, since the column tables are computed (section 10). `tb_zoom_backend_quick -DZOOM_FT8_COLS`: PASS.
- **Firmware.** `tr_fabric::zoom`: `Span` 0 to 10 (`Span::K48`, `Span::FT8` = 6 kHz, `NARROWEST` = 3 kHz),
  `Setup` / `start_with` (narrow gain, FT8 columns), `ft8_column_of`, `narrow_gain_db64`. A chip with
  the first version of the block (id version 1) counts as having no zoom.
  `tr_station::radio`: **`FT8_WATERFALL = FpgaZoom`**. `start_display_with` starts the zoom at the 6 kHz
  span, FT8 column scale, centre 2,999 Hz above the dial, every transform a line, and shows its ring in
  window 0 from source column 0, if the chip has the zoom and the window is 3,000 Hz wide at 2.56 Hz per
  column within 1 % (1,161 to 1,183 columns; the FT8 screen's is 1,172). Otherwise the software waterfall
  as before, the zoom at 48 kHz for the other window. Under QEMU and in a chip without the zoom nothing
  changes.
- **What the FT8 screen shows with it:** the same 0 to 3,000 Hz scale, finer in frequency (1.8 Hz bins
  against 5.9 Hz) and slower in time (a line every 0.55 s against 0.16 s: an FT8 symbol is 0.16 s, so
  single tones smear into the signal's 50 Hz band). The colours come from the level register, not from
  the software waterfall's running noise estimate: the right offset is a board matter (section 7.6).

## 13. Verified in this pass, and left

| Test | Result |
|---|---|
| `tb_cic_var_pow2` (final form) | 1,746 words, 0 differ |
| `zoom_rb1_compare_sim` at the chip's FFT parameters (16-bit window output, LUT RAM delay lines up to 512 words) | 0 of 4,096 words differ |
| `zoom_rb1_burst_sim` (after the half-band and four-part CIC changes) | 0 of 4,096 words differ, 28 bursts |
| `tb_zoom_backend_quick`, both column scales | PASS, worst 0.011 dB |
| `tb_zoom_cic_narrow` (new) | 1,016 words against a model, 0 differ; DC gain 1; pass-through |
| `zoom_narrow_chain_sim` (new) | PASS (section 12) |
| `cargo test -p tr-fabric`, the radio display test in `tr-station`, target build of `tr-app` | pass |
| `zoom_alias_sim`, eleven spans through the whole DDC | the line at the landing frequency is 111 to 129 dB under the reference at every span (narrow spans: 119 to 129 dB). The largest output word, the first version's measure: 2 steps = 82.8 dB at spans 1 to 9, none at 3 kHz, 3 steps = 79.3 dB at the widest span (the known shortfall there: section 3 has 79.6 dB; that chain is word for word the first version's). The simulation ends with FAIL for that one span, as the first version's criterion says. Output: `sim/zoom/zoom_alias_result_2026-10-12.txt` |

Not run again after the last source changes (carry pairs in `cic_var_pow2`; command register in
`zoom_cic_narrow`): the two 75-minute word-for-word tests. Each change has its own unit test above.
Not run: `tb_zoom_quick`, `zoom_bin48_sim`, `zoom_backend_full_sim` (compiled only), the whole-chip build.

Left:

- A fifth stand-alone run for the four classes of section 10, then the whole-chip build. The shared walk
  engine (`spectrum_ratio_db.v`) has to be fixed first or it caps the chip at about 120 MHz.
- `gowin/p1/build.sh` needs no new file in its list: `zoom_cic_narrow.v` and `zoom_lutram.v` are included
  by `zoom_ddc.v` and `spectrum_pipeline.v`.
- Owner: is a waterfall line every 0.55 s good enough for the FT8 screen? If not: 4 block RAMs for
  half-overlapped transforms (3.7 lines a second), or the software waterfall stays the default.
- On the board, in addition to section 9: zoom id reads `0x5A4D_0002`; with the FT8 screen a carrier
  1,500 Hz above the dial sits at window column 586; the level offset for the zoom waterfall.

## 14. Registers (the chip's binding resource since the merged chip failed placement)

Counted from the synthesis netlists (`tools/gowin_mems.py`): "before" is the chip synthesis of section 6,
"now" is stand-alone run 7 (the few changes after it add about 40 registers).

| | Registers before | now | LUT + adders before | now | LUT RAM cells before | now |
|---|---|---|---|---|---|---|
| Zoom receiver | 16,770 | 17,740 | 11,490 | 12,730 | 528 | 808 |
| Zoom context in the spectrum pipeline | about 7,300 | about 1,100 | about 2,000 | about 1,450 | about 0 | about 110 |
| **Zoom in all** | **about 24,100** | **about 18,800** | 13,500 | 14,200 | 530 | 920 |

The context's 6,900-register arrival queue is gone (section 10). The receiver grew by 970: the narrow
CIC 540, the carry registers and enable copies of the four-part adders about 430. No block RAM was
turned into registers: what left block RAM went into LUT RAM (FFT delay line, queue) or disappeared.

Where the receiver's 17,740 are: variable CIC 8,250 (two channels of 11 stages x 82 bits x 3 registers,
plus 1,500 enable and reset copies), fixed CIC 3,570, FFT 4,020, narrow CIC 540, the two filters 660,
mixer 290, window and bus 270.

**What a zoom of about 10,000 registers would take** (estimates, nothing built or timed):

1. **No feature lost, 18,800 to about 13,500:** the variable CIC keeps only its first decimation by 2 (27
   bits wide instead of 82: 2,700 registers instead of 8,250) and everything beyond goes to the
   one-add-at-a-time CIC of section 12, with its state in LUT RAM (about 250 LUT RAM cells and 600
   registers for both channels; it has to do one add per clock then, samples being 20 clocks apart).
   Same spans, same filters behind it. Cost: a new stage to design and time, the alias simulation again.
2. **Giving up the 3.072 MHz span, to about 12,000:** with the variable stage always decimating, the fixed
   CIC in front needs 5 stages instead of 9 for 80 dB (3,570 to about 2,000). `rtl/rx` file.
3. **To 10,000** the FFT has to give as well (4,020; `rtl/fft`): a 2,048-point transform saves only a few
   hundred, a sequential FFT (one butterfly, block RAM for the data, about 6 more blocks) about 3,000,
   at the price of block RAM again. So 10,000 means steps 1 and 2 and a different FFT, or step 1 and a
   zoom that is not built into every bitstream.

## 15. After merging master (block RAM round 2, whole-chip timing)

Merged into `zoom2` after the last stand-alone run; not built or timed since. The zoom FFT takes master's
`TW_LUT_MAX = 128` (its 128-word twiddle ROM in LUTs: 2 blocks less, so 30 for the zoom by this count,
less what master's shared sine table saves in the mixer). `rtl/fft/fft_delay.v` now keeps its read
addresses in registers, which is what the 512-word LUT RAM delay line was missing (section 10): worth
one stand-alone run with `FFT_LUT_MAX_W = 512` (3 more blocks, no registers). Master's note that the zoom
context's queue is an unregistered 128 x 54 LUT RAM read is the queue of section 10: registered here.

## 16. Register budget of 18,500 (receiver + zoom context), and the variable CIC

- **The queue fix alone** is branch `zoom2-fifob` (one commit on master 7c91dea: `zoom_lutram.v` and the
  queue in `spectrum_pipeline.v`, 54 bits wide there): 6,800 flip-flops become about 110 LUT RAM cells
  and 320 registers. `zoom2` has the same queue, 48 bits wide.
- **Where `zoom2` stands, by count, not by a build:** receiver 17,780 in run 7, less what master's
  `rx_fan` saves (kept reset copies were built twice; the zoom's variable CIC has about 800 of them, so
  about 400 to 700), plus about 1,100 for the context: **about 18,200 to 18,500**. That is at the limit.
  A synthesis count of the merged branch is needed to know; the run budget of this work is used up.
- **The variable CIC's state in LUT RAM is not a straight reuse** of `rtl/rx/cic_var_shared.v`. There
  eight contexts share one engine and the LUT RAM is eight words deep; the zoom has two contexts (I, Q),
  so "one word per context" saves nothing. What can be shared in the zoom is the eleven stages: one
  engine per channel that walks the stages, state in LUT RAM by stage. Two things make it a design of its
  own: (1) samples come 10 clocks apart and there are 11 integrators, so the engine must do two stages a
  clock (even and odd stages in two memories, walked from the top stage down so each reads the old value
  of the stage below, as today); (2) the words are 82 bits, so each add still takes its four clocks, as a
  pipeline. At the widest span the combs would not fit in the same 10 clocks, but there the stage is a
  pure delay of 22 samples and can be a 22-word delay line. Estimated: 8,250 registers become about
  1,300 and 200 LUT RAM cells, the zoom about 11,500 in all; `tb_cic_var_pow2` is the test (every
  decimation, word for word). Not done: it needs a stand-alone run, and it is the same work as step 1
  of section 14 (which gets there with less new logic: keep the first decimation by 2 in registers at 27
  bits, give the rest to the one-add-at-a-time stage).
