// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Taken from an earlier design by the same author.
//
// audio_spdif_tx: S/PDIF (IEC 60958-3, consumer format) transmitter.
//
// What it does
//   Sends a stereo stream of 24-bit samples as one self-clocked serial signal on a single 3.3 V pin, in the
//   format that optical (TOSLINK) and coaxial digital audio inputs of amplifiers, DACs and sound cards understand.
//   The sample rate is 48 kHz by default (96 kHz as a parameter).  The pin is meant to go through an optical
//   transmitter module or a small coupling network on a separate board (docs/AUDIO_OUT.md).  The format is a
//   published open standard (IEC 60958-3, which grew out of the Sony/Philips interface); everything below
//   follows that standard.
//
// Where it sits in the radio
//   Fed by: audio_digital_out.v, which hands over one 24-bit stereo sample per 48 kHz period (the same samples as the HDMI
//   audio).  Feeds: the S/PDIF output pin.  The glossary entry "S/PDIF" in docs/learn/GLOSSARY.md gives a short summary.
//
// What a subframe looks like
//   Each audio frame (one sample period) consists of two 32-slot "subframes", the left channel first and then
//   the right.  A subframe is laid out like this:
//
//     slot:   0  1  2  3 | 4 .......................... 27 | 28 | 29 | 30 | 31
//     field:  ---- preamble ---- | -------- 24-bit sample (LSB first) -------- |  V  |  U  |  C  |  P
//
//   - Preamble (slots 0-3): not data but a fixed waveform that breaks the normal biphase-mark rule (below), so that
//     a receiver finds the start of a subframe without any separate sync wire.  There are three kinds: B marks
//     the first left subframe of a 192-frame channel-status block, M every other left subframe, and W every
//     right subframe.
//   - Sample (slots 4-27): the 24-bit sample, least significant bit first.  The four slots that the standard
//     calls "auxiliary sample bits" simply carry the low four bits of the 24-bit word here.
//   - V (slot 28): validity bit, always 0 here.  The polarity is the convention that consumer receivers assume
//     (0 means valid), but sources word it inconsistently and it has not been checked against a real receiver.
//   - U (slot 29): user data, always 0 (unused, as the standard says for consumer equipment).
//   - C (slot 30): one bit of the 192-bit channel-status block, a different bit in every frame.
//   - P (slot 31): even parity over slots 4 to 31, so that the number of ones in those 28 slots is even.  It is
//     an XOR of the sample bits and V, U and C.
//
// Biphase-mark coding (BMC)
//   S/PDIF has no clock wire.  The receiver recovers the timing from the data itself, because each slot is coded
//   as a pair of "chips" (line levels), so a subframe is 64 chips and a frame is 128 chips (the "bit clock is
//   128 x fs" of the standard: 6.144 MHz at 48 kHz and 12.288 MHz at 96 kHz).  The rule is that the line always
//   changes level at the start of every slot (which is what makes the signal self-clocking, data or not), and
//   changes level a second time in the middle of the slot if the data bit is 1, and stays where it is if the data
//   bit is 0.  A receiver therefore counts one or two changes per slot to recover the bit.  The code has no DC
//   component, which matters for the transformer or the optical module on the far end.
//
//   The preambles are where the rule is broken on purpose.  Each one is eight chips that no legal data sequence
//   can produce (the first three chips hold one level for one and a half slot times, which normal BMC never does).
//   Starting from a line that is at level 0, the three preambles are
//
//     B (block start):          1 1 1 0 1 0 0 0
//     M (ordinary left):        1 1 1 0 0 0 1 0
//     W (every right):          1 1 1 0 0 1 0 0
//
//   and starting from level 1 each one is the complement of its row.  The line level before the preamble decides
//   which of the two waveforms goes out, and the meaning of the preamble does not change.  This module keeps that
//   starting level in `preamble_invert` and applies it to one stored pattern per kind.
//
// Chip rate clock
//   120 MHz / 6.144 MHz = 19.53125 (and 120 MHz / 12.288 MHz = 9.765625) are not integers, so a plain divider
//   cannot make the chip clock.  A phase accumulator (audio_nco_tick.v, TICK_HZ = 128 x SAMPLE_RATE) does it from
//   `clk` without a new clock resource.  An edge can be up to one clock period early or late (8.3 ns at 120 MHz),
//   and the long-run rate is off by -0.0025 ppm at 48 kHz and +0.0003 ppm at 96 kHz, which is far inside what S/PDIF
//   receivers tolerate.  A dedicated PLL output at the exact chip rate would have less jitter, but 6.144 MHz / 50 MHz is
//   384/3125 in lowest terms, which no integer PLL divider can make exactly, so it would need a fractional
//   PLL or another reference; whether the GW5A PLL has a fractional mode was not checked, and nothing here has shown
//   that a receiver needs the lower jitter.  In audio_digital_out.v the module runs from a 49.152 MHz clock (exactly 1,024 x 48 kHz),
//   where one chip is exactly 8 clocks and the accumulator steps by exactly 2^29.
//
// Interface
//   `in_valid`, `in_l` and `in_r` use the same "latch whatever is newest" convention as audio_pt8211_tx.v: the module
//   takes the pair on any clock where in_valid is high and does not pace the source.  SAMPLE_RATE must match the
//   rate of the source.  The module's chip clock and the source's sample clock run independently, so over a
//   long time one of them repeats or drops a sample against the other, which is far below audibility.  In
//   audio_digital_out.v the word is given to this module during the left preamble, which is when it is taken safely.
//   `spdif_out` is the raw line level (3.3 V LVCMOS) for the coupling network, not a DAC pin; S/PDIF has no word
//   clock or bit clock wire next to it.
//
// Dependency
//   audio_nco_tick.v is not `include`d here.  The top level or testbench that uses this module lists every file
//   once.

