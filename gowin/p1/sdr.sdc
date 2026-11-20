// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Timing constraints of the chip top level rtl/top/sdr_top.v, in the SDC format (the usual text format for timing
// constraints, which Gowin's place-and-route tool reads).
//
// WHAT THIS FILE DOES
// After the logic is placed on the chip, the tool checks every path from one register to the next against the clock that
// drives them: the data must arrive before the next clock edge (setup) and must not change too soon after the edge that
// captured the previous value (hold). To do that it must be told how fast each clock runs, so this file declares every
// clock of the design with its frequency. It then says which clocks have nothing to do with each other (asynchronous
// clock groups, whose crossings are built to be safe in the logic, so the tool must not time them), and which paths are
// not timed at all (false paths, mostly the pins that connect to the outside world through synchronizers). Without these
// lines the tool would try to time paths between unrelated clocks and report thousands of failures that cannot occur in
// the chip, and it would hide the failures that can.
// The file has four parts, in this order: the clocks (the primary clocks that enter at a pin, the PLL outputs derived from
// the 50 MHz oscillator, and the clocks of the transceiver), the asynchronous groups, the operating conditions, and the
// false paths of the pins. The PLL settings that the generated clocks must match are in gowin/p1/ip/*.mod, and the pattern
// of the AE350 and DDR3 lines follows Sipeed's ae350_customized_demo.sdc (Apache-2.0). For the terms see docs/learn/GLOSSARY.md.
//
// HOW THE FILE IS USED
// gowin/p1/build.sh joins this file with the timing exceptions of rtl/rx_backend and rtl/ft8 into one file for the tool. It
// first removes the blocks that belong to the other memory size: a block between a begin line and an end line that carry the
// tag DDR3-256-ONLY or the tag DDR3-1G-ONLY is kept only in the build with that memory (256 MB with the AE350's own DDR3
// controller, or 1 GB with Gowin's DDR3 IP). Those marker lines are matched by text, so they must not be changed, and every
// comment line inside such a block disappears together with the block.

// ---- primary clocks
// create_clock declares a clock that enters the chip at a pin. The oscillator on the SOM is 50 MHz: period 20 ns, rising
// edge at 0 ns, falling edge at 10 ns (a 50 percent duty cycle).
create_clock -name clk_50m  -period 20    -waveform {0 10} [get_ports {clk_50m}]
// The HL2 link has no RGMII receive clock: it runs on the transceiver's lane clocks declared below. The RJ45 PHY's receive
// clock pin is sampled as ordinary data by the network unit, so it is no clock of the design.

