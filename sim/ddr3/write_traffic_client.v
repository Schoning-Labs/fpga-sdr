// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Synthetic write traffic source, a stand-in for one of the real writers (the IQ writer behind the receiver
// bank, the waterfall writer, the raw capture writer) on a client port of rtl/ddr3/ddr3_write_arbiter.v. It
// is a helper for the arbiter testbenches in this folder and is not a testbench itself.
//
// Every PERIOD_CYCLES clocks it raises `req` for one burst of BURSTLEN words into a ring of RING_WORDS
// words that starts at BASE_ADDR, moves the start address on by one burst each time and wraps at the end
// of the ring. The bandwidth one instance stands for is BURSTLEN words * 8 bytes per PERIOD_CYCLES clocks
// at the 100 MHz lane clock, so a 4-word burst every 130 clocks is about 24.6 MB/s (the IQ writer figure
// in docs/F4_DDR.md section 3). With PERIOD_CYCLES at 1 the client is saturating and always has the next
// burst ready, which is how the priority tests keep a lane permanently busy.
//
// The data pattern is address derived, the word at address A is `{A, ~A}`. A checker can then recompute
// what any address ought to contain without keeping a shadow copy of the memory, which is what
// sim/ddr3/tb_ddr3_write_arbiter.v does in its readback check.

`timescale 1ns / 1ps

module write_traffic_client #(
    parameter integer ADDR_WIDTH    = 32,
    parameter integer DATA_WIDTH    = 64,
    parameter integer MASK_WIDTH    = DATA_WIDTH / 8,
    parameter integer BASE_ADDR     = 0,
    parameter integer RING_WORDS    = 4096,   // must be a power of 2
    parameter integer BURSTLEN      = 1,      // 1-255 (MUG1031 burstcount is an 8-bit field)
    parameter integer PERIOD_CYCLES = 100     // clocks between the start of consecutive bursts
) (
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    enable,

    output reg                     req,
    output reg  [ADDR_WIDTH-1:0]   addr,
    output wire [7:0]              burstlen,
    output wire [DATA_WIDTH-1:0]   wdata,
    output wire [MASK_WIDTH-1:0]   wmask,
    input  wire                    gnt,
    input  wire                    done,

    output reg  [63:0]             words_done,
    output reg  [31:0]             bursts_done,
    // longest wait, in clocks, from `req` going high to the `gnt` for the first beat of a burst, which is
    // the worst arbitration latency this client has seen (docs/F4_DDR.md section 4)
    output reg  [31:0]             max_wait_cycles
);

    localparam integer RING_BITS = $clog2(RING_WORDS);

    assign burstlen = BURSTLEN[7:0];
    assign wmask    = {MASK_WIDTH{1'b1}};

    // Beat number inside the current burst, and the address of the beat being offered.
    reg [7:0] beat_idx;
    reg [ADDR_WIDTH-1:0] eff_addr;
    always @* eff_addr = addr + beat_idx;
    // The data on offer for the current beat, see the header for the pattern.
    assign wdata = {eff_addr, ~eff_addr};

    // Two states: counting the gap to the next burst, or having a request open until `done`.
    localparam WAIT = 1'b0, REQ = 1'b1;
    reg state;
    reg [31:0] cycle_cnt;
    reg [31:0] wait_cnt;
    reg        waiting_for_gnt;

    // State machine. `waiting_for_gnt` and `wait_cnt` run alongside it and time how long each request waits
    // for its first grant.
    always @(posedge clk) begin
        if (rst) begin
            state           <= WAIT;
            cycle_cnt       <= 32'd0;
            req             <= 1'b0;
            addr            <= BASE_ADDR[ADDR_WIDTH-1:0];
            beat_idx        <= 8'd0;
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
                        beat_idx        <= 8'd0;
                        state           <= REQ;
                        waiting_for_gnt <= 1'b1;
                        wait_cnt        <= 32'd0;
                    end else begin
                        cycle_cnt <= cycle_cnt + 1'b1;
                    end
                end
                // Request open: the arbiter pulses `gnt` once per accepted beat, so that is when to move
                // to the next beat. On `done` move the start address on by one burst (wrapped to the ring,
                // which works because RING_WORDS is a power of 2).
                REQ: begin
                    if (gnt) begin
                        beat_idx   <= beat_idx + 8'd1;
                        words_done <= words_done + 64'd1;
                    end
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
                            // The video model in sim/ddr3/video_scanout_model.v and the read client
                            // keep a real gap between bursts on purpose, because that turnaround is a
                            // true cost the video test has to see (docs/F4_DDR.md section 2).
                            beat_idx        <= 8'd0;
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
