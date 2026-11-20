<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# HL2_SFP: the Hermes-Lite 2 on SFP cage 0, the home network on the RJ45 socket

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Written 2026-10-21, branch `hl2sfp` (cut from `ddr300`). Owner's decision: docs/DECISIONS.md "2026-10-21: cabling
changed". Nothing here has run on a board. The minimal test build of the same receive path is docs/HL2MIN.md.

## 0. Documents used

| Document | Section | Used for |
|---|---|---|
| IPUG1024-1.7.2E Gowin Customized PHY IP | 3.7.1 | transmit buffer: `tx_clk_i` is its write clock; with it = `tx_pcs_clkout_o` "full and afull are constant 0", a word every clock (section 5) |
| | 3.7.2 | receive buffer: `rx_clk_i` is its read clock; with it = `rx_pcs_clkout_o` aempty is 0 and the data "a continuous data stream"; `rx_valid_o` marks a word 3 clocks after `rden` (section 4) |
| | 3.2, table 4-1 | reset forms, lane and PCS resets (unchanged from docs/SFP_LINKS.md 2.3) |
| UG306-1.0.9E Arora V clock | 2.3, 5.1 | PLL: Fclkout = Fvco / ODIV, VCO 650-1,300 MHz on the 138K: the Ethernet PLL's output 0 becomes 1,000 / 10 = 100 MHz (section 9) |
| UG300-1.3.6E BSRAM | 3.3 | the memories in use are simple dual port with a registered read, never read-before-write (138K has none) |
| UG304-1.3.8E GPIO | 4.1 | RJ45 pins in SDR mode through fabric registers; no IDDR/ODDR is used any more (section 9) |
| SUG940-2.0E timing constraints | set_clock_groups, set_false_path | clock groups and the RGMII pins (section 3) |
| HL2 release branch docs/rawfront/PROTOCOL.md | 1, 5, 6, 9 | wire format, rates, transmit interlock |
| IEEE 802.3 clauses 36, 37 | | 1000BASE-X: /S/ on even symbols, /T/ /R/, idle, auto-negotiation (the benches' module model) |

No DCS, DSP or new PLL is used. Gowin synthesis and place-and-route were not run here (the full build is run separately).

## 1. What moved

| Before | After |
|---|---|
| HL2 on the RJ45 socket: RGMII PHY (rgmii_rx_phy, rgmii_tx_phy, IDDR/ODDR, MDIO, PHY reset), clk_rx = RXC, clk_tx = 125 MHz PLL | HL2 on SFP0 = quad 1 lane 0, 1000BASE-X to the copper module: rtl/sfp/sfp_phy.v (aligner, 8b/10b, PCS) gives bytes to the same hl2link chain; clk_rx = `n1_rxc`, clk_tx = `sfp_txc` |
| SFP0 = the processor's network: PCS + MAC + packet memory (rtl/sfp/sfp_net.v) on page 0x0A | page 0x0A keeps transceiver, cages, I2C and lane 0's PCS (net_ctrl, net_status, align_losses, new code_errors); MAC and packet memory not built (`sfp_top` NET_MAC = 0) |
| RJ45 = HL2 | RJ45 = the network unit: rtl/net/eth_top.v behind rtl/net/net_unit.v, page 0xE924_0000 (was 0xE811_0000 until NET_ID.md), 100 Mbit/s |
| SFP1 board link | unchanged |

The firmware sees the HL2 link exactly as before: the same pages 0x01 (hl2_link) and 0x02 (hl2_pkt), the same classifier,
rings and TX framer. Only the lane must be up first (fw/tr-app/src/sfplane.rs).

## 2. Receive gaps (task point a)

The receive buffer is read with `rx_clk_i` = `rx_pcs_clkout_o` (rtl/sfp/sfp_serdes.v), so by IPUG1024 3.7.2 a word comes
every clock. Clocks without a word (`rx_valid` 0) were still seen on the board, and frames were lost until the MAC took the
PCS's byte enable. So the whole chain is built for gaps of any pattern:

- the PCS (sfp_pcs.v) marks a new byte with `mac_rx_ce`;
- rtl/hl2link/gmii_rx_in.v (new) strips preamble and SFD with every register enabled by `ce`, and passes `ce` on;
- rtl/hl2link/eth_frame_rx.v: every register moves only with `ce`; every strobe to the sample ring and the CPU ring
  (raw_sof, raw_sample_valid, other_sof, other_valid) is 0 in a clock without a byte, so each byte is taken once;
  frame-end pulses are one clock as before;
- raw_frame_buffer.v and cpu_rx_ring.v act on those strobes only; the drain runs every clock, independent of gaps.

No elastic stage is needed: the chain takes at most one byte per clock and the line gives at most one byte per clock.
Benches: sim/h1_link_rx (-DGAPS), sim/hl2sfp, sim/hl2min (gaps always on, 2.5 % of the clocks without a word).

## 3. Clock domains (task point b)

| Clock | MHz | Clocks | Crossings |
|---|---|---|---|
| `n1_rxc` | 125 (recovered) | aligner, PCS receive, gmii_rx_in, eth_frame_rx, sample ring write and drain, CPU receive ring, regbus channel 1 | to clk_dsp: cdc_sample_fifo (Gray), cdc_word (counters, every 32 clocks), rx_tx_fill_bridge; from clk_dsp: the HL2 IP (cdc_word); to sfp_txc: sfp_xstat in the PCS |
| `sfp_txc` | 125 | PCS transmit and negotiation, coder, hl2_link_tx_top (framer second half, CPU queue, FCS, gmii_tx_out), regbus channel 2 | from clk_dsp: tx_sample_framer's FIFO, settings (cdc_word); from n1_rxc: sfp_xstat |
| `clk_eth` | 100 (PLL) | the network unit, regbus channel 3 | to clk_dsp: its interrupt through 3 registers; bus: toggle handshake |
| `clk_dsp` | 120 | registers, gap filler, receivers | |

No path runs directly between `n1_rxc` and `sfp_txc` outside sfp_xstat words (link_up goes back through two registers).
`gowin/p1/sdr.sdc`: `clk_rx`, `clk_tx` and `clk_25` are gone; `clk_eth` is a generated clock of the Ethernet PLL
(`-multiply_by 2`); the asynchronous group lists name `n1_rxc`, `sfp_txc`, `bl_rxc`, `clk_eth` beside the others (the AHB
clock is now asynchronous to the HL2 lane's clocks too, through bus channels 1 and 2). The RGMII pins are false paths
(section 9). `gowin/p1/sdr.cst`: clock line 11 is `clk_eth` (was `clk_tx`); line 10 (was the RJ45 receive clock,
no longer a clock) goes to `clk_aud`, which had lost its line in WP SFP; the PHY clock's LOCAL_CLOCK line is gone.
`gowin/p1/sdc_margin.py` tightens `clk_eth` like the other design clocks.

## 4. Transmit (task point c)

hl2_link_tx_top's arbiter, FCS (crc32_append.v, fixed in `final`) and framer are unchanged; rgmii_tx_phy.v is replaced
by rtl/hl2link/gmii_tx_out.v: the same preamble/SFD/12-byte-gap state machine, its byte as a register to the PCS
(`sfp_phy` puts one more register in front of the PCS). The PCS turns the first preamble byte into /S/ (or drops it when
the frame begins on an odd symbol, 36.2.4), adds /T/ /R/. Link gate: a frame that starts while the PCS has no link is
clocked through (no stall of framer or queue) with its enable held low, so the module never gets half a frame. The lane's
transmit buffer is written with `sfp_txc` = its own `tx_pcs_clkout` (equal clocks, IPUG1024 3.7.1).

## 5. Line rate and clock offsets (task point d)

Wire bytes per frame = UDP payload + 8 (UDP) + 20 (IPv4) + 14 (Ethernet) + 4 (FCS) + 8 (preamble, SFD) + 12 (minimum
gap). The 1000BASE-X line carries 125 M bytes per second (8 ns each), the same as 1000BASE-T.

| Direction, setting | Samples N | Wire bytes | Wire time | Sample time (76.8 MHz) | Line use |
|---|---|---|---|---|---|
| HL2 to us, header 20, MTU 1500 | 968 | 1,538 | 12.304 us | 12.604 us | 97.6 % |
| HL2 to us, header 20, jumbo | 5,968 | 9,038 | 72.304 us | 77.708 us | 93.0 % |
| HL2 to us, header 48 (duplex), MTU 1500 | 948 | 1,536 | 12.288 us | 12.344 us | **99.5 %** |
| HL2 to us, header 48, jumbo | 5,948 | 9,038 | 72.304 us | 77.448 us | 93.4 % |
| us to HL2 (TX frames, header 16), jumbo | 5,970 | 9,037 | 72.296 us | 77.734 us | 93.0 % |
| us to HL2, MTU 1500 | 970 | 1,537 | 12.296 us | 12.630 us | 97.4 % |

Clock offsets. The HL2's ADC clock and its Ethernet clock may each be off ours by 100 ppm: at +100 ppm the HL2 makes
1.0001 times the samples; the worst row (99.5 %) becomes 99.56 %: it fits, with 7 byte times to spare per frame, which
is too thin to recommend; duplex should use jumbo frames if the module passes them (section 11). Over hours nothing
accumulates in the chip:

- lane receive buffer: read and write clock are the same recovered clock (IPUG1024 3.7.2): it neither fills nor empties;
- the copper module: its own FIFO between the HL2's 1000BASE-T clock and its 1000BASE-X clock absorbs the difference
  inside each frame (200 ppm worst case: 14.5 bits in a 9,038-byte frame, 2.5 bits in 1,538) and takes it back in the
  gaps, which are at least 12 bytes plus the spare of the table;
- sample ring to clk_dsp: the drain takes up to 125 M samples/s, the gap filler up to 120 M/s against 76.8 M/s x 1.0001;
  the sample FIFO holds at most the samples of one burst; the ring (8,192) holds a frame (5,968) while the next comes;
- transmit: the TX framer is paced by the HL2's FIFO fill (H2 rate lock, unchanged); the lane's transmit buffer is
  written with its own read clock.

## 6. Loss accounting (task point e)

The owner's requirement: 100 % of the raw data. Counters (page 0x01, hw/regmap/hl2_link.toml, all from the HL2 link's
receive reset; the 16-bit ones stop at 0xFFFF):

| Register | Counts | Where |
|---|---|---|
| `seq_lost` (0x070) | raw frames missing by the HL2's frame sequence number: every frame lost before the commit, for any reason (line, module, FCS, code error, length) | eth_frame_rx.v |
| `rx_seq` (0x028) | sequence number of the newest committed raw frame (read 0 before) | eth_frame_rx.v |
| `loss_a` (0x074) | 15:0 sequence restarts (went back, or flag 4 "first frame"); 31:16 frames dropped for a code error | eth_frame_rx.v |
| `loss_b` (0x078) | 15:0 raw frames with a good FCS dropped for a length other than 3N/2 (or N odd, 0, above 5,968); 31:16 frames with flag 5 (the HL2 itself lost samples) | eth_frame_rx.v |
| `loss_c` (0x07C) | 15:0 committed frames not drained (the previous one still draining); 31:16 samples overwritten before they were drained | raw_frame_buffer.v |
| `loss_d` (0x080) | 15:0 frame indices lost (index FIFO full); 31:16 the HL2's own overflow count from its newest header | raw_frame_buffer.v, header |
| existing | crc_error_count (now including code errors), gap_count, gap_sample_count, resync_count, ring frames and drops | |
| page 0x0A | align_losses, code_errors (new), serdes_status buffer flags | sfp_phy.v |

Firmware: `tr_fabric::hl2link::Hl2Link::loss()` returns them (`LossCounters::none_lost`).

Bench (sim/hl2sfp/tb_hl2_sfp.v, `bash sim/hl2sfp/run.sh`): the chip's receive path (sfp_phy and hl2_link_rx_top, gap
filler on its own 120 MHz) against a synthetic HL2 stream in the PROTOCOL.md 5.2 format, sent in bursts back to back at
the minimum gap, through a 1000BASE-X module model written from clauses 36 and 37 (negotiation, /S/ on even symbols,
/T/ /R/, an elastic queue) and the lane model, receive buffer read 2.5 % fast. Every sample is checked against its
index (test pattern). Results, 20 ms of stream each (2026-10-21):

