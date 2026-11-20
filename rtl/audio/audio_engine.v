// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// audio_engine: the whole path from the audio ring in DDR3 to the three pins of the headphone DAC.
//
// What it does
//   Firmware (or any other producer) writes 48 kHz stereo audio into a ring buffer in DDR3, one 32-bit word per
//   stereo sample ({left[15:0], right[15:0]}, two's complement), and advances a write pointer.  This module reads
//   the ring at the pace of the audio clock, raises the sample rate from 48 kHz to 384 kHz with a polyphase
//   filter, and serializes the result for the PT8211 DAC chip that drives the headphone and speaker outputs.
//   A copy of every 48 kHz sample is also handed out on a separate port for the HDMI and S/PDIF outputs.
//
// Where it sits in the radio
//   Fed by: the firmware's ring in DDR3 (through the memory read port below) and the write pointer register.
//   Feeds:  the PT8211 pins, and `hdmi_audio_*` towards rtl/audio/audio_out_src.v (which makes the stream that
//           the HDMI encoder and the S/PDIF and I2S outputs use, see docs/AUDIO_OUT.md).
//
// How it works, and why the sample rate goes up
//   A sample rate is the number of values per second that describe the waveform; 48 kHz is the usual rate for
//   video and studio audio and is enough for sound up to about 20 kHz.  A DAC that is fed 48 kHz directly
//   produces, besides the wanted sound, mirror images of it around every multiple of 48 kHz (a tone at 10 kHz
//   also shows up at 38 kHz, 58 kHz and so on), and the first of these lies so close to the audio band that only a
//   steep analog filter could remove it.  Interpolation avoids that: seven zero samples are put between every pair
//   of real samples (which raises the rate to 384 kHz and creates the images), and a digital low-pass filter
//   then removes everything above about 20 kHz.  What is left is the same sound at 8 times the sample rate,
//   and the first image now sits near 364 kHz, where the DAC's own output stage and the headphones remove it
//   without any help.  The PT8211 accepts exactly this 8x oversampled rate, which is why the filter ratio is 8.
//
//   Three blocks do the work, in this order (see each file for its own details and the glossary entries
//   "Interpolation", "Polyphase", "I2S" and "PT8211" in docs/learn/GLOSSARY.md):
//     - audio_ring_reader.v  reads the ring from DDR3 into a small FIFO and gives out one sample per 48 kHz tick.
//     - audio_interp_x8.v    turns each 48 kHz sample into 8 samples at 384 kHz with an 18-tap-per-phase filter.
//     - audio_pt8211_tx.v    shifts the samples out as BCK, WS and DIN, and generates the 384 kHz frame tick that
//                            paces the other two (so the DAC clock and the sample flow can never drift apart).
//
// Clocking
//   `clk` is clk_dsp (120 MHz, docs/ARCHITECTURE.md section 2) and `rst` is a synchronous, active high reset in
//   that domain.  Everything here is in this one clock domain; nothing crosses a clock.
//
// Limits
//   The register block of the audio page (audio_regs in rtl/top/block_regs.v) and the read lane arbiter of the shared
//   DDR3 (rtl/ddr3/ddr3_read_arbiter.v) are outside this module, and rtl/top/sdr_core.v connects them: `ring_base`,
//   `wr_ptr` and `rd_ptr` are the ring registers of the audio page, and the generic memory port below goes through
//   rtl/top/rd_word_adapter.v into one tier of the arbiter.  A full description with the measured filter figures is in docs/A1_AUDIO.md.

