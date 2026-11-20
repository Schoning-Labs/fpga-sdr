<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# Glossary

The terms used in the Verilog comments, the firmware and the documents of this repository, one plain paragraph each,
in alphabetical order. The headings are stable, so other documents and code comments can link to an entry as
`docs/learn/GLOSSARY.md#cic-filter`. Where a term has a number in this radio, the number is given. Where a term needs
more than a paragraph, the entry points to the primer or design document that explains it.

## 0-9

### 1000BASE-T

Gigabit Ethernet over ordinary copper network cable, four wire pairs, up to 100 m. The Hermes-Lite 2's network port
speaks 1000BASE-T, and the copper SFP module in cage SFP0 converts it to [1000BASE-X](#1000base-x) for the FPGA.

### 1000BASE-X

Gigabit Ethernet as one serial stream of 1.25 Gbit/s with [8b/10b](#8b10b) coding, the form used by fiber and by the
host side of most SFP modules. The FPGA's transceiver lane 0 runs it to talk to the HL2 through the copper module, and
`rtl/sfp/sfp_pcs.v` holds the [PCS](#pcs) with its [auto-negotiation](#auto-negotiation).

### 8b/10b

A line code that sends each 8-bit byte as a 10-bit symbol chosen so that the stream has about as many ones as zeros
and enough edges for the receiver to recover the clock. The two extra bits per byte are why a 1 Gbit/s data rate needs
1.25 Gbit/s on the wire. Special symbols such as K28.5 (a [comma](#comma)) mark word boundaries. Encoder and decoder are
in `rtl/n1/enc_8b10b.v` and `dec_8b10b.v`.

## A

### AD9866

The converter chip on the Hermes-Lite 2. Its 12-bit ADC samples the antenna signal at 76.8 Msps, and its DAC is the
transmit output. Everything this radio receives comes from this one ADC.

### ADC

Analog-to-digital converter: the part that measures a voltage at regular moments and gives each measurement as a
number. Here it is the HL2's 12-bit ADC at 76.8 million samples per second, so each sample is a value from -2,048 to
+2,047 and the samples are 13 ns apart.

### adc_valid

The one-bit strobe that comes with every sample on the radio's internal sample bus. In `clk_dsp` (120 MHz) it is high
in one clock for each sample, about 64 % of the clocks on average, in bursts while a frame is unpacked. Every receive
block advances only when it is high, so the count of `adc_valid` pulses is the radio's clock of HL2 time. See
[valid strobe](#valid-strobe).

### AE350

Gowin's RISC-V subsystem built into the GW5AST chip: an Andes A25 core (RV32IMAFDC, five-stage in-order pipeline) at
800 MHz, 32 KB instruction and 32 KB data cache, 64 KB [ILM](#ilm) and 64 KB [DLM](#dlm), a [PLIC](#plic) with 16
interrupt lines from the logic, UARTs, an SPI flash controller and timers (Gowin MUG1031). It runs the Rust firmware.
Its buses run at 80 MHz in this design.

### AGC

Automatic gain control: the loop that keeps the audio level steady while the signal strength changes by many
decades. It turns the gain down quickly when the signal rises (attack, 2 ms in LISTEN), holds it, and lets it come back
up slowly (decay). The back end does it in the log domain in `rtl/rx_backend/bk_post.v`, so no divider is needed.

### AHB

The Advanced High-performance Bus of the ARM AMBA family, which the AE350 uses. The processor reaches the FPGA's
registers through its Extended AHB Slave port (a 128 MB window at 0xE800_0000), and its main memory through its data
memory AHB port; both are 80 MHz or 50 MHz buses, not synchronous to `clk_dsp`.

### Alias

A false signal that appears when a frequency above half the sample rate is sampled: it folds back and shows up at a
lower frequency. Every decimation step needs a low-pass filter in front of it to keep aliases out, and the design
documents give "alias rejection" in dB for each filter (the zoom receiver aims at 80 dB, `docs/F3_ZOOM.md`).

### ALU

Arithmetic logic unit: an adder, subtracter or comparator. In Gowin reports "ALU" counts the logic cells used in carry
mode for adders and counters. Each DSP block also has a 48-bit ALU after its multiplier, which is what makes a
multiply-accumulate possible in one block.

### AM

Amplitude modulation: the carrier's strength follows the audio. The receiver demodulates it by taking the envelope (the
length of the I/Q vector) and removing its steady part with a [DC tracker](#dc-tracker). The LISTEN screen offers AM
filters of 6, 9 and 4 kHz.

### APB

The Advanced Peripheral Bus, the slower partner of [AHB](#ahb) for simple peripherals. In the AE350 it carries the
UARTs, timers and similar units, at 80 MHz here.

### Arbiter

A circuit that decides which of several requesters gets a shared resource next. This radio has two DDR3 lane arbiters
(`rtl/ddr3/ddr3_read_arbiter.v`, `ddr3_write_arbiter.v`) with fixed priority tiers, and smaller arbiters inside blocks,
for example the round robin that picks which receiver's sample goes onto the shared output stream in `rx_bank.v`.

### Auto-negotiation

The exchange at link start in which two Ethernet ends agree on mode and abilities. For [1000BASE-X](#1000base-x) it is
defined in clause 37 of IEEE 802.3 and is done in `rtl/sfp/sfp_pcs.v`; if no link comes up within 3 s the firmware
tries [SGMII](#sgmii) instead.

## B

### Back end

Short for the receiver back end, `rtl/rx_backend/`: the time-shared engine after the receiver bank that does the noise
blanker, the half-band decimation to 24 ksps, the 1,024-tap channel filter, demodulation, AGC, S-meter, squelch and the
final half-band to 12 ksps, and writes each receiver's audio into a DDR3 ring. `docs/R4_BACKEND.md` specifies it.

### Back-pressure

A signal from a consumer telling the producer to wait. Most streams in this radio have none on purpose (the sample
stream cannot be paused, the HL2 keeps sending), so every block is sized to keep up, and where a stream can wait it is
written as `ready`, `wait` or a FIFO's full flag.

### Bank

In the back end, one of six memories per channel-filter unit that each hold a complete filter's coefficients. The
firmware writes a new filter into a free bank and then switches a receiver to it between two samples (`bank_sel`), so a
filter change makes no click. FT8 uses bank 0 and LISTEN alternates between banks 1 and 2.

### Band filter

The switched low-pass filters on the HL2's N2ADR filter board, chosen by relays through HL2 register 0x00. They are the
only part of the HL2 the radio changes with the frequency; the HL2 itself is never tuned. Groups: 160 m, 80 m, 60/40 m,
30/20 m, 17/15 m and 12/10 m.

### Bin

One output of an FFT: the strength and phase of the signal in a slice of the spectrum whose width is the sample rate
divided by the FFT size. The full-band FFT's bins are 76.8 MHz / 16,384 = 4.6875 kHz wide; the FT8 spectrogram's are
3.125 Hz.

### Bit growth

The extra bits a sum needs to hold its largest possible value. Adding two 12-bit numbers needs 13 bits, and a CIC
filter's integrators grow by stages x log2(decimation) bits, which is why the variable CIC has 43-bit accumulators.
Comments that give a register width usually derive it from the bit growth.

### Bit-reversed order

The order in which a streaming FFT gives its bins: bin numbers with their bits written backwards (for 8 points: 0, 4,
2, 6, 1, 5, 3, 7). `rtl/fft/fft_r22sdf.v` gives the bin number with each word (`out_bin`) instead of reordering, and
the spectrum pipeline sorts the bins out after the power step.

### Bitstream

The configuration file that sets every LUT, register, block RAM and wire of the FPGA. Gowin's tool writes it as
`sdr_top.fs`; loading it into the chip's configuration SRAM makes the FPGA become the radio until power-off.

### Blackman-Harris window

A [window](#window) function with four cosine terms whose side lobes are about 92 dB down. The full-band spectrum uses
it because the 12-bit ADC plus the FFT's gain span more than 80 dB, so a weaker window would draw false signals around
strong stations. Its 8,192 coefficients are stored as every 8th point and interpolated (`rtl/spectrum/spectrum_window.v`).

### BL616

The Bouffalo Lab microcontroller on the dock behind the debug USB-C socket. It is the JTAG cable that loads the FPGA and
the USB serial port to the processor's UART, and it also programs the SFP reference clock chips.

### Block RAM

Also BSRAM. The FPGA's dedicated memory blocks: 340 of 18 kbit each, two ports with their own clocks, shapes from
16,384 x 1 to 512 x 36 bits (Gowin UG300). Memories written in Verilog with a registered read become block RAM; the
138K chip has no read-before-write mode, so the RTL never asks for it. See [FPGA_PRIMER.md](FPGA_PRIMER.md) section 1.3.

### Board link

An optional link from this board to a second Tang board over SFP cage 1 at 2.5 Gbit/s (`rtl/blink/`, register page
0xE80B_0000, interrupt line 14), for a sample stream and control words between boards.

### BUFG

The name of a global clock buffer in Gowin's constraint syntax. `CLOCK_LOC "clk_pix" BUFG[15] = CLK;` puts the net
`clk_pix` on global clock line 15 (Gowin SUG1541 section 2.8). See [global clock line](#global-clock-line).

### Burst

Several consecutive words moved with one request. A DDR3 burst is 8 transfers of 32 bits, 32 bytes; a lane burst in this
radio is up to 255 words of 64 bits. Burst also describes how `adc_valid` arrives: a whole frame of samples on
consecutive clocks, then a pause.

### Butterfly

The basic step of an FFT: two values are combined into their sum and difference, one of them multiplied by a
[twiddle factor](#twiddle-factor). A 16,384-point radix-2^2 FFT is 14 stages of butterflies (`rtl/fft/fft_bf.v`).

## C

### Cache line

The unit the processor's cache loads and writes back, a few dozen bytes. Because the logic writes DDR3 behind the
cache's back, the firmware invalidates the lines of a ring before reading what the logic wrote and writes its own lines
back before telling the logic new data is there.

### Carry chain

A dedicated fast wire between neighboring logic cells that carries the carry bit of an addition, so a wide adder does
not need a LUT level per bit. Gowin's CLS in ALU mode uses it (UG303).

### CCTL

The Andes cache control commands of the AE350 (MUG1029), for example write back or invalidate one data cache line by its
address. The firmware uses them around every DDR3 ring the logic shares (`fw/tr-ae350`).

### CDC

Clock domain crossing: any place where a signal goes from logic on one clock to logic on another, unrelated clock. It
has to be built from a [synchronizer](#synchronizer), a [toggle handshake](#toggle-handshake) or a FIFO with
[Gray code](#gray-code) pointers, and the constraint file declares the two clocks asynchronous. `cdc_word.v` and
`cdc_sample_fifo.v` in `rtl/hl2link/` are examples.

### CEA-861

The standard that defines the video modes and the extra packets of HDMI. Mode 34 is 1920x1080 at 30 Hz with a
74.25 MHz pixel clock in a 2,200 x 1,125 frame, which is what this radio sends (74.17 MHz, 0.11 % low, within the
standard's 0.5 %).

### CFU

Configurable function unit: Gowin's logic tile, four [CLS](#cls) sections with two LUTs and two registers each, plus
their routing (Gowin UG303 chapter 2).

### Channel filter

The filter that decides what a receiver lets through: in the back end a complex FIR of up to 1,024 taps at 24 ksps with
32-bit coefficients (`rtl/rx_backend/bk_chfilt.v`), designed by the firmware for each mode and width. The LISTEN SSB
filter is 2.4 kHz wide, 1,023 taps, and delays the audio by 21 ms.

### Chip ID

A 64-bit number unique to each FPGA, read from Gowin's one-time programmable memory ([OTP](#otp)) by `rtl/net/chip_dna.v`.
The firmware derives the board's network MAC address and its name (`tang-xxxxxx.local`) from it.

### CIC filter

Cascaded integrator-comb filter (also called a Hogenauer filter): a decimating low-pass filter made only of adders, a
chain of [integrators](#integrator) at the high rate and a chain of [combs](#comb) at the low rate. It is cheap and
exact but droops in the pass band, so a compensating FIR follows it. The receiver uses a 3-stage CIC decimating by 10
and a 5-stage one decimating by 5 to 40. See [SDR_PRIMER.md](SDR_PRIMER.md) section 5.2.

### CLS

Configurable logic section: one quarter of a Gowin [CFU](#cfu), holding two 4-input LUTs and two registers. A CLS can
work as logic, as an adder with a carry chain, or as a 16 x 4 memory (Gowin UG303 section 2.1).

### Clock domain

All the registers clocked by one clock. This design has about a dozen (`clk_dsp`, `clk_pix`, `n1_rxc`, `sfp_txc`, the
AE350's bus clock, `clk_eth`, `clk_48m`, `clk_aud`, the DDR3 clocks and more), listed in
[FPGA_PRIMER.md](FPGA_PRIMER.md) section 5.

### Clock enable

An input that lets a register take a new value only in clocks where it is high. Blocks that process a stream slower
than their clock use the stream's valid strobe as clock enable, which is how every receiver stage advances only on
`adc_valid`.

### Clock group

A set of clocks declared in the SDC file with `set_clock_groups -asynchronous`, which tells the timing tool not to time
paths between groups because the design crosses them safely (Gowin SUG940 section 5.2.5). Each such line in
`gowin/p1/sdr.sdc` names the crossing circuits that make it true.

### Comb

The second half of a CIC filter: it subtracts from each sample the sample a fixed number of steps earlier. Combs run at
the low rate after the decimation.

### Comma

A special [8b/10b](#8b10b) symbol (K28.5) whose bit pattern cannot occur across the boundary of two normal symbols, so a
receiver can find where symbols start. The aligner in `rtl/sfp/` searches for it.

### Compositor

`rtl/video/compositor.v`: the block that builds the HDMI picture by laying the FPGA's spectrum traces and waterfalls over
the firmware's Slint framebuffer wherever the framebuffer holds the [key color](#key-color). See
[ARCHITECTURE_TOUR.md](ARCHITECTURE_TOUR.md) section 7.

### Constraint file

A file that tells the build tools what the RTL cannot: the physical constraints in `gowin/p1/sdr.cst` (pins, I/O
standards, drive strengths, clock lines) and the timing constraints in `gowin/p1/sdr.sdc` (clocks and their
relations, false paths).

### CORDIC

Coordinate rotation digital computer: a way to rotate a vector or find its angle and length with only shifts and adds,
one bit of precision per iteration. The back end's demodulator uses one iterative CORDIC with 20 iterations for AM, SAM
and FM. The receiver mixers used CORDICs in early versions and now use an [NCO](#nco) with a sine table.

### Clock domain crossing

A signal that is made in one clock domain and used in another, so that its changes can arrive at any moment relative to the receiving clock. A single bit goes through a [synchronizer](#synchronizer), several bits that belong together go through a small FIFO with Gray-coded pointers or through a held value that is only read after a handshake says it has settled, and the timing constraints declare the two clocks unrelated so that the tools do not try to time a path that cannot be timed.

### Costas array

A pattern of 7 tones in a fixed order that FT8 sends three times in each message. Searching the spectrogram for it
gives each signal's start time and frequency; this is the sync search of `rtl/ft8/ft8_sync.v`.

### CPU receive ring

A 4 KB block RAM ring (`rtl/hl2link/cpu_rx_ring.v`) that receives every frame from the HL2 link that is not a raw sample
frame (discovery replies, register replies, DHCP, ARP), for the processor to read through register page 0xE802_0000,
with interrupt line 0.

### CRC-32

The 32-bit checksum at the end of every Ethernet frame (the [FCS](#fcs)). The HL2 link checks it in
`rtl/hl2link/eth_frame_rx.v` and drops a bad frame completely; the gap filler then fills the missing samples with zeros.

### Credit

A flow-control scheme in which a sender may only send as many items as the receiver has said it has room for. The gap
filler issues reads to its sample FIFO on credit so that it can pop one sample every clock without overrunning its
4-word input queue.

### CW

Continuous wave: Morse code sent by switching a carrier on and off. The receiver is tuned 600 Hz below the carrier and
filters around +600 Hz, so the carrier is heard as a 600 Hz tone; LISTEN's CW filters are 500, 250 and 800 Hz wide.

## D

### Data island

A packet sent in the blanking time of an HDMI picture, coded with TERC4. Audio samples, the audio clock regeneration
packet and the InfoFrames travel in data islands; the hdl-util HDMI core in `rtl/vendor/hdmi` builds them, which is
how the monitor plays the radio's sound.

### dBFS

Decibels relative to full scale: 0 dBFS is the largest signal the ADC can take, and everything else is negative. The
LISTEN S-meter reads in dBFS (the back end's level plus 22.3 dB), and the squelch can be set from -140 to -20 dBFS.

### DC tracker

A slow filter that follows the steady (zero frequency) part of a signal so it can be subtracted. The AM demodulator
subtracts it from the envelope to remove the carrier and leave the audio.

### DDC

Digital down-converter: an NCO mixer followed by decimating filters, which moves one part of the spectrum to zero
frequency at a low sample rate. Each receiver is a DDC, and so is the zoom receiver (`rtl/zoom/zoom_ddc.v`).

### DDR3

The type of the board's main memory: two 4 Gbit chips, 16 bits each, together 32 bits and 1 GB. It moves data on both
clock edges; the radio runs it at a 300 MHz memory clock (600 million transfers per second) instead of the rated
400 MHz, because 400 MHz lost reads on this board when much logic switched. Gowin's DDR3 controller runs at a
quarter of the memory clock, 75 MHz.

### DDR3 lane

One of the two 64-bit ports through which the FPGA logic reaches DDR3, one for reading and one for writing
(`rtl/mem/ddr_mem.v`). Each has an arbiter with priority tiers in front of it. Their ceiling is 64 bits x 75 MHz =
600 MB/s each.

### De-emphasis

A low-pass filter after the FM demodulator that undoes the treble boost (pre-emphasis) the FM sender applied, which
also lowers the hiss. LISTEN uses 530 us, a slope of 6 dB per octave above about 300 Hz, with +12 dB of fixed gain to
make up for it.

### Decimation

Lowering the sample rate by keeping one sample in N, after a low-pass filter that removes everything that would alias.
The receiver decimates from 76.8 Msps to 48 to 384 ksps in three steps, and the back end continues to 24 and 12 ksps.

### Delay line

The memory of the last N input samples that a FIR filter multiplies with its taps. In this radio delay lines are
circular buffers in block RAM read by offset, instead of shift registers, which saves thousands of flip-flops per
receiver (`rtl/rx/fir_decim.v`).

### DHCP

The protocol that gives a network device its address. The radio is a DHCP client on the home network (RJ45), and on
the HL2 link the firmware answers the HL2's own DHCP request so the HL2 gets an address within a second.

### Discovery

The HL2 protocol step in which the radio asks "who is there" and the HL2 answers with its address and capabilities.
The firmware's HL2 session does it before starting the raw stream.

### DLM

Data local memory: 64 KB of fast on-chip RAM in the AE350 at 0xA020_0000, used for the stacks and hot data. Its
partner for code is the [ILM](#ilm).

### DPX9B

A Gowin primitive for a dual-port block RAM with 9-bit-wide byte lanes (UG300). `rtl/rx/nco_mixer.v` instantiates it
directly for the sine table, so that one block gives sine and cosine through its two ports.

### Droop

The fall of a filter's response towards the edge of its pass band. A CIC filter droops, so the FIR after it is designed
with the inverse slope to make the total flat (a compensating FIR).

### DSP block

The FPGA's hard multiplier blocks: 298 of them, each a 27 x 18 multiplier (or 12 x 12, or 27 x 36 using more), a 26-bit
pre-adder and a 48-bit ALU, with up to four register stages (Gowin UG305). Every multiplier in the radio is one. See
[FPGA_PRIMER.md](FPGA_PRIMER.md) section 1.4.

### Dual port

A memory with two independent ports, each with its own clock and address. "Simple" or "semi" dual port means one port
writes and the other reads, which is how nearly every block RAM in this design is used.

## E

### End point

In a timing report, a register input (or pin) that receives a path. "320 failing setup end points" means 320 register
inputs where at least one path arrives too late.

### Equiripple

A filter design in which the error ripples with equal height across the pass band and across the stop band, which
gives the steepest filter for a given number of taps. The back end's half-band filters are equiripple designs.

### Etherbone

A protocol for reading and writing a remote bus over UDP. The HL2 offers it as a bridge to its registers, and the
firmware's HL2 code can use it as a client.

### Ethernet frame

The unit of data on Ethernet: preamble and [SFD](#sfd), destination and source MAC address, type, payload and the
4-byte [FCS](#fcs). The HL2's raw frames are UDP inside IPv4 inside Ethernet frames of up to about 9,000 bytes (jumbo).

## F

### False path

A path the timing tool is told to ignore with `set_false_path`, because it is not timed by design (a pin sampled through
synchronizers, a reset held for many clocks). This radio uses them for the RJ45 and USB pins and the HDMI serializer
resets (`gowin/p1/sdr.sdc`).

### Fan-out

The number of inputs a signal drives. A net with hundreds of loads spreads over the chip and its wire alone can take
nanoseconds, so the RTL makes several [kept copies](#kept-copy) of such a register, each with about ten loads.

### FCS

Frame check sequence: the CRC-32 at the end of an Ethernet frame. `crc32_append.v` adds it on transmit and
`eth_frame_rx.v` checks it on receive.

### FFT

Fast Fourier transform: an efficient way to compute the spectrum of a block of N samples as N bins. The radio has a
16,384-point FFT on the full 76.8 Msps band whose last twelve stages also serve the zoom as a 4,096-point FFT, and
256-point FFTs inside the FT8 spectrogram, all from the same streaming core `rtl/fft/fft_r22sdf.v`.

### FIFO

First in, first out: a queue. A FIFO with read and write in different clocks (an asynchronous FIFO) is the standard way
to carry a stream across a clock domain, using [Gray code](#gray-code) pointers.

### FIR filter

Finite impulse response filter: each output is a weighted sum of the last N inputs, the weights being the
[taps](#tap). It can have almost any shape and its phase can be exactly linear. The receiver ends with a 65-tap FIR,
the back end's channel filter has up to 1,024 taps.

### Fixed point

Integer arithmetic with an agreed position of the binary point, used for all DSP in the FPGA. Comments describe it as
"Q25" (25 fraction bits) or "24.16" (24 integer and 16 fraction bits) and state how each step rounds.

### Flip-flop

One stored bit that takes a new value only on a clock edge (Gowin calls it REG). Every `reg` written in an
`always @(posedge clk)` block is a flip-flop. The chip has 138,240 of them.

### Fmax

The highest clock frequency at which every path of a clock domain meets setup timing, as reported after place and route.
`clk_dsp` needs 120 MHz; builds in October 2026 reached 106.6 to 111.96 MHz before the design closed timing.

### FM

Frequency modulation: the carrier's frequency follows the audio. The receiver demodulates it as the phase difference
between consecutive samples, then applies [de-emphasis](#de-emphasis). LISTEN's FM filter is 12 kHz wide.

### Framebuffer

A memory holding one picture, pixel by pixel. The firmware's Slint screen is an RGB565 framebuffer of 1,920 x 1,080 x 2
= 4,147,200 bytes in DDR3, read by the compositor.

### FreeDV

An open digital voice mode. The radio receives FreeDV 700D and 700E with Rust ports of codec2 and the FreeDV modems
(`fw/tr-freedv`, `fw/tr-codec2`, LGPL-2.1), shown on their own screen.

### FT4

A faster relative of FT8 with 7.5-second slots and 4 tones. The FT8 front end's engines are written to serve it through
parameters, though the Rust model covers FT8 only so far.

### FT8

A digital mode for weak signals: 15-second slots aligned to UTC, 79 symbols of 8 tones 6.25 Hz apart, LDPC error
correction. The radio's FPGA front end does the spectrogram, sync search and soft symbols, and the processor does the
decoding. See [SDR_PRIMER.md](SDR_PRIMER.md) section 10.

## G

### Gap filler

`rtl/hl2link/gap_filler.v`: the block that compares each raw frame's first-sample index with the expected index and
inserts one zero for every missing sample, so that every receiver keeps its phase and time. A jump over 65,536 samples
is counted as a resync instead.

### GMII

Gigabit media independent interface: the byte-wide interface between an Ethernet MAC and the PCS, one byte per clock at
125 MHz. The HL2 link's receive and transmit chains speak it on the inside (`gmii_rx_in.v`, `gmii_tx_out.v`).

### Global clock line

One of the 16 dedicated low-skew clock networks of the Arora V chip (Gowin UG306 section 2.1), shown in reports as 8
primary and 8 long-wire lines. Every clock in this design is meant to be on one; a clock on ordinary wiring gets 0.8 to
2.4 ns of skew and hold failures.

### Gowin EDA

Gowin's design software, used here in version V1.9.12.04: GowinSynthesis, place and route, timing analysis and the
bitstream writer, driven from the command line with `gw_sh` and its Tcl script. GowinModGen generates the PLL and other
IP from their `.mod` files. Only this version is used for this project.

### Gray code

A way of counting in which only one bit changes from one value to the next. A FIFO pointer passed across clock domains
in Gray code can be sampled at any moment and is either the old or the new value, never a mixture.

## H

### Half-band filter

A FIR filter whose cutoff is at a quarter of the sample rate, which makes almost half its taps zero. It is the cheap way
to decimate by 2. The back end uses a cascade of half-bands with 11, 15, 23 and 63 taps to reach 24 ksps, and the
zoom receiver a 63-tap one.

### HDMI

The digital monitor interface. The radio encodes it in logic (hdl-util core) with sound, and sends it on emulated LVDS
pins at 1920x1080, 30 Hz. See [TMDS](#tmds) and [data island](#data-island).

### Hermes-Lite 2

An open-source HF transceiver board (HL2). This radio uses it only as a front end: with its raw front end firmware it
streams every 12-bit ADC sample at 76.8 Msps over gigabit Ethernet and takes transmit samples back, and it keeps its own
hardware transmit interlocks.

### HL2 session

The firmware's state machine (`fw/tr-station`, `hl2session`) that brings the HL2 up: DHCP answer, discovery, raw mode,
band filter, gain, start, and again after a loss. Its module text lists every command it can send.

### Hold time

The time a register input must stay steady after the clock edge. A path that is too fast (usually because the clock
reaches the two registers at different times) fails the hold check; see [FPGA_PRIMER.md](FPGA_PRIMER.md) section 2.1.

## I

### I/Q

In-phase and quadrature: a pair of numbers per sample that together form a complex number, so a signal can have a
positive frequency without its negative mirror. Every receiver turns the real ADC stream into I/Q in its mixer.

### I2C

A two-wire bus for slow control. The dock's I2C (through a multiplexer) reaches the SFP modules and the clock chips;
`rtl/sfp/sfp_top.v` drives it from register page 0x0A.

### I2S

A three- or four-wire serial bus for audio samples: bit clock, word clock and data, sometimes a master clock. The radio
sends 48 kHz audio on I2S on PMOD2 pins (bit clock 3.072 MHz, master clock 12.288 MHz) for a DAC board.

### IDDR and ODDR

Gowin primitives that take or give data on both clock edges at a pin. The earlier gigabit RGMII link used them; the
current RJ45 unit at 100 Mbit/s does not, and the files are left unused in `rtl/hl2link/`.

### ILM

Instruction local memory: 64 KB of fast on-chip RAM in the AE350 at 0xA000_0000, for code that must not wait for the
cache. Its partner for data is the [DLM](#dlm).

### InfoFrame

A small HDMI packet that tells the monitor about the picture or the audio (format, channels, rate). The HDMI core sends
the AVI, audio and source product InfoFrames in [data islands](#data-island).

### Integrator

A running sum: each output is the previous output plus the input. The first half of a CIC filter is a chain of
integrators at the high sample rate; they are allowed to wrap around, because the combs take the growth out again.

### Interlock

A hardware safety lock that stops transmitting. The HL2 has its own (a lease that must be renewed, temperature,
inhibit, a watchdog, a maximum key-down time), and the radio's TX chain adds its own: zeros whenever transmit is not
enabled or the HL2's [transmit-safety byte](#transmit-safety-byte) shows a trip.

### Interpolation

Raising the sample rate: insert zeros between samples and low-pass filter, so the images of the signal move far above
the band. The audio engine interpolates 48 kHz eight times to 384 kHz for the PT8211 DAC, and the TX chain from
48 kHz up to 76.8 Msps.

### Interrupt

A signal that makes the processor stop what it is doing and run a handler. The logic has 16 interrupt lines into the
AE350's PLIC; line 10, for example, says a back-end audio block is ready. The full list is in
[ARCHITECTURE_TOUR.md](ARCHITECTURE_TOUR.md) section 9.3.

### IP core

A ready-made design block from a vendor, delivered as configuration plus (often encrypted) source. This radio uses
Gowin's AE350, DDR3 controller, SerDes and PLLs as IP; only their configuration files are kept in git
(`gowin/p1/ip/`), and the build regenerates them from the Gowin install.

### IPC

Instructions per clock, how many instructions a processor finishes per cycle on average. The CPU budget assumes 0.7 for
the A25 (`docs/ARCHITECTURE.md` section 5.5); 1.0 is its hard ceiling.

### Isochronous

A USB transfer type with a guaranteed time slot every frame and no retries, used for audio. The radio's USB sound card
and USB host both use isochronous endpoints, with a feedback endpoint for the playback rate.

### iverilog

Icarus Verilog, the open-source simulator used for most testbenches in `sim/`. It cannot simulate Gowin's encrypted IP,
which is why the top level is split into `sdr_top.v` and `sdr_core.v`.

## J

### JS8

A chat mode built on the FT8 waveform family, planned for the same front end engines through parameters.

### JTAG

A serial test and configuration port on chips. The BL616 uses the FPGA's JTAG port to load the bitstream; the AE350 has
its own JTAG port for a debugger on FPGA pins.

### Jumbo frame

An Ethernet frame larger than the standard 1,500-byte payload, here about 9,000 bytes. With jumbo frames the HL2 sends
5,968 samples per frame and the link is 93 % busy; without them 968 samples and 97.6 %.

## K

### K (averaging)

The number of FFT transforms the spectrum pipeline averages into one spectrum or waterfall line. It sets the waterfall
speed: at the 12 kHz zoom span K = 1 gives 3.7 lines per second and K = 4 gives 0.9.

### Kaiser window

A window function with one parameter (beta) that trades main-lobe width against side-lobe height, often used to design
FIR filters. The FT8 candidate engine's 65-tap FIR is a Kaiser design with beta 6.

### Kept copy

A deliberate duplicate of a register so that each copy drives only a few loads, which keeps wires short. Because Gowin
merges equal registers, the copies are kept with a `syn_preserve` comment directive and made genuinely different where
needed. `rx_fan` and similar modules in `rtl/rx/` build them.

### Key color

The color 0xF81F (magenta in RGB565) that the firmware's Slint screen paints where the FPGA should draw. Inside a
compositor window a key-color pixel shows the spectrum or waterfall; any other color shows the Slint layer, so menus can
cover the waterfall without an alpha plane.

## L

### Latency

How long a block takes from input to output, given in clocks or in samples. RTL headers state it, for example the NCO
mixer's 7 samples in receive mode, because blocks that work side by side must line up.

### LDPC

Low-density parity-check code: the error correcting code FT8 uses. The processor decodes it (belief propagation, then
ordered statistics decoding as a fallback) with the mfsk-core library.

### Lease

The HL2's transmit permission, which expires unless renewed. The firmware would renew it every 25 ms only while the
operator keys; transmit is built but has never been tested end to end, so the current firmware keeps it locked and the HL2 is never keyed.

### Leading-one detector

A circuit that finds the position of the highest set bit of a number, which is the integer part of its base-2 log. The
AGC and the spectrum dB step use it with a small table for the fraction (`rtl/spectrum/log2_core.v`).

### Logic level

One LUT on a path between two registers. Each level costs its own delay plus the wire to the next; in this design 16
levels took 8.7 ns, more than the 8.33 ns of a 120 MHz clock.

### LOS

Loss of signal: an SFP module's output that says it receives nothing. Pins V18 and W18 for the two cages.

### LSB (bit)

Least significant bit, the lowest bit of a number. "1 LSB" is the smallest step a value can change by.

### LSB (mode)

Lower sideband, the form of [SSB](#ssb) used by convention below 10 MHz. LISTEN chooses LSB by default below 10 MHz.

### LUT

Look-up table: the FPGA's basic logic element, a 16-bit memory whose 4 inputs are the address, so it can be any
function of 4 inputs. The chip has 138,240. See [FPGA_PRIMER.md](FPGA_PRIMER.md) section 1.1.

### LUT RAM

A LUT used as a 16 x 4-bit memory (Gowin RAM16, also called distributed RAM or SSRAM). Small FIFOs and clock-crossing
queues use it; build reports count each as 6 logic cells.

### LVCMOS33D

A Gowin I/O standard that makes a differential pair from two ordinary 3.3 V outputs driven in opposite phase (emulated
LVDS). The HDMI pins use it, which is the likely reason 1080p60 does not work on this board.

## M

### MAC

Media access control: the part of an Ethernet interface that builds and checks frames (addresses, FCS). The HL2 link
has its own minimal MAC in logic; the RJ45 network unit has another.

### MDIO

The two-wire management bus (with MDC as its clock) on which an Ethernet MAC reads and writes the PHY's registers. The
RJ45 unit uses it to start the RTL8211F.

### Metastability

The state of a flip-flop that sampled its input while it was changing: for a short, unpredictable time its output is
neither 0 nor 1. A [synchronizer](#synchronizer) gives it a whole clock to settle before anyone uses it.

### mfsk-core

A Rust library for FT8 and related modes that the firmware uses for decoding, with patches kept by this project. The
FPGA front end's Rust model reproduces its candidate search word for word.

### Mixer

A multiplier that shifts a signal's frequency by multiplying it with a sine wave. In this radio it is always an
[NCO](#nco) mixer (`rtl/rx/nco_mixer.v`), in receive mode real in and complex out, in transmit mode the other way.

### MS5351M

The clock generator chips on the dock that make the 125 MHz reference for the SFP transceiver from a 25 MHz crystal.
They are programmed over I2C.

### MSB

Most significant bit, the highest bit of a number; in two's complement it is the sign.

### MTU

Maximum transmission unit: the largest payload a network link carries in one frame, 1,500 bytes on standard Ethernet
and about 9,000 with jumbo frames.

### MULTALU27X18

The Gowin DSP primitive for a 27 x 18 multiplier followed by the 48-bit ALU (Gowin UG305 section 4.2.1). The RTL
instantiates it for multiply-accumulate because the synthesis tool maps an inferred one with a load wrongly.

### Multicycle path

A path that is allowed more than one clock because the logic only uses its result every second clock or later. In Gowin
a multicycle constraint hangs the placer, so this project gives such paths a `set_max_delay` instead
(`rtl/rx_backend/rx_backend.sdc`, 16.3 ns for two clocks).

## N

### N2ADR

The filter board on the HL2, a set of relay-switched low-pass filters for the amateur bands. See
[band filter](#band-filter).

### NCO

Numerically controlled oscillator: a phase accumulator to which a phase increment is added each sample, and a sine table
addressed by the phase. With 32 bits at 76.8 MHz the frequency step is 0.018 Hz. See [SDR_PRIMER.md](SDR_PRIMER.md)
section 4.

### Netlist

The output of synthesis: the design as a list of primitive cells (LUTs, registers, block RAMs, DSP blocks) and the nets
connecting them, which place and route then puts on the chip.

### Network unit

The RJ45 Ethernet interface in logic (`rtl/net/eth_top.v`, wrapped by `net_unit.v`): 100 Mbit/s, clocked by `clk_eth` at 100 MHz, register page 0xE924_0000.

### Noise blanker

A stage that detects short, strong pulses (ignition, electric fences) by comparing the signal's magnitude with a
running floor, and replaces the samples during a pulse by the last good one. It is the first step of the back end
(`rtl/rx_backend/bk_front.v`).

### Noise floor

The level of the background noise in a spectrum or a receiver when no signal is present. The waterfall's automatic
level puts the noise floor (the 25th percentile of a line) on palette index 32.

### Noise reduction

Processing that lowers steady background noise in audio, here spectral subtraction in the firmware at 12 ksps. It is
the one receive stage kept in software, because it is still changing.

### NRX

The build setting for the number of receivers, 1 to 8 (`TR_NRX` in `gowin/p1/build.sh`, default 4). The register map
always has room for 8; receivers beyond the built count read 0, and the chip reports its count in
`system.status.num_rx`.

### NRZI

Non-return-to-zero inverted: a line code in which a 0 is sent as a change of level and a 1 as no change. USB full speed
uses it, together with bit stuffing.

### Nyquist frequency

Half the sample rate, the highest frequency a sampled signal can represent: 38.4 MHz for the 76.8 Msps stream.

## O

### One-hot

A set of bits of which exactly one is high, used to encode a choice so that each option is one wire. Arbiter grants in
this design are often one-hot registers.

### OSD

Ordered statistics decoding: a slower, stronger decoder for codes such as FT8's LDPC, tried when belief propagation
fails. It runs on the processor.

### OSER10

Gowin's 10-to-1 output serializer primitive. It turns each 10-bit TMDS word into a bit stream at the pin, using a clock
five times the pixel clock on both edges; the HDMI output uses four of them.

### OTP

One-time programmable memory inside the FPGA, which holds a unique device number (Gowin calls it DNA). The chip ID
reader `rtl/net/chip_dna.v` reads it.

## P

### Palette

A table that turns an 8-bit waterfall value into a 24-bit color. The compositor has two palettes of 256 entries, one per
waterfall window; index 0 is black.

### PCS

Physical coding sublayer: the part of an Ethernet interface between the MAC and the serial line that does the
[8b/10b](#8b10b) coding, the ordered sets that mark frame start and end, and auto-negotiation. `rtl/sfp/sfp_pcs.v`
for the SFP lanes.

### Phase accumulator

The register of an [NCO](#nco) that adds the phase increment every sample and wraps around at 2^32, one full turn.

### Phase increment

The number added to the phase accumulator every sample: round(f / 76.8 MHz x 2^32) for a receiver at frequency f. The
firmware writes it into each receiver's register.

### PHY

The chip (or block) that drives the physical line of a network link. The RJ45 socket has a Realtek RTL8211F PHY; the
SFP lanes use the FPGA's own transceiver and the module.

### Pipeline

A chain of registers that splits a long computation into short steps, one per clock, so each step fits the clock period
and a new input can enter every clock. Most fixes for failing paths in this design add pipeline stages.

### Place and route

The build step that puts each cell of the netlist on a site of the chip and finds a wire for each net, steered by the
timing constraints. It takes about an hour for this design.

### PLIC

Platform-level interrupt controller: the RISC-V unit that collects interrupt lines, gives them priorities and tells the
core which one to serve. The AE350's PLIC has 16 lines from the FPGA logic.

### PLL

Phase locked loop: makes new clock frequencies from an input clock by multiplying it up to a VCO frequency (650 to
1,300 MHz on the 138K, Gowin UG306 section 2.3) and dividing that down on each output. The design uses six.

### PMOD

A small 12-pin expansion header standard. The dock has three; PMOD0 carries the USB host board and PMOD2 the S/PDIF and
I2S outputs.

### Polyphase

A way to build an interpolating or decimating FIR that computes only the outputs (or uses only the inputs) actually
needed, by splitting the taps into phases. The audio engine's x8 interpolator is polyphase (`rtl/audio/audio_interp_x8.v`).

### ppm

Parts per million, used for clock accuracy. The HL2's clocks may each be 100 ppm off the board's; at +100 ppm the HL2
makes 1.0001 times the samples, which the link has room for.

### Pre-adder

The adder in front of a DSP block's multiplier, which can add two inputs before multiplying. A symmetric FIR uses it to
add the two samples that share a coefficient, halving the multiplies.

### Processing gain

The improvement in signal-to-noise ratio a narrow filter or a long FFT gives, because it collects the signal's power
while taking only a slice of the noise. It is why a 12-bit ADC sampling 38.4 MHz of spectrum can still hear weak
signals in a 2.4 kHz filter.

### PT8211

The board's 16-bit stereo DAC for the headphone jack and speaker, fed with LSB-justified serial data on three pins (bit
clock E22, word clock F24, data G24) at a bit clock of 12.288 MHz.

## Q

### Q format

A notation for [fixed point](#fixed-point) numbers: Qn means n bits after the binary point. "Q25 coefficients" are
integers that represent the value divided by 2^25.

### Quarter-wave table

A sine table that holds only one quarter of a period, the other three quarters being found by symmetry (mirroring the
address and changing the sign). The NCO mixer's table is 1,024 entries of 18 bits for the quarter.

## R

### Raw frame

A UDP datagram from the HL2's port 1024 whose first payload byte is 0xA5: a header (20, 40 or 48 bytes, with sequence
number, first-sample index, sample count, flags and the transmit-safety byte) followed by samples packed three bytes
for two 12-bit values. The wire format is in the HL2 release's `docs/rawfront/PROTOCOL.md`.

### Read-before-write

A block RAM mode in which a write returns the old content of the address on the same port. The 138K chip does not have
it (Gowin UG300 section 2.1), so a Verilog memory that would need it stops place and route with error PA2122.

### Register bus

The path from the processor's AHB port to every block's registers: `rtl/top/ahb_reg_bridge.v` carries each 32-bit access
into the clock domain of its page with a toggle handshake and waits for the answer, about 245 ns per access to a
`clk_dsp` page.

### Register page

A 64 KB slice of the processor's 0xE800_0000 window that belongs to one block, selected by address bits 23 to 16. For
example 0xE803_0000 is the receiver bank and 0xE80C_0000 the back end.

### Regmap

The register map, kept once in `hw/regmap/*.toml` (one file per page). A generator writes the Verilog include files in
`hw/regmap/generated/` and the Rust crate `fw/tr-regs` from it, so the hardware and the firmware cannot disagree.

### RGB565

A 16-bit pixel format with 5 bits of red, 6 of green and 5 of blue. The Slint framebuffer uses it.

### RGMII

Reduced gigabit media independent interface: the 4-bit, double-data-rate interface between an Ethernet MAC and an
external PHY such as the RTL8211F. The RJ45 unit uses its pins at 100 Mbit/s and samples the receive clock as data.

### Ring

A circular buffer in memory with a write pointer and a read pointer, where the writer starts again at the beginning
after the end. Almost all data between the logic and the processor moves through rings in DDR3 (audio, waterfall,
FT8) or block RAM (the HL2 link's packet rings).

### Round half up

The rounding the RTL and its models use unless stated otherwise: add half of the last kept bit, then shift right
arithmetically. A value exactly halfway rounds up.

### RTL

Register transfer level: hardware described as registers and the logic between them, which is what the Verilog in
`rtl/` is. Also used as a name for that source code.

## S

### S-meter

The signal strength display. The back end measures it per receiver in steps of 1/64 dB relative to a 2^23 envelope;
LISTEN adds 22.3 dB so it reads in [dBFS](#dbfs).

### SAM

Synchronous AM: AM demodulated against a carrier recovered with a phase-locked loop instead of with an envelope
detector, which fades less and keeps the sidebands apart. The back end does it with its CORDIC and a PI loop.

### Sample index

The 48-bit count of HL2 samples since the HL2 started, carried in every raw frame header. The gap filler uses it to
detect lost samples, and the back end stamps each audio block with it, so all parts of the radio share one time base.

### Saturate

To clamp a result to the largest or smallest value that fits instead of letting it wrap around. Comments say where a
stage saturates; anything not said to saturate wraps or is wide enough never to overflow.

### SDC

Synopsys design constraints, the text format for timing constraints that Gowin uses too (Gowin SUG940 chapter 5):
`create_clock`, `create_generated_clock`, `set_clock_groups`, `set_false_path`, `set_max_delay`.

### SerDes

Serializer-deserializer: the FPGA's high-speed transceiver that turns parallel words into a serial stream of up to
12.5 Gbit/s and back. The SFP cages use quad 1, lanes 0 and 1, through Gowin's SerDes IP (`rtl/sfp/sfp_serdes.v`).

### Setup time

The time a register input must be steady before the clock edge. A path that arrives later fails the setup check; this is
the usual failing path when a design is too slow. See [FPGA_PRIMER.md](FPGA_PRIMER.md) section 2.1.

### SFD

Start frame delimiter: the byte 0xD5 after the Ethernet preamble that marks where the frame begins.

### SFDR

Spurious-free dynamic range: the distance in dB between a signal and the strongest false tone. The full-band FFT
measured 93.3 and 94.4 dBc for tones just below full scale, set by the ADC.

### SFP

Small form-factor pluggable: a socket (cage) for a small network module, fiber or copper. The dock has two SFP+ cages;
SFP0 carries the HL2 through a copper module, SFP1 the optional board link.

### SGMII

Serial gigabit media independent interface: like [1000BASE-X](#1000base-x) on the wire, with a different
auto-negotiation meaning. Some copper SFP modules use it; the firmware falls back to it if 1000BASE-X does not link.

### Single-path delay feedback

A way to build a fast Fourier transform that has one stream of samples going in and one coming out, with a delay line in every stage that holds half of the stage's block while the other half passes through. Each stage adds and subtracts pairs of samples (a [butterfly](#butterfly)), sends the sums on and puts the differences into its delay line to come out during the following block, so the delay lines are the only memory the transform needs. `rtl/fft/fft_bf.v` is one such stage, and the name "single path" in its header means that only one stream passes through, in contrast to a design that splits the stream into two paths.

### Skid buffer

A one- or two-entry buffer that catches a word when the consumer stops taking words a clock late. The receiver bank's
output arbiter has one per receiver.

### Slack

The time to spare on a timing path: required arrival time minus actual arrival time. Positive slack passes, negative
slack is a failing path.

### Slint

A Rust GUI toolkit that can render in software without an operating system. The firmware's screens are written in its
`.slint` language (`fw/tr-gui/ui/`) and rendered into the RGB565 framebuffer.

### Slot

In FT8, one 15-second period aligned to UTC in which stations transmit; the decoder works on one slot at a time. The
radio captures each slot's audio by HL2 sample index.

### smoltcp

A Rust network stack for systems without an operating system. The firmware's network code (`fw/tr-net`) builds on it.

### SNTP

Simple network time protocol: how the radio gets UTC from the internet over the RJ45 link, since FT8 needs the time to
within about a second.

### Soft symbol

A symbol decision that keeps how sure it is (for FT8 the strength of each of the 8 tones), instead of only the most
likely tone. The FPGA's candidate engine computes them and the LDPC decoder uses them.

### S/PDIF

A one-wire digital audio format (IEC 60958). The radio sends 48 kHz audio on S/PDIF from a PMOD2 pin for a TOSLINK
transmitter module, clocked from `clk_aud` at 49.152 MHz.

### Spectrogram

A picture of a signal's spectrum over time, as rows of FFT bins. The FT8 front end computes one per slot: a 3,840-point
transform every 480 samples (40 ms), 1,024 bins of 3.125 Hz kept per row.

### Squelch

A gate that mutes the audio while the signal level is below a threshold. LISTEN's squelch works on the S-meter level
from -140 to -20 dBFS and closes 3 dB below where it opened.

### SSB

Single sideband: a voice mode in which only one sideband of an AM signal is sent, without the carrier. The receiver's
channel filter keeps one side, and the real part of the result is the audio. LISTEN's SSB filters are 2.4, 1.8 and
2.8 kHz.

### SSTL15

The 1.5 V I/O standard of DDR3 pins. Its drive strength matters: this project uses 12 on data, mask, address and
control, 4 on CKE, and 8 on the clock and strobes.

### Stage-0 loader

The first program the processor runs, from its SPI flash at the reset address 0x8000_0000. It loads the real firmware
image (checked by a CRC) into DDR3 and jumps to it. `fw/tr-loader` is this project's; the radio is currently started
through a network loader image that is not part of this repository.

### Sync search

The step of the FT8 front end that finds where in time and at which audio frequency a station's message starts, by looking in the [spectrogram](#spectrogram) for the seven-tone [Costas array](#costas-array) that every FT8 message carries three times. It tries every start time and frequency spacing in a range, adds up how much energy sits at the places where the Costas tones should be, and hands the best scores on as candidates, which `rtl/ft8/ft8_sync.v` does in the chip. The candidates are then cut out and measured symbol by symbol (see [soft symbol](#soft-symbol)).

### Synchronizer

Two or three flip-flops in a row on the receiving clock, through which a single bit from another clock domain passes
so that [metastability](#metastability) has settled before the bit is used.

### Synthesis

The build step that turns Verilog into a [netlist](#netlist) of the chip's primitive cells. Gowin's tool is
GowinSynthesis; yosys is used in this project for quick resource estimates.

## T

### Tap

One coefficient of a FIR filter, together with the delayed sample it multiplies. "A 65-tap FIR" sums 65 products per
output.

### TCI

Transceiver control interface: a WebSocket protocol (Expert Electronics, version 2.0) through which PC programs control
an SDR and receive its audio and IQ. It is designed for this radio and not built yet.

### TERC4

The 4-bit to 10-bit code HDMI uses for data islands. The hdl-util core does it.

### Testbench

A Verilog file that drives a block with test inputs in simulation and checks its outputs. The testbenches are in `sim/`,
one folder per block, and `sim/top/tb_sdr_core.v` runs the whole core.

### Thermometer mask

A set of bits where all bits below a position are 1 and all above are 0, like the column of a thermometer. The receiver
bank's round-robin arbiter keeps its position this way.

### Timing closure

The state in which every path of the design meets setup and hold at the real clock frequencies. The radio's build of
5 November 2026 was the first with zero failing end points.

### TMDS

Transition-minimized differential signaling: the coding of HDMI and DVI video, which sends each 8-bit color as a
10-bit word chosen to keep the line balanced. Three data pairs and a clock pair carry it.

### Toggle handshake

A clock-crossing method: the sender holds a value steady and flips one bit, the receiver sees the flip through a
synchronizer and takes the value, and flips its own bit back as an acknowledge. The register bus crosses every access
this way.

### Transmit-safety byte

A byte in every HL2 raw frame header that reports the HL2's transmit interlock state. The chip copies it to a register
on every frame, raises an interrupt when it changes, and forces the TX output to zeros at once when bit 7 (trip) or bit 6
(over-temperature) is set.

### Twiddle factor

The complex sine value an FFT butterfly multiplies by, e^(-j 2 pi k / N). The FFT core reads them from a table with 18-bit
entries (`rtl/fft/tw/`).

### Two's complement

The usual way to store signed integers: the top bit has a negative weight, so a 12-bit value runs from -2,048 to +2,047,
and addition works the same for signed and unsigned numbers.

## U

### UART

A simple serial port. The AE350's UART goes to the BL616 and appears on the PC as the debug cable's second serial port;
the radio's console runs at 184,320 baud.

### USB audio class

The standard way a USB device acts as a sound card without a driver. The radio is a full-speed USB Audio Class 1.0
device on its "Custom USB" socket, 48 kHz 16-bit stereo in both directions (`rtl/usb`).

### USB host

The side of a USB link that controls devices. The radio has a USB host in logic for a mouse, keyboard or headset on a
PMOD board (`rtl/usbh`, `fw/tr-usbh`).

## V

### Valid strobe

A one-bit signal that marks the clocks in which a data bus carries a new word. Streams slower than their clock use one
instead of a separate clock, so `adc_valid` and `out_valid` appear all through the RTL.

### VCO

Voltage controlled oscillator: the part of a PLL that runs at the high internal frequency (650 to 1,300 MHz on the 138K)
from which the outputs are divided. The DSP PLL's VCO is 1,200 MHz.

### Verilator

An open-source tool that turns Verilog into fast C++ simulation and also checks the code for common mistakes (lint).
Some benches and lint runs in `sim/` use it.

### VITA-49

A standard (ANSI/VITA 49.2) for packets of radio samples with time stamps and context. It is designed for this radio's
network streams, with time stamps from the HL2 sample index, and not built yet.

## W

### Waterfall

A spectrum display that scrolls over time: each new spectrum line becomes a row of colors at the top and older rows move
down. The FPGA writes the lines into DDR3 rings of 2,048 lines of 1,920 bytes and the compositor draws them through a
palette.

### Window

A function by which a block of samples is multiplied before an FFT, fading in and out at the ends, so that a tone that
does not fit the block exactly does not smear across all bins. See [Blackman-Harris window](#blackman-harris-window).

### WSPR

A very slow weak-signal beacon mode with 2-minute slots, planned to use the FT8 front end's candidate engine.

## X

### XIP

Execute in place: running code directly from flash memory without copying it to RAM first. The AE350 can execute from
its SPI flash at 0x8000_0000, which is how the first loader runs.

## Y

### yosys

An open-source synthesis tool. This project uses it with `synth_gowin -family gw5a` for quick resource estimates per
block (`tools/yosys_res.sh`); it cannot make a bitstream for this chip.

## Z

### Zoom receiver

The extra receiver that feeds the zoom spectrum and waterfall: an NCO mixer, CICs, a half-band filter and a CIC
compensator decimate to one of eleven spans from 3.072 MHz to 3 kHz, followed by a window and a frame buffer of 4,096
complex samples (`rtl/zoom/`). Each frame is played into the last twelve stages of the full-band FFT, which form a
4,096-point FFT, so the zoom needs no FFT of its own. LISTEN uses it at 12 and 24 kHz spans, FT8 and FreeDV at 6 kHz.
