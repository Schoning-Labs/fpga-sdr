// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

// GENERATED FILE -- do not edit by hand. Produced by `cargo run -p xtask -- regmap`
// from hw/regmap/zoom.toml. See docs/REGMAP.md.
//
// Zoom DDC and zoom FFT (docs/ARCHITECTURE.md 3.4, docs/F3_ZOOM.md): tunes a zoom centre and a span
// (3 kHz to 3.072 MHz, powers of two), decimates, windows, and runs a 4,096-point complex FFT over
// rtl/zoom/zoom_spectrum.v. Also the zoom backend: column reduction, K-frame averaging, dB
// conversion and waterfall colour mapping over that FFT's output, sharing its arithmetic (log-domain
// K-average, docs/ARCHITECTURE.md 3.14 change C6a) with the full-band spectrum's own walk engine.
// Output (line values, waterfall bytes) is not in this register block; it is a fabric stream/port,
// consumed the same way full-band spectrum output is (see the spectrum block).
// status: final

`ifndef SDR_REGMAP_ZOOM_VH
`define SDR_REGMAP_ZOOM_VH

`define ZOOM_BASE 32'hE8060000
`define ZOOM_SIZE 32'h00010000

// id -- Block identifier/version: 'ZM' + version 2 (version 2: narrow_shift, narrow_gain, backend_ft8_columns; one line buffer). Reads 0 in a chip built without the zoom receiver.
`define ZOOM_ID_ADDR 32'h00000000
`define ZOOM_ID_ABS_ADDR (`ZOOM_BASE + `ZOOM_ID_ADDR)
`define ZOOM_ID_RESET 32'h5A4D0002

// phase_inc -- Zoom-centre NCO phase increment: round(f_Hz / 76.8e6 * 2^32), signed two's complement, relative to the HL2 ADC clock (0.018 Hz steps). Same convention as rx_bank's phase_inc.
`define ZOOM_PHASE_INC_ADDR 32'h00000004
`define ZOOM_PHASE_INC_ABS_ADDR (`ZOOM_BASE + `ZOOM_PHASE_INC_ADDR)
`define ZOOM_PHASE_INC_RESET 32'h00000000
`define ZOOM_PHASE_INC_VALUE_LSB 0
`define ZOOM_PHASE_INC_VALUE_MSB 31
`define ZOOM_PHASE_INC_VALUE_WIDTH 32

// ctrl -- Zoom DDC/FFT enable and span selection.
`define ZOOM_CTRL_ADDR 32'h00000008
`define ZOOM_CTRL_ABS_ADDR (`ZOOM_BASE + `ZOOM_CTRL_ADDR)
`define ZOOM_CTRL_RESET 32'h0000000C
`define ZOOM_CTRL_ENABLE_LSB 0
`define ZOOM_CTRL_ENABLE_MSB 0
`define ZOOM_CTRL_ENABLE_WIDTH 1
`define ZOOM_CTRL_SPAN_SHIFT_LSB 1
`define ZOOM_CTRL_SPAN_SHIFT_MSB 3
`define ZOOM_CTRL_SPAN_SHIFT_WIDTH 3
`define ZOOM_CTRL_BACKEND_COLUMN_MODE_LSB 4
`define ZOOM_CTRL_BACKEND_COLUMN_MODE_MSB 4
`define ZOOM_CTRL_BACKEND_COLUMN_MODE_WIDTH 1
`define ZOOM_CTRL_BACKEND_PEAK_HOLD_LSB 5
`define ZOOM_CTRL_BACKEND_PEAK_HOLD_MSB 5
`define ZOOM_CTRL_BACKEND_PEAK_HOLD_WIDTH 1
`define ZOOM_CTRL_NARROW_SHIFT_LSB 6
`define ZOOM_CTRL_NARROW_SHIFT_MSB 8
`define ZOOM_CTRL_NARROW_SHIFT_WIDTH 3
`define ZOOM_CTRL_NARROW_GAIN_LSB 9
`define ZOOM_CTRL_NARROW_GAIN_MSB 10
`define ZOOM_CTRL_NARROW_GAIN_WIDTH 2
`define ZOOM_CTRL_BACKEND_FT8_COLUMNS_LSB 11
`define ZOOM_CTRL_BACKEND_FT8_COLUMNS_MSB 11
`define ZOOM_CTRL_BACKEND_FT8_COLUMNS_WIDTH 1

// backend_averaging_k -- Zoom backend: zoom FFT frames averaged per output line. Reset default 32 is a placeholder (the zoom FFT's own frame rate varies with span_shift, unlike the full-band spectrum's fixed 4,687.5 transforms/s); firmware sets this once the target line rate is known.
`define ZOOM_BACKEND_AVERAGING_K_ADDR 32'h0000000C
`define ZOOM_BACKEND_AVERAGING_K_ABS_ADDR (`ZOOM_BASE + `ZOOM_BACKEND_AVERAGING_K_ADDR)
`define ZOOM_BACKEND_AVERAGING_K_RESET 32'h00000020

// backend_level -- Zoom backend: firmware-set offset and gain applied before the 8-bit waterfall colour index, same formula as the full-band spectrum's own level register.
`define ZOOM_BACKEND_LEVEL_ADDR 32'h00000010
`define ZOOM_BACKEND_LEVEL_ABS_ADDR (`ZOOM_BASE + `ZOOM_BACKEND_LEVEL_ADDR)
`define ZOOM_BACKEND_LEVEL_RESET 32'h01000000
`define ZOOM_BACKEND_LEVEL_OFFSET_DB64_LSB 0
`define ZOOM_BACKEND_LEVEL_OFFSET_DB64_MSB 15
`define ZOOM_BACKEND_LEVEL_OFFSET_DB64_WIDTH 16
`define ZOOM_BACKEND_LEVEL_GAIN_Q8_LSB 16
`define ZOOM_BACKEND_LEVEL_GAIN_Q8_MSB 31
`define ZOOM_BACKEND_LEVEL_GAIN_Q8_WIDTH 16

// backend_line_count -- Zoom backend: free-running count of zoom spectrum lines produced.
`define ZOOM_BACKEND_LINE_COUNT_ADDR 32'h00000014
`define ZOOM_BACKEND_LINE_COUNT_ABS_ADDR (`ZOOM_BASE + `ZOOM_BACKEND_LINE_COUNT_ADDR)
`define ZOOM_BACKEND_LINE_COUNT_RESET 32'h00000000

// backend_line_status -- Zoom backend: line status. There is one zoom line buffer since id version 2 (the compositor keeps its own copy of the line).
`define ZOOM_BACKEND_LINE_STATUS_ADDR 32'h00000018
`define ZOOM_BACKEND_LINE_STATUS_ABS_ADDR (`ZOOM_BASE + `ZOOM_BACKEND_LINE_STATUS_ADDR)
`define ZOOM_BACKEND_LINE_STATUS_RESET 32'h00000000
`define ZOOM_BACKEND_LINE_STATUS_READY_BUFFER_LSB 0
`define ZOOM_BACKEND_LINE_STATUS_READY_BUFFER_MSB 0
`define ZOOM_BACKEND_LINE_STATUS_READY_BUFFER_WIDTH 1
`define ZOOM_BACKEND_LINE_STATUS_LINE_DONE_LSB 1
`define ZOOM_BACKEND_LINE_STATUS_LINE_DONE_MSB 1
`define ZOOM_BACKEND_LINE_STATUS_LINE_DONE_WIDTH 1

`endif // SDR_REGMAP_ZOOM_VH
