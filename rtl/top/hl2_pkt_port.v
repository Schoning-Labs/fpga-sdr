// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// hl2_pkt_port and hl2_txq_port: the two halves of the packet memory page 0xE802_0000 of the HL2 link
// (hw/regmap/hl2_pkt.toml). Through this page the CPU reads the Ethernet frames that the receive link block set aside for
// it (the frames that are not raw ADC samples, for example the HL2's discovery reply) and writes the frames it wants to send
// (for example the discovery request). The raw sample stream itself never goes through here.
//
// hl2_pkt_port, the lower half (offsets 0x0000 to 0x0FFF, read-only): the CPU receive ring of rtl/hl2link/cpu_rx_ring.v
// is 4 KB of block RAM with a byte-wide read port, while the register bus reads 32 bits at a time. This module therefore
// turns one 32-bit register read into four byte reads of the ring and packs the bytes little-endian, the byte order of the
// AE350, so that ring byte 4w+k lands in bits [8k+7:8k] of word w and the CPU sees the ring as a plain array of 32-bit
// words. The module is clocked by clk_rx (125 MHz, the receive clock of the SFP lane), the same clock as the ring's read
// port, which is why it has its own copy of the register bus (regbus_cdc_dst with RD_LAT = 8 in sdr_core.v).
// How a read goes, counted in clocks after the clock in which bus_rd is high (clock 0): at the end of clock 0 the word number
// is taken from bus_addr and the byte counter starts; the ring is asked for byte 0, 1, 2 and 3 in clocks 1 to 4, each answer
// arrives one clock after its address, and the last byte is stored at the end of clock 5, so bus_rdata is complete 6 clocks
// after bus_rd. regbus_cdc_dst waits RD_LAT clocks before it captures bus_rdata, and RD_LAT must be at least 6.
// Writes to this half are ignored, the ring is read-only for the CPU.

