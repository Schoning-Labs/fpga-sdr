// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
//
// Testbench for rtl/video/sdr_hdmi_video.v, the HDMI transmitter wrapper that turns a pixel stream and a
// 48 kHz audio stream into the three TMDS data channels and a clock. TMDS is the coding HDMI uses on the wire:
// every 8-bit color value is turned into a 10-bit symbol that is balanced in its number of ones and zeros and
// has few transitions, and during the gaps between lines a second, "data island" coding (TERC4, 4 bits into
// 10) carries small packets such as the audio samples. See docs/learn/GLOSSARY.md for TMDS, TERC4 and data
// island.
//
// The test is a receiver written in the testbench. It undoes the encoding on the three channels and checks two
// things. First, the video: the DUT is fed by rtl/video/colorbar_gen.v, an 8-bar color pattern, and the decoded
// pixels must equal the pattern at every active pixel of the lines that are run (the first 100 lines of the
// frame), which the testbench computes again by its own formula. Second, the audio: a 48-entry sine table (the 1 kHz tone of the real design,
// amplitude 20,000, right channel the bitwise complement of the left so a channel swap is noticed) is fed in
// as samples, and every HDMI Audio Sample Packet found in the data islands (packet type 0x02, four samples
// per packet) must carry exactly the samples that were sent, in order. The sample rate in the test is much
// faster than 48 kHz, only so that a short run holds many packets.
//
// The DUT's serializer, which would turn the 10-bit symbols into a bit stream five times faster, is left out on
// purpose. The vendored core (rtl/vendor/hdmi/serializer.sv) has a simulation switch, the macro `VERILATOR`
// (from its original test setup, it has nothing to do with the simulator used here, which is Icarus Verilog),
// that leaves the serializer's output undriven so that the symbols can be read from `tmds_internal` before
// serialization. The macro is defined below ahead of the include, because the core tests it with `ifndef`.
// tools/run_v1_video_full.sh covers the rest in a longer run: full frames, all three video modes, and the
// bit serial path through the OSER10 simulation model (it defines `GW_IDE` instead).
//
// Passing: the last line is "PASS" when at least one active line of pixels was checked, no pixel differs, at
// least 2 audio packets were found and no audio sample differs outside the first packet after reset (see the
// note at `steady_state_audio_sample_errors`). Otherwise a "FAIL: ..." line says which of these failed,
// after a summary line with the counts. The first 5 pixel mismatches and every audio mismatch are printed. The
// test is run with tools/check.sh and is self-contained in the sense that check.sh expects, every file
// needed is included below with paths relative to the repository root, so it can also be run by hand from there:
//   iverilog -g2012 -o sim/out/tb_hdmi_video.vvp sim/video/tb_hdmi_video.v && vvp -n sim/out/tb_hdmi_video.vvp
`define VERILATOR

`include "rtl/vendor/hdmi/tmds_channel.sv"
`include "rtl/vendor/hdmi/serializer.sv"
`include "rtl/vendor/hdmi/audio_clock_regeneration_packet.sv"
`include "rtl/vendor/hdmi/audio_sample_packet.sv"
`include "rtl/vendor/hdmi/audio_info_frame.sv"
`include "rtl/vendor/hdmi/auxiliary_video_information_info_frame.sv"
`include "rtl/vendor/hdmi/source_product_description_info_frame.sv"
`include "rtl/vendor/hdmi/packet_assembler.sv"
`include "rtl/vendor/hdmi/packet_picker.sv"
`include "rtl/vendor/hdmi/hdmi.sv"
`include "rtl/video/colorbar_gen.v"
`include "rtl/video/sdr_hdmi_video.v"

module tb_hdmi_video;

// Video mode: id code 4 is 1280 x 720 at 60 Hz, the fastest of the three modes the design offers. The
// whole frame is 1650 x 750 pixels including the blanking (1650 x 750 x 60 = 74.25 MHz pixel clock).
// BIT_WIDTH and BIT_HEIGHT are the widths of the horizontal and vertical pixel counters.
localparam integer VIDEO_ID_CODE      = 4;    // 1280x720p60: the fastest of the three V1 modes
localparam integer SCREEN_WIDTH       = 1280;
localparam integer SCREEN_HEIGHT      = 720;
localparam integer FRAME_WIDTH        = 1650;
localparam integer FRAME_HEIGHT       = 750;
localparam real    VIDEO_REFRESH_RATE = 60.0;
localparam integer BIT_WIDTH          = 12;
localparam integer BIT_HEIGHT         = 11;

// How many lines to run: 100 lines of 1,650 clocks. That is enough to get past the packets every HDMI
// source sends once after reset (audio clock regeneration, the audio, AVI and SPD InfoFrames, from
// rtl/vendor/hdmi/packet_picker.sv) and to see real Audio Sample Packets. A full frame of every mode is
// left to tools/run_v1_video_full.sh.
localparam integer N_LINES = 100;

// `clk_pixel` is the pixel clock of the DUT (10 ns here, the real one is 74.25 MHz for this mode).
reg clk_pixel    = 1'b0;
reg clk_pixel_x5 = 1'b0; // port only; unused by the DUT while `VERILATOR is defined
reg clk_src      = 1'b0; // the audio stream's clock (clk_dsp on the chip)
// Audio input of the DUT: one sample pair with a strobe, on its own clock `clk_src`.
reg        aud_valid = 1'b0;
reg [15:0] aud_l = 16'd0, aud_r = 16'd0;
reg reset        = 1'b1;

