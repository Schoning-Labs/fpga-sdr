// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
// Measurement constraints for the stand-alone V2 compositor (gowin/res.sh compositor --clk2 clk_pix):
// the pixel clock 5 % tighter than 148.5 MHz, and the two clocks asynchronous as in the chip
// (every crossing is a toggle or gray code through flops; gowin/p1/sdr.sdc does the same).
create_clock -name clk_pix -period 6.4 [get_ports {clk_pix}]
set_clock_groups -asynchronous -group [get_clocks {clk}] -group [get_clocks {clk_pix}]
report_timing -setup -max_paths 300 -max_common_paths 1 -from_clock [get_clocks {clk_pix}] -to_clock [get_clocks {clk_pix}]
report_timing -setup -max_paths 300 -max_common_paths 1 -from_clock [get_clocks {clk}] -to_clock [get_clocks {clk}]
report_high_fanout_nets -max_nets 40
