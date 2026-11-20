// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Taken from an earlier design by the same author; modified 2026
// by Franz Schöning for fpga-sdr: 16-bit samples (4 bytes per stereo sample), the overflow as an event pulse
// instead of a counter (the counter is in usb_regs.v). docs/USB_AUDIO.md section 4.
//
// usb_ep_cap: the recording endpoint of the USB sound card, isochronous IN endpoint 0x82, which sends the radio's
// receiver audio (48 kHz, 16-bit stereo, asynchronous) to the PC. It is one of the endpoints that usb_audio.v hangs on
// usb_fs_core.v: the radio's samples arrive on the audio clock (clk_aud, the radio's 120 MHz clk_dsp) from
// usb_play.v, cross to the 48 MHz USB clock through a 128-entry FIFO (usb_afifo.v), and leave as packets when the PC asks for
// them. No firmware is involved.
//
// Isochronous transfers, for a beginner. An isochronous endpoint is meant for streams that must keep a steady rate,
// like audio. The host reserves bandwidth for it and asks for data once in every 1 ms frame (an IN token, right
// after the start-of-frame packet, SOF, that opens each frame). The device answers with one data packet, or with
// an empty packet if it has nothing. There is no handshake and no retry: a packet that arrives damaged is of no use
// to a live stream and is simply lost. Audio over USB adds the question of whose clock rules. This endpoint is of the asynchronous kind (USB
// 2.0 section 5.12.4): the radio's 48 kHz comes from its own oscillator and is not tied to the PC's 1 ms frames, so
// the number of samples per packet varies a little and the PC's driver reads the true rate from how many samples
// arrive over time. In the playback direction the device has to tell the PC how many samples it wants, which needs a
// feedback endpoint (usb_ep_play.v); in this direction nothing like that is needed. The samples of one 48 kHz
// stream, 2 bytes per channel, left channel first, are the format of USB Audio Class 1.0 (UAC1 Type I PCM).
//
// How it works. Every sample (aud_valid, once per 48 kHz) is pushed into the FIFO. At every SOF the endpoint reads
// how many complete samples are waiting, takes at most USB_AUDIO_MAX_SAMPLES (49) of them and fixes that as the
// size of the next packet (nsamp): normally 48 per 1 ms
// frame, now and then 47 or 49 because the radio's sample clock and the host's frame clock are independent.
// If the host skips a frame the
// samples wait and go out in later packets (49 per frame drains the backlog). When the IN token comes the core
// reads the packet byte by byte with in_rd: four bytes per sample, so the byte lane counts 0 to 3 and the
// FIFO is popped after the fourth byte. An in_commit at the end of the packet frees the samples for good and
// clears the packet size, so a second IN token in the same frame gets an empty packet.
//
// While the host has not selected alternate setting 1 the FIFO is kept empty (it is flushed while `enable` is
// low), so a recording starts with about 1 ms of latency, and the whole path from the receiver's audio to the
// PC takes between 1 and 2 ms. If the FIFO ever fills (the host stopped polling without switching the interface
// off), new samples are dropped and `ev_over` pulses once for each.
//
// Wire format per sample: L[7:0] L[15:8] R[7:0] R[15:8] (UAC1 Type I PCM, little-endian 2-byte subframes), which is
// the FIFO word {R, L} read as bytes 0 to 3.
//
// Gowin specifics: the FIFO is 128 entries of 32 bits in LUT RAM (usb_afifo.v with LUTRAM = 1), because the block
// RAM of the chip is the scarcer resource and 128 x 32 bits is small; the module's attributes keep the fan-out
// limit high and the synchronizer registers in place. The two clocks are declared unrelated in the timing constraints. See docs/learn/GLOSSARY.md for terms.

