<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# Making the design fit the chip (WP FIT)

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Written 2026-10-12, branch `fit`. The merged design (zoom receiver, FT8 front end, compositor) did not place:
`ERROR (PR0003) Failed to place with '10919 REG(s) unPlaced'`, registers 86 %, slices (CLS) 92 %
(gowin/reports/p1_ls5_b3/result.md). Target: registers under 75 %, CLS at or under 80 %, block RAM not above
255 of 340, no timing given back.

Manuals used: SUG550-2.0.1E (GowinSynthesis: `syn_ramstyle`, `syn_preserve`, `syn_maxfan`, translate_off),
UG285 / the primitive models in `IDE/simlib/gw5a/prim_sim.v` (RAM16SDP4: 16 words x 4 bits, written with the
clock, read without one, `INIT_0..3`; DFFSE / DFFRE), SUG940 (set_max_delay, as rx_backend.sdc uses it).
Features used: RAM16SDP4 as inferred distributed RAM with start contents; instantiated DFFSE / DFFRE for the
fan-out copies. Not used: shift-register (SRL) inference, block RAM for any of the moved state.

## 1. Where the registers were

From a synthesis-only run of master 9b51636 (`gowin/p1/build.sh --syn`, 17 minutes) and three tools on its
netlist: `tools/gowin_mems.py` (per unit), `tools/gowin_regs.py` (new: the flip-flops of one unit by signal
name, memories built from flip-flops grouped) and a search for `RAMREG` (the name GowinSynthesis gives a
memory it built from flip-flops).

| Where | Flip-flops | What they were |
|---|---|---|
| Receiver bank, the two shared variable CIC engines | 15,388 | 16 contexts x 15 words x 43 bits of state (10,320), 2 clocks of kept reset / enable copies per context (2,100), the rest control and output rounding |
| Spectrum, zoom context: its arrival queue `fifoB_mem` | 6,784 | **128 words x 53 bits built from flip-flops**, with a 128-way read select behind it. The source asks for LUT RAM in the attribute form `(* syn_ramstyle *)`, which this tool ignores (docs/TANG_LESSONS.md section 8). Not this work package's file (the zoom work package) |
| Compositor, the picture description | 6,128 | four copies of about 1,430 bits: the bus registers, a register stage `live`, the frame copy `snap`, the pixel-clock copy `cfg` |
| Receiver back end, settings | 2,700 | 13 settings x 8 receivers and 12 bank words as flip-flops; **with their 8-way selects in every engine and in the read-back they were most of the back end top level's 10,500 LUTs** |
| Receiver back end, stamps and counters | 1,024 | stamp_base, stamp_next, out_count per receiver |
| Kept reset copies that power up high (`rx_fan` with INIT = 1), receiver bank and zoom | about 1,900 | **each such register was built twice**: GowinSynthesis V1.9.11.03 makes the set-type flip-flop that drives the loads and a reset-type twin with no load, which `syn_preserve` then keeps. Measured on a 60-line design: 21 flip-flops for 10 |
| Receiver bank, 16 fixed CICs | 6,264 | 252 of state each (full rate: must be flip-flops), 92 of copies each (before the twin fix), 37 of input delay |
| Receiver bank, 8 mixers / 8 FIRs | 2,296 / 2,792 | pipelines |

What was looked at and is not where the registers are:

- **Long delay chains that `syn_srlstyle = "registers"` keeps out of shift registers.** In the receiver bank
  these are the mixer's 12-bit input delay (4 stages) and the fixed CIC's 18-bit input delay (2 stages):
  about 290 + 580 flip-flops in the whole bank. Shift registers there are RAM16 cells on one shared toggle,
  the cause of the 106.8 MHz run of WP LS3 (gowin/reports/rx_bank/summary.txt). Left as they are: the gain is
  under 1 % of the bank and the risk is known.
- **Fan-out copies more generous than the rule.** Apart from the twins above they are at 10 or 11 loads per
  copy, inside the 8 to 13 rule. Left.
- The back end's engines (`bk_post`, `bk_front`, `bk_ring`) already keep their per-receiver state in LUT RAM.

