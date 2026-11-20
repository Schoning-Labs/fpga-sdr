// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Appends the Ethernet FCS (frame check sequence, the 4-byte CRC-32 at the end of every frame) to
// the byte stream of the frame that is being transmitted.
//
// Where it sits: the arbiter in hl2_link_tx_top.v grants the wire either to tx_sample_framer.v
// (frames of samples for the HL2) or to cpu_tx_queue.v (frames prepared by the firmware). Both
// produce a frame from the destination MAC address through the last payload byte and neither
// knows anything about a CRC. This module sits behind the arbiter, passes the content through
// unchanged and adds the four FCS bytes right behind it, so the next stage (gmii_tx_out.v) sees
// one continuous, gapless byte stream per frame: content, then exactly four more bytes. See
// crc32_eth.v for what a CRC is and how it is calculated.
//
// The wire order of the FCS bytes: the check on the receiving side (eth_frame_rx.v) works as
// `crc_good = (~crc_run) == fcs_rx`, where `fcs_rx` reassembles the four trailing bytes with the
// LAST one that arrived as the most significant byte. Working that relation backwards, the four
// bytes must go out with the least significant byte of `~crc_run` first (bits 7:0, then 15:8, then
// 23:16, and 31:24 last), which is also the conventional order of a real Ethernet FCS.
//
// Timing, step by step:
//   1. While `in_enable` is high, every content byte goes to the output unchanged and into
//      crc32_eth.v.
//   2. crc32_eth.v updates its running value on the same clock edge on which it consumes the last
//      content byte. In the very next clock, the one in which `in_enable` reads low for the first
//      time (`falling`), `crc_run` therefore already covers the whole frame, and that clock can
//      carry FCS byte 0 straight from the combinational `~crc_run`, with no gap.
//   3. The value is latched in that clock, and the remaining three bytes follow from a small
//      counter (`fcs_idx` 1, 2, 3), one per clock, from the latched copy.
//
// Latency: no added delay for the content bytes (the path is combinational), and the FCS follows
// immediately after the last content byte.

`timescale 1ns / 1ps

module crc32_append (
    input  wire       clk,           // transmit clock, 125 MHz
    input  wire       rst,           // synchronous reset, active high

    input  wire [7:0] in_data,       // frame byte from the arbiter, destination MAC first
    input  wire       in_enable,     // gapless content stream: 1 for every byte of one frame

    output reg  [7:0] out_data,      // content bytes, then the four FCS bytes
    output reg        out_enable     // content, then exactly 4 more cycles (the FCS), gapless
);

    // `prev_in_enable` is `in_enable` one clock ago, which lets us find the first clock after the
    // content has ended.
    reg prev_in_enable = 1'b0;
    wire falling = prev_in_enable && !in_enable;   // the cycle right after the last content byte

    // The CRC is cleared between frames and never in the clock of the first content byte, because
    // crc32_eth.v gives `clear` priority over `enable`: a clear in the clock of the first byte
    // would keep that byte out of the CRC, and the FCS would then be the CRC of bytes 1 to N-1. The
    // producers start a frame only after the wire has been idle, so there is always a clock with
    // `in_enable` low and `prev_in_enable` low between two frames (the four FCS clocks at least).
    wire crc_clear = !in_enable && !prev_in_enable;
    wire [31:0] crc_run;

    crc32_eth crc_i (
        .clock (clk),
        .clear (crc_clear),
        .enable(in_enable),
        .data  (in_data),
        .crc   (crc_run)
    );

    wire [31:0] fcs_now = ~crc_run;   // valid combinationally on the `falling` cycle (see header)

    reg        appending   = 1'b0;    // high while FCS bytes 1 to 3 are going out
    reg [1:0]  fcs_idx      = 2'd0;   // 1, 2, 3 while `appending` (byte 0 is the `falling` cycle)
    reg [31:0] fcs_latched  = 32'd0;  // the FCS, held for bytes 1 to 3

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

    // Output multiplexer: content while it lasts, then the FCS bytes (byte 0 live, bytes 1 to 3
    // from the latched copy), otherwise nothing.
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
