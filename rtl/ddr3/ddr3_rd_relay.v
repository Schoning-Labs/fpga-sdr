// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ddr3_rd_relay: one register stage in the DDR3 read lane, between the read arbiter (rtl/ddr3/ddr3_read_arbiter.v)
// and the read lane of the memory bridge (module ddr_mem_rdlane in rtl/mem/ddr_mem.v). It is the read-side twin of
// rtl/ddr3/ddr3_wr_relay.v.
//
// WHERE IT SITS
// Everything in the radio that reads bulk data from the board's DDR3 memory (the video scan-out, the audio and TX
// ring readers, the FT8 sync engine) goes through the one read lane, which is called lane 5 after the signal names of
// the AE350 manual (the write lane is lane 4). The chain for a read request is: a client block -> ddr3_read_arbiter,
// which lets one client at a time use the lane -> this relay -> ddr_mem_rdlane -> the memory controller -> DDR3 chips.
// Everything up to and including ddr_mem_rdlane runs on clk_dsp (120 MHz), while the controller runs on its own 75 MHz
// clock and the crossing is done inside ddr_mem.v. Only the request (address and burst length) goes through the relay.
// The data beats come back from the lane to the arbiter directly, in rd_valid and rd_data, because they need no
// register stage of their own. A burst is a run of consecutive 64-bit words fetched by one request, and a lane
// handshake is the request/accept/done exchange described in the header of rtl/mem/ddr_mem.v. Terms like burst and
// lane are in docs/learn/GLOSSARY.md.
//
// WHY IT EXISTS
// Without the relay the arbiter forwards the owning client's request, address and length to the lane through no
// register at all (client `req`, then the choice of owner, then the address multiplexer, then `rd_en`), and the lane
// takes them into its line, count and word registers in the same clock. For the FT8 sync engine that meant its read
// request ran through the front end's share of the lane, the arbiter and the lane's own logic in one 8.3 ns clock of
// clk_dsp, which is 8 to 12 logic levels with more than half of the delay in routing, too long to meet 120 MHz. The
// relay breaks that path in two at the price of two clocks per burst.
//
// HOW IT WORKS, STEP BY STEP
// It speaks the lane handshake on both sides.
//   towards the arbiter  it acts as the lane: a request is taken in a clock with a_en high and a_rdy high. After
//                        that a_rdy is low until the lane has taken the request and has finished the burst, which
//                        the lane shows by its rd_rdy (here l_rdy) being high again. The data (rd_valid, rd_data)
//                        does not pass through the relay.
//   towards the lane     it acts as the arbiter: l_en, l_addr and l_burst stand in registers until the lane takes
//                        them (l_rdy high), as the lane requires. l_go is one clock high after the lane took the
//                        request; only the AE350's own lane in the 256 MB fall-back build (compiled with TR_DDR_256)
//                        uses it.
// Three states cover it, told apart by l_en and pend: idle (a_rdy high, waiting for a request), holding (l_en high,
// the lane has not yet taken the request) and pending (l_en low and pend high, the lane works on the burst). A request
// is not reordered or dropped, and one burst is outstanding at a time, which is what the arbiter expects (it does not
// ask again before the last beat).
//
// COST
// The request reaches the lane one clock later than without the relay, and a_rdy comes back one clock after the lane's
// rd_rdy, so each burst costs two more clk_dsp clocks. A burst of 180 words takes about 190 clocks, which means the
// lane's rate falls by about one percent.
//
// A request with burst length 0 is never taken by the lane (the lane only starts on a length of 1 or more), so l_en
// stays high and nothing more passes. No client sends such a request.

`timescale 1ns / 1ps

module ddr3_rd_relay (
    input  wire        clk,  // clk_dsp, 120 MHz; the relay and both sides of the handshake run on it
    input  wire        rst,  // synchronous reset, high = reset; the relay goes idle and a_rdy goes low until the first idle clock
    // arbiter side (the relay acts as the lane for the arbiter)
    input  wire [31:0] a_addr,  // word address of the request, 64-bit words
    input  wire [7:0]  a_burst,  // burst length in words, 1 to 255
    input  wire        a_en,  // the arbiter offers a request; taken in a clock with a_en high and a_rdy high
    output reg         a_rdy = 1'b0,  // high while the relay can take a request; low from the take until the whole burst is out of the lane
    // lane side (the relay acts as the arbiter for the lane)
    output reg  [31:0] l_addr = 32'd0,  // word address held for the lane
    output reg  [7:0]  l_burst = 8'd0,  // burst length held for the lane
    output reg         l_en = 1'b0,  // request to the lane, held high until the lane takes it
    output reg         l_go = 1'b0,  // one-clock pulse in the clock after the lane took the request
    input  wire        l_rdy  // from the lane (its rd_rdy): high = it takes a request now, low while it works on a burst
) /* synthesis syn_maxfan = 10000 */;

    reg  pend = 1'b0;                     // the lane has the request and is working on the burst
    // A request is taken in a clock with a_en high and a_rdy high; this wire is the arbiter's view of that.
    wire take = a_en && a_rdy;

    always @(posedge clk) begin
        // l_go is a pulse, so it falls back to 0 unless the branch below sets it again.
        l_go <= 1'b0;
        // The request registers follow the arbiter while nothing is held. Their enable is the register l_en and not
        // the long path from the clients' `req` signals; a_rdy high means l_en low, so the clock in which a request
        // is taken also loads them, and they stand still until the lane has taken the request.
        if (!l_en) begin
            l_addr  <= a_addr;
            l_burst <= a_burst;
        end
        // The state machine, one branch per state: take a request, hold it for the lane, wait for the end of the
        // burst, or (the last branch) become ready.
        if (take) begin
            l_en  <= 1'b1;
            a_rdy <= 1'b0;
        end else if (l_en) begin
            if (l_rdy) begin              // the lane takes the request at this edge
                l_en <= 1'b0;
                l_go <= 1'b1;
                pend <= 1'b1;
            end
        end else if (pend) begin
            if (l_rdy) begin              // burst finished: the lane is free again
                pend  <= 1'b0;
                a_rdy <= 1'b1;
            end
        // Idle: nothing held and nothing pending, so a_rdy goes high (this branch is also what raises it after reset).
        end else begin
            a_rdy <= 1'b1;
        end
        // Reset: back to idle; a_rdy stays low until the first clock after reset has passed.
        if (rst) begin
            l_en <= 1'b0; pend <= 1'b0; a_rdy <= 1'b0; l_go <= 1'b0;
        end
    end

endmodule
