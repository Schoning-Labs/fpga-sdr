// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ft8_slot_reader: fetches one frame's window of audio back out of DDR3 and loads it into the frame buffer.
//
// What it does
//   Before the transform of each spectrogram frame (ft8_spectrogram.v) the 1,920 samples of that frame's window
//   (one FT8 symbol, 160 ms) have to be read out of the ring that ft8_slot_capture.v filled in DDR3.  This block does the
//   read, through the read lane's lowest tier (via ft8_ddr3_rdmux.v), unpacks the four 16-bit samples of each 64-bit
//   word, and writes the samples one per clock into the input buffer port (`buf_wr_*`) of ft8_frame_core.v.
//
// How it works
//   The ring holds 4 samples per lane word.  A window that starts at ring sample `first_sample` covers lane words
//   first / 4 up to (first + 1,919) / 4, which is 480 words, or 481 when the start is not a multiple of 4.  Words come
//   in bursts of up to BURSTLEN beats (one lane word per beat) into a FIFO of 2 x BURSTLEN words, and are unpacked at
//   one sample per clock.  A burst is requested only when the FIFO has room for all of it, because the read lane cannot be
//   held off in the middle of a burst.  Bursts are also split where the window wraps past the end of the ring
//   (RING_SAMPLES is a power of two, and the 480-sample frame steps do not line up with it).  The unpacking runs while
//   the later words are still being fetched, so the window is in the buffer a little after the last word arrives.
//
// Where it sits in the radio
//   Fed by: the DDR3 read lane.  Feeds: ft8_frame_core.v.  Controlled by: the scheduler in ft8_spectrogram.v (`start`,
//   `busy`, `done`).

