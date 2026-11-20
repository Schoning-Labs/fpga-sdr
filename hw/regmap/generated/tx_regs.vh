// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

// GENERATED FILE -- do not edit by hand. Produced by `cargo run -p xtask -- regmap`
// from hw/regmap/tx.toml. See docs/REGMAP.md.
//
// TX chain (docs/ARCHITECTURE.md 3.6): baseband ring pointers, interpolate/CORDIC up-mix enable
// and gain, NCO phase increment, and rate-trim status. The framer that actually sends TX frames
// to the HL2 is in the hl2_link block (0xE801_0000, tx_ctrl/tx_fifo_fill/tx_trim); this block is
// the DSP chain feeding it.
// status: draft

`ifndef SDR_REGMAP_TX_VH
`define SDR_REGMAP_TX_VH

`define TX_BASE 32'hE8080000
`define TX_SIZE 32'h00010000

// id -- Block identifier/version: 'TX' + version 1 (set by the chip top level).
`define TX_ID_ADDR 32'h00000000
`define TX_ID_ABS_ADDR (`TX_BASE + `TX_ID_ADDR)
`define TX_ID_RESET 32'h54580001

// ctrl -- Chain enable.
`define TX_CTRL_ADDR 32'h00000004
`define TX_CTRL_ABS_ADDR (`TX_BASE + `TX_CTRL_ADDR)
`define TX_CTRL_RESET 32'h00000000
`define TX_CTRL_ENABLE_LSB 0
`define TX_CTRL_ENABLE_MSB 0
`define TX_CTRL_ENABLE_WIDTH 1

// gain -- Output gain before the 12-bit round (ARCHITECTURE 3.6 item 2).
`define TX_GAIN_ADDR 32'h00000008
`define TX_GAIN_ABS_ADDR (`TX_BASE + `TX_GAIN_ADDR)
`define TX_GAIN_RESET 32'h00000000
`define TX_GAIN_VALUE_LSB 0
`define TX_GAIN_VALUE_MSB 15
`define TX_GAIN_VALUE_WIDTH 16

// nco_phase_inc -- CORDIC up-mix frequency, same format as the receiver bank's phase_inc (docs/ARCHITECTURE.md 3.2, 3.6).
`define TX_NCO_PHASE_INC_ADDR 32'h0000000C
`define TX_NCO_PHASE_INC_ABS_ADDR (`TX_BASE + `TX_NCO_PHASE_INC_ADDR)
`define TX_NCO_PHASE_INC_RESET 32'h00000000
`define TX_NCO_PHASE_INC_VALUE_LSB 0
`define TX_NCO_PHASE_INC_VALUE_MSB 31
`define TX_NCO_PHASE_INC_VALUE_WIDTH 32

// ring_base -- Baseband ring base address in DDR3 (docs/ARCHITECTURE.md 5.4).
`define TX_RING_BASE_ADDR 32'h00000010
`define TX_RING_BASE_ABS_ADDR (`TX_BASE + `TX_RING_BASE_ADDR)
`define TX_RING_BASE_RESET 32'h12000000

// ring_size -- Ring size in complex sample frames (power of two).
`define TX_RING_SIZE_ADDR 32'h00000014
`define TX_RING_SIZE_ABS_ADDR (`TX_BASE + `TX_RING_SIZE_ADDR)
`define TX_RING_SIZE_RESET 32'h00000000

// ring_wptr -- Write pointer, in frames. Written by firmware after it writes back the new samples' cache lines (docs/ARCHITECTURE.md 4.2, CPU-written ring).
`define TX_RING_WPTR_ADDR 32'h00000018
`define TX_RING_WPTR_ABS_ADDR (`TX_BASE + `TX_RING_WPTR_ADDR)
`define TX_RING_WPTR_RESET 32'h00000000

// ring_rptr -- Read pointer, in frames. Updated by the fabric consumer.
`define TX_RING_RPTR_ADDR 32'h0000001C
`define TX_RING_RPTR_ABS_ADDR (`TX_BASE + `TX_RING_RPTR_ADDR)
`define TX_RING_RPTR_RESET 32'h00000000

// status -- Rate-trim direction and sticky low-water flag, matching fabric interrupt line 4 (ARCHITECTURE 4.3).
`define TX_STATUS_ADDR 32'h00000020
`define TX_STATUS_ABS_ADDR (`TX_BASE + `TX_STATUS_ADDR)
`define TX_STATUS_RESET 32'h00000000
`define TX_STATUS_LOW_WATER_LSB 0
`define TX_STATUS_LOW_WATER_MSB 0
`define TX_STATUS_LOW_WATER_WIDTH 1
`define TX_STATUS_TRIMMING_UP_LSB 1
`define TX_STATUS_TRIMMING_UP_MSB 1
`define TX_STATUS_TRIMMING_UP_WIDTH 1

`endif // SDR_REGMAP_TX_VH
