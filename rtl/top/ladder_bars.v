// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ladder_bars: eight colour bars through the HDMI core, step 2 of the bring-up ladder (rtl/top/ladder_top.v, docs/LADDER.md).
//
// WHAT IT DOES
// A colour bar generator produces the picture (eight vertical bars of the usual test colours) and the vendored hdl-util
// HDMI core (rtl/vendor/hdmi/) turns it into the four TMDS bit streams of an HDMI cable, using Gowin OSER10 serializers
// (a serializer takes ten parallel bits per pixel clock and shifts them out at ten times the pixel clock, that is, twice per
// cycle of the 5x bit clock). There is no audio: the core's audio inputs are held at zero and its audio clock is tied low.
// The only things under test are therefore the pixel clock, the 5x bit clock, the serializers and the pins. This is the video
// path of rtl/video/sdr_hdmi_video.v without the tone generator and the audio clock.
// The HDMI mode is video mode code 16, the 1080p60 timing of 2,200 by 1,125 clocks per frame with 1,920 by 1,080 visible
// pixels. The refresh rate follows the pixel clock that clk_pixel brings: 148.5 MHz would give 60 Hz, and the 74.17 MHz of the
// video PLL in gowin/p1/ip gives 29.97 Hz (74.17 MHz / (2,200 x 1,125)).
// The instance is named u_hdmi because the false paths of gowin/ladder/ladder.sdc for the serializers' reset pins name it,
// so it must not be renamed.
//
// `frame` is one clk_pixel clock wide pulse per frame (taken when the pixel position is 0, 0); the ladder counts it.

`timescale 1ns / 1ps

module ladder_bars (
    input  wire clk_pixel,  // pixel clock
    input  wire clk_pixel_x5,  // bit clock of the serializers, five times the pixel clock (the OSER10 shifts on both edges)
    input  wire reset,  // reset for the HDMI core, synchronous to clk_pixel, active high
    output wire [2:0] tmds,  // the three TMDS data lanes, one serialized bit stream each, going to the pseudo-differential pads
    output wire       tmds_clock,  // the TMDS clock lane, serialized
    output wire       frame  // one clk_pixel clock wide pulse once per picture, at the first pixel of the frame
);
    // cx and cy = the position of the pixel being sent, counted by the HDMI core over the whole frame including the blanking
    // (cx 0 to 2,199, cy 0 to 1,124); rgb = the 24-bit colour of the bar at that position (8 bits each of red, green, blue)
    wire [11:0] cx;
    wire [10:0] cy;
    wire [23:0] rgb;
    // the colour bar generator, for the 1,920 by 1,080 visible area
    colorbar_gen #(.SCREEN_WIDTH(1920), .SCREEN_HEIGHT(1080), .BIT_WIDTH(12), .BIT_HEIGHT(11)) u_colorbar (
        .cx(cx), .cy(cy), .rgb(rgb));

    // no audio: two 16-bit sample words (left and right) held at zero, and the audio clock input of the core is tied low
    wire [15:0] audio_sample_word [1:0];
    assign audio_sample_word[0] = 16'd0;
    assign audio_sample_word[1] = 16'd0;

    // outputs of the core that the ladder does not use (frame and screen size)
    wire [11:0] frame_width_unused, screen_width_unused;
    wire [10:0] frame_height_unused, screen_height_unused;
    // the HDMI core: video mode 16, HDMI (not DVI) mode with its info frames, 60 Hz as the mode's nominal rate, audio parameters
    // (48 kHz, 16 bit) that stay idle, and the text of the vendor and product info frame
    hdmi #(
        .VIDEO_ID_CODE(16), .DVI_OUTPUT(1'b0), .VIDEO_REFRESH_RATE(60.0),
        .AUDIO_RATE(48000), .AUDIO_BIT_WIDTH(16),
        .VENDOR_NAME({"fpgasdr", 8'd0}), .PRODUCT_DESCRIPTION({"fpga-sdr LAD2", 24'd0}),
        .BIT_WIDTH(12), .BIT_HEIGHT(11)
    ) u_hdmi (
        .clk_pixel_x5(clk_pixel_x5), .clk_pixel(clk_pixel), .clk_audio(1'b0), .reset(reset),
        .rgb(rgb), .audio_sample_word(audio_sample_word),
        .tmds(tmds), .tmds_clock(tmds_clock), .cx(cx), .cy(cy),
        .frame_width(frame_width_unused), .frame_height(frame_height_unused),
        .screen_width(screen_width_unused), .screen_height(screen_height_unused));

    // frame = one pulse per picture: cx and cy both 0, registered
    reg f = 1'b0;
    always @(posedge clk_pixel) f <= (cx == 12'd0) && (cy == 11'd0);
    assign frame = f;
endmodule
