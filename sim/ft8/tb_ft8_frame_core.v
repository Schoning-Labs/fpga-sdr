// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Small, self-contained test of the FT8 spectrogram transform, rtl/ft8/ft8_frame_core.v followed
// by the power stage rtl/ft8/ft8_power.v. A spectrogram is a picture of signal power per
// frequency bin and per time frame, and the FT8 decoder searches it for the Costas sync pattern.
// One frame here is a 3,840 point Fourier transform (see docs/learn/GLOSSARY.md) of a window of
// 1,920 audio samples at 12 ksps, built from fifteen 256 point sub-transforms by ft8_frame_core.v
// and then turned into 1,024 power words (real squared plus imaginary squared, shifted right by
// 16 and saturated to 32 bits) by ft8_power.v.
//
// Stimulus: the first 3,840 samples of the WSJT-X recording qso3_busy, read from
// sim/ft8/vectors/qso3_busy_small_audio.hex (one 16 bit sample per line in hex). Frames start
// 480 samples (40 ms) apart, so these samples give the first NFRAMES = 5 frames, each using a
// 1,920 sample window. The audio is written into the frame core's input buffer, the transform
// is started, and the power stage then streams out the 1,024 words of the frame.
//
// Pass criterion: every one of the 5 x 1,024 power words must equal the word in
// sim/ft8/vectors/qso3_busy_small_power.hex, which is a prefix of the Rust reference model's
// spectrogram (`ft8-frontend vectors` on captures/ft8/qso3_busy.wav, power shift 16), and every
// frame must produce exactly 1,024 words. The bench prints "PASS: tb_ft8_frame_core (...)" on
// success, and a "FAIL" line otherwise, with the first 20 mismatches listed. Both vector files
// are small and are kept in the repository so that this test runs without any download. The same
// check over all 372 frames of the real recording is sim/ft8/ft8_frame_core_wav_harness.v.
//
// Run from the repository root, as tools/check.sh does for every tb_*.v: iverilog -g2012 -o
// out.vvp sim/ft8/tb_ft8_frame_core.v, then vvp out.vvp.

`timescale 1ns / 1ps
`include "rtl/ft8/ft8_frame_core.v"
`include "rtl/ft8/ft8_power.v"

module tb_ft8_frame_core;
    // Number of 1,920 sample frames checked, taken 480 samples apart from the start of the audio.
    localparam integer NFRAMES = 5;

    // 100 MHz bench clock (10 ns period).
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;

    // The audio (3,840 samples is five frames' worth: 4 x 480 + 1,920) and the model's expected
    // power words, 1,024 per frame.
    reg [15:0] audio [0:3839];
    initial $readmemh("sim/ft8/vectors/qso3_busy_small_audio.hex", audio);
    reg [31:0] expect_word [0:NFRAMES*1024-1];
    initial $readmemh("sim/ft8/vectors/qso3_busy_small_power.hex", expect_word);

    // Input buffer write port of the frame core, one 16 bit sample per write.
    reg        buf_wr_en;
    reg [10:0] buf_wr_addr;
    reg [15:0] buf_wr_data;
    reg        frame_start;
    wire       frame_busy, frame_done;

    wire        p_rd_en;
    wire [9:0]  p_rd_addr;
    wire signed [43:0] rd_re, rd_im;

    // FEED_PERIOD = 8 clocks between samples fed to the FFT, the pace used in the chip.
    ft8_frame_core #(.FEED_PERIOD(8)) dut (
        .clk(clk), .rst(rst),
        .buf_wr_en(buf_wr_en), .buf_wr_addr(buf_wr_addr), .buf_wr_data(buf_wr_data),
        .frame_start(frame_start), .frame_busy(frame_busy), .frame_done(frame_done),
        .rd_en(p_rd_en), .rd_addr(p_rd_addr), .rd_re(rd_re), .rd_im(rd_im)
    );

    // Power stage handshake and its output stream of 1,024 (bin, word) pairs per frame.
    reg        p_start;
    wire       p_busy, p_done;
    wire       p_out_valid;
    wire [9:0] p_out_bin;
    wire [31:0] p_out_word;

    // sh = 16 is the power shift, credit = 0 means no flow control (one word per clock).
    ft8_power u_power (
        .clk(clk), .rst(rst),
        .start(p_start), .sh(5'd16), .busy(p_busy), .done(p_done), .credit(2'd0),
        .rd_en(p_rd_en), .rd_addr(p_rd_addr), .rd_re(rd_re), .rd_im(rd_im),
        .out_valid(p_out_valid), .out_bin(p_out_bin), .out_word(p_out_word)
    );

    // got collects one frame's 1,024 power words, indexed by bin.
    integer errors, checked, f, i;
    reg [31:0] got [0:1023];

    // One clock, then 1 ns later, so that the bench changes its inputs after the clock edge.
    task step;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    // For each frame: fill the buffer, run the frame core, run the power stage, then compare.
    initial begin
        errors = 0;
        checked = 0;
        buf_wr_en = 0;
        buf_wr_addr = 0;
        buf_wr_data = 0;
        frame_start = 0;
        p_start = 0;
        repeat (4) step;
        rst = 0;
        step;

        for (f = 0; f < NFRAMES; f = f + 1) begin
            // Load this frame's 1,920 sample window (frame f covers audio[480 * f .. 480 * f + 1919]).
            for (i = 0; i < 1920; i = i + 1) begin
                buf_wr_en   = 1;
                buf_wr_addr = i[10:0];
                buf_wr_data = audio[480 * f + i];
                step;
            end
            buf_wr_en = 0;
            step;

            // Start the transform and wait until the frame core reports the frame done, which is
            // after its 16 blocks (15 sub-transforms and one flush block) have been combined.
            frame_start = 1;
            step;
            frame_start = 0;
            while (!frame_done) step;
            step; // let frame_busy settle low

            // Read the finished frame out through the power stage, noting which bin each word is.
            p_start = 1;
            step;
            p_start = 0;
            i = 0;
            while (!p_done) begin
                if (p_out_valid) begin
                    got[p_out_bin] = p_out_word;
                    i = i + 1;
                end
                step;
            end
            if (p_out_valid) begin
                got[p_out_bin] = p_out_word;
                i = i + 1;
            end
            // A frame must produce exactly one word per bin.
            if (i != 1024) begin
                $display("FAIL: frame %0d produced %0d power words, expected 1,024", f, i);
                errors = errors + 1;
            end

            // Bit-exact comparison with the model.
            for (i = 0; i < 1024; i = i + 1) begin
                checked = checked + 1;
                if (got[i] !== expect_word[f * 1024 + i]) begin
                    errors = errors + 1;
                    if (errors <= 20)
                        $display("MISMATCH frame %0d bin %0d: got %08x want %08x", f, i, got[i], expect_word[f * 1024 + i]);
                end
            end
            $display("frame %0d checked (%0d errors so far)", f, errors);
        end

        if (errors == 0) $display("PASS: tb_ft8_frame_core (%0d frames, %0d bins)", NFRAMES, checked);
        else $display("FAIL: tb_ft8_frame_core, %0d errors of %0d", errors, checked);
        $finish;
    end
endmodule
