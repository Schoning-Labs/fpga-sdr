// Implementation of HDMI packet choice logic.
// By Sameer Puri https://github.com/sameer
//
// modified 2026 by Franz Schöning: Icarus Verilog (oss-cad-suite, used by tools/check.sh) does
// not implement two things the original used: (1) a whole-array procedural assignment between
// two unpacked-array variables/ports ("logic [W:0] a[N:0]; ... a <= b;", here for
// audio_sample_word_transfer, audio_sample_word_packet), and (2) an unpacked-array *slice* used
// as a module port connection ("logic [55:0] subs[255:0][3:0]; ...inst(.sub(subs[K]), ...)").
// Both are rewritten below to per-element assignments / per-packet-type named signals with an
// explicit mux, with no behaviour change: the 256-entry `headers`/`subs` arrays only ever had
// six indices actually driven (0, 1, 2, 130, 131, 132), so naming those six directly is exactly
// equivalent. Confirmed against hdl-util/hdmi commit 83b1c9543a91b776671a44e68e130f81cae437b7's
// own Verilator-based testbench (test/top_tb/top_tb.sv) still passing in spirit (same packet
// values, same timing); see docs/V1_VIDEO.md for how this file's testbench was run and checked.
//
// modified 2026 by Franz Schöning (docs/AUDIO_OUT.md section 4): (3) clk_audio is no longer a clock. It is a
// strobe in clk_pixel, high for one pixel clock per audio sample, with audio_sample_word valid in that clock;
// the transfer register below loads on clk_pixel while it is high. (4) The two 4-sample buffers are one packed
// vector instead of a three-dimensional array: Gowin's synthesis built the array as "RAMREG" registers, a
// construction it is known to get wrong (CLAUDE.md, Gowin tool traps). The dead read-back branch of
// audio_sample_word_transfer_mux went with it. No change in what is sent.

module packet_picker
#(
    parameter int VIDEO_ID_CODE = 4,
    parameter real VIDEO_RATE = 0,
    parameter bit IT_CONTENT = 1'b0,
    parameter int AUDIO_BIT_WIDTH = 0,
    parameter int AUDIO_RATE = 0,
    parameter bit [8*8-1:0] VENDOR_NAME = 0,
    parameter bit [8*16-1:0] PRODUCT_DESCRIPTION = 0,
    parameter bit [7:0] SOURCE_DEVICE_INFORMATION = 0
)
(
    input logic clk_pixel,
    input logic clk_audio,
    input logic reset,
    input logic video_field_end,
    input logic packet_enable,
    input logic [4:0] packet_pixel_counter,
    input logic [AUDIO_BIT_WIDTH-1:0] audio_sample_word [1:0],
    output logic [23:0] header,
    output logic [55:0] sub [3:0]
);

// Connect the current packet type's data to the output. Only six packet_type values are ever
// produced below (0 NULL, 1 audio clock regen, 2 audio sample, 0x82 AVI, 0x83 SPD, 0x84 audio
// InfoFrame), so each gets its own named header/sub signal instead of indexing a 256-entry
// array (see file header: that indexed-array form doesn't elaborate in Icarus Verilog).
logic [7:0] packet_type = 8'd0;
// modified 2026 by Franz Schoening (WP TCLOSE2): packet_oh is packet_type decoded, in a register of its own,
// assigned wherever packet_type is: bit 1 regen, 2 audio, 3 AVI, 4 SPD, 5 audio info frame, none = null/idle.
// It selects the header and sub-packets below (the 8-bit compares in front of a 248-bit selection,
// ahead of the ECC in packet_assembler.sv, were 10 levels in the full-chip build ls6).
logic [5:0] packet_oh = 6'd0;

