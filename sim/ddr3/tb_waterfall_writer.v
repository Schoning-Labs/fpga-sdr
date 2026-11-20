// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Testbench for rtl/video/waterfall_writer.v, the block that takes the stream of colour index bytes the
// spectrum pipeline produces (one byte per pixel column of a waterfall line) and appends it, line after line,
// to a ring of lines in DDR3, where the compositor later reads it for the screen. The writer packs 8 bytes
// into one 64-bit lane word, buffers the words in a small FIFO and sends them to the write lane in bursts of
// 8 words, 30 bursts for one line of 1,920 bytes (240 words).
//
// The writer is connected directly to the write lane of sim/ddr3/ddr3_lane_behav_model.v without an
// arbiter in between, because the test is about the writer's own byte packing, addressing and ring
// wraparound, and the arbiter has its own tests in this folder. The lane model injects random stalls (4
// percent of idle clocks, runs of up to 5 clocks), so the writer's backpressure (`in_ready` going low)
// gets exercised too.
//
// Stimulus: RING_LINES + 2 lines are sent, each line is 1,920 bytes with a known pattern, byte number
// `col` of line `n` is `(n * 16 + col) mod 256`. The ring is only RING_LINES (4) lines long on purpose,
// so 6 lines make the write position pass the end of the ring and the later lines overwrite the first ones.
//
// Checks, after every line: (1) `write_line_ptr`, the index of the last fully written line, has reached the
// ring slot of the line just sent, so it advances by one per line and wraps; (2) every byte of the line reads
// back from the lane model's memory at the right ring address, in the byte order the writer promises (the
// first byte received sits in the most significant byte of the word, bits [63:56]). Because the check runs
// right after each line, the lines that land on a slot already used before show that the wrap overwrites the
// old line at the correct address.
//
// Passing: the last line is "PASS", otherwise "FAIL: ..." lines and "FAIL: <n> error(s)" are printed, or
// "FAIL: timeout" after 5 ms of simulated time. Run it from the repository root, the include paths are
// relative to it:
//   iverilog -g2012 -o sim/out/tb_waterfall_writer.vvp sim/ddr3/tb_waterfall_writer.v && vvp -n sim/out/tb_waterfall_writer.vvp
// or all testbenches together with tools/check.sh. Terms such as burst and ring are explained in
// docs/learn/GLOSSARY.md.

