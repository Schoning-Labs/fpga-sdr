// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// CPU receive ring: a 4 KB circular buffer in block RAM that collects every Ethernet frame the
// radio's firmware has to look at, which means every frame that eth_frame_rx.v does not classify
// as a raw sample frame (discovery replies, register-write replies, ARP, DHCP, ICMP, and the
// bridge, aux and message traffic of the Hermes-Lite 2). The firmware reads the frames out through
// the register page of the HL2 link (docs/ARCHITECTURE.md 3.1 step 2, 4.1, 4.3).
//
// Where it sits: eth_frame_rx.v (clk_rx, one byte per clock) feeds it with `sof`, `valid`,
// `data`, `eof` and `commit`. Its read side is the byte-wide window the CPU reads through the
// register bus, and its interrupt output tells the CPU that a new frame is waiting.
//
// What a stored frame looks like: a 2-byte big-endian length, followed by that many bytes, which
// are the destination MAC address through the last payload byte (the 4-byte FCS, the frame check
// sequence at the end of every Ethernet frame, is not stored, because eth_frame_rx.v already
// leaves it out). Frames follow each other directly, each one starting on an even byte address
// (an odd-length frame is padded with one zero byte in the ring, and its stored length is not
// padded). The firmware reads from where it last stopped up to `wr_ptr`, the byte address one
// past the newest complete frame, and wakes up through `irq_pkt_rx`.
//
// Commit or roll back: the frame is not known to be good until its last byte has been checked
// against the FCS, so each frame is stored speculatively, with its length word reserved at the
// start. At `eof` the frame is either committed (`commit` is high: the FCS was good and the frame
// is not a raw sample frame), which publishes it by moving `wr_ptr`, or it is rolled back by
// giving the whole reservation back, so the next frame reuses exactly the same ring space. Most
// frames on the wire are raw sample frames, which this ring never keeps, so the roll back is the
// common case. A committed frame that does not fit before the firmware's read position is dropped
// the same way and counted in `cnt_dropped`.
//
// Memory shape (the Gowin specific point): the ring is stored as 16-bit words, two bytes per
// word, behind exactly one write-only port and one read-only port, each in its own always block
// doing nothing else. That is the shape that the chip's block RAM (BSRAM) has, and the tools only
// use block RAM for it when the code looks that way: a memory that can take two writes in the same
// clock, or whose read shares an address with a write, falls back to individual flip-flops, which
// for 4 KB means roughly 33,000 of them. So everything that writes goes through one shared write
// port, arbitrated so that only one source fires in any clock:
//   - the payload byte stream, packed two bytes per word write as the bytes arrive;
//   - the pending frame's odd trailing byte, padded with a zero low byte, at `eof` if needed;
//   - the finished frame's length word, delayed to the clock after `eof` (`len_pending`), so that
//     it never has to share a clock with the two writes above. A new frame's first write cannot
//     land in that clock either, because `sof` and the previous frame's `eof` never coincide (a
//     real Ethernet frame is far longer than two clocks). The delay is invisible to everything
//     downstream except `wr_ptr`, `cnt_frames` and `irq_pkt_rx`, which move one more clock later
//     (`len_landing`), when the length word really is in the memory, so a reader is never pointed
//     at a frame whose length has not been written yet.
//
// The read port is a plain synchronous byte-address port with one clock of latency.

`timescale 1ns / 1ps

module cpu_rx_ring #(
    parameter RING_BYTES = 4096,   // size of the ring in bytes
    parameter AW = 12               // byte address width, 2**12 = 4096
) (
    input  wire        clk,        // clk_rx, the Ethernet receive clock
    input  wire        rst,        // synchronous reset, active high

    input  wire        sof,        // one-clock pulse with the first byte of a frame (data is byte 0 in the same clock)
    input  wire         valid,     // `data` is a frame byte this clock (one pulse per byte)
    input  wire [7:0]   data,      // frame byte, destination MAC first, FCS excluded
    input  wire         eof,         // this frame (of either kind) has ended
    input  wire         commit,      // asserted together with `eof`: CRC good and not raw, so keep it
    // (eof without commit, meaning a bad CRC or a frame that turned out to be a raw sample frame,
    // which stops `valid` partway through, rolls the speculative reservation back below)

    output reg  [15:0] cnt_frames,    // committed frames since reset (wraps at 65,536)
    output reg  [15:0] cnt_dropped,   // committed frames that did not fit; ring left unchanged
    output reg          irq_pkt_rx,   // one-cycle pulse per committed frame (PLIC line 0)

    // read port (byte address into the ring, 1-cycle latency)
    input  wire [AW-1:0] rd_addr,     // byte address the CPU wants to read
    output wire [7:0]    rd_data,     // that byte, one clock after rd_addr
    output reg  [AW-1:0] wr_ptr       // byte address one past the newest committed frame
) /* synthesis syn_srlstyle = "registers" */;

    localparam WAW = AW - 1;   // word address width: RING_BYTES/2 words

    reg [15:0] mem [0:(1<<WAW)-1];   // one array, two ports: write-only and read-only

    // -----------------------------------------------------------------
    // Assembly of the 16-bit words. Bytes arrive one per clock, so the first byte of each pair is
    // held in `byte_hi` for a clock and written together with the second one.
    reg           phase = 1'b0;    // 0: next byte starts a new word; 1: next byte completes it
    reg  [7:0]    byte_hi;         // the word's first (even byte-offset) half, held one cycle
    reg  [WAW-1:0] cur_word;        // word currently being assembled
    reg  [WAW-1:0] nextw = {WAW{1'b0}};       // next free word (word 0 of a frame is its length word)
    reg  [WAW-1:0] frame_start_w;   // this frame's length-word address
    reg  [15:0]   frame_len;        // bytes counted so far in the frame being stored
    reg           overflowed = 1'b0; // this frame has run into the firmware's read position

    wire [WAW-1:0] wr_ptr_word = wr_ptr[AW-1:1];   // the published pointer as a word address

    // The delayed length-word write, and the frame's wr_ptr and interrupt, which are released
    // together one clock after eof and commit (see the header).
    reg           len_pending = 1'b0;
    reg  [WAW-1:0] len_addr;
    reg  [15:0]   len_data;
    reg  [AW-1:0]  pending_wr_ptr;
    // The shared write port is itself registered (mem_we, mem_waddr and mem_wdata, then the memory
    // block), so a length word requested at one clock edge only lands in `mem` at the next. wr_ptr
    // and the interrupt therefore move one clock after the request (`len_landing`) and not with
    // it, because a reader that reacts in the very next clock would otherwise read the length word
    // before it has been written.
    reg           len_landing = 1'b0;

    // The one shared write port: exactly one of {delayed length word, odd-byte pad, payload byte
    // pair} drives it in any given clock (see the header for why they never collide).
    reg           mem_we;
    reg  [WAW-1:0] mem_waddr;
    reg  [15:0]   mem_wdata;

    always @(posedge clk) begin
        mem_we     <= 1'b0;
        irq_pkt_rx <= 1'b0;

        if (rst) begin
            phase       <= 1'b0;
            overflowed  <= 1'b0;
            cnt_frames  <= 16'd0;
            cnt_dropped <= 16'd0;
            wr_ptr      <= {AW{1'b0}};
            nextw       <= {WAW{1'b0}};
            len_pending <= 1'b0;
            len_landing <= 1'b0;
        end else begin
            // Release a length word queued by last clock's commit ...
            len_landing <= 1'b0;
            if (len_pending) begin
                mem_we      <= 1'b1;
                mem_waddr   <= len_addr;
                mem_wdata   <= len_data;
                len_pending <= 1'b0;
                len_landing <= 1'b1;
            end
            // ... and, once it has landed, the pointer update and interrupt that make this frame
            // visible to a reader.
            if (len_landing) begin
                wr_ptr      <= pending_wr_ptr;
                cnt_frames  <= cnt_frames + 16'd1;
                irq_pkt_rx  <= 1'b1;
            end

            if (sof) begin
                // Reserve the length word and this frame's first payload word in one go. `data`
                // is already byte 0 in this same clock (eth_frame_rx.v lines other_sof up with
                // other_data), so there is no "reserve now, start writing next clock" gap in which
                // the first byte could be lost. The overflow test asks whether the two reserved
                // words have reached the position the firmware has read up to.
                frame_start_w <= nextw;
                cur_word      <= nextw + 1'b1;
                nextw         <= nextw + 2'd2;
                byte_hi       <= data;
                phase         <= 1'b1;
                frame_len     <= 16'd1;
                overflowed    <= ((nextw + 2'd2) == wr_ptr_word);
            end else if (valid && !overflowed) begin
                // A payload byte: the first of a pair is kept, the second completes the word and
                // is written together with it.
                frame_len <= frame_len + 16'd1;
                if (!phase) begin
                    byte_hi  <= data;
                    cur_word <= nextw;
                    phase    <= 1'b1;
                    nextw    <= nextw + 1'b1;
                    if ((nextw + 1'b1) == wr_ptr_word) overflowed <= 1'b1;
                end else begin
                    mem_we    <= 1'b1;
                    mem_waddr <= cur_word;
                    mem_wdata <= {byte_hi, data};
                    phase     <= 1'b0;
                end
            end

            if (eof) begin
                if (commit && !overflowed) begin
                    if (phase) begin
                        // Odd byte count: flush the pending half word with its low byte padded
                        // with zero, so that the next frame's length word starts on a word
                        // boundary.
                        mem_we    <= 1'b1;
                        mem_waddr <= cur_word;
                        mem_wdata <= {byte_hi, 8'h00};
                    end
                    len_pending    <= 1'b1;
                    len_addr       <= frame_start_w;
                    len_data       <= frame_len;
                    pending_wr_ptr <= {nextw, 1'b0};
                end else begin
                    // CRC bad, turned out to be a raw frame, or too big for the ring: forget the
                    // whole reservation (length word included), so that no ring space leaks away
                    // frame after frame. Most frames on the wire are raw sample frames, which this
                    // module never commits.
                    nextw <= frame_start_w;
                    if (overflowed) cnt_dropped <= cnt_dropped + 16'd1;
                end
                phase      <= 1'b0;
                overflowed <= 1'b0;
            end
        end
    end

    // The memory-only ports: the write, and the unconditional read, with nothing else in their
    // blocks (see the header for why that isolation matters for block RAM).
    always @(posedge clk) if (mem_we) mem[mem_waddr] <= mem_wdata;

    // Read port: one 16-bit word per clock, then one byte of it picked by the low address bit
    // (remembered one clock, to line up with the word that comes out of the memory). The even
    // byte is the high half, which matches the big-endian order in which the bytes arrived.
    reg  [15:0] rd_q;
    always @(posedge clk) rd_q <= mem[rd_addr[AW-1:1]];

    reg rd_low_r;
    always @(posedge clk) rd_low_r <= rd_addr[0];

    assign rd_data = rd_low_r ? rd_q[7:0] : rd_q[15:8];

endmodule
