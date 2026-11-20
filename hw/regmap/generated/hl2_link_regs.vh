// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

// GENERATED FILE -- do not edit by hand. Produced by `cargo run -p xtask -- regmap`
// from hw/regmap/hl2_link.toml. See docs/REGMAP.md.
//
// HL2 link control (docs/ARCHITECTURE.md 3.1): our/HL2 addressing, the raw-frame header mirror,
// the safety byte and its change interrupt, receive counters, and TX framer enable/trim. Packet
// memory for the CPU receive ring and transmit queue is the separate block at 0xE802_0000.
// status: draft

`ifndef SDR_REGMAP_HL2_LINK_VH
`define SDR_REGMAP_HL2_LINK_VH

`define HL2_LINK_BASE 32'hE8010000
`define HL2_LINK_SIZE 32'h00010000

// id -- Block identifier/version: 'HL' + version 1 (set by the chip top level, rtl/top/hl2_link_regs.v).
`define HL2_LINK_ID_ADDR 32'h00000000
`define HL2_LINK_ID_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_ID_ADDR)
`define HL2_LINK_ID_RESET 32'h484C0001

// ctrl -- Link enable and addressing mode.
`define HL2_LINK_CTRL_ADDR 32'h00000004
`define HL2_LINK_CTRL_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_CTRL_ADDR)
`define HL2_LINK_CTRL_RESET 32'h00000002
`define HL2_LINK_CTRL_RX_ENABLE_LSB 0
`define HL2_LINK_CTRL_RX_ENABLE_MSB 0
`define HL2_LINK_CTRL_RX_ENABLE_WIDTH 1
`define HL2_LINK_CTRL_DHCP_ENABLE_LSB 1
`define HL2_LINK_CTRL_DHCP_ENABLE_MSB 1
`define HL2_LINK_CTRL_DHCP_ENABLE_WIDTH 1

// our_mac_hi -- Our MAC address, upper 16 bits (in bits [15:0]); used to build TX frame headers in logic.
`define HL2_LINK_OUR_MAC_HI_ADDR 32'h00000008
`define HL2_LINK_OUR_MAC_HI_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_OUR_MAC_HI_ADDR)
`define HL2_LINK_OUR_MAC_HI_RESET 32'h00000000

// our_mac_lo -- Our MAC address, lower 32 bits.
`define HL2_LINK_OUR_MAC_LO_ADDR 32'h0000000C
`define HL2_LINK_OUR_MAC_LO_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_OUR_MAC_LO_ADDR)
`define HL2_LINK_OUR_MAC_LO_RESET 32'h00000000

// our_ip -- Our IPv4 address on the HL2 link. Reset value is 10.99.0.1 (ARCHITECTURE 3.1's default Tang address).
`define HL2_LINK_OUR_IP_ADDR 32'h00000010
`define HL2_LINK_OUR_IP_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_OUR_IP_ADDR)
`define HL2_LINK_OUR_IP_RESET 32'h0A630001

// hl2_mac_hi -- HL2's MAC address, upper 16 bits (in bits [15:0]). Firmware writes it from the discovery reply (read-write: nothing in logic learns it); the TX framer addresses raw TX frames to it.
`define HL2_LINK_HL2_MAC_HI_ADDR 32'h00000014
`define HL2_LINK_HL2_MAC_HI_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_HL2_MAC_HI_ADDR)
`define HL2_LINK_HL2_MAC_HI_RESET 32'h00000000

// hl2_mac_lo -- HL2's MAC address, lower 32 bits, learned from its discovery reply.
`define HL2_LINK_HL2_MAC_LO_ADDR 32'h00000018
`define HL2_LINK_HL2_MAC_LO_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_HL2_MAC_LO_ADDR)
`define HL2_LINK_HL2_MAC_LO_RESET 32'h00000000

// hl2_ip -- HL2's IPv4 address, either assigned by our DHCP server (10.99.0.2 by default) or learned from discovery.
`define HL2_LINK_HL2_IP_ADDR 32'h0000001C
`define HL2_LINK_HL2_IP_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_HL2_IP_ADDR)
`define HL2_LINK_HL2_IP_RESET 32'h00000000

