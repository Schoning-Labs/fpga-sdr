<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# How the radio got the way it is: decisions, attempts and what went wrong

This is the record of how the radio was designed and brought up, what was tried at each step, what the measurements
said, and why a design was kept or dropped. It is written for someone who wants to learn from the mistakes as much as
from the parts that worked, so the failures are told with the same care as the fixes. The numbers come from the
benches, the Gowin reports, the board runs and the git history of the `master` branch. Where a cause was never
established, the text says so instead of guessing one afterwards.

A few words that come up all the time:

- **The board** is the Sipeed Tang Mega 138K Pro with its dock: a Gowin GW5AST-138C FPGA with a hard RISC-V
  processor (the AE350, an Andes A25 core at 800 MHz), two 512 MB DDR3 chips, an HDMI output, one RJ45 network socket
  and two SFP+ cages.
- **The HL2** is the Hermes-Lite 2, a small HF transceiver with a 12-bit ADC and DAC at 76.8 million samples a second.
- **clk_dsp** is the main logic clock of the radio (120 MHz in the shipped design, 150 MHz at first).
- **Failing end points** are the paths Gowin's timing report says miss their clock. A build "closes" when there are
  none, for setup and for hold.

## 1. Why the HL2 sends raw samples

A normal HL2 does its own receiving: its small FPGA mixes and decimates up to four receivers and sends their baseband
samples (at most 384 kHz wide each) to a PC over the openHPSDR protocol. The radio needed more than that from the
start, i.e. a full-band view of 0 to 30 MHz with a zoom, four to eight independent receivers, all digital modes on
the box itself, and later the FT8 front end in logic. None of that fits into the HL2's Cyclone IV, which is already
full with the stock design, and a baseband stream would have tied every receiver to what the HL2 can decimate.

So the author decided early that the HL2 is only the RF front end, and that everything else happens on the Tang. The
HL2 got its own gateware (the `hl2-rawfront-release` of the author's Hermes-Lite2 fork), which removes the stock
receivers and sends every 12-bit ADC sample, 921.6 Mbit/s of raw data, over the HL2's own gigabit Ethernet port in
9,000-byte jumbo UDP frames (931 Mbit/s on the wire, about 7 % to spare), and takes 12-bit transmit samples back at
the same rate. Removing the receivers freed about 6,800 logic elements, 20 of the 66 memory blocks and all 56 DSP
blocks of the HL2, which is what made room for its transmit FIFO, a register bridge and the transmit interlock in
logic. Two custom link boards (LVDS over a SlimSAS cable, and a fibre link with serializer chips) were worked out
before that and dropped, because both needed a custom board, the connector was rated for only 250 matings and the
serializer chips were hard to buy. The price of the Ethernet route is that nothing is retransmitted, so a lost frame
is lost, and the far side needs a gigabit port of its own for the HL2.

The protocol to the rest of the world was settled at the same time: VITA-49 for data streams and TCI for control, and
no Hermes or openHPSDR protocol, because the radio is meant to stand on its own with a monitor on its HDMI output and
no PC needed to operate it.

## 2. What goes into logic and what stays in Rust

The first split put the receivers' mixing and decimation in logic and everything per receiver after that (channel
filter, demodulator, AGC, noise blanker) in Rust on the AE350. The CPU cost of that split was then measured instead of
estimated, by running the real Rust kernels under QEMU with instruction counting. It came out at 2 to 4 times the
estimate: the author's normal use took 55 to 66 % of the core and heavy use 136 to 182 %, before FT8, and FT8 decoding
alone cost about 10 % of the core per receiver. Eight FT8 receivers would have needed 85 % on their own, so the old
split could never work.

The rule applied after that was simple: a function goes into logic if its algorithm is fixed and its cost is per
sample, and it stays in Rust if the algorithm still changes, needs large state or search, or runs rarely. The noise
blanker, channel filter, demodulators, AGC and S-meter moved into a time-shared receiver back end in logic, the audio
mixer moved into logic and is clocked in HL2 time (so no resampling is needed anywhere in the audio path), and the
expensive half of FT8 (spectrogram, Costas sync search, per-candidate down-conversion and soft symbols) became an FT8
front end in logic. The decoders' back halves (LDPC, OSD, unpacking, subtraction), noise reduction, the GUI and all
control stay in Rust. The new budget came to 38.9 % of the core for normal use and 51.4 % for heavy use, both with FT8
on all eight receivers. A software change found in the same work mattered almost as much: the A25 has a hardware
double-precision unit that the standard Rust target does not use, and switching it on cut FT8 decode from 2.97 G to
0.89 G instructions per busy slot (section 10).

