// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// hl2_link_regs: the register page 0xE801_0000 of the link to the Hermes-Lite 2 (HL2).
//
// WHAT IT DOES AND WHERE IT SITS
// The HL2 sends its raw ADC samples to the radio as Ethernet frames over the SFP0 cage. The receive link block
// (rtl/hl2link/hl2_link_rx_top.v) picks those frames apart in the clk_rx domain (125 MHz, the receive clock recovered by
// transceiver lane 0), counts what it sees and keeps a ring of the frames meant for the CPU. The transmit link block
// (rtl/hl2link/hl2_link_tx_top.v) sends the transmit samples and control frames back. This module is the window the CPU
// looks through: it holds the settings the CPU writes (addresses, ports, enables), it shows the counters and status that
// the link blocks produce, and it raises two interrupt lines. It runs in clk_dsp (120 MHz) like the rest of the register
// bus, and the registers themselves are listed below with the offsets the firmware uses (hw/regmap/hl2_link.toml is the
// source of the offsets, the generated include below turns them into the `define names used in the code).
//
// CROSSING BETWEEN clk_rx AND clk_dsp
// The two clocks are unrelated (the constraint file declares them asynchronous), so a multi-bit value cannot simply be
// read in the other domain, because a read taken in the middle of a change could mix old and new bits. Every counter that
// lives in clk_rx is therefore packed into one wide word, and cdc_word.v (a toggle handshake) copies the whole word
// across at once, every 32 clk_rx clocks (256 ns). The counters are free-running or slow status values, so a snapshot that
// is at most 256 ns old is exact enough, and the CPU only ever sees a consistent set. The loss counters travel in a second
// word, sent 16 clocks after the first so that the two do not start together. The HL2's IP address goes the other way, from
// clk_dsp to clk_rx, once every 64 clk_dsp clocks (533 ns), so that a receive clock that starts late (the link comes up after
// reset) still gets it without any special event. For a beginner: see docs/learn/GLOSSARY.md for clock domain crossing.
//
// INTERRUPTS (docs/ARCHITECTURE.md 4.3; sys_regs.v latches them)
//   irq_pkt     line 0, one clk_dsp clock whenever the count of committed ring frames changed between two snapshots (a frame
//               landed in the CPU receive ring). Several frames between two snapshots give one pulse, which is fine because
//               the firmware drains the ring up to RING_WPTR anyway.
//   irq_status  line 1, one clock when the safety byte changes or when the gap filler reports a gap or resync (irq_gap).
//
// REGISTER MAP (offset inside the page, 32 bits each; RO = read-only, RW = read-write, W1C = write 1 to clear)
//   0x00 ID                 RO   0x484C_0001 (the letters "HL" and version 1)
//   0x04 CTRL               RW   bit 0 rx_enable (the classifier and raw-frame parser run), bit 1 dhcp_enable (the
//                                firmware's DHCP server answers the HL2; 0 = link-local addressing only). Reset value 0x2.
//   0x08 OUR_MAC_HI         RW   bits 15:0 = upper 16 bits of our MAC address (used to build transmit frame headers)
//   0x0C OUR_MAC_LO         RW   lower 32 bits of our MAC address
//   0x10 OUR_IP             RW   our IPv4 address on the link, reset value 10.99.0.1
//   0x14 HL2_MAC_HI         RW   bits 15:0 = upper 16 bits of the HL2's MAC address (the firmware writes it from the discovery reply)
//   0x18 HL2_MAC_LO         RW   lower 32 bits of the HL2's MAC address
//   0x1C HL2_IP             RW   the HL2's IPv4 address (assigned by our DHCP server or learned from discovery)
//   0x20 STATUS             RO   bit 0 = at least one frame has been routed to the CPU receive ring (the register map names
//                                this bit "discovered", since the HL2's discovery reply is such a frame), bit 1 = streaming:
//                                a raw sample frame arrived within the last 2^18 clk_dsp clocks (2.2 ms)
//   0x24 SAFETY_BYTE        bits 7:0 RO, the safety byte from the header of the latest raw frame (bit 7 = trip, bit 6 = over
//                                temperature); bit 8 = changed, a sticky flag set when the byte changes, cleared by writing 1 (W1C)
//   0x28 RX_SEQ             RO   sequence number of the last committed raw frame
//   0x2C RX_FIRST_SAMPLE_HI RO   reads 0 (the receive block does not export the frame header fields)
//   0x30 RX_FIRST_SAMPLE_LO RO   reads 0, as above
//   0x34 GAP_COUNT          RO   gap-fill events (lost or CRC-failed frames); a free-running count, read it twice and subtract
//   0x38 CRC_ERROR_COUNT    RO   frames dropped for a bad CRC-32
//   0x3C TX_CTRL            RW   bit 0 = enable of the transmit framer (1 = real transmit samples go out, 0 = zeros)
//   0x40 TX_FIFO_FILL       RO   bits 15:0, the fill of the HL2's transmit FIFO as reported in the frame header
//   0x44 TX_TRIM            RO   signed count of samples the trim loop has added or dropped to hold that fill steady
//   0x48 RAW_FRAME_COUNT    RO   CRC-good raw sample frames
//   0x4C OTHER_FRAME_COUNT  RO   CRC-good frames routed to the CPU receive ring
//   0x50 RING_FRAMES        RO   bits 15:0 = frames committed to the ring, bits 31:16 = frames dropped because it was full
//   0x54 GAP_SAMPLE_COUNT   RO   zero samples the gap filler inserted
//   0x58 RESYNC_COUNT       RO   sample index jumps too large to fill
//   0x5C RING_WPTR          RO   bits 11:0, write pointer of the CPU receive ring as a byte offset into its 4 KB
//   0x60 SAMPLE_INDEX_LO    RO   low 32 bits of the 48-bit HL2 sample index of the next expected sample; reading this word
//                                also takes a copy of the whole index, so that the next read sees a matching high word
//   0x64 SAMPLE_INDEX_HI    RO   bits 15:0 = high 16 bits of the index copy taken by the last read of SAMPLE_INDEX_LO
//   0x68 OUR_PORT           RW   bits 15:0 = our UDP source port for raw transmit frames, reset value 51000 (0xC738)
//   0x6C TX_COUNTS          RO   bits 15:0 = samples inserted, bits 31:16 = samples skipped by the transmit rate lock
//   0x70 SEQ_LOST           RO   raw frames missing by the HL2's frame sequence number (the figure that should stay 0)
//   0x74 LOSS_A             RO   bits 15:0 = sequence restarts (the HL2 started again), bits 31:16 = frames with a code error
//   0x78 LOSS_B             RO   bits 15:0 = length errors, bits 31:16 = committed frames flagged by the HL2 as having lost samples
//   0x7C LOSS_C             RO   bits 15:0 = frames not drained (the previous one was still draining), bits 31:16 = ring overruns
//   0x80 LOSS_D             RO   bits 15:0 = frame indices lost because the index FIFO was full, bits 31:16 = the HL2's own FIFO overflow count
// Every register is read two clocks after its strobe at the earliest and every write lands two clocks after the strobe
// (the registered decode described in block_regs.v).

