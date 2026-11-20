// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Receive side of an Ethernet MAC (media access control) at the GMII byte interface. It takes the bytes
// of a frame from the PCS (sfp_pcs.v: preamble, start-of-frame delimiter, content and FCS, one byte per
// clock, with a data-valid flag), strips the preamble and the delimiter, checks the FCS (the CRC-32 at the
// end of the frame), and gives the content (destination MAC through the last payload byte, FCS excluded)
// to the packet memory (sfp_net.v), together with one end-of-frame pulse per frame that says whether the
// FCS was good. It belongs to the network socket of sfp_net.v, which the chip does not use (the HL2 link
// has its own chain, rtl/hl2link/eth_frame_rx.v); the two work in the same way.
//
// How the FCS check works: the FCS is the last four bytes of the frame, but when a byte arrives nobody
// knows whether it is among the last four. The usual solution, which eth_frame_rx.v uses too (it explains
// it in more detail), is to delay the byte stream by four clocks (`d1` to `d4`, with the flag `ca1` to
// `ca4` that says "this was frame content"), feed the CRC engine (crc32_eth.v) with the byte that is four
// clocks old, only while the frame is still going on four clocks later (`crc_en`, which is therefore 0
// for exactly the last four bytes of any frame, with no need to know the length in advance), and compare
// the inverted CRC with those last four bytes reassembled with the newest one on top.
//
// Byte enable: the SFP receive path has clocks without a byte (the transceiver's receive buffer is
// read while it is not almost empty). Every register moves only when `ce` is 1, so that a held byte is
// not taken twice, and a clock without a byte leaves everything as it is. Tie `ce` to 1 where every clock
// carries a byte.