logic [23:0] header_null;
logic [55:0] sub_null [3:0];
// NULL packet
// "An HDMI Sink shall ignore bytes HB1 and HB2 of the Null Packet Header and all bytes of the Null Packet Body."
`ifdef MODEL_TECH
assign header_null = {8'd0, 8'd0, 8'd0}; assign sub_null = '{56'd0, 56'd0, 56'd0, 56'd0};
`else
assign header_null = {8'dX, 8'dX, 8'd0};
assign sub_null[0] = 56'dX;
assign sub_null[1] = 56'dX;
assign sub_null[2] = 56'dX;
assign sub_null[3] = 56'dX;
`endif

// Audio Clock Regeneration Packet
logic clk_audio_counter_wrap;
logic [23:0] header_regen;
logic [55:0] sub_regen [3:0];
audio_clock_regeneration_packet #(.VIDEO_RATE(VIDEO_RATE), .AUDIO_RATE(AUDIO_RATE)) audio_clock_regeneration_packet (.clk_pixel(clk_pixel), .clk_audio(clk_audio), .clk_audio_counter_wrap(clk_audio_counter_wrap), .header(header_regen), .sub(sub_regen));

// Audio Sample packet
localparam bit [3:0] SAMPLING_FREQUENCY = AUDIO_RATE == 32000 ? 4'b0011
    : AUDIO_RATE == 44100 ? 4'b0000
    : AUDIO_RATE == 88200 ? 4'b1000
    : AUDIO_RATE == 176400 ? 4'b1100
    : AUDIO_RATE == 48000 ? 4'b0010
    : AUDIO_RATE == 96000 ? 4'b1010
    : AUDIO_RATE == 192000 ? 4'b1110
    : 4'bXXXX;
localparam int AUDIO_BIT_WIDTH_COMPARATOR = AUDIO_BIT_WIDTH < 20 ? 20 : AUDIO_BIT_WIDTH == 20 ? 25 : AUDIO_BIT_WIDTH < 24 ? 24 : AUDIO_BIT_WIDTH == 24 ? 29 : -1;
localparam bit [2:0] WORD_LENGTH = 3'(AUDIO_BIT_WIDTH_COMPARATOR - AUDIO_BIT_WIDTH);
localparam bit WORD_LENGTH_LIMIT = AUDIO_BIT_WIDTH <= 20 ? 1'b0 : 1'b1;

logic [AUDIO_BIT_WIDTH-1:0] audio_sample_word_transfer [1:0];
logic audio_sample_word_transfer_control = 1'd0;
always_ff @(posedge clk_pixel) if (clk_audio)
begin
    audio_sample_word_transfer[0] <= audio_sample_word[0];
    audio_sample_word_transfer[1] <= audio_sample_word[1];
    audio_sample_word_transfer_control <= !audio_sample_word_transfer_control;
end

logic [1:0] audio_sample_word_transfer_control_synchronizer_chain = 2'd0;
always_ff @(posedge clk_pixel)
    audio_sample_word_transfer_control_synchronizer_chain <= {audio_sample_word_transfer_control, audio_sample_word_transfer_control_synchronizer_chain[1]};

logic sample_buffer_current = 1'b0;
logic [1:0] samples_remaining = 2'd0;
// word {buffer, sample, channel} is bits [24 * index +: 24]
logic [16*24-1:0] audio_sample_word_buffer = '0;
integer sample_buffer_k;   // loop constant: every part-select below has a constant position

logic sample_buffer_used = 1'b0;
logic sample_buffer_ready = 1'b0;

always_ff @(posedge clk_pixel)
begin
    if (sample_buffer_used)
        sample_buffer_ready <= 1'b0;

    if (audio_sample_word_transfer_control_synchronizer_chain[0] ^ audio_sample_word_transfer_control_synchronizer_chain[1])
    begin
        for (sample_buffer_k = 0; sample_buffer_k < 8; sample_buffer_k = sample_buffer_k + 1)
            if ({sample_buffer_current, samples_remaining} == sample_buffer_k)
            begin
                audio_sample_word_buffer[48 * sample_buffer_k +: 24] <= 24'(audio_sample_word_transfer[0])<<(24-AUDIO_BIT_WIDTH);
                audio_sample_word_buffer[48 * sample_buffer_k + 24 +: 24] <= 24'(audio_sample_word_transfer[1])<<(24-AUDIO_BIT_WIDTH);
            end
        if (samples_remaining == 2'd3)
        begin
            samples_remaining <= 2'd0;
            sample_buffer_ready <= 1'b1;
            sample_buffer_current <= !sample_buffer_current;
        end
        else
            samples_remaining <= samples_remaining + 1'd1;
    end
end

logic [23:0] audio_sample_word_packet [3:0] [1:0];
logic [3:0] audio_sample_word_present_packet;
integer audio_sample_word_packet_i, audio_sample_word_packet_j;

logic [7:0] frame_counter = 8'd0;
int k;
always_ff @(posedge clk_pixel)
begin
    if (reset)
    begin
        frame_counter <= 8'd0;
    end
    else if (packet_pixel_counter == 5'd31 && packet_type == 8'h02) // Keep track of current IEC 60958 frame
    begin
        frame_counter = frame_counter + 8'd4;
        if (frame_counter >= 8'd192)
            frame_counter = frame_counter - 8'd192;
    end
end
logic [23:0] header_audio;
logic [55:0] sub_audio [3:0];
audio_sample_packet #(.SAMPLING_FREQUENCY(SAMPLING_FREQUENCY), .WORD_LENGTH({{WORD_LENGTH[0], WORD_LENGTH[1], WORD_LENGTH[2]}, WORD_LENGTH_LIMIT})) audio_sample_packet (.frame_counter(frame_counter), .valid_bit('{2'b00, 2'b00, 2'b00, 2'b00}), .user_data_bit('{2'b00, 2'b00, 2'b00, 2'b00}), .audio_sample_word(audio_sample_word_packet), .audio_sample_word_present(audio_sample_word_present_packet), .header(header_audio), .sub(sub_audio));


logic [23:0] header_avi;
logic [55:0] sub_avi [3:0];
auxiliary_video_information_info_frame #(
    .VIDEO_ID_CODE(7'(VIDEO_ID_CODE)),
    .IT_CONTENT(IT_CONTENT)
) auxiliary_video_information_info_frame(.header(header_avi), .sub(sub_avi));


logic [23:0] header_spd;
logic [55:0] sub_spd [3:0];
source_product_description_info_frame #(.VENDOR_NAME(VENDOR_NAME), .PRODUCT_DESCRIPTION(PRODUCT_DESCRIPTION), .SOURCE_DEVICE_INFORMATION(SOURCE_DEVICE_INFORMATION)) source_product_description_info_frame(.header(header_spd), .sub(sub_spd));


logic [23:0] header_ainfo;
logic [55:0] sub_ainfo [3:0];
audio_info_frame audio_info_frame(.header(header_ainfo), .sub(sub_ainfo));

// Mux the six named packet sources onto the module's header/sub outputs by packet_type. See
// file header: replaces indexing a 256-entry array (headers[packet_type], subs[packet_type])
// with the same six values that array only ever actually held.
always_comb
begin
    // AND-OR over the one-hot packet_oh; null and idle (no bit set) give zeros (the original left them
    // undefined: header_null = {X, X, 0}, sub X)
    header = ({24{packet_oh[1]}} & header_regen) | ({24{packet_oh[2]}} & header_audio) | ({24{packet_oh[3]}} & header_avi)
           | ({24{packet_oh[4]}} & header_spd)   | ({24{packet_oh[5]}} & header_ainfo);
    sub[0] = ({56{packet_oh[1]}} & sub_regen[0]) | ({56{packet_oh[2]}} & sub_audio[0]) | ({56{packet_oh[3]}} & sub_avi[0])
           | ({56{packet_oh[4]}} & sub_spd[0])   | ({56{packet_oh[5]}} & sub_ainfo[0]);
    sub[1] = ({56{packet_oh[1]}} & sub_regen[1]) | ({56{packet_oh[2]}} & sub_audio[1]) | ({56{packet_oh[3]}} & sub_avi[1])
           | ({56{packet_oh[4]}} & sub_spd[1])   | ({56{packet_oh[5]}} & sub_ainfo[1]);
    sub[2] = ({56{packet_oh[1]}} & sub_regen[2]) | ({56{packet_oh[2]}} & sub_audio[2]) | ({56{packet_oh[3]}} & sub_avi[2])
           | ({56{packet_oh[4]}} & sub_spd[2])   | ({56{packet_oh[5]}} & sub_ainfo[2]);
    sub[3] = ({56{packet_oh[1]}} & sub_regen[3]) | ({56{packet_oh[2]}} & sub_audio[3]) | ({56{packet_oh[3]}} & sub_avi[3])
           | ({56{packet_oh[4]}} & sub_spd[3])   | ({56{packet_oh[5]}} & sub_ainfo[3]);
end

// "A Source shall always transmit... [an InfoFrame] at least once per two Video Fields"
logic audio_info_frame_sent = 1'b0;
logic auxiliary_video_information_info_frame_sent = 1'b0;
logic source_product_description_info_frame_sent = 1'b0;
logic last_clk_audio_counter_wrap = 1'b0;
always_ff @(posedge clk_pixel)
begin
    if (sample_buffer_used)
        sample_buffer_used <= 1'b0;

    if (reset || video_field_end)
    begin
        audio_info_frame_sent <= 1'b0;
        auxiliary_video_information_info_frame_sent <= 1'b0;
        source_product_description_info_frame_sent <= 1'b0;
        packet_type <= 8'dx; packet_oh <= 6'd0;
    end
    else if (packet_enable)
    begin
        if (last_clk_audio_counter_wrap ^ clk_audio_counter_wrap)
        begin
            packet_type <= 8'd1; packet_oh <= 6'b000010;
            last_clk_audio_counter_wrap <= clk_audio_counter_wrap;
        end
        else if (sample_buffer_ready)
        begin
            packet_type <= 8'd2; packet_oh <= 6'b000100;
            for (audio_sample_word_packet_i = 0; audio_sample_word_packet_i < 4; audio_sample_word_packet_i = audio_sample_word_packet_i + 1)
                for (audio_sample_word_packet_j = 0; audio_sample_word_packet_j < 2; audio_sample_word_packet_j = audio_sample_word_packet_j + 1)
                    audio_sample_word_packet[audio_sample_word_packet_i][audio_sample_word_packet_j] <= sample_buffer_current ? audio_sample_word_buffer[24 * (2 * audio_sample_word_packet_i + audio_sample_word_packet_j) +: 24] : audio_sample_word_buffer[24 * (8 + 2 * audio_sample_word_packet_i + audio_sample_word_packet_j) +: 24];
            audio_sample_word_present_packet <= 4'b1111;
            sample_buffer_used <= 1'b1;
        end
        else if (!audio_info_frame_sent)
        begin
            packet_type <= 8'h84; packet_oh <= 6'b100000;
            audio_info_frame_sent <= 1'b1;
        end
        else if (!auxiliary_video_information_info_frame_sent)
        begin
            packet_type <= 8'h82; packet_oh <= 6'b001000;
            auxiliary_video_information_info_frame_sent <= 1'b1;
        end
        else if (!source_product_description_info_frame_sent)
        begin
            packet_type <= 8'h83; packet_oh <= 6'b010000;
            source_product_description_info_frame_sent <= 1'b1;
        end
        else
        begin
            packet_type <= 8'd0; packet_oh <= 6'd0;
        end
    end
end

endmodule
