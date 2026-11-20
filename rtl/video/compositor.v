// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// compositor: the screen compositor. It builds the picture that the HDMI output shows from three kinds of layers and gives
// the HDMI core its pixel for every position.
//
// WHERE IT SITS
// The AE350 CPU's firmware draws the user interface (Slint) into a framebuffer in DDR3 memory and sets up through registers
// (page 0x07, hw/regmap/video.toml) where the FPGA drawn windows are. This module reads that framebuffer and the waterfall
// lines from DDR3 through the video tier of the read arbiter, takes the spectrum line from the spectrum pipeline, draws the
// spectrum trace, the waterfall and the overlays (grid, receiver passbands, tuning cursor), mixes everything per pixel, and
// gives the pixel to rtl/video/sdr_hdmi_video.v, which turns it into the TMDS signal for the monitor. The theory of
// the layers, the key color and the alpha blend is in the header of compositor_pix.v, and the theory of the video timing in
// the header of sdr_hdmi_video.v. Terms are also in docs/learn/GLOSSARY.md.
//
// THE FILE HOLDS TWO MODULES
// compositor_regs is the register file and compositor is the top that ties it to the fetch engine (compositor_fetch.v), the
// pixel pipeline (compositor_pix.v), the line buffer memories and the clock crossings. The helpers are in compositor_util.v
// and the layout of the picture description is in compositor_cfg.vh.
//
// TWO CLOCK DOMAINS
//   clk (clk_dsp, 120 MHz)  the registers (page 0x07), the fetch engine, the copy of the spectrum line into a snapshot RAM, and
//                           the write sides of the line buffers
//   clk_pix (74.17 MHz)     the pixel pipeline (compositor_pix.v) and the read sides of the line buffers
// The two clocks come from different PLLs and have no fixed relation, so every signal that crosses goes through a
// synchronizer: a single toggling bit through three flip-flops (the receiver sees a change by comparing the last two
// flip-flops, which gives a one-clock pulse), or a gray coded counter through two (a gray code changes one bit at a time, so
// a value caught during a change is still a valid neighbor). The line buffers are RAMs with one write clock and one read
// clock, which is safe because the two sides never use the same half of a buffer at once. The picture description crosses as
// a whole block under a handshake.
//
// THE FRAME HANDSHAKE (all crossings are toggles or gray codes)
//   1. At line VCAP (1082, in the vertical blanking, the visible lines are 0 to 1079) the pixel side flips `cap_tog`.
//   2. In clk_dsp this is `cap_pulse`. The register file reads its 256 shadow RAM words out into the description registers
//      (`snap`, about 270 clocks), then the frame counter goes up by one and the spectrum line is copied into the snapshot
//      RAM (W clocks, some 16 us; a spectrum line that finishes during this copy shows as a torn trace for one frame).
//   3. After `snap` has settled, `ack_tog` flips; the pixel side turns this into the pulse `load_pix`, and `snap` is copied
//      into `cfg` (compositor_util.v comp_xfer).
// So the description changes only in the vertical blanking, and the fetch engine (which uses `snap`) and the pixel pipeline
// (which uses `cfg`) always work from the same picture. The pixel side never waits for the clk_dsp side: with no
// acknowledge it simply goes on with the old description.
//
// The description exists twice, `snap` in clk and `cfg` in clk_pix. The registers the CPU writes are words of the shadow
// RAM only, which also serves to read them back, and the description registers are loaded from it once per frame.

`timescale 1ns / 1ps
`include "hw/regmap/generated/video_regs.vh"
`include "rtl/video/compositor_cfg.vh"

// ================================================================================ register file
module compositor_regs (
    input  wire         clk,  // clk_dsp, 120 MHz
    input  wire         bus_wr,  // one-clock write strobe from the register bridge (rtl/top/regbus_leg.v)
    input  wire         bus_rd,  // one-clock read strobe
    input  wire [15:0]  bus_addr,  // byte address inside the page 0x07; only offsets below 0x400 are used (bits 15:10 must be 0), bits 9:2 select one of 256 words
    input  wire [31:0]  bus_wdata,  // write data, 32 bits
    output reg  [31:0]  bus_rdata,  // read data, valid three clocks after bus_rd (the bridge waits six)
    // status in
    input  wire [31:0]  st_ucount,  // number of underrun lines since the last clear
    input  wire [31:0]  st_fcount,  // frames shown since reset
    input  wire [31:0]  st_fbact,  // framebuffer base address (byte) of the frame in `snap`
    input  wire [21:0]  st_wftop,           // latched scroll line of waterfall window 0, 1
    input  wire         st_underrun,  // sticky underrun flag
    input  wire         st_laneerr,  // sticky lane error flag
    input  wire [10:0]  wf_write_line,      // full-band hardware writer's last line
    input  wire [10:0]  zwf_write_line,     // zoom hardware writer's last line
    output reg          clr_underrun,  // one-clock pulse: a write of 1 to the status register's underrun bit, clears the flag and the counter
    output reg          clr_laneerr,  // one-clock pulse: a write of 1 to the status register's lane error bit
    // description out (clk): the frame's own copy, loaded from the shadow RAM after `cap`
    input  wire         cap,                // one pulse: take the description for the next frame
    output reg          snap_rdy,           // one pulse: `snap` has settled
    output wire [`CF_W-1:0] snap,
    output wire [31:0]  wf_ring_base,       // to the full-band waterfall writer
    output wire [31:0]  zwf_ring_base,      // to the zoom waterfall writer
    // palette write port
    output reg          pal_we,  // one-clock pulse: write a palette entry
    output reg  [8:0]   pal_wa,  // palette address: {window 8, color index 7:0}
    output reg  [23:0]  pal_wd  // palette color, 24 bits {red, green, blue}
) /* synthesis syn_maxfan = 10000 */;

    // ---- the bus path: a write is registered once (wr_q, hi_ok, wi, d_q), and the strobes for individual registers are
    // decoded one stage later from a one-hot split of the word index, which keeps every stage short.
    reg        wr_q = 1'b0, hi_ok = 1'b0;
    reg [7:0]  wi = 8'd0;
    reg [31:0] d_q = 32'd0;
    always @(posedge clk) begin
        wr_q  <= bus_wr;
        hi_ok <= (bus_addr[15:10] == 6'd0);
        wi    <= bus_addr[9:2];
        d_q   <= bus_wdata;
    end
    reg [31:0] d_q2 = 32'd0, d_q3 = 32'd0;   // d_q delayed by two and three more clocks, to go with the registered strobes below
    always @(posedge clk) begin d_q2 <= d_q; d_q3 <= d_q2; end

    // ---- the registers, with their reset values from the register map. Only r_pidx, r_pdat, r_wfring and r_zwfring are written
    // by the bus directly. All the others are the frame's description and are loaded from the shadow RAM by the sweep
    // further down (the same decode, a second copy of it): a write from the CPU lands in the RAM at once and reaches the
    // description only at the next frame, which is what makes a change appear whole in the next frame and never half.
    reg        r_en = `VIDEO_CTRL_RESET;
    reg        r_m30 = 1'b0;
    reg [31:0] r_fbbase = `VIDEO_FB_BASE_RESET;
    reg [31:0] r_fbstride = `VIDEO_FB_STRIDE_RESET;
    reg [127:0] r_wpos = {4{`VIDEO_WIN_POS_RESET}};
    reg [127:0] r_wsize = {4{`VIDEO_WIN_SIZE_RESET}};
    reg [127:0] r_wctrl = {4{`VIDEO_WIN_CTRL_RESET}};
    reg [127:0] r_wsrc = {4{`VIDEO_WIN_SRC_RESET}};
    reg [8:0]  r_pidx = 9'd0;
    reg [23:0] r_pdat = 24'd0;
    reg [31:0] r_wfring = `VIDEO_WF_RING_BASE_RESET;
    reg [31:0] r_zwfring = `VIDEO_WF_ZOOM_RING_BASE_RESET;
    reg [63:0] r_wwring = 64'd0;             // per waterfall window: ring base,
    reg [3:0]  r_wwsrc = 4'd0;               // scroll line source,
    reg [21:0] r_wwline = 22'd0;             // CPU-written scroll line
    reg [15:0] r_key = `VIDEO_KEY_RESET;
    reg [127:0] r_wscale = {4{`VIDEO_WIN_SCALE_RESET}};
    reg [127:0] r_wgx = {4{`VIDEO_WIN_GRIDX_RESET}};
    reg [127:0] r_wgy = {4{`VIDEO_WIN_GRIDY_RESET}};
    reg [23:0] r_cbg = `VIDEO_COL_BG_RESET;
    reg [23:0] r_cfill = `VIDEO_COL_FILL_RESET;
    reg [23:0] r_ctrace = `VIDEO_COL_TRACE_RESET;
    reg [23:0] r_cgrid = `VIDEO_COL_GRID_RESET;
    reg [11:0] r_curc = `VIDEO_CURSOR_CTRL_RESET;
    reg [11:0] r_curx = `VIDEO_CURSOR_X_RESET;
    reg [23:0] r_curcol = `VIDEO_CURSOR_COL_RESET;
    reg [255:0] r_pbr = {8{`VIDEO_PB_RANGE_RESET}};
    reg [255:0] r_pbc = {8{`VIDEO_PB_CTRL_RESET}};
    localparam [31:0] PBCOL_RST = `VIDEO_PB_COL_RESET;
    reg [191:0] r_pbcol = {8{PBCOL_RST[23:0]}};

    // The ring bases of the two hardware waterfall writers are bus registers that take effect at once.
    assign wf_ring_base  = r_wfring;
    assign zwf_ring_base = r_zwfring;

    // A write to page 0x07 (vw), and the one-hot decode of its word index: dh[n] says the upper four bits of the index equal
    // n and dl[n] the lower four, so a register is selected by two ANDed bits instead of an 8-bit compare.
    wire vw = wr_q & hi_ok;
    reg  [15:0] dh = 16'd0, dl = 16'd0;
    reg         vw2 = 1'b0;
    integer     di;
    always @(posedge clk) begin
        vw2 <= vw;
        for (di = 0; di < 16; di = di + 1) begin
            dh[di] <= (wi[7:4] == di);
            dl[di] <= (wi[3:0] == di);
        end
    end
    // sel(w): this write is for word w (a function of constants only, it becomes two AND inputs)
    function sel(input [7:0] w);
        sel = vw2 & dh[w[7:4]] & dl[w[3:0]];
    endfunction
    // strobes for the registers that the bus writes directly: palette index, palette data, the two ring bases and the status
    // register (writing 1 to its bits clears them)
    reg  s_pidx = 1'b0;  always @(posedge clk) s_pidx <= sel(`VIDEO_PALETTE_INDEX_ADDR >> 2);
    reg  s_pdat = 1'b0;  always @(posedge clk) s_pdat <= sel(`VIDEO_PALETTE_DATA_ADDR >> 2);
    reg  s_wfring = 1'b0;  always @(posedge clk) s_wfring <= sel(`VIDEO_WF_RING_BASE_ADDR >> 2);
    reg  s_zwfring = 1'b0;  always @(posedge clk) s_zwfring <= sel(`VIDEO_WF_ZOOM_RING_BASE_ADDR >> 2);
    reg  s_status = 1'b0;  always @(posedge clk) s_status <= sel(`VIDEO_STATUS_ADDR >> 2);

    // Write side of those direct registers. The palette write goes out as {index, data} for one clock.
    always @(posedge clk) begin
        pal_we <= s_pdat;
        pal_wa <= r_pidx;
        pal_wd <= d_q3[23:0];
        clr_underrun <= s_status & d_q3[`VIDEO_STATUS_UNDERRUN_LSB];
        clr_laneerr  <= s_status & d_q3[`VIDEO_STATUS_LANE_ERROR_LSB];
        if (s_pidx)   r_pidx     <= d_q3[8:0];
        if (s_pdat)   r_pdat     <= d_q3[23:0];
        if (s_wfring) r_wfring   <= d_q3;
        if (s_zwfring) r_zwfring <= d_q3;
    end

    // ---- the sweep: after `cap` the 256 words of the shadow RAM are read once through the read-back port (which a bus read
    // takes away for eight clocks, because the bridge samples its answer in that time) and loaded into the description
    // registers. xv, rd_wi2 and sh_rd are to the sweep what vw, wi and d_q are to the bus: the strobe, the address and the
    // data. The sweep lasts 256 words + 14 clocks until everything derived has settled, about 270 clocks.
    reg  [7:0]  rd_wi = 8'd0, rd_wi2 = 8'd0;
    reg  [31:0] sh_rd = 32'd0;
    reg  [3:0]  brw = 4'd0;                 // a bus read has the read port for this many clocks more
    reg         brw_q = 1'b0;
    wire        bus_sel = bus_rd | (brw != 4'd0);
    reg         sw_run = 1'b0;
    reg  [7:0]  sw_i = 8'd0;
    wire        sw_take = sw_run & ~bus_sel;
    reg         xv0 = 1'b0, xv = 1'b0, xv2 = 1'b0;
    reg  [31:0] x_q2 = 32'd0, x_q3 = 32'd0;
    reg  [15:0] xh = 16'd0, xl = 16'd0;
    reg  [4:0]  sw_dn = 5'd0;               // clocks left until the description has settled
    reg  [1:0]  top_ld /* synthesis syn_preserve = 1 */;
    initial begin top_ld = 2'd0; snap_rdy = 1'b0; end
    // Sweep control: `cap` starts it, sw_i counts the words, the pipeline xv0, xv, xv2 follows the reads, sw_dn counts the 14
    // clocks until the derived values are in place and then gives snap_rdy.
    always @(posedge clk) begin
        if (bus_rd) brw <= 4'd7; else if (brw != 4'd0) brw <= brw - 4'd1;
        brw_q <= (brw != 4'd0);
        if (cap) begin sw_run <= 1'b1; sw_i <= 8'd0; end
        else if (sw_take) begin
            sw_i <= sw_i + 8'd1;
            if (sw_i == 8'd255) sw_run <= 1'b0;
        end
        xv0  <= sw_take;                    // rd_wi holds a sweep address
        xv   <= xv0;                        // sh_rd holds its word, rd_wi2 its address
        xv2  <= xv;
        x_q2 <= sh_rd;
        x_q3 <= x_q2;
        for (di = 0; di < 16; di = di + 1) begin
            xh[di] <= (rd_wi2[7:4] == di);
            xl[di] <= (rd_wi2[3:0] == di);
        end
        // 14 clocks after the last word was read every register and every derived value is in place
        snap_rdy <= 1'b0;
        top_ld   <= 2'd0;
        if (sw_take && sw_i == 8'd255) sw_dn <= 5'd14;
        else if (sw_dn != 5'd0) begin
            sw_dn <= sw_dn - 5'd1;
            if (sw_dn == 5'd4) top_ld <= 2'b11;
            if (sw_dn == 5'd1) snap_rdy <= 1'b1;
        end
    end
    // xsel(w): the sweep word being delivered is word w (the same trick as sel, for the sweep).
    function xsel(input [7:0] w);
        xsel = xv2 & xh[w[7:4]] & xl[w[3:0]];
    endfunction
    // Strobes of the sweep, one per register with a single instance.
    reg  x_ctrl = 1'b0;   always @(posedge clk) x_ctrl <= xsel(`VIDEO_CTRL_ADDR >> 2);
    reg  x_fbbase = 1'b0; always @(posedge clk) x_fbbase <= xsel(`VIDEO_FB_BASE_ADDR >> 2);
    reg  x_fbstr = 1'b0;  always @(posedge clk) x_fbstr <= xsel(`VIDEO_FB_STRIDE_ADDR >> 2);
    reg  x_key = 1'b0;    always @(posedge clk) x_key <= xsel(`VIDEO_KEY_ADDR >> 2);
    reg  x_cbg = 1'b0;    always @(posedge clk) x_cbg <= xsel(`VIDEO_COL_BG_ADDR >> 2);
    reg  x_cfill = 1'b0;  always @(posedge clk) x_cfill <= xsel(`VIDEO_COL_FILL_ADDR >> 2);
    reg  x_ctrace = 1'b0; always @(posedge clk) x_ctrace <= xsel(`VIDEO_COL_TRACE_ADDR >> 2);
    reg  x_cgrid = 1'b0;  always @(posedge clk) x_cgrid <= xsel(`VIDEO_COL_GRID_ADDR >> 2);
    reg  x_curc = 1'b0;   always @(posedge clk) x_curc <= xsel(`VIDEO_CURSOR_CTRL_ADDR >> 2);
    reg  x_curx = 1'b0;   always @(posedge clk) x_curx <= xsel(`VIDEO_CURSOR_X_ADDR >> 2);
    reg  x_curcol = 1'b0; always @(posedge clk) x_curcol <= xsel(`VIDEO_CURSOR_COL_ADDR >> 2);
    // The sweep loads the description registers: enable, mode, framebuffer base and stride, key color, the four colors,
    // the cursor control, position and color.
    always @(posedge clk) begin
        if (x_ctrl)   begin r_en <= x_q3[`VIDEO_CTRL_ENABLE_LSB]; r_m30 <= x_q3[`VIDEO_CTRL_MODE_30HZ_LSB]; end
        if (x_fbbase) r_fbbase   <= x_q3;
        if (x_fbstr)  r_fbstride <= x_q3;
        if (x_key)    r_key      <= x_q3[15:0];
        if (x_cbg)    r_cbg      <= x_q3[23:0];
        if (x_cfill)  r_cfill    <= x_q3[23:0];
        if (x_ctrace) r_ctrace   <= x_q3[23:0];
        if (x_cgrid)  r_cgrid    <= x_q3[23:0];
        if (x_curc)   r_curc     <= x_q3[11:0];
        if (x_curx)   r_curx     <= x_q3[11:0];
        if (x_curcol) r_curcol   <= x_q3[23:0];
    end

    // The registers that exist several times (four windows, two waterfall windows, eight passbands) have a strobe vector
    // sw, sf or sp per instance. The window registers: position, size, control, source column, scale and the two grids.
    genvar i, k;
    generate
        for (i = 0; i < 4; i = i + 1) begin : wr_w
            reg [6:0] sw = 7'd0;
            always @(posedge clk) begin
                sw[0] <= xsel(`VIDEO_WIN_POS_ADDR(i) >> 2);
                sw[1] <= xsel(`VIDEO_WIN_SIZE_ADDR(i) >> 2);
                sw[2] <= xsel(`VIDEO_WIN_CTRL_ADDR(i) >> 2);
                sw[3] <= xsel(`VIDEO_WIN_SRC_ADDR(i) >> 2);
                sw[4] <= xsel(`VIDEO_WIN_SCALE_ADDR(i) >> 2);
                sw[5] <= xsel(`VIDEO_WIN_GRIDX_ADDR(i) >> 2);
                sw[6] <= xsel(`VIDEO_WIN_GRIDY_ADDR(i) >> 2);
                if (sw[0]) r_wpos[32*i +: 32]   <= x_q3;
                if (sw[1]) r_wsize[32*i +: 32]  <= x_q3;
                if (sw[2]) r_wctrl[32*i +: 32]  <= x_q3;
                if (sw[3]) r_wsrc[32*i +: 32]   <= x_q3;
                if (sw[4]) r_wscale[32*i +: 32] <= x_q3;
                if (sw[5]) r_wgx[32*i +: 32]    <= x_q3;
                if (sw[6]) r_wgy[32*i +: 32]    <= x_q3;
            end
        end
        // the two waterfall windows: ring base, line source (hardware or CPU written) and the CPU's scroll line
        for (i = 0; i < 2; i = i + 1) begin : wr_f
            reg [2:0] sf = 3'd0;
            always @(posedge clk) begin
                sf[0] <= xsel(`VIDEO_WF_WIN_RING_ADDR(i) >> 2);
                sf[1] <= xsel(`VIDEO_WF_WIN_CTRL_ADDR(i) >> 2);
                sf[2] <= xsel(`VIDEO_WF_WIN_LINE_ADDR(i) >> 2);
                if (sf[0]) r_wwring[32*i +: 32] <= x_q3;
                if (sf[1]) r_wwsrc[2*i +: 2]    <= x_q3[`VIDEO_WF_WIN_CTRL_LINE_SRC_LSB +: 2];
                if (sf[2]) r_wwline[11*i +: 11] <= x_q3[10:0];
            end
        end
        // the eight passbands: range, control (enable, window mask, alpha) and color
        for (k = 0; k < 8; k = k + 1) begin : wr_p
            reg [2:0] sp = 3'd0;
            always @(posedge clk) begin
                sp[0] <= xsel(`VIDEO_PB_RANGE_ADDR(k) >> 2);
                sp[1] <= xsel(`VIDEO_PB_CTRL_ADDR(k) >> 2);
                sp[2] <= xsel(`VIDEO_PB_COL_ADDR(k) >> 2);
                if (sp[0]) r_pbr[32*k +: 32]    <= x_q3;
                if (sp[1]) r_pbc[32*k +: 32]    <= x_q3;
                if (sp[2]) r_pbcol[24*k +: 24]  <= x_q3[23:0];
            end
        end
    endgenerate

    // ---- read back: every register's value as written lives in a small RAM (initialized with the reset values), and the few
    // read-only words are multiplexed over it. A read takes three clocks, the bridge waits six. The RAM is 32 bits wide
    // and built as 18 bits of block RAM and 14 bits of LUT RAM, which together use less block RAM than a 32-bit-wide
    // block RAM memory would.
    reg [17:0] shmem [0:255];
    (* syn_ramstyle = "distributed_ram" *) reg [13:0] shmem_h [0:255];
`define SHSET(A, V) begin shmem[A] = (V); shmem_h[A] = (V) >> 18; end
    // SHSET writes the two parts of one initial value (kept as a macro, undefined again below)
    reg        rd_ok = 1'b0, rd_ok2 = 1'b0;
    integer ii;
    initial begin
        for (ii = 0; ii < 256; ii = ii + 1) `SHSET(ii, 32'd0);
        `SHSET(`VIDEO_FB_BASE_ADDR >> 2, `VIDEO_FB_BASE_RESET);
        `SHSET(`VIDEO_FB_STRIDE_ADDR >> 2, `VIDEO_FB_STRIDE_RESET);
        `SHSET(`VIDEO_KEY_ADDR >> 2, `VIDEO_KEY_RESET);
        `SHSET(`VIDEO_COL_FILL_ADDR >> 2, `VIDEO_COL_FILL_RESET);
        `SHSET(`VIDEO_COL_TRACE_ADDR >> 2, `VIDEO_COL_TRACE_RESET);
        `SHSET(`VIDEO_COL_GRID_ADDR >> 2, `VIDEO_COL_GRID_RESET);
        `SHSET(`VIDEO_CURSOR_CTRL_ADDR >> 2, `VIDEO_CURSOR_CTRL_RESET);
        `SHSET(`VIDEO_CURSOR_COL_ADDR >> 2, `VIDEO_CURSOR_COL_RESET);
        for (ii = 0; ii < 4; ii = ii + 1)
            `SHSET(`VIDEO_WIN_SCALE_ADDR(ii) >> 2, `VIDEO_WIN_SCALE_RESET);
        for (ii = 0; ii < 8; ii = ii + 1) begin
            `SHSET(`VIDEO_PB_CTRL_ADDR(ii) >> 2, `VIDEO_PB_CTRL_RESET);
            `SHSET(`VIDEO_PB_COL_ADDR(ii) >> 2, `VIDEO_PB_COL_RESET);
        end
    end
`undef SHSET
    // The shadow RAM: a bus write stores its word, and the read port serves the bus read, or the sweep when no bus read is
    // active. The read-only words (id, status and counters, writers' line numbers, the scroll line of each waterfall
    // window) come from signals and are multiplexed over the RAM's data by address.
    always @(posedge clk) begin
        if (vw) begin
            shmem[wi]   <= d_q[17:0];
            shmem_h[wi] <= d_q[31:18];
        end
        sh_rd  <= {shmem_h[rd_wi], shmem[rd_wi]};
        rd_wi  <= bus_sel ? bus_addr[9:2] : sw_i;
        rd_wi2 <= rd_wi;
        rd_ok  <= (bus_addr[15:10] == 6'd0);
        rd_ok2 <= rd_ok;
        if (brw_q) case (rd_wi2)       // only while a bus read has the port
            (`VIDEO_ID_ADDR >> 2):             bus_rdata <= rd_ok2 ? `VIDEO_ID_RESET : 32'd0;
            (`VIDEO_WF_WRITE_LINE_ADDR >> 2):  bus_rdata <= rd_ok2 ? {21'd0, wf_write_line} : 32'd0;
            (`VIDEO_STATUS_ADDR >> 2):         bus_rdata <= rd_ok2 ? {30'd0, st_laneerr, st_underrun} : 32'd0;
            (`VIDEO_UNDERRUN_COUNT_ADDR >> 2): bus_rdata <= rd_ok2 ? st_ucount : 32'd0;
            (`VIDEO_FRAME_COUNT_ADDR >> 2):    bus_rdata <= rd_ok2 ? st_fcount : 32'd0;
            (`VIDEO_FB_ACTIVE_ADDR >> 2):      bus_rdata <= rd_ok2 ? st_fbact : 32'd0;
            (`VIDEO_WF_ZOOM_WRITE_LINE_ADDR >> 2): bus_rdata <= rd_ok2 ? {21'd0, zwf_write_line} : 32'd0;
            (`VIDEO_WF_WIN_TOP_ADDR(0) >> 2):  bus_rdata <= rd_ok2 ? {21'd0, st_wftop[10:0]} : 32'd0;
            (`VIDEO_WF_WIN_TOP_ADDR(1) >> 2):  bus_rdata <= rd_ok2 ? {21'd0, st_wftop[21:11]} : 32'd0;
            default:                           bus_rdata <= rd_ok2 ? sh_rd : 32'd0;
        endcase
    end

    // ---- the description: the registers themselves, and one register stage `der` for the derived values (sums, clamps),
    // which follows them all the time. `snap` is steady from snap_rdy of one frame until `cap` of the next. Fields that are
    // just a register are assigned straight to `snap`; the derived ones (window right and bottom edge, height minus 1,
    // cursor end, passband alpha limit, window enable) go through `der`.
    wire [`CF_W-1:0] live_c;
    reg  [`CF_W-1:0] der = {`CF_W{1'b0}};   // only the derived fields are read; the rest is removed
    always @(posedge clk) der <= live_c;

        // per window: window enable (enable bit and a size above 0), type, source, position and edges. The window right edge
        // is x + width and the bottom edge y + height (one past the last column and row), height minus 1 is the last row.
    generate
        for (i = 0; i < 4; i = i + 1) begin : lw
            wire [31:0] pos = r_wpos[32*i +: 32];
            wire [31:0] siz = r_wsize[32*i +: 32];
            wire [31:0] ctl = r_wctrl[32*i +: 32];
            wire [31:0] src = r_wsrc[32*i +: 32];
            wire [31:0] scl = r_wscale[32*i +: 32];
            wire [31:0] gx  = r_wgx[32*i +: 32];
            wire [31:0] gy  = r_wgy[32*i +: 32];
            assign snap[`CF_WEN_L + i] = der[`CF_WEN_L + i];
            assign live_c[`CF_WEN_L + i]  = ctl[`VIDEO_WIN_CTRL_ENABLE_LSB] & (siz[11:0] != 12'd0) & (siz[26:16] != 11'd0);
            assign snap[`CF_WF_L + i]   = (i < 2) ? ctl[`VIDEO_WIN_CTRL_TYPE_WATERFALL_LSB] : 1'b0;
            assign snap[`CF_WZ_L + i]   = ctl[`VIDEO_WIN_CTRL_SOURCE_ZOOM_LSB];
            assign snap[`CF_WX_L  + 12*i +: 12] = pos[11:0];
            assign snap[`CF_WXE_L + 12*i +: 12] = der[`CF_WXE_L + 12*i +: 12];
            assign live_c[`CF_WXE_L + 12*i +: 12] = pos[11:0] + siz[11:0];
            assign snap[`CF_WY_L  + 11*i +: 11] = pos[26:16];
            assign snap[`CF_WYE_L + 11*i +: 11] = der[`CF_WYE_L + 11*i +: 11];
            assign live_c[`CF_WYE_L + 11*i +: 11] = pos[26:16] + siz[26:16];
            assign snap[`CF_WSX0_L + 12*i +: 12] = src[11:0];
            assign snap[`CF_WHM1_L + 11*i +: 11] = der[`CF_WHM1_L + 11*i +: 11];
            assign live_c[`CF_WHM1_L + 11*i +: 11] = siz[26:16] - 11'd1;
            assign snap[`CF_WREF_L + 16*i +: 16]  = scl[15:0];
            assign snap[`CF_WGAIN_L + 16*i +: 16] = scl[31:16];
            assign snap[`CF_WGXF_L + 12*i +: 12] = gx[11:0];
            assign snap[`CF_WGXS_L + 12*i +: 12] = gx[27:16];
            assign snap[`CF_WGYF_L + 12*i +: 12] = gy[11:0];
            assign snap[`CF_WGYS_L + 12*i +: 12] = gy[27:16];
        end
        // per waterfall window: the first source word and the number of words of its line that the fetch engine reads. The
        // first word is the source column / 8 (8 pixels per 64-bit word); the last is the column of the window's right edge
        // / 8 limited to 239 (the end of the 1,920-byte line), so that n = last - first + 1, or 0 if the window starts beyond
        // the line. Done in a few pipeline steps because it is only needed once per frame.
        for (i = 0; i < 2; i = i + 1) begin : lf
            wire [31:0] siz = r_wsize[32*i +: 32];
            wire [31:0] src = r_wsrc[32*i +: 32];
            reg  [12:0] sum = 13'd0;
            reg  [7:0]  fw0 = 8'd0, fw1 = 8'd0;
            reg  [7:0]  lastw = 8'd0;
            reg  [8:0]  n = 9'd0;
            always @(posedge clk) begin
                sum   <= {1'b0, src[11:0]} + {1'b0, siz[11:0]} - 13'd1;           // last source column + 1 - 1
                fw0   <= src[10:3];
                lastw <= (sum[12:3] > 10'd239) ? 8'd239 : sum[10:3];
                fw1   <= fw0;
                n     <= (lastw >= fw1) ? ({1'b0, lastw} - {1'b0, fw1} + 9'd1) : 9'd0;
            end
            assign snap[`CF_WFW0_L + 8*i +: 8] = fw1;
            assign snap[`CF_WFN_L + 9*i +: 9]  = n;
        end
    endgenerate
    // colors, key color, enable, and the cursor: its width in pixels (0 counts as 1) is added to the first column for the end
    assign snap[`CF_CBG_L +: 24]    = r_cbg;
    assign snap[`CF_CFILL_L +: 24]  = r_cfill;
    assign snap[`CF_CTRACE_L +: 24] = r_ctrace;
    assign snap[`CF_CGRID_L +: 24]  = r_cgrid;
    assign snap[`CF_KEY_L +: 16]    = r_key;
    assign snap[`CF_EN_L]           = r_en;
    assign snap[`CF_CUREN_L]        = r_curc[`VIDEO_CURSOR_CTRL_ENABLE_LSB];
    assign snap[`CF_CURWM_L +: 4]   = r_curc[`VIDEO_CURSOR_CTRL_WINDOW_MASK_LSB +: 4];
    assign snap[`CF_CURX_L +: 12]   = r_curx;
    assign snap[`CF_CURXE_L +: 12] = der[`CF_CURXE_L +: 12];
    assign live_c[`CF_CURXE_L +: 12]  = r_curx + ((r_curc[`VIDEO_CURSOR_CTRL_WIDTH_LSB +: 4] == 4'd0) ? 12'd1 : {8'd0, r_curc[`VIDEO_CURSOR_CTRL_WIDTH_LSB +: 4]});
    assign snap[`CF_CURCOL_L +: 24] = r_curcol;
    // per passband: enable, window mask, column range, alpha (limited to 16 sixteenths) and color
    generate
        for (k = 0; k < 8; k = k + 1) begin : lp
            wire [31:0] rng = r_pbr[32*k +: 32];
            wire [31:0] ctl = r_pbc[32*k +: 32];
            wire [4:0]  al  = ctl[`VIDEO_PB_CTRL_ALPHA_LSB +: 5];
            assign snap[`CF_PBEN_L + k] = ctl[`VIDEO_PB_CTRL_ENABLE_LSB];
            assign snap[`CF_PBWM_L + 4*k +: 4] = ctl[`VIDEO_PB_CTRL_WINDOW_MASK_LSB +: 4];
            assign snap[`CF_PBX0_L + 12*k +: 12] = rng[11:0];
            assign snap[`CF_PBX1_L + 12*k +: 12] = rng[27:16];
            assign snap[`CF_PBAL_L + 5*k +: 5] = der[`CF_PBAL_L + 5*k +: 5];
            assign live_c[`CF_PBAL_L + 5*k +: 5]   = (al > 5'd16) ? 5'd16 : al;
            assign snap[`CF_PBCOL_L + 24*k +: 24] = r_pbcol[24*k +: 24];
        end
    endgenerate
    // framebuffer base and stride as 64-bit word values (byte address / 8, stride / 8)
    assign snap[`CF_FBW_L +: `CF_FBW_W]     = r_fbbase[31:3];
    assign snap[`CF_FBSW_L +: `CF_FBSW_W]   = r_fbstride[22:3];
    // each waterfall window: its own ring and its scroll line from the full-band writer, the zoom writer or the CPU
    generate
        for (i = 0; i < 2; i = i + 1) begin : lr
            wire [1:0] src = r_wwsrc[2*i +: 2];
            assign snap[`CF_WFRING_L + 32*i +: 32] = r_wwring[32*i +: 32];
            // the scroll line is taken once per frame (the writers' lines move while a frame is drawn), at the moment top_ld
            // says so, a few clocks before the description is complete
            reg [10:0] top_q = 11'd0;
            always @(posedge clk)
                if (top_ld[i]) top_q <= src[1] ? r_wwline[11*i +: 11] : src[0] ? zwf_write_line : wf_write_line;
            assign snap[`CF_WLTOP_L + 11*i +: 11] = top_q;
        end
    endgenerate
    // the framebuffer base also as a byte address, which the register fb_active reads back
    assign snap[`CF_FBBYTE_L +: 32]         = r_fbbase;


endmodule

// ================================================================================ compositor
// compositor: the top. It holds the clock crossings, the frame sequencing, the line buffer memories and the spectrum snapshot
// copy, and instantiates the register file, the fetch engine and the pixel pipeline.
module compositor #(
    parameter integer W         = 1920,  // visible pixels per line
    parameter integer H         = 1080,  // visible lines per frame
    parameter integer FW        = 2200,  // total pixels per line including blanking, as the HDMI core counts them
    parameter integer FH        = 1125,  // total lines per frame including blanking
    parameter integer VCAP      = 1082,  // line at which the description for the next frame is requested (in the vertical blanking)
    parameter integer ZOOM_SNAP = 0,  // 1 = the spectrum snapshot also holds the zoom line (the snapshot RAM becomes twice as large)
    parameter integer BURST     = 160  // words per DDR3 read burst, the longest burst the fetch engine requests
) (
    input  wire         clk,                // clk_dsp
    input  wire         rst,  // synchronous reset in clk_dsp
    input  wire         clk_pix,  // pixel clock, 74.17 MHz
    input  wire [11:0]  cx,  // column the HDMI core is asking a pixel for, in clk_pix
    input  wire [10:0]  cy,  // line the HDMI core is asking a pixel for, in clk_pix
    output wire [23:0]  rgb,                // clk_pix: the pixel for (cx, cy), in the same clock
    // register page 0x07 (video), in clk_dsp
    input  wire         bus_wr,
    input  wire         bus_rd,
    input  wire [15:0]  bus_addr,
    input  wire [31:0]  bus_wdata,
    output wire [31:0]  bus_rdata,
    // video tier of the DDR3 read arbiter (the convention of rtl/ddr3/ddr3_read_arbiter.v)
    output wire         rd_req,
    output wire [31:0]  rd_addr,
    output wire [7:0]   rd_burstlen,
    input  wire         rd_gnt,
    input  wire         rd_rvalid,
    input  wire [63:0]  rd_rdata,
    input  wire         rd_done,
    // spectrum line buffers (full band, zoom) of the spectrum pipeline, with synchronous read in clk: the address goes out
    // and the 16-bit level (signed, 1/64 dB) is on the data input one clock later
    output reg  [10:0]  line_rd_addr,
    input  wire [15:0]  line_rd_data,
    output reg  [10:0]  zline_rd_addr,
    input  wire [15:0]  zline_rd_data,
    // the two hardware waterfall writers (full band, zoom, rtl/video/waterfall_writer.v): where each one's ring is, and
    // the last line each has finished. The ring and the scroll line of a waterfall window are registers of their own.
    output wire [31:0]  wf_ring_base,
    input  wire [10:0]  wf_write_line,
    output wire [31:0]  zwf_ring_base,
    input  wire [10:0]  zwf_write_line,
    // frame start: one clk pulse per frame (interrupt line 8), for the firmware to pace its drawing
    output reg          frame_start
);
    // SPAW: address bits of the spectrum snapshot RAM, 11 for the 1,920 columns of the full-band line and one more when the
    // zoom line is stored too.
    localparam integer SPAW = 11 + ZOOM_SNAP;

    // ---------------------------------------------------------------- crossings
    // Toggle bits from the pixel side (cap_tog, fs_tog, ur_tog) and the gray coded line counter go through synchronizers in clk;
    // ack_tog and the fetch engine's done_gray go the other way into clk_pix. A pulse is made from a toggle by comparing the
    // last two stages.
    wire         cap_tog, fs_tog, ur_tog;
    wire [10:0]  cy_gray_p;
    wire [10:0]  done_gray_d;
    reg          ack_tog = 1'b0;
    reg  [2:0]   cap_s /* synthesis syn_preserve = 1 */;
    reg  [2:0]   fs_s  /* synthesis syn_preserve = 1 */;
    reg  [2:0]   ur_s  /* synthesis syn_preserve = 1 */;
    reg  [10:0]  cyg_s1 /* synthesis syn_preserve = 1 */;
    reg  [10:0]  cyg_s2 /* synthesis syn_preserve = 1 */;
    initial begin cap_s = 3'd0; fs_s = 3'd0; ur_s = 3'd0; cyg_s1 = 11'd0; cyg_s2 = 11'd0; end
    always @(posedge clk) begin
        cap_s  <= {cap_s[1:0], cap_tog};
        fs_s   <= {fs_s[1:0], fs_tog};
        ur_s   <= {ur_s[1:0], ur_tog};
        cyg_s1 <= cy_gray_p;
        cyg_s2 <= cyg_s1;
        frame_start <= fs_s[2] ^ fs_s[1];
    end
    wire cap_pulse = cap_s[2] ^ cap_s[1];
    wire ur_pulse  = ur_s[2] ^ ur_s[1];

    reg [2:0]  ack_s /* synthesis syn_preserve = 1 */;
    reg [10:0] dg_s1 /* synthesis syn_preserve = 1 */;
    reg [10:0] dg_s2 /* synthesis syn_preserve = 1 */;
    initial begin ack_s = 3'd0; dg_s1 = 11'd0; dg_s2 = 11'd0; end
    always @(posedge clk_pix) begin
        ack_s <= {ack_s[1:0], ack_tog};
        dg_s1 <= done_gray_d;
        dg_s2 <= dg_s1;
    end
    wire load_pix = ack_s[2] ^ ack_s[1];

    // ---------------------------------------------------------------- registers
    // The register file and the signals around it: the picture description `snap` (clk_dsp copy) and `cfg` (clk_pix copy), the
    // palette write port, the counters and the sticky status flags.
    wire [`CF_W-1:0] snap, cfg;
    wire             snap_rdy;
    wire             clr_ur, clr_le;
    wire             pal_we;
    wire [8:0]       pal_wa;
    wire [23:0]      pal_wd;
    wire [31:0]      ucount, fcount;
    reg              fc_inc = 1'b0, ur_inc = 1'b0;
    reg              st_ur = 1'b0, st_le = 1'b0;
    wire             lane_err;
    wire [21:0]      wftop = snap[`CF_WLTOP_L +: 22];
    wire [31:0]      fbact = snap[`CF_FBBYTE_L +: 32];
    wire             snap_en = snap[`CF_EN_L];

    compositor_regs u_regs (
        .clk(clk), .bus_wr(bus_wr), .bus_rd(bus_rd), .bus_addr(bus_addr), .bus_wdata(bus_wdata),
        .bus_rdata(bus_rdata),
        .st_ucount(ucount), .st_fcount(fcount), .st_fbact(fbact), .st_wftop(wftop),
        .st_underrun(st_ur), .st_laneerr(st_le), .wf_write_line(wf_write_line),
        .zwf_write_line(zwf_write_line),
        .clr_underrun(clr_ur), .clr_laneerr(clr_le),
        .cap(cap_pulse), .snap_rdy(snap_rdy), .snap(snap), .wf_ring_base(wf_ring_base), .zwf_ring_base(zwf_ring_base),
        .pal_we(pal_we), .pal_wa(pal_wa), .pal_wd(pal_wd)
    );

    // Frame sequencing. snap_rdy starts a short sequence counted by `seq`: at step 6 the frame counter goes up and the
    // spectrum copy starts, at step 7 the acknowledge toggle ack_tog flips (so the pixel side loads its copy while the
    // spectrum copy is still running, which is fine because the copy goes to its own RAM). The status flags are set by an
    // underrun pulse (while the compositor is enabled) or a lane error and cleared by the bus.
    reg [3:0] seq = 4'd0;
    reg       cp_start = 1'b0;
    always @(posedge clk) begin
        cp_start <= 1'b0;
        fc_inc   <= 1'b0;
        ur_inc   <= ur_pulse & snap_en;
        if (snap_rdy) seq <= 4'd1;
        else if (seq != 4'd0) begin
            seq <= (seq == 4'd8) ? 4'd0 : seq + 4'd1;
            if (seq == 4'd6) begin
                fc_inc   <= 1'b1;
                cp_start <= 1'b1;
            end
            if (seq == 4'd7) ack_tog <= ~ack_tog;
        end
        if (ur_pulse && snap_en) st_ur <= 1'b1;
        if (lane_err) st_le <= 1'b1;
        if (clr_ur) st_ur <= 1'b0;
        if (clr_le) st_le <= 1'b0;
    end

    // The frame counter and the underrun counter (cleared by the status write).
    comp_cnt32 u_fcnt (.clk(clk), .inc(fc_inc), .clr(1'b0),   .q(fcount));
    comp_cnt32 u_ucnt (.clk(clk), .inc(ur_inc), .clr(clr_ur), .q(ucount));

    // The frame copy of the description into clk_pix, under the pulse load_pix.
    comp_xfer #(.W(`CF_W)) u_xfer (
        .snap(snap), .clk_b(clk_pix), .load_b(load_pix), .cfg(cfg)
    );

    // ---------------------------------------------------------------- spectrum snapshot copy
    // Runs after the frame copy, in the vertical blanking: reads the spectrum line buffer (and the zoom one) once from start to
    // end into a RAM of our own, so that the pixel side, which runs in another clock, reads a line that holds still for the
    // whole frame. cp_n counts the entries; the address goes out as line_rd_addr, the data comes one clock later, and the
    // registered copies cp_a1 and cp_a2 and cp_v1 and cp_v2 carry the address and the valid flag along so that the write
    // address matches the data.
    reg [11:0] cp_n = 12'd0;
    reg        cp_run = 1'b0;
    reg [11:0] cp_a1 = 12'd0, cp_a2 = 12'd0;
    reg        cp_v1 = 1'b0, cp_v2 = 1'b0;
    reg        sp_we = 1'b0;
    reg [SPAW-1:0] sp_wa = {SPAW{1'b0}};
    reg [15:0] sp_wd = 16'd0;
    // number of entries to copy minus 1: W for the full-band line, 2 W with the zoom line
    localparam integer CP_LAST = W * (1 + ZOOM_SNAP) - 1;
    always @(posedge clk) begin
        cp_v1 <= cp_run;
        cp_v2 <= cp_v1;
        cp_a1 <= cp_n;
        cp_a2 <= cp_a1;
        if (cp_start) begin cp_run <= 1'b1; cp_n <= 12'd0; end
        else if (cp_run) begin
            if (cp_n == CP_LAST) cp_run <= 1'b0;
            cp_n <= cp_n + 12'd1;
        end
        // the full-band line is read for the first W entries and the zoom line for the next W
        line_rd_addr  <= (cp_n >= W) ? 11'd0 : cp_n[10:0];
        zline_rd_addr <= (cp_n >= W) ? (cp_n - W) : 11'd0;
        // The data of address cp_a1 is on line_rd_data one clock after it was presented. The zoom line is stored from word
        // 2,048 up, which is why the write address gets 2,048 - W added once the count is past W.
        sp_we <= cp_v2;
        sp_wa <= cp_a2[SPAW-1:0] + ((ZOOM_SNAP != 0 && cp_a2 >= W) ? (12'd2048 - W) : 12'd0);
        sp_wd <= (cp_a2 >= W && ZOOM_SNAP != 0) ? zline_rd_data : line_rd_data;
    end

    // ---------------------------------------------------------------- fetch engine and memories
    // The fetch engine writes its words into the three line buffers through one shared data bus (wdat) with a write enable per
    // buffer.
    wire [63:0] wdat;
    wire        sl_we, wf0_we, wf1_we;
    wire [9:0]  sl_wa;
    wire [8:0]  wf_wa;
    wire [10:0] done_gray_w;
    wire        rq;
    wire [31:0] ra;
    wire [7:0]  rl;

    compositor_fetch #(.W(W), .H(H), .FH(FH), .BURST(BURST)) u_fetch (
        .clk(clk), .rst(rst), .snap(snap), .cy_gray(cyg_s2), .done_gray(done_gray_w),
        .rd_req(rq), .rd_addr(ra), .rd_burstlen(rl), .rd_gnt(rd_gnt), .rd_rvalid(rd_rvalid),
        .rd_rdata(rd_rdata),
        .wdat(wdat), .sl_we(sl_we), .sl_wa(sl_wa), .wf0_we(wf0_we), .wf1_we(wf1_we), .wf_wa(wf_wa),
        .lane_err(lane_err)
    );
    assign rd_req = rq;
    assign rd_addr = ra;
    assign rd_burstlen = rl;
    assign done_gray_d = done_gray_w;

    // The memories (comp_ram, block RAM unless noted): the GUI line buffer is 1,024 words of 64 bits (two lines of 512 words),
    // the waterfall line buffers 1,024 words of 64 bits for both windows together, the spectrum snapshot 2,048 words of 16
    // bits (2 x that with the zoom line) and the palette 512 entries of 24 bits. Each is written in clk (by the fetch engine or
    // the register file) and read in clk_pix.
    wire [9:0]  sl_ra;
    wire [63:0] sl_rd, wf_rd;
    wire [SPAW-1:0] sp_ra;
    wire [15:0] sp_rd;
    wire [9:0]  wf_ra;
    wire [8:0]  pal_ra;
    wire [23:0] pal_rd;

    comp_ram #(.DW(64), .AW(10)) u_slint (.clk_w(clk), .we(sl_we), .wa(sl_wa), .wd(wdat),
                                          .clk_r(clk_pix), .ra(sl_ra), .rd(sl_rd));
    // The two waterfall line buffers share one 1,024 x 64 memory, window 1's line in the upper half (address bit 9). The pixel
    // side reads one of them per pixel, never both, and the fetch engine never writes both halves in the same clock, since it
    // fetches for one destination at a time.
    comp_ram #(.DW(64), .AW(10)) u_wf (.clk_w(clk), .we(wf0_we | wf1_we), .wa({wf1_we, wf_wa}), .wd(wdat),
                                       .clk_r(clk_pix), .ra(wf_ra), .rd(wf_rd));
    comp_ram #(.DW(16), .AW(SPAW)) u_spec (.clk_w(clk), .we(sp_we), .wa(sp_wa), .wd(sp_wd),
                                           .clk_r(clk_pix), .ra(sp_ra), .rd(sp_rd));
    // The 24-bit palette is split into 18 bits of block RAM and 6 bits of LUT RAM: the same 24 bits in a single memory would take
    // two blocks and waste most of the second.
    comp_ram #(.DW(18), .AW(9)) u_pal (.clk_w(clk), .we(pal_we), .wa(pal_wa), .wd(pal_wd[17:0]),
                                       .clk_r(clk_pix), .ra(pal_ra), .rd(pal_rd[17:0]));
    comp_ram #(.DW(6), .AW(9), .LUT(1)) u_palh (.clk_w(clk), .we(pal_we), .wa(pal_wa), .wd(pal_wd[23:18]),
                                       .clk_r(clk_pix), .ra(pal_ra), .rd(pal_rd[23:18]));

    // ---------------------------------------------------------------- pixel pipeline
    compositor_pix #(.W(W), .H(H), .FW(FW), .FH(FH), .VCAP(VCAP), .ZOOM(ZOOM_SNAP)) u_pix (
        .clk(clk_pix), .cx(cx), .cy(cy), .cfg(cfg),
        .sl_ra(sl_ra), .sl_rd(sl_rd), .sp_ra(sp_ra), .sp_rd(sp_rd), .wf_ra(wf_ra),
        .wf_rd(wf_rd), .pal_ra(pal_ra), .pal_rd(pal_rd),
        .rgb(rgb),
        .cap_tog(cap_tog), .load(load_pix), .fs_tog(fs_tog), .cy_gray(cy_gray_p),
        .done_gray(dg_s2), .ur_tog(ur_tog)
    );

endmodule
