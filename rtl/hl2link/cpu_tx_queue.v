// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// CPU transmit queue: a 4 KB buffer in block RAM in which the firmware prepares one complete
// Ethernet frame at a time, and from which the hardware sends it out when the wire is free
// (docs/ARCHITECTURE.md 3.1, transmit path: "arbiter with two sources, the TX sample framer
// (priority) and the CPU transmit queue").
//
// What an Ethernet frame is, for a beginner: a block of bytes that starts with the 6-byte
// destination MAC address (the hardware address of the receiving network card), then the 6-byte
// source MAC address, then a 2-byte type field, then the payload, and then a 4-byte checksum
// called the FCS (frame check sequence, a CRC-32). Firmware writes the frame from the destination
// MAC through the last payload byte and leaves the FCS out, because hl2_link_tx_top.v's shared
// crc32_append.v adds it in the same way for frames from either source.
//
// How it works, step by step:
//   1. The firmware writes the frame byte by byte through the write port (`wr_en`, `wr_addr`,
//      `wr_data`) into the memory.
//   2. It then pulses `send_len_wr` with the frame's length in `wr_len_in`, which latches the
//      length and raises `req`, the request for the wire. `busy` goes high at the same time and
//      tells the firmware not to touch the buffer until it falls again.
//   3. The arbiter in hl2_link_tx_top.v answers with `gnt` when the wire is free. The TX sample
//      framer has priority, so this only ever runs between that module's own frames.
//   4. The hardware then drains the memory one byte per clock on `tx_data`, with
//      `tx_enable_content` held high for exactly the bytes of the frame, and counts the frame in
//      `cnt_tx_frames` when the last byte is out.
//
// It is a single buffer, not a ring of several frames: `busy` says when the buffer is free again,
// so only one frame is in flight at a time. The traffic here is control traffic (discovery,
// register-write replies, aux and bridge datagrams), well under 1 Mbit/s against a link of
// 1000 Mbit/s, so the turnaround of one buffer is not a throughput concern.
//
// Memory shape (the Gowin specific point): exactly one write-only port and one read-only port,
// each in its own always block doing nothing else, which is the shape the chip's block RAM (BSRAM)
// needs. If the code asks for anything more, the tools build the 4 KB out of individual
// flip-flops instead.
//
// Clock: everything here is in clk_tx, the transmit clock (125 MHz). Whatever clock crossing the
// register bus needs to reach the write port is done outside this module.

`timescale 1ns / 1ps

module cpu_tx_queue #(
    parameter AW = 12   // address width in bits, 2**12 = 4096 bytes
) (
    input  wire         clk_tx,       // transmit clock, 125 MHz
    input  wire         rst_tx,       // synchronous reset, active high

    // firmware write port (clk_tx domain; the crossing from the bus clock is done outside)
    input  wire         wr_en,        // write wr_data to wr_addr in this clock
    input  wire [AW-1:0] wr_addr,     // byte address in the buffer, 0 is the first destination MAC byte
    input  wire [7:0]    wr_data,     // frame byte
    input  wire          send_len_wr,   // pulse: latch wr_len_in and request a send (ignored if busy)
    input  wire [15:0]   wr_len_in,     // frame length in bytes, FCS not included
    output wire           busy,          // the buffer holds a frame queued or sending

    // arbiter (hl2_link_tx_top.v)
    output wire         req,          // a frame is waiting and wants the wire
    input  wire         gnt,          // the arbiter grants the wire in this clock
    output reg  [7:0]  tx_data,       // the frame byte, valid while tx_enable_content is high
    output reg          tx_enable_content, // high for exactly the bytes of the frame

    output reg  [31:0] cnt_tx_frames   // frames completely sent since reset
) /* synthesis syn_srlstyle = "registers" */;

    // ---- memory: one write-only port, one read-only port (see the header) ----
    reg [7:0] mem [0:(1<<AW)-1];

    always @(posedge clk_tx) if (wr_en) mem[wr_addr] <= wr_data;

    // The read address and the registered read data. The read has one clock of latency, so the
    // drain below always works one byte behind the address.
    reg [AW-1:0] dp = {AW{1'b0}};
    reg [7:0]    mem_q;
    always @(posedge clk_tx) mem_q <= mem[dp];   // unconditional, its own block: see the header

    // ---- send state machine ----
    // IDLE: nothing sending (or waiting for the grant), PRIME: the first byte is arriving from
    // the memory, DRAIN: the rest of the frame is going out.
    localparam ST_IDLE = 2'd0, ST_PRIME = 2'd1, ST_DRAIN = 2'd2;
    reg [1:0]  state    = ST_IDLE;
    reg [15:0] frm_len  = 16'd0;    // length of the queued frame, 0 when none is queued
    reg [15:0] byte_cnt = 16'd0;    // bytes handled so far while draining

    assign req  = (state == ST_IDLE) && (frm_len != 16'd0);
    assign busy = (state != ST_IDLE) || (frm_len != 16'd0);

    always @(posedge clk_tx) begin
        if (rst_tx) begin
            state             <= ST_IDLE;
            frm_len           <= 16'd0;
            tx_enable_content <= 1'b0;
            cnt_tx_frames     <= 32'd0;
        end else begin
            // The send request is latched independently of `state`: it can arrive at any time, it
            // is only acted on from ST_IDLE (through `req` and `gnt`), and `busy` already tells
            // the firmware not to write a new frame or pulse `send_len_wr` again until this one
            // has cleared.
            //
            // `dp` is reset here, at the same clock edge as `frm_len`, and not at the grant. The
            // read-only memory block below samples `mem[dp]` unconditionally in every clock, one
            // clock ahead of where the drain consumes `mem_q`, so resetting `dp` only once the
            // grant arrived would still read the address that the previous frame's drain left
            // behind for that first clock. `req` cannot go true (frm_len is still 0 in this same
            // clock) until the clock after this one, so `dp` is always already 0 for at least one
            // full clock before any grant is possible.
            if (send_len_wr && !busy) begin
                frm_len <= wr_len_in;
                dp      <= {AW{1'b0}};
            end

            case (state)
                ST_IDLE: begin
                    tx_enable_content <= 1'b0;
                    if (req && gnt) begin
                        byte_cnt <= 16'd0;
                        state    <= ST_PRIME;
                    end
                end

                ST_PRIME: begin
                    // mem_q now holds mem[0] (the address that was set one clock ago, in the
                    // grant clock), so start emitting and ask the memory for the next address.
                    tx_enable_content <= 1'b1;
                    dp                <= dp + {{(AW-1){1'b0}}, 1'b1};
                    byte_cnt          <= 16'd1;
                    state             <= (frm_len == 16'd1) ? ST_IDLE : ST_DRAIN;
                    if (frm_len == 16'd1) begin
                        frm_len       <= 16'd0;
                        cnt_tx_frames <= cnt_tx_frames + 32'd1;
                    end
                end

                ST_DRAIN: begin
                    // `byte_cnt` (the value before the increment, which is what is read here)
                    // counts the drain intervals so far, starting at 1. The `mem_q` of this
                    // interval is `mem[byte_cnt-1]`, one behind, because `dp` (and so `mem_q`)
                    // always trails by the one clock that the registered memory read needs. The
                    // last of the `frm_len` bytes (index frm_len-1) is therefore read during the
                    // interval in which `byte_cnt` itself equals `frm_len`, and testing for
                    // `byte_cnt+1 == frm_len` would end the frame one interval early and never
                    // send the last byte.
                    byte_cnt <= byte_cnt + 16'd1;
                    if (byte_cnt == frm_len) begin
                        tx_enable_content <= 1'b0;
                        frm_len           <= 16'd0;
                        cnt_tx_frames     <= cnt_tx_frames + 32'd1;
                        state             <= ST_IDLE;
                    end else begin
                        dp <= dp + {{(AW-1){1'b0}}, 1'b1};
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    // The output byte is the registered memory read, with no logic in between.
    always @* tx_data = mem_q;

endmodule
