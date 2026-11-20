<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# THIN: cells out of the densely placed blocks

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Written 2026-10-13, branch `thin`. Follows docs/ROUTE_DIAG.md (unrouted nets come from local density). Gowin
V1.9.11.03, whole chip without the zoom (`TR_NO_ZOOM=1`), clk_dsp 120 MHz.

## Result

| Whole chip, no zoom | master 14c762c | this branch |
|---|---|---|
| LUT / adder cells / LUT-RAM cells / registers (synthesis) | 51,268 / 20,085 / 2,399 / 79,908 | 47,862 / 18,941 / 2,474 / 71,130 |
| Flip-flops fed by another flip-flop | 30,517 | 24,990 |
| Block RAM primitives / DSP | 218 / 124 | 217 / 118 |
| Cells placed | 159,577 | 145,356 |
| Input pins per 8 x 8 block: median / max | 1,879 / 2,797 | 1,759 / 2,723 |
| Blocks over 2,400 pins | 31 of 275 | **10 of 276** |
| Routes | no, 185 nets | **not known**: the run was stopped after placement, as the task description says for blocks over 2,400 |

About 13,300 cells are out (14,200 placed cells). The build that routed had 129,000 placed cells and no block
over 2,400: another 10,000 to 16,000 cells are still to go. The 10 dense blocks have 157 adder cells per block
against 69 on average (tools/gowin_place.py); the file has no names, so which units they are was not established.

## The cuts (LUT / adders / LUT RAM / registers, synthesis, before -> after)

| Block | Before | After | What |
|---|---|---|---|
| FT8 front end | 12,492 / 5,381 / 668 / 19,412 | 9,995 / 4,237 / 713 / 12,330 | all of the below |
| - candidate engine | 4,596 / 2,308 / 306 / 6,006 | 2,738 / 1,295 / 230 / 3,167 | one lane built (`ft8_cand` LANES = 1), run twice for a two-lane command; lane payload delay in LUT RAM. 6 DSP, 1 block RAM less |
| - spectrogram | 3,809 / 1,899 / 129 / 7,259 | 3,485 / 1,903 / 193 / 4,529 | FFT delay lines of 4 to 32 words in LUT RAM (FFT 4,305 -> 2,049 registers); combine's sample delay in LUT RAM; twiddle multiplier one clock shorter |
| - sync search | 2,401 / 1,174 / 225 / 3,843 | 2,001 / 1,039 / 226 / 3,007 | score divider with one pair instead of four (1,042 -> 391 registers) |
| - front end top | | | the three ring bases per receiver in LUT RAM (`ft8_cfg8`), read by each engine at its own receiver |
| Back end | 12,684 / 2,925 / 474 / 12,606 | 11,760 / 2,925 / 494 / 11,755 | input stage: sample delay of 10 clocks in LUT RAM (1,746 -> 1,323 registers); decimator: stage state in one 32-word LUT RAM (1,507 / 1,039 -> 567 / 606) |
| Full-band FFT | 4,353 / 1,843 / 376 / 4,708 | 4,381 / 1,843 / 376 / 4,224 | twiddle multiplier's octant mapping in one clock |
| Compositor | 2,579 / 1,377 / 177 / 6,161 | 2,618 / 1,377 / 187 / 5,801 | the 25-clock Slint pixel and key delays in LUT RAM |
| Receiver bank | 5,065 / 5,244 / 302 / 16,118 | unchanged | see "not done" |

Delays are `ft8_dly` (rtl/ft8/ft8_dly.v; `bk_dly`, `comp_dlyram` are the same module): a LUT RAM with two
pointers and an output register, written with `syn_ramstyle` in the comment form. It pays from about 5 clocks on
(place-and-route counts a LUT-RAM cell as 6 logic cells per 4 bits); 3-clock chains were left alone.

## Latency and time

