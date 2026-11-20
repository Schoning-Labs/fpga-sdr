// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Test of rtl/zoom/zoom_cic_narrow.v, the third CIC filter of the zoom DDC, which only the narrow spans (24
// kHz down to 3 kHz) use. A CIC (cascaded integrator-comb) filter is a chain of running sums, then a
// decimation (only every R-th sample is kept), then a chain of differences, and it does the job of a low-pass
// filter in front of a sample rate reduction without any multiplier; docs/learn/GLOSSARY.md has the terms.
// This one has 11 stages and decimates by 2, 4, 8 or 16, and because its input words arrive at least 300
// clocks apart the chip form works out every add one at a time in a single serial adder, with the state in
// LUT RAM, taking four clocks per add and at most about 270 clocks for each input word. A shift of 0 passes the
// words on unchanged. The gain input multiplies the output by 4^gain (0, 12, 24 or 36 dB) with saturation,
// because the noise in a span of a few kHz is far below one step of a 16-bit word.
//
// The bench holds a model of the same filter written as plain sums that are done in one step, in a task that
// the stimulus calls once per input word. The model keeps 60-bit wrapping accumulators (16 bits of input plus
// 11 stages times 4 bits of growth for decimation 16), shifts the result down by 11 x shift - 2 x gain bits,
// adds half a step for rounding and saturates to 16 bits, which is what the DUT is specified to do.
//
// Stimulus and checks, in this order:
//   1. shift 0: twenty random words, the output must be the same word with its strobe, one clock after
//      the input strobe.
//   2. For decimation 2, 4, 8 and 16, each with gain 0 to 3, each with full-scale random words and with
//      small words (shifted right by 2 x gain + 1 bits, so that the gain does not saturate every word):
//      (30 << shift) + 8 random words, 301 to 332 clocks apart, a reset before each run. Every I and Q
//      output word must equal the model's word, and the number of words must match and be at least 30.
//      A full-scale positive I word on every 13th input and a full-scale negative Q word on every 17th
//      push the sums to their limits.
//   3. A constant input (12345 on I, -32768 on Q) with gain 0 must come out as the same constant, which
//      shows that the DC gain is 1, and this part uses a reset of only five clocks to show that stale
//      state left in the memories is gone from the output after the first eleven output words.
// The bench prints the number of words compared, how many were non-zero and how many were saturated, and
// ends with PASS if there were no errors, more than half of the words were non-zero and more than 20
// words were saturated (so that the saturation path is actually exercised), otherwise FAIL.
//
// Run from the repository root:
//   iverilog -g2012 -s tb_zoom_cic_narrow -o build/tb_zoom_cic_narrow.vvp sim/zoom/tb_zoom_cic_narrow.v && vvp build/tb_zoom_cic_narrow.vvp

`timescale 1ns / 1ps
`include "rtl/zoom/zoom_cic_narrow.v"

