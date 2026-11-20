// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ft8_ddr3_mux: the FT8 front end's shares of the two DDR3 lanes, each built in one level.
//
// Why this exists
//   The DDR3 is shared by many blocks, through one write lane and one read lane, each with an arbiter that has a few
//   client ports (docs/ARCHITECTURE.md section 3.9).  The FT8 front end gets one write port and one read port, the lowest
//   tier, and has several engines that need them.  So it needs a small arbiter of its own, and these are the ones that are
//   used (docs/FT8_PASS2.md section 8):
//     ft8_ddr3_wmux4  puts four write clients on the write arbiter's FT8 port (the convention of rtl/ddr3/ddr3_write_arbiter.v);
//     ft8_ddr3_rmux3  puts three read clients on the read arbiter's "rest" tier (rtl/ddr3/ddr3_read_arbiter.v);
//     ft8_wr_stage    one register stage between the write mux and the chip's write arbiter.
//   Client 0 has the highest priority, and an owner keeps the lane until its burst's `done`, so a burst is never cut short.
//
// How it is built
//   A chain of two-way arbiters (ft8_ddr3_writer.v and ft8_ddr3_rdmux.v, three and two in a row) was the slowest part of the
//   front end when it was timed on its own: the grant ran back through one select per level into every client.  Here instead:
//   - the owner is a one-hot register, chosen one clock before anything goes upstream (while the mux is idle, `req`
//     upstream is 0), so that a grant in the first clock of `req` goes to the right client by construction;
//   - a client's `gnt` and `done` are a single AND of its owner bit with the lane's;
//   - the address and the data to the lane are a single AND-OR over the owner bits.
//   A burst starts one clock after its client asks.

