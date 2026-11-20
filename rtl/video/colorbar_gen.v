// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// colorbar_gen: a test picture of eight vertical color bars that the HDMI output can show before the real screen exists.
//
// WHERE IT SITS
// sdr_hdmi_video.v instantiates it when its parameter EXT_RGB is 0. The HDMI encoder keeps two counters, cx and
// cy, that say which pixel of the picture it needs next (cx counts across a line, cy counts the lines down the screen,
// both starting at 0 in the top left corner of the visible area, see the header of sdr_hdmi_video.v), and this
// module answers with the 24-bit color of exactly that pixel. In the finished radio the compositor
// (compositor_pix.v) answers instead and draws the same bars itself while the firmware has not yet enabled it, so this
// module is mainly the simplest possible pixel source for a first picture on a new monitor or a new cable.
//
// WHAT IT DOES
// The visible width is cut into eight bars of equal width (1920 / 8 = 240 pixels each at 1080p). From left to right
// the colors are white, yellow, cyan, green, magenta, red, blue and black, which is the classic broadcast order: the
// bars are sorted from the brightest to the darkest, and a damaged color channel (a broken cable wire, say) shows up
// as a bar of the wrong color at a known place. Each color channel is 8 bits, so 8'hFF is full amplitude (100 %).
// A 24-bit pixel is {red[7:0], green[7:0], blue[7:0]}, the order the HDMI encoder expects.
//
// The module is purely combinational (no clock, no registers): the color follows cx at once, with no latency. cy is
// not used because the bars run the full height of the screen; it stays a port so that another pattern could use it
// (a moving line, for example) without changing the connections around it.
//
// SCREEN_WIDTH has to be a multiple of 8 for the bars to be exactly equal (1920 / 8 = 240 and 1280 / 8 = 160 both
// are). Other widths still work but the divide in bar_index gives a last bar of a different width, which the check
// below warns about in simulation.

// SCREEN_WIDTH, SCREEN_HEIGHT: size of the visible picture in pixels. BIT_WIDTH, BIT_HEIGHT: widths of cx and cy
// (12 bits count to 4095, enough for the 2200 pixels of a 1080p line, 11 bits count to 2047, enough for the 1125
// lines of a frame). SCREEN_HEIGHT is only carried along, the bars do not depend on it.
module colorbar_gen #(
    parameter integer SCREEN_WIDTH  = 1920,
    parameter integer SCREEN_HEIGHT = 1080,
    parameter integer BIT_WIDTH     = 12,
    parameter integer BIT_HEIGHT    = 11
) (
    input  wire [BIT_WIDTH-1:0]  cx,  // pixel column to draw, 0 at the left edge of the visible area
    input  wire [BIT_HEIGHT-1:0] cy,  // pixel line to draw, 0 at the top (not used)
    output reg  [23:0]           rgb  // color of that pixel, {red, green, blue} of 8 bits each
);

// Width of one bar in pixels. SCREEN_WIDTH / 8 is evaluated by the tool while building, so it costs no logic.
localparam integer BAR_WIDTH = SCREEN_WIDTH / 8;

// A warning in simulation only, so a width that does not divide by 8 does not go unnoticed.
// synthesis translate_off
initial begin
    if (SCREEN_WIDTH != BAR_WIDTH * 8)
        $display("colorbar_gen: WARNING SCREEN_WIDTH=%0d is not a multiple of 8; the last bar will be a different width", SCREEN_WIDTH);
end
// synthesis translate_on

// Which of the eight bars the column cx is in: the integer divide of cx by the bar width is a constant divisor, so
// it becomes a small comparator and not a real divider. Columns past the visible area (the blanking time, where the
// monitor ignores the color anyway) are sent to bar 7, black.
wire [2:0] bar_index = (cx < SCREEN_WIDTH) ? (cx / BAR_WIDTH) : 3'd7;

// The color table, written as a case statement that the tool turns into a small lookup: each bar index gives one
// fixed 24-bit color.
always @(*) begin
    case (bar_index)
        3'd0: rgb = 24'hFFFFFF;
        3'd1: rgb = 24'hFFFF00;
        3'd2: rgb = 24'h00FFFF;
        3'd3: rgb = 24'h00FF00;
        3'd4: rgb = 24'hFF00FF;
        3'd5: rgb = 24'hFF0000;
        3'd6: rgb = 24'h0000FF;
        default: rgb = 24'h000000;
    endcase
end

endmodule
