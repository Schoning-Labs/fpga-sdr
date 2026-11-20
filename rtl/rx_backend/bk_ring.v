// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// bk_ring: the output ring writer of the receiver back end. It collects every receiver's 16-bit
// output samples (audio, or I and Q pairs) into blocks of 128 samples and writes them to a ring
// buffer of that receiver in DDR3, so that the firmware can read the audio of any receiver (for
// noise reduction, for the FT8 decoders, for recording) without taking part in the real-time
// work. It writes through a write-lane client port of rtl/ddr3/ddr3_write_arbiter.v (the signals
// req, addr, burstlen, wdata, wmask, gnt and done). The specification is docs/R4_BACKEND.md section
// 3.10 and the terms are explained in docs/learn/GLOSSARY.md.
//
// Ring layout (addresses in 64-bit lane words): slot s of receiver r starts at
// ring_base[r] + s * W, W = 34 (audio: 2 header words + 32 words of 4 x 16-bit samples) or 66 (IQ:
// 2 + 64 words of 2 x {Q, I} 16-bit pairs); s runs modulo 2^ring_log2[r]. Samples are
// little-endian: audio sample k of a word at bits 16k+15..16k, IQ pair k at 32k+31..32k with I in
// the low half.
//   header word 0: bits 47..0 HL2 stamp of the block's first sample, 50..48 receiver, 56 IQ flag
//   header word 1: bits 31..0 block sequence number since the ring was enabled,
//                  47..32 S-meter (1/64 dB) when the block completed
// The header is written after the payload; ring_wptr[r] (blocks, free-running) advances and
// block_done[r] pulses only when the header write has landed, so the firmware never reads a
// half-written slot. There is no back-pressure: the fabric overwrites old slots when the ring is
// full, so the firmware must keep up (at 12 ksps one block lasts 10.7 ms, 128 / 12,000 s).
// A beginner can see the HL2 stamp as a time stamp in units of 1/76.8 million of a second, which
// lets the firmware tell exactly when each block started.
//
// How the writing works: samples arrive one at a time from bk_post. A small packer per receiver
// puts them together into 64-bit words (four audio samples or two IQ pairs per word), each
// finished word goes through an address pipeline that computes its DDR3 address and into a write
// queue, and a small state machine takes the entries off the queue and does the DDR3 write, one
// word at a time. After the 128th sample of a block the two header words are queued, and when the
// last of them has been written the pointer for that receiver is advanced.
//
// Runs in the back end's clock. At integration the lane side needs the DDR3 fabric clock: an
// asynchronous FIFO goes between this module's write queue and its lane FSM (docs/R4_BACKEND.md
// section 9).

