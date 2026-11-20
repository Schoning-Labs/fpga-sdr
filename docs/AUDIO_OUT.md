<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# Audio outputs: headphone DAC, HDMI, S/PDIF, I2S

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Written 2026-10-12, branch `audio` (parts of work packages LS2, LS5, LS8 of docs/PLAN.md). **Nothing here has
run on a board.** What is simulated and what is only built is in section 6. USB audio is not part of this
(USB is deferred, docs/DECISIONS.md).

The audio output consists of `rtl/audio/audio_digital_out.v`, `rtl/audio/audio_spdif_tx.v`,
`sim/audio/tb_audio_digital_out.v`, the audio PLL's settings (`hw/gowin/ip/pll_aud.mod`), the pins and the constraint lines.

## 0. Documents used

The Gowin documents were read when the audio output was first designed and **not opened again for this document**;
the figures below are copied from that reading.

| Document | Sections | Used for |
|---|---|---|
| DS1239-1.0.3E GW5AST data sheet | 3.3.6, table 3-18 | PLL limits: phase detector 19 to 81.25 MHz, VCO 650 to 1,300 MHz; output jitter below 4 % of the period under 100 MHz |
| UG306-1.0.9E Arora V Clock User Guide | 2.1, 5.1 | 16 global clock lines; the PLL's dividers; only output 0 has a fractional divider (eighths) |
| SUG940-2.0E Timing Constraints | 5.2.2, 5.2.5 | `create_generated_clock`, `set_clock_groups` |
| SUG1018-1.6E Physical Constraints | 2.7 | `CLOCK_LOC "net" BUFG[n] = CLK` |
| Dock schematic 4071f | PMOD sheet, DAC+PA sheet | the PMOD2 balls; the PT8211's three pins (read here) |
| Sipeed example `audio/audio_music/src/audio.cst` | | the PT8211's three pins (read here) |
| hdl-util/hdmi sources (`rtl/vendor/hdmi/`) | `packet_picker.sv`, `audio_clock_regeneration_packet.sv` | how the core takes samples and makes its clock regeneration packets (read here) |

Features used: two PLLs in a row, the fractional divider of output 0, two global clock lines. Not used: any
dynamic PLL setting, phase shift, the PLL's reset.

## 1. The outputs

| Output | Carries | Pins | Clock |
|---|---|---|---|
| Headphone and speaker DAC (PT8211) | the audio ring, 16 bits, interpolated to 384 kHz (WP A1, unchanged) | bit clock E22, word clock F24, data G24 | `clk_dsp` (fractional tick) |
| HDMI audio | the 48 kHz stream, 16 bits, in HDMI audio sample packets | the HDMI socket | pixel clock; the rate follows the stream |
| S/PDIF | the 48 kHz stream, 24-bit frames (top 16 bits used) | B21 = PMOD2 (J26) pin 12 | audio clock 49.152 MHz |
| I2S (Philips format, 24 bits in 32) | the same; bit clock 3.072 MHz, word clock 48 kHz, data, master clock 12.288 MHz | B20, A20, B19, A19 = J26 pins 9, 10, 7, 8 | audio clock 49.152 MHz |

J26 pins 1-2 are 3.3 V, 3-4 ground. A TOSLINK transmitter module needs pin 12, 3.3 V and ground. A Pi-type
DAC board must be one that needs no I2C set-up (PCM5102A class). J26 pins 5, 6 and 11 stay free.

**PT8211 pin fix.** The pin file and docs/BOARD.md had the bit clock on G24 and the data on E22. The dock
schematic (PT8211 pin 1 BCK = net `I2S_BCLK` = E22, pin 3 DIN = net `I2S_DIN` = G24) and Sipeed's example agree
on the opposite. Corrected in `gowin/p1/sdr.cst` and docs/BOARD.md. With the swapped pins the DAC would
have been silent.

## 2. The 48 kHz stream

`rtl/audio/audio_out_src.v` makes one stream of 16-bit stereo samples in `clk_dsp`, one clock pulse per
sample, that never stops:

