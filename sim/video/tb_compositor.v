// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Testbench for rtl/video/compositor.v (with its parts compositor_fetch.v, compositor_pix.v and
// compositor_util.v), the block that builds the picture the monitor shows. It reads the GUI's framebuffer
// (16-bit RGB565 pixels drawn by the firmware) and the waterfall lines from DDR3, draws the spectrum trace,
// the waterfalls, a grid, passband markers and a cursor in the FPGA, and mixes everything per pixel. The GUI
// reserves a "key" color (magenta, 0xF81F) for the places where it wants the FPGA's drawing to show
// through: wherever a window is configured and the GUI pixel has the key color, the FPGA layer is shown, and
// everywhere else the GUI pixel is shown unchanged (docs/V2_COMPOSITOR.md). See docs/learn/GLOSSARY.md for
// framebuffer, key color, vertical blank and waterfall.
//
// Setup: a small frame of 96 x 24 active pixels inside 240 x 30 in total, so the test is quick and one video
// line takes 240 pixel clocks (the real line takes 2,200). The real compositor is connected to the real
// ddr3_read_arbiter.v (only the video tier in use) and to the behavioral lane model
// sim/ddr3/ddr3_lane_behav_model.v with 6 clocks of read latency, which holds two framebuffers of random
// pixels and two waterfall rings of random bytes. Two clocks run at slightly different rates, about 150 MHz
// for the register and fetch side (`clk`) and 148.5 MHz for the pixel side (`clk_pix`), so the clock domain
// crossings in the compositor get exercised. The real DSP clock is 120 MHz (docs/ARCHITECTURE.md section 2),
// so this ratio is friendlier than the one in the radio.
//
// What the test covers:
//   - the register file and its read back,
//   - the GUI layer from the framebuffer (two buffers, random pixels, the key color inside the windows with
//     a few real pixels on top of it),
//   - two waterfall windows with a palette, a source offset, each with its own ring and its own scroll line:
//     window 0 first follows the full-band hardware writer and later the zoom writer, window 1 follows a line
//     the CPU writes, in a second ring and later in the first ring,
//   - two trace windows (scale, clamp at the top, source offset), one showing the full-band spectrum line and
//     one the zoom spectrum line, plus the grid, three passbands (priority, alpha blend, window mask) and the
//     cursor,
//   - the picture description changes only in the vertical blank: registers written in the middle of a
//     frame show up in the next frame, a framebuffer swap included,
//   - every pixel of every compared frame is equal to the reference model written below, which is built from
//     the specification (docs/V2_COMPOSITOR.md section 3) and the register words alone and does not look at
//     the compositor's internals,
//   - an underrun (the lane held off for two lines) is counted, shows in the status register, stops nothing,
//     and the frame after it is exact again.
//
// Passing: zero mismatching pixels and no failed register check, with more than five frames' worth of pixels
// compared. The testbench prints the first 12 mismatches (frame, position, got and expected color), a line
// with the pixel counts per layer (to show every feature was actually on screen), a line with the pixels
// compared, errors and stall underruns, and then "PASS" or "FAIL", or "FAIL: timeout" after 3 ms of simulated
// time. Run it from the repository root, the include paths are relative to it:
//   iverilog -g2012 -o build/tb_compositor.vvp sim/video/tb_compositor.v && vvp build/tb_compositor.vvp
// or all testbenches together with tools/check.sh.

`timescale 1ns / 1ps
// The generated register map of the video page: addresses, field positions and reset values used below.
`include "hw/regmap/generated/video_regs.vh"
`include "rtl/video/compositor_util.v"
`include "rtl/video/compositor_fetch.v"
`include "rtl/video/compositor_pix.v"
`include "rtl/video/compositor.v"
`include "rtl/ddr3/ddr3_read_arbiter.v"
`include "sim/ddr3/ddr3_lane_behav_model.v"

module tb_compositor;
    // Active picture W x H, total frame FW x FH. VCAP is the line at which the compositor captures the
    // description for the next frame, a little below the last active line (24).
    localparam integer W = 96, H = 24, FW = 240, FH = 30, VCAP = 26;
    // BARW is the width of one color bar of the test pattern shown while the picture is off, 12 pixels.
    localparam integer BARW = W / 8;
    // Framebuffer base addresses in bytes (two buffers, swapped to test the double buffering) and the stride
    // of one framebuffer line in bytes: 96 pixels at 2 bytes each.
    localparam [31:0] FB_A = 32'h0000_8000, FB_B = 32'h0001_0000, STRIDE = 2 * W;
    localparam [31:0] RING = 32'd20000;                  // lane word address of line 0 of the first waterfall ring
    localparam [31:0] RING1 = 32'd32000;                 // and of the second

    // `clk` (half period 3.333 ns, about 150 MHz) runs the registers and the fetch engine, `clk_pix`
    // (half period 3.367 ns, about 148.5 MHz) the pixel side.
    reg clk = 1'b0, clk_pix = 1'b0, rst = 1'b1;
    always #3.333 clk = ~clk;
    always #3.367 clk_pix = ~clk_pix;

    // ---------------------------------------------------------------- video timing (like hdmi.sv)
    reg [11:0] cx = 12'd0;
    reg [10:0] cy = 11'd0;
    integer frame_n = 0;
    always @(posedge clk_pix) begin
        cx <= (cx == FW - 1) ? 12'd0 : cx + 12'd1;
        if (cx == FW - 1) begin
            cy <= (cy == FH - 1) ? 11'd0 : cy + 11'd1;
            if (cy == FH - 1) frame_n <= frame_n + 1;
        end
    end

    // ---------------------------------------------------------------- DUT, arbiter, lane model
    reg         bus_wr = 1'b0, bus_rd = 1'b0;
    reg  [15:0] bus_addr = 16'd0;
    reg  [31:0] bus_wdata = 32'd0;
    wire [31:0] bus_rdata;
    wire        vr_req, vr_gnt, vr_rvalid, vr_done;
    wire [31:0] vr_addr;
    wire [7:0]  vr_burst;
    wire [63:0] vr_rdata;
    wire [10:0] line_rd_addr, zline_rd_addr;
    reg  [15:0] line_rd_data = 16'd0, zline_rd_data = 16'd0;
    wire [23:0] rgb;
    wire [31:0] wf_ring_base;
    reg  [10:0] wf_write_line = 11'd20;
    reg  [10:0] zwf_write_line = 11'd31;
    wire        frame_start;

    // The compositor under test, built for the small frame, with the zoom spectrum snapshot enabled.
    compositor #(.W(W), .H(H), .FW(FW), .FH(FH), .VCAP(VCAP), .ZOOM_SNAP(1)) dut (
        .clk(clk), .rst(rst), .clk_pix(clk_pix), .cx(cx), .cy(cy), .rgb(rgb),
        .bus_wr(bus_wr), .bus_rd(bus_rd), .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
        .rd_req(vr_req), .rd_addr(vr_addr), .rd_burstlen(vr_burst), .rd_gnt(vr_gnt),
        .rd_rvalid(vr_rvalid), .rd_rdata(vr_rdata), .rd_done(vr_done),
        .line_rd_addr(line_rd_addr), .line_rd_data(line_rd_data),
        .zline_rd_addr(zline_rd_addr), .zline_rd_data(zline_rd_data),
        .wf_ring_base(wf_ring_base), .wf_write_line(wf_write_line),
        .zwf_ring_base(), .zwf_write_line(zwf_write_line), .frame_start(frame_start)
    );

    wire [31:0] addr5;
    wire        en5, go5, rdy5_m, valid5;
    wire [7:0]  bc5;
    wire [63:0] data5;
    reg         force_stall = 1'b0;
    // The real read arbiter with only the video tier connected. `force_stall` takes the lane's ready away
    // from the arbiter and the request away from the lane, which is how the underrun is made later.
    ddr3_read_arbiter u_arb (
        .clk(clk), .rst(rst),
        .video_req(vr_req), .video_addr(vr_addr), .video_burstlen(vr_burst), .video_gnt(vr_gnt),
        .video_rvalid(vr_rvalid), .video_rdata(vr_rdata), .video_done(vr_done),
        .audio_req(1'b0), .audio_addr(32'd0), .audio_burstlen(8'd0), .audio_gnt(), .audio_rvalid(), .audio_rdata(), .audio_done(),
        .tx_req(1'b0), .tx_addr(32'd0), .tx_burstlen(8'd0), .tx_gnt(), .tx_rvalid(), .tx_rdata(), .tx_done(),
        .rest_req(1'b0), .rest_addr(32'd0), .rest_burstlen(8'd0), .rest_gnt(), .rest_rvalid(), .rest_rdata(), .rest_done(),
        .addr_lane5(addr5), .rd_en_lane5(en5), .rd_go_lane5(go5), .burstcount_lane5(bc5),
        .rd_valid_lane5(valid5), .rd_data_lane5(data5), .rd_rdy_lane5(rdy5_m & ~force_stall),
        .owner()
    );
    // The lane model holds the framebuffers and the waterfall rings, read latency 6 clocks.
    ddr3_lane_behav_model #(.MEM_WORDS(65536), .RD_LATENCY(6)) lane (
        .clk(clk), .rst(rst),
        .addr_lane4(32'd0), .wr_mask_lane4(8'd0), .wr_data_lane4(64'd0), .wr_en_lane4(1'b0),
        .wr_go_lane4(1'b0), .burstcount_lane4(8'd0), .wr_wait_lane4(), .wr_done_lane4(),
        .addr_lane5(addr5), .rd_en_lane5(en5 & ~force_stall), .rd_go_lane5(go5), .burstcount_lane5(bc5),
        .rd_valid_lane5(valid5), .rd_data_lane5(data5), .rd_rdy_lane5(rdy5_m),
        .phys_busy()
    );

    // spectrum line buffer as the spectrum pipeline gives it (1-clock registered read)
    reg signed [15:0] spec [0:2047];
    always @(posedge clk) line_rd_data <= spec[line_rd_addr];
    // the zoom spectrum's line buffer (the compositor is built with its zoom snapshot): window 3 shows it
    reg signed [15:0] zspec [0:2047];
    always @(posedge clk) zline_rd_data <= zspec[zline_rd_addr];

    // ---------------------------------------------------------------- register bus (like regbus_cdc_dst)
    reg [31:0] live [0:255];          // what the model believes the register words hold
    reg [31:0] act  [0:255];          // the copy taken in the vertical blank
    reg [10:0] act_wltop [0:1];       // scroll line of each waterfall window, as latched
    reg [1:0]  m_src;
    reg [23:0] pal [0:1][0:255];
    integer ii, jj, kk;

    // Register write: one write strobe on the bus, then a pause so the value has crossed into the register
    // file, and the model's own copy (`live`) is updated.
    task wreg(input [15:0] a, input [31:0] d);
        begin
            @(posedge clk);
            bus_addr <= a; bus_wdata <= d; bus_wr <= 1'b1;
            @(posedge clk);
            bus_wr <= 1'b0;
            repeat (10) @(posedge clk);
            live[a[9:2]] = d;
        end
    endtask
    // Register read: strobe, wait for the read data to be valid.
    task rreg(input [15:0] a, output [31:0] d);
        begin
            @(posedge clk);
            bus_addr <= a; bus_rd <= 1'b1;
            @(posedge clk);
            bus_rd <= 1'b0;
            repeat (6) @(posedge clk);
            d = bus_rdata;
        end
    endtask
    // Write one palette entry: the index register takes {palette number, index}, the data register the
    // 24-bit color, and the model keeps its copy.
    task wpal(input integer which, input integer idx, input [23:0] c);
        begin
            wreg(`VIDEO_PALETTE_INDEX_ADDR, (which << 8) | idx);
            wreg(`VIDEO_PALETTE_DATA_ADDR, {8'd0, c});
            pal[which][idx] = c;
        end
    endtask

    // ---------------------------------------------------------------- reference model
    function [31:0] areg(input integer a);
        areg = act[a >> 2];
    endfunction

    integer m_i, m_w, m_k;
    integer n_fpga = 0, n_wf = 0, n_tline = 0, n_fill = 0, n_grid = 0, n_pb = 0, n_cur = 0, n_bars = 0;
    // The reference model: the color the compositor has to give for pixel (x, y), computed only from the
    // register words of the frame in force (`act`, copied in the vertical blank), the framebuffer and ring
    // contents in the lane model and the spectrum arrays. In order: outside the picture black; picture off
    // (control register 0) the 8 color bars; otherwise the GUI pixel (RGB565 widened to 8 bits per color by
    // repeating the top bits) unless it is the key color inside a window, where the FPGA layer is drawn: a
    // waterfall (palette lookup of the byte at the scrolled ring line) or a spectrum trace with its fill, then
    // the grid, then the first passband that covers the pixel blended with its alpha (0 to 16 sixteenths),
    // then the trace line and last the cursor. Where windows overlap the lowest numbered window wins.
    function [23:0] model(input integer x, input integer y);
        integer wsel, rx, ry, c, ch, d, dp, yt, ypv, ymin, ymax, hm1, gain, rf, vv, pbk;
        integer gxf, gxs, gyf, gys, alpha, dr, dg, db, widx, bidx, ll;
        reg [31:0] pos, siz, ctl, src, scl, gx, gy, pbc, pbr;
        reg [15:0] s;
        reg [23:0] fpga, base, pbcol, s888;
        reg        tline, tfill, wf, found, key_hit, gridhit;
        reg [63:0] wd;
        reg [7:0]  bt;
        integer wxx, wyy, ww, hh;
        begin
            if (x >= W || y >= H) begin
                model = 24'd0;
            // The 8 color bars: white, yellow, cyan, green, magenta, red, blue and black.
            end else if (!areg(`VIDEO_CTRL_ADDR) & 32'd1) begin
                case ((x / BARW > 7) ? 7 : (x / BARW))
                    0: model = 24'hFFFFFF;  1: model = 24'hFFFF00;  2: model = 24'h00FFFF;  3: model = 24'h00FF00;
                    4: model = 24'hFF00FF;  5: model = 24'hFF0000;  6: model = 24'h0000FF;  default: model = 24'h000000;
                endcase
            end else begin
            // The GUI pixel: four 16-bit pixels per 64-bit lane word, the framebuffer address is in bytes
            // (divided by 8 for the word), and the pixel is widened from 565 to 888 by repeating top bits.
                s = lane.mem[(areg(`VIDEO_FB_BASE_ADDR) >> 3) + y * (areg(`VIDEO_FB_STRIDE_ADDR) >> 3) + (x >> 2)] >> (16 * (x & 3));
                s888 = {s[15:11], s[15:13], s[10:5], s[10:9], s[4:0], s[4:2]};
            // Find the window that owns this pixel, the lowest numbered enabled one that contains it.
                wsel = -1;
                for (m_i = 3; m_i >= 0; m_i = m_i - 1) begin
                    pos = areg(`VIDEO_WIN_POS_ADDR(m_i)); siz = areg(`VIDEO_WIN_SIZE_ADDR(m_i));
                    ctl = areg(`VIDEO_WIN_CTRL_ADDR(m_i));
                    wxx = pos[11:0]; wyy = pos[26:16]; ww = siz[11:0]; hh = siz[26:16];
                    if (ctl[0] && ww != 0 && hh != 0 && x >= wxx && x < wxx + ww && y >= wyy && y < wyy + hh) wsel = m_i;
                end
                if (wsel < 0 || s != areg(`VIDEO_KEY_ADDR)) begin
                    model = s888;
                end else begin
                // The FPGA layer for window `wsel`: its position, size, control, source offset, scale
                // (low half: top reference level, high half: gain) and grid registers.
                    pos = areg(`VIDEO_WIN_POS_ADDR(wsel)); siz = areg(`VIDEO_WIN_SIZE_ADDR(wsel));
                    ctl = areg(`VIDEO_WIN_CTRL_ADDR(wsel)); src = areg(`VIDEO_WIN_SRC_ADDR(wsel));
                    scl = areg(`VIDEO_WIN_SCALE_ADDR(wsel));
                    gx = areg(`VIDEO_WIN_GRIDX_ADDR(wsel)); gy = areg(`VIDEO_WIN_GRIDY_ADDR(wsel));
                    rx = x - pos[11:0]; ry = y - pos[26:16];
                    c = rx + src[11:0];
                    hm1 = siz[26:16] - 1;
                    rf = $signed(scl[15:0]); gain = scl[31:16];
                    wf = ctl[1] && (wsel < 2);
                    tline = 0; tfill = 0;
                    // trace row of this column and the previous one
                    vv = ctl[2] ? zspec[c & 2047] : spec[c & 2047]; d = rf - vv; dp = (d < 0) ? 0 : d; yt = (dp * gain) >> 14; if (yt > hm1) yt = hm1;
                    if (rx == 0) ypv = yt;
                    else begin
                        vv = ctl[2] ? zspec[(c - 1) & 2047] : spec[(c - 1) & 2047]; d = rf - vv; dp = (d < 0) ? 0 : d; ypv = (dp * gain) >> 14; if (ypv > hm1) ypv = hm1;
                    end
                    ymin = (yt < ypv) ? yt : ypv; ymax = (yt < ypv) ? ypv : yt;
                    tline = !wf && ry >= ymin && ry <= ymax;
                    tfill = ry > yt;
                    n_fpga = n_fpga + 1; if (wf) n_wf = n_wf + 1; if (tline) n_tline = n_tline + 1; if (tfill && !wf) n_fill = n_fill + 1;
                    // Waterfall: the ring line shown on row `ry` counts back from the window's scroll line,
                    // each line is 240 words, the byte of column `c` is picked from its word most
                    // significant byte first, and the window's palette gives the color.
                    if (wf) begin
                        ll = (act_wltop[wsel] - ry) & 2047;
                        wd = lane.mem[areg(`VIDEO_WF_WIN_RING_ADDR(wsel)) + ll * 240 + (c >> 3)];
                        bt = wd >> (56 - 8 * (c & 7));
                        base = pal[wsel][bt];
                    end else begin
                        base = tfill ? areg(`VIDEO_COL_FILL_ADDR) : areg(`VIDEO_COL_BG_ADDR);
                    end
                    // grid
                    gxf = gx[11:0]; gxs = gx[27:16]; gyf = gy[11:0]; gys = gy[27:16];
                    gridhit = 0;
                    if (gxs != 0 && rx >= gxf && ((rx - gxf) % gxs) == 0) gridhit = 1;
                    if (!wf && gys != 0 && ry >= gyf && ((ry - gyf) % gys) == 0) gridhit = 1;
                    if (gridhit) begin base = areg(`VIDEO_COL_GRID_ADDR); n_grid = n_grid + 1; end
                    // passbands: the first one that covers the pixel
                    found = 0;
                    for (m_k = 7; m_k >= 0; m_k = m_k - 1) begin
                        pbc = areg(`VIDEO_PB_CTRL_ADDR(m_k)); pbr = areg(`VIDEO_PB_RANGE_ADDR(m_k));
                        if (pbc[0] && pbc[1 + wsel] && x >= pbr[11:0] && x < pbr[27:16]) begin
                            found = 1; pbk = m_k;
                        end
                    end
                    if (found) begin
                        n_pb = n_pb + 1;
                        pbc = areg(`VIDEO_PB_CTRL_ADDR(pbk)); pbcol = areg(`VIDEO_PB_COL_ADDR(pbk));
                        alpha = pbc[12:8]; if (alpha > 16) alpha = 16;
                        dr = pbcol[23:16] - base[23:16]; dg = pbcol[15:8] - base[15:8]; db = pbcol[7:0] - base[7:0];
                        base = {8'(base[23:16] + ((dr * alpha) >>> 4)), 8'(base[15:8] + ((dg * alpha) >>> 4)),
                                8'(base[7:0] + ((db * alpha) >>> 4))};
                    end
                    // The trace line wins over everything else, the cursor over that.
                    if (tline) base = areg(`VIDEO_COL_TRACE_ADDR);
                    pbc = areg(`VIDEO_CURSOR_CTRL_ADDR);
                    if (pbc[0] && pbc[1 + wsel] && x >= areg(`VIDEO_CURSOR_X_ADDR) &&
                        x < areg(`VIDEO_CURSOR_X_ADDR) + ((pbc[11:8] == 0) ? 1 : pbc[11:8]))
                        begin base = areg(`VIDEO_CURSOR_COL_ADDR); n_cur = n_cur + 1; end
                    model = base;
                end
            end
        end
    endfunction

    // Checker: on every pixel clock inside the active picture compare `rgb` with the model.
    // ---------------------------------------------------------------- checker
    reg     cmp_on = 1'b0;
    integer errors = 0, compared = 0, fpga_px = 0;
    reg [23:0] exp_px;
    always @(posedge clk_pix) begin
        if (cmp_on && cx < W && cy < H) begin
            exp_px = model(cx, cy);
            compared = compared + 1;
            if (rgb !== exp_px) begin
                errors = errors + 1;
                if (errors <= 12) $display("MISMATCH frame %0d (%0d,%0d): rgb %h expected %h", frame_n, cx, cy, rgb, exp_px);
            end
        end
        // description takes over in the vertical blank (the model's copy of that)
        if (cx == 12'd0 && cy == VCAP + 1) begin
            for (kk = 0; kk < 256; kk = kk + 1) act[kk] = live[kk];
            for (kk = 0; kk < 2; kk = kk + 1) begin
                m_src = live[`VIDEO_WF_WIN_CTRL_ADDR(kk) >> 2];
                act_wltop[kk] = m_src[1] ? live[`VIDEO_WF_WIN_LINE_ADDR(kk) >> 2] : m_src[0] ? zwf_write_line : wf_write_line;
            end
        end
    end

    // Stimulus helpers: random pixels for the framebuffers with the key color placed inside the windows.
    // ---------------------------------------------------------------- stimulus
    function [15:0] rnd16(input integer dummy);
        rnd16 = $random;
    endfunction
    // True when pixel (x, y) is inside any of the four enabled-or-not windows of the programmed
    // description (position and size only).
    function inwin(input integer x, input integer y);
        integer q;
        reg [31:0] p, z;
        begin
            inwin = 0;
            for (q = 0; q < 4; q = q + 1) begin
                p = live[`VIDEO_WIN_POS_ADDR(q) >> 2]; z = live[`VIDEO_WIN_SIZE_ADDR(q) >> 2];
                if (x >= p[11:0] && x < p[11:0] + z[11:0] && y >= p[26:16] && y < p[26:16] + z[26:16]) inwin = 1;
            end
        end
    endfunction
    // Fill one framebuffer with random RGB565 pixels. Inside the windows the pixel is the key color in 7
    // cases of 8, so a few GUI pixels show on top of the FPGA layer, and the key color is kept out of every
    // other pixel.
    task fill_fb(input [31:0] base, input integer seed_sel);
        integer x, y;
        reg [15:0] px;
        begin
            for (y = 0; y < H; y = y + 1)
                for (x = 0; x < W; x = x + 1) begin
                    px = $random;
                    if (px == 16'hF81F) px = 16'h07E0;
                    if (inwin(x, y) && ($random & 7) != 0) px = 16'hF81F;    // mostly key inside windows
                    lane.mem[(base >> 3) + y * (STRIDE >> 3) + (x >> 2)][16 * (x & 3) +: 16] = px;
                end
        end
    endtask

    integer ucount0, ucount1, f0;
    reg [31:0] rd;

    // Test sequence, see the header for what each part checks.
    initial begin
        for (ii = 0; ii < 256; ii = ii + 1) begin live[ii] = 0; act[ii] = 0; end
        act_wltop[0] = 11'd20; act_wltop[1] = 11'd20;
        // register reset values as in the register map
        live[`VIDEO_FB_BASE_ADDR >> 2] = `VIDEO_FB_BASE_RESET;
        live[`VIDEO_FB_STRIDE_ADDR >> 2] = `VIDEO_FB_STRIDE_RESET;
        live[`VIDEO_KEY_ADDR >> 2] = `VIDEO_KEY_RESET;
        live[`VIDEO_COL_FILL_ADDR >> 2] = `VIDEO_COL_FILL_RESET;
        live[`VIDEO_COL_TRACE_ADDR >> 2] = `VIDEO_COL_TRACE_RESET;
        live[`VIDEO_COL_GRID_ADDR >> 2] = `VIDEO_COL_GRID_RESET;
        live[`VIDEO_CURSOR_CTRL_ADDR >> 2] = `VIDEO_CURSOR_CTRL_RESET;
        live[`VIDEO_CURSOR_COL_ADDR >> 2] = `VIDEO_CURSOR_COL_RESET;
        for (ii = 0; ii < 4; ii = ii + 1) live[`VIDEO_WIN_SCALE_ADDR(ii) >> 2] = `VIDEO_WIN_SCALE_RESET;
        for (ii = 0; ii < 8; ii = ii + 1) begin
            live[`VIDEO_PB_CTRL_ADDR(ii) >> 2] = `VIDEO_PB_CTRL_RESET;
            live[`VIDEO_PB_COL_ADDR(ii) >> 2] = `VIDEO_PB_COL_RESET;
        end
        for (ii = 0; ii < 256; ii = ii + 1) act[ii] = live[ii];
        // Random spectrum lines (10-bit values with an offset, nonzero only for the columns that are shown)
        // and random palettes.
        for (ii = 0; ii < 2048; ii = ii + 1) spec[ii] = (ii < W + 40) ? (($random & 1023) - 900) : 0;
        for (ii = 0; ii < 2048; ii = ii + 1) zspec[ii] = (ii < W + 40) ? (($random & 1023) - 700) : 0;
        for (ii = 0; ii < 2; ii = ii + 1) for (jj = 0; jj < 256; jj = jj + 1) pal[ii][jj] = $random;
        repeat (20) @(posedge clk);
        rst = 1'b0;
        repeat (5) @(posedge clk);

        // two waterfall rings: 40 lines of 240 words of random bytes each
        for (ii = 0; ii < 40 * 240; ii = ii + 1) lane.mem[RING + ii] = {$random, $random};
        for (ii = 0; ii < 40 * 240; ii = ii + 1) lane.mem[RING1 + ii] = {$random, $random};

        // ---- read back the reset values
        rreg(`VIDEO_ID_ADDR, rd);              if (rd !== `VIDEO_ID_RESET) begin $display("ERROR id %h", rd); errors = errors + 1; end
        rreg(`VIDEO_FB_BASE_ADDR, rd);         if (rd !== `VIDEO_FB_BASE_RESET) begin $display("ERROR fb_base reset %h", rd); errors = errors + 1; end
        rreg(`VIDEO_KEY_ADDR, rd);             if (rd !== 32'hF81F) begin $display("ERROR key reset %h", rd); errors = errors + 1; end
        rreg(`VIDEO_WIN_SCALE_ADDR(2), rd);    if (rd !== `VIDEO_WIN_SCALE_RESET) begin $display("ERROR scale reset %h", rd); errors = errors + 1; end

        // ---- program the picture (frame 0); it takes effect at the vertical blank
        wreg(`VIDEO_FB_BASE_ADDR, FB_A);
        wreg(`VIDEO_FB_STRIDE_ADDR, STRIDE);
        wreg(`VIDEO_WF_RING_BASE_ADDR, RING);
        wreg(`VIDEO_WF_ZOOM_RING_BASE_ADDR, RING1);
        // window 0: the first ring, scrolled by the full-band hardware writer; window 1: the second
        // ring, scrolled by the CPU's line
        wreg(`VIDEO_WF_WIN_RING_ADDR(0), RING);   wreg(`VIDEO_WF_WIN_CTRL_ADDR(0), 32'd0);
        wreg(`VIDEO_WF_WIN_RING_ADDR(1), RING1);  wreg(`VIDEO_WF_WIN_CTRL_ADDR(1), 32'd2);
        wreg(`VIDEO_WF_WIN_LINE_ADDR(1), 32'd15);
        rreg(`VIDEO_WF_WIN_RING_ADDR(1), rd);  if (rd !== RING1) begin $display("ERROR wf_win_ring readback %h", rd); errors = errors + 1; end
        rreg(`VIDEO_WF_WIN_LINE_ADDR(1), rd);  if (rd !== 15) begin $display("ERROR wf_win_line readback %h", rd); errors = errors + 1; end
        if (wf_ring_base !== RING || dut.zwf_ring_base !== RING1) begin $display("ERROR writer ring bases"); errors = errors + 1; end
        // window 0, 1: waterfalls side by side; 2, 3: traces below
        wreg(`VIDEO_WIN_POS_ADDR(0), (2 << 16) | 8);   wreg(`VIDEO_WIN_SIZE_ADDR(0), (10 << 16) | 48);
        wreg(`VIDEO_WIN_CTRL_ADDR(0), 32'b011);        wreg(`VIDEO_WIN_SRC_ADDR(0), 3);
        wreg(`VIDEO_WIN_POS_ADDR(1), (2 << 16) | 60);  wreg(`VIDEO_WIN_SIZE_ADDR(1), (10 << 16) | 30);
        wreg(`VIDEO_WIN_CTRL_ADDR(1), 32'b011);        wreg(`VIDEO_WIN_SRC_ADDR(1), 20);
        wreg(`VIDEO_WIN_POS_ADDR(2), (14 << 16) | 8);  wreg(`VIDEO_WIN_SIZE_ADDR(2), (8 << 16) | 40);
        wreg(`VIDEO_WIN_CTRL_ADDR(2), 32'b001);        wreg(`VIDEO_WIN_SRC_ADDR(2), 0);
        wreg(`VIDEO_WIN_POS_ADDR(3), (14 << 16) | 50); wreg(`VIDEO_WIN_SIZE_ADDR(3), (8 << 16) | 40);
        wreg(`VIDEO_WIN_CTRL_ADDR(3), 32'b101);        wreg(`VIDEO_WIN_SRC_ADDR(3), 5);       // the zoom trace
        wreg(`VIDEO_WIN_SCALE_ADDR(2), (32'h0100 << 16) | 16'h0000);       // 1 px / dB, 0 dB at the top
        wreg(`VIDEO_WIN_SCALE_ADDR(3), (32'h0180 << 16) | 16'hFF80);       // 1.5 px / dB, +2 dB at the top
        wreg(`VIDEO_WIN_GRIDX_ADDR(0), (5 << 16) | 0);
        wreg(`VIDEO_WIN_GRIDX_ADDR(1), (4 << 16) | 2);
        wreg(`VIDEO_WIN_GRIDX_ADDR(2), (7 << 16) | 3);
        wreg(`VIDEO_WIN_GRIDY_ADDR(2), (3 << 16) | 1);
        wreg(`VIDEO_WIN_GRIDY_ADDR(3), (2 << 16) | 0);
        wreg(`VIDEO_COL_BG_ADDR, 32'h101010);
        wreg(`VIDEO_PB_RANGE_ADDR(0), (40 << 16) | 20);   wreg(`VIDEO_PB_CTRL_ADDR(0), (8 << 8) | (4'b0101 << 1) | 1);
        wreg(`VIDEO_PB_RANGE_ADDR(1), (70 << 16) | 30);   wreg(`VIDEO_PB_CTRL_ADDR(1), (16 << 8) | (4'b1111 << 1) | 1);
        wreg(`VIDEO_PB_RANGE_ADDR(2), (96 << 16) | 0);    wreg(`VIDEO_PB_CTRL_ADDR(2), (4 << 8) | (4'b1000 << 1) | 1);
        wreg(`VIDEO_PB_COL_ADDR(0), 32'h00FF00);          wreg(`VIDEO_PB_COL_ADDR(1), 32'hFF0000);
        wreg(`VIDEO_PB_COL_ADDR(2), 32'h0000FF);
        wreg(`VIDEO_CURSOR_X_ADDR, 45);
        wreg(`VIDEO_CURSOR_CTRL_ADDR, (2 << 8) | (4'b1111 << 1) | 1);
        for (ii = 0; ii < 256; ii = ii + 1) begin wpal(0, ii, pal[0][ii]); wpal(1, ii, pal[1][ii]); end
        fill_fb(FB_A, 0);
        fill_fb(FB_B, 1);
        // fill_fb used `live` for the window rectangles: the same windows apply after the swap
        wreg(`VIDEO_CTRL_ADDR, 32'd1);

        // ---- the first frame that shows the picture: wait for the frame, the description is taken at line
        // VCAP of it, and compare from the next frame on
        f0 = frame_n + 1;
        while (!(frame_n == f0 && cy == 11'd2)) @(posedge clk_pix);     // all registers written; takes over at line VCAP of this frame
        while (frame_n < f0 + 1) @(posedge clk_pix);
        cmp_on = 1'b1;
        rreg(`VIDEO_FRAME_COUNT_ADDR, rd);
        while (!(frame_n == f0 + 1 && cy == 11'd10)) @(posedge clk_pix);
        rreg(`VIDEO_FB_ACTIVE_ADDR, rd);   if (rd !== FB_A) begin $display("ERROR fb_active %h", rd); errors = errors + 1; end
        rreg(`VIDEO_FB_BASE_ADDR, rd);     if (rd !== FB_A) begin $display("ERROR fb_base readback %h", rd); errors = errors + 1; end
        rreg(`VIDEO_WIN_POS_ADDR(3), rd);  if (rd !== ((14 << 16) | 50)) begin $display("ERROR win_pos readback %h", rd); errors = errors + 1; end
        rreg(`VIDEO_UNDERRUN_COUNT_ADDR, rd); ucount0 = rd;
        // ---- frame 2: write the next picture in the middle of the frame, which must not change this frame
        while (!(frame_n == f0 + 2 && cy == 11'd6)) @(posedge clk_pix);
        wreg(`VIDEO_FB_BASE_ADDR, FB_B);
        wreg(`VIDEO_CURSOR_X_ADDR, 10);
        wreg(`VIDEO_COL_TRACE_ADDR, 32'h00FFFF);
        wreg(`VIDEO_WIN_SRC_ADDR(0), 9);
        wf_write_line = 11'd23;
        wreg(`VIDEO_WF_WIN_LINE_ADDR(1), 32'd16);                      // the CPU scrolls window 1 by one line
        rreg(`VIDEO_WF_WIN_TOP_ADDR(1), rd); if (rd !== 15) begin $display("ERROR wf_win_top(1) %0d changed in the frame", rd); errors = errors + 1; end
        // ---- frame 3: the new picture, framebuffer B, new cursor, trace color, source offset and scroll lines
        while (!(frame_n == f0 + 3 && cy == 11'd10)) @(posedge clk_pix);
        rreg(`VIDEO_FB_ACTIVE_ADDR, rd);   if (rd !== FB_B) begin $display("ERROR fb_active after swap %h", rd); errors = errors + 1; end
        rreg(`VIDEO_UNDERRUN_COUNT_ADDR, rd); if (rd !== 0) begin $display("ERROR underrun count %0d before the stall", rd); errors = errors + 1; end
        rreg(`VIDEO_WF_WIN_TOP_ADDR(0), rd); if (rd !== 23) begin $display("ERROR wf_win_top(0) %0d", rd); errors = errors + 1; end
        rreg(`VIDEO_WF_WIN_TOP_ADDR(1), rd); if (rd !== 16) begin $display("ERROR wf_win_top(1) %0d", rd); errors = errors + 1; end
        rreg(`VIDEO_WF_WRITE_LINE_ADDR, rd); if (rd !== 23) begin $display("ERROR wf_write_line %0d", rd); errors = errors + 1; end
        rreg(`VIDEO_WF_ZOOM_WRITE_LINE_ADDR, rd); if (rd !== 31) begin $display("ERROR wf_zoom_write_line %0d", rd); errors = errors + 1; end
        // ---- frame 4: hold the lane off for 500 clocks (about two lines) around line 8, compare switched off
        // for that frame
        while (!(frame_n == f0 + 4 && cy == 11'd8 && cx == 12'd100)) @(posedge clk_pix);
        cmp_on = 1'b0;
        force_stall = 1'b1;
        repeat (500) @(posedge clk);
        force_stall = 1'b0;
        // ---- frame 5: the picture is exact again, the stall was counted, the status bit is set and then
        // cleared by writing a 1 to it, which also clears the count
        while (!(frame_n == f0 + 5 && cy == 11'd2)) @(posedge clk_pix);
        cmp_on = 1'b1;
        while (!(frame_n == f0 + 6 && cy == 11'd10)) @(posedge clk_pix);
        rreg(`VIDEO_UNDERRUN_COUNT_ADDR, rd); ucount1 = rd;
        if (ucount1 < 1) begin $display("ERROR the stall was not counted as an underrun"); errors = errors + 1; end
        rreg(`VIDEO_STATUS_ADDR, rd);      if (rd[0] !== 1'b1) begin $display("ERROR status.underrun not set"); errors = errors + 1; end
        wreg(`VIDEO_STATUS_ADDR, 32'd1);
        rreg(`VIDEO_STATUS_ADDR, rd);      if (rd[0] !== 1'b0) begin $display("ERROR status.underrun not cleared"); errors = errors + 1; end
        rreg(`VIDEO_UNDERRUN_COUNT_ADDR, rd); if (rd !== 0) begin $display("ERROR count not cleared"); errors = errors + 1; end
        // ---- frames 7 and 8: window 0 follows the zoom writer's line, window 1 moves to the first ring
        wreg(`VIDEO_WF_WIN_CTRL_ADDR(0), 32'd1);
        wreg(`VIDEO_WF_WIN_RING_ADDR(1), RING);
        wreg(`VIDEO_WF_WIN_LINE_ADDR(1), 32'd27);
        while (!(frame_n == f0 + 8 && cy == 11'd10)) @(posedge clk_pix);
        rreg(`VIDEO_UNDERRUN_COUNT_ADDR, rd); if (rd !== 0) begin $display("ERROR underruns after recovery: %0d", rd); errors = errors + 1; end
        rreg(`VIDEO_WF_WIN_TOP_ADDR(0), rd); if (rd !== 31) begin $display("ERROR wf_win_top(0) %0d with the zoom writer's line", rd); errors = errors + 1; end
        rreg(`VIDEO_WF_WIN_TOP_ADDR(1), rd); if (rd !== 27) begin $display("ERROR wf_win_top(1) %0d", rd); errors = errors + 1; end
        $display("model pixels: fpga layer %0d (waterfall %0d, trace line %0d, fill %0d), grid %0d, passband %0d, cursor %0d", n_fpga, n_wf, n_tline, n_fill, n_grid, n_pb, n_cur);
        $display("compared %0d pixels, %0d errors, stall underruns %0d (before the stall %0d)", compared, errors, ucount1, ucount0);
        if (errors == 0 && compared > 5 * W * H) $display("PASS");
        else $display("FAIL");
        $finish;
    end

    // Safety net: 3 ms of simulated time, the nine frames of the test need about 0.45 ms.
    initial begin
        #3_000_000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
