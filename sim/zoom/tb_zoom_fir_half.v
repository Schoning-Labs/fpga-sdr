// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Bit-exact comparison of the zoom DDC's half-band filter, rtl/zoom/zoom_fir_half.v, against a parallel
// reference of the same filter, sim/zoom/ref/zoom_fir_half_parallel_ref.v.
//
// The filter is a 63-tap linear-phase FIR (finite impulse response, a sliding weighted sum of the last 63
// samples) that low-passes the I and Q streams and keeps every second output, which is a decimation by 2;
// it is what protects the displayed 80 % of the zoom spectrum against aliasing, and docs/learn/GLOSSARY.md
// explains these terms. The coefficients are symmetric, so the two samples that share a coefficient are
// added before the multiply and only 32 multiplications are needed for the 63 taps. The DUT works them out
// two folded taps per clock with two multipliers per channel, on a block RAM delay line that also queues
// the bursts in which the HL2 delivers its samples. The reference works out all 32 products in the same
// clock, with 64 multipliers, is easy to read, and shares nothing with the DUT's sequencing, so a matching
// output proves that the serial schedule, the bank selection of the delay line and the burst queue are
// right. Both are built with 20-bit coefficients here and read rtl/zoom/zoom_fir_half_coeffs.hex.
//
// Stimulus: the same strobes and 16-bit I and Q words go to both. The random words include both extremes
// (+32767 and -32768) with a chance of 1 in 16 each, to drive the accumulators to their limits. The clock is
// 120 MHz, the rate the chip runs at (half period 4.1667 ns), and the gap between inputs is counted in clocks:
//   1. 4,000 inputs with a random spacing of 5 to 15 clocks, 10 on average, which is what the widest
//      span delivers (the fixed CIC in front decimates by 10)
//   2. HL2-frame bursts, four times: 597 inputs, one every 10 clocks (a frame of 5,968 samples arrives on
//      consecutive clocks, and the fixed CIC turns that into one input per 10 clocks), then a pause of
//      6,000 clocks, with alternating full-scale words
//   3. the closest spacing the filter allows, 3 clocks, for 300 random inputs
// After each part the bench prints the number of outputs of both filters and the largest backlog of jobs
// that the DUT had queued (its internal pend counter), and requires that the DUT has caught up.
//
// What counts as a pass: after each part the DUT has produced as many outputs as the reference, at the end
// every output pair (I and Q together) is equal, and the reference produced at least 3,000 outputs so that
// the comparison is not empty. It prints "PASS: n outputs equal" or "FAIL" with the number of errors, and
// the first ten mismatches are listed.
//
// Run from the repository root, because the coefficient file is read relative to it:
//   iverilog -g2012 -o build/tb_zoom_fir_half.vvp sim/zoom/tb_zoom_fir_half.v && vvp build/tb_zoom_fir_half.vvp

`timescale 1ns / 1ps

// fft_mul is the multiplier of the reference, and cic_var_shared and fir_decim give the DUT its
// multiply-accumulate block (rx_mac).
`include "rtl/fft/fft_mul.v"
`include "rtl/rx/cic_var_shared.v"
`include "rtl/rx/fir_decim.v"
`include "rtl/zoom/zoom_fir_half.v"
`include "sim/zoom/ref/zoom_fir_half_parallel_ref.v"

