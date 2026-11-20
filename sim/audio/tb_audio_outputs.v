// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Testbench for the digital audio outputs as the core wires them (docs/AUDIO_OUT.md section 6): the register
// block `audio_regs` (rtl/top/block_regs.v, registers out_ctrl and out_status), the stream source
// rtl/audio/audio_out_src.v and the output block rtl/audio/audio_digital_out.v with its S/PDIF and I2S pins. I2S
// (a three-wire serial audio bus: bit clock, word clock and data) is a common way to feed an external DAC
// board, S/PDIF carries the same stereo stream on a single pin for an optical transmitter. See
// docs/learn/GLOSSARY.md for both.
//
// What audio_out_src does matters for the checks: it must give the outputs one sample every 2,500 clocks
// (120 MHz / 2,500 = 48 kHz) whether or not the audio engine delivers anything, because an HDMI sink or an
// S/PDIF receiver wants a stream that never stops. A sample from the engine is passed on as it comes, and
// when none arrives for the period plus a grace time of 16 clocks (2,516 in all) a zero sample is sent
// instead and then one every 2,500 clocks. With the tone bit set it sends a 1 kHz sine from a table of
// 48 entries (20,000 x sin(2 pi p / 48)) instead.
//
// The testbench contains a model of the audio engine (a sample every 2,499, 2,500 or 2,501 clocks, picked
// at random by a small shift-register generator, so the spacing is slightly irregular and averages 2,500),
// a decoder of the I2S pins (data taken on the rising bit clock, word clock
// low for the left channel, one bit of delay, 24 bits per word) and a register bus. The steps are:
//   1  the reset value of out_ctrl is 3 (S/PDIF and I2S on, no tone)
//   2  no engine: the first zero sample comes about 2,516 clocks after the start and then one every 2,500
//      clocks exactly, I2S carries zeros, status is PLL lock plus run and not live
//   3  test tone on: I2S carries the 48-entry 1 kHz table in order on both channels, in the top 16 of the
//      24 bits (the low 8 bits are zero)
//   4  engine samples: passed on one for one, bit for bit and with none added, status shows live
//   5  engine stops: zeros again at the exact rate, not live, and no slip or error has been counted in the
//      whole run
//   6  out_ctrl = 0: all five pins (S/PDIF, I2S bit clock, word clock, data and master clock) stay low
// The coding of S/PDIF itself is checked in sim/audio/tb_audio_digital_out.v, here the only check is that its pin
// moves while it is switched on.
//
// Passing: every check passes and the last line is "PASS: tb_audio_outputs, <n> checks", otherwise one
// "FAIL: <text>" line per failed check and "FAIL: tb_audio_outputs, <k> of <n> checks failed". Run it from
// the repository root:
//   iverilog -g2012 -o sim/out/tb_audio_outputs.vvp sim/audio/tb_audio_outputs.v && vvp -n sim/out/tb_audio_outputs.vvp

`include "rtl/top/block_regs.v"
`include "rtl/audio/audio_nco_tick.v"
`include "rtl/audio/audio_spdif_tx.v"
`include "rtl/audio/audio_out_src.v"
`include "rtl/audio/audio_digital_out.v"
// The time unit comes after the includes, which set their own coarser one: 1 fs resolution is needed for
// the 20.345 ns period of the 49.152 MHz audio clock.
`timescale 1ns / 1fs