`timescale 1ns / 1ps

module ft8_ddr3_wmux4 #(
    parameter integer ADDR_WIDTH = 32
) (
    // Clock (clk_dsp, 120 MHz) and synchronous reset (active high).
    input  wire        clk,
    input  wire        rst,
    // Clients, packed: client i in slice i of each vector.  c_req raises a request, c_addr, c_burstlen, c_wdata and
    // c_wmask are the burst's address (a lane word address), length in beats, data and byte mask.  c_gnt is one beat taken
    // (a pulse per beat) and c_done the end of the burst, each only for the owner.
    input  wire [3:0]              c_req,
    input  wire [4*ADDR_WIDTH-1:0] c_addr,
    input  wire [4*8-1:0]          c_burstlen,
    input  wire [4*64-1:0]         c_wdata,
    input  wire [4*8-1:0]          c_wmask,
    output wire [3:0]              c_gnt,
    output wire [3:0]              c_done,
    // The write arbiter's FT8 port.
    output wire                    req,
    output reg  [ADDR_WIDTH-1:0]   addr,
    output reg  [7:0]              burstlen,
    output reg  [63:0]             wdata,
    output reg  [7:0]              wmask,
    input  wire                    gnt,
    input  wire                    done
);

    // sel is the one-hot owner, all zeros while idle.
    reg [3:0] sel /* synthesis syn_maxfan = 10000 */;

    // The request, grant and done signals are an AND with the owner bit.
    assign req    = |(sel & c_req);
    assign c_gnt  = sel & {4{gnt}};
    assign c_done = sel & {4{done}};

    // The address, length, data and mask are an AND-OR of the clients' values with the owner bits.
    integer i;
    always @* begin
        addr     = {ADDR_WIDTH{1'b0}};
        burstlen = 8'd0;
        wdata    = 64'd0;
        wmask    = 8'd0;
        for (i = 0; i < 4; i = i + 1) begin
            addr     = addr     | (c_addr[i*ADDR_WIDTH +: ADDR_WIDTH] & {ADDR_WIDTH{sel[i]}});
            burstlen = burstlen | (c_burstlen[i*8 +: 8] & {8{sel[i]}});
            wdata    = wdata    | (c_wdata[i*64 +: 64] & {64{sel[i]}});
            wmask    = wmask    | (c_wmask[i*8 +: 8] & {8{sel[i]}});
        end
    end

    // Owner selection: when idle, take the lowest-numbered client that asks; release on `done`.
    always @(posedge clk) begin
        if (rst) begin
            sel <= 4'b0000;
        end else if (sel == 4'b0000) begin
            sel <= c_req[0] ? 4'b0001 : c_req[1] ? 4'b0010 : c_req[2] ? 4'b0100 : c_req[3] ? 4'b1000 : 4'b0000;
        end else if (done) begin
            sel <= 4'b0000;
        end
    end

endmodule

module ft8_ddr3_rmux3 #(
    parameter integer ADDR_WIDTH = 32
) (
    input  wire        clk,
    input  wire        rst,
    // Clients, packed as in the write mux: three read clients, each with request, address and burst length, and for
    // each its own gnt, rvalid and done.  The read data is not muxed: every client reads `rdata` straight from the lane
    // and only counts words when its own rvalid is high.
    input  wire [2:0]              c_req,
    input  wire [3*ADDR_WIDTH-1:0] c_addr,
    input  wire [3*8-1:0]          c_burstlen,
    output wire [2:0]              c_gnt,
    output wire [2:0]              c_rvalid,
    output wire [2:0]              c_done,
    // The read arbiter's "rest" tier.
    output wire                    req,
    output reg  [ADDR_WIDTH-1:0]   addr,
    output reg  [7:0]              burstlen,
    input  wire                    gnt,
    input  wire                    rvalid,
    input  wire                    done
);

    // sel is the one-hot owner, all zeros while idle.
    reg [2:0] sel /* synthesis syn_maxfan = 10000 */;

    // Request, grant, read-valid and done are an AND with the owner bit; address and length an AND-OR.
    assign req      = |(sel & c_req);
    assign c_gnt    = sel & {3{gnt}};
    assign c_rvalid = sel & {3{rvalid}};
    assign c_done   = sel & {3{done}};

    integer i;
    always @* begin
        addr     = {ADDR_WIDTH{1'b0}};
        burstlen = 8'd0;
        for (i = 0; i < 3; i = i + 1) begin
            addr     = addr     | (c_addr[i*ADDR_WIDTH +: ADDR_WIDTH] & {ADDR_WIDTH{sel[i]}});
            burstlen = burstlen | (c_burstlen[i*8 +: 8] & {8{sel[i]}});
        end
    end

    // Owner selection as in the write mux.
    always @(posedge clk) begin
        if (rst) begin
            sel <= 3'b000;
        end else if (sel == 3'b000) begin
            sel <= c_req[0] ? 3'b001 : c_req[1] ? 3'b010 : c_req[2] ? 3'b100 : 3'b000;
        end else if (done) begin
            sel <= 3'b000;
        end
    end

endmodule

// ---------------------------------------------------------------------------------------------------------
// ft8_wr_stage: one register stage between ft8_ddr3_wmux4 and the chip's write arbiter (the second write relay of
// docs/ROUTE_CAUSE.md section 6, row 1).  The arbiter's `gnt` and `done` come combinationally from the DDR3 lane's wait,
// and the mux hands them on to the four clients, so a lane signal ran through the arbiter, the mux and a client's counters
// in one clock, which did not meet timing.  Here the stage is the arbiter's client and the mux's arbiter:
//   - towards the arbiter it is a client of the usual kind (req, addr, burstlen, wdata and wmask held in registers; `req`
//     is high from the clock after a beat is taken until the arbiter's `gnt` for it);
//   - towards the mux it is the arbiter: `m_gnt` (one beat taken) is `m_req` and the stage empty, formed from registers and
//     the mux's own `req` only; `m_done` is the arbiter's `done` registered.
// It is not ddr3_wr_relay.v itself: that module speaks the lane's wait/done handshake, which the arbiter does not show to
// its clients (it gives a combinational gnt for the clock a beat is taken, and nothing for "the word is in").  The stage
// counts the beats of the burst from `burstlen` (0 counts as 1), so that after the last beat it takes nothing more until the
// arbiter's `done` has reached the mux and the client has dropped `req`.  It takes one beat at most every second clock,
// which is plenty: the lane takes one word per ten clocks or more.
module ft8_wr_stage #(
    parameter integer ADDR_WIDTH = 32
) (
    // Clock and synchronous reset (active high).
    input  wire        clk,
    input  wire        rst,
    // The mux side: the burst that the mux wants to send, one beat per m_gnt, and the end of the burst on m_done.
    input  wire                    m_req,
    input  wire [ADDR_WIDTH-1:0]   m_addr,
    input  wire [7:0]              m_burstlen,
    input  wire [63:0]             m_wdata,
    input  wire [7:0]              m_wmask,
    output wire                    m_gnt,
    output reg                     m_done = 1'b0,
    // The chip's write arbiter, FT8 port.
    output reg                     req = 1'b0,
    output reg  [ADDR_WIDTH-1:0]   addr = {ADDR_WIDTH{1'b0}},
    output reg  [7:0]              burstlen = 8'd0,
    output reg  [63:0]             wdata = 64'd0,
    output reg  [7:0]              wmask = 8'd0,
    input  wire                    gnt,
    input  wire                    done
);
    // State: inb is high while a burst is under way, blk when the last beat has been taken, left counts the beats still to take.
    reg       inb = 1'b0;            // a burst is under way: its first beat has been taken
    reg       blk = 1'b0;            // the last beat of the burst has been taken: take nothing until `done` is through
    reg [7:0] left = 8'd0;           // beats of the burst still to be taken after the ones taken

    // A beat is taken when the mux asks, the previous beat has been handed over and the burst is not yet complete.
    assign m_gnt = m_req && !req && !blk;

    wire [7:0] total  = (m_burstlen == 8'd0) ? 8'd1 : m_burstlen;
    wire [7:0] left_n = inb ? (left - 8'd1) : (total - 8'd1);

    // Registers hold the beat for the arbiter until it grants; counting of the burst's beats; release on done.
    always @(posedge clk) begin
        m_done <= done;
        if (gnt) req <= 1'b0;
        if (m_gnt) begin
            req      <= 1'b1;
            addr     <= m_addr;
            burstlen <= m_burstlen;
            wdata    <= m_wdata;
            wmask    <= m_wmask;
            inb      <= 1'b1;
            left     <= left_n;
            if (left_n == 8'd0) blk <= 1'b1;
        end
        if (m_done) begin              // one clock after the arbiter's done: the mux has the client released now
            inb <= 1'b0;
            blk <= 1'b0;
        end
        if (rst) begin
            req <= 1'b0; inb <= 1'b0; blk <= 1'b0; m_done <= 1'b0;
        end
    end
endmodule
