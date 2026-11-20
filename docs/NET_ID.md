<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# NET_ID: RJ45 fixes and the board identity

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Branch `netid` (cut from `ddr300`), 2026-10-21. Nothing here has run on a board; no Gowin synthesis or place-and-route was run (the full build is run separately).

## 0. Documents used

| Document | Section | Used for |
|---|---|---|
| Gowin SUG283-3.6.1E Primitives User Guide (`Gowin_V1.9.12.04_x64/IDE/doc/EN`) | 8.9 OTP, tables 8-13 to 8-16, figure 8-14 | `OTP` is supported on GW5AST-138 (table 8-13). Ports CLK, READ (pulse, at least one clock, loads the 128-bit fuse register), SHIFT (level, shifts it out on DOUT, lowest bit first, one bit per clock). MODE 2'b01 = chip DNA: bits 95 to 32 (64 bits) are valid. The guide gives no clock limit for this device |
| Board run of the network page (2026-10-21) | | DOUT carries register bit 0 before the first clock edge, so the ID is raw[95:32] (the first guess raw[96:33] was one bit too high) |

Not used: no DSP, BSRAM or PLL is new. The OTP clock is a fabric register (clk / 32: 1.56 MHz at 50 MHz, 3.1 MHz at 100 MHz;
inside the 1.2 to 4.7 MHz range run on the board). No timing constraint is needed or added for it.

## 1. RJ45 and chip ID changes

| Item | Result |
|---|---|
| `rtl/io/eth_top.v` | unchanged: includes the TXC timing fix of commit 19029b3 (TXC rises one clock after TXD/TX_CTL change, so TX_CTL never changes at an edge) |
| `rtl/io/eth_xck.v` | not used: it is only needed for 75 MHz builds (DIV = 3, TXC and the PHY clock from a 150 MHz clock). Here `eth_top` runs DIV = 4 on the 100 MHz `clk_eth`, where the unit's own registers give a square wave |
| `rtl/io/chip_dna.v` | `rtl/net/chip_dna.v`, logic unchanged (SPDX line and a "modified 2026" note added) |
| Chip ID registers | `rtl/net/net_unit.v`: 0x80 to 0x90 raw read (129 bits), 0x94 status (bit 0 done, 15:8 width 64), 0x98 ID low, 0x9C ID high (raw[95:32]) |
| Page | **0xE924_0000**, the page the generic board loader expects. Was 0xE811_0000 here. One place: `hw/regmap/net.toml`; the core and the firmware take it from the generated files. The bridge decodes HADDR[23:16] = 0x24, which no other block uses; 0xE924_0000 is inside the AE350's 0xE800_0000 to 0xEFFF_FFFF window |
| Link test | the unit's status test accepts 100 Mbit/s full duplex (`Status::usable`), as before; a test now pins 10, 1000, half duplex and no receive clock as not usable |
| PHY start-up | `fw/tr-fabric/src/eth.rs` `Phy`: reset low 12 ms, then 100 ms before the first MDIO read (was 35: the RTL8211F reads all ones at 35 ms and answers at 70 ms); read the identifier at address 1, else at 0 to 31; a start-up that fails runs again from the reset every second, the wait doubling (100 ms to 3.2 s); the receiver takes every frame meanwhile; only the first failure is an event |

Kept from this branch: the wiring in `sdr_core.v` (clk_eth, bus channel 3, interrupt line 6), `net_unit.v`'s read-word
hold, `MacRings`, millisecond clock for the PHY start-up.

## 2. Chip ID in the build

- Every radio bitstream: `net_unit` instantiates `chip_dna` (clock `clk_eth`, reset = the unit's reset). The read takes about 150 us
  after reset; `dna_status` bit 0 says done. Registers above.
- Minimal HL2 build (`rtl/hl2min`): `hl2min_core` instantiates `chip_dna` on `clk_50m`; the UART line gets ` id=<16 hex digits>`
  at its end (fields 18 and 19, high and low word; zeros until the read is done). Sample: `... ck=00 try=1 id=0123456789abcdef`.
- The ID in the simulation is `0123456789abcdef` (the expectation; `sim/net/otp_model.v` holds it).

## 3. Firmware

- `fw/tr-net/src/ident.rs` (no_std, host-tested): `mac_from_dna`, `host_name`, `choose`. MAC = 02 + the low 40 bits of
  `h ^ (h >> 29)`, h = FNV-1a 64 bit over the ID's 8 bytes low byte first; name = `tang-` + the MAC's last three bytes.
  For `0123456789abcdef`: MAC `02:32:f8:2f:e5:cf`, name `tang-2fe5cf.local` (values produced by running the functions).
- `fw/tr-app/src/rj45net.rs`: `Rj45Net::new(.., mac_setting)` reads the ID (waits at most about 1 ms for the read), picks
  stored setting, else ID, else the fixed fallback `02:54:52:00:00:02` (printed with a warning). `identity()` gives ID, MAC, name;
  `ft8fw` prints three lines at start-up. The firmware has no settings store yet, so it passes `None`.
- There is no mDNS responder in this firmware yet; the name is derived and printed.

## 4. Benches

`sim/net/tb_dna.v` (reader against the OTP model), `sim/top/tb_sdr_core.v` (ID registers through the AHB bridge at
the new page, the frame loop-back of the RJ45 unit), `sim/hl2min/run.sh` (the ID on every UART line). Firmware: `cargo test`
of `tr-net` (ident) and `tr-fabric` (eth). Results are in the commit message of the branch's last commit.

## 5. What the build must know

- New file in the Gowin file lists: `rtl/net/chip_dna.v` (added to `gowin/p1/build.sh` and `gowin/hl2min/build.sh`). It instantiates
  Gowin's primitive `OTP` (`#(.MODE(2'b01))`), which synthesis knows; the simlib's `OTP` has no body, so every bench that
  includes the reader also includes `sim/net/otp_model.v` (benches only, never a build).
- No constraint change: the OTP clock is an internal register, as in earlier board-tested builds. If place-and-route
  complains about a clock from a register, no special handling has been needed so far.
- `sdr_core.v` is no longer free of vendor primitives (it contains `OTP` through `net_unit`).
