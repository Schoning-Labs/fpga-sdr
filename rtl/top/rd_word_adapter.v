// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// rd_word_adapter: lets a block that reads one 32-bit word at a time use the wide read lane of the DDR3 arbiter.
//
// WHERE IT SITS
// Two blocks of the radio read their rings out of DDR3 with a simple memory port: the audio ring reader
// (rtl/audio/audio_ring_reader.v) and the transmit baseband ring reader. Their port gives a one-clock request pulse
// (mem_req) with the address of a 32-bit word, and the answer (mem_rvalid with mem_rdata) comes any time later, with only one
// request outstanding. The read lane of the DDR3 arbiter (rtl/ddr3/ddr3_read_arbiter.v, one instance of this adapter per tier)
// speaks differently: it asks for a burst with req, addr and burstlen, waits for the grant (gnt) and then receives 64-bit lane
// words with rvalid. This module converts between the two. Every request is a burst of one 64-bit lane word, and the
// right half of that word is handed back to the ring reader.
//
// ADDRESSES
// The ring readers count 32-bit words and the lane counts 64-bit words (docs/F4_DDR.md section 2), so the lane address is the
// word address divided by two, and the lowest bit of the word address says which half of the lane word is wanted:
// word 2k is bits [31:0] of lane word k and word 2k+1 is bits [63:32]. This is the little-endian order of the AE350, so
// the CPU sees the ring as a plain array of 32-bit words.
//
// LATENCY
// req goes high one clock after mem_req, drops when the arbiter grants it, and mem_rvalid pulses one clock after rvalid.
// The time in between is the arbiter's and DDR3's, not this module's.

`timescale 1ns / 1ps

module rd_word_adapter (
    input  wire        clk,  // clock of the lane, clk_dsp (120 MHz)
    input  wire        rst,  // synchronous reset, high = reset
    // ring-reader side
    input  wire        mem_req,  // one-clock request pulse from the ring reader
    input  wire [31:0] mem_addr,  // address of the 32-bit word wanted (word number, not byte number)
    output reg         mem_rvalid,  // one-clock pulse: the word on mem_rdata is the answer
    output reg  [31:0] mem_rdata,  // the word read, valid together with mem_rvalid
    // arbiter client side
    output reg         req,  // request to the arbiter, held until it is granted
    output reg  [31:0] addr,  // lane address, counted in 64-bit lane words
    output wire [7:0]  burstlen,  // burst length in lane words: always 1
    input  wire        gnt,  // grant from the arbiter: the request has been accepted
    input  wire        rvalid,  // one-clock pulse: a lane word arrives on rdata
    input  wire [63:0] rdata  // the 64-bit lane word read
);
    // every request is one lane word
    assign burstlen = 8'd1;
    // hi = the half of the lane word that was asked for: 0 = bits [31:0], 1 = bits [63:32]
    reg hi = 1'b0;
    // One clock per step. A request from the ring reader raises req and remembers the address and the half; the grant
    // drops req again (only one request is ever outstanding); the arriving lane word is cut in half and passed back.
    always @(posedge clk) begin
        // mem_rvalid is a one-clock pulse, so it is cleared every clock and set again only when data arrives
        mem_rvalid <= 1'b0;
        if (rst) begin
            req <= 1'b0;
        end else begin
            // lane address = word address / 2, with a zero in the top bit
            if (mem_req) begin
                req  <= 1'b1;
                addr <= {1'b0, mem_addr[31:1]};
            // the lowest word address bit selects the half of the lane word
                hi   <= mem_addr[0];
            // accepted by the arbiter: stop requesting
            end else if (gnt) begin
                req <= 1'b0;
            end
            // data arrived: pass the wanted half back with a one-clock valid pulse
            if (rvalid) begin
                mem_rvalid <= 1'b1;
                mem_rdata  <= hi ? rdata[63:32] : rdata[31:0];
            end
        end
    end
endmodule
