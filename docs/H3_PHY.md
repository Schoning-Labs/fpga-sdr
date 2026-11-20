<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# H3: RTL8211F PHY setup and RGMII pin constraints

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Work package H3 (`docs/PLAN.md`), branch `h2h3` (bundled with H2). Covers the RTL8211F PHY setup (MDIO, RGMII delay, the 25 MHz
reference) and the pin constraints for the Tang Mega 138K Pro dock's RJ45 port, which BOARD.md and
H1_LINK_RX.md both left as this WP's job ("RGMII pin locations... a pin constraints file is H3's
job", "blocked (needs RX pins from the schematic)").

## 1. Pin assignment and PHY straps, from the dock schematic

**2026-10-21 (docs/HL2_SFP.md):** the RJ45 PHY is no longer the HL2's: it is the network unit's (rtl/net, eth_top, 100 Mbit/s); the RGMII and MDIO pieces described here are not in the chip any more.


Source: Sipeed's dock schematic (BOARD.md's own citation), rev 1.2, sheet `RGMII_sch.kicad_sch`
("RGMII_ETHNET"), read with `pdftotext -layout` (the schematic text extracts cleanly; no image
OCR was needed) on `TANG_MEGA-138K_Pro-Dock-4071f_Schematics.pdf` page 17 of 19.

### 1.1 RGMII bus, MDIO, clock and reset pins

| Signal | FPGA pin | Direction | Notes |
|---|---|---|---|
| `RGMII_TXD[0]` | K21 | FPGA to PHY | |
| `RGMII_TXD[1]` | J21 | FPGA to PHY | |
| `RGMII_TXD[2]` | L19 | FPGA to PHY | |
| `RGMII_TXD[3]` | K18 | FPGA to PHY | |
| `RGMII_TXEN` (TX_CTL) | J24 | FPGA to PHY | |
| `RGMII_TXCK` | H24 | FPGA to PHY | this WP's `eth_clk_pll.v` `clk_125` (GTX_CLK) |
| `RGMII_RXD[0]` | B26 | PHY to FPGA | **previously NOT VERIFIED (BOARD.md); confirmed here** |
| `RGMII_RXD[1]` | C26 | PHY to FPGA | as above |
| `RGMII_RXD[2]` | D26 | PHY to FPGA | as above |
| `RGMII_RXD[3]` | E26 | PHY to FPGA | as above |
| `RGMII_RXDV` (RX_CTL) | C22 | PHY to FPGA | as above |
| `RGMII_RXCK` | C23 | PHY to FPGA | as above; source-synchronous, H1's `clk_rx` |
| `RGMII_MDIO` | K22 | bidirectional | shared management bus |
| `RGMII_MDC` | K23 | FPGA to PHY | |
| `EPHY_CLK` | E18 | FPGA to PHY | 25 MHz reference (this WP's `eth_clk_pll.v` `clk_25`) |
| `EPHY_~{RST}` | E17 | FPGA to PHY | active low (`PHYRSTB`) |

The TX pins and MDIO/clock/reset pins already matched BOARD.md's own (independently sourced)
listing exactly, confirming the same schematic sheet is being read consistently; the RX pins are
new (BOARD.md's open item, now closed).

I/O standard: **LVCMOS33**. The PHY's RGMII I/O rail is strapped to external 3.3 V: `LED0/CFG_EXT`
is pulled up to `PHY_VIO` (R71, 5.1 kOhm) and the schematic's own strap table reads
`CFG_EXT=1'b1, CFG_LDO[1:0]=2'b00` -> "External 3.3V" (the same sheet also documents
`CFG_LDO[1:1]=0x11, select 3.3V external power`) -- so this is the PHY's own actual supply rail,
not merely this FPGA family's default choice.

### 1.2 RTL8211F address and RGMII delay straps

The schematic labels **"PHY0 Address = 3'b001"** directly (appears twice, next to the address
strap resistors on `RXD3`/`RXC`/`RXCTL`): **MDIO address 1**.

RGMII delay is set entirely by board strap, both directions enabled, confirmed two ways:

- The schematic's own resistor population: `PHY0_RXD1/TXDLY` and `PHY0_RXD0/RXDLY` each have one
  of their two strap resistors stuffed (5.1 kOhm) with the note *"Pull Up to add 2ns delay to
  TXC/RXC for TXD/RXD latching"* printed once, next to both.
- A community-compiled reference to the RTL8211F(I)/RTL8211FD(I) datasheet itself (Rev. 1.1, 21 Feb
  2014; Realtek's own PDF could not be fetched directly -- every direct download
  attempt timed out or returned an HTML redirect page instead of a PDF; this reference cites it by
  section and page throughout, and its own strap table's default/pulled values match this board's
  reading independently): `TXDLY` pulled high -> "+2 ns internal delay on TXC" (the PHY delays the
  *incoming* TXC before latching TXD, so the MAC may drive TXC edge-aligned with TXD); `RXDLY`
  pulled high -> "+2 ns internal delay on RXC" (the PHY delays the *outgoing* RXC, so it arrives
  centred in the RXD eye at the MAC). Source:
  https://github.com/anarkiwi/reefervole/blob/master/docs/rtl8211f.md (retrieved via `gh search
  code`/`gh api`, itself citing DS section 6.6 Table 6 p.9 and section 7.8 Table 11 p.15).

**Consequence for this WP's own RTL**: neither `rgmii_tx_phy.v` (H2) nor a future RGMII receive
delay block needs to add or compensate for any delay -- the PHY already centres both clock edges
relative to their data, both directions, by strap alone. `phy_setup_top.v` does not write an RGMII
delay register; docs/H2_LINK_TX.md section 6 and this file both flag this as **confirmed, not
merely assumed**, by the PHY ID read (section 3) succeeding at all -- a wrong strap value would
still answer MDIO correctly; only real RGMII traffic (WP B5, on the board) would show a wrong
delay, as CRC errors, which is out of this WP's own (pre-board) scope.

The straps also latch a PHY power-mode bit (`PLLOFF`, "pull down: PLL continues toggling in ALDPS
mode") not relevant to RGMII timing or MDIO addressing, so it is noted here for completeness and
not acted on.

### 1.3 What this WP does not attempt

No PULL_MODE is set on the RGMII RX pins beyond the .cst fragment's own defaults: unlike an ECP5
board the reefervole reference above also documents (where the FPGA's own configuration-time
pull-ups fight the board's strap resistors and must be explicitly disabled), nothing in DS1104/
DS1239 suggests the GW5AST family drives a competing pull on unconfigured I/O in this way; this is
flagged here as worth checking against `gw_sh` once WP T1's licence makes that possible (the same
status every Gowin-specific fact in this WP already carries), not asserted as verified.

## 2. Reset sequencing (`phy_reset_seq.v`)

Per the same community-compiled reference (section 1.2's citation): **`PHYRSTB` held low >= 10 ms**
(the straps in section 1.2 are latched as reset releases, so a short reset re-strap-samples
correctly but a *register* access before the PHY has finished its own internal power-up would not
get a real answer), then **a further >= 30 ms before register access**. `phy_reset_seq.v` defaults
to 12 ms hold and 35 ms post-reset settle (2 ms and 5 ms of margin over those minimums), and also
holds reset until `eth_clk_pll.v` reports `locked`, since the PHY's own internal logic needs a
stable 25 MHz reference before the strap latch and its own power-up sequencing mean anything.

These are the same order of magnitude as two independent Rockchip device-tree defaults for this
exact part found alongside the reference above (`snps,reset-delays-us = <0 20000 100000>`, i.e.
20 ms hold + 100 ms settle) -- more conservative than the cited datasheet minimums, which this
module's own defaults sit between. **Flagged for confirmation against Realtek's own datasheet**
once it can be fetched or a physical copy is available (WP B3/B5, board bring-up), since it could not be retrieved directly (section 1.2).

## 3. MDIO (`mdio_ctrl.v`)

Plain bit-banged clause 22 master (DS1104/DS1239 name no hard MDIO controller for this chip
family): 32-bit frame (preamble, ST, OP, PHYAD, REGAD, TA, DATA), MDC generated by dividing the
input clock (default `MDC_DIV=50`, giving 1.25 MHz from a 125 MHz input, inside the clause 22
2.5 MHz ceiling with margin).

**RTL8211F PHY ID**: 0x001cc916 (PHYID1 register 2 = 0x001C, PHYID2 register 3 = 0xC916), found
via `gh search code "RTL_8211F_PHYID"` turning up a device-tree patch defining
`#define RTL_8211F_PHYID 0x001cc916` (`Advantech-EECC/meta-modular-bsp-nxp`) -- a driver-source
citation, the same kind of independent confirmation BOARD.md already uses elsewhere in this
repository, not a value taken on faith from one place.

### 3.1 Done-test: MDIO read against a register model

`sim/h3_phy/tb_mdio.v` drives `mdio_ctrl.v` against `sim/h3_phy/mdio_phy_model.v`, a small test-only
register model (not synthesisable, not part of the FPGA build -- the same role the vendored HL2
files play for H1/H2) that answers clause 22 reads at PHY address 1 (section 1.2) for PHYID1/
PHYID2 (0x001C/0xC916) and BMCR (a third, different register, checked to prove the controller
really addresses what it is told to, not just replaying its first answer).

```
$ iverilog -g2012 -o build/tb_mdio.vvp sim/h3_phy/tb_mdio.v && vvp build/tb_mdio.vvp
PHYID1=001c PHYID2=c916 BMCR=1140
PASS
```

Reading that against the PLAN.md H3 done-test ("MDIO read of the PHY ID in simulation against a
register model"): the combined 32-bit read (0x001cc916) matches the real RTL8211F ID exactly, and
the BMCR read at a different register address returns that register's own distinct value, not the
ID repeated -- proving `REGAD` addressing works, not just that one hard-coded answer comes back.

## 4. 25 MHz reference (`eth_clk_pll.v`)

One Gowin PLL from the board's 50 MHz oscillator (BOARD.md; SOM schematic, pin P16), the same VCO
plan Sipeed's own RGMII example uses (BOARD.md's own citation of `udp_rgmii_send/src/gowin_pll/
GMII_pll.v`: "50 MHz x 20 = 1,000 MHz VCO, /8 and /40"): CLKOUT = VCO/8 = 125 MHz (RGMII_TXCK /
this repo's `clk_tx`), CLKOUTD = VCO/40 = 25 MHz (`EPHY_CLK`). **NOT VERIFIED** against Gowin's own
primitive library, same status as every other Gowin-specific primitive in this repository pending
WP T1's licence (`gowin_iddr5.v`, `gowin_oddr5.v`).

## 5. Pin constraints (`gowin/cst/h3_rgmii_phy.cst`)

A fragment, not a whole-chip file (WP P1 concatenates every block's own constraints and adds the
SDC-side timing constraints once real timing closure is in scope) -- see the file's own header.
Every `IO_LOC` is one of section 1.1's table entries; `IO_TYPE=LVCMOS33` throughout per section
1.1's own reasoning.

## 6. Gowin measured resources and timing

`gowin/res.sh --wrap`, `phy_setup_top.v` (`gowin/reports/README.md` has the method), commit
`4ba2b7e`:

```
gowin/res.sh phy_setup_top --clk clk_in --wrap rtl/hl2link/eth_clk_pll.v \
    rtl/hl2link/phy_reset_seq.v rtl/hl2link/mdio_ctrl.v rtl/hl2link/phy_setup_top.v

phy_setup_top_ooc_wrap: Logic 186/138240, Register 223/139140, DSP 0/298, BSRAM 0/340
  -- 149.993(MHz) target, 197.141(MHz) achieved
Block alone: phy_setup_top: Logic 146, Register 140
```

Comfortably clears 150 MHz (this block is small: a clause 22 bit-bang state machine and a reset
counter, no datapath), measured against `clk_in` -- `eth_clk_pll.v`'s own real clocks (`clk_125`,
`clk_25`) are generated *inside* this block, and `mdio_ctrl.v`/`phy_reset_seq.v` actually run on
`clk_125`, so this number is really "how fast the 50 MHz input path plus the PLL's own
combinational logic closes", not a `clk_125`-domain measurement -- most of this block's own logic
(the MDIO state machine, the reset counters) is clocked by `clk_125` internally and reported
correctly at the summary's "Block alone" line; only the fact that the *wrapper* drives everything
at `clk_in`'s rate is the same class of approximation section 5's own dual-clock caveat describes.

**RGMII I/O timing** (needs real pins, not the generated wrapper -- `gowin/res.sh --wrap`'s whole
point is to avoid pin-placement effects on *logic* timing, which would hide exactly the number
these particular pins need reported) is **not measured in this work**: it needs a small,
separate top-level wired directly to `gowin/cst/h3_rgmii_phy.cst`'s pins rather than the
`--wrap` flow, which the Gowin runs available here did not extend to alongside the two
`--wrap` measurements above and WP H2's own long simulation runs. Left for WP P1 (the chip top
level, which needs a real, pin-constrained build regardless) or a follow-up piece of work.

## 7. What H3 leaves for later

- **Realtek's own datasheet** for the reset timing and PHY ID (sections 2, 3) could not be fetched
  directly; both numbers are corroborated from independent secondary sources
  (a community reference citing the datasheet by section/page, and driver source code) but should
  be checked against a primary copy before WP B3/B5 (board bring-up) relies on them without
  margin.
- **`eth_clk_pll.v`'s `GOWIN_PLL` branch and `gowin_oddr5.v`'s `GOWIN_ODDR` branch are unverified**
  against the real primitive library (WP T1 pending), same status as every Gowin-specific
  primitive in this repository so far.
- **RGMII RX pull-mode** (section 1.3) is flagged, not resolved, pending a `gw_sh` check.
- **Real RGMII traffic through the PHY** (confirming the strap-based delay actually works, not
  just that MDIO answers) is WP B5's job, on the board.