`timescale 1ns / 1ps
`include "rtl/video/waterfall_writer.v"
`include "sim/ddr3/ddr3_lane_behav_model.v"

module tb_waterfall_writer;

    localparam integer ADDR_WIDTH = 32;
    localparam integer DATA_WIDTH = 64;
    // A line is 1,920 bytes, the width of the 1080p screen, so 1,920 / 8 = 240 lane words.
    localparam integer LINE_BYTES = 1920;
    localparam integer RING_LINES = 4;    // small on purpose, to exercise wraparound quickly
    localparam integer WORDS_PER_LINE = LINE_BYTES / 8;

    reg clk = 0;
    reg rst = 1;
    always #5 clk = ~clk;

    // Byte stream input of the writer, driven by `send_line`.
    reg        in_valid;
    reg [7:0]  in_data;
    wire       in_ready;
    reg [ADDR_WIDTH-1:0] ring_base;
    wire [1:0] write_line_ptr; // $clog2(4) = 2 bits

    wire req;
    wire [ADDR_WIDTH-1:0] addr;
    wire [7:0] burstlen;
    wire [DATA_WIDTH-1:0] wdata;
    wire [7:0] wmask;
    wire gnt, done;

    waterfall_writer #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH),
                        .LINE_BYTES(LINE_BYTES), .RING_LINES(RING_LINES), .FIFO_WORDS(64)) dut (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .in_data(in_data), .in_ready(in_ready),
        .ring_base(ring_base), .write_line_ptr(write_line_ptr),
        .req(req), .addr(addr), .burstlen(burstlen), .wdata(wdata), .wmask(wmask),
        .gnt(gnt), .done(done));

    // The writer's request port is connected straight to the lane model's write side, the arbiter's job is
    // not part of this test. `req` stays high through the clock on which `wr_done` pulses (the writer only drops
    // it one clock later, when it sees `done`), so `wr_en` has to be gated with `!wr_done`, as
    // rtl/ddr3/ddr3_write_arbiter.v does for the same reason, or the lane accepts one extra beat at the
    // address of the burst that just finished.
    wire wr_wait, wr_done;
    wire wr_en = req && !wr_done;
    assign gnt  = wr_en && !wr_wait;
    assign done = wr_done;

    ddr3_lane_behav_model #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH), .MEM_WORDS(4096),
                             .STALL_NUM(40), .STALL_DEN(1000), .STALL_MAX_CYCLES(5),
                             .SEED(32'h5EED_0001)) u_lane (
        .clk(clk), .rst(rst),
        .addr_lane4(addr), .wr_mask_lane4(wmask), .wr_data_lane4(wdata),
        .wr_en_lane4(wr_en), .wr_go_lane4(1'b0), .burstcount_lane4(burstlen),
        .wr_wait_lane4(wr_wait), .wr_done_lane4(wr_done),
        .addr_lane5(32'd0), .rd_en_lane5(1'b0), .rd_go_lane5(1'b0), .burstcount_lane5(8'd0),
        .rd_valid_lane5(), .rd_data_lane5(), .rd_rdy_lane5(), .phys_busy());

    // Loop counters, the expected byte and the word being checked.
    integer errors, line, col;
    reg [7:0] expect_byte;
    reg [DATA_WIDTH-1:0] word;
    integer word_idx, byte_in_word;
    reg [ADDR_WIDTH-1:0] a;

    // Sends one line, one byte per clock whenever the writer is ready.
    task send_line(input integer line_num);
        begin
            for (col = 0; col < LINE_BYTES; col = col + 1) begin
                in_data  = (line_num * 8'h10 + col) & 8'hFF;
                in_valid = 1'b1;
                @(posedge clk);
                #1; // let this edge's updates, `in_ready` among them, settle before the next iteration
                    // changes `in_data`, otherwise the change races the writer's own sample of the current
                    // byte on the same edge and some simulators lose bytes. The same wait is used wherever
                    // a handshake like this is driven in this folder.
                while (!in_ready) begin
                    @(posedge clk);
                    #1;
                end
            end
            in_valid = 1'b0;
        end
    endtask

    // Compares the whole line in its ring slot with the pattern: word by word, byte by byte.
    task check_line(input integer line_num, input integer ring_slot);
        begin
            for (word_idx = 0; word_idx < WORDS_PER_LINE; word_idx = word_idx + 1) begin
                a = ring_base + ring_slot * WORDS_PER_LINE + word_idx;
                word = u_lane.peek(a);
                for (byte_in_word = 0; byte_in_word < 8; byte_in_word = byte_in_word + 1) begin
                    col = word_idx * 8 + byte_in_word;
                    expect_byte = (line_num * 8'h10 + col) & 8'hFF;
                    // packer byte order: the first byte received is the word's most significant byte, so
                    // byte 0 of a word is bits [63:56]
                    if (word[(7 - byte_in_word)*8 +: 8] !== expect_byte) begin
                        $display("FAIL: line %0d col %0d (word %0h) got %02h expected %02h",
                                  line_num, col, a, word[(7 - byte_in_word)*8 +: 8], expect_byte);
                        errors = errors + 1;
                    end
                end
            end
        end
    endtask

    initial begin
        errors = 0;
        in_valid = 0;
        ring_base = 32'h0000_0000;
        rst = 1;
        repeat (5) @(posedge clk);
        rst = 0;

        // Send RING_LINES + 2 lines, which is one and a half times around the ring, so the ring wraps and the
        // first two lines get overwritten.
        // Write RING_LINES + 2 lines (2 full wraps' worth) so the ring wraps and overwrites.
        for (line = 0; line < RING_LINES + 2; line = line + 1) begin
            send_line(line);
        // Wait for the line's last burst to land, which is when `write_line_ptr` has reached this line.
            // wait for the line's last burst to actually land (write_line_ptr catches up)
            while (write_line_ptr !== ((line % RING_LINES))) @(posedge clk);
            if (write_line_ptr !== (line % RING_LINES)) begin
                $display("FAIL: after line %0d, write_line_ptr = %0d, expected %0d",
                          line, write_line_ptr, line % RING_LINES);
                errors = errors + 1;
            end
        // Check the line at its ring slot, for the lines that wrapped this is the old slot with new data.
            check_line(line, line % RING_LINES);
        end

        repeat (20) @(posedge clk);

        if (errors == 0) begin
            $display("PASS");
        end else begin
            $display("FAIL: %0d error(s)", errors);
        end
        $finish;
    end

    initial begin
        #5_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule
