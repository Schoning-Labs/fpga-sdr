<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# WP FO3, S17, FO2 — The CPU half of FT8 decoding: cheaper ladder, decode scheduler, effort defaults

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Status: done 2026-09-27, branch `ft8cpu`. Work packages in
[PLAN.md](PLAN.md): FO3 (cheaper LLRs and belief propagation), S17 (decode scheduler) and FO2 (its effort
defaults). Background: [FT8_OFFLOAD.md](FT8_OFFLOAD.md) (FO1) and [CPU_BUDGET.md](CPU_BUDGET.md) section 8.

## 1. Result in short

- **FO3: belief propagation and LLRs cost 2.4-3 times less, with the same decodes.** The LLR set from the soft
  symbols went from 2.32 M to 0.68 M instructions and one min-sum run from 2.22 M to 0.99 M, with bit-identical
  results (same float operations; only the bookkeeping around them changed). The a-priori passes now run the
  ladder's min-sum instead of WSJT-X's sum-product (3.67 M per run before). Per failed candidate: 11.2 M to
  4.6 M for the LLRs and four min-sum runs, 25.8 M to 8.6 M with the blind-CQ pass. Sensitivity: identical hit
  counts at every SNR step in both sweeps (ordinary -21.02 dB, CQ -21.55 dB, 0.00 dB change); the three
  recordings decode the same messages at 30 and 60 candidates, one and two passes.
- **Per slot at 60 candidates, one pass** (QEMU): 124-174 M instructions per receiver (FO1: 162-244 M), cap
  315 M. The operator's receiver with two passes: 335-565 M (FO1: 449-814 M), cap 945 M.
- **S17/FO2: the scheduler** (`fw/tr-modes/src/frontend/sched.rs`): per-slot job queue for FT8 and FT4
  receivers, operator's receiver first, a CPU cap per job counted on the core's own counter, checked at
  candidate boundaries; full ladder with packed OSD on every candidate of every receiver, two passes only on the
  operator's receiver, and a candidate count per receiver that grows while a slot leaves headroom.
- **Eight receivers under QEMU** (the three recordings, three runs with the operator on each): every job within
  its cap, every receiver's decodes equal to the unrationed full ladder's, operator first; one FT8 slot of all
  eight costs 1,355-1,584 M instructions against a budget of 3,150 M (43-50 %). A job given a cap it cannot
  meet (120 M on the busy slot) stops at a candidate boundary at 107 M and reports it (14 of 18 candidates
  decoded, 12 of 15 messages).

## 2. FO3: what changed in the ladder (vendored mfsk-core, VENDOR_PATCH fix 8)

| Change | Where | Results |
|---|---|---|
| LLR bit metrics: square root of the two maxima per bit instead of one per hypothesis (512 per 3-symbol group, a libm call each on `no_std`); maxima by pairwise reduction (`nt` visits instead of `nt` per bit); no 512-entry table per group | `engine/llr.rs` | bit-identical (monotone, correctly rounded root) |
| Fused min-sum: edge tables built once per scratch; one pass over the check rows per iteration does parity, variable-to-check messages, both minima and the new check-to-variable messages | new `fec/ldpc/bp_fast.rs` | bit-identical (result, codeword, hard errors, iteration count), f32 and Q11 |
| A-priori passes: min-sum (the fused kernel with the a-priori mask) instead of sum-product | `process_candidates.rs`, `Ft8Effort::ap_min_sum` | changed algorithm; no measurable effect (section 4) |
| LLR set for OSD and the a-priori passes: reuse Steps 1-2's arrays, compute a missing variant only if OSD or the passes read it | `process_candidates.rs` | identical values |

**Q11 fixed point was measured and not adopted.** The plan row proposed fixed-point (Q11) min-sum where
mfsk-core has it. On the AE350 it is more instructions, not fewer: 2.76 M per run with mfsk-core's generic
kernel, 1.41 M with the fused one, against 0.99 M for the fused f32 kernel (the core has a hardware FPU; Q11
needs saturating adds and sign handling around every step). mfsk-core's own note says the same on the ESP32-S3
(Q11 0.85 times the speed of f32). The f32 kernel is also bit-identical to what was measured before, so no
sensitivity question arises.

## 3. Measurements

### 3.1 Per kernel (QEMU, `tools/qemu_fo1_kernels.sh`)

Mean instructions per call on 12 candidates belief propagation cannot decode (method of FT8_OFFLOAD 3.2). Every
new result was checked equal to the old one in the same run.

