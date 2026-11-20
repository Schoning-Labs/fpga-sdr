// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// bk_cordic: an iterative CORDIC, the circuit that the demodulators use to find the length and
// the angle of a complex sample (vectoring mode) and to rotate a complex sample by an angle
// (rotation mode). It is the only place in the back end that does these two jobs, and bk_post.v
// shares it between all demodulators and all receivers (docs/R4_BACKEND.md section 3.4, model in
// fw/tr-dsp/src/backend/cordic.rs). The terms are explained in docs/learn/GLOSSARY.md.
//
// How a CORDIC works: rotating a vector (x, y) by an angle normally needs multiplications by
// sine and cosine. A CORDIC rotates by a series of small fixed angles atan(2^-i), i = 0, 1, 2 and so
// on, each of which needs only a shift and an add, and chooses the direction of every small
// rotation (plus or minus) so that the sum of the small angles approaches the wanted angle. Each
// step grows the vector by sqrt(1 + 2^(-2i)), so after 20 steps the vector is longer by the
// constant K = 1.6467602581, which the caller removes with one multiplication by BK_KINV.
// In vectoring mode (rot = 0) the direction is chosen to drive y to zero, so what is left in x
// is K times the length of the input and the sum of the angles that were used is its angle.
// In rotation mode (rot = 1) the direction is chosen to drive the angle accumulator z to zero,
// so the input vector is turned by z_in and x_out is K times the real part of the result,
// K x Re(v e^(j 2 pi z)).
//
// Numbers: 20 iterations; x and y are 30 bits (the 24-bit input shifted up by 4 for fraction
// bits, with 2 bits of room for the gain); angles are 24 bits in units of 1/2^24 of a turn (so
// one half turn is 2^23 and wrapping around a full turn comes free with two's complement
// arithmetic). The first step, atan(1), is 1/8 turn = 2^21, and the table of the other angles is
// in bk_consts.vh. Measured against floating point: magnitude within 1.1 LSB, angle within
// 7 / 2^24 of a turn at a length of 8 M.
//
// The vector is first turned into the right half plane: in vectoring mode a negative x_in
// starts the angle at half a turn and negates the vector; in rotation mode an angle outside
// -1/4 .. +1/4 turn is first reduced by half a turn and the vector negated. A CORDIC with these
// angles only converges within about +-99 degrees, which is why this is needed.
//
// Timing: start in cycle 0, done pulses in cycle 42 with the results valid from then on, so one
// vectoring or rotation takes 42 clocks. Each iteration takes two clocks: the shifts x >>> i and
// y >>> i and the angle table read are registered in the first, and the add or subtract is done
// in the second (a variable shift followed by a 30-bit add in one clock was a critical path).
// `start` is taken one clock late, from four registered copies, because one register for start
// fanned out to about 90 load enables; the inputs must therefore stay put for that extra clock
// (bk_post holds them until the next start). The result registers and done do not depend on start.

`timescale 1ns / 1ps

module bk_cordic (
    input  wire               clk,
    input  wire               rst,      // synchronous reset, stops a run
    input  wire               start,    // one-clock pulse: begin (the inputs below must be stable from here on for 2 clocks)
    input  wire               rot,      // 0: vectoring (length and angle), 1: rotation by z_in
    input  wire signed [23:0] x_in,     // vector, real part (24-bit scale)
    input  wire signed [23:0] y_in,     // vector, imaginary part
    input  wire signed [23:0] z_in,     // angle to rotate by, 1/2^24 turn (rotation mode only)
    output reg                done,     // one-clock pulse, results valid from here until the next start
    output reg  signed [29:0] x_out,    // K x length (vectoring) or K x Re of the rotated vector (rotation); K is not removed here
    output reg  signed [23:0] z_out     // angle of the input vector in 1/2^24 turn (vectoring only)
);
    `include "rtl/rx_backend/bk_consts.vh"

    // working registers: the vector (x, y), the angle accumulator z, the mode, the iteration
    // number i and the busy flag
    reg signed [29:0] x, y;
    reg signed [23:0] z;
    reg        mode_rot;
    reg [4:0]  i;
    reg        busy;
    reg        half;                // 0: shift clock, 1: add clock of the two clocks of an iteration
    reg        i_last;              // i == BK_CORDIC_ITER - 1, kept as a register
    reg signed [29:0] dx_r, dy_r;
    reg signed [23:0] at_r;
    // dx_r, dy_r and at_r hold the shifted vector halves and the table angle of this iteration.
    // The direction bit is kept in three copies, one per adder (as one net it would fan out to all
    // 84 bits). Each adder adds or subtracts its operand as x + (d ^ m) + m, m being all ones to
    // subtract.
    (* syn_preserve = 1 *) reg cw_x, cw_y, cw_z;
    wire [30:0] x_sum = {x, 1'b1} + {dx_r ^ {30{!cw_x}}, !cw_x};
    wire [30:0] y_sum = {y, 1'b1} + {dy_r ^ {30{cw_y}},  cw_y};
    wire [24:0] z_sum = {z, 1'b1} + {at_r ^ {24{!cw_z}}, !cw_z};

    // inputs widened to 30 bits and shifted up by 4 (four fraction bits)
    wire signed [29:0] xs = {{6{x_in[23]}}, x_in} <<< 4;
    wire signed [29:0] ys = {{6{y_in[23]}}, y_in} <<< 4;
    // rotation pre-step: angles outside [-1/4, 1/4) turn rotate by half a turn first
    wire rot_flip = (z_in >= 24'sd4194304) || (z_in < -24'sd4194304);

    // the shift amount in four copies, one per half of each shifter (as the one register i, its
    // fan-out into both 30-bit shifters took 3 ns of routing); the two halves of each shifted
    // value are put together below
    (* syn_preserve = 1 *) reg [4:0] i_xl, i_xh, i_yl, i_yh;
    wire signed [29:0] dx_l = y >>> i_yl;
    wire signed [29:0] dx_h = y >>> i_yh;
    wire signed [29:0] dy_l = x >>> i_xl;
    wire signed [29:0] dy_h = x >>> i_xh;
    wire signed [29:0] dx = {dx_h[29:15], dx_l[14:0]};
    wire signed [29:0] dy = {dy_h[29:15], dy_l[14:0]};
    wire               cw = mode_rot ? z[23] : !y[29];   // vectoring: y >= 0; rotation: z < 0
    wire signed [23:0] at = bk_atan(i);

    // start_c: 0 busy/half/i/mode, 1 x, 2 y, 3 z
    (* syn_preserve = 1 *) reg [3:0] start_c;
    always @(posedge clk)
        start_c <= rst ? 4'd0 : {4{start}};

    always @(posedge clk) begin
        done <= 1'b0;
        if (!rst && !start_c[0] && busy && half && i_last) begin
            done <= 1'b1;
            x_out <= x_sum[30:1];
            z_out <= z_sum[24:1];
        end
        if (rst) begin
            busy <= 1'b0;
        end else if (start_c[0]) begin
            busy <= 1'b1;
            half <= 1'b0;
            i <= 5'd0;
            i_last <= (BK_CORDIC_ITER == 1);
            {i_xl, i_xh, i_yl, i_yh} <= 20'd0;
            mode_rot <= rot;
        end else if (busy && !half) begin
            dx_r <= dx;
            dy_r <= dy;
            at_r <= at;
            cw_x <= cw;
            cw_y <= cw;
            cw_z <= cw;
            half <= 1'b1;
        end else if (busy) begin
            if (i_last)
                busy <= 1'b0;
            i <= i + 5'd1;
            i_last <= (i + 5'd1 == BK_CORDIC_ITER - 1);
            {i_xl, i_xh, i_yl, i_yh} <= {4{i + 5'd1}};
            half <= 1'b0;
        end
    end

    // x, y, z: loaded at the start (each from its own copy of it), then the add clock of each
    // iteration.
    // vectoring, y >= 0: x += y>>i, y -= x>>i, z += atan  (rotation, z < 0: the same)
    // x +/- dx as x + (dx ^ m) + m with m all-zero or all-one (two's complement), one adder each
    // instead of two and a mux; same sums (and the + 1 of the two's complement as
    // ({a,1} + {b,1}) >> 1, inside the adder)
    // (the start values are worked out in the clock start_c is loaded, from the inputs, which
    // the caller set with start)
    wire neg_in = rot ? rot_flip : x_in[23];
    reg signed [29:0] x_ld, y_ld;
    reg signed [23:0] z_ld;
    always @(posedge clk) begin
        x_ld <= neg_in ? -xs : xs;
        y_ld <= neg_in ? -ys : ys;
        z_ld <= !rot ? (x_in[23] ? -24'sd8388608 : 24'sd0)
                     : (rot_flip ? z_in - 24'sd8388608 : z_in);
        if (start_c[1])
            x <= x_ld;
        else if (busy && half)
            x <= x_sum[30:1];
        if (start_c[2])
            y <= y_ld;
        else if (busy && half)
            y <= y_sum[30:1];
        if (start_c[3])
            z <= z_ld;
        else if (busy && half)
            z <= z_sum[24:1];
    end
endmodule
