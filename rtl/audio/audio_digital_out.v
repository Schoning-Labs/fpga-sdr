// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Taken from an earlier design by the same author.  In fpga-sdr `clk` is clk_dsp
// (120 MHz), the USB hand-over (u_v, u_l, u_r and ctl[2]) is left unconnected because USB audio is not used
// here, and the stream comes from rtl/audio/audio_out_src.v.  docs/AUDIO_OUT.md describes the whole audio output.
//
// audio_digital_out: the digital audio outputs, S/PDIF and I2S, from one 48 kHz stereo stream.
//
// What it does
//   Takes the final mix (24-bit stereo samples at 48 kHz, after the master volume) and sends it out on up to three
//   interfaces that can all be active at once:
//     1. USB audio   the stream is handed on unchanged to the USB core's recording endpoint (not connected here);
//     2. S/PDIF      through audio_spdif_tx.v, for an optical (TOSLINK) or coaxial transmitter;
//     3. I2S         bit clock, word clock, data and a master clock, for a DAC board of the Raspberry Pi type.
//   `ctl` switches each one on and off.
//
// Where it sits in the radio
//   Fed by: audio_out_src.v (48 kHz samples, 16 bit with 8 zero bits added, in the `clk` domain).  Feeds: the
//   S/PDIF and I2S pins.  The glossary entries "I2S" and "S/PDIF" in docs/learn/GLOSSARY.md give the background.
//
// Clocks
//   S/PDIF and I2S run on `clk_aud` = 49.152 MHz = 1,024 x 48 kHz, which is made by the board's own PLLs (no
//   separate audio oscillator): the DSP PLL's 48 MHz output (50 MHz x 24 / 25) goes into a second PLL with
//   x 128 / 125, which gives a VCO at 768 MHz and an output divider of 15.625.  Every pin of the two outputs is a
//   register on clk_aud, so an edge carries the PLL's jitter and nothing from logic.  The frame length is 1,024
//   clocks and everything else is a division of it:
//     master clock  clk_aud / 4    = 12.288 MHz (256 x fs)
//     bit clock     clk_aud / 16   =  3.072 MHz (64 x fs)
//     word clock    clk_aud / 1024 = 48 kHz
//     S/PDIF        one line cell = 8 clocks (6.144 MHz), exact (audio_spdif_tx's rate generator steps by 2^29)
//
// Taking up the rate difference between two clock domains
//   The stream arrives in the `clk` domain with the engine's own 48 kHz tick (a 32-bit phase accumulator on
//   `clk`), which differs from the exact 48 kHz of clk_aud by its rounding: +0.011 ppm with clk = 120 MHz.
//   Sooner or later (one sample every 17 minutes at that error) a sample too many has accumulated.  A small buffer
//   of 8 samples in front of the output holds the samples, and when its fill drifts too high or too low the reader
//   removes or repeats one sample without a click: over 64 frames it reads between two samples, moving 1/64 sample
//   further each frame (a linear blend, i.e. a very slow interpolation) until it is one sample ahead or behind.
//   Outside such a slip the output words are the input words, bit for bit.
//
// I2S format (Philips)
//   Word clock low is the left channel.  Data changes on the falling edge of the bit clock, and the most
//   significant bit comes one bit clock after the edge of the word clock (the bit slot straight after the edge is
//   skipped, which is the difference from the PT8211's format in audio_pt8211_tx.v).  Each channel has 32 bit
//   clocks and carries the 24-bit sample first and 0 in the remaining 8.
//
// Status towards `clk`
//   One one-clock pulse for each input sample, each frame sent, each slip and each error (an error is a buffer
//   overrun or underrun, which loses a sample or restarts the reader), plus the levels run and PLL lock.
`default_nettype none

module audio_digital_out (
    input  wire        clk,
    input  wire        rst,
    // Input stream in the `clk` domain: one clock pulse on s_v per 48 kHz sample, with the signed 24-bit left
    // and right samples valid on that clock.  ctl switches the outputs: bit 0 S/PDIF, bit 1 I2S, bit 2 USB audio.
    input  wire        s_v,               // one clock per 48 kHz sample
    input  wire [23:0] s_l,
    input  wire [23:0] s_r,
    input  wire [2:0]  ctl,               // 0 S/PDIF on, 1 I2S on, 2 USB audio on
    // to the USB core (clk)
    output wire        u_v,
    output wire [23:0] u_l,
    output wire [23:0] u_r,
    // audio clock domain
    // Audio clock domain: clk_aud is the 49.152 MHz audio clock, aud_lock is the lock of the PLL that makes it.
    // The pins spdif, i2s_bck, i2s_ws, i2s_sd and i2s_mclk are registers on clk_aud.
    input  wire        clk_aud,           // 49.152 MHz
    input  wire        aud_lock,          // the audio PLL's lock
    output reg         spdif,
    output reg         i2s_bck,
    output reg         i2s_ws,
    output reg         i2s_sd,
    output reg         i2s_mclk,
    // status (clk)
    // Status in the `clk` domain.  st_lock and st_run are levels (PLL locked, reader running), ev_* are one-clock
    // pulses: ev_in per input sample, ev_frame per frame sent, ev_slip per slip, ev_err per buffer error.
    output wire        st_lock,
    output wire        st_run,
    output wire        ev_in,
    output wire        ev_frame,
    output wire        ev_slip,
    output wire        ev_err
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;
    // ---------------------------------------------------------------- clk side
    // Input side in `clk`: take the 48-bit sample pair into x_d and flip the toggle x_tg once per sample, which is
    // how the new sample is announced to clk_aud (a toggle crosses a clock boundary safely, unlike a pulse).
    // The USB side gets the sample unchanged one clock later.
    reg [47:0] x_d /* synthesis syn_preserve = 1 */;
    reg        x_tg /* synthesis syn_preserve = 1 */;
    reg        u_vr = 1'b0;
    reg [23:0] u_lr = 24'd0, u_rr = 24'd0;
    reg        in_p = 1'b0;
    initial begin x_d = 48'd0; x_tg = 1'b0; end
    always @(posedge clk) begin
        in_p <= s_v && !rst;
        if (s_v && !rst) begin x_d <= {s_r, s_l}; x_tg <= ~x_tg; end
        u_vr <= s_v && ctl[2] && !rst;
        if (s_v) begin u_lr <= s_l; u_rr <= s_r; end
    end
    assign u_v = u_vr; assign u_l = u_lr; assign u_r = u_rr;
    assign ev_in = in_p;

    // ---------------------------------------------------------------- reset and controls into clk_aud
    // Resets, controls and the toggle synchronized into clk_aud.  Each is passed through two or three flip-flops
    // so that a signal from another clock cannot upset the logic behind it.
    reg [2:0] a_rs /* synthesis syn_preserve = 1 */;
    reg [1:0] c_s0 /* synthesis syn_preserve = 1 */;
    reg [1:0] c_s1 /* synthesis syn_preserve = 1 */;
    reg [2:0] t_s /* synthesis syn_preserve = 1 */;
    initial begin a_rs = 3'b111; c_s0 = 2'd0; c_s1 = 2'd0; t_s = 3'd0; end
    always @(posedge clk_aud) begin
        a_rs <= {a_rs[1:0], rst | ~aud_lock};
        c_s0 <= ctl[1:0]; c_s1 <= c_s0;
        t_s  <= {t_s[1:0], x_tg};
    end
    wire a_rst = a_rs[2];
    wire en_sp = c_s1[0], en_i2s = c_s1[1];
    // push is high for one clk_aud clock for every toggle of x_tg.  By the time it is seen, x_d has been stable
    // for two clocks and it stays so for 20 us (one 48 kHz period is 20.8 us), long enough to copy it.
    wire push  = t_s[2] ^ t_s[1];         // x_d has been stable for two clocks and stays so for 20 us

    // ---------------------------------------------------------------- buffer: 8 samples
    // Buffer of 8 samples in clk_aud (written at wp, read at rp, fill = number stored).  fill[3] is high when it is full.
    reg [47:0] mem [0:7];
    reg [2:0]  wp = 3'd0, rp = 3'd0;
    reg [3:0]  fill = 4'd0;
    reg        pop = 1'b0;                // one clock: b takes mem[rp]
    wire       full = fill[3];
    wire [47:0] m_q = mem[rp];
    always @(posedge clk_aud) if (push && !full) mem[wp] <= x_d;

    // ---------------------------------------------------------------- frame counter and reader
    // Frame counter and reader.  c counts the 1,024 clocks of a frame, cn is its next value.  a is the sample
    // in hand and b the one after it.  mode and mu control the slip: in mode 0 the output is a, in mode 1 (a sample
    // is being dropped) mu rises 1 to 63 over 63 frames, in mode 2 (a sample is being repeated) it falls from 63 to
    // 1.  The output is a + (b - a) x mu / 64.  adv says how many samples this frame takes from the buffer.
    // Ordinarily it is 1 per frame, 2 once at the end of a drop, and 0 at the start of a repeat.
    reg [9:0]  c = 10'd0;                 // 1,024 clocks per frame
    wire [9:0] cn = c + 10'd1;
    reg        run = 1'b0;
    reg [47:0] a = 48'd0, b = 48'd0;      // the sample in hand and the next one
    reg [6:0]  mu = 7'd0;                 // 0..63: the output is a + (b - a) x mu / 64
    reg [1:0]  mode = 2'd0;               // 0 none, 1 dropping a sample (mu rises), 2 repeating one (mu falls)
    reg [1:0]  adv = 2'd0;                // samples still to take in this frame
    reg        t_frame = 1'b0, t_slip = 1'b0, t_err = 1'b0;
    // blend: six shift-and-add steps per channel
    reg  signed [24:0] d_l = 25'sd0, d_r = 25'sd0;
    reg  signed [30:0] p_l = 31'sd0, p_r = 31'sd0, q_l = 31'sd0, q_r = 31'sd0;
    reg  [5:0]  m_sh = 6'd0;
    reg  [3:0]  k = 4'd8;                 // 0 load, 1..6 steps, 7 sum, 8 idle
    reg  [23:0] y_l = 24'd0, y_r = 24'd0; // the frame's output, ready long before the next frame
    wire signed [30:0] r_l = q_l + 31'sd32;
    wire signed [30:0] r_r = q_r + 31'sd32;
    wire signed [24:0] s_yl = $signed({a[23], a[23:0]}) + r_l[30:6];
    wire signed [24:0] s_yr = $signed({a[47], a[47:24]}) + r_r[30:6];
    reg  [23:0] o_l = 24'd0, o_r = 24'd0; // the words being sent
    reg         o_v = 1'b0;
    // Normal operation on clk_aud, in the order of a frame:
    //  - bookkeeping of the buffer on every clock (write pointer, fill level, and the pop that moves b into a);
    //  - at clock 0 of a frame the word made during the last frame is sent (o_l, o_r) and the plan for the
    //    new frame is made, based on the fill level: 5 or more samples starts the reader, 6 or more starts
    //    dropping one, 2 or fewer starts repeating one;
    //  - around clock 16 the S/PDIF sender is given its word (o_v);
    //  - in the first clocks of the frame the frame's samples are taken (adv of them), and at clock 32 the blend of
    //    a and b is started;
    //  - if the buffer runs empty the reader stops (run = 0) and the output is silent until it has refilled to 5.
    always @(posedge clk_aud) begin
        pop <= 1'b0; o_v <= 1'b0;
        if (a_rst) begin
            c <= 10'd0; run <= 1'b0; wp <= 3'd0; rp <= 3'd0; fill <= 4'd0; mu <= 7'd0; mode <= 2'd0; adv <= 2'd0;
            k <= 4'd8; y_l <= 24'd0; y_r <= 24'd0; o_l <= 24'd0; o_r <= 24'd0;
        end else begin
            c <= cn;
            // buffer pointers and level
            if (push) begin
                if (full) t_err <= ~t_err; else wp <= wp + 3'd1;
            end
            fill <= fill + ((push && !full) ? 4'd1 : 4'd0) - (pop ? 4'd1 : 4'd0);
            if (pop) begin a <= b; b <= m_q; rp <= rp + 3'd1; end
            // frame start: send the word made in the last frame, then decide this frame's step
            if (cn == 10'd0) begin
                t_frame <= ~t_frame;
                o_l <= run ? y_l : 24'd0; o_r <= run ? y_r : 24'd0;
                if (!run) begin
                    mu <= 7'd0; mode <= 2'd0;
                    if (fill >= 4'd5) begin run <= 1'b1; adv <= 2'd2; end
                end else if (mode == 2'd0) begin
                    if (fill >= 4'd6)      begin mode <= 2'd1; mu <= 7'd1;  adv <= 2'd1; t_slip <= ~t_slip; end
                    else if (fill <= 4'd2) begin mode <= 2'd2; mu <= 7'd63; adv <= 2'd0; t_slip <= ~t_slip; end
                    else adv <= 2'd1;
                end else if (mode == 2'd1) begin
                    if (mu == 7'd63) begin mu <= 7'd0; mode <= 2'd0; adv <= 2'd2; end
                    else begin mu <= mu + 7'd1; adv <= 2'd1; end
                end else begin
                    mu <= mu - 7'd1; adv <= 2'd1;
                    if (mu == 7'd1) mode <= 2'd0;
                end
            end
            if (c == 10'd16) o_v <= 1'b1;               // inside the S/PDIF sender's left preamble (see below)
            // take the frame's samples, one every fourth clock (clocks 4, 8)
            if (c[1:0] == 2'd3 && c[9:4] == 6'd0 && adv != 2'd0) begin
                if (fill == 4'd0) begin run <= 1'b0; adv <= 2'd0; t_err <= ~t_err; end
                else begin pop <= 1'b1; adv <= adv - 2'd1; end
            end
            // blend, started at clock 32 when a and b are in place: q = (b - a) x mu in six shift-and-add steps
            if (c == 10'd32) begin
                d_l <= $signed({b[23], b[23:0]}) - $signed({a[23], a[23:0]});
                d_r <= $signed({b[47], b[47:24]}) - $signed({a[47], a[47:24]});
                m_sh <= mu[5:0]; q_l <= 31'sd0; q_r <= 31'sd0; k <= 4'd0;
            end else if (k == 4'd0) begin
                p_l <= {{6{d_l[24]}}, d_l}; p_r <= {{6{d_r[24]}}, d_r}; k <= 4'd1;
            end else if (k <= 4'd6) begin
                if (m_sh[0]) begin q_l <= q_l + p_l; q_r <= q_r + p_r; end
                m_sh <= {1'b0, m_sh[5:1]};
                p_l <= {p_l[29:0], 1'b0}; p_r <= {p_r[29:0], 1'b0};
                k <= k + 4'd1;
            end else if (k == 4'd7) begin
                y_l <= s_yl[23:0]; y_r <= s_yr[23:0]; k <= 4'd8;
            end
        end
    end

    // ---------------------------------------------------------------- I2S
    // I2S pins, all driven from the frame counter: mclk is cn[1] (clk_aud / 4), bck is cn[3] (/ 16) and ws is cn[9]
    // (/ 1024).  sh is the shift register for the two words: 24 bits left, 8 zeros (the 7 padding bits of the left
    // slot and the skipped slot of the right channel), 24 bits right and 7 zeros, 63 bits in all.  The skipped slot
    // of the left channel is the clock where i2s_sd is set to 0 at the frame start, and after that the next bit
    // of sh moves to i2s_sd at every fall of the bit clock (cn[3:0] == 0).

    reg [62:0] sh = 63'd0;
    initial begin i2s_bck = 1'b0; i2s_ws = 1'b0; i2s_sd = 1'b0; i2s_mclk = 1'b0; end
    wire [23:0] n_l = run ? y_l : 24'd0;
    wire [23:0] n_r = run ? y_r : 24'd0;
    always @(posedge clk_aud) begin
        if (a_rst || !en_i2s) begin
            i2s_bck <= 1'b0; i2s_ws <= 1'b0; i2s_sd <= 1'b0; i2s_mclk <= 1'b0; sh <= 63'd0;
        end else begin
            i2s_mclk <= cn[1];
            i2s_bck  <= cn[3];
            i2s_ws   <= cn[9];
            if (cn[3:0] == 4'd0) begin
                if (cn == 10'd0) begin i2s_sd <= 1'b0; sh <= {n_l, 8'd0, n_r, 7'd0}; end
                else begin i2s_sd <= sh[62]; sh <= {sh[61:0], 1'b0}; end
            end
        end
    end

    // ---------------------------------------------------------------- S/PDIF
    // The sender latches a word whenever it is given one, so the word must arrive while it sends a preamble.
    // Its reset is released at a frame start only; its frame then begins 9 clocks after ours (its rate
    // generator's first step) and its left preamble lasts 64 clocks: the word is given at clock 16.
    wire sp_o;
    reg  sp_rst = 1'b1;
    always @(posedge clk_aud) begin
        if (a_rst || !en_sp) sp_rst <= 1'b1;
        else if (cn == 10'd0) sp_rst <= 1'b0;
    end
    audio_spdif_tx #(.CLK_HZ(49_152_000), .SAMPLE_RATE(48000)) u_spdif (
        .clk(clk_aud), .rst(sp_rst), .in_valid(o_v), .in_l(o_l), .in_r(o_r), .spdif_out(sp_o));
    initial spdif = 1'b0;
    always @(posedge clk_aud) spdif <= sp_o && !sp_rst;

    // ---------------------------------------------------------------- status into clk
    reg [2:0] f_s /* synthesis syn_preserve = 1 */;
    reg [2:0] l_s /* synthesis syn_preserve = 1 */;
    reg [2:0] e_s /* synthesis syn_preserve = 1 */;
    reg [1:0] r_s /* synthesis syn_preserve = 1 */;
    reg [1:0] k_s /* synthesis syn_preserve = 1 */;
    initial begin f_s = 3'd0; l_s = 3'd0; e_s = 3'd0; r_s = 2'd0; k_s = 2'd0; end
    always @(posedge clk) begin
        f_s <= {f_s[1:0], t_frame}; l_s <= {l_s[1:0], t_slip}; e_s <= {e_s[1:0], t_err};
        r_s <= {r_s[0], run}; k_s <= {k_s[0], aud_lock};
    end
    assign ev_frame = f_s[2] ^ f_s[1];
    assign ev_slip  = l_s[2] ^ l_s[1];
    assign ev_err   = e_s[2] ^ e_s[1];
    assign st_run   = r_s[1];
    assign st_lock  = k_s[1];
endmodule

`default_nettype wire
