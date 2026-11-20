// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

// GENERATED FILE -- do not edit by hand. Produced by `cargo run -p xtask -- regmap`
// from hw/regmap/rx_bank.toml. See docs/REGMAP.md.
//
// Receiver bank (docs/ARCHITECTURE.md 3.2): per-receiver NCO phase increment and control for the
// CORDIC/CIC/FIR chain in rtl/rx/rx_bank.v (branch rx-dsp). N = 4 to 8 receivers, one register
// port, one shared IQ output stream (not in this register block; see the IQ writer at
// 0xE804_0000).
// status: draft

`ifndef SDR_REGMAP_RX_BANK_VH
`define SDR_REGMAP_RX_BANK_VH

`define RX_BANK_BASE 32'hE8030000
`define RX_BANK_SIZE 32'h00010000

// id -- Block identifier/version: 'RX' + version 1 (set by the chip top level).
`define RX_BANK_ID_ADDR 32'h00000000
`define RX_BANK_ID_ABS_ADDR (`RX_BANK_BASE + `RX_BANK_ID_ADDR)
`define RX_BANK_ID_RESET 32'h52580001

// phase_inc -- Per-receiver NCO phase increment: round(f_Hz / 76.8e6 * 2^32), signed two's complement, relative to the HL2 ADC clock (0.018 Hz steps).
`define RX_BANK_PHASE_INC_OFFSET 32'h00000004
`define RX_BANK_PHASE_INC_STRIDE 32'h00000008
`define RX_BANK_PHASE_INC_COUNT 8
`define RX_BANK_PHASE_INC_ADDR(i) (`RX_BANK_PHASE_INC_OFFSET + (i)*`RX_BANK_PHASE_INC_STRIDE)
`define RX_BANK_PHASE_INC_ABS_ADDR(i) (`RX_BANK_BASE + `RX_BANK_PHASE_INC_ADDR(i))
`define RX_BANK_PHASE_INC_RESET 32'h00000000
`define RX_BANK_PHASE_INC_VALUE_LSB 0
`define RX_BANK_PHASE_INC_VALUE_MSB 31
`define RX_BANK_PHASE_INC_VALUE_WIDTH 32

// ctrl -- Per-receiver enable and output rate.
`define RX_BANK_CTRL_OFFSET 32'h00000008
`define RX_BANK_CTRL_STRIDE 32'h00000008
`define RX_BANK_CTRL_COUNT 8
`define RX_BANK_CTRL_ADDR(i) (`RX_BANK_CTRL_OFFSET + (i)*`RX_BANK_CTRL_STRIDE)
`define RX_BANK_CTRL_ABS_ADDR(i) (`RX_BANK_BASE + `RX_BANK_CTRL_ADDR(i))
`define RX_BANK_CTRL_RESET 32'h00000000
`define RX_BANK_CTRL_ENABLE_LSB 0
`define RX_BANK_CTRL_ENABLE_MSB 0
`define RX_BANK_CTRL_ENABLE_WIDTH 1
`define RX_BANK_CTRL_RATE_SEL_LSB 1
`define RX_BANK_CTRL_RATE_SEL_MSB 2
`define RX_BANK_CTRL_RATE_SEL_WIDTH 2

`endif // SDR_REGMAP_RX_BANK_VH