module tb_zoom_fir_half;
    reg clock = 1'b0;
    // 120 MHz: half period 1 / (2 x 120 MHz) = 4.1667 ns.
    always #4.1667 clock = ~clock;                     // 120 MHz

    reg               rst = 1'b1;
    reg               in_strobe = 1'b0;
    reg signed [15:0] in_i = 16'sd0, in_q = 16'sd0;
    wire              s_d, s_r;
    wire signed [15:0] di, dq, ri, rq;

    // Both filters see the same inputs. The widths are the chip's (16-bit words) with 20-bit coefficients.
    zoom_fir_half #(.TAPS(63), .IN_WIDTH(16), .COEFF_WIDTH(20), .OUT_WIDTH(16)) u_dut (
        .clock(clock), .rst(rst), .in_strobe(in_strobe), .in_i(in_i), .in_q(in_q),
        .out_strobe(s_d), .out_i(di), .out_q(dq));
    zoom_fir_half_ref #(.TAPS(63), .IN_WIDTH(16), .COEFF_WIDTH(20), .OUT_WIDTH(16)) u_ref (
        .clock(clock), .rst(rst), .in_strobe(in_strobe), .in_i(in_i), .in_q(in_q),
        .out_strobe(s_r), .out_i(ri), .out_q(rq));

    // Outputs of both filters, in order, I in the upper half and Q in the lower half of one word.
    reg [31:0] q_d [0:65535];
    reg [31:0] q_r [0:65535];
    integer n_d = 0, n_r = 0, n_in = 0;
    always @(posedge clock) if (s_d) begin q_d[n_d] = {di, dq}; n_d = n_d + 1; end
    always @(posedge clock) if (s_r) begin q_r[n_r] = {ri, rq}; n_r = n_r + 1; end

    // Largest number of jobs that the DUT had accepted and not started yet.
    integer max_pend = 0;
    always @(posedge clock) if (u_dut.pend > max_pend) max_pend = u_dut.pend;

    // The seed is fixed so that every run uses the same random words.
    integer errors = 0, seed = 20261012;

    // Puts one input word on both filters: the strobe lasts one clock, and the task returns when
    // `gap` clocks have passed since the strobe was raised, so that the next call starts a new spacing.
    task put(input signed [15:0] a, input signed [15:0] b, input integer gap);
        integer g;
        begin
            @(posedge clock);
            in_i <= a; in_q <= b; in_strobe <= 1'b1; n_in = n_in + 1;
            @(posedge clock);
            in_strobe <= 1'b0;
            for (g = 2; g < gap; g = g + 1) @(posedge clock);
        end
    endtask

    // A random 16-bit word, with the two extremes in 1 of 16 cases each.
    function signed [15:0] rnd16(input integer dummy);
        integer r;
        begin
            r = $random(seed);
            case (r[3:0])
                4'd0:    rnd16 = 16'sh7FFF;
                4'd1:    rnd16 = 16'sh8000;
                default: rnd16 = r[31:16];
            endcase
        end
    endfunction

    integer k, b, behind;
    // Prints the output counts and the job backlog after a part, and counts a failure when the DUT has
    // outputs left to deliver.
    task report(input [255:0] name);
        begin
            behind = n_r - n_d;
            $display("%0s: %0d inputs so far, ref %0d outputs, dut %0d outputs, largest job backlog %0d, behind %0d",
                     name, n_in, n_r, n_d, max_pend, behind);
            if (behind != 0) begin errors = errors + 1; $display("  FAIL: not caught up"); end
        end
    endtask

    initial begin
        // Reset for a few clocks, then a few clocks of quiet.
        repeat (6) @(posedge clock);
        rst <= 1'b0;
        repeat (4) @(posedge clock);

        // Part 1: random spacing of 5 to 15 clocks.
        for (k = 0; k < 4000; k = k + 1) put(rnd16(0), rnd16(0), 5 + ($random(seed) & 32'h7FFF_FFFF) % 11);
        repeat (400) @(posedge clock);
        report("1 random spacing");

        // Part 2: four HL2-frame bursts (597 inputs, 10 clocks apart), each followed by a long pause.
        for (b = 0; b < 4; b = b + 1) begin
            for (k = 0; k < 597; k = k + 1)
                put((k & 1) ? 16'sh7FFF : 16'sh8000, (k & 2) ? 16'sh8000 : 16'sh7FFF, 10);
            repeat (6000) @(posedge clock);
        end
        report("2 frame bursts");

        // Part 3: the closest spacing the filter allows.
        for (k = 0; k < 300; k = k + 1) put(rnd16(0), rnd16(0), 3);
        repeat (4000) @(posedge clock);
        report("3 closest spacing");

        // Compare every output pair of the two filters, in order (!== also catches x).
        for (k = 0; k < n_r && k < n_d; k = k + 1)
            if (q_d[k] !== q_r[k]) begin
                errors = errors + 1;
                if (errors < 10) $display("MISMATCH output %0d: dut %h ref %h", k, q_d[k], q_r[k]);
            end
        // Enough outputs must have been compared for the result to mean something.
        if (n_r < 3000) begin errors = errors + 1; $display("FAIL: only %0d reference outputs", n_r); end
        if (errors == 0) $display("PASS: %0d outputs equal", n_r);
        else $display("FAIL: %0d error(s)", errors);
        $finish;
    end
endmodule
