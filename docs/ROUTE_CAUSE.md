<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# ROUTE_CAUSE: why a chip at 60 to 65 % did not route, by comparison with a design that does

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Written 2026-10-13, branch `rcause`. Follows docs/ROUTE_DIAG.md, docs/FIT.md, docs/THIN.md. GW5AST-LV138FPG676A.
All runs of this work: Gowin V1.9.12.04, place option 3, route option 1, no replication, `GOWIN_REPORTS=1`.
A reference design that routes on the same board (variant v8dl) was built here from a copy of its source tree
(`git archive` into this worktree's ignored build folder).

## 1. In short

1. **The chip that left 287 nets unrouted routes on the new tool.** The same tree (master a3e977b: 4 receivers
   and zoom, logic 65 %, slices 91 %) built with V1.9.12.04 instead of V1.9.11.03: 0 unrouted nets (run
   `base12`). "Does not route" was the old router.
2. **The reference design's "77 to 80 % full" is slices, not cells.** Its build that passes at 78 % slices has 45 % logic
   and 46 % registers: 121,600 placed cells. Our failing chip had 159,100 placed cells (1.31 times) and 1.44 times
   the wires. By the reference design's own measure we stood at 91 %. It has passed once at 88 % slices (one
   engine alone, 2026-09-29) and never above; at 92 % it routed only with the fast router and reached 110 of
   150 MHz, and one of its designs left 2,023 nets unrouted at 74 % slices and 125,000 cells, on the new tool.
   A fair measure of "how full" is placed cells or input pins, section 2.
3. **Slices far above cell use is not a fault of our style.** The reference design fills 78 % of the slices with 45 % of
   the cells (2.28 cells per used slice); we fill 86 % with 57 / 50 % (2.34). The placer spreads into the room
   it has in both projects. The share of flip-flops without a LUT of their own is 57 to 61 % in both.
4. **What the design did wrong is in the timing, not the routing: logic between units that are far apart.**
   On the new tool the chip routes and then misses 120 MHz on a handful of structures in which a signal crosses
   the chip, passes several LUTs and crosses back in one clock. Three of them were removed here (section 4);
   with them the chip of master a91c22c **routes and meets every clock, setup and hold** (run X1), and with the
   synthesis fan-out limit switched off as well it **meets the clocks tightened by 5 %** (run X3: clk_dsp
   129.3 MHz for 120).
5. Two style differences are real but small: 59 control sets per 1,000 flip-flops against 38, and 25 to 28 %
   adder cells against 17 %. Neither was shown to cost routing (section 3).

## 2. The comparison

