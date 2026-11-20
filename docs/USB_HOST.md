<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# USB host on a Pmod board (branch `usbh`)

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

A USB headset or simple sound card, a mouse and a keyboard plugged into the radio, no PC. Owner decision:
docs/DECISIONS.md 2026-10-16 "USB host through a Pmod board": the passive Muse Lab PMOD-USBHOST v1.0
(docs/ref/pmod-usbhost-v1.0.pdf), the FPGA does the host work. The "Custom USB" socket stays the PC-facing
sound card (docs/USB_AUDIO.md); this note only says what is different for the host.

## 1. In short

| Question | Decision |
|---|---|
| Speeds | full speed (12 Mbit/s) and low speed (1.5 Mbit/s), chosen per port by the firmware from which line the device pulls up. No high speed, no hubs |
| Ports | two, each with its own line interface and transaction engine, so a headset and a mouse or keyboard work at once |
| Logic / CPU | logic: bit timing, start of frame or keep-alive every 1 ms, one transaction with its time-outs and three tries, NAK retry, two interrupt-IN polls per port, isochronous OUT and IN straight to the audio paths, "device gone" detection. CPU (Rust): connect debounce, reset, enumeration, descriptors, class drivers (section 2) |
| Pull-downs | the FPGA pins' own, `PULL_MODE=DOWN PULL_STRENGTH=MEDIUM`. No external resistor is needed to work; the value is weaker than the 15 kohm of the standard (section 3) |
| Socket | **PMOD0 = J22**, dock pins 9 to 12 (balls L22, N17, N18, M26); PMOD1 = J24 as a build choice. Which of a port's two pins is D+ depends on which way up the board sits, so the registers have a swap bit and the firmware finds it out (section 4) |
| Clock | the existing `clk_48m`. Frames are 48,000 of its clocks; the radio's 48 kHz comes from the same PLL, so the radio makes **exactly 48 samples per frame** |
| Speaker | the stream the digital outputs get (`aud48_*`), 48 samples a frame; mono and 3-byte samples by a format setting |
| Microphone | taken as it comes, at the device's own rate, into the **same CPU FIFO** the PC's playback uses (`usb.ctrl.speech_src`); the firmware's resampler brings it to the radio's rate. No slip block in logic (section 5) |
| Mouse, keyboard | boot keyboard; mouse by its report descriptor (wheel), boot protocol as fall-back; events go into Slint as pointer and key events; the pointer is a Slint element drawn by the firmware (section 6) |
| Not supported | class 2.0 audio and high-speed-only devices (reported), hubs, speakers that only do 44.1 kHz, devices that need more than the board's boost converter gives |

## 2. Logic and CPU

The rule: everything with a deadline shorter than the firmware's main loop is logic; everything that happens
once per plug-in, or that needs a table, is Rust.

**Logic (`rtl/usbh`, all on `clk_48m` except the register page and the audio ends):**

- `usbh_phy.v`: `rtl/usb/usb_fs_phy.v` with a speed input. NRZI, bit stuffing, SYNC and EOP, the receive clock
  recovery (the phase counter that restarts on every edge) are the device's; a bit is 4 clocks at full speed and
  32 at low speed, and low speed swaps the meaning of the two lines (idle = D- high). New: a bare EOP (the
  low-speed keep-alive), forced SE0 (reset) and forced K (resume).
- `usbh_port.v`: one port. A 48,000-clock frame counter; at 0 a SOF token (full speed) or a keep-alive (low
  speed). Then, in this order, when due: isochronous OUT, isochronous IN, interrupt slot 0, slot 1, the CPU's
  transaction. Nothing starts in the last 1/6 of a frame, so the next SOF is never late.
  One transaction = token, data, handshake, with CRC5/CRC16 made and checked (the functions of
  `usb_fs_core.v`). No answer within 24 bit times, a bad CRC or a bad PID: tried again, three times in all, then
  reported. NAK: tried again in the next frame, up to a frame count the firmware gives. A repeated data packet
  (wrong toggle) is acknowledged and dropped.
