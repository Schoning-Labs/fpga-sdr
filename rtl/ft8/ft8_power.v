// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ft8_power: turns a finished frame's 1,024 complex sums into 1,024 power words, the line of the spectrogram.
//
// What it does
//   After ft8_combine.v has finished the frame's 1,024 accumulators A (complex, 44 bit per part), this block reads them
//   out in bin order and converts each to a 32-bit power value.  Power is the squared magnitude, the energy of that
//   frequency bin during the frame, which is what the sync search compares (glossary "Spectrogram", "Bin").  The result is
//   bit-exact with `power_word` in `fw/tr-modes/src/frontend/spectrogram.rs`:
//
//   X = round(A / 2^17) = (A + 2^16) >>> 17          (27-bit signed, per bin, real and imaginary)
//   P = Xr^2 + Xi^2                                   (54-bit unsigned)
//   S = sh == 0 ? min(P, 2^32 - 1) : min((P + 2^(sh-1)) >> sh, 2^32 - 1)
//
//   The first line scales the sum down to 27 bits (the twiddle factors in ft8_combine.v are scaled by 2^17) with
//   rounding, the second squares and adds the two parts (so it is the magnitude squared), and the third shifts the power
//   down by `sh` bits, with rounding and saturation, to make it fit into 32 bits.  `sh` is the per-receiver power shift
//   register (default 16, `PWR_SHIFT_DEFAULT` in docs/S15_FT8MODEL.md): at 16, audio with 10 LSB of noise gives a noise floor
//   of about 3 counts per bin and only a single tone near full scale saturates.  The firmware can move it with the audio
//   level.  `sh` is loaded once per frame, and the caller changes it only between frames and never in the middle of a
//   read-out.
//
// Where it sits in the radio
//   Fed by: ft8_combine.v (its accumulator read port, through ft8_frame_core.v).  Feeds: ft8_ring_writer.v, which writes the
//   words to DDR3.  Started by the scheduler in ft8_spectrogram.v with `start`.
//
// How it works
//   `start` makes 1,024 requests to the read port of ft8_combine.v (`rd_en` and `rd_addr`, one per clock, with two in flight
//   to match the port's two clocks of latency) and 1,024 `out_valid` words come out, in bin order.  `done` is pulsed once
//   after the last one.  Each word passes through 8 pipeline stages (listed at the stage registers below), so a word comes out
//   about 10 clocks after its request.  The block uses 2 DSP multipliers for the squares.
//
// Flow control
//   With CREDITS > 0 the consumer (ft8_ring_writer.v, whose DDR3 writes are far slower than one word per clock) has room
//   for CREDITS words and reports on `credit` how many it freed in each clock.  A read is issued only while a credit is held,
//   so that no word is ever dropped.  CREDITS = 0 streams one word per clock with no back-pressure, for unit testbenches.

    // CREDITS: words of buffer room in the consumer (0 = no flow control).
