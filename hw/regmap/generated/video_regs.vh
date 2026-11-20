// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

// GENERATED FILE -- do not edit by hand. Produced by `cargo run -p xtask -- regmap`
// from hw/regmap/video.toml. See docs/REGMAP.md.
//
// Video compositor (docs/ARCHITECTURE.md 3.5, docs/V2_COMPOSITOR.md): enable, Slint framebuffer
// base/stride, up to 4 FPGA windows (spectrum trace or waterfall; waterfall in windows 0 and 1
// only, each with its own ring and scroll line), the waterfall palettes, colours, grid, 8 receiver passbands, a tuning cursor, and the
// status and underrun counters.
// status: final

`ifndef SDR_REGMAP_VIDEO_VH
`define SDR_REGMAP_VIDEO_VH

`define VIDEO_BASE 32'hE8070000
`define VIDEO_SIZE 32'h00010000

// id -- Block identifier/version: 'VI' + version 2 (version 2: a ring base and a scroll line per waterfall window, the zoom waterfall ring).
`define VIDEO_ID_ADDR 32'h00000000
`define VIDEO_ID_ABS_ADDR (`VIDEO_BASE + `VIDEO_ID_ADDR)
`define VIDEO_ID_RESET 32'h56490002

// ctrl -- Output enable and refresh-rate select.
`define VIDEO_CTRL_ADDR 32'h00000004
`define VIDEO_CTRL_ABS_ADDR (`VIDEO_BASE + `VIDEO_CTRL_ADDR)
`define VIDEO_CTRL_RESET 32'h00000000
`define VIDEO_CTRL_ENABLE_LSB 0
`define VIDEO_CTRL_ENABLE_MSB 0
`define VIDEO_CTRL_ENABLE_WIDTH 1
`define VIDEO_CTRL_MODE_30HZ_LSB 1
`define VIDEO_CTRL_MODE_30HZ_MSB 1
`define VIDEO_CTRL_MODE_30HZ_WIDTH 1

// fb_base -- Slint framebuffer base address in DDR3, byte address, multiple of 8 (docs/ARCHITECTURE.md 5.4: two 4 MB buffers from 0x1000_0000). Takes effect at the next vertical blank: this is the buffer swap.
`define VIDEO_FB_BASE_ADDR 32'h00000008
`define VIDEO_FB_BASE_ABS_ADDR (`VIDEO_BASE + `VIDEO_FB_BASE_ADDR)
`define VIDEO_FB_BASE_RESET 32'h10000000

// fb_stride -- Framebuffer stride in bytes, multiple of 8. Reset value is 1,920 x 2 B (RGB565, ARCHITECTURE 3.5 item 1).
`define VIDEO_FB_STRIDE_ADDR 32'h0000000C
`define VIDEO_FB_STRIDE_ABS_ADDR (`VIDEO_BASE + `VIDEO_FB_STRIDE_ADDR)
`define VIDEO_FB_STRIDE_RESET 32'h00000F00

// win_pos -- Window top-left corner, one of up to 4 FPGA windows (ARCHITECTURE 3.5 item 2). Windows must not overlap: where they do, the lowest-numbered window wins but its grid lines are not reliable.
`define VIDEO_WIN_POS_OFFSET 32'h00000020
`define VIDEO_WIN_POS_STRIDE 32'h00000010
`define VIDEO_WIN_POS_COUNT 4
`define VIDEO_WIN_POS_ADDR(i) (`VIDEO_WIN_POS_OFFSET + (i)*`VIDEO_WIN_POS_STRIDE)
`define VIDEO_WIN_POS_ABS_ADDR(i) (`VIDEO_BASE + `VIDEO_WIN_POS_ADDR(i))
`define VIDEO_WIN_POS_RESET 32'h00000000
`define VIDEO_WIN_POS_X_LSB 0
`define VIDEO_WIN_POS_X_MSB 11
`define VIDEO_WIN_POS_X_WIDTH 12
`define VIDEO_WIN_POS_Y_LSB 16
`define VIDEO_WIN_POS_Y_MSB 27
`define VIDEO_WIN_POS_Y_WIDTH 12