`timescale 1ns / 1ps

module usb_ep_cap (
    input  wire        clk_usb,  // 48 MHz USB clock
    input  wire        rst_usb,  // reset of the USB side (synchronous to clk_usb)
    input  wire        enable,       // 1 = the PC has switched the capture interface to alternate setting 1 (stream on); else the FIFO is kept empty
    input  wire        sof,  // one-clock pulse at each start of frame (every 1 ms): fixes the size of the next packet
    output wire        in_ready,  // 1 = an IN packet may be sent (an empty one if no sample is ready)
    output wire [9:0]  in_len,  // bytes in the packet: 4 per sample, 0 to 196
    output wire [7:0]  in_data,  // the byte at the current position of the packet
    input  wire        in_rd,  // one-clock pulse: the core took the byte, step on
    input  wire        in_commit,  // one-clock pulse at the end of the packet: free the samples that were sent
    // audio side
    input  wire        clk_aud,  // audio clock (clk_dsp of the radio, 120 MHz)
    input  wire        rst_aud,  // reset of the audio side (synchronous to clk_aud)
    input  wire        aud_valid,  // one-clock pulse per 48 kHz sample, with aud_l and aud_r
    input  wire [15:0] aud_l,  // left channel, signed 16 bit
    input  wire [15:0] aud_r,  // right channel, signed 16 bit
    output reg         ev_over = 1'b0    // clk_aud: one clock per dropped sample (FIFO full)
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;
    `include "rtl/usb/usb_desc_params.vh"

    // wfree: free FIFO entries (write side). word: the FIFO's output, {R, L}. avail: samples waiting (read side, 0 to 128).
    wire [7:0]  wfree;
    wire [31:0] word;
    wire [7:0]  avail;
    // nsamp: samples in the packet being prepared (at most 49, so 6 bits). lane: which byte of the sample the core reads next.
    // pop: the sample is used up when its fourth byte was read.
    reg  [5:0]  nsamp;
    reg  [1:0]  lane;
    wire        pop = in_rd && (lane == 2'd3);

    // A dropped sample is one that arrives while the FIFO is full; the pulse is registered, one clock long.
    always @(posedge clk_aud) ev_over <= aud_valid && (wfree == 8'd0) && !rst_aud;

    // On the USB clock: at every SOF the packet size becomes the number of waiting samples, capped at 49; an end of packet
    // (in_commit) clears it again; the byte lane runs through 0 to 3 during the read.
    always @(posedge clk_usb) begin
        if (rst_usb || !enable) begin
            nsamp <= 6'd0;
            lane  <= 2'd0;
        end else begin
            if (sof) nsamp <= (avail > USB_AUDIO_MAX_SAMPLES) ? USB_AUDIO_MAX_SAMPLES[5:0] : avail[5:0];
            if (in_commit) begin
                nsamp <= 6'd0;
                lane  <= 2'd0;
            end else if (in_rd) begin
                lane <= lane + 2'd1;
            end
        end
    end

    // 4 bytes per stereo sample, so the length is the sample count times 4 (the two low bits are 0); the byte comes
    // from the sample word at the current lane.
    assign in_ready = enable;
    assign in_len   = {2'd0, nsamp, 2'd0};          // 4 bytes per stereo sample
    assign in_data  = word[8*lane +: 8];

    // The FIFO: write side on the audio clock, a push per sample, committed at once; read side on the USB clock,
    // popped after every fourth byte, committed at the end of the packet, flushed while the stream is off.
    usb_afifo #(.W(32), .AW(7), .LUTRAM(1)) u_fifo (
        .wclk(clk_aud), .wrst(rst_aud),
        .w_push(aud_valid), .w_data({aud_r, aud_l}), .w_commit(1'b1), .w_abort(1'b0),
        .w_free(wfree),
        .rclk(clk_usb), .rrst(rst_usb),
        .r_pop(pop), .r_commit(in_commit), .r_rewind(1'b0), .r_flush(!enable),
        .r_data(word), .r_avail_c(avail), .r_avail_t()
    );

endmodule
