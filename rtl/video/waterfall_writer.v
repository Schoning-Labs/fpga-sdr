// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// waterfall_writer: stores the lines of the waterfall display in a ring of lines in DDR3 memory, one line per spectrum line.
//
// WHAT A WATERFALL IS
// A spectrum display shows power against frequency for one moment. A waterfall shows the history: every new spectrum line
// is drawn as a row of colored pixels (the color says how strong the signal is in that frequency column), the newest row
// goes at the top, and older rows move down, so a steady carrier shows up as a vertical streak and a signal that comes and
// goes as a dashed one. Moving the whole picture down by one row for every new line would mean copying megabytes, so the
// rows are not moved. They are stored in a ring (a circular buffer): RING_LINES slots in memory, a write position that goes
// forward by one slot per new line and wraps from the last slot back to the first, and a number telling which slot was
// written last (`write_line_ptr`). To scroll, the display only has to start reading one slot further back, which is a
// register in the compositor (rtl/video/compositor.v) and costs nothing here.
//
// WHERE IT SITS
// The spectrum pipeline (rtl/spectrum/) delivers, once per spectrum line, 1,920 bytes (LINE_BYTES): one 8-bit color index
// per screen column, already scaled by the firmware's offset and gain (docs/ARCHITECTURE.md 3.3). This module packs them
// into 64-bit words, collects the words in a small FIFO and writes them in bursts through a client port of
// rtl/ddr3/ddr3_write_arbiter.v into the ring in DDR3. The compositor later reads the lines back (rtl/video/compositor_fetch.v)
// and looks each byte up in a 256-entry color palette to get the pixel. There are two instances in the radio, one for the
// full-band spectrum and one for the zoom spectrum, each with its own ring (docs/ARCHITECTURE.md 3.5, 3.9).
//
// HOW IT WORKS, STEP BY STEP
//   1. Bytes arrive with `in_valid` and `in_data`. Eight of them are collected in `pack_reg`, the first byte of a group ending
//      up in the top byte (bits 63:56) of the word, so the leftmost column of a line is the top byte of the line's first word.
//   2. Each completed 64-bit word goes into a FIFO of FIFO_WORDS words. The FIFO is built from LUT RAM (distributed RAM made
//      of the logic cells' lookup tables) because the write lane needs only a short queue and block RAM would be wasted.
//   3. As soon as the FIFO holds BURST_WORDS (8) words, a write burst is requested: `req` goes high with the DDR3 word
//      address `ring_base + word_off`, and `burstlen` is 8. The arbiter pulses `gnt` once for every word of the burst that it
//      takes, and this module offers the next FIFO word on `wdata` and steps to the following word on each `gnt`. When the
//      whole burst has landed the arbiter pulses `done`.
//   4. A line is 240 words (1,920 / 8), that is 30 bursts. After the 30th `done`, `write_line_ptr` is set to the number of
//      the line just finished (so a reader that looks at `write_line_ptr` never sees a half written line as the newest one)
//      and writing goes on in the next ring slot. After the last slot of the ring it goes back to the first.
//
// SIZES AND NUMBERS: a line of 1,920 bytes is 240 words of 8 bytes, a ring of 2,048 lines is 491,520 words, which is
// 3,932,160 bytes (about 3.9 MB). `ring_base` and `addr` count words of the 64-bit lane, not bytes. The spectrum pipeline
// delivers one line every 1/30 to 1/60 of a second, which is a data rate of about 0.1 MB/s for each instance, much less than
// the write lane can take, so `in_ready` should never actually go low. It exists for correctness when the lane stalls, as
// the lane model in sim/ddr3/ddr3_lane_behav_model.v makes it do at random.
//
// LIMITS: LINE_BYTES must be a multiple of 8, because a partial last word is never written out (both instances use 1,920).
// RING_LINES must be a power of 2. Latency: a line shows up in `write_line_ptr` about one burst (8 beats plus the lane's
// own delay) after its last byte arrives, and bytes flow in at most one per clock.