// win_size -- Window width/height, paired with win_pos at the same index.
`define VIDEO_WIN_SIZE_OFFSET 32'h00000024
`define VIDEO_WIN_SIZE_STRIDE 32'h00000010
`define VIDEO_WIN_SIZE_COUNT 4
`define VIDEO_WIN_SIZE_ADDR(i) (`VIDEO_WIN_SIZE_OFFSET + (i)*`VIDEO_WIN_SIZE_STRIDE)
`define VIDEO_WIN_SIZE_ABS_ADDR(i) (`VIDEO_BASE + `VIDEO_WIN_SIZE_ADDR(i))
`define VIDEO_WIN_SIZE_RESET 32'h00000000
`define VIDEO_WIN_SIZE_W_LSB 0
`define VIDEO_WIN_SIZE_W_MSB 11
`define VIDEO_WIN_SIZE_W_WIDTH 12
`define VIDEO_WIN_SIZE_H_LSB 16
`define VIDEO_WIN_SIZE_H_MSB 27
`define VIDEO_WIN_SIZE_H_WIDTH 12

// win_ctrl -- Window type/source/enable, paired with win_pos/win_size at the same index.
`define VIDEO_WIN_CTRL_OFFSET 32'h00000028
`define VIDEO_WIN_CTRL_STRIDE 32'h00000010
`define VIDEO_WIN_CTRL_COUNT 4
`define VIDEO_WIN_CTRL_ADDR(i) (`VIDEO_WIN_CTRL_OFFSET + (i)*`VIDEO_WIN_CTRL_STRIDE)
`define VIDEO_WIN_CTRL_ABS_ADDR(i) (`VIDEO_BASE + `VIDEO_WIN_CTRL_ADDR(i))
`define VIDEO_WIN_CTRL_RESET 32'h00000000
`define VIDEO_WIN_CTRL_ENABLE_LSB 0
`define VIDEO_WIN_CTRL_ENABLE_MSB 0
`define VIDEO_WIN_CTRL_ENABLE_WIDTH 1
`define VIDEO_WIN_CTRL_TYPE_WATERFALL_LSB 1
`define VIDEO_WIN_CTRL_TYPE_WATERFALL_MSB 1
`define VIDEO_WIN_CTRL_TYPE_WATERFALL_WIDTH 1
`define VIDEO_WIN_CTRL_SOURCE_ZOOM_LSB 2
`define VIDEO_WIN_CTRL_SOURCE_ZOOM_MSB 2
`define VIDEO_WIN_CTRL_SOURCE_ZOOM_WIDTH 1

// win_src -- Source column offset of window i: window column 0 shows source column x0 (spectrum line or waterfall line, 0-1,919).
`define VIDEO_WIN_SRC_OFFSET 32'h0000002C
`define VIDEO_WIN_SRC_STRIDE 32'h00000010
`define VIDEO_WIN_SRC_COUNT 4
`define VIDEO_WIN_SRC_ADDR(i) (`VIDEO_WIN_SRC_OFFSET + (i)*`VIDEO_WIN_SRC_STRIDE)
`define VIDEO_WIN_SRC_ABS_ADDR(i) (`VIDEO_BASE + `VIDEO_WIN_SRC_ADDR(i))
`define VIDEO_WIN_SRC_RESET 32'h00000000
`define VIDEO_WIN_SRC_X0_LSB 0
`define VIDEO_WIN_SRC_X0_MSB 11
`define VIDEO_WIN_SRC_X0_WIDTH 12

