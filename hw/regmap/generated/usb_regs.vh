// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

// GENERATED FILE -- do not edit by hand. Produced by `cargo run -p xtask -- regmap`
// from hw/regmap/usb.toml. See docs/REGMAP.md.
//
// USB audio device on the "Custom USB" socket (docs/USB_AUDIO.md, rtl/usb/usb_regs.v): the board as a
// class-compliant sound card, 48 kHz 16-bit stereo both ways. The device enumerates and streams
// without firmware; this page is status, the playback samples for the CPU, and three switches.
// status: final

`ifndef SDR_REGMAP_USB_VH
`define SDR_REGMAP_USB_VH

`define USB_BASE 32'hE80E0000
`define USB_SIZE 32'h00010000

// id -- Block identifier/version: 'US' + version 1.
`define USB_ID_ADDR 32'h00000000
`define USB_ID_ABS_ADDR (`USB_BASE + `USB_ID_ADDR)
`define USB_ID_RESET 32'h55530001

// ctrl -- Switches.
`define USB_CTRL_ADDR 32'h00000004
`define USB_CTRL_ABS_ADDR (`USB_BASE + `USB_CTRL_ADDR)
`define USB_CTRL_RESET 32'h00000001
`define USB_CTRL_CONNECT_LSB 0
`define USB_CTRL_CONNECT_MSB 0
`define USB_CTRL_CONNECT_WIDTH 1
`define USB_CTRL_FIFO_EN_LSB 1
`define USB_CTRL_FIFO_EN_MSB 1
`define USB_CTRL_FIFO_EN_WIDTH 1
`define USB_CTRL_MONITOR_LSB 2
`define USB_CTRL_MONITOR_MSB 2
`define USB_CTRL_MONITOR_WIDTH 1
`define USB_CTRL_LOOPBACK_LSB 3
`define USB_CTRL_LOOPBACK_MSB 3
`define USB_CTRL_LOOPBACK_WIDTH 1
`define USB_CTRL_SPEECH_SRC_LSB 4
`define USB_CTRL_SPEECH_SRC_MSB 4
`define USB_CTRL_SPEECH_SRC_WIDTH 1

// status -- State of the device. Bits from the USB clock are synchronised one by one.
`define USB_STATUS_ADDR 32'h00000008
`define USB_STATUS_ABS_ADDR (`USB_BASE + `USB_STATUS_ADDR)
`define USB_STATUS_RESET 32'h00000000
`define USB_STATUS_CONFIGURED_LSB 0
`define USB_STATUS_CONFIGURED_MSB 0
`define USB_STATUS_CONFIGURED_WIDTH 1
`define USB_STATUS_PLAY_ON_LSB 1
`define USB_STATUS_PLAY_ON_MSB 1
`define USB_STATUS_PLAY_ON_WIDTH 1
`define USB_STATUS_CAP_ON_LSB 2
`define USB_STATUS_CAP_ON_MSB 2
`define USB_STATUS_CAP_ON_WIDTH 1
`define USB_STATUS_PLAY_RUN_LSB 3
`define USB_STATUS_PLAY_RUN_MSB 3
`define USB_STATUS_PLAY_RUN_WIDTH 1
`define USB_STATUS_PLAY_FILL_LSB 16
`define USB_STATUS_PLAY_FILL_MSB 24
`define USB_STATUS_PLAY_FILL_WIDTH 9

// fifo_level -- Stereo samples waiting in the CPU FIFO, 0 to 1,024.
`define USB_FIFO_LEVEL_ADDR 32'h0000000C
`define USB_FIFO_LEVEL_ABS_ADDR (`USB_BASE + `USB_FIFO_LEVEL_ADDR)
`define USB_FIFO_LEVEL_RESET 32'h00000000

// fifo_data -- The oldest sample of the CPU FIFO: left in bits 15:0, right in bits 31:16, signed. Reading takes it out. 0 when the FIFO is empty.
`define USB_FIFO_DATA_ADDR 32'h00000010
`define USB_FIFO_DATA_ABS_ADDR (`USB_BASE + `USB_FIFO_DATA_ADDR)
`define USB_FIFO_DATA_RESET 32'h00000000

// fifo_mark -- High-water mark, 1 to 1,024: interrupt line 12 is high while fifo_level is at or above it (and ctrl.fifo_en is 1). 512 = 10.7 ms.
`define USB_FIFO_MARK_ADDR 32'h00000014
`define USB_FIFO_MARK_ABS_ADDR (`USB_BASE + `USB_FIFO_MARK_ADDR)
`define USB_FIFO_MARK_RESET 32'h00000200

// play_errors -- Playback faults. Counters wrap at 65,535. Expected: both stay still while a PC plays.
`define USB_PLAY_ERRORS_ADDR 32'h00000018
`define USB_PLAY_ERRORS_ABS_ADDR (`USB_BASE + `USB_PLAY_ERRORS_ADDR)
`define USB_PLAY_ERRORS_RESET 32'h00000000
`define USB_PLAY_ERRORS_UNDERRUNS_LSB 0
`define USB_PLAY_ERRORS_UNDERRUNS_MSB 15
`define USB_PLAY_ERRORS_UNDERRUNS_WIDTH 16
`define USB_PLAY_ERRORS_OVERRUNS_LSB 16
`define USB_PLAY_ERRORS_OVERRUNS_MSB 31
`define USB_PLAY_ERRORS_OVERRUNS_WIDTH 16

// more_errors -- Further faults. Counters wrap at 65,535.
`define USB_MORE_ERRORS_ADDR 32'h0000001C
`define USB_MORE_ERRORS_ABS_ADDR (`USB_BASE + `USB_MORE_ERRORS_ADDR)
`define USB_MORE_ERRORS_RESET 32'h00000000
`define USB_MORE_ERRORS_CAP_OVERRUNS_LSB 0
`define USB_MORE_ERRORS_CAP_OVERRUNS_MSB 15
`define USB_MORE_ERRORS_CAP_OVERRUNS_WIDTH 16
`define USB_MORE_ERRORS_FIFO_OVERRUNS_LSB 16
`define USB_MORE_ERRORS_FIFO_OVERRUNS_MSB 31
`define USB_MORE_ERRORS_FIFO_OVERRUNS_WIDTH 16

// play_bad -- Playback packets dropped for a checksum error (16 bits, wraps). A bad cable shows here.
`define USB_PLAY_BAD_ADDR 32'h00000020
`define USB_PLAY_BAD_ABS_ADDR (`USB_BASE + `USB_PLAY_BAD_ADDR)
`define USB_PLAY_BAD_RESET 32'h00000000

// levels -- Peak meters: the largest magnitude of either channel since the last read of this register. Reading clears both.
`define USB_LEVELS_ADDR 32'h00000024
`define USB_LEVELS_ABS_ADDR (`USB_BASE + `USB_LEVELS_ADDR)
`define USB_LEVELS_RESET 32'h00000000
`define USB_LEVELS_PLAY_PEAK_LSB 0
`define USB_LEVELS_PLAY_PEAK_MSB 14
`define USB_LEVELS_PLAY_PEAK_WIDTH 15
`define USB_LEVELS_CAP_PEAK_LSB 16
`define USB_LEVELS_CAP_PEAK_MSB 30
`define USB_LEVELS_CAP_PEAK_WIDTH 15

`endif // SDR_REGMAP_USB_VH