## 2. The cuts, largest first

| Cut | Flip-flops | LUT + adders | LUT RAM cells | Timing risk, and what happened |
|---|---|---|---|---|
| 1. Shared CIC: state in three LUT RAMs per engine, one word per context | -10,700 | -5,500 | +302 | New 4-clock read / add / write pipeline. Stand-alone at 6.35 ns: first version 142.9 MHz, 52 end points (the grant decision, 6 levels); second version **161.2 MHz, 0 failing** (before the cut: 155.6 MHz, 1 failing) |
| 2. Compositor: description held twice instead of four times | -2,570 | +80 | 0 | None on clk_dsp (fewer registers on the same paths); the frame copy now takes about 270 clocks of the vertical blank instead of 2 |
| 3. Back end: settings and bank table in LUT RAM, read by each engine at its own receiver | -2,650 | -7,800 | +156 | Lower: a LUT RAM read replaces an 8-way select of far flip-flops. Write enables are registers; the write address and data keep their two-clock rule |
| 4. Back end: first-sample stamp per receiver in LUT RAM | -384 | (in 3) | +12 | None (written once per enable, read only by the CPU) |
| 5. `rx_fan`: instantiated flip-flops, no twins | -590 in the bank, -1,224 in the zoom | 0 | 0 | None |

### 2.1 Shared variable CIC (`rtl/rx/cic_var_shared.v`)

The engine serves one context per clock, so only that context's 15 words are needed at a time. They are three
memories of 215 bits (integrators, comb outputs, comb inputs of last time), 16 words deep with 8 in use
(`rx_ctxram`: one kept write-enable copy per 10 cells; the address registers are copied by `syn_maxfan`).
After a grant: E0 read the integrators; E1 add, read the comb words; E2 write the integrators, subtract, write
the comb inputs; E3 write the comb outputs and load that context's own 32-bit copy of the top comb output,
which the output rounding reads every clock as before (so a change of the decimation setting still shows at
once). A context is granted at most once in 10 clocks, so its words are never in the pipeline twice.

Reset of one context (a receiver switched off) clears nothing in the memory: it sets two flags of that
context, "integrators count as zero" and "comb words count as zero". The next grant takes zeros instead of
what it read and clears the flag. (The first version did the clear as a grant of its own; that put two more
terms into the grant decision and failed timing.)

Checked: `tb_rb3_compare` (846 output words equal to the reference design, full-rate and bursty input),
`tb_rx_bank` (rates, switch off and on again).

### 2.2 Compositor (`rtl/video/compositor.v`, `compositor_util.v`)

A register write goes into the read-back RAM only (it was there already). Once per frame, at the capture
pulse from the pixel side, a sweep reads the 256 words through the read-back port and loads the description
registers; derived values (sums, clamps) follow in one register stage, the two scroll lines are taken at the
end, then the frame counter, the spectrum copy and the acknowledge go on as before. A bus read takes the port
for eight clocks and the sweep waits. Still written at once by the bus: palette index and data, the two ring
bases of the waterfall writers, the status clear bits.

What changes for firmware: nothing in addresses or values. A register written during the 270 clocks of the
sweep may land in this frame or the next (before: during 2 clocks).

Checked: `tb_compositor`, 15,478 pixels, 0 errors.

### 2.3 Back end settings (`rtl/rx_backend/rx_backend.v`, `bk_post.v`, `bk_front.v`, `bk_ring.v`, `bk_chfilt.v`)

Each engine works on one receiver at a time and loaded that receiver's settings into its own registers
through an 8-way select. Now it gives its receiver number (`cfg_rx`, `cfg_r2c` / `cfg_r3` / `cfg_r4`,
`cfg_bank`) and gets the one value from a 16-word LUT RAM (`bk_cfgram` in bk_ram.v); the register read-back
has a second memory per setting. Still flip-flops: the control word, ring size and ring enable (read for all
receivers at once).

Reset values are the memories' start contents (checked in the netlist: `INIT_n` of the RAM16SDP4 cells carry
them), and while the reset is held every word is written again, one in four clocks (576 clocks; the reset key
and PLL lock hold far longer). **A reset shorter than 576 clocks after the first leaves CPU-written settings
in the words it did not reach**; there is no such reset in the design.

