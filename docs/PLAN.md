<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# fpga-sdr work plan

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Work packages (WP) small enough for one person to finish in a few days. Every WP has a done-test; wherever possible it
runs in simulation or on the PC, so most of the work finishes before the board is usable. Design references:
[ARCHITECTURE.md](ARCHITECTURE.md) (section numbers "A 3.2" etc.) and [BOARD.md](BOARD.md).

Rules for every WP:

- One branch per WP.
- Testbenches: iverilog or Verilator from oss-cad-suite; each prints PASS or stops at the first failure.
  Rust: `cargo test` on the PC.
- **No transmitting.** TX tests use the HL2's echo mode (register 0x31 = 5) or virtual DAC (0x31 = 1). The
  real DAC (0x31 = 3) and the key bit in TX_PERMIT need an explicit owner instruction for that run.
- Gowin-generated IP is not committed: only `.ipc` files plus the regeneration script (A 7).

Status key: **in progress**, ready (can start now), blocked (by the listed WP), board (needs the board).

## Priority order (owner, 2026-09-27): a working FT8 transceiver first

**Owner, 2026-10-12: FreeDV (S9) is the next mode after FT8**, ahead of FT4, WSPR, CW decode, RTTY/PSK31, SSTV and JS8. Receive first (codec2 port in `no_std` Rust plus our modem, audio through the back end and the audio outputs); transmit waits for a microphone input.

**Owner, 2026-10-13: the target chip is 4 receivers with the zoom** (8 receivers does not fit with it); the receiver count is one build setting (`TR_NRX`, default 4), and 8 receivers without the zoom stays a build variant (docs/DECISIONS.md).

Everything on the FT8 path below comes first; everything else waits until FT8 works on the
board. Working rules (owner): while developing a package, run only its own tests and not the full `tools/check.sh`; run
one combined check per merged batch; put long runs in the background; bundle related WPs into one piece of work.

FT8 path, in order:

1. Running now: F5 (spectrogram engine), FO3 + S17 + FO2 (CPU half: cheaper BP/LLR, scheduler), timing2
   narrowed to the receiver back end and the TX chain.
2. F6 + F7 as one piece of work: Costas sync search and candidate engine.
3. H2 + H3 as one piece of work: TX sample path to the HL2 and the RTL8211F Ethernet PHY/pins.
4. **P1 (new): chip top level.** One Gowin project wiring the FT8-path blocks: HL2 link RX/TX, receiver
   bank, back end, F5-F7, TX chain, DDR3 controller IP + lane arbiters, video + compositor, AE350 bus
   bridge, register map, PLLs, pin constraints; full-chip synthesis and place-and-route at 150 MHz.
5. **P2 (new): FT8 firmware.** C3 drivers (`tr-fabric`) for the FT8-path blocks; S14 FT8 encoder only;
   FT8 screen in the GUI (decode list, click to answer, CQ, TX slot even/odd, TX frequency); UTC time
   from the network (SNTP over the SFP link, owner decision 2026-09-27); V2 compositor (Slint layer +
   waterfall).
5a. **N1 moved onto the FT8 path** (needed for network time): SFP 1000BASE-X PCS that also accepts SGMII
   (cheap copper modules differ), MAC reusing H2's, and a minimal no_std IP stack in Rust (ARP, DHCP, UDP,
   SNTP client). Starts after H2 + H3 are merged.
