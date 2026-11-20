// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Board link, receiver (docs/SFP_LINKS.md 5.1 to 5.3): the receive half of the link between two boards on SFP
// lane 1. It takes the decoded word stream of the lane (two symbols per clock from sfp_rx_sym.v, in the recovered
// clock) apart into sample frames, control words and status words. The word format is described in
// rtl/blink/blink_tx.v (frames start with a K symbol, carry their data in data symbols, and end with a CRC-16).
//
// How a frame is received, step by step: the state machine waits in R_HUNT for a start symbol. K27.7 starts a
// sample frame (the high byte is the frame counter), K28.0 starts a control word (sequence number) and K28.3 a
// status word. Then the words follow, each added to a running CRC-16, until the CRC word, which has to equal the
// running value. Idle words (K28.5) are dropped wherever they stand, since the sender puts them between any two
// words. A sample frame goes on to blink_rx_buf.v as it arrives, but only becomes valid there when its CRC was
// good (`f_commit`), and the end word K29.7 must carry the number of samples counted minus one.
//
// A frame is bad when a symbol had a code error, a control symbol stood where none belongs, the length did not
// match, or the CRC failed. A bad frame gives nothing downstream: sample frames are only committed to
// blink_rx_buf after their CRC, and the gap filler behind it fills what is missing with zeros.
//
// Link state: the link counts as up when the aligner is locked and 4 good frames of any kind came in a row. It
// counts as down when the lock is lost, after 8 bad frames in a row, or when no good frame came for 2^19 clocks
// (4.2 ms). The status words of the other end are shown in `rem_flags` and `rem_bad`.
//
// Counters: good sample frames, bad frames of any kind, sample frames whose frame counter did not follow the
// last one (a frame was lost on the link), control words received, control words missing by their sequence
// numbers, and the number of times the link came up.

