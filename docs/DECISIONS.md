<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# Owner decisions

Decisions made by the owner (Franz Schöning). Do not reopen them; build on them.

## What the radio is

- A standalone HF transceiver. The Hermes-Lite 2 (HL2) is only the raw front end: it streams
  raw 12-bit ADC samples (76.8 Msps) over its gigabit Ethernet port and takes raw DAC samples back.
  Everything else happens on a Sipeed Tang Mega 138K Pro dock (Gowin GW5AST-LV138, hard
  RISC-V AE350 at 800 MHz, 1 GB DDR3). The board arrives around 2026-09-29.
- HL2 side: already done, public release `hl2-rawfront-release-v0.1` on
  github.com/Schoning-Labs/Hermes-Lite2 (docs in `docs/rawfront/`, wire format in `PROTOCOL.md`).
  Includes hardware TX safety interlocks and register access to all radio functions.
- Full RX and TX from the start. All modes, including all digital modes and WSPR, built in.
  No external software, no virtual audio cables.
- Standalone first: a monitor on the board's HDMI/DVI output. No PC needed to operate it.
- Receivers: 4 to 8 independent receivers plus one full-band (0 to 30 MHz) spectrum view with zoom.

## Hardware (FPGA)

- Language: Verilog. Reason: the radio code worth reusing (HL2/openHPSDR, KiwiSDR) is Verilog,
  and SpinalHDL/Amaranth add a generator layer without enough gain here.
- Do as much as possible in hardware: receivers (mixing, decimation), spectrum FFT, waterfall
  drawing, and compositing the waterfall/spectrum over the GUI.
- Red Pitaya designs are Xilinx-IP based and do not port; use them for ideas only.

## Software

- Pure Rust, bare metal (no operating system) on the AE350 hard core. No C or C++ anywhere,
  including no C GUI toolkits (GTK etc.) and no C DSP libraries (WDSP etc.).
- GUI: Slint (pure Rust, runs without an OS, software renderer). The FPGA draws spectrum and
  waterfall and overlays them on the Slint-rendered panel. The panel can be a simple image of a
  radio front panel with buttons and menus. MIDI controller support wanted later.
- Display: 1920x1080 output; the owner's 4K monitor scales it. Layout must also scale down to
  small LCD panels later (for example 1024x600 on the board's RGB interface).

## Protocols

- VITA-49 for data streams and full TCI server from the start. No Hermes/openHPSDR protocol.
- The board's only RJ45 port is used by the HL2. The home-network link uses an SFP module in an
  SFP+ cage (owner will buy one). Until then the radio runs standalone; TCI and spot uploads wait.

## Audio and input

- RX audio: the board's speaker and headphone outputs, and HDMI audio to the monitor.
- Mic and USB (mouse, keyboard, MIDI, USB audio stick) are deferred. Until then TX covers digital
  modes and CW; SSB voice TX waits for a mic input.

## Digital modes build order

After SSB, CW, AM, FM: FT8 and FT4, WSPR, CW decoder, RTTY and PSK31, SSTV, JS8, FreeDV last
(its voice codec must be rewritten in Rust).

## Filter board

- N2ADR filter board on the HL2. Show the filter curves visually over the spectrum so the operator
  can see which filter to use. Calculate the curves from the board's published part values first;
  check them against measurements later.

## Testing before the board arrives

- Simulation with generated test signals of known frequency and level.
- Real captures from the HL2 (owner will connect an antenna this week).

## Repository

- New repository `fpga-sdr`, public, GPL-3.0-or-later (changed to Apache-2.0 for the public release; docs/learn/LICENSES.md).
- Commits as `fschoning`.

## 2026-09-27: FT8 first; time from the network
- A working FT8 transceiver comes before every other mode and interface.
- UTC for FT8 comes from the network: SNTP over the SFP link. The owner will have a cheap
  1000BASE-T copper SFP module (Cisco GLC-T compatible) by the time the board arrives.

## 2026-10-12: lessons learned; Gowin version; bus clock

- Apply the findings in docs/TANG_LESSONS.md: 1 GB DDR3 for the AE350 (256 MB build kept as
  fall-back), audio outputs (PT8211, HDMI audio, S/PDIF, I2S), fan-out and block-RAM practice.
- USB audio stays deferred (unchanged).
- Move to Gowin V1.9.12.04 with the owner's own licence, after the running jobs are merged (work package LS9).
- The AE350 bus clock stays at 100 MHz; close the timing rather than drop to 50 MHz.


## 2026-10-12 (later): zoom stays in; no permanent decoder fall-back

- The zoom receiver stays in the chip (parameter ZOOM = 1). Spare logic is traded for block RAM
  to get back under 75 %; the zoom gets narrower spans so the FT8 screen can use it.
- The firmware never gives up on the chip's FT8 front end: a bad slot is decoded in software for
  that slot only and the chip is tried again in the next slot.

## 2026-10-12 (evening): FreeDV moves up

- FreeDV is the next mode after FT8 (it was last). New mode order: FT8, then FreeDV, then the
  rest as before (FT4, WSPR, CW decode, RTTY/PSK31, SSTV, JS8). This replaces the 2026-09-25 order
  for FreeDV only.
- FreeDV receive needs only the audio outputs; FreeDV transmit needs a microphone input, which is
  still deferred (owner to decide how audio gets in).

## 2026-10-12 (night): main clock 120 MHz, was 150

- `clk_dsp` is 120 MHz (DSP PLL: VCO 1,200 MHz / 10). Owner's decision after docs/CLOCK_STUDY.md found that no
  block needs 150 MHz: the tightest are the back end's channel filter unit (99.8 MHz) and, as built, the zoom
  half-band filter at the widest span (122.9 MHz). 120 MHz is the one lower frequency where only the PLL divider
  changes: the 48 MHz audio feed (/ 25) is untouched, the 48 kHz sample is exactly 2,500 clocks, a microsecond is
  exactly 120 clocks. Every path gets 1.67 ns more (period 8.33 ns); the margin rule's constraint is 7.92 ns.
- Cost: FT8 decodes arrive about 0.2 s later after the slot (0.93 s instead of 0.74 s with 8 receivers, lane
  and video share not measured); the back end's channel filter unit runs at 83 % of capacity (was 67 %).
  Headphone bit clock jitter 8.3 ns instead of 6.7 ns. The TX rate lock takes 26 ms to lock instead of 20 ms.
- One RTL change: the zoom half-band filter (`rtl/zoom/zoom_fir_half.v`) has two multipliers per channel
  (+2 DSP blocks) and makes an output in 16 clocks instead of 32; its delay line is 4 block RAMs instead of 2
  (+2 BSRAM) because two folded taps need four reads a clock. Bit-exact with the one-multiplier form
  (`sim/zoom/tb_zoom_fir_half.v`, against the parallel reference).
- Everything that states the clock follows: PLL, constraints (`gowin/p1/sdr.sdc`, `gowin/ladder/ladder.sdc`,
  `rx_backend.sdc` two-clock limit 16.3 ns, stand-alone default 8.333 ns), audio engine, 48 kHz filler,
  firmware cycle counter (120 per microsecond), register descriptions, ladder test.

## 2026-10-13: 4 receivers and the zoom is the target chip; 8 receivers is a build variant

- Owner: "Do 4 receivers and zoom." The chip cannot hold 8 receivers plus the zoom receiver. The target
  chip has 4 receivers (the 4 of "4 to 8 independent receivers" above) with the zoom receiver.
- The number of receivers is one build setting, `NRX` (1 to 8), carried through the RTL; the build define is
  `TR_NRX` in `gowin/p1/build.sh` (unset = 4). The 8-receiver chip without the zoom (it routes and meets timing
  at 120 MHz) stays buildable as `TR_NRX=8 TR_NO_ZOOM=1`.
- The register map keeps the 8-receiver layout, so no address moves. Receivers at or above the built count
  read 0 and ignore writes. The chip reports its count in `system.status.num_rx` (bits 19:16, read-only; 0 =
  an older bitstream, read as 8). One firmware image runs on both variants: it reads the count at start
  (`tr_fabric::system::System::num_rx`) and sizes its loops with it.
- Measured (synthesis only, `TR_NO_ZOOM=1`, whole chip, NRX 8 -> 4): LUT 47,666 -> 41,533, adder cells 19,038 -> 15,386,
  registers 71,358 -> 60,168, block RAM 217 -> 172, DSP 118 -> 94. The second channel-filter unit (receivers 4-7) goes
  away at NRX <= 4.

## 2026-10-14: Gowin V1.9.12.04 only

- All builds use Gowin EDA V1.9.12.04 with the owner's own licence (C:/Gowin/Gowin_V1.9.12.04_x64/IDE).
  V1.9.11.03 is not used any more. (Approved on 2026-10-12; carried out late.)

## 2026-10-15: FT8 waterfall, FreeDV now, speech input

- The FT8 screen's default waterfall is the chip's zoom waterfall (fine in frequency, a line every
  0.55 s); the software waterfall remains the fall-back.
- FreeDV receive starts now (pure `no_std` Rust port of codec2 700C and the FreeDV modems).
- Speech input for voice and FreeDV transmit comes in over USB and over an Ethernet remote link
  (not an audio-input module on the PMOD). This reopens USB for audio; both are still to be
  designed. Voice transmit and real on-air transmit stay on hold until the owner says.

## 2026-10-15: USB audio in and out is built

- Owner: "add these missing features first ... Do we have usb audio in/out?" It is built (branch `usb`,
  docs/USB_AUDIO.md): the board is a class-compliant USB sound card on its "Custom USB" socket, 48 kHz 16-bit
  stereo, radio to PC (the receiver audio) and PC to radio (speech and transmit-audio source, monitor).
  **USB is no longer deferred for audio.** This socket cannot be a host (docs/BOARD.md); USB keyboard,
  mouse and headsets are the next entry (a host on a Pmod board).
- Full speed, USB Audio Class 1.0, in our own plain Verilog, not Gowin's encrypted
  high-speed PHY and controller. The radio's 48 kHz is the clock master in both directions: recording is
  asynchronous, playback is asynchronous with a feedback endpoint. No new clock: the existing 48 MHz.
- The PC's playback reaches the CPU through a 1,024-sample FIFO on register page 0xE80E_0000 with interrupt
  line 12. That is the interface the voice and FreeDV transmit paths will read. **No transmit logic was added;
  voice transmit stays on hold.**
- Not yet tried on a PC. A USB serial console on the same socket is possible later (docs/USB_AUDIO.md
  section 8); not built.

## 2026-10-16: USB host through a Pmod board

- USB host (headset or sound card without a PC, mouse, keyboard) is done in the FPGA itself on a
  passive Pmod board, not with a Pico: Muse Lab "PMOD-USBHOST" v1.0 (schematic in
  docs/ref/pmod-usbhost-v1.0.pdf, from github.com/wuxx/icesugar). 2x6 Pmod plug; USB1 D-/D+ on
  header pins 2/11, USB2 D-/D+ on pins 1/12 (the drawing numbers 1-6 down one row and 12-7 down
  the other); GND pair 5/8, 3.3 V pair 6/7; 5 V for the devices from an ME2188A50 boost
  converter; no pull-down or series resistors on the board (the FPGA pins provide the host's
  pull-downs). Full/low speed. The "Custom USB" socket stays the PC-facing audio device.
- It goes on an end Pmod socket (the board is wider than one socket).

## 2026-10-16: USB host is built (not yet on a board)

- Branch `usbh`, docs/USB_HOST.md: two host ports in logic (`rtl/usbh`, full and low speed, on the existing
  48 MHz clock), register page 0xE80F_0000, interrupt line 13, the host stack in Rust (`fw/tr-usbh`).
- The Pmod board goes on PMOD0 = J22 (pins L22, N17, N18, M26); `TR_USBH_PMOD=1` builds for PMOD1. The pins'
  own pull-downs are the host's; no external part.
- The headset's microphone feeds the same speech FIFO as the PC's playback (`usb.ctrl.speech_src`). **No
  transmit logic was added; voice transmit stays on hold.**
- Hubs, class 2.0 audio and speakers that only do 44.1 kHz are not supported.

## 2026-10-13: AE350 bus clock (AHB and APB) 80 MHz instead of 100

- The AE350's AHB and APB clocks are 80 MHz (the same 800 MHz VCO, output divider 10 instead of 8 on the two outputs
  `odiv2_sel`, `odiv3_sel` of `gowin/p1/ip/gowin_pll_ae350.mod`). Core 800 MHz, the DDR-bus clock 50 MHz and the RTC
  10 MHz are unchanged. 75 MHz is not possible from this PLL. This replaces "the AE350 bus clock stays at 100 MHz"
  of 2026-10-12.
- Why: Gowin's own encrypted SPI flash controller inside the AE350 reached 91.7, 99, 106, 108 and 109 MHz in different
  layouts of the same design: it passes 100 MHz in some and fails it in others.
  80 MHz keeps clear of that spread (docs/ROUTE_CAUSE.md, docs/TANG_LESSONS.md section 5).
- Cost: the AHB part of a CPU access to a fabric register is a quarter slower (a bus clock is 12.5 ns instead of
  10 ns; about 8 of them per access). The rest of the access is counted in clk_dsp clocks (about 17 of them, 145 ns)
  and does not change, so a whole access to a clk_dsp page goes from about 225 ns to about 245 ns (9 % longer).
  Instruction fetch from the flash (in-place start-up code) is slower in the bus ratio; the flash clock is the bus
  clock divided by 2 (40 MHz now).
- Changed with it: both constraint files (`ae350_ahb_clk`, `ae350_apb_clk`: `-multiply_by 8 -divide_by 5`), the UART
  input clock and machine-timer rate constants (`tr-ae350` board constants, now 80 MHz; both NOT VERIFIED until the
  ladder program has run on the board), the ladder start-up program (80 MHz is the first UART-clock guess, the old
  100 MHz the second), the register-bus testbench clock, and the documents. The register bridge needed no change: it
  is a toggle handshake with synchronisers and every wait is counted in the clock of the side that waits.

## 2026-10-17: the two SFP+ links are merged with the USB host (branch `final`)

- The board link's interrupt is **line 14**. Line 13 stays the USB host's (both had claimed it). Line 15 is spare. Moved in
  `rtl/top/sdr_core.v`, `sim/top/tb_sdr_core.v`, `docs/ARCHITECTURE.md` 4.3, `docs/SFP_LINKS.md`, `docs/P1_TOP.md`.
  The board-link driver in `tr-fabric` never named the line, so no firmware changed. (Default taken by the merge, not asked.)
- Pages: network socket 0xE80A, board link 0xE80B, USB audio 0xE80E, USB host 0xE80F; no overlap. Pads: the USB host's
  Pmod pins (L22, N17, N18, M26) and the SFP and I2C pins (R18, M20, V18, W18, K25, K26, N19, P19, P26) are all different.

## 2026-10-20: DDR3 memory clock 300 MHz instead of 400 (branch `ddr300`)

- The DDR3 memory clock is 300 MHz: PLL VCO 1,200 MHz, MDIV 24, memory-clock output ODIV 4, IP clock output ODIV 24 (50 MHz), PLL still at
  PLL_L[0]; `gwmc_param.v` tCK 3333 ps, CL 5, CWL 5, ratio 1:4 (controller clock `ddr3_sys` 75 MHz); both sdc files `ddr3_memory_clk -multiply_by 6`.
  Pin drives unchanged (Sipeed's: 12; CKE 4; CK and DQS 8).
- Why: measured on this board, at 400 MHz reads with two or more in flight are lost or corrupted when much on-chip logic switches, and the
  processor then waits for ever on a read. 300 MHz passed 7 of 7 cases.
- Cost: the lanes' ceiling is 64 bit x 75 MHz = 600 MB/s (was 800). Video needs 374 MB/s steady, up to 519 MB/s for the compositor: it fits with less
  room. The FT8 sync search reads what video leaves: about 80 MB/s instead of 250, so about 3 times slower (1.3 s instead of 0.42 s for 8 receivers).
  The measured 839 MB/s read-lane figure in MEM_1GB.md was at 100 MHz and no longer holds. NOT re-measured.
- Nothing in the radio logic counts DDR3 controller clocks in absolute time: only comments named 100 MHz (changed).
- Build results (V1.9.12.04): margin build (5 %): routing ended with 1 unrouted net (PR0004), no bitstream and no timing report. Plain build (real clocks):
  routes, 320 failing setup end points, 0 hold (clk_dsp 205 at 111.96 MHz for 120, clk_tx 64, clk_pix 26, clk_rx 14, n1_rxc 8, sfp_txc 3). The DDR3 clocks pass
  (`ddr3_sys` 116 MHz for 75). Master (a9ff4b0) had 0 failing at real clocks, so this placement is worse; the radio's own timing problem is open, no feature cut.
- Board test (one 4-minute run, 2026-10-20, board loader tool with board.lock held): the plain build loaded into SRAM (status 0x00026230, user code
  0x00006B6B). UART silent at 184,320, 115,200, 230,400 and 57,600 baud: the flash holds no fpga-sdr program (tr-ladder or stage-0 was never written; the flash is
  not to be written here), so the test shows only that the bitstream loads. DDR3 calibration (LED 4) and the freeze fix are NOT VERIFIED on the radio.
- Provenance: the settings are recorded in the header of `hw/gowin/mem/gwmc_param.v` (there is no separate PROVENANCE file).

### 2026-10-20 (later): the radio's processor does not start on the board
- Loaded into SRAM with the board loader tool and listened on COM14 from before the load (115,200 and 184,320 baud; 184,320 is the stage-0 loader's
  115,200 at the 80 MHz APB clock): silent for the 300 MHz plain build, for the old 400 MHz keeper `full_e0287a3`, and for a third build (below). So the
  fault is not the 300 MHz change. The AE350 is released only after `ddr3_init` (rtl/top/sdr_top.v), so a DDR3 that does not calibrate gives exactly this.
- Found while looking: `gowin/p1/sdr.cst` had drive 8 on every DDR3 pin (Sipeed's values are 12; CKE 4; CK and DQS 8), against the standing rule. Fixed.
  Also commit 14d5da6 fed the DDR3 IP's reference from the oscillator net; this never ran on a board; the PLL copy is the one known to calibrate. Reverted
  (clk_aud back on a local line).
- Third build (both fixes, plain, real clocks, `gowin/impl_plain3`): routes; 3,682 failing setup and 105 failing hold end points (`clk_dsp` 552, `clk_rx` 22,
  `n1_rxc` 19, `sfp_txc` 4, `clk_pix` 1; hold 102 on `clk_aud`, the DDR3 reference crossing). Still silent on the UART after loading.
- NOT VERIFIED: whether DDR3 calibrates (LED 0 is `ddr3_init`; the webcam sees the dock LCD, not the LEDs). Next: someone must read LED 0, or a build that
  shows `ddr3_init` on something the PC can see.

## 2026-10-21: cabling changed: RJ45 is the home network, the Hermes-Lite 2 moves to SFP (owner)
- Earlier plan (2026-10-17 and the first answer of 2026-10-21): RJ45 to the HL2, SFP0 to the PC, SFP1 board to board. **Replaced by:**
  - the board's RJ45 socket (RTL8211F, RGMII) is the home-network port for every project: radio control, GUI, TCI, and the flash loader (one
    generic loader for all projects loads the program over this port; the UART stays as a fall-back; the loader and the
    register page of the network unit are designed elsewhere and their interface is supplied to this project; no flash write without the owner's OK);
  - the Hermes-Lite 2 is on an SFP cage with a 1000BASE-T copper module (10Gtek "1.25G SFP-T", Marvell 88E1111, 1000BASE-X mode): **put the module in
    cage SFP0** (quad 1 lane 0, 1.25 Gbit/s Ethernet lane); the board-to-board link stays on SFP1 (lane 1, 2.5 Gbit/s);
  - every radio bitstream keeps the RJ45 network unit, same pins and same register page.
- Requirement (owner): **100 % of the HL2 raw sample data arrives.** Proof: a long run against the real HL2 stream counting every packet by its
  sequence number, zero loss; the chip keeps a loss counter readable by the firmware.
- Open until the interface is supplied: the network unit's page layout and the loader's image header and PC protocol.

## 2026-10-21 (later): the RJ45 network unit follows the proven version; board identity from the chip ID (branch `netid`; details docs/NET_ID.md)
- Owner instruction. Taken from the proven version: the PHY start-up that waits 100 ms and repeats from the reset with
  doubling waits (the RTL8211F read all ones at 35 ms, answered at 70 ms), a search over all MDIO addresses, the chip ID reader and its registers.
  `eth_top.v` (with the TXC fix) was already identical; `eth_xck.v` is for 75 MHz builds and not needed.
- **The network page is 0xE924_0000** (fixed for the generic loader), no longer 0xE811_0000. Status final.
  The layout changes only with an entry here.
- **Board identity:** chip ID = Gowin OTP DNA, bits 95:32 (SUG283-3.6.1E 8.9), registers 0x98/0x9C in every radio bitstream and a field on the minimal HL2
  build's UART line. MAC = 02 + 40 bits of a hash of the ID, name `tang-<last 3 MAC bytes>.local`;
  a stored address wins (no store in this firmware yet). This board: ID 0123456789abcdef, MAC 02:32:f8:2f:e5:cf, tang-2fe5cf.local.
- Not done: an mDNS responder (the name is only derived and printed); the loader's image header and PC protocol (still to be supplied).

### 2026-10-21 (evening): full build of the merged radio (HL2 on SFP0, RJ45 unit, board ID, DDR3 and atomics fixes)
- Merge 9810d14 + netid (b771e1e), plain build at real clocks, V1.9.12.04, 5,532 s: routes, bitstream `gowin/impl_plain8/sdr_top/impl/pnr/sdr_top.fs`
  (not in git). Verdict: 634 failing setup end points and 3 failing hold end points over all clock pairs; every per-clock row reads 0 open, so the 634 sit in pairs the
  tool's table does not list (not analysed). Fmax: `clk_dsp` 106.6 MHz (120 asked), `sfp_txc` 125.7, `n1_rxc` 127.6, `clk_eth` 116.6, `clk_pix` 148.8.
  Worst hold -2.35 ns: DDR3 IP init reset `ddr3_sys` -> the DDR3 PLL's 50 MHz reference (`u_pll_ddr3/PLL_inst/CLKOUT0`), the reference crossing of the PLL copy.
- Two earlier attempts stopped at the constraint file ("Can't find object named clk_eth"): the net is inside the core and not at the top of the netlist. The fixed
  clock line for it was removed; the tool places it.
- Not run on a board (the debug cable froze at 14:14 during an image send; owner away).

## 2026-10-21 (night): the radio runs on the board for the first time
- Bitstream of the merged build with the AE350 PLL at PLL_R[0] (`gowin/impl_plain9`, build 3,574 s: 2,493 failing setup, 3 failing hold end points, not analysed).
  LED 1 (`USR_LED.1`, DDR3 ready) lit, processor started, the flash loader answered. Loaded with the board loader tool `board.py`, which is not part of this repository (SRAM only, no flash write):
  its 42 KB network loader over the cable, the 2 MB radio firmware over UDP on the RJ45 (3.3 s, all checksums good, 100 Mbit/s full duplex, DHCP 192.168.2.160,
  name tang-2fe5cf, board ID 0123456789abcdef).
- Two firmware faults found by it and fixed: the UART base of `tr-ae350` was 0xF030_0000 (the first byte never left, the firmware hung before its first line;
  now 0xF030_0020) and the console speaks 184,320 baud like the flash loader. The first line is then
  `chip id 0x54520001 ... register bus ok, DDR3 up, PLLs locked`, `receivers in the chip: 4`, USB audio and USB host present.
- Seen in the first minutes: RJ45 link up 100 Mbit/s full; **sfp0 (HL2) link up, 1000BASE-X** (the module is in cage SFP0); HDMI frames counted but
  `underrun true` on every report; the software decoder gets 0 samples (the HL2 session is not streaming yet: nothing in the console about it);
  the chip FT8 search "never finished". All open.

## 2026-10-21 (late): the PC controls the radio's own screen over the home network (branch `netinput`; docs/NETINPUT.md)
- Owner: "I just need to be able to control the radio from the PC until I can get a USB port adapter. Everything stays on the radio HDMI GUI." No screen streaming.
  A PC program sends mouse and keyboard events by UDP (port 21600) to the RJ45 unit; the firmware feeds them into the path of the USB host's mouse and keyboard.
- Binding: input only. The network never enables transmit: keys `t c s u 0-9 - + =` are dropped, and the screen's transmit events are dropped for 1 s after any
  button or key from the network. The HL2 is never keyed by this work.

## 2026-10-22: HDMI at 1920x1080 and 30 Hz (CEA mode 34) instead of 60 Hz
- On the board the radio's 1080p60 output gave a black picture (monitor sees a signal; colour bars of the compositor black too). A minimal test design
  (branch `hdmitest`, a separate test design that is not part of this repository) at the same pins: 720p60 shows the picture, 1080p30 shows the picture, **1080p60 stays black** in both clocking forms
  (the radio's second-PLL-output form and the manual's divided-clock form). So 1080p60 (1.4875 Gbit/s per lane) does not work on these emulated-differential
  pins; 1080p30 has the 720p60 bit rate (742.5 Mbit/s).
- The radio now runs 1080p30: video PLL VCO 1,112.5 MHz, `clk_pix5` 370.83 MHz, `clk_pix` 74.17 MHz (-0.11 %), `VIDEO_ID_CODE` 34, 30 Hz refresh. The 2200x1125
  totals and the 1920x1080 layout are unchanged. The compositor's memory reads halve, which may also clear the underruns seen at 60 Hz.
- Cost: 30 pictures a second; the pointer and the waterfall move at 30 Hz at most. 1080i60 was considered: same bit rate, needs field logic and flickers on thin lines.

## 2026-11-05 Timing: the DDR3 reset paths were a constraint gap
- The 1,780 setup and 3 hold failing end points of the 1080p30 build were the DDR3 IP's own reset paths. The PLL's 50 MHz output (`u_pll_ddr3/PLL_inst/CLKOUT0`) had no clock name in the 1 GB build, so the tool timed its resets into `ddr3_sys` and `ddr3_memory_clk` as synchronous.
- Fix: `ddr3_ref` declared on CLKOUT0 and put in its own asynchronous group against `ddr3_sys`, `ddr3_memory_clk`, `clk_50m`, `ae350_ddr_clk` and `clk_dsp` (`gowin/p1/sdr.sdc`). No false-path commands.
- Results (full builds, 56 to 70 minutes each): 1,357 setup + 3 hold, then 101 setup + 1 hold (`ddr3_ref` was grouped with the memory clock), then **0 setup, 0 hold**; every clock meets its constraint.
- The timing-clean bitstream is in `impl/keep/radio_20261105_timingclean/`. It has **not** run on the board: the board was lent out on 2026-11-05. The active radio bitstream in `impl/keep/radio_20261021/` is unchanged until it has been tested.

## 2026-11-12 (owner): no usage limits

There is no cap on logic cells, block RAM, DSP, LUT RAM or any other chip resource: use up to 100 %. This replaces every earlier 70 %, 75 %, 80 % or 85 % limit in this file and in the lessons files. A feature is never skipped, shrunk or postponed because of a percentage. The only test is whether the build closes timing and works on the board. Earlier figures stay as measured facts, not limits.

## 2026-11-19: placement option 2 is the default, because the design has almost no margin at 120 MHz

After the project was renamed (module and file names only, no logic change) the same design placed differently and the default build (place option 1) ended with 161 failing setup end points on `clk_dsp` at 116.6 MHz. Place option 3 gave 245 failures at 114.7 MHz. Place option 2 closed timing with 0 setup and 0 hold failures, and `clk_dsp` reaches 120.013 MHz against the 120 MHz requirement. `gowin/p1/build.sh` therefore defaults to `GOWIN_PLACE_OPT=2`. That is a margin of 0.013 MHz, so any small change to the design can move the result again, and a build that fails by a few hundred end points after an unrelated edit should be tried with the other place options before anybody cuts logic. The cure that would last is a real margin on the `clk_dsp` paths. None of these bitstreams has run on the board.