// ---- PLL outputs
// create_generated_clock declares a clock that a PLL makes from another clock. -source is where the master clock enters
// (the oscillator pin), -multiply_by and -divide_by give the ratio, so the frequency is 50 MHz x multiply / divide, and the
// last item is the output pin of the PLL primitive in the netlist (CLKOUT0 to CLKOUT4 of the instance named). The tool does
// not read the PLL's settings, so every ratio here is typed by hand and has to equal what the PLL really does.
// clk_dsp: 50 x 12 / 5 = 120 MHz, the clock of almost every block of the radio (the PLL's 1,200 MHz oscillator divided by 10).
create_generated_clock -name clk_dsp   -source [get_ports {clk_50m}] -master_clock clk_50m -multiply_by 12 -divide_by 5 [get_pins {u_pll_dsp/PLL_inst/CLKOUT0}]
// clk_eth: 50 x 2 = 100 MHz, the clock of the network unit on the RJ45 socket (rtl/net/net_unit.v). The PLL sits inside the
// core as Gowin_PLL_ETH, and its second output (25 MHz) has no load.
create_generated_clock -name clk_eth   -source [get_ports {clk_50m}] -master_clock clk_50m -multiply_by 2 [get_pins {u_core/u_eth_pll/u_pll/PLL_inst/CLKOUT0}]
// clk_pix5: 50 x 89 / 12 = 370.83 MHz, the HDMI bit clock of the serializers (the video PLL's oscillator runs at 1,112.5 MHz).
create_generated_clock -name clk_pix5  -source [get_ports {clk_50m}] -master_clock clk_50m -multiply_by 89 -divide_by 12 [get_pins {u_pll_video/PLL_inst/CLKOUT0}]
// clk_pix: 50 x 89 / 60 = 74.17 MHz, the pixel clock (1080p30), one fifth of clk_pix5.
create_generated_clock -name clk_pix   -source [get_ports {clk_50m}] -master_clock clk_50m -multiply_by 89 -divide_by 60 [get_pins {u_pll_video/PLL_inst/CLKOUT1}]
// The five outputs of the AE350's PLL (oscillator 800 MHz): ae350_ddr_clk 50 MHz is the CPU's data-memory bus clock,
// ae350_core_clk 50 x 16 = 800 MHz is the CPU core, ae350_ahb_clk and ae350_apb_clk 50 x 8 / 5 = 80 MHz are the two buses the
// CPU uses to reach peripherals, and ae350_rtc_clk 50 / 5 = 10 MHz is the real-time counter.
create_generated_clock -name ae350_ddr_clk -source [get_ports {clk_50m}] -master_clock clk_50m -multiply_by 1 [get_pins {u_pll_ae350/PLL_inst/CLKOUT0}]
create_generated_clock -name ae350_core_clk -source [get_ports {clk_50m}] -master_clock clk_50m -multiply_by 16 [get_pins {u_pll_ae350/PLL_inst/CLKOUT1}]
create_generated_clock -name ae350_ahb_clk -source [get_ports {clk_50m}] -master_clock clk_50m -multiply_by 8 -divide_by 5 [get_pins {u_pll_ae350/PLL_inst/CLKOUT2}]
create_generated_clock -name ae350_apb_clk -source [get_ports {clk_50m}] -master_clock clk_50m -multiply_by 8 -divide_by 5 [get_pins {u_pll_ae350/PLL_inst/CLKOUT3}]
create_generated_clock -name ae350_rtc_clk -source [get_ports {clk_50m}] -master_clock clk_50m -divide_by 5 [get_pins {u_pll_ae350/PLL_inst/CLKOUT4}]
// ---- AE350 SPI flash clock. The flash controller inside the AE350 IP (u_gwspiflash, Gowin's encrypted source) makes the flash
// clock in the fabric (a divided copy of the AHB clock, to the pad FLASH_SPI_CLK) and reads the pad back as a clock for its input
// registers (spi_in_r_*). If no clock is declared on that net, the tool takes the pad as an unrelated clock and times its
// registers against ae350_ahb_clk as if both started at time zero, which gives hold failures that do not exist in the
// chip: the returned clock is the AHB clock itself, delayed by the divider flop, the pad and the way back (several ns, all
// of it after the AHB edge it came from), so those paths start later than the tool assumes. The declaration below is the
// same line as in Sipeed's ae350_customized_demo.sdc (flash_sysclk on FLASH_SPI_CLK_in, 20 ns: the flash clock is at most
// the AHB clock / 2, so 20 ns is a safe bound at 80 MHz) and in an earlier design by the same author. The clock is made its own
// asynchronous group below, which removes only the paths between flash_sysclk registers and the other clocks. It does not touch
// the AHB-clock paths inside the controller and it does not check the flash pins: this file has no input or output delay
// on them, so the pin timing is not checked. The leg by hand (an estimate, the tool does not time it): the returned clock
// reaches spi_in_r_* about 7 ns after the AHB edge that made it (2.8 ns clock tree, 0.3 ns flop, about 3 ns out through the
// pad driver, 0.5 + 0.4 ns back in), the data leg to rx_shift_reg_r_* takes 0.7 ns, and the next AHB edge is 12.5 ns after
// the first at 80 MHz, so about 4.5 ns remain.
create_clock -name flash_sysclk -period 20 -waveform {0 10} [get_nets {FLASH_SPI_CLK_in}]
// ---- DDR3-256-ONLY begin (the 1 GB build feeds the DDR3 IP from the oscillator net: no clock of this name)
// ddr3_clkin: 50 MHz, the PLL's CLKOUT0, which feeds the reset and initialization logic of the AE350's own DDR3 controller.
create_generated_clock -name ddr3_clkin -source [get_ports {clk_50m}] -master_clock clk_50m -multiply_by 1 [get_pins {u_pll_ddr3/PLL_inst/CLKOUT0}]
// ---- DDR3-256-ONLY end
// ddr3_memory_clk: 50 x 6 = 300 MHz, the DDR3 memory clock (CLKOUT2 of the DDR3 PLL). This is deliberately below the 400 MHz the
// memory chips are rated for, because reads that overlap were lost or corrupted at 400 MHz when much logic switched at once.
create_generated_clock -name ddr3_memory_clk -source [get_ports {clk_50m}] -master_clock clk_50m -multiply_by 6 [get_pins {u_pll_ddr3/PLL_inst/CLKOUT2}]