`timescale 1ns / 1ps

module audio_engine #(
    // Parameters (RING_SIZE_WORDS and FIFO_DEPTH have to be powers of two, because the pointers wrap by masking):
    //   CLK_HZ          frequency of `clk` in Hz, used to derive the bit clock of the DAC.
    //   BCK_HZ          PT8211 bit clock in Hz: 384,000 words per second x 32 bits = 12,288,000.
    //   ADDR_WIDTH      width of the DDR3 word address.
    //   RING_SIZE_WORDS number of stereo samples in the ring (512 samples are 10.7 ms of audio at 48 kHz).
    //   FIFO_DEPTH      depth of the prefetch FIFO in the ring reader, in stereo samples.
    parameter integer CLK_HZ          = 120_000_000,
    parameter integer BCK_HZ          = 12_288_000,
    parameter integer ADDR_WIDTH      = 32,
    parameter integer RING_SIZE_WORDS = 512,
    parameter integer FIFO_DEPTH      = 8
) (
    // Clock (clk_dsp, 120 MHz) and synchronous reset, active high.
    input  wire                  clk,
    input  wire                  rst,

    // Ring control, wired to the ring registers of the audio page (audio_regs).  ring_base is the word address of the ring's
    // first sample.  wr_ptr is the producer's free-running write counter in samples.  rd_ptr is this module's
    // own free-running read counter, which firmware reads to see how much room is left; wrapping at the ring
    // size is done by masking when the address is formed.
    input  wire [ADDR_WIDTH-1:0] ring_base,
    input  wire [ADDR_WIDTH-1:0] wr_ptr,
    output wire [ADDR_WIDTH-1:0] rd_ptr,

    // Generic DDR3 word read port: mem_req is a one-clock request for the word at mem_addr, mem_rvalid is a
    // one-clock pulse when the answer is on mem_rdata (see audio_ring_reader.v for the exact handshake).
    output wire                  mem_req,
    output wire [ADDR_WIDTH-1:0] mem_addr,
    input  wire                  mem_rvalid,
    input  wire [31:0]           mem_rdata,

    // PT8211 pins: bit clock, word select (low = right channel, high = left) and serial data.  On the board
    // these are HP_BCK, HP_WS and HP_DIN (E22, F24 and G24, docs/BOARD.md).
    output wire                  pt8211_bck,
    output wire                  pt8211_ws,
    output wire                  pt8211_din,

    // 48 kHz stereo sample port for the HDMI and S/PDIF outputs.  hdmi_audio_valid is a one-clock pulse per
    // sample, and hdmi_audio_l and hdmi_audio_r are stable and correct on that same clock (two's complement
    // PCM, full scale +/-32767).  The port stays in the clk_dsp domain; building the HDMI audio packets and
    // crossing into the pixel clock is done elsewhere (docs/A1_AUDIO.md, "HDMI audio hand-off").
    output wire                  hdmi_audio_valid,
    output wire signed [15:0]    hdmi_audio_l,
    output wire signed [15:0]    hdmi_audio_r,

    // Status: ring_empty is high while the ring holds no unread sample, ring_low_water is high while the
    // prefetch FIFO is nearly empty (a hint for the "ring is running dry" interrupt), and interp_underrun is a
    // one-clock pulse each time a sample was due and the FIFO had none, so the interpolator repeated the last one.
    output wire                  ring_empty,
    output wire                  ring_low_water,
    output wire                  interp_underrun
);

    // 48 kHz sample stream from the ring reader to the interpolator: smp_valid says a sample is waiting,
    // smp_ready is the interpolator's one-clock request for it (once per 48 kHz period).
    wire                smp_valid, smp_ready;
    wire signed [15:0]  smp_l, smp_r;

    // frame_tick: one clock per 384 kHz word, from the PT8211 serializer.  interp_*: the interpolated
    // 384 kHz samples, valid on the clock where interp_valid is high.
    wire                frame_tick;
    wire                interp_valid;
    wire signed [15:0]  interp_l, interp_r;

    audio_ring_reader #(
        .ADDR_WIDTH     (ADDR_WIDTH),
        .RING_SIZE_WORDS(RING_SIZE_WORDS),
        .FIFO_DEPTH     (FIFO_DEPTH)
    ) u_ring (
        .clk       (clk),
        .rst       (rst),
        .ring_base (ring_base),
        .wr_ptr    (wr_ptr),
        .rd_ptr    (rd_ptr),
        .mem_req   (mem_req),
        .mem_addr  (mem_addr),
        .mem_rvalid(mem_rvalid),
        .mem_rdata (mem_rdata),
        .smp_valid (smp_valid),
        .smp_l     (smp_l),
        .smp_r     (smp_r),
        .smp_ready (smp_ready),
        .hdmi_valid(hdmi_audio_valid),
        .hdmi_l    (hdmi_audio_l),
        .hdmi_r    (hdmi_audio_r),
        .ring_empty(ring_empty),
        .low_water (ring_low_water)
    );

    // The interpolator (and through its smp_ready the FIFO pop in the ring reader) sees the frame tick one clock
    // late, from a register.  audio_pt8211_tx decodes the tick from its bit counter, and carrying that decode on
    // into the interpolator start and the FIFO count in a single clock made a critical path.  The interpolator
    // finishes about 23 clocks after its start and the next frame is about 312 clocks away (120 MHz / 384 kHz),
    // so the extra clock changes nothing at the output.

    reg frame_tick_q;
    always @(posedge clk)
        frame_tick_q <= !rst && frame_tick;

    audio_interp_x8 u_interp (
        .clk        (clk),
        .rst        (rst),
        .frame_tick (frame_tick_q),
        .smp_ready  (smp_ready),
        .smp_valid  (smp_valid),
        .smp_l      (smp_l),
        .smp_r      (smp_r),
        .underrun   (interp_underrun),
        .out_l      (interp_l),
        .out_r      (interp_r),
        .out_valid  (interp_valid)
    );

    audio_pt8211_tx #(
        .CLK_HZ(CLK_HZ),
        .BCK_HZ(BCK_HZ)
    ) u_pt8211 (
        .clk       (clk),
        .rst       (rst),
        .in_l      (interp_l),
        .in_r      (interp_r),
        .in_valid  (interp_valid),
        .frame_tick(frame_tick),
        .bck       (pt8211_bck),
        .ws        (pt8211_ws),
        .din       (pt8211_din)
    );

endmodule
