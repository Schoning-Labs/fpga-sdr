// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Board link, sender (docs/SFP_LINKS.md 5.1): the transmit half of the link between two boards on SFP lane 1. It
// takes the radio's sample stream, the control words that the CPU queued, and the link status, and makes
// the word stream that goes to the lane, one 16-bit word per clock of the lane's transmit clock (125 MHz,
// so 2 Gbit/s of payload on the 2.5 Gbit/s line).
//
// Why a board link exists: the Hermes-Lite 2 is connected to board 1 only. Board 2 gets the same raw
// sample stream over this link, with the same sample numbering, so that its receivers see exactly what
// board 1's see. The link also carries small control words in both directions, which the firmware of the
// two boards use to talk to each other.
//
// A word is 16 bits, which is two 8b/10b symbols (see sfp_enc20.v), and each word goes out as two symbols,
// the low byte first on the line. Only the low byte is ever a control symbol (a K symbol, which marks the
// start and end of things), the high byte is always data. The words are:
//   idle              K28.5, D16.2
//   sample frame      K27.7 + frame counter; index of the first sample in 3 words (low first); 1 to 128
//                     sample words {0000, sample}; K29.7 + (samples - 1); CRC
//   control word      K28.0 + sequence number; 2 words (low first); CRC
//   status            K28.3 + flags; my count of bad frames; CRC (every 2^17 clocks, every 512 while a
//                     link is coming up, and at once when a flag or the count changed)
// The CRC is a CRC-16 (polynomial 0x1021, start 0xFFFF, bit 15 first) over every word of the frame before
// it, with idles left out (see crc32_eth.v for what a CRC is; this one is 16 bits and word by word). An idle
// word goes out whenever no sample is ready, also inside a frame, and one after every frame, so the
// receiver always sees commas (which keep it aligned) and this module needs no look-ahead.
//
// The sample FIFO's words carry a flag "a frame must start here" (first sample, or the one after a gap).
// For those the index comes from the index FIFO, and otherwise it counts on. A frame is closed in front of
// such a sample, after 128 samples, or when no sample came for 16 clocks. Fill samples (zeros that stand in
// for a lost frame) never reach this module, so a gap at the source is a gap in the link's sample numbering.
//
// The status word says in bit 0 that my receiver has the link up, in bit 1 that I am sending samples, in
// bit 2 that my control receive FIFO is full, and in bits 7:4 of its first word the format version (1).

