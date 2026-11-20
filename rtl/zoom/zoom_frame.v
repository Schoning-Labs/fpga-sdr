// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// zoom_frame: the frame buffer between the zoom's window and the FFT that the zoom shares with the
// whole-band spectrum (docs/ZOOM_FIT.md section 2). The zoom has no FFT of its own: its windowed samples are
// collected here, 4,096 complex words of 2 x 16 bits, and played into the last twelve stages of the
// whole-band FFT (rtl/fft/fft_r22sdf.v, INJ_S) when rtl/spectrum/spectrum_pipeline.v says so, in a gap of the
// full-band stream. The zoom produces samples slowly (at most 3.84 Msps, while the FFT can take one
// per clock), so collecting a frame here and playing it in one burst is what lets one FFT serve both.
//
//   - `take` is high while the buffer collects: the caller gives the window a sample only then, so the
//     window's frame counter and this buffer stay in step (both count the accepted samples from reset,
//     frames of 4,096). After the 4,096th accepted sample `take` falls; samples that arrive until the frame
//     has been played are dropped.
//   - `ready` rises when the frame's last windowed word is in the memory.
//   - one clock of `go` starts the play: 4,096 words on consecutive clocks, the first three clocks after
//     `go`, `last` with the last one. `ready` falls with `go`; `take` rises again after the last word.
//
// The memory is never read and written at one address in one clock: it is written only while collecting
// and read only while playing. 4,096 x 32 bits: 8 block RAMs (4 bits per block at that depth,
// IDE/simlib/gw5a/prim_sim.v SDPB), read with an address register and an output register.

`timescale 1ns / 1ps

module zoom_frame #(
    parameter integer LOG_N = 12,    // log2 of the frame length
    parameter integer W     = 16     // bits of one component of a sample
)(
    input  wire                clock,
    input  wire                rst,
    // from the DDC: one clock of in_strobe per sample (to count the accepted ones)
    input  wire                in_strobe,
    output wire                take,        // the buffer collects: the window may be given a sample
    // from the window
    input  wire                win_valid,   // a windowed sample is on win_re/win_im
    input  wire signed [W-1:0] win_re,
    input  wire signed [W-1:0] win_im,
    // to the shared FFT
    output reg                 ready,       // a complete frame is in the memory
    input  wire                go,          // one clock: play the frame
    output reg                 out_valid,   // a word of the frame is on out_re/out_im
    output reg                 out_last,    // with the last word
    output reg  signed [W-1:0] out_re,
    output reg  signed [W-1:0] out_im
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;

    localparam integer N = 1 << LOG_N;

    reg [2*W-1:0] mem [0:N-1];
    integer i;
    initial for (i = 0; i < N; i = i + 1) mem[i] = {(2*W){1'b0}};

    // memory words are {re, im}; wa is the write address (counts windowed samples), ra the read address
    // while playing, cap the accepted samples of this frame
    reg [LOG_N:0]   cap = {(LOG_N+1){1'b0}};       // accepted samples of this frame; bit LOG_N: full
    reg [LOG_N-1:0] wa  = {LOG_N{1'b0}};
    reg [LOG_N-1:0] ra  = {LOG_N{1'b0}};
    reg             playing = 1'b0;
    reg             pv = 1'b0, pl = 1'b0;          // read strobe and "last word", one clock behind the address
    reg [2*W-1:0]   rq = {(2*W){1'b0}};
    initial begin ready = 1'b0; out_valid = 1'b0; out_last = 1'b0; out_re = {W{1'b0}}; out_im = {W{1'b0}}; end

    assign take = ~cap[LOG_N];

    always @(posedge clock) begin
        if (win_valid) mem[wa] <= {win_re, win_im};
        rq <= mem[ra];
        if (pv) begin
            out_re <= rq[2*W-1:W];
            out_im <= rq[W-1:0];
        end
        if (rst) begin
            cap <= {(LOG_N+1){1'b0}}; wa <= {LOG_N{1'b0}}; ra <= {LOG_N{1'b0}};
            playing <= 1'b0; ready <= 1'b0; pv <= 1'b0; pl <= 1'b0; out_valid <= 1'b0; out_last <= 1'b0;
        end else begin
            if (in_strobe && take) cap <= cap + 1'b1;
            if (win_valid) begin
                wa <= wa + 1'b1;
                if (wa == {LOG_N{1'b1}}) ready <= 1'b1;
            end
            if (go) begin
                ready   <= 1'b0;
                playing <= 1'b1;
            end
            if (playing) begin
                ra <= ra + 1'b1;
                if (ra == {LOG_N{1'b1}}) playing <= 1'b0;
            end
            pv <= playing;
            pl <= playing && (ra == {LOG_N{1'b1}});
            out_valid <= pv;
            out_last  <= pl;
            if (pl) cap <= {(LOG_N+1){1'b0}};
        end
    end

endmodule
