<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# WP P1: chip top level

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

The first top level of the whole FPGA: every block on the FT8 path that exists, wired together with the AE350
hard RISC-V, its shared DDR3 controller, the PLLs, the pins and the timing constraints, in one Gowin project
that builds from the command line. Branch `p1`. PLAN.md priority item 4.

## 1. Files

| File | What |
|---|---|
| `rtl/top/sdr_top.v` | Chip top: pins, 4 PLLs, AE350 (`RiscV_AE350_SOC_Top`), HDMI encoder with OSER10 and ELVDS pads, resets |
| `rtl/top/sdr_core.v` | All of our own logic: register bus, every block, DDR3 lane arbiters, interrupts. One vendor primitive, `OTP` (chip ID, in `net_unit`; docs/NET_ID.md), which `sim/net/otp_model.v` stands in for, so it simulates whole in iverilog |
| `rtl/top/ahb_reg_bridge.v`, `regbus_cdc_dst.v` | AE350 Extended AHB Slave to the fabric register buses (section 3) |
| `rtl/top/sys_regs.v` | System page 0xE800_0000: id, build, scratch, interrupt pending/enable/raw, status, cycle counter |
| `rtl/top/hl2_link_regs.v`, `hl2_pkt_port.v` | HL2 link registers (0xE801_0000) and the CPU receive ring (0xE802_0000) |
| `rtl/top/block_regs.v` | Register blocks for the receiver bank, TX chain, audio and video (they have no register port of their own) |
| `rtl/top/rd_word_adapter.v` | 32-bit ring readers onto the 64-bit read lane |
| `rtl/top/p1_stubs.v` | Marked stubs: FT8 front end (F5-F7), compositor (V2), SFP0 link (N1) |
| `hw/regmap/system.toml`, `hl2_pkt.toml`, `ft8.toml` | New register pages; `hl2_link.toml` and `video.toml` extended, block ids set (section 4) |
| `gowin/p1/build.sh` | Regenerates the IP and runs Gowin synthesis, place-and-route, bitstream (section 9) |
| `gowin/p1/ip/riscv_ae350_soc.ipc`, `ipc_to_config.py` | AE350 configuration and its define generator (section 2) |
| `gowin/p1/ip/gowin_pll_*.mod` | The four PLLs, for GowinModGen |
| `gowin/p1/sdr.cst`, `sdr.sdc` | Pin and timing constraints (section 7) |
| `sim/top/tb_sdr_core.v` | Smoke test (section 8) |

