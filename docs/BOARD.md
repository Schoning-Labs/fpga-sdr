<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 Franz Schöning, https://www.schoning.com -->
# Sipeed Tang Mega 138K Pro dock: verified facts

This is a design note from the build-up of the radio, so the numbers and plans in it may predate later changes (the DDR3 speed and the video mode, for example, are not what they were when most of these notes were written), and [docs/learn/HISTORY.md](learn/HISTORY.md) gives the current picture.

Facts that the design depends on, each with its source. Checked 2026-09-25. Anything that could not be
checked is marked **NOT VERIFIED** and repeated in [Open questions](#open-questions). The board has not
arrived yet (expected 2026-09-29); nothing here was measured on hardware.

## Sources

| Key | Source |
|---|---|
| WIKI | Sipeed wiki, Tang Mega 138K Pro: https://wiki.sipeed.com/hardware/en/tang/tang-mega-138k/mega-138k-pro.html |
| SOM | Core module schematic rev 1.10, "TANG_MEGA-138K-Pro_4071": https://dl.sipeed.com/fileList/TANG/Mega_138K_Pro/02_Schematic/TANG_MEGA-138K-Pro_4071_Schematics.pdf |
| DOCK | Dock schematic rev 1.2 (2024-10-10), "TANG_MEGA-138K_Dock-4071f": https://dl.sipeed.com/fileList/TANG/Mega_138K_Pro/02_Schematic/TANG_MEGA-138K_Pro-Dock-4071f_Schematics.pdf |
| EX | Sipeed example repository (Apache-2.0): https://github.com/sipeed/TangMega-138KPro-example (file paths given per fact) |
| DS1104 | Gowin GW5AST data sheet DS1104-1.0E (2023-09-22): https://cdn.gowinsemi.com.cn/DS1104E.pdf |
| DS1239 | Gowin GW5AST data sheet DS1239-1.0.3E (2025-10-24), newer: https://cdn.gowinsemi.com.cn/DS1239E.pdf |
| MUG1031 | Gowin RiscV_AE350_SOC Hardware Design Manual MUG1031-1.3.1E (2026-01-23): https://cdn.gowinsemi.com.cn/MUG1031E.pdf |
| MUG1029 | Gowin RiscV_AE350_SOC Software Programming Manual MUG1029-1.3E: https://www.gowinsemi.com/upload/database_doc/2688/document/67dd35b63d214.pdf |
| MUG1030 | Gowin RiscV_AE350_SOC Quick Start Manual MUG1030-1.3E: https://www.gowinsemi.com/upload/database_doc/2724/document/67dd368533185.pdf |
| INSTALL | The local Gowin EDA install, `C:/Gowin/Gowin_V1.9.11.03_Education/Gowin_V1.9.11.03_Education_x64/IDE` |
| UG300 | Gowin "Arora V BSRAM & SSRAM User Guide" UG300-1.3.6E (2025-06-27), local copy in INSTALL at `IDE/doc/EN/UG300-1.3.6E_Arora V BSRAM & SSRAM User Guide.pdf` (this guide's own front matter lists DS1104, "GW5AST series of FPGA Products Data Sheet", as the datasheet it applies to) |
| RUST | Rust platform support list: https://doc.rust-lang.org/rustc/platform-support.html |
| PT8211 | PT8211 data sheet (PJRC copy): https://www.pjrc.com/store/pt8211.pdf |

Schematic PDFs: neither PDF contains a licence or reuse statement, only "Shenzhen Sipeed Technology Co,Ltd."
in the title block. They are therefore **not** copied into `docs/vendor/`; use the URLs above. (Sipeed's
example code is Apache-2.0; its README also shows a CC BY-SA 4.0 badge, but it is not stated that this covers
the schematics, which are hosted outside that repository.)

## FPGA part and board revision

- FPGA: GW5AST-LV138FPG676A, device GW5AST-138, **device version B**, package "FCPBG676A" (WIKI; EX
  `sfp+/customized_phy/1.25G/src/fpga_project.cst` header: "GW5AST-LV138FPG676AES, Device Version: B").
  The SOM schematic title text says "GW5AT-LV138FPG676A" (SOM); the wiki and every example use GW5AST.
- Board revisions: SOM 4071 and 4072 share one schematic; dock 4071f and 4071f2 share one schematic
  (readme field of https://dl.sipeed.com/fileList/TANG/Mega_138K_Pro/02_Schematic/).
- Clock: one **50 MHz oscillator** on the SOM into FPGA pin P16 (SOM; used as `sys_clk` in every EX .cst).

## Toolchain: Gowin EDA Education cannot build for this board

Checked on this PC, 2026-09-25:

- The Education install lists exactly one GW5AST-138 part: `GW5AST-LV138PG484AC1/I0` (package PBGA484A),
  device versions B and C (`INSTALL/share/device/device_info.csv`). The board's **FPG676A package is not
  in the list**.
- `gw_sh` confirms it. `set_device GW5AST-LV138FPG676AC1/I0` and `set_device GW5AST-LV138FPG676AES` both
  answer "can't find device"; `set_device GW5AST-LV138PG484AC1/I0` is accepted and synthesis starts
  (test in the scratch area, not the repo).
- The Education install has **no AE350 IP**: the release note (RN100-1.9.11.03 Education, in INSTALL) lists
  only Gowin_EMPU and Gowin_PicoRV32 as processor IP, and no `*ae350*` file exists under `C:/Gowin`.
- Sipeed: "currently not supported by the education version"; use V1.9.9 or newer of the commercial IDE.
  Sipeed runs two floating licence servers for it: 45.33.107.56:10559 and 106.55.34.119:10559 (WIKI).
- Therefore: install **Gowin EDA Standard** (commercial) V1.9.11.x and use either Sipeed's licence servers
  or a licence from Gowin. Whether Gowin issues that licence free of charge is **NOT VERIFIED**.
- The Andes/Gowin C toolchain (AndeSight "RDS") needs its own licence from Gowin (MUG1026 section 5, via
  sub-agent). We do not need it: the firmware is Rust.

## Gowin GW5AST-138 resources

| Resource | Value | Source |
|---|---|---|
| LUT4 / registers | 138,240 / 138,240 | DS1104 table 1-1 |
| Block SRAM | **340 blocks, each 18 kbit, 6,120 kbit total** (see correction below) | DS1104 table 1-1, UG300 |
| Distributed SRAM | 1,080 kbit | DS1104 table 1-1 |
| DSP | 298 blocks; 27x18, 12x12, 27x36 multipliers, 48-bit accumulator | DS1104 table 1-1 and 1.1 |
| PLLs | up to 12 (package-dependent) | DS1104 table 1-1 |
| Global / high-speed clocks | 16 / 24 | DS1104 table 1-1 |
| SerDes | 8 lanes, 270 Mbit/s to 12.5 Gbit/s. Listed protocols include SGMII (1.25 Gbit/s), 1000BASE-X and 10GBASE-R, with Gowin IP | DS1104 2.6, DS1239 |
| LVDS | DS1104: 1.25 Gbit/s. DS1239: 1.5 Gbit/s RX, 1.6 Gbit/s TX | DS1104, DS1239 table 1-1 |
| Serializer OSER10 (10:1 gearbox) | 1,600 Mbit/s maximum, "IO logic maximum, IP-dependent" | DS1239 table 3-16 |
| DDR3 | DS1239 resource table: 800 Mbit/s for GW5AST-138 (DS1104 said up to 1,333) | DS1239 table 1-1 |
| I/O in FPG676A | 312 user I/O, 150 true-LVDS pairs | DS1239 table 1-2 |
| PCIe | hard PCIe 2.0 x1-x8 | DS1104 2.7 |

**Correction, 2026-09-26 (found while building the chip-wide resource ledger, `docs/ARCHITECTURE.md`
section 3.14):** this row previously read "340 blocks, 6,120 kbit (each 36 kbit block = 2 x 18 kbit)",
which is self-contradictory (340 blocks of 36 kbit would be 12,240 kbit, not 6,120) and was read
downstream as "the chip has 340 blocks of 36 kbit each", halving every real BSRAM count entered against
it. The primitive is **18 kbit, not 36**: `340 x 18 kbit = 6,120 kbit` matches the table exactly, and
UG300 ("Arora V BSRAM & SSRAM User Guide", the primitives guide for the GW5A/GW5AST family DS1104
covers) states directly, of the base primitive: "The capacity of a BSRAM is 18 Kbits, can be configured
up to 36 Kbits" (UG300 section on the BSRAM overview). The 36-kbit figure is real but is a
**configuration**, not the primitive size: `SDP36KE` (UG300, its own dedicated section) cascades **two**
adjacent 18-kbit physical primitives into one semi-dual-port block addressed as 36 kbit wide/512 x 72 -
useful when a design wants a single wider or deeper memory, but it does not change the device's total
capacity or its 340-primitive count. Every BSRAM number elsewhere in this repository should be counted
in 18-kbit primitives against a denominator of 340, never 36-kbit "blocks" against 170.

Gowin IP in the local Education install (`INSTALL/ipcore`), among others: `FFT`, `CORDIC`,
`Complex_Multiplier`, `DDS_II`, `DDR3`, `DVI_TX`, `DVI_RX`, `SERDES_IP`, `TSE_MAC` (triple-speed Ethernet
MAC), `VFB` (video frame buffer), `USBSoftPHY`, `PLL_ADV`, `FlashController`. **No FIR or CIC IP, no AE350.**
The Standard edition's IP list was not checked (not installed).

## AE350 RISC-V subsystem (hard core)

All from MUG1031 section 2-4 unless marked.

| Item | Fact |
|---|---|
| Core | **Andes A25** (figure 2-1), 5-stage in-order pipeline, up to **800 MHz** |
| Width and ISA | **RV32** I, M, A, C, **F and D (single and double precision FPU)**, N (user interrupts), "DSP supported" (Andes P extension) |
| Privilege, MMU | M, S, U modes; Sv32 page-based virtual memory; 16 PMP entries |
| Caches | 32 KB I-cache and 32 KB D-cache, both 4-way, pseudo-LRU |
| Local memory | ILM 64 KB at 0xA000_0000, DLM 64 KB at 0xA020_0000; the fabric can reach both as a master through the 64-bit Extended AHB Master port |
| Benchmarks | 1.72 DMIPS/MHz, 3.22 CoreMark/MHz, 0.783 MWIPS/MHz (MUG1031 table 4-3). At 800 MHz: about 2,580 CoreMark |
| Instruction memory | 0x8000_0000-0x8FFF_FFFF (max 256 MB, AHB, below 200 MHz): SPI flash (memory-mapped), ITCM, or user memory |
| Data memory | 0x0000_0000-0x7FFF_FFFF (max 2 GB, AHB 64-bit, below 200 MHz): DDR3, DTCM, or user memory |
| Fabric ports | **Extended AHB Slave** 32-bit, 128 MB, AE350 is master (CPU reads/writes fabric registers). **Extended APB Slave** 32-bit, 64 MB. **Extended AHB Master** 64-bit, fabric is master into ILM/DLM |
| Address map | Extended AHB Slave 0xE800_0000-0xEFFF_FFFF; Extended APB Slave 0xF800_0000-0xFBFF_FFFF; PLIC 0xE400_0000; machine timer 0xE600_0000; PLIC software interrupts 0xE640_0000; debug module 0xE680_0000; UART1 0xF020_0000; UART2 0xF030_0000; SPI 0xF0F0_0000; DMA 0xF0C0_0000 (MUG1029 table 3-1) |
| DDR3 shared with fabric | Option "Shared DDR3: Logic R/W Mode": the MCU and the fabric access DDR3 at the same time. The fabric gets one **write lane** and one **read lane** (address, 32- or 64-bit data, burst count up to 8 bits, wait/valid handshakes). Off by default. Example `example\DDR3_Shared` |
| DDR3 clocks | DDR3 memory clock at most 400 MHz (DDR3-800); fabric R/W clock at least 1/4 of it; 50 MHz reference in (table 4-2) |
| Other clocks | core up to 800 MHz; DDR (data memory) clock, AHB and APB clock each below 200 MHz; core, DDR and AHB/APB clocks asynchronous; AHB:APB 1:1 (table 4-1) |
| Interrupts | PLIC with 15 priority levels, vectored mode, software interrupts (PLIC-SWINT); **16 user interrupt lines from the fabric** (sources GP0-GP15, MUG1029 table 4-2); machine timer; WDT on NMI |
| Peripherals | UART1, UART2, SPI (flash, XIP), I2C, GPIO, PIT, WDT, RTC, SMU, DMAC (8 channels, AXI4) |
| Cache control | Andes CCTL commands, including L1D write-back and invalidate by address (MUG1029 table 6-4) |
| Reset and boot | Reset vector register default **0x8000_0000** (SPI flash) (MUG1029 table 16-12). Boot modes: load by GDB into ILM or DDR; burn to flash and run from DDR, DLM, ILM, or in place from flash (MUG1029 table 5-1) |
| Debug | RISC-V debug module, 8 breakpoints, external 4-wire JTAG on FPGA user pins (`TCK_IN`, `TMS_IN`, `TDI_IN`, `TDO_OUT`, `TRST_IN`). Reference designs list the Andes AICE-MINI+, the Gowin FTDI programmer and an Olimex adapter (MUG1031 tables 8-1 to 8-3). Whether stock OpenOCD + GDB work is **NOT VERIFIED** |
| On this board | Sipeed example: core 800 MHz, AHB/APB 100 MHz (**fpga-sdr runs them at 80 MHz** since 2026-10-13, docs/DECISIONS.md), DDR3 memory clock 200 MHz, DDR3 input 50 MHz (EX `ae350_customized_demo/ReadMe.txt`). DDR3 pins in its .cst are 32 bits wide (`DDR3_DQ[31:0]`, SSTL15) |
| Licence of the IP | Not in Education (above); available in the Standard edition |

## Rust target

- `riscv32imafc-unknown-none-elf`: bare RV32IMAFC, hardware single-precision float. **Tier 2** (RUST);
  promoted in Rust 1.77 (rust-lang/rust PR 118704). No upstream RV32 target uses the D extension; doubles
  would need a custom target file. We use f32 in our own code; since the cpu-budget work the firmware is
  built with `-C target-feature=+d` (rustc calls the feature unstable but accepts it on stable 1.93; the ABI
  stays ilp32f), so f64 in dependencies such as mfsk-core runs on the D unit instead of in software
  (`docs/CPU_BUDGET.md` section 5).
- `-C target-cpu=andes-a25` exists in Rust 1.93 (LLVM model: RV32GC plus the Andes performance extension
  XAndesPerf); QEMU cannot run XAndesPerf, so it is not used yet. The Andes P (packed-SIMD DSP) extension that
  MUG1031 lists is not in that model and has no rustc target feature (`docs/CPU_BUDGET.md` section 4).
- On this PC: rustc 1.88.0. The target is not installed yet (`rustup target list --installed`). Slint 1.18.1
  needs Rust 1.92 and mfsk-core 0.11 needs 1.93 (crates.io `rust_version`): update the toolchain first.

## Ethernet (RJ45, used for the HL2)

- PHY **Realtek RTL8211FI-CG**, **RGMII**, gigabit; RJ45 with magnetics HY911130A (DOCK sheet RGMII_sch).
- The **FPGA supplies the PHY's 25 MHz reference**: in the Sipeed example a PLL makes 125 MHz for
  `RGMII_GTXCLK` (pin H24) and 25 MHz for `PHY_CLK` (pin E18) from the 50 MHz oscillator (EX
  `udp_rgmii_send/src/gowin_pll/GMII_pll.v`: 50 MHz x 20 = 1,000 MHz VCO, /8 and /40).
- Pins (EX `udp_rgmii_send/src/top.cst`): TXD0-3 K21, J21, L19, K18; TXEN J24; PHY reset E17; MDIO K22,
  MDC K23 (DOCK). RX data, RX_DV and RX clock pins: **NOT VERIFIED** (not extracted; read from DOCK sheet
  RGMII_sch before writing constraints).
- Sipeed's example is a send-only bandwidth test (about 900 Mbit/s seen on a PC), not a MAC or IP stack
  (EX `udp_rgmii_send/README.md`). An open issue reports it not working for some users.
- RGMII delay setting of the PHY (strap or MDIO): **NOT VERIFIED**.

## SFP+ cages (home network)

- Two cages. SFP0 on SerDes quad Q1 lane 0, SFP1 on Q1 lane 1 (DOCK sheet SFP-PLUS).
- Reference clocks `Q1_REFCLK0/1` come from two **MS5351M** clock generators, each with a 25 MHz crystal.
  **They are programmed over I2C by the BL616 debug chip, not by the FPGA** (DOCK sheet CLOCK; EX
  `sfp+/customized_phy/readme.md` and `docs/SET_5351.md`).
- Control pins: TX_DISABLE R18 (SFP0), M20 (SFP1); LOS V18, W18; module I2C through an I2C mux (EX
  `sfp+/10G_Serial_Ethernet/XGbE_UDP/src/fpga_project.cst`, DOCK).
- Sipeed examples: raw SerDes PRBS loopback at 1.25, 10.3125 and 12.5 Gbit/s using Gowin's "Customized PHY"
  IP with 8b/10b, and a 10 GbE UDP send test. Open issue #21: the SerDes example fails on newer IDE versions.
- What a home-network link needs: a module whose host side is **1000BASE-X** (1.25 Gbit/s, 8b/10b), a
  1000BASE-X PCS (Gowin lists SGMII and 1000BASE-X with its IP, DS1104 2.6), and a MAC in fabric. Many
  1000BASE-T copper modules default to SGMII; some (for example Finisar FCLF8521P2BTL) default to 1000BASE-X
  with auto-negotiation towards the host (Coherent application note AN-2036,
  https://www.coherent.com/resources/application-note/networking/1000base-t-sfp-faq-an-2036.pdf). A fibre
  1000BASE-SX/LX module is 1000BASE-X by definition.

## HDMI / DVI output

- Two TX and two RX ports, mutually exclusive ("DVI RX x2 / DVI TX x2", WIKI).
- **Plain FPGA I/O, no HDMI chip, no SerDes**: TMDS pairs are `IO_TYPE=LVCMOS33D` (emulated differential)
  on AB24/AC24, V24/W24, AA22/AA23, clock Y22/Y23 for port 0 (EX `simple_video_out/svo/src/hdmi.cst`); only
  ESD parts between pins and connector (DOCK sheet DVI_TX).
- **DDC (EDID) and CEC are wired** (DOCK), so the port can carry real HDMI, not only DVI.
- Speed: Sipeed's camera example runs **1280x720 at 60 Hz, 74.25 MHz pixel clock** (742.5 Mbit/s per lane)
  (EX `cam2hdmi_alt/cam2dvi/src/TMDS_60HZ.sdc`: 50 MHz x 297/200). No example at 1920x1080 60 Hz
  (148.5 MHz, 1,485 Mbit/s per lane) was found. The OSER10 serializer is rated to 1,600 Mbit/s (DS1239
  table 3-16); whether LVCMOS33D pins and the board traces carry 1,485 Mbit/s cleanly is **NOT VERIFIED**.
- **HDMI audio**: possible, because the TMDS encoding is done in logic. It needs HDMI data islands (audio
  sample and InfoFrame packets), which Gowin's DVI TX IP does not produce. The open core hdl-util/hdmi
  (https://github.com/hdl-util/hdmi, "MIT OR Apache-2.0", SystemVerilog) does, and has a Gowin OSER10
  serializer path. Not yet tried on this board.
- Connector type (full-size or mini): **NOT VERIFIED**.

## Audio

- Stereo DAC **PT8211-S** driven from FPGA pins `HP_BCK`, `HP_WS`, `HP_DIN` (**E22, F24, G24**: bit clock E22, word clock F24, data G24) (DOCK sheet
  DAC+PA; EX `audio/audio_music/src/audio.cst`), followed by a power amplifier for the speaker ("DAC+PA").
  The amplifier part number: **NOT VERIFIED**. The 3.5 mm headphone jack is on the same DAC (WIKI lists
  "3.5mm Headphone Jack" and "Speaker Interface").
- PT8211: 16-bit, two's complement, MSB first, **LSB-justified ("Japanese") format**, no master clock
  needed, BCK up to 20 MHz, 8x oversampling at 48 kHz word rate supported (PT8211).
- Digital audio outputs on PMOD2 = J26 (docs/AUDIO_OUT.md; balls from the DOCK PMOD sheet): S/PDIF on pin 12
  (`PMOD2_IO4`, B21) for a 3-pin TOSLINK transmitter module; I2S for a Pi-type DAC board on pins 9, 10, 7, 8
  (`PMOD2_IO1` B20 bit clock, `PMOD2_IO5` A20 word clock, `PMOD2_IO2` B19 data, `PMOD2_IO6` A19 master clock).
  J26 pins 1-2 are 3.3 V, 3-4 ground; pins 5, 6 (A17, A18) and 11 (C21) are free. Not tried on a board.
- Microphone array: 10-pin FPC connector J28 with `MIC_D1-D3`, `MIC_WS`, `MIC_BCK`: an I2S-style bus with
  three data lines (DOCK), for Sipeed's 6+1 microphone array (WIKI). Mic input is deferred by owner decision.

## USB

- **"Custom USB" (USB-C, J5, "USB2.0-DEV.")**: wired **directly to FPGA pins, no USB PHY chip**. The Sipeed
  example is a soft USB 2.0 device PHY in fabric (`usb_dxp_io` LVPECL33E, `usb_rxdp_i/usb_rxdn_i` LVDS25)
  (EX `usb2_soft/usb_uart_loopback/src/usb_ref.cst`). CC1/CC2 have 5.1 kOhm pull-downs (device role) and
  there is no VBUS switch (DOCK). WIKI: "cannot power the board".
- **USB host: No.** The port is built as a device: no VBUS source and device-role CC resistors. A host is
  built on a Pmod board instead (docs/USB_HOST.md): PMOD0 = J22, dock pins 9 to 12 = balls L22, N17, N18, M26;
  PMOD1 = J24 has C24, B24 (IO0, IO4), E25, D25 (IO1, IO5), L17, L18 (IO2, IO6), H14, H15 (IO3, IO7) and is free.
- **Debug USB-C**: goes to a **BL616** (Bouffalo Lab) that acts as the USB-to-JTAG (FPGA configuration) and
  USB-to-UART bridge; UART to FPGA pins N16/P15. The BL616 also programs the MS5351 SFP clock chips (DOCK).

## Memory and storage

- DDR3: two SK Hynix H5TQ4G63EFR-RDC (4 Gbit, x16 each) = **32-bit bus, 1 GB** (SOM). Issue #4 on EX reports
  shipped boards and example IP configurations naming different chips (Micron MT41J in some projects): check
  the chips on the delivered board.
- DDR3 speed in examples: 400 MHz memory clock = DDR3-800 (EX `cam2hdmi_alt/.../DDR3MI_400M`,
  `ddr_test_Micron_400MHz`). Peak bandwidth 32 bit x 800 MT/s = **3.2 GB/s**.
- Two 128 Mbit SPI NOR flashes: one for the FPGA bitstream, one on the AE350 flash controller (EX .cst paths
  `u_riscv_ae350_flash_top/u_gwspiflash`). Part numbers: **NOT VERIFIED**.
- microSD slot, 4-bit SDIO (DOCK).

## Other I/O

- RGB LCD connector with 6 bits per colour in the example (`lcd_r/g/b[5:0]`), examples at 480x272 and
  800x480 (EX `rgb_screen/`). WIKI says RGB888. 1024x600: **NOT VERIFIED**.
- 4 buttons, 6 LEDs, 3 PMOD headers, M.2 and PCIe (DOCK, WIKI).
- Power: USB-C 5 V or 12 V barrel jack (DOCK).

## Open questions

1. Gowin Standard licence: can the owner get one from Gowin (free or paid), or rely on Sipeed's floating
   licence servers? (Blocks every bitstream for this board.)
2. Does 1920x1080 at 60 Hz (1,485 Mbit/s per TMDS lane) work on the LVCMOS33D pins? First board test.
3. Does stock OpenOCD + GDB reach the AE350 debug module through its JTAG pins, and which adapter?
4. RGMII RX pin locations and the RTL8211F delay configuration.
5. HDMI connector type; speaker amplifier part; SPI flash parts; DDR3 chip actually fitted.
6. How to set the MS5351 SFP reference clocks to 125 MHz (BL616 firmware command or I2C access).
7. How the AE350 SPI flash is programmed with our firmware image (Gowin programmer, or our own loader).
8. How the shared-DDR3 controller arbitrates between the MCU and the fabric lanes (latency seen by video).
