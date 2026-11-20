// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ddr3_read_arbiter: lets four read clients share the one DDR3 read lane, one burst at a time, in a fixed priority
// order that always serves the video reader first.
//
// WHERE IT SITS
// The radio keeps its bulk data in the board's 1 GB of DDR3 memory (rtl/mem/ddr_mem.v explains how the memory is
// organized and how the AE350 CPU and the logic share it). The logic reaches the memory through a write lane and a
// read lane, which keep the names of the AE350 manual's "Shared DDR3: Logic R/W Mode" signals (MUG1031 table 5-1,
// signals `..._lane5` for reading and `..._lane4` for writing). The read lane carries 64-bit words, runs on clk_dsp
// (120 MHz) and serves one burst at a time, so this arbiter sits in front of it. Its upstream side feeds
// ddr3_rd_relay (rtl/ddr3/ddr3_rd_relay.v), which feeds the lane in ddr_mem.v; the write lane has the twin
// ddr3_write_arbiter.v. The four clients are, from the highest to the lowest priority tier:
//   tier 0, video     the compositor's scan-out reader, which fetches the picture (the Slint screen layer and the
//                     waterfall line data) for the HDMI output. It needs about 374 MB/s steadily (docs/F4_DDR.md
//                     section 3) and must never starve, because a late line shows on the monitor as a flicker or a
//                     torn picture. It has strict top priority.
//   tier 1, audio, tx the audio ring reader and the TX ring reader, which fetch the 48 kHz sample streams the CPU
//                     wrote (together about 0.4 MB/s). They have equal priority and take turns (round robin) when
//                     both want the lane, so neither can starve the other.
//   tier 2, rest      everything else that reads over this lane, which today is the FT8 sync engine. The budget in
//                     docs/ARCHITECTURE.md 3.9 names no occupant for it, so it is a catch-all background reader that
//                     gets a small but real share (docs/F4_DDR.md section 2).
// The owner number used inside and on the `owner` port is 1 for video, 2 for audio, 3 for tx and 4 for rest, and
// 0 for nobody.
//
// A BURST, AND WHAT A CLIENT SEES
// A burst is a run of consecutive 64-bit words (8 bytes each) read from consecutive addresses after one request,
// which is cheaper than a request per word because the address is sent once. The burst length is an 8-bit field, so
// a burst has up to 255 words. Each client has the same port, a read burst request:
//   - It holds `req`, `addr` and `burstlen` steady while it wants a burst, from `req` until its `done`.
//   - The arbiter pulses `gnt` once when the request (not a data word) has been accepted onto the lane, so the
//     client can drop `req` or move on to the address of its next burst.
//   - `rvalid` and `rdata` deliver the burst's data, one pulse per word, `burstlen` words in all; rdata is the same
//     bus for every client and only the owner's `rvalid` pulses.
//   - `done` pulses once after the last word.
//
// HOW IT WORKS, STEP BY STEP
//   1. IDLE: the highest-priority client with `req` high is chosen (next_owner) and remembered in `owner`.
//   2. ISSUE: the owner's address and length are put on the lane together with `rd_en_lane5`, and the arbiter waits
//      until the lane takes them, which it does in a clock with `rd_rdy_lane5` high.
//   3. BUSY: the lane returns the burst's words, each marked by `rd_valid_lane5`. MUG1031 table 5-1 has no "read
//      done" line, only `rd_rdy_lane5`, so the arbiter counts the words against the burst length (beats_left) to
//      know when the burst is over. `gnt` pulsed when ISSUE ended, and `done` pulses when the last word has passed.
//   4. SETTLE: one clock of rest, then back to IDLE.
// Priority is evaluated only in IDLE, so a lower-tier client that is in the middle of a burst is never pre-empted and
// the longest a video request can wait for one lower-tier burst is the burst's own length, however long that is.
// Because the burst length is up to 255 words, a client that chooses a long burst makes everybody behind it wait
// longer but needs fewer request round trips for itself (docs/F4_DDR.md section 2; the write arbiter has the same
// rule). The lane itself may deliver about 600 MB/s at most with the 75 MHz memory controller clock, against the 374
// MB/s that video needs (docs/DECISIONS.md, docs/MEM_1GB.md section 4).

