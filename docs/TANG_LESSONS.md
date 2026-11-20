<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# What we learned about this board and Gowin's tools

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

> **Owner 2026-11-12: no usage limits.** Any percentage limit below (75 % block RAM, 80 % logic) is void. Use up to 100 %; the only test is timing closure and the board. The numbers stay as measured facts.


Written 2026-10-12, branch `lessons`. Collected from earlier designs built on the same Tang Mega 138K Pro with the
same Gowin tools. Follow-up work: docs/PLAN.md, section "Proposed by lessons".

**Two limits on everything below.** (1) **Nothing below had run on a board when this was written.** "Works" below
means: built, simulated, and place-and-route passed with no failing end point. (2) The measurements are on Gowin
V1.9.12.04 unless marked (11) for V1.9.11.03, the version this project built with at that time. Both are installed on this
PC (`C:/Gowin/Gowin_V1.9.12.04_x64/IDE`).

## 1. The whole 1 GB DDR3 for the AE350 and the logic

Our P1 build reaches 256 MB of one chip (docs/P1_TOP.md section 2). An earlier design reaches 1 GB (both chips, 32 data
lines, 15 row lines), built and simulated, timing met.

| Way | Reaches | Verdict |
|---|---|---|
| The AE350 block's own DDR3 port with "Customized DDR3 Settings" (own `gwmc_param.v`) | 256 MB | Not possible: `riscv_ae350_top.v` has `DDR3_ADDR[13:0]`, `DDR3_DQ[15:0]` whatever the settings say |
| "Customized Data Memory" + Gowin's / Sipeed's bridge `gw_ahb_ddr3.v` | 64 MB | Written for 16 lines, no lanes for the logic, Gowin copyright. Sipeed's own demo does not reach 1 GB |
| Customized Data Memory + DDR3 IP's AXI4 side + bridges | 1 GB | More logic, 4 more block RAMs, three vendor blocks |
| **Customized Data Memory + DDR3 IP's plain user interface + own bridge** | **1 GB** | **Chosen** |

What has to change here, file by file:

- **AE350 configuration** (`gowin/p1/ip/riscv_ae350_soc.ipc`, `ipc_to_config.py`): data memory = "Customized Data
  Memory" (define `AE350_EXT_D_MEM_EN`) instead of `ENABLE_DDR3` / `sharedDdr3RWMode`. The block's data bus comes
  out as AHB-Lite, 64 data bits, port `DDR_H*` (MUG1031 8.2.3). Lanes 4 and 5 of the block go away.
