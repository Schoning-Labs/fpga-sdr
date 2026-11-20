// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Transmit side of an Ethernet MAC (media access control) at the GMII byte interface, for the network
// socket of sfp_net.v (the chip does not use that socket, and the HL2 link builds its frames in
// rtl/hl2link/tx_sample_framer.v and cpu_tx_queue.v instead). It reads one frame's content bytes
// (destination MAC through the last payload byte, with no preamble and no FCS) out of the packet memory
// through a plain synchronous read port (address in one clock, data in the next, the same shape that the
// other memories of the design use, chosen
// there so BSRAM synthesises instead of thousands of flip-flops), prepends the 7-byte preamble and
// the 1-byte start-of-frame delimiter, and appends the FCS (frame check sequence, the 4-byte CRC-32) with
// rtl/n1/fcs_append.v, in the same "gapless content stream in, content plus FCS out" split that the HL2
// link's transmit side uses (rtl/hl2link/hl2_link_tx_top.v). The output is one GMII byte per clock to the
// PCS (sfp_pcs.v, `mac_tx_data` and `mac_tx_en`), and the PCS is the one that puts /S/ in place of the
// first preamble byte and adds /T/ and /R/ at the end, not this module.
//
// States, in the order of a frame: ST_IDLE (waiting for a frame and for the link), ST_PRE (7 bytes of 0x55),
// ST_SFD (one byte 0xD5), ST_BODY (the content, then the 4 FCS bytes, until the FCS has left).
//
// Read pipelining: `tx_rd_addr` is driven one clock ahead of the byte it fetches. It is set to 0 as soon
// as the frame is accepted, so `tx_rd_data` already holds content byte 0 by the time ST_BODY needs it:
// the 7-clock preamble plus the 1-clock delimiter are exactly enough slack to hide the read latency of the
// memory, so fcs_append never sees a gap in the content.

`timescale 1ns / 1ps

module gmii_mac_tx (
    input  wire        clk,          // transmit clock, 125 MHz
    input  wire        rst,          // synchronous reset, active high

    input  wire        link_up,      // the PCS sends data: don't start a frame until this is set

    // --- packet memory: one synchronous read port + a "frame ready" handshake ---
    input  wire         tx_has_frame,    // a frame is waiting
    input  wire [15:0]  tx_frame_len, // content length, FCS not included
    output reg  [13:0]  tx_rd_addr,      // byte address in the frame
    input  wire [7:0]   tx_rd_data,   // = ring[tx_rd_addr], one cycle after the address changes
    output reg           tx_frame_taken, // pulse: this frame's bytes have all been read

    // --- to the PCS (sfp_pcs.v) ---
    output wire [7:0]  mac_tx_data,      // preamble, SFD, content, FCS
    output wire        mac_tx_en         // the byte is part of a frame
);

    localparam ST_IDLE = 2'd0, ST_PRE = 2'd1, ST_SFD = 2'd2, ST_BODY = 2'd3;
    reg [1:0]  state = ST_IDLE;
    reg [2:0]  pre_cnt = 3'd0;      // preamble bytes sent
    reg [15:0] byte_cnt;            // content bytes handled so far
    reg [15:0] frame_len;           // length of the frame being sent
    reg [15:0] len_m1 = 16'd0;      // frame_len - 1, kept in a register so the last-byte compare is fast

    wire       body_in_enable = (state == ST_BODY) && (byte_cnt != frame_len);
    wire       crc_out_en;
    wire [7:0] crc_out_data;

    // fcs_append and not rtl/hl2link/crc32_append.v: both give the same result and fcs_append is the one that
    // the network socket's testbench checks against an independent CRC.
    fcs_append u_crc_append (
        .clk       (clk),
        .rst       (rst),
        .in_data   (tx_rd_data),
        .in_enable (body_in_enable),
        .out_data  (crc_out_data),
        .out_enable(crc_out_en)
    );

    // The frame state machine. ST_IDLE takes a waiting frame once the link is up and loads its length;
    // ST_PRE and ST_SFD send the 8 bytes in front of the frame while the first content byte is read;
    // ST_BODY counts the content bytes into fcs_append (`body_in_enable` is high for exactly the content)
    // and ends when the FCS has left too. `tx_frame_taken` pulses when the last content byte has been read.
    always @(posedge clk) begin
        tx_frame_taken <= 1'b0;
        if (rst) begin
            state    <= ST_IDLE;
            pre_cnt  <= 3'd0;
            byte_cnt <= 16'd0;
            tx_rd_addr <= 14'd0;
        end else begin
            case (state)
                ST_IDLE: if (tx_has_frame && link_up) begin
                             state      <= ST_PRE;
                             pre_cnt    <= 3'd0;
                             byte_cnt   <= 16'd0;
                             frame_len  <= tx_frame_len;
                             len_m1     <= tx_frame_len - 16'd1;
                             tx_rd_addr <= 14'd0; // dout = byte 0 by the time ST_BODY starts
                         end
                ST_PRE:  if (pre_cnt == 3'd6) state <= ST_SFD;
                         else pre_cnt <= pre_cnt + 3'd1;
                ST_SFD:  begin
                    state      <= ST_BODY;
                    // One extra address bump here, ahead of the first real body_in_enable clock. The
                    // memory's read port takes an address in one clock and gives the byte in the
                    // next, so byte_cnt (the content counter) and tx_rd_addr (the fetch counter)
                    // have to be offset by one clock from each other, and not driven by the same
                    // increment condition, or every byte would be one behind and the last one would
                    // never be fetched. This early bump is exactly that offset.
                    tx_rd_addr <= tx_rd_addr + 14'd1;
                end
                ST_BODY: begin
                    if (body_in_enable) begin
                        byte_cnt   <= byte_cnt + 16'd1;
                        tx_rd_addr <= tx_rd_addr + 14'd1;
                        if (byte_cnt == len_m1) tx_frame_taken <= 1'b1;
                    end
                    if (!crc_out_en && !body_in_enable) state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end

    // Output: the preamble byte or the delimiter while in those states, then whatever fcs_append gives
    // (content, then the FCS), and enabled only while there is something to send.
    assign mac_tx_en   = (state == ST_PRE) || (state == ST_SFD) || ((state == ST_BODY) && crc_out_en);
    assign mac_tx_data = (state == ST_PRE) ? 8'h55 :
                          (state == ST_SFD) ? 8'hD5 :
                          crc_out_data;

endmodule
