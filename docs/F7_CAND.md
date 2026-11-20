<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# WP F7 — FT8 candidate engine

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Work package F7 (`docs/PLAN.md`, with the RB8 amendment on the same row: 2 lanes), design in
`docs/ARCHITECTURE.md` 3.12 (d) and 3.14 change C9. Reference model: `baseband_fx`
(`fw/tr-modes/src/frontend/baseband.rs`, pass 1) and `symbols_fx` (`symbols.rs`, pass 2), WP S15.
Built together with F6 (`docs/F6_SYNC.md`) on branch `f67`. This job also re-measures F5.

## Status (2026-10-12)

Bit-exact in its unit test, in the chip (`rtl/ft8/ft8_frontend.v`). Alone it measured 120.6 MHz
after a rebuild; the fixes for what that run showed are in and not measured.

- `sim/ft8/tb_ft8_cand.v` PASS on the final RTL: 6,400 baseband words and 1,264 soft-symbol
  words bit-exact. Pass 1 (both lanes, one slot replay) 204,048 clocks = 1.360 ms; pass 2
  25,681 clocks = 0.171 ms. For 480 candidates: 240 x 1.531 ms = **0.367 s** (limit 0.4 s).
- `tools/check_ft8_cand.sh` PASS on the final RTL: 480 candidates (8 receivers x 60) of
  `qso3_busy` and `qso1`, every baseband and soft-symbol word equal to the model's, **368.1 ms**
  simulated with video traffic (limit 400 ms), no video underrun. LDPC (mfsk-core) on the RTL's
  soft symbols gives the model's messages: 15 on `qso3_busy`, 3 on `qso1`.

## Resources and Fmax

`gowin/res.sh ft8_cand --wrap --period-ns 6.35 --opt "place_option 3" --opt "route_option 1"
rtl/ft8/ft8_cand.v` (150 MHz with 5 % margin):

| | Run 1 (RTL of the pause) | Run 2 (after the rebuild) |
|---|---|---|
| Fmax | 83.9 MHz | **120.6 MHz** |
| Failing end points | 2,203 | 140 |
| Logic / registers (block alone) | 10,361 / 4,953 | 9,009 / 6,239 |
| DSP | 13 | **12** (limit 16) |
| Block RAM (place-and-route count) | 8 | **2** (the two NCO ROMs; limit 5) |

Run 1 would not synthesise at first: the request cursors had two drivers (Gowin EX2000; the
simulator accepts it). What it then showed, and the rebuild (docs/TANG_LESSONS.md 3 and 6):

- The multipliers were inferred without output registers, and their products ran through 50-bit
  adders in the same clock (6.7 ns of cells). Now six instantiated DSP blocks per lane
  (`ft8_mac.v`: input, product and output register). The four of the FIR / DFT accumulate inside
  the block; a clock with a zero operand holds the sum, so no sum register has a load enable.
  Rounding moved from the accumulators' first load to a clock behind the sums.
- Gowin had built the two lanes' payload delay as one shared block RAM (the fault of a register
  array in a module instantiated twice, TANG_LESSONS section 8). They are named registers now,
  and the modules carry `syn_srlstyle = "registers"`.
- `t x n` of the DFT was a hard 12 x 12 multiplier; it is a running sum.
- Integrators: load enables in nine kept copies. Combs: one 4-word LUT RAM, two clocks per comb.
- The FIR tap ROM was 2 block RAMs per lane; it is LUTs.
- Engine: the pass 1 word register reloads on a flag decided a clock ahead; pass 2 hands a word
  over with a strobe after the lane showed ready (5 clocks per word); the request arithmetic is
  one add or compare per clock.

What run 2 showed (worst -1.94 ns), fixed after it and **not re-measured**:

- 330 command registers on one load enable (`run`): the addresses, increments and start samples
  are no longer copied; the engine reads its inputs for the whole command (the front end's
  registers hold them);
- the 128-word FIFO read plus the first word's shift in one clock: the word comes from the
  registered FIFO head;
- the FIR sequencer's compares on the q index and the output count: registered flags;
- the issue addresses' load enable: they load every clock.

Left from run 2 and not touched: FIFO count update (-0.22 ns), the write address add (-0.08),
the NCO's sign stage (-0.04).

## What the CPU does (registers: `hw/regmap/ft8.toml`, page 0xE80D_0000)

All addresses are lane-word addresses: byte address in DDR3 = 8 x the value. The engines write
DDR3 themselves; the CPU reads the results from its own view of the memory after invalidating
those data-cache lines (docs/ARCHITECTURE.md 4.2).

1. Once per receiver: `cap_base` (1 MB audio ring), `spec_base` (1.5 MB spectrogram),
   `rec_base` (sync records, 32 bytes per carrier bin), `band`, `trig`, `ctrl` (enable, shift).
2. Each slot: read `cap_wr_ptr` at a known time, work out the capture sample count of the slot's
   first sample, write it to `slot_boundary`. That starts the slot: the spectrogram frames are
   computed as the audio arrives, and the sync searches start by themselves at the `trig`
   frame counts and at frame 372.
3. Interrupt 11 with `irq_status.sync_done[r]`: read receiver r's records at `rec_base`
   (`sync_rows` says how many rows that search covered), build the candidate list.
4. Per pair of candidates: write `cand_cap_base` (the receiver's `cap_base`),
   `cand_first_sample` (its `slot_boundary`), per lane `cand_inc` and `cand_bb_base`, then
   `cand_cmd` = pass 1. On `irq_status.cand_done` read the two basebands (3,200 words each),
   find fine time and frequency, write per lane `cand_inc` (rotation), `cand_i0` and
   `cand_sym_base`, then `cand_cmd` = pass 2. On `cand_done` read the 632 soft-symbol words per
   lane and run LDPC. Write the `cand_*` registers only while `status.cand_busy` is 0.

## What is left

- (Done 2026-10-12, `docs/FT8_PASS2.md`: the second pass. The spectrogram engine replays a
  buffer of residual audio and the sync engine then searches it, on `p2_cmd`; the candidate engine
  takes the residual buffer as `cand_cap_base` with `cand_first_sample` = 0.)
- **The slot boundary is in capture-sample counts, not HL2 sample indices** (ARCHITECTURE 3.12
  (a) says HL2 index). The firmware converts with one read of `cap_wr_ptr`; the back end's
  sample stamp is not carried into the capture.
- Gowin re-measurement of `ft8_sync` and `ft8_cand` after their second fix rounds.
- FT4 and JS8 parameters (not modelled either).

## Files so far

| File | What |
|---|---|
| `rtl/ft8/ft8_cand.v` | Engine top: commands, slot replay and baseband read (128-word FIFO), 2 lanes, output writer |
| `rtl/ft8/ft8_cand_lane.v` | One lane. Pass 1: mix, 4-stage CIC/30, 65-tap FIR/2 (4 multipliers, 33 clocks per output). Pass 2: rotation, 79 x 8 tone DFTs. 6 DSP per lane |
| `rtl/ft8/ft8_nco.v` | The model's rounded-index NCO lookup, from a packed quarter-wave ROM (512 x 36, 1 BSRAM). Why not `rtl/rx/nco_mixer.v`: see its header. That mixer's Taylor correction, gain and sign differ from the S15 model, so only its ROM layout is reused |
| `rtl/ft8/rom/ft8_nco_q512.hex`, `ft8_fir65.hex`, `ft8_w32.hex` | ROMs written by `ft8-frontend tables`, which also checks the RTL's NCO address mapping against the model's table for all 4,096 indices |
| `sim/ft8/tb_ft8_cand.v`, `sim/ft8/vectors/f7_synth_*.hex` | Unit test and its vectors (`ft8-frontend f7-synth`) |
| `sim/ft8/ft8_cand_wav_harness.v`, `tools/check_ft8_cand.sh` | 480-candidate check on the recordings (`ft8-frontend f7-vectors`, `cand-check`) |
| `rtl/ft8/ft8_slot_capture.v`, `ft8_slot_reader.v`, `ft8_spectrogram.v` | The F5 changes above |
| `tools/check.sh` | Runs the two long FT8 checks only with `FT8_LONG=1` |
