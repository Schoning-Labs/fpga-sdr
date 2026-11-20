<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# LS6: the bring-up ladder and the loader's flash layout

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Written 2026-10-12, branch `ladder`; rebuilt 2026-10-13 on Gowin V1.9.12.04 with the bus at 80 MHz (section 2). **Nothing here has run on a board.** The loader half of this work package is in
[C2_LOADER.md](C2_LOADER.md) "Flash layout".

## 1. What was built

Three small bitstreams, each adding one part, so that a failed first power-on names the part that is faulty
instead of showing a dark board. One top level (`rtl/top/ladder_top.v`), one build script
(`gowin/ladder/build.sh`, `STEP=1|2|3`), its own pins (`gowin/ladder/ladder.cst`) and timing
(`gowin/ladder/ladder.sdc`). `rtl/top/sdr_top.v` and `gowin/p1/sdr.cst/.sdc` are not touched.

| Step | In it | Tests it makes possible |
|---|---|---|
| 1 | the four PLLs, the AE350, the 1 GB DDR3 controller and bridge, the debug serial port, the six LEDs, a register page, a counter for every clock | LEDs; the program's report over the serial port: PLL locks, DDR3 ready, register read-back, every clock's rate against the 50 MHz oscillator, the machine timer's rate |
| 2 | step 1 + HDMI colour bars, 1080p60 (pixel clock 148.75 MHz, `gowin/ladder/ladder.sdc`; the radio itself runs 1080p30, see the note under section 3 step 8) | the above + the **DDR3 size probe, address-line test and pattern tests** run by the program (the processor's data memory is the DDR3), video frame count, eight colour bars on the monitor |
| 3 | step 2 + a 1 kHz tone on the PT8211 DAC (bit clock E22, word select F24, data G24) | the above + audio frame count, a tone on the headphone jack |

The DDR3 controller and its bridge are in all three steps, because the processor's data memory is the DDR3 and
the processor is held in reset until the controller reports ready (the lesson of
Sipeed's reference design). What step 2 adds is the **use** of that memory: the program runs the size probe,
the address-line test and the pattern tests only when it finds step 2 or 3 (register 0x04). The program itself needs no DDR3 to start: it runs
from flash with its stack in the processor's own 64 KiB data memory. Step 1 therefore tells "PLLs, AE350,
register bus, serial port, DDR3 ready flag" apart from "DDR3 data is wrong".

**LEDs (active low on the board, the bitstream inverts them):** 0 blinks from a counter on the 50 MHz
oscillator (no PLL, no processor); 1 DDR3 PLL locked; 2 DSP PLL locked; 3 video PLL locked; 4 DDR3
controller initialised and calibrated; 5 toggled by the program once per report. **The processor is held in
reset until LED 4 comes on**, so a dead DDR3 shows as LED 4 dark and a silent serial port, not as a program
that hangs.

**The program** (`fw/tr-ladder`, 22 KiB, runs in place from flash at 0x8000_0000, written at chip offset
0x60_0000): prints one line at once for each of seven guesses of the UART's input clock (80, 100, 50, 24, 25, 20,
10 MHz at 115,200 baud: 80 MHz is the APB clock, 100 MHz was before 2026-10-13; no document says which clock divides the UART), runs its checks, then prints the
whole report again and again, once per guess, each with a header that names the guess. Exactly one guess is
readable; that value is what `tr-ae350`'s UART setup and the loader must use (`LADDER_UCLK_HZ=<Hz>
tools/ladder_fw.sh build` keeps one guess). Report lines read `<check>: PASS|FAIL (<detail>)`, then
`result: N passed, M failed`.

Register page (0xE800_0000, `rtl/top/ladder_regs.v`): 0x00 `LADR`, 0x04 step, 0x08 commit, 0x0C LED word, 0x10
status (DDR3 ready, three PLL locks), 0x14 scratch, 0x40 milliseconds, 0x44 audio frames, 0x48 to 0x58 clock
counters, 0x5C video frames.

## 2. Results of the builds

Rebuilt 2026-10-13 at commit `ca74878` (Gowin EDA V1.9.12.04, place option 3, route option 1, 5 % timing margin: the
design clocks are built 5 % faster than they run). Changes since the first build: AHB and APB 80 MHz (docs/DECISIONS.md
2026-10-13), clk_dsp 120 MHz (built as 126), the PT8211 pins E22 / F24 / G24 (were swapped in the full chip, not in the ladder), the 1 GB
DDR3 bridge, the flash clock declared in `ladder.sdc` (`flash_sysclk`, as in the full chip), the DDR3 user clock asynchronous to the AHB/APB clocks
(first rebuild: one hold failure of -2.1 ns from the DDR3 init flag into the register page's synchroniser, an artefact of the missing
declaration), synthesis fan-out limit off (it already was in the ladder files).

| Step | Logic | CLS | Block RAM | Build time (synthesis + place and route + bitstream) | Verdict (`tools/gowin_verdict.py`) |
|---|---|---|---|---|---|
| 1 | 5,966 (5 %) | 6,210 (9 %) | 32 (10 %) | 145 s | setup 0, hold 0 |
| 2 | 6,421 (5 %) | 6,540 (10 %) | 32 (10 %) | 145 s | setup 0, hold 0 |
| 3 | 6,527 (5 %) | 6,614 (10 %) | 33 (10 %) | 146 s | setup 0, hold 0 |

Step 3 clocks reached against built: DSP 341 MHz against 126, pixel 260 against 156.2, AHB 116 against 80, DDR3 user clock 169
against 100. Worst hold slack 0.17 ns (inside the DDR3 bridge). The bitstreams are `G:/proj/fpga-sdr/impl/keep/ladder_ca74878/step<n>/ladder_top.fs`
(the build folders are git-ignored; the program is `tr-ladder.bin` in the same folder, 22,364 bytes). The `.fs` is the text form
of the bitstream (about 37 MB; the flash gets 5 MiB). No clock was put on a global line by hand.

## 3. First power-on, step by step

Preparation, on the PC (once): build the program, `tools/ladder_fw.sh build`. Connect the board's USB-C
debug port; it gives the Gowin programmer's JTAG and a serial port (115,200 baud, 8N1). Build the three
bitstreams (`STEP=n OUT_DIR=<absolute path> gowin/ladder/build.sh`, 1 to 3 minutes each plus synthesis) or use the
files from the build folder.

For each step n = 1, 2, 3 (do not go on until the step passes):

1. Write the two files into the flash: `tools/ladder_fw.sh write n` prints the two Gowin programmer commands
   (bitstream at flash offset 0, program at offset 0x600000); `tools/ladder_fw.sh write n --go` runs them.
   If the programmer refuses the device, set `DEVICE=GW5AST-138B`. If it complains about the address
   option, use the programmer's window: bitstream at 0, the program file as "C Bin" at 0x600000.
2. Power the board off and on. Wait 20 seconds (the FPGA loads its configuration at 2.5 MHz).
3. **LED 0 blinks (about once in 1.3 s).** No blink: the FPGA did not load the bitstream. Check the
   programmer's device name (B or C), the power, and that the write finished. This is not a design fault.
4. **LEDs 1, 2, 3 are on.** One that stays off: that PLL did not lock (1 = DDR3 PLL, 2 = DSP PLL, 3 = video
   PLL): the oscillator, or that PLL's setting.
5. **LED 4 is on** (within a second). Off with 1 to 3 on: **the DDR3 does not come up** (the controller's
   initialisation or read calibration fails): the memory chips, their 1.5 V supply, a DDR3 pin, or the
   controller's settings. The processor is held in reset, so there is no serial output: that is expected.
   Nothing past this point can be judged until LED 4 is on.
6. **Open the serial port.** Within a few seconds seven header lines appear, `=== tr-ladder: this line is readable
   if the UART clock is N kHz ...`. **Write down which one is readable** (the other six are garbage). No
   readable line at all, but LED 4 on: the program is not running: the program was not written, or it is not
   at the address the processor starts from (the processor's 0x8000_0000 is chip offset 0x60_0000, an
   inference, [C2_LOADER.md](C2_LOADER.md)): write it again, check the programmer's address, the serial port's
   number and speed. Garbage in all seven: the baud rate or the guesses; note the UART's clock from the PLL
   (APB 80 MHz, DDR bus 50 MHz, RTC 10 MHz) and rebuild with another `LADDER_UCLK_HZ`.
7. **Read the report** (step 1 starts printing after about 2 seconds, step 2 and 3 after the memory tests, about
   a minute). LED 5 toggles with every report. Every line should say PASS; the last line counts. A FAIL names the part:

   | FAIL line | Part |
   |---|---|
   | register page, register write and read back | the bus from the processor to the logic (AHB window) |
   | PLL locks | the PLL that says no (see 4) |
   | DDR3 controller | see 5 |
   | oscillator time base | the 50 MHz oscillator or the counter |
   | DSP, pixel, AHB, DDR-bus, RTC clock | that PLL output (the detail line gives the measured kHz) |
   | machine timer | information only: the timer's real rate (used by the loader's 2 s window and `tr-ae350`) |
   | DDR3 size | the size the data lines/chips give: 1,024 MB expected; 512 MB = one chip missing; a repeat at other sizes = an address line |
   | DDR3 address lines | one address line open or shorted (the detail gives the first bad address) |
   | DDR3 memory test, top of memory | data lines, byte lanes, timing: the detail gives the first wrong word and the bits |
   | HDMI video frames | the video PLL, the pixel clock (expected 12 frames in 200 ms) |
   | audio frames | the 120 MHz clock and the audio block (expected 4,800 frames in 100 ms) |

8. **Step 2 and 3: look at the monitor** (HDMI port 0): eight vertical colour bars, white, yellow, cyan, green,
   magenta, red, blue, black. No picture with the frame count passing: the HDMI cable, the TMDS pins or the
   serializers (the logic is running). The ladder is still built for 1080p60, which on the board's HDMI pins gives a black picture (docs/DECISIONS.md 2026-10-22; the radio runs 1080p30 with a 74.167 MHz pixel clock), so the frame count can pass at 12 in 200 ms while the monitor shows nothing; a 1080p30 ladder would expect 6 frames in 200 ms, and its limits in `fw/tr-ladder/src/main.rs` would have to change with it. **Step 3: listen at the headphone jack:** a clean 1 kHz tone, quiet
   (-15 dBFS). Silence with the frame count passing: the PT8211 or its three pins (E22, F24, G24).
9. Step 3 is the end of the ladder. The next rung is the whole design (`gowin/p1/build.sh`, LS1), and the
   loader: write `stage0` at 0x600000 with the programmer, power-cycle, and read its first lines: the
   flash chip's JEDEC id and "flash mapping ... confirmed". Only then send an image with the `F` command.
   If the mapping line says DIFFERS, stop and read [C2_LOADER.md](C2_LOADER.md) "Flash layout".

What to send back after the first try: which LEDs were on, which UART guess was readable, the whole text of
one report, and what the monitor and the headphones did.

**Changed since the first version (2026-10-13):** seven UART guesses, the first is 80 MHz; the "AHB clock" line expects 80 MHz
(was 100); everything else in the table above is as before.

## 3a. Arrival-day checklist (numbered, in order)

Everything in steps 1 to 4 is ready on the PC. Commands are for a Git-Bash window in the repository root.

1. **Connect:** power, the USB-C debug port to the PC, an HDMI monitor on HDMI port 0, headphones on the jack. No HL2, no antenna.
   Find the board's serial port number (Device Manager, "COMn"; 115,200 baud, 8N1).
2. **Ladder step 1.** Build the program once, then write step 1:
   `tools/ladder_fw.sh build`
   `BITSTREAM=G:/proj/fpga-sdr/impl/keep/ladder_ca74878/step1/ladder_top.fs tools/ladder_fw.sh write 1 --go`
   (use the `FW=` variable for another program file; if the programmer refuses the device, add `DEVICE=GW5AST-138B`).
   Power-cycle, wait 20 s, then check as in section 3: LED 0 blinks, LEDs 1 to 3 on, LED 4 on, seven header lines on the
   serial port (write down which one is readable), report all PASS. Stop here if not and use the FAIL table.
3. **Ladder step 2** (same command with `step2`), then **step 3** (`step3`). Section 3 steps 7 and 8: report PASS, eight colour bars
   on the monitor, 1 kHz tone on the headphones.
4. **Set the UART clock.** Put the readable guess (kHz times 1000) into `UART_CLOCK_HZ` in `fw/tr-ae350/src/board.rs`
   (`board::ae350`; it is 80,000,000 now, a guess). If the report's "machine timer" line shows a rate other than 80 MHz, put that
   into `TIMER_HZ` there too. Commit.
5. **Build the full chip firmware:** `tools/ladder_fw.sh chip` (stage-0 loader `fw/target/ladder/stage0.bin`, the FT8/FreeDV image
   `fw/target/ladder/ft8fw.img`, the sender `fw/target/release/tr-loader-send`). Set `TR_CALL` and `TR_GRID` first for the
   owner's call sign (without them the image is N0CALL and its transmit switch stays locked).
6. **Build the full-chip bitstream** (about 35 minutes; not yet done at 80 MHz, see section 4):
   `GOWIN_PLACE_OPT=3 GOWIN_ROUTE_OPT=1 OUT_DIR=<absolute folder> bash gowin/p1/build.sh`
   and accept it only with 0 failing setup and hold end points (`tools/gowin_verdict.py` is run at the end).
7. **Write the chip and the loader:** `BITSTREAM=<folder>/sdr_top/impl/pnr/sdr_top.fs tools/ladder_fw.sh write-chip --go`
   (bitstream at flash offset 0, stage-0 at 0x600000; it replaces the ladder program).
8. **Put the firmware into the flash:** start the sender first, it waits for the loader's prompt:
   `fw/target/release/tr-loader-send --serial COMn --baud 115200 --image fw/target/ladder/ft8fw.img --cmd flash`
   (`tools/ladder_fw.sh write-chip` prints this line with your `SERIAL=COMn`), then power-cycle the board. The loader prints the flash
   chip's JEDEC id and "flash mapping ... confirmed" (if it says DIFFERS, stop: [C2_LOADER.md](C2_LOADER.md) "Flash layout"),
   takes the image into the inactive slot, checks it, and switches the active slot. `--cmd run` instead starts the image from
   RAM without touching the flash (use it for the first try).
9. **Power-cycle once more:** the loader waits 2 s for the sender, then starts the active slot. The console shows
   "receivers in the chip: 4" and the monitor shows the FT8 screen. Send back the serial text, which LEDs were on, and what the
   monitor and headphones did.

## 4. Not verified, and left out

- Everything. No bitstream has run on the board; the program has never run (it compiles for the target and its
  section addresses were checked with objdump). All numbers in the tables are place-and-route and synthesis
  results of the tools.
- The Gowin programmer's options for the two writes are taken from the help text
  only (`--run 54` bitstream to the external flash, `--run 56` program file, `--spiaddr`). The device name
  (138B or 138C) is open.
- The mapping of the processor's 0x8000_0000 onto the chip (offset 0x60_0000) is an inference; the loader
  checks it at start-up, the ladder program only proves that it runs.
- The memory tests are small (512 KiB-equivalent in four patterns over 80 KiB plus the address lines up to
  512 MB) because the program runs from flash without a cache; they find a dead data line, address line or
  byte lane, not a rare weak cell.
- The 256 MB fall-back of `TR_DDR=256` (the AE350's own DDR3 controller, one chip) has no ladder build; it is the
  way to tell a board fault from a fault of the bridge, and adding it needs a second top (the p1 top has the
  switch).
- HDMI audio is not in the ladder (LS5 is about it); the colour bars carry no sound.
- The ladder uses the clocks of the full design (120 MHz DSP, 300 MHz DDR3 memory clock, 80 MHz AHB), except the pixel clock, which is the 1080p60 one (148.75 MHz) here and 74.167 MHz in the radio; if they change again, the
  ladder's PLL list and `HZ_*` constants in `fw/tr-ladder/src/main.rs` follow.
- **The full chip at 80 MHz AHB has not been through a complete build** (the owner stopped the run on 2026-10-13: the chip
  changes again first). Only the three small ladder builds show that the 80 MHz bus works with Gowin's flash controller.