// status -- Link and discovery status, read-only except the change flag.
`define HL2_LINK_STATUS_ADDR 32'h00000020
`define HL2_LINK_STATUS_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_STATUS_ADDR)
`define HL2_LINK_STATUS_RESET 32'h00000000
`define HL2_LINK_STATUS_DISCOVERED_LSB 0
`define HL2_LINK_STATUS_DISCOVERED_MSB 0
`define HL2_LINK_STATUS_DISCOVERED_WIDTH 1
`define HL2_LINK_STATUS_STREAMING_LSB 1
`define HL2_LINK_STATUS_STREAMING_MSB 1
`define HL2_LINK_STATUS_STREAMING_WIDTH 1

// safety_byte -- Mirror of the safety byte from the most recent raw-frame header (PROTOCOL 5.4), and its change flag.
`define HL2_LINK_SAFETY_BYTE_ADDR 32'h00000024
`define HL2_LINK_SAFETY_BYTE_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_SAFETY_BYTE_ADDR)
`define HL2_LINK_SAFETY_BYTE_RESET 32'h00000000
`define HL2_LINK_SAFETY_BYTE_VALUE_LSB 0
`define HL2_LINK_SAFETY_BYTE_VALUE_MSB 7
`define HL2_LINK_SAFETY_BYTE_VALUE_WIDTH 8
`define HL2_LINK_SAFETY_BYTE_CHANGED_LSB 8
`define HL2_LINK_SAFETY_BYTE_CHANGED_MSB 8
`define HL2_LINK_SAFETY_BYTE_CHANGED_WIDTH 1

// rx_seq -- Sequence number of the most recent committed raw frame (since 2026-10-21; it read 0 before).
`define HL2_LINK_RX_SEQ_ADDR 32'h00000028
`define HL2_LINK_RX_SEQ_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_RX_SEQ_ADDR)
`define HL2_LINK_RX_SEQ_RESET 32'h00000000

// rx_first_sample_hi -- First-sample index of the most recent raw frame, upper 16 bits of the 48-bit index (bits [15:0]).
`define HL2_LINK_RX_FIRST_SAMPLE_HI_ADDR 32'h0000002C
`define HL2_LINK_RX_FIRST_SAMPLE_HI_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_RX_FIRST_SAMPLE_HI_ADDR)
`define HL2_LINK_RX_FIRST_SAMPLE_HI_RESET 32'h00000000

// rx_first_sample_lo -- First-sample index of the most recent raw frame, lower 32 bits of the 48-bit index.
`define HL2_LINK_RX_FIRST_SAMPLE_LO_ADDR 32'h00000030
`define HL2_LINK_RX_FIRST_SAMPLE_LO_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_RX_FIRST_SAMPLE_LO_ADDR)
`define HL2_LINK_RX_FIRST_SAMPLE_LO_RESET 32'h00000000

// gap_count -- Running count of gap-fill events (lost or CRC-failed frames, ARCHITECTURE 3.1 item 4). Free-running; firmware differences successive reads.
`define HL2_LINK_GAP_COUNT_ADDR 32'h00000034
`define HL2_LINK_GAP_COUNT_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_GAP_COUNT_ADDR)
`define HL2_LINK_GAP_COUNT_RESET 32'h00000000

// crc_error_count -- Running count of frames dropped for a bad CRC-32. Free-running.
`define HL2_LINK_CRC_ERROR_COUNT_ADDR 32'h00000038
`define HL2_LINK_CRC_ERROR_COUNT_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_CRC_ERROR_COUNT_ADDR)
`define HL2_LINK_CRC_ERROR_COUNT_RESET 32'h00000000

// tx_ctrl -- TX sample framer enable.
`define HL2_LINK_TX_CTRL_ADDR 32'h0000003C
`define HL2_LINK_TX_CTRL_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_TX_CTRL_ADDR)
`define HL2_LINK_TX_CTRL_RESET 32'h00000000
`define HL2_LINK_TX_CTRL_ENABLE_LSB 0
`define HL2_LINK_TX_CTRL_ENABLE_MSB 0
`define HL2_LINK_TX_CTRL_ENABLE_WIDTH 1

// tx_fifo_fill -- HL2 TX FIFO fill estimate reported back in the v3 header (PROTOCOL 6.3), for the trim loop (ARCHITECTURE 3.6 item 3, target 12,000 of 16,384).
`define HL2_LINK_TX_FIFO_FILL_ADDR 32'h00000040
`define HL2_LINK_TX_FIFO_FILL_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_TX_FIFO_FILL_ADDR)
`define HL2_LINK_TX_FIFO_FILL_RESET 32'h00000000