| Run | Frames | Samples out | Lost by sequence | Every other loss counter | Clocks without a word |
|---|---|---|---|---|---|
| N 968, bursts of 4, HL2 +100 ppm | 1,584 (+99 other) | 1,533,312 | 0 | 0 | 64,925 |
| N 968, bursts of 4, HL2 -100 ppm | 1,584 (+99 other) | 1,533,312 | 0 | 0 | 65,446 |
| N 5,968, bursts of 2, +100 ppm | 256 (+16 other) | 1,527,808 | 0 | 0 | 65,479 |

That the counters see a loss when there is one: sim/h1_link_rx (one corrupted frame: seq_lost 1, 968 fill samples) and
sim/hl2min -DDROP (lost 1, gap 1, fcs 1). Other benches of this change: sim/h1_link_rx (default, -DGAPS, backpressure),
sim/h2_link_tx (GMII out, 359 frames, FCS and echo checked), sim/sfp (codec, network, gaps; sfp_net now on sfp_phy),
sim/top/tb_sdr_core.v (the whole core: HL2 over lane 0 with a module model, the RJ45 unit looped back).

## 7. Copper module and HL2 settings

- Line mode: 1000BASE-X with negotiation first (the owner's 88E1111 module runs so); the firmware tries SGMII
  after 3 s without link (fw/tr-app/src/sfplane.rs).
- Jumbo frames through the module are not known. N = 968 (MTU 1500) works without them at 97.6 %; duplex at MTU 1500
  needs 99.5 % (section 5). The module's FIFO depth (the 88E1111's, set over I2C at address 0x56) was not read here.

