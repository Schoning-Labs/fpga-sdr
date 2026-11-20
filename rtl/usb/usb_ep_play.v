// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// usb_ep_play: the playback endpoint of the USB sound card on the USB clock side (docs/USB_AUDIO.md sections 4 and 5):
// isochronous OUT endpoint 0x01 (PC to radio, 48 kHz, 16-bit stereo, asynchronous) and its explicit feedback
// endpoint 0x81. It is one of the endpoints that usb_audio.v hangs on usb_fs_core.v, and it feeds the write side of
// the playback FIFO (usb_afifo.v) whose read side is usb_play.v on the radio's clock. The isochronous transfer basics (one packet per 1 ms frame, no handshake, no
// retry) are described in usb_ep_cap.v; terms are in docs/learn/GLOSSARY.md.
//
// OUT. The packet's bytes are put together to stereo samples (L[7:0] L[15:8] R[7:0] R[15:8]) and pushed into
// the write side of a 256-sample dual-clock FIFO (rtl/usb/usb_afifo.v, instantiated in usb_audio.v, which
// also holds the read side's user usb_play.v). The packet becomes visible to the reader when the packet
// engine commits it (good CRC); a bad packet is dropped whole (w_abort) and counted. A sample that finds the
// FIFO full is dropped and counted; the rest of the packet is treated the same way, sample by sample. A packet of 48
// samples is 192 bytes. A byte that does not complete a sample when the packet ends is thrown away.
//
// Feedback (USB 2.0 section 5.12.4.2). The radio's 48 kHz is the master: the PC has to send as many samples as
// the reader takes, but the PC's own clock runs a little differently from the radio's, so the radio must say how
// many samples per frame it wants. This is what the feedback endpoint is for: the host reads it from time to time
// (an IN endpoint with a 3-byte packet) and adjusts how many samples it sends per frame. At full speed the number is
// a fixed-point value of 10.14 format: 10 bits before the point and 14 after, so that 48.0 samples per frame is
// 48 x 16,384 = 786,432 (FB_NOMINAL, 24 bits, sent low byte first).
// At every start of frame the endpoint computes the number of samples per frame it wants,
// in this format, from the FIFO's fill at that moment:
//
//     wanted = 48 + (TARGET - fill) / 64  samples per frame,   limited to 48 -+ 63/64
//
// fill is taken at the start of frame, before this frame's packet arrives, so it is the low point of the
// cycle. TARGET is 72: when the packet of a frame comes at the very start and that of the next one at the very end,
// the FIFO holds 72 samples at the low point and 24 are still in hand just before the next packet arrives (48 are used up in
// a frame). A proportional loop on the fill: time constant 64 frames (64 ms), and a PC 100 ppm off settles 0.3 samples
// from TARGET (100 ppm of 48 samples is 0.0048 samples per frame, times the loop's 64). No frequency measurement and nothing that can drift.
//
// Latency: the error is taken at the SOF and the feedback value is ready 2 clocks later, long before the host reads it.
//
// ev_over_t and ev_bad_t are toggles (one flip per event) for the counters in usb_regs.v (clk_dsp): a toggle is
// used because it is safe to carry across to the radio's clock, where three registers turn a flip back into a pulse.
//
// Gowin specifics: nothing but ordinary logic; the FIFO behind it is in LUT RAM, see usb_afifo.v.