`timescale 1ns / 1ps

module audio_spdif_tx #(
    // CLK_HZ is the frequency of `clk`, SAMPLE_RATE the audio sample rate (48000 or 96000), ACC_WIDTH the width
    // of the chip clock's phase accumulator.
    parameter integer CLK_HZ      = 120_000_000,
    parameter integer SAMPLE_RATE = 48000,   // 48000 or 96000, matches audio_out.v's HDMI_RATE
    parameter integer ACC_WIDTH   = 32
) (
    // Clock and synchronous reset (active high).
    input  wire               clk,
    input  wire               rst,

    // Stereo sample input (signed 24 bit), taken whenever in_valid is high.
    input  wire               in_valid,
    input  wire signed [23:0] in_l,
    input  wire signed [23:0] in_r,

    // S/PDIF line level, one chip per 128 x SAMPLE_RATE tick.
    output reg                spdif_out
);

    // ---------------------------------------------------------------- chip-rate clock (see header)
    wire chip_tick;
    audio_nco_tick #(
        .CLK_HZ (CLK_HZ),
        .TICK_HZ(128 * SAMPLE_RATE),
        .ACC_WIDTH(ACC_WIDTH)
    ) u_chip_nco (
        .clk (clk),
        .rst (rst),
        .tick(chip_tick)
    );

    // ---------------------------------------------------------------- sample capture (as audio_pt8211_tx.v)
    reg signed [23:0] cur_l, cur_r;
    reg               par_l, par_r;   // each sample's parity bit, worked out when the sample is taken so that
                                      // no 24-bit XOR sits in front of the line level
    always @(posedge clk) begin
        if (rst) begin
            cur_l <= 24'sd0;
            cur_r <= 24'sd0;
            par_l <= 1'b0;
            par_r <= 1'b0;
        end else if (in_valid) begin
            cur_l <= in_l;
            cur_r <= in_r;
            par_l <= ^in_l;
            par_r <= ^in_r;
        end
    end

    // ---------------------------------------------------------------- channel-status block
    // The channel status is a 192-bit block, one bit sent in slot 30 of every frame, in the consumer layout of
    // IEC 60958-3.  Bytes 5 to 23 (including the CRC byte 23) are left at 0, and no CRC is computed; most consumer
    // equipment is documented as not checking it, but that has not been confirmed on a real receiver.  The bit
    // order inside the fields for clock accuracy (bits 28-29) and original sample frequency (bits 36-39) was
    // not confirmed either, so both are left at the "not indicated" codes, which are a legal default whatever
    // the order is.

    localparam [3:0] CS_FREQ_NIBBLE = (SAMPLE_RATE == 96000) ? 4'h5 : 4'h4; // 48kHz=0100b, 96kHz=0101b
    localparam [7:0] CS_BYTE0 = 8'h04; // bit0=0 consumer, bit1=0 linear PCM, bit2=1 copyright not
                                        // asserted, bits3-5=000 no emphasis, bits6-7=00 mode 0
    localparam [7:0] CS_BYTE1 = 8'h00; // category code 0 ("general"), L-bit 0 (two-channel format)
    localparam [7:0] CS_BYTE2 = 8'h00; // source number, channel number: both "not indicated"
    localparam [7:0] CS_BYTE3 = {4'h0, CS_FREQ_NIBBLE}; // clock accuracy Level II (00, safe default,
                                                          // even though this design's own NCO is
                                                          // far tighter - see header) + sample rate
    localparam [7:0] CS_BYTE4 = 8'h0B; // bit0=1 max word length 24-bit, bits1-3=101 word length=24
                                        // bit, bits4-7=0000 original sample frequency not indicated
    localparam [191:0] CHAN_STATUS = {152'h0, CS_BYTE4, CS_BYTE3, CS_BYTE2, CS_BYTE1, CS_BYTE0};

    // ---------------------------------------------------------------- preamble waveforms (see header)
    localparam [0:7] PREAMBLE_B0 = 8'b11101000;
    localparam [0:7] PREAMBLE_M0 = 8'b11100010;
    localparam [0:7] PREAMBLE_W0 = 8'b11100100;

    // ---------------------------------------------------------------- frame/chip sequencing
    // chip_idx: 0..127, one 128-chip frame (both subframes) per sample. subframe_sel selects left
    // (0, chips 0-63) or right (1, chips 64-127); slot_idx (0..31) is the bit-time within that
    // subframe; chip_phase (0/1) is which of the slot's two chips this is.
    reg [6:0] chip_idx;
    reg [7:0] frame_count; // 0..191, one 192-frame channel-status block

    wire        subframe_sel = chip_idx[6];
    wire [5:0]  chip_in_sub  = chip_idx[5:0];
    wire [4:0]  slot_idx     = chip_in_sub[5:1];
    wire        chip_phase   = chip_in_sub[0];
    wire        is_preamble  = (slot_idx < 5'd4);
    wire [2:0]  chip_in_pre  = chip_in_sub[2:0];

    // ---------------------------------------------------------------- this subframe's 28-bit payload
    // (slots 4-31): 24-bit sample (LSB first) + V + U + C + P, built combinationally from the
    // latched sample and this frame's channel-status bit - see header for the field order.
    wire signed [23:0] cur_sample = subframe_sel ? cur_r : cur_l;
    wire               v_bit = 1'b0;
    wire               u_bit = 1'b0;
    wire               c_bit = CHAN_STATUS[frame_count];
    wire               parity_bit = c_bit ^ u_bit ^ v_bit ^ (subframe_sel ? par_r : par_l);
    wire [27:0]        payload = {parity_bit, c_bit, u_bit, v_bit, cur_sample};
    wire               data_bit = payload[slot_idx - 5'd4];

    // ---------------------------------------------------------------- preamble type for this subframe
    wire [0:7] pre_pattern = subframe_sel ? PREAMBLE_W0
                                           : ((frame_count == 8'd0) ? PREAMBLE_B0 : PREAMBLE_M0);
    wire       pre_bit0 = pre_pattern[chip_in_pre];

    // ---------------------------------------------------------------- line-level encoder
    // preamble_invert: latched line level from the chip immediately before this preamble began
    // (chip_in_sub==0), held for all 8 of the preamble's chips - see header ("only the level the
    // line was already sitting at ... decides which of the two waveforms is sent"). For chip 0
    // itself the *current* (pre-update) line_level already is that value, so the effective select
    // below uses line_level directly there and the registered latch for chips 1-7.
    reg  line_level;
    reg  preamble_invert;
    wire preamble_invert_eff = (chip_in_sub == 6'd0) ? line_level : preamble_invert;
    wire preamble_bit = preamble_invert_eff ? ~pre_bit0 : pre_bit0;

    // Biphase-mark data bit: always transition on the cell's first chip; transition again on the
    // second chip only if the data bit is 1 (see header).
    wire bmc_bit = chip_phase ? (data_bit ? ~line_level : line_level) : ~line_level;

    wire new_level = is_preamble ? preamble_bit : bmc_bit;

    always @(posedge clk) begin
        if (rst) begin
            chip_idx        <= 7'd0;
            frame_count      <= 8'd0;
            line_level       <= 1'b0;
            preamble_invert  <= 1'b0;
            spdif_out        <= 1'b0;
        end else if (chip_tick) begin
            if (chip_in_sub == 6'd0) preamble_invert <= line_level;
            line_level <= new_level;
            spdif_out  <= new_level;
            if (chip_idx == 7'd127) begin
                chip_idx    <= 7'd0;
                frame_count <= (frame_count == 8'd191) ? 8'd0 : (frame_count + 8'd1);
            end else begin
                chip_idx <= chip_idx + 7'd1;
            end
        end
    end

endmodule