`timescale 1ns / 1ps

module blink_tx (
    input  wire        clk,                  // lane 1 transmit word clock, 125 MHz
    input  wire        rst,                  // synchronous reset, active high
    // sample FIFO read side: {start flag, sample}; rd_valid one clock after rd_en (cdc_sample_fifo)
    output reg         s_pop = 1'b0,         // request one sample word
    input  wire [12:0] s_data,               // {start flag, 12-bit sample}
    input  wire        s_valid,              // s_data holds the word requested a clock ago
    output reg         i_pop = 1'b0,         // request one frame index
    input  wire [47:0] i_data,               // index of the first sample of a frame
    input  wire        i_valid,              // i_data is valid
    // control-word FIFO read side
    output reg         c_pop = 1'b0,         // request one control word
    input  wire [31:0] c_data,               // control word
    input  wire        c_valid,              // c_data is valid
    // status to send
    input  wire [3:0]  st_flags,         // 0 my link up, 1 sending samples, 2 my control FIFO full
    input  wire [15:0] st_bad,               // my count of bad frames
    input  wire        st_fast,          // status every 512 clocks (a link is still coming up), not every 2^17
    // to the coder
    output reg  [15:0] w_d = 16'h50BC,       // the word (K28.5 D16.2 is 0x50BC, an idle)
    output reg  [1:0]  w_k = 2'b01,          // which symbol of the word is a K symbol (bit 0: the low one)
    output reg  [15:0] cnt_frames = 16'd0,   // sample frames sent
    output reg  [15:0] cnt_ctl = 16'd0       // control words sent
) /* synthesis syn_srlstyle = "registers" */;

    // CRC-16: for each of the 16 bits of the word, from bit 15 down, shift the register left and, if the
    // bit that falls out of the top differs from the data bit, XOR in the polynomial 0x1021.
    function [15:0] crc16(input [15:0] c, input [15:0] d);
        integer i;
        reg [15:0] r;
        begin
            r = c;
            for (i = 15; i >= 0; i = i - 1) r = (r[15] ^ d[i]) ? ({r[14:0], 1'b0} ^ 16'h1021) : {r[14:0], 1'b0};
            crc16 = r;
        end
    endfunction

    // ---- 4-word input queue in front of the sample FIFO, popped on credit (the same scheme as in
    // rtl/hl2link/gap_filler.v, which explains why: the FIFO's read has a clock of latency, so pops are
    // issued ahead and only while the queue has room for every word that is on its way)
    reg [12:0] q_mem [0:3];
    reg [1:0]  q_wp = 2'd0, q_rp = 2'd0;
    reg [2:0]  q_cnt = 3'd0;
    wire        q_has   = (q_cnt != 3'd0);
    wire        q_start = q_mem[q_rp][12];
    wire [11:0] q_samp  = q_mem[q_rp][11:0];
    wire        deq;
    wire [2:0]  q_cnt_next = q_cnt + {2'd0, s_valid} - {2'd0, deq};
    wire        pop_ok = ({1'b0, q_cnt_next} + {3'd0, s_pop} + 4'd1) <= 4'd4;
    always @(posedge clk) begin
        if (rst) begin
            q_wp <= 2'd0; q_rp <= 2'd0; q_cnt <= 3'd0; s_pop <= 1'b0;
        end else begin
            if (s_valid) begin q_mem[q_wp] <= s_data; q_wp <= q_wp + 2'd1; end
            if (deq) q_rp <= q_rp + 2'd1;
            q_cnt <= q_cnt_next;
            s_pop <= pop_ok;
        end
    end

    // ---- one index and one control word fetched ahead, so that they are ready when a frame starts. `*_have`
    // says that one is held, `*_wait` that a request is out, and a request that finds the FIFO empty is
    // simply asked again.
    reg        i_have = 1'b0, i_wait = 1'b0, c_have = 1'b0, c_wait = 1'b0;
    reg [47:0] i_q = 48'd0;
    reg [31:0] c_q = 32'd0;
    wire       i_take, c_take;
    always @(posedge clk) begin
        i_pop <= 1'b0; c_pop <= 1'b0;
        if (rst) begin
            i_have <= 1'b0; i_wait <= 1'b0; c_have <= 1'b0; c_wait <= 1'b0;
        end else begin
            if (i_valid) begin i_q <= i_data; i_have <= 1'b1; i_wait <= 1'b0; end
            else if (i_take) i_have <= 1'b0;
            else if (!i_have && !i_wait && !i_pop) begin i_pop <= 1'b1; i_wait <= 1'b1; end
            else if (i_wait && !i_pop) i_wait <= 1'b0;     // the FIFO was empty: ask again
            if (c_valid) begin c_q <= c_data; c_have <= 1'b1; c_wait <= 1'b0; end
            else if (c_take) c_have <= 1'b0;
            else if (!c_have && !c_wait && !c_pop) begin c_pop <= 1'b1; c_wait <= 1'b1; end
            else if (c_wait && !c_pop) c_wait <= 1'b0;
        end
    end

    // ---- sequencer: the states follow a frame word by word. S_IDLE (an idle word is going out, and the next
    // frame, control word or status is chosen), S_I0 to S_I2 (the three index words), S_SAMP (sample words),
    // S_CRC (the CRC word), S_C1, S_C2 (the two control data words), S_T1 (the status's second word).
    // `st_timer` paces the status, `quiet` counts clocks without a sample inside a frame, `first` says that
    // the frame has no sample yet, and `fresh` that a frame just ended, so one idle word goes out first.
    localparam [3:0] S_IDLE = 4'd0, S_I0 = 4'd1, S_I1 = 4'd2, S_I2 = 4'd3, S_SAMP = 4'd4, S_CRC = 4'd5,
                     S_C1 = 4'd6, S_C2 = 4'd7, S_T1 = 4'd8;
    reg [3:0]  st = S_IDLE;
    reg [15:0] crc = 16'hFFFF;
    reg [47:0] idx = 48'd0;
    reg [7:0]  n = 8'd0, fcnt = 8'd0, cseq = 8'd0;
    reg [4:0]  quiet = 5'd0;
    reg [16:0] st_timer = 17'd0;
    reg        st_due = 1'b1;
    reg [3:0]  flags_q = 4'd0;
    reg [15:0] bad_q = 16'd0;
    reg        first = 1'b0;             // the frame has no sample yet
    reg        fresh = 1'b0;             // a frame just ended: one idle word first

    // `go`: the sequencer is free to start something. `start_ok`: a sample is queued and, if it starts a frame,
    // its index has been fetched. `samp_ok`: the next sample belongs to the frame in progress (it does not
    // start a new one, unless it is the frame's first) and the frame is not full (128 samples, n[7]).
    // `i_take` and `c_take` consume the fetched index or control word when the frame or word starts.
    wire go       = (st == S_IDLE) && !fresh;
    wire start_ok = q_has && (!q_start || i_have);
    wire samp_ok  = (st == S_SAMP) && q_has && (first || !q_start) && !n[7];
    assign deq    = samp_ok;
    assign i_take = go && !st_due && !c_have && start_ok && q_start;
    assign c_take = go && !st_due && c_have;

    // The CRC takes each frame word from the output register one clock after it was put there, because a
    // sample queue, the word and the CRC in one clock would be the lane clock's tightest path. `acc` says
    // that the word now in w_d belongs to the frame, and `acc0` that it is the frame's first (which starts the
    // CRC from 0xFFFF). `put` sends a word and marks it as part of the frame.
    reg        acc = 1'b0, acc0 = 1'b0;
    wire [15:0] crc_now = crc16(acc0 ? 16'hFFFF : crc, w_d);
    task put(input [15:0] d, input k0);
        begin w_d <= d; w_k <= {1'b0, k0}; acc <= 1'b1; end
    endtask

    // The sequencer. In S_IDLE it picks what comes next, in this order: a status word if one is due, a control
    // word if one is waiting, a sample frame if a sample is ready (a frame starts with its counter word, K27.7).
    // Otherwise an idle word goes out. `st_due` is set by the status timer, by the fast timer while the link
    // is coming up, and by any change of the flags or the bad-frame count.
    always @(posedge clk) begin
        st_timer <= st_timer + 17'd1;
        flags_q  <= st_flags;
        acc <= 1'b0; acc0 <= 1'b0;
        if (acc) crc <= crc_now;
        bad_q    <= st_bad;
        if (rst) begin
            st <= S_IDLE; st_due <= 1'b1; w_d <= 16'h50BC; w_k <= 2'b01; fcnt <= 8'd0; cseq <= 8'd0;
            cnt_frames <= 16'd0; cnt_ctl <= 16'd0;
        end else begin
            if ((st_timer == 17'd0) || (st_fast && (st_timer[8:0] == 9'd0)) || (flags_q != st_flags) || (bad_q != st_bad))
                st_due <= 1'b1;
            case (st)
                S_IDLE: begin
                    w_d <= 16'h50BC; w_k <= 2'b01;
                    n <= 8'd0; quiet <= 5'd0; first <= 1'b1; fresh <= 1'b0;
                    if (fresh) begin
                        // the idle word above
                    end else if (st_due) begin
                        w_d <= {4'd1, st_flags, 8'h7C}; acc <= 1'b1; acc0 <= 1'b1;
                        st_due <= 1'b0; st <= S_T1;
                    end else if (c_have) begin
                        w_d <= {cseq, 8'h1C}; acc <= 1'b1; acc0 <= 1'b1;
                        cseq <= cseq + 8'd1; cnt_ctl <= cnt_ctl + 16'd1; st <= S_C1;
                    end else if (start_ok) begin
                        w_d <= {fcnt, 8'hFB}; acc <= 1'b1; acc0 <= 1'b1;
                        fcnt <= fcnt + 8'd1; cnt_frames <= cnt_frames + 16'd1;
                        if (q_start) idx <= i_q;
                        st <= S_I0;
                    end
                end
                S_I0: begin put(idx[15:0], 1'b0);  st <= S_I1; end
                S_I1: begin put(idx[31:16], 1'b0); st <= S_I2; end
                S_I2: begin put(idx[47:32], 1'b0); st <= S_SAMP; end
                S_SAMP: begin
                    if (samp_ok) begin
                        put({4'd0, q_samp}, 1'b0);
                        n <= n + 8'd1; idx <= idx + 48'd1; first <= 1'b0; quiet <= 5'd0;
                    end else if (!first && (q_has || quiet[4])) begin
                        put({n - 8'd1, 8'hFD}, 1'b1);            // a start flag ahead, 128 samples, or silence
                        st <= S_CRC;
                    end else begin
                        w_d <= 16'h50BC; w_k <= 2'b01;           // nothing ready: idle inside the frame
                        quiet <= quiet + 5'd1;
                    end
                end
                S_CRC: begin w_d <= crc_now; w_k <= 2'b00; st <= S_IDLE; fresh <= 1'b1; end
                S_C1:  begin put(c_q[15:0], 1'b0);  st <= S_C2; end
                S_C2:  begin put(c_q[31:16], 1'b0); st <= S_CRC; end
                S_T1:  begin put(st_bad, 1'b0);     st <= S_CRC; end
                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
