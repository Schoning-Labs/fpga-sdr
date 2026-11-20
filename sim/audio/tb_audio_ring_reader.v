// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Testbench for rtl/audio/audio_ring_reader.v, the block that reads the audio ring buffer in DDR3 and turns
// it into a 48 kHz stereo sample stream. In the radio the firmware writes 16-bit left and right samples into
// that ring and moves a write pointer, the reader fetches one word (one stereo pair) at a time, keeps a
// small prefetch FIFO so the delay of a DDR3 read never reaches the real-time consumer, and hands each
// sample to the interpolator (rtl/audio/audio_interp_x8.v) and, as a copy on a second port, to the HDMI
// audio path. See docs/learn/GLOSSARY.md for ring buffer, FIFO and valid/ready.
//
// Stimulus: a process in the testbench plays the firmware. It writes 200 distinct sample pairs into
// sim/audio/ddr3_behav_model.v (a 3-clock-latency memory) through a ring that is only 16 words deep, so the
// ring wraps more than 12 times, and it advances `wr_ptr` only while the ring has a free slot
// (`wr_ptr - rd_ptr` below the ring size), which is the rule real firmware must also follow so it never
// overwrites a word the reader has not fetched. The consumer is greedy (`smp_ready` follows `smp_valid`),
// so it takes every sample the moment it is offered. The samples are `L = i*101 - 5000` and
// `R = -(i*57) + 2000`, two different slopes that stay inside the 16-bit range for i up to 199, so a swapped
// channel, a repeated or a skipped sample all show up as a mismatch.
//
// Checks: both output ports, the main 48 kHz stream and the HDMI tap, must deliver all 200 samples in order
// and unchanged. The fixed wait of 20 clocks lets reset finish first.
//
// Passing: "PASS" is printed, otherwise one "FAIL:" line per wrong sample and "FAIL: <n> mismatch(es)", or
// "FAIL: timeout" after 2 ms of simulated time. Run it from the repository root, the include paths are
// relative to it:
//   iverilog -g2012 -o sim/out/tb_audio_ring_reader.vvp sim/audio/tb_audio_ring_reader.v && vvp -n sim/out/tb_audio_ring_reader.vvp
// or all testbenches together with tools/check.sh.

