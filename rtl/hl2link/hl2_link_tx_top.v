// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// HL2 link transmit path, top level (docs/ARCHITECTURE.md 3.1 transmit path and 3.6): everything
// between the radio's transmit samples and the bytes that the SFP lane's PCS sends to the
// Hermes-Lite 2 (docs/H2_LINK_TX.md).
//
// What goes out on this link: the HL2 plays one transmit sample per tick of its own 76.8 MHz ADC
// clock, so the radio has to send it a continuous stream of 12-bit samples at exactly that rate,
// packed into UDP datagrams of N samples each (docs/rawfront/PROTOCOL.md section 6.2), plus the
// occasional control datagram that the firmware prepares (discovery, start and stop, register
// writes). The HL2's clock differs from ours by a few parts per million, so the sample rate is
// locked to the receive side (tx_rate_lock.v).
//
// The pieces, in the order the data travels:
//   tx_rate_lock.v      one transmit sample per received sample, trimmed by the HL2's reported TX
//                       FIFO fill (clk_dsp). It produces `pace_out`, which the chip top level
//                       connects to the transmit chain's `pace` input; the chain's output sample
//                       and valid then come back in through `in_sample` and `in_valid`.
//   tx_sample_framer.v  sample packing and the Ethernet, IP and UDP headers for each frame
//                       (clk_dsp to clk_tx).
//   cpu_tx_queue.v      control frames that the firmware queued (clk_tx), lower priority.
//   crc32_append.v      the FCS (frame check sequence) of whichever producer was granted the wire.
//   gmii_tx_out.v       preamble, start-of-frame delimiter and inter-frame gap, giving the bytes
//                       of transceiver lane 0's PCS (rtl/sfp/sfp_phy.v). `clk_tx` is the lane's
//                       transmit word clock (sfp_txc), 125 MHz (docs/HL2_SFP.md).
//
// Arbitration: the sample framer has priority, with the CPU queue as the second source. A new
// frame is only granted while the wire is completely idle, which means that no content or FCS is
// still streaming (`appended_enable`) and that gmii_tx_out.v reports idle (`phy_active` low,
// meaning that its own inter-frame gap has elapsed). So the two producers never have to know
// about each other, or about the gap that the Ethernet standard demands between frames.
//
// The register interface here is a flat list of fields and not a bus slave, in the same way as
// hl2_link_rx_top.v. The register block generated from hw/regmap/ wraps it.

