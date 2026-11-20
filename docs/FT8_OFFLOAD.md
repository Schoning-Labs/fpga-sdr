<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# WP FO1 — Where the FT8 back end runs: second core, fabric engine, or software

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Status: done 2026-09-26, branch `ft8offload`. Proposed
work packages: end of [PLAN.md](PLAN.md) ("Proposed by ft8offload"). The decision is also in
[ARCHITECTURE.md](ARCHITECTURE.md) 3.12 ("FT8 back end: where it runs").

The owner's question: *for FT8 decode, would it make sense to install a gateware RISC-V processor with custom
DSP or other instructions to do the heavy decode, and leave the AE350 for the UI?*

## 1. Result in short

- **No.** The heavy part was not the arithmetic the CPU does, it was the way mfsk-core's OSD was written:
  one byte per bit and a bitwise CRC for every one of thousands of test patterns. Rewritten with 32-bit words
  and a linear CRC syndrome (same searches, identical results), one OSD search costs about 0.4 M instructions
  on the AE350 instead of about 6 M (the deep npre2 search 2 M instead of 16-260 M), and mfsk-core's whole
  unrationed ladder (eight OSD searches per failed candidate plus the a-priori pass with OSD) fits the existing 30 Mcycles/s per-receiver cap: **162-244 M
  instructions per slot at 60 candidates, against 655-746 M before** (the cap is 315 M).
- **What that buys**: full-depth single-pass decoding (every candidate gets the full ladder, no OSD rationing)
  on **all 8 receivers**, 15-23 Mcycles/s each, 1.9-2.9 % of the core per receiver; the normal-use budget
  (ARCHITECTURE 5.5) stays at 38.9 % because the 30 Mcycles/s allowance is unchanged. Rationing OSD would
  have cost 0.35 dB (one search instead of eight, ordinary messages) to 0.73 dB (no OSD). A second
  pass (subtract and decode again) costs 449-814 M per slot: it fits the operator's receiver's extra
  allowance, as planned, not every receiver.
- **A soft core** (option b) would be slower than the work it takes: a NEORV32 or VexRiscv at about
  100-150 MHz runs 25-135 M instructions/s, 5-24 % of the A25, and the f32 LLR and belief-propagation code
  needs an FPU in it. Cost: 3.9-6.3k logic for the core alone (yosys gw5a), plus 16-86 BSRAM for its memory,
  a second firmware image and debug path, on a chip whose logic is already the tight resource (71-75 %
  against 70 %).
- **A fixed-function engine** (option c) is cheap only for belief propagation: a serial min-sum LDPC engine
  sketches at about 0.6k logic and 3 BSRAM and would take 6-11 % of the core off FT8 for 8 receivers. It is
  not needed at today's cap; it is proposed as a reserve (PLAN FO4) if the board's measured IPC or real
  busy-band candidate counts push FT8 over the cap. An OSD engine is not worth it any more (5.7k logic to save
  0.4-0.8 % of the core per receiver).
- **The three mfsk-core hooks** S15 asked for are in the vendored copy (VENDOR_PATCH fix 6): a per-candidate
  soft-symbol entry with the outcome and the rung that succeeded, an OSD effort setting (variants, seeds,
  npre2), and switches for the blind-CQ a-priori pass. With the default effort they reproduce mfsk-core's
  decodes exactly (tested on all three recordings).

## 2. What was built

| File | What |
|---|---|
| `fw/vendor/mfsk-core/src/ft8/decode_block/effort.rs` | `Ft8Effort`, `Rung`, `CandidateOutcome`, `CandidateWork`, `decode_soft_symbols` (fix 6) |
| `fw/vendor/mfsk-core/src/ft8/decode_block/{process_candidates,osd_strategy}.rs` | the ladder driven by an `Ft8Effort`, per-rung counters and clock samples (fix 6) |
| `fw/vendor/mfsk-core/src/fec/ldpc/osd_fast.rs` | bit-packed OSD kernels with a linear CRC syndrome (fix 7) |
| `fw/tr-modes/src/frontend/effort.rs` | text form of an effort (`osd=abcd,seeds=12,npre2=1,cq=bposd`, `none`, `kernel=ref`, ...) |
| `fw/tr-modes/src/frontend/decode.rs` | the CPU half calls `decode_soft_symbols` per candidate; `DecodeParams::effort`; the capped two-sweep mode no longer repeats belief propagation; per-candidate log |
| `fw/tr-modes/src/frontend/trace.rs` | trace format 2 (carries the effort) |
| `fw/tr-modes/src/bin/ft8_frontend.rs` | `effort-sweep` (50 % points of several efforts on the same trials, CQ or ordinary messages), `ladder` (per-candidate rungs) |
| `fw/tr-modes/tests/fo1_effort.rs`, `fo1_osd_fast.rs` | equivalence and knob tests (section 5) |
| `fw/tr-ft8bench/src/kernels.rs`, `tools/qemu_fo1_kernels.sh` | per-kernel instruction counts on the target |
| `tools/qemu_s15.sh` | effort specs in the settings, parallel QEMU runs (`S15_JOBS`), BP/OSD/a-priori split and OSD search counts in the table |
| `tools/fo1_sketch/` | the two fabric sizing sketches of option (c) and their yosys script (not design RTL) |

