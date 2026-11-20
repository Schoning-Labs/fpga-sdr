// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Taken from an earlier design by the same author; modified 2026 by
// Franz Schöning for fpga-sdr: the synthesis attributes on the module, and the synchronised pointers are turned to binary in a register
// of its own (w_bin, r_bin: one clock later; in fpga-sdr the read side of the playback FIFO runs at 120 MHz
// and Gray-to-binary, the flush selection and the LUT-RAM read did not fit one clock) (docs/USB_AUDIO.md).
//
// usb_afifo: a first-in first-out buffer whose write side and read side run on two unrelated clocks, with a
// "commit or abort" step on each side so that a whole USB packet is either kept or thrown away. It is the
// buffer between the USB clock (48 MHz) and the radio's clock (120 MHz) in both audio directions: usb_audio.v
// uses one copy for the playback stream (written by usb_ep_play.v on the USB clock, read by usb_play.v on the
// radio clock) and usb_ep_cap.v holds another for the capture stream (written on the radio clock, read on the USB
// clock); the register FIFO of the CPU is a different, simpler block (usb_play.v).
//
// Why it is needed. Two things happen at once here. First, the two sides of the FIFO have clocks that have
// nothing to do with each other, so a pointer that one side hands to the other has to be passed in a way that can
// never be read half-changed (a clock domain crossing, see docs/learn/GLOSSARY.md). Second, USB works in
// packets that can be bad: a packet is received while its CRC is still unknown, and only at its end does the
// device learn whether to keep it, and an IN packet that the host did not acknowledge must be sent a second time.
// So each side keeps a tentative pointer, which moves with every sample, and a committed pointer, which moves only
// when the packet is final.
//
//  - write side: w_push stores at the tentative write pointer; w_commit makes everything pushed so
//    far visible to the reader (including a push in the same cycle); w_abort drops everything
//    pushed since the last commit. Tie w_commit high for an ordinary FIFO.
//  - read side: r_data always shows the entry at the tentative read pointer (registered, so it is
//    valid from the clock after the pointer moved); r_pop steps the tentative pointer; r_commit
//    frees everything popped so far (including a pop in the same cycle); r_rewind goes back to
//    the last commit (a packet the host did not acknowledge is sent again). r_flush discards
//    everything visible (tentative and committed pointer jump to the write pointer).
//
// Crossing, step by step. A pointer is a binary counter with one more bit than the memory address needs (AW+1 bits
// for 2^AW entries, so full and empty can be told apart). When a counter goes from 0111 to 1000 all four bits change at
// once, and a flip-flop in the other clock domain that samples during the change can see any mixture, so the
// counters cross as Gray code, in which two neighboring values differ in a single bit, and a sample is then
// either the old or the new value. The committed pointers cross as Gray code through two flip-flops (the second
// one gives a metastable first one time to settle). A commit can move a
// pointer by many entries at once, and a multi-step jump in Gray code is not safe to sample, so
// the published pointer (w_pub, r_pub) walks towards the committed one (w_target, r_target) by one entry per clock: every change the
// other domain can sample is a single-bit Gray change. The walk costs at most DEPTH clocks of
// apparent latency, which no user here notices.
//
// The other side's pointer is seen three clocks of the receiving side late (two synchronizer registers and the binary register), after the walk, which
// is always on the safe side: the writer sees less room than there is, the reader fewer entries. The two sides
// have to be reset at the same time, because each side resets only its own pointers.
//
// Counts: w_free = DEPTH - (tentative write - synchronized published read);
// r_avail_c = synchronized published write - committed read; r_avail_t the same from the
// tentative read pointer. Pointers wrap, and the subtraction of two AW+1 bit counters is correct modulo 2^(AW+1).
//
// Gowin specifics: the memory is written on wclk and read on rclk with a registered output. With LUTRAM = 1 it is
// made of LUT RAM (the chip's logic cells used as memory, 16 words of a few bits per cell group, which can be read
// without a clock), which for the small FIFOs used here costs no block RAM, and the registered r_data
// after it keeps the read path short. With LUTRAM = 0 the tool maps it to block RAM (a 20 kbit memory block with a
// clocked read, which has no read-before-write mode on this chip, and the two ports use different addresses
// anyway). The attributes on the module keep the fan-out limit high and keep the two-stage synchronizers as
// ordinary registers.