// tx_trim -- Signed count of samples the trim loop has added (+) or dropped (-) since the last read, to hold tx_fifo_fill near its target.
`define HL2_LINK_TX_TRIM_ADDR 32'h00000044
`define HL2_LINK_TX_TRIM_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_TX_TRIM_ADDR)
`define HL2_LINK_TX_TRIM_RESET 32'h00000000

// raw_frame_count -- Running count of CRC-good raw sample frames (counter cnt_raw_frames). Free-running.
`define HL2_LINK_RAW_FRAME_COUNT_ADDR 32'h00000048
`define HL2_LINK_RAW_FRAME_COUNT_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_RAW_FRAME_COUNT_ADDR)
`define HL2_LINK_RAW_FRAME_COUNT_RESET 32'h00000000

// other_frame_count -- Running count of CRC-good frames routed to the CPU receive ring (counter cnt_other_frames). Free-running.
`define HL2_LINK_OTHER_FRAME_COUNT_ADDR 32'h0000004C
`define HL2_LINK_OTHER_FRAME_COUNT_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_OTHER_FRAME_COUNT_ADDR)
`define HL2_LINK_OTHER_FRAME_COUNT_RESET 32'h00000000

// ring_frames -- CPU receive ring frame counters (counters cnt_ring_frames and cnt_ring_dropped), free-running.
`define HL2_LINK_RING_FRAMES_ADDR 32'h00000050
`define HL2_LINK_RING_FRAMES_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_RING_FRAMES_ADDR)
`define HL2_LINK_RING_FRAMES_RESET 32'h00000000
`define HL2_LINK_RING_FRAMES_COMMITTED_LSB 0
`define HL2_LINK_RING_FRAMES_COMMITTED_MSB 15
`define HL2_LINK_RING_FRAMES_COMMITTED_WIDTH 16
`define HL2_LINK_RING_FRAMES_DROPPED_LSB 16
`define HL2_LINK_RING_FRAMES_DROPPED_MSB 31
`define HL2_LINK_RING_FRAMES_DROPPED_WIDTH 16

// gap_sample_count -- Running count of zero samples the gap filler inserted. Free-running.
`define HL2_LINK_GAP_SAMPLE_COUNT_ADDR 32'h00000054
`define HL2_LINK_GAP_SAMPLE_COUNT_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_GAP_SAMPLE_COUNT_ADDR)
`define HL2_LINK_GAP_SAMPLE_COUNT_RESET 32'h00000000

// resync_count -- Running count of index jumps too large to fill (resyncs). Free-running.
`define HL2_LINK_RESYNC_COUNT_ADDR 32'h00000058
`define HL2_LINK_RESYNC_COUNT_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_RESYNC_COUNT_ADDR)
`define HL2_LINK_RESYNC_COUNT_RESET 32'h00000000

// ring_wptr -- CPU receive ring write pointer, byte offset into the 4 KB ring at 0xE802_0000 (ring_wr_ptr). Each frame is a 2-byte big-endian length followed by the frame bytes.
`define HL2_LINK_RING_WPTR_ADDR 32'h0000005C
`define HL2_LINK_RING_WPTR_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_RING_WPTR_ADDR)
`define HL2_LINK_RING_WPTR_RESET 32'h00000000

// sample_index_lo -- HL2 sample index of the next expected ADC sample (gap filler), low 32 bits. Read lo first: that latches hi.
`define HL2_LINK_SAMPLE_INDEX_LO_ADDR 32'h00000060
`define HL2_LINK_SAMPLE_INDEX_LO_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_SAMPLE_INDEX_LO_ADDR)
`define HL2_LINK_SAMPLE_INDEX_LO_RESET 32'h00000000

// sample_index_hi -- HL2 sample index, high 16 bits in [15:0], as latched by the last sample_index_lo read.
`define HL2_LINK_SAMPLE_INDEX_HI_ADDR 32'h00000064
`define HL2_LINK_SAMPLE_INDEX_HI_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_SAMPLE_INDEX_HI_ADDR)
`define HL2_LINK_SAMPLE_INDEX_HI_RESET 32'h00000000

// our_port -- Our UDP source port for raw TX frames to the HL2 (tx_sample_framer cfg_my_port).
`define HL2_LINK_OUR_PORT_ADDR 32'h00000068
`define HL2_LINK_OUR_PORT_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_OUR_PORT_ADDR)
`define HL2_LINK_OUR_PORT_RESET 32'h0000C738

