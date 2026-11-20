<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# FT8 second decode pass with the chip's help

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Branch `pass2`. **Nothing here has run on the board.** Sections 1 to 6 are the design, written
before the build; section 7 on has what was built and measured.

## 1. The problem

One pass through the chip's front end (F5 spectrogram, F6 sync search, F7 candidate engine) finds
6 of the 8 messages WSJT-X decodes in the busy test recording (`qso3_busy`). The two it lacks:

- `K1BZM DK8NE -10`: a weak signal that is not among the first 70 candidates of the first pass.
- `KD2UGC F6GCP R-23`: 7 Hz from a stronger signal. It only shows after the stronger one is
  subtracted from the audio.

A second pass (subtract the first pass's decodes, search the residual again) finds both. Until now
the chip had no way to search a residual: the spectrogram engine only transformed the live audio of
a receiver, and the sync search followed it. Doing the residual's spectrogram, sync search and
candidate filters in software costs about 83 % of a full software decode, which does not fit.

## 2. Decisions

| Question | Decision | Why |
|---|---|---|
| Where is the subtraction done? | **On the CPU**, on a copy of the slot's audio, written back to DDR3 as a residual buffer | It already exists (`frontend/subtract.rs`), is measured (31 to 140 M instructions per slot, FT8_CPU 3.2) and fits the operator's allowance. It is the same arithmetic the two-pass model uses, so the chip path decodes exactly what the model decodes. In the chip it would need a GFSK generator, an amplitude tracker (a 0.33 s smoothing filter per signal) and a read-modify-write pass over the capture ring: new multipliers and memory for work the CPU has room for |
| How does the chip search the residual? | **A replay channel in the spectrogram engine** (F5): a ninth, internal "receiver" whose audio is the residual buffer in DDR3 instead of a live capture ring. It runs frame after frame at full speed, into its own spectrogram area. When its frame 371 is in DDR3 the **sync engine (F6) starts by itself** on that spectrogram and writes its records to their own area | F5's transform, F6's search and F7's filters run unchanged, so they stay bit-exact with the models. F7 already replays any audio ring (`cand_cap_base`) |
| How is the one engine shared with the live capture? | Live frames go first. The scheduler takes a replay frame only when no live receiver has a frame due. A live frame can wait for at most one replay frame (0.24 ms; a live frame is due every 40 ms per receiver). The capture of the live audio into DDR3 is a separate block and is never held | No second FFT, no second accumulator |
| Raise the candidate count instead? | Not as the fix. The scheduler's count policy stays as it is (it already climbs from 60 by 10 per slot, up to 150, while a slot leaves headroom) | 100 candidates finds `K1BZM DK8NE` in one pass but can never find `KD2UGC F6GCP`, which needs subtraction. 30 more first-pass candidates cost 60 to 100 M instructions per slot (most fail, and a failed candidate is the dearest); the second pass finds both messages at the count the policy has |
| Which receivers? | **The operator's receiver** (scheduler's rule: two passes only there). The chip side is not the limit: one replay takes about 0.14 s of chip time, so several would fit; the CPU allowance is (section 4) | Owner brief |
| Block RAM, DSP | **None added.** The new state is registers; the residual, its spectrogram and its records live in DDR3 | Block RAM is the scarce resource |
| A chip step of the second pass fails | That slot's second pass runs on the software models (the earlier `HybridFabric` path), under the same CPU cap; the next slot uses the chip again | Owner ruling 2026-10-12: fall back for that slot only, never for good |

## 3. The chip side

### 3.1 Spectrogram engine (`rtl/ft8/ft8_spectrogram.v`)

New inputs: `rp_start` (pulse), `rp_cap_base` (residual audio, lane-word address; sample 0 of the
slot is sample 0 of the buffer, 4 samples per lane word as in the capture rings), `rp_spec_base`,
`rp_sh` (power shift). New outputs: `rp_frame` (frames done, 0 to 372), `rp_busy`, `rp_done` (pulse
when frame 371 is in DDR3).

- `rp_start` sets the frame counter to 0 and marks the replay active.
- In the idle state the scheduler picks a live receiver if one is ready (as before); otherwise, if
  the replay is active, it picks the replay. The replay's settings enter the same registered
  settings word the receivers use (one more input of a registered select), so the frame path is
  the same hardware.
- A replay frame raises no frame interrupt and does not touch the receivers' round-robin pointer.
- The slot reader, frame core, power stage and ring writer are unchanged.

### 3.2 Sync engine (`rtl/ft8/ft8_sync.v`)

