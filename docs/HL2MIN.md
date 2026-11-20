<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# HL2MIN: minimal FPGA build to test the Hermes-Lite 2 over SFP cage 0

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Written 2026-10-21, branch `hl2sfp`. Owner's request: before the full radio, a small build
that brings the real HL2 up over the SFP0 lane and counts every lost packet. Nothing here has run on a board.

Cabling (docs/DECISIONS.md 2026-10-21): the HL2's Ethernet into a 10Gtek "1.25G SFP-T" copper module (Marvell 88E1111,
1000BASE-X towards us) in cage SFP0 = quad 1 lane 0 at 1.25 Gbit/s. No switch between.

## 1. What is in it

| Part | File | Clock |
|---|---|---|
| Pins, reset key, Gowin transceiver (`Serdes_Top`, IDE default reset form) | `rtl/hl2min/hl2min_top.v`, `rtl/sfp/sfp_serdes.v` | |
| Clock chip and transceiver start-up, no processor | `rtl/hl2min/hl2min_clkseq.v` | clk_50m |
| Lane 0: aligner, 8b/10b, PCS 1000BASE-X with auto-negotiation | `rtl/sfp/sfp_phy.v` (sfp_rx_sym, sfp_pcs, enc_8b10b) | n1_rxc / sfp_txc |
| HL2 receive chain with byte enable and loss counters (docs/HL2_SFP.md) | `rtl/hl2link/hl2_link_rx_top.v` and below | n1_rxc (its "clk_dsp" side too) |
| The HL2's MAC and IP, learned from its discovery reply | `rtl/hl2min/hl2min_core.v` | n1_rxc |
| Frame sender (discovery, stop, register 0x30, start) | `rtl/hl2min/hl2min_sender.v`, `rtl/n1/fcs_append.v`, `rtl/hl2link/gmii_tx_out.v` | sfp_txc |
| One UART line a second, LEDs | `rtl/hl2min/hl2min_report.v`, `hl2min_core.v` | clk_50m |

Not in it: AE350, DDR3, PLLs, video, USB, the receivers. Lane 1 exists only because the quad is generated with both
lanes (`gowin/p1/ip/serdes/serdes.toml`); its PCS stays in reset, its words are 0, cage SFP1's transmitter is off.

## 2. Start-up (hl2min_clkseq.v), copied from the firmware's order (fw/tr-fabric/src/sfp.rs; docs/SFP_LINKS.md 2.3)

1. Hold 5 ms: both lanes in reset (`pma_rstn` 0), all PCS resets high, SFP0 transmitter off.
2. I2C multiplexer channel 3: N19 = 1, P19 = 1, P26 = 0 (N19 is select bit 0; board run 2026-10-20).
   The MS5351M at 0x60 gets the 40 writes of `program_clock_chip` in that order: outputs off, 16/17/18 powered down,
   PLL A and PLL B = 25 MHz x 30, dividers 6 on outputs 0 and 1, output control 16 = 0x4F, 17 = 0x5F (output 1
   inverted), 177 = 0xA0 (PLL reset), 3 = 0xFC (outputs 0 and 1 on). About 100 kbit/s, open drain.
3. 10 ms, then register 0 every millisecond until SYS_INIT and LOL_A (0xA0) are clear, at most 100 ms.
4. Lanes out of reset, PCS still in reset; up to 100 ms for lane 0's PLL lock. No lock: back to step 1, again
   without limit (`try=` on the UART line counts the attempts).
5. Locked: lane 0's PCS out of reset, the PCS enabled (1000BASE-X, negotiation on), the SFP0 transmitter on. While
   running, lane 0's receive side is reset for 1 ms when it had signal but no aligner lock for 100 ms.

A missing I2C acknowledge sets bit 7 of `pcs=` and the sequence goes on, as the firmware does.

## 3. Receive

Lane 0's recovered clock clocks the PCS receive side and the whole HL2 receive chain of docs/HL2_SFP.md section 4,
including the gap filler (one sample per clock, 125 M/s against 76.8 M/s). The classifier needs the HL2's IP: it is
taken from the HL2's discovery reply (UDP from port 1024 or 1025, payload `EF FE 02` or `EF FE 03`, FCS good), with
its MAC. Raw frames from that IP are counted and their samples checked:

- with the test pattern (default, register 0x30 bit 1) every real sample must equal its index mod 4096
  (PROTOCOL.md 5.5): `pat=` counts mismatches; this checks every sample, not only every frame;
- lost frames by the HL2's sequence number, the largest single jump, bad FCS (and code errors), wrong length, our
  overflows (ring overrun, drain busy, index FIFO), the HL2's own overflow count from the header, fill samples.

## 4. Transmit and SAFETY

Once a second a discovery (`EF FE 02`, broadcast, port 1025). While the HL2 is known and no raw frame came in the last
second: stop (`EF FE 04 00`, port 1024), register 0x30 (`EF FE 05 7F 60` + value, port 1025), start (`EF FE 04 81`,
port 1024), all unicast to the HL2's MAC and IP (its gateware takes register writes only unicast:
dsopenhpsdr1.v). Our addresses: MAC 02:54:52:00:00:01, IP 169.254.77.1, UDP port 51000.

Register 0x30 = N << 16 | test pattern << 1 | raw mode on; default N = 968 (standard frames).

**Transmit interlock.** These four frames are the only ones the sender can make (one case statement). None reaches
the HL2's transmit path (PROTOCOL.md section 9): no TX_PERMIT (it needs the register bridge on port 1027, never sent),
no register 0x09 (PA enable, TX gain), 0x31 (duplex, real DAC: stays 0, so the HL2 takes no TX samples), 0x3A-0x3D,
no EP2 frame (`EF FE 01`), no flash command (`EF FE 03`); the MOX bit (bit 0 of the address byte 0x60) is 0. Start
byte 0x81 = run and watchdog off only. The safety byte of every raw frame is shown (`sb=`; 0x01 = transmit off).

## 5. UART line and LEDs

115,200 baud 8N1 on P15 (FT2232 channel B), one line a second, numbers decimal unless marked hexadecimal:

```
t=16 st=4 ln=f pcs=1f fr=173 by=24195 lost=0 gap=0 fcs=0 len=0 ovf=0 hovf=0 fill=0 pat=0 sb=01 ip=0a630002 ck=00 try=1 id=0123456789abcdef
```

| Field | Meaning |
|---|---|
| t | seconds since reset |
| st | start-up step: 0 hold, 1 I2C, 2 reference wait, 3 lock wait, 4 running |
| ln | lane 0 status, hex: bit 0 PLL lock, 1 receive clock lock, 2 signal detect, 3 ready |
| pcs | hex: 0 link up, 1 negotiation done, 2 synchronised, 3 idles seen, 4 aligner locked, 6 the lane's receive buffer gave a clock without a word (sticky), 7 I2C acknowledge missing |
| fr | raw frames committed (total) |
| by | bytes received in the last second (all frames, destination MAC to FCS) |
| lost | raw frames missing by sequence number (total) |
| gap | largest number of frames missing at once |
| fcs | frames dropped for a bad FCS or a code error |
| len | raw frames dropped for a length that is not 3N/2 |
| ovf | our receive overflows: drain busy + ring overrun + index FIFO |
| hovf | the HL2's own FIFO overflow count (from its last header) |
| fill | zero samples the gap filler inserted |
| pat | test-pattern mismatches |
| sb | the HL2's transmit-safety byte, hex |
| ip | the HL2's IP, hex (0 until its discovery reply came) |
| ck | the clock chip's register 0, hex (00 = locked) |
| try | start-up attempts |
| id | the chip's factory ID (Gowin OTP DNA, 64 bits, 16 hex digits; zeros until the read is done, about 150 us after reset; docs/NET_ID.md) |

At N = 968 a running stream shows about 79,300 frames and 120 MB a second. LEDs (active low on the dock, as in
fpga-sdr; locations J14, R26, L20, M25 from a board-tested constraint file): 0 PCS link up, 1 raw frames
arriving (0.1 s stretch), 2 any loss since reset (lost, ovf, fill, pat or len not 0), 3 heartbeat (toggles each second).

## 6. Build

```
gowin/hl2min/build.sh                 # synthesis, place-and-route, bitstream (Gowin V1.9.12.04)
HL2MIN_N=5968 gowin/hl2min/build.sh   # jumbo frames (only if the copper module passes them)
HL2MIN_ADC=1 gowin/hl2min/build.sh    # real ADC samples instead of the test pattern
HL2MIN_LANE=1 gowin/hl2min/build.sh   # the module in cage SFP1 (lane 1); lane 0 idle
```

**Lane option (added 2026-10-21, because the owner's module is in cage SFP1).** `HL2MIN_LANE=1` puts the
HL2 on quad 1 lane 1 = cage SFP1 (tx_disable M20 low, SFP0's R18 high; LOS W18 unused as on lane 0). The build makes
lane 1 like lane 0: 1.25 Gbit/s, 10-bit raw words, a copy of `serdes.toml` whose `[q1.ln1]` is then identical to
the proven `hw/gowin/sfp/serdes.toml` (both lanes 1.25G Ethernet), IDE-default reset form. Lane 1's transmit
buffer is written with its own `tx_pcs_clkout` (`ln1_txc`) and its receive buffer read with its own `rx_pcs_clkout`
(`bl_rxc`); the logic runs on those two, and the constraints name them instead of `sfp_txc` and `n1_rxc` (same clock
lines 12 and 13). No lane-0 clock touches lane 1's buffers (a lane-0 clock on them corrupted data on this board); in both settings lane 1's transmit buffer has its own clock. Clock-chip start-up unchanged; the lane-PLL
wait and the receive resets act on lane 1, lane 0's PCS stays in reset. Default `HL2MIN_LANE=0`.

Bitstream `gowin/impl/hl2min_top/impl/pnr/hl2min_top.fs`. Constraints `gowin/hl2min/hl2min.cst`, `hl2min.sdc`
(three asynchronous clocks: clk_50m, sfp_txc, n1_rxc; the lane clocks on long-wire lines 12 and 13 as in the full
chip). The transceiver is generated exactly as for the full chip (the "SFP" section of gowin/p1/build.sh, copied). A
dry run (`GOWIN_DRY=1`, GowinModGen and the register-file tool only) was made; no synthesis was run here.

Gowin documents used: IPUG1024-1.7.2E 3.7.1, 3.7.2 (the user interface is a FIFO; `rx_clk_i` = `rx_pcs_clkout_o`
gives equal read and write clocks, a word may still be missing: `rx_valid`), table 4-1 (lane reset, PCS resets),
3.2 (reset forms); SUG940 (`set_clock_groups -asynchronous`); SUG1220 3.3.19 (`set_csr`). No PLL, DCS, IDDR/ODDR or
DSP is used; block RAM only by inference (receive ring 8,192 x 12, sample FIFO, CPU ring), simple dual port with a
registered read, never read-before-write (UG300 3.3).

## 7. Bench

`bash sim/hl2min/run.sh [-DPPM_NEG] [-DDROP] [-DSIM_SECS=n]`: hl2min_core.v whole (everything but the pins and
Gowin's block) against a clock chip model, the lane model with receive gaps (receive buffer read 2.5 % fast), a
copper-module model written from IEEE 802.3 clauses 36/37 (negotiation, idle, /S/ /T/ /R/ on even positions, an
elastic queue), and the HL2's own send RTL in test-pattern mode on a clock 100 ppm off ours. Its command side is a
model that checks every frame we send (FCS, kind; any other frame is a safety error). The second is 200 us there.

Results (2026-10-21):

| Run | Result |
|---|---|
| +100 ppm, gaps | PASS: 40 clock-chip writes, link up, HL2 learned and started, 173 raw frames, lost 0, fcs 0, ovf 0, fill 0, pat 0, safety errors 0, 10,584 clocks without a word |
| -100 ppm, gaps | PASS, same counters 0 |
| -DDROP (one byte flipped on the line) | PASS: lost=1 gap=1 fcs=1 fill=968, the rest 0 |
| -DLANE1 (+100 ppm, gaps) | PASS: cage SFP1 on, SFP0 off, lane 1 PCS released, lane 0 PCS in reset; lost 0, fcs 0, ovf 0, fill 0, pat 0 |

## 8. Open, for the board

- The copper module: jumbo frames (N = 5968) and its FIFO depth (the 88E1111's register 16) are not known; the
  default N = 968 uses standard frames (docs/HL2_SFP.md section 7).
- The HL2 needs an IP to answer unicast: with no DHCP on the direct cable it takes a 169.254.x.x address after about
  15 s (PROTOCOL.md section 1); until then `ip=` may be 0 and our unicast frames go to 0.0.0.0, which its gateware
  accepts as its own address only while it has none.
- LED polarity and J14 for LED 0 are taken from fpga-sdr, not seen on this build.