`timescale 1ns / 1ps

module hl2_link_tx_top #(
    parameter N          = 5970,   // samples per frame (5,970 fits a 9,000-byte IP MTU, 970 fits 1,500)
    parameter FIFO_AW    = 13,     // address width of the framer's sample FIFO, 2**13 = 8,192 samples
    parameter CPU_TX_AW  = 12      // address width of the CPU queue, 2**12 = 4 KB
) (
    // -------- clk_dsp: paced sample production --------
    input  wire        clk_dsp,
    input  wire        rst_dsp,

    input  wire        rx_adc_valid,       // hl2_link_rx_top.v samp_out_valid
    input  wire [15:0] fifo_fill,          // hl2_link_rx_top.v raw_tx_fifo_fill
    input  wire        fifo_fill_valid,    // one clk_dsp pulse per new fill value

    output wire        pace_out,           // feed this to tx_chain.v `pace` (see module header)
    input  wire [11:0] in_sample,          // tx_chain.v out_data, paced by `pace_out` above
    input  wire        in_valid,           // tx_chain.v out_valid (== pace_out once wired)

    input  wire        cfg_tx_enable,      // firmware TX-permit register
    input  wire        cfg_trip,           // safety trip / over-temperature

    output wire [31:0] cnt_tx_skip,        // samples skipped by the rate lock (the HL2's FIFO was too full)
    output wire [31:0] cnt_tx_insert,      // samples repeated by the rate lock (the HL2's FIFO was too empty)
    output wire [31:0] cnt_tx_fill_updates, // fill reports received from the HL2

    // -------- clk_tx: frame assembly, arbitration, bytes to the lane's PCS --------
    input  wire        clk_tx,             // the lane's transmit word clock, 125 MHz
    input  wire        rst_tx,             // synchronous reset for the clk_tx domain, active high

    input  wire [47:0] cfg_my_mac,         // our MAC address
    input  wire [31:0] cfg_my_ip,          // our IPv4 address
    input  wire [15:0] cfg_my_port,        // our UDP source port
    input  wire [47:0] cfg_hl2_mac,        // the HL2's MAC address (learned from its discovery reply)
    input  wire [31:0] cfg_hl2_ip,         // the HL2's IPv4 address

    // CPU transmit queue, firmware write port
    input  wire                    cq_wr_en,
    input  wire [CPU_TX_AW-1:0]    cq_wr_addr,
    input  wire [7:0]              cq_wr_data,
    input  wire                    cq_send_len_wr,
    input  wire [15:0]             cq_wr_len_in,
    output wire                     cq_busy,

    output wire [31:0] cnt_tx_frames,        // sample frames sent
    output wire [31:0] cnt_cq_frames,        // CPU queue frames sent
    output wire [31:0] cnt_tx_fifo_overrun,  // samples lost because the framer's FIFO was full

    input  wire        tx_link_up,         // the lane's PCS sends data (rtl/sfp/sfp_phy.v tx_link_up)
    output wire [7:0]  gmii_txd,           // byte to the PCS
    output wire        gmii_tx_en          // the byte is part of a frame (preamble through FCS)
) /* synthesis syn_srlstyle = "registers" */;

    // ---------------------------------------------------------------------
    // clk_dsp: rate lock
    tx_rate_lock rate_lock_i (
        .clk_dsp(clk_dsp), .rst_dsp(rst_dsp),
        .rx_adc_valid(rx_adc_valid),
        .fifo_fill(fifo_fill), .fifo_fill_valid(fifo_fill_valid),
        .pace(pace_out),
        .cnt_fill_updates(cnt_tx_fill_updates),
        .cnt_skip(cnt_tx_skip), .cnt_insert(cnt_tx_insert)
    );

    // ---------------------------------------------------------------------
    // Sample framer and CPU queue byte streams (before the FCS)
    wire        framer_req;
    reg         framer_gnt;
    wire [7:0]  framer_data;
    wire        framer_enable;

    tx_sample_framer #(.N(N), .FIFO_AW(FIFO_AW)) framer_i (
        .clk_dsp(clk_dsp), .rst_dsp(rst_dsp),
        .in_sample(in_sample), .in_valid(in_valid),
        .cfg_tx_enable(cfg_tx_enable), .cfg_trip(cfg_trip),
        .clk_tx(clk_tx), .rst_tx(rst_tx),
        .cfg_my_mac(cfg_my_mac), .cfg_my_ip(cfg_my_ip), .cfg_my_port(cfg_my_port),
        .cfg_hl2_mac(cfg_hl2_mac), .cfg_hl2_ip(cfg_hl2_ip),
        .req(framer_req), .gnt(framer_gnt),
        .tx_data(framer_data), .tx_enable_content(framer_enable),
        .cnt_tx_frames(cnt_tx_frames), .cnt_tx_fifo_overrun(cnt_tx_fifo_overrun)
    );

    wire        queue_req;
    reg         queue_gnt;
    wire [7:0]  queue_data;
    wire        queue_enable;

    cpu_tx_queue #(.AW(CPU_TX_AW)) queue_i (
        .clk_tx(clk_tx), .rst_tx(rst_tx),
        .wr_en(cq_wr_en), .wr_addr(cq_wr_addr), .wr_data(cq_wr_data),
        .send_len_wr(cq_send_len_wr), .wr_len_in(cq_wr_len_in), .busy(cq_busy),
        .req(queue_req), .gnt(queue_gnt),
        .tx_data(queue_data), .tx_enable_content(queue_enable),
        .cnt_tx_frames(cnt_cq_frames)
    );

    // ---------------------------------------------------------------------
    // Arbiter (clk_tx): the sample framer has priority, and a grant is only given while the wire
    // is completely idle. `cur_is_framer` remembers who got the grant, and selects whose bytes go
    // on to the FCS stage.
    wire        phy_active;
    wire        appended_enable;

    wire wire_idle = !appended_enable && !phy_active;

    always @* begin
        framer_gnt = 1'b0;
        queue_gnt  = 1'b0;
        if (wire_idle) begin
            if (framer_req)      framer_gnt = 1'b1;
            else if (queue_req)  queue_gnt  = 1'b1;
        end
    end

    reg cur_is_framer = 1'b0;
    always @(posedge clk_tx) begin
        if (framer_gnt)     cur_is_framer <= 1'b1;
        else if (queue_gnt) cur_is_framer <= 1'b0;
    end

    wire [7:0] mux_data   = cur_is_framer ? framer_data   : queue_data;
    wire       mux_enable = cur_is_framer ? framer_enable : queue_enable;

    // ---------------------------------------------------------------------
    // Shared FCS append and the bytes to the PCS
    wire [7:0] appended_data;

    crc32_append crc_append_i (
        .clk(clk_tx), .rst(rst_tx),
        .in_data(mux_data), .in_enable(mux_enable),
        .out_data(appended_data), .out_enable(appended_enable)
    );

    gmii_tx_out gmii_tx_i (
        .clk(clk_tx),
        .data(appended_data), .tx_enable(appended_enable), .link_up(tx_link_up),
        .active(phy_active),
        .gmii_txd(gmii_txd), .gmii_tx_en(gmii_tx_en)
    );

endmodule