`timescale 1ns / 1ps

module waterfall_writer #(
    parameter integer ADDR_WIDTH  = 32,  // width of `addr`, in bits of lane-word address
    parameter integer DATA_WIDTH  = 64,  // width of the DDR3 write lane in bits (one word)
    parameter integer MASK_WIDTH  = DATA_WIDTH / 8,  // byte enables per word, one per 8 data bits
    parameter integer LINE_BYTES  = 1920,           // one line = one byte per screen column; must be a multiple of MASK_WIDTH (8)
    parameter integer RING_LINES  = 2048,           // lines in the ring; must be a power of 2 (2,048 lines x 1,920 bytes = 3.9 MB)
    parameter integer FIFO_WORDS  = 64              // packing FIFO depth, in 64-bit words
) (
    input  wire                    clk,  // clock, clk_dsp (120 MHz)
    input  wire                    rst,  // synchronous reset, high = reset

    // -------- byte stream from the spectrum pipeline (docs/ARCHITECTURE.md 3.3) --------
    input  wire                    in_valid,  // one byte offered this clock (a byte is taken when in_valid and in_ready are both high)
    input  wire [7:0]              in_data,  // color index of one screen column, 0 to 255, left to right within a line
    output wire                    in_ready,  // high while the FIFO has room; goes low only when the FIFO is completely full

    // -------- ring configuration and position (plain ports, wired to the register block by the core, see
    // docs/ARCHITECTURE.md 4.1; the same style as ring_base and wr_ptr of rtl/audio/audio_ring_reader.v) --------
    input  wire [ADDR_WIDTH-1:0]   ring_base,       // DDR3 lane-word address where ring line 0 begins (set by firmware, needs to be steady while the writer runs)
    output reg  [$clog2(RING_LINES)-1:0] write_line_ptr, // number of the ring slot (0 to RING_LINES-1) of the last completely written line

    // -------- write-lane arbiter client port (the convention of rtl/ddr3/ddr3_write_arbiter.v) -------
    output reg                     req,  // high from the start of a burst request until `done`
    output reg  [ADDR_WIDTH-1:0]   addr,  // lane-word address of the burst's first word, held until `done`
    output wire [7:0]              burstlen,  // words in the burst, always 8
    output wire [DATA_WIDTH-1:0]   wdata,  // the current beat's data, the FIFO's oldest word
    output wire [MASK_WIDTH-1:0]   wmask,  // byte enables of the current beat, all ones (every byte is written)
    input  wire                    gnt,  // one-clock pulse for every beat the arbiter took
    input  wire                    done  // one-clock pulse when the whole burst has landed
);

    localparam integer WORDS_PER_LINE  = LINE_BYTES / MASK_WIDTH; // 1920 / 8 = 240 words in a line
    localparam integer BURST_WORDS     = 8;                       // words per burst (64 bytes)
    localparam integer BURSTS_PER_LINE = WORDS_PER_LINE / BURST_WORDS; // 240 / 8 = 30 bursts in a line
    localparam integer LINE_BITS       = $clog2(RING_LINES);
    localparam integer FIFO_BITS       = $clog2(FIFO_WORDS);

    // ---------------- byte packer: 8 bytes in -> 1 lane word into the FIFO ----------------
    // pack_reg shifts left by one byte for every byte taken, so after 8 bytes the first one sits in bits 63:56.
    // pack_cnt counts the bytes of the word being collected, 0 to 7. When the 8th byte arrives (pack_cnt = 7) the word
    // is complete and written to the FIFO in the same clock, taken directly from {pack_reg[55:0], in_data}.
    reg [63:0] pack_reg;
    reg [2:0]  pack_cnt;
    wire       pack_word_ready = (pack_cnt == 3'd7) && in_valid && in_ready;

    // The packing FIFO is a ring of FIFO_WORDS words in LUT RAM. fifo_wptr and fifo_rptr are its write and read positions,
    // fifo_count how many words it holds (one bit wider than the pointers, so that it can say "64", i.e. full).
    (* syn_ramstyle = "distributed_ram" *) reg [DATA_WIDTH-1:0] fifo_mem [0:FIFO_WORDS-1];
    reg [FIFO_BITS-1:0]  fifo_wptr, fifo_rptr;
    reg [FIFO_BITS:0]    fifo_count; // one extra bit: needs to represent FIFO_WORDS (full)
    reg                  rd_pop;     // set by the drain-side state machine below  // one-clock pulse from the drain side: one word has been taken by the lane

    wire fifo_full  = (fifo_count == FIFO_WORDS);
    wire fifo_empty = (fifo_count == 0);
    // in_ready is high while the FIFO is not completely full. A byte is then always safe to take, because the byte that
    // completes a word needs one free FIFO slot and at least one exists.
    assign in_ready = !fifo_full;

    // Packer and FIFO write side. The count goes up when a word is written and down when the drain side pops one; when
    // both happen in the same clock the count stays as it is.
    always @(posedge clk) begin
        if (rst) begin
            pack_reg   <= 64'd0;
            pack_cnt   <= 3'd0;
            fifo_wptr  <= {FIFO_BITS{1'b0}};
            fifo_count <= {(FIFO_BITS+1){1'b0}};
        end else begin
            if (in_valid && in_ready) begin
                pack_reg <= {pack_reg[55:0], in_data};
                if (pack_cnt == 3'd7) begin
                    pack_cnt <= 3'd0;
                end else begin
                    pack_cnt <= pack_cnt + 3'd1;
                end
            end
            if (pack_word_ready) begin
                fifo_mem[fifo_wptr] <= {pack_reg[55:0], in_data};
                fifo_wptr  <= fifo_wptr + 1'b1;
                if (!(rd_pop)) fifo_count <= fifo_count + 1'b1;
            end else if (rd_pop) begin
                fifo_count <= fifo_count - 1'b1;
            end
        end
    end

    // ---------------- drain side: burst the FIFO out to the write lane ----------------
    // Two states: WAIT_BURST (idle until the FIFO holds a whole burst, then raise `req`) and IN_BURST (hold `req` and
    // advance the FIFO read pointer on every `gnt` until `done`).
    localparam WAIT_BURST = 1'b0, IN_BURST = 1'b1;
    reg                       dstate;
    // number of the burst within the current line, 0 to 29
    reg [$clog2(BURSTS_PER_LINE+1)-1:0] burst_idx;
    reg [LINE_BITS-1:0]       cur_line; // ring slot being filled now (not yet complete)
    // Word offset of the next burst from ring_base, that is cur_line * WORDS_PER_LINE + burst_idx * BURST_WORDS. It is kept
    // as a running sum (it grows by BURST_WORDS per burst and goes back to 0 after the last line of the ring) instead of
    // being multiplied out each time, so that no multiplier sits in front of the 32-bit address add.
    // words in the whole ring (2,048 x 240 = 491,520) and the bits needed to count them
    localparam integer RING_WORDS = RING_LINES * WORDS_PER_LINE;
    localparam integer OFF_BITS   = $clog2(RING_WORDS);
    reg [OFF_BITS-1:0]        word_off;

    // Constant outputs: 8 words per burst, every byte enabled, and the FIFO's oldest word on the data bus (the FIFO is
    // read combinationally, the read pointer moves when the arbiter says `gnt`).
    assign burstlen = BURST_WORDS[7:0];
    assign wmask    = {MASK_WIDTH{1'b1}};
    assign wdata    = fifo_mem[fifo_rptr];

    // Drain state machine. rd_pop is a pulse that defaults to 0 and is set for one clock per beat taken.
    always @(posedge clk) begin
        rd_pop <= 1'b0;
        if (rst) begin
            dstate         <= WAIT_BURST;
            req            <= 1'b0;
            addr           <= {ADDR_WIDTH{1'b0}};
            burst_idx      <= 0;
            cur_line       <= {LINE_BITS{1'b0}};
            word_off       <= {OFF_BITS{1'b0}};
            fifo_rptr      <= {FIFO_BITS{1'b0}};
            write_line_ptr <= (RING_LINES - 1); // "last written" = none yet (wraps to valid on first completion)
        end else begin
            case (dstate)
                WAIT_BURST: begin
                    if (fifo_count >= BURST_WORDS) begin
                        req  <= 1'b1;
                        addr <= ring_base + word_off;
                        dstate <= IN_BURST;
                    end
                end
                IN_BURST: begin
                    if (gnt) begin
                        fifo_rptr <= fifo_rptr + 1'b1;
                        rd_pop    <= 1'b1;
                    end
                    if (done) begin
                        req <= 1'b0;
                        dstate <= WAIT_BURST;
                        word_off <= (word_off == RING_WORDS - BURST_WORDS) ? {OFF_BITS{1'b0}}
                                                                           : word_off + BURST_WORDS[OFF_BITS-1:0];
                        // last burst of the line: the line is complete, publish its number and go on with the next slot
                        if (burst_idx + 1 == BURSTS_PER_LINE) begin
                            burst_idx      <= 0;
                            write_line_ptr <= cur_line; // this line is now fully written
                            cur_line       <= (cur_line == RING_LINES - 1) ? {LINE_BITS{1'b0}} : cur_line + 1'b1;
                        end else begin
                            burst_idx <= burst_idx + 1'b1;
                        end
                    end
                end
            endcase
        end
    end

endmodule
