// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

// GENERATED FILE -- do not edit by hand. Produced by `cargo run -p xtask -- regmap`
// from hw/regmap/system.toml. See docs/REGMAP.md.
//
// System block (docs/ARCHITECTURE.md 4.1, 4.3): identification, a scratch register, the 16 fabric
// interrupt lines GP0-GP15 (pending, enable, raw), clock and memory status, and a free-running
// clk_dsp cycle counter. rtl/top/sys_regs.v, docs/P1_TOP.md.
// status: draft

`ifndef SDR_REGMAP_SYSTEM_VH
`define SDR_REGMAP_SYSTEM_VH

`define SYSTEM_BASE 32'hE8000000
`define SYSTEM_SIZE 32'h00010000

// id -- Chip identifier: 'TR' + top-level version 1.
`define SYSTEM_ID_ADDR 32'h00000000
`define SYSTEM_ID_ABS_ADDR (`SYSTEM_BASE + `SYSTEM_ID_ADDR)
`define SYSTEM_ID_RESET 32'h54520001

// build -- Build identifier: the first 8 hex digits of the git commit the bitstream was built from (gowin/p1/build.sh); 0 in simulation.
`define SYSTEM_BUILD_ADDR 32'h00000004
`define SYSTEM_BUILD_ABS_ADDR (`SYSTEM_BASE + `SYSTEM_BUILD_ADDR)
`define SYSTEM_BUILD_RESET 32'h00000000

// scratch -- Scratch register for bus tests; no effect.
`define SYSTEM_SCRATCH_ADDR 32'h00000008
`define SYSTEM_SCRATCH_ABS_ADDR (`SYSTEM_BASE + `SYSTEM_SCRATCH_ADDR)
`define SYSTEM_SCRATCH_RESET 32'h00000000

// irq_pending -- Latched interrupt events, one bit per fabric line GP0-GP15 (docs/ARCHITECTURE.md 4.3). A bit is set by a rising edge of its source; the PLIC line is pending AND enable.
`define SYSTEM_IRQ_PENDING_ADDR 32'h00000010
`define SYSTEM_IRQ_PENDING_ABS_ADDR (`SYSTEM_BASE + `SYSTEM_IRQ_PENDING_ADDR)
`define SYSTEM_IRQ_PENDING_RESET 32'h00000000
`define SYSTEM_IRQ_PENDING_LINES_LSB 0
`define SYSTEM_IRQ_PENDING_LINES_MSB 15
`define SYSTEM_IRQ_PENDING_LINES_WIDTH 16

// irq_enable -- Per-line enable of the pending bits onto the AE350's EXT_INT inputs.
`define SYSTEM_IRQ_ENABLE_ADDR 32'h00000014
`define SYSTEM_IRQ_ENABLE_ABS_ADDR (`SYSTEM_BASE + `SYSTEM_IRQ_ENABLE_ADDR)
`define SYSTEM_IRQ_ENABLE_RESET 32'h00000000
`define SYSTEM_IRQ_ENABLE_LINES_LSB 0
`define SYSTEM_IRQ_ENABLE_LINES_MSB 15
`define SYSTEM_IRQ_ENABLE_LINES_WIDTH 16

// irq_raw -- Current level of each interrupt source, before edge latching.
`define SYSTEM_IRQ_RAW_ADDR 32'h00000018
`define SYSTEM_IRQ_RAW_ABS_ADDR (`SYSTEM_BASE + `SYSTEM_IRQ_RAW_ADDR)
`define SYSTEM_IRQ_RAW_RESET 32'h00000000
`define SYSTEM_IRQ_RAW_LINES_LSB 0
`define SYSTEM_IRQ_RAW_LINES_MSB 15
`define SYSTEM_IRQ_RAW_LINES_WIDTH 16

// status -- Clock, memory and bus-bridge status.
`define SYSTEM_STATUS_ADDR 32'h0000001C
`define SYSTEM_STATUS_ABS_ADDR (`SYSTEM_BASE + `SYSTEM_STATUS_ADDR)
`define SYSTEM_STATUS_RESET 32'h00000000
`define SYSTEM_STATUS_DDR3_INIT_LSB 0
`define SYSTEM_STATUS_DDR3_INIT_MSB 0
`define SYSTEM_STATUS_DDR3_INIT_WIDTH 1
`define SYSTEM_STATUS_PLLS_LOCKED_LSB 1
`define SYSTEM_STATUS_PLLS_LOCKED_MSB 1
`define SYSTEM_STATUS_PLLS_LOCKED_WIDTH 1
`define SYSTEM_STATUS_BUS_TIMEOUT_LSB 8
`define SYSTEM_STATUS_BUS_TIMEOUT_MSB 8
`define SYSTEM_STATUS_BUS_TIMEOUT_WIDTH 1
`define SYSTEM_STATUS_RX_DOMAIN_DEAD_LSB 9
`define SYSTEM_STATUS_RX_DOMAIN_DEAD_MSB 9
`define SYSTEM_STATUS_RX_DOMAIN_DEAD_WIDTH 1
`define SYSTEM_STATUS_NUM_RX_LSB 16
`define SYSTEM_STATUS_NUM_RX_MSB 19
`define SYSTEM_STATUS_NUM_RX_WIDTH 4

// dsp_cycles -- Free-running clk_dsp (120 MHz) cycle counter, low 32 bits.
`define SYSTEM_DSP_CYCLES_ADDR 32'h00000020
`define SYSTEM_DSP_CYCLES_ABS_ADDR (`SYSTEM_BASE + `SYSTEM_DSP_CYCLES_ADDR)
`define SYSTEM_DSP_CYCLES_RESET 32'h00000000

`endif // SDR_REGMAP_SYSTEM_VH
