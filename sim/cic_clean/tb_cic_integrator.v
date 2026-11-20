// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Self checking test of cic_integrator.
//
// The test builds a small behavioral model straight from the arithmetic that an integrator has to follow: an accumulator
// that becomes accumulator plus input at every clock edge where strobe is high, calculated modulo 2^WIDTH, with a
// synchronous reset that wins over strobe. The model works on 64 bit integers and cuts the result down with a mask, so
// it shares no structure with the module under test. Random inputs, random strobes and random resets are applied for a
// few widths (including 64 bits, the default), and the module output is compared with the model after every clock edge.
// A stretch of large constant input makes sure the accumulator really overflows several times, because the wrap-around
// is the property a CIC filter depends on.
//
// Run from the repository root:
//     iverilog -g2012 -o build/tb_cic_integrator.vvp sim/cic_clean/tb_cic_integrator.v rtl/rx/cic_integrator.v
//     vvp build/tb_cic_integrator.vvp

`timescale 1ns/1ps

// One test case for one width. done goes high when the case has finished, errors counts the mismatches.
module chk_integrator #(
    parameter WIDTH = 64,
    parameter SEED  = 1
) (
    output reg        done,
    output reg [31:0] errors,
    output reg [31:0] wraps
);
    reg clock = 0;
    reg rst = 1;
    reg strobe = 0;
    reg [WIDTH-1:0] in_data = 0;
    wire [WIDTH-1:0] out_data;

    cic_integrator #(WIDTH) dut (
        .clock(clock), .rst(rst), .strobe(strobe), .in_data(in_data), .out_data(out_data)
    );

    always #5 clock = ~clock;

    // The mask that keeps WIDTH bits of a 64 bit number (for WIDTH = 64 the shift gives 0 and the minus 1 gives all ones).
    wire [63:0] mask = (64'd1 << WIDTH) - 64'd1;

    // The behavioral model, updated on the clock edge with blocking assignments. The input values are driven at the
    // falling edge, so they are stable at the rising edge and no race exists.
    reg [63:0] acc = 0;
    reg [64:0] wide_sum;
    always @(posedge clock) begin
        if (rst)
            acc = 64'd0;
        else if (strobe) begin
            wide_sum = {1'b0, acc} + {1'b0, in_data};
            if (wide_sum[WIDTH] === 1'b1 && WIDTH < 64) wraps = wraps + 1;
            acc = wide_sum[63:0] & mask;
        end
    end

    integer seed;
    integer n;
    reg [63:0] r;
    initial begin
        done = 0; errors = 0; wraps = 0; seed = SEED;
        // Reset for a few clocks, then random stimulus.
        repeat (3) @(negedge clock);
        rst = 0;
        for (n = 0; n < 6000; n = n + 1) begin
            @(negedge clock);
            // The model has been updated at the rising edge before this falling edge, so compare now.
            if (out_data !== acc[WIDTH-1:0]) begin
                errors = errors + 1;
                if (errors < 5) $display("integrator W=%0d mismatch at n=%0d: dut %h model %h", WIDTH, n, out_data, acc[WIDTH-1:0]);
            end
            r = {$random(seed), $random(seed)};
            // Stretch from 2000 to 2600: large constant positive input, strobe always on, forces overflow.
            if (n >= 2000 && n < 2600) begin
                in_data = {1'b0, {(WIDTH-1){1'b1}}} - 3;
                strobe = 1;
                rst = 0;
            end else begin
                in_data = r[WIDTH-1:0];
                strobe = r[40];                    // about half of the clocks
                rst = (r[50:43] == 8'd0);           // about 1 in 256 clocks, also together with a strobe
            end
        end
        done = 1;
    end
endmodule

module tb_cic_integrator;
    wire [3:0] done;
    wire [31:0] e0, e1, e2, e3, w0, w1, w2, w3;
    chk_integrator #(64, 11) c0 (.done(done[0]), .errors(e0), .wraps(w0));
    chk_integrator #(48, 12) c1 (.done(done[1]), .errors(e1), .wraps(w1));
    chk_integrator #(28, 13) c2 (.done(done[2]), .errors(e2), .wraps(w2));
    chk_integrator #(8,  14) c3 (.done(done[3]), .errors(e3), .wraps(w3));

    initial begin
        wait (&done);
        #1;
        $display("integrator: errors %0d %0d %0d %0d, overflow events %0d %0d %0d %0d", e0, e1, e2, e3, w0, w1, w2, w3);
        if (e0 + e1 + e2 + e3 == 0 && w1 > 3 && w2 > 3 && w3 > 3) $display("PASS");
        else $display("FAIL");
        $finish;
    end
endmodule
