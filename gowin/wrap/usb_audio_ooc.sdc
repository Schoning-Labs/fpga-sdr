// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
// Measurement constraints for the stand-alone USB audio device (docs/USB_AUDIO.md):
//   gowin/res.sh usb_audio --clk clk_dsp --clk2 clk_usb --period-ns 7.917 --wrap --sdc gowin/wrap/usb_audio_ooc.sdc ...
// clk (the wrapper's name for clk_dsp) at 120 MHz less 5 %; the USB clock at 48 MHz less 5 % (19.84 ns); the two
// asynchronous as in the chip (every crossing is a Gray-coded pointer, a level or a toggle through
// registers; gowin/p1/sdr.sdc does the same).
create_clock -name clk_usb -period 19.84 [get_ports {clk_usb}]
set_clock_groups -asynchronous -group [get_clocks {clk}] -group [get_clocks {clk_usb}]
report_timing -setup -max_paths 40 -max_common_paths 1 -from_clock [get_clocks {clk_usb}] -to_clock [get_clocks {clk_usb}]
report_timing -setup -max_paths 40 -max_common_paths 1 -from_clock [get_clocks {clk}] -to_clock [get_clocks {clk}]
report_timing -hold -max_paths 20 -max_common_paths 1