wire [2:0] tmds;
wire       tmds_clock;
wire [BIT_WIDTH-1:0]  cx_dut;
wire [BIT_HEIGHT-1:0] cy_dut;

sdr_hdmi_video #(
    .VIDEO_ID_CODE      (VIDEO_ID_CODE),
    .SCREEN_WIDTH       (SCREEN_WIDTH),
    .SCREEN_HEIGHT      (SCREEN_HEIGHT),
    .VIDEO_REFRESH_RATE (VIDEO_REFRESH_RATE),
    .BIT_WIDTH          (BIT_WIDTH),
    .BIT_HEIGHT         (BIT_HEIGHT)
) dut (
    .clk_pixel    (clk_pixel),
    .clk_pixel_x5 (clk_pixel_x5),
    .clk_aud_src  (clk_src),
    .aud_valid    (aud_valid),
    .aud_l        (aud_l),
    .aud_r        (aud_r),
    .reset        (reset),
    .tmds         (tmds),
    .tmds_clock   (tmds_clock),
    .cx           (cx_dut),
    .cy           (cy_dut)
);

// The pixel clock and the audio clock are independent domains, so their real ratio does not matter for this
// functional check, with two limits on the audio clock. It must stay slow compared with the pixel clock
// so that the 2-flop synchronizer in rtl/vendor/hdmi/packet_picker.sv sees every edge, and slow enough that
// the packet scheduler can send each group of 4 samples before the next group is complete, because that
// buffer has two entries and no backpressure and samples would be silently overwritten, exactly as real
// hardware would do if it were fed audio far faster than its packet bandwidth allows. Real HDMI has
// a large margin here, 48 kHz audio against a pixel clock of more than 20 MHz, and this test keeps the
// same kind of margin with a ratio of about 1 to 500 and not the true 1 to 1,500.
always #5    clk_pixel = ~clk_pixel;
// The audio stream: one sample every 833 ticks of a 6 ns clock (4,998 ns, the margin described above, so
// roughly 4 samples in 1.2 lines of 16.5 us). The clock has nothing to do with `clk_pixel`. Left is the 1 kHz
// table and right is its complement, so that a swap of the channels shows up.
always #3    clk_src = ~clk_src;

// Hold reset for 10 pixel clocks.
initial begin
    reset = 1'b1;
    repeat (10) @(posedge clk_pixel);
    reset = 1'b0;
end

// ---------------------------------------------------------------------------------------------
// Which pixel a decoded TMDS symbol belongs to. The testbench reads the vendored core's own `cx`, `mode`
// and `video_data` through hierarchical references (the same way the original test bench of that core
// reads its structural and timing signals) and does not work out their timing from a guessed constant
// delay. A single shared delay does not work, because `mode` is computed from the already registered
// `video_data_period`, one pixel clock further behind `cx` than `video_data` itself is. They are
// equal in the middle of the active region but differ at the transition from the video guard band to
// video data. Each signal therefore gets only the delay of tmds_channel's own registers.
// ---------------------------------------------------------------------------------------------
// rtl/vendor/hdmi/tmds_channel.sv encodes in three clocks (TMDS_EXTRA = 2 clocks more than the single register
// of the original core), so every delay below is TMDS_EXTRA longer.
localparam integer TMDS_EXTRA = 2;
// Delay chains: `cx` and `cy` over 4 clocks, `mode` and `video_data` over 3.
reg [BIT_WIDTH-1:0]  dut_cx_d1 = 0, dut_cx_d2 = 0, dut_cx_d3 = 0, dut_cx_d4 = 0;
reg [BIT_HEIGHT-1:0] dut_cy_d1 = 0, dut_cy_d2 = 0, dut_cy_d3 = 0, dut_cy_d4 = 0;
reg [2:0]  dut_mode_d1 = 0, dut_mode_d2 = 0, dut_mode_d3 = 0;
reg [23:0] dut_video_data_d1 = 0, dut_video_data_d2 = 0, dut_video_data_d3 = 0;
always @(posedge clk_pixel) begin
    if (reset) begin
        dut_cx_d1 <= 0; dut_cy_d1 <= 0;
        dut_cx_d2 <= 0; dut_cy_d2 <= 0;
        dut_cx_d3 <= 0; dut_cy_d3 <= 0;
        dut_cx_d4 <= 0; dut_cy_d4 <= 0;
        dut_mode_d1 <= 0; dut_mode_d2 <= 0; dut_mode_d3 <= 0;
        dut_video_data_d1 <= 0; dut_video_data_d2 <= 0; dut_video_data_d3 <= 0;
    end else begin
        // `video_data <= rgb` in rtl/vendor/hdmi/hdmi.sv reads `cx` and `cy` in the same clock, so `cx`
        // delayed by one clock is the position that `video_data` shows.
        dut_cx_d1 <= dut.cx;    dut_cy_d1 <= dut.cy;
        dut_cx_d2 <= dut_cx_d1; dut_cy_d2 <= dut_cy_d1;
        dut_cx_d3 <= dut_cx_d2; dut_cy_d3 <= dut_cy_d2;
        dut_cx_d4 <= dut_cx_d3; dut_cy_d4 <= dut_cy_d3;
        // tmds_channel's last register takes `mode` and `video_data` at its first edge, so both delayed by
        // 1 + TMDS_EXTRA clocks are what that register holds, in the same clock as the symbol on the wire.
        dut_mode_d1       <= dut.u_hdmi.mode;
        dut_mode_d2       <= dut_mode_d1;
        dut_mode_d3       <= dut_mode_d2;
        dut_video_data_d1 <= dut.u_hdmi.video_data;
        dut_video_data_d2 <= dut_video_data_d1;
        dut_video_data_d3 <= dut_video_data_d2;
    end
end

// ---------------------------------------------------------------------------------------------
// TMDS decode (the receiver side): undoes the 8-bit to 10-bit video coding of rtl/vendor/hdmi/tmds_channel.sv
// (bit 9 says whether the byte was inverted, bit 8 whether the neighbouring bits were combined by XOR or XNOR)
// and its TERC4 coding for data islands (a table of the 16 symbols). The formulas are the same as the ones in
// the original test bench of the core (hdl-util/hdmi, MIT or Apache-2.0).
// ---------------------------------------------------------------------------------------------
function [7:0] tmds_decode_byte;
    input [9:0] code;
    reg [7:0] d;
    integer i;
    begin
        d[0] = code[9] ? ~code[0] : code[0];
        for (i = 1; i < 8; i = i + 1)
            d[i] = code[8] ? (code[i] ^ code[i-1]) : (code[i] ~^ code[i-1]);
        tmds_decode_byte = d;
    end