// ---- DDR3-1G-ONLY begin (docs/MEM_1GB.md; gowin/p1/build.sh takes this block out with TR_DDR=256)
// The user clock of Gowin's DDR3 IP in rtl/mem/ddr_mem.v: the memory clock / 4 = 75 MHz, made by the CLKDIV of the IP's PHY
// (Sipeed's demo declares the same as ddr3_sysclk). It runs the IP's controller and
// ddr_mem_core. Every crossing to the bus side (ae350_ddr_clk) and to the lanes (clk_dsp) is a toggle through synchronizers with held
// data or a Gray-coded FIFO, so it is asynchronous to every other clock. The second group below lists the clocks it has
// paths to (a clock added elsewhere needs no entry here).
// -divide_by 4 here works on a clock that is itself a PLL output: the source is that PLL pin and the master clock is
// ddr3_memory_clk. The last item is the output pin of the divider inside the DDR3 PHY.
create_generated_clock -name ddr3_sys -source [get_pins {u_pll_ddr3/PLL_inst/CLKOUT2}] -master_clock ddr3_memory_clk -divide_by 4 [get_pins {u_mem/u_ddr3/gw3_top/u_ddr_phy_top/fclkdiv/CLKOUT}]
// The PLL's 50 MHz output CLKOUT0 also clocks the IP's reset and initialization logic. Without a name the tool names it
// "CLKOUT0.default_gen_clk" and times its reset paths into ddr3_sys as synchronous, which gives failures that cannot occur,
// because the reset crossings are handled in the IP. This file declares it as ddr3_ref and puts it in the asynchronous
// groups.
create_generated_clock -name ddr3_ref -source [get_ports {clk_50m}] -master_clock clk_50m -multiply_by 1 [get_pins {u_pll_ddr3/PLL_inst/CLKOUT0}]
// set_clock_groups -asynchronous says that the clocks in different -group items are unrelated: the tool does not time any path
// that starts in one group and ends in another, because every such crossing is built (in the logic) to work at any phase
// between the two clocks. Here ddr3_sys is separated from clk_dsp, the CPU's memory bus clock, the memory clock and the oscillator.
set_clock_groups -asynchronous -group [get_clocks {ddr3_sys}] -group [get_clocks {clk_dsp ae350_ddr_clk ddr3_memory_clk clk_50m}]
// ddr3_ref is separated from every other clock that exists in this build.
set_clock_groups -asynchronous -group [get_clocks {ddr3_ref}] -group [get_clocks {ddr3_sys}] -group [get_clocks {ddr3_memory_clk}] -group [get_clocks {clk_50m}] -group [get_clocks {ae350_ddr_clk}] -group [get_clocks {clk_dsp}]
// ---- DDR3-1G-ONLY end

// ---- audio outputs begin (docs/AUDIO_OUT.md section 3). The 48 MHz of the DSP PLL feeds the audio PLL only;
// the audio clock 49.152 MHz = 48 MHz x 128 / 125 clocks S/PDIF and I2S. Every signal between clk_dsp and clk_aud goes
// through synchronizer registers or is held while it is read (rtl/audio/audio_digital_out.v).
// HDMI audio has no clock of its own: the audio packets take their samples with a strobe in the pixel clock
// (rtl/video/sdr_hdmi_video.v).
// clk_48m: 50 x 24 / 25 = 48 MHz, the second output (CLKOUT1) of the DSP PLL, used by the USB full-speed logic and as the
// reference of the audio PLL.
create_generated_clock -name clk_48m -source [get_ports {clk_50m}] -master_clock clk_50m -multiply_by 24 -divide_by 25 [get_pins {u_pll_dsp/PLL_inst/CLKOUT1}]
// clk_aud: 48 x 128 / 125 = 49.152 MHz = 1,024 x 48 kHz, the output of the audio PLL. Its source is the 48 MHz pin of the DSP PLL
// and its master clock is clk_48m, because that is what feeds it.
create_generated_clock -name clk_aud -source [get_pins {u_pll_dsp/PLL_inst/CLKOUT1}] -master_clock clk_48m -multiply_by 128 -divide_by 125 [get_pins {u_pll_aud/PLL_inst/CLKOUT0}]
// clk_aud is asynchronous to clk_dsp, and clk_48m to clk_aud, although clk_aud is made from clk_48m: the crossings are
// synchronizers and held words.
set_clock_groups -asynchronous -group [get_clocks {clk_aud}] -group [get_clocks {clk_dsp}]
set_clock_groups -asynchronous -group [get_clocks {clk_48m}] -group [get_clocks {clk_aud}]
// ---- USB audio (docs/USB_AUDIO.md section 9): clk_48m also clocks the USB device (rtl/usb). Everything between it and clk_dsp is
// a Gray-coded FIFO pointer (rtl/usb/usb_afifo.v), a level through two registers or a toggle through three (rtl/usb/usb_regs.v,
// usb_audio.v), so the two are unrelated although they come from one PLL. The two data pins are read through two registers
// and driven from registers, at 4 clocks per bit.
set_clock_groups -asynchronous -group [get_clocks {clk_48m}] -group [get_clocks {clk_dsp}]
// set_false_path tells the tool not to time a path at all. The USB data pins are not timed against a clock because the
// logic reads them through two registers and drives them from registers, at 4 clocks per bit, which is slow compared with
// the 48 MHz clock.
set_false_path -from [get_ports {usb_dp usb_dn}]
set_false_path -to [get_ports {usb_dp usb_dn usb_pullup}]
// ---- USB host (docs/USB_HOST.md): the four data pins of the Pmod USB host board, read through two registers and driven from
// clk_48m registers (behind the D+/D- switch of usbh.ctrl.swap), at 4 or 32 clocks per bit, so they are false paths too
set_false_path -from [get_ports {usbh_a[*] usbh_b[*]}]
set_false_path -to [get_ports {usbh_a[*] usbh_b[*]}]
// hdl-util's serializer resets its OSER10 serializers from the pixel-clock reset. The reset is held for many clocks, so its
// timing to the 5x clock does not matter, and the three paths to the serializers' RESET pins are false paths.
set_false_path -to [get_pins {u_hdmi/u_hdmi_0/serializer/gwSer0/RESET}]
set_false_path -to [get_pins {u_hdmi/u_hdmi_0/serializer/gwSer1/RESET}]
set_false_path -to [get_pins {u_hdmi/u_hdmi_0/serializer/gwSer2/RESET}]
// ---- audio outputs end

// ---- SFP+ transceiver (docs/SFP_LINKS.md section 3): the three lane clocks, 125 MHz each. sfp_txc is made from the 125 MHz
// reference by the lane PLL, n1_rxc and bl_rxc are recovered from the received data. Each is asynchronous to every other clock:
// status crosses as held words behind toggles (rtl/sfp/sfp_xstat.v), samples and packets through Gray-coded FIFOs and
// two-clock block RAM, resets through synchronizers. n1_rxc is the receive clock of lane 0 (SFP0, the HL2 link) and bl_rxc that
// of lane 1.
// These three are declared with create_clock on the nets, because the transceiver makes them and they are not outputs of a
// PLL primitive that the tool follows. Period 8 ns = 125 MHz, rising edge at 0, falling edge at 4 ns.
create_clock -name sfp_txc -period 8 -waveform {0 4} [get_nets {sfp_txc}]
create_clock -name n1_rxc  -period 8 -waveform {0 4} [get_nets {n1_rxc}]
create_clock -name bl_rxc  -period 8 -waveform {0 4} [get_nets {bl_rxc}]
// the three lane clocks and clk_dsp are unrelated to each other
set_clock_groups -asynchronous -group [get_clocks {sfp_txc}] -group [get_clocks {n1_rxc}] -group [get_clocks {bl_rxc}] -group [get_clocks {clk_dsp}]

