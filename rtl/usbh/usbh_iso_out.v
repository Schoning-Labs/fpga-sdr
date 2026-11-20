// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// usbh_iso_out: the speaker stream of the USB host (docs/USB_HOST.md section 5): the radio's 48 kHz samples as one isochronous OUT
// packet per frame, sent by usbh_port.v to a headset or a USB sound card. Isochronous transfers (one packet per 1 ms frame, no
// handshake, no retry) are explained in rtl/usb/usb_ep_cap.v, and this module is the same job seen from the other end.
// It takes the radio's stereo stream from usbh_top.v (the stream that the digital outputs get), passes it through a FIFO from the 120 MHz
// radio clock to the 48 MHz USB clock, and at every start of frame prepares the packet that the port then reads byte by byte.
//
// Made from rtl/usb/usb_ep_cap.v (the device's recording endpoint, the same job seen from the
// other end): a 128-sample dual-clock FIFO, and at every start of frame a packet of all complete samples
// waiting, `max_samp` at most. The frame clock and the radio's sample clock come from one PLL, so that is 48
// per frame; the limit is there for the first frames and for a FIFO that got ahead. Here the host owns the frame, and the radio's 48 kHz tick is
// 2,500 clocks of 120 MHz while a frame is 48,000 clocks of 48 MHz, both derived from the same 1,200 MHz oscillator
// of the PLL (divided by 25 and by 10), which is why exactly 48 samples arrive per frame and no feedback is needed.
//
// Format, from the device's descriptors: `mono` sends one channel, (left + right) / 2; `bytes3` sends 3-byte
// samples (the low byte 0). Little-endian, left first (USB Audio Data Formats 2.2.1). The packet's length in bytes is the
// number of samples times 2 (mono, 16 bit), 3 (mono, 24 bit), 4 (stereo, 16 bit) or 6 (stereo, 24 bit).
//
// While `enable` is low the FIFO is kept empty. A sample that finds it full is dropped (ev_over, clk_aud).
//
// Latency: a sample waits in the FIFO until the next start of frame, so up to 1 ms, then goes out within that frame; the
// length of the packet is ready 2 clocks after the SOF pulse, long before the port needs it.
//
// Gowin specifics: the FIFO is 128 x 32 bits in LUT RAM (usb_afifo.v with LUTRAM = 1), and the mono mix is one 17-bit add; no DSP block. Terms are in
// docs/learn/GLOSSARY.md.