New inputs: `alt_start` (pulse), `alt_rx` (the receiver whose band applies), `alt_spec_base`,
`alt_rec_base`. New output: `irq_alt` (with `irq`: the finished search was the residual's).

- One more pending request next to the eight receivers'. A receiver's own search goes first.
- The search itself is unchanged; only the two base addresses come from the `alt_*` inputs.

### 3.3 Registers (`hw/regmap/ft8.toml`, page 0xE80D_0000; the id becomes version 2)

| Register | Offset | What |
|---|---|---|
| `p2_frame` | 0x01C | Read only: replay frames written, 0 to 372 |
| `p2_cmd` | 0x030 | Write starts the replay and, after it, the search. Field `rx`: the receiver whose band and power shift apply |
| `p2_base` | 0x034 | The 4 MB DDR3 area of the second pass, a lane-word address that is a multiple of 2^19 (only the upper 8 bits are stored). From the base, in lane words: 0 the residual audio the CPU wrote (45,000), 0x1_0000 the residual's spectrogram (372 x 512), 0x4_0000 its sync records |
| `status.p2_busy` | 0x00C bit 4 | From `p2_cmd` until the records are in DDR3 |
| `irq_status.p2_done` | 0x004 bit 10 | The residual's records are in DDR3 |

F7 needs nothing new: pass 1 of a second-pass candidate is the existing command with
`cand_cap_base` = `p2_base` and `cand_first_sample` = 0.

### 3.4 Gowin manuals

The change uses flip-flops and look-up tables only: no multiplier, no block RAM, no LUT RAM, no
clock or constraint change. So no figure from the DSP, memory or clock guides enters this design.
The rules it follows are the ones already taken from those manuals and from the measured runs,
recorded in `docs/TANG_LESSONS.md` sections 3 and 6: wide registers load through enables that are
register outputs, selects of wide words are registered, no state decode drives a wide load enable.

## 4. Time inside the 15 s cycle

Chip time, at 150 MHz:

| Step | Time |
|---|---|
| Replay: 372 frames x 36,103 clocks (F5's measured frame, alone) | 89.5 ms |
| Live frames in between (8 receivers, 4.8 % of the engine) | about 5 ms more |
| Sync search of the residual (F6 measured) | 47 ms |
| **Replay and search** | **about 0.14 s** |
| Second-pass candidates, 35 pairs x 1.53 ms (F7 measured) | 54 ms, spread through the CPU work |

CPU time (800 MHz, 0.7 instructions per cycle = 560 M instructions per second), operator's receiver:

| Step | Instructions | Ends after the slot end |
|---|---|---|
| Sync search of the slot (chip) | | 0.05 to 0.1 s |
| First pass | 124 to 174 M | about 0.4 s: **first-pass decodes go to the station here** |
| Read the audio, subtract, write the residual | 31 to 140 M + about 6 M | 0.5 to 0.65 s |
| Replay and search (chip; the CPU decodes another receiver meanwhile) | | 0.65 to 0.8 s |
| Second pass (fine sync, soft symbols, LDPC) | 176 to 246 M | **about 1.0 to 1.3 s** |

The whole second pass is 207 to 386 M instructions per slot (FT8_CPU 3.2, measured under QEMU
from recorded engine words) plus the 6 M for moving the audio. That is inside the operator's cap
(945 M for both passes; 335 to 565 M used). Eight receivers with the operator's second pass:
1,355 to 1,584 M of the 3,150 M slot budget, the figure FT8_CPU 4.1 already planned with.

The next slot's own results are needed 15 s later. The replay is over about 0.8 s into the next
slot; that slot's capture runs untouched and its live frames keep priority.

## 5. The firmware side

- `tr_modes::frontend::decode`: `decode_slot` is split into steps (`SlotDecoder`: first pass,
  subtraction, second pass) so the caller can hand out the first pass's decodes and do other work
  while the chip replays. `decode_slot` itself is those steps in a row, with the same results.
- `tr_modes::frontend::replay`: the model of the replay (residual buffer layout, spectrogram and
  records of a residual), next to the F5 to F7 models.
- `tr_fabric::ft8fe`: `start_residual` (write the buffer, cache write-back, the 10 us wait, then
  `p2_cmd`), `residual_done`, `take_residual_sync`, `pass1_residual`. DDR3 map: residual audio
  0x14C0_0000, its spectrogram 0x14C8_0000, its records 0x14E0_0000 (one 4 MB area).
- `tr_station::chipdec`: `ChipDecoder::poll` works in steps instead of decoding every receiver in
  one call. Order: operator's first pass (event `Operator` with its decodes), subtraction and
  replay start, other receivers one per call, operator's second pass as soon as the replay is done,
  then the event `Decoded` with everything. The second pass is on by default when the chip's id
  says version 2 or later.
- The next slot's boundary is written as soon as every receiver's search of the old slot is done,
  not after all decoding.

## 6. Tests planned

| Test | What |
|---|---|
| `sim/ft8/tb_ft8_spectrogram.v` | A replay runs while three live receivers run: replay spectrogram bit-exact, live results unchanged, no frame interrupt for replay frames |
| `sim/ft8/tb_ft8_sync.v` | A residual search between the two ordinary ones: records at the alternate base equal the model's, `irq_alt` set |
| `sim/ft8/tb_ft8_frontend.v` | The new registers; `p2_cmd` to `p2_busy` to `p2_done` |
| `tools/check_ft8_pass2.sh` (long) | `qso1` and `qso3_busy`: the model's residual through the front end as the chip instantiates it (registers, replay, search, DDR3 with video traffic); records against the model; the decode from them must contain all 8 WSJT-X messages of `qso3_busy` |
| `cargo test -p tr-fabric --lib ft8fe`, `-p tr-station --test chip_decode`, `-p tr-modes` (decode path) | Driver rules for the residual; two passes through the chip model equal the two-pass model; failure falls back for one slot |

## 7. What was built and tested (2026-10-12)

| Test | Result |
|---|---|
| `sim/ft8/tb_ft8_spectrogram.v` | PASS: a replay next to three live receivers, 20,480 words bit-exact, one `rp_done`, no frame interrupt for replay frames; 35,900 clocks per frame |
| `sim/ft8/tb_ft8_sync.v` | PASS: three searches, the third the residual's (alternate bases, `irq_alt`), bit-exact |
| `sim/ft8/tb_ft8_frontend.v`, `tb_ft8_cand.v` | PASS |
| `tools/check_ft8_pass2.sh` (front end as in the chip, through its registers, DDR3 with video traffic) | PASS on both recordings: 0 of 190,464 spectrogram lane words and 0 of 929 records differ from the model |
| `sim/top/tb_sdr_core.v` (after merging master) | PASS |
| `cargo test -p tr-fabric --lib ft8fe` (7), `-p tr-station --test chip_decode` (8), `-p tr-modes --lib --test s17_sched --test fo1_effort` | pass; board image `ft8fw` builds |

Decodes (WSJT-X decodes 8 messages in `qso3_busy`; it has no reference list for `qso1`):

| Recording | One pass | Two passes, second through the chip |
|---|---|---|
| `qso3_busy`, 60 candidates | 15 messages, 6 of WSJT-X's 8 | 19 messages, **all 8** (`KD2UGC F6GCP R-23` and `K1BZM DK8NE -10` come in pass 2) |
| `qso1`, 60 candidates | 3 | 5 |

Chip time measured in the recording check, with video traffic: replay of 372 frames 92.4 ms,
search 42.2 ms, **`p2_cmd` to `p2_done` 134.6 ms**. No video underrun.

CPU cost of the second pass was not re-measured on the target: the CPU work is the code the QEMU
traces of FT8_CPU 3.2 already measured (207 to 386 M instructions per slot for the second pass with
its subtraction), plus moving the audio (180,000 samples read, 180,000 written: about 6 M,
estimated). Section 4's times follow from those.

## 8. Gowin: the whole front end alone (three runs, the budget)

`gowin/res.sh ft8_frontend --wrap --period-ns 6.35 --opt "place_option 3" --opt "route_option 1"
--sdc rtl/ft8/ft8_spectrogram.sdc rtl/ft8/ft8_frontend.v`. This is the first time F5, F6, F7 and
their DDR3 shares were measured together (the earlier figures were per engine: 153.6, 132.8, 120.6 MHz).

| | Run 1 (second pass in, DDR3 shares as before) | Run 2 (owner of a share registered) | Run 3 (shares in one level, read side one stage deeper, sync triggers, reader) |
|---|---|---|---|
| Fmax | 93.5 MHz | 105.5 MHz | 105.9 MHz |
| Failing end points | 345 | 271 | 338 |
| Logic / registers (block alone) | 23,206 / 19,671 | 23,197 / 19,685 | 23,502 / 20,539 |
| DSP | 32.5 | 32.5 | 32.5 |
| Block RAM (place-and-route count) | 13 | 13 | 14 |

- **Run 1.** The slowest paths were the chains of two-way DDR3 sub-arbiters (three in a row for
  writes, two for reads): each chose its owner combinationally from the idle clients' requests, so
  a request ran through every level into every other client's grant. Not a second-pass path; it
  had never been measured because the engines were measured one at a time.
- **Run 2.** Registered owner: that class is gone from the top; the grant's way back through three
  levels was still first (-3.1 ns, 80 % of it routing).
- **Run 3.** One level (`rtl/ft8/ft8_ddr3_mux.v`): the share is no longer among the failing
  classes. What leads now is routing between blocks, not logic depth: three or four levels of
  logic with 6 to 8 ns of wire (the sync engine's state to its own registers, fan-out 51; a
  register of the sync divider that Gowin merged with an equal one in the spectrogram's combine
  stage; the page's read select). The extra read stage of run 3 cost 850 registers and one block
  RAM and gained nothing, so **it was taken out again after the run** (the read side is run 2's).
- **Not measured: the final RTL** (run 3 minus the read stage, one `p2_base`, 27 address bits). No
  run was left. Expected from the runs: about 106 MHz alone, 13 block RAMs, about 19,300 registers.
- **The FT8 front end alone does not reach 150 MHz as one block.** F6's and F7's last fix rounds
  are now covered by a run, and their own logic is not what limits: the remaining failures are
  placement distance between the engines and the page's registers. The whole-chip build places
  them differently; its report is where this has to be judged next.
- One thing to check in the next run: the netlist of run 3 shows the page's write-enable decode
  built as a small ROM in a block RAM (`we_p2_rec`, 64 x 16). If the final RTL still has it, give
  the decode `syn_romstyle = "logic"`.

## 9. Registers (owner constraint of 2026-10-12: registers and slices are the scarce resource)

What the second pass itself adds: about 60 registers (8 bits of `p2_base`, the receiver number,
the power shift, the replay's frame counter and flags, the residual search's request flags, one
event bit). It was about 150 before the three base registers became one.

Whole FT8 front end, stand-alone counts (the chip's own count before this work: 19,246 registers):

| | Run 1 (second pass in) | Run 3 | Final RTL |
|---|---|---|---|
| Registers | 19,671 | 20,539 | about 19,300 (estimated, not measured) |
| LUT + adder cells | 23,206 logic in all | 13,451 + 5,423 | a little under run 3 |
| LUT-RAM cells | | 1,205 | 1,205 |

Cut in this work: the three second-pass bases into one (-88), 27 instead of 32 address bits in
every address register and adder of the three engines and the page (about -270), the read stage
of run 3 taken out again (-850), the sync engine's trigger rows no longer a register array.

Where the registers are (run 3's netlist):

| Unit | Registers | Mostly |
|---|---|---|
| Frame core (FFT, combine) | 5,061 | the FFT's delay chains kept in flip-flops: stage 3 1,269, stage 4 695, stage 5 391; three twiddle multipliers about 375 each; combine 530 |
| Candidate engine, two lanes | 882 + 2,599 + 2,528 | each lane's filter and DFT pipelines and delays |
| Sync engine | 2,863, of it the divider 1,043 | stream pipeline, divider ring |
| The page (per-receiver settings, read side) | 3,278, about 2,200 after the cuts | 8 receivers x (three bases, boundary, band, triggers) |
| Slot capture, power, reader, ring writer, scheduler | 2,254 | |

**A front end of about 12,000 registers** means taking out about 7,300. What it would take, none
of it measured:

| Step | Registers saved (estimate) | Cost |
|---|---|---|
| FFT delay chains of stages 3 to 5 into LUT RAM / SRL (the FFT's `SR_LUT` parameter) | 2,200 | about 250 LUT-RAM cells; timing risk: as LUT RAM the 128-word line once missed 150 MHz by 0.5 ns |
| One candidate lane instead of two | 2,600 (and 6 DSP, 1 block RAM) | candidate chip time doubles: 0.37 s to 0.73 s for 8 receivers x 60 candidates, about 45 ms more before the operator's first decodes |
| or: both lanes kept, their delays into SRL | about 1,500 | timing work inside the lanes (the block that measured 120.6 MHz) |
| Per-receiver bases into LUT RAM, read through the selects that exist | 600 | small |
| Sync divider as one stage used four times as long | 700 | search 42 ms to about 50 ms per receiver |
| Combine and power pipeline registers into SRL where they only delay | 500 | small |

With one candidate lane that is about 6,600, with two lanes about 5,500: 12,700 to 13,800
registers. The last 1,000 would have to come out of the sync engine's stream pipeline or the
twiddle multipliers, which were pipelined that deep to reach 150 MHz. It needs two to three
Gowin runs and a re-run of the recording checks.

## 10. What is left

- A Gowin run of the final RTL (section 8), and the register cuts of section 9 if the owner wants them.
- The CPU cost of the second pass on the target (section 7), and all of it on the board: the
  residual area at 0x14C0_0000 free, `p2_done` about 0.14 s after `p2_cmd`, the cache write-back
  of the 360 KB residual, the live capture undisturbed (`cap_overflow` stays 0).
- The second pass for more than the operator's receiver: the chip has the time (0.14 s each); the
  scheduler's CPU allowance is what limits it (207 to 386 M instructions each).
- With several receivers the other receivers' decodes still reach the main loop only in the final
  event; only the operator's go out early.
