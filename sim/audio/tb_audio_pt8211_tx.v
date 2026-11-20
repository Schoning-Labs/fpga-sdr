// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Testbench for rtl/audio/audio_pt8211_tx.v, the serializer that sends the interpolated stereo samples to the
// PT8211 DAC chip on three pins: BCK (bit clock), WS (word select, which channel) and DIN (the data). The
// PT8211 wants the LSB-justified format (also called the Japanese format): 16 bits per channel, two's
// complement, most significant bit first, shifted in on the rising BCK edge, 32 BCK cycles per stereo frame.
// With BCK at 12.288 MHz that gives 12.288 MHz / 32 = 384 kHz frames, the rate the interpolator produces.
// See docs/learn/GLOSSARY.md for serializer and two's complement.
//
// The test only looks at the three pins from the outside, as the PT8211 itself would. A small decoder in
// the testbench shifts DIN into a register on every BCK rising edge and, after every 16 bits, files the
// word away as right channel (first half of the frame) or left channel (second half), using its own bit
// counter that started at reset. It does not read WS, so the counter has to agree with the DUT's frame
// position, and a swapped channel would show up as a mismatch.
//
// Stimulus: 24 stereo vectors, chosen to catch framing and bit order faults: zero and minus one (all bits
// clear and all set), plus and minus full scale, the alternating patterns 0x5555 and 0xAAAA, plus and minus
// one, a mid-size value, and then a ramp of 14 pairs with different slopes for left and right. `in_valid`
// is raised on the same clock as the DUT's own `frame_tick`, so each sample is taken the moment a frame
// begins and the DUT has about 6 clocks to spare before the first bit has to go out. The full audio engine is
// different, there the interpolator's multi-clock calculation adds one whole frame of delay, which
// tb_audio_engine.v covers. This test only checks the bit exact framing, which does not depend on which
// frame a sample lands in.
//
// Pass: all 24 decoded pairs equal the vectors, in order (the very first decoded frame is skipped, as DIN
// still has its reset value then). The last line is "PASS", otherwise "FAIL: vector ..." lines and "FAIL: <n>
// mismatch(es)", or "FAIL: timeout" after 2 ms of simulated time. Run it from the repository root:
//   iverilog -g2012 -o sim/out/tb_audio_pt8211_tx.vvp sim/audio/tb_audio_pt8211_tx.v && vvp -n sim/out/tb_audio_pt8211_tx.vvp
// or all testbenches together with tools/check.sh.