| Kernel | Before | After | Ratio |
|---|---|---|---|
| LLR set (four variants, up to 3-symbol coherent) | 2,316,799 | 680,357 | 3.4 |
| LLRs a and d only (Step 1) | | 84,804 | |
| Min-sum belief propagation, 30 iterations, f32 | 2,216,365 | 991,258 | 2.2 |
| Same in Q11 | 2,760,581 | 1,409,052 | 2.0 |
| A-priori belief propagation: sum-product before, fused min-sum after | 3,666,365 | 991,258 | 3.7 |
| **Per failed candidate: LLR set + four min-sum runs (Steps 1-2)** | **11,182,259** | **4,645,389** | **2.4** |
| **Same plus the blind-CQ pass's four runs** | **25,847,719** | **8,610,421** | **3.0** |

### 3.2 Per slot, one receiver (QEMU, `tools/qemu_s15.sh`, effort `full`, 60 candidates)

Instructions in millions per 15 s slot for the whole CPU part (method of S15 and FT8_OFFLOAD 3.1; target
decodes equal the host's in every run). "Ladder" is LLR/BP/OSD/a-priori/CRC/unpack, split into belief
propagation with its LLRs / OSD with its LLR set and seeds / a-priori passes. Before = FT8_OFFLOAD 3.1 (`full`).

| Recording | Passes | Decodes | Total before | **Total after** | Ladder before / after | BP / OSD / a-priori before | BP / OSD / a-priori after |
|---|---|---|---|---|---|---|---|
| qso3_busy | 1 | 15 | 194.8 | **132.8** | 134.5 / 72.5 | 76.3 / 31.3 / 25.9 | 29.8 / 31.3 / 10.2 |
| qso1 | 1 | 3 | 162.1 | **123.6** | 102.5 / 64.0 | 56.4 / 37.2 / 8.6 | 21.6 / 37.2 / 5.0 |
| qso2 | 1 | 5 | 244.3 | **173.7** | 184.0 / 113.4 | 114.3 / 69.3 / 0.0 | 43.6 / 69.4 / 0.0 |
| qso3_busy | 2 | 19 | 622.5 | **456.5** | | | 78.0 / 91.1 / 25.6 |
| qso1 | 2 | 5 | 449.3 | **330.9** | | | 61.9 / 98.1 / 19.5 |
| qso2 | 2 | 5 | 814.0 | **560.0** | | | 148.2 / 237.0 / 5.1 |

Belief propagation with its LLRs per slot fell 2.6 times (56-114 M to 22-44 M); OSD is unchanged (its seeds
are still sum-product, section 6) and is now the largest part of the ladder on two of the three recordings.
The rest of each total is unchanged: fine sync 48-49 M, reading the engines' words 11 M, subtraction 31-140 M
in the second pass.

### 3.3 Sensitivity (`ft8-frontend effort-sweep`, 200 trials per step, -23 to -18.5 dB)

Method of FT8_OFFLOAD 3.3: 20 candidates, fixed-point front end, +/-100 Hz; both efforts decode the same
audio. `full,apbp=sp` is the ladder before FO3 (sum-product a-priori passes; the other two changes are
bit-identical).

| Messages | `full` (FO3) | `full,apbp=sp` (before) | Difference |
|---|---|---|---|
| Ordinary (`<call1> <call2> <grid>`) | -21.02 dB | -21.02 dB | 0.00 dB, same hits at every step |
| CQ (`CQ <call> <grid>`) | -21.55 dB | -21.55 dB | 0.00 dB, same hits at every step |

On CQ messages the a-priori pass decoded 28 trials by belief propagation and 160 by its OSD with either
kind (spread slightly differently over the LLR variants); the rest of the rung histogram is identical.

## 4. S17 and FO2: the decode scheduler

`fw/tr-modes/src/frontend/sched.rs` (`no_std`):

- **Queue.** At each 7.5 s boundary the receivers whose slot ended get a job: FT4 receivers every 7.5 s, FT8
  receivers every 15 s. Order: the operator's receiver, then receiver order.
- **Cap per job**, in ticks of the scheduler's clock (`Budget`): `AE350` counts `mcycle`, 30 Mcycles/s per
  receiver (450 M per FT8 slot) plus 60 Mcycles/s for the operator's (1,350 M); `QEMU` counts `minstret`, the
  same at IPC 0.7 (315 M and 945 M).
- **Where the cap bites** (`DecodeParams::cap`, `decode.rs`): before each candidate's ladder, the ticks spent
  since the slot started plus a reserve (the dearest candidate so far in the slot, at least
  `Budget::cand_reserve`) must fit, or the pass stops there and `StageCounts::cut` records the pass, candidates
  done and left, ticks spent and the reserve. A second pass starts only if the first ran to the end and its
  cost fits again. The per-candidate ticks come from the same clock the ladder's `CandidateWork` uses.
- **Effort** (FO2): `Ft8Effort::FULL` on every candidate of every receiver, no `osd_max` rationing; two passes
  only on the operator's receiver.
- **Headroom goes to more candidates** (`CandPolicy`): after each slot a receiver's candidate count rises by 10
  (up to 150) when its first pass used under 85 % of its single-pass cap, and falls by 10 (down to 20) after a
  cut or a first pass over that cap. At 124-174 M of 315 M every receiver moves from 60 to 70.
- **FT4 jobs** run mfsk-core's software FT4 decoder (`run_ft4_software`): the S15 front-end model is FT8 only,
  so FT4 has no candidate hook yet; its cost is measured and reported, not cut.

### 4.1 Eight receivers under QEMU (`tools/qemu_s17.sh`)

One FT8 slot, eight receivers replayed from traces of the unrationed full ladder: receiver 0 the operator's
(two passes), receivers 1-7 cycle qso3_busy, qso1, qso2. Three runs, one per recording on the operator's
receiver. Instructions in millions ("spent" includes opening the trace and copying the slot's audio, about 3 M):

| Operator's recording | Operator: spent (cap 945) | qso3_busy receivers (cap 315) | qso1 receivers | qso2 receivers | Slot total (budget 3,150) |
|---|---|---|---|---|---|
| qso3_busy | 460.9, 19 decodes | 136.6, 15 decodes | 127.4, 3 | 177.5, 5 | 1,480.4 |
| qso1 | 335.3, 5 decodes | 136.6 | 127.4 | 177.5 | 1,354.8 |
| qso2 | 564.5, 5 decodes | 136.6 | 127.4 | 177.5 | 1,583.9 |

Every receiver's decodes equal the host's unrationed decodes of the same recording and passes; no job was cut;
the operator's job ran first. The demonstration job (qso3_busy, cap 120 M): cut before candidate 15 of 18 with
103.8 M spent and a 16.3 M reserve, 106.9 M in all, 12 of the 15 messages.

**S17's own done-test** asked for the total per slot to match the budget within 10 %. With FO3 the full ladder
at 60 candidates uses 43-50 % of it; the rest is headroom that the candidate policy turns into more candidates
slot by slot. Under QEMU the traces fix the candidate count, so the policy's effect over several slots is tested
on the host only (`sched.rs` unit tests); on the board it will show in B10's measurements.

## 5. Tests

- `cargo test -p tr-modes --test fo3_kernels`: the four LLR variants bit for bit against the pre-fix-8 code on
  300 soft-symbol sets (with integer ones, ties); the fused min-sum against mfsk-core's on 600 LLR vectors, f32
  and Q11, with and without an a-priori mask (383 failed, 217 decoded); the same messages with min-sum and
  sum-product a-priori passes on the three recordings.
- `cargo test -p tr-modes --test s17_sched`: eight receivers through the scheduler decode what the unrationed
  ladder decodes; with a clock that runs out, the slot is cut at a candidate boundary, reports it, runs no
  second pass, and decodes a subset of the uncut messages.
- `cargo test -p tr-modes --lib frontend::sched`: caps, queue order and due jobs (FT4 every 7.5 s), the
  candidate policy.
- `cargo test -p tr-modes --test fo1_effort` (unchanged, still passes): the per-candidate entry equals
  mfsk-core's multi-candidate entry.
- `tools/qemu_fo1_kernels.sh`, `tools/qemu_s15.sh`, `tools/qemu_s17.sh`: target counts; each checks target
  results against the host's.

## 6. What is left

- **The OSD seeds** (BP-refined LLR sums after one and two iterations, 0.31 M and 0.46 M, eight per failed
  candidate) are still WSJT-X's sum-product; the same fused treatment would roughly halve them but changes OSD's
  input, so it needs its own sweep. Not needed at the cap.
- **FT4** has no front-end model or candidate hook; its jobs are measured, not cut.
- **Candidate policy over many slots** runs only on the host; the QEMU traces fix the candidate count.
- **Trace format** is now version 3 (carries `ap_min_sum`); version 2 traces no longer load.
- **Instructions, not cycles**: IPC 0.7 still assumed (PLAN B10).

## 7. How to reproduce

```sh
cd <repository root>
bash tools/fetch_test_audio.sh
cd fw
cargo test --release -p tr-modes --test fo3_kernels --test s17_sched --test fo1_effort
cargo run --release -p tr-modes --bin ft8-frontend -- effort-sweep -23 -18.5 0.5 200 std 20 full "full,apbp=sp"
cargo run --release -p tr-modes --bin ft8-frontend -- effort-sweep -23 -18.5 0.5 200 cq 20 full "full,apbp=sp"
cd ..
bash tools/qemu_fo1_kernels.sh
S15_JOBS=6 S15_SETTINGS="60:1:full:all 60:2:full:all" bash tools/qemu_s15.sh
bash tools/qemu_s17.sh
```
