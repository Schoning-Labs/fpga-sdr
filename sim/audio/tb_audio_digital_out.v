// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Pin-level testbench for rtl/audio/audio_digital_out.v, the block that turns one 48 kHz, 24-bit stereo stream into three
// outputs at once: S/PDIF (one pin, for an optical transmitter), I2S (bit clock, word clock, data and master
// clock, for an external DAC board) and a hand-over of the unchanged words to USB audio (docs/AUDIO_OUT.md
// section 6). The block runs its pins on a 49.152 MHz audio clock (1,024 x 48 kHz) from the board's PLL, while
// the samples arrive on the 100 MHz system clock of this bench from a source that can be slightly off 48 kHz,
// so inside it a small reader compensates the difference by blending between samples, a "slip".
// The file originates in an earlier design by the same author.
//
// The testbench contains its own decoders and compares what they see on the pins with the words it drove in: an
// I2S decoder (data taken on the rising bit clock, word clock low for left, one bit of delay, 24 bits in a
// 32-bit slot) and an S/PDIF decoder (biphase mark coding, the three preamble types recognized by their code
// violation). See docs/learn/GLOSSARY.md for I2S, S/PDIF and biphase mark.
//   case 0  source exactly 48 kHz: I2S, S/PDIF and the USB hand-over carry the input words bit for bit, the
//           clocks are 4, 16 and 1,024 audio clocks long (master, bit and word clock), and the data changes only
//           at the falling bit clock
//   case 1  source 1 % fast, input a ramp that rises by 1,000 per sample: the reader drops samples by blending,
//           so no step between output samples is larger than 1 + 1/64 input steps (1,016), no error, and about 9
//           slips in 900 frames
//   case 2  source 1 % slow: the same with repeats, no step smaller than 1 - 1/64 input steps (984) and none
//           negative
//   case 3  source stops and starts again: one error is counted, the output goes to zero and comes back
//   case 4  outputs switched off: pins low
// There is also a check that S/PDIF switched off and on again in the middle of a frame still delivers whole words.
//
// Passing: every check passes and the last line is "PASS: tb_audio_digital_out, <n> checks", otherwise one "FAIL: <text>"
// line per failed check and "FAIL: tb_audio_digital_out, <k> of <n> checks failed". Run it from the repository root:
//   iverilog -g2012 -o sim/out/tb_audio_digital_out.vvp sim/audio/tb_audio_digital_out.v && vvp -n sim/out/tb_audio_digital_out.vvp

`include "rtl/audio/audio_nco_tick.v"
`include "rtl/audio/audio_spdif_tx.v"
`include "rtl/audio/audio_digital_out.v"
`timescale 1ns / 1fs        // after the includes: theirs is 1 ps, too coarse for the audio clock period