`timescale 1ns / 1ps
`include "rtl/audio/audio_ring_reader.v"
`include "sim/audio/ddr3_behav_model.v"

module tb_audio_ring_reader;

    // 120 MHz is the DSP clock (docs/ARCHITECTURE.md section 2), the clock the reader runs on in the radio.
    localparam integer CLK_HZ = 120_000_000;
    localparam real    CLK_PERIOD_NS = 1.0e9 / CLK_HZ;

    reg clk = 0;
    always #(CLK_PERIOD_NS / 2.0) clk = ~clk;
    reg rst = 1;

    // A ring of 16 words and a prefetch FIFO of 4 are small on purpose, so the ring wraps often and the
    // FIFO runs close to full and empty. The ring starts at word address 0x100.
    localparam integer ADDR_WIDTH      = 32;
    localparam integer RING_SIZE_WORDS = 16;
    localparam integer FIFO_DEPTH      = 4;
    localparam [ADDR_WIDTH-1:0] RING_BASE = 32'h100;

    // Pointers: `wr_ptr` is the firmware's write position, `rd_ptr` the reader's own position. Both are
    // free-running word counters, only masked to the ring size when an address is formed.
    reg  [ADDR_WIDTH-1:0] wr_ptr;
    wire [ADDR_WIDTH-1:0] rd_ptr;

    wire                  mem_req;
    wire [ADDR_WIDTH-1:0] mem_addr;
    wire                  mem_rvalid;
    wire [31:0]           mem_rdata;

    wire                  smp_valid;
    wire signed [15:0]    smp_l, smp_r;
    wire                  smp_ready = smp_valid; // greedy consumer

    wire                  hdmi_valid;
    wire signed [15:0]    hdmi_l, hdmi_r;
    wire                  ring_empty, low_water;

    audio_ring_reader #(
        .ADDR_WIDTH     (ADDR_WIDTH),
        .RING_SIZE_WORDS(RING_SIZE_WORDS),
        .FIFO_DEPTH     (FIFO_DEPTH)
    ) dut (
        .clk       (clk),
        .rst       (rst),
        .ring_base (RING_BASE),
        .wr_ptr    (wr_ptr),
        .rd_ptr    (rd_ptr),
        .mem_req   (mem_req),
        .mem_addr  (mem_addr),
        .mem_rvalid(mem_rvalid),
        .mem_rdata (mem_rdata),
        .smp_valid (smp_valid),
        .smp_l     (smp_l),
        .smp_r     (smp_r),
        .smp_ready (smp_ready),
        .hdmi_valid(hdmi_valid),
        .hdmi_l    (hdmi_l),
        .hdmi_r    (hdmi_r),
        .ring_empty(ring_empty),
        .low_water (low_water)
    );

    // The memory model answers a read request 3 clocks after it is made.
    ddr3_behav_model #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .MEM_WORDS (1024),
        .LATENCY   (3)
    ) mem_model (
        .clk       (clk),
        .rst       (rst),
        .mem_req   (mem_req),
        .mem_addr  (mem_addr),
        .mem_rvalid(mem_rvalid),
        .mem_rdata (mem_rdata)
    );

    // ---------------------------------------------------------------- expected data + producer
    localparam integer NSAMP = 200; // >> RING_SIZE_WORDS, so the ring wraps many times
    reg signed [15:0] exp_l [0:NSAMP-1];
    reg signed [15:0] exp_r [0:NSAMP-1];
    integer i;
    // Expected samples, filled once at the start.
    initial begin
        for (i = 0; i < NSAMP; i = i + 1) begin
            exp_l[i] = i * 101 - 5000;
            exp_r[i] = -(i * 57) + 2000;
        end
    end

    // The simulated firmware: whenever there is a sample left to send and the ring has a free slot, write
    // the next sample into the memory (the `poke` back door stands for the CPU's cache write-back) and
    // move `wr_ptr` on by one.
    integer words_written;
    always @(posedge clk) begin
        if (rst) begin
            wr_ptr         <= {ADDR_WIDTH{1'b0}};
            words_written  <= 0;
        end else if (words_written < NSAMP &&
                     (wr_ptr - rd_ptr) < RING_SIZE_WORDS[ADDR_WIDTH-1:0]) begin
            mem_model.poke(RING_BASE + (wr_ptr & (RING_SIZE_WORDS - 1)),
                           {exp_l[words_written], exp_r[words_written]});
            wr_ptr        <= wr_ptr + 1'b1;
            words_written <= words_written + 1;
        end
    end

    // ---------------------------------------------------------------- capture both output ports
    reg signed [15:0] got_l      [0:NSAMP-1];
    reg signed [15:0] got_r      [0:NSAMP-1];
    reg signed [15:0] got_hdmi_l [0:NSAMP-1];
    reg signed [15:0] got_hdmi_r [0:NSAMP-1];
    integer got_count, hdmi_count;

    // Record every sample that comes out of each port, together with its position in the stream.
    always @(posedge clk) begin
        if (rst) begin
            got_count  <= 0;
            hdmi_count <= 0;
        end else begin
            if (smp_valid && smp_ready && got_count < NSAMP) begin
                got_l[got_count] <= smp_l;
                got_r[got_count] <= smp_r;
                got_count        <= got_count + 1;
            end
            if (hdmi_valid && hdmi_count < NSAMP) begin
                got_hdmi_l[hdmi_count] <= hdmi_l;
                got_hdmi_r[hdmi_count] <= hdmi_r;
                hdmi_count              <= hdmi_count + 1;
            end
        end
    end

    // ---------------------------------------------------------------- scoreboard
    integer errors;
    initial begin
        // Release reset after 20 clocks, then wait until both ports have delivered all samples.
        #(20 * CLK_PERIOD_NS);
        rst = 0;
        wait (got_count >= NSAMP && hdmi_count >= NSAMP);
        #(5 * CLK_PERIOD_NS);

        errors = 0;
        // Compare every sample, main port first and HDMI tap second.
        for (i = 0; i < NSAMP; i = i + 1) begin
            if (got_l[i] !== exp_l[i] || got_r[i] !== exp_r[i]) begin
                $display("FAIL: sample %0d main port: expected L=%0d R=%0d got L=%0d R=%0d",
                          i, exp_l[i], exp_r[i], got_l[i], got_r[i]);
                errors = errors + 1;
            end
            if (got_hdmi_l[i] !== exp_l[i] || got_hdmi_r[i] !== exp_r[i]) begin
                $display("FAIL: sample %0d hdmi port: expected L=%0d R=%0d got L=%0d R=%0d",
                          i, exp_l[i], exp_r[i], got_hdmi_l[i], got_hdmi_r[i]);
                errors = errors + 1;
            end
        end

        if (errors == 0)
            $display("PASS");
        else
            $display("FAIL: %0d mismatch(es)", errors);
        $finish;
    end

    // Safety net: 2 ms of simulated time, far more than 200 samples through a 3-clock memory need.
    initial begin
        #(2_000_000);
        $display("FAIL: timeout, got_count=%0d hdmi_count=%0d (expected %0d)",
                  got_count, hdmi_count, NSAMP);
        $finish;
    end

endmodule
