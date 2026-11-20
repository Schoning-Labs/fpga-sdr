<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# LISTEN: general receive (SSB, CW, AM, SAM, FM)

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Branch `listen` (cut from `ddr300`), 2026-10-22. Firmware and screen only: **no gateware change**. Nothing here has run on
a board.

Code: `fw/tr-station/src/listen.rs` (station and receiver, host tests in `listen/tests.rs`), `fw/tr-gui/src/listen.rs` and
`fw/tr-gui/ui/listen_view.slint` (screen), `fw/tr-app/src/bin/ft8fw.rs` (main loop), `fw/tr-input` (`console_code`,
`AnsiKeys`: the arrow and page keys), `fw/tr-fabric/src/backend.rs` (controls of a running receiver, partial ring reads).

## 1. What it does

| Item | Value |
|---|---|
| Modes | LSB, USB, CW, AM, SAM (synchronous AM), FM (narrow) |
| Tuning range | 100 kHz to 30 MHz, 1 Hz resolution |
| Filter presets (first = default) | SSB 2.4 kHz (300 to 2,700 Hz), 1.8 kHz (400 to 2,200), 2.8 kHz (200 to 3,000); CW 500, 250, 800 Hz around a 600 Hz pitch; AM and SAM 6, 9, 4 kHz; FM 12 kHz |
| Steps | 10 Hz, 100 Hz, 1 kHz, 5 kHz, 9 kHz, 10 kHz, 12.5 kHz, 100 kHz, 1 MHz |
| Bands | 160, 80, 60, 40, 30, 20, 17, 15, 12, 10 m and GEN (100 kHz to 30 MHz); each band remembers frequency and mode |
| Default mode | LSB below 10 MHz, USB above, USB on 60 m, CW on 30 m, AM on GEN (9.650 MHz) |
| AGC | on/off; off holds the gain the AGC had. FM always runs with a fixed gain |
| Squelch | on/off, level -140 to -20 dBFS, closes 3 dB below the opening level; on the S-meter level, any mode |
| S-meter | dBFS: the back end's level + 22.3 dB, so a full-scale ADC sine reads 0 dBFS (docs/R4_BACKEND.md 3.6) |
| Volume | 0 to 100 %, in software (see 3) |
| Audio out | headphone DAC (PT8211), S/PDIF, I2S, HDMI: the audio engine's 48 kHz ring |
| Transmit | none. Entering LISTEN switches TX off (the FT8 station's own path); nothing on the screen or in its keys transmits |

## 2. Receiver: how the frequency is made

- The HL2 is **not tuned**. Its raw stream (76.8 Msps, 12-bit) carries 0 to 38.4 MHz. Bank receiver **1** (FT8 keeps
  receiver 0) has its own oscillator, a 32-bit phase step at 76.8 MHz (0.018 Hz), and is set to any frequency in that
  range. 48 ksps out of the bank, then the back end (docs/R4_BACKEND.md): half-bands to 24 ksps, a 1,023-tap complex
  channel filter (21 ms delay), demodulator, AGC, squelch, half-band to 12 ksps, 16-bit audio into the DDR3 ring
  (2^9 blocks of 128 samples, 5.5 s).
- Oscillator = shown frequency, except CW: 600 Hz below the carrier, the filter around +600 Hz, so the carrier is heard
  as a 600 Hz tone and the shown frequency is the carrier.
- The only thing the HL2 hears about is the **band filter** (N2ADR relays, register 0x00), chosen from the frequency as
  for FT8 (`hl2session::filter_band`: up to 2.5 MHz the 160 m low-pass only, then 80, 60/40, 30/20, 17/15, 12/10 m groups).
  It is written only when the group changes. Below 1.8 MHz the 160 m low-pass and the HL2's own input are in the
  path; whether medium and long wave arrive at a useful level is **not verified**.
- Filter banks: unit 0 serves receivers 0 to 3 with 6 banks. FT8 has bank 0; LISTEN uses banks 1 and 2 in turn
  (a new filter is written into the one not in use, then the receiver switches between two samples, no restart);
  banks 3 to 5 stay free. Each filter is designed once (`tr_dsp::backend::design::bandpass_quantized_into`, the same
  integers as `quantize(bandpass(..))`, without 24 KB of arrays on the 32 KB stack) and kept.
- A mode change restarts the back end (new demodulator from a clean state). The AGC then starts at its top gain
  and comes down within its 2 ms attack: a short click is possible.
- FM: 12 kHz filter, discriminator range +/-12 kHz, de-emphasis 530 us (6 dB per octave above 300 Hz) and +12 dB fixed
  gain to make up for it. Squelch on the level, not on the noise (the back end has no noise squelch).

## 3. Audio route and timing

Back-end ring block (128 samples, 12 ksps) -> 4x interpolation to 48 kHz (`tr_freedv::resample::Resampler`, 24 taps per
phase) -> volume (gain (volume/100)^2 x 2, so 50 % is 0.5 and 100 % is +6 dB) -> both channels -> the audio engine's ring.

- The chip's volume register reaches no output (docs/AUDIO_OUT.md section 2); it is set to 255 and the volume is
  applied in software.
- The engine's ring is **4,096 frames = 85 ms, fixed in the logic** (`audio_engine #(.RING_SIZE_WORDS(4096))`; the
  ring-size register is not used by the reader). It cannot be made larger without a gateware change.