module tb_audio_outputs;
    // `clk` is the 120 MHz DSP clock, `clk_aud` the 49.152 MHz audio clock (1,024 x 48 kHz, the board's PLL
    // output) and `lock` stands for that PLL's lock signal.
    reg clk = 1'b0, clk_aud = 1'b0, rst = 1'b1, lock = 1'b0;
    always #(25.0 / 6.0) clk = ~clk;                    // 120 MHz
    // Audio clock period in ns, 1000 / 49.152 = 20.345 ns.
    localparam real TA = 1000.0 / 49.152;
    always #(TA / 2.0) clk_aud = ~clk_aud;

    // `check` counts the checks and prints the text of a failed one, `what` holds up to 80 characters.
    integer errors = 0, checks = 0;
    task check(input cond, input [639:0] what);
        begin checks = checks + 1; if (!cond) begin errors = errors + 1; $display("FAIL: %0s (t=%0t)", what, $time); end end
    endtask

    // ---------------------------------------------------------------- register bus
    reg         bus_wr = 1'b0, bus_rd = 1'b0;
    reg  [15:0] bus_addr = 16'd0;
    reg  [31:0] bus_wdata = 32'd0;
    wire [31:0] bus_rdata;
    wire [2:0]  ctl;
    wire        st_lock, st_run, live, ev_slip, ev_err;
    audio_regs u_regs (
        .clk(clk), .rst(rst), .bus_wr(bus_wr), .bus_rd(bus_rd), .bus_addr(bus_addr), .bus_wdata(bus_wdata),
        .bus_rdata(bus_rdata), .enable(), .ring_base(), .ring_wptr(), .ring_rptr(32'd0), .low_water(1'b0), .irq(),
        .out_ctl(ctl), .out_lock(st_lock), .out_run(st_run), .out_live(live),
        .out_ev_slip(ev_slip), .out_ev_err(ev_err));
    // Result of the last `rd_reg`.
    reg [31:0] rd;
    // Register write: address and data are set up on one clock and the write strobe is held for the next.
    task wr_reg(input [15:0] a, input [31:0] d);
        begin @(posedge clk); bus_addr <= a; bus_wdata <= d; bus_wr <= 1'b1; @(posedge clk); bus_wr <= 1'b0; end
    endtask
    // Register read: the data is picked up two clocks after the read strobe.
    task rd_reg(input [15:0] a);
        begin @(posedge clk); bus_addr <= a; bus_rd <= 1'b1; @(posedge clk); bus_rd <= 1'b0; @(posedge clk); rd = bus_rdata; end
    endtask

    // ---------------------------------------------------------------- stream source and outputs
    // Engine side input of audio_out_src (driven by the engine model below) and its output stream.
    reg         in_v = 1'b0;
    reg  [15:0] in_l = 16'd0, in_r = 16'd0;
    wire        s_v;
    wire [15:0] s_l, s_r;
    audio_out_src u_src (
        .clk(clk), .rst(rst), .in_v(in_v), .in_l(in_l), .in_r(in_r), .tone(ctl[2]),
        .s_v(s_v), .s_l(s_l), .s_r(s_r), .live(live));
    // The output pins of audio_digital_out. The 24-bit input words carry the 16-bit sample in their top bits.
    wire spdif, bck, ws, sd, mclk;
    audio_digital_out u_aout (
        .clk(clk), .rst(rst), .s_v(s_v), .s_l({s_l, 8'd0}), .s_r({s_r, 8'd0}), .ctl({1'b0, ctl[1:0]}),
        .u_v(), .u_l(), .u_r(), .clk_aud(clk_aud), .aud_lock(lock),
        .spdif(spdif), .i2s_bck(bck), .i2s_ws(ws), .i2s_sd(sd), .i2s_mclk(mclk),
        .st_lock(st_lock), .st_run(st_run), .ev_in(), .ev_frame(), .ev_slip(ev_slip), .ev_err(ev_err));

    // Stream monitor: for every sample the source sends (`s_v`) it measures the gap to the previous one in
    // clocks (`gap_min`, `gap_max`, `first_gap`) and stores the stereo word {right, left} in `s_q`.
    // spacing of the stream's samples, in clocks
    integer gap = 0, gap_min = 1 << 30, gap_max = 0, n_s = 0, first_gap = -1;
    reg [31:0] s_q [0:4095];
    always @(posedge clk) begin
        if (rst) gap = 0;
        else if (s_v) begin
            if (first_gap < 0) first_gap = gap + 1;
            else begin if (gap + 1 < gap_min) gap_min = gap + 1; if (gap + 1 > gap_max) gap_max = gap + 1; end
            gap = 0;
            s_q[n_s & 4095] = {s_r, s_l}; n_s = n_s + 1;
        end else gap = gap + 1;
    end

    // Engine model: when `eng_on` is set it delivers a random 16-bit pair every 2,499 to 2,501 clocks and
    // stores each one in `e_q` as {right, left} for the later comparison.
    // engine model: a sample every 2,499 to 2,501 clocks
    reg        eng_on = 1'b0;
    integer    eng_c = 0, eng_p = 2500, n_e = 0;
    reg [31:0] lfsr = 32'hACE1_2468;
    reg [31:0] e_q [0:4095];
    always @(posedge clk) begin
        in_v <= 1'b0;
        if (!eng_on) eng_c <= 0;
        else if (eng_c >= eng_p - 1) begin
            eng_c <= 0;
            lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            eng_p <= 2499 + (lfsr[7:0] % 3);
            in_v <= 1'b1; in_l <= lfsr[15:0]; in_r <= lfsr[31:16];
            e_q[n_e & 4095] = lfsr; n_e = n_e + 1;
        end else eng_c <= eng_c + 1;
    end

    // I2S decoder: a change of the word clock restarts the bit count, bits 1 to 24 after it are the sample,
    // shifted in on the rising bit clock. The word clock is low for the left channel, so a completed high
    // word closes a pair {right, left} that is stored in `i2s_q`.
    // I2S decoder (as sim/audio/tb_audio_digital_out.v)
    reg         ws_d = 1'b0;
    integer     idx = 99, n_i2s = 0;
    reg  [23:0] shr = 24'd0, i_l = 24'd0;
    reg  [47:0] i2s_q [0:4095];
    always @(posedge bck) begin
        if (ws !== ws_d) idx = 0; else idx = idx + 1;
        ws_d = ws;
        if (idx >= 1 && idx <= 24) shr = {shr[22:0], sd};
        if (idx == 24) begin
            if (!ws) i_l = shr;
            else begin i2s_q[n_i2s & 4095] = {shr, i_l}; n_i2s = n_i2s + 1; end
        end
    end
    // Number of edges seen on the S/PDIF pin, to see that it moves.
    integer sp_edges = 0;
    always @(spdif) sp_edges = sp_edges + 1;

    // The 1 kHz table as a function, to compare the decoded words against.
    function signed [15:0] tone_rom(input integer p);
        integer q;
        real v;
        begin
            // the table is 20000 x sin(2 pi p / 48), rounded
            v = 20000.0 * $sin(6.283185307179586 * p / 48.0);
            q = (v >= 0.0) ? $rtoi(v + 0.5) : -$rtoi(-v + 0.5);
            tone_rom = q;
        end
    endfunction

    integer i, j, bad, off, k0;
    reg [47:0] w;
    // Test sequence, each step is explained in the header.
    initial begin
        repeat (20) @(posedge clk);
        lock = 1'b1; rst = 1'b0;

        // ---- step 1: reset value of out_ctrl
        rd_reg(16'h0020);
        check(rd == 32'd3, "1: out_ctrl resets to 3");

        // ---- step 2: no engine, the source supplies zero samples on its own
        repeat (60) @(negedge ws);
        check(first_gap >= 2516 && first_gap <= 2518, "2: first zero sample 2,516 clocks after the start (the test counts 1 or 2 more)");
        $display("first zero sample after %0d clocks", first_gap);
        check(gap_min == 2500 && gap_max == 2500, "2: then one sample every 2,500 clocks");
        bad = 0; for (i = 0; i < n_s; i = i + 1) if (s_q[i] !== 32'd0) bad = bad + 1;
        check(n_s > 50 && bad == 0, "2: zero samples");
        check(i2s_q[(n_i2s - 1) & 4095] === 48'd0, "2: I2S carries zeros");
        rd_reg(16'h0024);
        check(rd == 32'h0000_0003, "2: status = lock, run, not live, no slip, no error");
        check(sp_edges > 1000, "2: S/PDIF pin moves");

        // ---- step 3: tone on (bit 2 together with S/PDIF and I2S), find where in the table the first
        // decoded word sits, then every following word has to follow the table
        wr_reg(16'h0020, 32'd7);
        rd_reg(16'h0020);
        check(rd == 32'd7, "3: out_ctrl reads back 7");
        repeat (20) @(negedge ws);
        k0 = n_i2s;
        repeat (120) @(negedge ws);
        // find the table phase of the first word, then all must follow in order
        off = -1;
        for (j = 0; j < 48; j = j + 1) begin
            w = i2s_q[k0 & 4095];
            if ($signed(w[23:8]) == tone_rom(j) && $signed(i2s_q[(k0 + 1) & 4095][23:8]) == tone_rom((j + 1) % 48)) off = j;
        end
        check(off >= 0, "3: tone found on I2S");
        bad = 0;
        for (i = 0; i < 110; i = i + 1) begin
            w = i2s_q[(k0 + i) & 4095];
            if ($signed(w[23:8]) !== tone_rom((off + i) % 48) || w[47:32] !== w[23:8] || w[7:0] !== 8'd0 || w[31:24] !== 8'd0) bad = bad + 1;
        end
        check(bad == 0, "3: 110 I2S words equal the 1 kHz table, both channels, low 8 bits 0");
        wr_reg(16'h0020, 32'd3);

        // ---- step 4: engine samples, compare the source stream and the I2S words with the engine's
        n_s = 0; n_e = 0; gap_min = 1 << 30; gap_max = 0;
        eng_on = 1'b1;
        repeat (200) @(negedge ws);
        check(live, "4: live");
        check(n_e > 190 && (n_s - n_e) <= 1 && (n_s - n_e) >= 0, "4: one sample out per engine sample");
        // the stream's words are the engine's, in order (the first may be the last zero sample)
        off = (s_q[0] === e_q[0]) ? 0 : 1;
        bad = 0; for (i = 0; i < n_e - 2; i = i + 1) if (s_q[i + off] !== e_q[i]) bad = bad + 1;
        check(bad == 0, "4: stream words equal the engine's words");
        // and they arrive on I2S bit for bit: find the engine's word 10
        off = -1;
        for (j = 0; j < 400; j = j + 1) begin
            w = i2s_q[(n_i2s - 1 - j) & 4095];
            if (off < 0 && w === {e_q[10][31:16], 8'd0, e_q[10][15:0], 8'd0}) off = (n_i2s - 1 - j);
        end
        check(off >= 0, "4: engine word found on I2S");
        bad = 0;
        for (i = 0; i < 150; i = i + 1) begin
            w = i2s_q[(off + i) & 4095];
            if (w !== {e_q[10 + i][31:16], 8'd0, e_q[10 + i][15:0], 8'd0}) bad = bad + 1;
        end
        check(bad == 0, "4: 150 I2S words equal the engine's words");
        rd_reg(16'h0024);
        check(rd == 32'h0000_0007, "4: status = lock, run, live, no slip, no error");

        // ---- step 5: engine stops
        eng_on = 1'b0;
        repeat (4) @(negedge ws);
        n_s = 0; gap_min = 1 << 30; gap_max = 0;
        repeat (40) @(negedge ws);
        check(!live && gap_min == 2500 && gap_max == 2500, "5: engine stopped: exact rate again, not live");
        check(i2s_q[(n_i2s - 1) & 4095] === 48'd0, "5: zeros on I2S");
        rd_reg(16'h0024);
        check(rd == 32'h0000_0003, "5: no slip and no error counted in the whole run");

        // ---- step 6: all outputs switched off
        wr_reg(16'h0020, 32'd0);
        repeat (40) @(posedge clk_aud);
        bad = 0;
        repeat (2100) begin @(posedge clk_aud); if (bck || ws || sd || mclk || spdif) bad = bad + 1; end
        check(bad == 0, "6: pins low when switched off");

        if (errors == 0) $display("PASS: tb_audio_outputs, %0d checks", checks);
        else $display("FAIL: tb_audio_outputs, %0d of %0d checks failed", errors, checks);
        $finish;
    end
endmodule
