// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Video scan-out traffic model, the stand-in for the read side of the compositor (rtl/video/compositor.v)
// on the video client port of rtl/ddr3/ddr3_read_arbiter.v. It is a helper for
// sim/ddr3/tb_ddr3_video_no_starve.v and models only how much data the display needs and when, not what
// the pixels are.
//
// What the real compositor needs: for every video line one line of the framebuffer the GUI draws into
// (1,920 pixels of RGB565 at 2 bytes = 3,840 bytes = 480 lane words of 8 bytes) and, while a waterfall
// window is on screen, one line of waterfall colour indices (1,920 bytes = 240 lane words). This model
// merges both into one demand of LINE_WORDS (720) words per line, which is the 1080p60 worst case with a
// full-screen waterfall (docs/ARCHITECTURE.md 3.5 and 3.9). A pixel clock of 148.5 MHz with 2,200 clocks
// per line gives a line time of 14.8 us, which is 1,481 clocks of the 100 MHz lane clock, and 720 words
// of 8 bytes in that time is 389 MB/s. The documented 373 MB/s is lower because it averages over the 1,080
// visible lines of the 1,125 in a frame, while the model also drains during the blanking lines, so it is
// slightly more demanding than the real thing.
//
// How it works: the display drains a prefetch FIFO at a steady rate, and the model asks the arbiter for the
// next burst of BURSTLEN words whenever the FIFO has room for all of it. `fifo_fill` is the number of words
// buffered ahead right now, `min_fifo_fill` is the lowest it has been since reset, which is the margin the
// testbench reports, and `underrun_events` counts every time the display wanted a word and the FIFO was
// empty, which has to stay at zero. The two real streams (framebuffer and waterfall) have a FIFO each in
// the compositor, and this model has one combined FIFO for both, a conservative simplification because a
// shortfall in either real stream shows up here as a drop in the combined fill (docs/F4_DDR.md section 2).
// It does not claim the real hardware shares one buffer.
//
// The drain is a rate accumulator (the same idea as a numerically controlled oscillator, see
// docs/learn/GLOSSARY.md): LINE_WORDS is added to an accumulator every clock and every time it passes
// LINE_PERIOD_CYCLES one word is removed from the FIFO, so exactly LINE_WORDS words leave per line, evenly
// spread, and the model never has to follow individual pixels.

`timescale 1ns / 1ps

module video_scanout_model #(
    parameter integer ADDR_WIDTH        = 32,
    parameter integer BASE_ADDR         = 0,
    parameter integer RING_WORDS        = 65536,
    // The burst length matters a great deal here. MUG1031 table 5-1 gives `burstcount_lane5` as an 8-bit
    // field, values up to 255, so a burst is not limited to 8 words. Every burst pays the lane model's
    // RD_LATENCY (pipeline fill) again, because bursts cannot be pre-empted and this model keeps only one
    // request outstanding. With 8-word bursts that fixed cost is spread over only 8 useful beats and the
    // video reader needs almost the whole lane just to keep up with itself, before any other client or any
    // stall is counted (docs/F4_DDR.md section 2 has the arithmetic). 180 words per burst, which is a
    // quarter of a 720-word line, spreads the same cost over more than 20 times as much data.
    parameter integer BURSTLEN          = 180,
    parameter integer LINE_WORDS        = 720,   // Slint (480) + waterfall (240) lane words/line
    parameter integer LINE_PERIOD_CYCLES = 1481, // 1080p60 line period at the 100 MHz lane clock
    parameter integer FIFO_DEPTH_LINES  = 2      // docs/ARCHITECTURE.md 3.9's prefetch sizing
) (
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    enable,

    output reg                     req,
    output reg  [ADDR_WIDTH-1:0]   addr,
    output wire [7:0]              burstlen,
    input  wire                    gnt,
    input  wire                    rvalid,
    input  wire                    done,

    output reg  signed [31:0]      fifo_fill,        // words currently buffered ahead
    output reg  signed [31:0]      min_fifo_fill,     // worst (lowest) fifo_fill seen
    output reg  [31:0]             underrun_events,
    output reg  [63:0]             words_done,
    output reg  [31:0]             max_wait_cycles
);

    // The FIFO holds FIFO_DEPTH_LINES whole lines of prefetched data.
    localparam integer FIFO_CAPACITY = LINE_WORDS * FIFO_DEPTH_LINES;

    assign burstlen = BURSTLEN[7:0];

    // ---------------- fill side: request bursts while there is room ----------------
    localparam WAIT = 1'b0, REQ = 1'b1;
    reg state;
    reg        waiting_for_gnt;
    reg [31:0] wait_cnt;

    // Room for a whole burst, the request is only made when all BURSTLEN words fit.
    wire room = (fifo_fill + BURSTLEN) <= FIFO_CAPACITY;

    // Fill side state machine: WAIT until there is room, then keep `req` high until `done`, count the arriving
    // words, and move the start address on by one burst (wrapped to the ring, RING_WORDS is a power of 2).
    // `waiting_for_gnt` and `wait_cnt` time each request for `max_wait_cycles`. Unlike the plain read
    // client there is always a gap after `done`, one clock at least, in which `req` is low.
    always @(posedge clk) begin
        if (rst) begin
            state           <= WAIT;
            req             <= 1'b0;
            addr            <= BASE_ADDR[ADDR_WIDTH-1:0];
            words_done      <= 64'd0;
            waiting_for_gnt <= 1'b0;
            wait_cnt        <= 32'd0;
            max_wait_cycles <= 32'd0;
        end else if (!enable) begin
            req <= 1'b0;
        end else begin
            if (waiting_for_gnt) begin
                if (gnt) begin
                    waiting_for_gnt <= 1'b0;
                    if (wait_cnt > max_wait_cycles) max_wait_cycles <= wait_cnt;
                end else begin
                    wait_cnt <= wait_cnt + 1'b1;
                end
            end
            case (state)
                WAIT: begin
                    if (room) begin
                        req             <= 1'b1;
                        state           <= REQ;
                        waiting_for_gnt <= 1'b1;
                        wait_cnt        <= 32'd0;
                    end
                end
                REQ: begin
                    if (rvalid) words_done <= words_done + 64'd1;
                    if (done) begin
                        req   <= 1'b0;
                        state <= WAIT;
                        addr  <= BASE_ADDR[ADDR_WIDTH-1:0] +
                                 (((addr - BASE_ADDR[ADDR_WIDTH-1:0]) + BURSTLEN) &
                                  (RING_WORDS - 1));
                    end
                end
            endcase
        end
    end

    // ---------------- drain side: NCO-style even drain of LINE_WORDS / LINE_PERIOD_CYCLES ----
    // `drain_acc` is the rate accumulator of the header.
    reg [31:0] drain_acc;
    // One word arrives on every `rvalid` pulse (one beat of an accepted burst).
    wire       fill_this_cycle = rvalid; // one word arrives per accepted read beat

    // The FIFO starts full because the compositor does not start before it is primed. A drain that
    // coincides with an arriving word cancels out, a drain on an empty FIFO with nothing arriving is
    // an underrun and does not make the fill negative.
    always @(posedge clk) begin
        if (rst) begin
            fifo_fill       <= FIFO_CAPACITY; // start full: compositor does not run until primed
            min_fifo_fill   <= FIFO_CAPACITY;
            underrun_events <= 32'd0;
            drain_acc       <= 32'd0;
        end else if (!enable) begin
            // frozen: no drain, no fill accounting, while the compositor is not running
        end else begin
            drain_acc <= drain_acc + LINE_WORDS;
            if (drain_acc >= LINE_PERIOD_CYCLES) begin
                drain_acc <= drain_acc + LINE_WORDS - LINE_PERIOD_CYCLES;
                if (fifo_fill == 0 && !fill_this_cycle) begin
                    underrun_events <= underrun_events + 1'b1;
                end else begin
                    fifo_fill <= fifo_fill + (fill_this_cycle ? 32'sd1 : 32'sd0) - 32'sd1;
                end
            end else if (fill_this_cycle) begin
                fifo_fill <= fifo_fill + 32'sd1;
            end
            if (fifo_fill < min_fifo_fill) min_fifo_fill <= fifo_fill;
        end
    end

endmodule