## 3. The receivers

The receiver chain started as a port of the HL2's own openHPSDR code: a CORDIC mixer at the input rate, a 3-stage CIC
decimating by 10 to 7.68 Msps, a 5-stage CIC decimating by 40, 20, 10 or 5, and a 65-tap compensating FIR decimating
by 4, which gives 48, 96, 192 or 384 kHz per receiver. Several things changed on the way:

- **The CORDIC gave way to a table mixer.** A quarter-wave sine table of 1,024 entries in one block RAM, with a
  first-order Taylor correction (two small multiplies), replaced the CORDIC in the receivers, the zoom and the
  transmitter. It keeps the CORDIC's gain and sign convention exactly, so nothing downstream changed, and its own
  spurs went from 98.4 dBc worst case to 117.3 dBc, while the logic of eight receivers fell from about 42,000 to about
  18,600 cells by yosys' count. The latency also dropped from 17 to 7 samples.
- **Two defects showed up only with a realistic input.** Every early bench drove `adc_valid` high on every clock, but
  the real HL2 samples arrive in bursts at about 51 % of the clocks. With gaps, the mixer's valid flag stayed high once
  its pipeline was full, so the bank decimated by clocks instead of by samples, and the shared output arbiter repeated
  a sample when no other receiver was waiting. Both were found by the end-to-end test of the back end against a
  bit-exact Rust model and fixed in the RTL and the model together. Since then every receiver bench drives a bursty valid
  pattern as well as a continuous one.
- **Shared variable CICs, and where their state lives.** The second CIC of every receiver became one of two shared
  engines working through many contexts in turn. Moving their state into block RAM was tried and stayed bit-exact, but
  it needed about 44 block RAMs for the bank instead of 8, and its place-and-route did not finish in 90 minutes, so
  the state stayed in flip-flops at first. When the full chip later failed to place for lack of registers (section 7),
  the same state went into LUT RAM instead, one word per context (it had been 645 registers per context), which saved
  the registers without spending block RAM.
- **The FIR multiply-accumulate is instantiated.** Gowin's synthesis maps an inferred multiply-accumulate with load
  into the DSP block wrongly (section 15), so the FIR uses an instantiated `MULTALU27X18`.

The author asked for four to eight receivers. The chip holds eight receivers without the zoom, or four with it, and the
author chose four with the zoom (section 7). The receiver count is one build setting, `TR_NRX`, the register map keeps
the eight-receiver layout so no address ever moves, and the chip reports how many receivers it has so one firmware
image runs on both variants.

## 4. The full-band spectrum and its FFT

The full-band view is a 16,384-point streaming FFT of the raw 12-bit stream, with a 4-term Blackman-Harris window,
which gives 4.6875 kHz bins and 4,687.5 transforms a second with no dead time, so averaging gains the full
sensitivity. Three FFTs were compared. ZipCPU's `dblclockfft` needed about six times the block RAM at 16k points, 36
multipliers, and had about 10 dB more arithmetic noise in its default configuration. Gowin's FFT IP is encrypted (so
it cannot be simulated in iverilog) and is documented only as a load, compute and unload core that cannot take a
continuous stream. So the radio got its own radix-2^2 single-path delay-feedback FFT, bit-exact with a Python model,
whose spurious-free range for a -1 dBFS tone (93.3 and 94.4 dBc) equals a double-precision FFT of the same 12-bit
samples, so the limit is the ADC's own.

Bringing up the spectrum pipeline found one real fault worth knowing about: the noise floor was wrong because a
column-start table was generated wrong and a line buffer swapped one frame early, which a short test with few averages
did not show. The long test with the real 156 averages per line is kept as its own script for that reason.

## 5. The zoom receiver

The zoom is one more down-converter with its own decimation plan (76.8 MHz / 25 down to 48 kHz in powers of two, later
down to 3 kHz) feeding a 4,096-point complex transform, so its bin width shrinks with the span. Its story is mostly
about room on the chip:

- **Alias rejection.** The first version reached only 75.9 to 81.9 dB of alias rejection, and an anti-alias half-band
  filter plus a CIC droop compensation filter were added. The figures later settled at 79.6 dB for the widest span
  and 83.2 dB for the others.
