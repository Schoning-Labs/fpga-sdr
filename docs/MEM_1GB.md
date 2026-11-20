<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# WP LS7: the board's whole DDR3 (1 GB) for the processor and the logic

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Written 2026-10-12, branch `ddr1g`. Owner 2026-10-12: "I want the 1G RAM for the RISCV"; build 1 GB, keep 256 MB as
the fall-back, measure the processor's memory speed on the board later. **Nothing here has run on a board.**
This document holds the design of the 1 GB memory.

## 1. Result

| Question | Answer |
|---|---|
| Memory | 1 GB (both chips, 32 data lines, 15 row lines) for the processor at 0x0000_0000 to 0x3FFF_FFFF and for both lanes of the logic. Before: 256 MB of one chip |
| Way | AE350 data memory = "Customized Data Memory" (its bus `DDR_H*` comes out of the block), Gowin's DDR3 IP in the logic, the bridge `rtl/mem/ddr_mem.v` between the IP, the processor's bus and our two lane arbiters |
| Fall-back | `TR_DDR=256 gowin/p1/build.sh`: the AE350's own controller, 256 MB, as before. One switch; it tells a board fault from a fault of the bridge |
| The arbiters | Unchanged. The bridge's **write lane had to be rewritten** and its processor side changed (section 3): taken over as it was, the first word of every write burst would have gone to the wrong address, and the processor would have read old data from memory the logic had written |
| Memory map | `docs/ARCHITECTURE.md` 5.4 already places frame buffers, rings and raw capture at 0x1000_0000 and above. That is beyond 256 MB: the map needed the 1 GB all along and now has it |
| Verified | Simulation only (section 5) and one synthesis of the whole chip (section 7) |

## 2. Manuals used

| Document | Sections | Taken |
|---|---|---|
| MUG1031-1.3.1E, AE350 hardware manual | table 4-1 and its note; chapter 5 port table (`DDR_H*`: "Customized Data Memory"); 8.2.3 | DDR clock "less than 200 MHz"; core, DDR and AHB/APB clocks asynchronous to each other; the data memory bus is AHB with 64 data lines. The wrapper `riscv_ae350_top.v` in the install says "DDR bus clock in, up to 250 MHz". No document gives the bus's burst types |
| IPUG281-2.6E, Gowin DDR3 Memory Interface IP | 4.4.2 to 4.4.9, table 6-1, 7.1 | **Not re-read here.** The bridge's IP side is unchanged from its first version |
| SUG940 (timing constraints) | `create_generated_clock`, `set_clock_groups` | the new clock is declared with `create_generated_clock`; a second `set_clock_groups` statement is used so that the shared line is not edited (to be confirmed by the first place-and-route) |
| Gowin install V1.9.11.03 and V1.9.12.04, `IDE/ipcore/RiscV_AE350_SOC/data` | `riscv_ae350_top.v`, `DDR3_TOP.v`, `ddr3_name.v`, `DDR3_define.v` | the six files the build uses are byte for byte the same in both versions, so results from one version hold for the other |

Used of the IP: controller with PHY, 32 data lines, clock ratio 1:4, burst of 8, automatic refresh, write mask.
Not used: AXI4 side, ECC, user refresh, self-refresh, termination on the FPGA side (the first thing to try if
calibration fails on the board).

## 3. The lanes against our arbiters, signal by signal

`docs/TANG_LESSONS.md` section 1 expected the arbiters to fit as they are. The read lane does. The write lane did
not; the processor side had a fault that only shows when the processor reads what the logic wrote.

**Read lane (lane 5), `rtl/ddr3/ddr3_read_arbiter.v`: fits, nothing changed.**

| Signal | Arbiter | Bridge (`ddr_mem_rdlane`) | Verdict |
|---|---|---|---|
| `addr_lane5` | 64-bit word address, held while `rd_en` | read in the clock with `rd_en` and `rd_rdy` | same |
| `burstcount_lane5` | 1 to 255 words; clients never ask for 0 | 1 to 255; a request for 0 is ignored (the arbiter would wait for ever) | same for every client we have |
| `rd_en_lane5` | high while idle with a request, until accepted | accepted in a clock with `rd_rdy` | same |
| `rd_rdy_lane5` | "lane free for the next request" | low from acceptance until the last word is out | same |
| `rd_valid_lane5`, `rd_data_lane5` | counts `burstcount` beats, then one settle clock | exactly `burstcount` beats, in address order | same |
| `rd_go_lane5` | pulsed after acceptance | not connected | not needed |

