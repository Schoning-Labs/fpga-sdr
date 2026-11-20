// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Behavioral model of the two fabric-side DDR3 lanes of the AE350 SoC, the write lane and the read lane,
// used only in simulation (it cannot be turned into hardware). The ports follow Gowin MUG1031 section 5,
// table 5-1, where the write lane signals end in _lane4 and the read lane signals end in _lane5.
//
// On the real board the DDR3 controller belongs to the CPU subsystem, and the fabric gets two lanes into
// it ("Shared DDR3: Logic R/W Mode"): one carries writes and one carries reads, each 64 bits wide at the
// 100 MHz fabric clock, which is 800 MB/s per lane at most. A lane works in bursts, because DDR3 memory
// pays a fixed setup time for every request (opening a row, waiting for the first data to come back), so
// a client gives one start address and one count and the words then follow one per clock. Several
// clients want the same lane, which is why rtl/ddr3/ddr3_write_arbiter.v and ddr3_read_arbiter.v sit in
// front of it and decide who goes next. This model is what those arbiters talk to in their testbenches.
//
// Both lanes are backed by one word-addressable array (`mem`), the way the real die is one physical memory
// behind both lanes and behind the CPU's own data path, so a testbench can write through the write lane and
// read the same address back through the read lane, or look at the array directly with `peek` and fill it
// with `poke`. An address counts 64-bit words, not bytes.
//
// What the model simplifies compared with the real part (the reasoning is in docs/F4_DDR.md section 2,
// which is worth reading before trusting a number that comes out of a run):
//
//  1. A burst that has been granted always finishes at one beat per clock. Only the wait for a new burst
//     to be accepted is subject to the random stalls described below. The question the arbiters have to
//     answer is how long the shared controller can hold off the video reader, which is an acceptance
//     latency and not a mid-burst throughput, and it is also why a client should keep its own bursts short:
//     the burstcount field is 8 bits wide (up to 255 words), a burst already running is never pre-empted,
//     and so the length of the longest lower-priority burst is the worst delay the next higher-priority
//     client can ever see.
//  2. Table 5-1 shows the write mask only as 4 bits wide (one bit per byte of the 32-bit configuration) and
//     does not spell out the 64-bit configuration this design uses, so the model assumes the natural
//     extension, an 8-bit mask with one bit per byte of the 64-bit word.
//  3. There are no banks, rows, refresh cycles, calibration or ECC. Reads have one fixed latency
//     (RD_LATENCY clocks from acceptance to the first beat) and only one read burst is in flight at a
//     time, `rd_rdy_lane5` stays low until it has finished. The wr_go_lane4 and rd_go_lane5 inputs exist
//     so the ports match the table, but they are not used.
//
// Random stalls: `phys_busy` goes high for a random run of clocks, which stands for the CPU winning the
// physical bus now and then. On every idle clock a run starts with probability STALL_NUM/STALL_DEN, and
// the run lasts between 1 and STALL_MAX_CYCLES clocks. The random numbers come from a xorshift32
// generator started from SEED, so a regression run gives the same result every time. While `phys_busy` is
// high neither lane accepts a new burst (`wr_wait_lane4` is forced high and `rd_rdy_lane5` is forced low),
// and since the two lanes share one die they share the one `phys_busy` signal.

