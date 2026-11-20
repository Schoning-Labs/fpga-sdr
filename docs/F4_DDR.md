<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# F4 - DDR3 lane arbiters and waterfall writer

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Work package F4 (docs/PLAN.md), design section docs/ARCHITECTURE.md 3.9 (DDR3 sharing and
bandwidth) and 4.2 (data movement); board facts docs/BOARD.md "DDR3 shared with fabric" and open
question 8; port list from Gowin's RiscV_AE350_SOC Hardware Design Manual, MUG1031-1.3.1E,
section 5, table 5-1 (downloaded and read directly for this WP - BOARD.md's own citations only
summarise it). Everything here is simulation-only (iverilog); the board has not arrived yet
(docs/DECISIONS.md: expected 2026-09-29).

## 1. What this builds

Two arbiters that put several fabric masters onto the AE350's two "Shared DDR3: Logic R/W Mode"
lanes (BOARD.md), in the priority order docs/ARCHITECTURE.md 3.9 states, plus the waterfall line
writer named in this WP's own row in docs/PLAN.md:

```
IQ writer ----\
waterfall writer -+-- ddr3_write_arbiter --> write lane (lane4) --\
raw capture ------/                                                +-- shared DDR3
video scan-out ---\                                                |
audio ring reader -+-- ddr3_read_arbiter --> read lane (lane5) ----/
TX ring reader ----/
the rest ---------/
```

Files:

| File | What |
|---|---|
| `rtl/ddr3/ddr3_write_arbiter.v` | write-lane arbiter: IQ writer > waterfall writer > raw capture |
| `rtl/ddr3/ddr3_read_arbiter.v` | read-lane arbiter: video > {audio, TX} (round-robin) > the rest |
| `rtl/video/waterfall_writer.v` | byte-stream-in, DDR3-ring-out waterfall line writer (this WP's other deliverable) |
| `sim/ddr3/ddr3_lane_behav_model.v` | behavioural model of both lanes, MUG1031 table 5-1's port list, one shared memory, random stalls |
| `sim/ddr3/write_traffic_client.v`, `read_traffic_client.v` | synthetic clients at a configurable bandwidth, standing in for real WPs that do not exist yet (IQ writer, audio/TX ring readers, raw capture) |
| `sim/ddr3/video_scanout_model.v` | video reader traffic model with a prefetch-FIFO margin measurement (this WP's central done-test instrument) |
| `sim/ddr3/tb_ddr3_write_arbiter.v` | write-lane data-integrity done-test, realistic traffic mix |
| `sim/ddr3/tb_ddr3_write_arbiter_priority.v` | write-lane priority-order done-test, saturating traffic |
| `sim/ddr3/tb_ddr3_read_arbiter.v` | read-lane data-integrity and priority-order done-test |
| `sim/ddr3/tb_waterfall_writer.v` | waterfall writer unit test: byte packing, ring wraparound, readback |
| `sim/ddr3/tb_ddr3_video_no_starve.v` | the combined done-test: full documented traffic mix, random stalls, video-starvation measurement |

All pass under `bash tools/check.sh`.

## 2. Assumptions this WP had to make, and why

MUG1031 table 5-1 and docs/BOARD.md leave real gaps; here is every place this WP filled one in,
so a later reader (or the board) can check it:

1. **Burst length is not capped at 8 words.** `burstcount_lane4`/`burstcount_lane5` are `[7:0]`
   fields (MUG1031 table 5-1) - an **8-bit field**, values up to 255, not "bursts of up to 8
   words". docs/BOARD.md's summary ("burst count up to 8 bits") is easy to misread the second
   way; an earlier version of this WP's video traffic model did exactly that, using 8-word
   bursts, and its own done-test caught the consequence - see section 4.
2. **Data/mask width in the 64-bit configuration.** The table shows the data field as
   "`[63:0]` / `[31:0]`" (the IP's two configurable widths) but only ever shows a 4-bit
   `wr_mask_lane4`, sized for the 32-bit option. This design uses the 64-bit option
   (docs/ARCHITECTURE.md 3.9), so `sim/ddr3/ddr3_lane_behav_model.v` and both arbiters use an
   **8-bit write mask** (one bit per byte of the 64-bit word) as the natural extension - not
   independently confirmed, since neither the manual nor the Gowin AE350 IP (not installed in the
   Education edition available on this PC, docs/BOARD.md "Toolchain") could be checked directly.
3. **The address field's units.** Table 5-1 does not say whether `addr_lane4`/`addr_lane5` count
   bytes or lane-words. This WP treats it as a lane-word (64-bit) address throughout, which is
   the more common convention for a fixed-width burst port; if the real IP counts bytes instead,
   every address in the arbiters, the waterfall writer, and the traffic models needs an
   `<< 3`/`>> 3`, but no other logic changes.
4. **No multiple-outstanding requests.** MUG1031's handshake (`..._en`, `..._go`, `..._wait`/
   `..._rdy`, `..._done`) reads as a single-transaction interface, and
   `sim/ddr3/ddr3_lane_behav_model.v` models it that way: one burst in flight at a time, a fixed
   `RD_LATENCY` (default 6 clocks) from a read request's acceptance to its first data beat, paid
   again on every new burst. If the real IP can accept a second request while the first is still
   completing (a real DDR3 controller normally can), the numbers in section 4 are pessimistic;
   this WP could not check either way before the board arrives.
5. **A granted burst always runs to completion once started**; the random-stall model
   (section 3) only ever blocks the *acceptance* of a new burst, never a burst already in
   progress. Chosen deliberately, not as a simplification of convenience: it is what keeps a
   lower-priority client's worst-case cost to the client above it bounded to one burst, however
   long that burst is (see section 4's burst-length trade-off) - an unbounded mid-burst stall
   would defeat that bound entirely, and docs/ARCHITECTURE.md 3.9's own open question is about
   how long the controller can hold a lane *off*, not about interrupting a transfer already under
   way.
6. **"The rest" tier has no documented occupant or bandwidth number** (docs/ARCHITECTURE.md 3.9's
   budget table lists nothing there). This WP's F4 task description calls it "CPU-visible rings", so the
   read arbiter gives it a real, working tier (not a dead port) and the traffic mix gives it a
   small nominal background rate (section 3), rather than assuming it is silent.
7. **The waterfall writer's 0.2 MB/s combined figure covers two ring instances** (full-band and
   zoom waterfalls, docs/ARCHITECTURE.md 3.5: "per waterfall a DDR3 ring") sharing one write-lane
   priority tier. `rtl/video/waterfall_writer.v` is written as one reusable module meant to be
   instantiated twice; the done-tests model the write-lane traffic of both combined as one
   synthetic client rather than two smaller ones, since it is the arbiter's behaviour being
   tested, not the module's own internals twice over (that is `tb_waterfall_writer.v`'s job).
8. **The video reader's Slint-layer and waterfall-scan-out prefetch FIFOs are modelled as one
   combined FIFO**, not the two separate ones the real V2 compositor (blocked by this WP) will
   have. This is conservative, not optimistic: a shortfall feeding *either* real stream shows up
   as a drop in the combined model's fill, so a margin measured here is a lower bound on what
   two correctly-sized separate FIFOs would show, not an upper one.
9. **DDR3 write latency is not modelled** (only the read side has `RD_LATENCY`). Real DDR3 writes
   do have their own latency, but since it doesn't stall the writer's *next* request the way CAS
   latency stalls a *read*'s next request in this design (writes only need `wr_wait`/`wr_done`,
   not a data return), leaving it out does not change which client wins arbitration or how much
   of the write lane's bandwidth is available - it only means this model's write-side MB/s
   numbers (section 4) are a hair optimistic relative to a real controller with non-zero write
   latency too.

## 3. Bandwidth arithmetic, re-derived from docs/ARCHITECTURE.md 3.9's table

The architecture doc gives "about 374 MB/s" read lane and "about 179 MB/s" write lane without
showing which of its budget rows go to which lane. Re-deriving it (necessary to build the traffic
clients at all) turns up a fact worth recording: **the "CPU (code and data misses, Slint
drawing)" row, about 200 MB/s, is not fabric-lane traffic at all.** The CPU reaches DDR3 through
its own AE350 "DDR3 Data Memory" port (BOARD.md), a *third* path into the physical DDR3 die,
separate from the two fabric lanes these arbiters own; it competes with the fabric lanes only
inside the shared DDR3 controller itself (BOARD.md open question 8), which is exactly what this
WP's random-stall model (section 4) stands in for, not something either arbiter schedules.

