// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com

// GENERATED FILE -- do not edit by hand. Produced by `cargo run -p xtask -- regmap`
// from hw/regmap/net.toml. See docs/REGMAP.md.
//
// Network unit on the RJ45 socket (RTL8211F, RGMII at 100 Mbit/s full duplex): the eth_top register page,
// in the 100 MHz network clock (about 20 AHB clocks per access). One frame out (2 KB), a 4 KB ring of frames in, MDIO.
// Chip ID (Gowin OTP DNA, 64 bits) at 0x80 to 0x9C. The layout is fixed and changes only with an entry in docs/DECISIONS.md.
// status: final

`ifndef SDR_REGMAP_NET_VH
`define SDR_REGMAP_NET_VH

`define NET_BASE 32'hE9240000
`define NET_SIZE 32'h00010000

// id -- Identifier 'ET' + version 1 (eth_top).
`define NET_ID_ADDR 32'h00000000
`define NET_ID_ABS_ADDR (`NET_BASE + `NET_ID_ADDR)
`define NET_ID_RESET 32'h45540001

// ctrl -- Bit 0 receiver on, 1 transmitter on, 2 PHY reset pin low, 3 every frame, 4 broadcast, 5 multicast.
`define NET_CTRL_ADDR 32'h00000004
`define NET_CTRL_ABS_ADDR (`NET_BASE + `NET_CTRL_ADDR)
`define NET_CTRL_RESET 32'h00000014

// status -- Bit 0 a frame waits, 1 transmitter busy, 2 the PHY's receive clock runs, 3 PHY link, 5:4 speed (0 10, 1 100, 2 1000), 6 full duplex (the PHY's in-band report).
`define NET_STATUS_ADDR 32'h00000008
`define NET_STATUS_ABS_ADDR (`NET_BASE + `NET_STATUS_ADDR)
`define NET_STATUS_RESET 32'h00000000

// flags -- Bit 0 frame waiting, 1 frame sent, 2 frame dropped, 3 MDIO done; write 1 to bits 1 to 3 to clear them.
`define NET_FLAGS_ADDR 32'h0000000C
`define NET_FLAGS_ABS_ADDR (`NET_BASE + `NET_FLAGS_ADDR)
`define NET_FLAGS_RESET 32'h00000000

// irq_enable -- Interrupt enable per flag bit.
`define NET_IRQ_ENABLE_ADDR 32'h00000010
`define NET_IRQ_ENABLE_ABS_ADDR (`NET_BASE + `NET_IRQ_ENABLE_ADDR)
`define NET_IRQ_ENABLE_RESET 32'h00000000

// mac_lo -- Our MAC address bytes 0 to 3 (byte 0 first on the wire, in bits 7:0).
`define NET_MAC_LO_ADDR 32'h00000014
`define NET_MAC_LO_ABS_ADDR (`NET_BASE + `NET_MAC_LO_ADDR)
`define NET_MAC_LO_RESET 32'h004A5402

// mac_hi -- Our MAC address bytes 4 and 5 in bits 15:0.
`define NET_MAC_HI_ADDR 32'h00000018
`define NET_MAC_HI_ABS_ADDR (`NET_BASE + `NET_MAC_HI_ADDR)
`define NET_MAC_HI_RESET 32'h00000100

// mdio -- Write: bit 30 read, 25:21 PHY, 20:16 register, 15:0 value; read: bit 31 busy, 15:0 the value read.
`define NET_MDIO_ADDR 32'h0000001C
`define NET_MDIO_ABS_ADDR (`NET_BASE + `NET_MDIO_ADDR)
`define NET_MDIO_RESET 32'h00000000

// tx_len -- Write: send the frame in the buffer, this many bytes (padded to 60). Read: bit 0 busy.
`define NET_TX_LEN_ADDR 32'h00000020
`define NET_TX_LEN_ABS_ADDR (`NET_BASE + `NET_TX_LEN_ADDR)
`define NET_TX_LEN_RESET 32'h00000000

// tx_data -- The next 4 bytes of the frame to send (byte k in bits 8k+7:8k).
`define NET_TX_DATA_ADDR 32'h00000024
`define NET_TX_DATA_ABS_ADDR (`NET_BASE + `NET_TX_DATA_ADDR)
`define NET_TX_DATA_RESET 32'h00000000

// tx_ptr -- Write: the next tx_data goes to the start of the buffer.
`define NET_TX_PTR_ADDR 32'h00000028
`define NET_TX_PTR_ABS_ADDR (`NET_BASE + `NET_TX_PTR_ADDR)
`define NET_TX_PTR_RESET 32'h00000000

// rx_len -- Length of the waiting frame in bytes (FCS not included), 0 when none waits.
`define NET_RX_LEN_ADDR 32'h0000002C
`define NET_RX_LEN_ABS_ADDR (`NET_BASE + `NET_RX_LEN_ADDR)
`define NET_RX_LEN_RESET 32'h00000000

// rx_data -- The next 4 bytes of the waiting frame.
`define NET_RX_DATA_ADDR 32'h00000030
`define NET_RX_DATA_ABS_ADDR (`NET_BASE + `NET_RX_DATA_ADDR)
`define NET_RX_DATA_RESET 32'h00000000

// rx_done -- Write: the waiting frame is read, the next one comes.
`define NET_RX_DONE_ADDR 32'h00000034
`define NET_RX_DONE_ABS_ADDR (`NET_BASE + `NET_RX_DONE_ADDR)
`define NET_RX_DONE_RESET 32'h00000000

// rx_count -- Good frames received.
`define NET_RX_COUNT_ADDR 32'h00000038
`define NET_RX_COUNT_ABS_ADDR (`NET_BASE + `NET_RX_COUNT_ADDR)
`define NET_RX_COUNT_RESET 32'h00000000

// rx_dropped -- 15:0 frames dropped for lack of room, 31:16 with a bad FCS or length; reading clears both.
`define NET_RX_DROPPED_ADDR 32'h0000003C
`define NET_RX_DROPPED_ABS_ADDR (`NET_BASE + `NET_RX_DROPPED_ADDR)
`define NET_RX_DROPPED_RESET 32'h00000000

// tx_count -- Frames sent.
`define NET_TX_COUNT_ADDR 32'h00000040
`define NET_TX_COUNT_ABS_ADDR (`NET_BASE + `NET_TX_COUNT_ADDR)
`define NET_TX_COUNT_RESET 32'h00000000

// dna_raw0 -- Chip ID read, raw bits 31:0 of the OTP shift (register bit k = raw bit k; raw bit 0 is DOUT before the first clock edge).
`define NET_DNA_RAW0_ADDR 32'h00000080
`define NET_DNA_RAW0_ABS_ADDR (`NET_BASE + `NET_DNA_RAW0_ADDR)
`define NET_DNA_RAW0_RESET 32'h00000000

// dna_raw1 -- Chip ID read, raw bits 63:32.
`define NET_DNA_RAW1_ADDR 32'h00000084
`define NET_DNA_RAW1_ABS_ADDR (`NET_BASE + `NET_DNA_RAW1_ADDR)
`define NET_DNA_RAW1_RESET 32'h00000000

// dna_raw2 -- Chip ID read, raw bits 95:64.
`define NET_DNA_RAW2_ADDR 32'h00000088
`define NET_DNA_RAW2_ABS_ADDR (`NET_BASE + `NET_DNA_RAW2_ADDR)
`define NET_DNA_RAW2_RESET 32'h00000000

// dna_raw3 -- Chip ID read, raw bits 127:96.
`define NET_DNA_RAW3_ADDR 32'h0000008C
`define NET_DNA_RAW3_ABS_ADDR (`NET_BASE + `NET_DNA_RAW3_ADDR)
`define NET_DNA_RAW3_RESET 32'h00000000

// dna_raw4 -- Bit 0 is raw bit 128 (one past the register).
`define NET_DNA_RAW4_ADDR 32'h00000090
`define NET_DNA_RAW4_ABS_ADDR (`NET_BASE + `NET_DNA_RAW4_ADDR)
`define NET_DNA_RAW4_RESET 32'h00000000

// dna_status -- Bit 0 the OTP read is done (about 150 us after reset), 15:8 the ID width in bits (64 when the reader is in the build).
`define NET_DNA_STATUS_ADDR 32'h00000094
`define NET_DNA_STATUS_ABS_ADDR (`NET_BASE + `NET_DNA_STATUS_ADDR)
`define NET_DNA_STATUS_RESET 32'h00000000

// dna_id_lo -- Chip ID (Gowin OTP DNA, MODE 2'b01, valid bits 95:32 of the 128-bit read, SUG283-3.6.1E section 8.9) bits 31:0.
`define NET_DNA_ID_LO_ADDR 32'h00000098
`define NET_DNA_ID_LO_ABS_ADDR (`NET_BASE + `NET_DNA_ID_LO_ADDR)
`define NET_DNA_ID_LO_RESET 32'h00000000

// dna_id_hi -- Chip ID bits 63:32.
`define NET_DNA_ID_HI_ADDR 32'h0000009C
`define NET_DNA_ID_HI_ABS_ADDR (`NET_BASE + `NET_DNA_ID_HI_ADDR)
`define NET_DNA_ID_HI_RESET 32'h00000000

`endif // SDR_REGMAP_NET_VH
