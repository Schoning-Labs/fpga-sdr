// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// compositor_cfg.vh: the layout of the "picture description", the one wide vector `cfg` that tells the compositor what
// the screen looks like in the current frame.
//
// WHAT IT IS
// The firmware sets up the screen through many registers (window positions and sizes, colors, grid spacing, passbands,
// cursor, framebuffer address, see hw/regmap/video.toml). If a register changed while a frame was being drawn the picture
// would tear, with the top half drawn from the old settings and the bottom half from the new. So the compositor takes
// its settings over once per frame, in the vertical blanking, as one block of bits. The block has three lives: the
// register file in compositor.v builds it from the registers in clk_dsp (it is called `snap` there), the fetch engine
// (compositor_fetch.v) reads the DDR3 side fields of it in clk_dsp, and compositor_util.v's comp_xfer copies the whole
// block into the pixel clock (clk_pix), where it is called `cfg` and read by compositor_pix.v. The same layout is used in
// all places, which is what this file defines, so that no module needs to know the bit positions of another.
//
// HOW TO READ IT
// `cfg` is a flat vector. Every field has two macros: CF_<name>_L is its lowest bit and CF_<name>_W its width in bits,
// and each field starts right above the one before (the definition of _L adds the previous field's _L and _W), so
// inserting a field moves all the following ones and nothing else has to change. A field that exists once per window has
// four values and window i is at bit CF_<name>_L + i * (CF_<name>_W / 4); the window number runs 0 to 3. A field per
// receiver passband has eight values in the same way. Fields that are used only on the DDR3 side or only for the two
// waterfall windows are marked below. The total width is CF_W, which a user takes as the port width.
//
// Pixel columns are counted from the left edge of the screen (0 to 1919) and rows from the top (0 to 1079). Level values
// are signed in 1/64 dB, as the spectrum line buffer delivers them.

`ifndef COMPOSITOR_CFG_VH
`define COMPOSITOR_CFG_VH