## 8. Tests run (test budget of the task)

sim/sfp/run.sh (4 runs PASS), sim/h1_link_rx (default, -DGAPS, backpressure PASS), sim/h2_link_tx (3 ms PASS),
sim/hl2sfp (3 x 20 ms PASS), sim/hl2min (+100, -100 ppm, DROP, LANE1 PASS), sim/top/tb_sdr_core.v,
`cargo test -p tr-fabric`, `-p tr-regs`, ft8fw release build, tools/check_no_amo.sh (0).

## 9. The RJ45 network unit (task point f)

The eth_top module runs entirely in one fabric clock: RXC, RXD, RX_CTL through two synchroniser registers, TXC,
TXD, TX_CTL, MDC/MDIO and the PHY's 25 MHz reference as registers (DIV = 4 at 100 MHz, its board-tested default). It
cannot use our RGMII pieces (they are gigabit DDR), so it is used unchanged (rtl/net/eth_top.v) and wrapped by rtl/net/net_unit.v, which holds its read word for the bus. Its clock: H3's PLL with
output 0 at 1,000 / 10 = 100 MHz (gowin/p1/ip/gowin_pll_eth.mod `odiv0_sel` 10; rtl/hl2link/eth_clk_pll.v port `clk_100`).
The bus bridge (rtl/top/ahb_reg_bridge.v) has a fourth channel for the page `NET_PAGE`, in clk_eth. Interrupt line 6 is
the unit's (it was the SFP0 network's frame received); line 7 is the HL2 lane's link change.