- **Putting it into the chip.** Built alone it was fine. In the chip, the zoom added about 38,000 cells and 32 block
  RAMs to a design that routed at about 145,000 cells and had failed at 160,000. It had to lose 15,000 to 20,000
  cells. The variable CIC (eleven stages of 82-bit state in flip-flops) became a 12-tap binomial filter for the first
  decimation by 2 plus a serial CIC with its state in LUT RAM, and the narrow spans got a serial CIC of their own.
  Alone, the zoom went from 47,415 to 27,861 cells and reached 134.0 MHz.
- **One FFT for both views, rejected and then adopted.** During an early resource review the idea of sharing one FFT
  between the full band and the zoom was rejected, on the reasoning that two concurrent streams need two copies of the
  pipeline's memory anyway. The zoom diet found the better form: a 16,384-point radix-2^2 FFT is two stages followed by
  a complete 4,096-point FFT, so a zoom frame can be played into the full-band FFT behind its second stage, as a fifth
  block between two full-band frames, and the bins come out word for word as from a separate zoom FFT. The zoom now
  has no FFT of its own. Its windowed samples are collected in a 4,096-word frame buffer (8 block RAMs,
  `rtl/zoom/zoom_frame.v`) and go into the last twelve stages of the 16k FFT, which saved about 4,000 registers, 11
  block RAMs and about 20 DSP blocks. The cost is that a zoom frame takes 4,096 of the full band's samples, up to 5 %
  of the full-band line rate at the widest span and 0.08 % at 48 kHz.
- **The FT8 screen on the zoom waterfall.** Spans down to 3 kHz let the FT8 screen show the zoom's fine waterfall
  instead of one computed in software, and the author made that the default (the software waterfall stays as the
  fall-back).

## 6. Clocks: 150 MHz down to 120, and the processor bus down to 80

The logic was first designed for 150 MHz. A study of every block's real limit then found that no block needed it: the
tightest were the back end's channel filter unit (99.8 MHz) and the zoom's half-band filter at the widest span (122.9
MHz). 120 MHz is the one lower frequency where only a PLL divider changes, the 48 kHz audio sample is exactly 2,500
clocks and a microsecond is exactly 120 clocks, so the author moved `clk_dsp` to 120 MHz and every path got 1.67 ns
more. The zoom's half-band filter got a second multiplier per channel to keep up, and FT8 decodes arrive about 0.2 s
later after each slot (0.93 s instead of 0.74 s with eight receivers).

The AE350's bus clock was meant to stay at 100 MHz. But Gowin's own encrypted SPI flash controller inside the AE350
reached 91.7, 99, 106, 108 and 109 MHz in different layouts of the same design, so whether a build passed 100 MHz was
a matter of luck. The bus went to 80 MHz, which keeps clear of that spread and makes a register access from the CPU
about 9 % slower (about 245 ns instead of 225 ns).

## 7. Fitting the chip

The merged design (receivers, zoom, FT8 front end, compositor) first did not place at all: 10,919 registers could not
be placed, with registers at 86 % and slices at 92 %. A tool that lists the flip-flops of each unit by signal name
showed where they were, and a few of them were memories that should never have been flip-flops: the zoom's arrival
queue (128 words of 53 bits) because Gowin ignores `syn_ramstyle` in the attribute form, four copies of the compositor's
picture description where two do, and the back end's per-receiver settings with their 8-way selects. Moving that state
into LUT RAM, which the chip has plenty of, was the main fix.

The next wall looked like routing: the chip with four receivers and the zoom left 287 nets unrouted. A comparison
with an earlier passing build of another design showed two things. First, the same tree routed with 0 unrouted nets on Gowin V1.9.12.04, so "does not
route" had been the old V1.9.11.03 router. Second, the "77 to 80 % full" rule of thumb is in slices, and in
placed cells this radio stood at 1.31 times that passing build. What the design actually did wrong showed up
in timing: a handful of structures in which a signal crossed the chip, passed several LUTs and crossed back in one
clock. With three of those removed and synthesis' fan-out limit switched off, the chip met every clock even with the
clocks tightened by 5 %.

Eight receivers with the zoom did not fit, and the author chose four receivers with the zoom as the target chip. The
eight-receiver chip without the zoom routes and meets timing at 120 MHz and stays buildable. Usage limits of 70 to 85 %
were used as targets during this period. The author later removed every usage limit: the only test is whether a build
closes timing and works on the board, and usage figures are facts to report.

## 8. DDR3: from 256 MB to 1 GB, and the 400 MHz freeze

The first memory plan used the AE350's own shared DDR3 controller, which gives the CPU one 256 MB chip and the logic
one read and one write lane. The memory map already needed more than 256 MB for frame buffers, waterfall rings and raw
capture, so the author asked for the whole 1 GB. That route uses the AE350's "Customized Data Memory" (its memory bus
comes out into the logic), Gowin's DDR3 IP with 32 data lines, and a bridge from an earlier design by the same author between the IP, the CPU bus
and the radio's lane arbiters. Taken over as it was, the bridge would have written the first word of every write
burst to the wrong address and let the CPU read stale data that the logic had written, so its write lane was
rewritten. The 256 MB build stays as a fall-back (`TR_DDR=256`), so a board fault can be told from a bridge fault.

The board then taught three lessons:

- **The DDR3 PLL must sit next to the DDR3 banks.** Calibration never completes unless the DDR3 IP's PLL is placed at
  `PLL_L[0]` (0 of 3 builds calibrated without it, 6 of 6 with it).
- **Pin drives as Sipeed's example.** 12 on data, mask, address and control, 4 on CKE, 8 on CK and DQS. Drive 8
  everywhere also calibrates, and two days went on wrong bytes before a note saying "try 12 first" was
  read again. The radio's own constraint file had drive 8 on every DDR3 pin until its first board runs, against the
  standing rule.
- **The memory clock at 300 MHz.** At Sipeed's 400 MHz, reads with two or more in flight were lost or corrupted when much logic
  switched, and the processor then waited for ever on a read. A small reproducer froze with two reads
  in flight at full switching load and with eight from 63 % load, and passed 7 of 7 cases at 300 MHz (and at 350 MHz).
  Pin drive, termination, timing, placement, clocks, resets, caches and supply droop were all ruled out on the way.
  The radio moved to 300 MHz (VCO 1,200 MHz, controller clock 75 MHz, CL 5, CWL 5). The cost is that the logic's lanes
  drop from 800 to 600 MB/s at most, which still carries video, but leaves the FT8 sync search about three times
  slower (about 1.3 s instead of 0.42 s for eight receivers). The lane figures were not measured again at 300 MHz.

One more change was tried and reverted: feeding the DDR3 IP's reference from the oscillator net instead of the PLL's
copy, which had never run on a board. The PLL copy is the one known to calibrate, so the radio went back to it.

## 9. Starting the processor

The first board runs at 300 MHz loaded the bitstream fine and then said nothing on the UART, for the new build, for the
old 400 MHz build and for a third build with the drive and reference fixes. Because the AE350 is released only after
the DDR3 is ready, a DDR3 that does not calibrate gives exactly this picture, so the DDR3 was suspected first. The
actual cause was the AE350's own PLL: the core stays in its own reset unless that PLL is placed at `PLL_R[0]`, which
Gowin's AE350 manual says it must be. With that one placement line the processor started, the DDR3-ready LED was lit
and the flash loader answered. Two firmware faults followed straight away. The UART driver used the base 0xF030_0000,
while the UART registers start at 0xF030_0020, so the transmitter-ready check read another register and the firmware
hung before its first character. And the console had to run at 184,320 baud, which is the flash loader's 115,200 baud
divider applied to the 80 MHz bus clock instead of 50 MHz.

All three of these (`PLL_R[0]`, the UART base, the DDR3 pin drives) were written down in a board lessons file
before the radio's first board run. Reading that file line by line before the
first load would have saved the silent board runs, and reading it first is now a standing rule for every project on
this board.

The radio's own stage-0 flash loader and its bring-up ladder of three small bitstreams were not used for the first
start: the radio is loaded into SRAM with a board loader tool that is not part of this repository, which sends a small
network loader over the debug cable and then the 2 MB firmware over UDP on the RJ45 socket (3.3 s). The flash is not
written.

## 10. The Rust firmware: target, floating point, atomics and the main loop

The firmware is pure Rust, bare metal, with no C anywhere and Slint for the GUI. Several target choices came out of
measurements and board faults:

- **The target is `riscv32imafc-unknown-none-elf` plus the D extension.** The A25 has a double-precision FPU, but the
  standard target does not use it, so every f64 operation was a library call. `-C target-feature=+d` keeps the ilp32f
  ABI (so the precompiled `core` still links) and cut FT8 decode by 3.3 times. A trap handler that saves FP registers
  must save them 64 bits wide, and floating point is forbidden in interrupt handlers by a guard type.
- **No atomic instructions.** An `amoadd` stopped the AE350 the first time one ran. The A extension is
  switched off for the radio's code (`-C target-feature=-a`), so `portable-atomic` (which Slint's reference counts use)
  takes its single-core path with interrupts masked, and `tools/check_no_amo.sh` checks the disassembly after every
  build, because the precompiled `core` is not rebuilt and could still carry one.
- **One cooperative main loop.** The architecture planned plain interrupt handlers for the hard
  deadlines and the `embassy` executor for everything else. For the first board image the firmware was written as one
  cooperative main loop instead, as the setup with the fewest unknowns, and it has stayed that way. Its weak point
  showed on the board: a pass of the loop included the decoders, and the software FT8 decoder took 13,961 ms on a slot
  with no samples at all, while the RJ45 unit's 4 KB receive ring filled in one or two seconds of ordinary home-network
  broadcasts. The fix stayed inside the loop: no decode of an empty slot, and a yield hook that the long jobs call
  between steps, which serves the network and the input at most every 20 ms. Some steps still cannot yield (the
  192,000-point FFT of the software decoder, one candidate's belief propagation, Slint drawing a frame), so the pointer
  can lag by a loop pass.

## 11. The link to the HL2: from RJ45 to SFP, and every sample counted

The first design put the HL2 on the board's RJ45 socket with the radio's own gigabit MAC behind the RTL8211F PHY, and
the home network on an SFP module. The author then changed the cabling for every project on this board: the RJ45 socket
became the home-network port (control, GUI, TCI and one generic network loader), and the HL2
moved to SFP cage 0 with a 1000BASE-T copper module (Marvell 88E1111) running 1000BASE-X. The radio's receive chain
stayed the same, fed with bytes from the SFP lane's PCS, but it had to accept a clock without a byte at any point,
because such gaps had been seen on this board and had lost frames until the MAC took the PCS's byte enable.

The author's requirement was that 100 % of the raw data arrives, proven by counting every frame by its sequence number,
so the link got a full set of loss counters (by sequence, code error, length, overwrite and the HL2's own overflow). A
minimal test build with no processor and no DDR3 then ran the HL2 against the Tang for 414 s: 79,340 frames a second,
32.4 million frames, 0 bad FCS, 0 length errors and 0 overflows. There was one loss event of 68,692 frames, a pause of
0.866 s at the moment the HL2 took its link-local address. The Tang's counters show no fault of their own and the
HL2's sequence counter kept running, so an HL2-side pause is likely, but this was never proven. Jumbo frames through
the copper module are not known to work, so the link was tested with 968 samples per standard frame, which uses
97.6 % of the line.

The first full radio run found a second HL2 problem. The HL2 had been started by the minimal build and kept
streaming, since it does not know the radio restarted. Before discovery the radio's classifier has no HL2 address,
so every raw frame counted as "other" and went to the 4 KB CPU receive ring (about 80,000 a second), where the small
discovery reply stayed readable for only 33.3 us, far less than one pass of the main loop. The session therefore
looked for the radio for ever. The fix is in firmware: while looking for the HL2, more than 200 non-raw frames since
the last discovery tick make the session broadcast a stop instead of a discovery request. A stop enables nothing, so it
is safe. Keeping raw-looking frames out of the CPU ring in logic would be the cleaner fix and is not built.

## 12. The home network and the PC as a mouse and keyboard

The RJ45 network unit is a proven 100 Mbit/s design from an earlier design by the same author, copied unchanged, on a register page chosen so
that one shared loader finds it. Its PHY start-up repeats from the reset with doubling waits, because the RTL8211F read all
ones at 35 ms and answered at 70 ms. Each board names itself from Gowin's chip ID (the OTP DNA): the MAC address is a
hash of the ID and the name is `tang-` plus the last three MAC bytes.

Until a USB host adapter exists, the author wanted to control the radio from the PC while everything stays on the
radio's HDMI screen. A small PC program sends mouse and keyboard events by UDP to the RJ45 unit and the firmware feeds
them into the same path as a USB mouse and keyboard. The screen is not streamed. Input from the network can never
switch on transmit: the transmit keys are dropped, and the screen's transmit events are held off for a while after any
event from the network.

## 13. HDMI: 1080p60 black, 1080p30 working

The display was planned at 1920 x 1080 and 60 Hz, which needs about 1.49 Gbit/s per lane on pins that only emulate a
differential output, while Sipeed's own example proves only 742.5 Mbit/s (720p60). The architecture listed this as a
risk with 1080p30 as the fall-back, and it hit: on the board the 1080p60 output gave a black picture (the monitor saw a
signal, the compositor's colour bars were black too). A minimal test design on the same pins showed 720p60 and 1080p30
working and 1080p60 black in both clocking forms tried. The radio now runs 1920 x 1080 at 30 Hz (CEA mode 34, pixel
clock 74.17 MHz), the same lane rate as 720p60, with the layout unchanged. The pointer and the waterfall move at 30 Hz
at most. 1080i60 has the same bit rate but needs field logic and flickers on thin lines, so it was not used. At 60 Hz
the compositor reported an underrun on every status line. The 30 Hz mode halves its memory reads, but whether that
cleared the underruns is not recorded.

## 14. The panadapter that stayed black

On the first LISTEN run the receiver worked, audio noise came out, the console said the zoom window was placed, and
the zoom waterfall was still black. The cause was arithmetic. The colour byte is the column's dB value times a gain plus
an offset, a column's power word of one step is 0 dB, and the firmware had set the scale so that a column showed
black unless it was 25 dB above one step. Working through the chain's fixed-point scaling showed that the ADC noise
landed at a fraction of one step per bin, so 60 % of the columns were exactly 0 at the 12 kHz span, 86 % at 6 kHz and
100 % at 48 kHz, and no setting could show noise at 48 kHz. The FT8 and FreeDV waterfalls had the same fault.

The fix was in firmware only: the narrow-span gain went from 16 to 64, the AM, SAM and FM spans from 48 to 24 kHz, and
an automatic floor reads each new waterfall line back from DDR3, takes its 25th percentile as the noise floor and sets
the level so the floor lands on a dark blue palette entry. A bench feeds noise-only frames through the zoom context:
with the old level 0 of 1,172 columns showed, with the new one 1,133. A second trap was found in the logic while adding
a speed control: the line ends when the frame count equals K - 1, so a K written below the current count is never met
and the waterfall stops. The firmware therefore raises K at once and lowers it only right after a new line appeared.

## 15. Gowin tool traps met on this design

Most of these were found on this board first and are now rules in this repository. Each is worked around in the
source, not by changing tool versions:

- An inferred multiply-accumulate with load is mapped into the DSP block wrongly: instantiate `MULTALU27X18` and check
  DSP mappings by simulating the synthesized netlist.
- A register array loaded in a loop is built wrongly and shared across instances (`RAMREG` in the netlist): use packed
  vectors.
- `syn_preserve` and `syn_ramstyle` in the `(* ... *)` attribute form are ignored; the comment form works. Equal
  registers are merged even when kept by name, so they have to be made genuinely unequal.
- A memory that reads the old word on a write to the same address becomes a read-before-write block RAM, which this
  chip does not have, and place-and-route stops (PA2122).
- V1.9.11.03 built every kept register that powers up high twice (a set-type flip-flop and an unused reset-type twin)
  and its router left nets unrouted on a design the newer router finished. All builds now use V1.9.12.04 only.
- Shift-register inference put delay lines into LUT RAM cells on one shared toggle, which limited the receiver bank to
  106.8 MHz, so it is switched off (`syn_srlstyle`).
- Some ordinary expressions grew very large: a variable index into an audio sample buffer took about 49,000 LUTs in
  its first synthesis, and a part-select for a colour choice built a 5,400-LUT shifter, so both became constant
  selects or a case.
- The constraint file must name nets as they exist in the netlist: a clock that lives inside the core was not found
  at the top ("Can't find object named clk_eth"), and synthesis renamed the shared SFP transmit clock until it was
  kept by name.
- Multicycle constraints hang the placer, and `syn_preserve` on a whole module stalls synthesis at "Running
  inference".

## 16. Timing closure

Closure came in rounds of one full build each (about an hour on this chip), each followed by the same handful of
techniques: a register copy of a reset or enable per unit, a decision taken one clock early into a register, state
moved out of wide flip-flop selects into LUT RAM, and a register stage between units that sit far apart. The first
full builds, still at 150 MHz, went from 536 failing end points to 115 and then 37, all on `clk_dsp`. After the move
to 120 MHz and the fixes of section 7 the chip reached 0 failing end points at the real clocks and with the clocks
tightened by 5 %, and the USB audio and USB host merges kept 0 at the real clocks.

The merges that brought the 300 MHz DDR3, the SFP links, the HL2 on SFP0 and the RJ45 unit then took the failing end
points into the hundreds and thousands, and every bitstream that has run on the board so far came from such a build.
The build after the switch to 1080p30 had 1,780 setup and 3 hold failures. Almost all of them turned out to be the
DDR3 IP's own reset paths: the DDR3 PLL's 50 MHz output had no clock name in the 1 GB build, so the tool timed those
resets into the DDR3 clocks as if they were synchronous. Naming that output `ddr3_ref` and putting it in its own
asynchronous group against every other clock, took the build to 1,357 failures, then 101 (with
`ddr3_ref` wrongly grouped with the memory clock), and then to 0 setup and 0 hold, with no false-path commands. That
timing-clean bitstream has not run on the board yet. The lesson is to read a large failure count by clock pair before
cutting logic, because a missing clock definition looks exactly like a slow design.

The build script now also runs a timing estimate on the synthesized netlist before place-and-route, from the author's
shared Tang tools, and can stop a build whose estimate already fails.

## 17. What is still open

- The timing-clean bitstream has not run on the board. The bitstream in use is an older one with failing end points.
- The 0.866 s pause at the HL2's address change in the long link test has no proven cause. A run in which the HL2 keeps
  its address would show whether it repeats.
- On the first full radio run, the chip's FT8 search never finished and the compositor reported underruns at 60 Hz.
  Neither has been checked again at 30 Hz.
- Transmit is built (chain, sample path to the HL2, FT8 waveform, safety checks) but has never been tested end to end, so it
  has never been enabled. The HL2 is never sent a transmit enable, voice transmit is not enabled, and the call sign is a
  placeholder that keeps the transmit switch locked.
- TCI, VITA-49 streams on the network, an mDNS responder and the radio's own network loader are not built. The RJ45
  unit runs at 100 Mbit/s, enough for control and the loader, not for raw streams.
- USB audio and the USB host are built and pass their benches, but neither has been tried with a real PC or device.
- The LISTEN audio ring holds about 85 ms, so a main-loop stretch longer than about 80 ms without a top-up gives an
  underrun. A larger ring needs a gateware change.
- The DDR3 lane bandwidth at 300 MHz and the processor's memory speed were never measured on the board.
- Raw-looking frames from an HL2 at an unknown address still reach the CPU ring; the firmware works around it.
- The zoom's line counter trap (section 14) is handled in firmware; a logic change that clears the count when K is
  written would remove the rule.

After the project was renamed, which changes names and nothing else, the same design placed differently: the default build failed 161 end points on `clk_dsp` (116.6 MHz) and place option 3 failed 245, while place option 2 closed timing with 0 setup and 0 hold failures at 120.013 MHz. The result of a place-and-route run depends on small things such as the names of the modules, so a design that closes by 0.013 MHz is not really closed. Keep that in mind when you read any timing claim in this repository: it holds for one source tree and one set of options (`docs/DECISIONS.md`, 2026-11-19).

The first board test of the Tang updating the HL2's saved program (2026-11-20) was refused by the update's own safety check: the HL2 was not quiet, because a stream from the previous run was still arriving, and the check looked at that one instant only. The safety check did what it should and nothing was written. The fix is to wait, with repeated Stop commands, until the stream has died down (docs/HL2_CONTROL.md).

The Tang updated the saved program of the real HL2 for the first time on 2026-11-20, after two false starts. The first was the quiet check described above. The second was a test that changed only the version label in the save header while the program inside still reported its old version, so the Tang rightly called the result a failure. The test that worked used a copy of the program with a different compiled-in version, and the next start found the HL2 up to date and wrote nothing.

The stage-0 loader had not linked since the firmware went without atomic instructions (2026-10-21): `core` asks for the one-byte libatomic functions, and only the four-byte ones existed, in tr-app. It went unnoticed because the loader image from before that date kept being used, and it surfaced on 2026-11-20 when `tools/ladder_fw.sh chip` was run for the public build instructions. The loader now carries the two one-byte functions it needs (`fw/tr-loader/src/bin/stage0.rs`).