endfunction

function [3:0] terc4_decode;
    input [9:0] code;
    begin
        case (code)
            10'b1010011100: terc4_decode = 4'b0000;
            10'b1001100011: terc4_decode = 4'b0001;
            10'b1011100100: terc4_decode = 4'b0010;
            10'b1011100010: terc4_decode = 4'b0011;
            10'b0101110001: terc4_decode = 4'b0100;
            10'b0100011110: terc4_decode = 4'b0101;
            10'b0110001110: terc4_decode = 4'b0110;
            10'b0100111100: terc4_decode = 4'b0111;
            10'b1011001100: terc4_decode = 4'b1000;
            10'b0100111001: terc4_decode = 4'b1001;
            10'b0110011100: terc4_decode = 4'b1010;
            10'b1011000110: terc4_decode = 4'b1011;
            10'b1010001110: terc4_decode = 4'b1100;
            10'b1001110001: terc4_decode = 4'b1101;
            10'b0101100011: terc4_decode = 4'b1110;
            10'b1011000011: terc4_decode = 4'b1111;
            default:        terc4_decode = 4'bxxxx;
        endcase
    end
endfunction

// The three 10-bit symbols on the wire in this clock, one per channel (channel 0 is blue, 1 green, 2 red).
wire [9:0] ch0 = dut.u_hdmi.tmds_internal[0];
wire [9:0] ch1 = dut.u_hdmi.tmds_internal[1];
wire [9:0] ch2 = dut.u_hdmi.tmds_internal[2];

// ---------------------------------------------------------------------------------------------
// Pixel check: whenever the delayed `mode` says this clock carries video data, decode the three symbols and
// compare them with the color bar generator's expected color for that position.
// ---------------------------------------------------------------------------------------------
integer pixels_checked    = 0;
integer pixel_mismatches  = 0;

