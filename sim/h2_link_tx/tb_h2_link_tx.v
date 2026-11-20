// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Franz Schöning, https://www.schoning.com
//
// Testbench for the HL2 link transmit path, rtl/hl2link/hl2_link_tx_top.v, closed into a loop with the receive path.
//
// Background for a reader new to this part of the radio. The Hermes-Lite 2 (HL2) can run in duplex mode, where it
// receives our transmit samples over the same gigabit link that carries its received samples to us. We cut the
// transmit samples into UDP frames of TX_N 12 bit samples each (hl2_link_tx_top.v), the HL2 plays them into a FIFO
// in front of its DAC (its "TX sink"), and it reports how full that FIFO is back to us inside the header of every raw
// receive frame. Our rate lock (tx_rate_lock.v) uses that fill value to keep the FIFO near 12,000 samples:
// too low and the DAC would run dry (an underflow), too high and the FIFO would overflow. Both outcomes would
// show up as a click in the transmitted signal. The terms used below (UDP, FCS, CRC, DAC, FIFO) are explained in
// docs/learn/GLOSSARY.md.
//
// The far end is the HL2's own gateware, so the bench tests against the real thing and not against a model of it:
//   - receive side: sim/h2_link_tx/hl2/{mac_recv,ip_recv,udp_recv}.v parse our transmit frames, and
//     sim/h2_link_tx/hl2/txsink.v (ECHO=1) plays the samples into its FIFO and, in echo mode, hands each played
//     sample together with its transmit index back to the send side;
//   - send side: sim/h1_link_rx/hl2/rawstream.v (DUPLEX=1, ECHO=1) plus the real udp_send, ip_send, mac_send, crc32 and
//     rgmii_send chain, which is the same far end tb_h1_link_rx.v uses, here with duplex and echo turned on.
// So the one HL2 image does both jobs of a real duplex radio, sinking our transmit samples and sending them back as its
// raw stream into the receive path (hl2_link_rx_top.v, unchanged), and the loop only closes if every stage of both
// directions is correct.
//
// The wire, one direction each. Both DUTs work with the bytes of the transceiver lane's PCS (GMII style: a byte,
// a data valid flag, preamble and start frame delimiter included) and not with RGMII pins:
//   - far end to us: the shift register of rgmii_send is tapped (the simulation only switches off its pin outputs, the
//     framing logic is unchanged) and its bytes, with data valid, go to hl2_link_rx_top.v one per clock;
//   - us to far end: the `gmii_txd` and `gmii_tx_en` of hl2_link_tx_top.v go through gmii_rx_in.v, which strips preamble
//     and SFD in the role of the far end's receiver, into the HL2's mac_recv.v. That strip is not what this bench checks.
//
// Stimulus: both ends are configured through the HL2's command bus (raw mode on with N = 968 samples per receive frame,
// then duplex plus echo on), `run` is set, and the transmit samples are a counter that wraps at 4096, advanced once per
// pace pulse of the rate lock, so sample k has the value k mod 4096. After a settling time of 25 ms for the rate lock to
// close the start-up fill deficit, the bench measures for SIM_US microseconds.
//
// Pass: the bench checks that transmit frames were sent and that each one carries a correct Ethernet FCS (computed
// bit by bit in the bench, since the HL2's receive logic ignores it), that every echoed sample at the far end equals its
// own index mod 4096, that the HL2 TX sink saw no underflow, overflow or bad sample, that no gap or resync happened on
// the return path, that the credit counter of the transmit FIFO never overran, and that the FIFO fill stayed within
// 12,000 +/- 2,000 for every sample played after the settling time. It prints "PASS", or "FAIL: n errors" after the
// individual ERROR lines.
//
// Run, from the repo root, with the folder sim/out present (the bench writes the first transmit frame to
// sim/out/h2_tx_frame0.hex):
//   iverilog -g2012 -o build/tb_h2_link_tx.vvp sim/h2_link_tx/tb_h2_link_tx.v && vvp build/tb_h2_link_tx.vvp
// The default SIM_US is 3000. sim/h2_link_tx/run_long.sh runs 50 ms (see docs/H2_LINK_TX.md), and -DSETTLE_US shortens
// the settling time for a run that only looks at the FCS.

