// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// usb_play: the radio's side of the USB playback path, on the radio's clock (clk_dsp, 120 MHz; docs/USB_AUDIO.md sections
// 4, 5 and 7). The PC's playback samples are written into a FIFO by usb_ep_play.v on the 48 MHz USB clock; this module
// takes one stereo sample per 48 kHz tick of the radio out of that FIFO and hands it on three ways. It sits in
// usb_audio.v between the playback FIFO (usb_afifo.v) on one side and the radio's audio stream, the capture endpoint
// (usb_ep_cap.v) and the register page (usb_regs.v) on the other. A tick comes every 2,500 clocks of clk_dsp
// (120 MHz / 48 kHz), so there is a lot of time to do each step.
//
// The tick is `s_v` of the radio's own 48 kHz stream (rtl/audio/audio_out_src.v: one clock per sample, never
// stops), so a playback sample and a receiver sample always come as a pair. The radio is the master of the rate: the
// PC is told through the feedback endpoint of usb_ep_play.v to send as many samples as are taken here, and when it
// does not follow (the FIFO runs empty or full) the module never waits for it, it plays silence or drops samples and
// counts the event.
//
// Reader. It waits until START samples (96, which is 2 ms of audio) are in the FIFO, then takes one per tick. A tick that
// finds the FIFO
// empty gives a zero sample, pulses `ev_under` and sends the reader back to waiting (so one gap in the PC's
// stream costs one count, not one per tick). While the PC has the playback interface switched off
// (`stream_on` low) the reader waits and counts nothing. Nothing here can wait on the PC. The FIFO's output
// r_data already shows the next sample before the tick (usb_afifo.v keeps it ready), so at the tick the sample is
// copied and the FIFO is popped one clock later.
//
// Outputs, two clocks after the tick:
//   m_v/m_l/m_r   the radio's stream for the digital outputs (HDMI, S/PDIF, I2S): the input stream, plus the
//                 playback sample when `monitor` is set (saturating add: the sum is limited to the 16-bit range instead of
//                 wrapping around, which would give a loud click)
//   c_v/c_l/c_r   the stream for the PC's recording endpoint: the input stream, or the playback sample when
//                 `loopback` is set. Taken before the monitor is added.
//   CPU FIFO      1,024 words {R, L} in block RAM (rtl/rx_backend/bk_ram.v, two 18 kbit blocks, 1,024 x 32 bits), filled with every sample that
//                 came from the PC while `fifo_en` is set, or, with `ext_sel` (usb.ctrl.speech_src,
//                 docs/USB_HOST.md section 5), with the samples of the USB host's microphone (x_v/x_l/x_r, at
//                 that device's own rate, not on the radio's tick); f_word is the oldest word, f_pop takes it. A sample
//                 that finds it full is dropped (`ev_fover`). With fifo_en low it is empty. The firmware reads it
//                 through usb_regs.v.
//   pk_play, pk_cap   largest magnitude (15 bits, of either channel) since the last pk_clr_play / pk_clr_cap (a peak meter for
//                 each direction, which the firmware reads and clears)
//
// The block RAM is read at an address that differs from the write address whenever the word is used: the
// level the reader sees (f_level) follows a push two clocks late, after the RAM's own read (UG285: this chip
// has no read-before-write mode, a read of the address that is being written would give the old word, so the level
// is only raised once the word has been in the RAM for a while). Samples are signed 16-bit numbers in two's complement.
//
// Latency: a PC sample leaves the FIFO at the next 48 kHz tick after it is in the FIFO (the FIFO itself holds 96
// samples when the reader starts, which is 2 ms), and reaches the outputs 2 clocks after that tick.
//
// Gowin specifics: the CPU FIFO is a block RAM with a registered read (UG285), the playback FIFO that feeds this module is in
// LUT RAM (usb_afifo.v), and the module's attributes keep the fan-out limit high. No DSP block is used: the only arithmetic is a 17-bit add and a comparison.

