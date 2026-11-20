// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ddr3_wr_relay: one register stage in the DDR3 write lane, between the write arbiter (rtl/ddr3/ddr3_write_arbiter.v)
// and the write lane of the memory bridge (module ddr_mem_wrlane in rtl/mem/ddr_mem.v).
//
// WHERE IT SITS
// The radio keeps its bulk data (receiver IQ blocks, waterfall lines, FT8 slots) in the board's DDR3 memory, and
// everything that writes there goes through the one write lane, which is called lane 4 after the signal names of the
// AE350 manual (the read lane is lane 5). The chain for a write is: a client block (receiver back end, waterfall
// writer, zoom waterfall writer, FT8 front end) -> ddr3_write_arbiter, which lets one client at a time use the lane
// -> this relay -> ddr_mem_wrlane, which hands the word over to the memory controller -> DDR3 chips. Everything up to
// and including ddr_mem_wrlane runs on clk_dsp (120 MHz); the controller has its own 75 MHz clock, and the crossing
// between the two is done inside ddr_mem.v. The read lane has a similar register stage, rtl/ddr3/ddr3_rd_relay.v. A
// lane handshake means a request is raised, held until the other side takes it, and then answered, and the exact
// signals of the write lane are described in the header of rtl/mem/ddr_mem.v. Terms like burst, beat and lane are in
// docs/learn/GLOSSARY.md.
//
// WHY IT EXISTS
// Without the relay the arbiter would forward the owning client's address, data and mask to the lane through a pure
// multiplexer, and would hand the lane's wait and done signals back to the client through another one. The lane sits
// close to the DDR3 pins and the clients are spread over the whole chip, so each of those two directions was one long
// combinational path, a client's request through the arbiter's choice of owner into the lane's address adder, and the
// lane's answer back through the arbiter to the client. At 120 MHz a clock lasts only 8.3 ns, which those paths could
// not meet. A register stage in the middle cuts each of them in two and costs a few clocks, which a lane with a very
// light load does not notice.
//
// HOW IT WORKS, STEP BY STEP
// It speaks the lane handshake on both sides.
//   towards the arbiter  it acts as the lane: a beat (one 64-bit word with its byte mask) is taken in a clock in which
//                        a_en is high and a_wait is low. From then on a_wait stays high until the lane has that word
//                        inside the memory controller. a_done is high for one clock after the last word of a burst,
//                        and a_wait is high in that same clock.
//   towards the lane     it acts as the arbiter: the beat it took stands in the l_* registers with l_en high until
//                        the lane takes it, which the lane shows by l_wait being low. l_addr and l_burst are the
//                        ones that came with the beat, and the lane reads them with the first beat of a burst only.
// Three states cover it, told apart by l_en and pend: idle (a_wait low, waiting for a beat), holding (l_en high, the
// lane has not yet taken the word) and pending (l_en low and pend high, the lane has the word and works on it).
// Every word passes, in order, and none is dropped or reordered. A burst is simply a series of beats that each go
// through the three states in turn.
//
// COST
// Two to three clk_dsp clocks more per 64-bit word. A word already costs on the order of ten clocks, because the
// lane sends a toggle over to the controller's 75 MHz domain and waits for the toggle that comes back, so the lane's
// top rate falls by roughly a fifth. That does not matter here, since the clients on the write lane (receiver rings,
// waterfalls, FT8 capture) need only about 26 MB/s together (docs/F4_DDR.md).
//
// a_go is the arbiter's start-of-burst pulse. The memory bridge of the default build ignores it, because its lane
// starts a burst with the first beat; the AE350's own lane in the 256 MB fall-back build (compiled with TR_DDR_256)
// does use it. The relay passes it on one clock later, in l_go.