- So the ring is topped up often, whole blocks at a time (512 frames): at the start and end of each main-loop pass,
  after the screen's state is applied, after the radio service, from the yield hook of long jobs (every 20 ms; the
  decoders are paused in LISTEN anyway), and **from inside the screen drawing**: the LISTEN screen is drawn line by
  line (`render_rgb565_lines_with`) and the ring is topped up every 5 ms on the way.
- Playing starts with 3 blocks (32 ms) waiting. If the ring runs dry it counts an **underrun** and waits for 3 blocks
  again. After a stall, blocks beyond what the ring takes plus 2 are **dropped** (counted), so the delay stays near
  85 ms + 21 ms (filter) + up to 21 ms (2 blocks) instead of growing.
- No rate matching between the HL2's clock (its 76.8 MHz) and the audio clock (from the board's 50 MHz): a 20 ppm
  difference gives one underrun or one dropped block every hour or so.

Console, every 5 s while LISTEN is shown:

```
LISTEN 7.074.000 Hz LSB 2.4 kHz, S-meter -78.4 dBFS, audio peak -16.3 dBFS, ring 81 ms, underruns 0, blocks lost 0, dropped 0, longest service gap 12 ms, longest pass 140 ms
```

`blocks lost` = blocks the back end overwrote before they were read (5.5 s of stall); `longest service gap` = the
longest time between two top-ups since the last line (above 85 ms means an underrun was likely).

## 4. Screen, keys and mouse

Screenshots: `docs/img/listen_1920x1080.png` (40 m LSB, zoom receiver), `docs/img/listen_am_1920x1080.png` (AM on GEN,
squelch closed, a chip without the zoom receiver). Only the 1920x1080 window exists in the firmware; the 1024x600
panel (`ui/panel_1024x600.slint`) is a design that is not wired in and got no LISTEN view.

- Top: screen buttons FT8 and FreeDV, the 11 band buttons, the HL2 link state, and under it the HL2's temperature
  and forward and reverse power codes from its telemetry (docs/HL2_CONTROL.md). An HL2 without the message-layer
  firmware sends no telemetry, and the line then says "HL2 telemetry: none (no message layer)".