- Twiddle multiplier: 7 clocks instead of 8 (`fft_twmul` M1_ONE = 1; the full-band FFT is 6 clocks shorter, the
  FT8 FFT 3). The zoom FFT is unchanged (parameter default 0; the zoom block's owner can set `TW_M1_ONE`).
- Candidate engine: results and registers unchanged, no firmware change. A pass 1 with its pass 2 for two
  candidates is 449,603 clocks instead of 229,729 (tb_ft8_cand): 480 candidates take 107.9 M clocks, **0.90 s at
  120 MHz** (two lanes: 0.46 s at 120, 0.37 s at 150). The engine's own 0.4 s limit (docs/F7_CAND.md,
  tools/check_ft8_cand.sh) no longer holds. Against the slot: 1.9 ms of chip time per candidate is below the CPU's
  own 4 to 5 ms per candidate (124 to 174 M instructions per 60), the operator's 60 candidates take 0.11 s
  instead of 0.06 s, so the first decodes move from about 0.40 to about 0.45 s after the slot end and the
  instruction budget of docs/FT8_CPU.md (3,150 M per slot) is not touched.
- Sync search: the divider now sets the pace of a lag (4,096 clocks against about 3,600): at least 7.8 M clocks
  per receiver against 6.92 M measured, **about 65 to 70 ms at 120 MHz** (58 ms before; the own limit was 60).
  Not measured: the recordings are not on this PC (`DIV_PAIRS = 2` halves the saving and should cost no time).
- Everything else: same clocks as before.

## Checks

tb_ft8_tw3840, tb_ft8_frame_core, tb_ft8_spectrogram, tb_ft8_sync, tb_ft8_cand (also `-DTB_LANES=1`),
tb_ft8_frontend, spectrogram and sync again with `-DTB_CFG_EXT` (bases the new way), tb_fft_r22sdf `-DTB_THIN`,
tb_rx_backend, tb_rx_backend_ring, tb_compositor, tb_sdr_core: all PASS, bit-exact. **Not run:**
tools/check_ft8_pass2.sh (it skips: captures/ft8/*.wav are not fetched here).

Stand-alone at 7.92 ns, place 3 / route 1: FT8 front end 122.4 MHz, 3 failing end points (register read-back,
`a1 -> glob`), logic 19,200, registers 12,452 (before, at 6.35 ns: 105.9 MHz, 338 failing, 23,502 / 20,539).
Back end 94.6 MHz, 40 failing end points: the post stage's receiver number on 91 loads (a fan-out limit was added
after this run, not re-measured) and the ring queue's write pointer into its LUT RAM; neither is a path of this
work. Logic 17,483, registers 11,684.

## Not done, and what else could come out

| What | Cells | Cost |
|---|---|---|
| Compositor: the pixel-clock copy of the picture description (`comp_xfer`) | 1,360 registers | the pixel side would read the clk_dsp registers directly; needs proof that nothing reads them during the 270-clock sweep |
| Back end: first-sample stamp and output count per receiver into LUT RAM | 640 registers, 640 adders, about 600 LUT | a two-entry queue for the write port (docs/FIT.md section 5) |
| Back end ring writer: sequence counters, slot masks; post stage: level and gain per receiver | about 650 registers and their selects | ports change from 8 values to one |
| FT8 sync: stream pipeline registers | about 800 | timing work in the engine that sets the front end's Fmax |
| FT8 spectrogram and capture: per-receiver frame counters and pointers | about 700 | they are compared for all 8 receivers at once today |
| Receiver bank | not touched | its flip-flop-fed registers are CIC state at full rate and fan-out copies; the 4-stage mixer delay as a shift register was the 106.8 MHz run of WP LS3 |
| Outside this work's blocks: audio interpolator delay lines 576, transmit settings crossing 356 | about 900 | small |
| Pipeline stages made for 150 MHz in back end post stage, FT8 sync | registers that sit behind their own LUT: they free few slices | state machine edits |
