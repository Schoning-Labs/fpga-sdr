// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// bk_front: the input stage of the receiver back end. It takes the receiver bank's shared stream
// (one 24-bit I/Q sample per clock at most, from any of the receivers) and does four things to
// every sample before the rest of the back end sees it: it drops the samples of receivers that
// are disabled, marks the first sample after a receiver was enabled, multiplies the sample by
// 2^in_shift (a shift with saturation to 24 bits), and runs the noise blanker. The software
// model is fw/tr-dsp/src/backend/nb.rs and docs/R4_BACKEND.md sections 3.1 and 3.9 hold the
// specification. Terms such as noise blanker and fixed point are in docs/learn/GLOSSARY.md.
//
// Where it sits: rx_bank.v (rtl/rx) feeds it at 48, 96, 192 or 384 ksps per receiver. Its output
// goes through a FIFO to bk_decim.v, which brings every receiver down to 24 ksps.
//
// Input scaling: the bank's samples use only about 17 of the 24 bits (the bank's CIC stages end
// in 16 bits and its FIR has unity gain, so a full-scale ADC tone gives |IQ| = 10,043). The first
// operation is x = sat24(in << in_shift) per receiver, default in_shift = 6, which puts a full
// scale ADC tone at 2^19.3, 22.3 dB below the 24-bit full scale, and keeps 6 fraction bits of the
// bank's resolution for the gain of the decimation filters further down.
//
// Noise blanker: impulse noise (a spark, a power line pulse) is much stronger than the signal but
// lasts a few samples. The blanker follows the magnitude of the signal with a slowly moving
// estimate of its normal level (the floor) and, when one sample is more than thr/16 times that
// floor, replaces it and the next hold - 1 samples by the last good sample.
//   - Magnitude: mag = max(|i|,|q|) + min/4 + min/8, the usual cheap approximation of the length
//     of a complex number (alpha-max-plus-beta-min, at most 6.8 percent too high). 24 bits.
//   - Floor: an unsigned 24.16 fixed point number (40 bits) that follows the magnitude with a
//     shift time constant, floor += ((mag << 16) - floor) >> k, where k is k_down when the
//     magnitude is below the floor (so the floor falls quickly) and k_up when above (so it
//     rises slowly and a burst of noise does not drag it up). The time constants are 2^k samples.
//     The first sample after enable sets floor = mag << 16. The floor is updated by every
//     sample, blanked or not, and also while the blanker is switched off, so that switching it
//     on later needs no settling time.
//   - Trigger: when not already holding and mag x 16 > (floor >> 16) x thr, with thr in U4.4
//     (a value of 96 means 6.0). This takes one 24 x 8 multiply, which is the only DSP block here.
//   - Hold: a trigger replaces the next `hold` samples by the last good sample, and the number of
//     replaced samples is counted per receiver (the blanked status register).
//
// Pipeline: about fifteen stages, one sample per clock. The per-receiver state (floor, hold
// counter, last good sample, blanked count) is in registers or small memories, read and written a
// few clocks apart. The bank delivers the same receiver's samples at least 200 ADC samples apart,
// far more than the depth of the pipeline, so one receiver's state is never in flight twice.
// Every single-clock step of the scaling, the floor update and the blank decision was too slow
// at the DSP clock, so each is split over several stages; latency is not important here.

