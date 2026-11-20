// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ddr3_write_arbiter: lets four write clients share the one DDR3 write lane, one burst at a time, in a fixed
// priority order.
//
// WHERE IT SITS
// The radio keeps its bulk data in the board's 1 GB of DDR3 memory (rtl/mem/ddr_mem.v explains how the memory is
// organized and how the AE350 CPU and the logic share it). The logic reaches the memory through two lanes, a write
// lane and a read lane, which keep the names of the AE350 manual's "Shared DDR3: Logic R/W Mode" signals (MUG1031
// table 5-1, signals `..._lane4` for writing and `..._lane5` for reading). Each lane carries 64-bit words, runs on
// clk_dsp (120 MHz) and can serve only one burst at a time. Several blocks want to write, so this arbiter sits in
// front of lane 4. Its upstream side feeds ddr3_wr_relay (rtl/ddr3/ddr3_wr_relay.v), which feeds the lane in
// ddr_mem.v; the read lane has the twin ddr3_read_arbiter.v. The four clients, from highest to lowest priority:
//   1 iq   the receiver back end, which writes the IQ rings the CPU reads (about 24.6 MB/s with 8 receivers)
//   2 wf   the full-band waterfall writer, one 1,920-byte line at a time (tiny: 60 lines/s)
//   3 cap  the zoom waterfall writer (the tier is named after raw capture, a client that is not built)
//   4 ft8  the FT8/FT4 front end, writing slot captures and the spectrogram ring (about 1.6 MB/s over 8 receivers)
// Together they need about 26 MB/s (docs/F4_DDR.md section 3). The fourth tier sits last so that it can never disturb
// the three above it. The priority order itself is the one docs/ARCHITECTURE.md 3.9 states.
//
// A BURST, AND WHAT A CLIENT SEES
// A burst is a run of consecutive 64-bit words (8 bytes each) written to consecutive addresses after one request,
// which is cheaper than a request per word because the address is sent once. The burst length is an 8-bit field,
// so a burst has up to 255 words. Each client has the same port, a streaming write burst:
//   - It holds `req` high while it wants to start a burst, presents the burst's first word address on `addr` and
//     its length on `burstlen`, and drives `wdata` and `wmask` for the current beat (one word) combinationally.
//     A client must not change `addr` or `burstlen` after raising `req` until it sees `done`.
//   - The arbiter makes `gnt` high for one clock for every beat of this client's that the lane took, and the client
//     advances its own beat counter on that clock.
//   - `done` is high for one clock once the whole burst has landed in the memory controller.
//
// HOW IT WORKS, STEP BY STEP
//   1. In the idle state it picks the highest-priority client with `req` high (next_owner), remembers it in `owner`
//      and moves to the busy state, one clock after the client's `req` came up.
//   2. From then on a registered one-hot select (sel_c) steers that client's address, length, data and mask onto the
//      lane signals, and the client's `req` becomes the lane's `wr_en`.
//   3. The lane takes a beat in every clock in which `wr_en` is high and `wr_wait` is low, and the owner's `gnt`
//      shows exactly those clocks. The first beat of the burst makes the lane read the address and the length.
//   4. When the lane raises `wr_done` after the last word, the owner's `done` pulses, the owner is cleared and the
//      arbiter is idle again, ready to choose among the clients that are waiting.
// The upstream signals are those of MUG1031 table 5-1 exactly (addr_lane4, wr_mask_lane4, wr_data_lane4, wr_en_lane4,
// wr_go_lane4, burstcount_lane4, wr_wait_lane4, wr_done_lane4), so the module plugs into the real lane, or into the
// testbench model sim/ddr3/ddr3_lane_behav_model.v, unchanged. docs/F4_DDR.md section 2 lists two points the manual
// leaves open: the width of the mask in the 64-bit configuration (8 bits, one per byte, 1 = byte written) and the
// unit of the address (64-bit words, not bytes).
//
// WHY A BURST IS NEVER INTERRUPTED
// Priority is evaluated only while the lane is idle, between bursts. Once a client owns the lane it keeps it until
// its `done`, so a lower-priority client that is already in the middle of a burst is never pre-empted (the lane has
// a single burst-length field and no way to stop a burst anyway). The worst delay a high-priority client can meet
// from a lower one is therefore one burst, however long that burst is, and never an unbounded run. A client that
// chooses a long burst (up to 255 words, about 21 microseconds at ten clocks per word) trades a longer worst-case
// wait for everybody behind it against fewer, cheaper request round trips for itself (docs/F4_DDR.md section 2).

