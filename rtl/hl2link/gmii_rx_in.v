// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Receive input of the HL2 link: turns the bytes that the SFP lane's PCS delivers into the byte
// stream that eth_frame_rx.v takes, by dropping the preamble and the start-of-frame delimiter.
//
// What the preamble is, for a beginner: every Ethernet frame is sent behind seven bytes of 0x55
// (alternating ones and zeros, which only serve to let the receiver's clock recovery settle) and
// one byte 0xD5, the SFD (start-of-frame delimiter), whose last two bits (11) say that the real
// frame starts with the next byte. The frame proper, from the destination MAC address to the last
// FCS byte, is what the rest of the chain wants, so this module raises `active` for exactly those
// bytes.
//
// Where it sits: rtl/sfp/sfp_phy.v (the PCS, the 1000BASE-X layer that turns line symbols into
// bytes) delivers GMII style signals: a byte `rx_d`, a data-valid flag `rx_dv`, an error flag
// `rx_er` and a byte enable `rx_ce`. GMII is the gigabit media independent interface, the
// standard byte-wide connection between an Ethernet PCS or PHY and the MAC logic behind it. This
// module feeds eth_frame_rx.v with `data`, `active`, `err` and the byte enable `ce_o`. It runs
// in n1_rxc, the 125 MHz clock recovered from the lane (docs/HL2_SFP.md section 4).
//
// Byte enable: the lane's receive buffer is read while it is not almost empty (IPUG1024-1.7.2E
// 3.7.2), so a clock can arrive without a new byte. The PCS marks a new byte with `ce`. Every
// register here moves only with it, and `ce_o` marks the clock in which `data`, `active` and
// `err` are new. Otherwise they simply hold, and eth_frame_rx.v takes nothing in that clock.
//
// SFD detection: the first 0xD5 after `dv` rose (the PCS delivers /S/ as 0x55, then the rest of
// the preamble). No minimum preamble length is demanded, because the PCS may lose the first byte
// of a preamble (IEEE 802.3 36.2.4.13) and the FIFO of a copper module may shorten it.
//
// `err`: the PCS reported a code error or a frame cut short (rx_er) in this byte, and
// eth_frame_rx.v then drops the frame.
//
// Latency: one clock (the input registers).

`timescale 1ns / 1ps

module gmii_rx_in (
    input  wire       clk,         // the lane's recovered word clock (n1_rxc)
    input  wire       rst,         // synchronous reset, active high
    input  wire [7:0] rx_d,        // byte from the PCS
    input  wire       rx_dv,       // data valid: high from the preamble through the last FCS byte
    input  wire       rx_er,       // error in this byte (code error or cut short)
    input  wire       rx_ce,       // a new byte is on rx_d in this clock
    output reg  [7:0] data = 8'd0,   // frame byte, destination MAC first, FCS last
    output wire       active,      // high from the first byte after the SFD to the last FCS byte
    output reg        ce_o = 1'b0, // a new byte in this clock (data, active and err are valid)
    output wire       err          // error in this byte
);
    // The registered inputs: the byte, data valid and error, and `payload`, which says that the
    // SFD has gone past, so that the bytes now arriving belong to the frame proper.
    reg dv = 1'b0, er = 1'b0, payload = 1'b0;
    always @(posedge clk) begin
        ce_o <= rx_ce && !rst;
        if (rst) begin
            dv <= 1'b0; er <= 1'b0;
        end else if (rx_ce) begin
            data <= rx_d; dv <= rx_dv; er <= rx_er;
        end
    end
    // When the byte now in `data` is the SFD, the next one is content byte 0, and `payload` goes
    // high with it. It drops again when `dv` falls at the end of the frame.
    always @(posedge clk) begin
        if (rst) payload <= 1'b0;
        else if (ce_o) begin
            if (!dv) payload <= 1'b0;
            else if (!payload && (data == 8'hD5)) payload <= 1'b1;
        end
    end
    assign active = dv && payload;
    assign err    = dv && er;
endmodule
