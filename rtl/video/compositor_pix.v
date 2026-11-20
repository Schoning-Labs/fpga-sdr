// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// compositor_pix: the pixel side of the screen compositor. For every pixel the monitor is about to get, it decides which
// color that pixel has, by stacking up to six layers.
//
// WHERE IT SITS
// compositor.v instantiates it together with the register file (compositor_regs) and the DDR3 fetch engine
// (compositor_fetch.v). Everything in this module runs in the pixel clock clk_pix (74.17 MHz at 1080p30). Its inputs are
// the position (cx, cy) that the HDMI core is asking a pixel for (rtl/video/sdr_hdmi_video.v has the theory of cx
// and cy, blanking and sync), the picture description `cfg` (compositor_cfg.vh, a copy of the registers that changes only
// in the vertical blanking) and the read data of four memories: the GUI line buffer, the spectrum snapshot, the waterfall
// line buffer and the palette (all block RAM in compositor.v, filled in clk_dsp by the fetch engine and the register file).
// The output is `rgb`, 24 bits of {red, green, blue}, which goes to the HDMI core as the pixel of (cx, cy).
//
// THE LAYERS AND THE TERMS (also in docs/learn/GLOSSARY.md)
// The picture is made of two sources. The GUI is drawn by the firmware (the Slint toolkit) into a framebuffer in DDR3 as
// RGB565 (16 bits per pixel: 5 bits red, 6 bits green, 5 bits blue). The spectrum trace and the waterfall are drawn here in
// hardware, because the CPU cannot redraw a 1,920 x 1,080 waterfall 30 times a second. The two are combined with a key
// color, which is the simplest kind of overlay: the firmware paints the rectangle where the FPGA windows are with one
// agreed color (magenta, 16'hF81F in RGB565) and the compositor shows the FPGA layer wherever it sees exactly that color
// inside a window. Anywhere else, menus and pop-ups included, the GUI pixel wins, so a menu opened on top of the waterfall
// simply covers it with no alpha plane in memory. Alpha blending is the other kind of overlay: a color is mixed into the
// picture with a weight alpha between 0 (invisible) and 1 (fully opaque), out = base + (color - base) x alpha. The
// receiver passbands use it, with alpha in sixteenths (0 to 16), to show a translucent band over the spectrum.
// A window is a rectangle set by registers, up to four of them, each a spectrum trace (a line of level against frequency
// with the area below it filled) or, for windows 0 and 1, a waterfall (one color index per pixel from DDR3, turned into
// a color by a 256-entry palette).
//
// THE RULES, FOR EACH PIXEL (docs/V2_COMPOSITOR.md section 3; the reference model in sim/video/tb_compositor.v follows the
// same text):
//   1. The lowest-numbered enabled window containing the pixel is "the window".
//   2. Outside every window, or where the GUI pixel is not the key color: the GUI pixel (RGB565 widened to RGB888 by
//      repeating the top bits, so 5'b11111 becomes 8'hFF).
//   3. Otherwise the FPGA layer of the window: for a trace window the background color, or the fill color below the trace;
//      for a waterfall window the palette color of the line buffer byte.
//   4. On top of that: grid lines, then the first passband that covers the pixel (blended), then the trace line, then the
//      cursor.
//   5. With the compositor disabled (cfg enable = 0): eight color bars instead of all of it, so that a picture exists
//      before the firmware has drawn its first frame. Outside the visible area the pixel is black.
//
// HOW IT RUNS: A PIPELINE
// The work per pixel (window compares, memory reads, subtractions, four multiplications, color mixing) is too much for one
// pixel clock of 13.5 ns, so it is cut into LAT = 31 register stages, each doing about four logic levels, and every pixel passes
// through all of them one clock at a time. The module has its own position counters (px, py) that run LAT clocks ahead of
// the HDMI core's (cx, cy): they are re-aligned to (cx, cy) once per frame, and the pixel for (px, py) comes out of the last
// stage LAT clocks later, exactly in the clock the HDMI core asks for it. A testbench checks this at every pixel. There
// are no resets and almost no clock enables, only registers in a line (the exceptions are the grid counters and the frame
// toggles). Reading a block RAM takes a clock, which is why an address goes out several stages before its data is needed.
//
// Per stage (S0 = the px, py counters; a signal of stage N has the suffix _N):
//   S1  window and passband range compares, coordinates relative to each window, GUI line buffer address
//   S2  in-window flags (and grid counters); GUI line buffer read
//   S3  window select (priority); GUI read data register
//   S4  select the window's parameters; pick the GUI pixel out of its 64-bit word; passband window mask
//   S5  source column; passband priority; key compare
//   S6  address of the spectrum snapshot or the waterfall line buffer
//   S7  line buffer read data
//   S8  level and waterfall word registered
//   S9  level difference; waterfall byte select
//   S10 clamp; palette address
//   S11 multiplier input registers; palette read
//   S12 multiplier; S13 multiplier output register; S14 one more register
//   S15 compare with the window height; S16 trace row; S17 to S19 range of trace rows (this and the previous column)
//   S20 row compares; S21 trace line and fill flags
//   S22 base color; S23 grid; S24 passband color; S25 color difference; S26 and S27 multiplier; S28 blend
//   S29 trace line; S30 cursor; S31 key mux and color bars -> rgb
//
// GOWIN POINTS: three multipliers of 9 x 6 bits for the passband blend and one of 16 x 16 for the trace row are inferred
// as DSP multipliers (there are registers before and after each, which the DSP block can absorb); all line buffers and the palette are block RAM (SDPB mode, registered
// read), with a one-clock read delay that the pipeline accounts for. The module carries the attribute syn_maxfan = 10000, which
// leaves the fan-out of every net as it is; where a signal needs copies they are made by hand.

`timescale 1ns / 1ps
`include "rtl/video/compositor_cfg.vh"

module compositor_pix #(
    parameter integer W    = 1920,     // visible pixels per line, a multiple of 8 and at most 2,040
    parameter integer H    = 1080,  // visible lines per frame
    parameter integer FW   = 2200,     // total pixels per line, as the HDMI core counts them (2200 for 1080p)
    parameter integer FH   = 1125,  // total lines per frame (1125 for 1080p)
    parameter integer VCAP = 1082,     // line at which the description for the next frame is requested, inside the vertical blanking (the visible lines are 0 to 1079)
    parameter integer ZOOM = 0         // 1 = the spectrum snapshot holds a zoom line as well as the full-band line
) (
    input  wire                 clk,  // pixel clock, 74.17 MHz
    input  wire [11:0]          cx,  // column the HDMI core is asking for, 0 to 2199
    input  wire [10:0]          cy,  // line the HDMI core is asking for, 0 to 1124
    input  wire [`CF_W-1:0]     cfg,  // picture description in the pixel clock (compositor_cfg.vh)
    // line buffer read ports (the memories are in compositor.v; each read data input is registered in the RAM, valid one clock
    // after its address)
    output reg  [9:0]           sl_ra,  // GUI line buffer word address: {line parity, word 8:0}; a word holds four 16-bit pixels
    input  wire [63:0]          sl_rd,  // GUI line buffer word, 64 bits; pixel 4k+j is in bits 16j+15:16j
    output reg  [ZOOM+10:0]     sp_ra,  // spectrum snapshot address: {zoom select (only with ZOOM), source column 10:0}
    input  wire [15:0]          sp_rd,  // spectrum level of that column, signed 16 bits in 1/64 dB
    output reg  [9:0]           wf_ra,       // waterfall line buffer address: {window, line parity, word 7:0}; one memory holds both windows' lines
    input  wire [63:0]          wf_rd,  // waterfall line buffer word: 8 pixels of one byte each, column 0 of the word in the top byte
    output reg  [8:0]           pal_ra,  // palette address: {window, color index 7:0}
    input  wire [23:0]          pal_rd,  // palette color, 24 bits {red, green, blue}
    // picture out
    output reg  [23:0]          rgb,  // the pixel for (cx, cy), valid in the same clock; black outside the visible area
    // frame control, toggles and gray codes that cross to the clk_dsp side (compositor.v synchronizes them)
    output reg                  cap_tog,        // toggles at line VCAP: asks the register file for a new picture description
    input  wire                 load,           // one clk_pix pulse: `cfg` takes the new description (after the clk_dsp side has acknowledged)
    output reg                  fs_tog,         // toggles at the first pixel of the frame, becomes the frame-start interrupt
    output reg  [10:0]          cy_gray,        // gray code of cy, for the fetch engine's target line
    input  wire [10:0]          done_gray,      // gray code of the last line completely fetched, already through synchronizing registers
    output reg                  ur_tog          // toggles once for every displayed line that was not completely fetched in time
) /* synthesis syn_maxfan = 10000 */;

// LAT: number of register stages from the position counters to `rgb`, the delay of the whole pipeline in clocks. BARW: width
// of one color bar in pixels, 1,920 / 8 = 240.
    localparam integer LAT = 31;
    localparam integer BARW = W / 8;

// ------------------------------------------------------------------------ config unpack
// The fields of `cfg` that are used in more than one stage or in a single wide piece. The per-window and per-passband
// fields are picked out where they are used.
    // ------------------------------------------------------------------------ config unpack
    wire [3:0]  c_wen = cfg[`CF_WEN_L +: 4];
    wire [3:0]  c_wf  = cfg[`CF_WF_L +: 4];
    wire [3:0]  c_wz  = cfg[`CF_WZ_L +: 4];
    wire [23:0] c_bg    = cfg[`CF_CBG_L +: 24];
    wire [23:0] c_fill  = cfg[`CF_CFILL_L +: 24];
    wire [23:0] c_trace = cfg[`CF_CTRACE_L +: 24];
    wire [23:0] c_grid  = cfg[`CF_CGRID_L +: 24];
    wire [15:0] c_key   = cfg[`CF_KEY_L +: 16];
    wire        c_en    = cfg[`CF_EN_L];
    wire        c_curen = cfg[`CF_CUREN_L];
    wire [3:0]  c_curwm = cfg[`CF_CURWM_L +: 4];
    wire [11:0] c_curx  = cfg[`CF_CURX_L +: 12];
    wire [11:0] c_curxe = cfg[`CF_CURXE_L +: 12];
    wire [23:0] c_curcol = cfg[`CF_CURCOL_L +: 24];
    wire [7:0]  c_pben  = cfg[`CF_PBEN_L +: 8];

    // ------------------------------------------------------------------------ S0: counters
    // Frame alignment: the HDMI core's position (0, 0) is seen by two registered compares (e_cx0, e_cy0) and a third register
    // (trig), which is high two clocks after that position was shown. At that moment px is loaded with 3 + LAT, so that
    // from there px runs LAT clocks ahead of cx. The same compare of cx with 0 and of cy with VCAP gives `trig_cap`, and
    // the frame-start and capture toggles flip on these pulses.
    reg e_cx0 = 1'b0, e_cy0 = 1'b0, e_cycap = 1'b0, trig = 1'b0, trig_cap = 1'b0;
    always @(posedge clk) begin
        e_cx0   <= (cx == 12'd0);
        e_cy0   <= (cy == 11'd0);
        e_cycap <= (cy == VCAP);
        trig     <= e_cx0 & e_cy0;
        trig_cap <= e_cx0 & e_cycap;
        if (trig)     fs_tog  <= ~fs_tog;
        if (trig_cap) cap_tog <= ~cap_tog;
        cy_gray <= cy ^ {1'b0, cy[10:1]};
    end
    initial begin fs_tog = 1'b0; cap_tog = 1'b0; cy_gray = 11'd0; end

    // px counts 0 to FW - 1 across the line and py the lines 0 to FH - 1; wrap_q is the found-one-clock-ahead flag that
    // px is on the last pixel of the line, so that the wrap is a registered signal.
    reg [11:0] px = 12'd0;
    reg [10:0] py = 11'd0;
    reg wrap_q = 1'b0;                  // px == FW - 1 in this clock, found one clock ahead
    always @(posedge clk) wrap_q <= trig ? 1'b0 : (px == FW - 2);
    always @(posedge clk) begin
        if (trig) begin
            px <= 12'd3 + LAT;
            py <= 11'd0;
        end else if (wrap_q) begin
            px <= 12'd0;
            py <= (py == FH - 1) ? 11'd0 : py + 11'd1;
        end else begin
            px <= px + 12'd1;
        end
    end

    // Underrun check at the start of every displayed line (px == 1, when py_gray has settled): if the line the fetch engine
    // has completed is not this one, the line is late, and ur_tog flips. Only with the compositor enabled.
    reg [10:0] py_gray = 11'd0;
    reg        chk = 1'b0;
    initial ur_tog = 1'b0;
    always @(posedge clk) begin
        py_gray <= py ^ {1'b0, py[10:1]};
        chk     <= (px == 12'd1) && (py < H) && c_en;
        if (chk && (done_gray != py_gray)) ur_tog <= ~ur_tog;
    end

    // ------------------------------------------------------------------------ S1
    reg [3:0]  ge_x1 = 4'd0, lt_x1 = 4'd0, ge_y1 = 4'd0, lt_y1 = 4'd0;
    reg [47:0] relx1 = 48'd0;
    reg [43:0] rely1 = 44'd0;
    reg [7:0]  pbge1 = 8'd0, pblt1 = 8'd0;
    reg        cge1 = 1'b0, clt1 = 1'b0, actv1 = 1'b0;
    reg [1:0]  px1_10 = 2'd0;
    reg        py1_0 = 1'b0;
    reg [6:0]  thermo1 = 7'd0;

    // The window and passband edges that stage S1 compares the position with, and the first vertical grid line, come out of
    // a register of their own, one clock after `cfg`. `cfg` is a frame copy loaded in the vertical blank and stands for about
    // 40 lines before the first displayed line, and its registers sit near the clk_dsp side of the chip, so the way from
    // `cfg` to the comparators was long; one more register makes it short.
    reg [`CF_WX_W-1:0]   q_wx  = 0;
    reg [`CF_WXE_W-1:0]  q_wxe = 0;
    reg [`CF_WY_W-1:0]   q_wy  = 0;
    reg [`CF_WYE_W-1:0]  q_wye = 0;
    reg [`CF_PBX0_W-1:0] q_pbx0 = 0;
    reg [`CF_PBX1_W-1:0] q_pbx1 = 0;
    reg [`CF_WGXF_W-1:0] q_gxf = 0;
    always @(posedge clk) begin
        q_wx   <= cfg[`CF_WX_L   +: `CF_WX_W];
        q_wxe  <= cfg[`CF_WXE_L  +: `CF_WXE_W];
        q_wy   <= cfg[`CF_WY_L   +: `CF_WY_W];
        q_wye  <= cfg[`CF_WYE_L  +: `CF_WYE_W];
        q_pbx0 <= cfg[`CF_PBX0_L +: `CF_PBX0_W];
        q_pbx1 <= cfg[`CF_PBX1_L +: `CF_PBX1_W];
        q_gxf  <= cfg[`CF_WGXF_L +: `CF_WGXF_W];
    end

    // Compares of the position against every window rectangle (in both directions, >= first and < one past the last) and
    // against every passband's column range, and the position relative to each window's top left corner.
    genvar i, k;
    generate
        for (i = 0; i < 4; i = i + 1) begin : s1w
            wire [11:0] wx  = q_wx [12*i +: 12];
            wire [11:0] wxe = q_wxe[12*i +: 12];
            wire [10:0] wy  = q_wy [11*i +: 11];
            wire [10:0] wye = q_wye[11*i +: 11];
            always @(posedge clk) begin
                ge_x1[i] <= (px >= wx);
                lt_x1[i] <= (px <  wxe);
                ge_y1[i] <= (py >= wy);
                lt_y1[i] <= (py <  wye);
                relx1[12*i +: 12] <= px - wx;
                rely1[11*i +: 11] <= py - wy;
            end
        end
        for (k = 0; k < 8; k = k + 1) begin : s1p
            wire [11:0] x0 = q_pbx0[12*k +: 12];
            wire [11:0] x1 = q_pbx1[12*k +: 12];
            always @(posedge clk) begin
                pbge1[k] <= (px >= x0);
                pblt1[k] <= (px <  x1);
            end
        end
        // eight color bars: one comparison per bar boundary (thermometer code), which S2 turns into the bar number
        for (k = 1; k < 8; k = k + 1) begin : s1b
            always @(posedge clk) thermo1[k-1] <= (px >= k * BARW);
        end
    endgenerate
    // the cursor's column range, "inside the picture" flag, the two low bits of px (which of the 4 pixels of a GUI word)
    // and the low bit of py (line parity), and the GUI line buffer address
    always @(posedge clk) begin
        cge1   <= (px >= c_curx);
        clt1   <= (px <  c_curxe);
        actv1  <= (px < W) && (py < H);
        px1_10 <= px[1:0];
        py1_0  <= py[0];
        sl_ra  <= {py[0], px[10:2]};
    end

    // ------------------------------------------------------------------------ S2
    // A pixel is inside window i when the window is enabled and px, py are in its rectangle; likewise for passbands and the
    // cursor. The bar number follows from the thermometer code.
    // ------------------------------------------------------------------------ S2
    reg [3:0]  in_w2 = 4'd0, iny2 = 4'd0;
    reg [7:0]  pbin2 = 8'd0;
    reg        cin2 = 1'b0, actv2 = 1'b0;
    reg [47:0] relx2 = 48'd0;
    reg [43:0] rely2 = 44'd0;
    reg [1:0]  px2_10 = 2'd0;
    reg        py2_0 = 1'b0;
    reg [2:0]  bar2 = 3'd0;
    always @(posedge clk) begin
        in_w2 <= c_wen & ge_x1 & lt_x1 & ge_y1 & lt_y1;
        iny2  <= ge_y1 & lt_y1;
        pbin2 <= c_pben & pbge1 & pblt1;
        cin2  <= c_curen & cge1 & clt1;
        actv2 <= actv1;
        relx2 <= relx1;
        rely2 <= rely1;
        px2_10 <= px1_10;
        py2_0  <= py1_0;
        bar2 <= thermo1[6] ? 3'd7 : thermo1[5] ? 3'd6 : thermo1[4] ? 3'd5 : thermo1[3] ? 3'd4 :
                thermo1[2] ? 3'd3 : thermo1[1] ? 3'd2 : thermo1[0] ? 3'd1 : 3'd0;
    end
    // The GUI line buffer's registered read data `sl_rd` is the word for sl_ra of S1, valid in S2.
    //
    // Grid counters (S2 to S3), one pair per window. A grid is a line every `step` pixels starting at `first`. Vertical lines
    // (x) use a down counter that advances every pixel inside the window; the flag gxz says "the counter is at zero, so this
    // pixel is on a line", and after zero the counter reloads with step - 1. At the first pixel of a row the counter is
    // reloaded with `first`. Horizontal lines (y) advance once per row at the window's first pixel of the row, in the same
    // way, and the flag gyz is high for all pixels of such a row. A step of 0 switches that grid off.
    reg [3:0] inw_d = 4'd0;
    reg [47:0] gxc = 48'd0;
    reg [3:0]  gxz = 4'd0;
    reg [47:0] gyc = 48'd0;
    reg [3:0]  gyz = 4'd0;
    reg [47:0] gxsm1 = 48'd0, gysm1 = 48'd0;
    reg [3:0]  gxsm1_z = 4'd0, gysm1_z = 4'd0, gxf_z = 4'd0, gyf_z = 4'd0, gxen = 4'd0, gyen = 4'd0;
    always @(posedge clk) inw_d <= in_w2;
    generate
        for (i = 0; i < 4; i = i + 1) begin : grid
            wire [11:0] gxf = q_gxf[12*i +: 12];
            wire [11:0] gxs = cfg[`CF_WGXS_L + 12*i +: 12];
            wire [11:0] gyf = cfg[`CF_WGYF_L + 12*i +: 12];
            wire [11:0] gys = cfg[`CF_WGYS_L + 12*i +: 12];
            wire first = in_w2[i] & ~inw_d[i];
            wire rely_z = (rely2[11*i +: 11] == 11'd0);
            always @(posedge clk) begin
                gxsm1[12*i +: 12] <= gxs - 12'd1;
                gysm1[12*i +: 12] <= gys - 12'd1;
                gxsm1_z[i] <= (gxs <= 12'd1);
                gysm1_z[i] <= (gys <= 12'd1);
                gxf_z[i]   <= (gxf == 12'd0);
                gyf_z[i]   <= (gyf == 12'd0);
                gxen[i]    <= (gxs != 12'd0);
                gyen[i]    <= (gys != 12'd0);
                if (in_w2[i]) begin
                    if (first) begin
                        gxc[12*i +: 12] <= gxf;
                        gxz[i]          <= gxf_z[i];
                    end else if (gxz[i]) begin
                        gxc[12*i +: 12] <= gxsm1[12*i +: 12];
                        gxz[i]          <= gxsm1_z[i];
                    end else begin
                        gxc[12*i +: 12] <= gxc[12*i +: 12] - 12'd1;
                        gxz[i]          <= (gxc[12*i +: 12] == 12'd1);
                    end
                    if (first) begin
                        if (rely_z) begin
                            gyc[12*i +: 12] <= gyf;
                            gyz[i]          <= gyf_z[i];
                        end else if (gyz[i]) begin
                            gyc[12*i +: 12] <= gysm1[12*i +: 12];
                            gyz[i]          <= gysm1_z[i];
                        end else begin
                            gyc[12*i +: 12] <= gyc[12*i +: 12] - 12'd1;
                            gyz[i]          <= (gyc[12*i +: 12] == 12'd1);
                        end
                    end
                end
            end
        end
    endgenerate

    // ------------------------------------------------------------------------ S3
    // Window select, a priority encoder: window 0 wins over 1, 2 and 3. The GUI word is registered here.
    // ------------------------------------------------------------------------ S3
    reg        w_any3 = 1'b0;
    reg [1:0]  w_sel3 = 2'd0;
    reg [7:0]  pbin3 = 8'd0;
    reg        cin3 = 1'b0, actv3 = 1'b0;
    reg [47:0] relx3 = 48'd0;
    reg [43:0] rely3 = 44'd0;
    reg [1:0]  px3_10 = 2'd0;
    reg        py3_0 = 1'b0;
    reg [2:0]  bar3 = 3'd0;
    reg [63:0] sl_q3 = 64'd0;
    always @(posedge clk) begin
        w_any3 <= |in_w2;
        w_sel3 <= in_w2[0] ? 2'd0 : in_w2[1] ? 2'd1 : in_w2[2] ? 2'd2 : 2'd3;
        pbin3  <= pbin2;
        cin3   <= cin2;
        actv3  <= actv2;
        relx3  <= relx2;
        rely3  <= rely2;
        px3_10 <= px2_10;
        py3_0  <= py2_0;
        bar3   <= bar2;
        sl_q3  <= sl_rd;
    end

    // ------------------------------------------------------------------------ S4
    // ------------------------------------------------------------------------ S4
    reg        w_any4 = 1'b0, pwf4 = 1'b0, pzoom4 = 1'b0, cin4 = 1'b0, actv4 = 1'b0, gx4 = 1'b0, gy4 = 1'b0;
    reg [1:0]  w_sel4 = 2'd0;
    reg [11:0] relx_sel4 = 12'd0, psx0_4 = 12'd0;
    reg [10:0] rely_sel4 = 11'd0, phm1_4 = 11'd0;
    reg [15:0] pref4 = 16'd0, pgain4 = 16'd0;
    reg [7:0]  pbin4 = 8'd0;
    reg [15:0] s16_4 = 16'd0;
    reg [2:0]  bar4 = 3'd0;
    reg        py4_0 = 1'b0;
    // The selected window's values are chosen by a case with constant offsets (a multiplication in a part-select index costs
    // logic levels): relative column and row, source column offset and window height minus 1.
    reg [11:0] relx_m, psx0_m;
    reg [10:0] rely_m, phm1_m;
    always @* begin
        case (w_sel3)
            2'd0: begin relx_m = relx3[11:0];  rely_m = rely3[10:0];  psx0_m = cfg[`CF_WSX0_L +  0 +: 12]; phm1_m = cfg[`CF_WHM1_L +  0 +: 11]; end
            2'd1: begin relx_m = relx3[23:12]; rely_m = rely3[21:11]; psx0_m = cfg[`CF_WSX0_L + 12 +: 12]; phm1_m = cfg[`CF_WHM1_L + 11 +: 11]; end
            2'd2: begin relx_m = relx3[35:24]; rely_m = rely3[32:22]; psx0_m = cfg[`CF_WSX0_L + 24 +: 12]; phm1_m = cfg[`CF_WHM1_L + 22 +: 11]; end
            default: begin relx_m = relx3[47:36]; rely_m = rely3[43:33]; psx0_m = cfg[`CF_WSX0_L + 36 +: 12]; phm1_m = cfg[`CF_WHM1_L + 33 +: 11]; end
        endcase
    end
    // Select the window's parameters and the grid flags, pick the 16-bit GUI pixel out of the 64-bit word with the two low
    // bits of px, and keep the cursor flag only for windows that the cursor is drawn in.
    always @(posedge clk) begin
        w_any4    <= w_any3;
        w_sel4    <= w_sel3;
        relx_sel4 <= relx_m;
        rely_sel4 <= rely_m;
        pwf4      <= c_wf[w_sel3];
        pzoom4    <= c_wz[w_sel3];
        psx0_4    <= psx0_m;
        phm1_4    <= phm1_m;
        pref4     <= cfg[`CF_WREF_L + 16*w_sel3 +: 16];
        pgain4    <= cfg[`CF_WGAIN_L + 16*w_sel3 +: 16];
        gx4       <= gxz[w_sel3] & gxen[w_sel3];
        gy4       <= gyz[w_sel3] & gyen[w_sel3];
        cin4      <= cin3 & c_curwm[w_sel3];
        actv4     <= actv3;
        bar4      <= bar3;
        py4_0     <= py3_0;
        s16_4     <= sl_q3[16*px3_10 +: 16];
    end
    // A passband counts for a pixel only if it is also meant for the selected window (its window mask).
    generate
        for (k = 0; k < 8; k = k + 1) begin : s4p
            wire [3:0] wm = cfg[`CF_PBWM_L + 4*k +: 4];
            always @(posedge clk) pbin4[k] <= pbin3[k] & wm[w_sel3];
        end
    endgenerate

    // ------------------------------------------------------------------------ S5
    // c5 is the source column: the window's relative column plus its source column offset. Then the key compare (is the GUI
    // pixel the key color), the passband priority encoder (the lowest-numbered passband wins, no stacking) and the grid flag
    // (horizontal lines are not drawn in waterfall windows).
    // ------------------------------------------------------------------------ S5
    reg [11:0] c5 = 12'd0;
    reg        first5 = 1'b0, pwf5 = 1'b0, pzoom5 = 1'b0, grid5 = 1'b0, cin5 = 1'b0, actv5 = 1'b0,
               w_any5 = 1'b0, w_sel5 = 1'b0, pbany5 = 1'b0, iskey5 = 1'b0, py5_0 = 1'b0;
    reg [10:0] rely5 = 11'd0, phm1_5 = 11'd0;
    reg [15:0] pref5 = 16'd0, pgain5 = 16'd0, s16_5 = 16'd0;
    reg [2:0]  pbidx5 = 3'd0, bar5 = 3'd0;
    always @(posedge clk) begin
        c5     <= relx_sel4 + psx0_4;
        first5 <= (relx_sel4 == 12'd0);
        pwf5   <= pwf4;
        pzoom5 <= pzoom4;
        grid5  <= gx4 | (gy4 & ~pwf4);
        cin5   <= cin4;
        actv5  <= actv4;
        w_any5 <= w_any4;
        w_sel5 <= w_sel4[0];
        rely5  <= rely_sel4;
        phm1_5 <= phm1_4;
        pref5  <= pref4;
        pgain5 <= pgain4;
        s16_5  <= s16_4;
        iskey5 <= (s16_4 == c_key);
        bar5   <= bar4;
        py5_0  <= py4_0;
        pbany5 <= |pbin4;
        pbidx5 <= pbin4[0] ? 3'd0 : pbin4[1] ? 3'd1 : pbin4[2] ? 3'd2 : pbin4[3] ? 3'd3 :
                  pbin4[4] ? 3'd4 : pbin4[5] ? 3'd5 : pbin4[6] ? 3'd6 : 3'd7;
    end

    // ------------------------------------------------------------------------ S6: memory addresses
    // The spectrum snapshot is read at the source column; the waterfall line buffer at {window, line parity, column / 8}
    // (the 3 low bits of the column pick the byte later).
    // ------------------------------------------------------------------------ S6: memory addresses
    reg [2:0]  c6_20 = 3'd0;
    reg        w_sel6 = 1'b0;
    always @(posedge clk) begin
        sp_ra  <= {pzoom5 & (ZOOM != 0), c5[10:0]};
        wf_ra  <= {w_sel5, py5_0, c5[10:3]};
        c6_20  <= c5[2:0];
        w_sel6 <= w_sel5;
    end

    // S7: sp_rd and wf_rd are the memories' registered read data (valid in S7)
    reg [2:0]  c7_20 = 3'd0;
    reg        w_sel7 = 1'b0;
    always @(posedge clk) begin
        c7_20  <= c6_20;
        w_sel7 <= w_sel6;
    end

    // ------------------------------------------------------------------------ S8..S21: trace and waterfall
    // Values that are known at S5 and needed later go through delays (comp_dly, compositor_util.v); the number is the stage
    // difference, so that the value arrives in the same clock as the data it belongs to.
    wire [10:0] rely_19;
    wire [10:0] phm1_14, phm1_15;
    wire [15:0] pref_8, pgain_10;
    wire        first_16;
    comp_dly #(.W(11), .N(14)) d_rely (.clk(clk), .d(rely5), .q(rely_19));          // S5 -> S19
    comp_dly #(.W(11), .N(9))  d_hm1  (.clk(clk), .d(phm1_5), .q(phm1_14));         // S5 -> S14
    comp_dly #(.W(16), .N(3))  d_ref  (.clk(clk), .d(pref5), .q(pref_8));           // S5 -> S8
    comp_dly #(.W(16), .N(5))  d_gain (.clk(clk), .d(pgain5), .q(pgain_10));        // S5 -> S10
    comp_dly #(.W(1),  .N(11)) d_first(.clk(clk), .d(first5), .q(first_16));        // S5 -> S16
    comp_dly #(.W(11), .N(1))  d_hm1b (.clk(clk), .d(phm1_14), .q(phm1_15));        // S14 -> S15

    // S8: the read data are registered (level of the column, 8 waterfall pixels)
    reg [15:0] v8 = 16'd0;
    reg [63:0] w64_8 = 64'd0;
    reg [2:0]  c8_20 = 3'd0;
    reg        w_sel8 = 1'b0;
    always @(posedge clk) begin
        v8     <= sp_rd;
        w64_8  <= wf_rd;
        c8_20  <= c7_20;
        w_sel8 <= w_sel7;
    end

    // S9: level difference ref - level (17 bits signed; positive = the level is below the top of the window) and the byte of
    // the waterfall word (column 0 of a word is its top byte)
    reg signed [16:0] d17_9 = 17'sd0;
    reg [7:0]  byte9 = 8'd0;
    reg        w_sel9 = 1'b0;
    always @(posedge clk) begin
        d17_9  <= {pref_8[15], pref_8} - {v8[15], v8};
        byte9  <= w64_8[56 - 8*c8_20 +: 8];       // column 0 of a word is its top byte
        w_sel9 <= w_sel8;
    end

    // S10: negative differences (the level is above the top row) are clamped to 0, and the palette address is {window, byte}
    reg [15:0] dpos10 = 16'd0;
    always @(posedge clk) begin
        dpos10 <= d17_9[16] ? 16'd0 : d17_9[15:0];
        pal_ra <= {w_sel9, byte9};
    end

    // S11 (multiplier input registers); pal_rd valid
    reg [15:0] a11 = 16'd0, g11 = 16'd0;
    always @(posedge clk) begin
        a11 <= dpos10;
        g11 <= pgain_10;
    end

    // S11 multiplier input registers; palette data valid. S12: the multiplier (a DSP block) forms (ref - level) x gain, S13
    // is its output register.
    reg [31:0] prod12 = 32'd0, prod13 = 32'd0;
    reg [23:0] palc12 = 24'd0;
    always @(posedge clk) begin
        prod12 <= a11 * g11;
        prod13 <= prod12;
        palc12 <= pal_rd;
    end

    // S14: one more register behind the multiplier (the block's output pins reach fabric through a register first)
    reg [31:0] prod14 = 32'd0;
    always @(posedge clk) prod14 <= prod13;

    // S15: row = (ref - level) x gain >> 14, clamped to the window height. The shift is 14 because the level is in 1/64 dB
    // (2^6) and the gain has 8 fraction bits (2^8): the product is 2^14 times the row number in pixels. gt15 is set when the
    // row is below the window's last row.
    reg        gt15 = 1'b0;
    reg [10:0] yq15 = 11'd0;
    always @(posedge clk) begin
        gt15 <= (prod14[31:14] > {7'd0, phm1_14});
        yq15 <= prod14[24:14];
    end
    // S16
    reg [10:0] yt16 = 11'd0;
    always @(posedge clk) yt16 <= gt15 ? phm1_15 : yq15;

    // S17: this column's row and the previous column's row (the previous is this one at the window's first column)
    reg [10:0] yt17 = 11'd0, ypv17 = 11'd0;
    always @(posedge clk) begin
        yt17  <= yt16;
        ypv17 <= first_16 ? yt16 : yt17;
    end
    // S18 and S19: the two rows put in order (min and max), because the trace line is drawn between them, which joins steep
    // slopes into one connected line instead of single dots
    reg        lt18 = 1'b0;
    reg [10:0] yt18 = 11'd0, ypv18 = 11'd0, ymin19 = 11'd0, ymax19 = 11'd0, yt19 = 11'd0;
    always @(posedge clk) begin
        lt18   <= (yt17 < ypv17);
        yt18   <= yt17;
        ypv18  <= ypv17;
        ymin19 <= lt18 ? yt18 : ypv18;
        ymax19 <= lt18 ? ypv18 : yt18;
        yt19   <= yt18;
    end
    // S20: compare the pixel's row with that range and with the trace row; S21: trace line flag (inside the range, trace
    // windows only) and fill flag (below the trace)
    reg gelo20 = 1'b0, lehi20 = 1'b0, below20 = 1'b0;
    wire pwf_20, w_any_20;
    comp_dly #(.W(1), .N(15)) d_pwf20 (.clk(clk), .d(pwf5),   .q(pwf_20));          // S5 -> S20
    comp_dly #(.W(1), .N(15)) d_any20 (.clk(clk), .d(w_any5), .q(w_any_20));
    reg tline21 = 1'b0, tfill21 = 1'b0;
    always @(posedge clk) begin
        gelo20  <= (rely_19 >= ymin19);
        lehi20  <= (rely_19 <= ymax19);
        below20 <= (rely_19 >  yt19);
        tline21 <= gelo20 & lehi20 & ~pwf_20 & w_any_20;
        tfill21 <= below20;
    end

    // ------------------------------------------------------------------------ S22..S31: composition
    // Delays again bring the flags of S5 (passband found, grid, cursor, window, key, bar number, the GUI pixel) to the stage
    // where they are used.
    wire        pwf_21, grid_22, cin_29, pbany_27, w_any_30, actv_30, iskey_30;
    wire [23:0] palc_21;
    wire [2:0]  pbidx_23, bar_30;
    wire [15:0] s16_30;
    comp_dly #(.W(24), .N(9))  d_palc (.clk(clk), .d(palc12),  .q(palc_21));        // S12 -> S21
    comp_dly #(.W(1),  .N(16)) d_pwf  (.clk(clk), .d(pwf5),    .q(pwf_21));         // S5 -> S21
    comp_dly #(.W(1),  .N(17)) d_grid (.clk(clk), .d(grid5),   .q(grid_22));        // S5 -> S22
    comp_dly #(.W(3),  .N(18)) d_pbix (.clk(clk), .d(pbidx5),  .q(pbidx_23));       // S5 -> S23
    comp_dly #(.W(1),  .N(22)) d_pbany(.clk(clk), .d(pbany5),  .q(pbany_27));       // S5 -> S27
    comp_dly #(.W(1),  .N(24)) d_cin  (.clk(clk), .d(cin5),    .q(cin_29));         // S5 -> S29
    comp_dly #(.W(1),  .N(25)) d_wany (.clk(clk), .d(w_any5),  .q(w_any_30));
    comp_dly #(.W(1),  .N(25)) d_actv (.clk(clk), .d(actv5),   .q(actv_30));
    comp_dly #(.W(1),  .N(25), .REG(1)) d_key  (.clk(clk), .d(iskey5),  .q(iskey_30));
    comp_dly #(.W(3),  .N(25)) d_bar  (.clk(clk), .d(bar5),    .q(bar_30));
    comp_dly #(.W(16), .N(25), .REG(1)) d_s16  (.clk(clk), .d(s16_5),   .q(s16_30));

    // S22: base color (waterfall palette color, or fill color below the trace, or background), S23: grid color over it
    reg [23:0] base22 = 24'd0, base23 = 24'd0;
    always @(posedge clk) begin
        base22 <= pwf_21 ? palc_21 : (tfill21 ? c_fill : c_bg);
        base23 <= grid_22 ? c_grid : base22;
    end

    // S24: the selected passband's color and alpha; S25: color minus base, per channel (9 bits signed); S26 and S27: times
    // alpha (3 multipliers); S28: blend = base + (difference x alpha) >> 4, rounded down, as the alpha is in sixteenths and
    // the product has four extra bits. Where no passband covers the pixel the base color goes through unchanged.
    reg [23:0] pbcol24 = 24'd0, base24 = 24'd0, base25 = 24'd0, base26 = 24'd0, base27 = 24'd0, bl28 = 24'd0;
    reg [4:0]  pbal24 = 5'd0, pbal25 = 5'd0;
    reg signed [8:0] dr25 = 9'sd0, dg25 = 9'sd0, db25 = 9'sd0;
    reg signed [14:0] pr26 = 15'sd0, pg26 = 15'sd0, pb26 = 15'sd0, pr27 = 15'sd0, pg27 = 15'sd0, pb27 = 15'sd0;
    // The 8:1 selection is written as a case: a variable part-select of the 192-bit vector builds a wide shifter that costs
    // thousands of logic cells.
    reg [23:0] pbcol_sel;
    reg [4:0]  pbal_sel;
    always @* begin
        case (pbidx_23)
            3'd0: begin pbcol_sel = cfg[`CF_PBCOL_L +  0 +: 24]; pbal_sel = cfg[`CF_PBAL_L +  0 +: 5]; end
            3'd1: begin pbcol_sel = cfg[`CF_PBCOL_L + 24 +: 24]; pbal_sel = cfg[`CF_PBAL_L +  5 +: 5]; end
            3'd2: begin pbcol_sel = cfg[`CF_PBCOL_L + 48 +: 24]; pbal_sel = cfg[`CF_PBAL_L + 10 +: 5]; end
            3'd3: begin pbcol_sel = cfg[`CF_PBCOL_L + 72 +: 24]; pbal_sel = cfg[`CF_PBAL_L + 15 +: 5]; end
            3'd4: begin pbcol_sel = cfg[`CF_PBCOL_L + 96 +: 24]; pbal_sel = cfg[`CF_PBAL_L + 20 +: 5]; end
            3'd5: begin pbcol_sel = cfg[`CF_PBCOL_L + 120 +: 24]; pbal_sel = cfg[`CF_PBAL_L + 25 +: 5]; end
            3'd6: begin pbcol_sel = cfg[`CF_PBCOL_L + 144 +: 24]; pbal_sel = cfg[`CF_PBAL_L + 30 +: 5]; end
            default: begin pbcol_sel = cfg[`CF_PBCOL_L + 168 +: 24]; pbal_sel = cfg[`CF_PBAL_L + 35 +: 5]; end
        endcase
    end
    always @(posedge clk) begin
        pbcol24 <= pbcol_sel;
        pbal24  <= pbal_sel;
        base24  <= base23;
        dr25 <= $signed({1'b0, pbcol24[23:16]}) - $signed({1'b0, base24[23:16]});
        dg25 <= $signed({1'b0, pbcol24[15:8]})  - $signed({1'b0, base24[15:8]});
        db25 <= $signed({1'b0, pbcol24[7:0]})   - $signed({1'b0, base24[7:0]});
        pbal25  <= pbal24;
        base25  <= base24;
        pr26 <= dr25 * $signed({1'b0, pbal25});
        pg26 <= dg25 * $signed({1'b0, pbal25});
        pb26 <= db25 * $signed({1'b0, pbal25});
        base26 <= base25;
        pr27 <= pr26;
        pg27 <= pg26;
        pb27 <= pb26;
        base27 <= base26;
        if (pbany_27)
            bl28 <= {base27[23:16] + pr27[11:4], base27[15:8] + pg27[11:4], base27[7:0] + pb27[11:4]};
        else
            bl28 <= base27;
    end

    // S29 trace line over it, S30 cursor over that, S31 final mux. The GUI pixel is converted from RGB565 to RGB888 by
    // repeating the top bits of every channel, and the color bars are the same eight colors as colorbar_gen.v.
    wire tline_28;
    comp_dly #(.W(1), .N(7)) d_tline (.clk(clk), .d(tline21), .q(tline_28));        // S21 -> S28
    reg [23:0] t29 = 24'd0, t30 = 24'd0;
    always @(posedge clk) begin
        t29 <= tline_28 ? c_trace : bl28;
        t30 <= cin_29 ? c_curcol : t29;
    end
    wire [23:0] s888_30 = {s16_30[15:11], s16_30[15:13], s16_30[10:5], s16_30[10:9], s16_30[4:0], s16_30[4:2]};
    reg [23:0] bars30;
    always @* begin
        case (bar_30)
            3'd0: bars30 = 24'hFFFFFF;
            3'd1: bars30 = 24'hFFFF00;
            3'd2: bars30 = 24'h00FFFF;
            3'd3: bars30 = 24'h00FF00;
            3'd4: bars30 = 24'hFF00FF;
            3'd5: bars30 = 24'hFF0000;
            3'd6: bars30 = 24'h0000FF;
            default: bars30 = 24'h000000;
        endcase
    end
    // The last stage: outside the visible area black; with the compositor disabled the color bars; inside a window on the
    // key color the FPGA layer (t30); everything else the GUI pixel.
    always @(posedge clk) begin
        if (!actv_30)                  rgb <= 24'h000000;
        else if (!c_en)                rgb <= bars30;
        else if (w_any_30 && iskey_30) rgb <= t30;
        else                           rgb <= s888_30;
    end

endmodule
