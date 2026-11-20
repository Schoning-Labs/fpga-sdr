// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Board link, receive side buffer: holds a sample frame until its CRC has been checked and was good, and then
// hands it to the gap filler in clk_dsp (docs/SFP_LINKS.md 5.2). It has the same shape and the same two FIFOs as
// rtl/hl2link/raw_frame_buffer.v (which explains the ring, the drain and the clock crossing in detail), with
// these differences: the samples are 12 bits and arrive already unpacked, the ring is small, up to 16 frames
// may wait one behind the other, and a frame that would not fit is dropped whole. So the unchanged
// rtl/hl2link/gap_filler.v can read it: a sample FIFO with a start flag, and one first-sample index per frame.
//
// A frame's samples are written into the ring as they arrive. `commit` (CRC good) puts the frame on a list of
// waiting frames and starts the drain into the sample FIFO; without a commit the next `sof` simply starts again at
// the same place, which discards the frame. A frame is dropped (`drop` pulse) when at its start the ring has under
// 264 free places, or when it ends while 16 frames are already waiting: the gap filler then fills it with zeros
// like any lost frame. The 264 is two maximum frames (128 samples each) and a margin of 8, because the start of
// a frame can follow the commit of the one before so closely that `room` does not show that frame yet.

`timescale 1ns / 1ps

module blink_rx_buf #(
    parameter integer AW = 9    // address width of the ring, 2**AW samples
) (
    input  wire        clk_rx,           // lane 1 recovered receive word clock, 125 MHz
    input  wire        rst_rx,           // synchronous reset for the clk_rx domain, active high
    input  wire        sof,              // a frame starts (before its first sample)
    input  wire        s_valid,          // s_data is a sample of the frame
    input  wire [11:0] s_data,           // 12-bit sample
    input  wire        commit,           // the frame just written is good
    input  wire [47:0] commit_first_idx, // index of the frame's first sample
    input  wire [7:0]  commit_n,         // samples - 1
    output reg         drop = 1'b0,      // pulse: a committed frame was dropped (no room)
    // ---- clk_dsp (gap_filler.v)
    input  wire        clk_dsp,          // 120 MHz
    input  wire        rst_dsp,          // synchronous reset for the clk_dsp domain, active high
    input  wire        samp_pop,         // read one sample word
    output wire        samp_sof,         // the sample is the first of a frame
    output wire [11:0] samp_data,        // 12-bit sample
    output wire        samp_valid,       // samp_data holds the word requested a clock ago
    input  wire        idx_pop,          // read one frame index
    output wire [47:0] idx_data,         // first-sample index of a frame
    output wire        idx_valid         // idx_data is valid
) /* synthesis syn_srlstyle = "registers" */;

    // The ring of samples. `wp` is the write pointer, `frame_start` where the frame being received began, and
    // `skip` says that the frame is being thrown away because there was no room at its start.
    reg [11:0] mem [0:(1<<AW)-1];
    reg [AW-1:0] wp = {AW{1'b0}}, frame_start = {AW{1'b0}};
    reg          skip = 1'b0;

    // Committed frames wait in the ring one behind the other, and a 16-deep list (`dmem`, with write pointer
    // `d_wp` and read pointer `d_rp`, five bits each so that full and empty can be told apart) holds their lengths
    // and first-sample indices.
    reg [55:0]   dmem [0:15];
    reg [4:0]    d_wp = 5'd0, d_rp = 5'd0;
    wire         d_empty = (d_wp == d_rp);
    wire         d_full  = (d_wp[3:0] == d_rp[3:0]) && (d_wp[4] != d_rp[4]);
    wire [55:0]  d_head  = dmem[d_rp[3:0]];

    // The drain, one frame at a time from the list: `dp` is the ring read address, `remaining` the samples of the
    // frame still to fetch, `drain_first_idx` the frame's index, and `drain_first` marks its first sample.
    reg          draining = 1'b0;
    reg [AW-1:0] dp = {AW{1'b0}};
    reg [8:0]    remaining = 9'd0;
    reg [47:0]   drain_first_idx = 48'd0;
    reg          drain_first = 1'b0;

    // Room in front of the oldest sample still needed: the ring may hold up to 2**AW - 264 samples between the
    // drain pointer and the start of the current frame. `room` is registered.
    wire [AW-1:0] used = frame_start - dp;
    reg           room = 1'b1;

    always @(posedge clk_rx) room <= (used < ((1 << AW) - 264));

    // A frame is taken (put on the list) when it is committed, was not skipped, and the list has room. The write
    // pointer returns to the frame start at every `sof`, so an uncommitted frame is overwritten by the next one.
    wire take = commit && !skip && !d_full;
    always @(posedge clk_rx) begin
        if (rst_rx) begin
            wp <= {AW{1'b0}}; frame_start <= {AW{1'b0}}; skip <= 1'b0; d_wp <= 5'd0;
        end else if (sof) begin
            wp   <= frame_start;
            skip <= !room;
        end else if (s_valid && !skip) begin
            wp <= wp + 1'b1;
        end else if (take) begin
            frame_start <= wp;
            dmem[d_wp[3:0]] <= {commit_n, commit_first_idx};
            d_wp <= d_wp + 5'd1;
        end
    end
    // The memory write, in a block of its own (a block RAM with one write port and one registered read port).
    always @(posedge clk_rx) if (s_valid && !skip && !sof) mem[wp] <= s_data;

    // ---- drain (rtl/hl2link/raw_frame_buffer.v explains the parked word `hold_*` and the one-clock-late
    // `q_pend_*` flags, which are the same here)
    reg         q_pend_valid = 1'b0, q_pend_first = 1'b0;
    reg         hold_valid = 1'b0, hold_first = 1'b0;
    reg [11:0]  hold_q = 12'd0, mem_q = 12'd0;
    reg         fifo_wr = 1'b0, idx_send = 1'b0;
    reg [12:0]  fifo_wdata = 13'd0;
    reg [47:0]  idx_send_data = 48'd0;
    wire        fifo_wr_full;

    wire have_word   = hold_valid || q_pend_valid;
    wire do_consume  = have_word && !fifo_wr_full;
    wire can_advance = draining && (remaining != 9'd0) && (!have_word || do_consume);
    wire        out_first = hold_valid ? hold_first : q_pend_first;
    wire [11:0] out_q     = hold_valid ? hold_q     : mem_q;
    wire is_first    = drain_first;

    always @(posedge clk_rx) begin
        fifo_wr  <= 1'b0;
        idx_send <= 1'b0;
        drop     <= commit && !take;
        if (rst_rx) begin
            draining <= 1'b0; q_pend_valid <= 1'b0; hold_valid <= 1'b0; dp <= {AW{1'b0}}; d_rp <= 5'd0;
        end else begin
            if (do_consume) begin
                fifo_wr    <= 1'b1;
                fifo_wdata <= {out_first, out_q};
                if (out_first) begin
                    idx_send      <= 1'b1;
                    idx_send_data <= drain_first_idx;
                end
            end

            if (can_advance) begin
                dp          <= dp + 1'b1;
                remaining   <= remaining - 9'd1;
                drain_first <= 1'b0;
                if (remaining == 9'd1) draining <= 1'b0;
            end else if (!draining && !d_empty) begin
                draining <= 1'b1; drain_first <= 1'b1;
                remaining <= {1'b0, d_head[55:48]} + 9'd1; drain_first_idx <= d_head[47:0];
                d_rp <= d_rp + 5'd1;
            end

            if (q_pend_valid && !do_consume) begin
                hold_valid <= 1'b1; hold_q <= mem_q; hold_first <= q_pend_first;
            end else if (hold_valid && do_consume) begin
                hold_valid <= 1'b0;
            end
            q_pend_valid <= can_advance;
            q_pend_first <= is_first;
        end
    end
    always @(posedge clk_rx) mem_q <= mem[dp];

    wire [12:0] samp_rd_data;
    assign samp_sof  = samp_rd_data[12];
    assign samp_data = samp_rd_data[11:0];
    cdc_sample_fifo #(.W(13), .AW(6), .REG_FULL(1)) u_sfifo (
        .wr_clk(clk_rx), .wr_rst(rst_rx), .wr_en(fifo_wr), .wr_data(fifo_wdata), .wr_full(fifo_wr_full),
        .rd_clk(clk_dsp), .rd_rst(rst_dsp), .rd_en(samp_pop), .rd_data(samp_rd_data),
        .rd_valid(samp_valid), .rd_empty()
    );
    cdc_sample_fifo #(.W(48), .AW(4)) u_ififo (
        .wr_clk(clk_rx), .wr_rst(rst_rx), .wr_en(idx_send), .wr_data(idx_send_data), .wr_full(),
        .rd_clk(clk_dsp), .rd_rst(rst_dsp), .rd_en(idx_pop), .rd_data(idx_data),
        .rd_valid(idx_valid), .rd_empty()
    );

endmodule