- Waterfall window (the same rectangle as FT8 and FreeDV): the zoom receiver centred on the tuned frequency, 12 kHz
  span (6.25 Hz per pixel, +/-3.66 kHz visible) for SSB and CW, 24 kHz span (12.5 Hz per pixel, +/-7.3 kHz) for AM, SAM
  and FM (48 kHz until 2026-10-22: see section 8). Under it a scale in kHz from the tuned frequency, the filter's pass band as a blue bar and the tuned
  frequency as a white mark. Without the zoom receiver the window is hidden and the caption says so.
- Right: the frequency display (8 digits, 10 MHz to 1 Hz), the step selector, S-meter bar with the squelch level
  mark, volume, squelch, receiver and audio lines, and one row of waterfall controls: Sensitivity, Contrast and Speed (each
  with - and +) and Auto (sections 8 and 9).
- Bottom left: mode buttons, AGC, filter buttons, tune down and up by the step, and at the right the HL2's RX gain
  ("RF gain" with - and +) and the RF AGC's AUTO/MANUAL button. The AGC button next to the modes is the audio AGC of
  the receiver; AUTO is the RF AGC that sets the HL2's gain from the level of the whole band (docs/HL2_CONTROL.md).
  The band filter of the HL2 follows the frequency by itself, so there is no filter or antenna selector.

| Action | Effect |
|---|---|
| click the upper / lower half of a digit | that digit up / down (10 MHz to 1 Hz) |
| wheel over a digit | that digit up (away from you) / down |
| click in the waterfall | tune there: SSB and CW to 10 Hz, AM, SAM and FM onto the step's grid |
| wheel over the waterfall | one step up / down |
| left / right arrow | one step down / up (on the step's grid) |
| up / down arrow | volume +5 / -5 % |
| Shift + up / down | squelch level +2 / -2 dB |
| Page Up / Page Down | +100 kHz / -100 kHz |
| Home / End (also `[` `]`) | band down / up |
| `l` `k` `w` `a` `g` `f` | LSB, USB, CW, AM, SAM, FM (`k` for USB: `u` is blocked from the network) |
| `b` | next filter width |
| `,` `<` / `.` `>` | smaller / larger step |
| `o` | AGC on/off |
| `q` | squelch on/off |
| `e` / `d` | waterfall sensitivity 3 dB more (brighter) / less (darker); buttons "Sensitivity" + - |
| `r` / `v` | waterfall contrast: the range from black to white one step wider / narrower (20, 30, 40, 50, 60, 80, 100, 120 dB); buttons "Contrast" + - (+ = wider range, a flatter picture) |
| `x` / `z` | waterfall speed one preset faster / slower; buttons "Speed" + - (section 9) |
| button "Auto" | sensitivity back to the automatic floor (0 dB) |
| buttons "RF gain" - / + | the HL2's RX gain 1 dB down / up (-12 to +48 dB); switches the RF AGC to manual |
| button AUTO / MANUAL | RF AGC on / off; it starts in manual at 20 dB |
| `m` | to FT8. `m` cycles FT8 -> FreeDV -> LISTEN -> FT8 |

None of these keys is on the network input's transmit block list (`t c s u 0-9 - + =`; test
`keys_are_receive_only_and_never_on_the_transmit_list`). One exception to know: the `]` key is blocked from the
network because it gives `+` on a German keyboard (that was already so for FT8 and FreeDV); End steps the band up.

Keys reach the screens in one place: `tr_input::console_code` turns a key (HID usage) into an ASCII character or a code
for the arrow, page and Home/End keys (0x80 to 0x89, never a typed character). The network input and the USB keyboard
both use it. The serial console's escape sequences (`ESC [ A`, `ESC [ 5 ~`, `ESC [ 1 ; 2 A` ...) become the same codes
(`tr_input::AnsiKeys`); a lone Escape is dropped.

The FT8 screen has a LISTEN button next to FreeDV; the FreeDV screen has a LISTEN button in its top bar, and its `m`
now goes on to LISTEN (it went back to FT8 before; the "< FT8" button still does).

## 5. While LISTEN is shown