// ---- asynchronous domains: every crossing between these groups is a handshake, a Gray-coded FIFO or a synchronizer
// (docs/P1_TOP.md section 3). Clocks that are in one group and made by one PLL (clk_pix and clk_pix5, ae350_ahb_clk and
// ae350_apb_clk) are related to each other and are timed normally.
// The groups in the next line are: clk_dsp, n1_rxc, sfp_txc, bl_rxc, clk_eth, clk_pix with clk_pix5, ae350_ahb_clk with ae350_apb_clk,
// ae350_core_clk, flash_sysclk, ae350_ddr_clk, ae350_rtc_clk, ddr3_memory_clk and clk_50m.
set_clock_groups -asynchronous -group [get_clocks {clk_dsp}] -group [get_clocks {n1_rxc}] -group [get_clocks {sfp_txc}] -group [get_clocks {bl_rxc}] -group [get_clocks {clk_eth}] -group [get_clocks {clk_pix clk_pix5}] -group [get_clocks {ae350_ahb_clk ae350_apb_clk}] -group [get_clocks {ae350_core_clk}] -group [get_clocks {flash_sysclk}] -group [get_clocks {ae350_ddr_clk}] -group [get_clocks {ae350_rtc_clk}] -group [get_clocks {ddr3_memory_clk}] -group [get_clocks {clk_50m}]
// the same for the 256 MB build, with the PLL copy of the oscillator clock (ddr3_clkin) that this build still has
// ---- DDR3-256-ONLY begin (the same, with the PLL copy of the oscillator clock the 256 MB build still has)
set_clock_groups -asynchronous -group [get_clocks {clk_dsp}] -group [get_clocks {n1_rxc}] -group [get_clocks {sfp_txc}] -group [get_clocks {bl_rxc}] -group [get_clocks {clk_eth}] -group [get_clocks {clk_pix clk_pix5}] -group [get_clocks {ae350_ahb_clk ae350_apb_clk}] -group [get_clocks {ae350_core_clk}] -group [get_clocks {flash_sysclk}] -group [get_clocks {ae350_ddr_clk}] -group [get_clocks {ae350_rtc_clk}] -group [get_clocks {ddr3_clkin}] -group [get_clocks {ddr3_memory_clk}] -group [get_clocks {clk_50m}]
// ---- DDR3-256-ONLY end

// The timing model for the checks: commercial temperature grade, the slow model (the worst case for setup), speed class 2,
// for both the setup and the hold analysis.
set_operating_conditions -grade c -model slow -speed 2 -setup -hold

// ---- RGMII I/O of the RJ45 socket (the network unit, rtl/net/eth_top.v, 100 Mbit/s). RXC, RXD and RX_CTL go through two
// synchronizer registers of clk_eth and are sampled 10 to 20 ns after RXC rises (a nibble is held for 40 ns). TXC, TXD, TX_CTL,
// MDC, MDIO and the PHY's 25 MHz reference are registers of clk_eth that change a quarter of a period away from the TXC edges
// (a board-tested unit). No pin is timed against a clock, because this file has no input or output delay for any pin:
// they are false paths, as for the USB pins.
set_false_path -from [get_ports {rgmii_rxc rgmii_rxd[*] rgmii_rx_ctl phy_mdio}]
set_false_path -to [get_ports {rgmii_txc rgmii_txd[*] rgmii_tx_ctl phy_clk phy_rst_n phy_mdc phy_mdio}]