`timescale 1ns / 1ps

module gmii_mac_rx (
    input  wire       clk,                 // receive clock, 125 MHz
    input  wire       rst,                 // synchronous reset, active high

    input  wire [7:0] mac_rx_data,         // byte from the PCS, preamble first
    input  wire       mac_rx_dv,           // data valid: high for the whole frame, preamble to FCS
    input  wire       mac_rx_er,           // error in this byte
    input  wire       ce,                  // a new byte in this clock

    output wire        rx_sof,             // pulse: rx_data is the first content byte
    output wire        rx_valid,           // rx_data is a content byte (FCS excluded)
    output wire [7:0]  rx_data,            // content byte
    output reg         rx_eof,       // pulse: this frame just ended
    output reg         rx_crc_good,  // valid on the rx_eof cycle
    output reg  [31:0] cnt_crc_errors      // frames with a bad FCS or an error, since reset
);

    // `content_active`: 1 from the cycle right after the SFD (0xD5) through the last FCS byte. It is
    // combinational in `mac_rx_dv` (via `seen_sfd`, and not via a registered copy of `mac_rx_dv`), so it
    // falls in the same clock in which `mac_rx_dv` does, which leaves exactly one register between "real
    // content" and its own one-clock-delayed copy (`content_active_d` below), the same shape as
    // `active` and `active_d` in eth_frame_rx.v. The PCS leaves `mac_rx_data` holding the last real byte
    // once `mac_rx_dv` drops, so a second register stage would shift that stale byte into the four-deep
    // delay line twice and put one FCS byte in the wrong place.
    reg seen_sfd = 1'b0;
    reg any_er = 1'b0;

    // `seen_sfd` goes high after the 0xD5 byte, and drops when the frame ends. `any_er` remembers an error
    // in any byte after it, which makes the frame count as bad.
    always @(posedge clk) begin
        if (rst || (ce && !mac_rx_dv)) begin
            seen_sfd <= 1'b0;
            any_er   <= 1'b0;
        end else if (!ce) begin
        end else if (!seen_sfd) begin
            if (mac_rx_data == 8'hD5) seen_sfd <= 1'b1; // next cycle's byte is content byte 0
        end else begin
            any_er <= any_er | mac_rx_er;
        end
    end

    wire content_active = mac_rx_dv && seen_sfd;

    // All registers of this section are explicitly cleared by `rst`, and not left to settle on their
    // own by shifting. Without that the delay chains (`d1` to `d4`, `ca1` to `ca4`, `sof1` to `sof4`) hold
    // unknown values in the first clocks of the very first frame after reset, which can make it come out
    // short or counted twice.
    reg content_active_d;
    always @(posedge clk) begin
        if (rst) content_active_d <= 1'b0;
        else if (ce) content_active_d <= content_active;
    end
    // Start and end of the content, found as the edges of content_active.
    wire c_sof = content_active & ~content_active_d;
    wire c_eof = content_active_d & ~content_active;

    reg [7:0]  d1, d2, d3, d4;
    reg        ca1, ca2, ca3, ca4;
    reg        sof1, sof2, sof3, sof4; // `c_sof` itself, delayed the same 4 clocks as d1..d4 and ca1..ca4. That is
                                        // simpler and cleaner than keeping a running byte index in step with them:
                                        // `c_sof` coincides with the first clock of `content_active`, so a separate
                                        // counter that is reset by it and also counts that clock would read "0" twice.

    always @(posedge clk) begin
        if (rst) begin
            d1 <= 8'h0; d2 <= 8'h0; d3 <= 8'h0; d4 <= 8'h0;
            ca1 <= 1'b0; ca2 <= 1'b0; ca3 <= 1'b0; ca4 <= 1'b0;
            sof1 <= 1'b0; sof2 <= 1'b0; sof3 <= 1'b0; sof4 <= 1'b0;
        end else if (ce) begin
            d1 <= mac_rx_data; d2 <= d1; d3 <= d2; d4 <= d3;
            ca1 <= content_active; ca2 <= ca1; ca3 <= ca2; ca4 <= ca3;
            sof1 <= c_sof; sof2 <= sof1; sof3 <= sof2; sof4 <= sof3;
        end
    end

    wire        crc_en = content_active & ca4 & ce;
    wire [31:0] crc_run;

    // `crc_started` goes high with the first `crc_en` pulse, and `crc_clear` marks that first pulse. The
    // CRC engine itself is cleared by `c_sof` below, four clocks ahead of the first byte that reaches it
    // (`crc_clear` itself is not used). Clearing in the clock of the first content byte would never
    // include that byte in the CRC, because crc32_eth.v gives `clear` priority over `enable`.
    reg crc_started;
    always @(posedge clk) begin
        if (rst || (ce && c_sof)) crc_started <= 1'b0;
        else if (crc_en) crc_started <= 1'b1;
    end
    wire crc_clear = crc_en && !crc_started;

    crc32_eth u_crc (
        .clock (clk),
        .clear (c_sof & ce),     // four clocks ahead of the first byte, so the first byte enters the CRC
        .enable(crc_en),
        .data  (d4),
        .crc   (crc_run)
    );

    // The outputs are the delayed stream, so they never include the FCS. The FCS (the last four bytes)
    // sits in d1 to d4 when the frame ends, newest byte in d1.
    assign rx_sof   = crc_en && sof4;
    assign rx_valid = crc_en;
    assign rx_data  = d4;

    wire [31:0] fcs_rx = {d1, d2, d3, d4};

    // At the end of the frame: one rx_eof pulse, with rx_crc_good telling whether the inverted CRC equals
    // the FCS bytes and no byte had an error. A bad frame is counted in cnt_crc_errors.
    always @(posedge clk) begin
        rx_eof <= 1'b0;
        if (rst) begin
            cnt_crc_errors <= 32'd0;
        end else if (c_eof && ce) begin
            rx_eof      <= 1'b1;
            rx_crc_good <= ((~crc_run) == fcs_rx) && !any_er;
            if (((~crc_run) != fcs_rx) || any_er) cnt_crc_errors <= cnt_crc_errors + 32'd1;
        end
    end

endmodule