- TX is switched off on the way in (`Station::force_tx_off`, the same path as FreeDV) and nothing can switch it on:
  the FT8 screen and its keys are not active, and the network guard keeps dropping the FT8 screen's transmit events.
- FT8 slots, decoding (chip and software) and the slot clock stop, as for FreeDV. Receiver 0 keeps running on the FT8
  dial frequency (its audio still fills the FT8 capture); FT8 decoding starts again with the next slot after `m`.
- Leaving LISTEN stops receiver 1 and the audio engine and gives the waterfall and the HL2 band filter back to the
  screen that follows.

## 6. Tests (host, mock fabric)

| Test | Checks |
|---|---|
| `cargo test -p tr-station --lib listen` (9 tests) | oscillator per mode, filter edges per preset, steps on the grid, digit tuning, range limits, click-to-tune, bands, default modes, band memory; each preset designed through `tr_dsp::backend::design` equal to `quantize(bandpass(..))` bit for bit, 0 dB in the pass band, below -60 dB 300 Hz outside, opposite sideband below -100 dB; receiver 1 set-up, banks 1 and 2 in turn with a busy bank, mode restart, AGC hold, squelch levels, FM settings, S-meter; audio: 1 kHz tone at 48 kHz with the volume applied, prefill, underrun count, latency cap after a stall, console line; keys; the zoom waterfall set-up |
| `cargo test -p tr-gui --test listen_screen` | renders the screen (PNG), key-colour rectangle intact, digit height, every control's event, wheel events, the firmware's window switching to LISTEN, line-by-line drawing calls the hook and draws the same pixels |
| `cargo test -p tr-input` | console codes of the arrow/page/Home/End keys and the LISTEN letters from the network, terminal escape sequences |
| `cargo test -p tr-fabric --lib backend` | bank switch, AGC, squelch, AGC gain read, partial ring reads |
| `cargo test -p tr-station --lib wflevel` and `radio::tests::zoom_waterfall_colours_follow_the_noise_floor` | section 8: the floor lands on its palette index from far below and far above, operator floor and range, the line after a change not measured; through the mock fabric: the line read back from the ring (byte order), the level register, the console report |
| `sim/zoom/tb_zoom_noise_colour.v` (RTL, about 2 s) | section 8: the zoom context's colour bytes for noise-only frames: old level and gain 16 all black (1,172 of 1,172 window columns at index 0); new level and gain 64: 1,133 of 1,172 not black, 25th percentile index 31 |

## 7. Not done, and risks

- Nothing has run on a board: audio level, S-meter calibration, the line-by-line drawing's speed on the AE350 and
  whether 5 ms top-ups during drawing keep the 85 ms ring from running dry are all unmeasured. Read the 5 s console
  line (`underruns`, `longest service gap`).
- The 85 ms ring is the weak point. Any stretch of main-loop work without a top-up longer than about 80 ms (a full
  Slint layout pass before drawing, a long network burst) gives an underrun. A larger ring needs the gateware.
- No noise blanker, noise reduction, RIT, variable CW pitch, notch, or memory that survives a power-off.
- The back end's squelch works on the level only; FM has no noise squelch.
- Frequencies cannot be typed from the network (the digits are transmit keys there). Tuning is by digit, wheel, keys
  and the waterfall.

## 8. Waterfall colours (2026-10-22)

**Seen on the board** (firmware of master 927f132, no antenna): audio noise, S-meter -105 dBFS, HDMI healthy, the console
said the zoom window was placed, but the LISTEN waterfall was black. The zoom receiver and the window were working; the
colour scale was far above the noise, and most of the noise was below one step of the power word.

**The numbers** (`rtl/spectrum/spectrum_pipeline.v`, zoom context): colour byte = clamp(((line dB x 64 + offset) x gain_q8) >> 14).
The line's dB is 10 log10 of a column's power word, 0 dB = one step (the FFT output rounded by 8 bits, then squared); a
power word of 0 gives -512 dB, so index 0. Palette index 0 is black (`default_palette`). The firmware wrote offset
-24.08 dB (the narrow-span gain taken off) and gain 1 dB per index: a column is index 0 unless it is 25 dB above one step.