`timescale 1ns / 1ps

`include "hw/regmap/generated/hl2_link_regs.vh"

module hl2_link_regs (
    input  wire        clk,            // register bus clock, clk_dsp (120 MHz)
    input  wire        rst,  // synchronous reset, high = reset
    input  wire        bus_wr,  // write strobe from regbus_leg, one clock per CPU write
    input  wire        bus_rd,  // read strobe from regbus_leg, one clock per CPU read (used only for the sample index capture)
    input  wire [15:0] bus_addr,  // offset of the register inside the 64 KB page, a multiple of 4
    input  wire [31:0] bus_wdata,  // data of the CPU write, held until the next access to this page
    output reg  [31:0] bus_rdata,  // read data back to the leg: the addressed register, 0 for any other address
    // Counters and status of the receive link block, all in the clk_rx domain and carried to clk_dsp by the snapshot below.
    input  wire        clk_rx,  // receive clock, 125 MHz (the recovered clock of SFP transceiver lane 0)
    input  wire [31:0] rx_cnt_crc_errors,  // frames dropped for a bad CRC-32, running count
    input  wire [31:0] rx_cnt_raw_frames,  // CRC-good raw sample frames, running count
    input  wire [31:0] rx_cnt_other_frames,  // CRC-good frames routed to the CPU receive ring, running count
    input  wire [15:0] rx_cnt_ring_frames,  // frames committed to the CPU receive ring, 16-bit count that wraps
    input  wire [15:0] rx_cnt_ring_dropped,  // frames dropped because the ring was full, 16-bit count that wraps
    input  wire [11:0] rx_ring_wr_ptr,  // write pointer of the CPU receive ring, byte offset 0 to 4095
    input  wire [7:0]  rx_safety_byte,  // safety byte from the header of the latest raw frame (bit 7 trip, bit 6 over temperature)
    // Loss accounting of the link (docs/HL2_SFP.md section 6), also in clk_rx.
    input  wire [31:0] rx_seq_lost,  // raw frames missing by the HL2's frame sequence number
    input  wire [31:0] rx_last_seq,  // sequence number of the last committed raw frame
    input  wire [15:0] rx_seq_restarts,  // times the sequence went back or the HL2 started again
    input  wire [15:0] rx_code_frames,  // frames dropped for a line code error
    input  wire [15:0] rx_len_errors,  // frames dropped for a length error
    input  wire [15:0] rx_hl2_missing,  // committed frames that carry the HL2's own lost-samples flag
    input  wire [15:0] rx_drain_drops,  // committed frames not drained because the previous one was still draining
    input  wire [15:0] rx_overruns,  // samples written over ones not yet drained
    input  wire [15:0] rx_idx_drops,  // frame indices lost because the index FIFO was full
    input  wire [15:0] rx_hl2_ovf,  // the HL2's own FIFO overflow count from the last raw frame header
    output wire [31:0] rx_cfg_hl2_ip,  // to the receive block, clk_rx domain: the HL2's IPv4 address, for its raw-frame classifier
    // From the gap filler of the receive link block, already in clk_dsp.
    input  wire [31:0] cnt_gap_events,  // gap-fill events, running count
    input  wire [31:0] cnt_gap_samples,  // zero samples the gap filler inserted, running count
    input  wire [31:0] cnt_resync_events,  // sample index jumps too large to fill, running count
    input  wire        irq_gap,  // one-clock pulse when the gap filler fills a gap or resynchronizes
    input  wire [47:0] sample_index,  // 48-bit HL2 sample index of the next expected ADC sample
    // Settings kept in this block and exported (clk_dsp): our addresses, the HL2's addresses, the transmit enable.
    output reg  [47:0] our_mac,  // our MAC address, 48 bits
    output reg  [31:0] our_ip,  // our IPv4 address
    output reg  [31:0] hl2_ip,  // the HL2's IPv4 address
    output reg  [47:0] hl2_mac,  // the HL2's MAC address
    output reg  [15:0] our_port,  // our UDP source port for raw transmit frames
    input  wire [31:0] tx_insert,      // from the transmit link: samples inserted by its rate lock (clk_dsp)
    input  wire [31:0] tx_skip,  // from the transmit link: samples skipped by its rate lock
    output reg         tx_enable,  // 1 = the transmit framer may send real transmit samples
    output wire [7:0]  safety_byte,    // clk_dsp copy of the safety byte, for the transmit chain's trip input
    input  wire [15:0] tx_fifo_fill,   // fill of the HL2's transmit FIFO as reported in the frame header (clk_dsp)
    input  wire [31:0] tx_trim,  // signed count of samples the transmit trim loop added or dropped
    // interrupts to the system register block (clk_dsp, one-clock pulses)
    output reg         irq_pkt,  // line 0: the number of frames in the receive ring changed
    output reg         irq_status  // line 1: the safety byte changed, or a gap or resync happened
) /* synthesis syn_maxfan = 10000 syn_srlstyle = "registers" */;

    // ---------------------------------------------------------------- clk_rx -> clk_dsp snapshot
    // SW is the width of the first snapshot word: three 32-bit counters, two 16-bit counters, the 12-bit ring pointer and the
    // 8-bit safety byte.
    localparam SW = 32 * 3 + 16 * 2 + 12 + 8;   // 148
    // rx_tick counts clk_rx clocks 0 to 31 and wraps; the word is sent when it is 0, so once every 32 clocks (256 ns at 125 MHz).
    reg  [4:0] rx_tick = 5'd0;
    always @(posedge clk_rx) rx_tick <= rx_tick + 1'b1;
    // snap_rx is the word as the receive side builds it (the first-listed field ends up in the top bits).
    wire [SW-1:0] snap_rx = {rx_cnt_crc_errors, rx_cnt_raw_frames, rx_cnt_other_frames,
                             rx_cnt_ring_frames, rx_cnt_ring_dropped, rx_ring_wr_ptr, rx_safety_byte};
    // snap and snap_valid are the copy in clk_dsp; snap_valid is a one-clock pulse when a fresh word has arrived.
    wire [SW-1:0] snap;
    wire          snap_valid;
    cdc_word #(.W(SW)) u_snap (
        .clk_a(clk_rx), .d_a(snap_rx), .send_a(rx_tick == 5'd0),
        .clk_b(clk),    .q_b(snap),    .valid_b(snap_valid)
    );
    // Taking the snapshot apart again, from the top bit down in the same order as it was packed.
    wire [31:0] crc_errors   = snap[147:116];
    wire [31:0] raw_frames   = snap[115:84];
    wire [31:0] other_frames = snap[83:52];
    wire [15:0] ring_frames  = snap[51:36];
    wire [15:0] ring_dropped = snap[35:20];
    wire [11:0] ring_wptr    = snap[19:8];
    assign      safety_byte  = snap[7:0];

    // the loss counters, a second word on the same tick counter but 16 clocks later; no valid pulse is needed because the
    // registers just show the latest word
    wire [191:0] lsnap;
    cdc_word #(.W(192)) u_lsnap (
        .clk_a(clk_rx), .d_a({rx_seq_lost, rx_last_seq, rx_code_frames, rx_seq_restarts, rx_hl2_missing, rx_len_errors,
                              rx_overruns, rx_drain_drops, rx_hl2_ovf, rx_idx_drops}),
        .send_a(rx_tick == 5'd16), .clk_b(clk), .q_b(lsnap), .valid_b()
    );

    // ---------------------------------------------------------------- clk_dsp -> clk_rx HL2 IP
    // dsp_tick counts clk_dsp clocks 0 to 63, so the HL2's IP address is sent to clk_rx every 64 clocks (533 ns).
    reg [5:0] dsp_tick = 6'd0 /* synthesis syn_preserve = 1 */;
    always @(posedge clk) dsp_tick <= dsp_tick + 1'b1;
    cdc_word #(.W(32)) u_ip (
        .clk_a(clk), .d_a(hl2_ip), .send_a(dsp_tick == 6'd0),
        .clk_b(clk_rx), .q_b(rx_cfg_hl2_ip), .valid_b()
    );

    // ---------------------------------------------------------------- registers
    // rx_enable and dhcp_enable are the two bits of CTRL; dhcp_enable is on after reset.
    reg        rx_enable = 1'b0, dhcp_enable = 1'b1;
    // safety_changed is the sticky changed flag of SAFETY_BYTE; safety_d is the safety byte of the previous snapshot.
    reg        safety_changed = 1'b0;
    reg [7:0]  safety_d = 8'h01;
    // ring_frames_d is the committed-frame count of the previous snapshot, used to find a change.
    reg [15:0] ring_frames_d = 16'd0;
    // snap_seen = a first snapshot has arrived, so the comparisons with the previous values are meaningful.
    reg        snap_seen = 1'b0;
    // index_hi_latch holds the high part of the sample index captured by a read of SAMPLE_INDEX_LO.
    reg [15:0] index_hi_latch = 16'd0;
    // raw_age counts clk_dsp clocks since the raw frame count last changed, saturating at 0x3FFFF (reset value = never).
    reg [17:0] raw_age = 18'h3FFFF;
    // raw_frames_d is the raw frame count of the previous snapshot.
    reg [31:0] raw_frames_d = 32'd0;

    // Registered decode (the scheme is described in block_regs.v): hit has one bit per register, the address compare of
    // this clock; the numbering of the bits (0 = ID at the right end, 30 = LOSS_D at the left end) is listed at we and rs below.
    // NR registers are decoded, 31 in all.
    localparam NR = 31;
    wire [NR-1:0] hit = {
        bus_addr == `HL2_LINK_LOSS_D_ADDR,            bus_addr == `HL2_LINK_LOSS_C_ADDR,
        bus_addr == `HL2_LINK_LOSS_B_ADDR,            bus_addr == `HL2_LINK_LOSS_A_ADDR,
        bus_addr == `HL2_LINK_SEQ_LOST_ADDR,          bus_addr == `HL2_LINK_RX_SEQ_ADDR,
        bus_addr == `HL2_LINK_SAMPLE_INDEX_HI_ADDR,   bus_addr == `HL2_LINK_SAMPLE_INDEX_LO_ADDR,
        bus_addr == `HL2_LINK_RING_WPTR_ADDR,         bus_addr == `HL2_LINK_RESYNC_COUNT_ADDR,
        bus_addr == `HL2_LINK_GAP_SAMPLE_COUNT_ADDR,  bus_addr == `HL2_LINK_RING_FRAMES_ADDR,
        bus_addr == `HL2_LINK_OTHER_FRAME_COUNT_ADDR, bus_addr == `HL2_LINK_RAW_FRAME_COUNT_ADDR,
        bus_addr == `HL2_LINK_TX_TRIM_ADDR,           bus_addr == `HL2_LINK_TX_FIFO_FILL_ADDR,
        bus_addr == `HL2_LINK_TX_CTRL_ADDR,           bus_addr == `HL2_LINK_CRC_ERROR_COUNT_ADDR,
        bus_addr == `HL2_LINK_GAP_COUNT_ADDR,         bus_addr == `HL2_LINK_SAFETY_BYTE_ADDR,
        bus_addr == `HL2_LINK_STATUS_ADDR,            bus_addr == `HL2_LINK_TX_COUNTS_ADDR,
        bus_addr == `HL2_LINK_OUR_PORT_ADDR,          bus_addr == `HL2_LINK_HL2_MAC_LO_ADDR,
        bus_addr == `HL2_LINK_HL2_MAC_HI_ADDR,        bus_addr == `HL2_LINK_HL2_IP_ADDR,
        bus_addr == `HL2_LINK_OUR_IP_ADDR,            bus_addr == `HL2_LINK_OUR_MAC_LO_ADDR,
        bus_addr == `HL2_LINK_OUR_MAC_HI_ADDR,        bus_addr == `HL2_LINK_CTRL_ADDR,
        bus_addr == `HL2_LINK_ID_ADDR};
    // we = write flag per register (one clock), rs = read selection per register, both registered one clock after the strobe.
    // The bit positions follow the order of the register map above: bit 0 = ID at 0x00, bit 1 = CTRL at 0x04, bit 2 = OUR_MAC_HI,
    // 3 = OUR_MAC_LO, 4 = OUR_IP, 5 = HL2_IP, 6 = HL2_MAC_HI, 7 = HL2_MAC_LO, 8 = OUR_PORT, 9 = TX_COUNTS, 10 = STATUS,
    // 11 = SAFETY_BYTE, 12 = GAP_COUNT, 13 = CRC_ERROR_COUNT, 14 = TX_CTRL, 15 = TX_FIFO_FILL, 16 = TX_TRIM, 17 = RAW_FRAME_COUNT,
    // 18 = OTHER_FRAME_COUNT, 19 = RING_FRAMES, 20 = GAP_SAMPLE_COUNT, 21 = RESYNC_COUNT, 22 = RING_WPTR, 23 = SAMPLE_INDEX_LO,
    // 24 = SAMPLE_INDEX_HI, 25 = RX_SEQ, 26 = SEQ_LOST, 27 to 30 = LOSS_A to LOSS_D.
    reg [NR-1:0] we = {NR{1'b0}}, rs = {NR{1'b0}};
    // rd_lo = a read of SAMPLE_INDEX_LO happened (bit 23 of hit), used one clock later to copy the index.
    reg          rd_lo = 1'b0;
    // index_lo_latch = low 32 bits of the sample index copy, shown by SAMPLE_INDEX_LO.
    reg [31:0]   index_lo_latch = 32'd0;
    // st_streaming and st_other are the two STATUS bits, registered to keep the read-data path short.
    reg          st_streaming = 1'b0, st_other = 1'b0;
    // registered flags: the decode (one clock after the strobe) and the two status bits
    always @(posedge clk) begin
        we    <= bus_wr ? hit : {NR{1'b0}};
        rs    <= hit;
        rd_lo <= bus_rd && hit[23];
        // streaming = a raw frame arrived recently (raw_age has not run out)
        st_streaming <= (raw_age != 18'h3FFFF);
        // other = the CPU receive ring has been used at least once
        st_other     <= (other_frames != 32'd0);
    end

    // settings, interrupt pulses, sticky flag and the sample index capture
    always @(posedge clk) begin
        // the interrupt outputs are pulses: low unless one of the conditions below sets them in this clock
        irq_pkt    <= 1'b0;
        irq_status <= 1'b0;
        // reset values: receive off, DHCP on, our address 10.99.0.1 (0x0A63_0001), UDP port 51000, everything else 0
        if (rst) begin
            rx_enable      <= 1'b0;
            dhcp_enable    <= 1'b1;
            our_mac        <= 48'd0;
            our_ip         <= 32'h0A63_0001;
            hl2_ip         <= 32'd0;
            hl2_mac        <= 48'd0;
            our_port       <= 16'd51000;
            tx_enable      <= 1'b0;
            safety_changed <= 1'b0;
            snap_seen      <= 1'b0;
        end else begin
            // a fresh snapshot has arrived: remember it and compare with the previous one
            if (snap_valid) begin
                snap_seen     <= 1'b1;
                safety_d      <= safety_byte;
                ring_frames_d <= ring_frames;
                raw_frames_d  <= raw_frames;
                // the committed-frame count changed, so at least one frame landed in the ring: interrupt line 0
                if (snap_seen && ring_frames != ring_frames_d) irq_pkt <= 1'b1;
                // the safety byte changed: set the sticky flag and raise interrupt line 1
                if (snap_seen && safety_byte != safety_d) begin
                    safety_changed <= 1'b1;
                    irq_status     <= 1'b1;
                end
            end
            // a gap or resync reported by the gap filler also raises interrupt line 1
            if (irq_gap) irq_status <= 1'b1;

            // CPU writes: we[n] is the write flag of register n (see the list above)
            if (we[1]) begin
                rx_enable   <= bus_wdata[`HL2_LINK_CTRL_RX_ENABLE_LSB];
                dhcp_enable <= bus_wdata[`HL2_LINK_CTRL_DHCP_ENABLE_LSB];
            end
            if (we[2]) our_mac[47:32] <= bus_wdata[15:0];
            if (we[3]) our_mac[31:0]  <= bus_wdata;
            if (we[4]) our_ip         <= bus_wdata;
            if (we[5]) hl2_ip         <= bus_wdata;
            if (we[6]) hl2_mac[47:32] <= bus_wdata[15:0];
            if (we[7]) hl2_mac[31:0]  <= bus_wdata;
            if (we[8]) our_port       <= bus_wdata[15:0];
            // W1C: writing a 1 into bit 8 of SAFETY_BYTE clears the changed flag
            if (we[11] && bus_wdata[`HL2_LINK_SAFETY_BYTE_CHANGED_LSB]) safety_changed <= 1'b0;
            // transmit framer enable
            if (we[14]) tx_enable <= bus_wdata[`HL2_LINK_TX_CTRL_ENABLE_LSB];
            // reading SAMPLE_INDEX_LO copies the whole 48-bit index in one clock (one clock after the strobe), and the read
            // data is that copy, so the low and the high word always belong together
            if (rd_lo) begin
                index_lo_latch <= sample_index[31:0];
                index_hi_latch <= sample_index[47:32];
            end
        end
        // "streaming" status: raw_age restarts at 0 whenever a snapshot shows a new raw frame count and then counts up to
        // 0x3FFFF, so the bit is set while a raw frame arrived within the last 2^18 clk_dsp clocks (2.2 ms at 120 MHz)
        if (snap_valid && raw_frames != raw_frames_d) raw_age <= 18'd0;
        else if (raw_age != 18'h3FFFF)                 raw_age <= raw_age + 1'b1;
    end

    // read data: every register is ANDed with its selection bit and the results are ORed, so only the addressed register
    // shows and any other address reads 0. Registers narrower than 32 bits are padded with zeros on the left.
    always @(posedge clk) begin
        bus_rdata <= ({32{rs[0]}}  & `HL2_LINK_ID_RESET)                        |
                     ({32{rs[1]}}  & {30'd0, dhcp_enable, rx_enable})           |
                     ({32{rs[2]}}  & {16'd0, our_mac[47:32]})                   |
                     ({32{rs[3]}}  & our_mac[31:0])                             |
                     ({32{rs[4]}}  & our_ip)                                    |
                     ({32{rs[5]}}  & hl2_ip)                                    |
                     ({32{rs[6]}}  & {16'd0, hl2_mac[47:32]})                   |
                     ({32{rs[7]}}  & hl2_mac[31:0])                             |
                     ({32{rs[8]}}  & {16'd0, our_port})                         |
                     ({32{rs[9]}}  & {tx_skip[15:0], tx_insert[15:0]})          |
                     ({32{rs[10]}} & {30'd0, st_streaming, st_other})           |
                     ({32{rs[11]}} & {23'd0, safety_changed, safety_byte})      |
                     ({32{rs[12]}} & cnt_gap_events)                            |
                     ({32{rs[13]}} & crc_errors)                                |
                     ({32{rs[14]}} & {31'd0, tx_enable})                        |
                     ({32{rs[15]}} & {16'd0, tx_fifo_fill})                     |
                     ({32{rs[16]}} & tx_trim)                                   |
                     ({32{rs[17]}} & raw_frames)                                |
                     ({32{rs[18]}} & other_frames)                              |
                     ({32{rs[19]}} & {ring_dropped, ring_frames})               |
                     ({32{rs[20]}} & cnt_gap_samples)                           |
                     ({32{rs[21]}} & cnt_resync_events)                         |
                     ({32{rs[22]}} & {20'd0, ring_wptr})                        |
                     ({32{rs[23]}} & index_lo_latch)                             |
                     ({32{rs[24]}} & {16'd0, index_hi_latch})                   |
                     // the loss counters, seen through the second snapshot word (LOSS_A to LOSS_D hold two 16-bit counters each, see the map above)
                     ({32{rs[25]}} & lsnap[159:128])                            |   // rx_seq
                     ({32{rs[26]}} & lsnap[191:160])                            |   // seq_lost
                     ({32{rs[27]}} & lsnap[127:96])                             |   // loss_a: code_frames, seq_restarts
                     ({32{rs[28]}} & lsnap[95:64])                              |   // loss_b: hl2_missing, len_errors
                     ({32{rs[29]}} & lsnap[63:32])                              |   // loss_c: overruns, drain_drops
                     ({32{rs[30]}} & lsnap[31:0]);                                  // loss_d: hl2_ovf, idx_drops
    end

endmodule
