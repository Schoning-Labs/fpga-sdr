// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Self checking test of cic_comb.
//
// The model is written from the arithmetic of a comb with a differential delay of one sample. At every clock edge where
// strobe is high, the output becomes input minus delay and the delay becomes the input, everything modulo 2^WIDTH, and a
// synchronous reset clears both registers and wins over strobe. The model is made of 64 bit integers that are cut down with
// a mask. A second, independent check feeds the comb with a running sum that is allowed to overflow and confirms that the
// output is the original sample sequence again, which is how a comb is used behind the integrators of a CIC filter.
//
// Run from the repository root:
//     iverilog -g2012 -o build/tb_cic_comb.vvp sim/cic_clean/tb_cic_comb.v rtl/rx/cic_comb.v
//     vvp build/tb_cic_comb.vvp

`timescale 1ns/1ps

module chk_comb #(
    parameter WIDTH = 64,
    parameter SEED  = 1
) (
    output reg        done,
    output reg [31:0] errors,
    output reg [31:0] undo_errors
);
    reg clock = 0;
    reg rst = 1;
    reg strobe = 0;
    reg [WIDTH-1:0] in_data = 0;
    wire [WIDTH-1:0] out_data;

    cic_comb #(WIDTH) dut (
        .clock(clock), .rst(rst), .strobe(strobe), .in_data(in_data), .out_data(out_data)
    );

    always #5 clock = ~clock;

    wire [63:0] mask = (64'd1 << WIDTH) - 64'd1;

    // Model: output register and delay register.
    reg [63:0] m_out = 0;
    reg [63:0] m_dly = 0;
    always @(posedge clock) begin
        if (rst) begin
            m_out = 0;
            m_dly = 0;
        end else if (strobe) begin
            m_out = (in_data - m_dly) & mask;      // modulo 2^WIDTH difference
            m_dly = in_data;
        end
    end

    // Second check: in the last part of the run the input is the running sum of random small samples (it wraps), and
    // the output must be the random sample itself, one strobe later than it was added. s_hist remembers the sample that was
    // added at the previous strobe.
    reg [63:0] sample_now = 0;
    reg [63:0] running = 0;
    reg [63:0] expect_sample = 0;
    reg        expect_valid = 0;

    integer seed;
    integer n;
    reg [63:0] r;
    initial begin
        done = 0; errors = 0; undo_errors = 0; seed = SEED;
        repeat (3) @(negedge clock);
        rst = 0;
        // Part 1: random everything, including reset together with strobe.
        for (n = 0; n < 5000; n = n + 1) begin
            @(negedge clock);
            if (out_data !== m_out[WIDTH-1:0]) begin
                errors = errors + 1;
                if (errors < 5) $display("comb W=%0d mismatch at n=%0d: dut %h model %h", WIDTH, n, out_data, m_out[WIDTH-1:0]);
            end
            r = {$random(seed), $random(seed)};
            in_data = r[WIDTH-1:0];
            strobe = r[40];
            rst = (r[50:43] == 8'd0);
        end
        // Part 2: clean reset, then strobe every other clock with a wrapping running sum as input.
        @(negedge clock); rst = 1; strobe = 0;
        @(negedge clock); rst = 0;
        for (n = 0; n < 4000; n = n + 1) begin
            // At this falling edge the output reflects the strobe edge before it.
            if (expect_valid && out_data !== expect_sample[WIDTH-1:0]) begin
                undo_errors = undo_errors + 1;
                if (undo_errors < 5) $display("comb undo W=%0d mismatch at n=%0d: dut %h expect %h", WIDTH, n, out_data, expect_sample[WIDTH-1:0]);
            end
            expect_valid = 0;
            r = {$random(seed), $random(seed)};
            if (n % 2 == 0) begin
                // A large random sample, so the running sum wraps often.
                sample_now = r & mask;
                running = (running + sample_now) & mask;
                in_data = running[WIDTH-1:0];
                strobe = 1;
                // The comb output after this edge is running(now) - running(before) = sample_now.
                expect_sample = sample_now;
                expect_valid = 1;
            end else begin
                strobe = 0;
                in_data = r[WIDTH-1:0];             // garbage while strobe is low must not matter
            end
            @(negedge clock);
        end
        done = 1;
    end
endmodule

module tb_cic_comb;
    wire [3:0] done;
    wire [31:0] e0, e1, e2, e3, u0, u1, u2, u3;
    chk_comb #(64, 21) c0 (.done(done[0]), .errors(e0), .undo_errors(u0));
    chk_comb #(48, 22) c1 (.done(done[1]), .errors(e1), .undo_errors(u1));
    chk_comb #(28, 23) c2 (.done(done[2]), .errors(e2), .undo_errors(u2));
    chk_comb #(8,  24) c3 (.done(done[3]), .errors(e3), .undo_errors(u3));

    initial begin
        wait (&done);
        #1;
        $display("comb: model errors %0d %0d %0d %0d, running sum errors %0d %0d %0d %0d", e0, e1, e2, e3, u0, u1, u2, u3);
        if (e0 + e1 + e2 + e3 + u0 + u1 + u2 + u3 == 0) $display("PASS");
        else $display("FAIL");
        $finish;
    end
endmodule