Noise per bin at the window, from the chain's fixed-point scaling (mixer table 107,922 / 2^11, fixed CIC 10^9 / 2^32, CICs and
filters gain 1, narrow CIC 4^gain, Blackman-Harris window, unscaled 4,096-point FFT), for ADC noise of 1.06 LSB^2 (what -105 dBFS in
2.4 kHz means) plus the rounding of the 16-bit words between the stages:

| Span, narrow gain | Noise per component after the 8-bit rounding | Power word mean | Columns exactly 0 | Index with the old level |
|---|---|---|---|---|
| 12 kHz (LISTEN SSB, CW), x16 | 0.34 step | 0.40 = -4.0 dB | 60 % | 0 everywhere |
| 6 kHz (FT8, FreeDV), x16 | 0.25 step | 0.29 = -5.4 dB | 86 % | 0 everywhere |
| 48 kHz (LISTEN AM, SAM, FM), no narrow gain | 0.09 step | 0.18 = -7.4 dB | 100 % | 0 everywhere |
| 12 kHz, x64 | 1.32 step | 3.64 = +5.6 dB | 3 % | |
| 24 kHz, x64 | 1.86 step | 7.09 = +8.5 dB | 1 % | |
| 6 kHz, x64 | 0.93 step | 1.91 = +2.8 dB | 6 % | |

So the FT8 and FreeDV zoom waterfalls were black too, and at 48 kHz no level can show the noise: the power words are 0.

**What changed (firmware only):**

- Narrow-span gain 64 (`radio::ZOOM_NARROW_GAIN`) for the FT8, FreeDV and LISTEN zoom waterfalls (was 16). Cost: the
  narrow spans' stage saturates for a tone above about -28 dBFS within about 15 kHz of the centre (was -16 dBFS); this
  affects the picture only, not the audio.