**Register stage in front of the read lane (WP TCLOSE2, `rtl/ddr3/ddr3_rd_relay.v`, in `sdr_core.v`).** In the full-chip
build ls6 the FT8 sync engine's read request ran through the front end's share, the arbiter and the lane's line, count and
word registers in one clock (8 to 12 levels, 65 failing end points at 120 MHz). The relay is the arbiter's lane
(`a_rdy` high = the request is taken) and the lane's arbiter (`l_en`, `l_addr`, `l_burst` held until the lane's `rd_rdy`);
`a_rdy` comes back when the lane has taken the request and is ready again, so one burst is outstanding at a time, as
the arbiter already required. `rd_go` is one clock after the lane took the request. Data beats do not pass through it.
Cost: the request reaches the lane one clock later and the next one waits for `a_rdy` one clock after `rd_rdy`: two
`clk_dsp` clocks per burst. `sim/mem/tb_ddr_mem.v` now drives the read lane through the relay as the write lane goes
through its own: test 4, read lane with 180-word bursts back to back beside the other two sides, **839 MB/s (846
before)**; test 7, 180 words alone, 853 MB/s (unchanged, the memory limits it); the compositor needs up to 519 MB/s.

**Write lane (lane 4), `rtl/ddr3/ddr3_write_arbiter.v`: the bridge's lane was rewritten.**

| Signal | Arbiter (and `sim/ddr3/ddr3_lane_behav_model.v`) | Earlier lane | Now |
|---|---|---|---|
| start of a burst | `wr_en` goes up in the idle clock; `wr_go` is a register and comes **one clock later** | a burst starts with `wr_go`, which must come with or before the first beat | the first beat taken after a burst has ended starts the burst; `wr_go` not connected |
| `addr_lane4`, `burstcount_lane4` | held for the whole burst | read with `wr_go` | read with the first beat; length 0 counts as 1 (as the model) |
| `wr_mask_lane4` | 8 bits, 1 = byte written | 4 bits, 1 = two bytes **not** written | 8 bits, 1 = byte written |
| `wr_wait_lane4` | a beat is taken in a clock with `wr_en` and without `wr_wait` | same | same; also high in the `wr_done` clock |
| `wr_done_lane4` | one clock after the last beat is in; `wr_en` is masked in that clock | one clock after the last word is in the controller | same |

With the earlier lane the first beat is taken before `wr_go`: it would go to the word after the end of the burst
before, and the burst's count would be one short. The earlier design never met this, because its one writer raises
`wr_go` with the first beat. Board check B4 (mask polarity, address units) is settled: our own file defines both.

**Processor side (`ddr_mem_ahb`), two things.**

- *Old data read back (fixed).* The bridge holds one 32-byte line. The first version kept a line it had read until another
  line was asked for. If the logic wrote into that line meanwhile, the processor got the old bytes, for as long as
  it asked for no other line: a loop that polls a ring word would never see it change. A processor that
  never reads what the logic writes would not notice; ours reads the receiver rings. Now a line read from the memory serves only an
  unbroken run of bus transfers and is dropped at the first idle bus clock (parameter `RD_KEEP` = 1). A cache line
  fill (four beats in a row) still costs one memory read. The bridge test fails on this with the old behaviour
  (96 errors) and passes with the new.
- *Processor writes reach the logic late (not fixed, a firmware rule).* A line the processor has written stays in
  the bridge until the bus asks for another line or has been idle for 256 bus clocks (5.1 us at 50 MHz, parameter
  `WR_IDLE`). The read lane does not see it before. **Rule for firmware: after writing data the logic will read
  (audio ring, TX ring, frame buffer) and writing the cache back, wait 10 us before moving the pointer the logic
  follows.** In normal running the readers are milliseconds behind the write pointer and never meet this.

## 4. Priority and the bus clock

**Priority inside the bridge: read lane, then write lane, then processor**, one memory command at a time, never
interrupted. The read lane may have 16 lines under way; while its FIFO is full the others get the command slots.
Inside the read lane our arbiter keeps its tiers: video first, audio and TX rings next, FT8 last; a burst that has
started is finished.