`timescale 1ns / 1ps

// no parameters
module usbh_iso_out (
    input  wire        clk_usb,  // 48 MHz USB clock
    input  wire        rst_usb,  // synchronous reset of the USB side
    input  wire        enable,  // 1 = the speaker stream is on (from the firmware); else the FIFO is kept empty
    input  wire        mono,  // 1 = send one channel, the mean of left and right
    input  wire        bytes3,  // 1 = 3-byte samples (24 bit, the low byte 0), else 2-byte samples
    input  wire [5:0]  max_samp,  // the most samples to put in one packet, set by the firmware (48, or 49 where the device allows it)
    input  wire        sof,  // one-clock pulse at each start of frame: fixes the size of the packet
    output reg  [9:0]  len = 10'd0,  // bytes in the packet
    output reg  [7:0]  data = 8'd0,  // the byte at the current position of the packet
    input  wire        rd,  // one-clock pulse: usbh_port.v took the byte, step on
    input  wire        commit,  // one-clock pulse: the packet was sent, free its samples
    output wire [7:0]  fill,  // samples waiting in the FIFO (for the firmware's status read-out)
    // audio side
    input  wire        clk_aud,  // radio clock, 120 MHz
    input  wire        rst_aud,  // synchronous reset of the radio side
    input  wire        aud_valid,  // one-clock pulse per 48 kHz sample
    input  wire signed [15:0] aud_l,  // left sample, signed 16 bit
    input  wire signed [15:0] aud_r,  // right sample, signed 16 bit
    output reg         ev_over = 1'b0  // one-clock pulse per dropped sample (FIFO full)
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;

    // wfree: free FIFO entries (write side). word: the FIFO's output {R, L}. avail: samples waiting (0 to 128).
    // nsamp: samples in the packet being prepared. sof_d: the SOF pulse one clock later, when nsamp is settled and the length is formed.
    wire [7:0]  wfree;
    wire [31:0] word;
    wire [7:0]  avail;
    reg  [5:0]  nsamp = 6'd0;
    reg         sof_d = 1'b0;
    reg         ch = 1'b0;            // 0 left (or the one mono channel), 1 right
    reg  [1:0]  bidx = 2'd0;          // byte within the sample (0 to 1, or 0 to 2 with 3-byte samples)
    // last_b: the byte now due is the last of its channel; last_c: and the channel is the last one. pop: the sample is used up after its last byte.
    wire        last_b = (bidx == (bytes3 ? 2'd2 : 2'd1));
    wire        last_c = mono || ch;
    wire        pop = rd && last_b && last_c;
    assign fill = avail;

    // A dropped sample is one that arrives while the FIFO is full.
    always @(posedge clk_aud) ev_over <= aud_valid && (wfree == 8'd0) && !rst_aud;

    // The sample being sent: the mono mean is the sum of both channels shifted right by 1 bit (a 17-bit sum); otherwise the channel now due.
    wire signed [16:0] sum = $signed(word[15:0]) + $signed(word[31:16]);
    wire [15:0] samp = mono ? sum[16:1] : ch ? word[31:16] : word[15:0];
    // The byte now due: registered, read by the port at least 32 clocks after `rd`. bsel 0 is the zero padding byte of a 3-byte sample, 1 its low and 2 its high byte.
    wire [1:0]  bsel = bytes3 ? bidx : bidx + 2'd1;      // 0 the padding byte, 1 low, 2 high
    always @(posedge clk_usb) data <= (bsel == 2'd0) ? 8'd0 : (bsel == 2'd1) ? samp[7:0] : samp[15:8];

    // n1 and n2: the sample count times 1 and times 2, to form the length without a multiplier.
    wire [9:0] n2 = {3'd0, nsamp, 1'b0};
    wire [9:0] n1 = {4'd0, nsamp};
    // At a SOF the packet size becomes the number of waiting samples, at most max_samp; one clock later the length in bytes is formed;
    // the end of the packet clears them; each byte read steps through the bytes and channels of the sample.
    always @(posedge clk_usb) begin
        sof_d <= sof;
        if (rst_usb || !enable) begin
            nsamp <= 6'd0;
            len   <= 10'd0;
            ch    <= 1'b0;
            bidx  <= 2'd0;
        end else begin
            if (sof) nsamp <= (avail > {2'd0, max_samp}) ? max_samp : avail[5:0];
            // bytes = samples x (channels x bytes per sample): 2, 3, 4 or 6
            if (sof_d) len <= mono ? (bytes3 ? n2 + n1 : n2) : (bytes3 ? {n2[8:0], 1'b0} + n2 : {n2[8:0], 1'b0});
            if (commit) begin
                nsamp <= 6'd0;
                len   <= 10'd0;
                ch    <= 1'b0;
                bidx  <= 2'd0;
            end else if (rd) begin
                if (last_b) begin
                    bidx <= 2'd0;
                    ch   <= last_c ? 1'b0 : 1'b1;
                end else begin
                    bidx <= bidx + 2'd1;
                end
            end
        end
    end

    // The FIFO: written on the audio clock, a push per sample, committed at once; read on the USB clock, popped after a sample's last
    // byte, committed at the end of the packet, flushed while the stream is off.
    usb_afifo #(.W(32), .AW(7), .LUTRAM(1)) u_fifo (
        .wclk(clk_aud), .wrst(rst_aud),
        .w_push(aud_valid), .w_data({aud_r, aud_l}), .w_commit(1'b1), .w_abort(1'b0),
        .w_free(wfree),
        .rclk(clk_usb), .rrst(rst_usb),
        .r_pop(pop), .r_commit(commit), .r_rewind(1'b0), .r_flush(!enable),
        .r_data(word), .r_avail_c(avail), .r_avail_t()
    );

endmodule
