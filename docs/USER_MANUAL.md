<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# fpga-sdr user manual (state of 2026-10-21)

What it is today: an **FT8 station** with a FreeDV receive screen and a LISTEN screen for SSB, CW, AM, SAM and FM
with free tuning (docs/LISTEN.md, branch `listen`, not yet run on the board), running on the Tang Mega 138K Pro and fed by a
Hermes-Lite 2 over an SFP cable. Transmit is built but has never been tested end to end, so the firmware keeps it locked.

## 1. What you need

| Item | Where it goes |
|---|---|
| Tang board, powered | USB-C debug cable to the PC (used only to load the radio) |
| HDMI monitor | the board's HDMI port: the radio's screen |
| Network cable | the board's RJ45 socket into the home network (DHCP, internet for the clock) |
| Hermes-Lite 2 with the raw-stream test firmware | its Ethernet cable into the **copper SFP module in cage SFP0** (the cage labeled SFP0 on the dock, not SFP1), antenna on the HL2 |
| PC | Python 3.10 with `pyserial` (already installed) |

Cage: the radio uses **SFP0** for the HL2. (The minimal test ran on cage SFP1; the full radio listens on SFP0. The console says
`sfp0 (HL2): link up (1000BASE-X)` when it works.)

## 2. Start

1. Power the board and the HL2. Plug the HDMI monitor in.
2. On the PC, from the repository root:

   ```
   run.bat
   ```

   It loads the radio into the board (about 1 minute: the bitstream over the debug cable, the firmware over the network) and then opens
   the mouse and keyboard window. Nothing is written to the board's flash, so **after a power-off you run this again**.
3. If it says the board is in use, another session has the board: ask there. If it says the debug USB is missing, check
   the USB-C cable and the board's power. If it ends with "no ok line" but the monitor shows the radio, run it once more.
4. The HDMI monitor shows the LISTEN screen (all modes; `m` cycles to FreeDV and FT8, or use the buttons at the top). The FT8 screen shows: clock status, a waterfall, the decode list and the band buttons.

## 3. Operate from the PC (no mouse or keyboard on the board)

`py tools/radio_input.py` finds the board by itself (or `--ip A.B.C.D`). **Click its window** to grab the PC mouse and keyboard; the title says
captured. **Esc and F12 together** release them. Watch the HDMI monitor: the pointer arrow moves like a laptop pad (it can lag a
fraction of a second while the radio is decoding). Click the screen's buttons with the left mouse button.

Keys the window sends (the same as the serial console's):

| Key | Action |
|---|---|
| `[` and `]` | band down and up (160, 80, 60, 40, 30, 20, 17, 15, 12, 10 m; the dial goes to the FT8 frequency of the band) |
| `h` | halt |
| `m` | next screen: FT8 -> FreeDV -> LISTEN -> FT8 |

**Blocked from the network on purpose** (they transmit or start answering): `t c s u`, the digits `0`-`9`, `-`, `+`, `=` and the screen's
transmit, CQ, answer and TX-frequency buttons. On the FreeDV screen `-` and `+` (squelch level) are blocked for the same reason.
The same keys work on the serial console (COM port B of the debug cable, 184,320 baud) for the day transmit is enabled.

## 4. Modes and frequencies

- **FT8** (the default screen): receiver 0 decodes the band's FT8 slot every 15 s. The list shows time, level, DT, audio offset and
  message. Band buttons set the HL2's frequency: 1.840, 3.573, 5.357, 7.074, 10.136, 14.074, 18.100, 21.074, 24.915, 28.074 MHz (dial,
  USB).
- **FreeDV** (`m`): receive screen for 700D and 700E: keys `d`, `e` (mode), `q` (squelch), `[` `]` (band), `<` `>` (dial 100 Hz down, up).
- **LISTEN** (`m` on the FreeDV screen, or the LISTEN buttons): LSB, USB, CW, AM, SAM, FM from 100 kHz to 30 MHz on receiver 1, audio
  on the headphone output, S/PDIF, I2S and HDMI. Click the upper or lower half of a frequency digit or turn the wheel over it; click
  the waterfall to tune there. Keys: arrows left/right tune by the step, up/down volume, Shift+up/down squelch level, Page Up/Down
  100 kHz, Home/End band, `l k w a g f` LSB USB CW AM SAM FM, `b` filter, `,` `.` step, `o` AGC, `q` squelch, `e` `d` waterfall
  sensitivity up (brighter) and down (darker), `r` `v` waterfall contrast (the range from black to white) wider and narrower, `x` `z`
  waterfall speed faster and slower, `m` back to FT8. The waterfall's colours follow the noise floor by themselves; the row of
  buttons under the right-hand panel (Sensitivity, Contrast, Speed, each - and +, and Auto for the automatic floor) and the keys
  shift them from there. Speed is lines per second (0.9 to 3.7 at 12 kHz span, 1.0 to 7.3 at 24 kHz). "RF gain" - and + set the
  HL2's input gain in 1 dB steps, and AUTO lets the radio set it from the level of the whole band: it turns the gain down at once
  when the band gets loud and back up slowly when it is quiet again. The radio starts in MANUAL at 20 dB. The line under the HL2
  link state shows the HL2's temperature and its forward and reverse power readings. Details: docs/LISTEN.md and
  docs/HL2_CONTROL.md.

## 5. Clock

FT8 needs UTC within about a second. The radio sets it from the network (SNTP over the RJ45) and the screen shows the clock status.
Without internet the serial console can set it by hand (`u` then `hhmmss`; blocked on the network window).

## 6. Listening and antenna

- Connect the antenna to the HL2's antenna connector for the band. Whether the HL2's band filter board switches with the band button
  is **not verified**.
- Audio outputs exist in the logic (headphone DAC, S/PDIF, I2S, HDMI audio, USB audio to a PC). FreeDV and LISTEN write their audio to the
  engine that feeds the first four; none of it has been heard on the board yet.

## 7. Safety

Transmit is built (the chain in the chip, the sample path to the HL2, the FT8 waveform and the safety checks) but it has never been tested end to end,
so it is locked: the call sign is the placeholder N0CALL, the HL2 is never sent a transmit enable, and the network window cannot
send a transmit key. Do not remove these limits before the whole path has been tested on a dummy load.

## 8. Troubleshooting

| Sign | Likely cause |
|---|---|
| no picture | HDMI cable and input; the picture is 1920x1080 at 30 Hz (1080p60 does not work on the board's HDMI pins); the serial console reports `HDMI: ... underrun false` when the picture fetch is healthy |
| window finds no board | the radio is not running, the RJ45 cable is not in the network, or the PC firewall blocks UDP port 21600 |
| `HL2: looking for the radio` forever | the HL2 is off, the module is not in SFP0, or the cable is wrong |
| `HL2: streaming, 0 gaps, 0 CRC errors` | everything is fine |
| `HL2 telemetry: none (no message layer)` | the HL2 runs without the message-layer firmware: reception works, the gain still changes, but there is no temperature or power reading |
| decode list empty | no antenna, no signals, or the clock is wrong |

## 9. Known open items (2026-10-21)

- The HDMI output reports an underrun on every check: the picture is unverified.
- The chip's timing has 2,493 failing setup and 3 failing hold end points (not analysed): odd behaviour is possible.
- The pointer lags by up to a main-loop pass; the loop is not yet split into tasks (docs/ARCHITECTURE.md section 5.3 planned that).
- The dock's LCD is not used. A status view on it is possible later.
- Network control for third-party programs (TCI) is not built.