module tb_zoom_cic_narrow;
    // 60 = 16-bit input words plus the bit growth of 11 stages at decimation 16 (11 x 4 = 44 bits).
    localparam integer STAGES = 11, ACC = 60;

    // Arbitrary 2 ns clock, only the number of clocks matters.
    reg clock = 1'b0;
    always #1 clock = ~clock;

    reg         rst = 1'b1;
    reg  [2:0]  shift = 3'd0;
    reg  [1:0]  gain = 2'd0;
    reg         in_strobe = 1'b0;
    reg  signed [15:0] in_i = 16'sd0, in_q = 16'sd0;
    wire        os;
    wire signed [15:0] oi, oq;

    zoom_cic_narrow #(.STAGES(STAGES), .WIDTH(16), .MAX_SHIFT(4)) dut (
        .clock(clock), .rst(rst), .shift(shift), .gain(gain),
        .in_strobe(in_strobe), .in_i(in_i), .in_q(in_q), .out_strobe(os), .out_i(oi), .out_q(oq));

    // ---- the model: two channels (index 0 is I, index 1 is Q), with one array of integrators and one of
    // comb delays per channel, and the list of expected output words.
    reg signed [ACC-1:0] mint [0:1][0:STAGES-1];
    reg signed [ACC-1:0] mdly [0:1][0:STAGES-1];
    reg signed [15:0]    exp_q [0:1][0:4095];
    integer              n_exp = 0, n_got = 0, m_cnt = 0;
    reg signed [ACC-1:0] mv, mt;
    reg signed [ACC:0]   mr;
    integer              sh, c, k;

    // Clears the model's state together with the DUT's reset.
    task model_reset;
        begin
            for (c = 0; c < 2; c = c + 1)
                for (k = 0; k < STAGES; k = k + 1) begin mint[c][k] = 0; mdly[c][k] = 0; end
            m_cnt = 0; n_exp = 0; n_got = 0;
        end
    endtask

    // Does one input word of the model: the integrators always, and when this word is the R-th since the last
    // output the combs, the shift and the rounding as well. R is 2^shift, so the mask below is R - 1.
    task model_step(input signed [15:0] xi, input signed [15:0] xq);
        reg dec;
        begin
            // dec is true on every R-th word.
            dec = ((m_cnt & ((1 << shift) - 1)) == ((1 << shift) - 1));
            m_cnt = dec ? 0 : m_cnt + 1;
            for (c = 0; c < 2; c = c + 1) begin
                mv = (c == 0) ? xi : xq;
                // Integrator chain: each stage adds the running value of the one before it.
                for (k = 0; k < STAGES; k = k + 1) begin mint[c][k] = mint[c][k] + mv; mv = mint[c][k]; end
                if (dec) begin
                    // Comb chain: each stage subtracts its own previous input (a one-word delay) from the value.
                    for (k = 0; k < STAGES; k = k + 1) begin mt = mv - mdly[c][k]; mdly[c][k] = mv; mv = mt; end
                    // Right shift by the bit growth minus the gain exponent (4^gain = 2^(2 x gain)).
                    sh = STAGES * shift - 2 * gain;
                    // Round half up in two steps: shift one bit less, add one, then drop that last bit.
                    mr = ($signed({mv[ACC-1], mv}) >>> (sh - 1)) + 1;     // rounding bit added
                    mr = mr >>> 1;
                    // Saturate to the range of a 16-bit word.
                    if (mr > 32767) mr = 32767;
                    if (mr < -32768) mr = -32768;
                    exp_q[c][n_exp] = mr[15:0];
                end
            end
            if (dec) n_exp = n_exp + 1;
        end
    endtask

    // Compares every output word of the DUT to the model's list, in order, I and Q together.
    integer errors = 0, total = 0, nonzero = 0, sat = 0;
    reg cmp_en = 1'b1;
    always @(posedge clock) if (os && !rst && shift != 0 && cmp_en) begin
        total = total + 1;
        if (oi != 0) nonzero = nonzero + 1;
        if (oi == 16'sh7FFF || oi == 16'sh8000) sat = sat + 1;
        if (n_got >= n_exp || oi !== exp_q[0][n_got] || oq !== exp_q[1][n_got]) begin
            errors = errors + 1;
            if (errors <= 10) $display("MISMATCH shift %0d gain %0d word %0d: %0d %0d, model %0d %0d", shift, gain, n_got, oi, oq, exp_q[0][n_got], exp_q[1][n_got]);
        end
        n_got = n_got + 1;
    end

    // Puts one input word on the DUT (and in the model) and then waits the given number of clocks, which
    // must be 300 or more for the DUT.
    task feed(input signed [15:0] xi, input signed [15:0] xq, input integer gap);
        begin
            in_i <= xi; in_q <= xq; in_strobe <= 1'b1;
            @(posedge clock);
            if (shift != 0) model_step(xi, xq);
            in_strobe <= 1'b0;
            repeat (gap) @(posedge clock);
        end
    endtask

    integer s, g, n, i, mode;
    reg signed [15:0] xi, xq, last_i;
    initial begin
        // 1. shift 0: straight through, one clock later.
        rst = 1'b1; shift = 3'd0; repeat (40) @(posedge clock); rst = 1'b0; repeat (4) @(posedge clock);
        for (i = 0; i < 20; i = i + 1) begin
            xi = $random; xq = $random;
            in_i <= xi; in_q <= xq; in_strobe <= 1'b1; @(posedge clock); in_strobe <= 1'b0; in_i <= 16'sd0; in_q <= 16'sd0;
            #0.1;
            if (!os || oi !== xi || oq !== xq) begin errors = errors + 1; $display("pass-through mismatch"); end
            repeat (9) @(posedge clock);
        end
        // 2. Every decimation and gain against the model. Mode 1 uses small words so that gain does not
        // saturate all of them.
        for (s = 1; s <= 4; s = s + 1)
            for (g = 0; g <= 3; g = g + 1)
                for (mode = 0; mode < 2; mode = mode + 1) begin
                    rst = 1'b1; shift = s; gain = g;
                    repeat (40) @(posedge clock);
                    model_reset;
                    rst = 1'b0;
                    repeat (4) @(posedge clock);
                    // Enough input to give at least 30 output words, plus a few more for the filter to settle.
                    n = (30 << s) + 8;
                    for (i = 0; i < n; i = i + 1) begin
                        xi = $random; xq = $random;
                        if (mode == 1) begin xi = xi >>> (2 * g + 1); xq = xq >>> (2 * g + 1); end
                        if (i % 13 == 0) xi = 16'sh7FFF;
                        if (i % 17 == 0) xq = 16'sh8000;
                    // Spacing of 301 to 332 clocks between strobes, above the 300 the DUT requires.
                        feed(xi, xq, 300 + ($random & 31));
                    end
                    // Wait for the last output to come out, then check the number of words.
                    repeat (400) @(posedge clock);
                    if (n_got != n_exp || n_got < 30) begin
                        errors = errors + 1;
                        $display("ERROR shift %0d gain %0d: %0d words, model %0d", s, g, n_got, n_exp);
                    end
                end
        // 3. DC gain 1 at gain 0, and a reset shorter than the clearing time of the memories.
        cmp_en = 1'b0;
        for (s = 1; s <= 4; s = s + 1) begin
            rst = 1'b1; shift = s; gain = 0; repeat (5) @(posedge clock); model_reset; rst = 1'b0; repeat (4) @(posedge clock);
            // Constant input, long enough to flush the 11 stages, then the last output must equal it.
            for (i = 0; i < (20 << s); i = i + 1) feed(16'sd12345, -16'sd32768, 300);
            repeat (400) @(posedge clock);
            if (oi !== 16'sd12345 || oq !== -16'sd32768) begin errors = errors + 1; $display("DC gain: shift %0d gives %0d %0d", s, oi, oq); end
        end
        // Pass only with no errors, mostly non-zero words, and a number of saturated words (the
        // saturation path was reached).
        $display("%0d words compared (%0d not zero, %0d saturated), %0d errors", total, nonzero, sat, errors);
        if (errors == 0 && nonzero > total / 2 && sat > 20) $display("PASS");
        else $display("FAIL");
        $finish;
    end
endmodule
