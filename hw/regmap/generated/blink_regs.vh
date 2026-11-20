// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

// GENERATED FILE -- do not edit by hand. Produced by `cargo run -p xtask -- regmap`
// from hw/regmap/blink.toml. See docs/REGMAP.md.
//
// Board link on SFP1 (docs/SFP_LINKS.md section 5): the HL2 sample stream to a second board, control
// words for the two CPUs, status and counters, and the switch that feeds the receivers of this board
// from the link. rtl/blink/blink_top.v. All in clk_dsp.
// status: draft

`ifndef SDR_REGMAP_BLINK_VH
`define SDR_REGMAP_BLINK_VH

`define BLINK_BASE 32'hE80B0000
`define BLINK_SIZE 32'h00010000

// id -- Block identifier: BL + version 1.
`define BLINK_ID_ADDR 32'h00000000
`define BLINK_ID_ABS_ADDR (`BLINK_BASE + `BLINK_ID_ADDR)
`define BLINK_ID_RESET 32'h424C0001

// ctrl -- Board link settings.
`define BLINK_CTRL_ADDR 32'h00000004
`define BLINK_CTRL_ABS_ADDR (`BLINK_BASE + `BLINK_CTRL_ADDR)
`define BLINK_CTRL_RESET 32'h00000000
`define BLINK_CTRL_ENABLE_LSB 0
`define BLINK_CTRL_ENABLE_MSB 0
`define BLINK_CTRL_ENABLE_WIDTH 1
`define BLINK_CTRL_SEND_SAMPLES_LSB 1
`define BLINK_CTRL_SEND_SAMPLES_MSB 1
`define BLINK_CTRL_SEND_SAMPLES_WIDTH 1
`define BLINK_CTRL_RX_FROM_LINK_LSB 2
`define BLINK_CTRL_RX_FROM_LINK_MSB 2
`define BLINK_CTRL_RX_FROM_LINK_WIDTH 1

// status -- Board link state.
`define BLINK_STATUS_ADDR 32'h00000008
`define BLINK_STATUS_ABS_ADDR (`BLINK_BASE + `BLINK_STATUS_ADDR)
`define BLINK_STATUS_RESET 32'h00000000
`define BLINK_STATUS_ALIGNED_LSB 0
`define BLINK_STATUS_ALIGNED_MSB 0
`define BLINK_STATUS_ALIGNED_WIDTH 1
`define BLINK_STATUS_LINK_UP_LSB 1
`define BLINK_STATUS_LINK_UP_MSB 1
`define BLINK_STATUS_LINK_UP_WIDTH 1
`define BLINK_STATUS_REMOTE_LINK_UP_LSB 2
`define BLINK_STATUS_REMOTE_LINK_UP_MSB 2
`define BLINK_STATUS_REMOTE_LINK_UP_WIDTH 1
`define BLINK_STATUS_REMOTE_SENDING_LSB 3
`define BLINK_STATUS_REMOTE_SENDING_MSB 3
`define BLINK_STATUS_REMOTE_SENDING_WIDTH 1
`define BLINK_STATUS_REMOTE_CTL_FULL_LSB 4
`define BLINK_STATUS_REMOTE_CTL_FULL_MSB 4
`define BLINK_STATUS_REMOTE_CTL_FULL_WIDTH 1
`define BLINK_STATUS_CTL_TX_FULL_LSB 5
`define BLINK_STATUS_CTL_TX_FULL_MSB 5
`define BLINK_STATUS_CTL_TX_FULL_WIDTH 1
`define BLINK_STATUS_CTL_RX_AVAIL_LSB 6
`define BLINK_STATUS_CTL_RX_AVAIL_MSB 6
`define BLINK_STATUS_CTL_RX_AVAIL_WIDTH 1

// ctl_tx -- Write: queue a 32-bit control word for the CPU of the other board. Reads 0.
`define BLINK_CTL_TX_ADDR 32'h00000010
`define BLINK_CTL_TX_ABS_ADDR (`BLINK_BASE + `BLINK_CTL_TX_ADDR)
`define BLINK_CTL_TX_RESET 32'h00000000

// ctl_rx -- The waiting control word; reading it takes it (status.ctl_rx_avail falls until the next one is ready).
`define BLINK_CTL_RX_ADDR 32'h00000014
`define BLINK_CTL_RX_ABS_ADDR (`BLINK_BASE + `BLINK_CTL_RX_ADDR)
`define BLINK_CTL_RX_RESET 32'h00000000

// rx_frames -- Good sample frames received (16 bits, wraps).
`define BLINK_RX_FRAMES_ADDR 32'h00000020
`define BLINK_RX_FRAMES_ABS_ADDR (`BLINK_BASE + `BLINK_RX_FRAMES_ADDR)
`define BLINK_RX_FRAMES_RESET 32'h00000000

// rx_bad -- Bad frames of any kind: code error, length, CRC (16 bits).
`define BLINK_RX_BAD_ADDR 32'h00000024
`define BLINK_RX_BAD_ABS_ADDR (`BLINK_BASE + `BLINK_RX_BAD_ADDR)
`define BLINK_RX_BAD_RESET 32'h00000000

// rx_seq_jumps -- Sample frames whose counter did not follow the one before (16 bits).
`define BLINK_RX_SEQ_JUMPS_ADDR 32'h00000028
`define BLINK_RX_SEQ_JUMPS_ABS_ADDR (`BLINK_BASE + `BLINK_RX_SEQ_JUMPS_ADDR)
`define BLINK_RX_SEQ_JUMPS_RESET 32'h00000000