// window enabled (per window, 4 bits): enable bit set and the window has a width and a height above 0
`define CF_WEN_L      0
`define CF_WEN_W      4
// window is a waterfall (per window, 4 bits; only windows 0 and 1 can be waterfalls, the bits of 2 and 3 are 0)
`define CF_WF_L       (`CF_WEN_L + `CF_WEN_W)
`define CF_WF_W       4
// window shows the zoom spectrum (per window, 4 bits)
`define CF_WZ_L       (`CF_WF_L + `CF_WF_W)
`define CF_WZ_W       4
// window left edge, pixel column (per window, 12 bits)
`define CF_WX_L       (`CF_WZ_L + `CF_WZ_W)
`define CF_WX_W       48
// window right edge, one past the last column: left edge + width (per window, 12 bits)
`define CF_WXE_L      (`CF_WX_L + `CF_WX_W)
`define CF_WXE_W      48
// window top edge, pixel row (per window, 11 bits)
`define CF_WY_L       (`CF_WXE_L + `CF_WXE_W)
`define CF_WY_W       44
// window bottom edge, one past the last row: top edge + height (per window, 11 bits)
`define CF_WYE_L      (`CF_WY_L + `CF_WY_W)
`define CF_WYE_W      44
// first source column shown at window column 0: the spectrum or waterfall line is read from this column on (per window,
// 12 bits)
`define CF_WSX0_L     (`CF_WYE_L + `CF_WYE_W)
`define CF_WSX0_W     48
// window height minus 1, the last row of the window (per window, 11 bits)
`define CF_WHM1_L     (`CF_WSX0_L + `CF_WSX0_W)
`define CF_WHM1_W     44
// trace windows: the level at the top row of the window, signed, in 1/64 dB (per window, 16 bits)
`define CF_WREF_L     (`CF_WHM1_L + `CF_WHM1_W)
`define CF_WREF_W     64
// trace windows: pixels per dB as a fixed point number with 8 fractional bits, so 16'h0100 is 1 pixel per dB (per
// window, 16 bits)
`define CF_WGAIN_L    (`CF_WREF_L + `CF_WREF_W)
`define CF_WGAIN_W    64
// vertical grid lines (frequency): window column of the first line (per window, 12 bits); then the spacing in pixels,
// where 0 switches the grid off
`define CF_WGXF_L     (`CF_WGAIN_L + `CF_WGAIN_W)
`define CF_WGXF_W     48
`define CF_WGXS_L     (`CF_WGXF_L + `CF_WGXF_W)
`define CF_WGXS_W     48
// horizontal grid lines (level), trace windows only: window row of the first line (per window, 12 bits); then the
// spacing in pixels, 0 = off
`define CF_WGYF_L     (`CF_WGXS_L + `CF_WGXS_W)
`define CF_WGYF_W     48
`define CF_WGYS_L     (`CF_WGYF_L + `CF_WGYF_W)
`define CF_WGYS_W     48
// waterfall fetch (clk_dsp only, for waterfall windows 0 and 1): the first 64-bit word of the ring line that the window
// shows (the source column divided by 8, 8 bits each), and the number of words from there to the right edge of the window
// or the end of the line (9 bits each, at most 240)
`define CF_WFW0_L     (`CF_WGYS_L + `CF_WGYS_W)
`define CF_WFW0_W     16
`define CF_WFN_L      (`CF_WFW0_L + `CF_WFW0_W)
`define CF_WFN_W      18
// trace window background color, 24-bit {red, green, blue}
`define CF_CBG_L      (`CF_WFN_L + `CF_WFN_W)
`define CF_CBG_W      24
// trace window fill color, the area below the trace line
`define CF_CFILL_L    (`CF_CBG_L + `CF_CBG_W)
`define CF_CFILL_W    24
// trace line color
`define CF_CTRACE_L   (`CF_CFILL_L + `CF_CFILL_W)
`define CF_CTRACE_W   24
// grid line color
`define CF_CGRID_L    (`CF_CTRACE_L + `CF_CTRACE_W)
`define CF_CGRID_W    24
// key color in RGB565 (5 bits red, 6 bits green, 5 bits blue): where the GUI framebuffer has exactly this color inside a
// window, the FPGA layer shows through
`define CF_KEY_L      (`CF_CGRID_L + `CF_CGRID_W)
`define CF_KEY_W      16
// compositor enable: 0 shows the color bars instead of the picture and reads no DDR3
`define CF_EN_L       (`CF_KEY_L + `CF_KEY_W)
`define CF_EN_W       1
// tuning cursor: enable, then the windows it is drawn in (one bit per window), then its first column, its end column
// (one past the last, so the width is CURXE - CURX) and its color
`define CF_CUREN_L    (`CF_EN_L + `CF_EN_W)
`define CF_CUREN_W    1
`define CF_CURWM_L    (`CF_CUREN_L + `CF_CUREN_W)
`define CF_CURWM_W    4
`define CF_CURX_L     (`CF_CURWM_L + `CF_CURWM_W)
`define CF_CURX_W     12
`define CF_CURXE_L    (`CF_CURX_L + `CF_CURX_W)
`define CF_CURXE_W    12
`define CF_CURCOL_L   (`CF_CURXE_L + `CF_CURXE_W)
`define CF_CURCOL_W   24
// receiver passbands (eight of them): enable bit, the windows each is drawn in (4 bits each), first column and one past
// the last (12 bits each), opacity in sixteenths 0 to 16 (5 bits each, counted as at most 16) and color (24 bits each)
`define CF_PBEN_L     (`CF_CURCOL_L + `CF_CURCOL_W)
`define CF_PBEN_W     8
`define CF_PBWM_L     (`CF_PBEN_L + `CF_PBEN_W)
`define CF_PBWM_W     32
`define CF_PBX0_L     (`CF_PBWM_L + `CF_PBWM_W)
`define CF_PBX0_W     96
`define CF_PBX1_L     (`CF_PBX0_L + `CF_PBX0_W)
`define CF_PBX1_W     96
`define CF_PBAL_L     (`CF_PBX1_L + `CF_PBX1_W)
`define CF_PBAL_W     40
`define CF_PBCOL_L    (`CF_PBAL_L + `CF_PBAL_W)
`define CF_PBCOL_W    192
// fetch side (clk_dsp only). FBW is the GUI framebuffer base as a 64-bit word address (the byte address divided by 8, 29
// bits) and FBSW the line stride in words (20 bits; 480 words = 3,840 bytes for 1,920 pixels of 2 bytes). WFRING and
// WLTOP hold two values each, for waterfall window i at bit CF_<name>_L + i * (CF_<name>_W / 2): the DDR3 word address of
// the window's ring of lines (32 bits each) and its scroll line, the ring line shown in the top row (11 bits each). FBBYTE
// is the framebuffer base byte address, kept so that the register that reports the active buffer can read it back.
`define CF_FBW_L      (`CF_PBCOL_L + `CF_PBCOL_W)
`define CF_FBW_W      29
`define CF_FBSW_L     (`CF_FBW_L + `CF_FBW_W)
`define CF_FBSW_W     20
`define CF_WFRING_L   (`CF_FBSW_L + `CF_FBSW_W)
`define CF_WFRING_W   64
`define CF_WLTOP_L    (`CF_WFRING_L + `CF_WFRING_W)
`define CF_WLTOP_W    22
`define CF_FBBYTE_L   (`CF_WLTOP_L + `CF_WLTOP_W)
`define CF_FBBYTE_W   32
`define CF_W          (`CF_FBBYTE_L + `CF_FBBYTE_W)

`endif
