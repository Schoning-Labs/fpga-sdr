<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# fpga-sdr source inventory

This is the list of every file in the repository (1,108 files), grouped by folder, with line counts, what the files are,
who wrote them and under which license they are published. The counts come from `git ls-files` and `wc -l` on the
released tree, and the origins come from the SPDX and copyright lines in each file's first lines plus a search for
"taken from", "ported from", "adapted from", "copied from" and the names of the Hermes-Lite and HPSDR authors, so a file
that hides its origin somewhere deeper than its header would not show up here (none is known, but keep that limit in
mind). Binary files are given in bytes instead of lines.

The classes used in the tables:

- **OURS**: written by Franz Schöning for fpga-sdr, or copied from his own earlier designs (for example tangcore),
  which counts as the same author. These files are Apache-2.0.
- **DERIVED**: started from a third-party file or routine and changed so much that the upstream license still holds for
  the file. The table says from what.
- **THIRD-PARTY**: carried from another project, unchanged or with a few marked changes, under its own license.
- **GENERATED**: written by a script or a tool from other files in the repository (the generator is named). They carry
  the Apache-2.0 header of the generator that wrote them and can be rebuilt at any time.

Upstream licenses that appear: Hermes-Lite 2 / HPSDR gateware GPL-2.0-or-later (simulation files only), mfsk-core
GPL-3.0-or-later, WSJT-X GPL-3.0-or-later (three derived files), Codec 2 and FreeDV LGPL-2.1, hdl-util HDMI (Sameer
Puri) MIT OR Apache-2.0, Sipeed's Tang Mega 138K Pro examples Apache-2.0, Slint (fetched by Cargo, not in the
repository) GPL-3.0-only or a commercial license. `LICENSES.md` explains each one and lists the files that carry a GPL
or LGPL header.

Not in the repository, by design: bitstreams and firmware images (users build both), Gowin's encrypted IP, recordings
and captures (`tools/fetch_test_audio.sh` and `tools/fetch_freedv_test.sh` download them), simulation output and logs,
the timing and usage summaries of past builds, the filter measurements of DK1CG's Hermes-Lite 2 filter board and the
plots made from them, the schematic of the USB host Pmod (linked in the documents instead), a set of sketches of an FT8
decoder in logic that was never used, and the notes of the author's own working setup.

## 1. Top level

| File | Lines | What it is | Class |
|---|---:|---|---|
| `LICENSE` | 201 | Apache-2.0 text | license text |
| `NOTICE` | 87 | Third-party notices for the repository and the built images | OURS |
| `README.md` | 139 | Description, build steps, reading list, license summary | OURS |
| `run.bat` | 51 | Starts the radio on Windows (calls `tools/radio_start.py`) | OURS, needs a board loader tool that is not in the repository (section 10) |
| `rust-toolchain.toml` | 10 | Pins the Rust toolchain | OURS |
| `.gitignore`, `.gitattributes` | 30 / 13 | Ignore list; LF line ends for generated register files | OURS |

## 2. FPGA design (`rtl/`, 222 files, about 80,000 lines)

Everything here is OURS and Apache-2.0 except `rtl/vendor/hdmi`. Of the 222 files, 34 are hex files (ROM contents written
by the Python generators in `tools/`, GENERATED, 37,733 lines in all), 13 are the HDMI encoder and 175 are Verilog and
include files written for this radio. No file of `rtl/` carries a GPL or LGPL header.

