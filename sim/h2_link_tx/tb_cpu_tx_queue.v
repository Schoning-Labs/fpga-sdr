// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Unit test for rtl/hl2link/cpu_tx_queue.v, the 4 KB buffer in which firmware assembles one Ethernet frame (destination
// MAC to the last payload byte, without the FCS) before hardware sends it out one byte per clock. tb_h2_link_tx.v does
// not exercise it, since it ties `cq_wr_en` low and only the sample framer sends there.
//
// Stimulus: three frames are written through the firmware port back to back, of 20, 35 and 1 bytes, each byte
// being the frame's first byte plus its position, and then a pulse on `send_len_wr` with the length queues the frame.
// A model of the arbiter grants the wire as soon as the queue asks for it. The frame lengths are chosen so that the
// second frame catches a drain address that is reset at the wrong edge (it would repeat the last address of the first
// frame for one clock), and the one byte frame takes the short path from ST_PRIME straight to ST_IDLE without ever
// entering ST_DRAIN.
//
// Pass: each frame comes out byte-exact with the right length (captured while `tx_enable_content` is high, which
// also proves there was no gap inside the frame) and `busy` is low after the last one. It prints "PASS", or
// "FAIL: n errors" after the individual ERROR lines.
//
// Run, from the repo root (the include path is relative to it):
//   iverilog -g2012 -o build/tb_cpu_tx_queue.vvp sim/h2_link_tx/tb_cpu_tx_queue.v && vvp build/tb_cpu_tx_queue.vvp

`include "rtl/hl2link/cpu_tx_queue.v"

`timescale 1ns / 1ps

module tb_cpu_tx_queue;

    // 125 MHz transmit clock (half period 4 ns).
    logic clk_tx = 1'b0;
    always #4 clk_tx = ~clk_tx;

    logic        rst_tx = 1'b1;
    logic        wr_en = 1'b0;
    logic [11:0] wr_addr = 12'd0;
    logic [7:0]  wr_data = 8'd0;
    logic        send_len_wr = 1'b0;
    logic [15:0] wr_len_in = 16'd0;
    wire         busy;

    logic        gnt = 1'b0;
    wire         req;
    wire [7:0]   tx_data;
    wire         tx_enable_content;
    wire [31:0]  cnt_tx_frames;

    cpu_tx_queue #(.AW(12)) dut (
        .clk_tx(clk_tx), .rst_tx(rst_tx),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .send_len_wr(send_len_wr), .wr_len_in(wr_len_in), .busy(busy),
        .req(req), .gnt(gnt),
        .tx_data(tx_data), .tx_enable_content(tx_enable_content),
        .cnt_tx_frames(cnt_tx_frames)
    );

    integer errors = 0;
    `define CHECK(cond, msg) if ((cond) !== 1'b1) begin errors = errors + 1; $display("ERROR t=%0t: %s", $time, msg); end

    // Firmware's side: writes `len` bytes (byte i is first_byte + i) to consecutive addresses, one per clock, and then pulses
    // `send_len_wr` for one clock with the length.
    task automatic write_frame(input [15:0] len, input [7:0] first_byte);
        integer i;
        begin
            @(posedge clk_tx);
            for (i = 0; i < len; i = i + 1) begin
                wr_en   <= 1'b1;
                wr_addr <= i[11:0];
                wr_data <= first_byte + i[7:0];
                @(posedge clk_tx);
            end
            wr_en       <= 1'b0;
            send_len_wr <= 1'b1;
            wr_len_in   <= len;
            @(posedge clk_tx);
            send_len_wr <= 1'b0;
        end
    endtask

    // The arbiter's side: grants as soon as the queue requests, as the real arbiter does when the sample framer is not also
    // asking for the wire.
    always @(posedge clk_tx) gnt <= req && !gnt;

    // Captures the frame as it streams out. `got_len` is the byte count including this clock's byte (if any). A single
    // non-blocking write to it handles both the first byte of a new frame and the next byte of one in progress, through
    // `next_idx`, which is computed from the state going into the clock edge.
    reg [7:0] got [0:4095];
    integer   got_len   = 0;
    reg       capturing = 1'b0;
    wire [31:0] next_idx = (tx_enable_content && !capturing) ? 32'd0 : got_len;

    always @(posedge clk_tx) begin
        if (tx_enable_content) begin
            got[next_idx] <= tx_data;
            got_len       <= next_idx + 32'd1;
            capturing     <= 1'b1;
        end else begin
            capturing <= 1'b0;
        end
    end

    // Waits until the frame counter says that frame number `label` has been sent, then compares its length and every byte
    // with what was written.
    task automatic check_frame(input [15:0] expect_len, input [7:0] first_byte, input [63:0] label);
        integer i;
        begin
            while (cnt_tx_frames != label[31:0]) @(posedge clk_tx);
            @(negedge clk_tx);
            `CHECK(got_len == expect_len, $sformatf("frame %0d: length %0d, expected %0d", label, got_len, expect_len))
            for (i = 0; i < expect_len; i = i + 1)
                `CHECK(got[i] == (first_byte + i[7:0]),
                       $sformatf("frame %0d byte %0d: got %h expected %h", label, i, got[i], first_byte + i[7:0]))
        end
    endtask

    initial begin
        // Start of reset, released at 17 ns so that it does not coincide with a clock edge.
        #17;
        rst_tx = 1'b0;
        #20;

        // First frame, 20 bytes starting at 0x00.
        write_frame(16'd20, 8'h00);
        check_frame(16'd20, 8'h00, 64'd1);

        // A second frame of a different size right after: this exercises the drain address reset at the write edge. If it
        // were reset at the grant edge instead, this frame's first byte would repeat the last address of the previous frame.
        write_frame(16'd35, 8'h40);
        check_frame(16'd35, 8'h40, 64'd2);

        // A short frame of 1 byte: this takes the direct path from ST_PRIME to ST_IDLE (frame length 1) and never
        // enters ST_DRAIN.
        write_frame(16'd1, 8'ha5);
        check_frame(16'd1, 8'ha5, 64'd3);

        #40;
        `CHECK(!busy, "queue still busy after its last frame finished")

        if (errors == 0) $display("PASS");
        else $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule
