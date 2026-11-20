// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// bk_fifo: a small synchronous first-in first-out queue with "show-ahead" output, which means
// that dout is already the oldest entry whenever empty is low and the reader only has to pop it
// when it has taken it. The back end uses it between its engines (bk_front to bk_decim, bk_decim
// to the channel filters, the channel filters to bk_post) and in front of the output ring, so that
// an engine that is busy for a few dozen clocks does not stall the one before it. A push while the
// queue is full (and not popping) is dropped and pulses `overflow` for one clock, which the
// register block counts. The terms are explained in docs/learn/GLOSSARY.md.
//
// How it is built: the entries are in a small LUT RAM (8 to 64 words; the 64 x 53 and 32 x 68
// ones took 4 block RAMs each as block RAM). The oldest entry is moved from the memory into an
// output register (od, ov) as soon as that register is free, so that dout and empty both come
// straight from registers. The reader's take logic then starts at a flip-flop and not at a
// RAM read followed by a pointer compare, which was the slowest path of the whole back end
// before this was done. A pushed entry becomes visible one clock after the push, and after a
// pop the next entry is in dout the clock after. The capacity is 2^LOG2 + 1 (the output
// register counts as one). A push is taken whenever the memory is not full; since the output
// register holds one entry, the memory is not full while the reader is popping, so every push
// that a plain FIFO would take is taken here too, and the write enable does not wait for the
// pop logic.

`timescale 1ns / 1ps

module bk_fifo #(
    parameter integer DW   = 52,        // bits per entry
    parameter integer LOG2 = 4          // log2 of the number of memory words
) (
    input  wire          clk,
    input  wire          rst,           // synchronous reset, empties the queue
    input  wire          push,          // write din into the queue
    input  wire [DW-1:0] din,
    input  wire          pop,           // the reader takes dout (only meaningful when !empty)
    output wire [DW-1:0] dout,          // oldest entry
    output wire          empty,         // no entry in dout
    output wire          full,          // the memory has no free word
    output reg           overflow       // one-clock pulse: a push was dropped
);
    // LUT RAM: the read is registered (od).
    (* syn_ramstyle = "distributed_ram" *) reg [DW-1:0]   mem [0:(1<<LOG2)-1];
    reg [LOG2:0]   wp, rp;            // write and read pointers, one bit wider than an address (the extra bit tells full from empty)
    reg            ov;                // the output register holds the head
    reg [DW-1:0]   od;
    wire m_empty = (wp == rp);
    assign full  = (wp[LOG2] != rp[LOG2]) && (wp[LOG2-1:0] == rp[LOG2-1:0]);
    assign empty = !ov;
    assign dout  = od;
    // move the memory's head into the output register: it is free, or being popped
    wire take = !m_empty && (!ov || pop);
    always @(posedge clk) begin
        overflow <= 1'b0;
        if (take)
            od <= mem[rp[LOG2-1:0]];
        if (rst) begin
            wp <= 0;
            rp <= 0;
            ov <= 1'b0;
        end else begin
            if (push) begin
                if (!full) begin
                    mem[wp[LOG2-1:0]] <= din;
                    wp <= wp + 1'b1;
                end else
                    overflow <= 1'b1;
            end
            if (take) begin
                rp <= rp + 1'b1;
                ov <= 1'b1;
            end else if (pop)
                ov <= 1'b0;
        end
    end
endmodule