| Load (bridge test, everything at once, DDR3 IP as a model whose ready signals drop 25 % of the time) | Reached | Needed (`docs/ARCHITECTURE.md` 3.9, `docs/F4_DDR.md` 3) |
|---|---|---|
| Read lane, 180-word bursts back to back | 846 MB/s | 374 MB/s (video 373.2, audio and TX rings 0.4) |
| Write lane, 4-word bursts back to back, while the read lane runs flat out | 46.8 MB/s (104 MB/s alone) | 26.4 MB/s (receiver rings 24.6, waterfall 0.2, FT8 1.6) |
| Processor | 3,000 accesses in 1.8 ms beside both | not specified |

- **Video read tier (ARCHITECTURE risk 4).** A video request waits for at most the one memory command already in
  front of the IP, plus whatever the IP itself inserts (refresh every 7.8 us, 260 ns). The processor can no longer
  hold the video off, which was the open question with Gowin's shared controller. In our arbiter a single-word
  audio, TX or FT8 read that has started is finished first. `sim/ddr3/tb_ddr3_video_no_starve.v` was not re-run
  through the bridge (it models the old lane, and the compositor is a stub).
- **Raw capture does not fit the write lane as it is.** The lane makes one memory write per 64-bit word: 104 MB/s
  at best, raw capture needs 153.6 MB/s. It is not built. When it is, the lane has to collect four words into one
  memory write (about four times the rate); that is a change to `ddr_mem_wrlane` only.
- **Bus clock of the processor side: 50 MHz, as now** (the AE350 PLL's `DDR_CLK` output; the bridge's bus side runs
  on that net). It is Sipeed's value; builds of this bridge with the bus side at 80 to 122 MHz also met
  timing. In the bridge test a 32-byte cache line read takes 423 ns at 50 MHz and 292 ns at 100 MHz (the
  rest is the memory's own latency, which a faster bus clock does not shorten; the IP's latency in the model is our
  reading, not measured). So 100 MHz would give about 30 % on cache misses, and needs the bus side to meet 100 MHz.
  Changing it is one divider in `gowin/p1/ip/gowin_pll_ae350.mod` and one number in the `.sdc`. Decide after the
  board measurement (`tr-bench` FT8 kernel in DDR3, 1 GB build against the 256 MB build).

## 5. What is simulated

| Test | Shows | Result |
|---|---|---|
| `sim/mem/tb_ddr_mem.v` (iverilog) | 7,000 random bus accesses of 1 to 8 bytes against a byte reference; every written byte in the memory after a rest; read bursts of 1 to 255 words; the write lane driven as our arbiter drives it (request up before the burst, held until `wr_done`, bursts back to back, byte masks, length 0); all three sides at once with the rates of section 4 checked against the budget; the top line of the 1 GB; processor read, logic write, processor read | PASS |
| the same with `-DRD_KEEP=255` (the old behaviour) | that test 6 catches the old-data fault | FAIL, 96 errors, as it must |
| the same with a 100 MHz bus clock (`-DHCLK_HALF=5.03`) | the figure in section 4 | PASS |
| `sim/top/tb_sdr_core.v` | the whole core with its lanes through the bridge into the DDR3 IP model: receiver 0's ring words land at their addresses; **new:** every word the write arbiter gave is compared with the model's memory; the model saw no fault | PASS (6 lane beats in the run, 5 different words compared) |

Not simulated: Gowin's DDR3 IP itself (the model is a reading of IPUG281), calibration, the pins, the
AE350's bus (the test bus is plain AHB-Lite), the top level `sdr_top.v` (vendor primitives), the reset order,
the size probe (compiled for the target only), the 256 MB build after this change (its project was generated and
compared: the same sources and constraints as before).

## 6. Files

| File | What |
|---|---|
| `rtl/mem/ddr_mem.v` | the bridge; changes listed in its header |
| `rtl/ddr3/ddr3_rd_relay.v` | the register stage in front of the read lane (above) |
| `sim/mem/tb_ddr_mem.v`, `sim/mem/ddr3_ip_model.v` | its test and the IP model (model unchanged) |
| `hw/gowin/mem/gwmc_param.v` | the IP's settings: Sipeed's for this board (DQ 32, row 15, tRFC 260 ns, CL 6, CWL 5, 400 MHz), unchanged when this was written; the file now sets a 300 MHz memory clock (tCK 3,333 ps, CL 5, CWL 5) |
| `gowin/p1/ip/riscv_ae350_soc.ipc` | now "Customized Data Memory"; `riscv_ae350_soc_256.ipc` is the old configuration; `ipc_to_config.py` knows the new key |
| `gowin/p1/build.sh` | `TR_DDR=1024` (default) or `256`: AE350 configuration, IP source list, include path, `` `TR_DDR_256 ``, and the build's copy of the constraints without the "DDR3-1G-ONLY" blocks |
| `rtl/top/sdr_top.v` | ports of the second chip, the bridge, AE350 bus, reset; all between "DDR3 begin" and "DDR3 end" |
| `gowin/p1/sdr.cst` | 20 more pins (data 16 to 31, strobes 2 and 3 as pairs, masks 2 and 3); address line 14 is now a real address line (ball U5, was held low) |
| `gowin/p1/sdr.sdc` | clock `ddr3_sys` (the IP's user clock, 75 MHz at the 300 MHz memory clock; it was 100 MHz at 400 MHz) and its asynchronous group |
| `fw/tr-ae350/memory-ae350.x` | the map of ARCHITECTURE 5.4 above the heap named (`DDR_FABRIC`); code and heap unchanged |
| `fw/tr-ae350/src/memprobe.rs` | size probe for the start-up test: prints the size found and PASS when it is the size the bitstream is built for. No start-up program for the board exists yet (B3); it has to call `size_probe` and `size_line` |

**Reset.** The DDR3 controller starts with the key and the DDR3 PLL. The AE350 is held in reset until the
controller reports calibration done. LED 0 lights when the memory is up: memory dead = LED dark and no UART text.
The lanes hold their clients off (`wr_wait` high, `rd_rdy` low) until then.

## 7. Cost

One synthesis-only run of the whole chip with the 1 GB path (Gowin V1.9.11.03, 591 s, no errors; counts are
synthesis counts, before place-and-route; `tools/gowin_hier.py`). No place-and-route, so no timing.

| Part | LUT | ALU | Registers | Block RAM | LUT-RAM cells | DSP |
|---|---|---|---|---|---|---|
| Whole chip | 53,179 | 18,921 | 55,050 | 217 | 696 | 91 |
| Memory path `u_mem` | 4,520 | 252 | 7,316 | 16 | 134 | 0 |
| of it Gowin's DDR3 IP, 32 data lines | 3,278 | 190 | 5,668 | 16 | 0 | 0 |
| of it the bridge (core, two FIFOs, bus side, two lanes) | 1,242 | 62 | 1,648 | 0 | 134 | 0 |
| AE350's part in the logic (flash controller; its DDR3 controller is gone) | 692 | 55 | 227 | 0 | 64 | 0 |

- **Against the 256 MB build: not measured here** (one Gowin run was allowed). The same change measured
  on a small design: about 1,900 logic cells more (1.4 % of this chip's 138k), block RAM the same.
- Pins: 20 more (95 to 115 of 312), all in the DDR3 bank.
- Clocks: one more generated clock (`ddr3_sys`, 75 MHz at the 300 MHz memory clock the radio runs, 100 MHz when this was written for 400 MHz, made inside the IP), and the 50 MHz DDR-bus clock now
  also clocks logic. No PLL changed.
- Synthesis warns (EX2478) that start values on output registers of the bridge are ignored in SystemVerilog mode.
  Every one of those registers is set by the bridge's reset, which is held until the memory is calibrated.

## 8. Open

- First board run: calibration with 32 data lines; the AE350's data memory bus (assumed plain AHB-Lite with
  `HREADY` as its only wait); the size probe must print 1,024 MB.
- If the AE350 puts idle clocks between the four beats of a cache line fill, every beat costs a memory read and
  misses get about four times slower. It would show in the board measurement; `RD_KEEP` is the parameter.
- Clock lines: the build has two more clocks in the logic (`ddr3_sys`, and the 50 MHz DDR-bus clock now also runs
  the bridge's bus side). The chip has 16 global clock lines (8 primary and 8 LW, Gowin UG306 section 2.1); check the clock table of the first place-and-route.
- Firmware: the 10 us rule of section 3, and a start-up program that calls the probe.
- Raw capture needs the faster write lane (section 4).
- The 512 MB form of the bridge (`HALF`) is neither built nor tested here.
