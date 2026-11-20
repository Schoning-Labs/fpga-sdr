// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Appends the Ethernet FCS (frame check sequence, the 4-byte CRC-32 at the end of every frame) to a gapless
// stream of frame content, for the network socket's MAC (rtl/n1/gmii_mac_tx.v) and for the frames of the
// minimal Hermes-Lite 2 test build (rtl/hl2min/hl2min_sender.v). It does the same as
// rtl/hl2link/crc32_append.v, which explains the timing in detail (the FCS of the last content byte is
// ready in the clock right after it, so the FCS follows with no gap). The CRC itself is crc32_eth.v.
//
// The one point that matters: the CRC register is cleared between frames and never in the clock of the
// first content byte. crc32_eth.v gives `clear` priority over `enable`, so a clear in the clock of the
// first byte would keep that byte out of the CRC, and the FCS would be the CRC of bytes 1 to N-1, which
// no real switch would accept. The testbench sim/sfp/tb_sfp_net.v checks it against a bit-serial CRC-32
// written in the bench itself.

`timescale 1ns / 1ps

module fcs_append (
    input  wire       clk,         // transmit clock, 125 MHz
    input  wire       rst,         // synchronous reset, active high

    input  wire [7:0] in_data,     // frame byte, destination MAC first
    input  wire       in_enable,     // gapless content stream: 1 for every byte of one frame

    output reg  [7:0] out_data,    // content bytes, then the four FCS bytes
    output reg        out_enable     // content, then exactly 4 more cycles (the FCS), gapless
);

    reg prev_in_enable = 1'b0;
    wire falling = prev_in_enable && !in_enable;   // the cycle right after the last content byte

    wire crc_clear = !in_enable && !prev_in_enable; // between frames; never on a content byte
    wire [31:0] crc_run;

    crc32_eth crc_i (
        .clock (clk),
        .clear (crc_clear),
        .enable(in_enable),
        .data  (in_data),
        .crc   (crc_run)
    );

    wire [31:0] fcs_now = ~crc_run;   // valid combinationally on the `falling` cycle -- see header

    reg        appending   = 1'b0;
    reg [1:0]  fcs_idx      = 2'd0;   // 1, 2, 3 while `appending` (byte 0 is the `falling` cycle)
    reg [31:0] fcs_latched  = 32'd0;

    always @(posedge clk) begin
        prev_in_enable <= in_enable;
        if (rst) begin
            appending  <= 1'b0;
            fcs_idx     <= 2'd0;
        end else if (falling) begin
            fcs_latched <= fcs_now;
            appending   <= 1'b1;
            fcs_idx      <= 2'd1;
        end else if (appending) begin
            if (fcs_idx == 2'd3) appending <= 1'b0;
            else                  fcs_idx  <= fcs_idx + 2'd1;
        end
    end

    always @* begin
        if (in_enable) begin
            out_data   = in_data;
            out_enable = 1'b1;
        end else if (falling) begin
            out_data   = fcs_now[7:0];       // FCS byte 0
            out_enable = 1'b1;
        end else if (appending) begin
            case (fcs_idx)
                2'd1:    out_data = fcs_latched[15:8];
                2'd2:    out_data = fcs_latched[23:16];
                default: out_data = fcs_latched[31:24];  // fcs_idx == 3
            endcase
            out_enable = 1'b1;
        end else begin
            out_data   = 8'h00;
            out_enable = 1'b0;
        end
    end

endmodule