- While the audio engine runs, each sample it hands to the PT8211 path (the ring reader's 48 kHz tap) is passed
  on unchanged.
- When the engine delivers nothing for 2,516 clocks (audio off, ring empty), a zero sample is sent, then one
  every 2,500 clocks: 120 MHz / 2,500 = 48 kHz exactly.
- With `audio.out_ctrl.tone` = 1 every sample is replaced by a 1 kHz sine (amplitude 20,000 of 32,767, both
  channels). It needs neither firmware nor DDR3: the first board test of all three digital outputs.

The stream goes to `audio_digital_out` (S/PDIF, I2S) with 8 zero bits below, and to the HDMI encoder. The volume
register is not applied anywhere yet (it never was; the PT8211 path ignores it too).

Registers (`hw/regmap/audio.toml`, block 0xE809_0000):

| Register | Bits | Meaning |
|---|---|---|
| `out_ctrl` 0x020 | 0 `spdif`, 1 `i2s`, 2 `tone` | reset value 3: S/PDIF and I2S on, no tone. A 0 holds that output's pins low |
| `out_status` 0x024 | 0 `pll_lock`, 1 `run`, 2 `live`, 15:8 `slips`, 23:16 `errors` | audio PLL locked; S/PDIF and I2S sending samples; the stream comes from the engine; counters wrap at 255 |

HDMI audio has no switch: it carries the stream, which is zeros when nothing plays.

## 3. The audio clock

48 kHz x 1,024 = 49.152 MHz = 50 MHz x 3,072 / 3,125. One PLL cannot make it (3,125 = 5^5; the phase detector
needs 19 MHz or more). Two in a row can:

| PLL | Setting | Output |
|---|---|---|
| DSP PLL (`gowin/p1/ip/gowin_pll_dsp.mod`), **changed** | VCO 50 x 24 = 1,200 MHz (was 50 x 15 = 750); output 0 = / 10 since 2026-10-12 (/ 8 for 150 MHz; was / 5); new output 1 = / 25 | `clk_dsp` 120 MHz (150 MHz at first); `clk_48m` 48 MHz |
| Audio PLL (`gowin/p1/ip/gowin_pll_aud.mod`), new | input 48 MHz, VCO x 16 = 768 MHz, output 0 = / 15.625 | `clk_aud` 49.152 MHz |

1,200 MHz is the only VCO frequency in the allowed 650 to 1,300 MHz that gives both 150 and 48 MHz from
50 MHz. Both new clocks are asked onto global clock lines 8 and 11 in the pin file: **two of the chip's 16
lines**. `clk_48m` has no register on it; it only feeds the audio PLL.

The audio PLL's lock is a status bit. The chip's reset does not wait for it. **Whether the second PLL locks
behind the first is a board question.** Jitter: Gowin guarantees under 0.8 ns (4 % of the period), enough for
S/PDIF; whether a 110 dB DAC board reaches its figure must be measured.

All five pins are registers on `clk_aud`: master clock / 4, bit clock / 16, word clock / 1,024, one S/PDIF
line cell = 8 clocks.

**Slips.** The engine's sample tick is a rounded phase accumulator on `clk_dsp`: its 48 kHz is 0.011 ppm
fast against the audio clock's exact 48 kHz, one sample too many every 17 minutes. `audio_digital_out` keeps 8 samples
between the two clocks and takes the extra sample out over 64 frames by a straight-line blend; outside a slip
the output words are the input words bit for bit. While the engine is off the stream runs at exactly 2,500
clocks and there are no slips.

Constraints (`gowin/p1/sdr.sdc`): `clk_48m` and `clk_aud` as generated clocks; `clk_aud` asynchronous
to `clk_dsp` (every signal between them goes through synchroniser registers or is held while it is read).

## 4. HDMI audio

### 4.1 What was wrong

docs/P1_TOP.md section 9 says the full-chip build removes the audio packets. **It does not.** In the netlist
of the full-chip synthesis of master 8c778a2 (build folder `impl/ls1`, 2026-10-12) the whole audio path is
there: the tone table as a ROM, the sample buffer (256 registers), the packet registers (128), the clock
regeneration packet (46 registers). The modules `audio_sample_packet` and `audio_info_frame` are missing from
the hierarchy table because they hold no register: one is wiring and parity, the other constants, and Gowin
merges such logic into the neighbouring modules. The two video info-frame modules are missing from the table
for the same reason.

Of the three suspects, checked against that netlist and the source:

| Suspect | Finding |
|---|---|
| Tone generator on the made-up clock | Present in the netlist (as a ROM clocked by `clk_audio`). Not a fault by itself, but it was the only source: no radio audio reached HDMI |
| `clk_audio` a register output on ordinary wiring | True. It clocked about 75 registers and the ROM, and would have needed one of the 16 global lines |
| Accumulator step gives 96 kHz | True: 2,748,779 x 150 MHz / 2^32 = 96,000. The sink would have got a 2 kHz tone at twice the announced rate |

A fourth: Gowin built the core's sample buffer (a three-dimensional array) as "RAMREG" registers, a
construction it is known to get wrong (docs/TANG_LESSONS.md section 8, Gowin tool traps). Whether it was wrong here was not
examined.

### 4.2 What was changed

- **No 48 kHz clock any more.** `rtl/video/sdr_hdmi_video.v` takes the 48 kHz stream in `clk_dsp`,
  holds each sample and carries a toggle into the pixel clock. The vendored core gets a strobe, one pixel
  clock long, per sample: its transfer register and its sample counter (two `always` blocks, in
  `packet_picker.sv` and `audio_clock_regeneration_packet.sv`) now run on the pixel clock while the strobe is
  high. The core's port is still called `clk_audio`. One clock, one constraint and one global line less.
- **The rate is the stream's.** The core measures the pixel clocks per 48 samples (CTS) from the strobes, so
  the sink's audio clock follows the real stream: 48 kHz.
- **The sample buffer is a packed vector** (`packet_picker.sv`): plain registers, no "RAMREG".
- **The source is the radio's stream** (section 2), with the test tone as a register bit. The old
  `rtl/video/audio_tone_gen.v` and the accumulator in the top level are gone.

The three changes to the vendored core are noted in each file's header and in `rtl/vendor/hdmi/README.md`.

## 5. Constraint lines for the HDMI serializers (LS2 d)

Three `set_false_path -to` lines for the `RESET` pins of the three OSER10 serializers
(`u_hdmi/u_hdmi/serializer/gwSer0..2/RESET`): the reset is held for many clocks, so its timing to the 5x
pixel clock does not matter. They only take effect in place-and-route, which the full build runs.

## 6. What is verified

| Item | How | Result |
|---|---|---|
| `audio_digital_out` (S/PDIF coding, I2S format and clock shapes, slips, stop and restart, off) | `sim/audio/tb_audio_digital_out.v`, a test with pin-level decoders | PASS, 25 checks |
| Stream source, registers, tone and engine samples through to the I2S pins | `sim/audio/tb_audio_outputs.v` (new) | PASS, 20 checks |
| HDMI audio: samples of both channels decoded from the data islands, sample-exact, with the strobe and the packed buffer | `sim/video/tb_hdmi_video.v` (changed: stream input, right = complement of left) | PASS, 82 packets, 0 errors |
| Core with the new ports | `sim/top/tb_sdr_core.v` (run before the last change to `packet_picker.sv` and the tone table, which it does not contain or exercise) | PASS |
| Full chip synthesis: both PLLs generate, the audio modules are in the hierarchy | `gowin/p1/build.sh --syn`, `tools/gowin_hier.py` | done, section 7 |

Not verified: anything on a board; place-and-route (pin file lines, global lines, timing of `clk_aud`, the
three false-path lines); the lock of the second PLL; `tools/video/tb_hdmi_video_full.v` (changed the same
way as the short test, compiles, not run).

## 7. Size (synthesis only)

`gowin/p1/build.sh --syn` of this branch (build folder `impl/aud2`, 609 s) against the same run of master
8c778a2 (`impl/ls1`), read with `tools/gowin_hier.py`:

| | LUT | ALU | Registers | Block RAM | LUT-RAM | DSP |
|---|---|---|---|---|---|---|
| Whole chip, master | 51,233 | 18,626 | 51,684 | 215 | 542 | 91 |
| Whole chip, this branch | 51,683 | 18,770 | 52,491 | 214 | 554 | 91 |
| Difference | +450 | +144 | +807 | -1 | +12 | 0 |

| Instance (this branch) | LUT | ALU | Registers | Block RAM | LUT-RAM |
|---|---|---|---|---|---|
| `u_core/u_aout` (S/PDIF, I2S, slip buffer and blend) | 476 | 166 | 655 | 0 | 12 |
| of which `u_spdif` | 97 | 0 | 81 | 0 | 0 |
| `u_core/u_aout_src` (stream source, tone table) | 95 | 0 | 69 | 0 | 0 |
| `u_core/u_au_regs` (was 112 LUT, 163 registers) | 136 | 14 | 182 | 0 | 0 |
| `u_hdmi` whole (was 948 LUT, 594 registers, 1 block RAM) | 799 | 49 | 689 | 0 | 0 |
| HDMI `packet_picker` (sample buffer 256, packet registers 128, transfer 32, ...) | 183 | 22 | 484 | 0 | 0 |
| HDMI `audio_clock_regeneration_packet` | 8 | 22 | 46 | 0 | 0 |
| HDMI `packet_assembler` | 427 | 4 | 45 | 0 | 0 |

Clocks: one PLL more (6 of the chip's PLLs in use), two clocks more (`clk_48m`, `clk_aud`), one less
(`clk_audio`). No "RAMREG" register is left in `packet_picker`.

The synthesis log still prints "module audio_sample_packet ... is swept in optimizing" (NL0002), and the same
for `audio_info_frame` and the two video info-frame modules. That message is the origin of the report in
docs/P1_TOP.md: it means the module's shell is gone because it holds no register, not that its function is.

A first run of this branch (`impl/aud`) showed 49,000 LUT in `packet_picker`: the packed buffer was indexed
with a computed position. It is now written and read at constant positions only.

## 8. Left to do

- Board: PT8211 sounds; second PLL locks (`out_status.pll_lock`); tone on S/PDIF, I2S and HDMI; then radio audio.
- The volume register applies to no output.
- Firmware knows the two new registers only through the generated accessors; nothing uses them yet.
- docs/P1_TOP.md section 9 still says the audio packets are swept (not edited here: another work package's file).
- USB audio: deferred.
