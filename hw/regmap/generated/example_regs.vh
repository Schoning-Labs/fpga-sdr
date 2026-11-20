// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

// GENERATED FILE -- do not edit by hand. Produced by `cargo run -p xtask -- regmap`
// from hw/regmap/example.toml. See docs/REGMAP.md.
//
// Regmap generator self-test fixture. Not a real fabric block.
// status: test

`ifndef SDR_REGMAP_EXAMPLE_VH
`define SDR_REGMAP_EXAMPLE_VH

`define EXAMPLE_BASE 32'hE8EE0000
`define EXAMPLE_SIZE 32'h00001000

// id -- Fixed block identifier and format version; read-only.
`define EXAMPLE_ID_ADDR 32'h00000000
`define EXAMPLE_ID_ABS_ADDR (`EXAMPLE_BASE + `EXAMPLE_ID_ADDR)
`define EXAMPLE_ID_RESET 32'h1CE50001

// ctrl -- Control: an enable bit and a two-bit mode select.
`define EXAMPLE_CTRL_ADDR 32'h00000004
`define EXAMPLE_CTRL_ABS_ADDR (`EXAMPLE_BASE + `EXAMPLE_CTRL_ADDR)
`define EXAMPLE_CTRL_RESET 32'h00000000
`define EXAMPLE_CTRL_ENABLE_LSB 0
`define EXAMPLE_CTRL_ENABLE_MSB 0
`define EXAMPLE_CTRL_ENABLE_WIDTH 1
`define EXAMPLE_CTRL_MODE_LSB 1
`define EXAMPLE_CTRL_MODE_MSB 2
`define EXAMPLE_CTRL_MODE_WIDTH 2

// status -- Sticky status flags. Each bit is set by hardware and cleared by firmware writing a 1 to it (write-1-to-clear); see docs/REGMAP.md on why a register with W1C fields gets no modify().
`define EXAMPLE_STATUS_ADDR 32'h00000008
`define EXAMPLE_STATUS_ABS_ADDR (`EXAMPLE_BASE + `EXAMPLE_STATUS_ADDR)
`define EXAMPLE_STATUS_RESET 32'h00000000
`define EXAMPLE_STATUS_OVERFLOW_LSB 0
`define EXAMPLE_STATUS_OVERFLOW_MSB 0
`define EXAMPLE_STATUS_OVERFLOW_WIDTH 1
`define EXAMPLE_STATUS_ERROR_LSB 1
`define EXAMPLE_STATUS_ERROR_MSB 1
`define EXAMPLE_STATUS_ERROR_WIDTH 1

// channel -- Per-channel gain, four instances at consecutive words (docs/ARCHITECTURE.md 3.2's per-receiver phase_inc/ctrl pair is the real-block version of this shape).
`define EXAMPLE_CHANNEL_OFFSET 32'h00000010
`define EXAMPLE_CHANNEL_STRIDE 32'h00000004
`define EXAMPLE_CHANNEL_COUNT 4
`define EXAMPLE_CHANNEL_ADDR(i) (`EXAMPLE_CHANNEL_OFFSET + (i)*`EXAMPLE_CHANNEL_STRIDE)
`define EXAMPLE_CHANNEL_ABS_ADDR(i) (`EXAMPLE_BASE + `EXAMPLE_CHANNEL_ADDR(i))
`define EXAMPLE_CHANNEL_RESET 32'h00000080
`define EXAMPLE_CHANNEL_GAIN_LSB 0
`define EXAMPLE_CHANNEL_GAIN_MSB 7
`define EXAMPLE_CHANNEL_GAIN_WIDTH 8

`endif // SDR_REGMAP_EXAMPLE_VH