`timescale 1ns / 1ps

module ddr3_wr_relay (
    input  wire        clk,  // clk_dsp, 120 MHz; the relay and both sides of the handshake run on it
    input  wire        rst,  // synchronous reset, high = reset; the relay goes idle and a_wait goes high
    // arbiter side (the relay acts as the lane for the arbiter)
    input  wire [31:0] a_addr,  // word address of the beat, 64-bit words; the lane reads it with the first beat of a burst
    input  wire [7:0]  a_mask,  // byte mask of the beat, bit i = 1 writes byte i of the 64-bit word
    input  wire [63:0] a_data,  // data of the beat, 64 bits
    input  wire        a_en,  // the arbiter offers a beat; taken in a clock with a_en high and a_wait low
    input  wire        a_go,  // start-of-burst pulse from the arbiter; passed on in l_go one clock later
    input  wire [7:0]  a_burst,  // burst length in words (the lane treats 0 as 1); the lane reads it with the first beat
    output reg         a_wait = 1'b1,  // high while the relay cannot take a beat; high from reset on, low when idle
    output reg         a_done = 1'b0,  // one-clock pulse after the last word of a burst has gone in; a_wait is high in that clock
    // lane side (the relay acts as the arbiter for the lane)
    output reg  [31:0] l_addr = 32'd0,  // word address held for the lane
    output reg  [7:0]  l_mask = 8'd0,  // byte mask held for the lane
    output reg  [63:0] l_data = 64'd0,  // data word held for the lane
    output reg         l_en = 1'b0,  // request to the lane, held high until the lane takes the beat
    output reg         l_go = 1'b0,  // one-clock start-of-burst pulse, a_go delayed by one clock
    output reg  [7:0]  l_burst = 8'd0,  // burst length held for the lane
    input  wire        l_wait,  // from the lane: high while it cannot take a beat; low with l_en high = beat taken
    input  wire        l_done  // from the lane: one-clock pulse after the last word of a burst is in the memory controller
) /* synthesis syn_maxfan = 10000 */;

    reg  pend = 1'b0;                     // the lane has taken the beat and is working on it; the relay waits for
                                          // the lane's wait or done signal
    // A beat is taken in a clock with a_en high and a_wait low; this wire is the arbiter's view of that.
    wire take = a_en && !a_wait;

    always @(posedge clk) begin
        // a_done is a pulse, so it falls back to 0 unless the last-word branch below sets it again.
        a_done <= 1'b0;
        // The start-of-burst pulse is simply delayed by one clock.
        l_go   <= a_go;
        // The beat registers follow the arbiter while no beat is held. Their enable is the register l_en and not
        // `take`, because `take` would come through the arbiter's choice of owner from the clients' `req` signals
        // and then fan out to the enables of well over a hundred registers (64 data, 8 mask, 32 address and 8 burst bits),
        // which is a long net. A beat is only taken while l_en is low (a_wait is low only then), so the clock that takes it
        // also loads the registers, and they stand still until the lane has taken the beat.
        if (!l_en) begin
            l_addr  <= a_addr;
            l_burst <= a_burst;
            l_data  <= a_data;
            l_mask  <= a_mask;
        end
        // The state machine, one branch per state: take a beat, hold it for the lane, wait for the lane's answer,
        // or (the last branch) stay ready.
        if (take) begin
            l_en    <= 1'b1;
            a_wait  <= 1'b1;
        end else if (l_en) begin
            if (!l_wait) begin            // the lane takes the beat at this edge
                l_en <= 1'b0;
                pend <= 1'b1;
            end
        end else if (pend) begin
            if (l_done) begin             // last word of the burst: a_wait stays high this clock
                a_done <= 1'b1;
                pend   <= 1'b0;
            end else if (!l_wait) begin   // word is in, more to come
                a_wait <= 1'b0;
                pend   <= 1'b0;
            end
        // Idle: nothing held and nothing pending, so the relay is ready for the next beat.
        end else begin
            a_wait <= 1'b0;
        end
        // Reset: back to idle, with a_wait high so that no client can start a beat before the lane is ready.
        if (rst) begin
            l_en <= 1'b0; pend <= 1'b0; a_wait <= 1'b1; a_done <= 1'b0; l_go <= 1'b0;
        end
    end

endmodule