| Folder | Files | Lines | What it is | Class |
|---|---:|---:|---|---|
| `rtl/audio` | 9 | 1,681 | Audio engine, interpolators, I2S/S/PDIF out (two files from an earlier design by the same author); 1 hex file | OURS |
| `rtl/blink` | 4 | 856 | First board test design | OURS |
| `rtl/ddr3` | 4 | 769 | Read and write arbiters and relays in front of Gowin's DDR3 controller | OURS |
| `rtl/example` | 1 | 31 | Toolchain smoke test (an adder) | OURS |
| `rtl/fft` | 19 | 17,224 | Radix-2^2 streaming FFT; 14 twiddle hex tables from `tools/fft_r22sdf.py` | OURS + GENERATED |
| `rtl/ft8` | 24 | 6,757 | FT8 front end in logic (spectrogram, Costas sync, candidates, baseband); 4 ROM hex files | OURS + GENERATED |
| `rtl/hl2link` | 22 | 3,555 | Ethernet/UDP link to the Hermes-Lite 2: GMII and RGMII registers, frames, sample unpacking, transmit queue | OURS |
| `rtl/hl2min` | 5 | 1,174 | Minimal HL2 test build without a CPU | OURS |
| `rtl/mem` | 1 | 773 | DDR3 memory front end for the AE350 (from an earlier design by the same author) | OURS |
| `rtl/n1` | 8 | 1,774 | 1000BASE-X PCS for the SFP copper module; 8b/10b table | OURS + GENERATED |
| `rtl/net` | 3 | 586 | RJ45 network unit (MAC from an earlier design by the same author) | OURS |
| `rtl/rx` | 13 | 3,197 | Receiver bank: NCO, CORDIC mixer, CIC and FIR decimators; 2 hex files | OURS, the four CIC files are clean-room rewrites |
| `rtl/rx_backend` | 16 | 6,190 | Demodulator back end in logic (AGC, log/exp tables); 3 hex files | OURS + GENERATED |
| `rtl/sfp` | 8 | 1,384 | SFP lanes on the Gowin SerDes | OURS |
| `rtl/spectrum` | 9 | 11,822 | Spectrum and waterfall pipeline; 4 hex files | OURS + GENERATED |
| `rtl/top` | 16 | 3,804 | Chip top, core, ladder test designs, register pages | OURS |
| `rtl/tx` | 4 | 864 | Transmit chain (FIR, CIC, CORDIC) | OURS, `CicInterpM5.v` is a clean-room rewrite |
| `rtl/usb` | 11 | 2,260 | USB full-speed audio device (from an earlier design by the same author); 1 hex file | OURS |
| `rtl/usbh` | 6 | 1,628 | USB host for the Pmod (keyboard, mouse, headset) | OURS |
| `rtl/video` | 11 | 2,792 | HDMI video, compositor, waterfall writer, OSER10 simulation model | OURS |
| `rtl/zoom` | 15 | 9,358 | Zoom receiver chain; 5 hex files | OURS + GENERATED |
| `rtl/vendor/hdmi` | 13 | 1,697 | hdl-util HDMI encoder, 3 files modified with notes | THIRD-PARTY, MIT OR Apache-2.0, taken as Apache-2.0, license files present |

The five CIC files of the chip (`rtl/rx/cic_integrator.v` 71 lines, `cic_comb.v` 73, `cic_fixed.v` 194, `cic_var.v` 219 and
`rtl/tx/CicInterpM5.v` 244) and their Rust model `fw/tr-rxmodel/src/cic.rs` (276) are clean-room rewrites: they were
written from specifications of the behavior and checked bit for bit against the earlier Hermes-Lite and HPSDR filters in
simulation (benches in `sim/cic_clean`), and they carry Apache-2.0 headers. `rtl/rx/cic_var_shared.v` (487 lines) is the
time-shared variable CIC engine of the receiver bank and is ours.

## 3. Gowin build (`gowin/`, `hw/`)

