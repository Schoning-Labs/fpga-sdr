<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# WP F5 — FT8/FT4 spectrogram engine

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Work package F5 (`docs/PLAN.md`; RB8 amendment, same PLAN row), design in `docs/ARCHITECTURE.md`
3.12 (b) and 3.14 change C9. Reference model: `fw/tr-modes/src/frontend/spectrogram.rs` and
`fft256.rs` (WP S15, `docs/S15_FT8MODEL.md`). New RTL: `rtl/ft8/`.

**Status (2026-10-12):** bit-exact, in the chip (`rtl/ft8/ft8_frontend.v`), and at 150 MHz alone.

| | Gowin alone, place 3 / route 1, constraint 6.35 ns (150 MHz + 5 %) |
|---|---|
| Fmax | **153.6 MHz**; 9 end points miss the 5 % margin by at most 0.16 ns, none misses 150 MHz |
| Logic / registers (block alone) | 6,927 / 7,152 |
| DSP | 20.5 |
| Block RAM (place-and-route count) | **9** (limit 10) |

What changed on 2026-10-12 (the older sections 4 and 5 below describe the state before):

- The slot reader's 32 x 64 FIFO is LUT RAM (it had become 4 block RAMs).
- The slot capture picks its receiver's ring base and pointer in two registered steps.
- The FFT's 128-word delay line is one block RAM (as LUT RAM its read missed by 0.5 ns); the
  FFT's stage-2 twiddle ROM went to LUTs on master (WP LS4), so the count stays 9.
- **The FFT's butterflies are two-clock paths** (`rtl/ft8/ft8_spectrogram.sdc`, added to
  `gowin/p1/build.sh`'s constraints and to `gowin/res.sh --sdc`). This FFT gets one sample every
  8 clocks, and inside a butterfly every register loads only with a sample, so those paths have
  8 clocks. The file names the FFT by its instance name `u_ft8fft`, which exists once in the chip.
  Without it the same netlist measures 137.5 MHz with 118 failing end points (the stage-2
  twiddle ROM's read and the butterfly adders, both inside `rtl/fft`).
- The power stage's saturation is a clock of its own (8 stages).
- The 9 end points left are of two kinds: the power stage's saturation (fixed after the run,
  not re-measured) and load enables of the FFT's stage-3 register chain (one net on 1,229
  flip-flops, inside `rtl/fft`, -0.05 ns).

Tests on the final RTL: `sim/ft8/tb_ft8_spectrogram.v` PASS (3 receivers, 15,360 words through
DDR3, 35,888 clocks per frame = 239 us; 8 receivers x 25 frames/s = 4.8 % busy). The
full-recording check (`tools/check_ft8_wav.sh`, 380,928 words) was last run before these changes;
they are pipeline changes that the end-to-end test covers.

**Second pass (2026-10-12, `docs/FT8_PASS2.md`).** The scheduler has a ninth source, the replay
channel: a whole slot of residual audio (the first pass's decodes subtracted by the CPU, written
to a DDR3 buffer) goes through the same reader, transform, power stage and ring writer into a
spectrogram area of its own, frame after frame, whenever no live receiver has a frame due.
`sim/ft8/tb_ft8_spectrogram.v` runs one next to three live receivers.

## 1. What this builds

Captures each decoder receiver's 12 ksps audio into DDR3, computes the 3,840-point (256 x 15)
spectrogram transform every 480 samples (40 ms) per receiver, and writes the resulting 1,024
power words per frame into a DDR3 ring — one shared engine, time-multiplexed across up to 8
receivers.

