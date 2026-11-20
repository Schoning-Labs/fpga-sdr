// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// spectrum_pipeline: everything between the ADC samples and the spectrum and waterfall lines, for the
// full-band spectrum and for the zoom spectrum, which share one column-walk engine (docs/ARCHITECTURE.md
// 3.14 change C6d; docs/F2_SPECTRUM.md, docs/F3_ZOOM.md). The terms (FFT, bin, window, dB, waterfall,
// peak hold) are explained in docs/learn/GLOSSARY.md.
//
// Full-band side: window (spectrum_window.v) -> FFT (rtl/fft/fft_r22sdf.v, 16,384 points, one transform
// per 16,384 samples, 4,687.5 per second, 4.6875 kHz per bin) -> power -> per-column reduction (the bins
// that fall in one of the 1,920 screen columns are reduced to one value, by their maximum so that narrow
// carriers stay visible, or by their sum for the mean) -> K-frame averaging or peak hold -> dB -> one
// line buffer and a waterfall byte stream. Register interface: hw/regmap/spectrum.toml.
//   - Power: the 29-bit FFT outputs are rounded down by RSH = 8 bits to 21 bits (saturating), squared
//     and added, which gives a 42-bit power word. Only bins below NUM_BINS = 6400 (0 to 30 MHz) are
//     used, and only the even out_index words (the odd ones are the mirror half of a real input's
//     spectrum).
//   - Columns: bin -> column is bin x 3/10 (1,920 columns for 6,400 bins), done as a multiply and a
//     shift. The first bin of a column in arrival order starts it afresh; the others are added or
//     compared into the per-frame column accumulator (44 bits, up to 4 bins). The FFT delivers its bins
//     in bit-reversed order, so the bins of one column arrive thousands of samples apart.
//   - K-frame average: when a frame has been collected, one walk of the shared engine adds the column
//     accumulators into the K-frame accumulators (48 bits, saturating) and, on every K-th frame, turns
//     sum / (K x bins) into dB (1/64 dB units) with spectrum_ratio_db.v. With peak hold the engine keeps
//     the larger value instead and the divisor is 1.
//   - Output: the 16-bit dB values go into the line buffer that the compositor reads, and the waterfall
//     byte is clamp(((dB x 64 + level_offset) x level_gain) >> 14), with level_gain an unsigned Q8.8, so
//     a gain of 1.0 is one color step per dB.
//
// Zoom side: takes the complex bin stream of the zoom FFT (from rtl/zoom/zoom_spectrum.v, or, with
// ZOOM_SHARED = 1, from the second stream of this module's own FFT, see below) and runs the same shape
// over the zoom's own 1,920 screen columns (3,277 usable bins per docs/F3_ZOOM.md section 6). The log-domain
// K-average and the leading-one/LUT log2 estimator (rtl/spectrum/spectrum_ratio_db.v, rtl/spectrum/log2_core.v)
// are shared through rtl/spectrum/spectrum_walk_core.v, one instance serving whichever stream's frame
// completes next; each stream keeps its own column buffer, K-frame accumulator, line buffer and column
// tables, and only the walk engine (dB conversion) and the waterfall color formula are shared hardware.
// Register interface of the zoom side's backend_* fields: hw/regmap/zoom.toml (it shares that block's page
// with the zoom DDC's own phase_inc, ctrl.enable and ctrl.span_shift, which this module does not touch:
// see "Register bus note" below).
//
// Two things distinguish the full-band side from the zoom side in structure: the per-frame column
// accumulator is a single buffer plus an arrival FIFO (1,024 entries; see FIFO_AW below), and the window
// ROM stores every 8th sample and interpolates. A FIFO is needed with a single buffer, because the shared
// walk engine can leave a context waiting for the engine to be free, and a bin that arrives while the walk
// is reading the buffer would otherwise corrupt columns that have not been read yet.
//
// Full design notes, buffering and timing-margin analysis: docs/F2_SPECTRUM.md ("How it works"),
// docs/F3_ZOOM.md.