`timescale 1ns / 1ps

module ddr3_read_arbiter #(
    parameter integer ADDR_WIDTH = 32,
    parameter integer DATA_WIDTH = 64
) (
    input  wire                    clk,  // clk_dsp, 120 MHz; everything here and on the lane runs on it
    input  wire                    rst,  // synchronous reset, high = reset; the arbiter goes idle with no owner

    // -------- tier 0: video scan-out reader --------
    input  wire                    video_req,  // wants a burst; held until `done`
    input  wire [ADDR_WIDTH-1:0]   video_addr,  // word address (64-bit words) of the burst's first word; held until `done`
    input  wire [7:0]              video_burstlen,  // burst length in words, 1 to 255; held until `done`
    output wire                    video_gnt,  // request accepted onto the lane: one-clock pulse
    output wire                    video_rvalid,  // one data word of the burst is on `video_rdata` (one-clock pulse per word)
    output wire [DATA_WIDTH-1:0]   video_rdata,  // data word, 64 bits, valid while `video_rvalid` is high
    output wire                    video_done,  // the whole burst has been delivered: one-clock pulse after the last word

    // -------- tier 1a: audio ring reader (equal priority with tx, round robin) --------
    input  wire                    audio_req,  // as video_req
    input  wire [ADDR_WIDTH-1:0]   audio_addr,  // as video_addr
    input  wire [7:0]              audio_burstlen,  // as video_burstlen
    output wire                    audio_gnt,  // as video_gnt
    output wire                    audio_rvalid,  // as video_rvalid
    output wire [DATA_WIDTH-1:0]   audio_rdata,  // as video_rdata
    output wire                    audio_done,  // as video_done

    // -------- tier 1b: TX ring reader (equal priority with audio, round robin) --------
    input  wire                    tx_req,  // as video_req
    input  wire [ADDR_WIDTH-1:0]   tx_addr,  // as video_addr
    input  wire [7:0]              tx_burstlen,  // as video_burstlen
    output wire                    tx_gnt,  // as video_gnt
    output wire                    tx_rvalid,  // as video_rvalid
    output wire [DATA_WIDTH-1:0]   tx_rdata,  // as video_rdata
    output wire                    tx_done,  // as video_done

    // -------- tier 2: the rest (today the FT8 sync engine) --------
    input  wire                    rest_req,  // as video_req
    input  wire [ADDR_WIDTH-1:0]   rest_addr,  // as video_addr
    input  wire [7:0]              rest_burstlen,  // as video_burstlen
    output wire                    rest_gnt,  // as video_gnt
    output wire                    rest_rvalid,  // as video_rvalid
    output wire [DATA_WIDTH-1:0]   rest_rdata,  // as video_rdata
    output wire                    rest_done,  // as video_done

    // -------- upstream: MUG1031 table 5-1 read lane (lane 5), reached through ddr3_rd_relay --------
    output reg  [ADDR_WIDTH-1:0]   addr_lane5,  // word address of the burst, 64-bit words; held while rd_en_lane5 is high
    output reg                     rd_en_lane5,  // request to the lane, high in ISSUE until the lane accepts (rd_rdy_lane5 high)
    output reg                     rd_go_lane5,  // start-of-burst pulse, one clock after the request is accepted; only the AE350's own lane uses it
    output reg  [7:0]              burstcount_lane5,  // burst length in words, 1 to 255
    input  wire                    rd_valid_lane5,  // from the lane: one-clock pulse per data word of the burst
    input  wire [DATA_WIDTH-1:0]   rd_data_lane5,  // from the lane: data word, 64 bits, valid with rd_valid_lane5
    input  wire                    rd_rdy_lane5,  // from the lane: high = the lane is free for the next request, low from acceptance until the last word is out

    // instrumentation (used by the testbenches): which client owns the lane
    // (0 = none, 1 = video, 2 = audio, 3 = tx, 4 = rest)
    output reg  [2:0]              owner
);

    // IDLE only chooses and registers the owner. ISSUE then offers that owner's request to the lane, with the address
    // and length selected by the registered owner. If the choice (client `req`, then priority, then address select)
    // were made in the same clock as the lane relay's request registers, that path would be too long for 120 MHz
    // (6 logic levels, three quarters of the delay in routing). The price is one clock more at the start of each
    // burst, which is small against a burst of 180 words that takes about 190 clocks. A client keeps `req`, `addr`
    // and `burstlen` steady from `req` until its `done` (see the header). The four states are:
    //   IDLE    nobody owns the lane; look for a request
    //   ISSUE   the owner's request is offered to the lane and waits for it to be accepted
    //   BUSY    the lane returns the burst's words
    //   SETTLE  one clock after the last word, before the next choice (explained at the BUSY branch below)
    localparam [1:0] IDLE = 2'd0, BUSY = 2'd1, SETTLE = 2'd2, ISSUE = 2'd3;
    reg [1:0] state;  // current state: IDLE, ISSUE, BUSY or SETTLE
    reg [7:0] beats_left;  // words of the current burst that have not yet come back; counts down in BUSY
    reg       rr_last; // round-robin memory between audio and tx: 0 = audio was served last (so tx is next when both wait), 1 = tx was served last (so audio is next)

    // Priority encoder, combinational: the owner number (1 to 4) of the highest-priority client with `req` high, or
    // 0 when nobody wants the lane. Audio and tx are equals and take turns by rr_last.
    reg [2:0] next_owner;
    always @* begin
        if (video_req) begin
            next_owner = 3'd1;
        end else if (audio_req || tx_req) begin
            if (audio_req && tx_req) begin
                next_owner = rr_last ? 3'd2 : 3'd3; // rr_last=1 (tx served) -> audio next
            end else if (audio_req) begin
                next_owner = 3'd2;
            end else begin
                next_owner = 3'd3;
            end
        end else if (rest_req) begin
            next_owner = 3'd4;
        end else begin
            next_owner = 3'd0;
        end
    end

    // The owner whose request or burst is on the lane right now; 0 in IDLE and SETTLE so that the lane signals are
    // quiet then.
    reg [2:0] active;
    always @* active = (state == ISSUE || state == BUSY) ? owner : 3'd0;

    // Multiplexer: the address, length and `req` of the active owner. active_req is selected for completeness; nothing
    // downstream uses it.
    reg [ADDR_WIDTH-1:0] active_addr;
    reg [7:0]             active_burstlen;
    reg                   active_req;
    always @* begin
        case (active)
            3'd1: begin active_addr = video_addr; active_burstlen = video_burstlen; active_req = video_req; end
            3'd2: begin active_addr = audio_addr; active_burstlen = audio_burstlen; active_req = audio_req; end
            3'd3: begin active_addr = tx_addr;    active_burstlen = tx_burstlen;    active_req = tx_req;    end
            3'd4: begin active_addr = rest_addr;  active_burstlen = rest_burstlen;  active_req = rest_req;  end
            default: begin active_addr = {ADDR_WIDTH{1'b0}}; active_burstlen = 8'd0; active_req = 1'b0; end
        endcase
    end

    // Lane outputs: the active owner's address and length, and the request, which is high only in ISSUE.
    always @* begin
        addr_lane5       = active_addr;
        burstcount_lane5 = active_burstlen;
        // The request is offered only in ISSUE, until the lane accepts it. Once it is accepted (the state goes to
        // BUSY at the clock edge) the lane runs the burst on its own and needs no request until the next one.
        rd_en_lane5 = (state == ISSUE);
    end

    // One-clock pulses per client (indices 1 to 4 are the owner numbers): `gnt` when the request is accepted, `done`
    // after the last word. Both are registered, so they appear in the clock after the event.
    reg gnt_pulse [1:4];
    reg done_pulse [1:4];
    integer gi;

    // gnt and done to the clients
    assign video_gnt = gnt_pulse[1];
    assign audio_gnt = gnt_pulse[2];
    assign tx_gnt    = gnt_pulse[3];
    assign rest_gnt  = gnt_pulse[4];

    assign video_done = done_pulse[1];
    assign audio_done = done_pulse[2];
    assign tx_done    = done_pulse[3];
    assign rest_done  = done_pulse[4];

    // rvalid to the clients: the lane's rd_valid_lane5 goes only to the current owner; rdata is shared
    assign video_rvalid = rd_valid_lane5 && (owner == 3'd1);
    assign audio_rvalid = rd_valid_lane5 && (owner == 3'd2);
    assign tx_rvalid    = rd_valid_lane5 && (owner == 3'd3);
    assign rest_rvalid  = rd_valid_lane5 && (owner == 3'd4);
    assign video_rdata = rd_data_lane5;
    assign audio_rdata = rd_data_lane5;
    assign tx_rdata    = rd_data_lane5;
    assign rest_rdata  = rd_data_lane5;

    // The lane takes the request in a clock in which the arbiter asks (ISSUE) and the lane is free.
    wire req_accepted = rd_en_lane5 && rd_rdy_lane5;

    // Sequential part: the pulses fall back to 0 each clock and are set again by the branches below.
    always @(posedge clk) begin
        for (gi = 1; gi <= 4; gi = gi + 1) begin
            gnt_pulse[gi]  <= 1'b0;
            done_pulse[gi] <= 1'b0;
        end
        rd_go_lane5 <= 1'b0;

        if (rst) begin
            state      <= IDLE;
            owner      <= 3'd0;
            beats_left <= 8'd0;
            rr_last    <= 1'b0;
        end else begin
            case (state)
                // IDLE: register the winner of the priority choice and go to ISSUE.
                IDLE: begin
                    if (next_owner != 3'd0) begin
                        owner <= next_owner;
                        state <= ISSUE;
                    end
                end
                // ISSUE: when the lane accepts, load the burst length into the word counter, pulse gnt and the
                // start-of-burst signal, move to BUSY and note for the round robin which of audio and tx was served.
                ISSUE: begin
                    if (req_accepted) begin
                        beats_left <= active_burstlen;
                        state      <= BUSY;
                        rd_go_lane5 <= 1'b1;
                        gnt_pulse[owner] <= 1'b1;
                        if (owner == 3'd2) rr_last <= 1'b0;
                        if (owner == 3'd3) rr_last <= 1'b1;
                    end
                end
                // BUSY: each word that comes back is counted off; the last one ends the burst.
                BUSY: begin
                    if (rd_valid_lane5) begin
                        if (beats_left <= 8'd1) begin
                            done_pulse[owner] <= 1'b1;
                            // One settle clock before looking for the next owner, not straight back to IDLE. The
                            // registered `done_pulse` (and so each client's `done`) is visible to the client only in
                            // the clock after this one, and that is also the earliest clock in which a client that
                            // keeps requesting has updated its own `addr` (it updates on seeing `done`). Without the
                            // settle clock such a client would be granted again with its old address, one clock
                            // too early, and every burst after the first would read the previous burst's addresses.
                            state <= SETTLE;
                            owner <= 3'd0;
                        end
                        beats_left <= beats_left - 8'd1;
                    end
                end
                // SETTLE: nothing to do for one clock.
                SETTLE: begin
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule
