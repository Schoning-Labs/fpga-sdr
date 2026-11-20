<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# Does the main logic clock have to be 150 MHz?

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Study of 2026-10-12 on master 7c91dea. Read-only: figures come from the RTL headers and the design documents named
in each row, and from arithmetic on them. Nothing was simulated or built for this study. "Not measured" marks what
that leaves open (section 7).

**Decided 2026-10-12: 120 MHz** (docs/DECISIONS.md). Done on branch `clk120`. Two things the list in section 5 missed: `gowin/ladder/ladder.sdc` carries its own `clk_dsp` constraint, and the half-band's two lanes need four block RAMs, not two.

## 1. Answer

**No. Nothing in the chip needs 150 MHz.** As built, two blocks set the floor:

| Floor | Block | Why |
|---|---|---|
| **122.9 MHz** | zoom receiver, half-band filter (`rtl/zoom/zoom_fir_half.v`), **widest span only** (3.072 MHz) | one output costs 32 clocks, 3.84 M outputs per second of HL2 time: 122.88 M clocks/s. 82 % busy at 150, 98 % at 125, over 100 % at 120. Every other span needs at most half of that |
| **99.8 MHz** | receiver back end, channel filter unit (`rtl/rx_backend/bk_chfilt.v`), 8 receivers with 1,024 taps | one unit serves 4 receivers: 4 x 24,000 x 1,040 = 99.84 M clocks/s |
| about 95 MHz | compositor line fetch (`rtl/video/compositor_fetch.v`), two full-screen waterfalls | 960 lane words per 14.8 us line take about 1,400 clocks (upper bound if the lane is limited by our clock, not by the memory) |
| 77.1 MHz | HL2 link (`rtl/hl2link`) | one sample per clock, 76.8 Msps; a frame must be drained before the next is committed |

**Recommended: 120 MHz, with one RTL change in the zoom half-band** (a second multiplier per channel, 2 DSP blocks, or
dropping the 3.072 MHz span). Period 8.33 ns instead of 6.67 ns: 1.67 ns more on every path. The chip measured
126 to 135 MHz before the last blocks went in, so 120 leaves 5 to 12 % against that measurement.
**Without touching the zoom: 133.3 MHz** (7.5 ns), which is inside the measured range, not below it.

## 2. What the PLL can make

Limits (GW5AST data sheet DS1239 table 3-18 and clock guide UG306, as quoted in `docs/AUDIO_OUT.md` section 1; the
PDFs were not opened again): phase detector 19 to 81.25 MHz, VCO 650 to 1,300 MHz, only output 0 has a fractional
divider (eighths). The audio clock needs an exact 48 MHz feed (49.152 MHz = 48 x 128 / 125). 1,200 MHz is the only
VCO frequency that gives 48 MHz from a whole-number divider.

| clk_dsp | How | Audio feed | Clocks per 48 kHz sample | Clocks per microsecond |
|---|---|---|---|---|
| 150 | VCO 1,200 / 8 (now) | 48 MHz = / 25, unchanged | 3,125 | 150 |
| 133.33 | VCO 1,200 / 9 | unchanged | 2,777.78 | 133.33 |
| 126.3, 124.7, 123.1 | VCO 1,200 / 9.5, 9.625, 9.75 (fractional divider on the main clock) | unchanged | not whole | not whole |
| 125 | not from VCO 1,200 (9.6 is not an eighth). VCO 750: output 1 = / 6, output 0 = / 15.625 = 48 MHz | 48 MHz from the fractional output; both outputs swap; its jitter into the audio PLL is not measured | 2,604.17 | 125 |
| **120** | **VCO 1,200 / 10: one number in `gowin/p1/ip/gowin_pll_dsp.mod`** | **unchanged** | **2,500** | **120** |
| 100 | VCO 1,200 / 12 | unchanged | 2,083.33 | 100 |

120 MHz is the only lower frequency where the PLL change is one divider, the audio path is untouched and both
derived constants stay whole numbers.

## 3. Block by block

"Burst" = while an HL2 frame is being delivered: 5,968 samples on consecutive clocks. Budgets counted in valid
samples do not depend on the clock at all; they are marked "sample-counted".

| Block | Budget as built | 150 | 125 | 120 | 100 | Breaks below |
|---|---|---|---|---|---|---|
| HL2 link receive: clocks carrying a sample | 76.8 Msps, one per clock (`gap_filler.v`); sample FIFO 1,024, frame ring 8,192, input queue 4 | 51 % | 61 % | 64 % | 77 % | 77.1 MHz |
| HL2 link: time to drain one frame (period 77.7 us) | 5,968 clocks | 39.8 us | 47.7 us | 49.7 us | 59.7 us | 77.1 MHz |
| HL2 link: time to catch up after one lost frame (zero fill) | 5,968 / (clock - 76.8 M) | 82 us | 124 us | 138 us | 257 us | grows without limit near 77 MHz |
| Receiver bank: mixer and fixed CIC | one sample per clock, sample-counted | 51 % | 61 % | 64 % | 77 % | 76.8 MHz |
| Receiver bank: shared variable CIC, 8 contexts per engine | 8 clocks of work per 10 samples, sample-counted: 80 % in a burst at any clock | 41 % avg | 49 % | 51 % | 61 % | 76.8 MHz |
| Receiver bank: FIR decimator at 384 ksps | 137 clocks (2 x 65 + 7) per 200 samples, sample-counted: 69 % in a burst at any clock | 35 % avg | 42 % | 44 % | 53 % | 76.8 MHz |
| Back end: channel filter unit, 4 receivers x 1,024 taps | 99.84 M clocks/s; 8-entry FIFO in front (R4_BACKEND: 64 % measured at 150) | 67 % | 80 % | 83 % | 99.8 % | **99.8 MHz** (105 with 5 % spare) |
| Back end: half-band decimator, 8 x 384 ksps | 47 M clocks/s (27 % measured) | 31 % | 38 % | 39 % | 47 % | 47 MHz |
| Back end: demodulator and AGC | under 45 M clocks/s (6 % measured in the SSB run) | 30 % | 36 % | 38 % | 45 % | 45 MHz |
| Full-band spectrum: FFT | streaming, sample-counted | 51 % | 61 % | 64 % | 77 % | 76.8 MHz |
| Spectrum walk (full band + zoom) | 5,437 frames/s x 1,930 clocks = 10.5 M clocks/s | 7 % | 8 % | 9 % | 10 % | far below |
| **Zoom half-band, widest span** | 32 clocks per output, 3.84 M outputs/s; buffer for 449 samples of backlog | 82 % | 98 % | **102 %** | 123 % | **122.9 MHz** |
| Zoom half-band, second-widest span | 61.4 M clocks/s | 41 % | 49 % | 51 % | 61 % | 61.4 MHz |
| Zoom droop filter, widest span | 15 clocks per sample, 57.6 M clocks/s | 38 % | 46 % | 48 % | 58 % | 57.6 MHz |
| FT8 spectrogram, 8 receivers | 36,103 clocks per frame, 25 frames/s each: 7.2 M clocks/s | 4.8 % | 5.8 % | 6.0 % | 7.2 % | far below |
| FT8 sync search, per receiver (own limit 60 ms) | 7.06 M clocks | 47 ms | at least 56 ms | at least 59 ms | at least 71 ms | 118 MHz for the 60 ms limit |
| FT8 candidates, all 8 receivers, 480 candidates (own limit 400 ms) | 55.2 M clocks | 368 ms | at least 442 ms | at least 460 ms | at least 552 ms | 138 MHz for the 400 ms limit |
| FT8 total after the slot ends, 8 receivers | sync x 8 + candidates | 0.74 s | at least 0.89 s | at least 0.93 s | at least 1.11 s | a limit we set ourselves |
| TX chain | one output per received sample, sample-counted; FIR pass 22 clocks per 400 samples | 51 % | 61 % | 64 % | 77 % | 76.8 MHz |
| TX rate lock | one correction per 256 clocks; the link carries about 700 ksps spare | 586 ksps | 488 | 469 | 391 | none (start-up takes 20 / 25 / 26 / 31 ms) |
| Audio engine | interpolator about 23 clocks per 384 kHz frame | of 390 | of 325 | of 312 | of 260 | a few MHz |
| Audio outputs (S/PDIF, I2S) | on the 49.152 MHz audio clock, not on clk_dsp | same | same | same | same | PLL only (section 2) |
| Compositor line fetch, worst case (two full-screen waterfalls) | 960 lane words in one 14.8 us line; about 1,400 clocks at 150 | 2,218 clocks, 63 % | 1,849, at most 76 % | 1,775, at most 79 % | 1,479, at most 95 % | about 95 MHz |
| DDR3 read lane | 846 MB/s reached at 150; 374 needed normally, 519 worst case | 846 | at least 705 | at least 677 | at least 564 | about 92 MHz for the worst case |
| DDR3 write lane with relay, read lane flat out | 41.8 MB/s reached; 26.4 needed (24.6 of it is 8 receivers at 384 ksps) | 41.8 | at least 34.8 | at least 33.4 | at least 27.9 | about 95 MHz |
| Register bus | toggle handshake from the AHB bus (80 MHz since 2026-10-13, 100 MHz when this study was written), time-out 4,096 bus clocks; read data 3 clocks | fine | fine | fine | fine | none |

"At least" and "at most" rows: the DDR3 memory core runs on its own 100 MHz clock, which does not change. Only the
part of each transfer spent in our clock domain scales. The figures given assume all of it scales (worst case).
The FT8 times are different: they are lane-bound, and video takes a larger share of the lane's clocks at a lower
clock, so they can grow by more than the ratio. Not measured.

## 4. With 4 or 6 receivers

| | 8 receivers | 6 (3 per filter unit) | 4 (2 per filter unit) |
|---|---|---|---|
| Channel filter floor | 99.8 MHz | 74.9 MHz | 49.9 MHz |
| Filter unit busy at 120 / 100 MHz | 83 % / 99.8 % | 62 % / 75 % | 42 % / 50 % |
| FT8 after the slot at 120 MHz | 0.93 s | 0.70 s | 0.47 s |
| Write lane need | 26.4 MB/s | 20.3 | 14.1 |

