// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Transmit output of the HL2 link: turns the frame stream of hl2_link_tx_top.v into the byte
// stream that the SFP lane's PCS sends, by putting a preamble and a start-of-frame delimiter in
// front of each frame and leaving a gap behind it.
//
// What the preamble and the gap are, for a beginner: every Ethernet frame is sent behind seven
// bytes of 0x55 (alternating ones and zeros, which let the receiver's clock recovery settle) and
// one byte 0xD5, the SFD (start-of-frame delimiter), and the standard demands a quiet gap of at
// least 12 byte times between two frames. The frame content, destination MAC address through the
// last FCS byte, comes from crc32_append.v with `tx_enable` high for every byte. This module adds
// the eight bytes in front with a shift register, and keeps `active` high for the 12 bytes of
// gap afterwards, which tells the arbiter in hl2_link_tx_top.v not to start the next frame any
// closer than the wire allows. The PCS replaces the first 0x55 by the start-of-packet code /S/
// and puts /T/ and /R/ (end of packet) into the gap (IEEE 802.3 36.2.4); rtl/sfp/sfp_phy.v is
// the PCS.
//
// How it works, step by step:
//   1. In ST_IDLE, nothing is being sent. When `tx_enable` rises, the module goes to ST_SEND, and
//      the byte at the top of the shift register (the first preamble byte) is registered to the
//      output in that very clock. The data bytes then enter the shift register at the bottom and come out at the top
//      eight clocks later, which is why the preamble and SFD are in front of them.
//   2. In ST_SEND, the shift register keeps moving until `tx_enable` has dropped and the last eight
//      bytes have been shifted out (`bytes_left` counts them), then the module goes to ST_GAP.
//   3. In ST_GAP, 12 byte times pass with `active` still high, then back to ST_IDLE.
//
// Link gate: a frame is passed to the PCS only if the lane's link was up when its first preamble
// byte left (`link_up`, from the PCS in the same clock). A frame that starts while the link is
// down is still clocked through (`active` and the gap as usual, so the framer and the CPU queue
// never stall), but `gmii_tx_en` stays 0 for all of it. The PCS then sends idle, and a link that
// comes up in the middle of a frame never receives half a frame.
//
// The outputs are registers, because the PCS is in another file and the lane's word clock is
// 125 MHz. The output has a latency of one clock.

`timescale 1ns / 1ps

module gmii_tx_out (
    input  wire       clk,           // the lane's transmit word clock (sfp_txc)
    input  wire [7:0] data,          // frame byte from crc32_append.v
    input  wire       tx_enable,     // one content byte of `data` valid this cycle
    input  wire       link_up,       // the PCS sends data (sfp_phy.v tx_link_up)

    output wire       active,        // high while sending (preamble/SFD/content) or in the gap
    output reg  [7:0] gmii_txd = 8'd0,   // byte to the PCS
    output reg        gmii_tx_en = 1'b0  // the byte on gmii_txd is part of a frame (preamble through FCS)
);

    // The preamble is seven 0x55 and one 0xD5, in a shift register as wide as the preamble. When no
    // frame is going on the register holds the preamble, ready for the next one.
    localparam [63:0] PREAMBLE_BYTES = 64'h55_55_55_55_55_55_55_D5;
    localparam        PREAMB_LEN     = 4'd8;
    localparam        HI_BIT         = 8*PREAMB_LEN - 1;

    reg [HI_BIT:0] shift_reg  = PREAMBLE_BYTES;
    reg [3:0]      bytes_left = 4'd0;       // counts the clocks left in the current stage

    localparam ST_IDLE = 2'd0, ST_SEND = 2'd1, ST_GAP = 2'd2;
    reg [1:0] state = ST_IDLE;
    reg       pass = 1'b0;                   // the link was up when this frame started

    wire sending = tx_enable | (state == ST_SEND);
    assign active = sending | (state == ST_GAP);

    always @(posedge clk) begin
        if (sending) shift_reg <= {shift_reg[HI_BIT-8:0], data};
        else         shift_reg <= PREAMBLE_BYTES;

        case (state)
            ST_IDLE: if (tx_enable) begin state <= ST_SEND; pass <= link_up; end

            // While tx_enable is high, the count is held at 7 (one less than the preamble length)
            // so that when the content ends, the preamble length minus one more bytes still have to
            // come out of the shift register before the gap starts.
            ST_SEND: begin
                if (tx_enable) bytes_left <= PREAMB_LEN - 4'd1;
                else if (bytes_left != 0) bytes_left <= bytes_left - 4'd1;
                else begin bytes_left <= 4'd12; state <= ST_GAP; end
            end

            ST_GAP: begin
                if (bytes_left != 0) bytes_left <= bytes_left - 4'd1;
                else state <= ST_IDLE;
            end

            default: state <= ST_IDLE;
        endcase

        // The byte at the top of the shift register leaves now. In the clock of the change from
        // ST_IDLE to ST_SEND, `pass` is not yet set, so the first preamble byte takes its enable
        // from link_up directly.
        gmii_txd   <= shift_reg[HI_BIT -: 8];
        gmii_tx_en <= sending && ((state == ST_IDLE) ? link_up : pass);
    end

endmodule
