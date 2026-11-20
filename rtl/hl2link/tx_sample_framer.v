// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Transmit sample framer: packs the radio's transmit samples into Ethernet frames for the
// Hermes-Lite 2 (docs/ARCHITECTURE.md 3.1 transmit path, 3.6; docs/rawfront/PROTOCOL.md 6.2).
//
// What it produces: every N transmit samples become one UDP datagram to port 1026 of the HL2,
// carried in an Ethernet frame. The frame is built from the destination MAC address through the
// last sample byte (the FCS at the end is appended by crc32_append.v behind the arbiter in
// hl2_link_tx_top.v). The 58 header bytes are 14 bytes of Ethernet header (destination MAC, source
// MAC, EtherType 0x0800 for IPv4), 20 bytes of IPv4 header (version and length, total length,
// time to live 64, protocol 17 for UDP, a header checksum, our IP and the HL2's IP), 8 bytes of
// UDP header (our source port, destination port 1026, length, checksum left at 0, which UDP over
// IPv4 allows), and 16 bytes of raw transmit header (PROTOCOL 6.2: magic 0x5A, version 1, flags,
// a zero byte, a 32-bit sequence number that counts frames, and the 48-bit index of the frame's
// first sample, which counts samples and is what the HL2's echo test uses). Then come the samples,
// packed like the received ones: two 12-bit samples `a` and `b` take three bytes, `a[11:4]`,
// `{a[3:0], b[11:8]}`, `b[7:0]`. With N = 5,970 the UDP payload is 16 + 8,955 bytes, which fits a
// 9,000-byte IP MTU (jumbo frames).
//
// Where it sits: tx_chain.v produces one sample per `pace` pulse of tx_rate_lock.v, and
// `in_sample` and `in_valid` carry them here. The frame leaves one byte per clock to whichever
// arbiter grants it the wire (hl2_link_tx_top.v, where it has priority over the CPU transmit
// queue).
//
// Clock domains:
//   clk_dsp (120 MHz): sample intake, packing of two samples into three bytes, and the safety mux.
//     When `cfg_tx_enable` is off or `cfg_trip` is on, the samples become zero within one sample
//     (docs/ARCHITECTURE.md 3.6 point 5), so a safety trip silences the transmitter at once, in
//     logic, without waiting for the firmware.
//   clk_tx (125 MHz, the lane's transmit clock): frame assembly (the headers and the IP header
//     checksum) and the byte-serial output to the arbiter, one byte per clock, gapless from the
//     first header byte through the last payload byte.
//
// Clock crossing: the packing is done in pairs (two samples to three bytes) in clk_dsp, but the
// FIFO to clk_tx carries whole PAIRS as one 24-bit word and not individual bytes. A byte-wide
// FIFO would need a write in every clk_dsp clock at the input's full burst rate, and also a
// dedicated three-clock drain grouping on the read side, for no benefit. Packing to 24 bits before
// the crossing removes that mismatch (one write per accepted pair, one read per emitted group of
// three wire bytes) without changing what crosses (cdc_sample_fifo.v explains how a FIFO crosses
// clocks).
//
// Frame cadence: this module counts samples and not bytes or time, to know when a frame's payload
// is ready. Every N accepted samples (N is even, PROTOCOL.md 5.1) are exactly 3N/2 bytes, so a
// single sample counter wrapping at N is enough to know that a complete payload has been written
// to the FIFO. That count crosses to clk_tx as a single toggle handshake pulse (cdc_word.v with
// W = 1) that drives a small credit counter: the frame state machine only starts sending once the
// credit is not zero, i.e. once the corresponding clk_dsp pulse is known to have landed. Since the
// FIFO is deep (`FIFO_AW`, 8,192 pairs, about 2.7 frames) compared to how far ahead of the drain
// the write side can get, the bytes are already in the FIFO well before the read side asks for
// them. `cnt_tx_fifo_overrun` counts the case in which more than three frames of credit pile up,
// which would mean the margin was too small and is expected to stay 0.