6. Board bring-up B1-B7, then B6/B7 on FT8: decode real stations, then (owner's go only) one real QSO.

Added 2026-10-12: the timing, block-RAM, bring-up and DDR3 work that follows from results
on the same board is listed in priority order under "Proposed by lessons" at the end (LS1 to LS9;
[TANG_LESSONS.md](TANG_LESSONS.md)). LS1 to LS6 are P1's blockers and belong to items 4 and 6 above.

Paused until FT8 works: WSPR, CW decode, RTTY/PSK31, SSTV, JS8, FreeDV (S6-S9), TCI and VITA-49 (S12,
S13, N2), audio mixer (A2), RB5, RB9, RB10, zoom and spectrum timing/BSRAM polish, S4, S18.

## Track T: tools and repository

| WP | What | Done-test | Depends | Status |
|---|---|---|---|---|
| T1 | Gowin EDA **Standard** 1.9.11.x installed, licence working (Sipeed floating server now; ask Gowin for a node-locked licence). Build Sipeed's `ae350_demo` and a blink design for GW5AST-LV138FPG676A, device version B. Write `docs/TOOLCHAIN.md` | Both bitstreams build from the command line (`gw_sh`); licence steps written down | owner provides or approves the licence | ready, **blocks every bitstream** |
| T2 | Repository skeleton: `rtl/`, `sim/`, `gowin/`, `hw/regmap/`, `fw/` Cargo workspace, `tools/check.sh` that runs every testbench and `cargo test` | `tools/check.sh` passes on the skeleton | none | done 2026-09-25 |
| T3 | Register-map generator: `xtask regmap` turns `hw/regmap/*.toml` into a Verilog include (addresses, field positions) and the `tr-regs` crate | A sample block round-trips: iverilog testbench and Rust test agree on every address and field | T2 | ready after T2 |
| T4 | Rust toolchain: rustup to at least 1.93 (mfsk-core needs 1.93, Slint 1.92), add `riscv32imafc-unknown-none-elf`, install QEMU for RISC-V | `cargo build --target riscv32imafc-unknown-none-elf` of an empty `no_std` binary; `qemu-system-riscv32 --version` | none | done 2026-09-25 |

## Track R: receivers (FPGA)

| WP | What | Done-test | Depends | Status |
|---|---|---|---|---|
| R1 | **Receiver bank** (branch `rx-dsp`): CORDIC, CIC, FIR, N receivers, shared output stream, interface as in A 3.2 | Testbench with generated tones of known frequency and level: output frequency and level as predicted (document tolerance), alias/image rejection measured, all 4 rates, N = 8, `adc_valid` bursty at 51 % as well as every cycle. Gain and group delay per rate written into its doc | none | **in progress** |
| R2 | Bit-exact Rust model of the receiver bank in `tr-dsp` | Same input file through iverilog and the model: identical output words | R1 | blocked by R1 |
| R3 | Gowin multiplier/BSRAM wrappers (pattern: HL2 `gateware/rtl/primitives/*/multipliers.v`) and place-and-route of `rx_bank` N = 8 alone at 150 MHz | Timing met or worst slack reported; resource table (LUT, DSP, BSRAM) added to this plan | R1, T1 | blocked |

## Track H: HL2 link (FPGA)

| WP | What | Done-test | Depends | Status |
|---|---|---|---|---|
| H1 | Receive: RGMII RX, MAC with CRC check, classifier, raw-frame parser, CDC FIFO, gap filler, CPU receive ring, safety-byte register and interrupt (A 3.1) | Far end in the testbench is the HL2's own RTL (`rawstream.v` + Ethernet send modules from the release branch, as `gateware/sim/rawstream/run.sh` builds them) in test-pattern mode with a 50 ppm clock offset: every sample equals `(index) mod 4096` over 20 ms of stream; a frame with a flipped bit is dropped and replaced by exactly N zero samples; a discovery reply lands in the CPU ring; a safety-byte change raises the interrupt | T2 | ready |
| H2 | Transmit: TX sample framer, one-sample-per-`adc_valid` rate lock and fill trim, CPU transmit queue, MAC TX, RGMII TX (A 3.1, 3.6) | Far end is the HL2's `txsink.v` + Ethernet receive modules with a 50 ppm offset: after lock the HL2 TX FIFO fill stays within 12,000 +/- 2,000 for 50 ms of simulated time, 0 underflows, 0 overflows; frames arrive in echo mode back through H1 with the expected offset | H1 | blocked by H1 |
| H3 | RTL8211F: MDIO, delay settings, 25 MHz reference from a PLL, pin constraints from the dock schematic | Constraints file complete; MDIO read of the PHY ID in simulation against a register model | T1 | blocked (needs RX pins from the schematic) |

## Track F: spectrum (FPGA)

| WP | What | Done-test | Depends | Status |
|---|---|---|---|---|
| F1 | **FFT decision**: 16k streaming FFT, own design vs ZipCPU `dblclockfft` (LGPL-3.0) vs Gowin FFT IP. Compare accuracy, DSP/BSRAM use, simulation without encrypted models | Tone test: peak in the right bin, spurious-free range measured; resource numbers from Gowin place-and-route; decision written into A 3.3 | T2 (T1 for resources) | ready |
| F2 | Full-band spectrum pipeline: window, FFT, power, dB, column mapping (max/mean), averaging, peak-hold, line buffers, waterfall line output (A 3.3) | Tones of known frequency and level plus noise: peak in the expected column, level within 0.5 dB, averaged noise-floor spread matches theory for K = 156 | F1 | blocked by F1 |
| F3 | Zoom DDC + 4k FFT (A 3.4) | Tone 1 kHz off the zoom centre at 48 kHz span lands in the right bin; spans 48 k to 3.072 M | R1, F1 | blocked |
| F4 | DDR3 lane arbiters and waterfall writer against a behavioural model of the shared-DDR3 write and read lanes (port list MUG1031 section 5) | Random lane stalls: every word written and read back, priority order held, video reader never starved in the model | T2 | ready |

## Track V: video (FPGA)

| WP | What | Done-test | Depends | Status |
|---|---|---|---|---|
| V1 | Video timing, hdl-util/hdmi integration with audio packets, test pattern; 1080p60 and 1080p30 modes | Verilator: TMDS decoder in the testbench recovers the test pattern and finds audio sample packets; Gowin place-and-route at 1080p60 reports serializer timing (risk 2) | T2 (T1 for P&R) | ready |
| V2 | Compositor: Slint layer from the DDR model, windows, spectrum trace, waterfall with palette, grid, passbands, filter curves, key colour (A 3.5) | Verilator renders one frame from fixed inputs to a PNG that equals, pixel for pixel, a PNG from a Rust reference model | V1, F4 | blocked by V1 |

## Track X and A: transmit and audio (FPGA)

| WP | What | Done-test | Depends | Status |
|---|---|---|---|---|
| X1 | TX chain: ring reader, FIR x4, CIC x400, CORDIC up-mix (HL2 `cpl_cordic.v`), 12-bit output, zeros when disabled or on a trip (A 3.6) | Two-tone baseband: FFT of the 76.8 Msps output shows both tones at the right RF, everything else below -70 dBc from 0 to 38.4 MHz (threshold to be confirmed by the owner); output is zero within 1 sample of disable or trip | T2 | ready |
| A1 | Audio engine: ring reader, x8 interpolation, PT8211 LSB-justified serializer, feed to HDMI audio (A 3.7) | Testbench decodes the serial pins back into samples equal to the input; interpolator images below -60 dB | T2 | ready |

## Track N: SFP network (FPGA)

| WP | What | Done-test | Depends | Status |
|---|---|---|---|---|
| N1 | 1000BASE-X: Gowin SerDes and PCS IP or open PCS, our GMII MAC, packet rings (A 3.8). Decide which PCS | Simulation loopback MAC -> PCS -> MAC passes frames with CRC; auto-negotiation completes against a link-partner model | T1 | ready, low priority |

## Track C: CPU platform (firmware)

| WP | What | Done-test | Depends | Status |
|---|---|---|---|---|
| C1 | `tr-ae350`: start-up (riscv-rt), trap handling, PLIC, machine timer, UART2, CCTL cache operations, FPU enable, linker script for the A 5.4 memory map, all from MUG1029 register descriptions | Builds for `riscv32imafc`; the target-independent parts run under QEMU `virt` (hello, timer interrupt, trap on illegal instruction) | T4 | ready |
| C2 | Stage-0 loader in flash (copies image to DDR3, checks CRC, jumps) with a UART loader; image format and packer in `xtask` | Under QEMU: an image sent over the emulated UART is loaded, CRC-checked, started; a corrupt image is refused | C1 | blocked by C1 |
| C3 | `tr-fabric` drivers for rings and every block, against `tr-regs` | Host tests with a mock register space: ring pointer arithmetic, cache-operation calls at the right addresses | T3 | blocked by T3 |

## Track S: firmware functions, developed on the PC

| WP | What | Done-test | Depends | Status |
|---|---|---|---|---|
| S1 | `tr-hl2` with a `std` feature: discovery, DHCP server, start/stop, register writes, bridge reads, I2C, safety byte, filter selection. Wire format from rawcap `protocol.rs`. **Never sets the key bit** | On the PC against the real HL2: status read; 10 s stream with 0 gaps; filter bits written and the MCP23008 latch read back over the bridge I2C; AM-band level in a capture with bit 23 on and off (settles the high-pass polarity question, A 8) | T2 | ready |
| S2 | CPU benchmark harness: `tr-dsp` kernels, mfsk-core FT8 decode of a recorded slot, Slint software rendering of a 1,920 x 1,080 panel, all built for `riscv32imafc` and run under QEMU with instruction counting | Table of instructions per task in A 5.5, replacing the estimates (cycles follow on the board) | T4, S3 (kernels) | ready after T4 |
| S3 | `tr-dsp`: fast-convolution filters, AGC, SSB/CW/AM/FM demodulators, noise blanker, noise reduction, resampler, CW keying shape | Host tests with generated signals (passband and stopband, AGC attack and decay, demodulated tone frequency and SNR); a real HL2 capture demodulated to a WAV file that sounds right | T2 | ready |
| S4 | `tr-sim`: live HL2 or capture -> receiver model (R2) -> `tr-dsp` -> WAV or PC audio; spectrum in a window | Tune an on-air SSB signal from the owner's antenna capture and hear it | S1, S3, R2 | blocked |
| S5 | `tr-modes` FT8/FT4/WSPR through mfsk-core, `no_std` build | Decodes on WSJT-X sample recordings and on real captures match WSJT-X on the same audio (at least 90 % of its decodes); builds for `riscv32imafc` | T2, T4 | ready |
| S6 | CW decoder, RTTY, PSK31 modems | Generated signals at stated SNRs decode without error; real captures decode | S3 | later |
| S7 | SSTV | Decodes a standard test recording to an image | S3 | later |
| S8 | JS8 | Decodes JS8Call sample recordings | S5 | later |
| S9 | FreeDV: codec2 port (`micromath` for `no_std`) plus our modem | Round trip on the PC; decodes a FreeDV reference recording | S3 | receive: modem, codec, firmware mode, screen and text channel done (docs/FREEDV.md section 9; never on the board); transmit on hold; 1600 not done |
| S10 | `tr-filters`: N2ADR responses from the schematic and BOM values | Cut-off and pass-band loss within 1 dB of the DK1CG VNA plots on the HL2 wiki; curves exported as tables for the compositor | T2 | ready |
| S11 | `tr-gui`: front-panel UI in `.slint`, 1,920 x 1,080 and 1,024 x 600, key-colour windows, software-renderer path into an RGB565 buffer | PNG screenshots at both sizes; the software-renderer image equals the desktop render | T4 | ready |
| S12 | `tr-tci`: TCI 2.0 server inside `tr-sim` | WSJT-X (TCI) connects to `tr-sim`, tunes it and decodes FT8 from the live HL2; TX audio is accepted but routed only to echo mode | S4 | blocked |
| S13 | `tr-vita49`: encoder and profile document | Packets from `tr-sim` parse with the `vita49` crate on the PC; timestamps match the HL2 sample index | S4 | blocked |
| S14 | TX baseband: FT8/WSPR encoders, CW, SSB from a WAV; full TX path through the PC to the HL2 **in echo mode** | Echoed samples match the generated baseband after the model of the FPGA TX chain (X1) | S1, X1 | blocked |

## Track B: on the board (from about 2026-09-29)

In order; each needs T1.

| WP | What | Done-test |
|---|---|---|
| B1 | Power-up with Sipeed demos: blink, UART through the BL616, DDR3 test; note the DDR3 chips, HDMI connector type, speaker amplifier | Demos run; BOARD.md open questions 5 answered |
| B2 | V1 bitstream: HDMI test pattern at 1080p60 and 1080p30 with a test tone as HDMI audio (**risk 2**) | Owner's monitor shows a clean pattern and plays the tone; decision 60 or 30 Hz recorded |
| B3 | C1/C2 on the AE350: UART hello loaded by GDB (or the UART loader), then boot from flash (**risk 3**) | Hello at power-up without a PC |
| B4 | Shared-DDR3 stress: video scan-out + fabric traffic + CPU memory loop (**risk 4**) | 10 minutes without a video line underrun; otherwise switch to the fallback in A 3.9 |
| B5 | H1-H3 on hardware with the HL2 | 10-minute stream with 0 gaps and 0 CRC errors; echo both ways with every sample matching |
| B6 | R1 + IQ writer + firmware demodulation to headphones and HDMI audio | An on-air SSB signal heard on both |
| B7 | F2/F3 + V2: spectrum and waterfall on the monitor, filter curves shown | Known signal at the right place and level |
| B8 | S11 Slint panel on the monitor with FPGA windows; S2 cycle counts on the real CPU | A 5.5 budget table updated with measured cycles |
| B9 | N1: SFP link to the home network (needs the owner's SFP module) | TCI client on the PC connects over the SFP link |

## What can run in parallel now (before the board)

Independent, can start at once, each in its own worktree:

- FPGA, simulation only: **H1**, **F1**, **F4**, **V1**, **X1**, **A1** (plus R1 already running).
- Firmware on the PC: **S1**, **S3**, **S5**, **S10**, **S11**, and **C1** after T4.
- Tools: **T2** first (small, most WPs build on it), **T4**, and **T1** as soon as the owner settles the licence.

Chains that follow: R1 -> R2 -> S4 -> S12/S13; H1 -> H2; F1 -> F2/F3; V1 -> V2; C1 -> C2; T3 -> C3.

Critical path to "radio on the monitor": T1 -> B1 -> B2/B3 -> B5 -> B6 -> B7 -> B8. Everything else feeds
into it pre-tested.

## Proposed by cpu-budget

Proposed by the cpu-budget work (`docs/CPU_BUDGET.md`, ARCHITECTURE 3.10-3.14 and 5.5). Not yet accepted
into the tracks above. Each FPGA block gets a bit-exact Rust model first, so the testbench compares RTL output
with the model word for word.

| WP | What | Done-test | Depends | Status |
|---|---|---|---|---|
| R4 | **Receiver back end** (A 3.10): noise blanker, decimation to 24 ksps, 1,024-tap complex channel filter with double-buffered coefficients, SSB/CW/AM/SAM/FM/IQ demodulator (shared CORDIC), half-band to 12 ksps, log-domain AGC, S-meter level, audio rings with HL2 index stamps; bit-exact Rust model in `tr-dsp` | Model and RTL identical word for word on generated tones and noise for every mode and all 4 input rates; USB/LSB opposite-sideband rejection and CW 300 Hz filter skirts within 1 dB of the float design; AGC attack/decay within 10 % of the `tr-dsp::agc` time constants; 8 receivers in one run with bursty `adc_valid`; yosys DSP/BSRAM count entered in A 3.14 | R1 | proposed |
| A2 | **Audio mixer and HL2-locked audio clock** (A 3.11): per-receiver volume/pan/mute/source (back end or NR return ring), sum, x4 interpolation, add the firmware ring, feed A1; DPLL trimming `audio_nco_tick` to `adc_valid`/1,600 | With `adc_valid` 50 ppm off the board clock and bursty, the 48 kHz tick count tracks `adc_valid`/1,600 within 1 sample over 10 simulated seconds and no ring over- or underflows; tick jitter stays one `clk_dsp` period; two receivers at different pans come out on the right channels at the set levels (0.1 dB) | A1, R4 | proposed |
| F5 | **FT8/FT4 spectrogram engine** (A 3.12 a, b): slot capture to DDR3, 3,840-point (256 x 15) transform every 480 samples per decoder receiver, power to a DDR3 ring | RTL equals the S15 model bit for bit on `captures/ft8/*.wav` fed as 12 ksps audio; FT8 tones land 2 bins apart; engine busy time under 10 % with 8 receivers | S15, F4 | proposed |
| F6 | **Costas sync search engine** (A 3.12 c): per-bin best lag and score over the spectrogram, stripe buffering, early-decode triggers | Per-bin results equal the S15 model; the S15 candidate list built from them contains every signal WSJT-X decodes in `qso1.wav` and `qso3_busy.wav`; under 30 ms per receiver in simulation | F5 | proposed |
| F7 | **FT8 candidate engine** (A 3.12 d): 8-lane slot replay, NCO mix, CIC/60 + FIR to 200 sps baseband, then 79 x 8 tone DFTs at refined time/frequency | Baseband and soft symbols equal the S15 model bit for bit; 60 candidates of 8 receivers processed in under 0.2 s of simulated time; LDPC on the soft symbols decodes the same messages as S15 | F6, S15 | proposed |
| N2 | **VITA-49 stream framer** on the SFP MAC (A 3.13) | Packets from the testbench parse with the `vita49` crate; timestamps equal the block stamps; 8 x 384 ksps streams sustained with CPU packets interleaved | N1, S13 | proposed, low priority |
| S15 | **FT8/FT4 front-end reference model** in Rust (`tr-modes`): slot buffer, 3,840-point spectrogram, Costas sync search with `sync8`-style normalisation, candidate down-conversion to 200 sps, soft symbols; feeds mfsk-core's LDPC/unpack (or our own) and does subtraction on the CPU. Fixed-point exactly as F5-F7 will be | On the WSJT-X sample recordings at least as many decodes as mfsk-core's own pipeline at the same candidate count; instruction count under QEMU of the CPU part (everything the FPGA does not do) under 315 M per slot per receiver | S5 | proposed |
| S16 | **FT8 on the target, measured and fixed**: commit the `bench-ft8` kernel in `tr-bench` (the cpu-budget scratch harness: mfsk-core, size-class allocator, sampling profiler); plan-caching mixed-radix FFT backend for mfsk-core's `fft-extern` hook (the Stockham 4/2/3/5 FFT from the harness); OSD on embedded builds (mfsk-core compiles it out; patch upstream or our own OSD) | `tools/qemu_s2.sh` prints FT8 instructions per slot for `qso1` and `qso3_busy`; with OSD the target decodes as many signals as the host build at the same settings (host 30 candidates: 12 on `qso3_busy`, target today 7) | S5 | proposed |
| S17 | **Decode scheduler**: per-slot FT8/FT4 job queue, operator's receiver first, per-receiver CPU cap measured with `mcycle` (owner decision 1 in CPU_BUDGET section 8), candidate count and OSD attempts adapted to stay inside it | Under QEMU with 8 recorded slots: every decode job stays within its cap; the operator's receiver's results come first; total CPU per slot matches the budget within 10 % | S15, S16 | proposed |
| S18 | **Firmware on the new split**: coefficient design for the back end (from `fastconv::BandpassFilter::design`), NR task at 12 ksps on the back-end audio ring with return ring, back-end and mixer register drivers | Host test: coefficients written for USB 300-2,700 Hz give the same response as the float filter within 0.1 dB in the passband; under QEMU the NR task for 8 receivers stays under 8 x 3.6 M instructions/s | R4, A2, C3 | proposed |
| C4 | **FP registers and traps**: riscv-rt saves only integer registers; with `+d` FP registers are 64 bit. Either forbid FP in interrupt handlers (handlers only wake tasks) with a check, or save/restore the caller-saved FP registers with `fsd`/`fld` in the trap entry | Under QEMU a timer interrupt handler that uses FP, firing during an FP loop in the main task, leaves the main task's results bit-identical to a run without interrupts | C1 | proposed |
| B10 | **IPC on the board**: `mcycle` and `minstret` around every `tr-bench` kernel and the FT8 decode; try `-C target-cpu=andes-a25` (XAndesPerf) there | A 5.5 and CPU_BUDGET section 6 updated with measured IPC per kernel; `andes-a25` adopted or rejected with numbers | B3, S16 | proposed |

## Proposed by rebalance

Proposed by the rebalance work (ARCHITECTURE 3.14, which has the arithmetic and the cost of every change;
the C-numbers below refer to it). Not yet accepted into the tracks above. Together these bring the chip from
261 DSP / 353 BSRAM / over 244,000 logic (the design as it stands) to 164 DSP (55 %) / 226 BSRAM (66.5 %) /
about 104,000 logic (75 %) without dropping any capability. Every resource figure in a done-test is from
`tools/yosys_res.sh` (yosys gw5a, multipliers counted as DSP) until Gowin numbers exist (RB10).

| WP | What | Done-test | Depends | Status |
|---|---|---|---|---|
| RB1 | **Zoom FIRs time-multiplexed** (C7): `zoom_fir_half` and `zoom_cic_comp` each with one multiplier per channel; the half-band's delay line a circular buffer of at least 320 samples in one BSRAM, a 256-entry input FIFO for the compensator, so HL2 frame bursts are absorbed | `zoom_spectrum` output word for word equal to the current parallel RTL on `tb_zoom_quick.v` and on a run where `adc_valid` comes as whole 5,968-sample frames on consecutive clocks (51 % average) at the widest span; `tools/yosys_res.sh zoom_spectrum`: at most 26 DSP (4 of them the FIRs), logic at most 15.5k | F3 | proposed |
| RB2 | **TX FIR time-multiplexed** (C8): `tx_fir_interp4` with one multiplier for all 10 taps x I/Q | X1 testbench output word for word equal to the current RTL (two-tone and disable/trip cases); `tools/yosys_res.sh tx_chain`: FIR 1 DSP, logic at most 10k | X1 | proposed |
| RB3 | **Receiver bank logic** (C2, C3): FIR delay lines as circular buffers in BSRAM (two receivers per block, no snapshot copy); two shared 5-stage variable CIC engines, 4 receivers x I/Q each, state in BSRAM | `rx_bank` N = 8 output word for word equal to the post-`r1-fix` RTL on the R1 testbenches, all 4 rates, `adc_valid` every clock and bursty at 51 %; `tools/yosys_res.sh rx_bank`: logic at most 38k (CORDICs still in), registers at most 20k, BSRAM at most 6 | R1 fixes merged (`r1-fix`) | proposed |
| RB4 | **NCO mixer instead of CORDIC** (C1) in the receiver bank, the zoom DDC and the TX chain: phase accumulator, 1,024 x 18-bit quarter-wave table in one dual-port BSRAM, first-order Taylor correction, 4 DSP; R2's bit-exact model follows | Standalone: spurious-free range at least 100 dBc for a full-scale 12-bit tone at 1,000 random tuning words (FFT of the output, tone excluded), level within 0.01 dB of ideal. In place: R1's alias/image results within 1 dB of the CORDIC version, F3's alias rejection unchanged, X1's two-tone test still below -70 dBc; R2 model and RTL word for word; `tools/yosys_res.sh`: at most 400 logic, 4 DSP, 1 BSRAM per mixer | RB1, RB2, RB3 | proposed |
| RB5 | **Back-end channel filter with real prototype banks** (C4) and **per-receiver settings in RAM** (C5): banks hold 512 real 32-bit taps (one BSRAM each); per-receiver centre-frequency accumulator; input rotated by -wc before and the output by +wc after the filter, rotation error at most 2^-25; firmware designer writes the prototype and the centre; bit-exact model in `tr-dsp::backend` updated. Fallback if 2^-25 is not reached: 27-bit complex banks | R4's own done-tests unchanged: USB/LSB 300-2,700 Hz opposite-sideband rejection at least 140 dB for mirror tones 500-2,500 Hz, shape within 0.05 dB of the float design to -110 dB and 0.5 dB to -126 dB, AGC constants, every mode and rate, RTL and model word for word; new: one bank used by two receivers at different centres gives both the float response; `tools/yosys_res.sh rx_backend`: BSRAM at most 49, DSP at most 9, logic at most 19k | R4 | proposed |
| RB6 | **One spectrum back end for both spectra** (C6): log-domain K-average instead of the divide, window ROM at every 8th point with linear interpolation, one column buffer plus a 512-entry arrival FIFO, and the same walk engine serving the zoom stream (its own column buffer, K accumulator, line buffers, column tables) | F2's done-test passes on both streams (zoom: 1 kHz tone off centre at 48 kHz span in the right column, level within 0.5 dB, noise-floor spread as theory for its K); full-band spurious-free range for -1 dBFS tones at 7.1 and 30 MHz unchanged (at least 93 dB); dB values within 1/64 dB of the current F2 RTL on the same input; `tools/yosys_res.sh`: F1 + F2 + zoom back end at most 15k logic and 81 BSRAM | F2 merged, RB1 | proposed |
| RB7 | **HL2 link RX memories** (C11): the two raw-frame banks become one 8,192-sample ring with a registered read; the CPU receive ring 4 KB with one write port per clock (length word through the second port) | The H1 testbench passes unchanged (every sample over 20 ms, bad-CRC frame replaced by exactly N zeros, discovery reply in the CPU ring, safety interrupt); `tools/yosys_res.sh hl2_link_rx_top` completes, logic at most 3.5k, registers at most 3k, BSRAM at most 9 | H1 | proposed |
| RB8 | **FT8 front-end memory plan into F5-F7** (C9): spectrogram accumulates the 15 sub-FFT outputs into 1,024 bin accumulators; Costas sync streams spectrogram rows from DDR3 in lag order (no stripe buffer); candidate engine with 2 lanes. Amends the F5, F6, F7 rows above | Added to F5: BSRAM at most 10. Added to F6: per-receiver sync search at most 60 ms in simulation with the F4 video traffic model running, BSRAM at most 3. Added to F7: 480 candidates (8 receivers x 60) in at most 0.4 s of simulated time with video traffic, DSP at most 16, BSRAM at most 5. All still bit-exact with S15 | S15 | proposed |
| RB9 | **Buffer sizes for blocks not yet built** (C10, C12, C13, C14): H2's TX sample FIFO cut-through at 2,048 samples (start a frame at 1,000); N1's packet rings in DDR3 with two received frames and one frame to send in BSRAM; the IQ writer in 4-word bursts from one shared FIFO; V2's memories as listed in C10 with filter curves at every 8th column. Amends the H2, N1, V2 rows and the IQ-writer part of R1/F4 | Added to H2: HL2 FIFO fill test unchanged with the 2,048-sample FIFO, 0 underruns in 50 ms. Added to N1: loopback at line rate through the F4 DDR3 model with no lost frame while video traffic runs. Added to V2: the frame PNG equals the reference with curves interpolated the same way in the Rust model. Each: BSRAM as in 3.14 (2, 4, 1, 12) | H2, N1, V2 as listed | proposed |
| RB10 | **Gowin numbers for the largest blocks**: Gowin synthesis and place-and-route at 150 MHz of `rx_bank` (after RB3, RB4), `rx_backend` (after RB5) and `zoom_spectrum` (after RB1, RB4); logic, DSP, BSRAM and the Gowin-to-yosys ratio entered in ARCHITECTURE 3.14; the owner decision in 3.14 taken again on those numbers | Gowin utilisation and timing reports for the three blocks committed under `gowin/reports/`; 3.14 updated; ratio stated | T1, RB1-RB5 | proposed |

## Proposed by ft8offload

Proposed by the ft8offload work (PLAN FO1, `docs/FT8_OFFLOAD.md`, ARCHITECTURE 3.12 "FT8 back end: where it
runs"). Not yet accepted into the tracks above. The answer to the owner's question (a soft RISC-V core in the
fabric for the FT8 back end) is no: the back end stays on the AE350, and the full mfsk-core ladder fits the
existing per-receiver cap once OSD is rewritten (FO1, done).

| WP | What | Done-test | Depends | Status |
|---|---|---|---|---|
| FO1 | **FT8 back end: measure, decide, software first**: the three mfsk-core hooks (per-candidate soft-symbol entry with outcome and rung, OSD effort, a-priori switches; VENDOR_PATCH fix 6), bit-packed OSD kernels with a linear CRC syndrome (fix 7), effort sweeps, soft-core and fabric-engine sizing | Hooks reproduce mfsk-core's decodes exactly on the three recordings; packed OSD equals the reference on 1,600 LLR vectors and on the target; full ladder at 60 candidates under 315 M instructions per slot on every recording; decision in ARCHITECTURE 3.12 | S15, S16 | done 2026-09-26 |
| FO2 | **Scheduler effort defaults** (amends S17): the CPU half calls `decode_soft_symbols` per candidate with effort `full` (mfsk-core's ladder, packed OSD) on every candidate of every receiver (no `osd_max` rationing), `CandidateWork` ticks (`mcycle` on the board) against the 30 Mcycles/s cap, headroom spent on more candidates first; two passes only on the operator's receiver | Under QEMU, the three recordings as 8 receivers: every receiver's slot within 315 M instructions at 60 candidates with decodes equal to the unrationed full ladder's; operator's receiver with two passes within 945 M; a slot whose ladder would exceed the cap is cut at a candidate boundary and says so (`BudgetReport`-style count) | S17, FO1 | proposed |
| FO3 | **Cheaper LLRs and belief propagation in software**, now the largest part of the ladder (per failed candidate: LLR set 2.3 M, four min-sum runs 2.2 M each, a-priori sum-product runs 3.6 M each): fixed-point (Q11) min-sum where mfsk-core already has it, min-sum instead of sum-product in the a-priori passes, LLR variants b and c only when their BP will run | Sensitivity within 0.1 dB of `full` in both `effort-sweep` kinds (ordinary and CQ, 200 trials/step); every recording decodes the same messages; `tools/qemu_fo1_kernels.sh` shows BP and LLR instructions per failed candidate at least halved | FO1 | proposed |
| FO4 | **Reserve, only on owner decision: fabric min-sum LDPC engine** (ARCHITECTURE 3.12 option c) for the ladder's belief propagation and the OSD seeds, driven by the AE350; trigger: B10's measured IPC or real busy-band candidate counts push FT8 over its cap after FO3 | Bit-exact Rust model; RTL equals it word for word on 10,000 LLR vectors; sensitivity within 0.3 dB of the software ladder in both sweep kinds; `tools/yosys_res.sh` at most 1.2k logic, 4 BSRAM, 0 DSP; FT8 CPU per slot reduced by at least the measured BP share | FO3, B10 | proposed, conditional |
| FO5 | **Offer fixes 6 and 7 to mfsk-core upstream** (pull request to github.com/jl1nie/mfsk-core), so the vendored copy can shrink back | Owner approves publishing; PR opened with the equivalence tests ported to mfsk-core's own test suite | FO1, owner | proposed, needs owner's yes |

## Proposed by lessons

Proposed 2026-10-12 from results on the same board and tools
([TANG_LESSONS.md](TANG_LESSONS.md), section numbers "L 3" etc.; the work packages here are LS1 to LS9). Not yet accepted into the tracks above. The
FT8-first order still holds: LS1 to LS6 are on the FT8 path (they are P1's blockers 1 to 6 and the bring-up),
LS7 is the owner's request of 2026-10-12, LS8 and LS9 wait. Nothing of this has run on a board yet; every gain
below is a place-and-route or synthesis measurement from earlier builds, not from this design. Each package runs only the tests named.

| WP | What | Files | Expected gain | What to measure |
|---|---|---|---|---|
| LS1 | **New baseline with the better place-and-route settings.** One full build: `GOWIN_PLACE_OPT=3 GOWIN_ROUTE_OPT=1 GOWIN_REPORTS=1 OUT_DIR=<absolute> gowin/p1/build.sh`, in the background (50 minutes). No RTL change. If V1.9.11.03 refuses the two extra report commands, run again without `GOWIN_REPORTS` | none (the switches exist) | 125 -> 188 MHz on one DSP-heavy netlist from place option 1 -> 3 (L 7). Ours is unknown; it costs machine time only, and every later number is compared with it | `tools/gowin_verdict.py` totals (setup, hold); `tools/gowin_classes.py <html> clk_dsp 6.667` class table; the report's clock list (which clocks are on global lines); the 50 nets with the most loads |
| LS2 | **Mechanical fixes** in one piece of work: (a) PT8211 pins `hp_bck` E22, `hp_din` G24 in the pin file and BOARD.md (L 9: swapped today); (b) the 41 `(* syn_preserve = 1 *)` in `rtl/` to the comment form (L 8); (c) grep the LS1 netlist for `RAMREG` and list the modules that exist more than once; (d) three `set_false_path -to` lines for the HDMI serializers' `RESET` pins (P1 blocker 5) | `gowin/p1/sdr.cst`, `gowin/p1/sdr.sdc`, `docs/BOARD.md`, `rtl/**` (attribute form only) | the headphone DAC plays at all; kept registers really kept; the 22 failing end points of `clk_pix` gone | the testbench of each touched module, once; the `RAMREG` list; no place-and-route |
| LS3 | **Receiver bank timing** (P1 blocker 1: `clk_dsp` 69 MHz). Root causes are known. `fir_decim.v`: register the tap index, the coefficient ROM address and the ROM output; the multiply in an instantiated `MULTALU27X18` with input and output register and the accumulate inside the block (L 6). `cic_var_shared.v`: per-context reset and enables as kept copies per 8 to 13 loads, loaded a clock ahead; register arrays as packed vectors (L 3, L 8). `/* synthesis syn_maxfan = 10 */` on every module of `rtl/rx`. Stand-alone through `gowin/res.sh rx_bank --wrap` with place 3, route 1, 6.35 ns (5 % margin) | `rtl/rx/fir_decim.v`, `cic_var_shared.v`, `rx_bank.v`, `rx_channel.v`, `sim/rx/*` | `clk_dsp` from 69 MHz to the 150 MHz target for this block: the two worst paths (14.4 and 14.0 ns) are one un-pipelined multiply-accumulate and one reset net, the two kinds of path whose removal took another block from 208 to 240 MHz | class table before and after; failing end points at the tightened clock; `tb_rx_bank` and `tb_rb3_compare` bit-exact with the latency change listed; `tools/gowin_fanout.py` on the block: no net above about 13 loads |
| LS4 | **Block RAM down** (P1 blocker 2: 261 of 340, 86 to 93 % ahead; timing on this chip needs it under 75 %). Run `tools/gowin_mems.py <LS1 netlist> --mem --lutram`; then, largest first: memories of 32 words or fewer to LUT RAM (`syn_ramstyle`), ROMs of 64 words or fewer to LUTs (`syn_romstyle = "distributed_rom"`), tables read at two addresses as one dual-port block, 32/36-bit memories that use 18 bits or fewer narrowed (L 4). Attributes only where possible, so the simulated text does not change | `rtl/fft`, `rtl/spectrum`, `rtl/rx_backend`, `rtl/video/waterfall_writer.v` (64-bit FIFO: 4 blocks), `rtl/tx`, `rtl/audio` | 268 -> 174 blocks in one earlier build for about 1.2 % of the logic. Here the aim is 30 to 50 blocks (the first listing of F5 alone shows 6 blocks in two 32-word memories) | block count by `gowin_mems.py` before and after (synthesis only, `--syn`); the testbench of each touched block; the 75 % line (255 blocks) with F5 to F7 and the compositor counted in |
| LS5 | **Clocks and pins of the top level** (P1 blockers 3, 4, 6 and the swept HDMI audio). (a) HDMI audio: establish why the packets are swept; three suspects in L 2 (the tone generator on a made-up clock, `clk_audio` on ordinary wiring, an accumulator step that gives 96 kHz); feed the core from a real sample source (the audio engine's 48 kHz). (b) Every clock on a global line: `CLOCK_LOC "<net>" BUFG[8..15] = CLK;` for those the LS1 report shows on ordinary wiring; write the list of all clocks against the chip's 16 lines (the SFP lane adds two). (c) RGMII: TXC through an ODDR like the data; RX: IODELAY or the PHY's delay strap; one targeted `report_timing` per direction. There is **no earlier gigabit RGMII result** to build on, so (c) has to be worked out here. (d) AHB at 100 MHz misses by 7 end points; AHB and APB can run at 50 MHz, because Gowin's flash controller inside the block reached only 69 MHz in an earlier build: decide 100 or 50 (register access time doubles) | `rtl/top/sdr_top.v`, `rtl/video/sdr_hdmi_video.v`, `rtl/hl2link/rgmii_*_phy.v`, `gowin/p1/sdr.sdc`, `.cst`, `gowin/p1/ip/gowin_pll_ae350.mod` | HDMI audio present in the netlist (board check B2 needs it); no hold failure from clocks; the `clk_tx` and `clk_rx` pin paths met or explained | the audio packet modules in the synthesis hierarchy (`tools/gowin_hier.py`); the hold total in the verdict; the two RGMII path reports |
| LS6 | **Bring-up ladder and the loader's flash layout.** (a) Three small bitstreams before the whole design: PLLs + AE350 + UART + LEDs + clock counters; + DDR3 tests + HDMI bars; + the audio tone. The start-up program prints once per guess of the UART clock; LEDs active low; the CPU held until DDR3 is ready (L 9). (b) The loader: bitstream and program share one flash, the bitstream is at offset 0 and 5.04 MiB long; move every slot above 0x600000 and settle how 0x8000_0000 maps onto the chip; fix the two faults already noted in C2_LOADER.md. | new ladder top (or build switches of `rtl/top/sdr_top.v`), `gowin/p1/build.sh`, `fw/tr-loader`, `fw/tr-ae350`, `docs/C2_LOADER.md` | a failing first power-on names the part instead of showing a dark board; **a flash write can no longer erase the bitstream** | each ladder step: verdict 0 / 0 and its build time; the loader's host tests; `objdump` of where `_start_rust` lands |
| LS7 | **The whole 1 GB DDR3 (owner 2026-10-12).** AE350 data memory as "Customized Data Memory", Gowin's DDR3 IP with 32 data and 15 row lines in the logic, the DDR3 bridge `rtl/mem/ddr_mem.v` with its testbench, our two arbiters on its lanes, 20 more pins, one more generated clock, the CPU held until calibration, a size probe in the start-up test (L 1, file by file). Keep the 256 MB build as the fall-back that tells a board fault from a bridge fault. Establish first: the lanes signal by signal against our arbiters; the lanes' priority against the video read tier (ARCHITECTURE risk 4); whether the DDR bus clock should be 50 or up to 200 MHz for the FT8 decode | `gowin/p1/ip/riscv_ae350_soc.ipc`, `ipc_to_config.py`, `gowin/p1/build.sh`, new `rtl/mem/`, new `hw/gowin/mem/gwmc_param.v`, `rtl/top/sdr_top.v`, `sdr_core.v`, `gowin/p1/sdr.cst`, `.sdc`, `fw/tr-ae350/memory-ae350.x`, `sim/top/tb_sdr_core.v` | 1 GB instead of 256 MB for the CPU and both lanes; DDR3 peak 3.2 instead of 1.6 GB/s; cost about 1,900 logic cells (2.7 %) and **no block RAM** (measured as small build against small build). One chip only (512 MB) would save 16 blocks and 1,975 cells against 1 GB | the bridge's testbench; `tb_sdr_core` PASS through the bridge; synthesis sizes of the memory path; `ddr3_sys` at 100 MHz and the bus side met; on the board: the size probe prints 1,024 MB, and the CPU's memory speed (`tr-bench` FT8 kernel in DDR3) against the 256 MB build |
| LS8 | **More audio outputs** (owner 2026-10-12; after FT8 works). S/PDIF (one PMOD pin, a TOSLINK module) and I2S for a Pi-type DAC board (four PMOD pins) from `rtl/audio/audio_digital_out.v`, on a 49.152 MHz clock from a second PLL behind a 48 MHz output of the DSP PLL (its VCO raised from 750 to 1,200 MHz: / 8 = 150, / 25 = 48); its slip handling between our 48 kHz and the exact clock. USB audio (the board as a class-compliant recording device on the "Custom USB" socket) only on an owner decision: USB is deferred in DECISIONS.md, and the radio also wants the playback direction for TX audio, which does not exist yet | `rtl/audio/`, `rtl/top/`, new `gowin/p1/ip/gowin_pll_aud.mod`, `gowin_pll_dsp.mod`, `.cst`, `.sdc`, `hw/regmap/audio.toml` | two digital outputs better than the PT8211's 89 dB; RX audio into a PC or hi-fi without an analogue cable | `audio_digital_out`'s own testbench; frames out equal samples in, within 4; sizes; both new clocks on global lines |
| LS9 | **Gowin V1.9.12.04 with the owner's own licence** instead of V1.9.11.03 on Sipeed's shared server: 3 runs at once, place options documented, group constraints no longer hang. Before the move: write every memory that reads and writes one address in one clock as "write, else read" (the new version refuses them, PA2122); `build.sh` already leaves out the switch that version dropped | `docs/TOOLCHAIN.md`, `gowin/p1/build.sh`, `gowin/res.sh`, RTL found by the first synthesis | three place-and-route runs side by side | one synthesis-only run on the new version: errors and sizes against LS1 |

LS6 status 2026-10-12 (branch `ladder`, not merged): built, nothing run on a board. Loader: slots moved to chip 0x61_0000 and up, mapping and guard in `fw/tr-loader-layout` (14 host tests), both faults of C2_LOADER.md fixed; ladder: three bitstreams (verdict 0 / 0, 159 to 170 s each) and `fw/tr-ladder`; see [LADDER.md](LADDER.md).

Suggested order: LS1 now, LS2, then LS3 and LS4 side by side (different files), LS5, LS6 before the
board work B1 to B3, LS7, then LS8 and LS9. LS7 before the board is first used saves debugging the DDR3 path twice.

### Own suggestions (not from the owner's list; each needs a yes before it becomes a work package)

Things in fpga-sdr that look wrong after reading the lessons:

1. **The headphone DAC's bit clock and data pins are swapped** in `gowin/p1/sdr.cst` and docs/BOARD.md
   (Sipeed's example and the dock schematic: BCK E22, DIN G24). In LS2.
2. **The loader would erase the FPGA bitstream on its first flash write**: docs/C2_LOADER.md assumes a flash of
   the processor's own; the board has one flash for both, with the bitstream at offset 0. In LS6.
3. **The full-chip build used place option 1**; option 3 measured far better on this chip, and it is
   the tool's own default. In LS1. P1's 69 MHz may be partly this.
4. **The HDMI audio clock** is made by a register in `clk_dsp`, runs on ordinary wiring, and by arithmetic turns
   at 96 kHz, not 48 (not simulated). In LS5.
5. **`(* syn_preserve = 1 *)` is used 41 times**; the attribute form was seen ignored in a large design
   (not reproduced in a small case). In LS2.
6. **The processor is not held in reset until DDR3 is calibrated** (P1 section 2 leaves it to the boot code).
   Holding it makes a dead DDR3 show as an LED. In LS6 and LS7.
7. **`rx_backend`'s fourth timing pass used `replicate_resources 1`** and hand copies only; replication measured
   worse and the module attribute `syn_maxfan = 10` better. Try the attribute on `rtl/rx_backend`
   with place 3 and no replication before more hand work on `bk_post` (132 MHz today).

Further suggestions:

8. **Adopt the 5 % margin rule** (`TIMING_MARGIN_PCT=5`) for every build meant for the board, and judge builds by
   failing end points over all clock pairs, not by Fmax.
9. **Treat 75 % block RAM as a timing limit, not only a fit limit.** The owner decision P1 asks for (what leaves
   if F5 to F7, the compositor, zoom and SFP do not all fit under 255 blocks) should come before LS4 is called
   done; the zoom spectrum is the largest single candidate.
10. **A clock-line budget.** The chip has 16 global lines; the constraint file already declares 15 clocks, and
    the SFP lane, a USB clock and an audio clock would add four. Resets take the lines clocks do not claim.
11. **An exact 148.5 MHz pixel clock may be reachable** with fractional settings (25 MHz x 37.125 = 928.125 MHz,
    output 0 divided by 1.25 = 742.5 MHz, the pixel clock through a divide-by-5 clock divider). Not checked against the PLL guide; low value, since +0.17 % is inside CEA-861.
12. **Netlist simulation of the DSP mappings** (`IDE/simlib/gw5a/prim_sim.v`), once per block that infers a
    multiply-accumulate (`fir_decim`, `bk_chfilt`, `bk_decim`, `audio_interp_x8`, `tx_fir_interp4`): an inferred
    accumulator was found wrong in every sample.
