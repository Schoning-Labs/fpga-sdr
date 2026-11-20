<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# Tools used to build, simulate and run the radio

Everything a newcomer needs to build the chip and the firmware, run the benches and start the radio on a board, with
what each tool does, how it is run and what it needs. The host is a Windows 11 PC; the scripts are bash and run in Git
Bash (several use `cygpath`), and every command below is run from the repository root unless it says otherwise.

Keep in mind that a few tools reach outside this repository. The board loader and its lock are not part of this
repository (`tools/radio_start.py` takes them from the environment variables `RADIO_BOARD_TOOL`, `RADIO_NETBOOT` and
`RADIO_BOARD_LOCK`), and the timing estimate comes from the author's shared Tang tools (`G:/proj/tangcommon`). That path
is written into the scripts, so on another machine it has to be changed or the tools copied. Each section says which tools need it.

## 1. Installing the toolchain

| Tool | Where from | Version | Used for |
|---|---|---|---|
| Gowin EDA (IDE), `gw_sh.exe`, `GowinModGen.exe` | gowinsemi.com, with a licence that covers the GW5AST-138 | V1.9.12.04 only, in `C:/Gowin/Gowin_V1.9.12.04_x64/IDE` | synthesis, place-and-route, timing, PLL and transceiver generation |
| Gowin programmer (`programmer_cli.exe`) | gowinsemi.com | as installed in `C:/tools/gowin-programmer` | loading a bitstream (used by the board tool, section 5) |
| OSS CAD Suite (iverilog, vvp, yosys) | github.com/YosysHQ/oss-cad-suite-build | as unpacked in `C:/tools/oss-cad-suite` | every Verilog bench, yosys resource counts |
| Rust via rustup | rustup.rs | pinned to 1.93.0 by `rust-toolchain.toml` | all firmware and host tests |
| QEMU (`qemu-system-riscv32`) | `scoop install qemu` | as installed | instruction counts and smoke tests of the firmware |
| xPack RISC-V GCC (`riscv-none-elf-objdump`, `objcopy`) | github.com/xpack-dev-tools | 15.2.0-1, in `C:/tools/xpack-riscv-none-elf-gcc-15.2.0-1` | only objdump and objcopy; the firmware itself is Rust |
| Python 3 | python.org | 3.10 or newer | generators, checks, the PC tools; numpy, scipy and matplotlib for the coefficient generators and the receiver bench, pyserial for the board loader |

Notes that cost time before they were written down:

- The Gowin Education edition cannot target the GW5AST-138 package and has no AE350 IP, and the older V1.9.11.03 had
  a router that failed on this design (docs/learn/HISTORY.md section 7). Use V1.9.12.04 and nothing else.
- `rust-toolchain.toml` installs the toolchain and the `riscv32imafc-unknown-none-elf` target the first time `cargo`
  runs inside the repository, without touching the machine's default toolchain. `rustup show` inside the repository
  should report 1.93.0 as active, "overridden by" that file.
- Verilator is in the OSS CAD Suite and `tools/check.sh` would run Verilator benches (`sim/**/tb_*.sv`), but none
  exist, and Verilator cannot compile on this PC without a C++ compiler on the path. Every bench in this repository
  runs under Icarus Verilog.

## 2. Building the chip: `gowin/p1/build.sh`

`gowin/p1/build.sh` builds `rtl/top/sdr_top.v` for the GW5AST-LV138FPG676AC1/I0 (device version B) with no GUI.
It regenerates Gowin's IP from the committed configuration every time (only configuration is in git: the AE350
settings `gowin/p1/ip/riscv_ae350_soc.ipc`, the DDR3 settings `hw/gowin/mem/gwmc_param.v`, the PLL scripts
`gowin/p1/ip/gowin_pll_*.mod` and the transceiver's `gowin/p1/ip/serdes/serdes.ipc` and `serdes.toml`), writes a Tcl
project and runs `gw_sh`.

```sh
gowin/p1/build.sh            # synthesis, timing estimate, place-and-route, bitstream (about an hour)
gowin/p1/build.sh --syn      # synthesis only
```