Fewer receivers do not lower the clock by themselves: the zoom floor (122.9 MHz) does not depend on the receiver
count. With the zoom fix, 6 or 4 receivers move the floor from the filter unit (100 MHz) to the video line fetch and
the HL2 link, both near 95 MHz in the worst case. So the gain is 120 to 100 MHz at most, and 100 MHz then leaves
5 % on the worst-case screen and takes 257 us to recover from a lost frame. Not recommended.

## 5. What must change for 120 MHz

| What | Where | Places |
|---|---|---|
| PLL output divider 8 to 10; regenerate the IP | `gowin/p1/ip/gowin_pll_dsp.mod` | 1 |
| Clock constraint: x 3 becomes x 12 / 5; default period of the stand-alone runs | `gowin/p1/sdr.sdc`, `gowin/res.sh` (and check `gowin/p1/sdc_margin.py`) | 2 |
| "Two clocks" written as 13.0 ns (Gowin ignores multicycle on a PLL clock) becomes 16.3 ns | `rtl/rx_backend/rx_backend.sdc` | 1 file |
| Audio engine clock parameter 150,000,000 | `rtl/top/sdr_core.v` line 613 | 1 |
| Filler period of the 48 kHz output stream, 3,125 clocks becomes 2,500 | `rtl/audio/audio_out_src.v` (make it a parameter set next to the one above) | 1 |
| Parameter defaults that say 150 MHz (overridden or unused in the chip; keep them true) | `audio_engine.v`, `audio_nco_tick.v`, `audio_pt8211_tx.v`, `audio_spdif_tx.v` | 4 |
| **Zoom half-band: two multipliers per channel (16 clocks per output, 51 % busy), or drop the 3.072 MHz span** | `rtl/zoom/zoom_fir_half.v` (another work package was changing `rtl/zoom` at the time) | the one real RTL change |
| Firmware clock: cycles per second of the chip's cycle counter | `fw/tr-fabric/src/system.rs` (`CycleClock::HZ` and its test), `fw/tr-station/src/selftest.rs` | 3 |
| Register descriptions "150 MHz clocks", then regenerate | `hw/regmap/system.toml`, `hw/regmap/ft8.toml` (2 entries) | 3 |
| Ladder test design only | `rtl/top/ladder_pt8211.v` (fixed increment), `fw/tr-ladder/src/main.rs` (`HZ_DSP`) | 2 |
| Comments and documents that say 150 MHz | about 40 RTL comment lines, the design documents | text only |

Not affected: the TX rate lock (its 256-clock spacing only gets safer), the PHY reset sequence (runs on the 125 MHz
transmit clock), the UART and the CPU timer (CPU side, bus clock: 100 MHz then, 80 MHz since 2026-10-13), the compositor's 3,000-clock time-outs, every
sample-counted block, the audio PLL and the audio pins, the pixel clock.

For 133.3 MHz instead: the same list without the zoom row; the 48 kHz filler period (2,777.78) and the cycles per
microsecond are then not whole numbers, so the filler needs a fractional counter.

## 6. Risks

- **A lower clock does not close timing by itself.** 126 to 135 MHz was measured before the last blocks went in and
  with the chip under 90 % full. The 120 MHz result needs one whole-chip run.
- **Zoom at the widest span after a lost frame.** Catch-up delivers samples on every clock for 82 us at 150 MHz and
  138 us at 120. By this study's arithmetic the half-band's backlog buffer (449 samples) is already at its edge at
  150 MHz (about 459 samples). With two multipliers the filter keeps up at any clock above 77 MHz and the buffer is
  no longer needed for this.
- **FT8 results arrive later**: at least 0.93 s after the slot instead of 0.74 s with 8 receivers. The 400 ms
  candidate limit we set ourselves is missed (460 ms). The second FT8 pass on branch `pass2` adds to this and was
  not looked at.
- **Back-end filter unit at 83 %** with all 8 receivers on 1,024 taps. Service time is fixed and jobs arrive evenly,
  so it holds on paper; the 8 x 384 ksps real-time simulation should be repeated at the new ratio.
- **Headphone DAC bit clock** is made by a fractional tick on clk_dsp: edge jitter goes from 6.7 to 8.3 ns.
- **The zoom is being rebuilt** (branches `zoom2`, `zoom2-fifob`: a serial CIC behind the variable one, spans down
  to 3 kHz). This study read master only.

## 7. Not established without a measurement

1. Whole-chip Fmax at a 120 MHz constraint (one Gowin run).
2. How much of the DDR3 lane rates is bound by our clock: read lane, write lane, the compositor's 1,400 clocks per
   line, and with them the FT8 sync and candidate times (the existing lane, compositor and FT8 test benches, run
   with a 120 MHz logic clock against the 100 MHz memory clock).
3. Back-end worst case (8 x 384 ksps, 1,024 taps, real time) at 120 MHz: FIFO peaks.
4. Zoom half-band backlog at 150 and 120 MHz with a lost frame.
5. For the 125 MHz variant only: the audio clock's jitter with its 48 MHz feed taken from a fractional divider.