- The CPU's transaction (the "queue" is one deep per port; control transfers are slow and the firmware sends the
  next stage when one is done): kind (SETUP, OUT, IN), endpoint, toggle, length, 64 bytes of send buffer in the
  register page. Result code and, for IN, the data as a record in the port's receive FIFO.
- Two interrupt-IN slots per port (endpoint, interval in ms). The toggle is kept in logic. Each report that
  arrives is a record in the same receive FIFO (1,024 bytes, one block RAM per port), so a key press is not lost
  when the firmware is busy for a while: a device only sends when something changed.
- `usbh_iso_out.v`, `usbh_iso_in.v`: the audio ends, one each, switched to either port (section 5).
- "Device gone": both lines low for 85 us while the port runs and nobody drives. The port stops by itself
  (no token goes to an empty socket) and tells the firmware.
- Suspend is "no SOF" (mode 3); resume is forced K for 20 ms timed by the firmware, ended by logic with a
  low-speed EOP. A device asking to be woken shows as K in the line status.

**CPU (`fw/tr-usbh`, `no_std`, no allocation; `fw/tr-fabric/src/usbh.rs` is the register driver):**

- Per port a state machine driven from the main loop with the time in ms: line stable for 100 ms, SE0 for 50 ms,
  10 ms recovery, first 8 bytes of the device descriptor, address, descriptors, configuration.
- Descriptor parser, class 1.0 audio driver (format choice, alternate settings, sampling-frequency request,
  un-mute), HID driver (boot keyboard, report-descriptor mouse), the US and German key tables, the microphone
  resampler.
- Enumeration at one speed failing three times with the swap bit one way is tried the other way: a board the
  other way up looks like a full-speed device on a low-speed pull-up.

Not in logic on purpose: reset timing (50 ms, nothing gained), descriptor parsing, the data toggles of control
transfers (the firmware knows the stage).

## 3. The electrical side with nothing but FPGA pins

The board has no pull-down, series resistor or ESD part (schematic). Per port the FPGA has two LVCMOS33
bidirectional pins.

**Pull-downs.** The standard wants 15 kohm +-5 % from each line to ground at the host (USB 2.0 7.1.5; the 2003
resistor ECN allows 14.25 to 24.8 kohm), against the device's 1.5 kohm pull-up to 3.0 to 3.6 V. Gowin gives
the pin's pull-down as a **current, maximum only** (DS1239-1.0.3E table 3-8, GW5AST-138, V_in between
V_IL(max) and VCCIO): strong 400 uA, medium 150 uA, weak 50 uA. No minimum and no resistance is given
(UG304-1.3.8E 3.5.4 and 3.5.11 only name the settings `PULL_MODE`, `PULL_STRENGTH`).

| Setting | Largest pull-down current | Equal to at 3.3 V | Idle level of the pulled-up line, worst case | Against the standard |
|---|---|---|---|---|
| strong | 400 uA | 8.3 kohm or more | 3.3 V - 1.5 kohm x 400 uA = 2.7 V | may be stronger than 14.25 kohm; idle level at the 2.7 V limit (7.1.5) |
| **medium** | 150 uA | 22 kohm or more | 3.08 V | inside the ECN range if near its maximum, weaker otherwise |
| weak | 50 uA | 66 kohm or more | 3.23 V | weaker than the standard |

- **Used: medium.** A connected line idles at 3.08 V or more (V_IH is 2.0 V); the other line and an empty
  socket are pulled to ground by 150 uA at most. What the data sheet does not promise is the minimum, so "an
  empty socket reads SE0 and is not disturbed by noise" is true by design of a pull-down but has no number.
  The connect detection therefore wants the line state stable for 100 ms.
- **An external resistor is not needed** for the port to work, and the board has no place for one. If the
  first measurement on the board (empty socket: both lines under 0.3 V; device in: 3.0 V or more on one, the
  other under 0.3 V) fails, the fix is 15 kohm from each data pin to ground on the Pmod plug.
- Before the bitstream is loaded every pin has a weak pull-down (UG304 3.1): a device sees SE0, which is what
  a host in reset looks like.

