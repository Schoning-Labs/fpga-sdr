// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

// GENERATED FILE -- do not edit by hand. Produced by `cargo run -p xtask -- regmap`
// from hw/regmap/spectrum.toml. See docs/REGMAP.md.
//
// Full-band spectrum (docs/ARCHITECTURE.md 3.3): 16,384-point FFT over the raw 12-bit stream,
// column reduction, averaging, and the waterfall colour mapping. Output lines land in a
// double-buffered line buffer and a waterfall ring in DDR3 (not registers, see 3.5); this block
// is control and status only.
// status: final

`ifndef SDR_REGMAP_SPECTRUM_VH
`define SDR_REGMAP_SPECTRUM_VH

`define SPECTRUM_BASE 32'hE8050000
`define SPECTRUM_SIZE 32'h00010000

// id -- Block identifier/version; rtl/spectrum/spectrum_pipeline.v is version 1.
`define SPECTRUM_ID_ADDR 32'h00000000
`define SPECTRUM_ID_ABS_ADDR (`SPECTRUM_BASE + `SPECTRUM_ID_ADDR)
`define SPECTRUM_ID_RESET 32'h00000001

// ctrl -- Enable and per-column reduction mode.
`define SPECTRUM_CTRL_ADDR 32'h00000004
`define SPECTRUM_CTRL_ABS_ADDR (`SPECTRUM_BASE + `SPECTRUM_CTRL_ADDR)
`define SPECTRUM_CTRL_RESET 32'h00000000
`define SPECTRUM_CTRL_ENABLE_LSB 0
`define SPECTRUM_CTRL_ENABLE_MSB 0
`define SPECTRUM_CTRL_ENABLE_WIDTH 1
`define SPECTRUM_CTRL_COLUMN_MODE_LSB 1
`define SPECTRUM_CTRL_COLUMN_MODE_MSB 1
`define SPECTRUM_CTRL_COLUMN_MODE_WIDTH 1
`define SPECTRUM_CTRL_PEAK_HOLD_LSB 2
`define SPECTRUM_CTRL_PEAK_HOLD_MSB 2
`define SPECTRUM_CTRL_PEAK_HOLD_WIDTH 1

// averaging_k -- Transforms averaged per output line. ARCHITECTURE 3.3 example: K = 156 for 30 lines/s at the full 4,687.5 transforms/s rate.
`define SPECTRUM_AVERAGING_K_ADDR 32'h00000008
`define SPECTRUM_AVERAGING_K_ABS_ADDR (`SPECTRUM_BASE + `SPECTRUM_AVERAGING_K_ADDR)
`define SPECTRUM_AVERAGING_K_RESET 32'h0000009C

// level -- Firmware-set offset and gain applied before the 8-bit waterfall colour index (ARCHITECTURE 3.3).
`define SPECTRUM_LEVEL_ADDR 32'h0000000C
`define SPECTRUM_LEVEL_ABS_ADDR (`SPECTRUM_BASE + `SPECTRUM_LEVEL_ADDR)
`define SPECTRUM_LEVEL_RESET 32'h01000000
`define SPECTRUM_LEVEL_OFFSET_DB64_LSB 0
`define SPECTRUM_LEVEL_OFFSET_DB64_MSB 15
`define SPECTRUM_LEVEL_OFFSET_DB64_WIDTH 16
`define SPECTRUM_LEVEL_GAIN_Q8_LSB 16
`define SPECTRUM_LEVEL_GAIN_Q8_MSB 31
`define SPECTRUM_LEVEL_GAIN_Q8_WIDTH 16

// line_count -- Free-running count of spectrum lines produced, for firmware pacing against the waterfall writer.
`define SPECTRUM_LINE_COUNT_ADDR 32'h00000010
`define SPECTRUM_LINE_COUNT_ABS_ADDR (`SPECTRUM_BASE + `SPECTRUM_LINE_COUNT_ADDR)
`define SPECTRUM_LINE_COUNT_RESET 32'h00000000

// line_status -- Which of the two spectrum line buffers is ready to read (double-buffered, ARCHITECTURE 3.3).
`define SPECTRUM_LINE_STATUS_ADDR 32'h00000014
`define SPECTRUM_LINE_STATUS_ABS_ADDR (`SPECTRUM_BASE + `SPECTRUM_LINE_STATUS_ADDR)
`define SPECTRUM_LINE_STATUS_RESET 32'h00000000
`define SPECTRUM_LINE_STATUS_READY_BUFFER_LSB 0
`define SPECTRUM_LINE_STATUS_READY_BUFFER_MSB 0
`define SPECTRUM_LINE_STATUS_READY_BUFFER_WIDTH 1
`define SPECTRUM_LINE_STATUS_LINE_DONE_LSB 1
`define SPECTRUM_LINE_STATUS_LINE_DONE_MSB 1
`define SPECTRUM_LINE_STATUS_LINE_DONE_WIDTH 1

`endif // SDR_REGMAP_SPECTRUM_VH