| Row (docs/ARCHITECTURE.md 3.9) | Lane | MB/s |
|---|---|---|
| Slint layer scan-out | read (video) | 248.8 |
| Waterfall scan-out, worst case full screen | read (video) | 124.4 |
| Audio + TX rings | read (audio, tx) | 0.4 (0.192 + 0.192, rounds to 0.4) |
| **Read lane total** | | **373.6 (doc: "about 374")** |
| Waterfall writes | write (waterfall writer) | 0.2 |
| IQ writes, 8 receivers at 384 k | write (IQ writer) | 24.6 |
| Raw capture (debug only) | write (raw capture) | 153.6 |
| **Write lane total, capture on** | | **178.4 (doc: "about 179")** |
| CPU code/data/Slint-drawing misses | *not a fabric lane* - CPU's own DDR3 port | 200 (excluded above) |

Both lane totals match docs/ARCHITECTURE.md 3.9's rounded figures exactly once the CPU row is
excluded, confirming the doc's arithmetic - the ambiguity was only in which rows summed to which
number, not the numbers themselves.

Traffic-client cadence used in the done-tests (100 MHz / 8 B-per-word lane, so 1 word = 12.5 MB/s
at one word per clock):

| Client | Target | Burst | Cycles/burst (bandwidth-derived) |
|---|---|---|---|
| IQ writer | 24.6 MB/s | 4 words (32 B) | 32 / 24.6 MB/s = ~130 clocks |
| Waterfall writer (both instances) | 0.2 MB/s | 8 words (64 B) | 64 / 0.2 MB/s = ~32,000 clocks |
| Raw capture | 153.6 MB/s | 8 words (64 B) | 64 / 153.6 MB/s = ~42 clocks |
| Audio ring reader | 0.192 MB/s | 1 word (8 B) | 8 / 0.192 MB/s = ~4,167 clocks |
| TX ring reader | 0.192 MB/s | 1 word (8 B) | 8 / 0.192 MB/s = ~4,167 clocks |
| "The rest" (nominal) | - | 1 word (8 B) | 5,000 clocks (assumption 6) |
| Video (Slint + waterfall combined) | 373.2 MB/s | 180 words (1,440 B) | via `sim/ddr3/video_scanout_model.v`'s continuous-fill/drain model, not a fixed period (section 4) |

(An earlier pass of this WP's write-side testbenches used the wrong cycle counts for IQ and the
waterfall writer - 13 and 1,667 instead of 130 and 32,000 - a plain unit slip in the first draft
of this table, caught by `tb_ddr3_video_no_starve.v` reporting each client's measured MB/s
against its target and finding IQ running at 5-6x its documented rate. Fixed before any number in
section 4 was taken.)

## 4. Done-test: video starvation under the documented traffic mix

`sim/ddr3/tb_ddr3_video_no_starve.v` runs every client in section 3's table at once, through
both arbiters and one shared `sim/ddr3/ddr3_lane_behav_model.v`, with random lane stalls
(`STALL_NUM`/`STALL_DEN`/`STALL_MAX_CYCLES`) standing in for the CPU holding the physical DDR3
off (docs/BOARD.md open question 8). `tools/check.sh` runs it once, 600 video lines, at this
WP's documented default assumption: a 3.0% chance per idle clock that a stall run starts, each
run 1-32 clocks (up to 320 ns) long - a burst of short, frequent interruptions, not one long one.
Margin numbers below are from longer hand runs (`-PLINES_TO_RUN=4000`, several hundred full
screens) at various `-P` overrides, to sample enough stall events for the worst case to settle
and to probe past what the default run alone would show.

### 4.1 A real bug this measurement caught

The first version of this done-test failed outright - video underran tens of thousands of times
- and not because of the stall model. Two bugs, both fixed and now regression-tested by this
same testbench:

1. **Wrong bandwidth-to-clock-period arithmetic** for the IQ writer and waterfall writer traffic
   clients (13 and 1,667 clocks between bursts instead of the correct 130 and 32,000 - see
   section 3's note). Both clients were running 5-19x their documented rate, saturating far more
   of the write lane than the real design would.
2. **An 8-word video burst leaves almost no margin.** Section 2, assumption 1: MUG1031's
   `burstcount` is an 8-bit *field*, not a burst cap of 8. At 8 words/burst, the read lane's
   modelled per-burst pipeline-fill cost (`RD_LATENCY`, 6 clocks, paid again on every new burst
   since this model has no multiple-outstanding-request pipelining, section 2 assumption 4) ate
   most of the lane's usable time: 8 useful beats per (6 + 8 + 1 settle) = 16 clocks is only 50%
   of the lane's raw word-rate capacity actually usable - and video's own demand (373.2 MB/s of
   the lane's 800 MB/s peak, i.e. 46.7% of the raw rate) then needed essentially the *entire*
   usable half just to keep up with itself - **before** any stall, and before audio, TX or "the
   rest" took their (tiny) share. Measured: 38,041 underruns in 600 lines with stalls switched
   **off** entirely.

   Fixed by giving the video reader 180-word bursts instead (`sim/ddr3/video_scanout_model.v`):
   180 / (6 + 180 + 1) = 96.3% of raw word rate is useful, comfortably inside budget. With
   stalls off, video now reaches 388.76 MB/s (above the 373.2 MB/s it needs) with the FIFO
   never dropping below 1,256 of 1,440 words (87.2% headroom).

   This is a real, if narrow, finding for the eventual real hardware: **the video reader's burst
   length matters a lot**, and 8-word bursts (an easy number to reach for, being the field's
   apparent "natural" size) would likely leave the real design without the margin
   docs/ARCHITECTURE.md 3.9 assumes it has - see section 5.

### 4.2 Priority order and data integrity

Covered by the other four testbenches (section 1), not repeated here: write-lane and read-lane
priority order hold under saturating contention (`tb_ddr3_write_arbiter_priority.v`,
`tb_ddr3_read_arbiter.v`), and every word/byte written by every client - IQ, waterfall,
capture, and `waterfall_writer.v` itself - reads back correctly under random stalls
(`tb_ddr3_write_arbiter.v`, `tb_ddr3_read_arbiter.v`, `tb_waterfall_writer.v`).

### 4.3 Video margin vs. stall duty cycle (short stalls)

Holding the stall run length short (1-32 clocks, 10-320 ns - the default assumption) and raising
how *often* one starts:

| Trigger chance/idle clock | Measured stalled-clock duty | Video underruns | FIFO min fill |
|---|---|---|---|
| 3.0% (default) | 33.3% | **0** | 85.6% |
| 5.0% | 46.3% | **0** | 85.6% |
| 8.0% | 59.1% | **0** | 85.0% |
| 15.0% | 74.5% | **0** | 83.9% |
| 30.0% | 87.7% | **0** | 82.7% |
| 50.0% | 94.3% | **0** | 81.8% |
| 70.0% | 97.5% | **0** | 75.0% |
| 90.0% | 99.3% | 26 | 0% |

Short, frequent stalls barely touch video: the lane is only ever off for a few hundred
nanoseconds at a time, well inside what a 180-word burst and an 87%-full FIFO absorb. Video
survives even a lane stalled 97.5% of the time, and only fails once the lane is stalled
essentially permanently (99.3%, a scenario with no realistic physical basis).

### 4.4 Video margin vs. a single stall's length (the real risk)

Duty cycle is the wrong axis. Holding the trigger *rare* (0.1% chance per idle clock - long
stretches of normal operation between events) and raising how long **one** stall run can be:

| Longest single stall | Equivalent time (100 MHz lane clock) | Video underruns | FIFO min fill |
|---|---|---|---|
| 1,000 clocks | 10.0 us | **0** | 87.2% |
| 1,500 clocks | 15.0 us | 808 | 0% |
| 2,000 clocks | 20.0 us | 1,869 | 0% |
| 2,500 clocks | 25.0 us | 40,211 | 0% |
| 2,900 clocks | 29.0 us | 77,716 | 0% |
| 3,200 clocks | 32.0 us | 94,145 | 0% |

**This is the number that matters, and the one docs/ARCHITECTURE.md 3.9 guessed at without a
measurement**: that section sized the video prefetch FIFO from "2 lines = 7.7 KB of Slint data,
about 30 us" - i.e. assumed the design could tolerate the shared DDR3 controller holding the
fabric lanes off for roughly 30 us. This model's measured breaking point is **between 10 and
15 us** - roughly half that assumption, not the "about 30 us" figure. A back-of-envelope check
matches the order of magnitude (FIFO capacity 1,440 words / drain rate 0.486 words/clock =
~2,962 clocks = ~29.6 us *if* the FIFO always starts completely full before a stall and nothing
else ever touches it), but the measured number is lower because, over a run with many stall
events and other read-lane clients also present, the FIFO is not reliably at full capacity when
a long stall lands.

### 4.5 What this means

- **Under this WP's documented default assumption** (3% chance/clock, runs up to 320 ns - short,
  frequent interruptions), video has a wide margin: zero underruns, worst-case FIFO fill 85.6%,
  and that holds all the way up to unrealistic (>97%) stall duty cycles.
- **The risk is not "how often" but "how long, once."** A single continuous stall past roughly
  10-15 us starts costing underruns; past 25-30 us it is severe. Whether the real shared-DDR3
  controller can ever hold a fabric lane off that long is exactly docs/BOARD.md open question 8,
  and this WP cannot answer it before the board arrives (or before T1's Gowin Standard licence
  unblocks inspecting the real AE350 IP). **WP B4 (shared-DDR3 stress on hardware) is where this
  gets a real answer**; until then, docs/ARCHITECTURE.md 3.9's "about 30 us" tolerance assumption
  should be treated as optimistic by roughly 2x against this model.
- **The fix, if B4 finds the real controller can block for that long, is not a bigger FIFO** (a
  sustained supply-vs-demand shortfall is what breaks this, not burstiness - no FIFO size saves
  it once the shared controller is unavailable for longer than the FIFO can bridge at the
  drain rate) but either a faster fallback (docs/ARCHITECTURE.md 3.9's own "Customized Data
  Memory" path with a purpose-built arbiter) or a larger prefetch bridging a genuinely longer
  worst case, sized from a measured number rather than an assumed one.

## 5. What is still open

- **The real V2 compositor must use a burst length well above 8 words for its DDR3 reads**
  (section 4.1) - this is the one recommendation this WP is confident enough to hand forward as
  more than a caveat. Whoever builds V2 should carry this design point over, not rediscover it.
- Board facts this WP could not check (assumptions 1-4, section 2) all affect the real margin;
  WP B4 (shared-DDR3 stress on hardware) is where they get checked for real. In particular: if
  the real shared-DDR3 controller can hold a fabric lane off for longer than about 10-15 us in
  one stretch (section 4.4), docs/ARCHITECTURE.md 3.9's prefetch sizing needs revisiting before
  B4, not after - see section 4.5.
- The Gowin AE350 IP itself was not available to inspect (Education edition, docs/BOARD.md); T1
  (Standard edition, needs a licence) blocks confirming any of MUG1031's table against the actual
  generated core.
- `rtl/video/waterfall_writer.v` is not wired to real register-block ports yet (T3, the register-
  map generator, is not built); `ring_base` is a plain input port, matching
  `rtl/audio/audio_ring_reader.v`'s same choice for the same reason.
- The real V2 compositor (blocked by this WP) will have its own Slint-layer and waterfall-scan-out
  prefetch FIFOs; assumption 8 (section 2) means this WP's margin number is conservative relative
  to that real design, not a substitute for measuring it once V2 exists.
- **Update (WP F5)**: the FT8/FT4 front end's slot capture and spectrogram ring writes needed
  DDR3 access this WP did not anticipate. The read side used tier 2 ("the rest", point 6 above)
  as designed, no change needed. The write side had no free tier — its three client ports are
  fixed and named — so `rtl/ddr3/ddr3_write_arbiter.v` gained a 4th, lowest-priority client port
  ("ft8"); see `docs/F5_FT8SPEC.md` section 2.5 for the traffic estimate (about 1.6 MB/s combined,
  negligible against this lane's ~179 MB/s) and why lowest priority is safe. The three
  testbenches this WP wrote (`sim/ddr3/tb_ddr3_write_arbiter{,_priority}.v`,
  `sim/ddr3/tb_ddr3_video_no_starve.v`) still pass unchanged (the new port tied off).
