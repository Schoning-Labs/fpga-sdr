// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ladder_pt8211: a fixed 1 kHz tone on the PT8211 stereo DAC, used as step 3 of the bring-up ladder (rtl/top/ladder_top.v,
// docs/LADDER.md), with nothing else in the path (no ring, no interpolator, no engine), so that a silent or wrong tone
// names the DAC, its three pins or the clock and nothing else.
//
// WHAT THE PT8211 NEEDS
// The PT8211 is a 16-bit stereo DAC (digital-to-analog converter, the chip that turns sample numbers into the voltage
// at the headphone jack) with a serial input of three wires: a bit clock (BCK), a word select (WS) that says which channel the
// bits belong to, and the data (DIN). Its format is the LSB-justified one, also called "Japanese format": WS high means the
// left channel, 16 bits go out per channel, most significant bit first, and the data changes on the falling edge of the bit
// clock so that it is stable when the DAC samples it on the rising edge. A frame is two channels of 16 bits, 32 bit clocks,
// and one frame is one audio sample for both channels. The serializer of the radio itself is rtl/audio/audio_pt8211_tx.v;
// this file writes the same protocol out again in a form of its own, so that the ladder does not depend on the audio files.
//
// HOW IT WORKS
// 1. The bit clock is 32 x 48 kHz = 1.536 MHz (the PT8211 takes up to 18.4 MHz). It is made from the 120 MHz clock by a phase
//    accumulator: a 32-bit counter that adds BCK_INC every clock and whose carry out marks a bit clock edge, the way
//    rtl/audio/audio_nco_tick.v makes its ticks. Because 120 MHz is not a whole multiple of 3.072 MHz, the edges fall on every
//    39th or 40th clock, which moves a bit clock edge by up to 8.3 ns and does not matter to the DAC.
// 2. A 5-bit bit index counts the rising edges, 0 to 31 per frame, and the end of the 32nd bit gives frame_tick, one clock
//    wide, once per 48 kHz frame.
// 3. A table of 48 sample values makes one period of a sine wave, so one new value per frame at 48 kHz gives
//    48 kHz / 48 = exactly 1 kHz. The amplitude is 6000 of 32767 (-14.7 dBFS), and the same word goes to both channels.
// 4. On every falling bit clock edge, WS and DIN are updated together with the next bit, half a bit period before the
//    rising edge that the DAC uses.
// Pins (docs/BOARD.md, Sipeed audio/audio.cst, dock schematic I2S_BCLK / I2S_LRCK / I2S_DIN): bit clock E22, word select F24,
// data G24.