`timescale 1ns / 1ps
`include "rtl/audio/audio_nco_tick.v"
`include "rtl/audio/audio_pt8211_tx.v"

module tb_audio_pt8211_tx;

    // 120 MHz DSP clock (docs/ARCHITECTURE.md section 2).
    localparam integer CLK_HZ = 120_000_000;
    // Bit clock: 384 kHz frames * 32 bits.
    localparam integer BCK_HZ = 12_288_000;
    localparam real CLK_PERIOD_NS = 1.0e9 / CLK_HZ;

    reg clk = 0;
    always #(CLK_PERIOD_NS / 2.0) clk = ~clk;

    reg rst = 1;

    reg signed [15:0] in_l, in_r;
    reg                in_valid;
    wire               frame_tick;
    wire               bck, ws, din;

    audio_pt8211_tx #(
        .CLK_HZ(CLK_HZ),
        .BCK_HZ(BCK_HZ)
    ) dut (
        .clk       (clk),
        .rst       (rst),
        .in_l      (in_l),
        .in_r      (in_r),
        .in_valid  (in_valid),
        .frame_tick(frame_tick),
        .bck       (bck),
        .ws        (ws),
        .din       (din)
    );

    // ---------------------------------------------------------------- test vectors
    localparam integer NVEC = 24;
    reg signed [15:0] exp_l [0:NVEC-1];
    reg signed [15:0] exp_r [0:NVEC-1];
    integer i;

    initial begin
        exp_l[0]  = 16'sd0;           exp_r[0]  = -16'sd1;
        exp_l[1]  = 16'sh7FFF;        exp_r[1]  = 16'sh8000; // + full scale, - full scale
        exp_l[2]  = 16'sh8000;        exp_r[2]  = 16'sh7FFF;
        exp_l[3]  = 16'sh5555;        exp_r[3]  = 16'shAAAA; // alternating bit patterns
        exp_l[4]  = 16'shAAAA;        exp_r[4]  = 16'sh5555;
        exp_l[5]  = 16'sd1;           exp_r[5]  = -16'sd1;
        exp_l[6]  = 16'sd12345;       exp_r[6]  = -16'sd12345;
        exp_l[7]  = 16'sd0;           exp_r[7]  = 16'sd0;
        exp_l[8]  = 16'sh0001;        exp_r[8]  = 16'shFFFE;
        exp_l[9]  = 16'sh4000;        exp_r[9]  = 16'shC000;
        for (i = 10; i < NVEC; i = i + 1) begin
            exp_l[i] = i * 777 - 9000;
            exp_r[i] = -(i * 333) + 4000;
        end
    end

    // ---------------------------------------------------------------- drive in_l/in_r
    integer vec_idx;
    always @(posedge clk) begin
        if (rst) begin
            vec_idx  <= 0;
            in_valid <= 1'b0;
            in_l     <= 16'sd0;
            in_r     <= 16'sd0;
        end else if (frame_tick && vec_idx < NVEC) begin
            in_l     <= exp_l[vec_idx];
            in_r     <= exp_r[vec_idx];
            in_valid <= 1'b1;
            vec_idx  <= vec_idx + 1;
        end else begin
            in_valid <= 1'b0;
        end
    end

    // ---------------------------------------------------------------- bus-functional PT8211 decoder
    reg [4:0]          idx;      // mirrors the DUT's own bit position, see file header
    reg [15:0]         shreg;
    reg                bck_d;
    wire               bck_rise = bck && !bck_d;

    reg signed [15:0]  got_l [0:NVEC+3];
    reg signed [15:0]  got_r [0:NVEC+3];
    integer            got_count;
    integer            errors;

    // Previous BCK level, to find its rising edge. The decoder runs on the 120 MHz clock and samples BCK
    // like any other signal, which is fine because BCK is only 12.288 MHz.
    always @(posedge clk) bck_d <= bck;

    // Decoder: on every BCK rising edge shift DIN in, and when the 16th bit of a channel has arrived
    // store the word (bit counter 0 to 15 is the right channel, 16 to 31 the left one, and a left word
    // completes a frame).
    always @(posedge clk) begin
        if (rst) begin
            idx       <= 5'd0;
            shreg     <= 16'd0;
            got_count <= 0;
            errors    <= 0;
        end else if (bck_rise) begin
            shreg <= {shreg[14:0], din};
            if (idx[3:0] == 4'hF) begin
                // 16th bit of this channel just shifted in
                if (idx[4] == 1'b0) begin
                    got_r[got_count] <= {shreg[14:0], din};
                end else begin
                    got_l[got_count] <= {shreg[14:0], din};
                    got_count        <= got_count + 1;
                end
            end
            idx <= (idx == 5'd31) ? 5'd0 : (idx + 5'd1);
        end
    end

    // `got_count` goes up once per completed frame (right then left). The first decoded frame is skipped
    // (SKIP): before the first sample reaches the pins, DIN and WS are still at their reset value, so that
    // frame holds no sample yet.
    localparam integer SKIP = 1;

    // Compare every vector with the decoded words, print the verdict and end the simulation.
    task check_all;
        integer k;
        begin
            errors = 0;
            for (k = 0; k < NVEC; k = k + 1) begin
                if (got_l[k+SKIP] !== exp_l[k] || got_r[k+SKIP] !== exp_r[k]) begin
                    $display("FAIL: vector %0d: expected L=%0d R=%0d, decoded L=%0d R=%0d",
                              k, exp_l[k], exp_r[k], got_l[k+SKIP], got_r[k+SKIP]);
                    errors = errors + 1;
                end
            end
            if (errors == 0)
                $display("PASS");
            else
                $display("FAIL: %0d mismatch(es)", errors);
            $finish;
        end
    endtask

    initial begin
        #(20 * CLK_PERIOD_NS);
        rst = 0;
        wait (got_count >= NVEC + SKIP);
        #(2 * CLK_PERIOD_NS);
        check_all;
    end

    // Safety net: 2 ms of simulated time, 24 frames at 384 kHz need about 70 us.
    initial begin
        #(2_000_000);
        $display("FAIL: timeout, got_count=%0d (expected %0d)", got_count, NVEC + SKIP);
        $finish;
    end

endmodule
