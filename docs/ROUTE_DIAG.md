<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# ROUTE_DIAG: why about 600 nets of the full chip do not route

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Written 2026-10-13, branch `route`. Gowin EDA V1.9.11.03, GW5AST-LV138FPG676AC1/I0. All full-chip builds without the
zoom receiver (`TR_NO_ZOOM=1`). Two full-chip runs made here (section 4), three small ones (section 5).

## 1. In short

- **Which nets are unrouted is not known and the tool does not say.** No report, log or option of V1.9.11.03 names
  them (SUG100 8.3, SUG937 and SUG940 searched; a second design's builds on the same tool found the same). When routing
  fails, no timing report is written, so `report_route_congestion` gives nothing either.
- **The cause is local density of the placement, not a scarce special resource.** The placement file can be read
  (section 2). Counted in input pins per block of 8 x 8 grid cells, the build that routes has no block above 2,400;
  every build that fails has 15 to 94 such blocks. The dense blocks hold adder datapaths with their registers
  (FT8 candidate search, FT8 spectrogram and sync, the FFT, the back end's post, decimator and ring).
- **The count of unrouted nets is a property of the placement.** The same placement routed twice, once with the
  router's timing optimisation off, left exactly 185 nets both times.
- **Ruled out:** clocks off the global lines, LUT RAM, the timing-driven switch, place and route options as a cure.
- **The fix is fewer cells in the dense units, about 15,000 cells in total** (section 6). No constraint, attribute
  or build option was found that makes this design route; nothing was changed in the build.
- **Slices (CLS) at 90 % with 60 % of the cells is the placer spreading, not a need** (section 7).

## 2. The placement can be read: `tools/gowin_place.py`

`impl/pnr/<top>.db` is written after placement and before routing, so it exists for a failed build. It is a plain
binary table: per cell a type code, row, column and position in the grid cell (format in the tool's header). It has
no names. Names were attached for this study by lining up the file's cell order with the netlist's instance order
(equal runs of cell types); that names about 80 % of the cells and is right at the level of a unit (checked: a LUT
and the flip-flop it feeds land in the same grid cell for 92 to 99 % of the pairs in most units), less sure inside
units with much LUT RAM. That script is not committed (scratch quality); the tool without names is.

## 3. Evidence

| Build | Design | Options (place, route) | clk_dsp | Cells placed | Input pins per 8 x 8 block: median / max | Blocks over 2,400 | Unrouted nets |
|---|---|---|---|---|---|---|---|
| `impl/ls2` | before FT8 and compositor | 3, 1 | 150 | 128,875 | 1,446 / 2,378 | 0 of 275 | **0 (routes)** |
| `impl/ls5` | 7c91dea7 + merges | 1, 2 | 150 | 159,476 | 1,874 / 2,744 | 15 | 595 |
| `impl/ls4` | 7c91dea7 | 3, 1 | 150 | 157,886 | 1,860 / 2,809 | 21 | 613 |
| run A (here) | master 272fb1e | 3, 1 | 120 | 159,577 | 1,879 / 2,797 | 31 | 185 |
| run B (here) | as A, `-timing_driven 0` | 3, 1 | 120 | the same placement | the same | 31 | 185 |
| `impl/ls3` | before the register diet | 3, 1 | 150 | about 190,000 | 2,101 / 2,929 | 94 | 27,967 |

(A block of 8 x 8 grid cells holds at most 3,584 input pins: 512 LUT4 and 512 flip-flops. 2,400 is two thirds.)

- The measure separates routing from not routing and the worst build from the rest. It does **not** order the three
  middle builds (15, 21, 31 blocks against 595, 613, 185 nets): the count also depends on what is in the blocks.
- In the dense blocks there are 118 to 142 adder cells per block against 73 on average, and 2 to 3 LUT-RAM cells
  against 8 to 9. The dense places are adders with a register behind each bit: every position of the grid cell used,
  every one with its own inputs.
- Units with the largest share of their own cells in dense blocks (`ls4` / `ls5`, blocks over 2,100 pins):
  `u_ft8/u_cand` 58 / 46 %, `u_ft8/u_sync` 60 / 50 %, `u_ft8/u_spec` 39 / 32 %, `u_spectrum/u_fft` 40 / 59 %,
  `u_backend/u_post` 41 / 61 %, `u_backend/u_decim` 58 / 55 %, `u_backend/u_ring` 40 / 60 %,
  `u_hl2_tx/framer_i` 91 / 74 %, `u_tx_chain/u_cic` 43 / 79 %. The same units in two different placements: it is the
  units, not a place on the chip.
- The chip is not evenly full: 743 grid cells are empty and whole regions stand at 42 to 78 % slice use while the
  dense ones are at 100 %. The placer does not move logic from dense units into the free regions.

## 4. The two full-chip runs

Both: master 272fb1e, `TR_NO_ZOOM=1 GOWIN_PLACE_OPT=3 GOWIN_ROUTE_OPT=1 GOWIN_REPORTS=1`, clk_dsp constrained at
120 MHz in the build's copy of the constraints only (`-multiply_by 12 -divide_by 5`; the PLL was not changed).
Logic 86,785 (63 %), registers 79,905 (58 %), CLS 62,081 (90 %), block RAM 244 (72 %), DSP 142 (48 %).

| Run | Change | Result | Time |
|---|---|---|---|
| A (`impl/a120`) | clk_dsp at 120 MHz | **185 unrouted nets**, no timing report, no bitstream | place 18 min, route 81 min |
| B (`impl/b120nt`) | A + `GOWIN_PNR_OPTS="-timing_driven 0"` | **185 unrouted nets**; placement file identical to A's byte for byte | place 19 min, route 79 min |

Failing end points per clock: none can be given, the tool writes no timing report for a build that does not route.

Reading: 185 against about 600 looks like the effect of the relaxed clock, but run A also differs from `ls4` by the
commit (the second FT8 pass) and from `ls5` by the options, so that is **not proven**. Run B proves that the nets
left over are not a product of the router chasing timing.

## 5. Small runs (transmit chain alone, `gowin/res.sh tx_chain --wrap`)

| Constraint | `-timing_driven` | Placement file | Fmax |
|---|---|---|---|
| 150 MHz | 1 | 7bf4c5... | 168.8 |
| 400 MHz | 1 | 44b83d... | 156.1 |
| 400 MHz | 0 | 44b83d... (same) | 154.8 |

So the clock constraint does change the placement; `-timing_driven` changes only the router. A relaxed clk_dsp can
therefore give a different, possibly less dense placement, which fits run A.

## 6. What was ruled out, and the candidate fixes

Ruled out:

- **Clocks on general routing.** The netlist has 12 clock nets; all are on the 8 primary or the 8 long-wire lines
  (report section 6). `FLASH_SPI_CLK` of the TA1132 warning clocks nothing in the logic.
- **LUT RAM.** 2,300 to 2,400 cells, all clocked from global lines, 258 write-enable nets of at most 62 loads, and
  under-represented in the dense blocks.
- **The two resets on long wires.** They are where they should be: the 4,490 loads of the DSP reset and the DDR3
  reset's loads leave general routing. Taking them off would add those loads to it.
- **Options.** Place 3 / route 1 and place 1 / route 2 gave 613 and 595. `-timing_driven 0` gave the same placement
  and the same count.
- Not examined further: control sets as a routing limit (4,415 sets, 1,542 reset nets and 383 enable nets with one
  load each; a grid cell has three independent enable and reset inputs, UG303 2.1.2); pin access of DSP and block
  RAM columns; the RGMII and DDR3 cells. Nothing in the placement points at them, but they are not excluded.

Candidate fixes, most promising first:

1. **Take cells out of the dense units: about 15,000 in total.** The build that routes has 129,000 placed cells, the
   failing ones 158,000 to 160,000; routed builds of another design on the same board stand at 77 to 78 % slices. The cheapest cells are
   the flip-flops that are fed by another flip-flop (delay lines and pipeline copies): 30,041 in the netlist, of
   them `u_ft8` 7,640, `u_rx_bank` 7,451, `u_backend` 3,707, `u_comp` 3,040, `u_spectrum` 2,233
   (`tools/gowin_pack.py`). A delay line of 16 steps in LUT RAM is 1 cell per 4 bits instead of 64 flip-flops; in
   block RAM it is none (block RAM is at 72 %). For whoever works on this next: in `u_ft8/u_cand`, `u_ft8/u_sync` and
   `u_backend/u_post` list the registers with `tools/gowin_regs.py`, and move every chain of 4 or more equal-enable
   stages into a LUT-RAM or block-RAM delay. The size of the effect per cell removed is an estimate, not measured.
2. **clk_dsp at 120 MHz** (decided, branch `clk120`). Run A suggests about a third of the unrouted nets are left;
   not enough alone. It also lets wide adders be less pipelined, which is fix 1 again.
3. **Gowin V1.9.12.04** (installed; `GOWIN_IDE=...`). One run, not made here. builds of another design with it also left
   nets unrouted at 78 %, so little is expected.
4. Not a fix: region or group constraints (they hang in this version);
   `-replicate_resources` (adds cells).

Check any fix with `python tools/gowin_place.py <...>.db` after the 20 minutes of placement: if blocks over 2,400
pins remain, the 80 minutes of routing will most likely fail and the run can be stopped.

## 7. Why slices (CLS) stand at 90 % with 60 % of the cells

A slice counts as used when any of its two LUT and two flip-flop positions is taken. In `ls4`: 43,325 half-slices
hold a LUT (or adder) and the flip-flop it feeds, **35,598 hold only a flip-flop, 28,036 only a LUT**. The placer
does not put an unrelated LUT and flip-flop into one half unless it must: `ls4` has 2.67 cells per slice, the build
that failed to place had 3.3 to 3.4 (docs/FIT.md). The hardware allows it (UG303 2.1.2, note 1: a register can take
its input from the routing while the LUT is in use). So 90 % is the placer using the room it has; it is not the
reason routing fails.

What brings it down: fewer flip-flops that have no LUT of their own (40,161 in the netlist: 30,041 fed by a
flip-flop, 5,465 by LUT RAM, 2,666 by block RAM or DSP outputs). That is the same work as fix 1. Control sets cost
little: 37,890 slices if only flip-flops of one set share a slice, against 36,515 if all could pair.