// palette_index -- Index into the waterfall palette; write here, then write palette_data.
`define VIDEO_PALETTE_INDEX_ADDR 32'h00000060
`define VIDEO_PALETTE_INDEX_ABS_ADDR (`VIDEO_BASE + `VIDEO_PALETTE_INDEX_ADDR)
`define VIDEO_PALETTE_INDEX_RESET 32'h00000000
`define VIDEO_PALETTE_INDEX_VALUE_LSB 0
`define VIDEO_PALETTE_INDEX_VALUE_MSB 7
`define VIDEO_PALETTE_INDEX_VALUE_WIDTH 8
`define VIDEO_PALETTE_INDEX_WHICH_LSB 8
`define VIDEO_PALETTE_INDEX_WHICH_MSB 8
`define VIDEO_PALETTE_INDEX_WHICH_WIDTH 1

// palette_data -- Colour for the palette entry selected by palette_index. Writing this register stores the entry (the palette is BSRAM). Reads return the last value written.
`define VIDEO_PALETTE_DATA_ADDR 32'h00000064
`define VIDEO_PALETTE_DATA_ABS_ADDR (`VIDEO_BASE + `VIDEO_PALETTE_DATA_ADDR)
`define VIDEO_PALETTE_DATA_RESET 32'h00000000
`define VIDEO_PALETTE_DATA_RGB_LSB 0
`define VIDEO_PALETTE_DATA_RGB_MSB 23
`define VIDEO_PALETTE_DATA_RGB_WIDTH 24

// wf_ring_base -- Full-band waterfall writer: lane-word address of line 0 of the ring it writes. Set it before the full-band spectrum is enabled.
`define VIDEO_WF_RING_BASE_ADDR 32'h00000070
`define VIDEO_WF_RING_BASE_ABS_ADDR (`VIDEO_BASE + `VIDEO_WF_RING_BASE_ADDR)
`define VIDEO_WF_RING_BASE_RESET 32'h00000000

// wf_write_line -- Full-band waterfall writer: index of the last fully written line (0-2,047; 2,047 after reset = none yet).
`define VIDEO_WF_WRITE_LINE_ADDR 32'h00000074
`define VIDEO_WF_WRITE_LINE_ABS_ADDR (`VIDEO_BASE + `VIDEO_WF_WRITE_LINE_ADDR)
`define VIDEO_WF_WRITE_LINE_RESET 32'h00000000

// wf_zoom_ring_base -- Zoom waterfall writer: lane-word address of line 0 of the ring it writes. Set it before the zoom spectrum is enabled.
`define VIDEO_WF_ZOOM_RING_BASE_ADDR 32'h0000007C
`define VIDEO_WF_ZOOM_RING_BASE_ABS_ADDR (`VIDEO_BASE + `VIDEO_WF_ZOOM_RING_BASE_ADDR)
`define VIDEO_WF_ZOOM_RING_BASE_RESET 32'h00000000

// key -- Key colour: where the Slint framebuffer holds this RGB565 value inside a window, the FPGA layer shows through (ARCHITECTURE 3.5 item 4).
`define VIDEO_KEY_ADDR 32'h00000078
`define VIDEO_KEY_ABS_ADDR (`VIDEO_BASE + `VIDEO_KEY_ADDR)
`define VIDEO_KEY_RESET 32'h0000F81F
`define VIDEO_KEY_RGB565_LSB 0
`define VIDEO_KEY_RGB565_MSB 15
`define VIDEO_KEY_RGB565_WIDTH 16

// status -- Compositor status. Writing 1 to underrun also clears underrun_count.
`define VIDEO_STATUS_ADDR 32'h00000080
`define VIDEO_STATUS_ABS_ADDR (`VIDEO_BASE + `VIDEO_STATUS_ADDR)
`define VIDEO_STATUS_RESET 32'h00000000
`define VIDEO_STATUS_UNDERRUN_LSB 0
`define VIDEO_STATUS_UNDERRUN_MSB 0
`define VIDEO_STATUS_UNDERRUN_WIDTH 1
`define VIDEO_STATUS_LANE_ERROR_LSB 1
`define VIDEO_STATUS_LANE_ERROR_MSB 1
`define VIDEO_STATUS_LANE_ERROR_WIDTH 1

// underrun_count -- Number of underrun lines since reset or since underrun was cleared. Counts only while ctrl.enable is 1.
`define VIDEO_UNDERRUN_COUNT_ADDR 32'h00000084
`define VIDEO_UNDERRUN_COUNT_ABS_ADDR (`VIDEO_BASE + `VIDEO_UNDERRUN_COUNT_ADDR)
`define VIDEO_UNDERRUN_COUNT_RESET 32'h00000000

// frame_count -- Frames shown since reset; increments when the shadow copy is taken (line 1082). A framebuffer swap written before this changes has taken effect once the value has changed twice.
`define VIDEO_FRAME_COUNT_ADDR 32'h00000088
`define VIDEO_FRAME_COUNT_ABS_ADDR (`VIDEO_BASE + `VIDEO_FRAME_COUNT_ADDR)
`define VIDEO_FRAME_COUNT_RESET 32'h00000000

// fb_active -- Framebuffer base currently in the shadow copy (the frame being scanned out or about to be). The other buffer is free to draw into.
`define VIDEO_FB_ACTIVE_ADDR 32'h0000008C
`define VIDEO_FB_ACTIVE_ABS_ADDR (`VIDEO_BASE + `VIDEO_FB_ACTIVE_ADDR)
`define VIDEO_FB_ACTIVE_RESET 32'h00000000

// wf_zoom_write_line -- Zoom waterfall writer: index of the last fully written line (0-2,047; 2,047 after reset = none yet).
`define VIDEO_WF_ZOOM_WRITE_LINE_ADDR 32'h00000094
`define VIDEO_WF_ZOOM_WRITE_LINE_ABS_ADDR (`VIDEO_BASE + `VIDEO_WF_ZOOM_WRITE_LINE_ADDR)
`define VIDEO_WF_ZOOM_WRITE_LINE_RESET 32'h00000000

// wf_win_ring -- Waterfall window i (0, 1): lane-word address of line 0 of the ring the window shows. To show a hardware writer's ring write the same value as that writer's ring base. Taken at the vertical blank.
`define VIDEO_WF_WIN_RING_OFFSET 32'h000000A0
`define VIDEO_WF_WIN_RING_STRIDE 32'h00000010
`define VIDEO_WF_WIN_RING_COUNT 2
`define VIDEO_WF_WIN_RING_ADDR(i) (`VIDEO_WF_WIN_RING_OFFSET + (i)*`VIDEO_WF_WIN_RING_STRIDE)
`define VIDEO_WF_WIN_RING_ABS_ADDR(i) (`VIDEO_BASE + `VIDEO_WF_WIN_RING_ADDR(i))
`define VIDEO_WF_WIN_RING_RESET 32'h00000000

// wf_win_ctrl -- Waterfall window i: where its scroll line comes from. The window shows ring line (scroll line - row) mod 2,048 in window row `row`: the newest line at the top.
`define VIDEO_WF_WIN_CTRL_OFFSET 32'h000000A4
`define VIDEO_WF_WIN_CTRL_STRIDE 32'h00000010
`define VIDEO_WF_WIN_CTRL_COUNT 2
`define VIDEO_WF_WIN_CTRL_ADDR(i) (`VIDEO_WF_WIN_CTRL_OFFSET + (i)*`VIDEO_WF_WIN_CTRL_STRIDE)
`define VIDEO_WF_WIN_CTRL_ABS_ADDR(i) (`VIDEO_BASE + `VIDEO_WF_WIN_CTRL_ADDR(i))
`define VIDEO_WF_WIN_CTRL_RESET 32'h00000000
`define VIDEO_WF_WIN_CTRL_LINE_SRC_LSB 0
`define VIDEO_WF_WIN_CTRL_LINE_SRC_MSB 1
`define VIDEO_WF_WIN_CTRL_LINE_SRC_WIDTH 2