`timescale 1ns / 1ps

module ddr3_lane_behav_model #(
    // ADDR_WIDTH and DATA_WIDTH follow the lanes (64 bits of data per beat). MASK_WIDTH is one mask bit per
    // data byte. MEM_WORDS is the size of the backing array in words and has to cover every address a
    // testbench uses, because the address is cut to its low bits and a larger one wraps onto a smaller one.
    parameter integer ADDR_WIDTH     = 32,
    parameter integer DATA_WIDTH     = 64,
    parameter integer MASK_WIDTH     = DATA_WIDTH / 8,
    parameter integer MEM_WORDS      = 65536,
    parameter integer RD_LATENCY     = 6,     // clocks from a read burst's grant to its first beat
    parameter integer STALL_NUM      = 0,     // probability per idle clock that a stall run starts
    parameter integer STALL_DEN      = 1000,  // = STALL_NUM / STALL_DEN; 0/anything = no stalls
    parameter integer STALL_MAX_CYCLES = 1,   // longest single stall run, clocks
    parameter integer SEED           = 32'hF00D_D00D,
    // Lane clock throttle. When BEAT_SKIP is larger than 0 no data beat (read or write) happens on every
    // BEAT_SKIP-th clock, which models a lane clock that is slower than the testbench clock: with
    // BEAT_SKIP = N the lane moves N-1 beats per N clocks. The value 3 gives 2 beats per 3 clocks, which
    // is the 100 MHz fabric lane clock seen from a 150 MHz engine clock, 800 MB/s at 8 bytes per beat
    // (a 120 MHz engine clock would need 6, giving 5 beats per 6 clocks). 0 switches the throttle off.
    parameter integer BEAT_SKIP      = 0
) (
    input  wire                    clk,
    input  wire                    rst,

    // -------- write lane (lane4) --------
    // Write request: `addr_lane4` is the first word, `burstcount_lane4` the number of words, and while
    // `wr_en_lane4` is high the lane takes one beat of `wr_data_lane4` per clock whenever `wr_wait_lane4`
    // is low. `wr_mask_lane4` has one bit per byte, a 1 lets that byte be written. `wr_done_lane4` is a
    // one-clock pulse on the clock the last beat of the burst is accepted.
    input  wire [ADDR_WIDTH-1:0]   addr_lane4,
    input  wire [MASK_WIDTH-1:0]   wr_mask_lane4,
    input  wire [DATA_WIDTH-1:0]   wr_data_lane4,
    input  wire                    wr_en_lane4,
    input  wire                    wr_go_lane4,
    input  wire [7:0]              burstcount_lane4,
    output wire                    wr_wait_lane4,
    output reg                     wr_done_lane4,

    // -------- read lane (lane5) --------
    // Read request: `rd_en_lane5` together with `rd_rdy_lane5` starts a burst of `burstcount_lane5` words at
    // `addr_lane5`. After the fixed latency the data comes back as one `rd_valid_lane5` pulse per beat on
    // `rd_data_lane5`, one beat per clock. `rd_rdy_lane5` is high when the lane is free for a new request.
    input  wire [ADDR_WIDTH-1:0]   addr_lane5,
    input  wire                    rd_en_lane5,
    input  wire                    rd_go_lane5,
    input  wire [7:0]              burstcount_lane5,
    output reg                     rd_valid_lane5,
    output reg  [DATA_WIDTH-1:0]   rd_data_lane5,
    output wire                    rd_rdy_lane5,

    // High while a stall run is active, brought out so a testbench can count the stalled clocks.
    // instrumentation
    output reg                     phys_busy
);

    // The backing memory shared by both lanes, one 64-bit word per entry.
    reg [DATA_WIDTH-1:0] mem [0:MEM_WORDS-1];
    localparam integer WORD_BITS = $clog2(MEM_WORDS);

    // ---------------- shared random-stall generator ----------------
    // Stall generator state: clocks left in the current run, and the random number generator.
    integer stall_run_left;
    reg [31:0] rng;

        // One step of the generator, a xorshift32 (shift left 13, right 17, left 5, each time xored in).
        // It only uses shifts and xors, so it gives the same sequence on every simulator.
    function [31:0] next_rng(input [31:0] x);
        // xorshift32; deterministic given SEED, portable across iverilog/verilator
        reg [31:0] v;
        begin
            v = x;
            v = v ^ (v << 13);
            v = v ^ (v >> 17);
            v = v ^ (v << 5);
            next_rng = v;
        end
    endfunction

    // Per clock: while a run is active count it down and hold `phys_busy` high. On an idle clock draw a
    // random number, start a run with probability STALL_NUM/STALL_DEN and give it a length of 1 to
    // STALL_MAX_CYCLES clocks. The modulo of the same random number is used for the chance and for the
    // length, which is good enough for a stall model.
    always @(posedge clk) begin
        if (rst) begin
            rng             <= SEED;
            stall_run_left  <= 0;
            phys_busy       <= 1'b0;
        end else begin
            rng <= next_rng(rng);
            if (stall_run_left > 0) begin
                stall_run_left <= stall_run_left - 1;
                phys_busy      <= 1'b1;
            end else if (STALL_NUM > 0 && (rng % STALL_DEN) < STALL_NUM) begin
                stall_run_left <= (STALL_MAX_CYCLES <= 1) ? 0 : (rng % STALL_MAX_CYCLES);
                phys_busy      <= 1'b1;
            end else begin
                phys_busy      <= 1'b0;
            end
        end
    end

    // BEAT_SKIP counter, it counts 0 up to BEAT_SKIP-1 and `skip_now` marks the one clock in each round
    // on which no data beat is allowed.
    // ---------------- lane clock throttle (BEAT_SKIP) ----------------
    reg  [7:0] skip_cnt;
    wire       skip_now = (BEAT_SKIP > 0) && (skip_cnt == BEAT_SKIP - 1);
    always @(posedge clk) begin
        if (rst || BEAT_SKIP == 0 || skip_now) skip_cnt <= 8'd0;
        else                                   skip_cnt <= skip_cnt + 8'd1;
    end

    // ---------------- write lane ----------------
    // `w_busy` is high while a burst is in progress after its first beat, `w_beat_idx` is the number of
    // beats of the current burst already written.
    reg        w_busy;
    reg [7:0]  w_beat_idx;
    // A stall only ever blocks the first beat of a new burst (`w_busy` low), once a burst is under way it
    // runs to the end at one beat per clock, as the module header says. The throttle blocks any beat.
    assign wr_wait_lane4 = (phys_busy && !w_busy) || skip_now;

    integer bi;
    reg [ADDR_WIDTH-1:0] w_eff_addr;
    // The word written by this beat, the burst's start address plus the beat number.
    always @* w_eff_addr = addr_lane4 + w_beat_idx;

    // Write beat: on every accepted clock each mask bit that is set copies its byte of `wr_data_lane4`
    // into the array. The last beat (beat number plus one reaches the burst count) pulses `wr_done_lane4`
    // and clears the burst state, any earlier beat keeps `w_busy` high and moves on to the next word.
    always @(posedge clk) begin
        wr_done_lane4 <= 1'b0;
        if (rst) begin
            w_busy     <= 1'b0;
            w_beat_idx <= 8'd0;
        end else if (wr_en_lane4 && !wr_wait_lane4) begin
            for (bi = 0; bi < MASK_WIDTH; bi = bi + 1) begin
                if (wr_mask_lane4[bi]) begin
                    mem[w_eff_addr[WORD_BITS-1:0]][bi*8 +: 8] <= wr_data_lane4[bi*8 +: 8];
                end
            end
            if (w_beat_idx + 8'd1 >= burstcount_lane4) begin
                wr_done_lane4 <= 1'b1;
                w_busy        <= 1'b0;
                w_beat_idx    <= 8'd0;
            end else begin
                w_busy        <= 1'b1;
                w_beat_idx    <= w_beat_idx + 8'd1;
            end
        end
    end

    // ---------------- read lane ----------------
    // Read burst state: `r_pending` is high while the fixed latency counts down (`r_wait_cnt`), `r_busy`
    // stays high until the last beat has been issued, `r_base` and `r_burstlen` hold the accepted request.
    reg                   r_busy;
    reg [ADDR_WIDTH-1:0]  r_base;
    reg [7:0]             r_burstlen, r_beat_idx;
    reg [$clog2(RD_LATENCY+1)-1:0] r_wait_cnt;
    reg                   r_pending; // accepted, counting down RD_LATENCY before first beat
    // Address of the beat after the one currently being delivered.
    wire [ADDR_WIDTH-1:0] r_next_beat_addr = r_base + r_beat_idx + 8'd1;

    // The lane is free when no burst is running and no stall is active.
    assign rd_rdy_lane5 = !r_busy && !phys_busy;

    // Read: accepting a request latches address and length and starts the latency countdown. When it
    // reaches zero the first word is delivered, and each following clock delivers the next word until the
    // burst length is used up. A clock that the throttle skips delivers nothing and counts nothing.
    always @(posedge clk) begin
        rd_valid_lane5 <= 1'b0;
        if (rst) begin
            r_busy     <= 1'b0;
            r_pending  <= 1'b0;
            r_beat_idx <= 8'd0;
            r_wait_cnt <= 0;
        end else begin
            if (rd_en_lane5 && rd_rdy_lane5) begin
                r_base     <= addr_lane5;
                r_burstlen <= burstcount_lane5;
                r_beat_idx <= 8'd0;
                r_busy     <= 1'b1;
                r_pending  <= 1'b1;
                r_wait_cnt <= RD_LATENCY[$clog2(RD_LATENCY+1)-1:0];
            end else if (skip_now) begin
                // lane clock throttle: no beat this clock
            end else if (r_pending) begin
                if (r_wait_cnt == 0) begin
                    r_pending      <= 1'b0;
                    rd_valid_lane5 <= 1'b1;
                    rd_data_lane5  <= mem[r_base[WORD_BITS-1:0]];
                    if (r_burstlen <= 8'd1) r_busy <= 1'b0;
                end else begin
                    r_wait_cnt <= r_wait_cnt - 1'b1;
                end
            end else if (r_busy) begin
                // streaming the remaining beats, one per clock
                rd_valid_lane5 <= 1'b1;
                rd_data_lane5  <= mem[r_next_beat_addr[WORD_BITS-1:0]];
                if (r_beat_idx + 8'd2 >= r_burstlen) begin
                    r_busy <= 1'b0;
                end
                r_beat_idx <= r_beat_idx + 8'd1;
            end
        end
    end

    // Testbench back door: `poke` writes a word straight into the array and `peek` reads one, both without
    // going through either lane and without costing any clocks.
    // ---------------- testbench helpers ----------------
    task poke(input [ADDR_WIDTH-1:0] addr, input [DATA_WIDTH-1:0] data);
        begin
            mem[addr[WORD_BITS-1:0]] = data;
        end
    endtask

    function [DATA_WIDTH-1:0] peek(input [ADDR_WIDTH-1:0] addr);
        begin
            peek = mem[addr[WORD_BITS-1:0]];
        end
    endfunction

endmodule
