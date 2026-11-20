// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Streaming Ethernet CRC-32, one byte per clock.
//
// What a CRC is, for a beginner: a CRC (cyclic redundancy check) is a 32-bit checksum worked out
// from every byte of a frame, in such a way that a single flipped bit, or any short burst of
// flipped bits, changes the result. The sender computes it over the frame and appends it as the
// last four bytes (the FCS, frame check sequence), and the receiver computes it again over what
// it received and compares. If the two differ, the frame was damaged on the way and is thrown
// away. The Hermes-Lite 2 does not check the FCS of what it receives, so this radio is the one
// that does it, and a damaged raw frame becomes a counted gap that gap_filler.v fills with zeros.
//
// How the calculation works: the CRC register starts at all ones (0xFFFFFFFF). For each new byte,
// the byte is XORed into the low eight bits of the register, and then the register is shifted
// right eight times, one bit per step, XORing in the polynomial 0xEDB88320 each time a one falls
// off the end. That polynomial is the usual CRC-32 polynomial 0x04C11DB7 written with its bits in
// reverse order, which is the form used when bytes are processed least significant bit first, the
// order in which Ethernet puts the bits on the wire. The loop in `next_crc` below is that
// calculation for one byte, and it is written as a loop of eight steps that the tools unroll into
// plain XOR gates, so one byte per clock costs no more than a short chain of XORs.
//
// This is the CRC-32/ISO-HDLC variant that IEEE 802.3 uses. The module returns the running
// register without the final inversion: a user that wants the transmitted FCS inverts it
// (crc32_append.v sends `~crc`), and a user that checks a received frame compares the inverted
// register with the four FCS bytes reassembled from the wire, which is what eth_frame_rx.v does.
//
// Used by: eth_frame_rx.v (check of every received frame) and crc32_append.v (the FCS of every
// transmitted frame).

`timescale 1ns / 1ps

module crc32_eth (
    input  wire        clock,
    input  wire        clear,   // synchronous: crc <= 32'hFFFFFFFF next cycle (wins over enable)
    input  wire        enable,  // consume `data` this cycle
    input  wire [ 7:0] data,    // the next frame byte
    output wire [31:0] crc      // running CRC-32, standard convention (seed 0xFFFFFFFF, no final invert)
);

    // The CRC register, preloaded with the seed so that the first frame needs no clear.
    reg [31:0] state = 32'hFFFFFFFF;

    // One byte of the CRC: XOR the byte into the low bits, then eight shift-and-conditionally-XOR
    // steps (shift right, and if the bit that fell off was a one, XOR in the polynomial).
    function [31:0] next_crc(input [31:0] c, input [7:0] d);
        integer i;
        reg [31:0] r;
        begin
            r = c ^ {24'h0, d};
            for (i = 0; i < 8; i = i + 1)
                r = r[0] ? ((r >> 1) ^ 32'hEDB88320) : (r >> 1);
            next_crc = r;
        end
    endfunction

    always @(posedge clock) begin
        if (clear) state <= 32'hFFFFFFFF;
        else if (enable) state <= next_crc(state, data);
    end

    assign crc = state;

endmodule