`timescale 1ns / 1ps

module ft8_slot_reader #(
    parameter integer ADDR_WIDTH   = 32,
    parameter integer BURSTLEN     = 16,       // longest burst in beats (lane words), 1 .. 64
    parameter integer RING_SAMPLES = 1 << 19
) (
    // Clock (clk_dsp, 120 MHz) and synchronous reset (active high).
    input  wire        clk,
    input  wire        rst,

    // Start a fetch of ring samples first_sample .. first_sample + 1,919 (mod RING_SAMPLES) from the ring at ring_base
    // (a lane word address): `start` is a one-clock pulse, `busy` is high from the start until the last sample is
    // loaded, and `done` is a one-clock pulse after it.
    input  wire        start,
    input  wire [ADDR_WIDTH-1:0] ring_base,
    input  wire [31:0]           first_sample,
    output reg          busy,
    output reg          done,

    // Load port of the input buffer in ft8_frame_core.v: write enable, sample index 0 .. 1,919 and the sample.
    output reg          buf_wr_en,
    output reg  [10:0]  buf_wr_addr,
    output reg  [15:0]  buf_wr_data,

    // Read-lane client port (rtl/ddr3/ddr3_read_arbiter.v convention): req with address and burst length, gnt when
    // granted, rvalid with rdata for each word, rdone after the last.
    output reg          req,
    output wire [ADDR_WIDTH-1:0] addr,
    output wire [7:0]   burstlen,
    input  wire         gnt,
    input  wire         rvalid,
    input  wire [63:0]  rdata,
    input  wire         rdone
);

    // Ring size in words, address width of a word inside the ring, and FIFO depth and pointer width.
    localparam integer RING_WORDS = RING_SAMPLES / 4;
    localparam integer RW  = $clog2(RING_WORDS);
    localparam integer FD  = 2 * BURSTLEN;          // FIFO depth, words
    localparam integer FAW = $clog2(FD);

    // ---------------- request side ----------------
    // offset is the ring word offset of the next word to request, words_left the words of the window not yet requested
    // (0 .. 481), remaining and to_wrap the words left in the window and before the ring's end (for splitting bursts),
    // len the length of the next burst (not more than BURSTLEN, remaining or to_wrap).
    reg [ADDR_WIDTH-1:0] base_latched;
    reg [RW-1:0] offset;       // ring word offset of the next word to request
    reg [9:0]    words_left;   // words of the window not yet requested (0 .. 481)
    reg [9:0]    remaining;
    reg [RW:0]   to_wrap;
    wire [9:0]   len_a    = (remaining < BURSTLEN) ? remaining : BURSTLEN[9:0];
    wire [9:0]   len_next = (to_wrap < len_a) ? to_wrap[9:0] : len_a;
    reg [7:0]    len;
    reg [ADDR_WIDTH-1:0] addr_r;
    assign addr     = addr_r;
    assign burstlen = len;

    // ---------------- FIFO ----------------
    // LUT RAM: left to itself the synthesizer made this 32 x 64 FIFO a block RAM, and a block RAM that is 64 bits wide
    // counts as four blocks.
    reg [63:0]    fifo [0:FD-1] /* synthesis syn_ramstyle = "distributed_ram" */;
    reg [FAW-1:0] fwp, frp;
    reg [FAW:0]   fcnt;          // words stored
    reg [FAW:0]   fres;          // words stored, or requested and not yet arrived
    wire          fpop;

    always @(posedge clk) begin
        if (rvalid) fifo[fwp] <= rdata;
    end

    // ---------------- unpack side ----------------
    // si is the window sample being written (0 .. 1,919) and lane the position of that sample inside the FIFO head word.
    // fcnt counts words stored in the FIFO and fres those stored or requested and not yet arrived (the space already
    // promised to bursts under way).
    reg [10:0]   si;            // window sample being written, 0 .. 1,919
    reg [1:0]    lane;          // its lane in the FIFO head word
    reg          unpacking;
    wire [63:0]  head = fifo[frp];
    assign fpop = unpacking && (fcnt != 0) && ((lane == 2'd3) || (si == 11'd1919));

    localparam [2:0] IDLE = 3'd0, SETUP = 3'd1, SETUP2 = 3'd2, WAITROOM = 3'd3, REQ = 3'd4,
                     BURST = 3'd5, SETUP3 = 3'd6;
    // Room for the next burst, computed a clock ahead of its use: the words stored or under way plus the burst's length.
    // While the reader waits that sum can only fall (words leave and none are requested), so a value one clock old never
    // says "room" too early.  State SETUP3 gives it a clock to take in the new length.
    reg [FAW+1:0] fsum;
    always @(posedge clk) fsum <= {1'b0, fres} + len[FAW+1:0];
    reg [2:0] state;
    wire granted = (state == REQ) && gnt;

    // Main sequencer.  The unpacking part runs by itself while `unpacking` is set, and the state machine below issues the
    // bursts: IDLE, then SETUP (address and remaining words), SETUP2 and SETUP3 (burst length), WAITROOM, REQ and BURST,
    // and back to SETUP until the window is requested.

    always @(posedge clk) begin
        buf_wr_en <= 1'b0;
        done      <= 1'b0;
        if (rst) begin
            state     <= IDLE;
            busy      <= 1'b0;
            req       <= 1'b0;
            unpacking <= 1'b0;
            fwp <= 0; frp <= 0; fcnt <= 0; fres <= 0;
        end else begin
            if (rvalid) fwp <= fwp + 1'b1;
            if (fpop)   frp <= frp + 1'b1;
            fcnt <= fcnt + (rvalid ? 1'b1 : 1'b0) - (fpop ? 1'b1 : 1'b0);
            fres <= fres + (granted ? len[FAW:0] : 0) - (fpop ? 1'b1 : 1'b0);

            // unpack: one sample per clock while the head word is there
            if (unpacking && fcnt != 0) begin
                buf_wr_en   <= 1'b1;
                buf_wr_addr <= si;
                case (lane)
                    2'd0:    buf_wr_data <= head[15:0];
                    2'd1:    buf_wr_data <= head[31:16];
                    2'd2:    buf_wr_data <= head[47:32];
                    default: buf_wr_data <= head[63:48];
                endcase
                lane <= lane + 2'd1;
                si   <= si + 11'd1;
                if (si == 11'd1919) begin
                    unpacking <= 1'b0;
                    busy      <= 1'b0;
                    done      <= 1'b1;
                end
            end

            case (state)
                IDLE: begin
                    if (start && !busy) begin
                        busy         <= 1'b1;
                        base_latched <= ring_base;
                        offset       <= first_sample[RW+1:2];
                        words_left   <= (first_sample[1:0] == 2'd0) ? 10'd480 : 10'd481;
                        lane         <= first_sample[1:0];
                        si           <= 11'd0;
                        unpacking    <= 1'b1;
                        state        <= SETUP;
                    end
                end
                SETUP: begin
                    if (words_left == 10'd0) begin
                        state <= IDLE;
                    end else begin
                        addr_r    <= base_latched + offset;
                        remaining <= words_left;
                        to_wrap   <= RING_WORDS - offset;
                        state     <= SETUP2;
                    end
                end
                SETUP2: begin
                    len   <= len_next[7:0];
                    state <= SETUP3;
                end
                SETUP3: state <= WAITROOM;      // fsum takes the new length here
                WAITROOM: begin
                    if (fsum <= FD) begin
                        req   <= 1'b1;
                        state <= REQ;
                    end
                end
                REQ: begin
                    if (gnt) begin
                        req        <= 1'b0;
                        words_left <= words_left - {2'd0, len};
                        offset     <= offset + len;   // wraps mod RING_WORDS by width
                        state      <= BURST;
                    end
                end
                BURST: begin
                    if (rdone) state <= SETUP;
                end
                default: state <= IDLE;
            endcase
        end
    end

endmodule