`timescale 1ns / 1ps

module ladder_pt8211 #(
    // phase increment of the accumulator: round(2 x 1,536,000 / 120,000,000 x 2^32), two bit-clock edges per accumulator wrap
    parameter [31:0] BCK_INC = 32'd109_951_163
) (
    input  wire clk,            // clock, clk_dsp 120 MHz
    input  wire rst,  // synchronous reset, high = reset
    output reg  bck,  // PT8211 bit clock, 1.536 MHz (E22)
    output reg  ws,  // PT8211 word select, 48 kHz, high = left channel (F24)
    output reg  din,  // PT8211 serial data, most significant bit first (G24)
    output wire frame_tick      // one clk_dsp clock wide, once per 48 kHz frame, at the end of the last bit
);
    // Bit clock generator: acc adds BCK_INC every clock; acc_n is the sum with one extra bit for the carry, and a carry
    // (edge_tick) toggles bck. The carry comes at 3.072 MHz, so bck toggles at that rate and runs at 1.536 MHz.
    reg [31:0] acc = 32'd0;
    wire [32:0] acc_n = {1'b0, acc} + {1'b0, BCK_INC};
    wire        edge_tick = acc_n[32];
    always @(posedge clk) begin
        if (rst) begin acc <= 32'd0; bck <= 1'b0; end
        else begin
            acc <= acc_n[31:0];
            if (edge_tick) bck <= ~bck;
        end
    end

    // bck delayed by one clock, to find the rising and falling edges of bck as one-clock pulses in the clk_dsp domain
    reg bck_d = 1'b0;
    always @(posedge clk) bck_d <= bck;
    wire bck_rise = bck & ~bck_d;
    wire bck_fall = ~bck & bck_d;

    // idx = index of the bit captured at the next rising edge: 0..15 right channel MSB first, 16..31 left channel
    reg [4:0] idx = 5'd0;
    always @(posedge clk) begin
        if (rst) idx <= 5'd0;
        else if (bck_rise) idx <= idx + 5'd1;
    end
    assign frame_tick = bck_rise & (idx == 5'd31);

    // the tone: one table entry per frame; ph is the position in the period (0 to 47) and s is the sample value,
    // 6000 x sin(2 pi ph / 48) rounded to an integer
    reg [5:0] ph = 6'd0;
    reg signed [15:0] s;
    always @(*) begin
        case (ph)
            6'd0: s = 16'sd0;
            6'd1: s = 16'sd783;
            6'd2: s = 16'sd1553;
            6'd3: s = 16'sd2296;
            6'd4: s = 16'sd3000;
            6'd5: s = 16'sd3653;
            6'd6: s = 16'sd4243;
            6'd7: s = 16'sd4760;
            6'd8: s = 16'sd5196;
            6'd9: s = 16'sd5543;
            6'd10: s = 16'sd5796;
            6'd11: s = 16'sd5949;
            6'd12: s = 16'sd6000;
            6'd13: s = 16'sd5949;
            6'd14: s = 16'sd5796;
            6'd15: s = 16'sd5543;
            6'd16: s = 16'sd5196;
            6'd17: s = 16'sd4760;
            6'd18: s = 16'sd4243;
            6'd19: s = 16'sd3653;
            6'd20: s = 16'sd3000;
            6'd21: s = 16'sd2296;
            6'd22: s = 16'sd1553;
            6'd23: s = 16'sd783;
            6'd24: s = 16'sd0;
            6'd25: s = -16'sd783;
            6'd26: s = -16'sd1553;
            6'd27: s = -16'sd2296;
            6'd28: s = -16'sd3000;
            6'd29: s = -16'sd3653;
            6'd30: s = -16'sd4243;
            6'd31: s = -16'sd4760;
            6'd32: s = -16'sd5196;
            6'd33: s = -16'sd5543;
            6'd34: s = -16'sd5796;
            6'd35: s = -16'sd5949;
            6'd36: s = -16'sd6000;
            6'd37: s = -16'sd5949;
            6'd38: s = -16'sd5796;
            6'd39: s = -16'sd5543;
            6'd40: s = -16'sd5196;
            6'd41: s = -16'sd4760;
            6'd42: s = -16'sd4243;
            6'd43: s = -16'sd3653;
            6'd44: s = -16'sd3000;
            6'd45: s = -16'sd2296;
            6'd46: s = -16'sd1553;
            6'd47: s = -16'sd783;
            default: s = 16'sd0;
        endcase
    end
    // cur = the sample that is being sent in the current frame; it changes only at frame_tick, so it is stable for all 32
    // bits of a frame, and ph moves on to the next table entry at the same time
    reg signed [15:0] cur = 16'sd0;
    always @(posedge clk) begin
        if (rst) begin ph <= 6'd0; cur <= 16'sd0; end
        else if (frame_tick) begin
            cur <= s;
            ph  <= (ph == 6'd47) ? 6'd0 : ph + 6'd1;
        end
    end

    // WS and DIN change together on the falling bit-clock edge, half a bit period before the capturing edge. The bit
    // that comes next is bit 15 - idx[3:0] of the sample (most significant first), and WS is idx[4]: 0 for the first
    // 16 bits of a frame and 1 for the second 16 (the left channel).
    wire [3:0] bit_sel = idx[3:0];
    wire       next_bit = cur[4'd15 - bit_sel];
    always @(posedge clk) begin
        if (rst) begin ws <= 1'b0; din <= 1'b0; end
        else if (bck_fall) begin ws <= idx[4]; din <= next_bit; end
    end
endmodule