`timescale 1ns / 1ps

module blink_rx (
    input  wire        clk,               // lane 1 recovered receive word clock, 125 MHz
    input  wire        rst,               // synchronous reset, active high
    input  wire        sym_vld,           // the symbols below are new in this clock
    input  wire [15:0] sym_d,             // two decoded symbols, the first on the line in bits 7:0
    input  wire [1:0]  sym_k,             // 1: the symbol is a control symbol
    input  wire [1:0]  sym_err,           // 1: the symbol is not in the 8b/10b alphabet
    input  wire        locked,            // the aligner is locked
    // to blink_rx_buf
    output reg         f_sof = 1'b0,      // pulse: a sample frame starts
    output reg         f_valid = 1'b0,    // f_data is a sample of the frame
    output reg  [11:0] f_data = 12'd0,    // 12-bit sample
    output reg         f_commit = 1'b0,   // pulse after the frame's CRC word: the frame was good
    output reg  [47:0] f_idx = 48'd0,     // index of the frame's first sample
    output reg  [7:0]  f_n = 8'd0,       // samples - 1
    // control words
    output reg         c_valid = 1'b0,    // pulse: a control word arrived with a good CRC
    output reg  [31:0] c_data = 32'd0,    // the control word
    // state and counters
    output reg         link_up = 1'b0,    // the link is up (see the header)
    output reg  [3:0]  rem_flags = 4'd0,  // the other end's status flags
    output reg  [15:0] rem_bad = 16'd0,   // the other end's count of bad frames
    output reg  [15:0] cnt_good = 16'd0,     // good sample frames
    output reg  [15:0] cnt_bad = 16'd0,      // bad frames of any kind
    output reg  [15:0] cnt_jump = 16'd0,     // sample frames whose counter did not follow the last
    output reg  [15:0] cnt_ctl = 16'd0,      // control words received
    output reg  [15:0] cnt_ctl_lost = 16'd0, // control words missing by their sequence numbers
    output reg  [15:0] cnt_up = 16'd0        // times the link came up
) /* synthesis syn_srlstyle = "registers" */;

    // CRC-16 (polynomial 0x1021), word by word, bit 15 first: the same as in blink_tx.v.
    function [15:0] crc16(input [15:0] c, input [15:0] d);
        integer i;
        reg [15:0] r;
        begin
            r = c;
            for (i = 15; i >= 0; i = i - 1) r = (r[15] ^ d[i]) ? ({r[14:0], 1'b0} ^ 16'h1021) : {r[14:0], 1'b0};
            crc16 = r;
        end
    endfunction

    // States: R_HUNT (waiting for a start symbol), R_I0 to R_I2 (the three index words), R_SAMP (sample
    // words), R_SCRC (the CRC word of a sample frame), R_C1, R_C2, R_CCRC (a control word: its two data words
    // and its CRC), R_T1, R_TCRC (a status word: its second word and its CRC).
    localparam [3:0] R_HUNT = 4'd0, R_I0 = 4'd1, R_I1 = 4'd2, R_I2 = 4'd3, R_SAMP = 4'd4, R_SCRC = 4'd5,
                     R_C1 = 4'd6, R_C2 = 4'd7, R_CCRC = 4'd8, R_T1 = 4'd9, R_TCRC = 4'd10;
    // `n` counts samples in the frame, `fcnt` and `fcnt_last` are the frame counter of this and of the last good
    // frame (their difference shows lost frames), `cseq` and `cseq_last` the same for control words, `seen_*` that
    // there was a last one, `tflags` and `tbad` the status being received, `good_run` and `bad_run` count good
    // and bad frames in a row for the link state, `idle_t` the clocks since the last good frame, and `ev_good`
    // and `ev_bad` are the events of a frame, handled in the next clock.
    reg [3:0]  st = R_HUNT;
    reg [15:0] crc = 16'hFFFF;
    reg [7:0]  n = 8'd0, fcnt = 8'd0, fcnt_last = 8'd0, cseq = 8'd0, cseq_last = 8'd0;
    reg        seen_f = 1'b0, seen_c = 1'b0;
    reg [3:0]  tflags = 4'd0;
    reg [15:0] tbad = 16'd0;
    reg [2:0]  good_run = 3'd0;
    reg [3:0]  bad_run = 4'd0;
    reg [19:0] idle_t = 20'd0;
    reg        ev_good = 1'b0, ev_bad = 1'b0;

    // A symbol is bad if it has a code error or if the high one is a control symbol (only the low one can be).
    wire bad_sym = (sym_err != 2'b00) || sym_k[1];
    wire is_k    = sym_k[0];
    wire is_idle = is_k && (sym_d[7:0] == 8'hBC);

    // The receiver. The strobes are one-clock pulses and default to 0. Without a lock, everything restarts.
    always @(posedge clk) begin
        f_sof <= 1'b0; f_valid <= 1'b0; f_commit <= 1'b0; c_valid <= 1'b0;
        ev_good <= 1'b0; ev_bad <= 1'b0;
        if (rst || !locked) begin
            st <= R_HUNT; link_up <= 1'b0; good_run <= 3'd0; bad_run <= 4'd0; idle_t <= 20'd0;
            seen_f <= 1'b0; seen_c <= 1'b0;
            if (rst) begin
                cnt_good <= 16'd0; cnt_bad <= 16'd0; cnt_jump <= 16'd0; cnt_ctl <= 16'd0;
                cnt_ctl_lost <= 16'd0; cnt_up <= 16'd0; rem_flags <= 4'd0; rem_bad <= 16'd0;
            end
        end else begin
            // ---- link state from the good / bad events of the clock before: a good frame clears the bad run and
            // the silence timer and counts towards link up (4 in a row), a bad one clears the good run and counts
            // towards link down (8 in a row), and 2**19 clocks without a good frame also take the link down
            if (!idle_t[19]) idle_t <= idle_t + 20'd1;
            if (ev_good) begin
                idle_t <= 20'd0; bad_run <= 4'd0;
                if (good_run != 3'd4) good_run <= good_run + 3'd1;
                if ((good_run == 3'd3) && !link_up) begin link_up <= 1'b1; cnt_up <= cnt_up + 16'd1; end
            end else if (ev_bad) begin
                good_run <= 3'd0; cnt_bad <= cnt_bad + 16'd1;
                if (bad_run != 4'd8) bad_run <= bad_run + 4'd1;
            end
            if ((bad_run == 4'd8) || idle_t[19]) begin link_up <= 1'b0; good_run <= 3'd0; end

            // ---- words: the symbols of one clock. A bad symbol ends the frame, an idle is skipped, a start symbol
            // is looked for in R_HUNT, and the data words of each frame type are collected and checked.
            if (sym_vld) begin
                if (bad_sym) begin
                    if (st != R_HUNT) ev_bad <= 1'b1;
                    st <= R_HUNT;
                end else if (is_idle) begin
                    // dropped wherever it stands
                end else if (st == R_HUNT) begin
                    crc <= crc16(16'hFFFF, sym_d);
                    if (is_k && (sym_d[7:0] == 8'hFB)) begin
                        fcnt <= sym_d[15:8]; n <= 8'd0; f_sof <= 1'b1; st <= R_I0;
                    end else if (is_k && (sym_d[7:0] == 8'h1C)) begin
                        cseq <= sym_d[15:8]; st <= R_C1;
                    end else if (is_k && (sym_d[7:0] == 8'h7C)) begin
                        tflags <= sym_d[11:8]; st <= (sym_d[15:12] == 4'd1) ? R_T1 : R_HUNT;
                    end                                  // anything else: the rest of a frame given up, skipped
                end else if (st == R_SAMP && is_k) begin
                    crc <= crc16(crc, sym_d);
                    if ((sym_d[7:0] == 8'hFD) && (sym_d[15:8] == n - 8'd1) && (n != 8'd0)) begin
                        f_n <= sym_d[15:8]; st <= R_SCRC;
                    end else begin ev_bad <= 1'b1; st <= R_HUNT; end
                end else if (is_k) begin
                    ev_bad <= 1'b1; st <= R_HUNT;        // a start or end where data belongs
                end else begin
                    crc <= crc16(crc, sym_d);
                    case (st)
                        R_I0: begin f_idx[15:0]  <= sym_d; st <= R_I1; end
                        R_I1: begin f_idx[31:16] <= sym_d; st <= R_I2; end
                        R_I2: begin f_idx[47:32] <= sym_d; st <= R_SAMP; end
                        R_SAMP: begin
                            if (n[7] || (sym_d[15:12] != 4'd0)) begin ev_bad <= 1'b1; st <= R_HUNT; end
                            else begin f_valid <= 1'b1; f_data <= sym_d[11:0]; n <= n + 8'd1; end
                        end
                        R_SCRC: begin
                            st <= R_HUNT;
                            if (sym_d == crc) begin
                                f_commit <= 1'b1; ev_good <= 1'b1; cnt_good <= cnt_good + 16'd1;
                                seen_f <= 1'b1; fcnt_last <= fcnt;
                                if (seen_f && (fcnt != fcnt_last + 8'd1)) cnt_jump <= cnt_jump + 16'd1;
                            end else ev_bad <= 1'b1;
                        end
                        R_C1: begin c_data[15:0]  <= sym_d; st <= R_C2; end
                        R_C2: begin c_data[31:16] <= sym_d; st <= R_CCRC; end
                        R_CCRC: begin
                            st <= R_HUNT;
                            if (sym_d == crc) begin
                                c_valid <= 1'b1; ev_good <= 1'b1; cnt_ctl <= cnt_ctl + 16'd1;
                                seen_c <= 1'b1; cseq_last <= cseq;
                                if (seen_c) cnt_ctl_lost <= cnt_ctl_lost + {8'd0, cseq - cseq_last - 8'd1};
                            end else ev_bad <= 1'b1;
                        end
                        R_T1: begin tbad <= sym_d; st <= R_TCRC; end
                        R_TCRC: begin
                            st <= R_HUNT;
                            if (sym_d == crc) begin
                                ev_good <= 1'b1; rem_flags <= tflags; rem_bad <= tbad;
                            end else ev_bad <= 1'b1;
                        end
                        default: st <= R_HUNT;
                    endcase
                end
            end
        end
    end

endmodule