| File | What |
|---|---|
| `rtl/ft8/ft8_tw3840.v` | `W_3840^e` twiddle lookup: octant ROM (`rtl/ft8/rom/ft8_w3840_oct.hex`, 480 entries, one block ROM) plus the address decompose/sign-map, bit-exact with `tables::twiddle`; 9-clock pipeline |
| `rtl/ft8/ft8_combine.v` | RB8's accumulate-as-you-go combine stage: 1,024 x 88-bit accumulator, one shared read port and one write port, the multiply-accumulate pipeline |
| `rtl/ft8/ft8_frame_core.v` | Feeds `rtl/fft/fft_r22sdf.v` (unmodified) the 15 sub-transforms of one frame plus one zero flush block, tags each output with its sub-transform, drives `ft8_combine.v` |
| `rtl/ft8/ft8_power.v` | Round/power/shift/saturate, 7-clock pipeline; streams the 1,024 finished words out under credit flow control |
| `rtl/ft8/ft8_slot_capture.v` | Part (a): mirrors each receiver's 12 ksps audio into its own DDR3 ring |
| `rtl/ft8/ft8_slot_reader.v` | Reads a receiver's current 1,920-sample window back out of DDR3 (read-lane "rest" tier), bursts split at the ring's wrap |
| `rtl/ft8/ft8_ring_writer.v` | Packs two power words per 64-bit lane word and writes a frame's 512 lane words into the receiver's spectrogram ring in 16-beat bursts |
| `rtl/ft8/ft8_ddr3_writer.v` | 2-way sub-arbiter merging slot-capture and ring-writer traffic onto one write-lane client |
| `rtl/ft8/ft8_spectrogram.v` | Top level: 8-receiver round-robin scheduler, DDR3 client ports, interrupt |
| `rtl/ft8/rom/ft8_w3840_oct.hex` | Octant twiddle table, written by `ft8-frontend tables` (`fw/tr-modes/src/bin/ft8_frontend.rs` `cmd_tables`, extended by this WP with the octant export) |
| `sim/ft8/tb_ft8_tw3840.v` | Unit test: all 15,360 (n1, k) combinations the RTL ever asks for, against the model's full twiddle table |
| `sim/ft8/tb_ft8_frame_core.v` | Frame core + power stage against 5 real frames of `qso3_busy.wav`, bit for bit |
| `sim/ft8/tb_ft8_spectrogram.v` | End to end: `ft8_spectrogram.v` + the real write and read arbiters + the behavioural DDR3 lanes (random stalls, IQ write traffic on the top tier), 3 receivers x 5 frames, rings read out of DDR3 and compared bit for bit |
| `sim/ft8/vectors/qso3_busy_small_*.hex`, `qso1_small_*.hex` | Committed prefixes (first 3,840 samples, first 5 x 1,024 power words) of the model's vectors for two real recordings |
| `tools/check_ft8_wav.sh`, `sim/ft8/ft8_frame_core_wav_harness.v` | Full-recording check against `captures/ft8/*.wav` (skips if not fetched); `tools/check.sh` runs it on 20 frames spread across the slot |
| `rtl/ddr3/ddr3_write_arbiter.v` | Extended with a 4th, lowest-priority client port ("ft8") for this WP's DDR3 write traffic |

## 2. Design

### 2.1 The transform (256 x 15) and the FFT's output lag

Bit-exact with `frame_bins_fx`: frame `j`'s window is audio samples `480j .. 480j + 1,919`
(rectangular, zero-padded to 3,840). For `n1 = 0 .. 14`, `u[n2] = a[15n2 + n1]` (zero for
`15n2+n1 >= 1,920`) streams into one shared `rtl/fft/fft_r22sdf.v` (`LOG_N = 8, IW = 16`,
unmodified) at one sample every `FEED_PERIOD` (8) clocks. ARCHITECTURE 3.12 (b) names
`REAL_IN = 0` (complex input, imaginary part zero); this uses `REAL_IN = 1`, the core's
real-input mode, which gives the same values (with a zero imaginary input the imaginary half of
the first delay line is always zero) and stores only the real half, halving the 128-deep first
delay line to 17 bits. That is what brought its LUT-RAM read inside 150 MHz. The testbenches
check it bit for bit.

`fft_r22sdf.v` emits exactly one output word per input word, and output word `j` (counted from
reset) holds frame position `(j - 255) mod 256`. So a 256-sample block's transform comes out while
the *next* block is being fed: the next block's inputs push it out. This is how a single-path
delay-feedback FFT works; it matters here because this engine feeds the FFT in bursts. A burst of
15 blocks leaves the 15th block's bins 1 .. 255 inside the FFT. So every frame feeds **16 blocks**:
the 15 sub-transforms and one zero "flush" block (`n1 = 15`) whose only job is to push block 14
out. Frames are whole multiples of 256 samples, so input and output block numbers stay aligned
from reset onward. The output side counts blocks mod 16 on `out_first` and drops block 15's
outputs (all zero; most of them only emerge when the next frame starts). No warm-up is needed:
the 255 words the core suppresses after reset belong to no block.

### 2.2 RB8: accumulate as it comes out

