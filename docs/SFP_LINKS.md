<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# SFP_LINKS: the two SFP+ cages in the chip — network socket (SFP0) and board link (SFP1)

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Written 2026-10-13, branch `sfp`. Owner: "add these missing features first". Replaces the stub `sfp_link_stub`
(docs/P1_TOP.md section 6) and the plan of P1_TOP 11.3. Earlier work it builds on: docs/N1_SFP.md (MAC, rings,
firmware, an 8b/10b codec; its PCS is replaced here, section 4). Part GW5AST-LV138FPG676AC1/I0, Gowin V1.9.12.04. Nothing here has run on a board.
**2026-10-21 (branch `sfpport`):** this network path was run on the same board in another build; the fixes
that run found are ported here (section 12), which changes sections 2.3, 2.4, 4, 6 and 7.
**2026-10-21 (branch `hl2sfp`, docs/HL2_SFP.md; cabling decision in docs/DECISIONS.md):** SFP0 carries the Hermes-Lite 2,
not the processor's network. Lane 0's PCS (now rtl/sfp/sfp_phy.v) gives its bytes to the HL2 link; the MAC and packet memory
of section 4 are not built in the chip (`sfp_top` NET_MAC = 0, kept for sim/sfp/tb_sfp_net.v); page 0x0A keeps the
transceiver, cages, I2C and the PCS registers, plus `code_errors` (0x044). Interrupt 6 is the RJ45 network unit's, 7 the HL2
lane's link change. Where this file says "network" for SFP0, read "HL2 link".

Words: **lane** = one transmitter and receiver of the chip's transceiver; **lane clock** = a clock the lane gives
the logic; **symbol** = one 8b/10b code (10 bits on the line, 8 bits and a control flag in the logic).

## 0. Documents used

| Document | Section | Used for |
|---|---|---|
| IPUG1024-1.7.2E Gowin Customized PHY IP | 3.2 | the reference must be stable before configuration, or "Global Reset Enable": port `por_n_i`, held low until it is (steps 1 to 5). Used since 2026-10-21 only with `SFP_POR_FABRIC=1`; the default is the form without it (2.4) |
| | table 4-1 | `pma_rstn_i` "PMA reset input, active-low" (the lane, its PLL included: 2.3); `pcs_rx_rst_i`, `pcs_tx_rst_i` active high |
| | 3.7.1, 3.7.2 | with equal read and write clocks `tx_fifo_afull_o` and `rx_fifo_aempty_o` are constant 0, so `wren = ~afull`, `rden = ~aempty`, with a register in each (2.3); `rx_valid_o` 3 clocks after `rden` |
| | 3.7.3, table 4-1 | status outputs (`pll_lock`, `rx_cdr_lock`, `signal_detect`, `ready`) |
| Board runs of this network path | | the board runs of this network path on the same board (section 12) |
| | 3.5, 3.7, tables 3-4 to 3-9 | lane clocks = line rate / width; the user interface is two buffers "in the form of FIFO": `tx_clk_i` is the **write clock** of the transmit buffer and `tx_pcs_clkout_o` its read clock, `rx_clk_i` the read clock of the receive buffer; data "low first"; without 8b/10b the 10-bit and 20-bit words are bits 9:0 and 19:0 |
| | 2.2, table 4-1 | line rate 1 to 12.5 Gbit/s, reference 50 to 800 MHz, widths 8/10/16/20/32/40/64/80; `pll_lock`, `rx_cdr_lock`, `signal_detect`, `ready` |
| DS1239-1.0.3E data sheet | tables 3-19 to 3-23 | this part and grade: up to 10.3125 Gbit/s on one board; lane PLL 1.25 to 6.5 GHz with divider 1/2/4/8; reference 20 to 800 MHz; receiver AC coupled |
| Sipeed example `sfp+/customized_phy` (Apache-2.0), commit d3cebf1 | readme, `1.25G/src` | "8B/10B encoding with comma align (except for the case of 1.25Gbps)"; their 1.25 Gbit/s example runs the lane **without** 8b/10b at width 10 |
| Sipeed `docs/SET_5351.md`, dock schematic rev 1.2 sheets CLOCK, TWI_MUX, SFP-PLUS | | clock chips, I2C multiplexer, cage pins (section 7) |
| IEEE 802.3 clauses 36, 37; Cisco SGMII specification 1.8 | | ordered sets, auto-negotiation, the SGMII control word (section 4) |
| Install, read in place | `ipcore/SERDES_IP/IPlib/CUSTOMIZED/data`, `bin/serdes_toml_to_csr_138k.exe`, `GowinModGen` | what builds from the command line (section 2.4) |

## 1. Decisions in short

| Question | Decision | Why |
|---|---|---|
| Network lane (SFP0, quad 1 lane 0) | **1.25 Gbit/s, raw 10-bit words, no 8b/10b and no alignment in the hard block**; 8b/10b, comma alignment and the PCS in logic | 1000BASE-X and SGMII are 1.25 Gbit/s by definition. Sipeed's own 1.25 Gbit/s example is raw 10 bit and their readme excludes hard 8b/10b at this rate. Our codec is built from the standard's tables and simulated; idle needs the running disparity, which only our own coder shows |
| Board-link lane (SFP1, quad 1 lane 1) | **2.5 Gbit/s, raw 20-bit words**, the same codec and aligner in logic | The HL2 stream is 76.8 Msps x 12 bit = 0.92 Gbit/s. At 1.25 Gbit/s the line carries 1.0 Gbit/s of data: 8 % for framing, too thin. At 2.5 Gbit/s it carries 2.0 Gbit/s: one sample per 16-bit word uses 61 % with no bit packing. 20 bits at 2.5 Gbit/s is **125 MHz, the same word clock as lane 0** (next row). 3.125 Gbit/s gives nothing more. The part allows 10.3 Gbit/s; a passive SFP+ cable is made for 10.3 |
| An earlier board-link design | 1.25 Gbit/s, hard 8b/10b, 40-bit words at 31.25 MHz (its payload was 0.1 Gbit/s of audio). Never built with the lane; lane clocks on ordinary wiring failed hold in its full design | its low rate does not carry our stream |
| Transmit clock | **one** 125 MHz clock for both lanes: lane 0's transmit clock writes both transmit buffers | both lanes' transmit clocks come from the same reference, so they have exactly the same frequency; the buffer is a two-clock FIFO by IPUG1024 3.7. Saves a clock line. Fall-back: build switch `SFP_TXC_SHARED=0` gives lane 1 its own |
| Reference clock | clock chip "PLL0" (MS5351M, 25 MHz crystal) at **125 MHz** on quad 1 reference input 1 (pins AA13/AB13), both lanes | the pair wired straight to the chip; 125 MHz is one of Sipeed's three tested settings |
| Who programs it | **our firmware, at start-up, over I2C from the FPGA** (two open-drain pins and the three select pins of the board's I2C multiplexer, as a register; the chip is register-compatible with the Si5351A). The lanes are held in reset by `pma_rstn_i` from a register until firmware has written the chip and seen its PLL lock (2.3; the `por_n_i` form of the plan did not lock in the board run) | no dependence on what the debug chip saved, on its firmware version, or on power-up order. The same I2C pins reach the cages' module memories (section 7) |
| Clock lines | three new clocks, all on long-wire lines; freed by taking the audio clock and the two reset nets off them (section 3) | |
| Board-link frame | 16-bit words; sample frames of up to 128 samples with a 48-bit first-sample index and CRC-16; 32-bit control words for the CPUs; a status word each millisecond (section 5) | |
| Receiver input select | a run-time bit: the receiver bank, zoom, spectrum and FT8 take the HL2 link's stream or the board link's | one bitstream for both boards |
| Registers | page 0x0A `sfp` (transceiver, cages, I2C, network MAC and packet memory), page 0x0B `blink` (board link), both in `clk_dsp` behind a bus leg | no page depends on a lane clock running |

## 2. The transceiver

### 2.1 Lane settings

| | Lane 0 (SFP0, network) | Lane 1 (SFP1, board link) |
|---|---|---|
| Line rate | 1.25 Gbit/s | 2.5 Gbit/s |
| Lane PLL (from the register-file tool's output) | VCO 1,250 MHz, divider 2 | VCO 1,250 MHz, divider 1 |
| Internal width, ratio | 10, 1:1 | 20, 1:1 |
| 8b/10b, word alignment, clock correction, channel bonding | off | off |
| Word clock | 125 MHz | 125 MHz |
| Swing, equalisers | 900 mV, automatic (Sipeed's values) | the same |

Bit order: "low first", bit 0 of a word goes on the line first. The codec's tables have `a` (first on the line)
at bit 9, so `rtl/sfp/sfp_serdes.v` reverses each symbol. In case the board shows otherwise there are register
bits per lane and direction for bit reversal and for polarity (four bits, 40 LUTs).

### 2.2 Alignment and codec in logic

`rtl/sfp/sfp_align.v` (width 10 or 20): looks for the comma (0011111 or 1100000 in bits `abcdeif`) at every bit
position of two consecutive words, takes the position, and is locked after three commas in a row at that position.
In lock, commas elsewhere are ignored; 16 invalid symbols within 4,096 words drop the lock and the search starts
again. With width 20 the comma symbol is always the first of the two, so the word boundary is found with it.
`rtl/n1/enc_8b10b.v`, `dec_8b10b.v` are N1's (table from the standard). The 20-bit coder takes the disparity of the
second symbol from a flag worked out one clock earlier, so no two table look-ups are chained in a clock.

### 2.3 Reset and reference start-up

Order, run by firmware (`fw/tr-fabric/src/sfp.rs`, 2026-10-21 from the board runs, section 12):

1. Before anything: both cages' module memories are read and printed (`fw/tr-app/src/sfpnet.rs`), with `serdes_ctrl` =
   hold (`por_n` 0, both lanes in reset, all four PCS resets high).
2. Write the clock chip (multiplexer channel 3 = N19 1, P19 1, P26 0): PLL A and PLL B = 25 MHz x 30 = 750 MHz, divider 6
   on outputs 0 and 1, output 1 inverted, PLL reset.
3. Wait 10 ms, then until the chip's register 0 shows SYS_INIT and LOL_A clear (at most 100 ms).
4. `por_n` 1 and both lanes out of reset (`pma_rstn_i` = 1), PCS resets still high. The lane reset is the reset of
   the whole lane, its PLL included (IPUG1024-1.7.2E table 4-1; the generated wrapper drives `FABRIC_LNn_RSTN_I` with
   it). The plan of 2026-10-13 released it only after `pll_lock`, so the lane PLL could never lock (board
   run 2026-10-21).
5. Wait up to 100 ms for lane 0's `pll_lock`. Each attempt prints one line: `serdes_ctrl`, `serdes_status` (with the
   quad's own status in bits 23:16 and the buffer flags in 27:24, section 6) and the clock chip's register 0. No lock:
   back to hold, 10 ms, again from step 3; after five attempts the network stays off.
6. Locked: lane 0's PCS out of reset; lane 1's PCS (board link) when its own PLL has locked. The receive side of a lane is
   reset again when the aligner has had no lock for 100 ms while `signal_detect` is high.

With the default build (2.4) `por_n` has no effect: the quad starts at configuration, and steps 4 and 5 restart the
lanes on the reference the clock chip now gives.

The FIFO enables of both lanes (`tx_fifo_wren_i = ~afull`, `rx_fifo_rden_i = ~aempty`, IPUG1024-1.7.2E 3.7.1, 3.7.2)
have a register each (`rtl/sfp/sfp_serdes.v`): in the full build of the board run the inverters were placed far from the block,
3.8 ns each way. With equal clocks the flags are constant; otherwise almost full and almost empty leave room for the one
word more. The receive buffer is read while not almost empty, so a receive clock may carry no word (`rx_valid` 0); the PCS
then marks its MAC byte as not new (section 4).

### 2.4 How the IP is built without the IDE

As the AE350 and DDR3 IP: nothing of Gowin's is in git. `gowin/p1/build.sh` generates the wrapper `Serdes_Top`
with `GowinModGen` from `gowin/p1/ip/serdes/serdes.ipc`, adds Gowin's encrypted PHY source from the install with
our `define.vh` and `param.v`, makes the register file with `serdes_toml_to_csr_138k.exe` from
`gowin/p1/ip/serdes/serdes.toml` and names it with `set_csr`. `serdes.toml` is the file the owner made in
the IDE (both lanes, 1.25 Gbit/s, 8b/10b; first made 2026-10-13), changed by hand in these keys only: lane 0 `width_mode` 10, lane 1
`width_mode` 20 and both data rates "2.5G", both lanes `encode_mode`/`decode_mode` "OFF", gear rates "1:1",
`word_align_enable` false (quad 1 `por_toggle_by_fabric` was set true too; back to the IDE's false on 2026-10-21). The
tool accepts it and reports the PLL settings of the table above. The per-lane macros are ours.

**Reset form (2026-10-21, from the board runs; IPUG1024-1.7.2E 3.2).** The script used to put `por_n_i` on the
generated wrapper's `FABRIC_POR_N_I` by hand and set quad 1 `por_toggle_by_fabric` true. That left the CMU resets and
every lane PLL's reset (`FABRIC_CMU0/1_RESETN_I`, `FABRIC_LNn_CPLL_RESETN_I`) tied low while the quad took them from the
logic: in the board run the lane PLL never locked. `GowinModGen` has the IDE's option as the `.mod` line
`-global_reset enable|disable` (the `.ipc`'s `global_reset_enable` is ignored). Even with Gowin's full global form the
lane PLL did not lock there; it locked with the IDE's default (no global reset; the register file ends with
0xc10008 = 3). `gowin/p1/build.sh` now builds:

| `SFP_POR_FABRIC` | Form | Wrapper | Register file |
|---|---|---|---|
| 0 (default) | the IDE's default | `-global_reset disable`: no `por_n_i` (`TR_SFP_NO_POR` leaves the port off in `sfp_serdes.v`); the build stops if the text has one | `serdes.toml` as committed; ends 0xc10008 = 3 (seen in a dry run) |
| 1 | Gowin's "Global Reset Enable" | `-global_reset enable`: `por_n_i` on `FABRIC_POR_N_I`, the CMU and lane PLL resets, `CK_AHB_I` from `FABRIC_CM_LIFE_CLK_O`; the build checks each | a copy with quad 1 `por_toggle_by_fabric = true` (ends 0xc10008 = 1) |

Both forms: the build adds the output `sfp_diag` to the wrapper from eight of its internal nets (CMU0/CMU1 OK, reference
detect CM0/CM1, lane 0/1 CMU OK, lane 0/1 PMA receive lock), shown in `serdes_status` bits 23:16. Generated and checked
with `GOWIN_DRY=1` in both forms (GowinModGen and the register-file tool only, no synthesis).

## 3. Clocks

| Clock | MHz | From | Clocks |
|---|---|---|---|
| `sfp_txc` | 125 | lane 0 `tx_pcs_clkout` | network PCS and MAC transmit side; board-link framer; both lanes' transmit buffers |
| `n1_rxc` | 125 | lane 0 `rx_pcs_clkout` (recovered) | aligner, decoder, PCS and MAC receive side, the write side of the receive ring |
| `bl_rxc` | 125 | lane 1 `rx_pcs_clkout` (recovered) | aligner, decoders, deframer, hold buffer |

Each is its own asynchronous group. Crossings: toggles with held words (`cdc_word`), Gray-coded FIFOs
(`cdc_sample_fifo`), two-clock block RAM. No register page is in a lane clock.

**Clock lines** (P1_TOP 11.3 is updated to this). Before: primary 8 of 8; long-wire: `clk_50m_d`, `rgmii_rxc_d`,
`clk_tx`, `clk_pix`, `clk_aud`, `clk_48m`, and two reset nets the tool put there (`rst_dsp`, the DDR3 reset).

| Change | Frees |
|---|---|
| `clk_aud` (49.152 MHz, S/PDIF and I2S: one small unit, `audio_digital_out`) to `LOCAL_CLOCK` | 1 long-wire line |
| the two reset nets leave when clocks ask for their lines (the tool's own rule; plan step 2) | 2 long-wire lines |

`clk_48m` was to give its line (plan step 3, when its one load was the audio PLL). Since the merge of USB audio
(master bf07eb2) it clocks the USB core and must stay on a global line, so the audio clock goes instead, the
fall-back P1_TOP 11.3 names.

After: primary 8 of 8 unchanged; long-wire `clk_50m_d`, `rgmii_rxc_d`, `clk_tx`, `clk_pix`, `clk_48m` (line 8),
**`sfp_txc`, `n1_rxc`, `bl_rxc`** (lines 12, 13, 14 by constraint); `clk_aud` on ordinary wiring. **USB needs no
further line** (device and the coming host both run on `clk_48m`). No long-wire line is free; the three reserves of
the plan are untouched and each frees a primary line: the DDR3 IP's reference from the oscillator net instead of a
PLL copy (step 4), the AE350's 10 MHz RTC clock (step 5), and the 5x pixel clock, which only clocks the three HDMI
serializers (step 6). The first of them freed puts `clk_aud` back on a global line. If the shared transmit clock had
to be given up (section 1), a fourth line would be needed for `ln1_txc`.

Constraints: `create_clock` at the three lane-clock nets, 8.0 ns; `TIMING_MARGIN_PCT` shortens their period like the
design clocks' (`gowin/p1/sdc_margin.py`).

## 4. Network socket (SFP0)

**The PCS of N1 is replaced.** N1's `pcs_1000basex.v` sent idle as a lone data symbol and its own 8-bit ability
byte; no real device would have answered it (N1_SFP.md said so for the ability byte). The new one follows the
standard:

| Item | Implementation |
|---|---|
| Ordered sets | idle `/I1/` = K28.5 D5.6 (once, when the running disparity is positive) and `/I2/` = K28.5 D16.2; configuration `/C1/` = K28.5 D21.5 + 16-bit word, `/C2/` = K28.5 D2.2 + word, alternating; frame `/S/` K27.7 in place of the first preamble byte, `/T/` K29.7, `/R/` K23.7, a second `/R/` when the frame ended on an even position so that idle starts on an even symbol (36.2.4) |
| Receive synchronisation | the aligner's lock (2.2) plus even/odd symbol position taken from the commas |
| Auto-negotiation (clause 37) | ability match and acknowledge match on three equal words in a row, idle match on three idles; states enable, restart, ability detect, acknowledge detect, complete acknowledge, idle detect, link OK; link timer 10 ms (1.6 ms in SGMII mode); restart on a received word of 0, on loss of lock, on a register write |
| 1000BASE-X word | ours: 0x0020 (full duplex) plus acknowledge bit 14 |
| SGMII word (MAC side) | ours: 0x4001; the module's word gives link (bit 15), duplex (12), speed (11:10); link up needs its link bit. Only 1000 Mbit/s is carried: at 10/100 the status shows the speed and the MAC stays silent |
| Without negotiation | register bit "force": idle straight away, link up when locked and idles arrive (for a partner with negotiation off) |
| Mode | register bits: 1000BASE-X or SGMII, or **automatic**: firmware reads the module's memory over I2C (identifier, 1000BASE-T compliance bit) and picks; if that fails it tries one mode, then the other, 3 s each |

Receive side in `n1_rxc`, transmit side and negotiation in `sfp_txc`; the received word and the three match flags
cross as a held word. No elastic buffer and no insertion or removal of idles is needed, because received frames go
straight into the ring in the receive clock.

MAC: N1's `gmii_mac_tx.v`, `gmii_mac_rx.v`. Since 2026-10-21 the receiver has a byte enable `ce` from the PCS
(`mac_rx_ce`): a receive clock without a word holds the PCS's outputs, and without the enable the MAC took the held byte
again and the frame failed its FCS (board run: most short frames lost; section 12). Packet memory, new and smaller than N1's (block RAM is the
tight resource): transmit buffer 2 KB (one frame in flight, as N1), receive ring 8 KB; both two-clock block RAMs
with a 32-bit port at the CPU (four bytes per register access) and an 8-bit port at the MAC. 5 block RAMs.
Interrupt 6 = frame received, 7 = link went up or down. N1's rings were 16 and 32 KB and read a byte per access.

## 5. Board link (SFP1)

### 5.1 Words

A word is 16 bits: two symbols, the low byte first on the line. Only the low byte is ever a control symbol.

| Word | Low byte | High byte | Then |
|---|---|---|---|
| idle | K28.5 (comma) | D16.2 | - |
| sample frame start | K27.7 | frame counter (8 bits) | 3 words: index of the first sample, 48 bits, low word first; then 1 to 128 sample words; then end |
| sample word | sample bits 7:0 | 0000 + sample bits 11:8 | |
| sample frame end | K29.7 | number of samples - 1 | 1 word: CRC |
| control word start | K28.0 | sequence number (8 bits) | 2 words: the 32-bit value, low word first; 1 word: CRC |
| status start | K28.3 | bit 0 my receiver has the link up, bit 1 I am sending samples, bit 2 my control receive FIFO is full, 7:4 format version 1 | 1 word: my count of bad frames (16 bits); 1 word: CRC |

CRC-16 (polynomial 0x1021, start 0xFFFF, word by word from bit 15 down) over every word of the frame from the
start word up to the CRC, idles left out. Idle words may stand between any two words of a frame and are dropped by the
receiver: the sender puts one whenever it has no sample ready (the stream fills 61 % of the words), so commas keep
coming and the framer needs no look-ahead. One idle word follows every frame. Priority of the sender between frames:
status when due (every 2^17 clocks, 1.05 ms; every 512 clocks while either end's link is still down; at once when a
flag or its bad-frame count changed), a waiting control word, samples.

### 5.2 What version 1 carries

- **The raw sample stream, board 1 to board 2.** Board 1 takes the stream behind its gap filler (sample, valid,
  fill flag, index). **Fill samples are not sent**: a frame is closed in front of a gap and the next one starts with
  the index after it. A frame is also closed after 128 samples. Board 2 feeds the frames through a second
  instance of the HL2 link's own `gap_filler.v`, unchanged: a jump of the index becomes zero samples marked as
  fill, a jump over 65,536 a resync, exactly as on board 1, and a frame lost on the link (bad CRC, code error,
  missing end) is filled the same way. So board 2's receivers see the same samples at the same index, with the same
  gap marking, and its sample index is board 1's (the HL2's).
- **Control words both ways**: 32 bits, a 16-deep FIFO each way, interrupt when one waits. CRC-protected; a bad one
  is dropped and counted, and the sequence number shows the gap. Meaning of the 32 bits is firmware's.
- **Status both ways** and the counters of 5.3.

Loss on the link costs at most one frame: 128 samples, 1.7 us, zero-filled.

### 5.3 Link state and counters

Link up: lane ready, aligner locked, 4 good frames of any kind in a row. Down: aligner lock lost, or 8 bad frames in
a row, or no good frame for 4 ms. Registers: state bits (lane PLL, receive lock, signal detect, aligner lock, link
up, remote link up, remote sending, remote FIFO full), counters of good sample frames, bad frames (CRC, code error,
length), sample frames with a counter jump, aligner lock losses, link-up events, samples sent and received, control
words sent, received, dropped (FIFO full), the remote's bad-frame count; from the gap filler: gap events, gap
samples, resyncs. Interrupt 14 = control word waiting, link went up or down (12 is USB audio's, 13 the USB host's).

### 5.4 Receiver input select

`blink.ctrl.rx_from_link`: 0 = the receiver bank, zoom receiver, full-band spectrum and FT8 front end get the HL2
link's stream (sample, valid, fill flag, index), 1 = the board link's. One register stage behind the selection; it
is also in front of board 1's link sender, which always takes the HL2 stream. The HL2 transmit side and its rate
lock keep the HL2's own stream on both boards. Switching is glitch-free but not sample-exact (the two streams are
unrelated in time); firmware switches while the receivers are disabled.

## 6. Registers

`hw/regmap/sfp.toml` (0xE80A_0000) and `hw/regmap/blink.toml` (0xE80B_0000) are the source; docs/REGMAP.md is
generated. `serdes_status` bits 23:16 (2026-10-21): the quad's own status (2.4); 27:24 sticky flags since the lane's PCS
side last left reset: 24 lane 0 transmit word not written (buffer almost full), 25 lane 0 receive clock without a word,
26 and 27 the same for lane 1. ARCHITECTURE 4.1 had 0x0A for the network settings and 0x0B for its packet memory; the packet memory is
now inside page 0x0A (0x1000 transmit buffer, 0x2000 receive ring) and 0x0B is the board link.

## 7. Pins (dock schematic rev 1.2, Sipeed's constraint files; none tried on a board)

| Signal | Pin | Note |
|---|---|---|
| SFP0 / SFP1 transmit and receive pairs, reference 1 | dedicated (quad 1 lanes 0 and 1; AA13/AB13) | bound by the transceiver block, not by the .cst |
| `sfp0_tx_disable`, `sfp1_tx_disable` | R18, M20 | high = module transmitter off; reset value high, firmware lowers it. A passive cable ignores it |
| `sfp0_los`, `sfp1_los` | V18, W18 | shown in the status register; not used by the logic (a passive cable gives no level): the lane's own lock signals decide |
| module present, transmit fault, rate select | not on FPGA pins (test points and pull resistors) | presence is found by reading the module's memory |
| `twi_scl`, `twi_sda` | K25, K26 | the board's system I2C, 2.2 kohm to 3.3 V on the board; open drain |
| `twi_sel[2:0]` | N19, P19, P26 (bits 2, 1, 0 of the register field). **N19 is the multiplexer's least significant select input** (drawing of IC3/IC4 on sheet TWI_MUX; the sheet's table and the CLOCK notes read it the other way, which made channel 3 select channel 6 in the board run of 2026-10-20). Firmware maps channel bits to pins (`channel::sel_bits`) | 8-way multiplexer: channel 0 = SFP0 module, 1 = SFP1 module, 3 = clock chip PLL0, 4 = clock chip PLL1; the others are HDMI and the camera socket. The debug chip sits on the clock chips' side of the multiplexer too |

## 8. What only the boards can confirm

1. Reset form: lane 0 and lane 1 PLLs lock with the IDE's default form and the lane-reset start-up of 2.3 (in the board run
   lane 0 at 1.25 Gbit/s locked that way; a lane at 2.5 Gbit/s was not tried).
2. Reference start-up: the clock chip answers at address 0x60 on channel 3 and gives 125 MHz with our register
   values (register map taken as the Si5351A's); the debug chip does not disturb the bus.
3. Lane 0: lock at 1.25 Gbit/s raw; bit order and polarity; the copper module's mode (SGMII or 1000BASE-X), its
   auto-negotiation against our PCS, link to the home switch, DHCP and SNTP.
4. Lane 1: 2.5 Gbit/s over the passive cable (one board, cage 0 to cage 1 is not possible with two different
   rates: it needs two boards, or a loopback plug in cage 1); bit errors over an hour; the transmit buffer of
   lane 1 written with lane 0's clock.
5. The I2C multiplexer's channel numbers and the module memories (bit order confirmed on the board; the module memory of
   an OEM SFP-GE-T was read).

## 9. Tests

| Bench | Checks |
|---|---|
| `sim/sfp/tb_sfp_codec.v` | every data byte and control symbol through coder, a serial line with an arbitrary bit offset, aligner and decoder, widths 10 and 20 |
| `sim/sfp/tb_sfp_net.v` | the network path as wired in the chip, through a bit-serial model of the lane: against an independent model of a link partner written from the standard (not from our PCS), in 1000BASE-X with negotiation and in SGMII; a frame each way; restart of negotiation. `-DGAPS` (`run.sh gaps`, 2026-10-21): the receive buffer read with a clock 2.5 % faster than the words, so some clocks carry no word; it fails on the MAC without the byte enable (36 errors) and passes with it |
| `fw/tr-fabric` `sfp::tests` | multiplexer select bits, clock chip register order (PLL A and B), module memory parsing, start-up order (lanes out of reset before the lock, PCS after it, lane 1's PCS after its own lock), five lock attempts then off |
| `sim/blink/tb_blink.v` | two link ends through two lane models with different clocks: sample stream bit-exact with its index, a gap at the source, a dropped frame and a corrupted one (zero-filled, same index after), loss of lock and resync, control words both ways, status |
| `sim/top/tb_sdr_core.v` | the pages through the bus bridge, both links in the whole core |

## 10. Results (2026-10-13)

**Simulation.** `bash sim/sfp/run.sh`, `bash sim/blink/run.sh`, `sim/top/tb_sdr_core.v`: all PASS. Network
bench: 37,818 (1000BASE-X) and 35,025 (SGMII) symbols of the design checked for code, disparity and place; a frame
each way with the FCS checked by the bench's own CRC; a corrupted frame dropped; renegotiation; dead line. Link bench:
29,192 samples bit-exact at their index, 808 zero-filled (source gap 40, one lost frame 128, dead line 640). Whole
core: both lanes looped, negotiation, a 62-byte frame through the packet memory, the stream over the link into the
receivers, a control word, interrupts 6, 7, 14.

**Two faults of N1 found by these benches, both fatal on a real network:** the 8b/10b table gave the wrong
disparity after D.7, D.x.3 and the seven balanced control symbols (100 of 536 table lines; found by counting bits);
the FCS left out the first byte of the frame, and N1's receiver had been made to agree. The second comes from
`rtl/hl2link/crc32_append.v`, which the HL2 link's transmit side uses too: measured alone, it gives the CRC of
bytes 1 to N-1. **Settled in branch `final` (docs/H2_LINK_TX.md 1.7): the HL2 link's transmit FCS was wrong on the wire too and is fixed in `crc32_append.v`**; the network MAC keeps its own `rtl/n1/fcs_append.v`, now the same logic.

**Chip cost** (full-chip build 3 against the USB build of master, gowin/reports/p1_usb): logic 85,527 (62 %), +5,075;
registers 72,155 (52 %), +4,429; block RAM 238 (70 %), 7 of them ours (receive ring 4, transmit buffer 1, link send
FIFO 1, link hold buffer 1); DSP 0; one transceiver quad; three long-wire clock lines. Slices 88 %.

**Full-chip builds** (4 receivers + zoom, place option 3, route option 1; reports in gowin/reports/p1_sfp_b1 to b3;
three starts before build 1 stopped at the constraints or at placement and are not counted):

| Build | Tree | Clocks | Failing end points | Lane clocks (Fmax, MHz) |
|---|---|---|---|---|
| 1 | a5547d8 + master (USB) | real | 27 setup (11 `sfp_txc`: MAC to coder in one clock; 16 `clk_dsp`), 0 hold | 105 / 148 / 135 |
| 2 | 031e9f9 | real | 3 setup + 5 hold on `clk_rx`, 1 hold (4 ps) on `clk_aud`; the tool had left the HL2 link's receive clock on ordinary wiring | 130 / 148 / 131 |
| 3 | 9ee2dff (master with the 80 MHz bus) | **5 % tighter** | **1 setup (-0.06 ns, `clk_dsp` at 126 MHz: FT8 write multiplexer to the write relay, not SFP logic), 0 hold** | 137.5 / 161.7 / 143.4 for 131.25 |

Build 3 per clock: `sfp_txc`, `n1_rxc`, `bl_rxc` met with the margin (tightest: negotiation state to the coder,
+0.35 ns); `clk_dsp` 125.04 MHz for 126 (the real 120 MHz is met by 0.33 ns); `clk_rx` 170, `clk_tx` 148.5,
`clk_pix` 162.2 for 156.2, AE350 bus 102.8 for 80, `ddr3_sys` 138.6, `clk_48m` 104.8, `clk_aud` 144.2: all met.
Long-wire lines in build 3: `clk_50m_d`, `rgmii_rxc_d`, `clk_48m`, `clk_pix`, `clk_tx`, `n1_rxc`, `bl_rxc`, `sfp_txc`
(all eight named in the .cst). On ordinary wiring: `clk_aud` (no hold failure in builds 1 and 3, one of 4 ps in
build 2) and both reset nets (`rst_dsp` had a long-wire line before). **No real-clock build of the final tree was
run** (the budget of three was used); the project's rule is that a build meeting the tightened clocks is clean, and
this one misses it by one end point outside the SFP logic.

**What the build flow needed** (section 2.4): `por_n_i` put on the generated wrapper; with it, place-and-route
demands the block's `CK_AHB_I` fed from its `FABRIC_CM_LIFE_CLK_O` (error PR1155) and the script does that too.
Replaced on 2026-10-21 by the IDE's default form (2.4); with `SFP_POR_FABRIC=1` GowinModGen feeds `CK_AHB_I` itself.

## 11. Left to do

1. The board checks of section 8.
2. `clk_aud` back on a global line: free a primary line (P1_TOP 11.3 steps 4 to 6).
3. The time server is the router; DHCP option 42 and a name lookup are not read. The MAC address is fixed.
4. Firmware for the board link beyond the driver: who is board 1 and board 2, what the control words mean, the
   switch of the receivers at run time; the transceiver start-up runs only inside the network object of `ft8fw`.
5. Packet memory holds one frame to send and 8 KB received: enough for time and control, small for remote audio.
6. SGMII at 10 and 100 Mbit/s is shown in the status and not carried.
7. `fw/tr-station` has no link use yet; `ft8fw_qemu` is unchanged.

## 12. Fixes from the board runs (2026-10-21, branch `sfpport`)

A copy of `rtl/sfp` and `rtl/n1` ran the network on this board in another build (50 of 50 pings answered at the end). Ported:

| Fix | Where |
|---|---|
| Byte enable from the PCS into the MAC: receive clocks without a word made the MAC take a byte twice | `sfp_pcs.v` `mac_rx_ce`, `gmii_mac_rx.v` `ce`, `sfp_net.v` |
| Timing of the full build: `link_up` registered, a register between PCS and coder (the idle's second symbol reads `enc_rd` live), the ring's full compare and the MAC's last-byte compare registered | `sfp_pcs.v`, `sfp_net.v`, `gmii_mac_tx.v` |
| A register in each FIFO enable of both lanes | `sfp_serdes.v` |
| The IDE's default reset form; Gowin's global form selectable; no hand patch | `gowin/p1/build.sh`, `serdes.toml`, `sfp_serdes.v` |
| Quad status and buffer flags in `serdes_status` 27:16, printed per lock attempt | build, `sfp_serdes.v`, `sfp_top.v`, regmap, firmware |
| Multiplexer select: N19 least significant | `sfp.rs` `channel::sel_bits` |
| Lanes out of reset while their PLLs lock; PCS resets held until then; five attempts | `sfp.rs` |
| Clock chip: PLL B set as PLL A; wait for SYS_INIT and LOL_A clear | `sfp.rs` |
| Both cages' modules identified and printed (vendor, part, revision, serial, kind, rate); console lines for the start-up, the line mode and the link | `sfp.rs`, `sfpnet.rs`, `ft8fw.rs` |

Not ported, and why:

| Item | Reason |
|---|---|
| Automatic choice of the network's cage, DCS on the receive clock | here lane 1 is the 2.5 Gbit/s board link and only lane 0 runs at 1.25 Gbit/s; the network stays on SFP0. An Ethernet module found only in SFP1 is reported as in the wrong cage |
| Transmit clock of lane 1 through a DCS from its own `tx_pcs_clkout` | lane 0 already writes its own buffer with its own clock. Lane 1's buffer is still written with lane 0's clock (the shared clock of section 1): the cause of the lost pings was the byte enable, not this. `TR_SFP_TXC_OWN=1` gives lane 1 its own clock, and lane 1's buffer flags (bits 26, 27) now show whether a word was ever skipped |
| Reading the module PHY over I2C (advertisement 1000 full only, host mode from HWCFG_MODE) | a feature of the other build's start-up, not a board fix; this firmware tries the other line mode every 3 s |
| I2C bus scan of all channels; the clock chip at 0x62 as well | diagnostics for the select-bit fault, which is fixed; the chip answered at 0x60 on the board |
