<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# Reading order and commenting plan for fpga-sdr

## Who this is for

The reader knows a little programming and wants to learn how a software defined radio is built in an FPGA. Nothing
about FPGAs, DDR3, SDR or Gowin is assumed. The book is the repository itself: the primers in this folder explain the
ideas, and then each chapter walks through real source files in the order given, so that each file builds on the ones
before it. If you already know FPGA design, chapters 1 and 3 can be skimmed, and if you already know DSP, chapter 2 can,
but keep in mind that every block in the receive chain depends on the `adc_valid` convention from chapter 5, so read
that one whatever you know.

This is not a course in Verilog syntax or in DSP theory; it shows how both are used in one working design and points
to the theory where it is needed. It is also not a guide to transmitting: the transmit chain is in the repository and
chapter 14 explains it, but it has never been tested end to end and the firmware keeps it locked.

Each chapter names what it teaches, the files to read in order, and the design documents in `docs/` that give the full
specification and the reasons. The reasons for decisions are in `docs/DECISIONS.md` (design decisions, by date) and,
for the longer story of what was tried and changed, in `docs/learn/HISTORY.md`, which the chapters point to by
section. Comments in the code are kept free of history on purpose.

## Chapters

### 1. What an FPGA is, and this board

LUTs, flip-flops, block RAM, DSP blocks, PLLs and clock lines; what timing closure means and why a long path or a
high fan-out net fails at speed; the GW5AST-138 chip and the Tang Mega 138K Pro board with its DDR3, SFP cages, HDMI
pins, RJ45 socket and headphone DAC; how synthesis, place and route, constraints and loading work.

- Read: [FPGA_PRIMER.md](FPGA_PRIMER.md), `docs/BOARD.md`.
- Files: `gowin/p1/sdr.cst` (for orientation: pins, I/O standards, clock lines), `gowin/p1/ip/gowin_pll_*.mod`
  (the six PLLs), `rtl/example/adder.v` with `sim/example/` (the smallest module and testbench in the tree, a first
  look at Verilog and a simulation run).

### 2. What a software defined radio is

Sampling, the Nyquist limit, I/Q, the NCO and the mixer, decimation, CIC and FIR filters, fixed point, the FFT, windows,
the waterfall, demodulation of SSB, CW, AM, SAM and FM, AGC, S-meter, squelch and FT8, all with this radio's numbers.

- Read: [SDR_PRIMER.md](SDR_PRIMER.md), then [ARCHITECTURE_TOUR.md](ARCHITECTURE_TOUR.md) for the map of the whole
  system that the following chapters fill in.
- Files: none yet; the glossary [GLOSSARY.md](GLOSSARY.md) stays open beside every later chapter.

### 3. The top level, the clocks and the register bus

How the chip is split into a part only Gowin can build and a part that simulates whole, which clock each block runs
on, how the processor reaches every block's registers through one AHB port and a toggle handshake per clock domain,
and how one TOML file per page generates both the Verilog constants and the Rust register crate.

- Files, in order: `rtl/top/sdr_top.v` (header and port list), `rtl/top/sdr_core.v` (header, then the
  instance list), `rtl/top/ahb_reg_bridge.v`, `rtl/top/regbus_cdc_dst.v`, `rtl/top/regbus_leg.v`,
  `rtl/top/sys_regs.v`, `rtl/top/block_regs.v`, `rtl/top/rd_word_adapter.v`, `hw/regmap/README.md`,
  `hw/regmap/system.toml` and its generated include in `hw/regmap/generated/`, `gowin/p1/sdr.sdc`.
- Docs: `docs/P1_TOP.md`, `docs/REGMAP.md`, `docs/ARCHITECTURE.md` sections 2 and 4.

### 4. The SFP lane: 1000BASE-X from the transceiver to bytes

What a transceiver lane does, 8b/10b coding and the comma, symbol alignment, the PCS with its auto-negotiation, and
why every register after the PCS moves only when a byte enable is high.

- Files, in order: `rtl/sfp/sfp_serdes.v`, `rtl/n1/enc_8b10b.v`, `rtl/n1/dec_8b10b.v`, `rtl/n1/tab_8b10b.vh` with
  `rtl/n1/gen_8b10b_table.py`, `rtl/n1/n1_codes.vh`, `rtl/sfp/sfp_rx_sym.v`, `rtl/sfp/sfp_pcs.v`, `rtl/sfp/sfp_phy.v`,
  `rtl/sfp/sfp_xstat.v`, `rtl/sfp/sfp_top.v`.