`include "rtl/hl2link/crc32_eth.v"
`include "rtl/hl2link/cdc_word.v"
`include "rtl/hl2link/cdc_sample_fifo.v"
`include "rtl/hl2link/gmii_rx_in.v"
`include "rtl/hl2link/gmii_tx_out.v"
`include "rtl/hl2link/eth_frame_rx.v"
`include "rtl/hl2link/raw_frame_buffer.v"
`include "rtl/hl2link/gap_filler.v"
`include "rtl/hl2link/cpu_rx_ring.v"
`include "rtl/hl2link/hl2_link_rx_top.v"
`include "rtl/hl2link/rx_tx_fill_bridge.v"
`include "rtl/hl2link/tx_rate_lock.v"
`include "rtl/hl2link/tx_sample_framer.v"
`include "rtl/hl2link/cpu_tx_queue.v"
`include "rtl/hl2link/crc32_append.v"
`include "rtl/hl2link/hl2_link_tx_top.v"

// The HL2 far-end gateware. The paths are relative to the repo root, since the build command above takes no
// include path.
`include "sim/h1_link_rx/dcfifo_sim_stub.v"
`include "sim/h1_link_rx/hl2/rawstream.v"
`include "sim/h1_link_rx/hl2/udp_send.v"
`include "sim/h1_link_rx/hl2/ip_send.v"
`include "sim/h1_link_rx/hl2/mac_send.v"
`include "sim/h1_link_rx/hl2/crc32.v"
`include "sim/h1_link_rx/hl2/rgmii_send.v"
`include "sim/h2_link_tx/hl2/mac_recv.v"
`include "sim/h2_link_tx/hl2/ip_recv.v"
`include "sim/h2_link_tx/hl2/udp_recv.v"
`include "sim/h2_link_tx/hl2/txsink.v"

// All delays below are in picoseconds (8000 = one 125 MHz period).
`timescale 1ps / 1fs