Outside `rtl/top/`: `hl2_link_rx_top.v` gained one output, `samp_index` (the gap filler's sample index, for
the receiver back end's time stamps); two build fixes in H2/H3's files for the GW5A family:
`eth_clk_pll.v` used the GW1N/GW2A `rPLL` primitive, now the generated `Gowin_PLL_ETH`
(`gowin/p1/ip/gowin_pll_eth.mod`, same 1,000 MHz VCO), and `gowin_oddr5.v` named the ODDR output `Q`, on
GW5A it is `Q0` (with `Q1`/`TX` for the tristate). `rtl/rx_backend` is untouched; its `rx_backend.sdc` is
appended to the chip constraints by `build.sh`.

## 2. AE350 and DDR3

**Configuration** (`gowin/p1/ip/riscv_ae350_soc.ipc`): instruction memory in the SPI flash, data memory in
DDR3 with "Shared DDR3: Logic R/W Mode" (fabric write lane 4 and read lane 5, 32-bit address, 64-bit data),
Extended AHB Slave (the register window 0xE800_0000-0xEFFF_FFFF), the 16 external interrupts, UART2, PIT, WDT,
RTC. Clocks as in Sipeed's demo: core 800 MHz, AHB and APB 100 MHz in Sipeed's demo (**80 MHz here since 2026-10-13**: output divider 10 of the 800 MHz VCO instead of 8, docs/DECISIONS.md), DDR_CLK 50 MHz, RTC 10 MHz.

**How the IP is regenerated without the GUI.** GowinModGen, the command-line generator, knows only primitive IP
(PLL_ADV works; `RiscV_AE350_SOC` and `DDR3` answer "unknown model type"). What the GUI dialog produces is a
`define` file plus a synthesised, encrypted netlist of the IP's own sources in `IDE/ipcore/RiscV_AE350_SOC/data`
(Sipeed's generated `riscv_ae350_soc.v` lists exactly those files as its sources). `build.sh` compiles those
sources straight into the chip project, with the define file that `ipc_to_config.py` writes from the committed
`.ipc`. So only the `.ipc` is committed, every build regenerates the IP, and the same `.ipc` opens in the GUI.
The shared-DDR3 controller is part of these sources: there is no separate DDR3 IP to generate.

**Findings that change the DDR3 plan** (ARCHITECTURE 3.9 assumed a 32-bit, 1 GB DDR3 behind the shared lanes):

- The AE350's embedded DDR3 controller is **16 bits wide**: its port is `DDR3_DQ[15:0]`, `DDR3_DM[1:0]`,
  `DDR3_DQS[1:0]`, fixed in the IP's top file, and the default controller settings (`gwmc_param.v`) say
  `DQ_WIDTH = 16`. Only one of the board's two x16 chips (byte lanes 0 and 1) is used.
- Its row address is **14 bits** (`DDR3_ADDR[13:0]`, `ROW_WIDTH = 14`). The fitted H5TQ4G63EFR has 15 row
  bits, so the controller reaches **256 MB** of that chip. A14 is driven low.
- Memory clock is 300 MHz since 2026-10-20 (`tCK = 3333 ps`, controller clock 75 MHz, DECISIONS 2026-10-20); the next lines were written for the earlier 400 MHz (`tCK = 2500 ps`): DDR3-800 x 16 bit = **1.6 GB/s peak**, half of the
  3.2 GB/s in ARCHITECTURE 3.9. The 3.9 budget (about 752 MB/s with raw capture, 600 without) is then 47 % of
  peak instead of 23 %. It still fits; the video-starvation question (risk 4) gets sharper.
- 256 MB is plenty for this design (framebuffer 4 MB, two waterfall rings 8 MB, receiver rings, firmware).

Using the whole 1 GB and 32 bits would need "Customized Data Memory" (the CPU's data AHB out to the fabric) with
Gowin's separate DDR3 memory-interface IP and our own arbiter: the fallback ARCHITECTURE 3.9 already names.
Not done here.

**Lane details not settled by MUG1031** (board check B4): the write mask is 4 bits even with 64-bit data; the top
level drives it with one bit per 16 bits in DDR3-DM polarity (1 = not written), and every fabric client writes
whole words. Lane addresses are taken as 64-bit lane words (docs/F4_DDR.md section 2). The lanes are clocked
with `clk_dsp` (MUG1031 table 4-2 wants at least a quarter of the 400 MHz memory clock); that removes every
crossing between the DSP blocks and DDR3.

**Reset.** The AE350's power-on and hardware resets come from the reset key and the PLL locks; its DDR3
controller's reset from the key and the DDR3 PLL. The CPU is not held until `DDR3_INIT` (the controller is inside
the same IP), so boot code polls `system.status.ddr3_init` before touching DDR3. Board check B3.

## 3. Register bus from the AE350

The AE350 is the AHB master on its Extended AHB Slave port. `ahb_reg_bridge` is the one slave: one access at a
time, 32-bit (a byte or halfword write writes the whole word), HRESP always OKAY.

- Page = address bits 23:16, one 64 KB page per block (ARCHITECTURE 4.1). Pages 0x00-0x0F are decoded.
- The access is carried by a toggle handshake into the clock domain that owns the page: `clk_dsp` for every
  page except 0x02, `clk_rx` (the PHY's receive clock) for the receive ring (page 0x02 below 0x8000), `clk_tx`
  for H2's CPU transmit queue (page 0x02 from 0x8000). `regbus_cdc_dst` on the far side
  issues one register access and answers a fixed number of clocks later. HREADY stays low meanwhile: about
  15 AHB clocks per access to a `clk_dsp` page, about 20 to page 0x02.
- **Timeout**: an access whose domain does not answer within 4,096 AHB clocks (41 us) returns 0xDEAD_BEEF and
  sets `system.status.bus_timeout`. This matters for page 0x02: with no Ethernet link the PHY gives no receive
  clock. The channel is then marked dead (`system.status.rx_domain_dead`) and answers 0xDEAD_BEEF at once until
  the late acknowledge arrives, so a late answer can never complete a later access with stale data.
- In `clk_dsp` the bus is registered once and fanned out as one-hot page strobes; each block registers its read
  data; the page mux registers again.

## 4. Register map changes

The generated map (`cargo run -p xtask -- regmap`) stays the only source of addresses. `tr-regs` tests pass.

| Page | Change |
|---|---|
| 0xE800_0000 `system` (new) | id 0x5452_0001, build (git hash from `build.sh`), scratch, `irq_pending` (W1C), `irq_enable`, `irq_raw`, status (DDR3 init, PLLs locked, bus timeout, receive domain dead), `dsp_cycles` |
| 0xE801_0000 `hl2_link` | `hl2_ip` is now RW: H1's classifier needs the HL2's IP and nothing in logic learns it, so firmware writes it after discovery. Added: raw and other frame counts, ring frame/drop counts, gap samples, resyncs, CPU ring write pointer, 48-bit sample index |
| 0xE802_0000 `hl2_pkt` (new) | The 4 KB CPU receive ring as 1,024 read-only words, byte k of the ring in bits 8(k mod 4)+7..8(k mod 4) |
| 0xE807_0000 `video` | Added `wf_ring_base`, `wf_write_line` for the full-band waterfall ring |
| 0xE80D_0000 `ft8` (new) | Placeholder, id only; F5-F7 replace the layout |
| ids | `rx_bank` 0x5258_0001, `tx` 0x5458_0001, `audio` 0x4155_0001, `video` 0x5649_0001, `hl2_link` 0x484C_0001 |

Two translations live in the register blocks, not in the TOML: `rx_bank.toml` puts enable in bit 0 and rate in
bits 2:1, `rx_bank.v` wants `{enable, rate[1:0]}`; the TX gain register's low 5 bits drive `tx_chain`'s
`gain_shift`. The audio and TX `ring_size` registers are stored but not used: the ring readers have fixed sizes
(audio 4,096 words = 85 ms, TX 8,192 words = 171 ms); disabling either restarts its read pointer at 0.

## 5. What is wired

All in `clk_dsp` unless noted.

| Block | Input | Output |
|---|---|---|
| HL2 link RX (H1) | RGMII pins (`clk_rx`) | 12-bit sample stream + valid, sample index; CPU ring; counters; safety byte |
| Receiver bank (R1), NRX receivers (4 by default, 8 with `TR_NRX=8`; docs/DECISIONS.md 2026-10-13) | sample stream | shared IQ stream |
| Receiver back end (R4) | bank IQ stream, sample index | output stream (to the FT8 stub), DDR3 rings on the write lane's top tier, interrupt 10 |
| Full-band spectrum (F1 + F2) | sample stream | waterfall byte stream, line buffer (to the compositor stub), interrupt 5 |
| Waterfall writer (F4) | spectrum waterfall stream | DDR3 ring, write lane tier 2 |
| TX chain (X1) | TX ring in DDR3 (read lane TX tier), paced by H2's rate lock, trip from safety byte bits 7/6 | 12-bit samples to H2 |
| HL2 link TX (H2) | TX chain samples, HL2 TX-FIFO fill from H1 (`rx_tx_fill_bridge`), MAC/IP/port settings carried into `clk_tx`, CPU transmit queue (page 0x02 upper half) | RGMII TX pins, `clk_tx` |
| PHY setup (H3) | 50 MHz oscillator | 125 MHz `clk_tx` and GTX clock, 25 MHz PHY reference, PHY reset sequence, PHY-id read over MDIO |
| Audio engine (A1) | audio ring in DDR3 (read lane audio tier) | PT8211 pins |
| DDR3 lane arbiters (F4) | the clients above | AE350 lanes 4 and 5 |
| HDMI (V1, in the top) | `clk_pix`, 48 kHz audio clock | TMDS pads; pixel position to the compositor stub |

The zoom DDC and 4k FFT were not built in at P1. **Since 2026-10-12 (branch `zoom`) they are**, feeding the spectrum
pipeline's zoom half, the compositor's zoom snapshot and a second waterfall writer: [ZOOM_IN_CHIP.md](ZOOM_IN_CHIP.md).

Interrupt lines (ARCHITECTURE 4.3), latched on a rising edge in `sys_regs`, `EXT_INT` = pending AND enable:
0 packet received, 1 HL2 status (safety byte change, gap), 3 audio low water, 4 TX low water, 5 spectrum line,
6 network frame received, 7 network link change (SFP0), 8 video frame start, 10 receiver back end, 11 FT8 front end. 12 USB playback samples waiting (docs/USB_AUDIO.md). 13 USB host (docs/USB_HOST.md), 14 board link (docs/SFP_LINKS.md). Lines 2, 9 and 15 have no source.

## 6. What is stubbed

Each stub is in `rtl/top/p1_stubs.v` with the port list its real block needs, at the place the real block goes in
`sdr_core.v`. Replacing one is a module swap plus the file lists in `build.sh` and the smoke test.

| Stub | Real block | What the stub does |
|---|---|---|
| (replaced 2026-10-12) `ft8_frontend_stub` | `rtl/ft8/ft8_frontend.v`: F5-F7 with the registers of `hw/regmap/ft8.toml` | No longer a stub; `sim/ft8/tb_ft8_frontend.v` tests its registers |
| `compositor_stub` | V2 | Video read tier idle, line buffers not read; makes the frame-start interrupt. The HDMI output shows V1's colour bars and 1 kHz tone |
| (replaced 2026-10-13) `sfp_link_stub` | `rtl/sfp/sfp_top.v`, `rtl/blink/blink_top.v`, the transceiver in `rtl/sfp/sfp_serdes.v` | No longer a stub: docs/SFP_LINKS.md |

## 7. Clocks, pins, timing constraints

| Clock | Frequency | Source |
|---|---|---|
| `clk_dsp` | 120 MHz | `pll_dsp` (VCO 50 x 24 = 1,200 MHz / 10; was 150 MHz, / 8, until 2026-10-12) |
| `clk_tx` / PHY reference | 125 / 25 MHz | `pll_dsp` (/6, /30) |
| AE350 core / AHB / APB / DDR / RTC | 800 / 100 / 100 / 50 / 10 MHz | `pll_ae350` (Sipeed's settings) |
| DDR3 memory / reference | 400 / 50 MHz | `pll_ddr3`, placed at PLL_L[0] (MUG1031 8.3) |
| `clk_pix5` / `clk_pix` | 743.75 / 148.75 MHz when this was written; **370.83 / 74.17 MHz now** (1080p30, 50 x 89 / 12 and 50 x 89 / 60, docs/DECISIONS.md 2026-10-22) | `pll_video`: 25 MHz x 29.75. 1080p60 at +0.17 %: the phase detector needs at least 19 MHz, so 50 MHz can only be divided by 1 or 2 and 148.5 MHz exactly is out of reach; CEA-861 allows 0.5 % |
| `clk_rx` | 125 MHz | RGMII RXC from the PHY |
| `clk_audio` | 48 kHz | phase accumulator in `clk_dsp` |

Pins (`sdr.cst`): from Sipeed's examples and the dock schematic, sources listed in the file's header.
The RGMII receive pins, still "not verified" in BOARD.md, are read from the dock schematic sheet RGMII_sch:
RXC C23, RX_CTL C22, RXD0-3 B26, C26, D26, E26. Debug UART on the BL616 bridge: TX P15, RX N16 (Sipeed's AE350
demo uses U16/V16, which the dock schematic names SDRAM_D0/D1). SFP0: TX_DISABLE R18, LOS V18.

`sdr.sdc` declares every PLL output as a generated clock and puts every domain in its own asynchronous
group: every crossing in the design is a handshake, a Gray-coded FIFO or a synchroniser.

## 8. Smoke test

`sim/top/tb_sdr_core.v` (iverilog, about 2 minutes): the whole core with the HL2's own send RTL as far end
(test pattern, 50 ppm offset, real RGMII), an AHB master model in the AE350's AHB clock, and the behavioural DDR3
lane model with random stalls. Checks: identification, build id, scratch write/read and an unmapped page through
the bridge; receiver-bank registers read back; raw frames arrive without CRC errors; the HL2's discovery reply
lands in the CPU ring and reads back through the `clk_rx` channel; receiver 0 (303 kHz, next to a test-pattern
harmonic, back end in IQ mode at 24 ksps) writes non-zero payload words into its ring in the DDR3 model at the
programmed address; the packet-received interrupt latches, reaches `EXT_INT` and clears. PASS.

## 9. Gowin build

*Sections 9 and 10 are the numbers of the first P1 build (2026-10-11), kept as history. The chip as it is now, its resources, clocks and the one list of board checks are in section 12.*

`gowin/p1/build.sh` (from the repository root) regenerates the IP, writes the build id and one constraint
file (`sdr.sdc` plus `rtl/rx_backend/rx_backend.sdc`), and runs synthesis, place-and-route and bitstream
with place option 1, route option 2, timing driven. One full run, 2026-09-27: **3,008 s (50 min)**, completes,
bitstream `sdr_top.fs` written. Timing is not met (below).

### Utilisation (place-and-route counts)

| | Used | Of chip | Owner target | ARCHITECTURE 3.14 ledger, rebalanced, place-and-route recount (whole design) |
|---|---|---|---|---|
| Logic (LUT + ALU + ROM16 + 6 x RAM16) | 73,559 | 53 % | 70 % | about 104,300 (75.4 %) |
| Registers | 51,685 | 37 % | - | about 61,000 |
| BSRAM (18 kbit) | **261** | **77 %** | 75 % | 298 (87.6 %) |
| DSP | 105 | 35 % | 70 % | 175.5 (58.9 %) |
| I/O | 95 of 312 | 30 % | | |
| AE350_SOC, PLLs | 1 of 1, 5 | | | |

What is in this build: H1, H2, H3, R1 (NRX receivers, 4 by default), R4, F1 + F2 including the zoom back-end half, F4 (both
arbiters, one waterfall writer), X1, A1, V1, the AE350's fabric part (DDR3 controller and PHY, SPI flash
controller) and the register bus. Not in it (stubs or skipped): F5-F7 FT8 engines (ledger about 11.5k logic,
34 DSP, 18 BSRAM), V2 compositor (6.5k, 6, 12), zoom DDC + 4k FFT (11.9k, 30, 21), SFP link (4k, 0, 4), IQ
writer, VITA-49 framer, audio mixer.

**BSRAM is already over the 75 % target at 261**, before the FT8 engines and the compositor. Adding the
ledger's figures for F5-F7 and V2 alone gives about 291 (86 %); with the zoom DDC and SFP about 316 (93 %).
This matches the ledger's own warning (87.6 % counted the way place-and-route counts). Logic and DSP have room.

### Timing per clock (worst case, slow corner, grade C)

| Clock | Target | Fmax | Failing endpoints (TNS) | Worst paths |
|---|---|---|---|---|
| `clk_dsp` | 150 MHz | **69.0 MHz** | 28,640 (-77,386 ns) | All 25 reported paths are in the receiver bank: the FIR's coefficient-select path (`firs[n].u_fir` tap index -> coefficient mux -> `out_q`, 18 logic levels, 14.4 ns) and the synchronous reset fanning out to the shared CIC's `cmb_out` register-file clock enables (14.0 ns). The receiver bank has never been through place-and-route before (ledger: "measured later, after RB3") |
| `clk_rx` (RGMII RX) | 125 MHz | 106.9 MHz | 106 setup (-58.8 ns); 5 hold (-21.8 ns) | Setup: 14-level logic in H1's receive path. Hold: the five RGMII input pins into their IDDRs, -4.37 ns each, against the constraint "data valid 2 ns either side of each RXC edge" (RXDLY strap). The clock insertion delay from the RXC pin is 2.9 ns; see section 10 |
| `clk_tx` (RGMII TX) | 125 MHz | 76.1 MHz | 41 (-54.1 ns) | Short paths (2 logic levels), not among the chip's 25 listed paths; most likely the RGMII outputs against the output-delay constraint, not verified |
| `clk_pix` | 148.75 MHz | 125.2 MHz | 22 (-9.9 ns) | Recovery: the pixel-domain reset into the three OSER10 serializers' RESET, timed against `clk_pix5`'s falling edge (-3.4 ns) |
| AE350 AHB (`EXTS_HCLK`) | 100 MHz (80 MHz since 2026-10-13) | 96.9 MHz | 7 (-1.1 ns) | Inside the bus bridge / AE350 boundary; small |
| `ddr3_memory_clk` / DDR3 PHY divided clock / `ddr3_clkin` / AE350 DDR clock | 400 / 100 / 50 / 50 MHz | 2,339 / 207 / 258 / 136 MHz | 0 | Met. Hold: nine DLL-step paths inside Gowin's DDR3 PHY at -0.36 to -0.53 ns (vendor IP) |
| `clk_50m`, `clk_audio` | 50 MHz, 48 kHz | 369, 336 MHz | 0 | Met |
| `clk_25`, `clk_pix5`, AE350 core/APB/RTC | | no register paths | | |

**Receiver back end, separately.** None of the 25 worst `clk_dsp` paths is in `rx_backend` (all are in
`rx_bank`), so its worst slack in the full chip is better than -7.6 ns, but Gowin's report lists only the
25 worst paths per analysis and the full-chip run gives no per-block figure. Measured alone on branch
`bkclose` with the same `rx_backend.sdc`: 132.4 MHz (worst slack -0.887 ns, 27 failing endpoints). Its
two-clock register-bus paths (`rbmc_*`) are constrained here too. The one hold path of `rx_backend` in the
report (`u_post` write field into a LUT RAM) has +0.116 ns.

Also seen in synthesis: the HDMI audio packet logic of V1 (`audio_sample_packet`, `audio_info_frame`) is
swept away as unused (the 48 kHz audio clock reaches the core but the samples do not), and the AE350's SPI
flash register interface is swept (the APB flash-register port is off in the configuration, as intended).

## 10. Blockers and board checks

Blockers for a bitstream that works at speed, in order of size:

1. **Receiver bank timing (`clk_dsp` at 69 MHz).** The FIR decimator's coefficient select and the reset
   fan-out into the shared CIC are 14 ns paths. Needs a timing pass on `rtl/rx` (pipeline the coefficient
   address, register or remove the synchronous reset on the CIC register file). Until then every block in
   `clk_dsp` would have to run at under half speed, which the 76.8 Msps input rules out.
2. **BSRAM at 77 %, heading for 86-93 % with the blocks still to come.** An owner decision (ledger section
   "What still does not fit"): candidates are the spectrum's accumulators in DDR3, narrower memories where a
   36-bit port is not needed, the zoom spectrum later or not at all.
3. **RGMII receive hold (-4.4 ns).** Either the constraint is wrong or the IDDR needs an input delay: the
   PHY's RXDLY strap already centres the data, and the FPGA adds 2.9 ns of clock insertion on RXC. Fix with an
   IODELAY on RXC or the data pins, or by clearing the RXDLY strap over MDIO; decide on the board (B5).
4. **`clk_tx` at 76 MHz (41 short paths, 2 logic levels).** Not in the listed worst paths, so not identified;
   most likely the RGMII outputs against the output-delay constraint. TXC is the PLL clock driven straight to
   its pin, not forwarded through an ODDR like the data; forwarding it through an ODDR puts clock and data on
   the same IOLOGIC timing. Needs one targeted timing report.
5. **HDMI serializer reset (recovery -3.4 ns).** Make the OSER10 reset asynchronous-to-`clk_pix5` a false
   path or release it through a `clk_pix5` synchroniser.
6. Smaller: AHB bridge -1.1 ns on 7 endpoints; RX logic in H1 at 107 MHz.

Board checks this top level adds to PLAN.md track B:

- B1/B3: debug UART on P15/N16; `system.status.ddr3_init` rises; boot code must wait for it (the CPU is not
  held in reset until DDR3 is ready).
- B4: the lane write-mask polarity and granularity (4 bits for 64-bit data); lane addresses in 64-bit words;
  only 256 MB of one x16 chip reachable through the AE350's controller.
- B2: the pixel clock is 148.75 MHz (+0.17 %); the monitor must accept it.
- B5: RGMII receive and transmit timing (items 3 and 4 above) and the PHY's delay straps.

## 11. WP LS5: whole-chip timing closure (2026-10-12, branch `tclose`)

Three full-chip builds (place option 3, route option 1); reports in `gowin/reports/p1_ls5_b1`, `_b2`, `_b3`.
Sections 9 and 10 above describe the first build of 2026-09-27 and are kept as history.

### 11.1 Result

Failing end points per clock (Fmax in MHz). "Before" is the build of 0c735b5 (`gowin/reports/p1_ls2`).

| Clock | Target | Before | Build 1 (b6a5139) | Build 2 (85977ea) |
|---|---|---|---|---|
| `clk_dsp` | 150 | 482 (110.6) | 23 (135.1) | 37 (126.3) |
| `clk_rx` | 125 | 24 setup + 5 hold (116.3) | 40 (117.8), hold 0 | **0** (128.0) |
| `clk_tx` | 125 | 18 (76.1) | 18 (114.4) | **0** (128.0) |
| `clk_pix` | 148.75 | 11 (132.9) | 34 (136.8) | **0** (148.9) |
| AE350 bus clock | 100 | 1 (94.2) | **0** (103.3) | **0** (106.4) |
| all clocks | | 536 setup, 5 hold | 115 setup, 0 hold | 37 setup, 0 hold |

- The 37 of build 2 are all in `clk_dsp`, the worst 0.16 ns short: the chip-wide reset net (5,200 loads) where it
  is a load enable through a LUT (`u_dst_dsp`, the audio interpolator), the `out_count` increment of `rx_backend`
  built from LUTs, two end points in `rtl/rx/rx_bank.v` (`pend_valid -> g_oh`; not a file of this work package),
  one each in the group counter and the window of the spectrum. Round 3 (ecc2558) changes all but the two in the
  receiver bank and the one in the window; **it has not been through a full build** (next point).
- **Build 3 did not place.** It was run on `tclose` merged with master aff4738 (zoom receiver, FT8 front end and
  compositor now in the core): `ERROR (PR0003) Failed to place with '10919 REG(s) unPlaced'`. The merged design
  has 119,472 of 139,140 registers (86 %), logic 80 %, CLS 92 %, block RAM 91 %; build 2 had 67,080 registers,
  CLS 78 %, block RAM 68 %. Registers by block: receiver bank 26,901, FT8 19,246, zoom 17,351, back end 15,635,
  spectrum 13,459 (6,113 while its zoom half had no input), compositor 8,326 (`p1_ls5_b3/result.md`). The
  changes of this work package cost about 2,800 registers. The design has to shrink before timing can be
  measured again; nothing here says how the three new blocks meet timing in the chip.
- A build at this margin is one draw: classes between -0.2 and +0.2 ns move between builds (the audio
  interpolator and the receiver bank were just positive in build 1 and just negative in build 2). The rule of
  docs/TANG_LESSONS.md section 5 (constrain 5 % tighter) is not met yet.

### 11.2 What was changed

| Fault | Change | Files |
|---|---|---|
| One address / data register for every block; synthesis shared the decode: a decode LUT with 133 loads, 7 logic levels in the register blocks | One bus leg per page (own copy of address and data, loaded only on an access to that page; read data returned as an OR of the legs) and a registered decode in the register blocks | `rtl/top/regbus_leg.v` (new), `sdr_core.v`, `block_regs.v`, `sys_regs.v`, `hl2_link_regs.v` |
| Lost-packet check: 48-bit subtract, compare and selection in one clock (16 levels) | Four clocks per frame on registers; fill counter 17 bits | `rtl/hl2link/gap_filler.v` |
| DDR3 write lane: client -> arbiter -> lane and back without a register, across the chip | A register stage that speaks the handshake of the lane on both sides | `rtl/ddr3/ddr3_wr_relay.v` (new), `sdr_core.v` |
| **Two-stage synchronisers and other 2-deep delays had become LUT-RAM cells addressed by one shared toggle** (bit 0 of `txcfg_tick`, 261 loads), read without a register. For the clock-crossing FIFOs of the HL2 link and the DDR3 bridge that is one storage stage, not two | `syn_srlstyle = "registers"` on every module with a synchroniser or a short delay (21 files); checked in the netlist | `rtl/hl2link`, `rtl/mem/ddr_mem.v`, `rtl/top`, `rtl/spectrum`, `rtl/rx_backend`, `rtl/fft/fft_twmul.v`, `rtl/audio/audio_digital_out.v` |
| The two-clock bus paths of the back end were timed as one clock. **Gowin V1.9.11.03 does not apply `set_multicycle_path` on a clock made with `create_generated_clock`** (reproduced on a 30-line design; with the clock on a pin it works, which is why the stand-alone runs never showed it) | `set_max_delay 13.0` from the same registers | `rtl/rx_backend/rx_backend.sdc` |
| RGMII receive: -4.4 ns hold. The constraint was wrong (it described data gone 2 ns before its own edge) and the circuit was marginal too (RXC needs 2.9 ns to the input registers, the data 1.4 ns) | IODELAY of 170 steps (2.7 ns) on the five data pins; input delays 1.0 to 3.0 ns, as the PHY sends with its RXDLY strap. Build 2: setup +1.26, hold +1.49 ns | `rtl/hl2link/gowin_iddr5.v`, `gowin/p1/sdr.sdc` |
| RGMII transmit: data pins timed against the PLL, TXC straight from the PLL to its pin | TXC through an ODDR like the data; no output delay lines (a clock made at the TXC port gets no delay from the tool, so the check cannot be written) | `rtl/top/sdr_top.v`, `sdr.sdc` |
| Rate lock: cool-down compare, decision and add in one clock | Decision flags one clock ahead | `rtl/hl2link/tx_rate_lock.v` |
| TX frame header: IP checksum (19 levels) and a 58-to-1 byte selection into the CRC | Checksum over four clocks, header byte from a register | `rtl/hl2link/tx_sample_framer.v` |
| Receive classifier: IP compare, decision and byte strobes in one clock | Header compares registered; held decision behind the CRC delay | `rtl/hl2link/eth_frame_rx.v` |
| HDMI: pixel and packet counters with 128 loads | `syn_maxfan = 20` on the module | `rtl/vendor/hdmi/hdmi.sv` |
| Spectrum: multiplier output through rounding and clamp; FFT delay RAM address behind two adders | Product registered (ratio stage 7 clocks, was 6); address from registers | `rtl/spectrum/spectrum_ratio_db.v`, `spectrum_walk_core.v`, `rtl/fft/fft_delay.v` |
| Round 3, not yet built: reset as a load enable; `out_count + 1` in LUTs; group compare behind an increment | Local reset registers; `{a,1} + {0,1}`; compare against count - 2 | `regbus_cdc_dst.v`, `sdr_core.v`, `rx_backend.v`, `spectrum_pipeline.v` |

Simulated: `sim/top/tb_sdr_core.v` (also on the merged tree), `sim/mem/tb_ddr_mem.v` (with the relay in
the lane), `sim/h1_link_rx`, `sim/h2_link_tx`, `sim/spectrum/tb_spectrum_two_ctx.v` and `tb_spectrum_pipeline.v`.

**What firmware sees.** No address changes. A register access to a `clk_dsp` page takes 2 `clk_dsp` clocks
longer (`RD_LAT` 12, was 10: 13 ns). A write lands 3 clocks after the bus strobe in the register blocks (was 1),
a W1C clear of `system.irq_pending` after 4. `hl2_link.sample_index_lo` now returns a copy taken together with
the high word, so the two always belong together. The top rate of the DDR3 write lane is 91 MB/s alone and
41.8 MB/s under a full read lane (was 104 and 46.8; budget 26.4). An insert or skip of the TX rate lock comes
two clocks later. Every register page should get a leg; a block left on shared bus registers brings the old
fault back.

### 11.3 Clock lines

The chip has 16 global lines: 8 primary and 8 long-wire (LW) lines (UG306). A clock is put on a given line
with `CLOCK_LOC "net" BUFG[n] = CLK;` (n = 8 to 15: LW) and kept off them with `CLOCK_LOC "net" LOCAL_CLOCK;`
(SUG1018 2.7). The tool fills spare LW lines with the largest reset nets.

**Now (build 2):**

| Line | Net | MHz | Loads |
|---|---|---|---|
| primary | `clk_dsp` | 150 | all DSP logic |
| primary | `exts_hclk` (AE350 AHB) | 100 | AE350 fabric part, bus bridge |
| primary | `apb_clk` (AE350 APB) | 100 | AE350 fabric part |
| primary | `ddr_clk` (AE350 data-memory bus) | 50 | AE350, bus side of the DDR3 bridge |
| primary | `rtc_clk` (AE350 RTC) | 10 | AE350 |
| primary | `ddr3_clk_in` (DDR3 IP reference, a PLL copy of the oscillator) | 50 | DDR3 IP start-up logic |
| primary | `u_mem/clk_m` (DDR3 IP user clock) | 100 | DDR3 controller, bridge core |
| primary | `clk_pix5` | 743.75 | the three HDMI serializers only (it also has the HCLK line of its bank) |
| LW | `clk_50m_d` (oscillator) | 50 | PHY reset, MDIO, PLL inputs |
| LW | `rgmii_rxc_d` | 125 | HL2 link receive |
| LW | `clk_tx` | 125 | HL2 link transmit |
| LW | `tmds_clock` (`clk_pix`) | 148.75 | HDMI encoder, compositor scan-out |
| LW | `clk_aud` (line 11 by constraint) | 49.152 | S/PDIF, I2S |
| LW | `clk_48m` (line 8 by constraint) | 48 | **one load: the input of the audio PLL** |
| LW | `rst_dsp` (reset, placed by the tool) | - | 5,200 |
| LW | `u_mem/ddr_rst` (reset, placed by the tool) | - | DDR3 IP |

Done in this work package: the 25 MHz reference of the PHY (`phy_clk_d`) had a line and clocks no register; it
is now `LOCAL_CLOCK`. That is why two LW lines carry resets.

**Done 2026-10-17 (branch `final`, section 12): step 4 is built (the DDR3 IP's reference is the oscillator net) and gave `clk_aud` a primary line; step 6 does not work (Gowin refuses `LOCAL_CLOCK` on `clk_pix5`, warning CT1018); step 5 was not tried.** **Superseded 2026-10-13 by docs/SFP_LINKS.md section 3 (branch `sfp`):** three new clocks, not four, all at 125 MHz
on long-wire lines 12 to 14: one transmit clock for both lanes (`sfp_txc`), the two recovered receive clocks
(`n1_rxc`, `bl_rxc`). The board link runs at 2.5 Gbit/s with 20-bit words, not 1.25 Gbit/s with 40-bit words. Freed
for them: `clk_aud` to `LOCAL_CLOCK` (not `clk_48m`, which USB audio now runs on) and the two reset nets (step 2). Steps 4 to 6 are untouched and are
the reserve. The reference is set by our firmware over I2C and the transceiver is held by
`por_n_i` until then. The text below is the plan as it stood.

**Needed: four more clocks.** Both cages are on transceiver quad 1 and share one reference: clock chip 0 at
125 MHz on quad 1 reference input 1 (set by the BL616; it must run before the FPGA is configured, or the
`por_n_i` input of the IP is held low until it does).

| Link | Cage, lane | Rate | Lane clocks |
|---|---|---|---|
| Network (N1, 1000BASE-X) | SFP0, quad 1 lane 0 | 1.25 Gbit/s, 10-bit words | transmit word clock and recovered receive word clock, 125 MHz each |
| Second Tang board | SFP1, quad 1 lane 1 | 1.25 Gbit/s, 40-bit words (one 32-bit word per clock) | transmit word clock and recovered receive word clock, 31.25 MHz each |

**Plan, in the order of least risk:**

| Step | Frees | State |
|---|---|---|
| 1. `phy_clk_d` off the global lines | 1 LW | done, in builds 1 and 2 |
| 2. `u_mem/ddr_rst` leaves when a clock asks for its line | 1 LW | what the tool does by itself; not forced yet |
| 3. `clk_48m` to `LOCAL_CLOCK` (PLL output straight into a PLL input) | 1 LW | not built. Check on the board that the audio PLL still locks and S/PDIF is clean |
| 4. `ddr3_clk_in`: feed the reference input of the DDR3 IP from the oscillator net instead of a PLL copy of it (same frequency) | 1 primary | not built; read IPUG281 on that input first |
| 5. `rtc_clk` (10 MHz) down to an LW line or ordinary wiring | 1 primary | not built |
| 6. `clk_pix5`: it only clocks the serializers, which use the HCLK line of the bank. Find out why it also takes a primary line | 1 primary | not looked into |

Not to be merged: the AHB and APB clocks of the AE350, although both are 80 MHz now (100 MHz when this was written; docs/TANG_LESSONS.md section 5).

**Target with steps 1 to 3 only** (no change to DDR3 or the AE350):

| Lines | Nets |
|---|---|
| primary 8 | unchanged |
| LW 8 | `clk_50m_d`, `rgmii_rxc_d`, `clk_tx`, `clk_pix`, `clk_aud`, **network transmit clock, network receive clock** (125 MHz), `rst_dsp` |
| ordinary wiring | **board-link transmit and receive clocks** (31.25 MHz), `clk_48m`, `phy_clk_d` |

The two board-link units were measured at 137.7 and 100.8 MHz on ordinary wiring in an empty chip
(needed 31.25), hold +0.004 ns; that is thin, and this chip will be full. So steps 4 to 6 are the reserve:
each frees a primary line, `clk_pix` (148.75 MHz) then moves up to it, and its LW line goes to a board-link
clock. With two of them done all four new clocks are on global lines and `rst_dsp` keeps its own.

**USB audio and the clock lines (branch `usb`, docs/USB_AUDIO.md section 9).** The USB audio device asks for
**no new line and no new clock**: it runs on `clk_48m`, which already has long-wire line 8. What changes is
what that line carries: until now one load (the input of the audio PLL), now also about 500 registers of
the USB device. This touches step 3 of the plan above (`clk_48m` to ordinary wiring, to free a line for an SFP
clock):

- Step 3 is no longer free. This USB core built on a 48 MHz clock on ordinary wiring
  gave 46 to 67 hold failures; with the clock on a global line it had none. So `clk_48m` keeps `BUFG[8]` in `gowin/p1/sdr.cst`.
- The target table above then reads: LW 8 = `clk_50m_d`, `rgmii_rxc_d`, `clk_tx`, `clk_pix`, `clk_aud`,
  `clk_48m` (USB), and two free for the network's transmit and receive clocks once `rst_dsp` and
  `u_mem/ddr_rst` give way. `rst_dsp` then has no line of its own, so one of steps 4 to 6 (each frees a
  primary line) is needed, not a reserve. Which net gives way is the SFP work's call; USB's request is only
  this: **`clk_48m` stays on a global line.**
- If a line cannot be found, the fall-back that costs USB nothing is the other direction: the audio PLL's
  output `clk_aud` (49.152 MHz, S/PDIF and I2S: about 300 registers in one small unit, `audio_digital_out`) goes to
  ordinary wiring and USB keeps line 8. Not built.
- Nothing of USB needs a fast clock: there is no 480 MHz or 60 MHz clock, because the device is full speed in
  our own logic and not Gowin's high-speed PHY.

## 12. The chip after the merge of the SFP links (branch `final`, 2026-10-17)

Commit `e0287a3`. Reports: `gowin/reports/p1_final/`. Bitstream of the plain build: `G:/proj/fpga-sdr/impl/keep/full_e0287a3/`
(`sdr_top.fs`, `.rpt.txt`, `.pin.html`). Nothing here has run on a board.

### 12.1 Verdict, in plain words

- **The plain build (the real clocks) passes: 0 failing setup and 0 failing hold end points on every clock.** `clk_dsp` reaches
  121.99 MHz for 120.
- **The build with the clocks 5 % tighter does NOT pass: 167 failing setup end points, 0 hold.** `clk_dsp` 157 end points
  (122.08 MHz reached for 126 asked), `sfp_txc` 6 (127.06 for 131.25), `clk_pix` 4 (150.30 for 156.19). The project's rule
  "a build is clean when it meets the tightened clocks" is therefore **not met**. The real margin on `clk_dsp` is about
  1.7 % (121.99 against 120), on `sfp_txc` 4.1 %, on `clk_pix` 4.7 %. One plain and one margin build were made (2 of the 4
  allowed); no second round was run.
- Worst classes of the margin build (`classes_margin_*.md`; slack in ns against the tightened period):
  - `clk_dsp`: the DSP reset `rst_dsp_s` (5,773 loads, about 7 ns of wire) into the receiver back end's registers
    (`u_backend/ws_en2` -0.26, 12 end points; `u_backend/u_fa/mem` -0.25; `u_backend/u_ring/cnt` -0.25, 23 end points) is 38 of
    the 42 failing classes. Besides it: `u_usb/u_play_fifo/w_bin -> r_data` -0.25 (17 end points, 11 logic levels),
    `u_wr_arb/owner -> u_wf_writer/fifo_rptr` -0.21, `g_zoom.u_zwf_writer/fifo_rptr -> u_wr_relay/l_data` -0.09. The FT8 write
    multiplexer class of the earlier builds is gone (the new write stage, 12.5); FT8's `u_cand/r_hi` (-0.17) and `u_sync/tprev` (-0.12) are
    still there, both from the same reset.
  - `sfp_txc`: `u_sfp/u_net/u_pcs/an -> u_sfp/u_net/u_enc/enc_q` -0.25 (10 end points, 14 logic levels) and `-> enc_rd` -0.06:
    the auto-negotiation state into the 8b/10b coder in one clock.
  - `clk_pix`: `packet_picker/packet_type -> packet_assembler/parity[1]` -0.25 (4 end points), `parity[0]` -0.08: the HDMI
    packet parity (vendored core, 8 and 9 logic levels).
- Next timing work, in this order: take the reset off the back end's data registers (ROUTE_CAUSE.md section 6 row 2; it is
  38 of the 42 failing classes); register the PCS state before the coder; pipeline the parity in the HDMI packet assembler.

### 12.2 What is in the chip (13 parts)

1. HL2 link receive (RGMII, FCS check, sample stream, CPU ring).
2. HL2 link transmit with the TX chain and the PHY setup (FCS corrected on 2026-10-17).
3. Receiver bank, 4 receivers, and their back end (filters, AGC, blanker, audio, DDR3 rings).
4. Full-band spectrum and the zoom receiver (DDC, 4k FFT), two waterfall writers.
5. FT8 front end with two decode passes (and its write stage).
6. Video: compositor and HDMI 1080p60 (+0.17 % pixel clock).
7. 1 GB DDR3 (Gowin IP, bridge, both lane arbiters and relays).
8. Audio outputs: S/PDIF, I2S, PT8211, HDMI audio samples.
9. USB audio device (class 1.0, "Custom USB" socket, page 0xE80E, interrupt 12).
10. USB host on the Pmod board (page 0xE80F, interrupt 13).
11. Network socket on SFP0: 1000BASE-X/SGMII PCS, MAC, packet memory (page 0xE80A, interrupts 6 and 7).
12. Board link on SFP1: sample stream and control words (page 0xE80B, interrupt 14).
13. AE350 (RISC-V, 800 MHz core, buses 80 MHz), register bus, system page 0xE800.

### 12.3 Resources (plain build, place-and-route counts)

| | Used | Of chip | Master before the merge (USB host build) |
|---|---|---|---|
| Logic (LUT, ALU, ROM16, SSRAM) | 89,807 | 65 % | 84,534 |
| Registers | 74,403 | 54 % | 69,863 |
| CLS | 61,389 | 89 % | 60,133 |
| Block RAM | 240 of 340 | 71 % | 226 |
| DSP | 127 of 298 | 43 % | 127 |
| I/O ports | 142 of 312 | 46 % | |
| Transceiver quad | 1 of 2 | 50 % | 0 |
| PLLs | 6 of 12 | 50 % | |

### 12.4 Clock lines (plain build, the tool's own table)

| Line | Net | MHz | Loads |
|---|---|---|---|
| primary | `clk_dsp` | 120 | all DSP logic |
| primary | `ahb_clk`, `apb_clk` (AE350 buses) | 80, 80 | AE350 fabric part, bus bridge |
| primary | `ddr_clk` (AE350 data-memory bus) | 50 | AE350, bus side of the DDR3 bridge |
| primary | `rtc_clk` | 10 | AE350 |
| primary | **`clk_aud`** | 49.152 | S/PDIF, I2S (now on a primary line; 154.3 MHz reached, hold met) |
| primary | `clk_pix5` (also the bank's HCLK) | 743.75 | the three HDMI serializers (cannot leave: CT1018) |
| primary | `u_mem/clk_x1i` (DDR3 IP user clock) | 100 | DDR3 controller, bridge core |
| long wire | `clk_48m` (line 8), `clk_50m_d` (9), `rgmii_rxc_d` (10), `clk_tx` (11), `sfp_txc` (12), `n1_rxc` (13), `bl_rxc` (14), `clk_pix` (15) | 48, 50, 125, 125, 125, 125, 125, 148.75 | all eight named in the .cst; no reset net on a long-wire line any more |
| HCLK | `ddr3_memory_clk` (banks 6, 7), `clk_pix5` (bank 2) | 400, 743.75 | DDR3 PHY, serializers |

`ddr3_clk_in` is gone: the DDR3 IP's `clk` is the oscillator net (IPUG281 4.4.2 allows the crystal input there), which freed
the primary line that `clk_aud` now has (`CLOCK_LOC "clk_aud" BUFG`). The 256 MB fall-back build (`TR_DDR=256`) still uses the PLL
copy. Step 5 (RTC clock down) was not tried; step 6 (`clk_pix5` off its primary line) does not work: a ladder step-2 build with
`LOCAL_CLOCK` on it gave "CT1018 Constrained resource local clock not available". The ladder was not rebuilt: its top level,
constraints and build script were not changed by the merge, and the RTL it shares (DDR3 bridge, HDMI core) did not change.

### 12.5 Faults found and open items closed on this branch

- HL2 link transmit FCS: the first byte of each frame was left out of the CRC (docs/H2_LINK_TX.md 1.7). Fixed; the TX link bench has an independent CRC-32 check.
- FT8 write path: `ft8_wr_stage` between the write multiplexer and the chip's write arbiter (rtl/ft8/ft8_ddr3_mux.v). FT8 front-end bench and the second-pass check on both recordings pass; the class "FT8 write multiplexer to the write relay" is not in the margin build's list.
- Board link interrupt moved from 13 to 14 (the USB host keeps 13).

### 12.6 What only the board can confirm (the one list)

Transceiver and SFP

1. `por_n_i` holds the transceiver as the IDE's option does (the patched port and `por_toggle_by_fabric`).
2. Reference start-up: the clock chip answers at 0x60 on I2C channel 3 and gives 125 MHz with our register values; the debug chip does not disturb the bus; the multiplexer's channel numbers (0 and 1 module memories, 3 and 4 clock chips).
3. Lane 0: lock at 1.25 Gbit/s, bit order and polarity, the copper module's mode (SGMII or 1000BASE-X), auto-negotiation against our PCS, link to the home switch, DHCP, SNTP.
4. Lane 1: 2.5 Gbit/s over the passive cable (needs two boards or a loopback plug), bit errors over an hour, the transmit buffer written with lane 0's clock.
5. The HL2 accepts our transmit frames with the corrected FCS (nothing has run against a real HL2; the vendored HL2 receive RTL never looks at the FCS).

USB

6. USB audio: enumeration and names on Windows, macOS and Linux; Windows follows the feedback endpoint (else the under-run and over-run counters move about once in a few seconds and `usb_play.v` needs an adaptive slip); drive strength and edges of T19 and U19; a one-hour recording and a one-hour playback with all five counters at 0.
7. USB host: with an empty socket both lines under 0.3 V, with a device 3.0 V or more on one (the FPGA's own pull-downs are the host's); the swap bit; headset, mouse, keyboard; ESD care (no protection on the board).

Memory, clocks, video, bring-up

8. The ladder steps 1 to 3 (docs/LADDER.md): LEDs, PLL locks, DDR3 calibration (LED 4), which UART guess is readable, clock rates, DDR3 size probe (1,024 MB), address and pattern tests, HDMI frames, the tone.
9. 1 GB DDR3: calibration with 32 data lines, the AE350's data-memory bus, the processor's memory speed (`tr-bench` FT8 kernel, 1 GB against the 256 MB build).
10. The DDR3 IP clocked from the oscillator net instead of a PLL copy; the audio PLL locks behind the DSP PLL; S/PDIF is clean with `clk_aud` on its primary line.
11. HDMI: the monitor accepts the 148.75 MHz pixel clock (+0.17 %); RGMII receive and transmit timing and the PHY's delay straps.
12. The AE350 at 80 MHz buses: UART clock and machine-timer constants (marked NOT VERIFIED).
13. Timing is closed for the real clocks only (12.1); a board that runs hot or slow may show first in the back end's reset fan-out, the SFP coder or the HDMI packet parity.
