<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# USB audio in and out (branch `usb`)

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

The board as a class-compliant USB sound card on its "Custom USB" socket: the receiver's audio to a PC
(recording, digital-mode programs) and audio from a PC into the radio (speech and transmit-audio source,
monitor). Owner decision: docs/DECISIONS.md 2026-10-15 "speech input ... comes in over USB".

## 1. In short

| Question | Decision |
|---|---|
| Speed and class | **Full speed (12 Mbit/s), USB Audio Class 1.0.** Our own plain-Verilog device (`rtl/usb/`), not Gowin's encrypted SoftPHY and controller |
| Format | 48 kHz, 16-bit, stereo in both directions (192 bytes per 1 ms frame each way; full speed carries 1,023) |
| PC -> radio (playback) | isochronous OUT 0x01, **asynchronous with an explicit feedback endpoint** 0x81: the PC sends as many samples as the radio uses |
| Radio -> PC (capture) | isochronous IN 0x82, **asynchronous**: 47, 48 or 49 samples per frame, as many as the radio made |
| Slip handling | none needed in normal running, because the radio's 48 kHz is the master in both directions. If the PC does not follow: playback under-run = silence and a restart of the buffer, over-run = samples dropped; both counted, never a hang |
| Clock | the existing `clk_48m` (DSP PLL second output, already on global line 8). **No new clock line, no new PLL, no 480 MHz clock** |
| Where playback enters | (a) a 1,024-sample FIFO read by the CPU through the new register page `usb` (0xE80E_0000) with a high-water interrupt (line 12); (b) a monitor switch that adds it to the stream of the digital outputs; (c) a loop-back switch that sends it back to the PC. No transmit logic |
| Second function now | none. A USB serial console is cheap later (section 8) |

## 2. The device and what was changed

The device does not use Gowin's "USB 2.0 SoftPHY" and "USB 2.0 Device Controller"
IP. Both are encrypted (IPUG781 table 2-1: "Verilog (encrypted)"), so they cannot be simulated with
iverilog and cannot go into a public GPL repository; the PHY needs a 60 MHz clock and a 480 MHz I/O clock; and
only a scope on the board can test a high-speed PHY. The device is a **full-speed** design in plain Verilog
(about 1,400 lines: line interface at 48 MHz with 4 samples per bit, packet engine, control endpoint 0 with all
requests in hardware and the descriptors in a ROM, a dual-clock FIFO with packet commit and rewind) with a
bit-level host model as test bench. State before this work: simulated (13 tests pass); built into three chip variants with
timing met at 48 MHz once the clock was on a global line (67 hold failures with the 48 MHz
clock on ordinary wiring, none on a global line); **never run on a board**. It had a recording endpoint
(24-bit) and USB-MIDI; no playback.

Changes to the files in `rtl/usb/`:

| File | Change |
|---|---|
| `usb_fs_phy.v` | none |
| `usb_fs_core.v` | isochronous OUT added (`out_iso`: any data toggle, no handshake) |
| `usb_afifo.v` | synthesis attributes; the synchronised pointers get a binary register of their own (section 13) |
| `usb_ep0.v` | two streaming interfaces instead of one plus MIDI; no bulk endpoints to halt |
| `usb_ep_cap.v` (formerly `usb_ep_audio.v`) | 16-bit samples (4 bytes), source in `clk_dsp` |
| new `usb_ep_play.v`, `usb_play.v`, `usb_regs.v`, `usb_audio.v` | playback endpoint with feedback, playback path in `clk_dsp`, registers, top of the unit |

## 3. Class 1.0 at full speed, not class 2.0

- **What the port can do.** The socket has no PHY chip. D+ and D- reach pins T19 and U19 through 0 ohm, which
  is a full-speed transceiver made of two LVCMOS33 pins. High speed needs the six other pins, Gowin's encrypted
  PHY and two more clocks.
- **What we need.** 48 kHz 16-bit stereo each way is 1.5 Mbit/s each; full speed's isochronous packets take
  1,023 bytes a frame (USB 2.0 5.6.3). High speed gives nothing here. Latency is set by the 1 ms frame at
  either speed for class 1.0.
- **What a PC accepts without a driver.** Class 1.0 has a built-in driver in every Windows version, macOS and
  Linux. The Windows class 2.0 driver exists only from Windows 10 1703, and whether it accepts a full-speed
  device is not established. Class 2.0 would buy 96 kHz and 24 bits, which
  speech and digital modes do not need.
- **Cost of the choice.** None today. A later CDC serial port and MIDI are full-speed functions too.

## 4. The clock problem

The radio's 48 kHz is `clk_dsp` / 2,500 from the board's 50 MHz oscillator. The PC's 48 kHz is its own, and
its 1 ms frames are a third clock in effect. Somebody has to follow.

**The radio is the master in both directions.** That is the natural choice for a device with its own clock and
needs no sample-rate converter and no slip.

- **Capture, asynchronous IN** (USB 2.0 5.12.4.1.1). Samples go into a 128-sample
  dual-clock FIFO. At each start of frame the endpoint sends every complete sample waiting, 49 at most:
  usually 48, now and then 47 or 49. The PC's driver takes the rate from the data. A skipped frame is caught up
  by 49-sample packets. Latency about 1 ms. FIFO full (the PC stopped asking without closing the stream):
  samples dropped and counted.
- **Playback, asynchronous OUT with explicit feedback** (USB 2.0 5.12.4.2). Samples from the PC go into a
  256-sample dual-clock FIFO; the radio takes one per 48 kHz tick. At each start of frame the device computes
  how many samples per frame it wants, as a 10.14 fixed-point number in 3 bytes (USB 2.0 5.12.4.2: full-speed
  format), and the PC reads it from endpoint 0x81:

      wanted = 48.0 + (72 - fill at start of frame) / 64        limited to 48 -+ 63/64, i.e. 47.0156 .. 48.9844 (`err_c` in `rtl/usb/usb_ep_play.v` is clamped to -63 .. 63)

  A fill-level control: with the PC 100 ppm off, the fill settles 0.3 samples from 72. Time constant 64 ms. No
  rate measurement is needed and the loop cannot drift.
- **Adaptive (the device follows the PC)** was the alternative for both directions: it needs a blend-slip or a
  resampler in each direction (`audio_digital_out.v` has the slip: one sample in or out over 64 frames by
  linear blending). Not used, because with the radio as master nothing has to be slipped. `audio_digital_out.v` keeps
  doing that job for S/PDIF and I2S, whose clock is exact.

**The slip rule of this design** (what the test benches check): while the PC follows the feedback, every sample
in is one sample out, bit for bit, both directions. When it does not:

| Fault | What happens | Counted in |
|---|---|---|
| Playback FIFO empty at a tick | zeros go out; the reader stops and starts again when 96 samples wait | `play_underruns` |
| Playback FIFO full | the arriving sample is dropped | `play_overruns` |
| A playback packet with a bad CRC | the whole packet is dropped (an under-run may follow) | `play_bad_packets` |
| Capture FIFO full | the new sample is dropped | `cap_overruns` |
| CPU FIFO full | the new sample is dropped | `fifo_overruns` |

Nothing waits on the PC and nothing waits on the CPU.

## 5. Buffering and latency

| Path | Buffer | Latency |
|---|---|---|
| Capture | 128 samples, LUT RAM, written in `clk_dsp`, read in `clk_48m` | 1 to 2 ms |
| Playback | 256 samples, LUT RAM, written in `clk_48m`, read in `clk_dsp`; start at 96, control target 72 at start of frame | 2 ms typical. 72 is what keeps 24 samples in hand when one frame's packet comes at the start of its frame and the next one at the end |
| To the CPU | 1,024 samples of {right, left}, one block RAM pair, pop on read | the firmware's own polling; high-water interrupt at a mark the firmware sets |

## 6. Descriptors

One configuration, device class 0 (per interface), three interfaces of one audio function:

| Interface | Content | Endpoints |
|---|---|---|
| 0 AudioControl | header (collection: 1, 2); input terminal 1 "USB streaming" -> output terminal 2 "line connector" (to the radio); input terminal 3 "line connector" (from the radio) -> output terminal 4 "USB streaming". No volume unit: the PC's own mixer does volume | none |
| 1 AudioStreaming, playback | alt 0 off; alt 1: PCM, 2 channels, 2-byte samples, 16 bits, 48,000 Hz | 0x01 isochronous OUT asynchronous, 196 bytes; 0x81 isochronous IN feedback, 3 bytes |
| 2 AudioStreaming, capture | alt 0 off; alt 1: same format | 0x82 isochronous IN asynchronous, 196 bytes |

- Written once, in Rust (`fw/tr-usb/src/descriptors.rs`); the ROM of the RTL (`rtl/usb/usb_desc_rom.hex`,
  `usb_desc_params.vh`) is generated from it and a test fails when it is stale.
- Vendor/product 0x1209:0x0001 is the pid.codes **test** ID; a real one must be asked for before publishing.
  Strings "fpga-sdr", "fpga-sdr transceiver".
- **Room kept**: endpoint numbers 3 (MIDI bulk), 4 (CDC data bulk) and 5 (CDC notification) are free; the core
  handles 16. A second function means an interface association descriptor per function and device class
  0xEF/2/1; the audio function's own descriptors stay as they are. Windows remembers a device's layout per
  vendor/product/release number, so that change must raise `bcdDevice`.

## 7. Where the playback stream enters the radio

Voice transmit is on hold (owner), so this stops at an interface:

    PC -> endpoint 0x01 -> FIFO -> usb_play (clk_dsp): one {left, right} sample per 48 kHz tick of the radio,
                                    valid flag, zeros when nothing comes
            |-> CPU FIFO (1,024 samples), register usb.fifo_data, interrupt 12 at the high-water mark
            |-> monitor: added (saturating) to the stream that feeds HDMI, S/PDIF and I2S   (usb.ctrl.monitor)
            |-> loop-back: replaces the receiver audio towards the PC                      (usb.ctrl.loopback)

- The CPU path is what the task asked for first: today the TX baseband ring is written by the CPU, so speech
  goes PC -> CPU (codec or SSB modulator) -> TX ring. The firmware reads at 48 kHz stereo; 48,000 register reads
  a second are about 1 to 2 % of the CPU. A decimating filter to 8 or 12 kHz in logic is the later saving.
- The monitor reaches the digital outputs only. The headphone DAC (PT8211) has its own path from the audio
  ring inside the audio engine; mixing there means a change to the engine and is left out.
- The capture tap is taken before the monitor is added, so the PC never hears itself unless loop-back is on.
- Peak meters (largest magnitude since the last read) for both directions are in the register page.
- `usb.ctrl.speech_src` (added with the USB host, docs/USB_HOST.md section 5): 1 = the CPU FIFO takes the
  microphone of a headset on the USB host board instead of the PC's playback. Those samples come at the
  headset's own rate, not on the radio's tick.

## 8. A USB serial console: worth it later, not now

The first board is already operated over USB: the debug socket's BL616 chip is a USB-to-serial bridge on the
AE350's UART. A CDC serial port on the Custom USB socket saves the second cable, nothing else.

Cost if wanted: two bulk endpoints with small LUT-RAM byte FIFOs and an interrupt endpoint that always answers
"nothing" (about 400 LUTs, 350 registers, no block RAM, with the MIDI endpoint as the pattern);
three class requests in endpoint 0 (set/get line coding, set control line state: accept and ignore); about 66
descriptor bytes plus the association descriptors of section 6; a byte driver in `tr-fabric` and a second
console sink in the app. About a day of work, with the bench extended by the bulk tests. Windows 10 and later load their serial driver for it without an INF file.
Recommendation: build it with the first on-board USB test, not before.

## 9. Clocks and pins

- `clk_48m` = 1,200 MHz VCO / 25 of the DSP PLL: exactly 48 MHz, crystal accuracy (full speed asks +-0.25 %,
  USB 2.0 7.1.11). It exists (it feeds the audio PLL) and already sits on long-wire global line 8 with one
  load. **USB adds about 500 registers to that line (the half of the unit that runs on it) and asks for nothing new.** docs/P1_TOP.md 11.3 planned to
  move `clk_48m` to ordinary wiring to free its line for an SFP clock; that is no longer free of cost:
  46 to 67 hold failures were measured with exactly this core on ordinary wiring and none on a global
  line. The note in P1_TOP 11.3 says so.
- Everything between `clk_48m` and `clk_dsp` is a Gray-coded FIFO pointer, a two-register synchroniser or a
  toggle; the two clocks are declared asynchronous.
- Pins (bank 3.3 V; Sipeed `usb_ref.cst`, dock schematic PERIPHERALS):
  T19 D+ and U19 D- (LVCMOS33, bidirectional, 8 mA), M19 pull-up switch (1.5 kohm to D+). The six pins of the
  high-speed circuit (M21, M22, U21, V21, T20, U20) are inputs without pull.
- The pull-up is on after reset, so the board enumerates as soon as the bitstream runs, without firmware;
  `usb.ctrl.connect` takes it off the bus.

## 10. Manuals and sources used

USB 2.0: 5.6 (isochronous), 5.12.4 (synchronisation types, feedback), 7.1 (signalling), 8 (protocol), 9
(requests, descriptors). USB Audio 1.0: 4.3 to 4.6, Terminal Types, Data Formats. Gowin: UG306 (global clock
lines) and SUG1018 2.7 (`CLOCK_LOC`) through docs/P1_TOP.md 11.3; SUG550 (synthesis attributes
`syn_ramstyle`, `syn_srlstyle`, `syn_preserve`); UG285 (block RAM: no read-before-write on this chip, so the
CPU FIFO reads and writes different addresses or returns the new word); IPUG781 only to turn the SoftPHY down.
No DSP block and no PLL setting is changed.

## 11. Not verifiable without a PC on the socket

Enumeration and the names Windows, macOS and Linux give the two devices; that Windows' class 1.0 driver follows
the feedback endpoint (if it does not, the under-run and over-run counters move by about one event every few
seconds and the fix is an adaptive slip in `usb_play.v`); drive strength and edges of T19/U19 against the
full-speed limits; a one-hour recording and a one-hour playback with all five counters at 0.

## 12. What is built and how it was tested

| Part | Files |
|---|---|
| Logic | `rtl/usb/` (section 2), wired in `rtl/top/sdr_core.v` (page 0x0E, interrupt 12, the stream to the digital outputs) and `sdr_top.v` (two bidirectional pads) |
| Descriptors | `fw/tr-usb` -> `rtl/usb/usb_desc_rom.hex`, `usb_desc_params.vh` (183-byte configuration, 301 of 512 ROM bytes) |
| Registers | `hw/regmap/usb.toml` (10 registers), generated files |
| Constraints | `gowin/p1/sdr.cst` (9 pins), `sdr.sdc` (`clk_48m` and `clk_dsp` unrelated), `build.sh` file list |
| Firmware | `fw/tr-fabric/src/usb.rs`: state, FIFO reader (stereo and mono), switches, fault counters, peak meters, a status line; one status line at start in `fw/tr-app/src/bin/ft8fw.rs` |

`sim/usb/tb_usb_audio.v` (iverilog, 2.5 minutes; `iverilog -g2012 -o x.vvp sim/usb/tb_usb_audio.v && vvp x.vvp`):
a bit-level host model against the whole unit, the host 1,000 ppm slow, the radio's sample clock
5,000 ppm fast so that the feedback has work to do. All pass:

| Test | Result |
|---|---|
| Enumeration: descriptors byte for byte, address, STALLs, configuration | pass |
| Sampling-frequency requests on both endpoints; all three endpoints silent while switched off | pass |
| 160 frames both ways, the host sending what the feedback asks | every sample PC -> CPU FIFO once and in order (7,635 read); every radio sample at the PC once and in order, 48 or 49 a frame; feedback 48.234 against 48.240 true; buffer 56 to 58 at start of frame (theory: 72 - 0.24 x 64 = 56.6); no fault counted |
| Stream to the digital outputs | equal to the radio's stream while the monitor is off; radio + PC with it on (387 samples) |
| Loop-back | 579 samples back at the PC in order |
| High-water interrupt, peak meters | pass |
| PC stops sending | exactly one under-run; then 9,305 samples sent = 9,305 read |
| Bad CRC on a playback packet | dropped, counted once, reader runs on |
| PC sends twice too much | 220 samples dropped and counted, device goes on |
| PC stops fetching the recording | 188 dropped and counted; then 49-sample packets take the backlog down |
| Firmware stops reading | CPU FIFO full at 1,024, 134 dropped and counted, interrupt high, drains |
| Interfaces off, bus reset, pull-up off | pass |
| Longest device response | 3.32 bit times (limit 7.5) |

Also: `sim/top/tb_sdr_core.v` passes with the unit in (page 0x0E read and written through the AHB bridge);
`cargo test -p tr-usb` 8 tests, `cargo test -p tr-fabric usb` 6 tests; both crates and the firmware binary build
for the AE350.

Not simulated: a host faster than the device's bit clock, suspend and resume (ignored by the device),
corrupted tokens.

## 13. Cost

Stand-alone, Gowin V1.9.12.04, wrapper subtracted (`gowin/res.sh usb_audio --clk clk_dsp --clk2 clk_usb
--period-ns 7.917 --wrap --sdc gowin/wrap/usb_audio_ooc.sdc ...`; both clocks 5 % tighter than real):

| | LUT | Adder cells | Registers | LUT-RAM cells | Block RAM |
|---|---|---|---|---|---|
| whole unit | 1,909 | 396 | 1,223 | 192 | 3 |
| of it: packet engine + line interface | 511 | 14 | 213 | 0 | 0 |
| endpoint 0 | 283 | 62 | 169 | 0 | 1 (descriptor ROM) |
| capture endpoint with its FIFO | 223 | 61 | 153 | 64 | 0 |
| playback endpoint and FIFO | 383 | 60 | 204 | 128 | 0 |
| playback reader, monitor, CPU FIFO, meters | 334 | 113 | 250 | 0 | 2 |
| registers | 164 | 86 | 217 | 0 | 0 |

Gowin's "Logic" figure is 3,477 (2.5 % of the chip; a LUT-RAM cell counts 6). The two audio FIFOs are in LUT
RAM because block RAM is the scarcer resource in this chip; in block RAM they would be 2 blocks and about
1,300 "Logic" less. Timing alone: `clk_dsp` 126.5 MHz (needed 120), `clk_48m` 99.8 MHz (needed 48), no hold
failure. The first run failed 52 end points at 112.9 MHz in the read side of the playback FIFO
(Gray-to-binary, flush selection and LUT-RAM read in one clock); the synchronised pointers now have a binary
register of their own (`usb_afifo.v`).

## 14. What the firmware and the app must still do

Nothing is needed for the PC to see and use the sound card: recording works from the bitstream alone.

1. **Main loop** (not done: another work package has `tr-app` and `tr-station`): create
   `tr_fabric::usb::UsbAudio`, call `set_fifo(true, mark)` when a speech source is wanted, and read
   `read_mono()` each pass (or on interrupt line 12, `usb::IRQ_FIFO`). The FIFO holds 21 ms; a loop that can
   stall longer than that must read in the interrupt into its own ring.
2. **Speech path** (on hold with voice transmit): 48 kHz mono -> 8 kHz for FreeDV (`tr-station` already has
   the 12 k/8 k/48 k converters) or -> SSB modulator -> TX baseband ring.
3. **Console and screen**: `status_line()` once a second next to the audio status; a "USB" entry for the
   transmit-audio source and a monitor switch.
4. **Under-run policy**: on `play_run` false while transmitting from USB, send silence, never stale samples.
5. Later, in logic: a decimating filter to 12 or 8 kHz in front of the CPU FIFO (saves 3/4 or 5/6 of the
   register reads), and the monitor into the headphone path of the audio engine.

### Full-chip builds (target chip: 4 receivers and the zoom, commit c3ee9b4)

Gowin V1.9.12.04, place option 3, route option 1; reports in `gowin/reports/p1_usb/`. Failing end points per
clock (setup / hold) and the frequency reached:

| Clock | Needed MHz | Build 1, real clocks | Build 2, clk_dsp and clk_pix 5 % tighter |
|---|---|---|---|
| `clk_dsp` | 120 | 0 / 0, 121.95 | 0 / 0, 126.29 (constraint 126.0) |
| `clk_48m` (USB) | 48 | 0 / 0, 103.06 | 0 / 0, 99.27 |
| `clk_aud` | 49.152 | 0 / 0, 165.75 | 0 / 0, 181.28 |
| `clk_rx` | 125 | 0 / 0, 170.33 | 0 / 0, 170.33 |
| `clk_tx` | 125 | 0 / 0, 160.88 | 0 / 0, 142.00 |
| `clk_pix` | 148.75 | 0 / 0, 158.63 | 0 / 0, 167.13 (constraint 156.19) |
| AE350 bus clock | 100 | 0 / 0, 111.20 | 0 / 0, 107.85 |
| AE350 data-memory bus clock | 50 | 0 / 0, 111.06 | 0 / 0, 106.92 |
| DDR3 controller clock | 100 | 0 / 0, 162.38 | 0 / 0, 136.95 |
| all clocks | | **0 setup, 0 hold** | **0 setup, 0 hold** |

Chip fill with USB in (build 1): Logic 80,452 of 138,240 (59 %), registers 67,726 (49 %), CLS 86 %, block RAM
224 of 340 (66 %), DSP 127 of 298 (43 %), 131 of 312 pins. Clock lines: 8 of 8 primary and 8 of 8 long-wire in
use, as before: `clk_48m` is on its long-wire line (now with the USB logic on it); the two reset nets
`rst_dsp` and `u_mem/ddr_rst` still have the last two long-wire lines. No line was added or moved.