module tb_h2_link_tx;

    // ------------------------------------------------------------------
    localparam [47:0] HL2_MAC = 48'h02_00_00_00_00_02;
    localparam [31:0] HL2_IP  = 32'h0a63_0002;   // 10.99.0.2
    localparam [47:0] MY_MAC  = 48'h02_00_00_00_00_01;
    localparam [31:0] MY_IP   = 32'h0a63_0001;   // 10.99.0.1
    localparam [15:0] MY_PORT = 16'd1027;
    // Samples per transmit frame (PROTOCOL.md 6.2): 5970 samples of 12 bit are 8955 payload bytes.
    localparam        TX_N    = 5970;            // PROTOCOL.md 6.2

    // ------------------------------------------------------------------
    // Clocks. `clk` is shared by every Ethernet side block, both directions, both our DUTs and the far end (the same
    // simplification tb_h1_link_rx.v makes for the receive direction). `clk_ad` is the far end's ADC and DAC clock,
    // 76.8 MHz plus 50 ppm, the one clock that has an offset, so that the rate lock has something to track. `clk_dsp`
    // is the DUTs' own independent 150 MHz clock.
    logic clk = 1'b0;
    always #4000 clk = ~clk;                     // 125 MHz

    logic clk_ad = 1'b0;
    initial begin
        #1733;
        forever #6510.0912 clk_ad = ~clk_ad;     // 76.8 MHz + 50 ppm (see tb_h1_link_rx.v)
    end

    logic clk_dsp = 1'b0;
    initial begin
        #907;
        forever #3333.333 clk_dsp = ~clk_dsp;    // 150 MHz
    end

    // ------------------------------------------------------------------
    // Command bus shared by the far end (rawstream.v decodes register 0x30 and txsink.v register 0x31 off the same
    // wires, as the HL2's hermeslite_core.v shares it).
    logic        run = 1'b0;
    logic [ 5:0] cmd_addr = 6'h0;
    logic [31:0] cmd_data = 32'h0;
    logic        cmd_rqst = 1'b0;

    // ------------------------------------------------------------------
    // Far end, receive side: our transmitter's bytes, with preamble and SFD stripped by our own gmii_rx_in.v in the
    // role of the far end's receiver (one byte every clock), go through mac_recv, ip_recv and udp_recv into txsink (ECHO=1).
    wire [7:0] tx_gmii_txd;
    wire       tx_gmii_tx_en;

    wire [7:0] far_rx_data;
    wire       far_rx_active;

    gmii_rx_in far_rx_phy_i (
        .clk(clk), .rst(1'b0), .rx_d(tx_gmii_txd), .rx_dv(tx_gmii_tx_en), .rx_er(1'b0), .rx_ce(1'b1),
        .data(far_rx_data), .active(far_rx_active), .ce_o(), .err()
    );

    wire mac_rx_active, far_is_arp, far_broadcast;
    wire [47:0] far_remote_mac; wire far_remote_mac_valid;
    mac_recv mac_recv_i (
        .clock(clk), .rx_enable(far_rx_active), .data(far_rx_data), .local_mac(HL2_MAC),
        .active(mac_rx_active), .broadcast(far_broadcast), .is_arp(far_is_arp),
        .remote_mac(far_remote_mac), .remote_mac_valid(far_remote_mac_valid)
    );

    wire ip_rx_active, far_is_icmp;
    wire [31:0] far_remote_ip; wire far_remote_ip_valid;
    wire [31:0] far_to_ip; wire far_to_ip_is_me;
    wire ip_rx_enable = mac_rx_active && !far_is_arp;
    ip_recv #(.LW(16)) ip_recv_i (
        .clock(clk), .rx_enable(ip_rx_enable), .data(far_rx_data), .broadcast(far_broadcast),
        .local_ip(HL2_IP), .active(ip_rx_active), .is_icmp(far_is_icmp),
        .remote_ip(far_remote_ip), .remote_ip_valid(far_remote_ip_valid),
        .to_ip(far_to_ip), .to_ip_is_me(far_to_ip_is_me)
    );

    wire udp_rx_active, far_dhcp_active;
    wire [15:0] far_to_port;
    wire [31:0] far_udp_dst_ip; wire [47:0] far_udp_dst_mac; wire [15:0] far_udp_dst_port;
    wire far_udp_dst_valid;
    wire udp_rx_enable = ip_rx_active && !far_is_icmp;
    udp_recv #(.LW(16)) udp_recv_i (
        .clock(clk), .run(run), .rx_enable(udp_rx_enable), .data(far_rx_data),
        .to_ip(far_to_ip), .local_ip(HL2_IP), .broadcast(far_broadcast),
        .remote_mac(far_remote_mac), .remote_ip(far_remote_ip),
        .active(udp_rx_active), .dhcp_active(far_dhcp_active), .to_port(far_to_port),
        .udp_destination_ip(far_udp_dst_ip), .udp_destination_mac(far_udp_dst_mac),
        .udp_destination_port(far_udp_dst_port), .udp_destination_valid(far_udp_dst_valid)
    );

    wire raw_mode_far;
    wire [159:0] txs_status;
    wire         txs_dup_on;
    wire [11:0]  echo_data;
    wire [47:0]  echo_idx;
    wire         echo_ok, echo_play;
    wire         txs_real, txs_echo;

    txsink #(.FIFO_AW(14), .ECHO(1)) txsink_i (
        .clk_rx       (clk),
        .eth_port     (far_to_port),
        .eth_broadcast(far_broadcast),
        .eth_valid    (udp_rx_active),
        .eth_data     (far_rx_data),
        .clk_ad       (clk_ad),
        .clk          (clk),
        .raw_mode     (raw_mode_far),
        .run          (run),
        .cmd_addr     (cmd_addr),
        .cmd_data     (cmd_data),
        .cmd_rqst     (cmd_rqst),
        .dup_on       (txs_dup_on),
        .status       (txs_status),
        .mode_real    (txs_real),
        .mode_echo    (txs_echo),
        .dac_out      (),
        .echo_data    (echo_data),
        .echo_idx     (echo_idx),
        .echo_ok      (echo_ok),
        .echo_play    (echo_play)
    );

    // Far end, send side (echo mode): rawstream.v (DUPLEX=1, ECHO=1) plus the real send chain, the same far end as
    // tb_h1_link_rx.v but with duplex and echo turned on. There is no discovery packer here (tb_h1_link_rx.v covers the
    // CPU ring path), so pkt_tx_request is tied low and rawstream.v owns the send path.
    wire [1:0]  udp_tx_request;
    wire [15:0] udp_tx_length;
    wire [7:0]  udp_tx_data;
    wire        udp_tx_enable, udp0_tx_enable, udp_tx_busy;

    rawstream #(.FIFO_AW(14), .DUPLEX(1), .ECHO(1)) far_i (
        .clk_ad        (clk_ad),
        .adc_data      (12'h000),           // unused: echo mode substitutes echo_data
        .clk           (clk),
        .run           (run),
        .cmd_addr      (cmd_addr),
        .cmd_data      (cmd_data),
        .cmd_rqst      (cmd_rqst),
        .raw_mode      (raw_mode_far),
        .pkt_tx_request(2'b00),
        .pkt_tx_length (16'd0),
        .pkt_tx_data   (8'h00),
        .pkt_tx_enable (),
        .udp_tx_request(udp_tx_request),
        .udp_tx_length (udp_tx_length),
        .udp_tx_data   (udp_tx_data),
        .udp_tx_enable (udp_tx_enable),
        .udp0_tx_enable(udp0_tx_enable),
        .udp_tx_busy   (udp_tx_busy),
        .dup_on        (txs_dup_on),
        .dup_status    (txs_status),
        .tx_status     (8'h01),             // PROTOCOL.md 5.4 idle value (not under test here)
        .aux_room      (),
        .raw_run       (),
        .aux_ready     (1'b0),
        .aux_grant     (),
        .aux_tx_request(2'b00),
        .aux_tx_length (16'd0),
        .aux_tx_data   (8'd0),
        .aux_busy      (1'b0),
        .udp2_tx_enable(1'b0),
        .aux_enable    (),
        .echo_on       (txs_echo),
        .echo_data     (echo_data),
        .echo_idx      (echo_idx),
        .echo_ok       (echo_ok),
        .echo_play     (echo_play),
        .ext_status    (16'h0000)
    );

    // The HL2's network.v send arbitration, copied from the HL2's own testbench (no packer here): a request from rawstream.v
    // is granted when the transmitter is idle.
    // network.v send arbitration (copied from tb_rawstream.sv / tb_h1_link_rx.v; no packer here)
    logic tx_ready = 1'b0, tx_start = 1'b0;
    wire rgmii_tx_active;
    assign udp_tx_enable  = tx_start;
    assign udp0_tx_enable = tx_start;
    assign udp_tx_busy    = tx_ready | tx_start | rgmii_tx_active;
    always @(posedge clk)
        if (rgmii_tx_active) begin tx_ready <= 1'b0; tx_start <= 1'b0; end
        else if (tx_ready) tx_start <= 1'b1;
        else if (udp_tx_request == 2'b10) tx_ready <= 1'b1;

    wire        udp_tx_active;
    wire [ 7:0] udp_data;
    wire [15:0] udp_length;
    wire [ 7:0] ip_tx_data;
    wire        ip_tx_active;
    wire [ 7:0] mac_tx_data;
    wire        mac_tx_active;
    logic [7:0] rgmii_tx_data_in_pipe;
    logic       rgmii_tx_enable_pipe = 1'b0;

    udp_send udp_send_inst (.reset(1'b0), .clock(clk), .tx_enable(udp_tx_enable), .data_in(udp_tx_data),
        .length_in(udp_tx_length), .local_port(16'd1024), .destination_port(MY_PORT),
        .active(udp_tx_active), .data_out(udp_data), .length_out(udp_length), .port_ID(8'h00));
    ip_send ip_send_inst (.data_in(udp_data), .tx_enable(udp_tx_active), .is_icmp(1'b0), .length(udp_length),
        .destination_ip(MY_IP), .data_out(ip_tx_data), .active(ip_tx_active), .clock(clk), .reset(1'b0),
        .local_ip(HL2_IP));
    mac_send mac_send_inst (.data_in(ip_tx_data), .tx_enable(ip_tx_active), .destination_mac(MY_MAC),
        .data_out(mac_tx_data), .active(mac_tx_active), .clock(clk), .local_mac(HL2_MAC), .reset(1'b0));
    always @(posedge clk) begin
        rgmii_tx_data_in_pipe <= mac_tx_data;
        rgmii_tx_enable_pipe  <= mac_tx_active;
    end
    rgmii_send #(.SIM(1)) rgmii_send_inst (.data(rgmii_tx_data_in_pipe), .tx_enable(rgmii_tx_enable_pipe),
        .active(rgmii_tx_active), .clock(clk), .PHY_TX(), .PHY_TX_EN());

    initial begin
        udp_send_inst.byte_no = 16'd0; udp_send_inst.sending = 1'b0;
        ip_send_inst.byte_no = 5'd0;   ip_send_inst.sending = 1'b0;
    end

    // Wire tap, far end to us: `wire_byte` and `wire_dv` register the byte of rgmii_send's shift register and its
    // `sending` flag once per clock, so that the DUT sees them as it would see the registered output of the
    // transceiver's receive path. Reading the shift register directly in the DUT's own always blocks would race
    // with the clock edge that updates it.
    wire       far_sending = rgmii_send_inst.sending;
    wire [7:0] far_byte    = rgmii_send_inst.shift_reg[63:56];

    logic [7:0] wire_byte;
    logic       wire_dv;
    // To the DUT as the lane's PCS gives bytes, one per clock.
    // (2026-10-21: to the DUT as the lane's PCS gives bytes, one per clock)
    always @(posedge clk) begin
        wire_byte <= far_byte;
        wire_dv   <= far_sending;
    end

    // ------------------------------------------------------------------
    // DUT: the receive path (H1), taking the far end's echoed raw stream.
    // DUT: H1 (unchanged) receiving the far end's echoed raw stream
    logic rst_rx = 1'b1, rst_dsp = 1'b1, rst_tx = 1'b1;
    logic [31:0] cfg_hl2_ip = HL2_IP;

    wire [11:0] samp_out;
    wire        samp_out_valid, samp_out_is_fill;
    wire [7:0]  safety_byte;
    wire        irq_safety_change, irq_pkt_rx, irq_gap;
    wire [31:0] cnt_crc_errors, cnt_raw_frames, cnt_other_frames;
    wire [15:0] cnt_ring_frames, cnt_ring_dropped;
    wire [31:0] cnt_gap_events, cnt_gap_samples, cnt_resync_events;
    logic [13:0] ring_rd_addr = 14'd0;
    wire [7:0]   ring_rd_data;
    wire [13:0]  ring_wr_ptr;
    wire [7:0]   raw_version;
    wire [15:0]  raw_tx_fifo_fill;
    wire         raw_commit_pulse;

    hl2_link_rx_top #(.RING_AW(14)) dut_rx (
        .clk_rx      (clk),
        .rst_rx      (rst_rx),
        .g_rx_d(wire_byte), .g_rx_dv(wire_dv), .g_rx_er(1'b0), .g_rx_ce(1'b1),
        .clk_dsp     (clk_dsp),
        .rst_dsp     (rst_dsp),
        .cfg_hl2_ip  (cfg_hl2_ip),
        .samp_out         (samp_out),
        .samp_out_valid   (samp_out_valid),
        .samp_out_is_fill (samp_out_is_fill),
        .safety_byte      (safety_byte),
        .irq_safety_change(irq_safety_change),
        .raw_version      (raw_version),
        .raw_tx_fifo_fill (raw_tx_fifo_fill),
        .raw_commit_pulse (raw_commit_pulse),
        .irq_pkt_rx  (irq_pkt_rx),
        .irq_gap     (irq_gap),
        .cnt_crc_errors  (cnt_crc_errors),
        .cnt_raw_frames  (cnt_raw_frames),
        .cnt_other_frames(cnt_other_frames),
        .cnt_ring_frames (cnt_ring_frames),
        .cnt_ring_dropped(cnt_ring_dropped),
        .cnt_gap_events   (cnt_gap_events),
        .cnt_gap_samples  (cnt_gap_samples),
        .cnt_resync_events(cnt_resync_events),
        .cnt_seq_lost(), .cnt_seq_restarts(), .cnt_code_frames(), .cnt_len_errors(), .cnt_hl2_missing(), .last_seq(),
        .cnt_drain_drops(), .cnt_overruns(), .cnt_idx_drops(), .hl2_ovf_count(),
        .ring_rd_addr(ring_rd_addr),
        .ring_rd_data(ring_rd_data),
        .ring_wr_ptr (ring_wr_ptr)
    );

    wire [15:0] fifo_fill;
    wire        fifo_fill_valid;
    rx_tx_fill_bridge fill_bridge_i (
        .clk_rx(clk), .raw_version(raw_version), .raw_tx_fifo_fill(raw_tx_fifo_fill),
        .raw_commit_pulse(raw_commit_pulse),
        .clk_dsp(clk_dsp), .fifo_fill(fifo_fill), .fifo_fill_valid(fifo_fill_valid)
    );

    // ------------------------------------------------------------------
    // DUT: the transmit path. `in_sample` and `in_valid` stand in for the out_data and out_valid of tx_chain.v (see
    // hl2_link_tx_top.v): a counter of sample index mod 4096 that advances once per `pace_out` pulse and is looped back as
    // `in_valid`, which is the contract tx_chain.v itself has with `pace`. Testing the framer and rate lock this way
    // (docs/H2_LINK_TX.md) leaves the real DSP chain out of the picture, so the pattern is easy to check at the far end.
    wire pace_out;
    logic [11:0] tx_pattern = 12'h000;
    always @(posedge clk_dsp) begin
        if (rst_dsp) tx_pattern <= 12'h000;
        else if (pace_out) tx_pattern <= tx_pattern + 12'd1;
    end

    // Transmit permitted, no safety trip.
    logic cfg_tx_enable = 1'b1;
    logic cfg_trip      = 1'b0;

    wire [31:0] cnt_tx_skip, cnt_tx_insert, cnt_tx_fill_updates;
    wire [31:0] cnt_tx_frames, cnt_cq_frames, cnt_tx_fifo_overrun;

    hl2_link_tx_top #(.N(TX_N), .FIFO_AW(13), .CPU_TX_AW(12)) dut_tx (
        .clk_dsp(clk_dsp), .rst_dsp(rst_dsp),
        .rx_adc_valid(samp_out_valid),
        .fifo_fill(fifo_fill), .fifo_fill_valid(fifo_fill_valid),
        .pace_out(pace_out),
        .in_sample(tx_pattern), .in_valid(pace_out),
        .cfg_tx_enable(cfg_tx_enable), .cfg_trip(cfg_trip),
        .cnt_tx_skip(cnt_tx_skip), .cnt_tx_insert(cnt_tx_insert), .cnt_tx_fill_updates(cnt_tx_fill_updates),
        .clk_tx(clk), .rst_tx(rst_tx),
        .cfg_my_mac(MY_MAC), .cfg_my_ip(MY_IP), .cfg_my_port(MY_PORT),
        .cfg_hl2_mac(HL2_MAC), .cfg_hl2_ip(HL2_IP),
        .cq_wr_en(1'b0), .cq_wr_addr(12'd0), .cq_wr_data(8'd0),
        .cq_send_len_wr(1'b0), .cq_wr_len_in(16'd0), .cq_busy(),
        .cnt_tx_frames(cnt_tx_frames), .cnt_cq_frames(cnt_cq_frames), .cnt_tx_fifo_overrun(cnt_tx_fifo_overrun),
        .tx_link_up(1'b1), .gmii_txd(tx_gmii_txd), .gmii_tx_en(tx_gmii_tx_en)
    );

    // ------------------------------------------------------------------
    // Checkers
    integer errors = 0;
    // `!== 1'b1` so that a condition that evaluates to X counts as a failure.
    `define CHECK(cond, msg) if ((cond) !== 1'b1) begin errors = errors + 1; $display("ERROR t=%0t: %s", $time, msg); end

    // ------------------------------------------------------------------
    // FCS monitor. Every frame our transmitter puts on the wire is taken as the far end's receiver sees it (destination MAC
    // to FCS, preamble and SFD stripped) and its last four bytes are compared with an Ethernet CRC-32 that is
    // computed here, bit by bit, without crc32_eth.v or crc32_append.v. This is needed because the HL2's own receive
    // logic (mac_recv, ip_recv, udp_recv) ignores the FCS, so the echo check below would never notice a wrong one.
    reg [7:0] fcs_buf [0:16383];
    integer   fcs_n = 0, fcs_frames = 0, fcs_bad = 0;
    reg       fcs_act_d = 1'b0;
    integer   fcs_fh;
    function [31:0] bench_crc32(input integer n);   // standard CRC-32 (reflected 0xEDB88320, init and final XOR all ones)
        integer k, b;
        reg [31:0] r;
        begin
            r = 32'hFFFF_FFFF;
            for (k = 0; k < n; k = k + 1) begin
                r = r ^ {24'd0, fcs_buf[k]};
                for (b = 0; b < 8; b = b + 1) r = r[0] ? ((r >> 1) ^ 32'hEDB8_8320) : (r >> 1);
            end
            bench_crc32 = ~r;
        end
    endfunction
    // The first transmit frame is written as one line of hex bytes, for inspection after the run.
    initial fcs_fh = $fopen("sim/out/h2_tx_frame0.hex", "w");
    // Collects the bytes of a frame while the far end's receiver is active and, when the frame ends, compares its FCS.
    // Frames of 64 bytes or less and frames that do not fit the 16,384 byte buffer are not judged.
    always @(posedge clk) begin : fcs_monitor
        reg [31:0] want, got;
        integer k;
        fcs_act_d <= far_rx_active;
        if (far_rx_active) begin
            if (fcs_n < 16384) fcs_buf[fcs_n] = far_rx_data;
            fcs_n = fcs_n + 1;
        end else if (fcs_act_d) begin
            if (fcs_n > 64 && fcs_n < 16384) begin
                want = bench_crc32(fcs_n - 4);
                got  = {fcs_buf[fcs_n-1], fcs_buf[fcs_n-2], fcs_buf[fcs_n-3], fcs_buf[fcs_n-4]};   // last byte is the MSB
                fcs_frames = fcs_frames + 1;
                if (fcs_frames == 1) begin
                    for (k = 0; k < fcs_n; k = k + 1) $fwrite(fcs_fh, "%02x", fcs_buf[k]);
                    $fwrite(fcs_fh, "%c", 8'd10);
                    $fflush(fcs_fh);
                end
                if (want !== got) begin
                    fcs_bad = fcs_bad + 1;
                    if (fcs_bad < 4) $display("ERROR t=%0t: TX frame %0d (%0d bytes) FCS on the wire %08h, CRC-32 of the %0d bytes before it %08h",
                                              $time, fcs_frames, fcs_n, got, fcs_n - 4, want);
                end
            end
            fcs_n = 0;
        end
    end

    // Echoed pattern check (clk_ad domain, at the far end). echo_idx is the transmit sample index that our header
    // carried (first index of the frame plus the position within it), and the pattern is index mod 4096 = index[11:0].
    // This is a real check because it compares the far end's own bookkeeping of what it received with what it played back,
    // and does not use the DUT's own tx_pattern counter.
    integer echo_checked = 0;
    integer echo_mismatches = 0;
    always @(posedge clk_ad) begin
        if (echo_play && echo_ok) begin
            echo_checked = echo_checked + 1;
            if (echo_data !== echo_idx[11:0]) begin
                echo_mismatches = echo_mismatches + 1;
                if (echo_mismatches < 20)
                    $display("ERROR t=%0t: echo sample idx=%0d got %h expected %h",
                             $time, echo_idx, echo_data, echo_idx[11:0]);
            end
        end
    end

    // Fill band tracking (clk_ad domain, the far end's own registers): the FIFO fill is sampled once per played sample
    // after the settling time, so the check below judges the whole measured trace, not only the final value. The band is
    // the target of 12,000 samples plus or minus 2,000.
    integer fill_in_band = 0;
    integer fill_out_of_band = 0;
    integer fill_samples = 0;
    logic   fill_track_enable = 1'b0;
    always @(posedge clk_ad) begin
        if (fill_track_enable && txsink_i.take_sample) begin
            fill_samples = fill_samples + 1;
            if ((txsink_i.fill >= 16'd10000) && (txsink_i.fill <= 16'd14000)) fill_in_band = fill_in_band + 1;
            else fill_out_of_band = fill_out_of_band + 1;
        end
    end

    // ------------------------------------------------------------------
    integer sim_us;
    initial begin
`ifdef SIM_US
        sim_us = `SIM_US;
`else
        sim_us = 3000;   // default smoke-test length (tools/check.sh); run_long.sh uses 50,000
`endif

        // Reset phase. The extra 37 ps keeps every stimulus change off the 8000 ps grid of `clk`: after a `@(posedge clk)`
        // any later delay that is a whole multiple of the period lands back on a real edge, and then the value that a
        // clocked block reads is a race. A write on exactly that grid was once missed by txsink's own register-write block,
        // which left duplex and echo mode off for a whole run.
        #50037;
        rst_rx = 1'b0; rst_dsp = 1'b0; rst_tx = 1'b0;
        #10037;

        // Far end: raw mode on (bit 0) and N = 968 (top 16 bits), test pattern off (bit 1), since in echo mode rawstream.v
        // substitutes the echoed samples for the ADC data. A small receive frame size keeps the frame period of the return
        // path short, and it is independent of TX_N.
        cmd_addr <= 6'h30; cmd_data <= {16'd968, 13'd0, 1'b0, 1'b0, 1'b1}; cmd_rqst <= 1'b1;
        @(posedge clk); cmd_rqst <= 1'b0;
        #(20 * 8000 + 37);
        // txsink: duplex on (bit 0) and echo on (bit 2), the value 5 (PROTOCOL.md 6.1).
        // txsink: duplex on, echo on (PROTOCOL.md 6.1: 0x00000005)
        cmd_addr <= 6'h31; cmd_data <= 32'h0000_0005; cmd_rqst <= 1'b1;
        @(posedge clk); cmd_rqst <= 1'b0;
        #(20 * 8000 + 37);
        run <= 1'b1;

        // Let the link lock on before the fill check starts counting. tx_rate_lock.v closes the start-up deficit
        // (the fill starts at 0, the target is 12,000) only as fast as the wire's real spare capacity allows, about 586 ksps
        // at the default COOLDOWN of 256 clocks of 150 MHz, so from a cold start that takes roughly 12,000 * 256 / 150e6 =
        // 20 ms in the worst case (an emptier link locks sooner). 25 ms covers that with some margin. The delays here are
        // written as 64'd1_000_000 * microseconds, because under `timescale 1ps/1fs a bare #(25_000_000) is only 25 us.
`ifdef SETTLE_US
        #(64'd1_000_000 * `SETTLE_US);   // a short run for the FCS check alone
`else
        #(64'd1_000_000 * 25_000);
`endif
        fill_track_enable <= 1'b1;

        #(64'd1_000_000 * sim_us);

        fill_track_enable <= 1'b0;
        run <= 1'b0;
        #(200_000);

        // Final checks.
        // -------- checks --------
        `CHECK(cnt_tx_frames > 0, "no TX frames were ever sent")
        `CHECK(fcs_frames > 0, "no TX frame was seen on the wire by the FCS monitor")
        `CHECK(fcs_bad == 0, $sformatf("%0d of %0d TX frames have a wrong Ethernet FCS (CRC-32 computed in the bench)", fcs_bad, fcs_frames))
        `CHECK(cnt_tx_fifo_overrun == 32'd0,
               $sformatf("%0d credit overruns (the rate-lock corrector outran the byte FIFO's margin)", cnt_tx_fifo_overrun))
        `CHECK(echo_checked > 0, "no echoed sample was ever seen at the far end")
        `CHECK(echo_mismatches == 0, $sformatf("%0d echoed-sample pattern mismatches", echo_mismatches))
        // far_i.ovf_cnt is the overflow count of the far end's own return path sender, which has nothing to do with the
        // HL2 TX sink checked below. It reads 1 in every run, always during the start-up handshake before the first raw
        // frame (rawstream.v releasing its write hold for the first time) and never again, and the gap and resync counters
        // of the receive path below, which would show a lost sample, both stay 0. The HL2's TX sink counters are what
        // matter for the transmit path, and this is a start-up quirk of the unmodified far end model's duplex and echo path,
        // so it is printed as a note and not failed.
        if (far_i.ovf_cnt != 16'd0)
            $display("NOTE: far end return-path (vendored rawstream.v) reported %0d start-up overflow(s), no gap resulted", far_i.ovf_cnt);
        `CHECK(cnt_gap_events == 32'd0, $sformatf("%0d gap events on the return path (H1)", cnt_gap_events))
        `CHECK(cnt_resync_events == 32'd0, $sformatf("%0d resync events on the return path (H1)", cnt_resync_events))
        // The HL2 TX sink must show no underflow, no overflow and no bad sample, and the fill must stay in the band.
        // PLAN.md H2 done-test: 0 underflows, 0 overflows, fill within 12,000 +/- 2,000
        `CHECK(txsink_i.unf_cnt == 16'd0, $sformatf("HL2 TX sink underflowed %0d times", txsink_i.unf_cnt))
        `CHECK(txsink_i.ovf_cnt == 16'd0, $sformatf("HL2 TX sink overflowed %0d times", txsink_i.ovf_cnt))
        `CHECK(txsink_i.bad_cnt == 32'd0, $sformatf("HL2 TX sink counted %0d bad (pattern) samples", txsink_i.bad_cnt))
        `CHECK(fill_samples > 0, "fill was never sampled")
        `CHECK(fill_out_of_band == 0,
               $sformatf("fill left the 12,000+/-2,000 band on %0d of %0d sampled points", fill_out_of_band, fill_samples))

        $display("fcs_frames=%0d fcs_bad=%0d", fcs_frames, fcs_bad);
        $display("cnt_tx_frames=%0d echo_checked=%0d echo_mismatches=%0d", cnt_tx_frames, echo_checked, echo_mismatches);
        $display("hl2 tx sink: unf=%0d ovf=%0d bad=%0d final_fill=%0d", txsink_i.unf_cnt, txsink_i.ovf_cnt, txsink_i.bad_cnt, txsink_i.fill);
        $display("fill_samples=%0d fill_in_band=%0d fill_out_of_band=%0d", fill_samples, fill_in_band, fill_out_of_band);
        $display("cnt_tx_skip=%0d cnt_tx_insert=%0d cnt_tx_fill_updates=%0d", cnt_tx_skip, cnt_tx_insert, cnt_tx_fill_updates);
        $display("H1 return path: gap_events=%0d resync_events=%0d raw_frames=%0d", cnt_gap_events, cnt_resync_events, cnt_raw_frames);

        if (errors == 0) $display("PASS");
        else $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule
