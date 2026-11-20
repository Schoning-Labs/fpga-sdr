// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Timing constraints of rtl/top/ladder_top.v: gowin/p1/sdr.sdc of this repository
// (commit 59cfb25) without the Ethernet clocks (clk_rx, clk_tx, clk_25), the RGMII delays and the HDMI audio
// clock, which are not in the ladder; the PLL settings are those of gowin/p1/ip/*.mod. The pattern of the AE350 and
// DDR3 lines follows Sipeed's ae350_customized_demo.sdc (Apache-2.0). Two lines (the HDMI serializers' reset
// pins) are taken out by gowin/ladder/build.sh in step 1, which has no video.

// ---- primary clock
create_clock -name clk_50m  -period 20    -waveform {0 10} [get_ports {clk_50m}]

// ---- PLL outputs
create_generated_clock -name clk_dsp   -source [get_ports {clk_50m}] -master_clock clk_50m -multiply_by 12 -divide_by 5 [get_pins {u_pll_dsp/PLL_inst/CLKOUT0}]
create_generated_clock -name clk_pix5  -source [get_ports {clk_50m}] -master_clock clk_50m -multiply_by 119 -divide_by 8 [get_pins {u_pll_video/PLL_inst/CLKOUT0}]
create_generated_clock -name clk_pix   -source [get_ports {clk_50m}] -master_clock clk_50m -multiply_by 119 -divide_by 40 [get_pins {u_pll_video/PLL_inst/CLKOUT1}]
create_generated_clock -name ae350_ddr_clk -source [get_ports {clk_50m}] -master_clock clk_50m -multiply_by 1 [get_pins {u_pll_ae350/PLL_inst/CLKOUT0}]
create_generated_clock -name ae350_core_clk -source [get_ports {clk_50m}] -master_clock clk_50m -multiply_by 16 [get_pins {u_pll_ae350/PLL_inst/CLKOUT1}]
create_generated_clock -name ae350_ahb_clk -source [get_ports {clk_50m}] -master_clock clk_50m -multiply_by 8 -divide_by 5 [get_pins {u_pll_ae350/PLL_inst/CLKOUT2}]
create_generated_clock -name ae350_apb_clk -source [get_ports {clk_50m}] -master_clock clk_50m -multiply_by 8 -divide_by 5 [get_pins {u_pll_ae350/PLL_inst/CLKOUT3}]
create_generated_clock -name ae350_rtc_clk -source [get_ports {clk_50m}] -master_clock clk_50m -divide_by 5 [get_pins {u_pll_ae350/PLL_inst/CLKOUT4}]
// The SPI flash clock of the AE350 (as in gowin/p1/sdr.sdc, which gives the reasons): the flash controller inside
// the IP makes the flash clock in the fabric and reads the pad back as a clock for its input registers. Declared on the
// net, its own asynchronous group below; without it the tool timed those registers against the AHB clock as if both
// started at time zero (32 false hold failures in the full-chip build).
create_clock -name flash_sysclk -period 20 -waveform {0 10} [get_nets {FLASH_SPI_CLK_in}]
create_generated_clock -name ddr3_clkin -source [get_ports {clk_50m}] -master_clock clk_50m -multiply_by 1 [get_pins {u_pll_ddr3/PLL_inst/CLKOUT0}]
create_generated_clock -name ddr3_memory_clk -source [get_ports {clk_50m}] -master_clock clk_50m -multiply_by 6 [get_pins {u_pll_ddr3/PLL_inst/CLKOUT2}]

// The user clock of Gowin's DDR3 IP in rtl/mem/ddr_mem.v: memory clock / 4 = 100 MHz, made by the CLKDIV of its PHY
// (Sipeed's demo declares the same as ddr3_sysclk).
create_generated_clock -name ddr3_sys -source [get_pins {u_pll_ddr3/PLL_inst/CLKOUT2}] -master_clock ddr3_memory_clk -divide_by 4 [get_pins {u_mem/u_ddr3/gw3_top/u_ddr_phy_top/fclkdiv/CLKOUT}]
set_clock_groups -asynchronous -group [get_clocks {ddr3_sys}] -group [get_clocks {clk_dsp ae350_ddr_clk ae350_ahb_clk ae350_apb_clk ddr3_clkin ddr3_memory_clk clk_50m}]

// ---- asynchronous domains: every crossing between these is a handshake, a Gray-coded FIFO or a synchroniser
set_clock_groups -asynchronous -group [get_clocks {clk_dsp}] -group [get_clocks {clk_pix clk_pix5}] -group [get_clocks {ae350_ahb_clk ae350_apb_clk}] -group [get_clocks {ae350_core_clk}] -group [get_clocks {flash_sysclk}] -group [get_clocks {ae350_ddr_clk}] -group [get_clocks {ae350_rtc_clk}] -group [get_clocks {ddr3_clkin}] -group [get_clocks {ddr3_memory_clk}] -group [get_clocks {clk_50m}]

set_operating_conditions -grade c -model slow -speed 2 -setup -hold

// hdl-util's serializer resets its OSER10s from the pixel-clock reset; the reset is held for many clocks, so its
// timing to the 5x clock does not matter (docs/PLAN.md LS2 (d))
set_false_path -to [get_pins {u_bars/u_hdmi/serializer/gwSer0/RESET}]
set_false_path -to [get_pins {u_bars/u_hdmi/serializer/gwSer1/RESET}]
set_false_path -to [get_pins {u_bars/u_hdmi/serializer/gwSer2/RESET}]
