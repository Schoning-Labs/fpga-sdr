// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// sdr_hdmi_video: turns a stream of pixels and a stream of audio samples into the three TMDS data lanes and the
// TMDS clock lane of an HDMI cable.
//
// WHERE IT SITS
// The pixels come from the compositor (compositor_pix.v), which sits in the radio core and runs in the same pixel clock;
// this module only asks for them. The audio comes from the audio engine at 48 kHz in clk_dsp. The four outputs (tmds[2:0]
// and tmds_clock) go to the board's HDMI connector through one ELVDS_OBUF per lane in sdr_top.v. Inside this module
// the work is done by the vendored hdl-util/hdmi core (rtl/vendor/hdmi/hdmi.sv and its neighbors, MIT or Apache-2.0),
// and what is written here is the glue: the pixel source choice, the audio hand-over between two clocks, and the choice
// of video mode.
//
// THE THEORY OF A VIDEO SIGNAL (for a beginner, terms are also in docs/learn/GLOSSARY.md)
// A monitor is sent the picture one pixel after another, line after line, at a fixed rate called the pixel clock. The
// sender does not send only the visible 1920 x 1080 pixels. Every line has 2200 pixel slots and every frame has 1125
// lines, and the slots outside the visible area are the blanking: the horizontal blanking (280 slots at the end of each
// line, made of a front porch of 88, a sync pulse of 44 and a back porch of 148) and the vertical blanking (45 lines at
// the end of each frame, 4 of front porch, 5 of sync pulse and 36 of back porch). The sync pulses are what the monitor
// locks to in order to know where a line and a frame begin, and the blanking is a historical gap that used to give a
// cathode ray tube time to move its beam back. HDMI keeps it because the gap is now used to carry audio and other
// data. The core counts the slots with two counters, cx across the line (0 to 2199) and cy down the frame (0 to 1124),
// and the visible pixel is the one where cx < 1920 and cy < 1080. The pixel clock follows from the sizes: 2200 x 1125
// slots x 30 frames per second = 74.25 MHz, which is CEA-861 video mode 34, and mode 16 is the same picture at 60 Hz
// and 148.5 MHz. The radio uses mode 34 (1080p30) because the 60 Hz mode gives a black picture on this board's HDMI pins. The PLL cannot make exactly 74.25 MHz from the 50 MHz oscillator, so the real pixel clock is
// 74.17 MHz (0.11 % low, inside the 0.5 % the standard allows), which makes the frame rate 29.97 Hz and the line time
// 29.66 us.
//
// THE THEORY OF TMDS (Transition Minimized Differential Signaling)
// HDMI sends each 8-bit color value (blue, green and red on lane 0, 1 and 2) as a 10-bit symbol, one symbol per lane
// per pixel clock, and a fourth lane carries the pixel clock itself so that the monitor can recover the timing. The
// 10-bit code is chosen for two electrical reasons. First, the 8 bits are rewritten with a chain of XOR or XNOR
// operations so that the number of changes between neighboring bits is small (fewer transitions mean less radiated
// noise and an easier job for the cable), and a ninth bit records which of the two chains was used. Second, the
// encoder keeps a running count of how many more ones than zeros it has sent so far (the running disparity) and, when
// the count is already far from zero, sends the symbol inverted, with a tenth bit to say so. The result is a signal that
// averages to the same number of ones and zeros, which lets the cable be coupled with a capacitor (DC balanced). That
// 8-to-10 step lives in tmds_channel.sv. Outside the visible area the lanes send other things: during the blanking they
// send one of four fixed control symbols (lane 0 uses them to carry the sync bits, hsync and vsync), and between
// picture and control there are guard bands of fixed symbols that mark where video or a data island starts.
//
// A data island is a packet that HDMI hides in the horizontal blanking, 4 bits per lane per pixel clock, each group of
// 4 bits sent as a fixed 10-bit symbol from a table of 16 (TERC4, TMDS Error Reduction Coding with 4 bits). Packets
// carry the audio samples and the audio clock regeneration packet, besides the InfoFrames (small tables that tell the monitor the
// video mode, the audio format and the name of the sender; the vendor name and product name set below end up in one of
// them). The audio sample rate is not sent as a clock. The monitor has to rebuild the 48 kHz clock from the pixel clock,
// and for this the sender sends two numbers, N and CTS, in the clock regeneration packet: the monitor computes
// 128 x fs = pixel clock x N / CTS. N is fixed (6144 for 48 kHz) and CTS is counted by the sender, as the number of pixel
// clocks that pass while a fixed number of audio samples (48 of them) are taken. Because CTS is counted against the real
// pixel clock, the monitor's rebuilt audio clock is exactly as fast as the real sample stream, whatever the pixel clock
// is, which is why the audio and video clocks of this design do not need to be related.
//
// WHY A 5x CLOCK AND OSER10
// Each lane has to send 10 bits per pixel clock, so the bit rate is 10 x 74.17 = 741.7 Mbit/s per lane. The FPGA does
// not run logic that fast. Gowin's OSER10 primitive is a 10-to-1 serializer in the output cell: it takes the 10 parallel
// bits once per pixel clock (PCLK, clk_pixel) and shifts them out on a double data rate output, two bits per cycle of a
// faster clock (FCLK, clk_pixel_x5), one on the rising and one on the falling edge. Five cycles of FCLK send ten bits, so
// FCLK is five times the pixel clock (370.83 MHz) and both come from the same PLL. The serializers are in
// rtl/vendor/hdmi/serializer.sv, selected by the define GW_IDE. In simulation rtl/video/prim_sim/OSER10.v stands in. The
// TMDS clock lane is just clk_pixel on its own output.
//
// HOW THIS MODULE WORKS, STEP BY STEP
//   1. hdmi.sv counts cx and cy, produces hsync, vsync, the guard bands and data islands, and says at every clock which
//      pixel it needs next. The pixel must be on `rgb` in that same clock (the core registers it at the end of the clock).
//   2. `rgb` is either the compositor's pixel (EXT_RGB = 1, input rgb_ext, which the compositor aligns with cx and cy
//      itself) or the built-in test pattern of colorbar_gen.v (EXT_RGB = 0).
//   3. The audio sample (16-bit left and right, once per 48 kHz) crosses from clk_aud_src to clk_pixel with a toggle
//      handshake, described at the audio block below, and arrives as a one-clock strobe that the core counts for CTS and
//      uses to take the sample into its audio packets.
//   4. The core encodes each lane (tmds_channel.sv, three register stages in all, the last one being the output register) and the
//      serializers send the symbols out. From `rgb` to the serializer inputs the path is about four pixel clocks. The
//      sync and control symbols go through the same stages, so the picture is not shifted against its sync.
//
// MODE: VIDEO_ID_CODE is the CEA-861 video number the vendored core already knows:
//   16 = 1920x1080p60 (148.5 MHz pixel clock, 742.5 MHz bit clock)
//   34 = 1920x1080p30 (74.25 MHz nominal pixel clock, 371.25 MHz bit clock; the one used)
//    4 = 1280x720p60  (74.25 MHz, total 1650 x 750; the rate Sipeed's own example proves on these pins)
// SCREEN_WIDTH and SCREEN_HEIGHT are given in addition, matching the code, because the core does not hand them out as
// constants, and colorbar_gen needs them while the design is built.
//
// CLOCKS: clk_pixel and clk_pixel_x5 are inputs because the PLL that makes them lives in sdr_top.v (they are
// global clock lines there). Keeping the PLL out of this module also lets a testbench drive them directly.
//
// Audio crossing (docs/AUDIO_OUT.md section 4): aud_valid, aud_l and aud_r are the 48 kHz stream in its own clock
// clk_aud_src (clk_dsp; rtl/audio/audio_out_src.v gives one clock of aud_valid per sample and never stops). The sample
// is held here and a toggle carries the news into clk_pixel; the core gets one pixel-clock strobe per sample. There is
// no 48 kHz clock: the core's packet rate and its clock regeneration packets (CTS) follow the strobes, so the sink's
// audio clock is the stream's own rate.