`timescale 1ns / 1ps

// W: bits per entry. AW: address bits, so the FIFO holds 2^AW entries. LUTRAM: 1 = the memory is LUT RAM, 0 = block RAM.
module usb_afifo #(
    parameter integer W  = 32,
    parameter integer AW = 5,
    parameter integer LUTRAM = 0          // 1 = LUT RAM, 0 = block RAM
) (
    input  wire          wclk,  // write side clock
    input  wire          wrst,  // write side reset, synchronous to wclk
    input  wire          w_push,  // one-clock request: store w_data at the tentative write pointer (ignored when the FIFO is full)
    input  wire [W-1:0]  w_data,  // the entry to store
    input  wire          w_commit,  // make everything pushed so far (and this clock's push) visible to the reader
    input  wire          w_abort,  // forget everything pushed since the last commit
    output wire [AW:0]   w_free,  // free entries as seen by the writer, 0 to 2^AW (seen late, so never too many)

    input  wire          rclk,  // read side clock
    input  wire          rrst,  // read side reset, synchronous to rclk
    input  wire          r_pop,  // one-clock request: step the tentative read pointer to the next entry
    input  wire          r_commit,  // free everything popped so far
    input  wire          r_rewind,  // go back to the last commit, so what was popped since is read again
    input  wire          r_flush,  // drop everything that is visible
    output reg  [W-1:0]  r_data,  // the entry at the tentative read pointer, valid one clock after the pointer moved
    output wire [AW:0]   r_avail_c,  // entries available from the committed read pointer
    output wire [AW:0]   r_avail_t  // entries available from the tentative read pointer (what the reader may still pop)
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;
    // number of entries
    localparam integer DEPTH = 1 << AW;


    // Binary and Gray code conversion. In Gray code each bit is the XOR of two neighboring binary bits; converting back
    // takes the XOR of all Gray bits at and above each position.
    function [AW:0] bin2gray(input [AW:0] b);
        bin2gray = b ^ (b >> 1);
    endfunction
    function [AW:0] gray2bin(input [AW:0] g);
        integer i;
        for (i = 0; i <= AW; i = i + 1) gray2bin[i] = ^(g >> i);
    endfunction

    // Pointers (AW+1 bits). w_tent: tentative write. w_target: committed write. w_pub: published write, walking towards w_target.
    // w_pub_g: w_pub in Gray code, the one that crosses to the read clock. The read side has the same four, with
    // r_ for the read pointers.
    reg  [AW:0] w_tent, w_target, w_pub, w_pub_g;
    reg  [AW:0] r_tent, r_target, r_pub, r_pub_g;

    // ------------------------------------------------------------ write domain
    // The write side's view of the read pointer: two synchronizer registers (r_g_s1, r_g_s2) and the binary copy r_bin.
    reg  [AW:0] r_g_s1, r_g_s2, r_bin;
    wire [AW:0] r_sync = r_bin;
    // Room left: the memory size minus what lies between the committed-visible read pointer and the tentative write pointer.
    assign w_free = DEPTH[AW:0] - (w_tent - r_sync);
    wire do_push = w_push && (w_free != 0);
    wire [AW:0] w_tent_next = do_push ? w_tent + 1'b1 : w_tent;

    // (this block is empty and does nothing)
    always @(posedge wclk) begin
    end
    // Write side pointers: the synchronizer, the tentative and committed pointers, the walking published pointer.
    always @(posedge wclk) begin
        if (wrst) begin
            w_tent <= 0; w_target <= 0; w_pub <= 0; w_pub_g <= 0;
            r_g_s1 <= 0; r_g_s2 <= 0; r_bin <= 0;
        end else begin
            r_g_s1 <= r_pub_g;
            r_g_s2 <= r_g_s1;
            r_bin  <= gray2bin(r_g_s2);
            // an abort puts the tentative pointer back at the last commit; otherwise a push advances it, and a
            // commit moves the committed pointer to the new tentative position
            if (w_abort) begin
                w_tent <= w_target;
            end else begin
                w_tent <= w_tent_next;
                if (w_commit) w_target <= w_tent_next;
            end
            // the published pointer follows the committed one, one step a clock, and its Gray code is registered
            if (w_pub != w_target) w_pub <= w_pub + 1'b1;
            w_pub_g <= bin2gray(w_pub);
        end
    end

    // ------------------------------------------------------------ read domain
    // The read side's view of the write pointer, as above.
    reg  [AW:0] w_g_s1, w_g_s2, w_bin;
    wire [AW:0] w_sync = w_bin;
    // Entries available from the committed read position (the reader's own commit point, what the writer may reuse) and from the
    // tentative one (what the reader can still pop).
    assign r_avail_c = w_sync - r_target;
    assign r_avail_t = w_sync - r_tent;
    wire do_pop = r_pop && (r_avail_t != 0);
    // The next tentative read pointer: a flush jumps to the end of the data, a rewind goes back to the committed read pointer,
    // a pop steps one entry. The memory is read at this address, so r_data is already the right entry one clock after
    // the pointer moves.
    reg  [AW:0] r_tent_next;
    always @(*) begin
        if (r_flush)       r_tent_next = w_sync;
        else if (r_rewind) r_tent_next = r_target;
        else if (do_pop)   r_tent_next = r_tent + 1'b1;
        else               r_tent_next = r_tent;
    end

    // The memory with its write and its registered read, as LUT RAM or block RAM.
    generate if (LUTRAM != 0) begin : lram
        reg [W-1:0] mem [0:(1 << AW) - 1] /* synthesis syn_ramstyle = "distributed_ram" */;
        always @(posedge wclk) if (do_push) mem[w_tent[AW-1:0]] <= w_data;
        always @(posedge rclk) r_data <= mem[r_tent_next[AW-1:0]];
    end else begin : bram
        reg [W-1:0] mem [0:(1 << AW) - 1];
        always @(posedge wclk) if (do_push) mem[w_tent[AW-1:0]] <= w_data;
        always @(posedge rclk) r_data <= mem[r_tent_next[AW-1:0]];
    end endgenerate

    // Read side pointers, in the same manner as the write side.
    always @(posedge rclk) begin
        if (rrst) begin
            r_tent <= 0; r_target <= 0; r_pub <= 0; r_pub_g <= 0;
            w_g_s1 <= 0; w_g_s2 <= 0; w_bin <= 0;
        end else begin
            w_g_s1 <= w_pub_g;
            w_g_s2 <= w_g_s1;
            w_bin  <= gray2bin(w_g_s2);
            r_tent <= r_tent_next;
            // a flush and a commit both fix the new tentative position as the committed one
            if (r_flush || r_commit) r_target <= r_tent_next;
            if (r_pub != r_target) r_pub <= r_pub + 1'b1;
            r_pub_g <= bin2gray(r_pub);
        end
    end

endmodule