`timescale 1ns / 1ps

module ddr3_write_arbiter #(
    parameter integer ADDR_WIDTH = 32,
    parameter integer DATA_WIDTH = 64,
    parameter integer MASK_WIDTH = DATA_WIDTH / 8
) (
    input  wire                    clk,  // clk_dsp, 120 MHz; everything here and on the lane runs on it
    input  wire                    rst,  // synchronous reset, high = reset; the arbiter goes idle with no owner

    // -------- client 1: IQ writer, the receiver back end (highest priority) --------
    input  wire                    iq_req,  // wants to start a burst; held until `done`
    input  wire [ADDR_WIDTH-1:0]   iq_addr,  // word address (64-bit words) of the burst's first word; held until `done`
    input  wire [7:0]              iq_burstlen,  // burst length in words, 1 to 255; held until `done`
    input  wire [DATA_WIDTH-1:0]   iq_wdata,  // data of the current beat, 64 bits, valid while `req` is high
    input  wire [MASK_WIDTH-1:0]   iq_wmask,  // byte mask of the current beat, bit i = 1 writes byte i
    output wire                    iq_gnt,  // beat taken: high for one clock per word accepted onto the lane
    output wire                    iq_done,  // the burst has landed: high for one clock after the last word

    // -------- client 2: waterfall writer --------
    input  wire                    wf_req,  // as iq_req
    input  wire [ADDR_WIDTH-1:0]   wf_addr,  // as iq_addr
    input  wire [7:0]              wf_burstlen,  // as iq_burstlen
    input  wire [DATA_WIDTH-1:0]   wf_wdata,  // as iq_wdata
    input  wire [MASK_WIDTH-1:0]   wf_wmask,  // as iq_wmask
    output wire                    wf_gnt,  // as iq_gnt
    output wire                    wf_done,  // as iq_done

    // -------- client 3: zoom waterfall writer (the tier is named after raw capture) --------
    input  wire                    cap_req,  // as iq_req
    input  wire [ADDR_WIDTH-1:0]   cap_addr,  // as iq_addr
    input  wire [7:0]              cap_burstlen,  // as iq_burstlen
    input  wire [DATA_WIDTH-1:0]   cap_wdata,  // as iq_wdata
    input  wire [MASK_WIDTH-1:0]   cap_wmask,  // as iq_wmask
    output wire                    cap_gnt,  // as iq_gnt
    output wire                    cap_done,  // as iq_done

    // -------- client 4: FT8/FT4 front end, slot capture and spectrogram ring (lowest priority) --------
    input  wire                    ft8_req,  // as iq_req
    input  wire [ADDR_WIDTH-1:0]   ft8_addr,  // as iq_addr
    input  wire [7:0]              ft8_burstlen,  // as iq_burstlen
    input  wire [DATA_WIDTH-1:0]   ft8_wdata,  // as iq_wdata
    input  wire [MASK_WIDTH-1:0]   ft8_wmask,  // as iq_wmask
    output wire                    ft8_gnt,  // as iq_gnt
    output wire                    ft8_done,  // as iq_done

    // -------- upstream: MUG1031 table 5-1 write lane (lane 4) --------
    output reg  [ADDR_WIDTH-1:0]   addr_lane4,  // word address of the burst, 64-bit words; the lane reads it with the first beat
    output reg  [MASK_WIDTH-1:0]   wr_mask_lane4,  // byte mask of the beat, bit i = 1 writes byte i
    output reg  [DATA_WIDTH-1:0]   wr_data_lane4,  // data of the beat, 64 bits
    output reg                     wr_en_lane4,  // a beat is offered; taken in a clock with wr_en high and wr_wait low
    output reg                     wr_go_lane4,  // one-clock start-of-burst pulse, one clock after wr_en first rises; only the AE350's own lane uses it
    output reg  [7:0]              burstcount_lane4,  // burst length in words; the lane reads it with the first beat
    input  wire                    wr_wait_lane4,  // from the lane: high while it cannot take a beat
    input  wire                    wr_done_lane4,  // from the lane: one-clock pulse after the last word of a burst is in the memory controller

    // instrumentation (used by the testbenches): which client owns the lane
    // (0 = none, 1 = IQ, 2 = waterfall, 3 = zoom waterfall (capture tier), 4 = FT8/FT4)
    output reg  [2:0]              owner
);

    // The two states of the arbiter: IDLE chooses an owner, BUSY runs that owner's burst.
    localparam IDLE = 1'b0, BUSY = 1'b1;
    reg state;  // current state, IDLE or BUSY

    // The owner is chosen in IDLE and registered. The lane is driven, and `gnt` and `done` are given, from the
    // registered owner only, from the first clock of BUSY on. The first beat is therefore not forwarded or granted in
    // the IDLE clock itself, since that would run each client's `req` through the priority choice among the four
    // `req` signals, then through `ft8_gnt` and into the client's own counters and write multiplexer, all in one
    // 8.3 ns clock. The price is one clock more at the start of each burst, which is small against the roughly ten
    // clocks every word takes anyway. A client keeps `req`, `addr`, `burstlen` and the current beat's `wdata` and
    // `wmask` steady from `req` until `done` (see the header), so it does not matter that the first `gnt` comes one
    // clock later.
    // Priority encoder, combinational: the highest-priority client with `req` high, as an owner number (1 to 4), or
    // 0 when nobody wants the lane.
    reg [2:0] next_owner;
    always @* begin
        if (iq_req) begin
            next_owner = 3'd1;
        end else if (wf_req) begin
            next_owner = 3'd2;
        end else if (cap_req) begin
            next_owner = 3'd3;
        end else if (ft8_req) begin
            next_owner = 3'd4;
        end else begin
            next_owner = 3'd0;
        end
    end

    // Forwarding multiplexer. The select is a one-hot register per 8-bit byte lane of the data, mask, address and
    // length fields (`sel_c`, kept with syn_preserve because a decode of identical nets would just be merged back into one
    // by synthesis): as a single net it cost 3.5 ns of routing alone and was this block's critical
    // path. Splitting the select into one copy per byte lane gives every copy a small fan-out. The
    // function is the same as one case statement on the owner would give: each output bit is the OR of the four
    // clients' bits, each ANDed with its own select bit, and only one select bit is high.
    // NSEL: number of byte lanes of the data word (8 for a 64-bit word); sel_c holds 4 select bits per byte lane,
    // one for each client (bit 0 = iq, 1 = wf, 2 = cap, 3 = ft8).
    localparam integer NSEL = DATA_WIDTH / 8;
    (* syn_preserve = 1 *) reg [4*NSEL-1:0] sel_c;
    wire [DATA_WIDTH-1:0] fwd_data;
    wire [MASK_WIDTH-1:0] fwd_mask;
    wire [ADDR_WIDTH-1:0] fwd_addr;
    wire [7:0]            fwd_len;
    genvar gs;
    // One generate block per byte lane. It decodes that lane's four select bits and builds the byte of the forwarded
    // data, and, for the lanes that exist, of the mask (one bit per byte), the address (4 bytes) and the length (1 byte).
    generate
        for (gs = 0; gs < NSEL; gs = gs + 1) begin : g_sel
            wire s_iq  = sel_c[gs*4 + 0];
            wire s_wf  = sel_c[gs*4 + 1];
            wire s_cap = sel_c[gs*4 + 2];
            wire s_ft8 = sel_c[gs*4 + 3];
            assign fwd_data[gs*8 +: 8] = ({8{s_iq}}  & iq_wdata[gs*8 +: 8]) |
                                         ({8{s_wf}}  & wf_wdata[gs*8 +: 8]) |
                                         ({8{s_cap}} & cap_wdata[gs*8 +: 8]) |
                                         ({8{s_ft8}} & ft8_wdata[gs*8 +: 8]);
            if (gs < MASK_WIDTH) begin : g_mask
                assign fwd_mask[gs] = (s_iq & iq_wmask[gs]) | (s_wf & wf_wmask[gs]) |
                                      (s_cap & cap_wmask[gs]) | (s_ft8 & ft8_wmask[gs]);
            end
            if (gs < ADDR_WIDTH / 8) begin : g_addr
                assign fwd_addr[gs*8 +: 8] = ({8{s_iq}}  & iq_addr[gs*8 +: 8]) |
                                             ({8{s_wf}}  & wf_addr[gs*8 +: 8]) |
                                             ({8{s_cap}} & cap_addr[gs*8 +: 8]) |
                                             ({8{s_ft8}} & ft8_addr[gs*8 +: 8]);
            end
            if (gs == 0) begin : g_len
                assign fwd_len = ({8{s_iq}} & iq_burstlen) | ({8{s_wf}} & wf_burstlen) |
                                 ({8{s_cap}} & cap_burstlen) | ({8{s_ft8}} & ft8_burstlen);
            end
        end
    endgenerate

    // The lane's request: the owner's `req`, valid only while that client owns the lane.
    reg wr_en_raw;
    always @* begin
    // Address, length, data and mask come from the registered select; no extra register sits in between.
        addr_lane4       = fwd_addr;
        burstcount_lane4 = fwd_len;
        wr_data_lane4    = fwd_data;
        wr_mask_lane4    = fwd_mask;
        case (owner)
            3'd1:    wr_en_raw = iq_req;
            3'd2:    wr_en_raw = wf_req;
            3'd3:    wr_en_raw = cap_req;
            3'd4:    wr_en_raw = ft8_req;
            default: wr_en_raw = 1'b0;
        endcase
        // The owning client's `req` stays high through the clock in which `wr_done_lane4` pulses, because it only
        // reacts to `done` at the next clock edge. Without this qualifier the lane would see one extra, spurious beat
        // request in that clock, and since the lane's own busy flag already dropped when `wr_done_lane4` rose, it
        // would accept it as the start of a new burst at the old address. That would put the lane's burst tracking out
        // of step with this arbiter's `owner` and `state`, and the data of the next burst would land at wrong addresses.
        wr_en_lane4 = wr_en_raw && !wr_done_lane4;
    end

    // A beat is accepted in a clock with the lane's request up and its wait down.
    wire beat_accepted = wr_en_lane4 && !wr_wait_lane4;

    // `gnt` and `done` are combinational, straight off `beat_accepted` and `wr_done_lane4`, and not registered. The
    // client's own beat counter must advance on the same clock edge on which the lane's internal address counter
    // does, because otherwise the two drift apart and the client starts presenting beat N's data one or two clocks
    // after the lane has already latched it for beat N+1's address, which corrupts the data written.
    assign iq_gnt   = (owner == 3'd1) && beat_accepted;
    assign wf_gnt   = (owner == 3'd2) && beat_accepted;
    assign cap_gnt  = (owner == 3'd3) && beat_accepted;
    assign ft8_gnt  = (owner == 3'd4) && beat_accepted;
    assign iq_done  = (owner == 3'd1) && wr_done_lane4;
    assign wf_done  = (owner == 3'd2) && wr_done_lane4;
    assign cap_done = (owner == 3'd3) && wr_done_lane4;
    assign ft8_done = (owner == 3'd4) && wr_done_lane4;

    // wr_go follows one clock after the first beat is first requested. The lane of the 256 MB fall-back build wants
    // wr_en one clock before wr_go; the lane of the 1 GB build does not use wr_go at all.
    reg go_q;  // one-clock pulse when an owner has just been chosen; wr_go is this signal delayed by one more clock
    integer sk;  // loop variable of the select update below
    // Sequential part: wr_go pulse, state, owner and select registers.
    always @(posedge clk) begin
        go_q        <= 1'b0;
        wr_go_lane4 <= go_q;

        if (rst) begin
            state   <= IDLE;
            owner   <= 3'd0;
            sel_c   <= {(4*NSEL){1'b0}};
        end else begin
            case (state)
                // IDLE: when some client wants the lane, register the owner, set that owner's select bit in every
                // byte lane and move to BUSY; go_q starts the wr_go pulse.
                IDLE: begin
                    if (next_owner != 3'd0) begin
                        owner   <= next_owner;
                        state   <= BUSY;
                        for (sk = 0; sk < NSEL; sk = sk + 1)
                            sel_c[sk*4 +: 4] <= 4'b0001 << (next_owner - 3'd1);
                        go_q    <= 1'b1;
                    end
                end
                // BUSY: keep the owner until the lane reports the last word, then release everything.
                BUSY: begin
                    if (wr_done_lane4) begin
                        state   <= IDLE;
                        owner   <= 3'd0;
                        sel_c   <= {(4*NSEL){1'b0}};
                    end
                end
            endcase
        end
    end

endmodule