`ft8_combine.v` implements the RB8 amendment directly: each `(n1, k1)` output expands into 4
sub-events (`k = k2*256 + k1`, `k2 = 0..3`), each multiplied by `W_3840^(n1*k)` and accumulated
into `acc[k]` — 1,024 words, one memory. `n1 == 0` **writes** the fresh product instead of
reading a stale value, so no clear pass between frames is needed. Pipeline from a sub-event's
dispatch at clock T: twiddle lookup T+1 .. T+9, four partial products T+10, their sums T+11,
the accumulator read issued at T+9 so the old value is registered at T+11, write at the end of
T+11.

**Accumulator width 44 bits per component (88-bit words, five 1K x 18 BSRAM)**, not the "at most
46 bits" ARCHITECTURE 3.12 gives. The tight bound, for any 16-bit input:
`|Y_n1[k]| <= sum of |u[n2]|` plus the F1 FFT's own rounding error (under 100 LSB); the 15
sub-transforms together cover the 1,920 window samples once; every twiddle has magnitude
`<= 2^17`. So `|Re A|, |Im A| <= (1,920 x 32,768 + 1,500) x 2^17 = 0.94 x 2^43`. A 44-bit signed
accumulator never wraps and equals the model's `i64` sum exactly; 46 bits would cost a sixth
BSRAM. `X = round(A / 2^17)` then fits 27 bits, as ARCHITECTURE 3.12 states.

### 2.3 The twiddle ROM

`W_3840^e` (`e = n1*k mod 3,840`) uses the first-octant-table-plus-symmetry scheme of
`rtl/fft/fft_twmul.v`, generalised to 3,840 = 8 x 480: octant `o = e / 480`, remainder
`r = e % 480`, a 480-entry table, the 8-way sign/swap map, and the 45-degree constant (`K45`).
`ft8-frontend tables` writes the table (`ft8_w3840_oct.hex`) from `tables::octant_table(3_840)`,
the function `Tables::new()` itself uses, so RTL and model agree by construction. The table is
one block ROM (a 512 x 36 `pROMX9`, which place-and-route counts as 1 BSRAM); as a LUT ROM its
address fanned out to about 1,000 LUT inputs and missed timing by 5 ns. Nine pipeline stages:
input register; product `n1*k`; reduction mod 3,840; octant (seven parallel compares);
remainder; reflected address; ROM; 45-degree constant and both negations; sign/swap select.

### 2.4 Power stage

`ft8_power.v` reads `rd_addr = 0 .. 1,023` through combine's shared read port (2-clock latency)
and computes, bit-exact with `power_word`, one step per clock (the shift by `sh` over two):

```
X  = round(A / 2^17) = (A + 2^16) >>> 17        27-bit signed
P  = Xr^2 + Xi^2                                 54-bit
S  = sh == 0 ? min(P, 2^32-1) : min((P + 2^(sh-1)) >> sh, 2^32-1)
```

It issues a read only while it holds a credit from the ring writer (64 credits = its FIFO size),
so no word is dropped however long DDR3 holds the ring writer off.

### 2.5 DDR3 integration and scheduling

- **Slot capture (part a)**: `ft8_slot_capture.v` mirrors each receiver's 12 ksps audio into its
  own ring, one 64-bit lane word per sample (simpler than ARCHITECTURE 3.12's 4 samples per word:
  4 MB per receiver for a 2^19-word ring instead of 720 KB, negligible against the DDR3 size). A
  sticky `cap_overflow` output reports a dropped sample (8-deep FIFO full).
- **Read-back**: `ft8_slot_reader.v` fetches the frame's 1,920-sample window through the read
  lane's tier 2 ("the rest", `rtl/ddr3/ddr3_read_arbiter.v`, unmodified), bursts of up to 120
  words, split where the window wraps past the ring's end.
- **Spectrogram ring**: `ft8_ring_writer.v` writes lane word `ring_base + frame*512 + bin/2`,
  bin `2m` in the low half and `2m+1` in the high half. Read as little-endian bytes that is the
  model's `u32` array `S[j*1,024 + k]` (ARCHITECTURE 3.12's 1.5 MB per receiver). 16-beat bursts
  from a 32-entry lane-word FIFO.
- **Write lane**: its three client ports were all taken, so `rtl/ddr3/ddr3_write_arbiter.v` gained
  a 4th, lowest-priority "ft8" port; `ft8_ddr3_writer.v` merges slot capture (wins ties: live
  audio) and the ring writer onto it. Traffic across 8 receivers: 0.77 MB/s capture +
  0.82 MB/s spectrogram, against the lane's ~179 MB/s (`docs/F4_DDR.md` section 3).
