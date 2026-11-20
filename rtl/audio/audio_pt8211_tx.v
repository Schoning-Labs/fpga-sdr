// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// audio_pt8211_tx: serializer for the PT8211 headphone DAC, and source of the 384 kHz frame tick.
//
// What it does
//   Takes the latest 16-bit left and right sample from audio_interp_x8.v and sends them to the PT8211 chip as a
//   serial stream on three wires: BCK (bit clock), WS (word select, which says left or right) and DIN (the data).
//   At the same time it produces the `frame_tick` pulse, once per 32 bit clocks, that tells the interpolator to
//   compute the next 384 kHz sample.  Both come from the same bit counter, so the DAC's clock and the flow of
//   samples can never drift apart.
//
// Where it sits in the radio
//   Fed by: audio_interp_x8.v (samples at 384 kHz).  Feeds: the three PT8211 pins (HP_BCK, HP_WS and HP_DIN, which
//   are pins E22, F24 and G24 on the board, docs/BOARD.md) and, through `frame_tick`, back into the interpolator.
//
// The PT8211 format (the glossary entries "I2S" and "PT8211" in docs/learn/GLOSSARY.md give the background)
//   Many audio DACs use I2S, in which the data of a channel starts one bit clock after the word select edge and
//   the word is padded to the slot width.  The PT8211 uses the LSB-justified ("Japanese") variant instead:
//     - WS low selects the right channel and WS high the left channel;
//     - each channel gets 16 bit clocks, two's complement, most significant bit first, and the last bit (the
//       LSB) lands on the last bit clock before WS changes again, which is what "LSB-justified" means;
//     - a whole frame is 32 bit clocks, so the word rate is BCK / 32 = 12.288 MHz / 32 = 384 kHz.
//   The chip samples DIN on the rising edge of BCK.  This module changes DIN on the falling edge, which leaves half
//   a bit-clock period of setup time (about 40 ns at 12.288 MHz).  The data sheet's timing table allows a bit clock of
//   up to 18.4 MHz (the block diagram text in docs/BOARD.md says 20 MHz, and the table is the one to trust), so
//   12.288 MHz is comfortably inside both figures.
//
// How the clocks are made
//   BCK is made from clk_dsp (120 MHz) by a phase accumulator (audio_nco_tick.v), since 120 MHz / 12.288 MHz is not
//   an integer and a plain divider could not hit the PT8211's 8x oversampled rate.  The accumulator ticks at twice
//   the bit clock and every tick flips BCK.  The edges are therefore on clk_dsp edges, with up to one clock (8.3 ns)
//   of jitter, and the long-run rate is exact to a few thousandths of a part per million (docs/A1_AUDIO.md).
//
// Latency and a timing point to keep in mind
//   The sample pair is held in cur_l and cur_r and read live while the bits go out, so a new pair that arrives
//   while a channel word is on the wire changes the bits still to come in that word.  In audio_engine the
//   interpolator delivers a pair about 25 clocks after `frame_tick`, which is roughly 2.5 bit clocks into the right
//   channel word (a bit clock is 9.8 clocks of 120 MHz), so the first bits of the right word come from the
//   previous pair and the rest from the new one.  The left word starts 16 bit clocks later and is not affected.

`timescale 1ns / 1ps

module audio_pt8211_tx #(
    // CLK_HZ is the frequency of `clk`, BCK_HZ the bit clock of the DAC (the word rate is BCK_HZ / 32).
    parameter integer CLK_HZ = 120_000_000,
    parameter integer BCK_HZ = 12_288_000    // frame (WS) rate = BCK_HZ / 32
) (
    // Clock (clk_dsp, 120 MHz) and synchronous reset (active high).
    input  wire              clk,
    input  wire               rst,

    // The latest interpolated sample pair (signed 16 bit) and a one-clock pulse when it changes.  The module just
    // latches whatever came last, it does not wait for the pulse to line up with the frame.
    input  wire signed [15:0] in_l,
    input  wire signed [15:0] in_r,
    input  wire               in_valid,

    // One clock per 384 kHz frame, high on the clock where a new frame begins.
    output wire                frame_tick,

    // PT8211 pins: bit clock, word select (low = right, high = left) and serial data.
    output reg                 bck,
    output reg                 ws,
    output reg                 din
);

    // ------------------------------------------------------------ BCK generation
    // The NCO ticks at 2 x BCK_HZ and each tick flips the bit clock.  bck_toggle is that tick.
    wire bck_toggle;
    audio_nco_tick #(
        .CLK_HZ (CLK_HZ),
        .TICK_HZ(2 * BCK_HZ)
    ) u_bck_nco (
        .clk (clk),
        .rst (rst),
        .tick(bck_toggle)
    );

    // bck is the bit clock register.
    always @(posedge clk) begin
        if (rst) bck <= 1'b0;
        else if (bck_toggle) bck <= ~bck;
    end

    // bck_d is bck one clock ago, so that a rising edge (bck_rise) and a falling edge (bck_fall) each show up as a
    // one-clock pulse.  Everything below runs on clk_dsp and uses these pulses, so no clock is derived from bck itself.
    reg bck_d;
    always @(posedge clk) bck_d <= bck;
    wire bck_rise = bck && !bck_d;
    wire bck_fall = !bck && bck_d;

    // ------------------------------------------------------------ frame/bit counter
    // idx = index (0..31) of the bit that will be captured at the *next* BCK rising edge:
    // 0-15 = right channel MSB..LSB, 16-31 = left channel MSB..LSB (LSBJ, see header).
    // idx counts the 32 bit clocks of a frame and advances on every BCK rising edge.
    reg [4:0] idx;

    always @(posedge clk) begin
        if (rst) idx <= 5'd0;
        else if (bck_rise) idx <= (idx == 5'd31) ? 5'd0 : (idx + 5'd1);
    end

    // Frame boundary: the BCK rising edge that completes bit 31 and rolls idx back to 0.
    assign frame_tick = bck_rise && (idx == 5'd31);

    // Sample capture: hold the latest sample pair until the next one arrives.
    // ------------------------------------------------------------ sample capture
    reg signed [15:0] cur_l, cur_r;
    always @(posedge clk) begin
        if (rst) begin
            cur_l <= 16'sd0;
            cur_r <= 16'sd0;
        end else if (in_valid) begin
            cur_l <= in_l;
            cur_r <= in_r;
        end
    end

    // ------------------------------------------------------------ WS and DIN, updated together on
    // the BCK falling edge (idx has already advanced to the next bit's index by then), giving a
    // full BCK half-period of setup margin before the rising edge that captures them.
    // word is the channel being sent (idx[4] = 0 right, 1 left), bit_sel counts 0..15 inside the channel, and
    // word[15 - bit_sel] is the next bit to send, most significant first.
    wire signed [15:0] word    = idx[4] ? cur_l : cur_r;
    wire [3:0]         bit_sel = idx[3:0];
    wire                next_bit = word[15 - bit_sel];

    // Present WS and DIN for the next rising edge, on the falling edge.

    always @(posedge clk) begin
        if (rst) begin
            ws  <= 1'b0;
            din <= 1'b0;
        end else if (bck_fall) begin
            ws  <= idx[4];
            din <= next_bit;
        end
    end

endmodule