`timescale 1ns / 1ps

module bk_front #(
    parameter integer NRX = 8         // receivers built (rx_backend.v): per-receiver state is sized by it
) (
    input  wire         clk,        // DSP clock
    input  wire         rst,        // synchronous reset

    input  wire         in_valid,   // one-clock pulse: a sample from the bank is on in_rx/in_i/in_q
    input  wire [2:0]   in_rx,      // receiver number of that sample
    input  wire [23:0]  in_i,       // I, two's complement
    input  wire [23:0]  in_q,       // Q

    input  wire [7:0]   en,         // per receiver: enabled (samples of a disabled receiver are dropped)
    input  wire [7:0]   epoch,      // per receiver: epoch bit, flips at every enable, travels with the samples
    input  wire [23:0]  in_shift,   // 3 bits per receiver
    input  wire [7:0]   nb_en,      // per receiver: noise blanker on
    // The next four settings are the values of one receiver each, read from rx_backend's
    // settings memories at the receiver number that this module gives out on the cfg_* ports
    // (so the select is in the memory and not in here)
    output wire [2:0]   cfg_r2c,    // the receiver nb_kdown and nb_kup are wanted for
    output wire [2:0]   cfg_r3,     // ... nb_thr
    output wire [2:0]   cfg_r4,     // ... nb_hold
    input  wire [7:0]   nb_thr,     // U4.4
    input  wire [4:0]   nb_kdown,   // floor time constant 2^k samples when the magnitude is below the floor
    input  wire [4:0]   nb_kup,     // the same when it is above
    input  wire [15:0]  nb_hold,    // samples replaced after a trigger

    output reg          first_ev,   // first sample after enable accepted this cycle
    output reg  [2:0]   first_rx,   // its receiver

    output reg          out_push,   // one-clock pulse: out_data is a finished sample
    output reg  [52:0]  out_data,   // {epoch, rx[2:0], first, i[23:0], q[23:0]}
    output wire [255:0] blanked     // 32 bits per receiver: samples replaced by the blanker since reset
) /* synthesis syn_srlstyle = "registers" */;
    // ---------------------------------------------------------------- input, registered
    // The bank's output is registered first, because it would otherwise go straight into the
    // accept and first-sample logic, which is too long a path. `en` is registered together with
    // it, so each sample still meets the enable it had when it arrived. The receiver number is
    // kept twice, one copy for the first-sample logic and one for stage 1, to halve its fan-out.
    reg        in_v0;
    (* syn_preserve = 1 *) reg [2:0] in_rx0, in_rx0b;   // copies: the first-sample logic, stage 1
    reg [23:0] in_i0, in_q0;
    reg [7:0]  en0;
    always @(posedge clk) begin
        in_v0   <= in_valid && !rst;
        in_rx0  <= in_rx;
        in_rx0b <= in_rx;
        in_i0   <= in_i;
        in_q0   <= in_q;
        en0     <= en;
    end

    // ---------------------------------------------------------------- first-sample tracking
    // seen[r] says that receiver r has delivered a sample since it was enabled. A disabled
    // receiver clears its bit, so the first accepted sample after enable finds it clear and is
    // flagged (first_ev), and accept is a sample from an enabled receiver.
    reg [7:0] seen;
    wire accept = in_v0 && en0[in_rx0];
    integer k;
    integer k2;
    always @(posedge clk) begin
        first_ev <= 1'b0;
        if (rst) begin
            seen <= 8'd0;
        end else begin
            for (k = 0; k < NRX; k = k + 1)
                if (!en0[k]) seen[k] <= 1'b0;
            if (accept) begin
                seen[in_rx0] <= 1'b1;
                first_ev     <= !seen[in_rx0];
                first_rx     <= in_rx0;
            end
        end
    end

    // ---------------------------------------------------------------- stage 1: register input
    // The sample is registered together with its valid flag, first flag and receiver number.
    // The registers marked syn_srlstyle are kept as plain flip-flops (see the note below).
    reg        v1, f1;
    (* syn_srlstyle = "registers" *) reg [2:0]  r1;
    (* syn_srlstyle = "registers" *) reg signed [23:0] i1, q1;
    reg [2:0]  sh1;                   // the receiver's in_shift, selected here for stage 2s
    always @(posedge clk) begin
        v1 <= accept && !rst;
        f1 <= !seen[in_rx0b];
        r1 <= in_rx0b;
        i1 <= in_i0;
        q1 <= in_q0;
        sh1 <= in_shift[in_rx0b*3 +: 3];
    end

    // The sample pipeline registers carry syn_srlstyle = "registers": Gowin synthesis otherwise
    // turns the i/q delay through the stages into a block-RAM shift register whose write mode
    // its own place-and-route then rejects (PA2122).
    // The scaling, the floor update and the blank decision are each spread over several
    // stages (2s, 2a-2d, 3a, 3s, 3b, 3c, 6a-6c below), fifteen stages in all. The floor is carried
    // down the pipeline to the threshold multiply instead of being read back from floor_r.

    // ---------------------------------------------------------------- stages 2s, 2a: scale
    // scale(v, sh) = sat24(v << sh): the shift (2s), then the saturation (2a)
    function signed [23:0] sat24;
        input signed [31:0] w;
        begin
            if (w > 32'sd8388607)
                sat24 = 24'sd8388607;
            else if (w < -32'sd8388608)
                sat24 = -24'sd8388608;
            else
                sat24 = w[23:0];
        end
    endfunction

    reg        v2s, f2s;
    (* syn_srlstyle = "registers" *) reg [2:0]  r2s;
    reg signed [31:0] wi2s, wq2s;
    always @(posedge clk) begin
        v2s  <= v1 && !rst;
        f2s  <= f1;
        r2s  <= r1;
        wi2s <= $signed({{8{i1[23]}}, i1}) <<< sh1;
        wq2s <= $signed({{8{q1[23]}}, q1}) <<< sh1;
    end

    reg        v2a, f2a;
    (* syn_srlstyle = "registers" *) reg [2:0]  r2a;
    (* syn_srlstyle = "registers" *) reg signed [23:0] i2a, q2a;
    always @(posedge clk) begin
        v2a <= v2s && !rst;
        f2a <= f2s;
        r2a <= r2s;
        i2a <= sat24(wi2s);
        q2a <= sat24(wq2s);
    end

    reg [39:0] floor_r [0:NRX-1];   // the floor of each receiver, unsigned 24.16
    reg [7:0]  primed;              // per receiver: floor_r holds a value since the last reset

    // ---------------------------------------------------------------- stages 2b-2d: magnitude
    // M = max(|i|, |q|) + min/4 + min/8: absolute values (2b), max and min (2c), the sum (2d)
    reg        v2b, f2b;
    (* syn_srlstyle = "registers" *) reg [2:0]  r2b;
    reg [23:0] ai2b, aq2b;            // |-2^23| = 2^23 fits 24 bits unsigned
    always @(posedge clk) begin
        v2b  <= v2a && !rst;
        f2b  <= f2a;
        r2b  <= r2a;
        ai2b <= i2a[23] ? -i2a : i2a;
        aq2b <= q2a[23] ? -q2a : q2a;
    end

    reg        v2c, f2c;
    (* syn_srlstyle = "registers" *) reg [2:0]  r2c;
    reg [23:0] mx2c, mn2c;
    always @(posedge clk) begin
        v2c  <= v2b && !rst;
        f2c  <= f2b;
        r2c  <= r2b;
        mx2c <= (ai2b >= aq2b) ? ai2b : aq2b;
        mn2c <= (ai2b >= aq2b) ? aq2b : ai2b;
    end

    reg        v2, f2;
    (* syn_srlstyle = "registers" *) reg [2:0]  r2;
    (* syn_srlstyle = "registers" *) reg [24:0] mag2;
    // 2: the magnitude sum mx + mn/4 + mn/8 (25 bits); the floor of this receiver is read now
    // so that it is ready when stage 3a needs it
    reg [39:0] fl2;                   // this receiver's floor, read a stage ahead of its use
    reg        set2;
    reg [4:0]  kd2, ku2;              // and its k_down / k_up
    always @(posedge clk) begin
        fl2  <= floor_r[r2c];
        set2 <= f2c || !primed[r2c];
        kd2  <= nb_kdown;
        ku2  <= nb_kup;
        v2 <= v2c && !rst;
        f2 <= f2c;
        r2 <= r2c;
        mag2 <= {1'b0, mx2c} + {3'b0, mn2c[23:2]} + {4'b0, mn2c[23:3]};
    end

    // ---------------------------------------------------------------- stages 3a-3c: floor update
    // floor' = floor + ((M << 16) - floor) >>> k, k = k_down below the floor, k_up above; the
    // first sample of a receiver (or its first after reset) sets floor = M << 16.

    // 3a: read the floor, difference, direction
    reg        v3a, f3a, set3a;
    (* syn_srlstyle = "registers" *) reg [2:0]  r3a;
    (* syn_srlstyle = "registers" *) reg [24:0] mag3a;
    reg [39:0] fl3a;
    reg signed [41:0] diff3a;
    reg [4:0]  ksh3a;
    always @(posedge clk) begin : st3a
        reg [40:0] m16;
        reg [39:0] fl;
        reg        below;
        m16   = {mag2, 16'd0};
        fl    = fl2;
        below = m16 < {1'b0, fl};
        v3a    <= v2 && !rst;
        f3a    <= f2;
        r3a    <= r2;
        mag3a  <= mag2;
        fl3a   <= fl;
        set3a  <= set2;
        diff3a <= $signed({1'b0, m16}) - $signed({2'b0, fl});
        ksh3a  <= below ? kd2 : ku2;
    end

    // 3s: the step's shift by the multiple of 8 (3b does the rest)
    reg        v3s, f3s, set3s;
    (* syn_srlstyle = "registers" *) reg [2:0]  r3s;
    (* syn_srlstyle = "registers" *) reg [24:0] mag3s;
    reg [39:0] fl3s;
    reg signed [41:0] step3s;
    reg [2:0]  kf3s;
    always @(posedge clk) begin
        v3s    <= v3a && !rst;
        f3s    <= f3a;
        r3s    <= r3a;
        mag3s  <= mag3a;
        fl3s   <= fl3a;
        set3s  <= set3a;
        step3s <= diff3a >>> {ksh3a[4:3], 3'b000};
        kf3s   <= ksh3a[2:0];
    end

    // 3b: step
    reg        v3b, f3b, set3b;
    (* syn_srlstyle = "registers" *) reg [2:0]  r3b;
    (* syn_srlstyle = "registers" *) reg [24:0] mag3b;
    reg [39:0] fl3b;
    reg signed [41:0] step3b;
    always @(posedge clk) begin
        v3b    <= v3s && !rst;
        f3b    <= f3s;
        r3b    <= r3s;
        mag3b  <= mag3s;
        fl3b   <= fl3s;
        set3b  <= set3s;
        step3b <= step3s >>> kf3s;
    end

    // 3c: new floor, written back (the first sample of a receiver sets floor = magnitude << 16
    // instead of stepping)
    wire signed [41:0] upd3 = $signed({2'b0, fl3b}) + step3b;
    wire [39:0] newfl3 = set3b ? {mag3b[23:0], 16'd0} : upd3[39:0];

    reg        v3, f3;
    (* syn_srlstyle = "registers" *) reg [2:0]  r3;
    (* syn_srlstyle = "registers" *) reg [24:0] mag3;
    reg [39:0] fl3;
    // the new floor is registered (fl3) and written into floor_r from there a clock later
    always @(posedge clk) begin
        if (rst)
            primed <= 8'd0;
        else if (v3) begin
            floor_r[r3] <= fl3;
            primed[r3]  <= 1'b1;
        end
        v3 <= v3b && !rst;
        f3 <= f3b;
        r3 <= r3b;
        mag3 <= mag3b;
        fl3 <= newfl3;
    end

    // ---------------------------------------------------------------- stages 4-5: floor x thr
    // The threshold is the integer part of the floor (24 bits) times thr (U4.4); the product is
    // ready two clocks later (the multiplier's own registers), which is stage 5.
    wire signed [33:0] thr_p;
    bk_mul #(.AW(25), .BW(9)) u_mul (
        .clk(clk),
        .a({1'b0, fl3[39:16]}),
        .b({1'b0, nb_thr}),
        .p(thr_p)
    );
    reg        v4, f4, v5, f5;
    // f5 in copies for stage 6a (as one register its fan-out of 131 took 5 ns of routing):
    // 0 the hold count, 1 last6, 2 bc6, 3 bc6p1
    (* syn_preserve = 1 *) reg [3:0] f5c;
    // r4 in copies for the stage-5 state reads (its fan-out of 55 into the LUT-RAM read
    // addresses was too slow): r4a for holding and last, r4b for bcount
    (* syn_preserve = 1 *) reg [2:0] r4a, r4b;
    (* syn_srlstyle = "registers" *) reg [2:0]  r4, r5;
    (* syn_srlstyle = "registers" *) reg [24:0] mag4, mag5;
    always @(posedge clk) begin
        v4 <= v3 && !rst;  f4 <= f3;  r4 <= r3;  mag4 <= mag3;
        v5 <= v4 && !rst;  f5 <= f4;  r5 <= r4;  mag5 <= mag4;
        f5c <= {4{f4}};
        r4a <= r3;
        r4b <= r3;
    end

    // the receiver's blanker state and settings, read at stage 5 (from r4) for stage 6a
    reg [15:0] hold5, nbh5;
    reg [47:0] last5;
    reg [31:0] bc5;
    reg        nb5;

    // ---------------------------------------------------------------- stages 6a-6b: blank or pass
    // The blanker state of each receiver: holding is the number of samples still to be replaced,
    // last is the last good sample ({i, q}) and bcount the number of samples replaced so far.
    reg [15:0] holding [0:NRX-1];
    reg [47:0] last    [0:NRX-1];
    reg [31:0] bcount  [0:NRX-1];

    // 6a: read the receiver's blanker state, trigger decision
    reg        v6, f6, trig6, nb6;
    (* syn_srlstyle = "registers" *) reg [2:0]  r6;
    // The scaled sample from stage 2a to stage 6a, ten clocks: a LUT-RAM delay (bk_dly in
    // bk_ram.v) in place of ten registers of 48 bits, since nothing in between reads it.
    wire signed [23:0] i6, q6;
    bk_dly #(.W(48), .N(10)) u_iqd (.clk(clk), .d({i2a, q2a}), .q({i6, q6}));
    reg [15:0] hold6, nbh6;
    reg [47:0] last6;
    reg [31:0] bc6;
    reg [31:0] bc6p1;                 // bc6 + 1
    reg [15:0] hold6m1, nbh6m1;       // hold6 - 1, nbh6 - 1
    reg        hold6nz, nbh6nz;       // hold6 != 0, nbh6 != 0
    always @(posedge clk) begin
        hold5 <= holding[r4a];
        last5 <= last[r4a];
        bc5   <= bcount[r4b];
        nb5   <= nb_en[r4];
        nbh5  <= nb_hold;
    end
    always @(posedge clk) begin : st6a
        reg [15:0] hold_cur;
        hold_cur = f5c[0] ? 16'd0 : hold5;
        v6    <= v5 && !rst;
        f6    <= f5;
        r6    <= r5;
        nb6   <= nb5;
        nbh6  <= nbh5;
        hold6 <= hold_cur;
        last6 <= f5c[1] ? 48'd0 : last5;
        bc6   <= f5c[2] ? 32'd0 : bc5;
        bc6p1 <= (f5c[3] ? 32'd0 : bc5) + 32'd1;
        hold6m1 <= hold_cur - 16'd1;
        nbh6m1  <= nbh5 - 16'd1;
        hold6nz <= hold_cur != 16'd0;
        nbh6nz  <= nbh5 != 16'd0;
        trig6 <= (hold_cur == 16'd0) && ({3'b0, mag5, 4'd0} > {1'b0, thr_p[31:0]});
    end

    // 6b: update and output. A sample is passed unchanged when the blanker is off or not holding.
    // While holding (the trigger has just fired or the hold counter is running), the last good
    // sample goes out instead, the hold counter counts down and the blanked counter goes up.
    // The new state is written back a clock later (6c) from registers w7, r7, h7, l7, b7.
    reg        w7;
    reg [2:0]  r7;
    reg [15:0] h7;
    reg [47:0] l7;
    reg [31:0] b7;
    // hnew = trig6 ? nbh6 : hold6, and hnew - 1, hnew != 0, from 6a's precomputed pieces
    wire [15:0] hnew_m1 = trig6 ? nbh6m1 : hold6m1;
    wire        hnew_nz = trig6 ? nbh6nz : hold6nz;

    genvar g;
    generate
        for (g = 0; g < 8; g = g + 1) begin : bl
            if (g < NRX) begin : used
                assign blanked[g*32 +: 32] = bcount[g];
            end else begin : unused
                assign blanked[g*32 +: 32] = 32'd0;
            end
        end
    endgenerate

    always @(posedge clk) begin
        out_push <= 1'b0;
        w7       <= 1'b0;
        if (rst) begin
            for (k2 = 0; k2 < NRX; k2 = k2 + 1)
                bcount[k2] <= 32'd0;
        end else begin
            if (v6) begin
                out_push <= 1'b1;
                w7  <= 1'b1;
                r7  <= r6;
                if (!nb6) begin
                    h7 <= 16'd0;
                    l7 <= {i6, q6};
                    b7 <= bc6;
                    out_data <= {epoch[r6], r6, f6, i6, q6};
                end else if (hnew_nz) begin
                    h7 <= hnew_m1;
                    l7 <= last6;
                    b7 <= bc6p1;
                    out_data <= {epoch[r6], r6, f6, last6};
                end else begin
                    h7 <= 16'd0;
                    l7 <= {i6, q6};
                    b7 <= bc6;
                    out_data <= {epoch[r6], r6, f6, i6, q6};
                end
            end
            // 6c: the receiver's new blanker state, written from registers a clock later (done in
            // one clock, the trigger decision would fan out to every entry's write data)
            if (w7) begin
                holding[r7] <= h7;
                last[r7]    <= l7;
                bcount[r7]  <= b7;
            end
        end
    end
    assign cfg_r2c = r2c;
    assign cfg_r3  = r3;
    assign cfg_r4  = r4;
endmodule
