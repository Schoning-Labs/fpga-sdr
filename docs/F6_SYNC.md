<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# WP F6 — FT8 Costas sync search engine

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Work package F6 (`docs/PLAN.md`, with the RB8 amendment on the same row), design in
`docs/ARCHITECTURE.md` 3.12 (c) and 3.14 change C9. Reference model: `sync_fx` in
`fw/tr-modes/src/frontend/sync.rs` (WP S15, `docs/S15_FT8MODEL.md`). Built together with F7
(`docs/F7_CAND.md`) on branch `f67`.

**Status (2026-10-12):** bit-exact on both recordings, in the chip (`rtl/ft8/ft8_frontend.v`).
Alone it measured 132.8 MHz; the fixes for what that run showed are in, and their effect is not
measured (section 4).

- `tools/check_ft8_sync.sh` on the final RTL: `qso1` 929 of 929 records equal the model's,
  `qso3_busy` 929 of 929; all 8 WSJT-X reference decodes of `qso3_busy` found; **47.1 ms per
  receiver** with video traffic (7,062,154 clocks), no video underrun.
- `sim/ft8/tb_ft8_sync.v` PASS (early search over 295 rows and the full search).

## 1. What this builds

At the end of each slot, and at up to two early-decode points before it, the engine searches one
decoder receiver's spectrogram (written to DDR3 by F5) for the FT8 Costas pattern. For every
carrier bin in the band it finds the best time lag and its score, and writes an 8-word record per
bin to DDR3. The CPU builds the candidate list from these records (`frontend::candidates`,
unchanged).

| File | What |
|---|---|
| `rtl/ft8/ft8_sync.v` | The engine: requests and triggers, row streaming, per-carrier sums, divider feed, best-lag tracker, record writer |
| `rtl/ft8/ft8_sync_div.v` | The score divider: `min(floor(6t x 2^16 / d), 2^32 - 1)`, a 4-stage ring with 8 laps, one division per 8 clocks |
| `rtl/ft8/ft8_ddr3_rdmux.v` | 2-way read sub-arbiter: F5's slot reader, F6 and F7 share the read lane's "rest" tier |
| `sim/ft8/tb_ft8_sync.v` | Unit test: two searches (early trigger at 295 frames, then the full 372) over 31 bins of `qso1`, through DDR3 with video traffic, against the model |
| `sim/ft8/vectors/f6_qso1_*.hex` | Its vectors: 22 lane words of each of the 372 spectrogram rows, and the model's records |
| `tools/check_ft8_sync.sh`, `sim/ft8/ft8_sync_wav_harness.v` | Full-recording check: the whole band of `qso1` and `qso3_busy`, records against the model, candidate list and decodes |
| `fw/tr-modes/src/frontend/sync.rs` | `sync_fx_rows`: the model over the first `n_rows` frames (early decode); `sync_fx` is `sync_fx_rows(.., 372)`, unchanged |
| `fw/tr-modes/src/bin/ft8_frontend.rs` | `sync-vectors` and `sync-check` commands |
| `sim/ddr3/ddr3_lane_behav_model.v` | New parameter `BEAT_SKIP` (section 2.5); 0 (the default) leaves every earlier test unchanged |

## 2. Design

### 2.1 RB8: rows in lag order, no stripe buffer

The model's quantities, for carrier i and lag L, over the 21 Costas rows
`m = 13 + 4 (COSTAS_POS[b] + n) + L`:

- `t` = sum over the rows of the cell at the expected tone, `S[m][i + 2 COSTAS[n]]`;
- `t0` = sum over the rows of the 7 tone cells `S[m][i + 2k]`, k = 0 .. 6;
- the score of blocks 1 and 2 alone, and of all three blocks; `sync` is the larger.

A pass covers 64 carriers (32 carrier pairs, the first carrier even; a carrier outside
`ia .. ib` is computed and not written). For each lag in ascending order the engine reads the 21
row segments from DDR3: bins `cs .. cs + 75`, 38 lane words per row, one burst each. Rows are
read in the block order 1, 2, 0, so after 14 rows the sums hold blocks 1 and 2 and after 21 all
three. A row outside `0 .. n_rows - 1` is streamed as 38 zero words without a DDR3 read.

The words are processed as they arrive, one lane word (two bins, one carrier pair) per clock, with
no row buffer:

- an 8-word delay line and two running sums (even and odd bins) give each carrier's 7-cell sum
  `S[i] + S[i+2] + ... + S[i+12]` when bin `i + 12` arrives: `E(k) = E(k-1) + lo(k) - lo(k-7)`;
- the expected-tone cell is word `k - 6 + COSTAS[n]` of the delay line;
- per carrier pair, `t` (37 bits) and `t0` (40 bits) for both carriers are one 154-bit entry of a
  32-entry LUT RAM, read and written back one clock apart. The first row of a lag writes instead
  of adding, so no clearing pass is needed.

### 2.2 Queue and divider