- **IP sources** (`gowin/p1/build.sh`, list `ip_src`): drop `riscv_ae350_ddr3.v`, `fifo_top_32to128.v`,
  `fifo_top_128to32.v`; keep `DDR3_TOP.v`, `ddr3_1_4code_hs.v` (the 1 GB design's list also has `gw_dtcm.v`,
  `gw_itcm.v` with two small config files: check whether our flash-boot configuration needs them). Put our own
  `gwmc_param.v` (plus the install's `DDR3_define.v`, `ddr3_name.v`, `gwmc_local_param.v`) on the include path
  instead of `ddr3_default_settings`. Settings: Sipeed's `gwmc_param.v` for this
  board (`DQ_WIDTH` 32, row 15, tRFC 260 ns, tRCD/tRP 15 ns, CL 6, CWL 5, RTT_NOM 60 ohm, 400 MHz).
- **Bridge**: a new `rtl/mem/ddr_mem.v` (599 lines in the 1 GB design) and `sim/mem/tb_ddr_mem.v` (7,000 random bus accesses
  against a byte reference, lane bursts, all at once). One "line" = one DDR3 burst = 8 x 32 bits = 32 bytes = one
  line of the CPU's data cache. Priority: read lane, write lane, processor. The CPU side holds one line and writes
  it back after 256 idle clocks. Two 16-entry, 256-bit FIFOs in LUT RAM: **no block RAM**. Read lane: 1 to 255
  words of 64 bits; write lane: one 64-bit word per write with a mask (1 = not written, per 16 bits). The lanes
  were written to the same reading of lanes 4 and 5 as our `rtl/ddr3/ddr3_read_arbiter.v` and
  `ddr3_write_arbiter.v`, so the arbiters should stay as they are (to be checked signal by signal); board check
  B4 (mask polarity, address units) stops being a guess about Gowin's block, because our own file defines it.
- **Pins** (`gowin/p1/sdr.cst`): add DQ 16 to 31, DQS 2 and 3, DM 2 and 3, address line 14 (ball U5) from
  Sipeed's `ae350_customized_demo` .cst. A15 (M6) is not connected.
- **Constraints** (`gowin/p1/sdr.sdc`): the IP's user clock, 100 MHz = memory clock / 4:
  `create_generated_clock -name ddr3_sys -source [get_pins {u_pll_ddr3/PLL_inst/CLKOUT2}] -master_clock
  ddr3_memory_clk -divide_by 4 [get_pins {<bridge>/u_ddr3/gw3_top/u_ddr_phy_top/fclkdiv/CLKOUT}]`, own
  asynchronous group. The tool puts it on a global line by itself.
- **Reset**: the processor is held until the IP reports calibration done (we do not hold it today: P1 section 2).
- **Firmware** (`fw/tr-ae350/memory-ae350.x`): the map stays valid (data memory window 0x0000_0000 to
  0x7FFF_FFFF; everything we use is below 256 MB). `DDR_HEAP` may grow from 240 MB to 1,008 MB. Add a
  size probe to the start-up test: a marker at base and at base + 2^k, k = 30 down to 20; it prints the size found.

| Cost (measured in synthesis and ladder builds) | 32 lines, 1 GB | 16 lines, 512 MB (`DDR_512MB`) |
|---|---|---|
| Gowin DDR3 IP | 3,178 LUT, 5,670 registers, 32 blocks | 2,114 LUT, 3,524 registers, 16 blocks |
| Bridge and lanes | 1,161 LUT, 130 LUT-RAM cells, 1,599 registers | 784 LUT, 66 cells, 1,090 registers |
| Whole memory path | logic 5,372, registers 7,280 | logic 3,483, registers 4,625 |

Against the same small design on the block's own 16-line port: about **+1,900 CLS (2.7 % of the chip), block RAM
the same** (the block's own controller and its two FIFOs leave). `ddr3_sys` met 100 MHz in every build (103 to
127 MHz); its slowest paths are inside Gowin's IP (9.7 of 10 ns), not in the bridge. Peak rate doubles to 3.2 GB/s,
which is what docs/ARCHITECTURE.md 3.9 assumed in the first place.

**Open, and it matters more for the radio than for the synth:** the CPU's memory speed through the bridge is not
measured (estimate: 0.5 us per 32-byte cache line at a 50 MHz bus clock; the bus clock may go to 200 MHz, MUG1031
table 4-1). The FT8 decode lives in DDR3 (docs/CPU_BUDGET.md). Measure it on the board before the 256 MB build is
retired. Also not verified: that the IP calibrates with 32 lines on this board, and the `DDR_H*` bus protocol.

## 2. Audio outputs

One block, `rtl/audio/audio_digital_out.v`, takes one 48 kHz, 24-bit stereo stream and feeds three outputs at
once; the headphone DAC stays beside it. None has been heard yet.

| Output | How | Pins | For the radio |
|---|---|---|---|
| Headphone / speaker DAC (PT8211) | 16 bit, LSB-justified, held samples: feed it at 96 kHz or more (48 kHz straight leaves the image of a 20 kHz tone 3 dB under the tone); 16-bit dither | **BCK E22, WS F24, DIN G24** | We have it (A1, x8 interpolation). **Our pin file has BCK and DIN swapped** (section 9) |
| S/PDIF, 24 bit | sender on the audio clock; 3-pin TOSLINK transmitter module on a PMOD pin, nothing else | B21 = PMOD2 (J26) pin 12 | Cheap digital out to a hi-fi DAC or PC |
| I2S for a Pi-type DAC board | bit clock 3.072 MHz, word clock 48 kHz, data, master clock 12.288 MHz; Philips format, 24 in 32 | B20, A20, B19, A19 = J26 pins 9, 10, 7, 8 | Better analogue out than the PT8211 (89 dB). Pin-configured DAC chips only (PCM5102A class): no I2C built |
| USB audio | USB Audio Class 1.0, full speed, no driver: the board is a 48 kHz, 24-bit stereo **recording** device plus USB MIDI; own soft PHY and core (`rtl/usb/*.v`, 8 files, 48 MHz clock) | "Custom USB" socket: D+ T19, D- U19, pull-up switch M19 | RX audio to a PC with one cable. The playback direction (PC to radio, for TX audio) is not built |
| HDMI audio | an earlier board build carried 16-bit audio in HDMI packets through the same hdl-util core we use; it was then dropped there for size | - | See below |

- **J26 pin numbering** is 1-2 = 3.3 V, 3-4 = GND, 5-12 = IO3, IO7, IO2, IO6, IO1, IO5, IO0, IO4. It is not the
  Digilent order. PMOD2 pins 5 and 6 (A17, A18) are free.
- **An exact audio clock from the 50 MHz oscillator needs two PLLs in a row**: 12.288 MHz = 50 x 768 / 3,125, and
  3,125 = 5^5 cannot be divided out in one PLL (phase detector at least 19 MHz). PLL 1 (the DSP PLL, VCO 1,200
  MHz) output / 25 = 48 MHz (also the USB clock); PLL 2: 48 MHz x 16 / 15.625 = **49.152 MHz = 1,024 x 48 kHz**
  (`-odiv0_sel 15 -odiv0_frac_sel 5`; only output 0 has the fraction, in eighths). Constraint: `create_generated_clock ... -multiply_by 128 -divide_by 125`; both
  clocks on global lines (`CLOCK_LOC "clk_usb" BUFG[8] = CLK; CLOCK_LOC "clk_aud" BUFG[11] = CLK;`). Whether
  PLL 2 locks behind PLL 1 is a board question. Gowin's jitter limit is 4 % of the period (0.8 ns): enough for
  S/PDIF, unknown for a 110 dB DAC.
- **Two free-running 48 kHz rates slip.** A phase-accumulator tick is off by 0.005 to 0.02 ppm against the PLL's
  clock: one sample too many every 17 to 69 minutes. `audio_digital_out` keeps 8 samples between the clocks and takes a
  slip out over 64 frames by a straight-line blend. We have the same case twice: `audio_nco_tick` against the
  HL2's sample clock (WP A2 plans a DPLL), and any digital output against it.
- **HDMI audio here is swept away** (P1 section 9). In the earlier design it was not, with the same core: there the
  samples came from a real source in another domain, latched first, and the 48 kHz clock rose 8 DSP clocks later.
  Three things to check in ours: the tone generator is the only source and is clocked by the made-up clock;
  `clk_audio` is a register output on ordinary wiring (section 5: such a clock must be on a global line);
  and the accumulator step in `rtl/top/sdr_top.v` (2,748,779, "2 x 48,000") makes bit 31 turn at
  **96 kHz**, not 48 (step x 150 MHz / 2^32). The last is arithmetic only, not simulated.

## 3. Fan-out

**On this chip the routing delay of a net follows its number of loads, not its length.** Measured: 23 loads two
rows away 3.75 ns; 27 to 54 loads 3.7 to 4.2 ns; 1 to 6 loads over the same distance 0.5 to 1.6 ns. Taking logic
depth out and leaving the fan-out made a block slower (208 to 180 MHz); limiting fan-out on the same RTL gave
230 MHz, and with hand copies 240 MHz. Our own reports say the same (gowin/reports/README.md: "a net with a
fan-out of 100 to 250 costs 3 to 5.5 ns"), but we fixed it net by net.

- **Module attribute, behind the port list**: `module m (...) /* synthesis syn_maxfan = 10 */;` (in one comment
  with `syn_srlstyle` where a module has both). The tool copies registers and LUTs, also registers kept by name,
  and does not merge its copies again. It reaches every instance below; a sub-module that names its own value
  gets that value. We use `syn_maxfan` in 4 places only.
- **Not covered: clock enables, synchronous resets, memory write enables, a DSP block's output pins.** Copy by
  hand: one kept copy per 8 to 13 loads, written `r <= {N{x}}` into a kept vector, **loaded one clock ahead**.
  A DSP sign bit: a product of n bits has 48 - n equal pins above it; take the copies from different pins.
- **Cost and scope**: the limit on a whole 16-voice engine cost 3,110 registers and 884 LUT (2.5 % of the chip).
  Put it on the units that run at the fast clock; a unit at half clock names 10,000 to opt out.
- **A selection as a reset**: two sources, each in a register that is reset when the other is meant (the
  register's synchronous reset costs no LUT); the consumer takes their OR.
- **Words that cross between blocks far apart**: two registers, and a copy per consumer before any selection.
  A register behind every word that leaves a block for several consumers.
- **Where it applies first**: `rtl/rx/cic_var_shared.v` (the per-context `rst[c]` drives the clock enables of
  every `integ` / `cmb_out` / `cmb_prev` register: 14.0 ns) and `rtl/rx/fir_decim.v`, `rx_bank.v`; then
  `rtl/top/sdr_core.v` (page strobes), `rtl/spectrum`, `rtl/rx_backend/bk_post.v`.
- Tool: `python tools/gowin_fanout.py <netlist.vg> --depth 3 --top 40` lists the nets with the most loads, their
  driver and where the loads are, from a synthesis-only run (minutes, no place-and-route).

## 4. Block RAM and logic

Block RAM is our scarce resource (261 of 340, heading for 86 to 93 %). An earlier design went from 268 to 174 blocks in
one build by the steps below, and found that **timing depends on it: keep block RAM under 75 %** (162 to 200 MHz
came from register stages, block RAM under 75 % and split memories; Gowin calls 80 % excessive, SUG113 4.3.2).

| Trick | Measured | Where here |
|---|---|---|
| Memories of 16 or 32 words out of block RAM into LUT RAM: `syn_ramstyle = "distributed_ram"` on the memory, same registered read | 34 blocks for about 540 cells (0.8 %) | `python tools/gowin_mems.py <vg> --mem` lists every block RAM with words and bits in use. First run on F5 shows a 32 x 64 FIFO in 4 blocks and a 32-word ROM in 2 |
| Small ROMs in LUTs: `syn_romstyle = "distributed_rom"` on the ROM's output register | 18 blocks for 425 LUT and 280 registers | twiddle and coefficient ROMs of 64 words or fewer (`rtl/fft`, `rtl/tx`, `rtl/audio`) |
| A table read at two addresses per clock: one dual-port block used read-only (one read per port) instead of two ROMs; widths in 18-bit primitives, not 32 | 28 to 12 blocks, no logic | `rtl/rx/nco_mixer.v` sine tables, window and ratio ROMs in `rtl/spectrum` |
| Count the way place-and-route counts: a primitive wider than 18 bits is 2 blocks | `gowin_mems.py` does; the synthesis report does not | already our rule (gowin/reports/README.md) |
| One memory chip instead of two (`DDR_512MB`) | 16 blocks and 1,975 cells | only if 1 GB is given up (section 1) |
| Fixed pipelines, not general programmable engines; no soft CPU (Hazard3 about 55 MHz here) | 60 % of a general lane was operand RAM and capture multiplexers | agrees with docs/FT8_OFFLOAD.md (no soft core) |
| Remove what only one function needs before optimising it | a 5-instrument mixer and an 8-channel decimator (5,000 cells) had one user left | P1's zoom half of the spectrum pipeline is built with an idle input |

Sizing rules: never estimate from a block that looks similar (3 to 5 times too low, three times); confirm with a
synthesis-only run (`gowin/p1/build.sh --syn`, minutes) and `tools/gowin_hier.py`. Stay at or under about 80 %
of the logic cells: above 90 % the router does not finish and Fmax swings 10 % between runs.

## 5. Timing: depth, margin, hold, clocks

- **Judge a build by the timing report's totals of failing end points, setup and hold, over all clock pairs**,
  not by the per-clock Fmax table: a failing path between two related clocks is not in that table.
  `python tools/gowin_verdict.py <..._tr_content.html>` prints the totals; `gowin/p1/build.sh` now ends with it.
- **Compare path classes, not Fmax.** One placement's Fmax is not a measurement of a fix (the same block gave
  198, 185 and 160 MHz over three trees), and a result at a constraint the design cannot meet says little (194 MHz
  at a 240 MHz constraint, 179 at 210, same netlist). `python tools/gowin_classes.py <html> clk_dsp 6.667` groups
  the listed paths by start and end register and shows cell delay, route delay and the largest fan-out per class.
  Ask for more than the default 25 paths: `report_timing -setup -max_paths 300` (`GOWIN_REPORTS=1`).
- **Depth rule: 1.95 ns of cells per path at 200 MHz** (three LUT levels, or one 18-bit carry chain). Chip figures
  (DS1239, grade C1/I0, and reports): LUT4 0.52 ns, register clock-to-output 0.34 ns, carry chain 0.5 ns entry +
  0.045 ns per bit + 0.27 ns: 16 bits 1.8 ns, 26 bits 2.2 ns, 33 bits 2.5 ns. At our former 150 MHz that was about 2.9 ns (at 120 MHz about 3.6 ns, or 4.5 ns with the margin: 7.92 ns)
  of cells: 4 LUT levels or one 32-bit add, **never two chained adders in a clock** (7.6 ns measured).
- **Margin: constrain 5 % tighter than the real clock** (`TIMING_MARGIN_PCT=5`: 126 MHz for `clk_dsp` at 120 MHz, a 7.92 ns period; 157.5 MHz, 6.35 ns, at the former 150 MHz). A build
  is clean when it meets the tightened clocks. The earlier design then passed three of three fresh folders.
- **Every clock on a global line.** The chip has 16 (0 to 7 "PRIMARY", 8 to 15 "LW", which the tool fills with
  resets). `CLOCK_LOC "net" BUFG[n] = CLK;` with n = 8 to 15 puts a clock on an LW line (skew 0.00 to 0.03 ns).
  A clock on ordinary wiring gave hundreds of hold failures in a full design, although a trial in an empty chip
  passed. Ours to check: `clk_audio`, `clk_rx` (from the RGMII pin), `clk_tx`, `clk_25`.
- **Hold**: `-correct_hold_violation` is on by default and repairs through routing; leave it. Hold failures left
  after that were clocks off the global lines. Our five RGMII hold failures (-4.4 ns) are pin timing, not this.
- **Do not feed several clock inputs of the AE350 from one net** to save a line.
- **AE350 bus clock**: at 100 MHz AHB Gowin's own flash controller inside the block only reached 69.1 MHz in
  an earlier design's first build (11); that design has run AHB and APB at 50 MHz since. Ours failed 100 MHz by 7 end points and reached
  91.7 to 109 MHz across layouts; **fpga-sdr runs AHB and APB at 80 MHz since 2026-10-13** (docs/DECISIONS.md).
- **Same tree, same result** holds only for place-and-route repeated on one synthesis project; a fresh folder
  with a fresh synthesis is a new draw (200.3 against 196.8 MHz). Keep a passing build as commit + bitstream +
  post-place file. The incremental flow (`-inc_pnr`) was refused in every documented form.
- **Pinning hard blocks made every build slower** (120 to 131 MHz against 200): the placer does not put a
  block's logic near a pinned DSP or block RAM. Do not floorplan. Fix the design, then build.

## 6. Fast pipelines on this chip (read before writing RTL for 150 MHz or more)

- **DSP block (`MULTALU27X18`): instantiate it**, with the input and the output register (286 MHz; one stage
  203 MHz). Inference drops input registers and never uses the cascade. A multiply-add is 2 clocks; `a x b + c`
  (48-bit c) needs no fabric adder; the pre-adder gives `(a - d) x b + c` at 280 MHz; a sum of products goes
  through the cascade at one clock per block. The block has no shift.
- Block output into logic: register first unless the logic is one adder next to it. A long carry into a block
  input: register first. Saturation behind an adder is its own clock, on the bits the product really has.
- Block RAM: address register, then the output register (0.3 to 0.4 ns clock-to-output with it, 1.4 to 1.8 ns
  without), then a registered selection. LUT RAM: one address register per memory and per 48 bits of width;
  above 32 words use block RAM. A LUT RAM read without a register into an adder fails (208 MHz for 26 bits).
- `{a, 1'b1} + {b, 1'b1}` for a + b + 1 (written plainly Gowin builds two adders).
- **Remove waits before speeding anything up**: write the clock table of the pipeline first.
- Check every DSP mapping by simulating the synthesized netlist with `IDE/simlib/gw5a/prim_sim.v`.
- Applies directly to `rtl/rx/fir_decim.v`: tap index -> subtract -> coefficient ROM read without a register ->
  multiply -> accumulate is one clock today (18 levels, 14.4 ns).

## 7. Build practice

- **`-place_option 3`, `-route_option 1`, no `-replicate_resources`.** One netlist: options 0, 1, 2, 4 gave 123,
  125, 119, 147 MHz; **3 gave 188 MHz** (11). Route 1 was 1 to 20 MHz better than 2; 0 was 40 MHz worse;
  replication 3 MHz worse. 3 and 2 are the tool's own defaults for this chip. **Our P1 build ran with place 1,
  route 2.** No seed, effort or thread switch exists. Do not use the undocumented switches (`-retiming` etc.).
- **`-gen_posp 1`** in every run: free, writes the sites of all DSP blocks and block RAMs.
- **Size first**: synthesis only, then the size tools; full place-and-route only when every part is under 80 %.
  No timing-fix loops on a design known to be temporary. Stop runs that go nowhere.
- **Runs in parallel**: the owner's own licence (V1.9.12.04) allows 3 Gowin runs at once; Sipeed's floating
  server, which this project uses, allows one. Each run in its own absolute `OUT_DIR`.
- **Never edit the build script while a run goes**, and use `GOWIN_SNAPSHOT=1` when sources may change under it.
- **A settings file read with `tr -d '\r'`** applied no setting at all after a checkout with Windows line ends
  (the build silently ran place 1 with replication: 3,454 failing end points instead of 0). Use `'\015'`, and
  check `run.tcl` of a run for the options it really got.
- **Watchdog by process ID, never by name** (other sessions run their own `gw_sh`): `tools/gowin_watch.py <out>`
  reads `<out>/gw_sh.pid` and ends the run only when its CPU time has stood still (routing is silent but busy).
- **A wrapper per block for stand-alone runs** is already ours (`gowin/res.sh --wrap`); an earlier design confirms it.
- All of this is now behind environment switches of `gowin/p1/build.sh` (see its header); with none set the run
  is unchanged except for the post-place file. Suggested next run: `GOWIN_PLACE_OPT=3 GOWIN_ROUTE_OPT=1`.
- **V1.9.12.04 against V1.9.11.03**: same sizes; place options now documented; region and group constraints no
  longer hang; new `syn_dont_touch`, `-retiming_resource` (do not use), `NET_NO_REP`; `-gen_text_timing_rpt` is
  gone; **stricter on read-during-write memories** (section 8). Stand-alone speed within one placement's spread.

## 8. Gowin tool faults and workarounds

| Fault | Workaround |
|---|---|
| `(* syn_preserve = 1 *)` (attribute form) ignored in a large design; the comment form `reg x /* synthesis syn_preserve = 1 */;` works. **new for us: `rtl/` has 41 uses of the attribute form** | comment form |
| Equal registers are made one even when kept by name (62 kept counters became one) | make them unequal (reset from different taps of a delay chain); **new**: `syn_dont_touch` keeps a small case apart, not yet tried on a real one |
| A register array loaded in a loop (`reg [7:0] r [0:2]`) in a module instantiated several times: one shared `RAMREG` set with wrong bits; seen only in netlist simulation | packed vectors; grep the netlist for `RAMREG`. **new**: the name alone is no fault for a module that exists once. Ours to check: `rtl/rx/cic_var_shared.v` (`integ[c][s]` loaded in loops), the 8 `fir_decim` instances |
| Multiply-accumulate with load inferred wrongly into the DSP block | instantiate (`ACCSEL`), check by netlist simulation |
| A memory read and written at one address in one clock: two-port block RAM in (11), **single-port read-before-write in V1.9.12.04, which place-and-route refuses (PA2122)**: the 138K has no such mode. new | write it as "write, else read"; needed before this project moves to V1.9.12.04 |
| Short delay chains become RAM16 shift registers on one shared toggle, or block RAM (PA2122) | `/* synthesis syn_srlstyle = "registers" */` on the module |
| `syn_preserve` on a whole module stalls "Running inference" | per register only |
| `set_multicycle_path` hung the placer in an earlier design (13 lines with `get_regs` wildcards) | none known. **Differs here**: `rtl/rx_backend/rx_backend.sdc` has multicycle paths and our runs complete |
| Variable shift of a constant (`1 << v`): SP00018; a small constant array with a variable index stalls inference | case statement |
| Region / group constraints hang in (11); in V1.9.12.04 they run, but a region for a whole unit runs out of memory | do not floorplan (section 5) |
| A location line that cannot be obeyed is only a warning (CT1094); a `MULT27X36` takes two DSP sites | read the log |
| The timing report does not time several cascaded DSP adds in one clock | an output register in every block of a cascade |
| new: UG300 says the GW5AST-138B has no RAM16 (LUT RAM) primitives; the data sheet lists them and the tool places 1,285 of them | open until a board runs; every build uses them |

## 9. Board bring-up (none of it tried yet)

- **PT8211 pins: BCK = E22, WS = F24, DIN = G24** (Sipeed `audio/audio_music/src/audio.cst`; dock schematic nets
  `I2S_BCLK` E22, `I2S_DIN` G24). `gowin/p1/sdr.cst` and docs/BOARD.md have `hp_bck` G24 and `hp_din` E22:
  **swapped; the DAC would stay silent.** Not changed in this work package.
- **One SPI flash holds the bitstream and the processor's code.** Gowin's procedure writes the bitstream at
  0x000000 and the program at 0x600000 (MUG1030 2.6.8, 3.4.5); a bitstream is 5.04 MiB. docs/C2_LOADER.md calls
  the processor's flash "distinct from the FPGA's own bitstream configuration flash", and the loader's slots at
  chip offsets 0x1_0000 and 0x71_0000 **would erase the bitstream**. Another loader for this board writes at 0x610000.
  How 0x8000_0000 maps onto the chip (assumed: offset 0x600000) is a board question. Two more loader faults are
  already noted at the end of docs/C2_LOADER.md.
- **A ladder of small bitstreams**, each adding one part: (1) PLLs, AE350, UART, LEDs, clock counters; (2) + DDR3
  tests and HDMI; (3) + audio; (4) the design. A failing step names the part. The first steps build in 2 to 3
  minutes (4,000 to 8,000 logic). Our B1 to B3 start from Sipeed's demos and then the whole design.
- The FPGA needs about **20 s** to load at power-on (2.5 MHz configuration clock). **LEDs are active low**
  (J14, R26, L20, M25, N21, N23). Reset key: G16 ("user key 3", low = pressed).
- **UART clock unknown**: the ladder program prints its report six times, once per guess of the UART's input
  clock (50, 24, 100, 25, 20, 10 MHz at 115,200 baud); the readable one tells. The machine timer rate is unknown too.
- **Hold the CPU in reset until DDR3 is ready**, so a dead DDR3 shows as an LED and not as a hung program.
- Programmer: the bitstream header says device version C, Sipeed's examples say B; try `--device GW5AST-138C`,
  then `138B`. Unused pins get a pull-up by the tool's default.
- `-use_cpu_as_gpio 1` (LEDs 1 to 5, UART2 RXD sit on those balls), `-use_mspi_as_gpio 1` (the flash),
  `-use_sspi_as_gpio 1`; READY, DONE and I2C are not set as GPIO.
- AE350 JTAG balls (Y21, W21, P23, U14, P21) are on the dock's SDRAM / 40-pin connector: wired by hand.

## 10. Tools

| File | Does |
|---|---|
| `tools/gowin_fanout.py` | nets with the most loads, loads per unit, histogram, from a synthesis netlist (.vg) |
| `tools/gowin_mems.py` | per unit: LUT, adders, LUT RAM, registers, block RAM as place-and-route counts it; `--mem`, `--lutram` list every memory |
| `tools/gowin_hier.py` | resource table per instance from `<top>_syn_rsc.xml` |
| `tools/gowin_verdict.py` | failing end points (setup, hold, all clock pairs), per-clock Fmax, worst cross-clock and hold paths |
| `tools/gowin_classes.py` | path classes of one clock: end points, worst slack, cell and route delay, fan-out |
| `tools/gowin_watch.py` | ends a stalled run by its process ID |
| `gowin/p1/build.sh`, `gowin/p1/sdc_margin.py` | the switches of section 7 |

Each was run once on `ft8_spectrogram_ooc_wrap` (an existing report of WP F5) or, for the build script, as a dry
run (`GOWIN_DRY=1`). Floorplan tools were measured useless and are not used.