module sdr_hdmi_video #(
    parameter integer VIDEO_ID_CODE      = 16,  // CEA-861 video number, see MODE above
    parameter integer SCREEN_WIDTH       = 1920,  // visible pixels per line
    parameter integer SCREEN_HEIGHT      = 1080,  // visible lines per frame
    parameter real    VIDEO_REFRESH_RATE = 60.0,  // frame rate in Hz, the core only uses it to tell 59.94 and 29.97 from 60 and 30
    parameter integer BIT_WIDTH          = 12,  // width of cx in bits (12 counts to 4095, the 2200 of a 1080p line fit)
    parameter integer BIT_HEIGHT         = 11,  // width of cy in bits (11 counts to 2047, the 1125 lines fit)
    // 1 = the pixel comes from outside (the compositor's `rgb_ext`, already aligned with cx and cy: the pixel for
    // (cx, cy) arrives in the same clock); 0 = the built-in color bars
    parameter integer EXT_RGB            = 0
) (
    input  wire clk_pixel,  // pixel clock, 74.17 MHz for mode 34
    input  wire clk_pixel_x5,  // TMDS bit clock for the OSER10 serializers, exactly 5 x clk_pixel from the same PLL
    input  wire reset,  // synchronous reset in clk_pixel, high = reset

    // 48 kHz audio stream, in the clk_aud_src domain
    input  wire        clk_aud_src,  // audio source clock (clk_dsp, 120 MHz), asynchronous to clk_pixel
    input  wire        aud_valid,  // one clock high per audio sample (every 2500 clocks of 120 MHz)
    input  wire [15:0] aud_l,  // left channel sample, 16-bit signed, valid while aud_valid is high
    input  wire [15:0] aud_r,  // right channel sample, 16-bit signed, valid while aud_valid is high

    output wire [2:0] tmds,  // the three TMDS data lanes, serial, 741.7 Mbit/s each; lane 0 = blue, 1 = green, 2 = red
    output wire       tmds_clock,  // the TMDS clock lane: the pixel clock itself

    // The position the core is asking a pixel for in this clock (pixel column and line, 0,0 = top left of the picture);
    // the compositor uses them, nothing else in this module does.
    output wire [BIT_WIDTH-1:0]  cx,  // pixel column, 0 to 2199 (visible area 0 to 1919)
    output wire [BIT_HEIGHT-1:0] cy,  // line, 0 to 1124 (visible area 0 to 1079)

    // The compositor's pixel for (cx, cy), 8 bits each of red (23:16), green (15:8) and blue (7:0); used when EXT_RGB = 1
    input  wire [23:0] rgb_ext  // color of the pixel asked for in this clock
);