// tx_counts -- Rate lock: samples inserted and skipped to hold the HL2 TX FIFO fill (free-running, low 16 bits each).
`define HL2_LINK_TX_COUNTS_ADDR 32'h0000006C
`define HL2_LINK_TX_COUNTS_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_TX_COUNTS_ADDR)
`define HL2_LINK_TX_COUNTS_RESET 32'h00000000
`define HL2_LINK_TX_COUNTS_INSERTED_LSB 0
`define HL2_LINK_TX_COUNTS_INSERTED_MSB 15
`define HL2_LINK_TX_COUNTS_INSERTED_WIDTH 16
`define HL2_LINK_TX_COUNTS_SKIPPED_LSB 16
`define HL2_LINK_TX_COUNTS_SKIPPED_MSB 31
`define HL2_LINK_TX_COUNTS_SKIPPED_WIDTH 16

// seq_lost -- Raw frames missing by the HL2's frame sequence number (every frame lost before the commit: line, module, FCS, code error, length). Owner requirement: 0.
`define HL2_LINK_SEQ_LOST_ADDR 32'h00000070
`define HL2_LINK_SEQ_LOST_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_SEQ_LOST_ADDR)
`define HL2_LINK_SEQ_LOST_RESET 32'h00000000

// loss_a -- Sequence restarts and frames with a code error.
`define HL2_LINK_LOSS_A_ADDR 32'h00000074
`define HL2_LINK_LOSS_A_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_LOSS_A_ADDR)
`define HL2_LINK_LOSS_A_RESET 32'h00000000
`define HL2_LINK_LOSS_A_SEQ_RESTARTS_LSB 0
`define HL2_LINK_LOSS_A_SEQ_RESTARTS_MSB 15
`define HL2_LINK_LOSS_A_SEQ_RESTARTS_WIDTH 16
`define HL2_LINK_LOSS_A_CODE_FRAMES_LSB 16
`define HL2_LINK_LOSS_A_CODE_FRAMES_MSB 31
`define HL2_LINK_LOSS_A_CODE_FRAMES_WIDTH 16

// loss_b -- Length errors and the HL2's own sample loss.
`define HL2_LINK_LOSS_B_ADDR 32'h00000078
`define HL2_LINK_LOSS_B_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_LOSS_B_ADDR)
`define HL2_LINK_LOSS_B_RESET 32'h00000000
`define HL2_LINK_LOSS_B_LEN_ERRORS_LSB 0
`define HL2_LINK_LOSS_B_LEN_ERRORS_MSB 15
`define HL2_LINK_LOSS_B_LEN_ERRORS_WIDTH 16
`define HL2_LINK_LOSS_B_HL2_MISSING_LSB 16
`define HL2_LINK_LOSS_B_HL2_MISSING_MSB 31
`define HL2_LINK_LOSS_B_HL2_MISSING_WIDTH 16

// loss_c -- Loss behind the commit (receive chain).
`define HL2_LINK_LOSS_C_ADDR 32'h0000007C
`define HL2_LINK_LOSS_C_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_LOSS_C_ADDR)
`define HL2_LINK_LOSS_C_RESET 32'h00000000
`define HL2_LINK_LOSS_C_DRAIN_DROPS_LSB 0
`define HL2_LINK_LOSS_C_DRAIN_DROPS_MSB 15
`define HL2_LINK_LOSS_C_DRAIN_DROPS_WIDTH 16
`define HL2_LINK_LOSS_C_OVERRUNS_LSB 16
`define HL2_LINK_LOSS_C_OVERRUNS_MSB 31
`define HL2_LINK_LOSS_C_OVERRUNS_WIDTH 16

// loss_d -- Index FIFO and the HL2's overflow count.
`define HL2_LINK_LOSS_D_ADDR 32'h00000080
`define HL2_LINK_LOSS_D_ABS_ADDR (`HL2_LINK_BASE + `HL2_LINK_LOSS_D_ADDR)
`define HL2_LINK_LOSS_D_RESET 32'h00000000
`define HL2_LINK_LOSS_D_IDX_DROPS_LSB 0
`define HL2_LINK_LOSS_D_IDX_DROPS_MSB 15
`define HL2_LINK_LOSS_D_IDX_DROPS_WIDTH 16
`define HL2_LINK_LOSS_D_HL2_OVF_LSB 16
`define HL2_LINK_LOSS_D_HL2_OVF_MSB 31
`define HL2_LINK_LOSS_D_HL2_OVF_WIDTH 16

`endif // SDR_REGMAP_HL2_LINK_VH
