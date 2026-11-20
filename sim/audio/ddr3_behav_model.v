// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Behavioral stand-in for DDR3 on the generic memory port of rtl/audio/audio_ring_reader.v. It is used only
// in simulation (it cannot be turned into hardware) and is a plain word-addressable memory of 32-bit words
// that answers each read request after a fixed number of clocks (LATENCY), which is all that reader needs
// from the real memory path. The audio ring reader's port is deliberately generic, a request with an
// address and later a valid strobe with the data, so this model does not have to follow the burst
// protocol of the real DDR3 lane that sim/ddr3/ddr3_lane_behav_model.v models.
//
// Simplifications compared with the real part: there is no arbitration against other clients, no bursts,
// no refresh and no stalls, a request is answered LATENCY clocks later every time, and the model would
// even accept a new request on every clock (the reader itself keeps only one outstanding).
//
// A testbench loads the memory with the `poke` task, a plain procedural write that stands for the firmware
// writing samples into the ring, which in the real system is done by the CPU and not by this model's port.

`timescale 1ns / 1ps

module ddr3_behav_model #(
    // Number of 32-bit words in the memory, and the clocks from a request to the matching `mem_rvalid`.
    parameter integer ADDR_WIDTH = 32,
    parameter integer MEM_WORDS  = 4096,
    parameter integer LATENCY    = 3      // clocks from mem_req to mem_rvalid, >= 1
) (
    input  wire                  clk,
    input  wire                  rst,
    input  wire                  mem_req,
    input  wire [ADDR_WIDTH-1:0] mem_addr,
    output reg                   mem_rvalid,
    output reg  [31:0]           mem_rdata
);

    localparam integer WORD_BITS = $clog2(MEM_WORDS);

    // The memory itself, one stereo sample ({left, right}, 16 bits each) per word.
    reg [31:0] mem [0:MEM_WORDS-1];

    // The requests in flight: a small shift register, one stage per clock of latency, that carries each
    // request's valid flag and address along until its data is due.
    reg                  pend_v [0:LATENCY-1];
    reg [ADDR_WIDTH-1:0] pend_a [0:LATENCY-1];
    integer i;

    // Every clock the requests move one stage on. The memory is read when a request leaves the last stage,
    // and `mem_rvalid` goes high on the same clock as `mem_rdata`, which makes LATENCY clocks from the
    // clock that sampled `mem_req` to the clock that shows the data.
    always @(posedge clk) begin
        if (rst) begin
            mem_rvalid <= 1'b0;
            mem_rdata  <= 32'd0;
            for (i = 0; i < LATENCY; i = i + 1) begin
                pend_v[i] <= 1'b0;
                pend_a[i] <= {ADDR_WIDTH{1'b0}};
            end
        end else begin
            pend_v[0] <= mem_req;
            pend_a[0] <= mem_addr;
            for (i = 1; i < LATENCY; i = i + 1) begin
                pend_v[i] <= pend_v[i-1];
                pend_a[i] <= pend_a[i-1];
            end
            mem_rvalid <= pend_v[LATENCY-1];
            mem_rdata  <= mem[pend_a[LATENCY-1][WORD_BITS-1:0]];
        end
    end

    // Testbench back door: write one word straight into the memory, without a clock.
    task poke(input [ADDR_WIDTH-1:0] addr, input [31:0] data);
        begin
            mem[addr[WORD_BITS-1:0]] = data;
        end
    endtask

endmodule