// wf_win_line -- Waterfall window i: the scroll line the CPU writes (used when wf_win_ctrl.line_src = 2). Write the new line's bytes to DDR3 first, then this register. Taken at the vertical blank.
`define VIDEO_WF_WIN_LINE_OFFSET 32'h000000A8
`define VIDEO_WF_WIN_LINE_STRIDE 32'h00000010
`define VIDEO_WF_WIN_LINE_COUNT 2
`define VIDEO_WF_WIN_LINE_ADDR(i) (`VIDEO_WF_WIN_LINE_OFFSET + (i)*`VIDEO_WF_WIN_LINE_STRIDE)
`define VIDEO_WF_WIN_LINE_ABS_ADDR(i) (`VIDEO_BASE + `VIDEO_WF_WIN_LINE_ADDR(i))
`define VIDEO_WF_WIN_LINE_RESET 32'h00000000
`define VIDEO_WF_WIN_LINE_LINE_LSB 0
`define VIDEO_WF_WIN_LINE_LINE_MSB 10
`define VIDEO_WF_WIN_LINE_LINE_WIDTH 11

// wf_win_top -- Waterfall window i: ring line shown in its top row in the current frame (the scroll line as latched at the vertical blank).
`define VIDEO_WF_WIN_TOP_OFFSET 32'h000000AC
`define VIDEO_WF_WIN_TOP_STRIDE 32'h00000010
`define VIDEO_WF_WIN_TOP_COUNT 2
`define VIDEO_WF_WIN_TOP_ADDR(i) (`VIDEO_WF_WIN_TOP_OFFSET + (i)*`VIDEO_WF_WIN_TOP_STRIDE)
`define VIDEO_WF_WIN_TOP_ABS_ADDR(i) (`VIDEO_BASE + `VIDEO_WF_WIN_TOP_ADDR(i))
`define VIDEO_WF_WIN_TOP_RESET 32'h00000000

// win_scale -- Spectrum trace vertical scale of window i: row = (ref - level) x gain, level in 1/64 dB as in the spectrum line buffer.
`define VIDEO_WIN_SCALE_OFFSET 32'h00000100
`define VIDEO_WIN_SCALE_STRIDE 32'h00000020
`define VIDEO_WIN_SCALE_COUNT 4
`define VIDEO_WIN_SCALE_ADDR(i) (`VIDEO_WIN_SCALE_OFFSET + (i)*`VIDEO_WIN_SCALE_STRIDE)
`define VIDEO_WIN_SCALE_ABS_ADDR(i) (`VIDEO_BASE + `VIDEO_WIN_SCALE_ADDR(i))
`define VIDEO_WIN_SCALE_RESET 32'h01000000
`define VIDEO_WIN_SCALE_TOP_LEVEL_LSB 0
`define VIDEO_WIN_SCALE_TOP_LEVEL_MSB 15
`define VIDEO_WIN_SCALE_TOP_LEVEL_WIDTH 16
`define VIDEO_WIN_SCALE_GAIN_LSB 16
`define VIDEO_WIN_SCALE_GAIN_MSB 31
`define VIDEO_WIN_SCALE_GAIN_WIDTH 16

// win_gridx -- Vertical grid lines (frequency) of window i, drawn in col_grid over the window.
`define VIDEO_WIN_GRIDX_OFFSET 32'h00000104
`define VIDEO_WIN_GRIDX_STRIDE 32'h00000020
`define VIDEO_WIN_GRIDX_COUNT 4
`define VIDEO_WIN_GRIDX_ADDR(i) (`VIDEO_WIN_GRIDX_OFFSET + (i)*`VIDEO_WIN_GRIDX_STRIDE)
`define VIDEO_WIN_GRIDX_ABS_ADDR(i) (`VIDEO_BASE + `VIDEO_WIN_GRIDX_ADDR(i))
`define VIDEO_WIN_GRIDX_RESET 32'h00000000
`define VIDEO_WIN_GRIDX_FIRST_LSB 0
`define VIDEO_WIN_GRIDX_FIRST_MSB 11
`define VIDEO_WIN_GRIDX_FIRST_WIDTH 12
`define VIDEO_WIN_GRIDX_STEP_LSB 16
`define VIDEO_WIN_GRIDX_STEP_MSB 27
`define VIDEO_WIN_GRIDX_STEP_WIDTH 12

// win_gridy -- Horizontal grid lines (level) of window i; trace windows only.
`define VIDEO_WIN_GRIDY_OFFSET 32'h00000108
`define VIDEO_WIN_GRIDY_STRIDE 32'h00000020
`define VIDEO_WIN_GRIDY_COUNT 4
`define VIDEO_WIN_GRIDY_ADDR(i) (`VIDEO_WIN_GRIDY_OFFSET + (i)*`VIDEO_WIN_GRIDY_STRIDE)
`define VIDEO_WIN_GRIDY_ABS_ADDR(i) (`VIDEO_BASE + `VIDEO_WIN_GRIDY_ADDR(i))
`define VIDEO_WIN_GRIDY_RESET 32'h00000000
`define VIDEO_WIN_GRIDY_FIRST_LSB 0
`define VIDEO_WIN_GRIDY_FIRST_MSB 11
`define VIDEO_WIN_GRIDY_FIRST_WIDTH 12
`define VIDEO_WIN_GRIDY_STEP_LSB 16
`define VIDEO_WIN_GRIDY_STEP_MSB 27
`define VIDEO_WIN_GRIDY_STEP_WIDTH 12

// col_bg -- Trace window background colour.
`define VIDEO_COL_BG_ADDR 32'h00000180
`define VIDEO_COL_BG_ABS_ADDR (`VIDEO_BASE + `VIDEO_COL_BG_ADDR)
`define VIDEO_COL_BG_RESET 32'h00000000
`define VIDEO_COL_BG_RGB_LSB 0
`define VIDEO_COL_BG_RGB_MSB 23
`define VIDEO_COL_BG_RGB_WIDTH 24

// col_fill -- Trace window colour below the trace line.
`define VIDEO_COL_FILL_ADDR 32'h00000184
`define VIDEO_COL_FILL_ABS_ADDR (`VIDEO_BASE + `VIDEO_COL_FILL_ADDR)
`define VIDEO_COL_FILL_RESET 32'h00003060
`define VIDEO_COL_FILL_RGB_LSB 0
`define VIDEO_COL_FILL_RGB_MSB 23
`define VIDEO_COL_FILL_RGB_WIDTH 24

// col_trace -- Trace line colour.
`define VIDEO_COL_TRACE_ADDR 32'h00000188
`define VIDEO_COL_TRACE_ABS_ADDR (`VIDEO_BASE + `VIDEO_COL_TRACE_ADDR)
`define VIDEO_COL_TRACE_RESET 32'h00FFFF00
`define VIDEO_COL_TRACE_RGB_LSB 0
`define VIDEO_COL_TRACE_RGB_MSB 23
`define VIDEO_COL_TRACE_RGB_WIDTH 24

// col_grid -- Grid line colour.
`define VIDEO_COL_GRID_ADDR 32'h0000018C
`define VIDEO_COL_GRID_ABS_ADDR (`VIDEO_BASE + `VIDEO_COL_GRID_ADDR)
`define VIDEO_COL_GRID_RESET 32'h00606060
`define VIDEO_COL_GRID_RGB_LSB 0
`define VIDEO_COL_GRID_RGB_MSB 23
`define VIDEO_COL_GRID_RGB_WIDTH 24

// cursor_ctrl -- Tuning cursor: a vertical line across the windows selected by window_mask.
`define VIDEO_CURSOR_CTRL_ADDR 32'h00000190
`define VIDEO_CURSOR_CTRL_ABS_ADDR (`VIDEO_BASE + `VIDEO_CURSOR_CTRL_ADDR)
`define VIDEO_CURSOR_CTRL_RESET 32'h00000100
`define VIDEO_CURSOR_CTRL_ENABLE_LSB 0
`define VIDEO_CURSOR_CTRL_ENABLE_MSB 0
`define VIDEO_CURSOR_CTRL_ENABLE_WIDTH 1
`define VIDEO_CURSOR_CTRL_WINDOW_MASK_LSB 1
`define VIDEO_CURSOR_CTRL_WINDOW_MASK_MSB 4
`define VIDEO_CURSOR_CTRL_WINDOW_MASK_WIDTH 4
`define VIDEO_CURSOR_CTRL_WIDTH_LSB 8
`define VIDEO_CURSOR_CTRL_WIDTH_MSB 11
`define VIDEO_CURSOR_CTRL_WIDTH_WIDTH 4

// cursor_x -- Cursor left edge, screen pixels.
`define VIDEO_CURSOR_X_ADDR 32'h00000194
`define VIDEO_CURSOR_X_ABS_ADDR (`VIDEO_BASE + `VIDEO_CURSOR_X_ADDR)
`define VIDEO_CURSOR_X_RESET 32'h00000000
`define VIDEO_CURSOR_X_X_LSB 0
`define VIDEO_CURSOR_X_X_MSB 11
`define VIDEO_CURSOR_X_X_WIDTH 12

// cursor_col -- Cursor colour.
`define VIDEO_CURSOR_COL_ADDR 32'h00000198
`define VIDEO_CURSOR_COL_ABS_ADDR (`VIDEO_BASE + `VIDEO_CURSOR_COL_ADDR)
`define VIDEO_CURSOR_COL_RESET 32'h00FF0000
`define VIDEO_CURSOR_COL_RGB_LSB 0
`define VIDEO_CURSOR_COL_RGB_MSB 23
`define VIDEO_CURSOR_COL_RGB_WIDTH 24

// pb_range -- Receiver passband k: screen columns x0 <= x < x1.
`define VIDEO_PB_RANGE_OFFSET 32'h00000200
`define VIDEO_PB_RANGE_STRIDE 32'h00000010
`define VIDEO_PB_RANGE_COUNT 8
`define VIDEO_PB_RANGE_ADDR(i) (`VIDEO_PB_RANGE_OFFSET + (i)*`VIDEO_PB_RANGE_STRIDE)
`define VIDEO_PB_RANGE_ABS_ADDR(i) (`VIDEO_BASE + `VIDEO_PB_RANGE_ADDR(i))
`define VIDEO_PB_RANGE_RESET 32'h00000000
`define VIDEO_PB_RANGE_X0_LSB 0
`define VIDEO_PB_RANGE_X0_MSB 11
`define VIDEO_PB_RANGE_X0_WIDTH 12
`define VIDEO_PB_RANGE_X1_LSB 16
`define VIDEO_PB_RANGE_X1_MSB 27
`define VIDEO_PB_RANGE_X1_WIDTH 12

// pb_ctrl -- Receiver passband k: where the lowest-numbered enabled passband covering a pixel blends its colour over the picture.
`define VIDEO_PB_CTRL_OFFSET 32'h00000204
`define VIDEO_PB_CTRL_STRIDE 32'h00000010
`define VIDEO_PB_CTRL_COUNT 8
`define VIDEO_PB_CTRL_ADDR(i) (`VIDEO_PB_CTRL_OFFSET + (i)*`VIDEO_PB_CTRL_STRIDE)
`define VIDEO_PB_CTRL_ABS_ADDR(i) (`VIDEO_BASE + `VIDEO_PB_CTRL_ADDR(i))
`define VIDEO_PB_CTRL_RESET 32'h00000800
`define VIDEO_PB_CTRL_ENABLE_LSB 0
`define VIDEO_PB_CTRL_ENABLE_MSB 0
`define VIDEO_PB_CTRL_ENABLE_WIDTH 1
`define VIDEO_PB_CTRL_WINDOW_MASK_LSB 1
`define VIDEO_PB_CTRL_WINDOW_MASK_MSB 4
`define VIDEO_PB_CTRL_WINDOW_MASK_WIDTH 4
`define VIDEO_PB_CTRL_ALPHA_LSB 8
`define VIDEO_PB_CTRL_ALPHA_MSB 12
`define VIDEO_PB_CTRL_ALPHA_WIDTH 5

// pb_col -- Receiver passband k colour.
`define VIDEO_PB_COL_OFFSET 32'h00000208
`define VIDEO_PB_COL_STRIDE 32'h00000010
`define VIDEO_PB_COL_COUNT 8
`define VIDEO_PB_COL_ADDR(i) (`VIDEO_PB_COL_OFFSET + (i)*`VIDEO_PB_COL_STRIDE)
`define VIDEO_PB_COL_ABS_ADDR(i) (`VIDEO_BASE + `VIDEO_PB_COL_ADDR(i))
`define VIDEO_PB_COL_RESET 32'h0000A0FF
`define VIDEO_PB_COL_RGB_LSB 0
`define VIDEO_PB_COL_RGB_MSB 23
`define VIDEO_PB_COL_RGB_WIDTH 24

`endif // SDR_REGMAP_VIDEO_VH