`timescale 1ns / 1ps

// hl2_pkt_port is clocked by clk_rx.
module hl2_pkt_port (
    input  wire        clk,  // receive clock of the SFP lane, 125 MHz
    input  wire        bus_rd,  // read strobe from regbus_cdc_dst, one clock per CPU read
    input  wire [15:0] bus_addr,  // offset inside the page in bytes; bits 11:2 select the 32-bit word of the 4 KB ring
    output reg  [31:0] bus_rdata,  // the 32-bit word read, built from four ring bytes (complete 6 clocks after bus_rd)
    output wire [11:0] ring_rd_addr,  // byte address into the receive ring: {word number, byte number}, 12 bits for 4 KB
    input  wire [7:0]  ring_rd_data  // byte read from the ring, arrives one clock after the address
);
    // word = number of the 32-bit word being read (bits 11:2 of the register address, 10 bits)
    reg [9:0] word = 10'd0;
    reg [2:0] step = 3'd4;       // byte counter of the read in progress: 0 to 3 = asking the ring for byte k, 4 = idle
    reg [2:0] got  = 3'd4;       // number of the byte whose data arrives from the ring in this clock (step one clock ago)
    // the byte address given to the ring is the word number followed by the two-bit byte number
    assign ring_rd_addr = {word, step[1:0]};

    // One clock per step: a read starts the byte counter, the counter walks through bytes 0 to 3 and stops at 4, and every
    // arriving byte is stored in its place within the 32-bit word. A new bus_rd in the middle of a read simply restarts it.
    always @(posedge clk) begin
        got <= step;
        if (bus_rd) begin
            word <= bus_addr[11:2];
            step <= 3'd0;
        end else if (step != 3'd4) begin
            step <= step + 1'b1;
        end
        // store the byte that arrives now into its slot of the output word, little-endian (byte 0 in the lowest bits)
        case (got)
            3'd0: bus_rdata[7:0]   <= ring_rd_data;
            3'd1: bus_rdata[15:8]  <= ring_rd_data;
            3'd2: bus_rdata[23:16] <= ring_rd_data;
            3'd3: bus_rdata[31:24] <= ring_rd_data;
            default: ;
        endcase
    end
endmodule

// ================================================================================ TX queue port
// hl2_txq_port, the upper half of the page (hw/regmap/hl2_pkt.toml tx_queue, tx_send and tx_status), clocked by clk_tx
// (125 MHz, the transmit clock of the SFP lane). The CPU builds a frame to send in the transmit queue of
// rtl/hl2link/cpu_tx_queue.v (4 KB of block RAM with a byte-wide write port) and then tells the transmit link its length.
//   offset 0x8000 to 0xBFFF  tx_queue   write-only; bits 11:2 of the offset select the 32-bit word of the queue
//   offset 0xC000            tx_send    write-only; bits 15:0 = length of the frame in bytes, which starts the transmission
//   offset 0xC004            tx_status  read-only; bit 0 = busy, a queued frame has not finished sending
//                                       (the CPU must not write tx_queue while it is set)
// One 32-bit write becomes four byte writes into the queue, byte k of the word going to queue address 4w+k, on four clocks
// in a row that start one clock after the write strobe. The register bus spaces its accesses much further apart than four
// clocks, so one word is always finished before the next arrives. A write to tx_send gives a one-clock pulse on
// cq_send_len_wr with the length on cq_wr_len. Any read returns tx_status at 0xC004 and 0 at every other address.
module hl2_txq_port (
    input  wire        clk,  // transmit clock of the SFP lane, 125 MHz
    input  wire        bus_wr,  // write strobe from regbus_cdc_dst, one clock per CPU write
    input  wire        bus_rd,  // read strobe, one clock per CPU read; unused, the read data follows the address
    input  wire [15:0] bus_addr,  // offset inside the page in bytes
    input  wire [31:0] bus_wdata,  // data of the CPU write
    output reg  [31:0] bus_rdata,  // read data: {31 zeros, busy} at 0xC004, else 0
    output reg         cq_wr_en = 1'b0,  // one-clock write enable of the queue's byte port
    output reg  [11:0] cq_wr_addr = 12'd0,  // byte address in the queue (4 KB), {word number, byte number}
    output reg  [7:0]  cq_wr_data = 8'd0,  // byte to write
    output reg         cq_send_len_wr = 1'b0,  // one-clock pulse: a frame of cq_wr_len bytes is ready to send
    output reg  [15:0] cq_wr_len = 16'd0,  // frame length in bytes, valid with cq_send_len_wr
    input  wire        cq_busy  // 1 = the previous frame has not finished sending
);
    // the 32-bit word being split into bytes, the word number it belongs to, and the byte counter (0 to 3 = writing byte k, 4 = idle)
    reg [31:0] word = 32'd0;
    reg [9:0]  widx = 10'd0;
    reg [2:0]  step = 3'd4;
    // The write enables are pulses and so are cleared every clock. A write to the queue half takes the word and starts the
    // byte counter, and in each following clock one byte is presented to the queue until the counter reaches 4.
    always @(posedge clk) begin
        cq_wr_en       <= 1'b0;
        cq_send_len_wr <= 1'b0;
        if (bus_wr && bus_addr[15:14] == 2'b10) begin          // 0x8000 to 0xBFFF: tx_queue (bits 15:14 = 10)
            word <= bus_wdata;
            widx <= bus_addr[11:2];
            step <= 3'd0;
        end else if (step != 3'd4) begin
            // write byte number step of the word to queue address {word number, step}
            cq_wr_en   <= 1'b1;
            cq_wr_addr <= {widx, step[1:0]};
            cq_wr_data <= word[8*step[1:0] +: 8];
            step       <= step + 1'b1;
        end
        if (bus_wr && bus_addr == 16'hC000) begin               // 0xC000: tx_send, passes the length on in a one-clock pulse
            cq_send_len_wr <= 1'b1;
            cq_wr_len      <= bus_wdata[15:0];
        end
        // read data, registered every clock: busy at 0xC004, zero at every other address
        bus_rdata <= (bus_addr == 16'hC004) ? {31'd0, cq_busy} : 32'd0;
    end
endmodule