module tb_audio_digital_out;
    // `clk` is the 100 MHz system clock of this bench (the radio's own is 120 MHz, the block does not
    // depend on the figure), `clk_aud` the 49.152 MHz audio clock and `lock` stands for the audio PLL's lock.
    reg clk = 1'b0, clk_aud = 1'b0, rst = 1'b1, lock = 1'b0;
    always #5 clk = ~clk;                               // 100 MHz
    localparam real TA = 1000.0 / 49.152;               // audio clock period, ns
    always #(TA / 2.0) clk_aud = ~clk_aud;

    // Inputs of the block: one stereo sample (24 bits each) with its one-clock strobe, and the control bits
    // (0 S/PDIF on, 1 I2S on, 2 USB audio on).
    reg         s_v = 1'b0;
    reg  [23:0] s_l = 24'd0, s_r = 24'd0;
    reg  [2:0]  ctl = 3'b111;
    wire        u_v, spdif, bck, ws, sd, mclk, st_lock, st_run, ev_in, ev_frame, ev_slip, ev_err;
    wire [23:0] u_l, u_r;
    audio_digital_out dut (
        .clk(clk), .rst(rst), .s_v(s_v), .s_l(s_l), .s_r(s_r), .ctl(ctl), .u_v(u_v), .u_l(u_l), .u_r(u_r),
        .clk_aud(clk_aud), .aud_lock(lock), .spdif(spdif), .i2s_bck(bck), .i2s_ws(ws), .i2s_sd(sd),
        .i2s_mclk(mclk), .st_lock(st_lock), .st_run(st_run), .ev_in(ev_in), .ev_frame(ev_frame),
        .ev_slip(ev_slip), .ev_err(ev_err));

    // `check` counts the checks and prints the text of a failed one, `what` holds up to 80 characters.
    integer errors = 0, checks = 0;
    task check(input cond, input [639:0] what);
        begin checks = checks + 1; if (!cond) begin errors = errors + 1; $display("FAIL: %0s (t=%0t)", what, $time); end end
    endtask

    // ---------------------------------------------------------------- source
    integer mode = 0;                                   // 0 random words, 1 ramp
    real    ppm = 0.0;
    reg     src_on = 1'b0;
    integer n_in = 0;
    reg [47:0] in_q [0:8191];
    reg [31:0] lfsr = 32'h1234_5678;
    real tnext;
    reg [23:0] rl, rr;
    // Source model: every 1,024 audio clocks (divided by 1 + ppm/1e6, which is how a source off by `ppm`
    // parts per million is made), present a new stereo word for one clock. In mode 0 the words are random
    // (from a shift-register generator), in mode 1 a ramp of +1,000 per sample on the left and -1,000 on the
    // right. Every word sent is also stored in `in_q`, as {right, left}, for the comparison.
    initial begin
        tnext = 0.0;
        forever begin
            @(posedge clk);
            if (!src_on) tnext = $realtime;
            else if ($realtime >= tnext) begin
                tnext = tnext + 1024.0 * TA / (1.0 + ppm * 1.0e-6);
                if (mode == 0) begin
                    lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
                    s_l <= lfsr[23:0]; s_r <= ~lfsr[27:4];
                    in_q[n_in & 8191] = {~lfsr[27:4], lfsr[23:0]};
                end else begin
                    rl = n_in * 1000; rr = -(n_in * 1000);
                    s_l <= rl; s_r <= rr;
                    in_q[n_in & 8191] = {rr, rl};
                end
                n_in = n_in + 1;
                s_v <= 1'b1; @(posedge clk); s_v <= 1'b0;
            end
        end
    end

    // ---------------------------------------------------------------- USB hand-over
    integer n_u = 0, u_bad = 0;
    always @(posedge clk) if (u_v) begin
        if ({u_r, u_l} !== in_q[n_u & 8191]) u_bad = u_bad + 1;
        n_u = n_u + 1;
    end

    // I2S decoder: a change of the word clock restarts the bit count, bits 1 to 24 after it are the sample,
    // shifted in on the rising bit clock, and a completed high word closes a pair {right, left} stored in
    // `i2s_q`. A set bit in the 8 pad bits of the slot is an error.
    // ---------------------------------------------------------------- I2S decoder
    reg         ws_d = 1'b0;
    integer     idx = 99, n_i2s = 0;
    reg  [23:0] shr = 24'd0, i_l = 24'd0;
    reg  [47:0] i2s_q [0:8191];
    always @(posedge bck) begin
        if (ws !== ws_d) idx = 0; else idx = idx + 1;
        ws_d = ws;
        if (idx >= 1 && idx <= 24) shr = {shr[22:0], sd};
        if (idx == 24) begin
            if (!ws) i_l = shr;
            else begin i2s_q[n_i2s & 8191] = {shr, i_l}; n_i2s = n_i2s + 1; end
        end
        if (idx > 24 && sd !== 1'b0) begin errors = errors + 1; $display("FAIL: I2S pad bit not 0"); end
    end
    // Clock shape monitors: the periods of master, bit and word clock must be 4, 16 and 1,024 audio clocks
    // (within 0.1 percent), and the data and word clock may only change right at a falling bit clock.
    // clock shapes: periods in audio clocks; data changes only where the bit clock falls
    realtime t_b = 0, t_m = 0, t_w = 0;
    integer  bad_per = 0, bad_sd = 0;
    reg      shape_on = 1'b0;
    always @(posedge bck)  begin if (shape_on && t_b != 0 && (($realtime - t_b) / TA < 15.99 || ($realtime - t_b) / TA > 16.01)) bad_per = bad_per + 1; t_b = $realtime; end
    always @(posedge mclk) begin if (shape_on && t_m != 0 && (($realtime - t_m) / TA < 3.99 || ($realtime - t_m) / TA > 4.01)) bad_per = bad_per + 1; t_m = $realtime; end
    always @(negedge ws)   begin if (shape_on && t_w != 0 && (($realtime - t_w) / TA < 1023.9 || ($realtime - t_w) / TA > 1024.1)) bad_per = bad_per + 1; t_w = $realtime; end
    realtime t_bf = 0;
    always @(negedge bck) t_bf = $realtime;
    always @(sd) if (shape_on && ($realtime - t_bf) > 0.001) bad_sd = bad_sd + 1;
    always @(ws) if (shape_on && ($realtime - t_bf) > 0.001) bad_sd = bad_sd + 1;

    // S/PDIF decoder. One chip (half of a biphase mark cell) is 8 audio clocks. The line is sampled in the
    // middle of every chip, two chips make one bit (equal chips are a 0, different ones a 1), and a
    // preamble is found as three equal chips in a row (a level held for 1.5 cells, which data never does).
    // A subframe is a preamble, 24 data bits and 4 more bits (validity, user, channel status and parity, of
    // which the parity must come out even).
    reg  [47:0] sp_q [0:8191];
    integer     n_sp = 0, sp_par = 0, sp_pre = 0;
    reg         sp_on = 1'b0;
    reg  [23:0] sp_w, sp_l;
    reg  [7:0]  pre;
    integer     ci, bi;
    reg         par, c0, c1, lost;
    reg  [1:0]  kind;
    integer     good;
    function [1:0] pre_kind(input [7:0] p);            // 1 B, 2 M, 3 W, 0 none; either starting level
        reg [7:0] q;
        begin
            q = p[7] ? ~p : p;
            pre_kind = (q == 8'b0001_0111) ? 2'd1 : (q == 8'b0001_1101) ? 2'd2 : (q == 8'b0001_1011) ? 2'd3 : 2'd0;
        end
    endfunction
    initial begin : spdif_dec
        forever begin
            wait (sp_on);
            // find the phase: an edge of the pin, then half a chip; then slide chip by chip until the last eight
            // chips are a preamble
            @(spdif); #(4.0 * TA);
            pre = 8'd0;
            begin : find
                forever begin
                    pre = {pre[6:0], spdif}; #(8.0 * TA);
                    if (pre_kind(pre) != 2'd0 || !sp_on) disable find;
                end
            end
            // read subframes; a subframe counts when the next preamble follows it (a false start, for example
            // the tail of preamble B with the first data chips, is dropped and the search starts again)
            good = 0; lost = 1'b0;
            while (sp_on && !lost) begin
                sp_w = 24'd0; par = 1'b0; kind = pre_kind(pre);
                for (bi = 0; bi < 28; bi = bi + 1) begin
                    c0 = spdif; #(8.0 * TA); c1 = spdif; #(8.0 * TA);
                    if (bi < 24) sp_w[bi] = c0 ^ c1;
                    par = par ^ c0 ^ c1;
                end
                for (ci = 0; ci < 8; ci = ci + 1) begin pre = {pre[6:0], spdif}; #(8.0 * TA); end
                if (pre_kind(pre) == 2'd0) begin
                    lost = 1'b1;
                    if (good > 4) sp_pre = sp_pre + 1;
                end else begin
                    good = good + 1;
                    if (par) sp_par = sp_par + 1;
                    if (kind == 2'd3) begin sp_q[n_sp & 8191] = {sp_w, sp_l}; n_sp = n_sp + 1; end
                    else sp_l = sp_w;
                end
            end
        end
    end

    // Event counters from the block's status pulses (slips, errors, frames sent and input samples taken).
    // ---------------------------------------------------------------- event counters
    integer n_slip = 0, n_err = 0, n_frame = 0, n_evin = 0;
    always @(posedge clk) begin
        if (ev_slip) n_slip = n_slip + 1;
        if (ev_err) n_err = n_err + 1;
        if (ev_frame) n_frame = n_frame + 1;
        if (ev_in) n_evin = n_evin + 1;
    end

    // Restart for a new case: switch the source and decoders off, reset the block, clear every counter,
    // set the mode and ppm offset and start again.
    task restart(input integer m, input real p);
        begin
            src_on = 1'b0; sp_on = 1'b0; shape_on = 1'b0;
            rst = 1'b1; repeat (40) @(posedge clk);
            mode = m; ppm = p; n_in = 0; n_u = 0; u_bad = 0; n_i2s = 0; n_sp = 0; n_slip = 0; n_err = 0; n_frame = 0;
            n_evin = 0; sp_par = 0; sp_pre = 0; bad_per = 0; bad_sd = 0; idx = 99;
            rst = 1'b0; repeat (40) @(posedge clk);
            src_on = 1'b1; sp_on = 1'b1;
        end
    endtask

    // first index where the decoded stream starts to carry input words: decoded[i] == in[i - off]
    integer off, i, mism, d, dmin, dmax, neg;
    // Find where in a decoded stream the input words begin, which is the first position where two
    // successive decoded words equal the first two input words (`which`: 0 I2S, 1 S/PDIF).
    task find_off(input integer which);
        reg [47:0] w;
        integer j, found;
        begin
            off = -1; found = 0;
            for (j = 0; j < 40 && !found; j = j + 1) begin
                w = which ? sp_q[j] : i2s_q[j];
                if (w === in_q[0] && (which ? sp_q[j + 1] : i2s_q[j + 1]) === in_q[1]) begin off = j; found = 1; end
            end
        end
    endtask

    initial begin
        repeat (20) @(posedge clk);
        lock = 1'b1;

        // ---- case 0: exact 48 kHz, bit for bit, clock shapes
        restart(0, 0.0);
        repeat (40) @(negedge ws);
        shape_on = 1'b1;
        repeat (300) @(negedge ws);
        shape_on = 1'b0;
        check(st_lock && st_run, "case 0: lock and run");
        check(n_slip == 0 && n_err == 0, "case 0: no slip, no error");
        check(bad_per == 0, "case 0: clock periods 4, 16, 1024 audio clocks");
        check(bad_sd == 0, "case 0: data and word clock change at the falling bit clock only");
        check(n_u > 300 && u_bad == 0, "case 0: USB hand-over carries every input word");
        find_off(0);
        check(off >= 0, "case 0: I2S stream found");
        mism = 0;
        for (i = off; i < n_i2s - 1; i = i + 1) if (i2s_q[i] !== in_q[i - off]) mism = mism + 1;
        check(n_i2s - off > 290 && mism == 0, "case 0: I2S words equal the input words");
        find_off(1);
        check(off >= 0, "case 0: S/PDIF stream found");
        mism = 0;
        for (i = off; i < n_sp - 1; i = i + 1) if (sp_q[i] !== in_q[i - off]) mism = mism + 1;
        check(n_sp - off > 280 && mism == 0, "case 0: S/PDIF words equal the input words");
        check(sp_par == 0 && sp_pre == 0, "case 0: S/PDIF parity even, preambles known");
        check(n_frame > 300 && n_evin > 300 && (n_frame - n_evin < 3) && (n_evin - n_frame < 3), "case 0: frame and sample pulses");
        $display("case 0: %0d I2S words, %0d S/PDIF words, %0d USB words", n_i2s, n_sp, n_u);

        // ---- case 1: source 1 % fast (10,000 ppm), ramp input
        restart(1, 10000.0);
        repeat (900) @(negedge ws);
        check(n_err == 0, "case 1: no error");
        check(n_slip >= 7 && n_slip <= 11, "case 1: about 9 slips in 900 frames");
        dmin = 1 << 30; dmax = 0; mism = 0;
        for (i = 20; i < n_i2s - 1; i = i + 1) begin
            d = $signed(i2s_q[i + 1][23:0]) - $signed(i2s_q[i][23:0]);
            if (d < dmin) dmin = d; if (d > dmax) dmax = d;
            d = $signed(i2s_q[i][47:24]) + $signed(i2s_q[i][23:0]);   // the blend rounds a half upwards on both
            if (d < 0 || d > 1) mism = mism + 1;
        end
        check(dmin >= 1000 && dmax <= 1016, "case 1: every step between 1 and 1 + 1/64 input steps");
        check(mism == 0, "case 1: right = minus left, within the rounding");
        $display("case 1: %0d slips, steps %0d to %0d", n_slip, dmin, dmax);

        // ---- case 2: source 1 % slow
        restart(1, -10000.0);
        repeat (900) @(negedge ws);
        check(n_err == 0, "case 2: no error");
        check(n_slip >= 7 && n_slip <= 11, "case 2: about 9 slips in 900 frames");
        dmin = 1 << 30; dmax = 0;
        for (i = 20; i < n_i2s - 1; i = i + 1) begin
            d = $signed(i2s_q[i + 1][23:0]) - $signed(i2s_q[i][23:0]);
            if (d < dmin) dmin = d; if (d > dmax) dmax = d;
        end
        check(dmin >= 984 && dmax <= 1000, "case 2: every step between 1 - 1/64 and 1 input step");
        $display("case 2: %0d slips, steps %0d to %0d", n_slip, dmin, dmax);

        // ---- case 3: the source stops and starts again
        restart(1, 0.0);
        repeat (100) @(negedge ws);
        check(st_run, "case 3: running");
        src_on = 1'b0;
        repeat (30) @(negedge ws);
        check(!st_run && n_err == 1, "case 3: stopped, one error");
        check(i2s_q[(n_i2s - 1) & 8191] === 48'd0, "case 3: zeros while stopped");
        src_on = 1'b1;
        repeat (30) @(negedge ws);
        check(st_run && i2s_q[(n_i2s - 1) & 8191] !== 48'd0, "case 3: running again");

        // ---- S/PDIF switched off and on again in the middle of a frame: words still whole
        mode = 0; ctl = 3'b110; repeat (3000) @(posedge clk_aud); sp_on = 1'b0; repeat (10) @(posedge clk);
        ctl = 3'b111; n_sp = 0; sp_par = 0; sp_pre = 0; sp_on = 1'b1;
        repeat (100) @(negedge ws);
        mism = 0;
        for (i = 10; i < n_sp - 1; i = i + 1) if (sp_q[i] !== i2s_q[(n_i2s - n_sp + i) & 8191] && sp_q[i] !== i2s_q[(n_i2s - n_sp + i + 1) & 8191] && sp_q[i] !== i2s_q[(n_i2s - n_sp + i - 1) & 8191]) mism = mism + 1;
        check(n_sp > 80 && sp_par == 0 && sp_pre == 0 && mism == 0, "S/PDIF after off and on: parity, preambles, words");

        // ---- case 4: outputs off
        ctl = 3'b000; mism = 0;
        repeat (4) @(negedge clk_aud);
        repeat (2100) begin @(posedge clk_aud); if (bck || ws || sd || mclk || spdif) mism = mism + 1; end
        n_u = 0; repeat (5000) @(posedge clk);
        check(mism == 0 && n_u == 0, "case 4: pins low and no USB words when switched off");
        lock = 1'b0; repeat (20) @(posedge clk);
        check(!st_lock, "lock bit follows the PLL");

        if (errors == 0) $display("PASS: tb_audio_digital_out, %0d checks", checks);
        else $display("FAIL: tb_audio_digital_out, %0d of %0d checks failed", errors, checks);
        $finish;
    end
endmodule