| File or folder | Files | Lines | What it is | Class |
|---|---:|---:|---|---|
| `gowin/p1/build.sh` | 1 | 468 | Full-chip build: IP regeneration, synthesis, place and route, timing estimate | OURS (the defaults for output folders and one timing tool are paths of the author's setup; environment variables override them) |
| `gowin/p1/sdr.cst`, `sdr.sdc` | 2 | 582 | Pins, clock lines, timing constraints | OURS, some lines follow Sipeed's `ae350_customized_demo` (Apache-2.0, in NOTICE) |
| `gowin/p1/ip/gowin_pll_*.mod` | 6 | 399 | GowinModGen scripts for the six PLLs | GENERATED (Gowin IDE settings, our values) |
| `gowin/p1/ip/riscv_ae350_soc*.ipc`, `serdes/serdes.ipc`, `serdes/serdes.toml` | 4 | 908 | IP configurations for the AE350 SoC and the SerDes | GENERATED (settings only, no Gowin code) |
| `gowin/p1/ip/serdes/param.v`, `define.vh` | 2 | 94 | Parameters for Gowin's Customized PHY, names as Sipeed's `sfp+/customized_phy` example (Apache-2.0) | OURS (in NOTICE) |
| `gowin/p1/ip/ipc_to_config.py`, `gowin/p1/sdc_margin.py` | 2 | 132 | Helpers of the build | OURS |
| `gowin/ladder/*`, `gowin/hl2min/*`, `gowin/cst/*` | 7 | 794 | Builds and constraints of the test designs | OURS (ladder constraints follow Sipeed examples, Apache-2.0) |
| `gowin/wrap/*` | 11 | 815 | Out-of-context wrappers and constraints for block timing builds | OURS |
| `gowin/gen_stub.py`, `gen_wrap.py`, `res.sh`, `report_paths.sdc`, `README.md` | 5 | 486 | Build helpers | OURS |
| `hw/gowin/mem/gwmc_param.v` | 1 | 56 | Settings for Gowin's DDR3 IP; values first made by Sipeed with Gowin's generator for this board, changed to 300 MHz | OURS (parameter values; Sipeed attribution in NOTICE) |
| `hw/regmap/*.toml`, `README.md` | 18 | 4,229 | Register map sources | OURS |
| `hw/regmap/generated/*.vh` | 17 | 2,738 | Register headers for the RTL | GENERATED by `cargo run -p xtask -- regmap` |

Nothing from Gowin's install is in the repository: the AE350 SoC, the DDR3 controller, the SerDes PHY and the
PLL modules are regenerated from the install by `build.sh` and are encrypted (`LICENSES.md` section 9).

## 4. Firmware (`fw/`, 299 files of our code, 62 in the two ports, 166 vendored)

| Crate | Files | Lines | What it is | Class |
|---|---:|---:|---|---|
| `fw/Cargo.toml`, `fw/.cargo/config.toml` | 2 | 148 | Workspace, release profile, mfsk-core patch | OURS |
| `fw/Cargo.lock` | 1 | 5,823 | Exact dependency versions | GENERATED by Cargo (it is the source offer for the firmware's dependencies) |
| `tr-ae350` | 13 | 1,174 | AE350 drivers: UART, caches (Andes CCTL from public Andes V5 CSR numbers), timer, memory probe | OURS |
| `tr-app` | 14 | 2,408 | Firmware top: memory layout, interrupts, tasks, heap, the `ft8fw` binary | OURS |
| `tr-bench` | 4 | 846 | DSP benchmarks under QEMU | OURS |
| `tr-dsp` | 33 | 5,966 | DSP kernels: filters, fast convolution, demodulators, AGC (`backend/tables.rs` generated) | OURS |
| `tr-fabric` | 23 | 6,699 | Drivers for the logic's register pages (SFP code from an earlier design by the same author) | OURS |
| `tr-filters` | 8 | 1,044 | N2ADR filter board model and band switching | OURS |
| `tr-freedvbench`, `tr-ft8bench` | 8 | 960 | FreeDV and FT8 runs under QEMU | OURS |
| `tr-gui` | 42 | 5,619 | Front panel in Slint (Rust and `.slint` files) | OURS (links Slint, see `LICENSES.md` section 1) |
| `tr-hl2` | 15 | 2,555 | HL2 protocol, discovery, DHCP server, PC bridge | OURS; `protocol.rs` and `pc/discover.rs` are ports of the author's own `rawcap` (Apache-2.0) from his Hermes-Lite2 fork |
| `tr-image`, `tr-loader`, `tr-loader-layout`, `tr-loader-send`, `tr-loader-testfw` | 23 | 2,730 | Firmware image format, stage-0 loader, PC sender (flash code from an earlier design by the same author) | OURS |
| `tr-input` | 4 | 1,497 + 110 bytes | Mouse and keyboard over UDP; `tests/golden.bin` | OURS |
| `tr-ladder` | 4 | 576 | Bring-up test program (from an earlier design by the same author) | OURS |
| `tr-modes` | 32 | 8,062 | Digital modes on top of mfsk-core: FT8/FT4/WSPR glue, FT8 front-end model, scheduler, tests against WSJT-X samples | OURS, except three files below |
| `tr-net` | 9 | 1,336 | DHCP and SNTP client on smoltcp | OURS |
| `tr-regs` | 5 | 9,790 | Register constants; `src/generated.rs` (9,516 lines) | OURS + GENERATED by xtask |
| `tr-rxmodel` | 11 | 2,176 | Bit-true model of the receiver bank, with the CIC model in `src/cic.rs` | OURS |
| `tr-sim`, `tr-tci`, `tr-vita49` | 6 | 101 | Placeholders for later work, members of the workspace | OURS |
| `tr-station` | 24 | 9,016 | Radio logic: FT8 QSO, FreeDV station, HL2 session; `tests/data/*.txt` | OURS |
| `tr-usb` | 4 | 593 | USB descriptors, source of the RTL descriptor ROM (from an earlier design by the same author) | OURS + GENERATED |
| `tr-usbh` | 7 | 2,537 | USB host stack (audio class, HID) | OURS |
| `xtask` | 7 | 1,477 | Register map generator and build tasks | OURS |
| `tr-codec2` | 19 | 3,388 + 155,544 bytes | Rust translation of Codec 2 700C; test vectors made by the C program | DERIVED, LGPL-2.1-only, `COPYING.LGPL-2.1` and `NOTICE` present |
| `tr-freedv` | 43 | 3,659 + 175,832 bytes | Rust translation of the FreeDV 700D/700E modem; traces and speech from the C receiver | DERIVED, LGPL-2.1-only, same files present |
| `fw/vendor/mfsk-core` | 165 | 78,187 | mfsk-core 0.11.0 (Naoki Sakurai JL1NIE), patched | THIRD-PARTY, GPL-3.0-or-later, `LICENSE` present |
| `fw/vendor/VENDOR_PATCH.md` | 1 | 298 | What was changed in mfsk-core and why | OURS (the GPL's notice of modification) |

The test files inside `tr-codec2` and `tr-freedv` written by Franz Schöning carry LGPL-2.1-only on purpose, so that the
two crates can go back to the Codec 2 project as a whole.

**Three files of `tr-modes` that carry a GPL header:** `src/frontend/candidates.rs` (83 lines), `src/frontend/decode.rs`
(682) and `src/txbb.rs` (172) follow routines of WSJT-X (`sync8`, `sync8d`, `gen_ft8wave` and `gfsk_pulse`) as
mfsk-core translates them, so they are DERIVED and keep GPL-3.0-or-later with a "modified 2026 by Franz Schöning" note.
The other files of `tr-modes`, including `src/frontend/sync.rs` and `subtract.rs`, are Apache-2.0. The authorship
confirmation that could move the three files to Apache-2.0 is the first of the open points in `LICENSES.md`.

## 5. Simulation (`sim/`, 143 files, about 41,000 lines)

All benches are OURS and Apache-2.0 except the rows below. `sim/ft8/vectors/` holds 4 hex files (11,506 lines) that
are generated by our own scripts; the 7 vector files made from WSJT-X recordings are not committed and
`tools/make_ft8_vectors.sh` makes them from the downloaded recordings.

| File | Lines | Origin | Class |
|---|---:|---|---|
| `sim/h1_link_rx/hl2/crc32.v`, `ip_send.v`, `mac_send.v`, `rgmii_send.v`, `udp_send.v` | 475 | HPSDR Metis code (VE3NEA, VK6APH) via Hermes-Lite 2, far end of the H1 bench | THIRD-PARTY, GPL-2.0-or-later; `LICENSE` (GPL-2.0) in the folder |
| `sim/h1_link_rx/hl2/rawstream.v` | 529 | The author's raw stream sender from his Hermes-Lite2 fork, released there as GPL-2.0-or-later; one module renamed | OURS, kept under GPL-2.0-or-later as in Hermes-Lite 2 |
| `sim/h2_link_tx/hl2/ip_recv.v`, `mac_recv.v`, `udp_recv.v` | 412 | HPSDR Metis code via Hermes-Lite 2, two files modified | THIRD-PARTY, GPL-2.0-or-later; `LICENSE` in the folder |
| `sim/h2_link_tx/hl2/txsink.v` | 457 | The author's file from the Hermes-Lite2 fork | OURS, as `rawstream.v` |
| `sim/rx/ref/cic_comb.v`, `cic_integrator.v`, `cic_fixed.v`, `cic_var.v` | 561 | Copies of the four clean-room CIC modules with `_ref` added to the module names, so the reference receiver of that folder can run next to the chip's own modules | OURS, Apache-2.0 |
| `sim/cic_clean/tb_cic_*.v` | 906 | Five benches that check the CIC modules bit for bit against the earlier filters | OURS |
| `sim/h1_link_rx/tb_h1_link_rx.v` | 674 | Parts copied from the author's `tb_rawstream.sv` in the HL2 fork; includes the HL2 sender from its `hl2` folder | OURS |
| `sim/h1_link_rx/dcfifo_sim_stub.v` | 127 | Behavioral stand-in for Intel's `dcfifo`, written from its documented behavior | OURS |
| `sim/net/otp_model.v` | 28 | Model of Gowin's OTP primitive; holds an invented ID, `0123456789abcdef` | OURS |
| `sim/ft8/vectors/ft8_w3840_full.hex`, `f7_synth_*.hex` | 11,506 | Window table and synthetic signals | GENERATED, OURS |
| `sim/rx_backend/bk_sine.hex` | 1,024 | Test sine | GENERATED, OURS |

## 6. Tools (`tools/`, 58 files, about 7,200 lines)

All OURS (`gowin_*.py` partly from an earlier design by the same author). Notes:

| File | Lines | Note |
|---|---:|---|
| `tools/fetch_test_audio.sh` | 62 | Downloads the WSJT-X sample recordings (GPL-3.0) from the mfsk-core repository into the ignored `captures/` |
| `tools/make_ft8_vectors.sh` | 56 | Makes the seven FT8 testbench vector files that hold values of those recordings, so that no GPL data is committed |
| `tools/fetch_freedv_test.sh` | 57 | Downloads Codec 2 speech files and FreeDV sample signals (LGPL-2.1) into `captures/freedv/` |
| `tools/fdvref/*` | 149 | Builds the Codec 2 C reference programs from upstream to remake the test vectors |
| `tools/radio_start.py` | 103 | Loads the board; depends on a board loader tool and a network loader image that are not in the repository (section 10) |
| `tools/qemu_*.sh`, `check*.sh` | 1,342 | QEMU runs and the check script |

## 7. Documents (`docs/`, 77 files)

| File or folder | Files | Size | What it is | Class |
|---|---:|---:|---|---|
| `ARCHITECTURE.md`, `BOARD.md`, `REGMAP.md`, `USER_MANUAL.md`, `TOOLCHAIN.md` | 5 | 1,956 lines | Design, board facts, register map, manual, tools | OURS |
| `DECISIONS.md` | 1 | 311 lines | Design decisions with dates | OURS |
| `TANG_LESSONS.md` | 1 | 288 lines | What the board taught | OURS |
| The other 55 `.md` files (`A1_AUDIO.md` to `ZOOM_IN_CHIP.md`) | 55 | about 15,900 lines | Work package designs and results, each with a note that its numbers may predate later changes | OURS |
| `learn/*.md` | 9 | about 3,800 lines | The reading material: primers, tour, outline, glossary, history, tools, licenses, this inventory | OURS |
| `img/fdv_*`, `ft8_*`, `listen_*`, `panel_*.png` | 6 | 1.59 MB | Screenshots of the radio's own screen | OURS |

## 8. Files ignored by git that the build or tests need

`captures/` (WSJT-X and FreeDV recordings, HL2 captures), `fw/target/`, `impl/` folders, all `*.fs` bitstreams and the
FT8 vector files made from recordings are ignored and never were in git, which is right. The tests that need
recordings skip when `captures/` is empty.

## 9. Totals of our code

Text lines, counted without hex data, the vendored and ported code, the HL2 simulation files and the generated files.

| Group | Lines |
|---|---:|
| RTL (`rtl/`, without hex and vendor) | about 40,700 |
| Gowin build, constraints, register map (`gowin/`, `hw/`, without generated headers) | about 9,000 |
| Firmware (`fw/`, without vendor, codec2, freedv and generated files) | about 57,400 |
| Simulation benches | about 26,100 |
| Tools | about 7,200 |
| Documents | about 22,200 |
| Total | about 162,600 |

## 10. What the start-up path needs from outside the repository

`run.bat` calls `tools/radio_start.py`, which imports a board loader tool (`board.py` with its `board.json`: lock file, cable
check, `programmer_cli` SRAM load, paced network load; the folder is set with `RADIO_BOARD_TOOL`) and sends a network loader
image (`RADIO_NETBOOT`), with the lock file named by `RADIO_BOARD_LOCK`. These parts are not in this repository, so a user who clones fpga-sdr
alone cannot use `run.bat` and loads the board by hand with the Gowin programmer and `tr-loader-send`, as the README
and `docs/learn/TOOLS.md` section 5 describe.
