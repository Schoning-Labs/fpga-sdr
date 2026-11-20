// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// video_pll_gowin: an empty placeholder for a video PLL wrapper. Nothing in the radio instantiates it.
//
// WHAT IS REALLY USED
// The video clocks of the radio come from the Gowin IP block Gowin_PLL_VIDEO (generated with Gowin's IP generator, its
// settings are in gowin/p1/ip/gowin_pll_video.mod), which sdr_top.v instantiates. It multiplies the board's 50 MHz
// oscillator up to a VCO frequency of 1,112.5 MHz and divides it twice: by 3 for clk_pix5 = 370.83 MHz (the TMDS bit
// clock, five times the pixel clock, see rtl/video/sdr_hdmi_video.v) and by 15 for clk_pix = 74.17 MHz (the pixel
// clock of 1080p30). A PLL (phase locked loop) is a circuit that makes a new clock from an existing one with a fixed
// frequency ratio and a fixed phase relation, which is what the OSER10 serializers need between their two clocks.
//
// WHY THE FILE STILL EXISTS
// sdr_hdmi_video.v takes clk_pixel and clk_pixel_x5 as plain inputs and does not depend on this file, so a
// testbench can drive both clocks directly. If the module is instantiated by mistake, the simulation stops with a
// message instead of running with a clock that never toggles.

module video_pll_gowin (
    input  wire clk_50m,  // 50 MHz board oscillator
    input  wire mode_select,   // would select the video mode: 0 = 1080p60 (148.5 / 742.5 MHz), 1 = 74.25 / 371.25 MHz
    output wire clk_pixel,  // would be the pixel clock
    output wire clk_pixel_x5,  // would be 5 x the pixel clock
    output wire locked  // would go high when the PLL has locked
);

// Not implemented: see comment above. Left as an unsynthesisable stub (not `included by
// anything else in this package) so its absence is a build-time error, not a silent zero clock,
// if something ever tries to instantiate it before T1 unblocks.
// synthesis translate_off
initial begin
    $display("video_pll_gowin: NOT IMPLEMENTED -- blocked on Gowin EDA Standard licence (see docs/V1_VIDEO.md)");
    $stop;
end
// synthesis translate_on

endmodule