`timescale 1ns / 1ps

module usb_ep_play #(
    parameter integer TARGET = 72        // samples in the FIFO at a start of frame (see the header: 24 stay in hand)
) (
    input  wire        clk,              // 48 MHz USB clock
    input  wire        rst,  // synchronous reset
    input  wire        enable,           // 1 = configured and the playback AudioStreaming interface is on (alternate setting 1)
    input  wire        sof,  // one-clock pulse at each start of frame (every 1 ms)
    // OUT 0x01, qualified by the endpoint multiplexer
    input  wire        out_wr,  // one-clock pulse: out_data is a byte of the audio packet
    input  wire [7:0]  out_data,  // the byte, in packet order: L low, L high, R low, R high
    input  wire        out_commit,  // one-clock pulse at the end of a good packet
    input  wire        out_abort,  // one-clock pulse at the end of a bad packet
    // feedback IN 0x81
    output wire        in_ready,  // 1 = the feedback packet may be sent
    output wire [9:0]  in_len,  // always 3 bytes
    output wire [7:0]  in_data,  // the feedback byte at the current position
    input  wire        in_rd,  // one-clock pulse: the core took a byte, step on
    input  wire        in_commit,  // one-clock pulse at the end of the feedback packet
    // FIFO write side
    output wire        w_push,  // one-clock pulse: store w_data in the FIFO
    output wire [31:0] w_data,  // the sample, {R, L}, 16 bits each
    output wire        w_commit,  // make the packet's samples visible to the reader
    output wire        w_abort,  // throw away the samples of the packet
    input  wire [8:0]  w_free,  // free entries of the FIFO, 0 to 256
    // events
    output reg         ev_over_t = 1'b0,  // flips when a sample was dropped because the FIFO was full
    output reg         ev_bad_t  = 1'b0  // flips when a bad packet was dropped
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;
    `include "rtl/usb/usb_desc_params.vh"

    // 48 samples per frame in 10.14 format: 48 x 2^14.
    localparam [23:0] FB_NOMINAL = USB_SAMPLE_RATE / 1000 * 16384;   // 48.0 in 10.14

    // ---------------------------------------------------------------- OUT: bytes to samples
    // bcnt: bytes of the sample so far (0 to 3). sh: the first three bytes of the sample, collected from the top down.
    // With the fourth byte the sample is complete: {R high, sh} = {R, L}, and it is pushed into the FIFO.
    reg [1:0]  bcnt = 2'd0;
    reg [23:0] sh = 24'd0;
    assign w_push   = out_wr && (bcnt == 2'd3);
    assign w_data   = {out_data, sh};                 // {R, L}
    assign w_commit = out_commit;
    assign w_abort  = out_abort;

    // The byte count restarts with every packet and while the stream is off, which drops a sample that was left half
    // done; each byte shifts in; a push that finds the FIFO full, or a bad packet, flips an event toggle.
    always @(posedge clk) begin
        if (rst || !enable || out_commit || out_abort) bcnt <= 2'd0;
        else if (out_wr) bcnt <= bcnt + 2'd1;
        if (out_wr) sh <= {out_data, sh[23:8]};
        if (w_push && w_free == 9'd0) ev_over_t <= ~ev_over_t;
        if (out_abort && enable)      ev_bad_t  <= ~ev_bad_t;
    end

    // ---------------------------------------------------------------- feedback
    // fill: samples in the FIFO (256 minus the free entries). err: TARGET minus fill, positive when the FIFO is too empty
    // (so the PC should send more). err_c: err limited to -63 to 63, which keeps the answer within 48 +- 63/64.
    // fb: the feedback value, 24 bits. lane: which feedback byte the core reads next.
    wire [8:0]        fill = 9'd256 - w_free;                     // 0 to 256
    wire signed [9:0] tgt  = TARGET;
    wire signed [9:0] err  = tgt - $signed({1'b0, fill});
    reg  signed [6:0] err_c = 7'sd0;                              // limited to -63 .. 63
    reg               sof_d = 1'b0;
    reg  [23:0]       fb = FB_NOMINAL;
    reg  [1:0]        lane = 2'd0;

    // At a start of frame the error is taken, one clock later the feedback value is formed.
    always @(posedge clk) begin
        sof_d <= sof;
        if (sof)
            err_c <= (err > 10'sd63) ? 7'sd63 : (err < -10'sd63) ? -7'sd63 : err[6:0];
    // one sample of error is 1/64 sample per frame, which in 10.14 format is 2^14/64 = 256, so err_c is shifted left 8
    // (the upper bits are the sign extension)
        // err_c * 256: 1/64 sample per frame for each sample of error
        if (sof_d) fb <= FB_NOMINAL + {{9{err_c[6]}}, err_c, 8'd0};
        if (rst || !enable || in_commit) lane <= 2'd0;
        else if (in_rd) lane <= lane + 2'd1;
    end

    // The packet is 3 bytes: the low, middle and high byte of fb, in that order.
    assign in_ready = enable;
    assign in_len   = 10'd3;
    assign in_data  = (lane == 2'd0) ? fb[7:0] : (lane == 2'd1) ? fb[15:8] : fb[23:16];

endmodule
