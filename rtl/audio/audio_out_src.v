// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// audio_out_src: the one 48 kHz stereo stream that never stops, for the digital audio outputs.
//
// What it does
//   The audio engine's 48 kHz tap (`hdmi_valid` of audio_ring_reader.v, one pulse per sample it hands to the
//   PT8211 path) only pulses while the engine is enabled and its ring is being fed.  An HDMI monitor and an S/PDIF
//   receiver, however, expect a stream that keeps running, and lose their lock or mute (with a click when the
//   sound comes back) if it stops.  This block keeps the rate going:
//     - a sample from the engine is passed on as it comes;
//     - when none has come for PERIOD + GRACE clocks, a zero sample (silence) is sent, and from then on one more
//       every PERIOD clocks (120 MHz / 2,500 = 48 kHz exactly) until the engine delivers again.
//   The GRACE clocks make sure that a sample from the engine that is only slightly late is taken as the real one
//   and is not preceded by a silent sample, which would put a gap into the sound.
//
// Test tone
//   With `tone` high, every sample that is sent is replaced by a 1 kHz sine wave in both channels: 48 values per
//   period (48 kHz / 1 kHz), amplitude 20,000 out of 32,767 (-4.3 dBFS).  That gives a test signal for all three
//   digital outputs that needs neither firmware nor DDR3.  The table is 20,000 x sin(2 pi p / 48), rounded.
//
// Where it sits in the radio
//   Fed by: the HDMI tap of audio_engine.v.  Feeds: audio_digital_out.v (S/PDIF and I2S, with 8 zero bits added below the
//   16-bit samples) and the HDMI audio packets in rtl/video/sdr_hdmi_video.v.  docs/AUDIO_OUT.md, section 2.
//
// Cost
//   No multiplier and no memory block: a 13-bit counter, a 6-bit phase counter and a 48-entry constant table in LUTs.

`timescale 1ns / 1ps

module audio_out_src #(
    // PERIOD is the number of clk_dsp clocks per 48 kHz sample.  GRACE is how many clocks after PERIOD the engine
    // may be late before a silent sample is sent in its place.
    parameter integer PERIOD = 2500,       // clocks per sample at the nominal rate
    parameter integer GRACE  = 16          // extra clocks the engine may be late before a zero sample is sent
) (
    // Clock (clk_dsp, 120 MHz) and synchronous reset (active high).
    input  wire               clk,
    input  wire               rst,
    input  wire               in_v,        // engine tap: one clock pulse per sample
    input  wire signed [15:0] in_l,        // engine tap: left sample, signed 16 bit, valid with in_v
    input  wire signed [15:0] in_r,        // engine tap: right sample, signed 16 bit, valid with in_v
    input  wire               tone,        // 1 = send the 1 kHz test tone instead of the stream
    output reg                s_v,         // one clock pulse per 48 kHz sample, never stops
    output reg  signed [15:0] s_l,         // left sample, signed 16 bit, valid with s_v and held until the next
    output reg  signed [15:0] s_r,         // right sample, same
    output reg                live         // 1 = the last sample sent came from the engine, 0 = silence or tone
);
    // One period of the test tone: sine48(p) = round(20000 x sin(2 pi p / 48)), p = 0 .. 47.
    function signed [15:0] sine48(input [5:0] p);
        case (p)
            6'd0:  sine48 = 16'sd0;      6'd1:  sine48 = 16'sd2611;   6'd2:  sine48 = 16'sd5176;
            6'd3:  sine48 = 16'sd7654;   6'd4:  sine48 = 16'sd10000;  6'd5:  sine48 = 16'sd12175;
            6'd6:  sine48 = 16'sd14142;  6'd7:  sine48 = 16'sd15867;  6'd8:  sine48 = 16'sd17321;
            6'd9:  sine48 = 16'sd18478;  6'd10: sine48 = 16'sd19319;  6'd11: sine48 = 16'sd19829;
            6'd12: sine48 = 16'sd20000;  6'd13: sine48 = 16'sd19829;  6'd14: sine48 = 16'sd19319;
            6'd15: sine48 = 16'sd18478;  6'd16: sine48 = 16'sd17321;  6'd17: sine48 = 16'sd15867;
            6'd18: sine48 = 16'sd14142;  6'd19: sine48 = 16'sd12175;  6'd20: sine48 = 16'sd10000;
            6'd21: sine48 = 16'sd7654;   6'd22: sine48 = 16'sd5176;   6'd23: sine48 = 16'sd2611;
            6'd24: sine48 = 16'sd0;      6'd25: sine48 = -16'sd2611;  6'd26: sine48 = -16'sd5176;
            6'd27: sine48 = -16'sd7654;  6'd28: sine48 = -16'sd10000; 6'd29: sine48 = -16'sd12175;
            6'd30: sine48 = -16'sd14142; 6'd31: sine48 = -16'sd15867; 6'd32: sine48 = -16'sd17321;
            6'd33: sine48 = -16'sd18478; 6'd34: sine48 = -16'sd19319; 6'd35: sine48 = -16'sd19829;
            6'd36: sine48 = -16'sd20000; 6'd37: sine48 = -16'sd19829; 6'd38: sine48 = -16'sd19319;
            6'd39: sine48 = -16'sd18478; 6'd40: sine48 = -16'sd17321; 6'd41: sine48 = -16'sd15867;
            6'd42: sine48 = -16'sd14142; 6'd43: sine48 = -16'sd12175; 6'd44: sine48 = -16'sd10000;
            6'd45: sine48 = -16'sd7654;  6'd46: sine48 = -16'sd5176;  6'd47: sine48 = -16'sd2611;
            default: sine48 = 16'sd0;
        endcase
    endfunction

    // cnt counts clk_dsp clocks since the last sample was sent (0 .. PERIOD + GRACE - 1) and decides when the
    // engine is late.  ph is the position in the tone table, advancing on every sample sent.
    reg [12:0] cnt = 13'd0;
    reg [5:0]  ph = 6'd0;
    // the table's output in a register: the next sample's tone value. Kept in LUTs: a block RAM for 48 words
    // would be a waste (the first synthesis run took one)
    reg signed [15:0] tone_q /* synthesis syn_romstyle = "distributed_rom" */;
    initial tone_q = 16'sd0;
    // late is high on the clock where the engine has been silent for PERIOD + GRACE clocks.  A sample is sent
    // on that clock, or on any clock where the engine delivers one (emit).
    wire late = (cnt == PERIOD + GRACE - 1);
    wire emit = in_v || late;

    initial begin s_v = 1'b0; s_l = 16'sd0; s_r = 16'sd0; live = 1'b0; end

    // Sequencer.  An engine sample restarts the clock count from zero; a late sample restarts it at GRACE, so
    // that the next silent sample follows exactly PERIOD clocks later.

    always @(posedge clk) begin
        s_v    <= 1'b0;
        tone_q <= sine48(ph);
        if (rst) begin
            cnt <= 13'd0; ph <= 6'd0; s_l <= 16'sd0; s_r <= 16'sd0; live <= 1'b0;
        end else begin
            if (in_v)      cnt <= 13'd0;
            else if (late) cnt <= GRACE[12:0];
            else           cnt <= cnt + 13'd1;
            if (emit) begin
                s_v  <= 1'b1;
                live <= in_v;
                ph   <= (ph == 6'd47) ? 6'd0 : ph + 6'd1;
                s_l  <= tone ? tone_q : (in_v ? in_l : 16'sd0);
                s_r  <= tone ? tone_q : (in_v ? in_r : 16'sd0);
            end
        end
    end
endmodule
