// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

// GENERATED FILE -- do not edit by hand. Produced by `cargo run -p xtask -- regmap`
// from hw/regmap/hl2_pkt.toml. See docs/REGMAP.md.
//
// HL2 link packet memory (docs/ARCHITECTURE.md 3.1, 4.1): the 4 KB CPU receive ring of the receive block
// (rtl/hl2link/cpu_rx_ring.v), read-only, one 32-bit word per 4 bytes of ring, byte k of the ring in
// bits [8(k%4)+7 : 8(k%4)] (little-endian, so a word copy keeps the stream order). The write pointer
// is hl2_link.ring_wptr. Reads cross into the RGMII receive clock domain: about 20 AHB clocks each.
// The upper half is H2's CPU transmit queue (rtl/hl2link/cpu_tx_queue.v, 4 KB, one frame in flight),
// in the 125 MHz transmit clock domain: write the frame (destination MAC to last payload byte, no FCS)
// as little-endian words at tx_queue, then its length in bytes to tx_send; tx_status.busy stays high
// until the frame has gone out.
// status: draft

`ifndef SDR_REGMAP_HL2_PKT_VH
`define SDR_REGMAP_HL2_PKT_VH

`define HL2_PKT_BASE 32'hE8020000
`define HL2_PKT_SIZE 32'h00010000

// rx_ring -- CPU receive ring, 4 bytes per word.
`define HL2_PKT_RX_RING_OFFSET 32'h00000000
`define HL2_PKT_RX_RING_STRIDE 32'h00000004
`define HL2_PKT_RX_RING_COUNT 1024
`define HL2_PKT_RX_RING_ADDR(i) (`HL2_PKT_RX_RING_OFFSET + (i)*`HL2_PKT_RX_RING_STRIDE)
`define HL2_PKT_RX_RING_ABS_ADDR(i) (`HL2_PKT_BASE + `HL2_PKT_RX_RING_ADDR(i))
`define HL2_PKT_RX_RING_RESET 32'h00000000

// tx_queue -- CPU transmit queue, write-only in effect (reads return 0): byte 4i+k of the frame in bits [8k+7:8k].
`define HL2_PKT_TX_QUEUE_OFFSET 32'h00008000
`define HL2_PKT_TX_QUEUE_STRIDE 32'h00000004
`define HL2_PKT_TX_QUEUE_COUNT 1024
`define HL2_PKT_TX_QUEUE_ADDR(i) (`HL2_PKT_TX_QUEUE_OFFSET + (i)*`HL2_PKT_TX_QUEUE_STRIDE)
`define HL2_PKT_TX_QUEUE_ABS_ADDR(i) (`HL2_PKT_BASE + `HL2_PKT_TX_QUEUE_ADDR(i))
`define HL2_PKT_TX_QUEUE_RESET 32'h00000000

// tx_send -- Write the frame length to queue the frame written at tx_queue for sending.
`define HL2_PKT_TX_SEND_ADDR 32'h0000C000
`define HL2_PKT_TX_SEND_ABS_ADDR (`HL2_PKT_BASE + `HL2_PKT_TX_SEND_ADDR)
`define HL2_PKT_TX_SEND_RESET 32'h00000000
`define HL2_PKT_TX_SEND_LENGTH_LSB 0
`define HL2_PKT_TX_SEND_LENGTH_MSB 15
`define HL2_PKT_TX_SEND_LENGTH_WIDTH 16

// tx_status -- CPU transmit queue status.
`define HL2_PKT_TX_STATUS_ADDR 32'h0000C004
`define HL2_PKT_TX_STATUS_ABS_ADDR (`HL2_PKT_BASE + `HL2_PKT_TX_STATUS_ADDR)
`define HL2_PKT_TX_STATUS_RESET 32'h00000000
`define HL2_PKT_TX_STATUS_BUSY_LSB 0
`define HL2_PKT_TX_STATUS_BUSY_MSB 0
`define HL2_PKT_TX_STATUS_BUSY_WIDTH 1

`endif // SDR_REGMAP_HL2_PKT_VH