`timescale 1ns / 1ps

`include "hw/regmap/generated/spectrum_regs.vh"
`include "hw/regmap/generated/zoom_regs.vh"
`include "rtl/fft/fft_delay.v"
`include "rtl/fft/fft_bf.v"
`include "rtl/fft/fft_mul.v"
`include "rtl/fft/fft_twmul.v"
`include "rtl/fft/fft_r22sdf.v"
`include "rtl/spectrum/spectrum_window.v"
`include "rtl/spectrum/spectrum_walk_core.v"
`include "rtl/zoom/zoom_lutram.v"

module spectrum_pipeline #(
    parameter TW_DIR     = "rtl/spectrum/tw/",
    parameter FFT_TW_DIR = "rtl/fft/tw/",
    parameter ZTW_DIR    = "rtl/zoom/",
    // 1 (the chip with the zoom, docs/ZOOM_FIT.md section 2): the zoom has no FFT of its own. Its frames of
    // 4,096 windowed samples come in on zfr_* and go through the last twelve stages of the whole-band FFT,
    // between two whole-band frames; the zoom context takes its bins from there and zoom_in_* is not used.
    // The whole-band FFT then runs whenever samples arrive (ctrl.enable gates the power stage only), so a
    // whole-band view that is switched off cannot hold up the zoom. 0: the zoom bins come on zoom_in_*.
    parameter integer ZOOM_SHARED = 0
) (
    input  wire                clk,          // clk_dsp, 120 MHz
    input  wire                rst,          // synchronous reset

    // ---- full-band side: ADC stream ----
    input  wire signed [11:0]  adc_data,     // the HL2 sample stream
    input  wire                adc_valid,    // one-clock pulse per sample

    // full-band register bus: byte offset within the spectrum block's page
    input  wire                reg_wr,
    input  wire                reg_rd,
    input  wire [15:0]         reg_addr,
    input  wire [31:0]         reg_wdata,
    output reg  [31:0]         reg_rdata,
    output wire                irq_line_done, // a full-band line is finished and not yet acknowledged

    // full-band spectrum line buffer read port (for the video compositor); synchronous read, 1-cycle
    // latency; a read of the column being written in the same clock gets the new word
    input  wire [10:0]         line_rd_addr,  // column
    output reg  [15:0]         line_rd_data,  // dB value, signed, 1/64 dB

    // full-band waterfall byte stream (for the waterfall writer): one byte per column, no
    // back-pressure (same convention as the IQ writer, ARCHITECTURE 3.2)
    output reg                 wf_valid,      // a byte is on wf_data
    output reg                 wf_sol,        // the byte is the first of a line
    output reg                 wf_eol,        // the byte is the last of a line
    output reg  [7:0]          wf_data,       // color index

    // ---- zoom side: raw complex bin stream from rtl/zoom/zoom_spectrum.v ----
    input  wire                 zoom_in_valid,   // an FFT word is valid
    input  wire                 zoom_in_first,   // the first word of a frame
    input  wire [11:0]          zoom_in_bin,      // LOG_N = 12 -> 4,096 bins
    input  wire                 zoom_in_usable,  // the bin is within the displayed 80 percent
    input  wire signed [28:0]   zoom_in_re,       // WIN_OUT_W(17) + LOG_N(12) = 29
    input  wire signed [28:0]   zoom_in_im,

    // ---- zoom side with ZOOM_SHARED = 1: frames from rtl/zoom/zoom_frame.v ----
    input  wire                 zfr_ready,        // a frame of 4,096 samples waits
    output reg                  zfr_go,           // one clock: play it (4,096 words on consecutive clocks)
    input  wire                 zfr_valid,        // a word of the frame is on zfr_re/zfr_im
    input  wire                 zfr_last,         // with the last word
    input  wire signed [15:0]   zfr_re,
    input  wire signed [15:0]   zfr_im,

    // zoom backend register bus: byte offset within the zoom block's page (hw/regmap/zoom.toml).
    // Register bus note: this port only decodes and responds to the backend_* fields (ctrl bits 4:5,
    // backend_averaging_k, backend_level, backend_line_count, backend_line_status); a write to
    // ctrl's enable/span_shift bits (owned by the zoom DDC elsewhere) passes through unrecognized here,
    // and a read of ctrl returns only bits 4:5 with the rest zero. The top level that wires both
    // blocks to the same physical page combines the two read words (rtl/zoom/zoom_frontend.v answers
    // for the DDC's own fields).
    input  wire                 zreg_wr,
    input  wire                 zreg_rd,
    input  wire [15:0]          zreg_addr,
    input  wire [31:0]          zreg_wdata,
    output reg  [31:0]          zreg_rdata,
    output wire                 zirq_line_done,   // a zoom line is finished and not yet acknowledged

    // zoom spectrum line buffer read port
    input  wire [10:0]          zline_rd_addr,
    output wire [15:0]          zline_rd_data,

    // zoom waterfall byte stream (as the full band's)
    output reg                  zwf_valid,
    output reg                  zwf_sol,
    output reg                  zwf_eol,
    output reg  [7:0]           zwf_data
) /* synthesis syn_srlstyle = "registers" */;

    localparam integer LOG_N     = 14;
    localparam integer N         = 1 << LOG_N;         // 16384
    localparam integer FFT_IW    = 15;
    localparam integer FFT_OW    = FFT_IW + LOG_N;      // 29
    // Truncation shift before squaring (docs/F2_SPECTRUM.md "Why 40 bits became 48"): RSH = 8,
    // shared by both the full-band and zoom power stages (the zoom FFT's output happens to be the
    // same 29-bit width, 17 + 12, so every constant in this section applies unchanged to the zoom
    // side).
    localparam integer RSH       = 8;
    localparam integer SQ_W      = FFT_OW - RSH;        // 21: truncated component width before squaring
    localparam integer POW_W     = 42;                  // per-bin power width (2 * 2^(SQ_W-1) squared)
    localparam integer ACCW1     = 44;                  // within-frame column accumulator (up to 4 bins)
    localparam integer ACCW2     = 48;                  // K-frame accumulator, saturates rather than wraps
    localparam integer NUM_BINS  = 6400;                // 0-30 MHz
    localparam integer NUM_COLS  = 1920;
    localparam integer COL_MULT  = 157287;              // 3 * 52429: bin*3/10 via multiply-shift
    localparam integer COL_SHIFT = 19;
    localparam integer DIV_W     = 23;                  // K (clamped 20 bit) * bins-in-col (2..4)
    // Arrival FIFO depth. While the shared engine walks a context's column buffer, bins of the next
    // frame keep arriving and are queued instead of being written. The full-band side's worst case is
    // exact and deterministic: NUM_COLS * NUM_BINS / N = 1920 * 6400 / 16384 = 750 bins during one walk
    // (bin arrival times depend only on the FFT's fixed bit-reversal structure, not on the input
    // signal, so this is the same every walk and not a statistical estimate); see docs/F2_SPECTRUM.md
    // "Why the arrival FIFO is 1,024 deep, not 512" (a 512-entry FIFO silently wraps and corrupts
    // columns). 1,024 is the next power of two above 750, with margin.
    //
    // The zoom side's worst case is far smaller: its front end sees a new bin only once every several
    // tens of `clk_dsp` cycles (the DDC's own decimated rate, at least 20 even at the widest span),
    // not every 2.6 or so, so at most about 1,920/20 = 96 bins can arrive during a walk. It gets its own,
    // much shallower FIFO (128 entries, comfortable margin over 96), which saves block RAM against
    // sharing the full-band side's 1,024.
    localparam integer FIFO_AW   = 10;                  // 1,024-entry arrival FIFO (full-band)
    localparam integer FIFO_N    = 1 << FIFO_AW;
    localparam integer ZFIFO_AW  = 7;                   // 128-entry arrival FIFO (zoom)
    localparam integer ZFIFO_N   = 1 << ZFIFO_AW;
    localparam integer FIFO_W    = 11 + 1 + POW_W;      // {col_idx[10:0], is_first, power[POW_W-1:0]}

    // Zoom column mapping constants (tools/gen_spectrum_tables.py gen_zoom_column_tables(); they must
    // be kept in sync with that script if ZOOM_NUM_COLS or ZOOM_NUM_BINS change there).
    localparam integer ZLOG_N        = 12;
    localparam integer ZN            = 1 << ZLOG_N;      // 4096
    localparam integer Z_USABLE_HALF = 1638;
    localparam integer Z_NUM_COLS    = 1920;
    localparam integer Z_COL_MULT    = 614363;
    localparam integer Z_COL_SHIFT   = 20;
    // Zoom memories, narrower than the full band's (docs/ZOOM_IN_CHIP.md section 11): a zoom column holds
    // at most 2 bins and a full-scale ADC tone is 2^33 per bin here, so 36 bits per frame and 45 bits over
    // the K frames lose nothing below 6 dB over ADC full scale (K up to 2,048 at full scale); both
    // saturate. 36 and 45 bits are 4 and 5 block RAMs of 2,048 x 9, where 44 and 48 were 5 and 6.
    localparam integer ZACCW1        = 36;
    localparam integer ZACCW2        = 45;

    // ================================================================
    // full-band register bus
    // ================================================================
    reg         ctrl_enable, ctrl_column_mode, ctrl_peak_hold;
    reg  [31:0] avg_k;
    reg  [15:0] level_offset;                            // signed dB offset, 1/64 dB
    reg  [15:0] level_gain;                               // unsigned Q8.8
    reg  [31:0] line_count_reg;
    reg         ready_buf_reg;
    reg         line_done_reg;

    // Both register buses (full-band and zoom) are registered once before decoding: the write and
    // read decode below works from the registered copies, not from the input pins.
    reg         reg_wr_r, reg_rd_r;
    reg  [15:0] reg_addr_r;
    reg  [31:0] reg_wdata_r;
    always @(posedge clk) begin
        if (rst) begin
            reg_wr_r <= 1'b0;
            reg_rd_r <= 1'b0;
        end else begin
            reg_wr_r <= reg_wr;
            reg_rd_r <= reg_rd;
        end
        reg_addr_r  <= reg_addr;
        reg_wdata_r <= reg_wdata;
    end

    wire [31:0] reg_addr32 = {16'b0, reg_addr_r};
    localparam [31:0] SPECTRUM_CTRL_ADDR32         = `SPECTRUM_CTRL_ADDR;
    localparam [31:0] SPECTRUM_AVERAGING_K_ADDR32  = `SPECTRUM_AVERAGING_K_ADDR;
    localparam [31:0] SPECTRUM_LEVEL_ADDR32        = `SPECTRUM_LEVEL_ADDR;
    localparam [31:0] SPECTRUM_ID_ADDR32           = `SPECTRUM_ID_ADDR;
    localparam [31:0] SPECTRUM_LINE_COUNT_ADDR32   = `SPECTRUM_LINE_COUNT_ADDR;
    localparam [31:0] SPECTRUM_LINE_STATUS_ADDR32  = `SPECTRUM_LINE_STATUS_ADDR;

    wire line_complete_pulse;    // full-band line finished (defined below)
    wire zline_complete_pulse;   // zoom line finished (defined below)

    localparam [31:0] SPECTRUM_CTRL_RESET32  = `SPECTRUM_CTRL_RESET;
    localparam [31:0] SPECTRUM_LEVEL_RESET32 = `SPECTRUM_LEVEL_RESET;

    always @(posedge clk) begin
        if (rst) begin
            ctrl_enable      <= SPECTRUM_CTRL_RESET32[`SPECTRUM_CTRL_ENABLE_LSB];
            ctrl_column_mode <= SPECTRUM_CTRL_RESET32[`SPECTRUM_CTRL_COLUMN_MODE_LSB];
            ctrl_peak_hold   <= SPECTRUM_CTRL_RESET32[`SPECTRUM_CTRL_PEAK_HOLD_LSB];
            avg_k            <= `SPECTRUM_AVERAGING_K_RESET;
            level_offset     <= SPECTRUM_LEVEL_RESET32[15:0];
            level_gain       <= SPECTRUM_LEVEL_RESET32[31:16];
            line_done_reg    <= 1'b0;
        end else begin
            if (reg_wr_r && reg_addr32 == SPECTRUM_CTRL_ADDR32) begin
                ctrl_enable      <= reg_wdata_r[`SPECTRUM_CTRL_ENABLE_LSB];
                ctrl_column_mode <= reg_wdata_r[`SPECTRUM_CTRL_COLUMN_MODE_LSB];
                ctrl_peak_hold   <= reg_wdata_r[`SPECTRUM_CTRL_PEAK_HOLD_LSB];
            end
            if (reg_wr_r && reg_addr32 == SPECTRUM_AVERAGING_K_ADDR32) avg_k <= reg_wdata_r;
            if (reg_wr_r && reg_addr32 == SPECTRUM_LEVEL_ADDR32) begin
                level_offset <= reg_wdata_r[`SPECTRUM_LEVEL_OFFSET_DB64_MSB:`SPECTRUM_LEVEL_OFFSET_DB64_LSB];
                level_gain   <= reg_wdata_r[`SPECTRUM_LEVEL_GAIN_Q8_MSB:`SPECTRUM_LEVEL_GAIN_Q8_LSB];
            end
            if (line_complete_pulse) line_done_reg <= 1'b1;
            else if (reg_wr_r && reg_addr32 == SPECTRUM_LINE_STATUS_ADDR32 &&
                     reg_wdata_r[`SPECTRUM_LINE_STATUS_LINE_DONE_LSB])
                line_done_reg <= 1'b0;
        end
    end

    assign irq_line_done = line_done_reg;

    always @(posedge clk) begin
        if (reg_rd_r) begin
            case (reg_addr32)
                SPECTRUM_ID_ADDR32:          reg_rdata <= `SPECTRUM_ID_RESET;
                SPECTRUM_CTRL_ADDR32:        reg_rdata <= {29'b0, ctrl_peak_hold, ctrl_column_mode, ctrl_enable};
                SPECTRUM_AVERAGING_K_ADDR32: reg_rdata <= avg_k;
                SPECTRUM_LEVEL_ADDR32:       reg_rdata <= {level_gain, level_offset};
                SPECTRUM_LINE_COUNT_ADDR32:  reg_rdata <= line_count_reg;
                SPECTRUM_LINE_STATUS_ADDR32: reg_rdata <= {30'b0, line_done_reg, ready_buf_reg};
                default:                      reg_rdata <= 32'h0;
            endcase
        end
    end

    // ================================================================
    // zoom backend register bus (see "Register bus note" above)
    // ================================================================
    reg         zctrl_column_mode, zctrl_peak_hold, zctrl_ft8_cols;
    reg  [31:0] zavg_k;
    reg  [15:0] zlevel_offset;
    reg  [15:0] zlevel_gain;
    reg  [31:0] zline_count_reg;
    reg         zready_buf_reg;
    reg         zline_done_reg;

    reg         zreg_wr_r, zreg_rd_r;
    reg  [15:0] zreg_addr_r;
    reg  [31:0] zreg_wdata_r;
    always @(posedge clk) begin
        if (rst) begin
            zreg_wr_r <= 1'b0;
            zreg_rd_r <= 1'b0;
        end else begin
            zreg_wr_r <= zreg_wr;
            zreg_rd_r <= zreg_rd;
        end
        zreg_addr_r  <= zreg_addr;
        zreg_wdata_r <= zreg_wdata;
    end

    wire [31:0] zreg_addr32 = {16'b0, zreg_addr_r};
    localparam [31:0] ZOOM_CTRL_ADDR32                = `ZOOM_CTRL_ADDR;
    localparam [31:0] ZOOM_BACKEND_AVERAGING_K_ADDR32 = `ZOOM_BACKEND_AVERAGING_K_ADDR;
    localparam [31:0] ZOOM_BACKEND_LEVEL_ADDR32       = `ZOOM_BACKEND_LEVEL_ADDR;
    localparam [31:0] ZOOM_BACKEND_LINE_COUNT_ADDR32  = `ZOOM_BACKEND_LINE_COUNT_ADDR;
    localparam [31:0] ZOOM_BACKEND_LINE_STATUS_ADDR32 = `ZOOM_BACKEND_LINE_STATUS_ADDR;

    localparam [31:0] ZOOM_BACKEND_AVERAGING_K_RESET32 = `ZOOM_BACKEND_AVERAGING_K_RESET;
    localparam [31:0] ZOOM_BACKEND_LEVEL_RESET32       = `ZOOM_BACKEND_LEVEL_RESET;

    always @(posedge clk) begin
        if (rst) begin
            zctrl_column_mode <= 1'b0;
            zctrl_ft8_cols    <= 1'b0;
            zctrl_peak_hold   <= 1'b0;
            zavg_k            <= ZOOM_BACKEND_AVERAGING_K_RESET32;
            zlevel_offset     <= ZOOM_BACKEND_LEVEL_RESET32[15:0];
            zlevel_gain       <= ZOOM_BACKEND_LEVEL_RESET32[31:16];
            zline_done_reg    <= 1'b0;
        end else begin
            if (zreg_wr_r && zreg_addr32 == ZOOM_CTRL_ADDR32) begin
                zctrl_column_mode <= zreg_wdata_r[`ZOOM_CTRL_BACKEND_COLUMN_MODE_LSB];
                zctrl_peak_hold   <= zreg_wdata_r[`ZOOM_CTRL_BACKEND_PEAK_HOLD_LSB];
                zctrl_ft8_cols    <= zreg_wdata_r[`ZOOM_CTRL_BACKEND_FT8_COLUMNS_LSB];
            end
            if (zreg_wr_r && zreg_addr32 == ZOOM_BACKEND_AVERAGING_K_ADDR32) zavg_k <= zreg_wdata_r;
            if (zreg_wr_r && zreg_addr32 == ZOOM_BACKEND_LEVEL_ADDR32) begin
                zlevel_offset <= zreg_wdata_r[`ZOOM_BACKEND_LEVEL_OFFSET_DB64_MSB:`ZOOM_BACKEND_LEVEL_OFFSET_DB64_LSB];
                zlevel_gain   <= zreg_wdata_r[`ZOOM_BACKEND_LEVEL_GAIN_Q8_MSB:`ZOOM_BACKEND_LEVEL_GAIN_Q8_LSB];
            end
            if (zline_complete_pulse) zline_done_reg <= 1'b1;
            else if (zreg_wr_r && zreg_addr32 == ZOOM_BACKEND_LINE_STATUS_ADDR32 &&
                     zreg_wdata_r[`ZOOM_BACKEND_LINE_STATUS_LINE_DONE_LSB])
                zline_done_reg <= 1'b0;
        end
    end

    assign zirq_line_done = zline_done_reg;

    always @(posedge clk) begin
        if (zreg_rd_r) begin
            case (zreg_addr32)
                // Only this module's own fields (bits 4:5); enable/span_shift (bits 0, 3:1) belong to
                // the zoom DDC elsewhere (see the "Register bus note" on this module's ports).
                ZOOM_CTRL_ADDR32:                zreg_rdata <= {20'b0, zctrl_ft8_cols, 5'b0, zctrl_peak_hold, zctrl_column_mode, 4'b0};
                ZOOM_BACKEND_AVERAGING_K_ADDR32: zreg_rdata <= zavg_k;
                ZOOM_BACKEND_LEVEL_ADDR32:       zreg_rdata <= {zlevel_gain, zlevel_offset};
                ZOOM_BACKEND_LINE_COUNT_ADDR32:  zreg_rdata <= zline_count_reg;
                ZOOM_BACKEND_LINE_STATUS_ADDR32: zreg_rdata <= {30'b0, zline_done_reg, zready_buf_reg};
                default:                          zreg_rdata <= 32'h0;
            endcase
        end
    end

    // ================================================================
    // full-band side: window -> FFT
    // ================================================================
    wire         win_valid;
    wire signed [FFT_IW-1:0] win_re;

    // ZOOM_SHARED: the zoom's frames through the same FFT (docs/ZOOM_FIT.md section 2). When a zoom frame
    // waits and the whole-band input stands at a frame boundary, the whole-band input stops (its samples
    // are dropped until it goes on, with a new frame), the window and the first two FFT stages pass their
    // last words on (48 clocks allowed), the 4,096 zoom samples go in behind stage 2, and the whole-band
    // input goes on after the last of them.
    localparam integer ZLOG_NF = 12;                    // the zoom's transform: 4,096 points (ZLOG_N below)
    wire        fb_hold;                                // the whole-band input is stopped
    wire        fb_take = adc_valid & ((ZOOM_SHARED != 0) ? ~fb_hold : ctrl_enable);
    generate
        if (ZOOM_SHARED != 0) begin : g_zsh
            reg [LOG_N-1:0] fb_pos = {LOG_N{1'b0}};     // whole-band samples taken in this frame
            reg             fb_at0 = 1'b1;              // none yet: a frame boundary
            reg [1:0]       zs = 2'd0;                  // 0 idle, 1 the stages in front empty out, 2 the zoom frame goes in
            reg [5:0]       zw = 6'd0;
            reg             zrdy = 1'b0;
            assign fb_hold = (zs != 2'd0) | (fb_at0 & zrdy);
            always @(posedge clk) begin
                zfr_go <= 1'b0;
                if (rst) begin
                    fb_pos <= {LOG_N{1'b0}}; fb_at0 <= 1'b1; zs <= 2'd0; zw <= 6'd0; zrdy <= 1'b0;
                end else begin
                    zrdy <= zfr_ready & (zs == 2'd0) & ~(fb_at0 & zrdy);
                    if (fb_take) begin
                        fb_pos <= fb_pos + 1'b1;
                        fb_at0 <= (fb_pos == {LOG_N{1'b1}});
                    end
                    case (zs)
                        2'd0: if (fb_at0 & zrdy) begin zs <= 2'd1; zw <= 6'd0; end
                        2'd1: begin
                            zw <= zw + 6'd1;
                            if (zw == 6'd47) begin zs <= 2'd2; zfr_go <= 1'b1; end
                        end
                        default: if (zfr_last) zs <= 2'd0;
                    endcase
                end
            end
        end else begin : g_nozsh
            assign fb_hold = 1'b0;
            always @(posedge clk) zfr_go <= 1'b0;
        end
    endgenerate

    spectrum_window #(.LOG_N(LOG_N), .IW(12), .OW(FFT_IW), .TW_DIR(TW_DIR)) u_win (
        .clk(clk), .rst(rst),
        .in_valid(fb_take), .in_sample(adc_data),
        .out_valid(win_valid), .out_sample(win_re)
    );

    wire                fft_valid, fft_first;
    wire [LOG_N-1:0]    fft_index, fft_bin;
    wire [FFT_OW-1:0]   fft_re, fft_im;
    wire                zf_valid, zf_first;             // the zoom's bins out of the shared FFT
    wire [ZLOG_NF-1:0]  zf_index, zf_bin;

    generate
        if (ZOOM_SHARED != 0) begin : g_fft
            // behind stage 2 the words are FFT_IW + 2 = 17 bits: the zoom's 16-bit samples, sign-extended
            fft_r22sdf #(.LOG_N(LOG_N), .IW(FFT_IW), .REAL_IN(1), .TW_DIR(FFT_TW_DIR), .SR_LUT(1),
                            .LUT_MAX_W(256), .TW_LUT_MAX(128), .TW_M1_ONE(1), .INJ_S(LOG_N - ZLOG_NF)) u_fft (
                .clk(clk), .rst(rst),
                .in_valid(win_valid), .in_re(win_re), .in_im({FFT_IW{1'b0}}),
                .out_valid(fft_valid), .out_first(fft_first), .out_index(fft_index), .out_bin(fft_bin),
                .out_re(fft_re), .out_im(fft_im),
                .inj_valid(zfr_valid), .inj_re({zfr_re[15], zfr_re}), .inj_im({zfr_im[15], zfr_im}),
                .out_ivalid(zf_valid), .out_ifirst(zf_first), .out_iindex(zf_index), .out_ibin(zf_bin)
            );
        end else begin : g_fft
            fft_r22sdf #(.LOG_N(LOG_N), .IW(FFT_IW), .REAL_IN(1), .TW_DIR(FFT_TW_DIR), .SR_LUT(1),
                            .LUT_MAX_W(256), .TW_LUT_MAX(128), .TW_M1_ONE(1)) u_fft (
                .clk(clk), .rst(rst),
                .in_valid(win_valid), .in_re(win_re), .in_im({FFT_IW{1'b0}}),
                .out_valid(fft_valid), .out_first(fft_first), .out_index(fft_index), .out_bin(fft_bin),
                .out_re(fft_re), .out_im(fft_im),
                .inj_valid(1'b0), .inj_re({FFT_IW{1'b0}}), .inj_im({FFT_IW{1'b0}}),
                .out_ivalid(), .out_ifirst(), .out_iindex(), .out_ibin()
            );
            assign zf_valid = 1'b0;
            assign zf_first = 1'b0;
            assign zf_index = {ZLOG_NF{1'b0}};
            assign zf_bin   = {ZLOG_NF{1'b0}};
        end
    endgenerate

    // The zoom context's bin stream: the port (ZOOM_SHARED = 0), or the second stream of the shared FFT
    // through one register stage, with the "displayed 80 %" flag as rtl/zoom/zoom_spectrum.v makes it.
    wire                 zin_valid, zin_first, zin_usable;
    wire [ZLOG_NF-1:0]   zin_bin;
    wire signed [28:0]   zin_re, zin_im;
    generate
        if (ZOOM_SHARED != 0) begin : g_zin
            reg                zv_q = 1'b0, zfirst_q = 1'b0, zus_q = 1'b0;
            reg [ZLOG_NF-1:0]  zbin_q = {ZLOG_NF{1'b0}};
            reg signed [28:0]  zre_q = 29'sd0, zim_q = 29'sd0;
            always @(posedge clk) begin
                zv_q     <= zf_valid & ~rst;
                zfirst_q <= zf_first;
                zbin_q   <= zf_bin;
                zus_q    <= (zf_bin <= 12'd1638) || (zf_bin >= 12'd2458);   // Z_USABLE_HALF, ZN - Z_USABLE_HALF
                zre_q    <= fft_re;
                zim_q    <= fft_im;
            end
            assign zin_valid = zv_q;   assign zin_first = zfirst_q;  assign zin_usable = zus_q;
            assign zin_bin   = zbin_q; assign zin_re    = zre_q;     assign zin_im     = zim_q;
        end else begin : g_zin
            assign zin_valid = zoom_in_valid; assign zin_first = zoom_in_first; assign zin_usable = zoom_in_usable;
            assign zin_bin   = zoom_in_bin;   assign zin_re    = zoom_in_re;    assign zin_im     = zoom_in_im;
        end
    endgenerate

    // ---- power: truncate to SQ_W (round, saturate), square, drop the mirror half (odd out_index) ----
    wire signed [FFT_OW-1:0] s_re = fft_re;
    wire signed [FFT_OW-1:0] s_im = fft_im;
    localparam signed [FFT_OW-1:0] RHALF = 1 <<< (RSH - 1);
    wire signed [FFT_OW-1:0] re_rnd = (s_re + RHALF) >>> RSH;
    wire signed [FFT_OW-1:0] im_rnd = (s_im + RHALF) >>> RSH;
    localparam signed [FFT_OW-1:0] SQMAX = (1 <<< (SQ_W - 1)) - 1;
    localparam signed [FFT_OW-1:0] SQMIN = -(1 <<< (SQ_W - 1));
    wire signed [SQ_W-1:0] re_t = (re_rnd > SQMAX) ? SQMAX[SQ_W-1:0] :
                                  (re_rnd < SQMIN) ? SQMIN[SQ_W-1:0] : re_rnd[SQ_W-1:0];
    wire signed [SQ_W-1:0] im_t = (im_rnd > SQMAX) ? SQMAX[SQ_W-1:0] :
                                  (im_rnd < SQMIN) ? SQMIN[SQ_W-1:0] : im_rnd[SQ_W-1:0];

    reg               pw_valid1;
    reg [LOG_N-1:0]   pw_bin1, pw_idx1;
    reg signed [SQ_W-1:0] re_t1, im_t1;
    always @(posedge clk) begin
        pw_valid1 <= rst ? 1'b0 : (fft_valid & ctrl_enable);
        pw_bin1   <= fft_bin;
        pw_idx1   <= fft_index;
        re_t1     <= re_t;
        im_t1     <= im_t;
    end

    wire [POW_W-1:0] power_word = re_t1 * re_t1 + im_t1 * im_t1;

    reg               pw_valid2;
    reg [LOG_N-1:0]   pw_bin2, pw_idx2;
    reg [POW_W-1:0]   power2;
    always @(posedge clk) begin
        pw_valid2 <= rst ? 1'b0 : pw_valid1;
        pw_bin2   <= pw_bin1;
        pw_idx2   <= pw_idx1;
        power2    <= power_word;
    end

    wire useful2c     = pw_valid2 & ~pw_idx2[0] & (pw_bin2 < NUM_BINS[LOG_N-1:0]);
    wire frame_last2c = pw_valid2 & (pw_idx2 == (N - 1));

    // bin -> column, exact for bin < 65536 (Hacker's Delight unsigned divide-by-10 x3, see
    // tools/gen_spectrum_tables.py col_of_bin, which this must match bit for bit)
    wire [31:0] colmul = {19'b0, pw_bin2[12:0]} * COL_MULT[31:0];

    (* syn_romstyle = "distributed_rom" *) reg col_first_rom [0:NUM_BINS-1];
    initial $readmemh({TW_DIR, "col_first.hex"}, col_first_rom);

    // Stage 3: the column number, the first-bin flag and the power are registered once more before the
    // front end uses them (the column multiply, the FIFO/live select and the column-buffer read address
    // in one clock would be too long). useful2 and frame_last2 say that a bin is to be used and that it
    // ends a frame, col_idx and is_first_bin say where it goes and whether it starts its column; the power
    // here is power3.
    reg               useful2, frame_last2;
    reg [10:0]        col_idx;
    reg               is_first_bin;
    reg [POW_W-1:0]   power3;
    always @(posedge clk) begin
        useful2      <= rst ? 1'b0 : useful2c;
        frame_last2  <= rst ? 1'b0 : frame_last2c;
        col_idx      <= colmul[29:19];
        is_first_bin <= col_first_rom[pw_bin2[12:0]];
        power3       <= power2;
    end

    // ================================================================
    // full-band front end: one column buffer plus a 1,024-entry arrival FIFO. A ping-ponged pair of
    // buffers would let the bins of frame N+1 write freely into the "other" buffer while a walk drained
    // frame N's buffer; with a single buffer, any bin arrival that lands while this module's walk
    // (via the shared engine) is still reading it would corrupt not-yet-read columns. A walk only takes
    // about 1,930 cycles and at most 750 useful bins arrive during that window, so those are queued in a
    // FIFO instead of a whole second 1,920-entry buffer, and drained (in the same read-modify-write
    // pipeline used for live arrivals) once the walk is done. Correctness does not depend on the drain
    // order: mean mode sums (commutative) and max mode takes a max (also commutative and idempotent under
    // reordering), so interleaving queued and live updates however scheduling works out is fine.
    // ================================================================
    reg [ACCW1-1:0] cfa_mem [0:NUM_COLS-1];
    integer cfa_i;
    initial for (cfa_i = 0; cfa_i < NUM_COLS; cfa_i = cfa_i + 1) cfa_mem[cfa_i] = {ACCW1{1'b0}};

    wire walkA_busy;   // this context is the one the shared walk engine is currently reading
    wire [10:0] wc_col_addr;   // the walk's column address (driven by u_walk below)

    reg  [FIFO_W-1:0] fifoA_mem [0:FIFO_N-1];   // {col_idx[10:0], is_first, power[41:0]}
    reg  [FIFO_AW-1:0]     fifoA_wr, fifoA_rd;
    reg  [FIFO_AW:0]       fifoA_count;
    wire fifoA_empty = (fifoA_count == 0);

    // Order matters here, not just "don't touch cfa_mem while the walk is reading it": a bin
    // arriving once the walk is done must not overtake an EARLIER bin for the same column that is
    // still sitting in the FIFO (queued while the walk was busy) but not yet drained, and if it did,
    // the later (non-"first") bin would accumulate onto stale, not-yet-refreshed data, and the
    // earlier (actually-"first") bin would then overwrite it once drained, silently losing the
    // later bin's contribution. So a new arrival queues, instead of going straight to cfa_mem,
    // whenever there is ANY backlog to preserve order behind, not only while busy; the queue only
    // bypasses (a_job_live) once it is fully drained.
    wire queueA_mode = walkA_busy | ~fifoA_empty;
    wire a_job_push  = useful2 & queueA_mode;
    wire a_job_drain = ~walkA_busy & ~fifoA_empty & ~a_job_push;
    wire a_job_live  = useful2 & ~queueA_mode;
    wire a_job_valid = a_job_live | a_job_drain;
    // The head entry is a registered read (fifoA_q), always the entry at fifoA_rd: the read address is the
    // pointer's next value, and an entry pushed into an empty queue goes straight into fifoA_q. A
    // combinational read of the memory would take 5 block RAMs for 54 bits (Gowin adds a second 32-bit
    // copy); this takes 3.
    reg  [FIFO_W-1:0] fifoA_q = {FIFO_W{1'b0}};
    wire [FIFO_AW-1:0] fifoA_rd_n = a_job_drain ? fifoA_rd + 1'b1 : fifoA_rd;
    always @(posedge clk)
        fifoA_q <= (a_job_push && fifoA_rd_n == fifoA_wr) ? {col_idx, is_first_bin, power3}
                                                          : fifoA_mem[fifoA_rd_n];
    wire [10:0]      a_job_col   = a_job_drain ? fifoA_q[53:43] : col_idx;
    wire             a_job_first = a_job_drain ? fifoA_q[42]    : is_first_bin;
    wire [POW_W-1:0] a_job_power = a_job_drain ? fifoA_q[41:0]  : power3;

    always @(posedge clk) begin
        if (rst) begin
            fifoA_wr <= {FIFO_AW{1'b0}}; fifoA_rd <= {FIFO_AW{1'b0}}; fifoA_count <= {(FIFO_AW+1){1'b0}};
        end else if (a_job_push) begin
            fifoA_mem[fifoA_wr] <= {col_idx, is_first_bin, power3};
            fifoA_wr    <= fifoA_wr + 1'b1;
            fifoA_count <= fifoA_count + 1'b1;
        end else if (a_job_drain) begin
            fifoA_rd    <= fifoA_rd + 1'b1;
            fifoA_count <= fifoA_count - 1'b1;
        end
    end

    function [ACCW1-1:0] sat_add1;
        input [ACCW1-1:0] a;
        input [POW_W-1:0] b;
        reg [ACCW1:0] s;
        begin
            s = a + b;
            sat_add1 = s[ACCW1] ? {ACCW1{1'b1}} : s[ACCW1-1:0];
        end
    endfunction

    reg              cfa_pending;
    reg [10:0]       cfa_addr_d;
    reg              cfa_first_d;
    reg [POW_W-1:0]  cfa_power_d;
    reg              cfa_colmode_d;
    wire [ACCW1-1:0] cfa_rd;     // the column memory's registered read (one port, shared with the walk)

    always @(posedge clk) begin
        cfa_pending   <= rst ? 1'b0 : a_job_valid;
        cfa_addr_d    <= a_job_col;
        cfa_first_d   <= a_job_first;
        cfa_power_d   <= a_job_power;
        cfa_colmode_d <= ctrl_column_mode;
    end

    // One read port for the front end and the walk (two ports would mean two copies of the 44-bit x 1,920
    // memory, 10 block RAMs; one copy is 5). The front end reads for a job only while this context is not
    // being walked (a_job_valid is 0 while walkA_busy), and the walk reads only while it is, so the
    // address picks one.
    reg [ACCW1-1:0] cfa_rdsh;
    always @(posedge clk) cfa_rdsh <= cfa_mem[walkA_busy ? wc_col_addr : a_job_col];
    assign cfa_rd = cfa_rdsh;

    // The read-modify-write is four clocks: the block RAM's read data, a 44-bit add or compare and a
    // select, back into the same RAM's write port, would be far too long for one clock. So: read (d), the
    // read data registered (e), the saturating sum and the max compare registered (f), and the select
    // written from registers. A column's next update must be issued at least four jobs later; bins of one
    // column arrive thousands of samples apart in the FFT's bit-reversed output order (docs/F2_SPECTRUM.md
    // "Timing"), and the walk's first reads (columns 0 and 1) are more than three clocks after the last
    // job of the frame that could touch them.
    reg              cfa_v_e, cfa_first_e, cfa_colmode_e;
    reg [10:0]       cfa_addr_e;
    reg [POW_W-1:0]  cfa_power_e;
    reg [ACCW1-1:0]  cfa_rd_e;
    reg              cfa_v_f, cfa_first_f, cfa_colmode_f, cfa_gt_f;
    reg [10:0]       cfa_addr_f;
    reg [ACCW1-1:0]  cfa_power_f, cfa_rd_f, cfa_sum_f;
    always @(posedge clk) begin
        cfa_v_e       <= rst ? 1'b0 : cfa_pending;
        cfa_addr_e    <= cfa_addr_d;
        cfa_first_e   <= cfa_first_d;
        cfa_colmode_e <= cfa_colmode_d;
        cfa_power_e   <= cfa_power_d;
        cfa_rd_e      <= cfa_rd;
        cfa_v_f       <= rst ? 1'b0 : cfa_v_e;
        cfa_addr_f    <= cfa_addr_e;
        cfa_first_f   <= cfa_first_e;
        cfa_colmode_f <= cfa_colmode_e;
        cfa_power_f   <= {{(ACCW1-POW_W){1'b0}}, cfa_power_e};
        cfa_rd_f      <= cfa_rd_e;
        cfa_sum_f     <= sat_add1(cfa_rd_e, cfa_power_e);
        cfa_gt_f      <= cfa_rd_e > {{(ACCW1-POW_W){1'b0}}, cfa_power_e};
    end

    wire [ACCW1-1:0] cfa_combined = cfa_first_f ? cfa_power_f
                                   : (cfa_colmode_f ? cfa_sum_f
                                                     : (cfa_gt_f ? cfa_rd_f : cfa_power_f));

    always @(posedge clk) if (cfa_v_f) cfa_mem[cfa_addr_f] <= cfa_combined;

    // ================================================================
    // full-band K-frame memory + column table (single buffer): kacc_mem holds the K-frame accumulator of every
    // column, and col_bins_rom the number of bins in each column (for the mean)
    // ================================================================
    reg [ACCW2-1:0] kacc_mem [0:NUM_COLS-1];
    integer kacc_i;
    initial for (kacc_i = 0; kacc_i < NUM_COLS; kacc_i = kacc_i + 1) kacc_mem[kacc_i] = {ACCW2{1'b0}};

    reg [2:0] col_bins_rom [0:NUM_COLS-1];
    initial $readmemh({TW_DIR, "col_bins.hex"}, col_bins_rom);

    // One line buffer, not two (docs/ZOOM_FIT.md, docs/ZOOM_IN_CHIP.md section 11): the compositor copies the
    // line into its own snapshot memory, so a second buffer here would only keep that copy from seeing a
    // line half old and half new for one picture. That is 2 block RAMs instead of 4.
    // line_status.ready_buffer reads 0.
    reg [15:0] line_buf_mem [0:NUM_COLS-1];

    // ================================================================
    // zoom side: power (from the externally-supplied FFT bin stream) + front end (same shape as
    // the full-band front end above: single column buffer + arrival FIFO, but only 128 entries --
    // this side's own worst case is far smaller, see ZFIFO_AW above)
    // ================================================================
    wire signed [28:0] zs_re = zin_re;
    wire signed [28:0] zs_im = zin_im;
    wire signed [28:0] zre_rnd = (zs_re + RHALF) >>> RSH;
    wire signed [28:0] zim_rnd = (zs_im + RHALF) >>> RSH;
    wire signed [SQ_W-1:0] zre_t = (zre_rnd > SQMAX) ? SQMAX[SQ_W-1:0] :
                                   (zre_rnd < SQMIN) ? SQMIN[SQ_W-1:0] : zre_rnd[SQ_W-1:0];
    wire signed [SQ_W-1:0] zim_t = (zim_rnd > SQMAX) ? SQMAX[SQ_W-1:0] :
                                   (zim_rnd < SQMIN) ? SQMIN[SQ_W-1:0] : zim_rnd[SQ_W-1:0];

    // zoom's own frame position counter: zoom_spectrum.v exposes out_first (index 0 of a frame)
    // but not the running index rtl/fft/fft_r22sdf.v uses internally, so this module tracks it
    // itself the same way: zpos_cur is THIS word's position, computed from the PREVIOUS word's
    // registered position (zpos) and out_first (which forces position 0 regardless of zpos).
    reg [ZLOG_N-1:0] zpos;
    wire [ZLOG_N-1:0] zpos_cur = zin_first ? {ZLOG_N{1'b0}} : (zpos + 1'b1);
    always @(posedge clk) if (rst) zpos <= {ZLOG_N{1'b0}}; else if (zin_valid) zpos <= zpos_cur;

    reg               zpw_valid1;
    reg [ZLOG_N-1:0]  zpw_bin1;
    reg               zpw_last1;
    reg signed [SQ_W-1:0] zre_t1, zim_t1;
    always @(posedge clk) begin
        zpw_valid1 <= rst ? 1'b0 : (zin_valid & zin_usable);
        zpw_bin1   <= zin_bin;
        zpw_last1  <= zin_valid & (zpos_cur == {ZLOG_N{1'b1}});
        zre_t1     <= zre_t;
        zim_t1     <= zim_t;
    end

    wire [POW_W-1:0] zpower_word = zre_t1 * zre_t1 + zim_t1 * zim_t1;

    reg               zpw_valid2;
    reg [ZLOG_N-1:0]  zpw_bin2;
    reg               zpw_last2;
    reg [POW_W-1:0]   zpower2;
    always @(posedge clk) begin
        zpw_valid2 <= rst ? 1'b0 : zpw_valid1;
        zpw_bin2   <= zpw_bin1;
        zpw_last2  <= zpw_last1;
        zpower2    <= zpower_word;
    end

    // bin -> contiguous frequency index ("rel", 0 .. 3,276) -> column = (rel * scale) >> 20, as
    // tools/gen_spectrum_tables.py's zoom_rel() / col_of_rel(). Three registered steps (rel; the product;
    // column and flags), because the compare and add for rel, a 12 x 20 multiply and a 3,277-word LUT ROM
    // in one clock are too long (docs/ZOOM_IN_CHIP.md section 10).
    //
    // Two column scales (ctrl.backend_ft8_columns): 614363 / 2^20 = 1,920 / 3,277, the whole displayed
    // span across the 1,920 columns; and 750080 / 2^20 = 0.71533, which at the 6 kHz span (bins of
    // 1.8311 Hz) makes a column 2.5597 Hz, 1,172 columns = 3,000 Hz, the FT8 screen's scale, starting at
    // the low edge of the span. Bins that land beyond column 1,919 are dropped.
    //
    // "First bin of its column in arrival order" needs no table at a scale above 1/2 (at most two bins
    // per column): the two are neighbours, the FFT delivers bins in bit-reversed order, and of two
    // neighbours the even one comes first (its lowest bit, the first one compared, is 0). So a bin is the
    // first if it is even or alone in its column; with f = the low 20 bits of rel * scale it shares the
    // column with the bin below if f >= scale and with the bin above if f + scale < 2^20.
    localparam [19:0] Z_COL_MULT_FT8 = 20'd750080;
    reg [19:0] zm_q;                                    // the scale in use
    reg [19:0] zmc_q;                                   // 2^20 - scale
    reg signed [21:0] zm1_q, zm2_q;                     // scale - 2^20, 2 * scale - 2^20 (bins per column, below)
    always @(posedge clk) begin
        zm_q  <= zctrl_ft8_cols ? Z_COL_MULT_FT8 : Z_COL_MULT[19:0];
        zmc_q <= 20'd0 - zm_q;
        zm1_q <= $signed({2'b00, zm_q}) - 22'sd1048576;
        zm2_q <= $signed({1'b0, zm_q, 1'b0}) - 22'sd1048576;
    end

    wire [11:0] zrel = (zpw_bin2 <= Z_USABLE_HALF[11:0]) ? (zpw_bin2 + Z_USABLE_HALF[11:0])
                                                          : (zpw_bin2 - (ZN[11:0] - Z_USABLE_HALF[11:0]));
    reg               zv_a, zlast_a, zv_b, zlast_b, zodd_b;
    reg [11:0]        zrel_a;
    // kept: without the attribute Gowin moves this register and zpower2 into the multipliers and leaves the
    // 42-bit sum of the two squares and the saturation in one clock, which is too long
    reg [POW_W-1:0]   zpow_a /* synthesis syn_preserve = 1 */;
    reg [ZACCW1-1:0]  zpow_b;
    reg [31:0]        zprod_b;
    always @(posedge clk) begin
        zv_a    <= rst ? 1'b0 : zpw_valid2;                 // usability already filtered at stage 1
        zlast_a <= zpw_valid2 & zpw_last2;
        zrel_a  <= zrel;
        zpow_a  <= zpower2;
        zv_b    <= rst ? 1'b0 : zv_a;
        zlast_b <= zlast_a;
        zodd_b  <= zrel_a[0];
        zpow_b  <= (|zpow_a[POW_W-1:ZACCW1]) ? {ZACCW1{1'b1}} : zpow_a[ZACCW1-1:0];
        zprod_b <= zrel_a * zm_q;
    end

    reg               zuseful2, zframe_last2;
    reg [10:0]        zcol_idx;
    reg               zis_first_bin;
    reg [ZACCW1-1:0]  zpower3;
    always @(posedge clk) begin
        zuseful2      <= rst ? 1'b0 : (zv_b & (zprod_b[31:20] < Z_NUM_COLS[11:0]));
        zframe_last2  <= rst ? 1'b0 : (zv_b & zlast_b);
        zcol_idx      <= zprod_b[30:20];
        zis_first_bin <= ~zodd_b | ((zprod_b[19:0] < zm_q) & (zprod_b[19:0] >= zmc_q));
        zpower3       <= zpow_b;
    end

    reg [ZACCW1-1:0] zcfa_mem [0:Z_NUM_COLS-1];
    integer zcfa_i;
    initial for (zcfa_i = 0; zcfa_i < Z_NUM_COLS; zcfa_i = zcfa_i + 1) zcfa_mem[zcfa_i] = {ZACCW1{1'b0}};

    wire walkB_busy;

    // The arrival queue: 128 x 48 bits of LUT RAM in lanes (rtl/zoom/zoom_lutram.v), read through
    // registers. Read without a register Gowin builds it from 6,912 flip-flops and a 128-way selection
    // (the read pointer would drive 1,697 loads). A word is at the queue's output two clocks after the
    // read pointer moves, so a word is taken every third clock at most; zoom bins come 32 clocks apart
    // or more.
    localparam integer ZFIFO_W = 11 + 1 + ZACCW1;       // {column, first, power}
    //
    // ZOOM_SHARED = 1: no queue. The bins of a zoom frame come out of the shared FFT in one burst (a bin
    // per whole-band sample), and the next burst is a whole zoom frame of samples later (82,000 clocks at
    // the very least), long after the walk of this one (at most two walks of 1,930 clocks after its last
    // bin). The read-modify-write below takes a bin a clock, like the whole-band context. A bin that came
    // during a walk would be dropped.
    reg  [ZFIFO_AW-1:0]    fifoB_wr, fifoB_rd;
    reg  [ZFIFO_AW:0]      fifoB_count;
    reg  [1:0]             fifoB_ok;                    // the output word is the one at fifoB_rd
    wire [ZFIFO_W-1:0]     fifoB_q;
    wire fifoB_empty = (ZOOM_SHARED != 0) ? 1'b1 : (fifoB_count == 0);

    // Same ordering rule as context A's fifoA above: queue whenever there is a backlog to stay
    // behind, not only while the walk is busy.
    wire queueB_mode = walkB_busy | ~fifoB_empty;
    wire b_job_push  = (ZOOM_SHARED != 0) ? 1'b0 : (zuseful2 & queueB_mode);
    wire b_job_drain = ~walkB_busy & fifoB_ok[1] & ~b_job_push;
    wire b_job_live  = zuseful2 & ~queueB_mode;
    wire b_job_valid = b_job_live | b_job_drain;
    // (fifoB_ok[1] alone picks the word: while the queue's word is valid the queue is not empty, so a bin
    // that arrives is queued and the only job there can be is the queue's)
    wire [10:0]       b_job_col   = fifoB_ok[1] ? fifoB_q[ZFIFO_W-1 -: 11] : zcol_idx;
    wire              b_job_first = fifoB_ok[1] ? fifoB_q[ZACCW1]          : zis_first_bin;
    wire [ZACCW1-1:0] b_job_power = fifoB_ok[1] ? fifoB_q[ZACCW1-1:0]      : zpower3;

    generate
        if (ZOOM_SHARED == 0) begin : g_fifoB
            zoom_lutram #(.AW(ZFIFO_AW), .W(ZFIFO_W), .LANE(4)) u_fifoB (
                .clock(clk), .we(b_job_push & ~rst), .wa(fifoB_wr), .wd({zcol_idx, zis_first_bin, zpower3}),
                .ra(fifoB_rd), .rq(fifoB_q)
            );
        end else begin : g_nofifoB
            assign fifoB_q = {ZFIFO_W{1'b0}};
        end
    endgenerate

    always @(posedge clk) begin
        if (rst || ZOOM_SHARED != 0) begin
            fifoB_wr <= {ZFIFO_AW{1'b0}}; fifoB_rd <= {ZFIFO_AW{1'b0}}; fifoB_count <= {(ZFIFO_AW+1){1'b0}};
        end else if (b_job_push) begin
            fifoB_wr    <= fifoB_wr + 1'b1;
            fifoB_count <= fifoB_count + 1'b1;
        end else if (b_job_drain) begin
            fifoB_rd    <= fifoB_rd + 1'b1;
            fifoB_count <= fifoB_count - 1'b1;
        end
        if (rst | b_job_drain | fifoB_empty) fifoB_ok <= 2'b00;
        else                                 fifoB_ok <= {fifoB_ok[0], 1'b1};
    end

    reg              zcfa_pending;
    reg [10:0]       zcfa_addr_d;
    reg              zcfa_first_d;
    reg [ZACCW1-1:0] zcfa_power_d;
    reg              zcfa_colmode_d;
    wire [ZACCW1-1:0] zcfa_rd;   // as cfa_rd (one read port, shared with the walk)

    always @(posedge clk) begin
        zcfa_pending   <= rst ? 1'b0 : b_job_valid;
        zcfa_addr_d    <= b_job_col;
        zcfa_first_d   <= b_job_first;
        zcfa_power_d   <= b_job_power;
        zcfa_colmode_d <= zctrl_column_mode;
    end

    reg [ZACCW1-1:0] zcfa_rdsh;
    always @(posedge clk) zcfa_rdsh <= zcfa_mem[walkB_busy ? wc_col_addr : b_job_col];
    assign zcfa_rd = zcfa_rdsh;

    // Read-modify-write as context A's (see there), on ZACCW1 bits and one clock longer: read (d), read
    // data registered (e), sum with its carry and the max compare registered (f; the compare in two
    // halves; f2: joined), the word chosen and registered (g), written. The choice in g is made per 9 bits
    // from kept copies of the four flags (36 loads on one flag would be the rest of the path). A column's
    // two bins arrive half a frame apart, and the walk reads a column long after the last job of its
    // frame.
    localparam integer ZG = 4;                          // groups of ZACCW1 / ZG bits
    localparam integer ZB = ZACCW1 / ZG;
    reg              zcfa_v_e, zcfa_first_e, zcfa_colmode_e;
    reg [10:0]       zcfa_addr_e;
    reg [ZACCW1-1:0] zcfa_power_e;
    reg [ZACCW1-1:0] zcfa_rd_e;
    reg              zcfa_v_f;
    reg [ZG-1:0]     zcfa_first_f   /* synthesis syn_preserve = 1 */;
    reg [ZG-1:0]     zcfa_colmode_f /* synthesis syn_preserve = 1 */;
    reg [ZG-1:0]     zcfa_gt_f      /* synthesis syn_preserve = 1 */;
    reg [10:0]       zcfa_addr_f;
    reg [ZACCW1-1:0] zcfa_power_f, zcfa_rd_f;
    reg [ZACCW1:0]   zcfa_sum_f;
    reg [ZG-1:0]     zcfa_cy_f      /* synthesis syn_preserve = 1 */;
    reg              zcfa_v_x, zcfa_first_x, zcfa_colmode_x, zcfa_gh_x, zcfa_eh_x, zcfa_gl_x;   // stage f
    reg [10:0]       zcfa_addr_x;
    reg [ZACCW1-1:0] zcfa_power_x, zcfa_rd_x;
    reg [ZACCW1:0]   zcfa_sum_x;
    reg              zcfa_v_g;
    reg [10:0]       zcfa_addr_g;
    reg [ZACCW1-1:0] zcfa_word_g;
    wire [ZACCW1:0]  zcfa_sum_w = {1'b0, zcfa_rd_e} + {1'b0, zcfa_power_e};
    integer zgi;
    always @(posedge clk) begin
        zcfa_v_e       <= rst ? 1'b0 : zcfa_pending;
        zcfa_addr_e    <= zcfa_addr_d;
        zcfa_first_e   <= zcfa_first_d;
        zcfa_colmode_e <= zcfa_colmode_d;
        zcfa_power_e   <= zcfa_power_d;
        zcfa_rd_e      <= zcfa_rd;
        // f: sum; compare in two halves
        zcfa_v_x       <= rst ? 1'b0 : zcfa_v_e;
        zcfa_addr_x    <= zcfa_addr_e;
        zcfa_first_x   <= zcfa_first_e;
        zcfa_colmode_x <= zcfa_colmode_e;
        zcfa_power_x   <= zcfa_power_e;
        zcfa_rd_x      <= zcfa_rd_e;
        zcfa_sum_x     <= zcfa_sum_w;
        zcfa_gh_x      <= zcfa_rd_e[ZACCW1-1:ZACCW1/2] >  zcfa_power_e[ZACCW1-1:ZACCW1/2];
        zcfa_eh_x      <= zcfa_rd_e[ZACCW1-1:ZACCW1/2] == zcfa_power_e[ZACCW1-1:ZACCW1/2];
        zcfa_gl_x      <= zcfa_rd_e[ZACCW1/2-1:0]      >  zcfa_power_e[ZACCW1/2-1:0];
        // f2: the flags as kept copies
        zcfa_v_f       <= rst ? 1'b0 : zcfa_v_x;
        zcfa_addr_f    <= zcfa_addr_x;
        zcfa_first_f   <= {ZG{zcfa_first_x}};
        zcfa_colmode_f <= {ZG{zcfa_colmode_x}};
        zcfa_power_f   <= zcfa_power_x;
        zcfa_rd_f      <= zcfa_rd_x;
        zcfa_sum_f     <= zcfa_sum_x;
        zcfa_cy_f      <= {ZG{zcfa_sum_x[ZACCW1]}};
        zcfa_gt_f      <= {ZG{zcfa_gh_x | (zcfa_eh_x & zcfa_gl_x)}};
        zcfa_v_g       <= rst ? 1'b0 : zcfa_v_f;
        zcfa_addr_g    <= zcfa_addr_f;
        for (zgi = 0; zgi < ZG; zgi = zgi + 1)
            zcfa_word_g[zgi*ZB +: ZB] <=
                zcfa_first_f[zgi]   ? zcfa_power_f[zgi*ZB +: ZB]
              : zcfa_colmode_f[zgi] ? (zcfa_cy_f[zgi] ? {ZB{1'b1}} : zcfa_sum_f[zgi*ZB +: ZB])
              :                       (zcfa_gt_f[zgi] ? zcfa_rd_f[zgi*ZB +: ZB] : zcfa_power_f[zgi*ZB +: ZB]);
    end

    always @(posedge clk) if (zcfa_v_g) zcfa_mem[zcfa_addr_g] <= zcfa_word_g;

    reg [ZACCW2-1:0] zkacc_mem [0:Z_NUM_COLS-1];
    integer zkacc_i;
    initial for (zkacc_i = 0; zkacc_i < Z_NUM_COLS; zkacc_i = zkacc_i + 1) zkacc_mem[zkacc_i] = {ZACCW2{1'b0}};

    // Bins per zoom column (1 or 2), for the mean: not a table but worked out as the walk goes from
    // column to column, one a clock. zwfrac is the low 20 bits of (first bin of the column) * scale; the
    // column has a second bin if zwfrac + scale < 2^20.
    reg  signed [21:0] zwfrac;
    wire signed [21:0] zwn1 = zwfrac + zm1_q;
    wire signed [21:0] zwn2 = zwfrac + zm2_q;

    // One zoom line buffer, not two (docs/ZOOM_IN_CHIP.md section 11): the compositor copies the line
    // into its own snapshot memory, so a second buffer here would only keep that copy from seeing a
    // line half old and half new, which it can now see (two consecutive lines, for one picture).
    reg [15:0] zline_buf_mem [0:Z_NUM_COLS-1];

    // ================================================================
    // shared walk engine: one spectrum_walk_core.v instance, two request-holding wrappers (one per
    // context; each holds a request level until the engine grants it, with a defensive retry if a
    // second frame completes before the first was granted). See spectrum_walk_core.v's own header for the
    // arbitration and hazard analysis. K, the number of frames averaged per line, is clamped to 1 ..
    // 2^20 - 1.
    // ================================================================
    wire [19:0] kA_clamp = (avg_k == 32'd0) ? 20'd1 :
                           (avg_k[31:20] != 0) ? 20'hFFFFF : avg_k[19:0];
    wire [19:0] kB_clamp = (zavg_k == 32'd0) ? 20'd1 :
                           (zavg_k[31:20] != 0) ? 20'hFFFFF : zavg_k[19:0];

    // "count - 1" in registers (the counts are settings; one clock late on a change) and "the next
    // position is the last": position == count - 2, or count == 1 when the group restarts (the position
    // never reaches count, so count - 2 = all ones is never met)
    reg [31:0] kA_m1 = 32'd0, kB_m1 = 32'd0, kA_m2 = 32'd0, kB_m2 = 32'd0;
    reg        kA_is1 = 1'b0, kB_is1 = 1'b0;
    always @(posedge clk) begin
        kA_m1  <= {12'b0, kA_clamp} - 32'd1;
        kB_m1  <= {12'b0, kB_clamp} - 32'd1;
        kA_m2  <= {12'b0, kA_clamp} - 32'd2;
        kB_m2  <= {12'b0, kB_clamp} - 32'd2;
        kA_is1 <= (kA_clamp == 20'd1);
        kB_is1 <= (kB_clamp == 20'd1);
    end

    reg         reqA_valid, reqA_finalize, reqA_first_of_group, reqA_pending2;
    reg [31:0]  groupA_pos;
    wire [31:0] groupA_pos_next = reqA_finalize ? 32'd0 : (groupA_pos + 32'd1);
    wire        grant_a_wc;

    always @(posedge clk) begin
        if (rst) begin
            reqA_valid <= 1'b0; reqA_pending2 <= 1'b0; groupA_pos <= 32'd0;
        end else if (grant_a_wc) begin
            groupA_pos <= groupA_pos_next;
            if (reqA_pending2 || frame_last2) begin
                reqA_valid          <= 1'b1;
                reqA_finalize       <= (reqA_finalize ? kA_is1 : (groupA_pos == kA_m2));
                reqA_first_of_group <= (groupA_pos_next == 32'd0);
                reqA_pending2       <= 1'b0;
            end else begin
                reqA_valid <= 1'b0;
            end
        end else if (frame_last2) begin
            if (!reqA_valid) begin
                reqA_valid          <= 1'b1;
                reqA_finalize       <= (groupA_pos == kA_m1);
                reqA_first_of_group <= (groupA_pos == 32'd0);
            end else begin
                reqA_pending2 <= 1'b1;   // defensive: not expected to trigger, see F2_SPECTRUM.md
            end
        end
    end

    reg         reqB_valid, reqB_finalize, reqB_first_of_group, reqB_pending2;
    reg [31:0]  groupB_pos;
    wire [31:0] groupB_pos_next = reqB_finalize ? 32'd0 : (groupB_pos + 32'd1);
    wire        grant_b_wc;
    // "this frame is the last of its group", for the frame now and for the next one, as registers: the
    // frame counter moves once per walk and is read a zoom frame later, and an add and a 32-bit compare
    // behind a selection in one clock would be too long
    reg [31:0]  zk_last;                                // K - 1 (the register is written long before it is used)
    reg [31:0]  zgrp_p1;
    reg         zlast_cur, zlast_nxt, zlast_zero;
    always @(posedge clk) begin
        zk_last    <= {12'b0, kB_clamp} - 32'd1;
        zgrp_p1    <= groupB_pos + 32'd1;
        zlast_cur  <= (groupB_pos == zk_last);
        zlast_nxt  <= (zgrp_p1 == zk_last);
        zlast_zero <= (zk_last == 32'd0);
    end

    always @(posedge clk) begin
        if (rst) begin
            reqB_valid <= 1'b0; reqB_pending2 <= 1'b0; groupB_pos <= 32'd0;
        end else if (grant_b_wc) begin
            groupB_pos <= groupB_pos_next;
            if (reqB_pending2 || zframe_last2) begin
                reqB_valid          <= 1'b1;
                reqB_finalize       <= reqB_finalize ? zlast_zero : zlast_nxt;
                reqB_first_of_group <= (groupB_pos_next == 32'd0);
                reqB_pending2       <= 1'b0;
            end else begin
                reqB_valid <= 1'b0;
            end
        end else if (zframe_last2) begin
            if (!reqB_valid) begin
                reqB_valid          <= 1'b1;
                reqB_finalize       <= zlast_cur;
                reqB_first_of_group <= (groupB_pos == 32'd0);
            end else begin
                reqB_pending2 <= 1'b1;   // defensive: not expected to trigger
            end
        end
    end

    wire        wc_col_addr_v;
    wire        wc_busy, wc_active_ctx;
    wire        wc_kacc_wr_v;
    wire [10:0] wc_kacc_wr_addr;
    wire [ACCW2-1:0] wc_kacc_wr_data;
    wire        wc_kacc_wr_ctx, wc_line_ctx;
    wire        wc_line_v;
    wire [10:0] wc_line_col;
    wire signed [15:0] wc_line_db64;
    wire        wc_line_last;

    assign walkA_busy = wc_busy & ~wc_active_ctx;
    assign walkB_busy = wc_busy &  wc_active_ctx;

    // Each context's walk-side read port is gated by its own walkX_busy so cfa_mem/kacc_mem never
    // need a third port: while a context is not being walked, its only other accessor is that
    // context's own front-end read-modify-write pipeline above (1 read + 1 write, unconditionally
    // safe on a plain dual-port BSRAM); while it IS being walked, the front end only pushes into
    // its FIFO (no cfa_mem access at all), leaving the walk-side port as the sole accessor.
    // (cfa_mem's walk read comes from the shared read register cfa_rdsh: the word read in a
    // busy clock is the one visible in the next, held after the walk stops)
    reg             walkA_busy_q = 1'b0;
    reg [ACCW1-1:0] cfaA_hold;
    wire [ACCW1-1:0] cfaA_rd_wc = walkA_busy_q ? cfa_rdsh : cfaA_hold;
    reg [ACCW2-1:0] kaccA_rd_wc;
    reg [2:0]       binsA_rd_wc;
    always @(posedge clk) begin
        walkA_busy_q <= walkA_busy;
        cfaA_hold    <= cfaA_rd_wc;
    end
    always @(posedge clk) if (walkA_busy) begin
        kaccA_rd_wc <= kacc_mem[wc_col_addr];
        binsA_rd_wc <= col_bins_rom[wc_col_addr];
    end

    reg             walkB_busy_q = 1'b0;
    reg [ZACCW1-1:0] cfaB_hold;
    wire [ZACCW1-1:0] cfaB_rd_z = walkB_busy_q ? zcfa_rdsh : cfaB_hold;
    wire [ACCW1-1:0] cfaB_rd_wc = {{(ACCW1-ZACCW1){1'b0}}, cfaB_rd_z};
    reg [ZACCW2-1:0] kaccB_rd_z;
    wire [ACCW2-1:0] kaccB_rd_wc = {{(ACCW2-ZACCW2){1'b0}}, kaccB_rd_z};
    reg [2:0]       binsB_rd_wc;
    always @(posedge clk) begin
        walkB_busy_q <= walkB_busy;
        cfaB_hold    <= cfaB_rd_z;
    end
    always @(posedge clk) if (walkB_busy) begin
        kaccB_rd_z  <= zkacc_mem[wc_col_addr];
        binsB_rd_wc <= zwn1[21] ? 3'd2 : 3'd1;
    end
    always @(posedge clk)
        if (!walkB_busy) zwfrac <= 22'sd0;
        else             zwfrac <= zwn1[21] ? zwn2 : zwn1;

    spectrum_walk_core #(
        .NUM_COLS(NUM_COLS), .ACCW1(ACCW1), .ACCW2(ACCW2), .DIV_W(DIV_W), .TW_DIR(TW_DIR)
    ) u_walk (
        .clk(clk), .rst(rst),
        .req_a_valid(reqA_valid), .req_a_finalize(reqA_finalize),
        .req_a_first_of_group(reqA_first_of_group), .req_a_peak_hold(ctrl_peak_hold),
        .req_a_k_clamp(kA_clamp), .grant_a(grant_a_wc),
        .req_b_valid(reqB_valid), .req_b_finalize(reqB_finalize),
        .req_b_first_of_group(reqB_first_of_group), .req_b_peak_hold(zctrl_peak_hold),
        .req_b_k_clamp(kB_clamp), .grant_b(grant_b_wc),
        .busy(wc_busy), .active_ctx(wc_active_ctx),
        .col_addr(wc_col_addr), .col_addr_v(wc_col_addr_v),
        .cfa_rdata(wc_active_ctx ? cfaB_rd_wc : cfaA_rd_wc),
        .bins_rdata(wc_active_ctx ? binsB_rd_wc : binsA_rd_wc),
        .kacc_rdata(wc_active_ctx ? kaccB_rd_wc : kaccA_rd_wc),
        .kacc_wr_v(wc_kacc_wr_v), .kacc_wr_addr(wc_kacc_wr_addr), .kacc_wr_data(wc_kacc_wr_data),
        .kacc_wr_ctx(wc_kacc_wr_ctx),
        .line_v(wc_line_v), .line_col(wc_line_col), .line_db64(wc_line_db64), .line_last(wc_line_last),
        .line_ctx(wc_line_ctx)
    );

    always @(posedge clk) begin
        if (wc_kacc_wr_v && !wc_kacc_wr_ctx) kacc_mem[wc_kacc_wr_addr] <= wc_kacc_wr_data;
    end

    // the zoom's K-frame memory is written one clock later, saturated to ZACCW2 bits (the walk reads a
    // column once and writes it a few clocks later; the next walk is a zoom frame away)
    reg              zk_wv;
    reg [10:0]       zk_wa;
    reg [ZACCW2-1:0] zk_wd;
    always @(posedge clk) begin
        zk_wv <= rst ? 1'b0 : (wc_kacc_wr_v & wc_kacc_wr_ctx);
        zk_wa <= wc_kacc_wr_addr;
        zk_wd <= (|wc_kacc_wr_data[ACCW2-1:ZACCW2]) ? {ZACCW2{1'b1}} : wc_kacc_wr_data[ZACCW2-1:0];
        if (zk_wv) zkacc_mem[zk_wa] <= zk_wd;
    end

    // ================================================================
    // full-band line buffer + waterfall output (context A of the shared walk engine)
    // ================================================================
    wire lineA_v    = wc_line_v & ~wc_line_ctx;
    wire lineA_last = wc_line_last & ~wc_line_ctx;

    always @(posedge clk) begin
        ready_buf_reg <= 1'b0;
        if (rst)             line_count_reg <= 32'd0;
        else if (lineA_last) line_count_reg <= line_count_reg + 32'd1;
    end

    assign line_complete_pulse = lineA_last;

    always @(posedge clk) if (lineA_v) line_buf_mem[wc_line_col] <= wc_line_db64;

    wire signed [16:0] adj17    = {wc_line_db64[15], wc_line_db64} + {level_offset[15], level_offset};
    wire signed [33:0] colprod  = adj17 * $signed({1'b0, level_gain});
    wire signed [33:0] colshift = colprod >>> 14;
    wire [7:0] color_byte = (colshift < 0) ? 8'd0 : (colshift > 34'sd255) ? 8'd255 : colshift[7:0];

    always @(posedge clk) begin
        wf_valid <= rst ? 1'b0 : lineA_v;
        wf_data  <= color_byte;
        wf_sol   <= (wc_line_col == 11'd0);
        wf_eol   <= (wc_line_col == NUM_COLS[10:0] - 11'd1);
    end

    // a read of the column being written in the same clock gets the new word (as the zoom's line buffer)
    reg [15:0] line_q, line_fw;
    reg        line_hit;
    always @(posedge clk) begin
        line_q   <= line_buf_mem[line_rd_addr];
        line_hit <= lineA_v & (wc_line_col == line_rd_addr);
        line_fw  <= wc_line_db64;
    end
    always @(*) line_rd_data = line_hit ? line_fw : line_q;

    // ================================================================
    // zoom line buffer + waterfall output (context B of the shared walk engine)
    // ================================================================
    wire lineB_v    = wc_line_v & wc_line_ctx;
    wire lineB_last = wc_line_last & wc_line_ctx;

    always @(posedge clk) begin
        zready_buf_reg <= 1'b0;                 // one buffer: backend_line_status.ready_buffer reads 0
        if (rst)             zline_count_reg <= 32'd0;
        else if (lineB_last) zline_count_reg <= zline_count_reg + 32'd1;
    end

    assign zline_complete_pulse = lineB_last;

    always @(posedge clk) if (lineB_v) zline_buf_mem[wc_line_col] <= wc_line_db64;

    // the color byte in three clocks (offset; gain; clamp), because the walk's dB value through an add, a
    // 17 x 17 multiply and the clamp in one clock is too long. The byte stream is two clocks later than
    // the full band's; the writer takes it as it comes.
    reg  signed [16:0] zadj17;
    reg  signed [33:0] zcolprod;
    reg  [2:0]         zwf_v_p, zwf_sol_p, zwf_eol_p;
    wire signed [33:0] zcolshift = zcolprod >>> 14;
    wire [7:0] zcolor_byte = (zcolshift < 0) ? 8'd0 : (zcolshift > 34'sd255) ? 8'd255 : zcolshift[7:0];

    always @(posedge clk) begin
        zadj17    <= {wc_line_db64[15], wc_line_db64} + {zlevel_offset[15], zlevel_offset};
        zcolprod  <= zadj17 * $signed({1'b0, zlevel_gain});
        zwf_v_p   <= rst ? 3'd0 : {zwf_v_p[1:0], lineB_v};
        zwf_sol_p <= {zwf_sol_p[1:0], (wc_line_col == 11'd0)};
        zwf_eol_p <= {zwf_eol_p[1:0], (wc_line_col == Z_NUM_COLS[10:0] - 11'd1)};
        zwf_valid <= rst ? 1'b0 : zwf_v_p[1];
        zwf_data  <= zcolor_byte;
        zwf_sol   <= zwf_sol_p[1];
        zwf_eol   <= zwf_eol_p[1];
    end

    // a read of the column being written in the same clock gets the new word (the memory's own answer
    // to that is not defined)
    reg [15:0] zline_q, zline_fw;
    reg        zline_hit;
    always @(posedge clk) begin
        zline_q   <= zline_buf_mem[zline_rd_addr];
        zline_hit <= lineB_v & (wc_line_col == zline_rd_addr);
        zline_fw  <= wc_line_db64;
    end
    assign zline_rd_data = zline_hit ? zline_fw : zline_q;

endmodule
