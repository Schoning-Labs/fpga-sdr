// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Bench for the FT8 spectrogram transform, rtl/ft8/ft8_frame_core.v followed by the power stage
// rtl/ft8/ft8_power.v, run over real audio from a WSJT-X recording. A spectrogram is a picture
// of how much signal there is at each frequency (a bin) at each moment (a frame), and the FT8
// decoder searches that picture for the Costas sync pattern. Here one frame is a 3,840 point
// Fourier transform (see docs/learn/GLOSSARY.md) of a window of 1,920 samples, built from
// fifteen 256 point sub-transforms by ft8_frame_core.v and then turned into 1,024 power words
// (real squared plus imaginary squared, shifted and saturated to 32 bits) by ft8_power.v.
//
// The bench takes the 12 ksps audio of a recording, one 1,920 sample window per frame
// (windows start 480 samples = 40 ms apart, so a 15 s slot gives 372 frames), pushes it through
// both blocks and compares the 1,024 power words of each frame with those of the Rust reference
// model (fw/tr-modes, `ft8-frontend vectors`, files audio.hex and spectrogram_sh16.hex, the
// 16 being the power shift used here). N_CHECK frames are checked, spread evenly over the slot.
//
// Pass criterion: every power word equals the model's and every frame yields exactly 1,024
// words. The bench prints "PASS: tb_ft8_frame_core_wav (...)" on success and a "FAIL" line
// otherwise, with the first 20 mismatches listed.
//
// This file has no tb_ prefix on purpose: tools/check.sh compiles every sim/**/tb_*.v on its
// own, and this one cannot compile without the parameters that tools/check_ft8_wav.sh writes.
// That script builds the vectors, writes the generated include file named by the define
// FT8_WAV_PARAMS (localparams N_TIME, N_CHECK, AUDIO_FILE and POWER_FILE), compiles this file with
// iverilog -g2012 and runs it with vvp. Checking all 372 frames takes about 20 minutes, so
// tools/check.sh asks for 20 frames (FT8_WAV_FRAMES=20).

`timescale 1ns / 1ps
`include "rtl/ft8/ft8_frame_core.v"
`include "rtl/ft8/ft8_power.v"
`include `FT8_WAV_PARAMS

module tb_ft8_frame_core_wav;
    // 15 s of audio at 12 ksps.
    localparam integer SLOT_LEN = 180_000;

    // 100 MHz bench clock (10 ns period).
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;

    // The recording's audio (16-bit samples) and the model's expected power words, 1,024 per frame.
    reg [15:0] audio [0:SLOT_LEN-1];
    initial $readmemh(AUDIO_FILE, audio);
    reg [31:0] expect_word [0:N_TIME*1024-1];
    initial $readmemh(POWER_FILE, expect_word);

    // Input buffer write port of the frame core, one 16-bit sample per write.
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

    // sh = 16 is the per-receiver power shift, credit = 0 means no flow control (one word per clock).
    ft8_power u_power (
        .clk(clk), .rst(rst),
        .start(p_start), .sh(5'd16), .busy(p_busy), .done(p_done), .credit(2'd0),
        .rd_en(p_rd_en), .rd_addr(p_rd_addr), .rd_re(rd_re), .rd_im(rd_im),
        .out_valid(p_out_valid), .out_bin(p_out_bin), .out_word(p_out_word)
    );

    // got collects one frame's 1,024 power words, indexed by bin.
    integer errors, checked, fi, f, i;
    reg [31:0] got [0:1023];

    // One clock, then 1 ns later, so that the bench changes its inputs after the clock edge.
    task step;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    // For each checked frame: fill the buffer, run the frame core, run the power stage, then compare.
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

        for (fi = 0; fi < N_CHECK; fi = fi + 1) begin
            // Frame number f of the N_CHECK that are checked, spread evenly from 0 to N_TIME - 1.
            f = (N_CHECK <= 1) ? 0 : (fi * (N_TIME - 1)) / (N_CHECK - 1);

            // Load the 1,920 sample window of frame f (frames start 480 samples apart).
            for (i = 0; i < 1920; i = i + 1) begin
                buf_wr_en   = 1;
                buf_wr_addr = i[10:0];
                buf_wr_data = audio[480 * f + i];
                step;
            end
            buf_wr_en = 0;
            step;

            // Start the transform and wait until the last of the 16 blocks (15 sub-transforms and
            // one flush block, see ft8_frame_core.v) has been combined.
            frame_start = 1;
            step;
            frame_start = 0;
            while (!frame_done) step;
            step;

            // Read the finished frame out through the power stage and note which bin each word is.
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
            $display("frame %0d/%0d checked (%0d errors so far)", f, N_TIME, errors);
        end

        if (errors == 0) $display("PASS: tb_ft8_frame_core_wav (%0d frames, %0d bins)", N_CHECK, checked);
        else $display("FAIL: tb_ft8_frame_core_wav, %0d errors of %0d", errors, checked);
        $finish;
    end
endmodule
