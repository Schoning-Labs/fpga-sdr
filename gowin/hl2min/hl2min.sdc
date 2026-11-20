// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Timing constraints of the minimal HL2 test build rtl/hl2min/hl2min_top.v (docs/HL2MIN.md section 6). Three clocks,
// no PLL: the board oscillator and the transceiver's two lane-0 clocks (lane 0 transmit word clock, made from the
// clock chip's 125 MHz reference; lane 0 recovered clock). Every crossing between them is a held word behind a
// toggle (rtl/hl2link/cdc_word.v, rtl/sfp/sfp_xstat.v), a synchroniser or a reset synchroniser, so the three are
// asynchronous groups (Gowin SUG940 set_clock_groups -asynchronous).
create_clock -name clk_50m -period 20 -waveform {0 10} [get_ports {clk_50m}]
create_clock -name sfp_txc -period 8 -waveform {0 4} [get_nets {sfp_txc}]
create_clock -name n1_rxc  -period 8 -waveform {0 4} [get_nets {n1_rxc}]
set_clock_groups -asynchronous -group [get_clocks {clk_50m}] -group [get_clocks {sfp_txc}] -group [get_clocks {n1_rxc}]
set_operating_conditions -grade c -model slow -speed 2 -setup -hold
