// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// usbh_iso_in: the microphone stream of the USB host (docs/USB_HOST.md section 5): the bytes of the device's isochronous IN
// packets become 16-bit stereo samples and cross to the radio's clock. It takes the bytes that usbh_port.v receives once per
// frame from a headset or a sound card (si_wr, si_data), puts them together to samples, passes them through a 128-entry FIFO
// (rtl/usb/usb_afifo.v) from the 48 MHz USB clock to the 120 MHz radio clock, and hands them to usb_play.v as the second source of its CPU
// FIFO (usb.ctrl.speech_src), through usbh_top.v. Isochronous transfers (one packet per 1 ms frame, no handshake, no
// retry) are explained in rtl/usb/usb_ep_cap.v.
//
// Nothing here knows the sample rate: what comes is passed on, one `m_v` pulse per sample frame, at the device's own rate
// (the firmware's resampler does the rest). The device is the master of this stream: a microphone has its own crystal and puts
// whatever it recorded into each packet, typically 48 samples per frame for a 48 kHz device and 44 or 45 for 44.1 kHz, so the
// number of samples per frame is not fixed, and it cannot be assumed to match the radio's 48 kHz tick. The firmware reads
// the count (`m_count`) to find the true rate and converts it to the radio's rate.
//
// Format, from the device's descriptors: `mono` = one channel, copied to both outputs; `bytes3` = 3-byte
// samples, of which the upper two are taken (the lowest byte of a 24-bit sample is dropped). A packet is only passed on when its CRC was good (commit); a
// damaged one is dropped whole (abort) and ev_bad_t toggles. A byte count that is not a whole number of sample
// frames loses its last part. The bytes of a sample come little-endian, the left channel first.
//
// m_count counts the samples passed on (wraps), for a rate read-out.
//
// Latency: a sample is released at the packet's commit and reaches the radio side a few clocks later (the pointer crossing and
// one pop per 3 clocks), so the delay of the whole path is one frame (1 ms, the packet is only released at its end) plus a few clocks.
//
// Gowin specifics: the FIFO is 128 x 32 bits in LUT RAM (LUTRAM = 1 in usb_afifo.v, which spares block RAM); the two clocks are unrelated, which the timing
// constraints declare. Terms are in docs/learn/GLOSSARY.md.

`timescale 1ns / 1ps

// no parameters
module usbh_iso_in (
    input  wire        clk_usb,  // 48 MHz USB clock
    input  wire        rst_usb,  // synchronous reset of the USB side
    input  wire        enable,  // 1 = the microphone stream is on (from the firmware); else the FIFO is flushed and nothing is passed on
    input  wire        mono,  // 1 = the device sends one channel, copied to left and right
    input  wire        bytes3,  // 1 = 3-byte samples (24 bit), else 2-byte samples (16 bit)
    input  wire        wr,  // one-clock pulse: data is a byte of the packet (CRC bytes already removed by usbh_port.v)
    input  wire [7:0]  data,  // the received byte
    input  wire        commit,  // one-clock pulse at the end of a good packet: make its samples visible
    input  wire        abort,  // one-clock pulse at the end of a bad packet: drop its samples
    output reg         ev_bad_t = 1'b0,  // toggle: flips once per dropped packet (carried to the register page)
    // radio side
    input  wire        clk_aud,  // radio clock, 120 MHz
    input  wire        rst_aud,  // synchronous reset of the radio side
    output reg         m_v = 1'b0,  // one-clock pulse per sample frame
    output reg  signed [15:0] m_l = 16'sd0,  // left sample, signed 16 bit
    output reg  signed [15:0] m_r = 16'sd0,  // right sample, signed 16 bit
    output reg  [31:0] m_count = 32'd0  // number of sample frames passed on since reset, wrapping, for the firmware's rate read-out
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;

    // ch: which channel the next sample is (0 left, 1 right). bidx: byte within the sample. lo: the low byte of the sample being assembled.
    // left: the left sample waiting for its right partner. push, pword: the FIFO write, one clock after the byte that completed it.
    reg         ch = 1'b0;
    reg  [1:0]  bidx = 2'd0;
    reg  [7:0]  lo = 8'd0;
    reg  [15:0] left = 16'd0;
    reg         push = 1'b0;
    reg  [31:0] pword = 32'd0;
    // hi_b, lo_b: the byte now arriving is the high byte (byte 1 of 2, or byte 2 of 3) or the low byte (byte 0 of 2, or byte 1 of 3; with
    // 3 bytes the very first byte, the least significant, is dropped). samp: the 16-bit sample, complete when its high byte is on `data`.
    wire        hi_b = (bidx == (bytes3 ? 2'd2 : 2'd1));
    wire        lo_b = (bidx == (bytes3 ? 2'd1 : 2'd0));
    wire [15:0] samp = {data, lo};

    // Sample assembly on the USB clock. A new packet, a commit, an abort or a stopped stream restarts the sample alignment; each byte
    // is stored or completes a sample: mono gives the same sample on both sides, stereo waits for the right sample after the left one.
    always @(posedge clk_usb) begin
        push <= 1'b0;
        if (rst_usb || !enable || commit || abort) begin
            ch   <= 1'b0;
            bidx <= 2'd0;
        end else if (wr) begin
            if (lo_b) lo <= data;
            if (hi_b) begin
                bidx <= 2'd0;
                if (mono) begin
                    push  <= 1'b1;
                    pword <= {samp, samp};
                end else if (!ch) begin
                    left <= samp;
                    ch   <= 1'b1;
                end else begin
                    push  <= 1'b1;
                    pword <= {samp, left};
                    ch    <= 1'b0;
                end
            end else begin
                bidx <= bidx + 2'd1;
            end
        end
        // each bad packet flips the toggle, for the register page's counter
        if (abort && enable && !rst_usb) ev_bad_t <= ~ev_bad_t;
    end

    // The FIFO (the commit comes at the end of the packet, when the last sample's push, one clock late, is long done).
    wire [7:0]  avail;
    wire [31:0] word;
    reg         pop = 1'b0;
    reg  [1:0]  en_s = 2'b00;
    usb_afifo #(.W(32), .AW(7), .LUTRAM(1)) u_fifo (
        .wclk(clk_usb), .wrst(rst_usb),
        .w_push(push), .w_data(pword), .w_commit(commit), .w_abort(abort),
        .w_free(),
        .rclk(clk_aud), .rrst(rst_aud),
        .r_pop(pop), .r_commit(pop), .r_rewind(1'b0), .r_flush(!en_s[1]),
        .r_data(word), .r_avail_c(avail), .r_avail_t()
    );
    // Radio side: the enable is brought over by two registers; a pop is made when a sample waits, at most one every third clock because
    // the FIFO's read data follows its pointer by a clock; the sample is copied when it is popped and m_v follows one clock later.
    always @(posedge clk_aud) begin
        en_s <= {en_s[0], enable};
        pop  <= (avail != 8'd0) && !pop && !m_v && en_s[1] && !rst_aud;
        m_v  <= pop;
        if (pop) begin
            m_l <= word[15:0];
            m_r <= word[31:16];
        end
        if (rst_aud)  m_count <= 32'd0;
        else if (m_v) m_count <= m_count + 32'd1;
    end

endmodule