`timescale 1ns / 1ps

module usb_play #(
    parameter integer START = 96         // samples that must wait in the FIFO before the reader starts (2 ms at 48 kHz)
) (
    input  wire               clk,  // radio clock, 120 MHz
    input  wire               rst,  // synchronous reset
    // the radio's 48 kHz stream: valid is a one-clock pulse per sample, then the left and right samples, signed 16 bit
    input  wire               s_v,
    input  wire signed [15:0] s_l,
    input  wire signed [15:0] s_r,
    // controls (registers of usb_regs.v)
    input  wire               stream_on,     // 1 = the PC has the playback interface on (from usb_regs.v, already on this clock)
    input  wire               fifo_en,  // 1 = the CPU FIFO is filled (else it is empty and held in reset)
    input  wire               monitor,  // 1 = add the PC's playback to the stream of the digital outputs
    input  wire               loopback,  // 1 = send the PC's own playback back to the PC's recording instead of the receiver audio
    // the other speech source: the USB host's microphone, one x_v pulse per sample (usbh_top.v)
    // the other speech source: the USB host's microphone (rtl/usbh), one x_v pulse per sample
    input  wire               ext_sel,  // 1 = the CPU FIFO takes the host microphone instead of the PC's playback (usb.ctrl.speech_src)
    input  wire               x_v,
    input  wire signed [15:0] x_l,
    input  wire signed [15:0] x_r,
    // playback FIFO, read side
    input  wire [8:0]         r_avail,  // entries in the playback FIFO that can be read (0 to 256)
    input  wire [31:0]        r_data,        // the next playback sample, {R, L}
    output reg                r_pop = 1'b0,  // one-clock pulse: take the sample, the FIFO steps on
    // streams out: m_* to the digital outputs, c_* to the PC's recording endpoint, both valid one clock per sample, 2 clocks after s_v
    output reg                m_v = 1'b0,
    output reg  signed [15:0] m_l = 16'sd0,
    output reg  signed [15:0] m_r = 16'sd0,
    output reg                c_v = 1'b0,
    output reg  signed [15:0] c_l = 16'sd0,
    output reg  signed [15:0] c_r = 16'sd0,
    // CPU FIFO
    input  wire               f_pop,  // CPU FIFO read strobe from usb_regs.v: take the oldest word out
    output wire [31:0]        f_word,  // the oldest word of the CPU FIFO, {R, L}
    output reg  [10:0]        f_level = 11'd0,  // words in the CPU FIFO that the firmware may read, 0 to 1,024 (a few clocks behind the writes)
    // status and events
    // status and events
    output reg                run = 1'b0,  // 1 while the reader is playing PC samples, 0 while it is waiting to fill up
    output reg                ev_under = 1'b0,  // one-clock pulse: a tick found the FIFO empty (under-run)
    output reg                ev_fover = 1'b0,  // one-clock pulse: a sample found the CPU FIFO full and was dropped
    input  wire               pk_clr_play,  // one-clock pulse: restart the playback peak meter
    input  wire               pk_clr_cap,  // one-clock pulse: restart the capture peak meter
    output reg  [14:0]        pk_play = 15'd0,  // largest magnitude of the playback samples since the last clear (15 bits)
    output reg  [14:0]        pk_cap = 15'd0  // largest magnitude of the stream to the PC since the last clear (15 bits)
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;

    // Saturating 17-bit to 16-bit: if the two top bits differ the sum overflowed, and it is limited to the largest
    // positive or negative value.
    function signed [15:0] sat17(input signed [16:0] x);
        sat17 = (x[16] != x[15]) ? (x[16] ? -16'sd32768 : 16'sd32767) : x[15:0];
    endfunction
    // Magnitude of a sample, 15 bits (for a negative number the bitwise inverse, which is one less than its size, close enough for a meter).
    function [14:0] mag(input signed [15:0] x);
        mag = x[15] ? ~x[14:0] : x[14:0];
    endfunction

    // ---------------------------------------------------------------- reader
    // avail: the FIFO's count, registered. t1, t2, t3: the tick delayed by 1, 2 and 3 clocks, which times the later steps.
    // h_l, h_r: the radio's sample of this tick. p_l, p_r: the PC's sample of this tick (zero when nothing is playing).
    // p_live: the PC's sample is real (not a filler zero). live: the reader is running and has a sample to give.
    reg [8:0]         avail = 9'd0;
    reg               t1 = 1'b0, t2 = 1'b0, t3 = 1'b0;
    reg signed [15:0] h_l = 16'sd0, h_r = 16'sd0;      // the radio's sample of this tick
    reg signed [15:0] p_l = 16'sd0, p_r = 16'sd0;      // the PC's sample of this tick
    reg               p_live = 1'b0;
    wire              live = run && stream_on && (avail != 9'd0);

    // At a tick: pop the FIFO one clock later if a sample is being played; run starts when START samples have gathered
    // and stops after an under-run; the radio's and the PC's samples are copied for the steps below.
    always @(posedge clk) begin
        avail    <= r_avail;
        r_pop    <= s_v && live && !rst;
        ev_under <= 1'b0;
        t1       <= s_v;
        if (rst || !stream_on) begin
            run <= 1'b0;
        end else if (!run) begin
            if (avail >= START[8:0]) run <= 1'b1;
        end else if (s_v && avail == 9'd0) begin
            run      <= 1'b0;
            ev_under <= 1'b1;
        end
        if (s_v) begin
            h_l    <= s_l;
            h_r    <= s_r;
            p_l    <= live ? $signed(r_data[15:0])  : 16'sd0;
            p_r    <= live ? $signed(r_data[31:16]) : 16'sd0;
            p_live <= live;
        end
    end

    // ---------------------------------------------------------------- monitor, loop-back
    // One clock after t1 the two output streams are formed: the monitor sum saturates, the loop-back picks the PC's sample.
    always @(posedge clk) begin
        m_v <= t1;
        c_v <= t1;
        if (t1) begin
            m_l <= monitor ? sat17({h_l[15], h_l} + {p_l[15], p_l}) : h_l;
            m_r <= monitor ? sat17({h_r[15], h_r} + {p_r[15], p_r}) : h_r;
            c_l <= loopback ? p_l : h_l;
            c_r <= loopback ? p_r : h_r;
        end
    end

    // ---------------------------------------------------------------- peak meters
    // Per tick the larger magnitude of the two channels is formed (mg_p for the playback sample, mg_c for the stream to the
    // PC), and the running peaks pk_play and pk_cap keep the largest one until they are cleared.
    reg [14:0] mg_p = 15'd0, mg_c = 15'd0;
    always @(posedge clk) begin
        t2 <= t1;
        t3 <= t2;
        if (t1) mg_p <= (mag(p_l) > mag(p_r)) ? mag(p_l) : mag(p_r);
        if (t2) mg_c <= (mag(c_l) > mag(c_r)) ? mag(c_l) : mag(c_r);
        if (rst || pk_clr_play)          pk_play <= 15'd0;
        else if (t2 && mg_p > pk_play)   pk_play <= mg_p;
        if (rst || pk_clr_cap)           pk_cap <= 15'd0;
        else if (t3 && mg_c > pk_cap)    pk_cap <= mg_c;
    end

    // ---------------------------------------------------------------- CPU FIFO
    // Pointers have 11 bits for 1,024 words, the top bit telling a full FIFO from an empty one. wp: write pointer. rp: read pointer.
    // wp_d, wp_vis: the write pointer delayed twice, so the level shown to the reader is only raised after the RAM has
    // had time to take the word.
    reg [10:0] wp = 11'd0, rp = 11'd0, wp_d = 11'd0, wp_vis = 11'd0;
    wire       full = (wp[10] != rp[10]) && (wp[9:0] == rp[9:0]);
    // the microphone's sample goes through a register of this unit, so the long wire from the USB host block ends in a flip-flop
    reg               xq_v = 1'b0;
    reg signed [15:0] xq_l = 16'sd0, xq_r = 16'sd0;
    always @(posedge clk) begin
        xq_v <= x_v && ext_sel;
        xq_l <= x_l;
        xq_r <= x_r;
    end
    // A word is pushed per PC sample (only real ones, p_live) or per microphone sample, whichever source is chosen.
    wire        push  = fifo_en && (ext_sel ? xq_v : (t1 && p_live));
    wire [31:0] pword = ext_sel ? {xq_r, xq_l} : {p_r, p_l};
    // Pointers: a push advances the write pointer unless the FIFO is full (then it is counted as dropped); a read of
    // the firmware (f_pop) advances the read pointer if a word is visible. Everything is cleared while the CPU FIFO is off.
    always @(posedge clk) begin
        ev_fover <= 1'b0;
        if (rst || !fifo_en) begin
            wp <= 11'd0; rp <= 11'd0; wp_d <= 11'd0; wp_vis <= 11'd0; f_level <= 11'd0;
        end else begin
            wp_d    <= wp;
            wp_vis  <= wp_d;
            f_level <= wp_vis - rp;
            if (push) begin
                if (!full) wp <= wp + 11'd1;
                else       ev_fover <= 1'b1;
            end
            if (f_pop && wp_vis != rp) rp <= rp + 11'd1;
        end
    end
    // The memory: 1,024 words of 32 bits, written at the write pointer and read, one clock later, at the read pointer.
    bk_ram #(.DW(32), .AW(10)) u_ram (
        .clk(clk), .we(push && !full), .waddr(wp[9:0]), .wdata(pword),
        .raddr(rp[9:0]), .rdata(f_word)
    );

endmodule
