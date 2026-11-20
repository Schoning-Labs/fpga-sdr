// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// ddr_mem: the bridge between Gowin's DDR3 Memory Interface IP and the three blocks that want to use the board's
// memory: the AE350 CPU's data bus and the radio's two lanes (a write lane and a read lane). The design is the
// memory bridge of an earlier design by the same author, adapted here for the radio's lanes.
//
// WHERE IT SITS
// The board carries two DDR3 chips (two 4 Gbit x16 chips, 32 data lines, 1 GB in all). Gowin's DDR3 Memory Interface IP
// (IPUG281-2.6E, set up with hw/gowin/mem/gwmc_param.v for 32 data lines and 15 row lines) is a block in the logic
// that drives the DDR3 pins and does all the hard timing work of the memory itself. This file is the layer between
// the IP's user interface and the rest of the chip, and the three clients that it joins are:
//
//   ddr_mem_ahb     the AE350's "customized data memory" bus (MUG1031-1.3.1E 8.2.3; AHB-Lite, 64 data lines,
//                  0x0000_0000 up; the 1 GB repeats above 0x4000_0000). The firmware's code, data, heap and frame
//                  buffers all live in the memory through this port.
//   ddr_mem_rdlane  the read lane of the logic  (rtl/ddr3/ddr3_read_arbiter.v: video, audio ring, TX ring, FT8)
//   ddr_mem_wrlane  the write lane of the logic (rtl/ddr3/ddr3_write_arbiter.v: receiver rings, waterfall, FT8)
//
//   (AE350 bus)  --> ddr_mem_ahb  --\
//   (read lane)  --> ddr_mem_rdlane --+--> ddr_mem_core --> DDR3 IP --> DDR3 pins --> two DDR3 chips
//   (write lane) --> ddr_mem_wrlane --/        (each client has a toggle-and-held-data crossing into the core,
//                                              and read data comes back through two Gray-coded FIFOs)
//
// DDR3 IN A NUTSHELL (what a beginner needs to read this file; more terms in docs/learn/GLOSSARY.md)
//   - A DDR3 chip stores bits in banks (8 per chip), and each bank is a grid of rows and columns (here 32,768 rows
//     by 1,024 columns, each cell holding one 32-bit word because the two 16-bit chips work side by side). To read or write, the controller first opens a row of a bank
//     (activate), then reads or writes the columns of that open row, and finally closes the row (precharge). Opening
//     and closing take time, so the memory is fast only when many words come from the same open row. The memory also
//     needs a refresh of all its rows every few microseconds (every 7.8 us, which takes about 260 ns each time), which
//     the IP schedules by itself.
//   - Words move in bursts: one read or write command moves a fixed 8 words in a row, and each word is as wide as the
//     data bus (32 bits here), so one DDR3 burst is 8 x 32 bits = 32 bytes. This file calls such a unit a line.
//   - DDR means double data rate: data is sent on both edges of the memory clock. The memory clock is 300 MHz, so each
//     data pin carries 600 million bits per second, and the 32 pins together carry up to 2.4 GB/s when the memory is
//     busy all the time. The chips are rated for 400 MHz, but the board runs them at 300 MHz because reads that
//     overlapped were lost or corrupted at 400 MHz whenever a lot of logic on the chip switched at once.
//   - The IP is the controller: it runs the start-up sequence, calibrates the read timing (it finds out at what
//     delay the data pins must be sampled, which `init` reports as done), sends the activate, read, write, precharge
//     and refresh commands in the right order and with the right gaps, and offers the logic a simple command
//     interface on its own clock, clk_out. clk_out is the memory clock divided by 4, so 75 MHz (the ratio is "1:4"), and
//     one 8-word burst fills exactly one clk_out clock. In the constraints that clock is called ddr3_sys.
//
// THE CLOCK DOMAINS, AND HOW THEY ARE CROSSED
// Three clocks meet here, and none is related to the other two (the constraint file puts them in asynchronous groups):
//   clk_m (the IP's clk_out, 75 MHz)  runs ddr_mem_core and the write side of the two read FIFOs
//   hclk (the AE350's data-memory bus clock, the "DDR bus" clock of the CPU, 50 MHz) runs ddr_mem_ahb
//   lane_clk (clk_dsp, 120 MHz)       runs ddr_mem_rdlane and ddr_mem_wrlane, the 64-bit lanes of the radio
// Every crossing is one of two kinds. A request crossing is a toggle with held data: the sender puts its data in
// registers and holds them still, flips one bit (the toggle), and the receiving side passes that bit through a chain
// of flip-flops (a synchronizer, three here) and treats any change of it as "a request is waiting", reading the
// held data when it sees one; the answer comes back the same way with a second toggle. Read data crosses the
// other way through ddr_mem_afifo, a 16-entry first-in-first-out memory with Gray-coded pointers (a code in which only
// one bit changes at a time, so a pointer sampled in the middle of a change is never wrong by more than one step).
//
// THE LANES' HANDSHAKE
// The lanes keep the signal names of the AE350's own "Shared DDR3" lanes 4 and 5, which the arbiters were written for.
// The handshake is defined here, and it is the one sim/ddr3/ddr3_lane_behav_model.v models (checked signal by signal in
// docs/MEM_1GB.md section 3):
//   read lane   addr (64-bit word address), burstcount (1..255 words) and rd_en are held until a clock in
//               which rd_rdy is high; then burstcount rd_valid beats follow, one 64-bit word each, in
//               address order, and rd_rdy stays low until the last beat is out. rd_go is not used.
//   write lane  a beat is taken in every clock with wr_en high and wr_wait low. The first beat taken after
//               a burst has ended starts a burst: addr (64-bit word address) and burstcount (0 counts as 1)
//               are read in that clock; the following beats go to the following words. wr_mask bit i = 1
//               writes byte i of the word. wr_wait is high from a beat until that word is in the memory
//               controller, so a burst runs at one word per memory write. wr_done is high for one clock
//               after the last word of the burst is in the controller (wr_wait is high in that clock).
//               wr_go is not used.
//
// HOW A WORD FINDS ITS PLACE IN THE MEMORY
// One DDR3 line is 8 x 32 bits = 32 bytes (IPUG281 4.4.5: one read or write occupies 8 addresses). The user address of
// the IP is {rank 0, line number (25 bits), 3'b000}: 29 bits, of which the low three are zero because a burst occupies
// eight column addresses, and 25 bits of line number cover 2^25 lines x 32 bytes = 1 GB. The IP turns the line number
// into bank, row and column (3 + 15 + 10 = 28 bits, plus the one rank bit, which is 0 because there is one rank). Byte b
// of a line is bits 8b+7..8b of the 256-bit data word and bit b of the 32-bit mask (IPUG281 table 6-1: one mask bit
// per data byte, 1 = byte not written, which is the opposite polarity of the lanes' own mask). All three clients go
// through the same mapping, so they see the same bytes at the same addresses whatever order the IP puts the eight
// 32-bit words on the pins. The lanes count 64-bit words, four to a line, so a word address divided by four is the
// line number and the two low bits of the word address pick the quarter of the line.
//
// PRIORITY AND WHAT IT COSTS
// The core serves the read lane first (the picture cannot wait), then the write lane, then the processor, one memory
// command at a time and never interrupted. The AE350's bus keeps one 32-byte line in a small cache of its own
// (ddr_mem_ahb), so the processor's cache line fills and write-backs of four 64-bit beats cost one memory command each.
//
// BEHAVIOR WORTH KNOWING
//   - A line that the processor wrote stays in ddr_mem_ahb until the bus asks for another line or has been idle for
//     WR_IDLE bus clocks (256 clocks of 50 MHz = 5.1 us). The logic's read lane does not see the processor's data
//     before that. Firmware that writes data the logic will read (audio ring, TX ring, frame buffer) must therefore
//     write its cache back and then wait about 10 us before moving the pointer the logic follows.
//   - A line that the processor read is kept only for an unbroken run of bus transfers and dropped at the first idle
//     bus clock (parameter RD_KEEP = 1), so the processor never reads a held copy that is older than its own last
//     run of transfers, because the logic may have written the line since.
//   - The write lane starts a burst with the first beat it takes, and its mask is 8 bits with 1 = byte written, which
//     is what ddr3_write_arbiter.v gives; the arbiter's wr_go is not needed.
//   - Parameter HALF = 1 builds the same bridge for the IP with 16 data lines (one chip, 512 MB, lines of 16 bytes).
//     It came with the original design and is neither built nor tested here; HALF = 0 is the only form in use.

`timescale 1ns / 1ps

// ------------------------------------------------------------------------------------------------------------
// ddr_mem_afifo: a first-in-first-out memory (FIFO) of 16 entries of W bits, written in one clock domain and read in
// another. It is how read data (a whole line of 256 bits) crosses from the IP's clk_m to the clock of its reader.
//
// The entries are LUT RAM (distributed RAM made of logic cells), which has no clock on its read port: the read side
// sees the word that its read pointer points at without waiting a clock. An entry is written before the pointer that
// shows it crosses to the other domain, so the reader can never see a pointer that points at a word not yet written.
// Each pointer has 5 bits: 4 address bits for the 16 entries and one wrap bit, so that "full" (pointers differ by 16)
// can be told from "empty" (pointers equal). The pointers cross as Gray code (only one bit changes per step) through
// two flip-flops. w_rbin is the read pointer as the writer sees it (late, never early), converted back to binary, for
// the writer's own count of free entries.
module ddr_mem_afifo #(
    parameter integer W = 256  // width of one entry in bits; 256 = one DDR3 line (the 16-byte form of the bridge uses 128)
) (
    input  wire         wclk,  // write clock (the IP's clk_m)
    input  wire         wrst,  // write reset, high = reset (wclk domain)
    input  wire         we,  // write enable: store wd and advance the write pointer
    input  wire [W-1:0] wd,  // data to store, W bits
    output reg  [4:0]   w_rbin,  // read pointer as the writer sees it, 5 bits binary; late by the synchronizer's delay, never early
    input  wire         rclk,  // read clock (the reader's clock)
    input  wire         rrst,  // read reset, high = reset (rclk domain)
    input  wire         re,                 // pop: advance the read pointer; only with rne high
    output wire [W-1:0] rd,  // the entry at the read pointer, valid whenever rne is high (it needs no clock)
    output reg          rne  // read side not empty: there is an entry to read; registered, and late by the synchronizer's delay
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;
    // The 16 entries, forced into LUT RAM.
    (* syn_ramstyle = "distributed_ram" *) reg [W-1:0] mem [0:15];
    // Pointers: wbin/rbin in binary, wgray/rgray as Gray code. wg_s1, wg_s2 carry the write pointer into the read
    // domain and rg_s1, rg_s2 carry the read pointer into the write domain (two flip-flops each).
    reg [4:0] wbin = 5'd0, wgray = 5'd0;
    reg [4:0] rbin = 5'd0, rgray = 5'd0;
    reg [4:0] wg_s1 = 5'd0, wg_s2 = 5'd0, rg_s1 = 5'd0, rg_s2 = 5'd0;
    wire [4:0] wbin_n = wbin + 5'd1;
    wire [4:0] rbin_n = rbin + 5'd1;
    // Write side: store the entry, advance the write pointer (binary and Gray), and take the read pointer in; the
    // read pointer's Gray code is turned back to binary (each bit is the XOR of itself and all the bits above it).
    always @(posedge wclk) begin
        if (we) mem[wbin[3:0]] <= wd;
        if (wrst) begin wbin <= 5'd0; wgray <= 5'd0; end
        else if (we) begin wbin <= wbin_n; wgray <= wbin_n ^ (wbin_n >> 1); end
        rg_s1 <= rgray; rg_s2 <= rg_s1;
        w_rbin <= {rg_s2[4], rg_s2[4] ^ rg_s2[3], rg_s2[4] ^ rg_s2[3] ^ rg_s2[2],
                   rg_s2[4] ^ rg_s2[3] ^ rg_s2[2] ^ rg_s2[1], ^rg_s2};
    end
    // The read side shows the entry its pointer points at; no clock is needed for that.
    assign rd = mem[rbin[3:0]];
    // Gray code of the next read pointer value, to be loaded when a pop happens.
    wire [4:0] rgray_n = rbin_n ^ (rbin_n >> 1);
    // Read side: take the write pointer in, advance the read pointer on a pop, and keep rne (not empty) as the
    // comparison of the two Gray pointers; after a pop it compares against the pointer's next value.
    always @(posedge rclk) begin
        wg_s1 <= wgray; wg_s2 <= wg_s1;
        if (rrst) begin rbin <= 5'd0; rgray <= 5'd0; rne <= 1'b0; end
        else if (re) begin rbin <= rbin_n; rgray <= rgray_n; rne <= (rgray_n != wg_s2); end
        else rne <= (rgray != wg_s2);
    end
endmodule

// ------------------------------------------------------------------------------------------------------------
// ddr_mem_core: the IP's clock domain (clk_m, 75 MHz). It takes the three clients' requests, puts one command at a time
// in front of the IP, and hands the lines that the IP reads back in the order of the read commands (IPUG281 4.4.8,
// figure 4-17). Priority: read lane (the picture cannot wait), write lane, processor.
//
// Requests arrive as toggles (c_req_t, l_req_t, w_req_t) with their data held still by the client; the core passes each
// toggle through a three-flip-flop chain and takes a change as a new request. A write is acknowledged by a toggle back
// (c_wack_t, w_ack_t) once the IP has taken the command and the data. A read has no acknowledge: its line returns
// through rdq, and cf_we (processor) or lf_we (read lane) says which FIFO it belongs to.
module ddr_mem_core #(
    parameter integer HALF = 0              // 1 = 16 data lines (16-byte lines, the one-chip form); 0 is the form in use
) (
    input  wire         clk,                // clk_out of the IP  // clk_out of the IP, 75 MHz
    input  wire         rst,  // reset, high = reset (clk_m domain); held while the memory is not ready
    // IP user interface (IPUG281 4.4.5 to 4.4.8)
    input  wire         cmd_ready,  // the IP can take a command now
    output wire [2:0]   cmd,  // command: 3'b000 = write, 3'b001 = read
    output wire         cmd_en,  // command enable: high in the one clock in which the command is given
    output wire [28:0]  addr,  // user address: {rank 0, line number (25 bits), 3'b000}
    input  wire         wr_data_rdy,  // the IP can take write data now
    output wire [(HALF ? 128 : 256)-1:0] wr_data,  // write data, one whole line (256 bits; 128 in the 16-byte form)
    output wire         wr_data_en,  // write data valid, high in the clock of the command
    output wire         wr_data_end,  // last write data word, high with wr_data_en (one clock carries the whole line)
    output wire [(HALF ? 16 : 32)-1:0]  wr_data_mask,  // write mask, one bit per byte of the line, 1 = byte NOT written
    input  wire [(HALF ? 128 : 256)-1:0] rd_data,  // read data, one whole line
    input  wire         rd_data_valid,  // rd_data holds a valid line in this clock
    // processor requests (toggle and held data from the AHB side's clock)
    input  wire         c_req_t,  // request toggle; any change is a new request
    input  wire         c_wr,  // 1 = write the line, 0 = read it
    input  wire [24:0]  c_line,  // line number of the request
    input  wire [(HALF ? 128 : 256)-1:0] c_data,  // line to write
    input  wire [(HALF ? 16 : 32)-1:0]  c_mask,  // write mask, 1 = byte NOT written
    output reg          c_wack_t = 1'b0,  // toggles when the IP has taken the processor's write
    output reg          cf_we = 1'b0,       // pulse: rdq holds a read line for the processor's FIFO
    // read lane requests (toggle and held data from the lane's clock)
    input  wire         l_req_t,  // request toggle; any change is a new request
    input  wire [24:0]  l_line,  // number of the first line to read
    input  wire [(HALF ? 8 : 7)-1:0] l_n,   // lines to read, 1..65 (HALF: 1..128); 65 lines are the most that 255 words starting at the end of a line can span
    output reg          lf_we = 1'b0,       // pulse: rdq holds a read line for the lane's FIFO
    input  wire [4:0]   lf_rbin,            // the lane FIFO's read pointer as seen here (late), to count the lines on their way
    // write lane requests (toggle and held data from the lane's clock)
    input  wire         w_req_t,  // request toggle; any change is a new request
    input  wire [26:0]  w_word,  // 64-bit word address of the write (four words to a line)
    input  wire [63:0]  w_data,  // the word to write
    input  wire [7:0]   w_be,               // byte enables of the word, 1 = byte written
    output reg          w_ack_t = 1'b0,  // toggles when the IP has taken the lane's write
    output reg  [(HALF ? 128 : 256)-1:0] rdq  // the read data, registered once; the write side of both read FIFOs takes it from here
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;
    // W: width of a line in bits, MB: bytes (mask bits) per line, LNB: bits of the lane's line counter
    localparam integer W   = HALF ? 128 : 256;
    localparam integer MB  = HALF ? 16 : 32;
    localparam integer LNB = HALF ? 8 : 7;
    // synchronizer chains that bring the three request toggles into this domain; a change between the last two bits
    // is the request
    reg [2:0] cs = 3'd0, ls = 3'd0, ws = 3'd0;
    // c_pend, w_pend: a processor or write lane request waits to be given to the IP
    reg       c_pend = 1'b0, w_pend = 1'b0;
    // read lane bookkeeping: l_cnt lines still to command, l_cur the line to command next
    reg [LNB-1:0] l_cnt = 0;
    reg [24:0] l_cur = 25'd0;
    // l_ptr counts the read commands given for the lane (modulo 32); l_out is how many of those lines are still on
    // their way or in the lane's FIFO, and l_ok says that more lines are due and fewer than 16 are outstanding, so the
    // FIFO (16 entries) can always take every line that is on its way
    reg [4:0]  l_ptr = 5'd0;                // read commands given for the lane (mod 32)
    wire [4:0] l_out = l_ptr - lf_rbin;     // lines on their way or in the lane FIFO (never too small)
    wire       l_ok  = (l_cnt != 0) && !l_out[4];

    // the command in front of the IP: cmd_v valid, cmd_w write (else read), cmd_src who asked, sel_wl 1 = write data
    // comes from the write lane (else from the processor), cmd_line the line, wl_mask the write lane's byte mask
    reg        cmd_v = 1'b0, cmd_w = 1'b0;
    reg [1:0]  cmd_src = 2'd0;              // 0 read lane, 1 write lane, 2 processor
    reg        sel_wl = 1'b0;
    reg [24:0] cmd_line = 25'd0;
    reg [MB-1:0] wl_mask = {MB{1'b1}};
    // The command and the data go in together, in a clock in which the IP takes both (IPUG281 figure 4-10, first case).
    // For the write lane the 64-bit word is repeated into every quarter of the line, and wl_mask lets only the right
    // quarter through (and only its enabled bytes), so a single word writes just its own 8 bytes of the line.
    wire fire = cmd_v && cmd_ready && (!cmd_w || wr_data_rdy);
    assign cmd_en       = fire;
    assign cmd          = cmd_w ? 3'b000 : 3'b001;
    assign addr         = {1'b0, cmd_line, 3'b000};
    assign wr_data_en   = fire && cmd_w;
    assign wr_data_end  = fire && cmd_w;
    assign wr_data      = sel_wl ? {(W / 64){w_data}} : c_data;
    assign wr_data_mask = sel_wl ? wl_mask : c_mask;

    // Who the next read data belongs to, in the order of the read commands: tagq holds one bit per command given
    // (1 = processor, 0 = read lane), t_wp is where the next tag is written and t_rp where the next one is read. At most
    // 17 reads are on their way (16 for the lane and one for the processor).
    reg [31:0] tagq = 32'd0;
    reg [4:0]  t_wp = 5'd0, t_rp = 5'd0;
    wire       t_head = tagq[t_rp];

    // Clocked part: bring in the toggles, register the read data, pick the receiver of each returned line, find new
    // requests, give the next command and acknowledge writes.
    always @(posedge clk) begin
        cs <= {cs[1:0], c_req_t}; ls <= {ls[1:0], l_req_t}; ws <= {ws[1:0], w_req_t};
        rdq   <= rd_data;
        cf_we <= rd_data_valid && t_head && !rst;
        lf_we <= rd_data_valid && !t_head && !rst;
        if (rd_data_valid) t_rp <= t_rp + 5'd1;

        if (cs[2] != cs[1]) c_pend <= 1'b1;
        if (ws[2] != ws[1]) w_pend <= 1'b1;
        if (ls[2] != ls[1]) begin l_cnt <= l_n; l_cur <= l_line; end

        // With no command waiting: take the next one, read lane first, then write lane, then processor.
        if (!cmd_v) begin
            if (l_ok) begin
        // Read lane: command the next line of its burst, count it off, and count it as on its way.
                cmd_v <= 1'b1; cmd_w <= 1'b0; cmd_src <= 2'd0; sel_wl <= 1'b0; cmd_line <= l_cur;
                l_cur <= l_cur + 25'd1; l_cnt <= l_cnt - 1'b1; l_ptr <= l_ptr + 5'd1;
            end else if (w_pend) begin
        // Write lane: line number is the word address divided by 4 (by 2 in the 16-byte form); the mask lets the
        // addressed word through (mask bit 1 = byte NOT written, hence the inverted byte enables).
                cmd_v <= 1'b1; cmd_w <= 1'b1; cmd_src <= 2'd1; sel_wl <= 1'b1;
                cmd_line <= HALF ? w_word[25:1] : w_word[26:2];
                w_pend <= 1'b0;
                if (HALF) wl_mask <= w_word[0] ? {~w_be, 8'hFF} : {8'hFF, ~w_be};
                else case (w_word[1:0])
                    2'd0:    wl_mask <= {24'hFFFFFF, ~w_be};
                    2'd1:    wl_mask <= {16'hFFFF, ~w_be, 8'hFF};
                    2'd2:    wl_mask <= {8'hFF, ~w_be, 16'hFFFF};
                    default: wl_mask <= {~w_be, 24'hFFFFFF};
                endcase
        // Processor: read or write of a whole line, as the AHB side asked.
            end else if (c_pend) begin
                cmd_v <= 1'b1; cmd_w <= c_wr; cmd_src <= 2'd2; sel_wl <= 1'b0; cmd_line <= c_line;
                c_pend <= 1'b0;
            end
        // The IP took the command: write commands are acknowledged by a toggle, read commands note whose line returns.
        end else if (fire) begin
            cmd_v <= 1'b0;
            if (cmd_w) begin
                if (cmd_src == 2'd1) w_ack_t <= ~w_ack_t;
                else                 c_wack_t <= ~c_wack_t;
            end else begin
                tagq[t_wp] <= (cmd_src == 2'd2);
                t_wp <= t_wp + 5'd1;
            end
        end

        // Reset: forget all requests, bookkeeping and tags.
        if (rst) begin
            c_pend <= 1'b0; w_pend <= 1'b0; l_cnt <= 0; l_ptr <= 5'd0; cmd_v <= 1'b0;
            t_wp <= 5'd0; t_rp <= 5'd0; c_wack_t <= 1'b0; w_ack_t <= 1'b0;
        end
    end
endmodule

// ------------------------------------------------------------------------------------------------------------
// ddr_mem_ahb: the AE350's data memory bus (an AHB-Lite slave that is always selected). AHB is the ARM bus in which a
// master first sends an address phase and, one clock later, the data phase, and the slave stretches the data phase by
// holding hready low until it has the answer. The CPU's data cache fills and writes back whole lines (four 64-bit
// beats), and without the cache the accesses stay near each other, so this block keeps one line of 32 bytes: a beat
// that hits the line takes two clocks, and another line costs a write of the old one (only its written bytes, by
// the mask) and, for a read, a read of the new one. A written line that the bus leaves alone for WR_IDLE clocks goes to the
// memory, so the logic's read lane sees the processor's last write without another access; a read line is dropped after
// RD_KEEP idle clocks, so that it is never older than the processor's last run of transfers.
// The line moves to and from the memory through the request toggles and the read FIFO described at ddr_mem_core.
module ddr_mem_ahb #(
    parameter integer HALF = 0,             // 1 = 16-byte lines (the one-chip form); 0 is the form in use
    // RD_KEEP: a line read from the memory is dropped after this many idle bus clocks (1 to 255), so the processor
    // never reads a held copy older than its last run of transfers (the logic may have written the line since).
    // WR_IDLE: a line the processor has written goes to the memory after this many idle clocks (2 to 256).
    parameter integer RD_KEEP = 1,
    parameter integer WR_IDLE = 256         // 256 clocks of 50 MHz are 5.1 us
) (
    input  wire         hclk,  // the AE350's data-memory bus clock, 50 MHz; the whole block runs on it
    input  wire         mrst,               // memory not ready (hclk domain): everything here starts again
    input  wire         hrstn,              // the processor's bus reset (low = reset): the bus side only
    input  wire [31:0]  haddr,  // byte address of the access; the low 30 bits are used (1 GB)
    input  wire [2:0]   hsize,  // size of the access: 0 byte, 1 half-word, 2 word, 3 double word (8 bytes)
    input  wire [1:0]   htrans,  // transfer type; bit 1 set (NONSEQ or SEQ) = a transfer starts, 00 = idle, 01 = BUSY inside a burst
    input  wire         hwrite,  // 1 = write
    input  wire [63:0]  hwdata,  // write data, 64 bits; the beat's bytes are in the lanes given by the address
    output wire         hready,  // high = the slave is ready; low stretches the data phase
    output wire         hresp,  // always 0 (OKAY): the bridge never reports an error
    output reg  [63:0]  hrdata,  // read data, 64 bits, valid when hready is high
    // to ddr_mem_core (request toggle with held data, and the read FIFO of the processor)
    output reg          c_req_t = 1'b0,  // request toggle; flipped once per request
    output reg          c_wr = 1'b0,  // 1 = write a line, 0 = read one
    output reg  [24:0]  c_line = 25'd0,  // line number of the request
    output wire [(HALF ? 128 : 256)-1:0] c_data,  // the held line, written to the memory on a write request
    output wire [(HALF ? 16 : 32)-1:0]  c_mask,  // write mask: 1 = byte NOT written, so the bytes written since the line was fetched
    input  wire         c_wack_t,  // toggles back when the memory has taken the write
    input  wire         cf_rne,  // the processor's read FIFO is not empty
    input  wire [(HALF ? 128 : 256)-1:0] cf_rd,  // the FIFO's oldest line
    output reg          cf_re = 1'b0  // pop pulse for the FIFO
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;
    // W: line width in bits, MB: bytes per line
    localparam integer W  = HALF ? 128 : 256;
    localparam integer MB = HALF ? 16 : 32;
    reg         st = 1'b0;                  // 0: ready (an address phase is taken here), 1: data phase of the taken beat
    // The beat taken in the address phase: byte address, size and direction.
    reg [29:0]  a_addr = 30'd0;
    reg [2:0]   a_size = 3'd0;
    reg         a_write = 1'b0;
    // The held line (line), its line number (tag), tag_v = a line is held, full = the whole line holds memory data
    // (a fetched line, so a read may be answered from it), dirty = one bit per byte written by the processor and not
    // yet in the memory.
    reg [W-1:0] line = 0;
    reg [24:0]  tag = 25'd0;
    reg         tag_v = 1'b0, full = 1'b0;
    reg [MB-1:0] dirty = 0;
    wire [24:0] a_line = HALF ? a_addr[28:4] : a_addr[29:5];   // the beat's line number
    wire [255:0] line4 = line;              // (zero-extended with HALF: the 4-word select below is then not used)
    // xbusy: a transfer to or from the memory is under way; x_fetch: it is a read; wa: synchronizer for c_wack_t
    reg         xbusy = 1'b0, x_fetch = 1'b0;
    reg [2:0]   wa = 3'd0;
    reg [8:0]   idle = 9'd0;                // idle bus clocks since the last transfer (stops at WR_IDLE)
    // hrs: the registered bus reset
    reg         hrs = 1'b0;

    // hready is low in the data phase; the bridge never reports an error; the line goes to the core as it is, and
    // the mask is the inverse of the dirty bits.
    assign hready = !st;
    assign hresp  = 1'b0;
    assign c_data = line;
    assign c_mask = ~dirty;

    // match: the held line is the one the beat addresses; any_d: some byte is dirty
    wire        match   = tag_v && (tag == a_line);
    wire        any_d   = |dirty;
    // Byte strobes of the beat inside its 64-bit word (stb8), by size and the low address bits, then placed in the
    // right quarter of the line (stb4; stb2 for the 16-byte form), one bit per byte of the line.
    reg  [7:0]  stb8;
    always @* begin
        case (a_size[1:0])
            2'd0: case (a_addr[2:0])
                    3'd0: stb8 = 8'h01; 3'd1: stb8 = 8'h02; 3'd2: stb8 = 8'h04; 3'd3: stb8 = 8'h08;
                    3'd4: stb8 = 8'h10; 3'd5: stb8 = 8'h20; 3'd6: stb8 = 8'h40; default: stb8 = 8'h80;
                  endcase
            2'd1: case (a_addr[2:1])
                    2'd0: stb8 = 8'h03; 2'd1: stb8 = 8'h0C; 2'd2: stb8 = 8'h30; default: stb8 = 8'hC0;
                  endcase
            2'd2: stb8 = a_addr[2] ? 8'hF0 : 8'h0F;
            default: stb8 = 8'hFF;
        endcase
    end
    wire [31:0] stb4  = {(a_addr[4:3] == 2'd3) ? stb8 : 8'd0, (a_addr[4:3] == 2'd2) ? stb8 : 8'd0,
                         (a_addr[4:3] == 2'd1) ? stb8 : 8'd0, (a_addr[4:3] == 2'd0) ? stb8 : 8'd0};
    wire [15:0] stb2  = {a_addr[3] ? stb8 : 8'd0, a_addr[3] ? 8'd0 : stb8};
    wire [MB-1:0] stb32 = HALF ? stb2 : stb4;
    // do_wr: the data phase of a write that hits the held line: the bytes go into the line now. got: the memory has
    // delivered the line this beat waits for.
    wire        do_wr = st && !xbusy && a_write && match;
    wire        got   = xbusy && x_fetch && cf_rne && !cf_re;

    integer b;
    // Everything clocked in the AHB domain.
    always @(posedge hclk) begin
        hrs <= hrstn;
        wa  <= {wa[1:0], c_wack_t};
        cf_re <= 1'b0;
        // the line: a fetched line, or the bytes of a write beat (only the bytes the strobes select)
        for (b = 0; b < MB; b = b + 1)
            if (got) line[8*b +: 8] <= cf_rd[8*b +: 8];
            else if (do_wr && stb32[b]) line[8*b +: 8] <= hwdata[8*(b % 8) +: 8];

        // crossings: a write acknowledged by the core clears dirty; a fetched line is taken from the FIFO
        if (xbusy && !x_fetch && (wa[2] != wa[1])) begin xbusy <= 1'b0; dirty <= 0; end
        if (got) begin
            xbusy <= 1'b0; cf_re <= 1'b1; tag <= c_line; tag_v <= 1'b1; full <= 1'b1; dirty <= 0;
        end

        // Address phase (st = 0): take a new transfer, or, with the bus idle, drop a read copy after RD_KEEP idle clocks
        // and send a written line out once the bus has rested WR_IDLE clocks.
        if (!st) begin
            if (htrans[1]) begin
                a_addr <= haddr[29:0]; a_size <= hsize; a_write <= hwrite; st <= 1'b1; idle <= 9'd0;
            end else if (!xbusy) begin
                // The copy read from the memory ends with the run of transfers (an AHB BUSY clock, htrans 01, is part of
                // a burst and does not count).
                if (htrans == 2'b00 && idle == RD_KEEP - 1) full <= 1'b0;
                if (idle != WR_IDLE) idle <= idle + {8'd0, htrans == 2'b00};
                else if (any_d) begin                       // the written line goes out while the bus rests
                    c_wr <= 1'b1; c_line <= tag; c_req_t <= ~c_req_t; xbusy <= 1'b1; x_fetch <= 1'b0;
                end
            end
        // Data phase (st = 1) with no memory transfer under way: a write goes into the held line, or the old line is
        // written out first; a read is answered from the held line, or the memory is asked.
        end else if (!xbusy) begin
            if (a_write) begin
                if (match) begin
                    dirty <= dirty | stb32; st <= 1'b0;     // (the bytes: above)
                end else if (any_d) begin
                    c_wr <= 1'b1; c_line <= tag; c_req_t <= ~c_req_t; xbusy <= 1'b1; x_fetch <= 1'b0;
                end else begin
                    tag <= a_line; tag_v <= 1'b1; full <= 1'b0;
                end
            end else begin
                if (match && full) begin
                    if (HALF) hrdata <= a_addr[3] ? line4[127:64] : line4[63:0];
                    else case (a_addr[4:3])
                        2'd0: hrdata <= line4[63:0];    2'd1:    hrdata <= line4[127:64];
                        2'd2: hrdata <= line4[191:128]; default: hrdata <= line4[255:192];
                    endcase
                    st <= 1'b0;
                end else if (any_d) begin
                    c_wr <= 1'b1; c_line <= tag; c_req_t <= ~c_req_t; xbusy <= 1'b1; x_fetch <= 1'b0;
                end else begin
                    c_wr <= 1'b0; c_line <= a_line; c_req_t <= ~c_req_t; xbusy <= 1'b1; x_fetch <= 1'b1;
                    tag_v <= 1'b0;
                end
            end
        end

        // A reset of the bus ends a beat in progress; "memory not ready" clears everything held.
        if (!hrs) st <= 1'b0;
        if (mrst) begin
            st <= 1'b0; tag_v <= 1'b0; full <= 1'b0; dirty <= 0; xbusy <= 1'b0; c_req_t <= 1'b0;
            idle <= 9'd0;
        end
    end
endmodule

// ------------------------------------------------------------------------------------------------------------
// ddr_mem_rdlane: the read lane of the logic (handshake: file header). It turns a request for a burst of 64-bit words
// into read commands for whole lines, takes the lines out of the lane's FIFO as they come back, and hands out the
// words of each line one per clock. The first line may start in the middle (the burst begins at word idx of its line),
// so a burst of n words spans (word offset + n + 3) / 4 lines at most; 255 words need at most 65 lines.
module ddr_mem_rdlane #(
    parameter integer HALF = 0              // 1 = 16-byte lines (two words a line); 0 is the form in use
) (
    input  wire         clk,  // lane clock, clk_dsp, 120 MHz
    input  wire         rst,  // reset, high = reset (lane clock domain)
    input  wire [31:0]  lane_addr,          // 64-bit word address
    input  wire         lane_rd_en,  // request from the arbiter, held until accepted
    input  wire [7:0]   lane_burst,  // burst length in 64-bit words, 1 to 255; 0 is never accepted
    output reg          lane_rd_rdy = 1'b0,  // high = ready for a request; low from acceptance until the last word is out
    output reg          lane_rd_valid = 1'b0,  // one-clock pulse per word of the burst
    output reg  [63:0]  lane_rd_data,  // the word, 64 bits, valid with lane_rd_valid
    // to ddr_mem_core (request toggle with held data, and the lane's read FIFO)
    output reg          l_req_t = 1'b0,  // request toggle; flipped once per burst
    output reg  [24:0]  l_line = 25'd0,  // number of the first line of the burst
    output reg  [(HALF ? 8 : 7)-1:0] l_n = 0,  // number of lines the burst spans
    input  wire         lf_rne,  // the lane's read FIFO is not empty
    input  wire [(HALF ? 128 : 256)-1:0] lf_rd,  // the FIFO's oldest line
    output reg          lf_re = 1'b0  // pop pulse for the FIFO
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;
    // busy: a burst is running; have: the current line is in `cur`; left: words still to deliver; idx: word within the
    // line (0 to 3); cur: the line the words are cut from
    reg         busy = 1'b0, have = 1'b0;
    reg [7:0]   left = 8'd0;
    reg [1:0]   idx = 2'd0;
    reg [(HALF ? 128 : 256)-1:0] cur;
    wire [255:0] cur4 = cur;                // (zero-extended with HALF)
    // span: word offset + length + 3, whose upper bits are the number of lines (rounded up); span2 is the same for 2
    // words a line
    wire [8:0]  span = {7'd0, lane_addr[1:0]} + {1'b0, lane_burst} + 9'd3;
    wire [8:0]  span2 = {8'd0, lane_addr[0]} + {1'b0, lane_burst} + 9'd1;     // HALF: lines = span2 / 2
    // Free: show ready and wait for a request (rd_en and rd_rdy, length not 0), then send it and note idx and left.
    // Busy without a line: wait until a line is in the FIFO and take it, or end the burst when all words are out.
    // Busy with a line: deliver one word per clock, picked by idx, and give the line up after its last word.
    always @(posedge clk) begin
        lane_rd_valid <= 1'b0;
        lf_re <= 1'b0;
        if (!busy) begin
            lane_rd_rdy <= 1'b1;
            if (lane_rd_en && lane_rd_rdy && lane_burst != 8'd0) begin
                lane_rd_rdy <= 1'b0; busy <= 1'b1; have <= 1'b0;
                if (HALF) begin l_line <= lane_addr[25:1]; l_n <= span2[8:1]; idx <= {1'b0, lane_addr[0]}; end
                else      begin l_line <= lane_addr[26:2]; l_n <= span[8:2];  idx <= lane_addr[1:0]; end
                l_req_t <= ~l_req_t; left <= lane_burst;
            end
        end else if (!have) begin
            if (left == 8'd0) busy <= 1'b0;                 // all words out (and all lines taken)
            else if (lf_rne && !lf_re) begin cur <= lf_rd; lf_re <= 1'b1; have <= 1'b1; end
        end else begin
            lane_rd_valid <= 1'b1;
            if (HALF) lane_rd_data <= idx[0] ? cur4[127:64] : cur4[63:0];
            else case (idx)
                2'd0: lane_rd_data <= cur4[63:0];    2'd1:    lane_rd_data <= cur4[127:64];
                2'd2: lane_rd_data <= cur4[191:128]; default: lane_rd_data <= cur4[255:192];
            endcase
            idx <= HALF ? {1'b0, ~idx[0]} : idx + 2'd1; left <= left - 8'd1;
            if (idx == (HALF ? 2'd1 : 2'd3) || left == 8'd1) have <= 1'b0;
        end
        // Reset: not busy and not ready (ready comes one clock later).
        if (rst) begin
            busy <= 1'b0; have <= 1'b0; lane_rd_rdy <= 1'b0; lane_rd_valid <= 1'b0; l_req_t <= 1'b0;
            left <= 8'd0;
        end
    end
endmodule

// ------------------------------------------------------------------------------------------------------------
// ddr_mem_wrlane: the write lane of the logic (handshake: file header). It sends one 64-bit word per memory write, with
// the byte mask, so a burst runs at one word per round trip to the memory controller (about ten lane clocks). A burst
// starts with its first beat, not with wr_go.
module ddr_mem_wrlane (
    input  wire         clk,  // lane clock, clk_dsp, 120 MHz
    input  wire         rst,  // reset, high = reset (lane clock domain)
    input  wire [31:0]  lane_addr,          // 64-bit word address; read with the first beat of a burst
    input  wire [7:0]   lane_wr_mask,       // 1 = byte written
    input  wire [63:0]  lane_wr_data,  // the word, 64 bits
    input  wire         lane_wr_en,  // a beat is offered; taken in a clock with lane_wr_en high and lane_wr_wait low
    input  wire [7:0]   lane_burst,         // words; read with the first beat of a burst; 0 counts as 1
    output reg          lane_wr_wait = 1'b1,  // high from a beat until the word is in the memory controller; high from reset on
    output reg          lane_wr_done = 1'b0,  // one-clock pulse after the last word of a burst is in the controller; lane_wr_wait is high in that clock
    // to ddr_mem_core (request toggle with held data)
    output reg          w_req_t = 1'b0,  // request toggle; flipped once per word
    output reg  [26:0]  w_word = 27'd0,  // word address of the word, 64-bit words (four to a line)
    output reg  [63:0]  w_data = 64'd0,  // the word
    output reg  [7:0]   w_be = 8'd0,  // byte enables, 1 = byte written
    input  wire         w_ack_t  // toggles when the controller has taken the word
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;
    // as: synchronizer that brings w_ack_t in from the core's clock; sent: a word is on its way to the memory; inb: a
    // burst is under way (its first beat is taken); nxt: word address of the next beat; left: words still to come
    reg [2:0]  as = 3'd0;
    reg        sent = 1'b0, inb = 1'b0;     // inb: inside a burst (its first beat is taken)
    reg [26:0] nxt = 27'd0;
    reg [7:0]  left = 8'd0;                 // words of the burst still to come
    // take: a beat is accepted in this clock
    wire       take = lane_wr_en && !lane_wr_wait;
    // On a beat: send the word (the first beat of a burst takes lane_addr, the following beats the next address) and
    // load the counter; when the core acknowledges it, end the burst (done pulse) after the last word, or accept
    // the next beat; with nothing in flight the lane is ready.
    always @(posedge clk) begin
        as <= {as[1:0], w_ack_t};
        lane_wr_done <= 1'b0;
        if (take) begin
            w_word <= inb ? nxt : lane_addr[26:0];
            nxt    <= (inb ? nxt : lane_addr[26:0]) + 27'd1;
            left   <= inb ? left - 8'd1 : ((lane_burst == 8'd0) ? 8'd0 : lane_burst - 8'd1);
            inb    <= 1'b1;
            w_data <= lane_wr_data;
            w_be   <= lane_wr_mask;
            w_req_t <= ~w_req_t; sent <= 1'b1; lane_wr_wait <= 1'b1;
        end else if (sent) begin
            if (as[2] != as[1]) begin
                sent <= 1'b0;
                // after the last word: wr_done for one clock, wr_wait stays high in it
                if (left == 8'd0) begin lane_wr_done <= 1'b1; inb <= 1'b0; end
                else lane_wr_wait <= 1'b0;
            end
        end else lane_wr_wait <= 1'b0;
        // Reset: not in a burst, nothing on its way, not ready (ready comes one clock later).
        if (rst) begin
            sent <= 1'b0; inb <= 1'b0; lane_wr_wait <= 1'b1; lane_wr_done <= 1'b0; w_req_t <= 1'b0;
            left <= 8'd0;
        end
    end
endmodule

// ------------------------------------------------------------------------------------------------------------
// ddr_mem: the top of the bridge: the IP, the core, the two read FIFOs, the AHB side and the two lanes, and the reset
// of each clock domain.
module ddr_mem #(
    // HALF: 1 = 512 MB, the IP with 16 data lines on chip 0 (data lines 0 to 15, strobes and masks 0 and 1;
    // hw/gowin/mem/gwmc_param.v must have DQ_WIDTH 16: `DDR_512MB). The second chip shares the address, command and
    // clock lines, so it is initialized and answers every read on its own data lines: those pins (data 16 to 31,
    // strobes 2 and 3) are never driven here, and its two mask pins are held high (data masked on every write).
    // 0 (default): both chips, 1 GB.
    parameter integer HALF = 0,
    parameter integer RD_KEEP = 1,          // see ddr_mem_ahb
    parameter integer WR_IDLE = 256  // see ddr_mem_ahb
) (
    // DDR3 clocks and reset (IPUG281 4.4.2 to 4.4.4, figure 4-6)
    input  wire        ddr3_clk_in,         // 50 MHz, the IP's reference clock and the clock of its reset logic
    input  wire        ddr3_mem_clk,        // 300 MHz memory clock, PLL output 2; the IP's user clock is this divided by 4
    input  wire        ddr3_lock,  // the DDR3 PLL is locked
    output wire        ddr3_stop,           // to the PLL's enclk2  // to the PLL's enclk2: lets the IP stop the memory clock
    input  wire        rstn,                // system reset, low = reset, any clock
    output wire        init,                // initialization and read calibration done (clk_out domain)
    // DDR3 pins (grouped as on the chips)
    output wire [2:0]  DDR3_BANK,  // bank address, 3 bits
    output wire        DDR3_CS_N,  // chip select, low = chip selected
    output wire        DDR3_RAS_N,  // row address strobe, low = command bit (with CAS and WE it gives the command)
    output wire        DDR3_CAS_N,  // column address strobe, low = command bit
    output wire        DDR3_WE_N,  // write enable, low = command bit
    output wire        DDR3_CK,  // memory clock, true half of the differential pair
    output wire        DDR3_CK_N,  // memory clock, complement
    output wire        DDR3_CKE,  // clock enable
    output wire        DDR3_RESET_N,  // reset of the memory chips, low = reset
    output wire        DDR3_ODT,  // on-die termination enable
    output wire [14:0] DDR3_ADDR,  // row address during activate, column address during read and write, 15 bits
    output wire [3:0]  DDR3_DM,  // data mask, one pin per byte lane (4 byte lanes of 8 data pins)
    inout  wire [31:0] DDR3_DQ,  // data pins, 32, bidirectional
    inout  wire [3:0]  DDR3_DQS,  // data strobes, one per byte lane, bidirectional (they time the data pins)
    inout  wire [3:0]  DDR3_DQS_N,  // complement of the data strobes
    // AE350 data memory bus (AHB-Lite, see ddr_mem_ahb)
    input  wire        hclk,  // bus clock, 50 MHz
    input  wire        hrstn,  // bus reset, low = reset
    input  wire [31:0] haddr,  // byte address of the access
    input  wire [2:0]  hsize,  // access size
    input  wire [1:0]  htrans,  // transfer type
    input  wire        hwrite,  // 1 = write
    input  wire [63:0] hwdata,  // write data, 64 bits
    output wire        hready,  // slave ready
    output wire        hresp,  // error response, always 0
    output wire [63:0] hrdata,  // read data, 64 bits
    // lanes of the logic (handshake: header of this file)
    input  wire        lane_clk,  // lane clock, clk_dsp, 120 MHz
    input  wire        lane_rst,  // reset of the lane clock domain, high = reset
    input  wire [31:0] addr_lane4,  // write lane: word address of a burst, 64-bit words
    input  wire [7:0]  wr_mask_lane4,       // write lane: byte mask, 1 = byte written
    input  wire [63:0] wr_data_lane4,  // write lane: data word
    input  wire        wr_en_lane4,  // write lane: a beat is offered
    input  wire [7:0]  burstcount_lane4,  // write lane: burst length in words
    output wire        wr_wait_lane4,  // write lane: high while the lane cannot take a beat
    output wire        wr_done_lane4,  // write lane: one-clock pulse after the last word of a burst
    input  wire [31:0] addr_lane5,  // read lane: word address of a burst
    input  wire        rd_en_lane5,  // read lane: request
    input  wire [7:0]  burstcount_lane5,  // read lane: burst length in words
    output wire        rd_valid_lane5,  // read lane: one-clock pulse per word
    output wire [63:0] rd_data_lane5,  // read lane: the word, 64 bits
    output wire        rd_rdy_lane5  // read lane: high = ready for a request
);
    // The IP's reset input is released in step with its own clock (IPUG281 4.4.3): two flip-flops on the 50 MHz clock.
    reg [1:0] rn = 2'b00;
    always @(posedge ddr3_clk_in) rn <= {rn[0], rstn};

    // Wires between the IP and the core. W: line width, MB: bytes per line, DQW and DQB: data pins and byte lanes of
    // the IP (16 and 2 in the one-chip form).
    wire         clk_m, ddr_rst, cmd_ready, cmd_en, wr_data_rdy, wr_data_en, wr_data_end, rd_data_valid;
    wire [2:0]   cmd;
    wire [28:0]  addr;
    localparam integer W   = HALF ? 128 : 256;
    localparam integer MB  = HALF ? 16 : 32;
    localparam integer DQW = HALF ? 16 : 32;
    localparam integer DQB = HALF ? 2 : 4;
    wire [W-1:0]  wr_data, rd_data, rdq;
    wire [MB-1:0] wr_data_mask;
    // Gowin's DDR3 Memory Interface IP. Its user side (cmd, addr, wr_data, rd_data and the valid strobes) is wired to
    // the core; sr_req and ref_req (self-refresh and user refresh requests) are not used; burst = 1 selects the burst of
    // 8 words; the other ports are the DDR3 pins.
    DDR3_Memory_Interface_Top u_ddr3 (
        .clk(ddr3_clk_in), .pll_stop(ddr3_stop), .memory_clk(ddr3_mem_clk), .pll_lock(ddr3_lock),
        .rst_n(rn[1]), .clk_out(clk_m), .ddr_rst(ddr_rst), .init_calib_complete(init),
        .cmd_ready(cmd_ready), .cmd(cmd), .cmd_en(cmd_en), .addr(addr),
        .wr_data_rdy(wr_data_rdy), .wr_data(wr_data), .wr_data_en(wr_data_en), .wr_data_end(wr_data_end),
        .wr_data_mask(wr_data_mask), .rd_data(rd_data), .rd_data_valid(rd_data_valid), .rd_data_end(),
        .sr_req(1'b0), .ref_req(1'b0), .sr_ack(), .ref_ack(), .burst(1'b1),
        .O_ddr_addr(DDR3_ADDR), .O_ddr_ba(DDR3_BANK), .O_ddr_cs_n(DDR3_CS_N), .O_ddr_ras_n(DDR3_RAS_N),
        .O_ddr_cas_n(DDR3_CAS_N), .O_ddr_we_n(DDR3_WE_N), .O_ddr_clk(DDR3_CK), .O_ddr_clk_n(DDR3_CK_N),
        .O_ddr_cke(DDR3_CKE), .O_ddr_odt(DDR3_ODT), .O_ddr_reset_n(DDR3_RESET_N), .O_ddr_dqm(DDR3_DM[DQB-1:0]),
        .IO_ddr_dq(DDR3_DQ[DQW-1:0]), .IO_ddr_dqs(DDR3_DQS[DQB-1:0]), .IO_ddr_dqs_n(DDR3_DQS_N[DQB-1:0]));
    // With the 16-data-line form the second chip's pins stay unused (see the parameter): masks high, data and strobes
    // never driven.
    generate if (HALF != 0) begin : hlf
        // the second chip's pins (see the parameter): masks high, data and strobes never driven
        assign DDR3_DM[3:2]    = 2'b11;
        assign DDR3_DQ[31:16]  = 16'bz;
        assign DDR3_DQS[3:2]   = 2'bz;
        assign DDR3_DQS_N[3:2] = 2'bz;
    end endgenerate

    // "memory not ready" in each of the three clock domains: every part of the bridge starts again together. Each is a
    // three-flip-flop chain, so the reset ends cleanly in each domain; it is held while the IP has not finished
    // calibrating (init low), and it begins as set. The lane domain also takes the lane reset. The IP's own reset
    // output holds the core in reset too.
    reg [2:0] m_rs = 3'b111, h_rs = 3'b111, l_rs = 3'b111;
    always @(posedge clk_m)    m_rs <= {m_rs[1:0], ddr_rst | ~init};
    always @(posedge hclk)     h_rs <= {h_rs[1:0], ~init};
    always @(posedge lane_clk) l_rs <= {l_rs[1:0], ~init | lane_rst};
    wire m_rst = m_rs[2], h_rst = h_rs[2], l_rst = l_rs[2];

    // Wires between the blocks: the processor's and lanes' request toggles and held data, the read FIFOs, and the
    // write lane's fields.
    wire         c_req_t, c_wr, c_wack_t, cf_we, cf_rne, cf_re;
    wire [24:0]  c_line, l_line;
    wire [W-1:0]  c_data, cf_rd, lf_rd;
    wire [MB-1:0] c_mask;
    wire         l_req_t, lf_we, lf_rne, lf_re, w_req_t, w_ack_t;
    wire [(HALF ? 8 : 7)-1:0] l_n;
    wire [4:0]   lf_rbin;
    wire [26:0]  w_word;
    wire [63:0]  w_data;
    wire [7:0]   w_be;

    // The core, in the IP's clock domain.
    ddr_mem_core #(.HALF(HALF)) u_core (
        .clk(clk_m), .rst(m_rst),
        .cmd_ready(cmd_ready), .cmd(cmd), .cmd_en(cmd_en), .addr(addr), .wr_data_rdy(wr_data_rdy),
        .wr_data(wr_data), .wr_data_en(wr_data_en), .wr_data_end(wr_data_end), .wr_data_mask(wr_data_mask),
        .rd_data(rd_data), .rd_data_valid(rd_data_valid),
        .c_req_t(c_req_t), .c_wr(c_wr), .c_line(c_line), .c_data(c_data), .c_mask(c_mask),
        .c_wack_t(c_wack_t), .cf_we(cf_we),
        .l_req_t(l_req_t), .l_line(l_line), .l_n(l_n), .lf_we(lf_we), .lf_rbin(lf_rbin),
        .w_req_t(w_req_t), .w_word(w_word), .w_data(w_data), .w_be(w_be), .w_ack_t(w_ack_t),
        .rdq(rdq));

    // The processor's read FIFO (write side in clk_m, read side in the AHB clock).
    ddr_mem_afifo #(.W(W)) u_cf (
        .wclk(clk_m), .wrst(m_rst), .we(cf_we), .wd(rdq), .w_rbin(),
        .rclk(hclk), .rrst(h_rst), .re(cf_re), .rd(cf_rd), .rne(cf_rne));
    // The read lane's FIFO (write side in clk_m, read side in the lane clock); it also gives the core the read pointer.
    ddr_mem_afifo #(.W(W)) u_lf (
        .wclk(clk_m), .wrst(m_rst), .we(lf_we), .wd(rdq), .w_rbin(lf_rbin),
        .rclk(lane_clk), .rrst(l_rst), .re(lf_re), .rd(lf_rd), .rne(lf_rne));

    // The AE350's data memory bus, in the bus clock domain.
    ddr_mem_ahb #(.HALF(HALF), .RD_KEEP(RD_KEEP), .WR_IDLE(WR_IDLE)) u_ahb (
        .hclk(hclk), .mrst(h_rst), .hrstn(hrstn), .haddr(haddr), .hsize(hsize), .htrans(htrans),
        .hwrite(hwrite), .hwdata(hwdata), .hready(hready), .hresp(hresp), .hrdata(hrdata),
        .c_req_t(c_req_t), .c_wr(c_wr), .c_line(c_line), .c_data(c_data), .c_mask(c_mask),
        .c_wack_t(c_wack_t), .cf_rne(cf_rne), .cf_rd(cf_rd), .cf_re(cf_re));

    // The read lane, in the lane clock domain.
    ddr_mem_rdlane #(.HALF(HALF)) u_rdl (
        .clk(lane_clk), .rst(l_rst), .lane_addr(addr_lane5), .lane_rd_en(rd_en_lane5),
        .lane_burst(burstcount_lane5), .lane_rd_rdy(rd_rdy_lane5), .lane_rd_valid(rd_valid_lane5),
        .lane_rd_data(rd_data_lane5),
        .l_req_t(l_req_t), .l_line(l_line), .l_n(l_n), .lf_rne(lf_rne), .lf_rd(lf_rd), .lf_re(lf_re));

    // The write lane, in the lane clock domain.
    ddr_mem_wrlane u_wrl (
        .clk(lane_clk), .rst(l_rst), .lane_addr(addr_lane4), .lane_wr_mask(wr_mask_lane4),
        .lane_wr_data(wr_data_lane4), .lane_wr_en(wr_en_lane4),
        .lane_burst(burstcount_lane4), .lane_wr_wait(wr_wait_lane4), .lane_wr_done(wr_done_lane4),
        .w_req_t(w_req_t), .w_word(w_word), .w_data(w_data), .w_be(w_be), .w_ack_t(w_ack_t));
endmodule
