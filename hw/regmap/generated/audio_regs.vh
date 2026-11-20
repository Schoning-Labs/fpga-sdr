// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

// GENERATED FILE -- do not edit by hand. Produced by `cargo run -p xtask -- regmap`
// from hw/regmap/audio.toml. See docs/REGMAP.md.
//
// Audio engine (docs/ARCHITECTURE.md 3.7): ring pointers for the 48 kHz stereo ring firmware
// writes, PT8211 output volume, and low-water status. The ring's sample storage is in DDR3
// (5.4); this block is pointers and control only.
// status: draft

`ifndef SDR_REGMAP_AUDIO_VH
`define SDR_REGMAP_AUDIO_VH

`define AUDIO_BASE 32'hE8090000
`define AUDIO_SIZE 32'h00010000

// id -- Block identifier/version: 'AU' + version 1 (set by the chip top level).
`define AUDIO_ID_ADDR 32'h00000000
`define AUDIO_ID_ABS_ADDR (`AUDIO_BASE + `AUDIO_ID_ADDR)
`define AUDIO_ID_RESET 32'h41550001

// ctrl -- Output enable.
`define AUDIO_CTRL_ADDR 32'h00000004
`define AUDIO_CTRL_ABS_ADDR (`AUDIO_BASE + `AUDIO_CTRL_ADDR)
`define AUDIO_CTRL_RESET 32'h00000000
`define AUDIO_CTRL_ENABLE_LSB 0
`define AUDIO_CTRL_ENABLE_MSB 0
`define AUDIO_CTRL_ENABLE_WIDTH 1

// ring_base -- Ring base address in DDR3 (docs/ARCHITECTURE.md 5.4: within the 0x1200_0000 IQ/audio/TX ring region).
`define AUDIO_RING_BASE_ADDR 32'h00000008
`define AUDIO_RING_BASE_ABS_ADDR (`AUDIO_BASE + `AUDIO_RING_BASE_ADDR)
`define AUDIO_RING_BASE_RESET 32'h12000000

// ring_size -- Ring size in stereo sample frames (power of two).
`define AUDIO_RING_SIZE_ADDR 32'h0000000C
`define AUDIO_RING_SIZE_ABS_ADDR (`AUDIO_BASE + `AUDIO_RING_SIZE_ADDR)
`define AUDIO_RING_SIZE_RESET 32'h00000000

// ring_wptr -- Write pointer, in frames. Written by firmware after it writes back the new samples' cache lines (docs/ARCHITECTURE.md 4.2, CPU-written ring).
`define AUDIO_RING_WPTR_ADDR 32'h00000010
`define AUDIO_RING_WPTR_ABS_ADDR (`AUDIO_BASE + `AUDIO_RING_WPTR_ADDR)
`define AUDIO_RING_WPTR_RESET 32'h00000000

// ring_rptr -- Read pointer, in frames. Updated by the fabric consumer; firmware reads it to know how much room remains before overrunning it.
`define AUDIO_RING_RPTR_ADDR 32'h00000014
`define AUDIO_RING_RPTR_ABS_ADDR (`AUDIO_BASE + `AUDIO_RING_RPTR_ADDR)
`define AUDIO_RING_RPTR_RESET 32'h00000000

// volume -- Output volume, 0-255 linear (ARCHITECTURE 3.7: the PT8211 itself has no volume control).
`define AUDIO_VOLUME_ADDR 32'h00000018
`define AUDIO_VOLUME_ABS_ADDR (`AUDIO_BASE + `AUDIO_VOLUME_ADDR)
`define AUDIO_VOLUME_RESET 32'h00000080

// status -- Sticky low-water flag, matching fabric interrupt line 3 (ARCHITECTURE 4.3).
`define AUDIO_STATUS_ADDR 32'h0000001C
`define AUDIO_STATUS_ABS_ADDR (`AUDIO_BASE + `AUDIO_STATUS_ADDR)
`define AUDIO_STATUS_RESET 32'h00000000
`define AUDIO_STATUS_LOW_WATER_LSB 0
`define AUDIO_STATUS_LOW_WATER_MSB 0
`define AUDIO_STATUS_LOW_WATER_WIDTH 1

// out_ctrl -- Digital audio outputs (docs/AUDIO_OUT.md). They carry the engine's 48 kHz stream, zeros while the engine is off or its ring is empty.
`define AUDIO_OUT_CTRL_ADDR 32'h00000020
`define AUDIO_OUT_CTRL_ABS_ADDR (`AUDIO_BASE + `AUDIO_OUT_CTRL_ADDR)
`define AUDIO_OUT_CTRL_RESET 32'h00000003
`define AUDIO_OUT_CTRL_SPDIF_LSB 0
`define AUDIO_OUT_CTRL_SPDIF_MSB 0
`define AUDIO_OUT_CTRL_SPDIF_WIDTH 1
`define AUDIO_OUT_CTRL_I2S_LSB 1
`define AUDIO_OUT_CTRL_I2S_MSB 1
`define AUDIO_OUT_CTRL_I2S_WIDTH 1
`define AUDIO_OUT_CTRL_TONE_LSB 2
`define AUDIO_OUT_CTRL_TONE_MSB 2
`define AUDIO_OUT_CTRL_TONE_WIDTH 1

// out_status -- State of the digital outputs. The two counters wrap at 255.
`define AUDIO_OUT_STATUS_ADDR 32'h00000024
`define AUDIO_OUT_STATUS_ABS_ADDR (`AUDIO_BASE + `AUDIO_OUT_STATUS_ADDR)
`define AUDIO_OUT_STATUS_RESET 32'h00000000
`define AUDIO_OUT_STATUS_PLL_LOCK_LSB 0
`define AUDIO_OUT_STATUS_PLL_LOCK_MSB 0
`define AUDIO_OUT_STATUS_PLL_LOCK_WIDTH 1
`define AUDIO_OUT_STATUS_RUN_LSB 1
`define AUDIO_OUT_STATUS_RUN_MSB 1
`define AUDIO_OUT_STATUS_RUN_WIDTH 1
`define AUDIO_OUT_STATUS_LIVE_LSB 2
`define AUDIO_OUT_STATUS_LIVE_MSB 2
`define AUDIO_OUT_STATUS_LIVE_WIDTH 1
`define AUDIO_OUT_STATUS_SLIPS_LSB 8
`define AUDIO_OUT_STATUS_SLIPS_MSB 15
`define AUDIO_OUT_STATUS_SLIPS_WIDTH 8
`define AUDIO_OUT_STATUS_ERRORS_LSB 16
`define AUDIO_OUT_STATUS_ERRORS_MSB 23
`define AUDIO_OUT_STATUS_ERRORS_WIDTH 8

`endif // SDR_REGMAP_AUDIO_VH
