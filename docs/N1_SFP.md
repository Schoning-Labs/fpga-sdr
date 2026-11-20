<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# N1: SFP home-network link

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

**Superseded 2026-10-13 by docs/SFP_LINKS.md** (branch `sfp`): the PCS, the rings and `n1_top` of this work package are
replaced, its 8b/10b table and FCS were wrong and are fixed, the transceiver is instantiated, the link is in the
chip. Kept: the codec's structure, the MAC, `fw/tr-net`. The text below is history.

## Status (2026-09-27, paused mid-task)

**Done and verified:**
- `rtl/n1/`: 8b/10b codec (table generated and self-checked by `rtl/n1/gen_8b10b_table.py` against
  the public IEEE 802.3 clause 36 sub-block tables), an open-PCS fallback (`pcs_1000basex.v`) doing
  clause-37-style auto-negotiation and clause-36 idle/frame framing for both 1000BASE-X and SGMII,
  a GMII MAC (`gmii_mac_tx.v`/`gmii_mac_rx.v`, reusing `rtl/hl2link/crc32_append.v`/`crc32_eth.v`
  directly), and two packet rings (`n1_pkt_tx_ring.v`, `n1_pkt_rx_ring.v`) with a flat register
  interface (`n1_top.v`).
- `sim/n1/tb_n1_loopback.v` + `sim/n1/link_partner_model.v`: PASS in both 1000BASE-X and SGMII
  modes (`sim/n1/run.sh`) -- auto-negotiation completes, a 64-byte frame written into the DUT's
  transmit ring round-trips through the DUT's own PCS/MAC, the link-partner model's PCS/MAC, back
  through the DUT's receive PCS/MAC, and out the other side byte-for-byte identical, with the MAC's
  own CRC-error counter at zero. Getting there found and fixed six real bugs in this new code (all
  documented at the point they were fixed, in code comments naming "sim/n1's loopback test" as how
  each was found) -- a read-address pipeline off by one in the TX ring reader, a stray extra code
  group at end-of-frame in the PCS, a doubled register stage that corrupted the RX CRC's delay
  line, a mismatch with `crc32_append.v`'s own undocumented "first content byte never enters the
  running CRC" behaviour (confirmed empirically against that module directly), an inverted
  ring-free-space calculation that dropped every frame, and a write-address/write-enable pairing
  bug in the link-partner model's echo path. All six are fixed and the tests above pass with them
  in place.
- `fw/tr-net/`: `smoltcp`-based no_std glue (`MacRings` trait, `RingDevice: smoltcp::phy::Device`,
  an SNTP client, a disciplined UTC clock). `cargo test -p tr-net` passes: 6 unit tests plus
  `tests/dhcp_sntp.rs` (a real `smoltcp` `Interface` -- DHCPv4 client then a UDP/SNTP exchange --
  running entirely over an in-memory ring model against a hand-rolled DHCP+ARP+SNTP server model,
  disciplined clock ends up within 1 ms of the served time). `cargo check -p tr-net
  --no-default-features` (the no_std core) also compiles clean on the host target.
- `fw/tr-fabric/src/n1.rs`: the real MMIO driver (`N1<R: RegisterSpace>`, implementing `MacRings`)
  against `n1_top.v`'s register map. 4 unit tests against `tr-regs`'s mock pass (ctrl-write on
  construction, oversized-frame rejection, a normal transmit, and the "no frame waiting" receive
  case).

**Known gap, called out rather than silently left:** `tr-fabric/src/n1.rs`'s own test suite does
not exercise `receive()`'s indirect "write RX_RD_ADDR, read RX_RD_DATA" byte-copy loop for real --
`tr-regs::mock::MockRegisterSpace` models a flat page of independent registers, not an
indirect-addressed RAM, so a naive test against it silently checks the wrong thing (a first attempt
did exactly that, and was caught and removed rather than left in). The receive path this exercises
in Verilog terms *is* covered, just not from the Rust driver's own test suite -- `n1_pkt_rx_ring.v`
and the exact "address one cycle, data the next" read port `receive()` drives against it are what
`sim/n1/tb_n1_loopback.v` exercises end to end through the real register logic in `n1_top.v`. A
faithful Rust-side test needs either a small purpose-built fake `RegisterSpace` (a byte array plus
that latch-then-read behaviour) or waiting for WP T3's real register-map generator and its mock.

**Not done:**
- **Gowin resource/Fmax measurement** (`gowin/res.sh --wrap`) has not been run against any of the
  `rtl/n1/*.v` blocks yet. This is explicitly the last step this work package's task description asked for
  ("Gowin once at the end") and the owner's pause landed before it.
- **What is left for the board** (see the dedicated section below) has not changed: no real Gowin
  SerDes/PMA instantiation, no CST pin constraints, no I2C MS5351 clock setup, and the ability-byte
  AN scheme here is this design's own (not the official IEEE 16-bit Config_Reg layout), so it will
  not interoperate with a real off-the-shelf SFP module without further work -- see "What is left
  for the board".

**Exact next step when resumed:** run `gowin/res.sh --wrap` against the `rtl/n1/*.v` sources
(pattern: `gowin/res.sh n1_top --wrap rtl/n1/enc_8b10b.v rtl/n1/dec_8b10b.v
rtl/n1/pcs_1000basex.v rtl/n1/gmii_mac_tx.v rtl/n1/gmii_mac_rx.v rtl/n1/n1_pkt_tx_ring.v
rtl/n1/n1_pkt_rx_ring.v rtl/n1/n1_top.v rtl/hl2link/crc32_eth.v rtl/hl2link/crc32_append.v`),
copy the small excerpt into `gowin/reports/n1_top/` per `gowin/reports/README.md`, fill in the
"Results" section below with the numbers, and commit.

## Design: why an open PCS, not Gowin's licensed IP

ARCHITECTURE.md 3.8 and BOARD.md's own recommendation are Gowin's SGMII/1000BASE-X IP (DS1104
2.6), generated once and committed as `.ipc` + a regeneration script (the PLAN.md rule for all
Gowin IP). That IP is generated interactively from Gowin EDA's IP Core Generator GUI; there was no way here to drive that GUI, so PLAN.md's own fallback applies: "otherwise a small open PCS."
Everything under `rtl/n1/` is that fallback, built from scratch for this work package (not a
vendored/ported PCS), plus direct reuse of `rtl/hl2link/crc32_append.v` and `crc32_eth.v` exactly
as the task asked.

## 8b/10b: correctness, not vendoring

The codec (`rtl/n1/enc_8b10b.v`, `dec_8b10b.v`, generated table `rtl/n1/tab_8b10b.vh`) implements
the actual IEEE 802.3 clause 36 / Widmer-Franaszek algorithm -- not a simplified or self-consistent
substitute -- because the SFP module on the other end of a real link needs a standard-compliant
partner. `rtl/n1/gen_8b10b_table.py` builds the full table from the public 5b/6b (32-entry) and
3b/4b (8-entry, with the D.x.P7/D.x.A7 alternate) sub-block tables and the 12 fixed K-code words
(all technical constants published in the standard and widely republished, e.g. on Wikipedia's
"8b/10b encoding" page -- not another project's source code), and self-checks the result (full
running-disparity round trip for all 256 bytes at both starting disparities, plus the K28.5 comma
property) before emitting `tab_8b10b.vh`. An early plan to vendor an existing OpenCores 1000BASE-X
PCS project (which would have covered the 8b/10b codec and the AN state machine both) was not
pursued: the sandbox's own safety classifier declined the bulk download as "untrusted code
integration," and per the standing instruction boundary that classification is respected rather
than routed around through another tool. Building the codec from the public algorithm and the AN
state machine from the clause 37 mechanics (see below) took the place of that shortcut.

## Simplification: the AN ability byte is this design's own, not the IEEE layout

`pcs_1000basex.v` runs the real clause 37 *mechanics* -- continuous comma-prefixed ability
exchange, a 3-consecutive-identical-values consistency check, an ack handshake, a transition
through idle detection to link-up, and a restart on loss of signal or an invalid code group -- but
the ability byte exchanged is this design's own 8-bit field (link/duplex/mode-echo/ack/speed bits),
not the official IEEE 16-bit Config_Reg bit layout (clause 37 Figure 37-3) or the SGMII MAC-mode
register's own layout. This is why `sim/n1/link_partner_model.v` (which speaks the same 8-bit
layout) interoperates with this PCS but a real SFP module's PHY-side autonegotiation will not, yet
-- see "what is left for the board" below.

## What is left for the board

- **Gowin SerDes/PMA**: `pcs_1000basex.v` operates at 8b/10b *code-group* granularity (one byte of
  code-group content per `clk`, matching every other block in this directory) -- there is no
  bit-serial serialiser/deserialiser, comma bit-alignment, or CDR here. The real Gowin SerDes hard
  PMA for SerDes quad Q1 lane 0 needs to be instantiated and wired to `serdes_tx_code`/
  `serdes_rx_code` in `n1_top.v`.
- **CST pin constraints** for SFP0: none written yet (BOARD.md: TX_DISABLE R18, LOS V18, module I2C
  through the mux).
- **MS5351 125 MHz reference clock**: set over I2C by the BL616, not by the FPGA (BOARD.md); no
  code here talks to it, and none should -- this is firmware/board bring-up work outside the FPGA
  design.
- **Official AN ability-byte layout**: see the simplification note above. Needed before this PCS
  will link up with a real off-the-shelf SFP module's own autonegotiation, rather than only with
  `link_partner_model.v`.
- **`tr-fabric`'s register base address** (`N1_BASE = 0xE80A_0000` in `fw/tr-fabric/src/n1.rs`) is
  a placeholder matching ARCHITECTURE.md 4.1's reservation, but `n1_top.v`'s own flat register
  layout has not been split to match that document's two separate 64 KB pages (MAC/PCS status vs.
  packet memory) -- WP T3's real register-map generator is the eventual source of truth here, not
  this hand-written offset table.
- **Real hardware validation**: nothing here has run against real 8b/10b silicon or a real SFP
  module; `sim/n1/link_partner_model.v` is built from the same primitives as the DUT (see that
  file's header for why that is still a meaningful test, and its limits).
- **`tr-fabric/src/n1.rs`'s `receive()` test coverage gap**: see the status section above.

## Gowin resources and Fmax

Not measured yet -- see "exact next step" in the status section above.

## Results (Verilog simulation, `sim/n1/run.sh`, both PASS)

- 1000BASE-X: link up after 15 status polls; 64-byte frame echoed and verified byte-for-byte after
  238 cycles; MAC CRC-error counter 0.
- SGMII: link up after 17 status polls; same frame round trip in 238 cycles; MAC CRC-error counter
  0.

## Commit

`2311f76` on branch `n1`, not merged.