Netlist figures from `tools/gowin_struct.py` (new; cells of encrypted Gowin blocks are not in a netlist, so its
counts are a little under the report's), placement from `tools/gowin_place.py`, the rest from the reports.

| | reference design v8dl | fpga-sdr a3e977b (4 receivers + zoom, before the zoom diet) | fpga-sdr a91c22c (after the zoom diet) |
|---|---|---|---|
| Result on V1.9.12.04 | passes; clk_dsp 162.0 MHz for 157.5 | routes; clk_dsp 98.8 MHz for 120, 391 end points | routes; 109.2 MHz, 34 setup and 32 hold end points (run n1) |
| Result on V1.9.11.03 | - | **287 unrouted nets** (`ls8`) | - |
| Time of the run | 33 min | 95 min | 54 min |
| Logic / registers (report) | 62,176 (45 %) / 62,884 (46 %) | 89,073 (65 %) / 79,515 (58 %) | 78,144 (57 %) / 68,376 (50 %) |
| Slices (CLS) | 53,341 (78 %) | 62,665 (91 %) | 58,965 (86 %) |
| Block RAM / DSP | 262 (78 %) / 120 (41 %) | 226 (67 %) / 145 (49 %) | 221 (65 %) / 127 (43 %) |
| Placed cells | 121,592 | 159,070 | 138,049 |
| Placed cells per used slice | 2.28 | 2.54 | 2.34 |
| Half-slices: LUT and flip-flop / flip-flop only / LUT only | 23,162 / 39,721 / 29,988 | 44,594 / 34,920 / 27,702 | 32,057 / 36,318 / 31,405 |
| Nets / input pins (no clocks) | 130,090 / 287,536 | 186,386 / 413,584 | 158,552 / 354,736 |
| Pins per net | 2.21 | 2.22 | 2.24 |
| Input pins per block of 8 x 8 grid cells: median / max | 1,344 / 2,198 | 1,887 / 2,809 | 1,643 / 2,886 |
| Blocks over 2,400 pins | 0 | 16 | 4 |
| Routing use of the 50 fullest grids: highest / 50th | 91.7 / 81.9 % | 95.8 / 90.3 % | 88.9 / 83.3 % |
| LUT / adder cells / LUT ROM / LUT RAM (netlist) | 39,038 / 9,715 / 0 / 1,405 | 42,584 / 23,049 / 1,896 / 2,628 | 39,087 / 18,224 / 1,554 / 2,304 |
| Adder cells, share of logic | 17 % | 28 % | 25 % |
| Adder chains over 32 bits / over 48 | 52 / 4 | 122 / 21 | 130 / 21 |
| Flip-flops (netlist) | 56,987 | 73,618 | 62,479 |
| Flip-flops without a LUT of their own | 60 % | 61 % | 57 % |
| - of them fed by another flip-flop | 22,865 | 30,436 | 25,671 |
| Flip-flops with an enable / with a reset | 52 % / 21 % | 60 % / 36 % | 59 % / 32 % |
| Enable nets / reset nets | 1,275 / 883 | 2,791 / 2,692 | 2,036 / 2,024 |
| - enable nets with 5 to 16 loads / 17 to 64 | 278 / 598 | 1,682 / 447 | 1,072 / 432 |
| - reset nets with 5 to 16 loads | 190 | 1,232 | 732 |
| Control sets per 1,000 flip-flops | 38 | 61 | 59 |
| Data nets with over 64 loads (enable and reset pins not counted): nets / pins | 39 / 4,314 | 137 / 15,647 | 110 / 11,543 |
| Loads per DSP output bit | 1.64 | 1.40 | 1.42 |
| Global lines (primary / long wire) | 8 / 8 of 8 / 8 | 8 / 8 | 8 / 8 |
| Worst clk_dsp paths: logic levels, wire share | 1 to 3 levels, 81 to 94 % wire, up to 5.1 ns of wire | - | 6 to 10 levels, 56 to 86 % wire, up to 6.1 ns of wire |

Reading:

- **The rule of docs/ROUTE_DIAG.md holds across both designs and both tool versions as a measure of fill**: input
  pins per block. The reference design's passing build has a median of 1,344 and no block over 2,400. The old tool failed
  from about 15 such blocks; the new tool routes with 16, slowly (95 minutes) and far from the clock.
- **Per cell the two designs are alike**: pins per net, the share of nets with one load, flip-flops without a
  LUT, cells per slice. Our chip simply holds more of everything: 1.44 times the pins before the zoom diet, 1.23
  times now.
- **The last row is the difference that matters.** The reference design's longest wires (5 ns) carry one to three LUTs.
  Ours carried six to ten. Both placers put related registers 5 to 6 ns apart; only a design that has almost no
  logic on such a path survives it.

## 3. The hypotheses

| # | Hypothesis | Verdict | Evidence |
|---|---|---|---|
| 1 | Slices pack badly because of our style (flip-flops without a LUT, kept registers, `syn_srlstyle = "registers"`) | **no** | the reference design packs looser (2.28 cells per slice against 2.34 to 2.54) and has the same 60 % of flip-flops without a LUT. Synthesis without any `syn_srlstyle = "registers"` (run s2): 744 flip-flops less of 62,479, 68 LUT-RAM cells more: Gowin finds almost no shift register to convert, the 25,000 flip-flops fed by a flip-flop are single pipeline stages with their own enable or reset |
| 1b | Control sets (enable and reset variety) | **real difference, cost not shown** | 59 per 1,000 flip-flops against 38; 1,072 enable nets and 732 reset nets with 5 to 16 loads against 278 and 190: our habit of one kept copy per ten loads (`rx_fan`, `rx_vreg`, `syn_maxfan`). The slices do not show it (cells per slice as in the reference design). Not tested by a build with the copies merged: see section 6 |
| 2 | The fan-out limit multiplies registers and nets | **small, and the chip is better without it** | `syn_maxfan` set to 10,000 in all 46 places (run s1 synthesis, X2 and X3 full chip): 2,440 flip-flops and 1,185 LUT less, 8,000 pins less (2.3 %). Full chip: 32 against 36 minutes, clk_dsp 120.7 against 120.4 MHz at the real clocks; section 5 for the tightened clocks |
| 3 | Wide adders hinder placement | **not shown** | 2.4 times the reference design's adder cells before the diet, 21 chains over 48 bits against 4. But the blocks over 2,400 pins of the chip after the diet hold 22 to 82 adder cells against 67 on average, and no failing path of any run here is an adder chain. Moving accumulators into DSP blocks would save cells (section 6) but is not what failed |
| 4 | LUT RAM | **no** | 2,304 cells against 1,405; under-represented in the dense blocks (0 to 3 per block against 8.6 on average), as docs/ROUTE_DIAG.md found. LUT ROM (1,554 cells, none in the reference design) puts up to 123 cells on one address net; none on a failing path |
| 5 | Hub blocks: logic that joins units far apart | **yes: this is what failed timing** | The failing end points of the chip after the diet (n1): 18 in the receive lamp's counter, 13 from the zoom waterfall writer through the DDR3 write arbiter into the FT8 engines, 28 at 0.3 ns from the read arbiter into the lane address. Removed in section 4: 0 failing end points. What is left at the top of the list is the same family (section 6) |
| 6 | Global lines | **no** | Both designs use all 8 primary and all 8 long-wire lines. The DSP reset is on a long wire and still needs 6.3 to 7.0 ns to its farthest of 5,031 loads: the long wire is slow, it is not missing. The reference design's reset has 55 loads on its worst path |
| 7 | Tool version | **yes: this is what failed routing** | Same tree, same options: 287 unrouted nets on V1.9.11.03, 0 on V1.9.12.04 |

Also found: the constraints lacked the AE350's flash clock (the reference design has it). V1.9.12.04 then finds that
clock itself and reports 32 hold end points inside Gowin's flash controller. One line, section 4.

Different in the reference design and **not changed here, for the owner**: its AE350 bus clock is 50 MHz because Gowin's
encrypted flash controller reached only 69 MHz there; ours is 100 MHz. In our runs that controller is the
tightest thing on the bus clock: 91.7 MHz (13 failing end points) in n1, 101 to 109 MHz in the runs that pass.
It passes, with 1 to 9 % to spare, on logic nobody can change.

## 4. What was changed, and the builds

Commit eee2974 (four files):

| Change | File | Why | Cost |
|---|---|---|---|
| The write arbiter chooses its owner in a clock of its own; while idle it forwards and grants nothing | `rtl/ddr3/ddr3_write_arbiter.v` | Idle, it forwarded the client that priority would choose in the same clock, so every client's request reached every other client's grant: one piece of logic across the back end, both waterfall writers and FT8 | one clock per burst (a word takes about ten) |
| The read arbiter the same (new state between idle and busy) | `rtl/ddr3/ddr3_read_arbiter.v` | every client's request steered the lane address of all four | one clock per burst |
| The receive lamp is a register | `rtl/top/sdr_core.v` | the lamp was the stream-age counter's own end test as a wire; synthesis built the test into the lamp's logic, the placer put that at the lamp, 28 rows from the counter, and the counter's enable went there and back | one flip-flop |
| `create_clock` on the flash clock net, in the asynchronous groups | `gowin/p1/sdr.sdc` | 32 hold end points of a clock relation that does not exist | none |

Checks: `tb_ddr3_write_arbiter`, `tb_ddr3_write_arbiter_priority`, `tb_ddr3_read_arbiter`,
`tb_ddr3_video_no_starve`, `tb_waterfall_writer` and `tb_sdr_core` (arbiters with the relays and the real
clients): all PASS, once each.

Full chip, 4 receivers and zoom, master a91c22c:

| Run | Tree | Clocks asked | Routes | Setup / hold end points failing | clk_dsp | clk_tx | clk_pix | AHB | Logic / registers / slices | Time |
|---|---|---|---|---|---|---|---|---|---|---|
| n1 | a91c22c | real | yes | 34 / 32 (clk_dsp 18, clk_tx 2, clk_pix 1, AHB 13) | 109.2 | 123.7 | 136.7 | 91.7 | 78,144 / 68,376 / 58,965 (86 %) | 54 min |
| X1 | eee2974 (the four changes) | real | yes | **0 / 0** | 120.4 | 126.6 | 156.6 | 109.0 | 78,085 / 68,372 / 59,012 (86 %) | 36 min |
| X2 | eee2974, fan-out limit off | real | yes | **0 / 0** | 120.7 | 125.3 | 172.7 | 101.4 | 76,957 / 65,937 / 57,941 (84 %) | 32 min |
| X3 | as X2 | 5 % tighter (126 / 156.2 MHz) | yes | **0 / 0** | 129.3 | 129.4 | 165.6 | 106.7 | as X2 | 30 min |
| X4 | eee2974 | 5 % tighter | yes | **0 / 0** | 126.6 | 132.3 | 158.6 | 107.0 | as X1 | 34 min |

(Clocks: 120 MHz clk_dsp, 125 MHz clk_tx, 148.75 MHz clk_pix, 100 MHz AHB; the AHB is 80 MHz since 2026-10-13. All other clocks met in every run.)

X1 and X2 pass with 0.3 to 0.6 % on clk_dsp: the tool stops working on a clock once it is met, so a run at the
real clocks says nothing about the margin. X3 is the margin: the same tree asked for 126 MHz gives 129.3.

## 5. The fan-out limit

`syn_maxfan` stood in 46 places with values from 8 to 64, most of them 10 or 16, on whole modules. With the
limit the tool copies a register or LUT for every 10 or 16 loads.

| | Limit as written (X1, X4) | Limit off (X2, X3) |
|---|---|---|
| LUT / flip-flops (netlist) | 39,087 / 62,479 | 37,902 / 60,040 |
| Placed cells | 137,990 | 134,423 |
| Input pins | 354,736 | 346,740 |
| Data and control nets with 9 to 64 loads / over 64 | 6,412 / 225 | 4,360 / 389 |
| Input pins per 8 x 8 block: median / max | 1,601 / 2,668 | 1,593 / 2,433 |
| clk_dsp at the real clocks | 120.4 MHz | 120.7 MHz |
| clk_dsp asked for 126 MHz | 126.6 MHz | **129.3 MHz** |
| Failing end points, both pairs | 0 | 0 |
| Time of the run | 36 and 34 min | 32 and 30 min |

Both pass. Without the limit the chip is 3,570 cells smaller, the run shorter and clk_dsp 2.7 MHz faster where
the tool was pushed. One layout each, so the 2.7 MHz is an indication, not a proof; what is proven is that the
limit buys nothing on this chip. The reference design found the same in its engine (2,733 registers
less) and kept the limit only in two small units where a run had failed without it.

**Applied in the second commit of this branch:** every `syn_maxfan` in `rtl/` is 10,000 (the value is kept as a
place to put a number back: a unit that a timing report shows to need copies gets its own value again). X2 and
X3 are builds of exactly this tree. The hand-made copies (`rx_fan`, `rx_vreg`, kept registers) are untouched:
they are in the netlist of both columns, and merging them is RTL work in the receiver bank (section 6).

## 6. Redesign rules, and the work that follows

Rules (what our RTL must stop doing):

1. **Between two units there is a register on each side and at most one LUT between them.** A unit's outputs
   come from registers; a shared block (arbiter, register bus, multiplexer of several clients) registers what it
   takes and what it gives. No request that is answered in the same clock through a block another unit also
   talks to. The reference design's passing build has 1 to 3 LUTs on its longest wires; that is the mark.
2. **A value used in its own unit and somewhere far is two registers.** Never a wire out of the middle of a
   unit's logic to a lamp, a status register or another unit: synthesis merges the two uses and the placer puts
   the shared LUT at one of them.
3. **Size is judged in placed cells and input pins, not in slices.** Marks from this study: the reference design passes at
   121,600 cells and 288,000 pins; our chip passes with a 5 % margin at 134,400 cells and 347,000 pins; at
   159,000 cells and 414,000 pins it routes and reaches 99 MHz. Slices read 78, 84 and 91 % for the three and
   say little.
4. **No kept copy per ten loads as a habit.** Leave fan-out to the tool; copy a control signal by hand only where
   a timing report names it. (Section 5.)
5. **A reset only where the function needs one.** 32 % of our flip-flops have a reset against 21 %; the DSP
   reset has 5,031 loads and its long wire is the second tightest path of X3 (6.7 ns of wire).
6. **Every new clock the tool reports (warning TA1132) gets a constraint the day it appears.**

Follow-up work, in the order of X3's tightest paths (all of them pass today; this is margin):

| # | What | Files | Change | Expected |
|---|---|---|---|---|
| 0 | The hand-made control copies of the receiver bank and the variable CIC: 1,072 enable nets and 732 reset nets with 5 to 16 loads in the chip, 696 reset nets in the receiver bank alone | `rtl/rx/cic_var_shared.v` (`rx_fan`, `rx_vreg`), `rtl/rx/fir_decim.v`, `rtl/rx/rx_bank.v`, `rtl/rx/rx_channel.v` | one synthesis-only run and one full-chip run with `rx_fan` built as one register for all its outputs (a define); keep the copies only if clk_dsp falls | not known: this is the one style difference to the reference design (59 against 38 control sets per 1,000 flip-flops) that no build has tested |
| 1 | FT8's writers reach their own counters through the chip's write arbiter and the relay's wait in one clock (`u_ft8/u_cand/wr_req -> ocnt0`, 8 LUTs, 0.2 ns of slack in X3; also `-> u_wr_relay/l_en`, `-> u_spec/u_cap/req`) | `rtl/ft8/ft8_frontend.v` (its write multiplexer `u_wmux`), `rtl/ddr3/ddr3_wr_relay.v` | a word register at the output of FT8's write multiplexer speaking the relay's handshake (the module `ddr3_wr_relay` can be instantiated a second time there), so a client's grant comes from registers next to it | the top class of clk_dsp gone; about 110 flip-flops |
| 2 | The DSP reset: 5,031 loads, 6.3 to 7.0 ns of wire | all of `rtl/` | remove the reset from registers that are overwritten before they are read (data pipelines, delay lines, accumulators that have a clear of their own); keep it on state machines, valid flags and counters. Start with `rtl/ft8/ft8_spectrogram*.v` capture, `rtl/fft/fft_bf.v`, `rtl/ft8/ft8_sync.v`, the units on X3's list | the reset off the list; several thousand reset pins and the control sets they make |
| 3 | FT8 register read-back (`u_ft8/a1 -> glob`, 20 to 25 end points, a select with 146 to 272 loads) | `rtl/ft8/ft8_frontend.v` | read-back multiplexer in two clocks: one per engine, then between engines | 0.5 ns to several ns |
| 4 | One register named in the receiver back end's exponent table drives 501 enables of the transmit oscillator (`u_backend/u_post/u_exp/data -> u_tx_chain/u_nco/phase`, 0.5 ns in X3) | `rtl/rx_backend/bk_rom.v`, `rtl/tx/tx_chain.v` | not explained here: find out whether synthesis merged two equal registers of the two units, and give the transmit side its own kept register | one cross-chip net of 515 loads gone |
| 5 | The write relay's enable `l_en` clocks its own 115 registers and waits on itself (87 to 89 % wire) | `rtl/ddr3/ddr3_wr_relay.v` | two or four kept copies of `l_en` for the data registers | 1 ns |
| 6 | Accumulators over 48 bits (21 chains, 1,145 adder cells, the longest 71 bits in the back end) | `rtl/rx_backend`, `rtl/ft8` | only if cells are needed again: into the 54-bit accumulator of a DSP block (DSP stands at 43 %) | cells, not timing |
| 7 | Owner's decision: the AE350 bus clock at 50 MHz as in the reference design | `gowin/p1/ip/gowin_pll_ae350.mod`, `gowin/p1/sdr.sdc`, firmware timing constants | - | the encrypted flash controller no longer at 1 to 9 % of its limit; register access from the CPU half as fast |

## 7. Runs of this work

| Run | What | Result |
|---|---|---|
| ref | reference design v8dl | passes, as its own run q1: the netlist and placement for section 2 |
| base12 | fpga-sdr a3e977b on V1.9.12.04 (the baseline the owner ordered; not one of the five) | routes; clk_dsp 98.8 MHz |
| s1, s2 | synthesis only: fan-out limit off; `syn_srlstyle = "registers"` removed | section 3, rows 2 and 1 |
| X1 to X4 | four full-chip runs, sections 4 and 5 | one of the five allowed runs was not used |

Build folders: `gowin/impl/{ref,base12,x1,x2,x3,x4}` in this worktree (ignored by git; they go with the worktree).