// `video_expected` is true when this clock's symbols really are video coded, judged from the DUT's own `mode`
// (delayed to tmds_channel's register as above) and not from a guessed range of `cx`.
wire video_expected = (dut_mode_d3 == 3'd1);

// Expected color: the 8-bar formula of rtl/video/colorbar_gen.v (bar number is x * 8 / 1280, so every bar
// is 160 pixels wide: white, yellow, cyan, green, magenta, red, blue, black), evaluated here independently
// for the position `video_data` reflects, and not taken from `video_data` itself, so the test checks that
// colorbar_gen made the right color and not only that TMDS carries across whatever the DUT sent.
reg [23:0] expected_rgb;
always @(*) begin
    case ((dut_cx_d4 * 8) / SCREEN_WIDTH)
        3'd0: expected_rgb = 24'hFFFFFF;
        3'd1: expected_rgb = 24'hFFFF00;
        3'd2: expected_rgb = 24'h00FFFF;
        3'd3: expected_rgb = 24'h00FF00;
        3'd4: expected_rgb = 24'hFF00FF;
        3'd5: expected_rgb = 24'hFF0000;
        3'd6: expected_rgb = 24'h0000FF;
        default: expected_rgb = 24'h000000;
    endcase
end

always @(posedge clk_pixel) begin
    if (!reset && video_expected) begin
        pixels_checked = pixels_checked + 1;
        if (tmds_decode_byte(ch0) !== expected_rgb[7:0]  ||
            tmds_decode_byte(ch1) !== expected_rgb[15:8] ||
            tmds_decode_byte(ch2) !== expected_rgb[23:16]) begin
            pixel_mismatches = pixel_mismatches + 1;
            if (pixel_mismatches <= 5)
                $display("PIXEL MISMATCH at x=%0d y=%0d: got %02x%02x%02x expected %06x (dut_video_data=%06x)",
                    dut_cx_d4, dut_cy_d4,
                    tmds_decode_byte(ch2), tmds_decode_byte(ch1), tmds_decode_byte(ch0),
                    expected_rgb, dut_video_data_d3);
        end
    end
end

// ---------------------------------------------------------------------------------------------
// Audio Sample Packet capture: decode the TERC4 data island stream of the three channels into the packet
// header (24 bits from channel 0) and the four subpackets (64 bits each, from channels 1 and 2, two bits per
// clock) over the 32 clocks of a packet, see the framing note further down. The header's first byte must be
// 0x02, the Audio Sample Packet of rtl/vendor/hdmi/audio_sample_packet.sv.
// ---------------------------------------------------------------------------------------------
reg [23:0] pkt_header  = 0;
reg [63:0] pkt_sub [0:3];
integer gi;
initial for (gi = 0; gi < 4; gi = gi + 1) pkt_sub[gi] = 64'd0;

integer audio_packets_found = 0;
integer audio_sample_errors = 0;
// The same count without packet 1. The first Audio Sample Packet after reset can read back partly as silence
// (docs/V1_VIDEO.md), because the synchronizer that carries the samples from the audio clock into the pixel
// clock domain in rtl/vendor/hdmi/packet_picker.sv has not yet seen 4 real edges when that first packet
// goes out. It is reported but does not fail the test, and every later packet has to be exact.
integer steady_state_audio_sample_errors = 0;

// ---------------------------------------------------------------------------------------------
// Phase FIFO: the sine phase counter of the audio source runs from reset on, and the clear and InfoFrame
// packets delay the first real Audio Sample Packet by an unknown number of audio ticks, so packet N does not
// carry samples 4N to 4N+3. The testbench therefore keeps its own copy of the phase counter (`tb_phase`),
// pushes it into a FIFO on every audio sample, and every decoded packet takes exactly 4 entries out (a packet
// always holds 4 fresh samples, packet_picker.sv marks all four words present) and compares its subpackets
// with the table at those phases, oldest first (subpacket 0 is the oldest, packet_picker.sv fills it first).
// ---------------------------------------------------------------------------------------------
reg [5:0] tb_phase = 0;
localparam integer PHASE_FIFO_DEPTH = 16384;
reg [5:0] phase_fifo [0:PHASE_FIFO_DEPTH-1];
integer fifo_wr = 0;
integer fifo_rd = 0;
integer src_cnt = 0;
always @(posedge clk_src) begin
    aud_valid <= 1'b0;
    if (reset) begin
        tb_phase <= 0; fifo_wr <= 0; src_cnt <= 0;
    end else if (src_cnt == 832) begin
        src_cnt   <= 0;
        aud_valid <= 1'b1;
        aud_l     <= tone_rom(tb_phase);
        aud_r     <= ~tone_rom(tb_phase);
        phase_fifo[fifo_wr] <= tb_phase;
        fifo_wr   <= (fifo_wr == PHASE_FIFO_DEPTH-1) ? 0 : fifo_wr + 1;
        tb_phase  <= (tb_phase == 6'd47) ? 6'd0 : tb_phase + 6'd1;
    end else
        src_cnt <= src_cnt + 1;
end

// The 1 kHz test tone table: 48 values of 20,000 x sin(2 pi p / 48), the same table as in
// rtl/audio/audio_out_src.v.
function signed [15:0] tone_rom;
    input [5:0] ph;
    begin
        case (ph)
            6'd0 : tone_rom = 16'sd0;      6'd1 : tone_rom = 16'sd2611;
            6'd2 : tone_rom = 16'sd5176;   6'd3 : tone_rom = 16'sd7654;
            6'd4 : tone_rom = 16'sd10000;  6'd5 : tone_rom = 16'sd12175;
            6'd6 : tone_rom = 16'sd14142;  6'd7 : tone_rom = 16'sd15867;
            6'd8 : tone_rom = 16'sd17321;  6'd9 : tone_rom = 16'sd18478;
            6'd10: tone_rom = 16'sd19319;  6'd11: tone_rom = 16'sd19829;
            6'd12: tone_rom = 16'sd20000;  6'd13: tone_rom = 16'sd19829;
            6'd14: tone_rom = 16'sd19319;  6'd15: tone_rom = 16'sd18478;
            6'd16: tone_rom = 16'sd17321;  6'd17: tone_rom = 16'sd15867;
            6'd18: tone_rom = 16'sd14142;  6'd19: tone_rom = 16'sd12175;
            6'd20: tone_rom = 16'sd10000;  6'd21: tone_rom = 16'sd7654;
            6'd22: tone_rom = 16'sd5176;   6'd23: tone_rom = 16'sd2611;
            6'd24: tone_rom = 16'sd0;      6'd25: tone_rom = -16'sd2611;
            6'd26: tone_rom = -16'sd5176;  6'd27: tone_rom = -16'sd7654;
            6'd28: tone_rom = -16'sd10000; 6'd29: tone_rom = -16'sd12175;
            6'd30: tone_rom = -16'sd14142; 6'd31: tone_rom = -16'sd15867;
            6'd32: tone_rom = -16'sd17321; 6'd33: tone_rom = -16'sd18478;
            6'd34: tone_rom = -16'sd19319; 6'd35: tone_rom = -16'sd19829;
            6'd36: tone_rom = -16'sd20000; 6'd37: tone_rom = -16'sd19829;
            6'd38: tone_rom = -16'sd19319; 6'd39: tone_rom = -16'sd18478;
            6'd40: tone_rom = -16'sd17321; 6'd41: tone_rom = -16'sd15867;
            6'd42: tone_rom = -16'sd14142; 6'd43: tone_rom = -16'sd12175;
            6'd44: tone_rom = -16'sd10000; 6'd45: tone_rom = -16'sd7654;
            6'd46: tone_rom = -16'sd5176;  6'd47: tone_rom = -16'sd2611;
            default: tone_rom = 16'sdX;
        endcase
    end
endfunction

integer si;
reg [3:0] n0, n1, n2;
reg [5:0] pop_phase;

// Packet framing. The testbench reads the vendored core's own packet `counter` (0 to 31, the clock within the
// packet) and `data_island_period` through hierarchical references. The core frames only the whole run of
// data island clocks, not each packet, since several packets can follow each other with no guard band
// between them, so a framing state machine built from the wire alone is easy to get subtly wrong. The data
// itself still comes only from the TERC4 decoded wire (ch0, ch1, ch2) and not from any internal header or
// subpacket signal, the internals only provide the framing.
wire [4:0] dut_counter            = dut.u_hdmi.true_hdmi_output.packet_assembler.counter;
wire       dut_data_island_period = dut.u_hdmi.true_hdmi_output.data_island_period;

// The same pipeline as in the video path: `data_island_data` is registered from `packet_data` and `counter`
// in one clock and TERC4 coded into `tmds_internal` in the tmds_channel registers, so the symbols on the wire
// reflect the counter from 4 clocks earlier (1 plus the 3 clocks of tmds_channel).
reg [4:0] dut_counter_d1 = 0, dut_counter_d2 = 0, dut_counter_d3 = 0, dut_counter_d4 = 0;
reg       dut_dip_d1 = 0, dut_dip_d2 = 0, dut_dip_d3 = 0, dut_dip_d4 = 0;
always @(posedge clk_pixel) begin
    if (reset) begin
        dut_counter_d1 <= 0; dut_counter_d2 <= 0; dut_counter_d3 <= 0; dut_counter_d4 <= 0;
        dut_dip_d1 <= 0; dut_dip_d2 <= 0; dut_dip_d3 <= 0; dut_dip_d4 <= 0;
    end else begin
        dut_counter_d1 <= dut_counter; dut_counter_d2 <= dut_counter_d1;
        dut_counter_d3 <= dut_counter_d2; dut_counter_d4 <= dut_counter_d3;
        dut_dip_d1 <= dut_data_island_period; dut_dip_d2 <= dut_dip_d1;
        dut_dip_d3 <= dut_dip_d2; dut_dip_d4 <= dut_dip_d3;
    end
end

        // During a data island: decode the three nibbles, store the header bit and the subpacket bits
        // of this clock, and when the 32nd clock of a packet has been decoded check it.
always @(posedge clk_pixel) begin
    if (!reset && dut_dip_d4) begin
        n0 = terc4_decode(ch0);
        n1 = terc4_decode(ch1);
        n2 = terc4_decode(ch2);
        if (dut_counter_d4 < 24)
            pkt_header[dut_counter_d4] <= n0[2]; // ch0 nibble bit2 = packet_data[0] = bch4[counter]
        for (si = 0; si < 4; si = si + 1) begin
            pkt_sub[si][2*dut_counter_d4]   <= n1[si]; // ch1 nibble bit(si) = bch[si][2*counter]
            pkt_sub[si][2*dut_counter_d4+1] <= n2[si]; // ch2 nibble bit(si) = bch[si][2*counter+1]
        end
        if (dut_counter_d4 == 5'd31) begin
            if (pkt_header[7:0] == 8'h02) begin
                audio_packets_found = audio_packets_found + 1;
                for (si = 0; si < 4; si = si + 1) begin
                    pop_phase = phase_fifo[fifo_rd];
                    fifo_rd = (fifo_rd == PHASE_FIFO_DEPTH-1) ? 0 : fifo_rd + 1;
                    if ($signed(pkt_sub[si][23:8])  !== tone_rom(pop_phase) ||
                        $signed(pkt_sub[si][47:32]) !== ~tone_rom(pop_phase)) begin
                        audio_sample_errors = audio_sample_errors + 1;
                        // The first packet only counts toward the total, see the note by
                        // steady_state_audio_sample_errors.
                        // Packet 1 only: see the note by steady_state_audio_sample_errors below.
                        if (audio_packets_found != 1)
                            steady_state_audio_sample_errors = steady_state_audio_sample_errors + 1;
                        $display("AUDIO SAMPLE MISMATCH packet %0d sample %0d: L=%0d R=%0d expected %0d (phase %0d)",
                            audio_packets_found, si,
                            $signed(pkt_sub[si][23:8]), $signed(pkt_sub[si][47:32]),
                            tone_rom(pop_phase), pop_phase);
                    end
                end
            end
        end
    end
end

// ---------------------------------------------------------------------------------------------
// Run for N_LINES lines, report and judge.
// ---------------------------------------------------------------------------------------------
initial begin
    @(negedge reset);
    repeat (N_LINES) repeat (FRAME_WIDTH) @(posedge clk_pixel);

    $display("pixels_checked=%0d pixel_mismatches=%0d audio_packets_found=%0d audio_sample_errors=%0d (steady-state: %0d)",
        pixels_checked, pixel_mismatches, audio_packets_found, audio_sample_errors, steady_state_audio_sample_errors);

    if (pixels_checked < SCREEN_WIDTH)
        $display("FAIL: not enough active pixels observed (%0d)", pixels_checked);
    else if (pixel_mismatches != 0)
        $display("FAIL: %0d pixel mismatches", pixel_mismatches);
    else if (audio_packets_found < 2)
        $display("FAIL: fewer than 2 Audio Sample Packets found");
    else if (steady_state_audio_sample_errors != 0)
        $display("FAIL: %0d audio sample mismatches outside the documented first-packet startup transient", steady_state_audio_sample_errors);
    else
        $display("PASS");

    $finish;
end

endmodule