The output goes to `${OUT_DIR:-gowin/impl}/sdr_top/` (not in git): the bitstream `impl/pnr/sdr_top.fs`,
the reports `impl/pnr/sdr_top.rpt.txt` and `impl/pnr/sdr_top_tr_content.html`. After place-and-route the
script prints the verdict of `tools/gowin_verdict.py`, i.e. the failing end points over all clock pairs, setup and
hold. A build counts as clean only when that verdict says 0 for both.

Switches, all set as environment variables:

| Switch | Effect |
|---|---|
| `TR_NRX=1..8` | receivers built (default 4); `TR_NRX=8 TR_NO_ZOOM=1` is the eight-receiver chip without the zoom |
| `TR_DDR=1024` / `256` | 1 GB through Gowin's DDR3 IP and the bridge (default), or the AE350's own controller with 256 MB, which tells a board fault from a bridge fault |
| `TR_USBH_PMOD=1` | the USB host board on PMOD1 instead of PMOD0 |
| `SFP_POR_FABRIC=1` | the transceiver's global reset form (default 0, the IDE's default form, the only one whose lane PLL locked on the board) |
| `GOWIN_IDE`, `OUT_DIR` | the IDE folder; a build folder per run, so two runs can go side by side |
| `GOWIN_PLACE_OPT`, `GOWIN_ROUTE_OPT`, `GOWIN_REPLICATE`, `GOWIN_PNR_OPTS` | place-and-route options (defaults place 2, route 2); read Gowin's software user guide before changing them |
| `TIMING_MARGIN_PCT` | tightens `clk_dsp`, `clk_pix` and `clk_pix5` by that many percent in the build's copy of the constraints (default 0, the real clocks) |
| `GOWIN_REPORTS=1` | longer timing report, the nets with the most loads and the most congested grids |
| `GOWIN_SNAPSHOT=1` | copies `rtl/` and `hw/` into the build folder, so the sources may be edited during the run |
| `GOWIN_DRY=1` | writes the project and stops before Gowin starts |
| `TIMING_GATE=1`, `LEVELS_ONLY=1`, `LEVELS_FORCE=1`, `TIMING_MODEL` | the timing estimate, below |
| `KEEP_DIR`, `TAG` | where the deliverables go, below |

**Timing estimate between synthesis and place-and-route.** After synthesis the script runs
`G:/proj/tangcommon/tools/levels/timing_est.py` on the netlist (`.vg`) with the build's constraints and a fitted
delay model (`gowin/p1/timing_model.json` if present, otherwise tangcommon's), writes `timing.txt` in the build folder
and prints the end points it estimates over their requirement. On its own it only reports. `TIMING_GATE=1` stops the
build before place-and-route when an end point is estimated over, `LEVELS_FORCE=1` overrides that, and
`LEVELS_ONLY=1` stops after synthesis and the estimate. The estimate is good for ranking paths and is no prediction of
the clock a build will reach, and it needs the tangcommon folder.

**Deliverables folder.** After every run, also a failed one, the netlist, the constraint files, the timing and place
reports, the logs, the bitstream and a `build.txt` (commit, options, date) are copied to
`fpga-sdr-builds/<TAG>` (next to the repository folder) (`TAG` defaults to the build folder's parent name). That folder is never deleted in
cleanup. `KEEP_DIR` picks another folder and `KEEP_DIR=none` turns the copy off.

The bitstreams that have been run on the board are kept in `impl/keep/` (`radio_20261021` is the one in use,
`radio_20261105_timingclean` is the timing-clean build not yet run on the board).

Other build scripts, made from the same one and cut down:

| Script | Builds | Note |
|---|---|---|
| `gowin/hl2min/build.sh` | `rtl/hl2min/hl2min_top.v`: the SFP transceiver, the HL2 receive chain and loss counters, no processor, no DDR3 | switches `HL2MIN_LANE=1` (cage SFP1), `HL2MIN_N`, `HL2MIN_ADC=1`, `HL2MIN_SGMII=1`; the build that proved the HL2 link on the board (docs/HL2MIN.md) |
| `STEP=1..3 OUT_DIR=<abs> gowin/ladder/build.sh` | the three bring-up bitstreams: processor, DDR3 and UART; plus HDMI colour bars; plus a tone on the PT8211 | docs/LADDER.md; not needed for the radio's first start |
| `gowin/res.sh <top> --wrap ... <files>` | one RTL block alone, real place-and-route, registers on every port (`gowin/gen_wrap.py`) | logic, registers, DSP, block RAM and Fmax of one block |

### Reading a Gowin build

These scripts read Gowin's outputs. The first four come from an earlier design by the same author (copied, no dependency):

| Tool | Reads | Tells you |
|---|---|---|
| `tools/gowin_verdict.py <..._tr_content.html>` | timing report | failing end points over all clock pairs, setup and hold; the build's verdict |
| `tools/gowin_classes.py` | timing report | the failing paths of one clock grouped by start and end unit |
| `tools/gowin_watch.py <build dir>` | `gw_sh.pid`, the log, CPU time | ends a stalled run by its process ID, never by name, because other runs may own other `gw_sh` processes |
| `tools/gowin_hier.py`, `gowin_mems.py`, `gowin_fanout.py` | hierarchy report, netlist | resources per unit, memories per unit, fan-out and pin counts |
| `tools/gowin_regs.py` | netlist | the flip-flops of one unit by signal name; finds memories built from flip-flops (`RAMREG`) |
| `tools/gowin_ctrlsets.py`, `gowin_pack.py` | netlist | control sets, and flip-flops that cannot share a slice with their LUT |
| `tools/gowin_struct.py` | netlist | one column of structure figures, to compare two designs |
| `tools/gowin_place.py` | placement database `impl/pnr/<top>.db` | where the placer put the cells, also for a build that failed to route |
| `tools/yosys_res.sh` | RTL | a quick yosys resource count of one block (synthesis only, an estimate) |

## 3. Simulation benches in `sim/`

All benches run under Icarus Verilog (`iverilog -g2012`, then `vvp`). A file named `tb_*.v` is self-contained: it
includes what it needs with paths from the repository root, prints `PASS` on success, and can be run on its own:

```sh
iverilog -g2012 -o /tmp/tb.vvp sim/fft/tb_fft_r22sdf.v && vvp -n /tmp/tb.vvp
```

Some folders have a `run.sh` for benches that need defines or several runs (`sim/sfp/run.sh`, `sim/hl2sfp/run.sh`,
`sim/hl2min/run.sh`, `sim/blink/run.sh`, `sim/zoom/run_sim.sh`), and `run_long.sh` for the long link runs
(`sim/h1_link_rx`, `sim/h2_link_tx`). `sim/run_sim.sh` regenerates the receiver FIR and the test signals and runs the
receiver bank's accuracy and alias tests (needs numpy and scipy).

| Folder | What its benches check |
|---|---|
| `rx` | receiver bank: accuracy of 8 receivers, alias rejection, the NCO mixer against an ideal mix, word-for-word against an older reference |
| `rx_backend` | receiver back end (filters, demodulators, AGC) against the bit-exact Rust model, and its output ring |
| `fft` | the streaming FFT, real and complex input, against the Python model |
| `spectrum` | full-band pipeline and the two contexts (full band and zoom) |
| `zoom` | zoom filters, alias rejection over the spans, the shared FFT, the noise colour of the waterfall |
| `ft8` | FT8 front end: frame core, spectrogram, sync search, candidate engine, registers |
| `h1_link_rx`, `h2_link_tx`, `hl2sfp`, `hl2min`, `sfp` | the HL2 link both ways, with gaps, clock offsets and a 1000BASE-X module model; `hl2sfp -DSTALE` shows the stale-stream case |
| `ddr3`, `mem` | lane arbiters, video never starved, the waterfall writer, the DDR3 bridge |
| `video` | the compositor pixel for pixel against a model, HDMI timing |
| `audio`, `tx` | audio engine and outputs, the TX chain |
| `usb`, `usbh` | USB audio device, USB host |
| `net`, `h3_phy`, `regmap` | chip ID reader, MDIO, register map example |
| `top` | the whole core: the HL2 over lane 0 with a module model, the RJ45 unit looped back, the register pages |

**`tools/check.sh`** runs everything: it regenerates the register map (and fails if the committed generated files are
stale), runs every `tb_*.v`, compares the Rust receiver model against the RTL word for word, runs `cargo test` for the
host crates and builds the firmware for the target. It takes a long time. When you change one block, run that block's
benches instead.

Longer done-tests that `check.sh` leaves out, each a script in `tools/`:

| Script | Runs |
|---|---|
| `tools/spectrum_k156.sh` | the full-band spectrum with 156 averages per line (several minutes) |
| `tools/zoom_backend_full_sim.sh` | the zoom from the mixer to the waterfall bytes (about an hour) |
| `tools/run_r4_full.sh` | the receiver back end on its full scenarios |
| `tools/run_v1_video_full.sh` | one whole frame of every video mode, every pixel |
| `tools/check_ft8_wav.sh`, `check_ft8_sync.sh`, `check_ft8_cand.sh`, `check_ft8_pass2.sh` | the FT8 front end bit for bit against the reference model on real WSJT-X recordings (fetch them first, section 6) |
| `python tools/rb4_nco_sfdr.py` | the NCO mixer's spurious-free range over 1,000 random tuning words |

## 4. Firmware

The firmware is a Cargo workspace in `fw/`. The board image is the `ft8fw` binary of `tr-app`; the other crates are
plain `no_std` libraries with host tests, so most of the firmware can be tested on the PC.

```sh
cd fw
cargo test -p tr-station                 # host tests of one crate (run the crates you changed)
cargo build --release --target riscv32imafc-unknown-none-elf -p tr-app --bin ft8fw
cargo run -q -p xtask -- image --input target/riscv32imafc-unknown-none-elf/release/ft8fw --output target/ladder/ft8fw.img
cargo run -q -p xtask -- regmap          # hw/regmap/*.toml -> Verilog headers and fw/tr-regs
```

- The target flags are in `fw/.cargo/config.toml`: `+d` for the hardware double-precision FPU and `-a` to keep atomic
  instructions out (docs/learn/HISTORY.md section 10).
- **`tools/check_no_amo.sh [elf]`** must print 0 atomic instructions after every firmware build, because the
  precompiled `core` is not rebuilt with `-a`. It needs the xPack objdump.
- Build-time settings, as environment variables of the `cargo build`: `TR_CALL` and `TR_GRID` (without them the call
  is N0CALL and the transmit switch stays locked), `TR_START_FT8=1` (start on the FT8 screen instead of LISTEN),
  `TR_TX_ECHO=1` (transmit samples go to the HL2's echo mode), `TR_FT8_SOFT=1` (decode FT8 in software only).
- **`tools/ladder_fw.sh chip`** builds the stage-0 loader, `ft8fw` and its packed image `fw/target/ladder/ft8fw.img`,
  and the serial sender. `tools/ladder_fw.sh write-chip` only prints the programmer commands that would write the
  flash; the radio has always been run from SRAM.
- **QEMU scripts** (`tools/qemu_c1.sh`, `qemu_c2.sh`, `qemu_c4.sh`, `qemu_s2.sh`, `qemu_s15.sh`, `qemu_s17.sh`,
  `qemu_freedv.sh`, `qemu_fo1_kernels.sh`, `fw/tr-app/qemu_p2.sh`) run firmware under `qemu-system-riscv32 -M virt`.
  Most of them count retired instructions with `-icount shift=0`, which is how the CPU budget was measured; the rest
  are smoke tests of start-up, the loader and the FT8 image. Instruction counts are not cycles: the board's own
  cycle counts were never measured.
- After a new firmware build, copy `ft8fw.img` into the folder the loader uses (`impl/keep/radio_20261021/`), or point
  `RADIO_KEEP` at another folder (section 5).

## 5. Starting the radio on the board: `run.bat`

`run.bat` in the repository root loads the radio into the board's SRAM (nothing is written to the flash) and then
opens the PC's mouse and keyboard window. `run.bat noinput` loads only. Before it: the board powered, the debug USB-C
cable and the HDMI monitor connected, the RJ45 cable in the home network, and the HL2 switched on at the module in cage
SFP0. Run it again after every power-off.

It calls `tools/radio_start.py` (`py tools/radio_start.py [--input]`), which:

- finds the board's console port by the FT2232's IDs (channel B is the UART; channel A is JTAG and is never opened);
- takes the board lock file named by `RADIO_BOARD_LOCK` and refuses to start if another program holds it, because
  two programs loading the board at once can stick the debug cable;
- runs the board loader tool (`board.py load` in the folder named by `RADIO_BOARD_TOOL`) with a config written for the
  radio: the bitstream over the debug cable, the network loader image named by `RADIO_NETBOOT`, and then
  the 2 MB firmware over UDP on the RJ45 port; the console runs at 184,320 baud;
- takes the files from `impl/keep/radio_20261021/` (`sdr_top.fs`, `ft8fw.img`); `RADIO_KEEP` and
  `RADIO_BOARD_TOOL` override the folders.

**This needs a board loader tool, a network loader image and a lock file location, none of which is part of this repository.** It needs Python with pyserial. A load
takes about a minute. Never kill the programmer while it runs: a killed programmer is the usual cause of a stuck debug
cable.

## 6. PC tools and test data

| Tool | What it does | How to run | Needs |
|---|---|---|---|
| `tools/radio_input.py` | sends the PC's mouse and keyboard to the radio's screen by UDP (port 21600, docs/NETINPUT.md); the transmit keys are blocked in the firmware | `py tools/radio_input.py` (`--ip` when the board is not found by broadcast) | Python standard library (tkinter, socket, ctypes); the Windows firewall may have to allow Python |
| `tools/test_radio_input.py` | the packet builder against the golden datagrams the firmware's parser reads, and a loopback test | `py -m unittest tools/test_radio_input.py` | nothing else |
| `tools/fetch_test_audio.sh` | downloads the WSJT-X sample recordings for the FT8 tests into `captures/` (not in git) | `bash tools/fetch_test_audio.sh` | network |
| `tools/fetch_freedv_test.sh` | downloads the Codec 2 speech and modem test files into `captures/freedv/` | `bash tools/fetch_freedv_test.sh` | network |
| `fw/tr-sim` | runs the HL2 code, the receiver model, the DSP, the decoders and the GUI on the PC against the real HL2 or a capture | `cd fw && cargo run -p tr-sim` | a raw HL2 or a capture |

For the HL2 side itself (discovery, raw captures, the noise test), the PC tools are in the HL2 release branch
(`docs/rawfront/TOOLS.md` of the `hl2-rawfront-release` branch).

## 7. Table and coefficient generators

The ROM and coefficient files under `rtl/` are generated and committed. Change the generator, run it, and commit both:

| Generator | Writes |
|---|---|
| `tools/gen_nco_table.py` | the quarter-wave sine table of the NCO mixer |
| `tools/gen_fir_coeffs.py` | the receiver's compensating decimate-by-4 FIR |
| `tools/gen_rx_backend_tables.py` | the back end's tables, once for the RTL and once for the Rust model |
| `tools/fft_r22sdf.py gen-tw` | the FFT twiddle ROMs (the same file is the bit-true FFT model) |
| `tools/gen_spectrum_tables.py` | window, column and dB tables of the spectrum pipeline and the zoom context |
| `tools/gen_zoom_window.py`, `gen_zoom_fir_coeffs.py`, `gen_zoom_cic_comp_coeffs.py` | the zoom's window, half-band filter and droop filter |
| `tools/design_tx_fir.py` | the TX interpolation FIR |
| `tools/gen_audio_interp_coeffs.py` | the audio x8 interpolator for the PT8211 |
| `tools/gen_signals/*.py` | ADC test signals for the receiver benches |
| `tools/analyze_alias.py`, `analyze_zoom_alias.py` | worst-case alias rejection of the receiver and zoom chains, computed, not simulated |