`timescale 1ns / 1ps

module ft8_power #(
    parameter integer CREDITS = 0
) (
    // Clock (clk_dsp, 120 MHz) and synchronous reset (active high).
    input  wire        clk,
    input  wire        rst,

    input  wire        start,      // one-clock pulse: begin streaming the 1,024 bins of this frame
    input  wire [4:0]  sh,         // power shift (0 .. 31, 0 = no shift and no rounding), stable during a frame
    output reg         busy,       // high from start until the last word has left the pipeline
    output reg         done,       // one-clock pulse, together with the last (bin 1,023) word

    input  wire [1:0]  credit,     // words of downstream space freed in this clock (used if CREDITS > 0)

    // ft8_combine.v's accumulator read port: rd_en and rd_addr request a bin, rd_re and rd_im arrive 2 clocks later
    output reg         rd_en,
    output reg  [9:0]  rd_addr,
    input  wire signed [43:0] rd_re,
    input  wire signed [43:0] rd_im,

    // Power word stream: out_valid with the bin number (0 .. 1,023, in order) and the 32-bit word
    output reg         out_valid,
    output reg  [9:0]  out_bin,
    output reg  [31:0] out_word
);

    // Request sequencer: issues rd_addr = 0 .. 1,023 and then stops.  rd_re and rd_im arrive 2 clocks after rd_en (see
    // ft8_combine.v), so two requests are in flight before the first reply lands, and no separate FIFO is needed: the bin
    // index rides along in its own 2-deep shift register.  issue_cnt counts the requests (1,024 means no more to issue),
    // and `credits` is the number of words of room left downstream.
    reg [10:0] issue_cnt;     // 0 .. 1,024 (1,024 = "no more to issue")
    reg [7:0]  credits;
    reg [9:0]  p_addr;        // the power pipeline's current bin and valid flag (declared here,
    reg        p_valid;       // driven further down, read by the request sequencer)
    wire       can_issue = (CREDITS == 0) || (credits != 8'd0);
    wire       issue     = busy && issue_cnt < 11'd1024 && can_issue && !(start && !busy);

    // `credit` comes from the ring writer's pop, which follows the DDR3 write grant through the write arbiter.  It is
    // registered here, so that the grant path ends in a flip-flop and not in this adder.  The credits are therefore returned
    // one clock late, which is the safe side.
    reg [1:0] credit_q = 2'd0;
    always @(posedge clk) begin
        credit_q <= credit;
        if (rst) credits <= CREDITS;
        else     credits <= credits + {6'd0, credit_q} - (issue ? 8'd1 : 8'd0);
    end

    // Issue logic: start loads the counter, and each clock with a credit available issues the next bin.
    always @(posedge clk) begin
        rd_en <= 1'b0;
        if (rst) begin
            issue_cnt <= 11'd1024;
            busy      <= 1'b0;
        end else begin
            if (p_valid && p_addr == 10'd1023) begin
                busy <= 1'b0;   // last word leaves the pipeline this clock (`done` below)
            end
            if (start && !busy) begin
                issue_cnt <= 11'd0;
                busy      <= 1'b1;
            end else if (issue) begin
                rd_en   <= 1'b1;
                rd_addr <= issue_cnt[9:0];
                issue_cnt <= issue_cnt + 11'd1;
            end
        end
    end

    // The bin index shadow, 2 deep, to land together with rd_re and rd_im.
    reg [9:0] addr_d1, addr_d2;
    reg       ven_d1, ven_d2;
    always @(posedge clk) begin
        addr_d1 <= rd_addr;
        ven_d1  <= rd_en && !rst;
        addr_d2 <= addr_d1;
        ven_d2  <= ven_d1 && !rst;
    end

    // ---- round, power, shift, saturate: one small step per clock ----
    // Stage 1, X = round(A / 2^17) = (A + 2^16) >>> 17: the truncated arithmetic shift plus the top dropped bit gives the
    // same result without a full adder in front of the shift (the top dropped bit is exactly the "add half, then floor"
    // rounding decision in two's complement, whichever sign A has).  rd_re[43:17] and so on are plain part-selects, so the
    // add is modulo-2^27 arithmetic and the two's complement result is exact.  A fits into 44 bits (the header of ft8_combine.v
    // shows |A| < 2^43), so X fits into 27 bits and cannot wrap here.
    reg signed [26:0] xr1, xi1;
    // Stage 2, the squares, at P's full width: with `$unsigned(xr * xr)` the product would be sized self-determined at X's
    // own width and lose P's top bits, and only the strongest bins would come out wrong.  |X| <= 2^26, so P <= 2^53.
    reg [53:0] sq_r2, sq_i2;
    // Stage 3, P = the sum of the squares; stage 4, P + 2^(sh-1) (the rounding constant); stages 5 and 6, the shift right by
    // sh (first by sh[4:3] x 8, then by sh[2:0]); stage 7, the low word and the overflow flag; stage 8, saturate (out_word).
    // `sh` is stable for the whole frame, so the rounding constant is registered from it directly.
    reg [54:0] p3, p4, p5a, p5;
    reg [54:0] rnd;
    // Stage 7 registers the low word and the overflow flag (four kept copies, one for each output byte); stage 8 is out_word.
    // Done in one clock, the 23-bit compare into all 32 set inputs did not meet timing.  v holds the valid flags of stages 1 .. 8
    // and a1 .. a7 carry the bin number alongside.
    reg [31:0] p6;
    reg [3:0]  ov6 /* synthesis syn_preserve = 1 */;
    reg [7:0]  v;             // valid of stages 1 .. 8
    reg [9:0]  a1, a2, a3, a4, a5, a6, a7;

    wire signed [53:0] xr_w = xr1;
    wire signed [53:0] xi_w = xi1;
    always @(posedge clk) begin
        rnd   <= (sh == 5'd0) ? 55'd0 : (55'd1 << (sh - 5'd1));
        xr1   <= rd_re[43:17] + rd_re[16];
        xi1   <= rd_im[43:17] + rd_im[16];
        sq_r2 <= xr_w * xr_w;
        sq_i2 <= xi_w * xi_w;
        p3    <= sq_r2 + sq_i2;
        p4    <= p3 + rnd;
        p5a   <= p4 >> {sh[4:3], 3'd0};
        p5    <= p5a >> sh[2:0];
        p6    <= p5[31:0];
        ov6   <= {4{|p5[54:32]}};
        out_word <= {ov6[3] ? 8'hFF : p6[31:24], ov6[2] ? 8'hFF : p6[23:16],
                     ov6[1] ? 8'hFF : p6[15:8],  ov6[0] ? 8'hFF : p6[7:0]};
        a1 <= addr_d2; a2 <= a1; a3 <= a2; a4 <= a3; a5 <= a4; a6 <= a5; a7 <= a6;
        out_bin <= a7;
        done    <= !rst && v[6] && (a7 == 10'd1023);   // with the last word's out_valid
    end

    always @(posedge clk) begin
        if (rst) v <= 8'd0;
        else     v <= {v[6:0], ven_d2};
    end
    // The valid flag of stage 7 (the word that is out_word one clock later) goes back to the request sequencer, and
    // stage 8's is out_valid.

    always @* begin
        p_valid   = v[6];         // stage 7: the word that is out_word one clock later
        p_addr    = a7;
        out_valid = v[7];
    end

endmodule