// The pixel that goes into the core. Both sources exist all the time and the parameter picks one while the design is
// built, so the unused one costs no logic.
wire [23:0] rgb_bars;
wire [23:0] rgb = (EXT_RGB != 0) ? rgb_ext : rgb_bars;

// The color bars, a pixel source that needs nothing but cx.
colorbar_gen #(
    .SCREEN_WIDTH  (SCREEN_WIDTH),
    .SCREEN_HEIGHT (SCREEN_HEIGHT),
    .BIT_WIDTH     (BIT_WIDTH),
    .BIT_HEIGHT    (BIT_HEIGHT)
) u_colorbar (
    .cx  (cx),
    .cy  (cy),
    .rgb (rgb_bars)
);

// ---- audio: from clk_aud_src into clk_pixel
// The sample (left in bits 15:0, right in 31:16) is stored in x_d and a toggle bit x_tg flips with every new sample.
// Both are written in clk_aud_src and read in clk_pixel. A single bit that flips once per event can safely cross
// between unrelated clocks through a chain of flip-flops (a synchronizer), and x_d is not sampled until the toggle has
// gone through two of them, by which time it has been still for much longer than a pixel clock. The samples are 20.8 us
// apart, which is some 1,500 pixel clocks.
reg [31:0] x_d /* synthesis syn_preserve = 1 */;     // held from one sample to the next (20 us)
reg        x_tg /* synthesis syn_preserve = 1 */;
initial begin x_d = 32'd0; x_tg = 1'b0; end
always @(posedge clk_aud_src)
    if (aud_valid) begin x_d <= {aud_r, aud_l}; x_tg <= ~x_tg; end

