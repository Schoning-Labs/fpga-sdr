// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Asynchronous FIFO: a small queue that is written with one clock and read with another one, so
// that samples can cross from one clock domain into the other without ever being torn or lost.
//
// Where it sits: raw_frame_buffer.v drains the committed samples of a raw frame into this FIFO on
// the Ethernet receive clock (the 125 MHz clock recovered from the SFP lane, called clk_rx in the
// HL2 link), and gap_filler.v reads them on clk_dsp (120 MHz), which is where the whole receiver
// bank lives (docs/ARCHITECTURE.md 3.1, steps 3 and 4). The two clocks come from different
// oscillators and have no fixed phase relation at all, so a plain register or a plain memory
// shared between them would, every now and then, be read at the very moment it changes.
//
// How it works, step by step:
//   1. The data sits in an ordinary dual-port memory with one write port (clocked by wr_clk) and
//      one read port (clocked by rd_clk). The memory itself never has a problem, because each
//      port only ever sees its own clock.
//   2. The only things that have to cross are the two pointers, "how far has the writer got" and
//      "how far has the reader got". The writer needs the read pointer to know whether the queue
//      is full, and the reader needs the write pointer to know whether it is empty.
//   3. A binary counter is a bad thing to pass between clocks, because going from 0111 to 1000
//      changes four bits at once, and a flip-flop that samples in the middle of that change can
//      see any mix of old and new bits (0000, 1111, and so on), which would look like a wildly
//      wrong position. So each pointer is converted to Gray code before it crosses: in a Gray code
//      exactly one bit changes per step, so a sample taken during a change is either the old
//      value or the new one, both of which are harmless (the other side just sees the pointer
//      one step late, which only makes the FIFO look a little fuller or emptier than it is).
//   4. The Gray pointer is then passed through two flip-flops in the destination clock (a two
//      stage synchronizer), which gives a flip-flop that went metastable a whole clock to settle.
//   5. Full means "the write pointer is exactly one lap (DEPTH entries) ahead of the read
//      pointer", empty means "the two pointers are equal". The pointers have one extra top bit
//      to tell those two cases apart, since in both cases the low bits are equal.
//
// The data is not interpreted here. The caller reserves the top bit of each word (din[W-1]) as a
// tag marking the first sample of a committed frame, and this module just carries it along.
//
// Written as plain dual-port memory plus Gray pointers, so that it maps onto ordinary block RAM
// (BSRAM) on the Gowin chip with no vendor FIFO macro. The depth must be a power of two.
//
// Write side contract: `wr_full` answers "is there room for a write issued on the NEXT wr_clk
// cycle?", so it already counts a write that is happening in this very cycle. Both writers in
// raw_frame_buffer.v decide to write one clock before the write reaches this module (their
// `wr_en` is a register), which is exactly the question they need answered. For that reason
// `wr_en` must never depend combinationally on `wr_full`, and it does not in either caller: if
// it did, the flag would be a function of itself (full blocks the write, so it is not full, so
// the write goes ahead, so it is full again), which is a combinational loop that has no stable
// value. A write that arrives while the FIFO is really full is still dropped here as a safety
// net, so the memory can never be overwritten.
//
// Latency: a word written in one wr_clk cycle can be read at the earliest about three rd_clk
// cycles later (two for the synchronizer, one for the compare), and the read data comes one
// clock after rd_en.

`timescale 1ns / 1ps

module cdc_sample_fifo #(
    parameter W  = 13,            // word width in bits (a 12-bit sample plus the first-sample tag)
    parameter AW = 6,             // depth = 2**AW words
    // 1: `wr_full` comes from a register that is computed one clock early and is conservative by up
    // to two entries (it is true from DEPTH-2 words on, with the read pointer as the writer sees
    // it), so the writer's decision does not have to wait for the pointer comparison and the add
    // behind it. At 125 MHz that chain (the synchronized read pointer into the raw frame buffer's
    // drain counters) is long enough to miss timing on the Gowin chip, and the register cuts it.
    // 0: the exact flag, which allows the FIFO to fill up to the last word.
    parameter REG_FULL = 0
) (
    input  wire             wr_clk,   // write clock (125 MHz Ethernet receive clock)
    input  wire             wr_rst,   // synchronous reset for the write side, active high
    input  wire              wr_en,   // write the word on wr_data in this clock (see the contract above)
    input  wire [W-1:0]      wr_data, // word to store, written together with wr_en
    output wire               wr_full, // no room for a write issued on the next clock

    input  wire             rd_clk,   // read clock (120 MHz clk_dsp)
    input  wire             rd_rst,   // synchronous reset for the read side, active high
    input  wire              rd_en,   // request the next word (ignored while empty)
    output reg  [W-1:0]      rd_data, // the word asked for, valid when rd_valid is high
    output reg                rd_valid, // rd_data holds the word requested by rd_en last cycle
    output wire               rd_empty  // nothing to read (as seen through the synchronizer, so it can be a little late)
) /* synthesis syn_srlstyle = "registers" */;

    localparam DEPTH = 1 << AW;

    // The storage. One array, one write port and one read port, which is the shape the block RAM
    // of the chip has.
    reg [W-1:0] mem [0:DEPTH-1];

    // Both pointer registers are declared up front, because the simulator wants a declaration
    // textually before any use, including the cross-domain synchronizer reads below that refer to
    // the other side's pointer. Each pointer has AW+1 bits: AW address bits plus one lap bit.
    reg [AW:0] wr_bin  = {(AW+1){1'b0}};   // write pointer in binary, used inside the write domain
    reg [AW:0] wr_gray = {(AW+1){1'b0}};   // the same pointer in Gray code, this is what crosses
    reg [AW:0] rd_bin  = {(AW+1){1'b0}};   // read pointer in binary
    reg [AW:0] rd_gray = {(AW+1){1'b0}};   // read pointer in Gray code

    // ---- write side ----

    // The read pointer, brought into the write clock through two flip-flops. The preserve
    // attribute stops the tools from merging or retiming these two, since they only work as a
    // synchronizer while they stay plain back-to-back registers.
    (* preserve *) reg [AW:0] rd_gray_wq1 = {(AW+1){1'b0}};
    (* preserve *) reg [AW:0] rd_gray_wq2 = {(AW+1){1'b0}};

    // The Gray code of a pointer that is exactly one lap (DEPTH entries) ahead of the synchronized
    // read pointer. In a Gray code that is the same value with its top two bits inverted. When the
    // write pointer equals it, every word of the memory holds unread data.
    wire [AW:0] full_gray = {~rd_gray_wq2[AW:AW-1], rd_gray_wq2[AW-2:0]};
    wire        full_now  = (wr_gray == full_gray);     // registers only: no loop
    wire        wr_do     = wr_en & ~full_now;           // the write that really happens

    // Pointer after this clock's write, in binary and then converted to Gray (x ^ (x >> 1)).
    wire [AW:0] wr_bin_next = wr_bin + wr_do;
    wire [AW:0] wr_gray_next = wr_bin_next ^ (wr_bin_next >> 1);

    always @(posedge wr_clk) begin
        if (wr_rst) begin
            wr_bin  <= {(AW+1){1'b0}};
            wr_gray <= {(AW+1){1'b0}};
        end else begin
            if (wr_do) mem[wr_bin[AW-1:0]] <= wr_data;
            wr_bin  <= wr_bin_next;
            wr_gray <= wr_gray_next;
        end
        rd_gray_wq1 <= rd_gray;
        rd_gray_wq2 <= rd_gray_wq1;
    end

    // The exact flag: full once this cycle's write (if any) has landed, which means there is no
    // room for a write in the next cycle.
    wire full_exact = (wr_gray_next == full_gray);

    // REG_FULL: the flag of the next clock, worked out from this clock's registers. Between now and
    // the clock in which the writer uses the answer, at most two writes can land (this clock's and
    // the next clock's) and the read pointer can only move on, so "no room for a write one clock
    // after those" is true when the FIFO now holds DEPTH-2, DEPTH-1 or DEPTH words, i.e. when the
    // write pointer plus 0, 1 or 2 equals the read pointer plus DEPTH. The price is that up to two
    // words of the memory stay unused.
    wire [AW:0] wr_bin_p1 = wr_bin + 1'b1;
    wire [AW:0] wr_bin_p2 = wr_bin + 2'd2;
    wire [AW:0] wr_gray_p1 = wr_bin_p1 ^ (wr_bin_p1 >> 1);
    wire [AW:0] wr_gray_p2 = wr_bin_p2 ^ (wr_bin_p2 >> 1);
    reg  full_r = 1'b0;
    always @(posedge wr_clk) begin
        if (wr_rst) full_r <= 1'b0;
        else        full_r <= (wr_gray == full_gray) || (wr_gray_p1 == full_gray) || (wr_gray_p2 == full_gray);
    end
    assign wr_full = REG_FULL ? full_r : full_exact;

    // ---- read side ----

    // Pointer after this clock's read, in binary and in Gray code. A read only counts when the FIFO
    // is not empty.
    wire [AW:0] rd_bin_next = rd_bin + (rd_en & ~rd_empty);
    wire [AW:0] rd_gray_next = rd_bin_next ^ (rd_bin_next >> 1);

    // The write pointer, brought into the read clock through two flip-flops (the mirror image of
    // the pair on the write side).
    (* preserve *) reg [AW:0] wr_gray_rq1 = {(AW+1){1'b0}};
    (* preserve *) reg [AW:0] wr_gray_rq2 = {(AW+1){1'b0}};

    always @(posedge rd_clk) begin
        if (rd_rst) begin
            rd_bin   <= {(AW+1){1'b0}};
            rd_gray  <= {(AW+1){1'b0}};
            rd_valid <= 1'b0;
        end else begin
            rd_bin  <= rd_bin_next;
            rd_gray <= rd_gray_next;
            rd_valid <= 1'b0;
            if (rd_en & ~rd_empty) begin
                rd_data  <= mem[rd_bin[AW-1:0]];
                rd_valid <= 1'b1;
            end
        end
        wr_gray_rq1 <= wr_gray;
        wr_gray_rq2 <= wr_gray_rq1;
    end

    // Empty when the read pointer has caught up with the (synchronized) write pointer. Because the
    // write pointer is seen a few clocks late, the FIFO can briefly look empty when one word has
    // just been written, which only delays the reader and never loses a word.
    assign rd_empty = (rd_gray == wr_gray_rq2);

endmodule