**One place for the page:** `hw/regmap/net.toml` (base 0xE924_0000 since docs/NET_ID.md, the offsets and chip ID words, status final). The core takes
`NET_BASE` from the generated header for the bridge, the firmware `tr_regs::generated::net::BASE`. A new layout =
new net.toml + new eth_top.v (+ the offsets in fw/tr-fabric/src/eth.rs, marked NET-LAYOUT).

RGMII pieces now unused (left in the tree, not in the build list): rtl/hl2link/rgmii_rx_phy.v, rgmii_tx_phy.v,
gowin_iddr5.v, gowin_oddr5.v, mdio_ctrl.v, phy_reset_seq.v, phy_setup_top.v (marked not used); sim/h3_phy still tests
mdio_ctrl. Pins unchanged (gowin/p1/sdr.cst).

## 10. Firmware (task point g) and what is stubbed

| Item | State |
|---|---|
| HL2 session (fw/tr-station hl2session, fw/tr-hl2) | unchanged: same registers; it runs once the lane is up |
| fw/tr-fabric/src/n1.rs | lane 0 PCS only (`Lane0Pcs`: line mode, negotiation, status, counters); the packet-memory `MacRings` is gone |
| fw/tr-fabric/src/eth.rs | new: the network unit (the RJ45 driver), `MacRings`, PHY start-up (100 Mbit/s full duplex) |
| fw/tr-app/src/sfplane.rs | was sfpnet.rs: transceiver start-up, cages, line mode and link of the HL2 lane; no network time |
| fw/tr-app/src/rj45net.rs | new: PHY start-up, DHCP and SNTP (tr-net nettime) on the RJ45 unit; the station's clock |
| fw/tr-fabric/src/hl2link.rs | `loss()` for the new counters |
| **STUB** `rj45net::NetPort` | the trait the loader, TCI and GUI services will implement; nothing implements it until the interface is supplied |
| **STUB** chip ID words 0x80-0x9C of the network page (chip_dna) | not ported; read 0 |
| **STUB** the network loader (image header, PC protocol) | not started: designed elsewhere |