**Drive.** `DRIVE=8`, as the device socket (docs/USB_AUDIO.md 9). Full speed wants 4 to 20 ns edges and 28 to
44 ohm source impedance (7.1.1.1, 7.1.2); an 8 mA LVCMOS33 pin without series resistor is in that region and is
what the device socket already does. **Low speed wants 75 to 300 ns edges (7.1.2.1); an FPGA pin is ten times
faster.** That is outside the standard (more ringing on a long keyboard cable, more radio noise), not a
functional problem: the receiver samples in the middle of a 667 ns bit. No slew setting is used: UG304 names
the feature (2.1) but gives no constraint for it, and a setting found by trial is not a finding.
A radio is the wrong place for fast edges on a 2 m cable; 27 ohm in series on the Pmod plug is the cure if the
receiver hears it.

**Signalling by the host** (USB 2.0 7.1.7): idle = the device's pull-up (J: D+ high at full speed, D- high at
low speed); reset = both lines driven low for 50 ms (the standard asks 10 ms at least; 50 for a root port);
SOF every 1 ms +-500 ns keeps a full-speed device awake, a bare EOP (two low-speed bits of SE0, one of J) does
the same for a low-speed one; suspend = neither for 3 ms; resume = K for 20 ms, then a low-speed EOP.

**Supply and over-current.** 5 V comes from an ME2188A50 boost converter fed from the Pmod's 3.3 V pins; there
is no current limit and no fault signal. A device that draws too much makes the 5 V sag until it resets or
drops off. That is seen as "device gone" (section 2) or as three time-outs in a row; the firmware then starts
again from the connect detection and counts it. A device that keeps dropping off after a few seconds is
reported as "needs more power than the board gives".

**ESD.** None on the board, and the pins are the FPGA's own. Plug devices with the radio's ground connected.

## 4. Socket and pins