// Three flip-flops in clk_pixel: the first two are the synchronizer, the third remembers the toggle's previous value.
reg [2:0]  t_s /* synthesis syn_preserve = 1 */;
reg        aud_stb = 1'b0;                           // one pixel clock per sample
reg [15:0] w_l = 16'd0, w_r = 16'd0;
initial t_s = 3'd0;
// High for one pixel clock when the toggle has arrived (the last two stages differ), i.e. one new sample is ready.
wire take = t_s[2] ^ t_s[1];                         // x_d has been stable for two pixel clocks
// In the clock `take` is high the sample is copied into w_l and w_r, and in the next clock aud_stb is high for the core,
// so the strobe and the sample words arrive together. `aud_stb` is kept low in reset.
always @(posedge clk_pixel) begin
    t_s     <= {t_s[1:0], x_tg};
    aud_stb <= take && !reset;
    if (take) begin w_l <= x_d[15:0]; w_r <= x_d[31:16]; end
end

// The core wants the two channels as an array of two 16-bit words: index 0 is the left channel and index 1 the right
// one (in audio_sample_packet.sv the low half of the packet's subpacket is taken from word 0, which the core's own
// testbench also reads as left).
wire [15:0] audio_sample_word [1:0];
assign audio_sample_word[0] = w_l;
assign audio_sample_word[1] = w_r;

// Outputs of the core that this module does not need (the sizes of the whole frame and of the visible area, which are
// already given as parameters). They are tied to wires so that the instance has all its ports connected.
wire [BIT_WIDTH-1:0]  frame_width_unused;
wire [BIT_HEIGHT-1:0] frame_height_unused;
wire [BIT_WIDTH-1:0]  screen_width_unused;
wire [BIT_HEIGHT-1:0] screen_height_unused;

// The HDMI core. DVI_OUTPUT = 0 selects HDMI mode: with data islands, so that the audio and the InfoFrames are sent. In
// DVI mode (1) the lanes would carry only picture and control symbols and the monitor would get no sound.
hdmi #(
    .VIDEO_ID_CODE       (VIDEO_ID_CODE),  // video mode, see MODE above
    .DVI_OUTPUT          (1'b0),
    .VIDEO_REFRESH_RATE  (VIDEO_REFRESH_RATE),
    .AUDIO_RATE          (48000),  // the audio sample rate the clock regeneration math is made for (N = 6144)
    .AUDIO_BIT_WIDTH     (16),  // bits per sample in the audio packets
    .VENDOR_NAME         ({"fpgasdr", 8'd0}),         // 7 chars + 1 null byte = 8 bytes
    .PRODUCT_DESCRIPTION ({"fpga-sdr V1", 40'd0}),   // 11 chars + 5 null bytes = 16 bytes
    .BIT_WIDTH           (BIT_WIDTH),
    .BIT_HEIGHT          (BIT_HEIGHT)
) u_hdmi (
    .clk_pixel_x5     (clk_pixel_x5),
    .clk_pixel        (clk_pixel),
    .clk_audio        (aud_stb),      // a strobe in clk_pixel, see the vendored core's headers
    .reset            (reset),
    .rgb              (rgb),
    .audio_sample_word(audio_sample_word),

    .tmds       (tmds),
    .tmds_clock (tmds_clock),

    .cx (cx),
    .cy (cy),

    .frame_width   (frame_width_unused),
    .frame_height  (frame_height_unused),
    .screen_width  (screen_width_unused),
    .screen_height (screen_height_unused)
);

endmodule