- LISTEN AM, SAM and FM use the 24 kHz span (12.5 Hz per pixel, +/-7.3 kHz), not 48 kHz.
- Automatic floor (`tr_station::wflevel`, run from `Radio::service`): each new zoom waterfall line is read back from its
  DDR3 ring (the window's columns), its 25th percentile is taken as the noise floor, and the level is set so that the
  floor lands on palette index 32 (dark blue); 60 dB over the palette by default. A line clamped at 0 or 255 moves the
  estimate by half the range; the line after a level change is not measured.
- Operator controls on the LISTEN screen (until 2026-10-22 these were "Waterfall floor" and "Waterfall range"): sensitivity
  (3 dB steps, +/-30 dB from the automatic setting, + = brighter, shown as "+6 dB", "0 dB" = automatic; it is the floor
  with the sign reversed) and contrast (the range, 20 to 120 dB). Keys `e` `d` (sensitivity up, down) and `r` `v`
  (contrast wider, narrower); none is on the network's transmit list. The settings stay for the FT8 and FreeDV zoom waterfalls.
  Speed: section 9.
- Console, every 5 s on the LISTEN screen (and on the FreeDV screen), one more line (the figures here are an example, not a measurement):

```
LISTEN zoom waterfall: zoom id 0x5a4d0002 ctrl 0x068d (enable 1, span 12000 Hz, gain x64), lines 412 (18 since the view started), ring write line 1307, window 0 on waterfall source zoom ring 0x11800000 top line 1307 columns 374+1172, level offset +7.50 dB gain 1092/256, sensitivity +0 dB, contrast (range) 60 dB, speed 3.7 lines/s (1 frames per line), last line 1172 columns 39 black, index low 31 mean 44 peak 77 (1.5 / 4.6 / 10.6 dB of the line), floor estimate 1.4 dB, lines measured 17
```

**Reading it on the board if the waterfall stays black:** `lines` not rising = the zoom receiver makes no lines (enable,
span, the HL2 samples); `ring write line` not moving = the hardware writer does not write the ring; `window 0` not
`on waterfall source zoom ring 0x11800000` = the window set-up; `index low` 0 with `black` near all columns = the level
(the floor estimate should then fall by 30 dB per line until the floor shows); `index low` near 32 but a black picture =
the compositor or the palette.

**Bench:** `sim/zoom/tb_zoom_noise_colour.v` feeds noise-only zoom frames at the levels above into the zoom context:
old level and gain 16: 0 of 1,172 window columns not black; new level and gain 64: 1,133 of 1,172 not black, 25th
percentile index 31. The video path (palette and compositor) is unchanged and covered pixel for pixel by
`sim/video/tb_compositor.v`.

## 9. Waterfall speed (2026-10-22)

The zoom receiver makes one 4,096-point transform every 1/t second (t = 3.66 per second at the 12 kHz span, 7.32 at 24 kHz,
14.6 at 48 kHz) and averages K whole transforms into one waterfall line (`zoom.backend_averaging_k`), so a line comes every
K/t second. K is a whole number, so not every rate exists.

- **Presets** 1, 2, 5, 10 and 15 lines per second (`listen::SPEED_PRESETS`); the start value is 7 as before
  (`listen::ZOOM_LINES_PER_S`: every transform at both LISTEN spans). A preset gives the K whose rate is nearest to it
  (`tr_fabric::zoom::averaging_k`), never more lines than transforms. The screen shows the rate that results:

  | Span | K and lines per second, slowest to fastest |
  |---|---|
  | 12 kHz (SSB, CW) | K 4 = 0.9, K 2 = 1.8, K 1 = 3.7 (the presets 5, 10, 15 and the start value 7 all give K 1) |
  | 24 kHz (AM, SAM, FM) | K 7 = 1.0, K 4 = 1.8, K 2 = 3.7, K 1 = 7.3 (10, 15 and 7 give K 1) |

  The "Speed" - and + buttons and the keys `z` (slower) and `x` (faster) step through the rates the span gives. The preset
  asked for is kept when the mode changes the span; the screen then shows the rate it gives there.
- **How it changes.** Only `backend_averaging_k` is written, while the receiver runs: the zoom receiver, its centre, the
  audio, the automatic floor (the colour level) and the waterfall window are not touched, and the picture does not blank
  (`Radio::set_listen_speed`; test `listen_speed_changes_k_in_place_and_lowers_it_only_after_a_new_line`).
- **Trap in the logic found while reading it** (`rtl/spectrum/spectrum_pipeline.v`, `groupB_pos == zk_last`): the frames of
  the line in progress are counted in a 32-bit register and the line ends when the count equals K - 1. A K written below
  the count is never met and the waterfall stops (until K is raised again; the count only restarts at a line's end).
  So firmware raises K at once and lowers it only right after a new line appeared (zoom write line changed, count 0), in
  `Radio::service`. The same rule covers the restart on a mode change and the switch to the FT8 or FreeDV waterfall
  (`Radio::start_zoom_k`: the old K stays until the next line). If no new line comes for 4 s the radio writes K = 8 once
  (that ends any line in progress) and then the wanted K at the next line (`ZOOM_STALL_MS`); without a time from the
  caller (`Radio::set_now_ms`, called by ft8fw each pass) that check is off. No FPGA change is needed; a change that
  clears the count when K is written would remove the rule.
- Console: the 5 s "LISTEN zoom waterfall" line now ends its level part with `sensitivity +0 dB, contrast (range) 60 dB,
  speed 3.7 lines/s (1 frames per line)` (with `, 2 pending` while a lower K waits for the next line); a speed change
  prints "LISTEN: waterfall speed 1.8 lines/s (preset 2)".