Not moved: `stamp_next` and `out_count` (640 flip-flops, 640 adder cells). Each is read, changed and written
per output sample, and a first sample of another receiver can need the write port in the same clock; a
memory needs a small queue for that. See section 5.

Checked: `tb_rx_backend` (1,240 outputs of 8 receivers equal to the model), `tb_rx_backend_ring`
(its direct `bk_ring` instance now gives the ring base of the receiver asked for).

### 2.4 `rx_fan`

In Gowin builds (`GOWIN_DSP`) the copies are instantiated DFFSE (power-up high) or DFFRE flip-flops with
`syn_preserve`; simulation keeps the behavioural form. The same helper serves the zoom's CIC, which lost
1,224 flip-flops without a change to its files.

## 3. Result

Synthesis of the whole chip, before (9b51636) and after (this branch), same tool and settings:

| | Before | After |
|---|---|---|
| Registers | 120,695 (87 %) | 102,590 (74 %) |
| LUT / adder cells / LUT RAM cells | 64,664 / 33,681 / 2,113 | 57,447 / 27,677 / 2,583 |
| Logic as place-and-route counts it (LUT + adders + 6 per LUT RAM cell) | about 111,000 (80 %) | about 100,600 (73 %) |
| Block RAM (place-and-route's count) | 255 | 255 |

By block (LUT / adders / LUT RAM cells / registers; block RAM unchanged everywhere):

| Block | Before | After |
|---|---|---|
| Receiver bank | 3,482 / 11,264 / 640 / 27,405 | 4,020 / 5,244 / 942 / 16,118 |
| Receiver back end | 20,342 / 2,916 / 552 / 15,635 | 12,514 / 2,925 / 720 / 12,606 |
| Compositor | 2,486 / 1,375 / 177 / 8,799 | 2,555 / 1,382 / 177 / 6,232 |
| Zoom (not edited; `rx_fan` only) | 4,115 / 7,327 / 457 / 17,348 | 4,115 / 7,327 / 457 / 16,124 |
| Spectrum, FT8 front end | unchanged | 13,709 and 19,246 registers |

Receiver bank alone, place 3 / route 1, 6.35 ns: 155.6 MHz with 1 failing end point before, **161.2 MHz with
none** after; logic 14,634 -> 11,971, registers 26,908 -> 16,113.

Full-chip place-and-route: section 6 (it does not place yet).

## 4. Budgets for the two blocks other work packages own

- **Zoom, including the zoom context of the spectrum: 18,500 flip-flops in all** (today 16,124 in the zoom +
  about 7,600 in the spectrum's zoom half = 23,700). One change meets it: `fifoB_mem` in
  `rtl/spectrum/spectrum_pipeline.v` (128 x 53) out of flip-flops. Write the attribute in the comment form
  (`reg ... fifoB_mem [0:N-1] /* synthesis syn_ramstyle = "distributed_ram" */;`) and give it a registered
  read, or make it 32 words (the tool builds 16- and 32-word LUT RAMs; above that TANG_LESSONS says block
  RAM, which here would be 3 blocks). That is -6,784 flip-flops and about -2,500 LUT of read select.
  The zoom's own 16,124: its variable CIC (`cic_var_pow2`) keeps state in `rx_vreg` flip-flops the way the
  bank's did; a narrower span set shortens those words.
- **FT8 front end: 19,500 flip-flops with the second decode pass** (today 19,246: spectrogram 7,100,
  candidates 6,000, sync 3,700, top 2,400). The second pass should reuse the first pass's pipeline registers
  (same lanes, another sweep) and keep per-candidate state in LUT RAM as `ft8_cand_lane` does. `ft8_sync`
  has two small memories in flip-flops (`pend_rows` 72, `armed` 24).

With both budgets met the chip is at about 96,000 registers (69 %). Section 6 shows that registers alone
do not decide: count logic + registers, and see the last list there.

## 5. What else could go

| What | Saves | Cost |
|---|---|---|
| Back end `stamp_next`, `out_count` into LUT RAM with one shared adder | 640 flip-flops, 640 adder cells, about 600 LUT | a two-entry queue for the write port; the stamp path was a timing fix of the fourth pass |
| Back end ring writer: sequence counters and slot masks (`seq`, `slot_mask`) | 380 flip-flops | one more pipeline clock in the address path (was 0.3 ns short once) |
| Back end decimator: `fill`, `wp`, `phase` built from flip-flops | 450 flip-flops | small; not looked at in detail |
| Fixed CICs of the bank: comb halves of 8 receivers through two shared engines | about 1,400 flip-flops | the result must be back within 10 clocks at full input rate; 8 grants plus 4 pipeline clocks do not fit one engine, so two |
| 6 receivers instead of 8 | about 3,300 flip-flops, 8 DSP, 6 block RAM | a feature; the owner wants 8 |
| FFT of the spectrum (4,027 flip-flops) and its 790 LUT RAM cells | not examined | shared with FT8 |

## 6. Full-chip place-and-route: it still does not place, by 1,350 registers

One run of this branch (dae5dee + the reset value fix), place option 3, route option 1, zoom in:
`ERROR (PR0003) Failed to place with '1350 REG(s) unPlaced'` (build 3 of master: 10,919). No timing report.

| | Build 3 (master, fd1e00b) | This branch |
|---|---|---|
| Logic | 109,372 (80 %) | 103,446 (75 %) |
| Registers | 119,472 (86 %) | 102,590 (74 %) |
| Slices (CLS) | 63,500 (92 %) | 62,629 (91 %) |
| Block RAM, place-and-route's own figure | 307 (91 %) | 281 (83 %; not changed by this work: 250 primitives in both synthesis runs) |
| Registers it could not place | 10,919 | 1,350 |

**The register target is met and the slice figure hardly moved.** What the two failed runs show: the placer
stops at about 91 to 92 % of the slices whatever is in them, and it then holds 3.3 to 3.4 cells per slice
(logic cells plus flip-flops, of 4 places). So the number that decides is **logic + registers**:

| | Logic + registers | Outcome |
|---|---|---|
| Build 3 | 228,800 | 10,919 flip-flops over |
| This branch | 206,000 | 1,350 over |
| Placed, by this measure | about 204,700 | the slices full (91 %) |
| Build 2 of LS5 (before the zoom, FT8 and compositor) | about 164,000 | placed, CLS 78 % |
| Slices at 80 % | about 175,000 to 182,000 | the target |

A slice is not filled to 4 because a flip-flop that is not fed by the LUT or adder in its own slice half
cannot always share with a foreign LUT: `tools/gowin_pack.py` counts 55,000 of the design's 96,700 visible
flip-flops as fed by another flip-flop (37,300), a LUT RAM (5,700), a hard block (4,400) or a LUT that already
hosts a flip-flop (6,800). Control sets are not the cause: `tools/gowin_ctrlsets.py` finds 5,837 of them,
which cost 1,600 slices. (The exact slice rules are not in the manuals read; the 3.3 to 3.4 is measured on
two runs only.)

What follows:

- **To place at all: about 1,500 cells more.** The zoom context's arrival queue alone (section 4) is
  6,784 flip-flops and about 2,500 LUT: the design then stands near 196,700 and should place, with the slices
  still near 90 % and timing as uncertain as TANG_LESSONS says for a chip that full.
- **For slices at 80 %: about 25,000 to 30,000 cells below today's 206,000.** After the queue that is
  another 15,000 to 20,000, and it has to come from logic as much as from flip-flops. The blocks by logic +
  registers: FT8 front end 42,800; receiver back end 32,400; spectrum 32,400 (23,100 without the queue); zoom
  29,400; receiver bank 27,800; compositor 11,600. Section 5 lists about 6,000 in this work package's blocks;
  the rest is in the zoom (its CIC state, as section 2.1 did for the bank: of the order of 5,000) and the
  FT8 front end.

Not run: the stand-alone place-and-route of the back end (the third allowed block run) and a second full-chip
run; the budget allowed one full-chip run.