- **Scheduler** (`ft8_spectrogram.v`): receiver `r` is ready for its next frame `j` once
  `cap_wr_ptr[r] - slot_boundary_ptr[r] >= 1,920 + 480j` (and that difference is not negative,
  i.e. the boundary is not in the future). Round-robin from the receiver after the last one
  served. Per frame: read-back, transform, power, then wait until the ring writer has emptied, so
  the interrupt means the frame is in DDR3. `irq_rx`/`irq_frame` name the frame; `frame_ptr`
  gives each receiver's frames written so far in this slot. The firmware writes
  `slot_boundary_ptr[r]` and pulses `slot_start[r]` at each new slot, which restarts that
  receiver at frame 0.
- **Slot boundaries**: every frame `j = 0 .. 371` lies wholly inside its slot (frame 371 ends at
  slot sample 480 x 371 + 1,919 = 179,999), so no zero-padding past the slot is ever needed. (The
  first version documented a gap here; there is none.)
- Configuration is plain input ports, not a register block, as in `rtl/audio/audio_ring_reader.v`
  and `rtl/video/waterfall_writer.v`; whoever adds the front end's register page
  (ARCHITECTURE 3.12, `0xE80D_0000`) wires them.

## 3. Latency and busy time

Per frame: 16 x 256 x `FEED_PERIOD` (8) = 32,768 clocks of feed, plus the window read-back
(1,920 words), the power readout (1,024 words, paced by the ring writer's DDR3 writes) and a few
clocks of pipeline drain. **Measured in `sim/ft8/tb_ft8_spectrogram.v`: 36,103 clocks per frame**
(scheduler busy from pick to interrupt, with random DDR3 stalls and IQ write traffic on the top
tier), 240 us at 150 MHz.

`FEED_PERIOD` could be 4 (combine takes one output every 4 clocks), halving the feed; not needed
for the budget.

## 4. Resources and Fmax

`gowin/res.sh ft8_spectrogram --wrap rtl/ft8/ft8_spectrogram.v`, 150 MHz constraint (excerpt:
`gowin/reports/ft8_spectrogram/summary.txt`):

| | Final RTL | Run before (same but for the ring writer's address) |
|---|---|---|
| Fmax | **111.0 MHz** | 141.5 MHz |
| Logic / registers (block alone) | 6,563 / 6,582 | 6,600 / 6,553 |
| DSP | 20.5 | 20.5 |
| BSRAM (place-and-route count) | **9** | 9 |

BSRAM: accumulator 5 (1,024 x 88 as five 1K x 18), input window 2 (1,920 x 16), the two twiddle
ROMs 1 each (this WP's and the FFT core's stage-2 table). Done-test 4 (at most 10): **met**.

**Fmax: not met.** In both runs nearly every failing path is inside `rtl/fft/fft_bf.v`, which this
WP may not change: the butterfly's add-or-subtract (`rot` through a 20- to 23-bit carry chain
into `out_re`/`out_im` or the delay line), stages 2 and 4. Its slack moves from -0.4 to -2.3 ns
between runs with almost identical RTL, so it depends on placement, not on this engine's logic.
`gowin/reports/README.md` already has the same core alone at 140.4 MHz. The fix belongs in
`rtl/fft` (for example `rot` copied per byte lane, as the timing branch did for the write
arbiter's select). This WP's own logic has one failing path left in the final run:
`ft8_spectrogram.v`'s state register to one receiver's frame counter (`next_frame[3]`),
-0.621 ns; the fix is a registered one-hot receiver select and a precomputed `cur_frame + 1`
(not made after the final measurement).

How the memory and timing got here (first run: 30 BSRAM, 79.9 MHz):

- The FFT core's short shift-register delay lines (8 to 32 deep) had each become a 32-bit block
  RAM (2 BSRAM each). Instance attributes on the FFT in `ft8_frame_core.v` now keep them in
  flip-flops (`syn_srlstyle`) and its two RAM delay lines in LUT RAM (`syn_ramstyle`), with
  `syn_maxfan` for the flip-flops' enables. `rtl/fft` itself is unchanged.
- The ring writer's 64-bit FIFO (6 BSRAM as block RAM) is LUT RAM; combine's data delay line
  (4 BSRAM as block RAM) is flip-flops.
- Pipelining for 150 MHz: the twiddle lookup (3 to 9 stages), combine (products and sums in
  separate clocks), the power stage (7 stages), the input buffer read, the FFT output register,
  the scheduler (registered readiness, a registered round-robin pick, the selected receiver's
  settings in two registered steps), the slot capture and slot reader address arithmetic, and the
  ring writer's burst address (a running count instead of a stored index).

## 5. Done tests

**1. Bit-exact against the S15 model: met.**

- `sim/ft8/tb_ft8_frame_core.v`: 5 frames of `qso3_busy`, all 5,120 words equal. `PASS`.
- `tools/check_ft8_wav.sh` (full recording): all 372 frames of `qso3_busy.wav`, all 380,928
  words equal the model's. `PASS` (21 minutes in Icarus).
- `sim/ft8/tb_ft8_spectrogram.v`, end to end through DDR3 with random lane stalls (3 % of idle
  clocks, runs up to 32 clocks) and IQ write traffic on the top write tier: receivers 0 and 2 on
  `qso3_busy` (receiver 2 with 240 junk samples before its slot boundary), receiver 5 on `qso1`,
  audio interleaved on the shared input. 15 frames, all 15,360 words read out of the DDR3 model
  equal the model's; 15 interrupts with the right receiver/frame tags; no capture overflow.
  `PASS`.
- `sim/ft8/tb_ft8_tw3840.v`: all 15,360 twiddle lookups. `PASS`.
- `sim/ddr3/tb_ddr3_write_arbiter{,_priority}.v`, `tb_ddr3_video_no_starve.v`: still `PASS`.

**Root cause of the first version's mismatch** (every bin but DC close but wrong): the frame core
treated `fft_r22sdf.v` as having a short pipeline delay after a one-time fill. In fact a block's
outputs only come out as the next block's 256 inputs push them (section 2.1). Dumping one frame's
combine inputs from the RTL next to the model's sub-transform outputs showed it directly: the
first 255 events were the warm-up block's zeros, written as `n1 = 0`; every real sub-transform
was tagged one `n1` too high except its index-0 output; and sub-transform 14's bins 1 .. 255
never left the FFT. A tag one too high multiplies by `W^k` more, a pure rotation, and the missing
fifteenth term is small, which is why magnitudes were close. DC matched because every
sub-transform's index-0 output was tagged correctly and bin 0's twiddles are all 1. Fixed by the
flush block and block counting of section 2.1 (the warm-up is gone).

Other bugs found by the new tests and fixed:

- Power stage: `$unsigned(xr * xr)` sized the square at X's own width; the strongest bins
  (P >= 2^29) lost their top bits (15 of 5,120 words once the tagging was fixed).
- Power stage: 1,024 words at one per clock into an 8-deep ring-writer FIFO that empties at DDR3
  speed silently dropped words; now credit flow control. `busy` also had two drivers.
- Slot capture popped its FIFO one clock after `done`; the idle state re-sent the stale head as a
  new sample and the count underflowed into junk writes.
- Write sub-arbiter gated `gnt` with its own BUSY state; the write arbiter can grant a burst's
  first beat in the very clock `req` rises, so that grant was lost and the client sent a second,
  spurious beat.
- Slot reader: a fixed 120-word burst could run linearly past the ring's end (once per ring
  cycle; 2^19 is not a multiple of 480).
- Scheduler: no way to start a new slot (`next_frame` only reset at power-up); a boundary ahead
  of the write pointer read as a huge positive count; the interrupt fired before the last words
  reached DDR3.
- `tools/check_ft8_wav.sh` passed MSYS paths (`/g/...`) that the native Windows simulator cannot
  open, and its harness was named `tb_*.v`, which `tools/check.sh` would compile on its own and
  fail; renamed to `sim/ft8/ft8_frame_core_wav_harness.v`, and `tools/check.sh` now runs the
  script (20 frames).

**2. FT8 tones land 2 bins apart: met.** In `qso1`'s spectrogram (equal to the RTL's, done-test
1) the strongest signal's clean frames (peak more than twice both neighbours) peak on bins 413,
415, 417, ..., 427 (1,290.6 Hz + 6.25 m Hz): eight tones, 2 bins apart. The bins 2 away from a
clean peak sit on the window's nulls: median peak-to-(peak +- 2 bins) ratio 98 (20 dB), so
adjacent tones do not leak into each other.

**3. Busy time under 10 % with 8 receivers at 150 MHz: met, 4.8 %.** 36,103 clocks per frame
(section 3) x 25 frames/s x 8 receivers = 7.22 M clocks/s of 150 M. (At the measured 111 MHz it
would be 6.5 %.)

**4. BSRAM at most 10 (Gowin counting): met, 9. 150 MHz: not met, 111.0 MHz** (141.5 MHz in the
run before), limited by the F1 FFT core; section 4.