// align_losses -- Times the aligner of lane 1 lost its lock (16 bits).
`define BLINK_ALIGN_LOSSES_ADDR 32'h0000002C
`define BLINK_ALIGN_LOSSES_ABS_ADDR (`BLINK_BASE + `BLINK_ALIGN_LOSSES_ADDR)
`define BLINK_ALIGN_LOSSES_RESET 32'h00000000

// link_ups -- Times the link came up (16 bits).
`define BLINK_LINK_UPS_ADDR 32'h00000030
`define BLINK_LINK_UPS_ABS_ADDR (`BLINK_BASE + `BLINK_LINK_UPS_ADDR)
`define BLINK_LINK_UPS_RESET 32'h00000000

// tx_samples -- Samples queued for the link (32 bits).
`define BLINK_TX_SAMPLES_ADDR 32'h00000034
`define BLINK_TX_SAMPLES_ABS_ADDR (`BLINK_BASE + `BLINK_TX_SAMPLES_ADDR)
`define BLINK_TX_SAMPLES_RESET 32'h00000000

// rx_samples -- Real (not fill) samples delivered from the link (32 bits).
`define BLINK_RX_SAMPLES_ADDR 32'h00000038
`define BLINK_RX_SAMPLES_ABS_ADDR (`BLINK_BASE + `BLINK_RX_SAMPLES_ADDR)
`define BLINK_RX_SAMPLES_RESET 32'h00000000

// tx_counts -- Bits 15:0 sample frames sent, 31:16 control words sent.
`define BLINK_TX_COUNTS_ADDR 32'h0000003C
`define BLINK_TX_COUNTS_ABS_ADDR (`BLINK_BASE + `BLINK_TX_COUNTS_ADDR)
`define BLINK_TX_COUNTS_RESET 32'h00000000

// ctl_counts -- Bits 15:0 control words received, 31:16 control words missing by their sequence numbers.
`define BLINK_CTL_COUNTS_ADDR 32'h00000040
`define BLINK_CTL_COUNTS_ABS_ADDR (`BLINK_BASE + `BLINK_CTL_COUNTS_ADDR)
`define BLINK_CTL_COUNTS_RESET 32'h00000000

// ctl_dropped -- Received control words dropped because ctl_rx was not read (16 bits).
`define BLINK_CTL_DROPPED_ADDR 32'h00000044
`define BLINK_CTL_DROPPED_ABS_ADDR (`BLINK_BASE + `BLINK_CTL_DROPPED_ADDR)
`define BLINK_CTL_DROPPED_RESET 32'h00000000

// remote_bad -- The rx_bad count of the other board, from its status word.
`define BLINK_REMOTE_BAD_ADDR 32'h00000048
`define BLINK_REMOTE_BAD_ABS_ADDR (`BLINK_BASE + `BLINK_REMOTE_BAD_ADDR)
`define BLINK_REMOTE_BAD_RESET 32'h00000000

// gap_events -- Gaps zero-filled in the stream of the link (source gaps and lost frames).
`define BLINK_GAP_EVENTS_ADDR 32'h0000004C
`define BLINK_GAP_EVENTS_ABS_ADDR (`BLINK_BASE + `BLINK_GAP_EVENTS_ADDR)
`define BLINK_GAP_EVENTS_RESET 32'h00000000

// gap_samples -- Samples zero-filled.
`define BLINK_GAP_SAMPLES_ADDR 32'h00000050
`define BLINK_GAP_SAMPLES_ABS_ADDR (`BLINK_BASE + `BLINK_GAP_SAMPLES_ADDR)
`define BLINK_GAP_SAMPLES_RESET 32'h00000000

// resyncs -- Index jumps too large to fill (over 65,536 samples).
`define BLINK_RESYNCS_ADDR 32'h00000054
`define BLINK_RESYNCS_ABS_ADDR (`BLINK_BASE + `BLINK_RESYNCS_ADDR)
`define BLINK_RESYNCS_RESET 32'h00000000

// tx_overflows -- Times the send FIFO was full and samples were left out (the receiver fills them).
`define BLINK_TX_OVERFLOWS_ADDR 32'h00000058
`define BLINK_TX_OVERFLOWS_ABS_ADDR (`BLINK_BASE + `BLINK_TX_OVERFLOWS_ADDR)
`define BLINK_TX_OVERFLOWS_RESET 32'h00000000

// rx_overruns -- Frames dropped at the receiver for lack of room (16 bits).
`define BLINK_RX_OVERRUNS_ADDR 32'h0000005C
`define BLINK_RX_OVERRUNS_ABS_ADDR (`BLINK_BASE + `BLINK_RX_OVERRUNS_ADDR)
`define BLINK_RX_OVERRUNS_RESET 32'h00000000

// sample_index_lo -- Index of the next sample of the stream of the link, bits 31:0. Reading it latches the upper 16 bits.
`define BLINK_SAMPLE_INDEX_LO_ADDR 32'h00000060
`define BLINK_SAMPLE_INDEX_LO_ABS_ADDR (`BLINK_BASE + `BLINK_SAMPLE_INDEX_LO_ADDR)
`define BLINK_SAMPLE_INDEX_LO_RESET 32'h00000000

// sample_index_hi -- Bits 47:32, latched by the read of sample_index_lo.
`define BLINK_SAMPLE_INDEX_HI_ADDR 32'h00000064
`define BLINK_SAMPLE_INDEX_HI_ABS_ADDR (`BLINK_BASE + `BLINK_SAMPLE_INDEX_HI_ADDR)
`define BLINK_SAMPLE_INDEX_HI_RESET 32'h00000000

`endif // SDR_REGMAP_BLINK_VH
