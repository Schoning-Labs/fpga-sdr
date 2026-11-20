// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Synthetic read traffic source, a stand-in for one of the real readers (the audio ring reader, the TX ring
// reader, or any background reader) on a client port of rtl/ddr3/ddr3_read_arbiter.v. It is a helper for
// the arbiter testbenches in this folder and is not a testbench itself, and it models the amount and timing
// of the traffic and not its content.
//
// Every PERIOD_CYCLES clocks it raises `req` for one burst of BURSTLEN words and reads a ring of RING_WORDS
// words that starts at BASE_ADDR, moving the start address on by one burst each time and wrapping at the end
// of the ring. The average bandwidth one instance stands for is therefore BURSTLEN words * 8 bytes per
// PERIOD_CYCLES clocks, for example 1 word every 4167 clocks at 100 MHz is about 0.192 MB/s, the figure
// docs/F4_DDR.md section 3 uses for an audio or TX ring. With PERIOD_CYCLES at 1 the client is saturating and
// always has the next burst ready, which is how the priority tests keep a lane permanently busy.
//
// The data that comes back is not checked here, the testbench that needs a data check
// (sim/ddr3/tb_ddr3_read_arbiter.v) does it on the arbiter's own `rvalid` and `rdata` signals. The client
// only counts words and bursts and measures `max_wait_cycles`, the longest time between raising `req` and
// being granted, which is the arbitration latency the tests report.

`timescale 1ns / 1ps

module read_traffic_client #(
    parameter integer ADDR_WIDTH    = 32,
    parameter integer BASE_ADDR     = 0,
    parameter integer RING_WORDS    = 4096,  // must be a power of 2
    parameter integer BURSTLEN      = 1,     // 1-255 (MUG1031 burstcount is an 8-bit field)
    parameter integer PERIOD_CYCLES = 100    // clocks between the start of consecutive bursts
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

    output reg  [63:0]             words_done,
    output reg  [31:0]             bursts_done,
    // longest wait, in clocks, from `req` going high to the matching `gnt`, which is the worst
    // arbitration latency this client has seen
    output reg  [31:0]             max_wait_cycles
);

    assign burstlen = BURSTLEN[7:0];

    // Two states: counting the gap to the next burst, or having a request open until `done`.
    localparam WAIT = 1'b0, REQ = 1'b1;
    reg state;
    reg [31:0] cycle_cnt;
    reg [31:0] wait_cnt;
    reg        waiting_for_gnt;

    // State machine. `waiting_for_gnt` and `wait_cnt` run alongside it and time how long each request waits
    // for its grant.
    always @(posedge clk) begin
        if (rst) begin
            state           <= WAIT;
            cycle_cnt       <= 32'd0;
            req             <= 1'b0;
            addr            <= BASE_ADDR[ADDR_WIDTH-1:0];
            words_done      <= 64'd0;
            bursts_done     <= 32'd0;
            max_wait_cycles <= 32'd0;
            wait_cnt        <= 32'd0;
            waiting_for_gnt <= 1'b0;
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
                // Gap between bursts: after PERIOD_CYCLES clocks raise `req` and start timing the wait.
                WAIT: begin
                    if (cycle_cnt + 1 >= PERIOD_CYCLES) begin
                        cycle_cnt       <= 32'd0;
                        req             <= 1'b1;
                        state           <= REQ;
                        waiting_for_gnt <= 1'b1;
                        wait_cnt        <= 32'd0;
                    end else begin
                        cycle_cnt <= cycle_cnt + 1'b1;
                    end
                end
                // Request open: count every data beat that arrives, and on `done` move the start address
                // on by one burst (wrapped to the ring, which works because RING_WORDS is a power of 2).
                REQ: begin
                    if (rvalid) words_done <= words_done + 64'd1;
                    if (done) begin
                        bursts_done <= bursts_done + 1'b1;
                        addr <= BASE_ADDR[ADDR_WIDTH-1:0] +
                                (((addr - BASE_ADDR[ADDR_WIDTH-1:0]) + BURSTLEN) &
                                 (RING_WORDS - 1));
                        if (PERIOD_CYCLES <= 1) begin
                            // Saturating: go straight into the next burst without ever dropping `req`.
                            // A gap, even of one clock, would let a lower-priority client win the idle
                            // lane and run its whole burst to the end (the arbiter never pre-empts a
                            // burst), which would make a strict-priority saturation check look wrong.
                            // The video model in sim/ddr3/video_scanout_model.v keeps a real gap between
                            // bursts on purpose, because that turnaround is a true cost the video test
                            // has to see (docs/F4_DDR.md section 2).
                            waiting_for_gnt <= 1'b1;
                            wait_cnt        <= 32'd0;
                        end else begin
                            req   <= 1'b0;
                            state <= WAIT;
                        end
                    end
                end
            endcase
        end
    end

endmodule