- Not in the radio build but in the tree: `rtl/sfp/sfp_net.v`, `rtl/n1/gmii_mac_rx.v`, `gmii_mac_tx.v`,
  `fcs_append.v` (a network MAC for an SFP lane, built only with `NET_MAC = 1`), `rtl/sfp/sfp_enc20.v` (the board
  link's two-symbol coder, chapter 15).
- Docs: `docs/SFP_LINKS.md`, `docs/HL2_SFP.md` sections 2 to 5, `docs/N1_SFP.md`.

### 5. The HL2 link: from Ethernet frames to `adc_valid`

The HL2's raw wire format, how a frame is classified by byte 42 without buffering, the CRC check, the sample ring, the
Gray-coded FIFO into the DSP clock, the gap filler that keeps sample time exact, the loss counters, and the CPU's own
packet path. Then the transmit side of the link: the CPU queue, the TX sample framer, the CRC, and the rate lock that
keeps the HL2's transmit FIFO near 12,000 samples. This chapter defines `adc_valid`, which every later block uses.

- Files, in order (receive): `rtl/hl2link/gmii_rx_in.v`, `rtl/hl2link/crc32_eth.v`, `rtl/hl2link/eth_frame_rx.v`,
  `rtl/hl2link/raw_frame_buffer.v`, `rtl/hl2link/cdc_word.v`, `rtl/hl2link/cdc_sample_fifo.v`,
  `rtl/hl2link/gap_filler.v`, `rtl/hl2link/cpu_rx_ring.v`, `rtl/hl2link/hl2_link_rx_top.v`, `rtl/top/hl2_link_regs.v`,
  `rtl/top/hl2_pkt_port.v`.
- Files, in order (transmit): `rtl/hl2link/cpu_tx_queue.v`, `rtl/hl2link/crc32_append.v`, `rtl/hl2link/gmii_tx_out.v`,
  `rtl/hl2link/tx_sample_framer.v`, `rtl/hl2link/tx_rate_lock.v`, `rtl/hl2link/rx_tx_fill_bridge.v`,
  `rtl/hl2link/hl2_link_tx_top.v`, `rtl/hl2link/eth_clk_pll.v`.
- The same receive path in a small design: `rtl/hl2min/` (the minimal HL2 test build) is a good second read.
- Not in the build (the earlier gigabit RJ45 link, kept for reference): `gowin_iddr5.v`, `gowin_oddr5.v`, `mdio_ctrl.v`, `phy_reset_seq.v`, `phy_setup_top.v`.
- Docs: `docs/H1_LINK_RX.md`, `docs/H2_LINK_TX.md`, `docs/HL2_SFP.md`, `docs/HL2MIN.md`; the wire format in the HL2
  release's `docs/rawfront/PROTOCOL.md`.

### 6. The receiver bank

The NCO with its quarter-wave table and Taylor correction, the mixer in the DSP blocks, the fixed CIC, the variable CIC
engine shared by four receivers, the compensating FIR with its delay line in block RAM and one multiplier for 65 taps,
and the shared output stream. Also the timing patterns that show up everywhere: kept copies of high fan-out registers
and pipelines of one short step per clock.

- Files, in order: `rtl/rx/nco_mixer.v` with `rtl/rx/nco_sin_dp.vh` and `tools/gen_nco_table.py`, `rtl/rx/cic_integrator.v`,
  `rtl/rx/cic_comb.v`, `rtl/rx/cic_fixed.v` (the three CIC files, clean-room rewrites from the specification), `rtl/rx/rx_channel.v`,
  `rtl/rx/cic_var.v`, `rtl/rx/cic_var_shared.v`, `rtl/rx/fir_delay_ram2.v`, `rtl/rx/fir_decim.v` with
  `tools/gen_fir_coeffs.py`, `rtl/rx/rx_bank.v`.
- Model and tests: `fw/tr-rxmodel` (bit-exact Rust model), `sim/rx/`, `sim/cic_clean/` (self-checking benches of the CIC files).
- Docs: `docs/RX_DSP.md`, `docs/R2_RXMODEL.md`.

### 7. The receiver back end

How one time-shared engine serves all receivers: the noise blanker, the half-band cascade to 24 ksps, the 1,024-tap
complex channel filter with its coefficient banks, the CORDIC demodulator for every mode, the log-domain AGC, the
S-meter and squelch, and the audio rings in DDR3. Also how a register path is given two clocks with `set_max_delay`.

- Files, in order: `rtl/rx_backend/bk_consts.vh`, `rtl/rx_backend/bk_fifo.v`, `rtl/rx_backend/bk_ram.v`,
  `rtl/rx_backend/bk_rom.v`, `rtl/rx_backend/bk_mul.v`, `rtl/rx_backend/bk_front.v`, `rtl/rx_backend/bk_decim.v`,
  `rtl/rx_backend/bk_chfilt.v`, `rtl/rx_backend/bk_cordic.v`, `rtl/rx_backend/bk_post.v`, `rtl/rx_backend/bk_ring.v`,
  `rtl/rx_backend/rx_backend.v`, `rtl/rx_backend/rx_backend.sdc`, with the tables from `tools/gen_rx_backend_tables.py`.
- Model and tests: `fw/tr-dsp` (module `backend`), `sim/rx_backend/`.
- Docs: `docs/R4_BACKEND.md`, `docs/ARCHITECTURE.md` section 3.10.

### 8. The FFT and the full-band spectrum

The streaming radix-2^2 FFT stage by stage (delay, butterfly, twiddle multiply), bit-reversed output, then the spectrum
pipeline: the Blackman-Harris window, power, the per-column reduction, K-frame averaging in the log domain, dB in 1/64
steps, the line buffers and the waterfall byte stream.

- Files, in order: `rtl/fft/fft_delay.v`, `rtl/fft/fft_bf.v`, `rtl/fft/fft_mul.v`, `rtl/fft/fft_twmul.v`, `rtl/fft/tw/`,
  `rtl/fft/fft_r22sdf.v` with `tools/fft_r22sdf.py`, `rtl/spectrum/spectrum_window.v`, `rtl/spectrum/log2_core.v`,
  `rtl/spectrum/spectrum_ratio_db.v`, `rtl/spectrum/spectrum_walk_core.v`, `rtl/spectrum/spectrum_pipeline.v`, with
  `tools/gen_spectrum_tables.py`.
- Tests: `sim/fft/`, `sim/spectrum/`.
- Docs: `docs/F1_FFT.md`, `docs/F2_SPECTRUM.md`.

### 9. The zoom receiver

A second DDC with its own decimation plan (CICs in powers of two, a narrow CIC for the smallest spans, a 63-tap
half-band, a CIC compensator), its window, and the frame buffer that lets it borrow the last twelve stages of the
full-band FFT instead of having its own.

- Files, in order: `rtl/zoom/cic_var_pow2.v`, `rtl/zoom/zoom_cic_narrow.v`, `rtl/zoom/zoom_fir_half.v`,
  `rtl/zoom/zoom_cic_comp.v`, `rtl/zoom/zoom_ddc.v`, `rtl/zoom/zoom_window.v`, `rtl/zoom/zoom_lutram.v`,
  `rtl/zoom/zoom_frame.v`, `rtl/zoom/zoom_frontend.v`; then `rtl/zoom/zoom_spectrum.v` (the older form with its own FFT,
  used by the simulations) and the zoom context in `rtl/spectrum/spectrum_pipeline.v`.
- Tests: `sim/zoom/`.
- Docs: `docs/F3_ZOOM.md`, `docs/ZOOM_IN_CHIP.md`, `docs/ZOOM_FIT.md`.

### 10. DDR3: one memory for the processor and the logic

How DDR3 works in outline (banks, rows, bursts of 32 bytes, refresh, the 1:4 controller clock), Gowin's DDR3 controller
IP, the bridge that gives the processor's data bus and two 64-bit lanes access to it, the priority arbiters, the
register relays that shorten lane paths, and why the firmware must manage its data cache around every shared ring.

- Files, in order: `rtl/ddr3/ddr3_write_arbiter.v`, `rtl/ddr3/ddr3_read_arbiter.v`, `rtl/ddr3/ddr3_wr_relay.v`,
  `rtl/ddr3/ddr3_rd_relay.v`, `rtl/mem/ddr_mem.v`, `hw/gowin/mem/gwmc_param.v`.
- Tests: `sim/ddr3/`, `sim/mem/`.
- Docs: `docs/F4_DDR.md`, `docs/MEM_1GB.md`, `docs/ARCHITECTURE.md` sections 3.9 and 4.2.

### 11. Waterfall, compositor and HDMI

The waterfall writer and its DDR3 ring, the compositor's fetch side and pixel pipeline, the key color, windows,
palettes and overlays, the frame-synchronous register copy, and the HDMI core: CEA-861 timing, TMDS, data islands with
audio, the OSER10 serializers and the emulated LVDS pins.

- Files, in order: `rtl/video/waterfall_writer.v`, `rtl/video/compositor_cfg.vh`, `rtl/video/compositor_util.v`,
  `rtl/video/compositor_fetch.v`, `rtl/video/compositor_pix.v`, `rtl/video/compositor.v`, `rtl/video/colorbar_gen.v`,
  `rtl/video/sdr_hdmi_video.v`, `rtl/video/prim_gowin/` and `rtl/video/prim_sim/`; the vendored
  `rtl/vendor/hdmi/` (read only, MIT or Apache-2.0).
- Tests: `sim/video/`.
- Docs: `docs/V1_VIDEO.md`, `docs/V2_COMPOSITOR.md`, `docs/DECISIONS.md` entry of 2026-10-22 (1080p30).

### 12. Audio out

The audio ring reader, the 48 kHz tick, the x8 polyphase interpolator, the PT8211 serializer, and the S/PDIF and I2S
outputs on their own 49.152 MHz clock.

- Files, in order: `rtl/audio/audio_ring_reader.v`, `rtl/audio/audio_nco_tick.v`, `rtl/audio/audio_interp_x8.v` with
  `rtl/audio/audio_interp_coeffs.hex` and `tools/gen_audio_interp_coeffs.py`, `rtl/audio/audio_pt8211_tx.v`,
  `rtl/audio/audio_engine.v`, `rtl/audio/audio_out_src.v`, `rtl/audio/audio_spdif_tx.v`, `rtl/audio/audio_digital_out.v`.
- Tests: `sim/audio/`.
- Docs: `docs/A1_AUDIO.md`, `docs/AUDIO_OUT.md`.

### 13. The FT8 front end

FT8's structure and how its decode is split between the chip and the processor: slot capture, the 3,840-point
spectrogram built from fifteen 256-point FFTs and a multiply-accumulate combine, the Costas sync search with its
divider, and the candidate engine's NCO, CIC, FIR and per-symbol DFT. Every engine is specified by a bit-exact Rust
model.

- Files, in order: `rtl/ft8/ft8_frontend.v` (header first, as the map), `rtl/ft8/ft8_ddr3_mux.v`,
  `rtl/ft8/ft8_ddr3_rdmux.v`, `rtl/ft8/ft8_ddr3_writer.v`, `rtl/ft8/ft8_slot_capture.v`, `rtl/ft8/ft8_slot_reader.v`,
  `rtl/ft8/ft8_dly.v`, `rtl/ft8/ft8_frame_core.v`, `rtl/ft8/ft8_tw3840.v`, `rtl/ft8/ft8_mac.v`,
  `rtl/ft8/ft8_combine.v`, `rtl/ft8/ft8_power.v`, `rtl/ft8/ft8_ring_writer.v`, `rtl/ft8/ft8_spectrogram.v` with
  `rtl/ft8/ft8_spectrogram.sdc`, `rtl/ft8/ft8_sync_div.v`, `rtl/ft8/ft8_sync.v`, `rtl/ft8/ft8_nco.v`,
  `rtl/ft8/ft8_cand_lane.v`, `rtl/ft8/ft8_cand.v`, the tables in `rtl/ft8/rom/`.
- Model and tests: `fw/tr-modes/src/frontend/`, `sim/ft8/` (the vector files taken from WSJT-X recordings are made by `tools/make_ft8_vectors.sh` and are not committed).
- Docs: `docs/ARCHITECTURE.md` section 3.12, `docs/S15_FT8MODEL.md`, `docs/F5_FT8SPEC.md`, `docs/F6_SYNC.md`,
  `docs/F7_CAND.md`, `docs/FT8_PASS2.md`.

### 14. The transmit chain (built, never tested end to end, locked)

Interpolation from 48 kHz baseband up to 76.8 Msps (FIR x4, CIC x400), the NCO up-mix, the 12-bit output, and the
safety layers: zeros unless enabled, zeros at once on a trip in the HL2's safety byte, and the HL2's own interlocks.

- Files, in order: `rtl/tx/fir_coeffs.vh` with `tools/design_tx_fir.py`, `rtl/tx/tx_fir_interp4.v`,
  `rtl/tx/CicInterpM5.v` (a clean-room rewrite of the CIC interpolator), `rtl/tx/tx_chain.v`; back to `rtl/hl2link/tx_sample_framer.v` and
  `tx_rate_lock.v` from chapter 5.
- Tests: `sim/tx/`, `sim/cic_clean/` (the interpolator's bench), `sim/h2_link_tx/`.
- Docs: `docs/X1_TX.md`, `docs/ARCHITECTURE.md` section 3.6.

### 15. Network, USB and the board link

The RJ45 network unit and the chip ID that names the board, the USB full-speed device that makes
the board a sound card (NRZI, bit stuffing, isochronous endpoints, a feedback endpoint), the USB host on a PMOD board,
and the board-to-board link on SFP1.

- Files, in order: `rtl/net/eth_top.v`, `rtl/net/net_unit.v`, `rtl/net/chip_dna.v`; `rtl/usb/usb_fs_phy.v`,
  `rtl/usb/usb_fs_core.v`, `rtl/usb/usb_ep0.v`, `rtl/usb/usb_desc_params.vh`, `rtl/usb/usb_afifo.v`,
  `rtl/usb/usb_ep_cap.v`, `rtl/usb/usb_ep_play.v`, `rtl/usb/usb_play.v`, `rtl/usb/usb_regs.v`, `rtl/usb/usb_audio.v`;
  `rtl/usbh/usbh_phy.v`, `rtl/usbh/usbh_port.v`, `rtl/usbh/usbh_iso_in.v`, `rtl/usbh/usbh_iso_out.v`,
  `rtl/usbh/usbh_regs.v`, `rtl/usbh/usbh_top.v`; `rtl/blink/blink_tx.v`, `rtl/blink/blink_rx.v`,
  `rtl/blink/blink_rx_buf.v`, `rtl/blink/blink_top.v`.
- Tests: `sim/net/`, `sim/usb/`, `sim/usbh/`, `sim/blink/`.
- Docs: `docs/NET_ID.md`, `docs/USB_AUDIO.md`, `docs/USB_HOST.md`, `docs/SFP_LINKS.md` section 5.

### 16. The firmware

Bare-metal Rust on the AE350: start-up and traps, the generated register crate, the drivers for each FPGA block, the
HL2 session, the radio and its screens, the main loop, and how the firmware shares DDR3 rings with the logic.

- Files, in order: `fw/Cargo.toml`, `fw/tr-ae350`, `fw/tr-regs`, `fw/tr-fabric` (one module per block, in the order
  of chapters 5 to 12), `fw/tr-hl2`, `fw/tr-station` (`hl2session`, `radio`, `listen`, `wflevel`, `keys`), `fw/tr-dsp`
  (`backend::design` for the filters), `fw/tr-gui` (the `.slint` screens and the renderer), `fw/tr-modes`, `fw/tr-net`,
  `fw/tr-input`, `fw/tr-app/src/bin/ft8fw.rs`.
- Docs: `docs/ARCHITECTURE.md` section 5, `docs/C1_AE350.md`, `docs/P2_FT8_FW.md`, `docs/LISTEN.md`, `docs/NETINPUT.md`,
  `docs/CPU_BUDGET.md`.

### 17. Loading, starting and testing without a board

How the radio is loaded and started, the serial console, the PC input program, and how the design was tested before
and beside the board: testbenches for every block, the whole-core smoke test, bit-exact models, the minimal HL2 build
and the step-by-step board test.

- Files, in order: `run.bat`, `tools/radio_start.py`, `tools/radio_input.py`, `fw/tr-image`, `fw/tr-loader`,
  `sim/run_sim.sh`, `sim/top/tb_sdr_core.v`, `rtl/top/ladder_top.v` and the other `rtl/top/ladder_*.v`,
  `rtl/hl2min/hl2min_top.v`.
- Docs: `docs/USER_MANUAL.md`, `docs/C2_LOADER.md`, `docs/LADDER.md`, `docs/HL2MIN_BOARD_RESULT.md`, `docs/TOOLCHAIN.md`.

### 18. Closing timing on the full chip

How to read a Gowin timing report, what the build switches do, the timing estimate before place and route, kept copies
and pipelines, block RAM placement, clock lines, constraint gaps that look like logic failures, and the block-level
measurement wrappers.

- Files, in order: `gowin/p1/build.sh` (again, in full), `gowin/p1/sdr.sdc`, `gowin/p1/sdr.cst` (the
  clock lines), `gowin/p1/sdc_margin.py`, `gowin/README.md`, `gowin/res.sh` with `gowin/gen_wrap.py` and `gowin/wrap/`,
  `gowin/reports/README.md`, `tools/gowin_verdict.py` and the other `tools/gowin_*.py` readers, `tools/yosys_res.sh`.
- Docs: `docs/CLOCK_STUDY.md`, `docs/ROUTE_CAUSE.md`, `docs/FIT.md`, `docs/TANG_LESSONS.md`, `docs/ARCHITECTURE.md`
  section 3.14, `docs/DECISIONS.md` entry of 2026-11-05.

## Commenting work groups

Each group is about 3,000 to 6,000 lines of our own RTL plus the benches that belong to it (line counts from `wc -l`
of `.v`, `.vh` and `.sv` files; benches and scripts get the lighter treatment the release rules give `sim/`). The groups
follow the chapters, so one person reads related files together and the comments use the same words as the chapter.

| # | Group | Chapter | Files | RTL lines | Bench lines |
|---|---|---|---|---:|---:|
| 1 | Top level, register bus, constraints | 3, 18 | `rtl/top/` (without `ladder_*`), `gowin/p1/`, `hw/regmap/*.toml`, `sim/top/`, `sim/regmap/` | about 3,100 + 1,000 build | about 960 |
| 2 | SFP lane | 4 | `rtl/sfp/`, `rtl/n1/`, `sim/sfp/` | about 2,660 | about 480 |
| 3 | HL2 link | 5 | `rtl/hl2link/`, `rtl/hl2min/`, `sim/h1_link_rx/`, `sim/h2_link_tx/`, `sim/hl2sfp/`, `sim/hl2min/`, `sim/h3_phy/` | about 4,310 | about 4,490 |
| 4 | Receiver bank and TX chain | 6, 14 | `rtl/rx/` (our files), `rtl/tx/` (our files), `sim/rx/`, `sim/tx/` | about 2,990 | about 2,980 |
| 5 | Receiver back end | 7 | `rtl/rx_backend/`, `sim/rx_backend/` | about 3,740 | about 1,070 |
| 6 | FFT, spectrum and zoom | 8, 9 | `rtl/fft/`, `rtl/spectrum/`, `rtl/zoom/`, `sim/fft/`, `sim/spectrum/`, `sim/zoom/` | about 4,530 | about 4,140 |
| 7 | FT8 front end | 13 | `rtl/ft8/`, `sim/ft8/` | about 5,190 | about 2,140 |
| 8 | DDR3, video and audio | 10, 11, 12 | `rtl/ddr3/`, `rtl/mem/`, `rtl/video/`, `rtl/audio/`, `sim/ddr3/`, `sim/mem/`, `sim/video/`, `sim/audio/` | about 4,930 | about 4,330 |
| 9 | Network, USB, board link, bring-up | 15, 17 | `rtl/net/`, `rtl/usb/`, `rtl/usbh/`, `rtl/blink/`, `rtl/top/ladder_*.v`, `sim/net/`, `sim/usb/`, `sim/usbh/`, `sim/blink/` | about 4,430 + ladder | about 2,080 |
| 10 | Light comments on upstream files | 6, 14 | the HL2 copies under `sim/h1_link_rx/hl2/` and `sim/h2_link_tx/hl2/`: keep their headers, comment only where our use differs | not counted | |

Order: group 1 first, because every other group refers to the clocks, the register bus and the constraint files it
explains; then group 3, because `adc_valid` and the HL2 time base are used by groups 4 to 8; then 2 and 4 to 9 in any
order, since they do not share files. Group 10 can run beside any of them. Never comment or re-header `rtl/vendor/`,
`fw/vendor/`, `fw/tr-codec2`, `fw/tr-freedv` or generated files (`hw/regmap/generated/`, `rtl/rx/nco_sin_dp.vh`,
the `.hex` tables).

## Points to settle before the book is final

- `docs/ARCHITECTURE.md` still describes the HL2 on the RJ45 socket, the 1080p60 target and the 400 MHz DDR3 clock in
  several places, and some RTL headers (for example the DDR3 lines in `rtl/top/sdr_top.v`) still give 400 MHz.
  The commenting work should correct the RTL headers; `docs/ARCHITECTURE.md` stays as a design
  record, so read its numbers together with `docs/DECISIONS.md`, which is newer.
- The loader depends on a board loader tool that is not part of this repository (`tools/radio_start.py`). A public reader needs a stand-alone
  way to load the bitstream and the firmware, or a clear note that the tool is required.
- The firmware has no commenting group here, because the release rules scope the comment work to `rtl/`, `gowin/` and
  `sim/`; chapter 16 reads it as it is.