`timescale 1ns / 1ps

module tx_sample_framer #(
    parameter N       = 5970,   // PROTOCOL.md 6.2: samples per TX frame (fits a 9,000 B IP MTU)
    parameter FIFO_AW = 13      // byte-pair FIFO depth 2**13 = 8,192 pairs = 24,576 B ~= 2.7 frames
) (
    // -------- clk_dsp: paced sample intake --------
    input  wire        clk_dsp,       // 120 MHz
    input  wire        rst_dsp,       // synchronous reset for clk_dsp, active high

    input  wire [11:0] in_sample,     // tx_chain.v out_data in the full system (see header)
    input  wire        in_valid,      // tx_chain.v out_valid / tx_rate_lock.v pace

    input  wire        cfg_tx_enable, // firmware TX-permit register (clk_dsp domain)
    input  wire        cfg_trip,      // safety trip / over-temperature (clk_dsp domain)

    // -------- clk_tx: frame assembly --------
    input  wire        clk_tx,        // the lane's transmit clock, 125 MHz
    input  wire        rst_tx,        // synchronous reset for clk_tx, active high

    input  wire [47:0] cfg_my_mac,    // our MAC address
    input  wire [31:0] cfg_my_ip,     // our IPv4 address
    input  wire [15:0] cfg_my_port,   // our UDP source port
    input  wire [47:0] cfg_hl2_mac,   // the HL2's MAC address
    input  wire [31:0] cfg_hl2_ip,    // the HL2's IPv4 address

    output wire         req,           // a complete frame is staged and wants the wire
    input  wire         gnt,           // arbiter grants this cycle onward (until the frame ends)
    output reg  [7:0]  tx_data,        // content byte (Ethernet header through the last sample
                                       // byte, but NOT the FCS: hl2_link_tx_top.v's crc32_append
                                       // appends that once tx_enable_content drops)
    output reg          tx_enable_content,   // high for exactly the bytes of the frame

    output reg  [31:0] cnt_tx_frames,    // frames sent
    output reg  [31:0] cnt_tx_fifo_overrun   // diagnostic: credit arrived while already >0 twice
                                             // over (would mean the FIFO margin was too small --
                                             // see the module header; expected to stay 0
) /* synthesis syn_srlstyle = "registers" */;

    localparam PAIRS      = N / 2;                 // N is even (PROTOCOL.md 5.1)
    localparam HDR_BYTES  = 58;                     // 14 Ethernet + 20 IP + 8 UDP + 16 raw TX
    localparam PAY_BYTES  = 3 * PAIRS;              // = 3*N/2
    // Explicitly 16 bits: an unsized localparam expression defaults to a 32-bit integer, which
    // would silently widen the big concatenation of the header build below by 16 bits per
    // occurrence (two occurrences) and shift every earlier field out of place.
    localparam [15:0] UDP_LEN    = 16'd8 + 16'd16 + PAY_BYTES[15:0];
    localparam [15:0] IP_TOTLEN  = 16'd20 + UDP_LEN;

    // =====================================================================
    // clk_dsp: sample intake, safety mux, packing of 2 samples into 3 bytes, pair FIFO write.
    // The first sample of a pair is held until the second one arrives, then the two are written
    // together as one 24-bit word.
    wire [11:0] safe_sample = (cfg_tx_enable && !cfg_trip) ? in_sample : 12'h000;

    reg         have_first = 1'b0;        // the first sample of a pair is being held
    reg [11:0]  first_samp = 12'h000;
    reg [23:0]  pair_word  = 24'h000000;  // the two samples as three bytes
    reg         pair_wr    = 1'b0;        // write pair_word to the FIFO

    reg [15:0]  pair_cnt      = 16'd0;   // 0..PAIRS-1
    reg         frame_done_ds = 1'b0;    // one clk_dsp cycle per completed frame's worth of pairs

    always @(posedge clk_dsp) begin
        pair_wr       <= 1'b0;
        frame_done_ds <= 1'b0;
        if (rst_dsp) begin
            have_first <= 1'b0;
            pair_cnt   <= 16'd0;
        end else if (in_valid) begin
            if (!have_first) begin
                first_samp <= safe_sample;
                have_first <= 1'b1;
            end else begin
                // PROTOCOL.md 5.2: a[11:4], {a[3:0],b[11:8]}, b[7:0], transmitted MSB-byte first
                pair_word  <= {first_samp[11:4], first_samp[3:0], safe_sample[11:8], safe_sample[7:0]};
                pair_wr    <= 1'b1;
                have_first <= 1'b0;
                if (pair_cnt == PAIRS[15:0] - 16'd1) begin
                    pair_cnt      <= 16'd0;
                    frame_done_ds <= 1'b1;
                end else begin
                    pair_cnt <= pair_cnt + 16'd1;
                end
            end
        end
    end

    wire fifo_wr_full;
    wire [23:0] fifo_rd_data;
    wire        fifo_rd_valid, fifo_rd_empty;
    wire        fifo_rd_en;

    cdc_sample_fifo #(.W(24), .AW(FIFO_AW)) pair_fifo_i (
        .wr_clk (clk_dsp), .wr_rst(rst_dsp), .wr_en(pair_wr), .wr_data(pair_word), .wr_full(fifo_wr_full),
        .rd_clk (clk_tx),  .rd_rst(rst_tx),  .rd_en(fifo_rd_en), .rd_data(fifo_rd_data),
        .rd_valid(fifo_rd_valid), .rd_empty(fifo_rd_empty)
    );

    // frame_done_ds -> clk_tx: a single toggle handshake bit (cdc_word.v), not the pair data
    // itself. See the module header for why a bare pulse is enough here.
    wire        frame_done_tx_valid;
    wire        unused_qb;
    cdc_word #(.W(1)) frame_done_cdc_i (
        .clk_a(clk_dsp), .d_a(1'b1), .send_a(frame_done_ds),
        .clk_b(clk_tx),  .q_b(unused_qb), .valid_b(frame_done_tx_valid)
    );

    // =====================================================================
    // clk_tx: credit, frame assembly, byte-serial emission.
    // `credit` counts frames whose payload is complete in the FIFO and not yet sent (at most 3).
    reg [1:0] credit = 2'd0;

    // States: IDLE (waiting for credit and a grant), HDR (sending the 58 header bytes), PAYLOAD
    // (three bytes per FIFO word). ST_DRAIN2 and ST_DRAIN3 are not used.
    localparam ST_IDLE = 3'd0, ST_HDR = 3'd1, ST_PAYLOAD = 3'd2, ST_DRAIN2 = 3'd3, ST_DRAIN3 = 3'd4;
    reg [2:0]  state = ST_IDLE;

    reg [463:0] hdr_bytes = 464'd0;   // HDR_BYTES*8 = 464 bits, built once per frame
    reg [5:0]   hdr_idx   = 6'd0;     // 0..57

    reg [15:0]  pay_word_idx = 16'd0; // 0..PAIRS-1 (which 24-bit word)
    reg [1:0]   byte_phase   = 2'd0;  // 0,1,2 within the current word
    reg [23:0]  cur_word     = 24'd0; // the word being sent, held for its second and third byte

    reg [31:0]  tx_seq       = 32'd0;    // sequence number of the next frame
    reg [47:0]  tx_first_idx = 48'd0;    // index of the next frame's first sample

    assign req       = (state == ST_IDLE) && (credit != 2'd0);
    assign fifo_rd_en = (state == ST_HDR && hdr_idx == HDR_BYTES-1) ||
                        (state == ST_PAYLOAD && byte_phase == 2'd2 && pay_word_idx != PAIRS[15:0]-16'd1);

    // ---- IP header checksum (standard one's-complement sum, checksum field held at 0) ----
    // The IPv4 header checksum is the one's complement of the 16-bit one's-complement sum of the
    // ten 16-bit words of the header, with the checksum field itself counted as zero. A carry out
    // of bit 15 is added back in at the bottom, which is the "fold" below. This function is the
    // plain one-clock form, and the pipeline below computes the same value in several clocks.
    function [15:0] ip_checksum(input [31:0] my_ip, input [31:0] hl2_ip, input [15:0] totlen);
        reg [19:0] sum;   // 10 terms of at most 16'hffff each: fits comfortably in 20 bits
        begin
            sum = 20'h45_00 + {4'h0, totlen} + 20'h0 + 20'h0 + 20'h40_11 + 20'h0
                + {4'h0, my_ip[31:16]} + {4'h0, my_ip[15:0]}
                + {4'h0, hl2_ip[31:16]} + {4'h0, hl2_ip[15:0]};
            sum = {4'h0, sum[15:0]} + {16'h0, sum[19:16]};        // fold once
            sum = {4'h0, sum[15:0]} + {16'h0, sum[19:16]};        // fold any carry from the fold
            ip_checksum = ~sum[15:0];
        end
    endfunction

    // The checksum over four clocks, from the settings. They change only when the firmware writes
    // them, so a frame built in the few clocks after a change carries a wrong checksum once. In one
    // clock together with the header build it would be 19 logic levels, which does not fit in a
    // 125 MHz clock. 0x4500 is the version, header length and type of service word, 0x4011 the time
    // to live (64) and protocol (17) word, and the identification and flags words are zero.
    reg [19:0] cs_a = 20'd0, cs_b = 20'd0, cs_c = 20'd0;
    reg [16:0] cs_d = 17'd0;
    reg [15:0] ip_csum = 16'd0;
    always @(posedge clk_tx) begin
        cs_a    <= 20'h45_00 + {4'h0, IP_TOTLEN} + 20'h40_11 + {4'h0, cfg_my_ip[31:16]} + {4'h0, cfg_my_ip[15:0]};
        cs_b    <= {4'h0, cfg_hl2_ip[31:16]} + {4'h0, cfg_hl2_ip[15:0]};
        cs_c    <= cs_a + cs_b;
        cs_d    <= {1'b0, cs_c[15:0]} + {13'd0, cs_c[19:16]};                 // fold once
        ip_csum <= ~(cs_d[15:0] + {15'd0, cs_d[16]});                         // fold the carry of the fold
    end
    // The header byte that goes out, read one clock ahead into a register. Picking it out of the
    // header in the clock that also feeds the CRC would be a 58-to-1 selection of 10 logic levels
    // behind a net of 135 loads.
    reg  [7:0] hdr_byte = 8'd0;
    // hdr_idx + 1 is kept in a register of its own, because the adder in front of the 58-to-1
    // selection is too slow for 125 MHz, and it has a fan-out limit
    reg  [5:0] hdr_nx /* synthesis syn_maxfan = 10000 */;
    // The 58-to-1 selection of the next header byte is done in two steps. `hdr_q` holds the 8 bytes
    // (64 bits) that contain byte `hdr_nx`, and the next group is read into it in the clock that
    // fetches the last byte of the group, so the byte comes out of an 8-to-1 selection and not out
    // of the whole 464 bits.
    reg [63:0] hdr_q = 64'd0;
    wire [511:0] hdr_pad = {hdr_bytes, 48'd0};
    wire [2:0]   hdr_grp_n = hdr_nx[5:3] + 3'd1;
    // The header as built once per frame: the field order is the order of the bytes on the wire.
    wire [463:0] hdr_new = {
        cfg_hl2_mac, cfg_my_mac, 16'h0800,                          // Ethernet (14)
        8'h45, 8'h00, IP_TOTLEN, 16'h0000, 16'h0000, 8'd64, 8'd17,   // IP (14)
        ip_csum,                                                     // IP checksum (2)
        cfg_my_ip, cfg_hl2_ip,                                       // IP addrs (8)
        cfg_my_port, 16'd1026, UDP_LEN, 16'h0000,                    // UDP (8)
        8'h5A, 8'h01, 8'h00, 8'h00, tx_seq, tx_first_idx, N[15:0]    // raw TX hdr (16)
    };

    always @(posedge clk_tx) begin
        if (rst_tx) begin
            credit        <= 2'd0;
            state         <= ST_IDLE;
            tx_seq        <= 32'd0;
            tx_first_idx  <= 48'd0;
            cnt_tx_frames <= 32'd0;
            cnt_tx_fifo_overrun <= 32'd0;
            tx_enable_content   <= 1'b0;
        end else begin
            // Credit from clk_dsp: one more complete frame is in the FIFO. A fourth one waiting
            // is the overrun case (see the header) and is counted instead of added.
            if (frame_done_tx_valid) begin
                if (credit == 2'd3) cnt_tx_fifo_overrun <= cnt_tx_fifo_overrun + 32'd1;
                else credit <= credit + 2'd1;
            end

            case (state)
                ST_IDLE: begin
                    tx_enable_content <= 1'b0;
                    hdr_idx           <= 6'd0;
                    hdr_nx            <= 6'd1;
                    // On a grant, the header is built and header byte 0 is made ready.
                    if (req && gnt) begin
                        credit <= credit - 2'd1;
                        hdr_bytes <= hdr_new;
                        hdr_q     <= hdr_new[463:400];               // header bytes 0 to 7
                        hdr_byte          <= cfg_hl2_mac[47:40];     // header byte 0
                        tx_enable_content <= 1'b1;
                        state             <= ST_HDR;
                    end
                end

                ST_HDR: begin
                    if (hdr_idx == HDR_BYTES-1) begin
                        state        <= ST_PAYLOAD;
                        pay_word_idx <= 16'd0;
                        byte_phase   <= 2'd0;
                    end else begin
                        hdr_idx  <= hdr_nx;
                        hdr_nx   <= hdr_nx + 6'd1;
                        hdr_byte <= hdr_q[63 - 8*hdr_nx[2:0] -: 8];
                        if (hdr_nx[2:0] == 3'd7) hdr_q <= hdr_pad[511 - 64*hdr_grp_n -: 64];
                    end
                end

                // Payload: every FIFO word of 24 bits goes out as three bytes, high byte first.
                // The word is read in the clock after `fifo_rd_en` (the FIFO has one clock of
                // read latency), so the first byte of a word comes straight from `fifo_rd_data`
                // and the other two from `cur_word`.
                ST_PAYLOAD: begin
                    if (byte_phase == 2'd0) begin
                        cur_word   <= fifo_rd_data;   // valid: rd_en issued exactly 1 cycle ago
                        byte_phase <= 2'd1;
                    end else if (byte_phase == 2'd1) begin
                        byte_phase <= 2'd2;
                    end else begin // byte_phase == 2
                        if (pay_word_idx == PAIRS[15:0]-16'd1) begin
                            tx_enable_content <= 1'b0;
                            tx_seq            <= tx_seq + 32'd1;
                            tx_first_idx      <= tx_first_idx + {32'd0, N[15:0]};
                            cnt_tx_frames     <= cnt_tx_frames + 32'd1;
                            state             <= ST_IDLE;
                        end else begin
                            pay_word_idx <= pay_word_idx + 16'd1;
                            byte_phase   <= 2'd0;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    // Output byte mux (combinational: what `tx_data` shows in this clock, together with
    // `tx_enable_content` above, which is a plain register following the state machine).
    always @* begin
        case (state)
            ST_HDR:     tx_data = hdr_byte;
            ST_PAYLOAD: case (byte_phase)
                            2'd0: tx_data = fifo_rd_data[23:16];  // this cycle's freshly-read word
                            2'd1: tx_data = cur_word[15:8];
                            default: tx_data = cur_word[7:0];
                        endcase
            default: tx_data = 8'h00;
        endcase
    end

endmodule