When row 14 and row 21 of a lag stream, each carrier pair's sums go into a 32-entry job queue
(LUT RAM). A row that pushes waits until the queue is empty, so it never overflows. The queue
feeds the divider one carrier at a time through four registered steps: the queue head, `6t` and
`t0 - t`, `d = t0 - t + 6`, and the saturation test.

`ft8_sync_div.v` computes the score exactly: saturated when `(6t >> 16) >= d`, otherwise 32
steps of restoring division starting from the remainder `6t >> 16`. The four stages form a ring;
a job makes 8 laps, so one job finishes every 8 clocks and at most 4 are in flight. That is 1,024
clocks per lag for 64 carriers, while the lag's 21 rows take about 3,600 clocks to read with
video running. A 32-stage pipeline (one per clock) would cost about four times the logic for
speed the engine cannot use. Results leave in the order the jobs came in, into an 8-entry FIFO.
Jobs in flight plus results waiting never exceed 7, so the FIFO cannot overflow.

### 2.3 Best-lag tracker

One 1,024 x 36 BSRAM, 16 words per carrier:

| Word | Contents |
|---|---|
| 0 | the carrier's score at the previous lag, plus the two "pending" flags |
| 1, 3, 4, 7 | primary window: best score, score at best - 1, score at best + 1, best lag |
| 2, 5, 6, 9 | secondary window, the same |
| 8 | this lag's blocks-1-and-2 score |

A blocks-1-and-2 result is one write to word 8. An all-blocks result reads words 8, 0, 1 and 2,
forms `sync = max`, and decides:

- new primary best when the lag is -10, or the lag is in -10 .. 10 and the score is strictly
  greater than the best so far (the first maximum wins, as in the model's ascending scan);
- new secondary best at lag -63, or when strictly greater.

Then up to 7 writes. At a new best: the best score, the previous lag's score as "best - 1", and
the lag. The "best + 1" score is written one lag later (the pending flag). A best at lag 63 keeps
its pending flag, and its "+1" score is read out as 0, which is the model's `at(64)`. At lag -63
the previous score counts as 0, which is the model's `at(-64)`.

After the pass's last lag, every carrier's record is read out (9 reads) and written as 4 lane
words, one 4-beat burst, to `rec_base + 4 (i - ia)`. That is the model's `BinSyncFx::to_words`
order, word 2k in the low half.

### 2.4 Triggers and scheduling

- Per receiver: `trig1` and `trig2` (frame counts, 0 = off) and the slot end (frame 372).
- When the receiver's F5 frame counter reaches one of them, a search over that many rows is
  queued. `slot_start` re-arms all three.
- `cmd_start` queues a search directly (over whatever is at the receiver's `spec_base`).
- `alt_start` (second pass, `docs/FT8_PASS2.md`) asks for one more search, next to the eight
  receivers': over the residual's spectrogram at `alt_spec_base`, records to `alt_rec_base`, with
  the band of receiver `alt_rx`. A receiver's own search goes first. Its interrupt carries
  `irq_alt`; the front end turns that into `irq_status.p2_done` instead of `sync_done`.
- One search per receiver can be pending, and a later one with more rows replaces it.
  Receivers are served round-robin, and the pick is registered, as in F5's scheduler.
- `irq` with `irq_rx` and `irq_rows` fires when all of a search's records are in DDR3.
  `run_clocks` is that search's length.

**Early decode in the model.** ARCHITECTURE 3.12 (c) says the early runs at 11.8 s and 13.5 s
are not modelled. `sync_fx_rows(s, band, n_rows)` is the model's own search with rows from
`n_rows` on counted as outside the slot, exactly as rows past 371 are. It is what the engine
computes for an early trigger, and the unit test checks it bit for bit at 295 rows. How
mfsk-core treats a partly filled spectrogram (its `PartialBlock2` policies) is a decoder
decision for the firmware. The fabric gives the searches over any number of rows.

### 2.5 DDR3 test setup

The engine runs on `clk_dsp` (120 MHz; the figures below were measured with a 150 MHz simulation clock) and the DDR3 lanes on a 100 MHz clock (ARCHITECTURE
section 2). The testbenches run one 150 MHz clock and throttle the behavioural lane model to the
100 MHz lane rate with the new `BEAT_SKIP = 3`: no data beat on every third clock, so 2 beats per
3 clocks, 800 MB/s. Everything else follows F4's documented traffic mix:

- read latency 9 clocks (6 lane clocks);
- random stalls: 3 % chance per clock, runs of 1 to 32 clocks;
- F4's video scan-out model on the top read tier, at the 1080p60 Slint-plus-full-screen-waterfall
  rate (720 lane words per line, 2,222 clocks per line at 150 MHz);
- an IQ writer on the top write tier;
- a background reader standing in for F5's slot reader, sharing the "rest" tier through
  `ft8_ddr3_rdmux.v` with priority over F6.

The clock crossing between the two domains is not modelled. F5 was tested the same way.

## 3. Time per search

**Measured in `sim/ft8/ft8_sync_wav_harness.v`: 6,923,008 clocks for the band 100 - 3,000 Hz
(929 carriers, 15 passes), 46.2 ms at 150 MHz**, with video running and no video underrun. The
figure is the same for both recordings, because the timing does not depend on the data.

This is DDR3-bound:

- 15 passes x 127 lags x 21 rows x 38 words = 1.52 M lane words, about 0.22 words per clock.
- The divider needs 1,024 clocks per lag, and a lag takes about 3,600.
- About half of the lane's time goes to video bursts. A row request that arrives during one
  waits up to 280 clocks.

For 8 receivers searched one after another: 0.37 s after slot end. ARCHITECTURE C9 estimated
52 ms per receiver and 0.42 s for all 8.

## 4. Resources and Fmax

`gowin/res.sh ft8_sync --wrap --period-ns 6.35 --opt "place_option 3" --opt "route_option 1"
rtl/ft8/ft8_sync.v` (150 MHz with 5 % margin):

| | Run 1 (RTL of the pause) | Run 2 (after the first rebuild) |
|---|---|---|
| Fmax | 94.1 MHz | **132.8 MHz** |
| Failing end points | 1,521 | 76 |
| Logic / registers (block alone) | 3,749 / 3,141 | 5,009 / 3,709 |
| Block RAM (place-and-route count) | 22 | **2** (the tracker; limit 3) |
| DSP | 0 | 0 |

What run 1 showed, and the rebuild (docs/TANG_LESSONS.md sections 3 and 6):

- The accumulator and the job queue (32 words of 154 and 167 bits) had become 20 block RAMs.
  They are LUT RAM now, in two memories each, with registered addresses.
- The 8-word delay line (512 flip-flops on one load enable decoded from the state and the lane's
  `rvalid`) is two 16-word LUT RAMs. The stream pipeline has six stages and no load enable: a
  clock without a word adds zero.
- The running 7-bin sum was two adders in one clock; the difference is formed a clock earlier.
- The divider step (41-bit subtract, then a select on 41 loads) takes two clocks: low half, high
  half, and the select at the start of the next step from a registered flag. The ring has 8
  registers; a job still takes one slot for 64 clocks and one finishes every 8.
- The divider feed's four stages run freely behind the queue's read pointer; the hand-over to
  the divider is decided one clock ahead (`in_take`).
- The tracker writes its words in a fixed order of 8 clocks instead of finding the lowest set bit.

What run 2 showed (all in the main sequencer, worst -1.18 ns), fixed after it and **not
re-measured** (the Gowin run budget was used up; `tb_ft8_sync.v` and the recording check ran on
the result):

- state decode as the load enable of the job settings, the row registers and the record
  registers: these load through flags registered one clock ahead;
- the "everything drained" test in the state path: registered;
- the round-robin pick: two registered steps, and two wait states before idle;
- the queue head's load enable on the divider's take: moved a clock later onto kept copies.

Left from run 2 and not touched: the trigger bookkeeping (`pend_rows`, -0.01 ns).

Time per search rose from 46.2 to 47.1 ms (the feed takes 8 clocks per job instead of 7).

## 5. Done-tests

**1. Per-bin results equal the S15 model: met.**

- `tools/check_ft8_sync.sh`, full band (bins 32 .. 960, 929 carriers) through DDR3 with video:
  `qso1` 929 of 929 records equal the model's, and `qso3_busy` 929 of 929.
- `sim/ft8/tb_ft8_sync.v`: 31 carriers (401 .. 431), one early search over 295 rows and one full
  search, all 248 lane words equal. `PASS`. The band starts on an odd carrier, so the first
  pass's carrier 400 is computed and masked.

**2. The model's candidate list built from them contains every signal WSJT-X decodes: met for
`qso3_busy`. `qso1` has no WSJT-X reference.**

`ft8-frontend sync-check` builds the candidate list from the RTL's records (60 candidates,
threshold 1.3, `frontend::candidates` unchanged) and runs the S15 two-pass decode from it.

- `qso3_busy`: all 8 of WSJT-X's reference decodes (`tests/wsjtx_samples.rs`) are decoded.
  - 6 come straight from the pass-1 list built from the RTL's records, each within 1.5 Hz and
    0.05 s of a candidate.
  - The other 2, `K1BZM DK8NE -10` and `KD2UGC F6GCP R-23`, are not in the pass-1 list, and
    WSJT-X itself finds them only after subtracting the first pass's decodes (S15 section 4.1).
    Here they come from the pass-2 list, which F6 builds from the residual's spectrogram. In this
    check that list comes from the model: the RTL equals it bit for bit on both recordings'
    spectrograms. They are candidates 52 and 2 of that list.
  - 19 messages in all, as S15 reported.
- `qso1`: WSJT-X has no reference decode of this file (`docs/S5_MODES.md`, "Real recordings";
  WSJT-X is not installed here). Instead the check covers all 5 messages the S15 decoder finds in
  two passes: 3 are in the pass-1 list built from the RTL records, and 2 in the pass-2 list.

**3. Sync search at most 60 ms per receiver in simulation with F4's video traffic: met, 47.1 ms**
(section 3). No video underrun; the lowest video FIFO fill was 1,204 of 1,440 words.

**4. BSRAM at most 3: met, 2** (section 4).