## 3. Measurements

### 3.1 CPU part per slot, one receiver (QEMU, `tools/qemu_s15.sh`)

Instructions per 15 s slot for everything the FPGA front end does not do (method as S15: the fabric's
answers replayed from a trace, `minstret` under `-icount shift=0`, target decodes checked equal to the
host's in every run). 60 candidates, one pass. "Ladder" = LLR/BP/OSD/a-priori/CRC/unpack; its split is
belief propagation with its LLRs / OSD with its LLR set and seeds / a-priori passes. Effort specs as in
`tr_modes::frontend::effort`; `full` is mfsk-core's `DecodeDepth::FULL` ladder, `kernel=ref` the same with
mfsk-core's own OSD kernels (the S15 state).

| Recording | Effort | Decodes | **Total (M)** | Ladder (M) | BP / OSD / a-priori (M) | OSD searches (a-priori) |
|---|---|---|---|---|---|---|
| qso3_busy | `kernel=ref` (S15) | 15 | 746.0 | 685.7 | 76.3 / 427.3 / 181.0 | 33 (8) |
| qso3_busy | **`full`** (packed OSD) | 15 | **194.8** | 134.5 | 76.3 / 31.3 / 25.9 | 33 (8) |
| qso3_busy | `none` (no OSD) | 12 | 211.3 | 150.9 | 76.3 / 0 / 73.8 | 0 |
| qso3_busy | `none,cq=off` | 12 | 137.5 | 77.1 | 76.3 / 0 / 0 | 0 |
| qso3_busy | `osd=b,seeds=2` (one search) | 13 | 197.8 | 137.4 | 76.3 / 6.7 / 53.6 | 6 (16) |
| qso1 | `kernel=ref` (S15) | 3 | 704.4 | 644.8 | 56.4 / 502.4 / 85.7 | 40 (4) |
| qso1 | **`full`** | 3 | **162.1** | 102.5 | 56.4 / 37.2 / 8.6 | 40 (4) |
| qso1 | `none` | 3 | 126.1 | 66.5 | 56.4 / 0 / 9.8 | 0 |
| qso1 | `osd=b,seeds=2` | 3 | 130.0 | 70.4 | 56.4 / 5.0 / 8.6 | 5 (4) |
| qso2 | `kernel=ref` (S15) | 5 | 655.1 | 594.8 | 114.3 / 480.1 / 0.0 | 80 (0) |
| qso2 | **`full`** | 5 | **244.3** | 184.0 | 114.3 / 69.3 / 0.0 | 80 (0) |
| qso2 | `none` | 5 | 175.0 | 114.7 | 114.3 / 0 / 0.0 | 0 |
| qso2 | `osd=b,seeds=2` | 5 | 184.6 | 124.3 | 114.3 / 9.6 / 0.0 | 10 (0) |

The rest of each total is the same in every row: fine sync 48.4-49.1 M, reading the engines' words 11.0 M,
candidate list 0.2-0.3 M. The `kernel=ref` rows reproduce S15's `all` rows within 0.6 %.

Candidates and passes, effort `full` (a second pass subtracts the first pass's decodes and decodes the
residual; subtraction 31-140 M included):

| Recording | 30 cand., 1 pass | **60, 1 pass** | 100, 1 pass | 60, 2 passes | 100, 2 passes | 60, 1 pass, `npre2=0` | Decodes (60/1, 60/2, 100/2) |
|---|---|---|---|---|---|---|---|
| qso3_busy | 117.1 | **194.8** | 322.6 | 622.5 | 874.2 | 193.2 | 15, 19, 19 |
| qso1 | 66.8 | **162.1** | 317.9 | 449.3 | 837.4 | 159.7 | 3, 5, 5 |
| qso2 | 176.5 | **244.3** | 507.2 | 814.0 | 1,373.3 | 244.3 | 5, 5, 5 |

At the cap (315 M): one pass at 60 candidates fits on every recording with 70-150 M to spare; 100 candidates
do not fit on two of three; two passes at 60 candidates (449-814 M) fit the operator's receiver's allowance
(30 + 60 Mcycles/s, 945 M per slot) but not the per-receiver cap. In the ladder, belief propagation is now the
largest part (56-114 M of 100-184 M at 60/1; 163-391 M with two passes); OSD 31-69 M.

### 3.2 Per kernel (QEMU, `tools/qemu_fo1_kernels.sh`)

Mean instructions per call on 12 candidates that belief propagation cannot decode (noisy random codewords;
the OSD searches run on the one- and two-iteration seeds, as the ladder runs them). Every packed result
equalled the reference result.

| Kernel | Instructions | Packed / reference |
|---|---|---|
| LLR set from the 79 x 8 soft symbols (four variants, up to 3-symbol coherent) | 2,317,000 | |
| Belief propagation, normalised min-sum, 30 iterations (the ladder's Steps 1-2; four per failed candidate) | 2,215,000 | |
| Belief propagation, sum-product, 30 iterations (the a-priori passes) | 3,629,000 | |
| OSD seed: BP-refined LLR sum after 1 / 2 iterations | 311,000 / 461,000 | |
| OSD npre1 search (WSJT-X ndeep 2), reference / packed | 6,112,000 / **435,000** | 14 times fewer |
| OSD npre1 + npre2 search (ndeep 3, nsync >= 18), reference / packed | 261,376,000 / **1,921,000** | 136 times fewer |
| Unpruned order-2 OSD with CRC (a-priori passes), reference / packed | 19,509,000 / **321,000** | 61 times fewer |

On the recordings the reference npre2 search cost 16-40 M (fewer near-matches in its hash table than on
these synthetic inputs). What made the reference slow: every test pattern was built and compared one byte per
bit (174 bytes), and every pattern that passed the gate paid for an unpermute of 174 bytes and a bitwise CRC
over 96 bits (about 2,000 instructions). Packed, a pattern costs about 30 instructions, and the CRC is two
XORs of precomputed 14-bit syndromes, tested before anything else.

### 3.3 Sensitivity: what each saving costs (`ft8-frontend effort-sweep`)

Method of S5/S15: per SNR step 200 trials, one message at a random frequency (300-2,700 Hz) and time
(+/-0.3 s) in white Gaussian noise (SNR in 2,500 Hz), noise 1,000 LSB, fixed-point front end, +/-100 Hz,
20 candidates, sync threshold 1.0, 50 % point by linear interpolation; every effort decodes the same audio.
Two message kinds: `CQ <call> <grid>` (as S5 and S15; the blind-CQ a-priori pass can lock 29 of its bits)
and ordinary `<call1> <call2> <grid>` (the a-priori pass cannot help). Run to run the 50 % point moves by
about 0.05 dB.

| Effort | Ordinary messages: 50 % point | cost | CQ messages: 50 % point | cost | OSD searches per trial |
|---|---|---|---|---|---|
| `full` (mfsk-core ladder, packed OSD: identical decodes to the reference) | -21.02 dB | 0 | -21.55 dB | 0 | 62 |
| `npre2=0` (no deep npre2 search) | -21.02 dB | 0.00 dB | -21.55 dB | 0.00 dB | 62 |
| `seeds=1` (four searches instead of eight) | -20.96 dB | 0.05 dB | -21.55 dB | 0.00 dB | 31 |
| `osd=b,seeds=2` (one search) | -20.67 dB | **0.35 dB** | -21.56 dB | 0.00 dB | 8 |
| `osd=b,seeds=2,cq=bp` (one search, a-priori without OSD) | -20.67 dB | 0.35 dB | -21.04 dB | 0.51 dB | 8 |
| `cq=bp` (a-priori pass without OSD) | -21.02 dB | 0.00 dB | -21.15 dB | 0.40 dB | 62 |
| `cq=off` (no a-priori pass) | -21.02 dB | 0.00 dB | -20.95 dB | 0.60 dB | 62 |
| `none` (no OSD; a-priori by BP) | -20.29 dB | **0.73 dB** | -20.94 dB | 0.61 dB | 0 |
| `none,cq=off` (belief propagation only) | -20.29 dB | 0.73 dB | -20.27 dB | **1.28 dB** | 0 |

Reading: OSD is worth 0.7 dB on every message; the blind-CQ a-priori pass another 0.6 dB on CQ messages
(0.4 of it from its own OSD). With one search instead of eight, the a-priori pass hides the loss on CQ
messages but ordinary messages lose 0.35 dB, and on the busy recording one search loses 2 of 15 decodes.
npre2 buys nothing measurable here and is the most expensive search (section 3.2).

## 4. The options

### (a) Status quo: everything on the AE350, OSD rationed

Before this WP: the full ladder cost 655-746 M per slot per receiver, over the 315 M cap in every run, so S15
rationed OSD (`osd_max`) and S17 would have had to choose between candidates and OSD. Cost of rationing:
0.35-0.73 dB (section 3.3) and up to 3 decodes per busy slot.

### (b) A soft RISC-V core in the fabric for the back end

Resources, yosys 0.69 `synth_gowin -family gw5a` with `tools/yosys_res.sh` (multipliers as DSP, "logic" as
3.14 counts it), from the sources the HL2 project already uses (NEORV32 1.13.5 via GHDL 6.0 `--synth`,
VexRiscv "Min" as generated by SpinalHDL):

| Core, configuration | Logic | DSP | BSRAM | FF |
|---|---|---|---|---|
| NEORV32 CPU, rv32imc + Zbb + Zicntr, DSP multiplier, barrel shifter | 3,888 | 2 | 0 | 1,172 |
| same + Zfinx FPU + CFU (custom-instruction slot) | 6,310 | 3 | 0 | 2,112 |
| VexRiscv "Min" (rv32i, no multiplier, no caches; lower bound) | 1,759 | 0 | 2 | 856 |

Not in those numbers: instruction and data memory. The FT8 CPU half is 229 KB of code on the A25 (the whole
bench binary without its trace); the back end alone is roughly half, and its working set (BP scratch, OSD
setup and npre2 table, soft symbols, heap) about 100 KB. Tightly coupled memory for 128 KB code + 64 KB data
is 86 BSRAM (25 % of the chip); caches plus a DDR3 lane client instead are about 16 BSRAM and 1.5k logic.
A mailbox to the AE350 and an interrupt line: about 0.5k logic. Total **6-9k logic (4-7 % of the chip),
3 DSP, 16-86 BSRAM**, with logic already at 71-75 % against the 70 % target (3.14).

Speed: no Gowin timing exists yet (PLAN T1); such cores close at roughly 100-150 MHz on mid-range FPGAs.
NEORV32 is a multi-cycle core (2.5-4 cycles per instruction): 25-60 M instructions/s. A VexRiscv with
caches and a 5-stage pipeline (about 0.8 per cycle): 80-120 M/s. The A25: 560 M/s at IPC 0.7. The back end
for 8 receivers after (d) is 8 x 100-184 M per 15 s slot = 53-98 M instructions/s, all f32 in its hot loops:
a single soft core would be fully busy even with an FPU, and without one the float code runs several times
more instructions. Custom instructions (wide GF(2) XOR, population count, saturating min-sum steps) would
speed up the parts (d) already made cheap; the belief propagation that remains is f32 and would first have
to be rewritten in fixed point. Plus a second firmware image, its linker script and loader, a debug path
(NEORV32 on-chip debugger or a GDB stub), and inter-processor protocol and tests.

At best this moves the FT8 back end's 10-18 Mcycles/s per receiver off the A25, which the budget no longer
needs, at a cost in logic the chip does not have. **Rejected.**

### (c) A fixed-function engine driven by the AE350

Two sizing sketches in `tools/fo1_sketch/` (not design RTL; `bash tools/fo1_sketch/yosys.sh`):

| Sketch | Logic | DSP | BSRAM | FF | Clocks per job at 150 MHz |
|---|---|---|---|---|---|
| Layered normalised min-sum LDPC(174, 91), one edge per clock, Q 174 x 12 bit, R 522 x 8 bit | 617 | 0 | 3 | 202 | about 1,300 per iteration, 39,000 for 30 (0.26 ms) |
| GF(2) OSD engine: elimination on 192-bit rows (pointer-table swaps), npre1 pair search with 40-bit population count, syndrome check, weighted distance | 5,697 | 0 | 8 | 1,999 | about 16,200 elimination + 4,200 search + 40 per gated pair (0.15 ms) |

What each would take off the CPU per receiver, at 60 candidates (section 3.1, `full`):

- **Belief propagation** (the ladder's four runs per failed candidate, the a-priori runs and the OSD seeds):
  about 65-115 M of the 162-244 M per slot, 6-11 Mcycles/s per receiver, **6-11 % of the core for 8
  receivers**, for about 0.6-1k logic and 3 BSRAM once an interface is added. The engine is fixed point;
  mfsk-core's is f32 (and sum-product in the a-priori passes), so it needs a bit-exact Rust model of its own
  and a sensitivity sweep (0.3 dB rule) before it replaces anything. A reserve, not needed at today's cap:
  PLAN FO4.
- **OSD**: 31-69 M per slot after (d), 3-7 Mcycles/s per receiver, for 5.7k logic and 8 BSRAM. Not worth it.

### (d) Software first

Built and measured here: the hooks (fix 6) and the packed OSD kernels (fix 7). The packed kernels change no
result and cut the ladder 3-4 times; the hooks let the scheduler (S17) choose effort per candidate and
measure it. With both, the full ladder fits the cap on every recording (section 3.1).

## 5. Tests

- `cargo test -p tr-modes --test fo1_effort`: the per-candidate entry with `Ft8Effort::from_depth(d)`
  decodes exactly what mfsk-core's own multi-candidate entry decodes with `DecodeDepth` d (message,
  frequency, time, pass id, hard errors) on all three recordings at 30 and 60 candidates, one and two passes,
  `FULL` and `BP_ONLY`; the same with the reference OSD kernels; the knobs do what they say (eight searches
  per failed candidate under `FULL`, at most one with one variant and seed, none with OSD off, no a-priori
  work with the pass off; the capped mode's OSD sweep runs no belief propagation and finds the uncapped
  decodes when the cap covers every failure).
- `cargo test -p tr-modes --test fo1_osd_fast`: the three packed kernels equal the reference kernels on
  1,600 LLR vectors (channel LLRs of noisy codewords over a noise range where both outcomes occur, their one-
  and two-iteration BP-refined seeds, quantised copies with ties).
- `tools/qemu_fo1_kernels.sh`: the same comparison on the target, with the instruction counts.
- `tools/qemu_s15.sh`: every run's target decodes equal the host's.

## 6. Recommendation, and what it changes

1. **Keep the whole FT8 back end on the AE350.** No soft core, no fabric engine now.
2. **Default effort `full`**: mfsk-core's own ladder (eight OSD searches per failed candidate, npre2 for clean
   candidates, blind-CQ a-priori pass with OSD) with the packed kernels, on every candidate (no `osd_max`
   rationing) of every receiver at 60 candidates: 162-244 M per slot. `npre2=0` measured 0.00 dB in both
   sweeps but saves only 0-2.4 M per slot once packed, so the ladder stays as WSJT-X runs it. The rationing
   knobs stay available to the scheduler: `seeds=1` (half the searches, 0.00-0.05 dB), then one search
   (0.35 dB on ordinary messages), then `osd_max`.
3. **Second pass on the operator's receiver only**, as planned: 449-814 M per slot at 60 candidates, inside
   its 30 + 60 Mcycles/s. Two passes on more receivers would need another 27-54 Mcycles/s each: FO3 first.
4. The per-receiver cap of 30 Mcycles/s (CPU_BUDGET section 8, decision 1) stays; S17 uses
   `CandidateWork` ticks to stay inside it and spends the headroom on more candidates first.
5. Reserve: the min-sum engine (FO4) if B10's measured IPC or real busy-band traffic pushes FT8 over the cap.

## 7. How to reproduce

```sh
cd <repository root>
bash tools/fetch_test_audio.sh
cd fw
cargo test -p tr-modes --test fo1_effort --test fo1_osd_fast
cargo run --release -p tr-modes --bin ft8-frontend -- effort-sweep -23 -18.5 0.5 200 std 20 full none "osd=b,seeds=2" npre2=0
cargo run --release -p tr-modes --bin ft8-frontend -- ladder ../captures/ft8/qso3_busy.wav 60 1 full
cd ..
S15_JOBS=6 S15_SETTINGS="60:1:kernel=ref:all 60:1:full:all 60:2:full:all" bash tools/qemu_s15.sh
bash tools/qemu_fo1_kernels.sh
bash tools/fo1_sketch/yosys.sh
```

## 8. Limits

- Instruction counts, not cycles: IPC 0.7 is still assumed (PLAN B10). The packed kernels are integer code
  with small working sets, which should run nearer IPC 1 than the f32 code around them.
- Three real recordings and synthetic AWGN; no fading channel, no real busy-band slot with 30-50 signals.
- The soft-core and engine numbers are yosys synthesis of sources or sketches, not Gowin place-and-route, and
  the soft-core speeds are typical figures, not measurements on this chip.