The dock has three sockets (dock schematic 4071f, PMOD sheet):
PMOD0 = J22, PMOD1 = J24, PMOD2 = J26. PMOD2 carries S/PDIF, I2S and MIDI in. The board is wider than a
socket, so it goes on an end socket. **Assumed, not verified: the three sit in a row in the order 0, 1, 2**
(the schematic draws them so; Sipeed's page has no drawing), which makes PMOD0 the free end.

- PMOD0's eight signal pins are also the configuration port (SSPI) and, through 0 ohm arrays RN10/RN11, the
  microphone-array connector J28 and its LEDs; the schematic also shows L22 on the 40-pin header. The build already frees them (`use_sspi_as_gpio`); **the
  microphone array and the USB board cannot both be fitted.**
- If the row is not in that order, or PMOD0 is in the way, `TR_USBH_PMOD=1` builds for PMOD1 (all eight pins
  free). Only the four pin locations differ.

**Numbering.** The dock numbers a socket 1-2 = 3.3 V, 3-4 = ground, 5 to 12 = signals, odd pins in one row and
even pins in the other (not Digilent's numbering). The USB board's drawing
numbers 1 to 6 down one row and 12 to 7 down the other, with 6-7 = 3.3 V and 5-8 = ground. The supply pins fix
which end is which:

| Dock pin | Dock net | USB board pin (drawing) | Signal | Ball, PMOD0 (J22) | Ball, PMOD1 (J24) | Top-level port |
|---|---|---|---|---|---|---|
| 1, 2 | 3.3 V | 6, 7 | 3.3 V | | | |
| 3, 4 | ground | 5, 8 | ground | | | |
| 5, 6 | IO3, IO7 | 4, 9 | not connected | R17, T24 | H14, H15 | |
| 7, 8 | IO2, IO6 | 3, 10 | not connected | R16, L24 | L17, L18 | |
| 9 | IO1 | 2 or 11 | USB1 D- (or D+) | **L22** | E25 | `usbh_a[0]` |
| 10 | IO5 | 11 or 2 | USB1 D+ (or D-) | **N17** | D25 | `usbh_b[0]` |
| 11 | IO0 | 1 or 12 | USB2 D- (or D+) | **N18** | C24 | `usbh_a[1]` |
| 12 | IO4 | 12 or 1 | USB2 D+ (or D-) | **M26** | B24 | `usbh_b[1]` |

- **What is certain:** USB1 is on dock pins 9 and 10 and USB2 on 11 and 12, because the supply pins are at the
  other end.
- **What is not:** which row of the plug meets the dock's odd row. Neither drawing shows the mechanical side.
  If it is the other way, D+ and D- change places on both ports. `usbh.ctrl.swap` exchanges them in logic
  (reset: odd row = D-); the firmware tries the other setting when enumeration fails. One look at the board
  settles it and the reset value can then be fixed.
- Banks: PMOD0 is bank 3, PMOD1 banks 4 and 5; all 3.3 V (UG986, as the neighbours on the same banks).

## 5. Audio clocking

The device's clock is not the radio's, but as host we own the frame.

- **Speaker (isochronous OUT).** A frame is 48,000 clocks of `clk_48m`; the radio's sample tick is `clk_dsp`
  / 2,500; both clocks come from one PLL (VCO 1,200 MHz / 25 and / 10). So the radio makes exactly 48 samples
  per frame, for ever, and the host sends 48 per frame: what a synchronous or adaptive endpoint with a
  192-byte packet size expects. The logic still does not assume it: at each SOF it sends every complete sample
  waiting in the 128-sample FIFO, limited to `usbh.spk.max_samples` (48, or 49 where the device's packet size
  allows). The first frames after switching on may carry fewer.
  A speaker with an asynchronous endpoint and a feedback endpoint (some hi-fi DACs) is driven the same way and
  its feedback is not read: it has to drop or repeat a sample now and then. Reported at enumeration.
- **Microphone (isochronous IN).** One IN token per frame; whatever comes (0 to 50 samples, or 44/45 for
  44.1 kHz) is unpacked to 16 bits, mono copied to both channels, and crosses to `clk_dsp` through a 128-sample
  FIFO into the speech-input FIFO. A packet with a bad CRC is dropped and counted.
  **The firmware's resampler does the rate change, not the slip block.** The slip block of the digital
  outputs (`audio_digital_out.v`) moves one sample in 64 frames between two clocks that are both nominally 48 kHz; a
  microphone that only does 44.1, 16 or 8 kHz needs a real rate converter, and speech goes through the CPU
  anyway (FreeDV wants 8 kHz). `tr_usbh::resample::Resampler` takes the nominal rate from the descriptors and
  trims by the FIFO's fill. `usbh.mic_count` counts samples for a rate read-out.
- **Where the microphone enters.** `usb.ctrl.speech_src` (new bit 4 of the device page): 0 = the PC's playback,
  1 = the host microphone. Both feed the one CPU FIFO (`usb.fifo_data`, interrupt 12). Nothing else changes for
  the firmware that reads speech. No transmit logic.
- **Where the speaker stream comes from.** `aud48_*`: the stream S/PDIF, I2S and HDMI get (the receiver audio,
  with the PC's playback added while `usb.ctrl.monitor` is set).
- Format choice (firmware): speaker 48 kHz 16-bit, stereo before mono, 24-bit in 3 bytes accepted; microphone
  48 kHz before 44.1, 32, 16, 8 kHz, 16-bit before 24. Class 2.0 (interface protocol 0x20) and anything that
  only enumerates at high speed: "unsupported", shown on the status line.

## 6. Mouse and keyboard to the GUI

- Keyboard: boot protocol (8-byte report), set with SET_PROTOCOL. The driver compares each report with the last
  and gives press and release events with the modifier state; a table turns a key code into a character for
  the US or the German layout (`Layout::Us`, `Layout::De`, incl. AltGr for `@ { } [ ] \ | ~`).
- Mouse: the report descriptor is read and the positions of buttons, X, Y and wheel are taken from it (with a
  report ID if there is one); if it cannot be read, the boot protocol (3 bytes, no wheel).
- Events (`tr_usbh::hid::InputEvent`): pointer move (relative), button, wheel, key down/up. `tr_gui::input`
  keeps the pointer position, clamps it to the screen and hands Slint `PointerMoved`, `PointerPressed`,
  `PointerReleased`, `PointerScrolled`, `KeyPressed`, `KeyReleased`. Every Slint `TouchArea` and focus item then
  works, so the FT8 and FreeDV screens become clickable where they have (or get) touch areas.
- **The pointer is drawn by the firmware**, as a small Slint element on top of the screen, not as a hardware
  sprite. Slint's renderer redraws only the two small rectangles a move touches, the pixel clock (the tightest
  in the chip, 158.6 MHz reached for 148.75) is left alone, and nothing has to be kept in step between two
  position sources. A sprite in the compositor (two registers, a 16 x 16 shape, one stage in `compositor_pix.v`,
  about 80 LUTs on `clk_pix`) is the later step if pointer moves cost too much CPU.

## 7. Registers

Page 0x0F `usbh` (hw/regmap/usbh.toml), behind a `regbus_leg`, in `clk_dsp`; interrupt line 13 (record waiting,
transaction done, or line change, each with an enable bit). Settings cross to `clk_48m` as held values plus a
toggle; the receive FIFOs are `usb_afifo` (commit on a good packet, rewind on a bad one).

## 8. A hub

Not built. One level of hub costs: an address per slot instead of one per port and the PRE packet with a speed
change inside the frame for low-speed devices behind a full-speed hub (about 200 LUTs per port, plus more
interrupt slots); in the firmware a device table instead of one device per port, and the hub driver (hub
descriptor, port power, status-change endpoint, port reset, address assignment): about 500 lines and the
enumeration tests again. Two to three days of a mid-tier worker. Not nearly free, mostly because mice and
keyboards are low-speed devices and every hub is full speed.

## 9. Manuals and sources

USB 2.0: 5.5 to 5.7, 5.12.4, 7.1 (7.1.1, 7.1.2, 7.1.5, 7.1.7, 7.1.18, 7.1.19), 8, 9, 11.1 (frame timing);
pull-up/pull-down resistor ECN. USB Audio 1.0 and Data Formats; HID 1.11 with appendix B (boot reports) and
the usage tables. Gowin DS1239-1.0.3E table 3-8; UG304-1.3.8E 2.1, 3.1, 3.5; UG986 (banks); UG300 (block RAM:
no read-before-write) and SUG550 (attributes) through docs/USB_AUDIO.md 10. Dock schematic 4071f PMOD sheet;
Muse Lab PMOD-USBHOST v1.0 schematic. No DSP block, no PLL setting and no new clock line.

## 10. What is built and how it was tested

| Part | Files |
|---|---|
| Logic | `rtl/usbh/`: `usbh_phy.v`, `usbh_port.v`, `usbh_iso_out.v`, `usbh_iso_in.v`, `usbh_regs.v`, `usbh_top.v`; reuses `rtl/usb/usb_afifo.v`. Wired in `sdr_core.v` (page 0x0F, interrupt 13, `aud48_*` in, microphone out) and `sdr_top.v` (four pads) |
| Speech source | `rtl/usb/usb_play.v`, `usb_regs.v`, `usb_audio.v`: `usb.ctrl.speech_src` (bit 4) |
| Registers | `hw/regmap/usbh.toml` (15 registers), generated files |
| Constraints | `gowin/p1/sdr.cst` (4 pins, pull-down medium), `sdr.sdc` (the pins), `build.sh` (file list, `TR_USBH_PMOD`) |
| Host stack | `fw/tr-usbh`: `host.rs` (ports, enumeration, class set-up), `desc.rs`, `hid.rs`, `resample.rs` |
| Driver | `fw/tr-fabric/src/usbh.rs`: the stack's `Bus` on the register page, counters, status line |
| Screen | `fw/tr-gui/src/input.rs`, the pointer in `ui/app_1920x1080.slint`; `Screen::input` in `fw/tr-app/src/screen.rs`; the poll in `fw/tr-app/src/bin/ft8fw.rs` |

**`sim/usbh/tb_usbh.v`** (iverilog, about half an hour; 65 checks): the unit against three behavioural devices
(`usbh_tb_dev.v`), each on its own clock: a full-speed headset 480 ppm fast, a low-speed mouse 1.1 % fast, a
low-speed keyboard 1 % slow. The full-speed device uses the device's own line interface (`usb_fs_phy.v`), so
host and device are two implementations at the bit level; tokens are checked with the device core's CRC5
residual. The bench plays the firmware through the registers.

| Test | Result |
|---|---|
| Empty sockets, plug in, speed from the line, the plug the other way up and `ctrl.swap` | pass |
| Enumeration of headset (64-byte endpoint 0, 197-byte configuration) and mouse (8-byte, low speed), with the swapped plug | pass, byte for byte |
| Keep-alive: SE0 for two low-speed bits; one SOF per ms; frame numbers | pass |
| Control faults: 3 NAKs; NAK for ever (given up after `nak_limit`); STALL; no answer (3 tries); one damaged packet (asked again); three damaged; device missed our ACK (repeat dropped); device stops in mid-packet | each gives its result code; nothing reaches the FIFO from a bad packet; **no transaction hangs** |
| Class requests with a data stage OUT (sampling frequency) | pass |
| Mouse reports through a slot while the headset streams: order, a damaged report, a report sent twice | each report once |
| Audio, 100 ms both ways (300 ms in the first run) | speaker: every sample once and in order, 48 a packet (36 to 48 in the first frames); microphone at the device's rate: every sample once and in order, the count equals what the device sent; no overrun |
| Damaged microphone packet | dropped whole, counted once |
| Mono and 3-byte samples to the speaker | 144 bytes a packet, (left + right) / 2 |
| Mouse pulled while polled | `gone`, the port stops sending, a transaction ends with "not running" |
| Keyboard plugged into the same port, boot protocol, reports; its endpoint answering STALL | pass; the slot stops and says so |
| Suspend (no SOF), resume (K, then frames again), headset pulled and plugged again | pass |

One run found one failure, in the bench (it left a record in the FIFO); the logic was not changed after its
first run.

Also: `sim/top/tb_sdr_core.v` passes with the unit in (page 0x0F read and written through the AHB bridge);
`sim/usb/tb_usb_audio.v` compiles with the new ports (not run again: the device's paths did not change).
`cargo test -p tr-usbh`: 19 tests; `-p tr-fabric usbh`: 2; `-p tr-gui --test input`: 2 (a mouse moves to and
clicks buttons of the FT8 and the FreeDV view; the pointer is drawn and nothing else is redrawn). The firmware
`ft8fw` builds for the AE350.

**Descriptor sets in the stack's tests** (`fw/tr-usbh/tests/enumerate.rs`): the C-Media audio adapter 0d8c:0014
(253 bytes, from a public `lsusb -v` listing: mixer, selector, three feature units, 48 and 44.1 kHz, a HID
interface); the Pixart mouse 093a:2510's report descriptor (Linux kernel documentation); constructed: a boot
keyboard with a second interface, a class 2.0 device, a hub, a sound card with odd rates, a mouse with report
ID and 12-bit axes.

Not simulated: a hub, a device slower than the host by the full 0.25 % / 1.5 %, cable reflections, real
pull-down currents.

## 11. Supported and not

| Device | State |
|---|---|
| Headset or sound card, class 1.0, playback 48 kHz, 1 or 2 channels, 16 or 24 bit | supported; adaptive and synchronous endpoints as intended, asynchronous ones without their feedback (reported) |
| Microphone at 48, 44.1, 32, 22.05, 16, 11.025 or 8 kHz, 1 or 2 channels, 16 or 24 bit | supported; the firmware resamples |
| Boot keyboard (low or full speed) | supported; US and German tables |
| Mouse with a readable report descriptor, or the boot protocol | supported, with wheel where the descriptor has one |
| Keyboard and mouse in one device (wireless receiver) | supported: two slots per port |
| Volume and mute buttons of a headset, media keys | not read |
| Playback only at 44.1 kHz; class 2.0 audio; hubs; a second headset; tablets (absolute pointers) | reported as not supported |
| The headset's volume | left as the device starts (it is un-muted); no volume request yet |

## 12. Cost

Stand-alone, Gowin V1.9.12.04, wrapper subtracted (`gowin/res.sh usbh_top --clk clk_dsp --clk2 clk_usb
--period-ns 7.917 --wrap --sdc gowin/wrap/usb_audio_ooc.sdc ...`; both clocks 5 % tighter than real):
**Logic 3,994, registers 2,005, block RAM 2, no DSP.** `clk_dsp` 129.1 MHz (needed 120), `clk_48m` 93.7 MHz
(needed 48), no hold failure. In the whole chip the difference to the build before is Logic +4,082, registers
+2,137, block RAM +2.

### Full-chip builds (4 receivers and the zoom, commit c133286 plus the top-level fix)

Place option 3, route option 1; reports in `gowin/reports/p1_usbh/`. Failing end points (setup / hold) and the
frequency reached:

| Clock | Needed MHz | Build 1, real clocks | Build 2, clk_dsp and clk_pix 5 % tighter |
|---|---|---|---|
| `clk_dsp` | 120 | 0 / 0, 120.94 | **6 / 0**, 125.11 (constraint 126.0) |
| `clk_48m` (both USB units) | 48 | 0 / 0, 100.99 | 0 / 0, 106.06 |
| `clk_aud` | 49.152 | 0 / 0, 157.68 | 0 / 0, 158.40 |
| `clk_rx` | 125 | 0 / 0, 170.33 | 0 / 0, 170.33 |
| `clk_tx` | 125 | 0 / 0, 158.19 | 0 / 0, 145.55 |
| `clk_pix` | 148.75 | 0 / 0, 165.36 | 0 / 0, 163.43 (constraint 156.19) |
| AE350 bus clock | 100 | 0 / 0, 109.01 | 0 / 0, 108.24 |
| AE350 data-memory bus clock | 50 | 0 / 0, 111.81 | 0 / 0, 108.83 |
| DDR3 controller clock | 100 | 0 / 0, 172.88 | 0 / 0, 161.04 |
| all clocks | | **0 setup, 0 hold** | 6 setup, 0 hold |

- Build 1 is the chip: no failing end point on any clock. Both builds were made before master's change of the AE350 bus to 80 MHz (branch `ahb80`) was merged into this branch; the merged state was compiled and type-checked but not built again (two builds were the budget).
- The six of build 2 are all in the FT8 front end (`u_ft8/u_spec` to `u_ft8/u_cand` and to the write relay),
  0.056 ns and 0.021 ns short of a clock 5 % faster than the real one. None is in the USB host or on a path
  into or out of it. The build before the host had none at this margin: the chip is fuller (CLS 87 %), and that
  is where the placer gave way. `rtl/ft8` was not touched here.
- Chip fill (build 1): Logic 84,534 of 138,240 (62 %), registers 69,863 (51 %), CLS 87 %, block RAM 226 of 340,
  DSP 127 of 298. No clock line was added: the host is on `clk_48m`'s long-wire line with the USB device.

## 13. What the app still has to do

The main loop already polls the host, moves the pointer, clicks the views and takes ASCII keys as console keys.

1. **Speech from the headset** (on hold with voice transmit): `UsbHost::set_speech_from_mic(true)`, read
   `UsbAudio::read_mono()`, and put `tr_usbh::resample::Resampler::new(info.mic.rate, 48_000)` in front, steered
   by the FIFO level. The rate is in the `Connected` event.
2. **A setting for the key layout** (`USB_KEY_LAYOUT` in `ft8fw.rs` is a constant, US) and for the pointer's speed.
3. **Status on the screen**: what is plugged in, and the `Problem` events (they go to the console now).
4. **Headset volume** from the radio's volume control (a class request per change), and its buttons.
5. Text entry: nothing on the screens takes text yet; the key events already reach Slint.
6. The QEMU twin does not have the host (its register mock reads "not in this chip").

## 14. Only real devices on the board can confirm

- Which way up the board sits (the reset value of `ctrl.swap`), and that PMOD0 is the end socket.
- The pull-downs: an empty socket reads low on both lines without chatter; a plugged device's line is at 3.0 V
  or more.
- Edges and ringing on a low-speed keyboard cable, and whether the receiver hears them.
- That the boost converter holds 5 V for a headset (and which keyboards it cannot feed).
- Each real device: enumeration time, that a headset's adaptive endpoint is content with exactly 48 samples a
  frame, the microphone's true rate, a one-hour stream with all counters at 0.
- Devices that need a set-up this stack does not do (a headset that stays silent until its volume is set).