`timescale 1ns / 1ps

module bk_ring #(
    parameter integer ADDR_WIDTH = 32,
    parameter integer NRX = 8           // receivers built (rx_backend.v): per-receiver state is sized by it
) (
    input  wire                  clk,          // back end clock (DSP clock)
    input  wire                  rst,          // synchronous reset

    input  wire                  in_valid,     // one-clock pulse: a finished output sample
    input  wire [2:0]            in_rx,        // its receiver
    input  wire [15:0]           in_s0,        // audio, or I in IQ mode
    input  wire [15:0]           in_s1,        // Q in IQ mode
    input  wire                  in_iq,        // the receiver is in IQ mode (two samples per pair)
    input  wire [47:0]           in_stamp,     // HL2 sample index of the sample
    input  wire [127:0]          smeter,       // 16 per receiver

    output wire [2:0]            cfg_rx,       // the receiver whose ring base is wanted
    input  wire [31:0]           ring_base,    // that receiver's (lane-word address), from rx_backend's memory
    input  wire [31:0]           ring_log2,    // 4 per receiver: log2 of the number of slots
    input  wire [7:0]            ring_en,      // per receiver: ring enabled (disabled receivers write nothing)
    output wire [255:0]          ring_wptr,    // 32 per receiver: blocks completely written
    output reg  [7:0]            block_done,   // per receiver: one-clock pulse when a block has landed
    output reg                   overflow,     // pulse: a word was dropped (queue full)

    // write-lane client port (rtl/ddr3/ddr3_write_arbiter.v)
    output reg                   req,          // request a one-word write
    output reg  [ADDR_WIDTH-1:0] addr,         // lane word address
    output wire [7:0]            burstlen,     // always 1 word
    output reg  [63:0]           wdata,        // the word
    output wire [7:0]            wmask,        // always all 8 bytes
    input  wire                  gnt,          // the arbiter grants the lane (not used here, req stays up until done)
    input  wire                  done          // the write has been done
) /* synthesis syn_srlstyle = "registers" */;
    assign burstlen = 8'd1;
    assign wmask    = 8'hFF;

    // ---------------------------------------------------------------- per receiver state
    reg [6:0]  cnt   [0:NRX-1];     // samples in the current block
    reg [63:0] word  [0:NRX-1];     // payload word being packed
    reg [47:0] st0   [0:NRX-1];     // stamp of the block's first sample
    reg [31:0] seq   [0:NRX-1];     // blocks started since enable
    reg [31:0] wptr  [0:NRX-1];     // blocks completely written
    reg [7:0]  en_d;
    // ring_en registered here and used a clock late throughout (straight from its source it
    // would go into the pointer clears, the sample-accept test and the pointer write enable,
    // which is too slow); a ring is enabled or disabled one clock later
    reg [7:0]  ren;
    // wclr = !ren, its own register: the write pointers' clear (as a LUT behind ren, fanned out
    // to each pointer's 32 bits, it would be too slow)
    reg [7:0]  wclr;
    always @(posedge clk) begin
        ren  <= rst ? 8'd0 : ring_en;
        wclr <= rst ? 8'hFF : ~ring_en;
    end

    genvar g;
    generate
        for (g = 0; g < 8; g = g + 1) begin : wp
            if (g < NRX) begin : used
                assign ring_wptr[g*32 +: 32] = wptr[g];
            end else begin : unused
                assign ring_wptr[g*32 +: 32] = 32'd0;
            end
        end
    endgenerate

    // ---------------------------------------------------------------- write queue
    // Words wait here between the address pipeline and the DDR3 write state machine, so a write that
    // takes a while does not lose a sample. It is 32 entries deep (LOG2 = 5).
    // entry: {last, rx[2:0], addr[31:0], data[63:0]}
    wire         q_empty, q_full, q_ovf;
    reg          q_push;
    reg  [99:0]  q_din;
    wire [99:0]  q_dout;
    reg          q_pop;
    bk_fifo #(.DW(100), .LOG2(5)) u_q (
        .clk(clk), .rst(rst), .push(q_push), .din(q_din), .pop(q_pop), .dout(q_dout),
        .empty(q_empty), .full(q_full), .overflow(q_ovf)
    );

    // ---------------------------------------------------------------- packer
    // The packer is two clocks, and the queue entry's DDR3 address is worked out in four more
    // clocks after it, because receiver select, slot mask, slot x 34 or x 66, + ring base and
    // + word offset in one clock would be far too long a path.
    //   k0: register the sample and its receiver's state (cnt, word, seq, enables)
    //   k1: pack, update the receiver's state, hand the word (or a header word) to the address
    //       pipeline as {receiver, iq, slot number, word offset within the slot}
    //   a1..a4: slot & (2^log2 - 1); x 34 or x 66; + ring base; + word offset -> queue
    // k0 reads a receiver's state before k1 (k2 for the sequence counter) has written back the
    // previous sample's update, so two samples of the same receiver must be at least three
    // clocks apart; rx_backend's output stream gives at most one sample per bk_post job (tens of
    // clocks).
    // k0 also works out, from the sample count, where each 16-bit lane of the packed word comes
    // from (the old word, s0, s1 or zero), whether the word is full and its index, so k1's packing
    // is one 4:1 select per bit from registers; and the sequence counter's increment is written a
    // clock later (k2), from registers.
    reg        hdr_pend;        // two header words still to queue
    reg        hdr_second;
    reg [2:0]  h_rx;
    reg        h_iq;
    reg [31:0] h_seq;
    reg [63:0] h_w0, h_w1;
    reg [63:0] h_cur;           // the header word to queue next (h_w0, then h_w1)

    reg        k0_v, k0_ok, k0_iq;
    reg        k0_zero;             // cnt == 0: this sample starts a block
    // cnt == 127 and the sample is taken: the block's last sample, capture the header. In four
    // copies (syn_preserve), each the load enable of a quarter of the header registers: as one
    // net its fan-out of about 160 would be too slow.
    (* syn_preserve = 1 *) reg [3:0] k0_hdr;
    // k0_v && k0_ok (the sample is taken), in six copies: it selects every bit of the address
    // pipeline's entry (p_*) between the sample's word and a header word, and as one net its
    // fan-out of about 110 would be too slow
    (* syn_preserve = 1 *) reg [5:0] k0_take;
    reg [2:0]  k0_rx;
    reg [15:0] k0_s0, k0_s1;
    reg [47:0] k0_stamp, k0_st0;
    reg [6:0]  k0_c;
    reg [63:0] k0_word;
    reg [31:0] k0_seq;
    // lane sources: 0 the old word's lane, 1 s0, 2 s1, 3 zero (lane j = bits 16j+15..16j)
    localparam [1:0] LN_W = 2'd0, LN_S0 = 2'd1, LN_S1 = 2'd2, LN_Z = 2'd3;
    function [7:0] lanes;              // {lane 3, lane 2, lane 1, lane 0}
        input       iq;
        input [1:0] c;
        begin
            if (iq)
                lanes = c[0] ? {LN_S1, LN_S0, LN_W, LN_W} : {LN_Z, LN_Z, LN_S1, LN_S0};
            else case (c)
                2'd0:    lanes = {LN_Z,  LN_Z,  LN_Z,  LN_S0};
                2'd1:    lanes = {LN_Z,  LN_Z,  LN_S0, LN_W};
                2'd2:    lanes = {LN_Z,  LN_S0, LN_W,  LN_W};
                default: lanes = {LN_S0, LN_W,  LN_W,  LN_W};
            endcase
        end
    endfunction
    reg [7:0]  k0_ln;
    reg        k0_full;
    reg [5:0]  k0_idx;
    // The input sample registered once before anything uses it (the sample comes from
    // rx_backend's output registers, and its receiver number, fanned out to about 90 loads across
    // the die, would be too slow); the receiver number in copies: i_rx the enables, i_rxa the
    // count, i_rxb the packed word, i_rxc sequence and stamp.
    reg        i_v, i_iq;
    // ren && en_d per receiver, registered (selecting from the two in place would be too slow);
    // a ring is enabled or disabled one clock later again
    reg [7:0]  r_ok;
    always @(posedge clk)
        r_ok <= ren & en_d;
    reg [15:0] i_s0, i_s1;
    reg [47:0] i_stamp;
    (* syn_preserve = 1 *) reg [2:0] i_rx, i_rxa, i_rxb, i_rxc;
    always @(posedge clk) begin
        i_v     <= in_valid && !rst;
        i_iq    <= in_iq;
        i_s0    <= in_s0;
        i_s1    <= in_s1;
        i_stamp <= in_stamp;
        i_rx    <= in_rx;
        i_rxa   <= in_rx;
        i_rxb   <= in_rx;
        i_rxc   <= in_rx;
    end
    always @(posedge clk) begin
        k0_v     <= i_v && !rst;
        k0_ok    <= r_ok[i_rx];
        k0_rx    <= i_rx;
        k0_iq    <= i_iq;
        k0_s0    <= i_s0;
        k0_s1    <= i_s1;
        k0_stamp <= i_stamp;
        k0_c     <= cnt[i_rxa];
        k0_zero  <= cnt[i_rxa] == 7'd0;
        k0_hdr   <= {4{i_v && !rst && r_ok[i_rx] && cnt[i_rxa] == 7'd127}};
        k0_take  <= {6{i_v && !rst && r_ok[i_rx]}};
        k0_word  <= word[i_rxb];
        k0_seq   <= seq[i_rxc];
        k0_st0   <= st0[i_rxc];
        k0_ln    <= lanes(i_iq, cnt[i_rxa][1:0]);
        k0_full  <= i_iq ? cnt[i_rxa][0] : (cnt[i_rxa][1:0] == 2'd3);
        k0_idx   <= i_iq ? cnt[i_rxa][6:1] : {1'b0, cnt[i_rxa][6:2]};
    end

    // the packed word: lane j from k0_ln[2j+1:2j] (the old word's lane, s0, s1 or zero)
    wire [63:0] w_in;
    genvar gl;
    generate
        for (gl = 0; gl < 4; gl = gl + 1) begin : pk
            assign w_in[gl*16 +: 16] = (k0_ln[gl*2 +: 2] == LN_W)  ? k0_word[gl*16 +: 16] :
                                       (k0_ln[gl*2 +: 2] == LN_S0) ? k0_s0 :
                                       (k0_ln[gl*2 +: 2] == LN_S1) ? k0_s1 : 16'd0;
        end
    endgenerate
    wire        w_full  = k0_full;
    wire [5:0]  w_idx   = k0_idx;

    // k1 -> k2: the sequence counter's increment when a block's last sample is taken
    reg  [7:0]  sq_we;          // one-hot: which receiver's counter
    reg  [31:0] sq_val;

    // entry for the address pipeline
    reg         p_v, p_last, p_iq;
    reg  [2:0]  p_rx;
    reg  [31:0] p_seq;
    reg  [6:0]  p_off;          // word offset within the slot: 0, 1 header, 2.. payload
    // (syn_srlstyle: left alone, Gowin synthesis turns the p -> a1 -> a2 -> a3 data delay into a
    // block-RAM shift register whose write mode its own place-and-route rejects, PA2122)
    (* syn_srlstyle = "registers" *) reg [63:0] p_data;

    integer k;
    integer k2;
    integer k3;
    // the sequence counters, in a block of their own with the clear first (written from sq_we
    // inside the block below, their load enable would be a LUT behind a flag with a fan-out of
    // 33, which is too slow). A counter written in the clock its ring is disabled is cleared at
    // once instead of a clock later.
    always @(posedge clk)
        for (k3 = 0; k3 < NRX; k3 = k3 + 1)
            if (wclr[k3])                  // rst || !ren, registered
                seq[k3] <= 32'd0;
            else if (sq_we[k3])
                seq[k3] <= sq_val;

    // the entry is loaded every clock, from the sample's word or the next header word; p_v says
    // whether it is one
    always @(posedge clk) begin
        p_rx   <= k0_take[0] ? k0_rx : h_rx;
        p_iq   <= k0_take[0] ? k0_iq : h_iq;
        p_seq  <= k0_take[1] ? k0_seq : h_seq;
        p_data[31:0]  <= k0_take[2] ? w_in[31:0]  : h_cur[31:0];
        p_data[63:32] <= k0_take[3] ? w_in[63:32] : h_cur[63:32];
        p_off  <= k0_take[4] ? 7'd2 + {1'b0, w_idx} : {6'd0, hdr_second};
        p_last <= !k0_take[4] && hdr_second;
    end
    always @(posedge clk) begin
        p_v <= 1'b0;
        sq_we  <= 8'd0;
        sq_val <= k0_seq + 32'd1;
        if (rst) begin
            en_d <= 8'd0;
            hdr_pend <= 1'b0;
            for (k = 0; k < NRX; k = k + 1)
                cnt[k] <= 7'd0;
        end else begin
            en_d <= ren;
            for (k = 0; k < NRX; k = k + 1)
                if (!ren[k])
                    cnt[k] <= 7'd0;
            if (k0_v && k0_ok) begin
                if (k0_zero)
                    st0[k0_rx] <= k0_stamp;
                word[k0_rx] <= w_in;
                if (w_full)
                    p_v <= 1'b1;
                cnt[k0_rx] <= k0_c + 7'd1;
                if (k0_hdr[0]) begin
                    hdr_pend   <= 1'b1;
                    hdr_second <= 1'b0;
                    h_rx   <= k0_rx;
                    h_iq   <= k0_iq;
                    sq_we  <= 8'd1 << k0_rx; // seq[k0_rx] <= k0_seq + 1, in k2
                end
                if (k0_hdr[1]) h_seq <= k0_seq;
                if (k0_hdr[2]) h_cur <= {7'd0, k0_iq, 5'd0, k0_rx, k0_st0};
                // the S-meter read here, a clock after the sample (from the registered receiver
                // number, not from in_rx, to keep the path short); bk_post updates a
                // receiver's S-meter only in that receiver's next job, tens of clocks later
                if (k0_hdr[3]) h_w1  <= {16'd0, smeter[k0_rx*16 +: 16], k0_seq};
            end else if (hdr_pend) begin
                // the two header words, in clocks without an input sample
                p_v <= 1'b1;
                if (!hdr_second) begin
                    hdr_second <= 1'b1;
                    h_cur      <= h_w1;
                end else begin
                    hdr_pend <= 1'b0;
                end
            end
        end
    end

    // ---------------------------------------------------------------- slot address pipeline
    // slot_addr(base, slot, lg, iq) = base + (slot mod 2^lg) x (iq ? 66 : 34) lane words
    // syn_preserve: without it Gowin synthesis merged the a2 registers away, putting the ring
    // base select and the add back into one clock.
    reg         a1_v, a2_v, a3_v;
    reg  [2:0]  a1_rx;
    reg         a1_iq, a1_last, a2_last, a3_last;
    (* syn_preserve = 1 *) reg [31:0] a1_s, a2_m, a2_base, a3_a;
    reg  [6:0]  a1_off, a2_off, a3_off;
    (* syn_srlstyle = "registers" *) reg [63:0] a1_d, a2_d, a3_d;
    reg  [2:0]  a2_rx, a3_rx;
    // each ring's slot mask, 2^ring_slots - 1, registered from the setting (worked out from the
    // selected setting in a1 it would be too slow)
    reg  [31:0] slot_mask [0:NRX-1];
    integer     km;
    always @(posedge clk)
        for (km = 0; km < NRX; km = km + 1)
            slot_mask[km] <= (32'd1 << ring_log2[km*4 +: 4]) - 32'd1;
    always @(posedge clk) begin
        a1_v <= p_v && !rst;
        a2_v <= a1_v && !rst;
        a3_v <= a2_v && !rst;
        // a1: slot number within the ring
        a1_s    <= p_seq & slot_mask[p_rx];
        a1_rx   <= p_rx;  a1_iq <= p_iq;  a1_last <= p_last;  a1_off <= p_off;  a1_d <= p_data;
        // a2: slot x 34 or x 66, and the ring base
        a2_m    <= a1_iq ? ((a1_s << 6) + (a1_s << 1)) : ((a1_s << 5) + (a1_s << 1));
        a2_base <= ring_base;
        a2_rx   <= a1_rx; a2_last <= a1_last; a2_off <= a1_off; a2_d <= a1_d;
        // a3: + base
        a3_a    <= a2_base + a2_m;
        a3_rx   <= a2_rx; a3_last <= a2_last; a3_off <= a2_off; a3_d <= a2_d;
        // a4: + word offset, into the queue
        q_din   <= {a3_last, a3_rx, a3_a + {25'd0, a3_off}, a3_d};
    end
    always @(posedge clk) begin
        q_push   <= a3_v && !rst;
        overflow <= q_ovf;
    end

    // ---------------------------------------------------------------- lane client
    // The lane client takes one entry from the queue at a time, drives req/addr/wdata until the
    // lane says done, and goes on to the next. After the last header word of a block the pointer
    // update and the block_done pulse happen three clocks after the lane's `done`, not in the
    // same clock: inc_go/inc_rx register which receiver finished, inc2_sel selects its pointer,
    // then it is incremented. cur_rx comes straight from the queue RAM's output, and receiver
    // select, 32-bit increment and write behind it would be too long a path. (A receiver's blocks
    // are 130 lane words apart, so its next update is never in flight at the same time.)
    reg        busy;
    reg        cur_last;
    reg [2:0]  cur_rx;
    reg        inc_go;
    reg [2:0]  inc_rx;
    reg [7:0]  inc2_sel;          // one-hot: the receiver whose pointer is written
    integer    k4;
    always @(posedge clk)
        for (k4 = 0; k4 < NRX; k4 = k4 + 1)
            if (wclr[k4])
                wptr[k4] <= 32'd0;
            else if (inc2_sel[k4])
                wptr[k4] <= wptr[k4] + 32'd1;
    always @(posedge clk) begin
        q_pop <= 1'b0;
        block_done <= 8'd0;
        inc_go <= 1'b0;
        inc2_sel <= inc_go ? 8'd1 << inc_rx : 8'd0;
        if (rst) begin
            req  <= 1'b0;
            busy <= 1'b0;
        end else begin
            for (k2 = 0; k2 < NRX; k2 = k2 + 1)
                if (ren[k2] && inc2_sel[k2])
                    block_done[k2] <= 1'b1;
            if (!busy) begin
                if (!q_empty && !q_pop) begin
                    req      <= 1'b1;
                    addr     <= q_dout[95:64];
                    wdata    <= q_dout[63:0];
                    cur_last <= q_dout[99];
                    cur_rx   <= q_dout[98:96];
                    busy     <= 1'b1;
                    q_pop    <= 1'b1;
                end
            end else if (done) begin
                req    <= 1'b0;
                busy   <= 1'b0;
                inc_go <= cur_last;
                inc_rx <= cur_rx;
            end
        end
    end
    assign cfg_rx = a1_rx;
endmodule