No atomic instructions (tools/check_no_amo.sh: 0).

## 11. Files the full build must know (gowin/p1/build.sh, updated)

Added: rtl/sfp/sfp_phy.v, rtl/hl2link/gmii_rx_in.v, rtl/hl2link/gmii_tx_out.v, rtl/net/eth_top.v, rtl/net/net_unit.v,
hw/regmap/generated/net_regs.vh (included by rtl/top/sdr_core.v). Removed from the list: rgmii_rx_phy.v,
rgmii_tx_phy.v, gowin_iddr5.v, gowin_oddr5.v, mdio_ctrl.v, phy_reset_seq.v, phy_setup_top.v (and the GOWIN_IDDR/ODDR
defines). Changed: gowin_pll_eth.mod (100 MHz), sdr.sdc, sdr.cst, sdc_margin.py.

## 12. Open risks

1. Nothing has run on the board. The PCS against the real 88E1111 in 1000BASE-X was run with pings, not with
   gigabit streams.
2. The module and jumbo frames; duplex at MTU 1500 uses 99.5 % of the line (section 5).
3. Timing: the byte enable adds a level to every register enable of eth_frame_rx at 125 MHz (`n1_rxc` had 19 failing end
   points in the ddr300 build already); clk_aud now on a long-wire line again.
4. The RJ45 unit is 100 Mbit/s: enough for control, GUI, TCI and the loader, not for raw streams.

## 13. An HL2 still streaming when the radio starts (board 2026-10-21, branch hl2fix)

- Seen: the session stayed at "looking for the radio"; `other` frames rose by ~80,000 a second, `raw` stood still.
  The HL2 had been started by the minimal design (hl2min) and streams on: it does not know the radio restarted.
- Cause: before discovery the classifier has no HL2 address (register 0), so every raw frame is "other" and goes to
  the 4 KB CPU receive ring (cpu_rx_ring.v keeps no read pointer and writes over old frames). A 60-byte discovery
  reply between them stays readable for 33.3 us (`bash sim/hl2sfp/run.sh -DSTALE`), far less than one main-loop
  pass, so the firmware never sees it. The 1,256,237 raw frames before that (15.8 s at 79,340/s) fit the HL2's own
  restart: its link dropped at the radio's FPGA load, it sent from address 0.0.0.0 during its DHCP attempt (equal
  to the register's 0, so counted raw) and took a 169.254.x.x address after 1 s settle plus 15 s.
- Fix (firmware only, works with the current bitstream): while looking for the HL2, if more than 200 non-raw frames
  arrived since the last discovery tick (0.5 s), the session broadcasts a stop (`EF FE 04 00`, port 1024) instead of
  the discovery request. The HL2 accepts broadcasts on ports 1024 and 1025 (gateware udp_recv.v, dsopenhpsdr1.v;
  RUNSTOP has no broadcast check). A stop enables nothing; the safety table in hl2session.rs lists it. Test:
  `a_radio_still_streaming_from_an_earlier_session` (tr-station tests/hl2_session.rs). The debug line now also
  prints the ring's frame count and the number of these stops.
- Not done (RTL, for a later build if wanted): keep frames that look raw (UDP source port 1024, byte 42 = 0xA5)
  out of the CPU ring whatever their source address.
